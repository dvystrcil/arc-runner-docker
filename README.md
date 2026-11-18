# arc-runner-image

Custom GitHub Actions Runner image with Harbor internal CA cert baked in.

Built and pushed to `harbor.sirddail.net/arc/actions-runner:latest`.

Each build also pushes a fixed tag, `<actions/runner version>-<run number>`
(for example `2.338.2-81`), on all three images (`actions-runner`, `dind`,
`orcaslicer-runner`), and creates a release `v2.338.2-81` whose body says why
the build ran and what changed: the runner version and a package diff against
the previous release. argocd-projects pins the runners to that tag, and its
Renovate reads it from the release (#58): a rebuild on the same runner, or a
runner patch, automerges; a runner minor or major waits for review.
`scripts/release-lib.sh` builds the tag and the body; `tests/test-release.sh`
tests them.

## License

[MIT](LICENSE)
