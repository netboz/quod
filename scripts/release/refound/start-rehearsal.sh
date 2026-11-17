#!/bin/sh
# start-rehearsal.sh <work-dir> <label> <image>
# Start the isolated rehearsal founder: no network, its own empty data directory.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${1:?work dir, for example doc/evidence/<release>/refound}
LABEL=${2:?label, for example matrix-20261117}
IMAGE=${3:?image}
DATA=$HOME/.cache/quod-refound-$LABEL/rehearsal-data
mkdir -p "$WORK/rehearsal"
test ! -e "$DATA"
mkdir -p -m 700 "$DATA"
openssl rand -out "$DATA/agent-vault.unlock" 32
chmod 600 "$DATA/agent-vault.unlock"
docker run -d --name "quod-rehearsal-$LABEL" --network none \
  -v "$DATA:/quod/data" -v "$HERE/rehearsal-quod.conf:/conf/quod.conf:ro" -e QUOD_CONF=/conf/quod.conf \
  "$IMAGE" foreground
echo "quod-rehearsal-$LABEL" > "$WORK/rehearsal/container"
