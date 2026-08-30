// Hardening middleware (arcade remediation W4a / plan §6.F): the full
// production-Go server set that the audited-absence catalogue named as
// "standards postponed as preferences".
//
//   - securityHeaders stamps the OWASP-baseline response headers on
//     EVERY response: a layered CSP (script-src 'self' — the inline
//     toast handlers were extracted to /static/toasts.js exactly so
//     this can be strict; style-src keeps 'unsafe-inline' for the
//     progressbar width attributes, the documented residual),
//     X-Frame-Options: DENY + frame-ancestors 'none' (clickjacking),
//     X-Content-Type-Options: nosniff, Referrer-Policy: no-referrer,
//     and htmx's own recommended pins: the meta-config disables
//     allowEval (hx-on is unused in this app) and the auto-injected
//     indicator <style> (its rule lives in app.css instead).
//
//   - the stdlib's CrossOriginProtection (plan §6.F names it verbatim)
//     sits inside the headers: a cross-origin browser POST — a hostile
//     page riding the operator's session from another tab — is
//     refused 403 by the browser's own Sec-Fetch-Site/Origin
//     declaration, even when the hostile page smuggles the htmx
//     header. Requests without either header (curl, tests, the
//     kiosk's own scripts) pass unchanged: the app's htmx-only check
//     (hxRequestOK) stays the first line; this is the second,
//     browser-enforced line — the 403 class the W3 lane proved the
//     curl-only lanes can never see.
//
//   - withBodyLimits wraps EVERY body-reading endpoint in
//     http.MaxBytesReader with a per-route cap: 64 MiB + slack for the
//     one legit large upload (.torrent staging — the largest Minerva
//     optical sets reach tens of MB), 1 MiB for everything else (every
//     form the app serves is a handful of short fields). A declared
//     Content-Length over the cap is refused with 413 before any
//     handler runs; a lying/absent Content-Length dies on the reader
//     itself mid-parse.
package web

import (
	"log"
	"net/http"
	"strings"
)

// maxBodyDefault caps request bodies on every route except the torrent
// upload: all of this app's forms are a few short fields.
const maxBodyDefault = 1 << 20 // 1 MiB

// maxBodyTorrentUpload matches downloads.go's maxTorrentUpload plus
// multipart framing slack.
const maxBodyTorrentUpload = (64 << 20) + (1 << 20)

// contentSecurityPolicy is the layered CSP (see the file comment). 'self'
// only for scripts; styles keep 'unsafe-inline' for the progressbar
// width attributes — removing those means reworking every bar template
// and is tracked as the documented residual, not smuggled in silently.
const contentSecurityPolicy = "default-src 'self'; " +
	"script-src 'self'; " +
	"style-src 'self' 'unsafe-inline'; " +
	"img-src 'self' data:; " +
	"connect-src 'self'; " +
	"font-src 'self'; " +
	"object-src 'none'; " +
	"base-uri 'none'; " +
	"form-action 'self'; " +
	"frame-ancestors 'none'"

// securityHeaders stamps the baseline security headers. Applied as
// middleware so partials, static files, /healthz and reports cannot
// drift out from under it.
func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Content-Security-Policy", contentSecurityPolicy)
		h.Set("X-Frame-Options", "DENY")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "no-referrer")
		next.ServeHTTP(w, r)
	})
}

// bodyLimitForPath maps a request to its MaxBytesReader cap. The torrent
// upload is matched on the full registered pattern shape
// (/systems/<sys>/stage-torrent): the suffix carries its own leading '/',
// so a plain suffix match cannot hit mid-segment.
func bodyLimitForPath(r *http.Request) int64 {
	if r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/stage-torrent") {
		return maxBodyTorrentUpload
	}
	return maxBodyDefault
}

// withBodyLimits arms MaxBytesReader on every request that can carry a
// body, refusing declared oversizes with 413 up front.
func withBodyLimits(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodPost, http.MethodPut, http.MethodPatch:
			limit := bodyLimitForPath(r)
			if r.ContentLength > limit {
				http.Error(w, "request body too large", http.StatusRequestEntityTooLarge)
				log.Printf("web: refused oversized body %s %s (%d bytes > %d cap)",
					r.Method, r.URL.Path, r.ContentLength, limit)
				return
			}
			r.Body = http.MaxBytesReader(w, r.Body, limit)
		}
		next.ServeHTTP(w, r)
	})
}

// harden chains the W4a middleware set (applied once, in New). Order:
// securityHeaders OUTERMOST so even a refused request carries the full
// header set, then CrossOriginProtection (plan §6.F names it verbatim —
// it judges on Sec-Fetch-Site/Origin headers only, before the body-limit
// reader consumes anything), then the body limits.
func harden(h http.Handler) http.Handler {
	cross := http.NewCrossOriginProtection()
	return securityHeaders(cross.Handler(withBodyLimits(h)))
}
