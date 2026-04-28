{
  lib,
  buildNpmPackage,
  nodejs,
  version,
  src,
}:
buildNpmPackage {
  pname = "lemonade-tauri-frontend";
  inherit version src nodejs;

  sourceRoot = "${src.name}/src/app";

  # Upstream ships its own package-lock.json under src/app/, so buildNpmPackage
  # reads it directly. Refresh on dep bumps.
  npmDepsHash = "sha256-EdmbKKIOdlzzZiZnIAhu5oqrQUmVFkoAQ/7OCUypL8Q=";

  npmBuildScript = "build:renderer:prod";

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -r dist/renderer/. $out/
    runHook postInstall
  '';

  dontNpmInstall = true;

  meta = {
    description = "Lemonade Tauri desktop app frontend (React static bundle)";
    homepage = "https://github.com/lemonade-sdk/lemonade";
    license = lib.licenses.asl20;
    platforms = ["x86_64-linux"];
  };
}
