**Verdict: corrections accepted. Approve for the final exact-tree gate.** All four of my findings are closed in the frozen tree, the Nomad provisioning is consistent with the schema, app startup and vault init, and the retained corrections run shows 104 tests with 0 failures and a true child exit 0. This is not a release or deployment verdict.

**Verified against the frozen tree**

- One node-reference owner: `quod_node_actor:reference/0` is the only materialization; the bridge, `quod_agent:current_node/2` and `quod_runtime:local_node_reference/0` all call it. The post-vault destination check at `tree/src/predicates/quod_agent_predicates.erl:112` now states its reason.
- Vault uncertainty is narrowed to `custody_mutation` wrappers around write, link plus sync, and delete plus sync. Unchanged repeats are one read and two stat calls. The flag is carried in the returned state regardless of the expired-reply branch at `tree/src/quod_agent_vault.erl:132`. The recovery trace test proves exactly one sync then no I/O.
- Prolog: `agent_preparation_assignment/3` alone owns the exact-assignment check. The `prepare_agent_key` action, the base policy and the helper's positive clause all require a positive epoch. The new grant test proves an explicit `none, 0` grant still cannot publish a candidate and produces no diff. The runtime scope guard still refuses epoch zero before any of that.
- Deployment: the rendered HOCON supplies only the three keys; `quod_schema` defaults fill ip, port, peer_keys and TLS fields, so the map match in `apply_agent_vault` succeeds with provider none. Vault init accepts the file the script guarantees: regular, 32 bytes, no group/other bits, outside the vault directory. The quod task runs as root like the prestart container, so a root-owned 0600 file is readable. The script tools exist in the trixie runtime image. Secret bytes never reach output.
- No live caller of the old four-argument policy or of `generate/1` remains.

**Blockers (missing evidence, not code defects)**

1. **Final exact-tree gates on this corrected tree.** The corrections run covered seven EUnit modules only. It did not re-run `quod_physics_tests` (the real signed-ingress `none, 0` path and the two-destination race), `quod_lobby_tests`, `quod_common_primitives_tests`, CT, dialyzer or xref. Those must pass on the committed tree before any release claim.
2. **No boot evidence for the enabled vault.** The vault child in `quod_sup` stops the whole node on any unlock or directory problem. My static trace passes, but no retained run shows the release starting with `agent_vault.enabled = true` against a prestart-provisioned file. One container boot with the rendered config closes this before the rolling deploy.

**Optional follow-ups**

- The script accepts only mode 600 while the vault accepts any mode without group/other bits. An operator-supplied 0400 key would be refused at prestart. Align or document.
- If the script dies between `ln` and `rm`, a second hard link to the secret remains forever, since later runs skip the creation branch. Keeping the trap armed until after the `rm` removes that window for catchable exits.
- `agent_recovery_data` still proves `agent_hosted` twice (its own line plus the helper's positive clause), and the positive-epoch test repeats three times along the action path. Harmless, purely tidy.
- Signing-policy discipline remains the separate follow-up already recorded.
