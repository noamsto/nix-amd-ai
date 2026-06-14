{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkPackageOption mkOption mkIf types getExe;
  cfg = config.services.lemonade;
in {
  options.services.lemonade = {
    enable = mkEnableOption "the Lemonade AI server (macOS, llama.cpp Metal backend)";

    package = mkPackageOption pkgs "lemonade" {};

    host = mkOption {
      type = types.str;
      default = "localhost";
      description = "Address for the Lemonade server to bind to.";
    };

    port = mkOption {
      type = types.port;
      default = 13305;
      description = "Port for the Lemonade server.";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [cfg.package];

    # user.agents (not agents): nix-darwin activates these via
    # `launchctl asuser <uid> … load`, so the agent starts in the primary
    # user's GUI session on `darwin-rebuild switch` and runs as that user —
    # required because lemond's llama.cpp Metal backend reaches the GPU
    # through the user session, not a root daemon. lemond fetches the Metal
    # backend into ~/.cache/lemonade on first run, like the upstream .pkg.
    launchd.user.agents.lemonade = {
      serviceConfig = {
        ProgramArguments = [
          (getExe cfg.package)
          "--port"
          (toString cfg.port)
          "--host"
          cfg.host
        ];
        RunAtLoad = true;
        # Respawn on crash, but not after a clean `launchctl stop` / exit.
        KeepAlive = {Crashed = true;};
        StandardOutPath = "/Users/${config.system.primaryUser}/Library/Logs/lemonade.log";
        StandardErrorPath = "/Users/${config.system.primaryUser}/Library/Logs/lemonade.log";
      };
    };
  };
}
