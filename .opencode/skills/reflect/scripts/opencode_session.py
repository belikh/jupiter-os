#!/usr/bin/env python3
"""
OpenCode session helpers for sourcing the current conversation transcript.

OpenCode does not write the vendor-specific ``~/.opencode/session-env/<id>/
transcript.jsonl`` files that the original Reflect skill expects. Instead it
keeps sessions in an SQLite database and exposes them through the
``opencode export <session-id>`` subcommand.

This module provides two helpers used by ``extract_signals.py``:
  * ``current_session_id()``  -- resolve the most relevant session for cwd.
  * ``opencode_export_transcript(sid)`` -- dump a session to a temp JSON file.

Both are designed to NEVER hang and to return ``None`` on any failure so the
caller can gracefully fall back.
"""

from __future__ import annotations

import os
import shutil
import sqlite3
import subprocess
import tempfile
from pathlib import Path
from typing import Optional


def _db_path() -> Path:
    """Location of the OpenCode SQLite database."""
    env = os.environ.get("OPENCODE_DB")
    if env:
        return Path(env).expanduser()
    return Path.home() / ".local" / "share" / "opencode" / "opencode.db"


def _session_rows(limit: int = 50) -> list:
    """Return session rows ordered by most-recently-updated first, or []."""
    db = _db_path()
    if not db.exists():
        return []

    conn = sqlite3.connect(str(db))
    try:
        conn.row_factory = sqlite3.Row
        cur = conn.cursor()
        # Tolerate schema differences: only order by a column we can confirm.
        cur.execute("SELECT * FROM sessions")
        cols = [c[0] for c in cur.description] if cur.description else []
        rows = cur.fetchall()
    finally:
        conn.close()

    if not rows:
        return []

    # Prefer ordering by time_updated when present, else time_created, else
    # insertion order (already DESC via a stable ORDER BY when available).
    if "time_updated" in cols:
        order_col = "time_updated"
    elif "time_created" in cols:
        order_col = "time_created"
    else:
        order_col = None

    if order_col:
        try:
            conn2 = sqlite3.connect(str(db))
            try:
                conn2.row_factory = sqlite3.Row
                c2 = conn2.cursor()
                c2.execute(
                    f"SELECT * FROM sessions ORDER BY {order_col} DESC LIMIT ?",
                    (limit,),
                )
                rows = c2.fetchall()
            finally:
                conn2.close()
        except Exception:
            # Fall back to the unordered rows already fetched.
            pass

    return list(rows)


def current_session_id() -> Optional[str]:
    """Return the id of the most relevant OpenCode session for the cwd.

    Prefers the session whose ``directory`` matches the current working
    directory; otherwise returns the most recently updated session. Returns
    ``None`` if no usable session can be determined.
    """
    try:
        rows = _session_rows()
        if not rows:
            return None

        cwd = os.getcwd()
        try:
            cwd_resolved = os.path.realpath(cwd)
        except Exception:
            cwd_resolved = os.path.abspath(cwd)

        for row in rows:
            d = row["directory"] if "directory" in row.keys() else None
            if not d:
                continue
            try:
                d_resolved = os.path.realpath(str(d))
            except Exception:
                d_resolved = os.path.abspath(str(d))
            if d_resolved == cwd_resolved:
                return str(row["id"])

        # No directory match -> most recent session.
        return str(rows[0]["id"])
    except Exception:
        return None


def opencode_export_transcript(sid: str) -> Optional[str]:
    """Export ``opencode export <sid>`` to a temp JSON file and return its path.

    IMPORTANT: an explicit ``sid`` is ALWAYS passed. ``opencode export`` with no
    arguments blocks waiting for interactive input, which would hang the skill.
    Any failure (missing binary, non-zero exit, empty output, timeout) returns
    ``None`` rather than raising or hanging.
    """
    if not sid:
        return None

    try:
        out_path = os.path.join(tempfile.gettempdir(), f"reflect_export_{sid}.json")
        opencode_bin = shutil.which("opencode") or "opencode"

        # Never invoke `opencode export` with no sid argument.
        proc = subprocess.run(
            [opencode_bin, "export", str(sid)],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=30,
        )

        if proc.returncode != 0:
            return None

        stdout = (proc.stdout or "").strip()
        if not stdout:
            return None

        with open(out_path, "w", encoding="utf-8") as f:
            f.write(stdout)

        if not os.path.exists(out_path) or os.path.getsize(out_path) == 0:
            return None

        return out_path
    except Exception:
        return None


if __name__ == "__main__":
    sid = current_session_id()
    if sid:
        print(sid)
    else:
        print("")
