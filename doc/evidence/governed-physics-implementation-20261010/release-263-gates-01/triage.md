# Stopped gate: local network permission

Native debug/release, Clippy, client tests, UI build and lint passed.
EUnit stopped with exit 1: Ranch could not bind the vault test listener on
127.0.0.1 port 0, reporting eperm. The test run was mistakenly launched inside
the filesystem/network sandbox. It reports 45 tests, zero assertion failures
and six cancellations before aborting. This is not a completed EUnit pass.

The original log and STOP receipt remain unchanged. Campaign 02 uses the same
source hashes, a fresh clean tree and the existing required local-network
permission. No production code, deadline or assertion is changed for this failure.
