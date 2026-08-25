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
