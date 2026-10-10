# Ordinary view integration: review proposal

The current signed socket already owns proof admission, actual read dependencies,
native watches, expiry and refresh. The browser still starts it from a separate
Simulation menu and discovers physics in the acting agent's ontology. This stage
replaces that entry and its one-argument selector. It adds no native authority,
projection store or synchronization protocol.

## Concrete interface

Use one canonical anchored read of
`client_world_view(Instance, Mode, ExpectedDependencies, View)` in
the visible world's ontology. The target includes its exact namespace, genesis
anchor and ground instance; Mode is a ground atom. ExpectedDependencies is the
bounded, sorted list of exact namespace/anchor/height triples returned by the
earlier signed navigation read. The signed acting agent stays
the origin and principal. The endpoint checks the fixed goal shape, including
the named View output, rather than accepting an arbitrary manufactured binding.
Remove the current requirement that the acting agent must be hosted locally;
ordinary signed ingress already owns its local/remote proof route. Only an active
native simulation must be hosted locally for the existing pose stream.

Ingress submission currently waits for both local proofs and remote routing.
Run that same submission in one monitored, cancellable opening worker owned by
the existing socket, using `quod_process:kill_when_owner_dies/2` for owner death.
The socket retains the original signed expiry and an exact opening reference,
kills the worker on cancellation/expiry, and ignores a late result from an older
opening. It admits no second opening worker until the cancelled worker has died.
This worker only invokes existing ingress; it owns no proof execution,
authorization, queue or network routing. Do not bypass ingress with the trusted
`execute_async` operator API or build another submission owner.

The shared Prolog wrapper belongs in common framework predicates. A space's
`world_view(Instance, Mode, Marks)` adapts its existing representation goal. Use
`findall` with an exact singleton result to require one complete scene; an
ordinary first-answer read or `once` does not establish uniqueness. Absence,
ambiguity and malformed output are unavailable. The adapter owns no physical
flag, permission or copied body state. Apply the same singleton requirement to
the configuration selected for this view: the existing
`physics_required_configuration/4` enumerates alternatives and is not itself an
ambiguity check.

Reuse `space_instance(Instance, space)` to establish the space, then
`space_instance(Instance, physical_space)` for its physical classification. A
missing space composition or invalid instance is unavailable, not nonphysical.
A known nonphysical space selects nonphysical. A physical space's enablement,
authority, grants and budgets come from the existing physics_space/3 and physics
rules. There is no second mutable physical/nonphysical declaration in the view.
Class membership alone installs no code, native resource or control permission.

Physical eligibility must be shared with the existing physics resource and
hosting selectors, not added only to rendering. Currently `physics_projection/2`
tests `physics_space/3` without `space_instance/2`, and hosting suspension tests
only an explicit disabled row. Replace those independent eligibility checks with
one derived Prolog rule requiring the physical-space class and enabled singleton
configuration. Use it from the existing resource, authority-hosting and live-input
paths. Remove the old checks and update their physical fixtures to compose the
space vocabulary; absence of the class is not a compatibility exception.

For physical selection the wrapper calls the composed physics rules at the same
space owner, passing the exact instance and already-selected Marks. Replace
`physics_client_view/1` with `physics_client_view/3` (Space, Marks, Selection),
removing the duplicate physics_view/2 rendering selector and acting-agent
physics_client_world/1 discovery. Reuse existing can_view_physics/2, body/control/
viewpoint validation and pinned rendering validation. This deployment keeps the
visible space and its physics authority at one governance/lifecycle owner.
Cross-ontology live body definitions remain references consumed by that authority;
no linked physics ontology is introduced and no ontology becomes a space merely
because it owns one. The shared interface contains no lobby name or behavior.

The resulting world view contains the exact entity reference, ordinary marks and
one typed selection: nonphysical, disabled, denied, recovering, unavailable or
the existing active simulation fence/control configuration. Disabled and denied
selections still read their actual policy and binding dependencies and keep the
socket's subscriptions. Missing run/host activation is recovering; missing or
ambiguous required configuration is unavailable. Installation is checked by the
existing native watch after committed selection and is reported separately.
Outer invocation refusal or proof failure remains unavailable unless the Prolog
selection explicitly proves a more precise status; Erlang does not guess policy.

## Browser and subscription ownership

The generic view input is an exact space instance reference plus its selected
representation mode. Existing navigation supplies that reference; physics is
always selected at the visible space owner, never guessed from the acting agent.
Retire the separate Simulation menu and readSimulationWorld path. All scene,
authorization, geometry and failed/disabled selection scopes belong to the one
signed proof and its existing socket subscriptions.

