#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
DIGEST_LIB="$SCRIPT_DIR/lib/digest.sh"
[[ -f "$DIGEST_LIB" ]] || {
  printf '[FAIL] Missing script helper: %s\n' "$DIGEST_LIB" >&2
  exit 1
}
# shellcheck source=lib/digest.sh
source "$DIGEST_LIB"
CODEX_DIR=${CODEX_HOME:-"$HOME/.codex"}
case "$CODEX_DIR" in
  /*) ;;
  *) CODEX_DIR="$PWD/$CODEX_DIR" ;;
esac
render_dir=''

cleanup_render_dir() {
  [[ -n "$render_dir" && -d "$render_dir" ]] || return 0
  case "$render_dir" in
    "$CODEX_DIR"/.herdr-codex-team-render.*) rm -rf -- "$render_dir" ;;
    *) printf '[WARN] Refusing to clean unexpected render path: %s\n' "$render_dir" >&2 ;;
  esac
}
trap cleanup_render_dir EXIT

usage() {
  printf '%s\n' \
    'Usage: ./scripts/install.sh' \
    '' \
    'Installs planner, coder, and reviewer profiles into $CODEX_HOME.' \
    'Optional model overrides at install time:' \
    '  PLANNER_MODEL=... CODER_MODEL=... REVIEWER_MODEL=... ./scripts/install.sh'
}

die() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

if [[ ${1:-} == "--help" || ${1:-} == "-h" ]]; then
  usage
  exit 0
fi

if [[ $# -ne 0 ]]; then
  usage >&2
  exit 2
fi

command -v codex >/dev/null 2>&1 || die 'Codex CLI was not found in PATH.'
command -v herdr >/dev/null 2>&1 || die 'Herdr was not found in PATH.'

for role in planner coder reviewer; do
  [[ -f "$PROJECT_ROOT/profiles/$role.config.toml" ]] || \
    die "Missing profile template: profiles/$role.config.toml"
  [[ -f "$PROJECT_ROOT/prompts/$role.md" ]] || \
    die "Missing role prompt: prompts/$role.md"
  if grep -Fq "'''" "$PROJECT_ROOT/prompts/$role.md"; then
    die "prompts/$role.md contains three consecutive single quotes and cannot be embedded safely in TOML."
  fi
done

if [[ ! -d "$CODEX_DIR" ]]; then
  mkdir -p -- "$CODEX_DIR"
  chmod 700 "$CODEX_DIR" 2>/dev/null || true
  printf '[OK] Created Codex home: %s\n' "$CODEX_DIR"
fi
CODEX_DIR=$(CDPATH= cd -- "$CODEX_DIR" && pwd -P)
export CODEX_HOME="$CODEX_DIR"

printf '[OK] Codex found: %s\n' "$(codex --version 2>&1 | head -n 1)"
printf '[OK] Herdr found: %s\n' "$(herdr --version 2>&1 | head -n 1)"

timestamp=$(date '+%Y%m%d-%H%M%S')
backup_dir="$CODEX_DIR/herdr-codex-team-backup-$timestamp"
if [[ -e "$backup_dir" ]]; then
  backup_dir="$backup_dir-$$"
fi

backup_needed=0
for role in planner coder reviewer; do
  if [[ -e "$CODEX_DIR/$role.config.toml" ]]; then
    backup_needed=1
  fi
done

if [[ $backup_needed -eq 1 ]]; then
  mkdir -p -- "$backup_dir"
  chmod 700 "$backup_dir" 2>/dev/null || true
  for role in planner coder reviewer; do
    if [[ -e "$CODEX_DIR/$role.config.toml" ]]; then
      cp -p -- "$CODEX_DIR/$role.config.toml" "$backup_dir/$role.config.toml"
      printf '[OK] Backed up %s.config.toml\n' "$role"
    fi
  done
  printf '[OK] Backup directory: %s\n' "$backup_dir"
else
  printf '[OK] No existing team profiles need backup.\n'
fi

model_for_role() {
  case "$1" in
    planner) printf '%s' "${PLANNER_MODEL:-}" ;;
    coder) printf '%s' "${CODER_MODEL:-}" ;;
    reviewer) printf '%s' "${REVIEWER_MODEL:-}" ;;
    *) return 1 ;;
  esac
}

for role in planner coder reviewer; do
  model=$(model_for_role "$role")
  if [[ -n "$model" && ! "$model" =~ ^[A-Za-z0-9._:/-]+$ ]]; then
    die "$role model contains unsupported characters: $model"
  fi
done

render_dir=$(mktemp -d "$CODEX_DIR/.herdr-codex-team-render.XXXXXX")
chmod 700 "$render_dir" 2>/dev/null || true

render_profile() {
  local role=$1
  local model
  local target="$render_dir/$role.config.toml"
  local template="$PROJECT_ROOT/profiles/$role.config.toml"
  local prompt="$PROJECT_ROOT/prompts/$role.md"
  local prompt_digest
  local policy_digest

  model=$(model_for_role "$role")
  prompt_digest=$(prompt_payload_sha256 "$prompt") || \
    die "Could not compute the embedded prompt digest for $role. Install shasum, sha256sum, or openssl."
  policy_digest=$(profile_policy_source_sha256 "$template") || \
    die "Could not compute the managed profile-policy digest for $role."
  {
    printf '# Installed by herdr-codex-team. Edit the source template and rerun install.sh.\n'
    printf '# herdr-prompt-sha256: %s\n' "$prompt_digest"
    printf '# herdr-profile-policy-sha256: %s\n' "$policy_digest"
    if [[ -n "$model" ]]; then
      printf 'model = "%s"\n' "$model"
      # A role template may carry a default model. Remove only that key when
      # the user supplies an explicit install-time override, avoiding duplicate
      # TOML keys while preserving its reasoning and sandbox defaults.
      sed '/^[[:space:]]*model[[:space:]]*=/d' "$template"
    else
      command cat -- "$template"
    fi
    printf '\ndeveloper_instructions = '\''\'\''\'\''\n'
    command cat -- "$prompt"
    printf '\n'\''\'\''\'\''\n'
  } >"$target"
  chmod 600 "$target" 2>/dev/null || true
}

for role in planner coder reviewer; do
  render_profile "$role"
done

for role in planner coder reviewer; do
  if ! integrity_error=$(profile_prompt_integrity \
       "$render_dir/$role.config.toml" "$PROJECT_ROOT/prompts/$role.md" 2>&1); then
    die "Rendered $role profile failed prompt self-check: $integrity_error"
  fi
  if ! integrity_error=$(profile_policy_integrity \
       "$render_dir/$role.config.toml" "$PROJECT_ROOT/profiles/$role.config.toml" 2>&1); then
    die "Rendered $role profile failed policy self-check: $integrity_error"
  fi
  if ! CODEX_HOME="$render_dir" \
       codex --profile "$role" debug prompt-input 'profile validation' >/dev/null 2>&1; then
    die "Codex could not load the rendered $role profile; no destination profile was replaced."
  fi
done

for role in planner coder reviewer; do
  mv -f -- "$render_dir/$role.config.toml" "$CODEX_DIR/$role.config.toml"
  printf '[OK] Installed %s\n' "$CODEX_DIR/$role.config.toml"
done
cleanup_render_dir
render_dir=''

integration_status=''
if integration_status=$(herdr integration status 2>&1) && \
   printf '%s\n' "$integration_status" | grep -Eq '^codex: current([[:space:]]|$)'; then
  printf '[OK] Herdr Codex integration is current.\n'
else
  printf '[WARN] Herdr Codex integration is not confirmed current.\n'
  printf '       Review status: herdr integration status\n'
  printf '       If needed:     herdr integration install codex\n'
fi

printf '\nInstallation complete.\n'
printf 'Next steps:\n'
printf '  1. Start or attach Herdr: herdr\n'
printf '  2. Start the team in a Git project: %s/scripts/start.sh /path/to/project\n' "$PROJECT_ROOT"
printf '  3. Check it: %s/scripts/doctor.sh\n' "$PROJECT_ROOT"
printf '  4. Test it:  %s/scripts/test.sh ping\n' "$PROJECT_ROOT"
