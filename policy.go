package main

// Destination policy for the HTTPS CONNECT proxy.
//
// Two operator-editable files define what the relay may connect to:
//
//	/etc/dohcord-relay/allowed-domains.txt   one domain per line
//	/etc/dohcord-relay/destination-policy.conf
//	        <domain> <port>[,<port>|<from>-<to> ...]
//
// This file parses both, validates them strictly, renders the Squid ACL include
// that enforces the policy, and serialises the exact policy that Squid is
// enforcing so the network-configuration endpoint cannot advertise something
// different from what the proxy allows.

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// schemaVersion is the version of the network-configuration document.
const schemaVersion = 1

// PortRange is an inclusive TCP port range.
type PortRange struct {
	From int `json:"from"`
	To   int `json:"to"`
}

// Destination is one allowlisted domain and the TCP ports permitted for it.
type Destination struct {
	Domain     string      `json:"domain"`
	Ports      []int       `json:"ports"`
	PortRanges []PortRange `json:"portRanges,omitempty"`
}

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

// parsePortSpec parses "443" or "443,1024-65535" into explicit ports and ranges.
// Validation is deliberately strict: the proxy's reach must never widen because
// a malformed line was silently ignored.
func parsePortSpec(spec string) ([]int, []PortRange, error) {
	var ports []int
	var ranges []PortRange
	seen := make(map[int]bool)

	add := func(port int) error {
		if seen[port] {
			return fmt.Errorf("port %d is listed more than once", port)
		}
		seen[port] = true
		return nil
	}

	for _, part := range strings.Split(spec, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			return nil, nil, fmt.Errorf("empty entry in port list %q", spec)
		}
		lo, hi := part, part
		if i := strings.IndexByte(part, '-'); i >= 0 {
			lo, hi = strings.TrimSpace(part[:i]), strings.TrimSpace(part[i+1:])
		}
		from, err := parsePort(lo)
		if err != nil {
			return nil, nil, err
		}
		to, err := parsePort(hi)
		if err != nil {
			return nil, nil, err
		}
		if from > to {
			return nil, nil, fmt.Errorf("port range %q is reversed", part)
		}
		if from == to {
			if err := add(from); err != nil {
				return nil, nil, err
			}
			ports = append(ports, from)
			continue
		}
		for p := from; p <= to; p++ {
			if seen[p] {
				return nil, nil, fmt.Errorf("port %d is covered by more than one entry in %q", p, spec)
			}
			seen[p] = true
		}
		ranges = append(ranges, PortRange{From: from, To: to})
	}

	// Ports are given as single values or ranges; overlapping entries may not
	// exist, but a range and a single port can still be adjacent. Check the
	// ranges against each other for overlap.
	for i := 0; i < len(ranges); i++ {
		for j := i + 1; j < len(ranges); j++ {
			if ranges[i].From <= ranges[j].To && ranges[j].From <= ranges[i].To {
				return nil, nil, fmt.Errorf("port ranges %d-%d and %d-%d overlap",
					ranges[i].From, ranges[i].To, ranges[j].From, ranges[j].To)
			}
		}
	}

	sort.Ints(ports)
	sort.Slice(ranges, func(i, j int) bool { return ranges[i].From < ranges[j].From })
	return ports, ranges, nil
}

func parsePort(s string) (int, error) {
	n, err := strconv.Atoi(strings.TrimSpace(s))
	if err != nil {
		return 0, fmt.Errorf("port %q is not a number", s)
	}
	if n < 1 || n > 65535 {
		return 0, fmt.Errorf("port %d is outside 1-65535", n)
	}
	return n, nil
}

// readConfigLines returns the significant lines of a configuration file with
// comments and blank lines removed. It keeps the line number for messages.
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

