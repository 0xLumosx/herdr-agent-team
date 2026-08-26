#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/herdr-remote-launcher.XXXXXX")

cleanup() {
  case "$temporary_root" in
    "${TMPDIR:-/tmp}"/herdr-remote-launcher.*) rm -rf -- "$temporary_root" ;;
  esac
}
trap cleanup EXIT

die() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

fake_root="$temporary_root/fake-team"
mock_bin="$temporary_root/bin"
remote_shell_bin="$temporary_root/remote-shell-bin"
call_log="$temporary_root/calls.log"
profiles_home="$temporary_root/profiles-home"
mkdir -p "$fake_root/scripts/lib" "$mock_bin" "$remote_shell_bin" \
  "$temporary_root/home" "$profiles_home"
cp -p -- "$PROJECT_ROOT/scripts/herdr_mcp.py" "$fake_root/scripts/herdr_mcp.py"
for helper in team json digest scope run-state; do
  cp -p -- "$PROJECT_ROOT/scripts/lib/$helper.sh" "$fake_root/scripts/lib/$helper.sh"
done

cat >"$fake_root/scripts/lib/scope.sh" <<'MOCK_SCOPE'
#!/usr/bin/env bash
scope_path_has_control() { return 1; }
scope_physical_dir() { printf '%s\n' "$1"; }
MOCK_SCOPE

cat >"$fake_root/scripts/start.sh" <<'MOCK_START'
#!/usr/bin/env bash
set -euo pipefail
printf 'start\n' >>"$MOCK_CALL_LOG"
for arg in "$@"; do printf '<%s>\n' "$arg" >>"$MOCK_CALL_LOG"; done
MOCK_START

cat >"$fake_root/scripts/doctor.sh" <<'MOCK_DOCTOR'
#!/usr/bin/env bash
set -euo pipefail
printf 'doctor\n' >>"$MOCK_CALL_LOG"
for arg in "$@"; do printf '<%s>\n' "$arg" >>"$MOCK_CALL_LOG"; done
[[ ${MOCK_DOCTOR_FAIL:-0} -eq 0 ]]
MOCK_DOCTOR

cat >"$fake_root/scripts/install.sh" <<'MOCK_INSTALL'
#!/usr/bin/env bash
set -euo pipefail
printf 'install\n' >>"$MOCK_CALL_LOG"
MOCK_INSTALL

cat >"$fake_root/scripts/open.sh" <<'MOCK_OPEN'
#!/usr/bin/env bash
set -euo pipefail
printf 'bootstrap-open\n' >>"$MOCK_CALL_LOG"
for arg in "$@"; do printf '<%s>\n' "$arg" >>"$MOCK_CALL_LOG"; done
MOCK_OPEN

cat >"$mock_bin/herdr" <<'MOCK_HERDR'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1-} == --remote ]]; then
  printf 'attach\n' >>"$MOCK_CALL_LOG"
  for arg in "$@"; do printf '<%s>\n' "$arg" >>"$MOCK_CALL_LOG"; done
  exit 0
fi
if [[ ${1-} == --version ]]; then
  if [[ ${MOCK_REMOTE:-0} -eq 1 ]]; then
    printf 'herdr %s\n' "${MOCK_REMOTE_HERDR_VERSION:-0.8.2}"
  else
    printf 'herdr %s\n' "${MOCK_LOCAL_HERDR_VERSION:-0.8.2}"
  fi
  exit 0
