#!/bin/sh
# Client gates only, repeated after the stale-check fix; survives a session restart.
cd "$(dirname "$0")/../../.."
E=doc/evidence/eidolon-toolkit-20261112
python3 $E/client-gates-phase3-02.py; c=$?
echo "client=$c" > $E/phase3-02-done.txt
