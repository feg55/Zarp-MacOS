package main

import (
	"bytes"
	"strings"
	"testing"
	"time"
)

func TestNoiseFilterThinsDroppedPacketLines(t *testing.T) {
	var out bytes.Buffer
	clock := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	f := newNoiseFilter(&out)
	f.now = func() time.Time { return clock }

	drop := []byte("dropping proxied packet (96 bytes) that can't be proxied: connect-ip: datagram Hop Limit too small: 1\n")
	for i := 0; i < 5; i++ {
		if n, err := f.Write(drop); err != nil || n != len(drop) {
			t.Fatalf("Write = %d, %v (must report the whole line as written)", n, err)
		}
		clock = clock.Add(time.Second)
	}
	if got := strings.Count(out.String(), "dropping proxied packet"); got != 1 {
		t.Fatalf("within the interval only the first line goes through, got %d:\n%s", got, out.String())
	}

	clock = clock.Add(time.Minute)
	f.Write(drop)
	s := out.String()
	if strings.Count(s, "dropping proxied packet") != 2 || !strings.Contains(s, "4 more packets") {
		t.Fatalf("after the interval the next line goes through, preceded by the count of suppressed ones:\n%s", s)
	}
}

func TestNoiseFilterNeverTouchesOtherLines(t *testing.T) {
	var out bytes.Buffer
	f := newNoiseFilter(&out)
	for i := 0; i < 100; i++ {
		f.Write([]byte("open #1 transport=masqueH3\n"))
	}
	if got := strings.Count(out.String(), "open #1"); got != 100 {
		t.Fatalf("ordinary lines must all pass, got %d", got)
	}
}