// loadDomainList parses allowed-domains.txt.
func loadDomainList(path string) ([]string, error) {
	lines, err := readConfigLines(path)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", path, err)
	}
	var domains []string
	seen := make(map[string]bool)
	for _, line := range lines {
		domain, err := normalizeDomain(line.text)
		if err != nil {
			return nil, fmt.Errorf("%s line %d: %w", path, line.number, err)
		}
		if seen[domain] {
			return nil, fmt.Errorf("%s line %d: %q is listed twice", path, line.number, domain)
		}
		seen[domain] = true
		domains = append(domains, domain)
	}
	if len(domains) == 0 {
		return nil, fmt.Errorf("%s contains no domains; refusing to build a proxy policy", path)
	}
	sort.Strings(domains)
	return domains, nil
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
		domain, err := normalizeDomain(fields[0])
		if err != nil {
			return nil, fmt.Errorf("%s line %d: %w", path, line.number, err)
		}
		if _, dup := out[domain]; dup {
			return nil, fmt.Errorf("%s line %d: %q has more than one policy line", path, line.number, domain)
		}
		ports, ranges, err := parsePortSpec(fields[1])
		if err != nil {
			return nil, fmt.Errorf("%s line %d: %w", path, line.number, err)
		}
		out[domain] = Destination{Domain: domain, Ports: ports, PortRanges: ranges}
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
	for _, d := range domains {
		if _, ok := byDomain[d]; !ok {
			missing = append(missing, d)
		}
	}
	for d := range byDomain {
		if !containsString(domains, d) {
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

	p := &Policy{Version: schemaVersion}
	for _, d := range domains {
		p.Destinations = append(p.Destinations, byDomain[d])
	}
	return p, nil
}

func containsString(list []string, want string) bool {
	for _, v := range list {
		if v == want {
			return true
		}
	}
	return false
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
		if h != d.Domain && !strings.HasSuffix(h, "."+d.Domain) {
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

// PortList renders the ports of a destination the way Squid's "port" ACL wants
// them: space separated single ports and inclusive ranges.
func (d Destination) PortList() string {
	var parts []string
	for _, p := range d.Ports {
		parts = append(parts, strconv.Itoa(p))
	}
	for _, r := range d.PortRanges {
		parts = append(parts, fmt.Sprintf("%d-%d", r.From, r.To))
	}
	return strings.Join(parts, " ")
}

// SquidACL renders the include file that Squid evaluates. Each destination gets
// a dstdomain ACL and a port ACL, and a single http_access line that references
// both: Squid ANDs different ACL names on one line, so a CONNECT request must
// match the domain and a permitted port for that same domain. Squid rejects two
// types on one ACL name, which is why they are separate.
//
// dstdomain matches on DNS label boundaries, so "discord.com.evil.example"
// never matches ".discord.com". A leading dot covers the domain itself and every
// subdomain; listing the bare name too is rejected by Squid as redundant.
func (p *Policy) SquidACL() string {
	var b strings.Builder
	b.WriteString("# Generated by `dohcord-relay -policy-apply` from\n")
	b.WriteString("# /etc/dohcord-relay/allowed-domains.txt and\n")
	b.WriteString("# /etc/dohcord-relay/destination-policy.conf.\n")
	b.WriteString("# Do not edit: change those two files and run the policy command instead.\n\n")
	for i, d := range p.Destinations {
		fmt.Fprintf(&b, "# %s\n", d.Domain)
		fmt.Fprintf(&b, "acl dohcord_domain_%d dstdomain .%s\n", i, d.Domain)
		fmt.Fprintf(&b, "acl dohcord_ports_%d port %s\n", i, d.PortList())
		fmt.Fprintf(&b, "http_access allow CONNECT dohcord_domain_%d dohcord_ports_%d\n\n", i, i)
	}
	return b.String()
}

// SquidIncludeLine is the include directive the rendered file must be reachable
// from; applyPolicy rewrites it while validating and refuses to run without it.
func SquidIncludeLine(allowFile string) string {
	return "include " + allowFile
}

// writeFileAtomic writes data to path via a temporary file in the same
// directory, so a reader never sees a partial file.
func writeFileAtomic(path string, data []byte, mode os.FileMode) error {
	dir := filepath.Dir(path)
	f, err := os.CreateTemp(dir, "."+filepath.Base(path)+".tmp-")
	if err != nil {
		return err
	}
	tmp := f.Name()
	defer os.Remove(tmp)

	if _, err := f.Write(data); err != nil {
		f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmp, mode); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// SavePolicyState writes the policy Squid is enforcing to path.
func SavePolicyState(path string, p *Policy) error {
	p.GeneratedAt = time.Now().UTC().Format(time.RFC3339)
	data, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return err
	}
	return writeFileAtomic(path, append(data, '\n'), 0o644)
}

// loadPolicyState reads a policy state file written by SavePolicyState.
func loadPolicyState(path string) (*Policy, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var p Policy
	if err := json.Unmarshal(data, &p); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	if p.Version != schemaVersion {
		return nil, fmt.Errorf("%s has schema version %d, expected %d", path, p.Version, schemaVersion)
	}
	if len(p.Destinations) == 0 {
		return nil, fmt.Errorf("%s contains no destinations", path)
	}
	for _, d := range p.Destinations {
		if _, err := normalizeDomain(d.Domain); err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
		if len(d.Ports) == 0 && len(d.PortRanges) == 0 {
			return nil, fmt.Errorf("%s: destination %q has no ports", path, d.Domain)
		}
	}
	return &p, nil
}

// policyCache returns the policy the proxy is enforcing. The state file written
// by the policy command wins, so the endpoint can never advertise a policy that
// Squid has not been reloaded with. Without a state file the source files are
// parsed directly (the case in tests and on a fresh checkout).
type policyCache struct {
	domainsPath string
	policyPath  string
	statePath   string

	cached    *Policy
	stateKey  fileKey
	sourceKey fileKey
}

type fileKey struct {
	modTime time.Time
	size    int64
	exists  bool
}

func statKey(path string) fileKey {
	fi, err := os.Stat(path)
	if err != nil {
		return fileKey{}
	}
	return fileKey{modTime: fi.ModTime(), size: fi.Size(), exists: true}
}

func (c *policyCache) get() (*Policy, error) {
	stateKey := statKey(c.statePath)
	sourceKey := statKey(c.domainsPath)
	portsKey := statKey(c.policyPath)
	sourceKey = fileKey{modTime: sourceKey.modTime, size: sourceKey.size + 7919*portsKey.size, exists: sourceKey.exists && portsKey.exists}

	if c.cached != nil && stateKey == c.stateKey && sourceKey == c.sourceKey {
		return c.cached, nil
	}

	var (
		p   *Policy
		err error
	)
	if stateKey.exists {
		p, err = loadPolicyState(c.statePath)
		if err != nil {
			return nil, err
		}
	} else {
		p, err = LoadPolicy(c.domainsPath, c.policyPath)
		if err != nil {
			return nil, err
		}
	}

	c.cached = p
	c.stateKey = stateKey
	c.sourceKey = sourceKey
	return p, nil
}
