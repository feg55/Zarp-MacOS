package daemon

import (
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/feg55/zarp-macos/zarpd/ipc"
)

// LogRing keeps the daemon's most recent log lines in memory so the app can pull them over IPC
// (`logs`) and show them next to its own — a daemon-side failure ("route add failed", "DNS
// override skipped") is otherwise invisible to anyone who isn't tailing a root-owned file.
//
// It is an io.Writer, so it can sit behind the standard library logger.
type LogRing struct {
	mu      sync.Mutex
	lines   []ipc.LogLine // oldest first, at most cap
	cap     int
	nextSeq uint64
	now     func() time.Time
	partial strings.Builder // bytes of an unfinished line from the previous Write
}

// NewLogRing returns a ring holding the last capacity lines.
func NewLogRing(capacity int) *LogRing {
	if capacity <= 0 {
		capacity = 1000
	}
	return &LogRing{cap: capacity, nextSeq: 1, now: time.Now}
}

// Write implements io.Writer: it splits p into lines and records each. The standard logger writes
// one line per call, but a partial trailing line is held until its newline arrives anyway.
func (r *LogRing) Write(p []byte) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.partial.Write(p)
	buf := r.partial.String()
	for {
		i := strings.IndexByte(buf, '\n')
		if i < 0 {
			break
		}
		r.addLocked(strings.TrimRight(buf[:i], "\r"))
		buf = buf[i+1:]
	}
	r.partial.Reset()
	r.partial.WriteString(buf)
	return len(p), nil
}

// Printf records one formatted line (embedded newlines become separate lines).
func (r *LogRing) Printf(format string, args ...any) {
	for _, line := range strings.Split(strings.TrimRight(fmt.Sprintf(format, args...), "\n"), "\n") {
		r.mu.Lock()
		r.addLocked(line)
		r.mu.Unlock()
	}
}

func (r *LogRing) addLocked(text string) {
	if text == "" {
		return
	}
	r.lines = append(r.lines, ipc.LogLine{Seq: r.nextSeq, TimeMs: r.now().UnixMilli(), Text: text})
	r.nextSeq++
	if over := len(r.lines) - r.cap; over > 0 {
		// Copy rather than reslice so the backing array doesn't grow without bound.
		r.lines = append(r.lines[:0:0], r.lines[over:]...)
	}
}

// Since returns every line with Seq > since, the cursor to ask from next time, and how many lines
// between since and the oldest one still held were lost to the ring's size.
func (r *LogRing) Since(since uint64) (lines []ipc.LogLine, next uint64, dropped uint64) {
	r.mu.Lock()
	defer r.mu.Unlock()
	next = r.nextSeq - 1
	if len(r.lines) == 0 {
		return nil, next, 0
	}
	oldest := r.lines[0].Seq
	if since+1 < oldest {
		dropped = oldest - (since + 1)
	}
	for _, l := range r.lines {
		if l.Seq > since {
			lines = append(lines, l)
		}
	}
	return lines, next, dropped
}
