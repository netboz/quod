# syntax=docker/dockerfile:1
#
# Multi-stage build for a quod node.
#
#   builder  — builds the heavy quicer/msquic + OpenSSL NIF ONCE in a layer keyed
#              only on rebar.config/rebar.lock, then assembles a prod release with
#              a bundled ERTS. Editing quod source reuses the cached NIF layer.
#   runtime  — slim Debian with just the shared libs the NIF needs; no Erlang or
#              toolchain (ERTS is inside the release).
#
# Build:  docker build -t quod:0.1.0 .
# Run:    docker run --rm -p 14567:14567/udp quod:0.1.0

# ---- builder ---------------------------------------------------------------
FROM erlang:28 AS builder

# msquic + OpenSSL are compiled from source by the quicer dep's build hooks.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake perl git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# 1) Dependency layer — cached until rebar.{config,lock} change. A throwaway
#    app stub lets rebar3 fetch AND compile deps (this is the multi-minute msquic
#    NIF build) without our source, so quod code edits never rebuild the NIF.
COPY rebar.config rebar.lock ./
RUN mkdir -p src \
    && printf '{application, quod, [{vsn,"0.0.0"},{registered,[]},{applications,[kernel,stdlib]}]}.\n' \
         > src/quod.app.src \
    && rebar3 as prod compile \
    && rm -rf src _build/prod/lib/quod

# 2) App + release — the only layer that reruns on a source change; the built
#    deps (incl. the NIF) above are reused untouched.
COPY config/ config/
COPY priv/   priv/
COPY src/    src/
RUN rebar3 as prod release

# ---- runtime ---------------------------------------------------------------
# Must match the builder's Debian release (erlang:28 is Debian 13 "trixie") so
# the bundled ERTS + NIF find the same glibc.
FROM debian:trixie-slim AS runtime

# Shared libs the quicer/msquic NIF and the erl scripts load at runtime.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libstdc++6 libssl3 libncurses6 ca-certificates openssl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/quod
COPY --from=builder /build/_build/prod/rel/quod ./

# Self-signed cert for the QUIC listener (TLS 1.3 is mandatory; peers dial with
# verify=none). Point the release's baked config at an absolute path so it is
# found regardless of the start script's cwd.
RUN mkdir -p /opt/quod/certs \
    && openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=quod \
         -keyout /opt/quod/certs/key.pem -out /opt/quod/certs/cert.pem \
    && sed -i 's#"priv/certs/cert.pem"#"/opt/quod/certs/cert.pem"#; \
              s#"priv/certs/key.pem"#"/opt/quod/certs/key.pem"#' \
         /opt/quod/releases/0.1.0/sys.config

# QUIC is UDP.
EXPOSE 14567/udp

ENTRYPOINT ["/opt/quod/bin/quod"]
CMD ["foreground"]
