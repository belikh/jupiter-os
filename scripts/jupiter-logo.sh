#!/usr/bin/env bash
# jupiterOS branding: real Jupiter imagery rendered as terminal art via chafa.
# Static frame for motd/banners, or --animate to live-play a colorized NASA
# Voyager 1 rotation sequence right in the terminal.
#
# Usage: jupiter-logo.sh [--full|--compact|--plain] [--animate [--fps N] [--grayscale]]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSET_DIR="$SCRIPT_DIR/assets"

MODE="auto"
ANIMATE=0
FPS=""
GRAYSCALE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --full|--compact|--plain) MODE="${1#--}" ;;
        --animate) ANIMATE=1 ;;
        --fps) shift; FPS="${1:-}" ;;
        --grayscale) GRAYSCALE=1 ;;
        *) echo "usage: $(basename "$0") [--full|--compact|--plain] [--animate [--fps N] [--grayscale]]" >&2; exit 1 ;;
    esac
    shift
done

supports_color() {
    [[ "${TERM:-}" == *256color* ]] && return 0
    [[ "$(tput colors 2>/dev/null || echo 0)" -ge 256 ]]
}

run_chafa() {
    if command -v chafa >/dev/null 2>&1; then
        chafa "$@"
    else
        nix run nixpkgs#chafa -- "$@"
    fi
}

print_plain() {
    cat <<'EOF'
                    .:cxddxc:.
                .:oxOKXNNXKOxo:.
              ;dOXWMMMMMMMMMWXOd;
            :OWMMMMMMMMMMMMMMMMWO:
           lWMMMMMMMMMMMMMMMMMMMWl
          cWMMMMMMMMMMMMMMMMMMMMWc
          NMMMMMMMMMMMMMMMMMMMMMMN
          WMM===(GREAT RED SPOT)==W
          NMMMMMMMMMMMMMMMMMMMMMMN
          cWMMMMMMMMMMMMMMMMMMMMWc
           lWMMMMMMMMMMMMMMMMMMMWl
            :OWMMMMMMMMMMMMMMMMWO:
              ;dOXWMMMMMMMMMWXOd;
                .:oxOKXNNXKOxo:.
                    .:cxddxc:.

    j u p i t e r OS
EOF
}

if [[ "$MODE" == "auto" ]]; then
    if supports_color; then
        cols="$(tput cols 2>/dev/null || echo 80)"
        if (( cols >= 100 )); then MODE="full"; else MODE="compact"; fi
    else
        MODE="plain"
    fi
fi

if (( ANIMATE )); then
    if [[ "$MODE" == "plain" ]]; then
        echo "jupiter-logo.sh: --animate needs a color-capable terminal" >&2
        exit 1
    fi
    gif="$ASSET_DIR/jupiter-voyager.gif"
    (( GRAYSCALE )) && gif="$ASSET_DIR/jupiter-voyager-grayscale.gif"
    size="70x35"
    [[ "$MODE" == "compact" ]] && size="50x25"
    args=(--format symbols --size "$size" --symbols block --colors full \
          --color-space rgb --dither none)
    [[ -n "$FPS" ]] && args+=(--speed "${FPS}fps")
    run_chafa "${args[@]}" "$gif"
    exit 0
fi

case "$MODE" in
    full)    cat "$ASSET_DIR/jupiter-logo-full.ans" ;;
    compact) cat "$ASSET_DIR/jupiter-logo-compact.ans" ;;
    plain)   print_plain ;;
esac
