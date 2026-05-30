package cli

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/bench"
	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/models"
	"golang.org/x/term"
)

// opts holds all parsed CLI flags + positional args, matching Python's
// argparse namespace (main ~867-1048).
type opts struct {
	// Positional
	ModelIDs []string

	// Lemonade connection
	BaseURL string

	// Measurement parameters
	PromptTokens int
	GenTokens    int
	Warmup       int
	Repeat       int
	MinDecodeTPS float64 // exit 1 gate; default 5.0

	// Backend switch (lemonade mode)
	Backend       string // "rocm", "vulkan", "auto", or ""
	ConfigPath    string
	LemondService string
	NoRestart     bool

	// MTP A/B mode
	MTPAb         string // model ID for --mtp-ab; "" means normal mode
	MTPAbBackends string // comma-separated; default "rocm,vulkan"

	// Ctx size (Go extension: Python hardcodes 2048 in run_mtp_ab)
	CtxSize int

	// Go-specific
	NoTUI bool
}

// parseFlags parses args[1:] into opts. Returns (o, nil) on success,
// (opts{}, flag.ErrHelp) when --help/-h is seen, and (opts{}, err) on parse
// error. On mutual-exclusion violation it returns an error (callers print +
// exit 2).
func parseFlags(args []string) (opts, error) {
	fs := flag.NewFlagSet("benchmark", flag.ContinueOnError)
	fs.Usage = func() {
		fmt.Fprintf(fs.Output(), "Usage: benchmark [flags] [MODEL_ID ...]\n\n")
		fmt.Fprintf(fs.Output(), "Benchmark lemonade backends via HTTP API.\n\n")
		fs.PrintDefaults()
	}

	var o opts

	// Lemonade connection
	fs.StringVar(&o.BaseURL, "base-url", "http://localhost:13305",
		"Lemonade server base URL")

	// Measurement parameters
	fs.IntVar(&o.PromptTokens, "prompt-tokens", 512,
		"Approximate number of prompt tokens")
	fs.IntVar(&o.GenTokens, "gen-tokens", 128,
		"Number of tokens to request per completion")
	fs.IntVar(&o.Warmup, "warmup", 1,
		"Number of warmup iterations before measurement")
	fs.IntVar(&o.Repeat, "repeat", 3,
		"Number of measurement iterations")
	fs.Float64Var(&o.MinDecodeTPS, "min-decode-tps", 5.0,
		"Minimum acceptable decode t/s; exit 1 if any model falls below this (signals CPU fallback)")

	// Backend switch
	fs.StringVar(&o.Backend, "backend", "",
		`Force llamacpp.backend in lemonade config and restart lemond before benchmarking (choices: rocm, vulkan, auto)`)
	fs.StringVar(&o.ConfigPath, "config-path",
		filepath.Join(os.Getenv("HOME"), ".cache", "lemonade", "config.json"),
		"Path to lemonade's config.json")
	fs.StringVar(&o.LemondService, "lemond-service", "lemond.service",
		"systemd service name to restart when --backend is set")
	fs.BoolVar(&o.NoRestart, "no-restart", false,
		"Skip sudo systemctl restart after writing the config")

	// MTP A/B
	fs.StringVar(&o.MTPAb, "mtp-ab", "",
		"Run MTP on/off A/B for MODEL_ID (mutually exclusive with positional MODEL_IDs)")
	fs.StringVar(&o.MTPAbBackends, "mtp-ab-backends", "rocm,vulkan",
		"Comma-separated backends to sweep when --mtp-ab is set")

	// Ctx size (Go extension; Python hardcodes 2048 for MTP A/B)
	fs.IntVar(&o.CtxSize, "ctx-size", 2048,
		"llama-server --ctx-size for MTP A/B mode (Go extension; Python hardcodes 2048)")

	// Go-specific
	fs.BoolVar(&o.NoTUI, "no-tui", false,
		"Disable interactive TUI; print markdown to stdout")

	if err := fs.Parse(args[1:]); err != nil {
		return opts{}, err
	}
	o.ModelIDs = fs.Args()

	// Mutual exclusion: --mtp-ab vs positional MODEL_IDs (matches Python ~972-979).
	if o.MTPAb != "" && len(o.ModelIDs) > 0 {
		return opts{}, fmt.Errorf("--mtp-ab is mutually exclusive with positional MODEL_ID arguments")
	}

	// Backend validation: match Python's choices=["rocm","vulkan","auto"].
	if o.Backend != "" {
		switch o.Backend {
		case "rocm", "vulkan", "auto":
			// ok
		default:
			return opts{}, fmt.Errorf("--backend: invalid choice %q; expected one of: rocm, vulkan, auto", o.Backend)
		}
	}

	return o, nil
}

