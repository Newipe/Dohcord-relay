package main

import (
	"encoding/json"
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

// serverWithPolicy builds a server whose policy comes from the given file
// contents, so a test can change the canonical policy and re-read it.
func serverWithPolicy(t *testing.T, domains, ports string) (*server, string, string) {
	t.Helper()
	dir := t.TempDir()
	domainsPath := filepath.Join(dir, "allowed-domains.txt")
	policyPath := filepath.Join(dir, "destination-policy.conf")
	writeFile(t, domainsPath, domains)
	writeFile(t, policyPath, ports)
	secretPath := filepath.Join(dir, "turn-secret")
	writeFile(t, secretPath, "dohcord-test-secret\n")

	cfg := defaultConfig()
	cfg.secretFile = secretPath
	cfg.ttl = 24 * time.Hour
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
	cfg.policyStateFile = filepath.Join(dir, "policy.json")
	return newServer(cfg, log.New(io.Discard, "", 0)), domainsPath, policyPath
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

// networkConfigDocument mirrors the published schema so tests fail if a field
// is renamed or dropped.
type networkConfigDocument struct {
	SchemaVersion int `json:"schemaVersion"`
	Version       int `json:"version"`
	Proxy         struct {
		Scheme string `json:"scheme"`
		Host   string `json:"host"`
		Port   int    `json:"port"`
	} `json:"proxy"`
	HTTPSProxy struct {
		URL                 string        `json:"url"`
		AllowedDestinations []Destination `json:"allowedDestinations"`
	} `json:"httpsProxy"`
	Routing struct {
		Domains []RoutingRule `json:"domains"`
	} `json:"routing"`
	RTCRelay struct {
		ExpiresAt  int64       `json:"expiresAt"`
		IceServers []iceServer `json:"iceServers"`
	} `json:"rtcRelay"`
}

func fetchNetworkConfig(t *testing.T, srv *server) (*httptest.ResponseRecorder, networkConfigDocument) {
	t.Helper()
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/network-config", nil)
	req.RemoteAddr = "203.0.113.9:4444"
	srv.routes().ServeHTTP(rec, req)

	var doc networkConfigDocument
	if rec.Code == http.StatusOK {
		if err := json.Unmarshal(rec.Body.Bytes(), &doc); err != nil {
			t.Fatalf("decode body: %v (%s)", err, rec.Body.String())
		}
	}
	return rec, doc
}

// ruleFor returns the routing rule for host.
func ruleFor(t *testing.T, rules []RoutingRule, host string) RoutingRule {
	t.Helper()
	for _, r := range rules {
		if r.Host == host {
			return r
		}
	}
	t.Fatalf("no routing rule for %q in %+v", host, rules)
	return RoutingRule{}
}

// TestRoutingContract checks the documented response: schema version, the proxy
// endpoint (443, not the 8443 configuration port), the routing rules with their
// matching mode and ports, and the fields older clients already use.
func TestRoutingContract(t *testing.T) {
	srv, _ := testServer(t, "dohcord-test-secret", 24*time.Hour)
	rec, doc := fetchNetworkConfig(t, srv)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (%s)", rec.Code, rec.Body.String())
	}
	if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
		t.Errorf("Content-Type = %q, want application/json", ct)
	}
	if cc := rec.Header().Get("Cache-Control"); !strings.Contains(cc, "no-store") {
		t.Errorf("Cache-Control = %q, want no-store so policy changes are not cached", cc)
	}

	if doc.SchemaVersion != schemaVersion {
		t.Errorf("schemaVersion = %d, want %d", doc.SchemaVersion, schemaVersion)
	}
	if doc.Version != schemaVersion {
		t.Errorf("version = %d, want %d (older clients read this field)", doc.Version, schemaVersion)
	}

	// The proxy endpoint and the configuration endpoint are different things.
	if doc.Proxy.Scheme != "https" {
		t.Errorf("proxy.scheme = %q, want https", doc.Proxy.Scheme)
	}
	if doc.Proxy.Host != "relay.example.test" {
		t.Errorf("proxy.host = %q", doc.Proxy.Host)
	}
	if doc.Proxy.Port != 443 {
		t.Errorf("proxy.port = %d, want 443", doc.Proxy.Port)
	}
	if doc.Proxy.Port == 8443 {
		t.Error("proxy.port must not be the network-configuration port")
	}

	if got, want := len(doc.Routing.Domains), 5; got != want {
		t.Fatalf("routing.domains = %d, want %d", got, want)
	}
	for _, r := range doc.Routing.Domains {
		if r.Match != matchSuffix && r.Match != matchExact {
			t.Errorf("%s has unknown match mode %q", r.Host, r.Match)
		}
		if len(r.Ports) == 0 {
			t.Errorf("%s publishes no ports", r.Host)
		}
	}

	// A single port is from == to; a range keeps its real boundaries.
	discord := ruleFor(t, doc.Routing.Domains, "discord.com")
	if discord.Match != matchSuffix {
		t.Errorf("discord.com match = %q, want suffix", discord.Match)
	}
	if len(discord.Ports) != 1 || discord.Ports[0] != (PortRange{From: 443, To: 443}) {
		t.Errorf("discord.com ports = %+v, want [{443 443}]", discord.Ports)
	}
	media := ruleFor(t, doc.Routing.Domains, "discord.media")
	want := []PortRange{{From: 443, To: 443}, {From: 1024, To: 65535}}
	if len(media.Ports) != len(want) {
		t.Fatalf("discord.media ports = %+v, want %+v", media.Ports, want)
	}
	for i := range want {
		if media.Ports[i] != want[i] {
			t.Errorf("discord.media ports[%d] = %+v, want %+v", i, media.Ports[i], want[i])
		}
	}

	// Existing fields are still published.
	if got, want := doc.HTTPSProxy.URL, "https://relay.example.test:443"; got != want {
		t.Errorf("httpsProxy.url = %q, want %q", got, want)
	}
	if got, want := len(doc.HTTPSProxy.AllowedDestinations), 5; got != want {
		t.Errorf("httpsProxy.allowedDestinations = %d, want %d", got, want)
	}
	if doc.RTCRelay.ExpiresAt == 0 || len(doc.RTCRelay.IceServers) == 0 {
		t.Errorf("rtcRelay missing from the response: %+v", doc.RTCRelay)
	}
	if u := doc.RTCRelay.IceServers[0].URLs; len(u) != 2 || doc.RTCRelay.IceServers[0].Credential == "" {
		t.Errorf("rtcRelay credentials incomplete: %+v", doc.RTCRelay.IceServers[0])
	}
}

