# Throwaway experiment shell for the typed-decisions exploration (#149).
# Not a flake output: nothing under pkgs/, modules/, or flake.nix references
# this. Weights (convaiinnovations/laya, ~0.8-1.7 GB per checkpoint) and the
# allenai/ai2_arc parquet files land in the ambient HF cache ($HF_HOME or
# ~/.cache/huggingface), never in the repo.
let
  flake = import ../../default.nix;
  pkgs = import flake.inputs.nixpkgs {};

  laya = pkgs.fetchFromGitHub {
    owner = "NandhaKishorM";
    repo = "laya";
    rev = "v0.3.5";
    hash = "sha256-cbUuLBMBC7WwqAf7m7Ihs6qkx7H7FdwhPVMWfgnfg8c=";
  };

  python = pkgs.python3.withPackages (ps:
    with ps; [
      torch
      transformers
      safetensors
      huggingface-hub
      numpy
      pyarrow
    ]);
in
  pkgs.mkShell {
    packages = [python pkgs.curl pkgs.jq];
    PYTHONPATH = "${laya}";
    HF_HUB_DISABLE_TELEMETRY = "1";
  }
