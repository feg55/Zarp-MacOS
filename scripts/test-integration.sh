#!/bin/bash
# End-to-end test of zarpd against the REAL network — the checks a unit test cannot do.
#
#   scripts/test-integration.sh              # run everything (asks for your password once, via sudo)
#   scripts/test-integration.sh --h2         # use the HTTP/2 transport with a ClientHello split
#   scripts/test-integration.sh --no-tunnel  # skip the tests that route all traffic through WARP
#
# REQUIREMENTS
#   * Turn OFF any other VPN first (Happ, WireGuard, ...). The script never touches your VPN: if
#     the default route is on a tunnel interface (utunN) it refuses to start.
#   * Internet access, and Go installed (it builds zarpd and zarpctl from this checkout).
#
# WHAT IT DOES
#   It starts its OWN zarpd on a private socket in /tmp (the installed LaunchDaemon is untouched)
#   and drives it with zarpctl through the same calls the app makes:
#     1  ping / protocol version
#     2  request validation (no network): flood-sized repeats, non-WARP endpoint
#     3  file-descriptor leak on failed dials (it used to leak one UDP socket per failure)
#     4  a real scan-style connection: open, measure (warp=on), close, route removed
#     5  orphaned test connection: client "crashes" without closing; the next open takes over, and
#        the lease reaps one that nobody replaces
#     6a FULL TUNNEL, routes only: all traffic through WARP (IPv4, IPv6 if you have it), the
#        tunnel must stay up (the control connection must not be swallowed by its own routes),
#        large download, then a clean disconnect that removes every route
#     6b FULL TUNNEL + DNS override: names resolve through Cloudflare, DNS restored exactly after
#     7  daemon killed with -9 while the tunnel is up: the /1 routes must vanish by themselves, and
#        the next start must remove the endpoint route and put DNS back
#     8  daemon stopped with SIGTERM while the tunnel is up: everything restored at once
#
# A test that needs the tunnel first checks it is really up (and still up a few seconds later) —
# a dead tunnel is reported as such, not as a pass of the cleanup checks that follow.
#
# SAFETY
#   * Whatever happens (Ctrl-C, a failed test, a hang), an exit handler tears the test daemon down
#     and then CHECKS that the default route, DNS and connectivity are as they were — printing the
#     exact repair commands if anything is not.
#   * A watchdog ends the whole run after 15 minutes.
#   * The /1 routes of a full tunnel are bound to the tunnel interface, so even `kill -9` of the
#     daemon removes them (test 7 proves it). The one route that is not — the host route that keeps
#     the WARP endpoint off the tunnel — is journaled, and the next daemon start deletes it.
#
# At the end it prints a block to copy back to the developer; the daemon log is kept for the whole
# run (it is not reset when the daemon is restarted).

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
STAGE2=0
BIN=""
# Stage 2 is this same script re-run under sudo: `--stage2 <bin dir> [flags]`.
if [[ "${1:-}" == "--stage2" ]]; then STAGE2=1; shift; BIN=$1; shift; fi

MODE="all"
TRANSPORT_ARGS=(-transport h3 -fake quic_google:6)
TRANSPORT_LABEL="HTTP/3 + quic_google x6"
for arg in "$@"; do
  case "$arg" in
    --h2) TRANSPORT_ARGS=(-transport h2 -split split:host,midsld); TRANSPORT_LABEL="HTTP/2 + split host,midsld" ;;
    --no-tunnel) MODE="narrow" ;;
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------- stage 1: build as the user
if [[ $STAGE2 -eq 0 ]]; then
  if [[ $EUID -eq 0 ]]; then
    echo "Run this as your normal user (it asks for sudo itself when needed), not with sudo." >&2
    exit 2
  fi
  export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/local/go/bin:$PATH"
  command -v go >/dev/null || { echo "Go is not installed (brew install go)." >&2; exit 2; }

  BIN=$(mktemp -d /tmp/zarpd-itest-bin.XXXXXX)
  echo "==> Building zarpd and zarpctl"
  ( cd "$REPO/zarpd" \
    && GOOS=darwin GOARCH=arm64 CGO_ENABLED=1 go build -trimpath -ldflags "-X main.version=itest" -o "$BIN/zarpd" ./cmd/zarpd \
    && GOOS=darwin GOARCH=arm64 CGO_ENABLED=1 go build -trimpath -o "$BIN/zarpctl" ./cmd/zarpctl ) \
    || { echo "build failed" >&2; exit 2; }

  # Refuse early (before asking for a password) if a VPN owns the default route.
  DEFIF=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')
  if [[ -z "$DEFIF" ]]; then
    echo "STOP: this Mac has no default route (not online). Connect to the internet and run it again." >&2
    rm -rf "$BIN"
    exit 3
  fi
  if [[ "$DEFIF" == utun* ]]; then
    echo "" >&2
    echo "STOP: the default route is on $DEFIF — another VPN/proxy is active." >&2
    echo "Turn it off yourself (this script never touches your VPN), then run it again." >&2
    rm -rf "$BIN"
    exit 3
  fi

  echo "==> Starting the privileged half (sudo)"
  exec sudo -E "$0" --stage2 "$BIN" "$@"
