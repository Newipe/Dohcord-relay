// Command dohcord-relay serves the public configuration API for a Dohcord relay
// VPS and manages the destination policy of the HTTPS CONNECT proxy.
//
//	GET /network-config   the HTTPS proxy URL, its destination policy and
//	                      temporary TURN credentials, in one document
//	GET /turn-credentials the TURN iceServers block alone (legacy clients)
//
// It also answers ACME HTTP-01 challenges on port 80, and the -policy-apply
// command validates /etc/dohcord-relay/allowed-domains.txt and
// /etc/dohcord-relay/destination-policy.conf, renders the Squid ACL include and
// only then reloads Squid.
//
// The TURN shared secret is read from disk on demand and is never logged or
// returned to clients. Nothing is persisted: no database, no accounts, no
// permanent client credentials.
package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	defaultConfigPath = "/etc/dohcord-relay/config.env"

	maxIdentityLength = 64
	maxTTL            = 7 * 24 * time.Hour
	minTTL            = time.Minute
	maxSecretBytes    = 4096
)

func main() {
	var (
		configPath     = flag.String("config", defaultConfigPath, "path to the configuration file")
		printConfig    = flag.Bool("print-config", false, "print the effective configuration (never the secret) and exit")
		acmeOnly       = flag.Bool("acme-only", false, "serve only the ACME HTTP-01 responder (used while the certificate is being obtained)")
		policyCheck    = flag.Bool("policy-check", false, "validate the destination policy files and exit")
		policyApply    = flag.Bool("policy-apply", false, "validate the destination policy, render the Squid include and reload Squid, then exit")
		policyNoReload = flag.Bool("no-reload", false, "with -policy-apply: write the validated policy without reloading Squid")
	)
	flag.Parse()

	logger := log.New(os.Stderr, "dohcord-relay: ", log.LstdFlags)

	cfg, err := loadConfig(*configPath)
	if err != nil {
		logger.Printf("ERROR invalid configuration in %s: %v", *configPath, err)
		os.Exit(1)
	}

	switch {
	case *policyCheck:
		p, err := LoadPolicy(cfg.allowedDomainsFile, cfg.destinationPolicyFile)
		if err != nil {
			logger.Printf("ERROR policy invalid: %v", err)
			os.Exit(1)
		}
		printPolicySummary(os.Stdout, p)
		return
	case *policyApply:
		if err := applyPolicy(cfg, !*policyNoReload, logger); err != nil {
			logger.Printf("ERROR %v", err)
			os.Exit(1)
		}
		return
	case *printConfig:
		printEffectiveConfig(os.Stdout, cfg)
		return
	case *acmeOnly:
		// Bootstrapping: answer HTTP-01 challenges only, because no HTTPS
		// certificate exists yet.
		cfg.httpsListen = ""
	}

	srv := newServer(cfg, logger)
	if err := srv.run(); err != nil {
		logger.Printf("ERROR server stopped: %v", err)
		os.Exit(1)
	}
}

// config is the runtime configuration, read from a small KEY=VALUE file so the
// installer can write it and systemd can pass a single path.
type config struct {
	// Public identity of the relay, as clients must reach it.
	proxyURL string // https://host:443 - the HTTPS CONNECT proxy
	apiURL   string // https://host:8443/network-config, for logs and reports

	turnURLs   []string
	identity   string
	ttl        time.Duration
	secretFile string
	certFile   string
	keyFile    string

	httpsListen string
	httpListen  string
	acmeWebroot string

	// Destination policy.
	allowedDomainsFile    string
	destinationPolicyFile string
	policyStateFile       string
	squidConf             string
	squidAllowFile        string
	squidBinary           string

	perIPRate   int
	perIPBurst  int
	globalRate  int
	globalBurst int
	trustProxy  bool
}

