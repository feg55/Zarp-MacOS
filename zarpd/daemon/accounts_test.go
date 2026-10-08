package daemon

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestFileAccountsHasIsCachedOncePositive(t *testing.T) {
	path := filepath.Join(t.TempDir(), "cfg.json")
	a := &FileAccounts{Path: path}
	if a.Has() {
		t.Fatal("no file, no account")
	}
	if err := os.WriteFile(path, []byte(`{"private_key":"k","endpoint_pub_key":"p"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if !a.Has() {
		t.Fatal("a config with keys is an account")
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if !a.Has() {
		t.Fatal("a positive answer is cached: status/ping must not re-read the file every few seconds")
	}
}

func TestFileAccountsRejectsAHalfWrittenConfig(t *testing.T) {
	path := filepath.Join(t.TempDir(), "cfg.json")
	os.WriteFile(path, []byte(`{"private_key":"k"}`), 0o600)
	if (&FileAccounts{Path: path}).Has() {
		t.Fatal("a config without the endpoint key is not usable")
	}
	os.WriteFile(path, []byte(`{not json`), 0o600)
	if (&FileAccounts{Path: path}).Has() {
		t.Fatal("garbage is not an account")
	}
}

func TestFileAccountsRegister(t *testing.T) {
	var gotPath, gotName string
	a := &FileAccounts{Path: "/x/cfg.json", DeviceName: "Zarp macOS", RegisterFn: func(p, n string) error {
		gotPath, gotName = p, n
		return nil
	}}
	if err := a.Register(context.Background()); err != nil || gotPath != "/x/cfg.json" || gotName != "Zarp macOS" {
		t.Fatalf("%v %q %q", err, gotPath, gotName)
	}
	boom := errors.New("boom")
	a.RegisterFn = func(string, string) error { return boom }
	if err := a.Register(context.Background()); !errors.Is(err, boom) {
		t.Fatalf("%v", err)
	}
}

func TestFileAccountsRegisterHonorsCancelAndTimeout(t *testing.T) {
	release := make(chan struct{})
	defer close(release)
	a := &FileAccounts{RegisterFn: func(string, string) error { <-release; return nil }, Timeout: 150 * time.Millisecond}

	ctx, cancel := context.WithCancel(context.Background())
	go func() { time.Sleep(50 * time.Millisecond); cancel() }()
	if err := a.Register(ctx); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancel: %v", err)
	}
	start := time.Now()
	if err := a.Register(context.Background()); err == nil || time.Since(start) > 2*time.Second {
		t.Fatalf("timeout: err=%v after %v", err, time.Since(start))
	}
}
