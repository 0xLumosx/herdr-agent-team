#!/usr/bin/env bash

# User-local launch registry for one fixed Herdr/Codex team.
#
# This module owns only records written by this project's startup helper and a
# short-lived startup lock shared by managed starts that use the same
# CODEX_HOME. Herdr remains authoritative for live workspaces, panes, agents,
# lifecycle, and prompt delivery.

run_state_now() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

run_state_new_id() {
  printf '%s-%s-%s' "$(date -u '+%Y%m%dT%H%M%SZ')" "$$" "${RANDOM:-0}"
}

run_state_configure() {
  local codex_dir=${1-}
  local team_mode=${2-}
  local team_prefix=${3-}
  local team_key

  [[ "$codex_dir" == /* && "$codex_dir" != '/' ]] || return 1
  if command -v scope_path_has_control >/dev/null 2>&1 && \
     scope_path_has_control "$codex_dir"; then
    return 1
  fi
  case "$team_mode" in
    legacy)
      [[ -z "$team_prefix" ]] || return 1
      team_key=legacy
      ;;
    prefixed)
      team_validate_prefix "$team_prefix" || return 1
      # Keep prefixed teams in an injective namespace. Without this marker,
      # `--team legacy` would collide with the actual no-prefix legacy team.
      team_key="prefixed-$team_prefix"
      ;;
    *) return 1 ;;
  esac

  RUN_STATE_CODEX_DIR=$codex_dir
  RUN_STATE_BASE_DIR="$codex_dir/herdr-codex-team/state/v1"
  RUN_STATE_TEAMS_DIR="$RUN_STATE_BASE_DIR/teams"
  RUN_STATE_TEAM_DIR="$RUN_STATE_TEAMS_DIR/$team_key"
  RUN_STATE_FILE="$RUN_STATE_TEAM_DIR/current.json"
  RUN_STATE_LOCK_DIR="$RUN_STATE_BASE_DIR/startup.lock"
  RUN_STATE_LOCK_HELD=0
  RUN_STATE_LOCK_TOKEN=''
}

run_state_ensure_private_dir() {
  local path=$1

  if [[ -L "$path" ]]; then
    return 1
  fi
  if [[ -e "$path" ]]; then
    [[ -d "$path" ]] || return 1
  else
    mkdir -- "$path" || return 1
  fi
  chmod 700 "$path" || return 1
}

run_state_storage_dirs_safe() {
  local managed_dir

  [[ -n "${RUN_STATE_CODEX_DIR:-}" && -n "${RUN_STATE_TEAM_DIR:-}" ]] || return 1
  for managed_dir in \
    "$RUN_STATE_CODEX_DIR/herdr-codex-team" \
    "$RUN_STATE_CODEX_DIR/herdr-codex-team/state" \
    "$RUN_STATE_BASE_DIR" \
    "$RUN_STATE_TEAMS_DIR" \
    "$RUN_STATE_TEAM_DIR"; do
    [[ -d "$managed_dir" && ! -L "$managed_dir" ]] || return 1
  done
}

run_state_current_target_safe() {
  if [[ ! -e "$RUN_STATE_FILE" && ! -L "$RUN_STATE_FILE" ]]; then
    return 0
  fi
  [[ -f "$RUN_STATE_FILE" && ! -L "$RUN_STATE_FILE" ]]
}

run_state_utf8_roundtrips() {
  local value=${1-}
  local decoded
  local sentinel=$'\036'

  if command -v jq >/dev/null 2>&1; then
    decoded=$(jq -nr --arg value "$value" '$value + "\u001e"') || return 1
    [[ "$decoded" == *"$sentinel" ]] || return 1
    decoded=${decoded%"$sentinel"}
    [[ "$decoded" == "$value" ]]
    return
  fi

  command -v python3 >/dev/null 2>&1 || return 127
  python3 -c '
import sys

value = sys.argv[1]
try:
    encoded = value.encode("utf-8", "strict")
    decoded = encoded.decode("utf-8", "strict")
except UnicodeError:
    raise SystemExit(1)
if decoded != value:
    raise SystemExit(1)
' "$value"
}

run_state_file_utf8_valid() {
  local path=$1
  local raw
  local decoded
  local sentinel=$'\036'

  if command -v jq >/dev/null 2>&1; then
    raw=$(command cat "$path"; printf '%s' "$sentinel") || return 1
    decoded=$(jq -Rrs '. + "\u001e"' "$path") || return 1
    [[ "$raw" == *"$sentinel" && "$decoded" == *"$sentinel" ]] || return 1
    raw=${raw%"$sentinel"}
    decoded=${decoded%"$sentinel"}
    [[ "$decoded" == "$raw" ]]
    return
  fi

  command -v python3 >/dev/null 2>&1 || return 127
  python3 -c '
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8", errors="strict") as handle:
        handle.read()
except (OSError, UnicodeError):
    raise SystemExit(1)
' "$path"
}

run_state_validate_launch_strings() {
  local value

  for value in "$@"; do
    run_state_utf8_roundtrips "$value" || return $?
  done
}

run_state_prepare_storage() (
  local codex_dir

  [[ -n "${RUN_STATE_BASE_DIR:-}" && -n "${RUN_STATE_TEAM_DIR:-}" ]] || return 1
  codex_dir=$RUN_STATE_CODEX_DIR
  umask 077
  run_state_ensure_private_dir "$codex_dir/herdr-codex-team" || return 1
  run_state_ensure_private_dir "$codex_dir/herdr-codex-team/state" || return 1
  run_state_ensure_private_dir "$RUN_STATE_BASE_DIR" || return 1
  run_state_ensure_private_dir "$RUN_STATE_TEAMS_DIR" || return 1
  run_state_ensure_private_dir "$RUN_STATE_TEAM_DIR" || return 1
  run_state_storage_dirs_safe || return 1
  run_state_current_target_safe || return 1
)

run_state_host_id() {
  local host

  host=$(uname -n 2>/dev/null || true)
  case "$host" in
    ''|*[!A-Za-z0-9._-]*) printf '%s' unknown ;;
    *) printf '%s' "$host" ;;
  esac
}

run_state_owner_value() {
  local owner_file=$1
  local key=$2

  [[ -f "$owner_file" && ! -L "$owner_file" ]] || return 1
  (( $(wc -c <"$owner_file") <= 4096 )) || return 1
  awk -F= -v wanted="$key" '
    $1 == wanted { count++; value = substr($0, length($1) + 2) }
    END {
      if (count != 1 || value == "") exit 2
      print value
    }
  ' "$owner_file"
}

run_state_discard_quarantine() {
  local quarantine=$1
  local owner_file="$quarantine/owner"

  if [[ -f "$owner_file" && ! -L "$owner_file" ]]; then
    rm -f -- "$owner_file" || return 1
  fi
  rmdir -- "$quarantine" 2>/dev/null || return 1
}

run_state_recover_stale_lock() {
  local owner_file="$RUN_STATE_LOCK_DIR/owner"
  local owner_host
  local owner_pid
  local owner_token
  local owner_run_id
  local owner_team
  local owner_identity
  local current_host
  local quarantine

  [[ -d "$RUN_STATE_LOCK_DIR" && ! -L "$RUN_STATE_LOCK_DIR" ]] || {
    printf '[FAIL] Startup lock path is not a safe directory: %s\n' \
      "$RUN_STATE_LOCK_DIR" >&2
    return 1
  }
  owner_host=$(run_state_owner_value "$owner_file" host) || {
    printf '[FAIL] Startup lock owner is missing or malformed: %s\n' \
      "$owner_file" >&2
    return 1
  }
  owner_pid=$(run_state_owner_value "$owner_file" pid) || {
    printf '[FAIL] Startup lock owner PID is missing or malformed: %s\n' \
      "$owner_file" >&2
    return 1
  }
  owner_token=$(run_state_owner_value "$owner_file" token) || {
    printf '[FAIL] Startup lock owner token is missing or malformed: %s\n' \
      "$owner_file" >&2
    return 1
  }
  owner_run_id=$(run_state_owner_value "$owner_file" run_id) || {
    printf '[FAIL] Startup lock owner run ID is missing or malformed: %s\n' \
      "$owner_file" >&2
    return 1
  }
  owner_team=$(run_state_owner_value "$owner_file" team) || {
    printf '[FAIL] Startup lock owner Team is missing or malformed: %s\n' \
      "$owner_file" >&2
    return 1
  }
  (( $(wc -l <"$owner_file") == 5 )) || {
    printf '[FAIL] Startup lock owner has unexpected content: %s\n' \
      "$owner_file" >&2
    return 1
  }
  [[ "$owner_pid" =~ ^[1-9][0-9]*$ ]] || {
    printf '[FAIL] Startup lock owner PID is invalid: %s\n' "$owner_pid" >&2
    return 1
  }
  case "$owner_token" in
    *[!A-Za-z0-9._-]*|'')
      printf '[FAIL] Startup lock owner token is invalid.\n' >&2
      return 1
      ;;
  esac
  case "$owner_host" in
    *[!A-Za-z0-9._-]*|'')
      printf '[FAIL] Startup lock owner host is invalid.\n' >&2
      return 1
      ;;
  esac
  for owner_identity in "$owner_run_id" "$owner_team"; do
    case "$owner_identity" in
      *[!A-Za-z0-9._-]*|'')
        printf '[FAIL] Startup lock owner identity is invalid.\n' >&2
        return 1
        ;;
    esac
  done

  current_host=$(run_state_host_id)
  if [[ "$owner_host" != "$current_host" || "$current_host" == unknown ]]; then
    printf '[FAIL] Another host or an unverifiable owner holds the startup lock (host=%s, pid=%s).\n' \
      "$owner_host" "$owner_pid" >&2
    return 1
  fi
  if kill -0 "$owner_pid" 2>/dev/null; then
    printf '[FAIL] Another herdr-codex-team startup is active (pid=%s). Retry after it finishes.\n' \
      "$owner_pid" >&2
    return 1
  fi

  quarantine="$RUN_STATE_BASE_DIR/.startup.lock.stale.$owner_token"
  [[ ! -e "$quarantine" && ! -L "$quarantine" ]] || {
    printf '[FAIL] Refusing to reuse an existing stale-lock quarantine: %s\n' \
      "$quarantine" >&2
    return 1
  }
  mv -- "$RUN_STATE_LOCK_DIR" "$quarantine" || return 1
  if ! run_state_discard_quarantine "$quarantine"; then
    printf '[WARN] Recovered a stale startup lock but retained its quarantine for inspection: %s\n' \
      "$quarantine" >&2
  fi
}

run_state_acquire_start_lock() {
  local run_id=$1
  local host
  local owner_file
  local attempt=1

  case "$run_id" in
    *[!A-Za-z0-9._-]*|'') return 1 ;;
  esac
  host=$(run_state_host_id)
  [[ "$host" != unknown ]] || {
    printf '[FAIL] Could not derive a safe local host identity for the startup lock.\n' >&2
    return 1
  }

  while (( attempt <= 2 )); do
    if mkdir -- "$RUN_STATE_LOCK_DIR" 2>/dev/null; then
      RUN_STATE_LOCK_TOKEN="${run_id}.$$"
      owner_file="$RUN_STATE_LOCK_DIR/owner"
      if ! chmod 700 "$RUN_STATE_LOCK_DIR"; then
        rmdir -- "$RUN_STATE_LOCK_DIR" 2>/dev/null || true
        return 1
      fi
      if ! {
        printf 'token=%s\n' "$RUN_STATE_LOCK_TOKEN"
        printf 'pid=%s\n' "$$"
        printf 'host=%s\n' "$host"
        printf 'run_id=%s\n' "$run_id"
        printf 'team=%s\n' "${TEAM_DISPLAY:-unknown}"
      } >"$owner_file"; then
        if [[ -f "$owner_file" && ! -L "$owner_file" ]]; then
          rm -f -- "$owner_file" || true
        fi
        rmdir -- "$RUN_STATE_LOCK_DIR" 2>/dev/null || true
        return 1
      fi
      if ! chmod 600 "$owner_file"; then
        rm -f -- "$owner_file"
        rmdir -- "$RUN_STATE_LOCK_DIR" 2>/dev/null || true
        return 1
      fi
      RUN_STATE_LOCK_HELD=1
      return 0
    fi
    (( attempt == 1 )) || break
    run_state_recover_stale_lock || return 1
    attempt=$((attempt + 1))
  done

  printf '[FAIL] Could not acquire the managed startup lock: %s\n' \
    "$RUN_STATE_LOCK_DIR" >&2
  return 1
}

run_state_release_start_lock() {
  local owner_file
  local owner_token
  local quarantine

  [[ ${RUN_STATE_LOCK_HELD:-0} -eq 1 ]] || return 0
  owner_file="$RUN_STATE_LOCK_DIR/owner"
  owner_token=$(run_state_owner_value "$owner_file" token) || return 1
  [[ "$owner_token" == "$RUN_STATE_LOCK_TOKEN" ]] || return 1
  quarantine="$RUN_STATE_BASE_DIR/.startup.lock.release.$RUN_STATE_LOCK_TOKEN"
  [[ ! -e "$quarantine" && ! -L "$quarantine" ]] || return 1
  mv -- "$RUN_STATE_LOCK_DIR" "$quarantine" || return 1
  RUN_STATE_LOCK_HELD=0
  run_state_discard_quarantine "$quarantine"
}

run_state_render_current() {
  local status=$1
  local updated_at=$2
  local jq_filter

  case "$status" in
    starting|partial|ready) ;;
    *) return 1 ;;
  esac

  if command -v jq >/dev/null 2>&1; then
    jq_filter='
      $ARGS.positional as $add_dirs |
      {
        schema_version: 1,
        run_id: $run_id,
        status: $status,
        started_at: $started_at,
        updated_at: $updated_at,
        team: {
          mode: $team_mode,
          prefix: $team_prefix,
          display: $team_display
        },
        launch: {
          primary_cwd: $primary_cwd,
          add_dirs: $add_dirs,
          no_focus: $no_focus,
          non_git_evidence_degraded: $non_git
        },
        herdr: {
          workspace_id: $workspace_id,
          agents: {
            planner: {name: $planner_name, cli: $planner_cli, pane_id: $planner_pane, sandbox: "read-only"},
            coder: {name: $coder_name, cli: $coder_cli, pane_id: $coder_pane, sandbox: "workspace-write"},
            reviewer: {name: $reviewer_name, cli: $reviewer_cli, pane_id: $reviewer_pane, sandbox: "read-only"}
          }
        },
        authorities: {
          live_runtime: "herdr",
          launch_record: "herdr-codex-team",
          code_changes: "git-or-filesystem"
        }
      }
    '
    jq -n \
      --arg run_id "$RUN_ID" \
      --arg status "$status" \
      --arg started_at "$RUN_STARTED_AT" \
      --arg updated_at "$updated_at" \
      --arg team_mode "$TEAM_MODE" \
      --arg team_prefix "$TEAM_PREFIX_EFFECTIVE" \
      --arg team_display "$TEAM_DISPLAY" \
      --arg primary_cwd "$PROJECT_DIR" \
      --argjson no_focus "$([[ $NO_FOCUS -eq 1 ]] && printf true || printf false)" \
      --argjson non_git "$([[ $REQUESTED_HAS_NON_GIT -eq 1 ]] && printf true || printf false)" \
      --arg workspace_id "${workspace_id:-}" \
      --arg planner_cli "$(team_role_cli planner)" \
      --arg planner_name "$PLANNER_AGENT" \
      --arg planner_pane "${root_pane_id:-}" \
      --arg coder_cli "$(team_role_cli coder)" \
      --arg coder_name "$CODER_AGENT" \
      --arg coder_pane "${coder_pane_id:-}" \
      --arg reviewer_cli "$(team_role_cli reviewer)" \
      --arg reviewer_name "$REVIEWER_AGENT" \
      --arg reviewer_pane "${reviewer_pane_id:-}" \
      --args "$jq_filter" ${ADD_DIRS[@]+"${ADD_DIRS[@]}"}
    return
  fi

  command -v python3 >/dev/null 2>&1 || return 127
  python3 -c '
import json
import sys

(
    run_id, status, started_at, updated_at, team_mode, team_prefix,
    team_display, primary_cwd, no_focus, non_git, workspace_id,
    planner_name, planner_pane, coder_name, coder_pane,
    reviewer_name, reviewer_pane, planner_cli, coder_cli, reviewer_cli, separator, *add_dirs
) = sys.argv[1:]
if separator != "--":
    raise SystemExit(2)
payload = {
    "schema_version": 1,
    "run_id": run_id,
    "status": status,
    "started_at": started_at,
    "updated_at": updated_at,
    "team": {
        "mode": team_mode,
        "prefix": team_prefix,
        "display": team_display,
    },
    "launch": {
        "primary_cwd": primary_cwd,
        "add_dirs": add_dirs,
        "no_focus": no_focus == "1",
        "non_git_evidence_degraded": non_git == "1",
    },
    "herdr": {
        "workspace_id": workspace_id,
        "agents": {
            "planner": {"name": planner_name, "cli": planner_cli, "pane_id": planner_pane, "sandbox": "read-only"},
            "coder": {"name": coder_name, "cli": coder_cli, "pane_id": coder_pane, "sandbox": "workspace-write"},
            "reviewer": {"name": reviewer_name, "cli": reviewer_cli, "pane_id": reviewer_pane, "sandbox": "read-only"},
        },
    },
    "authorities": {
        "live_runtime": "herdr",
        "launch_record": "herdr-codex-team",
        "code_changes": "git-or-filesystem",
    },
}
json.dump(payload, sys.stdout, ensure_ascii=False, indent=2)
sys.stdout.write("\n")
' \
    "$RUN_ID" "$status" "$RUN_STARTED_AT" "$updated_at" \
    "$TEAM_MODE" "$TEAM_PREFIX_EFFECTIVE" "$TEAM_DISPLAY" "$PROJECT_DIR" \
    "$NO_FOCUS" "$REQUESTED_HAS_NON_GIT" "${workspace_id:-}" \
    "$PLANNER_AGENT" "${root_pane_id:-}" \
    "$CODER_AGENT" "${coder_pane_id:-}" \
    "$REVIEWER_AGENT" "${reviewer_pane_id:-}" "$(team_role_cli planner)" "$(team_role_cli coder)" "$(team_role_cli reviewer)" -- \
    ${ADD_DIRS[@]+"${ADD_DIRS[@]}"}
}

run_state_write_current() {
  local status=$1
  local updated_at
  local temporary_file

  run_state_storage_dirs_safe || return 1
  run_state_current_target_safe || return 1
  updated_at=$(run_state_now) || return 1
  temporary_file=$(umask 077; mktemp "$RUN_STATE_TEAM_DIR/.current.json.XXXXXX") || return 1
  if ! run_state_render_current "$status" "$updated_at" >"$temporary_file"; then
    rm -f -- "$temporary_file"
    return 1
  fi
  chmod 600 "$temporary_file" || {
    rm -f -- "$temporary_file"
    return 1
  }
  # Recheck immediately before replacement. BSD mv treats a directory target
  # as a destination directory, so both the precheck and postcheck are needed
  # to avoid reporting a successful current.json update in that case.
  if ! run_state_storage_dirs_safe || ! run_state_current_target_safe; then
    rm -f -- "$temporary_file"
    return 1
  fi
  if ! mv -f -- "$temporary_file" "$RUN_STATE_FILE"; then
    rm -f -- "$temporary_file"
    return 1
  fi
  if [[ ! -f "$RUN_STATE_FILE" || -L "$RUN_STATE_FILE" ]]; then
    if [[ -d "$RUN_STATE_FILE" && ! -L "$RUN_STATE_FILE" ]]; then
      rm -f -- "$RUN_STATE_FILE/${temporary_file##*/}" 2>/dev/null || true
    fi
    return 1
  fi
  chmod 600 "$RUN_STATE_FILE"
}

run_state_current_exists() {
  local managed_dir

  [[ -n "${RUN_STATE_CODEX_DIR:-}" && -n "${RUN_STATE_FILE:-}" ]] || return 2
  for managed_dir in \
    "$RUN_STATE_CODEX_DIR/herdr-codex-team" \
    "$RUN_STATE_CODEX_DIR/herdr-codex-team/state" \
    "$RUN_STATE_BASE_DIR" \
    "$RUN_STATE_TEAMS_DIR" \
    "$RUN_STATE_TEAM_DIR"; do
    if [[ -L "$managed_dir" ]]; then
      return 2
    fi
    if [[ ! -e "$managed_dir" ]]; then
      return 1
    fi
    [[ -d "$managed_dir" ]] || return 2
  done
  if [[ ! -e "$RUN_STATE_FILE" && ! -L "$RUN_STATE_FILE" ]]; then
    return 1
  fi
  [[ -f "$RUN_STATE_FILE" && ! -L "$RUN_STATE_FILE" ]] || return 2
}

run_state_parse_current() {
  local jq_filter

  run_state_current_exists || return $?
  (( $(wc -c <"$RUN_STATE_FILE") <= 1048576 )) || return 2
  run_state_file_utf8_valid "$RUN_STATE_FILE" || return 2
  if command -v jq >/dev/null 2>&1; then
    jq_filter='
      def safe_string:
        type == "string" and ((test("[[:cntrl:]]")) | not);
      def safe_nonempty: safe_string and length > 0;
      def safe_absolute: safe_nonempty and startswith("/") and . != "/";
      def safe_run_id:
        safe_nonempty and test("^[A-Za-z0-9._-]+$");
      def utc_stamp:
        safe_nonempty and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
      . as $s |
      if ($s.schema_version != 1) or
         (($s.run_id | safe_run_id) | not) or
         (($s.started_at | utc_stamp) | not) or
         (($s.updated_at | utc_stamp) | not) or
         (["starting", "partial", "ready"] | index($s.status) | not) or
         (["legacy", "prefixed"] | index($s.team.mode) | not) or
         (($s.team.prefix | safe_string) | not) or
         (($s.team.display | safe_nonempty) | not) or
         (($s.team.mode == "legacy") and
           (($s.team.prefix != "") or ($s.team.display != "legacy"))) or
         (($s.team.mode == "prefixed") and
           (($s.team.prefix == "") or ($s.team.display != $s.team.prefix))) or
         (($s.launch.primary_cwd | safe_absolute) | not) or
         (($s.launch.add_dirs | type) != "array") or
         (all($s.launch.add_dirs[]; safe_absolute) | not) or
         (($s.launch.no_focus | type) != "boolean") or
         (($s.launch.non_git_evidence_degraded | type) != "boolean") or
         (($s.herdr.workspace_id | safe_nonempty) | not) or
         ((all(["planner", "coder", "reviewer"][];
           ($s.herdr.agents[.].name | safe_nonempty) and
           ($s.herdr.agents[.].pane_id | safe_string))) | not) or
         ($s.herdr.agents.planner.sandbox != "read-only") or
         ($s.herdr.agents.coder.sandbox != "workspace-write") or
         ($s.herdr.agents.reviewer.sandbox != "read-only") or
         (($s.status == "ready") and
           (($s.herdr.workspace_id == "") or
            ($s.herdr.agents.planner.pane_id == "") or
            ($s.herdr.agents.coder.pane_id == "") or
            ($s.herdr.agents.reviewer.pane_id == ""))) or
         ($s.authorities.live_runtime != "herdr") or
         ($s.authorities.launch_record != "herdr-codex-team") or
         ($s.authorities.code_changes != "git-or-filesystem")
      then error("invalid launch state")
      else
        "RUN_ID=" + $s.run_id,
        "STATUS=" + $s.status,
        "TEAM_MODE=" + $s.team.mode,
        "TEAM_PREFIX=" + $s.team.prefix,
        "PRIMARY_CWD=" + $s.launch.primary_cwd,
        "WORKSPACE_ID=" + $s.herdr.workspace_id,
        "PLANNER_NAME=" + $s.herdr.agents.planner.name,
        "PLANNER_PANE=" + $s.herdr.agents.planner.pane_id,
        "CODER_NAME=" + $s.herdr.agents.coder.name,
        "CODER_PANE=" + $s.herdr.agents.coder.pane_id,
        "REVIEWER_NAME=" + $s.herdr.agents.reviewer.name,
        "REVIEWER_PANE=" + $s.herdr.agents.reviewer.pane_id,
        ($s.launch.add_dirs[] | "ADD_DIR=" + .)
      end
    '
    jq -er "$jq_filter" "$RUN_STATE_FILE" 2>/dev/null
    return
  fi

  command -v python3 >/dev/null 2>&1 || return 127
  python3 -c '
import json
import re
import sys

def safe(value, nonempty=False):
    return (
        isinstance(value, str)
        and (bool(value) or not nonempty)
        and not any(ord(char) < 32 or 127 <= ord(char) <= 159 for char in value)
    )

def absolute(value):
    return safe(value, True) and value.startswith("/") and value != "/"

def run_id(value):
    return safe(value, True) and re.fullmatch(r"[A-Za-z0-9._-]+", value) is not None

def utc_stamp(value):
    return (
        safe(value, True)
        and re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", value)
        is not None
    )

try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        state = json.load(handle)
    team = state["team"]
    launch = state["launch"]
    herdr = state["herdr"]
    agents = herdr["agents"]
    schema_version = state.get("schema_version")
    if (
        isinstance(schema_version, bool)
        or not isinstance(schema_version, (int, float))
        or schema_version != 1
    ):
        raise TypeError
    if not run_id(state.get("run_id")):
        raise TypeError
    if not utc_stamp(state.get("started_at")) or not utc_stamp(state.get("updated_at")):
        raise TypeError
    if state.get("status") not in {"starting", "partial", "ready"}:
        raise TypeError
    if team.get("mode") not in {"legacy", "prefixed"}:
        raise TypeError
    if not safe(team.get("prefix")) or not safe(team.get("display"), True):
        raise TypeError
    if team["mode"] == "legacy" and (team["prefix"] != "" or team["display"] != "legacy"):
        raise TypeError
    if team["mode"] == "prefixed" and (not team["prefix"] or team["display"] != team["prefix"]):
        raise TypeError
    if not absolute(launch.get("primary_cwd")):
        raise TypeError
    add_dirs = launch.get("add_dirs")
    if not isinstance(add_dirs, list) or not all(absolute(path) for path in add_dirs):
        raise TypeError
    if not isinstance(launch.get("no_focus"), bool):
        raise TypeError
    if not isinstance(launch.get("non_git_evidence_degraded"), bool):
        raise TypeError
    if not safe(herdr.get("workspace_id"), True):
        raise TypeError
    for role in ("planner", "coder", "reviewer"):
        if not safe(agents[role].get("name"), True) or not safe(agents[role].get("pane_id")):
            raise TypeError
    if agents["planner"].get("sandbox") != "read-only":
        raise TypeError
    if agents["coder"].get("sandbox") != "workspace-write":
        raise TypeError
    if agents["reviewer"].get("sandbox") != "read-only":
        raise TypeError
    if state["status"] == "ready" and (
        not herdr["workspace_id"]
        or any(not agents[role]["pane_id"] for role in ("planner", "coder", "reviewer"))
    ):
        raise TypeError
    authorities = state.get("authorities", {})
    if (
        authorities.get("live_runtime") != "herdr"
        or authorities.get("launch_record") != "herdr-codex-team"
        or authorities.get("code_changes") != "git-or-filesystem"
    ):
        raise TypeError
    fields = (
        ("RUN_ID", state["run_id"]),
        ("STATUS", state["status"]),
        ("TEAM_MODE", team["mode"]),
        ("TEAM_PREFIX", team["prefix"]),
        ("PRIMARY_CWD", launch["primary_cwd"]),
        ("WORKSPACE_ID", herdr["workspace_id"]),
        ("PLANNER_NAME", agents["planner"]["name"]),
        ("PLANNER_PANE", agents["planner"]["pane_id"]),
        ("CODER_NAME", agents["coder"]["name"]),
        ("CODER_PANE", agents["coder"]["pane_id"]),
        ("REVIEWER_NAME", agents["reviewer"]["name"]),
        ("REVIEWER_PANE", agents["reviewer"]["pane_id"]),
    )
    for key, value in fields:
        print(f"{key}={value}")
    for path in add_dirs:
        print(f"ADD_DIR={path}")
except (AttributeError, KeyError, OSError, TypeError, ValueError, UnicodeError):
    raise SystemExit(2)
' "$RUN_STATE_FILE" 2>/dev/null
}

run_state_load_scope() {
  local parsed
  local line
  local tag
  local value
  local run_id_seen=0
  local status_seen=0
  local mode_seen=0
  local prefix_seen=0
  local cwd_seen=0
  local workspace_seen=0
  local planner_name_seen=0
  local planner_pane_seen=0
  local coder_name_seen=0
  local coder_pane_seen=0
  local reviewer_name_seen=0
  local reviewer_pane_seen=0

  parsed=$(run_state_parse_current) || return $?
  RUN_STATE_LOADED_ADD_DIRS=()
  while IFS= read -r line; do
    tag=${line%%=*}
    value=${line#*=}
    case "$tag" in
      RUN_ID) (( run_id_seen == 0 )) || return 2; RUN_STATE_LOADED_RUN_ID=$value; run_id_seen=1 ;;
      STATUS) (( status_seen == 0 )) || return 2; RUN_STATE_LOADED_STATUS=$value; status_seen=1 ;;
      TEAM_MODE) (( mode_seen == 0 )) || return 2; RUN_STATE_LOADED_TEAM_MODE=$value; mode_seen=1 ;;
      TEAM_PREFIX) (( prefix_seen == 0 )) || return 2; RUN_STATE_LOADED_TEAM_PREFIX=$value; prefix_seen=1 ;;
      PRIMARY_CWD) (( cwd_seen == 0 )) || return 2; RUN_STATE_LOADED_CWD=$value; cwd_seen=1 ;;
      WORKSPACE_ID) (( workspace_seen == 0 )) || return 2; RUN_STATE_LOADED_WORKSPACE_ID=$value; workspace_seen=1 ;;
      PLANNER_NAME) (( planner_name_seen == 0 )) || return 2; RUN_STATE_LOADED_PLANNER_NAME=$value; planner_name_seen=1 ;;
      PLANNER_PANE) (( planner_pane_seen == 0 )) || return 2; RUN_STATE_LOADED_PLANNER_PANE=$value; planner_pane_seen=1 ;;
      CODER_NAME) (( coder_name_seen == 0 )) || return 2; RUN_STATE_LOADED_CODER_NAME=$value; coder_name_seen=1 ;;
      CODER_PANE) (( coder_pane_seen == 0 )) || return 2; RUN_STATE_LOADED_CODER_PANE=$value; coder_pane_seen=1 ;;
      REVIEWER_NAME) (( reviewer_name_seen == 0 )) || return 2; RUN_STATE_LOADED_REVIEWER_NAME=$value; reviewer_name_seen=1 ;;
      REVIEWER_PANE) (( reviewer_pane_seen == 0 )) || return 2; RUN_STATE_LOADED_REVIEWER_PANE=$value; reviewer_pane_seen=1 ;;
      ADD_DIR) RUN_STATE_LOADED_ADD_DIRS+=("$value") ;;
      *) return 2 ;;
    esac
  done <<<"$parsed"

  (( run_id_seen && status_seen && mode_seen && prefix_seen && cwd_seen && \
     workspace_seen && planner_name_seen && planner_pane_seen && \
     coder_name_seen && coder_pane_seen && reviewer_name_seen && reviewer_pane_seen )) || return 2
  [[ "$RUN_STATE_LOADED_TEAM_MODE" == "$TEAM_MODE" && \
     "$RUN_STATE_LOADED_TEAM_PREFIX" == "$TEAM_PREFIX_EFFECTIVE" ]] || return 2
  [[ "$RUN_STATE_LOADED_PLANNER_NAME" == "$PLANNER_AGENT" && \
     "$RUN_STATE_LOADED_CODER_NAME" == "$CODER_AGENT" && \
     "$RUN_STATE_LOADED_REVIEWER_NAME" == "$REVIEWER_AGENT" ]] || return 2
}
