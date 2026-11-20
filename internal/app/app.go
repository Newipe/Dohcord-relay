// Package app wires the command-line entry point of the relay: it loads the
// configuration, runs the one-shot maintenance commands and starts the API.
package app

import (
	"flag"
	"fmt"
	"log"
	"os"

	"github.com/Newipe/Dohcord-relay/internal/api"
	"github.com/Newipe/Dohcord-relay/internal/buildinfo"
	"github.com/Newipe/Dohcord-relay/internal/config"
	"github.com/Newipe/Dohcord-relay/internal/policy"
)

// Main runs the dohcord-relay command and exits non-zero on failure.
func Main() {
	var (
		configPath     = flag.String("config", config.DefaultPath, "path to the configuration file")
		printConfig    = flag.Bool("print-config", false, "print the effective configuration (never the secret) and exit")
		printVersion   = flag.Bool("version", false, "print the build version and exit")
		acmeOnly       = flag.Bool("acme-only", false, "serve only the ACME HTTP-01 responder (used while the certificate is being obtained)")
		policyCheck    = flag.Bool("policy-check", false, "validate the destination policy files and exit")
		policyApply    = flag.Bool("policy-apply", false, "validate the destination policy, render the Squid include and reload Squid, then exit")
		policyNoReload = flag.Bool("no-reload", false, "with -policy-apply: write the validated policy without reloading Squid")
	)
	flag.Parse()

	if *printVersion {
		fmt.Println(buildinfo.String("dohcord-relayd"))
		return
	}

	logger := log.New(os.Stderr, "dohcord-relay: ", log.LstdFlags)

	cfg, err := config.Load(*configPath)
	if err != nil {
		logger.Printf("ERROR invalid configuration in %s: %v", *configPath, err)
		os.Exit(1)
	}

	switch {
	case *policyCheck:
		p, err := policy.LoadPolicy(cfg.AllowedDomainsFile, cfg.DestinationPolicyFile)
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
		config.Print(os.Stdout, cfg)
		return
	case *acmeOnly:
		// Bootstrapping: answer HTTP-01 challenges only, because no HTTPS
		// certificate exists yet.
		cfg.HTTPSListen = ""
	}

	srv := api.New(cfg, logger)
	if err := srv.Run(); err != nil {
		logger.Printf("ERROR server stopped: %v", err)
		os.Exit(1)
	}
}

// printPolicySummary prints the effective policy in the destination-policy.conf
// format, which is what an operator wants to see after validation.
func printPolicySummary(w *os.File, p *policy.Policy) {
	fmt.Fprintf(w, "destination policy is valid: %d domains\n", len(p.Destinations))
	for _, d := range p.Destinations {
		fmt.Fprintf(w, "  %-28s %s\n", d.Domain, d.PortList())
	}
}