// TestRoutingMatchingSemantics checks that exact rules stay exact and suffix
// rules keep strict label-boundary matching, both in the published rules and in
// the Squid ACLs generated from the same policy.
func TestRoutingMatchingSemantics(t *testing.T) {
	const uploads = "uploads.example.com"
	domains := "discord.com\n=" + uploads + "\n"
	ports := "discord.com 443\n=" + uploads + " 443\n"
	srv, domainsPath, policyPath := serverWithPolicy(t, domains, ports)

	_, doc := fetchNetworkConfig(t, srv)
	if got := ruleFor(t, doc.Routing.Domains, uploads).Match; got != matchExact {
		t.Errorf("exact entry match = %q, want %q", got, matchExact)
	}
	suffix := ruleFor(t, doc.Routing.Domains, "discord.com")
	if suffix.Match != matchSuffix {
		t.Errorf("plain entry match = %q, want %q", suffix.Match, matchSuffix)
	}

	if !suffix.Matches("discord.com") || !suffix.Matches("gateway.discord.com") {
		t.Error("suffix rule does not match its own host and a subdomain")
	}
	for _, host := range []string{"notdiscord.com", "discord.com.example.org", "evil-discord.com"} {
		if suffix.Matches(host) {
			t.Errorf("suffix rule matched %q", host)
		}
	}
	exact := ruleFor(t, doc.Routing.Domains, uploads)
	if !exact.Matches(uploads) {
		t.Error("exact rule does not match its own host")
	}
	if exact.Matches("sub." + uploads) {
		t.Error("exact rule matched a subdomain")
	}

	policy, err := LoadPolicy(domainsPath, policyPath)
	if err != nil {
		t.Fatalf("LoadPolicy: %v", err)
	}
	acl := policy.SquidACL()
	if !strings.Contains(acl, "dstdomain "+uploads+"\n") {
		t.Errorf("exact host is not an exact dstdomain:\n%s", acl)
	}
	if strings.Contains(acl, "dstdomain ."+uploads) {
		t.Errorf("exact host was widened to its subdomains:\n%s", acl)
	}
	if !strings.Contains(acl, "dstdomain .discord.com\n") {
		t.Errorf("suffix host is not a subdomain dstdomain:\n%s", acl)
	}
	// Routing and ACL must agree for every host/mode pair tested above.
	for _, host := range []string{"discord.com", "gateway.discord.com", uploads, "sub." + uploads} {
		if policy.Allows(host, 443) != (suffix.Matches(host) || exact.Matches(host)) {
			t.Errorf("policy.Allows(%q) disagrees with the published routing rules", host)
		}
	}
}

