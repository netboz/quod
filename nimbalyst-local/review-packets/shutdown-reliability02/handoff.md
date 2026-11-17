# Shutdown reliability checkpoint — partial

The intermittent shutdown cause remains unestablished. One new current-source
software observation passed 93 initial and 68 same-profile reopen checks. Both
direct native engines, both client wrappers, the server and the outer driver
exited 0; all six streams reached EOF and their readers retired. No original
failure cutoff occurred, so no failure-time native capture ran and no shutdown
fix is claimed. Reliability acceptance remains open.

Work used the existing `worktree/pearl-stone` branch at
`293cf6115c0a6b18315eccdbb42cbca396f443d3`, with an empty index. Session
`d2781fa7-d8a1-4051-8de9-a946187cb25c` is reported by the editor as
`openai-codex:gpt-6-astra`; effective reasoning effort is not exposed.
The coordinator, previous implementation session, VR reliability session and
completed reviewer were idle before edits. No parallel writer or review was
launched. All pre-existing tracked changes remain byte-identical to the saved
baseline patch; existing product, helper and source bindings were verified.

## Implementation checklist

- [x] Trace the current managed close, native engine and wrapper/pipe owners.
- [x] Bind a new finite observation to current sources and existing dependencies.
- [ ] Establish the intermittent failure's cause and correct its responsible owner.
- [x] Verify the current diagnostic signed journey, same-profile reopen, direct
  engine exits, wrappers, EOF, readers and terminal managed resources.
- [x] Freeze the exact new source/evidence delta and verify reconstruction.

## Ownership and observations

[Main.cs](../../client/godot/Main.cs:609) owns application close. Ordinary
WM-close and the qualification caller reach this same method. It cancels the
active action and backup, retires the current session, joins view/action/backup/XR
tasks, releases model consumers, awaits the existing XR shutdown, releases the
identity writer lease and requests SceneTree Quit. Its `_ExitTree` retains the
lease on an external quit while cancelled I/O is outstanding. The local store
still uses atomic replacement, file/directory sync and read-back; no durability
or uncertain-write behavior was changed.

`Main._Ready` starts `ExportChecks.Begin` on the Godot executor. The removable
current visibility companion performs ordinary native control gestures and signed
operations, writes its result, then emits its completion marker **before**
awaiting `CloseApplication`. That marker cannot establish shutdown. The Python
journey owns the bwrap Popen and two readers per child; its Popen result is the
wrapper's result, independent of a direct engine exit or an inherited pipe writer.

The diagnostic reuses retirement250's reversible staged Main milestones,
`CloseTrace.cs` and failure-only `shutdown_capture.py` unchanged. It adds bwrap's
native exit-status channel and checks the already-owned engine pidfd at completion.
At an original post-completion cutoff it saves the whole failure before the
existing bounded capture. Exact engine PID/starttime/executable inode/mappings
and separate wrapper identities are retained privately. No stale PID was inspected.
The conditional capture and exited-engine descriptor branches remain unexercised.

Both observed closes produced all 26 stages on thread 1 with
`Godot.GodotSynchronizationContext`. Views, action, backup, XR completion and
models were already completed at their joins. Close-enter to `_ExitTree` return
was 0.022199385s and 0.024644071s; these intervals are **not** native exit latency.
Both native status streams report exit-code 0 and both exact engine pidfds report
exit. Terminal scenes, sockets, subscriptions, sources, appearances, captures,
model templates and leases are zero; XR remained off.

This distinguishes the lifetimes during normal completion. It does not identify
which lifetime remained during the original failure. No further application run
followed the successful observation. A further launch needs a new discriminating
observation or a demonstrated correction, not another attempt to obtain green exits.

## Exact inputs and verification

The current trace-free visibility product has 98 source inputs; its manifest is
`40276e0371d70153f701eb15883e06c05ca97fe4ec21f78b4079cb79615b3bda`.
Five of those files differ from attention279, so attention279 was not reused as
the current product source. The diagnostic stages all 98 current inputs, supplies
100 including the two diagnostic partials, and produces 196 export files. It uses
the same pinned engine/template and eight dependency archives. Fourteen current
server sources and the already-qualified world-name correction are bound; core
server and dependencies were not rebuilt.

- `shutdown-observation01-build` failed with child/wrapper 1: the sandbox denied
  Godot's local sockets (`SocketException (13): Permission denied`). Full logs,
  staged source and outputs remain retained. No application journey ran under it.
- `shutdown-observation02-build` uses the required local socket access. All five
  sequential build phases and the outer driver exited 0.
- `shutdown-observation02` completed 93+68 checks in 32.307172536849976s. Both
  engine exits and client wrapper exits were 0; server/outer were 0; six EOF,
  no reader errors. Original phase180/post-completion60/outer300 and cleanup60+10
  bounds were preserved. The failure-only capture bound remains15s.
