# kubectl comes from the official image via the registry path — plain
# HTTP downloads from dl.k8s.io hung deterministically inside the dind
# buildkit network (homelab#462; two identical ~5min timeouts), while
# registry pulls work fine. ROOT CAUSE since fixed: dind bridge MTU
# 1500 > flannel 1450 (argocd-projects#75; dockerd now runs --mtu=1450,
# build.yaml carries a network canary). The registry COPY stays as
# defense in depth — it's also just the more robust pattern.
FROM registry.k8s.io/kubectl:v1.37.2 AS kubectl

# Pre-populated RUNNER_TOOL_CACHE (homelab#1812 AC2, D-027): setup-go/
# setup-python/setup-node find these instead of downloading at job time,
# which is what failed or stalled CI on degraded-egress days. Laid out as
# @actions/tool-cache's find() expects: <tool>/<ver>/x64 + x64.complete.
# Baked, NOT an image volume: the cache must stay writable, or a version
# miss, `pip install` and kubeconform -cache all break (lab/runner-tool-cache
# in dvystrcil/homelab).
#
# Patch-only Renovate bumps (renovate.json): the fleet asks for '3.x'/'3.14',
# '24', '1.27'; a new minor (go 1.28, python 3.15) would stop serving them,
# so moving the line is a deliberate edit here. Exact pins elsewhere (immich's
# go 1.27.1) still download -- a miss is slow, not broken.
#
# Built FROM the runner image itself, not a separate ubuntu tag: the Python
# build below targets the runner's OS release and runs (pip upgrade) during
# the build, so the stage must be the OS the final image is. A separate
# `ubuntu:NN.04` drifts on its own -- Renovate proposed 24.04 -> 26.04 for it
# (#37) while the runner stayed on 24.04. Same base, same OS, by construction.
FROM ghcr.io/actions/actions-runner:latest AS toolcache
USER root
# renovate: datasource=golang-version depName=go
ARG GO_VERSION=1.27.3
# renovate: datasource=python-version depName=python
ARG PYTHON_VERSION=3.14.10
# renovate: datasource=node-version depName=node
ARG NODE_VERSION=24.22.1
ENV RUNNER_TOOL_CACHE=/opt/hostedtoolcache
RUN apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends curl ca-certificates jq >/dev/null
# Go and Node from their official tarballs (setup-go/-node's own fallback
# source; same content as actions/*-versions), checksum-verified.
RUN set -eux; tc=$RUNNER_TOOL_CACHE; \
    mkdir -p $tc/go/$GO_VERSION/x64 $tc/node/$NODE_VERSION/x64; \
    curl -fsSLo /tmp/go.tgz https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz; \
    sha=$(curl -fsSL 'https://go.dev/dl/?mode=json&include=all' | jq -r --arg f "go${GO_VERSION}.linux-amd64.tar.gz" \
          '.[].files[] | select(.filename == $f) | .sha256'); \
    echo "$sha  /tmp/go.tgz" | sha256sum -c; \
    tar -xzf /tmp/go.tgz --strip-components=1 -C $tc/go/$GO_VERSION/x64; \
    touch $tc/go/$GO_VERSION/x64.complete; \
    n=node-v${NODE_VERSION}-linux-x64.tar.gz; \
    curl -fsSLo /tmp/$n https://nodejs.org/dist/v${NODE_VERSION}/$n; \
    curl -fsSL https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt | grep " $n\$" | (cd /tmp && sha256sum -c); \
    tar -xzf /tmp/$n --strip-components=1 -C $tc/node/$NODE_VERSION/x64; \
    touch $tc/node/$NODE_VERSION/x64.complete; \
    rm -f /tmp/go.tgz /tmp/$n
# Python MUST be the actions/python-versions build: it is compiled for
# $RUNNER_TOOL_CACHE/Python/<ver>/x64. The URL carries a build-run id, so it is
# resolved from the same manifest setup-python reads. A Renovate bump to a
# release actions has not built yet fails HERE, loudly, at build time.
# The build for THIS stage's OS release (= the runner's), read from os-release.
RUN set -eux; . /etc/os-release; \
    url=$(curl -fsSL https://raw.githubusercontent.com/actions/python-versions/main/versions-manifest.json \
          | jq -r --arg v "$PYTHON_VERSION" --arg os "$VERSION_ID" '.[] | select(.version == $v) | .files[] | select(.platform == "linux" and .platform_version == $os and .arch == "x64") | .download_url'); \
    test -n "$url"; \
    mkdir /tmp/py && curl -fsSL "$url" | tar -xz -C /tmp/py; \
    cd /tmp/py && bash ./setup.sh >/dev/null; \
    test -f $RUNNER_TOOL_CACHE/Python/$PYTHON_VERSION/x64.complete; \
    rm -rf /tmp/py
# Strip what no CI job loads (807 -> 549 MB in the lab): CPython's own test
# suite and static libs (embedding only); Go's compiler tests and stdlib
# testdata (`go build` compiles src/ without them). NOT node's include/:
# node-gyp needs it, and would otherwise fetch headers from the internet.
RUN set -eux; tc=$RUNNER_TOOL_CACHE; \
    rm -rf $tc/Python/*/x64/lib/python3.*/test; \
    find $tc/Python -name '*.a' -delete; \
    rm -rf $tc/go/*/x64/test; \
    find $tc/go/*/x64/src -type d -name testdata -prune -exec rm -rf {} +

