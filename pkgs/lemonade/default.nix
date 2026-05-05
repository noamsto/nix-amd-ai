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
  version = "10.3.0";

  src = fetchFromGitHub {
    owner = "lemonade-sdk";
    repo = "lemonade";
    rev = "v${version}";
    hash = "sha256-IQE8E/88yI8MoqyTvoDSNjbPX9F7yW2ckne2PaDewxk=";
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
    openssl
    systemd
    libcap
    libdrm
  ];

  # nixpkgs ships httplib as `httplib.pc`, but lemonade's CMakeLists looks for
  # `cpp-httplib.pc` via pkg_check_modules. Synthesize an alias .pc file and add
  # it to PKG_CONFIG_PATH so USE_SYSTEM_HTTPLIB takes the system path instead of
  # falling through to FetchContent (which requires network and breaks the
  # nix sandbox).
  preConfigure = ''
    mkdir -p $TMPDIR/pc-shim
    cat > $TMPDIR/pc-shim/cpp-httplib.pc <<EOF
    prefix=${httplib}
    includedir=${httplib}/include
    Name: cpp-httplib
    Description: C++ header-only HTTP/HTTPS server and client library (alias for httplib)
    Version: ${httplib.version}
    Cflags: -I${httplib}/include
    EOF
    export PKG_CONFIG_PATH=$TMPDIR/pc-shim:$PKG_CONFIG_PATH
  '';

  cmakeFlags = [
    (lib.cmakeFeature "CMAKE_BUILD_TYPE" "Release")
    # Web app and Tauri are built as separate derivations and merged in
    # postInstall, so the C++ build never runs npm or cargo itself.
    (lib.cmakeBool "BUILD_WEB_APP" false)
    (lib.cmakeBool "BUILD_TAURI_APP" false)
    (lib.cmakeBool "REQUIRE_LINUX_TRAY" false)
  ];

  postPatch = ''
    # Lemonade's CMakeLists assumes Debian's compiled libcpp-httplib.so
    # (target name `cpp-httplib`); nixpkgs ships httplib header-only, so the
    # link of -lcpp-httplib fails. Header-only cpp-httplib doesn't need a
    # link entry — the inline functions are emitted into our own .o files —
    # so use ''${HTTPLIB_LIBRARIES} (empty under our header-only .pc shim)
    # instead of the literal `cpp-httplib` target name.
    substituteInPlace CMakeLists.txt \
      --replace-fail \
        'target_link_libraries(lemonade-server-core PUBLIC cpp-httplib)' \
        'target_link_libraries(lemonade-server-core PUBLIC ''${HTTPLIB_LIBRARIES})'
    substituteInPlace src/cpp/cli/CMakeLists.txt \
      --replace-fail \
        'target_link_libraries(lemonade PRIVATE cpp-httplib)' \
        'target_link_libraries(lemonade PRIVATE ''${HTTPLIB_LIBRARIES})'
    substituteInPlace src/cpp/legacy-cli/CMakeLists.txt \
      --replace-fail \
        'target_link_libraries(lemonade-server PRIVATE cpp-httplib)' \
        'target_link_libraries(lemonade-server PRIVATE ''${HTTPLIB_LIBRARIES})'

    # Three install(CODE ...) blocks in cli, legacy-cli, and the top-level
    # CMakeLists try to symlink binaries / units into /usr/bin and
    # /usr/lib/systemd/system via $ENV{DESTDIR} — designed for Debian's
    # DESTDIR-staged build. In Nix, DESTDIR is unset and CMAKE_INSTALL_PREFIX
    # is $out, so $ENV{DESTDIR}/usr/bin resolves to /usr/bin, which the
    # sandbox refuses. Drop those symlink blocks; the binaries and unit live
    # at $out/{bin,lib/systemd/system}/ and the NixOS module wires them in.
    sed -i '/Create symlink in standard bin path only if not installing to/,/^endif()$/d' \
      src/cpp/cli/CMakeLists.txt \
      src/cpp/legacy-cli/CMakeLists.txt
    sed -i '/Create symlink in standard systemd search path only if not installing to/,/^    endif()$/d' CMakeLists.txt

    # secrets.conf install rule writes to absolute /etc/lemonade/conf.d. The
    # NixOS module is what owns /etc, not us — relocate the template under
    # $out so it ships with the derivation but doesn't try to populate /etc.
    substituteInPlace CMakeLists.txt \
      --replace-fail \
        'DESTINATION /etc/lemonade/conf.d' \
        'DESTINATION share/lemonade/conf.d.example'

    # FLM-recipe whisper models report their capabilities as
    # ["realtime-transcription","transcription"] (the labels emitted by
    # `flm list --json`). Lemonade's `get_model_type_from_labels` only
    # recognises the literal label "audio", so FLM whisper falls through to
    # ModelType::LLM and the audio router rejects every realtime call with
    # `Audio transcription not supported by FLM llm model`. Teach the
    # classifier that "transcription" / "realtime-transcription" also imply
    # the AUDIO deployment mode. See lemonade-sdk/lemonade — no upstream
    # issue yet at v${version}.
    substituteInPlace src/cpp/include/lemon/model_types.h \
      --replace-fail \
        'if (label == "audio") {' \
        'if (label == "audio" || label == "transcription" || label == "realtime-transcription") {'

    # Make user-supplied llamacpp.*_bin paths fully authoritative. v10.3.0
    # added a no_fetch_executables throw and rocm-stable / TheRock runtime
    # downloads to install_backend that fire BEFORE install_from_github's
    # path-override short-circuit, so the env-var-migrated *_bin we set
    # in the NixOS module gets ignored: the runtime libs still download
    # into ~/.cache/lemonade/bin/ and llamacpp_server prepends them to
    # LD_LIBRARY_PATH, shadowing the libs the nix-built llama-server is
    # RPATH-bound to. Short-circuit install_backend the moment we see a
    # user-supplied bin path. See lemonade-sdk/lemonade#1791 and
    # noamsto/nix-amd-ai#5.
    substituteInPlace src/cpp/server/backend_manager.cpp \
      --replace-fail \
        '    if (auto* cfg = RuntimeConfig::global()) {
        if (cfg->no_fetch_executables()) {
            throw std::runtime_error(
                "Fetching executable artifacts is disabled");
        }
    }' \
        '    if (!backends::BackendUtils::find_external_backend_binary(recipe, resolved_backend).empty()) {
        return;
    }

    if (auto* cfg = RuntimeConfig::global()) {
        if (cfg->no_fetch_executables()) {
            throw std::runtime_error(
                "Fetching executable artifacts is disabled");
        }
    }'

    # Companion to the install_backend patch above. When the user pointed
    # llamacpp.rocm_bin at a system binary, that binary already resolves
    # its ROCm libs through its own RPATH; lemonade prepending TheRock's
    # ~/.cache/lemonade/bin/.../lib (or the rocm-stable runtime dir) to
    # LD_LIBRARY_PATH would override that and crash on lib version skew.
    substituteInPlace src/cpp/server/backends/llamacpp_server.cpp \
      --replace-fail \
        '    // For ROCm on Linux, set LD_LIBRARY_PATH to include the ROCm library directory
    std::vector<std::pair<std::string, std::string>> env_vars;
