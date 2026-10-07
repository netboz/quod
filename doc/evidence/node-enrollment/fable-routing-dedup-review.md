Evaluation of your dedupe rule, then the complete findings 1 to 5 for the archive.

**Evaluation: the rule is correct, and prefer-subscriber is the only direction that works.** I re-checked the acceptance code. A page arriving on a direct link is accepted only when its signing node key and endpoint equal the sending peer's, so third-party relays over our outbound control link are rejected at the remote. A page arriving on the remote's own outbound link is accepted for any author as long as that link is the remote's current control link to us. So between two control peers, only the stream the remote opened can carry relays. This also means third-party relay between roots never worked before this diff. The subscription is now the real relay path, which the new doc paragraph already states.

Points to carry into the implementation:

- **Exclude the outbound link only when an eligible downstream stream exists for that key.** Downstream is already empty when we are not a control peer, so non-root nodes keep publishing their own pages over outbound links unchanged. If the peer's inbound stream died and it has not redialed, falling back to the outbound link still delivers our own-authored pages, which is the only thing that link could ever deliver.
- **Keep every distinct subscriber stream for the same key.** The remote accepts pinned-link pages only from the link process that is its current control link, so copies on a stale stream are dropped before validation. No repeated validation there, and the window closes when the old stream resets.
- **Skip keys apply across both classes.** Unchanged and correct.
- **Ordering improves.** Snapshot reply and later pages now share one stream for peers that subscribed, instead of being split across two.
- **Test to add with the fix.** Same key with outbound link and subscriber: one send, on the subscriber stream. Outbound link only: one send, on the outbound link. Plus the negative case from finding 3.

**Complete findings for the frozen scope tree-01, patch sha256 15978b14…**

Scope verification: all six files hash to the manifest, the patch equals the git diff, the foreign-log and catchup hunks are byte-identical to the first review. Directory control gained only the subscriber count stat. The routing doc records the subscription contract and the local answerer rule. Gates-01 reached eunit when you set the stop marker. Remote-02 CT passed including the cost fixture. No rollout approval was given.

Causal diagnoses, checked independently:

- Directory expiry is real. Root's live stats show one control peer and zero outbound links. Root's own renewals and relayed client generations went only to control links, so root published to nobody. Clients requested a resync only on link install or route demand, so their cached root snapshot lapsed. Subscribe-then-snapshot in the same owner turn is the correct model and matches the routing doc ordering rule.
- Sole-custodian current tip is real at the observable level. Custodian trace: retry after the full budget. Third party: success in 14 ms with a one-member committee. The founder trace shows every validation on the custodian returning retry. The fix routes the self answerer through the existing local view seam with the same evidence receiver, so verification and quorum counting are unchanged.

Finding 1, duplicate delivery between control peers, recommended fix, being applied. With two or more control peers, each holds an outbound link to the other and now also retains the other's inbound stream as a subscriber, so every page reaches the peer twice. `validate_remote_generation` performs no high-water check before validating, so the second copy, arriving after the first validation was removed, spawns a full validation worker again including current-tip probes, and is rejected only at install by the high-water rule. New repeated I/O introduced by this diff, invisible on the single-root live cluster. Fix at [quod_directory_control.erl:1009](/home/yan/src/quod/src/quod_directory_control.erl:1009): when folding control links into recipients, drop the outbound link for any key that has an eligible downstream subscriber stream, per the rule evaluated above.

Finding 2, cost fixture can be vacuous on the local probe path, minor. The assertion that each local probe opened one snapshot reader holds trivially when the resident tip answered both checks with zero probes. The first wait in the case still exercises the local answerer functionally, so coverage exists, but the cost bound on that path is not proven by this fixture. Note it in the evidence file.

Finding 3, missing negative unit test, minor. No assertion that a node with a known root proof that is not a control peer neither retains a resync requester nor fans out to it. That is the gate the comment and the doc promise. The lifetime test covers self as control peer, duplicate subscribe, two forwarded generations including withdrawal, stream death, and revocation only.

Finding 4, injected ticks leave extra renewal chains, minor. The two injected ticks at [quod_ask_SUITE.erl:224](/home/yan/src/quod/test/quod_ask_SUITE.erl:224) and line 232 each re-arm a timer, so both nodes run doubled renewals for the rest of the suite. Harmless to the outcome. The natural renewal interval fits inside the wait budget.

Finding 5, open follow-up outside this scope. No transport code refuses an own-key pinned open, and the page binding waits until the pull timeout, so the transport-level reason a self-dial pull burns its whole deadline is unexplained. Range advancement and other self-peer pulls that do not pass through fetch_evidence still take the network. Either fail fast on own-key opens or route all self pulls locally.

Security and correctness checks that passed:

- Authorization: subscribers get delivery only. Ingest still requires node key equals link peer key and, for bootstrap authors, control membership. Fan-out is gated on installed root authority, and revocation clears subscribers.
- Lifetime: subscriber monitors are removed on stream death, on revocation, and in cleanup. Inbound link processes live per stream. A directory-control restart resets peer-opened streams, so clients re-subscribe through the existing resync on reinstall.
- Startup: pre-proof retention plus the send gate means nothing is sent before authority is known. A failed first proof leaves the height undefined and the gate closed.
- Foreign log: the self branch ignores supplied endpoints, so routes cannot steer it. The local path only triggers when the local key is a candidate, which the collector filters by the certified committee. The snapshot is opened once per evidence call and closed after all pages, with no writes. Continuation tokens round-trip correctly through the shared opener, which both the serve path and the local fetch use.
- Unit fixture now seeds the control-peer root fact so the proof query and the test state agree.
- Production delta is small and adds no process or timer.

The stop notification script is still missing from its path, so no desktop alert was sent.
