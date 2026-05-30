package bench

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"os"
	"os/exec"
	"sort"
	"strings"
	"time"

	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/hw"
)

// logWriter returns w if non-nil, otherwise os.Stderr.
// Used so a nil LogW field transparently defaults to headless behavior.
func logWriter(w io.Writer) io.Writer {
	if w == nil {
		return os.Stderr
	}
	return w
}

// ErrNoMTPHead is returned by RunMTPAB when llama-server rejects
// --spec-type draft-mtp because the model has no MTP draft head.
var ErrNoMTPHead = errors.New("no MTP head")

// completionHTTPTimeout bounds streaming completion and model-load requests.
// Shared by runOneCompletion and LoadModel so they cannot silently diverge.
const completionHTTPTimeout = 300 * time.Second

// settleDelay lets GPU memory drain between llama-server launches.
const settleDelay = 3 * time.Second

type MeasureOpts struct {
	PromptTokens int
	GenTokens    int
	Warmup       int
	Repeat       int
	IgnoreEOS    bool
	// PhaseLog prints "Warming up"/"Measuring" to LogW at the phase
	// boundaries, matching Python's benchmark_model interleaving. The MTP
	// path (_measure_one_spec) leaves it false — Python prints no phase logs
	// there.
	PhaseLog bool
	// LogW is the destination for status prints ("Warming up", "Measuring",
	// per-iteration warnings). nil → os.Stderr (headless default).
	// The TUI sets this to io.Discard to keep the alt-screen clean.
	LogW io.Writer
	// OnIteration, if non-nil, is called after each measured (non-warmup)
	// iteration with the 1-based index and the iteration's decode t/s. Skipped
	// no-token iterations do not fire it. Nil-safe: nil means no callback.
	OnIteration func(iter int, decodeTPS float64)
	// OnPhase, if non-nil, fires at the start of the warmup and measure phases
	// ("warming up" / "measuring") so a UI can show what's happening during the
	// otherwise-silent warmup. Nil-safe.
	OnPhase func(phase string)
}

// MeasureResult holds per-iteration samples from a measurement run.
// Empty slices mean "no successful iterations" — callers MUST guard with
// len check before calling MeanStdev (empty → render as N/A).
type MeasureResult struct {
	TTFT      []float64 // time-to-first-token per successful iteration (seconds)
	DecodeTPS []float64 // decode throughput per successful iteration (tokens/s)
}

// completionResult holds what one streaming completion returns.
// ok=false is the "no tokens" sentinel.
type completionResult struct {
	ttft      float64
	decodeTPS float64
	tokens    int
	ok        bool
}

