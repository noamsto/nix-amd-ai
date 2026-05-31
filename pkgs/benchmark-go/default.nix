{buildGoModule}:
buildGoModule {
  pname = "benchmark";
  version = "0.1.0";
  src = ./.;
  subPackages = ["cmd/benchmark"];
  vendorHash = "sha256-CBmwAVno6OqFdKcUk66MuP5+nI4Z3aQI4kcmT+YbqYY=";
  meta.description = "Multi-backend benchmark harness (Go)";
}
