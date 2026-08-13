#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Debian 一键换源脚本
#
# 支持：Debian 11 / 12 / 13，以及 testing / unstable
# 功能：
#   - 交互选择常用镜像站
#   - 可选择源码源、安全源、updates、backports、proposed-updates
#   - 可选择 main / contrib / non-free / non-free-firmware
#   - 自动选择 DEB822 或传统 sources.list 格式
#   - 完整备份原配置
#   - apt update 失败时自动回滚
#
# 默认配置：
#   CERNET、HTTPS、完整组件、安全源、updates
#   不启用 deb-src、backports、proposed-updates
# ============================================================

SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="2.1.0"
KEYRING="/usr/share/keyrings/debian-archive-keyring.gpg"

MIRROR_KEY=""
CUSTOM_BASE_URL=""
CUSTOM_SECURITY_URL=""
SECURITY_MODE="mirror"
COMPONENT_MODE="full"
CUSTOM_COMPONENTS=""
SOURCE_FORMAT="auto"
USE_HTTPS=1
ENABLE_SOURCE=0
ENABLE_SECURITY=1
ENABLE_UPDATES=1
ENABLE_BACKPORTS=0
ENABLE_PROPOSED=0
RUN_APT_UPDATE=1
DRY_RUN=0
NON_INTERACTIVE=0

BACKUP_DIR=""
BACKUP_CREATED=0

C_RESET='\033[0m'
C_BLUE='\033[1;34m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[1;31m'

log() {
    printf '\n%b[%s]%b %s\n' "$C_BLUE" "$(date '+%H:%M:%S')" "$C_RESET" "$*"
}

ok() {
    printf '%b[OK]%b %s\n' "$C_GREEN" "$C_RESET" "$*"
}

warn() {
    printf '%b[警告]%b %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2
}

fatal() {
    printf '%b[错误]%b %s\n' "$C_RED" "$C_RESET" "$*" >&2
    exit 1
}

usage() {
    cat <<EOF_USAGE
用法：
  sudo bash ${SCRIPT_NAME}
  sudo bash ${SCRIPT_NAME} [选项]

镜像选项：
  --mirror NAME            cernet|tuna|ustc|aliyun|tencent|huawei|official|custom
  --base-url URL           自定义 Debian 主仓库地址
  --security-url URL       自定义 Debian Security 仓库地址
  --http                    使用 HTTP（默认 HTTPS）
  --https                   使用 HTTPS

仓库选项：
  --components MODE        main|full|custom
  --custom-components STR  例如："main contrib non-free non-free-firmware"
  --source / --no-source   启用或关闭 deb-src
  --security MODE          mirror|official|no
  --updates / --no-updates
  --backports / --no-backports
  --proposed / --no-proposed
  --format FORMAT          auto|deb822|list

执行选项：
  --no-update              写入配置后不执行 apt-get update
  --dry-run                仅显示将生成的配置，不修改系统
  -y, --non-interactive    兼容选项；传入任意参数时默认即为非交互模式
  -h, --help               显示帮助

示例：
  sudo bash ${SCRIPT_NAME}
  sudo bash ${SCRIPT_NAME} --mirror cernet --backports
  sudo bash ${SCRIPT_NAME} --mirror tuna --security official --source
  sudo bash ${SCRIPT_NAME} --mirror official --components main -y
EOF_USAGE
}

bool_text() {
    if [[ "$1" -eq 1 ]]; then
        printf '启用'
    else
        printf '关闭'
    fi
}

normalize_url() {
    local url="$1"
    url="${url%/}"
    if [[ "$USE_HTTPS" -eq 0 ]]; then
        url="${url/https:\/\//http://}"
    else
        url="${url/http:\/\//https://}"
    fi
    printf '%s' "$url"
}

prompt_yes_no() {
    local prompt="$1"
    local default="$2"
    local answer=""
    local hint="[y/N]"

    [[ "$default" -eq 1 ]] && hint="[Y/n]"

    while true; do
        read -r -p "$prompt $hint: " answer || true
        answer="${answer,,}"
        case "$answer" in
            y|yes|是) return 0 ;;
            n|no|否) return 1 ;;
            '') [[ "$default" -eq 1 ]] && return 0 || return 1 ;;
            *) printf '请输入 y 或 n。\n' ;;
        esac
    done
}

