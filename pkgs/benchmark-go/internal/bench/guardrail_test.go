package bench

import (
	"fmt"
	"io"
	"strings"
	"testing"
)

const giBUnit = 1 << 30

func TestCheckGPUMemBudget(t *testing.T) {
	model := uint64(15 * giBUnit)
	tests := []struct {
		name    string
		free    uint64
		wantErr bool
	}{
		{"ample free", 26 * giBUnit, false},
		{"exactly model+headroom", 17 * giBUnit, false}, // 15 + 2 GiB headroom
		{"one byte short", 17*giBUnit - 1, true},
		{"occupied gpu", 11 * giBUnit, true},
		{"nothing free", 0, true},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			err := checkGPUMemBudget(model, tc.free)
			if (err != nil) != tc.wantErr {
				t.Fatalf("checkGPUMemBudget(%d, %d) err=%v, wantErr=%v", model, tc.free, err, tc.wantErr)
			}
			if err != nil && !strings.Contains(err.Error(), "insufficient free GPU memory") {
				t.Errorf("error missing actionable prefix: %v", err)
			}
		})
	}
}

func TestEnsureGPUMem(t *testing.T) {
	model := uint64(15 * giBUnit)

	t.Run("zero model size is a no-op", func(t *testing.T) {
		called := false
		err := ensureGPUMem(0, func() (uint64, bool) { called = true; return 0, true }, nil, io.Discard)
		if err != nil || called {
			t.Fatalf("expected no-op, got err=%v memFreeCalled=%v", err, called)
		}
	})

	t.Run("unmeasurable memory fails open", func(t *testing.T) {
		err := ensureGPUMem(model, func() (uint64, bool) { return 0, false }, nil, io.Discard)
		if err != nil {
			t.Fatalf("expected fail-open nil, got %v", err)
		}
	})

	t.Run("ample free does not evacuate", func(t *testing.T) {
		evac := false
		err := ensureGPUMem(model, func() (uint64, bool) { return 26 * giBUnit, true },
			func() error { evac = true; return nil }, io.Discard)
		if err != nil || evac {
			t.Fatalf("expected no evacuation, got err=%v evac=%v", err, evac)
		}
	})

	t.Run("evacuation frees enough", func(t *testing.T) {
		calls := 0
		evac := 0
		// First probe short; after evacuate, probes return ample.
		memFree := func() (uint64, bool) {
			calls++
			if evac == 0 {
				return 11 * giBUnit, true
			}
			return 26 * giBUnit, true
		}
		err := ensureGPUMem(model, memFree, func() error { evac++; return nil }, io.Discard)
		if err != nil {
			t.Fatalf("expected success after evacuation, got %v", err)
		}
		if evac != 1 {
			t.Errorf("expected exactly one evacuate call, got %d", evac)
		}
	})

	t.Run("evacuation does not free enough → actionable error", func(t *testing.T) {
		err := ensureGPUMem(model, func() (uint64, bool) { return 11 * giBUnit, true },
			func() error { return nil }, io.Discard)
		if err == nil || !strings.Contains(err.Error(), "insufficient free GPU memory") {
			t.Fatalf("expected actionable error, got %v", err)
		}
	})

	t.Run("evacuation error still yields actionable error", func(t *testing.T) {
		err := ensureGPUMem(model, func() (uint64, bool) { return 11 * giBUnit, true },
			func() error { return fmt.Errorf("boom") }, io.Discard)
		if err == nil || !strings.Contains(err.Error(), "insufficient free GPU memory") {
			t.Fatalf("expected actionable error after failed evacuate, got %v", err)
		}
	})

	t.Run("no evacuator → fails fast", func(t *testing.T) {
		err := ensureGPUMem(model, func() (uint64, bool) { return 11 * giBUnit, true }, nil, io.Discard)
		if err == nil || !strings.Contains(err.Error(), "insufficient free GPU memory") {
			t.Fatalf("expected fail-fast error, got %v", err)
		}
	})
}
