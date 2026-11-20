// Package policy parses, validates and renders the destination policy of the
// HTTPS CONNECT proxy.
//
// Two operator-editable files define what the relay may connect to:
//
//	/etc/dohcord-relay/allowed-domains.txt        one domain per line
//	/etc/dohcord-relay/destination-policy.conf    <domain> <port>[,<port>|<from>-<to> ...]
//
// Both are validated strictly and cross-checked, and the same parsed policy
// produces the Squid ACL include, the routing contract published by
// /network-config and the state file recording what Squid enforces.
package policy

import (
	"errors"
	"fmt"
	"os"
	"regexp"
	"sort"
	"strings"
)

const SchemaVersion = 1

// PortRange is an inclusive TCP port range.
type PortRange struct {
	From int `json:"from"`
	To   int `json:"to"`
}

// Destination is one allowlisted domain and the TCP ports permitted for it.
//
// Exact marks a host that is allowed on its own name only, without its
// subdomains. It is written with a leading "=" in both policy files and is not
// part of the network-configuration document, which only needs the name and its
// ports.
type Destination struct {
	Domain     string      `json:"domain"`
	Ports      []int       `json:"ports"`
	PortRanges []PortRange `json:"portRanges,omitempty"`
	Exact      bool        `json:"-"`
}

// exactPrefix marks an allowlist entry as that exact host name only. Without it
// a bare name also covers its subdomains ("discord.com" covers
// "gateway.discord.com"), which is right for Discord's own domains but wrong for
// a host under shared infrastructure such as Google Cloud Storage: there, every
// subdomain of the name can be a bucket owned by somebody else.
const exactPrefix = "="

// Policy is the authoritative destination policy.
type Policy struct {
	Version      int           `json:"version"`
	GeneratedAt  string        `json:"generatedAt,omitempty"`
	Destinations []Destination `json:"destinations"`
}

