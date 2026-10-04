# Scratch ThreadSanitizer build of fastflowlm for #197 evidence gathering.
# Not wired into the flake -- evaluated directly via `-f`, never imported
# from flake.nix. Adapted from
# bench-logs/flm-ps-race-2026-09-28/tsan.nix (the #196 recipe); the only
# change is which patch the red filter drops.
#
# Usage (fastflowlm is unfree, and the renamed derivation is evaluated
# outside the flake's allowUnfreePredicate):
#   NIXPKGS_ALLOW_UNFREE=1 nix build --impure -f bench-logs/flm-tz-race-2026-10-04/tsan.nix --arg fixed false -o result-tsan-red
#   NIXPKGS_ALLOW_UNFREE=1 nix build --impure -f bench-logs/flm-tz-race-2026-10-04/tsan.nix --arg fixed true  -o result-tsan-green
#
# fixed = false (red) drops thread-safe-localtime.patch, the #197 fix;
# fixed = true (green, default) builds with every patch applied.
{
  flake ? builtins.getFlake "path:${toString ../..}",
  fixed ? true,
}:
flake.packages.x86_64-linux.fastflowlm.overrideAttrs (old: {
  pname = old.pname + "-tsan";
  patches =
    if fixed
    then old.patches
    else
      let
        filtered = builtins.filter (p: baseNameOf p != "thread-safe-localtime.patch") old.patches;
      in
      # A renamed/missing patch file would silently no-op the filter and build
      # the "red" case with the fix still applied.
      assert builtins.length filtered == builtins.length old.patches - 1;
      filtered;
  configurePhase =
    let
      replaced = builtins.replaceStrings
        [ "-DCMAKE_BUILD_TYPE=Release" ]
        [ "-DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS=-fsanitize=thread '-DCMAKE_CXX_FLAGS=-fsanitize=thread -g' -DCMAKE_EXE_LINKER_FLAGS=-fsanitize=thread -DCMAKE_SHARED_LINKER_FLAGS=-fsanitize=thread" ]
        old.configurePhase;
    in
    # An upstream configurePhase rewrite could drop the substring and silently
    # build without TSan instrumentation.
    assert replaced != old.configurePhase;
    replaced;
  dontStrip = true;
})
