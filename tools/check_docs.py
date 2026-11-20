#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""文档链接与体量自检。

三类检查：
  1. 死链：Markdown 相对链接目标必须存在（跳过 http(s)/mailto/纯锚点）。
  2. 失效行号锚：`design.md:L749`、`development-plan.md:473` 这类行号引用一律禁止——
     拆分后行号必然漂移，须改用 `§锚` 或指向具体分册文件。
  3. 体量：单文件行数超过阈值时告警（WARN，不阻断），避免再次长出千行单文件。

退出码：0 = 无 FAIL；1 = 存在 FAIL（死链或失效行号锚）。

用法：
    python tools/check_docs.py            # 检查 docs/
    python tools/check_docs.py --root docs --max-lines 400
"""

import argparse
import io
import os
import re
import sys

LINK_RE = re.compile(r"(?<!\!)\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
SKIP_SCHEME = re.compile(r"^(https?:|mailto:|tel:|ftp:|data:|#)")
# 行号锚：design.md:L749 / design.md:749 / design.md:921-928 / design.md L846
LINE_ANCHOR = re.compile(
    r"(design\.md|development-plan\.md)\s*(?::|：|\s)\s*(L\d+(?:\s*[-–~]\s*\d+)?)"
)

# 历史核验报告记录的是「当时那一版文件的行号」，属不可改写的存档证据，
# 允许保留行号并要求同时出现「行版」口径说明。
LINE_ANCHOR_ALLOW_DIRS = ("docs/design/review/",)


def iter_md(root, exclude_dirs):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(
            d for d in dirnames if not d.startswith(".") and d not in exclude_dirs
        )
        for name in sorted(filenames):
            if name.endswith(".md"):
                yield os.path.join(dirpath, name)


def read_lines(path):
    with io.open(path, encoding="utf-8") as f:
        return f.read().split("\n")


def check_links(path, lines, problems):
    base = os.path.dirname(path)
    for lineno, line in enumerate(lines, 1):
        for m in LINK_RE.finditer(line):
            target = m.group(1)
            if SKIP_SCHEME.match(target):
                continue
            core = target.split("#", 1)[0]
            if not core:
                continue
            resolved = os.path.normpath(os.path.join(base, core.replace("/", os.sep)))
            if not os.path.exists(resolved):
                problems.append(
                    ("FAIL", path, lineno, "死链：%s（解析为 %s）" % (target, resolved))
                )


def check_line_anchors(path, lines, problems, repo_root):
    rel = os.path.relpath(path, repo_root).replace(os.sep, "/")
    allowed = any(rel.startswith(d) for d in LINE_ANCHOR_ALLOW_DIRS)
    for lineno, line in enumerate(lines, 1):
        for m in LINE_ANCHOR.finditer(line):
            problems.append(
                (
                    "WARN" if allowed else "FAIL",
                    path,
                    lineno,
                    "行号锚 `%s`%s" % (m.group(0), "（存档报告，允许保留）" if allowed else "，须改写为 §锚或指向分册文件"),
                )
            )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default="docs")
    ap.add_argument("--max-lines", type=int, default=400)
    ap.add_argument("--exclude", default="node_modules,lib,vendor,bin")
    args = ap.parse_args()

    repo_root = os.path.abspath(os.getcwd())
    root = os.path.join(repo_root, args.root)
    if not os.path.isdir(root):
        sys.stderr.write("root 不存在：%s\n" % root)
        return 2

    exclude = tuple(x for x in args.exclude.split(",") if x)
    problems = []
    files = list(iter_md(root, exclude))
    for path in files:
        lines = read_lines(path)
        if len(lines) > args.max_lines:
            problems.append(
                ("WARN", path, 0, "体量 %d 行 > 阈值 %d 行，建议拆分或收敛" % (len(lines), args.max_lines))
            )
        check_links(path, lines, problems)
        check_line_anchors(path, lines, problems, repo_root)

    fails = [p for p in problems if p[0] == "FAIL"]
    warns = [p for p in problems if p[0] == "WARN"]

    for level, path, lineno, msg in fails + warns:
        rel = os.path.relpath(path, repo_root).replace(os.sep, "/")
        loc = rel if lineno == 0 else "%s:%d" % (rel, lineno)
        print("%s %s | %s" % (level, loc, msg))

    print("\n检查 %d 个 Markdown 文件：FAIL %d，WARN %d" % (len(files), len(fails), len(warns)))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
