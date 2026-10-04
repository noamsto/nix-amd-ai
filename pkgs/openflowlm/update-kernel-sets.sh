#!/usr/bin/env bash
# Regenerate pkgs/openflowlm/kernel-sets.json from the pinned OpenFlowLM-Next
# source. Run this after bumping the openflowlm src pin in default.nix: the
# per-set kernel derivations and the CI matrix read the generated list, and the
# kernels join warns when the source drifts from it.
#
# Usage: update-kernel-sets.sh [SRC_DIR]
#   SRC_DIR defaults to `nix build --no-link --print-out-paths
#   .#openflowlm.passthru.src`.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/../.." && pwd)

if [ "$#" -gt 0 ]; then
  src=$1
else
  src=$(nix build --no-link --print-out-paths "$repo#openflowlm.passthru.src")
fi

if [ ! -d "$src/open_kernels/recipes/specs" ]; then
  echo "error: $src is not an OpenFlowLM-Next source tree" >&2
  exit 1
fi

# Stems, sorted; the join builds the specs in this order.
llm_specs=$(find "$src/open_kernels/recipes/specs" -maxdepth 1 -name '*.json' -printf '%f\n' |
  sed 's/\.json$//' | LC_ALL=C sort)
# Families in families.json order (that is the serial BERT order).
bert_families=$(jq -r '.families[].name' "$src/npu_offload/gemm_rtp/families.json")

llm_json=$(printf '%s\n' "$llm_specs" | jq -R -s 'split("\n") | map(select(length > 0))')
bert_json=$(printf '%s\n' "$bert_families" | jq -R -s 'split("\n") | map(select(length > 0))')

jq -n --argjson llm "$llm_json" --argjson bert "$bert_json" \
  '{llmSpecs: $llm, bertFamilies: $bert}' >"$here/kernel-sets.json"

echo "wrote $here/kernel-sets.json ($(jq '.llmSpecs | length' "$here/kernel-sets.json") LLM specs, $(jq '.bertFamilies | length' "$here/kernel-sets.json") BERT families)"