fi
case "${1-}:${2-}" in
  status:server)
    printf '<status-env:%s|%s|%s|%s>\n' \
      "${HERDR_SESSION:-}" "${HERDR_SOCKET_PATH:-}" \
      "${HERDR_CLIENT_SOCKET_PATH:-}" "${CODEX_HOME:-}" >>"$MOCK_CALL_LOG"
    if [[ ${3-} == --json ]]; then
      if [[ ${MOCK_SERVER_MODE:-running} == absent && \
            ! -e ${MOCK_SERVER_STATE:-/nonexistent/mock-server-state} ]]; then
        printf '{"status":"not_running","running":false,"version":null,"protocol":null,"capabilities":null,"compatible":null,"socket":"/tmp/mock","session":"%s","restart_needed":false}\n' \
          "${HERDR_SESSION:-}"
      else
        printf '{"status":"running","running":true,"version":"%s","protocol":8,"capabilities":{"live_handoff":true,"detached_server_daemon":%s},"compatible":%s,"socket":"/tmp/mock","session":"%s","restart_needed":false}\n' \
          "${MOCK_SERVER_VERSION:-${MOCK_REMOTE_HERDR_VERSION:-0.8.2}}" \
          "${MOCK_SERVER_DETACHED:-true}" "${MOCK_SERVER_COMPATIBLE:-true}" \
          "${MOCK_SERVER_SESSION:-${HERDR_SESSION:-}}"
      fi
    fi
    exit 0
    ;;
  remote-client-bridge:)
    printf 'remote-client-bridge\n' >>"$MOCK_CALL_LOG"
    : >"${MOCK_SERVER_STATE:?}"
    trap 'exit 0' TERM INT
    while :; do sleep 1; done
    ;;
  agent:list)
    case ${MOCK_AGENT_MODE:-none} in
      none) printf '%s\n' '{"result":{"type":"agent_list","agents":[]}}' ;;
      partial) printf '%s\n' '{"result":{"type":"agent_list","agents":[{"name":"demo-planner"}]}}' ;;
      full) printf '%s\n' '{"result":{"type":"agent_list","agents":[{"name":"demo-planner"},{"name":"demo-coder"},{"name":"demo-reviewer"}]}}' ;;
      other) printf '%s\n' '{"result":{"type":"agent_list","agents":[{"name":"another-agent"}]}}' ;;
      *) exit 2 ;;
    esac
    ;;
  agent:focus)
    printf '<focus:%s>\n' "${3-}" >>"$MOCK_CALL_LOG"
    ;;
  integration:status)
    if [[ ${MOCK_INTEGRATION_CURRENT:-1} -eq 1 || \
          -e ${MOCK_INTEGRATION_STATE:-/nonexistent/mock-integration-state} ]]; then
      printf 'codex: current\n'
    else
      printf 'codex: missing\n'
    fi
    ;;
  integration:install)
    printf 'integration-install\n' >>"$MOCK_CALL_LOG"
    [[ ${MOCK_INTEGRATION_INSTALL_FAIL:-0} -eq 0 ]] || exit 1
    if [[ -n ${MOCK_INTEGRATION_STATE:-} ]]; then
      : >"$MOCK_INTEGRATION_STATE"
    fi
    ;;
  *)
    printf 'Unexpected mock Herdr call: %s\n' "$*" >&2
    exit 2
    ;;
esac
MOCK_HERDR

cat >"$mock_bin/codex" <<'MOCK_CODEX'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1-} == --version ]]; then
  printf 'codex-cli 0.mock\n'
  exit 0
fi
exit 0
MOCK_CODEX

