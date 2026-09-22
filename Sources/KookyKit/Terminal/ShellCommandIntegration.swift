import Foundation

enum ShellCommandIntegration {
    static let keySequence = "\u{18}\u{1F}"
    static let titlePrefix = "kooky-shell-control:"

    enum Event: String { case available, ready, finished }

    static func parseTitle(_ title: String) -> (event: Event, pid: pid_t)? {
        guard title.hasPrefix(titlePrefix) else { return nil }
        let parts = title.dropFirst(titlePrefix.count).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let event = Event(rawValue: String(parts[0])),
              let pid = pid_t(parts[1]), pid > 0 else { return nil }
        return (event, pid)
    }

    static func payload(for command: String) -> String? {
        let command = command.trimmingCharacters(in: .newlines)
        guard !command.isEmpty, command.utf8.count <= 4096,
              !command.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return command + "\0"
    }

    // Only send command text after the shell's editor acknowledges the key.
    // The widgets run in that shell, so nvm's environment changes survive
    // without accepting or replacing the user's editing buffer.
    static let zsh = #"""
    _kooky_shell_control_available() { printf '\e]2;kooky-shell-control:available:%s\a' "$$"; }
    _kooky_shell_control() {
        local _kooky_control_text='' _kooky_control_char
        printf '\e]2;kooky-shell-control:ready:%s\a' "$$"
        while IFS= read -rk 1 -t 3 _kooky_control_char; do
            [[ "$_kooky_control_char" == $'\0' ]] && break
            _kooky_control_text+="$_kooky_control_char"
        done
        if [[ "$_kooky_control_char" == $'\0' && -n "$_kooky_control_text" ]]; then
            zle -I
            eval "$_kooky_control_text"
            _kooky_env_status
            _kooky_osc7_pwd
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
    _kooky_shell_control_available() { printf '\e]2;kooky-shell-control:available:%s\a' "$$"; }
    _kooky_shell_control() {
        local _kooky_control_text
        printf '\e]2;kooky-shell-control:ready:%s\a' "$$"
        if IFS= read -r -d '' -t 3 _kooky_control_text && [[ -n "$_kooky_control_text" ]]; then
            printf '\n'
            eval "$_kooky_control_text"
            _kooky_env_status
            _kooky_osc7_pwd
        fi
        printf '\e]2;kooky-shell-control:finished:%s\a' "$$"
    }
    for _kooky_keymap in emacs-standard vi-insert vi-command; do
        bind -m "$_kooky_keymap" -x '"\C-x\C-_":_kooky_shell_control'
    done
    unset _kooky_keymap
    """#

    static let fish = #"""
    function __kooky_shell_control
        printf '\e]2;kooky-shell-control:ready:%s\a' $fish_pid
        if read -lz _kooky_control_text; and test -n "$_kooky_control_text"
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
