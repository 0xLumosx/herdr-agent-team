#!/usr/bin/env bash

set -euo pipefail

CODEX_DIR=${CODEX_HOME:-"$HOME/.codex"}
case "$CODEX_DIR" in
  /*) ;;
  *) CODEX_DIR="$PWD/$CODEX_DIR" ;;
esac
if [[ -d "$CODEX_DIR" ]]; then
  CODEX_DIR=$(CDPATH= cd -- "$CODEX_DIR" && pwd -P)
fi
export CODEX_HOME="$CODEX_DIR"
failures=0
warnings=0

ok() {
  printf '[OK] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*"
  warnings=$((warnings + 1))
}

fail() {
  printf '[FAIL] %s\n' "$*"
  failures=$((failures + 1))
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

printf 'Herdr Codex Team doctor\n\n'

if command -v codex >/dev/null 2>&1; then
  ok "Codex found: $(codex --version 2>&1 | head -n 1)"
else
  fail 'Codex not found. Install Codex CLI and make sure `codex` is in PATH.'
fi

if command -v herdr >/dev/null 2>&1; then
  ok "Herdr found: $(herdr --version 2>&1 | head -n 1)"
else
  fail 'Herdr not found. Install Herdr and make sure `herdr` is in PATH.'
fi

for role in planner coder reviewer; do
  profile="$CODEX_DIR/$role.config.toml"
  if [[ -f "$profile" ]]; then
    ok "$role profile: $profile"
  else
    fail "$role profile not found at $profile. Run ./scripts/install.sh."
    continue
  fi

  if ! grep -Eq '^approval_policy[[:space:]]*=[[:space:]]*"never"[[:space:]]*$' "$profile"; then
    fail "$role profile does not set approval_policy = \"never\"."
  fi
  if ! grep -Eq '^developer_instructions[[:space:]]*=' "$profile"; then
    fail "$role profile has no installed developer_instructions. Rerun ./scripts/install.sh."
  fi
  if command -v codex >/dev/null 2>&1; then
    if codex --profile "$role" debug prompt-input 'profile validation' >/dev/null 2>&1; then
      ok "$role profile loads in Codex"
    else
      fail "$role profile cannot be loaded by Codex. Restore a backup or rerun ./scripts/install.sh."
    fi
  fi
done

if [[ -f "$CODEX_DIR/planner.config.toml" ]] && \
   ! grep -Eq '^sandbox_mode[[:space:]]*=[[:space:]]*"workspace-write"[[:space:]]*$' "$CODEX_DIR/planner.config.toml"; then
  fail 'planner profile must use sandbox_mode = "workspace-write" for Herdr communication.'
fi
if [[ -f "$CODEX_DIR/coder.config.toml" ]] && \
   ! grep -Eq '^sandbox_mode[[:space:]]*=[[:space:]]*"workspace-write"[[:space:]]*$' "$CODEX_DIR/coder.config.toml"; then
  fail 'coder profile must use sandbox_mode = "workspace-write".'
fi
if [[ -f "$CODEX_DIR/reviewer.config.toml" ]] && \
   ! grep -Eq '^sandbox_mode[[:space:]]*=[[:space:]]*"read-only"[[:space:]]*$' "$CODEX_DIR/reviewer.config.toml"; then
  fail 'reviewer profile must use sandbox_mode = "read-only".'
fi

if ! command -v herdr >/dev/null 2>&1; then
  printf '\nEnvironment is not healthy: %s failure(s), %s warning(s).\n' "$failures" "$warnings"
  exit 1
fi

if herdr agent start --help >/dev/null 2>&1 && \
   herdr agent prompt --help >/dev/null 2>&1 && \
   herdr agent get --help >/dev/null 2>&1 && \
   herdr agent list --help >/dev/null 2>&1 && \
   herdr agent read --help >/dev/null 2>&1 && \
   herdr agent wait --help >/dev/null 2>&1 && \
   herdr agent rename --help >/dev/null 2>&1 && \
   herdr pane process-info --help >/dev/null 2>&1 && \
   herdr pane split --help >/dev/null 2>&1 && \
   herdr pane rename --help >/dev/null 2>&1 && \
   herdr workspace create --help >/dev/null 2>&1; then
  ok 'Required Herdr command surface is available.'
else
  fail 'Installed Herdr lacks commands required by this project. Compare with the verified 0.8.2 command surface.'
fi

integration_status=$(herdr integration status 2>&1 || true)
if printf '%s\n' "$integration_status" | grep -Eq '^codex: current([[:space:]]|$)'; then
  ok 'Herdr Codex integration is current.'
else
  fail 'Herdr Codex integration is missing or outdated. Review `herdr integration status`, then run `herdr integration install codex` if appropriate.'
fi

server_running=0
if server_status=$(herdr status server 2>&1); then
  server_running=1
  ok 'Herdr server is running.'
else
  fail 'Herdr server is not reachable. Start or attach Herdr with `herdr`, then rerun doctor.sh.'
  printf '       Herdr response: %s\n' "$server_status"
fi

if [[ $server_running -eq 1 ]]; then
  printf '\nExpected agents:\n'
  for role in planner coder reviewer; do
    if agent_payload=$(herdr agent get "$role" 2>&1); then
      live_name=$(extract_agent_field "$agent_payload" name)
      state=$(extract_agent_field "$agent_payload" agent_status)
      agent_kind=$(extract_agent_field "$agent_payload" agent)
      interactive_ready=$(extract_agent_field "$agent_payload" interactive_ready)
      launch_pending=$(extract_agent_field "$agent_payload" launch_pending)
      pane_id=$(extract_agent_field "$agent_payload" pane_id)
      if [[ "$live_name" != "$role" ]]; then
        fail "$role target resolved to unexpected live name '${live_name:-unknown}'."
        continue
      fi
      if [[ "$agent_kind" != 'codex' ]]; then
        fail "$role name resolves to agent kind '${agent_kind:-unknown}', not codex."
        continue
      fi
      if [[ -z "$pane_id" ]]; then
        fail "$role did not expose a pane ID, so its active profile cannot be verified."
      elif process_payload=$(herdr pane process-info --pane "$pane_id" 2>&1); then
        if process_uses_profile "$process_payload" "$role"; then
          ok "$role foreground process uses --profile $role"
        else
          fail "$role is not verifiably running with --profile $role. Restart it through start.sh."
        fi
      else
        fail "$role foreground process could not be inspected: $process_payload"
      fi
      if [[ "$launch_pending" == 'true' ]]; then
        fail "$role agent launch is still pending. Inspect with: herdr agent get $role"
        continue
      fi
      case "$state" in
        idle|done)
          if [[ "$interactive_ready" == 'true' ]]; then
            ok "$role agent found (state: $state, ready: true)"
          else
            fail "$role agent is $state but not interactively ready. Inspect its pane."
          fi
          ;;
        working)
          warn "$role agent is currently working. Wait for it to settle before running communication tests."
          ;;
        blocked)
          fail "$role agent is blocked. Read its pane and let the user resolve the approval or question."
          ;;
        unknown|'')
          fail "$role agent lifecycle state is '${state:-unknown}'; completion is not verified."
          ;;
        *)
          fail "$role agent reported unsupported lifecycle state '$state'."
          ;;
      esac
    else
      fail "$role agent not found. Run ./scripts/start.sh /path/to/project."
    fi
  done

  printf '\nCurrent Herdr agent list:\n'
  herdr agent list 2>&1 || fail 'Unable to read the current Herdr agent list.'
else
  for role in planner coder reviewer; do
    fail "$role agent could not be checked while the Herdr server is unavailable."
  done
fi

printf '\n'
if [[ $failures -eq 0 ]]; then
  printf 'Environment looks healthy. %s warning(s).\n' "$warnings"
  exit 0
fi

printf 'Environment is not healthy: %s failure(s), %s warning(s).\n' "$failures" "$warnings"
exit 1
