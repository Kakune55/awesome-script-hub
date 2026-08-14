---
title: fio 磁盘性能测试
description: 使用 fio 模拟 CrystalDiskMark 的常用项目，测试磁盘顺序与随机读写性能。
os: ["Debian", "Ubuntu", "RHEL", "CentOS", "Rocky Linux", "AlmaLinux", "Fedora"]
tags: ["fio", "storage", "benchmark"]
updated: 2026-08-14
danger: safe
dangerMessage: 磁盘测试会产生一定的读写负载，建议避开生产业务运行时段执行。
---

# fio 磁盘性能测试

基于 [bihell/fio](https://github.com/bihell/fio) 改良，使用 fio 模拟 CrystalDiskMark 的常用测试项目。脚本会输出顺序与随机读写的带宽、IOPS 和平均延迟。

## 改良内容

- 脚本内部不调用 `sudo`，由执行者决定使用当前用户、root 或 `sudo`
- 自动检查 `fio` 和 `jq`，缺失时通过 `apt-get` 或 `dnf` 尝试安装
- 不再使用 `eval`，路径包含空格时也能安全执行
- 测试数据放入目标目录下的唯一临时目录，退出时只清理本次创建的文件
- 增加参数校验、目录可写检查和失败提示

## 适用环境

| 项目 | 要求 |
| --- | --- |
| 操作系统 | Debian、Ubuntu、RHEL、CentOS、Rocky Linux、AlmaLinux、Fedora |
| 依赖 | `fio`、`jq`；缺失时自动尝试安装 |
| 权限 | 目标目录可写；自动安装依赖时需要 root |
| 空间 | 默认每个任务文件 1 GiB；并行 SSD 测试需要更多可用空间 |

> 请勿直接对承载在线业务的目录执行基准测试。测试会产生高强度 I/O，结果也可能受到缓存、虚拟化和其他负载影响。

## 使用方法

默认测试，每项运行 60 秒：

```bash
bash script.sh /mnt/test
```

当前用户无权写入目标目录，或需要自动安装依赖时，由执行者选择使用 `sudo`：

```bash
sudo bash script.sh /mnt/test
```

快速测试，每项运行 10 秒：

```bash
bash script.sh /mnt/test fast
```

SSD/NVMe 测试：

```bash
bash script.sh /mnt/test ssd
```

运行全部测试：

```bash
bash script.sh /mnt/test all
```

参数顺序不作要求，例如 `bash script.sh fast all /mnt/test` 同样有效。

## 可调参数

可通过环境变量覆盖默认测试文件大小和时长：

```bash
FIO_SIZE=2g FIO_RUNTIME=30s bash script.sh /mnt/test all
```

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `FIO_SIZE` | `1g` | 每个 fio 任务的测试文件大小 |
| `FIO_RUNTIME` | `60s` | 每个测试项目运行时间；`fast` 参数会改为 `10s` |

## 依赖安装

仅当 `fio` 或 `jq` 缺失时，脚本才会安装依赖：

- Debian/Ubuntu：`apt-get update` 后执行 `apt-get install -y`
- Fedora/RHEL 及其衍生发行版：执行 `dnf install -y`

脚本不会自行提升权限。普通用户缺少依赖时会退出并提示使用 root 或由执行者加 `sudo` 后重跑。

## 来源与许可

原项目：[bihell/fio](https://github.com/bihell/fio)，Copyright (c) 2023 Haseo Chen。原作及本改良版本遵循 MIT License，许可证文本见同目录 `LICENSE`。
