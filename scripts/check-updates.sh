#!/usr/bin/env bash
# Check upstream repos for new versions and output update status.
# Outputs GitHub Actions variables via GITHUB_OUTPUT.
set -euo pipefail

FLM_LATEST=$(gh api repos/ROCm/FastFlowLM/releases/latest --jq '.tag_name' | sed 's/^v//')
LEM_LATEST=$(gh api repos/lemonade-sdk/lemonade/releases/latest --jq '.tag_name' | sed 's/^v//')
XDNA_LATEST=$(gh api "repos/amd/xdna-driver/commits?sha=1.7&per_page=1" --jq '.[0].sha')
# vLLM-ROCm cuts one release per gfx target, so `releases/latest` returns
# whichever target shipped last — routinely one we don't consume (gfx950,
# gfx942). Its base tag may have no build for our targets at all, which then
# 404s at prefetch time and downgrades the pin. Walk releases newest-first and
# take the first base tag built for every target sources.nix consumes.
mapfile -t VLLM_TARGETS < <(sed -n 's/^  \(gfx[0-9a-zA-Z]*\) = {$/\1/p' pkgs/vllm-rocm/sources.nix)
VLLM_TAGS=$(gh api "repos/lemonade-sdk/vllm-rocm/releases?per_page=100" \
  --jq '.[] | select(.draft | not) | .tag_name')
VLLM_LATEST=""
while read -r base; do
  for target in "${VLLM_TARGETS[@]}"; do
    grep -qxF "${base}-${target}" <<<"$VLLM_TAGS" || continue 2
  done
  VLLM_LATEST="$base"
  break
done < <(sed -n 's/-gfx[^-]*$//p' <<<"$VLLM_TAGS" | awk '!seen[$0]++')

if [ -z "$VLLM_LATEST" ]; then
  echo "ERROR: no vllm-rocm release covers all targets: ${VLLM_TARGETS[*]}" >&2
  exit 1
fi

FLM_CURRENT=$(grep 'version = ' pkgs/fastflowlm/default.nix | head -1 | sed 's/.*"\(.*\)".*/\1/')
LEM_CURRENT=$(sed -n 's/.*"\(.*\)".*/\1/p' pkgs/lemonade/version.nix | head -1)
XDNA_CURRENT=$(grep 'rev = ' pkgs/xrt-plugin-amdxdna/default.nix | head -1 | sed 's/.*"\(.*\)".*/\1/')
VLLM_CURRENT=$(grep 'releaseTag = ' pkgs/vllm-rocm/sources.nix | head -1 | sed 's/.*"\(.*\)".*/\1/; s/-gfx[^-]*$//')

NEEDS_UPDATE=false
[ "$FLM_LATEST" != "$FLM_CURRENT" ] && NEEDS_UPDATE=true
[ "$LEM_LATEST" != "$LEM_CURRENT" ] && NEEDS_UPDATE=true
[ "$XDNA_LATEST" != "$XDNA_CURRENT" ] && NEEDS_UPDATE=true
VLLM_NEEDS_UPDATE=false
[ "$VLLM_LATEST" != "$VLLM_CURRENT" ] && VLLM_NEEDS_UPDATE=true
[ "$VLLM_LATEST" != "$VLLM_CURRENT" ] && NEEDS_UPDATE=true

echo "FLM: $FLM_CURRENT -> $FLM_LATEST"
echo "Lemonade: $LEM_CURRENT -> $LEM_LATEST"
echo "XDNA: $XDNA_CURRENT -> $XDNA_LATEST"
echo "vLLM-ROCm: $VLLM_CURRENT -> $VLLM_LATEST"