func defaultConfig() config {
	return config{
		identity:              "Dohcord",
		ttl:                   24 * time.Hour,
		secretFile:            "/etc/dohcord-relay/turn-secret",
		certFile:              "/etc/dohcord-relay/tls/fullchain.pem",
		keyFile:               "/etc/dohcord-relay/tls/privkey.pem",
		httpsListen:           ":8443",
		httpListen:            ":80",
		acmeWebroot:           "/var/www/dohcord-relay",
		allowedDomainsFile:    "/etc/dohcord-relay/allowed-domains.txt",
		destinationPolicyFile: "/etc/dohcord-relay/destination-policy.conf",
		policyStateFile:       "/etc/dohcord-relay/policy.json",
		squidConf:             "/etc/dohcord-relay/squid.conf",
		squidAllowFile:        "/etc/dohcord-relay/squid-allow.conf",
		squidBinary:           "/usr/sbin/squid",
		perIPRate:             6,
		perIPBurst:            3,
		globalRate:            120,
		globalBurst:           60,
	}
}

// loadConfig reads path (KEY=VALUE, '#' comments) over the built-in defaults.
func loadConfig(path string) (config, error) {
	cfg := defaultConfig()

	values, err := parseEnvFile(path)
	if err != nil {
		return config{}, err
	}

	if v, ok := values["HTTPS_PROXY_URL"]; ok {
		cfg.proxyURL = v
	}
	if v, ok := values["NETWORK_CONFIG_URL"]; ok {
		cfg.apiURL = v
	}
	if v, ok := values["TURN_URLS"]; ok {
		urls := splitList(v)
		if len(urls) == 0 {
			return config{}, errors.New("TURN_URLS must list at least one TURN URL")
		}
		cfg.turnURLs = urls
	}
	if v, ok := values["TURN_IDENTITY"]; ok {
		cfg.identity = v
	}
	if v, ok := values["CREDENTIAL_TTL"]; ok {
		ttl, err := parseDuration(v)
		if err != nil {
			return config{}, fmt.Errorf("CREDENTIAL_TTL: %w", err)
		}
		cfg.ttl = ttl
	}
	if v, ok := values["SECRET_FILE"]; ok {
		cfg.secretFile = v
	}
	if v, ok := values["TLS_CERT_FILE"]; ok {
		cfg.certFile = v
	}
	if v, ok := values["TLS_KEY_FILE"]; ok {
		cfg.keyFile = v
	}
	if v, ok := values["HTTPS_LISTEN"]; ok {
		cfg.httpsListen = v
	}
	if v, ok := values["HTTP_LISTEN"]; ok {
		cfg.httpListen = v
	}
	if v, ok := values["ACME_WEBROOT"]; ok {
		cfg.acmeWebroot = v
	}
	if v, ok := values["ALLOWED_DOMAINS_FILE"]; ok {
		cfg.allowedDomainsFile = v
	}
	if v, ok := values["DESTINATION_POLICY_FILE"]; ok {
		cfg.destinationPolicyFile = v
	}
	if v, ok := values["POLICY_STATE_FILE"]; ok {
		cfg.policyStateFile = v
	}
	if v, ok := values["SQUID_CONF"]; ok {
		cfg.squidConf = v
	}
	if v, ok := values["SQUID_ALLOW_FILE"]; ok {
		cfg.squidAllowFile = v
	}
	if v, ok := values["SQUID_BINARY"]; ok {
		cfg.squidBinary = v
	}
	if v, ok := values["PER_IP_RATE_PER_MINUTE"]; ok {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 {
			return config{}, fmt.Errorf("PER_IP_RATE_PER_MINUTE must be a positive integer, got %q", v)
		}
		cfg.perIPRate = n
	}
	if v, ok := values["PER_IP_BURST"]; ok {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 {
			return config{}, fmt.Errorf("PER_IP_BURST must be a positive integer, got %q", v)
		}
		cfg.perIPBurst = n
	}
	if v, ok := values["GLOBAL_RATE_PER_MINUTE"]; ok {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 {
			return config{}, fmt.Errorf("GLOBAL_RATE_PER_MINUTE must be a positive integer, got %q", v)
		}
		cfg.globalRate = n
	}
	if v, ok := values["GLOBAL_BURST"]; ok {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 {
			return config{}, fmt.Errorf("GLOBAL_BURST must be a positive integer, got %q", v)
		}
		cfg.globalBurst = n
	}
	if v, ok := values["TRUST_PROXY_HEADER"]; ok {
		b, err := strconv.ParseBool(v)
		if err != nil {
			return config{}, fmt.Errorf("TRUST_PROXY_HEADER must be true or false, got %q", v)
		}
		cfg.trustProxy = b
	}

	if err := cfg.validate(); err != nil {
		return config{}, err
	}
	return cfg, nil
}

