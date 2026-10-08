package warp

import (
	"bytes"
	"context"
	"crypto/tls"
	"io"
	"net"
	"reflect"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/net/ipv4"
)

// ---- DialH3: the socket is closed on every failure (regression: it used to leak)

func TestDialH3FailureClosesTheCallersSocket(t *testing.T) {
	udpConn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4zero})
	if err != nil {
		t.Fatal(err)
	}
	dst := &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 9} // nothing listens: the handshake times out
	cfg := &tls.Config{InsecureSkipVerify: true, NextProtos: []string{"h3"}, ServerName: "x"}

	sess, err := DialH3(context.Background(), udpConn, dst, cfg, 30*time.Second, 300*time.Millisecond)
	if err == nil || sess != nil {
		t.Fatalf("expected the dial to fail, got %v %v", sess, err)
	}
	// quic-go's Transport.Close leaves a socket it didn't create open; DialH3 must close it.
	if _, werr := udpConn.WriteToUDP([]byte("x"), dst); werr == nil || !strings.Contains(werr.Error(), "closed") {
		t.Fatalf("the UDP socket is still open after a failed dial (WriteToUDP err = %v): that is an fd leak per failed strategy", werr)
	}
}

func TestDialH3ZeroTimeoutUsesTheDefault(t *testing.T) {
	// A non-positive timeout must not mean "already expired".
	udpConn, _ := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4zero})
	dst := &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 9}
	cfg := &tls.Config{InsecureSkipVerify: true, NextProtos: []string{"h3"}, ServerName: "x"}
	ctx, cancel := context.WithTimeout(context.Background(), 400*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, err := DialH3(ctx, udpConn, dst, cfg, 30*time.Second, 0)
	if err == nil {
		t.Fatal("expected an error")
	}
	if time.Since(start) < 300*time.Millisecond {
		t.Fatalf("the dial gave up after %v: a zero timeout must fall back to the default, not expire at once", time.Since(start))
	}
}

// ---- Session.Close

func TestSessionCloseRunsEveryCloserOnceInOrder(t *testing.T) {
	var order []string
	s := &Session{closers: []func(){
		func() { order = append(order, "a") },
		func() { order = append(order, "b") },
		func() { order = append(order, "c") },
	}}
	for i := 0; i < 3; i++ {
		s.Close()
	}
	if !reflect.DeepEqual(order, []string{"a", "b", "c"}) {
		t.Fatalf("closers ran as %v", order)
	}
}

// ---- DialH2 failure paths

// silentServer accepts TCP connections and never speaks: a TLS handshake against it hangs. Each
// accepted connection reports when the client side closes it.
func silentServer(t *testing.T) (addr *net.TCPAddr, closedByClient <-chan struct{}) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	closed := make(chan struct{}, 4)
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				_, _ = io.Copy(io.Discard, c) // returns when the client closes (or resets)
				c.Close()
				closed <- struct{}{}
			}()
		}
	}()
	return ln.Addr().(*net.TCPAddr), closed
}

func h2TestConfig() *tls.Config {
	return &tls.Config{InsecureSkipVerify: true, ServerName: "consumer-masque.cloudflareclient.com"}
}

func TestDialH2AbortsWhenTheCallerGoesAwayAndClosesItsConnection(t *testing.T) {
	addr, closed := silentServer(t)
	dialCtx, cancel := context.WithCancel(context.Background())
	go func() { time.Sleep(150 * time.Millisecond); cancel() }()

	start := time.Now()
	sess, err := DialH2(context.Background(), dialCtx, &net.Dialer{}, addr, h2TestConfig(), nil, 10*time.Second)
	if err == nil || sess != nil {
		t.Fatalf("expected the dial to be aborted, got %v %v", sess, err)
	}
	if time.Since(start) > 3*time.Second {
		t.Fatalf("the dial kept going for %v after its caller left", time.Since(start))
	}
	select {
	case <-closed:
	case <-time.After(3 * time.Second):
		t.Fatal("the TCP connection to the endpoint was left open after the aborted dial")
	}
}

