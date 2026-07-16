# kubectl comes from the official image via the registry path — plain
# HTTP downloads from dl.k8s.io hung deterministically inside the dind
# buildkit network (homelab#462; two identical ~5min timeouts), while
# registry pulls work fine. ROOT CAUSE since fixed: dind bridge MTU
# 1500 > flannel 1450 (argocd-projects#75; dockerd now runs --mtu=1450,
# build.yaml carries a network canary). The registry COPY stays as
# defense in depth — it's also just the more robust pattern.
FROM registry.k8s.io/kubectl:v1.34.6 AS kubectl

FROM ghcr.io/actions/actions-runner:latest
ARG YQ_VERSION=v4.52.4
ARG DOCKER_COMPOSE_VERSION=v5.1.0
ARG CONTAINERD_VERSION=2.2.1

USER root

# Disable installation of recommended and suggested packages to reduce image size
RUN cat > /etc/apt/apt.conf.d/99norecommends <<EOF
APT::Install-Recommends "false";
APT::Install-Suggests "false";
APT::Get::Install-Recommends "false";
APT::Get::Install-Suggests "false";
Apt::AutoRemove::SuggestsImportant "false";
EOF

RUN add-apt-repository -y ppa:git-core/ppa \
    && mkdir -p -m 755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update -y \
    && apt-get upgrade -y \
    && apt-get install -y wget gh python3-socketio python3-websocket python3-yaml postgresql-client

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

# Installing docker-compose
RUN curl -fLo /usr/local/lib/docker/cli-plugins/docker-compose https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-Linux-x86_64 \
    && chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# clean up and lock down
RUN apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/* \
    && rm -rf /etc/ssh/ssh_host_*

USER runner
