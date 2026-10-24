# Source invalidation during pending terrain coverage

The real-owner `source_changed` case commits physics structure 2 to 3 while a
reposition query waits for missing terrain. Once the source verifies, it cancels
the input and retires the viewer. Frozen05 only rechecks coverage on explicit
unwatch or viewer death. Its unchanged-collider installation leaves the owner
in coverage after the query has gone. The diagnostic waits on installed-state
notifications and times out with structure 3 selected, the original body's
terrain present, and no remaining runtime work. Receipt: exit 1, three passed,
one failed; the failing hosted fixture and full log are retained.

The shared correction calls the same coverage recheck after installed input,
control or navigation-guard dependencies change. An identical installation is
still a no-op. Native coverage, unfinished restoration and the current source
guard remain authoritative; there is no new timer, queue or process.

The first fix run (`terrain-source-cancel-fix-01`) passed readiness but failed
the new body-state assertion: native's sleeping sentinel retained the old frame
structure. This was a real publication defect, not a test timing issue. The
recheck now requests the existing native refresh so actual coverage is checked
and the refreshed sample carries the current installed projection.

`terrain-source-cancel-fix-02` exits 0 with all nine cases passing. They cover
applied, expired, disconnected and source-cancelled queries; unavailable states
for unfinished restoration and real missing body terrain; both original pending
insertion/checkpoint cases; and large-coordinate rebase. Both cancelled-query
cases assert the original body position and successful fresh watch. This is
focused evidence, not a full release pass. Full05 was explicitly stopped after
its current gate; final source needs a separate complete freeze and Fable check.
