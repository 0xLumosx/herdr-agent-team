#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
TEAM_LIB="$SCRIPT_DIR/lib/team.sh"
JSON_LIB="$SCRIPT_DIR/lib/json.sh"
DIGEST_LIB="$SCRIPT_DIR/lib/digest.sh"
SCOPE_LIB="$SCRIPT_DIR/lib/scope.sh"
RUN_STATE_LIB="$SCRIPT_DIR/lib/run-state.sh"
BRIDGE_SOURCE="$SCRIPT_DIR/herdr_mcp.py"
[[ -f "$TEAM_LIB" && -f "$JSON_LIB" && -f "$DIGEST_LIB" && -f "$SCOPE_LIB" && \
   -f "$RUN_STATE_LIB" ]] || {
  printf '[FAIL] Missing script helper under %s/lib.\n' "$SCRIPT_DIR" >&2
  exit 1
}
# shellcheck source=lib/team.sh
source "$TEAM_LIB"
# shellcheck source=lib/json.sh
source "$JSON_LIB"
# shellcheck source=lib/digest.sh
source "$DIGEST_LIB"
# shellcheck source=lib/scope.sh
source "$SCOPE_LIB"
# shellcheck source=lib/run-state.sh
source "$RUN_STATE_LIB"
CODEX_DIR=${CODEX_HOME:-"$HOME/.codex"}
case "$CODEX_DIR" in
  /*) ;;
  *) CODEX_DIR="$PWD/$CODEX_DIR" ;;
esac
if [[ -d "$CODEX_DIR" ]]; then
  CODEX_DIR=$(CDPATH= cd -- "$CODEX_DIR" && pwd -P)
fi
export CODEX_HOME="$CODEX_DIR"
BRIDGE_TARGET="$CODEX_DIR/herdr-codex-team/herdr_mcp.py"
failures=0
warnings=0
TEAM_CLI_SET=0
TEAM_CLI_PREFIX=''
EXPECTED_CWD_ARG=''
CWD_ARG_SET=0
ADD_DIR_ARGS=()
ADD_DIRS=()
EXPECTED_DIRS=()
EXPECTED_SCOPE_ROOTS=()
EXPECTED_HAS_NON_GIT=0
STATE_SCOPE_LOADED=0
BIND_RECORD_IF_PRESENT=0

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
    'Usage: ./scripts/doctor.sh [--bind-record-if-present] [--team PREFIX] [--cwd PROJECT_DIR] [--add-dir DIR]...' \
    '' \
    'Without --team or TEAM_PREFIX, checks legacy planner/coder/reviewer names.' \
    'With --team github, checks github-planner/github-coder/github-reviewer.' \
    'TEAM_PREFIX may supply the prefix when --team is omitted.' \
    '--cwd requires all three agents to use that exact primary directory.' \
    '--add-dir is repeatable; Planner and Coder must expose those workspace roots, while Reviewer exposes none.' \
    "With neither root option, Doctor loads this team's latest user-local launch record when one exists." \
    'Supplying --cwd explicitly bypasses recorded runtime-ID binding and verifies the requested live scope directly.' \
    '--bind-record-if-present keeps explicit root checks and also binds any existing launch record IDs; open.sh uses it for safe reuse.'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --planner-cli|--coder-cli|--reviewer-cli)
      [[ $# -ge 2 && -n "$2" ]] || { printf '%s requires a CLI name\n' "$1" >&2; exit 2; }
      team_set_role_cli "$1" "$2" || exit 2
      shift 2 ;;
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
    --add-dir)
      [[ $# -ge 2 ]] || { usage >&2; fail '--add-dir requires a directory.'; exit 2; }
      ADD_DIR_ARGS+=("$2")
      shift 2
      ;;
    --add-dir=*)
      ADD_DIR_ARGS+=("${1#--add-dir=}")
      shift
      ;;
    --bind-record-if-present)
      [[ $BIND_RECORD_IF_PRESENT -eq 0 ]] || { fail '--bind-record-if-present may be provided only once.'; exit 2; }
      BIND_RECORD_IF_PRESENT=1
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
if ! run_state_configure "$CODEX_DIR" "$TEAM_MODE" "$TEAM_PREFIX_EFFECTIVE"; then
  fail 'Could not derive a safe user-local launch-state path.'
  exit 2
fi
if [[ $BIND_RECORD_IF_PRESENT -eq 1 && $CWD_ARG_SET -eq 0 ]]; then
  fail '--bind-record-if-present requires an explicit --cwd.'
  exit 2
fi
if [[ $CWD_ARG_SET -eq 0 && ${#ADD_DIR_ARGS[@]} -eq 0 ]] || \
   [[ $BIND_RECORD_IF_PRESENT -eq 1 ]]; then
  if run_state_current_exists; then
    if ! run_state_load_scope; then
      fail "The user-local launch record is malformed or incompatible: $RUN_STATE_FILE"
      exit 2
    fi
    STATE_SCOPE_LOADED=1
    if [[ $BIND_RECORD_IF_PRESENT -eq 0 ]]; then
      CWD_ARG_SET=1
      EXPECTED_CWD_ARG=$RUN_STATE_LOADED_CWD
      for state_add_dir in ${RUN_STATE_LOADED_ADD_DIRS[@]+"${RUN_STATE_LOADED_ADD_DIRS[@]}"}; do
        ADD_DIR_ARGS+=("$state_add_dir")
      done
    fi
  else
    state_exists_status=$?
    if [[ $state_exists_status -eq 2 ]]; then
      fail "The user-local launch-record path is not a safe regular file: $RUN_STATE_FILE"
      exit 2
    fi
  fi
fi
if [[ ${#ADD_DIR_ARGS[@]} -gt 0 && $CWD_ARG_SET -eq 0 ]]; then
  fail '--add-dir requires --cwd so primary and additional roots can be validated together.'
  exit 2
fi

EXPECTED_CWD=''
if [[ $CWD_ARG_SET -eq 1 ]]; then
  if scope_path_has_control "$EXPECTED_CWD_ARG"; then
    fail 'Expected cwd contains an unsupported control character.'
    exit 2
  fi
  [[ -n "$EXPECTED_CWD_ARG" && -d "$EXPECTED_CWD_ARG" ]] || {
    fail "Expected cwd does not exist or is not a directory: $EXPECTED_CWD_ARG"
    exit 2
  }
  EXPECTED_CWD=$(scope_physical_dir "$EXPECTED_CWD_ARG") || {
    fail 'Expected cwd contains an unsupported control character or cannot be resolved.'
    exit 2
  }
  [[ "$EXPECTED_CWD" != '/' ]] || {
    fail 'Refusing to verify a workspace rooted at the filesystem root.'
    exit 2
  }
fi

for add_dir_arg in ${ADD_DIR_ARGS[@]+"${ADD_DIR_ARGS[@]}"}; do
  if scope_path_has_control "$add_dir_arg"; then
    fail 'Expected additional directory contains an unsupported control character.'
    exit 2
  fi
  [[ -n "$add_dir_arg" && -d "$add_dir_arg" ]] || {
    fail "Expected additional directory does not exist or is not a directory: $add_dir_arg"
    exit 2
  }
  add_dir=$(scope_physical_dir "$add_dir_arg") || {
    fail 'Expected additional directory contains an unsupported control character or cannot be resolved.'
    exit 2
  }
  [[ "$add_dir" != '/' ]] || {
    fail 'Refusing to verify the filesystem root as an additional directory.'
    exit 2
  }
  if [[ -n "$EXPECTED_CWD" ]] && scope_paths_overlap "$EXPECTED_CWD" "$add_dir"; then
    fail "Expected additional directory overlaps the primary cwd: $add_dir"
    exit 2
  fi
  for existing_add_dir in ${ADD_DIRS[@]+"${ADD_DIRS[@]}"}; do
    if scope_paths_overlap "$existing_add_dir" "$add_dir"; then
      fail "Expected additional directories overlap or resolve to the same physical path: $existing_add_dir and $add_dir"
      exit 2
    fi
  done
  ADD_DIRS+=("$add_dir")
done

if [[ -n "$EXPECTED_CWD" ]]; then
  EXPECTED_DIRS+=("$EXPECTED_CWD")
  for add_dir in ${ADD_DIRS[@]+"${ADD_DIRS[@]}"}; do
    EXPECTED_DIRS+=("$add_dir")
  done
  for expected_dir in "${EXPECTED_DIRS[@]}"; do
    if expected_git_root=$(scope_git_root "$expected_dir"); then
      expected_scope_root=$expected_git_root
    else
      git_scope_status=$?
      if [[ $git_scope_status -eq 1 ]]; then
        expected_scope_root=$expected_dir
        EXPECTED_HAS_NON_GIT=1
      else
        fail "Could not safely inspect Git scope for an expected directory: $expected_dir"
        exit 2
      fi
    fi
    for existing_scope_root in ${EXPECTED_SCOPE_ROOTS[@]+"${EXPECTED_SCOPE_ROOTS[@]}"}; do
      if scope_paths_overlap "$existing_scope_root" "$expected_scope_root"; then
        fail "Expected directories share or overlap one effective Git/filesystem scope: $existing_scope_root and $expected_scope_root"
        exit 2
      fi
    done
    EXPECTED_SCOPE_ROOTS+=("$expected_scope_root")
  done
fi

if [[ $BIND_RECORD_IF_PRESENT -eq 1 && $STATE_SCOPE_LOADED -eq 1 ]]; then
  record_scope_matches=1
  [[ "$EXPECTED_CWD" == "$RUN_STATE_LOADED_CWD" ]] || record_scope_matches=0
  if [[ ${#ADD_DIRS[@]} -ne ${#RUN_STATE_LOADED_ADD_DIRS[@]} ]]; then
    record_scope_matches=0
  else
    for ((scope_index = 0; scope_index < ${#ADD_DIRS[@]}; scope_index++)); do
      if [[ "${ADD_DIRS[$scope_index]}" != "${RUN_STATE_LOADED_ADD_DIRS[$scope_index]}" ]]; then
        record_scope_matches=0
        break
      fi
    done
  fi
  if [[ $record_scope_matches -ne 1 ]]; then
    fail 'Requested cwd/ordered --add-dir list does not match the existing launch record.'
    exit 2
  fi
fi

if run_state_current_exists; then
  cli_rows=$(python3 -c 'import json,sys
a=json.load(open(sys.argv[1]))["herdr"]["agents"]
for r in ("planner","coder","reviewer"):
 print(r, a[r].get("cli","codex"))' "$RUN_STATE_FILE") || { fail 'Malformed recorded CLI selection'; exit 2; }
  while read -r role recorded; do
    case "$role" in
      planner) PLANNER_CLI=${PLANNER_CLI:-$recorded} ;;
      coder) CODER_CLI=${CODER_CLI:-$recorded} ;;
      reviewer) REVIEWER_CLI=${REVIEWER_CLI:-$recorded} ;;
    esac
    [[ $(team_role_cli "$role") == "$recorded" ]] || { fail "$role CLI differs from its launch record"; exit 2; }
  done <<<"$cli_rows"
fi

process_uses_profile() {
  local payload=$1
  local role=$2

  json_process_uses_profile "$payload" "$role"
}

process_add_dirs_match() {
  local payload=$1
  local role=$2
  local actual_output
  local actual_dir
  local expected_count
  local index=0

  case "$role" in
    planner|coder) expected_count=${#ADD_DIRS[@]} ;;
    reviewer) expected_count=0 ;;
    *) return 1 ;;
  esac

  actual_output=$(team_process_dirs "$payload" "$role" "$(team_role_cli "$role")") || return 1
  while IFS= read -r actual_dir; do
    [[ -n "$actual_dir" ]] || continue
    (( index < expected_count )) || return 1
    actual_dir=$(scope_physical_dir "$actual_dir") || return 1
    [[ "$actual_dir" == "${ADD_DIRS[$index]}" ]] || return 1
    index=$((index + 1))
  done <<<"$actual_output"
  (( index == expected_count ))
}

printf 'Herdr Codex Team doctor (team: %s)\n\n' "$TEAM_DISPLAY"

if [[ $STATE_SCOPE_LOADED -eq 1 ]]; then
  ok "Loaded launch record $RUN_STATE_LOADED_RUN_ID (recorded state: $RUN_STATE_LOADED_STATUS)"
  printf '     Source: %s\n' "$RUN_STATE_FILE"
  printf '     Herdr remains authoritative; the recorded IDs and roots are expectations to verify.\n'
fi

if [[ $EXPECTED_HAS_NON_GIT -eq 1 ]]; then
  warn 'Expected scope includes non-Git roots; launch identity can be checked, but complete Git diff/baseline evidence is unavailable.'
fi

for role in planner coder reviewer; do
  kind=$(team_role_cli "$role") || exit 2
  if command -v "$kind" >/dev/null; then ok "$role CLI: $kind"; else fail "$role requires $kind in PATH."; fi
done

if command -v herdr >/dev/null 2>&1; then
  ok "Herdr found: $(herdr --version 2>&1 | head -n 1)"
else
  fail 'Herdr not found. Install Herdr and make sure `herdr` is in PATH.'
fi

PYTHON_BIN=''
HERDR_BIN=''
if command -v python3 >/dev/null 2>&1 && \
   PYTHON_BIN=$(managed_python_executable); then
  ok "Python found: $("$PYTHON_BIN" --version 2>&1 | head -n 1) ($PYTHON_BIN)"
  if bridge_integrity_error=$(managed_bridge_integrity \
       "$BRIDGE_TARGET" "$BRIDGE_SOURCE" 2>&1); then
    if "$PYTHON_BIN" "$BRIDGE_TARGET" --check >/dev/null 2>&1; then
      ok 'Planner Herdr MCP bridge matches the managed source and passes self-check'
    else
      fail 'Installed Planner Herdr MCP bridge failed its self-check. Rerun ./scripts/install.sh.'
    fi
  else
    fail "$bridge_integrity_error. Rerun ./scripts/install.sh."
  fi
else
  fail 'Python 3 was not found or did not resolve to a safe absolute executable; the Planner Herdr MCP bridge cannot start.'
fi
if command -v herdr >/dev/null 2>&1 && [[ -n "$PYTHON_BIN" ]] && \
   HERDR_BIN=$(managed_command_executable herdr "$PYTHON_BIN"); then
  ok "Herdr executable resolves safely: $HERDR_BIN"
else
  fail 'Herdr did not resolve to a safe absolute executable; Planner profile validation cannot start its managed bridge.'
fi

json_ready=0
if JSON_BACKEND=$(json_backend_name); then
  json_ready=1
  ok "JSON parser found: $JSON_BACKEND"
else
  fail 'A real JSON parser is required: install jq or make python3 available.'
fi

if [[ -f "$CODEX_DIR/config.toml" ]] && \
   grep -Eq '^[[:space:]]*(sandbox_mode[[:space:]]*=|\[sandbox_workspace_write\])' \
     "$CODEX_DIR/config.toml"; then
  warn "$CODEX_DIR/config.toml contains legacy sandbox settings; effective permission checks below must pass, and the base config should be migrated for documented forward compatibility."
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
  if ! grep -Eq '^agents[.]enabled[[:space:]]*=[[:space:]]*false[[:space:]]*$' "$profile"; then
    fail "$role profile does not set agents.enabled = false; native Codex subagents must be unavailable."
  fi
  if ! grep -Eq '^developer_instructions[[:space:]]*=' "$profile"; then
    fail "$role profile has no installed developer_instructions. Rerun ./scripts/install.sh."
  fi
  if prompt_integrity_error=$(profile_prompt_integrity \
       "$profile" "$PROJECT_ROOT/prompts/$role.md" 2>&1); then
    ok "$role installed prompt matches the managed source"
  else
    fail "$role $prompt_integrity_error. Rerun ./scripts/install.sh."
  fi
  if policy_integrity_error=$(profile_policy_integrity \
       "$profile" "$PROJECT_ROOT/profiles/$role.config.toml" \
       "$PYTHON_BIN" "$BRIDGE_TARGET" 2>&1); then
    ok "$role installed profile policy matches the managed source"
  else
    fail "$role $policy_integrity_error. Rerun ./scripts/install.sh."
  fi
  if [[ $(team_role_cli "$role") == codex ]] && command -v codex >/dev/null 2>&1; then
    managed_role_permission_policy "$role" || {
      fail "Could not resolve the managed permission policy for role: $role"
      continue
    }
    expected_sandbox=$MANAGED_ROLE_SANDBOX
    if grep -Eq '^sandbox_mode[[:space:]]*=' "$profile"; then
      fail "$role profile still uses legacy sandbox_mode, which disables managed network permissions."
    fi
    if ! grep -Eq '^default_permissions[[:space:]]*=[[:space:]]*"'"$MANAGED_ROLE_PERMISSION_NAME"'"[[:space:]]*$' "$profile"; then
      fail "$role profile does not select $MANAGED_ROLE_PERMISSION_NAME."
    fi
    if ! grep -Eq '^permissions[.]'"$MANAGED_ROLE_PERMISSION_NAME"'[.]extends[[:space:]]*=[[:space:]]*"'"$MANAGED_ROLE_PERMISSION_PARENT"'"[[:space:]]*$' "$profile"; then
      fail "$role profile does not preserve the $expected_sandbox filesystem boundary."
    fi
    if ! grep -Eq '^permissions[.]'"$MANAGED_ROLE_PERMISSION_NAME"'[.]network[.]enabled[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$profile"; then
      fail "$role profile does not enable command network access."
    fi
    validation_args=(
      --profile "$role"
      -c 'agents.enabled=false'
    )
    for permission_config in "${MANAGED_ROLE_PERMISSION_CONFIGS[@]}"; do
      validation_args+=(-c "$permission_config")
    done
    if [[ "$role" != reviewer ]]; then
      for add_dir in ${ADD_DIRS[@]+"${ADD_DIRS[@]}"}; do
        validation_args+=(--add-dir "$add_dir")
      done
    fi
    validation_cwd=${EXPECTED_CWD:-$PWD}
    if rendered_permissions=$(CDPATH= cd -- "$validation_cwd" && \
         HERDR_BIN_PATH="$HERDR_BIN" \
         codex "${validation_args[@]}" \
         debug prompt-input 'profile validation' 2>/dev/null) && \
       json_prompt_has_effective_role_permissions "$rendered_permissions" "$role"; then
      ok "$role resolves to local $expected_sandbox with command network enabled"
      if [[ $CWD_ARG_SET -eq 1 ]]; then
        if json_prompt_has_role_workspace_roots \
             "$rendered_permissions" "$role" "$EXPECTED_CWD" \
             ${ADD_DIRS[@]+"${ADD_DIRS[@]}"}; then
          ok "$role exposes the exact managed workspace-root context"
        else
          fail "$role does not expose the exact managed workspace-root context. Use a compatible Codex release."
        fi
      fi
    else
      fail "$role does not resolve to local $expected_sandbox with command network enabled. Remove conflicting legacy sandbox settings or use a compatible Codex release."
    fi
  fi
done

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
while IFS= read -r integration; do
  if grep -Eq "^$integration: current([[:space:]]|$)" <<<"$integration_status"; then
    ok "Herdr $integration integration is current."
  else
    fail "Missing or outdated integration: $integration"
  fi
done < <(team_integrations)

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
      if ! live_name=$(json_agent_required_string "$agent_payload" name) || \
         ! state=$(json_agent_required_string "$agent_payload" agent_status) || \
         ! agent_kind=$(json_agent_required_string "$agent_payload" agent) || \
         ! interactive_ready=$(json_agent_required_boolean "$agent_payload" interactive_ready) || \
         ! launch_pending=$(json_agent_boolean_or_false_if_absent "$agent_payload" launch_pending) || \
         ! pane_id=$(json_agent_required_string "$agent_payload" pane_id) || \
         ! workspace_id=$(json_agent_required_string "$agent_payload" workspace_id); then
        fail "$live_name_expected reported malformed identity or lifecycle fields."
        continue
      fi
      if ! agent_cwd=$(json_agent_optional_string "$agent_payload" cwd) || \
         ! foreground_cwd=$(json_agent_optional_string "$agent_payload" foreground_cwd); then
        fail "$live_name_expected reported malformed cwd fields."
        continue
      fi
      effective_cwd=''
      cwd_evidence_count=0
      cwd_evidence_invalid=0
      for cwd_field in cwd foreground_cwd; do
        case "$cwd_field" in
          cwd) reported_cwd=$agent_cwd ;;
          foreground_cwd) reported_cwd=$foreground_cwd ;;
        esac
        [[ -n "$reported_cwd" ]] || continue
        cwd_evidence_count=$((cwd_evidence_count + 1))
        if scope_path_has_control "$reported_cwd"; then
          fail "$live_name_expected reported $cwd_field with unsupported control characters."
          cwd_evidence_invalid=1
          continue
        fi
        if [[ ! -d "$reported_cwd" ]]; then
          fail "$live_name_expected reported $cwd_field that does not exist or is not a directory: $reported_cwd"
          cwd_evidence_invalid=1
          continue
        fi
        if ! resolved_cwd=$(scope_physical_dir "$reported_cwd"); then
          fail "$live_name_expected reported $cwd_field that cannot be resolved safely."
          cwd_evidence_invalid=1
          continue
        fi
        if [[ "$resolved_cwd" == '/' ]]; then
          fail "$live_name_expected reported the filesystem root as $cwd_field."
          cwd_evidence_invalid=1
          continue
        fi
        if [[ -z "$effective_cwd" ]]; then
          effective_cwd=$resolved_cwd
        elif [[ "$resolved_cwd" != "$effective_cwd" ]]; then
          fail "$live_name_expected reported cwd and foreground_cwd that resolve to different directories."
          cwd_evidence_invalid=1
        fi
      done
      if [[ $cwd_evidence_count -eq 0 ]]; then
        fail "$live_name_expected did not expose cwd or foreground_cwd."
        continue
      fi
      if [[ $cwd_evidence_invalid -ne 0 ]]; then
        continue
      fi
      if [[ "$live_name" != "$live_name_expected" ]]; then
        fail "$live_name_expected target resolved to unexpected live name '${live_name:-unknown}'."
        continue
      fi
      if [[ "$agent_kind" != "$(team_role_cli "$role")" ]]; then
        fail "$live_name_expected resolves to agent kind '${agent_kind:-unknown}', expected $(team_role_cli "$role")."
        continue
      fi
      identity_failures_before=$failures
      if [[ $STATE_SCOPE_LOADED -eq 1 ]]; then
        case "$role" in
          planner) recorded_pane_id=$RUN_STATE_LOADED_PLANNER_PANE ;;
          coder) recorded_pane_id=$RUN_STATE_LOADED_CODER_PANE ;;
          reviewer) recorded_pane_id=$RUN_STATE_LOADED_REVIEWER_PANE ;;
        esac
        if [[ -n "$recorded_pane_id" && "$pane_id" != "$recorded_pane_id" ]]; then
          fail "$live_name_expected pane is $pane_id, not recorded run pane $recorded_pane_id. The launch record is stale or a different session now owns the name."
        fi
        if [[ -n "$RUN_STATE_LOADED_WORKSPACE_ID" && \
              "$workspace_id" != "$RUN_STATE_LOADED_WORKSPACE_ID" ]]; then
          fail "$live_name_expected workspace is $workspace_id, not recorded run workspace $RUN_STATE_LOADED_WORKSPACE_ID. The launch record is stale or a different session now owns the name."
        fi
      fi
      if [[ -z "$pane_id" ]]; then
        fail "$live_name_expected did not expose a pane ID, so its active profile cannot be verified."
      elif [[ "$seen_panes" == *"|$pane_id|"* ]]; then
        fail "$live_name_expected reuses pane $pane_id; every role must occupy a distinct pane."
      elif process_payload=$(herdr pane process-info --pane "$pane_id" 2>&1); then
        if team_process_policy "$process_payload" "$role" "$agent_kind"; then
          ok "$live_name_expected uses its managed $agent_kind role configuration"
        else
          fail "$live_name_expected lacks its managed role configuration."
        fi
        if process_add_dirs_match "$process_payload" "$role"; then
          if [[ "$role" == coder ]]; then
            ok "$live_name_expected additional roots match the requested writable --add-dir list"
          elif [[ "$role" == planner ]]; then
            ok "$live_name_expected additional roots match the requested read-only workspace context"
          else
            ok "$live_name_expected has no --add-dir writable-root grants, as required by read-only sandbox"
          fi
        else
          fail "$live_name_expected additional-root argv does not match its role: Planner and Coder require the requested --add-dir list; Reviewer requires none. Rerun doctor with the same options used by start.sh."
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
      if [[ -n "$EXPECTED_CWD" && "$effective_cwd" != "$EXPECTED_CWD" ]]; then
        fail "$live_name_expected cwd is '$effective_cwd', expected '$EXPECTED_CWD'."
      elif [[ -z "$team_cwd" ]]; then
        team_cwd=$effective_cwd
      elif [[ "$effective_cwd" != "$team_cwd" ]]; then
        fail "$live_name_expected cwd is '$effective_cwd', not same-team cwd '$team_cwd'."
      fi
      if [[ $failures -eq $identity_failures_before ]]; then
        ok "$live_name_expected identity: pane=$pane_id workspace=$workspace_id cwd=$effective_cwd"
      fi
      if [[ "$launch_pending" != 'false' ]]; then
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
  for add_dir in ${ADD_DIRS[@]+"${ADD_DIRS[@]}"}; do
    ok "Team additional root: $add_dir (launch argv evidence)"
  done

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
