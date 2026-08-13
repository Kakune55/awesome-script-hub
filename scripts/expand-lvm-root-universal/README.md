---
title: 通用 LVM 根卷扩容
description: 自动识别磁盘、分区、PV、LV 和文件系统，扩展虚拟机根卷。
os: ["Debian", "Ubuntu", "RHEL", "CentOS", "Rocky Linux", "AlmaLinux", "Fedora"]
tags: ["lvm", "storage"]
updated: 2026-08-12
danger: danger
dangerMessage: 该脚本会修改磁盘分区、LVM 元数据和根文件系统，操作失误可能导致系统无法启动或数据丢失。
---

# 通用 LVM 根卷扩容

自动识别根目录所在的 LV、VG、PV、物理磁盘和分区，并扩展分区、LVM 与文件系统。支持 Debian、Ubuntu、RHEL、CentOS、Rocky、AlmaLinux 和 Fedora。

> 这是高风险磁盘操作。执行前必须创建虚拟机快照或完整备份，并确认宿主机已经扩大虚拟磁盘容量。

## 执行链路

1. 识别 Linux 发行版和包管理器
2. 检查或安装 growpart、lvm2 与文件系统工具
3. 从根挂载点反查 LV、VG 和 PV
4. 使用 `growpart` 扩展分区
5. 使用 `pvresize` 扩展 PV
6. 使用 `lvextend -r` 扩展根 LV 与文件系统

## 只读预检

```bash
sudo bash script.sh --dry-run
```

请核对输出中的磁盘、分区号和根 LV。自动识别结果不正确时不要继续。

## 执行

自动识别：

```bash
sudo bash script.sh
```

手动指定目标：

```bash
sudo bash script.sh \
  --disk /dev/sda \
  --part 3 \
  --lv /dev/mapper/vg-root
```

## 验证

```bash
lsblk
pvs
vgs
lvs
df -Th /
```

## 风险说明

- 目标磁盘或分区选择错误可能破坏其他卷
- 扩容期间断电可能损坏分区表或文件系统
- 此操作只负责扩容，不支持缩容和自动回滚
- 多 PV、复杂存储拓扑应由管理员手动确认
