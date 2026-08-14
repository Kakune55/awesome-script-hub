#!/bin/sh
#From https://github.com/spiritLHLS/addzram
#Channel: https://t.me/vps_reviews
#2026.06.01

# 设置UTF-8环境 / Set UTF-8 locale
utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 -E "UTF-8|utf8")
if [ -z "$utf8_locale" ]; then
  echo "No UTF-8 locale found / 未找到UTF-8语言环境"
else
  export LC_ALL="$utf8_locale"
  export LANG="$utf8_locale"
  export LANGUAGE="$utf8_locale"
fi

# 创建工作目录 / Create work directory
if [ ! -d /usr/local/bin ]; then
  mkdir -p /usr/local/bin 2>/dev/null || true
fi

# 颜色输出函数 / Color output functions
_red()    { printf "\033[31m\033[01m%s\033[0m\n" "$*"; }
_green()  { printf "\033[32m\033[01m%s\033[0m\n" "$*"; }
_yellow() { printf "\033[33m\033[01m%s\033[0m\n" "$*"; }
_blue()   { printf "\033[36m\033[01m%s\033[0m\n" "$*"; }

# 读取用户输入 / Read user input
reading() {
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    printf "\033[32m\033[01m%s\033[0m" "$1" > /dev/tty
    read -r "$2" < /dev/tty
  else
    printf "\033[32m\033[01m%s\033[0m" "$1"
    read -r "$2"
  fi
}

pause_continue() {
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    printf "Press Enter to continue... / 按回车键继续..." > /dev/tty
    read -r dummy < /dev/tty
  else
    printf "Press Enter to continue... / 按回车键继续..."
    read -r dummy || true
  fi
}

ZRAM_DEVICE="/dev/zram0"
ZRAM_ALGO_FILE="/usr/local/bin/zram_algorithm"
REPO_URL="https://github.com/spiritLHLS/addzram"

# ────────────────────────────────────────────────
# 检测 init 系统 / Detect init system
# ────────────────────────────────────────────────
detect_init() {
  if [ -d /run/systemd/system ] || command -v systemctl >/dev/null 2>&1; then
    echo "systemd"
  elif [ -f /etc/init.d/rcS ] || command -v rc-service >/dev/null 2>&1; then
    echo "openrc"
  elif command -v sv >/dev/null 2>&1; then
    echo "runit"
  else
    echo "sysv"
  fi
}

INIT_SYS=$(detect_init)

# ────────────────────────────────────────────────
# 显示人类可读的大小 / Human-readable size
# ────────────────────────────────────────────────
human_readable_size() {
  bytes="$1"
  gb=$((bytes / 1024 / 1024 / 1024))
  mb=$((bytes / 1024 / 1024))
  if [ "$gb" -gt 0 ]; then
    echo "${gb}GB"
  else
    echo "${mb}MB"
  fi
}

# ────────────────────────────────────────────────
# 计算推荐 zRAM 大小 / Recommended zRAM size
# ────────────────────────────────────────────────
calculate_zram_size() {
  if [ -f /proc/meminfo ]; then
    mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  else
    # FreeBSD / OpenBSD / macOS
    mem_bytes=$(sysctl -n hw.physmem 2>/dev/null || sysctl -n hw.memsize 2>/dev/null || echo 0)
    mem_kb=$((mem_bytes / 1024))
  fi
  mem_mb=$((mem_kb / 1024))
  if [ "$mem_mb" -lt 4096 ]; then
    zram_mb=$mem_mb
  else
    zram_mb=$((mem_mb / 2))
  fi
  echo "$zram_mb"
}

# ────────────────────────────────────────────────
# 权限检查 / Check root
# ────────────────────────────────────────────────
check_root() {
  uid=$(id -u 2>/dev/null)
  if [ -z "$uid" ]; then
    uid=$(id | sed 's/uid=\([0-9]*\).*/\1/')
  fi
  if [ "$uid" != "0" ]; then
    _red "The script must be run as root."
    _red "脚本必须以root身份运行。"
    _yellow "Please run: sudo sh addzram.sh  or  sudo -i"
    _yellow "请执行:     sudo sh addzram.sh  或  sudo -i"
    exit 1
  fi
}

