# Fancy Benchmark TUI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Python `benchmark.py` harness with a portable Go + Charm binary that adds an interactive preflight guard, system-aware model/param suggestions, and a fancy TUI — while keeping a headless flag mode at behavior parity.

**Architecture:** A new Go module at `pkgs/benchmark-go/` built with `buildGoModule`, organized into small single-purpose packages (`hw`, `preflight`, `models`, `bench`, `advise`, `tui`, `cli`). Pure/deterministic logic (`bench` stats/SSE, `advise` math) is unit-tested without hardware; `hw`/`preflight` are tested against captured fixtures. The flake's `packages.benchmark` and `apps.benchmark` repoint to the Go build once it reaches headless parity, then `pkgs/benchmark/` (Python) is deleted.

**Tech Stack:** Go 1.23+, Charm `bubbletea`/`lipgloss`/`bubbles`, `teatest` for TUI tests, Nix `buildGoModule`. Module path: `github.com/noamsto/nix-amd-ai/pkgs/benchmark-go`.

---

## File Structure

```
pkgs/benchmark-go/
  go.mod                          module github.com/noamsto/nix-amd-ai/pkgs/benchmark-go
  go.sum
  default.nix                     buildGoModule { pname = "benchmark"; ... }
  main.go                         tiny: calls cli.Run(os.Args)
  internal/
    bench/
      stats.go        stats.go    mean/stdev
      sse.go          sse_test.go SSE data-line parsing + token counting
      prompt.go       prompt_test.go  build_prompt / build_mtp_prompt
      payload.go      payload_test.go completion payload builder (ignore_eos)
      devices.go      devices_test.go parse_llama_devices / pick_device
      gguf.go         gguf_test.go    resolve_lemonade_gguf
      config.go       config_test.go  lemonade config read/rewrite/restore
      server.go       server_test.go  LlamaServer spawn/ready/teardown
      args.go         args_test.go    build_llama_server_args
      run.go                          benchmark_model, run_mtp_ab, measure_one_spec
    hw/
      hw.go           hw_test.go      Detect() -> Info; fixture-driven parsers
      testdata/                       captured amdgpu_top JSON, sysfs files
    preflight/
      preflight.go    preflight_test.go  Check(), Checklist, fixers
    models/
      models.go       models_test.go  lemonade /api/v1/models + fit check
    advise/
      advise.go       advise_test.go  ceiling math, fit ranking, params
    tui/
      app.go                          root bubbletea model + screen routing
      hwpanel.go                      hardware panel screen
      preflight.go                    preflight checklist screen
      mode.go                         mode picker
      modelpick.go                    model picker
      params.go                       params form
      run.go                          live run screen
      results.go                      results + markdown export
      app_test.go                     teatest golden-path
    cli/
      cli.go          cli_test.go     flag parsing, headless vs TUI routing
      markdown.go     markdown_test.go markdown table rendering
```

---

## Phase 0 — Scaffold & packaging

### Task 0.1: Go module + hello-world binary

**Files:**
- Create: `pkgs/benchmark-go/go.mod`
- Create: `pkgs/benchmark-go/main.go`
- Create: `pkgs/benchmark-go/internal/cli/cli.go`

- [ ] **Step 1: Enter a Go dev shell**

Run: `nix shell nixpkgs#go nixpkgs#gopls --command fish`
Expected: `go version` prints `go1.23` or newer.

- [ ] **Step 2: Create the module**

`pkgs/benchmark-go/go.mod`:
```
module github.com/noamsto/nix-amd-ai/pkgs/benchmark-go

go 1.23
```

- [ ] **Step 3: Minimal cli + main**

`pkgs/benchmark-go/internal/cli/cli.go`:
```go
package cli

import "fmt"

// Run is the program entrypoint. Returns a process exit code.
func Run(args []string) int {
	fmt.Println("benchmark (go) — scaffold")
	return 0
}
```

`pkgs/benchmark-go/main.go`:
```go
package main

import (
	"os"

	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/cli"
)

func main() { os.Exit(cli.Run(os.Args)) }
```

- [ ] **Step 4: Build and run**

Run: `cd pkgs/benchmark-go; go build ./... && go run .`
Expected: prints `benchmark (go) — scaffold`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add pkgs/benchmark-go/go.mod pkgs/benchmark-go/main.go pkgs/benchmark-go/internal/cli/cli.go
git commit -m "feat(benchmark-go): scaffold Go module + hello binary"
```

### Task 0.2: Nix packaging (parallel build, not yet wired as default)

**Files:**
- Create: `pkgs/benchmark-go/default.nix`
- Modify: `flake.nix:114-126` (add `benchmark-go` to `packages`)

- [ ] **Step 1: Write the derivation**

`pkgs/benchmark-go/default.nix`:
```nix
{buildGoModule}:
buildGoModule {
  pname = "benchmark";
  version = "0.1.0";
  src = ./.;
  vendorHash = null; # no external deps yet; set after Charm is added
  meta.description = "Multi-backend benchmark harness (Go)";
}
```

- [ ] **Step 2: Wire as a separate package**

In `flake.nix` `packages = { ... }` block (around line 114-126), add:
```nix
          benchmark-go = pkgs.callPackage ./pkgs/benchmark-go {};
```

- [ ] **Step 3: Build via Nix**

Run: `nix build .#benchmark-go && ./result/bin/benchmark`
Expected: prints the scaffold line. (If `vendorHash` errors appear, they come later when deps are added.)

- [ ] **Step 4: Commit**

```bash
git add pkgs/benchmark-go/default.nix flake.nix
git commit -m "build(benchmark-go): package with buildGoModule as .#benchmark-go"
```

---

## Phase 1 — Measurement core (headless parity)

> Port `pkgs/benchmark/benchmark.py` 1:1. Read the Python source for each function before porting; the parity bar is `pkgs/benchmark/tests/test_benchmark.py`.

### Task 1.1: Stats (mean/stdev)

**Files:**
- Create: `pkgs/benchmark-go/internal/bench/stats.go`
- Test: `pkgs/benchmark-go/internal/bench/stats_test.go`

- [ ] **Step 1: Write the failing test**

```go
package bench

import (
	"math"
	"testing"
)

func TestMeanStdev(t *testing.T) {
	m, sd := MeanStdev([]float64{10, 12, 14})
	if m != 12 {
		t.Fatalf("mean=%v want 12", m)
	}
	if math.Abs(sd-2) > 1e-9 {
		t.Fatalf("stdev=%v want 2", sd)
	}
}

func TestMeanStdevSingle(t *testing.T) {
	m, sd := MeanStdev([]float64{7})
	if m != 7 || sd != 0 {
		t.Fatalf("got %v,%v want 7,0", m, sd)
	}
}

func TestMeanStdevEmpty(t *testing.T) {
	m, sd := MeanStdev(nil)
	if m != 0 || sd != 0 {
		t.Fatalf("got %v,%v want 0,0", m, sd)
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/bench/ -run TestMeanStdev -v`
Expected: FAIL — `undefined: MeanStdev`.

