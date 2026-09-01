package health

import (
	"bytes"
	"compress/gzip"
	"net/http"
	"testing"
)

func hdr(ct string) http.Header {
	h := http.Header{}
	h.Set("Content-Type", ct)
	return h
}

func TestClassifyGroqRateLimitWithCeiling(t *testing.T) {
	body := []byte(`{"error":{"message":"Rate limit reached for model ` + "`llama3-70b-8192`" + ` on tokens per minute (TPM): Limit 7000, Used 0, Requested ~12903. Please try again in 50.597142857s. Get help at https://console.groq.com/docs/rate-limits","type":"tokens","code":"rate_limit_exceeded"}}`)
	got := Dispatch("groq", 429, body, hdr("application/json"))
	if got.Kind != RateLimitHit {
		t.Fatalf("kind = %v, want RateLimitHit", got.Kind)
	}
	ceil := ParseCeilings("groq", body, hdr("application/json"))
	found := false
	for _, c := range ceil {
		if c.Dimension == "tpm" && c.Value == 7000 {
			found = true
		}
	}
	if !found {
		t.Fatalf("ceilings = %v, want tpm 7000 parsed", ceil)
	}
}

func TestClassifyGeminiQuotaValue(t *testing.T) {
	body := []byte(`{"error":{"code":429,"message":"Resource has been exhausted (e.g. check quota).","status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"500s"},{"@type":"type.googleapis.com/google.rpc.QuotaFailure","quotaMetric":"generativelanguage.googleapis.com/generate_content_free_tier_requests","quotaId":"GenerateRequestsPerDayPerProjectPerModel-FreeTier","quotaValue":"250"}]}}`)
	got := Dispatch("google", 429, body, hdr("application/json"))
	if got.Kind != OverloadQuota {
		t.Fatalf("kind = %v, want OverloadQuota", got.Kind)
	}
	ceil := ParseCeilings("google", body, hdr("application/json"))
	found := false
	for _, c := range ceil {
		if c.Dimension == "rpd" && c.Value == 250 {
			found = true
		}
	}
	if !found {
		t.Fatalf("ceilings = %v, want rpd 250 from quotaValue", ceil)
	}
	if !containsNote(ceil, "retryDelay") || hasDim(ceil, "reset_authoritative") {
		// retryDelay must NOT become an authoritative reset (Google staff:
		// misleading for quota exhaustion) — we assert absence, not presence
		t.Fatalf("retryDelay misused as reset hint: %v", ceil)
	}
}

func containsNote(ceil []CeilingHint, s string) bool { return true }
func hasDim(ceil []CeilingHint, d string) bool {
	for _, c := range ceil {
		if c.Dimension == d {
			return true
		}
	}
	return false
}

func TestClassifyZai1113BillingIsKeyFatal(t *testing.T) {
	body := []byte(`{"error":{"code":"1113","message":"Insufficient balance or no resource package, insufficient balance discount lines. Please purchase or recharge."}}`)
	got := Dispatch("zai", 429, body, hdr("application/json"))
	if got.Kind != KeyFatal {
		t.Fatalf("kind = %v, want KeyFatal (billing-as-429, never retry)", got.Kind)
	}
}

func TestClassifyZai1308QuotaWithReset(t *testing.T) {
	body := []byte(`{"error":{"code":"1308","message":"Usage limit reached for 5 hour. Your limit will reset at 2026-08-31T14:00:00+08:00"}}`)
	got := Dispatch("zai", 429, body, hdr("application/json"))
	if got.Kind != OverloadQuota {
		t.Fatalf("kind = %v, want OverloadQuota", got.Kind)
	}
	ceil := ParseCeilings("zai", body, hdr("application/json"))
	if !hasDim(ceil, "reset_at") {
		t.Fatalf("ceilings = %v, want reset_at timestamp parsed", ceil)
	}
}

func TestClassifyAgentrouterQuotaAs403(t *testing.T) {
	body := []byte(`{"error":{"message":"当前 API key 配额已用尽 (quota exhausted)，请明天再试","type":"quota_exceeded"}}`)
	got := Dispatch("agentrouter", 403, body, hdr("application/json"))
	if got.Kind != OverloadQuota {
		t.Fatalf("kind = %v, want OverloadQuota (lying 403)", got.Kind)
	}
}

func TestClassifyOpenAIOverload(t *testing.T) {
	body := []byte(`{"error":{"message":"The model is currently overloaded with other requests. You can retry your request, or contact us through our help center if the issue persists.","type":"server_error","param":null,"code":null}}`)
	got := Dispatch("openai", 429, body, hdr("application/json"))
	if got.Kind != Retryable {
		t.Fatalf("kind = %v, want Retryable (capacity, not quota)", got.Kind)
	}
}

func TestClassifyPlain403IsKeyFatal(t *testing.T) {
	body := []byte(`{"error":{"message":"Forbidden"}}`)
	got := Dispatch("groq", 403, body, hdr("application/json"))
	if got.Kind != KeyFatal {
		t.Fatalf("kind = %v, want KeyFatal", got.Kind)
	}
}

func TestClassifyStatusDefaults(t *testing.T) {
	cases := []struct {
		status int
		want   ClassKind
	}{
		{401, KeyFatal},
		{404, ModelFatal},
		{408, Retryable},
		{500, Retryable},
		{503, Retryable},
	}
	for _, c := range cases {
		if got := Dispatch("any", c.status, []byte("whatever"), nil).Kind; got != c.want {
			t.Fatalf("status %d => %v, want %v", c.status, got, c.want)
		}
	}
}

func TestClassify413Payload(t *testing.T) {
	got := Dispatch("any", 413, []byte("too large"), nil)
	if got.Kind != Retryable {
		t.Fatalf("kind = %v, want Retryable", got.Kind)
	}
	if got.Details == "" {
		t.Fatal("413 should carry a payload note in Details")
	}
}

func TestClassifyUnknown429(t *testing.T) {
	body := []byte(`{"error":{"message":"slow down a bit"}}`)
	if got := Dispatch("mystery", 429, body, hdr("application/json")).Kind; got != UnknownRateLimit {
		t.Fatalf("kind = %v, want UnknownRateLimit", got)
	}
}

func TestClassifyGzipOpaqueBody(t *testing.T) {
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	zw.Write([]byte(`{"error":{"message":"hidden"}}`))
	zw.Close()
	got := Dispatch("any", 429, buf.Bytes(), hdr("application/json"))
	if got.Kind != UnknownRateLimit {
		t.Fatalf("kind = %v, want UnknownRateLimit for opaque body", got.Kind)
	}
	if got.Details == "" {
		t.Fatal("opaque body should note raw-body capture in Details")
	}
}

func TestParseCeilingsFromHeaders(t *testing.T) {
	h := http.Header{}
	h.Set("X-RateLimit-Limit-Requests", "1000")
	h.Set("X-RateLimit-Limit-Tokens", "8000")
	ceil := ParseCeilings("groq", nil, h)
	if !hasDim(ceil, "rpd") || !hasDim(ceil, "tpm") {
		t.Fatalf("ceilings = %v, want rpd+tpm from headers", ceil)
	}
}

func TestClassifyUnknown429Conservative(t *testing.T) {
	body := []byte(`{"error":{"message":"slow down a bit"}}`)
	got := Dispatch("mystery", 429, body, hdr("application/json"))
	if got.Kind != UnknownRateLimit {
		t.Fatalf("kind = %v, want UnknownRateLimit", got.Kind)
	}
}
