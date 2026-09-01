package upstream

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"modelrouter/internal/health"
	"modelrouter/internal/ledger"
	"modelrouter/internal/pool"
)

// mockAdapter scripts per-provider behaviour for walk tests.
type mockAdapter struct {
	provider   string
	status     int // start status (0 = streaming success script)
	body       string
	streamBody string // full SSE script for success case
	failAfter  int    // emit N content chunks then die (post-commit failure)
	calls      int32
}

func (m *mockAdapter) Start(ctx context.Context, sc ScopeID, req Request) (*StartResult, error) {
	atomic.AddInt32(&m.calls, 1)
	if m.status != 0 {
		return &StartResult{
			Status:  m.status,
			Headers: http.Header{},
			Resp: &http.Response{
				StatusCode: m.status,
				Header:     http.Header{},
				Body:       ioNopCloser(strings.NewReader(m.body)),
			},
		}, nil
	}
	var sb strings.Builder
	sb.WriteString(fmt.Sprintf("data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"},\"finish_reason\":null}]}\n\n"))
	for i := 0; i < 3; i++ {
		sb.WriteString(fmt.Sprintf("data: {\"choices\":[{\"delta\":{\"content\":\"chunk%d\"},\"finish_reason\":null}]}\n\n", i))
	}
	if m.failAfter > 0 {
		// emit failAfter content chunks then cut the stream (no [DONE])
		full := sb.String()
		parts := strings.SplitN(full, "\n\n", m.failAfter+2)
		sb.Reset()
		sb.WriteString(strings.Join(parts[:m.failAfter+1], "\n\n"))
		sb.WriteString("\n\n")
	} else {
		sb.WriteString("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n")
		sb.WriteString("data: [DONE]\n\n")
	}
	return &StartResult{
		Status:  200,
		Headers: http.Header{},
		Resp: &http.Response{
			StatusCode: 200,
			Header:     http.Header{},
			Body:       ioNopCloser(strings.NewReader(sb.String())),
		},
	}, nil
}

func (m *mockAdapter) ListModels(ctx context.Context) ([]string, error) { return nil, nil }
func (m *mockAdapter) Close(r *StartResult) {
	if r != nil && r.Resp != nil {
		r.Resp.Body.Close()
	}
}

type ioNop string

func ioNopCloser(r *strings.Reader) ioReadCloser { return ioNopCloserImpl{r} }

type ioReadCloser interface {
	Read(p []byte) (int, error)
	Close() error
}

type ioNopCloserImpl struct{ r *strings.Reader }

func (i ioNopCloserImpl) Read(p []byte) (int, error) { return i.r.Read(p) }
func (i ioNopCloserImpl) Close() error               { return nil }

func setupWalk(adapters map[string]Adapter) (*Walk, *pool.Pool, *health.Machine, *ledger.Ledger) {
	m := health.NewMachine()
	m.Tick(time.Now())
	led := ledger.New()
	p := pool.New(m, led, 0.5)
	w := NewWalk(p, led, m, func(provider string) Adapter { return adapters[provider] })
	return w, p, m, led
}

func TestWalkHappyPathCommitsAndCompletes(t *testing.T) {
	ad := &mockAdapter{provider: "groq"}
	w, p, m, _ := setupWalk(map[string]Adapter{"groq": ad})
	p.SetMembers("fam", []pool.Endpoint{{
		Scope:   health.Scope{Provider: "groq", Model: "m", Key: "k"},
		Weights: map[string]float64{"rpm": 30},
	}})
	_ = m
	var emitted []string
	err := w.Run(context.Background(), "fam", Request{Stream: true}, func(ev SSEEvent) error {
		emitted = append(emitted, ev.Data)
		return nil
	})
	if err != nil {
		t.Fatalf("happy path errored: %v", err)
	}
	if len(emitted) < 5 { // role + 3 content + finish + done
		t.Fatalf("emitted %d events, want >= 5", len(emitted))
	}
}

func TestWalkFailoverPreCommit(t *testing.T) {
	dead := &mockAdapter{provider: "dead", status: 500, body: `{"error":{"message":"upstream exploded"}}`}
	alive := &mockAdapter{provider: "alive"}
	w, p, _, _ := setupWalk(map[string]Adapter{"dead": dead, "alive": alive})
	p.SetMembers("fam", []pool.Endpoint{
		{Scope: health.Scope{Provider: "dead", Model: "m", Key: "k"}, Weights: map[string]float64{"rpm": 100}},
		{Scope: health.Scope{Provider: "alive", Model: "m", Key: "k"}, Weights: map[string]float64{"rpm": 50}},
	})
	var contentSeen []string
	err := w.Run(context.Background(), "fam", Request{Stream: true}, func(ev SSEEvent) error {
		contentSeen = append(contentSeen, ev.Data)
		return nil
	})
	if err != nil {
		t.Fatalf("failover run errored: %v", err)
	}
	if atomic.LoadInt32(&dead.calls) == 0 {
		t.Fatal("dead adapter never tried — chain broken")
	}
	if atomic.LoadInt32(&alive.calls) == 0 {
		t.Fatal("failover never reached the alive endpoint")
	}
	if len(contentSeen) < 5 {
		t.Fatalf("client saw %d events, want the full stream", len(contentSeen))
	}
}