- [ ] **Step 3: Implement**

`stats.go`:
```go
package bench

import "math"

// MeanStdev returns the sample mean and population stdev (matching Python's
// statistics.pstdev used in benchmark.py). Empty -> (0,0); single -> (x,0).
func MeanStdev(xs []float64) (mean, stdev float64) {
	n := len(xs)
	if n == 0 {
		return 0, 0
	}
	var sum float64
	for _, x := range xs {
		sum += x
	}
	mean = sum / float64(n)
	if n == 1 {
		return mean, 0
	}
	var sq float64
	for _, x := range xs {
		d := x - mean
		sq += d * d
	}
	return mean, math.Sqrt(sq / float64(n))
}
```

> NOTE: confirm against `benchmark.py` whether it uses `statistics.stdev` (sample, n-1) or `pstdev` (population, n). Match it exactly; adjust the divisor and the expected `2.0` in the test if it uses sample stdev (`sqrt(8/2)`=2 either way for this triple — pick a test triple that distinguishes them, e.g. `[2,4]`: pstdev=1, stdev=1.414).

- [ ] **Step 4: Run to verify it passes**

Run: `go test ./internal/bench/ -run TestMeanStdev -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add pkgs/benchmark-go/internal/bench/stats.go pkgs/benchmark-go/internal/bench/stats_test.go
git commit -m "feat(bench): port mean/stdev stats"
```

### Task 1.2: SSE data-line parsing + token counting

**Files:**
- Create: `pkgs/benchmark-go/internal/bench/sse.go`
- Test: `pkgs/benchmark-go/internal/bench/sse_test.go`

> Read `benchmark.py` `http_post_stream` (lines 58-79) and `run_completion` (599-651) for the exact field names (`choices[].text`, `usage.completion_tokens`, the `[DONE]` sentinel).

- [ ] **Step 1: Write the failing test**

```go
package bench

import (
	"strings"
	"testing"
)

func TestParseSSEStream(t *testing.T) {
	raw := strings.Join([]string{
		`data: {"choices":[{"text":"Hello"}]}`,
		`data: {"choices":[{"text":" world"}]}`,
		`data: {"choices":[{"text":""}],"usage":{"completion_tokens":2}}`,
		`data: [DONE]`,
		``,
	}, "\n")
	res, err := ParseSSE(strings.NewReader(raw))
	if err != nil {
		t.Fatal(err)
	}
	if res.Text != "Hello world" {
		t.Fatalf("text=%q", res.Text)
	}
	if res.CompletionTokens != 2 {
		t.Fatalf("tokens=%d want 2", res.CompletionTokens)
	}
}

func TestParseSSEEmptyCompletion(t *testing.T) {
	// The MTP-path failure mode: a single EOS token, empty text.
	raw := "data: {\"choices\":[{\"text\":\"\"}],\"usage\":{\"completion_tokens\":1}}\ndata: [DONE]\n"
	res, _ := ParseSSE(strings.NewReader(raw))
	if res.CompletionTokens != 1 || res.Text != "" {
		t.Fatalf("got %d,%q", res.CompletionTokens, res.Text)
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/bench/ -run TestParseSSE -v`
Expected: FAIL — `undefined: ParseSSE`.

- [ ] **Step 3: Implement**

`sse.go`:
```go
package bench

import (
	"bufio"
	"encoding/json"
	"io"
	"strings"
)

// SSEResult is the accumulated text and reported token count from a stream.
type SSEResult struct {
	Text             string
	CompletionTokens int
}

type sseChunk struct {
	Choices []struct {
		Text string `json:"text"`
	} `json:"choices"`
	Usage *struct {
		CompletionTokens int `json:"completion_tokens"`
	} `json:"usage"`
}

// ParseSSE reads an OpenAI-style completion SSE stream, concatenating
// choices[0].text and capturing the final usage.completion_tokens.
func ParseSSE(r io.Reader) (SSEResult, error) {
	var out SSEResult
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := strings.TrimRight(sc.Text(), "\r")
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		payload := line[len("data: "):]
		if payload == "[DONE]" {
			break
		}
		var c sseChunk
		if err := json.Unmarshal([]byte(payload), &c); err != nil {
			continue // tolerate keep-alive/non-JSON lines, like the Python loop
		}
		if len(c.Choices) > 0 {
			out.Text += c.Choices[0].Text
		}
		if c.Usage != nil {
			out.CompletionTokens = c.Usage.CompletionTokens
		}
	}
	return out, sc.Err()
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `go test ./internal/bench/ -run TestParseSSE -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add pkgs/benchmark-go/internal/bench/sse.go pkgs/benchmark-go/internal/bench/sse_test.go
git commit -m "feat(bench): port SSE completion stream parsing"
```

### Task 1.3: Prompt builders

**Files:**
- Create: `pkgs/benchmark-go/internal/bench/prompt.go`
- Test: `pkgs/benchmark-go/internal/bench/prompt_test.go`

> Port `build_prompt` (444-482) and `build_mtp_prompt` (483-498). Match the "The " repetition approximation exactly.

- [ ] **Step 1: Write the failing test**

```go
package bench

import (
	"strings"
	"testing"
)

func TestBuildPromptApproxLength(t *testing.T) {
	p := BuildPrompt(256)
	// Same heuristic as Python: repeated "The " to ~target token count.
	if !strings.HasPrefix(p, "The ") {
		t.Fatalf("prefix=%q", p[:10])
	}
	words := strings.Fields(p)
	if len(words) < 200 || len(words) > 320 {
		t.Fatalf("word count %d outside expected band", len(words))
	}
}

