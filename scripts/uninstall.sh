#!/usr/bin/env bash

set -euo pipefail

CODEX_DIR=${CODEX_HOME:-"$HOME/.codex"}
case "$CODEX_DIR" in
  /*) ;;
  *) CODEX_DIR="$PWD/$CODEX_DIR" ;;
esac
if [[ -d "$CODEX_DIR" ]]; then
  CODEX_DIR=$(CDPATH= cd -- "$CODEX_DIR" && pwd -P)
fi
export CODEX_HOME="$CODEX_DIR"

usage() {
  printf '%s\n' \
    'Usage: ./scripts/uninstall.sh' \
    '' \
    'Moves profiles and the Planner Herdr MCP bridge installed by herdr-codex-team into a dated backup.' \
    'It does not remove Codex, Herdr, or the Herdr Codex integration.'
}

if [[ ${1:-} == "--help" || ${1:-} == "-h" ]]; then
  usage
  exit 0
fi

if [[ $# -ne 0 ]]; then
  usage >&2
  exit 2
fi

timestamp=$(date '+%Y%m%d-%H%M%S')
backup_dir="$CODEX_DIR/herdr-codex-team-uninstall-backup-$timestamp"
if [[ -e "$backup_dir" ]]; then
  backup_dir="$backup_dir-$$"
fi

moved=0
skipped=0
for role in planner coder reviewer; do
  profile="$CODEX_DIR/$role.config.toml"
  [[ -e "$profile" ]] || continue

  first_line=$(sed -n '1p' "$profile")
  if [[ "$first_line" != '# Installed by herdr-codex-team. Edit the source template and rerun install.sh.' ]]; then
    printf '[WARN] Leaving non-managed profile untouched: %s\n' "$profile"
    skipped=$((skipped + 1))
    continue
  fi

  if [[ $moved -eq 0 ]]; then
    mkdir -p -- "$backup_dir"
    chmod 700 "$backup_dir" 2>/dev/null || true
  fi
  mv -- "$profile" "$backup_dir/$role.config.toml"
  moved=$((moved + 1))
  printf '[OK] Moved %s.config.toml to the uninstall backup.\n' "$role"
done

bridge="$CODEX_DIR/herdr-codex-team/herdr_mcp.py"
if [[ -e "$bridge" || -L "$bridge" ]]; then
  bridge_marker='# Managed by herdr-codex-team. Edit this source file and rerun scripts/install.sh.'
  if [[ -f "$bridge" && ! -L "$bridge" ]] && grep -Fxq "$bridge_marker" "$bridge"; then
    if [[ $moved -eq 0 ]]; then
      mkdir -p -- "$backup_dir"
      chmod 700 "$backup_dir" 2>/dev/null || true
    fi
    mkdir -p -- "$backup_dir/herdr-codex-team"
    chmod 700 "$backup_dir/herdr-codex-team" 2>/dev/null || true
    if [[ -f "$HOME/.gemini/config/mcp_config.json" ]]; then
      script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
      python3 "$script_dir/providers.py" unconfigure-agy "$bridge" || {
        printf '[FAIL] Could not remove the managed Antigravity MCP entries. Retained the installed bridge.\n' >&2
        exit 1
      }
    fi
    mv -- "$bridge" "$backup_dir/herdr-codex-team/herdr_mcp.py"
    moved=$((moved + 1))
    printf '[OK] Moved the managed Planner Herdr MCP bridge to the uninstall backup.\n'
  else
    printf '[WARN] Leaving non-managed or unsafe bridge path untouched: %s\n' "$bridge"
    skipped=$((skipped + 1))
  fi
fi

if [[ $moved -gt 0 ]]; then
  printf '\nUninstall complete. Managed files remain recoverable at:\n  %s\n' "$backup_dir"
else
  printf 'No managed team files were found. Nothing was removed.\n'
fi

if [[ $skipped -gt 0 ]]; then
  printf '%s path(s) were intentionally left untouched because they lacked the installer marker or were unsafe.\n' "$skipped"
fi
