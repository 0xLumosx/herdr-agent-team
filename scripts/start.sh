#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
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
workspace_id=''
START_TIMEOUT_MS=${HERDR_START_TIMEOUT_MS:-120000}
startup_issues=0
first_issue_role=''

usage() {
  printf '%s\n' \
    'Usage: ./scripts/start.sh [--no-focus] [PROJECT_DIR]' \
    '' \
    'Creates one Herdr workspace with named planner, coder, and reviewer agents.' \
    'PROJECT_DIR defaults to the current directory and must be inside a Git worktree.' \
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
trap on_error ERR

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-focus)
      NO_FOCUS=1
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
      [[ -z "$PROJECT_ARG" ]] || die 'Only one PROJECT_DIR may be provided.'
      PROJECT_ARG=$1
      shift
      ;;
  esac
done

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

for role in planner coder reviewer; do
  if herdr agent get "$role" >/dev/null 2>&1; then
    die "A live Herdr agent already uses the name '$role'. Reuse that team or close it explicitly before starting another."
  fi
done

extract_object_string() {
  local payload=$1
  local object_name=$2
  local field_name=$3

  if command -v jq >/dev/null 2>&1; then
    case "$object_name.$field_name" in
      workspace.workspace_id)
        printf '%s\n' "$payload" | jq -er '.result.workspace.workspace_id' 2>/dev/null || true
        ;;
      root_pane.pane_id)
        printf '%s\n' "$payload" | jq -er '.result.root_pane.pane_id' 2>/dev/null || true
        ;;
      pane.pane_id)
        printf '%s\n' "$payload" | jq -er '.result.pane.pane_id' 2>/dev/null || true
        ;;
    esac
    return
  fi

  printf '%s\n' "$payload" | tr '\n' ' ' | sed -n \
    's/.*"'"$object_name"'"[[:space:]]*:[[:space:]]*{[^}]*"'"$field_name"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

