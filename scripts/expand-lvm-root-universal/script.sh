#!/usr/bin/env bash
set -Eeuo pipefail

# expand-lvm-root-universal.sh
#
# 适用场景：
#   Debian / Ubuntu / RHEL / CentOS / Rocky / Alma / Fedora 虚拟机内部扩容。
#   典型结构：
#     /dev/sda3  -> LVM PV
#     VG         -> root LV
#     /          -> /dev/mapper/<vg>-<root>
#
# 功能：
#   1. 自动识别发行版和包管理器
#   2. 自动安装 growpart / lvm2 / xfsprogs / e2fsprogs 等必要组件
#   3. 自动识别根目录对应的 LV、VG、PV、磁盘、分区号
#   4. 扩展分区、PV、根 LV、根文件系统
#
# 使用：
#   sudo bash expand-lvm-root-universal.sh
#
# 手动指定：
#   sudo bash expand-lvm-root-universal.sh --disk /dev/sda --part 3 --lv /dev/mapper/cs-root
#
# 只检查不执行：
#   sudo bash expand-lvm-root-universal.sh --dry-run
#
# 注意：
#   运行前请先在宿主机/PVE侧扩大虚拟磁盘：
#     qm resize <VMID> scsi0 +50G

DRY_RUN=0
NO_INSTALL=0
ASSUME_YES=1
DISK=""
PARTNUM=""
ROOT_LV=""

log() {
  echo -e "\n[+] $*"
}

warn() {
  echo -e "\n[!] $*" >&2
}

die() {
  echo -e "\n[ERROR] $*" >&2
  exit 1
}

run() {
  echo "+ $*"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    "$@"
  fi
}

usage() {
  cat <<'EOF'
Usage:
  sudo bash expand-lvm-root-universal.sh [options]

Options:
  --disk DEV       指定磁盘，例如 /dev/sda、/dev/vda、/dev/nvme0n1
  --part N         指定分区号，例如 3
  --lv LV          指定根 LV，例如 /dev/mapper/cs-root 或 /dev/vg/root
  --no-install     不自动安装依赖，缺少依赖则退出
  --dry-run        只打印将要执行的动作，不实际修改
  -h, --help       显示帮助

Examples:
  sudo bash expand-lvm-root-universal.sh
  sudo bash expand-lvm-root-universal.sh --disk /dev/sda --part 3 --lv /dev/mapper/cs-root
  sudo bash expand-lvm-root-universal.sh --dry-run
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --disk)
        DISK="${2:-}"
        shift 2
        ;;
      --part)
        PARTNUM="${2:-}"
        shift 2
        ;;
      --lv)
        ROOT_LV="${2:-}"
        shift 2
        ;;
      --no-install)
        NO_INSTALL=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "未知参数：$1"
        ;;
    esac
  done
}

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "请用 root 运行，例如：sudo bash $0"
}

detect_os() {
  OS_ID="unknown"
  OS_LIKE=""
  OS_NAME="unknown"

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_LIKE="${ID_LIKE:-}"
    OS_NAME="${PRETTY_NAME:-$OS_ID}"
  fi

  log "系统识别"
  echo "  OS      : $OS_NAME"
  echo "  ID      : $OS_ID"
  echo "  ID_LIKE : ${OS_LIKE:-unknown}"
}

has_like() {
  local key="$1"
  [[ "$OS_ID" == "$key" || " $OS_LIKE " == *" $key "* ]]
}

pkg_install() {
  [[ "$NO_INSTALL" -eq 0 ]] || die "缺少依赖且已指定 --no-install"

  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    run apt-get update
    run apt-get install -y "$@"
  elif command -v dnf >/dev/null 2>&1; then
    run dnf install -y "$@"
  elif command -v yum >/dev/null 2>&1; then
    run yum install -y "$@"
  elif command -v microdnf >/dev/null 2>&1; then
    run microdnf install -y "$@"
  else
    die "无法识别包管理器，不能自动安装依赖"
  fi
}

