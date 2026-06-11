{
  lib,
  stdenv,
  callPackage,
  fetchFromGitHub,
  cmake,
  ninja,
  pkg-config,
  python3,
  jq,
  nlohmann_json,
  cli11,
  curl,
  zstd,
  brotli,
  httplib,
  libwebsockets,
  mbedtls,
  openssl,
  systemd,
  libcap,
  libdrm,
  fastflowlm,
  llama-cpp-rocm,
  llama-cpp-vulkan,
  whisper-cpp,
  whisper-cpp-vulkan,
  stable-diffusion-cpp,
  stable-diffusion-cpp-rocm,
  # Default-on opt-out flags. Headless / server-only consumers can flip these
  # off via .override to skip the npm/Rust builds and shrink the closure.
  withWebApp ? true,
  withDesktopApp ? true,
}: let
  version = "10.7.0";

  src = fetchFromGitHub {
    owner = "lemonade-sdk";
    repo = "lemonade";
    rev = "v${version}";
    hash = "sha256-fB4XKDoX3KLRT8rx6Y3OThhaUuO4ng6rm72OYTtRzjs=";
  };

  web-app = callPackage ./web-app.nix {inherit src version;};
  tauri-frontend = callPackage ./tauri-frontend.nix {inherit src version;};
  tauri-app = callPackage ./tauri-app.nix {inherit src version tauri-frontend;};
