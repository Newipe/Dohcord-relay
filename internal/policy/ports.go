package policy

import (
	"fmt"
	"sort"
	"strconv"
	"strings"
)

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