func (c config) validate() error {
	if err := validateIdentity(c.identity); err != nil {
		return err
	}
	if len(c.identity) > maxIdentityLength {
		return fmt.Errorf("TURN_IDENTITY must be at most %d characters", maxIdentityLength)
	}
	if c.ttl < minTTL || c.ttl > maxTTL {
		return fmt.Errorf("CREDENTIAL_TTL must be between %s and %s", minTTL, maxTTL)
	}
	if len(c.turnURLs) == 0 {
		return errors.New("TURN_URLS must list at least one TURN URL")
	}
	for _, u := range c.turnURLs {
		if !strings.HasPrefix(u, "turn:") && !strings.HasPrefix(u, "turns:") {
			return fmt.Errorf("TURN_URLS entry %q must start with turn: or turns:", u)
		}
	}
	if c.secretFile == "" {
		return errors.New("SECRET_FILE must be set")
	}
	if err := validatePublicURL("HTTPS_PROXY_URL", c.proxyURL); err != nil {
		return err
	}
	// The endpoint publishes these fields, so an unusable proxy URL must stop the
	// service at startup rather than produce a document with missing routing data.
	if _, err := endpointFromURL(c.proxyURL); err != nil {
		return fmt.Errorf("HTTPS_PROXY_URL: %w", err)
	}
	if c.apiURL != "" {
		if err := validatePublicURL("NETWORK_CONFIG_URL", c.apiURL); err != nil {
			return err
		}
	}
	for name, p := range map[string]string{
		"ALLOWED_DOMAINS_FILE":    c.allowedDomainsFile,
		"DESTINATION_POLICY_FILE": c.destinationPolicyFile,
		"POLICY_STATE_FILE":       c.policyStateFile,
		"SQUID_CONF":              c.squidConf,
		"SQUID_ALLOW_FILE":        c.squidAllowFile,
	} {
		if p == "" {
			return fmt.Errorf("%s must be set", name)
		}
	}
	if c.httpsListen != "" {
		if c.certFile == "" || c.keyFile == "" {
			return errors.New("TLS_CERT_FILE and TLS_KEY_FILE must be set when HTTPS_LISTEN is set")
		}
		if c.httpsListen == ":443" || c.httpsListen == c.httpListen {
			return fmt.Errorf("HTTPS_LISTEN must not be :443 (the HTTPS CONNECT proxy owns that port) or equal HTTP_LISTEN")
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

func printEffectiveConfig(w *os.File, c config) {
	fmt.Fprintf(w, "HTTPS_PROXY_URL=%s\n", c.proxyURL)
	fmt.Fprintf(w, "NETWORK_CONFIG_URL=%s\n", c.apiURL)
	fmt.Fprintf(w, "TURN_URLS=%s\n", strings.Join(c.turnURLs, ","))
	fmt.Fprintf(w, "TURN_IDENTITY=%s\n", c.identity)
	fmt.Fprintf(w, "CREDENTIAL_TTL=%s\n", c.ttl)
	fmt.Fprintf(w, "SECRET_FILE=%s\n", c.secretFile)
	fmt.Fprintf(w, "TLS_CERT_FILE=%s\n", c.certFile)
	fmt.Fprintf(w, "TLS_KEY_FILE=%s\n", c.keyFile)
	fmt.Fprintf(w, "HTTPS_LISTEN=%s\n", c.httpsListen)
	fmt.Fprintf(w, "HTTP_LISTEN=%s\n", c.httpListen)
	fmt.Fprintf(w, "ACME_WEBROOT=%s\n", c.acmeWebroot)
	fmt.Fprintf(w, "ALLOWED_DOMAINS_FILE=%s\n", c.allowedDomainsFile)
	fmt.Fprintf(w, "DESTINATION_POLICY_FILE=%s\n", c.destinationPolicyFile)
	fmt.Fprintf(w, "POLICY_STATE_FILE=%s\n", c.policyStateFile)
	fmt.Fprintf(w, "SQUID_CONF=%s\n", c.squidConf)
	fmt.Fprintf(w, "SQUID_ALLOW_FILE=%s\n", c.squidAllowFile)
	fmt.Fprintf(w, "SQUID_BINARY=%s\n", c.squidBinary)
	fmt.Fprintf(w, "PER_IP_RATE_PER_MINUTE=%d\n", c.perIPRate)
	fmt.Fprintf(w, "PER_IP_BURST=%d\n", c.perIPBurst)
	fmt.Fprintf(w, "GLOBAL_RATE_PER_MINUTE=%d\n", c.globalRate)
	fmt.Fprintf(w, "GLOBAL_BURST=%d\n", c.globalBurst)
	fmt.Fprintf(w, "TRUST_PROXY_HEADER=%t\n", c.trustProxy)
}

// printPolicySummary prints the effective policy in the destination-policy.conf
// format, which is what an operator wants to see after validation.
func printPolicySummary(w *os.File, p *Policy) {
	fmt.Fprintf(w, "destination policy is valid: %d domains\n", len(p.Destinations))
	for _, d := range p.Destinations {
		fmt.Fprintf(w, "  %-28s %s\n", d.Domain, d.PortList())
	}
}

// ---------------------------------------------------------------------------
// Destination policy application
// ---------------------------------------------------------------------------

// applyPolicy validates the two operator files, renders the Squid ACL include,
// checks the complete Squid configuration with `squid -k parse`, installs the
// include and the policy state, and only after all of that reloads Squid. A
// failure at any step leaves the previous, working policy in place.
func applyPolicy(cfg config, reload bool, logger *log.Logger) error {
	p, err := LoadPolicy(cfg.allowedDomainsFile, cfg.destinationPolicyFile)
	if err != nil {
		return fmt.Errorf("policy invalid: %w", err)
	}
	printPolicySummary(os.Stdout, p)

	include := p.SquidACL()
	allowDir := filepath.Dir(cfg.squidAllowFile)
	if err := os.MkdirAll(allowDir, 0o755); err != nil {
		return fmt.Errorf("create %s: %w", allowDir, err)
	}

	// Stage the rendered include next to its final location so the validation
	// run and the installed file are the same bytes.
	staged, err := os.CreateTemp(allowDir, ".squid-allow-*.conf")
	if err != nil {
		return fmt.Errorf("stage Squid include: %w", err)
	}
	stagedName := staged.Name()
	defer os.Remove(stagedName)
	if _, err := staged.WriteString(include); err != nil {
		staged.Close()
		return fmt.Errorf("write staged Squid include: %w", err)
	}
	if err := staged.Close(); err != nil {
		return fmt.Errorf("close staged Squid include: %w", err)
	}
	if err := os.Chmod(stagedName, 0o644); err != nil {
		return fmt.Errorf("chmod staged Squid include: %w", err)
	}

	confData, err := os.ReadFile(cfg.squidConf)
	if err != nil {
		return fmt.Errorf("read Squid configuration %s: %w", cfg.squidConf, err)
	}
	wantInclude := SquidIncludeLine(cfg.squidAllowFile)
	if !strings.Contains(string(confData), wantInclude) {
		return fmt.Errorf("%s does not contain %q; refusing to apply a policy Squid would not read", cfg.squidConf, wantInclude)
	}
	stagedConf := strings.ReplaceAll(string(confData), wantInclude, SquidIncludeLine(stagedName))

	confFile, err := os.CreateTemp(allowDir, ".squid-conf-*.conf")
	if err != nil {
		return fmt.Errorf("stage Squid configuration: %w", err)
	}
	stagedConfName := confFile.Name()
	defer os.Remove(stagedConfName)
	if _, err := confFile.WriteString(stagedConf); err != nil {
		confFile.Close()
		return fmt.Errorf("write staged Squid configuration: %w", err)
	}
	if err := confFile.Close(); err != nil {
		return fmt.Errorf("close staged Squid configuration: %w", err)
	}

	// Validate the whole configuration, not just the include: a syntax error, a
	// missing certificate or an ACL that does not resolve all abort here.
	// Squid exits non-zero on a fatal parse error and prints "FATAL:"; both are
	// checked, and nothing narrower, because ordinary directive names contain
	// the word "error" (error_directory) and must not be mistaken for failures.
	out, err := exec.Command(cfg.squidBinary, "-k", "parse", "-f", stagedConfName).CombinedOutput()
	if err != nil || strings.Contains(string(out), "FATAL:") {
		return fmt.Errorf("Squid rejected the generated policy; the running configuration is unchanged:\n%s", strings.TrimSpace(string(out)))
	}

	if err := os.Rename(stagedName, cfg.squidAllowFile); err != nil {
		return fmt.Errorf("install %s: %w", cfg.squidAllowFile, err)
	}
	if err := SavePolicyState(cfg.policyStateFile, p); err != nil {
		return fmt.Errorf("write %s: %w", cfg.policyStateFile, err)
	}
	logger.Printf("policy applied: %d domains, include %s, state %s", len(p.Destinations), cfg.squidAllowFile, cfg.policyStateFile)

	if !reload {
		logger.Printf("policy staged but Squid not reloaded (-no-reload)")
		return nil
	}
	out, err = exec.Command(cfg.squidBinary, "-k", "reconfigure", "-f", cfg.squidConf).CombinedOutput()
	if err != nil {
		return fmt.Errorf("Squid failed to reload (it keeps serving the previous policy): %s\n%s", err, strings.TrimSpace(string(out)))
	}
	logger.Printf("Squid reloaded")
	return nil
}

// ---------------------------------------------------------------------------
// HTTP service
// ---------------------------------------------------------------------------

type server struct {
	cfg    config
	log    *log.Logger
	secret *secretStore
	certs  *certReloader
	perIP  *limiter
	global *limiter
	policy *policyCache

	now func() time.Time
}

func newServer(cfg config, logger *log.Logger) *server {
	return &server{
		cfg:    cfg,
		log:    logger,
		secret: &secretStore{path: cfg.secretFile},
		certs:  &certReloader{certFile: cfg.certFile, keyFile: cfg.keyFile},
		perIP:  newLimiter(cfg.perIPRate, cfg.perIPBurst),
		global: newLimiter(cfg.globalRate, cfg.globalBurst),
		policy: &policyCache{
			domainsPath: cfg.allowedDomainsFile,
			policyPath:  cfg.destinationPolicyFile,
			statePath:   cfg.policyStateFile,
		},
		now: time.Now,
	}
}

type iceServer struct {
	URLs       []string `json:"urls"`
	Username   string   `json:"username"`
	Credential string   `json:"credential"`
}

type rtcRelay struct {
	ExpiresAt  int64       `json:"expiresAt"`
	IceServers []iceServer `json:"iceServers"`
}

type httpsProxyInfo struct {
	URL                 string        `json:"url"`
	AllowedDestinations []Destination `json:"allowedDestinations"`
}

// proxyEndpoint is where clients reach the HTTPS CONNECT proxy. It is not the
// network-configuration endpoint: that one is normally on port 8443, while this
// is the proxy listener on port 443.
type proxyEndpoint struct {
	Scheme string `json:"scheme"`
	Host   string `json:"host"`
	Port   int    `json:"port"`
}

// routingPolicy is the client-facing routing contract: the destinations Dohcord
// may send through the proxy, with the matching mode and permitted ports. It is
// generated from the same policy that produces the Squid ACLs.
type routingPolicy struct {
	Domains []RoutingRule `json:"domains"`
}

type networkConfig struct {
	// SchemaVersion is the version of this document. version (below) is the
	// field older clients read and carries the same value.
	SchemaVersion int            `json:"schemaVersion"`
	Version       int            `json:"version"`
	Proxy         proxyEndpoint  `json:"proxy"`
	HTTPSProxy    httpsProxyInfo `json:"httpsProxy"`
	Routing       routingPolicy  `json:"routing"`
	RTCRelay      rtcRelay       `json:"rtcRelay"`
}

// endpointFromURL splits the public proxy URL into the fields clients need. The
// port defaults to 443 when the URL does not name one.
func endpointFromURL(raw string) (proxyEndpoint, error) {
	u, err := url.Parse(raw)
	if err != nil {
		return proxyEndpoint{}, fmt.Errorf("parse %q: %w", raw, err)
	}
	host := u.Hostname()
	if host == "" {
		return proxyEndpoint{}, fmt.Errorf("%q has no host name", raw)
	}
	port := 443
	if p := u.Port(); p != "" {
		n, err := strconv.Atoi(p)
		if err != nil {
			return proxyEndpoint{}, fmt.Errorf("%q has a non-numeric port %q", raw, p)
		}
		port = n
	}
	if port < 1 || port > 65535 {
		return proxyEndpoint{}, fmt.Errorf("%q has port %d outside 1-65535", raw, port)
	}
	return proxyEndpoint{Scheme: u.Scheme, Host: host, Port: port}, nil
}

// credentialsResponse is the legacy /turn-credentials document.
type credentialsResponse struct {
	ExpiresAt  int64       `json:"expiresAt"`
	IceServers []iceServer `json:"iceServers"`
}

func (s *server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/network-config", s.handleNetworkConfig)
	mux.HandleFunc("/turn-credentials", s.handleCredentials)
	return mux
}

func (s *server) acmeRoutes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/.well-known/acme-challenge/", s.handleACMEChallenge)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusNotFound)
		fmt.Fprintln(w, "dohcord-relay: HTTPS only")
	})
	return mux
}

