#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$SCRIPT_DIR/lib/team.sh"
source "$SCRIPT_DIR/lib/json.sh"
source "$SCRIPT_DIR/lib/digest.sh"
kind=$1
case "$kind" in codex|claude|agy) ;; *) exit 2 ;; esac
role=${HERDR_TEAM_ROLE:?Run this command from a Herdr role pane}
RUN_STATE_FILE=${HERDR_TEAM_STATE_FILE:?}
RUN_ID=${HERDR_TEAM_RUN_ID:?}
PYTHON_BIN=$(managed_python_executable)
HERDR_BIN=$(managed_command_executable herdr "$PYTHON_BIN")
export HERDR_BIN_PATH="$HERDR_BIN"
BRIDGE_TARGET="$CODEX_HOME/herdr-codex-team/herdr_mcp.py"
command -v "$kind" >/dev/null || { echo "找不到 $kind" >&2; exit 1; }
integration=$kind
[[ $kind != agy ]] || integration=antigravity-cli
herdr integration status | grep -E "^$integration: current([[:space:]]|$)" >/dev/null || {
  echo "请先运行 herdr integration install $integration" >&2; exit 1;
}
context=$("$PYTHON_BIN" -B "$SCRIPT_DIR/switch_role.py" context "$kind")
ADD_DIRS=()
{ IFS= read -r group; IFS= read -r project; while IFS= read -r path; do ADD_DIRS+=("$path"); done; } <<<"$context"
cd -- "$project"
if [[ $kind == agy ]]; then
  "$PYTHON_BIN" "$SCRIPT_DIR/providers.py" configure-agy "$BRIDGE_TARGET" "$HERDR_BIN"
fi
team_role_args "$role" "$kind" ""
"$PYTHON_BIN" -B "$SCRIPT_DIR/switch_role.py" launch "$kind" "$group" "$$" "${TEAM_ROLE_ARGS[@]}"
