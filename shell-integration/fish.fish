# Death Terminal shell integration for fish.
#
# Emits OSC 133 prompt/command marks and OSC 7 (working directory); see
# bash.sh for what they mean. Injected automatically with --init-command
# when shell.integration = true. To source it yourself instead:
#   deathterminal --print-shell-integration fish > ~/.config/fish/conf.d/deathterminal.fish

status is-interactive; or exit 0
set -q __dt_si_loaded; and exit 0
set -g __dt_si_loaded 1

# fish 4 emits the command marks (C, D) and OSC 7 by itself; older
# versions need them here. The prompt marks (A, B) are always added below.
if not test (string split -f1 . $version) -ge 4 2>/dev/null
    function __dt_preexec --on-event fish_preexec
        printf '\e]133;C\a'
    end

    function __dt_postexec --on-event fish_postexec
        printf '\e]133;D;%s\a' $status
    end

    function __dt_cwd --on-variable PWD
        printf '\e]7;file://%s%s\a' $hostname "$PWD"
    end
    __dt_cwd
end

if functions -q fish_prompt
    functions -c fish_prompt __dt_orig_prompt
else
    function __dt_orig_prompt
        printf '%s> ' (prompt_pwd)
    end
end

function fish_prompt
    printf '\e]133;A\a'
    __dt_orig_prompt
    printf '\e]133;B\a'
end
