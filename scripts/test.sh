#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
TEST_TIMEOUT_MS=${HERDR_TEST_TIMEOUT_MS:-120000}
FULL_TIMEOUT_MS=${HERDR_FULL_TEST_TIMEOUT_MS:-1200000}
READ_LINES=${HERDR_TEST_READ_LINES:-2000}
FULL_TEST_ACTIVE_DIR=''

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
    'Usage: ./scripts/test.sh static|ping|communication|full' \
    '' \
    '  static         Validate files, shell syntax, role boundaries, and installer safety.' \
    '  ping           External shell -> live coder and reviewer.' \
    '  communication  Live planner -> live coder and reviewer.' \
    '  full           Isolated demo: Planner -> Coder -> Reviewer -> Planner.' \
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

run_token() {
  printf '%s_%s_%s' "$1" "$(date '+%s')" "$$"
}

agent_field() {
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

process_uses_profile() {
  local payload=$1
  local role=$2
  local compact

  if command -v jq >/dev/null 2>&1; then
    printf '%s\n' "$payload" | jq -e --arg role "$role" '
      any(.result.process_info.foreground_processes[]?;
        (
          ((.argv // []) as $args |
            any(range(0; ($args | length));
              (($args[.] == "--profile") and ($args[. + 1] == $role))))
          or
          ((.cmdline // "") |
            test("(^|[[:space:]])--profile[[:space:]]+" + $role + "([[:space:]]|$)"))
        )
      )
    ' >/dev/null 2>&1
    return
  fi

  compact=$(printf '%s\n' "$payload" | tr '\n' ' ')
  printf '%s\n' "$compact" | grep -Eq -- \
    '"--profile"[[:space:]]*,[[:space:]]*"'"$role"'"|--profile[[:space:]]+'"$role"'([[:space:]]|")'
}

read_agent() {
  herdr agent read "$1" --source recent-unwrapped --lines "$READ_LINES" 2>/dev/null || true
}

require_runtime() {
  local role
  local payload
  local live_name
  local agent_kind
  local agent_status
  local interactive_ready
  local launch_pending
  local pane_id
  local process_payload

  command -v herdr >/dev/null 2>&1 || die 'Herdr was not found in PATH.'
  if ! server_status=$(herdr status server 2>&1); then
    printf '%s\n' "$server_status" >&2
    die 'Herdr server is not reachable. Start or attach Herdr first.'
  fi
  for role in "$@"; do
    if ! payload=$(herdr agent get "$role" 2>&1); then
      die "Live Herdr agent '$role' was not found. Run ./scripts/start.sh /path/to/project."
    fi
    live_name=$(agent_field "$payload" name)
    agent_kind=$(agent_field "$payload" agent)
    agent_status=$(agent_field "$payload" agent_status)
    interactive_ready=$(agent_field "$payload" interactive_ready)
    launch_pending=$(agent_field "$payload" launch_pending)
    pane_id=$(agent_field "$payload" pane_id)
    [[ "$live_name" == "$role" ]] || \
      die "Target '$role' resolved to unexpected live name '${live_name:-unknown}'."
    [[ "$agent_kind" == 'codex' ]] || \
      die "Live name '$role' is agent kind '${agent_kind:-unknown}', not codex."
    [[ -n "$pane_id" ]] || die "Live '$role' did not expose its pane ID."
    if ! process_payload=$(herdr pane process-info --pane "$pane_id" 2>&1); then
      printf '%s\n' "$process_payload" >&2
      die "Could not inspect the foreground process for live '$role'."
    fi
    process_uses_profile "$process_payload" "$role" || \
      die "Live '$role' is not verifiably running with --profile $role. Restart it through start.sh."
    [[ "$interactive_ready" == 'true' && "$launch_pending" != 'true' ]] || \
      die "Live '$role' is not interactively ready (ready=${interactive_ready:-unknown}, launch_pending=${launch_pending:-unknown})."
    case "$agent_status" in
      idle|done) ;;
      *) die "Live '$role' must be settled before testing; current state is '${agent_status:-unknown}'." ;;
    esac
  done
}

require_agents_cover_host() {
  local host_dir=$1
  local role
  local payload
  local agent_cwd
  local foreground_cwd
  local covers

  for role in planner coder reviewer; do
    payload=$(herdr agent get "$role" 2>&1)
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
      die "Live '$role' cwd does not cover the full-test host '$host_dir' (cwd=${agent_cwd:-unknown}, foreground_cwd=${foreground_cwd:-unknown}). Run full from the project used by start.sh or set HERDR_TEST_PROJECT_DIR correctly."
  done
}

prompt_and_wait() {
  local agent=$1
  local prompt=$2
  local timeout=$3
  local result

  # Herdr does not bind --wait to a turn when the target is already working.
  # Fail closed immediately before submission, then verify again afterward.
  require_runtime "$agent"
  if ! result=$(herdr agent prompt "$agent" "$prompt" --wait --timeout "$timeout" 2>&1); then
    printf '%s\n' "$result" >&2
    die "Herdr prompt to '$agent' failed. Inspect with: herdr agent get $agent"
  fi
  printf '%s\n' "$result"
  require_runtime "$agent"
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

  required='README.md
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
tests/prompts/01-coder-ping.md
tests/prompts/02-reviewer-ping.md
tests/prompts/03-planner-to-coder.md
tests/prompts/04-planner-to-reviewer.md
tests/prompts/05-full-loop.md
tests/fixtures/full-loop/.gitignore
tests/fixtures/full-loop/calculator.py
tests/fixtures/full-loop/test_calculator.py
docs/architecture.md
docs/installation.md
docs/workflow.md
docs/configuration.md
docs/troubleshooting.md
docs/security.md'

  while IFS= read -r path; do
    [[ -f "$PROJECT_ROOT/$path" ]] || die "Required file is missing: $path"
  done <<<"$required"

  for script in "$PROJECT_ROOT"/scripts/*.sh; do
    bash -n "$script"
  done
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
  grep -Fq 'HERDR_COMMUNICATION_FAILED' "$PROJECT_ROOT/prompts/planner.md" || \
    die 'Planner prompt lacks the mandatory Herdr failure result.'
  grep -Fq 'Allow at most 4 review rounds total.' "$PROJECT_ROOT/prompts/planner.md" || \
    die 'Planner prompt does not clearly cap the loop at 4 rounds.'
  [[ $(grep -Foc 'PLANNER_TO_CODER_CHALLENGE' "$PROJECT_ROOT/tests/prompts/03-planner-to-coder.md") -eq 1 ]] || \
    die 'Planner-to-Coder prompt must contain exactly one challenge placeholder.'
  [[ $(grep -Foc 'PLANNER_TO_REVIEWER_CHALLENGE' "$PROJECT_ROOT/tests/prompts/04-planner-to-reviewer.md") -eq 1 ]] || \
    die 'Planner-to-Reviewer prompt must contain exactly one challenge placeholder.'
  if grep -Fq 'PLANNER_TO_CODER_OK' "$PROJECT_ROOT/tests/prompts/03-planner-to-coder.md" || \
     grep -Fq 'PLANNER_TO_REVIEWER_OK' "$PROJECT_ROOT/tests/prompts/04-planner-to-reviewer.md"; then
    die 'A mediated prompt contains its complete expected response instead of a challenge.'
  fi
  process_fixture='{"result":{"process_info":{"foreground_processes":[{"argv":["codex","--profile","planner"]}]}}}'
  process_uses_profile "$process_fixture" planner || \
    die 'Process/profile binding parser rejected a valid fixture.'
  if process_uses_profile "$process_fixture" reviewer; then
    die 'Process/profile binding parser accepted the wrong role.'
  fi
  process_fixture='{"result":{"process_info":{"foreground_processes":[{"argv":["codex","--profile","planner-extra"]}]}}}'
  if process_uses_profile "$process_fixture" planner; then
    die 'Process/profile binding parser accepted a role-name prefix.'
  fi
  printf '[OK] Profile and prompt guardrails\n'

  temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/herdr-codex-team-static.XXXXXX")
  codex_test_dir="$temporary_root/codex"
  mkdir -p "$codex_test_dir"

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

  prompt=$(<"$prompt_file")
  unique_marker=$(run_token "$marker")
  prompt=${prompt//"$marker"/"$unique_marker"}
  prompt_count=$(printf '%s\n' "$prompt" | token_line_count "$unique_marker")

  printf 'Pinging live Herdr %s...\n' "$role"
  prompt_and_wait "$role" "$prompt" "$TEST_TIMEOUT_MS" >/dev/null
  after=$(read_agent "$role")
  after_count=$(printf '%s\n' "$after" | token_line_count "$unique_marker")

  if (( after_count < prompt_count + 1 )); then
    printf '%s\n' "$after" >&2
    die "$role did not add the expected exact run token '$unique_marker' after the submitted prompt."
  fi
  printf '[OK] external shell -> live %s -> %s\n' "$role" "$unique_marker"
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

  prompt=$(<"$prompt_file")
  unique_challenge=$(run_token "$challenge_marker")
  unique_response=${unique_challenge/CHALLENGE/OK}
  prompt=${prompt//"$challenge_marker"/"$unique_challenge"}

  printf 'Asking live Planner to route to live %s...\n' "$target"
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
  printf '[OK] live planner -> live %s -> %s\n' "$target" "$unique_response"
}

run_communication() {
  require_uint HERDR_TEST_TIMEOUT_MS "$TEST_TIMEOUT_MS"
  require_runtime planner coder reviewer
  run_route_case coder "$PROJECT_ROOT/tests/prompts/03-planner-to-coder.md" PLANNER_TO_CODER_CHALLENGE
  run_route_case reviewer "$PROJECT_ROOT/tests/prompts/04-planner-to-reviewer.md" PLANNER_TO_REVIEWER_CHALLENGE
  printf '\nCommunication tests passed.\n'
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

case ${1:-} in
  static) run_static ;;
  ping) run_ping ;;
  communication) run_communication ;;
  full) run_full ;;
  --help|-h|'') usage; [[ -n ${1:-} ]] || exit 2 ;;
  *) usage >&2; exit 2 ;;
esac
