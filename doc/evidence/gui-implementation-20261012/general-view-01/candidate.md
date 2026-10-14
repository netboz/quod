# General signed-view owner integration

The existing client simulation WebSocket already owns authenticated signed reads,
absolute deadlines, renewal, subscribe-before-snapshot, foreign-log follow custody,
owner monitoring and invalidation. Generalize that owner to signed ontology views;
do not add a GUI subscription process or invent a physical space for a form.

Replace the old endpoint/module with /api/views and quod_client_view. Migrate all
live browser, server and test callers in one scope; no legacy route or dispatch
shim. Keep frozen evidence unchanged. No native wire consumer has been found in
the current source tree; the native plan documents the older endpoint and needs
an explicit reference update, not a fabricated running-client compatibility claim.

The opening envelope names an exact namespace/anchor plus a closed view kind:
world, gui_hud or gui_question. Only the corresponding exact signed read goal is
admitted. World keeps client_world_view/4 and its physical input/ACK behavior.
HUD reads gui_pending_questions/1 in the authenticated human scope. A selected
question reads gui_question_form/2 from its responsible scope. Both GUI kinds have
no physics subscription, attachment, frame credit or body dependency. They use the
same real proof dependencies, foreign retained projections and renewal lifecycle.

One client signed-view transport must own socket/authentication/deadline/renewal
logic for all kinds. World-specific motion decoding/control remains its adapter;
GUI data decoding uses existing world.js helpers. No poll/reconnect timer; only
protocol authorization renewal and explicit browser-online/user refresh. A changed
projection invalidates drafts by identity/revision; unknown writes remain locked
by existing controller/journal ownership.

This slice supplies an authenticated live view and HUD updates, not gui_open.
It must not claim native receiver acceptance or invent a session registry. Next
trace connection incarnation into the existing effect preparation owner and pinned
remote transport; preserve absent-human/installed-handler Prolog failure, rollback,
absolute deadlines and certified release. Client auth session alone is not a
connected human receiver. No new effect descriptor or mixed-write permission is
authorized by this refactor's view proof.

Required evidence: existing world/nonphysical/foreign lifecycle regression gates;
GUI signed grammar/authority tests; HUD/form attach without physics; unchanged
renewal retains follows and performs no disk/history rebuild; stale/duplicate
owner notices harmless; disconnect/expiry/readiness fail closed. Hold production
and test source fixed throughout gates. No commit/deploy or hardware acceptance.