choose_mirror_interactive() {
    cat <<'EOF_MENU'

请选择 Debian 镜像站：
  1) CERNET 校园网联合镜像（默认）
  2) 清华 TUNA
  3) 中科大 USTC
  4) 阿里云
  5) 腾讯云
  6) 华为云
  7) Debian 官方 CDN
  8) 自定义地址
EOF_MENU

    local choice=""
    read -r -p '输入编号 [1]: ' choice || true
    case "${choice:-1}" in
        1) MIRROR_KEY="cernet" ;;
        2) MIRROR_KEY="tuna" ;;
        3) MIRROR_KEY="ustc" ;;
        4) MIRROR_KEY="aliyun" ;;
        5) MIRROR_KEY="tencent" ;;
        6) MIRROR_KEY="huawei" ;;
        7) MIRROR_KEY="official" ;;
        8)
            MIRROR_KEY="custom"
            read -r -p 'Debian 主仓库 URL: ' CUSTOM_BASE_URL
            read -r -p 'Debian Security URL（留空则使用官方）: ' CUSTOM_SECURITY_URL
            ;;
        *) fatal "无效的镜像编号：$choice" ;;
    esac
}

choose_components_interactive() {
    cat <<'EOF_COMPONENTS'

请选择仓库组件：
  1) 完整：main + contrib + non-free + non-free-firmware（默认）
  2) 纯自由软件：仅 main
  3) 自定义
EOF_COMPONENTS

    local choice=""
    read -r -p '输入编号 [1]: ' choice || true
    case "${choice:-1}" in
        1) COMPONENT_MODE="full" ;;
        2) COMPONENT_MODE="main" ;;
        3)
            COMPONENT_MODE="custom"
            read -r -p '组件列表，例如 main contrib non-free: ' CUSTOM_COMPONENTS
            ;;
        *) fatal "无效的组件编号：$choice" ;;
    esac
}

choose_security_interactive() {
    cat <<'EOF_SECURITY'

请选择安全更新源：
  1) 使用所选镜像站的 debian-security（默认，国内通常更快）
  2) 使用 Debian 官方 security.debian.org
  3) 不配置安全源（不推荐）
EOF_SECURITY

    local choice=""
    read -r -p '输入编号 [1]: ' choice || true
    case "${choice:-1}" in
        1) SECURITY_MODE="mirror"; ENABLE_SECURITY=1 ;;
        2) SECURITY_MODE="official"; ENABLE_SECURITY=1 ;;
        3) SECURITY_MODE="no"; ENABLE_SECURITY=0 ;;
        *) fatal "无效的安全源编号：$choice" ;;
    esac
}

choose_format_interactive() {
    cat <<'EOF_FORMAT'

请选择配置格式：
  1) 自动选择（Debian 12+ 使用 DEB822，Debian 11 使用 sources.list）
  2) DEB822：/etc/apt/sources.list.d/debian.sources
  3) 传统格式：/etc/apt/sources.list
