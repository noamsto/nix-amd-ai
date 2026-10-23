{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  ninja,
  pkg-config,
  git,
  python312,
  boost,
  opencl-headers,
  opencl-clhpp,
  ocl-icd,
  rapidjson,
  protobuf,
  elfutils,
  libdrm,
  systemd,
  curl,
  openssl,
  libuuid,
  libxcrypt,
  ncurses,
  libsystemtap,
  wget,
}:
stdenv.mkDerivation rec {
  pname = "xrt";
  # Pinned to the commit that amd/xdna-driver branch 1.9 references as a submodule
  version = "unstable-2026-08-13";

  src = fetchFromGitHub {
    owner = "Xilinx";
    repo = "XRT";
    rev = "e9db9ab15f10173f8d2fc93ff92ab4c7eb09d2e6";
    hash = "sha256-C/PQDHH8t41pUYZv2PB8iCOKkXQ9Af5NX8QK98NvI7k=";
    fetchSubmodules = true;
  };

  patches = [
    # Make the /etc/os-release based distro detection overridable, so
    # LINUX_FLAVOR and LINUX_VERSION can be passed in below. Without it both
    # end up empty in the sandbox, which is a hard error in the unquoted
    # `if (${LINUX_FLAVOR} ...)` conditions the build uses.
    # https://github.com/Xilinx/XRT/pull/10071
    ./allow-overriding-distro-detection.patch
    # Honour AIEBU_UPSTREAM for the build date, which upstream guards for XRT
    # itself but forgot for the bundled aiebu submodule.
    # https://github.com/Xilinx/aiebu/pull/388
    ./aiebu-reproducible-build-date.patch
  ];

  # Python with packages needed by spec_tool.py during build
  pythonWithPackages = python312.withPackages (ps: [
    ps.pyyaml
    ps.markdown
    ps.jinja2
    ps.pybind11
  ]);

  nativeBuildInputs = [
    cmake
    ninja
    pkg-config
    git
    pythonWithPackages
    wget
  ];

  buildInputs = [
    boost
    opencl-headers
    opencl-clhpp
    ocl-icd
    rapidjson
    protobuf
    elfutils
    libdrm
    systemd
    curl
    openssl
    libuuid
    libxcrypt
    ncurses
    libsystemtap
  ];

  cmakeDir = "../src";

  cmakeFlags = [
    "-DCMAKE_INSTALL_PREFIX=${placeholder "out"}/opt/xilinx/xrt"
    "-DXRT_INSTALL_PREFIX=${placeholder "out"}/opt/xilinx/xrt"
    "-DCMAKE_BUILD_TYPE=Release"
    "-DDISABLE_WERROR=ON"
    # abseil (via protobuf) requires C++20 <compare>; XRT defaults to 17
    "-DCMAKE_CXX_STANDARD=20"
    # Its host_defines.h defines __noinline__ empty, which breaks libstdc++'s
    # <format> (pulled in by <chrono> under C++20). Nothing here uses HIP.
    "-DXRT_ENABLE_HIP=OFF"
    # Disable kernel module building (we use mainline amdxdna)
    "-DXRT_DKMS_DRIVER_SRC_BASE_DIR="
    # XRT_UPSTREAM_DEBIAN enables XRT_UPSTREAM which propagates to AIEBU_UPSTREAM
    # This disables static linking in aiebu tools
    "-DXRT_UPSTREAM_DEBIAN=ON"
    "-DLINUX_FLAVOR=nixos"
    "-DLINUX_VERSION=${lib.versions.majorMinor lib.version}"
    # Override install dirs to relative paths to prevent aiebu cmake path issues
    "-DCMAKE_INSTALL_LIBDIR=lib"
    "-DCMAKE_INSTALL_BINDIR=bin"
    "-DCMAKE_INSTALL_INCLUDEDIR=include"
    # Enable Python bindings (pyxrt)
    "-DXRT_ENABLE_PYXRT=ON"
    "-DPython3_EXECUTABLE=${pythonWithPackages}/bin/python3"
    "-DPython3_INCLUDE_DIR=${pythonWithPackages}/include/python3.12"
    "-DPython3_LIBRARY=${pythonWithPackages}/lib/libpython3.12.so"
    "-DPYTHON_EXECUTABLE=${pythonWithPackages}/bin/python3"
    # aiebu's test/CMakeLists.txt guards its cmake-test behind AIEBU_SUBMODULE
    # ("Whomever added this test, please make it work when AIEBU is built as a
    # submodule from XRT"), but nothing in the XRT tree ever sets it, so the
    # test is registered anyway and fails for want of a staging area. This is
    # exactly the submodule build that guard is meant to cover.
    "-DAIEBU_SUBMODULE=ON"
  ];

  postPatch = ''
    # Fix Python3 detection — /usr/bin/python3 doesn't exist in the Nix sandbox
    substituteInPlace src/python/pybind11/CMakeLists.txt \
      --replace-quiet '/usr/bin/python3' "${pythonWithPackages}/bin/python3" || true

    # Disable -Werror globally
    find . -name "CMakeLists.txt" -exec sed -i 's/-Werror//g' {} \; || true

    # Create stub markdown_graphviz_svg.py to avoid network download
    cat > src/runtime_src/core/common/aiebu/specification/markdown_graphviz_svg.py << 'PYEOF'
# Stub — the real module is https://github.com/Tanami/markdown-graphviz-svg
from markdown.extensions import Extension

class GraphvizBlocksExtension(Extension):
    def extendMarkdown(self, md):
        pass

GraphvizExtension = GraphvizBlocksExtension

def makeExtension(**kwargs):
    return GraphvizBlocksExtension(**kwargs)
PYEOF

    # Replace wget commands in CMakeLists with no-ops
    find . -name "CMakeLists.txt" -exec grep -l "wget" {} \; | while read f; do
      sed -i 's|COMMAND wget|COMMAND true # wget|g' "$f"
      sed -i 's|COMMAND powershell wget|COMMAND true # powershell wget|g' "$f"
    done

    # Disable spec generation targets that cause issues at install time
    specCmake="src/runtime_src/core/common/aiebu/specification/aie2ps/CMakeLists.txt"
    if [ -f "$specCmake" ]; then
      cat > "$specCmake" << 'STUBCMAKE'
# Disabled for Nix build — spec generation causes issues
message(STATUS "Skipping aie2ps spec generation (Nix build)")
STUBCMAKE
    fi

    # Fix shebangs for Python scripts
    patchShebangs --build src/runtime_src/core/common/aiebu/specification/
    patchShebangs --build src/runtime_src/core/common/aiebu/src/python/ || true
    patchShebangs --build src/runtime_src/core/common/aiebu/test/
  '';

  # Most install destinations are relative to CMAKE_INSTALL_PREFIX already;
  # only these three are absolute paths that would escape $out. Each rule is
  # anchored on the opening quote, or on the } of the "$ENV{DESTDIR}/usr/..."
  # paths the RPATH fixup after an install checks: rewriting only the former
  # installs xbflash2 but skips its fixup, leaving a /build RPATH. Anchoring
  # also keeps a rule from rewriting a destination an earlier rule has already
  # redirected, and leaves the prefix-relative destinations untouched.
  preInstall = ''
    find . -name cmake_install.cmake -exec sed -i \
      -e 's|\(["}]\)/usr/src|\1'"$out"'/opt/xilinx/xrt/share/xrt-dkms-src|g' \
      -e 's|\(["}]\)/usr/local|\1'"$out"'/opt/xilinx/xrt|g' \
      -e 's|\(["}]\)/etc/OpenCL|\1'"$out"'/opt/xilinx/xrt/etc/OpenCL|g' \
      {} \;
  '';

  doCheck = true;

  # Only the aiebu suite: it runs aiebu-asm over .asm fixtures and compares
  # against checked-in .gold files, needing nothing but the build tree. XRT's
  # own tests are not run - they want a staging install to source setup.sh
  # from, python and the openssl CLI, and real hardware for xrt-smi/xbmgmt2.
  checkPhase = ''
    runHook preCheck
    # The suite's python tools load libelf through ctypes.CDLL("libelf.so").
    export LD_LIBRARY_PATH=${lib.getLib elfutils}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
    ctest --test-dir runtime_src/core/common/aiebu --output-on-failure
    runHook postCheck
  '';

  postInstall = ''
    # Create convenience symlinks at top level
    mkdir -p $out/bin $out/lib $out/include

    for bin in $out/opt/xilinx/xrt/bin/*; do
      ln -sf $bin $out/bin/
    done

    for lib in $out/opt/xilinx/xrt/lib/*.so*; do
      ln -sf $lib $out/lib/
    done

    cp $out/opt/xilinx/xrt/setup.sh $out/ || true

    # Create pkg-config file
    mkdir -p $out/lib/pkgconfig
    cat > $out/lib/pkgconfig/xrt.pc << EOF
    prefix=$out/opt/xilinx/xrt
    exec_prefix=\''${prefix}
    libdir=\''${exec_prefix}/lib
    includedir=\''${prefix}/include

    Name: XRT
    Description: Xilinx Runtime for AMD NPU
    Version: ${version}
    Libs: -L\''${libdir} -lxrt_coreutil
    Cflags: -I\''${includedir}
    EOF
  '';

  meta = with lib; {
    description = "Xilinx Runtime (XRT) for AMD Ryzen AI NPU";
    homepage = "https://github.com/Xilinx/XRT";
    license = licenses.asl20;
    platforms = ["x86_64-linux"];
  };
}
