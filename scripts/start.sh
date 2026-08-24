#!/usr/bin/env bash

set -Eeuo pipefail

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
NO_FOCUS=0
PROJECT_ARG=''
PROJECT_POSITIONAL_SET=0
CWD_ARG_SET=0
TEAM_CLI_SET=0
TEAM_CLI_PREFIX=''
workspace_id=''
START_TIMEOUT_MS=${HERDR_START_TIMEOUT_MS:-120000}
startup_issues=0
first_issue_role=''

usage() {
  printf '%s\n' \
    'Usage: ./scripts/start.sh [--no-focus] [--team PREFIX] [--cwd PROJECT_DIR] [PROJECT_DIR]' \
    '' \
    'Creates one Herdr workspace with three live agents.' \
    'Without --team or TEAM_PREFIX: planner, coder, reviewer (legacy mode).' \
    'With --team github: github-planner, github-coder, github-reviewer.' \
    'TEAM_PREFIX may supply the prefix when --team is omitted.' \
    'PROJECT_DIR defaults to the current directory and must be inside a Git worktree.' \
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
[[ -d "$PROJECT_ARG" ]] || die "Project directory does not exist: $PROJECT_ARG"
PROJECT_DIR=$(CDPATH= cd -- "$PROJECT_ARG" && pwd -P)
[[ "$PROJECT_DIR" != '/' ]] || die 'Refusing to start workspace-write agents at the filesystem root.'
git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || \
  die "PROJECT_DIR is not inside a Git worktree: $PROJECT_DIR"

command -v codex >/dev/null 2>&1 || die 'Codex CLI was not found in PATH.'
command -v herdr >/dev/null 2>&1 || die 'Herdr was not found in PATH.'
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
  codex --profile "$role" debug prompt-input 'profile validation' >/dev/null 2>&1 || \
    die "Codex cannot load $CODEX_DIR/$role.config.toml. Restore a backup or rerun $SCRIPT_DIR/install.sh."
done

herdr agent start --help >/dev/null 2>&1 || \
  die 'Herdr does not expose `agent start` with the expected command surface.'
herdr agent prompt --help >/dev/null 2>&1 || \
  die 'Herdr does not expose `agent prompt` with the expected command surface.'
herdr agent get --help >/dev/null 2>&1 || \
  die 'Herdr does not expose `agent get` with the expected command surface.'
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

extract_object_string() {
  local payload=$1
  local object_name=$2
  local field_name=$3

  json_object_string "$payload" "$object_name" "$field_name" || true
}

extract_agent_field() {
  local payload=$1
  local field=$2

  json_agent_field "$payload" "$field" || true
}

project_name=${PROJECT_DIR##*/}
[[ -n "$project_name" ]] || project_name='project'
workspace_label="codex-team:$project_name"
if [[ "$TEAM_MODE" == prefixed ]]; then
  workspace_label="codex-team:$TEAM_DISPLAY:$project_name"
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
[[ -n "$root_pane_id" ]] || die "Could not parse root pane ID from Herdr response: $create_payload"

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
  local native_args=(--profile "$role")
  local start_result

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
    printf '       herdr agent start %s --kind codex --pane %s --timeout %s -- --profile %s' \
      "$live_name" "$pane_id" "$START_TIMEOUT_MS" "$role" >&2
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
    planner) pane_expected=$root_pane_id ;;
    coder) pane_expected=$coder_pane_id ;;
    reviewer) pane_expected=$reviewer_pane_id ;;
  esac
  if agent_payload=$(herdr agent get "$live_name_expected" 2>&1); then
    live_name=$(extract_agent_field "$agent_payload" name)
    agent_kind=$(extract_agent_field "$agent_payload" agent)
    agent_status=$(extract_agent_field "$agent_payload" agent_status)
    interactive_ready=$(extract_agent_field "$agent_payload" interactive_ready)
    launch_pending=$(extract_agent_field "$agent_payload" launch_pending)
    live_pane_id=$(extract_agent_field "$agent_payload" pane_id)
    live_workspace_id=$(extract_agent_field "$agent_payload" workspace_id)
    if [[ "$live_name" == "$live_name_expected" && "$agent_kind" == 'codex' && \
          "$live_pane_id" == "$pane_expected" && "$live_workspace_id" == "$workspace_id" && \
          "$interactive_ready" == 'true' && "$launch_pending" != 'true' && \
          ( "$agent_status" == 'idle' || "$agent_status" == 'done' ) ]]; then
      printf '[OK] %s ready as %s (state: %s)\n' "$role" "$live_name_expected" "$agent_status"
      continue
    fi
    printf '[FAIL] %s final state is not ready (expected_name=%s, name=%s, kind=%s, pane=%s, workspace=%s, state=%s, ready=%s, launch_pending=%s).\n' \
      "$role" "$live_name_expected" "${live_name:-unknown}" "${agent_kind:-unknown}" \
      "${live_pane_id:-unknown}" "${live_workspace_id:-unknown}" "${agent_status:-unknown}" \
      "${interactive_ready:-unknown}" "${launch_pending:-unknown}" >&2
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
  if [[ "$TEAM_MODE" == prefixed ]]; then
    printf '       Then run: %s/doctor.sh --team %s --cwd %s\n' "$SCRIPT_DIR" "$TEAM_DISPLAY" "$PROJECT_DIR" >&2
  else
    printf '       Then run: %s/doctor.sh --cwd %s\n' "$SCRIPT_DIR" "$PROJECT_DIR" >&2
  fi
  if [[ $NO_FOCUS -eq 0 && -n "$first_issue_role" ]] && \
     herdr agent get "$first_issue_role" >/dev/null 2>&1; then
    herdr workspace focus "$workspace_id" >/dev/null 2>&1 || true
    herdr agent focus "$first_issue_role" >/dev/null 2>&1 || true
  fi
  exit 1
fi

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
if [[ "$TEAM_MODE" == prefixed ]]; then
  printf '\nVerify with: %s/doctor.sh --team %s --cwd %s\n' "$SCRIPT_DIR" "$TEAM_DISPLAY" "$PROJECT_DIR"
else
  printf '\nVerify with: %s/doctor.sh --cwd %s\n' "$SCRIPT_DIR" "$PROJECT_DIR"
fi
