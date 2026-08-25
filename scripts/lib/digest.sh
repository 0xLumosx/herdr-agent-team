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

# install.sh embeds the source prompt plus one separator newline before the
# closing TOML delimiter. Hash that exact payload, not merely the source file.
prompt_payload_sha256() {
  local prompt=${1-}
  [[ -f "$prompt" ]] || return 2
  { command cat -- "$prompt"; printf '\n'; } | sha256_stream
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
  [[ -f "$template" ]] || return 2
  {
    sed '/^[[:space:]]*model[[:space:]]*=/d' "$template"
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
    $0 == "# Installed by herdr-codex-team. Edit the source template and rerun install.sh." { next }
    index($0, "# herdr-prompt-sha256: ") == 1 { next }
    index($0, "# herdr-profile-policy-sha256: ") == 1 { next }
    /^[[:space:]]*model[[:space:]]*=/ { next }
    { print }
    END {
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
  local expected
  local marker
  local installed

  if ! expected=$(profile_policy_source_sha256 "$source_template"); then
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
