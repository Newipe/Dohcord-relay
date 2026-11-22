package config

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

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
		"api port not a number":      base + "NETWORK_CONFIG_PORT=eighty\n",
		"api port zero":              base + "NETWORK_CONFIG_PORT=0\n",
		"api port too high":          base + "NETWORK_CONFIG_PORT=70000\n",
		"api port mismatch":          base + "NETWORK_CONFIG_PORT=9443\nHTTPS_LISTEN=:8443\n",
		"bad listen address":         base + "HTTPS_LISTEN=nonsense\n",
	}
	for name, body := range cases {
		if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
			t.Fatalf("write config: %v", err)
		}
		if _, err := Load(path); err == nil {
			t.Errorf("%s: Load accepted invalid config", name)
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

	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.TTL != 24*time.Hour {
		t.Errorf("ttl = %v, want 24h", cfg.TTL)
	}
	if cfg.Identity != "Dohcord" {
		t.Errorf("identity = %q, want Dohcord", cfg.Identity)
	}
	if len(cfg.TurnURLs) != 2 {
		t.Errorf("urls = %v, want 2 entries", cfg.TurnURLs)
	}
	if cfg.PerIPRate != 12 {
		t.Errorf("perIPRate = %d, want 12", cfg.PerIPRate)
	}
	if cfg.ProxyURL != "https://relay.example.test:443" {
		t.Errorf("proxyURL = %q", cfg.ProxyURL)
	}
}

func writeConfig(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "config.env")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}
	return path
}

const portTestBase = "HTTPS_PROXY_URL=https://relay.example.test:443\nTURN_URLS=turn:relay.example.test:3478?transport=udp\n"

// TestNetworkConfigPortDefaultsTo8443 covers configurations written before the
// port became configurable: there is no NETWORK_CONFIG_PORT key at all.
func TestNetworkConfigPortDefaultsTo8443(t *testing.T) {
	cfg, err := Load(writeConfig(t, portTestBase))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.NetworkConfigPort != DefaultNetworkConfigPort {
		t.Errorf("port = %d, want %d", cfg.NetworkConfigPort, DefaultNetworkConfigPort)
	}
	if cfg.HTTPSListen != ":8443" {
		t.Errorf("listen = %q, want :8443", cfg.HTTPSListen)
	}
}

func TestNetworkConfigPortCustom(t *testing.T) {
	cfg, err := Load(writeConfig(t, portTestBase+"NETWORK_CONFIG_PORT=9443\n"))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.NetworkConfigPort != 9443 {
		t.Errorf("port = %d, want 9443", cfg.NetworkConfigPort)
	}
	// With no explicit listen address, the configured port is what is bound.
	if cfg.HTTPSListen != ":9443" {
		t.Errorf("listen = %q, want :9443", cfg.HTTPSListen)
	}
}

func TestNetworkConfigPortCustomListenAddress(t *testing.T) {
	cfg, err := Load(writeConfig(t, portTestBase+"NETWORK_CONFIG_PORT=9443\nHTTPS_LISTEN=127.0.0.1:9443\n"))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.HTTPSListen != "127.0.0.1:9443" {
		t.Errorf("listen = %q, want 127.0.0.1:9443", cfg.HTTPSListen)
	}
}

// TestNetworkConfigPortFromLegacyListen covers an upgrade whose configuration
// only has HTTPS_LISTEN: the port in use must be preserved, never reset to 8443.
func TestNetworkConfigPortFromLegacyListen(t *testing.T) {
	cfg, err := Load(writeConfig(t, portTestBase+"HTTPS_LISTEN=:9443\n"))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.NetworkConfigPort != 9443 {
		t.Errorf("port = %d, want 9443 from HTTPS_LISTEN", cfg.NetworkConfigPort)
	}
}

func TestNetworkConfigPortPrinted(t *testing.T) {
	cfg, err := Load(writeConfig(t, portTestBase+"NETWORK_CONFIG_PORT=9443\n"))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	var out bytes.Buffer
	Print(&out, cfg)
	if !strings.Contains(out.String(), "NETWORK_CONFIG_PORT=9443\n") {
		t.Errorf("printed configuration does not include the port:\n%s", out.String())
	}
}

func TestListenPort(t *testing.T) {
	cases := map[string]int{
		"":               0,
		":8443":          8443,
		"127.0.0.1:8443": 8443,
		"[::1]:8443":     8443,
		"8443":           8443,
	}
	for addr, want := range cases {
		got, err := ListenPort(addr)
		if err != nil {
			t.Errorf("ListenPort(%q): %v", addr, err)
			continue
		}
		if got != want {
			t.Errorf("ListenPort(%q) = %d, want %d", addr, got, want)
		}
	}
	for _, addr := range []string{"nonsense", ":0", ":70000", "host:"} {
		if _, err := ListenPort(addr); err == nil {
			t.Errorf("ListenPort(%q) accepted an invalid address", addr)
		}
	}
}

// TestDefaultRequestLimits pins the shipped defaults: several profiles loading at
// once must fit inside one client's burst.
func TestDefaultRequestLimits(t *testing.T) {
	cfg := Default()
	if cfg.PerIPRate != 60 || cfg.PerIPBurst != 30 {
		t.Errorf("per-IP limits = %d/%d, want 60/minute and a burst of 30", cfg.PerIPRate, cfg.PerIPBurst)
	}
	if cfg.GlobalRate != 1200 || cfg.GlobalBurst != 300 {
		t.Errorf("global limits = %d/%d, want 1200/minute and a burst of 300", cfg.GlobalRate, cfg.GlobalBurst)
	}
	if cfg.PerIPBurst < 10 {
		t.Errorf("per-IP burst %d is below the 10 simultaneous profile loads the defaults must cover", cfg.PerIPBurst)
	}
}

// TestRequestLimitBounds rejects values that would disable the limiter or make
// it reject everything, from the file as well as from an in-memory config.
func TestRequestLimitBounds(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.env")
	base := "HTTPS_PROXY_URL=https://relay.example.test:443\nTURN_URLS=turn:relay.example.test:3478\n"

	for key, values := range map[string][]string{
		"PER_IP_RATE_PER_MINUTE": {"0", "-1", "1000001", "fast"},
		"PER_IP_BURST":           {"0", "-5", "1000001", "big"},
		"GLOBAL_RATE_PER_MINUTE": {"0", "1000001"},
		"GLOBAL_BURST":           {"0", "1000001"},
	} {
		for _, v := range values {
			if err := os.WriteFile(path, []byte(base+key+"="+v+"\n"), 0o600); err != nil {
				t.Fatalf("write config: %v", err)
			}
			if _, err := Load(path); err == nil {
				t.Errorf("%s=%s was accepted, want an error", key, v)
			}
		}
	}

	cfg := Default()
	cfg.PerIPBurst = 0
	if err := cfg.Validate(); err == nil {
		t.Error("Validate accepted a zero burst")
	}
}
