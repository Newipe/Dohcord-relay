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

// while the file is unchanged. The secret is never logged.
type secretStore struct {
	path string

	mu      sync.Mutex
	cached  []byte
	modTime time.Time
	size    int64
}

func (s *secretStore) invalidate() {
	s.mu.Lock()
	s.cached = nil
	s.mu.Unlock()
}

func (s *secretStore) get() ([]byte, error) {
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
		return s.cached, nil
	}

	raw, err := os.ReadFile(s.path)
	if err != nil {
		s.cached = nil
		return nil, fmt.Errorf("read turn secret: %w", err)
	}
	secret := []byte(strings.TrimSpace(string(raw)))
	if len(secret) < 16 {
		s.cached = nil
		return nil, fmt.Errorf("turn secret %s is too short (%d bytes), expected at least 16", s.path, len(secret))
	}

	s.cached = secret
	s.modTime = fi.ModTime()
	s.size = fi.Size()
	return s.cached, nil
}

// certReloader serves the current certificate and reloads it when the files on
// disk change, so a 160-hour Let's Encrypt IP certificate can be replaced
