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
}:
stdenv.mkDerivation rec {
  pname = "lemonade";
  version = "10.2.0";

  src = fetchurl {
    url = "https://github.com/lemonade-sdk/lemonade/releases/download/v${version}/lemonade-server-${version}.x86_64.rpm";
    hash = "sha256-+37NZ2qr5Kk7lbEHd9VYCgqq5VV37oy5TT9Pe7YYndg=";
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

  # Patch backend_versions.json to match our FLM version.
  # The file is explicitly designed to be user-editable (see its "comment" field).
  postPatch = ''
    jq '.flm.npu = "v${fastflowlm.version}"' \
      opt/share/lemonade-server/resources/backend_versions.json > tmp.json
    mv tmp.json opt/share/lemonade-server/resources/backend_versions.json
  '';

  installPhase = ''
    mkdir -p $out/bin $out/share

    install -m755 opt/bin/lemonade $out/bin/lemonade
    install -m755 opt/bin/lemond $out/bin/lemond
    install -m755 opt/bin/lemonade-server $out/bin/lemonade-server

    # lemond searches for resources/ next to the binary AND in /opt/share/lemonade-server/
    # Place next to binary so the relative lookup works in the Nix store
    cp -r opt/share/lemonade-server/resources $out/bin/resources

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
