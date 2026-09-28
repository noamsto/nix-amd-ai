# Scratch ThreadSanitizer build of fastflowlm for #184 evidence gathering.
# Not wired into the flake -- evaluated directly via `-f`, never imported
# from flake.nix.
#
# Usage (fastflowlm is unfree, and the renamed derivation is evaluated
# outside the flake's allowUnfreePredicate):
#   NIXPKGS_ALLOW_UNFREE=1 nix build --impure -f bench-logs/flm-ps-race-2026-09-28/tsan.nix --arg fixed false -o result-tsan-red
#   NIXPKGS_ALLOW_UNFREE=1 nix build --impure -f bench-logs/flm-ps-race-2026-09-28/tsan.nix --arg fixed true  -o result-tsan-green
#
# fixed = false (red) drops ps-serving-snapshot.patch, the #184 fix; fixed =
# true (green, default) builds with every patch applied.
{
  flake ? builtins.getFlake "path:${toString ../..}",
  fixed ? true,
}:
flake.packages.x86_64-linux.fastflowlm.overrideAttrs (old: {
  pname = old.pname + "-tsan";
  patches =
    if fixed
    then old.patches
    else builtins.filter (p: baseNameOf p != "ps-serving-snapshot.patch") old.patches;
  configurePhase = builtins.replaceStrings
    [ "-DCMAKE_BUILD_TYPE=Release" ]
    [ "-DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS=-fsanitize=thread '-DCMAKE_CXX_FLAGS=-fsanitize=thread -g' -DCMAKE_EXE_LINKER_FLAGS=-fsanitize=thread -DCMAKE_SHARED_LINKER_FLAGS=-fsanitize=thread" ]
    old.configurePhase;
  dontStrip = true;
})
