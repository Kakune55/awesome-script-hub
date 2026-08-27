#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Caddy Fresh Installer
#
# 安装布局：
#
#   /usr/local/bin/caddy
#   /usr/local/bin/xcaddy
#
#   /etc/caddy/Caddyfile
#   /etc/caddy/caddy.env
#
#   /var/lib/caddy
#
#   /etc/systemd/system/caddy.service
#
# 用法：
#
#   标准版：
#       sudo ./install-caddy.sh
#
#   Cloudflare DNS：
#       sudo ./install-caddy.sh cloudflare
#
#   自定义模块：
#       sudo ./install-caddy.sh \
#           github.com/caddy-dns/cloudflare \
#           github.com/mholt/caddy-l4
#
# ============================================================


# ------------------------------------------------------------
# 基本配置
# ------------------------------------------------------------

CADDY_BIN="/usr/local/bin/caddy"
XCADDY_BIN="/usr/local/bin/xcaddy"

CADDY_USER="caddy"
CADDY_GROUP="caddy"

CADDY_CONFIG_DIR="/etc/caddy"
CADDY_CONFIG="${CADDY_CONFIG_DIR}/Caddyfile"
CADDY_ENV="${CADDY_CONFIG_DIR}/caddy.env"

CADDY_HOME="/var/lib/caddy"

SYSTEMD_UNIT="/etc/systemd/system/caddy.service"

BUILD_DIR=""


# ------------------------------------------------------------
# 输出函数
# ------------------------------------------------------------

log() {
    echo
    echo "==> $*"
}

die() {
    echo
    echo "ERROR: $*" >&2
    exit 1
}

cleanup() {
    if [[ -n "${BUILD_DIR}" && -d "${BUILD_DIR}" ]]; then
        rm -rf "${BUILD_DIR}"
    fi
}

trap cleanup EXIT


# ------------------------------------------------------------
# Root 检查
# ------------------------------------------------------------

[[ "${EUID}" -eq 0 ]] || die "请使用 root 运行此脚本"


# ------------------------------------------------------------
# 平台检查
# ------------------------------------------------------------

command -v apt-get >/dev/null 2>&1 \
    || die "当前脚本仅支持 Debian / Ubuntu 系发行版"


# ------------------------------------------------------------
# 解析模块
# ------------------------------------------------------------

MODULES=()

for module in "$@"; do

    case "${module}" in

        cloudflare)
            MODULES+=("github.com/caddy-dns/cloudflare")
            ;;

        default)
            ;;

        *)
            MODULES+=("${module}")
            ;;

    esac

done


log "准备安装 Caddy"

if [[ "${#MODULES[@]}" -eq 0 ]]; then

    echo "构建类型：标准 Caddy"

else

    echo "构建类型：自定义 Caddy"
    echo

    for module in "${MODULES[@]}"; do
        echo "  + ${module}"
    done

fi


# ------------------------------------------------------------
# 安装编译环境
# ------------------------------------------------------------

log "安装编译依赖"

apt-get update

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates \
    curl \
    git \
    golang-go \
    build-essential


# ------------------------------------------------------------
# 检查 Go
# ------------------------------------------------------------

command -v go >/dev/null 2>&1 \
    || die "Go 安装失败"

log "Go 环境"

go version


# ------------------------------------------------------------
# 安装 / 更新 xcaddy
# ------------------------------------------------------------

log "安装 xcaddy"

GOBIN=/usr/local/bin \
    go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest

[[ -x "${XCADDY_BIN}" ]] \
    || die "xcaddy 安装失败"

echo "xcaddy: ${XCADDY_BIN}"


# ------------------------------------------------------------
# 编译 Caddy
# ------------------------------------------------------------

log "编译 Caddy"

BUILD_DIR="$(mktemp -d)"

BUILD_ARGS=()

for module in "${MODULES[@]}"; do
    BUILD_ARGS+=(
        --with "${module}"
    )
done

(
    cd "${BUILD_DIR}"

    "${XCADDY_BIN}" build "${BUILD_ARGS[@]}"
)

[[ -x "${BUILD_DIR}/caddy" ]] \
    || die "Caddy 编译失败"


# ------------------------------------------------------------
# 安装 Caddy binary
# ------------------------------------------------------------

log "安装 Caddy"

install \
    -o root \
    -g root \
    -m 0755 \
    "${BUILD_DIR}/caddy" \
    "${CADDY_BIN}"

echo "Binary: ${CADDY_BIN}"


# ------------------------------------------------------------
# 创建 Caddy 用户
# ------------------------------------------------------------

log "创建运行用户"

if ! getent group "${CADDY_GROUP}" >/dev/null; then

    groupadd \
        --system \
        "${CADDY_GROUP}"

fi


if ! id "${CADDY_USER}" >/dev/null 2>&1; then

    useradd \
        --system \
        --gid "${CADDY_GROUP}" \
        --home-dir "${CADDY_HOME}" \
        --shell /usr/sbin/nologin \
        "${CADDY_USER}"

fi


# ------------------------------------------------------------
# 创建目录
# ------------------------------------------------------------

log "创建目录"

install \
    -d \
    -o root \
    -g "${CADDY_GROUP}" \
    -m 0750 \
    "${CADDY_CONFIG_DIR}"

install \
    -d \
    -o "${CADDY_USER}" \
    -g "${CADDY_GROUP}" \
    -m 0750 \
    "${CADDY_HOME}"


# ------------------------------------------------------------
# 创建默认 Caddyfile
#
# 不覆盖已有配置。
#
# 使用 2015 作为安装验证端口，
# 避免安装时直接占用公网 80/443。
# ------------------------------------------------------------

