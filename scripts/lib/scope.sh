#!/usr/bin/env bash

# Shared physical-path and workspace-scope helpers. These functions are kept
# compatible with macOS Bash 3.2: callers use indexed arrays and explicit loops.

scope_path_has_control() {
  local path=$1

  case "$path" in
    *$'\n'*|*$'\r'*) return 0 ;;
  esac
  if printf '%s' "$path" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    return 0
  fi
  # In a C locale, POSIX cntrl does not match UTF-8 encodings of the C1
  # control range U+0080..U+009F (C2 80..9F). Reject that sequence explicitly
  # without rejecting ordinary UTF-8 continuation bytes in non-ASCII names.
  if printf '%s' "$path" | LC_ALL=C grep -q $'\302[\200-\237]'; then
    return 0
  fi
  return 1
}

scope_physical_dir() {
  local path=$1
  local resolved
  local sentinel=$'\034'

  [[ -n "$path" ]] || return 1
  scope_path_has_control "$path" && return 2
  [[ -d "$path" ]] || return 1
  resolved=$(
    CDPATH= cd -P -- "$path" || exit 1
    printf '%s%s' "$PWD" "$sentinel"
  ) || return 1
  case "$resolved" in
    *"$sentinel") resolved=${resolved%"$sentinel"} ;;
    *) return 1 ;;
  esac
  scope_path_has_control "$resolved" && return 2
  printf '%s\n' "$resolved"
}

scope_git_root() {
  local path=$1
  local physical_path
  local git_record
  local git_output
  local git_status
  local git_root
  local sentinel=$'\034'

  command -v git >/dev/null 2>&1 || return 2
  physical_path=$(scope_physical_dir "$path") || return 2
  if git_record=$(
    git_status=0
    env \
      -u GIT_DIR \
      -u GIT_WORK_TREE \
      -u GIT_COMMON_DIR \
      -u GIT_CEILING_DIRECTORIES \
      -u GIT_INDEX_FILE \
      -u GIT_OBJECT_DIRECTORY \
      -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
      GIT_DISCOVERY_ACROSS_FILESYSTEM=1 \
      LC_ALL=C git -C "$physical_path" rev-parse --show-toplevel 2>&1 || git_status=$?
    printf '%s' "$sentinel"
    exit "$git_status"
  ); then
    git_status=0
  else
    git_status=$?
  fi
  case "$git_record" in
    *"$sentinel") git_record=${git_record%"$sentinel"} ;;
    *) return 2 ;;
  esac
  # rev-parse emits one LF record terminator. Remove exactly that terminator;
  # any remaining newline belongs to the path/diagnostic and is unsafe.
  case "$git_record" in
    *$'\n') git_output=${git_record%$'\n'} ;;
    *) return 2 ;;
  esac
  if [[ $git_status -ne 0 ]]; then
    case "$git_output" in
      'fatal: not a git repository (or any of the parent directories): .git') return 1 ;;
      *) return 2 ;;
    esac
  fi
  scope_path_has_control "$git_output" && return 2
  git_root=$(scope_physical_dir "$git_output") || return 2
  [[ "$git_root" != '/' ]] || return 2
  scope_is_same_or_descendant "$physical_path" "$git_root" || return 2
  printf '%s\n' "$git_root"
}

# A Git-backed path is governed at the physical worktree root. A non-Git path
# is governed at the physical directory itself.
scope_effective_root() {
  local path=$1
  local git_root
  local git_status

  if git_root=$(scope_git_root "$path"); then
    printf '%s\n' "$git_root"
  else
    git_status=$?
    [[ $git_status -eq 1 ]] || return "$git_status"
    printf '%s\n' "$path"
  fi
}

scope_is_same_or_descendant() {
  local child=$1
  local ancestor=$2
  local current=$child
  local parent

  while :; do
    [[ "$current" -ef "$ancestor" ]] && return 0
    [[ "$current" == '/' ]] && break
    parent=${current%/*}
    [[ -n "$parent" ]] || parent='/'
    [[ "$parent" != "$current" ]] || break
    current=$parent
  done
  return 1
}

scope_paths_overlap() {
  local left=$1
  local right=$2

  scope_is_same_or_descendant "$left" "$right" || \
    scope_is_same_or_descendant "$right" "$left"
}
