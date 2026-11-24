#!/usr/bin/env bash

# Portable prompt-integrity helpers shared by install, start, and doctor.

sha256_stream() {
  local digest

  if command -v shasum >/dev/null 2>&1; then
    digest=$(shasum -a 256 | awk 'NR == 1 { print $1 }') || return
  elif command -v sha256sum >/dev/null 2>&1; then
    digest=$(sha256sum | awk 'NR == 1 { print $1 }') || return
  elif command -v openssl >/dev/null 2>&1; then
    digest=$(openssl dgst -sha256 | sed 's/^.*= //') || return
  else
    return 127
  fi
  [[ ${#digest} -eq 64 && "$digest" != *[!0-9a-f]* ]] || return 2
  printf '%s\n' "$digest"
}

render_codex_role_instructions() {
  local prompt=$1
  local skill="${prompt%/*}/stop-that-shit/SKILL.md"
  local mode
  case "${prompt##*/}" in
    planner.md) mode="Use the task mode that matches the user's request." ;;
    coder.md) mode="Use change mode for authorized implementation." ;;
    reviewer.md) mode="Use review mode for implementation reviews." ;;
    *) return 2 ;;
  esac
  [[ -s "$prompt" && -s "$skill" ]] || return 2
  if grep -Fq "'''" "$prompt" "$skill"; then
    printf 'Role instructions contain the closing TOML delimiter.\n' >&2
    return 2
  fi
  command cat -- "$prompt" &&
    printf '\nApply the embedded Stop That Shit skill on every task. %s\n\n' "$mode" &&
    command cat -- "$skill" && printf '\n'
}

prompt_payload_sha256() {
  render_codex_role_instructions "$1" | sha256_stream
}

# Resolve the interpreter selected by the user's current trusted startup
# environment to one absolute executable. Installed Planner MCP configuration
# records this exact path, so the later sandbox-external launch never searches
# PATH. Callers must rerun install.sh when the interpreter path changes.
managed_python_executable() {
  command -v python3 >/dev/null 2>&1 || return 127
  python3 -c '
import os
import stat
import sys

path = os.path.realpath(sys.executable)
if (not os.path.isabs(path) or not path or
        any(ord(character) < 32 or 127 <= ord(character) <= 159
            for character in path)):
    raise SystemExit(2)
metadata = os.stat(path)
if not stat.S_ISREG(metadata.st_mode) or not os.access(path, os.X_OK):
    raise SystemExit(2)
print(path)
' 2>/dev/null
}

# Resolve another command selected by the trusted startup environment to one
# absolute executable, using the already-pinned Python interpreter for portable
# realpath and file-type checks.
managed_command_executable() {
  local command_name=${1-}
  local python_path=${2-}
  local candidate

  [[ "$command_name" =~ ^[A-Za-z0-9._+-]+$ && -x "$python_path" ]] || return 2
  candidate=$(command -v -- "$command_name") || return 127
  "$python_path" -c '
import os
import stat
import sys

path = os.path.realpath(sys.argv[1])
if (not os.path.isabs(path) or not path or
        any(ord(character) < 32 or 127 <= ord(character) <= 159
            for character in path)):
    raise SystemExit(2)
metadata = os.stat(path)
if not stat.S_ISREG(metadata.st_mode) or not os.access(path, os.X_OK):
    raise SystemExit(2)
print(path)
' "$candidate" 2>/dev/null
}