# ────────────────────────────────────────────────
# 通用安装软件包 / Generic package install
# ────────────────────────────────────────────────
install_pkg() {
  pkg="$1"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y "$pkg"
  elif command -v apt >/dev/null 2>&1; then
    apt update -qq && apt install -y "$pkg"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "$pkg"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "$pkg"
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm "$pkg"
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache "$pkg"
  elif command -v zypper >/dev/null 2>&1; then
    zypper install -y "$pkg"
  elif command -v pkg >/dev/null 2>&1; then
    pkg install -y "$pkg"
  elif command -v emerge >/dev/null 2>&1; then
    emerge -q "$pkg"
  else
    return 1
  fi
}

# ────────────────────────────────────────────────
# 检查并加载 zram 模块 / Check & load zram module
# ────────────────────────────────────────────────
check_zram_module() {
  if lsmod 2>/dev/null | grep -q "^zram"; then
    _green "ZRAM module is already loaded. / ZRAM模块已加载。"
    return 0
  fi
  if modprobe zram 2>/dev/null; then
    _green "ZRAM module loaded successfully. / ZRAM模块加载成功。"
    return 0
  fi
  _yellow "ZRAM module not found, trying to install... / 未找到zram模块，尝试安装..."
  if command -v apt-get >/dev/null 2>&1 || command -v apt >/dev/null 2>&1; then
    _green "Detected apt, installing zram-tools... / 检测到apt，安装zram-tools..."
    install_pkg zram-tools
  elif command -v dnf >/dev/null 2>&1; then
    _green "Detected dnf, installing kmod-zram... / 检测到dnf，安装kmod-zram..."
    install_pkg kmod-zram
  elif command -v yum >/dev/null 2>&1; then
    _green "Detected yum, installing kmod-zram... / 检测到yum，安装kmod-zram..."
    install_pkg kmod-zram
  elif command -v pacman >/dev/null 2>&1; then
    _green "Detected pacman, installing zram-generator... / 检测到pacman，安装zram-generator..."
    install_pkg zram-generator
  elif command -v apk >/dev/null 2>&1; then
    _green "Detected apk (Alpine), installing zram-init... / 检测到apk(Alpine)，安装zram-init..."
    install_pkg zram-init
  elif command -v zypper >/dev/null 2>&1; then
    _green "Detected zypper, installing zram... / 检测到zypper，安装zram..."
    install_pkg zram
  else
    _red "No supported package manager found. Please install zram module manually."
    _red "未找到支持的包管理器，请手动安装zram模块。"
    echo "  Debian/Ubuntu : apt install zram-tools"
    echo "  RHEL/CentOS   : yum install kmod-zram"
    echo "  Fedora        : dnf install kmod-zram"
    echo "  Arch Linux    : pacman -S zram-generator"
    echo "  Alpine        : apk add zram-init"
    echo "  openSUSE      : zypper install zram"
    exit 1
  fi
  if ! modprobe zram 2>/dev/null; then
    _red "Failed to load zram module after installation. / 安装后仍无法加载zram模块。"
    exit 1
  fi
  _green "ZRAM module is available. / ZRAM模块可用。"
}

# ────────────────────────────────────────────────
# 检查并安装必要命令 / Ensure required commands
# ────────────────────────────────────────────────
ensure_util_linux() {
  missing=""
  for cmd in zramctl mkswap swapon swapoff; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing="$missing $cmd"
    fi
  done
  if [ -z "$missing" ]; then
    return 0
  fi
  _yellow "Missing commands:$missing / 缺少命令:$missing"
  _yellow "Trying to install util-linux... / 尝试安装util-linux..."
  install_pkg util-linux || true
  for cmd in zramctl mkswap swapon swapoff; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      _red "Command '$cmd' still missing. Please install util-linux manually."
      _red "命令 '$cmd' 仍缺失，请手动安装util-linux。"
      exit 1
    fi
  done
}

