package bench

import (
	"os"
	"path/filepath"
	"testing"
)

func TestResolveLemonadeGGUF_MissingCacheRoot(t *testing.T) {
	tmp := t.TempDir()
	result := ResolveLemonadeGGUF("Qwen3.6-27B-MTP-GGUF", filepath.Join(tmp, "nonexistent"))
	if result != "" {
		t.Fatalf("expected empty string, got %q", result)
	}
}

func TestResolveLemonadeGGUF_ModelDirMissing(t *testing.T) {
	tmp := t.TempDir()
	result := ResolveLemonadeGGUF("Qwen3.6-27B-MTP-GGUF", tmp)
	if result != "" {
		t.Fatalf("expected empty string, got %q", result)
	}
}

func TestResolveLemonadeGGUF_NoGGUFInMatchedDir(t *testing.T) {
	tmp := t.TempDir()
	dir := filepath.Join(tmp, "models--unsloth--Qwen3.6-27B-MTP-GGUF", "snapshots", "abc")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "config.json"), []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}
	result := ResolveLemonadeGGUF("Qwen3.6-27B-MTP-GGUF", tmp)
	if result != "" {
		t.Fatalf("expected empty string, got %q", result)
	}
}

func TestResolveLemonadeGGUF_FindsGGUF(t *testing.T) {
	tmp := t.TempDir()
	snapshotDir := filepath.Join(tmp, "models--unsloth--Qwen3.6-27B-MTP-GGUF", "snapshots", "abc")
	if err := os.MkdirAll(snapshotDir, 0o755); err != nil {
		t.Fatal(err)
	}
	ggufPath := filepath.Join(snapshotDir, "Qwen3.6-27B-UD-Q4_K_XL.gguf")
	if err := os.WriteFile(ggufPath, []byte{}, 0o644); err != nil {
		t.Fatal(err)
	}
	result := ResolveLemonadeGGUF("Qwen3.6-27B-MTP-GGUF", tmp)
	if result != ggufPath {
		t.Fatalf("got %q, want %q", result, ggufPath)
	}
}

func TestResolveLemonadeGGUF_IgnoresOtherModels(t *testing.T) {
	tmp := t.TempDir()
	otherDir := filepath.Join(tmp, "models--unsloth--SomeOtherModel-GGUF", "snapshots", "def")
	if err := os.MkdirAll(otherDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(otherDir, "irrelevant.gguf"), []byte{}, 0o644); err != nil {
		t.Fatal(err)
	}
	result := ResolveLemonadeGGUF("Qwen3.6-27B-MTP-GGUF", tmp)
	if result != "" {
		t.Fatalf("expected empty string, got %q", result)
	}
}