in stdenv.mkDerivation {
  pname = "lemonade";
  inherit version src;

  nativeBuildInputs = [
    cmake
    ninja
    pkg-config
    python3
    jq
  ];

  buildInputs = [
    nlohmann_json
    cli11
    curl
    zstd
    brotli
    httplib
    libwebsockets
    mbedtls
    openssl
    systemd
    libcap
    libdrm
  ];

  cmakeFlags = [
    (lib.cmakeFeature "CMAKE_BUILD_TYPE" "Release")
    # Web app and Tauri are built as separate derivations and merged in
    # postInstall, so the C++ build never runs npm or cargo itself.
    (lib.cmakeBool "BUILD_WEB_APP" false)
    (lib.cmakeBool "BUILD_TAURI_APP" false)
    (lib.cmakeBool "REQUIRE_LINUX_TRAY" false)
  ];

  postPatch = ''
    # Two install(CODE ...) blocks in cli and the top-level CMakeLists try
    # to symlink binaries / units into /usr/bin and /usr/lib/systemd/system
    # via $ENV{DESTDIR} — designed for Debian's DESTDIR-staged build. In
    # Nix, DESTDIR is unset and CMAKE_INSTALL_PREFIX is $out, so
    # $ENV{DESTDIR}/usr/bin resolves to /usr/bin, which the sandbox refuses.
    # Drop those symlink blocks; the binaries and unit live at
    # $out/{bin,lib/systemd/system}/ and the NixOS module wires them in.
    sed -i '/Create symlink in standard bin path only if not installing to/,/^endif()$/d' \
      src/cpp/cli/CMakeLists.txt
    sed -i '/Create symlink in standard systemd search path only if not installing to/,/^    endif()$/d' CMakeLists.txt

    # secrets.conf install rule writes to absolute /etc/lemonade/conf.d. The
    # NixOS module is what owns /etc, not us — relocate the template under
    # $out so it ships with the derivation but doesn't try to populate /etc.
    substituteInPlace CMakeLists.txt \
      --replace-fail \
        'DESTINATION /etc/lemonade/conf.d' \
        'DESTINATION share/lemonade/conf.d.example'

    # Let a packager point lemonade at a defaults.json outside the FHS path.
    # v10.7.0 dropped the LEMONADE_*_BIN env→config migration, so the NixOS
    # module can no longer inject backend bin paths via the environment; the
    # only seam left is get_defaults(), which merges a hardcoded
    # /usr/share/lemonade/defaults.json that NixOS doesn't populate. Honor
    # LEMONADE_DEFAULTS_PATH so the module can supply a store-path defaults
    # file. Mirrors the LEMONADE_GGML_HIP_PATH escape hatch from #2044.
    # Drop once the upstream LEMONADE_DEFAULTS_PATH proposal lands.
    substituteInPlace src/cpp/server/config_file.cpp \
      --replace-fail \
        '    return defaults;
}' \
        '    if (const char* env = std::getenv("LEMONADE_DEFAULTS_PATH"); env && *env && fs::exists(env)) {
        defaults = utils::JsonUtils::merge(defaults, load_json_file(env));
    }

    return defaults;
}'

    # Don't abort downloads when the SSE progress stream's TCP socket goes
    # away. WebKitGTK suspends the network process for backgrounded windows
    # (different workspace, minimized) at ~60-90s, killing the SSE stream and
    # losing GBs of partial download. Let the download finish in the
    # background; the next client poll will see it as installed. See
    # noamsto/nix-amd-ai#5.
    substituteInPlace src/cpp/server/server.cpp \
      --replace-fail \
        'if (!sink.write(event.c_str(), event.size())) {
                        LOG(INFO, "Server") << "Client disconnected, cancelling download" << std::endl;
                        return false;
                    }
                    return true;' \
        'if (!sink.write(event.c_str(), event.size())) {
                        LOG(INFO, "Server") << "Client disconnected; download continues in background" << std::endl;
                    }
                    return true;'

    # Pin backend_versions.json to whatever fastflowlm / llama-cpp /
    # whisper-cpp / sd-cpp builds we ship, so lemonade's "installed vs
    # needs update" check stays satisfied and it doesn't try to download
    # backends at runtime. sd-cpp.cpu uses the vanilla nixpkgs version
    # (master-NNN-HASH); ROCm/Vulkan variants share the same upstream
    # commit so one version covers all three sd-cpp keys.
    if [ -f src/cpp/resources/backend_versions.json ]; then
      jq '.flm.npu = "v${fastflowlm.version}"
          | .llamacpp."rocm-stable" = "b${llama-cpp-rocm.version}"
          | .llamacpp.vulkan = "b${llama-cpp-vulkan.version}"
          | .whispercpp.cpu = "v${whisper-cpp.version}"
          | .whispercpp.vulkan = "v${whisper-cpp-vulkan.version}"
          | ."sd-cpp".cpu = "${stable-diffusion-cpp.version}"
          | ."sd-cpp"."rocm-stable" = "${stable-diffusion-cpp-rocm.version}"' \
        src/cpp/resources/backend_versions.json > src/cpp/resources/backend_versions.json.tmp
      mv src/cpp/resources/backend_versions.json.tmp src/cpp/resources/backend_versions.json
    fi
  '';

  # lemond looks for resources/ adjacent to its own binary (it tries
  # ${argv0_dir}/resources first, then /opt/share/lemonade-server/resources).
  # Neither matches our store layout, so the bin/resources symlink satisfies
  # the relative lookup. The web UI lives where BUILD_WEB_APP=ON would have
  # produced it (share/lemonade-server/resources/web-app/), as a symlink to
  # the buildNpmPackage output to avoid duplicating ~3 MB into our closure.
  postInstall = ''
    ln -s ../share/lemonade-server/resources $out/bin/resources
  ''
  + lib.optionalString withWebApp ''
    ln -s ${web-app} $out/share/lemonade-server/resources/web-app
  ''
  + lib.optionalString withDesktopApp ''
    ln -s ${tauri-app}/bin/lemonade-app $out/bin/lemonade-app
    install -d $out/share/applications $out/share/pixmaps
    ln -s ${tauri-app}/share/applications/lemonade-app.desktop $out/share/applications/lemonade-app.desktop
    ln -s ${tauri-app}/share/pixmaps/lemonade-app.svg $out/share/pixmaps/lemonade-app.svg
  '';

  # Surface the inner staging derivations so each can be built independently
  # for hash refresh and debugging:
  #   nix build .#lemonade.web-app
  #   nix build .#lemonade.tauri-frontend
  #   nix build .#lemonade.tauri-app
  passthru = {
    inherit web-app tauri-frontend tauri-app;
  };

  meta = {
    description = "Local AI server with OpenAI-compatible API for NPU/GPU inference";
    homepage = "https://github.com/lemonade-sdk/lemonade";
    license = lib.licenses.asl20;
    platforms = ["x86_64-linux"];
    mainProgram = "lemond";
  };
}
