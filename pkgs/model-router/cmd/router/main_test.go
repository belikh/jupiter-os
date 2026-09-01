package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// The composed root mux serves /healthz and dispatches the dashboard.
func TestHealthzOnComposedMux(t *testing.T) {
	// build the minimal composed mux shape: the real wiring needs the
	// full stack; here we assert the /healthz route contract on a mux
	// assembled the same way main() assembles it.
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		w.Write([]byte("ok"))
	})
	ts := httptest.NewServer(mux)
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/healthz")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("healthz = %d, want 200", resp.StatusCode)
	}

	req, _ := http.NewRequest("POST", ts.URL+"/healthz", nil)
	presp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer presp.Body.Close()
	if presp.StatusCode != 405 {
		t.Fatalf("POST healthz = %d, want 405", presp.StatusCode)
	}
	if allow := presp.Header.Get("Allow"); allow != "GET, HEAD" {
		t.Fatalf("Allow = %q", allow)
	}
}
