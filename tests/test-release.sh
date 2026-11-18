#!/usr/bin/env bash
# scripts/release-lib.sh (arc-runner-docker#58): the image tag, the release tag
# and the release body. Offline: fixtures only, no docker, no network.
#
# Why each case exists:
#  - Tags are <actions/runner version>-<run_number> so Renovate in
#    argocd-projects (regex versioning, build group = run number) sees a
#    same-runner rebuild as a patch it may automerge and a runner minor/major
#    as an update that waits for review. A malformed version must FAIL the
#    build, never produce a tag Renovate silently cannot parse.
#  - Runner.Listener --version prints its whole log to stdout
#    (ACTIONS_RUNNER_PRINT_LOG_TO_STDOUT=1 in the upstream image), so the
#    version is "the one line that is exactly x.y.z", and zero or two such
#    lines is an error, not a guess.
#  - The previous release can be old-style (v2026.11.17.80 -> image :80) or
#    new-style (v2.338.2-81 -> image :2.338.2-81); the diff needs its image.
#  - The body must say WHY the build ran and WHAT changed, or say explicitly
#    that nothing did (AC1, AC2).
#
#   tests/test-release.sh
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
ok()  { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
# expect NAME EXPECTED ACTUAL
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi; }
# refuses NAME CMD...: the command must exit non-zero
refuses() { local n=$1; shift; if ( "$@" ) >/dev/null 2>&1; then bad "$n: accepted"; else ok "$n"; fi; }
# has NAME NEEDLE HAYSTACK
has() { if grep -qF -- "$2" <<<"$3"; then ok "$1"; else bad "$1: missing [$2]"; printf '%s\n' "$3" | sed 's/^/    | /'; fi; }
hasnt() { if grep -qF -- "$2" <<<"$3"; then bad "$1: unexpected [$2]"; else ok "$1"; fi; }

[ -f scripts/release-lib.sh ] || { echo "FAIL: scripts/release-lib.sh missing"; exit 1; }
# shellcheck source=../scripts/release-lib.sh
. scripts/release-lib.sh

# --- runner version from Runner.Listener --version output -------------------
listener_out='[RUNNER 2026-11-18 03:35:50Z INFO HostContext] Well known directory '"'"'Bin'"'"': '"'"'/home/runner/bin'"'"'
[RUNNER 2026-11-18 03:35:50Z INFO Listener] Version: 2.338.2
[RUNNER 2026-11-18 03:35:45Z INFO Terminal] WRITE LINE: 2.338.2
2.338.2
[RUNNER 2026-11-18 03:35:45Z INFO Listener] Runner execution has finished with return code 0'
expect "version: the one bare x.y.z line among log lines" 2.338.2 "$(runner_version <<<"$listener_out")"
refuses "version: no bare version line" runner_version <<<'[RUNNER ...] Version: 2.338.2'
refuses "version: two bare version lines" runner_version <<<$'2.338.2\n2.339.0'
refuses "version: empty output" runner_version </dev/null

# --- image tag ------------------------------------------------------------
expect "tag: runner version + run number" 2.338.2-81 "$(image_tag 2.338.2 81)"
refuses "tag: non-semver runner version" image_tag 2.338 81
refuses "tag: empty runner version" image_tag "" 81
refuses "tag: non-numeric run number" image_tag 2.338.2 abc
# The release tag is what argocd-projects' Renovate reads (extractVersionTemplate).
expect "release tag: v + image tag" v2.338.2-81 "$(release_tag 2.338.2-81)"

# --- previous release tag -> its image tag ----------------------------------
expect "prev: new-style release" 2.338.2-81 "$(prev_image_tag v2.338.2-81)"
expect "prev: old-style dated release" 80 "$(prev_image_tag v2026.11.17.80)"
refuses "prev: unknown release tag shape" prev_image_tag v1.0
refuses "prev: empty" prev_image_tag ""