func setAPIHeaders(w http.ResponseWriter) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, HEAD")
	w.Header().Set("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
	w.Header().Set("Pragma", "no-cache")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Referrer-Policy", "no-referrer")
}

// allowRequest applies the global and per-address limits shared by both API
// endpoints. It writes the refusal itself and reports whether to continue.
func (s *server) allowRequest(w http.ResponseWriter, r *http.Request, now time.Time) (string, bool) {
	clientIP := s.clientIP(r)
	if ok, retry := s.global.allow("global", now); !ok {
		retryAfter(w, retry)
		writeJSON(w, http.StatusTooManyRequests, errorBody("global request limit reached"))
		return clientIP, false
	}
	if ok, retry := s.perIP.allow(clientIP, now); !ok {
		retryAfter(w, retry)
		writeJSON(w, http.StatusTooManyRequests, errorBody("too many requests from this address"))
		return clientIP, false
	}
	return clientIP, true
}

func (s *server) issue(now time.Time) ([]iceServer, int64, error) {
	secret, err := s.secret.get()
	if err != nil {
		return nil, 0, err
	}
	username, password, expiresAt := issueCredential(secret, s.cfg.identity, s.cfg.ttl, now)
	return []iceServer{{
		URLs:       s.cfg.turnURLs,
		Username:   username,
		Credential: password,
	}}, expiresAt, nil
}

