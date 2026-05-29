package bench

import "strings"

// mtpPromptBase is a fixed passage of well-known opening lines used for MTP
// measurement. Synthetic "The " repetition produces unstable draft acceptance
// rates; this naturalistic prose gives the MTP draft head something realistic.
const mtpPromptBase = ("The quick brown fox jumps over the lazy dog. " +
	"It was a bright cold day in April, and the clocks were " +
	"striking thirteen. " +
	"All happy families are alike; each unhappy family is " +
	"unhappy in its own way. " +
	"In the beginning the Universe was created. This has made " +
	"a lot of people very angry and been widely regarded as a " +
	"bad move. " +
	"Many years later, as he faced the firing squad, Colonel " +
	"Aureliano Buendia was to remember that distant afternoon " +
	"when his father took him to discover ice. " +
	"It is a truth universally acknowledged, that a single man " +
	"in possession of a good fortune, must be in want of a wife. " +
	"Call me Ishmael. Some years ago - never mind how long " +
	"precisely - having little or no money in my purse, and " +
	"nothing particular to interest me on shore, I thought I " +
	"would sail about a little and see the watery part of the " +
	"world. " +
	"Mr and Mrs Dursley, of number four, Privet Drive, were " +
	"proud to say that they were perfectly normal, thank you " +
	"very much. ")

// MTPPromptBase returns the fixed naturalistic passage used by BuildMTPPrompt.
// Exported for testing.
func MTPPromptBase() string { return mtpPromptBase }

// BuildPrompt builds a rough prompt of approximately promptTokens tokens by
// repeating "The ", matching Python's build_prompt.
func BuildPrompt(promptTokens int) string {
	return strings.Repeat("The ", promptTokens)
}

// BuildMTPPrompt builds a naturalistic prompt of approximately promptTokens
// tokens by repeating mtpPromptBase until the character target is met.
// Target chars = promptTokens * 4 (~3.5 chars/token on English text).
// Matches Python's build_mtp_prompt exactly.
func BuildMTPPrompt(promptTokens int) string {
	targetChars := promptTokens * 4
	var b strings.Builder
	b.Grow(targetChars)
	for b.Len() < targetChars {
		b.WriteString(mtpPromptBase)
	}
	return b.String()[:targetChars]
}