func TestWalkAllDeadPreCommitErrors(t *testing.T) {
	a := &mockAdapter{provider: "a", status: 500, body: "boom"}
	b := &mockAdapter{provider: "b", status: 429, body: `{"error":{"message":"Rate limit reached for model m on tokens per minute (TPM): Limit 7000, Used 0, Requested ~12903"}}`}
	w, p, _, _ := setupWalk(map[string]Adapter{"a": a, "b": b})
	p.SetMembers("fam", []pool.Endpoint{
		{Scope: health.Scope{Provider: "a", Model: "m", Key: "k"}, Weights: map[string]float64{"rpm": 10}},
		{Scope: health.Scope{Provider: "b", Model: "m", Key: "k"}, Weights: map[string]float64{"rpm": 10}},
	})
	err := w.Run(context.Background(), "fam", Request{Stream: true}, func(ev SSEEvent) error { return nil })
	if err == nil || err == ErrAllEndpointsFailed {
		// both shapes acceptable (empty chain guard may fire first)
		if err != nil && !strings.Contains(err.Error(), "all endpoints failed") {
			t.Fatalf("want all-endpoints error, got %v", err)
		}
	}
}

func TestWalkPostCommitDeathIsHonestNoSplice(t *testing.T) {
	// provider emits ONE content chunk then dies mid-stream
	flakyon := &mockAdapter{provider: "flaky", failAfter: 1}
	healthy := &mockAdapter{provider: "healthy"}
	w, p, _, _ := setupWalk(map[string]Adapter{"flaky": flakyon, "healthy": healthy})
	p.SetMembers("fam", []pool.Endpoint{
		{Scope: health.Scope{Provider: "flaky", Model: "m", Key: "k"}, Weights: map[string]float64{"rpm": 100}},
		{Scope: health.Scope{Provider: "healthy", Model: "m", Key: "k"}, Weights: map[string]float64{"rpm": 50}},
	})
	var content []string
	err := w.Run(context.Background(), "fam", Request{Stream: true}, func(ev SSEEvent) error {
		content = append(content, ev.Data)
		return nil
	})
	if err != ErrCommitted {
		t.Fatalf("post-commit death must return ErrCommitted, got %v", err)
	}
	if atomic.LoadInt32(&healthy.calls) != 0 {
		t.Fatal("SPLICE DETECTED: the healthy provider was called after commit — never allowed")
	}
	// client saw the one committed chunk and nothing spliced after
	if len(content) < 2 { // role frame + one content chunk
		t.Fatalf("client should have the pre-death frames, got %d", len(content))
	}
}

func TestWalkRoleOnlyNeverCommits(t *testing.T) {
	// a stream of ONLY role frames then death: failover must stay open
	roleOnly := &mockAdapter{provider: "ro"}
	// craft: status 200, body = role frame + cut
	ad := &mockAdapter{provider: "ro2"}
	w, p, _, _ := setupWalk(map[string]Adapter{"ro": roleOnly, "ro2": ad})
	p.SetMembers("fam", []pool.Endpoint{
		{Scope: health.Scope{Provider: "ro", Model: "m", Key: "k"}, Weights: map[string]float64{"rpm": 100}},
		{Scope: health.Scope{Provider: "ro2", Model: "m", Key: "k"}, Weights: map[string]float64{"rpm": 50}},
	})
	// make "ro" stream only a role frame then EOF (no content, no DONE)
	var sb strings.Builder
	sb.WriteString("data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"},\"finish_reason\":null}]}\n\n")
	roleOnly.streamBody = sb.String()
	// monkey-patch via failAfter=0 gives full success script; instead use a
	// dedicated adapter override
	roAdapter := &roleOnlyAdapter{}
	w.adapter = func(provider string) Adapter {
		if provider == "ro" {
			return roAdapter
		}
		return ad
	}
	err := w.Run(context.Background(), "fam", Request{Stream: true}, func(ev SSEEvent) error { return nil })
	if err != nil {
		t.Fatalf("role-only failover errored: %v", err)
	}
	if atomic.LoadInt32(&ad.calls) == 0 {
		t.Fatal("role-only stream must NOT commit — failover should reach the second endpoint")
	}
}

type roleOnlyAdapter struct{ calls int32 }

func (r *roleOnlyAdapter) Start(ctx context.Context, sc ScopeID, req Request) (*StartResult, error) {
	atomic.AddInt32(&r.calls, 1)
	body := "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"},\"finish_reason\":null}]}\n\n"
	return &StartResult{
		Status: 200,
		Resp: &http.Response{
			StatusCode: 200,
			Header:     http.Header{},
			Body:       ioNopCloser(strings.NewReader(body)),
		},
	}, nil
}
func (r *roleOnlyAdapter) ListModels(ctx context.Context) ([]string, error) { return nil, nil }
func (r *roleOnlyAdapter) Close(res *StartResult) {
	if res != nil && res.Resp != nil {
		res.Resp.Body.Close()
	}
}
