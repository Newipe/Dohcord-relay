// Package ratelimit implements the bounded token bucket used to limit API
// requests globally and per client address.
package ratelimit

import (
	"sync"
	"sync/atomic"
	"time"
)

// shardCount splits the bucket table so concurrent requests from different
// addresses do not serialize on one mutex. 32 shards keep a busy relay's profile
// loads independent while staying small enough that the per-shard maps remain
// cache-friendly.
const shardCount = 32

// maxKeys bounds the total number of tracked keys, so a flood of unique
// addresses cannot grow memory or kernel state without limit.
const maxKeys = 50000

// idleTTL is how long a bucket may sit unused before it is dropped.
const idleTTL = 10 * time.Minute

// Limiter is a token-bucket rate Limiter. A Limiter with a single key acts as a
// global bucket; the per-address Limiter keys buckets by client address.
type Limiter struct {
	shards      [shardCount]shard
	perShardMax int
	rate        float64 // tokens added per second
	burst       float64 // maximum tokens a bucket can hold

	// lastSweep is the last global sweep, so expiring idle buckets costs one
	// atomic load per request instead of a second lock.
	lastSweep int64
	sweepMu   sync.Mutex
}

type shard struct {
	mu      sync.Mutex
	buckets map[string]*bucket
}

type bucket struct {
	tokens float64
	last   time.Time
}

func New(perMinute, burst int) *Limiter {
	if perMinute < 1 {
		perMinute = 1
	}
	if burst < 1 {
		burst = 1
	}
	perShard := maxKeys / shardCount
	if perShard < 1 {
		perShard = 1
	}
	l := &Limiter{
		perShardMax: perShard,
		rate:        float64(perMinute) / 60,
		burst:       float64(burst),
	}
	for i := range l.shards {
		l.shards[i].buckets = make(map[string]*bucket)
	}
	return l
}

// Allow consumes one token for key. When the request is refused it also reports
// how long the caller should wait before retrying.
func (l *Limiter) Allow(key string, now time.Time) (bool, time.Duration) {
	if now.UnixNano()-atomic.LoadInt64(&l.lastSweep) >= int64(time.Minute) {
		l.sweepIdle(now)
	}

	s := &l.shards[keyShard(key)]
	s.mu.Lock()
	defer s.mu.Unlock()

	b, ok := s.buckets[key]
	if !ok {
		if len(s.buckets) >= l.perShardMax {
			// Too many distinct clients on this shard right now: refuse
			// rather than grow without bound.
			return false, time.Second
		}
		b = &bucket{tokens: l.burst, last: now}
		s.buckets[key] = b
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

// sweepIdle drops buckets that have been idle for a while across every shard.
// It runs at most once a minute: a request that loses the try-lock simply skips
// it, so a busy relay never waits behind the sweep. Idle buckets cost a map
// entry, nothing more, which is why skipping a sweep is harmless.
func (l *Limiter) sweepIdle(now time.Time) {
	if !l.sweepMu.TryLock() {
		return
	}
	defer l.sweepMu.Unlock()
	atomic.StoreInt64(&l.lastSweep, now.UnixNano())
	for i := range l.shards {
		s := &l.shards[i]
		s.mu.Lock()
		for k, b := range s.buckets {
			if now.Sub(b.last) > idleTTL {
				delete(s.buckets, k)
			}
		}
		s.mu.Unlock()
	}
}

// size reports the number of tracked keys (used by tests).
func (l *Limiter) Size() int {
	total := 0
	for i := range l.shards {
		s := &l.shards[i]
		s.mu.Lock()
		total += len(s.buckets)
		s.mu.Unlock()
	}
	return total
}

// keyShard maps a key to a shard with FNV-1a, which is cheap and spreads
// addresses evenly.
func keyShard(key string) uint32 {
	var h uint32 = 2166136261
	for i := 0; i < len(key); i++ {
		h ^= uint32(key[i])
		h *= 16777619
	}
	return h % shardCount
}
