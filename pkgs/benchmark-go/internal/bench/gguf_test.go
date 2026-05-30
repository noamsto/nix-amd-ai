package bench

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// --- resolveHFCacheRoot tests ---

func TestResolveHFCacheRoot_HFHubCache(t *testing.T) {
	// HF_HUB_CACHE takes top precedence, returned as-is.
	env := func(k string) string {
		if k == "HF_HUB_CACHE" {
			return "/custom/hub/cache"
		}
		return ""
	}
	got := resolveHFCacheRoot(env, 0, nil, nil)
	want := "/custom/hub/cache"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestResolveHFCacheRoot_HFHome(t *testing.T) {
	// HF_HOME present, HF_HUB_CACHE absent → join with "hub".
	env := func(k string) string {
		if k == "HF_HOME" {
			return "/custom/hf"
		}
		return ""
	}
	got := resolveHFCacheRoot(env, 0, nil, nil)
	want := filepath.Join("/custom/hf", "hub")
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestResolveHFCacheRoot_SudoUser(t *testing.T) {
	// euid==0, SUDO_USER=alice, lookupHome succeeds → alice's cache.
	env := func(k string) string {
		if k == "SUDO_USER" {
			return "alice"
		}
		return ""
	}
	lookupHome := func(u string) (string, error) {
		if u == "alice" {
			return "/home/alice", nil
		}
		return "", errors.New("not found")
	}
	got := resolveHFCacheRoot(env, 0, lookupHome, nil)
	want := "/home/alice/.cache/huggingface/hub"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestResolveHFCacheRoot_SudoUserLookupFails(t *testing.T) {
	// euid==0, SUDO_USER=alice, lookupHome fails → fall back to /home/alice.
	env := func(k string) string {
		if k == "SUDO_USER" {
			return "alice"
		}
		return ""
	}
	lookupHome := func(_ string) (string, error) {
		return "", errors.New("no passwd entry")
	}
	got := resolveHFCacheRoot(env, 0, lookupHome, nil)
	want := "/home/alice/.cache/huggingface/hub"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestResolveHFCacheRoot_SudoUserIsRoot(t *testing.T) {
	// euid==0 but SUDO_USER=root (real root, not a sudo invocation) → userHome path.
	env := func(k string) string {
		if k == "SUDO_USER" {
			return "root"
		}
		return ""
	}
	userHome := func() (string, error) { return "/root", nil }
	got := resolveHFCacheRoot(env, 0, nil, userHome)
	want := "/root/.cache/huggingface/hub"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestResolveHFCacheRoot_SudoUserUnset(t *testing.T) {
	// euid==0 but SUDO_USER unset → userHome path.
	env := func(_ string) string { return "" }
	userHome := func() (string, error) { return "/root", nil }
	got := resolveHFCacheRoot(env, 0, nil, userHome)
	want := "/root/.cache/huggingface/hub"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestResolveHFCacheRoot_NormalUser(t *testing.T) {
	// euid != 0 → userHome path regardless of SUDO_USER.
	env := func(k string) string {
		if k == "SUDO_USER" {
			return "alice"
		}
		return ""
	}
	userHome := func() (string, error) { return "/home/bob", nil }
	got := resolveHFCacheRoot(env, 1000, nil, userHome)
	want := "/home/bob/.cache/huggingface/hub"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

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

func TestResolveGGUFByCheckpoint_OnlyMmproj(t *testing.T) {
	// Realistic partial-download state: snapshot has only an mmproj projection
	// file, no model shard → resolver returns "" (mmproj excluded + len==0 guard).
	// Case-insensitive: an uppercase MMproj must also be excluded.
	root := t.TempDir()
	dir := filepath.Join(root, "models--unsloth--gemma-4-26B-A4B-it-GGUF", "snapshots", "rev1")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"mmproj-F16.gguf", "MMproj-BF16.gguf"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte{}, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	got := ResolveGGUFByCheckpoint("unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q4_K_M", root)
	if got != "" {
		t.Errorf("got %q, want empty (only mmproj files present)", got)
	}
}

func TestResolveGGUFByCheckpoint_TagNoMatch(t *testing.T) {
	// A real .gguf exists but the variant tag matches no filename → "".
	root := t.TempDir()
	dir := filepath.Join(root, "models--unsloth--TestRepo-GGUF", "snapshots", "rev1")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "TestModel-UD-Q4_K_M.gguf"), []byte{}, 0o644); err != nil {
		t.Fatal(err)
	}
	got := ResolveGGUFByCheckpoint("unsloth/TestRepo-GGUF:UD-Q8_0", root)
	if got != "" {
		t.Errorf("got %q, want empty (variant tag UD-Q8_0 matches no file)", got)
	}
}

func TestResolveGGUFByCheckpoint_MultiSlashRepo(t *testing.T) {
	// A repo part containing a further "/" (checkpoint "a/b/c") is rejected
	// rather than building a path that descends into a subdir.
	got := ResolveGGUFByCheckpoint("a/b/c", t.TempDir())
	if got != "" {
		t.Errorf("got %q, want empty for multi-slash checkpoint", got)
	}
}
