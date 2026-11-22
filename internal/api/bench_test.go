package api

import (
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/Newipe/Dohcord-relay/internal/config"
)

// benchServer builds the same server the tests use, with the request limits
// raised so a benchmark measures the handler and not the limiter.
func benchServer(tb testing.TB) *Server {
	tb.Helper()
	dir := tb.TempDir()
	secretPath := filepath.Join(dir, "turn-secret")
	if err := os.WriteFile(secretPath, []byte("0123456789abcdef0123456789abcdef\n"), 0o600); err != nil {
		tb.Fatalf("write secret: %v", err)
	}
	domainsPath, policyPath := testPolicyFiles(tb)

	cfg := config.Default()
	cfg.SecretFile = secretPath
	cfg.TTL = 24 * time.Hour
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
	cfg.PerIPRate = 1000000
	cfg.PerIPBurst = 1000000
	cfg.GlobalRate = 1000000
	cfg.GlobalBurst = 1000000

	return New(cfg, log.New(io.Discard, "", 0))
}

func benchRequest() *http.Request {
	req := httptest.NewRequest(http.MethodGet, "/network-config", nil)
	req.RemoteAddr = "203.0.113.7:5555"
	return req
}

// BenchmarkNetworkConfig measures one request at a time: the number is the cost
// of a single profile fetch.
func BenchmarkNetworkConfig(b *testing.B) {
	srv := benchServer(b)
	h := srv.Routes()
	req := benchRequest()
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			b.Fatalf("status = %d", rec.Code)
		}
	}
}

// BenchmarkNetworkConfigParallel measures concurrent profile loads, which is
// what several Dohcord profiles opening at once actually do.
func BenchmarkNetworkConfigParallel(b *testing.B) {
	srv := benchServer(b)
	h := srv.Routes()
	req := benchRequest()
	b.ReportAllocs()
	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		for pb.Next() {
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)
			if rec.Code != http.StatusOK {
				b.Fatalf("status = %d", rec.Code)
			}
		}
	})
}
