#!/usr/bin/env bash
# Dockerfile.orcaslicer reads Ubuntu packages from a pinned snapshot, never the
# live mirror (homelab#1981, D-051; design and tests: dvystrcil/homelab
# architecture/apt-snapshot-image-builds.md). Two parts:
#
#  1. static: the shape the bump job and the build rely on. One global
#     `ARG APT_SNAPSHOT=<YYYYMMDDTHHMMSSZ>` (homelab#2426 edits that line), the
#     direct snapshot as the default base, `--error-on=any` + retries on every
#     `apt-get update`, the pin as `URIs:` (not --snapshot / Snapshot:, which
#     still read the live mirror), and build.yaml's orcaslicer step passing the
#     in-cluster cache and running part 2 before it pushes.
#  2. blocked mirror: builds Dockerfile.orcaslicer twice, --no-cache so apt runs.
#     a. archive.ubuntu.com + security.ubuntu.com -> 127.0.0.1 in every RUN:
#        must build, >=1 fetch from the snapshot source, 0 from the live mirror.
#     b. the snapshot source's host blocked too (snapshot.ubuntu.com, or the
#        apt-cacher-ng Service in CI): must FAIL with apt's own
#        `E: Failed to fetch`, and no fetch from the live mirror.
#     --add-host is a build flag, so it reaches the RUN containers through the
#     daemon on the ARC DinD sidecar, which can't see this container's files.
#     The base's third-party sources (git-core PPA, cli.github.com) stay live
#     (owner decision, D-051) and are not blocked.
#
#   tests/test-apt-snapshot.sh            # both
#   tests/test-apt-snapshot.sh --static   # 1 only (no docker needed)
#
#   BASE_IMAGE         passed as --build-arg when set (CI: the image just built)
#   APT_SNAPSHOT_BASE  passed as --build-arg when set (CI: the cache URL)
#   DPKG_OUT           optional: write case a's `dpkg-query -W` here
#
# Prints TEST-APT-SNAPSHOT-COMPLETE as its last line only if every check held.
set -uo pipefail
cd "$(dirname "$0")/.."
DF=Dockerfile.orcaslicer
CACHE=http://apt-cacher-ng.arc-runner.svc.cluster.local:3142/HTTPS///snapshot.ubuntu.com/ubuntu
fail=0
bad() { echo "FAIL: $*"; fail=1; }

# --- 1. static
ids=$(grep -cE '^ARG APT_SNAPSHOT=' "$DF")
[ "$ids" -eq 1 ] || bad "$DF: want exactly one 'ARG APT_SNAPSHOT=' line, found $ids"
grep -qE '^ARG APT_SNAPSHOT=[0-9]{8}T[0-9]{6}Z$' "$DF" || bad "$DF: APT_SNAPSHOT is not YYYYMMDDTHHMMSSZ"
first_from=$(grep -nE '^FROM ' "$DF" | head -1 | cut -d: -f1)
id_line=$(grep -nE '^ARG APT_SNAPSHOT=' "$DF" | head -1 | cut -d: -f1)
[ -n "$id_line" ] && [ -n "$first_from" ] && [ "$id_line" -lt "$first_from" ] || bad "$DF: APT_SNAPSHOT must be a global ARG (before FROM)"
[ "$(grep -E '^ARG APT_SNAPSHOT_BASE=' "$DF")" = "ARG APT_SNAPSHOT_BASE=https://snapshot.ubuntu.com/ubuntu" ] \
  || bad "$DF: default APT_SNAPSHOT_BASE must be https://snapshot.ubuntu.com/ubuntu"
grep -qxE 'ARG APT_SNAPSHOT' "$DF" && grep -qxE 'ARG APT_SNAPSHOT_BASE' "$DF" || bad "$DF: ARGs not re-declared after FROM"
grep -qF 'URIs: ${APT_SNAPSHOT_BASE}/${APT_SNAPSHOT}/' "$DF" || bad "$DF: no URIs: rewrite to the snapshot"
code=$(grep -vE '^[[:space:]]*#' "$DF")
updates=$(printf '%s\n' "$code" | grep -oE 'apt-get update[^\\&]*')
[ -n "$updates" ] || bad "$DF: no apt-get update found"
while IFS= read -r u; do
  [ -z "$u" ] && continue
  case "$u" in *--error-on=any*'-o Acquire::Retries=3'*) ;; *) bad "$DF: '$u' lacks --error-on=any -o Acquire::Retries=3" ;; esac
