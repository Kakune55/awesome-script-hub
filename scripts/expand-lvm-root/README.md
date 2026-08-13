---
title: LVM 根卷扩容
description: 面向常见虚拟机 LVM 布局的精简根分区扩容脚本。
os: ["Linux"]
tags: ["lvm", "virtual-machine", "storage"]
updated: 2026-08-11
danger: danger
dangerMessage: 该脚本会直接扩展分区、PV、LV 和根文件系统，执行前必须完成快照或备份。
---

# LVM 根卷扩容

针对常见虚拟机 LVM 根目录布局的精简扩容脚本。它从 `/` 挂载点识别根 LV，再定位对应的 VG、PV、磁盘和分区。

## 典型结构

```text
/dev/sda3
  └── LVM PV
      └── VG
          └── root LV
              └── /
```

## 前置条件

- 已在 PVE、VMware、Hyper-V 或云平台控制台扩大虚拟磁盘
- 根目录位于 LVM 逻辑卷
- 已创建虚拟机快照或数据备份
- 当前维护窗口允许磁盘操作

## 自动执行

```bash
sudo bash script.sh
```

手动指定磁盘、分区号和根 LV：

```bash
sudo bash script.sh /dev/sda 3 /dev/mapper/vg-root
```

## 验证目标

执行前至少确认以下信息：

```bash
findmnt -n -o SOURCE /
lsblk -f
pvs
lvs
```

执行后确认容量：

```bash
df -Th /
lvs
```

> 该精简版本没有 `--dry-run`。如果系统结构不标准，优先使用带预检能力的通用版本。
