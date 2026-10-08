package main

import (
	"io"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// rotatingFile is an append-only log file that keeps itself bounded: when a write would take it
// past maxBytes, the file is renamed to <path>.1 (replacing the previous one) and a fresh file is
// started. The daemon runs for weeks, so a log that only ever grows — what launchd's own
// StandardOutPath file does — is not acceptable.
type rotatingFile struct {
	path     string
	maxBytes int64

	mu   sync.Mutex
	f    *os.File
	size int64
}

func newRotatingFile(path string, maxBytes int64) (*rotatingFile, error) {
	r := &rotatingFile{path: path, maxBytes: maxBytes}
	if err := r.open(); err != nil {
		return nil, err
	}
	return r, nil
}

func (r *rotatingFile) open() error {
	if err := os.MkdirAll(filepath.Dir(r.path), 0o755); err != nil {
		return err
	}
	f, err := os.OpenFile(r.path, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o644)
	if err != nil {
		return err
	}
	fi, err := f.Stat()
	if err != nil {
		_ = f.Close()
		return err
	}
	r.f, r.size = f, fi.Size()
	return nil
}

func (r *rotatingFile) Write(p []byte) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.f == nil {
		return 0, os.ErrClosed
	}
	if r.size > 0 && r.size+int64(len(p)) > r.maxBytes {
		_ = r.f.Close()
		_ = os.Remove(r.path + ".1")
		_ = os.Rename(r.path, r.path+".1")
		if err := r.open(); err != nil {
			r.f = nil
			return 0, err
		}
	}
	n, err := r.f.Write(p)
	r.size += int64(n)
	return n, err
}

func (r *rotatingFile) Close() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.f == nil {
		return nil
	}
	err := r.f.Close()
	r.f = nil
	return err
}

// timestamped prefixes every Write with a local timestamp — one Write per log line, which is how
// the standard logger calls its output.
type timestamped struct{ w io.Writer }

func (t timestamped) Write(p []byte) (int, error) {
	stamp := time.Now().Format("2006/01/02 15:04:05 ")
	if _, err := t.w.Write(append([]byte(stamp), p...)); err != nil {
		return 0, err
	}
	return len(p), nil
}