# helm + kubeconform on PATH: helm-validate-action and kustomize-validate-
# action already skip their runtime downloads behind `command -v` (immich#52
# failed on exactly that download, 2026-10-27). helm stays on 3: the action
# installs 3 via get-helm-3, so this changes nothing but where it comes from.
# Runner base here too: one OS for every stage, nothing for Renovate to split.
FROM ghcr.io/actions/actions-runner:latest AS bins
USER root
# renovate: datasource=github-releases depName=helm/helm
ARG HELM_VERSION=v3.22.1
# renovate: datasource=github-releases depName=yannh/kubeconform
ARG KUBECONFORM_VERSION=v0.7.0
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends curl ca-certificates >/dev/null
RUN set -eux; cd /tmp; \
    curl -fsSLO https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz; \
    curl -fsSL https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum | sha256sum -c; \
    tar -xzf helm-${HELM_VERSION}-linux-amd64.tar.gz --strip-components=1 -C /usr/local/bin linux-amd64/helm; \
    curl -fsSLO https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/kubeconform-linux-amd64.tar.gz; \
    curl -fsSL https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/CHECKSUMS \
      | grep ' kubeconform-linux-amd64.tar.gz$' | sha256sum -c; \
    tar -xzf kubeconform-linux-amd64.tar.gz -C /usr/local/bin kubeconform

FROM ghcr.io/actions/actions-runner:latest
# Every *_VERSION ARG carries a `# renovate:` line, which renovate.json's
# custom manager reads; tests/test-renovate-annotations.sh fails a PR that
# adds one without it. An unannotated ARG is a pin nothing ever revisits.
# renovate: datasource=github-releases depName=mikefarah/yq
ARG YQ_VERSION=v4.54.1
# renovate: datasource=github-releases depName=docker/compose
ARG DOCKER_COMPOSE_VERSION=v5.6.1

USER root

# Disable installation of recommended and suggested packages to reduce image size
RUN cat > /etc/apt/apt.conf.d/99norecommends <<EOF
APT::Install-Recommends "false";
APT::Install-Suggests "false";
APT::Get::Install-Recommends "false";
APT::Get::Install-Suggests "false";
Apt::AutoRemove::SuggestsImportant "false";
EOF

# python3-venv + python3-pip (2026-09-26): jobs moving off GitHub-hosted
# runners to save Actions minutes (1,801/2,000 used) need them --
# dvystrcil/yaml-validate-action builds a venv for yamllint, and several repos'
# checks pip-install into one. A pod probe showed this image had neither.
RUN add-apt-repository -y ppa:git-core/ppa \
    && mkdir -p -m 755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update -y \
    && apt-get upgrade -y \
    && apt-get install -y wget gh python3-socketio python3-websocket python3-yaml python3-ruamel.yaml postgresql-client python3-venv python3-pip

# Initialize Flatpak
# ENV TMPDIR=/tmp
# RUN flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
# RUN flatpak remote-add --if-not-exists flathub-beta https://flathub.org/beta-repo/flathub-beta.flatpakrepo
# RUN flatpak remote-add --if-not-exists gnome-nightly https://nightly.gnome.org/gnome-nightly.flatpakrepo

# RUN cd /var/lib/flatpak \
#     && mkdir -p repo/objects repo/tmp
    
# RUN tee repo/config <<EOF
# [core]
# repo_version=1
# mode=bare-user-only
# min-free-space-size=500MB
# EOF

# Add Harbor internal CA to system trust store
COPY harbor-internal-ca.crt /usr/local/share/ca-certificates/harbor-internal-ca.crt
RUN update-ca-certificates

# install yq
RUN export YQ_BINARY=yq_linux_amd64 \
    && wget -q https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${YQ_BINARY} -O /usr/local/bin/yq \
    && chmod +x /usr/local/bin/yq

# install kubectl — pinned to the cluster minor (homelab#462); CI audits
# use the runner pod's in-cluster ServiceAccount (RBAC: arc-runners repo,
# read-only, no secrets)
COPY --from=kubectl /bin/kubectl /usr/local/bin/kubectl

ENV RUNNER_TOOL_CACHE=/opt/hostedtoolcache
RUN mkdir /opt/hostedtoolcache \
    && chgrp runner /opt/hostedtoolcache \
    && chmod g+rwx /opt/hostedtoolcache
# Owned by runner so a cache MISS can still download and add a version.
COPY --from=toolcache --chown=runner:runner /opt/hostedtoolcache/ /opt/hostedtoolcache/
COPY --from=bins /usr/local/bin/helm /usr/local/bin/kubeconform /usr/local/bin/

# Installing docker-compose
RUN curl -fLo /usr/local/lib/docker/cli-plugins/docker-compose https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-Linux-x86_64 \
    && chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# clean up and lock down
RUN apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/* \
    && rm -rf /etc/ssh/ssh_host_*

USER runner
