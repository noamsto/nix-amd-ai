# Production (no sanitizer) fastflowlm built without thread-safe-localtime.patch,
# for the red half of the #197 offset probe. Evaluated directly via `-f`:
#
#   NIXPKGS_ALLOW_UNFREE=1 nix build --impure -f bench-logs/flm-tz-race-2026-10-04/unpatched.nix -o result-unpatched
{
  flake ? builtins.getFlake "path:${toString ../..}",
}:
flake.packages.x86_64-linux.fastflowlm.overrideAttrs (old: {
  pname = old.pname + "-unpatched";
  patches =
    let
      filtered = builtins.filter (p: baseNameOf p != "thread-safe-localtime.patch") old.patches;
    in
    # Exactly one patch must be dropped; a renamed/missing file would silently
    # build the "unpatched" case with the fix still applied.
    assert builtins.length filtered == builtins.length old.patches - 1;
    filtered;
})
