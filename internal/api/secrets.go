package api

import (
	"fmt"
	"os"
	"strings"
	"sync"
	"time"
)

// maxSecretBytes bounds the size of the coturn shared secret file.
const maxSecretBytes = 4096

// secretRecheck bounds how often the secret file is stat'ed while the cached
// value is being served. A profile load used to stat the file every time; a
// burst of simultaneous profile loads now shares one check. The explicit reload
// path (SIGHUP) clears the cache immediately, and a rotation is still noticed
// within this interval. A stat is a syscall, and the file only changes when an
// operator rotates the secret.
const secretRecheck = time.Second

// secretStore reads the coturn shared secret on demand, reusing the cached value
// while the file is unchanged. The secret is never logged.
type secretStore struct {
	path string

	mu      sync.Mutex
	cached  []byte
	modTime time.Time
	size    int64
	checked time.Time
}

func (s *secretStore) invalidate() {
	s.mu.Lock()
	s.cached = nil
	s.checked = time.Time{}
	s.mu.Unlock()
}

func (s *secretStore) get() ([]byte, error) {
	// The common case is a cached read with no filesystem call at all. The
	// returned slice is never modified in place, so handing it out after the
	// lock is released is safe: invalidate only drops the reference.
	s.mu.Lock()
	if s.cached != nil && time.Since(s.checked) < secretRecheck {
		secret := s.cached
		s.mu.Unlock()
		return secret, nil
	}
	s.mu.Unlock()

	fi, err := os.Stat(s.path)
	if err != nil {
		s.invalidate()
		return nil, fmt.Errorf("stat turn secret: %w", err)
	}
	if fi.Size() == 0 || fi.Size() > maxSecretBytes {
		return nil, fmt.Errorf("turn secret %s has an unusable size (%d bytes)", s.path, fi.Size())
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	if s.cached != nil && fi.ModTime().Equal(s.modTime) && fi.Size() == s.size {
		s.checked = time.Now()
		return s.cached, nil
	}

	raw, err := os.ReadFile(s.path)
	if err != nil {
		s.cached = nil
		s.checked = time.Time{}
		return nil, fmt.Errorf("read turn secret: %w", err)
	}
	secret := []byte(strings.TrimSpace(string(raw)))
	if len(secret) < 16 {
		s.cached = nil
		s.checked = time.Time{}
		return nil, fmt.Errorf("turn secret %s is too short (%d bytes), expected at least 16", s.path, len(secret))
	}

	s.cached = secret
	s.modTime = fi.ModTime()
	s.size = fi.Size()
	s.checked = time.Now()
	return s.cached, nil
}
