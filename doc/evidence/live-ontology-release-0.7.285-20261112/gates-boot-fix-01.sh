#!/bin/sh
# Server gates for the node-enrolment boot fix; survives a session restart.
cd "$(dirname "$0")/../../.."
E=doc/evidence/live-ontology-release-0.7.285-20261112
python3 $E/server-gates-boot-fix-01.py; s=$?
echo "server=$s" > $E/boot-fix-01-done.txt
