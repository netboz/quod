# Fable delta review

Read-only review; the child ran no builds or tests. Reported test outcomes came from the parent. This review is consultative, and live deployment was not performed.

I'll diff the current tree against the tree-01 hashes to isolate the deltas, then read only those.

Two final reads: the raw-to-normalized mapping (whether any post-custody engine result can normalize to `failed`), and the two rejected-outcome shapes, since the new clause requires `height > 0`.

All deltas read against tree-01. No new production files beyond the three named; the dead fact is gone from every src, priv and test path.

**Fix 1, `node_vocabulary`.** Removed; no remaining reference outside the archived review text. Done.

**Fix 2, pre-execution allowlist.** Verified sound, and conservative where it matters.
- Every atom in the list originates before admission: `verify_request` errors (`invalid_signature`, `invalid_request`, `wrong_network`, `wrong_target`, `expired`), route lookup (`signed_target_unavailable`, `{anchor_conflict, _}`), local identity and auth (`node_identity_unavailable`, `signed_goal_unavailable`, `client_auth_unavailable`, `client_goal_busy`, `client_goal_rate_limited`), symbol materialization before the proof (`client_symbol_budget_exhausted`, `atom_limit`), the router's pre-send route busy ([quod_client_goal_router.erl:305](/home/yan/src/quod/src/quod_client_goal_router.erl:305)), and the three atoms the target itself passes through as "cannot carry durable custody" ([quod_client_goal_target.erl](/home/yan/src/quod/src/quod_client_goal_target.erl) `normalized/2`).
- Everything post-custody is shaped differently: `{outcome_unknown, _}` becomes `{normalized, {pending, _}}`, any other engine error becomes `{normalized, {error, _}}` ([quod_client_result.erl:144](/home/yan/src/quod/src/quod_client_result.erl:144)), and neither matches the allowlist, so they stay unresolved. `operation_conflict` is correctly excluded. `{failed, _}` and `fail` arise only from a proof that never sealed.
- Expiry is accepted only in `submit_retained`, which runs solely on a first dispatch of a fresh operation; `resolved_retained` rejects `{error, expired}` and the unit test pins that. A replacement after a recorded refusal is a new operation, not a resend.

**Fix 3, terminal outcome.** Correct for both lanes. `resolved_retained` accepts only `{operation_outcome, _, #{status := rejected | aborted, height := H}}` with `H > 0`. That shape comes only from the winning claim bound to these exact bytes through `resolved_operation` and then `read_outcome`: an ordinary rejection carries its slot ([quod_outcome.erl:1028](/home/yan/src/quod/src/quod_outcome.erl:1028)), covering the self-host activation, and a group abort carries its slot ([quod_outcome.erl:1051](/home/yan/src/quod/src/quod_outcome.erl:1051)), covering the atomic enroll. The effect-journal-derived rejection has no height ([quod_prolog.erl:685](/home/yan/src/quod/src/quod_prolog.erl:685)) and is therefore excluded, as are the group-selector result and absence. The ordering in `resume_allocation` applies the refusal only when no allocation exists for the key.

**Tests.** The admission-refusal stage exercises the real auth charge seam and recovers only on an auth readiness change. The retained-policy upgrade test is good evidence for the mechanism: one administrator-signed atomic transaction installs template, founder allocation, custodian hosting delegation and root delegation, the class subtree is restarted under its supervisor, the pointer is byte-unchanged, and a fresh applicant then enrolls with the founder as custodian. It is single-node and uses a freshly founded class, so it does not stand in for the live fleet's retained histories; that migration stays unapproved and unrun. The stale-generation fixture fix keeps the receiver's rejection intact.

**Contract.** The Recovery section now matches the code on refusal classes and winning-claim terminal outcomes. One wording item: it still says an unresolved pre-admission request "may require explicit recovery". Per the ruling, there is none; say it remains unresolved and visible, with no automatic or manual recovery defined. On refounding, I make no claim: whether old custody is ever retired is a separate, explicit destruction decision to be documented only if Yan asks, and nothing here deletes anything.

**Updated verdict.** The deltas resolve all three must-fix items safely for the atomic enrollment and the ordinary self-hosting transition, introduce no new authority, and keep strict no-resend intact. The tree is ready for the tree-02 freeze and the full clean sequential gates, subject to those gates and the owed report triage. Retained live-fleet migration remains unapproved.
