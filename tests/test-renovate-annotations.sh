#!/usr/bin/env bash
# Every `ARG <NAME>_VERSION=` in a Dockerfile* must sit directly under a
# `# renovate: datasource=<ds> depName=<dep>` line (homelab#1812 AC3).
# renovate.json's custom manager reads that pair; an ARG without it is a pin
# Renovate never sees, and a regex that stops matching makes Renovate silent,
# not red. So this enumerates EVERY *_VERSION ARG (not just annotated ones)
# and checks the exact shape the manager's regex expects.
#
#   tests/test-renovate-annotations.sh [dir]     # default: repo root
#
# Self-check: `--self-test` runs it against generated good and bad fixtures.
set -uo pipefail

check() {  # check <dir>: prints problems, returns 1 if any, 2 if no ARGs found
  local dir=$1 found=0 bad=0
  while IFS= read -r f; do
    awk -v f="$f" '
      /^ARG[ \t]+[A-Z0-9_]+_VERSION=/ {
        n++
        if (prev !~ /^#[ \t]*renovate:[ \t]*datasource=[^ \t]+[ \t]+depName=[^ \t]+[ \t]*$/) {
          printf "%s:%d: %s has no `# renovate: datasource=... depName=...` line directly above\n", f, NR, $2
          b++
        }
      }
      { prev = $0 }
      END { printf "COUNT %d %d\n", n, b }' "$f"
  done < <(find "$dir" -maxdepth 2 -name 'Dockerfile*' -type f -not -path '*/.git/*' | sort) \
  | { while read -r a b c rest; do
        if [ "$a" = COUNT ]; then found=$((found + b)); bad=$((bad + c)); else echo "$a $b $c $rest"; fi
      done
      echo "checked $found *_VERSION ARG(s), $bad unannotated"
      [ "$found" -gt 0 ] || exit 2
      [ "$bad" -eq 0 ]; }
}

if [ "${1:-}" = "--self-test" ]; then
  t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
  mkdir -p "$t/good" "$t/bad" "$t/none"
  printf '# renovate: datasource=github-releases depName=a/b\nARG X_VERSION=1\n' > "$t/good/Dockerfile"
  printf '# renovate: datasource=github-releases depName=a/b\nARG X_VERSION=1\nARG Y_VERSION=2\n' > "$t/bad/Dockerfile"
  printf 'FROM scratch\n' > "$t/none/Dockerfile"
  fail=0
  check "$t/good" >/dev/null; [ $? -eq 0 ] || { echo "FAIL: annotated ARG rejected"; fail=1; }
  check "$t/bad"  >/dev/null; [ $? -eq 1 ] || { echo "FAIL: unannotated Y_VERSION accepted"; fail=1; }
  check "$t/none" >/dev/null; [ $? -eq 2 ] || { echo "FAIL: zero ARGs read as a pass"; fail=1; }
  [ $fail -eq 0 ] && echo "self-test OK"; exit $fail
fi

check "${1:-$(cd "$(dirname "$0")/.." && pwd)}"
