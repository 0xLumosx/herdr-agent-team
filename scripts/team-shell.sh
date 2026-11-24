# Source in interactive Bash or Zsh. Plain provider commands apply to the current Herdr role.
export HERDR_LANG="${HERDR_LANG:-zh-CN}"
herdr() {
  if [ "${1:-}" = --team ]; then
    shift
    command herdr-team "$@"
  else
    command herdr "$@"
  fi
}

if [ -n "${HERDR_TEAM_STATE_FILE:-}" ] && [ "${HERDR_ENV:-}" = 1 ]; then
  codex()  { if [ "$#" -eq 0 ]; then herdr-team codex; else command codex "$@"; fi; }
  claude() { if [ "$#" -eq 0 ]; then herdr-team claude; else command claude "$@"; fi; }
  gemini() { if [ "$#" -eq 0 ]; then herdr-team gemini; else command gemini "$@"; fi; }
  agy()    { if [ "$#" -eq 0 ]; then herdr-team gemini; else command agy "$@"; fi; }
fi
