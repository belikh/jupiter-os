#!/usr/bin/env python3
"""
Presents proposed changes for user review with interactive approval.

v1.3.0: Added meta-learning feedback logging (passive, non-blocking)
"""

import json
import os
import difflib
from pathlib import Path
from typing import Dict, List, Any
import sys
from datetime import datetime

# Meta-learning integration (optional, passive)
try:
    from meta_learning import log_feedback
    META_LEARNING_AVAILABLE = True
except ImportError:
    META_LEARNING_AVAILABLE = False

from opencode_paths import skills_root, reflect_skill_dir


# Confidence ranking: LOW < MEDIUM < HIGH
_CONFIDENCE_RANK = {'LOW': 1, 'MEDIUM': 2, 'HIGH': 3}

# Proposed-change bucket -> confidence rank
_BUCKET_RANK = {
    'high_confidence': 3,
    'medium_confidence': 2,
    'low_confidence': 1,
}


def _confidence_rank(level: str) -> int:
    return _CONFIDENCE_RANK.get(str(level or 'LOW').upper(), 1)


def _filter_proposed(proposed: Dict[str, List[Dict[str, Any]]], threshold_rank: int) -> Dict[str, List[Dict[str, Any]]]:
    """Keep only non-empty buckets whose confidence rank meets the threshold."""
    return {
        bucket: items
        for bucket, items in proposed.items()
        if items and _BUCKET_RANK.get(bucket, 1) >= threshold_rank
    }


def present_review(signals_by_skill: Dict[str, List[Dict[str, Any]]],
                   non_interactive=None,
                   confidence_min=None) -> List[Dict[str, Any]]:
    """
    Present signals and proposed changes for approval.

    In interactive mode the user is prompted per skill (via input()).
    In non-interactive mode (no TTY, REFLECT_NONINTERACTIVE=1, or
    --non-interactive) only changes at or above `confidence_min` are
    auto-applied and a run log is written. No input() is ever called.

    Returns list of approved changes.
    """
    if not signals_by_skill:
        return []

    # Resolve non-interactive mode.
    if non_interactive is None:
        non_interactive = (
            os.getenv('REFLECT_NONINTERACTIVE') == '1'
            or '--non-interactive' in sys.argv
            or not sys.stdin.isatty()
        )

    # Resolve confidence threshold (LOW < MEDIUM < HIGH).
    confidence_min = (confidence_min or os.getenv('REFLECT_CONFIDENCE_MIN') or 'HIGH').upper()
    threshold_rank = _confidence_rank(confidence_min)

    if non_interactive:
        return _present_non_interactive(signals_by_skill, threshold_rank)

    return _present_interactive(signals_by_skill)


def _present_interactive(signals_by_skill: Dict[str, List[Dict[str, Any]]]) -> List[Dict[str, Any]]:
    """Original interactive review loop (unchanged behavior)."""
    print("\n" + "="*60)
    print("REFLECTION REVIEW")
    print("="*60 + "\n")

    # Show summary
    print("## Signals Detected\n")
    for skill, signals in signals_by_skill.items():
        high = len([s for s in signals if s.get('confidence') == 'HIGH'])
        medium = len([s for s in signals if s.get('confidence') == 'MEDIUM'])
        low = len([s for s in signals if s.get('confidence') == 'LOW'])
        print(f"**{skill}**:")
        if high: print(f"  - HIGH: {high} corrections")
        if medium: print(f"  - MEDIUM: {medium} approvals")
        if low: print(f"  - LOW: {low} observations")

    print("\n" + "-"*60 + "\n")

    approved_changes = []

    for skill_name, signals in signals_by_skill.items():
        print(f"\n## {skill_name}\n")

        # Generate proposed changes
        proposed = generate_proposed_changes(skill_name, signals)

        if not proposed['high_confidence'] and not proposed['medium_confidence'] and not proposed['low_confidence']:
            print("No actionable changes proposed for this skill.\n")
            continue

        # Show diff
        show_diff(skill_name, proposed)

        # Get approval
        response = input("\n[A]pprove / [M]odify / [S]kip / [Q]uit? ").strip().upper()

        if response == 'A' or response == '':
            approved_changes.append({
                'skill_name': skill_name,
                'signals': signals,
                'proposed_updates': proposed
            })
            print(f"✓ Approved changes to {skill_name}")

            # Meta-learning: log acceptance (passive, non-blocking)
            _log_decision(signals, skill_name, 'accept')

        elif response == 'M':
            # Natural language modification
            modification = input("Describe modification: ").strip()
            if modification:
                modified = apply_modification(proposed, modification)
                approved_changes.append({
                    'skill_name': skill_name,
                    'signals': signals,
                    'proposed_updates': modified
                })
                print(f"✓ Applied modified changes to {skill_name}")

                # Meta-learning: log modification
                _log_decision(signals, skill_name, 'modify', modification)
            else:
                print(f"⊘ Skipped {skill_name} (no modification provided)")
                _log_decision(signals, skill_name, 'skip')

        elif response == 'Q':
            print("Review aborted")
            _log_decision(signals, skill_name, 'quit')
            return []

        else:  # Skip
            print(f"⊘ Skipped {skill_name}")
            _log_decision(signals, skill_name, 'skip')

    return approved_changes


