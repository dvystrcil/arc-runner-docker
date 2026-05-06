FROM ghcr.io/actions/actions-runner:latest

USER 0

# Disable installation of recommended and suggested packages to reduce image size
RUN cat > /etc/apt/apt.conf.d/99norecommends <<EOF
APT::Install-Recommends "false";
APT::Install-Suggests "false";
APT::Get::Install-Recommends "false";
APT::Get::Install-Suggests "false";
Apt::AutoRemove::SuggestsImportant "false";
EOF

RUN add-apt-repository -y ppa:git-core/ppa \
    # && mkdir -p -m 755 /etc/apt/keyrings && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
    # && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    # && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    # && cat /etc/apt/sources.list.d/github-cli.list \
    && apt-get update -y \
    && apt-get upgrade -y \
    && apt-get install -y gh

# Add Harbor internal CA to system trust store
COPY harbor-internal-ca.crt /usr/local/share/ca-certificates/harbor-internal-ca.crt
RUN sudo update-ca-certificates

# install yq
RUN export YQ_BINARY=yq_linux_amd64 \
    && wget -q https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${YQ_BINARY} -O /usr/local/bin/yq \
    && chmod +x /usr/local/bin/yq

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