# nixpkgs lock vs nixos-unstable HEAD. We surface diffs for the six backend
# packages we consume (Lemonade pins their versions into backend_versions.json
# at build time, so movement here is user-visible).
NIXPKGS_CURRENT_REV=$(jq -r '.nodes.nixpkgs.locked.rev' flake.lock)
NIXPKGS_LATEST_REV=$(gh api repos/NixOS/nixpkgs/branches/nixos-unstable --jq '.commit.sha')
NIXPKGS_NEEDS_UPDATE=false
NIXPKGS_BACKEND_DIFFS=""
if [ "$NIXPKGS_CURRENT_REV" != "$NIXPKGS_LATEST_REV" ]; then
  NIXPKGS_NEEDS_UPDATE=true
  NEEDS_UPDATE=true
  echo "nixpkgs: ${NIXPKGS_CURRENT_REV:0:12} -> ${NIXPKGS_LATEST_REV:0:12}"
  for pkg in llama-cpp-rocm llama-cpp-vulkan whisper-cpp whisper-cpp-vulkan stable-diffusion-cpp stable-diffusion-cpp-rocm; do
    cur=$(nix eval --raw "github:NixOS/nixpkgs/${NIXPKGS_CURRENT_REV}#${pkg}.version" 2>/dev/null || echo "?")
    new=$(nix eval --raw "github:NixOS/nixpkgs/${NIXPKGS_LATEST_REV}#${pkg}.version" 2>/dev/null || echo "?")
    if [ "$cur" != "$new" ]; then
      echo "  $pkg: $cur -> $new"
      NIXPKGS_BACKEND_DIFFS+="- ${pkg}: ${cur} -> ${new}"$'\n'
    fi
  done
fi

# Cross-check llamaCppMtpOverride against Lemonade's backend_versions.json
# (llamacpp.vulkan). Our flake pin must match for MTP to light up; nixpkgs
# catching up to that pin means we can drop the override entirely.
MTP_OVERRIDE_NEEDS_UPDATE=false
MTP_CLEANUP=false
MTP_REQUIRED=""
MTP_CURRENT=""
if grep -q "llamaCppMtpOverride" flake.nix; then
  MTP_CURRENT=$(grep -A1 'LLAMA_BUILD_NUMBER' flake.nix | grep 'version =' | sed 's/.*"\([0-9]*\)".*/\1/')
  MTP_REQUIRED=$(gh api "repos/lemonade-sdk/lemonade/contents/src/cpp/resources/backend_versions.json?ref=v${LEM_LATEST}" \
    -H "Accept: application/vnd.github.v3.raw" \
    --jq '.llamacpp.vulkan' 2>/dev/null | sed 's/^b//')

  if [ -n "$MTP_REQUIRED" ] && [ -n "$MTP_CURRENT" ] && [ "$MTP_REQUIRED" != "$MTP_CURRENT" ]; then
    MTP_OVERRIDE_NEEDS_UPDATE=true
    NEEDS_UPDATE=true
    echo "MTP override: b${MTP_CURRENT} -> b${MTP_REQUIRED} (lemonade v${LEM_LATEST} pins llamacpp.vulkan)"
  fi

  llamacpp_new=$(nix eval --raw "github:NixOS/nixpkgs/${NIXPKGS_LATEST_REV}#llama-cpp-rocm.version" 2>/dev/null || echo "")
  llamacpp_num="${llamacpp_new%%-*}"
  if [ -n "$MTP_REQUIRED" ] && [[ "$llamacpp_num" =~ ^[0-9]+$ ]] && [ "$llamacpp_num" -ge "$MTP_REQUIRED" ]; then
    MTP_CLEANUP=true
  fi
fi

# gaia is a uvx wrapper: no hash to prefetch, and it builds green whatever
# version it names, so nothing already here would ever notice it going stale.
# The console scripts it re-exports are version-dependent — 0.21.0 dropped
# gaia-emr and gaia-code — so report the script list alongside the version. A
# version-only bump would ship wrappers for entry points that no longer exist.
GAIA_CURRENT=$(sed -n 's/^  version = "\(.*\)";$/\1/p' pkgs/gaia/default.nix | head -1)
GAIA_SCRIPTS_CURRENT=$(sed -n 's/^  bins = \[\(.*\)\];$/\1/p' pkgs/gaia/default.nix \
  | tr -d '"' | tr ' ' '\n' | grep -v '^$' | sort | paste -sd' ' -)
GAIA_LATEST=$(curl -fsSL https://pypi.org/pypi/amd-gaia/json | jq -r '.info.version')

# Read the entry points from the published wheel rather than from the
# changelog: the wheel is what uvx installs at run time.
GAIA_WHEEL=$(mktemp -u /tmp/gaia-XXXXXX.whl)
curl -fsSL "$(curl -fsSL "https://pypi.org/pypi/amd-gaia/${GAIA_LATEST}/json" \
  | jq -r 'first(.urls[] | select(.filename | endswith(".whl")) | .url)')" -o "$GAIA_WHEEL"
