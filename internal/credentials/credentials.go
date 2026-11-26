// Package credentials issues and validates the time-limited TURN REST
// credentials described by coturn.
package credentials

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"fmt"
	"hash"
	"strconv"
	"strings"
	"sync"
	"time"
)

// restSeparator is the timestamp/identity separator used by coturn's TURN REST
// authentication (turnserver.conf: rest-api-separator, default ':').
const restSeparator = ":"

// maxIdentityLen bounds the identity part of a username. It mirrors
// ValidateIdentity, and sizes the stack buffer Issue writes into.
const maxIdentityLen = 64

// macState is a reusable HMAC-SHA1 state bound to one shared secret.
// hmac.New allocates keyed state on every call and a credential is issued on
// every profile load, so the state is pooled and reset instead of rebuilt.
type macState struct {
	mac    hash.Hash
	secret []byte
}

var macPool = sync.Pool{New: func() any { return new(macState) }}

// acquireMac returns a reset HMAC-SHA1 state keyed with secret. A pooled state
// built for another secret is replaced, because hmac cannot change its key.
func acquireMac(secret []byte) *macState {
	st := macPool.Get().(*macState)
	if st.mac == nil || !bytes.Equal(st.secret, secret) {
		st.mac = hmac.New(sha1.New, secret)
		st.secret = append(st.secret[:0], secret...)
		return st
	}
	st.mac.Reset()
	return st
}

// ValidateIdentity rejects identities that would break the "<timestamp>:<identity>"
// username format or the TURN username grammar.
func ValidateIdentity(identity string) error {
	switch {
	case identity == "":
		return fmt.Errorf("turn identity must not be empty")
	case len(identity) > maxIdentityLen:
		return fmt.Errorf("turn identity must be at most %d characters", maxIdentityLen)
	case strings.ContainsRune(identity, ':'):
		return fmt.Errorf("turn identity must not contain %q", restSeparator)
	case strings.ContainsAny(identity, " \t\r\n"):
		return fmt.Errorf("turn identity must not contain whitespace")
	}
	return nil
}

// Issue computes the time-limited TURN credential described by coturn:
//
//	temporary-username = "<unix-expiration-timestamp>" + ":" + identity
//	temporary-password = base64(hmac-sha1(key = shared secret, input = temporary-username))
//
// The password is the standard base64 encoding of the raw HMAC-SHA1 digest, with
// padding, which is what coturn itself computes for --use-auth-secret.
//
// The username and digest are built in stack buffers and the HMAC state is
// reused, so issuing a credential allocates only the two returned strings.
func Issue(secret []byte, identity string, ttl time.Duration, now time.Time) (username, password string, expiresAt int64) {
	expiresAt = now.Add(ttl).Unix()

	// 10 digits of timestamp, the separator and the identity; append grows the
	// slice on the heap only if an identity longer than ValidateIdentity allows
	// is passed in, and the result is then still correct.
	var name [11 + maxIdentityLen]byte
	b := strconv.AppendInt(name[:0], expiresAt, 10)
	b = append(b, restSeparator...)
	b = append(b, identity...)

	st := acquireMac(secret)
	_, _ = st.mac.Write(b)
	var digest [sha1.Size]byte
	sum := st.mac.Sum(digest[:0])
	macPool.Put(st)

	var encoded [28]byte // base64.StdEncoding.EncodedLen(sha1.Size)
	base64.StdEncoding.Encode(encoded[:], sum)

	return string(b), string(encoded[:]), expiresAt
}

// ParseUsername splits a REST username back into its expiration timestamp and
// identity. It is used by the self-tests so a generated username can be checked
// against the format coturn expects.
func ParseUsername(username string) (expiresAt int64, identity string, err error) {
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