// TestRoutingMatchesSquidACL checks that the published rules and the generated
// Squid authorization cover exactly the same hosts and ports.
func TestRoutingMatchesSquidACL(t *testing.T) {
	domains := "discord.com\ndiscord.media\n=uploads.example.com\n"
	ports := "discord.com 443\ndiscord.media 443,1024-65535\n=uploads.example.com 443\n"
	_, domainsPath, policyPath := serverWithPolicy(t, domains, ports)

	policy, err := LoadPolicy(domainsPath, policyPath)
	if err != nil {
		t.Fatalf("LoadPolicy: %v", err)
	}
	rules := policy.RoutingRules()
	acl := policy.SquidACL()

	if got := strings.Count(acl, "http_access allow CONNECT"); got != len(rules) {
		t.Errorf("%d allow rules in the ACL but %d routing rules published", got, len(rules))
	}
	for _, r := range rules {
		scope := r.Host
		if r.Match == matchSuffix {
			scope = "." + r.Host
		}
		if !strings.Contains(acl, "dstdomain "+scope+"\n") {
			t.Errorf("ACL has no dstdomain %s for routing rule %+v", scope, r)
		}
		var spec []string
		for _, p := range r.Ports {
			if p.From == p.To {
				spec = append(spec, itoa(p.From))
			} else {
				spec = append(spec, itoa(p.From)+"-"+itoa(p.To))
			}
		}
		if !strings.Contains(acl, "port "+strings.Join(spec, " ")+"\n") {
			t.Errorf("ACL has no port rule %q for %s:\n%s", strings.Join(spec, " "), r.Host, acl)
		}
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	return string(b)
}

// TestRoutingTracksPolicyChanges adds and removes a domain in the canonical
// policy files and checks the endpoint follows, without any second list.
func TestRoutingTracksPolicyChanges(t *testing.T) {
	domains := "discord.com\n"
	ports := "discord.com 443\n"
	srv, domainsPath, policyPath := serverWithPolicy(t, domains, ports)

	_, before := fetchNetworkConfig(t, srv)
	if len(before.Routing.Domains) != 1 {
		t.Fatalf("initial routing rules = %d, want 1", len(before.Routing.Domains))
	}

	// Add a domain, as an operator would.
	writeFile(t, domainsPath, "discord.com\nexample.com\n")
	writeFile(t, policyPath, "discord.com 443\nexample.com 443,2053\n")
	bumpModTime(t, domainsPath, policyPath)

	_, added := fetchNetworkConfig(t, srv)
	if len(added.Routing.Domains) != 2 {
		t.Fatalf("after adding: routing rules = %d, want 2", len(added.Routing.Domains))
	}
	rule := ruleFor(t, added.Routing.Domains, "example.com")
	wantPorts := []PortRange{{From: 443, To: 443}, {From: 2053, To: 2053}}
	if len(rule.Ports) != 2 || rule.Ports[0] != wantPorts[0] || rule.Ports[1] != wantPorts[1] {
		t.Errorf("example.com ports = %+v, want %+v", rule.Ports, wantPorts)
	}

	// Remove it again.
	writeFile(t, domainsPath, "discord.com\n")
	writeFile(t, policyPath, "discord.com 443\n")
	bumpModTime(t, domainsPath, policyPath)

	_, removed := fetchNetworkConfig(t, srv)
	if len(removed.Routing.Domains) != 1 || removed.Routing.Domains[0].Host != "discord.com" {
		t.Errorf("after removing: routing rules = %+v, want only discord.com", removed.Routing.Domains)
	}
}

func bumpModTime(t *testing.T, paths ...string) {
	t.Helper()
	future := time.Now().Add(2 * time.Second)
	for _, p := range paths {
		if err := os.Chtimes(p, future, future); err != nil {
			t.Fatalf("chtimes %s: %v", p, err)
		}
	}
}

// TestRoutingRefusesBrokenConfiguration makes sure an incomplete policy is an
// error, never a successful response with partial routing data.
func TestRoutingRefusesBrokenConfiguration(t *testing.T) {
	srv, domainsPath, policyPath := serverWithPolicy(t, "discord.com\n", "discord.com 443\n")

	// A domain with no port policy: the pair no longer validates.
	writeFile(t, domainsPath, "discord.com\nexample.com\n")
	bumpModTime(t, domainsPath, policyPath)

	rec, _ := fetchNetworkConfig(t, srv)
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503 for an invalid policy", rec.Code)
	}
	if body := rec.Body.String(); strings.Contains(body, "routing") || strings.Contains(body, "discord.com") {
		t.Errorf("a failed policy leaked routing data: %s", body)
	}
}

