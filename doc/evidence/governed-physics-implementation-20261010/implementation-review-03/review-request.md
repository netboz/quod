# Fable: final geometry refusal correction

Yan explicitly requested Claude plan and implementation reviews. Use Fable for
this read-only follow-up. Do not edit, invoke commands or agents, or access live
services. Review the frozen inputs only; preserve all evidence.

Read the previous review included at
`tree/doc/evidence/governed-physics-implementation-20261010/implementation-review-02/fable-review.md`.
The full feature and capability plan remain open. This review is only the actual
geometry prerequisite after fixing your demonstrated coordinate-reason leak.
It is not a renewed request to approve the incomplete capability proposal.

`followup.patch` compares the corrected files to that previously reviewed tree.
`changes.patch` supplies the complete four-file production/test/doc slice against
repository HEAD. Before snapshots correspond to the prior reviewed version.
The geometry helper now keeps shared query coordinates silent; body geometry
adds its own allowance reason. Independently check malformed encoding, actual
policy allowance reasons, input/query/recovery refusal classes, backtracking,
and all callers. Confirm there is no new semantic regression or missed caller.

The signed regression tests cover excessive speed, angular input, push impulse
and motion query. The first assertion incorrectly expected no normal goal
breadcrumbs; it was corrected to assert specifically that no added coordinate
allowance reason appears. The pre-fix failure did contain that explicit reason;
the first post-fix failure contained only normal goal breadcrumbs. Both failed
runs/fixtures remain. Final focused 13 and broad 178 tests passed with child
exit 0 and stable source hashes. Documentation now includes motor scalars.

The prior unattributed datasync is still unresolved. No strict zero-I/O assertion
was weakened; passing runs do not explain its cause or establish remote-work
acceptance. No remote propagation, capability epoch, normal-view integration,
admission/withdrawal integration, current signed lobby baseline or live desktop
collision acceptance is claimed.

Return a concise verdict on correctness of this partial implemented slice,
remaining actionable findings with severity and real file/line references, and
the limits of its validation. Do not infer approval of the full task.
