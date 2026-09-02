#!/usr/bin/env bash

# Linux Hardware BOM
# Usage:
#   bash script.sh              # 输出到终端
#   sudo bash script.sh         # 获取完整 DIMM / DMI / NVMe 信息
#   bash script.sh -o out.txt   # 同时保存到文件
#
# 推荐 sudo 运行，否则 dmidecode / NVMe / DIMM 信息可能不完整。

set -u

export LC_ALL=C

OUT_FILE=""
while getopts "o:h" opt; do
    case "$opt" in
        o) OUT_FILE="$OPTARG" ;;
        h)
            echo "Usage: bash script.sh [-o output_file]"
            echo "  -o FILE   将报告同时写入 FILE（终端仍会输出）"
            exit 0
            ;;
        *)
            echo "Usage: bash script.sh [-o output_file]" >&2
            exit 1
            ;;
    esac
done
shift $((OPTIND - 1))

if [ -n "$OUT_FILE" ] && ! touch "$OUT_FILE" 2>/dev/null; then
    echo "ERROR: 无法写入输出文件: $OUT_FILE" >&2
    exit 1
fi

# 统一输出：终端与可选文件
emit() {
    printf '%s\n' "$*"
    if [ -n "$OUT_FILE" ]; then
        printf '%s\n' "$*" >>"$OUT_FILE"
    fi
}

line() {
    local width="${COLUMNS:-100}"
    printf '%*s\n' "$width" '' | tr ' ' '-'
    if [ -n "$OUT_FILE" ]; then
        printf '%*s\n' "$width" '' | tr ' ' '-' >>"$OUT_FILE"
    fi
}

section() {
    emit ""
    line
    emit "## $1"
    line
}

have() {
    command -v "$1" >/dev/null 2>&1
}

clean() {
    sed \
        -e 's/^[[:space:]]*//' \
        -e 's/[[:space:]]*$//'
}

is_root() {
    [ "$(id -u)" -eq 0 ]
}

dmi_value() {
    local type="$1"
    if have dmidecode && is_root; then
        dmidecode -s "$type" 2>/dev/null | head -n1 | clean
    elif [ -r "/sys/class/dmi/id/${type//-/_}" ]; then
        clean <"/sys/class/dmi/id/${type//-/_}" 2>/dev/null
    fi
}

kv() {
    emit "$(printf '%-22s %s' "$1:" "${2-}")"
}

emit "Linux Hardware BOM"
emit "Generated: $(date '+%Y-%m-%d %H:%M:%S %z')"
emit "Hostname : $(hostname)"
emit "Kernel   : $(uname -srmo)"

if ! is_root; then
    emit ""
    emit "WARNING: 建议使用 sudo 运行，以获取完整 DIMM / DMI / NVMe 信息。"
fi

# ============================================================
# SYSTEM
# ============================================================

section "SYSTEM"

kv "Manufacturer" "$(dmi_value system-manufacturer)"
kv "Product" "$(dmi_value system-product-name)"
kv "Version" "$(dmi_value system-version)"
kv "Serial" "$(dmi_value system-serial-number)"
kv "UUID" "$(dmi_value system-uuid)"

if have hostnamectl; then
    while IFS= read -r l; do emit "$l"; done < <(
        hostnamectl 2>/dev/null | grep -E \
            'Operating System|Kernel|Architecture|Hardware Vendor|Hardware Model' || true
    )
fi

# ============================================================
# MOTHERBOARD
# ============================================================

section "MOTHERBOARD"

kv "Manufacturer" "$(dmi_value baseboard-manufacturer)"
kv "Product" "$(dmi_value baseboard-product-name)"
kv "Version" "$(dmi_value baseboard-version)"
kv "Serial" "$(dmi_value baseboard-serial-number)"

# ============================================================
# BIOS / UEFI
# ============================================================

section "BIOS / UEFI"

kv "Vendor" "$(dmi_value bios-vendor)"
kv "Version" "$(dmi_value bios-version)"
kv "Release Date" "$(dmi_value bios-release-date)"

if [ -d /sys/firmware/efi ]; then
    emit "Boot Mode:             UEFI"
else
    emit "Boot Mode:             Legacy BIOS / unknown"
fi

# ============================================================
# CPU
# ============================================================

section "CPU"