def _present_non_interactive(signals_by_skill: Dict[str, List[Dict[str, Any]]], threshold_rank: int) -> List[Dict[str, Any]]:
    """Auto-apply changes at or above the confidence threshold; never call input()."""
    print("\n" + "="*60)
    print("REFLECTION REVIEW (non-interactive)")
    print("="*60 + "\n")

    approved_changes = []
    skipped = []

    for skill_name, signals in signals_by_skill.items():
        proposed = generate_proposed_changes(skill_name, signals)

        if not proposed['high_confidence'] and not proposed['medium_confidence'] and not proposed['low_confidence']:
            skipped.append(skill_name)
            _log_decision(signals, skill_name, 'skip')
            continue

        filtered = _filter_proposed(proposed, threshold_rank)

        if filtered:
            approved_changes.append({
                'skill_name': skill_name,
                'signals': signals,
                'proposed_updates': filtered
            })
            _log_decision(signals, skill_name, 'accept')
            print(f"✓ Auto-applied (>= threshold) changes to {skill_name}")
        else:
            skipped.append(skill_name)
            _log_decision(signals, skill_name, 'skip')
            print(f"⊘ Skipped {skill_name} (below confidence threshold)")

    write_run_log(approved_changes, skipped)
    return approved_changes


def write_run_log(approved: List[Dict[str, Any]], skipped: List[str]):
    """Persist a JSON run log under reflect_skill_dir()/.state/reflect_runs/."""
    try:
        run_dir = reflect_skill_dir() / '.state' / 'reflect_runs'
        run_dir.mkdir(parents=True, exist_ok=True)
        timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
        run_file = run_dir / f'run_{timestamp}.json'
        payload = {
            'timestamp': datetime.now().isoformat(),
            'mode': 'non_interactive',
            'approved': [
                {
                    'skill_name': c['skill_name'],
                    'buckets': sorted(c['proposed_updates'].keys()),
                }
                for c in approved
            ],
            'skipped': skipped,
        }
        with open(run_file, 'w') as f:
            json.dump(payload, f, indent=2)
    except Exception as e:
        print(f"Warning: Could not write run log: {e}")


def _log_decision(signals: List[Dict], skill_name: str, decision: str, modification: str = None):
    """
    Log decision to meta-learning system.

    This is completely passive and non-blocking.
    Failures are silently ignored to never break core workflow.
    """
    if not META_LEARNING_AVAILABLE:
        return

    try:
        for signal in signals:
            log_feedback(
                pattern_type=signal.get('type', 'unknown'),
                pattern_regex=signal.get('detection_method', 'regex'),
                skill_name=skill_name,
                confidence_level=signal.get('confidence', 'UNKNOWN'),
                decision=decision,
                signal_content=signal.get('content', ''),
                modification=modification
            )
    except Exception:
        # Silent fail - meta-learning should never break core workflow
        pass


def generate_proposed_changes(skill_name: str, signals: List[Dict[str, Any]]) -> Dict[str, List[Dict[str, Any]]]:
    """Generate proposed skill updates from signals"""
    updates = {
        'high_confidence': [],
        'medium_confidence': [],
        'low_confidence': []
    }

    for signal in signals:
        confidence = signal.get('confidence', 'LOW')

        if confidence == 'HIGH':
            updates['high_confidence'].append({
                'description': extract_correction_description(signal),
                'old_approach': extract_old_approach(signal),
                'new_approach': extract_new_approach(signal)
            })
        elif confidence == 'MEDIUM':
            updates['medium_confidence'].append({
                'pattern': extract_pattern_name(signal),
                'description': extract_pattern_description(signal)
            })
        else:  # LOW
            updates['low_confidence'].append({
                'suggestion': signal.get('suggestion', signal.get('description', 'Unknown'))
            })

    return updates


