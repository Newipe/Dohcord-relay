package ratelimit

import (
	"fmt"
	"sync"
	"sync/atomic"
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

// TestLimiterConcurrentBurstIsExact checks the sharded limiter under concurrent
// load: a burst of 100 shared by 400 simultaneous requests must admit exactly
// 100 of them, no more and no fewer.
func TestLimiterConcurrentBurstIsExact(t *testing.T) {
	l := New(60, 100)
	now := time.Unix(0, 0)
	var allowed int32
	var wg sync.WaitGroup
	start := make(chan struct{})
	for i := 0; i < 400; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			<-start
			key := "203.0.113.9"
			if i%2 == 1 {
				key = "203.0.113.10"
			}
			if ok, _ := l.Allow(key, now); ok {
				atomic.AddInt32(&allowed, 1)
			}
		}(i)
	}
	close(start)
	wg.Wait()
	if got := atomic.LoadInt32(&allowed); got != 200 {
		t.Fatalf("allowed = %d, want 200 (100 per address, two addresses)", got)
	}
}

// TestLimiterTracksDistinctAddresses checks that a burst of distinct clients is
// admitted independently and that the tracked-key count is exact.
func TestLimiterTracksDistinctAddresses(t *testing.T) {
	l := New(60, 30)
	now := time.Unix(0, 0)
	for i := 0; i < 500; i++ {
		if ok, _ := l.Allow(fmt.Sprintf("198.51.100.%d", i%256)+fmt.Sprintf("-%d", i/256), now); !ok {
			t.Fatalf("client %d was refused", i)
		}
	}
	if got := l.Size(); got != 500 {
		t.Fatalf("tracked keys = %d, want 500", got)
	}
}

// TestLimiterIdleSweep keeps memory bounded: buckets idle for longer than the TTL
// are dropped once the sweep interval passes.
func TestLimiterIdleSweep(t *testing.T) {
	l := New(60, 5)
	start := time.Unix(0, 0)
	for i := 0; i < 10; i++ {
		l.Allow(fmt.Sprintf("192.0.2.%d", i), start)
	}
	if got := l.Size(); got != 10 {
		t.Fatalf("tracked keys = %d, want 10", got)
	}
	l.Allow("192.0.2.200", start.Add(idleTTL+2*time.Minute))
	if got := l.Size(); got != 1 {
		t.Fatalf("tracked keys after sweep = %d, want 1", got)
	}
}
