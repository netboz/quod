# Ordinary view integration: review proposal

The current signed socket already owns proof admission, actual read dependencies,
native watches, expiry and refresh. The browser still starts it from a separate
Simulation menu and discovers physics in the acting agent's ontology. This stage
replaces that entry and its one-argument selector. It adds no native authority,
projection store or synchronization protocol.

## Concrete interface

Use one canonical anchored read of `client_world_view(Instance, Mode, View)` in
the visible world's ontology. The target includes its exact namespace, genesis
anchor and ground instance; Mode is a ground atom. The signed acting agent stays
the origin and principal. The endpoint checks the fixed goal shape, including
the named View output, rather than accepting an arbitrary manufactured binding.
Remove the current requirement that the acting agent must be hosted locally;
ordinary signed ingress already owns its local/remote proof route. Only an active
native simulation must be hosted locally for the existing pose stream.

The shared Prolog wrapper belongs in common framework predicates. A world's
`world_view(Instance, Mode, Marks, Kind)` is its explicit domain entry, with Kind
either `nonphysical` or `physical`. It must yield exactly one complete choice;
absence, ambiguity and malformed output are unavailable. This hook adapts an
existing representation goal, not a new renderer or recipe database. An ordinary
nonphysical world explicitly says nonphysical; missing physics predicates, failed
proofs and missing collision coverage never imply empty space or observer travel.

For physical selection the wrapper calls the composed physics rules at the same
world owner, passing the exact instance and already-selected Marks. Replace
`physics_client_view/1` with `physics_client_view/3` (World, Marks, Selection),
removing the duplicate physics_view/2 rendering selector and acting-agent
physics_client_world/1 discovery. Use existing `space_instance/2` to require the
physical_space semantics, existing physics_space/3 for enablement and authority,
existing can_view_physics/2, body/control/viewpoint validation and pinned rendering
validation. This deployment keeps visible world and its physics authority at one
governance/lifecycle owner. Cross-ontology live body definitions remain references
consumed by that authority; no linked physics ontology is introduced.

The resulting world view contains the exact entity reference, ordinary marks and
one typed selection: nonphysical, disabled, denied, recovering, unavailable or
the existing active simulation fence/control configuration. Disabled and denied
selections still read their actual policy and binding dependencies and keep the
socket's subscriptions. Missing run/host activation is recovering; missing or
ambiguous required configuration is unavailable. Installation is checked by the
existing native watch after committed selection and is reported separately.
Outer invocation refusal or proof failure remains unavailable unless the Prolog
selection explicitly proves a more precise status; Erlang does not guess policy.

The lobby adapter delegates to lobby_view/2, preserving its exact marks, console,
sky, roof, parents and vocabulary references. Before physical enablement it
explicitly selects nonphysical. The governed enablement transaction replaces
that adapter selection and composes the reviewed space/physics rules, explicit
geometry, camera/body binding, permissions and budgets into the SAME current
lobby. It does not change retained founding provenance. Updating a future template
is a separate source change and does not update an existing lobby. The actual
current signed identity/history baseline is still required before live writes.

## Browser and subscription ownership

Resolve the selected agent's existing lobby_reference/1, then use the same socket
for its ordinary view. Retire the separate Simulation menu and readSimulationWorld
path. The main signed view retains all actual origin, visible-world, rendering,
authorization and geometry scopes. Lobby modes can remain an ordinary metadata
read, but the displayed scene comes only from the socket's signed view proof.
Refresh repeats the current reference lookup and original-operation resolution
rules; movement commands with an uncertain outcome are never resubmitted.

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

## Gates and tests

This is a clean protocol/source change requiring compatible participating
validators and the existing release authority; no old/new decoder branches. No
manifest evolution, ledger rewrite or additional refound is needed for common
system predicates plus governed Prolog edits.

Exercise production signed views in two world namespaces (one non-lobby), an
explicit nonphysical world, disabled-to-enabled, denied-to-granted, retained
ordinary rendering dependencies, exact instance selection, stale anchors and
control revocation. Preserve the existing socket deadline and remote dependency
tests. Client tests cover one scene writer, parented marks, camera mounts, stale
frames, refresh/reconnect and no controlled-to-observer fallback. Real signed
desktop acceptance in the preserved actual lobby remains mandatory.

Review must specifically check that this wrapper does not bypass inner policy,
that the explicit domain Kind and physical_space semantics cannot silently
disagree, and whether the separate lobby-reference read needs an exact in-proof
guard to close the reference-change race before the first view opens. Use existing
proof/ACL owners for any necessary guard; do not add another view dispatcher or
mutable selection store.
