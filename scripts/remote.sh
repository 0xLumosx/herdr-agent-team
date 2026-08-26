#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
TEAM_LIB="$SCRIPT_DIR/lib/team.sh"
DIGEST_LIB="$SCRIPT_DIR/lib/digest.sh"
[[ -f "$TEAM_LIB" && -f "$DIGEST_LIB" ]] || {
  printf '[FAIL] Missing script helper under %s/lib.\n' "$SCRIPT_DIR" >&2
  exit 1
}
# shellcheck source=lib/team.sh
source "$TEAM_LIB"
# shellcheck source=lib/digest.sh
source "$DIGEST_LIB"

HOST=''
TEAM=''
PROJECT_DIR=''
REPAIR_PROFILES=0
INSTALL_INTEGRATION=0
ADD_DIRS=()

BUNDLE_FILES=(
  scripts/open.sh
  scripts/start.sh
  scripts/doctor.sh
  scripts/install.sh
  scripts/herdr_mcp.py
  scripts/lib/team.sh
  scripts/lib/json.sh
  scripts/lib/digest.sh
  scripts/lib/scope.sh
  scripts/lib/run-state.sh
  scripts/lib/remote-bootstrap.sh
  profiles/planner.config.toml
  profiles/coder.config.toml
  profiles/reviewer.config.toml
  prompts/planner.md
  prompts/coder.md
  prompts/reviewer.md
)

usage() {
  printf '%s\n' \
    'Usage: ./scripts/remote.sh [--repair-profiles] [--install-integration] --host SSH_HOST --team PREFIX --cwd REMOTE_PROJECT [--add-dir REMOTE_DIR]...' \
    '' \
    'Shows the Herdr interface locally while the three Codex agents and project files stay on the SSH host.' \
    'The same command creates an absent Team or reopens a verified current live Team.' \
    'If Herdr needs remote setup/update, detach its first UI with Ctrl+B then q; this command continues automatically.' \
    '--repair-profiles explicitly backs up and refreshes remote managed profiles, only when the named session has no live Agent.' \
    '--install-integration explicitly permits Herdr to install/update remote Codex hooks and configuration.' \
    'The current launcher is streamed to a private temporary directory; no remote repository checkout is required.'
}

die() {
  local status=$1
  shift
  printf '[FAIL] %s\n' "$*" >&2
  exit "$status"
}

has_control() {
  LC_ALL=C grep -q '[[:cntrl:]]' <<<"$1"
}

