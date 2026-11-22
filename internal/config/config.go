// Package config reads the relay's runtime configuration from a small KEY=VALUE
// file, so the installer can write it and systemd can pass a single path.
package config

import (
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/Newipe/Dohcord-relay/internal/credentials"
)

const (
	// DefaultPath is where the installer writes the configuration file.
	DefaultPath = "/etc/dohcord-relay/config.env"

	// DefaultNetworkConfigPort is used when the configuration does not name a
	// port, including configurations written by older releases.
	DefaultNetworkConfigPort = 8443

	// MaxIdentityLength bounds the TURN Identity in a REST username.
	MaxIdentityLength = 64

	// Default request limits. Several Dohcord profiles load their configuration
	// at the same time, so the per-address allowance has to cover a burst of
	// profile loads (and a reconnect) without answering 429. These are far above
	// normal use: a client fetches /network-config once per profile load and
	// then keeps its connection, so the limiter only exists to bound abuse.
	DefaultPerIPRate   = 60
	DefaultPerIPBurst  = 30
	DefaultGlobalRate  = 1200
	DefaultGlobalBurst = 300

	// MaxRate and MaxBurst bound what an operator may configure, so a typo can
	// never turn the limiter into a denial of service for the relay itself.
	MaxRate  = 1_000_000
	MaxBurst = 1_000_000
	// MaxTTL and MinTTL bound the lifetime of an issued TURN credential.
	MaxTTL = 7 * 24 * time.Hour
	MinTTL = time.Minute
)

// config is the runtime configuration, read from a small KEY=VALUE file so the
// installer can write it and systemd can pass a single path.
type Config struct {
	// Public Identity of the relay, as clients must reach it.
	ProxyURL string // https://host:443 - the HTTPS CONNECT proxy
	APIURL   string // https://host:<NETWORK_CONFIG_PORT>/network-config, for logs and reports

	TurnURLs   []string
	Identity   string
	TTL        time.Duration
	SecretFile string
	CertFile   string
	KeyFile    string

	// NetworkConfigPort is the authoritative port of the Network Configuration
	// API. HTTPSListen must bind the same port.
	NetworkConfigPort int
	HTTPSListen       string
	HTTPListen        string
	ACMEWebroot       string

	// Destination policy.
	AllowedDomainsFile    string
	DestinationPolicyFile string
	PolicyStateFile       string
	SquidConf             string
	SquidAllowFile        string
	SquidBinary           string

	PerIPRate   int
	PerIPBurst  int
	GlobalRate  int
	GlobalBurst int
	TrustProxy  bool
}

func Default() Config {
	return Config{
		Identity:              "Dohcord",
		TTL:                   24 * time.Hour,
		SecretFile:            "/etc/dohcord-relay/turn-secret",
		CertFile:              "/etc/dohcord-relay/tls/fullchain.pem",
		KeyFile:               "/etc/dohcord-relay/tls/privkey.pem",
		NetworkConfigPort:     DefaultNetworkConfigPort,
		HTTPSListen:           ":8443",
		HTTPListen:            ":80",
		ACMEWebroot:           "/var/www/dohcord-relay",
		AllowedDomainsFile:    "/etc/dohcord-relay/allowed-domains.txt",
		DestinationPolicyFile: "/etc/dohcord-relay/destination-policy.conf",
		PolicyStateFile:       "/etc/dohcord-relay/policy.json",
		SquidConf:             "/etc/dohcord-relay/squid.conf",
		SquidAllowFile:        "/etc/dohcord-relay/squid-allow.conf",
		SquidBinary:           "/usr/sbin/squid",
		PerIPRate:             DefaultPerIPRate,
		PerIPBurst:            DefaultPerIPBurst,
		GlobalRate:            DefaultGlobalRate,
		GlobalBurst:           DefaultGlobalBurst,
	}
}