EOF_FORMAT

    local choice=""
    read -r -p '输入编号 [1]: ' choice || true
    case "${choice:-1}" in
        1) SOURCE_FORMAT="auto" ;;
        2) SOURCE_FORMAT="deb822" ;;
        3) SOURCE_FORMAT="list" ;;
        *) fatal "无效的格式编号：$choice" ;;
    esac
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mirror)
                [[ $# -ge 2 ]] || fatal '--mirror 缺少参数'
                MIRROR_KEY="$2"; shift 2 ;;
            --base-url)
                [[ $# -ge 2 ]] || fatal '--base-url 缺少参数'
                CUSTOM_BASE_URL="$2"; shift 2 ;;
            --security-url)
                [[ $# -ge 2 ]] || fatal '--security-url 缺少参数'
                CUSTOM_SECURITY_URL="$2"; shift 2 ;;
            --http) USE_HTTPS=0; shift ;;
            --https) USE_HTTPS=1; shift ;;
            --components)
                [[ $# -ge 2 ]] || fatal '--components 缺少参数'
                COMPONENT_MODE="$2"; shift 2 ;;
            --custom-components)
                [[ $# -ge 2 ]] || fatal '--custom-components 缺少参数'
                COMPONENT_MODE="custom"; CUSTOM_COMPONENTS="$2"; shift 2 ;;
            --source) ENABLE_SOURCE=1; shift ;;
            --no-source) ENABLE_SOURCE=0; shift ;;
            --security)
                [[ $# -ge 2 ]] || fatal '--security 缺少参数'
                SECURITY_MODE="$2"
                [[ "$SECURITY_MODE" == "no" ]] && ENABLE_SECURITY=0 || ENABLE_SECURITY=1
                shift 2 ;;
            --updates) ENABLE_UPDATES=1; shift ;;
            --no-updates) ENABLE_UPDATES=0; shift ;;
            --backports) ENABLE_BACKPORTS=1; shift ;;
            --no-backports) ENABLE_BACKPORTS=0; shift ;;
            --proposed) ENABLE_PROPOSED=1; shift ;;
            --no-proposed) ENABLE_PROPOSED=0; shift ;;
            --format)
                [[ $# -ge 2 ]] || fatal '--format 缺少参数'
                SOURCE_FORMAT="$2"; shift 2 ;;
            --no-update) RUN_APT_UPDATE=0; shift ;;
            --dry-run) DRY_RUN=1; shift ;;
            -y|--non-interactive) NON_INTERACTIVE=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) fatal "未知参数：$1（使用 --help 查看帮助）" ;;
        esac
    done
}

validate_options() {
    case "$MIRROR_KEY" in
        cernet|tuna|ustc|aliyun|tencent|huawei|official|custom) ;;
        *) fatal "不支持的镜像名称：$MIRROR_KEY" ;;
    esac

    case "$SECURITY_MODE" in
        mirror|official|no) ;;
        *) fatal "--security 仅支持 mirror、official 或 no" ;;
    esac

    case "$COMPONENT_MODE" in
        main|full|custom) ;;
        *) fatal "--components 仅支持 main、full 或 custom" ;;
    esac

    case "$SOURCE_FORMAT" in
        auto|deb822|list) ;;
        *) fatal "--format 仅支持 auto、deb822 或 list" ;;
    esac

    if [[ "$MIRROR_KEY" == "custom" && -z "$CUSTOM_BASE_URL" ]]; then
        fatal '选择 custom 时必须提供 --base-url'
    fi
}

resolve_mirror_urls() {
    local base=""
    local security=""

    case "$MIRROR_KEY" in
        cernet)
            base='https://mirrors.cernet.edu.cn/debian'
            security='https://mirrors.cernet.edu.cn/debian-security'
            ;;
        tuna)
            base='https://mirrors.tuna.tsinghua.edu.cn/debian'
            security='https://mirrors.tuna.tsinghua.edu.cn/debian-security'
            ;;
        ustc)
            base='https://mirrors.ustc.edu.cn/debian'
            security='https://mirrors.ustc.edu.cn/debian-security'
            ;;
        aliyun)
            base='https://mirrors.aliyun.com/debian'
            security='https://mirrors.aliyun.com/debian-security'
            ;;
        tencent)
            base='https://mirrors.cloud.tencent.com/debian'
            security='https://mirrors.cloud.tencent.com/debian-security'
            ;;
        huawei)
            base='https://repo.huaweicloud.com/debian'
            security='https://repo.huaweicloud.com/debian-security'
            ;;
        official)
            base='https://deb.debian.org/debian'
            security='https://security.debian.org/debian-security'
            ;;
        custom)
            base="$CUSTOM_BASE_URL"
            security="${CUSTOM_SECURITY_URL:-https://security.debian.org/debian-security}"
            ;;
    esac

    BASE_URL="$(normalize_url "$base")"

    case "$SECURITY_MODE" in
        official)
            SECURITY_URL="$(normalize_url 'https://security.debian.org/debian-security')"
            ;;
        mirror)
            SECURITY_URL="$(normalize_url "$security")"
            ;;
        no)
            SECURITY_URL=""
            ;;
    esac
}

