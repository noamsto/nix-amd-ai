{
  lib,
  buildNpmPackage,
  nodejs,
  version,
  src,
}:
buildNpmPackage {
  pname = "lemonade-web-app";
  inherit version src nodejs;

  sourceRoot = "${src.name}/src/web-app";

  # Upstream ships its own package-lock.json under src/web-app/, so
  # buildNpmPackage reads it directly. Refresh on dep bumps.
  npmDepsHash = "sha256-oNxXTgyz9qgdBn1mrZj53NA3aeg97ySx5tnqDPX7f2Q=";

  # webpack.config.js resolves the shared React renderer via
  # `../app/src/renderer/index.tsx`, so the sibling src/app/ must be present
  # at build time. unpackPhase extracts the full lemonade tarball and
  # sourceRoot only cd's, so the sibling is there — fail loudly if a future
  # upstream rearrangement breaks that assumption.
  preBuild = ''
    if [ ! -d ../app/src/renderer ]; then
      echo "expected ../app/src/renderer next to src/web-app, got:" >&2
      ls .. >&2
      exit 1
    fi
  '';

  npmBuildScript = "build";

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -r dist/renderer/. $out/
    runHook postInstall
  '';

  dontNpmInstall = true;

  meta = {
    description = "Lemonade web UI (React) — static bundle for serving by lemond";
    homepage = "https://github.com/lemonade-sdk/lemonade";
    license = lib.licenses.asl20;
    platforms = ["x86_64-linux"];
  };
}
