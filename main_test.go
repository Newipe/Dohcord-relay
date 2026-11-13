package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func testServer(t *testing.T, secret string, ttl time.Duration) (*server, string) {
	t.Helper()
	dir := t.TempDir()
	secretPath := filepath.Join(dir, "turn-secret")
	if secret != "" {
		if err := os.WriteFile(secretPath, []byte(secret+"\n"), 0o600); err != nil {
			t.Fatalf("write secret: %v", err)
		}
	}

	cfg := defaultConfig()
	cfg.secretFile = secretPath
	cfg.ttl = ttl
	cfg.httpsListen = ""
	cfg.httpListen = ""

	logger := log.New(io.Discard, "", 0)
	srv := newServer(cfg, logger)
	return srv, secretPath
}

// TestCredentialVector pins the TURN REST credential algorithm to a value
// produced independently with:
//
//	printf '%s' '1700000000:Dohcord' |
//	  openssl dgst -sha1 -hmac 'dohcord-test-secret' -binary | base64
func TestCredentialVector(t *testing.T) {
	now := time.Unix(1700000000-86400, 0)
	username, password, expiresAt := issueCredential([]byte("dohcord-test-secret"), "Dohcord", 24*time.Hour, now)

	if want := int64(1700000000); expiresAt != want {
		t.Errorf("expiresAt = %d, want %d", expiresAt, want)
	}
	if want := "1700000000:Dohcord"; username != want {
		t.Errorf("username = %q, want %q", username, want)
	}
	if want := "oIF3yqYkLlX5CGs/bG1ryjeRTT0="; password != want {
		t.Errorf("password = %q, want %q", password, want)
	}
}

func TestParseTURNUsername(t *testing.T) {
	exp, identity, err := parseTURNUsername("1794600000:Dohcord")
	if err != nil {
		t.Fatalf("parseTURNUsername: %v", err)
	}
	if exp != 1794600000 || identity != "Dohcord" {
		t.Fatalf("got (%d, %q), want (1794600000, \"Dohcord\")", exp, identity)
	}

	for _, in := range []string{"", "Dohcord", "abc:Dohcord"} {
		if _, _, err := parseTURNUsername(in); err == nil {
			t.Errorf("parseTURNUsername(%q) succeeded, want error", in)
		}
	}
}

func TestValidateIdentity(t *testing.T) {
	for _, ok := range []string{"Dohcord", "dohcord-relay"} {
		if err := validateIdentity(ok); err != nil {
			t.Errorf("validateIdentity(%q) = %v, want nil", ok, err)
		}
	}
	for _, bad := range []string{"", "Doh:cord", "Doh cord", strings.Repeat("a", 65)} {
		if err := validateIdentity(bad); err == nil {
			t.Errorf("validateIdentity(%q) = nil, want error", bad)
		}
	}
}

func TestCredentialsHandler(t *testing.T) {
	srv, _ := testServer(t, "0123456789abcdef0123456789abcdef", 24*time.Hour)
	srv.now = func() time.Time { return time.Unix(1794591360, 0) }

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/turn-credentials", nil)
	req.RemoteAddr = "203.0.113.7:5555"
	srv.routes().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body %s)", rec.Code, rec.Body.String())
	}
	if got := rec.Header().Get("Cache-Control"); !strings.Contains(got, "no-store") {
		t.Errorf("Cache-Control = %q, want it to contain no-store", got)
	}
	if got := rec.Header().Get("Content-Type"); !strings.HasPrefix(got, "application/json") {
		t.Errorf("Content-Type = %q, want application/json", got)
	}

	var resp credentialsResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode body: %v", err)
	}
	if want := int64(1794591360 + 86400); resp.ExpiresAt != want {
		t.Errorf("expiresAt = %d, want %d", resp.ExpiresAt, want)
	}
	if len(resp.IceServers) != 1 {
		t.Fatalf("got %d ice servers, want 1", len(resp.IceServers))
	}
	ice := resp.IceServers[0]
	if want := []string{
		"turn:13.48.52.216:3478?transport=udp",
		"turns:13.48.52.216:5349?transport=tcp",
	}; strings.Join(ice.URLs, ",") != strings.Join(want, ",") {
		t.Errorf("urls = %v, want %v", ice.URLs, want)
	}
	if !strings.HasSuffix(ice.Username, ":Dohcord") {
		t.Errorf("username = %q, want it to end with :Dohcord", ice.Username)
	}
	expiryFromName, _, err := parseTURNUsername(ice.Username)
	if err != nil {
		t.Fatalf("parse username: %v", err)
	}
	if expiryFromName != resp.ExpiresAt {
		t.Errorf("username timestamp = %d, expiresAt = %d, want equal", expiryFromName, resp.ExpiresAt)
	}
	if len(ice.Credential) != 28 {
		t.Errorf("credential length = %d, want 28 (base64 of a SHA-1 digest)", len(ice.Credential))
	}
	if strings.Contains(rec.Body.String(), "0123456789abcdef") {
		t.Error("response leaked the shared secret")
	}
}