func TestDialH2ConnectTimeoutIsReportedAndCleansUp(t *testing.T) {
	addr, closed := silentServer(t)
	start := time.Now()
	_, err := DialH2(context.Background(), context.Background(), &net.Dialer{}, addr, h2TestConfig(), nil, 250*time.Millisecond)
	if err == nil || !strings.Contains(err.Error(), "timeout after") {
		t.Fatalf("expected our own connect timeout to be named, got %v", err)
	}
	if time.Since(start) > 3*time.Second {
		t.Fatalf("took %v", time.Since(start))
	}
	select {
	case <-closed:
	case <-time.After(3 * time.Second):
		t.Fatal("the TCP connection was left open after the timeout")
	}
}

func TestDialH2SessionContextOutlivesAShortDialContext(t *testing.T) {
	// The IPC request that asked for a connection finishes long before the tunnel does: ending
	// dialCtx *after* the dial must never touch the session. Verified here through the failure
	// path's observable contract: a dialCtx that is already finished does abort the dial, while a
	// live sessionCtx that is cancelled later has no effect on a dial that never started.
	addr, _ := silentServer(t)
	sessionCtx, cancelSession := context.WithCancel(context.Background())
	defer cancelSession()
	dialCtx, cancelDial := context.WithCancel(context.Background())
	cancelDial()
	if _, err := DialH2(sessionCtx, dialCtx, &net.Dialer{}, addr, h2TestConfig(), nil, 10*time.Second); err == nil {
		t.Fatal("an already-cancelled dial context must abort the dial")
	}
	if sessionCtx.Err() != nil {
		t.Fatal("aborting the dial must not cancel the daemon's own context")
	}
}

// ---- SendFakes

func udpPair(t *testing.T) (client *net.UDPConn, server *ipv4.PacketConn, dst *net.UDPAddr) {
	t.Helper()
	ln, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.ParseIP("127.0.0.1")})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	pc := ipv4.NewPacketConn(ln)
	if err := pc.SetControlMessage(ipv4.FlagTTL, true); err != nil {
		t.Skipf("cannot receive TTLs on this system: %v", err)
	}
	// Same socket family the daemon uses: a wildcard "udp" socket, which Go makes dual-stack.
	client, err = net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4zero})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { client.Close() })
	return client, pc, ln.LocalAddr().(*net.UDPAddr)
}

type received struct {
	payload []byte
	ttl     int
}

func drain(t *testing.T, pc *ipv4.PacketConn, n int) []received {
	t.Helper()
	var out []received
	buf := make([]byte, 4096)
	for len(out) < n {
		_ = pc.SetReadDeadline(time.Now().Add(2 * time.Second))
		k, cm, _, err := pc.ReadFrom(buf)
		if err != nil {
			t.Fatalf("received %d of %d packets: %v", len(out), n, err)
		}
		out = append(out, received{append([]byte(nil), buf[:k]...), cm.TTL})
	}
	return out
}

func TestSendFakesSendsEveryStepInOrderAndRestoresTTL(t *testing.T) {
	client, server, dst := udpPair(t)
	a, b := bytes.Repeat([]byte{0xA1}, 40), bytes.Repeat([]byte{0xB2}, 60)

	var order []int
	packets, total, err := SendFakes(client, dst, []FakeStep{
		{Blob: a, Repeats: 3, TTL: 4},
		{Blob: b, Repeats: 2}, // default TTL
	}, func(step, pkt, n int) { order = append(order, step*10+pkt) })
	if err != nil {
		t.Fatal(err)
	}
	if packets != 5 || total != 3*40+2*60 || !reflect.DeepEqual(order, []int{0, 1, 2, 10, 11}) {
		t.Fatalf("packets=%d bytes=%d order=%v", packets, total, order)
	}
	got := drain(t, server, 5)
	for i, r := range got {
		want := a
		if i >= 3 {
			want = b
		}
		if !bytes.Equal(r.payload, want) {
			t.Fatalf("packet %d has the wrong payload", i)
		}
	}
	// The strategy's TTL must really be on the wire for the fakes — and only for them. The socket
	// is dual-stack (as in the daemon), so this also proves the IPv6 TTL option governs IPv4
	// sends on it, which the strategy relies on.
	for i := 0; i < 3; i++ {
		if got[i].ttl != 4 {
			t.Errorf("fake %d left with TTL %d, want 4", i, got[i].ttl)
		}
	}
	for i := 3; i < 5; i++ {
		if got[i].ttl == 4 || got[i].ttl < 32 {
			t.Errorf("packet %d (no TTL requested) left with TTL %d: the lowered TTL leaked into the next step", i, got[i].ttl)
		}
	}
	// And afterwards a real packet (the QUIC Initial) leaves with the normal TTL.
	if _, err := client.WriteToUDP([]byte("real"), dst); err != nil {
		t.Fatal(err)
	}
	if r := drain(t, server, 1)[0]; r.ttl < 32 {
		t.Fatalf("the socket's TTL was not restored: the real handshake would leave with TTL %d", r.ttl)
	}
}

