#!/usr/bin/env bash
# shellcheck disable=SC2154 # bin, port and work come from the sourcing script
# Sourced by ui-train.sh and chat.sh: start Studio on a loopback scratch port, log in, and provide
# `api METHOD PATH` (JSON body on stdin). Credentials never reach argv or stdout; the bearer
# header lives in a 0600 file. The caller must set UNSLOTH_STUDIO_HOME to a scratch install, because
# a first login changes the admin password of that instance.
# Needs: bin, port, work (a scratch dir the caller removes), and calls session_cleanup on exit.

studio_pid=
hdr=
session_cleanup() {
    [ -n "$studio_pid" ] && { kill "$studio_pid" 2>/dev/null; wait "$studio_pid" 2>/dev/null; }
    return 0
}

set_token() { printf 'authorization: Bearer %s\n' "$1" >"$hdr"; }

api() {
    local method=$1 path=$2
    curl -s -X "$method" "localhost:$port$path" -H @"$hdr" -H 'content-type: application/json' -d @-
}

studio_login() {
    [ -n "${UNSLOTH_STUDIO_HOME:-}" ] || { echo "session: set UNSLOTH_STUDIO_HOME to a scratch install" >&2; return 2; }
    if curl -sf "localhost:$port/api/health" >/dev/null; then
        echo "session: port $port already answers" >&2
        return 2
    fi
    hdr=$work/hdr
    (
        umask 077
        : >"$hdr"
    )
    "$bin" studio -H 127.0.0.1 -p "$port" >"$work/studio.log" 2>&1 &
    studio_pid=$!
    local up=
    for _ in $(seq 1 60); do
        curl -sf "localhost:$port/api/health" >/dev/null && { up=1; break; }
        sleep 3
    done
    [ -n "$up" ] || { echo "session: Studio did not come up" >&2; return 1; }

    local boot new tok pw_file=$UNSLOTH_STUDIO_HOME/auth/.probe_password
    if [ -f "$UNSLOTH_STUDIO_HOME/auth/.bootstrap_password" ]; then
        boot=$(cat "$UNSLOTH_STUDIO_HOME/auth/.bootstrap_password") || return 1
        new=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
        tok=$(jq -n --arg p "$boot" '{username:"unsloth",password:($p|rtrimstr("\n"))}' |
            curl -s -X POST "localhost:$port/api/auth/login" -H 'content-type: application/json' -d @- | jq -r .access_token)
        [ -n "$tok" ] && [ "$tok" != null ] || { echo "session: bootstrap login returned no token" >&2; return 1; }
        set_token "$tok"
        tok=$(jq -n --arg c "$boot" --arg n "$new" '{current_password:$c,new_password:$n}' |
            curl -s -X POST "localhost:$port/api/auth/change-password" -H @"$hdr" -H 'content-type: application/json' -d @- | jq -r .access_token)
        [ -n "$tok" ] && [ "$tok" != null ] || { echo "session: password change returned no token" >&2; return 1; }
        (
            umask 077
            printf '%s' "$new" >"$pw_file"
        )
        set_token "$tok"
        return 0
    fi
    # Later runs: the password a previous run stored in the scratch home (0600).
    [ -f "$pw_file" ] || { echo "session: no bootstrap or stored password in the scratch home" >&2; return 1; }
    tok=$(jq -n --rawfile p "$pw_file" '{username:"unsloth",password:($p|rtrimstr("\n"))}' |
        curl -s -X POST "localhost:$port/api/auth/login" -H 'content-type: application/json' -d @- | jq -r .access_token)
    [ -n "$tok" ] && [ "$tok" != null ] || { echo "session: login returned no token" >&2; return 1; }
    set_token "$tok"
}
