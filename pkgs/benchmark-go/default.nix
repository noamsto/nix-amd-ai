{buildGoModule}:
buildGoModule {
  pname = "benchmark";
  version = "0.1.0";
  src = ./.;
  subPackages = ["cmd/benchmark"];
  vendorHash = "sha256-76yvZ8MhGnJhkfBALS/MYAeEmkOcLX0VKu1zTtPLhxo=";
  meta.description = "Multi-backend benchmark harness (Go)";
}
