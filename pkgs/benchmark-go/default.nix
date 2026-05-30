{buildGoModule}:
buildGoModule {
  pname = "benchmark";
  version = "0.1.0";
  src = ./.;
  subPackages = ["cmd/benchmark"];
  vendorHash = "sha256-FkmyRaHsKMiu63EkvLiMnnMdYrZduUz1x/e7bs/+uUU=";
  meta.description = "Multi-backend benchmark harness (Go)";
}
