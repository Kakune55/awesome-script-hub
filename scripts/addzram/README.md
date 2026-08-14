---
title: ZRAM 一键配置管理
description: 交互式添加、移除和检查 ZRAM 压缩交换设备，并配置开机自动启用。
os: ["Linux"]
tags: ["zram", "memory", "swap"]
updated: 2026-08-14
danger: warning
dangerMessage: 该脚本会加载内核模块、调整交换设备并写入开机启动配置，执行前请确认 ZRAM 大小和现有 Swap 状态。
---

# ZRAM 一键配置管理

收录自 [spiritLHLS/addzram](https://github.com/spiritLHLS/addzram)，用于在 Linux 服务器上添加、移除和检查 ZRAM 压缩交换设备。ZRAM 使用内存中的压缩块设备作为 Swap，可以用额外 CPU 开销换取更高的有效内存容量。

本站版本固定于上游提交 [`cd835d2`](https://github.com/spiritLHLS/addzram/commit/cd835d250e6e1761d3b92ed610d5fe7af567048d)，并将交互输入改为优先读取 `/dev/tty`，以兼容本站的一键管道执行方式。

## 功能

- 根据物理内存推荐 ZRAM 容量：不足 4 GiB 时取物理内存大小，否则取一半
- 读取内核支持的压缩算法并优先推荐 `zstd`
- 创建 `/dev/zram0`、初始化 Swap，并以优先级 100 启用
- 支持添加、移除、查看状态和验证运行状态
- 支持 systemd、OpenRC、runit 以及 SysV/`rc.local`
- 缺少工具或内核模块时，尝试使用当前系统的包管理器安装

## 适用环境

| 项目 | 要求 |
| --- | --- |
| 操作系统 | 使用 Linux 内核且支持 ZRAM 的发行版 |
| 权限 | root |
| 虚拟化 | 宿主机或 VPS 必须允许加载 `zram` 内核模块 |
| 交互 | 需要终端选择操作、算法和容量 |

支持识别 `apt-get`、`apt`、`dnf`、`yum`、`pacman`、`apk`、`zypper`、`pkg` 和 `emerge`。具体软件包是否可用仍取决于发行版软件源和当前内核。

## 使用方法

以 root 运行：

```bash
sudo sh script.sh
```

脚本会显示以下菜单：

```text
[1] Add zRAM / 添加 zRAM
[2] Remove zRAM / 删除 zRAM
[3] Show system status / 查看系统详细状态
[4] Verify ZRAM status / 验证 ZRAM 运行状态
[0] Exit / 退出
```

添加时可以直接回车采用推荐值，也可以选择内核支持的压缩算法并输入 ZRAM 大小。容量单位为 MiB，例如 `1024` 表示 1 GiB。

> ZRAM 容量通常不应大于物理内存。内存紧张但 CPU 有余量的服务器更适合使用 ZRAM。

## 系统改动

添加 ZRAM 时可能执行以下操作：

- 加载 `zram` 内核模块
- 安装 `util-linux` 或发行版对应的 ZRAM 工具包
- 创建并启用 `/dev/zram0` Swap
- 写入 `/usr/local/bin/zram_algorithm`
- 根据 init 系统写入 systemd、OpenRC、runit 或 `rc.local` 自启动配置

systemd 环境会写入：

```text
/etc/systemd/system/zram.service
/etc/modules-load.d/zram.conf
/etc/modprobe.d/zram.conf
```

## 移除与验证

重新运行脚本并选择 `[2]` 可关闭 `/dev/zram0`、重置设备并移除脚本创建的自启动配置。移除后可执行：

```bash
swapon --show
zramctl
```

也可以在菜单中选择 `[4]`，检查内核模块、设备、Swap、自启动服务及压缩统计。

## 来源与许可

原项目：[spiritLHLS/addzram](https://github.com/spiritLHLS/addzram)。截至本次收录，上游仓库未提供 `LICENSE` 或其他明确许可文件；使用和再分发条件以原作者说明为准。