Every installed typed world view, including nonphysical, disabled and denied,
renews its signed read at the existing authorization-expiry boundary. Presence
of a native PID must not decide whether such a view remains subscribed. An
unfinished opening still expires under its original deadline. This is lease
renewal, not a retry timer for discovering readiness.

A reference discovered by an earlier signed read needs every dependency of that
read fenced, including foreign selection policy. The earlier proposed
`block_height/1` guard does not exist and checking the origin alone would miss
foreign changes. Carry the complete ExpectedDependencies in the canonical signed
goal instead. Before classifying or selecting the view, the common wrapper visits
each dependency with its existing anchored `current_ontology_identity/2` read.
All those visits use ordinary scope authorization and the same pinned proof;
there is no live-height query or extra read engine.

The socket compares every expected triple against that proof's actual dependency
envelope before exposing a scene or attaching to a native owner. An absent or
different triple cannot install the view; a changed selection asks the browser
to re-read navigation. Existing subscribe-before-snapshot then watches the full
actual envelope, including these navigation scopes. This keeps later changes to
the navigation decision visible as well. Namespace/anchor and uint64 height
validation is bounded by existing proof and wire limits; HTTP dependency heights
use decimal strings so a browser cannot round a fence. Explicit direct navigation
may have an empty prior dependency list; derived navigation must forward its full
list and must never silently discard it to make opening work.

The navigation adapter must also return an exact `entity_ref`, not only an
ontology reference. The current personal-lobby reference has only namespace and
anchor; its ordinary Prolog adapter must resolve the authored space instance in
that same signed navigation read. The generic client must not guess an instance
name or reuse the system lobby-vocabulary anchor. This is navigation adaptation,
with physics still selected at the visible space owner. Uncertain movement/domain
operations are resolved by original identity, never resubmitted.

One scene update method owns marks and poses. A frame only updates its existing
body sources; a projection updates the marks under the same owner. Remove the
parallel React paint effect and simulation painter. Authored attachment frames
and camera local transforms retain the existing exact identities.

Nonphysical is explicit observer travel. An active physical view with an explicit
unbound control selection may observe, while a bound agent uses commanded body
travel and its authored viewpoint. Denied, disabled, recovering, disconnected or
unavailable selection pauses movement; losing permission cannot silently clear
the committed controlled-agent selection. Tracked head motion remains inside the
existing authored mount and contact/comfort checks.

Changing classification does not authorize silently dropping a retained body
assignment. A nonphysical classification with a still-bound physical controller
is unavailable for body travel until the designated atomic withdrawal/unbinding
transition resolves it. The Prolog selection must establish an unbound observer
state; the browser must not infer one merely because the physical class or native
owner disappeared. Domain assignment cleanup remains in the existing space and
control actions, never in the renderer or a post-commit repair.

## Gates and tests

This is a clean protocol/source change requiring compatible participating
validators and the existing release authority; no old/new decoder branches. No
manifest evolution, ledger rewrite or additional refound is needed for common
system predicates plus governed Prolog edits.

Exercise production signed views in two world namespaces (one non-lobby), an
explicit nonphysical world, disabled-to-enabled, denied-to-granted, retained
ordinary rendering dependencies, exact instance selection, stale anchors and
control revocation. Also change a foreign navigation dependency while the origin
height stays unchanged; the old selection must never attach. Test ambiguous
scene/configuration, exact uint64 fences and missing dependency triples. Hold
ingress work through expiry, reopen and socket death, and prove cancellation
releases the original worker without installing a late answer. Preserve the
existing socket deadline and remote dependency tests. Client tests cover one
scene writer, parented marks, camera mounts, stale
frames, refresh/reconnect and no controlled-to-observer fallback. Real signed
desktop acceptance in the preserved actual lobby remains mandatory.
Test physical classification withdrawal with a retained controller as well as
proper atomic withdrawal, and prove the same eligibility rule prevents native
allocation and physics authority hosting in a nonphysical space.

Review must check that the wrapper preserves Prolog policy, that existing
space_instance/2 and physics_space/3 are the only physical classification and
enablement sources, and that complete dependency fencing closes reference
selection races without an ACL bypass or another dispatcher. This amended plan
supersedes the unreviewed world_view/4 Kind proposal. The frozen first review
attempt remains intact; it exited on Claude's session limit and reviewed nothing.

## Real-space acceptance only

The personal lobby is one existing space used for required desktop acceptance.
Its ordinary representation adapter delegates to its existing view; enabling
physics changes the same generic class/configuration/body policies as for any
other space. No lobby-specific physics selector, enablement branch, gravity,
collision store or runtime lifecycle is allowed. Existing console, roof, openings,
parents and camera transforms must survive. Source edits use the current lobby's
authorized action path after establishing its actual signed identity/history;
changing a future founding template cannot update that existing instance.
