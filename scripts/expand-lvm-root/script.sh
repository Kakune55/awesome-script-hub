#!/usr/bin/env bash
set -Eeuo pipefail

# expand-lvm-root.sh
# 在虚拟机内部运行：扩展承载根目录 / 的 LVM 分区、PV、LV 和文件系统。
#
# 默认自动识别：
#   - 根目录 LV，例如 /dev/mapper/cs-root
#   - 根 VG，例如 cs
#   - 承载该 VG 的 PV，例如 /dev/sda3
#   - PV 所在磁盘和分区号，例如 /dev/sda + 3
#
# 可选手动指定：
#   sudo bash expand-lvm-root.sh /dev/sda 3 /dev/mapper/cs-root
#
# 注意：
#   这只负责虚拟机内部扩容。
#   运行前请先在宿主机 / PVE 里扩大虚拟磁盘，例如：
#     qm resize <VMID> scsi0 +50G

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

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "请用 root 运行，例如：sudo bash $0"
}

run() {
  echo "+ $*"
  "$@"
}

install_growpart() {
  if command -v growpart >/dev/null 2>&1; then
    return 0
  fi

  log "未找到 growpart，尝试安装"

  if command -v dnf >/dev/null 2>&1; then
    run dnf install -y cloud-utils-growpart
  elif command -v yum >/dev/null 2>&1; then
    run yum install -y cloud-utils-growpart
  elif command -v apt-get >/dev/null 2>&1; then
    run apt-get update
    run apt-get install -y cloud-guest-utils
  else
    die "未找到 growpart，且无法识别包管理器。请手动安装 cloud-utils-growpart 或 cloud-guest-utils。"
  fi

  command -v growpart >/dev/null 2>&1 || die "growpart 安装失败"
}

detect_root_lv() {
  local src
  src="$(findmnt -n -o SOURCE /)" || die "无法识别根目录挂载源"

  # /dev/mapper/cs-root -> /dev/dm-X
  local real
  real="$(readlink -f "$src")"

  if ! command -v lvs >/dev/null 2>&1; then
    die "未找到 lvs。当前系统可能没有安装 lvm2，或根目录不是 LVM。"
  fi

  if ! lvs "$real" >/dev/null 2>&1; then
    # 有些系统 lvs 能识别 /dev/mapper/name，但不识别 readlink 后的 /dev/dm-X
    if lvs "$src" >/dev/null 2>&1; then
      echo "$src"
      return 0
    fi
    die "根目录挂载源不是可识别的 LVM LV：$src -> $real"
  fi

  echo "$real"
}

detect_vg_from_lv() {
  local lv="$1"
  lvs --noheadings -o vg_name "$lv" | awk '{$1=$1; print}'
}

detect_pv_for_vg() {
  local vg="$1"

  # 优先选择分区型 PV，例如 /dev/sda3、/dev/vda3
  local pv
  pv="$(
    pvs --noheadings -o pv_name,vg_name 2>/dev/null \
      | awk -v vg="$vg" '$2 == vg {print $1}' \
      | while read -r candidate; do
          if lsblk -no TYPE "$candidate" 2>/dev/null | grep -qx "part"; then
            echo "$candidate"
            break
          fi
        done
  )"

  if [[ -z "${pv:-}" ]]; then
    pv="$(
      pvs --noheadings -o pv_name,vg_name 2>/dev/null \
        | awk -v vg="$vg" '$2 == vg {print $1; exit}'
    )"
  fi

  [[ -n "${pv:-}" ]] || die "无法找到 VG=$vg 对应的 PV"
  echo "$pv"
}

detect_disk_and_partnum_from_pv() {
  local pv="$1"

  local type
  type="$(lsblk -no TYPE "$pv" 2>/dev/null | head -n1 || true)"

  [[ "$type" == "part" ]] || die "当前 PV 不是普通分区：$pv。脚本只自动处理 /dev/sda3 这类分区型 LVM PV。"

  local pkname partnum
  pkname="$(lsblk -no PKNAME "$pv" | head -n1 | awk '{$1=$1; print}')"
  partnum="$(lsblk -no PARTN "$pv" | head -n1 | awk '{$1=$1; print}')"

  [[ -n "$pkname" ]] || die "无法识别 $pv 所属磁盘"
  [[ -n "$partnum" ]] || die "无法识别 $pv 的分区号"

  echo "/dev/$pkname $partnum"
}

rescan_disk() {
  local disk="$1"
  local base
  base="$(basename "$disk")"

  log "刷新内核识别的磁盘容量：$disk"

  if [[ -w "/sys/class/block/$base/device/rescan" ]]; then
    echo 1 > "/sys/class/block/$base/device/rescan"
  else
    warn "找不到 /sys/class/block/$base/device/rescan，跳过 rescan"
  fi

  partprobe "$disk" 2>/dev/null || true
  udevadm settle 2>/dev/null || true
}

main() {
  need_root

  local disk="${1:-}"
  local partnum="${2:-}"
  local root_lv="${3:-}"

  command -v findmnt >/dev/null 2>&1 || die "缺少 findmnt"
  command -v lsblk >/dev/null 2>&1 || die "缺少 lsblk"
  command -v awk >/dev/null 2>&1 || die "缺少 awk"
  command -v pvs >/dev/null 2>&1 || die "缺少 pvs，请安装 lvm2"
  command -v pvresize >/dev/null 2>&1 || die "缺少 pvresize，请安装 lvm2"
  command -v lvextend >/dev/null 2>&1 || die "缺少 lvextend，请安装 lvm2"

  if [[ -z "$root_lv" ]]; then
    root_lv="$(detect_root_lv)"
  fi

  local vg
  vg="$(detect_vg_from_lv "$root_lv")"
  [[ -n "$vg" ]] || die "无法从 $root_lv 识别 VG"

  local pv
  pv="$(detect_pv_for_vg "$vg")"

  if [[ -z "$disk" || -z "$partnum" ]]; then
    read -r disk partnum < <(detect_disk_and_partnum_from_pv "$pv")
  fi

  local part="${disk}${partnum}"
  # NVMe / MMC 分区名是 /dev/nvme0n1p3 这种，需要额外的 p
  if [[ "$disk" =~ [0-9]$ ]]; then
    part="${disk}p${partnum}"
  fi

  log "检测结果"
  echo "  root LV : $root_lv"
  echo "  VG      : $vg"
  echo "  PV      : $pv"
  echo "  disk    : $disk"
  echo "  partnum : $partnum"
  echo "  part    : $part"

  [[ -b "$disk" ]] || die "磁盘不存在：$disk"
  [[ -b "$part" ]] || die "分区不存在：$part"

  echo
  df -h /
  echo
  lsblk "$disk"

  install_growpart
  rescan_disk "$disk"

  log "扩展分区：$disk $partnum"
  if growpart "$disk" "$partnum"; then
    echo "growpart 完成"
  else
    warn "growpart 返回非 0。可能是分区已经扩到最大，继续尝试 pvresize。"
  fi

  partprobe "$disk" 2>/dev/null || true
  udevadm settle 2>/dev/null || true

  log "扩展 PV：$part"
  run pvresize "$part"

  log "扩展根 LV：$root_lv"
  run lvextend -r -l +100%FREE "$root_lv"

  log "扩容完成"
  df -h /
  echo
  lsblk "$disk"
  echo
  pvs
  echo
  vgs
  echo
  lvs
}

main "$@"
