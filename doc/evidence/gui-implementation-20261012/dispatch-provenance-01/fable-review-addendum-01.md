# Fable review addendum 01: corrections from the independent assessment

Reviewer: Claude Fable 5.1, 2026-10-13. Source reading only; no command run.

## Withdrawn: duplicate identical assertion (first report, section 3 last paragraph)

I wrote that an authorized writer could commit a second `assertz` of an
identical submitted row and so cause a second actual-assertion occurrence.
That is generic Prolog, not quod. `quod_diff:apply_op/3` treats an assertion
whose clause is already present as `unchanged` (content dedup,
`quod_diff.erl:280-284`), and the applied operations carry only real changes.
An identical re-assertion therefore produces no occurrence and no dispatch.
The consequence paragraph is withdrawn. Retraction followed by re-assertion,
or a distinct clause, remain real changes and real occurrences, as the
assessment states.

## Narrowed: R4 installation invariant

R4 asked for a test that composing the shared completion behaviour twice
yields one dispatch. The same reducer answers this first: composing an
identical `react_on` clause a second time is a content-dedup no-op, so one
clause is installed and `dispatch_candidates/7` sees one candidate. R4 is
reduced to relying on that existing behaviour; no installer, registry or
dedup store is implied, and none should be added. A distinct clause with the
same pattern is a real second declaration and would dispatch twice, which is
an authoring error the existing reducer correctly does not hide.

## Corrected: host trace

Section 2 argued no simultaneous-host window from committed heights observed
on each node. The exact ground is the key binding: signing is governed by
the committed `agent_hosted` row and the active key for that host and epoch,
and a new host assignment carries a new key. A node that lost hosting
cannot sign for the old key once the assignment changed, regardless of what
height it has observed; a node that gained hosting cannot sign the retained
bytes at all, because they bind the previous key (recovery-contract R1).
The at-most-once conclusion stands on that binding, not on equal heights.
