// zarpctl talks to a running zarpd over its IPC socket — the command-line twin of Zarp.app's
// ZarpdClient. It exists for development and for scripts/test-integration.sh, which drives a
// real daemon through the exact calls the app makes (open, measure, close, status, ...) so the
// behavior that needs root and a real network can be checked end to end without the GUI.
//
//	zarpctl ping
//	zarpctl status
//	zarpctl register
//	zarpctl logs [-since N]
//	zarpctl open -transport h3 -fake quic_google:6 [-fake quic_vk:3:4] [-endpoint isolated-1] [-persistent [-route-all [-dns]]]
//	zarpctl open -transport h2 -split split:host,midsld
//	zarpctl measure ID [-samples N]
//	zarpctl close ID
//	zarpctl restart
//
// Every command prints the daemon's JSON result; an error prints "error [code]: message" to stderr
// and exits 1. `open` exits as soon as it has the answer and does NOT close the connection it
// made — which is exactly what an app that crashes mid-scan looks like to the daemon.
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/feg55/zarp-macos/zarpd/ipc"
)

func main() {
	global := flag.NewFlagSet("zarpctl", flag.ExitOnError)
	socket := global.String("socket", "/var/run/zarpd.sock", "zarpd's IPC socket")
	wait := global.Duration("wait", 150*time.Second, "how long to wait for the daemon's answer")
	global.Usage = func() {
		fmt.Fprintln(os.Stderr, "usage: zarpctl [-socket PATH] [-wait DURATION] ping|status|register|logs|open|measure|close|restart [flags]")
	}
	_ = global.Parse(os.Args[1:])
	args := global.Args()
	if len(args) == 0 {
		global.Usage()
		os.Exit(2)
	}
	cmd, rest := args[0], args[1:]

	var method string
	var params any
	switch cmd {
	case "ping", "status", "register", "restart":
		method = cmd
	case "logs":
		fs := flag.NewFlagSet("logs", flag.ExitOnError)
		since := fs.Uint64("since", 0, "only lines newer than this sequence number")
		_ = fs.Parse(rest)
		method, params = "logs", ipc.LogsParams{Since: *since}
	case "close":
		if len(rest) != 1 {
			fatalUsage("close needs a connection id")
		}
		method, params = "close", ipc.CloseParams{ConnectionID: rest[0]}
	case "measure":
		if len(rest) < 1 {
			fatalUsage("measure needs a connection id")
		}
		fs := flag.NewFlagSet("measure", flag.ExitOnError)
		samples := fs.Int("samples", 3, "timed samples")
		_ = fs.Parse(rest[1:])
		method, params = "measure", ipc.MeasureParams{ConnectionID: rest[0], Samples: *samples}
	case "open":
		method, params = "open", parseOpen(rest)
	default:
		fatalUsage("unknown command " + cmd)
	}

	result, rpcErr, err := call(*socket, method, params, *wait)
	if err != nil {
		fmt.Fprintln(os.Stderr, "zarpctl:", err)
		os.Exit(1)
	}
	if rpcErr != nil {
		fmt.Fprintf(os.Stderr, "error [%s]: %s (timedOut=%v)\n", rpcErr.Code, rpcErr.Message, rpcErr.TimedOut)
		os.Exit(1)
	}
	pretty, _ := json.MarshalIndent(json.RawMessage(result), "", "  ")
	fmt.Println(string(pretty))
}

func fatalUsage(msg string) {
	fmt.Fprintln(os.Stderr, "zarpctl:", msg)
	os.Exit(2)
}

type multiFlag []string

func (m *multiFlag) String() string     { return strings.Join(*m, ",") }
func (m *multiFlag) Set(s string) error { *m = append(*m, s); return nil }

func parseOpen(args []string) ipc.OpenParams {
	fs := flag.NewFlagSet("open", flag.ExitOnError)
	transport := fs.String("transport", "h3", "h3 | h2")
	strategy := fs.String("strategy", "zarpctl", "strategy label reported by status")
	endpoint := fs.String("endpoint", "", `"", "ip[:port]" or "isolated-N"`)
	timeout := fs.Duration("timeout", 15*time.Second, "connect timeout")
	persistent := fs.Bool("persistent", false, "a persistent connection (what the app's Connect button makes)")
	routeAll := fs.Bool("route-all", false, "full tunnel: send all traffic through WARP (needs -persistent)")
	dns := fs.Bool("dns", false, "also override DNS while connected (needs -route-all)")
	split := fs.String("split", "", "h2 only: mode:positions, e.g. split:host,midsld or disorder:1")
	var fakes multiFlag
	fs.Var(&fakes, "fake", "h3 only, repeatable: blob:repeats[:ttl], e.g. quic_google:6 or quic_vk:6:4")
	_ = fs.Parse(args)

	p := ipc.OpenParams{
		StrategyID: *strategy, Endpoint: *endpoint, TimeoutMs: int(timeout.Milliseconds()),
		Persistent: *persistent, RouteAll: *routeAll, OverrideDNS: *dns,
	}
	switch *transport {
	case "h3":
		p.Transport = "masqueH3"
	case "h2":
		p.Transport = "masqueH2"
	default:
		fatalUsage("-transport must be h3 or h2")
	}
	for _, f := range fakes {
		parts := strings.Split(f, ":")
		if len(parts) < 2 || len(parts) > 3 {
			fatalUsage("bad -fake " + f)
		}
		repeats, err := strconv.Atoi(parts[1])
		if err != nil {
			fatalUsage("bad -fake repeats in " + f)
		}
		step := ipc.FakeStep{Blob: parts[0], Repeats: repeats}
		if len(parts) == 3 {
			ttl, err := strconv.Atoi(parts[2])
			if err != nil {
				fatalUsage("bad -fake ttl in " + f)
			}
			step.IPTTL = &ttl
		}
		p.FakeSteps = append(p.FakeSteps, step)
	}
	if *split != "" {
		mode, pos, ok := strings.Cut(*split, ":")
		if !ok {
			fatalUsage("-split needs mode:positions")
		}
		p.TCPDesync = &ipc.TCPDesync{Mode: mode, Positions: strings.Split(pos, ",")}
	}
	return p
}

func call(socket, method string, params any, wait time.Duration) (json.RawMessage, *ipc.ErrorInfo, error) {
	conn, err := net.DialTimeout("unix", socket, 3*time.Second)
	if err != nil {
		return nil, nil, fmt.Errorf("connect %s: %w — is zarpd running?", socket, err)
	}
	defer conn.Close()
	raw, err := json.Marshal(params)
	if err != nil {
		return nil, nil, err
	}
	if params == nil {
		raw = nil
	}
	line, _ := json.Marshal(ipc.Request{ID: uint64(time.Now().UnixNano()), Method: method, Params: raw})
	if _, err := conn.Write(append(line, '\n')); err != nil {
		return nil, nil, err
	}
	_ = conn.SetReadDeadline(time.Now().Add(wait))
	resp, err := bufio.NewReader(conn).ReadBytes('\n')
	if err != nil {
		return nil, nil, fmt.Errorf("reading the answer: %w", err)
	}
	var r ipc.Response
	if err := json.Unmarshal(resp, &r); err != nil {
		return nil, nil, fmt.Errorf("bad answer %q: %w", resp, err)
	}
	if r.Error != nil {
		return nil, r.Error, nil
	}
	return r.Result, nil, nil
}