// loadConfig reads path (KEY=VALUE, '#' comments) over the built-in defaults.
func Load(path string) (Config, error) {
	cfg := Default()

	values, err := parseEnvFile(path)
	if err != nil {
		return Config{}, err
	}

	if v, ok := values["HTTPS_PROXY_URL"]; ok {
		cfg.ProxyURL = v
	}
	if v, ok := values["NETWORK_CONFIG_URL"]; ok {
		cfg.APIURL = v
	}
	if v, ok := values["TURN_URLS"]; ok {
		urls := splitList(v)
		if len(urls) == 0 {
			return Config{}, errors.New("TURN_URLS must list at least one TURN URL")
		}
		cfg.TurnURLs = urls
	}
	if v, ok := values["TURN_IDENTITY"]; ok {
		cfg.Identity = v
	}
	if v, ok := values["CREDENTIAL_TTL"]; ok {
		TTL, err := parseDuration(v)
		if err != nil {
			return Config{}, fmt.Errorf("CREDENTIAL_TTL: %w", err)
		}
		cfg.TTL = TTL
	}
	if v, ok := values["SECRET_FILE"]; ok {
		cfg.SecretFile = v
	}
	if v, ok := values["TLS_CERT_FILE"]; ok {
		cfg.CertFile = v
	}
	if v, ok := values["TLS_KEY_FILE"]; ok {
		cfg.KeyFile = v
	}
	if v, ok := values["HTTPS_LISTEN"]; ok {
		cfg.HTTPSListen = v
	}
	_, listenConfigured := values["HTTPS_LISTEN"]
	if v, ok := values["NETWORK_CONFIG_PORT"]; ok {
		port, err := ParsePort(v)
		if err != nil {
			return Config{}, fmt.Errorf("NETWORK_CONFIG_PORT: %w", err)
		}
		cfg.NetworkConfigPort = port
		if !listenConfigured {
			// NETWORK_CONFIG_PORT is authoritative: bind it when no explicit
			// listen address is present.
			cfg.HTTPSListen = ":" + strconv.Itoa(port)
		}
	} else if port, err := ListenPort(cfg.HTTPSListen); err == nil && port != 0 {
		// Older releases only recorded the listen address. Preserve the port it
		// already used instead of falling back to the default.
		cfg.NetworkConfigPort = port
	}
	if v, ok := values["HTTP_LISTEN"]; ok {
		cfg.HTTPListen = v
	}
	if v, ok := values["ACME_WEBROOT"]; ok {
		cfg.ACMEWebroot = v
	}
	if v, ok := values["ALLOWED_DOMAINS_FILE"]; ok {
		cfg.AllowedDomainsFile = v
	}
	if v, ok := values["DESTINATION_POLICY_FILE"]; ok {
		cfg.DestinationPolicyFile = v
	}
	if v, ok := values["POLICY_STATE_FILE"]; ok {
		cfg.PolicyStateFile = v
	}
	if v, ok := values["SQUID_CONF"]; ok {
		cfg.SquidConf = v
	}
	if v, ok := values["SQUID_ALLOW_FILE"]; ok {
		cfg.SquidAllowFile = v
	}
	if v, ok := values["SQUID_BINARY"]; ok {
		cfg.SquidBinary = v
	}
	for _, limit := range []struct {
		key string
		dst *int
		max int
	}{
		{"PER_IP_RATE_PER_MINUTE", &cfg.PerIPRate, MaxRate},
		{"PER_IP_BURST", &cfg.PerIPBurst, MaxBurst},
		{"GLOBAL_RATE_PER_MINUTE", &cfg.GlobalRate, MaxRate},
		{"GLOBAL_BURST", &cfg.GlobalBurst, MaxBurst},
	} {
		v, ok := values[limit.key]
		if !ok {
			continue
		}
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > limit.max {
			return Config{}, fmt.Errorf("%s must be a whole number between 1 and %d, got %q", limit.key, limit.max, v)
		}
		*limit.dst = n
	}
	if v, ok := values["TRUST_PROXY_HEADER"]; ok {
		b, err := strconv.ParseBool(v)
		if err != nil {
			return Config{}, fmt.Errorf("TRUST_PROXY_HEADER must be true or false, got %q", v)
		}
		cfg.TrustProxy = b
	}

	if err := cfg.Validate(); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

func (c Config) Validate() error {
	if err := credentials.ValidateIdentity(c.Identity); err != nil {
		return err
	}
	if len(c.Identity) > MaxIdentityLength {
		return fmt.Errorf("TURN_IDENTITY must be at most %d characters", MaxIdentityLength)
	}
	if c.TTL < MinTTL || c.TTL > MaxTTL {
		return fmt.Errorf("CREDENTIAL_TTL must be between %s and %s", MinTTL, MaxTTL)
	}
	if len(c.TurnURLs) == 0 {
		return errors.New("TURN_URLS must list at least one TURN URL")
	}
	for _, u := range c.TurnURLs {
		if !strings.HasPrefix(u, "turn:") && !strings.HasPrefix(u, "turns:") {
			return fmt.Errorf("TURN_URLS entry %q must start with turn: or turns:", u)
		}
	}
	if c.SecretFile == "" {
		return errors.New("SECRET_FILE must be set")
	}
	if err := validatePublicURL("HTTPS_PROXY_URL", c.ProxyURL); err != nil {
		return err
	}
	// The endpoint publishes these fields, so an unusable proxy URL must stop the
	// service at startup rather than produce a document with missing routing data.
	if _, err := ParseEndpoint(c.ProxyURL); err != nil {
		return fmt.Errorf("HTTPS_PROXY_URL: %w", err)
	}
	if c.APIURL != "" {
		if err := validatePublicURL("NETWORK_CONFIG_URL", c.APIURL); err != nil {
			return err
		}
	}
	for name, p := range map[string]string{
		"ALLOWED_DOMAINS_FILE":    c.AllowedDomainsFile,
		"DESTINATION_POLICY_FILE": c.DestinationPolicyFile,
		"POLICY_STATE_FILE":       c.PolicyStateFile,
		"SQUID_CONF":              c.SquidConf,
		"SQUID_ALLOW_FILE":        c.SquidAllowFile,
	} {
		if p == "" {
			return fmt.Errorf("%s must be set", name)
		}
	}
	for name, limit := range map[string]struct{ value, max int }{
		"PER_IP_RATE_PER_MINUTE": {c.PerIPRate, MaxRate},
		"PER_IP_BURST":           {c.PerIPBurst, MaxBurst},
		"GLOBAL_RATE_PER_MINUTE": {c.GlobalRate, MaxRate},
		"GLOBAL_BURST":           {c.GlobalBurst, MaxBurst},
	} {
		if limit.value < 1 || limit.value > limit.max {
			return fmt.Errorf("%s must be between 1 and %d, got %d", name, limit.max, limit.value)
		}
	}
	if c.NetworkConfigPort < 1 || c.NetworkConfigPort > 65535 {
		return fmt.Errorf("NETWORK_CONFIG_PORT must be between 1 and 65535, got %d", c.NetworkConfigPort)
	}
	if c.HTTPSListen != "" {
		if c.CertFile == "" || c.KeyFile == "" {
			return errors.New("TLS_CERT_FILE and TLS_KEY_FILE must be set when HTTPS_LISTEN is set")
		}
		listenPort, err := ListenPort(c.HTTPSListen)
		if err != nil {
			return fmt.Errorf("HTTPS_LISTEN: %w", err)
		}
		if listenPort == 0 {
			return errors.New("HTTPS_LISTEN must include a port")
		}
		if listenPort == 443 {
			return errors.New("HTTPS_LISTEN must not be :443 (the HTTPS CONNECT proxy owns that port)")
		}
		if c.HTTPSListen == c.HTTPListen {
			return errors.New("HTTPS_LISTEN must not equal HTTP_LISTEN")
		}
		if listenPort != c.NetworkConfigPort {
			return fmt.Errorf("HTTPS_LISTEN uses port %d but NETWORK_CONFIG_PORT is %d; both must name the Network Configuration API port", listenPort, c.NetworkConfigPort)
		}
	}
	return nil
}

// validatePublicURL rejects anything that is not an absolute https URL with a
// host, because these URLs are handed to clients as-is.
func validatePublicURL(name, raw string) error {
	if raw == "" {
		return fmt.Errorf("%s must be set", name)
	}
	u, err := url.Parse(raw)
	if err != nil {
		return fmt.Errorf("%s is not a valid URL: %w", name, err)
	}
	if u.Scheme != "https" {
		return fmt.Errorf("%s must use https://, got %q", name, u.Scheme)
	}
	if u.Host == "" {
		return fmt.Errorf("%s must include a host", name)
	}
	if u.User != nil {
		return fmt.Errorf("%s must not contain credentials", name)
	}
	return nil
}

func parseEnvFile(path string) (map[string]string, error) {
	values := make(map[string]string)
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read config: %w", err)
	}
	for i, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, val, ok := strings.Cut(line, "=")
		if !ok {
			return nil, fmt.Errorf("config line %d is not KEY=VALUE", i+1)
		}
		key = strings.TrimSpace(key)
		val = strings.TrimSpace(val)
		if len(val) >= 2 {
			if (val[0] == '"' && val[len(val)-1] == '"') || (val[0] == '\'' && val[len(val)-1] == '\'') {
				val = val[1 : len(val)-1]
			}
		}
		values[strings.ToUpper(key)] = val
	}
	return values, nil
}

