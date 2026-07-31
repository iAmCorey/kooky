import Foundation

enum RemoteRuntimeScripts {
    /// Launches the ephemeral per-session runtime, then hands the terminal to
    /// the existing remote shell/agent bootstrap. The script deliberately
    /// uses only POSIX shell plus ubiquitous base utilities.
    static let bootstrapScript: String = {
        let nestedBootstrap = KookyShellIntegration.quote(
            KookyShellIntegration.remoteAgentBootstrapScript
        )
        return #"""
        set -f
        umask 077
        _kooky_token=${KOOKY_RUNTIME_TOKEN:-}
        # Consume-once: the token is captured into a local shell var used for the
        # rest of the runtime. Unset the exported copy so it does not leak into
        # the nested `sh -lc` handoff and the user's final interactive shell.
        unset KOOKY_RUNTIME_TOKEN
        case "$_kooky_token" in
          ????????-????-????-????-????????????) ;;
          *) printf 'kooky: invalid runtime token\n' >&2; exit 64 ;;
        esac
        case "$_kooky_token" in
          *[!0-9a-f-]*) printf 'kooky: invalid runtime token\n' >&2; exit 64 ;;
        esac

        _kooky_uid=$(id -u) || exit 70
        _kooky_base="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/kooky-$_kooky_uid"
        _kooky_runtime="$_kooky_base/$_kooky_token"
        case "$_kooky_runtime" in
          "$_kooky_base"/????????-????-????-????-????????????) ;;
          *) printf 'kooky: unsafe runtime path\n' >&2; exit 64 ;;
        esac

        if [ -e "$_kooky_base" ]; then
          [ -d "$_kooky_base" ] && [ ! -L "$_kooky_base" ] || {
            printf 'kooky: unsafe runtime root\n' >&2
            exit 73
          }
          _kooky_owner=$(stat -c %u -- "$_kooky_base" 2>/dev/null ||
            stat -f %u "$_kooky_base" 2>/dev/null) || exit 73
          _kooky_mode=$(stat -c %a -- "$_kooky_base" 2>/dev/null ||
            stat -f %Lp "$_kooky_base" 2>/dev/null) || exit 73
          [ "$_kooky_owner" = "$_kooky_uid" ] && [ "$_kooky_mode" = 700 ] || {
            printf 'kooky: unsafe runtime root ownership or mode\n' >&2
            exit 73
          }
        else
          mkdir -m 700 "$_kooky_base" 2>/dev/null || exit 73
        fi
        mkdir -m 700 "$_kooky_runtime" 2>/dev/null || {
          printf 'kooky: runtime already exists\n' >&2
          exit 73
        }
        _kooky_fifo="$_kooky_runtime/input.fifo"
        mkfifo -m 600 "$_kooky_fifo" 2>/dev/null || exit 73
        : > "$_kooky_runtime/events.log"
        printf '%s\n' 'KRP/1' > "$_kooky_runtime/protocol-version"
        printf 'KRP/1\tSNAPSHOT\t0\t-\tidle\t-\t0\t-\t-\n' > "$_kooky_runtime/state"

        _kooky_cleanup_runtime() {
          trap - EXIT HUP INT TERM
          : > "$_kooky_runtime/stopping" 2>/dev/null || :
          _kooky_live_collector=
          IFS= read -r _kooky_live_collector < "$_kooky_runtime/collector.pid" 2>/dev/null || :
          case "$_kooky_live_collector" in
            *[!0-9]*|'') ;;
            *) kill "$_kooky_live_collector" 2>/dev/null || : ;;
          esac
          [ -n "${_kooky_collector_supervisor_pid:-}" ] &&
            kill "$_kooky_collector_supervisor_pid" 2>/dev/null || :
          exec 8>&- 2>/dev/null || :
          exec 9>&- 2>/dev/null || :
          case "$_kooky_runtime" in
            "$_kooky_base"/"$_kooky_token")
              [ -d "$_kooky_runtime" ] && [ ! -L "$_kooky_runtime" ] &&
                rm -rf -- "$_kooky_runtime"
              ;;
          esac
        }
        trap '_kooky_cleanup_runtime' EXIT
        trap '_kooky_cleanup_runtime; exit 129' HUP
        trap '_kooky_cleanup_runtime; exit 130' INT
        trap '_kooky_cleanup_runtime; exit 143' TERM

        # Keeper FD prevents a producer open from blocking during a short
        # collector restart window. Producers still keep frames <=480 bytes.
        exec 9<> "$_kooky_fifo" || exit 74
        _kooky_collect_once() {
          while IFS="$_kooky_tab" read -r _kooky_v _kooky_type _kooky_a _kooky_b _kooky_c _kooky_d
          do
            [ "$_kooky_v" = P/1 ] || continue
            case "$_kooky_type" in
              AGENT)
                case "$_kooky_a" in *[!A-Za-z0-9._-]*|'') continue ;; esac
                case "$_kooky_b" in idle|running|attention|ended) ;; *) continue ;; esac
                _kooky_agent=$_kooky_a
                _kooky_activity=$_kooky_b
                ;;
              PROMPT)
                case "$_kooky_b" in 0|1) ;; *) continue ;; esac
                _kooky_cwd=$_kooky_a
                _kooky_truncated=$_kooky_b
                _kooky_exit=${_kooky_c:--}
                _kooky_duration=${_kooky_d:--}
                ;;
              ERROR)
                continue
                ;;
              *)
                continue
                ;;
            esac
            [ "$_kooky_seq" -lt 9223372036854775806 ] 2>/dev/null || return 70
            _kooky_seq=$((_kooky_seq + 1))
            printf 'KRP/1\tEVENT\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
              "$_kooky_seq" "$_kooky_agent" "$_kooky_activity" "$_kooky_cwd" \
              "$_kooky_truncated" "$_kooky_exit" "$_kooky_duration" \
              >> "$_kooky_runtime/events.log" || return 74
            printf 'KRP/1\tSNAPSHOT\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
              "$_kooky_seq" "$_kooky_agent" "$_kooky_activity" "$_kooky_cwd" \
              "$_kooky_truncated" "$_kooky_exit" "$_kooky_duration" \
              > "$_kooky_runtime/state.tmp" &&
              mv -f "$_kooky_runtime/state.tmp" "$_kooky_runtime/state" ||
              return 74
          done < "$_kooky_fifo"
        }
        _kooky_collect() {
          _kooky_tab=$(printf '\t')
          IFS="$_kooky_tab" read -r _kooky_v _kooky_type _kooky_seq \
            _kooky_agent _kooky_activity _kooky_cwd _kooky_truncated \
            _kooky_exit _kooky_duration < "$_kooky_runtime/state" ||
            return 74
          [ "$_kooky_v" = KRP/1 ] && [ "$_kooky_type" = SNAPSHOT ] ||
            return 74
          case "$_kooky_seq:$_kooky_agent:$_kooky_activity:$_kooky_truncated" in
            *[!0-9A-Za-z._:-]*|::*|*::|:*|*:) return 74 ;;
          esac
          case "$_kooky_activity" in idle|running|attention|ended) ;; *) return 74 ;; esac
          case "$_kooky_truncated" in 0|1) ;; *) return 74 ;; esac

          # Log-first/state-second means a crash can leave one durable EVENT
          # ahead of the snapshot. Recover that complete line before reopening
          # the FIFO so sequence allocation remains monotonic after restart.
          tail -n 1 "$_kooky_runtime/events.log" \
            > "$_kooky_runtime/recover.tmp" 2>/dev/null || :
          if [ -s "$_kooky_runtime/recover.tmp" ]; then
            IFS="$_kooky_tab" read -r _kooky_rv _kooky_rt _kooky_rs \
              _kooky_ra _kooky_ry _kooky_rc _kooky_rr _kooky_re _kooky_rd \
              < "$_kooky_runtime/recover.tmp" || return 74
            case "$_kooky_rs" in *[!0-9]*|'') return 74 ;; esac
            if [ "$_kooky_rs" -gt "$_kooky_seq" ] 2>/dev/null; then
              _kooky_seq=$_kooky_rs
              _kooky_agent=$_kooky_ra
              _kooky_activity=$_kooky_ry
              _kooky_cwd=$_kooky_rc
              _kooky_truncated=$_kooky_rr
              _kooky_exit=$_kooky_re
              _kooky_duration=$_kooky_rd
              printf 'KRP/1\tSNAPSHOT\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$_kooky_seq" "$_kooky_agent" "$_kooky_activity" "$_kooky_cwd" \
                "$_kooky_truncated" "$_kooky_exit" "$_kooky_duration" \
                > "$_kooky_runtime/state.tmp" &&
                mv -f "$_kooky_runtime/state.tmp" "$_kooky_runtime/state" ||
                return 74
            fi
          fi
          rm -f "$_kooky_runtime/recover.tmp"
          _kooky_collect_once
        }
        _kooky_supervise_collector() {
          _kooky_restarts=0
          while [ "$_kooky_restarts" -le 1 ]; do
            _kooky_collect &
            _kooky_child=$!
            printf '%s\n' "$_kooky_child" > "$_kooky_runtime/collector.pid" ||
              return 74
            wait "$_kooky_child"
            _kooky_child_status=$?
            [ -e "$_kooky_runtime/stopping" ] && return 0
            _kooky_restarts=$((_kooky_restarts + 1))
          done
          return "$_kooky_child_status"
        }
        _kooky_supervise_collector &
        _kooky_collector_supervisor_pid=$!
        printf '%s\n' "$_kooky_collector_supervisor_pid" \
          > "$_kooky_runtime/collector-supervisor.pid"
        printf '%s\n' "$_kooky_uid" > "$_kooky_runtime/owner.uid"
        printf '%s\n' "$_kooky_token" > "$_kooky_runtime/token"
        printf '%s\n' "$$" > "$_kooky_runtime/leader.pid"
        _kooky_leader_pgid=$(ps -o pgid= -p $$ 2>/dev/null) || exit 70
        _kooky_leader_pgid=${_kooky_leader_pgid#${_kooky_leader_pgid%%[! ]*}}
        case "$_kooky_leader_pgid" in *[!0-9]*|'') exit 70 ;; esac
        printf '%s\n' "$_kooky_leader_pgid" > "$_kooky_runtime/leader.pgid"
        _kooky_leader_start=$(ps -o lstart= -p $$ 2>/dev/null) || exit 70
        [ -n "$_kooky_leader_start" ] || exit 70
        printf '%s\n' "$_kooky_leader_start" > "$_kooky_runtime/leader.start"
        _kooky_parent_pid=$(ps -o ppid= -p $$ 2>/dev/null) || exit 70
        _kooky_parent_pid=${_kooky_parent_pid#${_kooky_parent_pid%%[! ]*}}
        case "$_kooky_parent_pid" in *[!0-9]*|'') exit 70 ;; esac
        _kooky_parent_start=$(ps -o lstart= -p "$_kooky_parent_pid" 2>/dev/null) || exit 70
        _kooky_parent_command=$(ps -o comm= -p "$_kooky_parent_pid" 2>/dev/null) || exit 70
        [ -n "$_kooky_parent_start" ] && [ -n "$_kooky_parent_command" ] || exit 70
        printf '%s\n' "$_kooky_parent_pid" > "$_kooky_runtime/parent.pid"
        printf '%s\n' "$_kooky_parent_start" > "$_kooky_runtime/parent.start"
        printf '%s\n' "$_kooky_parent_command" > "$_kooky_runtime/parent.command"

        exec 8> "$_kooky_fifo" || exit 74
        _kooky_hook="$_kooky_runtime/kooky-remote-hook"
        cat > "$_kooky_hook" <<'KOOKY_REMOTE_HOOK'
        #!/bin/sh
        _kooky_collector=
        [ -n "${KOOKY_REMOTE_RUNTIME:-}" ] &&
          IFS= read -r _kooky_collector \
            < "$KOOKY_REMOTE_RUNTIME/collector.pid" 2>/dev/null || exit 0
        case "$_kooky_collector" in *[!0-9]*|'') exit 0 ;; esac
        kill -0 "$_kooky_collector" 2>/dev/null || exit 0
        case "${1:-}" in
          AGENT)
            case "${2:-}" in *[!A-Za-z0-9._-]*|'') exit 0 ;; esac
            case "${3:-}" in idle|running|attention|ended) ;; *) exit 0 ;; esac
            printf 'P/1\tAGENT\t%s\t%s\n' "$2" "$3" > "${KOOKY_REMOTE_FIFO:?}" 2>/dev/null || :
            ;;
          ERROR)
            case "${2:-}" in *[!A-Za-z0-9._-]*|'') exit 0 ;; esac
            printf 'P/1\tERROR\t%s\n' "$2" > "${KOOKY_REMOTE_FIFO:?}" 2>/dev/null || :
            ;;
        esac
        exit 0
        KOOKY_REMOTE_HOOK
        chmod 700 "$_kooky_hook"
        _kooky_claude_settings="$_kooky_runtime/claude-settings.json"
        cat > "$_kooky_claude_settings" <<'KOOKY_CLAUDE_SETTINGS'
        {
          "hooks": {
            "SessionStart": [{"hooks": [{"type": "command", "command": "\"$KOOKY_REMOTE_HOOK\" AGENT claude running"}]}],
            "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "\"$KOOKY_REMOTE_HOOK\" AGENT claude running"}]}],
            "Stop": [{"hooks": [{"type": "command", "command": "\"$KOOKY_REMOTE_HOOK\" AGENT claude attention"}]}],
            "Notification": [{"hooks": [{"type": "command", "command": "\"$KOOKY_REMOTE_HOOK\" AGENT claude attention"}]}],
            "SessionEnd": [{"hooks": [{"type": "command", "command": "\"$KOOKY_REMOTE_HOOK\" AGENT claude ended"}]}]
          }
        }
        KOOKY_CLAUDE_SETTINGS
        chmod 600 "$_kooky_claude_settings"
        export KOOKY_REMOTE_FIFO="$_kooky_fifo"
        export KOOKY_REMOTE_HOOK="$_kooky_hook"
        export KOOKY_REMOTE_CLAUDE_SETTINGS="$_kooky_claude_settings"
        export KOOKY_REMOTE_EVENT_FD=8
        export KOOKY_REMOTE_RUNTIME="$_kooky_runtime"
        printf 'KRP/1\tREADY\t%s\n' "$_kooky_token" > "$_kooky_runtime/ready"

        sh -lc \#(nestedBootstrap)
        _kooky_status=$?
        exit "$_kooky_status"
        """#
    }()

    static func watchCommand(token: UUID) -> String {
        let canonical = token.uuidString.lowercased()
        return #"""
        set -f
        umask 077
        _kooky_token=\#(KookyShellIntegration.quote(canonical))
        _kooky_uid=$(id -u) || exit 70
        _kooky_base="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/kooky-$_kooky_uid"
        _kooky_runtime="$_kooky_base/$_kooky_token"
        [ -d "$_kooky_runtime" ] && [ ! -L "$_kooky_runtime" ] || exit 75
        _kooky_owner=$(stat -c %u -- "$_kooky_runtime" 2>/dev/null ||
          stat -f %u "$_kooky_runtime" 2>/dev/null) || exit 76
        _kooky_mode=$(stat -c %a -- "$_kooky_runtime" 2>/dev/null ||
          stat -f %Lp "$_kooky_runtime" 2>/dev/null) || exit 76
        [ "$_kooky_owner" = "$_kooky_uid" ] && [ "$_kooky_mode" = 700 ] || exit 76
        [ "$(cat "$_kooky_runtime/token" 2>/dev/null)" = "$_kooky_token" ] || exit 76
        printf 'KRP/1\tREADY\t%s\n' "$_kooky_token"
        _kooky_state=$(cat "$_kooky_runtime/state") || exit 74
        printf '%s\n' "$_kooky_state"
        _kooky_seq=$(printf '%s\n' "$_kooky_state" | awk -F '\t' '{print $3}')
        case "$_kooky_seq" in *[!0-9]*|'') exit 76 ;; esac
        tail -n "+$((_kooky_seq + 1))" -f "$_kooky_runtime/events.log"
        """#
    }

    static func cleanupCommand(token: UUID) -> String {
        let canonical = token.uuidString.lowercased()
        return #"""
        set -f
        _kooky_token=\#(KookyShellIntegration.quote(canonical))
        _kooky_uid=$(id -u) || exit 70
        _kooky_base="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/kooky-$_kooky_uid"
        _kooky_runtime="$_kooky_base/$_kooky_token"
        case "$_kooky_runtime" in "$_kooky_base"/"$_kooky_token") ;; *) exit 64 ;; esac
        [ -d "$_kooky_runtime" ] && [ ! -L "$_kooky_runtime" ] || exit 0
        _kooky_owner=$(stat -c %u -- "$_kooky_runtime" 2>/dev/null ||
          stat -f %u "$_kooky_runtime" 2>/dev/null) || exit 76
        _kooky_mode=$(stat -c %a -- "$_kooky_runtime" 2>/dev/null ||
          stat -f %Lp "$_kooky_runtime" 2>/dev/null) || exit 76
        [ "$_kooky_owner" = "$_kooky_uid" ] && [ "$_kooky_mode" = 700 ] || exit 76
        [ "$(cat "$_kooky_runtime/token" 2>/dev/null)" = "$_kooky_token" ] || exit 76
        _kooky_pid=$(cat "$_kooky_runtime/leader.pid" 2>/dev/null || :)
        _kooky_pgid=$(cat "$_kooky_runtime/leader.pgid" 2>/dev/null || :)
        _kooky_start=$(cat "$_kooky_runtime/leader.start" 2>/dev/null || :)
        _kooky_parent=$(cat "$_kooky_runtime/parent.pid" 2>/dev/null || :)
        _kooky_parent_start=$(cat "$_kooky_runtime/parent.start" 2>/dev/null || :)
        _kooky_parent_command=$(cat "$_kooky_runtime/parent.command" 2>/dev/null || :)
        case "$_kooky_pid:$_kooky_pgid:$_kooky_parent" in
          *[!0-9:]*|::*|*::|:*|*:) exit 76 ;;
        esac
        _kooky_live_pgid=$(ps -o pgid= -p "$_kooky_pid" 2>/dev/null) || {
          rm -rf -- "$_kooky_runtime"
          exit 0
        }
        _kooky_live_pgid=${_kooky_live_pgid#${_kooky_live_pgid%%[! ]*}}
        _kooky_live_start=$(ps -o lstart= -p "$_kooky_pid" 2>/dev/null) || exit 0
        _kooky_live_parent=$(ps -o ppid= -p "$_kooky_pid" 2>/dev/null) || exit 0
        _kooky_live_parent=${_kooky_live_parent#${_kooky_live_parent%%[! ]*}}
        _kooky_live_parent_start=$(ps -o lstart= -p "$_kooky_parent" 2>/dev/null) || exit 0
        _kooky_live_parent_command=$(ps -o comm= -p "$_kooky_parent" 2>/dev/null) || exit 0
        [ "$_kooky_live_pgid" = "$_kooky_pgid" ] &&
          [ "$_kooky_live_start" = "$_kooky_start" ] &&
          [ "$_kooky_live_parent" = "$_kooky_parent" ] &&
          [ "$_kooky_live_parent_start" = "$_kooky_parent_start" ] &&
          [ "$_kooky_live_parent_command" = "$_kooky_parent_command" ] || exit 76
        kill -TERM "-$_kooky_pgid" 2>/dev/null || kill -TERM "$_kooky_pid" 2>/dev/null || :
        exit 0
        """#
    }
}
