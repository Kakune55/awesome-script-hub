#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Debian 13 LXC: CERNET mirror + PostgreSQL 18 + Redis
# PostgreSQL admin: pgadmin / 123456
# PostgreSQL remote access: enabled (IPv4 + IPv6, SCRAM)
# Redis remote access: enabled (IPv4), no password
# ============================================================

PG_VERSION="18"
PG_ADMIN_USER="pgadmin"
PG_ADMIN_PASSWORD="123456"
PG_REMOTE_CIDR_V4="0.0.0.0/0"
PG_REMOTE_CIDR_V6="::/0"

DEBIAN_MIRROR="https://mirrors.cernet.edu.cn/debian"
DEBIAN_SECURITY_MIRROR="https://mirrors.cernet.edu.cn/debian-security"
PGDG_CERNET_MIRROR="https://mirrors.cernet.edu.cn/postgresql/repos/apt"
PGDG_OFFICIAL_MIRROR="https://apt.postgresql.org/pub/repos/apt"

log() {
    printf '\n\033[1;34m[%s]\033[0m %s\n' "$(date '+%H:%M:%S')" "$*"
}

warn() {
    printf '\n\033[1;33m[WARNING]\033[0m %s\n' "$*" >&2
}

fatal() {
    printf '\n\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
    exit 1
}

trap 'fatal "脚本在第 ${LINENO} 行执行失败。"' ERR

[[ ${EUID} -eq 0 ]] || fatal "请使用 root 用户运行此脚本。"
[[ -r /etc/os-release ]] || fatal "无法读取 /etc/os-release。"

# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "debian" ]] || fatal "本脚本仅支持 Debian。当前系统：${PRETTY_NAME:-unknown}"
[[ "${VERSION_ID:-}" == "13" ]] || fatal "本脚本要求 Debian 13。当前版本：${VERSION_ID:-unknown}"

CODENAME="${VERSION_CODENAME:-trixie}"
ARCH="$(dpkg --print-architecture)"

case "$ARCH" in
    amd64|arm64|ppc64el|loong64) ;;
    *) fatal "PGDG 当前不支持该架构：${ARCH}" ;;
esac

export DEBIAN_FRONTEND=noninteractive

log "备份并切换 Debian 软件源到 CERNET"
BACKUP_DIR="/root/apt-sources-backup-$(date '+%Y%m%d-%H%M%S')"
mkdir -p "$BACKUP_DIR"

if [[ -f /etc/apt/sources.list ]]; then
    cp -a /etc/apt/sources.list "$BACKUP_DIR/"
    : > /etc/apt/sources.list
fi

if [[ -f /etc/apt/sources.list.d/debian.sources ]]; then
    cp -a /etc/apt/sources.list.d/debian.sources "$BACKUP_DIR/"
fi

cat > /etc/apt/sources.list.d/debian.sources <<EOF
Types: deb
URIs: ${DEBIAN_MIRROR}
Suites: ${CODENAME} ${CODENAME}-updates ${CODENAME}-backports
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: ${DEBIAN_SECURITY_MIRROR}
Suites: ${CODENAME}-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    postgresql-common \
    redis-server

log "配置 PostgreSQL PGDG 18 软件源"
install -d -m 0755 /usr/share/postgresql-common/pgdg
curl -fsSL \
    https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
chmod 0644 /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc

PGDG_URI="$PGDG_CERNET_MIRROR"
if ! curl -fsSL --connect-timeout 8 --max-time 30 \
    "${PGDG_CERNET_MIRROR}/dists/${CODENAME}-pgdg/InRelease" \
    -o /dev/null; then
    warn "CERNET PostgreSQL 镜像当前不可达，PGDG 将回退到官方源。"
    PGDG_URI="$PGDG_OFFICIAL_MIRROR"
fi

cat > /etc/apt/sources.list.d/pgdg.sources <<EOF
Types: deb
URIs: ${PGDG_URI}
Suites: ${CODENAME}-pgdg
Architectures: ${ARCH}
Components: main
Signed-By: /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
EOF

apt-get update
apt-get install -y --no-install-recommends \
    "postgresql-${PG_VERSION}" \
    "postgresql-client-${PG_VERSION}"

log "初始化并启动 PostgreSQL ${PG_VERSION}"
if ! pg_lsclusters --no-header 2>/dev/null | awk -v v="$PG_VERSION" '$1 == v {found=1} END {exit !found}'; then
    pg_createcluster "$PG_VERSION" main --start
fi

PG_CLUSTER="$(pg_lsclusters --no-header | awk -v v="$PG_VERSION" '$1 == v {print $2; exit}')"
[[ -n "$PG_CLUSTER" ]] || fatal "没有找到 PostgreSQL ${PG_VERSION} 集群。"

pg_ctlcluster "$PG_VERSION" "$PG_CLUSTER" start || true

PG_CONF_DIR="/etc/postgresql/${PG_VERSION}/${PG_CLUSTER}"
PG_HBA_FILE="${PG_CONF_DIR}/pg_hba.conf"
[[ -f "$PG_HBA_FILE" ]] || fatal "找不到 PostgreSQL HBA 文件：${PG_HBA_FILE}"

