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
	writeJSON(w, http.StatusMethodNotAllowed, errorBody("method not allowed"))
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

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func errorBody(msg string) map[string]string { return map[string]string{"error": msg} }

func retryAfter(w http.ResponseWriter, d time.Duration) {
	secs := int(d.Seconds())
	if secs < 1 {
		secs = 1
	}
	w.Header().Set("Retry-After", strconv.Itoa(secs))
}
