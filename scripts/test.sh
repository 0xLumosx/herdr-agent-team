#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
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
  if [[ $status -ne 0 && -n "$FULL_TEST_ACTIVE_DIR" ]]; then
    printf 'Full-test workspace preserved for diagnosis: %s\n' "$FULL_TEST_ACTIVE_DIR" >&2
  fi
  exit "$status"
}
trap report_preserved_full_test EXIT

usage() {
  printf '%s\n' \
    'Usage: ./scripts/test.sh [--team PREFIX] [--against-team PREFIX] static|ping|communication|full|isolation' \
    '' \
    '  static         Validate files, shell syntax, role boundaries, and installer safety.' \
    '  ping           External shell -> live coder and reviewer.' \
    '  communication  Live planner -> live coder and reviewer.' \
    '  full           Isolated demo: Planner -> Coder -> Reviewer -> Planner.' \
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
    'Full-test workspace override:' \
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
    static|ping|communication|full|isolation) ;;
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

run_token() {
  printf '%s_%s_%s' "$1" "$(date '+%s')" "$$"
}

agent_field() {
  local payload=$1
  local field=$2

  json_agent_field "$payload" "$field" || true
}

process_uses_profile() {
  local payload=$1
  local role=$2

  json_process_uses_profile "$payload" "$role"
}

read_agent() {
  local role=$1
  local live_name
  live_name=$(team_agent_for_role "$role") || die "Unknown role: $role"
  herdr agent read "$live_name" --source recent-unwrapped --lines "$READ_LINES" 2>/dev/null || true
}

read_named_agent_strict() {
  local live_name=$1
  local payload

  if ! payload=$(herdr agent read "$live_name" \
      --source recent-unwrapped --lines "$READ_LINES" 2>&1); then
    printf '%s\n' "$payload" >&2
    die "Could not read retained transcript for live '$live_name'."
  fi
  printf '%s\n' "$payload"
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
  live_name=$(agent_field "$payload" name)
  agent_kind=$(agent_field "$payload" agent)
  agent_status=$(agent_field "$payload" agent_status)
  interactive_ready=$(agent_field "$payload" interactive_ready)
  launch_pending=$(agent_field "$payload" launch_pending)
  pane_id=$(agent_field "$payload" pane_id)
  workspace_id=$(agent_field "$payload" workspace_id)
  state_change_seq=$(agent_field "$payload" state_change_seq)
  [[ "$live_name" == "$live_name_expected" ]] || \
    die "Target '$live_name_expected' resolved to unexpected live name '${live_name:-unknown}'."
  [[ "$agent_kind" == 'codex' ]] || \
    die "Live name '$live_name_expected' is agent kind '${agent_kind:-unknown}', not codex."
  [[ -n "$pane_id" ]] || die "Live '$live_name_expected' did not expose its pane ID."
  [[ -n "$workspace_id" ]] || die "Live '$live_name_expected' did not expose its workspace ID."
  [[ "$state_change_seq" =~ ^[0-9]+$ ]] || \
    die "Live '$live_name_expected' did not expose a numeric state_change_seq."
  if ! process_payload=$(herdr pane process-info --pane "$pane_id" 2>&1); then
    printf '%s\n' "$process_payload" >&2
    die "Could not inspect the foreground process for live '$live_name_expected'."
  fi
  process_uses_profile "$process_payload" "$role" || \
    die "Live '$live_name_expected' is not verifiably running with generic --profile $role. Restart it through start.sh."
  [[ "$interactive_ready" == 'true' && "$launch_pending" != 'true' ]] || \
    die "Live '$live_name_expected' is not interactively ready (ready=${interactive_ready:-unknown}, launch_pending=${launch_pending:-unknown})."
  case "$agent_status" in
    idle|done) ;;
    *) die "Live '$live_name_expected' must be settled before testing; current state is '${agent_status:-unknown}'." ;;
  esac
  REQUIRED_AGENT_WORKSPACE=$workspace_id
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
  local role
  local live_name
  local payload
  local agent_cwd
  local foreground_cwd
  local covers

  for role in planner coder reviewer; do
    live_name=$(team_agent_for_role "$role")
    payload=$(herdr agent get "$live_name" 2>&1)
    agent_cwd=$(agent_field "$payload" cwd)
    foreground_cwd=$(agent_field "$payload" foreground_cwd)
    covers=0
    for candidate in "$foreground_cwd" "$agent_cwd"; do
      [[ -n "$candidate" ]] || continue
      case "$host_dir/" in
        "$candidate/"*) covers=1 ;;
      esac
    done
    [[ $covers -eq 1 ]] || \
      die "Live '$live_name' cwd does not cover the full-test host '$host_dir' (cwd=${agent_cwd:-unknown}, foreground_cwd=${foreground_cwd:-unknown}). Run full from the project used by start.sh or set HERDR_TEST_PROJECT_DIR correctly."
  done
}

