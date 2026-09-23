import Foundation

enum ShellCommandIntegration {
    static let keySequence = "\u{18}\u{1F}"
    static let titlePrefix = "kooky-shell-control:"

    enum Event: String { case available, finished }

    static func parseTitle(_ title: String) -> (event: Event, pid: pid_t)? {
        guard title.hasPrefix(titlePrefix) else { return nil }
        let parts = title.dropFirst(titlePrefix.count).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let event = Event(rawValue: String(parts[0])),
              let pid = pid_t(parts[1]), pid > 0 else { return nil }
        return (event, pid)
    }

    // The key invokes an editor widget; its helper fetches the command over
    // the hook socket, never from stdin. Keystrokes remain queued for the
    // editor while the widget runs, so they cannot become part of an eval.
    static let zsh = #"""
    _kooky_unset_proxy() { unset "$@"; }
    _kooky_shell_control_available() { printf '\e]2;kooky-shell-control:available:%s\a' "$$"; }
    _kooky_shell_control_status() { return "$1"; }
    _kooky_shell_control() {
        local _kooky_control_text _kooky_control_hook _kooky_control_status
        local _kooky_control_buffer=$BUFFER _kooky_control_cursor=$CURSOR
        if _kooky_control_text=$("$KOOKY_HOOK_BIN" shell-command "$$" </dev/null) && [[ -n "$_kooky_control_text" ]]; then
            zle -I
            eval "$_kooky_control_text"
            _kooky_control_status=$?
            # Rebuild cached prompts (vcs_info / Starship / p10k) before
            # repainting. Skip our own prompt/command markers: the draft
            # was not submitted and this is not a new command boundary.
            for _kooky_control_hook in precmd "${precmd_functions[@]}"; do
                [[ $_kooky_control_hook == _kooky_* || $_kooky_control_hook == __kooky_* ]] && continue
                (( ${+functions[$_kooky_control_hook]} )) || continue
                _kooky_shell_control_status "$_kooky_control_status"
                "$_kooky_control_hook" || break
            done
            _kooky_env_status
            _kooky_osc7_pwd
            BUFFER=$_kooky_control_buffer
            CURSOR=$_kooky_control_cursor
            zle reset-prompt
        fi
        printf '\e]2;kooky-shell-control:finished:%s\a' "$$"
    }
    zle -N _kooky_shell_control
    for _kooky_keymap in main emacs viins vicmd; do
        bindkey -M "$_kooky_keymap" '^X^_' _kooky_shell_control
    done
    unset _kooky_keymap
    autoload -Uz add-zsh-hook
    add-zsh-hook precmd _kooky_shell_control_available
    """#

    static let bash = #"""
    _kooky_unset_proxy() { unset "$@"; }
    _kooky_shell_control_available() { printf '\e]2;kooky-shell-control:available:%s\a' "$$"; }
    _kooky_shell_control() {
        local _kooky_control_text
        if _kooky_control_text=$("$KOOKY_HOOK_BIN" shell-command "$$" </dev/null) && [[ -n "$_kooky_control_text" ]]; then
            printf '\n'
            eval "$_kooky_control_text"
            _kooky_env_status
            _kooky_osc7_pwd
        fi
        # Bash 3.2 caches Readline's expanded prompt during bind -x. Keep
        # the draft intact; its next normal prompt refreshes PS1 as usual.
        printf '\e]2;kooky-shell-control:finished:%s\a' "$$"
    }
    for _kooky_keymap in emacs-standard vi-insert vi-command; do
        bind -m "$_kooky_keymap" -x '"\C-x\C-_":_kooky_shell_control'
    done
    unset _kooky_keymap
    """#

    static let fish = #"""
    function _kooky_unset_proxy
        for _kooky_proxy in $argv
            set -eg $_kooky_proxy
            # An exported empty global masks an exported universal value in
            # child processes; an unexported global still leaks the universal.
            # Keep the persistent value intact for other terminals.
            if set -qU $_kooky_proxy
                set -gx $_kooky_proxy ''
            end
        end
    end
    function __kooky_shell_control
        set -l _kooky_control_text ("$KOOKY_HOOK_BIN" shell-command $fish_pid </dev/null)
        if test -n "$_kooky_control_text"
            printf '\n'
            eval $_kooky_control_text
            __kooky_env_status
            __kooky_prompt
            commandline -f repaint
        end
        printf '\e]2;kooky-shell-control:finished:%s\a' $fish_pid
    end
    function __kooky_shell_control_available --on-event fish_prompt
        bind -M default \cx\c_ __kooky_shell_control
        bind -M insert \cx\c_ __kooky_shell_control
        printf '\e]2;kooky-shell-control:available:%s\a' $fish_pid
    end
    """#
}
