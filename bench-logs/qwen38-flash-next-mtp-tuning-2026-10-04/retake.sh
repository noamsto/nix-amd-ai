#!/usr/bin/env bash
# Re-take of the Qwen3.8-Flash-Next MTP tuning grid, one JSON line per row.
#
# Usage (from the repo root):
#   SERVER_VULKAN=... SERVER_ROCM=... TARGET=... DRAFT=... [OUT=./retake.jsonl] \
#       bench-logs/qwen38-flash-next-mtp-tuning-2026-10-04/retake.sh
#
# Every row goes through grid.py, which waits up to 30 min for loadavg < 2 and
# flags the row (load_flag) if the load never settled. The GPU memory must be
# free of other resident models, or rows fail or measure the wrong thing.
set -u

: "${SERVER_VULKAN:?set SERVER_VULKAN}"
: "${SERVER_ROCM:?set SERVER_ROCM}"
: "${TARGET:?set TARGET}"
: "${DRAFT:?set DRAFT}"
OUT=${OUT:-./retake.jsonl}

GRID="$(dirname "${BASH_SOURCE[0]}")/grid.py"

row() {
    local backend=$1 server=$2
    shift 2
    python3 "$GRID" row --server "$server" --target "$TARGET" --draft "$DRAFT" \
        --backend "$backend" "$@" >>"$OUT" || echo "row failed (exit $?): $backend $*" >&2
}

vulkan() { row vulkan "$SERVER_VULKAN" "$@"; }
rocm() { row rocm "$SERVER_ROCM" "$@"; }

# A. Vulkan clean re-take, two interleaved rounds
for round in 1 2; do
    vulkan --spec none --label "A-r$round-base"
    for cfg in 3:0 3:0.6 4:0.75 5:0.75 3:0.75; do
        vulkan --spec draft-mtp --nmax "${cfg%:*}" --pmin "${cfg#*:}" --label "A-r$round-mtp-$cfg"
    done
done

# B. Vulkan, n-max 3 / no p-min
vulkan --spec none --parallel auto --label B-par-auto-off
vulkan --spec draft-mtp --nmax 3 --pmin 0 --parallel auto --label B-par-auto-mtp
vulkan --spec none --fa off --label B-fa-off-off
vulkan --spec draft-mtp --nmax 3 --pmin 0 --fa off --label B-fa-off-mtp
vulkan --spec none --depth 32768 --label B-d32768-off
vulkan --spec draft-mtp --nmax 3 --pmin 0 --depth 32768 --label B-d32768-mtp

# C. ROCm
rocm --spec none --depth 512 --label C-d512-off
rocm --spec draft-mtp --nmax 3 --pmin 0 --depth 512 --label C-d512-mtp
rocm --spec none --fa off --label C-fa-off-off
rocm --spec draft-mtp --nmax 3 --pmin 0 --fa off --label C-fa-off-mtp
for depth in 8192 32768; do
    rocm --spec none --depth "$depth" --label "C-d$depth-off"
    rocm --spec draft-mtp --nmax 3 --pmin 0 --depth "$depth" --label "C-d$depth-mtp"
done

# D. Vulkan (3,0): residency, ngram-mod, tool call
vulkan --spec draft-mtp --nmax 3 --pmin 0 --residency --label D-residency
vulkan --spec draft-mtp --nmax 3 --pmin 0 --ngram-mod --residency --label D-ngram-mod-residency
vulkan --spec draft-mtp --nmax 3 --pmin 0 --tool-call --label D-tool-call
