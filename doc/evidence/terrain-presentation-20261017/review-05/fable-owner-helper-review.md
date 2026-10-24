Reading the owner-helper brief, manifest and delta.

Checking the goal text admission bound, the harness write path and the preparation goal shape.

All items are in hand; nothing further to read. Complete report follows.

References are to `doc/evidence/terrain-presentation-20261017/owner-appearance-acceptance-06.mjs`, the retained records under `_build/terrain-presentation-20261017/owner-appearance-01` and `owner-appearance-02`, and the unchanged production tree. Inspection was read-only: file and patch reads, hash recomputation of the seven manifest files and JSON summaries of the prepared goals. No command, test, build, edit, memory update, delegation or deployment. All seven manifest entries match on disk.

## Verdict

The correction addresses the actual cause and is structurally right. The failed write at `owner-appearance-01.log` was refused by `submitDurable` with `result_too_large`, which is the durable result encoding at the client goal boundary, reached through `encode_proof_submission` before any plan is registered, so nothing was committed; preparation02 then confirmed no unresolved operation. Helper06 moves compilation into a signed read, executes the returned compiled goal as one transaction, and derives the portable owner request from that same compiled term. I found no confirmed issue in the helper or in the two generated requests. The write has not run; limitations are listed below.

**Durable-result cause, fixed by construction.** Results carry only the request's named variables, per `src/quod_client_goal.erl:523-540`. In the old request those included `E0` and `E1`, each a whole compiled source edit. In the new write goal at `owner-appearance-02/prepared.json` the compiled edits are literal terms, and the sixty-eight named variables are either unbound clause variables or small state values: the principal, the world, view, resources, vocabulary identity and a six-material palette. That stays far below the 16 KiB bound at `include/quod_proof_limits.hrl:37`. Goal text is 10,859 bytes against a 128 KiB text bound at `include/quod_client_goal_limits.hrl:9`.

**Compilation and execution boundary.** `owner-appearance-acceptance-06.mjs:64-71` splits the reviewed request only at the literal `call(E0),call(E1),` seam, keeps the compiler calls in a read, and binds `Apply` to `transaction((E0,E1,state))` as data; the preparation goal contains no `call`, so the read executes nothing. The read also binds the lobby namespace and anchor from `lobby_reference`, which is why the compiled term carries concrete identities. The compiled edits took the direct target form, with no `system_prolog_edit` wrapper, consistent with `priv/ontologies/quod_prolog.pl:181-198` for a user-owned target.

**Atomicity.** The write is `transaction((transaction((E0,E1,L::state)),cleanup))`: both source edits, the appearance state and the Distant Heights fixture retraction commit together or not at all. Multiple write blocks to one lobby inside one transaction is the shape that the shared vocabulary edit already committed through execute05. The state block reads the palette from the pinned vocabulary, so it does not depend on seeing the just-edited clause.

**Variable identity.** The server's canonical printer names every distinct variable `V0` to `V68` with no anonymous variables, `client/src/prolog-read.js:71-73` maps equal names to one variable, and the printer re-emits them consistently. Shared variables such as the selected world `V8` and the palette `V22` keep their identity across the compiled and state parts.

**Guard scope.** The prepared state body retains owner check, unique target label, the exact old six-colour palette, absent world sky, personal brightness exactly 120, absence of the derived rule, and `voxel_validate_presentation`; the compiled edits retain their `edit_conflict` and `edit_not_representable` guards. A customised world, a changed brightness or a drifted source fails closed.

**Portability.** `generalize` at lines 73-82 replaces only whole binaries equal to the fixture lobby namespace or anchor and the exact label. The portable text binds `OwnerLobby` and `OwnerAnchor` through `lobby_reference`, references them seven and four times as expected, contains no fixture namespace, no `Highland Retreat`, exactly one `Wild Realm`, and no cleanup retraction. Yan's lobby must still hold the same 0.7.273 baseline sources and brightness 120; otherwise the guards refuse, which is the intended behaviour.

**Unresolved operations.** Lines 26-28 are unchanged: pending operations are resolved first and any remaining one blocks submission. `--prepare-only` at line 94 writes the prepared and portable files and submits nothing.

## Confirmed issues

None.

## Limitations

- **No write has run on helper06.** The size argument is by construction from the printed goal; the parent's own-account execution is the first real check, and its post-state read at lines 101-103 remains the proof that textures, sky, brightness and the derived rule actually took effect.
- **Baseline equality is assumed, not verified, for Yan's lobby.** The compiled before-source guards and the brightness guard are exact, so a mismatch refuses rather than corrupts, but the portable request has not been proven against his lobby's current source.
- **Parser acceptance of both texts** is reported by the parent from preparation02; I did not re-parse them.
- **Canonical printing of binaries** in the portable file uses escaped byte literals; it is intended for the Prove/Accept UI as prepared text, not for hand editing.
- This review is consultative, not approval; production, gates and deployment are out of its scope.
