package daemon

import (
	"context"
	"errors"
	"sync"
	"time"

	"github.com/feg55/zarp-macos/zarpd/warp"
)

// FileAccounts is the real Accounts: the WARP registration lives in one root-owned JSON file
// (warp.LoadConfig/Register). Registration happens only when the app asks for it — after the user
// has accepted Cloudflare's WARP terms there — never at daemon startup, where it used to run
// unconditionally (with the terms auto-accepted, and with a failure — no network at boot — killing
// the process and launchd relaunching it into the same failure every few seconds).
type FileAccounts struct {
	Path       string
	DeviceName string
	// Timeout bounds one registration (default 60s): the underlying API call takes no context.
	Timeout time.Duration
	// RegisterFn performs the registration (default warp.Register); tests substitute it.
	RegisterFn func(configPath, deviceName string) error

	mu  sync.Mutex
	has bool
}

// Has reports whether a usable account is on disk. A positive answer is cached — an account does
// not un-register itself — so the frequent status/ping calls don't re-read the file.
func (a *FileAccounts) Has() bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	if !a.has && warp.HasAccount(a.Path) {
		a.has = true
	}
	return a.has
}

// Register creates the account.
func (a *FileAccounts) Register(ctx context.Context) error {
	fn := a.RegisterFn
	if fn == nil {
		fn = warp.Register
	}
	timeout := a.Timeout
	if timeout <= 0 {
		timeout = 60 * time.Second
	}
	done := make(chan error, 1)
	go func() { done <- fn(a.Path, a.DeviceName) }()
	select {
	case err := <-done:
		return err
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(timeout):
		return errors.New("timed out waiting for Cloudflare")
	}
}
