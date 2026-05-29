package main

import (
	"os"

	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/cli"
)

func main() { os.Exit(cli.Run(os.Args)) }
