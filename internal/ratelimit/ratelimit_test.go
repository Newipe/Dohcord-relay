package ratelimit

import (
	"testing"
	"time"
)

func TestLimiterRefills(t *testing.T) {
	l := New(60, 1) // one token per second
	now := time.Unix(0, 0)
	if ok, _ := l.Allow("a", now); !ok {
		t.Fatal("first request should be allowed")
	}
	if ok, wait := l.Allow("a", now); ok || wait <= 0 {
		t.Fatalf("second request should be refused with a wait, got (%v, %v)", ok, wait)
	}
	if ok, _ := l.Allow("a", now.Add(2*time.Second)); !ok {
		t.Fatal("request after refill should be allowed")
	}
}
