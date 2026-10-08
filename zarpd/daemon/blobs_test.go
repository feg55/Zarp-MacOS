package daemon

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/feg55/zarp-macos/zarpd/ipc"
)

// The blob names are spelled in three places that must agree: Swift's Blob enum (the wire names),
// ipc.BlobNames (what a request may ask for) and blobFiles (what the daemon maps to files). A
// mismatch would only show up as a strategy failing at connect time on someone's machine.
func TestBlobNamesAgreeAndTheFilesExist(t *testing.T) {
	dir := filepath.Join("..", "..", "Resources", "blobs")
	o := &RealOpener{BlobsDir: dir}
	for name := range ipc.BlobNames {
		blob, err := o.loadBlob(name)
		if err != nil {
			t.Errorf("blob %q is accepted by the protocol but cannot be loaded: %v", name, err)
			continue
		}
		if len(blob) == 0 {
			t.Errorf("blob %q is empty", name)
		}
		if name == "zero64" && len(blob) != 64 {
			t.Errorf("zero64 has %d bytes", len(blob))
		}
	}
	for name := range blobFiles {
		if !ipc.BlobNames[name] {
			t.Errorf("blobFiles maps %q, which the protocol would refuse", name)
		}
	}
	if _, err := o.loadBlob("../../../etc/passwd"); err == nil {
		t.Error("a path must never be accepted as a blob name")
	}
	entries, _ := os.ReadDir(dir)
	files := 0
	for _, e := range entries {
		if filepath.Ext(e.Name()) == ".bin" {
			files++
		}
	}
	if files != len(blobFiles) {
		t.Errorf("Resources/blobs holds %d .bin files but blobFiles knows %d", files, len(blobFiles))
	}
}

func TestToFakeStepsMapsTTLAndRepeats(t *testing.T) {
	o := &RealOpener{BlobsDir: filepath.Join("..", "..", "Resources", "blobs")}
	ttl := 4
	steps, err := o.toFakeSteps([]ipc.FakeStep{
		{Blob: "quic_google", Repeats: 3, IPTTL: &ttl},
		{Blob: "zero64", Repeats: 2},
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(steps) != 2 || steps[0].Repeats != 3 || steps[0].TTL != 4 || steps[1].TTL != 0 || len(steps[1].Blob) != 64 {
		t.Fatalf("%+v", steps)
	}
}