// handleNetworkConfig returns the proxy and TURN configuration produced from the
// server's own configuration and the policy Squid is enforcing.
func (s *server) handleNetworkConfig(w http.ResponseWriter, r *http.Request) {
	if !allowedMethod(w, r) {
		return
	}
	setAPIHeaders(w)

	now := s.now()
	clientIP, ok := s.allowRequest(w, r, now)
	if !ok {
		return
	}

	policy, err := s.policy.get()
	if err != nil {
		s.log.Printf("ERROR destination policy unavailable: %v", err)
		writeJSON(w, http.StatusServiceUnavailable, errorBody("destination policy unavailable"))
		return
	}
	ice, expiresAt, err := s.issue(now)
	if err != nil {
		// Deliberately vague to the client; the details stay in the local log.
		s.log.Printf("ERROR turn configuration unavailable: %v", err)
		writeJSON(w, http.StatusServiceUnavailable, errorBody("turn configuration unavailable"))
		return
	}

	// A proxy URL that cannot be described precisely is a configuration error,
	// not something to paper over: clients would be told to use an endpoint the
	// relay cannot state.
	desc, err := endpointFromURL(s.cfg.proxyURL)
	if err != nil {
		s.log.Printf("ERROR proxy endpoint unusable: %v", err)
		writeJSON(w, http.StatusServiceUnavailable, errorBody("proxy configuration unavailable"))
		return
	}

	writeJSON(w, http.StatusOK, networkConfig{
		SchemaVersion: schemaVersion,
		Version:       schemaVersion,
		Proxy:         desc,
		HTTPSProxy: httpsProxyInfo{
			URL:                 s.cfg.proxyURL,
			AllowedDestinations: policy.Destinations,
		},
		Routing:  routingPolicy{Domains: policy.RoutingRules()},
		RTCRelay: rtcRelay{ExpiresAt: expiresAt, IceServers: ice},
	})

	// Log issuance without the credential: it is a bearer secret for the
	// lifetime of the allocation.
	s.log.Printf("served network-config client=%s destinations=%d expires_at=%d",
		clientIP, len(policy.Destinations), expiresAt)
}

