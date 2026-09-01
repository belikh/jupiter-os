// Package upstream adapts to provider APIs and runs the streaming walk:
// a bounded chain of endpoint attempts whose failover window stays open
// until the first content-bearing delta commits the response to the client.
package upstream

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"strings"
)

// SSEEvent is one parsed server-sent-event frame from a provider stream.
type SSEEvent struct {
	Data  string // the data field, with "data: " stripped
	Done  bool   // terminal [DONE] frame
	Named map[string]string
}

// parseSSE reads a byte stream of SSE frames. Invariants (fuzz-enforced):
// never panics on any input, never emits an empty non-terminal frame.
func parseSSE(r io.Reader, emit func(SSEEvent) error) error {
	br := bufio.NewReaderSize(r, 16*1024)
	for {
		line, err := br.ReadString('\n')
		if line != "" {
			trimmed := strings.TrimRight(line, "\r\n")
			if strings.HasPrefix(trimmed, "data:") {
				data := strings.TrimSpace(strings.TrimPrefix(trimmed, "data:"))
				if data == "" {
					// empty data frame: skip rather than emit an empty event
					if err == io.EOF {
						return nil
					}
					continue
				}
				if data == "[DONE]" {
					return emit(SSEEvent{Data: data, Done: true})
				}
				if err := emit(SSEEvent{Data: data}); err != nil {
					return err
				}
			}
			// non-data lines (event:, id:, comments, keepalives) are ignored
		}
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
	}
}

// delta carries the OpenAI streaming choice fields we care about.
type delta struct {
	Role      string `json:"role"`
	Content   string `json:"content"`
	ToolCalls any    `json:"tool_calls"`
}

// chunk is the OpenAI streaming chunk envelope.
type chunk struct {
	Choices []struct {
		Delta        delta  `json:"delta"`
		FinishReason string `json:"finish_reason"`
	} `json:"choices"`
	Error any `json:"error"`
}

// contentOf extracts the content-bearing text from a chunk's data payload.
// Returns ok=false for role-only chunks, pings, tool-call deltas without
// text, and non-chunk JSON.
func contentOf(data []byte) (text string, finish string, ok bool) {
	var c chunk
	if err := jsonUnmarshal(data, &c); err != nil {
		return "", "", false
	}
	if len(c.Choices) == 0 {
		return "", "", false
	}
	ch := c.Choices[0]
	if ch.FinishReason != "" && ch.FinishReason != "null" {
		return "", ch.FinishReason, false // terminal frame, no content
	}
	if ch.Delta.Content != "" {
		return ch.Delta.Content, "", true
	}
	return "", "", false
}

// jsonUnmarshal decodes one chunk payload. A thin var seam so the fuzz
// tests can exercise the parser exactly as the walk uses it.
var jsonUnmarshal = func(data []byte, v any) error { return json.Unmarshal(bytes.TrimSpace(data), v) }

// ContentOf is the exported content-bearing check the facade uses to
// assemble non-streaming responses.
func ContentOf(data string) (text, finish string, ok bool) {
	return contentOf([]byte(data))
}

// small helpers shared across the package (kept here to avoid an extra file)

func jsonMarshal(v any) ([]byte, error) { return json.Marshal(v) }

func bytesReader(b []byte) io.Reader { return bytes.NewReader(b) }

type errString string

func (e errString) Error() string { return string(e) }

func errf(format string, args ...any) error { return errString(fmt.Sprintf(format, args...)) }

func jsonDecodeBody(r io.Reader, v any) error {
	b, err := io.ReadAll(r)
	if err != nil {
		return err
	}
	return json.Unmarshal(b, v)
}

// readAllLimit reads up to n bytes (error bodies are bounded captures).
func readAllLimit(r io.Reader, n int64) ([]byte, error) {
	return io.ReadAll(io.LimitReader(r, n))
}
