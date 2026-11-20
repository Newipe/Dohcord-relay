package main

import (
	"os"
	"path/filepath"
	"testing"
)

// TestManagerScriptOverride checks the explicit override wins and that a bad
// override fails instead of silently falling back to another script.
func TestManagerScriptOverride(t *testing.T) {
	dir := t.TempDir()
	script := filepath.Join(dir, "manager.sh")
	if err := os.WriteFile(script, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatalf("write manager: %v", err)
	}

	t.Setenv(managerEnv, script)
	got, err := managerScript()
	if err != nil {
		t.Fatalf("managerScript: %v", err)
	}
	if got != script {
		t.Errorf("managerScript = %q, want %q", got, script)
	}

	t.Setenv(managerEnv, filepath.Join(dir, "missing.sh"))
	if _, err := managerScript(); err == nil {
		t.Error("managerScript accepted a missing override")
	}
}

// TestManagerScriptFromCheckout checks the development fallback: a checkout with
// deploy/scripts/dohcord-relay-manager.sh resolves from the working directory.
func TestManagerScriptFromCheckout(t *testing.T) {
	dir := t.TempDir()
	script := filepath.Join(dir, "deploy", "scripts", "dohcord-relay-manager.sh")
	if err := os.MkdirAll(filepath.Dir(script), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(script, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatalf("write manager: %v", err)
	}

	t.Setenv(managerEnv, "")
	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	if err := os.Chdir(filepath.Join(dir, "deploy")); err != nil {
		t.Fatalf("chdir: %v", err)
	}
	t.Cleanup(func() { _ = os.Chdir(wd) })

	got, err := managerScript()
	if err != nil {
		t.Fatalf("managerScript: %v", err)
	}
	if resolved, _ := filepath.EvalSymlinks(got); resolved != script {
		t.Errorf("managerScript = %q, want %q", resolved, script)
	}
}
