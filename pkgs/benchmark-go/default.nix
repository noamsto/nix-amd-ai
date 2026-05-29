{buildGoModule}:
buildGoModule {
  pname = "benchmark";
  version = "0.1.0";
  src = ./.;
  vendorHash = null; # no external deps yet; set after Charm is added
  meta.description = "Multi-backend benchmark harness (Go)";
}