// splitList accepts a comma or whitespace separated list.
func splitList(v string) []string {
	fields := strings.FieldsFunc(v, func(r rune) bool {
		return r == ',' || r == ' ' || r == '\t' || r == '\n'
	})
	out := make([]string, 0, len(fields))
	for _, f := range fields {
		if f = strings.TrimSpace(f); f != "" {
			out = append(out, f)
		}
	}
	return out
}

// parseDuration accepts Go durations ("24h") and plain seconds ("86400").
func parseDuration(v string) (time.Duration, error) {
	if secs, err := strconv.ParseInt(v, 10, 64); err == nil {
		return time.Duration(secs) * time.Second, nil
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		return 0, fmt.Errorf("must be a duration such as 24h or a number of seconds, got %q", v)
	}
	return d, nil
}

// Print writes the effective configuration, with the secret path but never the
// secret itself, so an operator can confirm what the service loaded.
func Print(w io.Writer, c Config) {
	fmt.Fprintf(w, "HTTPS_PROXY_URL=%s\n", c.ProxyURL)
	fmt.Fprintf(w, "NETWORK_CONFIG_URL=%s\n", c.APIURL)
	fmt.Fprintf(w, "TURN_URLS=%s\n", strings.Join(c.TurnURLs, ","))
	fmt.Fprintf(w, "TURN_IDENTITY=%s\n", c.Identity)
	fmt.Fprintf(w, "CREDENTIAL_TTL=%s\n", c.TTL)
	fmt.Fprintf(w, "SECRET_FILE=%s\n", c.SecretFile)
	fmt.Fprintf(w, "TLS_CERT_FILE=%s\n", c.CertFile)
	fmt.Fprintf(w, "TLS_KEY_FILE=%s\n", c.KeyFile)
	fmt.Fprintf(w, "NETWORK_CONFIG_PORT=%d\n", c.NetworkConfigPort)
	fmt.Fprintf(w, "HTTPS_LISTEN=%s\n", c.HTTPSListen)
	fmt.Fprintf(w, "HTTP_LISTEN=%s\n", c.HTTPListen)
	fmt.Fprintf(w, "ACME_WEBROOT=%s\n", c.ACMEWebroot)
	fmt.Fprintf(w, "ALLOWED_DOMAINS_FILE=%s\n", c.AllowedDomainsFile)
	fmt.Fprintf(w, "DESTINATION_POLICY_FILE=%s\n", c.DestinationPolicyFile)
	fmt.Fprintf(w, "POLICY_STATE_FILE=%s\n", c.PolicyStateFile)
	fmt.Fprintf(w, "SQUID_CONF=%s\n", c.SquidConf)
	fmt.Fprintf(w, "SQUID_ALLOW_FILE=%s\n", c.SquidAllowFile)
	fmt.Fprintf(w, "SQUID_BINARY=%s\n", c.SquidBinary)
	fmt.Fprintf(w, "PER_IP_RATE_PER_MINUTE=%d\n", c.PerIPRate)
	fmt.Fprintf(w, "PER_IP_BURST=%d\n", c.PerIPBurst)
	fmt.Fprintf(w, "GLOBAL_RATE_PER_MINUTE=%d\n", c.GlobalRate)
	fmt.Fprintf(w, "GLOBAL_BURST=%d\n", c.GlobalBurst)
	fmt.Fprintf(w, "TRUST_PROXY_HEADER=%t\n", c.TrustProxy)
}