func TestResolveLemonadeGGUF_IgnoresMalformedDirs(t *testing.T) {
	tmp := t.TempDir()
	// models--malformed yields only 2 parts under SplitN(name, "--", 3),
	// so it fails the len(parts) != 3 check and is ignored
	if err := os.MkdirAll(filepath.Join(tmp, "models--malformed"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(tmp, "tmp_dir"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(tmp, "version.txt"), []byte("1"), 0o644); err != nil {
		t.Fatal(err)
	}
	result := ResolveLemonadeGGUF("Qwen3.6-27B-MTP-GGUF", tmp)
	if result != "" {
		t.Fatalf("expected empty string, got %q", result)
	}
}

func TestResolveLemonadeGGUF_LexFirstGGUF(t *testing.T) {
	tmp := t.TempDir()
	snapshotDir := filepath.Join(tmp, "models--unsloth--TestModel-GGUF", "snapshots", "abc")
	if err := os.MkdirAll(snapshotDir, 0o755); err != nil {
		t.Fatal(err)
	}
	// Create multiple .gguf files; "a.gguf" is lexicographically first
	for _, name := range []string{"z.gguf", "a.gguf", "m.gguf"} {
		if err := os.WriteFile(filepath.Join(snapshotDir, name), []byte{}, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	result := ResolveLemonadeGGUF("TestModel-GGUF", tmp)
	want := filepath.Join(snapshotDir, "a.gguf")
	if result != want {
		t.Fatalf("got %q, want %q (lexicographically first)", result, want)
	}
}

// --- ResolveGGUFByCheckpoint tests ---

func makeGemmaCache(t *testing.T) (root, gemmaPath string) {
	t.Helper()
	root = t.TempDir()
	dir := filepath.Join(root, "models--unsloth--gemma-4-26B-A4B-it-GGUF", "snapshots", "rev1")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	gemmaPath = filepath.Join(dir, "gemma-4-26B-A4B-it-UD-Q4_K_M.gguf")
	for _, name := range []string{"gemma-4-26B-A4B-it-UD-Q4_K_M.gguf", "mmproj-F16.gguf"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte{}, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root, gemmaPath
}

func TestResolveGGUFByCheckpoint_QuantTag_ExcludesMmproj(t *testing.T) {
	// Gemma: checkpoint "unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q4_K_M" (quant tag variant)
	// Must return the gemma file, NOT mmproj-F16.gguf.
	root, gemmaPath := makeGemmaCache(t)
	got := ResolveGGUFByCheckpoint("unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q4_K_M", root)
	if got != gemmaPath {
		t.Errorf("got %q, want %q", got, gemmaPath)
	}
}

func TestResolveGGUFByCheckpoint_FullFilename(t *testing.T) {
	// Qwen: checkpoint variant is a full filename ending in .gguf
	root := t.TempDir()
	dir := filepath.Join(root, "models--unsloth--Qwen3.6-27B-MTP-GGUF", "snapshots", "rev1")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	qwenPath := filepath.Join(dir, "Qwen3.6-27B-UD-Q4_K_XL.gguf")
	for _, name := range []string{"Qwen3.6-27B-UD-Q4_K_XL.gguf", "mmproj-F16.gguf"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte{}, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	got := ResolveGGUFByCheckpoint("unsloth/Qwen3.6-27B-MTP-GGUF:Qwen3.6-27B-UD-Q4_K_XL.gguf", root)
	if got != qwenPath {
		t.Errorf("got %q, want %q", got, qwenPath)
	}
}

func TestResolveGGUFByCheckpoint_NoVariant(t *testing.T) {
	// No variant → return lexicographically first non-mmproj .gguf.
	root, gemmaPath := makeGemmaCache(t)
	got := ResolveGGUFByCheckpoint("unsloth/gemma-4-26B-A4B-it-GGUF", root)
	if got != gemmaPath {
		t.Errorf("got %q, want %q", got, gemmaPath)
	}
}

func TestResolveGGUFByCheckpoint_NotFound(t *testing.T) {
	root := t.TempDir()
	got := ResolveGGUFByCheckpoint("unsloth/nonexistent-GGUF:variant", root)
	if got != "" {
		t.Errorf("got %q, want empty", got)
	}
}

func TestResolveGGUFByCheckpoint_Empty(t *testing.T) {
	got := ResolveGGUFByCheckpoint("", "")
	if got != "" {
		t.Errorf("got %q, want empty for empty checkpoint", got)
	}
}

func TestResolveGGUFByCheckpoint_CaseInsensitiveVariantMatch(t *testing.T) {
	// The checkpoint owner/repo is case-exact in the cache dir, but variant matching is case-insensitive.
	root := t.TempDir()
	dir := filepath.Join(root, "models--unsloth--TestRepo-GGUF", "snapshots", "rev1")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	wantPath := filepath.Join(dir, "TestModel-UD-Q4_K_M.gguf")
	if err := os.WriteFile(wantPath, []byte{}, 0o644); err != nil {
		t.Fatal(err)
	}
	// Variant in different case from filename
	got := ResolveGGUFByCheckpoint("unsloth/TestRepo-GGUF:ud-q4_k_m", root)
	if got != wantPath {
		t.Errorf("got %q, want %q", got, wantPath)
	}
}
