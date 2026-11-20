package app

import (
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/Newipe/Dohcord-relay/internal/config"
	"github.com/Newipe/Dohcord-relay/internal/policy"
)

// applyPolicy validates the two operator files, renders the Squid ACL include,
// checks the complete Squid configuration with `squid -k parse`, installs the
// include and the policy state, and only after all of that reloads Squid. A
// failure at any step leaves the previous, working policy in place.
func applyPolicy(cfg config.Config, reload bool, logger *log.Logger) error {
	p, err := policy.LoadPolicy(cfg.AllowedDomainsFile, cfg.DestinationPolicyFile)
	if err != nil {
		return fmt.Errorf("policy invalid: %w", err)
	}
	printPolicySummary(os.Stdout, p)

	include := p.SquidACL()
	allowDir := filepath.Dir(cfg.SquidAllowFile)
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

	confData, err := os.ReadFile(cfg.SquidConf)
	if err != nil {
		return fmt.Errorf("read Squid configuration %s: %w", cfg.SquidConf, err)
	}
	wantInclude := policy.SquidIncludeLine(cfg.SquidAllowFile)
	if !strings.Contains(string(confData), wantInclude) {
		return fmt.Errorf("%s does not contain %q; refusing to apply a policy Squid would not read", cfg.SquidConf, wantInclude)
	}
	stagedConf := strings.ReplaceAll(string(confData), wantInclude, policy.SquidIncludeLine(stagedName))

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
	out, err := exec.Command(cfg.SquidBinary, "-k", "parse", "-f", stagedConfName).CombinedOutput()
	if err != nil || strings.Contains(string(out), "FATAL:") {
		return fmt.Errorf("Squid rejected the generated policy; the running configuration is unchanged:\n%s", strings.TrimSpace(string(out)))
	}

	if err := os.Rename(stagedName, cfg.SquidAllowFile); err != nil {
		return fmt.Errorf("install %s: %w", cfg.SquidAllowFile, err)
	}
	if err := policy.SavePolicyState(cfg.PolicyStateFile, p); err != nil {
		return fmt.Errorf("write %s: %w", cfg.PolicyStateFile, err)
	}
	logger.Printf("policy applied: %d domains, include %s, state %s", len(p.Destinations), cfg.SquidAllowFile, cfg.PolicyStateFile)

	if !reload {
		logger.Printf("policy staged but Squid not reloaded (-no-reload)")
		return nil
	}
	out, err = exec.Command(cfg.SquidBinary, "-k", "reconfigure", "-f", cfg.SquidConf).CombinedOutput()
	if err != nil {
		return fmt.Errorf("Squid failed to reload (it keeps serving the previous policy): %s\n%s", err, strings.TrimSpace(string(out)))
	}
	logger.Printf("Squid reloaded")
	return nil
}
