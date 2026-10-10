# Existing model audit after the architecture correction

This is a code-reading correction, not a new approved design or acceptance
receipt. Yan's gravity and permission examples are requirements to evaluate
through the existing model. They do not request a new settings or ACL system,
separate position/velocity permissions, or co-location of spaces in an ontology.

## Reuse established by the current code

- Instance identity and classes: `instance_of/2`, shared `isa/2`, and
  `space_instance/2` already describe physical-space instances. `doc/spaces.md`
  explicitly separates space identity from ontology ownership and does not
  impose one ontology or simulator per room. Class membership imports no code
  and grants no access.
- Instance properties: `quod_lobby.pl:lobby_options/2` authors `attribute/3`
  values; `lobby_instance.pl:lobby_sky/1` reads those values for a specific
  instance. `quod_environment.pl:have_attribute/3` describes their vocabulary.
  `quod_material.pl` also demonstrates derived attribute views over one domain
  relation. Physics settings can follow these existing Prolog patterns; a
  derived native resource description must not become another mutable owner.
- Invocation permissions: `quod_ask:open_authorized_scope/8` passes the complete
  requested goal, authenticated principal and call path to the target's
  `can_invoke/4`. Policy can therefore distinguish instance and operation by
  ordinary Prolog arguments. Local and remote target calls share this path.
  Authorization reads join existing conflict checks; a staged grant cannot
  authorize itself.
- Result disclosure: a public Prolog rule can call a helper and return only
  selected values. Entry authorization is not a new ACL check on every internal
  helper call. A narrow wrapper must retain existing domain checks, and raw
  state/meta-goal/source access must be governed consistently. The fact that
  `physics_body_state/3` returns both pose and velocity does not by itself
  demonstrate a missing native primitive or permission mechanism.
- Cross-ontology references: ordinary `Namespace::Goal` uses target-owned
  scopes; anchored calls additionally verify `current_ontology_identity/2`.
  Existing argument following routes interpreted predicates on `Owner:Name`
  through that same scope owner. It does not apply to compiled predicates, so
  compiled physics calls must not be assumed to follow qualified arguments.
- Native availability: `quod_committed_projection:new_est/0` already invokes
  shared `quod_predicates:load/1`. Physics is currently an optional manifest
  module, not in that common list. Evaluating common startup registration does
  not require the unapproved per-world capability-epoch proposal. Root's
  ontology catalogue remains distinct from native registration.
- Physical lifecycle: `space_place/3` and `space_withdraw/3` already use the
  entity and destination owners in one atomic transition. The authored
  `space_physical_change/3` consequence is where physics admission/removal must
  compose. Runtime selectors and retained subscription projections already own
  installation and source following; their concrete missing wiring is recorded
  in [subscription-trace.md](subscription-trace.md).

## Evidence limits

Inspected existing tests include `quod_lobby_tests` (signed instance property
editing and private lobby access), `quod_ask_tests:t_permission_gate/1`,
`quod_space_tests:distinct_owner_authorization_test_/0`, and
`quod_physics_tests:signed_live_body_predicate_test_/0`. They show the existing
production seams and obligations; no new test run was performed for this audit.
They do not establish the requested remote physics integration or live lobby
acceptance. Earlier frozen reviews do not review the corrected composition.

The earlier capability-epoch proposal was premature. Starting from the current
physics adapter's packaging and policy names obscured the existing general
model. Any next implementation plan must identify a concrete missing connection
in these owners before adding machinery, then receive the requested Fable
review. There is no new production change from this audit.
