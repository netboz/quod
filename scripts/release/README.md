# Release tools

The scripts a release uses. They moved here from the evidence folders on
2026-11-17. Each one takes the evidence folder it writes into as its first
argument, so a release keeps its logs and receipts in its own folder under
`doc/evidence/` while the tools stay in one place.

Run them from the repository root.

| Step | Command | Writes |
| --- | --- | --- |
| Server gates | `python3 scripts/release/server-gates.py doc/evidence/<release> server-01` | one log per step, `results.jsonl` |
| Client gates | `python3 scripts/release/client-gates.py doc/evidence/<release> client-01` | logs, journey receipts, captured images |
| Install the client | `python3 scripts/release/client-install.py doc/evidence/<release> <label>` | `client-install-<label>.json` |
| One gate step | `python3 scripts/release/run-gate.py doc/evidence/<release> <label> <command…>` | `<label>.log`, a line in `results.jsonl` |

- A label is used once. No script overwrites a log or a receipt; run a second
  attempt under a new label (`server-02`) and keep the first.
- The server gates run every step even after a failure. The client gates stop
  on the first failing step.
- The client gates open windows on the real display. Do not start them while
  Yan uses the machine or the headset.
- `client-install.py` refuses to run while the installed Quod is running. It
  leaves the previous installation as `~/Games/quod-before-<label>`; renaming
  it back is the rollback. Keep one such copy at most.

Files the gates use: `client-journey.py` (one journey against a local fixture
node), `godot_m3b_fixture.erl` (that fixture), `verify-export.gd` (checks the
exported package) and `injected-mapping.term` (a controller mapping for the
controller checks).

## Refound

A clean refound replaces every ledger, account and node key. It needs Yan's
own go each time. The steps, as done for 0.7.294 on 2026-11-17:

1. Build the image from `git archive HEAD` and push it.
2. Compile the operator into the work folder:
   `erlc -o doc/evidence/<release>/refound scripts/release/refound/quod_refound_operator.erl`.
3. Rehearse from empty genesis in an isolated container:
   `scripts/release/refound/start-rehearsal.sh doc/evidence/<release>/refound <label> <image>`,
   then each phase with
   `python3 scripts/release/refound/found.py doc/evidence/<release>/refound local <phase>`.
4. Stop the job, delete and recreate the host volumes
   ([deploy](../../deploy/README.md)).
5. Deploy one founding node, write its allocation id into
   `doc/evidence/<release>/refound/founding/allocation`, then run each phase
   with `found.py … fleet <phase>`.
6. Deploy the joiners, then admit them one at a time:
   `scripts/release/refound/admit.sh doc/evidence/<release>/refound`.
7. Check every node with `refound/fleet-verify.erl` (an expression for
   `quod eval`).

The phases, in order, are the `ORDER` list at the top of `found.py`. A phase
that has run refuses to run again; there are no retries.

## Live source edit

`quod_source_release.erl` is loaded into a running node to bring one
ontology's stored clauses from an old source text to a new one, one predicate
at a time, through the ordinary signed edit. A test loads it
(`release_terms_use_the_existing_signed_edit_gate_test_` in
`test/quod_gui_menu_tests.erl`). Yan called the old and new source copies this
needs junk on 2026-11-15; a proper way to release ontology source is still to
be designed.

## Not yet run from here

Only `run-gate.py` was run after the move. The other scripts were changed in
one way only: where they find the repository, the evidence folder and their
labels. The server gates, the client gates, the client install and the refound
have not been run from this place yet; the first release that uses them is
their test.
