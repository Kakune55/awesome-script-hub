---
title: Debian 软件源切换器
description: 交互选择镜像站、仓库组件和 sources 格式，失败时自动回滚。
os: ["Debian"]
tags: ["apt", "mirror"]
updated: 2026-08-13
danger: warning
dangerMessage: 该脚本会替换系统 APT 软件源配置；执行前请确认镜像与发行版匹配。
---

# Debian 软件源切换器

为 Debian 11、12、13、testing 和 unstable 生成软件源配置。支持常用镜像、DEB822 与传统 `sources.list` 格式，并在 `apt-get update` 失败时自动回滚。

## 功能

- 交互选择 CERNET、TUNA、USTC、阿里云、腾讯云、华为云或官方源
- 配置安全源、updates、backports 和 proposed-updates
- 选择 `main`、`contrib`、`non-free` 与 `non-free-firmware`
- 自动识别适合的源文件格式
- 修改前完整备份现有配置
- 支持 `--dry-run` 预览

## 推荐用法

先预览配置：

```bash
sudo bash script.sh --dry-run
```

进入交互模式：

```bash
sudo bash script.sh
```

使用 CERNET 并启用 backports：

```bash
sudo bash script.sh \
  --mirror cernet \
  --backports
```

## 常用选项

| 选项 | 说明 |
| --- | --- |
| `--mirror NAME` | 选择镜像站 |
| `--components MODE` | 使用 main、full 或 custom 组件集合 |
| `--format FORMAT` | 使用 auto、deb822 或 list 格式 |
| `--no-update` | 写入后不执行 apt update |
| `--dry-run` | 仅显示配置，不修改系统 |

## 安全与回滚

脚本需要 root 权限，会修改 APT 配置。正常执行时会创建带时间戳的备份目录；验证失败时自动恢复。远程维护服务器时，建议保持当前 SSH 会话并先使用 `--dry-run`。
