package main

import (
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestUserFromRequest(t *testing.T) {
	none := httptest.NewRequest(http.MethodGet, "/", nil)
	if got := userFromRequest(none); got != "user=none" {
		t.Fatalf("missing header: %s", got)
	}

	bad := httptest.NewRequest(http.MethodGet, "/", nil)
	bad.Header.Set("Authorization", "Bearer not-a-jwt")
	if got := userFromRequest(bad); got != "user=unreadable" {
		t.Fatalf("malformed token: %s", got)
	}

	payload := base64.RawURLEncoding.EncodeToString([]byte(`{"iss":"hello-auth","sub":"demo-user"}`))
	ok := httptest.NewRequest(http.MethodGet, "/", nil)
	ok.Header.Set("Authorization", "Bearer header."+payload+".signature")
	got := userFromRequest(ok)
	if got != "iss=hello-auth sub=demo-user" {
		t.Fatalf("identity: %s", got)
	}
	if strings.Contains(got, payload) || strings.Contains(got, "signature") {
		t.Fatal("identity log included token material")
	}
}