// handleCredentials serves the pre-network-config response shape.
func (s *server) handleCredentials(w http.ResponseWriter, r *http.Request) {
	if !allowedMethod(w, r) {
		return
	}
	setAPIHeaders(w)

	now := s.now()
	clientIP, ok := s.allowRequest(w, r, now)
	if !ok {
		return
	}

	ice, expiresAt, err := s.issue(now)
	if err != nil {
		s.log.Printf("ERROR turn configuration unavailable: %v", err)
		writeJSON(w, http.StatusServiceUnavailable, errorBody("turn configuration unavailable"))
		return
	}

	writeJSON(w, http.StatusOK, credentialsResponse{ExpiresAt: expiresAt, IceServers: ice})
	s.log.Printf("issued turn credential client=%s expires_at=%d", clientIP, expiresAt)
}

func allowedMethod(w http.ResponseWriter, r *http.Request) bool {
	if r.Method == http.MethodGet || r.Method == http.MethodHead {
		return true
	}
	w.Header().Set("Allow", "GET, HEAD")
	writeJSON(w, http.StatusMethodNotAllowed, errorBody("method not allowed"))
	return false
}

var acmeToken = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)

// handleACMEChallenge serves HTTP-01 validation files from the webroot. It exists
// only so certbot can prove control of the domain or IP address; it is not an API.
func (s *server) handleACMEChallenge(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	token := strings.TrimPrefix(r.URL.Path, "/.well-known/acme-challenge/")
	if !acmeToken.MatchString(token) {
		http.NotFound(w, r)
		return
	}
	// certbot --webroot writes challenge files to
	// <webroot>/.well-known/acme-challenge/<token>.
	http.ServeFile(w, r, filepath.Join(s.cfg.acmeWebroot, ".well-known", "acme-challenge", token))
}

