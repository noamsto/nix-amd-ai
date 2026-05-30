// Package advise provides pure, deterministic functions for GPU inference
// parameter recommendations on Strix Point (gfx1150) hardware.
package advise

// FitState classifies how well a model fits within a GPU memory budget.
type FitState int

const (
	Fits   FitState = iota // model uses < 90% of budget
	Tight                  // model uses >= 90% of budget but does not exceed it
	Spills                 // model exceeds budget
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
// >budget → Spills; >=90% of budget → Tight; else Fits.
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

// BandwidthGBs derives memory bandwidth in decimal GB/s from RAM type and speed.
// DDR5/LPDDR5/LPDDR5X dual-channel formula: speedMTs * 8 * 2 / 1000 GB/s.
// When ramType is empty or speedMTs <= 0, falls back to ddr5Fallback (89.6)
// and returns estimated=true.
func BandwidthGBs(ramType string, speedMTs int) (gbps float64, estimated bool) {
	if ramType == "" || speedMTs <= 0 {
		return ddr5Fallback, true
	}
	// dual-channel: 2 channels × 8 bytes/transfer × speedMTs / 1000
	return float64(speedMTs) * 8 * 2 / 1000, false
}

// Params holds recommended llama.cpp server launch parameters for gfx1150.
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

// RecommendParams returns gfx1150 defaults for a model of the given size.
// Large models (>=8 GiB) use batch=256 to avoid hangs; smaller use batch=512.
// RocWMMA is always false — flash-attention via rocWMMA is a net regression
// on gfx1150 (locally tested: -42% pp4096).
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
