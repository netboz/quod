#!/bin/sh
# Client gates only, repeated after the pick check waits for the framed camera; survives a session restart.
cd "$(dirname "$0")/../../.."
E=doc/evidence/eidolon-toolkit-20261112
python3 $E/client-gates-phase3-05.py; c=$?
echo "client=$c" > $E/phase3-05-done.txt