fi

# ---------------------------------------------------------------- stage 2: root
ZARPD="$BIN/zarpd"
CTL="$BIN/zarpctl"
TMP=$(mktemp -d /tmp/zarpd-itest.XXXXXX)
SOCK="$TMP/z.sock"
CFG="$TMP/cfg.json"
LOG="$TMP/zarpd.log"
DNSB="$TMP/dns-backup.json"
JOURNAL="$TMP/exclusions.json"   # private, like the socket: never the installed daemon's journal
DPID=""
STARTS=0
EXCL_IPS=()                      # every WARP endpoint a full tunnel used (for the machine-state check)
PASS=0; FAIL=0; SKIP=0
RESULTS=()
SCRIPT_PID=$$

PROD_CFG="/Library/Application Support/Zarp/zarp-warp-config.json"

ctl() { "$CTL" -socket "$SOCK" "$@"; }
jget() { python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    for k in sys.argv[1].split("."):
        d=d[k]
    print(d if not isinstance(d,bool) else str(d).lower())
except Exception:
    print("")' "$1"; }

pass() { PASS=$((PASS+1)); RESULTS+=("PASS  $1"); echo "  PASS  $1"; }
fail() { FAIL=$((FAIL+1)); RESULTS+=("FAIL  $1${2:+ — $2}"); echo "  FAIL  $1${2:+ — $2}"; }
skip() { SKIP=$((SKIP+1)); RESULTS+=("SKIP  $1${2:+ — $2}"); echo "  SKIP  $1${2:+ — $2}"; }
step() { echo; echo "== $*"; }

# ---------------------------------------------------------------- baseline (to verify recovery)
ORIG_DEFAULT_IF=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')
ORIG_SERVICE=$(networksetup -listnetworkserviceorder 2>/dev/null | awk -v dev="$ORIG_DEFAULT_IF" '
  /^\([0-9*]+\)/ { sub(/^\([0-9*]+\) /,""); name=$0 }
  /Hardware Port:/ && index($0, "Device: " dev ")") { print name; exit }')
ORIG_DNS=$(networksetup -getdnsservers "$ORIG_SERVICE" 2>/dev/null | tr '\n' ' ')
ORIG_TRACE_WARP=$(curl -sS --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^warp=/ {print $2}')
# Does this network have working IPv6 *without* the tunnel? Decided up front, so that during the
# tunnel test a broken IPv6 path is a FAIL, not mistaken for "no IPv6 here".
HAS_V6=0
curl -6 -sS --max-time 6 -o /dev/null https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null && HAS_V6=1

# ---------------------------------------------------------------- daemon control
start_daemon() {
  STARTS=$((STARTS+1))
  echo "=== test daemon start #$STARTS at $(date +%H:%M:%S) ===" >>"$LOG"   # appended, never truncated
  "$ZARPD" -socket "$SOCK" -config "$CFG" -blobs "$REPO/Resources/blobs" -log "-" \
           -dns-backup "$DNSB" -route-journal "$JOURNAL" -test-lease 8s >>"$LOG" 2>&1 &
  DPID=$!
  for _ in $(seq 1 50); do
    [[ -S "$SOCK" ]] && ctl ping >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

stop_daemon() {  # graceful
  [[ -n "$DPID" ]] || return 0
  kill -TERM "$DPID" 2>/dev/null
  for _ in $(seq 1 60); do kill -0 "$DPID" 2>/dev/null || { DPID=""; return 0; }; sleep 0.1; done
  kill -KILL "$DPID" 2>/dev/null; DPID=""
}

# ---------------------------------------------------------------- observation helpers
log_mark()  { wc -l <"$LOG" 2>/dev/null | tr -d ' '; }
log_since() { tail -n +$(( ${1:-0} + 1 )) "$LOG" 2>/dev/null; }
dump_log()  { echo "     ---- daemon log since this test started ----"; log_since "${1:-0}" | tail -"${2:-30}" | sed 's/^/     | /'; echo "     --------------------------------------------"; }
tunnel_up() { [[ "$(ctl status 2>/dev/null | jget connected)" == "true" ]]; }
# A static host route for $1 (the endpoint exclusion): netstat shows flags like UGHS / UHS.
excl_present() { netstat -rn -f inet 2>/dev/null | awk -v ip="$1" '$1==ip && $3 ~ /S/ {f=1} END {exit !f}'; }
slash_routes() { netstat -rn -f inet | awk '($1=="0/1" || $1=="128.0/1") && /utun/ {n++} END {print n+0}'; }
dns_now() { networksetup -getdnsservers "$ORIG_SERVICE" 2>/dev/null | tr '\n' ' '; }

# open_full_tunnel <with-dns 0|1> — fills FT (raw answer), FID, UT, EP, EPIP; returns 1 if it didn't open.
open_full_tunnel() {
  local dnsflag=(); [[ ${1:-0} -eq 1 ]] && dnsflag=(-dns)
  FT=$(ctl open "${TRANSPORT_ARGS[@]}" -timeout 25s -strategy itest -persistent -route-all ${dnsflag[@]+"${dnsflag[@]}"} 2>&1)
  FID=$(echo "$FT" | jget connectionId); UT=$(echo "$FT" | jget utunName); EP=$(echo "$FT" | jget endpoint)
  EPIP=${EP%:*}
  [[ -n "$FID" ]] || return 1
  [[ -n "$EPIP" ]] && EXCL_IPS+=("$EPIP")
  return 0
}
# tunnel_survives <log mark> <seconds> — the tunnel must still be up after sitting idle for a while.
tunnel_survives() {
  sleep "$2"
  tunnel_up && return 0
  echo "     status: $(ctl status 2>&1)"
  dump_log "$1" 30
  return 1
}

# ---------------------------------------------------------------- recovery check / exit handler
verify_machine_state() {
  local ok=1
  local now_if; now_if=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')
  echo
  echo "== Checking the machine is back to normal"
  if [[ "$now_if" == "$ORIG_DEFAULT_IF" ]]; then echo "  default route: $now_if (as before)"; else echo "  !! default route is $now_if, was $ORIG_DEFAULT_IF"; ok=0; fi
  if netstat -rn -f inet 2>/dev/null | awk '$1=="0/1" || $1=="128.0/1" {print}' | grep -q utun; then
    echo "  !! leftover 0/1 or 128.0/1 routes via a utun remain"; ok=0
  else echo "  no full-tunnel routes left"; fi
  if netstat -rn -f inet 2>/dev/null | awk '$1=="1.1.1.1" {print}' | grep -q utun; then
    echo "  !! leftover 1.1.1.1 route via a utun"; ok=0
  fi
  local ip
  for ip in ${EXCL_IPS[@]+"${EXCL_IPS[@]}"}; do
    if excl_present "$ip"; then echo "  !! leftover host route for the WARP endpoint $ip"; ok=0; fi
  done
  if [[ -f "$JOURNAL" ]]; then echo "  !! the route journal still lists routes: $(cat "$JOURNAL")"; ok=0; fi
  local dns_cur; dns_cur=$(dns_now)
  if [[ "$dns_cur" == "$ORIG_DNS" ]]; then echo "  DNS for '$ORIG_SERVICE': unchanged"; else echo "  !! DNS for '$ORIG_SERVICE' is now: $dns_cur (was: $ORIG_DNS)"; ok=0; fi
  if curl -sS --max-time 8 -o /dev/null http://captive.apple.com/hotspot-detect.html 2>/dev/null \
     || curl -sS --max-time 8 -o /dev/null https://1.1.1.1/cdn-cgi/trace 2>/dev/null; then echo "  connectivity: OK"; else echo "  !! no direct connectivity (neither captive.apple.com nor 1.1.1.1 answered)"; ok=0; fi
  if [[ $ok -eq 0 ]]; then
    echo
    echo "  REPAIR (copy/paste — each is safe to run):"
    echo "    sudo route -n delete -inet 0.0.0.0/1;  sudo route -n delete -inet 128.0.0.0/1"
    echo "    sudo route -n delete -inet6 ::/1;      sudo route -n delete -inet6 8000::/1"
    echo "    sudo route -n delete -host 1.1.1.1"
    for ip in ${EXCL_IPS[@]+"${EXCL_IPS[@]}"}; do echo "    sudo route -n delete -host $ip"; done
    if [[ -n "$ORIG_DNS" && "$ORIG_DNS" != *"There aren"* ]]; then
      echo "    sudo networksetup -setdnsservers \"$ORIG_SERVICE\" $ORIG_DNS"
    else
      echo "    sudo networksetup -setdnsservers \"$ORIG_SERVICE\" Empty"
    fi
  fi
  return $((1-ok))
}

CLEANED=0
cleanup() {
  [[ $CLEANED -eq 1 ]] && return; CLEANED=1
  trap - EXIT INT TERM
  echo; echo "== Cleaning up"
  # A daemon killed with -9 leaves its DNS override and endpoint route behind: starting one runs the recovery.
  if [[ ( -f "$DNSB" || -f "$JOURNAL" ) && -z "$DPID" ]]; then echo "  recovering what a killed daemon left (DNS / endpoint route)"; start_daemon >/dev/null 2>&1; fi
  stop_daemon
  [[ -f "$DNSB" ]] && echo "  !! DNS backup still present: $DNSB"
  verify_machine_state; STATE_OK=$?
  echo
  echo "================ RESULT ================"
  echo "transport: $TRANSPORT_LABEL   mode: $MODE"
  printf '%s\n' ${RESULTS[@]+"${RESULTS[@]}"}
  echo "passed=$PASS failed=$FAIL skipped=$SKIP   machine-state=$([[ ${STATE_OK:-1} -eq 0 ]] && echo OK || echo CHECK-ABOVE)"
  echo "---------------- daemon log (last 80 lines of the whole run) ----------------"
  tail -80 "$LOG" 2>/dev/null
  echo "=========================================="
  echo "Copy everything between the RESULT line and this one back to the developer."
  rm -rf "$TMP" "$BIN"
  exit $(( FAIL > 0 || ${STATE_OK:-1} != 0 ))
}
trap cleanup EXIT INT TERM HUP
WATCHDOG=""
( sleep 900; echo "WATCHDOG: 15 minutes elapsed, ending the run" >&2; kill -TERM $SCRIPT_PID 2>/dev/null ) &
WATCHDOG=$!

# ---------------------------------------------------------------- setup
step "Setup"
echo "  baseline: default route $ORIG_DEFAULT_IF, service '$ORIG_SERVICE', DNS: ${ORIG_DNS:-none}, warp=${ORIG_TRACE_WARP:-?} (must NOT be on/plus)"
if [[ "$ORIG_TRACE_WARP" == "on" || "$ORIG_TRACE_WARP" == "plus" ]]; then
  echo "  This machine is already going through WARP (the official client?). Turn it off first." >&2; exit 3
fi
# The installed Zarp service must be idle, and nothing may already own the routes this test installs.
if [[ -S /var/run/zarpd.sock ]]; then
  PS=$("$CTL" -socket /var/run/zarpd.sock status 2>/dev/null)
  if [[ "$(echo "$PS" | jget connected)" == "true" ]]; then
    echo "  The installed Zarp service has an active connection. Disconnect in the Zarp app first, then re-run." >&2; exit 3
  fi
fi
if netstat -rn -f inet 2>/dev/null | awk '$1=="0/1" || $1=="128.0/1" || $1=="1.1.1.1" {print}' | grep -q utun; then
  echo "  Routes for 0/1, 128.0/1 or 1.1.1.1 already exist via a utun (another VPN, or an unclosed Zarp tunnel). Remove them first." >&2; exit 3
fi
if [[ -f "$PROD_CFG" ]]; then cp "$PROD_CFG" "$CFG"; echo "  using the existing WARP account"; else echo "  no WARP account yet: one will be registered with Cloudflare"; fi
start_daemon || { echo "  the test daemon did not start:"; cat "$LOG"; exit 1; }
echo "  test daemon pid $DPID on $SOCK"

# ---------------------------------------------------------------- 1. ping
step "1. ping and protocol"
P=$(ctl ping)
[[ "$(echo "$P" | jget protocol)" == "2" ]] && pass "protocol version 2" || fail "protocol version" "$P"
if [[ "$(echo "$P" | jget accountRegistered)" != "true" ]]; then
  R=$(ctl register 2>&1); [[ "$(echo "$R" | jget accountRegistered)" == "true" ]] && pass "registered a WARP account" || fail "register" "$R"
else pass "WARP account present"; fi

# ---------------------------------------------------------------- 2. validation
step "2. request validation (a root daemon must refuse these)"
E=$(ctl open -transport h3 -fake quic_google:1000000 2>&1); [[ "$E" == *"[bad_request]"* ]] && pass "refuses repeats=1000000" || fail "repeats flood" "$E"
E=$(ctl open -transport h3 -endpoint 8.8.8.8 2>&1);        [[ "$E" == *"[bad_request]"* ]] && pass "refuses an endpoint outside WARP's ranges" || fail "arbitrary endpoint" "$E"
E=$(ctl open -transport h3 -route-all 2>&1);              [[ "$E" == *"[bad_request]"* ]] && pass "refuses -route-all on a test connection" || fail "route-all without persistent" "$E"

# ---------------------------------------------------------------- 3. fd leak
step "3. file descriptors across failed dials"
fdcount() { lsof -p "$DPID" 2>/dev/null | wc -l | tr -d ' '; }
FD0=$(fdcount)
for i in $(seq 1 15); do ctl open -transport h3 -timeout 1ms >/dev/null 2>&1; done
sleep 0.5
FD1=$(fdcount)
if [[ -n "$FD0" && -n "$FD1" && $((FD1 - FD0)) -le 3 ]]; then pass "15 failed dials: fds $FD0 -> $FD1"; else fail "fd leak" "fds $FD0 -> $FD1 after 15 failed dials (each used to leak one)"; fi

# ---------------------------------------------------------------- 4. real narrow connection
step "4. a real test connection ($TRANSPORT_LABEL)"
NET_OK=0
O=$(ctl open "${TRANSPORT_ARGS[@]}" -timeout 20s -endpoint isolated-0 2>&1)
ID=$(echo "$O" | jget connectionId)
if [[ -n "$ID" ]]; then
  pass "open: $(echo "$O" | jget utunName) endpoint $(echo "$O" | jget endpoint) in $(echo "$O" | jget connectMs) ms"
  M=$(ctl measure "$ID" -samples 3 2>&1)
  if [[ "$(echo "$M" | jget kind)" == "ok" ]]; then pass "measure: warp=$(echo "$M" | jget warp), ping $(echo "$M" | jget pingMs) ms"; NET_OK=1; else fail "measure through the test connection" "$M"; fi
  if netstat -rn -f inet | awk '$1=="1.1.1.1" {print}' | grep -q utun; then pass "test route 1.1.1.1 is on the tunnel"; else fail "test route" "no 1.1.1.1 route via a utun"; fi
  ctl close "$ID" >/dev/null 2>&1
  sleep 0.5
  if netstat -rn -f inet | awk '$1=="1.1.1.1" {print}' | grep -q utun; then fail "route removal after close"; else pass "route removed after close"; fi
else
  fail "open a test connection" "$O"
  echo "     (if your network blocks this strategy, try:  scripts/test-integration.sh --h2)"
fi

# ---------------------------------------------------------------- 5. orphans
step "5. orphaned test connection (client 'crashes' without closing)"
if [[ $NET_OK -eq 1 ]]; then
  O1=$(ctl open "${TRANSPORT_ARGS[@]}" -timeout 20s -endpoint isolated-1 2>&1)   # zarpctl exits here: nobody will ever close it
  ID1=$(echo "$O1" | jget connectionId)
  [[ -n "$ID1" ]] && pass "opened #$ID1 and abandoned it" || fail "open the orphan" "$O1"
  O2=$(ctl open "${TRANSPORT_ARGS[@]}" -timeout 20s -endpoint isolated-2 2>&1)   # used to fail: "route: File exists"
  ID2=$(echo "$O2" | jget connectionId)
  [[ -n "$ID2" ]] && pass "the next open took over (#$ID2); no 'File exists'" || fail "open after an orphan" "$O2"
  sleep 10   # the test lease is 8s
  if netstat -rn -f inet | awk '$1=="1.1.1.1" {print}' | grep -q utun; then fail "lease reaping" "the abandoned connection's route is still there after the lease"; else pass "lease reaped the abandoned connection"; fi
else skip "orphan handling" "needs test 4 to work"; fi

# ---------------------------------------------------------------- 6-8. full tunnel
# full_tunnel_checks <label> <with-dns 0|1> — sets FT_SURVIVED=1 when the tunnel was up and stayed up.
full_tunnel_checks() {
  local label=$1 withdns=$2 mark; mark=$(log_mark)
  FT_SURVIVED=0
  if ! open_full_tunnel "$withdns"; then fail "$label: open the full tunnel" "$FT"; dump_log "$mark"; return; fi
  pass "$label: open: $UT, endpoint $EP"
  local W; W=$(echo "$FT" | python3 -c 'import json,sys; print("; ".join(json.load(sys.stdin).get("warnings") or []))')
  [[ -n "$W" ]] && echo "     warnings from the daemon: $W"

  local S; S=$(ctl status)
  [[ "$(echo "$S" | jget connected)" == "true" && "$(echo "$S" | jget routeAll)" == "true" ]] && pass "$label: status: connected, routeAll" || { fail "$label: status right after open" "$S"; dump_log "$mark"; ctl close "$FID" >/dev/null 2>&1; return; }
  # The decisive check of the first real run: the tunnel must not die the moment its routes go in.
  if tunnel_survives "$mark" 4; then pass "$label: the tunnel is still up after 4 s idle"; else fail "$label: the tunnel died right after it came up" "see the daemon log above"; ctl close "$FID" >/dev/null 2>&1; return; fi
  FT_SURVIVED=1

  echo "     routing table (full-tunnel entries):"; netstat -rn -f inet | awk -v ip="$EPIP" '$1=="0/1" || $1=="128.0/1" || $1==ip' | sed 's/^/       /'
  [[ "$(slash_routes)" == "2" ]] && pass "$label: IPv4 /1 routes via $UT" || fail "$label: IPv4 routes" "found $(slash_routes) of 2"
  if excl_present "$EPIP"; then pass "$label: the WARP endpoint has its own host route"; else fail "$label: endpoint exclusion route" "no host route for $EPIP"; fi
  local EPIF; EPIF=$(route -n get -host "$EPIP" 2>/dev/null | awk '/interface:/ {print $2}')
  [[ "$EPIF" == "$ORIG_DEFAULT_IF" ]] && pass "$label: the WARP endpoint still leaves via $EPIF (not into the tunnel)" || fail "$label: endpoint route" "leaves via '${EPIF:-?}', expected $ORIG_DEFAULT_IF"
  [[ "$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')" == "$ORIG_DEFAULT_IF" ]] && pass "$label: the real default route is untouched" || fail "$label: default route changed"

  local TR WARPV CODE
  TR=$(curl -sS --max-time 15 https://www.cloudflare.com/cdn-cgi/trace 2>&1)
  WARPV=$(echo "$TR" | awk -F= '/^warp=/ {print $2}')
  [[ "$WARPV" == "on" || "$WARPV" == "plus" ]] && pass "$label: general traffic is on WARP (www.cloudflare.com: warp=$WARPV)" || { fail "$label: general traffic through WARP" "warp=${WARPV:-<no answer>}  ${TR:0:120}"; dump_log "$mark" 15; }
  CODE=$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' https://example.com 2>&1)
  [[ "$CODE" == "200" ]] && pass "$label: an ordinary site works (example.com: $CODE)" || fail "$label: ordinary site" "$CODE"

  if [[ $withdns -eq 0 ]]; then
    local DL; DL=$(curl -sS --max-time 60 -o /dev/null -w '%{size_download} bytes at %{speed_download} B/s, exit' 'https://speed.cloudflare.com/__down?bytes=8000000' 2>&1)
    [[ "$DL" == 8000000* ]] && pass "$label: an 8 MB download completes (MTU/fragmentation OK): $DL" || fail "$label: large download" "$DL"
    if [[ $HAS_V6 -eq 1 ]]; then
      local T6; T6=$(curl -6 -sS --max-time 15 https://www.cloudflare.com/cdn-cgi/trace 2>&1 | awk -F= '/^warp=/ {print $2}')
      [[ "$T6" == "on" || "$T6" == "plus" ]] && pass "$label: IPv6 traffic is on WARP (warp=$T6)" || fail "$label: IPv6 through WARP" "warp=${T6:-<no answer>} (this network has IPv6; with the tunnel up it must go through WARP)"
    else
      skip "$label: IPv6 through WARP" "this network has no IPv6 connectivity"
    fi
    [[ "$(dns_now)" == "$ORIG_DNS" ]] && pass "$label: DNS untouched without -dns" || fail "$label: DNS changed although -dns was not asked" "now '$(dns_now)'"
  else
    local NS HOSTIP
    NS=$(scutil --dns 2>/dev/null | awk '/nameserver\[0\]/ {print $3; exit}')
    [[ "$NS" == "1.1.1.1" ]] && pass "$label: DNS points at Cloudflare while connected ($NS)" || fail "$label: DNS override" "first resolver is '$NS'"
    HOSTIP=$(dscacheutil -q host -a name example.com 2>/dev/null | awk '/ip_address/ {print $2; exit}')
    [[ -n "$HOSTIP" ]] && pass "$label: names resolve ($HOSTIP)" || fail "$label: name resolution while connected"
  fi

  ctl close "$FID" >/dev/null 2>&1
  sleep 1
  [[ "$(slash_routes)" == "0" ]] && pass "$label: /1 routes removed after disconnect" || fail "$label: route removal" "$(slash_routes) left"
  if excl_present "$EPIP"; then fail "$label: endpoint route removal" "the host route for $EPIP is still there"; else pass "$label: endpoint host route removed after disconnect"; fi
  [[ -f "$JOURNAL" ]] && fail "$label: route journal after disconnect" "still lists: $(cat "$JOURNAL")" || pass "$label: route journal is empty again"
  [[ "$(dns_now)" == "$ORIG_DNS" ]] && pass "$label: DNS exactly as before" || fail "$label: DNS restore" "now '$(dns_now)', was '$ORIG_DNS'"
  local OFF; OFF=$(curl -sS --max-time 10 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^warp=/ {print $2}')
  [[ "$OFF" == "off" || -z "$OFF" ]] && pass "$label: traffic is direct again (warp=${OFF:-n/a})" || fail "$label: traffic after disconnect" "warp=$OFF"
}

if [[ "$MODE" == "narrow" || $NET_OK -ne 1 ]]; then
  skip "full tunnel (tests 6-8)" "$([[ "$MODE" == "narrow" ]] && echo "--no-tunnel" || echo "needs test 4 to work")"
else
  step "6a. FULL TUNNEL, routes only (no DNS override)"
  full_tunnel_checks "6a" 0
  TUNNEL_WORKS=$FT_SURVIVED

  step "6b. FULL TUNNEL with the DNS override"
  if [[ $TUNNEL_WORKS -eq 1 ]]; then full_tunnel_checks "6b" 1; else skip "6b: DNS override" "the tunnel itself did not work in 6a"; fi

  step "7. daemon killed with -9 while the full tunnel is up"
  if [[ $TUNNEL_WORKS -ne 1 ]]; then skip "kill -9 test" "no working tunnel to crash (see 6a)"; else
    MARK=$(log_mark)
    if ! open_full_tunnel 1; then fail "7: open the full tunnel (for the crash test)" "$FT"; dump_log "$MARK"
    elif ! tunnel_survives "$MARK" 3; then fail "7: the tunnel did not stay up, so the crash can't be judged"; ctl close "$FID" >/dev/null 2>&1
    else
      pass "7: the tunnel is up before the crash ($UT)"
      [[ -f "$DNSB" ]] && pass "7: DNS override is in place (backup on disk)" || fail "7: DNS override before the crash" "no backup file, so there is nothing to recover"
      [[ -f "$JOURNAL" ]] && pass "7: the endpoint route is journaled" || fail "7: route journal" "empty while the tunnel is up"
      kill -KILL "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null; DPID=""
      sleep 1
      [[ "$(slash_routes)" == "0" ]] && pass "7: the /1 routes vanished with the interface (fail-open)" || fail "7: routes after kill -9" "$(slash_routes) left: the machine would have no working default"
      echo "     endpoint host route after kill -9: $(excl_present "$EPIP" && echo "still there (expected — the next start removes it)" || echo "gone")"
      D=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' https://1.1.1.1/cdn-cgi/trace 2>&1)
      [[ "$D" == "200" ]] && pass "7: direct connectivity right after the crash" || fail "7: connectivity after the crash" "$D"
      start_daemon && pass "7: daemon restarted" || fail "7: restart after the crash" "$(tail -5 "$LOG")"
      sleep 1
      [[ "$(dns_now)" == "$ORIG_DNS" && ! -f "$DNSB" ]] && pass "7: startup recovery restored DNS" || fail "7: DNS recovery at startup" "now '$(dns_now)', was '$ORIG_DNS', backup present: $([[ -f "$DNSB" ]] && echo yes || echo no)"
      if excl_present "$EPIP" || [[ -f "$JOURNAL" ]]; then fail "7: startup recovery of the endpoint route" "route present: $(excl_present "$EPIP" && echo yes || echo no), journal present: $([[ -f "$JOURNAL" ]] && echo yes || echo no)"; else pass "7: startup recovery removed the endpoint route"; fi
    fi
  fi

  step "8. daemon stopped with SIGTERM while the full tunnel is up"
  if [[ $TUNNEL_WORKS -ne 1 ]]; then skip "SIGTERM test" "no working tunnel (see 6a)"; else
    if [[ -z "$DPID" ]]; then start_daemon || fail "8: daemon not running"; fi
    MARK=$(log_mark)
    if ! open_full_tunnel 1; then fail "8: open the full tunnel (for the shutdown test)" "$FT"; dump_log "$MARK"
    elif ! tunnel_survives "$MARK" 3; then fail "8: the tunnel did not stay up, so the shutdown can't be judged"; ctl close "$FID" >/dev/null 2>&1
    else
      pass "8: the tunnel is up before the shutdown ($UT)"
      stop_daemon
      sleep 0.5
      if [[ "$(slash_routes)" == "0" ]] && ! excl_present "$EPIP" && [[ "$(dns_now)" == "$ORIG_DNS" && ! -f "$JOURNAL" ]]; then pass "8: graceful shutdown restored routes, endpoint route and DNS"
      else fail "8: graceful shutdown" "/1 routes left: $(slash_routes), endpoint route: $(excl_present "$EPIP" && echo present || echo gone), journal: $([[ -f "$JOURNAL" ]] && echo present || echo gone), DNS now '$(dns_now)'"; fi
    fi
  fi
fi

exit 0   # the EXIT trap prints the result and the recovery check
