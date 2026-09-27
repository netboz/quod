# CI image for the Forgejo runner (deploy/forgejo-runner.nomad): the release builder's
# Erlang (erlang:28 = OTP 28 + rebar3, the same base as the runtime ../../Dockerfile),
# plus node for the JavaScript actions (checkout, cache) and the Docker CLI for the
# master release-image job, which talks to the host daemon through the mounted socket,
# and the Claude Code CLI for the pull-request review workflow (claude-review.yml).
#
# Build and push, from the repo root:
#   docker build -t 192.168.1.11:5000/quod-ci:28 deploy/ci && docker push 192.168.1.11:5000/quod-ci:28
# Rebuild when ../../Dockerfile moves to a new erlang base, and re-tag accordingly.
FROM erlang:28

ARG DOCKER_VERSION=29.0.0
ARG CLAUDE_CODE_VERSION=2.1.283

RUN apt-get update \
    && apt-get install -y --no-install-recommends nodejs npm ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL "https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_VERSION}.tgz" \
       | tar -xz -C /usr/local/bin --strip-components=1 docker/docker \
    && npm install -g --no-fund --no-audit "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
    && npm cache clean --force \
    && node --version && docker --version && claude --version && rebar3 version