func TestCredentialsHandlerMissingSecret(t *testing.T) {
	srv, _ := testServer(t, "", time.Hour)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/turn-credentials", nil)
	req.RemoteAddr = "198.51.100.9:1234"
	srv.routes().ServeHTTP(rec, req)

	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503 when the catalog secret is missing", rec.Code)
	}
	var body map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode body: %v", err)
	}
	if body["error"] == "" {
		t.Error("expected a clear error message")
	}
}

func TestCredentialsHandlerRejectsOtherMethodsAndPaths(t *testing.T) {
	srv, _ := testServer(t, "0123456789abcdef0123456789abcdef", time.Hour)

	post := httptest.NewRecorder()
	srv.routes().ServeHTTP(post, httptest.NewRequest(http.MethodPost, "/turn-credentials", nil))
	if post.Code != http.StatusMethodNotAllowed {
		t.Errorf("POST status = %d, want 405", post.Code)
	}

	other := httptest.NewRecorder()
	srv.routes().ServeHTTP(other, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if other.Code != http.StatusNotFound {
		t.Errorf("GET /healthz status = %d, want 404 (only /turn-credentials is an API)", other.Code)
	}
}

func TestPerIPRateLimit(t *testing.T) {
	srv, _ := testServer(t, "0123456789abcdef0123456789abcdef", time.Hour)
	srv.perIP = newLimiter(6, 3)

	statuses := make([]int, 0, 5)
	for i := 0; i < 5; i++ {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, "/turn-credentials", nil)
		req.RemoteAddr = "192.0.2.10:9999"
		srv.routes().ServeHTTP(rec, req)
		statuses = append(statuses, rec.Code)
	}

	for i, code := range statuses {
		if i < 3 && code != http.StatusOK {
			t.Errorf("request %d status = %d, want 200 inside the burst", i+1, code)
		}
		if i >= 3 && code != http.StatusTooManyRequests {
			t.Errorf("request %d status = %d, want 429 once the burst is spent", i+1, code)
		}
	}

	other := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/turn-credentials", nil)
	req.RemoteAddr = "192.0.2.11:9999"
	srv.routes().ServeHTTP(other, req)
	if other.Code != http.StatusOK {
		t.Errorf("unrelated address status = %d, want 200 (limits are per address)", other.Code)
	}
}

func TestGlobalRateLimit(t *testing.T) {
	srv, _ := testServer(t, "0123456789abcdef0123456789abcdef", time.Hour)
	srv.global = newLimiter(60, 2)

	codes := make([]int, 0, 3)
	for i := 0; i < 3; i++ {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, "/turn-credentials", nil)
		req.RemoteAddr = fmt.Sprintf("192.0.2.%d:1", i+1)
		srv.routes().ServeHTTP(rec, req)
		codes = append(codes, rec.Code)
	}
	if codes[0] != http.StatusOK || codes[1] != http.StatusOK {
		t.Fatalf("codes = %v, want first two allowed", codes)
	}
	if codes[2] != http.StatusTooManyRequests {
		t.Fatalf("third code = %d, want 429 from the global limit", codes[2])
	}
}