# ────────────────────────────────────────────────
# 解析支持的压缩算法 / Parse supported algorithms
# ────────────────────────────────────────────────
parse_algorithms() {
  rm -f "$ZRAM_ALGO_FILE"
  if [ -f /sys/block/zram0/comp_algorithm ]; then
    algo_line=$(cat /sys/block/zram0/comp_algorithm)
    for word in $algo_line; do
      # 跳过纯数字 / Skip pure numbers
      case "$word" in
        *[!0-9]*) : ;;
        *) continue ;;
      esac
      clean=$(echo "$word" | tr -d '[]')
      if [ -n "$clean" ]; then
        echo "$clean" >> "$ZRAM_ALGO_FILE"
      fi
    done
  fi
  # 文件为空则写入默认算法 / Default fallback
  if [ ! -s "$ZRAM_ALGO_FILE" ]; then
    printf "lzo\nlz4\nzstd\n" > "$ZRAM_ALGO_FILE"
  fi
}

# 将 zstd 排到首位 / Promote zstd to first
promote_zstd() {
  if grep -q "^zstd$" "$ZRAM_ALGO_FILE" 2>/dev/null; then
    tmp_file="${ZRAM_ALGO_FILE}.tmp"
    echo "zstd" > "$tmp_file"
    grep -v "^zstd$" "$ZRAM_ALGO_FILE" >> "$tmp_file"
    mv "$tmp_file" "$ZRAM_ALGO_FILE"
  fi
}

# ────────────────────────────────────────────────
# 配置开机自启 / Configure autostart
# ────────────────────────────────────────────────
setup_autostart() {
  sel_algo="$1"
  sel_size="$2"
  MODPROBE_BIN=$(command -v modprobe 2>/dev/null || echo /sbin/modprobe)
  MKSWAP_BIN=$(command -v mkswap 2>/dev/null || echo /sbin/mkswap)
  SWAPON_BIN=$(command -v swapon 2>/dev/null || echo /sbin/swapon)
  SWAPOFF_BIN=$(command -v swapoff 2>/dev/null || echo /sbin/swapoff)

  case "$INIT_SYS" in
    systemd)
      cat > /etc/systemd/system/zram.service << SVCEOF
[Unit]
Description=Swap with zram
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=true
ExecStartPre=${MODPROBE_BIN} zram
ExecStartPre=/bin/sh -c 'echo ${sel_algo} > /sys/block/zram0/comp_algorithm'
ExecStartPre=/bin/sh -c 'echo ${sel_size}M > /sys/block/zram0/disksize'
ExecStartPre=${MKSWAP_BIN} /dev/zram0
ExecStart=${SWAPON_BIN} -p 100 /dev/zram0
ExecStop=${SWAPOFF_BIN} /dev/zram0

[Install]
WantedBy=multi-user.target
SVCEOF
      mkdir -p /etc/modules-load.d /etc/modprobe.d
      echo "zram" > /etc/modules-load.d/zram.conf
      echo "options zram num_devices=1" > /etc/modprobe.d/zram.conf
      systemctl daemon-reload
      systemctl enable zram.service
      _green "Systemd service enabled. / systemd服务已启用。"
      ;;

    openrc)
      init_script="/etc/init.d/zram"
      cat > "$init_script" << RCEOF
#!/sbin/openrc-run
description="Swap with zram"
depend() { need localmount; }
start() {
  modprobe zram 2>/dev/null || true
  echo ${sel_algo} > /sys/block/zram0/comp_algorithm
  echo ${sel_size}M > /sys/block/zram0/disksize
  mkswap /dev/zram0
  swapon -p 100 /dev/zram0
}
stop() {
  swapoff /dev/zram0 2>/dev/null || true
  echo 1 > /sys/block/zram0/reset 2>/dev/null || true
  rmmod zram 2>/dev/null || true
}
RCEOF
      chmod +x "$init_script"
      rc-update add zram default 2>/dev/null || true
      _green "OpenRC service enabled. / OpenRC服务已启用。"
      ;;

    runit)
      svc_dir="/etc/sv/zram"
      mkdir -p "$svc_dir"
      cat > "${svc_dir}/run" << RVEOF
