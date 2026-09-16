#!/usr/bin/env bash
# Configure the GitHub Actions secrets and variables the Niro Find workflow
# needs, for the agent CLI you select. Run once per repository from a machine
# where `gh` is authenticated with admin access to it.
#
# Secret values are never echoed and never placed on a command line:
#   * interactive mode lets `gh` prompt and read from the terminal;
#   * --from-env pipes values from the environment into `gh secret set` stdin.
#
# Usage:
#   scripts/niro-setup.sh copilot               # interactive prompts
#   scripts/niro-setup.sh copilot --from-env    # COPILOT_PROVIDER_* from env
#   scripts/niro-setup.sh claude [--from-env]
#   scripts/niro-setup.sh codex [--from-env]
#   scripts/niro-setup.sh environment --reviewers <login>[,<login>...]
#   scripts/niro-setup.sh status                # list configured names only
#
# Copilot BYOK is all four values together or none. A partial set is treated as
# native OAuth by Niro and can fail mid-run or bill the wrong account, so the
# workflow refuses to start without all four (Guard steps) — if that guard
# fires, run `scripts/niro-setup.sh copilot` again.
#
#   secret COPILOT_PROVIDER_API_KEY    the provider key (for example an
#                                      OpenRouter key)
#   var    COPILOT_PROVIDER_BASE_URL   OpenAI-compatible base URL, for example
#                                      https://openrouter.ai/api/v1
#   var    COPILOT_PROVIDER_TYPE       openai | azure | anthropic
#   var    COPILOT_MODEL               a tool-capable model id (128k+ context
#                                      recommended)
#
# Claude Code: set ONE of CLAUDE_CODE_OAUTH_TOKEN (`claude setup-token`) or
# ANTHROPIC_API_KEY.
# Codex: set ONE of OPENAI_API_KEY or CODEX_AUTH_JSON_B64
#        (`base64 < ~/.codex/auth.json | tr -d '\n'`).
set -euo pipefail

die() { printf 'niro-setup: ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf 'niro-setup: %s\n' "$*" >&2; }

usage() {
  sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'
}

[ $# -ge 1 ] || { usage; exit 2; }

COMMAND="$1"
shift

FROM_ENV=0
REVIEWERS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --from-env) FROM_ENV=1 ;;
    --reviewers)
      shift
      REVIEWERS="${1:-}"
      ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

command -v gh >/dev/null 2>&1 || die "gh CLI not found"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated (run: gh auth login)"

set_secret() {
  local name="$1"
  if [ "$FROM_ENV" = 1 ]; then
    local value="${!name:-}"
    [ -n "$value" ] || die "$name is empty in the environment"
    printf '%s' "$value" | gh secret set "$name"
    log "secret $name set"
  else
    log "setting secret $name (gh prompts; input is not echoed)"
    gh secret set "$name"
  fi
}

set_variable() {
  local name="$1"
  if [ "$FROM_ENV" = 1 ]; then
    local value="${!name:-}"
    [ -n "$value" ] || die "$name is empty in the environment"
    printf '%s' "$value" | gh variable set "$name"
    log "variable $name set"
  else
    log "setting variable $name (gh prompts)"
    gh variable set "$name"
  fi
}

case "$COMMAND" in
  copilot)
    [ "$FROM_ENV" = 1 ] || log "Copilot BYOK: all four values together, or none"
    set_secret COPILOT_PROVIDER_API_KEY
    set_variable COPILOT_PROVIDER_BASE_URL
    set_variable COPILOT_PROVIDER_TYPE
    set_variable COPILOT_MODEL
    ;;
  claude)
    if [ "$FROM_ENV" = 1 ]; then
      set_any=0
      if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then set_secret CLAUDE_CODE_OAUTH_TOKEN; set_any=1; fi
      if [ -n "${ANTHROPIC_API_KEY:-}" ]; then set_secret ANTHROPIC_API_KEY; set_any=1; fi
      [ "$set_any" = 1 ] || die "set CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY in the environment"
    else
      printf 'Set which Claude credential? [1] CLAUDE_CODE_OAUTH_TOKEN (subscription) [2] ANTHROPIC_API_KEY (API billing): ' >&2
      read -r answer
      case "$answer" in
        1) gh secret set CLAUDE_CODE_OAUTH_TOKEN ;;
        2) gh secret set ANTHROPIC_API_KEY ;;
        *) die "expected 1 or 2" ;;
      esac
    fi
    ;;
  codex)
    if [ "$FROM_ENV" = 1 ]; then
      set_any=0
      if [ -n "${OPENAI_API_KEY:-}" ]; then set_secret OPENAI_API_KEY; set_any=1; fi
      if [ -n "${CODEX_AUTH_JSON_B64:-}" ]; then set_secret CODEX_AUTH_JSON_B64; set_any=1; fi
      [ "$set_any" = 1 ] || die "set OPENAI_API_KEY or CODEX_AUTH_JSON_B64 in the environment"
    else
      printf 'Set which Codex credential? [1] OPENAI_API_KEY [2] CODEX_AUTH_JSON_B64 (base64 of ~/.codex/auth.json): ' >&2
      read -r answer
      case "$answer" in
        1) gh secret set OPENAI_API_KEY ;;
        2) gh secret set CODEX_AUTH_JSON_B64 ;;
        *) die "expected 1 or 2" ;;
      esac
    fi
    ;;
  environment)
    [ -n "$REVIEWERS" ] || die "environment needs --reviewers <login>[,<login>...]"
    reviewers_json="["
    first=1
    IFS=',' read -r -a logins <<<"$REVIEWERS"
    for login in "${logins[@]}"; do
      login="$(printf '%s' "$login" | tr -d '[:space:]')"
      [ -n "$login" ] || continue
      id="$(gh api "users/$login" --jq .id)" || die "cannot resolve GitHub user: $login"
      if [ "$first" = 1 ]; then first=0; else reviewers_json="$reviewers_json,"; fi
      reviewers_json="$reviewers_json{\"type\":\"User\",\"id\":$id}"
    done
    reviewers_json="$reviewers_json]"
    [ "$first" = 0 ] || die "no reviewer logins parsed"
    printf '{"reviewers":%s,"deployment_branch_policy":null}' "$reviewers_json" |
      gh api --method PUT "repos/{owner}/{repo}/environments/niro-autonomous" --input -
    log "niro-autonomous environment updated: every dispatch now needs a reviewer approval"
    ;;
  status)
    log "secrets (names only — values are not retrievable):"
    gh secret list
    log "variables (these are not secret):"
    gh variable list
    ;;
  -h | --help | help)
    usage
    ;;
  *)
    die "unknown command: $COMMAND (try: copilot, claude, codex, environment, status)"
    ;;
esac

log "done"