log "配置 PostgreSQL 远程监听与 SCRAM 认证"
pg_conftool "$PG_VERSION" "$PG_CLUSTER" set listen_addresses '*'
pg_conftool "$PG_VERSION" "$PG_CLUSTER" set password_encryption 'scram-sha-256'

# 删除本脚本以前写入的配置块，确保重复执行不会堆叠规则。
sed -i \
    '/^# BEGIN ONECLICK_PG_REMOTE$/,/^# END ONECLICK_PG_REMOTE$/d' \
    "$PG_HBA_FILE"

cat >> "$PG_HBA_FILE" <<EOF

# BEGIN ONECLICK_PG_REMOTE
# Remote access managed by setup-debian13-pg18-redis.sh
host    all    all    ${PG_REMOTE_CIDR_V4}    scram-sha-256
host    all    all    ${PG_REMOTE_CIDR_V6}    scram-sha-256
# END ONECLICK_PG_REMOTE
EOF

pg_ctlcluster "$PG_VERSION" "$PG_CLUSTER" restart

log "创建或重置 PostgreSQL 管理员账户 ${PG_ADMIN_USER}"
runuser -u postgres -- psql \
    --set=ON_ERROR_STOP=1 \
    --set=admin_user="$PG_ADMIN_USER" \
    --set=admin_password="$PG_ADMIN_PASSWORD" <<'SQL'
SELECT format('CREATE ROLE %I', :'admin_user')
WHERE NOT EXISTS (
    SELECT 1 FROM pg_roles WHERE rolname = :'admin_user'
) \gexec

SELECT format(
    'ALTER ROLE %I WITH LOGIN SUPERUSER CREATEDB CREATEROLE REPLICATION BYPASSRLS PASSWORD %L',
    :'admin_user', :'admin_password'
) \gexec

SELECT format('CREATE DATABASE %I OWNER %I', :'admin_user', :'admin_user')
WHERE NOT EXISTS (
    SELECT 1 FROM pg_database WHERE datname = :'admin_user'
) \gexec
SQL

log "配置 Redis 允许远程连接且不使用密码"
REDIS_CONF="/etc/redis/redis.conf"
[[ -f "$REDIS_CONF" ]] || fatal "找不到 Redis 配置文件：${REDIS_CONF}"

if [[ ! -f "${REDIS_CONF}.before-oneclick" ]]; then
    cp -a "$REDIS_CONF" "${REDIS_CONF}.before-oneclick"
fi

# 只监听 IPv4 的所有接口，避免部分 LXC 未启用 IPv6 时 Redis 启动失败。
if grep -Eq '^[[:space:]]*bind[[:space:]]+' "$REDIS_CONF"; then
    sed -ri 's|^[[:space:]]*bind[[:space:]].*$|bind 0.0.0.0|' "$REDIS_CONF"
else
    printf '\nbind 0.0.0.0\n' >> "$REDIS_CONF"
fi

if grep -Eq '^[[:space:]]*protected-mode[[:space:]]+' "$REDIS_CONF"; then
    sed -ri 's|^[[:space:]]*protected-mode[[:space:]].*$|protected-mode no|' "$REDIS_CONF"
else
    printf 'protected-mode no\n' >> "$REDIS_CONF"
fi

# 新安装默认没有密码；这里额外清除可能存在的 requirepass。
sed -ri \
    's|^[[:space:]]*requirepass[[:space:]].*$|# requirepass disabled by one-click setup|' \
    "$REDIS_CONF"

systemctl enable postgresql redis-server >/dev/null
systemctl restart postgresql redis-server

log "执行本机连通性测试"
PGPASSWORD="$PG_ADMIN_PASSWORD" \
    psql -h 127.0.0.1 \
    -U "$PG_ADMIN_USER" \
    -d "$PG_ADMIN_USER" \
    -v ON_ERROR_STOP=1 \
    -Atqc "SELECT 'PostgreSQL OK: ' || current_user || ' / ' || current_database();"

redis-cli -h 127.0.0.1 ping | grep -qx 'PONG'
printf 'Redis OK: PONG\n'

CONTAINER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
CONTAINER_IP="${CONTAINER_IP:-<LXC-IP>}"

cat <<EOF

============================================================
安装完成
============================================================

PostgreSQL ${PG_VERSION}
  地址：${CONTAINER_IP}
  端口：5432
  用户：${PG_ADMIN_USER}
  密码：${PG_ADMIN_PASSWORD}
  默认数据库：${PG_ADMIN_USER}
  认证：SCRAM-SHA-256

连接示例：
  PGPASSWORD='${PG_ADMIN_PASSWORD}' psql -h ${CONTAINER_IP} -U ${PG_ADMIN_USER} -d ${PG_ADMIN_USER}

Redis
  地址：${CONTAINER_IP}
  端口：6379
  密码：无

连接示例：
  redis-cli -h ${CONTAINER_IP} ping

APT 源备份：${BACKUP_DIR}
PGDG 地址：${PGDG_URI}

重要：Redis 当前对所有 IPv4 接口开放且没有密码。
请务必只在可信内网使用，并通过 PVE 防火墙/上游防火墙限制 6379。
PostgreSQL 也允许任意来源连接，请至少限制 5432 的来源网段。
============================================================
EOF
