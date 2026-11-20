package api

import (
	"crypto/tls"
	"fmt"
	"os"
	"sync"
	"time"
)

// certReloader serves the current certificate and reloads it when the files on
// disk change, so a 160-hour Let's Encrypt IP certificate can be replaced
// without restarting the service.
type certReloader struct {
	CertFile string
	KeyFile  string

	mu       sync.Mutex
	cert     *tls.Certificate
	certMod  time.Time
	keyMod   time.Time
	checked  time.Time
	forceRel bool
}

// statInterval bounds how often the certificate files are stat'ed.
const statInterval = 30 * time.Second

func (c *certReloader) invalidate() {
	c.mu.Lock()
	c.forceRel = true
	c.mu.Unlock()
}

func (c *certReloader) load(force bool) (*tls.Certificate, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	now := time.Now()
	if c.forceRel {
		force = true
		c.forceRel = false
	}
	if c.cert != nil && !force && now.Sub(c.checked) < statInterval {
		return c.cert, nil
	}
	c.checked = now

	certInfo, err := os.Stat(c.CertFile)
	if err != nil {
		return nil, fmt.Errorf("stat certificate: %w", err)
	}
	keyInfo, err := os.Stat(c.KeyFile)
	if err != nil {
		return nil, fmt.Errorf("stat private key: %w", err)
	}
	if c.cert != nil && !force &&
		certInfo.ModTime().Equal(c.certMod) && keyInfo.ModTime().Equal(c.keyMod) {
		return c.cert, nil
	}

	crt, err := tls.LoadX509KeyPair(c.CertFile, c.KeyFile)
	if err != nil {
		return nil, fmt.Errorf("load key pair: %w", err)
	}
	c.cert = &crt
	c.certMod = certInfo.ModTime()
	c.keyMod = keyInfo.ModTime()
	return c.cert, nil
}

func (c *certReloader) getCertificate(*tls.ClientHelloInfo) (*tls.Certificate, error) {
	crt, err := c.load(false)
	if err != nil {
		// Keep serving the previously loaded certificate if the renewed files
		// are mid-write.
		c.mu.Lock()
		cached := c.cert
		c.mu.Unlock()
		if cached != nil {
			return cached, nil
		}
		return nil, err
	}
	return crt, nil
}
