// Package api serves the public relay configuration endpoints.
//
//	GET /network-config   the HTTPS proxy URL, its destination policy and
//	                      temporary TURN credentials, in one document
//	GET /turn-credentials the TURN iceServers block alone (legacy clients)
//
// It also answers ACME HTTP-01 challenges on port 80. The TURN shared secret is
// read from disk on demand and is never logged or returned to clients. Nothing is
// persisted: no database, no accounts, no permanent client credentials.
package api

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/Newipe/Pishcord-relay/internal/config"
	"github.com/Newipe/Pishcord-relay/internal/credentials"
	"github.com/Newipe/Pishcord-relay/internal/policy"
	"github.com/Newipe/Pishcord-relay/internal/ratelimit"
)

type Server struct {
	cfg    config.Config
	log    *log.Logger
	secret *secretStore
	certs  *certReloader
	perIP  *ratelimit.Limiter
	global *ratelimit.Limiter
	policy *policy.Cache

	// proxy caches the parsed form of HTTPS_PROXY_URL. The endpoint does not
	// change while the process runs, so every profile load reuses it; the raw
	// string is compared so a replaced value is still parsed (and rejected).
	proxy atomic.Value // *proxyEndpoint; interface-based so the code still builds with Go 1.18

	// snapshot holds the JSON encoding of the policy-derived parts of the
	// document, rebuilt only when the policy itself changes. Two profile loads
	// that see the same policy share it without locking.
	snapshot atomic.Value // *policySnapshot

	// Encoded once: the document's static fields. Writing them directly avoids
	// re-encoding (and re-compacting) kilobytes on every profile load.
	proxyJSON json.RawMessage
	urlJSON   json.RawMessage
	urlsJSON  json.RawMessage

	bufs sync.Pool // *bytes.Buffer, reused for response encoding

	now func() time.Time
}

type proxyEndpoint struct {
	raw  string
	desc config.Endpoint
}

// endpoint returns the published proxy descriptor, parsing HTTPS_PROXY_URL only
// when it is not the value already parsed.
func (s *Server) endpoint() (config.Endpoint, bool) {
	if cached, _ := s.proxy.Load().(*proxyEndpoint); cached != nil && cached.raw == s.cfg.ProxyURL {
		return cached.desc, true
	}
	desc, err := config.ParseEndpoint(s.cfg.ProxyURL)
	if err != nil {
		return config.Endpoint{}, false
	}
	s.proxy.Store(&proxyEndpoint{raw: s.cfg.ProxyURL, desc: desc})
	return desc, true
}

type policySnapshot struct {
	policy *policy.Policy

	// allowedDestinations and routing are the encoded JSON fragments of the
	// document, so a request does not re-encode an unchanged policy.
	allowedDestinations json.RawMessage
	routing             json.RawMessage
}

func New(cfg config.Config, logger *log.Logger) *Server {
	s := &Server{
		cfg:    cfg,
		log:    logger,
		secret: &secretStore{path: cfg.SecretFile},
		certs:  &certReloader{CertFile: cfg.CertFile, KeyFile: cfg.KeyFile},
		perIP:  ratelimit.New(cfg.PerIPRate, cfg.PerIPBurst),
		global: ratelimit.New(cfg.GlobalRate, cfg.GlobalBurst),
		policy: &policy.Cache{
			DomainsPath: cfg.AllowedDomainsFile,
			PolicyPath:  cfg.DestinationPolicyFile,
			StatePath:   cfg.PolicyStateFile,
		},
		now: time.Now,
	}
	s.bufs.New = func() any { return new(bytes.Buffer) }
	// The values are validated by config.Validate, so these cannot fail; a
	// failed marshal leaves an empty fragment and the document stays valid JSON.
	if desc, err := config.ParseEndpoint(cfg.ProxyURL); err == nil {
		s.proxyJSON, _ = json.Marshal(desc)
	}
	s.urlJSON, _ = json.Marshal(cfg.ProxyURL)
	s.urlsJSON, _ = json.Marshal(cfg.TurnURLs)
	return s
}

