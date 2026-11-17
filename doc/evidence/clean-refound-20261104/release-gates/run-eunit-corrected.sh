#!/bin/sh
cd /tmp/quod-server-stage2-20261104-zckjvoTs || exit 127
printf 'START eunit-corrected %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> /tmp/quod-stage2-release-gates-20261104/status
rebar3 as test eunit > /tmp/quod-stage2-release-gates-20261104/eunit-corrected.log 2>&1
result=$?
printf 'EXIT eunit-corrected %s %s\n' "$result" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> /tmp/quod-stage2-release-gates-20261104/status
exit "$result"