#!/bin/sh
modprobe zram 2>/dev/null || true
echo ${sel_algo} > /sys/block/zram0/comp_algorithm
echo ${sel_size}M > /sys/block/zram0/disksize
mkswap /dev/zram0
swapon -p 100 /dev/zram0
exec sleep inf
RVEOF
      chmod +x "${svc_dir}/run"
      ln -sf "$svc_dir" /var/service/zram 2>/dev/null || true
      _green "Runit service enabled. / Runit服务已启用。"
      ;;

    *)
      # SysV / rc.local fallback
      rc_local=""
      for f in /etc/rc.local /etc/rc.d/rc.local; do
        [ -f "$f" ] && rc_local="$f" && break
      done
      if [ -z "$rc_local" ]; then
        rc_local="/etc/rc.local"
        printf "#!/bin/sh\nexit 0\n" > "$rc_local"
        chmod +x "$rc_local"
      fi
      # 移除旧条目 / Remove old zram entries
      grep -v "zram" "$rc_local" > "${rc_local}.tmp" && mv "${rc_local}.tmp" "$rc_local"
      # 插入新条目（exit 0 前）/ Insert before exit 0
      if grep -q "^exit 0" "$rc_local"; then
        sed -i "s|^exit 0|modprobe zram 2>/dev/null\necho ${sel_algo} > /sys/block/zram0/comp_algorithm\necho ${sel_size}M > /sys/block/zram0/disksize\nmkswap /dev/zram0\nswapon -p 100 /dev/zram0\nexit 0|" "$rc_local" 2>/dev/null || \
          printf "modprobe zram 2>/dev/null\necho ${sel_algo} > /sys/block/zram0/comp_algorithm\necho ${sel_size}M > /sys/block/zram0/disksize\nmkswap /dev/zram0\nswapon -p 100 /dev/zram0\n" >> "$rc_local"
      else
        printf "modprobe zram 2>/dev/null\necho ${sel_algo} > /sys/block/zram0/comp_algorithm\necho ${sel_size}M > /sys/block/zram0/disksize\nmkswap /dev/zram0\nswapon -p 100 /dev/zram0\n" >> "$rc_local"
      fi
      _green "rc.local autostart entry added. / 已写入rc.local自启动条目。"
      ;;
  esac
}

# ────────────────────────────────────────────────
# 移除自启配置 / Remove autostart
# ────────────────────────────────────────────────
remove_autostart() {
  case "$INIT_SYS" in
    systemd)
      if [ -f /etc/systemd/system/zram.service ]; then
        systemctl stop zram.service 2>/dev/null || true
        systemctl disable zram.service 2>/dev/null || true
        rm -f /etc/systemd/system/zram.service
        systemctl daemon-reload
      fi
      rm -f /etc/modules-load.d/zram.conf /etc/modprobe.d/zram.conf
      ;;
    openrc)
      rc-update del zram default 2>/dev/null || true
      rm -f /etc/init.d/zram
      ;;
    runit)
      rm -f /var/service/zram
      rm -rf /etc/sv/zram
      ;;
    *)
      for f in /etc/rc.local /etc/rc.d/rc.local; do
        if [ -f "$f" ]; then
          grep -v "zram" "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
        fi
      done
      ;;
  esac
}

