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
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/Newipe/Dohcord-relay/internal/config"
	"github.com/Newipe/Dohcord-relay/internal/credentials"
	"github.com/Newipe/Dohcord-relay/internal/policy"
	"github.com/Newipe/Dohcord-relay/internal/ratelimit"
)

type Server struct {
	cfg    config.Config
	log    *log.Logger
	secret *secretStore
	certs  *certReloader
	perIP  *ratelimit.Limiter
	global *ratelimit.Limiter
	policy *policy.Cache

	now func() time.Time
}

func New(cfg config.Config, logger *log.Logger) *Server {
	return &Server{
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
func (s *Server) allowRequest(w http.ResponseWriter, r *http.Request, now time.Time) (string, bool) {
	clientIP := s.clientIP(r)
	if ok, retry := s.global.Allow("global", now); !ok {
		retryAfter(w, retry)
		writeJSON(w, http.StatusTooManyRequests, errorBody("global request limit reached"))
		return clientIP, false
	}
	if ok, retry := s.perIP.Allow(clientIP, now); !ok {
		retryAfter(w, retry)
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
	// relay cannot state.
	desc, err := config.ParseEndpoint(s.cfg.ProxyURL)
	if err != nil {
		s.log.Printf("ERROR proxy endpoint unusable: %v", err)
		writeJSON(w, http.StatusServiceUnavailable, errorBody("proxy configuration unavailable"))
		return
	}

	writeJSON(w, http.StatusOK, networkConfig{
		SchemaVersion: policy.SchemaVersion,
		Version:       policy.SchemaVersion,
		Proxy:         desc,
		HTTPSProxy: httpsProxyInfo{
			URL:                 s.cfg.ProxyURL,
			AllowedDestinations: pol.Destinations,
		},
		Routing:  routingPolicy{Domains: pol.RoutingRules()},
		RTCRelay: rtcRelay{ExpiresAt: expiresAt, IceServers: ice},
	})

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
