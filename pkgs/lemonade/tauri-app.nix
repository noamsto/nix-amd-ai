{
  lib,
  rustPlatform,
  pkg-config,
  wrapGAppsHook3,
  webkitgtk_4_1,
  openssl,
  libayatana-appindicator,
  glib,
  gtk3,
  librsvg,
  gst_all_1,
  pipewire,
  version,
  src,
  tauri-frontend,
}:
rustPlatform.buildRustPackage {
  pname = "lemonade-app";
  inherit version src;

  sourceRoot = "${src.name}/src/app/src-tauri";

  cargoHash = "sha256-xX2Wkk0QqCQ//YoxeQBLTWfGEfyIR8JJKArYLzaAc0g=";

  # tauri-codegen's `generate_context!()` proc-macro embeds the frontendDist
  # files at lib.rs compile time. tauri.conf.json points frontendDist at
  # ../dist/renderer (relative to src-tauri/), so the pre-built bundle has
  # to land there before cargo runs. The unpacked source comes from the Nix
  # store with read-only perms, hence `chmod u+w ..` to allow the mkdir.
  preBuild = ''
    chmod u+w ..
    mkdir ../dist
    cp -r ${tauri-frontend} ../dist/renderer
  '';

  nativeBuildInputs = [
    pkg-config
    wrapGAppsHook3
  ];

  buildInputs = [
    webkitgtk_4_1
    openssl
    libayatana-appindicator
    glib
    gtk3
    librsvg
    # WebKit getUserMedia needs webrtcdsp (gst-plugins-bad) for the
    # echoCancellation/noiseSuppression constraints, and pipewiresrc
    # (in pipewire, not gst-plugins-*) for mic capture on Wayland.
    # wrapGAppsHook3 picks these up from buildInputs into GST_PLUGIN_SYSTEM_PATH_1_0.
    gst_all_1.gstreamer
    gst_all_1.gst-plugins-base
    gst_all_1.gst-plugins-good
    gst_all_1.gst-plugins-bad
    gst_all_1.gst-libav
    pipewire
  ];

  # `tauri/custom-protocol` flips tauri-codegen from dev mode (loading via
  # devUrl http://localhost:9123) to production mode (embedded assets served
  # via tauri://localhost). Tauri's own CLI sets this when invoked as
  # `cargo tauri build`; we drive cargo directly via buildRustPackage, so it
  # has to be enabled explicitly. Without it the window opens blank because
  # nothing is listening on :9123.
  buildFeatures = ["tauri/custom-protocol"];

  doCheck = false;

  # The CMake install rules for BUILD_TAURI_APP=ON would put these next to the
  # binary; we mirror that here so `from-source.nix` can compose a final
  # output that just symlinks $out/{bin,share}/...
  postInstall = ''
    install -Dm644 $src/data/lemonade-app.desktop $out/share/applications/lemonade-app.desktop
    install -Dm644 $src/src/app/assets/logo.svg $out/share/pixmaps/lemonade-app.svg
  '';

  meta = {
    description = "Lemonade desktop app (Tauri shell around the React UI)";
    homepage = "https://github.com/lemonade-sdk/lemonade";
    license = lib.licenses.mit;
    platforms = ["x86_64-linux"];
    mainProgram = "lemonade-app";
  };
}
