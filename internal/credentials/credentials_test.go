package credentials

import (
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"strconv"
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

// TestIssueMatchesCryptographicReference recomputes the credential with the
// standard library directly, so the pooled HMAC state can never change what a
// client (or coturn) sees.
func TestIssueMatchesCryptographicReference(t *testing.T) {
	secret := []byte("0123456789abcdef0123456789abcdef")
	now := time.Unix(1794591360, 0)

	for _, identity := range []string{"Pishcord", "pishcord-relay", strings.Repeat("a", 64)} {
		username, password, expiresAt := Issue(secret, identity, time.Hour, now)

		wantName := strconv.FormatInt(expiresAt, 10) + ":" + identity
		if username != wantName {
			t.Fatalf("username = %q, want %q", username, wantName)
		}
		mac := hmac.New(sha1.New, secret)
		mac.Write([]byte(wantName))
		if want := base64.StdEncoding.EncodeToString(mac.Sum(nil)); password != want {
			t.Fatalf("password = %q, want %q", password, want)
		}
	}
}

// TestIssueSwitchesKeysWhenTheSecretChanges covers secret rotation: a pooled
// state built for the old secret must not be reused.
func TestIssueSwitchesKeysWhenTheSecretChanges(t *testing.T) {
	now := time.Unix(1794591360, 0)
	_, first, _ := Issue([]byte("0123456789abcdef0123456789abcdef"), "Pishcord", time.Hour, now)
	_, second, _ := Issue([]byte("fedcba9876543210fedcba9876543210"), "Pishcord", time.Hour, now)
	if first == second {
		t.Fatal("the credential did not change after the shared secret changed")
	}
}

func BenchmarkIssue(b *testing.B) {
	secret := []byte("0123456789abcdef0123456789abcdef")
	now := time.Unix(1794591360, 0)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, _, expiresAt := Issue(secret, "Pishcord", time.Hour, now); expiresAt == 0 {
			b.Fatal("no expiry")
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