func (s *server) clientIP(r *http.Request) string {
	if s.cfg.trustProxy {
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			first, _, _ := strings.Cut(xff, ",")
			if ip := strings.TrimSpace(first); ip != "" {
				return ip
			}
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func errorBody(msg string) map[string]string { return map[string]string{"error": msg} }

func retryAfter(w http.ResponseWriter, d time.Duration) {
	secs := int(d.Seconds())
	if secs < 1 {
		secs = 1
	}
	w.Header().Set("Retry-After", strconv.Itoa(secs))
}

// run starts the HTTPS API (and the port-80 ACME responder, when enabled) and
// blocks until SIGTERM/SIGINT.
func (s *server) run() error {
	errc := make(chan error, 2)
	var servers []*http.Server

	shutdown := func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		for _, srv := range servers {
			_ = srv.Shutdown(ctx)
		}
	}

	if s.cfg.httpsListen != "" {
		if _, err := s.certs.load(true); err != nil {
			return fmt.Errorf("load TLS certificate: %w", err)
		}

		ln, err := net.Listen("tcp", s.cfg.httpsListen)
		if err != nil {
			return fmt.Errorf("listen on %s: %w", s.cfg.httpsListen, err)
		}

		tlsCfg := &tls.Config{
			GetCertificate: s.certs.getCertificate,
			MinVersion:     tls.VersionTLS12,
			NextProtos:     []string{"h2", "http/1.1"},
		}
		srv := &http.Server{
			Handler:           s.routes(),
			ReadHeaderTimeout: 5 * time.Second,
			ReadTimeout:       10 * time.Second,
			WriteTimeout:      15 * time.Second,
			IdleTimeout:       60 * time.Second,
			ErrorLog:          s.log,
		}
		servers = append(servers, srv)
		go func() { errc <- srv.Serve(tls.NewListener(ln, tlsCfg)) }()

		s.log.Printf("https api listening on %s (/network-config, /turn-credentials), proxy=%s turn_urls=%s ttl=%s",
			s.cfg.httpsListen, s.cfg.proxyURL, strings.Join(s.cfg.turnURLs, ","), s.cfg.ttl)
	}

	if s.cfg.httpListen != "" {
		ln, err := net.Listen("tcp", s.cfg.httpListen)
		if err != nil {
			shutdown()
			return fmt.Errorf("listen on %s for ACME HTTP-01: %w", s.cfg.httpListen, err)
		}
		srv := &http.Server{
			Handler:           s.acmeRoutes(),
			ReadHeaderTimeout: 5 * time.Second,
			ReadTimeout:       10 * time.Second,
			WriteTimeout:      15 * time.Second,
			IdleTimeout:       30 * time.Second,
			ErrorLog:          s.log,
		}
		servers = append(servers, srv)
		go func() { errc <- srv.Serve(ln) }()

		s.log.Printf("acme http-01 responder listening on %s (webroot %s)", s.cfg.httpListen, s.cfg.acmeWebroot)
	}

	if len(servers) == 0 {
		return errors.New("no listener configured: set HTTPS_LISTEN or HTTP_LISTEN")
	}

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)

	for {
		select {
		case err := <-errc:
			shutdown()
			if errors.Is(err, http.ErrServerClosed) {
				return nil
			}
			return err
		case sig := <-sigCh:
			if sig == syscall.SIGHUP {
				// Certificate renewed or secret rotated: reload on the next
				// request/handshake.
				s.log.Printf("reloading certificate and turn secret")
				s.certs.invalidate()
				s.secret.invalidate()
				continue
			}
			s.log.Printf("shutting down on %s", sig)
			shutdown()
			return nil
		}
	}
}

// ---------------------------------------------------------------------------
// Secret and certificate reloading
// ---------------------------------------------------------------------------

// secretStore reads the coturn shared secret on demand, reusing the cached value
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
// without restarting the service.
type certReloader struct {
	certFile string
	keyFile  string

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

	certInfo, err := os.Stat(c.certFile)
	if err != nil {
		return nil, fmt.Errorf("stat certificate: %w", err)
	}
	keyInfo, err := os.Stat(c.keyFile)
	if err != nil {
		return nil, fmt.Errorf("stat private key: %w", err)
	}
	if c.cert != nil && !force &&
		certInfo.ModTime().Equal(c.certMod) && keyInfo.ModTime().Equal(c.keyMod) {
		return c.cert, nil
	}

	crt, err := tls.LoadX509KeyPair(c.certFile, c.keyFile)
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
