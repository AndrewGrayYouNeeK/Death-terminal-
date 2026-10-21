# YouNeeK Death Terminal shell integration for zsh.
#
# Emits OSC 133 prompt/command marks and OSC 7 (working directory); see
# bash.sh for what they mean. Injected automatically through ZDOTDIR when
# shell.integration = true. To source it yourself instead:
#   deathterminal --print-shell-integration zsh > ~/.config/deathterminal/zsh.zsh
#   [[ $TERM_PROGRAM == DeathTerminal ]] && source ~/.config/deathterminal/zsh.zsh   # in ~/.zshrc

[[ -o interactive ]] || return 0
(( ${+__dt_si_loaded} )) && return 0
typeset -g __dt_si_loaded=1 __dt_running=

__dt_precmd() {
  local ec=$?
  if [[ -n $__dt_running ]]; then
    printf '\e]133;D;%s\a' "$ec"
    __dt_running=
  fi
  printf '\e]7;file://%s%s\a' "${HOST:-localhost}" "$PWD"
  if [[ $PS1 != *'133;B'* ]]; then
    PS1=$'%{\e]133;A\a%}'"$PS1"$'%{\e]133;B\a%}'
  fi
  return $ec
}

__dt_preexec() {
  __dt_running=1
  printf '\e]133;C\a'
}

autoload -Uz add-zsh-hook
add-zsh-hook precmd __dt_precmd
add-zsh-hook preexec __dt_preexec
