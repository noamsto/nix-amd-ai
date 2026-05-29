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
