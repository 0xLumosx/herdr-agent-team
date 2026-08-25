#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
TEAM_LIB="$SCRIPT_DIR/lib/team.sh"
JSON_LIB="$SCRIPT_DIR/lib/json.sh"
DIGEST_LIB="$SCRIPT_DIR/lib/digest.sh"
SCOPE_LIB="$SCRIPT_DIR/lib/scope.sh"
[[ -f "$TEAM_LIB" && -f "$JSON_LIB" && -f "$DIGEST_LIB" && -f "$SCOPE_LIB" ]] || {
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
ADD_DIR_ARGS=()
ADD_DIRS=()
EXPECTED_DIRS=()
EXPECTED_SCOPE_ROOTS=()
EXPECTED_HAS_NON_GIT=0

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
    'Usage: ./scripts/doctor.sh [--team PREFIX] [--cwd PROJECT_DIR] [--add-dir DIR]...' \
    '' \
    'Without --team or TEAM_PREFIX, checks legacy planner/coder/reviewer names.' \
    'With --team github, checks github-planner/github-coder/github-reviewer.' \
    'TEAM_PREFIX may supply the prefix when --team is omitted.' \
    '--cwd requires all three agents to use that exact primary directory.' \
    '--add-dir is repeatable; Planner/Coder must expose those writable roots, while read-only Reviewer must expose none.'
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
    --add-dir)
      [[ $# -ge 2 ]] || { usage >&2; fail '--add-dir requires a directory.'; exit 2; }
      ADD_DIR_ARGS+=("$2")
      shift 2
      ;;
    --add-dir=*)
      ADD_DIR_ARGS+=("${1#--add-dir=}")
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

  actual_output=$(json_process_codex_add_dirs "$payload") || return 1
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

if [[ $EXPECTED_HAS_NON_GIT -eq 1 ]]; then
  warn 'Expected scope includes non-Git roots; launch identity can be checked, but complete Git diff/baseline evidence is unavailable.'
fi

if command -v codex >/dev/null 2>&1; then
  ok "Codex found: $(codex --version 2>&1 | head -n 1)"
  if [[ ${#ADD_DIRS[@]} -gt 0 ]]; then
    if codex_help=$(codex --help 2>&1) && grep -Fq -- '--add-dir' <<<"$codex_help"; then
      ok 'Codex exposes --add-dir.'
    else
      fail 'This Codex CLI does not expose --add-dir.'
    fi
  fi
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
  if prompt_integrity_error=$(profile_prompt_integrity \
       "$profile" "$PROJECT_ROOT/prompts/$role.md" 2>&1); then
    ok "$role installed prompt matches the managed source"
  else
    fail "$role $prompt_integrity_error. Rerun ./scripts/install.sh."
  fi
  if policy_integrity_error=$(profile_policy_integrity \
       "$profile" "$PROJECT_ROOT/profiles/$role.config.toml" 2>&1); then
    ok "$role installed profile policy matches the managed source"
  else
    fail "$role $policy_integrity_error. Rerun ./scripts/install.sh."
  fi
  if command -v codex >/dev/null 2>&1; then
    case "$role" in
      planner|coder) expected_sandbox=workspace-write ;;
      reviewer) expected_sandbox=read-only ;;
    esac
    validation_args=(
      --profile "$role"
      -c 'sandbox_workspace_write.writable_roots=[]'
      --sandbox "$expected_sandbox"
    )
    if [[ "$role" != reviewer ]]; then
      for add_dir in ${ADD_DIRS[@]+"${ADD_DIRS[@]}"}; do
        validation_args+=(--add-dir "$add_dir")
      done
    fi
    if codex "${validation_args[@]}" debug prompt-input 'profile validation' >/dev/null 2>&1; then
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
      if ! live_name=$(json_agent_required_string "$agent_payload" name) || \
         ! state=$(json_agent_required_string "$agent_payload" agent_status) || \
         ! agent_kind=$(json_agent_required_string "$agent_payload" agent) || \
         ! interactive_ready=$(json_agent_required_boolean "$agent_payload" interactive_ready) || \
         ! launch_pending=$(json_agent_required_boolean "$agent_payload" launch_pending) || \
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
      if [[ "$agent_kind" != 'codex' ]]; then
        fail "$live_name_expected resolves to agent kind '${agent_kind:-unknown}', not codex."
        continue
      fi
      identity_failures_before=$failures
      case "$role" in
        planner|coder) expected_sandbox=workspace-write ;;
        reviewer) expected_sandbox=read-only ;;
      esac
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
        if json_process_has_managed_scope "$process_payload" "$expected_sandbox"; then
          ok "$live_name_expected uses the managed writable-roots override and --sandbox $expected_sandbox"
        else
          fail "$live_name_expected lacks the exact managed scope/sandbox argv. Restart it through the current start.sh."
        fi
        if process_add_dirs_match "$process_payload" "$role"; then
          if [[ "$role" == reviewer ]]; then
            ok "$live_name_expected has no --add-dir writable-root grants, as required by read-only sandbox"
          else
            ok "$live_name_expected additional roots match the requested writable --add-dir list"
          fi
        else
          fail "$live_name_expected writable-root argv does not match its role: Planner/Coder require the requested --add-dir list and Reviewer requires none. Rerun doctor with the same options used by start.sh."
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
