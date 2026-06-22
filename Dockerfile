# syntax=docker/dockerfile:1
#
# quod node — pure-Erlang QUIC (the `quic` library, no NIF, no msquic).
# Small image, fast build (no C toolchain, no from-source TLS/QUIC compile).
#
# Build:  docker build -t quod:0.1.0 .
# Run:    docker run --rm -p 14567:14567/udp quod:0.1.0

# ---- builder ---------------------------------------------------------------
FROM erlang:28 AS builder

# git only: the erlog dep is a git ref. (quic/gproc are pure Erlang hex deps.)
RUN apt-get update && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Dependency layer — cached until rebar.{config,lock} change. A throwaway app
# stub lets rebar3 fetch + compile deps without our source.
COPY rebar.config rebar.lock ./
RUN mkdir -p src \
    && printf '{application, quod, [{vsn,"0.0.0"},{registered,[]},{applications,[kernel,stdlib]}]}.\n' \
         > src/quod.app.src \
    && rebar3 as prod compile \
    && rm -rf src _build/prod/lib/quod

# App + release (bundled ERTS, no Erlang needed at runtime).
COPY config/ config/
COPY priv/   priv/
COPY src/    src/
RUN rebar3 as prod release

# ---- runtime ---------------------------------------------------------------
# Match the builder's Debian (erlang:28 is trixie) so ERTS finds the same glibc.
FROM debian:trixie-slim AS runtime

# libssl3: the OTP crypto NIF links libcrypto (quic does TLS 1.3 in Erlang on top
# of it). libncurses6/libstdc++6: erl run scripts + ERTS. No msquic libs.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libncurses6 libstdc++6 libssl3 ca-certificates openssl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/quod
COPY --from=builder /build/_build/prod/rel/quod ./

# Self-signed cert for the QUIC listener (peers dial with verify=false). Absolute
# path in the baked config so it is found regardless of the start script's cwd.
RUN mkdir -p /opt/quod/certs \
    && openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=quod \
         -keyout /opt/quod/certs/key.pem -out /opt/quod/certs/cert.pem \
    && sed -i 's#"priv/certs/cert.pem"#"/opt/quod/certs/cert.pem"#; \
              s#"priv/certs/key.pem"#"/opt/quod/certs/key.pem"#' \
         /opt/quod/releases/0.1.0/sys.config

EXPOSE 14567/udp

ENTRYPOINT ["/opt/quod/bin/quod"]
CMD ["foreground"]
