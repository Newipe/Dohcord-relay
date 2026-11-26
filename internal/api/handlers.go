package api

import (
	"encoding/json"
	"net"
	"net/http"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

func allowedMethod(w http.ResponseWriter, r *http.Request) bool {
	if r.Method == http.MethodGet || r.Method == http.MethodHead {
		return true
	}
	w.Header().Set("Allow", "GET, HEAD")
	writeError(w, http.StatusMethodNotAllowed, "method not allowed")
	return false
}

var acmeToken = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)

// handleACMEChallenge serves HTTP-01 validation files from the webroot. It exists
// only so certbot can prove control of the domain or IP address; it is not an API.
func (s *Server) handleACMEChallenge(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	token := strings.TrimPrefix(r.URL.Path, "/.well-known/acme-challenge/")
	if !acmeToken.MatchString(token) {
		http.NotFound(w, r)
		return
	}
	// certbot --webroot writes challenge files to
	// <webroot>/.well-known/acme-challenge/<token>.
	http.ServeFile(w, r, filepath.Join(s.cfg.ACMEWebroot, ".well-known", "acme-challenge", token))
}

func (s *Server) clientIP(r *http.Request) string {
	if s.cfg.TrustProxy {
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			first, _, _ := strings.Cut(xff, ",")
			if ip := strings.TrimSpace(first); ip != "" {
				return ip
			}
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// errorMessages is every fixed error the API returns. Encoding each one once
// keeps a refusal (a 429 under abuse, a 503 when a file is unreadable) free of
// the map and encoder a per-request response would otherwise allocate.
var errorMessages = []string{
	"destination policy unavailable",
	"encode response",
	"global request limit reached",
	"method not allowed",
	"proxy configuration unavailable",
	"too many requests from this address",
	"turn configuration unavailable",
}

var errorBodies = func() map[string][]byte {
	m := make(map[string][]byte, len(errorMessages))
	for _, msg := range errorMessages {
		body, err := json.Marshal(map[string]string{"error": msg})
		if err != nil {
			continue
		}
		m[msg] = append(body, '\n')
	}
	return m
}()

// errorBody returns the encoded {"error": msg} document. A message outside the
// fixed set is encoded on the spot, so the response shape never depends on the
// caller having registered it.
func errorBody(msg string) []byte {
	if body, ok := errorBodies[msg]; ok {
		return body
	}
	body, _ := json.Marshal(map[string]string{"error": msg})
	return append(body, '\n')
}

// writeError writes an error document in one call, with an exact length.
func writeError(w http.ResponseWriter, status int, msg string) {
	body := errorBody(msg)
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Content-Length", strconv.Itoa(len(body)))
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

func retryAfter(w http.ResponseWriter, d time.Duration) {
	secs := int(d.Seconds())
	if secs < 1 {
		secs = 1
	}
	w.Header().Set("Retry-After", strconv.Itoa(secs))
}
