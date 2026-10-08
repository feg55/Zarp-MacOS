package daemon

import (
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestLogRingBasics(t *testing.T) {
	r := NewLogRing(10)
	r.now = func() time.Time { return time.UnixMilli(1_700_000_000_123) }
	fmt.Fprintf(r, "first\nsecond\n")
	r.Printf("third %d", 3)
	lines, next, dropped := r.Since(0)
	if len(lines) != 3 || next != 3 || dropped != 0 {
		t.Fatalf("%+v next=%d dropped=%d", lines, next, dropped)
	}
	if lines[0].Text != "first" || lines[2].Text != "third 3" || lines[0].Seq != 1 || lines[0].TimeMs != 1_700_000_000_123 {
		t.Fatalf("%+v", lines)
	}
	if more, next2, _ := r.Since(next); len(more) != 0 || next2 != next {
		t.Fatalf("nothing new expected: %+v", more)
	}
	if rest, _, _ := r.Since(2); len(rest) != 1 || rest[0].Text != "third 3" {
		t.Fatalf("%+v", rest)
	}
}

func TestLogRingJoinsPartialWritesAndSkipsBlankLines(t *testing.T) {
	r := NewLogRing(10)
	fmt.Fprint(r, "hel")
	if lines, _, _ := r.Since(0); len(lines) != 0 {
		t.Fatalf("an unfinished line must wait for its newline: %+v", lines)
	}
	fmt.Fprint(r, "lo\r\n\n\nworld\n")
	lines, _, _ := r.Since(0)
	if len(lines) != 2 || lines[0].Text != "hello" || lines[1].Text != "world" {
		t.Fatalf("%+v", lines)
	}
}

func TestLogRingPrintfSplitsEmbeddedNewlines(t *testing.T) {
	r := NewLogRing(10)
	r.Printf("panic: boom\ngoroutine 1:\n\tmain.go:1\n")
	if lines, _, _ := r.Since(0); len(lines) != 3 {
		t.Fatalf("%+v", lines)
	}
}

func TestLogRingDropsOldestAndSaysSo(t *testing.T) {
	r := NewLogRing(5)
	for i := 1; i <= 12; i++ {
		r.Printf("line %d", i)
	}
	lines, next, dropped := r.Since(0)
	if len(lines) != 5 || lines[0].Text != "line 8" || next != 12 {
		t.Fatalf("%+v next=%d", lines, next)
	}
	if dropped != 7 {
		t.Fatalf("dropped = %d, want 7", dropped)
	}
	// A reader that was keeping up loses nothing.
	if _, _, dropped := r.Since(10); dropped != 0 {
		t.Fatalf("dropped = %d for an up-to-date reader", dropped)
	}
	// One that fell behind by exactly the ring is told what it missed.
	if lines, _, dropped := r.Since(4); dropped != 3 || len(lines) != 5 {
		t.Fatalf("lines=%d dropped=%d", len(lines), dropped)
	}
}

func TestLogRingIsSafeForConcurrentUse(t *testing.T) {
	r := NewLogRing(50)
	var wg sync.WaitGroup
	for g := 0; g < 8; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 200; i++ {
				r.Printf("g%d line %d", g, i)
				r.Since(0)
			}
		}()
	}
	wg.Wait()
	lines, next, _ := r.Since(0)
	if next != 1600 || len(lines) != 50 {
		t.Fatalf("next=%d len=%d", next, len(lines))
	}
	for i := 1; i < len(lines); i++ {
		if lines[i].Seq != lines[i-1].Seq+1 {
			t.Fatalf("sequence numbers must be contiguous: %v", lines)
		}
	}
	_ = strings.Contains
}
