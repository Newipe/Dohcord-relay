package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Newipe/Dohcord-relay/internal/ratelimit"
)

// profileLoad runs one /network-config request from addr and returns the status.
func profileLoad(srv *Server, addr string) int {
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/network-config", nil)
	req.RemoteAddr = addr
	srv.Routes().ServeHTTP(rec, req)
	return rec.Code
}

// TestSimultaneousProfileLoadsFromOneAddress is the case that used to be slow
// and rate limited: several Dohcord profiles (or a client with many accounts)
// loading their configuration at the same moment from one public address.
func TestSimultaneousProfileLoadsFromOneAddress(t *testing.T) {
	srv, _ := testServer(t, "0123456789abcdef0123456789abcdef", time.Hour)
	srv.cfg.PerIPRate = 60
	srv.cfg.PerIPBurst = 30
	srv.perIP = ratelimit.New(60, 30)

	const loads = 25
	var wg sync.WaitGroup
	var limited atomic.Int32
	start := make(chan struct{})
	for i := 0; i < loads; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			if code := profileLoad(srv, "198.51.100.20:4000"); code != http.StatusOK {
				if code == http.StatusTooManyRequests {
					limited.Add(1)
					return
				}
				t.Errorf("status = %d, want 200", code)
			}
		}()
	}
	close(start)
	wg.Wait()

	if n := limited.Load(); n != 0 {
		t.Fatalf("%d of %d simultaneous profile loads were rate limited; the default burst must cover them", n, loads)
	}
}

// TestSimultaneousProfileLoadsFromDifferentAddresses checks that independent
// clients do not consume each other's allowance.
func TestSimultaneousProfileLoadsFromDifferentAddresses(t *testing.T) {
	srv, _ := testServer(t, "0123456789abcdef0123456789abcdef", time.Hour)
	srv.cfg.PerIPRate = 60
	srv.cfg.PerIPBurst = 30
	srv.perIP = ratelimit.New(60, 30)

	const clients = 60
	var wg sync.WaitGroup
	for i := 0; i < clients; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			addr := "203.0.113." + strconv.Itoa(1+i%200) + ":5000"
			if code := profileLoad(srv, addr); code != http.StatusOK {
				t.Errorf("client %d status = %d, want 200", i, code)
			}
		}(i)
	}
	wg.Wait()
}

// TestGenuineRateLimitStillApplies proves the raised defaults do not disable the
// limiter: a client that really exceeds the burst is answered 429 with a
// Retry-After header.
func TestGenuineRateLimitStillApplies(t *testing.T) {
	srv, _ := testServer(t, "0123456789abcdef0123456789abcdef", time.Hour)
	srv.perIP = ratelimit.New(60, 5)

	for i := 0; i < 5; i++ {
		if code := profileLoad(srv, "198.51.100.99:1234"); code != http.StatusOK {
			t.Fatalf("request %d status = %d, want 200 inside the burst", i+1, code)
		}
	}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/network-config", nil)
	req.RemoteAddr = "198.51.100.99:1234"
	srv.Routes().ServeHTTP(rec, req)
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429 after the burst", rec.Code)
	}
	if rec.Header().Get("Retry-After") == "" {
		t.Error("429 response has no Retry-After header")
	}
}

// TestResponseContractAfterOptimization pins the document's structure and field
// order, because clients parse it and must not need an update.
func TestResponseContractAfterOptimization(t *testing.T) {
	srv, _ := testServer(t, "0123456789abcdef0123456789abcdef", time.Hour)
	srv.now = func() time.Time { return time.Unix(1794591360, 0) }

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/network-config", nil)
	req.RemoteAddr = "203.0.113.7:5555"
	srv.Routes().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	body := rec.Body.String()
	// Field order is part of what older clients already receive.
	order := []string{`"schemaVersion"`, `"version"`, `"proxy"`, `"httpsProxy"`, `"routing"`, `"rtcRelay"`}
	last := -1
	for _, field := range order {
		i := strings.Index(body, field)
		if i < 0 {
			t.Fatalf("response has no %s field: %s", field, body)
		}
		if i < last {
			t.Fatalf("field %s moved in the response: %s", field, body)
		}
		last = i
	}
	if !strings.Contains(body, `"routing":{"domains":[`) {
		t.Errorf("routing is not an array of rules: %s", body)
	}
	var doc networkConfig
	if err := json.Unmarshal(rec.Body.Bytes(), &doc); err != nil {
		t.Fatalf("decode body: %v", err)
	}
	if doc.SchemaVersion != 1 || doc.Version != 1 {
		t.Errorf("versions = %d/%d, want 1/1", doc.SchemaVersion, doc.Version)
	}
	if doc.Proxy.Host != "relay.example.test" || doc.Proxy.Port != 443 {
		t.Errorf("proxy = %+v", doc.Proxy)
	}
	if len(doc.HTTPSProxy.AllowedDestinations) != 5 {
		t.Errorf("allowedDestinations = %d entries, want 5", len(doc.HTTPSProxy.AllowedDestinations))
	}
	if len(doc.Routing.Domains) != 5 {
		t.Errorf("routing domains = %d entries, want 5", len(doc.Routing.Domains))
	}
	if len(doc.RTCRelay.IceServers) != 1 || doc.RTCRelay.ExpiresAt == 0 {
		t.Errorf("rtcRelay = %+v", doc.RTCRelay)
	}

	if got := rec.Header().Get("Content-Length"); got == "" {
		t.Error("Content-Length is missing: the body should be written in one piece")
	}
	if got := rec.Header().Get("Cache-Control"); got == "" {
		t.Error("Cache-Control is missing")
	}
}
