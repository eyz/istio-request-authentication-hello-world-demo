package main

import (
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestSignTokenMatchesJWKS(t *testing.T) {
	key := mustPrivateKey()
	now := time.Unix(1_795_464_901, 0)
	token, err := signToken(key, now)
	if err != nil {
		t.Fatal(err)
	}
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		t.Fatalf("token sections = %d", len(parts))
	}
	payload := decodeJSON(t, parts[1])
	if payload["iss"] != issuer || payload["sub"] != subject {
		t.Fatalf("claims iss=%v sub=%v", payload["iss"], payload["sub"])
	}
	header := decodeJSON(t, parts[0])
	if header["alg"] != "RS256" || header["kid"] != keyID {
		t.Fatalf("header alg=%v kid=%v", header["alg"], header["kid"])
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if err := rsa.VerifyPKCS1v15(&key.PublicKey, crypto.SHA256, sum[:], sig); err != nil {
		t.Fatal(err)
	}
	set := publicJWKS(key)
	if len(set.Keys) != 1 || set.Keys[0].Kid != keyID || set.Keys[0].N == "" || set.Keys[0].E == "" {
		t.Fatalf("jwks kid=%s keys=%d", set.Keys[0].Kid, len(set.Keys))
	}
}

func TestRejectUnlessGet(t *testing.T) {
	req := httptest.NewRequest(http.MethodPost, "/token", nil)
	rec := httptest.NewRecorder()
	if !rejectUnlessGet(rec, req) {
		t.Fatal("POST /token was allowed")
	}
	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("POST /token status = %d, want 405", rec.Code)
	}
	if rec.Header().Get("Allow") != http.MethodGet {
		t.Fatalf("Allow header = %q, want GET", rec.Header().Get("Allow"))
	}
}

func decodeJSON(t *testing.T, part string) map[string]any {
	t.Helper()
	raw, err := base64.RawURLEncoding.DecodeString(part)
	if err != nil {
		t.Fatal(err)
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatal(err)
	}
	return out
}