# --- release body ---------------------------------------------------------
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
printf '%s\n' 'adduser 3.137ubuntu1' 'curl 8.5.0-2ubuntu10.6' 'libgone 1.0' 'zlib1g 1:1.3' > "$d/old"
printf '%s\n' 'adduser 3.137ubuntu1' 'curl 8.5.0-2ubuntu10.7' 'libnew 2.0' 'zlib1g 1:1.3' > "$d/new"
cp "$d/old" "$d/same"

body=$(TRIGGER=watcher REASON='runner: sha256:aaa -> sha256:bbb' \
       PREV_TAG=v2.338.2-80 OLD_RUNNER=2.338.2 NEW_RUNNER=2.338.2 \
       OLD_PKGS="$d/old" NEW_PKGS="$d/new" release_body)
has "body: watcher trigger names the digest move" 'runner: sha256:aaa -> sha256:bbb' "$body"
has "body: compares against the previous release" 'v2.338.2-80' "$body"
has "body: runner unchanged is said" '`actions/runner` 2.338.2 (unchanged)' "$body"
has "body: changed package old -> new" '| curl | 8.5.0-2ubuntu10.6 | 8.5.0-2ubuntu10.7 |' "$body"
has "body: added package" '| libnew | (new) | 2.0 |' "$body"
has "body: removed package" '| libgone | 1.0 | (removed) |' "$body"
hasnt "body: unchanged package not listed" '| adduser |' "$body"
has "body: counts" '1 changed, 1 added, 1 removed' "$body"
hasnt "body: never says Nightly" 'Nightly' "$body"

body=$(TRIGGER=push SHA=0123456789abcdef SUBJECT='feat: bump kubectl (#60)' \
       PREV_TAG=v2026.11.17.80 OLD_RUNNER=2.338.1 NEW_RUNNER=2.338.2 \
       OLD_PKGS="$d/old" NEW_PKGS="$d/same" release_body)
has "body: push names the commit" '0123456 feat: bump kubectl (#60)' "$body"
has "body: runner version change" '`actions/runner` 2.338.1 → 2.338.2' "$body"
has "body: explicit no-package-changes line" 'No package changes.' "$body"

body=$(TRIGGER=schedule PREV_TAG=v2.338.2-80 OLD_RUNNER=2.338.2 NEW_RUNNER=2.338.2 \
       OLD_PKGS="$d/old" NEW_PKGS="$d/same" release_body)
has "body: weekly schedule named" 'Weekly scheduled rebuild' "$body"

body=$(TRIGGER=manual ACTOR=dvystrcil PREV_TAG=v2.338.2-80 OLD_RUNNER=2.338.2 NEW_RUNNER=2.338.2 \
       OLD_PKGS="$d/old" NEW_PKGS="$d/same" release_body)
has "body: manual dispatch names who" 'Manual dispatch by dvystrcil' "$body"

# The previous image can be gone from Harbor (retention): say so, never
# print "No package changes" for a comparison that did not happen.
body=$(TRIGGER=schedule PREV_TAG=v2.338.2-80 OLD_RUNNER= NEW_RUNNER=2.338.2 \
       OLD_PKGS="$d/missing" NEW_PKGS="$d/new" release_body)
has "body: missing previous image is explicit" 'could not be compared' "$body"
hasnt "body: no false no-change claim" 'No package changes.' "$body"
# Runner version read fine but the package listing came back empty.
body=$(TRIGGER=schedule PREV_TAG=v2.338.2-80 OLD_RUNNER=2.338.2 NEW_RUNNER=2.338.2 \
       OLD_PKGS="$d/missing" NEW_PKGS="$d/new" release_body)
has "body: empty previous package list is explicit" 'could not be compared' "$body"

body=$(TRIGGER=schedule PREV_TAG= OLD_RUNNER= NEW_RUNNER=2.338.2 \
       OLD_PKGS= NEW_PKGS="$d/new" release_body)
has "body: first release has nothing to compare" 'No previous release' "$body"

refuses "body: unknown trigger" env TRIGGER=bogus NEW_RUNNER=2.338.2 NEW_PKGS="$d/new" bash -c '. scripts/release-lib.sh; release_body'

[ $fail = 0 ] && echo TEST-RELEASE-COMPLETE
exit $fail
