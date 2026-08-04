#!/bin/bash
#
# install.sh - install ai-aligned-xcode and its tool shims
#
# Copies the shim to ~/.local/bin and symlinks it as xcodebuild, xcrun, swift
# and xcodegen. The shims only take effect if ~/.local/bin precedes the real
# tools on PATH, so this verifies the ordering rather than assuming it.
#
# Supports both local installation and curl | sh:
#   curl -fsSL https://raw.githubusercontent.com/ai-ecoverse/ai-aligned-xcode/main/install.sh | sh

set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
RAW_BASE_URL="https://raw.githubusercontent.com/ai-ecoverse/ai-aligned-xcode/main"
SOURCE_SCRIPT="executable_ai-aligned-xcode"
SHIMS=(xcodebuild xcrun swift xcodegen)

# BASH_SOURCE is unset when piped from curl, so fall back to the cwd and let
# the download path below handle a missing local copy.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)"
SOURCE="$SCRIPT_DIR/$SOURCE_SCRIPT"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s!%s %s\n' "$YELLOW" "$NC" "$*"; }
die()  { printf '%s✗%s %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "ai-aligned-xcode is macOS-only (found $(uname -s))"

say "Installing ai-aligned-xcode to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

if [ -r "$SOURCE" ]; then
    install -m 0755 "$SOURCE" "$INSTALL_DIR/ai-aligned-xcode"
    ok "installed ai-aligned-xcode from $SOURCE"
else
    # Piped from curl, or run outside a checkout: fetch the shim.
    say "No local copy found; downloading from $RAW_BASE_URL"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$RAW_BASE_URL/$SOURCE_SCRIPT" -o "$INSTALL_DIR/ai-aligned-xcode"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$INSTALL_DIR/ai-aligned-xcode" "$RAW_BASE_URL/$SOURCE_SCRIPT"
    else
        die "neither curl nor wget is available"
    fi
    chmod 0755 "$INSTALL_DIR/ai-aligned-xcode"
    ok "downloaded and installed ai-aligned-xcode"
fi

for tool in "${SHIMS[@]}"; do
    target="$INSTALL_DIR/$tool"
    if [ -e "$target" ] && [ ! -L "$target" ]; then
        warn "$target exists and is not a symlink; leaving it alone"
        continue
    fi
    ln -sf ai-aligned-xcode "$target"
    ok "shimmed $tool"
done

# --- verify the shims actually win on PATH -----------------------------------

say ""
say "Checking PATH precedence:"
problems=0
for tool in "${SHIMS[@]}"; do
    resolved="$(command -v "$tool" 2>/dev/null || true)"
    case "$resolved" in
        "$INSTALL_DIR/$tool") ok "$tool -> $resolved" ;;
        "")                   warn "$tool not found on PATH (is it installed?)" ;;
        *)                    warn "$tool resolves to $resolved, NOT the shim"; problems=1 ;;
    esac
done

if [ "$problems" -ne 0 ] || ! printf '%s' ":$PATH:" | grep -q ":$INSTALL_DIR:"; then
    say ""
    warn "$INSTALL_DIR must come BEFORE /usr/bin on PATH."
    say "  Add this to your shell config, then restart your shell:"
    say ""
    case "$(basename "${SHELL:-bash}")" in
        fish)   say "    fish_add_path --prepend $INSTALL_DIR" ;;
        elvish) say "    set paths = [$INSTALL_DIR \$@paths]" ;;
        *)      say "    export PATH=\"$INSTALL_DIR:\$PATH\"" ;;
    esac
    say ""
    say "  Agents that spawn non-login shells may need it in ~/.zshenv rather"
    say "  than ~/.zshrc, since ~/.zshrc is skipped for non-interactive shells."
fi

say ""
"$INSTALL_DIR/ai-aligned-xcode" doctor
say ""
say "Humans get an untouched pass-through; only detected agents are managed."
say "Disable at any time with AI_ALIGNED_XCODE_DISABLE=true."