extract_agent_field() {
  local payload=$1
  local field=$2
  local compact
  local value

  if command -v jq >/dev/null 2>&1; then
    printf '%s\n' "$payload" | jq -r --arg field "$field" \
      '.result.agent[$field] // empty' 2>/dev/null || true
    return
  fi

  compact=$(printf '%s\n' "$payload" | tr '\n' ' ')
  value=$(printf '%s\n' "$compact" | sed -n \
    's/.*"'"$field"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  if [[ -z "$value" ]]; then
    value=$(printf '%s\n' "$compact" | sed -n \
      's/.*"'"$field"'"[[:space:]]*:[[:space:]]*\([A-Za-z0-9._-]*\).*/\1/p')
  fi
  printf '%s' "$value"
}

project_name=${PROJECT_DIR##*/}
[[ -n "$project_name" ]] || project_name='project'
workspace_label="codex-team:$project_name"

printf 'Creating Herdr workspace for %s\n' "$PROJECT_DIR"
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

herdr pane rename "$root_pane_id" planner >/dev/null
herdr pane rename "$coder_pane_id" coder >/dev/null
herdr pane rename "$reviewer_pane_id" reviewer >/dev/null

start_agent() {
  local role=$1
  local pane_id=$2
  local model=$3
  local native_args=(--profile "$role")
  local start_result

  if [[ -n "$model" ]]; then
    native_args+=(--model "$model")
  fi

  printf 'Starting %s in %s\n' "$role" "$pane_id"
  if start_result=$(herdr agent start "$role" --kind codex --pane "$pane_id" \
      --timeout "$START_TIMEOUT_MS" -- "${native_args[@]}" 2>&1); then
    printf '%s\n' "$start_result"
    return 0
  fi

  startup_issues=$((startup_issues + 1))
  printf '[FAIL] %s was not confirmed ready.\n' "$role" >&2
  printf '%s\n' "$start_result" >&2
  if herdr agent get "$role" >/dev/null 2>&1; then
    printf '       Herdr retained the process/name. Inspect it with:\n' >&2
    printf '       herdr agent get %s\n' "$role" >&2
    printf '       herdr agent read %s --source recent-unwrapped --lines 120\n' "$role" >&2
  else
    printf '       No live name was retained. After repairing the pane, retry exactly:\n' >&2
    printf '       herdr agent start %s --kind codex --pane %s --timeout %s -- --profile %s' \
      "$role" "$pane_id" "$START_TIMEOUT_MS" "$role" >&2
    if [[ -n "$model" ]]; then
      printf ' --model %s' "$model" >&2
    fi
    printf '\n' >&2
  fi
  return 0
}

# Start workers first so Planner can immediately resolve both live names.
start_agent coder "$coder_pane_id" "${CODER_MODEL:-}"
start_agent reviewer "$reviewer_pane_id" "${REVIEWER_MODEL:-}"
start_agent planner "$root_pane_id" "${PLANNER_MODEL:-}"

# A nonzero `agent start` can leave a usable name behind. Current live state,
# not the command's earlier exit status, is the final startup authority.
startup_issues=0
for role in planner coder reviewer; do
  if agent_payload=$(herdr agent get "$role" 2>&1); then
    live_name=$(extract_agent_field "$agent_payload" name)
    agent_kind=$(extract_agent_field "$agent_payload" agent)
    agent_status=$(extract_agent_field "$agent_payload" agent_status)
    interactive_ready=$(extract_agent_field "$agent_payload" interactive_ready)
    launch_pending=$(extract_agent_field "$agent_payload" launch_pending)
    if [[ "$live_name" == "$role" && "$agent_kind" == 'codex' && \
          "$interactive_ready" == 'true' && "$launch_pending" != 'true' && \
          ( "$agent_status" == 'idle' || "$agent_status" == 'done' ) ]]; then
      printf '[OK] %s ready (state: %s)\n' "$role" "$agent_status"
      continue
    fi
    printf '[FAIL] %s final state is not ready (name=%s, kind=%s, state=%s, ready=%s, launch_pending=%s).\n' \
      "$role" "${live_name:-unknown}" "${agent_kind:-unknown}" "${agent_status:-unknown}" \
      "${interactive_ready:-unknown}" "${launch_pending:-unknown}" >&2
  else
    printf '[FAIL] %s has no live Herdr agent after startup.\n' "$role" >&2
  fi
  startup_issues=$((startup_issues + 1))
  [[ -n "$first_issue_role" ]] || first_issue_role=$role
done

if [[ $startup_issues -gt 0 ]]; then
  trap - ERR
  printf '\nSTART_PARTIAL\n\n'
  printf '[FAIL] Workspace %s is only partially ready (%s role issue(s)).\n' \
    "$workspace_id" "$startup_issues" >&2
  printf '       Planner pane:  %s\n' "$root_pane_id" >&2
  printf '       Coder pane:    %s\n' "$coder_pane_id" >&2
  printf '       Reviewer pane: %s\n' "$reviewer_pane_id" >&2
  printf '       All three roles were attempted. Resolve retained blocked agents or run the printed exact retry for a missing name.\n' >&2
  printf '       Then run: %s/doctor.sh\n' "$SCRIPT_DIR" >&2
  if [[ $NO_FOCUS -eq 0 && -n "$first_issue_role" ]] && \
     herdr agent get "$first_issue_role" >/dev/null 2>&1; then
    herdr workspace focus "$workspace_id" >/dev/null 2>&1 || true
    herdr agent focus "$first_issue_role" >/dev/null 2>&1 || true
  fi
  exit 1
fi

if [[ $NO_FOCUS -eq 0 ]]; then
  herdr workspace focus "$workspace_id" >/dev/null
  herdr agent focus planner >/dev/null
fi

trap - ERR
printf '\n[OK] Three-agent team started.\n'
printf 'Workspace: %s\n' "$workspace_id"
printf 'Planner:   %s\n' "$root_pane_id"
printf 'Coder:     %s\n' "$coder_pane_id"
printf 'Reviewer:  %s\n' "$reviewer_pane_id"
printf '\nVerify with: %s/doctor.sh\n' "$SCRIPT_DIR"
