{
  lib,
  symlinkJoin,
  writeShellScriptBin,
  uv,
}: let
  version = "0.23.0";

  # Upstream dropped the gaia-emr and gaia-code console scripts in 0.21.0
  # (changelog: "drop stale gaia-emr smoke check", amd/gaia#1563). Verified
  # against the published wheels' entry_points.txt: 0.20.0 still ships all
  # five, 0.21.0 through 0.23.0 ship only these three. Keeping the other two
  # would generate wrappers that fail at run time with "executable not found".
  bins = ["gaia" "gaia-cli" "gaia-mcp"];

  # GAIA reads LEMONADE_BASE_URL from .env / environ; default it to lemond's
  # in-tree port (modules/amd-npu.nix lemonade.port = 13305) so users don't
  # need a .env to talk to a flake-provisioned server. User-set value wins.
  mkBin = name:
    writeShellScriptBin name ''
      : "''${LEMONADE_BASE_URL:=http://localhost:13305/api/v1}"
      export LEMONADE_BASE_URL
      exec ${uv}/bin/uvx --from "amd-gaia[ui]==${version}" ${name} "$@"
    '';
in
  symlinkJoin {
    name = "gaia-${version}";
    paths = map mkBin bins;
    meta = {
      description = "AMD GAIA — local AI agent framework, runs against lemond via uvx";
      homepage = "https://github.com/amd/gaia";
      license = lib.licenses.mit;
      platforms = ["x86_64-linux"];
      mainProgram = "gaia";
    };
  }