ensure_base_deps() {
  log "检查基础依赖"

  local missing=()

  command -v findmnt >/dev/null 2>&1 || missing+=("findmnt")
  command -v lsblk >/dev/null 2>&1 || missing+=("lsblk")
  command -v awk >/dev/null 2>&1 || missing+=("awk")
  command -v sed >/dev/null 2>&1 || missing+=("sed")
  command -v grep >/dev/null 2>&1 || missing+=("grep")

  command -v pvs >/dev/null 2>&1 || missing+=("lvm")
  command -v pvresize >/dev/null 2>&1 || missing+=("lvm")
  command -v lvextend >/dev/null 2>&1 || missing+=("lvm")

  command -v partprobe >/dev/null 2>&1 || missing+=("partprobe")
  command -v udevadm >/dev/null 2>&1 || true

  if [[ "${#missing[@]}" -eq 0 ]]; then
    echo "  基础依赖已满足"
    return 0
  fi

  warn "发现缺失命令：${missing[*]}"
  log "尝试安装基础依赖"

  if command -v apt-get >/dev/null 2>&1 || has_like debian || has_like ubuntu; then
    # findmnt/lsblk 属于 util-linux；partprobe 属于 parted；udevadm 属于 udev。
    pkg_install util-linux lvm2 parted udev
  elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1 || has_like rhel || has_like fedora || has_like centos; then
    pkg_install util-linux lvm2 parted systemd-udev
  else
    die "无法根据系统类型安装基础依赖"
  fi
}

ensure_growpart() {
  if command -v growpart >/dev/null 2>&1; then
    echo "  growpart 已存在：$(command -v growpart)"
    return 0
  fi

  log "未找到 growpart，尝试按发行版安装"

  if command -v apt-get >/dev/null 2>&1 || has_like debian || has_like ubuntu; then
    pkg_install cloud-guest-utils
  elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1 || has_like rhel || has_like fedora || has_like centos; then
    pkg_install cloud-utils-growpart
  else
    die "无法判断 growpart 包名。Debian/Ubuntu 为 cloud-guest-utils；RHEL 系为 cloud-utils-growpart。"
  fi

  command -v growpart >/dev/null 2>&1 || die "growpart 仍不可用"
}

ensure_fs_tools() {
  local fstype="$1"

  log "检查文件系统工具：$fstype"

  case "$fstype" in
    xfs)
      if ! command -v xfs_growfs >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1 || has_like debian || has_like ubuntu; then
          pkg_install xfsprogs
        elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1 || has_like rhel || has_like fedora || has_like centos; then
          pkg_install xfsprogs
        else
          die "缺少 xfs_growfs，请手动安装 xfsprogs"
        fi
      fi
      ;;
    ext2|ext3|ext4)
      if ! command -v resize2fs >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1 || has_like debian || has_like ubuntu; then
          pkg_install e2fsprogs
        elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1 || has_like rhel || has_like fedora || has_like centos; then
          pkg_install e2fsprogs
        else
          die "缺少 resize2fs，请手动安装 e2fsprogs"
        fi
      fi
      ;;
    *)
      warn "未显式识别的根文件系统类型：$fstype。将依赖 lvextend -r 自动处理。"
      ;;
  esac
}

detect_root_lv() {
  local src real

  src="$(findmnt -n -o SOURCE /)" || die "无法识别根目录挂载源"
  real="$(readlink -f "$src")"

  if lvs "$real" >/dev/null 2>&1; then
    echo "$real"
    return 0
  fi

  if lvs "$src" >/dev/null 2>&1; then
    echo "$src"
    return 0
  fi

  # Debian 常见 /dev/mapper/vg-root；RHEL 常见 /dev/mapper/cs-root。
  # 如果 findmnt 返回 /dev/dm-0，这里已经覆盖；如果返回其它形式且 lvs 不认，则退出。
  die "根目录挂载源不是可识别的 LVM LV：$src -> $real"
}

detect_vg_from_lv() {
  local lv="$1"
  lvs --noheadings -o vg_name "$lv" | awk '{$1=$1; print}'
}

detect_lv_path_preferred() {
  local lv="$1"
  local path
  path="$(lvs --noheadings -o lv_path "$lv" 2>/dev/null | awk '{$1=$1; print}')"
  if [[ -n "$path" && -e "$path" ]]; then
    echo "$path"
  else
    echo "$lv"
  fi
}

detect_root_fstype() {
  findmnt -n -o FSTYPE /
}

detect_pv_for_vg() {
  local vg="$1"
  local pv_list=()

  while read -r pvname vgname; do
    [[ -n "${pvname:-}" ]] || continue
    [[ "$vgname" == "$vg" ]] || continue
    pv_list+=("$pvname")
  done < <(pvs --noheadings -o pv_name,vg_name 2>/dev/null | awk '{print $1, $2}')

  [[ "${#pv_list[@]}" -gt 0 ]] || die "无法找到 VG=$vg 对应的 PV"

  if [[ "${#pv_list[@]}" -eq 1 ]]; then
    echo "${pv_list[0]}"
    return 0
  fi

  warn "VG=$vg 有多个 PV：${pv_list[*]}"
  warn "自动选择第一个分区型 PV。多 PV 环境建议使用 --disk 和 --part 明确指定。"

  local candidate
  for candidate in "${pv_list[@]}"; do
    if lsblk -no TYPE "$candidate" 2>/dev/null | grep -qx "part"; then
      echo "$candidate"
      return 0
    fi
  done

  echo "${pv_list[0]}"
}

