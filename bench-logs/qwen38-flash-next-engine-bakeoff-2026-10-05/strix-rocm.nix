# Builds this flake's llama-cpp-rocm from a llama.cpp fork, e.g.
#   nix build --impure -f strix-rocm.nix --argstr owner halo-box \
#     --argstr repo strix-llama.cpp --argstr rev <sha> --argstr hash <sri>
{
  owner,
  repo,
  rev,
  hash,
  flake ? builtins.getFlake (toString ../..),
}: let
  pkgs = flake.inputs.nixpkgs.legacyPackages.x86_64-linux;
  shortRev = builtins.substring 0 7 rev;
in
  flake.packages.x86_64-linux.llama-cpp-rocm.overrideAttrs (old: {
    version = "${repo}-${shortRev}";
    src = pkgs.fetchFromGitHub {inherit owner repo rev hash;};
    # gfx1151 only: the bake-off host is gfx1151, so skip compiling gfx1150.
    cmakeFlags =
      map (
        flag:
          if pkgs.lib.hasPrefix "-DLLAMA_BUILD_COMMIT:STRING=" flag
          then "-DLLAMA_BUILD_COMMIT:STRING=${shortRev}"
          else if pkgs.lib.hasPrefix "-DLLAMA_BUILD_NUMBER:STRING=" flag
          then "-DLLAMA_BUILD_NUMBER:STRING=0"
          else if pkgs.lib.hasPrefix "-DCMAKE_HIP_ARCHITECTURES:STRING=" flag
          then "-DCMAKE_HIP_ARCHITECTURES:STRING=gfx1151"
          else flag
      )
      old.cmakeFlags;
  })
