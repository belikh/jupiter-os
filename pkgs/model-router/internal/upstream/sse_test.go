package upstream

import (
	"bufio"
	"bytes"
	"io"
	"strings"
	"testing"
)

func TestParseSSEEmitsDataFrames(t *testing.T) {
	in := "data: {\"a\":1}\n\ndata: [DONE]\n\n"
	var got []SSEEvent
	err := parseSSE(strings.NewReader(in), func(ev SSEEvent) error {
		got = append(got, ev)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("events = %d, want 2", len(got))
	}
	if got[0].Data != `{"a":1}` || got[1].Done != true {
		t.Fatalf("events wrong: %+v", got)
	}
}

func TestParseSSERoleOnlyChunkRelayedNotContent(t *testing.T) {
	frame := `data: {"choices":[{"delta":{"role":"assistant"},"finish_reason":null}]}`
	text, finish, ok := contentOf([]byte(frame))
	if ok {
		t.Fatalf("role-only chunk treated as content: %q", text)
	}
	if finish != "" {
		t.Fatalf("role-only chunk carried finish: %q", finish)
	}
}

func TestParseSSEContentChunkIsContent(t *testing.T) {
	frame := `{"choices":[{"delta":{"content":"Hello"},"finish_reason":null}]}`
	text, _, ok := contentOf([]byte(frame))
	if !ok || text != "Hello" {
		t.Fatalf("content chunk not detected: %q ok=%v", text, ok)
	}
}

func TestParseSSFTerminalFrameCarriesFinish(t *testing.T) {
	frame := `{"choices":[{"delta":{},"finish_reason":"stop"}]}`
	_, finish, ok := contentOf([]byte(frame))
	if ok {
		t.Fatal("terminal frame must not be content")
	}
	if finish != "stop" {
		t.Fatalf("finish = %q, want stop", finish)
	}
}

func TestParseSSEEmptyDataSkipped(t *testing.T) {
	in := "data: \n\ndata: [DONE]\n"
	var got []SSEEvent
	if err := parseSSE(strings.NewReader(in), func(ev SSEEvent) error {
		got = append(got, ev)
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || !got[0].Done {
		t.Fatalf("empty data frame must be skipped, got %+v", got)
	}
}

func TestParseSSEIgnoresCommentsAndFields(t *testing.T) {
	in := ": keepalive\nevent: ping\nid: 42\ndata: {\"x\":1}\n\n"
	var got []SSEEvent
	if err := parseSSE(strings.NewReader(in), func(ev SSEEvent) error {
		got = append(got, ev)
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].Data != `{"x":1}` {
		t.Fatalf("comments/fields leaked: %+v", got)
	}
}

func TestParseSSETruncatedStream(t *testing.T) {
	// a provider death mid-frame: no trailing newline, no [DONE]
	in := "data: {\"choices\":[{\"delta\":{\"cont"
	var got []SSEEvent
	if err := parseSSE(strings.NewReader(in), func(ev SSEEvent) error {
		got = append(got, ev)
		return nil
	}); err != nil {
		t.Fatalf("truncated stream must not error the parser: %v", err)
	}
	if len(got) != 1 || got[0].Data != `{"choices":[{"delta":{"cont` {
		// the partial frame IS emitted as data — the walk's watchdog
		// decides what to do with it; the parser only refuses to lie
		t.Fatalf("partial frame handling: %+v", got)
	}
}

func TestParseSSECRLF(t *testing.T) {
	in := "data: {\"a\":1}\r\n\r\ndata: [DONE]\r\n\r\n"
	var got []SSEEvent
	if err := parseSSE(strings.NewReader(in), func(ev SSEEvent) error {
		got = append(got, ev)
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("CRLF stream mishandled: %+v", got)
	}
}

// FuzzParseSSE enforces the parser invariants: never panic on ANY input,
// never emit an empty non-terminal event.
func FuzzParseSSE(f *testing.F) {
	f.Add([]byte("data: {\"a\":1}\n\n"))
	f.Add([]byte("data: \n\n"))
	f.Add([]byte("\x00\x01\x02garbage"))
	f.Add([]byte("data: [DONE]"))
	f.Add([]byte("event: x\n"))
	f.Add([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n"))
	f.Fuzz(func(t *testing.T, in []byte) {
		var got []SSEEvent
		_ = parseSSE(bytes.NewReader(in), func(ev SSEEvent) error {
			got = append(got, ev)
			if !ev.Done && strings.TrimSpace(ev.Data) == "" {
				t.Fatalf("empty non-terminal event emitted for %q", in)
			}
			return nil
		})
	})
}

// guard the imports used only in some tests
var _ = bufio.NewReader
var _ io.Reader = nil
