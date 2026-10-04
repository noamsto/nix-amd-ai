#!/usr/bin/env bash
# Interleaved old-vs-new llama-bench matrix for the llama.cpp pin bump.
#
# Each round runs old then new back-to-back for every model/backend, so host
# drift hits both arms alike. Old arm = this flake at rev 81ffca6 (b11207);
# new arm = the current tree (b11382).
#
# Env:
#   OLD_VULKAN_BIN OLD_ROCM_BIN NEW_VULKAN_BIN NEW_ROCM_BIN  llama-bench paths
#   M27B FLASH GPTOSS                                        GGUF paths
#   ROUNDS  interleaved rounds (default 3)
#   R       llama-bench repetitions per run (default 3)
#   OUT     log/JSON directory (default ./old-vs-new-out)
#
# Per-run output: $OUT/<label>.rN.log (full output incl. the "build:" line,
# the only in-band proof of which pin ran) and $OUT/<label>.rN.json.
# Exits non-zero if any run fails.
set -uo pipefail

: "${OLD_VULKAN_BIN:?}"; : "${OLD_ROCM_BIN:?}"; : "${NEW_VULKAN_BIN:?}"; : "${NEW_ROCM_BIN:?}"
: "${M27B:?}"; : "${FLASH:?}"; : "${GPTOSS:?}"
ROUNDS="${ROUNDS:-3}"
R="${R:-3}"
OUT="${OUT:-./old-vs-new-out}"
mkdir -p "$OUT"
rc=0

run() { # label round bin model
  local base="$OUT/$1.r$2"
  echo "=== $1 round $2 ==="
  if ! "$3" --model "$4" -ngl 99 -r "$R" -p 512 -n 128 -o json >"$base.json" 2>"$base.log"; then
    echo "FAILED: $1 round $2 (see $base.log)" >&2
    rc=1
    return
  fi
  grep -E '^build:' "$base.log"
  jq -r '.[] | "\(.n_prompt)/\(.n_gen) avg_ts=\(.avg_ts) sd=\(.stddev_ts) build=\(.build_commit)"' "$base.json"
}

for round in $(seq 1 "$ROUNDS"); do
  for cfg in \
    "27b-vulkan $NEW_VULKAN_BIN $OLD_VULKAN_BIN $M27B" \
    "27b-rocm $NEW_ROCM_BIN $OLD_ROCM_BIN $M27B" \
    "flash-vulkan $NEW_VULKAN_BIN $OLD_VULKAN_BIN $FLASH" \
    "flash-rocm $NEW_ROCM_BIN $OLD_ROCM_BIN $FLASH" \
    "gptoss-vulkan $NEW_VULKAN_BIN $OLD_VULKAN_BIN $GPTOSS"; do
    read -r name new old model <<<"$cfg"
    run "old-$name" "$round" "$old" "$model"
    run "new-$name" "$round" "$new" "$model"
  done
done

python3 - "$OUT" "$ROUNDS" <<'PY'
import glob, json, os, statistics as st, sys

out, rounds = sys.argv[1], int(sys.argv[2])
labels = sorted({os.path.basename(f).split(".r")[0][4:] for f in glob.glob(f"{out}/old-*.json")})
print("\nconfig                 test   old med    new med    delta   paired mean old / new")
for lab in labels:
    for test in ("pp512", "tg128"):
        old, new = [], []
        for r in range(1, rounds + 1):
            try:
                pair = []
                for arm in ("old", "new"):
                    with open(f"{out}/{arm}-{lab}.r{r}.json") as fh:
                        rec = [x for x in json.load(fh) if (x["n_prompt"] and x["n_gen"] == 0) == (test == "pp512")][0]
                    pair.append(rec["avg_ts"])
            except (OSError, IndexError):
                continue
            old.append(pair[0])
            new.append(pair[1])
        if not old:
            continue
        mo, mn = st.median(old), st.median(new)
        print(f"{lab:<22} {test}  {mo:9.2f}  {mn:9.2f}  {100 * (mn - mo) / mo:+6.1f}%   "
              f"{st.mean(old):.2f} / {st.mean(new):.2f}")
PY
exit "$rc"
