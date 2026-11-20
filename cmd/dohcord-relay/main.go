// Command dohcord-relay is the management console for a Dohcord relay server,
// and the command users are expected to run.
//
// The console itself is the Bash application installed as
// /usr/local/lib/dohcord-relay/manager.sh: it drives the systemd units, the
// daemon's -policy-check/-policy-apply commands, certbot and the verification
// suite. This binary only locates and runs it, so the command name stays stable
// even though the console is a script. Inside a checkout, running
// `go run ./cmd/dohcord-relay` finds the same script under deploy/scripts/.
package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/Newipe/Dohcord-relay/internal/buildinfo"
)

const (
	// systemManager is where the installer puts the console.
	systemManager = "/usr/local/lib/dohcord-relay/manager.sh"
	// managerEnv overrides the console path (used by tests and by checkouts).
	managerEnv = "DOHCORD_RELAY_MANAGER"
	// bash runs the console; it is the same interpreter the installer uses.
	bash = "/bin/bash"
	// devManager is the console's path inside a source checkout.
	devManager = "deploy/scripts/dohcord-relay-manager.sh"
)

func main() {
	// The console owns "version"; this flag reports the binary's own build
	// provenance without starting the script.
	if len(os.Args) == 2 && (os.Args[1] == "--build-info" || os.Args[1] == "-build-info") {
		fmt.Println(buildinfo.String("dohcord-relay"))
		return
	}

	script, err := managerScript()
	if err != nil {
		fmt.Fprintf(os.Stderr, "dohcord-relay: %v\n", err)
		fmt.Fprintln(os.Stderr, "dohcord-relay: reinstall with the one-line installer from the README")
		fmt.Fprintln(os.Stderr, "dohcord-relay: development builds are documented in docs/development.md")
		os.Exit(1)
	}

	args := append([]string{script}, os.Args[1:]...)
	cmd := exec.Command(bash, args...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			os.Exit(exitErr.ExitCode())
		}
		fmt.Fprintf(os.Stderr, "dohcord-relay: run %s: %v\n", script, err)
		os.Exit(1)
	}
}

// managerScript resolves the console, preferring an explicit override, then the
// installed path, then a checkout containing the binary or the working directory.
func managerScript() (string, error) {
	if p := os.Getenv(managerEnv); p != "" {
		if isFile(p) {
			return p, nil
		}
		return "", fmt.Errorf("%s points to %s, which is not a readable file", managerEnv, p)
	}
	if isFile(systemManager) {
		return systemManager, nil
	}

	var starts []string
	if wd, err := os.Getwd(); err == nil {
		starts = append(starts, wd)
	}
	if exe, err := os.Executable(); err == nil {
		if resolved, err := filepath.EvalSymlinks(exe); err == nil {
			exe = resolved
		}
		starts = append(starts, filepath.Dir(exe))
	}
	for _, start := range starts {
		for dir, depth := start, 0; depth < 6; dir, depth = filepath.Dir(dir), depth+1 {
			candidate := filepath.Join(dir, devManager)
			if isFile(candidate) {
				return candidate, nil
			}
			if parent := filepath.Dir(dir); parent == dir {
				break
			}
		}
	}
	return "", errors.New("management console not found at " + systemManager)
}

func isFile(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && fi.Mode().IsRegular()
}
