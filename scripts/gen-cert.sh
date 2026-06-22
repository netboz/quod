#!/usr/bin/env bash
# Generate a self-signed cert for the QUIC listener (dev only).
# QUIC mandates TLS 1.3, so the listener needs a certfile + keyfile.
# For real deployments, use per-node identity keys (raw public keys / a CA).
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)/priv/certs"
mkdir -p "$DIR"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$DIR/key.pem" -out "$DIR/cert.pem" \
  -days 3650 -subj "/CN=quod-node"
echo "wrote $DIR/cert.pem and $DIR/key.pem"
