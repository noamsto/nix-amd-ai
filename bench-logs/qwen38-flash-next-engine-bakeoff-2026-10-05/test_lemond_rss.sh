#!/usr/bin/env bash
# lemond_rss (run.sh) sums RssAnon over lemond's whole process tree, not only its direct children.
set -eu
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
eval "$(sed -n '/^lemond_rss() {/,/^}/p' "$(dirname "$0")/run.sh")"
# a descendant listed before its parent (pid wraparound): the multi-pass walk must still find it
ps() { printf '%s\n' '9 14 late' '10 1 lemond' '11 10 wrapper' '12 11 llamacpp-rocm' '13 1 other' '14 12 helper'; }
for p in 9:32 10:1 11:2 12:4 13:8 14:16; do
    mkdir -p "$d/${p%%:*}"
    printf 'Name:\tx\nVmRSS:\t999999 kB\nRssAnon:\t%s kB\n' "${p##*:}" >"$d/${p%%:*}/status"
done
got=$(PROC_ROOT=$d lemond_rss)
want=$(((2 + 4 + 16 + 32) * 1024))
[ "$got" = "$want" ] || { echo "FAIL: lemond_rss $got, want $want" >&2; exit 1; }
echo "ok: descendants of lemond summed ($got bytes)"
