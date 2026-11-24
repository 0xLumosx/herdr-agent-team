#!/usr/bin/env bash

set -euo pipefail

SOURCE_PATH=${BASH_SOURCE[0]-}
if [[ -n "${HERDR_CODEX_TEAM_ROOT:-}" ]]; then
  [[ "$HERDR_CODEX_TEAM_ROOT" == /* && "$HERDR_CODEX_TEAM_ROOT" != '/' ]] || {
    printf '[FAIL] HERDR_CODEX_TEAM_ROOT must be an absolute path other than /.\n' >&2
    exit 2
  }
  SCRIPT_DIR="$HERDR_CODEX_TEAM_ROOT/scripts"
elif [[ -n "$SOURCE_PATH" && -f "$SOURCE_PATH" ]]; then
  SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$SOURCE_PATH")" && pwd)
else
  printf '[FAIL] Could not resolve the open.sh helper directory.\n' >&2
  exit 1
fi
TEAM_LIB="$SCRIPT_DIR/lib/team.sh"
JSON_LIB="$SCRIPT_DIR/lib/json.sh"
SCOPE_LIB="$SCRIPT_DIR/lib/scope.sh"
[[ -f "$TEAM_LIB" && -f "$JSON_LIB" && -f "$SCOPE_LIB" && -x "$SCRIPT_DIR/start.sh" && \
   -x "$SCRIPT_DIR/doctor.sh" && -x "$SCRIPT_DIR/install.sh" ]] || {
  printf '[FAIL] Missing script helper under %s/lib.\n' "$SCRIPT_DIR" >&2
  exit 1
}
# shellcheck source=lib/team.sh
source "$TEAM_LIB"
# shellcheck source=lib/json.sh
source "$JSON_LIB"
# shellcheck source=lib/scope.sh
source "$SCOPE_LIB"

TEAM_CLI_SET=0
TEAM_CLI_PREFIX=''
CWD_ARG_SET=0
PROJECT_DIR=''
NO_FOCUS=0
REPAIR_PROFILES=0
INSTALL_INTEGRATION=0
ADD_DIRS=()
LINK_IDS=()

usage() {
  printf '%s\n' \
    'Usage: ./scripts/open.sh [--planner-cli CLI] [--coder-cli CLI] [--reviewer-cli CLI] [--no-focus] [--repair-profiles] [--install-integration] [--team PREFIX] --cwd PROJECT_DIR [--add-dir DIR]...' \
    '' \
    'Opens one managed three-agent team in the current Herdr session.' \
    'If all three exact agents are healthy, the current compatible live Team is left running.' \
    'If none exist, a new team is created through start.sh.' \
    '--link-current PLANNER_UUID CODER_UUID REVIEWER_UUID registers the three explicitly selected live chats after verification.' \
    '--repair-profiles explicitly backs up and refreshes managed profiles plus the Planner bridge, but only when no Agent is live in this Herdr session.' \
    '--install-integration explicitly permits Herdr to install/update hooks for the selected CLIs.' \
    'A partial or unhealthy team is never overwritten or silently replaced.'
}

die() {
  local status=$1
  shift
  printf '[FAIL] %s\n' "$*" >&2
  exit "$status"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --planner-cli|--coder-cli|--reviewer-cli)
      [[ $# -ge 2 && -n "$2" ]] || { printf '%s requires a CLI name\n' "$1" >&2; exit 2; }
      team_set_role_cli "$1" "$2" || exit 2
      shift 2 ;;
    --link-current)
      [[ $# -ge 4 && ${#LINK_IDS[@]} -eq 0 ]] || die 2 '--link-current requires exactly three role UUIDs.'
      LINK_IDS=("$2" "$3" "$4")
      shift 4
      ;;
    --no-focus)
      NO_FOCUS=1
      shift
      ;;
    --repair-profiles)
      [[ $REPAIR_PROFILES -eq 0 ]] || die 2 '--repair-profiles may be provided only once.'
      REPAIR_PROFILES=1
      shift
      ;;
    --install-integration)
      [[ $INSTALL_INTEGRATION -eq 0 ]] || die 2 '--install-integration may be provided only once.'
      INSTALL_INTEGRATION=1
      shift
      ;;
    --team)
      [[ $# -ge 2 ]] || die 2 '--team requires a prefix.'
      [[ $TEAM_CLI_SET -eq 0 ]] || die 2 '--team may be provided only once.'
      TEAM_CLI_SET=1
      TEAM_CLI_PREFIX=$2
      shift 2
      ;;
    --team=*)
      [[ $TEAM_CLI_SET -eq 0 ]] || die 2 '--team may be provided only once.'
      TEAM_CLI_SET=1
      TEAM_CLI_PREFIX=${1#--team=}
      shift
      ;;
    --cwd)
      [[ $# -ge 2 ]] || die 2 '--cwd requires a project directory.'
      [[ $CWD_ARG_SET -eq 0 ]] || die 2 '--cwd may be provided only once.'
      CWD_ARG_SET=1
      PROJECT_DIR=$2
      shift 2
      ;;
    --cwd=*)
      [[ $CWD_ARG_SET -eq 0 ]] || die 2 '--cwd may be provided only once.'
      CWD_ARG_SET=1
      PROJECT_DIR=${1#--cwd=}
      shift
      ;;
    --add-dir)
      [[ $# -ge 2 ]] || die 2 '--add-dir requires a directory.'
      ADD_DIRS+=("$2")
      shift 2
      ;;
    --add-dir=*)
      ADD_DIRS+=("${1#--add-dir=}")
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die 2 "Unknown argument: $1"
      ;;
  esac
done

[[ $CWD_ARG_SET -eq 1 && -n "$PROJECT_DIR" ]] || die 2 '--cwd is required.'
if ! REQUESTED_TEAM_PREFIX=$(team_resolve_requested_prefix "$TEAM_CLI_SET" "$TEAM_CLI_PREFIX"); then
  die 2 'Could not resolve a single non-empty team prefix.'
fi
if ! team_configure "$REQUESTED_TEAM_PREFIX"; then
  die 2 "Invalid team prefix '$REQUESTED_TEAM_PREFIX'. It must match [a-z][a-z0-9_-]* and be at most 23 characters."
fi

scope_path_has_control "$PROJECT_DIR" && \
  die 2 'Project directory argument contains an unsupported control character.'
PROJECT_DIR=$(scope_physical_dir "$PROJECT_DIR") || \
  die 2 'Project directory does not exist or cannot be resolved safely.'
[[ "$PROJECT_DIR" != '/' ]] || die 2 'Refusing to open a managed team at the filesystem root.'
NORMALIZED_ADD_DIRS=()
for add_dir in ${ADD_DIRS[@]+"${ADD_DIRS[@]}"}; do
  scope_path_has_control "$add_dir" && \
    die 2 'An additional directory argument contains an unsupported control character.'
  normalized_add_dir=$(scope_physical_dir "$add_dir") || \
    die 2 'An additional directory does not exist or cannot be resolved safely.'
  [[ "$normalized_add_dir" != '/' ]] || \
    die 2 'Refusing to grant the filesystem root as an additional directory.'
  NORMALIZED_ADD_DIRS+=("$normalized_add_dir")
done
ADD_DIRS=()
for normalized_add_dir in ${NORMALIZED_ADD_DIRS[@]+"${NORMALIZED_ADD_DIRS[@]}"}; do
  ADD_DIRS+=("$normalized_add_dir")
done

command -v herdr >/dev/null 2>&1 || die 12 'Herdr was not found in PATH.'
JSON_BACKEND=$(json_backend_name) || \
  die 2 'A real JSON parser is required: install jq or make python3 available.'
if ! server_status=$(herdr status server 2>&1); then
  printf '%s\n' "$server_status" >&2
  die 15 'Herdr server is not reachable in the selected session.'
fi
if ! agent_list_payload=$(herdr agent list 2>&1); then
  printf '%s\n' "$agent_list_payload" >&2
  die 1 'Could not inspect the current Herdr agent list.'
fi
if ! live_agent_names=$(json_agent_names "$agent_list_payload"); then
  die 1 "Could not parse the Herdr agent list with $JSON_BACKEND."
fi

live_count=0
for role in planner coder reviewer; do
  live_name=$(team_agent_for_role "$role")
  if printf '%s\n' "$live_agent_names" | grep -Fxq -- "$live_name"; then
    live_count=$((live_count + 1))
  fi
done

COMMON_ARGS=()
if [[ "$TEAM_MODE" == prefixed ]]; then
  COMMON_ARGS+=(--team "$TEAM_DISPLAY")
fi
COMMON_ARGS+=(--cwd "$PROJECT_DIR")
for add_dir in ${ADD_DIRS[@]+"${ADD_DIRS[@]}"}; do
  COMMON_ARGS+=(--add-dir "$add_dir")
done

if [[ $REPAIR_PROFILES -eq 1 && -n "$live_agent_names" ]]; then
  printf 'TEAM_UNSAFE: --repair-profiles requires no live Agent in the selected Herdr session.\n' >&2
  printf 'No shared profile or Agent was modified. Inspect or stop the intended session explicitly before repair.\n' >&2
  exit 4
fi
if [[ $INSTALL_INTEGRATION -eq 1 && -n "$live_agent_names" ]]; then
  printf 'TEAM_UNSAFE: --install-integration requires no live Agent in the selected Herdr session.\n' >&2
  printf 'No hook, Codex configuration, profile, or Agent was modified. Stop and inspect the intended session before retrying.\n' >&2
  exit 4
fi

case "$live_count" in
  0)
    [[ ${#LINK_IDS[@]} -eq 0 ]] || die 3 '--link-current requires a running managed team.'
    integration_status=$(herdr integration status 2>&1 || true)
    integrations=$(team_integrations) || exit 2
    while IFS= read -r integration; do
      if ! grep -Eq "^$integration: current([[:space:]]|$)" <<<"$integration_status"; then
        [[ $INSTALL_INTEGRATION -eq 1 ]] || die 17 "INTEGRATION_REQUIRED: $integration. Retry with --install-integration."
        herdr integration install "$integration" || die 4 "Could not install $integration integration."
        integration_status=$(herdr integration status)
        grep -Eq "^$integration: current([[:space:]]|$)" <<<"$integration_status" || die 4 "$integration integration is still unavailable."
      fi
    done <<<"$integrations"
    profile_count=0
    for role in planner coder reviewer; do
      profile_path=${CODEX_HOME:-"$HOME/.codex"}/$role.config.toml
      if [[ -e "$profile_path" || -L "$profile_path" ]]; then
        profile_count=$((profile_count + 1))
      fi
    done
    bridge_count=0
    bridge_path=${CODEX_HOME:-"$HOME/.codex"}/herdr-codex-team/herdr_mcp.py
    if [[ -e "$bridge_path" || -L "$bridge_path" ]]; then
      bridge_count=1
    fi
    managed_file_count=$((profile_count + bridge_count))
    if [[ $REPAIR_PROFILES -eq 1 ]]; then
      printf 'Explicit profile repair requested; install.sh will back up existing managed profile and bridge paths.\n'
      "$SCRIPT_DIR/install.sh"
    elif [[ $managed_file_count -eq 0 ]]; then
      printf 'No managed Codex team files exist yet; installing the three profiles and Planner bridge once.\n'
      "$SCRIPT_DIR/install.sh"
    elif [[ $managed_file_count -ne 4 ]]; then
      printf 'TEAM_UNSAFE: found %s of 3 managed Codex profile paths and %s of 1 Planner bridge paths.\n' "$profile_count" "$bridge_count" >&2
      printf 'No managed file or Agent was overwritten. After reviewing the Codex home, rerun with --repair-profiles to make a backed-up replacement.\n' >&2
      exit 4
    fi
    START_ARGS=()
    [[ $NO_FOCUS -eq 0 ]] || START_ARGS+=(--no-focus)
    START_ARGS+=("${COMMON_ARGS[@]}")
    "$SCRIPT_DIR/start.sh" "${START_ARGS[@]}"
    printf '\nTEAM_CREATED: %s\n' "$TEAM_DISPLAY"
    ;;
  3)
    if ! "$SCRIPT_DIR/doctor.sh" --bind-record-if-present "${COMMON_ARGS[@]}"; then
      printf '\nTEAM_UNSAFE: all three names exist, but the managed-team check failed.\n' >&2
      printf 'No agent was stopped, replaced, or restarted.\n' >&2
      exit 4
    fi
    if [[ ${#LINK_IDS[@]} -gt 0 ]]; then
      source "$SCRIPT_DIR/lib/run-state.sh"
      codex_dir=$(cd -- "${CODEX_HOME:-$HOME/.codex}" && pwd -P)
      run_state_configure "$codex_dir" "$TEAM_MODE" "$TEAM_PREFIX_EFFECTIVE" || die 4 'Cannot locate the team launch record.'
      [[ -f "$RUN_STATE_FILE" && ! -L "$RUN_STATE_FILE" ]] || die 4 'Missing team launch record.'
      idx=0
      for role in planner coder reviewer; do
        live_name=$(team_agent_for_role "$role")
        agent_payload=$(herdr agent get "$live_name") || die 4 "Cannot inspect $live_name."
        active=$(HERDR_BIN_PATH="$(command -v herdr)" python3 "$SCRIPT_DIR/herdr_mcp.py" --thread-id <<<"$agent_payload") || die 4 "Cannot verify $live_name."
        [[ "$active" == "${LINK_IDS[$idx]}" ]] || die 4 "The selected $role conversation differs from the supplied UUID."
        idx=$((idx + 1))
      done
      python3 "$SCRIPT_DIR/herdr_mcp.py" --bind-launch "$RUN_STATE_FILE" "${LINK_IDS[@]}" || die 4 'Conversation registration failed.'
      printf 'CONVERSATIONS_LINKED: %s\n' "${LINK_IDS[0]}"
    fi
    if [[ $NO_FOCUS -eq 0 ]]; then
      herdr agent focus "$PLANNER_AGENT" >/dev/null
    fi
    if [[ -z "${RUN_STATE_FILE:-}" ]]; then
      source "$SCRIPT_DIR/lib/run-state.sh"
      local_home=${CODEX_HOME:-$HOME/.codex}
      if [[ -d "$local_home" ]]; then
        run_state_configure "$(cd -- "$local_home" && pwd -P)" "$TEAM_MODE" "$TEAM_PREFIX_EFFECTIVE"
      fi
    fi
    if [[ -f "${RUN_STATE_FILE:-}" ]]; then
      CODEX_HOME="${RUN_STATE_CODEX_DIR}" HERDR_BIN_PATH="$(command -v herdr)" python3 "$SCRIPT_DIR/herdr_mcp.py" --ensure-observer "$RUN_STATE_FILE"
    fi
    printf '\nTEAM_REUSED: %s (current compatible live Team verified; open.sh restarted nothing)\n' "$TEAM_DISPLAY"
    ;;
  *)
    printf 'TEAM_PARTIAL: found %s of 3 expected agents for team %s.\n' \
      "$live_count" "$TEAM_DISPLAY" >&2
    printf 'No agent was stopped, replaced, or created. Inspect the named Herdr session before retrying.\n' >&2
    exit 3
    ;;
esac
