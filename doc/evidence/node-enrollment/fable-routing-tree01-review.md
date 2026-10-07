Final findings for the frozen scope tree-01.

**Verification of the scope.** All six working-tree files hash to the manifest in tree-01.json, and the patch file equals the current git diff (sha256 15978b14…). The foreign-log and catchup hunks are byte-identical to what I reviewed earlier. Directory control gained only the subscriber count stat. The routing doc now records the subscription contract and the local answerer rule. Gates so far: the two clean steps exit 0, eunit still running, remote-02 CT passed with the cost fixture. No rollout approval until the full sequential gates are green.

**Verdict: approve the scope for commit once gates-01 is green. No blocker. One recommended fix, which I would still make now if a re-freeze is cheap, otherwise before any deployment with more than one root control peer.**

**1. Duplicate delivery between control peers triggers repeated validation. Recommended fix.** With two or more control peers, each holds an outbound link to the other and now also retains the other's inbound stream as a subscriber. Every page therefore reaches the peer twice. I verified that `validate_remote_generation` does no high-water check before validating, so the second copy, arriving after the first validation was removed, spawns a full validation worker again, including current-tip probes, and is only rejected at install by the high-water rule. That is new repeated I/O introduced by this diff. It is invisible on the live single-root cluster. Fix at [quod_directory_control.erl:1009](/home/yan/src/quod/src/quod_directory_control.erl:1009): when folding control links into the recipients map, drop any subscriber entry whose node key equals that link's key. One clause, no new concept.

**2. Cost fixture can be vacuous on the local probe path. Minor.** The assertion that each local probe opened one snapshot reader holds trivially when the resident tip answered both checks with zero probes. The first wait in the case still exercises the local answerer functionally, so coverage exists, but the cost bound on that path is not proven by this fixture. Worth a note in the evidence file rather than a code change.

**3. Missing negative unit test. Minor.** Still no assertion that a node with a known root proof that is not a control peer neither retains a resync requester nor fans out to it. That is the gate the comment and the doc promise.

**4. Injected ticks leave extra renewal chains. Minor.** The two injected ticks at [quod_ask_SUITE.erl:224](/home/yan/src/quod/test/quod_ask_SUITE.erl:224) and line 232 each re-arm a timer, so both nodes run doubled renewals for the rest of the suite. Harmless to the outcome.

**5. Open follow-up, not in scope.** The transport-level reason a self-dial pull burns its whole deadline is still unexplained. Range advancement and other self-peer pulls that do not pass through fetch_evidence still take the network.

**Checks that passed on the frozen tree.** Authorization unchanged for ingest. Subscribers are delivery-only and gated on installed root authority. Monitors are cleared on stream death, revocation and cleanup. The unit fixture now seeds the control-peer fact so the proof query and the test state agree. The local answerer ignores supplied endpoints, opens one read-only snapshot per evidence call, and verifies through the same receiver. Doc update covers the new contract. Production delta is small and adds no process or timer.

The stop notification script is still missing from its path, so no desktop alert was sent.