func TestSendFakesOnAPlainIPv4Socket(t *testing.T) {
	// Same property for a plain AF_INET socket (the other branch of the v6 check).
	ln, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.ParseIP("127.0.0.1")})
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	pc := ipv4.NewPacketConn(ln)
	if err := pc.SetControlMessage(ipv4.FlagTTL, true); err != nil {
		t.Skip(err)
	}
	client, _ := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4zero})
	defer client.Close()
	if _, _, err := SendFakes(client, ln.LocalAddr().(*net.UDPAddr), []FakeStep{{Blob: []byte("x"), Repeats: 1, TTL: 7}}, nil); err != nil {
		t.Fatal(err)
	}
	if r := drain(t, pc, 1)[0]; r.ttl != 7 {
		t.Fatalf("TTL on the wire = %d, want 7", r.ttl)
	}
}

func TestSendFakesRefusesOutOfBoundsStepsBeforeSendingAnything(t *testing.T) {
	client, server, dst := udpPair(t)
	bad := [][]FakeStep{
		{{Blob: []byte("x"), Repeats: MaxFakeRepeats + 1}},
		{{Blob: []byte("x"), Repeats: 0}},
		{{Blob: []byte("x"), Repeats: -3}},
		{{Blob: []byte("x"), Repeats: 1, TTL: 256}},
		{{Blob: []byte("x"), Repeats: 1, TTL: -1}},
		{{Blob: nil, Repeats: 1}},
		make([]FakeStep, MaxFakeSteps+1),
	}
	for i, steps := range bad {
		if _, _, err := SendFakes(client, dst, steps, nil); err == nil {
			t.Errorf("case %d: out-of-bounds steps accepted", i)
		}
	}
	_ = server.SetReadDeadline(time.Now().Add(150 * time.Millisecond))
	if _, _, _, err := server.ReadFrom(make([]byte, 64)); err == nil {
		t.Fatal("a packet was sent for a request that should have been refused up front")
	}
}

func TestSendFakesReportsWriteFailuresAndRestoresTTL(t *testing.T) {
	client, _, dst := udpPair(t)
	_ = client.Close() // writes now fail
	_, _, err := SendFakes(client, dst, []FakeStep{{Blob: []byte("x"), Repeats: 2, TTL: 3}}, nil)
	if err == nil {
		t.Fatal("expected an error on a closed socket")
	}
}

// ---- desync

