#!/bin/sh
# Trace only OS entropy calls; raw formatting never prints entropy buffer bytes.
exec /usr/bin/strace -f -e trace=getrandom -e raw=getrandom -o "$M1B_RUNTIME_TRACE" "$M1B_REAL_EXPORT" "$@"
