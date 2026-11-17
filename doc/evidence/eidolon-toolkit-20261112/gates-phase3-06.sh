#!/bin/sh
# Client gates only, repeated after the click helper waits for the scrolled control; survives a session restart.
cd "$(dirname "$0")/../../.."
E=doc/evidence/eidolon-toolkit-20261112
python3 $E/client-gates-phase3-06.py; c=$?
echo "client=$c" > $E/phase3-06-done.txt
