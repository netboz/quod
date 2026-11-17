#!/bin/sh
# Client gates only, repeated after the intermittent gui step; survives a session restart.
cd "$(dirname "$0")/../../.."
E=doc/evidence/eidolon-toolkit-20261112
python3 $E/client-gates-phase3-03.py; c=$?
echo "client=$c" > $E/phase3-03-done.txt
