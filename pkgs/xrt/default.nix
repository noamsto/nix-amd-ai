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
  # Pinned to the commit that amd/xdna-driver branch 1.7 references as a submodule
  version = "unstable-2025-06-06";

  src = fetchFromGitHub {
    owner = "Xilinx";
    repo = "XRT";
    rev = "89b2f18e7060be7487595b8800f729589b0e83ee";
    hash = "sha256-nQuR8lZufaT4YPrCD7eFqdBTRf/K6Q3NRHlu0hYHHt0=";
    fetchSubmodules = true;
  };

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
    # Disable kernel module building (we use mainline amdxdna)
    "-DXRT_DKMS_DRIVER_SRC_BASE_DIR="
    # XRT_UPSTREAM_DEBIAN enables XRT_UPSTREAM which propagates to AIEBU_UPSTREAM
    # This disables static linking in aiebu tools
    "-DXRT_UPSTREAM_DEBIAN=ON"
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
  ];

  postPatch = ''
    # Fix Python3 detection — /usr/bin/python3 doesn't exist in the Nix sandbox
    substituteInPlace src/python/pybind11/CMakeLists.txt \
      --replace-quiet '/usr/bin/python3' "${pythonWithPackages}/bin/python3" || true

    # Remove kernel module references
    substituteInPlace src/CMakeLists.txt \
      --replace-quiet 'add_subdirectory(runtime_src/core/pcie/driver)' '#add_subdirectory(runtime_src/core/pcie/driver)' || true

    # Fix hardcoded /usr/src DKMS install path
    for f in src/CMake/version.cmake src/CMake/dkms.cmake src/CMake/dkms-edge.cmake; do
      if [ -f "$f" ]; then
        sed -i 's|/usr/src/xrt-|''${CMAKE_INSTALL_PREFIX}/share/xrt-dkms-src/xrt-|g' "$f"
      fi
    done
    if [ -f src/CMake/dkms-aws.cmake ]; then
      sed -i 's|/usr/src/xrt-aws-|''${CMAKE_INSTALL_PREFIX}/share/xrt-dkms-src/xrt-aws-|g' src/CMake/dkms-aws.cmake
    fi

    # Fix hardcoded /usr/local/bin install paths for xbflash tools
    for f in src/runtime_src/core/tools/xbflash2/CMakeLists.txt src/runtime_src/core/pcie/tools/xbflash.qspi/CMakeLists.txt; do
      if [ -f "$f" ]; then
        sed -i 's|"/usr/local/bin"|"''${CMAKE_INSTALL_PREFIX}/bin"|g' "$f"
      fi
    done

    # Fix /etc/OpenCL/vendors path for OpenCL ICD registration
    if [ -f src/CMake/icd.cmake ]; then
      sed -i 's|/etc/OpenCL/vendors|''${CMAKE_INSTALL_PREFIX}/etc/OpenCL/vendors|g' src/CMake/icd.cmake
    fi

    # Fix hardcoded /opt/xilinx/xrt in config_reader
    substituteInPlace src/runtime_src/core/common/config_reader.cpp \
      --replace-quiet '/opt/xilinx/xrt' '${placeholder "out"}/opt/xilinx/xrt' || true

    # Fake /etc/os-release for the build
    mkdir -p $TMPDIR/etc
    echo 'ID=nixos' > $TMPDIR/etc/os-release
    echo 'VERSION_ID="25.11"' >> $TMPDIR/etc/os-release

    # Patch CMake scripts that try to read /etc/os-release
    find . -name "*.cmake" -o -name "CMakeLists.txt" | xargs sed -i \
      -e 's|/etc/os-release|'$TMPDIR'/etc/os-release|g' || true

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
