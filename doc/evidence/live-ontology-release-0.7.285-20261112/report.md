# Eidolon toolkit release: 0.7.286 live (2026-11-12)

Rolling upgrade plus live ontology edit on the existing network, root anchor
`C21E011BC94C7B69AD56A4227BED085EF2FA7C536458A5457C410256C1FD3F5E`. No refound,
no data wiped.

## Commits (worktree/pearl-stone)

- `8b52fa9e` feat: show spaces by a shared marker and edit one thing in place
- `2dcb6ab2` chore: bump to 0.7.285
- `fdac1e0e` fix: let a node restart while its enrollment awaits activation
- `117e2a43` chore: bump to 0.7.286

## Steps and results

1. Client installed to `~/Games/quod` from the export that passed the Phase 4
   client gates; previous install kept at
   `~/Games/quod-before-eidolon-toolkit-20261112` (`client-install01.json`).
2. Image 0.7.285 built and pushed. Rolling upgrade started 18:16 and failed at
   its deadline: see `rolling-upgrade-stop.md`. Yan chose to fix the boot
   defect rather than refound.
3. Boot fix, gates `boot-fix-server-01`: eunit 4361/0, CT 150, xref 0,
   dialyzer 0. Image 0.7.286 built and pushed
   (`sha256:ae757c2f…d61d69`).
4. Rolling upgrade to 0.7.286, 21:16 to 21:19: deployment successful, 8/8
   compute and 2/2 cloud healthy, no restarts (`upgrade-286-progress.log`,
   `after-286-status.txt`). The two nodes that could not start now run, and
   every node reports `node_enrollment=complete`.
5. Live edit from node 0 (`live-release.erl`, `live-release-01.log`): 44
   predicate edits applied, 0 failed (14 `gui_scene.pl`, 1 `quod_gui.pl`,
   29 `quod_space.pl`), about four seconds.
6. Verification:
   - `live-verify-01.log`: marker size 500, `corner_box` kind, default
     10 m, playing recipe = the GUI vocabulary's `marker`, edition recipe =
     `space_edition`, outside values `[solid, contents]`, size text
     `10 m × 1/3 mm × 2 km`. Its three `old_*_gone` rows are not valid checks
     (`clause/2` through `prove_ro`, and a variable-headed `eidolon/3` clause);
     the source comparison below replaces them.
   - `live-verify-source-01.log`: for all 82 predicates of `quod_space.pl`
     and the edited ones of `quod:gui`, every clause of the new file is
     stored in order and no clause only the old file had remains. Three
     untouched `gui_scene.pl` predicates (`anchor/4`, `face/4`,
     `oriented_bounds/12`) compare unequal through the rendering of negative
     numbers; they were not edited.
   - `live-plan-03-after.log` lists six predicates as still "planned". That
     is the plan tool treating clauses common to old and new as old when a
     clause was inserted mid-list; applying it would reorder them. It was not
     applied.
   - `live-verify-fleet-01.log`: all ten nodes at root 60, gui 18, space 32;
     a rational `corner_box` with three surfaces models; `marker_size(500)`
     holds; the edition recipe is offered; `space_half_depth/2` is gone.

## Left as is

- `/tmp/quod_source_release.beam` and the `old-*.pl` / `new-*.pl` copies on
  node 0's container: the harness blocked the removal. They disappear at the
  node's next restart.
- `quod_physics.pl` changed one line with the same meaning for valid values.
  It is part of world and lobby ontologies, none of which was edited live.
- Spaces created before this release keep their stored place.
