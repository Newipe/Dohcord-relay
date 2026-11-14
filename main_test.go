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

// testPolicyFiles writes a small allowlist and port policy and returns their
// paths. The default test policy mirrors the shipped one closely enough to
// exercise root domains, subdomains and a dynamic port range.
func testPolicyFiles(t *testing.T) (domainsPath, policyPath string) {
	t.Helper()
	dir := t.TempDir()
	domainsPath = filepath.Join(dir, "allowed-domains.txt")
	policyPath = filepath.Join(dir, "destination-policy.conf")

	domains := strings.Join([]string{
		"# Discord destinations the relay may reach",
		"discord.com",
		"discord.gg",
		"discordapp.com",
		"discordapp.net",
		"discord.media",
		"",
	}, "\n")
	ports := strings.Join([]string{
		"discord.com       443",
		"discord.gg        443",
		"discordapp.com    443",
		"discordapp.net    443",
		"discord.media     443,1024-65535",
		"",
	}, "\n")

	if err := os.WriteFile(domainsPath, []byte(domains), 0o644); err != nil {
		t.Fatalf("write allowlist: %v", err)
	}
	if err := os.WriteFile(policyPath, []byte(ports), 0o644); err != nil {
		t.Fatalf("write port policy: %v", err)
	}
	return domainsPath, policyPath
}

func testServer(t *testing.T, secret string, ttl time.Duration) (*server, string) {
	t.Helper()
	dir := t.TempDir()
	secretPath := filepath.Join(dir, "turn-secret")
	if secret != "" {
		if err := os.WriteFile(secretPath, []byte(secret+"\n"), 0o600); err != nil {
			t.Fatalf("write secret: %v", err)
		}
	}

	domainsPath, policyPath := testPolicyFiles(t)

	cfg := defaultConfig()
	cfg.secretFile = secretPath
	cfg.ttl = ttl
	cfg.httpsListen = ""
	cfg.httpListen = ""
	cfg.proxyURL = "https://relay.example.test:443"
	cfg.apiURL = "https://relay.example.test:8443/network-config"
	cfg.turnURLs = []string{
		"turn:relay.example.test:3478?transport=udp",
		"turns:relay.example.test:5349?transport=tcp",
	}
	cfg.allowedDomainsFile = domainsPath
	cfg.destinationPolicyFile = policyPath

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
		"turn:relay.example.test:3478?transport=udp",
		"turns:relay.example.test:5349?transport=tcp",
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

func TestNetworkConfigHandler(t *testing.T) {
	srv, _ := testServer(t, "0123456789abcdef0123456789abcdef", 24*time.Hour)
	srv.now = func() time.Time { return time.Unix(1794591360, 0) }

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/network-config", nil)
	req.RemoteAddr = "203.0.113.7:5555"
	srv.routes().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body %s)", rec.Code, rec.Body.String())
	}
	if got := rec.Header().Get("Cache-Control"); !strings.Contains(got, "no-store") {
		t.Errorf("Cache-Control = %q, want no-store", got)
	}

	var resp networkConfig
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode body: %v", err)
	}
	if resp.Version != schemaVersion {
		t.Errorf("version = %d, want %d", resp.Version, schemaVersion)
	}
	if got, want := resp.HTTPSProxy.URL, "https://relay.example.test:443"; got != want {
		t.Errorf("httpsProxy.url = %q, want %q", got, want)
	}
	if len(resp.HTTPSProxy.AllowedDestinations) != 5 {
		t.Fatalf("got %d destinations, want 5", len(resp.HTTPSProxy.AllowedDestinations))
	}

	// The document must describe exactly what the policy files say.
	var media *Destination
	for i := range resp.HTTPSProxy.AllowedDestinations {
		if resp.HTTPSProxy.AllowedDestinations[i].Domain == "discord.media" {
			media = &resp.HTTPSProxy.AllowedDestinations[i]
		}
	}
	if media == nil {
		t.Fatalf("discord.media missing from the advertised policy: %+v", resp.HTTPSProxy.AllowedDestinations)
	}
	if len(media.Ports) != 1 || media.Ports[0] != 443 {
		t.Errorf("discord.media ports = %v, want [443]", media.Ports)
	}
	if len(media.PortRanges) != 1 || media.PortRanges[0].From != 1024 || media.PortRanges[0].To != 65535 {
		t.Errorf("discord.media portRanges = %v, want 1024-65535", media.PortRanges)
	}

	if resp.RTCRelay.ExpiresAt != 1794591360+86400 {
		t.Errorf("expiresAt = %d, want %d", resp.RTCRelay.ExpiresAt, 1794591360+86400)
	}
	if len(resp.RTCRelay.IceServers) != 1 || len(resp.RTCRelay.IceServers[0].Credential) != 28 {
		t.Errorf("unexpected iceServers: %+v", resp.RTCRelay.IceServers)
	}
	if strings.Contains(rec.Body.String(), "0123456789abcdef") {
		t.Error("response leaked the shared secret")
	}

	// The advertised policy must agree with an independent load of the files.
	policy, err := LoadPolicy(srv.cfg.allowedDomainsFile, srv.cfg.destinationPolicyFile)
	if err != nil {
		t.Fatalf("LoadPolicy: %v", err)
	}
	stored, err := json.Marshal(resp.HTTPSProxy.AllowedDestinations)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	want, err := json.Marshal(policy.Destinations)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if string(stored) != string(want) {
		t.Errorf("advertised policy %s != authoritative policy %s", stored, want)
	}

	// Only the documented endpoints exist.
	other := httptest.NewRecorder()
	srv.routes().ServeHTTP(other, httptest.NewRequest(http.MethodGet, "/", nil))
	if other.Code != http.StatusNotFound {
		t.Errorf("GET / = %d, want 404", other.Code)
	}
}

