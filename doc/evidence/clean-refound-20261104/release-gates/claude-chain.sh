#!/usr/bin/env bash
G=/tmp/quod-stage2-release-gates-20261104
cd /tmp/quod-stage2-final-source-20261104-rcpkvrbd || exit 99
bash $G/run_gate.sh eunit6 rebar3 eunit && bash $G/run_gate.sh ct6 rebar3 ct && bash $G/run_gate.sh xref6 rebar3 xref && bash $G/run_gate.sh dialyzer6 rebar3 dialyzer
printf 'CHAIN-END %s %s\n' "$?" "$(date -u +%FT%TZ)" >> $G/status