prompt_and_wait() {
  local role=$1
  local prompt=$2
  local timeout=$3
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
  local doctor_log
  local doctor_call_log
  local herdr_call_log
  local split_counter
  local parse_log

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
scripts/doctor.sh
scripts/start.sh
scripts/test.sh
scripts/uninstall.sh
scripts/lib/team.sh
scripts/lib/json.sh
tests/prompts/01-coder-ping.md
tests/prompts/02-reviewer-ping.md
tests/prompts/03-planner-to-coder.md
tests/prompts/04-planner-to-reviewer.md
tests/prompts/05-full-loop.md
tests/prompts/06-multi-team-routing.md
tests/fixtures/full-loop/.gitignore
tests/fixtures/full-loop/calculator.py
tests/fixtures/full-loop/test_calculator.py
docs/architecture.md
docs/installation.md
docs/workflow.md
docs/configuration.md
docs/troubleshooting.md
docs/security.md'
  required="$required
docs/multi-team.md
docs/zh-CN/architecture.md
docs/zh-CN/configuration.md
docs/zh-CN/installation.md
docs/zh-CN/multi-team.md
docs/zh-CN/security.md
docs/zh-CN/troubleshooting.md
docs/zh-CN/workflow.md
examples/multi-team.md"

  while IFS= read -r path; do
    [[ -f "$PROJECT_ROOT/$path" ]] || die "Required file is missing: $path"
  done <<<"$required"

  for script in "$PROJECT_ROOT"/scripts/*.sh; do
    bash -n "$script"
  done
  bash -n "$TEAM_LIB"
  bash -n "$JSON_LIB"
  printf '[OK] Shell syntax\n'

  grep -Eq '^sandbox_mode[[:space:]]*=[[:space:]]*"workspace-write"' "$PROJECT_ROOT/profiles/planner.config.toml" || \
    die 'Planner template is not workspace-write.'
  grep -Eq '^sandbox_mode[[:space:]]*=[[:space:]]*"workspace-write"' "$PROJECT_ROOT/profiles/coder.config.toml" || \
    die 'Coder template is not workspace-write.'
  grep -Eq '^sandbox_mode[[:space:]]*=[[:space:]]*"read-only"' "$PROJECT_ROOT/profiles/reviewer.config.toml" || \
    die 'Reviewer template is not read-only.'
  for role in planner coder reviewer; do
    grep -Eq '^approval_policy[[:space:]]*=[[:space:]]*"never"[[:space:]]*$' \
      "$PROJECT_ROOT/profiles/$role.config.toml" || \
      die "$role template does not set approval_policy = \"never\"."
  done
  if grep -Eq '^sandbox_mode[[:space:]]*=[[:space:]]*"danger-full-access"' "$PROJECT_ROOT"/profiles/*.config.toml; then
    die 'A profile defaults to danger-full-access.'
  fi
  grep -Fq 'HERDR COMMUNICATION IS MANDATORY' "$PROJECT_ROOT/prompts/planner.md" || \
    die 'Planner prompt lacks the mandatory Herdr guardrail.'
  grep -Fq 'HERDR TEAM IDENTITY AND ROUTING' "$PROJECT_ROOT/prompts/planner.md" || \
    die 'Planner prompt lacks explicit runtime team identity and routing rules.'
  grep -Fq 'STRICT TEAM ISOLATION' "$PROJECT_ROOT/prompts/planner.md" || \
    die 'Planner prompt lacks the strict team-isolation guardrail.'
  grep -Fq 'HERDR_PANE_ID' "$PROJECT_ROOT/prompts/planner.md" || \
    die 'Planner prompt does not derive identity from its Herdr pane.'
  grep -Fq 'HERDR_COMMUNICATION_FAILED' "$PROJECT_ROOT/prompts/planner.md" || \
    die 'Planner prompt lacks the mandatory Herdr failure result.'
  grep -Fq 'Allow at most 4 review rounds total.' "$PROJECT_ROOT/prompts/planner.md" || \
    die 'Planner prompt does not clearly cap the loop at 4 rounds.'
  grep -Eq '^model[[:space:]]*=[[:space:]]*"gpt-5\.6-luna"[[:space:]]*$' \
    "$PROJECT_ROOT/profiles/coder.config.toml" || \
    die 'Coder template does not default to gpt-5.6-luna.'
  grep -Eq '^model_reasoning_effort[[:space:]]*=[[:space:]]*"high"[[:space:]]*$' \
    "$PROJECT_ROOT/profiles/coder.config.toml" || \
    die 'Coder template does not default to high reasoning effort.'
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

  [[ $(team_name_for_prefix '' planner) == planner ]] || \
    die 'Legacy Planner name derivation failed.'
  [[ $(team_name_for_prefix github coder) == github-coder ]] || \
    die 'Prefixed Coder name derivation failed.'
  [[ $(team_name_for_prefix github reviewer) == github-reviewer ]] || \
    die 'Prefixed Reviewer name derivation failed.'
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
  process_fixture='{"result":{"process_info":{"foreground_processes":[{"pid":101,"name":"codex","argv0":"/usr/local/bin/codex","argv":["codex","--profile","planner-extra"]}]}}}'
  if process_uses_profile "$process_fixture" planner; then
    die 'Process/profile binding parser accepted a role-name prefix.'
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
  printf '[OK] Profile and prompt guardrails\n'

  temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/herdr-codex-team-static.XXXXXX")
  codex_test_dir="$temporary_root/codex"
  mkdir -p "$codex_test_dir"

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
    grep -Eq '^developer_instructions[[:space:]]*=' "$codex_test_dir/$role.config.toml" || \
      die "Installed $role profile lacks developer instructions."
    grep -Eq '^model[[:space:]]*=[[:space:]]*"test-'"$role"'"' "$codex_test_dir/$role.config.toml" || \
      die "Installed $role model override is missing."
  done

  for role in planner coder reviewer; do
    if ! CODEX_HOME="$codex_test_dir" \
         codex --profile "$role" debug prompt-input 'profile validation' >/dev/null 2>&1; then
      die "Codex could not load the rendered $role profile."
    fi
  done
  printf '[OK] Codex loaded all rendered profiles\n'

  mock_bin="$temporary_root/mock-bin"
  workspace_marker="$temporary_root/workspace-created"
  mkdir -p "$mock_bin"
  cat >"$mock_bin/codex" <<'MOCK_CODEX'
#!/usr/bin/env bash
if [[ ${1-} == --version ]]; then
  printf '%s\n' 'codex-cli mock'
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
      race-collision)
        printf '%s\n' '{"result":{"type":"agent_list","agents":[]}}'
        ;;
      doctor-success)
        printf '%s\n' '{"result":{"type":"agent_list","agents":[{"name":"github-planner"},{"name":"github-coder"},{"name":"github-reviewer"}]}}'
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
    : >"$MOCK_WORKSPACE_MARKER"
    printf '%s\n' '{"result":{"workspace":{"workspace_id":"mock-workspace"},"root_pane":{"pane_id":"mock-root"}}}'
    ;;
  pane:split)
    [[ ${3-} == --help ]] && exit 0
    count=0
    [[ -f "$MOCK_SPLIT_COUNTER" ]] && count=$(<"$MOCK_SPLIT_COUNTER")
    count=$((count + 1))
    printf '%s' "$count" >"$MOCK_SPLIT_COUNTER"
    printf '{"result":{"pane":{"pane_id":"mock-pane-%s"}}}\n' "$count"
    ;;
  agent:start)
    [[ ${3-} == --help ]] && exit 0
    printf '%s\n' "$*" >>"$MOCK_HERDR_CALL_LOG"
    if [[ ${MOCK_HERDR_MODE:-} == race-collision && ${3-} == github-coder ]]; then
      printf '%s\n' 'agent_name_taken: github-coder' >&2
      exit 1
    fi
    ;;
  agent:get)
    [[ ${3-} == --help ]] && exit 0
    if [[ ${MOCK_HERDR_MODE:-} == doctor-success ]]; then
      case ${3-} in
        github-planner|github-coder|github-reviewer)
          printf '%s\n' "$*" >>"$MOCK_HERDR_CALL_LOG"
          role=${3#github-}
          printf '{"result":{"agent":{"name":"%s","agent":"codex","agent_status":"idle","interactive_ready":true,"launch_pending":false,"pane_id":"mock-%s-pane","workspace_id":"mock-team-workspace","cwd":"%s","foreground_cwd":"%s"}}}\n' \
            "$3" "$role" "$MOCK_PROJECT_ROOT" "$MOCK_PROJECT_ROOT"
          exit 0
          ;;
      esac
    fi
    exit 1
    ;;
  pane:process-info)
    [[ ${3-} == --help ]] && exit 0
    if [[ ${MOCK_HERDR_MODE:-} == doctor-success ]]; then
      case ${4-} in
        mock-planner-pane) role=planner ;;
        mock-coder-pane) role=coder ;;
        mock-reviewer-pane) role=reviewer ;;
        *) exit 1 ;;
      esac
      printf '{"result":{"process_info":{"foreground_processes":[{"pid":101,"name":"codex","argv0":"/usr/local/bin/codex","argv":["codex","--profile","%s"],"cmdline":"codex --profile %s"}]}}}\n' \
        "$role" "$role"
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

  doctor_log="$temporary_root/doctor.log"
  doctor_call_log="$temporary_root/doctor-calls.log"
  : >"$doctor_call_log"
  if ! env -u TEAM_PREFIX PATH="$mock_bin:$PATH" CODEX_HOME="$codex_test_dir" \
       MOCK_HERDR_MODE=doctor-success \
       MOCK_HERDR_CALL_LOG="$doctor_call_log" \
       MOCK_PROJECT_ROOT="$PROJECT_ROOT" \
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
  printf '[OK] doctor.sh validates one exact prefixed team\n'

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
  unique_challenge=$(run_token "$challenge_marker")
  unique_response=${unique_challenge/CHALLENGE/OK}
  prompt=${prompt//"$challenge_marker"/"$unique_challenge"}

  target_live_name=$(team_agent_for_role "$target")
  printf 'Asking live %s to route to live %s...\n' "$PLANNER_AGENT" "$target_live_name"
  prompt_and_wait planner "$prompt" "$TEST_TIMEOUT_MS" >/dev/null
  require_runtime "$target"
  after=$(read_agent "$target")
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
  local coder_challenge_token
  local coder_done_token
  local coder_done_count
  local reviewer_challenge_token
  local reviewer_pass_token
  local planner_pass_count
  local planner_fail_count
  local planner_pass_in_prompt
  local reviewer_pass_count
  local status_output
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
  require_agents_cover_host "$host_dir"

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
  coder_challenge_token=$(run_token HERDR_CODER_CHALLENGE)
  coder_done_token=${coder_challenge_token/HERDR_CODER_CHALLENGE/HERDR_CODER_DONE}
  reviewer_challenge_token=$(run_token HERDR_REVIEWER_CHALLENGE)
  reviewer_pass_token=${reviewer_challenge_token/HERDR_REVIEWER_CHALLENGE/HERDR_REVIEWER_PASS}
  prompt="$prompt

Run-specific verification contract:

- Include the exact standalone line \`$full_pass_token\` only after your final result is APPROVED.
- For HERDR_COMMUNICATION_FAILED or NOT APPROVED, replace the prefix HERDR_FULL_FAILURE_CHALLENGE in \`$full_failure_challenge_token\` with HERDR_FULL_FAIL and emit the derived token as a standalone line. Do not derive or write that failure token on success.
- In every Coder handoff, include the challenge \`$coder_challenge_token\` inline. Require Coder, only after IMPLEMENTATION_DONE, to replace the prefix HERDR_CODER_CHALLENGE with HERDR_CODER_DONE and emit the derived token as a standalone line immediately after its status. Do not derive or write that DONE token yourself.
- In every Reviewer handoff, include the challenge \`$reviewer_challenge_token\` inline. Require Reviewer, only when its decision is PASS, to replace the prefix HERDR_REVIEWER_CHALLENGE with HERDR_REVIEWER_PASS and emit the derived token as a standalone line immediately after PASS. Reviewer must omit it for CHANGES_REQUIRED. Do not derive or write that PASS token yourself.
- Do not modify, stage, commit, or weaken test_calculator.py. The only expected working-tree change is calculator.py."

  planner_pass_in_prompt=$(printf '%s\n' "$prompt" | token_line_count "$full_pass_token")

  printf 'Running isolated full workflow in %s\n' "$test_dir"
  if ! prompt_and_wait planner "$prompt" "$FULL_TIMEOUT_MS" >/dev/null; then
    printf 'Full-test workspace preserved for diagnosis: %s\n' "$test_dir" >&2
    exit 1
  fi

  coder_after=$(read_agent coder)
  reviewer_after=$(read_agent reviewer)
  planner_after=$(read_agent planner)
  planner_pass_count=$(printf '%s\n' "$planner_after" | token_line_count "$full_pass_token")
  planner_fail_count=$(printf '%s\n' "$planner_after" | token_line_count "$full_fail_token")
  coder_done_count=$(printf '%s\n' "$coder_after" | token_line_count "$coder_done_token")
  reviewer_pass_count=$(printf '%s\n' "$reviewer_after" | token_line_count "$reviewer_pass_token")
  require_runtime planner coder reviewer

  if (( coder_done_count < 1 )); then
    printf '%s\n' "$coder_after" >&2
    die 'The live Coder pane did not show the derived run-specific IMPLEMENTATION_DONE response.'
  fi
  if (( reviewer_pass_count < 1 )); then
    printf '%s\n' "$reviewer_after" >&2
    die 'The live Reviewer pane did not show the run-specific PASS response.'
  fi
  if (( planner_pass_count < planner_pass_in_prompt + 1 )); then
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

  printf '\n[OK] Live Coder and Reviewer returned derived run-specific role tokens.\n'
  printf '[OK] Fixture HEAD stayed at baseline; host Git-visible status, branch, and HEAD were unchanged.\n'
  printf '[OK] Only calculator.py changed; immutable external assertions and fixture tests pass.\n'
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
  isolation) run_isolation ;;
  *) die "Unhandled test mode: $MODE" ;;
esac
