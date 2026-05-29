package bench

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"os"
	"os/exec"
	"sort"
	"strings"
	"time"
)

// MeasureOpts holds parameters for MeasureSpec / BenchmarkModel.
type MeasureOpts struct {
	PromptTokens int
	GenTokens    int
	Warmup       int
	Repeat       int
	IgnoreEOS    bool
}

// MeasureResult holds per-iteration samples from a measurement run.
// Empty slices mean "no successful iterations" — callers MUST guard with
// len check before calling MeanStdev (empty → render as N/A).
type MeasureResult struct {
	TTFT      []float64 // time-to-first-token per successful iteration (seconds)
	DecodeTPS []float64 // decode throughput per successful iteration (tokens/s)
}

// completionResult holds what one streaming completion returns.
// ok=false is the "no tokens" sentinel (mirrors Python's `return None, None, 0`).
type completionResult struct {
	ttft      float64
	decodeTPS float64
	tokens    int
	ok        bool
}

// runOneCompletion posts one streaming completion to baseURL+path and
// returns timing/TPS. Mirrors Python's run_completion exactly.
//
// Timing combination rules (Python mirror):
//   - completion_tokens = CompletionTokens if > 0, else TextTokenCount
//   - decode_tps = PredictedPerSecond if > 0, else wall-clock
//     (compTokens-1)/decodeElapsed; 0 if compTokens<=1; +Inf if elapsed<=0
//   - TTFT = wall-clock from request start to first non-empty text token
//
// Returns ok=false when no tokens received (TextTokenCount == 0).
func runOneCompletion(baseURL, path string, opts CompletionOpts) completionResult {
	payload := BuildCompletionPayload(opts)
	body, err := json.Marshal(payload)
	if err != nil {
		return completionResult{}
	}

	req, err := http.NewRequest(http.MethodPost, baseURL+path, bytes.NewReader(body))
	if err != nil {
		return completionResult{}
	}
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: 300 * time.Second}

	tStart := time.Now()
	resp, err := client.Do(req)
	if err != nil {
		return completionResult{}
	}
	defer resp.Body.Close()

	// Parse SSE stream while recording per-token wall-clock times.
	// This reimplements the key parts of ParseSSE with timing hooks,
	// matching Python's run_completion loop exactly.
	var (
		tFirstToken time.Time
		tLastToken  time.Time
		textCount   int // client-side non-empty text token count

		finalCompTokens   int
		finalPredictedTPS float64
	)

	type sseTimingChunk struct {
		Choices []struct {
			Text string `json:"text"`
		} `json:"choices"`
		Usage *struct {
			CompletionTokens int `json:"completion_tokens"`
		} `json:"usage"`
		Timings *struct {
			PredictedPerSecond float64 `json:"predicted_per_second"`
		} `json:"timings"`
	}

	sc := bufio.NewScanner(resp.Body)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := strings.TrimRight(sc.Text(), "\r")
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		payload := line[len("data: "):]
		if strings.TrimSpace(payload) == "[DONE]" {
			break
		}
		var c sseTimingChunk
		if err := json.Unmarshal([]byte(payload), &c); err != nil {
			continue
		}
		// Overwrite on each truthy value — matches Python final_usage/final_timings.
		if c.Usage != nil && c.Usage.CompletionTokens != 0 {
			finalCompTokens = c.Usage.CompletionTokens
		}
		if c.Timings != nil && c.Timings.PredictedPerSecond != 0 {
			finalPredictedTPS = c.Timings.PredictedPerSecond
		}
		for _, ch := range c.Choices {
			if ch.Text != "" {
				now := time.Now()
				if tFirstToken.IsZero() {
					tFirstToken = now
				}
				textCount++
				tLastToken = now
			}
		}
	}

	// No tokens received → sentinel, matching Python's `if t_first_token is None`.
	if tFirstToken.IsZero() {
		return completionResult{}
	}

	ttft := tFirstToken.Sub(tStart).Seconds()

	// completion_tokens: server-reported if truthy, else client count.
	compTokens := finalCompTokens
	if compTokens == 0 {
		compTokens = textCount
	}

	// decode_tps: server-reported if truthy, else wall-clock.
	var decodeTPS float64
	if finalPredictedTPS > 0 {
		decodeTPS = finalPredictedTPS
	} else if compTokens <= 1 {
		decodeTPS = 0
	} else {
		decodeElapsed := tLastToken.Sub(tFirstToken).Seconds()
		if decodeElapsed <= 0 {
			decodeTPS = math.Inf(1)
		} else {
			decodeTPS = float64(compTokens-1) / decodeElapsed
		}
	}

	return completionResult{
		ttft:      ttft,
		decodeTPS: decodeTPS,
		tokens:    compTokens,
		ok:        true,
	}
}

