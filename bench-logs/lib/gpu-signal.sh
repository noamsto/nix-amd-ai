# shellcheck shell=bash
# GPU bench signal file helpers. Source this; do not execute it. The caller sets SIGNAL_FILE to the file's path before
# calling either function.

# Echo the pid of a live bench other than this process holding the signal file, else nothing. kill -0 fails on EPERM
# too, which still means alive; /proc distinguishes it from ESRCH.
signal_live_holder() {
    local holder
    holder=$(sed -n 1p "$SIGNAL_FILE" 2>/dev/null)
    [[ $holder =~ ^[1-9][0-9]*$ ]] && [ "$holder" != "$$" ] && { kill -0 "$holder" 2>/dev/null || [ -d "/proc/$holder" ]; } && echo "$holder"
}

# Take the file atomically so two benches started seconds apart cannot both hold it: under a lock, link this run's
# temp file into place (fails while any file exists), confirm line 1 is this pid, and on a lost race only proceed when
# the holder is stale (removed, retried once) or refuse. 0 = ours; 2 = a live foreign bench holds it (or both lost).
signal_claim() { # <row label>
    local label=$1 tmp=$SIGNAL_FILE.$$ tries=0 rc=2
    # The stale-file takeover below is check-then-delete, so serialise claimers with a kernel lock; without it two
    # benches finding the same stale file could both discard it and both link a claim. flock is released when this
    # process dies, so the lock file needs no stale cleanup.
    exec 9>>"$SIGNAL_FILE.lock" || return 2
    flock 9 || { exec 9>&-; return 2; }
    while [ "$tries" -lt 2 ]; do
        tries=$((tries + 1))
        printf '%s\n%s\n' "$$" "$label" >"$tmp" || { rm -f "$tmp"; rc=2; break; }
        if ln "$tmp" "$SIGNAL_FILE" 2>/dev/null && [ "$(sed -n 1p "$SIGNAL_FILE" 2>/dev/null)" = "$$" ]; then
            rm -f "$tmp"
            rc=0
            break
        fi
        rm -f "$tmp"
        [ -n "$(signal_live_holder)" ] && { rc=2; break; }
        rm -f "$SIGNAL_FILE" # stale or unparsable holder: drop it and try once more
    done
    flock -u 9 2>/dev/null
    exec 9>&-
    return "$rc"
}
