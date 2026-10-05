#!/usr/bin/env bash
# Run rows 1-3 against a Strix Halo host's lemond-managed Qwen3.8-Flash-Next.
#
# Usage (repo root): SERVER=... TARGET=... DRAFT=... CORPUS_REV=<sha> OUT=rows.jsonl \
#     bench-logs/qwen38-flash-next-lazy-ub-pmin-2026-10-05/run.sh [row1|row2|row3]...
#
# Unloads Qwen3.8-Flash-Next-MTP from lemond's HTTP API first (two copies do not fit) and
# reloads it on every exit path (KEEP_OFFLINE=1 skips the reload after a run in which every row succeeded, so a
# later invocation can continue offline; the last one must not set it). ROW2_LAZY (on|auto) is the lazy setting row 2 and 3 use.
set -u
: "${SERVER:?}" "${TARGET:?}" "${DRAFT:?}" "${CORPUS_REV:?}" "${OUT:?}"
ROW2_LAZY=${ROW2_LAZY:-auto}
LEMOND=http://127.0.0.1:13305/api/v1
MODEL=Qwen3.8-Flash-Next-MTP
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT=$(git -C "$HERE" rev-parse --show-toplevel) || exit 1
cd "$ROOT" || exit 1

post() { curl -sS -X POST "$LEMOND/$1" -H 'Content-Type: application/json' -d "$2"; }
loaded() { curl -sS "$LEMOND/health" | jq -r '.all_models_loaded | length'; }

reload() {
    local rc=$?
    [ "${KEEP_OFFLINE:-0}" = 1 ] && [ "$rc" = 0 ] && [ "$rows_ok" = 1 ] && return
    local n
    n=$(loaded) || n=
    case $n in '' | 0) ;; *) return ;; esac
    post load "{\"model_name\":\"$MODEL\"}" >&2 || echo "reload: POST /load failed" >&2
    echo >&2
    curl -sS "$LEMOND/health" | jq '{model_loaded, pinned_models, loaded: [.all_models_loaded[] | {model_name, status, pinned}]}' >&2
}
rows_ok=1
trap reload EXIT

row() {
    python3 "$HERE/probe.py" --server "$SERVER" --target "$TARGET" --draft "$DRAFT" \
        --corpus-root "$ROOT" --corpus-rev "$CORPUS_REV" "$@" >>"$OUT"
    local rc=$?
    case $rc in
    0) ;;
    2 | 3) echo "aborting: probe.py exit $rc: $*" >&2; exit "$rc" ;;
    *) echo "row failed (exit $rc): $*" >&2; rows_ok=0 ;;
    esac
}

if [ "$(loaded)" != 0 ]; then
    post unload "{\"model_name\":\"$MODEL\"}" >&2
    echo >&2
fi
[ "$(loaded)" = 0 ] || { echo "lemond still has a model loaded" >&2; exit 1; }

[ $# -gt 0 ] || set -- row1 row2 row3
for r in "$@"; do
    case $r in
    row1)
        row --label row1-baseline
        row --label row1-lazy-on --lazy on
        ;;
    row2)
        row --label row2-pmin0 --lazy "$ROW2_LAZY" --do prose
        row --label row2-pmin0.6 --lazy "$ROW2_LAZY" --pmin 0.6 --do prose
        ;;
    row3)
        row --label row3-ub-default --lazy "$ROW2_LAZY" --do decode512,prefill4k,decode32k
        row --label row3-ub2048 --lazy "$ROW2_LAZY" --ub 2048 --batch 2048 --do decode512,prefill4k,decode32k
        row --label row3-ub4096 --lazy "$ROW2_LAZY" --ub 4096 --batch 4096 --do decode512,prefill4k,decode32k
        ;;
    esac
done
