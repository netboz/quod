#!/bin/sh
# Start the isolated rehearsal founder: no network, its own empty data directory.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
DATA=$HOME/.cache/quod-interior-eidolon-release/rehearsal-data
IMAGE=${1:?image}
test ! -e "$DATA"
mkdir -p -m 700 "$DATA"
openssl rand -out "$DATA/agent-vault.unlock" 32
chmod 600 "$DATA/agent-vault.unlock"
docker run -d --name quod-refound-rehearsal --network none \
  -v "$DATA:/quod/data" -v "$HERE/quod.conf:/conf/quod.conf:ro" -e QUOD_CONF=/conf/quod.conf \
  "$IMAGE" foreground
echo quod-refound-rehearsal > "$HERE/container"
