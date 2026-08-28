#!/usr/bin/env python3
"""Semantic learning detection.

By default calls Groq directly via its OpenAI-compatible API. This keeps the
request tiny (just our prompt), which is required because this Groq model has
an 8000-token context limit and `opencode run` would otherwise drag in the
whole project/system context. Set REFLECT_SEMANTIC_CLI to route through
`opencode run` instead (useful for large-context models). Falls back to the
regex detector on any failure.

Advantages over regex:
- Multi-language support (works in German, Spanish, etc.)
- Better accuracy (understands intent, not just keywords)
- Extracts clean, actionable learning statements
"""
import json
import os
import subprocess
import sys
from typing import Optional, Dict, Any, List

# Default timeout for agent CLI calls (seconds)
DEFAULT_TIMEOUT = 30

# Semantic analysis prompt template
ANALYSIS_PROMPT = '''Analyze this user message from a coding session. Determine if it contains
a reusable learning, correction, or preference that should be remembered for future sessions.

Message: "{text}"

Respond ONLY with valid JSON (no markdown, no explanation):
{{
  "is_learning": true or false,
  "type": "correction" or "positive" or "explicit" or null,
  "confidence": 0.0 to 1.0,
  "reasoning": "brief 1-sentence explanation",
  "extracted_learning": "concise actionable statement, or null if not a learning"
}}

Guidelines:
- correction: User telling AI to do something differently ("use X not Y", "don't use Z")
- positive: User affirming good behavior ("perfect!", "exactly right", "great approach")
- explicit: User explicitly asking to remember ("remember: ...", "always do X")
- is_learning=true only if it's reusable across sessions (not one-time task instructions)
- confidence: How certain this is a genuine, reusable learning (0.6+ to be useful)
- extracted_learning: Should be actionable and concise (e.g., "Use uv instead of pip")
- Works for ANY language - understand intent, not just English keywords
- Filter out: questions, greetings, one-time commands, context-specific requests'''


# --- Context window cap (Groq) -------------------------------------------------
# Groq models reject prompts over their context limit; keep the total prompt
# under this many tokens. Overridable via REFLECT_MAX_CONTEXT_TOKENS.
MAX_CONTEXT_TOKENS = int(os.environ.get("REFLECT_MAX_CONTEXT_TOKENS", "8000"))
_CONTEXT_MARGIN = 800  # headroom for OpenCode's own system prompt


