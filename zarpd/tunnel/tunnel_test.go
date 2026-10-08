package tunnel

import (
	"bytes"
	"errors"
	"os"
	"testing"

	"golang.zx2c4.com/wireguard/tun"
)

// fakeDevice records what is written into it and implements just enough of tun.Device.
type fakeDevice struct {
	written [][]byte
	offsets []int
	err     error
	short   bool
}

func (d *fakeDevice) File() *os.File                         { return nil }
func (d *fakeDevice) Read([][]byte, []int, int) (int, error) { return 0, errors.New("unused") }
func (d *fakeDevice) MTU() (int, error)                      { return 1280, nil }
func (d *fakeDevice) Name() (string, error)                  { return "utun99", nil }
func (d *fakeDevice) Events() <-chan tun.Event               { return nil }
func (d *fakeDevice) Close() error                           { return nil }
func (d *fakeDevice) BatchSize() int                         { return 1 }
func (d *fakeDevice) Write(bufs [][]byte, offset int) (int, error) {
	if d.err != nil {
		return 0, d.err
	}
	if d.short {
		return 0, nil
	}
	for _, b := range bufs {
		d.written = append(d.written, append([]byte(nil), b[offset:]...))
		d.offsets = append(d.offsets, offset)
	}
	return len(bufs), nil
}

// countingDevice discards writes without recording them, so allocations can be measured.
type countingDevice struct{ fakeDevice }

func (d *countingDevice) Write(bufs [][]byte, offset int) (int, error) { return len(bufs), nil }

func TestDeviceWriterPutsThePacketBehindTheHeadroom(t *testing.T) {
	dev := &fakeDevice{}
	w := newDeviceWriter(dev, 1280)
	pkts := [][]byte{
		bytes.Repeat([]byte{0x45}, 20),
		bytes.Repeat([]byte{0x60}, 1280),
		bytes.Repeat([]byte{0x45}, 5000), // bigger than mtu+slack: the buffer grows rather than panicking
		bytes.Repeat([]byte{0x45}, 3),    // and a small one afterwards is not corrupted by the earlier large copy
	}
	for _, p := range pkts {
		if err := w.write(p); err != nil {
			t.Fatal(err)
		}
	}
	for i, p := range pkts {
		if !bytes.Equal(dev.written[i], p) || dev.offsets[i] != headroom {
			t.Fatalf("packet %d: device saw %d bytes at offset %d", i, len(dev.written[i]), dev.offsets[i])
		}
	}
}

func TestDeviceWriterDoesNotAllocatePerPacket(t *testing.T) {
	dev := &countingDevice{}
	w := newDeviceWriter(dev, 1280)
	pkt := make([]byte, 1200)
	allocs := testing.AllocsPerRun(200, func() { _ = w.write(pkt) })
	if allocs != 0 {
		t.Fatalf("%v allocations per packet written to the utun (it used to allocate a buffer for every one)", allocs)
	}
}

func TestDeviceWriterReportsFailures(t *testing.T) {
	boom := errors.New("utun gone")
	if err := newDeviceWriter(&fakeDevice{err: boom}, 1280).write([]byte{1}); !errors.Is(err, boom) {
		t.Fatalf("got %v", err)
	}
	if err := newDeviceWriter(&fakeDevice{short: true}, 1280).write([]byte{1}); err == nil {
		t.Fatal("a short write must be an error")
	}
}
