import Foundation

/// POSIX sh scripts executed on the remote host. They rely only on sh, awk, ps, mv, find and base64.
public enum RemoteRunScripts {
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    private static func runDirAssignment(_ runId: String) -> String {
        #"R="$HOME/.minis/runs/"\#(shellQuote(runId))"#
    }

    public static func launch(runId: String, workdir: String, commandBase64: String) -> String {
        """
        \(runDirAssignment(runId))
        mkdir -p "$R" || exit 96
        cd \(shellQuote(workdir)) || exit 97
        printf '%s' \(shellQuote(commandBase64)) > "$R/cmd.b64"
        base64 -d < "$R/cmd.b64" > "$R/cmd" 2>/dev/null || base64 -D < "$R/cmd.b64" > "$R/cmd" 2>/dev/null
        if [ $? -ne 0 ] || { [ -s "$R/cmd.b64" ] && [ ! -s "$R/cmd" ]; }; then echo "minis: cannot decode command" >&2; exit 98; fi
        rm -f "$R/cmd.b64"
        case "${SHELL##*/}" in
          sh|bash|zsh|dash|ksh|ash) S="$SHELL" ;;
          *) S=/bin/sh ;;
        esac
        export R
        if ! mkdir "$R/started" 2>/dev/null || [ -e "$R/exit" ]; then echo "minis: run was cancelled before it started" >&2; exit 95; fi
        nohup "$S" -lc '( . "$R/cmd" ); echo $? > "$R/exit.tmp"; mv "$R/exit.tmp" "$R/exit"' </dev/null >"$R/out" 2>&1 &
        echo $! > "$R/pid.tmp" && mv "$R/pid.tmp" "$R/pid"

        """
    }

    public static func readChunk(runId: String, offset: Int, maxBytes: Int) -> String {
        """
        \(runDirAssignment(runId))
        tail -c +\(offset + 1) "$R/out" 2>/dev/null | head -c \(maxBytes)

        """
    }

    public static func status(runId: String) -> String {
        """
        \(runDirAssignment(runId))
        if [ -f "$R/exit" ]; then
          cat "$R/exit"
        elif kill -0 "$(cat "$R/pid" 2>/dev/null)" 2>/dev/null; then
          echo "running 1"
        elif [ -f "$R/exit" ]; then
          cat "$R/exit"
        else
          echo "running 0"
        fi

        """
    }

    public static func cancelTree(runId: String, signal: String) -> String {
        """
        \(runDirAssignment(runId))
        sig=\(shellQuote(signal))
        root=$(cat "$R/pid" 2>/dev/null)
        if [ -z "$root" ]; then echo 0; exit 0; fi
        table=$(ps -A -o pid= -o ppid= 2>/dev/null || ps -o pid= -o ppid=)
        all=$root; frontier=$root
        while [ -n "$frontier" ]; do
          next=""; for p in $frontier; do kids=$(printf '%s\\n' "$table" | awk -v p="$p" '$2==p {print $1}'); next="$next $kids"; done
          frontier=$(echo $next); all="$all $frontier"
        done
        if [ "$sig" = KILL ]; then
          for p in $(cat "$R/tree" 2>/dev/null); do
            case " $all " in *" $p "*) continue ;; esac
            printf '%s\\n' "$table" | awk -v p="$p" '$1==p {f=1} END {exit !f}' && all="$all $p"
          done
        else
          echo $all > "$R/tree"
        fi
        n=0; for p in $all; do kill -"$sig" "$p" 2>/dev/null && n=$((n+1)); done; echo "$n"

        """
    }

    /// Creates the run directory so a cancel that lands before the launch leaves the exit file the launcher
    /// refuses to start over.
    private static let markCancelled =
        #"mkdir -p "$R" && printf cancelled > "$R/exit.tmp" && mv "$R/exit.tmp" "$R/exit""#

    public static func writeCancelled(runId: String) -> String {
        """
        \(runDirAssignment(runId))
        \(markCancelled)

        """
    }

    /// For a launch whose reply was lost. The launcher and the claim race for the atomic `mkdir "$R/started"`,
    /// so exactly one of them proceeds. Winning marks the run cancelled and prints `claimed`; losing waits for
    /// the launcher's `pid` and prints `launched`, or `claimed` when an earlier claim already won. No output
    /// means the launcher took the token but wrote no `pid` in time, so the outcome is unknown.
    public static func claimUnlaunched(runId: String) -> String {
        """
        \(runDirAssignment(runId))
        if mkdir -p "$R" && mkdir "$R/started" 2>/dev/null; then \(markCancelled) && echo claimed; exit 0; fi
        [ -d "$R/started" ] || exit 1
        i=0
        while [ $i -lt 5 ]; do
          if [ -f "$R/pid" ]; then echo launched; exit 0; fi
          if [ -f "$R/exit" ]; then echo claimed; exit 0; fi
          sleep 1; i=$((i+1))
        done

        """
    }

    public static let retention: String =
        #"find "$HOME/.minis/runs" -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} + 2>/dev/null; true"# + "\n"
}
