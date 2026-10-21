# YouNeeK Death Terminal shell integration for bash.
#
# Emits OSC 133 prompt/command marks (A = prompt start, B = input start,
# C = command start, D;<exit> = command finished) and OSC 7 (working
# directory) so the terminal knows what you are typing, where commands
# start and end, and how they exited. AI suggestions use this.
#
# YouNeeK Death Terminal injects this file automatically (shell.integration = true
# in config.lua). To source it yourself instead:
#   deathterminal --print-shell-integration bash > ~/.config/deathterminal/bash.sh
#   [ "$TERM_PROGRAM" = DeathTerminal ] && . ~/.config/deathterminal/bash.sh   # in ~/.bashrc

[[ $- == *i* ]] || return 0
[[ -n "${__dt_si_loaded-}" ]] && return 0
__dt_si_loaded=1
__dt_running=
__dt_inprompt=
__dt_ec=0

__dt_prompt_start() {
  __dt_ec=$?
  __dt_inprompt=1
}

__dt_prompt_end() {
  if [[ -n "$__dt_running" ]]; then
    printf '\e]133;D;%s\a' "$__dt_ec"
    __dt_running=
  fi
  printf '\e]7;file://%s%s\a' "${HOSTNAME:-localhost}" "$PWD"
  if [[ "$PS1" != *'133;B'* ]]; then
    PS1='\[\e]133;A\a\]'"$PS1"'\[\e]133;B\a\]'
  fi
  __dt_inprompt=
  return "$__dt_ec"
}

__dt_preexec() {
  [[ -n "$__dt_inprompt" || -n "$__dt_running" || -n "${COMP_LINE-}" ]] && return
  [[ "$BASH_COMMAND" == __dt_prompt_* ]] && return
  __dt_running=1
  printf '\e]133;C\a'
}

if [[ -z "${PROMPT_COMMAND-}" ]]; then
  PROMPT_COMMAND='__dt_prompt_start;__dt_prompt_end'
elif [[ "$PROMPT_COMMAND" != *__dt_prompt_* ]]; then
  PROMPT_COMMAND="__dt_prompt_start;${PROMPT_COMMAND%;};__dt_prompt_end"
fi
trap '__dt_preexec' DEBUG
