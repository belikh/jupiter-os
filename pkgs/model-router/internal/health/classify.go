package health

import (
	"encoding/json"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// ClassKind is the dispatch verdict for one provider error response.
type ClassKind int

const (
	Retryable ClassKind = iota
	KeyFatal
	ModelFatal
	OverloadQuota
	RateLimitHit
	UnknownRateLimit
)

// Class carries the verdict plus details (payload notes, raw-body capture
// markers, reset timestamps) for the ledger and the dashboard.
type Class struct {
	Kind    ClassKind
	Details string
}

// CeilingHint is a learnable limit parsed from an error body or response
// headers — the ledger's learn-from-response input.
type CeilingHint struct {
	Dimension string  // "rpm", "rpd", "tpm", "tpd", "reset_at" (unix seconds)
	Value     float64 // for reset_at: seconds since epoch
}

// provider error-code conventions. The zai table is first-class because its
// codes are documented; other providers are pattern-matched.
const (
	zaiCode1113 = "1113" // billing rejection arriving as HTTP 429 — never retry
	zaiCode1308 = "1308" // usage limit with an explicit reset timestamp
	zaiCode1310 = "1310" // weekly/monthly exhaustion
)

var (
	// Groq's body names the model, dimension, enforced limit and a countdown.
	// The corpus fixture shows "Requested ~12903" with a tilde — tolerate it.
	groqLimitRe = regexp.MustCompile(`Limit ([0-9]+), Used ([0-9]+), Requested ~?([0-9]+)`)

	// gzip magic bytes — an opaque body we must not parse.
	gzipMagic = []byte{0x1f, 0x8b}

	// Z.ai reset timestamps arrive inside the message text.
	zaiResetRe = regexp.MustCompile(`reset at ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2})`)
)

// quotaKeywords mark a 403 as a lying quota rejection.
var quotaKeywords = []string{"quota", "配额"}

// providerQuotaText lists providers whose 403s carry quota text instead of
// auth failure (the lying-code class). "agentrouter" is the documented case.
var lyingQuotaProviders = map[string]bool{
	"agentrouter": true,
}

// errorBody is the common OpenAI-compatible error envelope.
type errorBody struct {
	Error struct {
		Code    any    `json:"code"`
		Message string `json:"message"`
		Type    string `json:"type"`
	} `json:"error"`
	Code    any    `json:"code"`    // Gemini nests differently
	Message string `json:"message"` // Gemini nests differently
}

// geminiError matches Google's RESOURCE_EXHAUSTED envelope.
type geminiError struct {
	Error struct {
		Status  string `json:"status"`
		Message string `json:"message"`
		Details []struct {
			Type        string `json:"@type"`
			RetryDelay  string `json:"retryDelay"`
			QuotaMetric string `json:"quotaMetric"`
			QuotaID     string `json:"quotaId"`
			QuotaValue  string `json:"quotaValue"`
		} `json:"details"`
	} `json:"error"`
}

// Dispatch classifies a provider error response on the (status, body,
// headers) triple after provider-specific restatement. It never trusts the
// status code alone: documented lying codes include quota-as-403
// (agentrouter), overload-as-429 (OpenAI) and billing-as-429 (Z.ai 1113).
func Dispatch(providerID string, status int, body []byte, headers http.Header) Class {
	// opaque body: capture, never parse
	if len(body) >= 2 && bytesEqual(body[:2], gzipMagic) {
		return Class{Kind: UnknownRateLimit, Details: "opaque gzipped error body captured for inspection"}
	}

	lower := strings.ToLower(string(body))

	switch status {
	case 429:
		return dispatch429(providerID, body, lower)
	case 401:
		return Class{Kind: KeyFatal, Details: "authentication rejected"}
	case 403:
		if lyingQuotaProviders[providerID] && containsAny(lower, quotaKeywords) {
			return Class{Kind: OverloadQuota, Details: "lying 403: quota exhausted reported as forbidden"}
		}
		if containsAny(lower, quotaKeywords) {
			// any provider whose 403 text names quota is a lying code,
			// not an auth failure — the body outranks the status
			return Class{Kind: OverloadQuota, Details: "lying 403: quota exhausted reported as forbidden"}
		}
		return Class{Kind: KeyFatal, Details: "forbidden"}
	case 404:
		return Class{Kind: ModelFatal, Details: "model not found — retire the mapping"}
	case 408:
		return Class{Kind: Retryable, Details: "request timeout"}
	case 413:
		return Class{Kind: Retryable, Details: "payload too large: reduce request size or split"}
	default:
		if status >= 500 {
			return Class{Kind: Retryable, Details: "upstream server error"}
		}
		return Class{Kind: UnknownRateLimit, Details: "unclassified status " + strconv.Itoa(status)}
	}
}

func dispatch429(providerID string, body []byte, lower string) Class {
	// Z.ai first: documented business codes outrank generic patterns.
	var eb errorBody
	_ = json.Unmarshal(body, &eb)
	code := codeString(eb.Error.Code, eb.Code)

	if providerID == "zai" || code == zaiCode1113 || code == zaiCode1308 || code == zaiCode1310 {
		switch code {
		case zaiCode1113:
			return Class{Kind: KeyFatal, Details: "zai 1113: billing rejection " + billingMarker + " — no free quota on this route, never retry"}
		case zaiCode1308, zaiCode1310:
			return Class{Kind: OverloadQuota, Details: "zai usage limit with stated reset (next_flush_time)"}
		}
	}

	// Groq-style disclosure: Limit N, Used U, Requested R.
	if groqLimitRe.MatchString(string(body)) {
		return Class{Kind: RateLimitHit, Details: "groq-style limit disclosure in body"}
	}

	// Gemini quota envelope.
	var ge geminiError
	if json.Unmarshal(body, &ge) == nil && ge.Error.Status == "RESOURCE_EXHAUSTED" {
		return Class{Kind: OverloadQuota, Details: "gemini quotaValue envelope"}
	}

	// OpenAI-style overload: capacity, not quota — fail over rather than cool.
	if strings.Contains(lower, "overloaded") {
		return Class{Kind: Retryable, Details: "capacity overload — fail over to another endpoint"}
	}

	// Unknown 429 dialect: conservative rate-limit, never a long cooldown.
	return Class{Kind: UnknownRateLimit, Details: "unrecognised 429 dialect treated conservatively"}
}

// ParseCeilings extracts learnable limits from an error body and response
// headers. Monotone-conservative consumers (the ledger) fill NULLs or lower
// existing ceilings; never raise.
func ParseCeilings(providerID string, body []byte, headers http.Header) []CeilingHint {
	var out []CeilingHint

	// header-carried limits (x-ratelimit-*: requests mean RPD, tokens TPM —
	// the Groq convention the corpus documents)
	if headers != nil {
		if v := headerFloat(headers, "X-RateLimit-Limit-Requests"); v > 0 {
			out = append(out, CeilingHint{Dimension: "rpd", Value: v})
		}
		if v := headerFloat(headers, "X-RateLimit-Limit-Tokens"); v > 0 {
			out = append(out, CeilingHint{Dimension: "tpm", Value: v})
		}
	}
	if len(body) < 2 || bytesEqual(body[:2], gzipMagic) {
		return out
	}

	// Groq disclosure: the first number after "Limit " is the enforced
	// ceiling for the dimension named in the message.
	if m := groqLimitRe.FindStringSubmatch(string(body)); m != nil {
		if v, err := strconv.ParseFloat(m[1], 64); err == nil {
			dim := "tpm"
			if strings.Contains(string(body), "per day") || strings.Contains(string(body), "RPD") {
				dim = "rpd"
			} else if strings.Contains(string(body), "requests per minute") || strings.Contains(string(body), "RPM") {
				dim = "rpm"
			}
			out = append(out, CeilingHint{Dimension: dim, Value: v})
		}
	}

	// Gemini quotaValue: the enforced daily per-model/project figure.
	var ge geminiError
	if json.Unmarshal(body, &ge) == nil {
		for _, d := range ge.Error.Details {
			if d.QuotaValue != "" {
				if v, err := strconv.ParseFloat(d.QuotaValue, 64); err == nil {
					dim := "rpd"
					if strings.Contains(strings.ToLower(d.QuotaMetric), "token") {
						dim = "tpd"
					}
					out = append(out, CeilingHint{Dimension: dim, Value: v})
				}
			}
			// NOTE: d.RetryDelay is deliberately NOT parsed into a reset
			// hint — Google staff confirmed it misreports quota resets.
		}
	}

	// Z.ai reset timestamp: an authoritative reset clock.
	if m := zaiResetRe.FindStringSubmatch(string(body)); m != nil {
		if ts, err := time.Parse(time.RFC3339, m[1]); err == nil {
			out = append(out, CeilingHint{Dimension: "reset_at", Value: float64(ts.Unix())})
		}
	}

	return out
}

func codeString(vals ...any) string {
	for _, v := range vals {
		switch c := v.(type) {
		case string:
			return c
		case float64:
			return strconv.FormatFloat(c, 'f', -1, 64)
		}
	}
	return ""
}

func containsAny(s string, words []string) bool {
	for _, w := range words {
		if strings.Contains(s, w) {
			return true
		}
	}
	return false
}

func headerFloat(h http.Header, name string) float64 {
	v := strings.TrimSpace(h.Get(name))
	if v == "" {
		return 0
	}
	f, err := strconv.ParseFloat(v, 64)
	if err != nil {
		return 0
	}
	return f
}

func bytesEqual(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
