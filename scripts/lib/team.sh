#!/usr/bin/env bash

# Shared Herdr live-name rules. Profiles stay generic (planner/coder/reviewer);
# only live Herdr agent names carry an optional team prefix.

HERDR_AGENT_NAME_PATTERN='^[a-z][a-z0-9_-]{0,31}$'
HERDR_TEAM_PREFIX_PATTERN='^[a-z][a-z0-9_-]{0,22}$'

team_validate_agent_name() {
  local name=${1-}
  [[ "$name" =~ $HERDR_AGENT_NAME_PATTERN ]]
}

team_validate_prefix() {
  local prefix=${1-}

  [[ -n "$prefix" ]] || return 1
  [[ "$prefix" =~ $HERDR_TEAM_PREFIX_PATTERN ]] || return 1
  team_validate_agent_name "$prefix-planner" || return 1
  team_validate_agent_name "$prefix-coder" || return 1
  team_validate_agent_name "$prefix-reviewer" || return 1
}

team_name_for_prefix() {
  local prefix=${1-}
  local role=${2-}

  case "$role" in
    planner|coder|reviewer) ;;
    *) return 1 ;;
  esac

  if [[ -n "$prefix" ]]; then
    team_validate_prefix "$prefix" || return 1
    printf '%s-%s' "$prefix" "$role"
  else
    printf '%s' "$role"
  fi
}

team_configure() {
  local prefix=${1-}

  if [[ -n "$prefix" ]]; then
    team_validate_prefix "$prefix" || return 1
    TEAM_MODE='prefixed'
    TEAM_DISPLAY=$prefix
  else
    TEAM_MODE='legacy'
    TEAM_DISPLAY='legacy'
  fi

  TEAM_PREFIX_EFFECTIVE=$prefix
  PLANNER_AGENT=$(team_name_for_prefix "$prefix" planner) || return 1
  CODER_AGENT=$(team_name_for_prefix "$prefix" coder) || return 1
  REVIEWER_AGENT=$(team_name_for_prefix "$prefix" reviewer) || return 1
}

team_agent_for_role() {
  case "${1-}" in
    planner) printf '%s' "$PLANNER_AGENT" ;;
    coder) printf '%s' "$CODER_AGENT" ;;
    reviewer) printf '%s' "$REVIEWER_AGENT" ;;
    *) return 1 ;;
  esac
}

# Print the canonical role for a live name managed by this project. This
# accepts the three legacy names and valid <team>-<role> names only.
team_role_from_live_name() {
  local name=${1-}
  local role
  local prefix

  case "$name" in
    planner|coder|reviewer)
      printf '%s' "$name"
      return 0
      ;;
    *-planner) role=planner; prefix=${name%-planner} ;;
    *-coder) role=coder; prefix=${name%-coder} ;;
    *-reviewer) role=reviewer; prefix=${name%-reviewer} ;;
    *) return 1 ;;
  esac

  team_validate_prefix "$prefix" || return 1
  [[ "$(team_name_for_prefix "$prefix" "$role")" == "$name" ]] || return 1
  printf '%s' "$role"
}

team_resolve_requested_prefix() {
  local cli_was_set=${1-0}
  local cli_prefix=${2-}
  local env_was_set=0
  local env_prefix=''

  if [[ ${TEAM_PREFIX+x} == x ]]; then
    env_was_set=1
    env_prefix=$TEAM_PREFIX
    [[ -n "$env_prefix" ]] || {
      printf '%s\n' 'TEAM_PREFIX is set but empty.' >&2
      return 1
    }
  fi

  if [[ "$cli_was_set" == 1 ]]; then
    [[ -n "$cli_prefix" ]] || {
      printf '%s\n' '--team requires a non-empty prefix.' >&2
      return 1
    }
    if [[ $env_was_set -eq 1 && "$env_prefix" != "$cli_prefix" ]]; then
      printf 'Conflicting team prefixes: --team=%s but TEAM_PREFIX=%s.\n' \
        "$cli_prefix" "$env_prefix" >&2
      return 1
    fi
    printf '%s' "$cli_prefix"
    return 0
  fi

  if [[ $env_was_set -eq 1 ]]; then
    printf '%s' "$env_prefix"
  fi
}