# ────────────────────────────────────────────────
# 显示系统状态 / Show system status
# ────────────────────────────────────────────────
show_status() {
  _blue "===== System Status / 系统状态 ====="

  if [ -f /proc/meminfo ]; then
    mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    mem_mb=$((mem_kb / 1024))
    mem_gb=$((mem_mb / 1024))
    _green ">> Physical Memory / 物理内存: ${mem_gb}GB (${mem_mb}MB)"
  fi

  _green ">> SWAP Status / SWAP状态:"
  if command -v swapon >/dev/null 2>&1; then
    swapon --show 2>/dev/null || cat /proc/swaps 2>/dev/null || echo "N/A"
  else
    cat /proc/swaps 2>/dev/null || echo "N/A"
  fi

  _green ">> Block Devices / 块设备信息:"
  if command -v lsblk >/dev/null 2>&1; then
    lsblk
  else
    ls /dev/zram* 2>/dev/null || echo "lsblk not available / lsblk不可用"
  fi

  _green ">> ZRAM Compression Algorithm / zRAM压缩算法:"
  cat /sys/block/zram0/comp_algorithm 2>/dev/null || echo "ZRAM not loaded / zRAM未加载"

  _green ">> ZRAM Size / zRAM大小:"
  if [ -f /sys/block/zram0/disksize ]; then
    size_bytes=$(cat /sys/block/zram0/disksize)
    human_readable_size "$size_bytes"
  else
    echo "ZRAM not loaded / zRAM未加载"
  fi

  _green ">> Memory Usage / 内存使用情况:"
  free -h 2>/dev/null || free 2>/dev/null || echo "free not available / free不可用"

  echo ""
  pause_continue
}

# ────────────────────────────────────────────────
# 添加 zRAM / Add zRAM
# ────────────────────────────────────────────────
add_zram() {
  check_zram_module
  ensure_util_linux
  parse_algorithms
  promote_zstd

  # 显示算法列表 / Show algorithm list
  _blue "Available compression algorithms / 可用压缩算法:"
  idx=0
  while IFS= read -r line; do
    _blue "  [$idx] $line"
    idx=$((idx + 1))
  done < "$ZRAM_ALGO_FILE"

  _green "Enter algorithm number (leave blank for default zstd) / 请输入算法序号(留空默认zstd):"
  reading "> " selected_index

  # 校验输入 / Validate input
  case "$selected_index" in
    ''|*[!0-9]*)
      selected_algorithm="zstd"
      ;;
    *)
      selected_algorithm=$(awk -v n="$selected_index" 'NR==n+1{print;exit}' "$ZRAM_ALGO_FILE")
      if [ -z "$selected_algorithm" ]; then
        _yellow "Invalid index, using zstd. / 无效序号，使用zstd。"
        selected_algorithm="zstd"
      fi
      ;;
  esac

  # 若算法不在支持列表则回退 / Fallback if unsupported
  if ! grep -qx "$selected_algorithm" "$ZRAM_ALGO_FILE" 2>/dev/null; then
    _yellow "Algorithm '$selected_algorithm' may not be supported, trying lzo as fallback."
    _yellow "算法 '$selected_algorithm' 可能不受支持，回退使用lzo。"
    selected_algorithm="lzo"
  fi

  # 推荐大小 / Recommended size
  recommended_size=$(calculate_zram_size)
  _green "Enter zRAM size in MB (leave blank for recommended ${recommended_size}MB) / 请输入zRAM大小(MB)(留空默认${recommended_size}MB):"
  reading "> " zram_size
  if [ -z "$zram_size" ]; then
    zram_size="$recommended_size"
  fi
  case "$zram_size" in
    *[!0-9]*|'')
      _yellow "Invalid size, using recommended ${recommended_size}MB. / 无效大小，使用推荐值${recommended_size}MB。"
      zram_size="$recommended_size"
      ;;
  esac

  # 已有 zram swap 则先移除 / Remove existing zram swap
  if grep -q "/dev/zram" /proc/swaps 2>/dev/null; then
    _yellow "ZRAM swap already active, removing first... / ZRAM swap已存在，先移除..."
    swapoff /dev/zram0 2>/dev/null || true
    if [ -f /sys/block/zram0/reset ]; then
      echo 1 > /sys/block/zram0/reset
    fi
    sleep 1
  fi

  # 配置 zRAM 设备 / Configure zRAM device
  if [ -d "/sys/block/zram0" ]; then
    if ! zramctl /dev/zram0 --algorithm "$selected_algorithm" --size "${zram_size}M"; then
      _red "zramctl failed. / zramctl执行失败。"
      exit 1
    fi
  else
    if ! zramctl --find --size "${zram_size}M" --algorithm "$selected_algorithm"; then
      _red "zramctl --find failed. / zramctl --find执行失败。"
      exit 1
    fi
  fi

  mkswap /dev/zram0
  swapon -p 100 /dev/zram0

  # 配置开机自启 / Setup autostart
  setup_autostart "$selected_algorithm" "$zram_size"

  _green "ZRAM setup complete: /dev/zram0  size=${zram_size}M  algorithm=${selected_algorithm}"
  _green "ZRAM设置成功: 设备=/dev/zram0  大小=${zram_size}M  算法=${selected_algorithm}"
  _green "Auto-start on boot has been configured. / 已配置开机自启动。"
  check_zram
}