# Render the two host-specific Planner MCP paths while leaving every other
# profile-policy byte unchanged. Python's JSON strings are valid TOML basic
# strings and safely preserve spaces, Unicode, quotes, and backslashes.
profile_policy_render() {
  local template=${1-}
  local python_path=${2-}
  local bridge_path=${3-}

  [[ -f "$template" ]] || return 2
  if ! grep -Fq '__HERDR_CODEX_TEAM_PYTHON__' "$template" &&
     ! grep -Fq '__HERDR_CODEX_TEAM_BRIDGE__' "$template"; then
    command cat -- "$template"
    return
  fi
  [[ -n "$python_path" && -n "$bridge_path" ]] || return 2
  "$python_path" -c '
import json
import os
import sys

python_path, bridge_path = sys.argv[1:]
for value in (python_path, bridge_path):
    if (not os.path.isabs(value) or not value or
            any(ord(character) < 32 or 127 <= ord(character) <= 159
                for character in value)):
        raise SystemExit(2)
text = sys.stdin.read()
python_marker = "\"__HERDR_CODEX_TEAM_PYTHON__\""
bridge_marker = "\"__HERDR_CODEX_TEAM_BRIDGE__\""
if not text.count(python_marker) or text.count(python_marker) != text.count(bridge_marker):
    raise SystemExit(2)
text = text.replace(python_marker, json.dumps(python_path, ensure_ascii=False))
text = text.replace(bridge_marker, json.dumps(bridge_path, ensure_ascii=False))
sys.stdout.write(text)
' "$python_path" "$bridge_path" <"$template"
}

profile_marker_sha256() {
  local profile=${1-}
  local prefix=${2-}
  awk -v prefix="$prefix" '
    BEGIN { count = 0; invalid = 0 }
    index($0, prefix) == 1 {
      count++
      value = substr($0, length(prefix) + 1)
      if (length(value) != 64 || value ~ /[^0-9a-f]/) invalid = 1
    }
    END {
      if (count != 1 || invalid) exit 2
      print value
    }
  ' "$profile"
}

profile_prompt_marker_sha256() {
  profile_marker_sha256 "${1-}" '# herdr-prompt-sha256: '
}

profile_embedded_prompt_sha256() {
  local profile=${1-}
  awk -v opener="developer_instructions = '''" -v closer="'''" '
    BEGIN { state = 0; starts = 0; closes = 0; invalid = 0 }
    $0 == opener {
      starts++
      if (starts != 1 || state != 0) invalid = 1
      state = 1
      next
    }
    state == 1 && $0 == closer {
      closes++
      state = 2
      next
    }
    state == 1 { print }
    END {
      if (invalid || starts != 1 || closes != 1 || state != 2) exit 2
    }
  ' "$profile" | sha256_stream
}

# The installed model may be selected independently, so model assignments are
# the only template lines intentionally excluded from the managed policy hash.
profile_policy_source_sha256() {
  local template=${1-}
  local python_path=${2-}
  local bridge_path=${3-}
  [[ -f "$template" ]] || return 2
  {
    profile_policy_render "$template" "$python_path" "$bridge_path" |
      sed '/^[[:space:]]*model[[:space:]]*=/d'
    printf '\n'
  } | sha256_stream
}

profile_policy_marker_sha256() {
  profile_marker_sha256 "${1-}" '# herdr-profile-policy-sha256: '
}

profile_installed_policy_sha256() {
  local profile=${1-}
  awk -v opener="developer_instructions = '''" -v closer="'''" '
    BEGIN { state = 0; starts = 0; closes = 0; invalid = 0 }
    $0 == opener {
      starts++
      if (starts != 1 || state != 0) invalid = 1
      state = 1
      next
    }
    state == 1 && $0 == closer {
      closes++
      state = 2
      next
    }
    state == 1 { next }
    # Native Codex writes notice counters and user-confirmed folder trust below
    # the managed prompt. Keep all other fields in the policy hash.
    state == 2 && $0 == "[tui.model_availability_nux]" { blanks = 0; native = "notices"; next }
    state == 2 && /^\[projects\."([^"\\]|\\.)+"\]$/ { blanks = 0; native = "trust"; next }
    native == "notices" && /^[[:space:]]*("[[:alnum:]_.-]+"|[[:alnum:]_-]+)[[:space:]]*=[[:space:]]*[0-9]+[[:space:]]*$/ { next }
    native == "trust" && /^[[:space:]]*trust_level[[:space:]]*=[[:space:]]*"(trusted|untrusted)"[[:space:]]*$/ { next }
    state == 2 && $0 == "" { if (!native) blanks++; next }
    state == 2 {
      while (blanks > 0) { print ""; blanks-- }
      native = ""
    }
    $0 == "# Installed by herdr-codex-team. Edit the source template and rerun install.sh." { next }
    index($0, "# herdr-prompt-sha256: ") == 1 { next }
    index($0, "# herdr-profile-policy-sha256: ") == 1 { next }
    /^[[:space:]]*model[[:space:]]*=/ { next }
    { print }
    END {
      while (blanks > 0) { print ""; blanks-- }
      if (invalid || starts != 1 || closes != 1 || state != 2) exit 2
    }
  ' "$profile" | sha256_stream
}