# Per-role native CLI. Unspecified roles retain the existing Codex default.
team_role_cli() {
  local kind
  case "$1" in
    planner) kind=${PLANNER_CLI:-codex} ;;
    coder) kind=${CODER_CLI:-codex} ;;
    reviewer) kind=${REVIEWER_CLI:-codex} ;;
    *) return 2 ;;
  esac
  case "$kind" in
    codex|claude|agy) printf '%s\n' "$kind" ;;
    antigravity) printf 'agy\n' ;;
    *) printf 'Unsupported %s CLI: %s (expected codex, claude or agy)\n' "$1" "$kind" >&2; return 2 ;;
  esac
}

team_integrations() {
  local role kind seen=' '
  for role in planner coder reviewer; do
    kind=$(team_role_cli "$role") || return 2
    [[ "$kind" != agy ]] || kind=antigravity-cli
    [[ "$seen" == *" $kind "* ]] || printf '%s\n' "$kind"
    seen="$seen$kind "
  done
}

team_process_policy() {
  local payload=$1 role=$2 kind=$3
  if [[ "$kind" == codex ]]; then
    json_process_uses_profile "$payload" "$role" && json_process_has_managed_scope "$payload" "$role"
  else
    python3 "$SCRIPT_DIR/providers.py" inspect "$kind" "$role" <<<"$payload" >/dev/null
  fi
}

team_process_dirs() {
  if [[ "$3" == codex ]]; then
    json_process_codex_add_dirs "$1"
  else
    python3 "$SCRIPT_DIR/providers.py" inspect "$3" "$2" <<<"$1"
  fi
}

team_set_role_cli() {
  case "$1" in
    --planner-cli) export PLANNER_CLI="$2"; team_role_cli planner >/dev/null ;;
    --coder-cli) export CODER_CLI="$2"; team_role_cli coder >/dev/null ;;
    --reviewer-cli) export REVIEWER_CLI="$2"; team_role_cli reviewer >/dev/null ;;
    *) return 2 ;;
  esac
}

# Shared by initial team launch and a CLI replacement in an existing role pane.
team_role_args() {
  local role=$1 kind=$2 model=$3 role_folder prepared arg add_dir permission_config
  if [[ "$kind" != codex ]]; then
    role_folder="${RUN_STATE_FILE%/*}/$RUN_ID"
    mkdir -p -- "$role_folder"
    prepared=$("$PYTHON_BIN" "$SCRIPT_DIR/providers.py" prepare "$kind" "$role" "$role_folder" "$BRIDGE_TARGET" "$HERDR_BIN") || return 1
    TEAM_ROLE_ARGS=()
    while IFS= read -r arg; do TEAM_ROLE_ARGS+=("$arg"); done <<<"$prepared"
  else
    managed_role_permission_policy "$role" || return 1
    TEAM_ROLE_ARGS=(
      --profile "$role"
      -c 'agents.enabled=false'
      -c 'tui.terminal_title=["session-id"]'
      -c 'tui.status_line=["session-id"]'
    )
    for permission_config in "${MANAGED_ROLE_PERMISSION_CONFIGS[@]}"; do
      TEAM_ROLE_ARGS+=(-c "$permission_config")
    done

  fi

  if [[ "$role" != reviewer ]]; then
    for add_dir in ${ADD_DIRS[@]+"${ADD_DIRS[@]}"}; do
      TEAM_ROLE_ARGS+=(--add-dir "$add_dir")
    done
  fi

  if [[ -n "$model" ]]; then
    TEAM_ROLE_ARGS+=(--model "$model")
  fi
}
