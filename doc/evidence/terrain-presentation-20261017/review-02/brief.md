# Fable review: complete terrain presentation correction

Read AGENTS.md. Yan explicitly requests Claude validation of the live terrain
flashing, missing textures and missing sky. Read-only: no commands, tests,
builds, edits, memory updates or delegation. Return a COMPLETE report with a
verdict, confirmed defects separated from risks, exact frozen references and
inspection limits. This is consultative review, not deployment approval.

The exact tree is `_build/terrain-presentation-20261017/clean-presentation-03/tree`.
The accompanying scope, manifest and patch identify all task changes from the
deployed baseline. Review changed seams and necessary callers, not the entire
previous world-library implementation or every unchanged manifest entry.

The original visibility/material/sky changes remain as in review-01. Their
real-owner Prolog test passed; all 31 focused client cases now pass. Five focused
physics cases pass through the real owner and signed socket. Source and test
receipts are under `_build/terrain-presentation-20261017`. Full 12-gate campaign
03 is running; neither partial campaign 01 nor 02 is a release pass.

The longer walk found a further cause of freezing: the owner withheld physical
frames until every chunk had completed its separate network acknowledgement.
Timing in `../delivery-timing.json` records 315 exchanges, average 0.133 ms from
receive to rendered acknowledgement, then 71.35 ms to the next resource. These
are browser timestamps, not a claim to isolate raw network latency. The world
stayed visible in 392 rendered frames, but loading still paused movement.

The shared stream now sends exactly the requested missing indices together in
one content message, bounded by the already validated manifest allocation.
There is no new owner, queue, policy constant, API route, per-chunk fast path or
compatibility branch. `terrain_chunk` and the separate `terrain_complete`
message are removed. An empty content message completes a fully retained set.
The browser checks exact ordered indices and all digests before installing new
bytes, waits for the ordinary renderer, and only then announces completion and
permits navigation. A stale interest releases its token without installing the
old content or making the newer window ready. Projection/expiry replacement
still fences asynchronous work. Resources and fresh physical frames alternate
on the existing one-credit owner, with no motion queue and unchanged fences.

Please scrutinize aggregate bounds, exact acknowledgement custody, rebase,
expiry/replacement and interest changes during checksum/rendering. Check that
there are no leftover old-wire callers. The real-owner fixture covers a falling
body advancing while the manifest holds credit, latest-pose delivery, stale
cross-kind acknowledgements and continued resource delivery. The signed socket
checks the complete multi-chunk content against native output, retained empty
completion and no repeated physics I/O. Client tests reject missing, duplicate,
unrequested and bad-digest content before partial installation, plus delayed
rendering, checksum/interest races, replacement revisions and canonical rebases.

The proposed live rollout must preserve the current volume family, root,
accounts, owner authorization and worlds. New source files do not automatically
rewrite founded ontology state. System vocabulary updates need ordinary node
authority; existing personal worlds need their owner's ordinary signed edit.
That concrete operator/owner update is being prepared separately; do not claim
it is reviewed here. The diagnostic appearance fixture is confined to the
agent-owned acceptance account and is not production code or user-world data.
