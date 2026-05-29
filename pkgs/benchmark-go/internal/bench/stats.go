package bench

import "math"

// MeanStdev returns the sample mean and sample standard deviation (n-1 divisor),
// matching Python's statistics.stdev / statistics.mean.
// Empty slice returns (0, 0); single element returns (x, 0).
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
