package facade

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"modelrouter/internal/health"
	"modelrouter/internal/ledger"
	"modelrouter/internal/pool"
	"modelrouter/internal/upstream"
)

// stub walk adapter: one healthy endpoint that streams a full answer
type walkFixture struct {
	walk  *upstream.Walk
	pools *pool.Pool
}

func newFixture() *walkFixture {
	m := health.NewMachine()
	led := ledger.New()
	p := pool.New(m, led, 0.5)
	adapters := map[string]upstream.Adapter{
		"groq": &stubAdapter{},
	}
	w := upstream.NewWalk(p, led, m, func(provider string) upstream.Adapter {
		return adapters[provider]
	})
	p.SetMembers("glm-4x-flash", []pool.Endpoint{{
		Scope:   health.Scope{Provider: "groq", Model: "glm-4x-flash", Key: "k"},
		Weights: map[string]float64{"rpm": 30},
	}})
	return &walkFixture{walk: w, pools: p}
}

type stubAdapter struct{ calls int32 }

func (s *stubAdapter) Start(ctx context.Context, sc upstream.ScopeID, req upstream.Request) (*upstream.StartResult, error) {
	frames := []string{
		`data: {"choices":[{"delta":{"role":"assistant"},"finish_reason":null}]}`,
		`data: {"choices":[{"delta":{"content":"Hello"},"finish_reason":null}]}`,
		`data: {"choices":[{"delta":{},"finish_reason":"stop"}]}`,
		`data: [DONE]`,
	}
	body := strings.Join(frames, "\n\n") + "\n\n"
	return &upstream.StartResult{
		Status: 200,
		Resp: &http.Response{
			StatusCode: 200,
			Header:     http.Header{},
			Body:       io.NopCloser(strings.NewReader(body)),
		},
	}, nil
}

func (s *stubAdapter) ListModels(ctx context.Context) ([]string, error) { return nil, nil }
func (s *stubAdapter) Close(r *upstream.StartResult) {
	if r != nil && r.Resp != nil {
		r.Resp.Body.Close()
	}
}

func TestAuthRejectsWrongBearer(t *testing.T) {
	f := newFixture()
	srv := NewServer("secret-token", f.walk, nil, func() []string { return []string{"glm-4x-flash"} })
	ts := httptest.NewServer(srv.Mux())
	defer ts.Close()

	resp, err := http.Post(ts.URL+"/v1/chat/completions", "application/json",
		strings.NewReader(`{"model":"glm-4x-flash","messages":[{"role":"user","content":"hi"}]}`))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 401 {
		t.Fatalf("no-token status = %d, want 401", resp.StatusCode)
	}
	var body map[string]any
	json.NewDecoder(resp.Body).Decode(&body)
	if body["error"].(map[string]any)["code"] != "invalid_api_key" {
		t.Fatalf("error envelope wrong: %v", body)
	}
}

func TestModelsListingFromLivePools(t *testing.T) {
	f := newFixture()
	srv := NewServer("tok", f.walk, nil, func() []string { return []string{"glm-4x-flash", "kimi-k3"} })
	ts := httptest.NewServer(srv.Mux())
	defer ts.Close()

	req, _ := http.NewRequest("GET", ts.URL+"/v1/models", nil)
	req.Header.Set("Authorization", "Bearer tok")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out struct {
		Data []struct{ ID string } `json:"data"`
	}
	json.NewDecoder(resp.Body).Decode(&out)
	if len(out.Data) != 2 || out.Data[0].ID != "glm-4x-flash" {
		t.Fatalf("models = %+v", out.Data)
	}
}

func TestChatCompletionStreamingEndToEnd(t *testing.T) {
	f := newFixture()
	srv := NewServer("tok", f.walk, nil, func() []string { return []string{"glm-4x-flash"} })
	ts := httptest.NewServer(srv.Mux())
	defer ts.Close()

	req, _ := http.NewRequest("POST", ts.URL+"/v1/chat/completions", bytes.NewReader(
		[]byte(`{"model":"glm-4x-flash","stream":true,"messages":[{"role":"user","content":"hi"}]}`)))
	req.Header.Set("Authorization", "Bearer tok")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("status = %d", resp.StatusCode)
	}
	if ct := resp.Header.Get("Content-Type"); !strings.Contains(ct, "text/event-stream") {
		t.Fatalf("content-type = %q", ct)
	}
	body, _ := io.ReadAll(resp.Body)
	s := string(body)
	if !strings.Contains(s, "data: ") {
		t.Fatalf("no SSE frames: %q", s[:min(120, len(s))])
	}
	if !strings.Contains(s, "[DONE]") {
		t.Fatal("stream must end with [DONE]")
	}
}

func TestMapFinishEnum(t *testing.T) {
	// legal values pass through
	for _, legal := range []string{"stop", "length", "tool_calls", "content_filter", "function_call"} {
		if got := mapFinish(legal); got != legal {
			t.Errorf("mapFinish(%q) = %q, want passthrough", legal, got)
		}
	}
	// illegal values map to the nearest legal
	if got := mapFinish("error"); got != "stop" {
		t.Errorf("error -> %q, want stop", got)
	}
	if got := mapFinish("max_output_tokens"); got != "length" {
		t.Errorf("max_output_tokens -> %q, want length", got)
	}
	if got := mapFinish("malformed_function_call"); got != "stop" {
		t.Errorf("malformed_function_call -> %q, want stop", got)
	}
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
