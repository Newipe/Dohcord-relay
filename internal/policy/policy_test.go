package policy

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeFiles(t *testing.T, domains, ports string) (string, string) {
	t.Helper()
	dir := t.TempDir()
	d := filepath.Join(dir, "allowed-domains.txt")
	p := filepath.Join(dir, "destination-policy.conf")
	if err := os.WriteFile(d, []byte(domains), 0o644); err != nil {
		t.Fatalf("write domains: %v", err)
	}
	if err := os.WriteFile(p, []byte(ports), 0o644); err != nil {
		t.Fatalf("write ports: %v", err)
	}
	return d, p
}

func TestLoadPolicyValid(t *testing.T) {
	d, p := writeFiles(t, "discord.media\nDiscord.com  # trailing comment\n", "discord.com 443\ndiscord.media 443,1024-65535\n")
	policy, err := LoadPolicy(d, p)
	if err != nil {
		t.Fatalf("LoadPolicy: %v", err)
	}
	if len(policy.Destinations) != 2 {
		t.Fatalf("got %d destinations, want 2", len(policy.Destinations))
	}
	// Domains are normalised and sorted.
	if policy.Destinations[0].Domain != "discord.com" || policy.Destinations[1].Domain != "discord.media" {
		t.Fatalf("unexpected order: %+v", policy.Destinations)
	}
	if got := policy.Destinations[1].PortList(); got != "443 1024-65535" {
		t.Errorf("PortList = %q", got)
	}
}

func TestLoadPolicyRejects(t *testing.T) {
	cases := map[string]struct{ domains, ports string }{
		"empty allowlist":       {"# nothing\n", "discord.com 443\n"},
		"empty policy":          {"discord.com\n", "# nothing\n"},
		"domain without policy": {"discord.com\nexample.com\n", "discord.com 443\n"},
		"policy without domain": {"discord.com\n", "discord.com 443\nexample.com 443\n"},
		"duplicate domain":      {"discord.com\ndiscord.com\n", "discord.com 443\n"},
		"ip literal":            {"1.2.3.4\n", "1.2.3.4 443\n"},
		"wildcard":              {"*.discord.com\n", "*.discord.com 443\n"},
		"scheme":                {"https://discord.com\n", "discord.com 443\n"},
		"domain with port":      {"discord.com:443\n", "discord.com 443\n"},
		"port out of range":     {"discord.com\n", "discord.com 70000\n"},
		"zero port":             {"discord.com\n", "discord.com 0\n"},
		"reversed range":        {"discord.com\n", "discord.com 2000-1000\n"},
		"overlapping ports":     {"discord.com\n", "discord.com 443,400-500\n"},
		"duplicate port":        {"discord.com\n", "discord.com 443,443\n"},
		"missing ports":         {"discord.com\n", "discord.com\n"},
		"junk after ports":      {"discord.com\n", "discord.com 443 extra\n"},
		"underscore in domain":  {"my_host.com\n", "my_host.com 443\n"},
		"single label":          {"localhost\n", "localhost 443\n"},
	}
	for name, c := range cases {
		d, p := writeFiles(t, c.domains, c.ports)
		if _, err := LoadPolicy(d, p); err == nil {
			t.Errorf("%s: LoadPolicy accepted invalid input", name)
		}
	}
}