resolve_components() {
    case "$COMPONENT_MODE" in
        main)
            COMPONENTS='main'
            ;;
        full)
            COMPONENTS='main contrib non-free'
            if [[ "$VERSION_MAJOR" -ge 12 || "$VERSION_MAJOR" -eq 0 ]]; then
                COMPONENTS+=' non-free-firmware'
            fi
            ;;
        custom)
            [[ -n "$CUSTOM_COMPONENTS" ]] || fatal '自定义组件列表不能为空'
            COMPONENTS="$CUSTOM_COMPONENTS"
            ;;
    esac

    [[ " $COMPONENTS " == *' main '* ]] || fatal '组件列表必须包含 main'

    if [[ "$VERSION_MAJOR" -gt 0 && "$VERSION_MAJOR" -lt 12 && " $COMPONENTS " == *' non-free-firmware '* ]]; then
        warn "Debian ${VERSION_MAJOR} 没有独立的 non-free-firmware 组件，已自动移除。"
        COMPONENTS="$(printf '%s\n' "$COMPONENTS" | sed -E 's/(^|[[:space:]])non-free-firmware([[:space:]]|$)/ /g; s/[[:space:]]+/ /g; s/^ //; s/ $//')"
    fi
}

resolve_release_behavior() {
    SECURITY_SUITE="${CODENAME}-security"
    BASE_SUITES=("$CODENAME")

    local release_text="${PRETTY_NAME:-} ${VERSION:-} ${CODENAME}"
    release_text="${release_text,,}"

    if [[ "$CODENAME" == 'sid' || "$CODENAME" == 'unstable' || "$release_text" == *'/sid'* || "$release_text" == *'unstable'* ]]; then
        warn '检测到 Debian testing/unstable 开发分支：稳定版专用的 updates、安全源、backports 和 proposed-updates 已关闭。'
        ENABLE_SECURITY=0
        SECURITY_MODE='no'
        ENABLE_UPDATES=0
        ENABLE_BACKPORTS=0
        ENABLE_PROPOSED=0
        return
    fi

    if [[ "$CODENAME" == 'testing' || "$release_text" == *' testing'* ]]; then
        warn '检测到 testing 别名：仅配置基础仓库，避免生成不存在的稳定版附加套件。'
        ENABLE_SECURITY=0
        SECURITY_MODE='no'
        ENABLE_UPDATES=0
        ENABLE_BACKPORTS=0
        ENABLE_PROPOSED=0
        return
    fi

    [[ "$ENABLE_UPDATES" -eq 1 ]] && BASE_SUITES+=("${CODENAME}-updates")
    [[ "$ENABLE_BACKPORTS" -eq 1 ]] && BASE_SUITES+=("${CODENAME}-backports")
    [[ "$ENABLE_PROPOSED" -eq 1 ]] && BASE_SUITES+=("${CODENAME}-proposed-updates")
    return 0
}

resolve_source_format() {
    if [[ "$SOURCE_FORMAT" == 'auto' ]]; then
        if [[ "$VERSION_MAJOR" -ge 12 || "$VERSION_MAJOR" -eq 0 ]]; then
            SOURCE_FORMAT='deb822'
        else
            SOURCE_FORMAT='list'
        fi
    fi
}

make_deb822_config() {
    local types='deb'
    [[ "$ENABLE_SOURCE" -eq 1 ]] && types='deb deb-src'

    cat <<EOF_CONFIG
# Generated by ${SCRIPT_NAME} on $(date -Is)
# Debian: ${PRETTY_NAME}

Types: ${types}
URIs: ${BASE_URL}
Suites: ${BASE_SUITES[*]}
Components: ${COMPONENTS}
Signed-By: ${KEYRING}
EOF_CONFIG

    if [[ "$ENABLE_SECURITY" -eq 1 ]]; then
        cat <<EOF_CONFIG

Types: ${types}
URIs: ${SECURITY_URL}
Suites: ${SECURITY_SUITE}
Components: ${COMPONENTS}
Signed-By: ${KEYRING}
EOF_CONFIG
    fi
}

