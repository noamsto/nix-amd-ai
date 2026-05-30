{buildGoModule}:
buildGoModule {
  pname = "benchmark";
  version = "0.1.0";
  src = ./.;
  subPackages = ["cmd/benchmark"];
  vendorHash = "sha256-TbdG0y8yLnjSB0RLvlX6CDZeTkgB/6OUvfDkE6qittc=";
  meta.description = "Multi-backend benchmark harness (Go)";
}
