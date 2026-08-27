#!/usr/bin/env bash
# One signed benchmark driver for both target-local and remote (`::`) goals.
# The implementation imports the browser client's request/authentication code;
# this wrapper deliberately adds no alternate protocol.
exec node "$(dirname "$0")/signed-goal-loadtest.mjs" "$@"
