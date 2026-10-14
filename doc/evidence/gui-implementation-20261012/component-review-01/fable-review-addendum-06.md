# Fable review addendum 6: the `at(NodeKey, Namespace)` route constraint on `::`

Reviewer: Claude Fable 5.1 (claude-fable-5-1), 2026-10-12. Consultative only.
Earlier reports unchanged. Inputs read live for this review:
`src/predicates/quod_ask.erl`, `src/quod_proof_context.erl`,
`src/quod_ask_router.erl`, `src/quod_scope_session.erl`,
`src/quod_scope_wire.erl`, `src/quod_directory.erl`, the scope-open and
nested-controller parts of `src/quod_prolog.erl`, `quod_simplex:identity_view/1`
and `prepare_genesis/3`. No command, build or test was run. Line numbers are
from those live files.

Addendum 4's standalone `gui_actor_accepts` query is withdrawn as the
selected shape; the parent is right that a discarded query's influence on the
material rows vanishes. The actor acceptance belongs inside a prepared
interactive effect. Section 4 states where that effect lives.

## 1. Verified facts about scope selection today

S1. **One scope per identity per proof, opened at the origin.** The origin
proof context keys scopes by `{Ns, Anchor}`, refuses a second anchor for the
same namespace, and bounds the count (`quod_proof_context.erl:573-620`).
Nested `::` from a scope worker, local or remote, goes back to the origin
(`quod_ask.erl:929-941`, `:1289-1302`; remote workers relay through the
controller event `nested_open` with a flat `TargetNs` binary,
`quod_prolog.erl:3571-3587`, `quod_scope_wire.erl:606-611`). So any route
constraint is evaluated once, at the origin, and reused by every nested
caller. That is the right owner for a pin.

S2. **Where the choice of host happens.** `origin_scope/1` prefers the local
engine when the namespace is hosted here (`quod_ask.erl:280-297`);
`open_cohosted_scope/3` keeps it local for read-only proofs and for
read-write proofs only when `identity_view/1` says this node is in the
committee, otherwise it asks the directory for confirmed validator routes
(`:298-331`; `quod_simplex.erl:3134-3158`). Remote opens iterate
`eligible_routes/1` (role validator) and, for read-only proofs, verify the
committee from the foreign log (`:431-506`); `open_remote_routes/5` tries
routes in order and keeps the best error (`:507-555`). No caller-selected
host exists anywhere on that path.

S3. **The target key is already bound end to end.** The binding
`{scope_binding, OriginKey, TargetKey, ProofId, ScopeId, OriginIdentity,
TargetIdentity, Mode, Principal, AuthDigest}` carries the chosen target key
(`:514-528`). The target engine accepts an open only when `TargetKey`
equals its own key (`quod_prolog.erl:2052-2059, 2413-2419`), the router
checks link peer key against `target_key` on every event
(`quod_ask_router.erl:1407-1412`), and a remote plan is accepted only if its
witness signer is that key (`quod_scope_session.erl:283-297`). The wire
validates key shape only (`quod_scope_wire.erl:659-676`). So "scope signer
bound to selected key, prepared effect checks same key" holds today once the
key is chosen; `effect_admission/2` and `validate_plan/2` complete it
(addendum 1, E1 and E2).

S4. **Reuse ignores the target key.** The router reuse key is
`{Owner, ProofId, TargetIdentity}` and `reusable_binding/2` wildcards
`TargetKey` and `ScopeId` (`quod_ask_router.erl:1108-1130, 1189-1194`). The
origin map likewise reuses by identity alone (S1). A second open of the
same identity with a different key is therefore silently served by the
first key. This is the one place the proposed "reject conflicting pin"
rule is not already the behaviour.

S5. **Routes know keys and roles.** Directory routes carry `node_key`,
`endpoint`, `genesis_anchor`, `role` and `status`
(`quod_directory.erl:623-645`); only confirmed validator routes are
awaited (`:184, 207-290`). Observer rows exist in simplex vocabulary but
are never selected for scopes.

S6. **A node's own ontology is created with the creating node as sole
genesis signer** (`quod_ontology.erl:480-489` in delta-02 with
`committee => []`; `quod_simplex:prepare_genesis/3` at `:3702-3715` signs
the genesis as `Self`). Whether later committee changes can make a node an
observer of its own ontology is not something I verified; today the
creating node is its validator.

## 2. The proposal against those facts

**Expressible route selection on the existing ask owner.** Correct in
shape. `do_ask/4` flattens `NsTerm` through `quod_ontology_name:flatten/1`
(`quod_ask.erl:107-114`); an `at(Key, Ns)` term is rejected as `bad_name`
today, so the parse point is exactly one function, and the scope map,
binding, authentication, chain and nested relay need no second scope. The
following constraints are what the code requires to keep its invariants.

C1. **Pin on first open only, and conflict rule.** Implement the pin at
`get_or_open_scope/2`: store the pinned key beside the `#scope{}` for the
identity; a later `at(Other, Ns)` for an identity already opened, pinned or
unpinned, is `{error, {scope_pin_conflict, Ns}}`; `Ns::G` after
`at(K, Ns)::G` reuses. Also tighten the router's `reusable_binding/2` to
compare `TargetKey`, or the origin pin can be bypassed by the router's own
reuse (S4). Never switch an active scope: both maps already forbid replacing
a live scope; the pin must not add a path that does.

