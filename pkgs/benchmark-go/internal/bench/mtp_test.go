package bench

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestMTPResidentBytes(t *testing.T) {
	dir := t.TempDir()
	write := func(name string, n int) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, make([]byte, n), 0o600); err != nil {
			t.Fatal(err)
		}
		return p
	}
	gguf := write("model.gguf", 100)
	draft := write("draft.gguf", 25)

	tests := []struct {
		name    string
		gguf    string
		draft   string
		want    uint64
		wantErr bool
	}{
		{"no draft", gguf, "", 100, false},
		{"draft file adds its size", gguf, draft, 125, false},
		{"draft is a directory", gguf, dir, 0, true},
		{"draft missing", gguf, filepath.Join(dir, "nope.gguf"), 0, true},
		{"missing gguf counts as zero", filepath.Join(dir, "nope.gguf"), draft, 25, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := mtpResidentBytes(tt.gguf, tt.draft)
			if (err != nil) != tt.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tt.wantErr)
			}
			if got != tt.want {
				t.Errorf("bytes = %d, want %d", got, tt.want)
			}
		})
	}
}

func TestMTPStartError(t *testing.T) {
	cause := errors.New("llama-server exited: failed to load draft-mtp head /m/mtp-head.gguf")

	t.Run("draft path keeps the original error", func(t *testing.T) {
		err := mtpStartError(MTPABOpts{ModelID: "M", DraftModelPath: "/m/mtp-head.gguf"}, "rocm", "draft-mtp", cause)
		if errors.Is(err, ErrNoMTPHead) {
			t.Errorf("draft-path failure must not map to ErrNoMTPHead: %v", err)
		}
		if !errors.Is(err, cause) {
			t.Errorf("startErr not wrapped: %v", err)
		}
	})

	t.Run("no draft mtp failure maps to ErrNoMTPHead and wraps startErr", func(t *testing.T) {
		err := mtpStartError(MTPABOpts{ModelID: "M"}, "rocm", "draft-mtp", cause)
		if !errors.Is(err, ErrNoMTPHead) {
			t.Errorf("want ErrNoMTPHead, got: %v", err)
		}
		if !errors.Is(err, cause) {
			t.Errorf("startErr not wrapped: %v", err)
		}
	})

	t.Run("unrelated failure is not rewritten", func(t *testing.T) {
		other := errors.New("out of memory")
		err := mtpStartError(MTPABOpts{ModelID: "M"}, "rocm", "draft-mtp", other)
		if errors.Is(err, ErrNoMTPHead) || !errors.Is(err, other) || !strings.Contains(err.Error(), "[rocm]") {
			t.Errorf("unexpected: %v", err)
		}
	})

	t.Run("none arm is not rewritten", func(t *testing.T) {
		err := mtpStartError(MTPABOpts{ModelID: "M"}, "rocm", "none", cause)
		if errors.Is(err, ErrNoMTPHead) {
			t.Errorf("none arm must not map to ErrNoMTPHead: %v", err)
		}
		if !errors.Is(err, cause) {
			t.Errorf("startErr not wrapped: %v", err)
		}
	})
}
