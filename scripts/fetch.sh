#!/bin/sh
# fetch.sh URL FILE -- every build-time download (tests/test-fetch.sh).
#
# Always to a FILE: on a retry curl truncates -o and starts over, but APPENDS
# to stdout, so `curl --retry | tar` corrupts on the very day it retries.
# A stall (< 100 KB/s for 30s) aborts and retries instead of hanging: a
# go.dev fetch once sat 1002s before failing the build (2026-10-28,
# homelab#1801). --retry-all-errors because a dropped HTTP/2 stream (92) or a
# short read (18) is not in curl's "transient" list. The FETCH_* overrides
# exist for the test.
set -eu
[ $# -eq 2 ] || { echo "usage: fetch.sh URL FILE" >&2; exit 2; }
exec curl -fsSL --connect-timeout 20 \
  --speed-limit 100000 --speed-time "${FETCH_SPEED_TIME:-30}" \
  --retry "${FETCH_RETRY:-5}" --retry-all-errors --retry-delay "${FETCH_RETRY_DELAY:-5}" \
  -o "$2" "$1"
