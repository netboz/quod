"""Harmless argv recipient; never imports a physical or application owner."""
import sys
assert sys.argv[1:]==['morning-launch-argv01','--client-manifest','fixture-manifest','--require-wands']
print('LAUNCH_ARGV_CHILD_PASS',flush=True)