detect_disk_and_partnum_from_pv() {
  local pv="$1"
  local type pkname partnum

  type="$(lsblk -no TYPE "$pv" 2>/dev/null | head -n1 | awk '{$1=$1; print}')"
  [[ "$type" == "part" ]] || die "当前 PV 不是普通分区：$pv。请手动处理裸盘 PV 或使用更明确的分区型 LVM。"

  pkname="$(lsblk -no PKNAME "$pv" | head -n1 | awk '{$1=$1; print}')"
  partnum="$(lsblk -no PARTN "$pv" | head -n1 | awk '{$1=$1; print}')"

  [[ -n "$pkname" ]] || die "无法识别 $pv 所属磁盘"
  [[ -n "$partnum" ]] || die "无法识别 $pv 的分区号"

  echo "/dev/$pkname $partnum"
}

partition_path() {
  local disk="$1"
  local n="$2"

  if [[ "$disk" =~ [0-9]$ ]]; then
    echo "${disk}p${n}"
  else
    echo "${disk}${n}"
  fi
}

rescan_disk() {
  local disk="$1"
  local base

  base="$(basename "$disk")"

  log "刷新内核识别的磁盘容量：$disk"

  if [[ -w "/sys/class/block/$base/device/rescan" ]]; then
    run sh -c "echo 1 > '/sys/class/block/$base/device/rescan'"
  else
    warn "找不到 /sys/class/block/$base/device/rescan，跳过 rescan"
  fi

  run partprobe "$disk" || true

  if command -v udevadm >/dev/null 2>&1; then
    run udevadm settle || true
  fi
}

show_state() {
  local disk="$1"

  echo
  echo "===== df -h / ====="
  df -h /
  echo
  echo "===== lsblk -f $disk ====="
  lsblk -f "$disk" || true
  echo
  echo "===== pvs ====="
  pvs || true
  echo
  echo "===== vgs ====="
  vgs || true
  echo
  echo "===== lvs ====="
  lvs || true
}

main() {
  parse_args "$@"
  need_root
  detect_os
  ensure_base_deps
  ensure_growpart

  local root_lv="$ROOT_LV"
  if [[ -z "$root_lv" ]]; then
    root_lv="$(detect_root_lv)"
  fi

  root_lv="$(detect_lv_path_preferred "$root_lv")"

  local vg
  vg="$(detect_vg_from_lv "$root_lv")"
  [[ -n "$vg" ]] || die "无法从 $root_lv 识别 VG"

  local fstype
  fstype="$(detect_root_fstype)"
  [[ -n "$fstype" ]] || die "无法识别根文件系统类型"

  ensure_fs_tools "$fstype"

  local pv
  pv="$(detect_pv_for_vg "$vg")"

  local disk="$DISK"
  local partnum="$PARTNUM"

  if [[ -z "$disk" || -z "$partnum" ]]; then
    read -r disk partnum < <(detect_disk_and_partnum_from_pv "$pv")
  fi

  local part
  part="$(partition_path "$disk" "$partnum")"

  log "扩容目标"
  echo "  root LV : $root_lv"
  echo "  VG      : $vg"
  echo "  PV      : $pv"
  echo "  FSTYPE  : $fstype"
  echo "  disk    : $disk"
  echo "  partnum : $partnum"
  echo "  part    : $part"
  echo "  dry-run : $DRY_RUN"

  [[ -b "$disk" ]] || die "磁盘不存在：$disk"
  [[ -b "$part" ]] || die "分区不存在：$part"

  log "扩容前状态"
  show_state "$disk"

  rescan_disk "$disk"

  log "扩展分区：growpart $disk $partnum"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    if growpart "$disk" "$partnum"; then
      echo "growpart 完成"
    else
      warn "growpart 返回非 0。可能是分区已经扩到最大，继续尝试 pvresize。"
    fi
  else
    echo "+ growpart $disk $partnum"
  fi

  run partprobe "$disk" || true
  if command -v udevadm >/dev/null 2>&1; then
    run udevadm settle || true
  fi

  log "扩展 LVM PV：$part"
  run pvresize "$part"

  log "扩展根 LV 和文件系统：$root_lv"
  run lvextend -r -l +100%FREE "$root_lv"

  log "扩容后状态"
  show_state "$disk"

  log "完成"
  echo "如果 df -h / 显示容量已变大，说明 LV 和文件系统均已完成扩容。"
}

main "$@"