// TestPolicyAllowsDomainBoundaries is the allowlist boundary test the README
// documents: a suffix match must be a DNS label boundary, never a substring.
func TestPolicyAllowsDomainBoundaries(t *testing.T) {
	d, p := writeFiles(t,
		"discord.com\ndiscordapp.com\ndiscord.media\n",
		"discord.com 443\ndiscordapp.com 443\ndiscord.media 443,1024-65535\n")
	policy, err := LoadPolicy(d, p)
	if err != nil {
		t.Fatalf("LoadPolicy: %v", err)
	}

	allow := []struct {
		host string
		port int
	}{
		{"discord.com", 443},
		{"gateway.discord.com", 443},
		{"cdn.discordapp.com", 443},
		{"a.b.discordapp.com", 443},
		{"discordapp.com", 443},
		{"sweetwater-12345.discord.media", 2048},
		{"discord.media", 443},
		{"discord.media", 65535},
		{"DISCORD.MEDIA", 443}, // normalised
	}
	for _, c := range allow {
		if !policy.Allows(c.host, c.port) {
			t.Errorf("Allows(%q, %d) = false, want true", c.host, c.port)
		}
	}

	deny := []struct {
		host string
		port int
	}{
		{"discord.com.evil.example", 443},
		{"evil-discord.com", 443},
		{"example.com", 443},
		{"notdiscord.com", 443},
		{"discord.com", 80},
		{"discord.com", 4443},
		{"gateway.discord.com", 2048}, // dynamic ports are discord.media only
		{"discord.gg", 443},           // not in the allowlist at all
		{"1.2.3.4", 443},
		{"127.0.0.1", 443},
		{"", 443},
		{"discord.media", 80},
		{"discord.media", 65536},
	}
	for _, c := range deny {
		if policy.Allows(c.host, c.port) {
			t.Errorf("Allows(%q, %d) = true, want false", c.host, c.port)
		}
	}
}

func TestSquidACL(t *testing.T) {
	d, p := writeFiles(t, "discord.com\ndiscord.media\n", "discord.com 443\ndiscord.media 443,1024-65535\n")
	policy, err := LoadPolicy(d, p)
	if err != nil {
		t.Fatalf("LoadPolicy: %v", err)
	}
	out := policy.SquidACL()

	for _, want := range []string{
		"acl dohcord_domain_0 dstdomain .discord.com",
		"acl dohcord_ports_0 port 443",
		"http_access allow CONNECT dohcord_domain_0 dohcord_ports_0",
		"acl dohcord_domain_1 dstdomain .discord.media",
		"acl dohcord_ports_1 port 443 1024-65535",
		"http_access allow CONNECT dohcord_domain_1 dohcord_ports_1",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("generated ACL is missing %q\n%s", want, out)
		}
	}
	// Nothing may be allowed unconditionally.
	if strings.Contains(out, "http_access allow CONNECT all") || strings.Contains(out, "http_access allow all") {
		t.Error("generated ACL contains an unconditional allow")
	}
	for _, line := range strings.Split(out, "\n") {
		if strings.HasPrefix(line, "http_access allow") && !strings.Contains(line, "dohcord_domain_") {
			t.Errorf("unexpected allow rule: %q", line)
		}
	}
	// Every allow rule must constrain both the domain and the port.
	for _, line := range strings.Split(out, "\n") {
		if strings.HasPrefix(line, "http_access allow") {
			if !strings.Contains(line, "dohcord_domain_") || !strings.Contains(line, "dohcord_ports_") {
				t.Errorf("allow rule does not constrain domain and port: %q", line)
			}
		}
	}
}

func TestPolicyStateRoundTrip(t *testing.T) {
	d, p := writeFiles(t, "discord.com\ndiscord.media\n", "discord.com 443\ndiscord.media 443,1024-65535\n")
	policy, err := LoadPolicy(d, p)
	if err != nil {
		t.Fatalf("LoadPolicy: %v", err)
	}
	path := filepath.Join(t.TempDir(), "policy.json")
	if err := SavePolicyState(path, policy); err != nil {
		t.Fatalf("SavePolicyState: %v", err)
	}
	loaded, err := loadPolicyState(path)
	if err != nil {
		t.Fatalf("loadPolicyState: %v", err)
	}
	if len(loaded.Destinations) != len(policy.Destinations) {
		t.Fatalf("round trip lost destinations: %+v", loaded.Destinations)
	}
	for i := range loaded.Destinations {
		if loaded.Destinations[i].Domain != policy.Destinations[i].Domain {
			t.Errorf("destination %d = %q, want %q", i, loaded.Destinations[i].Domain, policy.Destinations[i].Domain)
		}
	}
	if loaded.GeneratedAt == "" {
		t.Error("GeneratedAt was not set")
	}
}