#ifndef _WIN32
    if (is_llamacpp_rocm_backend(llamacpp_backend)) {' \
        '    // For ROCm on Linux, set LD_LIBRARY_PATH to include the ROCm library directory
    std::vector<std::pair<std::string, std::string>> env_vars;
#ifndef _WIN32
    if (is_llamacpp_rocm_backend(llamacpp_backend) &&
        BackendUtils::find_external_backend_binary(SPEC.recipe, llamacpp_backend).empty()) {'

    # Teach is_ggml_hip_plugin_available() about a NixOS-friendly env var
    # so the "system" llamacpp recipe stops being permanently "unsupported"
    # here. The hardcoded probe only knows Debian/Ubuntu/Arch FHS paths;
    # libggml-hip.so on NixOS lives in $\{llama-cpp-rocm}/lib. With the env
    # var set, "system" + prefer_system: true becomes a real option.
    substituteInPlace src/cpp/server/utils/path_utils.cpp \
      --replace-fail \
        'bool is_ggml_hip_plugin_available() {
#ifdef __linux__
    // On Linux x86_64, check common system library paths for the HIP plugin' \
        'bool is_ggml_hip_plugin_available() {
#ifdef __linux__
    if (const char* env = std::getenv("LEMONADE_GGML_HIP_PATH"); env && *env && fs::exists(env)) {
        return true;
    }
    // On Linux x86_64, check common system library paths for the HIP plugin'

    # whispercpp's vulkan and rocm backends accept *_bin via runtime config
    # (build_bin_config_key) but lemonade ships no env-var migration for
    # them — only LEMONADE_WHISPERCPP_{CPU,NPU}_BIN are mapped. Add the
    # missing vulkan mapping so the NixOS module can wire whisper-cpp's
    # vulkan build via systemd Environment. (rocm not exposed for
    # whispercpp at all in v${version} RECIPE_DEFS.)
    substituteInPlace src/cpp/server/config_file.cpp \
      --replace-fail \
        '{"LEMONADE_WHISPERCPP_NPU_BIN",      "whispercpp", "npu_bin"},' \
        '{"LEMONADE_WHISPERCPP_NPU_BIN",      "whispercpp", "npu_bin"},
    {"LEMONADE_WHISPERCPP_VULKAN_BIN",   "whispercpp", "vulkan_bin"},'

    # ConfigFile::load only runs migrate_from_env when ~/.cache/lemonade/
    # config.json doesn't exist (first run). After that, env-var changes
    # are silently ignored — so a NixOS module bumping pkgs.llama-cpp from
    # the systemd Environment won't take effect unless the user manually
    # deletes config.json. Re-apply the env overlay on every load so
    # systemd-set bin paths stay authoritative. migrate_from_env's first
    # arg is just the merge base (despite the name), so passing the loaded
    # config in lets env values override stored ones.
    substituteInPlace src/cpp/server/config_file.cpp \
      --replace-fail \
        'return utils::JsonUtils::merge(defaults, loaded);' \
        'return migrate_from_env(utils::JsonUtils::merge(defaults, loaded));'

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
          | .llamacpp.rocm = "b${llama-cpp-rocm.version}"
          | .llamacpp.vulkan = "b${llama-cpp-vulkan.version}"
          | .whispercpp.cpu = "v${whisper-cpp.version}"
          | .whispercpp.vulkan = "v${whisper-cpp-vulkan.version}"
          | ."sd-cpp".cpu = "${stable-diffusion-cpp.version}"
          | ."sd-cpp"."rocm-stable" = "${stable-diffusion-cpp-rocm.version}"
          | ."sd-cpp"."rocm-preview" = "${stable-diffusion-cpp-rocm.version}"' \
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
