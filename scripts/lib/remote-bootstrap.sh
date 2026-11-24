#!/usr/bin/env bash

# Runs inside the current launcher bundle on the SSH host. It selects one
# named Herdr session, verifies the binary and running-server identities, uses
# Herdr's own remote bridge to create a supported detached daemon when absent,
# and then performs the create-or-reuse decision.

set -euo pipefail


TEAM=''
PROJECT_DIR=''
EXPECTED_HERDR_VERSION=''
EXPECTED_BUNDLE_DIGEST=''
REPAIR_PROFILES=0
INSTALL_INTEGRATION=0
ADD_DIRS=()

die() {
  local status=$1
  shift
  printf '[FAIL] %s\n' "$*" >&2
  exit "$status"
}

TEAM_ROOT=${HERDR_CODEX_TEAM_ROOT:-}
[[ -f "$TEAM_ROOT/scripts/lib/team.sh" ]] || die 14 "Incomplete launcher: $TEAM_ROOT"
source "$TEAM_ROOT/scripts/lib/team.sh"

parse_herdr_version() {
  local output=$1
  local product
  local version
  local extra

  read -r product version extra <<<"$output"
  [[ "$product" == herdr && -n "$version" && -z "${extra:-}" ]] || return 1
  [[ "$version" =~ ^[0-9][A-Za-z0-9.+_-]*$ ]] || return 1
  printf '%s\n' "$version"
}

server_json_running() {
  [[ "$1" == *'"running":true'* ]]
}

