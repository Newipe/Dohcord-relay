package main

import (
	"sync"
	"time"
)

// limiter is a token-bucket rate limiter. A limiter with an empty key set acts as
// a single global bucket; the per-address limiter keys buckets by client address.
//
// Memory is bounded: idle buckets are swept periodically and a hard cap on the
// number of tracked keys is enforced.
type limiter struct {
	mu      sync.Mutex
	buckets map[string]*bucket
	rate    float64 // tokens added per second
	burst   float64 // maximum tokens a bucket can hold
	maxKeys int
	lastGC  time.Time
}

type bucket struct {
	tokens float64
	last   time.Time
}

// idleTTL is how long a bucket may sit unused before it is dropped.
const idleTTL = 10 * time.Minute

func newLimiter(perMinute, burst int) *limiter {
	if perMinute < 1 {
		perMinute = 1
	}
	if burst < 1 {
		burst = 1
	}
	return &limiter{
		buckets: make(map[string]*bucket),
		rate:    float64(perMinute) / 60,
		burst:   float64(burst),
		maxKeys: 50000,
	}
}

// allow consumes one token for key. When the request is refused it also reports
// how long the caller should wait before retrying.
func (l *limiter) allow(key string, now time.Time) (bool, time.Duration) {
	l.mu.Lock()
	defer l.mu.Unlock()

	l.sweep(now)

	b, ok := l.buckets[key]
	if !ok {
		if len(l.buckets) >= l.maxKeys {
			// Too many distinct clients right now: refuse rather than grow
			// without bound.
			return false, time.Second
		}
		b = &bucket{tokens: l.burst, last: now}
		l.buckets[key] = b
	}

	elapsed := now.Sub(b.last).Seconds()
	if elapsed > 0 {
		b.tokens += elapsed * l.rate
		if b.tokens > l.burst {
			b.tokens = l.burst
		}
	}
	b.last = now

	if b.tokens >= 1 {
		b.tokens--
		return true, 0
	}

	wait := time.Duration((1 - b.tokens) / l.rate * float64(time.Second))
	if wait < time.Second {
		wait = time.Second
	}
	return false, wait
}

// sweep drops buckets that have been idle for a while. It runs at most once a
// minute and must be called with l.mu held.
func (l *limiter) sweep(now time.Time) {
	if !l.lastGC.IsZero() && now.Sub(l.lastGC) < time.Minute {
		return
	}
	l.lastGC = now
	for k, b := range l.buckets {
		if now.Sub(b.last) > idleTTL {
			delete(l.buckets, k)
		}
	}
}

// size reports the number of tracked keys (used by tests).
func (l *limiter) size() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.buckets)
}
