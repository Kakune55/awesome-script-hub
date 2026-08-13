#!/usr/bin/env python3
"""Awesome Script Hub 内容维护工具。"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from datetime import date
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent
SCRIPTS_DIR = ROOT / "scripts"
INDEX_FILE = ROOT / "scripts.json"
ID_PATTERN = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
RISK_LEVELS = {"safe", "warning", "danger"}


class HubError(Exception):
    """可直接展示给维护者的内容错误。"""


@dataclass(frozen=True)
class ScriptEntry:
    script_id: str
    updated: str


README_TEMPLATE = """---
title: {title}
description: 请补充脚本用途和适用场景。
os: ["Linux"]
tags: []
updated: {updated}
danger: warning
dangerMessage: 请阅读源码并确认影响范围后执行。
---

# {title}

请补充脚本说明。

## 适用环境

- 操作系统：Linux
- 权限：按实际情况填写

## 使用方法

```bash
sudo bash script.sh
```

## 验证

请补充执行后的验证方法。
"""


SCRIPT_TEMPLATE = """#!/usr/bin/env bash
set -Eeuo pipefail

# 请在这里实现脚本逻辑。
echo "TODO: implement {script_id}"
"""


def parse_value(raw: str, *, file: Path, key: str) -> Any:
    """解析站点支持的 Front Matter 标量和 JSON 风格数组。"""
    value = raw.strip()
    if value.startswith(("[", "{")):
        try:
            return json.loads(value)
        except json.JSONDecodeError as exc:
            raise HubError(f"{file}: 字段 {key} 不是有效的 JSON 数组或对象") from exc
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
        return value[1:-1]
    return value


def read_front_matter(file: Path) -> dict[str, Any]:
    if not file.is_file():
        raise HubError(f"缺少说明文档：{file.relative_to(ROOT)}")

    lines = file.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0] != "---":
        raise HubError(f"{file.relative_to(ROOT)}: 文件头缺少 ---")

    try:
        end = lines.index("---", 1)
    except ValueError as exc:
        raise HubError(f"{file.relative_to(ROOT)}: Front Matter 未闭合") from exc

    attributes: dict[str, Any] = {}
    for number, line in enumerate(lines[1:end], start=2):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if ":" not in line:
            raise HubError(f"{file.relative_to(ROOT)}:{number}: 字段格式应为 key: value")
        key, raw = line.split(":", 1)
        key = key.strip()
        if not key:
            raise HubError(f"{file.relative_to(ROOT)}:{number}: 字段名不能为空")
        attributes[key] = parse_value(raw, file=file.relative_to(ROOT), key=key)
    return attributes


def require_string(attributes: dict[str, Any], key: str, file: Path) -> str:
    value = attributes.get(key)
    if not isinstance(value, str) or not value.strip():
        raise HubError(f"{file.relative_to(ROOT)}: {key} 必须是非空字符串")
    return value.strip()


def validate_script(directory: Path) -> ScriptEntry:
    script_id = directory.name
    if not ID_PATTERN.fullmatch(script_id):
        raise HubError(f"无效目录名：scripts/{script_id}，只允许小写字母、数字和短横线")

    readme = directory / "README.md"
    attributes = read_front_matter(readme)
    for key in ("title", "description", "updated", "danger", "dangerMessage"):
        require_string(attributes, key, readme)

    for key in ("os", "tags"):
        value = attributes.get(key)
        if not isinstance(value, list) or not all(isinstance(item, str) and item.strip() for item in value):
            raise HubError(f"{readme.relative_to(ROOT)}: {key} 必须是字符串数组")
    if not attributes["os"]:
        raise HubError(f"{readme.relative_to(ROOT)}: os 不能为空")

    if attributes["danger"] not in RISK_LEVELS:
        raise HubError(f"{readme.relative_to(ROOT)}: danger 只允许 safe、warning、danger")
    try:
        date.fromisoformat(attributes["updated"])
    except ValueError as exc:
        raise HubError(f"{readme.relative_to(ROOT)}: updated 必须是 YYYY-MM-DD") from exc

    file_definitions = attributes.get("files")
    if file_definitions is None:
        file_definitions = [{"name": attributes.get("source", "script.sh")}]
    if not isinstance(file_definitions, list) or not file_definitions:
        raise HubError(f"{readme.relative_to(ROOT)}: files 必须是非空数组")

    for definition in file_definitions:
        file_info = {"name": definition} if isinstance(definition, str) else definition
        if not isinstance(file_info, dict):
            raise HubError(f"{readme.relative_to(ROOT)}: files 中的项目必须是文件名或对象")
        source_name = file_info.get("name")
        if not isinstance(source_name, str) or Path(source_name).name != source_name:
            raise HubError(f"{readme.relative_to(ROOT)}: files 中的 name 必须是当前目录内的文件名")
        file_os = file_info.get("os", attributes["os"])
        if not isinstance(file_os, list) or not file_os or not all(isinstance(item, str) and item for item in file_os):
            raise HubError(f"{readme.relative_to(ROOT)}: {source_name} 的 os 必须是非空字符串数组")
        if not (directory / source_name).is_file():
            raise HubError(f"缺少源码：{(directory / source_name).relative_to(ROOT)}")

    return ScriptEntry(script_id=script_id, updated=attributes["updated"])


def discover_scripts() -> list[ScriptEntry]:
    if not SCRIPTS_DIR.is_dir():
        raise HubError("缺少 scripts 目录")
    entries = [validate_script(path) for path in SCRIPTS_DIR.iterdir() if path.is_dir()]
    entries.sort(key=lambda item: item.script_id)
    entries.sort(key=lambda item: item.updated, reverse=True)
    return entries


def rendered_index() -> str:
    ids = [entry.script_id for entry in discover_scripts()]
    return json.dumps(ids, ensure_ascii=False, indent=2) + "\n"


def generate_index(check_only: bool) -> int:
    expected = rendered_index()
    current = INDEX_FILE.read_text(encoding="utf-8") if INDEX_FILE.exists() else ""
    if current == expected:
        print(f"索引已是最新：{len(json.loads(expected))} 个脚本")
        return 0
    if check_only:
        print("索引不是最新，请运行：python3 hub.py index g", file=sys.stderr)
        return 1

    temporary = INDEX_FILE.with_suffix(".json.tmp")
    temporary.write_text(expected, encoding="utf-8")
    temporary.replace(INDEX_FILE)
    print(f"已生成 scripts.json：{len(json.loads(expected))} 个脚本")
    return 0


def create_script(script_id: str) -> int:
    if not ID_PATTERN.fullmatch(script_id):
        raise HubError("脚本 ID 只允许小写字母、数字和短横线")

    directory = SCRIPTS_DIR / script_id
    if directory.exists():
        raise HubError(f"目录已存在：{directory.relative_to(ROOT)}")

    title = script_id.replace("-", " ")
    directory.mkdir(parents=True)
    (directory / "README.md").write_text(
        README_TEMPLATE.format(title=title, updated=date.today().isoformat()),
        encoding="utf-8",
    )
    script = directory / "script.sh"
    script.write_text(SCRIPT_TEMPLATE.format(script_id=script_id), encoding="utf-8")
    script.chmod(script.stat().st_mode | 0o111)

    print(f"已创建：scripts/{script_id}/")
    print("请完善 README.md 和 script.sh，然后运行：python3 hub.py index g")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Awesome Script Hub 内容维护工具")
    commands = parser.add_subparsers(dest="command", required=True)

    new_parser = commands.add_parser("new", help="创建脚本目录和模板")
    new_parser.add_argument("script_id", help="脚本目录 ID，例如 docker-cleanup")

    index_parser = commands.add_parser("index", help="生成或检查 scripts.json")
    index_parser.add_argument("action", nargs="?", default="g", choices=("g", "check"))
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        if args.command == "new":
            return create_script(args.script_id)
        return generate_index(check_only=args.action == "check")
    except (HubError, OSError) as exc:
        print(f"错误：{exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
