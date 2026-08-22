#!/usr/bin/env bash
# Documented launcher for the signed client cross-ontology workload driver.
set -euo pipefail
exec node "$(dirname "$0")/cross-ontology-loadtest.mjs" "$@"
