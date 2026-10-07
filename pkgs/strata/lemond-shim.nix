{
  writers,
  writeText,
}: {
  server,
  settings,
}: let
  settingsFile = writeText "strata-lemond-settings.json" (builtins.toJSON settings);
in
  writers.writePython3Bin "strata-lemond-shim" {flakeIgnore = ["E501"];}
  (builtins.replaceStrings ["@settings@" "@server@"] ["${settingsFile}" server]
    (builtins.readFile ./lemond-shim.py))
