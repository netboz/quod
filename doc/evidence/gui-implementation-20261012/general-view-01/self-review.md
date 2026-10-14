# General views and question controller assessment

Independent source review; no Claude review requested or claimed. The final
scope is `tree/` plus `simplification/tree/`, pinned by `final-manifest.json`.
The latter removes unused one-shot HUD/form HTTP helpers after all production
consumers moved to the shared subscription. Status remains an explicit signed
read. The old HTTP helper test obligation is covered by the signed HUD socket
test, with renewal/disconnect coverage added. Existing decoding tests remain.

The server replaces the old simulation owner and endpoint; no compatibility
route remains. Kind decoding is closed. The signed goal must match its exact
kind, namespace, anchor and projection variable. GUI projection opens reuse the
same proof, dependency monitors, foreign follows, authorization expiry and
renewal lifecycle. They subscribe to no physics owner. Signed GUI socket tests
exercise authenticated human selection, refusal of a different human, source
invalidation distinct from HUD invalidation, and unchanged renewal with retained
monitors/follows and no measured disk/history work.

The client has one signed subscription implementation. The world adapter keeps
movement sequence, frame fencing and uncertain-command locks. An early renewal
does not discard an in-flight command. HUD and question adapters decode existing
ontology terms and accept no executable client callbacks from the ontology.

The portable question controller owns local drafts and interaction locks only.
It uses the existing signed-operation journal for submission/cancellation and
the existing exact outcome endpoint for resolution. Busy is set synchronously
before signing. Pending journal rows lock a reopened question; successful
submission also locks an older awaiting projection. A failed journal read never
enables writes. Unchanged projections preserve drafts, changed schemas retire
them. The server remains authority for revision, policy and the atomic write.

Explicit answer-status reads permit cancellation after certified negative
completion, including after the controller's own successful submission. If the
source schema is withdrawn, an authenticated awaiting-status read can still
permit cancellation without offering cached fields for editing. The server
rechecks that status in the cancellation transaction. Unknown status gives no
cancellation permission. This is explicit human recovery, not automatic work
recovery.

Desktop and spatial panels use the same controller/model. The existing world
action menu offers the pending-question list in VR; there is no new menu owner.
The MCP browser exercised the real React form and IndexedDB journal, with a
fixture socket/HTTP transport and a spatial model sink. It verified shared
drafts, simultaneous-submit refusal, locking across lost response/reopening,
one execute followed by one exact outcome read, and no browser errors. It does
not establish live server opening, actual Babylon targeting or headset comfort.

Production delta against this packet's before snapshots is +485/-131, net +354
lines, including declaration files. The common transport removes the duplicated
lifecycle that separate GUI sockets would require; the new adapter, local
controller and mounted question/list UI account for the necessary growth.
No queue, durable store, proof owner or authorization system was added.

No blocking correctness finding in this delivered scope. Full acceptance remains
incomplete: original opening still needs authenticated remote native preparation
and release, installed-handler acceptance and original hosted-request custody;
automatic recovery observation, application demonstrations and Vive validation
also remain. These views require the human/responder ontologies to compose the
shared GUI behavior; this change neither deploys those ontologies nor invents an
offline acceptance fallback.