done <<<"$updates"
printf '%s\n' "$code" | grep -qE -- '--snapshot|Snapshot:|APT::Snapshot' && bad "$DF: uses apt's snapshot option (still reads the live mirror)"
# build.yaml: only the orcaslicer step, up to the next step.
step=$(awk '/- name: Build and push orcaslicer-runner/{f=1; print; next} f && /^    - name:/{exit} f' .github/workflows/build.yaml)
[ -n "$step" ] || bad "build.yaml: no 'Build and push orcaslicer-runner' step"
printf '%s\n' "$step" | grep -qF "APT_SNAPSHOT_BASE: $CACHE" || bad "build.yaml: orcaslicer step does not set the cache URL"
printf '%s\n' "$step" | grep -E 'docker build .*-f Dockerfile.orcaslicer' | grep -qF -- '--build-arg APT_SNAPSHOT_BASE=$APT_SNAPSHOT_BASE' \
  || bad "build.yaml: orcaslicer docker build does not pass APT_SNAPSHOT_BASE"
printf '%s\n' "$step" | grep -qF 'tests/test-apt-snapshot.sh | tee apt-snapshot-test.out' || bad "build.yaml: orcaslicer step does not run the blocked-mirror test"
printf '%s\n' "$step" | grep -qF 'test "$(tail -n 1 apt-snapshot-test.out)" = TEST-APT-SNAPSHOT-COMPLETE' \
  || bad "build.yaml: orcaslicer step does not assert the test's completion marker"
[ "$fail" -eq 0 ] && echo "ok: static"
if [ "${1:-}" = --static ]; then
  [ "$fail" -eq 0 ] || exit 1
  echo TEST-APT-SNAPSHOT-COMPLETE; exit 0
fi

# --- 2. blocked mirror
IMG=orcaslicer-apt-snapshot-test:ci
LOGDIR=$(mktemp -d); trap 'rm -rf "$LOGDIR"' EXIT
args=()
[ -z "${BASE_IMAGE:-}" ] || args+=(--build-arg "BASE_IMAGE=${BASE_IMAGE}")
if [ -n "${APT_SNAPSHOT_BASE:-}" ]; then
  args+=(--build-arg "APT_SNAPSHOT_BASE=${APT_SNAPSHOT_BASE}"); base=$APT_SNAPSHOT_BASE
else
  base=$(sed -n 's/^ARG APT_SNAPSHOT_BASE=//p' "$DF")
fi
src_host=$(printf '%s\n' "$base" | sed -E 's|^[a-z]+://([^/:]+).*|\1|')
[ -n "$src_host" ] || { echo "FAIL: no host in '$base'"; exit 1; }
echo "snapshot source: $base (host $src_host)"

build() {  # build <log> <extra args...>; returns docker's exit code
  local log=$1; shift
  docker build --no-cache --progress=plain -f "$DF" "${args[@]}" "$@" -t "$IMG" . >"$log" 2>&1
}
live=(--add-host archive.ubuntu.com:127.0.0.1 --add-host security.ubuntu.com:127.0.0.1)
livere='(Get|Hit):[0-9]+ [a-z]+://(archive|security)\.ubuntu\.com'

echo "== case a: live mirror blocked, snapshot reachable: must build"
if build "$LOGDIR/a.log" "${live[@]}"; then
  gets=$(grep -cE "Get:[0-9]+ [a-z]+://${src_host}[:/]" "$LOGDIR/a.log")
  livegets=$(grep -cE "$livere" "$LOGDIR/a.log")
  echo "   fetches from $src_host: $gets; from the live mirror: $livegets"
  if [ "$gets" -lt 1 ] || [ "$livegets" -ne 0 ]; then
    bad "case a built, but apt did not read only the snapshot source"
  else
    echo "   ok"
    [ -z "${DPKG_OUT:-}" ] || docker run --rm --entrypoint dpkg-query "$IMG" -W >"$DPKG_OUT"
  fi
else
  bad "case a did not build with the live mirror blocked"
  grep -E '(E:|W:|Err:)' "$LOGDIR/a.log" | head -20
  tail -n 20 "$LOGDIR/a.log"
fi

echo "== case b: snapshot source blocked too: must fail clearly, no fallback"
if build "$LOGDIR/b.log" "${live[@]}" --add-host "${src_host}:127.0.0.1"; then
  bad "case b built with the snapshot source unreachable"
else
  err=$(grep -E 'E: (Failed to fetch|Some index files failed)' "$LOGDIR/b.log" | head -3)
  if [ -z "$err" ]; then
    bad "case b failed, but not with apt's fetch error"; tail -n 20 "$LOGDIR/b.log"
  elif [ "$(grep -cE "$livere" "$LOGDIR/b.log")" -ne 0 ]; then
    bad "case b reached the live mirror"
  else
    printf '   apt said: %s\n' "$err"; echo "   ok"
  fi
fi

docker image rm -f "$IMG" >/dev/null 2>&1
[ "$fail" -eq 0 ] || exit 1
echo TEST-APT-SNAPSHOT-COMPLETE
