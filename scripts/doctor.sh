#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TEAM_LIB="$SCRIPT_DIR/lib/team.sh"
JSON_LIB="$SCRIPT_DIR/lib/json.sh"
[[ -f "$TEAM_LIB" && -f "$JSON_LIB" ]] || {
  printf '[FAIL] Missing script helper under %s/lib.\n' "$SCRIPT_DIR" >&2
  exit 1
}
# shellcheck source=lib/team.sh
source "$TEAM_LIB"
# shellcheck source=lib/json.sh
source "$JSON_LIB"
CODEX_DIR=${CODEX_HOME:-"$HOME/.codex"}
case "$CODEX_DIR" in
  /*) ;;
  *) CODEX_DIR="$PWD/$CODEX_DIR" ;;
esac
if [[ -d "$CODEX_DIR" ]]; then
  CODEX_DIR=$(CDPATH= cd -- "$CODEX_DIR" && pwd -P)
fi
export CODEX_HOME="$CODEX_DIR"
failures=0
warnings=0
TEAM_CLI_SET=0
TEAM_CLI_PREFIX=''
EXPECTED_CWD_ARG=''
CWD_ARG_SET=0

ok() {
  printf '[OK] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*"
  warnings=$((warnings + 1))
}

fail() {
  printf '[FAIL] %s\n' "$*"
  failures=$((failures + 1))
}

usage() {
  printf '%s\n' \
    'Usage: ./scripts/doctor.sh [--team PREFIX] [--cwd PROJECT_DIR]' \
    '' \
    'Without --team or TEAM_PREFIX, checks legacy planner/coder/reviewer names.' \
    'With --team github, checks github-planner/github-coder/github-reviewer.' \
    'TEAM_PREFIX may supply the prefix when --team is omitted.' \
    '--cwd additionally requires all three agents to use that exact directory.'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --team)
      [[ $# -ge 2 ]] || { usage >&2; fail '--team requires a prefix.'; exit 2; }
      [[ $TEAM_CLI_SET -eq 0 ]] || { fail '--team may be provided only once.'; exit 2; }
      TEAM_CLI_SET=1
      TEAM_CLI_PREFIX=$2
      shift 2
      ;;
    --team=*)
      [[ $TEAM_CLI_SET -eq 0 ]] || { fail '--team may be provided only once.'; exit 2; }
      TEAM_CLI_SET=1
      TEAM_CLI_PREFIX=${1#--team=}
      shift
      ;;
    --cwd)
      [[ $# -ge 2 ]] || { usage >&2; fail '--cwd requires a project directory.'; exit 2; }
      [[ $CWD_ARG_SET -eq 0 ]] || { fail '--cwd may be provided only once.'; exit 2; }
      CWD_ARG_SET=1
      EXPECTED_CWD_ARG=$2
      shift 2
      ;;
    --cwd=*)
      [[ $CWD_ARG_SET -eq 0 ]] || { fail '--cwd may be provided only once.'; exit 2; }
      CWD_ARG_SET=1
      EXPECTED_CWD_ARG=${1#--cwd=}
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "Unknown argument: $1"
      exit 2
      ;;
  esac
done

if ! REQUESTED_TEAM_PREFIX=$(team_resolve_requested_prefix "$TEAM_CLI_SET" "$TEAM_CLI_PREFIX"); then
  fail 'Could not resolve a single non-empty team prefix.'
  exit 2
fi
if ! team_configure "$REQUESTED_TEAM_PREFIX"; then
  fail "Invalid team prefix '$REQUESTED_TEAM_PREFIX'. It must match [a-z][a-z0-9_-]* and be at most 23 characters."
  exit 2
fi

EXPECTED_CWD=''
if [[ $CWD_ARG_SET -eq 1 ]]; then
  [[ -n "$EXPECTED_CWD_ARG" && -d "$EXPECTED_CWD_ARG" ]] || {
    fail "Expected cwd does not exist or is not a directory: $EXPECTED_CWD_ARG"
    exit 2
  }
  EXPECTED_CWD=$(CDPATH= cd -- "$EXPECTED_CWD_ARG" && pwd -P)
fi

extract_agent_field() {
  local payload=$1
  local field=$2

  json_agent_field "$payload" "$field" || true
}

process_uses_profile() {
  local payload=$1
  local role=$2

  json_process_uses_profile "$payload" "$role"
}

printf 'Herdr Codex Team doctor (team: %s)\n\n' "$TEAM_DISPLAY"

if command -v codex >/dev/null 2>&1; then
  ok "Codex found: $(codex --version 2>&1 | head -n 1)"
else
  fail 'Codex not found. Install Codex CLI and make sure `codex` is in PATH.'
fi

if command -v herdr >/dev/null 2>&1; then
  ok "Herdr found: $(herdr --version 2>&1 | head -n 1)"
else
  fail 'Herdr not found. Install Herdr and make sure `herdr` is in PATH.'
fi

json_ready=0
if JSON_BACKEND=$(json_backend_name); then
  json_ready=1
  ok "JSON parser found: $JSON_BACKEND"
else
  fail 'A real JSON parser is required: install jq or make python3 available.'
fi

for role in planner coder reviewer; do
  profile="$CODEX_DIR/$role.config.toml"
  if [[ -f "$profile" ]]; then
    ok "$role profile: $profile"
  else
    fail "$role profile not found at $profile. Run ./scripts/install.sh."
    continue
  fi

  if ! grep -Eq '^approval_policy[[:space:]]*=[[:space:]]*"never"[[:space:]]*$' "$profile"; then
    fail "$role profile does not set approval_policy = \"never\"."
  fi
  if ! grep -Eq '^developer_instructions[[:space:]]*=' "$profile"; then
    fail "$role profile has no installed developer_instructions. Rerun ./scripts/install.sh."
  fi
  if command -v codex >/dev/null 2>&1; then
    if codex --profile "$role" debug prompt-input 'profile validation' >/dev/null 2>&1; then
      ok "$role profile loads in Codex"
    else
      fail "$role profile cannot be loaded by Codex. Restore a backup or rerun ./scripts/install.sh."
    fi
  fi
done

if [[ -f "$CODEX_DIR/planner.config.toml" ]] && \
   ! grep -Eq '^sandbox_mode[[:space:]]*=[[:space:]]*"workspace-write"[[:space:]]*$' "$CODEX_DIR/planner.config.toml"; then
  fail 'planner profile must use sandbox_mode = "workspace-write" for Herdr communication.'
fi
if [[ -f "$CODEX_DIR/coder.config.toml" ]] && \
   ! grep -Eq '^sandbox_mode[[:space:]]*=[[:space:]]*"workspace-write"[[:space:]]*$' "$CODEX_DIR/coder.config.toml"; then
  fail 'coder profile must use sandbox_mode = "workspace-write".'
fi
if [[ -f "$CODEX_DIR/reviewer.config.toml" ]] && \
   ! grep -Eq '^sandbox_mode[[:space:]]*=[[:space:]]*"read-only"[[:space:]]*$' "$CODEX_DIR/reviewer.config.toml"; then
  fail 'reviewer profile must use sandbox_mode = "read-only".'
fi

if ! command -v herdr >/dev/null 2>&1; then
  printf '\nEnvironment is not healthy: %s failure(s), %s warning(s).\n' "$failures" "$warnings"
  exit 1
fi

if [[ $json_ready -ne 1 ]]; then
  printf '\nEnvironment is not healthy: %s failure(s), %s warning(s).\n' "$failures" "$warnings"
  exit 1
fi

if herdr agent start --help >/dev/null 2>&1 && \
   herdr agent prompt --help >/dev/null 2>&1 && \
   herdr agent get --help >/dev/null 2>&1 && \
   herdr agent list --help >/dev/null 2>&1 && \
   herdr agent read --help >/dev/null 2>&1 && \
   herdr agent wait --help >/dev/null 2>&1 && \
   herdr agent rename --help >/dev/null 2>&1 && \
   herdr pane process-info --help >/dev/null 2>&1 && \
   herdr pane split --help >/dev/null 2>&1 && \
   herdr pane rename --help >/dev/null 2>&1 && \
   herdr workspace create --help >/dev/null 2>&1; then
  ok 'Required Herdr command surface is available.'
else
  fail 'Installed Herdr lacks commands required by this project. Compare with the verified 0.8.2 command surface.'
fi

integration_status=$(herdr integration status 2>&1 || true)
if printf '%s\n' "$integration_status" | grep -Eq '^codex: current([[:space:]]|$)'; then
  ok 'Herdr Codex integration is current.'
else
  fail 'Herdr Codex integration is missing or outdated. Review `herdr integration status`, then run `herdr integration install codex` if appropriate.'
fi

server_running=0
if server_status=$(herdr status server 2>&1); then
  server_running=1
  ok 'Herdr server is running.'
else
  fail 'Herdr server is not reachable. Start or attach Herdr with `herdr`, then rerun doctor.sh.'
  printf '       Herdr response: %s\n' "$server_status"
fi

if [[ $server_running -eq 1 ]]; then
  printf '\nExpected agents:\n'
  team_workspace_id=''
  team_cwd=''
  seen_panes='|'
  for role in planner coder reviewer; do
    live_name_expected=$(team_agent_for_role "$role")
    if agent_payload=$(herdr agent get "$live_name_expected" 2>&1); then
      live_name=$(extract_agent_field "$agent_payload" name)
      state=$(extract_agent_field "$agent_payload" agent_status)
      agent_kind=$(extract_agent_field "$agent_payload" agent)
      interactive_ready=$(extract_agent_field "$agent_payload" interactive_ready)
      launch_pending=$(extract_agent_field "$agent_payload" launch_pending)
      pane_id=$(extract_agent_field "$agent_payload" pane_id)
      workspace_id=$(extract_agent_field "$agent_payload" workspace_id)
      agent_cwd=$(extract_agent_field "$agent_payload" cwd)
      foreground_cwd=$(extract_agent_field "$agent_payload" foreground_cwd)
      effective_cwd=${foreground_cwd:-$agent_cwd}
      if [[ -n "$effective_cwd" && -d "$effective_cwd" ]]; then
        effective_cwd=$(CDPATH= cd -- "$effective_cwd" && pwd -P)
      fi
      if [[ "$live_name" != "$live_name_expected" ]]; then
        fail "$live_name_expected target resolved to unexpected live name '${live_name:-unknown}'."
        continue
      fi
      if [[ "$agent_kind" != 'codex' ]]; then
        fail "$live_name_expected resolves to agent kind '${agent_kind:-unknown}', not codex."
        continue
      fi
      identity_failures_before=$failures
      if [[ -z "$pane_id" ]]; then
        fail "$live_name_expected did not expose a pane ID, so its active profile cannot be verified."
      elif [[ "$seen_panes" == *"|$pane_id|"* ]]; then
        fail "$live_name_expected reuses pane $pane_id; every role must occupy a distinct pane."
      elif process_payload=$(herdr pane process-info --pane "$pane_id" 2>&1); then
        if process_uses_profile "$process_payload" "$role"; then
          ok "$live_name_expected foreground process uses generic --profile $role"
        else
          fail "$live_name_expected is not verifiably running with --profile $role. Restart it through start.sh."
        fi
      else
        fail "$live_name_expected foreground process could not be inspected: $process_payload"
      fi
      seen_panes="$seen_panes$pane_id|"
      if [[ -z "$workspace_id" ]]; then
        fail "$live_name_expected did not expose a workspace ID."
      elif [[ -z "$team_workspace_id" ]]; then
        team_workspace_id=$workspace_id
      elif [[ "$workspace_id" != "$team_workspace_id" ]]; then
        fail "$live_name_expected is in workspace $workspace_id, not same-team workspace $team_workspace_id."
      fi
      if [[ -z "$effective_cwd" ]]; then
        fail "$live_name_expected did not expose cwd or foreground_cwd."
      elif [[ -n "$EXPECTED_CWD" && "$effective_cwd" != "$EXPECTED_CWD" ]]; then
        fail "$live_name_expected cwd is '$effective_cwd', expected '$EXPECTED_CWD'."
      elif [[ -z "$team_cwd" ]]; then
        team_cwd=$effective_cwd
      elif [[ "$effective_cwd" != "$team_cwd" ]]; then
        fail "$live_name_expected cwd is '$effective_cwd', not same-team cwd '$team_cwd'."
      fi
      if [[ $failures -eq $identity_failures_before ]]; then
        ok "$live_name_expected identity: pane=$pane_id workspace=$workspace_id cwd=$effective_cwd"
      fi
      if [[ "$launch_pending" == 'true' ]]; then
        fail "$live_name_expected launch is still pending. Inspect with: herdr agent get $live_name_expected"
        continue
      fi
      case "$state" in
        idle|done)
          if [[ "$interactive_ready" == 'true' ]]; then
            ok "$live_name_expected found (state: $state, ready: true)"
          else
            fail "$live_name_expected is $state but not interactively ready. Inspect its pane."
          fi
          ;;
        working)
          warn "$live_name_expected is currently working. Wait for it to settle before running communication tests."
          ;;
        blocked)
          fail "$live_name_expected is blocked. Read its pane and let the user resolve the approval or question."
          ;;
        unknown|'')
          fail "$live_name_expected lifecycle state is '${state:-unknown}'; completion is not verified."
          ;;
        *)
          fail "$live_name_expected reported unsupported lifecycle state '$state'."
          ;;
      esac
    else
      fail "$live_name_expected not found. Run ./scripts/start.sh${REQUESTED_TEAM_PREFIX:+ --team $REQUESTED_TEAM_PREFIX} --cwd /path/to/project."
    fi
  done

  if [[ -n "$team_workspace_id" ]]; then
    ok "Team workspace: $team_workspace_id"
  fi
  if [[ -n "$team_cwd" ]]; then
    ok "Team cwd: $team_cwd"
  fi

  printf '\nCurrent Herdr agent list:\n'
  herdr agent list 2>&1 || fail 'Unable to read the current Herdr agent list.'
else
  for role in planner coder reviewer; do
    live_name_expected=$(team_agent_for_role "$role")
    fail "$live_name_expected could not be checked while the Herdr server is unavailable."
  done
fi

printf '\n'
if [[ $failures -eq 0 ]]; then
  printf 'Environment looks healthy. %s warning(s).\n' "$warnings"
  exit 0
fi

printf 'Environment is not healthy: %s failure(s), %s warning(s).\n' "$failures" "$warnings"
exit 1