// runOneCompletion posts one streaming completion to baseURL+path and returns timing/TPS.
//
// Timing rules:
//   - completion_tokens = server CompletionTokens if > 0, else client TextTokenCount
//   - decode_tps = server PredictedPerSecond if > 0, else wall-clock
//     (compTokens-1)/decodeElapsed; 0 if compTokens<=1; +Inf if elapsed<=0
//   - TTFT = wall-clock from request start to first non-empty text token
//
// Returns ok=false when no tokens received.
func runOneCompletion(ctx context.Context, baseURL, path string, opts CompletionOpts) completionResult {
	payload := BuildCompletionPayload(opts)
	body, err := json.Marshal(payload)
	if err != nil {
		return completionResult{}
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, baseURL+path, bytes.NewReader(body))
	if err != nil {
		return completionResult{}
	}
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: completionHTTPTimeout}

	tStart := time.Now()
	resp, err := client.Do(req)
	if err != nil {
		return completionResult{}
	}
	defer resp.Body.Close()

	// Parse SSE stream while recording per-token wall-clock times. Uses scanSSE
	// directly (rather than ParseSSE) to capture per-token timestamps.
	var (
		tFirstToken time.Time
		tLastToken  time.Time
		textCount   int // client-side non-empty text token count

		finalCompTokens   int
		finalPredictedTPS float64
	)

	_ = scanSSE(resp.Body, func(c sseChunk) {
		// Overwrite on each truthy value — last truthy wins.
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
	})

	if tFirstToken.IsZero() {
		return completionResult{}
	}

	ttft := tFirstToken.Sub(tStart).Seconds()

	// completion_tokens: server-reported if truthy, else client count.
	compTokens := finalCompTokens
	if compTokens == 0 {
		compTokens = textCount
	}

	// decode_tps: server-reported if truthy (!= 0), else wall-clock.
	// A pathological negative server TPS is taken as-is.
	var decodeTPS float64
	if finalPredictedTPS != 0 {
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
// Skips iterations that return no tokens. Empty result slices mean all failed.
//
// ctx cancellation interrupts the in-flight HTTP call and breaks the loops at
// the next iteration boundary, returning promptly without blocking up to completionHTTPTimeout.
func MeasureSpec(ctx context.Context, baseURL, path, model string, o MeasureOpts) MeasureResult {
	var prompt string
	if o.IgnoreEOS {
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

	lw := logWriter(o.LogW)
	if o.Warmup > 0 && o.OnPhase != nil {
		o.OnPhase("warming up")
	}
	if o.PhaseLog {
		fmt.Fprintf(lw, "  Warming up (%d iteration(s))...\n", o.Warmup)
	}
	for range o.Warmup {
		if ctx.Err() != nil {
			return MeasureResult{}
		}
		runOneCompletion(ctx, baseURL, path, opts)
	}

	if o.OnPhase != nil {
		o.OnPhase("measuring")
	}
	if o.PhaseLog {
		fmt.Fprintf(lw, "  Measuring (%d iteration(s))...\n", o.Repeat)
	}
	var result MeasureResult
	for i := range o.Repeat {
		if ctx.Err() != nil {
			break
		}
		cr := runOneCompletion(ctx, baseURL, path, opts)
		if !cr.ok {
			fmt.Fprintf(lw, "  WARNING: iteration %d produced no tokens\n", i+1)
			continue
		}
		result.TTFT = append(result.TTFT, cr.ttft)
		result.DecodeTPS = append(result.DecodeTPS, cr.decodeTPS)
		if o.OnIteration != nil {
			o.OnIteration(len(result.DecodeTPS), cr.decodeTPS)
		}
	}
	return result
}

type BenchmarkModelOpts struct {
	BaseURL      string
	ModelID      string
	PromptTokens int
	GenTokens    int
	Warmup       int
	Repeat       int
	// LogW is the destination for status prints. nil → os.Stderr.
	LogW io.Writer
	// OnIteration, if non-nil, fires after each measured iteration. See
	// MeasureOpts.OnIteration.
	OnIteration func(iter int, decodeTPS float64)
}

// BenchmarkModelResult holds aggregated results. Nil pointer fields signal N/A.
type BenchmarkModelResult struct {
	MeanTTFT *float64
	MeanTPS  *float64
	StdevTPS *float64
}

// BenchmarkModel loads a model into lemonade then warms up and measures.
// ctx cancellation interrupts the in-flight measurement; LoadModel has its own timeout.
func BenchmarkModel(ctx context.Context, o BenchmarkModelOpts) (BenchmarkModelResult, error) {
	fmt.Fprintf(logWriter(o.LogW), "  Loading %q...\n", o.ModelID)
	if err := LoadModel(o.BaseURL, o.ModelID); err != nil {
		return BenchmarkModelResult{}, err
	}

	mo := MeasureOpts{
		PromptTokens: o.PromptTokens,
		GenTokens:    o.GenTokens,
		Warmup:       o.Warmup,
		Repeat:       o.Repeat,
		IgnoreEOS:    false,
		PhaseLog:     true,
		LogW:         o.LogW,
		OnIteration:  o.OnIteration,
	}

	r := MeasureSpec(ctx, o.BaseURL, lemonadeCompletionsPath, o.ModelID, mo)

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

type MTPABOpts struct {
	ModelID      string
	Backends     []string
	PromptTokens int
	GenTokens    int
	Warmup       int
	Repeat       int
	// CtxSize is the llama-server --ctx-size. <= 0 defaults to 2048.
	CtxSize int
	// BackendBinEnv maps backend key → env var name for the binary path.
	// nil uses the standard LEMONADE_LLAMACPP_{ROCM,VULKAN}_BIN env vars.
	BackendBinEnv map[string]string
	// LogW is the destination for status prints ("MTP A/B sweep", per-backend
	// bin/device lines, per-spec-type lines). nil → os.Stderr.
	// The TUI sets this to io.Discard.
	LogW io.Writer
	// OnIteration, if non-nil, fires after each measured iteration with the
	// backend, spec type ("none" | "draft-mtp"), the 1-based iteration index,
	// and the iteration's decode t/s. Lets a TUI stream per-iteration progress.
	OnIteration func(backend, specType string, iter int, decodeTPS float64)
	// OnStatus, if non-nil, reports the current activity for a (backend,
	// specType) unit during otherwise-silent phases: "freeing GPU memory",
	// "loading model", "warming up", "measuring". Lets a UI show what's
	// happening between measured iterations. Nil-safe.
	OnStatus func(backend, specType, status string)
	// BaseURL is the lemonade server (scheme+host+port). Used only to evacuate a
	// lemonade-held model when the GPU-memory guardrail trips. "" disables it.
	BaseURL string
	// GPUMemFree returns live free GPU (GTT) bytes; ok=false when unreadable.
	// nil defaults to hw.GPUMemFree. The guardrail in RunMTPAB uses it to fail
	// fast when the GPU can't hold the model (test seam: inject a fake).
	GPUMemFree func() (free uint64, ok bool)
	// Evacuate frees GPU memory when the guardrail trips (default: unload the
	// lemonade model via BaseURL). nil + empty BaseURL disables evacuation, so
	// the guardrail fails fast instead (test seam: inject a fake).
	Evacuate func() error
}

// gpuDrainPolls / gpuDrainPollInterval bound how long ensureGPUMem waits for
// GTT to drain after an evacuation. Unload is near-instant (measured <1s) but a
// short poll absorbs allocator lag.
const (
	gpuDrainPolls        = 6
	gpuDrainPollInterval = 500 * time.Millisecond
)

// ensureGPUMem is the GPU-memory guardrail: it confirms the model fits in free
// GPU memory before a server is spawned. If memory is short it evacuates (the
// default frees a lemonade-held model, the most common occupant) and re-checks,
// returning an actionable error only if the GPU is still too full afterward.
// Fails open (nil) when free memory can't be measured — the server's stderr
// tail then surfaces in any readiness-timeout error.
func ensureGPUMem(modelBytes uint64, memFree func() (uint64, bool), evacuate func() error, lw io.Writer, onEvacuate func()) error {
	if modelBytes == 0 || memFree == nil {
		return nil
	}
	free, ok := memFree()
	if !ok {
		return nil
	}
	if checkGPUMemBudget(modelBytes, free) == nil {
		return nil
	}

	if evacuate != nil {
		if onEvacuate != nil {
			onEvacuate()
		}
		fmt.Fprintf(lw, "  GPU low on free memory (%.1f GiB); evacuating loaded model…\n", giB(free))
		if err := evacuate(); err != nil {
			fmt.Fprintf(lw, "  WARNING: evacuate failed: %v\n", err)
		} else {
			for range gpuDrainPolls {
				time.Sleep(gpuDrainPollInterval)
				if f, ok := memFree(); ok && checkGPUMemBudget(modelBytes, f) == nil {
					return nil
				}
			}
		}
	}

	free, ok = memFree()
	if !ok {
		return nil
	}
	return checkGPUMemBudget(modelBytes, free)
}

// gpuMemHeadroomBytes is GTT needed beyond the GGUF file itself: KV cache, the
// MTP draft head, and allocator fragmentation. The loaded footprint runs
// ~1–2 GiB over file size at ctx 2048 (measured: 15.5 GiB file → 17.3 GiB GTT).
const gpuMemHeadroomBytes = 2 << 30 // 2 GiB

func giB(b uint64) float64 { return float64(b) / (1 << 30) }

// checkGPUMemBudget fails fast when free GPU memory can't hold the model plus
// headroom. This is the guardrail against the silent failure mode where a server
// starts on a GPU that's already occupied (a loaded lemonade model or a stray
// llama-server), loads partially, then never goes ready — surfacing only as an
// HTTP 503 after the full 5-minute readiness timeout. modelBytes is the GGUF
// file size; freeBytes is live free GTT. Returns nil when there is enough room.
func checkGPUMemBudget(modelBytes, freeBytes uint64) error {
	need := modelBytes + gpuMemHeadroomBytes
	if freeBytes >= need {
		return nil
	}
	return fmt.Errorf(
		"insufficient free GPU memory: %.1f GiB free but the model needs ~%.1f GiB "+
			"(%.1f GiB model + headroom). Something else is holding the GPU — a loaded "+
			"lemonade model or a stray llama-server. Free it (lemonade unload, or kill "+
			"the llama-server process) and retry",
		giB(freeBytes), giB(need), giB(modelBytes),
	)
}

// MTPABResult holds the MTP-off and MTP-on TPS for one backend.
// Nil TPS pointer means no successful iterations for that spec.
type MTPABResult struct {
	Backend string
	OffTPS  *float64
	OnTPS   *float64
}

var defaultBackendBinEnv = map[string]string{
	"rocm":   "LEMONADE_LLAMACPP_ROCM_BIN",
	"vulkan": "LEMONADE_LLAMACPP_VULKAN_BIN",
}

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

// mtpABDefaultCtx is the fallback --ctx-size: sized to the 512+128-token
// workload with headroom. Larger ctx wastes KV memory and risks iGPU offload.
const mtpABDefaultCtx = 2048

func resolveCtxSize(ctx int) int {
	if ctx <= 0 {
		return mtpABDefaultCtx
	}
	return ctx
}

// RunMTPAB runs an MTP-on / MTP-off A/B across the given backends,
// spawning llama-server twice per backend.
// ctx cancellation stops the sweep at the next backend/spec boundary;
// the per-spec deferred Stop() still tears the server down.
func RunMTPAB(ctx context.Context, o MTPABOpts) ([]MTPABResult, error) {
	if len(o.Backends) == 0 {
		return nil, fmt.Errorf("RunMTPAB: empty backend list")
	}
	binEnv := o.BackendBinEnv
	if binEnv == nil {
		binEnv = defaultBackendBinEnv
	}

	ctxSize := resolveCtxSize(o.CtxSize)

	gguf := ResolveLemonadeGGUF(o.ModelID, "")
	if gguf == "" {
		return nil, fmt.Errorf(
			"model %q not found in lemonade cache; run: lemonade pull %s",
			o.ModelID, o.ModelID,
		)
	}

	// Model file size + the GPU-memory probe drive the pre-spawn guardrail below.
	var modelBytes uint64
	if fi, statErr := os.Stat(gguf); statErr == nil && fi.Size() > 0 {
		modelBytes = uint64(fi.Size())
	}
	memFree := o.GPUMemFree
	if memFree == nil {
		memFree = hw.GPUMemFree
	}
	evacuate := o.Evacuate
	if evacuate == nil && o.BaseURL != "" {
		baseURL := strings.TrimRight(o.BaseURL, "/")
		evacuate = func() error { return UnloadLemonadeModel(baseURL) }
	}

	lw := logWriter(o.LogW)
	fmt.Fprintf(lw,
		"\nMTP A/B sweep: model=%s\n  gguf=%s\n  backends=%v\n"+
			"  protocol: prompt=%d tokens, gen=%d tokens,"+
			" %d warmup + %d measured\n\n",
		o.ModelID, gguf, o.Backends,
		o.PromptTokens, o.GenTokens, o.Warmup, o.Repeat,
	)

	var results []MTPABResult
	for i, backend := range o.Backends {
		if ctx.Err() != nil {
			return results, ctx.Err()
		}
		if i > 0 {
			time.Sleep(settleDelay)
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

		fmt.Fprintf(lw, "\n[%s] bin=%s device=%s\n", backend, binPath, device)

		specTPS := map[string]*float64{}
		specTypes := []string{"none", "draft-mtp"}
		for j, specType := range specTypes {
			if ctx.Err() != nil {
				return results, ctx.Err()
			}
			if j > 0 {
				time.Sleep(settleDelay)
			}
			// Run each spec in its own closure so the deferred Stop() always
			// runs — on normal return, on the error path, or on a panic —
			// before the loop moves to the next spec or returns.
			tps, err := func() (*float64, error) {
				fmt.Fprintf(lw, "\n[%s] --spec-type %s\n", backend, specType)
				emit := func(status string) {
					if o.OnStatus != nil {
						o.OnStatus(backend, specType, status)
					}
				}

				port, err := FindFreePort()
				if err != nil {
					return nil, fmt.Errorf("[%s] find free port: %w", backend, err)
				}

				// Guardrail: ensure the GPU can hold the model (evacuating a
				// lemonade-held model if needed) instead of spawning a server
				// that hangs until the 5m readiness timeout. Re-checked per spec.
				if memErr := ensureGPUMem(modelBytes, memFree, evacuate, lw, func() { emit("freeing GPU memory") }); memErr != nil {
					return nil, fmt.Errorf("[%s] spec=%s: %w", backend, specType, memErr)
				}

				emit("loading model")
				argv := BuildLlamaServerArgs(ServerArgs{
					BinPath:   binPath,
					ModelPath: gguf,
					Port:      port,
					Device:    device,
					SpecType:  specType,
					NGL:       99,
					Ctx:       ctxSize,
				})

				srv := NewLlamaServer(argv, port)
				srv.LogW = o.LogW
				if startErr := srv.Start(); startErr != nil {
					msg := startErr.Error()
					if specType == "draft-mtp" && strings.Contains(strings.ToLower(msg), "mtp") {
						return nil, fmt.Errorf(
							"%w: model %q rejected --spec-type draft-mtp (pick an MTP-labeled model)",
							ErrNoMTPHead, o.ModelID,
						)
					}
					return nil, fmt.Errorf("[%s] spec=%s server start: %w", backend, specType, startErr)
				}
				defer func() { _ = srv.Stop() }()

				return measureOneSpec(ctx, srv, o, backend, specType), nil
			}()
			if err != nil {
				return nil, err
			}
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
func measureOneSpec(ctx context.Context, srv *LlamaServer, o MTPABOpts, backend, specType string) *float64 {
	mo := MeasureOpts{
		PromptTokens: o.PromptTokens,
		GenTokens:    o.GenTokens,
		Warmup:       o.Warmup,
		Repeat:       o.Repeat,
		IgnoreEOS:    true,
		LogW:         o.LogW,
	}
	if o.OnIteration != nil {
		mo.OnIteration = func(iter int, decodeTPS float64) {
			o.OnIteration(backend, specType, iter, decodeTPS)
		}
	}
	if o.OnStatus != nil {
		mo.OnPhase = func(phase string) { o.OnStatus(backend, specType, phase) }
	}
	r := MeasureSpec(ctx, srv.BaseURL, "/v1/completions", "default", mo)
	if len(r.DecodeTPS) == 0 {
		return nil
	}
	mean, _ := MeanStdev(r.DecodeTPS)
	return &mean
}

func runListDevices(binPath string) (string, error) {
	out, err := exec.Command(binPath, "--list-devices").Output() //nolint:gosec
	if err != nil {
		return "", err
	}
	return string(out), nil
}
