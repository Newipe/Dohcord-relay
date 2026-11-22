package policy

import (
	"os"
	"path/filepath"
	"testing"
)

func cacheFixture(tb testing.TB) *Cache {
	tb.Helper()
	dir := tb.TempDir()
	domains := filepath.Join(dir, "allowed-domains.txt")
	ports := filepath.Join(dir, "destination-policy.conf")
	state := filepath.Join(dir, "policy.json")

	if err := os.WriteFile(domains, []byte("discord.com\ndiscord.media\n"), 0o644); err != nil {
		tb.Fatalf("write domains: %v", err)
	}
	if err := os.WriteFile(ports, []byte("discord.com   443\ndiscord.media 443,1024-65535\n"), 0o644); err != nil {
		tb.Fatalf("write policy: %v", err)
	}
	pol, err := LoadPolicy(domains, ports)
	if err != nil {
		tb.Fatalf("load policy: %v", err)
	}
	if err := SavePolicyState(state, pol); err != nil {
		tb.Fatalf("save state: %v", err)
	}
	return &Cache{DomainsPath: domains, PolicyPath: ports, StatePath: state}
}

// TestCacheReusesParsedPolicy makes sure the common case does not re-parse: the
// same pointer comes back until a file changes.
func TestCacheReusesParsedPolicy(t *testing.T) {
	c := cacheFixture(t)
	first, err := c.Get()
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	second, err := c.Get()
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if first != second {
		t.Fatal("an unchanged policy was re-parsed instead of reused")
	}
	if len(first.Destinations) != 2 {
		t.Fatalf("destinations = %d, want 2", len(first.Destinations))
	}
}

// TestCachePicksUpAppliedPolicy checks that a new state file replaces the cached
// policy, which is what a policy apply must make visible immediately.
func TestCachePicksUpAppliedPolicy(t *testing.T) {
	c := cacheFixture(t)
	if _, err := c.Get(); err != nil {
		t.Fatalf("Get: %v", err)
	}

	dir := filepath.Dir(c.StatePath)
	domains := filepath.Join(dir, "allowed-domains.txt")
	ports := filepath.Join(dir, "destination-policy.conf")
	if err := os.WriteFile(domains, []byte("discord.com\ndiscord.media\nexample.org\n"), 0o644); err != nil {
		t.Fatalf("write domains: %v", err)
	}
	if err := os.WriteFile(ports, []byte("discord.com   443\ndiscord.media 443,1024-65535\nexample.org   443\n"), 0o644); err != nil {
		t.Fatalf("write policy: %v", err)
	}
	pol, err := LoadPolicy(domains, ports)
	if err != nil {
		t.Fatalf("load policy: %v", err)
	}
	if err := SavePolicyState(c.StatePath, pol); err != nil {
		t.Fatalf("save state: %v", err)
	}

	got, err := c.Get()
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if len(got.Destinations) != 3 {
		t.Fatalf("destinations = %d, want 3 after the apply", len(got.Destinations))
	}
}

// TestCacheWithoutStateFile follows the source files, which is the fresh-checkout
// and test path.
func TestCacheWithoutStateFile(t *testing.T) {
	c := cacheFixture(t)
	if err := os.Remove(c.StatePath); err != nil {
		t.Fatalf("remove state: %v", err)
	}
	pol, err := c.Get()
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if len(pol.Destinations) != 2 {
		t.Fatalf("destinations = %d, want 2 from the source files", len(pol.Destinations))
	}
	same, err := c.Get()
	if err != nil || same != pol {
		t.Fatalf("second Get did not reuse the parsed policy (err %v)", err)
	}
}

func BenchmarkCacheGet(b *testing.B) {
	c := cacheFixture(b)
	if _, err := c.Get(); err != nil {
		b.Fatalf("warm Get: %v", err)
	}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := c.Get(); err != nil {
			b.Fatalf("Get: %v", err)
		}
	}
}

func BenchmarkCacheGetParallel(b *testing.B) {
	c := cacheFixture(b)
	if _, err := c.Get(); err != nil {
		b.Fatalf("warm Get: %v", err)
	}
	b.ReportAllocs()
	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		for pb.Next() {
			if _, err := c.Get(); err != nil {
				b.Fatalf("Get: %v", err)
			}
		}
	})
}