func TestNetworkConfigInvalidPolicyIsRefused(t *testing.T) {
	srv, _ := testServer(t, "0123456789abcdef0123456789abcdef", time.Hour)
	// Add a domain to the allowlist without a port policy: the pair is
	// inconsistent, so the endpoint must not advertise anything.
	f, err := os.OpenFile(srv.cfg.allowedDomainsFile, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatalf("open allowlist: %v", err)
	}
	if _, err := f.WriteString("example.com\n"); err != nil {
		t.Fatalf("append allowlist: %v", err)
	}
	f.Close()

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/network-config", nil)
	req.RemoteAddr = "198.51.100.4:1234"
	srv.routes().ServeHTTP(rec, req)

	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503 for an inconsistent policy (body %s)", rec.Code, rec.Body.String())
	}
	if strings.Contains(rec.Body.String(), "example.com") {
		t.Error("error response should not echo the policy contents")
	}
}

func TestCredentialsHandlerMissingSecret(t *testing.T) {
	srv, _ := testServer(t, "", time.Hour)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/turn-credentials", nil)
	req.RemoteAddr = "198.51.100.9:1234"
	srv.routes().ServeHTTP(rec, req)

	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503 when the secret is missing", rec.Code)
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

	postConfig := httptest.NewRecorder()
	srv.routes().ServeHTTP(postConfig, httptest.NewRequest(http.MethodPost, "/network-config", nil))
	if postConfig.Code != http.StatusMethodNotAllowed {
		t.Errorf("POST /network-config status = %d, want 405", postConfig.Code)
	}

	other := httptest.NewRecorder()
	srv.routes().ServeHTTP(other, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if other.Code != http.StatusNotFound {
		t.Errorf("GET /healthz status = %d, want 404", other.Code)
	}
}

func TestPerIPRateLimit(t *testing.T) {
	srv, _ := testServer(t, "0123456789abcdef0123456789abcdef", time.Hour)
	srv.perIP = newLimiter(6, 3)

	statuses := make([]int, 0, 5)
	for i := 0; i < 5; i++ {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, "/network-config", nil)
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
	req := httptest.NewRequest(http.MethodGet, "/network-config", nil)
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
		req := httptest.NewRequest(http.MethodGet, "/network-config", nil)
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
	srv.acmeRoutes().ServeHTTP(root, httptest.NewRequest(http.MethodGet, "/network-config", nil))
	if root.Code != http.StatusNotFound {
		t.Errorf("port 80 status = %d, want 404 (HTTP is only for ACME)", root.Code)
	}
}

func TestLoadConfigRejectsBadValues(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.env")

	base := "HTTPS_PROXY_URL=https://relay.example.test:443\nTURN_URLS=turn:relay.example.test:3478?transport=udp\n"
	cases := map[string]string{
		"bad ttl":                    base + "CREDENTIAL_TTL=forever\n",
		"bad url":                    base + "TURN_URLS=http://example.com\n",
		"bad identity":               base + "TURN_IDENTITY=Doh:cord\n",
		"bad rate":                   base + "PER_IP_RATE_PER_MINUTE=0\n",
		"missing equals":             "NONSENSE\n",
		"http proxy url":             "HTTPS_PROXY_URL=http://relay.example.test:443\nTURN_URLS=turn:x:3478\n",
		"proxy url with credentials": "HTTPS_PROXY_URL=https://user:pass@relay.example.test:443\nTURN_URLS=turn:x:3478\n",
		"missing proxy url":          "TURN_URLS=turn:relay.example.test:3478\n",
		"api on 443":                 base + "HTTPS_LISTEN=:443\n",
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
		"TURN_URLS=turn:relay.example.test:3478?transport=udp turns:relay.example.test:5349?transport=tcp",
		"HTTPS_PROXY_URL=https://relay.example.test:443",
		"NETWORK_CONFIG_URL=https://relay.example.test:8443/network-config",
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
	if cfg.proxyURL != "https://relay.example.test:443" {
		t.Errorf("proxyURL = %q", cfg.proxyURL)
	}
}