func TestLimiterRefills(t *testing.T) {
	l := newLimiter(60, 1) // one token per second
	now := time.Unix(0, 0)
	if ok, _ := l.allow("a", now); !ok {
		t.Fatal("first request should be allowed")
	}
	if ok, wait := l.allow("a", now); ok || wait <= 0 {
		t.Fatalf("second request should be refused with a wait, got (%v, %v)", ok, wait)
	}
	if ok, _ := l.allow("a", now.Add(2*time.Second)); !ok {
		t.Fatal("request after refill should be allowed")
	}
}

func TestACMEChallengeServing(t *testing.T) {
	srv, _ := testServer(t, "", time.Hour)
	webroot := t.TempDir()
	srv.cfg.acmeWebroot = webroot
	// certbot --webroot places the file under .well-known/acme-challenge.
	challengeDir := filepath.Join(webroot, ".well-known", "acme-challenge")
	if err := os.MkdirAll(challengeDir, 0o755); err != nil {
		t.Fatalf("create challenge dir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(challengeDir, "token-123"), []byte("challenge-body"), 0o644); err != nil {
		t.Fatalf("write challenge: %v", err)
	}

	rec := httptest.NewRecorder()
	srv.acmeRoutes().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/.well-known/acme-challenge/token-123", nil))
	if rec.Code != http.StatusOK || strings.TrimSpace(rec.Body.String()) != "challenge-body" {
		t.Fatalf("got %d %q, want 200 challenge-body", rec.Code, rec.Body.String())
	}

	traversal := httptest.NewRecorder()
	srv.acmeRoutes().ServeHTTP(traversal, httptest.NewRequest(http.MethodGet, "/.well-known/acme-challenge/..%2f..%2fetc%2fpasswd", nil))
	if traversal.Code == http.StatusOK {
		t.Fatal("path traversal must not be served")
	}

	root := httptest.NewRecorder()
	srv.acmeRoutes().ServeHTTP(root, httptest.NewRequest(http.MethodGet, "/turn-credentials", nil))
	if root.Code != http.StatusNotFound {
		t.Errorf("port 80 status = %d, want 404 (HTTP is only for ACME)", root.Code)
	}
}

func TestLoadConfigRejectsBadValues(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.env")

	cases := map[string]string{
		"bad ttl":        "CREDENTIAL_TTL=forever\n",
		"bad url":        "TURN_URLS=http://example.com\n",
		"bad identity":   "TURN_IDENTITY=Doh:cord\n",
		"bad rate":       "PER_IP_RATE_PER_MINUTE=0\n",
		"missing equals": "NONSENSE\n",
	}
	for name, body := range cases {
		if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
			t.Fatalf("write config: %v", err)
		}
		if _, err := loadConfig(path); err == nil {
			t.Errorf("%s: loadConfig accepted invalid config", name)
		}
	}
}

func TestLoadConfigDefaultsAndOverrides(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.env")
	body := strings.Join([]string{
		"# comment",
		"CREDENTIAL_TTL=86400",
		"TURN_IDENTITY=\"Dohcord\"",
		"TURN_URLS=turn:13.48.52.216:3478?transport=udp turns:13.48.52.216:5349?transport=tcp",
		"PER_IP_RATE_PER_MINUTE=12",
	}, "\n")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}

	cfg, err := loadConfig(path)
	if err != nil {
		t.Fatalf("loadConfig: %v", err)
	}
	if cfg.ttl != 24*time.Hour {
		t.Errorf("ttl = %v, want 24h", cfg.ttl)
	}
	if cfg.identity != "Dohcord" {
		t.Errorf("identity = %q, want Dohcord", cfg.identity)
	}
	if len(cfg.turnURLs) != 2 {
		t.Errorf("urls = %v, want 2 entries", cfg.turnURLs)
	}
	if cfg.perIPRate != 12 {
		t.Errorf("perIPRate = %d, want 12", cfg.perIPRate)
	}
}
