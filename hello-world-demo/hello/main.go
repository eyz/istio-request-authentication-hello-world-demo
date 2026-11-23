package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"log"
	"net/http"
	"strings"
	"time"
	"unicode"
)

type detailKey struct{}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		if rejectUnlessGet(w, r) {
			return
		}
		setDetail(r, "result=probe "+userFromRequest(r))
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok\n"))
	})
	mux.HandleFunc("/api/v1/hello", func(w http.ResponseWriter, r *http.Request) {
		if rejectUnlessGet(w, r) {
			return
		}
		setDetail(r, "result=served "+userFromRequest(r))
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("hello world\n"))
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if rejectUnlessGet(w, r) {
			return
		}
		setDetail(r, "result=not_found "+userFromRequest(r))
		http.NotFound(w, r)
	})
	log.Printf("listening addr=:8080")
	server := &http.Server{
		Addr:              ":8080",
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
	setDetail(r, "result=method_not_allowed "+userFromRequest(r))
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

func userFromRequest(r *http.Request) string {
	const prefix = "Bearer "
	header := r.Header.Get("Authorization")
	if !strings.HasPrefix(header, prefix) {
		return "user=none"
	}
	parts := strings.Split(header[len(prefix):], ".")
	if len(parts) != 3 {
		return "user=unreadable"
	}
	raw, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return "user=unreadable"
	}
	var claims struct {
		Iss string `json:"iss"`
		Sub string `json:"sub"`
	}
	if json.Unmarshal(raw, &claims) != nil {
		return "user=unreadable"
	}
	iss := safeID(claims.Iss)
	sub := safeID(claims.Sub)
	if iss == "" && sub == "" {
		return "user=none"
	}
	return "iss=" + iss + " sub=" + sub
}

func safeID(s string) string {
	if s == "" {
		return ""
	}
	var b strings.Builder
	for _, r := range s {
		if unicode.IsLetter(r) || unicode.IsDigit(r) || strings.ContainsRune("-_./:@", r) {
			b.WriteRune(r)
			if b.Len() == 128 {
				break
			}
		}
	}
	return b.String()
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
