# Release-gate timeout triage

The first full sequence stopped at EUnit, exit 1: 4,039 passed, zero assertion
failures, but cancellation after the five-second default timeout in
`complete_edit_groups_predicates_and_preserves_unchanged_contents_test/0`.
The stack is in `erlog_int:dderef/2`. No CT/xref/Dialyzer/release gate followed
that failure. Its complete log, STOP marker and receipts remain in gates-01.

Comparison with the previous passing release input manifest shows only the
17 intended build-input changes for unrestricted viewing. The failed test,
`quod_prolog.pl`, editor/compiler and Erlog implementation are unchanged. The
test constructs a local editor and target containing `choice/1` and
`unselected/1`; its call path does not enter XR, physics or the lobby recipe.
The previous full release completed this same test in 1.855 seconds.

Separate diagnostic module runs, without changed limits or assertions, passed
all 20 source-edit tests on both trees. The timed-out case took 0.977 seconds
on the correction and 0.783 seconds on the prior tree. These are diagnostic
results, not replacements for the failed full gate. The diagnostic invocation
used each tree's build outputs; all frozen source inputs were checked unchanged
afterward, and the original release evidence was not overwritten.

Host load was 4.58/5.11/5.49 on eight CPUs at the subsequent sample. That sample
does not establish contention at the timeout. The 1,323.60-second failing full
EUnit run was slower than the previous 972.72-second passing run. Timing or
suite-state effects are hypotheses; the timeout's root cause is unresolved.

A single new complete release sequence is justified to test reproducibility
after the isolated comparison. It uses a separately labelled fresh tree with
identical build inputs, identical commands and unchanged test deadlines.
Gates-01 remains failed. A second incomplete sequence would leave release
qualification blocked rather than trigger indefinite reruns.


The second complete sequence reproduced the identical failure after 4,039
passing tests (EUnit exit 1, 1,311.44 seconds). No later gate ran. No third release
attempt is started. All 656 compared dependency source/configuration files are
identical to the previous passing tree, as are the editor and its source recipe.
The read-only resource capture ended with its owned EUnit process; it recorded
peak RSS 941,125,632 bytes. It is not a per-test heap or reduction trace and does
not establish why deep dereferencing exceeded the deadline. The current release
is blocked pending a causal, smaller reproduction of this suite-context effect.