// ParsePort validates a TCP port number supplied by an operator.
func ParsePort(raw string) (int, error) {
	n, err := strconv.Atoi(strings.TrimSpace(raw))
	if err != nil {
		return 0, fmt.Errorf("must be a TCP port number, got %q", raw)
	}
	if n < 1 || n > 65535 {
		return 0, fmt.Errorf("port %d is outside the range 1-65535", n)
	}
	return n, nil
}

// ListenPort returns the TCP port of an address such as ":8443",
// "127.0.0.1:8443" or a bare "8443". It returns 0 when addr is empty.
func ListenPort(addr string) (int, error) {
	if addr == "" {
		return 0, nil
	}
	_, port, err := net.SplitHostPort(addr)
	if err != nil {
		// A bare port is accepted by net.Listen as well.
		if n, convErr := strconv.Atoi(addr); convErr == nil {
			return ParsePort(strconv.Itoa(n))
		}
		return 0, fmt.Errorf("address %q is not host:port", addr)
	}
	return ParsePort(port)
}

// Endpoint is the public address of the HTTPS CONNECT proxy, split into the
// fields clients need.
type Endpoint struct {
	Scheme string `json:"scheme"`
	Host   string `json:"host"`
	Port   int    `json:"port"`
}

// ParseEndpoint splits the public proxy URL. The port defaults to 443 when the
// URL does not name one.
func ParseEndpoint(raw string) (Endpoint, error) {
	u, err := url.Parse(raw)
	if err != nil {
		return Endpoint{}, fmt.Errorf("parse %q: %w", raw, err)
	}
	host := u.Hostname()
	if host == "" {
		return Endpoint{}, fmt.Errorf("%q has no host name", raw)
	}
	port := 443
	if p := u.Port(); p != "" {
		n, err := strconv.Atoi(p)
		if err != nil {
			return Endpoint{}, fmt.Errorf("%q has a non-numeric port %q", raw, p)
		}
		port = n
	}
	if port < 1 || port > 65535 {
		return Endpoint{}, fmt.Errorf("%q has port %d outside 1-65535", raw, port)
	}
	return Endpoint{Scheme: u.Scheme, Host: host, Port: port}, nil
}
