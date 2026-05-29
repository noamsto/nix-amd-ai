package bench

import (
	"math"
	"testing"
)

func TestMeanStdev(t *testing.T) {
	t.Run("empty", func(t *testing.T) {
		m, s := MeanStdev(nil)
		if m != 0 || s != 0 {
			t.Errorf("empty: got (%v, %v), want (0, 0)", m, s)
		}
	})

	t.Run("single", func(t *testing.T) {
		m, s := MeanStdev([]float64{5})
		if m != 5 || s != 0 {
			t.Errorf("single: got (%v, %v), want (5, 0)", m, s)
		}
	})

	// [2, 4]: mean=3, sample stdev (n-1) = sqrt(2) ≈ 1.4142, pstdev (n) = 1.0
	// Python uses statistics.stdev (sample, n-1), so expected ≈ 1.4142
	t.Run("two_elements_distinguishes_sample_vs_population", func(t *testing.T) {
		m, s := MeanStdev([]float64{2, 4})
		if math.Abs(m-3.0) > 1e-9 {
			t.Errorf("mean: got %v, want 3.0", m)
		}
		want := math.Sqrt(2) // sample stdev with n-1
		if math.Abs(s-want) > 1e-9 {
			t.Errorf("stdev: got %v, want %v (sample/n-1); pstdev would be 1.0", s, want)
		}
	})

	t.Run("three_elements", func(t *testing.T) {
		m, s := MeanStdev([]float64{2, 4, 6})
		if math.Abs(m-4.0) > 1e-9 {
			t.Errorf("mean: got %v, want 4.0", m)
		}
		// sample stdev: deviations [-2,0,2], sq sum=8, /2=4, sqrt=2.0
		if math.Abs(s-2.0) > 1e-9 {
			t.Errorf("stdev: got %v, want 2.0", s)
		}
	})
}
