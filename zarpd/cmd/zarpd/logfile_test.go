package main

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func TestRotatingFileStaysBounded(t *testing.T) {
	path := filepath.Join(t.TempDir(), "logs", "zarpd.log") // the directory doesn't exist yet
	r, err := newRotatingFile(path, 1000)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	line := strings.Repeat("x", 99) + "\n"
	for i := 0; i < 100; i++ { // 10 000 bytes through a 1 000-byte cap
		if _, err := r.Write([]byte(line)); err != nil {
			t.Fatal(err)
		}
	}
	for _, p := range []string{path, path + ".1"} {
		fi, err := os.Stat(p)
		if err != nil {
			t.Fatalf("%s: %v", p, err)
		}
		if fi.Size() > 1000 {
			t.Fatalf("%s is %d bytes, over the 1000-byte cap", p, fi.Size())
		}
	}
	if _, err := os.Stat(path + ".2"); err == nil {
		t.Fatal("only one backup generation is kept")
	}
}

func TestRotatingFileKeepsExistingContentAndWholeLines(t *testing.T) {
	path := filepath.Join(t.TempDir(), "zarpd.log")
	os.WriteFile(path, []byte("from a previous run\n"), 0o644)
	r, err := newRotatingFile(path, 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	r.Write([]byte("new line\n"))
	r.Close()
	got, _ := os.ReadFile(path)
	if string(got) != "from a previous run\nnew line\n" {
		t.Fatalf("%q", got)
	}
	if _, err := r.Write([]byte("x")); err == nil {
		t.Fatal("writing to a closed log must fail, not panic")
	}
}

func TestRotatingFileIsSafeForConcurrentWriters(t *testing.T) {
	path := filepath.Join(t.TempDir(), "zarpd.log")
	r, _ := newRotatingFile(path, 5000)
	defer r.Close()
	var wg sync.WaitGroup
	for g := 0; g < 8; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 200; i++ {
				r.Write([]byte("a line of log text\n"))
			}
		}()
	}
	wg.Wait()
	for _, p := range []string{path, path + ".1"} {
		data, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		for _, l := range strings.Split(strings.TrimRight(string(data), "\n"), "\n") {
			if l != "a line of log text" {
				t.Fatalf("interleaved or torn line in %s: %q", p, l)
			}
		}
	}
}
