{buildGoModule}:
buildGoModule {
  pname = "benchmark";
  version = "0.1.0";
  src = ./.;
  subPackages = ["cmd/benchmark"];
  vendorHash = null; # using vendored dependencies (vendor/ committed)
  meta.description = "Multi-backend benchmark harness (Go)";
}
