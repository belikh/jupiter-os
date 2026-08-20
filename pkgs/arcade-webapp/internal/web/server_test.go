package web

import (
	"io"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestIndexServesPlaceholder(t *testing.T) {
	rec := httptest.NewRecorder()
	New().Handler().ServeHTTP(rec, httptest.NewRequest("GET", "/", nil))

	if rec.Code != 200 {
		t.Fatalf("GET /: status = %d, want 200", rec.Code)
	}
	body := rec.Body.String()
	for _, marker := range []string{
		"jupiterOS Arcade",
		"arcade webapp placeholder",
		"/healthz",
	} {
		if !strings.Contains(body, marker) {
			t.Errorf("GET /: body missing marker %q", marker)
		}
	}
	if ct := rec.Header().Get("Content-Type"); !strings.Contains(ct, "text/html") {
		t.Errorf("GET /: Content-Type = %q, want text/html", ct)
	}
}

func TestUnknownPathIsNotFound(t *testing.T) {
	rec := httptest.NewRecorder()
	New().Handler().ServeHTTP(rec, httptest.NewRequest("GET", "/no-such-page", nil))

	if rec.Code != 404 {
		t.Fatalf("GET /no-such-page: status = %d, want 404", rec.Code)
	}
}

func TestHealthz(t *testing.T) {
	rec := httptest.NewRecorder()
	New().Handler().ServeHTTP(rec, httptest.NewRequest("GET", "/healthz", nil))

	if rec.Code != 200 {
		t.Fatalf("GET /healthz: status = %d, want 200", rec.Code)
	}
	body, err := io.ReadAll(rec.Body)
	if err != nil {
		t.Fatalf("reading body: %v", err)
	}
	if strings.TrimSpace(string(body)) != "ok" {
		t.Errorf("GET /healthz: body = %q, want %q", body, "ok")
	}
}
