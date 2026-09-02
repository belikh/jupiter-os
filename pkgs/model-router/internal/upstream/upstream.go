package upstream

import (
	"context"
	"net/http"
	"time"
)

// Request is the router's internal chat request (OpenAI-shaped).
type Request struct {
	Model    string           `json:"model"`
	Messages []map[string]any `json:"messages"`
	Stream   bool             `json:"stream"`
	Extra    map[string]any   `json:"-"`
}

// StartResult is what an adapter returns when a request is accepted: the
// HTTP response whose body is the (possibly streaming) SSE or JSON payload.
type StartResult struct {
	Resp    *http.Response
	Status  int
	Body    []byte // non-streaming: full body; streaming: read via Resp
	Headers http.Header
}

// Adapter starts a chat completion against one endpoint. Start returning
// an error or a non-2xx result leaves the walk's failover window open;
// success closes only when content actually flows (the commit rule).
type Adapter interface {
	Start(ctx context.Context, sc ScopeID, req Request) (*StartResult, error)
	// ListModels returns the provider's live catalogue (discovery).
	ListModels(ctx context.Context) ([]string, error)
	// Close releases the response body.
	Close(r *StartResult)
}

// ScopeID identifies the endpoint the adapter should call (base URL, key,
// and the provider-local model id come from the pool's endpoint record).
type ScopeID struct {
	Provider string
	Model    string // provider-local slug
	Key      string
}

// httpClient is shared per-adapter; the transport tuning matters (the
// corpus's GPT-Load table): generous response-header timeout for long
// prefill, pooled connections per host.
func newHTTPClient() *http.Client {
	tr := &http.Transport{
		MaxIdleConns:          100,
		MaxIdleConnsPerHost:   10,
		IdleConnTimeout:       90 * time.Second,
		ResponseHeaderTimeout: 120 * time.Second, // long prefill tolerance
	}
	return &http.Client{Transport: tr}
}

// OpenAIAdapter is the generic adapter for OpenAI-compatible providers
// (the ~95% case: OpenRouter, Groq, NIM, HF router, Cerebras, Mistral,
// Ollama, Together, Chutes, OVH, SiliconFlow, ModelScope).
type OpenAIAdapter struct {
	BaseURL string
	// APIKey resolves the bearer token for one key alias (vault-backed;
	// nil-safe; empty string means "no key for this alias").
	APIKey func(alias string) string
	Client *http.Client
}

func NewOpenAIAdapter(baseURL string, keyFn func(alias string) string) *OpenAIAdapter {
	return &OpenAIAdapter{BaseURL: baseURL, APIKey: keyFn, Client: newHTTPClient()}
}

func (a *OpenAIAdapter) Start(ctx context.Context, sc ScopeID, req Request) (*StartResult, error) {
	payload := map[string]any{
		"model":    sc.Model,
		"messages": req.Messages,
		"stream":   req.Stream,
	}
	for k, v := range req.Extra {
		payload[k] = v
	}
	body, err := jsonMarshal(payload)
	if err != nil {
		return nil, err
	}
	hreq, err := http.NewRequestWithContext(ctx, "POST", a.BaseURL+"/chat/completions", bytesReader(body))
	if err != nil {
		return nil, err
	}
	hreq.Header.Set("Content-Type", "application/json")
	// identity encoding: we parse error bodies ourselves and never want
	// opaque gzip in the classification path (the corpus's CLIProxyAPI
	// lesson)
	hreq.Header.Set("Accept-Encoding", "identity")
	if a.APIKey != nil {
		if k := a.APIKey(sc.Key); k != "" {
			hreq.Header.Set("Authorization", "Bearer "+k)
		}
	}
	resp, err := a.Client.Do(hreq)
	if err != nil {
		return nil, err
	}
	return &StartResult{Resp: resp, Status: resp.StatusCode, Headers: resp.Header}, nil
}

func (a *OpenAIAdapter) ListModels(ctx context.Context) ([]string, error) {
	hreq, err := http.NewRequestWithContext(ctx, "GET", a.BaseURL+"/models", nil)
	if err != nil {
		return nil, err
	}
	if a.APIKey != nil {
		// ListModels is alias-agnostic: probe with the provider's
		// first usable key (empty string when the vault is empty —
		// keyless endpoints like NIM answer anyway).
		if k := a.APIKey(""); k != "" {
			hreq.Header.Set("Authorization", "Bearer "+k)
		}
	}
	resp, err := a.Client.Do(hreq)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, errf("list models: status %d", resp.StatusCode)
	}
	var out struct {
		Data []struct {
			ID string `json:"id"`
		} `json:"data"`
	}
	if err := jsonDecodeBody(resp.Body, &out); err != nil {
		return nil, err
	}
	ids := make([]string, 0, len(out.Data))
	for _, m := range out.Data {
		ids = append(ids, m.ID)
	}
	return ids, nil
}

func (a *OpenAIAdapter) Close(r *StartResult) {
	if r != nil && r.Resp != nil && r.Resp.Body != nil {
		r.Resp.Body.Close()
	}
}