# ────────────────────────────────────────────────
# 删除 zRAM / Delete zRAM
# ────────────────────────────────────────────────
del_zram() {
  if [ -e "$ZRAM_DEVICE" ] || grep -q "/dev/zram" /proc/swaps 2>/dev/null; then
    _yellow "Removing ZRAM device $ZRAM_DEVICE ... / 正在删除ZRAM设备 $ZRAM_DEVICE ..."
    remove_autostart
    swapoff /dev/zram0 2>/dev/null || true
    if [ -f /sys/block/zram0/reset ]; then
      echo 1 > /sys/block/zram0/reset
    fi
    if lsmod 2>/dev/null | grep -q "^zram"; then
      rmmod zram 2>/dev/null || true
    fi
    rm -f "$ZRAM_ALGO_FILE"
    _green "ZRAM deleted successfully! / ZRAM删除成功！"
  else
    _yellow "ZRAM device $ZRAM_DEVICE does not exist. / ZRAM设备 $ZRAM_DEVICE 不存在。"
  fi
  check_zram
}

# ────────────────────────────────────────────────
# 检查 zRAM 状态 / Check zRAM status
# ────────────────────────────────────────────────
check_zram() {
  _blue "===== ZRAM Status / ZRAM状态 ====="

  if lsmod 2>/dev/null | grep -q "^zram"; then
    _green ">> ZRAM module loaded / ZRAM模块已加载"
  else
    _yellow ">> ZRAM module not loaded / ZRAM模块未加载"
  fi

  if [ -e "$ZRAM_DEVICE" ]; then
    _green ">> ZRAM device exists / ZRAM设备存在"
    if command -v zramctl >/dev/null 2>&1; then
      zramctl
    fi
    echo ""

    if [ -f /sys/block/zram0/comp_algorithm ]; then
      _green ">> Compression algorithm / 压缩算法:"
      cat /sys/block/zram0/comp_algorithm
    fi

    if grep -q "$ZRAM_DEVICE" /proc/swaps 2>/dev/null; then
      _green ">> ZRAM swap enabled / ZRAM swap已启用"
      if command -v swapon >/dev/null 2>&1; then
        swapon --show 2>/dev/null || cat /proc/swaps
      else
        cat /proc/swaps
      fi
    else
      _yellow ">> ZRAM device exists but not used as swap / ZRAM设备存在但未用作swap"
    fi

    # 各 init 系统的服务状态 / Service status per init
    case "$INIT_SYS" in
      systemd)
        if [ -f /etc/systemd/system/zram.service ]; then
          _green ">> Systemd service status / systemd服务状态:"
          systemctl status zram.service --no-pager 2>/dev/null || true
        fi
        ;;
      openrc)
        if [ -f /etc/init.d/zram ]; then
          _green ">> OpenRC service status / OpenRC服务状态:"
          rc-service zram status 2>/dev/null || true
        fi
        ;;
      runit)
        if [ -L /var/service/zram ]; then
          _green ">> Runit service status / Runit服务状态:"
          sv status zram 2>/dev/null || true
        fi
        ;;
    esac
  else
    _yellow ">> ZRAM device does not exist / ZRAM设备不存在"
  fi

  echo ""
  pause_continue
}