func TestBuildMTPPromptRepetitive(t *testing.T) {
	p := BuildMTPPrompt(256)
	if len(p) == 0 {
		t.Fatal("empty mtp prompt")
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/bench/ -run Prompt -v`
Expected: FAIL — undefined.

- [ ] **Step 3: Implement** (transcribe the exact construction from `benchmark.py:444-498`)

`prompt.go`:
```go
package bench

import "strings"

// BuildPrompt approximates promptTokens tokens by repeating "The ".
// Mirrors benchmark.py build_prompt: ~1 token per "The ".
func BuildPrompt(promptTokens int) string {
	if promptTokens <= 0 {
		return ""
	}
	return strings.Repeat("The ", promptTokens)
}

// BuildMTPPrompt builds the repetitive prompt used for the MTP A/B path,
// where high draft-acceptance is expected. Mirrors build_mtp_prompt.
func BuildMTPPrompt(promptTokens int) string {
	// TRANSCRIBE the exact body from benchmark.py:483-498. If it differs
	// from BuildPrompt (e.g. a repeated sentence), reproduce it verbatim.
	return BuildPrompt(promptTokens)
}
```

> NOTE: open `benchmark.py:483-498` and replace the body if `build_mtp_prompt` is not identical to `build_prompt`. The test only asserts non-empty, so update it to assert the real shape once transcribed.

- [ ] **Step 4: Run to verify it passes**

Run: `go test ./internal/bench/ -run Prompt -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add pkgs/benchmark-go/internal/bench/prompt.go pkgs/benchmark-go/internal/bench/prompt_test.go
git commit -m "feat(bench): port prompt builders"
```

### Task 1.4: Completion payload builder (the ignore_eos fix)

**Files:**
- Create: `pkgs/benchmark-go/internal/bench/payload.go`
- Test: `pkgs/benchmark-go/internal/bench/payload_test.go`

> Port `build_completion_payload` (499-519). The CRITICAL detail (from the mtp-ab-benchmark memory): the MTP path MUST set `ignore_eos: true`, else the model emits a single EOS token and the decode sample is a 1-token empty completion.

- [ ] **Step 1: Write the failing test**

```go
package bench

import "testing"

func TestPayloadIgnoreEOS(t *testing.T) {
	p := BuildCompletionPayload(CompletionOpts{
		Model: "M", Prompt: "x", GenTokens: 128, IgnoreEOS: true, Stream: true,
	})
	if p["ignore_eos"] != true {
		t.Fatalf("ignore_eos not set: %v", p["ignore_eos"])
	}
	if p["max_tokens"] != 128 {
		t.Fatalf("max_tokens=%v", p["max_tokens"])
	}
	if p["stream"] != true {
		t.Fatalf("stream=%v", p["stream"])
	}
}

func TestPayloadDefaultNoIgnoreEOS(t *testing.T) {
	p := BuildCompletionPayload(CompletionOpts{Model: "M", Prompt: "x", GenTokens: 128})
	if _, ok := p["ignore_eos"]; ok {
		t.Fatal("ignore_eos should be absent when false")
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/bench/ -run Payload -v`
Expected: FAIL — undefined.

- [ ] **Step 3: Implement**

`payload.go`:
```go
package bench

// CompletionOpts configures a /v1/completions request.
type CompletionOpts struct {
	Model     string
	Prompt    string
	GenTokens int
	Stream    bool
	IgnoreEOS bool // MTP A/B path sets this; see mtp-ab-benchmark memory
}

// BuildCompletionPayload mirrors benchmark.py build_completion_payload.
func BuildCompletionPayload(o CompletionOpts) map[string]any {
	p := map[string]any{
		"model":      o.Model,
		"prompt":     o.Prompt,
		"max_tokens": o.GenTokens,
		"stream":     o.Stream,
		"temperature": 0,
	}
	if o.IgnoreEOS {
		p["ignore_eos"] = true
	}
	return p
}
```

> NOTE: confirm the exact key set (`temperature`, `n_predict` vs `max_tokens`, `cache_prompt`) against `benchmark.py:499-519` and match it.

- [ ] **Step 4: Run to verify it passes**

Run: `go test ./internal/bench/ -run Payload -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add pkgs/benchmark-go/internal/bench/payload.go pkgs/benchmark-go/internal/bench/payload_test.go
git commit -m "feat(bench): port completion payload builder with ignore_eos"
```

### Task 1.5: Device parsing + pick

**Files:**
- Create: `pkgs/benchmark-go/internal/bench/devices.go`
- Test: `pkgs/benchmark-go/internal/bench/devices_test.go`

> Port `parse_llama_devices` (135-161) and `pick_device` (162-183). Copy the exact fixture strings from `test_benchmark.py` into the Go test.

- [ ] **Step 1: Write the failing test** (use the real device-list string from `test_benchmark.py`)

```go
package bench

import "testing"

func TestParseLlamaDevices(t *testing.T) {
	// Replace with the verbatim sample from test_benchmark.py.
	out := `Available devices:
  ROCm0: Radeon 890M (gfx1150)
  Vulkan0: AMD Radeon Graphics`
	devs := ParseLlamaDevices(out)
	if len(devs) != 2 {
		t.Fatalf("got %d devices", len(devs))
	}
}

func TestPickDeviceROCm(t *testing.T) {
	devs := []Device{{ID: "ROCm0", Backend: "rocm"}, {ID: "Vulkan0", Backend: "vulkan"}}
	d, ok := PickDevice(devs, "rocm")
	if !ok || d.ID != "ROCm0" {
		t.Fatalf("got %v,%v", d, ok)
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/bench/ -run Device -v`
Expected: FAIL — undefined.

- [ ] **Step 3: Implement** — transcribe the regexes/logic from `benchmark.py:135-183` into `devices.go` (`Device` struct with `ID`, `Backend`, `Name`; `ParseLlamaDevices(string) []Device`; `PickDevice([]Device, backend string) (Device, bool)`).

- [ ] **Step 4: Run to verify it passes**

Run: `go test ./internal/bench/ -run Device -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add pkgs/benchmark-go/internal/bench/devices.go pkgs/benchmark-go/internal/bench/devices_test.go
git commit -m "feat(bench): port llama device parse + pick"
```

### Task 1.6: GGUF resolution

**Files:**
- Create: `pkgs/benchmark-go/internal/bench/gguf.go`
- Test: `pkgs/benchmark-go/internal/bench/gguf_test.go`

> Port `resolve_lemonade_gguf` (94-134). Test against a temp dir mimicking the HF hub layout (`models--owner--repo/snapshots/<rev>/file.gguf`).

- [ ] **Step 1: Write the failing test**

```go
package bench

import (
	"os"
	"path/filepath"
	"testing"
)

func TestResolveGGUF(t *testing.T) {
	root := t.TempDir()
	snap := filepath.Join(root, "models--unsloth--Qwen3.6-27B-GGUF", "snapshots", "abc123")
	if err := os.MkdirAll(snap, 0o755); err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(snap, "model.gguf")
	os.WriteFile(want, []byte("x"), 0o644)

	got := ResolveLemonadeGGUF("Qwen3.6-27B-GGUF", root)
	if got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}

func TestResolveGGUFMissing(t *testing.T) {
	if ResolveLemonadeGGUF("Nope", t.TempDir()) != "" {
		t.Fatal("expected empty for missing model")
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/bench/ -run GGUF -v`
Expected: FAIL — undefined.

- [ ] **Step 3: Implement** `ResolveLemonadeGGUF(modelID, cacheRoot string) string` mirroring the Python scan: match `models--*--<modelID>`, recurse for the lexicographically-first `*.gguf`, return "" on miss. Use `filepath.WalkDir` + `sort`.

- [ ] **Step 4: Run to verify it passes**

Run: `go test ./internal/bench/ -run GGUF -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add pkgs/benchmark-go/internal/bench/gguf.go pkgs/benchmark-go/internal/bench/gguf_test.go
git commit -m "feat(bench): port GGUF path resolution"
```

### Task 1.7: lemonade config read/rewrite/restore

**Files:**
- Create: `pkgs/benchmark-go/internal/bench/config.go`
- Test: `pkgs/benchmark-go/internal/bench/config_test.go`

> Port `set_llamacpp_backend` (303-324) and `restore_llamacpp_backend` (325-339). Operate on a temp JSON file; preserve unrelated keys.

- [ ] **Step 1: Write the failing test**

```go
package bench

import (
	"os"
	"path/filepath"
	"testing"
)

func TestSetAndRestoreBackend(t *testing.T) {
	cfg := filepath.Join(t.TempDir(), "config.json")
	os.WriteFile(cfg, []byte(`{"llamacpp":{"backend":"vulkan"},"other":1}`), 0o644)

	prev, err := SetLlamacppBackend(cfg, "rocm")
	if err != nil {
		t.Fatal(err)
	}
	if prev != "vulkan" {
		t.Fatalf("prev=%q", prev)
	}
	b, _ := os.ReadFile(cfg)
	if !contains(b, `"backend":"rocm"`) || !contains(b, `"other":1`) {
		t.Fatalf("rewrite lost keys: %s", b)
	}
	if err := RestoreLlamacppBackend(cfg, prev); err != nil {
		t.Fatal(err)
	}
	b, _ = os.ReadFile(cfg)
	if !contains(b, `"backend":"vulkan"`) {
		t.Fatalf("restore failed: %s", b)
	}
}

func contains(b []byte, s string) bool { return len(b) > 0 && (string(b) != "" && indexOf(string(b), s) >= 0) }
func indexOf(h, n string) int          { for i := 0; i+len(n) <= len(h); i++ { if h[i:i+len(n)] == n { return i } }; return -1 }
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/bench/ -run Backend -v`
Expected: FAIL — undefined.

- [ ] **Step 3: Implement** `SetLlamacppBackend(path, backend string) (prev string, err error)` and `RestoreLlamacppBackend(path, prev string) error` — decode into `map[string]any`, mutate `llamacpp.backend`, re-marshal preserving other keys (`json.Marshal` of the map). Match Python’s behavior for a missing `llamacpp` block (create it).

- [ ] **Step 4: Run to verify it passes**

Run: `go test ./internal/bench/ -run Backend -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add pkgs/benchmark-go/internal/bench/config.go pkgs/benchmark-go/internal/bench/config_test.go
git commit -m "feat(bench): port lemonade backend config rewrite/restore"
```

### Task 1.8: llama-server args builder

**Files:**
- Create: `pkgs/benchmark-go/internal/bench/args.go`
- Test: `pkgs/benchmark-go/internal/bench/args_test.go`

> Port `build_llama_server_args` (184-225). MUST include `--flash-attn on` and ctx 2048 for the MTP path (mtp-ab-benchmark memory). Spec params in `docs/.../2026-05-29-fancy-benchmark-tui-design.md` "Researched param baselines" table.

- [ ] **Step 1: Write the failing test**

```go
package bench

import (
	"slices"
	"testing"
)

func TestBuildServerArgsMTP(t *testing.T) {
	args := BuildLlamaServerArgs(ServerArgs{
		ModelPath: "/m.gguf", Port: 9000, Ctx: 2048,
		FlashAttn: true, SpecType: "draft-mtp", NGL: 999, Batch: 256, UBatch: 256, Parallel: 1,
	})
	must := [][]string{{"--flash-attn", "on"}, {"-c", "2048"}, {"-ngl", "999"}, {"--parallel", "1"}}
	for _, pair := range must {
		i := slices.Index(args, pair[0])
		if i < 0 || i+1 >= len(args) || args[i+1] != pair[1] {
			t.Fatalf("missing %v in %v", pair, args)
		}
	}
}

func TestBuildServerArgsSpecNone(t *testing.T) {
	args := BuildLlamaServerArgs(ServerArgs{ModelPath: "/m.gguf", Port: 9000, Ctx: 2048, SpecType: "none"})
	if slices.Contains(args, "--draft-max") {
		t.Fatal("spec=none should not set draft flags")
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/bench/ -run ServerArgs -v`
Expected: FAIL — undefined.

- [ ] **Step 3: Implement** `ServerArgs` struct + `BuildLlamaServerArgs(ServerArgs) []string`, transcribing the Python flag assembly including the `--spec-type` / `draft-mtp` branch and `--flash-attn on`.

- [ ] **Step 4: Run to verify it passes**

Run: `go test ./internal/bench/ -run ServerArgs -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add pkgs/benchmark-go/internal/bench/args.go pkgs/benchmark-go/internal/bench/args_test.go
git commit -m "feat(bench): port llama-server args builder"
```

### Task 1.9: LlamaServer process lifecycle

**Files:**
- Create: `pkgs/benchmark-go/internal/bench/server.go`
- Test: `pkgs/benchmark-go/internal/bench/server_test.go`

> Port the `LlamaServer` class (226-302): spawn `exec.Cmd`, poll `/health` until ready (timeout), graceful SIGTERM then SIGKILL on teardown. Test with a fake server script (a tiny HTTP listener) rather than real llama-server.

- [ ] **Step 1: Write the failing test** (uses an in-process httptest server's port as a "already ready" probe target, and a `sleep` binary as the fake process)

```go
package bench

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestWaitReadyPollsHealth(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
	}))
	defer srv.Close()
	if err := waitReady(srv.URL, 2*time.Second); err != nil {
		t.Fatalf("waitReady: %v", err)
	}
}

func TestWaitReadyTimeout(t *testing.T) {
	if err := waitReady("http://127.0.0.1:1", 300*time.Millisecond); err == nil {
		t.Fatal("expected timeout error")
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/bench/ -run WaitReady -v`
Expected: FAIL — undefined `waitReady`.

- [ ] **Step 3: Implement** `waitReady(baseURL string, timeout time.Duration) error` (poll `GET {base}/health` every 250ms until 200 or timeout) and a `LlamaServer` type with `Start()` (spawn `exec.Command`, capture stderr, call `waitReady`) and `Stop()` (SIGTERM, wait `termTimeout`, SIGKILL). Use `FindFreePort()` (port-0 bind helper, port `find_free_port` at 82-92).

- [ ] **Step 4: Run to verify it passes**

Run: `go test ./internal/bench/ -run WaitReady -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add pkgs/benchmark-go/internal/bench/server.go pkgs/benchmark-go/internal/bench/server_test.go
git commit -m "feat(bench): port LlamaServer lifecycle + health poll"
```

### Task 1.10: Measurement orchestration (run.go)

**Files:**
- Create: `pkgs/benchmark-go/internal/bench/run.go`
- Test: `pkgs/benchmark-go/internal/bench/run_test.go`

> Port `run_completion` (599), `benchmark_model` (599-651), `_measure_one_spec` (723-758), and `run_mtp_ab` (759-866). Drive against an `httptest` server that streams canned SSE so timing/stats logic is tested without real inference.

- [ ] **Step 1: Write the failing test**

```go
package bench

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestMeasureOneSpecAgainstFakeServer(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fl := w.(http.Flusher)
		for i := 0; i < 4; i++ {
			fmt.Fprintf(w, "data: {\"choices\":[{\"text\":\"x\"}]}\n")
			fl.Flush()
		}
		fmt.Fprint(w, "data: {\"choices\":[{\"text\":\"\"}],\"usage\":{\"completion_tokens\":4}}\n")
		fmt.Fprint(w, "data: [DONE]\n")
	}))
	defer srv.Close()

	res := MeasureSpec(srv.URL, MeasureOpts{Model: "M", PromptTokens: 8, GenTokens: 4, Warmup: 0, Repeat: 2})
	if len(res.DecodeTPS) != 2 {
		t.Fatalf("got %d samples", len(res.DecodeTPS))
	}
	for _, v := range res.DecodeTPS {
		if v <= 0 {
			t.Fatalf("non-positive t/s: %v", v)
		}
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/bench/ -run MeasureOneSpec -v`
Expected: FAIL — undefined.

- [ ] **Step 3: Implement** `MeasureOpts`, `MeasureResult{TTFT, DecodeTPS []float64}`, `MeasureSpec(baseURL string, o MeasureOpts) MeasureResult` (warmup loop + repeat loop, each POSTing `BuildCompletionPayload`, timing first-token and total, computing `completion_tokens / decode_seconds`). Then `RunMTPAB(...)` that, per backend, starts a `LlamaServer` for `spec=none` and `spec=draft-mtp` (with `IgnoreEOS:true`) and returns paired results. Keep `BenchmarkModel(...)` for the HTTP-via-lemonade mode.

- [ ] **Step 4: Run to verify it passes**

Run: `go test ./internal/bench/ -run MeasureOneSpec -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add pkgs/benchmark-go/internal/bench/run.go pkgs/benchmark-go/internal/bench/run_test.go
git commit -m "feat(bench): port measurement orchestration (spec/mtp-ab/http)"
```

### Task 1.11: models package (lemonade enumeration)

**Files:**
- Create: `pkgs/benchmark-go/internal/models/models.go`
- Test: `pkgs/benchmark-go/internal/models/models_test.go`

> Port `check_models` (377-425) and `load_model` (426-443). Test JSON decode of `/api/v1/models` against the captured shape (see this session's curl output: `data[].id`, `.recipe`/`labels`, `.downloaded`).

- [ ] **Step 1: Write the failing test**

```go
package models

import "testing"

func TestParseModelsList(t *testing.T) {
	js := `{"data":[{"id":"Gemma-4-26B-A4B-it-GGUF","downloaded":true,"labels":["llamacpp"]},
	                {"id":"Qwen3.6-27B-GGUF","downloaded":false,"labels":["llamacpp"]}]}`
	ms, err := ParseModels([]byte(js))
	if err != nil {
		t.Fatal(err)
	}
	if len(ms) != 2 || ms[0].ID != "Gemma-4-26B-A4B-it-GGUF" || !ms[0].Downloaded {
		t.Fatalf("parsed wrong: %+v", ms)
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/models/ -v`
Expected: FAIL — undefined.

- [ ] **Step 3: Implement** `Model{ID string; Downloaded bool; Labels []string}`, `ParseModels([]byte) ([]Model, error)`, and `Fetch(baseURL string) ([]Model, error)` (HTTP GET `/api/v1/models`).

- [ ] **Step 4: Run to verify it passes**

Run: `go test ./internal/models/ -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add pkgs/benchmark-go/internal/models/
git commit -m "feat(models): port lemonade model enumeration"
```

### Task 1.12: markdown table + headless CLI wiring

**Files:**
- Create: `pkgs/benchmark-go/internal/cli/markdown.go`, `markdown_test.go`
- Modify: `pkgs/benchmark-go/internal/cli/cli.go`

> Port `print_markdown_table` (652-670) and `format_mtp_row` (671-698). Wire `Run` to parse flags and dispatch headless when `--no-tui` or non-TTY.

- [ ] **Step 1: Write the failing test**

```go
package cli

import (
	"strings"
	"testing"
)

func TestMarkdownTable(t *testing.T) {
	out := RenderMarkdownTable([]Row{
		{Model: "Qwen3.6-27B", Backend: "rocm", TTFT: 1.69, DecodeTPS: 3.6, Stdev: 0.1},
	})
	if !strings.Contains(out, "| Model") || !strings.Contains(out, "Qwen3.6-27B") {
		t.Fatalf("bad table:\n%s", out)
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/cli/ -run Markdown -v`
Expected: FAIL — undefined.

- [ ] **Step 3: Implement** `Row` struct + `RenderMarkdownTable([]Row) string` (and an MTP variant matching `format_mtp_row`'s off→on×speedup columns). Then expand `cli.Run`:

```go
package cli

import (
	"flag"
	"os"

	"golang.org/x/term"
)

type Options struct {
	NoTUI       bool
	MTPAB       bool
	Backend     string
	Models      []string
	Repeat      int
	Warmup      int
	Ctx         int
	MinDecodeTPS float64
	BaseURL     string
}

func Run(argv []string) int {
	o := parseFlags(argv[1:])
	interactive := !o.NoTUI && term.IsTerminal(int(os.Stdin.Fd()))
	if interactive {
		return runTUI(o) // implemented in Phase 5; stub returns 0 for now
	}
	return runHeadless(o)
}
```

> The `runTUI` stub returns 0 until Phase 5. `runHeadless` calls into `bench` + `cli.RenderMarkdownTable`, prints, and returns 1 if any decode t/s < `MinDecodeTPS` (the CPU-fallback gate, default 5.0).

- [ ] **Step 4: Add the `golang.org/x/term` dep and update vendorHash**

Run: `go get golang.org/x/term && go mod tidy`
Then set `vendorHash` in `pkgs/benchmark-go/default.nix`: run `nix build .#benchmark-go` once, copy the "got:" hash from the error into `vendorHash`.

- [ ] **Step 5: Run tests + build**

Run: `go test ./... && nix build .#benchmark-go`
Expected: all PASS; Nix build succeeds.

- [ ] **Step 6: Commit**

```bash
git add pkgs/benchmark-go/
git commit -m "feat(cli): markdown output + headless routing"
```

### Task 1.13: Headless parity gate

**Files:** none (verification task)

- [ ] **Step 1: Run both tools on the same model headless**

Run (GPU idle, see preflight in Phase 4):
```bash
nix run .#benchmark -- --backend vulkan Phi-4-mini-instruct-GGUF > /tmp/py.txt
nix run .#benchmark-go -- --no-tui --backend vulkan --model Phi-4-mini-instruct-GGUF > /tmp/go.txt
```
Expected: same backend/model rows; decode t/s within run-to-run noise (~±10%). Record both in `bench-logs-*/parity.txt`.

- [ ] **Step 2: Commit the parity evidence**

```bash
git add bench-logs-*/parity.txt 2>/dev/null || true
git commit -m "test(benchmark-go): headless parity vs benchmark.py" --allow-empty
```

---

## Phase 2 — Hardware detection (`hw`)

### Task 2.1: Parse amdgpu_top JSON + sysfs (fixtures)

**Files:**
- Create: `pkgs/benchmark-go/internal/hw/hw.go`, `hw_test.go`
- Create fixtures: `pkgs/benchmark-go/internal/hw/testdata/amdgpu_top.json`, `testdata/mem_info_vram_total`, `testdata/mem_info_gtt_total`, `testdata/meminfo`

- [ ] **Step 1: Capture fixtures from this box**

Run:
```bash
mkdir -p pkgs/benchmark-go/internal/hw/testdata
amdgpu_top --json > pkgs/benchmark-go/internal/hw/testdata/amdgpu_top.json
cp /sys/class/drm/card1/device/mem_info_vram_total pkgs/benchmark-go/internal/hw/testdata/
cp /sys/class/drm/card1/device/mem_info_gtt_total  pkgs/benchmark-go/internal/hw/testdata/
cp /proc/meminfo pkgs/benchmark-go/internal/hw/testdata/meminfo
```

- [ ] **Step 2: Write the failing test**

```go
package hw

import (
	"os"
	"testing"
)

func TestParseMemTotalKB(t *testing.T) {
	b, _ := os.ReadFile("testdata/meminfo")
	gib := parseMemTotalGiB(b)
	if gib < 50 || gib > 70 { // ~57 GiB on the target
		t.Fatalf("ram=%v GiB", gib)
	}
}

func TestParseGRBMBusy(t *testing.T) {
	b, _ := os.ReadFile("testdata/amdgpu_top.json")
	busy, arch := parseAmdgpuTop(b)
	_ = busy
	if arch == "" {
		t.Fatal("arch not parsed")
	}
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `go test ./internal/hw/ -v`
Expected: FAIL — undefined parsers.

- [ ] **Step 4: Implement** `parseMemTotalGiB([]byte) float64`, `parseAmdgpuTop([]byte) (grbmBusyPct float64, arch string)` (decode the `devices[0].GRBM."Graphics Pipe".value` and the device name/arch), `parseBytesFile([]byte) uint64`, and `Detect() Info` where:
```go
type Info struct {
	GfxArch     string
	RAMGiB      float64
	RAMType     string // "" if unknown (needs root)
	RAMSpeedMTs int    // 0 if unknown
	VRAMBytes   uint64 // UMA carveout
	GTTBytes    uint64 // real ceiling on Strix Point
	GRBMBusyPct float64
	Governor    string
	Performance bool   // platform_profile==performance && EPP==performance
	OnAC        bool
}
```
`Detect` reads sysfs + runs `amdgpu_top --json`; RAM type/speed via `dmidecode -t memory` best-effort (empty on failure, never error).

- [ ] **Step 5: Run to verify it passes**

Run: `go test ./internal/hw/ -v`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add pkgs/benchmark-go/internal/hw/
git commit -m "feat(hw): hardware detection with fixture-driven parsers"
```

---

## Phase 3 — Advice (`advise`)

### Task 3.1: Bandwidth ceiling + fit ranking + recommended params

**Files:**
- Create: `pkgs/benchmark-go/internal/advise/advise.go`, `advise_test.go`

> Math from the design doc "`advise` math" section and the `perf-baselines-gfx1150` memory.

- [ ] **Step 1: Write the failing test**

```go
package advise

import (
	"math"
	"testing"
)

func TestDecodeCeiling(t *testing.T) {
	// DDR5-5600 dual-channel ~89.6 GB/s; a 15.7 GB active model -> ~5.7 t/s.
	got := DecodeCeilingTPS(89.6, 15.7)
	if math.Abs(got-5.7) > 0.3 {
		t.Fatalf("ceiling=%v", got)
	}
}

func TestFitClassify(t *testing.T) {
	// budget=27 GiB (GTT). 15.7 fits, 25 tight, 30 spills.
	if FitClass(15.7, 27) != Fits {
		t.Fatal("15.7 should fit")
	}
	if FitClass(25, 27) != Tight {
		t.Fatal("25 should be tight")
	}
	if FitClass(30, 27) != Spills {
		t.Fatal("30 should spill")
	}
}

func TestRecommendParamsLargeModel(t *testing.T) {
	p := RecommendParams(15.7)
	if p.Batch != 256 || p.Parallel != 1 || !p.FlashAttn || p.RocWMMA {
		t.Fatalf("bad params: %+v", p)
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/advise/ -v`
Expected: FAIL — undefined.

- [ ] **Step 3: Implement**

```go
package advise

type FitState int

const (
	Fits FitState = iota
	Tight
	Spills
)

// DecodeCeilingTPS is the bandwidth-bound decode ceiling:
// bandwidth(GB/s) / activeBytesPerToken(GB). For a dense model the active
// bytes per token ~= model size in GB (every weight read once per token).
func DecodeCeilingTPS(bandwidthGBs, activeGB float64) float64 {
	if activeGB <= 0 {
		return 0
	}
	return bandwidthGBs / activeGB
}

// FitClass classifies a model against the usable GPU memory budget (GiB).
// On Strix Point the budget is GTT (~27 GiB), not the 8 GiB UMA carveout.
func FitClass(modelGiB, budgetGiB float64) FitState {
	switch {
	case modelGiB > budgetGiB:
		return Spills
	case modelGiB > budgetGiB*0.9:
		return Tight
	default:
		return Fits
	}
}

type Params struct {
	NGL       int
	Batch     int
	UBatch    int
	Ctx       int
	Parallel  int
	FlashAttn bool
	RocWMMA   bool // ALWAYS false on gfx1150: local regression, see rocwmma-build-flag memory
}

// RecommendParams returns gfx1150 defaults; large models start at batch 256
// to avoid the known GPU hang. Never enables rocWMMA.
func RecommendParams(modelGiB float64) Params {
	batch := 512
	if modelGiB >= 8 {
		batch = 256
	}
	return Params{NGL: 999, Batch: batch, UBatch: 256, Ctx: 2048, Parallel: 1, FlashAttn: true, RocWMMA: false}
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `go test ./internal/advise/ -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add pkgs/benchmark-go/internal/advise/
git commit -m "feat(advise): bandwidth ceiling, fit ranking, gfx1150 params"
```

---

## Phase 4 — Preflight (`preflight`)

### Task 4.1: Checks + classification + fixers

**Files:**
- Create: `pkgs/benchmark-go/internal/preflight/preflight.go`, `preflight_test.go`

> Checks: (a) lemond serving — `systemctl is-active lemond.service`; (b) competing GPU listener — `ss -ltnp` shows a non-lemond port (e.g. :8001); (c) GPU busy — `hw.Info.GRBMBusyPct > 5`; (d) power — `hw.Info.Performance && hw.Info.OnAC`. Each → `Result{Name, Status, Reason, Fixer}`.

- [ ] **Step 1: Write the failing test** (pure classification over injected inputs — no real commands)

```go
package preflight

import "testing"

func TestClassifyGPUBusy(t *testing.T) {
	r := classifyGPU(42.0)
	if r.Status != Fail {
		t.Fatalf("42%% busy should fail, got %v", r.Status)
	}
	if classifyGPU(0).Status != Pass {
		t.Fatal("idle should pass")
	}
}

func TestClassifyPower(t *testing.T) {
	if classifyPower(true, true).Status != Pass {
		t.Fatal("AC+performance should pass")
	}
	if classifyPower(false, true).Status != Warn {
		t.Fatal("battery should warn")
	}
}

func TestClassifyLemond(t *testing.T) {
	if classifyLemond("active").Status != Warn {
		t.Fatal("active lemond should warn (fixable)")
	}
	if classifyLemond("inactive").Status != Pass {
		t.Fatal("inactive lemond should pass")
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/preflight/ -v`
Expected: FAIL — undefined.

- [ ] **Step 3: Implement** `Status` enum (`Pass/Warn/Fail`), `Result{Name string; Status Status; Reason string; Fix func() error}`, the pure `classify*` helpers, and a `Run(hwInfo hw.Info) []Result` that gathers live inputs (`systemctl is-active`, `ss -ltnp`) and calls the classifiers. Fixers: `stopLemond()` = `systemctl stop lemond.service` (sudo), `setPerformance()` = write governor/EPP (sudo). Fixers are only attached to fixable results.

- [ ] **Step 4: Run to verify it passes**

Run: `go test ./internal/preflight/ -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add pkgs/benchmark-go/internal/preflight/
git commit -m "feat(preflight): GPU/power/lemond interference checks + fixers"
```

### Task 4.2: Wire preflight into headless (warnings only)

**Files:**
- Modify: `pkgs/benchmark-go/internal/cli/cli.go` (`runHeadless`)

- [ ] **Step 1: Add the call** — before measuring, `runHeadless` calls `preflight.Run(hw.Detect())` and prints any `Warn`/`Fail` lines to stderr prefixed `preflight:` but NEVER prompts or blocks.

- [ ] **Step 2: Manual check**

Run: `nix run .#benchmark-go -- --no-tui --backend vulkan --model Phi-4-mini-instruct-GGUF`
Expected: preflight warnings appear on stderr (lemond active, etc.), benchmark still runs.

- [ ] **Step 3: Commit**

```bash
git add pkgs/benchmark-go/internal/cli/cli.go
git commit -m "feat(cli): headless preflight warnings (non-blocking)"
```

---

## Phase 5 — TUI (`tui`)

> Add Charm deps: `go get github.com/charmbracelet/bubbletea github.com/charmbracelet/lipgloss github.com/charmbracelet/bubbles && go mod tidy`, then re-derive `vendorHash` (build `.#benchmark-go`, copy "got:" hash). Use `github.com/charmbracelet/x/exp/teatest` for tests.

### Task 5.1: Root model + screen routing

**Files:**
- Create: `pkgs/benchmark-go/internal/tui/app.go`, `app_test.go`

- [ ] **Step 1: Write the failing teatest** (golden path: app starts on the hardware panel, `enter` advances to preflight)

```go
package tui

import (
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/exp/teatest"
)

func TestAppStartsOnHardwarePanel(t *testing.T) {
	m := New(testInfo()) // testInfo: a fixed hw.Info
	tm := teatest.NewTestModel(t, m, teatest.WithInitialTermSize(120, 40))
	teatest.WaitFor(t, tm.Output(), func(b []byte) bool {
		return contains(b, "Hardware")
	}, teatest.WithDuration(2*time.Second))
	tm.Send(tea.KeyMsg{Type: tea.KeyEnter})
	teatest.WaitFor(t, tm.Output(), func(b []byte) bool {
		return contains(b, "Preflight")
	}, teatest.WithDuration(2*time.Second))
	tm.Send(tea.Quit())
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/tui/ -run AppStarts -v`
Expected: FAIL — undefined `New`.

- [ ] **Step 3: Implement** a root `model` with a `screen` enum (`screenHW, screenPreflight, screenMode, screenModel, screenParams, screenRun, screenResults`), `New(hw.Info) tea.Model`, and `Update` that advances `screen` on Enter / backs up on Esc. `View` delegates to the per-screen render funcs (stubs returning their title for now: "Hardware …", "Preflight …", etc.).

- [ ] **Step 4: Run to verify it passes**

Run: `go test ./internal/tui/ -run AppStarts -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add pkgs/benchmark-go/internal/tui/
git commit -m "feat(tui): root model + screen routing"
```

### Task 5.2: Hardware panel + preflight checklist screens

**Files:**
- Create: `pkgs/benchmark-go/internal/tui/hwpanel.go`, `pkgs/benchmark-go/internal/tui/preflight.go`

- [ ] **Step 1: Implement the hardware panel** — a lipgloss-bordered box rendering `hw.Info` (arch, RAM GiB + type/speed or "unknown", VRAM/GTT, power state). No new test (covered by 5.1's "Hardware" assertion; extend it to assert the RAM line).

- [ ] **Step 2: Implement the preflight screen** — render `[]preflight.Result` with ✓/⚠/✗ glyphs and per-item key hints (`[s] stop lemond`, `[p] set performance`). Pressing the key runs `Result.Fix` in a `tea.Cmd`, then re-runs `preflight.Run` and updates the list. Add a teatest asserting a ✗ row renders.

- [ ] **Step 3: Run tests**

Run: `go test ./internal/tui/ -v`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add pkgs/benchmark-go/internal/tui/hwpanel.go pkgs/benchmark-go/internal/tui/preflight.go pkgs/benchmark-go/internal/tui/app_test.go
git commit -m "feat(tui): hardware panel + preflight checklist screens"
```

### Task 5.3: Mode + model + params screens

**Files:**
- Create: `pkgs/benchmark-go/internal/tui/mode.go`, `modelpick.go`, `params.go`

- [ ] **Step 1: Mode picker** — `bubbles/list` with three items (HTTP bench / Backend A/B / MTP A/B); selection stored on the model.

- [ ] **Step 2: Model picker** — fetch `models.Fetch`, annotate each with `advise.FitClass` + `advise.DecodeCeilingTPS` (use `hw.Info` budget/bandwidth), render with fit glyph + predicted t/s; multi-select via `bubbles/list` with a checked state.

- [ ] **Step 3: Params form** — `bubbles/textinput` fields pre-filled from `advise.RecommendParams(selectedModelGiB)` (ctx, repeat, warmup, batch); editable.

- [ ] **Step 4: teatest** the model picker shows a fit glyph for a canned model list (inject a fake `models.Fetch` via a function field on the model).

- [ ] **Step 5: Run tests + commit**

Run: `go test ./internal/tui/ -v`
```bash
git add pkgs/benchmark-go/internal/tui/
git commit -m "feat(tui): mode, model, and params screens"
```

### Task 5.4: Live run + results screens

**Files:**
- Create: `pkgs/benchmark-go/internal/tui/run.go`, `pkgs/benchmark-go/internal/tui/results.go`

- [ ] **Step 1: Live run** — a `bubbles/progress` bar per model/iteration; a `tea.Cmd` runs `bench.MeasureSpec`/`bench.RunMTPAB` in a goroutine, streaming progress via custom messages; show running mean±stdev and the live `hw` GRBM% (poll every 1s via `tea.Tick`).

- [ ] **Step 2: Results** — a lipgloss table (measured t/s, predicted ceiling, %-of-ceiling). Key `[m]` switches to a plain `cli.RenderMarkdownTable` view for copy-paste; key `[w]` writes a log file to `bench-logs-<topic>-<date>/` (date passed in via the model, NOT generated — keep it injectable for testing).

- [ ] **Step 3: teatest** a canned result set renders the markdown view on `[m]`.

- [ ] **Step 4: Wire `runTUI`** in `cli.go` to build and run the program: `tea.NewProgram(tui.New(hw.Detect())).Run()`; map the final selected config to the real `bench` calls (replace the Phase-1 stub).

- [ ] **Step 5: Run tests + manual smoke**

Run: `go test ./... && nix run .#benchmark-go`
Expected: tests PASS; TUI launches, walks all screens.

- [ ] **Step 6: Commit**

```bash
git add pkgs/benchmark-go/internal/tui/ pkgs/benchmark-go/internal/cli/cli.go
git commit -m "feat(tui): live run + results screens, wire runTUI"
```

---

## Phase 6 — Cutover

### Task 6.1: Repoint flake to the Go build

**Files:**
- Modify: `flake.nix` (`packages.benchmark`, `apps.benchmark`)

- [ ] **Step 1: Repoint** — change `benchmark = pkgs.callPackage ./pkgs/benchmark {};` to `benchmark = pkgs.callPackage ./pkgs/benchmark-go {};`, remove the separate `benchmark-go` entry, and update `apps.benchmark.program` to `"${pkgs.callPackage ./pkgs/benchmark-go {}}/bin/benchmark"`.

- [ ] **Step 2: Verify**

Run: `nix run .#benchmark -- --no-tui --backend vulkan --model Phi-4-mini-instruct-GGUF`
Expected: the Go tool runs as `.#benchmark`.

- [ ] **Step 3: Commit**

```bash
git add flake.nix
git commit -m "build: repoint .#benchmark to the Go harness"
```

### Task 6.2: Delete the Python harness

**Files:**
- Delete: `pkgs/benchmark/` (entire dir)

- [ ] **Step 1: Remove** (use gtrash, not rm, per global instructions)

Run: `gtrash put pkgs/benchmark`

- [ ] **Step 2: Verify nothing references it**

Run: `grep -rn "pkgs/benchmark\b" flake.nix; grep -rn "benchmark.py" .`
Expected: no matches (the Go dir is `pkgs/benchmark-go`).

- [ ] **Step 3: Build the whole flake**

Run: `nix flake check && nix build .#benchmark`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore(benchmark): remove Python harness, superseded by Go"
```

### Task 6.3: Update README

**Files:**
- Modify: `README.md` (lines ~227-239: the benchmark section)

- [ ] **Step 1: Update** the `nix run .#benchmark` docs to describe the interactive TUI (default) and the `--no-tui` headless flags, and note the preflight guard + system-aware suggestions. Keep the existing `--backend`/`--mtp-ab`/`--min-decode-tps` examples (flags unchanged).

- [ ] **Step 2: Add the (still pending) MTP speedup subsection placeholder** pointing at the headless `--mtp-ab` command — numbers get filled by an actual authoritative run (separate task, requires idle GPU + AC; see `mtp-ab-benchmark` memory).

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs(readme): document interactive benchmark TUI + headless mode"
```

---

## Self-Review

**Spec coverage:**
- Preflight guard → Phase 4 (4.1 checks/fixers, 4.2 headless wiring, 5.2 TUI screen). ✓
- Hardware panel → 2.1 (`hw.Detect`) + 5.2 (render). ✓
- Model shortlist (fit) → 3.1 (`FitClass`) + 5.3 (annotated picker). ✓
- Bandwidth ceiling → 3.1 (`DecodeCeilingTPS`) + 5.3/5.4 (predicted vs measured). ✓
- Recommended params → 3.1 (`RecommendParams`) + 5.3 (pre-filled form). ✓
- Measurement port (SSE, stats, MTP A/B with `ignore_eos`, `--backend` switch+restore, GGUF, devices) → Phase 1.1-1.12. ✓
- Headless flag mode + CPU-fallback exit gate → 1.12 + 4.2. ✓
- Go + Charm portable binary → 0.1, 0.2, Phase 5. ✓
- Replace `benchmark.py` at parity → 1.13 (gate) + 6.1/6.2 (cutover). ✓
- rocWMMA-never-recommended → 3.1 (`RocWMMA` always false, tested). ✓
- Testing (pure units, fixtures, teatest, parity) → throughout + 1.13. ✓

**Placeholder scan:** Tasks 1.3 (`BuildMTPPrompt` body) and 1.1 (stdev divisor), 1.4 (payload key set), 1.5 (device regex) carry explicit "transcribe from benchmark.py:lines" notes — these are deliberate 1:1-port instructions with exact source line ranges, not vague placeholders. All other steps contain runnable code/commands.

**Type consistency:** `hw.Info` fields referenced by `preflight` (GRBMBusyPct, Performance, OnAC) and `advise`/`tui` (VRAMBytes, GTTBytes, RAMType) match the struct in 2.1. `bench.MeasureOpts/MeasureResult`, `cli.Row`, `advise.Params`, `preflight.Result` names are used consistently across the tasks that reference them.

**Scope:** One coherent subsystem (the benchmark tool). Phased so Phase 1 alone yields a working headless replacement (parity gate at 1.13) before any TUI work — landable incrementally.
