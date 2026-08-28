#!/usr/bin/env python3
"""
Main reflection orchestration engine.
Coordinates signal extraction, skill updates, and user review.
"""

import json
import sys
import os
from pathlib import Path
from datetime import datetime
import subprocess

# Add scripts directory to path for imports
sys.path.insert(0, str(Path(__file__).parent))

from extract_signals import extract_signals
from update_skill import update_skill
from present_review import present_review
from opencode_paths import skills_root, reflect_skill_dir

def _parse_args():
    """Parse reflect flags.

    Flags:
      --non-interactive            force non-interactive review mode
      --confidence-min=LEVEL       auto-apply at/above LEVEL (LOW/MEDIUM/HIGH)
    The first non-flag argument is the transcript path (env TRANSCRIPT_PATH
    still takes precedence).
    """
    non_interactive = False
    confidence_min = None
    transcript_path = os.getenv('TRANSCRIPT_PATH')
    rest = []
    for arg in sys.argv[1:]:
        if arg == '--non-interactive':
            non_interactive = True
        elif arg.startswith('--confidence-min='):
            confidence_min = arg.split('=', 1)[1]
        else:
            rest.append(arg)
    if transcript_path is None and rest:
        transcript_path = rest[0]
    return transcript_path, non_interactive, confidence_min


def main():
    """Main reflection workflow"""
    # 1. Get transcript path / flags from env or arguments
    transcript_path, non_interactive, confidence_min = _parse_args()

    print("🧠 Reflection Analysis Starting...")

    # 2. Extract signals from transcript
    try:
        signals_by_skill = extract_signals(transcript_path)
    except Exception as e:
        print(f"✗ Error extracting signals: {e}")
        return 1

    if not signals_by_skill:
        print("✓ No improvement suggestions found")
        return 0

    print(f"Found signals in {len(signals_by_skill)} skill(s)")

    # 3. Present for review
    try:
        approved_changes = present_review(
            signals_by_skill,
            non_interactive=non_interactive,
            confidence_min=confidence_min
        )
    except KeyboardInterrupt:
        print("\n\nReview interrupted by user")
        return 1
    except Exception as e:
        print(f"✗ Error during review: {e}")
        return 1

    if not approved_changes:
        print("\nNo changes approved")
        return 0

    # 4. Apply changes with backups
    success_count = 0
    for change in approved_changes:
        try:
            if update_skill(change):
                success_count += 1
        except Exception as e:
            print(f"✗ Error updating {change['skill_name']}: {e}")

    if success_count == 0:
        print("\n✗ No skills were updated successfully")
        return 1

    # 5. Git commit
    try:
        commit_changes(approved_changes)
    except Exception as e:
        print(f"Warning: Git commit failed: {e}")
        print("Changes were applied but not committed. Commit manually if needed.")

    print(f"\n✓ {success_count} skill(s) updated successfully")

    # 6. Update reflection timestamp
    update_last_reflection_timestamp()

    return 0

def commit_changes(changes):
    """Commit skill updates to git"""
    skills_dir = skills_root()

    # Check if git repo exists
    if not (skills_dir / '.git').exists():
        print("\nNote: Skills directory is not a git repository")
        print(f"Initialize with: cd {skills_dir} && git init")
        return

    skill_names = [c['skill_name'] for c in changes]

    # Build commit message
    message_lines = ["refactor(skills): apply reflection learnings\n"]
    message_lines.append("Signals detected:")

    for change in changes:
        proposed = change.get('proposed_updates', {})
        high_count = len(proposed.get('high_confidence', []))
        medium_count = len(proposed.get('medium_confidence', []))
        low_count = len(proposed.get('low_confidence', []))

        if high_count:
            message_lines.append(f"- HIGH ({high_count}): {change['skill_name']}")
        if medium_count:
            message_lines.append(f"- MEDIUM ({medium_count}): {change['skill_name']}")
        if low_count:
            message_lines.append(f"- LOW ({low_count}): {change['skill_name']}")

    message_lines.append(f"\nSkills updated: {', '.join(skill_names)}\n")

    # Add session info if available
    session_id = os.getenv('SESSION_ID', 'unknown')
    auto_reflected = os.getenv('AUTO_REFLECTED', 'false')
    message_lines.append(f"Session: {session_id}")
    message_lines.append(f"Auto-reflected: {auto_reflected}\n")

    message_lines.append("🤖 Generated with the Reflect self-learning system")
    message_lines.append("Co-Authored-By: Reflect <reflect@local>")

    commit_message = "\n".join(message_lines)

    try:
        # Stage all changes in skills directory
        subprocess.run(['git', 'add', '.'], cwd=skills_dir, check=True, capture_output=True)

        # Commit
        subprocess.run(['git', 'commit', '-m', commit_message], cwd=skills_dir, check=True, capture_output=True)

        print("\n✓ Changes committed to git")

        # Note: We don't auto-push for safety
        # User can push manually if they want
        print(f"  (Run 'cd {skills_dir} && git push' to push to remote)")

    except subprocess.CalledProcessError as e:
        # Check if it's just "nothing to commit"
        if b'nothing to commit' in e.stdout or b'nothing to commit' in e.stderr:
            print("\nNote: Git reported nothing to commit (files may be unchanged)")
        else:
            raise

def update_last_reflection_timestamp():
    """Update the last reflection timestamp to prevent duplicates"""
    timestamp_file = reflect_skill_dir() / '.state' / 'last-reflection.timestamp'
    try:
        with open(timestamp_file, 'w') as f:
            f.write(datetime.now().isoformat())
    except Exception as e:
        print(f"Warning: Could not update timestamp: {e}")

if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\n\nReflection cancelled by user")
        sys.exit(1)
    except Exception as e:
        print(f"\n✗ Unexpected error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
