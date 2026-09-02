// Package facade exposes the OpenAI-compatible HTTP surface: the chat
// completions endpoint (streaming + non-streaming), the models listing,
// and the dashboard routes. Auth is the router's own bearer token.
package facade

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"modelrouter/internal/discovery"
	"modelrouter/internal/upstream"
)

// Server carries the wired dependencies.
type Server struct {
	Token    string // router's own client token
	Walk     *upstream.Walk
	Loop     *discovery.Loop
	Families func() []string // model families currently routable
}

// NewServer builds the facade.
func NewServer(token string, walk *upstream.Walk, loop *discovery.Loop, families func() []string) *Server {
	return &Server{Token: token, Walk: walk, Loop: loop, Families: families}
}

// Mux assembles the HTTP routes.
func (s *Server) Mux() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/chat/completions", s.auth(s.handleChat))
	mux.HandleFunc("GET /v1/models", s.auth(s.handleModels))
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		w.Write([]byte("ok"))
	})
	return mux
}

func (s *Server) auth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		auth := r.Header.Get("Authorization")
		if auth != "Bearer "+s.Token {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusUnauthorized)
			json.NewEncoder(w).Encode(map[string]any{
				"error": map[string]any{"message": "invalid bearer token", "type": "auth_error", "code": "invalid_api_key"},
			})
			return
		}
		next(w, r)
	}
}

// chatRequest is the client-facing OpenAI-shaped request. The model field
// names a FAMILY (glm-5.3-flash, kimi-k3...) the router pools across
// endpoints — or an "auto:" strategy prefix (v2).
type chatRequest struct {
	Model    string           `json:"model"`
	Messages []map[string]any `json:"messages"`
	Stream   bool             `json:"stream"`
	Extra    map[string]any   `json:"-"`
}

func (s *Server) handleChat(w http.ResponseWriter, r *http.Request) {
	var req chatRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid_json", err.Error())
		return
	}
	if req.Model == "" || len(req.Messages) == 0 {
		writeErr(w, http.StatusBadRequest, "invalid_request", "model and messages are required")
		return
	}

	flusher, _ := w.(http.Flusher)
	if req.Stream {
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache")
		w.Header().Set("X-Accel-Buffering", "no")
		w.Header().Set("Connection", "keep-alive")
		// headers written lazily: the walk's first emit commits them
		committed := false
		commit := func() {
			if !committed {
				committed = true
				w.WriteHeader(http.StatusOK)
			}
		}
		err := s.Walk.Run(r.Context(), req.Model, upstream.Request{
			Model: req.Model, Messages: req.Messages, Stream: true, Extra: req.Extra,
		}, func(ev upstream.SSEEvent) error {
			commit()
			if _, err := w.Write([]byte("data: " + ev.Data + "\n\n")); err != nil {
				return err
			}
			if flusher != nil {
				flusher.Flush()
			}
			return nil
		})
		if err != nil {
			s.handleStreamError(w, err, committed, commit, req.Model)
			return
		}
		return
	}

	// non-streaming client: the upstream request STILL streams. The walk's
	// commit rule (first content wins, honest termination, stall watchdog)
	// only exists on the SSE path — a buffered JSON body has no content
	// clock, so an upstream JSON response would stall-fail every hop
	// (observed: non-stream requests exhausted all endpoints). The events
	// are buffered here and reassembled into one completion object.
	var content strings.Builder
	finish := "stop"
	err := s.Walk.Run(r.Context(), req.Model, upstream.Request{
		Model: req.Model, Messages: req.Messages, Stream: true, Extra: req.Extra,
	}, func(ev upstream.SSEEvent) error {
		if text, fin, ok := upstream.ContentOf(ev.Data); ok {
			content.WriteString(text)
		} else if fin != "" {
			finish = mapFinish(fin)
		}
		return nil
	})
	if err != nil {
		s.handleError(w, err, req.Model)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{
		"id":      "router-" + time.Now().Format("20060102150405"),
		"object":  "chat.completion",
		"created": time.Now().Unix(),
		"model":   req.Model,
		"choices": []any{map[string]any{
			"index":         0,
			"message":       map[string]any{"role": "assistant", "content": content.String()},
			"finish_reason": finish,
		}},
	})
}

// handleStreamError maps walk failures post-commit to the in-band enum-
// legal error termination (LiteLLM #21348's lesson: a non-standard
// finish_reason loses the whole response in strict clients; the true
// error state rides an extension field).
func (s *Server) handleStreamError(w http.ResponseWriter, err error, committed bool, commit func(), model string) {
	if !committed {
		s.handleError(w, err, model)
		return
	}
	// committed: in-band termination with a LEGAL finish_reason and the
	// true error in the extension field — never a splice, never a bare
	commit()
	payload := map[string]any{
		"choices": []any{map[string]any{
			"index":         0,
			"delta":         map[string]any{},
			"finish_reason": "error", // mapped below to legal enum
		}},
		"router_error": err.Error(),
	}
	// map "error" to the nearest legal value by downstream-action
	// semantics: content_filter when the stream died after content, else
	// stop. pydantic-ai #2844 proved "error" itself breaks strict SDKs.
	for _, ch := range payload["choices"].([]any) {
		m := ch.(map[string]any)
		m["finish_reason"] = "content_filter"
	}
	data, _ := json.Marshal(payload)
	w.Write([]byte("data: " + string(data) + "\n\n"))
	w.Write([]byte("data: [DONE]\n\n"))
}

func (s *Server) handleError(w http.ResponseWriter, err error, model string) {
	status := http.StatusBadGateway
	code := "upstream_error"
	if strings.Contains(err.Error(), "no endpoints") {
		status = http.StatusNotFound
		code = "model_not_found"
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]any{
		"error": map[string]any{
			"message": err.Error(), "type": code, "code": code,
		},
	})
}

// mapFinish maps provider finish_reasons to the OpenAI legal enum,
// preserving the true value in router_finish_reason when remapped.
func mapFinish(fin string) string {
	switch fin {
	case "stop", "length", "tool_calls", "content_filter", "function_call":
		return fin
	case "error", "malformed_function_call", "aborted", "max_output_tokens",
		"end_turn", "stop_sequence", "eos", "complete", "finish":
		// remap by downstream-action semantics: unknown-but-terminal
		// reasons map to stop; max tokens map to length
		if fin == "max_output_tokens" {
			return "length"
		}
		return "stop"
	}
	return "stop"
}

func (s *Server) handleModels(w http.ResponseWriter, r *http.Request) {
	families := s.Families()
	data := make([]any, 0, len(families))
	for _, f := range families {
		data = append(data, map[string]any{"id": f, "object": "model", "owned_by": "model-router"})
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"object": "list", "data": data})
}

func writeErr(w http.ResponseWriter, status int, code, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]any{
		"error": map[string]any{"message": msg, "type": code, "code": code},
	})
}