// TestRoutingRefusesUnsupportedState rejects a policy state file written by a
// different schema version instead of publishing it.
func TestRoutingRefusesUnsupportedState(t *testing.T) {
	srv, _, _ := serverWithPolicy(t, "discord.com\n", "discord.com 443\n")
	state := `{"version": 99, "destinations": [{"domain": "discord.com", "ports": [443]}]}`
	writeFile(t, srv.cfg.policyStateFile, state)

	rec, _ := fetchNetworkConfig(t, srv)
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503 for an unsupported state schema", rec.Code)
	}
}

// TestProxyEndpointValidation keeps an unusable proxy URL from being published.
func TestProxyEndpointValidation(t *testing.T) {
	for _, raw := range []string{"https://relay.example.test:0", "https://relay.example.test:70000"} {
		if _, err := endpointFromURL(raw); err == nil {
			t.Errorf("endpointFromURL(%q) succeeded, want an error", raw)
		}
	}

	cfg := defaultConfig()
	cfg.proxyURL = "https://relay.example.test:70000"
	if err := cfg.validate(); err == nil {
		t.Error("validate() accepted a proxy URL with an invalid port")
	}

	// Even if validation were bypassed, the handler must not publish routing data
	// with a missing proxy endpoint.
	srv, _, _ := serverWithPolicy(t, "discord.com\n", "discord.com 443\n")
	srv.cfg.proxyURL = "not a url"
	rec, _ := fetchNetworkConfig(t, srv)
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503 for an unusable proxy URL", rec.Code)
	}
	if strings.Contains(rec.Body.String(), "routing") {
		t.Errorf("routing data was published with a broken proxy URL: %s", rec.Body.String())
	}

	// A URL without an explicit port is the normal 443 case.
	ep, err := endpointFromURL("https://relay.example.test")
	if err != nil || ep.Port != 443 || ep.Scheme != "https" {
		t.Errorf("endpointFromURL without a port = %+v, %v", ep, err)
	}
}

// TestRoutingFromAppliedState is the integration path: one policy produces both
// the Squid ACLs and the state file the endpoint serves, and the two agree.
func TestRoutingFromAppliedState(t *testing.T) {
	domains := "discord.com\n=uploads.example.com\n"
	ports := "discord.com 443\n=uploads.example.com 443\n"
	srv, domainsPath, policyPath := serverWithPolicy(t, domains, ports)

	policy, err := LoadPolicy(domainsPath, policyPath)
	if err != nil {
		t.Fatalf("LoadPolicy: %v", err)
	}
	// What -policy-apply does: render the ACL include and save the state.
	acl := policy.SquidACL()
	if err := SavePolicyState(srv.cfg.policyStateFile, policy); err != nil {
		t.Fatalf("SavePolicyState: %v", err)
	}

	_, doc := fetchNetworkConfig(t, srv)
	if got := len(doc.Routing.Domains); got != 2 {
		t.Fatalf("routing rules = %d, want 2", got)
	}
	for _, r := range doc.Routing.Domains {
		scope := r.Host
		if r.Match == matchSuffix {
			scope = "." + r.Host
		}
		if !strings.Contains(acl, "dstdomain "+scope+"\n") {
			t.Errorf("published rule %s (%s) has no matching Squid authorization", r.Host, r.Match)
		}
	}
	// And the endpoint must not advertise anything Squid does not allow.
	rules := policy.RoutingRules()
	if len(rules) != strings.Count(acl, "http_access allow CONNECT") {
		t.Errorf("published %d rules, Squid allows %d destinations", len(rules), strings.Count(acl, "http_access allow CONNECT"))
	}
}