make_legacy_config() {
    local type
    local suite

    printf '# Generated by %s on %s\n' "$SCRIPT_NAME" "$(date -Is)"
    printf '# Debian: %s\n\n' "$PRETTY_NAME"

    for suite in "${BASE_SUITES[@]}"; do
        printf 'deb %s %s %s\n' "$BASE_URL" "$suite" "$COMPONENTS"
        if [[ "$ENABLE_SOURCE" -eq 1 ]]; then
            printf 'deb-src %s %s %s\n' "$BASE_URL" "$suite" "$COMPONENTS"
        fi
    done

    if [[ "$ENABLE_SECURITY" -eq 1 ]]; then
        printf '\n# Security updates\n'
        printf 'deb %s %s %s\n' "$SECURITY_URL" "$SECURITY_SUITE" "$COMPONENTS"
        if [[ "$ENABLE_SOURCE" -eq 1 ]]; then
            printf 'deb-src %s %s %s\n' "$SECURITY_URL" "$SECURITY_SUITE" "$COMPONENTS"
        fi
    fi
}

backup_sources() {
    BACKUP_DIR="/root/apt-sources-backup-$(date '+%Y%m%d-%H%M%S')"
    mkdir -p "$BACKUP_DIR"

    if [[ -e /etc/apt/sources.list ]]; then
        cp -a /etc/apt/sources.list "$BACKUP_DIR/sources.list"
    else
        : > "$BACKUP_DIR/.sources-list-was-absent"
    fi

    if [[ -d /etc/apt/sources.list.d ]]; then
        cp -a /etc/apt/sources.list.d "$BACKUP_DIR/sources.list.d"
    else
        : > "$BACKUP_DIR/.sources-list-d-was-absent"
    fi

    BACKUP_CREATED=1
    ok "原 APT 配置已备份到：$BACKUP_DIR"
}

restore_sources() {
    [[ "$BACKUP_CREATED" -eq 1 ]] || return 0

    warn '正在恢复换源前的 APT 配置……'
    rm -f /etc/apt/sources.list
    rm -rf /etc/apt/sources.list.d

    if [[ -f "$BACKUP_DIR/sources.list" ]]; then
        cp -a "$BACKUP_DIR/sources.list" /etc/apt/sources.list
    fi

    if [[ -d "$BACKUP_DIR/sources.list.d" ]]; then
        cp -a "$BACKUP_DIR/sources.list.d" /etc/apt/sources.list.d
    else
        mkdir -p /etc/apt/sources.list.d
    fi

    ok '原 APT 配置已恢复。'
}

comment_debian_lines_in_legacy_file() {
    local file="$1"
    [[ -f "$file" ]] || return 0

    # 仅注释标准 Debian 主仓库与安全仓库行；Docker、PGDG 等第三方仓库不受影响。
    sed -Ei \
        '/^[[:space:]]*deb(-src)?([[:space:]]+\[[^]]+\])?[[:space:]]+https?:\/\/[^[:space:]]+\/(debian|debian-security)\/?[[:space:]]/ s|^|# disabled-by-debian-source-switcher: |' \
        "$file"
}

remove_previous_managed_block() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    sed -i \
        '/^# BEGIN DEBIAN-SOURCE-SWITCHER$/,/^# END DEBIAN-SOURCE-SWITCHER$/d' \
        "$file"
}

