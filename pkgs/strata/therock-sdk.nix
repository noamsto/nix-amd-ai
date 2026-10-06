# AMD's TheRock ROCm 7.14.1 SDK for gfx1151 (hipcc, clang, HIP runtime, hipBLASLt), repackaged for the Nix store.
# Strata wants this exact ROCm; nixpkgs' rocmPackages is older and lacks gfx1151 hipBLASLt kernels. The tarball is
# self-contained apart from glibc and libstdc++, so only the executables' ELF interpreter and rpath change. The shared
# objects stay untouched: patchelf rewriting libhipblaslt.so breaks it, and they resolve libstdc++ by soname from the
# copy their executable already loaded.
{
  lib,
  stdenv,
  fetchurl,
  patchelf,
}: let
  src = (import ./sources.nix).therock;
in
  stdenv.mkDerivation {
    pname = "therock-sdk-gfx1151";
    inherit (src) version;

    src = fetchurl {inherit (src) url hash;};
    sourceRoot = ".";
    nativeBuildInputs = [patchelf];

    dontConfigure = true;
    dontBuild = true;
    # Bundled ELFs carry their own $ORIGIN runpaths; do not let fixup rewrite them.
    dontFixup = true;

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -r . $out/
      chmod -R u+w $out

      loader=${stdenv.cc.bintools.dynamicLinker}
      libs=${lib.makeLibraryPath [stdenv.cc.cc.lib]}
      # Executables only: shared objects have no interpreter. Keep the existing runpath and append libstdc++.
      find $out -type f -perm -u+x ! -name '*.so*' | while read -r f; do
        if patchelf --print-interpreter "$f" >/dev/null 2>&1; then
          patchelf --set-interpreter "$loader" --add-rpath "$libs" "$f"
        fi
      done
      runHook postInstall
    '';

    meta = {
      description = "AMD TheRock ROCm SDK for gfx1151 (prebuilt)";
      homepage = "https://github.com/ROCm/TheRock";
      license = lib.licenses.mit;
      platforms = ["x86_64-linux"];
      sourceProvenance = [lib.sourceTypes.binaryNativeCode];
    };
  }