# ────────────────────────────────────────────────
# 验证 zRAM 运行状态 / Verify zRAM operation
# ────────────────────────────────────────────────
verify_zram() {
  _blue "===== Verifying ZRAM / 验证zRAM状态 ====="
  all_ok=1

  if lsmod 2>/dev/null | grep -q "^zram"; then
    _green "ZRAM module is loaded. / ZRAM模块已加载。"
  else
    _red "ZRAM module is NOT loaded. / ZRAM模块未加载。"
    all_ok=0
  fi

  if [ -e /sys/block/zram0 ]; then
    _green "ZRAM device /dev/zram0 exists. / ZRAM设备/dev/zram0存在。"
  else
    _red "ZRAM device /dev/zram0 does NOT exist. / ZRAM设备/dev/zram0不存在。"
    all_ok=0
  fi

  if grep -q "/dev/zram0" /proc/swaps 2>/dev/null; then
    _green "ZRAM swap is active. / ZRAM swap已激活。"
    echo "Swap details / Swap详情:"
    grep "/dev/zram0" /proc/swaps
  else
    _red "ZRAM swap is NOT active. / ZRAM swap未激活。"
    all_ok=0
  fi

  case "$INIT_SYS" in
    systemd)
      if [ -f /etc/systemd/system/zram.service ]; then
        _green "Systemd service found. / 已找到systemd服务。"
        systemctl status zram.service --no-pager 2>/dev/null || true
      else
        _yellow "No systemd service found. / 未找到systemd服务。"
      fi
      ;;
    openrc)
      if [ -f /etc/init.d/zram ]; then
        _green "OpenRC service found. / 已找到OpenRC服务。"
      else
        _yellow "No OpenRC service found. / 未找到OpenRC服务。"
      fi
      ;;
    runit)
      if [ -L /var/service/zram ]; then
        _green "Runit service found. / 已找到Runit服务。"
      else
        _yellow "No Runit service found. / 未找到Runit服务。"
      fi
      ;;
    *)
      _yellow "Init system: sysv/rc.local / Init系统: sysv/rc.local"
      ;;
  esac

  if [ -f /sys/block/zram0/comp_algorithm ]; then
    _green "Compression algorithm / 压缩算法:"
    cat /sys/block/zram0/comp_algorithm
  fi

  if [ -f /sys/block/zram0/mm_stat ]; then
    _green "Memory statistics / 内存统计:"
    cat /sys/block/zram0/mm_stat
  fi

  if [ -f /sys/block/zram0/stat ]; then
    _green "IO statistics / IO统计:"
    cat /sys/block/zram0/stat
  fi

  echo ""
  if [ "$all_ok" = "1" ]; then
    _green "All checks passed! / 所有检查通过！"
  else
    _yellow "Some checks failed. Run option [1] to set up. / 部分检查未通过，请选择[1]进行配置。"
  fi

  echo ""
  pause_continue
}

# ────────────────────────────────────────────────
# 主菜单 / Main menu
# ────────────────────────────────────────────────
main() {
  check_root

  while true; do
    clear
    free -m 2>/dev/null || true
    _blue "Repository / 项目地址: ${REPO_URL}"
    echo "-------------------------------------------------------------"
    _green "Linux VPS one-click add/remove zram script"
    _green "Linux VPS 一键添加/删除 zram 脚本"
    echo "-------------------------------------------------------------"
    _green "[1] Add zRAM    / 添加zRAM"
    _green "[2] Remove zRAM / 删除zRAM"
    _green "[3] Show system status  / 查看系统详细状态"
    _green "[4] Verify zRAM status  / 验证zRAM运行状态"
    _green "[0] Exit / 退出"
    echo "-------------------------------------------------------------"
    reading "Please enter [0-4] / 请输入数字 [0-4]: " num
    case "$num" in
      1) add_zram ;;
      2) del_zram ;;
      3) show_status ;;
      4) verify_zram ;;
      0) _green "Bye! / 退出。"; exit 0 ;;
      *) _yellow "Invalid input, please retry. / 输入无效，请重新输入。" ;;
    esac
  done
}

main
