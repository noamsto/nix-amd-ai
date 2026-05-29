package bench

import (
	"strings"
	"testing"
)

func TestBuildPrompt(t *testing.T) {
	t.Run("zero", func(t *testing.T) {
		p := BuildPrompt(0)
		if p != "" {
			t.Errorf("got %q, want empty string", p)
		}
	})

	t.Run("one", func(t *testing.T) {
		p := BuildPrompt(1)
		if p != "The " {
			t.Errorf("got %q, want %q", p, "The ")
		}
	})

	t.Run("three", func(t *testing.T) {
		p := BuildPrompt(3)
		if p != "The The The " {
			t.Errorf("got %q, want %q", p, "The The The ")
		}
	})

	t.Run("repeats_the_exactly", func(t *testing.T) {
		p := BuildPrompt(5)
		parts := strings.SplitAfter(p, "The ")
		// SplitAfter on "The " for "The The The The The " gives ["The ", "The ", "The ", "The ", "The ", ""]
		// so len-1 parts before trailing empty = 5
		count := 0
		for _, part := range parts {
			if part == "The " {
				count++
			}
		}
		if count != 5 {
			t.Errorf("expected 5 'The ' repetitions, got %d in %q", count, p)
		}
	})
}

func TestBuildMTPPrompt(t *testing.T) {
	t.Run("length_is_prompt_tokens_times_4", func(t *testing.T) {
		for _, n := range []int{1, 10, 100, 512} {
			p := BuildMTPPrompt(n)
			want := n * 4
			if len(p) != want {
				t.Errorf("n=%d: got len %d, want %d", n, len(p), want)
			}
		}
	})

	t.Run("content_is_prefix_of_repeated_base", func(t *testing.T) {
		// For small n, the result must be a prefix of MTPPromptBase repeated
		n := 10
		p := BuildMTPPrompt(n)
		target := n * 4 // 40 chars
		// Build expected by repeating base until >= target, then cut
		base := MTPPromptBase()
		full := ""
		for len(full) < target {
			full += base
		}
		expected := full[:target]
		if p != expected {
			t.Errorf("got %q, want %q", p, expected)
		}
	})

	t.Run("starts_with_known_prefix", func(t *testing.T) {
		p := BuildMTPPrompt(100)
		// The passage starts with "The quick brown fox..."
		if !strings.HasPrefix(p, "The quick brown fox") {
			t.Errorf("expected MTP prompt to start with 'The quick brown fox', got prefix: %q", p[:min(30, len(p))])
		}
	})
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
