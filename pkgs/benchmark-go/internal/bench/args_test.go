package bench

import (
	"testing"
)

// flagValue finds flag in args and returns the immediately following value.
// Returns ("", false) if the flag is absent.
func flagValue(args []string, flag string) (string, bool) {
	for i, a := range args {
		if a == flag && i+1 < len(args) {
			return args[i+1], true
		}
	}
	return "", false
}

func TestBuildLlamaServerArgs_DraftMTP(t *testing.T) {
	sa := ServerArgs{
		BinPath:    "/nix/store/abc/bin/llama-server",
		ModelPath:  "/tmp/model.gguf",
		Port:       18080,
		Device:     "Vulkan0",
		SpecType:   "draft-mtp",
		NGL:        99,
		Ctx:        4096,
	}
	args := BuildLlamaServerArgs(sa)

	if args[0] != sa.BinPath {
		t.Fatalf("args[0] = %q, want %q", args[0], sa.BinPath)
	}

	required := []struct{ flag, want string }{
		{"--model", "/tmp/model.gguf"},
		{"--port", "18080"},
		{"--host", "127.0.0.1"},
		{"--device", "Vulkan0"},
		{"--spec-type", "draft-mtp"},
		{"--n-gpu-layers", "99"},
		{"--ctx-size", "4096"},
		{"--parallel", "1"},
		{"--flash-attn", "on"},
		{"--spec-draft-n-max", "6"},
	}
	for _, r := range required {
		got, ok := flagValue(args, r.flag)
		if !ok {
			t.Errorf("flag %q missing from args", r.flag)
			continue
		}
		if got != r.want {
			t.Errorf("flag %q = %q, want %q", r.flag, got, r.want)
		}
	}
}

func TestBuildLlamaServerArgs_SpecTypeNone(t *testing.T) {
	sa := ServerArgs{
		BinPath:   "/usr/bin/llama-server",
		ModelPath: "/tmp/model.gguf",
		Port:      18080,
		Device:    "ROCm0",
		SpecType:  "none",
		NGL:       99,
		Ctx:       4096,
	}
	args := BuildLlamaServerArgs(sa)

	// --spec-type "none" must be present
	if v, ok := flagValue(args, "--spec-type"); !ok || v != "none" {
		t.Errorf("--spec-type: got %q %v, want none true", v, ok)
	}

	// --flash-attn on regardless of spec_type
	if v, ok := flagValue(args, "--flash-attn"); !ok || v != "on" {
		t.Errorf("--flash-attn: got %q %v, want on true", v, ok)
	}

	// --spec-draft-n-max must be absent for spec_type=none
	if _, ok := flagValue(args, "--spec-draft-n-max"); ok {
		t.Error("--spec-draft-n-max should be absent when spec_type=none")
	}
}

// TestResolveCtxSize covers the --ctx-size wiring: a positive request is
// honored, and <= 0 falls back to the 2048 default. RunMTPAB feeds this
// resolved value straight into ServerArgs.Ctx → "--ctx-size".
func TestResolveCtxSize(t *testing.T) {
	tests := []struct {
		name string
		in   int
		want int
	}{
		{"explicit 4096 honored", 4096, 4096},
		{"zero defaults to 2048", 0, 2048},
		{"negative defaults to 2048", -1, 2048},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := resolveCtxSize(tc.in); got != tc.want {
				t.Errorf("resolveCtxSize(%d) = %d, want %d", tc.in, got, tc.want)
			}
		})
	}
}

// TestBuildLlamaServerArgs_CtxSizeFlows confirms the resolved ctx size lands
// on the "--ctx-size" flag, end-to-end through the args builder.
func TestBuildLlamaServerArgs_CtxSizeFlows(t *testing.T) {
	for _, ctx := range []int{resolveCtxSize(4096), resolveCtxSize(0)} {
		args := BuildLlamaServerArgs(ServerArgs{
			BinPath:   "/usr/bin/llama-server",
			ModelPath: "/tmp/model.gguf",
			Port:      18080,
			Device:    "ROCm0",
			SpecType:  "none",
			NGL:       99,
			Ctx:       ctx,
		})
		want := "4096"
		if ctx == 2048 {
			want = "2048"
		}
		if v, ok := flagValue(args, "--ctx-size"); !ok || v != want {
			t.Errorf("--ctx-size for Ctx=%d: got %q %v, want %q true", ctx, v, ok, want)
		}
	}
}
