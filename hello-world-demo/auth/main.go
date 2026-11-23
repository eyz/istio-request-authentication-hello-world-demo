package main

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"log"
	"math/big"
	"net/http"
	"strings"
	"time"
)

const (
	issuer     = "hello-auth"
	subject    = "demo-user"
	keyID      = "hello-auth-1"
	listenAddr = ":8081"
)

type detailKey struct{}

func main() {
	key := mustPrivateKey()
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		if rejectUnlessGet(w, r) {
			return
		}
		setDetail(r, "result=ok")
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok\n"))
	})
	mux.HandleFunc("/.well-known/jwks.json", func(w http.ResponseWriter, r *http.Request) {
		if rejectUnlessGet(w, r) {
			return
		}
		setDetail(r, fmt.Sprintf("result=served keys=1 kid=%s alg=RS256 kty=RSA", keyID))
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(publicJWKS(key))
	})
	mux.HandleFunc("/token", func(w http.ResponseWriter, r *http.Request) {
		if rejectUnlessGet(w, r) {
			return
		}
		now := time.Now()
		token, err := signToken(key, now)
		if err != nil {
			setDetail(r, "result=error")
			http.Error(w, "could not sign token\n", http.StatusInternalServerError)
			return
		}
		setDetail(r, fmt.Sprintf("result=issued iss=%s sub=%s kid=%s exp=%d", issuer, subject, keyID, now.Add(time.Hour).Unix()))
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		_, _ = w.Write([]byte(token))
	})
	log.Printf("listening addr=%s iss=%s kid=%s", listenAddr, issuer, keyID)
	server := &http.Server{
		Addr:              listenAddr,
		Handler:           logRequests(mux),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	log.Fatal(server.ListenAndServe())
}

func rejectUnlessGet(w http.ResponseWriter, r *http.Request) bool {
	if r.Method == http.MethodGet {
		return false
	}
	setDetail(r, "result=method_not_allowed")
	w.Header().Set("Allow", http.MethodGet)
	http.Error(w, "method not allowed\n", http.StatusMethodNotAllowed)
	return true
}

func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		detail := ""
		r = r.WithContext(context.WithValue(r.Context(), detailKey{}, &detail))
		rec := &statusWriter{ResponseWriter: w}
		next.ServeHTTP(rec, r)
		if rec.status == 0 {
			rec.status = http.StatusOK
		}
		if detail == "" {
			detail = resultForStatus(rec.status)
		}
		log.Printf("from=%s method=%s path=%s status=%d bytes=%d %s",
			oneLine(r.RemoteAddr), oneLine(r.Method), oneLine(r.URL.Path), rec.status, rec.n, oneLine(detail))
	})
}

func setDetail(r *http.Request, detail string) {
	if p, ok := r.Context().Value(detailKey{}).(*string); ok {
		*p = detail
	}
}

func resultForStatus(status int) string {
	switch status {
	case http.StatusNotFound:
		return "result=not_found"
	case http.StatusMethodNotAllowed:
		return "result=method_not_allowed"
	default:
		return "result=handled"
	}
}

func oneLine(s string) string {
	return strings.Map(func(r rune) rune {
		if r < 32 || r == 127 {
			return -1
		}
		return r
	}, s)
}

type statusWriter struct {
	http.ResponseWriter
	status int
	n      int
}

func (s *statusWriter) WriteHeader(code int) {
	if s.status != 0 {
		return
	}
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

func (s *statusWriter) Write(b []byte) (int, error) {
	if s.status == 0 {
		s.status = http.StatusOK
	}
	n, err := s.ResponseWriter.Write(b)
	s.n += n
	return n, err
}

func mustPrivateKey() *rsa.PrivateKey {
	block, _ := pem.Decode([]byte(privateKeyPEM))
	if block == nil {
		log.Fatal("auth signing key is not PEM")
	}
	key, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		pkcs1, err1 := x509.ParsePKCS1PrivateKey(block.Bytes)
		if err1 != nil {
			log.Fatalf("parse auth signing key: %v", err)
		}
		return pkcs1
	}
	rsaKey, ok := key.(*rsa.PrivateKey)
	if !ok {
		log.Fatal("auth signing key is not RSA")
	}
	return rsaKey
}

type jwksDoc struct {
	Keys []jwk `json:"keys"`
}

type jwk struct {
	Kty string `json:"kty"`
	Kid string `json:"kid"`
	Use string `json:"use"`
	Alg string `json:"alg"`
	N   string `json:"n"`
	E   string `json:"e"`
}

func publicJWKS(key *rsa.PrivateKey) jwksDoc {
	return jwksDoc{Keys: []jwk{{
		Kty: "RSA",
		Kid: keyID,
		Use: "sig",
		Alg: "RS256",
		N:   base64.RawURLEncoding.EncodeToString(key.N.Bytes()),
		E:   base64.RawURLEncoding.EncodeToString(big.NewInt(int64(key.E)).Bytes()),
	}}}
}

func signToken(key *rsa.PrivateKey, now time.Time) (string, error) {
	headerRaw, err := json.Marshal(struct {
		Alg string `json:"alg"`
		Typ string `json:"typ"`
		Kid string `json:"kid"`
	}{Alg: "RS256", Typ: "JWT", Kid: keyID})
	if err != nil {
		return "", err
	}
	header := base64.RawURLEncoding.EncodeToString(headerRaw)
	payloadRaw, err := json.Marshal(map[string]any{
		"iss": issuer,
		"sub": subject,
		"iat": now.Unix(),
		"exp": now.Add(time.Hour).Unix(),
	})
	if err != nil {
		return "", err
	}
	payload := base64.RawURLEncoding.EncodeToString(payloadRaw)
	signingInput := header + "." + payload
	sum := sha256.Sum256([]byte(signingInput))
	sig, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, sum[:])
	if err != nil {
		return "", err
	}
	return signingInput + "." + base64.RawURLEncoding.EncodeToString(sig), nil
}
