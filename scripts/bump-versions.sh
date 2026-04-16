#!/usr/bin/env bash
# Bump package versions in derivation files.
# Usage: bump-versions.sh <flm_new> <flm_old> <lem_new> <lem_old> <xdna_new> <xdna_old>
set -euo pipefail

FLM_NEW="$1" FLM_OLD="$2"
LEM_NEW="$3" LEM_OLD="$4"
XDNA_NEW="$5" XDNA_OLD="$6"

update_hash() {
  local pkg="$1"
  echo "  Prefetching hash for $pkg..."
  local new_hash
  new_hash=$(nix build ".#$pkg" 2>&1 | grep -oP 'got:\s+\K\S+' || true)
  if [ -n "$new_hash" ]; then
    sed -i "s|hash = \"\"|hash = \"$new_hash\"|" "pkgs/$pkg/default.nix"
    echo "  Hash updated: $new_hash"
  else
    echo "  WARNING: could not auto-prefetch hash for $pkg"
  fi
}

# FastFlowLM
if [ "$FLM_NEW" != "$FLM_OLD" ]; then
  echo "Bumping FastFlowLM: $FLM_OLD -> $FLM_NEW"
  sed -i "s/version = \"$FLM_OLD\"/version = \"$FLM_NEW\"/" pkgs/fastflowlm/default.nix
  sed -i 's/hash = "sha256-[^"]*"/hash = ""/' pkgs/fastflowlm/default.nix
  update_hash fastflowlm
fi

# Lemonade
if [ "$LEM_NEW" != "$LEM_OLD" ]; then
  echo "Bumping Lemonade: $LEM_OLD -> $LEM_NEW"
  sed -i "s/version = \"$LEM_OLD\"/version = \"$LEM_NEW\"/" pkgs/lemonade/default.nix
  sed -i 's/hash = "sha256-[^"]*"/hash = ""/' pkgs/lemonade/default.nix
  update_hash lemonade
fi

# xdna-driver (also check XRT submodule)
if [ "$XDNA_NEW" != "$XDNA_OLD" ]; then
  echo "Bumping xdna-driver: ${XDNA_OLD:0:12} -> ${XDNA_NEW:0:12}"
  sed -i "s/rev = \"$XDNA_OLD\"/rev = \"$XDNA_NEW\"/" pkgs/xrt-plugin-amdxdna/default.nix
  sed -i 's/hash = "sha256-[^"]*"/hash = ""/' pkgs/xrt-plugin-amdxdna/default.nix

  # Check if XRT submodule also changed
  NEW_XRT_REV=$(gh api "repos/amd/xdna-driver/contents/xrt?ref=$XDNA_NEW" --jq '.sha' || true)
  if [ -n "$NEW_XRT_REV" ]; then
    OLD_XRT_REV=$(grep 'rev = ' pkgs/xrt/default.nix | head -1 | sed 's/.*"\(.*\)".*/\1/')
    if [ "$NEW_XRT_REV" != "$OLD_XRT_REV" ]; then
      echo "  XRT submodule also changed: ${OLD_XRT_REV:0:12} -> ${NEW_XRT_REV:0:12}"
      sed -i "s/rev = \"$OLD_XRT_REV\"/rev = \"$NEW_XRT_REV\"/" pkgs/xrt/default.nix
      sed -i 's/hash = "sha256-[^"]*"/hash = ""/' pkgs/xrt/default.nix
      update_hash xrt
    fi
  fi

  update_hash xrt-plugin-amdxdna
fi

echo "Version bump complete."
