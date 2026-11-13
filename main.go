// Command dohcord-relay-credentials serves the Dohcord relay TURN credential
// endpoint over HTTPS and issues coturn TURN REST credentials.
//
// It is a single small HTTP service: GET /turn-credentials returns an
// RTCPeerConnection-compatible iceServers array whose username is
// "<unix-expiration>:Dohcord" and whose credential is the matching
// HMAC-SHA1 password derived from the coturn shared secret.
//
// The shared secret is read from disk on demand and is never logged or returned
// to clients. Nothing is persisted: no database, no accounts, no client keys.
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
	"os"
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
		configPath  = flag.String("config", defaultConfigPath, "path to the configuration file")
		printConfig = flag.Bool("print-config", false, "print the effective configuration (never the secret) and exit")
		acmeOnly    = flag.Bool("acme-only", false, "serve only the ACME HTTP-01 responder (used while the certificate is being obtained)")
	)
	flag.Parse()

	logger := log.New(os.Stderr, "dohcord-relay-credentials: ", log.LstdFlags)

	cfg, err := loadConfig(*configPath)
	if err != nil {
		logger.Printf("ERROR invalid configuration in %s: %v", *configPath, err)
		os.Exit(1)
	}

	if *printConfig {
		printEffectiveConfig(os.Stdout, cfg)
		return
	}

	if *acmeOnly {
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
	turnURLs    []string
	identity    string
	ttl         time.Duration
	secretFile  string
	certFile    string
	keyFile     string
	httpsListen string
	httpListen  string
	acmeWebroot string
	perIPRate   int
	perIPBurst  int
	globalRate  int
	globalBurst int
	trustProxy  bool
}

func defaultConfig() config {
	return config{
		turnURLs: []string{
			"turn:13.48.52.216:3478?transport=udp",
			"turns:13.48.52.216:5349?transport=tcp",
		},
		identity:    "Dohcord",
		ttl:         24 * time.Hour,
		secretFile:  "/etc/dohcord-relay/turn-secret",
		certFile:    "/etc/dohcord-relay/tls/fullchain.pem",
		keyFile:     "/etc/dohcord-relay/tls/privkey.pem",
		httpsListen: ":443",
		httpListen:  ":80",
		acmeWebroot: "/var/www/dohcord-relay",
		perIPRate:   6,
		perIPBurst:  3,
		globalRate:  120,
		globalBurst: 60,
		trustProxy:  false,
	}
}

// loadConfig reads path (KEY=VALUE, '#' comments) over the built-in defaults.
func loadConfig(path string) (config, error) {
	cfg := defaultConfig()

	values, err := parseEnvFile(path)
	if err != nil {
		return config{}, err
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
	for _, u := range c.turnURLs {
		if !strings.HasPrefix(u, "turn:") && !strings.HasPrefix(u, "turns:") {
			return fmt.Errorf("TURN_URLS entry %q must start with turn: or turns:", u)
		}
	}
	if c.secretFile == "" {
		return errors.New("SECRET_FILE must be set")
	}
	if c.httpsListen != "" {
		if c.certFile == "" || c.keyFile == "" {
			return errors.New("TLS_CERT_FILE and TLS_KEY_FILE must be set when HTTPS_LISTEN is set")
		}
		if c.httpListen == ":443" || c.httpsListen == c.httpListen {
			return errors.New("HTTPS_LISTEN and HTTP_LISTEN must differ")
		}
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
	fmt.Fprintf(w, "TURN_URLS=%s\n", strings.Join(c.turnURLs, ","))
	fmt.Fprintf(w, "TURN_IDENTITY=%s\n", c.identity)
	fmt.Fprintf(w, "CREDENTIAL_TTL=%s\n", c.ttl)
	fmt.Fprintf(w, "SECRET_FILE=%s\n", c.secretFile)
	fmt.Fprintf(w, "TLS_CERT_FILE=%s\n", c.certFile)
	fmt.Fprintf(w, "TLS_KEY_FILE=%s\n", c.keyFile)
	fmt.Fprintf(w, "HTTPS_LISTEN=%s\n", c.httpsListen)
	fmt.Fprintf(w, "HTTP_LISTEN=%s\n", c.httpListen)
	fmt.Fprintf(w, "ACME_WEBROOT=%s\n", c.acmeWebroot)
	fmt.Fprintf(w, "PER_IP_RATE_PER_MINUTE=%d\n", c.perIPRate)
	fmt.Fprintf(w, "PER_IP_BURST=%d\n", c.perIPBurst)
	fmt.Fprintf(w, "GLOBAL_RATE_PER_MINUTE=%d\n", c.globalRate)
	fmt.Fprintf(w, "GLOBAL_BURST=%d\n", c.globalBurst)
	fmt.Fprintf(w, "TRUST_PROXY_HEADER=%t\n", c.trustProxy)
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
		now:    time.Now,
	}
}

type iceServer struct {
	URLs       []string `json:"urls"`
	Username   string   `json:"username"`
	Credential string   `json:"credential"`
}

type credentialsResponse struct {
	ExpiresAt  int64       `json:"expiresAt"`
	IceServers []iceServer `json:"iceServers"`
}

func (s *server) routes() http.Handler {
	mux := http.NewServeMux()
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

func (s *server) handleCredentials(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		writeJSON(w, http.StatusMethodNotAllowed, errorBody("method not allowed"))
		return
	}

	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, HEAD")
	w.Header().Set("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
	w.Header().Set("Pragma", "no-cache")
	w.Header().Set("X-Content-Type-Options", "nosniff")

	now := s.now()

	clientIP := s.clientIP(r)
	if ok, retry := s.global.allow("global", now); !ok {
		retryAfter(w, retry)
		writeJSON(w, http.StatusTooManyRequests, errorBody("global request limit reached"))
		return
	}
	if ok, retry := s.perIP.allow(clientIP, now); !ok {
		retryAfter(w, retry)
		writeJSON(w, http.StatusTooManyRequests, errorBody("too many requests from this address"))
		return
	}

	secret, err := s.secret.get()
	if err != nil {
		// Deliberately vague to the client; the details stay in the local log.
		s.log.Printf("ERROR turn configuration unavailable: %v", err)
		writeJSON(w, http.StatusServiceUnavailable, errorBody("turn configuration unavailable"))
		return
	}

	username, password, expiresAt := issueCredential(secret, s.cfg.identity, s.cfg.ttl, now)

	writeJSON(w, http.StatusOK, credentialsResponse{
		ExpiresAt: expiresAt,
		IceServers: []iceServer{{
			URLs:       s.cfg.turnURLs,
			Username:   username,
			Credential: password,
		}},
	})

	// Log the issuance without the credential: the username and password are
	// bearer secrets for the lifetime of the allocation.
	s.log.Printf("issued turn credential client=%s expires_at=%d", clientIP, expiresAt)
}

var acmeToken = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)

// handleACMEChallenge serves HTTP-01 validation files from the webroot. It exists
// only so certbot can prove control of the IP address; it is not an API.
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
	http.ServeFile(w, r, filepath.Join(s.cfg.acmeWebroot, token))
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

// run starts the HTTPS endpoint (and the port-80 ACME responder, when enabled)
// and blocks until SIGTERM/SIGINT.
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

		s.log.Printf("https credential endpoint listening on %s (/turn-credentials), turn_urls=%s ttl=%s",
			s.cfg.httpsListen, strings.Join(s.cfg.turnURLs, ","), s.cfg.ttl)
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