// writeNetworkConfig writes the exact wire shape of /network-config: the static
// fields are pre-encoded, the policy fragments come from the snapshot, and only
// the credential fields are encoded per request. The field order and names are
// what older clients already parse.
//
// The pieces are written straight into one buffer, so a profile load performs no
// reflective encoding of the document and sends a single response body.
func (s *Server) writeNetworkConfig(w http.ResponseWriter, snap *policySnapshot, ice []iceServer, expiresAt int64) {
	server := ice[0]
	username, _ := json.Marshal(server.Username)
	credential, _ := json.Marshal(server.Credential)

	buf := s.bufs.Get().(*bytes.Buffer)
	buf.Reset()
	buf.Grow(1024 + len(snap.allowedDestinations) + len(snap.routing))

	buf.WriteString(`{"schemaVersion":`)
	buf.WriteString(strconv.Itoa(policy.SchemaVersion))
	buf.WriteString(`,"version":`)
	buf.WriteString(strconv.Itoa(policy.SchemaVersion))
	buf.WriteString(`,"proxy":`)
	buf.Write(s.proxyJSON)
	buf.WriteString(`,"httpsProxy":{"url":`)
	buf.Write(s.urlJSON)
	buf.WriteString(`,"allowedDestinations":`)
	buf.Write(snap.allowedDestinations)
	buf.WriteString(`},"routing":{"domains":`)
	buf.Write(snap.routing)
	buf.WriteString(`},"rtcRelay":{"expiresAt":`)
	buf.WriteString(strconv.FormatInt(expiresAt, 10))
	buf.WriteString(`,"iceServers":[{"urls":`)
	buf.Write(s.urlsJSON)
	buf.WriteString(`,"username":`)
	buf.Write(username)
	buf.WriteString(`,"credential":`)
	buf.Write(credential)
	buf.WriteString("}]}}\n")

	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Content-Length", strconv.Itoa(buf.Len()))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(buf.Bytes())
	s.bufs.Put(buf)
}

// snapshotFor returns the encoded policy fragments for pol, rebuilding them only
// when the cache handed back a different policy.
func (s *Server) snapshotFor(pol *policy.Policy) (*policySnapshot, error) {
	if snap, _ := s.snapshot.Load().(*policySnapshot); snap != nil && snap.policy == pol {
		return snap, nil
	}
	destinations, err := json.Marshal(pol.Destinations)
	if err != nil {
		return nil, err
	}
	routing, err := json.Marshal(pol.RoutingRules())
	if err != nil {
		return nil, err
	}
	snap := &policySnapshot{policy: pol, allowedDestinations: destinations, routing: routing}
	s.snapshot.Store(snap)
	return snap, nil
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
	URL                 string               `json:"url"`
	AllowedDestinations []policy.Destination `json:"allowedDestinations"`
}

type routingPolicy struct {
	Domains []policy.RoutingRule `json:"domains"`
}

type networkConfig struct {
	// SchemaVersion is the version of this document. version (below) is the
	// field older clients read and carries the same value.
	SchemaVersion int             `json:"schemaVersion"`
	Version       int             `json:"version"`
	Proxy         config.Endpoint `json:"proxy"`
	HTTPSProxy    httpsProxyInfo  `json:"httpsProxy"`
	Routing       routingPolicy   `json:"routing"`
	RTCRelay      rtcRelay        `json:"rtcRelay"`
}

// writeDocument encodes doc into a pooled buffer and writes it in one call. The
// response is a few kilobytes, so this removes a per-request buffer allocation
// and the chunked framing json.Encoder would produce.
func (s *Server) writeDocument(w http.ResponseWriter, status int, doc any) {
	buf := s.bufs.Get().(*bytes.Buffer)
	buf.Reset()
	err := json.NewEncoder(buf).Encode(doc)
	if err != nil {
		s.bufs.Put(buf)
		writeJSON(w, http.StatusInternalServerError, errorBody("encode response"))
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Content-Length", strconv.Itoa(buf.Len()))
	w.WriteHeader(status)
	_, _ = w.Write(buf.Bytes())
	s.bufs.Put(buf)
}

type credentialsResponse struct {
	ExpiresAt  int64       `json:"expiresAt"`
	IceServers []iceServer `json:"iceServers"`
}

func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/network-config", s.handleNetworkConfig)
	mux.HandleFunc("/turn-credentials", s.handleCredentials)
	return mux
}

func (s *Server) ACMERoutes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/.well-known/acme-challenge/", s.handleACMEChallenge)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusNotFound)
		fmt.Fprintln(w, "pishcord-relay: HTTPS only")
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
func (s *Server) allowRequest(w http.ResponseWriter, r *http.Request, now time.Time) (string, bool) {
	clientIP := s.clientIP(r)
	if ok, retry := s.global.Allow("global", now); !ok {
		retryAfter(w, retry)
		// One line per refusal: diagnostics count these, and a working relay
		// should log none.
		s.log.Printf("rate limited client=%s scope=global retry_after=%s", clientIP, retry)
		writeJSON(w, http.StatusTooManyRequests, errorBody("global request limit reached"))
		return clientIP, false
	}
	if ok, retry := s.perIP.Allow(clientIP, now); !ok {
		retryAfter(w, retry)
		s.log.Printf("rate limited client=%s scope=per-ip retry_after=%s", clientIP, retry)
		writeJSON(w, http.StatusTooManyRequests, errorBody("too many requests from this address"))
		return clientIP, false
	}
	return clientIP, true
}

