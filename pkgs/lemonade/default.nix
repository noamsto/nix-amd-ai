{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  rpm,
  cpio,
  zstd,
  zlib,
  openssl,
  libwebsockets,
  systemd,
  libcap,
  jq,
  fastflowlm,
  llama-cpp-rocm,
  llama-cpp-vulkan,
}:
stdenv.mkDerivation rec {
  pname = "lemonade";
  version = "10.3.0";

  src = fetchurl {
    url = "https://github.com/lemonade-sdk/lemonade/releases/download/v${version}/lemonade-server-${version}.x86_64.rpm";
    hash = "sha256-iKPjmC8FE1ZHQyIEJkFMzDwZNKBuJzmKviIlkiGo0u4=";
  };

  nativeBuildInputs = [autoPatchelfHook rpm cpio jq];

  buildInputs = [
    stdenv.cc.cc.lib # libstdc++
    zstd
    zlib
    openssl
    libwebsockets
    systemd
    libcap
  ];

  unpackPhase = ''
    rpm2cpio $src | cpio -idm
  '';

  # Lemonade v10.2.0 requires exact backend version matches; override pinned
  # versions to match what nix-amd-ai actually ships.
  # Remove FLM override after upgrading to a release containing
  # lemonade-sdk/lemonade#1652 (>= semver comparison for FLM on Linux).
  postPatch = ''
    jq '.flm.npu = "v${fastflowlm.version}"
        | .llamacpp.rocm = "b${llama-cpp-rocm.version}"
        | .llamacpp.vulkan = "b${llama-cpp-vulkan.version}"' \
      opt/share/lemonade-server/resources/backend_versions.json > tmp.json
    mv tmp.json opt/share/lemonade-server/resources/backend_versions.json
  '';

  installPhase = ''
    mkdir -p $out/bin $out/share $out/libexec/lemonade

    install -m755 opt/bin/lemonade $out/libexec/lemonade/lemonade
    install -m755 opt/bin/lemond $out/libexec/lemonade/lemond
    install -m755 opt/bin/lemonade-server $out/libexec/lemonade/lemonade-server

    # Create wrappers that refresh ROCm runtime config on every launch.
    # Lemonade compares ~/.cache/lemonade/bin/llamacpp/rocm/version.txt against
    # resources/backend_versions.json .llamacpp.rocm to decide installed vs
    # update_required, so we pin both the rocm_bin path and that version.txt.
    for bin in lemonade lemond lemonade-server; do
      cat > $out/bin/$bin <<EOF
#!/usr/bin/env bash
if [ -n "\$LEMONADE_LLAMACPP_ROCM_BIN" ]; then
  CONFIG_DIR="\''${LEMONADE_CACHE_DIR:-\$HOME/.cache/lemonade}"
  CONFIG_FILE="\$CONFIG_DIR/config.json"
  mkdir -p "\$CONFIG_DIR"
  if [ -f "\$CONFIG_FILE" ]; then
    ${jq}/bin/jq --arg bin "\$LEMONADE_LLAMACPP_ROCM_BIN" '.llamacpp.rocm_bin = \$bin' "\$CONFIG_FILE" > "\$CONFIG_FILE.tmp" && mv "\$CONFIG_FILE.tmp" "\$CONFIG_FILE"
  else
    ${jq}/bin/jq -n --arg bin "\$LEMONADE_LLAMACPP_ROCM_BIN" '{llamacpp: {rocm_bin: \$bin}}' > "\$CONFIG_FILE"
  fi
  ROCM_VERSION="\$(${jq}/bin/jq -r '.llamacpp.rocm' $out/libexec/lemonade/resources/backend_versions.json)"
  ROCM_INSTALL_DIR="\$CONFIG_DIR/bin/llamacpp/rocm"
  mkdir -p "\$ROCM_INSTALL_DIR"
  printf '%s' "\$ROCM_VERSION" > "\$ROCM_INSTALL_DIR/version.txt"
fi
if [ -n "\$LEMONADE_LLAMACPP_VULKAN_BIN" ]; then
  CONFIG_DIR="\''${LEMONADE_CACHE_DIR:-\$HOME/.cache/lemonade}"
  CONFIG_FILE="\$CONFIG_DIR/config.json"
  mkdir -p "\$CONFIG_DIR"
  if [ -f "\$CONFIG_FILE" ]; then
    ${jq}/bin/jq --arg bin "\$LEMONADE_LLAMACPP_VULKAN_BIN" '.llamacpp.vulkan_bin = \$bin' "\$CONFIG_FILE" > "\$CONFIG_FILE.tmp" && mv "\$CONFIG_FILE.tmp" "\$CONFIG_FILE"
  else
    ${jq}/bin/jq -n --arg bin "\$LEMONADE_LLAMACPP_VULKAN_BIN" '{llamacpp: {vulkan_bin: \$bin}}' > "\$CONFIG_FILE"
  fi
  VULKAN_VERSION="\$(${jq}/bin/jq -r '.llamacpp.vulkan' $out/libexec/lemonade/resources/backend_versions.json)"
  VULKAN_INSTALL_DIR="\$CONFIG_DIR/bin/llamacpp/vulkan"
  mkdir -p "\$VULKAN_INSTALL_DIR"
  printf '%s' "\$VULKAN_VERSION" > "\$VULKAN_INSTALL_DIR/version.txt"
fi
exec "$out/libexec/lemonade/$bin" "\$@"
EOF
      chmod +x $out/bin/$bin
    done

    # lemond searches for resources/ next to the binary AND in /opt/share/lemonade-server/
    # Place next to binary so the relative lookup works in the Nix store
    cp -r opt/share/lemonade-server/resources $out/libexec/lemonade/resources
    ln -s ../libexec/lemonade/resources $out/bin/resources

    # Also install to share/ for completeness (man pages, examples)
    cp -r opt/share/lemonade-server/* $out/share/
    cp -r opt/share/man $out/share/
  '';

  meta = {
    description = "Local AI server with OpenAI-compatible API for NPU/GPU inference";
    homepage = "https://github.com/lemonade-sdk/lemonade";
    license = lib.licenses.asl20;
    platforms = ["x86_64-linux"];
    mainProgram = "lemond";
  };
}
