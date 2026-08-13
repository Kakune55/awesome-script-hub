---
title: Debian 13 数据库环境初始化
description: 为 Debian 13 LXC 安装 PostgreSQL 18 与 Redis，并配置远程访问。
os: ["Debian 13"]
tags: ["postgresql", "redis", "lxc"]
updated: 2026-08-10
danger: danger
dangerMessage: 源码包含固定弱密码，且会开放 PostgreSQL 和 Redis 远程访问，禁止直接用于公网或生产环境。
---

# Debian 13 数据库环境初始化

为 Debian 13 LXC 安装 PostgreSQL 18 和 Redis，切换 CERNET 软件源，并配置远程连接。

> **禁止直接在生产环境或公网主机运行。** 当前源码使用固定 PostgreSQL 管理员密码 `123456`，允许 `0.0.0.0/0` 和 `::/0` 访问 PostgreSQL，并开放无密码 Redis。

## 脚本行为

- 备份并替换 Debian APT 软件源
- 添加 PostgreSQL PGDG 软件源
- 安装 PostgreSQL 18 和 Redis
- 创建 PostgreSQL 超级管理员
- 修改 PostgreSQL 监听地址与访问控制
- 修改 Redis 监听和保护模式
- 启用并重启数据库服务

## 仅限隔离测试环境

如果确实需要测试，请先下载并修改以下配置：

```bash
curl -fsSL https://example.com/scripts/setup-debian13-pg18-redis/script.sh \
  -o script.sh
chmod 600 script.sh
editor script.sh
```

至少应修改：

```bash
PG_ADMIN_PASSWORD="使用随机生成的强密码"
PG_REMOTE_CIDR_V4="你的管理网段"
PG_REMOTE_CIDR_V6="你的 IPv6 管理网段"
```

同时应为 Redis 配置认证或仅监听本机，并使用主机防火墙限制数据库端口。

## 验证

```bash
systemctl status postgresql redis-server
ss -lntp | grep -E ':(5432|6379)'
sudo -u postgres psql -c '\du'
redis-cli ping
```

## 生产替代方案

生产环境建议使用配置管理工具或密钥系统注入凭据，明确设置允许访问的 CIDR，并为 PostgreSQL 与 Redis 配置 TLS、认证、备份和监控。