verify_running_server() {
  local payload=$1

  server_json_running "$payload" || return 1
  [[ "$payload" == *'"version":"'"$EXPECTED_HERDR_VERSION"'"'* ]] || return 1
  [[ "$payload" == *'"compatible":true'* ]] || return 1
  [[ "$payload" == *'"detached_server_daemon":true'* ]] || return 1
  [[ "$payload" == *'"session":"'"$TEAM"'"'* ]] || return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --planner-cli|--coder-cli|--reviewer-cli)
      [[ $# -ge 2 && -n "$2" ]] || { printf '%s requires a CLI name\n' "$1" >&2; exit 2; }
      team_set_role_cli "$1" "$2" || exit 2
      shift 2 ;;
    --team)
      [[ $# -ge 2 && -z "$TEAM" ]] || die 2 '--team requires one value.'
      TEAM=$2
      shift 2
      ;;
    --cwd)
      [[ $# -ge 2 && -z "$PROJECT_DIR" ]] || die 2 '--cwd requires one value.'
      PROJECT_DIR=$2
      shift 2
      ;;
    --herdr-version)
      [[ $# -ge 2 && -z "$EXPECTED_HERDR_VERSION" ]] || \
        die 2 '--herdr-version requires one value.'
      EXPECTED_HERDR_VERSION=$2
      shift 2
      ;;
    --bundle-digest)
      [[ $# -ge 2 && -z "$EXPECTED_BUNDLE_DIGEST" ]] || \
        die 2 '--bundle-digest requires one value.'
      EXPECTED_BUNDLE_DIGEST=$2
      shift 2
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
    --add-dir)
      [[ $# -ge 2 ]] || die 2 '--add-dir requires a value.'
      ADD_DIRS+=("$2")
      shift 2
      ;;
    *) die 2 "Unknown remote bootstrap argument: $1" ;;
  esac
done

[[ "$TEAM" =~ ^[a-z][a-z0-9_-]{0,22}$ ]] || die 2 'Invalid remote Team prefix.'
[[ "$EXPECTED_HERDR_VERSION" =~ ^[0-9][A-Za-z0-9.+_-]*$ ]] || \
  die 2 'Invalid expected Herdr version.'
[[ "$EXPECTED_BUNDLE_DIGEST" =~ ^[0-9a-f]{64}$ ]] || \
  die 2 'Invalid expected launcher bundle digest.'
[[ "$PROJECT_DIR" == /* && "$PROJECT_DIR" != '/' ]] || \
  die 2 'Remote --cwd must be an absolute path other than /.'
for add_dir in ${ADD_DIRS[@]+"${ADD_DIRS[@]}"}; do
  [[ "$add_dir" == /* && "$add_dir" != '/' ]] || \
    die 2 'Each remote --add-dir must be an absolute path other than /.'
done

[[ "$TEAM_ROOT" == /* && "$TEAM_ROOT" != '/' ]] || \
  die 2 'HERDR_CODEX_TEAM_ROOT must select the streamed absolute runtime.'
[[ -x "$TEAM_ROOT/scripts/open.sh" && -x "$TEAM_ROOT/scripts/start.sh" && \
   -x "$TEAM_ROOT/scripts/doctor.sh" && -x "$TEAM_ROOT/scripts/install.sh" && \
   -f "$TEAM_ROOT/scripts/herdr_mcp.py" && ! -L "$TEAM_ROOT/scripts/herdr_mcp.py" && \
   -f "$TEAM_ROOT/scripts/lib/team.sh" && -f "$TEAM_ROOT/scripts/lib/json.sh" && \
   -f "$TEAM_ROOT/scripts/lib/digest.sh" && -f "$TEAM_ROOT/scripts/lib/scope.sh" && \
   -f "$TEAM_ROOT/scripts/lib/run-state.sh" ]] || \
  die 14 "Streamed herdr-codex-team launcher is incomplete: $TEAM_ROOT"

export PATH="$HOME/.local/bin:$HOME/bin:$PATH"
command -v herdr >/dev/null 2>&1 || die 12 'Herdr is not installed on the remote host.'
remote_herdr_output=$(herdr --version 2>&1) || die 16 'Could not read the remote Herdr version.'
REMOTE_HERDR_VERSION=$(parse_herdr_version "$remote_herdr_output") || \
  die 16 "Could not parse the complete remote Herdr version: $remote_herdr_output"
[[ "$REMOTE_HERDR_VERSION" == "$EXPECTED_HERDR_VERSION" ]] || \
  die 16 "Local Herdr is $EXPECTED_HERDR_VERSION but remote Herdr is $REMOTE_HERDR_VERSION."
for role in planner coder reviewer; do
  kind=$(team_role_cli "$role") || exit 2
  command -v "$kind" >/dev/null || die 13 "Remote $role requires $kind."
done
command -v python3 >/dev/null 2>&1 || die 13 'Python 3 is not installed on the remote host.'

# A forwarded socket override takes precedence over a named session. Clear
# both before every Herdr command so this launcher cannot touch another
# runtime, then verify the selected session in structured server status.
unset HERDR_SOCKET_PATH HERDR_CLIENT_SOCKET_PATH TEAM_PREFIX
export HERDR_SESSION="$TEAM"
server_status_json=$(herdr status server --json 2>&1) || \
  die 15 "Could not read named Herdr server status: $server_status_json"
bridge_pid=''
cleanup_bridge() {
  if [[ -n "$bridge_pid" ]] && kill -0 "$bridge_pid" 2>/dev/null; then
    kill "$bridge_pid" 2>/dev/null || true
    wait "$bridge_pid" 2>/dev/null || true
  fi
}
trap cleanup_bridge EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if ! server_json_running "$server_status_json"; then
  bridge_log="$TEAM_ROOT/.remote-bridge.log"
  herdr remote-client-bridge </dev/null >/dev/null 2>"$bridge_log" &
  bridge_pid=$!
  server_ready=0
  for _attempt in {1..50}; do
    server_status_json=$(herdr status server --json 2>&1) || true
    if server_json_running "$server_status_json"; then
      server_ready=1
      break
    fi
    if ! kill -0 "$bridge_pid" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
  cleanup_bridge
  bridge_pid=''
  if [[ $server_ready -ne 1 ]]; then
    printf '[FAIL] Named Herdr server did not become ready.\n' >&2
    tail -n 40 -- "$bridge_log" >&2 2>/dev/null || true
    exit 15
  fi
fi

verify_running_server "$server_status_json" || \
  die 16 'The selected Herdr server version, protocol, session, or detached-daemon capability does not match this launcher.'

OPEN_ARGS=(--team "$TEAM" --cwd "$PROJECT_DIR")
[[ $REPAIR_PROFILES -eq 0 ]] || OPEN_ARGS+=(--repair-profiles)
[[ $INSTALL_INTEGRATION -eq 0 ]] || OPEN_ARGS+=(--install-integration)
for add_dir in ${ADD_DIRS[@]+"${ADD_DIRS[@]}"}; do
  OPEN_ARGS+=(--add-dir "$add_dir")
done
"$TEAM_ROOT/scripts/open.sh" "${OPEN_ARGS[@]}"