cat >"$remote_shell_bin/bash" <<'MOCK_REMOTE_BASH'
#!/bin/bash
set -euo pipefail
[[ ${1-} == -c && $# -ge 4 ]] || exit 2
shift 3
for arg in "$@"; do printf '<remote-arg:%s>\n' "$arg" >>"$MOCK_CALL_LOG"; done
tar -tf - >"$MOCK_ARCHIVE_LOG"
MOCK_REMOTE_BASH

cat >"$mock_bin/ssh" <<'MOCK_SSH'
#!/usr/bin/env bash
set -euo pipefail
[[ ${1-} == -T && $# -eq 3 ]] || exit 2
printf '<ssh-host:%s>\n' "$2" >>"$MOCK_CALL_LOG"
if [[ -n ${MOCK_SSH_FIRST_STATUS_FILE:-} && ! -e $MOCK_SSH_FIRST_STATUS_FILE ]]; then
  tar -tf - >/dev/null
  : >"$MOCK_SSH_FIRST_STATUS_FILE"
  exit "${MOCK_SSH_FIRST_STATUS:-12}"
fi
if [[ ${MOCK_SSH_EXECUTE:-0} -eq 1 ]]; then
  MOCK_REMOTE=1 /bin/bash -c "$3"
else
  PATH="$MOCK_REMOTE_SHELL_BIN:$PATH" /bin/bash -c "$3"
fi
MOCK_SSH

chmod +x "$fake_root/scripts/start.sh" "$fake_root/scripts/doctor.sh" \
  "$fake_root/scripts/install.sh" "$fake_root/scripts/open.sh" \
  "$mock_bin/herdr" "$mock_bin/codex" "$mock_bin/ssh" \
  "$remote_shell_bin/bash"
for role in planner coder reviewer; do
  : >"$profiles_home/$role.config.toml"
done
mkdir -p "$profiles_home/herdr-codex-team"
cp -p -- "$PROJECT_ROOT/scripts/herdr_mcp.py" \
  "$profiles_home/herdr-codex-team/herdr_mcp.py"

: >"$call_log"
env PATH="$mock_bin:$PATH" CODEX_HOME="$profiles_home" MOCK_CALL_LOG="$call_log" \
  HERDR_CODEX_TEAM_ROOT="$fake_root" MOCK_AGENT_MODE=none \
  "$PROJECT_ROOT/scripts/open.sh" --team demo --cwd /srv/project --add-dir '/srv/extra root' \
  >"$temporary_root/open-create.log"
grep -Fxq start "$call_log" || die 'open.sh did not create an absent team.'
grep -Fxq '</srv/extra root>' "$call_log" || die 'open.sh changed an --add-dir argument.'
grep -Fq 'TEAM_CREATED: demo' "$temporary_root/open-create.log" || \
  die 'open.sh did not report TEAM_CREATED.'

integration_state="$temporary_root/integration-state"
: >"$call_log"
if env PATH="$mock_bin:$PATH" CODEX_HOME="$profiles_home" MOCK_CALL_LOG="$call_log" \
     HERDR_CODEX_TEAM_ROOT="$fake_root" MOCK_AGENT_MODE=none \
     MOCK_INTEGRATION_CURRENT=0 MOCK_INTEGRATION_STATE="$integration_state" \
     "$PROJECT_ROOT/scripts/open.sh" --team demo --cwd /srv/project \
     >"$temporary_root/open-integration-required.log" 2>&1; then
  die 'open.sh installed a missing Herdr Codex integration without explicit approval.'
else
  integration_required_status=$?
fi
[[ $integration_required_status -eq 17 ]] || \
  die "Missing integration without approval returned status $integration_required_status: $(tr '\n' ' ' <"$temporary_root/open-integration-required.log")"
if grep -Eq '^(integration-install|install|start)$' "$call_log"; then
  die 'Missing integration caused configuration or Agent mutation before approval.'
fi
grep -Fq 'INTEGRATION_REQUIRED' "$temporary_root/open-integration-required.log" || \
  die 'open.sh omitted its stable integration-approval diagnostic.'

: >"$call_log"
env PATH="$mock_bin:$PATH" CODEX_HOME="$profiles_home" MOCK_CALL_LOG="$call_log" \
  HERDR_CODEX_TEAM_ROOT="$fake_root" MOCK_AGENT_MODE=none \
  MOCK_INTEGRATION_CURRENT=0 MOCK_INTEGRATION_STATE="$integration_state" \
  "$PROJECT_ROOT/scripts/open.sh" --install-integration --team demo --cwd /srv/project \
  >"$temporary_root/open-integration-install.log"
grep -Fxq integration-install "$call_log" || \
  die 'open.sh did not install a missing integration after explicit approval.'
grep -Fxq start "$call_log" || \
  die 'open.sh did not start after the Herdr Codex integration became current.'

failed_integration_state="$temporary_root/failed-integration-state"
: >"$call_log"
if env PATH="$mock_bin:$PATH" CODEX_HOME="$profiles_home" MOCK_CALL_LOG="$call_log" \
     HERDR_CODEX_TEAM_ROOT="$fake_root" MOCK_AGENT_MODE=none \
     MOCK_INTEGRATION_CURRENT=0 MOCK_INTEGRATION_STATE="$failed_integration_state" \
     MOCK_INTEGRATION_INSTALL_FAIL=1 \
     "$PROJECT_ROOT/scripts/open.sh" --install-integration --team demo --cwd /srv/project \
     >"$temporary_root/open-integration-failure.log" 2>&1; then
  die 'open.sh created a Team after integration installation failed.'
else
  integration_failure_status=$?
fi
[[ $integration_failure_status -eq 4 ]] || \
  die 'Integration installation failure returned the wrong status.'
if grep -Eq '^(install|start)$' "$call_log"; then
  die 'Integration installation failure reached profile or Agent mutation.'
fi

: >"$call_log"
if env PATH="$mock_bin:$PATH" CODEX_HOME="$profiles_home" MOCK_CALL_LOG="$call_log" \
     HERDR_CODEX_TEAM_ROOT="$fake_root" MOCK_AGENT_MODE=other \
     MOCK_INTEGRATION_CURRENT=0 \
     "$PROJECT_ROOT/scripts/open.sh" --install-integration --team demo --cwd /srv/project \
     >"$temporary_root/open-integration-live.log" 2>&1; then
  die 'open.sh changed integration while another Agent was live.'
else
  integration_live_status=$?
fi
[[ $integration_live_status -eq 4 ]] || \
  die 'Live-session integration installation returned the wrong status.'
if grep -Eq '^(integration-install|install|start|doctor)$' "$call_log"; then
  die 'Live-session integration approval modified or trusted the active session.'
fi

: >"$call_log"
missing_project="$temporary_root/does-not-exist"
if env PATH="$mock_bin:$PATH" CODEX_HOME="$profiles_home" MOCK_CALL_LOG="$call_log" \
     HERDR_CODEX_TEAM_ROOT="$PROJECT_ROOT" MOCK_AGENT_MODE=none \
     MOCK_INTEGRATION_CURRENT=0 \
     "$PROJECT_ROOT/scripts/open.sh" --install-integration --team demo \
     --cwd "$missing_project" >"$temporary_root/open-missing-project.log" 2>&1; then
  die 'open.sh accepted a missing project directory.'
else
  missing_project_status=$?
fi
[[ $missing_project_status -eq 2 ]] || \
  die 'Missing project validation returned the wrong status.'
[[ ! -s "$call_log" ]] || \
  die 'Missing project validation contacted Herdr or mutated global configuration.'

: >"$call_log"
env PATH="$mock_bin:$PATH" CODEX_HOME="$profiles_home" MOCK_CALL_LOG="$call_log" \
  HERDR_CODEX_TEAM_ROOT="$fake_root" MOCK_AGENT_MODE=full \
  "$PROJECT_ROOT/scripts/open.sh" --team demo --cwd /srv/project \
  >"$temporary_root/open-reuse.log"
grep -Fxq doctor "$call_log" || die 'open.sh did not verify a complete live team.'
grep -Fxq '<--bind-record-if-present>' "$call_log" || \
  die 'open.sh did not bind an existing launch record when checking reuse.'
grep -Fxq '<focus:demo-planner>' "$call_log" || die 'open.sh did not focus the reused Planner.'
if grep -Fxq start "$call_log"; then
  die 'open.sh restarted a complete live team.'
fi
grep -Fq 'TEAM_REUSED: demo' "$temporary_root/open-reuse.log" || \
  die 'open.sh did not report TEAM_REUSED.'

: >"$call_log"
if env PATH="$mock_bin:$PATH" CODEX_HOME="$profiles_home" MOCK_CALL_LOG="$call_log" \
     HERDR_CODEX_TEAM_ROOT="$fake_root" MOCK_AGENT_MODE=partial \
     "$PROJECT_ROOT/scripts/open.sh" --team demo --cwd /srv/project \
     >"$temporary_root/open-partial.log" 2>&1; then
  die 'open.sh accepted a partial live team.'
else
  partial_status=$?
fi
[[ $partial_status -eq 3 ]] || die 'open.sh returned the wrong partial-team status.'
if grep -Eq '^(start|doctor)$' "$call_log"; then
  die 'open.sh mutated or trusted a partial live team.'
fi
grep -Fq 'TEAM_PARTIAL' "$temporary_root/open-partial.log" || \
  die 'open.sh omitted the stable partial-team diagnostic.'

: >"$call_log"
if env PATH="$mock_bin:$PATH" CODEX_HOME="$profiles_home" MOCK_CALL_LOG="$call_log" \
     HERDR_CODEX_TEAM_ROOT="$fake_root" MOCK_AGENT_MODE=full MOCK_DOCTOR_FAIL=1 \
     "$PROJECT_ROOT/scripts/open.sh" --team demo --cwd /srv/project \
     >"$temporary_root/open-unsafe.log" 2>&1; then
  die 'open.sh accepted an unhealthy complete team.'
else
  unsafe_status=$?
fi
[[ $unsafe_status -eq 4 ]] || die 'open.sh returned the wrong unhealthy-team status.'
if grep -Fxq start "$call_log"; then
  die 'open.sh replaced an unhealthy complete team.'
fi
grep -Fq 'TEAM_UNSAFE' "$temporary_root/open-unsafe.log" || \
  die 'open.sh omitted the stable unhealthy-team diagnostic.'

empty_codex_home="$temporary_root/empty-codex-home"
mkdir -p "$empty_codex_home"
: >"$call_log"
env PATH="$mock_bin:$PATH" CODEX_HOME="$empty_codex_home" MOCK_CALL_LOG="$call_log" \
  HERDR_CODEX_TEAM_ROOT="$fake_root" MOCK_AGENT_MODE=none \
  "$PROJECT_ROOT/scripts/open.sh" --team demo --cwd /srv/project \
  >"$temporary_root/open-first-install.log"
grep -Fxq install "$call_log" || die 'open.sh did not install three wholly absent profiles.'
grep -Fxq start "$call_log" || die 'open.sh did not start after first profile installation.'

partial_codex_home="$temporary_root/partial-codex-home"
mkdir -p "$partial_codex_home"
: >"$partial_codex_home/planner.config.toml"
: >"$call_log"
if env PATH="$mock_bin:$PATH" CODEX_HOME="$partial_codex_home" MOCK_CALL_LOG="$call_log" \
     HERDR_CODEX_TEAM_ROOT="$fake_root" MOCK_AGENT_MODE=none \
     "$PROJECT_ROOT/scripts/open.sh" --team demo --cwd /srv/project \
     >"$temporary_root/open-partial-profiles.log" 2>&1; then
  die 'open.sh overwrote or accepted a partial profile installation.'
else
  partial_profile_status=$?
fi
[[ $partial_profile_status -eq 4 ]] || die 'open.sh returned the wrong partial-profile status.'
if grep -Eq '^(install|start)$' "$call_log"; then
  die 'open.sh mutated profiles or agents after finding a partial profile set.'
fi

: >"$call_log"
env PATH="$mock_bin:$PATH" CODEX_HOME="$partial_codex_home" MOCK_CALL_LOG="$call_log" \
  HERDR_CODEX_TEAM_ROOT="$fake_root" MOCK_AGENT_MODE=none \
  "$PROJECT_ROOT/scripts/open.sh" --repair-profiles --team demo --cwd /srv/project \
  >"$temporary_root/open-repair-profiles.log"
grep -Fxq install "$call_log" || \
  die 'open.sh did not run the backed-up explicit profile repair.'
grep -Fxq start "$call_log" || \
  die 'open.sh did not create the team after explicit profile repair.'
grep -Fq 'Explicit profile repair requested' "$temporary_root/open-repair-profiles.log" || \
  die 'open.sh did not report the explicit destructive-boundary decision.'

: >"$call_log"
if env PATH="$mock_bin:$PATH" CODEX_HOME="$profiles_home" MOCK_CALL_LOG="$call_log" \
     HERDR_CODEX_TEAM_ROOT="$fake_root" MOCK_AGENT_MODE=other \
     "$PROJECT_ROOT/scripts/open.sh" --repair-profiles --team demo --cwd /srv/project \
     >"$temporary_root/open-repair-live.log" 2>&1; then
  die 'open.sh repaired shared profiles while another Agent was live.'
else
  repair_live_status=$?
fi
[[ $repair_live_status -eq 4 ]] || die 'Live-session profile repair returned the wrong status.'
if grep -Eq '^(install|start|doctor)$' "$call_log"; then
  die 'Live-Team profile repair modified or trusted the active Team.'
fi

# Exercise remote bootstrap independently from the SSH quoting shim. The mock
# bridge marks the server ready and stays alive until bootstrap kills it.
server_state="$temporary_root/server-state"
: >"$call_log"
env PATH="$mock_bin:$PATH" HOME="$temporary_root/home" CODEX_HOME="$temporary_root/home/.codex" \
  MOCK_CALL_LOG="$call_log" MOCK_REMOTE=1 MOCK_SERVER_MODE=absent \
  MOCK_SERVER_STATE="$server_state" HERDR_CODEX_TEAM_ROOT="$fake_root" \
  HERDR_SOCKET_PATH=/tmp/wrong.sock HERDR_CLIENT_SOCKET_PATH=/tmp/wrong-client.sock \
  "$PROJECT_ROOT/scripts/lib/remote-bootstrap.sh" --team demo --cwd /srv/project \
  --herdr-version 0.8.2 --bundle-digest "$(printf 'a%.0s' {1..64})" \
  --repair-profiles --install-integration --add-dir '/srv/extra root' \
  >"$temporary_root/bootstrap.log"
grep -Fxq remote-client-bridge "$call_log" || \
  die 'remote bootstrap did not use Herdr remote-client-bridge for official daemon startup.'
grep -Fxq bootstrap-open "$call_log" || die 'remote bootstrap did not run open.sh after readiness.'
grep -Fxq '<--repair-profiles>' "$call_log" || \
  die 'remote bootstrap did not pass through explicit profile repair.'
grep -Fxq '<--install-integration>' "$call_log" || \
  die 'remote bootstrap did not pass through explicit integration approval.'
if grep -F '<status-env:' "$call_log" | grep -vF '<status-env:demo|||'; then
  die 'remote bootstrap retained a wrong session or socket override.'
fi

: >"$call_log"
if env PATH="$mock_bin:$PATH" HOME="$temporary_root/home" MOCK_CALL_LOG="$call_log" \
     MOCK_REMOTE=1 MOCK_REMOTE_HERDR_VERSION=0.8.2-preview.alpha \
     MOCK_SERVER_STATE="$server_state" HERDR_CODEX_TEAM_ROOT="$fake_root" \
     "$PROJECT_ROOT/scripts/lib/remote-bootstrap.sh" --team demo --cwd /srv/project \
     --herdr-version 0.8.2 --bundle-digest "$(printf 'b%.0s' {1..64})" \
     >"$temporary_root/bootstrap-preview-version.log" 2>&1; then
  die 'remote bootstrap treated stable and preview Herdr binaries as identical.'
else
  preview_status=$?
fi
[[ $preview_status -eq 16 ]] || die 'Preview binary mismatch returned the wrong status.'
if grep -Eq '^(bootstrap-open|remote-client-bridge)$' "$call_log"; then
  die 'Version mismatch reached server startup or Team operations.'
fi

: >"$call_log"
if env PATH="$mock_bin:$PATH" HOME="$temporary_root/home" MOCK_CALL_LOG="$call_log" \
     MOCK_REMOTE=1 MOCK_REMOTE_HERDR_VERSION=0.8.2-preview.alpha \
     MOCK_SERVER_VERSION=0.8.2-preview.beta MOCK_SERVER_STATE="$server_state" \
     HERDR_CODEX_TEAM_ROOT="$fake_root" \
     "$PROJECT_ROOT/scripts/lib/remote-bootstrap.sh" --team demo --cwd /srv/project \
     --herdr-version 0.8.2-preview.alpha --bundle-digest "$(printf 'c%.0s' {1..64})" \
     >"$temporary_root/bootstrap-server-version.log" 2>&1; then
  die 'remote bootstrap accepted a running server from a different preview build.'
else
  server_version_status=$?
fi
[[ $server_version_status -eq 16 ]] || die 'Running-server version mismatch returned the wrong status.'
if grep -Fxq bootstrap-open "$call_log"; then
  die 'Running-server version mismatch reached Team operations.'
fi

: >"$call_log"
if env PATH="$mock_bin:$PATH" HOME="$temporary_root/home" MOCK_CALL_LOG="$call_log" \
     MOCK_REMOTE=1 MOCK_SERVER_DETACHED=false MOCK_SERVER_STATE="$server_state" \
     HERDR_CODEX_TEAM_ROOT="$fake_root" \
     "$PROJECT_ROOT/scripts/lib/remote-bootstrap.sh" --team demo --cwd /srv/project \
     --herdr-version 0.8.2 --bundle-digest "$(printf 'd%.0s' {1..64})" \
     >"$temporary_root/bootstrap-detach.log" 2>&1; then
  die 'remote bootstrap accepted a server that is not an official detached daemon.'
else
  detached_status=$?
fi
[[ $detached_status -eq 16 ]] || die 'Detached-daemon mismatch returned the wrong status.'
if grep -Fxq bootstrap-open "$call_log"; then
  die 'Detached-daemon mismatch reached Team operations.'
fi

# The SSH wrapper streams the fixed current bundle in one call and passes all
# user values as quoted positional arguments. A mock inner Bash records those
# arguments without running the real remote driver.
: >"$call_log"
archive_log="$temporary_root/archive.log"
injection_marker="$temporary_root/remote-command-injected"
remote_project="/srv/project'; touch '$injection_marker'; printf '"
env PATH="$mock_bin:$PATH" HOME="$temporary_root/home" MOCK_CALL_LOG="$call_log" \
  MOCK_ARCHIVE_LOG="$archive_log" MOCK_REMOTE_SHELL_BIN="$remote_shell_bin" \
  "$PROJECT_ROOT/scripts/remote.sh" --host test-server --team demo \
  --repair-profiles --install-integration --cwd "$remote_project" \
  --add-dir '/srv/extra root' \
  >"$temporary_root/remote.log"
[[ ! -e "$injection_marker" ]] || die 'remote.sh allowed remote-shell command injection.'
[[ $(grep -Fc '<ssh-host:test-server>' "$call_log") -eq 1 ]] || \
  die 'remote.sh did not use one streamed preparation SSH call.'
grep -Fxq "<remote-arg:$remote_project>" "$call_log" || \
  die 'remote.sh changed the quoted remote cwd.'
grep -Fxq '<remote-arg:/srv/extra root>' "$call_log" || \
  die 'remote.sh changed a quoted remote --add-dir.'
grep -Fxq '<remote-arg:--repair-profiles>' "$call_log" || \
  die 'remote.sh did not pass through explicit profile repair.'
grep -Fxq '<remote-arg:--install-integration>' "$call_log" || \
  die 'remote.sh did not pass through explicit integration approval.'
grep -Fxq 'scripts/open.sh' "$archive_log" || die 'remote.sh did not stream open.sh.'
grep -Fxq 'scripts/herdr_mcp.py' "$archive_log" || \
  die 'remote.sh did not stream the Planner Herdr MCP bridge.'
grep -Fxq 'scripts/lib/remote-bootstrap.sh' "$archive_log" || \
  die 'remote.sh did not stream the remote bootstrap.'
grep -Fxq '<--remote>' "$call_log" || die 'remote.sh did not launch the local Herdr remote client.'
grep -Fxq '<test-server>' "$call_log" || die 'remote.sh changed the Herdr SSH target.'
grep -Fxq '<--session>' "$call_log" || die 'remote.sh omitted the named Herdr session.'

: >"$call_log"
first_status_file="$temporary_root/ssh-first-status"
env PATH="$mock_bin:$PATH" HOME="$temporary_root/home" MOCK_CALL_LOG="$call_log" \
  MOCK_ARCHIVE_LOG="$archive_log" MOCK_REMOTE_SHELL_BIN="$remote_shell_bin" \
  MOCK_SSH_FIRST_STATUS_FILE="$first_status_file" \
  "$PROJECT_ROOT/scripts/remote.sh" --host test-server --team demo --cwd /srv/project \
  >"$temporary_root/remote-first-setup.log"
[[ $(grep -Fc '<ssh-host:test-server>' "$call_log") -eq 2 ]] || \
  die 'remote.sh did not retry preparation after first-time Herdr setup.'
[[ $(grep -c '^attach$' "$call_log") -eq 2 ]] || \
  die 'remote.sh did not open one setup UI and then the final local Team UI.'
[[ $(grep -Fc '<--handoff>' "$call_log") -eq 1 ]] || \
  die 'remote.sh did not request live handoff for the setup/update attach only.'
grep -Fq 'continue automatically' "$temporary_root/remote-first-setup.log" || \
  die 'remote.sh did not explain the one-command first-time setup flow.'

: >"$call_log"
integration_first_status_file="$temporary_root/ssh-integration-first-status"
printf 'y\n' | env PATH="$mock_bin:$PATH" HOME="$temporary_root/home" \
  MOCK_CALL_LOG="$call_log" MOCK_ARCHIVE_LOG="$archive_log" \
  MOCK_REMOTE_SHELL_BIN="$remote_shell_bin" \
  MOCK_SSH_FIRST_STATUS_FILE="$integration_first_status_file" \
  MOCK_SSH_FIRST_STATUS=17 \
  "$PROJECT_ROOT/scripts/remote.sh" --host test-server --team demo --cwd /srv/project \
  >"$temporary_root/remote-integration-approval.log"
[[ $(grep -Fc '<ssh-host:test-server>' "$call_log") -eq 2 ]] || \
  die 'remote.sh did not retry preparation after integration approval.'
[[ $(grep -Fc '<remote-arg:--install-integration>' "$call_log") -eq 1 ]] || \
  die 'remote.sh did not add explicit integration approval to the retry.'
[[ $(grep -c '^attach$' "$call_log") -eq 1 ]] || \
  die 'remote.sh did not open exactly one final UI after integration approval.'
grep -Fq 'Retrying Team preparation with explicit integration-install approval' \
  "$temporary_root/remote-integration-approval.log" || \
  die 'remote.sh did not explain its approved integration retry.'

remote_home="$temporary_root/driver-home"
remote_tmp="$temporary_root/driver-tmp"
remote_project_dir="$temporary_root/driver-project"
mkdir -p "$remote_home/.codex" "$remote_tmp" "$remote_project_dir"
: >"$remote_home/.codex/planner.config.toml"
: >"$call_log"
if env PATH="$mock_bin:$PATH" HOME="$remote_home" TMPDIR="$remote_tmp" \
     MOCK_CALL_LOG="$call_log" MOCK_REMOTE_SHELL_BIN="$remote_shell_bin" \
     MOCK_SSH_EXECUTE=1 TEAM_PREFIX=wrong CODEX_HOME=/wrong/codex-home \
     HERDR_CODEX_TEAM_ROOT=/wrong/helper HERDR_SOCKET_PATH=/tmp/wrong.sock \
     HERDR_CLIENT_SOCKET_PATH=/tmp/wrong-client.sock \
     "$PROJECT_ROOT/scripts/remote.sh" --host test-server --team demo --cwd "$remote_project_dir" \
     >"$temporary_root/remote-driver.log" 2>&1; then
  die 'remote.sh unexpectedly accepted a partial remote profile set.'
else
  driver_status=$?
fi
[[ $driver_status -eq 4 ]] || die 'Streamed remote-driver failure returned the wrong status.'
grep -Fq 'found 1 of 3 managed Codex profile paths' "$temporary_root/remote-driver.log" || \
  die 'The streamed current open.sh did not run inside the remote driver.'
if grep -F '<status-env:' "$call_log" | grep -vF "<status-env:demo|||$remote_home/.codex>"; then
  die 'The streamed driver retained inherited session, socket, or CODEX_HOME overrides.'
fi
if find "$remote_tmp" -mindepth 1 -print -quit | grep -q .; then
  die 'The streamed driver did not clean its private temporary runtime.'
fi

printf '[OK] Remote launcher streams current policy, preserves identity, and fails closed\n'