write_sources() {
    mkdir -p /etc/apt/sources.list.d

    # 清理本脚本的旧输出。
    rm -f /etc/apt/sources.list.d/00-debian-source-switcher.sources

    # 注释传统格式中已有的 Debian 官方仓库行，保留第三方仓库。
    comment_debian_lines_in_legacy_file /etc/apt/sources.list
    local list_file
    shopt -s nullglob
    for list_file in /etc/apt/sources.list.d/*.list; do
        comment_debian_lines_in_legacy_file "$list_file"
    done
    shopt -u nullglob

    if [[ "$SOURCE_FORMAT" == 'deb822' ]]; then
        # Debian 官方镜像/容器的标准文件通常仅包含 Debian 自身仓库，可安全替换。
        if [[ -f /etc/apt/sources.list.d/debian.sources ]]; then
            rm -f /etc/apt/sources.list.d/debian.sources
        fi

        make_deb822_config > /etc/apt/sources.list.d/debian.sources
        chmod 0644 /etc/apt/sources.list.d/debian.sources
        ok '已写入 /etc/apt/sources.list.d/debian.sources'
    else
        # 传统格式写入 sources.list 的受管块，并保留文件中的第三方仓库。
        touch /etc/apt/sources.list
        remove_previous_managed_block /etc/apt/sources.list
        {
            printf '\n# BEGIN DEBIAN-SOURCE-SWITCHER\n'
            make_legacy_config
            printf '# END DEBIAN-SOURCE-SWITCHER\n'
        } >> /etc/apt/sources.list
        chmod 0644 /etc/apt/sources.list

        # 避免标准 DEB822 文件与传统配置重复。
        rm -f /etc/apt/sources.list.d/debian.sources
        ok '已写入 /etc/apt/sources.list'
    fi
}

validate_new_debian_sources() {
    local tmp_dir sourceparts_dir tmp_source
    tmp_dir="$(mktemp -d /tmp/debian-source-switcher.XXXXXX)"
    sourceparts_dir="$tmp_dir/sourceparts"
    mkdir -p "$sourceparts_dir"

    # APT 对 sourceparts 目录中的文件严格按照扩展名识别格式：
    #   *.sources -> DEB822
    #   *.list    -> 传统单行格式
    # 主 sources.list 指向 /dev/null，确保只验证本脚本生成的新 Debian 源。
    if [[ "$SOURCE_FORMAT" == 'deb822' ]]; then
        tmp_source="$sourceparts_dir/debian.sources"
        make_deb822_config > "$tmp_source"
    else
        tmp_source="$sourceparts_dir/debian.list"
        make_legacy_config > "$tmp_source"
    fi

    printf '[调试] 验证配置文件：%s\n' "$tmp_source"

    if ! apt-get \
        -o 'Dir::Etc::sourcelist=/dev/null' \
        -o "Dir::Etc::sourceparts=$sourceparts_dir" \
        -o 'APT::Get::List-Cleanup=0' \
        update; then
        rm -rf "$tmp_dir"
        return 1
    fi

    rm -rf "$tmp_dir"
    return 0
}

show_summary() {
    cat <<EOF_SUMMARY

=================== 配置预览 ===================
系统：             ${PRETTY_NAME}
代号：             ${CODENAME}
镜像：             ${MIRROR_KEY}
主仓库：           ${BASE_URL}
安全仓库：         ${SECURITY_URL:-未配置}
格式：             ${SOURCE_FORMAT}
组件：             ${COMPONENTS}
源码包 deb-src：   $(bool_text "$ENABLE_SOURCE")
安全更新：         $(bool_text "$ENABLE_SECURITY")
常规 updates：     $(bool_text "$ENABLE_UPDATES")
Backports：        $(bool_text "$ENABLE_BACKPORTS")
Proposed updates： $(bool_text "$ENABLE_PROPOSED")
执行 apt update：  $(bool_text "$RUN_APT_UPDATE")
================================================
EOF_SUMMARY

    if [[ "$SOURCE_FORMAT" == 'deb822' ]]; then
        printf '\n--- /etc/apt/sources.list.d/debian.sources ---\n'
        make_deb822_config
    else
        printf '\n--- 传统 sources.list 受管配置块 ---\n'
        make_legacy_config
    fi
}

main() {
    printf "Debian Source Switcher v%s\n" "$SCRIPT_VERSION"
    # 无参数时进入交互菜单；传入任何参数时按命令行模式执行，未指定项使用默认值。
    [[ $# -gt 0 ]] && NON_INTERACTIVE=1
    parse_args "$@"

    [[ ${EUID} -eq 0 || "$DRY_RUN" -eq 1 ]] || fatal '请使用 root 用户运行此脚本。'
    [[ -r /etc/os-release ]] || fatal '无法读取 /etc/os-release。'

    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == 'debian' ]] || fatal "本脚本仅支持 Debian，当前系统：${PRETTY_NAME:-unknown}"

    CODENAME="${VERSION_CODENAME:-}"
    if [[ -z "$CODENAME" ]]; then
        CODENAME="$(. /etc/os-release; printf '%s' "${DEBIAN_CODENAME:-}")"
    fi
    [[ -n "$CODENAME" ]] || fatal '无法识别 Debian 版本代号。'

    VERSION_MAJOR=0
    if [[ "${VERSION_ID:-}" =~ ^([0-9]+) ]]; then
        VERSION_MAJOR="${BASH_REMATCH[1]}"
    fi

    if [[ "$VERSION_MAJOR" -gt 0 && "$VERSION_MAJOR" -lt 11 ]]; then
        fatal "Debian ${VERSION_MAJOR} 已结束常规支持并可能迁入 archive.debian.org；本脚本仅自动支持 Debian 11 及以上。"
    fi

    if [[ "$NON_INTERACTIVE" -eq 0 && -t 0 ]]; then
        [[ -n "$MIRROR_KEY" ]] || choose_mirror_interactive

        if prompt_yes_no '使用 HTTPS 软件源？' 1; then USE_HTTPS=1; else USE_HTTPS=0; fi
        choose_components_interactive
        choose_security_interactive

        if prompt_yes_no '启用源码包索引 deb-src？' 0; then ENABLE_SOURCE=1; else ENABLE_SOURCE=0; fi
        if prompt_yes_no '启用常规 updates 仓库？' 1; then ENABLE_UPDATES=1; else ENABLE_UPDATES=0; fi
        if prompt_yes_no '启用 backports 仓库？' 0; then ENABLE_BACKPORTS=1; else ENABLE_BACKPORTS=0; fi
        if prompt_yes_no '启用 proposed-updates 测试仓库？' 0; then ENABLE_PROPOSED=1; else ENABLE_PROPOSED=0; fi
        choose_format_interactive
        if prompt_yes_no '写入后执行 apt-get update 验证？' 1; then RUN_APT_UPDATE=1; else RUN_APT_UPDATE=0; fi
    else
        MIRROR_KEY="${MIRROR_KEY:-cernet}"
    fi

    validate_options
    resolve_components
    resolve_release_behavior
    resolve_source_format
    resolve_mirror_urls
    show_summary

    if [[ "$DRY_RUN" -eq 1 ]]; then
        ok 'Dry-run 完成，未修改系统。'
        exit 0
    fi

    if [[ "$NON_INTERACTIVE" -eq 0 && -t 0 ]]; then
        if ! prompt_yes_no '确认应用以上配置？' 1; then
            printf '已取消。\n'
            exit 0
        fi
    fi

    backup_sources
    write_sources

    if [[ "$RUN_APT_UPDATE" -eq 1 ]]; then
        log '单独验证新 Debian 软件源'
        if ! validate_new_debian_sources; then
            restore_sources
            fatal "新 Debian 软件源验证失败，已自动回滚。备份仍保留在：$BACKUP_DIR"
        fi
        ok '新 Debian 软件源验证成功。'

        log '更新全部 APT 仓库索引'
        if apt-get update; then
            ok '全部 APT 仓库索引更新成功。'
        else
            warn 'Debian 新源已验证成功，但某个现有第三方仓库更新失败；配置未回滚，请检查上方 apt 输出。'
        fi
    fi

    cat <<EOF_DONE

换源完成。
配置格式：${SOURCE_FORMAT}
备份目录：${BACKUP_DIR}

恢复命令（需要时手动执行）：
  rm -f /etc/apt/sources.list
  rm -rf /etc/apt/sources.list.d
  cp -a ${BACKUP_DIR}/sources.list /etc/apt/sources.list 2>/dev/null || true
  cp -a ${BACKUP_DIR}/sources.list.d /etc/apt/sources.list.d 2>/dev/null || mkdir -p /etc/apt/sources.list.d
EOF_DONE
}

main "$@"
