# XRT with the amdxdna driver plugin next to its libraries. On Linux XRT
# takes its root from the path libxrt_coreutil was loaded from (dladdr, with
# symlinks left unresolved; common/detail/linux/xilinx_xrt.h) and looks for
# driver plugins in that root's lib/. So a binary that loads libxrt_coreutil
# through this package's lib/ finds the plugin; one linked against plain xrt
# loads it from ${xrt}/lib, where there is no plugin, and sees no NPU.
{
  symlinkJoin,
  xrt,
  xrt-plugin-amdxdna,
}:
symlinkJoin {
  name = "xrt-combined-${xrt.version}";
  paths = [xrt xrt-plugin-amdxdna];

  # xrt.pc names xrt's own prefix, so a consumer that finds XRT through
  # pkg-config would get -L${xrt}/lib, and the linker wrapper would put
  # ${xrt}/lib on its RUNPATH next to (and possibly ahead of) this lib/.
  postBuild = ''
    pc=$out/lib/pkgconfig/xrt.pc
    target=$(readlink -f "$pc")
    rm "$pc"
    substitute "$target" "$pc" --replace-fail "${xrt}" "$out"
  '';

  passthru = {
    inherit xrt;
    plugin = xrt-plugin-amdxdna;
  };

  meta =
    xrt.meta
    // {
      description = "XRT with the amdxdna NPU driver plugin";
    };
}
