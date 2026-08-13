# Awesome Script Hub

一个无后端、无构建步骤的静态 SRE 脚本门户。浏览器运行时读取 `scripts.json`，加载 Markdown 文档和脚本源码。

## 内容结构

每个脚本独占一个目录，源码和说明共同维护：

```text
scripts/
└── example/
    ├── README.md
    └── script.sh
```

`README.md` 使用 Hexo 风格 Front Matter 保存展示元数据和安全提示：

```yaml
---
title: 示例脚本
description: 用一句话说明脚本用途。
os: ["Debian", "Ubuntu"]
tags: ["example"]
updated: 2026-08-13
danger: warning
dangerMessage: 该脚本会修改系统配置。
---
```

`danger` 支持 `safe`、`warning`、`danger`。默认源码文件名为 `script.sh`；单个其他类型可增加 `source: script.py`。

一个脚本条目需要提供多个适配文件时，使用 JSON 风格的 `files` 数组：

```yaml
files: [{"name":"debian.sh","label":"Debian / Ubuntu","os":["Debian","Ubuntu"]},{"name":"rhel.sh","label":"RHEL 系列","os":["RHEL","Rocky Linux","AlmaLinux"]}]
```

`name` 是同目录文件名，`label` 用于文件列表显示，`os` 表示该文件的适用系统。配置 `files` 后不再读取单文件 `source`。

`scripts.json` 只负责列出脚本目录：

```json
[
  "example",
  "another-script"
]
```

## 本地预览

不要直接双击 `index.html`，浏览器会阻止本地 `fetch`。在仓库目录启动静态服务器：

```bash
python3 -m http.server 8080
```

然后访问 <http://localhost:8080>。

## 新增脚本

使用维护工具创建模板：

```bash
python3 hub.py new docker-cleanup
```

完善生成的 `README.md` 和 `script.sh` 后，重新生成索引：

```bash
python3 hub.py index g
```

只检查内容和索引是否有效，不修改文件：

```bash
python3 hub.py index check
```

文档路径和默认源码路径根据目录 ID 自动推导。语法高亮和一键执行方式根据源码扩展名映射，目前 `.sh` 与 `.py` 支持一键执行；无法可靠通过管道执行的类型只展示源码。

## Cloudflare Pages

连接 Git 仓库后使用以下配置：

- Framework preset：None
- Build command：`exit 0`
- Build output directory：`.`

站点使用 Hash 路由，不需要额外的重写规则。
