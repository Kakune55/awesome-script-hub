---
title: Caddy 自定义编译安装
description: 在 Debian 或 Ubuntu 上使用 xcaddy 编译安装 Caddy，支持 Cloudflare DNS 和任意自定义模块。
os: ["Debian", "Ubuntu"]
tags: ["caddy", "xcaddy", "web-server"]
updated: 2026-08-27
danger: warning
dangerMessage: 该脚本会安装编译依赖、覆盖 Caddy 二进制和 systemd unit，并重启 Caddy 服务；升级现有实例前请备份配置和二进制。
---

# Caddy 自定义编译安装

使用 `xcaddy` 从源码编译并安装 Caddy。无参数时构建标准版，也可以通过快捷参数加入 Cloudflare DNS 插件，或传入任意一个或多个 Go 模块路径生成自定义版本。

## 功能

- 安装 Go、Git、编译工具及 `xcaddy`
- 使用最新版 `xcaddy` 编译标准或自定义 Caddy
- 支持 `cloudflare` 快捷参数和任意 `--with` 模块
- 创建专用的 `caddy` 系统用户和数据目录
- 创建默认 Caddyfile、环境变量文件及 systemd 服务
- 验证 Caddy 二进制、配置、Cloudflare 模块和服务状态
- 首次安装时在本机 `2015` 端口执行 HTTP 健康检查

## 适用环境

| 项目 | 要求 |
| --- | --- |
| 操作系统 | Debian、Ubuntu |
| 权限 | root |
| 服务管理 | systemd |
| 网络 | 能够访问 APT 软件源、GitHub 和 Go 模块代理 |
| 架构 | Go 与 Caddy 支持的系统架构 |

## 执行前检查

脚本会写入或更新以下路径：

```text
/usr/local/bin/caddy
/usr/local/bin/xcaddy
/etc/caddy/Caddyfile
/etc/caddy/caddy.env
/etc/systemd/system/caddy.service
/var/lib/caddy
```

已有的 `Caddyfile` 和 `caddy.env` 会保留，但 `caddy`、`xcaddy` 和 `caddy.service` 会被覆盖。脚本最后会校验已有 Caddyfile，并重启当前 Caddy 服务。用于升级生产实例时，应先备份配置和旧二进制，并确认自定义构建包含现有配置所需的全部模块。

## 使用方法

无参数运行，编译标准 Caddy：

```bash
sudo bash script.sh
```

加入 Cloudflare DNS 模块：

```bash
sudo bash script.sh cloudflare
```

加入一个或多个自定义模块：

```bash
sudo bash script.sh \
  github.com/caddy-dns/cloudflare \
  github.com/mholt/caddy-l4
```

通过管道执行并传递参数时，使用 `bash -s --`：

```bash
curl -fsSL https://example.com/scripts/install-caddy-custom/script.sh \
  | sudo bash -s -- cloudflare
```

模块参数会原样传递给 `xcaddy build --with`。建议先确认模块来源可信并检查其版本兼容性；未指定版本时由 Go 模块解析规则选择版本。

## Cloudflare DNS

使用 `cloudflare` 参数编译完成后，将 API Token 写入 `/etc/caddy/caddy.env`：

```text
CF_API_TOKEN=xxxxxxxxxxxxxxxx
```

然后可以在 Caddyfile 中引用：

```caddyfile
tls {
    dns cloudflare {env.CF_API_TOKEN}
}
```

修改后验证并重载服务：

```bash
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

## 默认配置

仅当 `/etc/caddy/Caddyfile` 不存在时，脚本会创建以下本地测试配置：

```caddyfile
:2015 {
    respond "Caddy is running"
}
```

该配置不会直接占用公网 HTTP/HTTPS 端口。确认安装完成后，请按实际域名和服务修改 Caddyfile。

## 验证

```bash
caddy version
caddy list-modules
sudo caddy validate --config /etc/caddy/Caddyfile
systemctl status caddy
journalctl -u caddy -n 100 --no-pager
```

查看自定义模块时可以按名称筛选：

```bash
caddy list-modules | grep -F cloudflare
```

## 回滚提示

脚本不会自动保存旧的 Caddy 二进制或 systemd unit。若用于升级已有实例，应在运行前自行备份 `/usr/local/bin/caddy`、`/etc/systemd/system/caddy.service` 和 `/etc/caddy`。回滚后执行 `systemctl daemon-reload` 并重启 Caddy。