// Run is the program entrypoint. Returns a process exit code.
//
// Exit codes matching Python:
//   - 0  all models passed min-decode-tps threshold (or MTP A/B ok)
//   - 1  one or more models below min-decode-tps (CPU-fallback gate)
//   - 2  hard error: server unreachable, model not found/downloaded,
//     device not ready, or bad arguments
func Run(args []string) int {
	o, err := parseFlags(args)
	if err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return 0
		}
		fmt.Fprintf(os.Stderr, "ERROR: %v\n", err)
		return 2
	}

	// Detect a TTY on stdout, not stdin: `benchmark | tee log` leaves stdin a
	// TTY but stdout a pipe, and should print markdown rather than launch the TUI.
	interactive := !o.NoTUI && term.IsTerminal(int(os.Stdout.Fd()))
	if interactive {
		return runTUI(o)
	}
	return runHeadless(o)
}

// runTUI is a Phase 5 stub. Returns 2 (not 0) so scripts don't read the
// not-yet-implemented interactive path as success.
func runTUI(_ opts) int {
	fmt.Fprintln(os.Stderr, "interactive TUI not yet implemented; use --no-tui")
	return 2
}

// runHeadless drives the real benchmark calls and prints a markdown table.
// Mirrors Python's main() / run_benchmarks().
func runHeadless(o opts) int {
	if o.MTPAb != "" {
		return runHeadlessMTPAB(o)
	}
	return runHeadlessLemonade(o)
}

// runHeadlessMTPAB implements the --mtp-ab path. Mirrors Python's run_mtp_ab
// call in main().
func runHeadlessMTPAB(o opts) int {
	backends := splitBackends(o.MTPAbBackends)
	if len(backends) == 0 {
		fmt.Fprintln(os.Stderr, "ERROR: --mtp-ab-backends produced an empty backend list")
		return 2
	}

	abOpts := bench.MTPABOpts{
		ModelID:      o.MTPAb,
		Backends:     backends,
		PromptTokens: o.PromptTokens,
		GenTokens:    o.GenTokens,
		Warmup:       o.Warmup,
		Repeat:       o.Repeat,
		CtxSize:      o.CtxSize,
	}

	results, err := bench.RunMTPAB(abOpts)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ERROR: %v\n", err)
		// exit 1 for MTP-head-absent (mirrors Python's sys.exit(1) in run_mtp_ab)
		if errors.Is(err, bench.ErrNoMTPHead) {
			return 1
		}
		return 2
	}

	rows := make([]MTPRow, 0, len(results))
	for _, r := range results {
		rows = append(rows, MTPRow{
			Model:   o.MTPAb,
			Backend: r.Backend,
			OffTPS:  r.OffTPS,
			OnTPS:   r.OnTPS,
		})
	}

	fmt.Print(RenderMTPMarkdownTable(rows))
	return 0
}

