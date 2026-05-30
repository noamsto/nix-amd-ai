package advise

import (
	"math"
	"testing"
)

func TestEstimateActiveGiB(t *testing.T) {
	tests := []struct {
		name        string
		modelID     string
		totalGiB    float64
		wantActive  float64
		wantIsMoE   bool
		wantEpsilon float64
	}{
		{
			name:     "Gemma MoE 26B total 4B active",
			modelID:  "Gemma-4-26B-A4B-it-GGUF",
			totalGiB: 15.7,
			// activeGiB = 15.7 * (4/26) ≈ 2.4154
			wantActive:  15.7 * (4.0 / 26.0),
			wantIsMoE:   true,
			wantEpsilon: 0.05,
		},
		{
			name:     "Qwen3.6 dense 27B",
			modelID:  "Qwen3.6-27B-GGUF",
			totalGiB: 16.0,
			// dense: activeGiB == totalGiB
			wantActive:  16.0,
			wantIsMoE:   false,
			wantEpsilon: 1e-9,
		},
		{
			name:     "Qwen3 30B-A3B MoE",
			modelID:  "Qwen3-30B-A3B",
			totalGiB: 18.0,
			// activeGiB = 18.0 * (3/30) = 1.8
			wantActive:  18.0 * (3.0 / 30.0),
			wantIsMoE:   true,
			wantEpsilon: 0.05,
		},
		{
			name:        "no B token at all",
			modelID:     "SomeModel-GGUF",
			totalGiB:    5.0,
			wantActive:  5.0,
			wantIsMoE:   false,
			wantEpsilon: 1e-9,
		},
		{
			name:        "MoE token but active >= total (nonsensical - treat as dense)",
			modelID:     "Model-4B-A8B",
			totalGiB:    3.0,
			wantActive:  3.0,
			wantIsMoE:   false,
			wantEpsilon: 1e-9,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, isMoE := EstimateActiveGiB(tc.modelID, tc.totalGiB)
			if isMoE != tc.wantIsMoE {
				t.Errorf("EstimateActiveGiB(%q, %.1f): isMoE=%v; want %v", tc.modelID, tc.totalGiB, isMoE, tc.wantIsMoE)
			}
			if math.Abs(got-tc.wantActive) > tc.wantEpsilon {
				t.Errorf("EstimateActiveGiB(%q, %.1f): activeGiB=%.4f; want %.4f (±%.4f)",
					tc.modelID, tc.totalGiB, got, tc.wantActive, tc.wantEpsilon)
			}
		})
	}
}

func TestDecodeCeilingTPS(t *testing.T) {
	// bandwidth is decimal GB/s, model size is GiB. Converted internally:
	// 89.6 / (15.7 * 1.073741824) ≈ 5.32 TPS
	got := DecodeCeilingTPS(89.6, 15.7)
	want := 89.6 / (15.7 * 1.073741824)
	if math.Abs(got-want) > 0.05 {
		t.Errorf("DecodeCeilingTPS(89.6, 15.7) = %.3f; want ~%.3f (±0.05)", got, want)
	}
}

func TestDecodeCeilingTPS_ZeroActive(t *testing.T) {
	// Divide-by-zero guard: activeGiB <= 0 returns 0, not +Inf.
	if got := DecodeCeilingTPS(89.6, 0); got != 0 {
		t.Errorf("DecodeCeilingTPS(89.6, 0) = %v; want 0", got)
	}
}

func TestFitClass(t *testing.T) {
	tests := []struct {
		name      string
		modelGiB  float64
		budgetGiB float64
		want      FitState
	}{
		{"fits comfortably", 15.7, 27, Fits},
		{"tight (>90% budget)", 25, 27, Tight},
		{"spills (exceeds budget)", 30, 27, Spills},
		// Boundary: exactly at budget → Tight (not Spills; >budget means Spills, ==budget means Tight)
		{"exact boundary at budget", 27, 27, Tight},
		// Boundary: exactly at 90% → Tight
		{"exact boundary at 90pct", 27 * 0.9, 27, Tight},
		// Just under 90% → Fits
		{"just under 90pct", 27*0.9 - 0.01, 27, Fits},
		// Defensive: zero/negative budget → Spills
		{"zero budget", 15.7, 0, Spills},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := FitClass(tc.modelGiB, tc.budgetGiB)
			if got != tc.want {
				t.Errorf("FitClass(%.3f, %.3f) = %v; want %v", tc.modelGiB, tc.budgetGiB, got, tc.want)
			}
		})
	}
}

