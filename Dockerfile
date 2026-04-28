FROM ghcr.io/actions/actions-runner:latest

# Add Harbor internal CA to system trust store
COPY harbor-internal-ca.crt /usr/local/share/ca-certificates/harbor-internal-ca.crt
RUN sudo update-ca-certificates
