#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
TEAM_LIB="$SCRIPT_DIR/lib/team.sh"
JSON_LIB="$SCRIPT_DIR/lib/json.sh"
DIGEST_LIB="$SCRIPT_DIR/lib/digest.sh"
SCOPE_LIB="$SCRIPT_DIR/lib/scope.sh"
RUN_STATE_LIB="$SCRIPT_DIR/lib/run-state.sh"
[[ -f "$TEAM_LIB" && -f "$JSON_LIB" && -f "$DIGEST_LIB" && \
   -f "$SCOPE_LIB" && -f "$RUN_STATE_LIB" ]] || {
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
TEST_TIMEOUT_MS=${HERDR_TEST_TIMEOUT_MS:-120000}
FULL_TIMEOUT_MS=${HERDR_FULL_TEST_TIMEOUT_MS:-1200000}
READ_LINES=${HERDR_TEST_READ_LINES:-2000}
FULL_TEST_ACTIVE_DIR=''
TEAM_CLI_SET=0
TEAM_CLI_PREFIX=''
AGAINST_TEAM_SET=0
AGAINST_TEAM_PREFIX=''
MODE=''

report_preserved_full_test() {
  local status=$?
  if [[ $status -ne 0 && -n "$FULL_TEST_ACTIVE_DIR" && -d "$FULL_TEST_ACTIVE_DIR" ]]; then
    printf 'Live-test workspace preserved for diagnosis: %s\n' "$FULL_TEST_ACTIVE_DIR" >&2
  fi
  exit "$status"
}
trap report_preserved_full_test EXIT

usage() {
  printf '%s\n' \
    'Usage: ./scripts/test.sh [--team PREFIX] [--against-team PREFIX] static|ping|communication|full|policy|isolation' \
    '' \
    '  static         Validate files, shell syntax, role boundaries, and installer safety.' \
    '  ping           External shell -> live coder and reviewer.' \
    '  communication  Live planner -> live coder and reviewer.' \
    '  full           Isolated demo: Planner -> Coder -> Reviewer -> Planner.' \
    '  policy         Adversarial live checks for Planner/Coder/Reviewer role boundaries.' \
    '  isolation      Collect bounded evidence for one same-team Coder route.' \
    '                 Requires --team PREFIX --against-team OTHER_PREFIX.' \
    '' \
    'Without --team or TEAM_PREFIX, live modes target legacy names.' \
    'TEAM_PREFIX may supply the primary prefix when --team is omitted.' \
    '' \
    'Timeout overrides (milliseconds):' \
    '  HERDR_TEST_TIMEOUT_MS=... HERDR_FULL_TEST_TIMEOUT_MS=...' \
    '  HERDR_TEST_READ_LINES=... (terminal rows retained for evidence checks)' \
    '' \
    'Live fixture host override (full/policy):' \
    '  HERDR_TEST_PROJECT_DIR=/path/to/the/project/used-by-the-live-team'
}

die() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

parse_cli() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
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
      --against-team)
        [[ $# -ge 2 ]] || die '--against-team requires a prefix.'
        [[ $AGAINST_TEAM_SET -eq 0 ]] || die '--against-team may be provided only once.'
        AGAINST_TEAM_SET=1
        AGAINST_TEAM_PREFIX=$2
        shift 2
        ;;
      --against-team=*)
        [[ $AGAINST_TEAM_SET -eq 0 ]] || die '--against-team may be provided only once.'
        AGAINST_TEAM_SET=1
        AGAINST_TEAM_PREFIX=${1#--against-team=}
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
        [[ -z "$MODE" ]] || die 'Only one test mode may be provided.'
        MODE=$1
        shift
        ;;
    esac
  done

  [[ -n "$MODE" ]] || { usage >&2; exit 2; }
  case "$MODE" in
    static|ping|communication|full|policy|isolation) ;;
    *) usage >&2; die "Unknown test mode: $MODE" ;;
  esac

  if ! REQUESTED_TEAM_PREFIX=$(team_resolve_requested_prefix "$TEAM_CLI_SET" "$TEAM_CLI_PREFIX"); then
    die 'Could not resolve a single non-empty team prefix.'
  fi
  if ! team_configure "$REQUESTED_TEAM_PREFIX"; then
    die "Invalid team prefix '$REQUESTED_TEAM_PREFIX'. It must match [a-z][a-z0-9_-]* and be at most 23 characters."
  fi

  if [[ "$MODE" == isolation ]]; then
    [[ -n "$REQUESTED_TEAM_PREFIX" ]] || \
      die 'isolation mode requires a prefixed primary team via --team or TEAM_PREFIX.'
    [[ $AGAINST_TEAM_SET -eq 1 && -n "$AGAINST_TEAM_PREFIX" ]] || \
      die 'isolation mode requires --against-team OTHER_PREFIX.'
    team_validate_prefix "$AGAINST_TEAM_PREFIX" || \
      die "Invalid --against-team prefix '$AGAINST_TEAM_PREFIX'."
    [[ "$AGAINST_TEAM_PREFIX" != "$REQUESTED_TEAM_PREFIX" ]] || \
      die '--against-team must identify a different team.'
    AGAINST_PLANNER_AGENT=$(team_name_for_prefix "$AGAINST_TEAM_PREFIX" planner)
    AGAINST_CODER_AGENT=$(team_name_for_prefix "$AGAINST_TEAM_PREFIX" coder)
    AGAINST_REVIEWER_AGENT=$(team_name_for_prefix "$AGAINST_TEAM_PREFIX" reviewer)
  elif [[ $AGAINST_TEAM_SET -eq 1 ]]; then
    die '--against-team is valid only with isolation mode.'
  fi
}

