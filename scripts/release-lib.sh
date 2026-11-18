# Sourced by .github/workflows/build.yaml; tested by tests/test-release.sh.
# arc-runner-docker#58: images and releases carry the actions/runner version,
# and the release says why it was built and what changed.
#
# Tag scheme: <actions/runner version>-<run_number>, e.g. 2.338.2-81.
# argocd-projects' Renovate reads it from the release tag (v2.338.2-81) with
#   regex:^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)-(?<build>\d+)$
# where a build-only change counts as a patch. So a rebuild on the same
# runner (and a runner patch) automerges; a runner minor/major waits for
# review. Anything that would make a tag outside that shape fails here,
# because Renovate does not error on an unparseable version: it goes quiet.

# stdin: Runner.Listener --version output. The upstream image sets
# ACTIONS_RUNNER_PRINT_LOG_TO_STDOUT=1, so the log is on stdout too; the
# version is the one line that is exactly x.y.z. Zero or several: fail.
runner_version() {
  local v n
  v=$(grep -xE '[0-9]+\.[0-9]+\.[0-9]+')
  n=$(printf '%s' "$v" | grep -c . || true)
  if [ "$n" != 1 ]; then
    echo "runner_version: expected exactly one x.y.z line, got $n" >&2
    return 1
  fi
  printf '%s\n' "$v"
}

# image_tag RUNNER_VERSION RUN_NUMBER -> 2.338.2-81
image_tag() {
  [[ ${1:-} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "image_tag: bad runner version [${1:-}]" >&2; return 1; }
  [[ ${2:-} =~ ^[0-9]+$ ]] || { echo "image_tag: bad run number [${2:-}]" >&2; return 1; }
  printf '%s-%s\n' "$1" "$2"
}

release_tag() { printf 'v%s\n' "$1"; }

# prev_image_tag RELEASE_TAG -> the image tag that release pushed.
#   v2.338.2-81     -> 2.338.2-81   (this scheme)
#   v2026.11.17.80  -> 80           (before #58: dated name, bare run number)
prev_image_tag() {
  local t=${1:-}
  if [[ $t =~ ^v([0-9]+\.[0-9]+\.[0-9]+-[0-9]+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  elif [[ $t =~ ^v[0-9]{4}\.[0-9]+\.[0-9]+\.([0-9]+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    echo "prev_image_tag: unrecognised release tag [$t]" >&2
    return 1
  fi
}

# release_body: markdown on stdout. Inputs (env):
#   TRIGGER   push | schedule | watcher | manual
#   SHA SUBJECT   (push)        REASON (watcher)        ACTOR (manual)
#   PREV_TAG      previous release tag, empty on the first release
#   OLD_RUNNER NEW_RUNNER       actions/runner versions (OLD empty if unknown)
#   OLD_PKGS NEW_PKGS           files of "package version" lines (dpkg-query -W)
release_body() {
  echo "## Why this build"
  echo
  case "${TRIGGER:-}" in
    push)     echo "Pushed commit ${SHA:0:7} ${SUBJECT:-}" ;;
    schedule) echo "Weekly scheduled rebuild (picks up \`apt-get upgrade\`)." ;;
    watcher)  echo "Upstream base image moved: ${REASON:-}" ;;
    manual)   echo "Manual dispatch by ${ACTOR:-unknown}." ;;
    *) echo "release_body: unknown TRIGGER [${TRIGGER:-}]" >&2; return 1 ;;
  esac
  echo
  if [ -z "${PREV_TAG:-}" ]; then
    echo "## What changed"
    echo
    echo "No previous release to compare against. \`actions/runner\` ${NEW_RUNNER}."
    return 0
  fi
  echo "## What changed since ${PREV_TAG}"
  echo
  if [ -z "${OLD_RUNNER:-}" ] || [ ! -s "${OLD_PKGS:-/nonexistent}" ]; then
    echo "\`actions/runner\` ${NEW_RUNNER}. The previous image could not be compared (not pullable from Harbor), so there is no package diff for this release."
    return 0
  fi
  if [ "$OLD_RUNNER" = "$NEW_RUNNER" ]; then
    echo "- \`actions/runner\` ${NEW_RUNNER} (unchanged)"
  else
    echo "- \`actions/runner\` ${OLD_RUNNER} → ${NEW_RUNNER}"
  fi
  local rows
  rows=$(awk '
    FNR == NR { old[$1] = $2; next }
    { new[$1] = $2 }
    END {
      for (p in old) if (!(p in new))      printf "%s\t| %s | %s | (removed) |\n", p, p, old[p]
      for (p in new) if (!(p in old))      printf "%s\t| %s | (new) | %s |\n",     p, p, new[p]
                     else if (old[p] != new[p]) printf "%s\t| %s | %s | %s |\n",   p, p, old[p], new[p]
    }' "$OLD_PKGS" "$NEW_PKGS" | sort | cut -f2-)
  if [ -z "$rows" ]; then
    echo "- No package changes."
    return 0
  fi
  local changed added removed
  added=$(grep -c '| (new) |' <<<"$rows" || true)
  removed=$(grep -c '| (removed) |$' <<<"$rows" || true)
  changed=$(( $(grep -c . <<<"$rows") - added - removed ))
  echo "- Packages: ${changed} changed, ${added} added, ${removed} removed"
  echo
  echo "<details><summary>Package diff (dpkg)</summary>"
  echo
  echo "| package | before | after |"
  echo "|---|---|---|"
  printf '%s\n' "$rows"
  echo
  echo "</details>"
}
