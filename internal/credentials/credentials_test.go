package credentials

import (
	"strings"
	"testing"
	"time"
)

func TestCredentialVector(t *testing.T) {
	now := time.Unix(1700000000-86400, 0)
	username, password, expiresAt := Issue([]byte("pishcord-test-secret"), "Pishcord", 24*time.Hour, now)

	if want := int64(1700000000); expiresAt != want {
		t.Errorf("expiresAt = %d, want %d", expiresAt, want)
	}
	if want := "1700000000:Pishcord"; username != want {
		t.Errorf("username = %q, want %q", username, want)
	}
	if want := "v/0BhJnIX/y6FPnlhFlMEtNrjS0="; password != want {
		t.Errorf("password = %q, want %q", password, want)
	}
}

func TestParseTURNUsername(t *testing.T) {
	exp, identity, err := ParseUsername("1794600000:Pishcord")
	if err != nil {
		t.Fatalf("ParseUsername: %v", err)
	}
	if exp != 1794600000 || identity != "Pishcord" {
		t.Fatalf("got (%d, %q), want (1794600000, \"Pishcord\")", exp, identity)
	}

	for _, in := range []string{"", "Pishcord", "abc:Pishcord"} {
		if _, _, err := ParseUsername(in); err == nil {
			t.Errorf("ParseUsername(%q) succeeded, want error", in)
		}
	}
}

func TestValidateIdentity(t *testing.T) {
	for _, ok := range []string{"Pishcord", "pishcord-relay"} {
		if err := ValidateIdentity(ok); err != nil {
			t.Errorf("ValidateIdentity(%q) = %v, want nil", ok, err)
		}
	}
	for _, bad := range []string{"", "Doh:cord", "Doh cord", strings.Repeat("a", 65)} {
		if err := ValidateIdentity(bad); err == nil {
			t.Errorf("ValidateIdentity(%q) = nil, want error", bad)
		}
	}
}
