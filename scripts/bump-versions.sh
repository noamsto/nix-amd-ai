#!/usr/bin/env bash
# Bump package versions in derivation files.
# Usage: bump-versions.sh <flm_new> <flm_old> <lem_new> <lem_old> <xdna_new> <xdna_old> [vllm_new] [vllm_old]
# vllm_new/old are the gfx-stripped base release tags (see check-updates.sh).
set -euo pipefail

FLM_NEW="$1" FLM_OLD="$2"
LEM_NEW="$3" LEM_OLD="$4"
XDNA_NEW="$5" XDNA_OLD="$6"
VLLM_NEW="${7:-}" VLLM_OLD="${8:-}"

# The unstable-YYYY-MM-DD date names the pinned rev, so it has to move with it.
update_unstable_date() {
  local repo="$1" rev="$2" file="$3"
  local date
  date=$(gh api "repos/$repo/commits/$rev" --jq '.commit.committer.date[0:10]' || true)
  if [ -n "$date" ]; then
    sed -i "s/\(version = \"[^\"]*unstable-\)[0-9-]\{10\}\"/\1$date\"/" "$file"
    echo "  Version date updated: $date"
  else
    echo "  WARNING: could not resolve commit date for $repo@${rev:0:12}"
  fi
}

# The workflow opens — and on the clean path auto-merges — whatever tree this
# leaves behind, so a hash we could not prefetch has to fail the job.
update_hash() {
  local pkg="$1"
  echo "  Prefetching hash for $pkg..."
  local new_hash
  new_hash=$(nix build ".#$pkg" 2>&1 | grep -oP 'got:\s+\K\S+' || true)
  if [ -z "$new_hash" ]; then
    echo "ERROR: could not auto-prefetch hash for $pkg" >&2
    exit 1
  fi
  sed -i "s|hash = \"\"|hash = \"$new_hash\"|" "pkgs/$pkg/default.nix"
  echo "  Hash updated: $new_hash"
}

# Release tags come in two shapes — `vllm<ver>+rocm<...>` nightlies and
# `vllm-omni<ver>-rocm<...>` cuts. Both reduce to the bare version.
vllm_version() {
  local v="${1#vllm}"
  v="${v#-}"
  v="${v%%+*}"
  printf '%s' "${v%-rocm*}"
}

# Keyed by URL rather than file position: a positional fill shifts every later
# hash into the wrong part as soon as one prefetch fails.
set_part_hash() {
  local file="$1" url="$2" hash="$3"
  grep -qF "$url" "$file" || {
    echo "ERROR: no part in $file has url $url" >&2
    exit 1
  }
  awk -v url="$url" -v h="$hash" '
    index($0, url) {found = 1}
    found && /hash = / {sub(/hash = "[^"]*"/, "hash = \"" h "\""); found = 0}
    {print}
  ' "$file" >"$file.tmp"
  mv "$file.tmp" "$file"
}

# FastFlowLM
if [ "$FLM_NEW" != "$FLM_OLD" ]; then
  echo "Bumping FastFlowLM: $FLM_OLD -> $FLM_NEW"
  sed -i "s/version = \"$FLM_OLD\"/version = \"$FLM_NEW\"/" pkgs/fastflowlm/default.nix
  sed -i 's/hash = "sha256-[^"]*"/hash = ""/' pkgs/fastflowlm/default.nix
  update_hash fastflowlm
fi

# Lemonade — one version (pkgs/lemonade/version.nix) feeds both the Linux source
# build and the macOS prebuilt wrap, but they fetch different tarballs and so
# carry separate hashes.
if [ "$LEM_NEW" != "$LEM_OLD" ]; then
  echo "Bumping Lemonade: $LEM_OLD -> $LEM_NEW"
  sed -i "s/\"$LEM_OLD\"/\"$LEM_NEW\"/" pkgs/lemonade/version.nix

  # Linux source tarball: blank + rebuild to capture the new hash.
  sed -i 's/hash = "sha256-[^"]*"/hash = ""/' pkgs/lemonade/default.nix
  update_hash lemonade

  # macOS embeddable bundle: a fixed-output fetch, so prefetch the URL directly
  # (works on the Linux CI runner, where the aarch64-darwin package can't build).
  echo "  Prefetching macOS embeddable hash..."
  darwin_url="https://github.com/lemonade-sdk/lemonade/releases/download/v${LEM_NEW}/lemonade-embeddable-${LEM_NEW}-macos-arm64.tar.gz"
  if ! darwin_hash=$(nix store prefetch-file --json "$darwin_url" | jq -er .hash); then
    echo "ERROR: could not prefetch macOS embeddable hash for $LEM_NEW" >&2
    exit 1
  fi
  sed -i "s|hash = \"sha256-[^\"]*\"|hash = \"$darwin_hash\"|" pkgs/lemonade/darwin.nix
  echo "  macOS hash updated: $darwin_hash"