# Print a stable diagnostic and return non-zero on any integrity failure.
profile_prompt_integrity() {
  local profile=${1-}
  local source_prompt=${2-}
  local expected
  local marker
  local embedded

  if ! expected=$(prompt_payload_sha256 "$source_prompt"); then
    printf '%s' 'source prompt digest unavailable'
    return 1
  fi
  if ! marker=$(profile_prompt_marker_sha256 "$profile"); then
    printf '%s' 'installed prompt marker missing or invalid'
    return 1
  fi
  if ! embedded=$(profile_embedded_prompt_sha256 "$profile"); then
    printf '%s' 'installed developer_instructions block missing or invalid'
    return 1
  fi
  if [[ "$marker" != "$expected" || "$embedded" != "$expected" ]]; then
    printf '%s' 'installed prompt digest mismatch'
    return 1
  fi
}

profile_policy_integrity() {
  local profile=${1-}
  local source_template=${2-}
  local python_path=${3-}
  local bridge_path=${4-}
  local expected
  local marker
  local installed

  if ! expected=$(profile_policy_source_sha256 \
       "$source_template" "$python_path" "$bridge_path"); then
    printf '%s' 'source profile policy digest unavailable'
    return 1
  fi
  if ! marker=$(profile_policy_marker_sha256 "$profile"); then
    printf '%s' 'installed profile policy marker missing or invalid'
    return 1
  fi
  if ! installed=$(profile_installed_policy_sha256 "$profile"); then
    printf '%s' 'installed profile policy block missing or invalid'
    return 1
  fi
  if [[ "$marker" != "$expected" || "$installed" != "$expected" ]]; then
    printf '%s' 'installed profile policy digest mismatch'
    return 1
  fi
}

# The Planner-only stdio bridge is executable policy, not a user-editable
# profile override. Require an exact regular-file copy of the repository source
# before start/doctor may trust it.
managed_bridge_integrity() {
  local installed=${1-}
  local source_bridge=${2-}
  local installed_dir
  local expected
  local actual
  local marker='# Managed by herdr-codex-team. Edit this source file and rerun scripts/install.sh.'

  if [[ ! -f "$source_bridge" || -L "$source_bridge" ]]; then
    printf '%s' 'source Herdr MCP bridge is missing or unsafe'
    return 1
  fi
  installed_dir=${installed%/*}
  if [[ -z "$installed_dir" || "$installed_dir" == "$installed" || \
        ! -d "$installed_dir" || -L "$installed_dir" ]]; then
    printf '%s' 'installed Herdr MCP bridge parent is missing or unsafe'
    return 1
  fi
  if [[ ! -f "$installed" || -L "$installed" || ! -O "$installed" ]]; then
    printf '%s' 'installed Herdr MCP bridge is missing or unsafe'
    return 1
  fi
  if ! grep -Fxq "$marker" "$source_bridge" || ! grep -Fxq "$marker" "$installed"; then
    printf '%s' 'Herdr MCP bridge marker is missing'
    return 1
  fi
  if ! expected=$(sha256_stream <"$source_bridge") || ! actual=$(sha256_stream <"$installed"); then
    printf '%s' 'Herdr MCP bridge digest unavailable'
    return 1
  fi
  if [[ "$actual" != "$expected" ]]; then
    printf '%s' 'installed Herdr MCP bridge digest mismatch'
    return 1
  fi
}
