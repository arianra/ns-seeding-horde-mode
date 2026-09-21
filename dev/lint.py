#!/usr/bin/env python3
"""Static gate for the mod's Lua — driven by dev/lint.sh.

One hard check, three advisories:

  FAIL  every file under source/ parses as Lua 5.1 (the engine's dialect)
  WARN  an extension module does not end with `return <module>` (convention only)
  WARN  a world API is called at file scope (runs before the world exists)
  WARN  a function body longer than 60 lines

The single hard rule is the parse: it is the only one the engine itself enforces
(`loadfile` fails the whole extension), and it is what a 2-minute server boot would
otherwise cost us to learn.

Run: uv run --with luaparser python3 dev/lint.py
Exit 0 = clean (warnings allowed), 1 = parse failures, 2 = the tool itself broke.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

try:
    from luaparser import ast as lua_ast
except ImportError:
    print("lint: luaparser unavailable — run through dev/lint.sh (uv provides it)", file=sys.stderr)
    sys.exit(2)

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "source"
MAX_FUNC_LINES = 60

# Comments would otherwise trip the pattern checks: a doc block that *mentions*
# GetGamerules() is not a call at file scope. Newlines are preserved so reported
# line numbers still point at the source.
BLOCK_COMMENT = re.compile(r"--\[\[.*?\]\]", re.DOTALL)
LINE_COMMENT = re.compile(r"--[^\n]*")

# Before the world exists GetGamerules() is nil and reaching into it crashes
# Gamerules_Global (spike zpw), so these are only safe inside a function that
# runs after world init.
WORLD_API = re.compile(r"\b(GetGamerules|CreateEntity|Pathing\.\w+|Server\.\w+|Shared\.GetEntit\w+)\s*\(")
FUNC_OPEN = re.compile(r"^\s*function\s+")
FUNC_CLOSE = re.compile(r"^\s*end\s*$")
RETURN_MODULE = re.compile(r"^\s*return\s+\w+\s*$")

failures: list[str] = []
warnings: list[str] = []


def rel(path: Path) -> str:
    return str(path.relative_to(ROOT))


def lua_files() -> list[Path]:
    return sorted(p for p in SOURCE.rglob("*.lua") if ".git" not in p.parts)


def strip_comments(text: str) -> str:
    return BLOCK_COMMENT.sub(lambda m: "\n" * m.group(0).count("\n"), text)


def check_parses(path: Path, text: str) -> None:
    try:
        lua_ast.parse(text)
    except Exception as exc:  # luaparser raises different shapes per failure kind
        first = str(exc).splitlines()[0] if str(exc) else exc.__class__.__name__
        failures.append(f"{rel(path)}: not valid Lua 5.1 — {first[:180]}")


def check_returns_module(path: Path, text: str) -> None:
    if "extensions" not in path.parts:
        return
    lines = [line for line in text.rstrip().splitlines() if line.strip()]
    # Shine's DoFileWithArgs (extensions.lua:57) only loadfile + calls, so a nil
    # return is legal; this is repo convention, not an engine requirement.
    if not lines or not RETURN_MODULE.match(lines[-1]):
        warnings.append(f"{rel(path)}: last line is not `return <module>` (convention)")


def check_file_scope_world_api(path: Path, source: str) -> None:
    depth = 0
    for number, raw in enumerate(source.splitlines(), start=1):
        code = LINE_COMMENT.sub("", raw)
        opens = len(re.findall(r"\bfunction\b", code))
        closes = len(re.findall(r"\bend\b", code))
        if depth == 0 and code.strip() and WORLD_API.search(code):
            warnings.append(f"{rel(path)}:{number}: world API at file scope (runs before world init)")
        depth = max(0, depth + opens - closes)


def check_function_length(path: Path, source: str) -> None:
    lines = source.splitlines()
    start = None
    for number, line in enumerate(lines, start=1):
        code = LINE_COMMENT.sub("", line)
        if start is None and FUNC_OPEN.match(code):
            start = number
        elif start is not None and FUNC_CLOSE.match(code):
            if number - start > MAX_FUNC_LINES:
                warnings.append(f"{rel(path)}:{start}: function spans {number - start} lines (>{MAX_FUNC_LINES})")
            start = None


def main() -> int:
    files = lua_files()
    if not files:
        print("lint: no .lua files under source/ — run from the repo root", file=sys.stderr)
        return 2

    for path in files:
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as exc:
            failures.append(f"{rel(path)}: unreadable — {exc}")
            continue
        strip = strip_comments(text)
        check_parses(path, text)
        check_returns_module(path, text)
        check_file_scope_world_api(path, strip)
        check_function_length(path, strip)

    for item in warnings:
        print(f"[lint] warn  {item}")
    for item in failures:
        print(f"[lint] FAIL  {item}", file=sys.stderr)

    print(f"[lint] {len(files)} files · {len(failures)} failed · {len(warnings)} warning(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