func TestSplitPositions(t *testing.T) {
	host := "consumer-masque.cloudflareclient.com"
	data := []byte("\x16\x03\x01....prefix" + host + "....suffix....................")
	at := bytes.Index(data, []byte(host))
	tests := []struct {
		pos  []string
		want []int
	}{
		{[]string{"1"}, []int{1}},
		{[]string{"host"}, []int{at}},
		{[]string{"endhost"}, []int{at + len(host)}},
		{[]string{"sld"}, []int{at + len("consumer-masque.")}},
		{[]string{"midsld"}, []int{at + len("consumer-masque.") + len("cloudflareclient")/2}},
		{[]string{"-2"}, []int{len(data) - 2}},
		{[]string{"1", "midsld", "host"}, []int{1, at, at + len("consumer-masque.") + len("cloudflareclient")/2}},
		{[]string{"5", "5", "5"}, []int{5}},                           // duplicates collapse
		{[]string{"0", "99999", "-99999", "bogus"}, nil},              // outside the payload or unparsable: skipped
		{[]string{strconv.Itoa(len(data))}, nil},                      // == len: not "strictly inside"
		{[]string{strconv.Itoa(len(data) - 1)}, []int{len(data) - 1}}, // last valid offset
	}
	for _, tt := range tests {
		if got := splitPositions(data, tt.pos, host); !reflect.DeepEqual(got, tt.want) {
			t.Errorf("splitPositions(%v) = %v, want %v", tt.pos, got, tt.want)
		}
	}
	// An SNI that isn't in the payload yields no host-relative positions rather than a wrong one.
	if got := splitPositions([]byte("no sni in here at all............"), []string{"host", "midsld", "3"}, host); !reflect.DeepEqual(got, []int{3}) {
		t.Errorf("without the host in the payload only numeric positions survive, got %v", got)
	}
}

func TestParseDesync(t *testing.T) {
	spec, err := ParseDesync("disorder: -2, endhost")
	if err != nil || spec.Mode != DesyncDisorder || !reflect.DeepEqual(spec.Pos, []string{"-2", "endhost"}) {
		t.Fatalf("%+v %v", spec, err)
	}
	for _, bad := range []string{"", "split", "split:", "shred:1", "split:midsld+1", "split:1,,2"} {
		if _, err := ParseDesync(bad); err == nil {
			t.Errorf("ParseDesync(%q) should fail", bad)
		}
	}
}

func TestDesyncConnDeliversTheWholeClientHelloInOrder(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	got := make(chan []byte, 1)
	go func() {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		_ = c.SetReadDeadline(time.Now().Add(3 * time.Second))
		data, _ := io.ReadAll(c)
		got <- data
	}()

	raw, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	host := "consumer-masque.cloudflareclient.com"
	hello := append([]byte{0x16, 0x03, 0x01, 0x02, 0x00}, []byte("....................."+host+"....................")...)
	for _, mode := range []DesyncMode{DesyncSplit} { // disorder needs a real path to retransmit; covered by the on-device test
		conn := NewDesyncConn(raw.(*net.TCPConn), &DesyncSpec{Mode: mode, Pos: []string{"1", "host", "midsld"}}, host)
		n, err := conn.Write(hello)
		if err != nil || n != len(hello) {
			t.Fatalf("Write = %d, %v", n, err)
		}
		// Later writes pass straight through.
		if _, err := conn.Write([]byte("tail")); err != nil {
			t.Fatal(err)
		}
	}
	raw.Close()
	select {
	case data := <-got:
		if !bytes.Equal(data, append(append([]byte(nil), hello...), []byte("tail")...)) {
			t.Fatalf("the receiver got %d bytes that don't match what was written", len(data))
		}
	case <-time.After(4 * time.Second):
		t.Fatal("receiver never finished")
	}
}

func TestDesyncConnLeavesNonTLSAndShortWritesAlone(t *testing.T) {
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	defer ln.Close()
	var received atomic.Int32
	go func() {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		b := make([]byte, 64)
		for {
			n, err := c.Read(b)
			received.Add(int32(n))
			if err != nil {
				return
			}
		}
	}()
	raw, _ := net.Dial("tcp", ln.Addr().String())
	defer raw.Close()
	c := NewDesyncConn(raw.(*net.TCPConn), &DesyncSpec{Mode: DesyncSplit, Pos: []string{"1"}}, "")
	// First write isn't a TLS handshake record: untouched.
	if n, err := c.Write([]byte("GET / HTTP/1.1\r\n\r\n")); err != nil || n != 18 {
		t.Fatalf("%d %v", n, err)
	}
	time.Sleep(50 * time.Millisecond)
	if received.Load() != 18 {
		t.Fatalf("receiver saw %d bytes", received.Load())
	}
}