// runHeadlessLemonade implements the normal lemonade path (positional MODEL_IDs).
// Mirrors Python's run_benchmarks().
func runHeadlessLemonade(o opts) int {
	if len(o.ModelIDs) == 0 {
		fmt.Fprintln(os.Stderr, "ERROR: at least one MODEL_ID is required (or use --mtp-ab)")
		return 2
	}

	baseURL := strings.TrimRight(o.BaseURL, "/")

	fmt.Fprintf(os.Stderr, "Benchmarking %d model(s) against %s\n",
		len(o.ModelIDs), baseURL)

	// --- Backend switch: rewrite lemonade config + restart lemond ---
	// Mirrors Python's try/finally block in main(). The deferred restore is the
	// single restore site: registered the moment the config is written, it runs
	// on every return path (success, below-threshold, or pre-benchmark failure)
	// with no ordering dependency on later code.
	prevBackend := ""
	backendForced := false
	defer func() {
		if !backendForced {
			return
		}
		if err := bench.RestoreLlamacppBackend(o.ConfigPath, prevBackend); err != nil {
			fmt.Fprintf(os.Stderr, "WARNING: failed to restore lemonade config: %v\n", err)
		} else {
			fmt.Fprintf(os.Stderr, "  Restored llamacpp.backend to %q\n", prevBackend)
		}
		if !o.NoRestart {
			if err := bench.RestartLemond(o.LemondService); err != nil {
				fmt.Fprintf(os.Stderr, "WARNING: failed to restart lemond during cleanup: %v\n", err)
			}
		}
	}()

	if o.Backend != "" {
		var err error
		prevBackend, err = bench.SetLlamacppBackend(o.ConfigPath, o.Backend)
		if err != nil {
			// Config was not written → nothing to restore; defer stays a no-op.
			fmt.Fprintf(os.Stderr, "ERROR: writing lemonade config: %v\n", err)
			return 2
		}
		// Config written: arm the deferred restore for all subsequent returns.
		backendForced = true
		fmt.Fprintf(os.Stderr, "  Forced llamacpp.backend = %q (was %q) in %s\n",
			o.Backend, prevBackend, o.ConfigPath)

		if !o.NoRestart {
			if err := bench.RestartLemond(o.LemondService); err != nil {
				fmt.Fprintf(os.Stderr, "ERROR: %v\n", err)
				return 2
			}
			if err := bench.WaitForLemond(baseURL, 60e9); err != nil { // 60s
				fmt.Fprintf(os.Stderr, "ERROR: %v\n", err)
				return 2
			}
		}
	}

	// --- Step 1: validate models exist and are downloaded ---
	// Mirrors Python's check_models().
	allModels, err := models.Fetch(baseURL)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ERROR: cannot reach lemonade at %s: %v\n", baseURL, err)
		return 2
	}

	modelMap := make(map[string]models.Model, len(allModels))
	for _, m := range allModels {
		modelMap[m.ID] = m
	}

	var notFound []string
	var notDownloaded []string
	for _, mid := range o.ModelIDs {
		m, ok := modelMap[mid]
		if !ok {
			notFound = append(notFound, mid)
		} else if !m.Downloaded {
			notDownloaded = append(notDownloaded, mid)
		}
	}
	if len(notFound) > 0 {
		fmt.Fprintf(os.Stderr, "ERROR: models not found: %s\n", strings.Join(notFound, ", "))
		return 2
	}
	if len(notDownloaded) > 0 {
		fmt.Fprintf(os.Stderr,
			"ERROR: models not downloaded (run 'lemonade pull <model>'): %s\n",
			strings.Join(notDownloaded, ", "))
		return 2
	}

	// modelRecipe returns the recipe string for a model, rewriting it when
	// --backend forced a specific llamacpp backend (mirrors Python's model_recipe).
	modelRecipe := func(mid string) string {
		m := modelMap[mid]
		raw := m.Recipe
		if raw == "" {
			raw = "unknown"
		}
		// Rewrite llamacpp* recipe when a specific backend was forced.
		if (o.Backend == "rocm" || o.Backend == "vulkan") &&
			strings.HasPrefix(raw, "llamacpp") {
			return "llamacpp:" + o.Backend
		}
		return raw
	}

	// --- Step 2: benchmark each model ---
	var rows []Row
	var belowThreshold []string

	for _, mid := range o.ModelIDs {
		recipe := modelRecipe(mid)
		fmt.Fprintf(os.Stderr, "\nBenchmarking %q (recipe=%s)...\n", mid, recipe)

		bmOpts := bench.BenchmarkModelOpts{
			BaseURL:      baseURL,
			ModelID:      mid,
			PromptTokens: o.PromptTokens,
			GenTokens:    o.GenTokens,
			Warmup:       o.Warmup,
			Repeat:       o.Repeat,
		}
		result, bmErr := bench.BenchmarkModel(bmOpts)
		if bmErr != nil {
			fmt.Fprintf(os.Stderr, "ERROR: benchmarking %q: %v\n", mid, bmErr)
			return 2
		}

		rows = append(rows, Row{
			Model:    mid,
			Backend:  recipe,
			MeanTTFT: result.MeanTTFT,
			MeanTPS:  result.MeanTPS,
			StdevTPS: result.StdevTPS,
		})

		// min-decode-tps gate (exit 1 for CPU fallback).
		// Only checked when MeanTPS is non-nil (i.e. there were successful iters).
		if result.MeanTPS != nil && *result.MeanTPS < o.MinDecodeTPS {
			belowThreshold = append(belowThreshold,
				fmt.Sprintf("%q (%s): %.1f t/s < %.1f t/s threshold",
					mid, recipe, *result.MeanTPS, o.MinDecodeTPS))
		}
	}

	// --- Step 3: print results table ---
	fmt.Println()
	fmt.Print(RenderMarkdownTable(rows))

	// --- Step 4: exit 1 if any model below threshold ---
	if len(belowThreshold) > 0 {
		fmt.Fprintf(os.Stderr,
			"\nERROR: the following models are below the minimum decode t/s threshold (%.1f t/s) -- likely CPU fallback:\n",
			o.MinDecodeTPS)
		for _, msg := range belowThreshold {
			fmt.Fprintf(os.Stderr, "  %s\n", msg)
		}
		return 1
	}

	fmt.Fprintln(os.Stderr, "\nAll models passed minimum decode t/s threshold.")
	return 0
}

// splitBackends splits a comma-separated backend string, matching Python's
// [b.strip() for b in s.split(",") if b.strip()].
func splitBackends(s string) []string {
	parts := strings.Split(s, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if t := strings.TrimSpace(p); t != "" {
			out = append(out, t)
		}
	}
	return out
}
