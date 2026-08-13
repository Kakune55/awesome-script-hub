---
title: Docker CE 一键安装
description: 在 Debian 或 Ubuntu 上安装 Docker Engine、Buildx 和 Compose，可选配置 Docker Hub 镜像源。
os: ["Debian", "Ubuntu"]
tags: ["docker", "apt"]
updated: 2026-08-13
danger: warning
dangerMessage: 该脚本会安装和移除系统软件包、写入 APT 配置并重启 Docker 服务；仅在指定镜像源时修改 Docker 配置。
---

# Docker CE 一键安装

在 Debian 或 Ubuntu 上安装最新版稳定版 Docker Engine、Buildx 与 Compose 插件。脚本默认使用 CERNET Docker CE 软件源，执行时可选择是否配置 Docker Hub 镜像源。

## 适用环境

| 项目 | 要求 |
| --- | --- |
| 操作系统 | Debian、Ubuntu |
| 权限 | root |
| 网络 | 能够访问 APT 软件源和 Docker 镜像源 |
| 架构 | 由 `dpkg --print-architecture` 自动识别 |

## 执行前检查

脚本会执行以下系统变更：

- 移除可能冲突的 Docker、Podman、containerd 和 runc 软件包
- 写入 `/etc/apt/sources.list.d/docker.sources`
- 指定 Docker Hub 镜像源时，更新 `/etc/docker/daemon.json` 中的 `registry-mirrors`
- 启用并重启 Docker 与 containerd 服务

> 移除冲突软件包不会主动删除 `/var/lib/docker`，但生产环境仍应先备份重要容器数据和配置。

## 使用方法

下载后执行：

```bash
curl -fsSL https://example.com/scripts/install-docker-ce/script.sh -o script.sh
less script.sh
sudo bash script.sh
```

执行时会询问：

```text
Docker Hub 镜像源（直接回车使用官方默认）：
```

直接回车不会写入或清空 `registry-mirrors`：新环境使用 Docker 官方默认源，已有 `daemon.json` 配置保持不变。

自动化执行时可以通过环境变量预设镜像源：

```bash
sudo DOCKER_APT_MIRROR="https://download.docker.com" \
  REGISTRY_MIRROR="https://your-registry-mirror.example.com" \
  bash script.sh
```

非交互环境未设置 `REGISTRY_MIRROR` 时，脚本自动使用官方默认且不修改 Docker 镜像配置。

## 验证

```bash
docker version
docker compose version
docker run --rm hello-world
```

## 回滚提示

指定镜像源时，脚本只合并 `registry-mirrors` 字段。原文件无法解析时会重命名为 `daemon.json.bak`。未指定镜像源时不会改动该文件。