func TestBandwidthGBs(t *testing.T) {
	t.Run("DDR5 5600 MT/s", func(t *testing.T) {
		gbps, estimated := BandwidthGBs("DDR5", 5600)
		if math.Abs(gbps-89.6) > 0.1 {
			t.Errorf("BandwidthGBs(DDR5, 5600) = %.2f; want 89.6 (±0.1)", gbps)
		}
		if estimated {
			t.Error("BandwidthGBs(DDR5, 5600): estimated should be false")
		}
	})

	t.Run("empty type and zero speed falls back to estimated", func(t *testing.T) {
		gbps, estimated := BandwidthGBs("", 0)
		if math.Abs(gbps-89.6) > 0.1 {
			t.Errorf("BandwidthGBs('', 0) = %.2f; want 89.6 (±0.1)", gbps)
		}
		if !estimated {
			t.Error("BandwidthGBs('', 0): estimated should be true")
		}
	})

	t.Run("known type but zero speed falls back to estimated", func(t *testing.T) {
		gbps, estimated := BandwidthGBs("DDR5", 0)
		if math.Abs(gbps-89.6) > 0.1 {
			t.Errorf("BandwidthGBs(DDR5, 0) = %.2f; want 89.6 (±0.1)", gbps)
		}
		if !estimated {
			t.Error("BandwidthGBs(DDR5, 0): estimated should be true")
		}
	})
}

func TestRecommendParams(t *testing.T) {
	t.Run("large model (>=8 GiB) uses batch 256", func(t *testing.T) {
		p := RecommendParams(15.7)
		if p.Batch != 256 {
			t.Errorf("RecommendParams(15.7).Batch = %d; want 256", p.Batch)
		}
		if p.Parallel != 1 {
			t.Errorf("RecommendParams(15.7).Parallel = %d; want 1", p.Parallel)
		}
		if !p.FlashAttn {
			t.Error("RecommendParams(15.7).FlashAttn should be true")
		}
		if p.RocWMMA {
			t.Error("RecommendParams(15.7).RocWMMA must always be false (gfx1150 regression)")
		}
		if p.NGL != 999 {
			t.Errorf("RecommendParams(15.7).NGL = %d; want 999", p.NGL)
		}
		if p.Ctx != 2048 {
			t.Errorf("RecommendParams(15.7).Ctx = %d; want 2048", p.Ctx)
		}
		if p.UBatch != 256 {
			t.Errorf("RecommendParams(15.7).UBatch = %d; want 256", p.UBatch)
		}
	})

	t.Run("small model (<8 GiB) uses batch 512", func(t *testing.T) {
		p := RecommendParams(4.0)
		if p.Batch != 512 {
			t.Errorf("RecommendParams(4.0).Batch = %d; want 512", p.Batch)
		}
		if p.RocWMMA {
			t.Error("RecommendParams(4.0).RocWMMA must always be false")
		}
	})

	// 9.0 GiB is >= 8 GiB cutoff but < the old plan's 10 GiB; pins the 8 GiB choice.
	t.Run("9 GiB model crosses 8 GiB cutoff -> batch 256", func(t *testing.T) {
		if p := RecommendParams(9.0); p.Batch != 256 {
			t.Errorf("RecommendParams(9.0).Batch = %d; want 256", p.Batch)
		}
	})
}

func TestBudgetGiB(t *testing.T) {
	// 29292957696 bytes / 1024^3 = exactly 27.28125 GiB
	got := BudgetGiB(29292957696)
	want := 29292957696.0 / (1024 * 1024 * 1024)
	if math.Abs(got-want) > 1e-9 {
		t.Errorf("BudgetGiB(29292957696) = %.10f; want %.10f", got, want)
	}
}
