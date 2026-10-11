I have everything I need. Writing up the review now.

**Verdict: no blockers found. The composition goal is safe to submit in the existing signed world, under one condition stated below.**

**What I verified against the frozen tree**

- **Clause fidelity.** All 23 clauses of `priv/ontologies/space.pl` appear in `compose-space.prolog` in file order with matching bodies, including the `->`/`;` nesting, `\==`, `is`, `findall` and `Ns::(...)` shapes. The 20 guarded indicators equal the usort of the non-isa heads.
- **Variable isolation.** V0 to V110 are used in strictly increasing per-clause blocks. No variable from an earlier clause reappears in a later one, and the first goal and the guards bind no `V` variable, so every asserted clause is closed over its own variables.
- **Anchor literal.** The `\xHH\` form is exactly what the frozen lexer requires (`quod_client_goal_parser.erl:554-564` demands the closing backslash). I decoded all 32 escapes and they equal the anchor hex in `missing-space-composition.json`. The namespace literal is the committed `human:.../lobby` name.
- **Guards.** `'$quod_predicate_source'` reads through `authored_state` (`quod_erlog_db_local_prove.erl:476-478`, follow disabled), so the generated routing clauses on `space_instance/2` do not count as source. `\+ clause(isa(space,thing), true)` only matches authored facts since the shared isa rules and following clauses have non-`true` bodies. The repeat run therefore fails on the guards and writes nothing, as the test asserts.
- **Authorization.** `lobby_instance.pl:4` grants the owner any goal. doc/spaces.md §Invocation policy explicitly treats an unrestricted administrative ACL as authority for source editing. The bundle itself installs no `can_invoke`, all `can_*` and `space_physical_change` defaults are `fail`, and `personal_lobby` is a `space`, not a `physical_space`, so no physical path is reachable.
- **OCC.** The guards put 21 functors in the read set and the asserts write 21 functors in one `transaction/1`. Any concurrent edit to those functors conflicts on version tokens. Nothing in the goal depends on time or node state.
- **Cold-node symbol path.** The parser leaves every non-operator opaque. `prepare_materialized` decodes the goal blob (`quod_client_goal_target.erl:136`), which resolves names that already exist as atoms in every position, and the target scope materializes callable heads/bodies (`quod_ask.erl:1477`). About 20 new atoms are needed, against 512 per request and 16384 cumulative. Data-only names stored opaque in the overlay are materialized when the ledger applies in `materialized` mode, with identical wire bytes. The test VM already has these atoms, so the test does not exercise this path, but the code does what the design says.
- **Size.** The goal text is far below the 128 KiB top-level limit.
- **Test.** `authored_space_composition_preserves_world_test_` founds the lobby without `instance_of(lobby, personal_lobby)` and adds it with the two other production facts, so the pre-composition state matches the evidence JSON. `quod_reg:via/1` and `quod_runtime`'s `physics_worlds` call both exist and return what the test expects.

**Condition for submission**

The file is a bare conjunction. Its anchor fence only takes effect if the client submits it inside the lobby scope, as the test's `editor_scope` does with `Ns::(...)`. Submitted unwrapped in the agent namespace, the first goal fails and nothing is written, so the failure mode is safe. I could not verify the native client's wrapping because `client/native` is outside the frozen tree.

**Non-blocking notes**

- Symbol rate limits are opt-in (`quod_client_auth.erl:177-179`). If the fleet config sets a symbol limit below roughly 25 per request, admission is refused with `rate_limited` and nothing is written. Worth a glance at the node config before the live attempt.
- The reply will echo 111 unbound variable bindings. Cosmetic only.

**Next step:** submit once from the signed desktop console with the personal lobby selected, then re-read `client_world_view` and expect `nonphysical` with the six marks.
