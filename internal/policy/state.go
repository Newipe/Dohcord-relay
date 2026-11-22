package policy

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"
)

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

// policyState is the on-disk record of the policy Squid is enforcing. It carries
// the exact/suffix scope, which the published document deliberately does not:
// without it, a reload would describe an exact host as a suffix rule while Squid
// kept enforcing the exact one.
type policyState struct {
	Version      int                `json:"version"`
	GeneratedAt  string             `json:"generatedAt,omitempty"`
	Destinations []stateDestination `json:"destinations"`
}

type stateDestination struct {
	Domain     string      `json:"domain"`
	Exact      bool        `json:"exact,omitempty"`
	Ports      []int       `json:"ports"`
	PortRanges []PortRange `json:"portRanges,omitempty"`
}

// SavePolicyState writes the policy Squid is enforcing to path.
func SavePolicyState(path string, p *Policy) error {
	p.GeneratedAt = time.Now().UTC().Format(time.RFC3339)
	state := policyState{Version: p.Version, GeneratedAt: p.GeneratedAt}
	for _, d := range p.Destinations {
		state.Destinations = append(state.Destinations, stateDestination{
			Domain:     d.Domain,
			Exact:      d.Exact,
			Ports:      d.Ports,
			PortRanges: d.PortRanges,
		})
	}
	data, err := json.MarshalIndent(state, "", "  ")
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
	var state policyState
	if err := json.Unmarshal(data, &state); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	if state.Version != SchemaVersion {
		return nil, fmt.Errorf("%s has schema version %d, expected %d", path, state.Version, SchemaVersion)
	}
	if len(state.Destinations) == 0 {
		return nil, fmt.Errorf("%s contains no destinations", path)
	}
	p := &Policy{Version: state.Version, GeneratedAt: state.GeneratedAt}
	for _, d := range state.Destinations {
		if _, err := normalizeDomain(d.Domain); err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
		if len(d.Ports) == 0 && len(d.PortRanges) == 0 {
			return nil, fmt.Errorf("%s: destination %q has no ports", path, d.Domain)
		}
		p.Destinations = append(p.Destinations, Destination{
			Domain:     d.Domain,
			Ports:      d.Ports,
			PortRanges: d.PortRanges,
			Exact:      d.Exact,
		})
	}
	return p, nil
}

// Cache returns the policy the proxy is enforcing. The state file written
// by the policy command wins, so the endpoint can never advertise a policy that
// Squid has not been reloaded with. Without a state file the source files are
// parsed directly (the case in tests and on a fresh checkout).
//
// The common case is a read: one stat of the state file and an atomic load, so
// concurrent profile loads never queue on a lock. Only a change (or the first
// call) takes the write lock and re-parses.
type Cache struct {
	DomainsPath string
	PolicyPath  string
	StatePath   string

	mu  sync.Mutex
	cur atomic.Pointer[cacheEntry]
}

type cacheEntry struct {
	stateKey  fileKey
	sourceKey fileKey
	policy    *Policy
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

// sourceKey fingerprints the two source files as one value.
func (c *Cache) sourceKey() fileKey {
	domains := statKey(c.DomainsPath)
	ports := statKey(c.PolicyPath)
	return fileKey{
		modTime: domains.modTime,
		size:    domains.size + 7919*ports.size,
		exists:  domains.exists && ports.exists,
	}
}

func (c *Cache) Get() (*Policy, error) {
	stateKey := statKey(c.StatePath)
	if e := c.cur.Load(); e != nil && e.stateKey == stateKey {
		// With a state file its timestamp alone decides: the source files only
		// matter while no policy has been applied yet.
		if stateKey.exists || e.sourceKey == c.sourceKey() {
			return e.policy, nil
		}
	}
	return c.refresh(stateKey)
}

func (c *Cache) refresh(stateKey fileKey) (*Policy, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	// Another request may have refreshed while this one waited for the lock.
	if e := c.cur.Load(); e != nil && e.stateKey == stateKey {
		src := c.sourceKey()
		if stateKey.exists || e.sourceKey == src {
			return e.policy, nil
		}
	}

	src := c.sourceKey()
	var (
		p   *Policy
		err error
	)
	if stateKey.exists {
		p, err = loadPolicyState(c.StatePath)
		if err != nil {
			return nil, err
		}
	} else {
		p, err = LoadPolicy(c.DomainsPath, c.PolicyPath)
		if err != nil {
			return nil, err
		}
	}

	c.cur.Store(&cacheEntry{stateKey: stateKey, sourceKey: src, policy: p})
	return p, nil
}
