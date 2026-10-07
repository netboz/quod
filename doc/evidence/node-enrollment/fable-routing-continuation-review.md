Read-only Fable consultation, 2026-10-07. This reviewed the proposed continuation boundary; it did not run builds or tests.

Boundary confirmed, and the proposed fix is the right shape.

**The defect is real and latent.** `evidence_accept` at [quod_catchup.erl:853](/home/yan/src/quod/src/quod_catchup.erl:853) requires the continuation to be `done` or a 128-bit token with a positive sequence. The local adapter returns an opaque `{{local, Sender}, 1}`, so the first page of any multi-page proof fails as malformed and the probe reports retry. Single-page proofs pass because their continuation is `done`, which is why the CT never tripped it. Multi-page evidence is real for era transitions with long finality chains, since the sender pages by count and bytes.

**It is the one inconsistent receiver.** `transfer_accept` already takes `more | done`. `range_accept` only compares the continuation to `done` and never inspects the token, which is why the pre-existing local range path through the same adapter never had this problem. The fix makes the third receiver match the other two.

**No security loss.** The receiver never uses the token. Grant binding is enforced where it belongs: the page decoder checks grant, next-grant inequality, token shape and parts; the request validator checks continue tokens; the server keys pending pulls by the 128-bit id. The receiver-side check was redundant on the network path and wrong on the local path. Certificate consumption, the exact-finality verifier, height constancy across pages, quorum counting and deadlines are untouched by the change.

**Fix shape to verify in the hunk.**

- `evidence_accept/4` guards on `more | done`, drops the continuation validator from its conjunct, keeps the parts validator, and its two completeness clauses test `End =:= done`.
- `fetch_evidence_pages` maps `done` to `done` and any `{Token, Sequence}` to `more` inside the consume fun, and still recurses with the original `{continue, Token, Sequence}` query.
- `valid_transfer_continuation` stays, since the decoder and request validator still use it. `range_accept` and `fetch_range` unchanged.
- Height constancy across local pages holds because every page reports the last index of the same read-only snapshot.

**Tests.** The existing helper at [quod_catchup_tests.erl:445](/home/yan/src/quod/test/quod_catchup_tests.erl:445) fabricates a fake token for the receiver; it should pass `more` after the fix. The regression must drive at least two pages through the local adapter, because the production local branch is unreachable from unit fixtures that inject a fetch fun: build a store whose evidence spans more than one transfer page, run `fetch_evidence_pages` with a local fetch over `local_view_fetch`, and assert a verified result. Keep one negative asserting the page decoder still rejects a non-128-bit token.

Verdict: approve the boundary fix as described, pending the frozen hunk, the multi-page regression, and fresh gates. This is the same scope, not a new one.
