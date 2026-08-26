#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
TEAM_LIB="$SCRIPT_DIR/lib/team.sh"
JSON_LIB="$SCRIPT_DIR/lib/json.sh"
DIGEST_LIB="$SCRIPT_DIR/lib/digest.sh"
SCOPE_LIB="$SCRIPT_DIR/lib/scope.sh"
RUN_STATE_LIB="$SCRIPT_DIR/lib/run-state.sh"
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
NO_FOCUS=0
PROJECT_ARG=''
PROJECT_POSITIONAL_SET=0
CWD_ARG_SET=0
TEAM_CLI_SET=0
TEAM_CLI_PREFIX=''
ADD_DIR_ARGS=()
ADD_DIRS=()
REQUESTED_DIRS=()
REQUESTED_SCOPE_ROOTS=()
REQUESTED_HAS_NON_GIT=0
workspace_id=''
START_TIMEOUT_MS=${HERDR_START_TIMEOUT_MS:-120000}
startup_issues=0
first_issue_role=''
RUN_ID=''
RUN_STARTED_AT=''
RUN_STATE_ACTIVE=0
RUN_STATE_FINAL_STATUS=''

usage() {
  printf '%s\n' \
    'Usage: ./scripts/start.sh [--no-focus] [--team PREFIX] [--cwd PROJECT_DIR] [--add-dir DIR]... [PROJECT_DIR]' \
    '' \
    'Creates one Herdr workspace with three live agents.' \
    'Without --team or TEAM_PREFIX: planner, coder, reviewer (legacy mode).' \
    'With --team github: github-planner, github-coder, github-reviewer.' \
    'TEAM_PREFIX may supply the prefix when --team is omitted.' \
    'PROJECT_DIR defaults to the current directory.' \
    'Existing Git and non-Git project directories are both supported.' \
    'Non-Git roots start normally with explicit degraded Git-evidence warnings.' \
    '--add-dir is repeatable and grants Planner/Coder additional writable roots; Reviewer remains read-only without writable-root grants.' \
    'Use either --cwd or the positional PROJECT_DIR, not both.' \
    '' \
    'Optional per-run model overrides:' \
    '  PLANNER_MODEL=... CODER_MODEL=... REVIEWER_MODEL=... ./scripts/start.sh .' \
    '' \
    'Startup timeout override (milliseconds): HERDR_START_TIMEOUT_MS=...'
}

die() {
  printf '[FAIL] %s\n' "$*" >&2
  if [[ -n "${workspace_id:-}" ]]; then
    printf '       Partial workspace %s was left intact for diagnosis.\n' "$workspace_id" >&2
    printf '       Inspect it with: herdr workspace get %s\n' "$workspace_id" >&2
  fi
  exit 1
}

on_error() {
  local status=$?
  printf '[FAIL] Team startup stopped before completion.\n' >&2
  if [[ -n "$workspace_id" ]]; then
    printf '       Partial workspace %s was left intact for diagnosis.\n' "$workspace_id" >&2
    printf '       Inspect it with: herdr workspace get %s\n' "$workspace_id" >&2
  fi
  exit "$status"
}

