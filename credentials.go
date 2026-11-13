package main

import (
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// restSeparator is the timestamp/identity separator used by coturn's TURN REST
// authentication (turnserver.conf: rest-api-separator, default ':').
const restSeparator = ":"

// validateIdentity rejects identities that would break the "<timestamp>:<identity>"
// username format or the TURN username grammar.
func validateIdentity(identity string) error {
	switch {
	case identity == "":
		return fmt.Errorf("turn identity must not be empty")
	case len(identity) > 64:
		return fmt.Errorf("turn identity must be at most 64 characters")
	case strings.ContainsRune(identity, ':'):
		return fmt.Errorf("turn identity must not contain %q", restSeparator)
	case strings.ContainsAny(identity, " \t\r\n"):
		return fmt.Errorf("turn identity must not contain whitespace")
	}
	return nil
}

// issueCredential computes the time-limited TURN credential described by coturn:
//
//	temporary-username = "<unix-expiration-timestamp>" + ":" + identity
//	temporary-password = base64(hmac-sha1(key = shared secret, input = temporary-username))
//
// The password is the standard base64 encoding of the raw HMAC-SHA1 digest, with
// padding, which is what coturn itself computes for --use-auth-secret.
func issueCredential(secret []byte, identity string, ttl time.Duration, now time.Time) (username, password string, expiresAt int64) {
	expiresAt = now.Add(ttl).Unix()
	username = strconv.FormatInt(expiresAt, 10) + restSeparator + identity

	mac := hmac.New(sha1.New, secret)
	mac.Write([]byte(username))
	password = base64.StdEncoding.EncodeToString(mac.Sum(nil))
	return username, password, expiresAt
}

// parseTURNUsername splits a REST username back into its expiration timestamp and
// identity. It is used by the self-tests so a generated username can be checked
// against the format coturn expects.
func parseTURNUsername(username string) (expiresAt int64, identity string, err error) {
	ts, id, ok := strings.Cut(username, restSeparator)
	if !ok {
		return 0, "", fmt.Errorf("username %q has no %q separator", username, restSeparator)
	}
	expiresAt, err = strconv.ParseInt(ts, 10, 64)
	if err != nil {
		return 0, "", fmt.Errorf("username %q has an invalid expiration timestamp: %w", username, err)
	}
	return expiresAt, id, nil
}