// MeasureSpec runs warmup+repeat completions against baseURL+path and returns
// per-iteration TTFT and DecodeTPS samples.
//
// model: the model ID string for the payload ("default" for raw llama-server).
// path: "/v1/completions" for raw llama-server, "/api/v1/completions" for lemonade.
//
// Skips iterations that hit the "no tokens" sentinel, matching Python's
// `if ttft is None: continue`. Empty result slices mean all iterations failed.
func MeasureSpec(baseURL, path, model string, o MeasureOpts) MeasureResult {
	var prompt string
	if o.IgnoreEOS {
		// MTP A/B uses the naturalistic prompt.
		prompt = BuildMTPPrompt(o.PromptTokens)
	} else {
		prompt = BuildPrompt(o.PromptTokens)
	}

	opts := CompletionOpts{
		Model:     model,
		Prompt:    prompt,
		GenTokens: o.GenTokens,
		Stream:    true,
		IgnoreEOS: o.IgnoreEOS,
	}

	for range o.Warmup {
		runOneCompletion(baseURL, path, opts)
	}

	var result MeasureResult
	for i := range o.Repeat {
		cr := runOneCompletion(baseURL, path, opts)
		if !cr.ok {
			fmt.Fprintf(os.Stderr, "  WARNING: iteration %d produced no tokens\n", i+1)
			continue
		}
		result.TTFT = append(result.TTFT, cr.ttft)
		result.DecodeTPS = append(result.DecodeTPS, cr.decodeTPS)
	}
	return result
}

// BenchmarkModelOpts holds parameters for BenchmarkModel.
type BenchmarkModelOpts struct {
	BaseURL      string
	ModelID      string
	PromptTokens int
	GenTokens    int
	Warmup       int
	Repeat       int
}

// BenchmarkModelResult holds aggregated results. Nil pointer fields signal
// "no successful iterations" (N/A), matching Python's `return None, None, None`.
type BenchmarkModelResult struct {
	MeanTTFT *float64
	MeanTPS  *float64
	StdevTPS *float64
}

// BenchmarkModel benchmarks a single model via the lemonade HTTP server.
// Loads the model, warms up, measures. Mirrors Python's benchmark_model.
func BenchmarkModel(o BenchmarkModelOpts) (BenchmarkModelResult, error) {
	fmt.Fprintf(os.Stderr, "  Loading %q...\n", o.ModelID)
	if err := LoadModel(o.BaseURL, o.ModelID); err != nil {
		return BenchmarkModelResult{}, err
	}

	mo := MeasureOpts{
		PromptTokens: o.PromptTokens,
		GenTokens:    o.GenTokens,
		Warmup:       o.Warmup,
		Repeat:       o.Repeat,
		IgnoreEOS:    false,
	}

	fmt.Fprintf(os.Stderr, "  Warming up (%d iteration(s))...\n", o.Warmup)
	fmt.Fprintf(os.Stderr, "  Measuring (%d iteration(s))...\n", o.Repeat)
	r := MeasureSpec(o.BaseURL, lemonadeCompletionsPath, o.ModelID, mo)

	// Guard: empty → N/A.
	if len(r.DecodeTPS) == 0 {
		return BenchmarkModelResult{}, nil
	}

	meanTTFT, _ := MeanStdev(r.TTFT)
	meanTPS, stdevTPS := MeanStdev(r.DecodeTPS)
	return BenchmarkModelResult{
		MeanTTFT: &meanTTFT,
		MeanTPS:  &meanTPS,
		StdevTPS: &stdevTPS,
	}, nil
}

// MTPABOpts holds parameters for RunMTPAB.
type MTPABOpts struct {
	ModelID      string
	Backends     []string
	PromptTokens int
	GenTokens    int
	Warmup       int
	Repeat       int
	// BackendBinEnv maps backend key → env var name for the binary path.
	// nil uses the standard LEMONADE_LLAMACPP_{ROCM,VULKAN}_BIN env vars.
	BackendBinEnv map[string]string
}

// MTPABResult holds the MTP-off and MTP-on TPS for one backend.
// Nil TPS pointer means no successful iterations for that spec.
type MTPABResult struct {
	Backend string
	OffTPS  *float64
	OnTPS   *float64
}

// defaultBackendBinEnv maps backend key → env var holding the llama-server binary.
var defaultBackendBinEnv = map[string]string{
	"rocm":   "LEMONADE_LLAMACPP_ROCM_BIN",
	"vulkan": "LEMONADE_LLAMACPP_VULKAN_BIN",
}

