> Subsequent status: user explicitly authorized this exact patch; it was applied with every before/after hash verified. See `inputs/carrier02-user-authorization.json`, `inputs/carrier02-application.json` and current RESULTS.md. The original proposal-state text/manifest below is retained as historical evidence, not current application status.

# Unapplied carrier/custody correction

Exact proposal: `carrier-custody.patch`, +27/−61 production lines (net −34). `manifest.json` binds before/proposed bytes for four existing owners. It is **unapplied, uncompiled and unexecuted**. `inputs/carrier02-apply-check.json` records only read-only patch applicability. No approval is inferred from that check.

Yan already authorized removing arbitrary resource limits. A subsequent automatic review rejected the combined edit before execution; `inputs/carrier-edit-rejected-command.json` preserves the original tool command and `inputs/carrier-edit-rejection01.json` preserves its literal reason and current hashes. This proposal makes the remaining action narrower and reviewable; it does not reinterpret Yan's authority as limited to128/512KiB. The parent is obtaining the required explicit approval. Do not execute the rejected command or apply this patch while that request remains pending.

| Owner | Correction | Preserved guarantees |
| --- | --- | --- |
| `quod_scope_wire` | Retire derived material subquotas; use actual32-bit link capacity for complete envelopes. | Canonical atom-safe decoding, identities, authorization chain, exact generations/IDs, error classification, pinned proof/material policy. Existing finite Erlog diagnostic allowances remain explicit. |
| `predicates/quod_ask` | Decode canonical already-authorized invocation without duplicate plan-envelope byte quota. | Full caller/target authorization chain, materialized goal checks, cancellation and original deadlines. |
| `quod_signing_journal` | Retire inherited body/control/block quotas; use actual32-bit disk-frame capacity; remove unreachable reader size branch. | Signatures, canonical bytes, magic/CRC, exact identity/custody, torn-tail handling, append/sync and recovery semantics. |
| `quod_dtx_phase_index` | Remove derived history-byte quota and duplicate checks. | Exact byte accounting, group identity, fixed Vote/Resolve/Complete phase semantics, certified reference validation/order, atomic delta commit and persistence. |

No new resource default, registry, transaction split, consensus relaxation, optional heap policy, deadline extension or historical rewrite is proposed. Allocation still belongs to existing committed Prolog material/proof policy; these guarantees do not imply that raw ingress or shared offheap binary memory is charged to finite heap allowances.

## Verification after approval

Use separately labelled real-owner failing baselines and exact current source inputs. Scope/ask: complete binary-heavy goals and material/control replies beyond former quotas, canonical malformed inputs, denied grants, cancellation, stale generation and exact request/cursor identities. Journal: large signed vote/control/transaction material, append/reopen, corrupt CRC, torn tail, valid signature/identity refusal and unchanged lookup I/O. Replace the obsolete test that equates a derived quota with a format bound; do not allocate4GiB to test a uint32 field. Phase index: valid certified history beyond the former derived byte quota, exact three phase ordering, bad references/group identities, commit/reopen, unchanged reads and byte accounting. Then affected signed large composition through real owners, including denial/revocation/stale/update/reconnect/cycles and the original unchanged-work acceptance. Keep full child exits/EOF and all failures; do not expand observation deadlines.

This patch does not complete the no-hardcoded-limits request. Still inventoried: foreign pages900KiB/256entries, derived durable/ingress byte and pending-count quotas, committee64, namespace255, callable/cumulative atom512/16384 and VM reserve, direct-effect byte2048, and pinned diagnostic dependency quotas. The retained three-phase protocol and actual signature/identity/length widths are semantic or representability constraints, not interchangeable with those resource budgets. See `remaining-correction-inventory.md` and `remaining-owner-design.md` for current scope; no bootstrap-policy choice remains.