GAIA_SCRIPTS_LATEST=$(unzip -p "$GAIA_WHEEL" '*.dist-info/entry_points.txt' \
  | awk '/^\[console_scripts\]/{f=1;next} /^\[/{f=0} f && /=/{sub(/=.*/,""); gsub(/[ \t]/,""); if ($0) print}' \
  | sort | paste -sd' ' -)
rm -f "$GAIA_WHEEL"

GAIA_NEEDS_UPDATE=false
if [ "$GAIA_LATEST" != "$GAIA_CURRENT" ] || [ "$GAIA_SCRIPTS_LATEST" != "$GAIA_SCRIPTS_CURRENT" ]; then
  GAIA_NEEDS_UPDATE=true
  NEEDS_UPDATE=true
  echo "gaia: $GAIA_CURRENT -> $GAIA_LATEST"
  [ "$GAIA_SCRIPTS_LATEST" != "$GAIA_SCRIPTS_CURRENT" ] \
    && echo "  console scripts: [$GAIA_SCRIPTS_CURRENT] -> [$GAIA_SCRIPTS_LATEST]"
fi

# Everything above came from an upstream release tag or from names read out of
# a published wheel, and it flows on into sed expressions in bump-versions.sh
# and into the PR body. Git tag names and wheel entry-point names are far more
# permissive than either consumer assumes: a / or & silently corrupts the sed,
# and $(...) or a backtick reaches a shell. Refuse anything outside a
# conservative charset rather than pass it along.
reject_odd() {
  [[ "$2" =~ ^[A-Za-z0-9._+-]+$ ]] || {
    echo "ERROR: unexpected characters in $1: $2" >&2
    exit 1
  }
}
reject_odd_list() {
  [[ "$2" =~ ^([A-Za-z0-9._+-]+( [A-Za-z0-9._+-]+)*)?$ ]] || {
    echo "ERROR: unexpected characters in $1: $2" >&2
    exit 1
  }
}

reject_odd FLM_LATEST "$FLM_LATEST"
reject_odd LEM_LATEST "$LEM_LATEST"
reject_odd XDNA_LATEST "$XDNA_LATEST"
reject_odd VLLM_LATEST "$VLLM_LATEST"
reject_odd GAIA_LATEST "$GAIA_LATEST"
reject_odd_list GAIA_SCRIPTS_LATEST "$GAIA_SCRIPTS_LATEST"
[ -z "$MTP_REQUIRED" ] || reject_odd MTP_REQUIRED "$MTP_REQUIRED"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "flm_latest=$FLM_LATEST"
    echo "lem_latest=$LEM_LATEST"
    echo "xdna_latest=$XDNA_LATEST"
    echo "vllm_latest=$VLLM_LATEST"
    echo "flm_current=$FLM_CURRENT"
    echo "lem_current=$LEM_CURRENT"
    echo "xdna_current=$XDNA_CURRENT"
    echo "vllm_current=$VLLM_CURRENT"
    echo "needs_update=$NEEDS_UPDATE"
    echo "vllm_needs_update=$VLLM_NEEDS_UPDATE"
    echo "nixpkgs_needs_update=$NIXPKGS_NEEDS_UPDATE"
    echo "mtp_cleanup=$MTP_CLEANUP"
    echo "mtp_override_needs_update=$MTP_OVERRIDE_NEEDS_UPDATE"
    echo "mtp_required=$MTP_REQUIRED"
    echo "mtp_current=$MTP_CURRENT"
    echo "gaia_current=$GAIA_CURRENT"
    echo "gaia_latest=$GAIA_LATEST"
    echo "gaia_needs_update=$GAIA_NEEDS_UPDATE"
    echo "gaia_scripts_current=$GAIA_SCRIPTS_CURRENT"
    echo "gaia_scripts_latest=$GAIA_SCRIPTS_LATEST"
    # Multi-line output needs the heredoc form (GitHub Actions docs). Random
    # delimiter: the content is nix-eval output, and a line equal to a fixed
    # delimiter would close the block early and let the rest write arbitrary
    # step outputs -- same reason the flake-check log uses one in update.yml.
    nixpkgs_delim="NIXPKGS_EOF_$(openssl rand -hex 16)"
    echo "nixpkgs_backend_diffs<<$nixpkgs_delim"
    printf '%s' "$NIXPKGS_BACKEND_DIFFS"
    echo "$nixpkgs_delim"
  } >> "$GITHUB_OUTPUT"
fi