// resolveBackendBin returns the llama-server binary path for the given backend.
// Mirrors Python's _resolve_backend_bin.
func resolveBackendBin(backend string, binEnv map[string]string) (string, error) {
	envVar, ok := binEnv[backend]
	if !ok {
		keys := make([]string, 0, len(binEnv))
		for k := range binEnv {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		return "", fmt.Errorf("unknown backend %q; expected one of %v", backend, keys)
	}
	path := os.Getenv(envVar)
	if path == "" {
		return "", fmt.Errorf(
			"%s not set in environment; the nix-amd-ai module sets it when"+
				" hardware.amd-npu.enable%s = true", envVar, strings.ToUpper(backend[:1])+backend[1:],
		)
	}
	return path, nil
}

// RunMTPAB runs an MTP-on / MTP-off A/B across the given backends,
// spawning llama-server twice per backend. Mirrors Python's run_mtp_ab.
func RunMTPAB(o MTPABOpts) ([]MTPABResult, error) {
	if len(o.Backends) == 0 {
		return nil, fmt.Errorf("RunMTPAB: empty backend list")
	}
	binEnv := o.BackendBinEnv
	if binEnv == nil {
		binEnv = defaultBackendBinEnv
	}

	gguf := ResolveLemonadeGGUF(o.ModelID, "")
	if gguf == "" {
		return nil, fmt.Errorf(
			"model %q not found in lemonade cache; run: lemonade pull %s",
			o.ModelID, o.ModelID,
		)
	}

	fmt.Fprintf(os.Stderr,
		"\nMTP A/B sweep: model=%s\n  gguf=%s\n  backends=%v\n"+
			"  protocol: prompt=%d tokens, gen=%d tokens,"+
			" %d warmup + %d measured\n\n",
		o.ModelID, gguf, o.Backends,
		o.PromptTokens, o.GenTokens, o.Warmup, o.Repeat,
	)

	var results []MTPABResult
	for i, backend := range o.Backends {
		if i > 0 {
			time.Sleep(3 * time.Second)
		}

		binPath, err := resolveBackendBin(backend, binEnv)
		if err != nil {
			return nil, err
		}

		// List devices and pick the matching one — hard error if not found.
		devicesOutput, err := runListDevices(binPath)
		if err != nil {
			return nil, fmt.Errorf("[%s] list-devices: %w", backend, err)
		}
		devices, err := ParseLlamaDevices(devicesOutput)
		if err != nil {
			return nil, fmt.Errorf("[%s] parse devices: %w", backend, err)
		}
		device, ok := PickDevice(devices, backend)
		if !ok {
			// PickDevice (_, false) is always a hard error — never run with --device "".
			return nil, fmt.Errorf("[%s] no matching device found (devices=%v)", backend, devices)
		}

		fmt.Fprintf(os.Stderr, "\n[%s] bin=%s device=%s\n", backend, binPath, device)

		specTPS := map[string]*float64{}
		specTypes := []string{"none", "draft-mtp"}
		for j, specType := range specTypes {
			if j > 0 {
				time.Sleep(3 * time.Second)
			}
			fmt.Fprintf(os.Stderr, "\n[%s] --spec-type %s\n", backend, specType)

			port, err := FindFreePort()
			if err != nil {
				return nil, fmt.Errorf("[%s] find free port: %w", backend, err)
			}

			argv := BuildLlamaServerArgs(ServerArgs{
				BinPath:   binPath,
				ModelPath: gguf,
				Port:      port,
				Device:    device,
				SpecType:  specType,
				NGL:       99,
				Ctx:       2048,
			})

			srv := NewLlamaServer(argv, port)
			if startErr := srv.Start(); startErr != nil {
				msg := startErr.Error()
				if specType == "draft-mtp" && strings.Contains(strings.ToLower(msg), "mtp") {
					return nil, fmt.Errorf(
						"model %q has no MTP head (--spec-type draft-mtp rejected by llama-server)."+
							" Pick an MTP-labeled model", o.ModelID,
					)
				}
				return nil, fmt.Errorf("[%s] spec=%s server start: %w", backend, specType, startErr)
			}

			tps := measureOneSpec(srv, o)
			_ = srv.Stop()
			specTPS[specType] = tps
		}

		results = append(results, MTPABResult{
			Backend: backend,
			OffTPS:  specTPS["none"],
			OnTPS:   specTPS["draft-mtp"],
		})
	}
	return results, nil
}

// measureOneSpec runs warmup+repeat MTP completions against a running LlamaServer.
// Returns mean decode TPS, or nil if no successful iterations.
// Mirrors Python's _measure_one_spec.
func measureOneSpec(srv *LlamaServer, o MTPABOpts) *float64 {
	mo := MeasureOpts{
		PromptTokens: o.PromptTokens,
		GenTokens:    o.GenTokens,
		Warmup:       o.Warmup,
		Repeat:       o.Repeat,
		IgnoreEOS:    true,
	}
	r := MeasureSpec(srv.BaseURL, "/v1/completions", "default", mo)
	if len(r.DecodeTPS) == 0 {
		return nil
	}
	mean, _ := MeanStdev(r.DecodeTPS)
	return &mean
}

// runListDevices executes `binPath --list-devices` and returns stdout.
func runListDevices(binPath string) (string, error) {
	out, err := exec.Command(binPath, "--list-devices").Output() //nolint:gosec
	if err != nil {
		return "", err
	}
	return string(out), nil
}
