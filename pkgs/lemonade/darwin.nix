{
  lib,
  stdenvNoCC,
  fetchurl,
}: let
  version = import ./version.nix;
in
  stdenvNoCC.mkDerivation {
    pname = "lemonade";
    inherit version;

    # Upstream ships a relocatable, server-only bundle for Apple Silicon:
    # lemond + lemonade CLI + resources/, no web UI / Tauri app (those are
    # .pkg-only). The Metal llama.cpp / sd.cpp backends are fetched into the
    # user cache at first run, exactly as the official .pkg does.
    src = fetchurl {
      url = "https://github.com/lemonade-sdk/lemonade/releases/download/v${version}/lemonade-embeddable-${version}-macos-arm64.tar.gz";
      hash = "sha256-C9jgvYTx9CVzH/yYTO9E6H7YuzVq0oXGtrQDrvvLsKQ=";
    };

    # The Mach-O binaries are adhoc-signed and link only against system
    # libraries and frameworks (incl. Metal) — no @rpath, no bundled dylibs.
    # Any install-name/rpath rewrite would break the signature, so skip fixup
    # entirely and place the files verbatim.
    dontConfigure = true;
    dontBuild = true;
    dontFixup = true;

    # lemond resolves its resources/ relative to the invoked binary, so keep
    # resources adjacent to lemond in $out/bin (mirrors the Linux build's
    # bin/resources symlink).
    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      cp -r lemond lemonade resources $out/bin/
      install -Dm644 LICENSE $out/share/doc/lemonade/LICENSE
      runHook postInstall
    '';

    meta = {
      description = "Local AI server with OpenAI-compatible API (Metal backend, macOS)";
      homepage = "https://github.com/lemonade-sdk/lemonade";
      license = lib.licenses.asl20;
      platforms = ["aarch64-darwin"];
      sourceProvenance = [lib.sourceTypes.binaryNativeCode];
      mainProgram = "lemond";
    };
  }
