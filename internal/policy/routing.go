package policy

import (
	"sort"
	"strings"
)

// RoutingRule is one entry of the client-facing routing policy published by
// /network-config. It describes the same policy Squid enforces, in the form a
// client needs to decide which requests to send to the proxy.
type RoutingRule struct {
	Host string `json:"host"`
	// Match is "exact" (this host name only) or "suffix" (this host and its
	// subdomains, matched on DNS label boundaries).
	Match string      `json:"match"`
	Ports []PortRange `json:"ports"`
}

// MatchExact and MatchSuffix are the two matching modes of a routing rule.
const (
	MatchExact  = "exact"
	MatchSuffix = "suffix"
)

// RoutingRules renders the policy as the routing contract published by
// /network-config. It is derived from the same parsed policy that produces the
// Squid ACLs, so the two can never disagree: an exact entry stays exact, a
// domain entry stays suffix-scoped, and each rule lists exactly the ports it is
// allowed to use (single ports as from==to, ranges unchanged).
func (p *Policy) RoutingRules() []RoutingRule {
	out := make([]RoutingRule, 0, len(p.Destinations))
	for _, d := range p.Destinations {
		match := MatchSuffix
		if d.Exact {
			match = MatchExact
		}
		ports := make([]PortRange, 0, len(d.Ports)+len(d.PortRanges))
		for _, port := range d.Ports {
			ports = append(ports, PortRange{From: port, To: port})
		}
		ports = append(ports, d.PortRanges...)
		sort.Slice(ports, func(i, j int) bool {
			if ports[i].From != ports[j].From {
				return ports[i].From < ports[j].From
			}
			return ports[i].To < ports[j].To
		})
		out = append(out, RoutingRule{Host: d.Domain, Match: match, Ports: ports})
	}
	return out
}

// Matches reports whether the rule names host, using the same DNS label-boundary
// rule Squid applies for dstdomain. It exists so the published contract can be
// tested directly.
func (r RoutingRule) Matches(host string) bool {
	h, err := normalizeDomain(host)
	if err != nil {
		return false
	}
	if r.Match == MatchExact {
		return h == r.Host
	}
	return h == r.Host || strings.HasSuffix(h, "."+r.Host)
}