fi

# xdna-driver (also check XRT submodule)
if [ "$XDNA_NEW" != "$XDNA_OLD" ]; then
  echo "Bumping xdna-driver: ${XDNA_OLD:0:12} -> ${XDNA_NEW:0:12}"
  sed -i "s/rev = \"$XDNA_OLD\"/rev = \"$XDNA_NEW\"/" pkgs/xrt-plugin-amdxdna/default.nix
  sed -i 's/hash = "sha256-[^"]*"/hash = ""/' pkgs/xrt-plugin-amdxdna/default.nix
  update_unstable_date amd/xdna-driver "$XDNA_NEW" pkgs/xrt-plugin-amdxdna/default.nix

  # Check if XRT submodule also changed
  NEW_XRT_REV=$(gh api "repos/amd/xdna-driver/contents/xrt?ref=$XDNA_NEW" --jq '.sha' || true)
  if [ -n "$NEW_XRT_REV" ]; then
    OLD_XRT_REV=$(grep 'rev = ' pkgs/xrt/default.nix | head -1 | sed 's/.*"\(.*\)".*/\1/')
    if [ "$NEW_XRT_REV" != "$OLD_XRT_REV" ]; then
      echo "  XRT submodule also changed: ${OLD_XRT_REV:0:12} -> ${NEW_XRT_REV:0:12}"
      sed -i "s/rev = \"$OLD_XRT_REV\"/rev = \"$NEW_XRT_REV\"/" pkgs/xrt/default.nix
      sed -i 's/hash = "sha256-[^"]*"/hash = ""/' pkgs/xrt/default.nix
      update_unstable_date Xilinx/XRT "$NEW_XRT_REV" pkgs/xrt/default.nix
      update_hash xrt
    fi
  fi

  update_hash xrt-plugin-amdxdna
fi

# vLLM-ROCm — prebuilt per-gfx split bundles. The base tag (minus -gfxNNNN)
# appears plain in each releaseTag and URL-encoded (+ -> %2B) in each URL, so
# swap both, then refetch every part's hash by URL — nix build can't emit
# per-part hashes.
if [ -n "$VLLM_NEW" ] && [ "$VLLM_NEW" != "$VLLM_OLD" ]; then
  echo "Bumping vLLM-ROCm: $VLLM_OLD -> $VLLM_NEW"
  src=pkgs/vllm-rocm/sources.nix
  old_enc="${VLLM_OLD//+/%2B}"
  new_enc="${VLLM_NEW//+/%2B}"
  old_ver=$(vllm_version "$VLLM_OLD")
  new_ver=$(vllm_version "$VLLM_NEW")

  sed -i "s|$old_enc|$new_enc|g; s|$VLLM_OLD|$VLLM_NEW|g" "$src"
  if [ "$old_ver" != "$new_ver" ]; then
    sed -i "s/version = \"$old_ver\"/version = \"$new_ver\"/g" "$src"
  fi

  base_url="https://github.com/lemonade-sdk/vllm-rocm/releases/download"
  mapfile -t targets < <(sed -n 's/^  \(gfx[0-9a-zA-Z]*\) = {$/\1/p' "$src")
  for target in "${targets[@]}"; do
    enctag="${new_enc}-${target}"
    for part in part01-of-02 part02-of-02; do
      url="${base_url}/${enctag}/${enctag}-x64.${part}.tar.gz"
      echo "  Prefetching $target $part..."
      if ! h=$(nix store prefetch-file --json "$url" | jq -er .hash); then
        echo "ERROR: could not prefetch $target $part" >&2
        echo "       $url" >&2
        exit 1
      fi
      set_part_hash "$src" "$url" "$h"
      echo "    $h"
    done
  done
fi

echo "Version bump complete."
