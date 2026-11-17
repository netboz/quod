#!/usr/bin/env bash
# Sequential release gates on the committed tree; each records START/EXIT with its true exit code.
G=/home/yan/src/quod_worktrees/pearl-stone/_build/refound-281/gates
cd /home/yan/src/quod_worktrees/pearl-stone || exit 99
git rev-parse HEAD > $G/source-head; git status --short | grep -v '^??' > $G/source-dirty
gate() { name=$1; shift; printf 'START %s %s\n' $name "$(date -u +%FT%TZ)" >> $G/status
  "$@" > $G/$name.log 2>&1; code=$?; printf 'EXIT %s %s %s\n' $name $code "$(date -u +%FT%TZ)" >> $G/status; return $code; }
gate eunit rebar3 eunit; gate ct rebar3 ct; gate xref rebar3 xref; gate dialyzer rebar3 dialyzer
printf 'CHAIN-END %s\n' "$(date -u +%FT%TZ)" >> $G/status
