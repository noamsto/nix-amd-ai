package bench

import "math"

// MeanStdev returns the sample mean and sample standard deviation (n-1 divisor),
// matching Python's statistics.stdev / statistics.mean.
//
// Callers MUST guard against empty input: an empty slice means "no samples",
// not "measured zero". Python's statistics.mean raises on empty input, and
// benchmark.py guards with `if not tps_samples: return None,...` so empty never
// reaches it (rendered as "N/A" in the table). The (0, 0) returned here for an
// empty slice is a convenience to avoid a panic, NOT a sentinel — do not treat
// it as a real measurement. A single element returns (x, 0).
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
	// n-1 divisor: sample stdev, matching Python statistics.stdev
	return mean, math.Sqrt(sq / float64(n-1))
}
