package main

import (
	"bytes"
	"fmt"
	"io"
	"sync"
	"time"
)

// noiseFilter thins out a log line a dependency prints for every packet it refuses to proxy
// (connect-ip: "dropping proxied packet … Hop Limit too small: 1" — link-local and multicast
// chatter that a Mac emits all the time). Seen at about one per second on a real network, they would
// push every useful line out of the 1000-line ring the app reads. The first such line goes through,
// then at most one per interval, followed by a count of the ones left out.
type noiseFilter struct {
	w        io.Writer
	interval time.Duration
	now      func() time.Time

	mu         sync.Mutex
	last       time.Time
	suppressed int
}

var noisyDrop = []byte("dropping proxied packet")

func newNoiseFilter(w io.Writer) *noiseFilter {
	return &noiseFilter{w: w, interval: 30 * time.Second, now: time.Now}
}

func (f *noiseFilter) Write(p []byte) (int, error) {
	if !bytes.Contains(p, noisyDrop) {
		return f.w.Write(p)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	now := f.now()
	if !f.last.IsZero() && now.Sub(f.last) < f.interval {
		f.suppressed++
		return len(p), nil
	}
	f.last = now
	if f.suppressed > 0 {
		_, _ = fmt.Fprintf(f.w, "zarpd: %d more packets that can't be proxied were dropped in the meantime (not logged individually)\n", f.suppressed)
		f.suppressed = 0
	}
	return f.w.Write(p)
}