def extract_correction_description(signal: Dict[str, Any]) -> str:
    """Extract description from correction signal"""
    if 'description' in signal:
        return signal['description']

    content = signal.get('content', '')
    match = signal.get('match', ())

    if match and len(match) >= 2:
        return f"Use '{match[1]}' instead of '{match[0]}'"
    elif match and len(match) == 1:
        return f"Correction: {match[0]}"

    return "User provided correction"


def extract_old_approach(signal: Dict[str, Any]) -> str:
    """Extract old approach from signal"""
    match = signal.get('match', ())
    if match and len(match) >= 1:
        return str(match[0])[:100]  # Limit length

    # Try to extract from content
    content = signal.get('content', '')
    return content[:100]


def extract_new_approach(signal: Dict[str, Any]) -> str:
    """Extract new approach from signal"""
    match = signal.get('match', ())
    if match and len(match) >= 2:
        return str(match[1])[:100]  # Limit length

    # Fallback to content
    content = signal.get('content', '')
    return content[:100]


def extract_pattern_name(signal: Dict[str, Any]) -> str:
    """Extract pattern name from approval signal"""
    return signal.get('type', 'approval').capitalize()


def extract_pattern_description(signal: Dict[str, Any]) -> str:
    """Extract pattern description from approval signal"""
    if 'description' in signal:
        return signal['description']

    previous = signal.get('previous_approach', '')
    if previous:
        return f"Approved approach: {previous[:100]}"

    return "Approved user's approach"


def show_diff(skill_name: str, proposed_updates: Dict[str, List[Dict[str, Any]]]):
    """Show unified diff of proposed changes"""
    skill_path = skills_root() / skill_name / 'SKILL.md'

    if not skill_path.exists():
        print(f"Skill file not found: {skill_path}")
        return

    try:
        with open(skill_path) as f:
            original = f.read()

        # Simulate applying updates
        from update_skill import parse_skill_file, apply_high_confidence_update, apply_medium_confidence_update, apply_low_confidence_update, reconstruct_skill_file

        frontmatter, body = parse_skill_file(original)

        # Apply proposed changes
        for update in proposed_updates.get('high_confidence', []):
            body = apply_high_confidence_update(body, update)

        for update in proposed_updates.get('medium_confidence', []):
            body = apply_medium_confidence_update(body, update)

        for update in proposed_updates.get('low_confidence', []):
            body = apply_low_confidence_update(body, update)

        updated = reconstruct_skill_file(frontmatter, body)

        # Generate diff
        diff = list(difflib.unified_diff(
            original.splitlines(keepends=True),
            updated.splitlines(keepends=True),
            fromfile=f'{skill_name}/SKILL.md (current)',
            tofile=f'{skill_name}/SKILL.md (proposed)',
            lineterm=''
        ))

        if diff:
            print("\n```diff")
            for line in diff[:100]:  # Limit to first 100 lines
                print(line.rstrip())
            if len(diff) > 100:
                print(f"\n... ({len(diff) - 100} more lines)")
            print("```\n")
        else:
            print("\nNo changes to display.\n")

    except Exception as e:
        print(f"Error generating diff: {e}")


def apply_modification(proposed: Dict[str, List[Dict[str, Any]]], user_instruction: str) -> Dict[str, List[Dict[str, Any]]]:
    """Apply natural language modification to proposed changes"""
    # For now, this is a placeholder
    # In a full implementation, this would use the agent to interpret the modification
    print(f"Note: Natural language modification '{user_instruction}' would be applied here")
    print("(This feature requires agent integration - using original proposal for now)")
    return proposed


if __name__ == '__main__':
    # Test mode
    test_signals = {
        'test-skill': [
            {
                'confidence': 'HIGH',
                'type': 'correction',
                'content': "No, don't use X, use Y instead",
                'match': ('X', 'Y'),
                'description': 'Use Y instead of X'
            },
            {
                'confidence': 'MEDIUM',
                'type': 'approval',
                'description': 'Approved this approach',
                'previous_approach': 'Used pattern Z successfully'
            }
        ]
    }

    approved = present_review(test_signals)
    print(f"\nApproved {len(approved)} change(s)")