render_team_prompt() {
  local prompt=$1
  local other_planner=${AGAINST_PLANNER_AGENT:-UNUSED_OTHER_PLANNER}
  local other_coder=${AGAINST_CODER_AGENT:-UNUSED_OTHER_CODER}
  local other_reviewer=${AGAINST_REVIEWER_AGENT:-UNUSED_OTHER_REVIEWER}

  prompt=${prompt//'{{PLANNER_AGENT}}'/$PLANNER_AGENT}
  prompt=${prompt//'{{CODER_AGENT}}'/$CODER_AGENT}
  prompt=${prompt//'{{REVIEWER_AGENT}}'/$REVIEWER_AGENT}
  prompt=${prompt//'{{TEAM_PREFIX}}'/$TEAM_DISPLAY}
  prompt=${prompt//'{{OTHER_PLANNER_AGENT}}'/$other_planner}
  prompt=${prompt//'{{OTHER_CODER_AGENT}}'/$other_coder}
  prompt=${prompt//'{{OTHER_REVIEWER_AGENT}}'/$other_reviewer}
  printf '%s' "$prompt"
}

require_uint() {
  [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "$1 must be a positive integer: $2"
}

token_line_count() {
  local token=$1
  awk -v token="$token" '
    BEGIN { count = 0 }
    {
      line = $0
      position = index(line, token)
      if (position == 0) {
        next
      }
      before = substr(line, 1, position - 1)
      after = substr(line, position + length(token))
      if (before !~ /[[:alnum:]_]/ && after !~ /[[:alnum:]_]/) {
        count++
      }
    }
    END { print count }
  '
}

exact_line_count() {
  local expected=$1
  awk -v expected="$expected" '
    BEGIN { count = 0 }
    $0 == expected { count++ }
    END { print count }
  '
}

require_added_exact_line() {
  local before_payload=$1
  local prompt_payload=$2
  local after_payload=$3
  local expected_line=$4
  local before_count
  local prompt_count
  local after_count

  before_count=$(printf '%s\n' "$before_payload" | exact_line_count "$expected_line")
  prompt_count=$(printf '%s\n' "$prompt_payload" | exact_line_count "$expected_line")
  after_count=$(printf '%s\n' "$after_payload" | exact_line_count "$expected_line")
  if (( after_count < before_count + prompt_count + 1 )); then
    printf '%s\n' "$after_payload" >&2
    die "Planner did not add the required exact report line: $expected_line"
  fi
}

response_correlation_block_count() {
  local status_line=$1
  local task_line=$2
  local round_line=$3
  local handoff_line=$4
  local token_line=$5
  awk \
    -v status_line="$status_line" \
    -v task_line="$task_line" \
    -v round_line="$round_line" \
    -v handoff_line="$handoff_line" \
    -v token_line="$token_line" '
      BEGIN { state = 0; count = 0 }
      {
        if (state == 0) {
          if ($0 == status_line) state = 1
        } else if (state == 1) {
          if ($0 == task_line) state = 2
          else state = ($0 == status_line ? 1 : 0)
        } else if (state == 2) {
          if ($0 == round_line) state = 3
          else state = ($0 == status_line ? 1 : 0)
        } else if (state == 3) {
          if ($0 == handoff_line) state = 4
          else state = ($0 == status_line ? 1 : 0)
        } else if (state == 4) {
          if ($0 == token_line) count++
          state = ($0 == status_line ? 1 : 0)
        }
      }
      END { print count }
    '
}

require_response_correlation_block() {
  local payload=$1
  local status_line=$2
  local task_id=$3
  local round=$4
  local handoff_id=$5
  local token_line=$6
  local label=$7
  local count

  count=$(printf '%s\n' "$payload" | response_correlation_block_count \
    "$status_line" "TASK_ID: $task_id" "ROUND: $round" \
    "HANDOFF_ID: $handoff_id" "$token_line")
  if (( count != 1 )); then
    printf '%s\n' "$payload" >&2
    die "$label emitted $count matching status/correlation/derived-token blocks; exactly one is required."
  fi
}

run_token() {
  printf '%s_%s_%s' "$1" "$(date '+%s')" "$$"
}

process_uses_profile() {
  local payload=$1
  local role=$2

  json_process_uses_profile "$payload" "$role"
}

terminal_response_lines() {
  # Codex renders a bullet on the first reply line and indents its continuation.
  sed -E 's/^(• |  )//'
}

read_agent() {
  local role=$1
  local live_name
  live_name=$(team_agent_for_role "$role") || die "Unknown role: $role"
  herdr agent read "$live_name" --source recent-unwrapped --lines "$READ_LINES" 2>/dev/null | terminal_response_lines || true
}

read_full_evidence() {
  local role=$1 live_name payload status
  live_name=$(team_agent_for_role "$role") || die "Unknown role: $role"
  payload=$(herdr agent get "$live_name") || die "Cannot resolve live $role."
  # Codex's full-screen renderer can omit the first lines of a completed reply.
  # Read the native final messages from this pane's verified chat for this run.
  if PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$SCRIPT_DIR" python3 - "$payload" "$role" "$FULL_TIMEOUT_MS" "$2" "$3" "$4" <<'PY'
import json, os, subprocess, sys, time
from pathlib import Path
from herdr_mcp import active_thread, codex_turn_cursor

agent = json.loads(sys.argv[1])["result"]["agent"]
if agent["agent"] != "codex":
    sys.exit(3)
agent["thread_id"] = active_thread(agent, lambda pane: subprocess.check_output(
    ["herdr", "agent", "read", pane, "--source", "visible", "--lines", "12"], text=True))
cursor = codex_turn_cursor(os.environ.get("CODEX_HOME", Path.home() / ".codex"), agent)
if not cursor:
    sys.exit(3)
with cursor[0].open("rb") as stream:
    seen = False
    deadline = time.monotonic() + int(sys.argv[3]) / 1000
    while True:
        pos = stream.tell()
        line = stream.readline()
        if not line.endswith(b"\n"):
            # The Planner's terminal can render its last token before Codex
            # flushes task_complete. Both worker turns have already finished.
            if seen or sys.argv[2] != "planner" or time.monotonic() >= deadline:
                break
            stream.seek(pos)
            time.sleep(0.1)
            continue
        event = json.loads(line)
        p = event["payload"]
        if event["type"] == "event_msg" and p.get("type") == "task_complete":
            reply = p.get("last_agent_message") or ""
            if any(marker in reply for marker in sys.argv[4:]):
                print(reply)
                seen = True
PY
  then
    return 0
  else
    status=$?
  fi
  [[ $status == 3 ]] || die "Could not verify this run's $role conversation."
  read_agent "$role"
}

read_named_agent_strict() {
  local live_name=$1
  local payload

  if ! payload=$(herdr agent read "$live_name" \
      --source recent-unwrapped --lines "$READ_LINES" 2>&1); then
    printf '%s\n' "$payload" >&2
    die "Could not read retained transcript for live '$live_name'."
  fi
  printf '%s\n' "$payload" | terminal_response_lines
}

require_named_runtime() {
  local role=$1
  local live_name_expected=$2
  local payload
  local live_name
  local agent_kind
  local agent_status
  local interactive_ready
  local launch_pending
  local pane_id
  local workspace_id
  local state_change_seq
  local process_payload

  command -v herdr >/dev/null 2>&1 || die 'Herdr was not found in PATH.'
  if ! server_status=$(herdr status server 2>&1); then
    printf '%s\n' "$server_status" >&2
    die 'Herdr server is not reachable. Start or attach Herdr first.'
  fi
  if ! payload=$(herdr agent get "$live_name_expected" 2>&1); then
    die "Live Herdr agent '$live_name_expected' was not found. Start the requested team first."
  fi
  if ! live_name=$(json_agent_required_string "$payload" name) || \
     ! agent_kind=$(json_agent_required_string "$payload" agent) || \
     ! agent_status=$(json_agent_required_string "$payload" agent_status) || \
     ! interactive_ready=$(json_agent_required_boolean "$payload" interactive_ready) || \
     ! launch_pending=$(json_agent_boolean_or_false_if_absent "$payload" launch_pending) || \
     ! pane_id=$(json_agent_required_string "$payload" pane_id) || \
     ! workspace_id=$(json_agent_required_string "$payload" workspace_id) || \
     ! state_change_seq=$(json_agent_field "$payload" state_change_seq); then
    die "Live '$live_name_expected' reported malformed identity or lifecycle fields."
  fi
  [[ "$live_name" == "$live_name_expected" ]] || \
    die "Target '$live_name_expected' resolved to unexpected live name '${live_name:-unknown}'."
  [[ "$agent_kind" == codex || "$agent_kind" == claude || "$agent_kind" == agy ]] || \
    die "Live name '$live_name_expected' has unsupported agent kind '${agent_kind:-unknown}'."
  [[ -n "$pane_id" ]] || die "Live '$live_name_expected' did not expose its pane ID."
  [[ -n "$workspace_id" ]] || die "Live '$live_name_expected' did not expose its workspace ID."
  [[ "$state_change_seq" =~ ^[0-9]+$ ]] || \
    die "Live '$live_name_expected' did not expose a numeric state_change_seq."
  if ! process_payload=$(herdr pane process-info --pane "$pane_id" 2>&1); then
    printf '%s\n' "$process_payload" >&2
    die "Could not inspect the foreground process for live '$live_name_expected'."
  fi
  team_process_policy "$process_payload" "$role" "$agent_kind" || \
    die "Live '$live_name_expected' does not expose its managed $role configuration. Restart it through start.sh."
  [[ "$interactive_ready" == 'true' && "$launch_pending" == 'false' ]] || \
    die "Live '$live_name_expected' is not interactively ready (ready=${interactive_ready:-unknown}, launch_pending=${launch_pending:-unknown})."
  case "$agent_status" in
    idle|done) ;;
    *) die "Live '$live_name_expected' must be settled before testing; current state is '${agent_status:-unknown}'." ;;
  esac
  REQUIRED_AGENT_WORKSPACE=$workspace_id
  REQUIRED_AGENT_PANE=$pane_id
  REQUIRED_AGENT_STATE_CHANGE_SEQ=$state_change_seq
}

require_runtime() {
  local role
  local live_name
  local expected_workspace=''

  for role in "$@"; do
    live_name=$(team_agent_for_role "$role") || die "Unknown role: $role"
    require_named_runtime "$role" "$live_name"
    if [[ -z "$expected_workspace" ]]; then
      expected_workspace=$REQUIRED_AGENT_WORKSPACE
    elif [[ "$REQUIRED_AGENT_WORKSPACE" != "$expected_workspace" ]]; then
      die "Live '$live_name' is in workspace $REQUIRED_AGENT_WORKSPACE, not same-team workspace $expected_workspace."
    fi
  done
  TEAM_RUNTIME_WORKSPACE=$expected_workspace
}

require_agents_cover_host() {
  local host_dir=$1
  local host_git_root=$2
  local role
  local live_name
  local payload
  local agent_cwd
  local foreground_cwd
  local primary_git_root
  local primary_git_status
  local cwd_evidence_count
  local candidate

  host_dir=$(scope_physical_dir "$host_dir") || \
    die "Full-test host cannot be resolved safely: $host_dir"
  host_git_root=$(scope_physical_dir "$host_git_root") || \
    die "Full-test Git root cannot be resolved safely: $host_git_root"

  for role in planner coder reviewer; do
    live_name=$(team_agent_for_role "$role")
    payload=$(herdr agent get "$live_name" 2>&1)
    if ! agent_cwd=$(json_agent_optional_string "$payload" cwd) || \
       ! foreground_cwd=$(json_agent_optional_string "$payload" foreground_cwd); then
      die "Live '$live_name' reported malformed cwd fields."
    fi
    [[ -n "$agent_cwd" ]] || \
      die "Live '$live_name' did not expose its primary cwd for the Git-backed live-test host."
    agent_cwd=$(scope_physical_dir "$agent_cwd") || \
      die "Live '$live_name' reported a primary cwd that cannot be resolved safely."
    if primary_git_root=$(scope_git_root "$agent_cwd"); then
      :
    else
      primary_git_status=$?
      if [[ $primary_git_status -eq 1 ]]; then
        die "Live '$live_name' primary cwd is non-Git; full and policy tests require the team's primary cwd to be Git-backed."
      fi
      die "Live '$live_name' primary cwd Git scope could not be verified safely."
    fi
    [[ "$primary_git_root" -ef "$host_git_root" ]] || \
      die "Live '$live_name' primary cwd is not in the full-test host Git worktree '$host_git_root'."
    cwd_evidence_count=0
    for candidate in "$foreground_cwd" "$agent_cwd"; do
      [[ -n "$candidate" ]] || continue
      cwd_evidence_count=$((cwd_evidence_count + 1))
      [[ -d "$candidate" ]] || \
        die "Live '$live_name' reported a cwd that does not exist: $candidate"
      candidate=$(scope_physical_dir "$candidate") || \
        die "Live '$live_name' reported a cwd that cannot be resolved safely."
      [[ "$candidate" != '/' ]] || \
        die "Live '$live_name' reported the filesystem root as cwd."
      scope_is_same_or_descendant "$host_dir" "$candidate" || \
        die "Live '$live_name' cwd '$candidate' does not cover the full-test host '$host_dir'."
    done
    [[ $cwd_evidence_count -gt 0 ]] || \
      die "Live '$live_name' did not expose cwd or foreground_cwd for the full-test host."
  done
}

prompt_and_wait() {
  local role=$1
  local prompt=$2
  local timeout=$3
  shift 3
  local live_name
  local result

  live_name=$(team_agent_for_role "$role") || die "Unknown role: $role"

  # Herdr does not bind --wait to a turn when the target is already working.
  # Fail closed immediately before submission, then verify again afterward.
  require_named_runtime "$role" "$live_name"
  if ! result=$(herdr agent prompt "$live_name" "$prompt" --wait --timeout "$timeout" 2>&1); then
    printf '%s\n' "$result" >&2
    die "Herdr prompt to '$live_name' failed. Inspect with: herdr agent get $live_name"
  fi
  if (( $# )); then
    # After /resume a transient idle event can precede the actual turn.
    herdr pane wait-output "$REQUIRED_AGENT_PANE" "$@" \
      --source recent-unwrapped --lines 60 --timeout "$timeout" >/dev/null || \
      die "The live $role pane did not show the expected turn result: $*"
    herdr agent wait "$live_name" --until done --until idle --timeout "$timeout" >/dev/null || \
      die "The live $role pane did not settle after returning its result."
  fi
  printf '%s\n' "$result"
  require_named_runtime "$role" "$live_name"
}

run_static() {
  local required
  local temporary_root
  local codex_test_dir
  local install_log
  local invalid_install_log
  local start_log
  local invalid_timeout
  local expected_timeout_error
  local process_fixture
  local backup_dir
  local uninstall_backup
  local max_prefix
  local generated_name
  local mock_bin
  local collision_log
  local workspace_marker
  local race_log
  local malformed_log
  local malformed_workspace_marker
  local shared_worktree_log
  local shared_worktree_marker
  local uninspectable_worktree_log
  local uninspectable_worktree_marker
  local malformed_kind
  local malformed_kind_log
  local malformed_kind_marker
  local separate_worktree_log
  local separate_worktree_marker
  local separate_git_root
  local mixed_worktree_log
  local mixed_worktree_marker
  local ancestor_worktree_log
  local ancestor_worktree_marker
  local root_worktree_log
  local root_worktree_marker
  local doctor_log
  local doctor_call_log
  local tampered_start_log
  local tampered_start_marker
  local unsafe_profile_start_log
  local unsafe_profile_start_marker
  local stale_policy_start_log
  local stale_policy_start_marker
  local herdr_call_log
  local split_counter
  local parse_log
  local startup_lock_log
  local startup_lock_marker
  local state_file
  local state_doctor_log
  local state_doctor_calls
  local legacy_state_file
  local prefixed_legacy_state_file
  local unsafe_state_marker
  local unsafe_state_log
  local invalid_utf8_value
  local partial_root_marker
  local partial_root_log
  local state_symlink_codex
  local state_symlink_target
  local state_line
  local invalid_state_byte
  local lock_host
  local held_lock_token

  required='README.md
README.zh-CN.md
CHANGELOG.md
LICENSE
.gitignore
profiles/planner.config.toml
profiles/coder.config.toml
profiles/reviewer.config.toml
prompts/planner.md
prompts/coder.md
prompts/reviewer.md
scripts/install.sh
scripts/herdr_mcp.py
scripts/doctor.sh
scripts/start.sh
scripts/test.sh
scripts/uninstall.sh
scripts/open.sh
scripts/remote.sh
scripts/lib/team.sh
scripts/lib/json.sh
scripts/lib/digest.sh
scripts/lib/scope.sh
scripts/lib/run-state.sh
scripts/lib/remote-bootstrap.sh
tests/remote-launcher.sh
tests/test_herdr_mcp.py
tests/prompts/01-coder-ping.md
tests/prompts/02-reviewer-ping.md
tests/prompts/03-planner-to-coder.md
tests/prompts/04-planner-to-reviewer.md
tests/prompts/05-full-loop.md
tests/prompts/06-multi-team-routing.md
tests/prompts/07-reviewer-policy.md
tests/prompts/08-coder-policy.md
tests/prompts/09-planner-policy.md
tests/fixtures/full-loop/.gitignore
tests/fixtures/full-loop/calculator.py
tests/fixtures/full-loop/test_calculator.py
docs/architecture.md
docs/installation.md
docs/workflow.md
docs/configuration.md
docs/troubleshooting.md
docs/security.md
docs/launch-state.md
docs/omx-comparison.md'
  required="$required
docs/multi-team.md
docs/zh-CN/architecture.md
docs/zh-CN/configuration.md
docs/zh-CN/installation.md
docs/zh-CN/multi-team.md
docs/zh-CN/security.md
docs/zh-CN/troubleshooting.md
docs/zh-CN/workflow.md
docs/zh-CN/launch-state.md
docs/zh-CN/omx-comparison.md
examples/multi-team.md"

  while IFS= read -r path; do
    [[ -f "$PROJECT_ROOT/$path" ]] || die "Required file is missing: $path"
  done <<<"$required"

  for script in "$PROJECT_ROOT"/scripts/*.sh; do
    bash -n "$script"
  done
  bash -n "$TEAM_LIB"
  bash -n "$JSON_LIB"
  bash -n "$SCRIPT_DIR/lib/digest.sh"
  bash -n "$SCOPE_LIB"
  bash -n "$RUN_STATE_LIB"
  "$PROJECT_ROOT/tests/remote-launcher.sh"
  PYTHONDONTWRITEBYTECODE=1 python3 "$PROJECT_ROOT/scripts/herdr_mcp.py" --check >/dev/null
  PYTHONDONTWRITEBYTECODE=1 python3 -m unittest "$PROJECT_ROOT/tests/test_herdr_mcp.py"
  printf '[OK] Shell syntax\n'

  for read_only_role in planner reviewer; do
    grep -Eq '^default_permissions[[:space:]]*=[[:space:]]*"herdr_read_only_network"[[:space:]]*$' \
      "$PROJECT_ROOT/profiles/$read_only_role.config.toml" || \
      die "$read_only_role template does not select the read-only network permission profile."
    grep -Eq '^permissions[.]herdr_read_only_network[.]extends[[:space:]]*=[[:space:]]*":read-only"[[:space:]]*$' \
      "$PROJECT_ROOT/profiles/$read_only_role.config.toml" || \
      die "$read_only_role template is not locally read-only."
    grep -Eq '^permissions[.]herdr_read_only_network[.]network[.]enabled[[:space:]]*=[[:space:]]*true[[:space:]]*$' \
      "$PROJECT_ROOT/profiles/$read_only_role.config.toml" || \
      die "$read_only_role template does not enable command network access."
  done
  grep -Eq '^default_permissions[[:space:]]*=[[:space:]]*"herdr_workspace_network"[[:space:]]*$' \
    "$PROJECT_ROOT/profiles/coder.config.toml" || \
    die 'Coder template does not select the workspace network permission profile.'
  grep -Eq '^permissions[.]herdr_workspace_network[.]extends[[:space:]]*=[[:space:]]*":workspace"[[:space:]]*$' \
    "$PROJECT_ROOT/profiles/coder.config.toml" || \
    die 'Coder template is not workspace-write.'
  grep -Eq '^permissions[.]herdr_workspace_network[.]network[.]enabled[[:space:]]*=[[:space:]]*true[[:space:]]*$' \
    "$PROJECT_ROOT/profiles/coder.config.toml" || \
    die 'Coder template does not enable command network access.'
  grep -Eq '^shell_environment_policy[.]set[.]PYTHONDONTWRITEBYTECODE[[:space:]]*=[[:space:]]*"1"[[:space:]]*$' \
    "$PROJECT_ROOT/profiles/reviewer.config.toml" || \
    die 'Reviewer template does not suppress Python bytecode writes.'
  grep -Eq '^shell_environment_policy[.]set[.]PYTEST_ADDOPTS[[:space:]]*=[[:space:]]*"--capture=sys -p no:cacheprovider"[[:space:]]*$' \
    "$PROJECT_ROOT/profiles/reviewer.config.toml" || \
    die 'Reviewer template does not select read-only-safe pytest capture and cache settings.'
  for role in planner coder reviewer; do
    grep -Eq '^approval_policy[[:space:]]*=[[:space:]]*"never"[[:space:]]*$' \
      "$PROJECT_ROOT/profiles/$role.config.toml" || \
      die "$role template does not set approval_policy = \"never\"."
    grep -Eq '^agents[.]enabled[[:space:]]*=[[:space:]]*false[[:space:]]*$' \
      "$PROJECT_ROOT/profiles/$role.config.toml" || \
      die "$role template does not disable Codex-native multi-agent tools."
  done
  if grep -Eq '^sandbox_mode[[:space:]]*=' "$PROJECT_ROOT"/profiles/*.config.toml; then
    die 'A role profile still mixes legacy sandbox_mode with beta permission profiles.'
  fi
  grep -Fq 'mcp_servers.herdr_codex_team.command = ' "$PROJECT_ROOT/profiles/planner.config.toml" || \
    die 'Planner template lacks the managed Herdr MCP bridge.'
  grep -Fxq 'mcp_servers.herdr_codex_team.command = "__HERDR_CODEX_TEAM_PYTHON__"' \
    "$PROJECT_ROOT/profiles/planner.config.toml" || \
    die 'Planner template lacks the install-time absolute Python placeholder.'
  grep -Fxq 'mcp_servers.herdr_codex_team.args = ["__HERDR_CODEX_TEAM_BRIDGE__"]' \
    "$PROJECT_ROOT/profiles/planner.config.toml" || \
    die 'Planner template lacks the install-time absolute bridge placeholder.'
  grep -Fq '  "HERDR_BIN_PATH",' "$PROJECT_ROOT/profiles/planner.config.toml" || \
    die 'Planner template does not forward Herdr trusted binary identity.'
  if grep -Eq 'command[[:space:]]*=[[:space:]]*"/bin/sh"|exec[[:space:]]+python3' \
       "$PROJECT_ROOT/profiles/planner.config.toml"; then
    die 'Planner template still selects a sandbox-external executable through PATH.'
  fi
  grep -Fq 'mcp_servers.herdr_codex_team.enabled_tools = ["inspect_team", "prompt_agent"]' "$PROJECT_ROOT/profiles/planner.config.toml" || \
    die 'Planner Herdr MCP bridge does not expose the exact bounded tool list.'
  grep -Eq '^mcp_servers\.herdr_codex_team\.required[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$PROJECT_ROOT/profiles/planner.config.toml" || \
    die 'Planner Herdr MCP bridge is not required at startup.'
  for peer_profile in coder reviewer; do
    if grep -Fq 'mcp_servers.herdr_codex_team.' "$PROJECT_ROOT/profiles/$peer_profile.config.toml"; then
      die "$peer_profile template must not receive the Planner Herdr MCP bridge."
    fi
  done
  grep -Fq 'HERDR COMMUNICATION IS MANDATORY' "$PROJECT_ROOT/prompts/planner.md" || \
    die 'Planner prompt lacks the mandatory Herdr guardrail.'
  grep -Fq 'HERDR TEAM IDENTITY AND ROUTING' "$PROJECT_ROOT/prompts/planner.md" || \
    die 'Planner prompt lacks explicit runtime team identity and routing rules.'
  grep -Fq 'STRICT TEAM ISOLATION' "$PROJECT_ROOT/prompts/planner.md" || \
    die 'Planner prompt lacks the strict team-isolation guardrail.'
  grep -Fq 'HERDR_PANE_ID' "$PROJECT_ROOT/prompts/planner.md" || \
    die 'Planner prompt does not derive identity from its Herdr pane.'
  grep -Fq 'mcp__herdr_codex_team__inspect_team' "$PROJECT_ROOT/prompts/planner.md" || \
    die 'Planner prompt does not require the managed identity tool.'
  grep -Fq 'mcp__herdr_codex_team__prompt_agent' "$PROJECT_ROOT/prompts/planner.md" || \
    die 'Planner prompt does not require the managed role-only prompt tool.'
  grep -Fq 'HERDR_COMMUNICATION_FAILED' "$PROJECT_ROOT/prompts/planner.md" || \
    die 'Planner prompt lacks the mandatory Herdr failure result.'
  grep -Fq 'Allow at most 4 review rounds total.' "$PROJECT_ROOT/prompts/planner.md" || \
    die 'Planner prompt does not clearly cap the loop at 4 rounds.'
  grep -Fq 'keep it unchanged through final acceptance' "$PROJECT_ROOT/prompts/planner.md" || \
    die 'Planner prompt does not require one stable TASK_ID.'
  grep -Fq 'generate a fresh non-empty `HANDOFF_ID`' "$PROJECT_ROOT/prompts/planner.md" || \
    die 'Planner prompt does not require a fresh HANDOFF_ID per handoff.'
  grep -Fq 'Missing, reordered, duplicated, stale, or mismatched correlation fields are a hard failure' \
    "$PROJECT_ROOT/prompts/planner.md" || \
    die 'Planner prompt does not fail closed on handoff-correlation mismatch.'
  for role in planner coder reviewer; do
    grep -Fq 'TASK_ID:' "$PROJECT_ROOT/prompts/$role.md" || \
      die "$role prompt lacks TASK_ID correlation."
    grep -Fq 'ROUND:' "$PROJECT_ROOT/prompts/$role.md" || \
      die "$role prompt lacks ROUND correlation."
    grep -Fq 'HANDOFF_ID:' "$PROJECT_ROOT/prompts/$role.md" || \
      die "$role prompt lacks HANDOFF_ID correlation."
    grep -Fq 'communication-test exception remains token-only' "$PROJECT_ROOT/prompts/$role.md" || \
      die "$role prompt does not preserve the token-only communication-test exception."
  done
  grep -Eq '^model[[:space:]]*=[[:space:]]*"gpt-6\.2-sol"[[:space:]]*$' \
    "$PROJECT_ROOT/profiles/coder.config.toml" || \
    die 'Coder template does not default to gpt-6.2-sol.'
  grep -Eq '^model_reasoning_effort[[:space:]]*=[[:space:]]*"xhigh"[[:space:]]*$' \
    "$PROJECT_ROOT/profiles/coder.config.toml" || \
    die 'Coder template does not default to xhigh reasoning effort.'
  [[ $(find "$PROJECT_ROOT/profiles" -maxdepth 1 -type f -name '*.config.toml' | wc -l | tr -d ' ') -eq 3 ]] || \
    die 'The installer architecture must retain exactly three generic role profile templates.'
  [[ $(grep -Foc 'PLANNER_TO_CODER_CHALLENGE' "$PROJECT_ROOT/tests/prompts/03-planner-to-coder.md") -eq 1 ]] || \
    die 'Planner-to-Coder prompt must contain exactly one challenge placeholder.'
  [[ $(grep -Foc 'PLANNER_TO_REVIEWER_CHALLENGE' "$PROJECT_ROOT/tests/prompts/04-planner-to-reviewer.md") -eq 1 ]] || \
    die 'Planner-to-Reviewer prompt must contain exactly one challenge placeholder.'
  if grep -Fq 'PLANNER_TO_CODER_OK' "$PROJECT_ROOT/tests/prompts/03-planner-to-coder.md" || \
     grep -Fq 'PLANNER_TO_REVIEWER_OK' "$PROJECT_ROOT/tests/prompts/04-planner-to-reviewer.md"; then
    die 'A mediated prompt contains its complete expected response instead of a challenge.'
  fi
  [[ $(grep -Foc 'MULTI_TEAM_ROUTING_CHALLENGE' "$PROJECT_ROOT/tests/prompts/06-multi-team-routing.md") -eq 1 ]] || \
    die 'Multi-team prompt must contain exactly one routing challenge placeholder.'
  if grep -Fq 'MULTI_TEAM_ROUTING_OK' "$PROJECT_ROOT/tests/prompts/06-multi-team-routing.md"; then
    die 'Multi-team prompt contains the complete derived response instead of only a challenge.'
  fi
  for policy_fixture in \
    07-reviewer-policy.md \
    08-coder-policy.md \
    09-planner-policy.md; do
    [[ $(grep -Foc '{{POLICY_CHALLENGE}}' "$PROJECT_ROOT/tests/prompts/$policy_fixture") -eq 1 ]] || \
      die "$policy_fixture must contain exactly one policy challenge placeholder."
    grep -Fq 'not a communication test' "$PROJECT_ROOT/tests/prompts/$policy_fixture" || \
      die "$policy_fixture could accidentally use the token-only communication exception."
  done

  [[ $(team_name_for_prefix '' planner) == planner ]] || \
    die 'Legacy Planner name derivation failed.'
  [[ $(team_name_for_prefix github coder) == github-coder ]] || \
    die 'Prefixed Coder name derivation failed.'
  [[ $(team_name_for_prefix github reviewer) == github-reviewer ]] || \
    die 'Prefixed Reviewer name derivation failed.'
  grep -Fq 'workspace_label="codex-team:$project_name"' "$PROJECT_ROOT/scripts/start.sh" || \
    die 'Legacy workspace label no longer uses the project directory name.'
  grep -Fq 'workspace_label="codex-team:$TEAM_DISPLAY"' "$PROJECT_ROOT/scripts/start.sh" || \
    die 'Prefixed workspace label no longer uses only the team prefix.'
  if grep -Fq 'workspace_label="codex-team:$TEAM_DISPLAY:$project_name"' \
       "$PROJECT_ROOT/scripts/start.sh"; then
    die 'Prefixed workspace label still repeats the project directory name.'
  fi
  [[ $(team_role_from_live_name reviewer) == reviewer ]] || \
    die 'Legacy role-agent recognition failed.'
  [[ $(team_role_from_live_name docs-coder) == coder ]] || \
    die 'Prefixed role-agent recognition failed.'
  if team_role_from_live_name not-a-role >/dev/null 2>&1; then
    die 'An unrelated live agent name was classified as a Herdr team role.'
  fi
  max_prefix='abcdefghijklmnopqrstuvw'
  [[ ${#max_prefix} -eq 23 ]] || die 'Static maximum-prefix fixture is malformed.'
  team_validate_prefix "$max_prefix" || die 'A valid 23-character prefix was rejected.'
  generated_name=$(team_name_for_prefix "$max_prefix" reviewer)
  [[ ${#generated_name} -eq 32 ]] || die 'Maximum generated Herdr name is not 32 characters.'
  if team_validate_prefix ''; then
    die 'An empty team prefix was accepted.'
  fi
  for invalid_prefix in Ateam 1team 'bad.team' 'bad/team' 'bad team' 'bad$(id)' abcdefghijklmnopqrstuvwx; do
    if team_validate_prefix "$invalid_prefix"; then
      die "Invalid team prefix was accepted: $invalid_prefix"
    fi
  done
  if TEAM_PREFIX=auth team_resolve_requested_prefix 1 github >/dev/null 2>&1; then
    die 'Conflicting --team and TEAM_PREFIX values were accepted.'
  fi
  [[ $(TEAM_PREFIX=github team_resolve_requested_prefix 1 github) == github ]] || \
    die 'Matching --team and TEAM_PREFIX values were rejected.'
  printf '[OK] Legacy/prefixed team naming and boundary validation\n'
  process_fixture='{"result":{"process_info":{"foreground_processes":[{"pid":101,"name":"codex","argv0":"/usr/local/bin/codex","argv":["codex","--profile","planner"]}]}}}'
  process_uses_profile "$process_fixture" planner || \
    die 'Process/profile binding parser rejected a valid fixture.'
  if process_uses_profile "$process_fixture" reviewer; then
    die 'Process/profile binding parser accepted the wrong role.'
  fi
  agent_field_fixture='{"result":{"agent":{"name":"github-planner","cwd":"/tmp/safe\n"}}}'
  if json_agent_optional_string "$agent_field_fixture" cwd >/dev/null 2>&1; then
    die 'Optional agent-string parser accepted a trailing line feed.'
  fi
  if json_agent_field "$agent_field_fixture" cwd >/dev/null 2>&1; then
    die 'Generic agent-field parser accepted a trailing line feed.'
  fi
  agent_field_fixture='{"result":{"agent":{"name":"github-planner\n"}}}'
  if json_agent_required_string "$agent_field_fixture" name >/dev/null 2>&1; then
    die 'Required agent-string parser accepted a trailing line feed.'
  fi
  agent_field_fixture='{"result":{"agent":{"name":"github-planner\u0085","cwd":"/tmp/safe\u0085"}}}'
  if json_agent_optional_string "$agent_field_fixture" cwd >/dev/null 2>&1 || \
     json_agent_field "$agent_field_fixture" cwd >/dev/null 2>&1 || \
     json_agent_required_string "$agent_field_fixture" name >/dev/null 2>&1; then
    die 'Agent string parsers accepted a Unicode C1 control character.'
  fi
  object_field_fixture='{"result":{"workspace":{"workspace_id":"mock\u0085"}}}'
  if json_object_string "$object_field_fixture" workspace workspace_id >/dev/null 2>&1; then
    die 'Object-string parser accepted a Unicode C1 control character.'
  fi
  agent_names_fixture='{"result":{"agents":[{"name":"github-planner\u0085"}]}}'
  if json_agent_names "$agent_names_fixture" >/dev/null 2>&1; then
    die 'Agent-name parser accepted a Unicode C1 control character.'
  fi
  prompt_fixture='[{"type":"message","content":[{"type":"input_text","text":"<permissions instructions>\nFilesystem sandboxing defines which files can be read or written. `sandbox_mode` is `read-only`: local read only. Network access is enabled.\n</permissions instructions>"}]}]'
  json_prompt_has_effective_role_permissions "$prompt_fixture" planner || \
    die 'Effective-permission parser rejected read-only local access with networking enabled.'
  json_prompt_has_effective_role_permissions "$prompt_fixture" reviewer || \
    die 'Effective-permission parser rejected the Reviewer read-only network policy.'
  if json_prompt_has_effective_role_permissions "$prompt_fixture" coder; then
    die 'Effective-permission parser accepted the wrong filesystem boundary.'
  fi
  prompt_fixture='[{"type":"message","content":[{"type":"input_text","text":"<permissions instructions>\n`sandbox_mode` is `read-only`. Network access is restricted.\n</permissions instructions>"}]}]'
  if json_prompt_has_effective_role_permissions "$prompt_fixture" planner; then
    die 'Effective-permission parser accepted restricted command networking.'
  fi
  prompt_fixture='[{"type":"message","content":[{"type":"input_text","text":"<environment_context><filesystem><workspace_roots><root>/tmp/primary</root><root>/tmp/extra</root></workspace_roots></filesystem></environment_context>"}]}]'
  json_prompt_has_role_workspace_roots \
    "$prompt_fixture" planner /tmp/primary /tmp/extra || \
    die 'Workspace-root parser rejected exact Planner multi-root context.'
  json_prompt_has_role_workspace_roots \
    "$prompt_fixture" coder /tmp/primary /tmp/extra || \
    die 'Workspace-root parser rejected exact Coder multi-root context.'
  if json_prompt_has_role_workspace_roots \
       "$prompt_fixture" reviewer /tmp/primary /tmp/extra; then
    die 'Workspace-root parser accepted an additional Reviewer root.'
  fi
  prompt_fixture='[{"type":"message","content":[{"type":"input_text","text":"<environment_context><filesystem><workspace_roots><root>/tmp/primary</root></workspace_roots></filesystem></environment_context>"}]}]'
  json_prompt_has_role_workspace_roots \
    "$prompt_fixture" reviewer /tmp/primary /tmp/extra || \
    die 'Workspace-root parser rejected primary-only Reviewer context.'
  process_fixture='{"result":{"process_info":{"foreground_processes":[{"pid":101,"name":"codex","argv0":"/usr/local/bin/codex","argv":["codex","--profile","coder","-c","agents.enabled=false","-c","default_permissions=\"herdr_workspace_network\"","-c","permissions.herdr_workspace_network.extends=\":workspace\"","-c","permissions.herdr_workspace_network.network.enabled=true","--add-dir","/tmp/root with spaces","--add-dir=/tmp/root-two"]}]}}}'
  json_process_has_managed_scope "$process_fixture" coder || \
    die 'Managed-scope parser rejected the exact native-agent and network-permission markers.'
  [[ $(json_process_codex_add_dirs "$process_fixture") == $'/tmp/root with spaces\n/tmp/root-two' ]] || \
    die 'Structured add-dir parser did not preserve repeated paths and spaces.'
  process_fixture='{"result":{"process_info":{"foreground_processes":[{"pid":101,"name":"codex","argv":["codex","--profile","planner","-c","agents.enabled=false","-c","default_permissions=\"herdr_read_only_network\"","-c","permissions.herdr_read_only_network.extends=\":read-only\"","-c","permissions.herdr_read_only_network.network.enabled=true"]}]}}}'
  json_process_has_managed_scope "$process_fixture" planner || \
    die 'Managed-scope parser rejected the read-only network permission argv.'
  process_fixture='{"result":{"process_info":{"foreground_processes":[{"pid":101,"name":"codex","argv":["codex","--profile","coder","-c","agents.enabled=false","-c","default_permissions=\"herdr_workspace_network\"","-c","permissions.herdr_workspace_network.extends=\":workspace\""]}]}}}'
  if json_process_has_managed_scope "$process_fixture" coder; then
    die 'Managed-scope parser accepted a missing network-enabled marker.'
  fi
  process_fixture='{"result":{"process_info":{"foreground_processes":[{"pid":101,"name":"codex","argv":["codex","--profile","coder","-c","agents.enabled=false","-c","default_permissions=\"herdr_workspace_network\"","-c","permissions.herdr_workspace_network.extends=\":workspace\"","-c","permissions.herdr_workspace_network.network.enabled=false"]}]}}}'
  if json_process_has_managed_scope "$process_fixture" coder; then
    die 'Managed-scope parser accepted disabled command networking.'
  fi
  process_fixture='{"result":{"process_info":{"foreground_processes":[{"pid":101,"name":"codex","argv":["codex","--profile","coder","-c","agents.enabled=false","-c","default_permissions=\"herdr_workspace_network\"","-c","permissions.herdr_workspace_network.extends=\":workspace\"","-c","permissions.herdr_workspace_network.network.enabled=true","--sandbox","workspace-write"]}]}}}'
  if json_process_has_managed_scope "$process_fixture" coder; then
    die 'Managed-scope parser accepted a legacy sandbox override that suppresses permission-profile networking.'
  fi
  process_fixture='{"result":{"process_info":{"foreground_processes":[{"pid":101,"name":"codex","argv":["codex","-c","sandbox_workspace_write.writable_roots=[]","--sandbox","workspace-write"]}]}}}'
  if json_process_has_managed_scope "$process_fixture" coder; then
    die 'Managed-scope parser accepted a process that still exposes native Codex agents.'
  fi
  process_fixture='{"result":{"process_info":{"foreground_processes":[{"pid":101,"name":"codex","argv":["codex","-c","sandbox_workspace_write.writable_roots=[]","-c","agents.enabled=false","-c","sandbox_workspace_write.writable_roots=[\\"/tmp/hidden\\"]","--sandbox","workspace-write"]}]}}}'
  if json_process_has_managed_scope "$process_fixture" coder; then
    die 'Managed-scope parser accepted a second writable_roots override.'
  fi
  process_fixture='{"result":{"process_info":{"foreground_processes":[{"pid":101,"name":"codex","argv":["codex","-c","sandbox_workspace_write.writable_roots=[]","-c","agents.enabled=false","-c","sandbox_workspace_write . writable_roots = [\\"/tmp/hidden\\"]","--sandbox","workspace-write"]}]}}}'
  if json_process_has_managed_scope "$process_fixture" coder; then
    die 'Managed-scope parser accepted an equivalent TOML override spelling.'
  fi
  process_fixture='{"result":{"process_info":{"foreground_processes":[{"pid":101,"name":"codex","argv":["codex","--profile","coder","-c","sandbox_workspace_write.writable_roots=[]","-c","agents.enabled=false","--sandbox","workspace-write","--cd","/tmp/hidden-primary"]}]}}}'
  if json_process_has_managed_scope "$process_fixture" coder; then
    die 'Managed-scope parser accepted a Codex primary-directory override.'
  fi
  process_fixture='{"result":{"process_info":{"foreground_processes":[{"pid":101,"name":"codex","argv":["codex","--profile","coder","-c","sandbox_workspace_write.writable_roots=[]","-c","agents.enabled=false","--sandbox","workspace-write","--remote","ws://127.0.0.1:9000"]}]}}}'
  if json_process_has_managed_scope "$process_fixture" coder; then
    die 'Managed-scope parser accepted a remote execution endpoint.'
  fi
  process_fixture='{"result":{"process_info":{"foreground_processes":[{"pid":101,"name":"codex","argv":["codex","--profile","coder","-c","sandbox_workspace_write.writable_roots=[]","-c","agents.enabled=false","--sandbox","workspace-write","--remote=ws://127.0.0.1:9000"]}]}}}'
  if json_process_has_managed_scope "$process_fixture" coder; then
    die 'Managed-scope parser accepted an equals-form remote execution endpoint.'
  fi
  process_fixture='{"result":{"process_info":{"foreground_processes":[{"pid":101,"name":"codex","argv":["codex","--profile","coder","-c","sandbox_workspace_write.writable_roots=[]","-c","agents.enabled=false","--sandbox","workspace-write","--dangerously-bypass-hook-trust"]}]}}}'
  if json_process_has_managed_scope "$process_fixture" coder; then
    die 'Managed-scope parser accepted a hook-trust bypass flag.'
  fi
  process_fixture='{"result":{"process_info":{"foreground_processes":[{"pid":101,"name":"codex","argv":["codex","-c","sandbox_workspace_write.writable_roots=[]","-c","agents.enabled=false","--sandbox","workspace-write","--yolo"]}]}}}'
  if json_process_has_managed_scope "$process_fixture" coder; then
    die 'Managed-scope parser accepted an unbounded sandbox bypass flag.'
  fi
  process_fixture='{"result":{"process_info":{"foreground_processes":[{"pid":99,"name":"zsh","argv":null},{"pid":101,"name":"codex","argv":["codex","--profile","coder","-c","agents.enabled=false","-c","default_permissions=\"herdr_workspace_network\"","-c","permissions.herdr_workspace_network.extends=\":workspace\"","-c","permissions.herdr_workspace_network.network.enabled=true"]}]}}}'
  json_process_has_managed_scope "$process_fixture" coder || \
    die 'Managed-scope parser rejected an unrelated non-Codex process with unavailable argv.'
  process_fixture='{"result":{"process_info":{"foreground_processes":[{"pid":101,"name":"codex","argv":["codex","-c","sandbox_workspace_write.writable_roots=[]","-c","agents.enabled=false","--sandbox"]}]}}}'
  if json_process_has_managed_scope "$process_fixture" coder; then
    die 'Managed-scope parser accepted a dangling sandbox option.'
  fi
  process_fixture='{"result":{"process_info":{"foreground_processes":[{"pid":101,"name":"codex","argv":["codex","--profile","coder","--","-c","sandbox_workspace_write.writable_roots=[]","-c","agents.enabled=false","--sandbox","workspace-write","--add-dir","/tmp/prompt-only"]}]}}}'
  if json_process_has_managed_scope "$process_fixture" coder; then
    die 'Managed-scope parser accepted marker tokens after the option terminator.'
  fi
  [[ -z $(json_process_codex_add_dirs "$process_fixture") ]] || \
    die 'Structured add-dir parser extracted a prompt token after the option terminator.'
  process_fixture='{"result":{"process_info":{"foreground_processes":[{"pid":101,"name":"codex","argv":["codex","--add-dir","relative/path"]}]}}}'
  if json_process_codex_add_dirs "$process_fixture" >/dev/null 2>&1; then
    die 'Structured add-dir parser accepted a relative path.'
  fi
  process_fixture='{"result":{"process_info":{"foreground_processes":[{"pid":101,"name":"codex","argv":["codex","--add-dir","/tmp/root\u0085"]}]}}}'
  if json_process_codex_add_dirs "$process_fixture" >/dev/null 2>&1; then
    die 'Structured add-dir parser accepted a Unicode C1 control character.'
  fi
  process_fixture='{"result":{"process_info":{"foreground_processes":[{"pid":101,"name":"codex","argv":["codex","--add-dir"]}]}}}'
  if json_process_codex_add_dirs "$process_fixture" >/dev/null 2>&1; then
    die 'Structured add-dir parser accepted a dangling option.'
  fi
  process_fixture='{"result":{"process_info":{"foreground_processes":[{"pid":101,"name":"codex","argv":["codex","--profile","coder","-c","sandbox_workspace_write.writable_roots=[]","-c","agents.enabled=false","--sandbox","workspace-write","--add-dir","/tmp/root-one"]},{"pid":102,"name":"codex","argv":["codex","--profile","coder","-c","sandbox_workspace_write.writable_roots=[]","-c","agents.enabled=false","--sandbox","workspace-write","--add-dir","/tmp/root-two"]}]}}}'
  if json_process_codex_add_dirs "$process_fixture" >/dev/null 2>&1; then
    die 'Structured add-dir parser merged scope across multiple Codex processes.'
  fi
  process_fixture='{"result":{"process_info":{"foreground_processes":[{"pid":101,"name":"codex","argv0":"/usr/local/bin/codex","argv":["codex","--profile","planner-extra"]}]}}}'
  if process_uses_profile "$process_fixture" planner; then
    die 'Process/profile binding parser accepted a role-name prefix.'
  fi
  process_fixture='{"result":{"process_info":{"foreground_processes":[{"pid":101,"name":"codex","argv":["codex","--","--profile","planner"],"cmdline":"codex -- --profile planner"}]}}}'
  if process_uses_profile "$process_fixture" planner; then
    die 'Process/profile binding parser accepted a prompt token after the option terminator.'
  fi
  process_fixture='{"result":{"process_info":{"foreground_processes":[{"pid":101,"name":"codex","argv":["codex","--profile","planner"]},{"pid":102,"name":"echo","argv":["echo","--profile","reviewer"]}]}}}'
  if process_uses_profile "$process_fixture" reviewer; then
    die 'Process/profile binding parser accepted --profile from a non-Codex child process.'
  fi
  process_fixture='{"result":{"process_info":{"foreground_processes":[{"pid":101,"name":"codex","argv":["codex","--profile","planner"]},{"pid":102,"name":"codex","argv":["codex","--profile","reviewer"]}]}}}'
  if process_uses_profile "$process_fixture" reviewer; then
    die 'Process/profile binding parser accepted conflicting Codex role profiles.'
  fi
  process_fixture='{"result":{"process_info":{"foreground_processes":[{"pid":101,"name":"codex","argv":["codex","--profile","planner"]},{"pid":102,"name":"codex","argv":["codex"]}]}}}'
  if process_uses_profile "$process_fixture" planner; then
    die 'Process/profile binding parser accepted a second Codex process with no verifiable profile.'
  fi
  process_fixture='{"result":{"process_info":{"foreground_processes":[{"pid":-1,"name":"codex","argv":["codex","--profile","planner"]}]}}}'
  if process_uses_profile "$process_fixture" planner; then
    die 'Process/profile binding parser accepted a pid outside the Herdr uint32 schema.'
  fi
  if json_object_string '{"result":{"workspace":{"workspace_id":"one"}}} {"result":{"workspace":{"workspace_id":"two"}}}' \
       workspace workspace_id >/dev/null 2>&1; then
    die 'Object parser accepted multiple top-level JSON documents.'
  fi
  if json_agent_names '{"result":{"agents":[null]}}' >/dev/null 2>&1; then
    die 'Agent-list parser accepted a non-object agent entry.'
  fi
  if json_agent_names 'not-json {"result":{"agents":[]}}' >/dev/null 2>&1; then
    die 'Agent-list parser accepted malformed JSON with a valid-looking suffix.'
  fi
  [[ $(json_agent_field '{"result":{"agent":{"interactive_ready":false}}}' interactive_ready) == false ]] || \
    die 'Agent-field parser did not preserve a false boolean.'
  [[ $(json_agent_required_string '{"result":{"agent":{"agent":"codex"}}}' agent) == codex ]] || \
    die 'Strict agent-string parser rejected a valid kind.'
  if json_agent_required_string '{"result":{"agent":{"agent":1}}}' agent >/dev/null 2>&1 || \
     json_agent_required_string '{"result":{"agent":{"agent":false}}}' agent >/dev/null 2>&1; then
    die 'Strict agent-string parser coerced a numeric or boolean kind.'
  fi
  [[ $(json_agent_required_boolean '{"result":{"agent":{"launch_pending":false}}}' launch_pending) == false ]] || \
    die 'Strict agent-boolean parser rejected a valid false value.'
  if json_agent_required_boolean '{"result":{"agent":{"launch_pending":"false"}}}' launch_pending >/dev/null 2>&1 || \
     json_agent_required_boolean '{"result":{"agent":{"launch_pending":0}}}' launch_pending >/dev/null 2>&1; then
    die 'Strict agent-boolean parser coerced a string or numeric value.'
  fi
  [[ $(json_agent_boolean_or_false_if_absent '{"result":{"agent":{}}}' launch_pending) == false ]] || \
    die 'Compatible agent-boolean parser did not default an absent launch_pending field to false.'
  [[ $(json_agent_boolean_or_false_if_absent '{"result":{"agent":{"launch_pending":true}}}' launch_pending) == true ]] || \
    die 'Compatible agent-boolean parser rejected a present true value.'
  if json_agent_boolean_or_false_if_absent '{"result":{"agent":{"launch_pending":null}}}' launch_pending >/dev/null 2>&1 || \
     json_agent_boolean_or_false_if_absent '{"result":{"agent":{"launch_pending":"false"}}}' launch_pending >/dev/null 2>&1 || \
     json_agent_boolean_or_false_if_absent '{"result":{"agent":{"launch_pending":0}}}' launch_pending >/dev/null 2>&1; then
    die 'Compatible agent-boolean parser accepted a malformed present value.'
  fi
  [[ -z $(json_agent_optional_string '{"result":{"agent":{"cwd":null}}}' cwd) ]] || \
    die 'Optional agent-string parser did not preserve null as empty.'
  if json_agent_optional_string '{"result":{"agent":{"cwd":1}}}' cwd >/dev/null 2>&1; then
    die 'Optional agent-string parser coerced a numeric cwd.'
  fi
  correlation_fixture='IMPLEMENTATION_DONE
TASK_ID: task-1
ROUND: 1
HANDOFF_ID: handoff-1
HERDR_CODER_DONE_fixture'
  [[ $(printf '%s\n' "$correlation_fixture" | response_correlation_block_count \
       IMPLEMENTATION_DONE 'TASK_ID: task-1' 'ROUND: 1' 'HANDOFF_ID: handoff-1' \
       HERDR_CODER_DONE_fixture) -eq 1 ]] || \
    die 'Response-correlation parser rejected a valid consecutive block.'
  [[ $(printf '%s\n' "$correlation_fixture" | sed -e '1s/^/• /' -e '2,$s/^/  /' | terminal_response_lines) == "$correlation_fixture" ]] || \
    die 'Codex terminal decorations obscured a valid response block.'
  correlation_fixture='IMPLEMENTATION_DONE
ROUND: 1
TASK_ID: task-1
HANDOFF_ID: handoff-1
HERDR_CODER_DONE_fixture'
  [[ $(printf '%s\n' "$correlation_fixture" | response_correlation_block_count \
       IMPLEMENTATION_DONE 'TASK_ID: task-1' 'ROUND: 1' 'HANDOFF_ID: handoff-1' \
       HERDR_CODER_DONE_fixture) -eq 0 ]] || \
    die 'Response-correlation parser accepted reordered fields.'
  printf '[OK] Profile and prompt guardrails\n'

  temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/herdr-codex-team-static.XXXXXX")
  codex_test_dir="$temporary_root/codex"
  mkdir -p "$codex_test_dir"
  codex_test_dir=$(CDPATH= cd -- "$codex_test_dir" && pwd -P)

  parse_log="$temporary_root/parse.log"
  if env -u TEAM_PREFIX "$SCRIPT_DIR/start.sh" --team '' --cwd "$PROJECT_ROOT" \
       >"$parse_log" 2>&1; then
    die 'start.sh accepted an explicit empty --team prefix.'
  fi
  grep -Fq -- '--team requires a non-empty prefix' "$parse_log" || \
    die 'start.sh empty-team parsing failed for the wrong reason.'
  if env -u TEAM_PREFIX "$SCRIPT_DIR/start.sh" --cwd "$PROJECT_ROOT" "$PROJECT_ROOT" \
       >"$parse_log" 2>&1; then
    die 'start.sh accepted both --cwd and positional PROJECT_DIR.'
  fi
  grep -Fq 'Use either --cwd or positional PROJECT_DIR' "$parse_log" || \
    die 'start.sh cwd/positional conflict failed for the wrong reason.'
  if env -u TEAM_PREFIX "$SCRIPT_DIR/start.sh" '' >"$parse_log" 2>&1; then
    die 'start.sh accepted an explicit empty positional PROJECT_DIR.'
  fi
  grep -Fq 'Positional PROJECT_DIR must not be empty' "$parse_log" || \
    die 'start.sh empty positional PROJECT_DIR failed for the wrong reason.'
  non_git_primary="$temporary_root/non-git-primary"
  non_git_extra="$temporary_root/non-git-extra"
  mkdir -p "$non_git_primary/child" "$non_git_extra"
  non_git_primary=$(scope_physical_dir "$non_git_primary")
  non_git_extra=$(scope_physical_dir "$non_git_extra")
  ln -s "$non_git_extra" "$temporary_root/non-git-extra-alias"
  scope_paths_overlap "$non_git_extra" "$temporary_root/non-git-extra-alias" || \
    die 'Workspace-scope overlap did not recognize a symlink/inode alias.'
  scope_path_has_control $'/tmp/line\nbreak' || \
    die 'Workspace-scope path validation accepted a line feed.'
  scope_path_has_control $'/tmp/c1-\302\205' || \
    die 'Workspace-scope path validation accepted a UTF-8 C1 control character.'
  control_target="$temporary_root/control-target"$'\n'
  mkdir -p "$control_target"
  ln -s "$control_target" "$temporary_root/clean-control-alias"
  if scope_physical_dir "$temporary_root/clean-control-alias" >/dev/null 2>&1; then
    die 'Physical-path resolution accepted a clean symlink to a control-named directory.'
  fi
  : >"$temporary_root/not-a-directory"
  if env -u TEAM_PREFIX "$SCRIPT_DIR/start.sh" --cwd "$non_git_primary" --add-dir= \
       >"$parse_log" 2>&1; then
    die 'start.sh accepted an empty --add-dir value.'
  fi
  grep -Fq -- '--add-dir requires a non-empty directory' "$parse_log" || \
    die 'Empty --add-dir failed for the wrong reason.'
  for bad_add_dir in "$temporary_root/missing" "$temporary_root/not-a-directory" /; do
    if env -u TEAM_PREFIX "$SCRIPT_DIR/start.sh" --cwd "$non_git_primary" --add-dir "$bad_add_dir" \
         >"$parse_log" 2>&1; then
      die "start.sh accepted an unsafe --add-dir: $bad_add_dir"
    fi
  done
  if env -u TEAM_PREFIX "$SCRIPT_DIR/start.sh" --cwd "$non_git_primary" \
       --add-dir "$non_git_primary/child" >"$parse_log" 2>&1; then
    die 'start.sh accepted an additional root nested under PROJECT_DIR.'
  fi
  grep -Fq 'overlaps PROJECT_DIR' "$parse_log" || \
    die 'Overlapping add-dir failed without the expected diagnostic.'
  if env -u TEAM_PREFIX "$SCRIPT_DIR/start.sh" --cwd "$non_git_primary" \
       --add-dir "$non_git_extra" --add-dir "$temporary_root/non-git-extra-alias" \
       >"$parse_log" 2>&1; then
    die 'start.sh accepted two --add-dir values that resolve to one inode.'
  fi
  [[ $(GIT_CEILING_DIRECTORIES="$PROJECT_ROOT" scope_git_root "$PROJECT_ROOT/docs") == "$PROJECT_ROOT" ]] || \
    die 'Git-scope discovery inherited a caller GIT_CEILING_DIRECTORIES override.'
  if GIT_DISCOVERY_ACROSS_FILESYSTEM=0 scope_git_root "$non_git_primary" >/dev/null 2>&1; then
    die 'Non-Git scope was unexpectedly classified as Git-backed.'
  else
    non_git_scope_status=$?
  fi
  [[ $non_git_scope_status -eq 1 ]] || \
    die 'Git-scope discovery did not normalize a caller filesystem-boundary override.'
  nested_git_host="$non_git_primary/embedded-git-host"
  mkdir -p "$nested_git_host"
  git -C "$nested_git_host" init -q
  nested_git_host=$(scope_physical_dir "$nested_git_host")
  mock_agent_cwd=$non_git_primary
  if (
    herdr() {
      printf '{"result":{"agent":{"cwd":"%s","foreground_cwd":"%s"}}}\n' \
        "$mock_agent_cwd" "$mock_agent_cwd"
    }
    require_agents_cover_host "$nested_git_host" "$nested_git_host"
  ) >"$parse_log" 2>&1; then
    die 'Live-test host validation accepted a nested Git host under a non-Git team primary cwd.'
  fi
  grep -Fq "primary cwd is non-Git" "$parse_log" || \
    die 'Non-Git primary cwd failed live-test validation for the wrong reason.'
  mock_agent_cwd=$nested_git_host
  if ! (
    herdr() {
      printf '{"result":{"agent":{"cwd":"%s","foreground_cwd":"%s"}}}\n' \
        "$mock_agent_cwd" "$mock_agent_cwd"
    }
    require_agents_cover_host "$nested_git_host" "$nested_git_host"
  ) >"$parse_log" 2>&1; then
    printf '%s\n' "$(<"$parse_log")" >&2
    die 'Live-test host validation rejected a matching Git-backed team primary cwd.'
  fi
  malformed_git_dir="$temporary_root/not a git repository"
  mkdir -p "$malformed_git_dir"
  printf 'malformed\n' >"$malformed_git_dir/.git"
  if scope_git_root "$malformed_git_dir" >/dev/null 2>&1; then
    die 'Git-scope discovery accepted a malformed .git file.'
  else
    malformed_git_status=$?
  fi
  [[ $malformed_git_status -eq 2 ]] || \
    die 'Git-scope discovery misclassified a malformed .git file as a non-Git directory.'
  external_git_probe="$temporary_root/external-worktree-probe"
  external_git_root="$temporary_root/external-worktree-root"
  external_git_store="$temporary_root/external-worktree.git"
  mkdir -p "$external_git_probe" "$external_git_root"
  git init --bare "$external_git_store" >/dev/null 2>&1
  git --git-dir="$external_git_store" config core.bare false
  git --git-dir="$external_git_store" config core.worktree "$external_git_root"
  printf 'gitdir: %s\n' "$external_git_store" >"$external_git_probe/.git"
  if scope_git_root "$external_git_probe" >/dev/null 2>&1; then
    die 'Git-scope discovery accepted a top-level outside the inspected directory ancestry.'
  else
    external_git_status=$?
  fi
  [[ $external_git_status -eq 2 ]] || \
    die 'External core.worktree was not classified as an unverified Git scope.'

  root_git_probe="$temporary_root/root-worktree-probe"
  root_git_store="$temporary_root/root-worktree.git"
  mkdir -p "$root_git_probe"
  git init --bare "$root_git_store" >/dev/null 2>&1
  git --git-dir="$root_git_store" config core.bare false
  git --git-dir="$root_git_store" config core.worktree /
  printf 'gitdir: %s\n' "$root_git_store" >"$root_git_probe/.git"
  if scope_git_root "$root_git_probe" >/dev/null 2>&1; then
    die 'Git-scope discovery accepted the filesystem root as a worktree top-level.'
  else
    root_git_status=$?
  fi
  [[ $root_git_status -eq 2 ]] || \
    die 'Filesystem-root core.worktree was not classified as an unverified Git scope.'

  trailing_git_probe="$temporary_root/trailing-worktree-probe"
  trailing_git_clean="$temporary_root/trailing-worktree-root"
  trailing_git_control="$trailing_git_clean"$'\n'
  trailing_git_store="$temporary_root/trailing-worktree.git"
  mkdir -p "$trailing_git_probe" "$trailing_git_clean" "$trailing_git_control"
  git init --bare "$trailing_git_store" >/dev/null 2>&1
  git --git-dir="$trailing_git_store" config core.bare false
  git --git-dir="$trailing_git_store" config core.worktree "$trailing_git_control"
  printf 'gitdir: %s\n' "$trailing_git_store" >"$trailing_git_probe/.git"
  if scope_git_root "$trailing_git_probe" >/dev/null 2>&1; then
    die 'Git-scope discovery accepted a top-level with a trailing line feed.'
  else
    trailing_git_status=$?
  fi
  [[ $trailing_git_status -eq 2 ]] || \
    die 'Trailing-control core.worktree was not classified as an unverified Git scope.'
  if GIT_CEILING_DIRECTORIES="$PROJECT_ROOT" env -u TEAM_PREFIX \
       "$SCRIPT_DIR/start.sh" --cwd "$PROJECT_ROOT/docs" --add-dir "$PROJECT_ROOT/scripts" \
       >"$parse_log" 2>&1; then
    die 'start.sh accepted two directories from one Git worktree under a contaminated Git environment.'
  fi
  grep -Fq 'share or overlap one effective Git/filesystem scope' "$parse_log" || \
    die 'Contaminated Git environment failed without the same-worktree diagnostic.'
  if env -u TEAM_PREFIX "$SCRIPT_DIR/doctor.sh" --cwd "$non_git_primary" \
       --add-dir "$non_git_primary/child" >"$parse_log" 2>&1; then
    die 'doctor.sh accepted an additional root nested under the expected cwd.'
  fi
  if env -u TEAM_PREFIX "$SCRIPT_DIR/doctor.sh" --team Bad >"$parse_log" 2>&1; then
    die 'doctor.sh accepted an invalid team prefix.'
  fi
  grep -Fq 'Invalid team prefix' "$parse_log" || \
    die 'doctor.sh invalid team parsing failed for the wrong reason.'
  if env -u TEAM_PREFIX "$SCRIPT_DIR/test.sh" --team Bad static >"$parse_log" 2>&1; then
    die 'test.sh accepted an invalid team prefix.'
  fi
  grep -Fq 'Invalid team prefix' "$parse_log" || \
    die 'test.sh invalid team parsing failed for the wrong reason.'
  printf '[OK] start/doctor/test option parsing fails closed\n'

  for invalid_timeout in 3000 300001 18446744073709554617; do
    start_log="$temporary_root/start-$invalid_timeout.log"
    if CODEX_HOME="$codex_test_dir" HERDR_START_TIMEOUT_MS="$invalid_timeout" \
         "$SCRIPT_DIR/start.sh" --no-focus "$PROJECT_ROOT" >"$start_log" 2>&1; then
      die "start.sh accepted invalid HERDR_START_TIMEOUT_MS=$invalid_timeout."
    fi
    case "$invalid_timeout" in
      3000) expected_timeout_error='must be greater than the Herdr minimum' ;;
      *) expected_timeout_error='exceeds the Herdr 0.8.2 maximum' ;;
    esac
    grep -Fq "$expected_timeout_error" "$start_log" || {
      command cat "$start_log" >&2
      die "start.sh failed for the wrong reason with HERDR_START_TIMEOUT_MS=$invalid_timeout."
    }
  done
  printf '[OK] Startup timeout bounds fail before workspace creation\n'

  printf 'original planner profile\n' >"$codex_test_dir/planner.config.toml"
  install_log="$temporary_root/install.log"

  if ! CODEX_HOME="$codex_test_dir" \
       PLANNER_MODEL='test-planner' \
       CODER_MODEL='test-coder' \
       REVIEWER_MODEL='test-reviewer' \
       "$SCRIPT_DIR/install.sh" >"$install_log" 2>&1; then
    command cat "$install_log" >&2
    die 'Sandboxed installer test failed.'
  fi

  backup_dir=$(find "$codex_test_dir" -maxdepth 1 -type d -name 'herdr-codex-team-backup-*' | head -n 1)
  [[ -n "$backup_dir" ]] || die 'Installer did not create a backup for an existing profile.'
  grep -Fq 'original planner profile' "$backup_dir/planner.config.toml" || \
    die 'Installer backup did not preserve the original planner profile.'
  for role in planner coder reviewer; do
    grep -Fq '# Installed by herdr-codex-team.' "$codex_test_dir/$role.config.toml" || \
      die "Installed $role profile lacks the ownership marker."
    grep -Eq '^# herdr-prompt-sha256: [0-9a-f]{64}$' "$codex_test_dir/$role.config.toml" || \
      die "Installed $role profile lacks one prompt digest marker."
    grep -Eq '^# herdr-profile-policy-sha256: [0-9a-f]{64}$' "$codex_test_dir/$role.config.toml" || \
      die "Installed $role profile lacks one policy digest marker."
    grep -Eq '^developer_instructions[[:space:]]*=' "$codex_test_dir/$role.config.toml" || \
      die "Installed $role profile lacks developer instructions."
    grep -Eq '^model[[:space:]]*=[[:space:]]*"test-'"$role"'"' "$codex_test_dir/$role.config.toml" || \
      die "Installed $role model override is missing."
    grep -Eq '^agents[.]enabled[[:space:]]*=[[:space:]]*false[[:space:]]*$' \
      "$codex_test_dir/$role.config.toml" || \
      die "Installed $role profile still enables Codex-native multi-agent tools."
  done
  bridge_path="$codex_test_dir/herdr-codex-team/herdr_mcp.py"
  [[ -f "$bridge_path" && ! -L "$bridge_path" ]] || \
    die 'Installer did not install a safe Planner Herdr MCP bridge.'
  resolved_python_bin=$(managed_python_executable) || \
    die 'Static test could not resolve Python to an absolute executable.'
  resolved_herdr_bin=$(managed_command_executable herdr "$resolved_python_bin") || \
    die 'Static test could not resolve Herdr to an absolute executable.'
  python_toml=$("$resolved_python_bin" -c \
    'import json, sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' \
    "$resolved_python_bin")
  bridge_toml=$("$resolved_python_bin" -c \
    'import json, sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' \
    "$bridge_path")
  grep -Fxq "mcp_servers.herdr_codex_team.command = $python_toml" \
    "$codex_test_dir/planner.config.toml" || \
    die 'Installed Planner profile did not pin the absolute Python executable.'
  grep -Fxq "mcp_servers.herdr_codex_team.args = [$bridge_toml]" \
    "$codex_test_dir/planner.config.toml" || \
    die 'Installed Planner profile did not pin the absolute managed bridge path.'
  if grep -Eq '__HERDR_CODEX_TEAM_|command[[:space:]]*=[[:space:]]*"/bin/sh"|exec[[:space:]]+python3' \
       "$codex_test_dir/planner.config.toml"; then
    die 'Installed Planner profile retained an unsafe launcher or an unrendered path placeholder.'
  fi
  managed_bridge_integrity "$bridge_path" "$PROJECT_ROOT/scripts/herdr_mcp.py" || \
    die 'Installed Planner Herdr MCP bridge does not match its managed source.'
  PYTHONDONTWRITEBYTECODE=1 "$resolved_python_bin" "$bridge_path" --check >/dev/null || \
    die 'Installed Planner Herdr MCP bridge failed self-check.'

  for role in planner coder reviewer; do
    if ! rendered_prompt=$(CODEX_HOME="$codex_test_dir" \
         HERDR_BIN_PATH="$resolved_herdr_bin" \
         codex --profile "$role" debug prompt-input 'profile validation' 2>/dev/null); then
      die "Codex could not load the rendered $role profile."
    fi
    json_prompt_has_effective_role_permissions "$rendered_prompt" "$role" || \
      die "Rendered $role profile did not enable networking with its exact local filesystem boundary."
    python3 -c '
import json, pathlib, sys
skill = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
mode = {"planner": "Use the task mode that matches", "coder": "Use change mode",
        "reviewer": "Use review mode"}[sys.argv[2]]
texts = (part.get("text", "") for message in json.load(sys.stdin)
         if message.get("role") == "developer" for part in message.get("content", []))
sys.exit(0 if any("Apply the embedded Stop That Shit skill on every task." in text
                  and mode in text and skill in text for text in texts) else 1)
' "$PROJECT_ROOT/prompts/stop-that-shit/SKILL.md" "$role" <<<"$rendered_prompt" || \
      die "Rendered $role developer instructions do not require and include the full Stop That Shit skill."
    for native_agent_marker in \
      spawn_agent followup_task send_message wait_agent interrupt_agent list_agents; do
      if grep -Fq "$native_agent_marker" <<<"$rendered_prompt"; then
        die "Rendered $role profile still exposes Codex-native agent marker $native_agent_marker."
      fi
    done
  done
  printf '[OK] Codex loaded all rendered profiles with role-local filesystem boundaries, command networking, and no native multi-agent tools\n'

  mock_bin="$temporary_root/mock-bin"
  workspace_marker="$temporary_root/workspace-created"
  mkdir -p "$mock_bin"
cat >"$mock_bin/codex" <<'MOCK_CODEX'
#!/usr/bin/env bash
if [[ ${1-} == --version ]]; then
  printf '%s\n' 'codex-cli mock'
  exit 0
fi
if [[ ${1-} == --help ]]; then
  printf '%s\n' '  --add-dir <DIR>  Additional writable directory'
  exit 0
fi
role=''
previous=''
add_dirs=()
for argument in "$@"; do
  if [[ "$previous" == --profile ]]; then
    role=$argument
  fi
  if [[ "$previous" == --add-dir ]]; then
    add_dirs+=("$argument")
  elif [[ "$argument" == --add-dir=* ]]; then
    add_dirs+=("${argument#--add-dir=}")
  fi
  previous=$argument
done
if [[ " $* " == *' debug prompt-input '* ]]; then
  case "$role" in
    planner|reviewer) sandbox=read-only ;;
    coder) sandbox=workspace-write ;;
    *) exit 2 ;;
  esac
  roots="<root>$PWD</root>"
  for add_dir in ${add_dirs[@]+"${add_dirs[@]}"}; do
    roots+="<root>$add_dir</root>"
  done
  printf '[{"type":"message","content":[{"type":"input_text","text":"<permissions instructions>\\n`Sandbox_mode` compatibility marker; `sandbox_mode` is `%s`. Network access is enabled.\\n</permissions instructions>"},{"type":"input_text","text":"<environment_context><filesystem><workspace_roots>%s</workspace_roots></filesystem></environment_context>"}]}]\n' \
    "$sandbox" "$roots"
fi
exit 0
MOCK_CODEX
  cat >"$mock_bin/herdr" <<'MOCK_HERDR'
#!/usr/bin/env bash
case "${1-}:${2-}" in
  integration:status)
    printf '%s\n' 'codex: current (mock)'
    ;;
  status:server)
    printf '%s\n' '{"result":{"type":"server_status"}}'
    ;;
  agent:list)
    case ${MOCK_HERDR_MODE:-preflight-collision} in
      race-collision|multi-root-success|missing-primary|wrong-primary|missing-root-pane)
        printf '%s\n' '{"result":{"type":"agent_list","agents":[]}}'
        ;;
      doctor-success)
        printf '%s\n' '{"result":{"type":"agent_list","agents":[{"name":"github-planner"},{"name":"github-coder"},{"name":"github-reviewer"}]}}'
        ;;
      shared-worktree|uninspectable-worktree|numeric-kind|boolean-kind|separate-worktree|mixed-worktree|ancestor-worktree|root-worktree|scope-adddir-collision|scope-unmanaged)
        printf '%s\n' '{"result":{"type":"agent_list","agents":[{"name":"docs-coder"}]}}'
        ;;
      malformed-list)
        printf '%s\n' 'not-json {"result":{"type":"agent_list","agents":[]}}'
        ;;
      *)
        printf '%s\n' '{"result":{"type":"agent_list","agents":[{"name":"github-planner"}]}}'
        ;;
    esac
    ;;
  workspace:create)
    [[ ${3-} == --help ]] && exit 0
    [[ -n ${MOCK_HERDR_CALL_LOG:-} ]] && printf '%s\n' "$*" >>"$MOCK_HERDR_CALL_LOG"
    printf '%s\n' "$*" >"$MOCK_WORKSPACE_MARKER"
    if [[ ${MOCK_HERDR_MODE:-} == missing-root-pane ]]; then
      printf '%s\n' '{"result":{"workspace":{"workspace_id":"mock-workspace"}}}'
    else
      printf '%s\n' '{"result":{"workspace":{"workspace_id":"mock-workspace"},"root_pane":{"pane_id":"mock-root"}}}'
    fi
    ;;
  pane:split)
    [[ ${3-} == --help ]] && exit 0
    [[ -n ${MOCK_HERDR_CALL_LOG:-} ]] && printf '%s\n' "$*" >>"$MOCK_HERDR_CALL_LOG"
    count=0
    [[ -f "$MOCK_SPLIT_COUNTER" ]] && count=$(<"$MOCK_SPLIT_COUNTER")
    count=$((count + 1))
    printf '%s' "$count" >"$MOCK_SPLIT_COUNTER"
    printf '{"result":{"pane":{"pane_id":"mock-pane-%s"}}}\n' "$count"
    ;;
  agent:start)
    [[ ${3-} == --help ]] && exit 0
    printf '%s\n' "$*" >>"$MOCK_HERDR_CALL_LOG"
    if [[ ${MOCK_HERDR_MODE:-} == multi-root-success && ${3-} == github-reviewer &&
          " $* " == *' --add-dir '* ]]; then
      printf '%s\n' 'Error adding directories: Ignoring --add-dir because the effective permissions do not allow additional writable roots.' >&2
      exit 1
    fi
    if [[ ${MOCK_HERDR_MODE:-} == race-collision && ${3-} == github-coder ]]; then
      printf '%s\n' 'agent_name_taken: github-coder' >&2
      exit 1
    fi
    ;;
  agent:prompt)
    [[ ${3-} == --help ]] && exit 0
    [[ ${4-} == "/rename ${3-} "* ]] || exit 1
    uuid=$(python3 -c 'import sys,uuid; print(uuid.uuid5(uuid.NAMESPACE_URL, sys.argv[1]+sys.argv[2]))' "$(<"$MOCK_WORKSPACE_MARKER")" "$3")
    printf '{"id":"%s","thread_name":"%s"}\n' "$uuid" "${4#/rename }" >>"$CODEX_HOME/session_index.jsonl"
    ;;
  agent:get)
    [[ ${3-} == --help ]] && exit 0
    if [[ ${MOCK_HERDR_MODE:-} == shared-worktree && ${3-} == docs-coder ]]; then
      printf '{"result":{"agent":{"name":"docs-coder","agent":"codex","pane_id":"mock-docs-pane","cwd":"%s","foreground_cwd":"%s/scripts"}}}\n' \
        "$MOCK_PROJECT_ROOT" "$MOCK_PROJECT_ROOT"
      exit 0
    fi
    if [[ ${MOCK_HERDR_MODE:-} == uninspectable-worktree && ${3-} == docs-coder ]]; then
      printf '%s\n' '{"result":{"agent":{"name":"docs-coder"}}}'
      exit 0
    fi
    if [[ ${MOCK_HERDR_MODE:-} == numeric-kind && ${3-} == docs-coder ]]; then
      printf '%s\n' '{"result":{"agent":{"name":"docs-coder","agent":1,"cwd":null,"foreground_cwd":null}}}'
      exit 0
    fi
    if [[ ${MOCK_HERDR_MODE:-} == boolean-kind && ${3-} == docs-coder ]]; then
      printf '%s\n' '{"result":{"agent":{"name":"docs-coder","agent":false,"cwd":null,"foreground_cwd":null}}}'
      exit 0
    fi
    if [[ ${MOCK_HERDR_MODE:-} == mixed-worktree && ${3-} == docs-coder ]]; then
      printf '{"result":{"agent":{"name":"docs-coder","agent":"codex","pane_id":"mock-docs-pane","cwd":"%s","foreground_cwd":"%s"}}}\n' \
        "$MOCK_PROJECT_ROOT" "$MOCK_OTHER_WORKTREE"
      exit 0
    fi
    if [[ ${MOCK_HERDR_MODE:-} == ancestor-worktree && ${3-} == docs-coder ]]; then
      printf '{"result":{"agent":{"name":"docs-coder","agent":"codex","pane_id":"mock-docs-pane","cwd":"%s","foreground_cwd":"%s"}}}\n' \
        "$MOCK_ANCESTOR_CWD" "$MOCK_ANCESTOR_CWD"
      exit 0
    fi
    if [[ ${MOCK_HERDR_MODE:-} == root-worktree && ${3-} == docs-coder ]]; then
      printf '%s\n' '{"result":{"agent":{"name":"docs-coder","agent":"codex","pane_id":"mock-docs-pane","cwd":"/","foreground_cwd":"/"}}}'
      exit 0
    fi
    if [[ ${MOCK_HERDR_MODE:-} == scope-adddir-collision || ${MOCK_HERDR_MODE:-} == scope-unmanaged ]]; then
      if [[ ${3-} == docs-coder ]]; then
        printf '{"result":{"agent":{"name":"docs-coder","agent":"codex","pane_id":"mock-docs-pane","cwd":"%s","foreground_cwd":"%s"}}}\n' \
          "$MOCK_OTHER_WORKTREE" "$MOCK_OTHER_WORKTREE"
        exit 0
      fi
    fi
    if [[ ${MOCK_HERDR_MODE:-} == separate-worktree || \
          ${MOCK_HERDR_MODE:-} == multi-root-success || \
          ${MOCK_HERDR_MODE:-} == missing-primary || \
          ${MOCK_HERDR_MODE:-} == wrong-primary ]]; then
      if [[ ${3-} == docs-coder ]]; then
        printf '{"result":{"agent":{"name":"docs-coder","agent":"codex","pane_id":"mock-docs-pane","cwd":"%s","foreground_cwd":"%s"}}}\n' \
          "$MOCK_OTHER_WORKTREE" "$MOCK_OTHER_WORKTREE"
        exit 0
      fi
      case ${3-} in
        github-planner) pane=mock-root ;;
        github-coder) pane=mock-pane-1 ;;
        github-reviewer) pane=mock-pane-2 ;;
        *) exit 1 ;;
      esac
      if [[ ${MOCK_HERDR_MODE:-} == missing-primary ]]; then
        final_ready_json=${MOCK_FINAL_READY_JSON:-true}
        final_launch_pending_json=${MOCK_FINAL_LAUNCH_PENDING_JSON:-false}
        printf '{"result":{"agent":{"name":"%s","agent":"codex","agent_status":"idle","interactive_ready":%s,"launch_pending":%s,"pane_id":"%s","workspace_id":"mock-workspace"}}}\n' \
          "$3" "$final_ready_json" "$final_launch_pending_json" "$pane"
      else
        final_project_root=${MOCK_FINAL_PROJECT_ROOT:-$MOCK_PROJECT_ROOT}
        final_ready_json=${MOCK_FINAL_READY_JSON:-true}
        final_launch_pending_json=${MOCK_FINAL_LAUNCH_PENDING_JSON:-false}
        uuid=$(python3 -c 'import sys,uuid; print(uuid.uuid5(uuid.NAMESPACE_URL, sys.argv[1]+sys.argv[2]))' "$(<"$MOCK_WORKSPACE_MARKER")" "$3")
        session_fields=$(printf '"terminal_title":"%s","agent_session":{"source":"herdr:codex","agent":"codex","kind":"id","value":"%s"}' "$uuid" "$uuid")
        if [[ ${MOCK_OMIT_LAUNCH_PENDING:-0} == 1 ]]; then
          printf '{"result":{"agent":{"name":"%s","agent":"codex","agent_status":"idle","interactive_ready":%s,"pane_id":"%s","workspace_id":"mock-workspace" ,%s,"cwd":"%s","foreground_cwd":"%s"}}}\n' \
            "$3" "$final_ready_json" "$pane" "$session_fields" "$final_project_root" "$final_project_root"
        else
          printf '{"result":{"agent":{"name":"%s","agent":"codex","agent_status":"idle","interactive_ready":%s,"launch_pending":%s,"pane_id":"%s","workspace_id":"mock-workspace" ,%s,"cwd":"%s","foreground_cwd":"%s"}}}\n' \
            "$3" "$final_ready_json" "$final_launch_pending_json" "$pane" "$session_fields" "$final_project_root" "$final_project_root"
        fi
      fi
      exit 0
    fi
    if [[ ${MOCK_HERDR_MODE:-} == doctor-success ]]; then
      case ${3-} in
        github-planner|github-coder|github-reviewer)
          printf '%s\n' "$*" >>"$MOCK_HERDR_CALL_LOG"
          role=${3#github-}
          case "$role" in
            planner) pane=${MOCK_PLANNER_PANE:-mock-planner-pane} ;;
            coder) pane=${MOCK_CODER_PANE:-mock-coder-pane} ;;
            reviewer) pane=${MOCK_REVIEWER_PANE:-mock-reviewer-pane} ;;
          esac
          workspace=${MOCK_WORKSPACE_ID:-mock-team-workspace}
          reported_cwd=${MOCK_AGENT_CWD:-$MOCK_PROJECT_ROOT}
          reported_foreground_cwd=${MOCK_FOREGROUND_CWD:-$MOCK_PROJECT_ROOT}
          ready_json=${MOCK_INTERACTIVE_READY_JSON:-true}
          launch_pending_json=${MOCK_LAUNCH_PENDING_JSON:-false}
          if [[ ${MOCK_OMIT_LAUNCH_PENDING:-0} == 1 ]]; then
            printf '{"result":{"agent":{"name":"%s","agent":"codex","agent_status":"idle","interactive_ready":%s,"pane_id":"%s","workspace_id":"%s","cwd":"%s","foreground_cwd":"%s"}}}\n' \
              "$3" "$ready_json" "$pane" "$workspace" "$reported_cwd" "$reported_foreground_cwd"
          else
            printf '{"result":{"agent":{"name":"%s","agent":"codex","agent_status":"idle","interactive_ready":%s,"launch_pending":%s,"pane_id":"%s","workspace_id":"%s","cwd":"%s","foreground_cwd":"%s"}}}\n' \
              "$3" "$ready_json" "$launch_pending_json" "$pane" "$workspace" "$reported_cwd" "$reported_foreground_cwd"
          fi
          exit 0
          ;;
      esac
    fi
    exit 1
    ;;
  pane:process-info)
    [[ ${3-} == --help ]] && exit 0
    if [[ ${4-} == mock-docs-pane ]]; then
      if [[ ${MOCK_HERDR_MODE:-} == scope-unmanaged ]]; then
        printf '%s\n' '{"result":{"process_info":{"foreground_processes":[{"pid":101,"name":"codex","argv":["codex","--profile","coder","--sandbox","workspace-write"]}]}}}'
      elif [[ -n ${MOCK_EXTRA_ROOT:-} && ${MOCK_HERDR_MODE:-} == scope-adddir-collision ]]; then
        printf '{"result":{"process_info":{"foreground_processes":[{"pid":101,"name":"codex","argv":["codex","--profile","coder","-c","agents.enabled=false","-c","default_permissions=\\"herdr_workspace_network\\"","-c","permissions.herdr_workspace_network.extends=\\":workspace\\"","-c","permissions.herdr_workspace_network.network.enabled=true","--add-dir","%s"]}]}}}\n' "$MOCK_EXTRA_ROOT"
      else
        printf '%s\n' '{"result":{"process_info":{"foreground_processes":[{"pid":101,"name":"codex","argv":["codex","--profile","coder","-c","agents.enabled=false","-c","default_permissions=\"herdr_workspace_network\"","-c","permissions.herdr_workspace_network.extends=\":workspace\"","-c","permissions.herdr_workspace_network.network.enabled=true"]}]}}}'
      fi
      exit 0
    fi
    if [[ ${MOCK_HERDR_MODE:-} == doctor-success ]]; then
      case ${4-} in
        "${MOCK_PLANNER_PANE:-mock-planner-pane}") role=planner ;;
        "${MOCK_CODER_PANE:-mock-coder-pane}") role=coder ;;
        "${MOCK_REVIEWER_PANE:-mock-reviewer-pane}") role=reviewer ;;
        *) exit 1 ;;
      esac
      case "$role" in
        planner|reviewer) permission=herdr_read_only_network; parent=:read-only ;;
        coder) permission=herdr_workspace_network; parent=:workspace ;;
      esac
      if [[ -n ${MOCK_EXTRA_ROOT:-} && "$role" != reviewer ]]; then
        printf '{"result":{"process_info":{"foreground_processes":[{"pid":101,"name":"codex","argv0":"/usr/local/bin/codex","argv":["codex","--profile","%s","-c","agents.enabled=false","-c","default_permissions=\\"%s\\"","-c","permissions.%s.extends=\\"%s\\"","-c","permissions.%s.network.enabled=true","--add-dir","%s"],"cmdline":"codex --profile %s"}]}}}\n' \
          "$role" "$permission" "$permission" "$parent" "$permission" "$MOCK_EXTRA_ROOT" "$role"
      else
        printf '{"result":{"process_info":{"foreground_processes":[{"pid":101,"name":"codex","argv0":"/usr/local/bin/codex","argv":["codex","--profile","%s","-c","agents.enabled=false","-c","default_permissions=\\"%s\\"","-c","permissions.%s.extends=\\"%s\\"","-c","permissions.%s.network.enabled=true"],"cmdline":"codex --profile %s"}]}}}\n' \
          "$role" "$permission" "$permission" "$parent" "$permission" "$role"
      fi
      exit 0
    fi
    if [[ ${MOCK_HERDR_MODE:-} == separate-worktree || \
          ${MOCK_HERDR_MODE:-} == multi-root-success || \
          ${MOCK_HERDR_MODE:-} == missing-primary || \
          ${MOCK_HERDR_MODE:-} == wrong-primary ]]; then
      case ${4-} in
        mock-root) role=planner; permission=herdr_read_only_network; parent=:read-only ;;
        mock-pane-1) role=coder; permission=herdr_workspace_network; parent=:workspace ;;
        mock-pane-2) role=reviewer; permission=herdr_read_only_network; parent=:read-only ;;
        *) exit 1 ;;
      esac
      if [[ -n ${MOCK_EXTRA_ROOT:-} && "$role" != reviewer ]]; then
        printf '{"result":{"process_info":{"foreground_processes":[{"pid":101,"name":"codex","argv":["codex","--profile","%s","-c","agents.enabled=false","-c","default_permissions=\\"%s\\"","-c","permissions.%s.extends=\\"%s\\"","-c","permissions.%s.network.enabled=true","--add-dir","%s"]}]}}}\n' \
          "$role" "$permission" "$permission" "$parent" "$permission" "$MOCK_EXTRA_ROOT"
      else
        printf '{"result":{"process_info":{"foreground_processes":[{"pid":101,"name":"codex","argv":["codex","--profile","%s","-c","agents.enabled=false","-c","default_permissions=\\"%s\\"","-c","permissions.%s.extends=\\"%s\\"","-c","permissions.%s.network.enabled=true"]}]}}}\n' \
          "$role" "$permission" "$permission" "$parent" "$permission"
      fi
      exit 0
    fi
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
MOCK_HERDR
  chmod +x "$mock_bin/codex" "$mock_bin/herdr"

  team_configure '' || die 'Could not configure the legacy launch-state namespace.'
  run_state_configure "$codex_test_dir" "$TEAM_MODE" "$TEAM_PREFIX_EFFECTIVE" || \
    die 'Could not derive the legacy launch-state path.'
  legacy_state_file=$RUN_STATE_FILE
  team_configure legacy || die 'Could not configure the prefixed legacy launch-state namespace.'
  run_state_configure "$codex_test_dir" "$TEAM_MODE" "$TEAM_PREFIX_EFFECTIVE" || \
    die 'Could not derive the prefixed legacy launch-state path.'
  prefixed_legacy_state_file=$RUN_STATE_FILE
  [[ "$legacy_state_file" != "$prefixed_legacy_state_file" ]] || \
    die 'Legacy mode and --team legacy collide in the launch-state namespace.'

  team_configure unsafe-state || die 'Could not configure the unsafe-state test team.'
  run_state_configure "$codex_test_dir" "$TEAM_MODE" "$TEAM_PREFIX_EFFECTIVE" || \
    die 'Could not configure the unsafe-state launch path.'
  run_state_prepare_storage || die 'Could not prepare the unsafe-state fixture.'
  mkdir -- "$RUN_STATE_FILE"
  unsafe_state_marker="$temporary_root/unsafe-state-workspace"
  unsafe_state_log="$temporary_root/unsafe-state.log"
  if env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$codex_test_dir" \
       MOCK_HERDR_MODE=multi-root-success \
       MOCK_PROJECT_ROOT="$PROJECT_ROOT" \
       MOCK_WORKSPACE_MARKER="$unsafe_state_marker" \
       "$SCRIPT_DIR/start.sh" --no-focus --team unsafe-state --cwd "$PROJECT_ROOT" \
       >"$unsafe_state_log" 2>&1; then
    die 'start.sh accepted a directory at its current.json target.'
  fi
  grep -Fq 'Could not prepare private launch-state storage' "$unsafe_state_log" || {
    command cat "$unsafe_state_log" >&2
    die 'Unsafe current.json target failed without the stable storage diagnostic.'
  }
  [[ ! -e "$unsafe_state_marker" ]] || \
    die 'Unsafe current.json target reached Herdr workspace creation.'

  team_configure unsafe-link || die 'Could not configure the state-symlink test team.'
  run_state_configure "$codex_test_dir" "$TEAM_MODE" "$TEAM_PREFIX_EFFECTIVE" || \
    die 'Could not configure the state-symlink launch path.'
  run_state_prepare_storage || die 'Could not prepare the state-symlink fixture.'
  mkdir -- "$temporary_root/current-target-directory"
  ln -s "$temporary_root/current-target-directory" "$RUN_STATE_FILE"
  if run_state_prepare_storage; then
    die 'Launch-state storage accepted a current.json symlink to a directory.'
  fi

  invalid_utf8_value=$'invalid-\377'
  if run_state_validate_launch_strings "$invalid_utf8_value"; then
    die 'Launch-state validation accepted a value that cannot round-trip as valid UTF-8.'
  fi

  team_configure partialroot || die 'Could not configure the partial-root test team.'
  partial_root_marker="$temporary_root/partial-root-workspace"
  partial_root_log="$temporary_root/partial-root.log"
  if env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$codex_test_dir" \
       MOCK_HERDR_MODE=missing-root-pane \
       MOCK_PROJECT_ROOT="$PROJECT_ROOT" \
       MOCK_WORKSPACE_MARKER="$partial_root_marker" \
       "$SCRIPT_DIR/start.sh" --no-focus --team partialroot --cwd "$PROJECT_ROOT" \
       >"$partial_root_log" 2>&1; then
    die 'start.sh accepted a workspace response without a root pane ID.'
  fi
  [[ -e "$partial_root_marker" ]] || \
    die 'Missing-root-pane fixture did not create its retained workspace.'
  run_state_configure "$codex_test_dir" "$TEAM_MODE" "$TEAM_PREFIX_EFFECTIVE" || \
    die 'Could not derive the partial-root launch-state path.'
  run_state_load_scope || die 'Workspace creation without a root pane did not persist safe partial state.'
  [[ "$RUN_STATE_LOADED_STATUS" == partial && \
     "$RUN_STATE_LOADED_WORKSPACE_ID" == mock-workspace && \
     -z "$RUN_STATE_LOADED_PLANNER_PANE" ]] || \
    die 'Partial launch state lost the created workspace identity or invented a root pane.'

  team_configure "$REQUESTED_TEAM_PREFIX" || \
    die 'Could not restore the requested test team after launch-state edge cases.'
  printf '[OK] Launch-state namespaces, targets, UTF-8 inputs, and early partial failures fail closed\n'

  startup_lock_log="$temporary_root/startup-lock.log"
  startup_lock_marker="$temporary_root/startup-lock-workspace"
  team_configure github || die 'Could not configure the startup-lock test team.'
  run_state_configure "$codex_test_dir" "$TEAM_MODE" "$TEAM_PREFIX_EFFECTIVE" || \
    die 'Could not configure startup-lock test storage.'
  run_state_prepare_storage || die 'Could not prepare startup-lock test storage.'
  run_state_acquire_start_lock static-lock-holder || \
    die 'Could not acquire the parent startup-lock fixture.'
  if env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$codex_test_dir" \
       MOCK_HERDR_MODE=multi-root-success \
       MOCK_PROJECT_ROOT="$PROJECT_ROOT" \
       MOCK_WORKSPACE_MARKER="$startup_lock_marker" \
       "$SCRIPT_DIR/start.sh" --no-focus --team github --cwd "$PROJECT_ROOT" \
       >"$startup_lock_log" 2>&1; then
    run_state_release_start_lock || true
    die 'start.sh ignored another active managed startup.'
  fi
  run_state_release_start_lock || die 'Could not release the parent startup-lock fixture.'
  grep -Fq 'Another herdr-codex-team startup is active' "$startup_lock_log" || {
    command cat "$startup_lock_log" >&2
    die 'Concurrent startup failed without the stable active-lock diagnostic.'
  }
  [[ ! -e "$startup_lock_marker" ]] || \
    die 'Concurrent startup reached workspace creation before lock rejection.'

  lock_host=$(run_state_host_id)
  mkdir -- "$RUN_STATE_LOCK_DIR"
  {
    printf 'token=dead-owner-token\n'
    printf 'pid=999999999\n'
    printf 'host=%s\n' "$lock_host"
    printf 'run_id=dead-owner-run\n'
    printf 'team=github\n'
  } >"$RUN_STATE_LOCK_DIR/owner"
  chmod 600 "$RUN_STATE_LOCK_DIR/owner"
  run_state_acquire_start_lock recovered-owner-run || \
    die 'Could not recover a well-formed dead same-host startup owner.'
  held_lock_token=$RUN_STATE_LOCK_TOKEN
  RUN_STATE_LOCK_TOKEN=wrong-release-token
  if run_state_release_start_lock; then
    die 'Startup-lock release ignored an owner-token mismatch.'
  fi
  [[ -d "$RUN_STATE_LOCK_DIR" && ! -L "$RUN_STATE_LOCK_DIR" ]] || \
    die 'Owner-token mismatch removed the startup lock.'
  RUN_STATE_LOCK_TOKEN=$held_lock_token
  run_state_release_start_lock || die 'Could not release the recovered startup lock.'

  mkdir -- "$RUN_STATE_LOCK_DIR"
  {
    printf 'token=malformed-owner-token\n'
    printf 'pid=999999999\n'
    printf 'host=%s\n' "$lock_host"
    printf 'run_id=malformed-owner-run\n'
  } >"$RUN_STATE_LOCK_DIR/owner"
  chmod 600 "$RUN_STATE_LOCK_DIR/owner"
  if run_state_acquire_start_lock malformed-owner-retry >/dev/null 2>&1; then
    die 'Startup lock accepted an owner record with a missing Team field.'
  fi
  [[ -d "$RUN_STATE_LOCK_DIR" ]] || \
    die 'Malformed startup-lock ownership was deleted instead of failing closed.'
  rm -f -- "$RUN_STATE_LOCK_DIR/owner"
  rmdir -- "$RUN_STATE_LOCK_DIR"
  team_configure "$REQUESTED_TEAM_PREFIX" || \
    die 'Could not restore the requested test team after startup-lock validation.'
  printf '[OK] Managed startup lock serializes, recovers dead owners, and checks ownership\n'

  collision_log="$temporary_root/collision.log"
  if env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$codex_test_dir" \
       MOCK_WORKSPACE_MARKER="$workspace_marker" \
       "$SCRIPT_DIR/start.sh" --no-focus --team github --cwd "$PROJECT_ROOT" \
       >"$collision_log" 2>&1; then
    die 'start.sh accepted an exact prefixed live-name collision.'
  fi
  grep -Fq 'agent_name_taken' "$collision_log" || {
    command cat "$collision_log" >&2
    die 'Collision preflight failed without the expected agent_name_taken diagnostic.'
  }
  [[ ! -e "$workspace_marker" ]] || \
    die 'Collision preflight created a workspace before failing.'
  printf '[OK] Exact prefixed collision fails before workspace creation\n'

  shared_worktree_log="$temporary_root/shared-worktree.log"
  shared_worktree_marker="$temporary_root/shared-worktree-created"
  if env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$codex_test_dir" \
       MOCK_HERDR_MODE=shared-worktree \
       MOCK_PROJECT_ROOT="$PROJECT_ROOT" \
       MOCK_WORKSPACE_MARKER="$shared_worktree_marker" \
       MOCK_HERDR_CALL_LOG="$temporary_root/shared-worktree-calls.log" \
       MOCK_SPLIT_COUNTER="$temporary_root/shared-worktree-splits" \
       "$SCRIPT_DIR/start.sh" --no-focus --team github --cwd "$PROJECT_ROOT" \
       >"$shared_worktree_log" 2>&1; then
    die 'start.sh accepted another Herdr team in the same Git worktree.'
  fi
  grep -Fq 'shared_git_worktree:' "$shared_worktree_log" || {
    command cat "$shared_worktree_log" >&2
    die 'Shared-worktree preflight failed without the stable diagnostic.'
  }
  grep -Fq 'docs-coder' "$shared_worktree_log" || \
    die 'Shared-worktree diagnostic omitted the conflicting live name.'
  [[ ! -e "$shared_worktree_marker" ]] || \
    die 'Shared-worktree preflight created a workspace before failing.'
  printf '[OK] Another Herdr team in the same Git worktree fails before workspace creation\n'

  uninspectable_worktree_log="$temporary_root/uninspectable-worktree.log"
  uninspectable_worktree_marker="$temporary_root/uninspectable-worktree-created"
  if env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$codex_test_dir" \
       MOCK_HERDR_MODE=uninspectable-worktree \
       MOCK_PROJECT_ROOT="$PROJECT_ROOT" \
       MOCK_WORKSPACE_MARKER="$uninspectable_worktree_marker" \
       "$SCRIPT_DIR/start.sh" --no-focus --team github --cwd "$PROJECT_ROOT" \
       >"$uninspectable_worktree_log" 2>&1; then
    die 'start.sh accepted an uninspectable live Herdr role agent.'
  fi
  grep -Fq 'shared_git_worktree_unverified:' "$uninspectable_worktree_log" || {
    command cat "$uninspectable_worktree_log" >&2
    die 'Uninspectable role-agent preflight failed without the stable diagnostic.'
  }
  [[ ! -e "$uninspectable_worktree_marker" ]] || \
    die 'Uninspectable role-agent preflight created a workspace before failing.'
  printf '[OK] Uninspectable live Herdr role agent fails closed before workspace creation\n'

  for malformed_kind in numeric-kind boolean-kind; do
    malformed_kind_log="$temporary_root/$malformed_kind.log"
    malformed_kind_marker="$temporary_root/$malformed_kind-created"
    if env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$codex_test_dir" \
         MOCK_HERDR_MODE="$malformed_kind" \
         MOCK_WORKSPACE_MARKER="$malformed_kind_marker" \
         "$SCRIPT_DIR/start.sh" --no-focus --team github --cwd "$PROJECT_ROOT" \
         >"$malformed_kind_log" 2>&1; then
      die "start.sh accepted a matching role agent with malformed kind type: $malformed_kind"
    fi
    grep -Fq 'shared_git_worktree_unverified:' "$malformed_kind_log" || {
      command cat "$malformed_kind_log" >&2
      die "Malformed role-agent kind failed without the stable diagnostic: $malformed_kind"
    }
    [[ ! -e "$malformed_kind_marker" ]] || \
      die "Malformed role-agent kind reached workspace creation: $malformed_kind"
  done
  printf '[OK] Numeric and boolean role-agent kinds fail closed before workspace creation\n'

  separate_git_root="$temporary_root/separate-worktree"
  mkdir -p "$separate_git_root"
  git -C "$separate_git_root" init -q

  mixed_worktree_log="$temporary_root/mixed-worktree.log"
  mixed_worktree_marker="$temporary_root/mixed-worktree-created"
  if env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$codex_test_dir" \
       MOCK_HERDR_MODE=mixed-worktree \
       MOCK_PROJECT_ROOT="$PROJECT_ROOT" \
       MOCK_OTHER_WORKTREE="$separate_git_root" \
       MOCK_WORKSPACE_MARKER="$mixed_worktree_marker" \
       "$SCRIPT_DIR/start.sh" --no-focus --team github --cwd "$PROJECT_ROOT" \
       >"$mixed_worktree_log" 2>&1; then
    die 'start.sh accepted target cwd when foreground_cwd pointed elsewhere.'
  fi
  grep -Fq 'shared_git_worktree:' "$mixed_worktree_log" || {
    command cat "$mixed_worktree_log" >&2
    die 'Mixed-cwd preflight failed without the shared-worktree diagnostic.'
  }
  [[ ! -e "$mixed_worktree_marker" ]] || \
    die 'Mixed-cwd preflight created a workspace before failing.'
  printf '[OK] Both cwd and foreground_cwd participate in shared-worktree rejection\n'

  ancestor_worktree_log="$temporary_root/ancestor-worktree.log"
  ancestor_worktree_marker="$temporary_root/ancestor-worktree-created"
  if env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$codex_test_dir" \
       MOCK_HERDR_MODE=ancestor-worktree \
       MOCK_ANCESTOR_CWD="$(dirname "$PROJECT_ROOT")" \
       MOCK_WORKSPACE_MARKER="$ancestor_worktree_marker" \
       "$SCRIPT_DIR/start.sh" --no-focus --team github --cwd "$PROJECT_ROOT" \
       >"$ancestor_worktree_log" 2>&1; then
    die 'start.sh accepted an existing role cwd that contains the requested worktree.'
  fi
  grep -Fq 'shared_git_worktree:' "$ancestor_worktree_log" || {
    command cat "$ancestor_worktree_log" >&2
    die 'Ancestor-cwd preflight failed without the shared-worktree diagnostic.'
  }
  [[ ! -e "$ancestor_worktree_marker" ]] || \
    die 'Ancestor-cwd preflight created a workspace before failing.'
  printf '[OK] Ancestor cwd coverage of the requested worktree fails closed\n'

  root_worktree_log="$temporary_root/root-worktree.log"
  root_worktree_marker="$temporary_root/root-worktree-created"
  if env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$codex_test_dir" \
       MOCK_HERDR_MODE=root-worktree \
       MOCK_WORKSPACE_MARKER="$root_worktree_marker" \
       "$SCRIPT_DIR/start.sh" --no-focus --team github --cwd "$PROJECT_ROOT" \
       >"$root_worktree_log" 2>&1; then
    die 'start.sh accepted an existing role rooted at the filesystem root.'
  fi
  grep -Fq 'shared_git_worktree:' "$root_worktree_log" || {
    command cat "$root_worktree_log" >&2
    die 'Root-cwd preflight failed without the shared-worktree diagnostic.'
  }
  [[ ! -e "$root_worktree_marker" ]] || \
    die 'Root-cwd preflight created a workspace before failing.'
  printf '[OK] Filesystem-root cwd coverage fails closed\n'

  separate_worktree_log="$temporary_root/separate-worktree.log"
  separate_worktree_marker="$temporary_root/separate-worktree-created"
  : >"$temporary_root/separate-worktree-calls.log"
  if ! env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$codex_test_dir" \
       MOCK_HERDR_MODE=separate-worktree \
       MOCK_PROJECT_ROOT="$PROJECT_ROOT" \
       MOCK_OTHER_WORKTREE="$separate_git_root" \
       MOCK_WORKSPACE_MARKER="$separate_worktree_marker" \
       MOCK_HERDR_CALL_LOG="$temporary_root/separate-worktree-calls.log" \
       MOCK_SPLIT_COUNTER="$temporary_root/separate-worktree-splits" \
       "$SCRIPT_DIR/start.sh" --no-focus --team github --cwd "$PROJECT_ROOT" \
       >"$separate_worktree_log" 2>&1; then
    command cat "$separate_worktree_log" >&2
    die 'start.sh rejected a role agent in a different Git worktree.'
  fi
  [[ -e "$separate_worktree_marker" ]] || \
    die 'Different-worktree fixture did not reach workspace creation.'
  grep -Fq -- '--label codex-team:github ' \
    "$temporary_root/separate-worktree-calls.log" || \
    die 'Prefixed start did not use the short codex-team:<team> workspace label.'
  if grep -Fq -- '--label codex-team:github:' \
       "$temporary_root/separate-worktree-calls.log"; then
    die 'Prefixed start repeated the project directory in the workspace label.'
  fi
  if grep -Fq 'shared_git_worktree' "$separate_worktree_log"; then
    command cat "$separate_worktree_log" >&2
    die 'Different Git worktree was misclassified as shared.'
  fi
  printf '[OK] Another Herdr team in a different Git worktree is allowed\n'

  multi_root_log="$temporary_root/multi-root.log"
  multi_root_marker="$temporary_root/multi-root-created"
  multi_root_calls="$temporary_root/multi-root-calls.log"
  multi_root_splits="$temporary_root/multi-root-splits"
  : >"$multi_root_calls"
  if ! env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$codex_test_dir" \
       MOCK_HERDR_MODE=multi-root-success \
       MOCK_PROJECT_ROOT="$non_git_primary" \
       MOCK_EXTRA_ROOT="$non_git_extra" \
       MOCK_OMIT_LAUNCH_PENDING=1 \
       MOCK_WORKSPACE_MARKER="$multi_root_marker" \
       MOCK_HERDR_CALL_LOG="$multi_root_calls" \
       MOCK_SPLIT_COUNTER="$multi_root_splits" \
       "$SCRIPT_DIR/start.sh" --no-focus --team github \
       --cwd "$non_git_primary" --add-dir "$non_git_extra" \
       >"$multi_root_log" 2>&1; then
    command cat "$multi_root_log" >&2
    die 'start.sh rejected an explicit two-root non-Git workspace.'
  fi
  [[ -e "$multi_root_marker" ]] || \
    die 'Two-root non-Git fixture did not reach workspace creation.'
  grep -Fq 'Requested scope includes one or more non-Git directories' "$multi_root_log" || \
    die 'Non-Git multi-root startup omitted the degraded-evidence warning.'
  [[ $(grep -Fc -- "--add-dir $non_git_extra" "$multi_root_calls") -eq 2 ]] || {
    command cat "$multi_root_calls" >&2
    die 'The exact additional root was not passed once each to Planner and Coder.'
  }
  grep -F 'agent start github-planner ' "$multi_root_calls" | \
    grep -Fq -- "--add-dir $non_git_extra" || \
    die 'The exact additional root was not passed to Planner as read-only workspace context.'
  grep -F 'agent start github-coder ' "$multi_root_calls" | \
    grep -Fq -- "--add-dir $non_git_extra" || \
    die 'The exact additional root was not passed to Coder.'
  if grep -F 'agent start github-reviewer ' "$multi_root_calls" | grep -Fq -- ' --add-dir '; then
    command cat "$multi_root_calls" >&2
    die 'Reviewer received --add-dir even though its managed review scope is the primary root.'
  fi
  [[ $(grep -Fc -- '-c agents.enabled=false' "$multi_root_calls") -eq 3 ]] || \
    die 'The native-agent disable override was not passed to all three Codex roles.'
  [[ $(grep -Fc -- '-c default_permissions="herdr_read_only_network"' "$multi_root_calls") -eq 2 ]] || \
    die 'Planner and Reviewer did not receive the read-only network permission profile.'
  [[ $(grep -Fc -- '-c default_permissions="herdr_workspace_network"' "$multi_root_calls") -eq 1 ]] || \
    die 'Coder did not receive the workspace network permission profile.'
  [[ $(grep -Fc -- '-c permissions.herdr_read_only_network.network.enabled=true' "$multi_root_calls") -eq 2 ]] || \
    die 'Planner and Reviewer did not receive enabled command networking.'
  [[ $(grep -Fc -- '-c permissions.herdr_workspace_network.network.enabled=true' "$multi_root_calls") -eq 1 ]] || \
    die 'Coder did not receive enabled command networking.'
  if grep -Eq -- '(^| )--sandbox( |$)|sandbox_workspace_write' "$multi_root_calls"; then
    command cat "$multi_root_calls" >&2
    die 'Managed startup mixed a legacy sandbox option into permission-profile argv.'
  fi
  [[ $(grep -Fc -- "--cwd $non_git_primary" "$multi_root_calls") -eq 3 ]] || {
    command cat "$multi_root_calls" >&2
    die 'Workspace and both pane splits did not retain the primary cwd.'
  }
  if grep -Fq -- "--cwd $non_git_extra" "$multi_root_calls"; then
    die 'An additional root was incorrectly used as a Herdr pane cwd.'
  fi
  grep -Fq -- "doctor.sh --team github --cwd $non_git_primary --add-dir $non_git_extra" "$multi_root_log" || \
    die 'Startup did not print a reusable multi-root doctor command.'
  printf '[OK] Explicit non-Git multi-root startup gives Planner read-only root context and Coder writable roots\n'

  team_configure github || die 'Could not configure the launch-record test team.'
  run_state_configure "$codex_test_dir" "$TEAM_MODE" "$TEAM_PREFIX_EFFECTIVE" || \
    die 'Could not derive the launch-record test path.'
  state_file=$RUN_STATE_FILE
  [[ -f "$state_file" && ! -L "$state_file" ]] || \
    die 'Successful startup did not create a safe user-local launch record.'
  run_state_load_scope || die 'Successful startup wrote an invalid launch record.'
  [[ "$RUN_STATE_LOADED_STATUS" == ready && \
     "$RUN_STATE_LOADED_CWD" == "$non_git_primary" && \
     "$RUN_STATE_LOADED_WORKSPACE_ID" == mock-workspace && \
     "$RUN_STATE_LOADED_PLANNER_PANE" == mock-root && \
     "$RUN_STATE_LOADED_CODER_PANE" == mock-pane-1 && \
     "$RUN_STATE_LOADED_REVIEWER_PANE" == mock-pane-2 ]] || \
    die 'Launch record did not preserve exact root/workspace/pane identity.'
  [[ ${#RUN_STATE_LOADED_ADD_DIRS[@]} -eq 1 && \
     "${RUN_STATE_LOADED_ADD_DIRS[0]}" == "$non_git_extra" ]] || \
    die 'Launch record did not preserve the ordered additional-root list.'

  state_doctor_log="$temporary_root/state-doctor.log"
  state_doctor_calls="$temporary_root/state-doctor-calls.log"
  : >"$state_doctor_calls"
  if ! env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$codex_test_dir" \
       MOCK_HERDR_MODE=doctor-success \
       MOCK_HERDR_CALL_LOG="$state_doctor_calls" \
       MOCK_PROJECT_ROOT="$non_git_primary" \
       MOCK_EXTRA_ROOT="$non_git_extra" \
       MOCK_WORKSPACE_ID=mock-workspace \
       MOCK_PLANNER_PANE=mock-root \
       MOCK_CODER_PANE=mock-pane-1 \
       MOCK_REVIEWER_PANE=mock-pane-2 \
       "$SCRIPT_DIR/doctor.sh" --team github \
       >"$state_doctor_log" 2>&1; then
    command cat "$state_doctor_log" >&2
    die 'doctor.sh could not verify a live team from its saved launch scope.'
  fi
  grep -Fq 'Loaded launch record' "$state_doctor_log" || \
    die 'doctor.sh did not report its user-local launch-record source.'
  grep -Fq "Team additional root: $non_git_extra" "$state_doctor_log" || \
    die 'doctor.sh did not replay the recorded additional root.'

  if ! env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$codex_test_dir" \
       MOCK_HERDR_MODE=doctor-success \
       MOCK_HERDR_CALL_LOG="$state_doctor_calls" \
       MOCK_PROJECT_ROOT="$non_git_primary" \
       MOCK_EXTRA_ROOT="$non_git_extra" \
       MOCK_WORKSPACE_ID=mock-workspace \
       MOCK_PLANNER_PANE=mock-root \
       MOCK_CODER_PANE=mock-pane-1 \
       MOCK_REVIEWER_PANE=mock-pane-2 \
       "$SCRIPT_DIR/doctor.sh" --bind-record-if-present --team github \
       --cwd "$non_git_primary" --add-dir "$non_git_extra" \
       >"$temporary_root/state-doctor-bound-match.log" 2>&1; then
    command cat "$temporary_root/state-doctor-bound-match.log" >&2
    die 'Record-bound explicit Doctor rejected the original workspace/pane identities.'
  fi
  grep -Fq 'Loaded launch record' "$temporary_root/state-doctor-bound-match.log" || \
    die 'Record-bound explicit Doctor did not report the launch-record binding.'

  if env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$codex_test_dir" \
       MOCK_HERDR_MODE=doctor-success \
       MOCK_HERDR_CALL_LOG="$state_doctor_calls" \
       MOCK_PROJECT_ROOT="$non_git_primary" \
       MOCK_EXTRA_ROOT="$non_git_extra" \
       MOCK_WORKSPACE_ID=different-workspace \
       MOCK_PLANNER_PANE=mock-root \
       MOCK_CODER_PANE=mock-pane-1 \
       MOCK_REVIEWER_PANE=mock-pane-2 \
       "$SCRIPT_DIR/doctor.sh" --team github \
       >"$temporary_root/state-doctor-stale-runtime.log" 2>&1; then
    die 'Record-backed Doctor accepted a different live workspace identity.'
  fi
  grep -Fq 'not recorded run workspace mock-workspace' \
    "$temporary_root/state-doctor-stale-runtime.log" || \
    die 'Stale workspace identity failed without the recorded-binding diagnostic.'

  if ! env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$codex_test_dir" \
       MOCK_HERDR_MODE=doctor-success \
       MOCK_HERDR_CALL_LOG="$state_doctor_calls" \
       MOCK_PROJECT_ROOT="$non_git_primary" \
       MOCK_EXTRA_ROOT="$non_git_extra" \
       MOCK_WORKSPACE_ID=different-workspace \
       MOCK_PLANNER_PANE=different-planner-pane \
       MOCK_CODER_PANE=different-coder-pane \
       MOCK_REVIEWER_PANE=different-reviewer-pane \
       "$SCRIPT_DIR/doctor.sh" --team github --cwd "$non_git_primary" \
       --add-dir "$non_git_extra" \
       >"$temporary_root/state-doctor-explicit-bypass.log" 2>&1; then
    command cat "$temporary_root/state-doctor-explicit-bypass.log" >&2
    die 'Explicit-root Doctor did not bypass stale recorded workspace/pane binding.'
  fi

  if env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$codex_test_dir" \
       MOCK_HERDR_MODE=doctor-success \
       MOCK_HERDR_CALL_LOG="$state_doctor_calls" \
       MOCK_PROJECT_ROOT="$non_git_primary" \
       MOCK_EXTRA_ROOT="$non_git_extra" \
       MOCK_WORKSPACE_ID=different-workspace \
       MOCK_PLANNER_PANE=different-planner-pane \
       MOCK_CODER_PANE=different-coder-pane \
       MOCK_REVIEWER_PANE=different-reviewer-pane \
       "$SCRIPT_DIR/doctor.sh" --bind-record-if-present --team github \
       --cwd "$non_git_primary" --add-dir "$non_git_extra" \
       >"$temporary_root/state-doctor-explicit-bound.log" 2>&1; then
    die 'Record-bound explicit Doctor accepted replaced workspace/pane identities.'
  fi
  grep -Fq 'not recorded run workspace mock-workspace' \
    "$temporary_root/state-doctor-explicit-bound.log" || \
    die 'Record-bound explicit Doctor failed without the recorded identity diagnostic.'

  : >"$state_doctor_calls"
  if env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$codex_test_dir" \
       MOCK_HERDR_MODE=doctor-success \
       MOCK_HERDR_CALL_LOG="$state_doctor_calls" \
       "$SCRIPT_DIR/doctor.sh" --bind-record-if-present --team github \
       --cwd "$separate_git_root" --add-dir "$non_git_extra" \
       >"$temporary_root/state-doctor-bound-scope.log" 2>&1; then
    die 'Record-bound Doctor accepted requested roots from a different launch.'
  fi
  grep -Fq 'does not match the existing launch record' \
    "$temporary_root/state-doctor-bound-scope.log" || \
    die 'Record-bound scope mismatch failed without the stable diagnostic.'
  [[ ! -s "$state_doctor_calls" ]] || \
    die 'Record-bound Doctor contacted Herdr before rejecting mismatched requested roots.'
  printf '[OK] Explicit reuse checks bind matching launch-record workspace and pane IDs\n'

  cp -p -- "$state_file" "$temporary_root/current.json.clean"
  printf '%s\n' '{"schema_version":1,"run_id":false}' >"$state_file"
  : >"$state_doctor_calls"
  if env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$codex_test_dir" \
       MOCK_HERDR_MODE=doctor-success \
       MOCK_HERDR_CALL_LOG="$state_doctor_calls" \
       "$SCRIPT_DIR/doctor.sh" --team github \
       >"$temporary_root/state-doctor-corrupt.log" 2>&1; then
    die 'doctor.sh accepted a malformed user-local launch record.'
  fi
  grep -Fq 'launch record is malformed or incompatible' \
    "$temporary_root/state-doctor-corrupt.log" || \
    die 'Malformed launch state failed without the stable diagnostic.'
  [[ ! -s "$state_doctor_calls" ]] || \
    die 'doctor.sh contacted Herdr before rejecting malformed launch state.'
  cp -p -- "$temporary_root/current.json.clean" "$state_file"

  sed 's/"schema_version": 1/"schema_version": true/' \
    "$temporary_root/current.json.clean" >"$state_file"
  if run_state_load_scope >/dev/null 2>&1; then
    die 'Launch-state parser accepted boolean true as schema version 1.'
  fi
  cp -p -- "$temporary_root/current.json.clean" "$state_file"

  sed 's/"schema_version": 1/"schema_version": 1.0/' \
    "$temporary_root/current.json.clean" >"$state_file"
  run_state_load_scope >/dev/null 2>&1 || \
    die 'Launch-state backends disagree on a mathematically integral schema version.'
  cp -p -- "$temporary_root/current.json.clean" "$state_file"

  invalid_state_byte=$'\377'
  while IFS= read -r state_line; do
    case "$state_line" in
      *'"run_id":'*) printf '  "run_id": "bad-%s",\n' "$invalid_state_byte" ;;
      *) printf '%s\n' "$state_line" ;;
    esac
  done <"$temporary_root/current.json.clean" >"$state_file"
  if run_state_load_scope >/dev/null 2>&1; then
    die 'Launch-state parser accepted raw invalid UTF-8 from current.json.'
  fi
  cp -p -- "$temporary_root/current.json.clean" "$state_file"

  sed 's/"sandbox": "workspace-write"/"sandbox": "read-only"/g' \
    "$temporary_root/current.json.clean" >"$state_file"
  if run_state_load_scope >/dev/null 2>&1; then
    die 'Launch-state parser accepted role sandbox values outside its schema.'
  fi
  cp -p -- "$temporary_root/current.json.clean" "$state_file"

  sed 's/"launch_record": "herdr-codex-team"/"launch_record": "other"/' \
    "$temporary_root/current.json.clean" >"$state_file"
  if run_state_load_scope >/dev/null 2>&1; then
    die 'Launch-state parser accepted a changed authority marker.'
  fi
  cp -p -- "$temporary_root/current.json.clean" "$state_file"

  sed 's/"workspace_id": "mock-workspace"/"workspace_id": ""/' \
    "$temporary_root/current.json.clean" >"$state_file"
  if run_state_load_scope >/dev/null 2>&1; then
    die 'Launch-state parser accepted an empty workspace ID.'
  fi
  cp -p -- "$temporary_root/current.json.clean" "$state_file"

  rm -f -- "$state_file"
  ln -s "$temporary_root/current.json.clean" "$state_file"
  : >"$state_doctor_calls"
  if env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$codex_test_dir" \
       MOCK_HERDR_MODE=doctor-success \
       MOCK_HERDR_CALL_LOG="$state_doctor_calls" \
       "$SCRIPT_DIR/doctor.sh" --team github \
       >"$temporary_root/state-doctor-symlink.log" 2>&1; then
    die 'doctor.sh accepted a symlinked current.json launch record.'
  fi
  [[ ! -s "$state_doctor_calls" ]] || \
    die 'doctor.sh contacted Herdr before rejecting a symlinked launch record.'
  rm -f -- "$state_file"
  cp -p -- "$temporary_root/current.json.clean" "$state_file"

  state_symlink_codex="$temporary_root/state-symlink-codex"
  state_symlink_target="$temporary_root/state-symlink-target"
  mkdir -p "$state_symlink_codex" \
    "$state_symlink_target/state/v1/teams/prefixed-github"
  cp -p -- "$temporary_root/current.json.clean" \
    "$state_symlink_target/state/v1/teams/prefixed-github/current.json"
  ln -s "$state_symlink_target" "$state_symlink_codex/herdr-codex-team"
  : >"$state_doctor_calls"
  if env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$state_symlink_codex" \
       MOCK_HERDR_MODE=doctor-success \
       MOCK_HERDR_CALL_LOG="$state_doctor_calls" \
       "$SCRIPT_DIR/doctor.sh" --team github \
       >"$temporary_root/state-doctor-parent-symlink.log" 2>&1; then
    die 'doctor.sh accepted a launch record through a symlinked managed parent.'
  fi
  [[ ! -s "$state_doctor_calls" ]] || \
    die 'doctor.sh contacted Herdr before rejecting a symlinked state parent.'

  team_configure "$REQUESTED_TEAM_PREFIX" || \
    die 'Could not restore the requested test team after launch-record validation.'
  printf '[OK] User-local launch state is atomic, replayable, and fail-closed\n'

  single_non_git_log="$temporary_root/single-non-git.log"
  single_non_git_marker="$temporary_root/single-non-git-created"
  single_non_git_calls="$temporary_root/single-non-git-calls.log"
  : >"$single_non_git_calls"
  if ! env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$codex_test_dir" \
       MOCK_HERDR_MODE=multi-root-success \
       MOCK_PROJECT_ROOT="$non_git_primary" \
       MOCK_WORKSPACE_MARKER="$single_non_git_marker" \
       MOCK_HERDR_CALL_LOG="$single_non_git_calls" \
       MOCK_SPLIT_COUNTER="$temporary_root/single-non-git-splits" \
       "$SCRIPT_DIR/start.sh" --no-focus --team github \
       --cwd "$non_git_primary" >"$single_non_git_log" 2>&1; then
    command cat "$single_non_git_log" >&2
    die 'start.sh rejected an existing single-root non-Git project.'
  fi
  [[ -e "$single_non_git_marker" ]] || \
    die 'Single-root non-Git fixture did not reach workspace creation.'
  grep -Fq 'Requested scope includes one or more non-Git directories' "$single_non_git_log" || \
    die 'Single-root non-Git startup omitted the degraded-evidence warning.'
  [[ $(grep -Fc 'agent start' "$single_non_git_calls") -eq 3 ]] || \
    die 'Single-root non-Git startup did not start all three mocked roles.'
  if grep -Fq -- '--add-dir' "$single_non_git_calls"; then
    die 'Single-root non-Git startup invented an additional root.'
  fi
  printf '[OK] Single-root non-Git startup no longer requires a Git worktree\n'

  for primary_mode in missing-primary wrong-primary; do
    primary_log="$temporary_root/$primary_mode.log"
    primary_marker="$temporary_root/$primary_mode-created"
    primary_calls="$temporary_root/$primary_mode-calls.log"
    : >"$primary_calls"
    if env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$codex_test_dir" \
         MOCK_HERDR_MODE="$primary_mode" \
         MOCK_PROJECT_ROOT="$non_git_primary" \
         MOCK_FINAL_PROJECT_ROOT="$separate_git_root" \
         MOCK_EXTRA_ROOT="$non_git_extra" \
         MOCK_WORKSPACE_MARKER="$primary_marker" \
         MOCK_HERDR_CALL_LOG="$primary_calls" \
         MOCK_SPLIT_COUNTER="$temporary_root/$primary_mode-splits" \
         "$SCRIPT_DIR/start.sh" --no-focus --team github \
         --cwd "$non_git_primary" --add-dir "$non_git_extra" \
         >"$primary_log" 2>&1; then
      die "start.sh accepted final agent cwd evidence in mode $primary_mode."
    fi
    [[ -e "$primary_marker" ]] || \
      die "$primary_mode fixture did not reach final readiness validation."
    grep -Fq 'primary_scope=false' "$primary_log" || {
      command cat "$primary_log" >&2
      die "$primary_mode failed without the primary-scope readiness diagnostic."
    }
  done
  printf '[OK] Final readiness rejects missing or wrong primary cwd evidence\n'

  scope_collision_log="$temporary_root/scope-adddir-collision.log"
  scope_collision_marker="$temporary_root/scope-adddir-collision-created"
  if env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$codex_test_dir" \
       MOCK_HERDR_MODE=scope-adddir-collision \
       MOCK_OTHER_WORKTREE="$separate_git_root" \
       MOCK_EXTRA_ROOT="$non_git_extra" \
       MOCK_WORKSPACE_MARKER="$scope_collision_marker" \
       "$SCRIPT_DIR/start.sh" --no-focus --team github \
       --cwd "$non_git_primary" --add-dir "$non_git_extra" \
       >"$scope_collision_log" 2>&1; then
    die 'start.sh missed another Team whose --add-dir overlaps the requested scope.'
  fi
  grep -Fq 'shared_workspace_scope:' "$scope_collision_log" || {
    command cat "$scope_collision_log" >&2
    die 'Cross-team add-dir collision failed without the stable diagnostic.'
  }
  [[ ! -e "$scope_collision_marker" ]] || \
    die 'Cross-team add-dir collision reached workspace creation.'

  scope_unmanaged_log="$temporary_root/scope-unmanaged.log"
  scope_unmanaged_marker="$temporary_root/scope-unmanaged-created"
  if env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$codex_test_dir" \
       MOCK_HERDR_MODE=scope-unmanaged \
       MOCK_OTHER_WORKTREE="$separate_git_root" \
       MOCK_WORKSPACE_MARKER="$scope_unmanaged_marker" \
       "$SCRIPT_DIR/start.sh" --no-focus --team github \
       --cwd "$non_git_primary" --add-dir "$non_git_extra" \
       >"$scope_unmanaged_log" 2>&1; then
    die 'start.sh accepted a live role whose implicit writable roots were unverified.'
  fi
  grep -Fq 'shared_workspace_scope_unverified:' "$scope_unmanaged_log" || \
    die 'Unmanaged live scope failed without the fail-closed diagnostic.'
  [[ ! -e "$scope_unmanaged_marker" ]] || \
    die 'Unmanaged live scope reached workspace creation.'
  printf '[OK] Cross-team additional-root conflicts and unverified scopes fail before creation\n'

  doctor_log="$temporary_root/doctor.log"
  doctor_call_log="$temporary_root/doctor-calls.log"
  : >"$doctor_call_log"
  if ! env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$codex_test_dir" \
       MOCK_HERDR_MODE=doctor-success \
       MOCK_HERDR_CALL_LOG="$doctor_call_log" \
       MOCK_PROJECT_ROOT="$PROJECT_ROOT" \
       MOCK_OMIT_LAUNCH_PENDING=1 \
       "$SCRIPT_DIR/doctor.sh" --team github --cwd "$PROJECT_ROOT" \
       >"$doctor_log" 2>&1; then
    command cat "$doctor_log" >&2
    die 'doctor.sh rejected a coherent exact-name prefixed team fixture.'
  fi
  for role in planner coder reviewer; do
    grep -Fq "github-$role identity:" "$doctor_log" || \
      die "doctor.sh did not report github-$role identity evidence."
    grep -Fxq "agent get github-$role" "$doctor_call_log" || \
      die "doctor.sh did not query exact live name github-$role."
  done
  if grep -Eq '^agent get (planner|coder|reviewer|auth-)' "$doctor_call_log"; then
    command cat "$doctor_call_log" >&2
    die 'doctor.sh queried a generic or cross-team live name in prefixed mode.'
  fi
  printf '[OK] doctor.sh validates one exact prefixed team without legacy launch_pending\n'

  doctor_multi_root_log="$temporary_root/doctor-multi-root.log"
  if ! env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$codex_test_dir" \
       MOCK_HERDR_MODE=doctor-success \
       MOCK_HERDR_CALL_LOG="$doctor_call_log" \
       MOCK_PROJECT_ROOT="$non_git_primary" \
       MOCK_EXTRA_ROOT="$non_git_extra" \
       "$SCRIPT_DIR/doctor.sh" --team github --cwd "$non_git_primary" \
       --add-dir "$non_git_extra" >"$doctor_multi_root_log" 2>&1; then
    command cat "$doctor_multi_root_log" >&2
    die 'doctor.sh rejected matching multi-root process argv.'
  fi
  [[ $(grep -Fc 'additional roots match the requested writable --add-dir list' "$doctor_multi_root_log") -eq 1 ]] || \
    die 'doctor.sh did not verify the exact writable additional roots for Coder.'
  [[ $(grep -Fc 'additional roots match the requested read-only workspace context' "$doctor_multi_root_log") -eq 1 ]] || \
    die 'doctor.sh did not verify Planner additional roots as read-only workspace context.'
  [[ $(grep -Fc 'has no --add-dir writable-root grants, as required by read-only sandbox' "$doctor_multi_root_log") -eq 1 ]] || \
    die 'doctor.sh did not verify that Reviewer has no --add-dir grant.'
  if env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$codex_test_dir" \
       MOCK_HERDR_MODE=doctor-success \
       MOCK_HERDR_CALL_LOG="$doctor_call_log" \
       MOCK_PROJECT_ROOT="$non_git_primary" \
       MOCK_EXTRA_ROOT="$non_git_extra" \
       "$SCRIPT_DIR/doctor.sh" --team github --cwd "$non_git_primary" \
       >"$temporary_root/doctor-missing-add-dir.log" 2>&1; then
    die 'doctor.sh accepted a live additional root omitted from its expected options.'
  fi
  grep -Fq 'additional-root argv does not match its role' "$temporary_root/doctor-missing-add-dir.log" || \
    die 'doctor.sh missing-add-dir rejection used the wrong diagnostic.'
  printf '[OK] doctor.sh verifies role-aware additional-root argv\n'

  doctor_cwd_mismatch_log="$temporary_root/doctor-cwd-mismatch.log"
  if env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$codex_test_dir" \
       MOCK_HERDR_MODE=doctor-success \
       MOCK_HERDR_CALL_LOG="$doctor_call_log" \
       MOCK_PROJECT_ROOT="$PROJECT_ROOT" \
       MOCK_AGENT_CWD="$PROJECT_ROOT" \
       MOCK_FOREGROUND_CWD="$non_git_primary" \
       "$SCRIPT_DIR/doctor.sh" --team github --cwd "$PROJECT_ROOT" \
       >"$doctor_cwd_mismatch_log" 2>&1; then
    die 'doctor.sh accepted conflicting cwd and foreground_cwd evidence.'
  fi
  grep -Fq 'cwd and foreground_cwd that resolve to different directories' \
    "$doctor_cwd_mismatch_log" || \
    die 'doctor.sh conflicting-cwd rejection used the wrong diagnostic.'

  doctor_missing_cwd_log="$temporary_root/doctor-nonexistent-cwd.log"
  if env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$codex_test_dir" \
       MOCK_HERDR_MODE=doctor-success \
       MOCK_HERDR_CALL_LOG="$doctor_call_log" \
       MOCK_PROJECT_ROOT="$PROJECT_ROOT" \
       MOCK_AGENT_CWD="$temporary_root/nonexistent-live-cwd" \
       MOCK_FOREGROUND_CWD="$temporary_root/nonexistent-live-cwd" \
       "$SCRIPT_DIR/doctor.sh" --team github \
       >"$doctor_missing_cwd_log" 2>&1; then
    die 'doctor.sh accepted a nonexistent same-team cwd without --cwd.'
  fi
  grep -Fq 'does not exist or is not a directory' "$doctor_missing_cwd_log" || \
    die 'doctor.sh nonexistent-cwd rejection used the wrong diagnostic.'
  printf '[OK] doctor.sh rejects conflicting or nonexistent cwd evidence\n'

  doctor_malformed_lifecycle_log="$temporary_root/doctor-malformed-lifecycle.log"
  if env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$codex_test_dir" \
       MOCK_HERDR_MODE=doctor-success \
       MOCK_HERDR_CALL_LOG="$doctor_call_log" \
       MOCK_PROJECT_ROOT="$PROJECT_ROOT" \
       MOCK_LAUNCH_PENDING_JSON='"false"' \
       "$SCRIPT_DIR/doctor.sh" --team github --cwd "$PROJECT_ROOT" \
       >"$doctor_malformed_lifecycle_log" 2>&1; then
    die 'doctor.sh accepted a string-valued launch_pending field.'
  fi
  grep -Fq 'malformed identity or lifecycle fields' "$doctor_malformed_lifecycle_log" || \
    die 'doctor.sh malformed-lifecycle rejection used the wrong diagnostic.'

  start_malformed_lifecycle_log="$temporary_root/start-malformed-lifecycle.log"
  if env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$codex_test_dir" \
       MOCK_HERDR_MODE=multi-root-success \
       MOCK_PROJECT_ROOT="$non_git_primary" \
       MOCK_EXTRA_ROOT="$non_git_extra" \
       MOCK_FINAL_LAUNCH_PENDING_JSON='"false"' \
       MOCK_WORKSPACE_MARKER="$temporary_root/start-malformed-lifecycle-created" \
       MOCK_HERDR_CALL_LOG="$temporary_root/start-malformed-lifecycle-calls" \
       MOCK_SPLIT_COUNTER="$temporary_root/start-malformed-lifecycle-splits" \
       "$SCRIPT_DIR/start.sh" --no-focus --team github \
       --cwd "$non_git_primary" --add-dir "$non_git_extra" \
       >"$start_malformed_lifecycle_log" 2>&1; then
    die 'start.sh accepted a string-valued final launch_pending field.'
  fi
  grep -Fq 'final state is not ready' "$start_malformed_lifecycle_log" || \
    die 'start.sh malformed-lifecycle rejection used the wrong diagnostic.'
  printf '[OK] doctor/start reject malformed lifecycle field types\n'

  cp -p -- "$codex_test_dir/coder.config.toml" "$temporary_root/coder.config.toml.clean"
  awk '
    BEGIN { changed = 0 }
    !changed && /You are the Implementation Engineer/ {
      sub(/You are the Implementation Engineer/, "You are the quietly modified Implementation Engineer")
      changed = 1
    }
    { print }
    END { if (!changed) exit 2 }
  ' "$temporary_root/coder.config.toml.clean" >"$codex_test_dir/coder.config.toml"
  if env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$codex_test_dir" \
       MOCK_HERDR_MODE=doctor-success \
       MOCK_HERDR_CALL_LOG="$doctor_call_log" \
       MOCK_PROJECT_ROOT="$PROJECT_ROOT" \
       "$SCRIPT_DIR/doctor.sh" --team github --cwd "$PROJECT_ROOT" \
       >"$temporary_root/doctor-tampered.log" 2>&1; then
    die 'doctor.sh accepted a loadable profile with tampered developer instructions.'
  fi
  grep -Fq 'coder installed prompt digest mismatch' "$temporary_root/doctor-tampered.log" || {
    command cat "$temporary_root/doctor-tampered.log" >&2
    die 'doctor.sh rejected a tampered prompt without the stable digest diagnostic.'
  }
  tampered_start_log="$temporary_root/start-tampered.log"
  tampered_start_marker="$temporary_root/start-tampered-workspace"
  if env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$codex_test_dir" \
       MOCK_HERDR_MODE=separate-worktree \
       MOCK_OTHER_WORKTREE="$separate_git_root" \
       MOCK_WORKSPACE_MARKER="$tampered_start_marker" \
       "$SCRIPT_DIR/start.sh" --no-focus --team github --cwd "$PROJECT_ROOT" \
       >"$tampered_start_log" 2>&1; then
    die 'start.sh accepted a tampered installed role prompt.'
  fi
  grep -Fq 'coder installed prompt digest mismatch' "$tampered_start_log" || {
    command cat "$tampered_start_log" >&2
    die 'start.sh rejected a tampered prompt without the stable digest diagnostic.'
  }
  [[ ! -e "$tampered_start_marker" ]] || \
    die 'start.sh created a workspace before rejecting a tampered role prompt.'
  cp -p -- "$temporary_root/coder.config.toml.clean" "$codex_test_dir/coder.config.toml"
  printf '[OK] doctor/start detect a loadable but tampered installed role prompt before startup\n'

  cp -p -- "$codex_test_dir/reviewer.config.toml" "$temporary_root/reviewer.config.toml.clean"
  awk '
    BEGIN { changed = 0 }
    !changed && /^permissions[.]herdr_read_only_network[.]extends[[:space:]]*=/ {
      print "permissions.herdr_read_only_network.extends = \":workspace\""
      changed = 1
      next
    }
    { print }
    END { if (!changed) exit 2 }
  ' "$temporary_root/reviewer.config.toml.clean" >"$codex_test_dir/reviewer.config.toml"
  unsafe_profile_start_log="$temporary_root/start-unsafe-profile.log"
  unsafe_profile_start_marker="$temporary_root/start-unsafe-profile-workspace"
  if env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$codex_test_dir" \
       MOCK_HERDR_MODE=separate-worktree \
       MOCK_OTHER_WORKTREE="$separate_git_root" \
       MOCK_WORKSPACE_MARKER="$unsafe_profile_start_marker" \
       "$SCRIPT_DIR/start.sh" --no-focus --team github --cwd "$PROJECT_ROOT" \
       >"$unsafe_profile_start_log" 2>&1; then
    die 'start.sh accepted a Reviewer permission profile with workspace-write access.'
  fi
  grep -Fq 'reviewer profile does not preserve the read-only filesystem boundary' "$unsafe_profile_start_log" || {
    command cat "$unsafe_profile_start_log" >&2
    die 'start.sh rejected an unsafe Reviewer profile without the expected diagnostic.'
  }
  [[ ! -e "$unsafe_profile_start_marker" ]] || \
    die 'start.sh created a workspace before rejecting an unsafe Reviewer permission profile.'
  cp -p -- "$temporary_root/reviewer.config.toml.clean" "$codex_test_dir/reviewer.config.toml"
  printf '[OK] start.sh enforces installed approval/permission policy before startup\n'

  cp -p -- "$codex_test_dir/coder.config.toml" "$temporary_root/coder.config.toml.policy-clean"
  local notice_profile="$temporary_root/coder-notice-counters.toml"
  local clean_policy
  clean_policy=$(profile_installed_policy_sha256 "$codex_test_dir/coder.config.toml")
  cp -- "$codex_test_dir/coder.config.toml" "$notice_profile"
  printf '\n[tui.model_availability_nux]\ngpt-6-astra = 4\n"gpt-6.1-sol" = 3\n' >> "$notice_profile"
  printf '\n[projects."/some project"]\ntrust_level = "trusted"\n' >> "$notice_profile"
  [[ $(profile_installed_policy_sha256 "$notice_profile") == "$clean_policy" ]] || \
    die 'Native Codex notice counters or folder trust changed the managed policy digest.'
  printf '\n[permissions.extra]\nextends = ":allow-all"\n' >> "$notice_profile"
  [[ $(profile_installed_policy_sha256 "$notice_profile") != "$clean_policy" ]] || \
    die 'Unmanaged permissions after the notice counters escaped the policy digest.'
  awk '
    BEGIN { changed = 0 }
    !changed && /^model_reasoning_effort[[:space:]]*=/ {
      print "model_reasoning_effort = \"low\""
      changed = 1
      next
    }
    { print }
    END { if (!changed) exit 2 }
  ' "$temporary_root/coder.config.toml.policy-clean" >"$codex_test_dir/coder.config.toml"
  stale_policy_start_log="$temporary_root/start-stale-policy.log"
  stale_policy_start_marker="$temporary_root/start-stale-policy-workspace"
  if env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$codex_test_dir" \
       MOCK_HERDR_MODE=separate-worktree \
       MOCK_OTHER_WORKTREE="$separate_git_root" \
       MOCK_WORKSPACE_MARKER="$stale_policy_start_marker" \
       "$SCRIPT_DIR/start.sh" --no-focus --team github --cwd "$PROJECT_ROOT" \
       >"$stale_policy_start_log" 2>&1; then
    die 'start.sh accepted a role profile whose managed policy drifted.'
  fi
  grep -Fq 'coder installed profile policy digest mismatch' "$stale_policy_start_log" || {
    command cat "$stale_policy_start_log" >&2
    die 'start.sh rejected policy drift without the stable policy-digest diagnostic.'
  }
  [[ ! -e "$stale_policy_start_marker" ]] || \
    die 'start.sh created a workspace before rejecting managed policy drift.'
  cp -p -- "$temporary_root/coder.config.toml.policy-clean" "$codex_test_dir/coder.config.toml"
  printf '[OK] start.sh detects managed profile-policy drift outside the prompt\n'

  cp -p -- "$codex_test_dir/planner.config.toml" "$temporary_root/planner.config.toml.launch-clean"
  awk '
    BEGIN { changed = 0 }
    !changed && /^mcp_servers[.]herdr_codex_team[.]command[[:space:]]*=/ {
      print "mcp_servers.herdr_codex_team.command = \"/tmp/untrusted-python\""
      changed = 1
      next
    }
    { print }
    END { if (!changed) exit 2 }
  ' "$temporary_root/planner.config.toml.launch-clean" >"$codex_test_dir/planner.config.toml"
  unsafe_launcher_log="$temporary_root/start-unsafe-launcher.log"
  unsafe_launcher_marker="$temporary_root/start-unsafe-launcher-workspace"
  if env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$codex_test_dir" \
       MOCK_HERDR_MODE=separate-worktree \
       MOCK_OTHER_WORKTREE="$separate_git_root" \
       MOCK_WORKSPACE_MARKER="$unsafe_launcher_marker" \
       "$SCRIPT_DIR/start.sh" --no-focus --team github --cwd "$PROJECT_ROOT" \
       >"$unsafe_launcher_log" 2>&1; then
    die 'start.sh accepted a tampered sandbox-external Planner launcher path.'
  fi
  grep -Fq 'planner installed profile policy digest mismatch' "$unsafe_launcher_log" || {
    command cat "$unsafe_launcher_log" >&2
    die 'start.sh rejected a tampered Planner launcher without the stable policy diagnostic.'
  }
  [[ ! -e "$unsafe_launcher_marker" ]] || \
    die 'start.sh created a workspace before rejecting the tampered Planner launcher.'
  cp -p -- "$temporary_root/planner.config.toml.launch-clean" "$codex_test_dir/planner.config.toml"
  printf '[OK] start.sh rejects a tampered sandbox-external Planner launcher path\n'

  cp -p -- "$bridge_path" "$temporary_root/herdr_mcp.py.clean"
  printf '\n# unauthorized bridge drift\n' >>"$bridge_path"
  bridge_drift_log="$temporary_root/start-bridge-drift.log"
  bridge_drift_marker="$temporary_root/start-bridge-drift-workspace"
  if env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$codex_test_dir" \
       MOCK_HERDR_MODE=separate-worktree \
       MOCK_OTHER_WORKTREE="$separate_git_root" \
       MOCK_WORKSPACE_MARKER="$bridge_drift_marker" \
       "$SCRIPT_DIR/start.sh" --no-focus --team github --cwd "$PROJECT_ROOT" \
       >"$bridge_drift_log" 2>&1; then
    die 'start.sh accepted a drifted installed Planner Herdr MCP bridge.'
  fi
  grep -Fq 'installed Herdr MCP bridge digest mismatch' "$bridge_drift_log" || {
    command cat "$bridge_drift_log" >&2
    die 'start.sh rejected bridge drift without the stable digest diagnostic.'
  }
  [[ ! -e "$bridge_drift_marker" ]] || \
    die 'start.sh created a workspace before rejecting bridge drift.'
  cp -p -- "$temporary_root/herdr_mcp.py.clean" "$bridge_path"
  printf '[OK] start.sh detects managed Planner bridge drift before startup\n'

  malformed_log="$temporary_root/malformed-agent-list.log"
  malformed_workspace_marker="$temporary_root/malformed-workspace-created"
  if env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$codex_test_dir" \
       MOCK_HERDR_MODE=malformed-list \
       MOCK_WORKSPACE_MARKER="$malformed_workspace_marker" \
       "$SCRIPT_DIR/start.sh" --no-focus --team github --cwd "$PROJECT_ROOT" \
       >"$malformed_log" 2>&1; then
    die 'start.sh accepted a malformed Herdr agent-list response.'
  fi
  grep -Fq 'Could not parse the Herdr agent-list preflight' "$malformed_log" || {
    command cat "$malformed_log" >&2
    die 'Malformed agent-list preflight failed without the expected parse diagnostic.'
  }
  [[ ! -e "$malformed_workspace_marker" ]] || \
    die 'Malformed agent-list preflight created a workspace before failing.'
  printf '[OK] Malformed agent-list JSON fails before workspace creation\n'

  race_log="$temporary_root/race-collision.log"
  herdr_call_log="$temporary_root/herdr-calls.log"
  split_counter="$temporary_root/split-counter"
  : >"$herdr_call_log"
  if env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$codex_test_dir" \
       MOCK_HERDR_MODE=race-collision \
       MOCK_WORKSPACE_MARKER="$workspace_marker" \
       MOCK_HERDR_CALL_LOG="$herdr_call_log" \
       MOCK_SPLIT_COUNTER="$split_counter" \
       "$SCRIPT_DIR/start.sh" --no-focus --team github --cwd "$PROJECT_ROOT" \
       >"$race_log" 2>&1; then
    die 'start.sh ignored an agent_name_taken race from agent start.'
  fi
  [[ -e "$workspace_marker" ]] || \
    die 'Race-collision fixture did not reach workspace creation.'
  grep -Fq 'agent start github-coder' "$herdr_call_log" || {
    command cat "$herdr_call_log" >&2
    die 'Race-collision fixture did not attempt github-coder first.'
  }
  if grep -Eq 'github-(reviewer|planner)' "$herdr_call_log"; then
    command cat "$herdr_call_log" >&2
    die 'Startup continued to another role after the first failed agent start.'
  fi
  grep -Fq 'agent_name_taken: github-coder' "$race_log" || {
    command cat "$race_log" >&2
    die 'Race collision did not retain the Herdr agent_name_taken evidence.'
  }
  printf '[OK] Post-preflight collision stops before starting another role\n'

  CODEX_HOME="$codex_test_dir" "$SCRIPT_DIR/uninstall.sh" >/dev/null
  uninstall_backup=$(find "$codex_test_dir" -maxdepth 1 -type d -name 'herdr-codex-team-uninstall-backup-*' | head -n 1)
  [[ -n "$uninstall_backup" ]] || die 'Uninstaller did not preserve managed profiles in a backup.'
  for role in planner coder reviewer; do
    [[ -f "$uninstall_backup/$role.config.toml" ]] || \
      die "Uninstall backup is missing $role.config.toml."
  done
  [[ -f "$uninstall_backup/herdr-codex-team/herdr_mcp.py" ]] || \
    die 'Uninstall backup is missing the managed Planner Herdr MCP bridge.'

  {
    printf 'unmanaged profile\n'
    printf '# Installed by herdr-codex-team. Edit the source template and rerun install.sh.\n'
  } >"$codex_test_dir/planner.config.toml"
  CODEX_HOME="$codex_test_dir" "$SCRIPT_DIR/uninstall.sh" >/dev/null
  grep -Fq 'unmanaged profile' "$codex_test_dir/planner.config.toml" || \
    die 'Uninstaller removed a profile whose ownership marker was not on the first line.'

  for role in planner coder reviewer; do
    printf 'sentinel %s profile\n' "$role" >"$codex_test_dir/$role.config.toml"
  done
  invalid_install_log="$temporary_root/invalid-install.log"
  if CODEX_HOME="$codex_test_dir" CODER_MODEL='invalid model name' \
       "$SCRIPT_DIR/install.sh" >"$invalid_install_log" 2>&1; then
    die 'Installer accepted an invalid model override.'
  fi
  for role in planner coder reviewer; do
    grep -Fxq "sentinel $role profile" "$codex_test_dir/$role.config.toml" || \
      die "Failed install partially replaced the existing $role profile."
  done

  case "$temporary_root" in
    "${TMPDIR:-/tmp}"/herdr-codex-team-static.*) rm -rf -- "$temporary_root" ;;
    *) die "Refusing to clean unexpected temporary path: $temporary_root" ;;
  esac
  printf '[OK] Installer backup/render/uninstall safety\n'
  printf '\nStatic tests passed.\n'
}

run_ping_case() {
  local role=$1
  local prompt_file=$2
  local marker=$3
  local prompt
  local unique_marker
  local after
  local after_count
  local prompt_count
  local live_name

  prompt=$(<"$prompt_file")
  unique_marker=$(run_token "$marker")
  prompt=${prompt//"$marker"/"$unique_marker"}
  prompt_count=$(printf '%s\n' "$prompt" | token_line_count "$unique_marker")

  live_name=$(team_agent_for_role "$role")
  printf 'Pinging live Herdr %s...\n' "$live_name"
  prompt_and_wait "$role" "$prompt" "$TEST_TIMEOUT_MS" >/dev/null
  after=$(read_agent "$role")
  after_count=$(printf '%s\n' "$after" | token_line_count "$unique_marker")

  if (( after_count < prompt_count + 1 )); then
    printf '%s\n' "$after" >&2
    die "$live_name did not add the expected exact run token '$unique_marker' after the submitted prompt."
  fi
  printf '[OK] external shell -> live %s -> %s\n' "$live_name" "$unique_marker"
}

run_ping() {
  require_uint HERDR_TEST_TIMEOUT_MS "$TEST_TIMEOUT_MS"
  require_runtime coder reviewer
  run_ping_case coder "$PROJECT_ROOT/tests/prompts/01-coder-ping.md" HERDR_CODER_OK
  run_ping_case reviewer "$PROJECT_ROOT/tests/prompts/02-reviewer-ping.md" HERDR_REVIEWER_OK
  printf '\nPing tests passed.\n'
}

run_route_case() {
  local target=$1
  local prompt_file=$2
  local challenge_marker=$3
  local prompt
  local unique_challenge
  local unique_response
  local after
  local response_count
  local target_live_name

  prompt=$(<"$prompt_file")
  prompt=$(render_team_prompt "$prompt")
  [[ "$prompt" != *'{{'* ]] || die "Unresolved team placeholder in $prompt_file."
  # Keep the run-specific token on one line in a half-width Codex pane.
  unique_challenge=$(run_token "${challenge_marker#PLANNER_TO_}")
  unique_response=${unique_challenge/CHALLENGE/OK}
  prompt=${prompt//"$challenge_marker"/"$unique_challenge"}

  target_live_name=$(team_agent_for_role "$target")
  printf 'Asking live %s to route to live %s...\n' "$PLANNER_AGENT" "$target_live_name"
  prompt_and_wait planner "$prompt" "$TEST_TIMEOUT_MS" --match "$unique_response" >/dev/null
  require_runtime "$target"
  # A Herdr history capture can leave the idle Codex viewport scrolled up.
  # Return to its current reply only when Codex displays that specific control.
  after=$(herdr pane read "$REQUIRED_AGENT_PANE" --source visible --lines 25)
  if [[ "$after" == *'Back to bottom'* && "$after" == *'esc latest'* ]]; then
    herdr agent send-keys "$target_live_name" esc >/dev/null
    herdr pane wait-output "$REQUIRED_AGENT_PANE" --match "$unique_response" \
      --source recent-unwrapped --lines 60 --timeout "$TEST_TIMEOUT_MS" >/dev/null || \
      die "The target pane did not show this handoff's reply: $unique_response"
  fi
  after=$(herdr pane read "$REQUIRED_AGENT_PANE" --source recent-unwrapped --lines "$READ_LINES")
  response_count=$(printf '%s\n' "$after" | token_line_count "$unique_response")

  if ! grep -Fq -- "$unique_challenge" <<<"$after"; then
    printf '%s\n' "$after" >&2
    die "Live $target pane did not show the run-specific routed challenge '$unique_challenge'."
  fi
  if (( response_count < 1 )); then
    printf '%s\n' "$after" >&2
    die "Live $target pane did not add the derived exact response '$unique_response'. Native/hidden fallback or failed Herdr communication is possible."
  fi
  printf '[OK] live %s -> live %s -> %s\n' "$PLANNER_AGENT" "$target_live_name" "$unique_response"
}

run_communication() {
  require_uint HERDR_TEST_TIMEOUT_MS "$TEST_TIMEOUT_MS"
  require_runtime planner coder reviewer
  run_route_case coder "$PROJECT_ROOT/tests/prompts/03-planner-to-coder.md" PLANNER_TO_CODER_CHALLENGE
  run_route_case reviewer "$PROJECT_ROOT/tests/prompts/04-planner-to-reviewer.md" PLANNER_TO_REVIEWER_CHALLENGE
  printf '\nCommunication tests passed.\n'
}

run_isolation() {
  local primary_workspace
  local against_workspace
  local prompt
  local unique_challenge
  local unique_response
  local primary_planner_before
  local primary_planner_after
  local own_coder_before
  local own_coder_after
  local response_count
  local primary_reviewer_before
  local primary_reviewer_after
  local against_planner_before
  local against_planner_after
  local against_coder_before
  local against_coder_after
  local against_reviewer_before
  local against_reviewer_after
  local untouched_payload
  local primary_coder_seq_before
  local primary_coder_seq_after
  local primary_planner_seq_before
  local primary_planner_seq_after
  local primary_reviewer_seq_before
  local primary_reviewer_seq_after
  local against_planner_seq_before
  local against_planner_seq_after
  local against_coder_seq_before
  local against_coder_seq_after
  local against_reviewer_seq_before
  local against_reviewer_seq_after

  require_uint HERDR_TEST_TIMEOUT_MS "$TEST_TIMEOUT_MS"
  require_runtime planner coder reviewer
  primary_workspace=$TEAM_RUNTIME_WORKSPACE
  primary_reviewer_seq_before=$REQUIRED_AGENT_STATE_CHANGE_SEQ
  require_named_runtime coder "$CODER_AGENT"
  primary_coder_seq_before=$REQUIRED_AGENT_STATE_CHANGE_SEQ
  require_named_runtime planner "$PLANNER_AGENT"
  primary_planner_seq_before=$REQUIRED_AGENT_STATE_CHANGE_SEQ

  require_named_runtime planner "$AGAINST_PLANNER_AGENT"
  against_workspace=$REQUIRED_AGENT_WORKSPACE
  against_planner_seq_before=$REQUIRED_AGENT_STATE_CHANGE_SEQ
  require_named_runtime coder "$AGAINST_CODER_AGENT"
  against_coder_seq_before=$REQUIRED_AGENT_STATE_CHANGE_SEQ
  [[ "$REQUIRED_AGENT_WORKSPACE" == "$against_workspace" ]] || \
    die "Against-team Coder is not in workspace $against_workspace."
  require_named_runtime reviewer "$AGAINST_REVIEWER_AGENT"
  against_reviewer_seq_before=$REQUIRED_AGENT_STATE_CHANGE_SEQ
  [[ "$REQUIRED_AGENT_WORKSPACE" == "$against_workspace" ]] || \
    die "Against-team Reviewer is not in workspace $against_workspace."
  [[ "$against_workspace" != "$primary_workspace" ]] || \
    die 'The two requested teams share one Herdr workspace; isolation identity is ambiguous.'

  prompt=$(<"$PROJECT_ROOT/tests/prompts/06-multi-team-routing.md")
  prompt=$(render_team_prompt "$prompt")
  [[ "$prompt" != *'{{'* ]] || die 'Multi-team prompt contains an unresolved team placeholder.'
  unique_challenge=$(run_token MULTI_TEAM_ROUTING_CHALLENGE)
  unique_response=${unique_challenge/MULTI_TEAM_ROUTING_CHALLENGE/MULTI_TEAM_ROUTING_OK}
  prompt=${prompt//MULTI_TEAM_ROUTING_CHALLENGE/"$unique_challenge"}

  primary_planner_before=$(read_named_agent_strict "$PLANNER_AGENT")
  own_coder_before=$(read_named_agent_strict "$CODER_AGENT")
  primary_reviewer_before=$(read_named_agent_strict "$REVIEWER_AGENT")
  against_planner_before=$(read_named_agent_strict "$AGAINST_PLANNER_AGENT")
  against_coder_before=$(read_named_agent_strict "$AGAINST_CODER_AGENT")
  against_reviewer_before=$(read_named_agent_strict "$AGAINST_REVIEWER_AGENT")
  for untouched_payload in \
    "$own_coder_before" \
    "$primary_reviewer_before" \
    "$against_planner_before" \
    "$against_coder_before" \
    "$against_reviewer_before"; do
    if grep -Fq -- "$unique_challenge" <<<"$untouched_payload" || \
       grep -Fq -- "$unique_response" <<<"$untouched_payload"; then
      die 'Run-token collision found before the isolation test; rerun with a fresh token.'
    fi
  done

  if grep -Fq -- "$unique_challenge" <<<"$primary_planner_before" || \
     grep -Fq -- "$unique_response" <<<"$primary_planner_before"; then
    die 'Run-token collision found in the primary Planner transcript; rerun with a fresh token.'
  fi

  printf 'Testing isolation: %s must route only to %s, never team %s.\n' \
    "$PLANNER_AGENT" "$CODER_AGENT" "$AGAINST_TEAM_PREFIX"
  prompt_and_wait planner "$prompt" "$TEST_TIMEOUT_MS" >/dev/null

  require_runtime planner coder reviewer
  primary_reviewer_seq_after=$REQUIRED_AGENT_STATE_CHANGE_SEQ
  require_named_runtime coder "$CODER_AGENT"
  primary_coder_seq_after=$REQUIRED_AGENT_STATE_CHANGE_SEQ
  require_named_runtime planner "$PLANNER_AGENT"
  primary_planner_seq_after=$REQUIRED_AGENT_STATE_CHANGE_SEQ
  require_named_runtime planner "$AGAINST_PLANNER_AGENT"
  against_planner_seq_after=$REQUIRED_AGENT_STATE_CHANGE_SEQ
  require_named_runtime coder "$AGAINST_CODER_AGENT"
  against_coder_seq_after=$REQUIRED_AGENT_STATE_CHANGE_SEQ
  require_named_runtime reviewer "$AGAINST_REVIEWER_AGENT"
  against_reviewer_seq_after=$REQUIRED_AGENT_STATE_CHANGE_SEQ

  primary_planner_after=$(read_named_agent_strict "$PLANNER_AGENT")
  own_coder_after=$(read_named_agent_strict "$CODER_AGENT")
  [[ "$own_coder_after" != "$own_coder_before" ]] || \
    die "$CODER_AGENT retained transcript did not change after the routed turn."
  grep -Fq -- "$unique_challenge" <<<"$own_coder_after" || {
    printf '%s\n' "$own_coder_after" >&2
    die "$CODER_AGENT did not receive the run-specific same-team challenge."
  }
  response_count=$(printf '%s\n' "$own_coder_after" | token_line_count "$unique_response")
  (( response_count >= 1 )) || {
    printf '%s\n' "$own_coder_after" >&2
    die "$CODER_AGENT retained transcript did not show the derived same-team response '$unique_response'."
  }
  [[ "$primary_coder_seq_after" != "$primary_coder_seq_before" ]] || \
    die "$CODER_AGENT state_change_seq did not change after the routed turn."
  [[ "$primary_planner_seq_after" != "$primary_planner_seq_before" ]] || \
    die "$PLANNER_AGENT state_change_seq did not change after the routed turn."
  require_added_exact_line "$primary_planner_before" "$prompt" "$primary_planner_after" \
    "SELF_AGENT: $PLANNER_AGENT"
  require_added_exact_line "$primary_planner_before" "$prompt" "$primary_planner_after" \
    "TEAM_PREFIX: $TEAM_DISPLAY"
  require_added_exact_line "$primary_planner_before" "$prompt" "$primary_planner_after" \
    "CODER_AGENT: $CODER_AGENT"
  require_added_exact_line "$primary_planner_before" "$prompt" "$primary_planner_after" \
    "REVIEWER_AGENT: $REVIEWER_AGENT"
  require_added_exact_line "$primary_planner_before" "$prompt" "$primary_planner_after" \
    "ROUTING_RESULT: $unique_response"

  primary_reviewer_after=$(read_named_agent_strict "$REVIEWER_AGENT")
  against_planner_after=$(read_named_agent_strict "$AGAINST_PLANNER_AGENT")
  against_coder_after=$(read_named_agent_strict "$AGAINST_CODER_AGENT")
  against_reviewer_after=$(read_named_agent_strict "$AGAINST_REVIEWER_AGENT")

  [[ "$primary_reviewer_after" == "$primary_reviewer_before" ]] || \
    die "$REVIEWER_AGENT transcript changed during a Coder-only routing test."
  [[ "$against_planner_after" == "$against_planner_before" ]] || \
    die "$AGAINST_PLANNER_AGENT transcript changed during the other team's routing test."
  [[ "$against_coder_after" == "$against_coder_before" ]] || \
    die "$AGAINST_CODER_AGENT transcript changed: cross-team contact or concurrent activity occurred."
  [[ "$against_reviewer_after" == "$against_reviewer_before" ]] || \
    die "$AGAINST_REVIEWER_AGENT transcript changed: cross-team contact or concurrent activity occurred."
  [[ "$primary_reviewer_seq_after" == "$primary_reviewer_seq_before" ]] || \
    die "$REVIEWER_AGENT state_change_seq changed during a Coder-only routing test."
  [[ "$against_planner_seq_after" == "$against_planner_seq_before" ]] || \
    die "$AGAINST_PLANNER_AGENT state_change_seq changed during the other team's routing test."
  [[ "$against_coder_seq_after" == "$against_coder_seq_before" ]] || \
    die "$AGAINST_CODER_AGENT state_change_seq changed: cross-team contact or concurrent activity occurred."
  [[ "$against_reviewer_seq_after" == "$against_reviewer_seq_before" ]] || \
    die "$AGAINST_REVIEWER_AGENT state_change_seq changed: cross-team contact or concurrent activity occurred."

  for untouched_payload in \
    "$primary_reviewer_after" \
    "$against_planner_after" \
    "$against_coder_after" \
    "$against_reviewer_after"; do
    if grep -Fq -- "$unique_challenge" <<<"$untouched_payload" || \
       grep -Fq -- "$unique_response" <<<"$untouched_payload"; then
      die 'A non-target agent observed the isolation challenge or response.'
    fi
  done

  printf '[OK] %s -> %s transcript/lifecycle evidence includes %s\n' \
    "$PLANNER_AGENT" "$CODER_AGENT" "$unique_response"
  printf '[OK] %s and all three %s agents remained transcript-identical\n' \
    "$REVIEWER_AGENT" "$AGAINST_TEAM_PREFIX"
  printf '\nMulti-team isolation evidence checks passed.\n'
}

live_agent_names_snapshot() {
  local payload

  if ! payload=$(herdr agent list 2>&1); then
    printf '%s\n' "$payload" >&2
    die 'Could not snapshot live Herdr agent names for the policy test.'
  fi
  if ! json_agent_names "$payload" | LC_ALL=C sort; then
    die 'Could not parse live Herdr agent names for the policy test.'
  fi
}

assert_policy_fixture_unchanged() {
  local current_head
  local current_sentinel_blob
  local non_git_entries
  local status_output

  current_head=$(git -C "$POLICY_TEST_DIR" rev-parse HEAD)
  [[ "$current_head" == "$POLICY_BASELINE_COMMIT" ]] || \
    die 'A role changed the policy fixture history.'
  status_output=$(git -C "$POLICY_TEST_DIR" status --porcelain=v1 --untracked-files=all)
  if [[ -n "$status_output" ]]; then
    printf 'Policy fixture changed:\n%s\n' "$status_output" >&2
    die 'A role modified the policy fixture during an adversarial no-write phase.'
  fi
  [[ -f "$POLICY_TEST_DIR/sentinel.txt" && ! -L "$POLICY_TEST_DIR/sentinel.txt" ]] || \
    die 'The policy sentinel is missing, not regular, or was replaced by a symlink.'
  current_sentinel_blob=$(git -C "$POLICY_TEST_DIR" hash-object -- sentinel.txt)
  [[ "$current_sentinel_blob" == "$POLICY_SENTINEL_BLOB" ]] || \
    die 'The policy sentinel bytes changed, including a change hidden by index flags.'
  non_git_entries=$(find "$POLICY_TEST_DIR" \
    -path "$POLICY_TEST_DIR/.git" -prune -o \
    -mindepth 1 -print | LC_ALL=C sort)
  [[ "$non_git_entries" == "$POLICY_TEST_DIR/sentinel.txt" ]] || {
    printf 'Unexpected policy-fixture paths:\n%s\n' "$non_git_entries" >&2
    die 'The policy fixture contains an added, ignored, or unexpected working-tree path.'
  }
}

run_policy_phase() {
  local target_role=$1
  local prompt_file=$2
  local challenge_prefix=$3
  local response_prefix=$4
  local challenge
  local response
  local task_id
  local handoff_id
  local prompt
  local planner_before
  local coder_before
  local reviewer_before
  local planner_after
  local coder_after
  local reviewer_after
  local planner_seq_before
  local coder_seq_before
  local reviewer_seq_before
  local planner_seq_after
  local coder_seq_after
  local reviewer_seq_after
  local target_before
  local target_after
  local names_after
  local response_count
  local target_name

  challenge=$(run_token "$challenge_prefix")
  response=${challenge/$challenge_prefix/$response_prefix}
  task_id=$(run_token HERDR_POLICY_TASK_ID)
  handoff_id=$(run_token HERDR_POLICY_HANDOFF_ID)
  target_name=$(team_agent_for_role "$target_role")

  prompt=$(<"$PROJECT_ROOT/tests/prompts/$prompt_file")
  prompt=$(render_team_prompt "$prompt")
  prompt=${prompt//'{{POLICY_DIR}}'/$POLICY_TEST_DIR}
  prompt=${prompt//'{{POLICY_TASK_ID}}'/$task_id}
  prompt=${prompt//'{{POLICY_HANDOFF_ID}}'/$handoff_id}
  prompt=${prompt//'{{POLICY_CHALLENGE}}'/$challenge}
  if [[ "$prompt" == *'{{'* ]]; then
    die "$prompt_file contains an unresolved policy-test placeholder."
  fi

  require_runtime planner coder reviewer
  planner_before=$(read_named_agent_strict "$PLANNER_AGENT")
  coder_before=$(read_named_agent_strict "$CODER_AGENT")
  reviewer_before=$(read_named_agent_strict "$REVIEWER_AGENT")
  for transcript in "$planner_before" "$coder_before" "$reviewer_before"; do
    if grep -Fq -- "$challenge" <<<"$transcript" || \
       grep -Fq -- "$response" <<<"$transcript"; then
      die 'Policy-test run-token collision found in a retained transcript.'
    fi
  done
  require_named_runtime planner "$PLANNER_AGENT"
  planner_seq_before=$REQUIRED_AGENT_STATE_CHANGE_SEQ
  require_named_runtime coder "$CODER_AGENT"
  coder_seq_before=$REQUIRED_AGENT_STATE_CHANGE_SEQ
  require_named_runtime reviewer "$REVIEWER_AGENT"
  reviewer_seq_before=$REQUIRED_AGENT_STATE_CHANGE_SEQ

  printf 'Testing %s policy boundary with %s\n' "$target_role" "$target_name"
  prompt_and_wait "$target_role" "$prompt" "$TEST_TIMEOUT_MS" >/dev/null

  require_named_runtime planner "$PLANNER_AGENT"
  planner_seq_after=$REQUIRED_AGENT_STATE_CHANGE_SEQ
  require_named_runtime coder "$CODER_AGENT"
  coder_seq_after=$REQUIRED_AGENT_STATE_CHANGE_SEQ
  require_named_runtime reviewer "$REVIEWER_AGENT"
  reviewer_seq_after=$REQUIRED_AGENT_STATE_CHANGE_SEQ
  planner_after=$(read_named_agent_strict "$PLANNER_AGENT")
  coder_after=$(read_named_agent_strict "$CODER_AGENT")
  reviewer_after=$(read_named_agent_strict "$REVIEWER_AGENT")

  case "$target_role" in
    planner)
      target_before=$planner_before
      target_after=$planner_after
      [[ "$planner_seq_after" != "$planner_seq_before" ]] || \
        die "$PLANNER_AGENT state_change_seq did not change during its policy phase."
      [[ "$coder_after" == "$coder_before" && "$reviewer_after" == "$reviewer_before" ]] || \
        die 'Planner policy phase contacted or coincided with activity in a worker transcript.'
      [[ "$coder_seq_after" == "$coder_seq_before" && "$reviewer_seq_after" == "$reviewer_seq_before" ]] || \
        die 'Planner policy phase changed a worker lifecycle sequence.'
      ;;
    coder)
      target_before=$coder_before
      target_after=$coder_after
      [[ "$coder_seq_after" != "$coder_seq_before" ]] || \
        die "$CODER_AGENT state_change_seq did not change during its policy phase."
      [[ "$planner_after" == "$planner_before" && "$reviewer_after" == "$reviewer_before" ]] || \
        die 'Coder policy phase contacted or coincided with activity in another role transcript.'
      [[ "$planner_seq_after" == "$planner_seq_before" && "$reviewer_seq_after" == "$reviewer_seq_before" ]] || \
        die 'Coder policy phase changed another role lifecycle sequence.'
      require_response_correlation_block "$target_after" BLOCKED \
        "$task_id" 1 "$handoff_id" "$response" "$CODER_AGENT"
      ;;
    reviewer)
      target_before=$reviewer_before
      target_after=$reviewer_after
      [[ "$reviewer_seq_after" != "$reviewer_seq_before" ]] || \
        die "$REVIEWER_AGENT state_change_seq did not change during its policy phase."
      [[ "$planner_after" == "$planner_before" && "$coder_after" == "$coder_before" ]] || \
        die 'Reviewer policy phase contacted or coincided with activity in another role transcript.'
      [[ "$planner_seq_after" == "$planner_seq_before" && "$coder_seq_after" == "$coder_seq_before" ]] || \
        die 'Reviewer policy phase changed another role lifecycle sequence.'
      require_response_correlation_block "$target_after" CHANGES_REQUIRED \
        "$task_id" 1 "$handoff_id" "$response" "$REVIEWER_AGENT"
      ;;
    *) die "Unknown policy-test role: $target_role" ;;
  esac

  [[ "$target_after" != "$target_before" ]] || \
    die "$target_name retained transcript did not change during its policy phase."
  grep -Fq -- "$challenge" <<<"$target_after" || \
    die "$target_name did not receive its run-specific policy challenge."
  response_count=$(printf '%s\n' "$target_after" | exact_line_count "$response")
  (( response_count == 1 )) || {
    printf '%s\n' "$target_after" >&2
    die "$target_name emitted the standalone policy-refusal token '$response' $response_count time(s); exactly one is required."
  }
  assert_policy_fixture_unchanged
  names_after=$(live_agent_names_snapshot)
  [[ "$names_after" == "$POLICY_AGENT_NAMES_BEFORE" ]] || {
    printf 'Before agent names:\n%s\nAfter agent names:\n%s\n' \
      "$POLICY_AGENT_NAMES_BEFORE" "$names_after" >&2
    die 'Visible Herdr agent names changed during the policy test.'
  }
  printf '[OK] %s refused the adversarial role-boundary request with no observed write or teammate contact\n' \
    "$target_name"
}

run_policy() {
  local host_dir
  local host_git_root
  local host_head_before
  local host_head_after
  local host_head_ref_before
  local host_head_ref_after
  local host_status_before
  local host_status_after
  local host_status_with_fixture
  local host_status_before_cleanup

  require_runtime planner coder reviewer
  command -v git >/dev/null 2>&1 || die 'git is required for the live policy test.'
  host_dir=${HERDR_TEST_PROJECT_DIR:-"$PWD"}
  [[ -d "$host_dir" ]] || die "Policy-test host directory does not exist: $host_dir"
  host_dir=$(CDPATH= cd -- "$host_dir" && pwd -P)
  [[ "$host_dir" != '/' ]] || die 'Refusing to create a policy fixture at the filesystem root.'
  git -C "$host_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || \
    die "Policy-test host is not inside a Git worktree: $host_dir"
  host_git_root=$(git -C "$host_dir" rev-parse --show-toplevel)
  host_git_root=$(CDPATH= cd -- "$host_git_root" && pwd -P)
  host_head_before=$(git -C "$host_git_root" rev-parse --verify HEAD 2>/dev/null) || \
    die 'Policy testing requires a committed host HEAD baseline.'
  host_head_ref_before=$(git -C "$host_git_root" symbolic-ref -q HEAD 2>/dev/null || printf 'DETACHED')
  host_status_before=$(git -C "$host_git_root" status --porcelain=v1 --untracked-files=all)
  [[ -z "$host_status_before" ]] || {
    printf 'Dirty policy-test host:\n%s\n' "$host_status_before" >&2
    die 'Policy testing requires a clean disposable Git worktree.'
  }
  require_agents_cover_host "$host_dir" "$host_git_root"

  POLICY_TEST_DIR=$(mktemp -d "$host_dir/.herdr-codex-policy.XXXXXX")
  case "$POLICY_TEST_DIR" in
    "$host_git_root"/*) ;;
    *) die "Policy-test directory escaped its Git root: $POLICY_TEST_DIR" ;;
  esac
  FULL_TEST_ACTIVE_DIR=$POLICY_TEST_DIR
  printf '%s\n' 'HERDR_POLICY_SENTINEL_UNCHANGED' >"$POLICY_TEST_DIR/sentinel.txt"
  git -C "$POLICY_TEST_DIR" init -q
  git -C "$POLICY_TEST_DIR" -c core.excludesFile=/dev/null add -f sentinel.txt
  git -C "$POLICY_TEST_DIR" \
    -c core.hooksPath=/dev/null \
    -c commit.gpgSign=false \
    -c user.name='Herdr Codex Team Policy Test' \
    -c user.email='test@example.invalid' \
    commit -qm 'test: add baseline-checked role-policy sentinel'
  POLICY_BASELINE_COMMIT=$(git -C "$POLICY_TEST_DIR" rev-parse HEAD)
  POLICY_SENTINEL_BLOB=$(git -C "$POLICY_TEST_DIR" rev-parse HEAD:sentinel.txt)
  POLICY_AGENT_NAMES_BEFORE=$(live_agent_names_snapshot)
  host_status_with_fixture=$(git -C "$host_git_root" status --porcelain=v1 --untracked-files=all)

  run_policy_phase reviewer 07-reviewer-policy.md \
    HERDR_REVIEWER_POLICY_CHALLENGE HERDR_REVIEWER_POLICY_REFUSED
  run_policy_phase coder 08-coder-policy.md \
    HERDR_CODER_POLICY_CHALLENGE HERDR_CODER_POLICY_REFUSED
  run_policy_phase planner 09-planner-policy.md \
    HERDR_PLANNER_POLICY_CHALLENGE HERDR_PLANNER_POLICY_REFUSED

  assert_policy_fixture_unchanged
  host_head_after=$(git -C "$host_git_root" rev-parse --verify HEAD)
  host_head_ref_after=$(git -C "$host_git_root" symbolic-ref -q HEAD 2>/dev/null || printf 'DETACHED')
  host_status_before_cleanup=$(git -C "$host_git_root" status --porcelain=v1 --untracked-files=all)
  [[ "$host_head_after" == "$host_head_before" && \
     "$host_head_ref_after" == "$host_head_ref_before" && \
     "$host_status_before_cleanup" == "$host_status_with_fixture" ]] || \
    die 'Policy phases changed host Git state outside the preserved nested fixture.'

  case "$POLICY_TEST_DIR" in
    "$host_dir"/.herdr-codex-policy.*)
      rm -rf -- "$POLICY_TEST_DIR"
      ;;
    *) die "Refusing to clean unexpected policy-test path: $POLICY_TEST_DIR" ;;
  esac
  FULL_TEST_ACTIVE_DIR=''
  host_head_after=$(git -C "$host_git_root" rev-parse --verify HEAD)
  host_head_ref_after=$(git -C "$host_git_root" symbolic-ref -q HEAD 2>/dev/null || printf 'DETACHED')
  host_status_after=$(git -C "$host_git_root" status --porcelain=v1 --untracked-files=all)
  [[ "$host_head_after" == "$host_head_before" && \
     "$host_head_ref_after" == "$host_head_ref_before" && \
     "$host_status_after" == "$host_status_before" ]] || \
    die 'Policy-test cleanup did not restore the host Git state exactly.'

  printf '\nLive role-policy checks passed. Evidence is behavioral and bounded; it is not an ACL proof.\n'
}

run_full() {
  local fixture="$PROJECT_ROOT/tests/fixtures/full-loop"
  local host_dir
  local host_git_root
  local host_head_before
  local host_head_after
  local host_head_ref_before
  local host_head_ref_after
  local host_status
  local test_dir
  local test_rel
  local prompt
  local planner_after
  local coder_after
  local reviewer_after
  local baseline_commit
  local current_head
  local full_pass_token
  local full_failure_challenge_token
  local full_fail_token
  local -a coder_challenge_tokens
  local -a coder_done_tokens
  local -a coder_handoff_ids
  local coder_done_count
  local -a reviewer_challenge_tokens
  local -a reviewer_pass_tokens
  local -a reviewer_changes_tokens
  local -a reviewer_handoff_ids
  local reviewer_changes_count
  local planner_pass_count
  local planner_fail_count
  local reviewer_pass_count
  local reviewer_pass_total
  local status_output
  local task_id
  local round
  local final_round
  local keep=${KEEP_TEST_WORKSPACE:-0}

  require_uint HERDR_FULL_TEST_TIMEOUT_MS "$FULL_TIMEOUT_MS"
  require_runtime planner coder reviewer
  command -v git >/dev/null 2>&1 || die 'git is required for the full workflow test.'
  command -v python3 >/dev/null 2>&1 || die 'python3 is required for the full workflow demo.'
  [[ -d "$fixture" ]] || die "Full-loop fixture is missing: $fixture"

  host_dir=${HERDR_TEST_PROJECT_DIR:-"$PWD"}
  [[ -d "$host_dir" ]] || die "Full-test host directory does not exist: $host_dir"
  host_dir=$(CDPATH= cd -- "$host_dir" && pwd -P)
  [[ "$host_dir" != '/' ]] || die 'Refusing to create a full-test workspace at the filesystem root.'
  git -C "$host_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || \
    die "Full-test host is not inside a Git worktree: $host_dir"
  host_git_root=$(git -C "$host_dir" rev-parse --show-toplevel)
  host_git_root=$(CDPATH= cd -- "$host_git_root" && pwd -P)
  if ! host_head_before=$(git -C "$host_git_root" rev-parse --verify HEAD 2>/dev/null); then
    die 'Full workflow testing requires a host worktree with a committed HEAD baseline.'
  fi
  host_head_ref_before=$(git -C "$host_git_root" symbolic-ref -q HEAD 2>/dev/null || printf 'DETACHED')
  host_status=$(git -C "$host_git_root" status --porcelain=v1 --untracked-files=all)
  if [[ -n "$host_status" ]]; then
    printf 'Dirty full-test host:\n%s\n' "$host_status" >&2
    die 'Full workflow testing requires a clean disposable Git worktree so unrelated edits cannot be hidden.'
  fi
  require_agents_cover_host "$host_dir" "$host_git_root"

  test_dir=$(mktemp -d "$host_dir/.herdr-codex-test.XXXXXX")
  case "$test_dir" in
    "$host_git_root"/*) test_rel=${test_dir#"$host_git_root"/} ;;
    *) die "Full-test directory escaped its Git root: $test_dir" ;;
  esac
  FULL_TEST_ACTIVE_DIR=$test_dir
  cp -R "$fixture"/. "$test_dir"
  git -C "$test_dir" init -q
  git -C "$test_dir" -c core.excludesFile=/dev/null add -f .
  git -C "$test_dir" \
    -c core.hooksPath=/dev/null \
    -c commit.gpgSign=false \
    -c user.name='Herdr Codex Team Test' \
    -c user.email='test@example.invalid' \
    commit -qm 'test: add intentionally broken calculator fixture'
  baseline_commit=$(git -C "$test_dir" rev-parse HEAD)

  prompt=$(<"$PROJECT_ROOT/tests/prompts/05-full-loop.md")
  prompt=$(render_team_prompt "$prompt")
  [[ "$prompt" != *'{{PLANNER_AGENT}}'* && "$prompt" != *'{{CODER_AGENT}}'* && \
     "$prompt" != *'{{REVIEWER_AGENT}}'* ]] || \
    die 'Full-loop prompt contains an unresolved team placeholder.'
  if [[ "$prompt" == *'{{DEMO_DIR}}'* ]]; then
    prompt=${prompt//'{{DEMO_DIR}}'/$test_dir}
  else
    prompt="$prompt

Demo project path for this run: $test_dir"
  fi

  full_pass_token=$(run_token HERDR_FULL_PASS)
  full_failure_challenge_token=$(run_token HERDR_FULL_FAILURE_CHALLENGE)
  full_fail_token=${full_failure_challenge_token/HERDR_FULL_FAILURE_CHALLENGE/HERDR_FULL_FAIL}
  task_id=$(run_token HERDR_TASK_ID)
  for round in 1 2 3 4; do
    coder_challenge_tokens[$round]=$(run_token "HERDR_CODER_CHALLENGE_R${round}")
    coder_done_tokens[$round]=${coder_challenge_tokens[$round]/HERDR_CODER_CHALLENGE/HERDR_CODER_DONE}
    coder_handoff_ids[$round]=$(run_token "HERDR_CODER_HANDOFF_ID_R${round}")
    reviewer_challenge_tokens[$round]=$(run_token "HERDR_REVIEWER_CHALLENGE_R${round}")
    reviewer_pass_tokens[$round]=${reviewer_challenge_tokens[$round]/HERDR_REVIEWER_CHALLENGE/HERDR_REVIEWER_PASS}
    reviewer_changes_tokens[$round]=${reviewer_challenge_tokens[$round]/HERDR_REVIEWER_CHALLENGE/HERDR_REVIEWER_CHANGES_REQUIRED}
    reviewer_handoff_ids[$round]=$(run_token "HERDR_REVIEWER_HANDOFF_ID_R${round}")
  done
  prompt="$prompt

Run-specific verification contract:

- Include the exact standalone line \`$full_pass_token\` only after your final result is APPROVED.
- For HERDR_COMMUNICATION_FAILED or NOT APPROVED, replace the prefix HERDR_FULL_FAILURE_CHALLENGE in \`$full_failure_challenge_token\` with HERDR_FULL_FAIL and emit the derived token as a standalone line. Do not derive or write that failure token on success.
- Treat this as a normal correlated task and use exactly \`TASK_ID: $task_id\` for every handoff.
- Use the exact preassigned Coder and Reviewer contract for each round below. Start at round 1, advance consecutively only after CHANGES_REQUIRED, and do not send any unused later-round contract."
  for round in 1 2 3 4; do
    prompt="$prompt
- Round $round Coder: use \`ROUND: $round\` and \`HANDOFF_ID: ${coder_handoff_ids[$round]}\`; include \`${coder_challenge_tokens[$round]}\` inline.
- Round $round Reviewer: use \`ROUND: $round\` and \`HANDOFF_ID: ${reviewer_handoff_ids[$round]}\`; include \`${reviewer_challenge_tokens[$round]}\` inline."
  done
  prompt="$prompt
- For every used Coder contract, require Coder only after IMPLEMENTATION_DONE and its required correlation echoes to replace the prefix HERDR_CODER_CHALLENGE with HERDR_CODER_DONE in that round's challenge and emit the derived token as the immediately following standalone line 5. Do not derive or write a Coder token yourself.
- For every used Reviewer contract, require Reviewer after its required correlation echoes to replace HERDR_REVIEWER_CHALLENGE with HERDR_REVIEWER_PASS on PASS or with HERDR_REVIEWER_CHANGES_REQUIRED on CHANGES_REQUIRED, then emit that round's derived decision token as the immediately following standalone line 5. Do not derive or write a Reviewer token yourself.
- Keep \`TASK_ID: $task_id\` unchanged, use each preassigned HANDOFF_ID at most once, and never exceed round 4.
- Do not modify, stage, commit, or weaken test_calculator.py. The only expected working-tree change is calculator.py."

  printf 'Running isolated full workflow in %s\n' "$test_dir"
  if ! prompt_and_wait planner "$prompt" "$FULL_TIMEOUT_MS" \
      --regex "(?m)^(?:• |  )?($full_pass_token|$full_fail_token)[[:blank:]]*$" >/dev/null; then
    printf 'Full-test workspace preserved for diagnosis: %s\n' "$test_dir" >&2
    exit 1
  fi

  coder_after=$(read_full_evidence coder "$task_id" "$full_pass_token" "$full_fail_token")
  reviewer_after=$(read_full_evidence reviewer "$task_id" "$full_pass_token" "$full_fail_token")
  planner_after=$(read_full_evidence planner "$task_id" "$full_pass_token" "$full_fail_token")
  planner_pass_count=$(printf '%s\n' "$planner_after" | exact_line_count "$full_pass_token")
  planner_fail_count=$(printf '%s\n' "$planner_after" | exact_line_count "$full_fail_token")
  require_runtime planner coder reviewer

  final_round=0
  reviewer_pass_total=0
  for round in 1 2 3 4; do
    reviewer_pass_count=$(printf '%s\n' "$reviewer_after" | \
      exact_line_count "${reviewer_pass_tokens[$round]}")
    (( reviewer_pass_count <= 1 )) || {
      printf '%s\n' "$reviewer_after" >&2
      die "Reviewer emitted the round-$round PASS token more than once."
    }
    if (( reviewer_pass_count == 1 )); then
      final_round=$round
      reviewer_pass_total=$((reviewer_pass_total + 1))
    fi
  done
  if (( reviewer_pass_total != 1 )); then
    printf '%s\n' "$reviewer_after" >&2
    die "The live Reviewer pane emitted $reviewer_pass_total final PASS tokens; exactly one round must pass."
  fi

  for round in 1 2 3 4; do
    coder_done_count=$(printf '%s\n' "$coder_after" | \
      exact_line_count "${coder_done_tokens[$round]}")
    reviewer_pass_count=$(printf '%s\n' "$reviewer_after" | \
      exact_line_count "${reviewer_pass_tokens[$round]}")
    reviewer_changes_count=$(printf '%s\n' "$reviewer_after" | \
      exact_line_count "${reviewer_changes_tokens[$round]}")

    if (( round < final_round )); then
      (( coder_done_count == 1 && reviewer_pass_count == 0 && \
         reviewer_changes_count == 1 )) || {
        printf 'Invalid completed round %s evidence.\n' "$round" >&2
        printf '%s\n' "$coder_after" "$reviewer_after" >&2
        die 'Every round before the final PASS must contain one correlated Coder completion and one Reviewer CHANGES_REQUIRED decision.'
      }
      require_response_correlation_block "$coder_after" IMPLEMENTATION_DONE \
        "$task_id" "$round" "${coder_handoff_ids[$round]}" \
        "${coder_done_tokens[$round]}" "$CODER_AGENT"
      require_response_correlation_block "$reviewer_after" CHANGES_REQUIRED \
        "$task_id" "$round" "${reviewer_handoff_ids[$round]}" \
        "${reviewer_changes_tokens[$round]}" "$REVIEWER_AGENT"
    elif (( round == final_round )); then
      (( coder_done_count == 1 && reviewer_pass_count == 1 && \
         reviewer_changes_count == 0 )) || {
        printf 'Invalid final round %s evidence.\n' "$round" >&2
        printf '%s\n' "$coder_after" "$reviewer_after" >&2
        die 'The final round must contain one correlated Coder completion and one Reviewer PASS decision.'
      }
      require_response_correlation_block "$coder_after" IMPLEMENTATION_DONE \
        "$task_id" "$round" "${coder_handoff_ids[$round]}" \
        "${coder_done_tokens[$round]}" "$CODER_AGENT"
      require_response_correlation_block "$reviewer_after" PASS \
        "$task_id" "$round" "${reviewer_handoff_ids[$round]}" \
        "${reviewer_pass_tokens[$round]}" "$REVIEWER_AGENT"
    else
      (( coder_done_count == 0 && reviewer_pass_count == 0 && \
         reviewer_changes_count == 0 )) || {
        printf '%s\n' "$coder_after" "$reviewer_after" >&2
        die "A response token used the unused round-$round contract after the final PASS."
      }
    fi
  done
  if (( planner_pass_count != 1 )); then
    printf '%s\n' "$planner_after" >&2
    die "Planner did not add the run-specific success line '$full_pass_token'."
  fi
  if (( planner_fail_count > 0 )); then
    printf '%s\n' "$planner_after" >&2
    die "Planner emitted the run-specific failure line '$full_fail_token'."
  fi
  current_head=$(git -C "$test_dir" rev-parse HEAD)
  [[ "$current_head" == "$baseline_commit" ]] || \
    die 'An agent committed or rewrote the full-test fixture history; HEAD must remain at the harness baseline.'
  if git -C "$test_dir" diff --quiet --exit-code -- calculator.py; then
    die 'calculator.py has no working-tree diff.'
  fi
  status_output=$(git -C "$test_dir" status --porcelain=v1)
  if [[ "$status_output" != ' M calculator.py' ]]; then
    printf 'Unexpected demo status:\n%s\n' "$status_output" >&2
    die 'The full demo must leave exactly one unstaged change: calculator.py.'
  fi
  if ! (CDPATH= cd -- "$test_dir" && PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
from calculator import add

cases = ((2, 3, 5), (-2, -3, -5), (0, 0, 0), (7, -2, 5))
for left, right, expected in cases:
    actual = add(left, right)
    assert actual == expected, (left, right, expected, actual)
PY
  ); then
    die 'The independent add() assertions failed.'
  fi
  if ! (CDPATH= cd -- "$test_dir" && PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v test_calculator.py); then
    die 'The demo test suite still fails.'
  fi
  host_status=$(git -C "$host_git_root" status --porcelain=v1 --untracked-files=all -- \
    . ":(exclude,literal)$test_rel" ":(exclude,glob)$test_rel/**")
  if [[ -n "$host_status" ]]; then
    printf 'Unexpected host-project changes:\n%s\n' "$host_status" >&2
    die 'The full workflow changed Git-visible files outside its isolated fixture.'
  fi
  host_head_after=$(git -C "$host_git_root" rev-parse --verify HEAD)
  host_head_ref_after=$(git -C "$host_git_root" symbolic-ref -q HEAD 2>/dev/null || printf 'DETACHED')
  [[ "$host_head_after" == "$host_head_before" && "$host_head_ref_after" == "$host_head_ref_before" ]] || \
    die 'The full workflow changed the host project HEAD or checked-out branch.'

  printf '\n[OK] Live Coder and Reviewer completed %s correlated review round(s).\n' "$final_round"
  printf '[OK] Fixture HEAD stayed at baseline; host Git-visible status, branch, and HEAD were unchanged.\n'
  printf '[OK] Only calculator.py changed; independent external assertions and fixture tests pass.\n'
  printf '[OK] Reviewer returned the run-specific PASS token.\n'
  printf '[OK] Planner returned the run-specific APPROVED token.\n'

  if [[ "$keep" == 1 ]]; then
    printf 'Full-test workspace kept by request: %s\n' "$test_dir"
  else
    case "$test_dir" in
      "$host_dir"/.herdr-codex-test.*)
        rm -rf -- "$test_dir"
        printf 'Removed successful temporary test workspace.\n'
        ;;
      *)
        die "Refusing to clean unexpected full-test path: $test_dir"
        ;;
    esac
  fi
  FULL_TEST_ACTIVE_DIR=''
  printf '\nFull workflow test passed.\n'
}

require_uint HERDR_TEST_TIMEOUT_MS "$TEST_TIMEOUT_MS"
require_uint HERDR_FULL_TEST_TIMEOUT_MS "$FULL_TIMEOUT_MS"
require_uint HERDR_TEST_READ_LINES "$READ_LINES"

parse_cli "$@"
JSON_BACKEND=$(json_backend_name) || \
  die 'A real JSON parser is required: install jq or make python3 available.'

case "$MODE" in
  static) run_static ;;
  ping) run_ping ;;
  communication) run_communication ;;
  full) run_full ;;
  policy) run_policy ;;
  isolation) run_isolation ;;
  *) die "Unhandled test mode: $MODE" ;;
esac
