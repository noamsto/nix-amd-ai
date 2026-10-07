{
  runCommand,
  makeWrapper,
}: strata:
runCommand "strata-server-lemond" {nativeBuildInputs = [makeWrapper];} ''
  # Keep in sync with the strata-server wrapper in ./default.nix.
  makeWrapper ${strata.python}/bin/python $out/bin/strata-server \
    --add-flags ${./lemond-server.py} \
    --chdir ${strata}/share/strata \
    --set STRATA_HIPBLASLT_TUNING ${strata}/share/strata/tools/hip/gfx1151-hipblaslt-100401.txt \
    --prefix PATH : ${strata}/bin
''