// TestPolicyCachePrefersStateFile proves the endpoint serves what the policy
// command applied, not a newer, unapplied edit of the source files.
func TestPolicyCachePrefersStateFile(t *testing.T) {
	d, p := writeFiles(t, "discord.com\n", "discord.com 443\n")
	state := filepath.Join(t.TempDir(), "policy.json")

	applied := &Policy{Version: SchemaVersion, Destinations: []Destination{
		{Domain: "discord.com", Ports: []int{443}},
	}}
	if err := SavePolicyState(state, applied); err != nil {
		t.Fatalf("SavePolicyState: %v", err)
	}
	cache := &Cache{DomainsPath: d, PolicyPath: p, StatePath: state}

	got, err := cache.Get()
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if len(got.Destinations) != 1 || got.Destinations[0].Domain != "discord.com" {
		t.Fatalf("unexpected policy: %+v", got.Destinations)
	}
	if !got.Allows("gateway.discord.com", 443) {
		t.Error("state policy should allow gateway.discord.com:443")
	}

	if err := os.Remove(state); err != nil {
		t.Fatalf("remove state: %v", err)
	}
	got, err = cache.Get()
	if err != nil {
		t.Fatalf("get after removing state: %v", err)
	}
	if len(got.Destinations) != 1 {
		t.Fatalf("unexpected policy after falling back to sources: %+v", got.Destinations)
	}
}

// TestExactDestination covers the '=' prefix: the host is allowed on its own
// name only, which is what keeps an exact Cloud Storage endpoint from widening
// to every bucket on the service.
func TestExactDestination(t *testing.T) {
	const host = "discord-attachments-uploads-prd.storage.googleapis.com"

	d, p := writeFiles(t, "discord.com\n="+host+"\n", "discord.com 443\n="+host+" 443\n")
	policy, err := LoadPolicy(d, p)
	if err != nil {
		t.Fatalf("LoadPolicy: %v", err)
	}

	var found *Destination
	for i := range policy.Destinations {
		if policy.Destinations[i].Domain == host {
			found = &policy.Destinations[i]
		}
	}
	if found == nil {
		t.Fatalf("exact host missing from the policy: %+v", policy.Destinations)
	}
	if !found.Exact {
		t.Error("entry was not marked exact")
	}
	if !policy.Allows(host, 443) {
		t.Error("the exact host is not allowed on 443")
	}
	if policy.Allows("evil."+host, 443) {
		t.Error("a subdomain of the exact host was allowed")
	}
	if policy.Allows(strings.TrimPrefix(host, "discord-attachments-uploads-prd."), 443) {
		t.Error("storage.googleapis.com itself was allowed")
	}
	if policy.Allows(host, 80) {
		t.Error("a port outside the policy was allowed")
	}

	acl := policy.SquidACL()
	if !strings.Contains(acl, "dstdomain "+host+"\n") {
		t.Errorf("exact host is not rendered as an exact dstdomain:\n%s", acl)
	}
	if strings.Contains(acl, "dstdomain ."+host) {
		t.Errorf("exact host was rendered with subdomain scope:\n%s", acl)
	}

	// The marker is a file-format detail; the published document must not carry it.
	blob, err := json.Marshal(policy)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if strings.Contains(string(blob), "Exact") || strings.Contains(string(blob), "="+host) {
		t.Errorf("published policy leaks the exact marker: %s", blob)
	}

	// A '=' in one file but not the other would silently widen the proxy.
	d2, p2 := writeFiles(t, "="+host+"\n", host+" 443\n")
	if _, err := LoadPolicy(d2, p2); err == nil {
		t.Error("the two files disagreeing about '=' was accepted")
	}
}