C2. **Pin overrides the local preference.** `origin_scope/1` and
`open_cohosted_scope/3` must take the pinned key first: if the key is this
node and the namespace is hosted here as a validator, open local; if the key
is this node and this node is not a validator for a read-write proof, refuse
`{pinned_host_not_validator, Ns}`; if the key is another node, skip the
local engine and the directory-wide search and open only the confirmed
validator route with `node_key =:= Key` (filter before
`open_remote_routes/5`), keeping the read-only committee verification. A
missing or unconfirmed route is `{pinned_host_unavailable, Ns}`, an
infrastructure refusal that must stay distinct from absence when the
application maps it to a reasoned failure. `await_directory_scope/2`'s
"never route back to our own node" case keeps working because the pin
decides before it.

C3. **No retry after invocation.** `open_remote_routes/5` already tries
alternative routes only before any invocation; with a single filtered route
there is nothing to retry, which matches the requirement. The retry
classification `router_admission_error/2` must not resurrect another route
for a pinned open.

C4. **Nested relay must carry the pin.** The controller event `nested_open`
carries `TargetNs :: binary()` validated by `valid_namespace/1`
(`quod_scope_wire.erl:606-611`), and the Erlang relay carries the flat
namespace (`quod_prolog.erl:3571-3587`). A nested `at(K, Ns)::G` from a remote
worker needs the key in that event. That is a wire-format change to one
operation and its validator, not a broker, but it is a change and must be
called one. Since the origin already decides, a simpler alternative is to
let only the origin-side proof pin and have remote nested asks refuse
`at/2` with a typed error; that is a real restriction on application Prolog
running inside foreign scopes and should be chosen explicitly.

C5. **ACL chain unchanged.** The chain stays a list of namespaces
(`quod_ask.erl:124`); `at/2` must flatten to `Ns` for the chain, the
`TargetIdentity` and the dependency evidence (`read_dependencies/0`), so a
pin confers nothing on `can_invoke/4` and leaves the read evidence exact.
The target still authenticates the principal and applies its own policy
(`begin_remote_scope_authentication/16`).

C6. **Validator-only, under the original deadline.** Filtering to confirmed
validator routes and the existing `execution_remaining_ms/0` guards give
this. An observer-only key is therefore `pinned_host_unavailable`, never
"absent". Correct, and it also answers the receivers question below.

## 3. Correctness and security points to test

- Pin then unpinned open of the same identity reuses; unpinned then pinned
  with the local key reuses; pinned then differently pinned refuses; two
  different namespaces pinned to the same key open two scopes.
- Remote worker issuing `at/2` nested asks: either relayed with the key
  (C4) or refused with the typed error, never silently unpinned.
- Pinned key equals self on a validator and on an observer of the namespace,
  read-only and read-write.
- Pinned key not in confirmed validator routes; pinned key confirmed but
  route down; pinned key whose target engine refuses because `self` differs
  (misdirected link): all must surface as infrastructure refusals distinct
  from absence and from `anchor_conflict`.
- Router reuse with a different `TargetKey` for the same owner, proof and
  identity must be `scope_binding_conflict` after the S4 fix.
- A plan from a pinned scope signed by another key is rejected (already
  covered by `checked_remote_plan/4`; keep the test).
- Pinned scope used for a prepared effect: executor equals the pinned key,
  `effect_admission/2` passes on that node and fails elsewhere.
- Deadline exhaustion while awaiting the single pinned route.

## 4. Where the two acceptances live, with this capability

With `at/2`, the interactive presentation action can reach both executors
without any Erlang cross-node call:

- The human-facing surface is prepared in the receiver node's own ontology
  scope, `at(ReceiverKey, ReceiverNodeNs)`, as a prepared effect whose
  private payload is the accepted hidden view incarnation (addendum 3).
- The actor-facing handler is prepared in the actor host's own ontology
  scope, `at(HostKey, HostNodeNs)`, as a second prepared effect in the same
  atomic group. Its preparation is the live acceptance: the staging
  continuation consults the host's local `quod_runtime` for the responder
  namespace (`request_executor/2`, the installed catalogue, the
  Prolog-supplied allowance) and either stages the effect with the accepted
  actor incarnation (committed epoch, key, host) as immutable private
  payload or fails with a reasoned refusal. Its execution after apply
  activates that exact handler incarnation for `Q`, terminal `expired` if
  the incarnation is gone, never retry.

Two prepared effects in one group are representable: every effect-bearing
plan is bound before activation and each plan carries at most one effect
(`tree/src/quod_prolog.erl:5366-5396`, `quod_effect.erl:95-103`). The
application's Prolog policy selects `ReceiverKey` and `HostKey` from committed
state, satisfying "no hardcoded namespace-prefix routing". No liveness or
capacity value enters a diff: both bridges return success or refusal and
their payloads hold committed identities.

Reentrancy: both scopes are opened by the origin (S1); the responder scope,
which holds the question row, is a third scope with a material diff and no
live bridge. There is no re-entry into either node scope from the other.

## 5. Does the requirement imply non-validator receivers?

The receiver node is whichever node accepted the human's authenticated
connection. It need not be a validator of the application, responder or
human ontologies; those scopes are opened at their own validators by the
origin. It must be a validator of its own node ontology, which it is as that
ontology's genesis signer (S6), unless an enrolled node can later lose its
own committee, which I did not verify. A client-serving node without its
own ontology cannot host a receiver scope; that is "unavailable", not
absence, and the policy selecting the receiver scope must come from
committed state so a human connected to such a node is refused rather than
declared absent. The same applies to the actor host, which must be a
validator of its own ontology and must host the responder runtime.

## 6. Unverified

Whether a node's own ontology committee can change after enrolment; the
target-side validator gating for read-write remote opens beyond
`self = TargetKey` (I found committee checks for attestation at
`quod_prolog.erl:1357-1369`, not for every scope open); the controller
event wire extension cost in `quod_scope_wire`; all test outcomes.
