// Package advise provides pure, deterministic functions for GPU inference
// parameter recommendations on Strix Point (gfx1150) hardware.
package advise

import (
	"regexp"
	"strconv"
	"strings"
)

// FitState classifies how well a model fits within a GPU memory budget.
// Fits < 90% of budget; Tight >= 90%; Spills > budget.
type FitState int

const (
	Fits FitState = iota
	Tight
	Spills
)

// DecodeCeilingTPS returns the bandwidth-bound decode ceiling in tokens/second.
// bandwidthGBs is decimal GB/s; activeGiB is the model's active size in binary
// GiB (every weight read once per token for a dense model). The GiB→GB
// conversion (×1.073741824) is applied internally so the ratio is
// unit-consistent — skipping it inflates the ceiling ~7.4%.
// Returns 0 for activeGiB <= 0 (divide-by-zero guard).
func DecodeCeilingTPS(bandwidthGBs, activeGiB float64) float64 {
	if activeGiB <= 0 {
		return 0
	}
	activeGB := activeGiB * (1 << 30) / 1e9
	return bandwidthGBs / activeGB
}

// FitClass classifies modelGiB against the usable GPU memory budget.
// Boundary: modelGiB == budgetGiB → Tight (not Spills).
func FitClass(modelGiB, budgetGiB float64) FitState {
	if budgetGiB <= 0 {
		return Spills
	}
	if modelGiB > budgetGiB {
		return Spills
	}
	if modelGiB >= 0.9*budgetGiB {
		return Tight
	}
	return Fits
}

// ddr5Fallback is the documented assumption used when RAM type/speed is unknown.
// Strix Point DDR5-5600 dual-channel: 5600 MT/s * 8 bytes * 2 channels / 1000 = 89.6 GB/s.
const ddr5Fallback = 89.6

// BandwidthGBs returns decimal GB/s for dual-channel RAM (speedMTs * 8 * 2 / 1000).
// Falls back to ddr5Fallback (89.6) when ramType is empty or speedMTs <= 0,
// and returns estimated=true.
func BandwidthGBs(ramType string, speedMTs int) (gbps float64, estimated bool) {
	if ramType == "" || speedMTs <= 0 {
		return ddr5Fallback, true
	}
	// dual-channel: 2 channels × 8 bytes/transfer × speedMTs / 1000
	return float64(speedMTs) * 8 * 2 / 1000, false
}

// Params holds recommended llama.cpp launch parameters for gfx1150.
type Params struct {
	NGL       int
	Batch     int
	UBatch    int
	Ctx       int
	Parallel  int
	FlashAttn bool
	RocWMMA   bool // always false on gfx1150 (local regression, -42% pp4096)
}

// largeBatchCutoffGiB: models at/above this size start at batch 256 (anti-hang).
// 8 GiB is chosen over a looser 10 GiB so ~8-10 GiB models also get the safer batch.
const largeBatchCutoffGiB = 8.0

// RecommendParams returns gfx1150 defaults for a model of modelGiB.
// Models >=8 GiB use batch=256 to avoid hangs; smaller use batch=512.
// RocWMMA is always false — net regression on gfx1150 (−42% pp4096).
func RecommendParams(modelGiB float64) Params {
	batch := 512
	if modelGiB >= largeBatchCutoffGiB {
		batch = 256
	}
	return Params{
		NGL:       999,
		Batch:     batch,
		UBatch:    256,
		Ctx:       2048,
		Parallel:  1,
		FlashAttn: true,
		RocWMMA:   false,
	}
}

// BudgetGiB converts a GTT byte count to GiB.
// On Strix Point, GTT (not the UMA carveout) is the real usable GPU memory ceiling.
func BudgetGiB(gttBytes uint64) float64 {
	return float64(gttBytes) / (1024 * 1024 * 1024)
}

// reTotalB matches a plain "<n>B" param token, e.g. "26B", "27B", "30B".
// A<n>B tokens are excluded by checking for a preceding "A" in EstimateActiveGiB.
var reTotalB = regexp.MustCompile(`(?i)(\d+(?:\.\d+)?)B`)

// reActiveB matches an MoE active-param token, e.g. "A4B", "A3B".
var reActiveB = regexp.MustCompile(`(?i)A(\d+(?:\.\d+)?)B`)

// EstimateActiveGiB returns the active bytes/token size (in GiB) for the
// decode-ceiling calc, derived from the model name + total size.
//
// Heuristic: parse the model ID (case-insensitive) for an active token
// A<n>B (e.g. "A4B" in "Gemma-4-26B-A4B") and a total token <n>B (e.g. "26B").
// If both are found and active < total, it is an MoE model:
//
//	activeGiB = totalGiB * (activeB / totalB)
//
// For a dense model, active == total. The total token is the largest plain <n>B
// value found; the active token is the A<n>B value. "A4B" is excluded from the
// total-token candidates because it is fully consumed by reActiveB first.
func EstimateActiveGiB(modelID string, totalGiB float64) (activeGiB float64, isMoE bool) {
	upper := strings.ToUpper(modelID)

	activeMatch := reActiveB.FindStringSubmatch(upper)
	if activeMatch == nil {
		return totalGiB, false
	}
	activeB, err := strconv.ParseFloat(activeMatch[1], 64)
	if err != nil || activeB <= 0 {
		return totalGiB, false
	}

	allTotalMatches := reTotalB.FindAllStringIndex(upper, -1)
	var totalB float64
	for _, loc := range allTotalMatches {
		start, end := loc[0], loc[1]
		if start > 0 && upper[start-1] == 'A' {
			continue
		}
		raw := upper[start : end-1] // strip trailing "B"
		v, err := strconv.ParseFloat(raw, 64)
		if err != nil {
			continue
		}
		if v > totalB {
			totalB = v
		}
	}

	if totalB <= 0 || activeB >= totalB {
		return totalGiB, false
	}

	return totalGiB * (activeB / totalB), true
}
