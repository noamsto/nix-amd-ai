{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  ninja,
  pkg-config,
  git,
  python3,
  boost,
  rapidjson,
  libdrm,
  elfutils,
  libuuid,
  libsystemtap,
  xrt,
}:
let
  # Reuse XRT source for internal headers the shim needs but aren't in the installed package
  xrtSrc = xrt.src;
in
  stdenv.mkDerivation rec {
    pname = "xrt-plugin-amdxdna";
    version = "1.7-unstable-2025-06-06";
    pluginVersion = "2.21.0";

    src = fetchFromGitHub {
      owner = "amd";
      repo = "xdna-driver";
      rev = "af164d672e15cd5c09c88f18cd1cdfb6fa4f1c5c";
      hash = "sha256-PUrB0RvRZGKii0eiiSnL82UAXg3Gv4twfrvvf6/lino=";
      fetchSubmodules = true;
    };

    nativeBuildInputs = [
      cmake
      ninja
      pkg-config
      git
      python3
    ];

    buildInputs = [
      boost
      rapidjson
      libdrm
      elfutils
      libuuid
      libsystemtap
      xrt
    ];

    # Build from source root with our wrapper CMakeLists.txt
    cmakeDir = "..";

    cmakeFlags = [
      "-DCMAKE_INSTALL_PREFIX=${placeholder "out"}"
      "-DCMAKE_BUILD_TYPE=Release"
      "-DXRT_VERSION_STRING=${pluginVersion}"
      # Point to XRT installation for libraries
      "-DXRT_INSTALL_DIR=${xrt}/opt/xilinx/xrt"
      # Point to XRT source for internal headers
      "-DXRT_SOURCE_DIR=${xrtSrc}/src"
    ];

    postPatch = ''
      # Disable -Werror
      find . -name "CMakeLists.txt" -exec sed -i 's/-Werror//g' {} \; || true

      # Remove the testing install commands for XRT targets (they reference
      # IMPORTED targets which cmake refuses to install)
      sed -i '/install(TARGETS.*XRT_CORE_TARGET/d' src/shim/CMakeLists.txt
      sed -i '/install(TARGETS.*XRT_COREUTIL_TARGET/d' src/shim/CMakeLists.txt
      # Remove test install of the xdna target too
      sed -i '/install(TARGETS.*XDNA_TARGET.*DESTINATION.*XDNA_BIN_DIR/d' src/shim/CMakeLists.txt

      # Create a wrapper CMakeLists.txt that defines IMPORTED targets for XRT
      # and only builds src/shim/
      cat > CMakeLists.txt << 'CMAKEOF'
    cmake_minimum_required(VERSION 3.18)
    project(xrt-plugin-amdxdna)

    # XRT upstream mode
    set(XRT_UPSTREAM ON)

    # Create IMPORTED targets for XRT libraries
    add_library(xrt_core SHARED IMPORTED)
    set_target_properties(xrt_core PROPERTIES
      IMPORTED_LOCATION "''${XRT_INSTALL_DIR}/lib/libxrt_core.so"
      INTERFACE_INCLUDE_DIRECTORIES "''${XRT_INSTALL_DIR}/include"
    )

    add_library(xrt_coreutil SHARED IMPORTED)
    set_target_properties(xrt_coreutil PROPERTIES
      IMPORTED_LOCATION "''${XRT_INSTALL_DIR}/lib/libxrt_coreutil.so"
      INTERFACE_INCLUDE_DIRECTORIES "''${XRT_INSTALL_DIR}/include"
    )

    # Create gen directory for version.h
    file(MAKE_DIRECTORY ''${CMAKE_BINARY_DIR}/gen)

    # Create version.h stub
    file(WRITE ''${CMAKE_BINARY_DIR}/gen/version.h
    "#pragma once
    #define XRT_VERSION \"''${XRT_VERSION_STRING}\"
    #define XRT_VERSION_MAJOR 2
    #define XRT_VERSION_MINOR 21
    #define XRT_VERSION_PATCH 0
    ")

    # Set XRT_BINARY_DIR for gen includes
    set(XRT_BINARY_DIR ''${CMAKE_BINARY_DIR})

    # Plugin version
    set(XRT_PLUGIN_VERSION_STRING ''${XRT_VERSION_STRING})
    set(XRT_SOVERSION 2)

    # Package installation directories
    set(XDNA_PKG_LIB_DIR "opt/xilinx/xrt/lib")
    set(XDNA_COMPONENT "xdna")
    set(XDNA_BIN_DIR "''${CMAKE_BINARY_DIR}/bin")

    add_subdirectory(src/shim)
    CMAKEOF
    '';

    postInstall = ''
      # Ensure plugin library is in XRT's expected location
      mkdir -p $out/opt/xilinx/xrt/lib
      if [ -d $out/opt/xilinx/lib ]; then
        mv $out/opt/xilinx/lib/* $out/opt/xilinx/xrt/lib/ || true
      fi

      # Create top-level symlinks
      mkdir -p $out/lib
      for lib in $out/opt/xilinx/xrt/lib/*.so*; do
        ln -sf $lib $out/lib/ 2>/dev/null || true
      done

      # Create pkg-config file
      mkdir -p $out/lib/pkgconfig
      cat > $out/lib/pkgconfig/xrt-amdxdna.pc << EOF
      prefix=$out/opt/xilinx/xrt
      exec_prefix=\''${prefix}
      libdir=\''${exec_prefix}/lib
      includedir=\''${prefix}/include

      Name: XRT-AMDXDNA
      Description: AMD XDNA Plugin for Xilinx Runtime
      Version: ${pluginVersion}
      Requires: xrt
      Libs: -L\''${libdir} -lxrt_driver_xdna
      EOF
    '';

    meta = with lib; {
      description = "AMD XDNA driver plugin for XRT (Ryzen AI NPU support)";
      homepage = "https://github.com/amd/xdna-driver";
      license = licenses.asl20;
      platforms = ["x86_64-linux"];
    };
  }
