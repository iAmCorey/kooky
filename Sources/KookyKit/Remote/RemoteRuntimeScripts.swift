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
          if [ -n "${KOOKY_REAPER_ENABLED:-}" ]; then
            # The reaper is the SINGLE cleanup executor: hand it the session end
            # and let it TERM->KILL registered agents and delete the runtime.
            printf 'SHUTDOWN\n' >&6 2>/dev/null || :
            exec 6>&- 2>/dev/null || :
          else
            case "$_kooky_runtime" in
              "$_kooky_base"/"$_kooky_token")
                [ -d "$_kooky_runtime" ] && [ ! -L "$_kooky_runtime" ] &&
                  rm -rf -- "$_kooky_runtime"
                ;;
            esac
          fi
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

        # --- Orphan reaper (Linux setsid is the primary delivery path) --------
        # A detached, session-owning process is the SINGLE cleanup executor: it
        # TERM->KILLs identity-verified agent process groups and is the SOLE
        # deleter of the runtime directory on session end or PTY death. Agents
        # register through the inherited, already-open fd 6 (never by opening
        # the FIFO themselves), so a crashed reaper can never block a launch.
        _kooky_leader_sid=$(ps -o sid= -p $$ 2>/dev/null ||
          ps -o sess= -p $$ 2>/dev/null || printf '')
        _kooky_leader_sid=${_kooky_leader_sid#${_kooky_leader_sid%%[! ]*}}
        _kooky_leader_sid=${_kooky_leader_sid%${_kooky_leader_sid##*[! ]}}
        _kooky_reaper_ctrl="$_kooky_runtime/reaper.control"
        if mkfifo -m 600 "$_kooky_reaper_ctrl" 2>/dev/null &&
          exec 6<> "$_kooky_reaper_ctrl"; then
          KOOKY_REAPER_RUNTIME="$_kooky_runtime" \
          KOOKY_REAPER_CTRL="$_kooky_reaper_ctrl" \
          KOOKY_REAPER_LEADER_PID="$$" \
          KOOKY_REAPER_LEADER_START="$_kooky_leader_start" \
          KOOKY_REAPER_POLL=2 \
          KOOKY_REAPER_GRACE=5 \
          setsid sh -s >/dev/null 2>&1 <<'KOOKY_REAPER_SH' &
        \#(RemoteRuntimeScripts.reaperScript)
        KOOKY_REAPER_SH
          _kooky_reaper_pid=$!
          _kooky_reaper_pgid=$(ps -o pgid= -p "$_kooky_reaper_pid" 2>/dev/null || printf '')
          _kooky_reaper_pgid=${_kooky_reaper_pgid#${_kooky_reaper_pgid%%[! ]*}}
          _kooky_reaper_pgid=${_kooky_reaper_pgid%${_kooky_reaper_pgid##*[! ]}}
          _kooky_reaper_sid=$(ps -o sid= -p "$_kooky_reaper_pid" 2>/dev/null ||
            ps -o sess= -p "$_kooky_reaper_pid" 2>/dev/null || printf '')
          _kooky_reaper_sid=${_kooky_reaper_sid#${_kooky_reaper_sid%%[! ]*}}
          _kooky_reaper_sid=${_kooky_reaper_sid%${_kooky_reaper_sid##*[! ]}}
          # Capability gate (constraint 3): the reaper is usable ONLY if it is
          # alive AND lives in a different process group AND session than the
          # login leader -- otherwise `kill -<leader_pgid>` would take it down
          # with the session. Its stdio is detached by construction (stdin is
          # this heredoc, stdout/stderr are /dev/null), never the PTY.
          if kill -0 "$_kooky_reaper_pid" 2>/dev/null &&
            [ -n "$_kooky_reaper_pgid" ] &&
            [ "$_kooky_reaper_pgid" != "$_kooky_leader_pgid" ] &&
            { [ -z "$_kooky_leader_sid" ] || [ "$_kooky_reaper_sid" != "$_kooky_leader_sid" ]; }
          then
            export KOOKY_REAPER_ENABLED=1
            export KOOKY_REAPER_FD=6
            printf '%s\n' "$_kooky_reaper_pid" > "$_kooky_runtime/reaper.pid"
          else
            case "$_kooky_reaper_pid" in
              *[!0-9]*|'') ;;
              *) kill "$_kooky_reaper_pid" 2>/dev/null || : ;;
            esac
            exec 6>&- 2>/dev/null || :
          fi
        else
          exec 6>&- 2>/dev/null || :
        fi

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

    /// Detached, session-owning reaper. It is the SINGLE cleanup executor and
    /// the SOLE deleter of the runtime directory. Agents register their
    /// identity through the control FIFO (`REG`/`UNREG` frames) into this
    /// process's in-memory table — never through files the leader trap might
    /// delete. A `SHUTDOWN` frame (from the poller on PTY/leader death, from
    /// the leader's own exit, or from a local SSH cleanup) makes it TERM→KILL
    /// every still-registered agent's process group, then remove the runtime.
    ///
    /// All parameters arrive by environment so the script text needs no
    /// per-launch interpolation and can be exercised directly in tests:
    /// `KOOKY_REAPER_RUNTIME`, `KOOKY_REAPER_CTRL`, `KOOKY_REAPER_LEADER_PID`,
    /// `KOOKY_REAPER_LEADER_START` (optional identity guard),
    /// `KOOKY_REAPER_POLL`, `KOOKY_REAPER_GRACE`.
    static let reaperScript: String = #"""
    set -f
    umask 077
    _r_runtime=${KOOKY_REAPER_RUNTIME:-}
    _r_ctrl=${KOOKY_REAPER_CTRL:-}
    _r_leader=${KOOKY_REAPER_LEADER_PID:-}
    _r_leader_start=${KOOKY_REAPER_LEADER_START:-}
    _r_poll=${KOOKY_REAPER_POLL:-2}
    _r_grace=${KOOKY_REAPER_GRACE:-5}
    [ -n "$_r_runtime" ] && [ -n "$_r_ctrl" ] && [ -n "$_r_leader" ] || exit 64
    case "$_r_leader" in *[!0-9]*|'') exit 64 ;; esac
    _r_tab=$(printf '\t')
    _r_table=

    # `ps -o lstart=` right-pads to a fixed width, and command substitution
    # only strips trailing NEWLINES (not spaces), so producer- and reaper-side
    # readings of the same start time can differ by trailing blanks. Normalize
    # both ends everywhere start times are compared.
    _r_trim() {
      _r_trimmed=$1
      _r_trimmed=${_r_trimmed#"${_r_trimmed%%[! ]*}"}
      _r_trimmed=${_r_trimmed%"${_r_trimmed##*[! ]}"}
    }
    _r_trim "$_r_leader_start"
    _r_leader_start=$_r_trimmed

    # rw open: never blocks on a missing reader, and keeps the FIFO writable
    # for producers even across our own read gaps. We are the sole reader.
    [ -p "$_r_ctrl" ] || mkfifo -m 600 "$_r_ctrl" 2>/dev/null || exit 74
    exec 3<>"$_r_ctrl" || exit 74

    _r_leader_alive() {
      kill -0 "$_r_leader" 2>/dev/null || return 1
      [ -n "$_r_leader_start" ] || return 0
      _r_cur=$(ps -o lstart= -p "$_r_leader" 2>/dev/null) || return 1
      _r_trim "$_r_cur"
      [ "$_r_trimmed" = "$_r_leader_start" ]
    }

    # Linux-only refinement: the leader may outlive the PTY (grandparent
    # mosh-server gone). A "(deleted)" controlling terminal is a hard trigger.
    _r_pty_dead() {
      [ -r "/proc/$_r_leader/fd/0" ] || return 1
      case "$(readlink "/proc/$_r_leader/fd/0" 2>/dev/null)" in
        *"(deleted)") return 0 ;;
      esac
      return 1
    }

    # Identity-checked target resolution (guards PID reuse). Prefer the live
    # wrapper anchor and its CURRENT pgid. PTY hangup can kill the wrapper a
    # moment before the reaper observes the deleted terminal, however, while a
    # HUP-ignoring Codex remains in the old job-control group. In that case the
    # recorded pgid is accepted only while it still has a member in the exact
    # recorded session. A live member prevents that SID/PGID pair from being
    # reused by an unrelated session.
    _r_target_pgid() {
      _r_rp=$1
      _r_rs=$2
      _r_rg=$3
      _r_rd=$4
      case "$_r_rp" in *[!0-9]*|'') return 1 ;; esac
      if kill -0 "$_r_rp" 2>/dev/null; then
        _r_cs=$(ps -o lstart= -p "$_r_rp" 2>/dev/null) || return 1
        _r_trim "$_r_cs"
        [ "$_r_trimmed" = "$_r_rs" ] || return 1
        _r_cg=$(ps -o pgid= -p "$_r_rp" 2>/dev/null) || return 1
        _r_cg=${_r_cg#${_r_cg%%[! ]*}}
        case "$_r_cg" in *[!0-9]*|'') return 1 ;; esac
        printf '%s' "$_r_cg"
        return 0
      fi
      case "$_r_rg:$_r_rd" in *[!0-9:]*|::*|*::|:*|*:) return 1 ;; esac
      ( ps -eo pgid=,sid= 2>/dev/null ||
        ps -eo pgid=,sess= 2>/dev/null ) | while read -r _r_mg _r_md; do
        if [ "$_r_mg" = "$_r_rg" ] && [ "$_r_md" = "$_r_rd" ]; then
          printf '%s' "$_r_rg"
          break
        fi
      done
    }

    _r_add() {
      case "$1" in *[!0-9]*|'') return 0 ;; esac
      case "$2" in *[!0-9]*|'') return 0 ;; esac
      _r_trim "$3"
      _r_line="$1$_r_tab$2$_r_tab$_r_trimmed$_r_tab$4"
      if [ -z "$_r_table" ]; then
        _r_table=$_r_line
      else
        _r_table="$_r_table
    $_r_line"
      fi
    }

    _r_remove() {
      case "$1" in *[!0-9]*|'') return 0 ;; esac
      _r_new=
      while IFS="$_r_tab" read -r _r_ep _r_eg _r_es _r_ed; do
        [ -n "$_r_ep" ] || continue
        [ "$_r_ep" = "$1" ] && continue
        _r_l="$_r_ep$_r_tab$_r_eg$_r_tab$_r_es$_r_tab$_r_ed"
        if [ -z "$_r_new" ]; then
          _r_new=$_r_l
        else
          _r_new="$_r_new
    $_r_l"
        fi
      done <<_R_TABLE
    $_r_table
    _R_TABLE
      _r_table=$_r_new
    }

    _r_signal_all() {
      _r_sig=$1
      while IFS="$_r_tab" read -r _r_ep _r_eg _r_es _r_ed; do
        [ -n "$_r_ep" ] || continue
        _r_pg=$(_r_target_pgid "$_r_ep" "$_r_es" "$_r_eg" "$_r_ed") || continue
        [ -n "$_r_pg" ] || continue
        kill -"$_r_sig" -"$_r_pg" 2>/dev/null || :
      done <<_R_TABLE
    $_r_table
    _R_TABLE
    }

    _r_any_alive() {
      while IFS="$_r_tab" read -r _r_ep _r_eg _r_es _r_ed; do
        [ -n "$_r_ep" ] || continue
        if _r_target_pgid "$_r_ep" "$_r_es" "$_r_eg" "$_r_ed" >/dev/null 2>&1; then
          printf yes
          return 0
        fi
      done <<_R_TABLE
    $_r_table
    _R_TABLE
    }

    _r_reap() {
      _r_signal_all TERM
      _r_end=$(( $(date +%s) + _r_grace ))
      while [ "$(date +%s)" -lt "$_r_end" ]; do
        [ "$(_r_any_alive)" = yes ] || return 0
        sleep 1
      done
      _r_signal_all KILL
    }

    _r_remove_runtime() {
      case "$_r_runtime" in
        */*)
          [ -d "$_r_runtime" ] && [ ! -L "$_r_runtime" ] &&
            rm -rf -- "$_r_runtime"
          ;;
      esac
    }

    _r_poller() {
      while :; do
        _r_leader_alive || { printf 'SHUTDOWN\n' >&3 2>/dev/null || :; return 0; }
        if _r_pty_dead; then
          printf 'SHUTDOWN\n' >&3 2>/dev/null || :
          return 0
        fi
        sleep "$_r_poll"
      done
    }

    _r_poller &
    _r_poller_pid=$!

    _r_shutdown=
    while IFS="$_r_tab" read -r _r_c0 _r_c1 _r_c2 _r_c3 _r_c4 <&3; do
      case "$_r_c0" in
        REG) _r_add "$_r_c1" "$_r_c2" "$_r_c3" "$_r_c4" ;;
        UNREG) _r_remove "$_r_c1" ;;
        SHUTDOWN) _r_shutdown=1; break ;;
        *) : ;;
      esac
    done

    kill "$_r_poller_pid" 2>/dev/null || :
    [ -n "$_r_shutdown" ] && _r_reap
    _r_remove_runtime
    exit 0
    """#

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

        # Constraint 1: when a reaper owns this session it is the SINGLE cleanup
        # executor. A local reclamation must not run its own TERM/KILL logic --
        # it asks the reaper to shut down (TERM->KILL of every registered agent
        # group, then delete the runtime) and only reclaims directly if the
        # reaper is provably gone. This runs before the strict leader-identity
        # gate below because the reaper already holds verified identities.
        _kooky_ctrl="$_kooky_runtime/reaper.control"
        _kooky_reaper=$(cat "$_kooky_runtime/reaper.pid" 2>/dev/null || :)
        case "$_kooky_reaper" in *[!0-9]*|'') _kooky_reaper= ;; esac
        if [ -p "$_kooky_ctrl" ] && [ -n "$_kooky_reaper" ] &&
          kill -0 "$_kooky_reaper" 2>/dev/null; then
          if exec 3<> "$_kooky_ctrl" 2>/dev/null; then
            printf 'SHUTDOWN\n' >&3 2>/dev/null || :
            exec 3>&- 2>/dev/null || :
          fi
          _kooky_wait=0
          while [ "$_kooky_wait" -lt 12 ]; do
            [ -d "$_kooky_runtime" ] || exit 0
            kill -0 "$_kooky_reaper" 2>/dev/null || break
            sleep 1
            _kooky_wait=$((_kooky_wait + 1))
          done
          # Reaper still alive but slow: trust it to finish after its grace
          # window rather than racing a second executor.
          kill -0 "$_kooky_reaper" 2>/dev/null && exit 0
        fi

        # Direct reclamation (no reaper, or the reaper died mid-shutdown). This
        # is the only place the local path signals processes, and unlike the
        # original single-TERM it escalates TERM->KILL so a busy-looping agent
        # cannot survive.
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
        _kooky_wait=0
        while [ "$_kooky_wait" -lt 5 ]; do
          kill -0 "$_kooky_pid" 2>/dev/null || break
          sleep 1
          _kooky_wait=$((_kooky_wait + 1))
        done
        if kill -0 "$_kooky_pid" 2>/dev/null; then
          kill -KILL "-$_kooky_pgid" 2>/dev/null || kill -KILL "$_kooky_pid" 2>/dev/null || :
        fi
        case "$_kooky_runtime" in
          "$_kooky_base"/"$_kooky_token")
            [ -d "$_kooky_runtime" ] && [ ! -L "$_kooky_runtime" ] &&
              rm -rf -- "$_kooky_runtime"
            ;;
        esac
        exit 0
        """#
    }
}
