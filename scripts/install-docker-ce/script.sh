#!/usr/bin/env bash
set -Eeuo pipefail

# Install the latest stable Docker CE on Debian/Ubuntu.
# Docker CE APT mirror: CERNET
# Docker Hub registry mirror: optional, prompted at runtime

DOCKER_APT_MIRROR="${DOCKER_APT_MIRROR:-https://mirrors.cernet.edu.cn/docker-ce}"
REGISTRY_MIRROR="${REGISTRY_MIRROR:-}"

log()  { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

trap 'die "执行失败：第 ${LINENO} 行，命令：${BASH_COMMAND}"' ERR

prompt_registry_mirror() {
    if [[ -n "$REGISTRY_MIRROR" ]]; then
        log "使用环境变量指定的 Docker Hub 镜像源"
    elif [[ -r /dev/tty && -w /dev/tty ]]; then
        printf 'Docker Hub 镜像源（直接回车使用官方默认）：' > /dev/tty
        IFS= read -r REGISTRY_MIRROR < /dev/tty || true
    else
        log "当前为非交互环境，使用 Docker Hub 官方默认源"
    fi

    REGISTRY_MIRROR="${REGISTRY_MIRROR%/}"
    if [[ -n "$REGISTRY_MIRROR" && ! "$REGISTRY_MIRROR" =~ ^https?://[^[:space:]]+$ ]]; then
        die "Docker Hub 镜像源必须是有效的 HTTP 或 HTTPS URL"
    fi
}

if [[ "${EUID}" -ne 0 ]]; then
    die "请使用 root 运行：sudo bash $0"
fi

[[ -r /etc/os-release ]] || die "无法识别操作系统：缺少 /etc/os-release"
# shellcheck disable=SC1091
source /etc/os-release

case "${ID:-}" in
    debian|ubuntu)
        DISTRO="${ID}"
        ;;
    *)
        die "仅支持 Debian/Ubuntu，当前系统：${PRETTY_NAME:-unknown}"
        ;;
esac

CODENAME="${VERSION_CODENAME:-}"
if [[ -z "${CODENAME}" ]]; then
    CODENAME="$(. /etc/os-release && printf '%s' "${UBUNTU_CODENAME:-}")"
fi
[[ -n "${CODENAME}" ]] || die "无法识别发行版代号 VERSION_CODENAME"

ARCH="$(dpkg --print-architecture)"
log "系统：${PRETTY_NAME:-$DISTRO}，架构：${ARCH}，代号：${CODENAME}"
prompt_registry_mirror

log "安装基础依赖"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl gnupg

log "移除可能冲突的软件包（不会删除 /var/lib/docker 数据）"
conflicts=(
    docker.io docker-compose docker-compose-v2 docker-doc
    podman-docker containerd runc
)
installed=()
for pkg in "${conflicts[@]}"; do
    if dpkg-query -W -f='${db:Status-Abbrev}' "$pkg" 2>/dev/null | grep -q '^ii'; then
        installed+=("$pkg")
    fi
done
if ((${#installed[@]})); then
    apt-get remove -y "${installed[@]}"
fi

log "配置 Docker CE CERNET 软件源"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL "${DOCKER_APT_MIRROR}/linux/${DISTRO}/gpg" \
    -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: ${DOCKER_APT_MIRROR}/linux/${DISTRO}
Suites: ${CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

log "安装最新版稳定版 Docker Engine、Buildx 和 Compose"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

if [[ -n "$REGISTRY_MIRROR" ]]; then
    log "配置 Docker Hub 镜像源：${REGISTRY_MIRROR}"
    install -m 0755 -d /etc/docker

    # 保留 daemon.json 现有配置，只更新 registry-mirrors。
    python3 - "${REGISTRY_MIRROR}" <<'PY'
import json
import os
import sys
import tempfile

path = "/etc/docker/daemon.json"
mirror = sys.argv[1]

data = {}
if os.path.exists(path) and os.path.getsize(path) > 0:
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            raise ValueError("顶层必须是 JSON object")
    except Exception as exc:
        backup = path + ".bak"
        os.replace(path, backup)
        print(f"[WARN] 原 daemon.json 无效，已备份为 {backup}: {exc}",
              file=sys.stderr)
        data = {}

mirrors = data.get("registry-mirrors", [])
if not isinstance(mirrors, list):
    mirrors = []
mirrors = [item for item in mirrors if item != mirror]
data["registry-mirrors"] = [mirror, *mirrors]

directory = os.path.dirname(path)
fd, tmp = tempfile.mkstemp(prefix=".daemon.", suffix=".json", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY
else
    log "未配置 Docker Hub 镜像源，保留官方默认或现有配置"
fi

log "校验 Docker 配置并启动服务"
if [[ -s /etc/docker/daemon.json ]]; then
    dockerd --validate --config-file=/etc/docker/daemon.json
fi
systemctl enable --now containerd
systemctl enable --now docker
systemctl restart docker

log "验证安装结果"
docker version
docker compose version
docker buildx version

printf '\n'
log "Docker 安装完成"
printf 'APT 软件源：%s/linux/%s\n' "${DOCKER_APT_MIRROR}" "${DISTRO}"
if [[ -n "$REGISTRY_MIRROR" ]]; then
    printf 'Docker Hub 镜像源：%s\n' "${REGISTRY_MIRROR}"
else
    printf 'Docker Hub 镜像源：官方默认（未修改）\n'
fi
printf '\n说明：脚本没有自动把任何普通用户加入 docker 组。\n'
