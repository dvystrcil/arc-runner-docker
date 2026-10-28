#!/usr/bin/env bash
# Build-time downloads must survive a flaky link (homelab#1801): on
# 2026-10-28 a go.dev fetch stalled 1002s and then killed the whole build.
# scripts/fetch.sh retries and aborts on a stall. Two things to hold:
#
#  1. No curl/wget in a Dockerfile writes to a PIPE. Retried, curl APPENDS
#     the second attempt to stdout (measured on the runner image's curl 8.5.0:
#     a 200000-byte body dropped halfway arrived as 300000 bytes), so
#     `curl --retry | tar` corrupts on exactly the flaky day it is meant for.
#     With -o FILE curl truncates and starts over. fetch.sh only takes a FILE.
#  2. fetch.sh itself: correct bytes after a mid-transfer drop, and a stall
#     fails fast instead of hanging.
#
#   tests/test-fetch.sh            # both
#   tests/test-fetch.sh --static   # 1 only (no python3/network needed)
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0

# --- 1. no piped downloads. Join `\` continuations so a pipe on the next
# line counts, then judge each command (split on ; && ||) on its own.
for f in Dockerfile*; do
  sed -e ':a' -e '/\\$/N; s/\\\n//; ta' "$f" | grep -vE '^[[:space:]]*#' \
    | sed -E 's/(;|&&|\|\|)/\n/g' \
    | grep -nE '(^|[[:space:](])(curl|wget)[[:space:]][^|]*\|' \
    | sed "s#^#$f: piped download (use scripts/fetch.sh URL FILE): #"
done > /tmp/piped.$$
if [ -s /tmp/piped.$$ ]; then cat /tmp/piped.$$; fail=1; else echo "ok: no piped downloads"; fi
rm -f /tmp/piped.$$
[ "${1:-}" = --static ] && exit $fail

# --- 2. fetch.sh behavior, against a local server.
[ -x scripts/fetch.sh ] || { echo "FAIL: scripts/fetch.sh missing or not executable"; exit 1; }
dir=$(mktemp -d); trap 'kill $srv 2>/dev/null; rm -rf "$dir"' EXIT
cat > "$dir/srv.py" <<'EOF'
import http.server, socketserver, sys, time
BODY = b"A" * 200000; seen = set()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        first = self.path not in seen; seen.add(self.path)
        self.send_response(200); self.send_header("Content-Length", str(len(BODY))); self.end_headers()
        if self.path.startswith("/drop") and first:   # half the body, then hang up
            self.wfile.write(BODY[:100000]); self.wfile.flush(); self.connection.shutdown(2); return
        if self.path == "/stall":                # a trickle, then nothing
            self.wfile.write(BODY[:10]); self.wfile.flush(); time.sleep(30); return
        self.wfile.write(BODY)
    def log_message(self, *a): pass
socketserver.ThreadingTCPServer.allow_reuse_address = True
socketserver.ThreadingTCPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
EOF
port=$((20000 + RANDOM % 20000))
python3 -I "$dir/srv.py" $port & srv=$!
for _ in $(seq 50); do curl -s -o /dev/null http://127.0.0.1:$port/ && break; sleep 0.1; done

# Control: without retries the same drop must fail, or the server never
# dropped and the check below proves nothing.
if FETCH_RETRY=0 scripts/fetch.sh http://127.0.0.1:$port/drop-control "$dir/ctl" 2>/dev/null; then
  echo "FAIL: control: the server did not drop the transfer"; fail=1
fi
if FETCH_RETRY_DELAY=1 scripts/fetch.sh http://127.0.0.1:$port/drop "$dir/drop" 2>/dev/null \
   && [ "$(wc -c < "$dir/drop")" -eq 200000 ]; then
  echo "ok: a dropped transfer is retried into a correct file"
else
  echo "FAIL: dropped transfer -> $(wc -c < "$dir/drop" 2>/dev/null || echo none) bytes, want 200000"; fail=1
fi

t0=$SECONDS
if FETCH_SPEED_TIME=2 FETCH_RETRY=1 FETCH_RETRY_DELAY=1 \
   scripts/fetch.sh http://127.0.0.1:$port/stall "$dir/stall" 2>/dev/null; then
  echo "FAIL: a stalled transfer succeeded"; fail=1
elif [ $((SECONDS - t0)) -gt 15 ] || [ $((SECONDS - t0)) -lt 2 ]; then
  # < 2s means it never got to the stall window: it failed for another reason.
  echo "FAIL: a stalled transfer took $((SECONDS - t0))s to fail, want the stall abort (2-15s)"; fail=1
else
  echo "ok: a stalled transfer fails in $((SECONDS - t0))s"
fi

[ $fail -eq 0 ] && echo "TEST-FETCH-COMPLETE"
exit $fail
