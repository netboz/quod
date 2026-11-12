# Phase 3 client gate run 03 stopped on `spaces`

`gui` passed. `phase3-client-03-spaces` failed in `m2-final` at
`SpaceChecks.cs:318`: clicking the centre of the second created marker
resolved the first created space.

Cause: both spaces were created with "Near my agent" from the same standing
point. Placement no longer depends on the space's size, so both markers stand
at exactly the same pose and the click reaches the first. The ontology and
client behaved as written; the check assumed two distinguishable places. (Two
default spaces also shared one pose before this change, 52 m away; the old
check avoided it by picking a 100 m wireframe edge.)

Fix: the check places its second space with the form's existing explicit
"at S0" choice. No production change. The stacking of successive near-agent
spaces is reported to Yan as an observation.

Navigation and local-backup never started. Run 04 repeats the client gates in
full on `phase3-04-tree.diff`.