func (s *Server) issue(now time.Time) ([]iceServer, int64, error) {
	secret, err := s.secret.get()
	if err != nil {
		return nil, 0, err
	}
	username, password, expiresAt := credentials.Issue(secret, s.cfg.Identity, s.cfg.TTL, now)
	return []iceServer{{
		URLs:       s.cfg.TurnURLs,
		Username:   username,
		Credential: password,
	}}, expiresAt, nil
}

// handleNetworkConfig returns the proxy and TURN configuration produced from the
// server's own configuration and the policy Squid is enforcing.
func (s *Server) handleNetworkConfig(w http.ResponseWriter, r *http.Request) {
	if !allowedMethod(w, r) {
		return
	}
	setAPIHeaders(w)

	now := s.now()
	clientIP, ok := s.allowRequest(w, r, now)
	if !ok {
		return
	}

	pol, err := s.policy.Get()
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
	// relay cannot state. It is parsed once at startup (and re-validated by
	// config.Validate).
	if _, ok = s.endpoint(); !ok {
		s.log.Printf("ERROR proxy endpoint unusable: %q", s.cfg.ProxyURL)
		writeJSON(w, http.StatusServiceUnavailable, errorBody("proxy configuration unavailable"))
		return
	}

	snap, err := s.snapshotFor(pol)
	if err != nil {
		s.log.Printf("ERROR encoding destination policy: %v", err)
		writeJSON(w, http.StatusInternalServerError, errorBody("encode response"))
		return
	}

	s.writeNetworkConfig(w, snap, ice, expiresAt)

	// Log issuance without the credential: it is a bearer secret for the
	// lifetime of the allocation.
	s.log.Printf("served network-config client=%s destinations=%d expires_at=%d",
		clientIP, len(pol.Destinations), expiresAt)
}

// handleCredentials serves the pre-network-config response shape.
func (s *Server) handleCredentials(w http.ResponseWriter, r *http.Request) {
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

// run starts the HTTPS API (and the port-80 ACME responder, when enabled) and
// blocks until SIGTERM/SIGINT.
func (s *Server) Run() error {
	errc := make(chan error, 2)
	var servers []*http.Server

	shutdown := func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		for _, srv := range servers {
			_ = srv.Shutdown(ctx)
		}
	}

	if s.cfg.HTTPSListen != "" {
		if _, err := s.certs.load(true); err != nil {
			return fmt.Errorf("load TLS certificate: %w", err)
		}

		ln, err := net.Listen("tcp", s.cfg.HTTPSListen)
		if err != nil {
			return fmt.Errorf("listen on %s: %w", s.cfg.HTTPSListen, err)
		}

		tlsCfg := &tls.Config{
			GetCertificate: s.certs.getCertificate,
			MinVersion:     tls.VersionTLS12,
			NextProtos:     []string{"h2", "http/1.1"},
		}
		srv := &http.Server{
			Handler:           s.Routes(),
			ReadHeaderTimeout: 5 * time.Second,
			ReadTimeout:       10 * time.Second,
			WriteTimeout:      15 * time.Second,
			IdleTimeout:       60 * time.Second,
			ErrorLog:          s.log,
		}
		servers = append(servers, srv)
		go func() { errc <- srv.Serve(tls.NewListener(ln, tlsCfg)) }()

		s.log.Printf("https api listening on %s (/network-config, /turn-credentials), proxy=%s turn_urls=%s TTL=%s",
			s.cfg.HTTPSListen, s.cfg.ProxyURL, strings.Join(s.cfg.TurnURLs, ","), s.cfg.TTL)
	}

	if s.cfg.HTTPListen != "" {
		ln, err := net.Listen("tcp", s.cfg.HTTPListen)
		if err != nil {
			shutdown()
			return fmt.Errorf("listen on %s for ACME HTTP-01: %w", s.cfg.HTTPListen, err)
		}
		srv := &http.Server{
			Handler:           s.ACMERoutes(),
			ReadHeaderTimeout: 5 * time.Second,
			ReadTimeout:       10 * time.Second,
			WriteTimeout:      15 * time.Second,
			IdleTimeout:       30 * time.Second,
			ErrorLog:          s.log,
		}
		servers = append(servers, srv)
		go func() { errc <- srv.Serve(ln) }()

		s.log.Printf("acme http-01 responder listening on %s (webroot %s)", s.cfg.HTTPListen, s.cfg.ACMEWebroot)
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
