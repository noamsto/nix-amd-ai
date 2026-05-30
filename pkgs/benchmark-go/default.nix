{buildGoModule}:
buildGoModule {
  pname = "benchmark";
  version = "0.1.0";
  src = ./.;
  subPackages = ["cmd/benchmark"];
  vendorHash = "sha256-MHO1e5yTBR+HFXGExNJRjocx+IjONHJ8n2kccbNfsag=";
  meta.description = "Multi-backend benchmark harness (Go)";
}
