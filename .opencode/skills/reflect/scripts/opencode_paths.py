#!/usr/bin/env python3
"""
OpenCode-aware path resolution for the Reflect skill.

The upstream scripts hardcode a vendor-specific skills path. This module
centralises path resolution so the same scripts work under OpenCode,
where skills live in ~/.opencode/skills and <project>/.opencode/skills.

Resolution order for the skills root:
  1. $SKILLS_ROOT   (explicit override)
  2. <cwd>/.opencode/skills  (walks up from the current directory; covers the
     project-local jupiter-os/.opencode/skills case)
  3. ~/.opencode/skills      (user-global OpenCode skills)
  4. ~/.claude/skills        (fallback: original vendor layout)
"""
from __future__ import annotations

import os
from pathlib import Path


def skills_root() -> Path:
    env = os.environ.get("SKILLS_ROOT")
    if env:
        return Path(env).expanduser()

    found = _find_project_skills()
    if found is not None:
        return found

    user_global = Path.home() / ".opencode" / "skills"
    if user_global.is_dir():
        return user_global

    return Path.home() / ".claude" / "skills"


def _find_project_skills() -> Path | None:
    d = Path.cwd().resolve()
    for parent in [d, *d.parents]:
        cand = parent / ".opencode" / "skills"
        if cand.is_dir():
            return cand
    return None


def reflect_skill_dir() -> Path:
    return skills_root() / "reflect"


def reflect_data_dir() -> Path:
    # Ledger / meta storage. Upstream used ~/.claude/reflect; we keep it
    # self-contained inside the reflect skill so it follows the skill around.
    return reflect_skill_dir() / "data"
