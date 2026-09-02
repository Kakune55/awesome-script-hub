---
title: Linux 硬件 BOM 采集
description: 采集 Linux 主机的硬件清单（BOM）：主板、BIOS、CPU、内存、DIMM、GPU、磁盘、NVMe、网卡、PCI/USB 设备与虚拟化环境。
os: ["Linux"]
tags: ["hardware", "bom", "dmidecode", "inventory"]
updated: 2026-09-02
danger: safe
dangerMessage: 脚本为只读采集，不修改系统；部分信息（DIMM/DMI/NVMe）需要 root 才完整。
---

# Linux 硬件 BOM 采集

采集 Linux 主机的完整硬件物料清单（Bill of Materials），输出结构化的分节报告，覆盖系统、主板、BIOS/UEFI、CPU、内存、DIMM、GPU、磁盘、NVMe、网络、温度、PCI/USB 设备与虚拟化环境。适合资产盘点、装机验收和故障排查前的基础信息收集。

## 功能

- 采集 DMI/SMBIOS 信息（厂商、型号、序列号、UUID），优先 `dmidecode`，无 root 时回退到 `/sys/class/dmi/id`
- 检测 UEFI / Legacy BIOS 启动模式
- 汇总 CPU 拓扑（插槽 / 核心 / 线程 / 缓存 / NUMA）
- 解析每根 DIMM 的插槽、容量、类型、频率、厂商、料号、序列号和 Rank
- 识别 NVIDIA（`nvidia-smi`）与 AMD ROCm（`rocm-smi`）独显信息
- 列出物理磁盘、NVMe 控制器（`nvme list` 或 sysfs 回退）
- 输出网卡 MAC / 驱动 / 固件 / 链路速率 / IP 地址
- 可选输出传感器温度（`sensors`）
- 检测物理机或虚拟化环境（`systemd-detect-virt`）

## 改良内容

- 新增 `-o FILE` 参数，报告可同时写入文件，便于存档
- 新增网卡 IPv4 / IPv6 地址信息（`ip`）
- 新增温度传感章节（装有 `lm-sensors` 时输出）
- 所有输出统一经由 `emit` 函数，终端与文件内容完全一致
- `ethtool -i` 由三次调用合并为一次
- 提取 `is_root` / `kv` 等公共函数，消除重复代码并统一字段对齐
- 管道与子 shell 输出统一收集，避免输出顺序错乱

## 适用环境

| 项目 | 要求 |
| --- | --- |
| 操作系统 | Linux |
| 依赖 | 均为可选；存在 `lspci`、`lsblk`、`dmidecode`、`nvme`、`ethtool` 等工具时输出更完整 |
| 权限 | 建议使用 `sudo` 运行以获取完整 DIMM / DMI / NVMe 信息 |

## 使用方法

输出到终端：

```bash
bash script.sh
```

推荐以 sudo 运行以获取完整信息：

```bash
sudo bash script.sh
```

同时保存报告到文件：

```bash
sudo bash script.sh -o hardware-bom.txt
```

查看帮助：

```bash
bash script.sh -h
```

## 输出章节

SYSTEM / MOTHERBOARD / BIOS-UEFI / CPU / MEMORY SUMMARY / MEMORY DIMMS / GPU / STORAGE / NVME / NETWORK / TEMPERATURES（可选）/ PCI-PCIE DEVICES / USB DEVICES / VIRTUALIZATION

## 注意事项

- 脚本完全只读，不会修改系统配置
- 序列号、UUID 等信息较为敏感，报告文件请妥善保管
- 无 root 时 DIMM 章节为空，DMI 信息可能被内核置为空字符串（部分厂商如此，属正常现象）
