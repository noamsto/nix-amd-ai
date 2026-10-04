#!/usr/bin/env bash
# Emit the kernel-set execution plan for a source tree against the committed
# set list. The openflowlm-kernels join executes this plan, so the tree it
# produces is the serial build's; the openflowlm-kernel-sets-drift flake check
# exercises the same plan with a doctored list in both drift directions.
#
# Usage: kernel-sets-plan.sh SRC_DIR SETS_JSON
#
# Lines, in the order the monolithic export builds them:
#   COPY-LLM  <stem>   listed and present in src -> the join copies its drv
#   BUILD-LLM <stem>   present in src, not listed -> the join builds it inline
#   COPY-BERT <name> / BUILD-BERT <name>          (BERT, families.json order)
#   SKIP-LLM  <stem> / SKIP-BERT <name>           listed but absent from src
# Always exits 0: drift is recoverable, never fatal.
set -euo pipefail

src=$1
sets=$2

listed_llm=$(jq -r '.llmSpecs[]' "$sets" | LC_ALL=C sort)
listed_bert=$(jq -r '.bertFamilies[]' "$sets" | LC_ALL=C sort)

# Sort the *.json filenames before stripping, matching the serial
# sorted(SPECS_DIR.glob('*.json')) order (see update-kernel-sets.sh).
src_llm=$(find "$src/open_kernels/recipes/specs" -maxdepth 1 -name '*.json' -printf '%f\n' |
  LC_ALL=C sort | sed 's/\.json$//')
src_bert=$(jq -r '.families[].name' "$src/npu_offload/gemm_rtp/families.json")

while IFS= read -r name; do
  [ -n "$name" ] || continue
  if grep -qxF "$name" <<<"$listed_llm"; then
    echo "COPY-LLM $name"
  else
    echo "BUILD-LLM $name"
  fi
done <<<"$src_llm"

while IFS= read -r name; do
  [ -n "$name" ] || continue
  if grep -qxF "$name" <<<"$listed_bert"; then
    echo "COPY-BERT $name"
  else
    echo "BUILD-BERT $name"
  fi
done <<<"$src_bert"

while IFS= read -r name; do
  [ -n "$name" ] || continue
  grep -qxF "$name" <<<"$src_llm" || echo "SKIP-LLM $name"
done <<<"$listed_llm"

while IFS= read -r name; do
  [ -n "$name" ] || continue
  grep -qxF "$name" <<<"$src_bert" || echo "SKIP-BERT $name"
done <<<"$listed_bert"