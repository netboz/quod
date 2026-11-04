#!/usr/bin/env bash
set -u
gate="$1"
shift
base=/tmp/quod-stage2-release-gates-20261104
printf 'START %s %s\n' "$gate" "$(date -u +%FT%TZ)" >> "$base/status"
"$@" > "$base/final-$gate.log" 2>&1
result=$?
printf 'EXIT %s %s %s\n' "$gate" "$result" "$(date -u +%FT%TZ)" >> "$base/status"
printf 'gate=%s exit=%s log=%s\n' "$gate" "$result" "$base/final-$gate.log"
exit "$result"
