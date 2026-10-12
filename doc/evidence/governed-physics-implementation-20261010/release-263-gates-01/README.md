# Release 263 clean gate 01: stopped

The six native/client/UI gates passed, including 27 native tests in debug and
release. EUnit stopped with child exit 1 after the sandbox denied the vault
test's loopback listener with eperm. It reports 45 tests, zero assertion failures
and six cancellations. This is not an EUnit pass; later gates did not run.

The [triage](triage.md) identifies the execution-permission error. Campaign 02
uses a new clean tree with exactly the same 684 input hashes and required local
network access. No source, deadline or assertion changed for this failure.
Full logs, the stop receipt, frozen source and runners are retained here.
