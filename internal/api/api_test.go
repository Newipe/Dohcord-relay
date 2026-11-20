package api

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

	"github.com/Newipe/Dohcord-relay/internal/config"
	"github.com/Newipe/Dohcord-relay/internal/credentials"
	"github.com/Newipe/Dohcord-relay/internal/policy"
	"github.com/Newipe/Dohcord-relay/internal/ratelimit"
)

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

func testServer(t *testing.T, secret string, ttl time.Duration) (*Server, string) {
	t.Helper()
	dir := t.TempDir()
	secretPath := filepath.Join(dir, "turn-secret")
	if secret != "" {
		if err := os.WriteFile(secretPath, []byte(secret+"\n"), 0o600); err != nil {
			t.Fatalf("write secret: %v", err)
		}
	}

	domainsPath, policyPath := testPolicyFiles(t)

	cfg := config.Default()
	cfg.SecretFile = secretPath
	cfg.TTL = ttl
	cfg.HTTPSListen = ""
	cfg.HTTPListen = ""
	cfg.ProxyURL = "https://relay.example.test:443"
	cfg.APIURL = "https://relay.example.test:8443/network-config"
	cfg.TurnURLs = []string{
		"turn:relay.example.test:3478?transport=udp",
		"turns:relay.example.test:5349?transport=tcp",
	}
	cfg.AllowedDomainsFile = domainsPath
	cfg.DestinationPolicyFile = policyPath

	logger := log.New(io.Discard, "", 0)
	srv := New(cfg, logger)
	return srv, secretPath
}

func TestCredentialsHandler(t *testing.T) {
	srv, _ := testServer(t, "0123456789abcdef0123456789abcdef", 24*time.Hour)
	srv.now = func() time.Time { return time.Unix(1794591360, 0) }

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/turn-credentials", nil)
	req.RemoteAddr = "203.0.113.7:5555"
	srv.Routes().ServeHTTP(rec, req)

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
	expiryFromName, _, err := credentials.ParseUsername(ice.Username)
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
	srv.Routes().ServeHTTP(rec, req)

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
	if resp.Version != policy.SchemaVersion {
		t.Errorf("version = %d, want %d", resp.Version, policy.SchemaVersion)
	}
	if got, want := resp.HTTPSProxy.URL, "https://relay.example.test:443"; got != want {
		t.Errorf("httpsProxy.url = %q, want %q", got, want)
	}
	if len(resp.HTTPSProxy.AllowedDestinations) != 5 {
		t.Fatalf("got %d destinations, want 5", len(resp.HTTPSProxy.AllowedDestinations))
	}

	// The document must describe exactly what the policy files say.
	var media *policy.Destination
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
	policy, err := policy.LoadPolicy(srv.cfg.AllowedDomainsFile, srv.cfg.DestinationPolicyFile)
	if err != nil {
		t.Fatalf("policy.LoadPolicy: %v", err)
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
	srv.Routes().ServeHTTP(other, httptest.NewRequest(http.MethodGet, "/", nil))
	if other.Code != http.StatusNotFound {
		t.Errorf("GET / = %d, want 404", other.Code)
	}
}

func TestNetworkConfigInvalidPolicyIsRefused(t *testing.T) {
	srv, _ := testServer(t, "0123456789abcdef0123456789abcdef", time.Hour)
	// Add a domain to the allowlist without a port policy: the pair is
	// inconsistent, so the endpoint must not advertise anything.
	f, err := os.OpenFile(srv.cfg.AllowedDomainsFile, os.O_APPEND|os.O_WRONLY, 0o644)
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
	srv.Routes().ServeHTTP(rec, req)

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
	srv.Routes().ServeHTTP(rec, req)

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
	srv.Routes().ServeHTTP(post, httptest.NewRequest(http.MethodPost, "/turn-credentials", nil))
	if post.Code != http.StatusMethodNotAllowed {
		t.Errorf("POST status = %d, want 405", post.Code)
	}

	postConfig := httptest.NewRecorder()
	srv.Routes().ServeHTTP(postConfig, httptest.NewRequest(http.MethodPost, "/network-config", nil))
	if postConfig.Code != http.StatusMethodNotAllowed {
		t.Errorf("POST /network-config status = %d, want 405", postConfig.Code)
	}

	other := httptest.NewRecorder()
	srv.Routes().ServeHTTP(other, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if other.Code != http.StatusNotFound {
		t.Errorf("GET /healthz status = %d, want 404", other.Code)
	}
}

func TestPerIPRateLimit(t *testing.T) {
	srv, _ := testServer(t, "0123456789abcdef0123456789abcdef", time.Hour)
	srv.perIP = ratelimit.New(6, 3)

	statuses := make([]int, 0, 5)
	for i := 0; i < 5; i++ {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, "/network-config", nil)
		req.RemoteAddr = "192.0.2.10:9999"
		srv.Routes().ServeHTTP(rec, req)
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
	srv.Routes().ServeHTTP(other, req)
	if other.Code != http.StatusOK {
		t.Errorf("unrelated address status = %d, want 200 (limits are per address)", other.Code)
	}
}

func TestGlobalRateLimit(t *testing.T) {
	srv, _ := testServer(t, "0123456789abcdef0123456789abcdef", time.Hour)
	srv.global = ratelimit.New(60, 2)

	codes := make([]int, 0, 3)
	for i := 0; i < 3; i++ {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, "/network-config", nil)
		req.RemoteAddr = fmt.Sprintf("192.0.2.%d:1", i+1)
		srv.Routes().ServeHTTP(rec, req)
		codes = append(codes, rec.Code)
	}
	if codes[0] != http.StatusOK || codes[1] != http.StatusOK {
		t.Fatalf("codes = %v, want first two allowed", codes)
	}
	if codes[2] != http.StatusTooManyRequests {
		t.Fatalf("third code = %d, want 429 from the global limit", codes[2])
	}
}

func TestACMEChallengeServing(t *testing.T) {
	srv, _ := testServer(t, "", time.Hour)
	webroot := t.TempDir()
	srv.cfg.ACMEWebroot = webroot
	// certbot --webroot places the file under .well-known/acme-challenge.
	challengeDir := filepath.Join(webroot, ".well-known", "acme-challenge")
	if err := os.MkdirAll(challengeDir, 0o755); err != nil {
		t.Fatalf("create challenge dir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(challengeDir, "token-123"), []byte("challenge-body"), 0o644); err != nil {
		t.Fatalf("write challenge: %v", err)
	}

	rec := httptest.NewRecorder()
	srv.ACMERoutes().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/.well-known/acme-challenge/token-123", nil))
	if rec.Code != http.StatusOK || strings.TrimSpace(rec.Body.String()) != "challenge-body" {
		t.Fatalf("got %d %q, want 200 challenge-body", rec.Code, rec.Body.String())
	}

	traversal := httptest.NewRecorder()
	srv.ACMERoutes().ServeHTTP(traversal, httptest.NewRequest(http.MethodGet, "/.well-known/acme-challenge/..%2f..%2fetc%2fpasswd", nil))
	if traversal.Code == http.StatusOK {
		t.Fatal("path traversal must not be served")
	}

	root := httptest.NewRecorder()
	srv.ACMERoutes().ServeHTTP(root, httptest.NewRequest(http.MethodGet, "/network-config", nil))
	if root.Code != http.StatusNotFound {
		t.Errorf("port 80 status = %d, want 404 (HTTP is only for ACME)", root.Code)
	}
}
