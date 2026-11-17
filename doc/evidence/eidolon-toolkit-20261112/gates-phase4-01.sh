#!/bin/sh
# Server gates, then client gates; survives a session restart. Writes one done marker.
cd "$(dirname "$0")/../../.."
E=doc/evidence/eidolon-toolkit-20261112
python3 $E/server-gates-phase4-01.py; s=$?
c=skipped; if [ $s -eq 0 ]; then python3 $E/client-gates-phase4-01.py; c=$?; fi
echo "server=$s client=$c" > $E/phase4-01-done.txt