def _estimate_tokens(s: str) -> int:
    """Rough, conservative token estimate (~3 chars/token, plus word count)."""
    return max(len(s) // 3, s.count(" ") + 1)


def _fit_to_context(text: str) -> str:
    """Truncate `text` so the rendered prompt stays under MAX_CONTEXT_TOKENS."""
    overhead = _estimate_tokens(ANALYSIS_PROMPT)
    budget = MAX_CONTEXT_TOKENS - _CONTEXT_MARGIN - overhead
    if budget <= 0:
        budget = MAX_CONTEXT_TOKENS - _CONTEXT_MARGIN
    max_chars = max(budget * 3, 0)
    if len(text) <= max_chars:
        return text
    return "…[truncated] " + text[-max_chars:]


def semantic_analyze(
    text: str,
    timeout: int = DEFAULT_TIMEOUT,
    model: Optional[str] = None
) -> Optional[Dict[str, Any]]:
    """
    Analyze text using the agent to determine if it's a learning.

    Args:
        text: The user message to analyze
        timeout: Timeout in seconds for the agent CLI call
        model: Optional model override (e.g., "groq/openai/gpt-oss-20b")

    Returns:
        Dictionary with analysis results, or None on failure:
        {
            "is_learning": bool,
            "type": "correction" | "positive" | "explicit" | None,
            "confidence": float (0.0-1.0),
            "reasoning": str,
            "extracted_learning": str | None
        }
    """
    if not text or not text.strip():
        return None

    # Enforce Groq's context cap: truncate the message if the full prompt would
    # exceed REFLECT_MAX_CONTEXT_TOKENS (default 8000 tokens).
    safe_text = _fit_to_context(text)
    prompt = ANALYSIS_PROMPT.format(text=safe_text.replace('"', '\\"'))

    # Default: a direct OpenAI-compatible call to Groq keeps the request tiny
    # (just our prompt), satisfying the 8k context limit. Set REFLECT_SEMANTIC_CLI
    # to route through opencode run instead (for large-context models). Falls back
    # to the regex detector on any failure.
    model_id = model or os.environ.get("REFLECT_SEMANTIC_MODEL", "groq/openai/gpt-oss-20b")
    cli = os.environ.get("REFLECT_SEMANTIC_CLI")
    if cli:
        return _analyze_via_cli(cli, prompt, model_id, timeout)
    return _analyze_via_api(prompt, model_id, timeout)


def _analyze_via_cli(cli, prompt, model_id, timeout):
    """Run detection through an external CLI (e.g. `opencode run`)."""
    cmd = [cli, "run", "--pure"]
    if model_id:
        cmd.extend(["-m", model_id])
    cmd.append(prompt)
    try:
        result = subprocess.run(
            cmd,
            input=prompt,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        if result.returncode != 0:
            return None
        output = result.stdout.strip()
        if not output:
            return None
        try:
            response = json.loads(output)
            content = response["result"] if isinstance(response, dict) and "result" in response else response
        except json.JSONDecodeError:
            content = _extract_json_from_text(output)
            if content is None:
                return None
        return _validate_response(content)
    except subprocess.TimeoutExpired:
        print(f"Warning: agent CLI timed out after {timeout}s")
        return None
    except FileNotFoundError:
        print("Error: agent CLI not found. Set REFLECT_SEMANTIC_CLI or install it.")
        return None
    except Exception as e:
        print(f"Error in semantic analysis: {e}")
        return None


def _analyze_via_api(prompt, model_id, timeout):
    """Run detection via a direct OpenAI-compatible chat completion (Groq)."""
    import urllib.request
    import urllib.error

    base = os.environ.get("REFLECT_SEMANTIC_API_BASE", "https://api.groq.com/openai/v1")
    key = os.environ.get("REFLECT_SEMANTIC_API_KEY", os.environ.get("GROQ_API_KEY", ""))
    # OpenCode-style ids are "provider/model"; the API wants just the model slug.
    api_model = model_id.split("/", 1)[-1]
    url = base.rstrip("/") + "/chat/completions"
    body = {
        "model": api_model,
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 0,
    }
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
            "User-Agent": "opencode-reflect/1.0",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            out = json.loads(resp.read().decode("utf-8"))
        content = out["choices"][0]["message"]["content"]
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace") if e.fp else ""
        print(f"Error: Groq API HTTP {e.code}: {detail[:200]}")
        return None
    except Exception as e:
        print(f"Error in semantic analysis: {e}")
        return None

    inner = _extract_json_from_text(content)
    if inner is None:
        print("Warning: could not parse JSON from Groq response")
        return None
    return _validate_response(inner)


def _extract_json_from_text(text: str) -> Optional[Dict[str, Any]]:
    """Try to extract JSON from text that may have surrounding content."""
    start = text.find('{')
    if start == -1:
        return None

    depth = 0
    for i, char in enumerate(text[start:], start):
        if char == '{':
            depth += 1
        elif char == '}':
            depth -= 1
            if depth == 0:
                try:
                    return json.loads(text[start:i+1])
                except json.JSONDecodeError:
                    return None
    return None


def _validate_response(content: Any) -> Optional[Dict[str, Any]]:
    """Validate and normalize the response from the agent."""
    if not isinstance(content, dict):
        return None

    if "is_learning" not in content:
        return None

    # Normalize boolean
    is_learning = content.get("is_learning")
    if isinstance(is_learning, str):
        is_learning = is_learning.lower() in ("true", "yes", "1")
    else:
        is_learning = bool(is_learning)

    # Normalize type
    learning_type = content.get("type")
    if learning_type not in ("correction", "positive", "explicit", None):
        learning_type = None

    # Normalize confidence
    try:
        confidence = float(content.get("confidence", 0.0))
        confidence = max(0.0, min(1.0, confidence))
    except (TypeError, ValueError):
        confidence = 0.5 if is_learning else 0.0

    return {
        "is_learning": is_learning,
        "type": learning_type if is_learning else None,
        "confidence": confidence,
        "reasoning": str(content.get("reasoning", "")),
        "extracted_learning": content.get("extracted_learning") if is_learning else None,
    }


def analyze_messages(
    messages: List[str],
    timeout: int = DEFAULT_TIMEOUT,
    model: Optional[str] = None,
    min_confidence: float = 0.6
) -> List[Dict[str, Any]]:
    """
    Analyze multiple messages and return only valid learnings.

    Args:
        messages: List of user messages to analyze
        timeout: Timeout per message
        model: Optional model override
        min_confidence: Minimum confidence threshold (default 0.6)

    Returns:
        List of validated learnings above threshold
    """
    learnings = []

    for msg in messages:
        result = semantic_analyze(msg, timeout=timeout, model=model)

        if result is None:
            continue

        if not result.get("is_learning"):
            continue

        if result.get("confidence", 0) < min_confidence:
            continue

        learnings.append({
            "original_message": msg,
            **result
        })

    return learnings


# =============================================================================
# Multi-language examples for testing
# =============================================================================

TEST_MESSAGES = {
    "en": "No, use uv instead of pip!",
    "de": "Nein, benutze immer pytest statt unittest!",
    "es": "No, usa Python en vez de JavaScript",
    "fr": "Non, utilise toujours ruff pour le linting",
    "greeting": "Hello, how are you?",  # Should NOT be detected
    "question": "Can you help me with this?",  # Should NOT be detected
}


if __name__ == "__main__":
    # Test mode
    if len(sys.argv) > 1:
        test_text = " ".join(sys.argv[1:])
        print(f"Analyzing: {test_text!r}")
        result = semantic_analyze(test_text)
        if result:
            print(json.dumps(result, indent=2, ensure_ascii=False))
        else:
            print("Analysis failed or returned None")
    else:
        # Run multi-language tests
        print("Running multi-language detection tests...\n")
        for lang, msg in TEST_MESSAGES.items():
            print(f"[{lang}] {msg}")
            result = semantic_analyze(msg)
            if result:
                status = "✓ LEARNING" if result["is_learning"] else "✗ Not a learning"
                print(f"  {status} (confidence: {result['confidence']:.2f})")
                if result.get("extracted_learning"):
                    print(f"  → {result['extracted_learning']}")
            else:
                print("  ✗ Analysis failed")
            print()