// domainRE matches a lowercase DNS name with at least two labels. It is applied
// after normalisation, so it never sees uppercase characters or a trailing dot.
var domainRE = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$`)

// maxDomainLength is the DNS length limit for a fully qualified name.
const maxDomainLength = 253

// normalizeDomain lowercases value, trims surrounding space and a single
// trailing dot, and validates it as a DNS name. It rejects IP literals, schemes,
// ports, paths and wildcards: a CONNECT authority is a host name, not a URL.
func normalizeDomain(value string) (string, error) {
	d := strings.ToLower(strings.TrimSpace(value))
	d = strings.TrimSuffix(d, ".")

	switch {
	case d == "":
		return "", errors.New("empty domain")
	case len(d) > maxDomainLength:
		return "", fmt.Errorf("domain %q is longer than %d characters", d, maxDomainLength)
	case strings.ContainsAny(d, " \t/\\:@?#[]*_"):
		return "", fmt.Errorf("domain %q must be a plain host name (no scheme, port, path, wildcard or underscore)", d)
	case looksLikeIPLiteral(d):
		return "", fmt.Errorf("%q is an IP address; only domain names may be allowlisted", d)
	case !domainRE.MatchString(d):
		return "", fmt.Errorf("%q is not a valid domain name", d)
	}
	return d, nil
}

// looksLikeIPLiteral reports whether value is an IPv4/IPv6 literal, including
// forms such as "127.1" and "0x7f000001" that resolvers may still accept.
func looksLikeIPLiteral(value string) bool {
	if strings.Contains(value, ":") {
		return true // any IPv6 literal (or an IP:port mistake)
	}
	if value == "" {
		return false
	}
	numeric := true
	for _, r := range value {
		if !(r >= '0' && r <= '9') && r != '.' {
			numeric = false
			break
		}
	}
	return numeric
}

type configLine struct {
	number int
	text   string
}

func readConfigLines(path string) ([]configLine, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var lines []configLine
	for i, raw := range strings.Split(string(data), "\n") {
		line := raw
		if idx := strings.IndexByte(line, '#'); idx >= 0 {
			line = line[:idx]
		}
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		lines = append(lines, configLine{number: i + 1, text: line})
	}
	return lines, nil
}

// domainEntry is one parsed allowlist entry: a host name and whether it is
// restricted to that exact name.
type domainEntry struct {
	Domain string
	Exact  bool
}

// parseDomainEntry parses one allowlist/port-policy entry, honouring the
// optional leading "=" that restricts it to the exact host name.
func parseDomainEntry(text string) (domainEntry, error) {
	exact := strings.HasPrefix(text, exactPrefix)
	if exact {
		text = strings.TrimSpace(strings.TrimPrefix(text, exactPrefix))
	}
	domain, err := normalizeDomain(text)
	if err != nil {
		return domainEntry{}, err
	}
	return domainEntry{Domain: domain, Exact: exact}, nil
}

// loadDomainList parses allowed-domains.txt.
func loadDomainList(path string) ([]domainEntry, error) {
	lines, err := readConfigLines(path)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", path, err)
	}
	var domains []domainEntry
	seen := make(map[string]bool)
	for _, line := range lines {
		entry, err := parseDomainEntry(line.text)
		if err != nil {
			return nil, fmt.Errorf("%s line %d: %w", path, line.number, err)
		}
		key := domainKey(entry)
		if seen[key] {
			return nil, fmt.Errorf("%s line %d: %q is listed twice", path, line.number, entry.Domain)
		}
		seen[key] = true
		domains = append(domains, entry)
	}
	if len(domains) == 0 {
		return nil, fmt.Errorf("%s contains no domains; refusing to build a proxy policy", path)
	}
	sort.Slice(domains, func(i, j int) bool { return domains[i].Domain < domains[j].Domain })
	return domains, nil
}

// domainKey identifies an entry independently of its exactness, so the same host
// cannot be listed twice with different scopes.
func domainKey(e domainEntry) string {
	return e.Domain
}

// parseDestinationPolicy parses destination-policy.conf into a domain->ports map.
func parseDestinationPolicy(path string) (map[string]Destination, error) {
	lines, err := readConfigLines(path)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", path, err)
	}
	out := make(map[string]Destination, len(lines))
	for _, line := range lines {
		fields := strings.Fields(line.text)
		if len(fields) != 2 {
			return nil, fmt.Errorf("%s line %d: expected \"<domain> <ports>\", got %q", path, line.number, line.text)
		}
		entry, err := parseDomainEntry(fields[0])
		if err != nil {
			return nil, fmt.Errorf("%s line %d: %w", path, line.number, err)
		}
		if _, dup := out[entry.Domain]; dup {
			return nil, fmt.Errorf("%s line %d: %q has more than one policy line", path, line.number, entry.Domain)
		}
		ports, ranges, err := parsePortSpec(fields[1])
		if err != nil {
			return nil, fmt.Errorf("%s line %d: %w", path, line.number, err)
		}
		out[entry.Domain] = Destination{Domain: entry.Domain, Ports: ports, PortRanges: ranges, Exact: entry.Exact}
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("%s contains no entries; refusing to build a proxy policy", path)
	}
	return out, nil
}

// LoadPolicy reads and cross-validates both files. Every allowlisted domain must
// have a port policy, and every port policy must belong to an allowlisted
// domain: an inconsistent pair of files is a configuration error, never a
// partially applied policy.
func LoadPolicy(domainsPath, policyPath string) (*Policy, error) {
	domains, err := loadDomainList(domainsPath)
	if err != nil {
		return nil, err
	}
	byDomain, err := parseDestinationPolicy(policyPath)
	if err != nil {
		return nil, err
	}

	var missing, extra []string
	for _, entry := range domains {
		d, ok := byDomain[entry.Domain]
		if !ok {
			missing = append(missing, entry.Domain)
			continue
		}
		// The two files must agree on the scope. A missing "=" in one of them
		// would quietly widen the proxy to every subdomain, so it is an error.
		if d.Exact != entry.Exact {
			return nil, fmt.Errorf("%q is spelled %q in %s but %q in %s; use the same leading '=' in both files",
				entry.Domain, map[bool]string{true: "=" + entry.Domain, false: entry.Domain}[entry.Exact], domainsPath,
				map[bool]string{true: "=" + d.Domain, false: d.Domain}[d.Exact], policyPath)
		}
	}
	entries := make(map[string]bool, len(domains))
	for _, entry := range domains {
		entries[entry.Domain] = true
	}
	for d := range byDomain {
		if !entries[d] {
			extra = append(extra, d)
		}
	}
	if len(missing) > 0 {
		sort.Strings(missing)
		return nil, fmt.Errorf("%s lists %s but %s has no port policy for them",
			domainsPath, strings.Join(missing, ", "), policyPath)
	}
	if len(extra) > 0 {
		sort.Strings(extra)
		return nil, fmt.Errorf("%s has entries for %s, which are missing from %s",
			policyPath, strings.Join(extra, ", "), domainsPath)
	}

	p := &Policy{Version: SchemaVersion}
	for _, entry := range domains {
		p.Destinations = append(p.Destinations, byDomain[entry.Domain])
	}
	return p, nil
}

// Allows reports whether host:port is inside the policy using strict domain
// boundary matching: "discord.com" and "x.discord.com" match, while
// "discord.com.evil.example" and "evil-discord.com" do not. It mirrors the
// dstdomain ACL that Squid enforces and is used by the tests.
func (p *Policy) Allows(host string, port int) bool {
	h, err := normalizeDomain(host)
	if err != nil {
		return false
	}
	for _, d := range p.Destinations {
		if d.Exact {
			if h != d.Domain {
				continue
			}
		} else if h != d.Domain && !strings.HasSuffix(h, "."+d.Domain) {
			continue
		}
		for _, p := range d.Ports {
			if p == port {
				return true
			}
		}
		for _, r := range d.PortRanges {
			if port >= r.From && port <= r.To {
				return true
			}
		}
	}
	return false
}