remote_quote() {
  local value=$1
  value=${value//\'/\'\\\'\'}
  printf "'%s'" "$value"
}

parse_herdr_version() {
  local output=$1
  local product
  local version
  local extra

  read -r product version extra <<<"$output"
  [[ "$product" == herdr && -n "$version" && -z "${extra:-}" ]] || return 1
  [[ "$version" =~ ^[0-9][A-Za-z0-9.+_-]*$ ]] || return 1
  printf '%s\n' "$version"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      [[ $# -ge 2 && -z "$HOST" ]] || die 2 '--host requires one value.'
      HOST=$2
      shift 2
      ;;
    --team)
      [[ $# -ge 2 && -z "$TEAM" ]] || die 2 '--team requires one value.'
      TEAM=$2
      shift 2
      ;;
    --cwd)
      [[ $# -ge 2 && -z "$PROJECT_DIR" ]] || die 2 '--cwd requires one value.'
      PROJECT_DIR=$2
      shift 2
      ;;
    --add-dir)
      [[ $# -ge 2 ]] || die 2 '--add-dir requires a value.'
      ADD_DIRS+=("$2")
      shift 2
      ;;
    --repair-profiles)
      [[ $REPAIR_PROFILES -eq 0 ]] || die 2 '--repair-profiles may be provided only once.'
      REPAIR_PROFILES=1
      shift
      ;;
    --install-integration)
      [[ $INSTALL_INTEGRATION -eq 0 ]] || die 2 '--install-integration may be provided only once.'
      INSTALL_INTEGRATION=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die 2 "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$HOST" ]] || die 2 '--host is required.'
case "$HOST" in
  -*|'') die 2 'SSH host must not be empty or start with -.' ;;
esac
if has_control "$HOST" || [[ "$HOST" =~ [[:space:]] ]]; then
  die 2 'SSH host must not contain whitespace or control characters.'
fi
team_validate_prefix "$TEAM" || \
  die 2 'Team prefix must match [a-z][a-z0-9_-]* and be at most 23 characters.'
[[ "$PROJECT_DIR" == /* && "$PROJECT_DIR" != '/' ]] || \
  die 2 'Remote --cwd must be an absolute path other than /.'
has_control "$PROJECT_DIR" && die 2 'Remote --cwd contains a control character.'
for add_dir in ${ADD_DIRS[@]+"${ADD_DIRS[@]}"}; do
  [[ "$add_dir" == /* && "$add_dir" != '/' ]] || \
    die 2 'Each remote --add-dir must be an absolute path other than /.'
  has_control "$add_dir" && die 2 'A remote --add-dir contains a control character.'
done

command -v ssh >/dev/null 2>&1 || die 1 'OpenSSH client was not found in PATH.'
command -v tar >/dev/null 2>&1 || die 1 'tar was not found in PATH.'
command -v herdr >/dev/null 2>&1 || die 1 'Local Herdr was not found in PATH.'
local_herdr_output=$(herdr --version 2>&1) || die 1 'Could not read the local Herdr version.'
LOCAL_HERDR_VERSION=$(parse_herdr_version "$local_herdr_output") || \
  die 1 "Could not parse the complete local Herdr version: $local_herdr_output"

for bundle_file in "${BUNDLE_FILES[@]}"; do
  bundle_path="$PROJECT_ROOT/$bundle_file"
  [[ -f "$bundle_path" && ! -L "$bundle_path" ]] || \
    die 1 "Launcher bundle member must be a regular non-symlink file: $bundle_file"
done
if ! BUNDLE_DIGEST=$(
  for bundle_file in "${BUNDLE_FILES[@]}"; do
    file_digest=$(sha256_stream <"$PROJECT_ROOT/$bundle_file") || exit
    printf '%s  %s\n' "$file_digest" "$bundle_file"
  done | sha256_stream
); then
  die 1 'Could not compute the launcher bundle digest.'
fi

REMOTE_ARGS=(
  --team "$TEAM"
  --cwd "$PROJECT_DIR"
  --herdr-version "$LOCAL_HERDR_VERSION"
  --bundle-digest "$BUNDLE_DIGEST"
)
[[ $REPAIR_PROFILES -eq 0 ]] || REMOTE_ARGS+=(--repair-profiles)
[[ $INSTALL_INTEGRATION -eq 0 ]] || REMOTE_ARGS+=(--install-integration)
for add_dir in ${ADD_DIRS[@]+"${ADD_DIRS[@]}"}; do
  REMOTE_ARGS+=(--add-dir "$add_dir")
done

# The login shell only has to launch Bash. All environment handling and user
# values remain positional arguments interpreted by the streamed Bash driver.
read -r -d '' remote_driver <<'REMOTE_DRIVER' || true
set -euo pipefail
expected_digest=$1
shift
[[ "$expected_digest" =~ ^[0-9a-f]{64}$ ]] || {
  printf '[FAIL] Invalid launcher bundle digest.\n' >&2
  exit 2
}
[[ "${HOME:-}" == /* && "$HOME" != / ]] || {
  printf '[FAIL] Remote HOME must be an absolute path other than /.\n' >&2
  exit 2
}
for remote_tool in tar mktemp find grep awk sed chmod rm python3; do
  command -v "$remote_tool" >/dev/null 2>&1 || {
    printf '[FAIL] Required remote tool is missing: %s\n' "$remote_tool" >&2
    exit 1
  }
done
umask 077
runtime_base=${TMPDIR:-/tmp}
case "$runtime_base" in
  /*) ;;
  *) runtime_base=/tmp ;;
esac
runtime_dir=$(mktemp -d "$runtime_base/herdr-codex-team.XXXXXX") || exit 1
case "$runtime_dir" in
  "$runtime_base"/herdr-codex-team.*) ;;
  *) printf '[FAIL] Unexpected temporary runtime path.\n' >&2; exit 1 ;;
esac
cleanup_runtime() {
  rm -rf -- "$runtime_dir"
}
trap cleanup_runtime EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
tar -xf - -C "$runtime_dir"
if find "$runtime_dir" -type l -print -quit | grep -q .; then
  printf '[FAIL] Launcher bundle contains a symbolic link.\n' >&2
  exit 1
fi
required_files=(
  scripts/open.sh scripts/start.sh scripts/doctor.sh scripts/install.sh \
  scripts/herdr_mcp.py \
  scripts/lib/team.sh scripts/lib/json.sh scripts/lib/digest.sh \
  scripts/lib/scope.sh scripts/lib/run-state.sh \
  scripts/lib/remote-bootstrap.sh \
  profiles/planner.config.toml profiles/coder.config.toml \
  profiles/reviewer.config.toml prompts/planner.md prompts/coder.md \
  prompts/reviewer.md
)
for required in "${required_files[@]}"; do
  [[ -f "$runtime_dir/$required" && ! -L "$runtime_dir/$required" ]] || {
    printf '[FAIL] Launcher bundle is missing %s.\n' "$required" >&2
    exit 1
  }
done
remote_sha256() {
  local digest
  if command -v sha256sum >/dev/null 2>&1; then
    digest=$(sha256sum | awk 'NR == 1 { print $1 }') || return
  elif command -v shasum >/dev/null 2>&1; then
    digest=$(shasum -a 256 | awk 'NR == 1 { print $1 }') || return
  elif command -v openssl >/dev/null 2>&1; then
    digest=$(openssl dgst -sha256 | sed 's/^.*= //') || return
  else
    return 127
  fi
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 2
  printf '%s\n' "$digest"
}
actual_digest=$(
  for required in "${required_files[@]}"; do
    file_digest=$(remote_sha256 <"$runtime_dir/$required") || exit
    printf '%s  %s\n' "$file_digest" "$required"
  done | remote_sha256
) || {
  printf '[FAIL] Could not verify the streamed launcher digest.\n' >&2
  exit 1
}
[[ "$actual_digest" == "$expected_digest" ]] || {
  printf '[FAIL] Streamed launcher digest mismatch.\n' >&2
  exit 1
}
chmod 700 "$runtime_dir/scripts/open.sh" "$runtime_dir/scripts/start.sh" \
  "$runtime_dir/scripts/doctor.sh" "$runtime_dir/scripts/install.sh" \
  "$runtime_dir/scripts/lib/remote-bootstrap.sh"
export PATH="$HOME/.local/bin:$HOME/bin:$PATH"
unset TEAM_PREFIX HERDR_SOCKET_PATH HERDR_CLIENT_SOCKET_PATH HERDR_CODEX_TEAM_ROOT CODEX_HOME
export CODEX_HOME="$HOME/.codex"
export HERDR_CODEX_TEAM_ROOT="$runtime_dir"
"$runtime_dir/scripts/lib/remote-bootstrap.sh" "$@"
REMOTE_DRIVER

build_remote_command() {
  remote_command="bash -c $(remote_quote "$remote_driver") -- $(remote_quote "$BUNDLE_DIGEST")"
  for remote_arg in "${REMOTE_ARGS[@]}"; do
    remote_command+=" $(remote_quote "$remote_arg")"
  done
}

prepare_remote_team() {
  local -a pipeline_status
  local tar_status

  build_remote_command
  printf 'Preparing Team %s on %s (%s) ...\n' "$TEAM" "$HOST" "$PROJECT_DIR"
  set +e
  COPYFILE_DISABLE=1 tar -C "$PROJECT_ROOT" -cf - "${BUNDLE_FILES[@]}" | \
    ssh -T "$HOST" "$remote_command"
  pipeline_status=("${PIPESTATUS[@]}")
  set -e
  tar_status=${pipeline_status[0]}
  prepare_status=${pipeline_status[1]}
  if [[ $tar_status -ne 0 && $prepare_status -eq 0 ]]; then
    prepare_status=1
  fi
}

prepare_remote_team
if [[ $prepare_status -eq 12 || $prepare_status -eq 16 ]]; then
  printf '\nFirst-time Herdr remote setup/update is required.\n'
  printf 'Herdr will open its supported remote flow now; when it is ready, press Ctrl+B then q.\n'
  printf 'If Herdr asks to update or restart an existing server, review that prompt before approving it.\n'
  printf 'This command will then continue automatically and open the three-agent Team.\n\n'
  set +e
  herdr --remote "$HOST" --session "$TEAM" --handoff
  bootstrap_status=$?
  set -e
  [[ $bootstrap_status -eq 0 ]] || die "$bootstrap_status" 'Herdr remote setup did not finish successfully.'
  printf '\nRetrying three-agent Team preparation after Herdr remote setup ...\n'
  prepare_remote_team
fi

if [[ $prepare_status -eq 17 && $INSTALL_INTEGRATION -eq 0 ]]; then
  printf '\nRemote Herdr Codex integration is missing or outdated.\n'
  printf 'Installing it may change executable hooks, hooks.json, and remote Codex configuration.\n'
  printf 'Review this global configuration boundary before approving. Install and continue? [y/N] '
  integration_answer=''
  IFS= read -r integration_answer || true
  case "$integration_answer" in
    y|Y|yes|YES|Yes)
      INSTALL_INTEGRATION=1
      REMOTE_ARGS+=(--install-integration)
      printf '\nRetrying Team preparation with explicit integration-install approval ...\n'
      prepare_remote_team
      ;;
    *)
      printf '\n[FAIL] Integration installation was not approved; no hook or Codex configuration was changed.\n' >&2
      printf '       Review the remote Herdr integration, then rerun the same command and approve, or add --install-integration explicitly.\n' >&2
      exit 17
      ;;
  esac
fi

case "$prepare_status" in
  0) ;;
  12)
    printf '\n[FAIL] Remote Herdr is still unavailable after its supported setup flow.\n' >&2
    printf '       Check SSH and the remote PATH, then rerun the same remote.sh command.\n' >&2
    exit 12
    ;;
  13)
    die 13 'Remote Codex CLI is missing. Install and authenticate Codex on the SSH host first.'
    ;;
  15|255)
    die "$prepare_status" 'Could not reach or start the selected remote Herdr session.'
    ;;
  16)
    printf '\n[FAIL] The local binary, remote binary, and running named-session server are not ready for a safe attach.\n' >&2
    printf '       The supported Herdr setup/update flow already ran; inspect its update/restart decision and retry.\n' >&2
    exit 16
    ;;
  17)
    printf '\n[FAIL] Remote Herdr Codex integration was not installed.\n' >&2
    printf '       Inspect the integration output above before retrying.\n' >&2
    exit 17
    ;;
  3|4)
    printf '\n[WARN] Team preparation returned status %s. No existing agent was automatically replaced.\n' \
      "$prepare_status" >&2
    printf '[WARN] Opening the local Herdr UI so the retained remote panes can be inspected.\n' >&2
    ;;
  1)
    printf '\n[FAIL] Remote Team preparation failed.\n' >&2
    printf '       If the output above reports managed profile drift and no target Agent is live, rerun the same command with --repair-profiles.\n' >&2
    printf '       install.sh will back up existing profiles before replacement.\n' >&2
    exit 1
    ;;
  *)
    die "$prepare_status" 'Remote Team preparation failed before a safe create-or-reuse result.'
    ;;
esac

printf 'Opening local Herdr UI; remote session: %s\n' "$TEAM"
set +e
herdr --remote "$HOST" --session "$TEAM"
attach_status=$?
set -e
if [[ $prepare_status -ne 0 ]]; then
  exit "$prepare_status"
fi
exit "$attach_status"
