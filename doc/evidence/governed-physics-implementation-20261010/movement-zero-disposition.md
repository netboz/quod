# Integer movement units: real desktop correction

The actual signed desktop trial on 0.7.259 reached the physical world and floor
contact, then backward travel failed. With the right-handed camera mount at zero
rotation, Babylon vector arithmetic produces a negative-zero vertical component.
`Math.trunc(value * 1000)` preserves that sign; the generic Prolog formatter
correctly preserves it as floating-point `-0.0`. The governed movement contract
requires integer milli-units, so Prolog correctly refused the command.

One pure conversion in [locomotion.js](../../../client/src/locomotion.js) canonicalizes quantized zero
to integer zero and serves drive linear/angular values, teleport and push. The
generic numeric formatter, server integer validation, finite-input checks,
resource budgets and signed protocol remain unchanged. There is no compatibility
branch. The handwritten production delta is +6/-3, net +3 lines.

The new backward-key regression traverses the existing controlled-navigation
owner and compares the serialized request term. Direct quantizer coverage checks
negative zero, negative sub-milli values, signed nonzero truncation and nonfinite
input across the three callers. Both new regressions failed on the prior code
with true child exit 1 and detailed assertion differences, then passed after the
correction. The full client suite includes the new test file. Existing generic
negative-zero round-trip coverage still passes.

Claude Fable approved the [plan and implementation](movement-zero-review/README.md)
(12 and 18 unchanged frozen inputs respectively),
both with child exit 0. Advice was checked against
the code. The plan review consulted the newly written live test outside its frozen
packet; the independent red-run hashes and the implementation packet explicitly
cover that file. The implementation review remained within its supplied packet.

Review notes checked afterward: the new untracked test is included in the release
freeze and must be committed; the standing test glob ran all 15 test files; all
existing source quantizers use the shared helper. The production minified bundle
was imported directly and exercised with the actual backward vector and negative
sub-milli values: drive and teleport emit integer zeros, while generic negative
zero still emits a float. That probe also records the exact asset hashes.

The [first clean release gate](release-260-gates-01/README.md) stopped at two
EUnit failures. The queue fixture assumed one blocker when a legitimate worker
custody handover can produce two; that ordering was reproduced deterministically
and the test now verifies it. A VM-wide source-read trace also observed a write
and datasync without recording their owner. Isolated diagnostics passed but do
not explain that observation. The next separately frozen campaign retains the
zero-work assertion and records caller/owner attribution on any failure.

The [second frozen release campaign](release-260-gates-02/README.md) passed
all ten sequential gates, including 3,879 EUnit tests and 146 Common Test cases.
All child exits were zero and all 683 source inputs remained unchanged. This
passing full run does not explain the earlier unattributed write; both records
remain available. The [test diagnosis and Fable review](release-260-test-diagnostics/README.md)
retain the deterministic custody reproduction and the unweakened I/O assertion.

Release 0.7.260 deployment and real desktop acceptance remain pending. A passing
review or release gate does not close [QUD.27](nimbalyst://QUD.27) or substitute
for the deployed browser check.
