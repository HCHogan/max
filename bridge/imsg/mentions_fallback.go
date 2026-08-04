//go:build !darwin || !cgo

package main

// Non-macOS builders cannot load Foundation's attributed-string archive.
// Keep confirmed identities for trigger compatibility, but deliberately omit
// text ranges rather than guessing where a display label occurs.
func decodeMentionSpans(body []byte) []mentionSpan {
	handles := confirmedMentionHandles(body)
	spans := make([]mentionSpan, 0, len(handles))
	for _, handle := range handles {
		spans = append(spans, mentionSpan{Handle: handle, UTF16Location: -1})
	}
	return spans
}