finish_start_run() {
  local status=$?

  trap - EXIT ERR
  set +e
  if [[ ${RUN_STATE_ACTIVE:-0} -eq 1 && \
        "${RUN_STATE_FINAL_STATUS:-}" != ready ]]; then
    if ! run_state_write_current partial; then
      printf '[WARN] Could not persist the partial launch record at %s. Herdr remains the live authority.\n' \
        "${RUN_STATE_FILE:-unknown}" >&2
    fi
  fi
  if [[ ${RUN_STATE_LOCK_HELD:-0} -eq 1 ]] && ! run_state_release_start_lock; then
    printf '[FAIL] Team processes were left intact, but the startup lock could not be released safely: %s\n' \
      "${RUN_STATE_LOCK_DIR:-unknown}" >&2
    [[ $status -ne 0 ]] || status=1
  fi
  exit "$status"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-focus)
      NO_FOCUS=1
      shift
      ;;
    --team)
      [[ $# -ge 2 ]] || die '--team requires a prefix.'
      [[ $TEAM_CLI_SET -eq 0 ]] || die '--team may be provided only once.'
      TEAM_CLI_SET=1
      TEAM_CLI_PREFIX=$2
      shift 2
      ;;
    --team=*)
      [[ $TEAM_CLI_SET -eq 0 ]] || die '--team may be provided only once.'
      TEAM_CLI_SET=1
      TEAM_CLI_PREFIX=${1#--team=}
      shift
      ;;
    --cwd)
      [[ $# -ge 2 ]] || die '--cwd requires a project directory.'
      [[ $CWD_ARG_SET -eq 0 ]] || die '--cwd may be provided only once.'
      CWD_ARG_SET=1
      PROJECT_ARG=$2
      shift 2
      ;;
    --cwd=*)
      [[ $CWD_ARG_SET -eq 0 ]] || die '--cwd may be provided only once.'
      CWD_ARG_SET=1
      PROJECT_ARG=${1#--cwd=}
      shift
      ;;
    --add-dir)
      [[ $# -ge 2 ]] || die '--add-dir requires a directory.'
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
    --*)
      usage >&2
      die "Unknown option: $1"
      ;;
    *)
      [[ $PROJECT_POSITIONAL_SET -eq 0 ]] || die 'Only one positional PROJECT_DIR may be provided.'
      [[ $CWD_ARG_SET -eq 0 ]] || die 'Use either --cwd or positional PROJECT_DIR, not both.'
      PROJECT_POSITIONAL_SET=1
      PROJECT_ARG=$1
      shift
      ;;
  esac
done

if [[ $CWD_ARG_SET -eq 1 && $PROJECT_POSITIONAL_SET -eq 1 ]]; then
  die 'Use either --cwd or positional PROJECT_DIR, not both.'
fi
if [[ $CWD_ARG_SET -eq 1 && -z "$PROJECT_ARG" ]]; then
  die '--cwd requires a non-empty project directory.'
fi
if [[ $PROJECT_POSITIONAL_SET -eq 1 && -z "$PROJECT_ARG" ]]; then
  die 'Positional PROJECT_DIR must not be empty.'
fi
if ! REQUESTED_TEAM_PREFIX=$(team_resolve_requested_prefix "$TEAM_CLI_SET" "$TEAM_CLI_PREFIX"); then
  die 'Could not resolve a single non-empty team prefix.'
fi
if ! team_configure "$REQUESTED_TEAM_PREFIX"; then
  die "Invalid team prefix '$REQUESTED_TEAM_PREFIX'. It must match [a-z][a-z0-9_-]* and leave every generated Herdr name at 32 characters or fewer (maximum prefix length: 23)."
fi

PROJECT_ARG=${PROJECT_ARG:-"$PWD"}
[[ "$START_TIMEOUT_MS" =~ ^[1-9][0-9]*$ ]] || \
  die "HERDR_START_TIMEOUT_MS must be a positive integer: $START_TIMEOUT_MS"
(( ${#START_TIMEOUT_MS} <= 6 )) || \
  die "HERDR_START_TIMEOUT_MS exceeds the Herdr 0.8.2 maximum of 300000: $START_TIMEOUT_MS"
(( 10#$START_TIMEOUT_MS > 3000 )) || \
  die "HERDR_START_TIMEOUT_MS must be greater than the Herdr minimum of 3000: $START_TIMEOUT_MS"
(( 10#$START_TIMEOUT_MS <= 300000 )) || \
  die "HERDR_START_TIMEOUT_MS exceeds the Herdr 0.8.2 maximum of 300000: $START_TIMEOUT_MS"
scope_path_has_control "$PROJECT_ARG" && \
  die 'Project directory argument contains an unsupported control character.'
[[ -d "$PROJECT_ARG" ]] || die "Project directory does not exist: $PROJECT_ARG"
PROJECT_DIR=$(scope_physical_dir "$PROJECT_ARG") || \
  die 'Project directory cannot be resolved safely.'
[[ "$PROJECT_DIR" != '/' ]] || die 'Refusing to start workspace-write agents at the filesystem root.'

for add_dir_arg in ${ADD_DIR_ARGS[@]+"${ADD_DIR_ARGS[@]}"}; do
  [[ -n "$add_dir_arg" ]] || die '--add-dir requires a non-empty directory.'
  scope_path_has_control "$add_dir_arg" && \
    die 'Additional directory argument contains an unsupported control character.'
  [[ -d "$add_dir_arg" ]] || die "Additional directory does not exist or is not a directory: $add_dir_arg"
  add_dir=$(scope_physical_dir "$add_dir_arg") || \
    die 'Additional directory cannot be resolved safely.'
  [[ "$add_dir" != '/' ]] || die 'Refusing to grant an agent the filesystem root through --add-dir.'
  if scope_paths_overlap "$PROJECT_DIR" "$add_dir"; then
    die "Additional directory overlaps PROJECT_DIR; use disjoint roots: $add_dir"
  fi
  for existing_add_dir in ${ADD_DIRS[@]+"${ADD_DIRS[@]}"}; do
    if scope_paths_overlap "$existing_add_dir" "$add_dir"; then
      die "Additional directories overlap or resolve to the same physical path: $existing_add_dir and $add_dir"
    fi
  done
  ADD_DIRS+=("$add_dir")
done

REQUESTED_DIRS+=("$PROJECT_DIR")
for add_dir in ${ADD_DIRS[@]+"${ADD_DIRS[@]}"}; do
  REQUESTED_DIRS+=("$add_dir")
done
for requested_dir in "${REQUESTED_DIRS[@]}"; do
  if requested_git_root=$(scope_git_root "$requested_dir"); then
    requested_scope_root=$requested_git_root
  else
    git_scope_status=$?
    if [[ $git_scope_status -eq 1 ]]; then
      requested_scope_root=$requested_dir
      REQUESTED_HAS_NON_GIT=1
    else
      die "Could not safely inspect Git scope for a requested directory: $requested_dir"
    fi
  fi
  for existing_scope_root in ${REQUESTED_SCOPE_ROOTS[@]+"${REQUESTED_SCOPE_ROOTS[@]}"}; do
    if scope_paths_overlap "$existing_scope_root" "$requested_scope_root"; then
      die "Requested directories share or overlap one effective Git/filesystem scope: $existing_scope_root and $requested_scope_root"
    fi
  done
  REQUESTED_SCOPE_ROOTS+=("$requested_scope_root")
done

if [[ $REQUESTED_HAS_NON_GIT -eq 1 ]]; then
  printf '[WARN] Requested scope includes one or more non-Git directories. Git status/diff, rollback, and pre-existing-change attribution are unavailable for those roots.\n' >&2
  printf '[WARN] Live full/policy tests still require a separate clean committed Git host; do not report them as passing for these roots.\n' >&2
fi

command -v codex >/dev/null 2>&1 || die 'Codex CLI was not found in PATH.'
command -v herdr >/dev/null 2>&1 || die 'Herdr was not found in PATH.'
if [[ ${#ADD_DIRS[@]} -gt 0 ]]; then
  codex_help=$(codex --help 2>&1) || \
    die 'Could not inspect the Codex CLI command surface.'
  grep -Fq -- '--add-dir' <<<"$codex_help" || \
    die 'This Codex CLI does not expose --add-dir. Upgrade Codex before using multi-root mode.'
fi
JSON_BACKEND=$(json_backend_name) || \
  die 'A real JSON parser is required: install jq or make python3 available.'

for role in planner coder reviewer; do
  case "$role" in
    planner) model=${PLANNER_MODEL:-} ;;
    coder) model=${CODER_MODEL:-} ;;
    reviewer) model=${REVIEWER_MODEL:-} ;;
  esac
  if [[ -n "$model" && ! "$model" =~ ^[A-Za-z0-9._:/-]+$ ]]; then
    die "$role model contains unsupported characters: $model"
  fi
done

for role in planner coder reviewer; do
  [[ -f "$CODEX_DIR/$role.config.toml" ]] || \
    die "Missing $CODEX_DIR/$role.config.toml. Run $SCRIPT_DIR/install.sh first."
  if ! prompt_integrity_error=$(profile_prompt_integrity \
       "$CODEX_DIR/$role.config.toml" "$PROJECT_ROOT/prompts/$role.md" 2>&1); then
    die "$role $prompt_integrity_error. Rerun $SCRIPT_DIR/install.sh before starting a team."
  fi
  grep -Eq '^approval_policy[[:space:]]*=[[:space:]]*"never"[[:space:]]*$' \
    "$CODEX_DIR/$role.config.toml" || \
    die "$role profile must use approval_policy = \"never\". Rerun $SCRIPT_DIR/install.sh."
  case "$role" in
    planner|coder) expected_sandbox=workspace-write ;;
    reviewer) expected_sandbox=read-only ;;
  esac
  grep -Eq '^sandbox_mode[[:space:]]*=[[:space:]]*"'"$expected_sandbox"'"[[:space:]]*$' \
    "$CODEX_DIR/$role.config.toml" || \
    die "$role profile must use sandbox_mode = \"$expected_sandbox\". Rerun $SCRIPT_DIR/install.sh."
  if ! policy_integrity_error=$(profile_policy_integrity \
       "$CODEX_DIR/$role.config.toml" "$PROJECT_ROOT/profiles/$role.config.toml" 2>&1); then
    die "$role $policy_integrity_error. Rerun $SCRIPT_DIR/install.sh before starting a team."
  fi
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
  codex "${validation_args[@]}" debug prompt-input 'profile validation' >/dev/null 2>&1 || \
    die "Codex cannot load $CODEX_DIR/$role.config.toml. Restore a backup or rerun $SCRIPT_DIR/install.sh."
done

herdr agent start --help >/dev/null 2>&1 || \
  die 'Herdr does not expose `agent start` with the expected command surface.'
herdr agent prompt --help >/dev/null 2>&1 || \
  die 'Herdr does not expose `agent prompt` with the expected command surface.'
herdr agent get --help >/dev/null 2>&1 || \
  die 'Herdr does not expose `agent get` with the expected command surface.'
herdr pane process-info --help >/dev/null 2>&1 || \
  die 'Herdr does not expose `pane process-info`, required for managed workspace-scope verification.'
herdr pane split --help >/dev/null 2>&1 || \
  die 'Herdr does not expose `pane split` with the expected command surface.'
herdr pane rename --help >/dev/null 2>&1 || \
  die 'Herdr does not expose `pane rename` with the expected command surface.'
herdr workspace create --help >/dev/null 2>&1 || \
  die 'Herdr does not expose `workspace create` with the expected command surface.'
if [[ $NO_FOCUS -eq 0 ]]; then
  herdr workspace focus --help >/dev/null 2>&1 || \
    die 'Herdr does not expose `workspace focus` with the expected command surface.'
  herdr agent focus --help >/dev/null 2>&1 || \
    die 'Herdr does not expose `agent focus` with the expected command surface.'
fi

integration_status=$(herdr integration status 2>&1 || true)
printf '%s\n' "$integration_status" | grep -Eq '^codex: current([[:space:]]|$)' || \
  die 'Herdr Codex integration is not current. Review `herdr integration status` and `herdr integration install codex`.'

if ! server_status=$(herdr status server 2>&1); then
  printf '%s\n' "$server_status" >&2
  die 'Herdr server is not reachable. Start or attach Herdr with `herdr` first.'
fi

RUN_ID=$(run_state_new_id) || die 'Could not generate a launch run ID.'
RUN_STARTED_AT=$(run_state_now) || die 'Could not timestamp the launch run.'
run_state_configure "$CODEX_DIR" "$TEAM_MODE" "$TEAM_PREFIX_EFFECTIVE" || \
  die 'Could not derive a safe user-local launch-state path.'
run_state_validate_launch_strings \
  "$CODEX_DIR" "$TEAM_MODE" "$TEAM_PREFIX_EFFECTIVE" "$TEAM_DISPLAY" \
  "$PROJECT_DIR" ${ADD_DIRS[@]+"${ADD_DIRS[@]}"} || \
  die 'Launch-state inputs must round-trip as valid UTF-8 before Herdr workspace creation.'
run_state_prepare_storage || \
  die "Could not prepare private launch-state storage under $RUN_STATE_BASE_DIR."
run_state_acquire_start_lock "$RUN_ID" || \
  die 'Another managed startup is active or its lock cannot be verified safely.'
trap finish_start_run EXIT

if ! agent_list_payload=$(herdr agent list 2>&1); then
  printf '%s\n' "$agent_list_payload" >&2
  die 'Could not verify live Herdr names before startup; refusing to assume names are free.'
fi
if ! live_agent_names=$(json_agent_names "$agent_list_payload"); then
  die "Could not parse the Herdr agent-list preflight with $JSON_BACKEND; refusing to create a workspace."
fi
for role in planner coder reviewer; do
  live_name=$(team_agent_for_role "$role")
  if printf '%s\n' "$live_agent_names" | grep -Fxq -- "$live_name"; then
    die "agent_name_taken: a live Herdr agent already uses '$live_name'. Startup did not create or alter a workspace. Reuse that team or close it explicitly before retrying."
  fi
done

# A second Herdr team may use different live names while still covering one of
# the same primary/additional roots. Refuse that setup before workspace
# creation. Git-backed paths compare at their physical worktree root; non-Git
# paths compare at their physical directory root.
if [[ $REQUESTED_HAS_NON_GIT -eq 1 ]]; then
  scope_conflict_tag='shared_workspace_scope'
else
  scope_conflict_tag='shared_git_worktree'
fi
while IFS= read -r candidate_name; do
  [[ -n "$candidate_name" ]] || continue
  if ! team_role_from_live_name "$candidate_name" >/dev/null; then
    continue
  fi
  if [[ "$candidate_name" == "$PLANNER_AGENT" || \
        "$candidate_name" == "$CODER_AGENT" || \
        "$candidate_name" == "$REVIEWER_AGENT" ]]; then
    # Exact names were handled above; keep this guard for defensive clarity.
    continue
  fi
  if ! candidate_payload=$(herdr agent get "$candidate_name" 2>&1); then
    printf '%s\n' "$candidate_payload" >&2
    die "${scope_conflict_tag}_unverified: could not inspect live Herdr role agent '$candidate_name'; refusing to assume its workspace scope is different."
  fi
  if ! candidate_kind=$(json_agent_required_string "$candidate_payload" agent) || \
     ! candidate_reported_name=$(json_agent_required_string "$candidate_payload" name) || \
     ! candidate_pane_id=$(json_agent_required_string "$candidate_payload" pane_id) || \
     ! candidate_cwd=$(json_agent_optional_string "$candidate_payload" cwd) || \
     ! candidate_foreground_cwd=$(json_agent_optional_string "$candidate_payload" foreground_cwd); then
    die "${scope_conflict_tag}_unverified: malformed identity, pane ID, or cwd for live Herdr role agent '$candidate_name'."
  fi
  [[ "$candidate_reported_name" == "$candidate_name" ]] || \
    die "${scope_conflict_tag}_unverified: lookup for '$candidate_name' resolved to '${candidate_reported_name:-unknown}'."
  [[ -n "$candidate_kind" ]] || \
    die "${scope_conflict_tag}_unverified: live Herdr role agent '$candidate_name' did not expose its agent kind."
  [[ "$candidate_kind" == codex ]] || continue

  candidate_role=$(team_role_from_live_name "$candidate_name") || \
    die "${scope_conflict_tag}_unverified: could not derive the role for live Herdr agent '$candidate_name'."
  case "$candidate_role" in
    planner|coder) candidate_expected_sandbox=workspace-write ;;
    reviewer) candidate_expected_sandbox=read-only ;;
  esac
  if ! candidate_process_payload=$(herdr pane process-info --pane "$candidate_pane_id" 2>&1); then
    printf '%s\n' "$candidate_process_payload" >&2
    die "${scope_conflict_tag}_unverified: could not inspect the process argv for live Herdr role agent '$candidate_name'."
  fi
  json_process_uses_profile "$candidate_process_payload" "$candidate_role" || \
    die "${scope_conflict_tag}_unverified: '$candidate_name' is not verifiably using generic --profile $candidate_role."
  json_process_has_managed_scope "$candidate_process_payload" "$candidate_expected_sandbox" || \
    die "${scope_conflict_tag}_unverified: '$candidate_name' lacks the managed writable-roots override. Restart older teams with this start.sh before retrying."
  if ! candidate_add_dirs=$(json_process_codex_add_dirs "$candidate_process_payload"); then
    die "${scope_conflict_tag}_unverified: '$candidate_name' exposes malformed or unstructured --add-dir arguments."
  fi

  CANDIDATE_DIRS=()
  CANDIDATE_SCOPE_ROOTS=()
  candidate_cwd_count=0
  for candidate_path in "$candidate_cwd" "$candidate_foreground_cwd"; do
    [[ -n "$candidate_path" ]] || continue
    candidate_cwd_count=$((candidate_cwd_count + 1))
    scope_path_has_control "$candidate_path" && \
      die "${scope_conflict_tag}_unverified: Codex role agent '$candidate_name' reported a cwd with unsupported control characters."
    [[ -d "$candidate_path" ]] || \
      die "${scope_conflict_tag}_unverified: Codex role agent '$candidate_name' reported a cwd that cannot be inspected: $candidate_path"
    candidate_path=$(scope_physical_dir "$candidate_path") || \
      die "${scope_conflict_tag}_unverified: Codex role agent '$candidate_name' reported an unsafe cwd."
    [[ "$candidate_path" != '/' ]] || \
      die "${scope_conflict_tag}: live Herdr role agent '$candidate_name' has filesystem-root cwd and can cover every requested root. Refusing unsafe overlap."
    CANDIDATE_DIRS+=("$candidate_path")
  done
  (( candidate_cwd_count > 0 )) || \
    die "${scope_conflict_tag}_unverified: Codex role agent '$candidate_name' has no inspectable cwd."

  while IFS= read -r candidate_add_dir; do
    [[ -n "$candidate_add_dir" ]] || continue
    [[ -d "$candidate_add_dir" ]] || \
      die "${scope_conflict_tag}_unverified: '$candidate_name' declared an additional directory that cannot be inspected: $candidate_add_dir"
    candidate_add_dir=$(scope_physical_dir "$candidate_add_dir") || \
      die "${scope_conflict_tag}_unverified: '$candidate_name' declared an unsafe additional directory."
    [[ "$candidate_add_dir" != '/' ]] || \
      die "${scope_conflict_tag}: '$candidate_name' declared the filesystem root through --add-dir."
    CANDIDATE_DIRS+=("$candidate_add_dir")
  done <<<"$candidate_add_dirs"

  for candidate_path in "${CANDIDATE_DIRS[@]}"; do
    candidate_scope_root=$(scope_effective_root "$candidate_path") || \
      die "${scope_conflict_tag}_unverified: could not safely inspect Git scope for '$candidate_name'."
    candidate_scope_seen=0
    for existing_candidate_scope in ${CANDIDATE_SCOPE_ROOTS[@]+"${CANDIDATE_SCOPE_ROOTS[@]}"}; do
      if [[ "$existing_candidate_scope" == "$candidate_scope_root" ]]; then
        candidate_scope_seen=1
        break
      fi
    done
    [[ $candidate_scope_seen -eq 1 ]] || CANDIDATE_SCOPE_ROOTS+=("$candidate_scope_root")
  done

  for requested_scope_root in "${REQUESTED_SCOPE_ROOTS[@]}"; do
    for candidate_scope_root in "${CANDIDATE_SCOPE_ROOTS[@]}"; do
      if scope_paths_overlap "$requested_scope_root" "$candidate_scope_root"; then
        die "${scope_conflict_tag}: live Herdr role agent '$candidate_name' covers '$candidate_scope_root', which overlaps requested scope '$requested_scope_root'. Reuse or explicitly close that team before retrying."
      fi
    done
  done
done <<<"$live_agent_names"

extract_object_string() {
  local payload=$1
  local object_name=$2
  local field_name=$3

  json_object_string "$payload" "$object_name" "$field_name" || true
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

print_doctor_command() {
  printf '%s/doctor.sh' "$SCRIPT_DIR"
  if [[ "$TEAM_MODE" == prefixed ]]; then
    printf ' --team %q' "$TEAM_DISPLAY"
  fi
  printf ' --cwd %q' "$PROJECT_DIR"
  for print_add_dir in ${ADD_DIRS[@]+"${ADD_DIRS[@]}"}; do
    printf ' --add-dir %q' "$print_add_dir"
  done
  printf '\n'
}

project_name=${PROJECT_DIR##*/}
[[ -n "$project_name" ]] || project_name='project'
workspace_label="codex-team:$project_name"
if [[ "$TEAM_MODE" == prefixed ]]; then
  workspace_label="codex-team:$TEAM_DISPLAY"
fi

printf 'Creating Herdr workspace for team %s in %s\n' "$TEAM_DISPLAY" "$PROJECT_DIR"
trap on_error ERR
create_payload=$(herdr workspace create \
  --cwd "$PROJECT_DIR" \
  --label "$workspace_label" \
  --env "CODEX_HOME=$CODEX_DIR" \
  --no-focus)
workspace_id=$(extract_object_string "$create_payload" workspace workspace_id)
root_pane_id=$(extract_object_string "$create_payload" root_pane pane_id)
[[ -n "$workspace_id" ]] || die "Could not parse workspace ID from Herdr response: $create_payload"
RUN_STATE_ACTIVE=1
[[ -n "$root_pane_id" ]] || die "Could not parse root pane ID from Herdr response: $create_payload"
run_state_write_current starting || \
  die "Workspace $workspace_id was created, but its launch record could not be written atomically at $RUN_STATE_FILE. Do not retry startup until the retained workspace is inspected."

coder_split=$(herdr pane split "$root_pane_id" \
  --direction right --ratio 0.5 --cwd "$PROJECT_DIR" \
  --env "CODEX_HOME=$CODEX_DIR" --no-focus)
coder_pane_id=$(extract_object_string "$coder_split" pane pane_id)
[[ -n "$coder_pane_id" ]] || die "Could not parse coder pane ID from Herdr response: $coder_split"

reviewer_split=$(herdr pane split "$coder_pane_id" \
  --direction down --ratio 0.5 --cwd "$PROJECT_DIR" \
  --env "CODEX_HOME=$CODEX_DIR" --no-focus)
reviewer_pane_id=$(extract_object_string "$reviewer_split" pane pane_id)
[[ -n "$reviewer_pane_id" ]] || die "Could not parse reviewer pane ID from Herdr response: $reviewer_split"

herdr pane rename "$root_pane_id" "$PLANNER_AGENT" >/dev/null
herdr pane rename "$coder_pane_id" "$CODER_AGENT" >/dev/null
herdr pane rename "$reviewer_pane_id" "$REVIEWER_AGENT" >/dev/null

start_agent() {
  local role=$1
  local live_name=$2
  local pane_id=$3
  local model=$4
  local expected_sandbox
  local add_dir
  local native_args
  local start_result

  case "$role" in
    planner|coder) expected_sandbox=workspace-write ;;
    reviewer) expected_sandbox=read-only ;;
    *) die "Unknown role passed to start_agent: $role" ;;
  esac
  native_args=(
    --profile "$role"
    -c 'sandbox_workspace_write.writable_roots=[]'
    --sandbox "$expected_sandbox"
  )

  if [[ "$role" != reviewer ]]; then
    for add_dir in ${ADD_DIRS[@]+"${ADD_DIRS[@]}"}; do
      native_args+=(--add-dir "$add_dir")
    done
  fi

  if [[ -n "$model" ]]; then
    native_args+=(--model "$model")
  fi

  printf 'Starting %s profile as live agent %s in %s\n' "$role" "$live_name" "$pane_id"
  if start_result=$(herdr agent start "$live_name" --kind codex --pane "$pane_id" \
      --timeout "$START_TIMEOUT_MS" -- "${native_args[@]}" 2>&1); then
    printf '%s\n' "$start_result"
    return 0
  fi

  startup_issues=$((startup_issues + 1))
  printf '[FAIL] %s (%s) was not confirmed ready.\n' "$role" "$live_name" >&2
  printf '%s\n' "$start_result" >&2
  if herdr agent get "$live_name" >/dev/null 2>&1; then
    printf '       Herdr retained the process/name. Inspect it with:\n' >&2
    printf '       herdr agent get %s\n' "$live_name" >&2
    printf '       herdr agent read %s --source recent-unwrapped --lines 120\n' "$live_name" >&2
  else
    printf '       No live name was retained. After repairing the pane, retry exactly:\n' >&2
    printf '       herdr agent start %q --kind codex --pane %q --timeout %q -- --profile %q' \
      "$live_name" "$pane_id" "$START_TIMEOUT_MS" "$role" >&2
    printf ' -c %q --sandbox %q' \
      'sandbox_workspace_write.writable_roots=[]' "$expected_sandbox" >&2
    if [[ "$role" != reviewer ]]; then
      for add_dir in ${ADD_DIRS[@]+"${ADD_DIRS[@]}"}; do
        printf ' --add-dir %q' "$add_dir" >&2
      done
    fi
    if [[ -n "$model" ]]; then
      printf ' --model %s' "$model" >&2
    fi
    printf '\n' >&2
  fi
  return 1
}

# Start workers first so Planner can immediately resolve both live names.
start_agent coder "$CODER_AGENT" "$coder_pane_id" "${CODER_MODEL:-}"
start_agent reviewer "$REVIEWER_AGENT" "$reviewer_pane_id" "${REVIEWER_MODEL:-}"
start_agent planner "$PLANNER_AGENT" "$root_pane_id" "${PLANNER_MODEL:-}"

# Every start command succeeded. Recheck the complete live identity before
# declaring the team ready; any mismatch leaves the partial workspace intact.
startup_issues=0
for role in planner coder reviewer; do
  live_name_expected=$(team_agent_for_role "$role")
  case "$role" in
    planner) pane_expected=$root_pane_id; expected_sandbox=workspace-write ;;
    coder) pane_expected=$coder_pane_id; expected_sandbox=workspace-write ;;
    reviewer) pane_expected=$reviewer_pane_id; expected_sandbox=read-only ;;
  esac
  if agent_payload=$(herdr agent get "$live_name_expected" 2>&1); then
    live_name=''
    agent_kind=''
    agent_status=''
    interactive_ready=''
    launch_pending=''
    live_pane_id=''
    live_workspace_id=''
    identity_fields_ready=false
    if live_name=$(json_agent_required_string "$agent_payload" name) && \
       agent_kind=$(json_agent_required_string "$agent_payload" agent) && \
       agent_status=$(json_agent_required_string "$agent_payload" agent_status) && \
       interactive_ready=$(json_agent_required_boolean "$agent_payload" interactive_ready) && \
       launch_pending=$(json_agent_required_boolean "$agent_payload" launch_pending) && \
       live_pane_id=$(json_agent_required_string "$agent_payload" pane_id) && \
       live_workspace_id=$(json_agent_required_string "$agent_payload" workspace_id); then
      identity_fields_ready=true
    fi
    primary_scope_ready=false
    if live_cwd=$(json_agent_optional_string "$agent_payload" cwd) && \
       live_foreground_cwd=$(json_agent_optional_string "$agent_payload" foreground_cwd); then
      primary_cwd_count=0
      primary_cwd_mismatch=0
      for live_primary_path in "$live_cwd" "$live_foreground_cwd"; do
        [[ -n "$live_primary_path" ]] || continue
        primary_cwd_count=$((primary_cwd_count + 1))
        if [[ ! -d "$live_primary_path" ]] || \
           ! live_primary_path=$(scope_physical_dir "$live_primary_path") || \
           [[ "$live_primary_path" != "$PROJECT_DIR" ]]; then
          primary_cwd_mismatch=1
        fi
      done
      if (( primary_cwd_count > 0 && primary_cwd_mismatch == 0 )); then
        primary_scope_ready=true
      fi
    fi
    process_scope_ready=false
    if [[ -n "$live_pane_id" ]] && \
       process_payload=$(herdr pane process-info --pane "$live_pane_id" 2>&1) && \
       json_process_uses_profile "$process_payload" "$role" && \
       json_process_has_managed_scope "$process_payload" "$expected_sandbox" && \
       process_add_dirs_match "$process_payload" "$role"; then
      process_scope_ready=true
    fi
    if [[ "$identity_fields_ready" == 'true' && \
          "$live_name" == "$live_name_expected" && "$agent_kind" == 'codex' && \
          "$live_pane_id" == "$pane_expected" && "$live_workspace_id" == "$workspace_id" && \
          "$interactive_ready" == 'true' && "$launch_pending" == 'false' && \
          "$primary_scope_ready" == 'true' && \
          "$process_scope_ready" == 'true' && \
          ( "$agent_status" == 'idle' || "$agent_status" == 'done' ) ]]; then
      printf '[OK] %s ready as %s (state: %s)\n' "$role" "$live_name_expected" "$agent_status"
      continue
    fi
    printf '[FAIL] %s final state is not ready (expected_name=%s, name=%s, kind=%s, pane=%s, workspace=%s, state=%s, ready=%s, launch_pending=%s, primary_scope=%s, managed_scope=%s).\n' \
      "$role" "$live_name_expected" "${live_name:-unknown}" "${agent_kind:-unknown}" \
      "${live_pane_id:-unknown}" "${live_workspace_id:-unknown}" "${agent_status:-unknown}" \
      "${interactive_ready:-unknown}" "${launch_pending:-unknown}" \
      "$primary_scope_ready" "$process_scope_ready" >&2
  else
    printf '[FAIL] %s has no live Herdr agent after startup.\n' "$live_name_expected" >&2
  fi
  startup_issues=$((startup_issues + 1))
  [[ -n "$first_issue_role" ]] || first_issue_role=$live_name_expected
done

if [[ $startup_issues -gt 0 ]]; then
  trap - ERR
  printf '\nSTART_PARTIAL\n\n'
  printf '[FAIL] Workspace %s is only partially ready (%s role issue(s)).\n' \
    "$workspace_id" "$startup_issues" >&2
  printf '       Planner pane:  %s\n' "$root_pane_id" >&2
  printf '       Coder pane:    %s\n' "$coder_pane_id" >&2
  printf '       Reviewer pane: %s\n' "$reviewer_pane_id" >&2
  printf '       Startup stopped at the first failed or mismatched role. Resolve retained agents or use the printed exact retry; no existing names were reused or renamed.\n' >&2
  printf '       Then run: ' >&2
  print_doctor_command >&2
  if [[ $NO_FOCUS -eq 0 && -n "$first_issue_role" ]] && \
     herdr agent get "$first_issue_role" >/dev/null 2>&1; then
    herdr workspace focus "$workspace_id" >/dev/null 2>&1 || true
    herdr agent focus "$first_issue_role" >/dev/null 2>&1 || true
  fi
  exit 1
fi

run_state_write_current ready || \
  die "All three agents are ready, but the final launch record could not be written atomically at $RUN_STATE_FILE. Do not rerun startup; inspect the live team directly."
RUN_STATE_FINAL_STATUS=ready

if [[ $NO_FOCUS -eq 0 ]]; then
  herdr workspace focus "$workspace_id" >/dev/null
  herdr agent focus "$PLANNER_AGENT" >/dev/null
fi

trap - ERR
printf '\n[OK] Three-agent team started.\n'
printf 'Team:      %s\n' "$TEAM_DISPLAY"
printf 'Workspace: %s\n' "$workspace_id"
printf 'Planner:   %s (%s)\n' "$PLANNER_AGENT" "$root_pane_id"
printf 'Coder:     %s (%s)\n' "$CODER_AGENT" "$coder_pane_id"
printf 'Reviewer:  %s (%s)\n' "$REVIEWER_AGENT" "$reviewer_pane_id"
printf 'Primary:   %s\n' "$PROJECT_DIR"
for add_dir in ${ADD_DIRS[@]+"${ADD_DIRS[@]}"}; do
  printf 'Add dir:   %s\n' "$add_dir"
done
printf 'Run state: %s (%s)\n' "$RUN_STATE_FILE" "$RUN_ID"
printf '\nVerify with: '
print_doctor_command