if have lscpu; then
    while IFS= read -r l; do emit "$l"; done < <(
        lscpu | grep -E \
            '^(Architecture|CPU\(s\)|On-line CPU|Model name|Socket\(s\)|Core\(s\) per socket|Thread\(s\) per core|Vendor ID|CPU max MHz|CPU min MHz|L1d cache|L1i cache|L2 cache|L3 cache|NUMA node\(s\)):' ||
            true
    )
else
    emit "$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null || true)"
fi

# ============================================================
# MEMORY SUMMARY
# ============================================================

section "MEMORY SUMMARY"

if have free; then
    while IFS= read -r l; do emit "$l"; done < <(free -h)
fi

if [ -r /proc/meminfo ]; then
    awk '/^MemTotal:/ { printf "Physical RAM: %.2f GiB\n", $2/1024/1024 }' /proc/meminfo |
        while IFS= read -r l; do emit "$l"; done
fi

# ============================================================
# MEMORY DIMMS
# ============================================================

section "MEMORY DIMMS"

if have dmidecode && is_root; then

    dmidecode -t memory 2>/dev/null | awk '
        /^Memory Device$/ {
            if (active) print ""
            active=1
            size=""; locator=""; bank=""; type=""; speed=""
            configured=""; manufacturer=""; serial=""; part=""; rank=""
        }

        active && /^[[:space:]]+Size:/                     { sub(/^[[:space:]]+/,""); size=$0 }
        active && /^[[:space:]]+Locator:/ && locator==""   { sub(/^[[:space:]]+/,""); locator=$0 }
        active && /^[[:space:]]+Bank Locator:/             { sub(/^[[:space:]]+/,""); bank=$0 }
        active && /^[[:space:]]+Type:/                     { sub(/^[[:space:]]+/,""); type=$0 }
        active && /^[[:space:]]+Speed:/ && speed==""       { sub(/^[[:space:]]+/,""); speed=$0 }
        active && /^[[:space:]]+Configured Memory Speed:/  { sub(/^[[:space:]]+/,""); configured=$0 }
        active && /^[[:space:]]+Manufacturer:/             { sub(/^[[:space:]]+/,""); manufacturer=$0 }
        active && /^[[:space:]]+Serial Number:/            { sub(/^[[:space:]]+/,""); serial=$0 }
        active && /^[[:space:]]+Part Number:/              { sub(/^[[:space:]]+/,""); part=$0 }
        active && /^[[:space:]]+Rank:/                     { sub(/^[[:space:]]+/,""); rank=$0 }

        /^$/ && active {
            if (size !~ /No Module Installed/) {
                print locator
                if (bank!="")         print "  " bank
                if (size!="")         print "  " size
                if (type!="")         print "  " type
                if (speed!="")        print "  " speed
                if (configured!="")   print "  " configured
                if (manufacturer!="") print "  " manufacturer
                if (part!="")         print "  " part
                if (serial!="")       print "  " serial
                if (rank!="")         print "  " rank
                print ""
            }
            active=0
        }
    ' | while IFS= read -r l; do emit "$l"; done

elif have dmidecode; then
    emit "DIMM SPD/DMI information requires root:"
    emit "  sudo bash script.sh"
else
    emit "DIMM SPD/DMI information requires:"
    emit "  sudo + dmidecode"
fi

# ============================================================
# GPU
# ============================================================

section "GPU"

if have lspci; then
    while IFS= read -r l; do emit "$l"; done < <(
        lspci -nn | grep -Ei \
            'VGA compatible controller|3D controller|Display controller' ||
            echo "No PCI GPU detected."
    )
else
    emit "lspci unavailable."
fi

if have nvidia-smi; then
    emit ""
    emit "NVIDIA:"
    while IFS= read -r l; do emit "$l"; done < <(
        nvidia-smi \
            --query-gpu=index,name,pci.bus_id,memory.total,vbios_version,serial,power.limit \
            --format=csv,noheader 2>/dev/null || true
    )
fi

if have rocm-smi; then
    emit ""
    emit "AMD ROCm:"
    while IFS= read -r l; do emit "$l"; done < <(
        rocm-smi --showproductname --showserial --showmeminfo vram 2>/dev/null || true
    )
fi

# ============================================================
# STORAGE
# ============================================================

section "STORAGE"

if have lsblk; then
    lsblk -d -o NAME,MODEL,SERIAL,SIZE,ROTA,TYPE,TRAN,REV 2>/dev/null |
        while IFS= read -r l; do emit "$l"; done