CREATED_DEFAULT_CONFIG=0

if [[ ! -f "${CADDY_CONFIG}" ]]; then

    log "创建默认 Caddyfile"

    cat > "${CADDY_CONFIG}" <<'EOF'
:2015 {
    respond "Caddy is running"
}
EOF

    chown root:"${CADDY_GROUP}" "${CADDY_CONFIG}"
    chmod 0640 "${CADDY_CONFIG}"

    CREATED_DEFAULT_CONFIG=1

else

    log "保留已有 Caddyfile"

fi


# ------------------------------------------------------------
# 创建环境变量文件
#
# 这里以后可以写：
#
# CF_API_TOKEN=xxxxxxxx
#
# Caddyfile：
#
# tls {
#     dns cloudflare {env.CF_API_TOKEN}
# }
#
# ------------------------------------------------------------

if [[ ! -f "${CADDY_ENV}" ]]; then

    log "创建环境变量文件"

    cat > "${CADDY_ENV}" <<'EOF'
# Caddy environment variables
#
# Example:
#
# CF_API_TOKEN=xxxxxxxxxxxxxxxx
#
EOF

    chown root:"${CADDY_GROUP}" "${CADDY_ENV}"
    chmod 0640 "${CADDY_ENV}"

fi


# ------------------------------------------------------------
# 创建 systemd Service
#
# 基于 Caddy 官方 systemd unit。
#
# 特意不加 --environ：
# 避免把 API Token 等环境变量输出进 journal。
# ------------------------------------------------------------

log "创建 systemd service"

cat > "${SYSTEMD_UNIT}" <<EOF
[Unit]
Description=Caddy
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify

User=${CADDY_USER}
Group=${CADDY_GROUP}

Environment=HOME=${CADDY_HOME}
EnvironmentFile=-${CADDY_ENV}

ExecStart=${CADDY_BIN} run --config ${CADDY_CONFIG}
ExecReload=${CADDY_BIN} reload --config ${CADDY_CONFIG} --force

TimeoutStopSec=5s
LimitNOFILE=1048576

PrivateTmp=true
ProtectSystem=full

AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

chmod 0644 "${SYSTEMD_UNIT}"


# ------------------------------------------------------------
# 验证 Binary
# ------------------------------------------------------------

log "验证 Caddy binary"

"${CADDY_BIN}" version

echo
echo "已编译模块："

if [[ "${#MODULES[@]}" -eq 0 ]]; then

    echo "  标准模块"

else

    for module in "${MODULES[@]}"; do
        echo "  ${module}"
    done

fi


# ------------------------------------------------------------
# 特别检查 Cloudflare 模块
# ------------------------------------------------------------

for module in "${MODULES[@]}"; do

    if [[ "${module}" == "github.com/caddy-dns/cloudflare"* ]]; then

        log "验证 Cloudflare DNS 模块"

        "${CADDY_BIN}" list-modules \
            | grep -Fx 'dns.providers.cloudflare' >/dev/null \
            || die "未检测到 dns.providers.cloudflare"

        echo "OK: dns.providers.cloudflare"

    fi

done


# ------------------------------------------------------------
# 验证 Caddyfile
# ------------------------------------------------------------

log "验证 Caddyfile"

"${CADDY_BIN}" validate \
    --config "${CADDY_CONFIG}"


# ------------------------------------------------------------
# systemd unit 校验
# ------------------------------------------------------------

if command -v systemd-analyze >/dev/null 2>&1; then

    log "验证 systemd unit"

    systemd-analyze verify "${SYSTEMD_UNIT}"

fi


# ------------------------------------------------------------
# 启用服务
# ------------------------------------------------------------

log "启动 Caddy"

systemctl daemon-reload

systemctl enable caddy.service

systemctl restart caddy.service


# ------------------------------------------------------------
# 状态检查
# ------------------------------------------------------------

sleep 1

if ! systemctl is-active --quiet caddy.service; then

    echo
    echo "Caddy 启动失败"
    echo
    journalctl \
        -u caddy.service \
        -n 100 \
        --no-pager

    exit 1

fi


# ------------------------------------------------------------
# 默认配置 Health Check
# ------------------------------------------------------------

if [[ "${CREATED_DEFAULT_CONFIG}" -eq 1 ]]; then

    log "HTTP Health Check"

    RESPONSE="$(
        curl \
            --fail \
            --silent \
            --show-error \
            http://127.0.0.1:2015
    )"

    if [[ "${RESPONSE}" != "Caddy is running" ]]; then
        die "HTTP Health Check 失败"
    fi

    echo "OK: ${RESPONSE}"

fi


# ------------------------------------------------------------
# 最终结果
# ------------------------------------------------------------

log "安装完成"

echo
echo "Binary:"
echo "  ${CADDY_BIN}"

echo
echo "xcaddy:"
echo "  ${XCADDY_BIN}"

echo
echo "Caddyfile:"
echo "  ${CADDY_CONFIG}"

echo
echo "Environment:"
echo "  ${CADDY_ENV}"

echo
echo "Data:"
echo "  ${CADDY_HOME}"

echo
echo "Systemd:"
echo "  ${SYSTEMD_UNIT}"

echo
echo "Version:"
"${CADDY_BIN}" version

echo
echo "Service:"
systemctl --no-pager --full status caddy.service || true

echo
echo "常用命令："
echo
echo "  caddy validate --config /etc/caddy/Caddyfile"
echo "  systemctl reload caddy"
echo "  systemctl restart caddy"
echo "  journalctl -u caddy -f"
echo
