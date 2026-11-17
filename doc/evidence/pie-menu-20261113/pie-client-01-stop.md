# Pie client gate run 01 stopped on `spaces`

Everything before it passed: javascript, core (368), export, package content,
icons, scene, pie (real render), controller-input, workspace and the `gui`
journey. Navigation and local-backup never started.

`pie-client-01-spaces` failed in `m2-final` at `SpaceChecks.cs:144`
(`PickSpace`): the helper clicked a space's marker and waited 5 s for it to be
selected. A panel was open at that point (the journey had just opened the
account's controller settings), so under the new rule the click closed that
panel and selected nothing. The client behaved as intended; the helper still
assumed that a click on a thing behind an open form selects it.

Fix (test helper only): when a form is open, `PickSpace` first presses once,
waits for the form to close, checks that nothing was selected, then presses
again to pick. This also covers the rule itself in the `spaces` and
`navigation` journeys.

`pie-try01` is one `spaces` journey on that fix. Run 02 then repeats the
client gates in full on `pie-02-tree.diff`.
