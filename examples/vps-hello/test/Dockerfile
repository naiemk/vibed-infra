# Optional image for environments that run docker-in-docker (not used in CI).
# CI and devcontainer DooD run test/run.sh on the host via test-dist.sh.
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl wget openssl python3 docker.io docker-compose-v2 \
    && rm -rf /var/lib/apt/lists/*
COPY dist /opt/dist
COPY packager /opt/vibed-infra
COPY run.sh /opt/test/run.sh
RUN chmod +x /opt/test/run.sh
WORKDIR /opt/test
ENTRYPOINT ["/opt/test/run.sh"]
