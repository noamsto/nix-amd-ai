#!/usr/bin/env bash
# Re-take of the Qwen3.8-Flash-Next MTP tuning grid, one JSON line per row.
#
# Usage (from the repo root):
#   SERVER_VULKAN=... SERVER_ROCM=... TARGET=... DRAFT=... [OUT=./retake.jsonl] \
#       bench-logs/qwen38-flash-next-mtp-tuning-2026-10-04/retake.sh
#
# Exit 2 (foreign benchmark process) or 3 (low memory) from grid.py aborts the
# script; any other row failure is logged to OUT as a marker line and skipped.
# OUT must not already exist. Every row goes through grid.py, which waits up to 30 min for loadavg < 2 and
# flags the row (load_flag) if the load never settled. The GPU memory must be
# free of other resident models, or rows fail or measure the wrong thing.
set -u

: "${SERVER_VULKAN:?set SERVER_VULKAN}"
: "${SERVER_ROCM:?set SERVER_ROCM}"
: "${TARGET:?set TARGET}"
: "${DRAFT:?set DRAFT}"
OUT=${OUT:-./retake.jsonl}
case $OUT in /*) ;; *) OUT=$PWD/$OUT ;; esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRID="$HERE/grid.py"
ROOT=$(git -C "$HERE" rev-parse --show-toplevel) || exit 1
cd "$ROOT" || exit 1

for bin in "$SERVER_VULKAN" "$SERVER_ROCM"; do
    [ -x "$bin" ] || { echo "not an executable: $bin" >&2; exit 1; }
done
for f in "$TARGET" "$DRAFT" "$GRID"; do
    [ -f "$f" ] || { echo "not a file: $f" >&2; exit 1; }
done
if [ -s "$OUT" ]; then
    echo "$OUT already exists and is non-empty; move it aside first" >&2
    exit 1
fi
printf '{"run": "%s", "git_sha": "%s"}\n' "$(date -u)" "$(git rev-parse --short HEAD)" >"$OUT" || exit 1

row() {
    local backend=$1 server=$2 rc
    shift 2
    python3 "$GRID" row --server "$server" --target "$TARGET" --draft "$DRAFT" \
        --backend "$backend" --corpus-glob-root "$ROOT" "$@" >>"$OUT"
    rc=$?
    case $rc in
    0) ;;
    2 | 3)
        echo "aborting: grid.py exit $rc on row: $backend $*" >&2
        exit "$rc"
        ;;
    *)
        echo "row failed (exit $rc): $backend $*" >&2
        printf '{"error":"exit %s","row":"%s %s"}\n' "$rc" "$backend" "$*" >>"$OUT"
        ;;
    esac
}

vulkan() { row vulkan "$SERVER_VULKAN" "$@"; }
rocm() { row rocm "$SERVER_ROCM" "$@"; }

# A. Vulkan clean re-take: baseline before each config, round 2 in reversed order
cfgs=(3:0 3:0.6 4:0.75 5:0.75 3:0.75)
for round in 1 2; do
    if [ "$round" = 2 ]; then
        rev=()
        for ((i = ${#cfgs[@]} - 1; i >= 0; i--)); do rev+=("${cfgs[i]}"); done
        order=("${rev[@]}")
    else
        order=("${cfgs[@]}")
    fi
    for cfg in "${order[@]}"; do
        vulkan --spec none --label "A-r$round-base-before-$cfg"
        vulkan --spec draft-mtp --nmax "${cfg%:*}" --pmin "${cfg#*:}" --label "A-r$round-mtp-$cfg"
    done
done

# B. Vulkan, n-max 3 / no p-min
vulkan --spec none --parallel auto --label B-par-auto-off
vulkan --spec draft-mtp --nmax 3 --pmin 0 --parallel auto --label B-par-auto-mtp
vulkan --spec none --fa off --label B-fa-off-off
vulkan --spec draft-mtp --nmax 3 --pmin 0 --fa off --label B-fa-off-mtp
vulkan --spec none --fa on --ctk f16 --ctv f16 --label B-fa-on-f16kv-off
vulkan --spec draft-mtp --nmax 3 --pmin 0 --fa on --ctk f16 --ctv f16 --label B-fa-on-f16kv-mtp
vulkan --spec none --depth 32768 --label B-d32768-off
vulkan --spec draft-mtp --nmax 3 --pmin 0 --depth 32768 --label B-d32768-mtp

# C. ROCm
rocm --spec none --depth 512 --label C-d512-off
rocm --spec draft-mtp --nmax 3 --pmin 0 --depth 512 --label C-d512-mtp
rocm --spec none --fa off --label C-fa-off-off
rocm --spec draft-mtp --nmax 3 --pmin 0 --fa off --label C-fa-off-mtp
rocm --spec none --fa on --ctk f16 --ctv f16 --label C-fa-on-f16kv-off
rocm --spec draft-mtp --nmax 3 --pmin 0 --fa on --ctk f16 --ctv f16 --label C-fa-on-f16kv-mtp
for depth in 8192 32768; do
    rocm --spec none --depth "$depth" --label "C-d$depth-off"
    rocm --spec draft-mtp --nmax 3 --pmin 0 --depth "$depth" --label "C-d$depth-mtp"
done

# D. Vulkan (3,0): residency, ngram-mod, tool call
vulkan --spec none --residency --label D-residency-off
vulkan --spec draft-mtp --nmax 3 --pmin 0 --residency --label D-residency
vulkan --spec draft-mtp --nmax 3 --pmin 0 --ngram-mod --residency --label D-ngram-mod-residency
vulkan --spec draft-mtp --nmax 3 --pmin 0 --tool-call --label D-tool-call

# E. Vulkan controls, n-max 3 / no p-min: f16 KV with FA on, default threads
vulkan --spec none --threads -1 --label E-threads-auto-off
vulkan --spec draft-mtp --nmax 3 --pmin 0 --threads -1 --label E-threads-auto-mtp
