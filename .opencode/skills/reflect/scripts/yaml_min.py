#!/usr/bin/env python3
"""
Minimal YAML frontmatter parser/dumper (no external dependencies).

Supports only what the Reflect skill needs:
  - top-level plain scalars: string / int / float / bool / null
  - folded '>' and literal '|' block scalars (more-indented following lines)

This replaces PyYAML so the Reflect scripts run without it installed.
"""

import re


def _parse_scalar(s: str):
    """Parse a plain (inline) scalar value into a Python object."""
    s = s.strip()
    if s == "":
        return ""
    # Strip surrounding quotes for simple quoted strings
    if len(s) >= 2 and ((s[0] == '"' and s[-1] == '"') or (s[0] == "'" and s[-1] == "'")):
        return s[1:-1]
    low = s.lower()
    if low == "true":
        return True
    if low == "false":
        return False
    if low in ("null", "~"):
        return None
    # int (but reject things like "123abc")
    try:
        return int(s)
    except ValueError:
        pass
    # float
    try:
        return float(s)
    except ValueError:
        pass
    return s


def parse_frontmatter(content: str):
    """
    Split ``content`` into (frontmatter_dict, body).

    The document must begin with a YAML frontmatter block delimited by '---'.
    Only top-level keys are parsed. Block scalars ('>' / '|') collect the
    more-indented following lines into a multiline string.
    """
    parts = content.split("---", 2)
    if len(parts) < 3:
        raise ValueError("Invalid SKILL.md format: missing YAML frontmatter delimiters")

    fm_text = parts[1]
    body = parts[2].strip()

    data = {}
    lines = fm_text.split("\n")
    n = len(lines)
    i = 0

    # Skip any leading blank lines before the first key
    while i < n and lines[i].strip() == "":
        i += 1

    while i < n:
        line = lines[i]
        stripped = line.strip()
        if stripped == "":
            i += 1
            continue

        colon_idx = stripped.find(":")
        if colon_idx < 0:
            # Not a key line; skip defensively
            i += 1
            continue

        key = stripped[:colon_idx].strip()
        if key == "":
            i += 1
            continue
        inline = stripped[colon_idx + 1:].strip()

        base_indent = len(line) - len(line.lstrip(" "))

        if inline.startswith(">") or inline.startswith("|"):
            # Block scalar: collect following lines that are more-indented
            # than the key line.
            block_lines = []
            block_indent = None
            j = i + 1
            while j < n:
                bl = lines[j]
                if bl.strip() == "":
                    # A blank line terminates the block (it is not more-indented).
                    break
                bl_indent = len(bl) - len(bl.lstrip(" "))
                if bl_indent > base_indent:
                    if block_indent is None:
                        block_indent = bl_indent
                    block_lines.append(bl[block_indent:])
                    j += 1
                else:
                    break
            i = j
            data[key] = "\n".join(block_lines)
        else:
            data[key] = _parse_scalar(inline)
            i += 1

    return data, body


def dump_frontmatter(data: dict, body: str) -> str:
    """
    Reconstruct a SKILL.md document from ``data`` and ``body``.

    Returns: "---\n" + lines + "---\n\n" + body
    """
    out_lines = []
    for key, val in data.items():
        if isinstance(val, bool):
            out_lines.append(f"{key}: {'true' if val else 'false'}")
        elif isinstance(val, (int, float)):
            out_lines.append(f"{key}: {val}")
        elif isinstance(val, str):
            if "\n" in val:
                out_lines.append(f"{key}: >")
                for sub in val.split("\n"):
                    out_lines.append(f"  {sub}")
            else:
                out_lines.append(f"{key}: {val}")
        elif val is None:
            out_lines.append(f"{key}: null")
        else:
            # Fallback: stringify
            out_lines.append(f"{key}: {val}")

    return "---\n" + "\n".join(out_lines) + "\n---\n\n" + body


def validate_frontmatter(data: dict):
    """Raise ValueError if required frontmatter fields are missing."""
    if "name" not in data:
        raise ValueError("Missing required 'name' field in frontmatter")
    if "description" not in data:
        raise ValueError("Missing required 'description' field in frontmatter")
