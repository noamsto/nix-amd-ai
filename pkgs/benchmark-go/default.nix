{buildGoModule}:
buildGoModule {
  pname = "benchmark";
  version = "0.1.0";
  src = ./.;
  subPackages = ["cmd/benchmark"];
  vendorHash = "sha256-hys+wUeUhKREcoa02EzifCougwV50CAX4Vie2KZCBrI=";
  meta.description = "Multi-backend benchmark harness (Go)";
}
