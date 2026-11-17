#!/bin/sh
# Client gates only, repeated after the overlapping-marker check fix; survives a session restart.
cd "$(dirname "$0")/../../.."
E=doc/evidence/eidolon-toolkit-20261112
python3 $E/client-gates-phase3-04.py; c=$?
echo "client=$c" > $E/phase3-04-done.txt
