package main

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"testing"
	"time"
)

// TestHTTPServerTimeoutConfiguration (remediation W4a / plan §6.F):
// every field of the production timeout set must be set — the app
// shipped with ReadHeaderTimeout only for its entire life, which is the
// audited-absence catalogue's first hygiene line. A zero field here is
// exactly the slowloris / slow-body / pinned-socket class returning.
func TestHTTPServerTimeoutConfiguration(t *testing.T) {
	srv := newHTTPServer(":0", http.NotFoundHandler())
	for _, tc := range []struct {
		name string
		got  time.Duration
		want time.Duration
	}{
		{"ReadHeaderTimeout", srv.ReadHeaderTimeout, 10 * time.Second},
		{"ReadTimeout", srv.ReadTimeout, 60 * time.Second},
		{"WriteTimeout", srv.WriteTimeout, 120 * time.Second},
		{"IdleTimeout", srv.IdleTimeout, 120 * time.Second},
	} {
		if tc.got != tc.want {
			t.Errorf("%s = %v, want %v (zero-value timeouts are the W4a regression)", tc.name, tc.got, tc.want)
		}
	}
}

// TestGracefulShutdownDrainsInFlightRequests (W4a acceptance): SIGTERM
// semantics — stop accepting, let in-flight requests COMPLETE. A slow
// handler with a live connection must finish and deliver its full body
// after Shutdown is called; the listener must return http.ErrServerClosed
// (the error main filters), not a crash.
func TestGracefulShutdownDrainsInFlightRequests(t *testing.T) {
	release := make(chan struct{})
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		<-release // hold the response open until the test says go
		_, _ = io.WriteString(w, "drained-response")
	})

	lst, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	srv := newHTTPServer("", mux)
	served := make(chan error, 1)
	go func() { served <- srv.Serve(lst) }()

	type result struct {
		body string
		err  error
	}
	done := make(chan result, 1)
	go func() {
		resp, err := http.Get("http://" + lst.Addr().String() + "/")
		if err != nil {
			done <- result{err: err}
			return
		}
		b, err := io.ReadAll(resp.Body)
		resp.Body.Close() //nolint:errcheck // test
		done <- result{body: string(b), err: err}
	}()

	// Wait until the request is INSIDE the handler, then shut down while
	// it is in flight — the drain window under test.
	time.Sleep(150 * time.Millisecond)
	shutdownErr := make(chan error, 1)
	go func() {
		// Fresh context, exactly like main's SIGTERM path (the signal
		// context is already cancelled the moment it fires).
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		shutdownErr <- srv.Shutdown(ctx)
	}()

	// The drain proof's first half: Shutdown is BLOCKED on the in-flight
	// request (it has not returned and the connection has not been cut).
	select {
	case err := <-shutdownErr:
		t.Fatalf("Shutdown returned (%v) while a request was still in flight — it cut the connection instead of draining", err)
	case r := <-done:
		t.Fatalf("in-flight request finished before release: %+v — drain window never existed", r)
	case <-time.After(300 * time.Millisecond):
		// still draining — correct.
	}

	// Second half: complete the in-flight response; Shutdown must now
	// return nil and the client must have received the FULL body.
	close(release)
	select {
	case r := <-done:
		if r.err != nil {
			t.Fatalf("in-flight request failed across shutdown: %v", r.err)
		}
		if r.body != "drained-response" {
			t.Fatalf("in-flight body = %q, want the complete response", r.body)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("in-flight request never completed after release")
	}
	select {
	case err := <-shutdownErr:
		if err != nil {
			t.Fatalf("Shutdown errored after drain: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Shutdown never returned after the in-flight request completed")
	}

	select {
	case err := <-served:
		if !errors.Is(err, http.ErrServerClosed) {
			t.Fatalf("Serve returned %v, want http.ErrServerClosed (the error main filters)", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Serve never returned after Shutdown")
	}
}

// TestVersionFlag answers the stamped identity (W4a: "a static 0.1.0
// cannot identify what is live" — the flag is the on-host half of the
// git-stamped version; the build stamps -X main.version).
func TestVersionFlag(t *testing.T) {
	if version == "" {
		t.Fatal("version var is empty — the ldflags stamp and the default must both exist")
	}
}