- `qualification01` verified the saved source, exports, raw streams, direct child
  bindings, result assertions, terminal resources and unchanged inherited tracked
  patch. Child and wrapper exited 0. It launched no application.
- A separate harmless bwrap child exiting7 verified native status encoding; both
  its native record and wrapper reported7 as expected.

Reopen preserves original U/A/S0 key and location, the exact original operation,
request digest and committed bindings, and the pending question identity. Local
form placement and Later/recall retain the native draft/caret/selection. The reopen
draft remains unsubmitted and no instruction is replayed. Both unchanged-operation
measurements report `work.calls=[]`; the real explicit configuration update reads
back exactly once. Generic unwritten form drafts are window-local, not claimed to
survive process restart.

The [result](../../doc/evidence/godot-shutdown-reliability-20261103/result.json),
[source manifest](../../doc/evidence/godot-shutdown-reliability-20261103/inputs/client-shutdown-observation02-manifest.json)
and [qualification receipt](../../doc/evidence/godot-shutdown-reliability-20261103/logs/qualification01.json)
contain exact hashes, checks and exits. Binaries, raw logs, stores and profiles
remain persistently under this worktree's `_build/godot-shutdown-reliability-20261103`.
Private credentials are excluded from the source/evidence archive.

The [final freeze receipt](../review-packets/shutdown-reliability02/result.json)
verifies actual tar creation/extraction and all 97 files/14 directories, contents
and modes. Manifest SHA256 is
`4ed4d782b469ac5017eb050d01070f0af15e51af65019cd4aab9e175a4be09f1`;
archive SHA256 is
`8d0b3c3aa41de72a2635859e8c8175e39f9e132b17041cdd76b3bdfb8843e08f`
(431,073 bytes). Archive/extract/freeze exited0. Only the new evidence subtree
is archived; this final handoff and tracker receipt are separately bound in the
packet after sealing. Persistent build/export directories retain the binaries.

[Freeze01](../review-packets/shutdown-reliability01/failure.json) remains failed:
its private umask changed 45 extracted file modes while every content hash matched.
The corrected freeze02 explicitly uses permission-preserving extraction into a
new directory; it never changes original file modes. Both packets and the failed
script remain intact. This is an evidence-packaging correction, not a client fix.

## Delta and remaining acceptance

No inherited production or test file changed: production delta **+0/-0**. New
diagnostic/evidence helpers total 1,196 physical lines across 14 files, including
unchanged retained copies of the existing fixture/journey/capture owners.
Against their saved helper originals, adaptations plus the three local helpers
are +177/-10. These are diagnostic growth, not production reductions.
[Exact helper deltas](../../doc/evidence/godot-shutdown-reliability-20261103/inputs/helper-line-delta.json)
record each file. No inventory capability changed.
The packet also retains the 50-line freeze script and its failed first version;
the extraction correction and new reconstruction label are +2/-2 against that
saved version.

The original appearance246 journey01/02, retirement250 result, current visibility
failures, visual02, VR review failures and all profiles/archives remain intact.
The new successful observation does not relabel any failed run. Visual02 still
has rendering-only evidence without Focused/controller admission; the later
SteamVR crash remains unexplained. XR/hardware/human acceptance was not run.

Final acceptance/release still needs:

1. A failure-time causal observation and justified shutdown correction, followed
   by its failing real-owner regression and affected original-bound acceptance.
   There is currently no evidence-based engine replacement or cleanup reorder.
2. Final integrated software acceptance on an identified frozen tree, with
   applicable clean sequential gates and any source-invalidated evidence renewed.
   Unchanged server gates were deliberately not repeated for diagnostic-only work.
3. Explicit disposition of remaining M4/hardware/usability and certified-negative
   outcome presentation gaps. The plan permits stated hardware gaps, not an
   unexplained shutdown pass.
4. Final package/platform qualification beyond the current private Linux
   GLIBC2.44 host and remaining covered retirement/caller/coverage audit, with
   actual ontology/file/production-line counts.
5. Refresh M0's exact old-network identities and verify replacement founding,
   catalogue, endpoint, trust, enrollment and routing before the later authorized
   cutover. This checkpoint performs no deployment, data retirement or deletion.

Tracker metadata/local checkpoint updates are distinct from collaborative body
publication. The start update explicitly failed collaborative storage; its full
[receipt](../../doc/evidence/godot-shutdown-reliability-20261103/inputs/tracker-start.json)
is retained. The final update saved status `blocked` and the local checkpoint,
but again explicitly failed collaborative body publication. Its
[receipt](../review-packets/shutdown-reliability02/tracker-final.json) is retained;
no publication retry followed. The blocker is missing failure-time causal evidence,
not a failed current journey. Broader M4/M5 remain open. No commit or push occurred.