else
    emit "lsblk unavailable."
fi

# ============================================================
# NVME
# ============================================================

section "NVME"

if have nvme; then

    nvme list 2>/dev/null | while IFS= read -r l; do emit "$l"; done

else

    found=0

    for dev in /sys/class/nvme/nvme*; do
        [ -d "$dev" ] || continue

        found=1

        emit "$(basename "$dev")"

        [ -r "$dev/model" ] &&
            emit "  Model:    $(clean <"$dev/model")"

        [ -r "$dev/serial" ] &&
            emit "  Serial:   $(clean <"$dev/serial")"

        [ -r "$dev/firmware_rev" ] &&
            emit "  Firmware: $(clean <"$dev/firmware_rev")"

        emit ""
    done

    [ "$found" -eq 0 ] && emit "No NVMe controller detected."

fi

# ============================================================
# NETWORK
# ============================================================

section "NETWORK"

if have lspci; then
    while IFS= read -r l; do emit "$l"; done < <(
        lspci -nn | grep -Ei \
            'Ethernet controller|Network controller|Wireless controller' || true
    )
fi

emit ""

for iface in /sys/class/net/*; do

    name="$(basename "$iface")"

    [ "$name" = "lo" ] && continue

    emit "$name"

    if [ -r "$iface/address" ]; then
        emit "  MAC:       $(cat "$iface/address")"
    fi

    if have ethtool; then

        info="$(ethtool -i "$name" 2>/dev/null || true)"
        driver="$(awk -F': ' '/^driver:/ {print $2}' <<<"$info")"
        firmware="$(awk -F': ' '/^firmware-version:/ {print $2}' <<<"$info")"
        bus="$(awk -F': ' '/^bus-info:/ {print $2}' <<<"$info")"

        [ -n "$driver" ] && emit "  Driver:    $driver"
        [ -n "$firmware" ] && emit "  Firmware:  $firmware"
        [ -n "$bus" ] && emit "  PCI:       $bus"

        speed="$(ethtool "$name" 2>/dev/null | awk -F': ' '/Speed:/ {print $2}')"
        [ -n "$speed" ] && emit "  Link:      $speed"
    fi

    if have ip; then
        ipv4="$(ip -4 -o addr show dev "$name" 2>/dev/null | awk '{print $4}' | paste -sd ',' -)"
        [ -n "$ipv4" ] && emit "  IPv4:      $ipv4"

        ipv6="$(ip -6 -o addr show dev "$name" scope global 2>/dev/null | awk '{print $4}' | paste -sd ',' -)"
        [ -n "$ipv6" ] && emit "  IPv6:      $ipv6"
    fi

    emit ""
done

# ============================================================
# TEMPERATURES (optional)
# ============================================================

if have sensors; then
    section "TEMPERATURES"
    while IFS= read -r l; do emit "$l"; done < <(
        sensors 2>/dev/null | grep -E '^(Tdie|Tctl|Package id [0-9]+|Composite|temp1|CPU|GPU|acpitz|Core [0-9]+)' || true
    )
fi

# ============================================================
# PCI DEVICES
# ============================================================

section "PCI / PCIE DEVICES"

if have lspci; then
    lspci -nn | while IFS= read -r l; do emit "$l"; done
else
    emit "lspci unavailable."
fi

# ============================================================
# USB DEVICES
# ============================================================

section "USB DEVICES"

if have lsusb; then
    lsusb | while IFS= read -r l; do emit "$l"; done
else
    emit "lsusb unavailable."
fi

# ============================================================
# HARDWARE VIRTUALIZATION
# ============================================================

section "VIRTUALIZATION"

if have systemd-detect-virt; then
    virt="$(systemd-detect-virt 2>/dev/null || true)"

    if [ "$virt" = "none" ] || [ -z "$virt" ]; then
        emit "Environment: Physical machine"
    else
        emit "Environment: $virt"
    fi
fi

if have lscpu; then
    while IFS= read -r l; do emit "$l"; done < <(
        lscpu | grep -E '^(Virtualization|Hypervisor vendor|Virtualization type):' || true
    )
fi

# ============================================================
# FINAL
# ============================================================

section "END"

emit "Hardware BOM collection completed."

if [ -n "$OUT_FILE" ]; then
    echo "Report saved to: $OUT_FILE"
fi
