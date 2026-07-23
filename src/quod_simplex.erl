-module(quod_simplex).
-moduledoc """
Per-namespace **DispersedSimplex** Byzantine consensus — quod's ordering layer,
replacing the earlier hand-rolled Raft ledger. One consensus instance per
namespace; the committee (validator set) is the set of **`peer_admitted` FACTS**,
derived from the committed log — asserted in the genesis block at bootstrap, then
changed by committed transactions whose diff asserts/retracts `peer_admitted`
(adopted live, in-process, at the slot boundary). The KB (`quod_prolog`) is the
other projection of the same log; the two never drift. See the approved plan and
`doc/simplex_extended.pdf` (§2 = the spec).

## The protocol (per slot `v`)

The leader for slot `v` proposes a `#block{}`. Each validator, in order:

- broadcasts a **support** share → a `⅔` **support certificate** *notarizes* the block; move to `v+1`;
- broadcasts a **commit** share → a `⅔` **commit certificate** *commits* the block — final, permanent.

If slot `v` does not finish before a `Δ_timeout`, a validator broadcasts a **complaint** share → a
`⅔` **complaint certificate** *skips* `v` and everyone moves on. That is the entire view-change.

**Safety** rests on one guard: a validator issues a *commit* share for `v` only if it has issued NO
*complaint* share for `v` **nor for its parent `v-1`** (and, symmetrically, complains `v` only if it has
committed neither `v` nor its child `v+1`). Because a commit **implicitly finalizes the approved parent**
(the depth-1 pipeline, below), this one-slot-wider guard is what keeps a slot from carrying both a commit
cert (its own OR its child's) and a complaint cert: any two `⅔`-quorums overlap on ≥1 honest party, who
would then have both complained `v` and committed `v` or `v+1` — impossible. Hence a committed block is
unique and irreversible. Everything is plain **Ed25519**: a certificate is a bag of `⅔` signatures,
self-verifying against the validator set — which is exactly the P2 relayed-commit proof a subscriber checks.

The runtime keeps two frontiers: **approved** (support-certified, safe to extend) and
**committed** (durable and externally visible). Leaders micro-batch ordered transactions
into one block and may build one child over an uncommitted approved parent. A child commit also
finalizes its approved parent; catch-up persists and verifies that implicit proof. Committee
transactions are singleton barriers, so a voting-set change is explicitly committed before
the next proposal opens.

Ingress is **park at the future leader, don't reject**: the rotation is a pure function of
the slot, so an author sends each change ONCE to the leader of the first slot it can still
enter — pre-positioned while the current slot's consensus is in flight — and that node
parks anything arriving within `?INGRESS_HORIZON` slots of its turn in a bounded FIFO
ingress queue. The queue drains — event-driven, from the universal transition hook — the
moment the holder's slot opens, straight into its batch (a multi-item drain seals
immediately: block N+1 carries what arrived during block N, already in place). Only a
genuine misroute — the schedule moved past the holder — redirects back through the author
with a concrete forward hint; a membership barrier parks unconditionally, since the
post-adoption schedule is unknowable. `{error, busy}` therefore only means queue overflow
or the ingress TTL cutting a genuinely stalled item loose — an alertable overload signal,
not routine backpressure — and the relay retransmit timer is demoted to a lost-frame
backstop (the terminal reply is the event).

One explicit `head_progress` state watches the oldest non-final slot (`committed+1`) through
`awaiting_proposal`, `awaiting_notarization`, and `awaiting_commit`. Notarization changes phase; it
does not cancel the watchdog. Complaint signing pauses while fewer than a certificate quorum have
authenticated inbound consensus streams carrying fresh, height-compatible readiness reports. The first
three quorum restorations for one unchanged phase start a fresh full Delta; later flaps cannot extend its
deadline. A member that accepted a proposal while recovering runs that held proposal through the normal
support or membership-verdict path once ready.

Every first support or final-vote decision is appended and synced through `m:quod_vote_journal`
before its signature can leave the node. Restart therefore reloads the same one-support and
commit-versus-complaint decisions instead of creating a second vote. One decision table owns every
first final vote in both live pipeline slots: `f+1` visible peer complaints select the skip camp;
otherwise a notarized block selects commit, while only the watchdog or an invalid-membership verdict may
create a complaint without amplified evidence. A member that has a support certificate but lacks the
corresponding block rotates point-to-point requests through certificate signers and then other committee
members, and accepts a response only after checking the certificate, block hash, parent, timestamp, payload,
and local final-vote compatibility.

These rules recover the observed mixed-camp and proposer-loss outages without copying the KB or
persisting full proposals. The Byzantine safety model remains `<=f`; durable latches additionally
preserve honest voting behavior across any number of process restarts. Recovery after a temporary
`>f` crash outage is a liveness extension, not an unconditional theorem: a final-vote split formed
before either side's `f+1` evidence becomes visible still needs a future view-change protocol, and a
commit side cannot reconstruct a lost block unless at least one holder survives.

The same engine handles N=1 and multi-validator namespaces, complaint-certified skips,
trustless catch-up, observer promotion, live member recovery, and deterministic Prolog apply.
Every non-genesis transaction is namespace-bound and Ed25519-signed by its author,
and every wire transaction is checked before an honest validator votes for it.
Remaining security work, notably author-aware authorization, epoch-frozen validator sets, and the
residual simultaneous final-vote split above, is tracked in `doc/deferred.md`.
""".

-include("quod_ledger.hrl").

-define(MAX_SLOT, 16#FFFFFFFFFFFFFFFF).   %% share_bytes/3 signs slots as unsigned 64-bit integers

-behaviour(gen_statem).

%% Pure consensus core (also used by the gen_statem below, the catch-up verifier, and the tests).
-export([quorum/1, leader/2,
         block_hash/1, block_from_entry/1, share_bytes/3,
         make_share/4, verify_share/1,
         form_cert/5, verify_cert/2,
         may_commit/2, may_complain/2, well_formed_block/1, well_formed_cert/1,
         well_formed_transaction/1, valid_history_entry/4,
         committee_delta/1, apply_committee_delta/2]).   %% committee = projection of peer_admitted facts

%% Per-namespace consensus process — API + gen_statem callbacks.
-export([start_link/2, append/2, rebuild/1, status/1, committee/1, genesis_hash/1, stats/1, namespaces/0]).
-export([init/1, callback_mode/0, running/3, terminate/3]).

-ifdef(TEST).
%% consensus-engine surface driven by eunit (the #eng record is otherwise private)
-export([eng_new/2, eng_offer/2, eng_prune/2, eng_tree/1, eng_committed/1, ts_acceptable/3,
         prune_dials/2, membership_change_ok/2, change_acceptable/2, complaint_amplified/3,
         admitted_endpoints/1, persisted_cert/4, eng_evict_final/4, eng_set_validators/2,
         ahead_cert_ceiling/1, eng_with_certs/2, eng_buffered_commit/4,
                                                     %% Slice 1: the gap detector's pure core
         is_participant/1, may_vote/1, caught_up/1, may_lead/1, should_sync/1, syncing/1, confirm_live/1,
         initial_sync/1, tip_quorum/3, maybe_arm_sync/1, pace_tick/1, arm_ready/1, backoff/1,
         recovery_failed/1, may_sink/2, reset_pace/0, approve_block/2, finalize/2,
         catchup_origin/1,
         test_state/1, test_arm/1, test_sync/1,
         restore_vote_rounds/1,
         proposal_slot/1, acceptable_payload/2, needs_hint_warm/2,
         reconcile_head_progress/1, resume_ready_rounds/1, resume_ready_slot/2,
         on_progress_timeout/2, progress_timer_actions/2, watch_requested/2,
         settle_readiness/2, prune_consensus_links/1,
         dispatch/3, reconcile_block_requests/1,
         test_progress/1, test_progress_rearms/1, test_support_grace/1,
         test_round/2, test_requested/1,
         test_progress_counts/1, test_committed_store/1, test_link_peers/1,
         test_redrive_head/3, test_block_requests/1, test_vote_journal/1,
         test_append/3, test_relayed_append/3, test_ingress/1, test_drain/1,
         test_expire_ingress/1, test_state_set/3, test_relay_pending/1,
         test_relay_result/4, route/4,
         proposal_visible/2, reseat_engine/2,
         stats_map/1, encode/2]).   %% encode/2: the `{log, Ns}` wire frame — used by simplex_SUITE to inject a crafted propose
-endif.

%% These validate records decoded from UNTRUSTED peer input (binary_to_term yields any term, so a
%% typed record can still carry malformed fields at runtime). Dialyzer trusts the declared field types
%% and consequently marks their reject branches unreachable; weakening the canonical record types would
%% hide useful mistakes everywhere else.
-dialyzer({nowarn_function, [dispatch/3, well_formed_block/1, well_formed_share/1, well_formed_cert/1,
                             valid_read_check/1, valid_diff/1, committee_transaction/2,
                             transaction_endpoints/1, proper_signatures/1, proper_list/1,
                             change_acceptable/2]}).

%% A node's SIGNING identity: the subset of `t:quod_identity:identity/0` consensus needs (pubkey +
%% private key), without the TLS cert. `make_share/4` signs with `key`; the share's signer is `pubkey`.
-type signer() :: quod_identity:signer().

%%%===================================================================
%%% quorum
%%%===================================================================

-doc """
The certificate quorum for a validator set of size `N`: `N − f`, where `f = ⌊(N−1)/3⌋` is the
Byzantine bound (`N = 3f+1` tolerates `f`). `N=1 → 1`, `N=4 → 3`, `N=7 → 5`. Any two quorums overlap
on ≥1 honest validator — the intersection property the whole safety argument rests on.
""".
-spec quorum(pos_integer()) -> pos_integer().
quorum(N) when is_integer(N), N >= 1 ->
    N - (N - 1) div 3.

%%%===================================================================
%%% block hashing + the bytes a share signs
%%%===================================================================

-doc "A block's content hash (sha256 over its deterministic ETF) — what support/commit shares bind to.".
-spec block_hash(#block{}) -> binary().
block_hash(#block{} = B) ->
    crypto:hash(sha256, term_to_binary(B, [deterministic])).

-doc """
The canonical bytes a share is signed over: a 1-byte **domain-separation tag** (so a `support`
signature can never be replayed as a `commit` or `complaint`), the slot, and the bound block hash
(empty for a slot-only `complaint`).
""".
-spec share_bytes(support | commit | complaint, slot(), binary() | none) -> binary().
share_bytes(Kind, Slot, BlockHash)
  when is_integer(Slot), Slot >= 0, Slot =< ?MAX_SLOT ->
    BH = case BlockHash of none -> <<>>; H when is_binary(H) -> H end,
    <<(tag(Kind)):8, Slot:64, BH/binary>>.

tag(support)   -> $S;
tag(commit)    -> $C;
tag(complaint) -> $X.

%%%===================================================================
%%% shares
%%%===================================================================

-doc "Build and Ed25519-sign one share of `Kind` for `Slot`/`BlockHash` with this node's signing key.".
-spec make_share(support | commit | complaint, slot(), binary() | none, signer()) -> #share{}.
make_share(Kind, Slot, BlockHash, #{pubkey := Pub, key := Key}) ->
    Sig = quod_identity:sign(share_bytes(Kind, Slot, BlockHash), Key),
    #share{kind = Kind, slot = Slot, block_hash = BlockHash, signer = Pub, sig = Sig}.

-doc """
Is a share well-formed AND its Ed25519 signature valid for its own signer? Well-formed = the right
`block_hash` shape for its kind (a 32-byte hash for `support`/`commit`, `none` for `complaint`) — so a
malformed share (e.g. a complaint carrying a hash, or a support with a bogus-length hash) is rejected
before it can be aggregated. (Set-membership is checked separately, in the cert functions.)
""".
-spec verify_share(#share{}) -> boolean().
verify_share(#share{kind = K, slot = Sl, block_hash = BH, signer = Signer, sig = Sig}) ->
    is_slot(Sl)
        andalso valid_signer_signature(Signer, Sig)
        andalso valid_shape(K, BH)
        andalso quod_identity:verify(Sig, share_bytes(K, Sl, BH), Signer).

%% A share/cert is well-formed iff its block_hash matches its kind: a 32-byte block hash binds a
%% support/commit; a complaint is slot-only (`none`). Guards the trustless path against malformed input.
valid_shape(complaint, none) -> true;
valid_shape(K, BH) when (K =:= support orelse K =:= commit),
                        is_binary(BH), byte_size(BH) =:= 32 -> true;
valid_shape(_K, _BH) -> false.

%%%===================================================================
%%% certificates
%%%===================================================================

-doc """
Form a certificate from a pool of shares: keep the shares of the SAME `(Kind, Slot, BlockHash)` that
are from **distinct validators in the set** and whose signatures verify; if that reaches `quorum(N)`,
return `{ok, #cert{}}`, else `{error, insufficient}`. A Byzantine node's duplicate/extra shares can't
inflate the count — signers are deduplicated.
""".
-spec form_cert(support | commit | complaint, slot(), binary() | none, [#share{}], [node_id()]) ->
          {ok, #cert{}} | {error, insufficient}.
form_cert(_Kind, _Slot, _BlockHash, _Shares, []) ->
    {error, insufficient};                       %% no validators yet ⇒ no quorum (never quorum(0))
form_cert(Kind, Slot, BlockHash, Shares, Validators) ->
    case is_slot(Slot) andalso valid_shape(Kind, BlockHash) of
        false -> {error, insufficient};          %% malformed (kind/block_hash mismatch)
        true  ->
            Msg  = share_bytes(Kind, Slot, BlockHash),
            Sigs = distinct_valid([{S#share.signer, S#share.sig}
                                    || S <- Shares,
                                       S#share.kind =:= Kind,
                                       S#share.slot =:= Slot,
                                       S#share.block_hash =:= BlockHash],
                                   Msg, Validators),
            case length(Sigs) >= quorum(length(Validators)) of
                true  -> {ok, #cert{kind = Kind, slot = Slot, block_hash = BlockHash, sigs = Sigs}};
                false -> {error, insufficient}
            end
    end.

-doc """
Verify a certificate independently against a known validator set: it carries `≥ quorum(N)` signatures
from **distinct** set members that all verify over the certificate's `(kind, slot, block_hash)`. This
is the trustless check — a subscriber/relay-receiver validates a committed block by its commit cert
without trusting whoever handed it over.
""".
-spec verify_cert(#cert{}, [node_id()]) -> boolean().
%% Reject before any signature work: an empty set has no quorum (never quorum(0)); and a legitimate
%% cert never carries MORE than |Validators| signatures — capping the length first stops a hostile
%% relay from forcing thousands of Ed25519 verifications (a CPU-amplification DoS on the trustless path).
verify_cert(#cert{kind = K, slot = Sl, block_hash = BH, sigs = Sigs}, Validators) ->
    N = length(Validators),
    N > 0
        andalso is_slot(Sl)
        andalso valid_shape(K, BH)
        andalso bounded_signatures(Sigs, N)
        andalso length(distinct_valid(Sigs, share_bytes(K, Sl, BH), Validators)) >= quorum(N).

%% A certificate can carry at most one signature per validator. This bounded recursive check both
%% rejects improper tails before any list BIF can raise and caps hostile crypto work before verification.
bounded_signatures([], _Remaining) -> true;
bounded_signatures([{Signer, Sig} | Rest], Remaining) when Remaining > 0 ->
    valid_signer_signature(Signer, Sig) andalso bounded_signatures(Rest, Remaining - 1);
bounded_signatures(_MalformedOrTooLong, _Remaining) -> false.

proper_signatures([{Signer, Sig} | Rest]) ->
    valid_signer_signature(Signer, Sig) andalso proper_signatures(Rest);
proper_signatures([]) -> true;
proper_signatures(_)  -> false.

valid_signer_signature(Signer, Sig) ->
    is_binary(Signer) andalso byte_size(Signer) =:= 32
        andalso is_binary(Sig) andalso byte_size(Sig) =:= 64.

%% Keep one signature per signer, from validators in the set, whose signature verifies over `Msg`.
distinct_valid(Sigs, Msg, Validators) ->
    VSet = ordsets:from_list(Validators),
    lists:ukeysort(1, [{Signer, Sig}
                       || {Signer, Sig} <- Sigs,
                          ordsets:is_element(Signer, VSet),
                          quod_identity:verify(Sig, Msg, Signer)]).

%%%===================================================================
%%% the commit guard (the load-bearing safety rule)
%%%===================================================================

-doc """
May this validator issue a **commit** share for `Slot`? Only if it has issued NO **complaint** share for
`Slot` **and none for its parent `Slot-1`**. Together with `may_complain/2` this is the whole safety
argument, extended by one slot to cover the depth-1 pipeline: a committed block **implicitly finalizes
its approved parent** (`detect_commits`), so committing `Slot` finalizes `Slot-1` too. Blocks are always
contiguous (`proposal_slot` sets `parent = Approved = slot-1`), so the parent is exactly `Slot-1`.

The guarantee: an honest validator is on at most ONE of {commit-or-implicit-commit of `v`, complaint of
`v`}, for every `v`. Hence a commit cert on the child `v+1` PROVES `⅔` did not complain `v`, so no
complaint cert on `v` can also form (any two `⅔`-quorums overlap on ≥1 honest party, who would then have
both complained `v` and committed its child — impossible) — a slot can never be both committed (its own
or its child's cert) and skipped. That inductive proof is exactly what `quod_catchup:verify_implicit`
relies on, so the catch-up side needs no extra check. `ComplainedSlots` is any plain list.
""".
-spec may_commit(slot(), [slot()]) -> boolean().
may_commit(Slot, ComplainedSlots) ->
    not lists:member(Slot, ComplainedSlots)
        andalso not lists:member(Slot - 1, ComplainedSlots).

-doc """
May this validator issue a **complaint** (skip) share for `Slot`? Only if it has issued NO **commit**
share for `Slot` **and none for its child `Slot+1`** — the symmetric half of `may_commit/2`. Committing
the child `Slot+1` implicitly finalizes `Slot`, so complaining `Slot` afterward would put this validator
on both certs for `Slot`. (The child clause is belt-and-braces: the Δ timer only arms for `Approved+1`,
which no longer names `Slot` once `Slot+1` is notarized — but keeping the guard local makes the
mutual-exclusion invariant self-contained rather than depending on the arming logic.) `CommittedSlots`
is any plain list.
""".
-spec may_complain(slot(), [slot()]) -> boolean().
may_complain(Slot, CommittedSlots) ->
    not lists:member(Slot, CommittedSlots)
        andalso not lists:member(Slot + 1, CommittedSlots).

%%%===================================================================
%%% consensus engine — certificate pool + complete block tree (§2.3)
%%%===================================================================
%%
%% One node's local protocol view, threaded functionally by the gen_statem. It ingests proposed
%% blocks, signature shares, and certificates; maintains the `⅔`-certificate **pool** (§2.3.1) and the
%% complete **block tree** (§2.3.2); and emits the events the driver acts on. Pure + deterministic — no
%% clock, no transport (the gen_statem owns those). Stage 2a uses **direct dispersal**: a proposal
%% carries the whole block, so a block joins the tree on (support cert + parent present) — no erasure
%% fragment decode (that is Stage 4). The pool's distinct-signer `⅔` check reuses `form_cert/5`.
%%
%% Events: `{broadcast, Cert}` (a cert we just formed or first learned — re-disseminate),
%% `{notarized, Block}` (a block joined the tree), `{committed, Slot, Block}` (a block is final → apply).

-record(eng, {validators   :: [node_id()],
              base     = 0   :: slot(),                                %% durable committed floor: slots =<
                                                                       %% base are final (in the store) and
                                                                       %% pruned from the maps below; a
                                                                       %% commit advances it (eng_prune/2)
              blocks   = #{} :: #{binary() => #block{}},               %% block_hash => proposed block
              shares   = #{} :: #{share_key() => #{node_id() => #share{}}},
              certs    = #{} :: #{share_key() => #cert{}},
              tree     = #{} :: #{slot() => #block{}},                 %% notarized blocks (in-flight window)
              tree_hashes = #{} :: #{slot() => binary()},              %% slot => verified key in `blocks`
              committed = #{} :: #{slot() => #block{}},                %% committed (final) in-flight blocks
              skipped  = #{} :: #{slot() => true}}).                   %% slots a complaint cert has skipped

-type share_key() :: {support | commit | complaint, slot(), binary() | none}.
-type eng_event() :: {broadcast, #cert{}} | {notarized, #block{}}
                   | {committed, slot(), #block{}} | {skipped, slot()}.

-doc """
A fresh engine for a validator set (the active voting set — `active_validators/1`; at epoch length 1 that
is the current committee), with `Base` = the durable committed floor (the last slot already final in the
store). Blocks `=< Base` are treated as committed history so a new proposal's parent resolves without the
engine holding the whole chain.
""".
-spec eng_new([node_id()], slot()) -> #eng{}.
eng_new(Validators, Base) ->
    #eng{validators = Validators, base = Base}.

%% Swap the engine's voting set to the ACTIVE validator set (`active_validators/1`) when `adopt_committee/2`
%% crosses a boundary. Today (epoch length 1) the active set IS the committee facts, so this fires on every
%% committee-changing commit; under real epochs it fires only at an epoch boundary, and a mid-epoch facts
%% change leaves the engine's set untouched. Safe at the slot boundary: the just-committed slot is already
%% pruned (`base` raised), so no in-flight share/cert is re-verified under the new set; the next slot's
%% shares/certs verify against it.
eng_set_validators(Validators, Eng) -> Eng#eng{validators = Validators}.

%% The certificate to PERSIST on a finalized `#entry`, captured before `finalize`→`eng_prune` drops it from
%% the pool. NOT the raw pool cert: we re-minimise it to the distinct VALID signatures of the committee
%% AS-OF-this-slot (`eng.validators`, already swapped to the post-slot-N-1 set) — so (a) a peer's padded /
%% relayed junk signatures can never bake into the append-only log (only ≤ N genuine committee sigs remain),
%% and (b) the persisted cert verifies against the committee a catch-up joiner reconstructs for this slot.
%% `none` only if the pool cert lacks a quorum under the current set — a lagging node that finalized under a
%% STALE committee (the mid-flight committee-change hazard; see doc/deferred.md §3).
persisted_cert(Kind, Slot, BH, #eng{certs = Certs, validators = Vs}) ->
    case maps:get({Kind, Slot, BH}, Certs, none) of
        none            -> none;
        #cert{sigs = S} ->
            %% Every cert is sanitized on engine ingress, so signatures are already cryptographically
            %% verified and unique. A committee transition only requires re-filtering signer membership.
            Min = [{Signer, Sig} || {Signer, Sig} <- S, lists:member(Signer, Vs)],
            case length(Min) >= quorum(length(Vs)) of
                true  -> #cert{kind = Kind, slot = Slot, block_hash = BH, sigs = Min};
                false -> none
            end
    end.

persisted_finality(Slot, BH, Eng) ->
    case persisted_cert(commit, Slot, BH, Eng) of
        #cert{} = Cert -> Cert;
        none -> implicit_finality(Slot, BH, Eng)
    end.

implicit_finality(Slot, BH, Eng = #eng{tree = Tree, tree_hashes = Hashes}) ->
    case {maps:get(Slot, Tree, undefined), persisted_cert(support, Slot, BH, Eng)} of
        {#block{payload = Payload}, #cert{} = Support} ->
            case payload_touches_committee(Payload) of
                true -> none;   %% committee transitions are explicit-finality barriers
                false ->
                    Children = lists:sort(
                      [{ChildSl, Child, maps:get(ChildSl, Hashes)}
                       || {ChildSl, #block{parent = Parent} = Child} <- maps:to_list(Tree),
                          Parent =:= Slot, ChildSl =:= Slot + 1]),
                    first_implicit_child(Children, Support, Eng)
            end;
        _ -> none
    end.

first_implicit_child([], _Support, _Eng) -> none;
first_implicit_child([{ChildSl, Child, ChildBH} | Rest], Support, Eng) ->
    case persisted_cert(commit, ChildSl, ChildBH, Eng) of
        #cert{} = Commit -> #implicit_cert{support = Support, child = Child, commit = Commit};
        none -> first_implicit_child(Rest, Support, Eng)
    end.

-doc """
Offer one protocol object to the engine; returns the updated engine + the events it produced. This is
the single ingestion point — a proposed `{block, B}`, a `{share, S}` (own or a peer's), or a relayed
`{cert, C}`. Invalid shares/certs (bad signature, non-validator signer, malformed) are dropped.
""".
-spec eng_offer({block, #block{}} | {share, #share{}} | {cert, #cert{}}, #eng{}) ->
          {#eng{}, [eng_event()]}.
%% Anything for an already-final slot (`=< base`) is stale — a replay or a peer relaying an old cert —
%% and must be dropped: it is pruned from the maps, so re-admitting it would re-notarize/re-commit a
%% committed slot (and drive a non-contiguous store append).
eng_offer({block, #block{slot = Sl}}, #eng{base = Base} = Eng) when Sl =< Base -> {Eng, []};
eng_offer({share, #share{slot = Sl}}, #eng{base = Base} = Eng) when Sl =< Base -> {Eng, []};
eng_offer({cert,  #cert{slot = Sl}},  #eng{base = Base} = Eng) when Sl =< Base -> {Eng, []};
eng_offer({block, #block{} = B}, Eng) ->
    eng_offer_hashed(block_hash(B), B, Eng);
eng_offer({share, #share{kind = K, slot = Sl, block_hash = BH, signer = Signer} = Sh}, Eng) ->
    Key = {K, Sl, BH},
    Bucket = maps:get(Key, Eng#eng.shares, #{}),
    %% Reject outsiders before Ed25519 work. A duplicate is already trusted in the bucket, so do not verify
    %% it again; it can still trigger re-formation after `weak_cert_wait` evicted a stale old-committee cert.
    case lists:member(Signer, Eng#eng.validators) of
        false -> {Eng, []};
        true  -> case maps:is_key(Signer, Bucket) of
                     true  -> maybe_form_bucket_cert(K, Sl, BH, Bucket, Eng);
                     false -> case verify_share(Sh) of
                                  true  -> ingest_share(Sh, Bucket, Eng);
                                  false -> {Eng, []}
                              end
                 end
    end;
eng_offer({cert, #cert{} = C}, Eng) ->
    Key = cert_key(C),
    case maps:is_key(Key, Eng#eng.certs) of
        true -> {Eng, []};
        false ->
            case sanitize_cert(C, Eng#eng.validators) of
                error -> settle(Eng);
                {ok, Clean} ->
                    {Eng1, Evs} = settle(Eng#eng{certs = (Eng#eng.certs)#{Key => Clean}}),
                    {Eng1, [{broadcast, Clean} | Evs]}   %% relay a newly-learned cert once (§2.3.1)
            end
    end.

%% The state-machine driver already computed the proposal hash for signing. Keep that trusted fast path
%% private; external users of the pure engine enter through `eng_offer({block,B}, ...)`, which derives it.
eng_offer_hashed(_BH, #block{slot = Sl}, #eng{base = Base} = Eng) when Sl =< Base -> {Eng, []};
eng_offer_hashed(BH, #block{} = B, Eng) ->
    settle(Eng#eng{blocks = (Eng#eng.blocks)#{BH => B}}).

%% Add a verified share to its (kind, slot, block) bucket; if that reaches the `⅔` quorum for the first
%% time, form the cert and re-disseminate it, then settle the tree/commits.
ingest_share(#share{kind = K, slot = Sl, block_hash = BH, signer = Signer} = Sh, Bucket, Eng) ->
    Key    = {K, Sl, BH},
    Bucket1 = Bucket#{Signer => Sh},
    Eng1   = Eng#eng{shares = (Eng#eng.shares)#{Key => Bucket1}},
    maybe_form_bucket_cert(K, Sl, BH, Bucket1, Eng1).

maybe_form_bucket_cert(K, Sl, BH, Bucket, Eng) ->
    Key = {K, Sl, BH},
    %% Crypto trust survives a committee transition; voting eligibility does not. Project the trusted
    %% bucket onto the CURRENT set so shares cached before a removal cannot satisfy the new quorum.
    Current = [{P, X} || {P, X} <- maps:to_list(Bucket),
                         lists:member(P, Eng#eng.validators)],
    Enough = length(Current) >= quorum(length(Eng#eng.validators)),
    case {maps:is_key(Key, Eng#eng.certs), Enough} of
        {true, _} -> settle(Eng);
        {false, false} -> {Eng, []};
        {false, true} ->
            %% Bucket insertion is the trust boundary: every value was verified once and the map key makes
            %% signers unique. Cert formation is therefore a membership projection, not another crypto pass.
            Sigs = lists:sort([{P, X#share.sig} || {P, X} <- Current]),
            Cert = #cert{kind = K, slot = Sl, block_hash = BH, sigs = Sigs},
            {Eng1, Evs} = settle(Eng#eng{certs = (Eng#eng.certs)#{Key => Cert}}),
            {Eng1, [{broadcast, Cert} | Evs]}
    end.

sanitize_cert(#cert{kind = K, slot = Sl, block_hash = BH, sigs = Sigs} = C, Validators) ->
    N = length(Validators),
    case N > 0 andalso is_slot(Sl) andalso valid_shape(K, BH)
         andalso bounded_signatures(Sigs, N) of
        false -> error;
        true  ->
            Valid = distinct_valid(Sigs, share_bytes(K, Sl, BH), Validators),
            case length(Valid) >= quorum(N) of
                true  -> {ok, C#cert{sigs = Valid}};
                false -> error
            end
    end.

cert_key(#cert{kind = K, slot = Sl, block_hash = BH}) -> {K, Sl, BH}.

%% Recompute the tree then the commits to a fixpoint — a newly-notarized block can enable its child's
%% notarization — returning the newly-notarized + newly-committed events in order.
settle(Eng) -> settle(Eng, []).
settle(Eng, AccRev) ->
    case grow_tree(Eng) of
        {Eng1, [_ | _] = New} -> settle(Eng1, lists:reverse(New, AccRev));
        {Eng1, []}            -> {Eng2, Commits} = detect_commits(Eng1),
                                 {Eng3, Skips}   = detect_complaints(Eng2),
                                 {Eng3, lists:reverse(AccRev, Commits ++ Skips)}
    end.

%% Add every block that now has a support cert AND whose parent is in the tree (or is genesis) AND
%% whose payload we hold — one pass (settle/2 loops it to a fixpoint).
grow_tree(Eng = #eng{certs = Certs, tree = Tree, tree_hashes = Hashes}) ->
    Ready = lists:filtermap(
              fun({{support, Sl, BH}, _Cert}) ->
                      case (not maps:is_key(Sl, Tree)) andalso block_for(BH, Eng) of
                          #block{} = B -> case parent_ok(B, Eng) of
                                             true -> {true, {Sl, BH, B}};
                                             false -> false
                                         end;
                          _            -> false
                      end;
                 (_) -> false
              end, maps:to_list(Certs)),
    case lists:keysort(1, Ready) of   %% slot-ascending, so parents are handed over before children
        [] -> {Eng, []};
        Sorted ->
            Tree1 = lists:foldl(fun({Sl, _BH, B}, T) -> T#{Sl => B} end, Tree, Sorted),
            Hashes1 = lists:foldl(fun({Sl, BH, _B}, Hs) -> Hs#{Sl => BH} end, Hashes, Sorted),
            {Eng#eng{tree = Tree1, tree_hashes = Hashes1},
             [{notarized, B} || {_Sl, _BH, B} <- Sorted]}
    end.

%% An explicit commit also commits its immediate approved parent. Runtime pipelining
%% is bounded to one uncommitted parent, so this single predecessor step is the full
%% implicit-commit closure. Events remain slot-ordered for the durable drain.
detect_commits(Eng = #eng{certs = Certs, tree = Tree, tree_hashes = Hashes,
                          committed = Committed}) ->
    Explicit = lists:filtermap(
            fun({{commit, Sl, BH}, _Cert}) ->
                    case (not maps:is_key(Sl, Committed)) andalso maps:get(Sl, Tree, undefined) of
                        #block{} = B -> case maps:get(Sl, Hashes, undefined) =:= BH of
                                           true -> {true, {Sl, B}};
                                           false -> false
                                       end;
                        _            -> false
                    end;
               (_) -> false
            end, maps:to_list(Certs)),
    Implicit = lists:filtermap(
                 fun({_ChildSl, #block{parent = Parent}}) when Parent > Eng#eng.base ->
                         case (not maps:is_key(Parent, Committed))
                              andalso maps:get(Parent, Tree, undefined) of
                             #block{} = B -> {true, {Parent, B}};
                             _ -> false
                         end;
                    (_) -> false
                 end, Explicit),
    New = lists:sort(maps:to_list(maps:from_list(Explicit ++ Implicit))),
    Committed1 = lists:foldl(fun({Sl, B}, C) -> C#{Sl => B} end, Committed, New),
    {Eng#eng{committed = Committed1}, [{committed, Sl, B} || {Sl, B} <- New]}.

%% A slot is skipped once the pool holds a `⅔` COMPLAINT cert for it (block-free — a complaint binds
%% only the slot). Emitted once per slot (the `skipped` set dedups); a peer-relayed complaint cert flows
%% through the same path, so a node that never complained still learns the skip and stays in lockstep.
%% Safety keeps a slot from being BOTH committed and skipped: an honest party issues at most one of
%% {commit, complaint} for a slot (the may_commit/may_complain guards), so only one cert can reach `⅔`.
detect_complaints(Eng = #eng{certs = Certs, skipped = Sk}) ->
    New = lists:sort([V || {{complaint, V, none}, _} <- maps:to_list(Certs), not maps:is_key(V, Sk)]),
    Sk1 = lists:foldl(fun(V, M) -> M#{V => true} end, Sk, New),
    {Eng#eng{skipped = Sk1}, [{skipped, V} || V <- New]}.

block_for(BH, #eng{blocks = Blocks}) -> maps:get(BH, Blocks, undefined).

%% A block may join the tree once its parent is already committed history (`=< base`, includes genesis
%% at 0) or is itself notarized in the in-flight tree.
parent_ok(#block{parent = P}, #eng{base = Base, tree = Tree}) ->
    P =< Base orelse maps:is_key(P, Tree).

-doc """
Advance the engine past a durably-committed slot: raise `base` and DROP every block/share/cert/tree/
committed entry at or below `Committed` — those slots are now final history in the store, so keeping
them would grow the maps without bound (and a later proposal's parent resolves via `base`, not the
pruned tree). Called by the driver right after it persists a committed block.
""".
%% Slice E — back out the engine's premature finalize-marking of a slot whose cert is SUB-QUORUM under the
%% current committee (the weak-cert guard, see `weak_cert_wait/4`): drop the stale cert (the key must be
%% ABSENT for `ingest_share` to re-form it under the current set) and un-mark it committed/skipped (so
%% `detect_commits`/`detect_complaints` re-fire once a genuine cert forms). The SHARES stay — the re-form
%% draws on them. Pure: the engine owns its cert/committed/skipped maps.
-spec eng_evict_final(commit | complaint, slot(), binary() | none, #eng{}) -> #eng{}.
eng_evict_final(commit, Slot, BH, Eng = #eng{certs = C, committed = Cm}) ->
    Eng#eng{certs = maps:remove({commit, Slot, BH}, C), committed = maps:remove(Slot, Cm)};
eng_evict_final(complaint, Slot, none, Eng = #eng{certs = C, skipped = Sk}) ->
    Eng#eng{certs = maps:remove({complaint, Slot, none}, C), skipped = maps:remove(Slot, Sk)}.

-spec eng_prune(slot(), #eng{}) -> #eng{}.
eng_prune(Committed, Eng = #eng{base = Base}) ->
    Above = fun(Sl) -> Sl > Committed end,
    Eng#eng{base      = max(Committed, Base),
            blocks    = maps:filter(fun(_BH, #block{slot = Sl}) -> Above(Sl) end, Eng#eng.blocks),
            shares    = maps:filter(fun({_K, Sl, _BH}, _) -> Above(Sl) end, Eng#eng.shares),
            certs     = maps:filter(fun({_K, Sl, _BH}, _) -> Above(Sl) end, Eng#eng.certs),
            tree      = maps:filter(fun(Sl, _) -> Above(Sl) end, Eng#eng.tree),
            tree_hashes = maps:filter(fun(Sl, _) -> Above(Sl) end, Eng#eng.tree_hashes),
            committed = maps:filter(fun(Sl, _) -> Above(Sl) end, Eng#eng.committed),
            skipped   = maps:filter(fun(Sl, _) -> Above(Sl) end, Eng#eng.skipped)}.

-doc """
The deterministic leader (proposer) for a slot: **round-robin** over the sorted validator set,
`sort(V)[(Slot-1) rem N]`. Every node computes the same leader for a given slot from the same frozen
set — for FUTURE slots too, which is what lets ingress routing (`route/4`) pre-position a change at
the node whose turn is coming — and a complaint-skip of slot `v` moves slot `v+1` to a *different*
leader: that rotation IS the failover. `Slot ≥ 1` (genesis is 0). Stable per-epoch leaders (keep one
leader for K slots) remain deliberately NOT taken: a dead tenured leader would cost K complaint
rounds instead of one, and pre-positioning already gives batching the stability tenure would buy.
""".
-spec leader(slot(), [node_id()]) -> node_id() | none.
leader(_Slot, []) -> none;   %% an empty committee has no leader — `none` matches no peer, so the append/
                             %% propose call sites reject gracefully instead of `rem 0`-crashing the statem
leader(Slot, Validators) ->
    Sorted = lists:sort(Validators),
    lists:nth(((Slot - 1) rem length(Sorted)) + 1, Sorted).

-ifdef(TEST).
eng_tree(#eng{tree = T})           -> T.           %% slot => notarized #block{}
eng_committed(#eng{committed = C}) -> C.           %% slot => committed #block{}
%% Build an #eng with a given `base` and a list of `{Kind, Slot}` certs planted directly into the pool
%% (bypassing verify) — for ahead_cert_ceiling/1's pure test only.
eng_with_certs(Base, KindSlots) ->
    Certs = maps:from_list([{{K, Sl, <<>>}, #cert{kind = K, slot = Sl, block_hash = <<>>, sigs = []}}
                            || {K, Sl} <- KindSlots]),
    #eng{validators = [], base = Base, certs = Certs}.

%% Reconstruct the exact engine half of an out-of-order commit already emitted to the FSM: the valid
%% certificate and committed latch exist, while the FSM separately holds the block in commit_buf.
eng_buffered_commit(Slot, Block, #cert{} = Cert,
                    Eng = #eng{certs = Certs, committed = Committed}) ->
    BH = block_hash(Block),
    Eng#eng{certs = Certs#{{commit, Slot, BH} => Cert},
            committed = Committed#{Slot => Block}}.
-endif.

%%%===================================================================
%%% gen_statem — the per-namespace consensus process
%%%===================================================================
%%
%% One process per namespace, one logical state (`running`) — Simplex validators are symmetric (no
%% follower/candidate/leader roles; "leader for slot v" is a function of the slot). Every commit runs
%% through the consensus engine (§2.3 pool + tree): the leader proposes a block; validators sign support
%% shares → a `⅔` support cert notarizes it → they sign commit shares → a `⅔` commit cert commits it →
%% apply + persist. At N=1 the sole validator IS the `⅔` quorum, so each step self-satisfies instantly
%% (the append commits synchronously). The durable block list lives in `quod_ledger_store`; this process
%% keeps only the in-flight engine window + the derived height + validator set (KB = projection).
%%
%% The engine drives commit uniformly at every N: at N=1 the sole validator IS the ⅔ quorum, so each
%% step self-satisfies and the append commits synchronously; with peers the same path runs over the
%% `{log, Ns}` transport, the durable-head progress watchdog, and the per-slot committee.

-define(DEFAULTS,
        #{node_id      => undefined,   %% our pubkey == node_id; REQUIRED
          mode         => create,      %% create = found genesis; join = trustlessly catch up from a contact
          committee    => [],          %% co-founders; `[]` = self-only (N=1), a list = a multi-validator committee
          genesis_file => undefined,   %% root .pl to seed on create (founder only)
          genesis_hash => undefined,   %% join only: the out-of-band-pinned slot-1 block_hash (the trust anchor)
          data_dir     => undefined}).

-define(MAX_OUTBOX, 1024).   %% per-peer cap on frames buffered while a link opens (bounds memory vs a dead peer)
-define(TICK_MS,     300).   %% consensus re-drive cadence: re-dial peers whose link never came up (liveness)
-define(DIAL_TIMEOUT_MS, 15000).  %% presume a dial lost if neither link_up nor link_error arrives within this
                                  %% long, and sweep its marker so the tick re-dials (guards a conn that dies
                                  %% mid-handshake); safely exceeds the worst-case legit dial (connect ~5s +
                                  %% link-ack ~5s, quod_conn), so an in-flight dial is never swept early
-define(DELTA_MS,   1000).   %% oldest-head progress timeout: redrive or complain while waiting for proposal,
                             %% notarization, or commit; must exceed real commit latency
                             %% (override via app-env `simplex_delta_ms`)
-define(SYNC_WINDOW,  256).  %% entries requested per catch-up / gap-fill fetch (matches the server's block cap)
-define(SINK_MS,     30000). %% budget for one sink window (store append + KB replay) — generous
-define(TIP_PROBE_MS, 9500). %% one parallel tip round; exceeds quod_catchup's 9s public pull budget
-define(RECOVERY_FETCHES, 2). %% bound source changes inside one recovery worker (retries resume durably)
-define(RECOVERY_HINT_WARMS, 3). %% bounded endpoint discovery before an identity-bound tip quorum
-define(RECOVERY_WARM_CONTACTS, 16). %% parallel, one-entry probes; cold recovery only
-define(SYNC_HYSTERESIS,  2).  %% ticks the `behind` gap must persist before a heavyweight pull arms (a transient
                               %% 1-2 slot lag rides the cheap redrive); an `unconfirmed` node bypasses it
-define(SYNC_BACKOFF_MIN, 3).  %% failure backoff floor (ticks) before re-arming a sync after no_contact/error
-define(SYNC_BACKOFF_MAX, 20). %% failure backoff cap (ticks) — exp-doubled, ±20% jittered, single-flight-paced
-define(APPLY_SYNC_EVERY, 256).  %% streamed replay: drain quod_prolog (sync barrier) every this many casts
-define(MAX_FUTURE_MS, (2 * 60 * 60 * 1000)).  %% block-timestamp future skew tolerance (2h, cf. Bitcoin MAX_FUTURE_BLOCK_TIME)
-define(MAX_BATCH_TXS, 256).                    %% hard count cap; bounds per-block apply work
-define(MAX_BLOCK_BYTES, (256 * 1024)).         %% an implicit proof may carry one child below the 1 MiB cap
-define(BATCH_ENVELOPE_BYTES, 6).               %% exact singleton-list ETF overhead beyond term_to_binary(Tx)
-define(BATCH_MS, 2).                           %% short micro-batch window; configurable with simplex_batch_ms
-define(PIPELINE_DEPTH, 1).                     %% at most one approved parent may remain uncommitted
-define(RELAY_RETRY_MS, 300).                    %% lost-frame backstop: the terminal reply is the normal
                                                  %% resolution now that holders PARK instead of rejecting;
                                                  %% this cadence only recovers frames the fire-and-forget
                                                  %% link send dropped (quod_link ignores flow-control
                                                  %% pressure by design), so it must stay tight until links
                                                  %% grow backpressure signalling (doc/deferred.md)
-define(MAX_RELAY_PENDING, 2048).                 %% bound parked callers and redrive state
-define(MAX_INGRESS_TXS, 512).                    %% ingress park queue: shared item bound (2x a full block)
-define(MAX_INGRESS_BYTES, (2 * ?MAX_BLOCK_BYTES)).  %% ingress park queue: shared byte bound
-define(MAX_INGRESS_PER_AUTHOR, 64).              %% fairness: one authenticated member cannot capture the
                                                  %% FIFO by flooding — its overflow rejects, others park
-define(INGRESS_TTL_MS, 7000).                    %% parked-item cutoff. Derivation: a pre-positioned park
                                                  %% may legitimately wait ?INGRESS_HORIZON slots, and ONE
                                                  %% of them may burn a full quorum-flap complaint cycle
                                                  %% (Δ×(1+?MAX_QUORUM_REARMS) = 4s) before the skip lands;
                                                  %% flight time is negligible. 7s covers that worst legit
                                                  %% wait yet stays under the caller's 8s append timeout,
                                                  %% so a REAL stall still fails visibly (busy) while the
                                                  %% caller can still hear it — the queue never hides a wedge
-define(INGRESS_HORIZON, 2).                      %% a relayed change parks here only if this node leads
                                                  %% within this many slots of the pipeline floor: the
                                                  %% origin targets the FIRST enterable slot, so +2 absorbs
                                                  %% one slot of in-flight advance plus the origin/receiver
                                                  %% view lag; anything farther out is a misroute — redirect.
                                                  %% Effectively min(H, N-1): a small committee's horizon
                                                  %% covers everyone, which is correct (nowhere better to go)
-define(SIGNED_GROWTH_BYTES, 96).                 %% capacity headroom for an unsigned local item growing at
                                                  %% sign time (64B Ed25519 sig + author_seq + ETF framing)
-define(SIGNATURE_VERIFY_TIMEOUT_MS, 2000).       %% fail closed if a crypto worker wedges
-define(MAX_QUORUM_REARMS, 3).                    %% bound link-flap deadline extension per slot/phase
-define(READINESS_MS, 1000).                      %% readiness refresh; at or below the default Delta
-define(READINESS_FRESH_MS, 3000).                %% tolerate two missed refreshes, then fail closed
-define(BLOCK_REQUEST_RETRY_MS, 500).              %% rotate a missing certified block request to another holder

-type final_vote() :: none | {commit, binary()} | complaint.
-type final_vote_trigger() :: notarized | complaint_evidence | timeout | rejected.
-record(round, {supporting = none :: none | binary(),
                final = none :: final_vote(),
                invalid = false :: boolean(),
                validating = none :: none | binary()}).

-record(batch, {slot :: slot(),
                parent :: slot(),
                items_rev = [] :: [{term(), #transaction{}}],
                bytes = 0 :: non_neg_integer()}).

-record(waiter, {reply_to :: term(),
                 trace_ctx :: quod_trace:context(),
                 trace_span :: quod_trace:span_ctx()}).

-record(local_proposal, {hash :: binary(),
                         waiters = [] :: [term()],
                         trace_ctxs = [] :: [quod_trace:context()]}).

-type progress_phase() :: awaiting_proposal | awaiting_notarization | awaiting_commit.
-record(head_progress, {slot :: slot(),
                        phase :: progress_phase(),
                        quorum_ready = false :: boolean(),
                        quorum_rearms = 0 :: 0..?MAX_QUORUM_REARMS,
                        support_grace_used = false :: boolean()}).

-record(relay_pending, {from :: term(),
                        target :: node_id(),
                        frame :: binary(),
                        deadline :: integer(),
                        next_retry :: integer(),
                        redirects = 0 :: 0..3}).   %% misroute correction: pre-positioning targets the
                                                   %% seat, so hops are the exception; the bound caps
                                                   %% Byzantine redirect ping-pong

%% One parked append: the FIFO "take a ticket" entry that replaced the reject-busy/retry
%% loop. `origin` fixes the trust shape (`local` = this node's own still-UNSIGNED
%% transaction — signed exactly once, on the pass that leaves the queue; `relayed` = an
%% author-signed submission verify_and_accept_relay already admitted). `enqueued_at` is
%% BOTH the TTL clock and the relay-deadline anchor: queue time counts against the
%% caller's end-to-end budget, so consensus still gives up no later than ~1s after the
%% prolog park TTL, exactly as before parking existed.
-record(ingress_item, {origin :: local | relayed,
                       waiter :: #waiter{},
                       change :: #transaction{},
                       bytes  :: pos_integer(),     %% batch-capacity accounting, incl. sign growth
                       enqueued_at :: integer()}).  %% mono ms

-record(s, {ns           :: binary(),
            self         :: node_id(),               %% our pubkey == node_id
            id           :: signer() | undefined,    %% signing identity (pubkey + private key)
            store        :: quod_ledger_store:handle() | undefined,
            vote_journal :: quod_vote_journal:handle() | memory | undefined,
            eng          :: #eng{} | undefined,      %% the consensus engine (certificate pool + block tree)
            chan         :: binary() | undefined,    %% term_to_binary({log, Ns}) — the transport channel
            validators   = [] :: [node_id()],        %% the committee FACTS — sorted `peer_admitted` pubkeys,
                                                     %% the KB projection re-derived from the committed log
                                                     %% (in-process). The ACTIVE voting set derives from this
                                                     %% via `active_validators/1` (identity at epoch length 1);
                                                     %% "who votes now" reads route through THAT, not this field.
            slot         = 0  :: slot(),             %% height: index of the last COMMITTED block (commits are
                                                     %% strictly in order, so this is also the committed floor)
            approved     = 0  :: slot(),             %% latest notarized/activated slot; proposals extend this
            last_applied = 0  :: slot(),             %% highest slot handed to quod_prolog
            collecting = none :: none | #batch{},    %% leader's not-yet-sealed micro-batch
            local_proposals = #{} :: #{slot() => #local_proposal{}}, %% sealed local blocks + parked callers
            rounds = #{} :: #{slot() => #round{}},   %% all local vote/validation latches for an in-flight slot
            requested_slot = none :: none | slot(),  %% earliest client-demanded slot not yet proposed/finalized
            head_progress = idle :: idle | #head_progress{},
                                                     %% explicit state of the oldest non-final slot; unlike the
                                                     %% old approval-frontier latch, notarization advances this
                                                     %% to awaiting_commit instead of cancelling its watchdog
            commit_buf = #{} :: #{slot() => {commit, #block{}} | skip},  %% out-of-order finalizations, drained in order
            conns      = #{} :: #{node_id() => {pid(), reference()}},  %% our OUTBOUND links to peers
            inbound_conns = #{} :: #{node_id() => {pid(), reference()}}, %% authenticated inbound consensus links
            peer_readiness = #{} :: #{node_id() => {pid(), slot(), boolean(), integer()}},
                                                     %% readiness reported on the exact inbound link generation
            readiness_advertised = {0, false, 0}
              :: {slot(), boolean(), integer()},      %% last local {height,ready,monotonic-ms} advertisement
            outbox     = #{} :: #{node_id() => [binary()]},            %% frames buffered while a link opens
            dialing    = #{} :: #{node_id() => integer()},             %% peer => monotonic-ms deadline of its in-flight open_link dial
            relay_pending = #{} :: #{binary() => #relay_pending{}},
            relay_inflight = #{} :: #{binary() => node_id()},
            relay_results = #{} :: #{binary() =>
                                      {node_id(), term(), integer()}},
            block_requests = #{} :: #{{slot(), binary()} =>
                                       {non_neg_integer(), integer()}},
                                                     %% certified block anti-entropy: attempt + next retry time
            %% Ingress park queue (park, don't reject): appends that cannot enter the batch RIGHT NOW
            %% wait here and drain event-driven from keep_progress the moment the pipeline opens. FIFO is
            %% strict — live arrivals join the tail whenever the queue is non-empty, so a parked head
            %% (e.g. a membership change waiting for the pipeline to quiesce) is never starved by
            %% queue-jumping. Bounded three ways (items, bytes, per-author); overflow and TTL expiry are
            %% the only remaining `busy` sources, making `busy` an alertable overload/stall signal.
            ingress = queue:new() :: queue:queue(#ingress_item{}),
            ingress_count = 0 :: non_neg_integer(),
            ingress_bytes = 0 :: non_neg_integer(),
            ingress_authors = #{} :: #{node_id() => pos_integer()},
            relay_timeout_ms = 31000 :: pos_integer(),
            author_seqs = #{} :: #{node_id() => non_neg_integer()},
            next_author_seq = 1 :: pos_integer(),
            prolog_ready = false :: boolean(),
            %% Recovery is one explicit state machine. `unconfirmed` means the durable prefix is valid but
            %% its tip has not been corroborated; `{pulling,Pid}` gives one worker exclusive ownership of
            %% catch-up ingestion; only `ready` may emit consensus evidence. This single enum cannot
            %% represent the unsafe combinations the
            %% former `sync` latch + `confirmed` boolean allowed after a partial or failed pull.
            sync         = unconfirmed :: unconfirmed | {pulling, pid()} | ready,
            sync_arm     = {0, 0, 0} :: {non_neg_integer(), non_neg_integer(), non_neg_integer()},
                                        %% {behind-hysteresis ticks, backoff cooldown ticks, backoff interval ticks}
            genesis_hash = undefined :: binary() | undefined,  %% join trust anchor: the pinned slot-1 block_hash
            last_ts    = 0 :: non_neg_integer(),  %% timestamp of the most recent committed block (monotonic bound for the next propose)
            appends = 0  :: non_neg_integer(),
            proposals = 0 :: non_neg_integer(),
            batched_txs = 0 :: non_neg_integer(),
            commits = 0  :: non_neg_integer(),
            submitted  = 0 :: non_neg_integer(),   %% every append attempt (metrics: submit rate)
            skips      = 0 :: non_neg_integer(),   %% complaint-skipped (noop) slots
            r_busy     = 0 :: non_neg_integer(),   %% appends REFUSED busy. Since the park queue landed this
                                                   %% counts only ingress overflow + TTL expiry — an
                                                   %% ALERTABLE overload/stall signal, no longer routine
                                                   %% backpressure (dashboards updated to match)
            r_redirect = 0 :: non_neg_integer(),   %% append not-in-charge: not this slot's leader / not a member (redirect)
            r_bad      = 0 :: non_neg_integer(),    %% append rejected: unacceptable change
            r_stale    = 0 :: non_neg_integer(),    %% append lost a routing race (stale_seq — retryable,
                                                    %% NOT malformed; keeping it out of r_bad keeps the
                                                    %% "malformed workload" alarm honest)
            ingress_overflow  = 0 :: non_neg_integer(),  %% parks refused: queue item/byte/per-author bound hit
            ingress_expired   = 0 :: non_neg_integer(),  %% parked items cut by ?INGRESS_TTL_MS (stalled head)
            ingress_forwarded = 0 :: non_neg_integer(),  %% drained items routed onward (relay or redirect)
            ingress_prepositioned = 0 :: non_neg_integer(),  %% relayed items parked AHEAD of this node's
                                                             %% turn to lead (the pre-positioning win path)
            membership_rejects = 0 :: non_neg_integer(),   %% membership proposals a KB verdict rejected as invalid
            redrives   = 0 :: non_neg_integer(),   %% Δ re-fires that re-broadcast our own in-flight proposal
            progress_timeouts = 0 :: non_neg_integer(), %% oldest-head watchdog expirations
            quorum_pauses = 0 :: non_neg_integer(), %% timeouts that withheld a complaint while < quorum ready
            weak_cert_waits = 0 :: non_neg_integer()}).  %% finalizations refused on a sub-quorum cert (Slice E,
                                                         %% the stale-cert hazard) — climbing = a laggard waiting

-ifdef(TEST).
%% Build a minimal #s{} for the Slice-4 gate-predicate eunit (the record is otherwise private). Only the
%% fields the pure predicates read carry meaning; every other field takes its record default.
test_state(Overrides) ->
    S = maps:fold(fun(approved, _V, Acc) -> Acc;
                     (K, V, Acc) -> test_state_set(K, V, Acc)
                  end, #s{ns = <<"t">>, self = <<"self">>, vote_journal = memory}, Overrides),
    case maps:find(approved, Overrides) of
        {ok, V} -> S#s{approved = V};
        error   -> S
    end.
test_state_set(self, V, S)       -> S#s{self = V};
test_state_set(id, V, S)         -> S#s{id = V};
test_state_set(validators, V, S) -> S#s{validators = V};
test_state_set(slot, V, S)       -> S#s{slot = V, approved = V};
test_state_set(approved, V, S)   -> S#s{approved = V};
test_state_set(eng, V, S)        -> S#s{eng = V};
test_state_set(sync, V, S)       -> S#s{sync = V};
test_state_set(last_applied, V, S) -> S#s{last_applied = V};
test_state_set(prolog_ready, V, S) -> S#s{prolog_ready = V};
test_state_set(author_seqs, V, S) -> S#s{author_seqs = V};
test_state_set(store, V, S)       -> S#s{store = V};
test_state_set(vote_journal, V, S) -> S#s{vote_journal = V};
test_state_set(commit_buf, V, S)  -> S#s{commit_buf = V};
test_state_set(head_progress, idle, S) -> S#s{head_progress = idle};
test_state_set(head_progress, {Slot, Phase, Ready}, S) ->
    S#s{head_progress = #head_progress{slot = Slot, phase = Phase,
                                       quorum_ready = Ready}};
test_state_set(head_progress, {Slot, Phase, Ready, Rearms}, S) ->
    S#s{head_progress = #head_progress{slot = Slot, phase = Phase,
                                       quorum_ready = Ready,
                                       quorum_rearms = Rearms}};
test_state_set(head_progress, {Slot, Phase, Ready, Rearms, SupportGrace}, S) ->
    S#s{head_progress = #head_progress{slot = Slot, phase = Phase,
                                       quorum_ready = Ready,
                                       quorum_rearms = Rearms,
                                       support_grace_used = SupportGrace}};
test_state_set(requested_slot, V, S) -> S#s{requested_slot = V};
test_state_set(conns, V, S)      -> S#s{conns = V};
test_state_set(inbound_conns, V, S) -> S#s{inbound_conns = V};
test_state_set(peer_readiness, V, S) -> S#s{peer_readiness = V};
test_state_set(outbox, V, S)     -> S#s{outbox = V};
test_state_set(dialing, V, S)    -> S#s{dialing = V};
test_state_set(block_requests, V, S) -> S#s{block_requests = V};
test_state_set(local_proposal, {Slot, Hash}, S) ->   %% plant an in-flight sealed proposal
    S#s{local_proposals =
            (S#s.local_proposals)#{Slot => #local_proposal{hash = Hash, waiters = []}}};
%% Plant parked ingress items: [{Origin, From, Change, EnqueuedAtMonoMs}] — waiter
%% envelopes, byte accounting, and per-author counts are derived exactly as park_ingress
%% derives them, so drain/expiry tests exercise the real bookkeeping.
test_state_set(ingress, Items, S) ->
    lists:foldl(
      fun({Origin, From, Change, At}, Acc) ->
              Waiter = new_waiter(From, otel_ctx:new(), Change, Acc#s.ns,
                                  Origin =:= relayed),
              {Acc1, []} = park_ingress(Origin, awaiting_turn, Waiter, Change, At, Acc),
              Acc1
      end, S, Items);
test_state_set(rounds, V, S)     -> S#s{rounds = V};
test_state_set(collecting, {Slot, Froms}, S) ->   %% a not-yet-sealed batch parking these callers
    S#s{collecting = #batch{slot = Slot, parent = Slot - 1,
                            items_rev = [{From, noop} || From <- Froms], bytes = 0}};
test_state_set(sync_arm, V, S)   -> S#s{sync_arm = V}.
test_arm(#s{sync_arm = A})       -> A.   %% read the pacing tuple back out of a state (record is private)
test_sync(#s{sync = Sy})         -> Sy.
test_progress(#s{head_progress = idle}) -> idle;
test_progress(#s{head_progress = #head_progress{slot = Slot, phase = Phase,
                                                quorum_ready = Ready}}) ->
    {Slot, Phase, Ready}.
test_progress_rearms(#s{head_progress = idle}) -> 0;
test_progress_rearms(#s{head_progress = #head_progress{quorum_rearms = Rearms}}) -> Rearms.
test_support_grace(#s{head_progress = idle}) -> false;
test_support_grace(#s{head_progress = #head_progress{support_grace_used = Used}}) -> Used.
test_round(Slot, S) ->
    R = round_state(Slot, S),
    {R#round.supporting, round_committed(R), round_complained(R)}.
test_requested(#s{requested_slot = V}) -> V.
test_progress_counts(#s{progress_timeouts = T, quorum_pauses = P}) -> {T, P}.
test_committed_store(#s{slot = Slot, store = Store}) -> {Slot, Store}.
test_link_peers(#s{conns = Conns, inbound_conns = Inbound,
                   outbox = Outbox, dialing = Dialing}) ->
    {lists:sort(maps:keys(Conns)), lists:sort(maps:keys(Inbound)),
     lists:sort(maps:keys(Outbox)), lists:sort(maps:keys(Dialing))}.
test_redrive_head(Slot, Hash, S) ->
    Local = #local_proposal{hash = Hash, waiters = []},
    redrive_head(Slot, S#s{local_proposals = #{Slot => Local}}).
test_block_requests(#s{block_requests = Requests}) -> Requests.
test_vote_journal(#s{vote_journal = Journal}) -> Journal.
%% Ingress-queue test surface: raw-From entry wrappers (the waiter/trace envelope is
%% built here exactly as the running/3 handlers build it), the queue view, and
%% clock-controlled drain/expiry.
test_append(From, Change, S) ->
    handle_append(new_waiter(From, otel_ctx:new(), Change, S#s.ns, false), Change, S).
test_relayed_append({relay, _Peer, _ReqId} = ReplyTo, Change, S) ->
    handle_relayed_append(
      new_waiter(ReplyTo, otel_ctx:new(), Change, S#s.ns, true), Change, S).
test_ingress(#s{ingress = Q, ingress_count = C, ingress_bytes = B,
                ingress_authors = Authors}) ->
    {C, B, Authors,
     [{O, Ch#transaction.tx_id, T}
      || #ingress_item{origin = O, change = Ch, enqueued_at = T} <- queue:to_list(Q)]}.
test_drain(S) -> drain_ingress(S).
test_expire_ingress(S) -> expire_ingress(S).
test_relay_pending(#s{relay_pending = Pending}) ->
    [{ReqId, Target, Deadline}
     || {ReqId, #relay_pending{target = Target, deadline = Deadline}}
            <- maps:to_list(Pending)].
test_relay_result(Peer, ReqId, Result, S) ->
    handle_relay_result(Peer, ReqId, Result, S).
-endif.

callback_mode() -> [state_functions].

%%%===================================================================
%%% API
%%%===================================================================

start_link(Ns, Config) ->
    gen_statem:start_link(quod_reg:via({quod_simplex, Ns}), ?MODULE, {Ns, Config}, []).

-doc """
Submit a change. Blocks until the block commits (`{ok, Slot}`); at N=1 that is its own fsync. A change
that cannot enter a block RIGHT NOW parks in the bounded ingress queue and resolves on the pipeline's
own events, so the error arms of the stable consensus-append contract `quod_prolog` handles are now:
`busy` (queue OVERFLOW, or a parked change cut by the ingress TTL during a genuine stall — an overload
signal, no longer routine backpressure), `stale_seq` (the change lost a routing race and its signed
sequence fell below the committed floor — retry), `not_in_charge` (this node isn't the slot's leader —
a redirect hint, or `unavailable` if this process is unreachable), and `skipped` (retry: a multi-node
committee complaint-skipped our proposed slot, or a relayed change came home because rotation reached
us mid-relay). At N=1 only the sole-validator commit path runs, so an append just returns `{ok, Slot}`.
The call timeout sits above the ingress TTL so a parked direct append cannot race its own expiry reply.
""".
-spec append(binary(), #transaction{}) ->
        {ok, slot()} | {error, busy} | {error, skipped} | {error, bad_change}
      | {error, stale_seq}
      | {error, not_in_charge, node_id() | none | unavailable}.
append(Ns, Change) ->
    try gen_statem:call(quod_reg:via({quod_simplex, Ns}),
                        {append, Change, quod_trace:context()}, 8000)
    catch exit:_ -> {error, not_in_charge, unavailable} end.

-doc "Ask the consensus process to (re)drive committed blocks into a freshly-started `quod_prolog`.".
-spec rebuild(binary()) -> ok.
rebuild(Ns) -> gen_statem:cast(quod_reg:via({quod_simplex, Ns}), rebuild).

status(Ns)    -> call(Ns, get_status, #{}).
committee(Ns) -> call(Ns, get_committee, []).
stats(Ns)     -> call(Ns, get_stats, undefined).

-doc "The `block_hash` of this node's local genesis block (slot 1) — the anchor a joiner must pin (config).".
-spec genesis_hash(binary()) -> binary() | undefined.
genesis_hash(Ns) -> call(Ns, get_genesis_hash, undefined).

namespaces() -> gproc:select([{{{n, l, {quod_simplex, '$1'}}, '_', '_'}, [], ['$1']}]).

call(Ns, Req, Default) ->
    try gen_statem:call(quod_reg:via({quod_simplex, Ns}), Req, 1000) catch exit:_ -> Default end.

%%%===================================================================
%%% init
%%%===================================================================

init({Ns, Config}) ->
    Cfg = maps:merge(?DEFAULTS, Config),
    case valid_cfg(Config, Cfg) of
        {error, Reason} -> {stop, {bad_config, Reason}};
        ok ->
            case signing_key(Cfg) of
                undefined -> {stop, {bad_config, no_signing_key}};   %% a consensus node must be able to sign
                Key       -> init_store(Ns, Cfg, #{pubkey => maps:get(node_id, Cfg), key => Key})
            end
    end.

init_store(Ns, Cfg, Id) ->
    {ok, Store} = quod_ledger_store:open(Ns, data_dir(Cfg)),
    Chan = term_to_binary({log, Ns}, [deterministic]),   %% the committee's consensus channel
    quod_reg:subscribe({channel, Chan}),                 %% receive peers' proposals/shares/certs
    RelayTimeout = relay_timeout_ms(Cfg),
    S0 = #s{ns = Ns, self = maps:get(pubkey, Id), id = Id, store = Store,
            chan = Chan, relay_timeout_ms = RelayTimeout},
    %% A bad/missing genesis `.pl` on create is fatal — fail-fast, the app stops.
    try load_or_bootstrap(S0, Cfg) of
        S1 ->
            Committed = S1#s.slot,   %% commits are in order, so the height IS the committed floor
            {ok, Journal} = quod_vote_journal:open(Ns, data_dir(Cfg), Committed),
            S2 = restore_vote_rounds(S1#s{vote_journal = Journal}),
            Eng = eng_new(active_validators(S2), Committed),   %% seed the engine's voting set (active set)
            %% One periodic tick drives everything post-boot: peer redials AND the sync armer (`maybe_arm_sync`)
            %% that kicks boot-sync/gap-fill. A fresh `mode=join` node boots `unconfirmed`, so `should_sync`
            %% arms its catch-up at the first tick — no separate join kick.
            {ok, running, S2#s{last_applied = 0, approved = Committed, eng = Eng}, [tick_timeout()]}
    catch
        throw:{genesis_failed, _} = Reason -> {stop, Reason}
    end.

restore_vote_rounds(S = #s{vote_journal = Journal}) ->
    S#s{rounds = vote_rounds(Journal)}.

vote_rounds(memory) -> #{};
vote_rounds(Journal) ->
    maps:map(
      fun(_Slot, #{support := Support, final := Final}) ->
              #round{supporting = Support, final = Final}
      end, quod_vote_journal:rounds(Journal)).

%% The consensus re-drive timer: fires every ?TICK_MS to retry dials whose link never came up, so a
%% transient dial failure at boot can't permanently stall a slot (there is no per-message retransmit).
tick_timeout() -> {{timeout, tick}, ?TICK_MS, tick}.

%% The private key this node signs shares with: from the config (tests inject it) or the app env
%% (production — `quod_app:apply_identity` sets `identity_key`). `undefined` ⇒ a misconfigured node.
signing_key(Cfg) ->
    case maps:get(identity, Cfg, undefined) of
        #{key := K} -> K;
        _           -> application:get_env(quod, identity_key, undefined)
    end.

relay_timeout_ms(Cfg) ->
    case maps:get(park_ttl_ms, Cfg, 30000) of
        N when is_integer(N), N > 0 -> N + 1000;
        _                           -> 31000
    end.

%% Restart reloads durable state: re-derive the committee by folding the `peer_admitted` asserts/retracts
%% out of the committed log's transaction diffs (`log_projection_step/2`, which also recovers the timestamp
%% floor `last_ts` in the same pass), STREAMED from the store in bounded windows — the log is never
%% materialized in RAM (the store is the archive, quod_prolog holds the KB projection; this consensus
%% process holds only the validator-set projection). A brand-new namespace is bootstrapped.
%% Re-folding the committee from the log is the accepted cost of running without a committee checkpoint;
%% `last/1` gives the height in O(1). Both projections derive from the same committed log, so they can't drift.
%% Derive the durable state, then decide by mode — `mode` is read HERE ONCE and then discarded (it is boot
%% config, not running state). `create` founds genesis when fresh (slot 0) or just re-derives on restart;
%% `join` records the pinned `genesis_hash` anchor and starts UNFOUNDED (slot 0) or RESUMES a partial prefix
%% (slot≥1) — either way it catches up via the tick's `should_sync` arm (from slot+1, so a retry never
%% re-appends disk-present bytes, and `maybe_mark_ready` stays gated on recovery reaching `ready`).
%%
%% The initial recovery state is seeded PURELY FROM THE FACTS, not the mode: only the sole validator can
%% trust its head is the tip (`active_validators == [Self]` — nobody else could have moved it). Everyone
%% else — a co-founder, a joiner, a resuming member — boots `unconfirmed` and runs recovery. So `mode`
%% leaves zero running-state residual.
load_or_bootstrap(S0 = #s{ns = Ns, store = Store}, Cfg) ->
    Base = case quod_ledger_store:last(Store) of
               0     -> S0;   %% empty ⇒ unfounded (slot 0)
               LastI -> {Vs, Ts, Seqs} = quod_ledger_store:fold(Store, 1, LastI,
                                                          fun(E, Acc) ->
                                                              checked_log_projection_step(Ns, E, Acc)
                                                          end, {[], 0, #{}}),
                        S0#s{validators = Vs, slot = LastI, last_ts = Ts,
                             author_seqs = Seqs}
           end,
    S1 = case {maps:get(mode, Cfg), Base#s.slot} of
             {join,   _} -> Base#s{genesis_hash = maps:get(genesis_hash, Cfg)};
             {create, 0} -> bootstrap(Cfg, Base);   %% fresh founder
             {create, _} -> Base                    %% restarted founder / admitted member
         end,
    S1#s{sync = initial_sync(S1),
         next_author_seq = maps:get(S1#s.self, S1#s.author_seqs, 0) + 1}.

%% The sole validator is ready immediately because no other node could have committed past its durable head.
%% Every other shape must corroborate its tip through recovery before it can emit consensus evidence.
initial_sync(#s{self = Self} = S) ->
    case active_validators(S) of
        [Self] -> ready;
        _      -> unconfirmed
    end.

%% Fresh create: durably commit ONE genesis block (slot 1) whose transaction asserts each founding
%% member's `peer_admitted` fact — the committee, as facts — followed by the root ontology content (if a
%% `.pl` is configured). The committee is then DERIVED from that same transaction (`apply_committee_delta`),
%% so bootstrap and the restart re-fold can never disagree. `quod_prolog:genesis_diff/1` is evaluated as
%% part of building the tx (it may throw `{genesis_failed,_}`), and the whole thing lands in ONE atomic
%% append — a bad `.pl` persists NOTHING: init stops and the next boot retries fresh.
%%
%% REQUIREMENT for a multi-member CO-FOUNDING committee: every co-founder MUST be configured with the SAME
%% `committee` AND the SAME `genesis_file` (or all none), so their genesis transactions are byte-identical
%% and every founder boots at the same height 1 under the same committee.
bootstrap(Cfg, S = #s{ns = Ns, self = Self, store = Store}) ->
    GenesisTx = genesis_tx(Cfg, Ns, Self),
    E = #entry{index = 1, data = quod_ledger:data([GenesisTx])},
    {ok, Store1} = quod_ledger_store:append(Store, [E]),
    S#s{store = Store1, validators = apply_committee_delta(GenesisTx, []), slot = 1}.

%% The genesis transaction: assert each founding member's `peer_admitted/4` fact (the committee as facts),
%% then the root ontology content from the `.pl` (if any). Facts + content are compiled through the erlog
%% overlay together (`quod_prolog:terms_to_diff/1` — a hand-built `{Head, true}` clause would be malformed).
%% The founding set is `[]` ⇒ self-only (N=1) or a list of co-founders; each entry is a bare pubkey (address
%% unknown until it links) or a `{Pubkey, Host, Port}` tuple. Only the pubkey is load-bearing for consensus;
%% the address is a dial hint the join path fills in later.
genesis_tx(Cfg, Ns, Self) ->
    PeerTerms  = [{peer_admitted, Pk, Host, Port, Pk} || {Pk, Host, Port} <- founding(Cfg, Self)],
    FileTerms  = case genesis_file(Cfg) of none -> []; File -> quod_prolog:read_terms(File) end,
    Diff       = quod_prolog:terms_to_diff(PeerTerms ++ FileTerms),
    #transaction{tx_id = <<"genesis:", Ns/binary>>, caller_ns = Ns, diff = Diff,
                 read_check = #{}, author = Self, sig = none}.

%% The founding members as `{Pubkey, Host, Port}` (sorted, self included). `Host`/`Port` are a dial hint the
%% join path fills in — `undefined` when only a bare pubkey is configured; consensus needs only the pubkey.
%% `valid_cfg/2` has already checked every element's shape, so `normalize_member/1` needs no catch-all.
founding(Cfg, Self) ->
    Others = [normalize_member(M) || M <- maps:get(committee, Cfg)],
    {SelfH, SelfP} = self_addr(Cfg),
    lists:ukeysort(1, [{Self, SelfH, SelfP} | [T || {Pk, _, _} = T <- Others, Pk =/= Self]]).

normalize_member({Pk, Host, Port}) when is_binary(Pk) -> {Pk, Host, Port};
normalize_member(Pk)               when is_binary(Pk) -> {Pk, undefined, undefined}.

%% This node's advertised endpoint for its own `peer_admitted` fact: the `node_addr` app-env var (set by
%% `quod_app:apply_identity` in production), overridable via the ns Cfg for tests. `undefined` if unset.
self_addr(Cfg) ->
    case maps:get(node_addr, Cfg, application:get_env(quod, node_addr, undefined)) of
        {H, P} -> {H, P};
        _      -> {undefined, undefined}
    end.

%%%===================================================================
%%% running
%%%===================================================================

running({call, From}, {append, Change}, S0) ->
    running({call, From}, {append, Change, otel_ctx:new()}, S0);
running({call, From}, {append, Change, TraceCtx}, S0) ->
    Waiter = new_waiter(From, TraceCtx, Change, S0#s.ns, false),
    {S1, Reply} = handle_append(
                    Waiter, Change,
                    S0#s{submitted = S0#s.submitted + 1}),
    keep_progress(S0, S1, Reply);
%% A freshly-(re)started quod_prolog: re-drive committed blocks from the start (async casts, in slot
%% order), then mark it ready ONLY once its kb is caught up — never a prove over a half-built kb.
running(cast, rebuild, S0) ->
    S1 = apply_committed(S0#s{last_applied = 0, prolog_ready = false}),
    keep_progress(S0, S1, []);
%% A peer's consensus message (proposal / share / cert) on our `{log, Ns}` channel. `Peer` is the
%% sender's authenticated node_id (pubkey); the address is a routing hint we ignore. Processing it can
%% advance/skip the head; `keep_progress/3` reconciles the explicit head watchdog afterward.
running(info, {quod_message, {{Peer, _Addr}, InLink}, Chan, Payload}, S0 = #s{chan = Chan}) ->
    %% Only a committee member acts on consensus traffic. A node that is still joining, or caught up but
    %% not (yet) admitted, is a read-only observer — it stays current via catch-up + its KB, never by
    %% voting — so it drops the committee's propose/share/cert stream (also guards `leader/2` on `[]`).
    case is_participant(S0) of
        false ->
            {keep_state, S0};
        true ->
            SIn = track_inbound(Peer, InLink, S0),
            case quod_relay:decode_frame(Payload, S0#s.ns) of
                {relay, Relay} ->
                    {S1, Actions} = dispatch_relay(Peer, Relay, SIn),
                    keep_progress(S0, S1, Actions);
                {consensus, Msg} ->
                    S1 = dispatch(Peer, Msg, SIn),
                    keep_progress(S0, S1, []);
                error ->
                    keep_progress(S0, SIn, [])
            end
    end;
running(info, {quod_message, _, _OtherChan, _}, S) -> {keep_state, S};   %% Brahms / another namespace's log
%% A membership verdict from our own quod_prolog (a plain message from `deliver_verdict`): emit or withhold
%% the deferred support share. The tag echoes the `{Slot, BlockHash}` we requested with, so the verdict binds
%% to the exact block. Support can advance/skip the head, so reflect that in the Δ timer.
running(info, {membership_verdict, {Sl, BH}, Verdict}, S0) ->
    S1 = on_membership_verdict(Sl, BH, Verdict, S0),
    keep_progress(S0, S1, []);
running(info, {link_up, Peer, Chan, LinkPid}, S0 = #s{chan = Chan}) ->
    keep_progress(S0, handle_link_up(Peer, LinkPid, S0), []);
running(info, {link_error, Peer, Chan}, S0 = #s{chan = Chan}) ->
    %% the dial failed — clear the in-flight marker but KEEP the buffered frames; the tick re-dials
    %% (consensus emits each propose/share only once, so dropping them would stall the slot forever).
    S1 = S0#s{dialing = maps:remove(Peer, S0#s.dialing)},
    keep_progress(S0, S1, []);
%% The sync worker CRASHED before casting `{sync_done,_}` (a normal exit always casts first, and that cast,
%% sent before the exit, is processed before this DOWN — flipping `sync` away from `{pulling,Pid}` to the
%% generic clause below). Clear the single-flight latch + back off; the tick re-arms if still `should_sync`.
%% The worker resumes from the persisted height, so a retry continues from the prefix already on disk.
running(info, {'DOWN', _Ref, process, Pid, _Reason}, S0 = #s{sync = {pulling, Pid}}) ->
    keep_progress(S0, recovery_failed(S0), []);
running(info, {'DOWN', _Ref, process, Pid, _}, S0) ->
    keep_progress(S0, drop_link(Pid, S0), []);
%% Seal the current micro-batch. A stale timeout is harmless: flush_batch/2 only
%% acts when the collecting slot still matches.
running({timeout, batch}, {flush_batch, V}, S0) ->
    S1 = flush_batch(V, S0),
    keep_progress(S0, S1, []);
%% The oldest non-final slot owns one Δ watchdog through all three phases. A timeout may redrive a
%% proposal/finality bundle or issue a complaint, but it never silently disappears at notarization.
running({timeout, progress}, {progress_timeout, V}, S0) ->
    S1 = on_progress_timeout(V, S0),
    keep_progress(S0, S1, [], rearm);
%% Consensus re-drive: sweep any dial that resolved to neither link_up nor link_error (presumed lost),
%% re-dial every peer whose link never came up (its frames are still buffered), AND arm sync — the one
%% place a boot-sync / member gap-fill is kicked (`maybe_arm_sync`, single-flight + paced, off the hot path).
running({timeout, tick}, tick, S0) ->
    S1 = maybe_arm_sync(
           redrive_relays(redrive_inflight(redial_pending(
             sweep_stale_dials(expire_ingress(S0)))))),
    keep_progress(S0, S1, [tick_timeout()]);
%% Only the recovery coordinator can produce `{ready, Height}`: it has pulled every available committee
%% source and observed a certificate quorum at the final local height. Bind completion to the monitored
%% worker pid. We accept the result when the durable head is AT OR PAST the corroborated `H` (`Slot >= H`),
%% not only exactly `H`: a member ingesting the live `{log}` stream during the pull can only advance its
%% head via `commit_block`/`skip_block`, each of which finalizes on a QUORUM cert (`persisted_finality`) —
%% so any slot past `H` is itself cert-corroborated, never a blind advance. Requiring `Slot =:= H` instead
%% would reject a member that stayed caught up under load (its head moved while the probe was in flight),
%% bouncing it back to `unconfirmed` forever — the load stall this guard must not cause.
running(cast, {sync_done, Pid, {ready, H}},
        S0 = #s{sync = {pulling, Pid}, slot = Slot}) when H >= 1, Slot >= H ->
    S1 = S0#s{sync = ready, sync_arm = reset_pace()},
    S2 = apply_committed(S1),
    %% Close the runtime replay even when recovery reaches a quiet head. This cast follows all
    %% replay apply casts from this same process, so reconciliation sees the complete prefix.
    _ = quod_prolog:mark_ready(S2#s.ns),
    keep_progress(S0, S2, []);
%% Any incomplete round returns to the single `unconfirmed` state. Partial windows stay durable and the
%% next worker resumes from the resulting height, but no signing capability survives the failure.
running(cast, {sync_done, Pid, _Result}, S0 = #s{sync = {pulling, Pid}}) ->
    keep_progress(S0, recovery_failed(S0), []);
running(cast, {sync_done, _Pid, _}, S) -> {keep_state, S};   %% result from an obsolete worker
%% The sync worker — and, for an observer, the feed's anti-entropy pull — hands each verified, contiguous
%% window here to persist + replay in slot order. The caller presents an explicit source capability:
%% `{recovery,Pid}` must match the one monitored recovery owner; `feed` is accepted only by a settled
%% observer. This keeps the sole-writer rule local and makes a promotion crossing deterministic.
running({call, From}, {sink_catchup, Source, Es}, S0) ->
    case may_sink(Source, S0) of
        %% `reseat_engine` discards the obsolete volatile round and its head watchdog. The common
        %% transition helper cancels the named timer before the recovered member can vote again.
        true  -> {S1, Reply} = apply_catchup_window(Source, Es, S0),
                 keep_progress(S0, S1, [{reply, From, Reply}]);
        false -> {keep_state, S0, [{reply, From, {error, not_following}}]}
    end;
%% The feed puller closes its whole multi-window replay through this process. All apply casts
%% above and this ready cast therefore have one sender and preserve mailbox order at Prolog.
running({call, From}, finish_feed_replay, S = #s{sync = ready}) ->
    case is_participant(S) of
        false -> _ = quod_prolog:mark_ready(S#s.ns),
                 {keep_state, S, [{reply, From, ok}]};
        true  -> {keep_state, S, [{reply, From, {error, not_following}}]}
    end;
running({call, From}, finish_feed_replay, S) ->
    %% Promotion can revoke feed ownership mid-window. Its member recovery will publish the
    %% ready edge after corroborating the new head; acknowledge the obsolete feed worker now.
    {keep_state, S, [{reply, From, ok}]};
running({call, From}, get_status, S)       -> {keep_state, S, [{reply, From, status_map(S)}]};
running({call, From}, get_committee, S)    -> {keep_state, S, [{reply, From, S#s.validators}]};
running({call, From}, get_genesis_hash, S) -> {keep_state, S, [{reply, From, local_genesis_hash(S)}]};
running({call, From}, get_stats, S)        -> {keep_state, S, [{reply, From, stats_map(S)}]};
running(_EventType, _Event, S)             -> {keep_state, S}.

terminate(_Reason, _State, #s{chan = Chan, store = Store, vote_journal = Journal}) ->
    _ = case Chan of undefined -> ok; _ -> catch quod_reg:unsubscribe({channel, Chan}) end,
    _ = case Store of
            undefined -> ok;
            _         -> try quod_ledger_store:close(Store) catch _:_ -> ok end
        end,
    _ = case Journal of
            undefined -> ok;
            memory    -> ok;
            _         -> try quod_vote_journal:close(Journal) catch _:_ -> ok end
        end,
    ok.

%%%===================================================================
%%% append (propose) → engine → commit → apply
%%%===================================================================

%% Appends collect for a few milliseconds into one block. A sealed proposal owns its
%% parked callers until commit/skip; the next slot may open as soon as that block is
%% notarized, even though the durable committed frontier has not caught up yet.
handle_append(From = #waiter{trace_ctx = TraceCtx}, Change,
              S = #s{ns = Ns}) ->
    _ = quod_trace:add_event(
          TraceCtx, <<"consensus.append_received">>,
          #{'quod.namespace' => Ns,
            'quod.tx.id' => quod_trace:tx_id(Change#transaction.tx_id)}),
    append_entry(local, From, Change, S).

handle_relayed_append(Waiter, Change, S) ->
    append_entry(relayed, Waiter, Change, S).

%% Live arrival: stamp the mono-ms anchor (parks and relay deadlines count queue
%% time against the end-to-end budget), compute the route, execute it.
append_entry(Origin, From, Change, S) ->
    Anchor = quod_time:mono_ms(),
    execute(entry, Origin, From, Change, Anchor, route(entry, Origin, Change, S), S).

%% ---------------------------------------------------------------------------
%% Consensus ingress routing: COMPUTE the decision, then EXECUTE it.
%%
%% `route/4` is the single pure decision function for every change entering
%% consensus — live arrivals (`entry`) and the park-queue drain (`drain`), local
%% authorship and relayed submissions alike — so admission and routing can never
%% fork into drifting paths (the former `drain_dispatchable` preview mirror is
%% gone: the drain executes the SAME decision it previewed). `execute/7` owns
%% every side effect (signing, parking, wire frames, counters), which is what
%% keeps the decision previewable: a `{park,_}` head simply stays parked.
%%
%% Placement follows the deterministic rotation instead of chasing it. `leader/2`
%% is a pure function of the slot, so the author computes the FIRST slot a change
%% can still enter — `T = Floor` (= approved+1) if that slot's proposal is not
%% yet visible, else `Floor+1` — and sends the change to leader(T) ONCE, while
%% the current slot's consensus is still in flight. The receiver parks anything
%% arriving at most ?INGRESS_HORIZON slots ahead of its turn and proposes it the
%% moment its slot opens (the level-triggered drain); only a genuine misroute —
%% the schedule moved past the holder — is redirected back to the author with a
%% concrete forward-looking hint, under the origin's redirect budget. A
%% membership barrier parks unconditionally: the post-adoption schedule is
%% unknowable until the committee block commits, so hints minted against the old
%% validator set would only burn that budget.
%%
%% Origin fixes the trust shape: only the author may relay its own submission
%% (dispatch_relay verifies Peer =:= Author), so `{relay,_,_}` is constructible
%% for LOCAL origin only — a relayed change can leave its holder solely as a
%% `{redirect,_,_}` back through the author. Known accepted hazard: an author
%% whose burst straddles the proposal_visible flip signs consecutive sequences
%% toward two different target slots; if the earlier one loses its race the
%% committed floor passes it and it resolves `stale_seq` — retryable by contract
%% (quod_prolog re-proves under a fresh sequence). The FIFO clause below narrows
%% that window; closing it entirely would take a per-author in-flight order gate
%% for a race the retry already heals.

-type park_cause() :: barrier | fifo | awaiting_turn | prepositioned.
-type route_decision() ::
        {reject, bad_change | too_large}
      | {redirect, node_id() | none, none | slot()}   %% hint, demand slot to arm
      | {park, park_cause()}
      | {collect, slot()}
      | {relay, node_id(), slot()}.                   %% target + demand slot; LOCAL origin only

-spec route(entry | drain, local | relayed, #transaction{}, #s{}) -> route_decision().
route(Pass, local, Change, S) ->
    case may_lead(S) of
        false -> {redirect, none, none};
        true ->
            case local_change_acceptable(Change, S) of
                false -> {reject, bad_change};
                true ->
                    case oversized(Change) of
                        true  -> {reject, too_large};
                        false -> place(Pass, local, Change, S)
                    end
            end
    end;
route(Pass, relayed, Change, S) ->
    case ingress_change_acceptable(Change, S) of
        false -> {reject, bad_change};
        true ->
            case oversized(Change) of
                true ->
                    %% reachable only at the envelope edge of the relay's own byte cap,
                    %% but the gate must hold for BOTH origins, and the caller deserves
                    %% too_large, not a doomed batch
                    {reject, too_large};
                false ->
                    case may_lead(S) of
                        false -> {redirect, none, none};
                        true  -> place(Pass, relayed, Change, S)
                    end
            end
    end.

place(Pass, Origin, Change, S = #s{self = Self}) ->
    case membership_barrier(S) of
        true ->
            {park, barrier};
        false ->
            Floor = S#s.approved + 1,   %% the exact Next when open; the floor while blocked
            Vals = active_validators(S),
            case Origin of
                local   -> place_local(Pass, Change, Floor, Self, Vals, S);
                relayed -> place_relayed(Pass, Change, Floor, Self, Vals, S)
            end
    end.

place_local(Pass, Change, Floor, Self, Vals, S) ->
    case leader(first_seat(Floor, S), Vals) of
        Self ->
            case proposal_slot(S) =:= {ok, Floor}
                     andalso not proposal_visible(Floor, S)
                     andalso admissible_for(Pass, Change, S) of
                true  -> {collect, Floor};
                false -> {park, awaiting_turn}   %% our seat is next — hold for it
            end;
        none ->
            {redirect, none, none};              %% empty committee
        Leader ->
            case Pass =:= entry andalso S#s.ingress_count > 0 of
                %% a live queue is the ONE ordered dispatcher for local egress: joining
                %% the tail preserves this author's sequence order through target flips
                true  -> {park, fifo};
                false -> {relay, Leader, Floor}
            end
    end.

place_relayed(Pass, Change, Floor, Self, Vals, S) ->
    case leads_within(Self, Floor, Vals) of
        true ->
            case Self =:= leader(Floor, Vals)
                     andalso proposal_slot(S) =:= {ok, Floor}
                     andalso admissible_for(Pass, Change, S) of
                true  -> {collect, Floor};
                false -> {park, preposition_cause(Floor, Self, Vals)}
            end;
        false ->
            %% misroute: the schedule moved past this holder. The hint must be a
            %% concrete forward seat — `none` is TERMINAL at the origin
            %% (handle_relay_result chases binary hints only)
            {redirect, leader(first_seat(Floor, S), Vals), Floor}
    end.

%% The first slot a change can still enter, as seen from here: the pipeline floor
%% itself, or one later once the floor's proposal is already out.
first_seat(Floor, S) ->
    case proposal_visible(Floor, S) of
        true  -> Floor + 1;
        false -> Floor
    end.

%% Does Self lead any slot within the horizon of the pipeline floor?
leads_within(Self, Floor, Vals) ->
    N = length(Vals),
    lists:any(fun(K) -> leader(Floor + K, Vals) =:= Self end,
              lists:seq(0, min(?INGRESS_HORIZON, max(N - 1, 0)))).

preposition_cause(Floor, Self, Vals) ->
    case leader(Floor, Vals) of
        Self -> awaiting_turn;   %% leading now, the batch/pipeline just isn't open
        _    -> prepositioned    %% parked AHEAD of our turn — the pre-positioning win path
    end.

%% Executor: the ONLY place a decision becomes effects. Entry parks to the queue
%% TAIL; the drain never executes `{park,_}` (drain_loop holds the head instead),
%% so a drained item can never re-park — strict FIFO by construction.
execute(Pass, Origin, From, Change, Anchor, Decision, S) ->
    case Decision of
        {reject, Why} ->
            reject_append(From, Why, S);
        {redirect, Hint, none} ->
            redirect_append(From, Hint, S);
        {redirect, Hint, WatchSlot} ->
            redirect_append(From, Hint,
                            watch_requested(WatchSlot, count_forwarded(Pass, S)));
        {park, Cause} ->
            park_ingress(Origin, Cause, From, Change, Anchor, S);
        {collect, Slot} when Origin =:= relayed ->
            collect_append(From, Change, Slot, S);
        {collect, Slot} ->
            sign_then(From, Change, S,
                      fun(F, Signed, S1) -> collect_append(F, Signed, Slot, S1) end);
        {relay, Leader, WatchSlot} ->   %% LOCAL origin only, by construction of route/4
            sign_then(From, Change, S,
                      fun(F, Signed, S1) ->
                          relay_append(F, Leader, Signed, Anchor,
                                       watch_requested(WatchSlot,
                                                       count_forwarded(Pass, S1)))
                      end)
    end.

%% Sign exactly once, on the pass that leaves the queue for a batch or the wire.
sign_then(From, Change, S, Then) ->
    case sign_local_change(Change, S) of
        {error, _}       -> reject_append(From, bad_change, S);
        {ok, Signed, S1} -> Then(From, Signed, S1)
    end.

count_forwarded(drain, S) -> S#s{ingress_forwarded = S#s.ingress_forwarded + 1};
count_forwarded(entry, S) -> S.

%% ONE size accounting for a change entering consensus. `signed_size` = encoded bytes
%% plus the sign-time growth headroom of a still-unsigned local item; `item_bytes` adds
%% the once-per-block envelope. The oversize gate, the park-queue byte bound, and batch
%% admission (which adds to a batch already carrying the envelope) all read these, so
%% they can never disagree about how big a change is.
signed_size(Change) ->
    encoded_change_size(Change) + signing_growth(Change).

item_bytes(Change) ->
    ?BATCH_ENVELOPE_BYTES + signed_size(Change).

%% A change that cannot fit even an EMPTY block can never be admitted — terminal, never parked.
oversized(Change) ->
    item_bytes(Change) > ?MAX_BLOCK_BYTES.

%% Would this change enter the batch RIGHT NOW? The single admission predicate shared by
%% live entry and the drain pre-check (so "can it go in" has exactly one definition).
%% Capacity and membership gating only — sequence/duplicate problems are CONTENT verdicts
%% (`stale_seq` / `bad_change`) decided in collect_append, not reasons to wait. Strict
%% FIFO: a non-empty park queue makes every live arrival inadmissible (join the tail),
%% so the queue head — possibly a membership change draining the pipeline — is never
%% starved by queue-jumping.
admissible_now(Change, S = #s{collecting = Collecting}) ->
    S#s.ingress_count =:= 0
        andalso membership_can_enter(Change, S)
        andalso case Collecting of
                    none ->
                        true;   %% oversized/1 already rejected what can't fit alone
                    #batch{items_rev = Items, bytes = Bytes} ->
                        not is_membership_change(Change)   %% membership seals alone
                            andalso length(Items) < ?MAX_BATCH_TXS
                            andalso Bytes + signed_size(Change) =< ?MAX_BLOCK_BYTES
                end.

%% The drain bypasses the queue-nonempty guard: it IS the queue. The route consults
%% this Pass-aware form so a drained item can never re-park behind its own queue-mates
%% (the no-re-park invariant — the entry guard would otherwise see the still-non-empty
%% queue and bounce the head straight back).
admissible_for(entry, Change, S) -> admissible_now(Change, S);
admissible_for(drain, Change, S) -> drain_admissible(Change, S).

drain_admissible(Change, S) -> admissible_now(Change, S#s{ingress_count = 0}).

signing_growth(#transaction{sig = none}) -> ?SIGNED_GROWTH_BYTES;
signing_growth(#transaction{})           -> 0.

%% Is the current slot's proposal already out, as seen from this node? True once we
%% supported it or it notarized — O(1) on existing latches. If the proposal exists but
%% has not reached us yet, relaying is still right: it joins the leader's open batch.
proposal_visible(Next, S = #s{eng = #eng{tree = Tree}}) ->
    (round_state(Next, S))#round.supporting =/= none
        orelse maps:is_key(Next, Tree);
proposal_visible(_Next, _S) ->
    false.

%% The local append API accepts only a structurally valid unsigned transaction
%% authored by this node. Sign after the cheap rejection/park routing but before
%% byte accounting, batching, or relay, so no unsigned live transaction crosses
%% the consensus boundary.
local_change_acceptable(
  #transaction{author = Self, sig = none} = Change,
  #s{self = Self} = S) ->
    ingress_change_acceptable(Change, S);
local_change_acceptable(_Change, _S) ->
    false.

sign_local_change(#transaction{author = Self, sig = none} = Change,
                  #s{ns = Ns, self = Self, id = #{pubkey := Self} = Id,
                     next_author_seq = Seq} = S)
  when is_binary(Self), byte_size(Self) =:= 32 ->
    case quod_transaction:sign(Ns, Change#transaction{author_seq = Seq}, Id) of
        {ok, Signed} -> {ok, Signed, S#s{next_author_seq = Seq + 1}};
        {error, _} = Error -> Error
    end;
sign_local_change(#transaction{}, _S) ->
    {error, invalid_local_author}.

reject_append(From, bad_change, S) ->
    reply_now(From, {error, bad_change}, S#s{r_bad = S#s.r_bad + 1});
reject_append(From, too_large, S) ->
    reply_now(From, {error, too_large}, S#s{r_bad = S#s.r_bad + 1});
reject_append(From, stale_seq, S) ->   %% content lost a routing race; retryable by contract,
                                       %% so it counts as r_stale, NEVER as r_bad — r_bad is
                                       %% the "malformed workload" alarm and must stay quiet
                                       %% for races the caller's retry heals
    reply_now(From, {error, stale_seq}, S#s{r_stale = S#s.r_stale + 1});
reject_append(From, busy, S) ->
    reply_now(From, {error, busy}, S#s{r_busy = S#s.r_busy + 1}).

%%%===================================================================
%%% ingress park queue — take a ticket, drain on the pipeline's own events
%%%===================================================================

%% Park one append (FIFO tail on `entry`; back to the HEAD on the never-expected `drain`
%% re-park, preserving order and stopping the drain loop). Overflow of any bound is the
%% real backpressure boundary; together with the TTL sweep below these are the only
%% remaining live sources of `{error, busy}`.
park_ingress(Origin, Cause, Waiter, Change, Anchor,
             S = #s{ingress_authors = Authors}) ->
    Author = Change#transaction.author,
    Bytes = item_bytes(Change),
    PerAuthor = maps:get(Author, Authors, 0),
    case S#s.ingress_count >= ?MAX_INGRESS_TXS
         orelse S#s.ingress_bytes + Bytes > ?MAX_INGRESS_BYTES
         orelse PerAuthor >= ?MAX_INGRESS_PER_AUTHOR of
        true ->
            {S1, Actions} = reject_append(Waiter, busy, S),
            {S1#s{ingress_overflow = S1#s.ingress_overflow + 1}, Actions};
        false ->
            _ = quod_trace:add_event(
                  waiter_trace_ctx(Waiter), <<"consensus.parked">>,
                  #{'quod.ingress.depth' => S#s.ingress_count + 1,
                    'quod.ingress.cause' => Cause}),
            Item = #ingress_item{origin = Origin, waiter = Waiter, change = Change,
                                 bytes = Bytes, enqueued_at = Anchor},
            S1 = S#s{ingress = queue:in(Item, S#s.ingress),
                     ingress_count = S#s.ingress_count + 1,
                     ingress_bytes = S#s.ingress_bytes + Bytes,
                     ingress_authors = Authors#{Author => PerAuthor + 1},
                     ingress_prepositioned =
                         S#s.ingress_prepositioned
                         + case Cause of prepositioned -> 1; _ -> 0 end},
            %% Parked demand arms the head watchdog CONSTRUCTIVELY: every park is a
            %% claim that the pipeline floor must move, so register it as demand
            %% instead of relying on each park cause to coincide with head evidence
            %% (the pre-positioned park is exactly the cause with none of its own).
            {watch_requested(S1#s.approved + 1, S1), []}
    end.

ingress_take_head(S = #s{ingress = Q, ingress_authors = Authors}) ->
    {{value, #ingress_item{change = Change, bytes = Bytes}}, Q1} = queue:out(Q),
    Author = Change#transaction.author,
    Authors1 = case maps:get(Author, Authors) of
                   1 -> maps:remove(Author, Authors);
                   N -> Authors#{Author => N - 1}
               end,
    S#s{ingress = Q1,
        ingress_count = S#s.ingress_count - 1,
        ingress_bytes = S#s.ingress_bytes - Bytes,
        ingress_authors = Authors1}.

%% Event-driven drain, LEVEL-triggered from keep_progress (the slot-6180 lesson: an
%% edge-triggered hook that can miss an edge eventually does; an O(1)-guarded level
%% check on the universal transition seam cannot). Strict FIFO: only the head is ever
%% considered, and a head routed `{park,_}` — waiting for this node's imminent turn,
%% a capacity gate, or a membership barrier — HOLDS the loop; deliberately, since a
%% waiting head must never be overtaken. Everything else pops and executes the exact
%% decision that was previewed, so a drained item can never re-park: the old preview
%% mirror and its no-progress backstop are gone by construction.
drain_ingress(S = #s{ingress_count = 0}) -> {S, []};
drain_ingress(S) -> drain_loop(S, [], 0).

drain_loop(S = #s{ingress_count = 0}, Acc, N) ->
    seal_drained(S, Acc, N);
drain_loop(S, Acc, N) ->
    {value, #ingress_item{origin = Origin, waiter = Waiter,
                          change = Change, enqueued_at = Anchor}} =
        queue:peek(S#s.ingress),
    case route(drain, Origin, Change, S) of
        {park, _Cause} ->
            seal_drained(S, Acc, N);   %% the head keeps waiting; FIFO holds the line
        Decision ->
            S1 = ingress_take_head(S),
            _ = quod_trace:add_event(
                  waiter_trace_ctx(Waiter), <<"consensus.drained">>,
                  #{'quod.ingress.depth' => S1#s.ingress_count}),
            {S2, Actions} = execute(drain, Origin, Waiter, Change, Anchor, Decision, S1),
            drain_loop(S2, Acc ++ Actions, N + 1)
    end.

%% A multi-item drain seals its batch NOW: the backlog already waited a full flight, a
%% 2ms window would only re-add latency (block N+1 = what arrived during block N — the
%% natural batch size). A SINGLETON drain keeps the normal micro-batch window so relays
%% landing in the same slot-open moment can still join it (its arm action is already in Acc).
seal_drained(S = #s{collecting = #batch{slot = Slot}}, Acc, N) when N >= 2 ->
    {flush_batch(Slot, S), Acc ++ [{{timeout, batch}, cancel}]};
seal_drained(S, Acc, _N) ->
    {S, Acc}.

%% TTL sweep, on the consensus tick. FIFO + constant TTL make expiry order = queue
%% order, so this peeks the HEAD only — O(expired), free when nothing expired. It walks
%% the ingress queue EXCLUSIVELY: every other waiter container (collecting batch,
%% local_proposals, relay_pending) has its own lifecycle, and expiring any of them here
%% would double-reply. An expiring stall must fail visibly: `busy` to the caller.
expire_ingress(S = #s{ingress_count = 0}) -> S;
expire_ingress(S) ->
    expire_ingress(quod_time:mono_ms() - ?INGRESS_TTL_MS, S).

expire_ingress(Cutoff, S = #s{ingress_count = C}) when C > 0 ->
    case queue:peek(S#s.ingress) of
        {value, #ingress_item{enqueued_at = T, waiter = Waiter}} when T =< Cutoff ->
            _ = quod_trace:add_event(
                  waiter_trace_ctx(Waiter), <<"consensus.expired">>, #{}),
            S1 = reply_waiter(Waiter, {error, busy}, ingress_take_head(S)),
            expire_ingress(Cutoff, S1#s{ingress_expired = S1#s.ingress_expired + 1,
                                        r_busy = S1#s.r_busy + 1});
        _ ->
            S
    end;
expire_ingress(_Cutoff, S) ->
    S.

%% Recovery re-seat / shutdown of the volatile window: parked callers are nacked
%% retryably, exactly like a discarded collecting batch.
nack_ingress(S = #s{ingress_count = 0}) -> S;
nack_ingress(S) ->
    S1 = lists:foldl(
           fun(#ingress_item{waiter = Waiter}, Acc) ->
                   reply_waiter(Waiter, {error, skipped}, Acc)
           end, S, queue:to_list(S#s.ingress)),
    S1#s{ingress = queue:new(), ingress_count = 0,
         ingress_bytes = 0, ingress_authors = #{}}.

redirect_append(From, Leader, S) ->
    reply_now(From, {error, not_in_charge, Leader},
              S#s{r_redirect = S#s.r_redirect + 1}).

reply_now(Waiter = #waiter{reply_to = {relay, _Peer, _ReqId}}, Reply, S) ->
    {reply_waiter(Waiter, Reply, S), []};
reply_now(Waiter = #waiter{reply_to = From}, Reply, S) ->
    finish_waiter_trace(Waiter, Reply),
    {S, [{reply, From, Reply}]};
reply_now({relay, Peer, ReqId}, Reply, S) ->
    {reply_relay(Peer, ReqId, Reply, S), []}.

%% `Anchor` = the submission's ORIGINAL arrival time (mono ms): a drained item's park
%% wait counts against the relay deadline, so consensus still resolves or definitively
%% fails inside the caller's park-TTL envelope, exactly as before the queue existed.
relay_append(From, Leader, Change, Anchor,
             S = #s{ns = Ns, relay_pending = Pending,
                    relay_timeout_ms = RelayTimeout}) ->
    case quod_transaction:submission(Ns, Change) of
        {error, _} ->
            reject_append(From, bad_change, S);
        {ok, Submission} ->
            ReqId = quod_transaction:submission_id(Submission),
            case {maps:is_key(ReqId, Pending),
                  map_size(Pending) >= ?MAX_RELAY_PENDING} of
                {true, _} ->
                    reject_append(From, bad_change, S);
                {false, true} ->
                    reject_append(From, busy, S);
                {false, false} ->
                    TraceCtx = waiter_trace_ctx(From),
                    _ = quod_trace:add_event(
                          TraceCtx, <<"consensus.relayed">>,
                          #{'quod.relay.target' => trace_node_id(Leader)}),
                    Frame = quod_relay:encode(
                              Ns, {relay_submit, ReqId, Submission,
                                   quod_trace:inject(TraceCtx)}),
                    Relay = #relay_pending{
                               from = From, target = Leader,
                               frame = Frame,
                               deadline = Anchor + RelayTimeout,
                               next_retry = quod_time:mono_ms() + ?RELAY_RETRY_MS},
                    S1 = send_frame(Leader, Frame, S),
                    {S1#s{relay_pending = Pending#{ReqId => Relay}}, []}
            end
    end.

%% A depth-one pipeline permits proposing H+2 after H+1 is approved but before it
%% commits. It stops there until commit catches up. Membership blocks are barriers,
%% and a complaint-finalized slot waiting behind an earlier commit is not reopened.
proposal_slot(S = #s{slot = Committed, approved = Approved, collecting = Collecting,
                     local_proposals = Local, commit_buf = Buf}) ->
    Next = Approved + 1,
    HasBatch = case Collecting of #batch{slot = Next} -> true; _ -> false end,
    Open = live_pipeline_slot(Next, Committed)
           andalso (HasBatch orelse not maps:is_key(Next, Local))
           andalso not maps:is_key(Next, Buf)
           andalso not membership_barrier(S),
    case Open of true -> {ok, Next}; false -> blocked end.

%% One definition owns the complete volatile consensus window: the durable head's successor plus the
%% configured number of approved descendants. Proposal admission, final-vote selection, block recovery,
%% and its metrics must never drift onto different slot ranges.
-spec live_pipeline_slot(slot(), slot()) -> boolean().
live_pipeline_slot(Slot, Committed) ->
    Slot > Committed andalso Slot =< Committed + ?PIPELINE_DEPTH + 1.

%% Capacity and membership gating live in the router (`admissible_now/2` — inadmissible
%% parks, it no longer rejects), so only CONTENT verdicts remain here: a sequence below
%% the floor is `stale_seq` (retryable — the write lost a routing race, its content is
%% fine), a duplicate tx_id is `bad_change` (terminal).
collect_append(From, Change, Slot, S = #s{collecting = none}) ->
    Bytes = ?BATCH_ENVELOPE_BYTES + encoded_change_size(Change),
    case sequence_payload_ok([Change], S) of
        false ->
            reject_append(From, stale_seq, S);
        true ->
            _ = quod_trace:add_event(
                  waiter_trace_ctx(From), <<"consensus.queued">>,
                  #{'quod.consensus.slot' => Slot}),
            Batch = #batch{slot = Slot, parent = S#s.approved,
                           items_rev = [{From, Change}], bytes = Bytes},
            S1 = S#s{collecting = Batch, appends = S#s.appends + 1},
            case is_membership_change(Change) orelse batch_ms() =:= 0 of
                true  -> {flush_batch(Slot, S1), [{{timeout, batch}, cancel}]};
                false -> {S1, [{{timeout, batch}, batch_ms(), {flush_batch, Slot}}]}
            end
    end;
collect_append(From, Change, Slot,
               S = #s{collecting = #batch{slot = Slot, items_rev = Items, bytes = Bytes} = Batch}) ->
    Added = encoded_change_size(Change),
    Duplicate = lists:any(fun({_From, T}) -> T#transaction.tx_id =:= Change#transaction.tx_id end, Items),
    Candidate = [T || {_Waiter, T} <- lists:reverse([{From, Change} | Items])],
    case {Duplicate, sequence_payload_ok(Candidate, S)} of
        {true, _}      -> reject_append(From, bad_change, S);
        {false, false} -> reject_append(From, stale_seq, S);
        {false, true} ->
            _ = quod_trace:add_event(
                  waiter_trace_ctx(From), <<"consensus.queued">>,
                  #{'quod.consensus.slot' => Slot}),
            Batch1 = Batch#batch{items_rev = [{From, Change} | Items], bytes = Bytes + Added},
            S1 = S#s{collecting = Batch1, appends = S#s.appends + 1},
            case length(Batch1#batch.items_rev) >= ?MAX_BATCH_TXS of
                true  -> {flush_batch(Slot, S1), [{{timeout, batch}, cancel}]};
                false -> {S1, []}
            end
    end.

flush_batch(Slot, S = #s{collecting = #batch{slot = Slot, parent = Parent,
                                              items_rev = ItemsRev}}) ->
    Items = lists:reverse(ItemsRev),
    Payload = [Change || {_From, Change} <- Items],
    case acceptable_collected_payload(Payload, S) of
        false -> reject_collected_batch(Items, S);
        true  -> propose_batch(Slot, Parent, Items, Payload, S)
    end;
flush_batch(_Slot, S) -> S.   %% stale named timeout after an early/full flush

propose_batch(Slot, Parent, Items, Payload, S) ->
    Waiters = [From || {From, _Change} <- Items],
    Block = #block{slot = Slot, parent = Parent, payload = Payload,
                   timestamp = max(quod_time:now_ms(), parent_timestamp(Parent, S))},
    BH = block_hash(Block),
    _ = [quod_trace:add_event(
           waiter_trace_ctx(Waiter), <<"consensus.proposed">>,
           #{'quod.consensus.slot' => Slot,
             'quod.batch.transactions' => length(Payload)})
         || {Waiter, _Change} <- Items],
    Local = #local_proposal{hash = BH, waiters = Waiters,
                            trace_ctxs = [waiter_trace_ctx(W) || W <- Waiters]},
    S1 = S#s{collecting = none,
             local_proposals = (S#s.local_proposals)#{Slot => Local},
             proposals = S#s.proposals + 1,
             batched_txs = S#s.batched_txs + length(Payload)},
    S2 = broadcast({propose, Block}, S1),
    S3 = engine_step([{block, BH, Block}], S2),
    watch_proposal(Slot, support_or_validate(Block, BH, S3)).

reject_collected_batch(Items, S) ->
    S1 = reply_waiters([From || {From, _Change} <- Items],
                       {error, bad_change}, S),
    S1#s{collecting = none, r_bad = S1#s.r_bad + length(Items)}.

encoded_change_size(Change) ->
    byte_size(term_to_binary(Change, [deterministic])).

batch_ms() ->
    case application:get_env(quod, simplex_batch_ms, ?BATCH_MS) of
        N when is_integer(N), N >= 0 -> N;
        _                            -> ?BATCH_MS
    end.

membership_can_enter(Change, #s{approved = A, slot = C}) ->
    not is_membership_change(Change) orelse A =:= C.

membership_barrier(#s{slot = Committed, eng = #eng{tree = Tree}}) ->
    lists:any(fun({Sl, #block{payload = Payload}}) ->
                      Sl > Committed andalso payload_touches_committee(Payload)
              end, maps:to_list(Tree)).

parent_timestamp(Parent, #s{slot = Parent, last_ts = Last}) -> Last;
parent_timestamp(Parent, #s{eng = #eng{tree = Tree}}) ->
    (maps:get(Parent, Tree))#block.timestamp.

%% Offer items to the consensus engine and act on every event it emits (to a fixpoint), returning the
%% new state. Commit replies are sent inline via `gen_statem:reply` (the caller for that slot is parked).
engine_step(Items, S) ->
    {Eng1, EventsRev} = lists:foldl(fun(It, {E, Acc}) ->
                                        {E1, Es} = offer_engine_item(It, E),
                                        {E1, lists:reverse(Es, Acc)}
                                    end, {S#s.eng, []}, Items),
    apply_events(lists:reverse(EventsRev), S#s{eng = Eng1}).

offer_engine_item({block, BH, #block{} = B}, Eng) -> eng_offer_hashed(BH, B, Eng);
offer_engine_item(Item, Eng) -> eng_offer(Item, Eng).

apply_events([], S)             -> S;
apply_events([Event | Rest], S) -> apply_events(Rest, apply_event(Event, S)).

%% A newly-formed (or first-learned) cert: disseminate it to the committee (§2.3.1).
apply_event({broadcast, Cert}, S) ->
    broadcast({cert, Cert}, S);
%% A block was notarized: sign + emit our commit share — UNLESS we already complaint-signed this slot
%% (`may_commit` guard) OR we judged its membership change INVALID (`#round.invalid`). Recording
%% the round's `commit` latch makes the symmetric `may_complain` guard hold, so an honest node contributes to at
%% most one of {commit cert, complaint cert} per slot — the safety rule. The `invalid` guard is
%% belt-and-braces: a node that evaluated a membership proposal and rejected it never endorses at ANY phase,
%% even if the block notarized via others (an absent verdict, by contrast, must NOT bar a commit share — a
%% support cert already proves ≥ f+1 honest validations).
apply_event({notarized, #block{} = Block}, S0) ->
    choose_final_vote(Block#block.slot, notarized, approve_block(Block, S0));
%% A block is final: apply it, in slot order (out-of-order finalizations are buffered — contiguous apply).
apply_event({committed, Slot, Block}, S) ->
    commit_contiguous(Slot, Block, S);
%% A slot was complaint-skipped: finalize it as an empty (`noop`) slot, in order — advancing the height
%% so the rotated leader for the next slot proposes.
apply_event({skipped, Slot}, S) ->
    skip_contiguous(Slot, S).

approve_block(#block{slot = Sl}, S = #s{approved = Approved}) ->
    %% A competing/equivocating proposal can notarize while this leader is still collecting its own batch
    %% for the same slot. Advancing `approved` without dropping that stale batch made the next append hit no
    %% `collect_append` clause and crash the statem. The slot is now decided at the approval layer, so reply
    %% retryably and discard the obsolete collection before advancing.
    S1 = nack_collecting_le(Sl, S),
    watch_notarized(Sl, S1#s{approved = max(Approved, Sl)}).

%% Persist the committed block (durable before we ack), apply it into quod_prolog, advance the height,
%% clear the per-slot latches, and reply `{ok, Slot}` to every caller in the batch.
commit_block(Slot, #block{payload = Payload, timestamp = BlockTs}, S = #s{store = Store, eng = Eng}) ->
    BH = engine_block_hash(Slot, S),
    case persisted_finality(Slot, BH, Eng) of
        none -> weak_cert_wait(commit, Slot, BH, S);   %% Slice E: don't finalize on a sub-quorum cert
        Cert ->
            Data = quod_ledger:data(Payload),
            E = #entry{index = Slot, data = Data, timestamp = BlockTs, cert = Cert},
            {ok, Store1} = persist_entry(Store, E, Slot, S),
            publish_feed(Slot, E, S),   %% LIVE commit ⇒ let the dissemination feed push it (never on replay/rebuild)
            SCommitted = resolve_committed_relays(
                           Payload, Slot,
                           S#s{store = Store1, commits = S#s.commits + 1,
                               last_ts = max(S#s.last_ts, BlockTs),
                               author_seqs =
                                   advance_author_seqs(Payload, S#s.author_seqs)}),
            S0 = ack_local(Slot, SCommitted),
            S1 = adopt_committee(Data, finalize(Slot, S0)),
            apply_live(Slot, Data, confirm_live(S1))
    end.

persist_entry(Store, Entry, Slot, S) ->
    quod_trace:with_optional_span(
      trace_context_for_slot(Slot, S), <<"quod.ledger.sync">>, internal,
      #{'quod.namespace' => S#s.ns, 'quod.consensus.slot' => Slot},
      fun() -> quod_ledger_store:append(Store, [Entry]) end).

resolve_committed_relays(_Payload, _Slot, S = #s{relay_pending = Pending})
  when map_size(Pending) =:= 0 ->
    S;
resolve_committed_relays(Payload, Slot, S = #s{relay_pending = Pending}) ->
    RequestIds =
        maps:from_keys(
          [quod_transaction:submission_id(Submission)
           || Transaction <- Payload,
              {ok, Submission} <- [quod_transaction:submission(S#s.ns,
                                                               Transaction)]],
          true),
    maps:fold(
      fun(ReqId, #relay_pending{from = From}, Acc) ->
              case maps:is_key(ReqId, RequestIds) of
                  true ->
                      reply_waiter(
                        From, {ok, Slot},
                        Acc#s{relay_pending =
                                  maps:remove(ReqId, Acc#s.relay_pending)});
                  false ->
                      Acc
              end
      end, S, Pending).

engine_block_hash(Slot, #s{eng = #eng{tree_hashes = Hashes}}) ->
    maps:get(Slot, Hashes).

%% A committed transaction advances the committee FACTS (`#s.validators`) at the slot boundary, IN-PROCESS —
%% by reading the `peer_admitted` asserts/retracts out of the block we just committed. This ALWAYS updates
%% the facts. The engine's VOTING set is then fed SEPARATELY through the epoch seam (`active_validators/1`):
%% today (epoch length 1) that is the identity. Committee blocks are explicit-finality pipeline barriers,
%% so their certs are formed and pruned under the OLD set before any next-slot proposal can open; slot+1
%% is the first slot voted under the NEW set. Never update this from an outside message: it could arrive
%% after the next round had started. The facts are a pure function of the committed prefix and every node
%% crosses the boundary at the same logical point. The delta folds via the SAME
%% `apply_committee_delta/2` as the restart re-fold, so the facts can never drift from a fresh re-fold.
adopt_committee(Change, S = #s{validators = V, self = Self, eng = Eng}) ->
    case apply_committee_delta(Change, V) of
        V  -> S;                                    %% no `peer_admitted` change → facts unchanged
        V1 -> %% learn the fresh admit-fact address (OVERWRITE): the change just passed quorum-many
              %% peer_ready verdicts, so this address is live NOW — this is the dial hint a member that
              %% missed the candidate's digests (a quorum<N voter) needs to reach the new member for the
              %% next slot. Fires on every member at the live finality point (commit_block).
              _ = [quod_quic:learn(Pk, Ep) || {Pk, Ep} <- admitted_endpoints(Change), Pk =/= Self],
              %% DEMOTION log-event (pairs with catchup_membership_transition's promotion notice): a member
              %% commit-signs its
              %% own removal as a voter, so it reaches here still a member and observes itself drop out.
              _ = case lists:member(Self, V) andalso not lists:member(Self, V1) of
                      true  -> logger:notice("quod[~s]: removed from the committee — now a read-only "
                                             "observer (committee ~b)", [S#s.ns, length(V1)]);
                      false -> ok
                  end,
              S1 = prune_consensus_links(S#s{validators = V1}),   %% FACTS + transport scope advance
              S1#s{eng = eng_set_validators(active_validators(S1), Eng)}   %% engine tracks the active set
    end.

%% A complaint cert skipped this slot: persist an empty `noop` entry so the store height (and every
%% node's) advances contiguously, then nack any caller that had proposed it so the client retries under
%% the rotated leader. `quod_prolog` applies a `noop` as a pure cursor advance (no fact change).
skip_block(Slot, S = #s{store = Store, eng = Eng}) ->
    case persisted_cert(complaint, Slot, none, Eng) of   %% minimal complaint cert that skipped this slot
        none -> weak_cert_wait(complaint, Slot, none, S);   %% Slice E: don't skip-finalize on a sub-quorum cert
        Cert ->
            E = #entry{index = Slot, data = noop, cert = Cert},
            {ok, Store1} = persist_entry(Store, E, Slot, S),
            publish_feed(Slot, E, S),   %% a committed `noop` skip disseminates too, so followers stay contiguous
            S0 = nack_local(Slot, S#s{store = Store1, skips = S#s.skips + 1}),
            S1 = finalize(Slot, S0),
            S2 = S1#s{approved = max(S1#s.approved, Slot)},
            apply_live(Slot, noop, confirm_live(S2))
    end.

%% Slice E — the weak-cert finalize guard. `persisted_cert` returned `none`: the pool's cert for this slot
%% lacks a quorum of signatures from the committee AS-OF-this-slot. This is the mid-flight committee-change /
%% stale-cert hazard (`doc/deferred.md` §3): a node lagging across a committee change can form a cert under
%% the OLD (smaller) quorum for a later slot, and finalizing it would locally commit a slot the honest
%% network (using the NEW, larger quorum) may never commit — forking this node from a catch-up joiner that
%% reconstructs the committee as-of the slot. So REFUSE to finalize and:
%%   - EVICT the stale cert from the pool. Load-bearing: `ingest_share` re-forms a cert only when the key is
%%     ABSENT (`maps:is_key` guard), so without eviction the wait is forever; a re-relayed copy can't
%%     re-enter because `verify_cert` rejects it under the current quorum.
%%   - UN-MARK the slot committed/skipped, so `detect_commits`/`detect_complaints` re-fire once a genuine
%%     cert forms under the current set (the SHARES are kept — the re-form draws on them).
%% The height does NOT advance and nothing is appended: the node waits at `Slot-1` until either enough
%% shares under the current set arrive (re-form → re-drive → finalize with a valid cert) or the trustless
%% catch-up / feed path delivers the properly-committed block. A laggard waiting is correct; a laggard
%% forking is not. The `commit_buf` entry was already taken by `drain_commits`, so this returns without a
%% height advance and the drain loop stops — no busy loop.
weak_cert_wait(Kind, Slot, BH, S) ->
    S#s{eng = eng_evict_final(Kind, Slot, BH, S#s.eng), weak_cert_waits = S#s.weak_cert_waits + 1}.

%% Advance the height past a now-durable slot and drop its per-slot in-flight state: the engine window,
%% local proposal, support/commit/complaint latches, and membership validation
%% latches (all bounded to the in-flight window).
finalize(Slot, S0) ->
    S = nack_collecting_le(Slot, S0),   %% a still-collecting batch for this now-finalized slot: nack its
                                        %% parked callers so they retry, not leave them to time out (below)
    {ok, Journal1} = prune_vote_journal(Slot, S#s.vote_journal),
    clear_requested_le(
      Slot,
      S#s{slot = Slot,
          vote_journal = Journal1,
          eng = eng_prune(Slot, S#s.eng),   %% this slot is durable now — drop it from the in-flight pool
          block_requests = prune_block_requests(Slot, S#s.block_requests),
          rounds = maps:remove(Slot, S#s.rounds),
          local_proposals = maps:remove(Slot, S#s.local_proposals)}).

ack_local(Slot, S) -> reply_local(Slot, {ok, Slot}, S).
nack_local(Slot, S) -> reply_local(Slot, {error, skipped}, S).

reply_local(Slot, Reply, S = #s{local_proposals = Local}) ->
    case maps:take(Slot, Local) of
        {#local_proposal{waiters = Waiters}, Local1} ->
            reply_waiters(Waiters, Reply, S#s{local_proposals = Local1});
        error -> S
    end.

%% A batch still being collected (not yet sealed into a proposal) parks its callers with NO reply. When its
%% slot finalizes -- reachable when that slot was complaint-SKIPPED, or COMMITTED by a competing block,
%% before our batch sealed -- nack them {error, skipped} so they retry at once, instead of hanging until the
%% ~30s park TTL (then getting a bogus {error, timeout}); then drop the batch. `nack_collecting/1` is the
%% shared body, reused by the recovery re-seat (`nack_inflight/1`), which discards the whole in-flight window.
nack_collecting_le(Slot, S = #s{collecting = #batch{slot = Sl}}) when Sl =< Slot -> nack_collecting(S);
nack_collecting_le(_Slot, S) -> S.

nack_collecting(S = #s{collecting = #batch{items_rev = Items}}) ->
    S1 = reply_waiters([From || {From, _Change} <- Items],
                       {error, skipped}, S),
    S1#s{collecting = none};
nack_collecting(S) -> S.

reply_waiters(Waiters, Reply, S) ->
    lists:foldl(fun(Waiter, Acc) -> reply_waiter(Waiter, Reply, Acc) end,
                S, Waiters).

reply_waiter(Waiter = #waiter{reply_to = ReplyTo}, Reply, S) ->
    finish_waiter_trace(Waiter, Reply),
    reply_waiter(ReplyTo, Reply, S);
reply_waiter({relay, Peer, ReqId}, Reply, S) ->
    reply_relay(Peer, ReqId, Reply, S);
reply_waiter(From, Reply, S) ->
    gen_statem:reply(From, Reply),
    S.

waiter_trace_ctx(#waiter{trace_ctx = TraceCtx}) -> TraceCtx;
waiter_trace_ctx(_) -> otel_ctx:new().

new_waiter(ReplyTo, ParentCtx, Change, Ns, Relayed) ->
    {TraceCtx, SpanCtx} = quod_trace:start_span(
                            ParentCtx, <<"quod.consensus.append">>, internal,
                            #{'quod.namespace' => Ns,
                              'quod.tx.id' => quod_trace:tx_id(Change#transaction.tx_id),
                              'quod.relay.hop' => Relayed}),
    #waiter{reply_to = ReplyTo, trace_ctx = TraceCtx, trace_span = SpanCtx}.

finish_waiter_trace(#waiter{trace_ctx = TraceCtx, trace_span = SpanCtx}, Reply) ->
    _ = quod_trace:add_event(
          TraceCtx, <<"consensus.append_result">>, trace_reply_attributes(Reply)),
    quod_trace:finish_span(SpanCtx, Reply).

trace_reply_attributes({ok, Slot}) ->
    #{'quod.outcome' => <<"committed">>, 'quod.consensus.slot' => Slot};
trace_reply_attributes({error, Reason}) when is_atom(Reason) ->
    #{'quod.outcome' => atom_to_binary(Reason, utf8)};
trace_reply_attributes({error, not_in_charge, _Hint}) ->
    #{'quod.outcome' => <<"not_in_charge">>};
trace_reply_attributes(_) ->
    #{'quod.outcome' => <<"unknown">>}.

trace_node_id(Id) when is_binary(Id) -> binary:encode_hex(Id, lowercase);
trace_node_id({Host, Port}) ->
    iolist_to_binary(io_lib:format("~ts:~B", [Host, Port]));
trace_node_id(_) -> <<"unknown">>.

trace_context_for_slot(Slot, #s{local_proposals = Local}) ->
    case maps:get(Slot, Local, undefined) of
        #local_proposal{trace_ctxs = [TraceCtx | _]} -> TraceCtx;
        _ -> undefined
    end.

round_state(Slot, #s{rounds = Rounds}) ->
    maps:get(Slot, Rounds, #round{}).

put_round(Slot, Round, S = #s{rounds = Rounds}) ->
    S#s{rounds = Rounds#{Slot => Round}}.

complained_slots(#s{rounds = Rounds}) ->
    [Sl || {Sl, Round} <- maps:to_list(Rounds), round_complained(Round)].

committed_slots(#s{rounds = Rounds}) ->
    [Sl || {Sl, Round} <- maps:to_list(Rounds), round_committed(Round)].

round_committed(#round{final = {commit, _}}) -> true;
round_committed(#round{}) -> false.

round_complained(#round{final = complaint}) -> true;
round_complained(#round{}) -> false.

prune_vote_journal(_Slot, memory) -> {ok, memory};
prune_vote_journal(Slot, Journal) -> quod_vote_journal:prune(Journal, Slot).

prune_block_requests(Committed, Requests) ->
    maps:filter(fun({Slot, _BH}, _Retry) -> Slot > Committed end, Requests).

%% Sign + emit our SUPPORT share for a block — offer it to our engine AND broadcast it — unless the slot
%% is already committed history, or we already supported a block for this slot (no double-support, the
%% honest-party one-block-per-slot invariant).
support_block(Block, BH, S) ->
    case may_vote(S) of
        true  -> support_block_ready(Block, BH, S);
        false -> S
    end.

support_block_ready(#block{slot = Sl}, _BH, S) when Sl =< S#s.slot -> S;
support_block_ready(#block{slot = Sl}, BH, S) ->
    Round = round_state(Sl, S),
    case Round#round.supporting of
        none -> case record_share(support, Sl, BH, S) of
                    blocked -> S;
                    {ok, Share, S1} ->
                        engine_step([{share, Share}],
                                    broadcast({share, Share}, S1))
                end;
        SupportedBH ->
            case BH of
                %% The SAME block again = the leader is REDRIVING the stuck slot — which means it is
                %% missing votes, possibly OURS (our frames to it were lost; the transport is send-once).
                %% Re-echo our own share(s) for it — deterministic Ed25519 re-signs to identical bytes —
                %% so a redrive heals both directions. Bounded by the leader's Δ (one echo per re-fire).
                SupportedBH -> {ok, Support} = own_share(support, Sl, BH, S),
                      Commit = case Round#round.final of
                                   {commit, BH} ->
                                       {ok, Sh} = own_share(commit, Sl, BH, S), [{share, Sh}];
                                   _ -> []
                               end,
                      Own = [{share, Support} | Commit],
                      lists:foldl(fun broadcast/2, S, Own);
                _  -> S   %% a DIFFERENT block for a slot we already signed — equivocation; never double-sign
            end
    end.

%% Commit/complaint certs can arrive out of slot order over the async transport; buffer each
%% finalization (a committed block, or a skip) and apply strictly in ascending slot order, so the
%% durable store (which enforces contiguity) never sees a gap.
commit_contiguous(Slot, Block, S) ->
    drain_commits(S#s{commit_buf = (S#s.commit_buf)#{Slot => {commit, Block}}}).
skip_contiguous(Slot, S) ->
    drain_commits(S#s{commit_buf = (S#s.commit_buf)#{Slot => skip}}).

drain_commits(S = #s{slot = H, commit_buf = Buf}) ->
    case maps:take(H + 1, Buf) of
        {{commit, Block}, Buf1} -> drain_commits(commit_block(H + 1, Block, S#s{commit_buf = Buf1}));
        {skip, Buf1}            -> drain_commits(skip_block(H + 1, S#s{commit_buf = Buf1}));
        error                   -> S
    end.

%%%===================================================================
%%% transport ({log, Ns} channel over quod_link)
%%%===================================================================

%% Route one inbound consensus message into the engine. A hostile peer can put any term on the wire, so
%% every message is SHAPE-VALIDATED first — a record with a malformed field (e.g. a non-integer slot)
%% would otherwise crash the statem downstream (share_bytes packs `Slot:64`). Malformed ⇒ silently dropped.
dispatch(Peer, {propose, #block{} = B}, S) -> case well_formed_block(B) of true -> on_propose(Peer, B, S); false -> S end;
dispatch(_Peer, {share, #share{} = Sh}, S) -> case well_formed_share(Sh) of true -> maybe_join_complaint(Sh, engine_step([{share, Sh}], S)); false -> S end;
dispatch(_Peer, {cert,  #cert{}  = C},  S) -> case well_formed_cert(C)  of true -> engine_step([{cert, C}], S);   false -> S end;
dispatch(Peer, {block_request, Slot, BH}, S)
  when is_integer(Slot), Slot >= 1, is_binary(BH), byte_size(BH) =:= 32 ->
    serve_certified_block(Peer, Slot, BH, S);
dispatch(Peer, {certified_block, #block{} = Block, #cert{} = Cert}, S) ->
    case well_formed_block(Block) andalso well_formed_cert(Cert) of
        true  -> ingest_certified_block(Peer, Block, Cert, S);
        false -> S
    end;
dispatch(Peer, {readiness, Height, Ready}, S)
  when is_integer(Height), Height >= 0, is_boolean(Ready) ->
    record_peer_readiness(Peer, Height, Ready, S);
dispatch(_Peer, _Other, S)                 -> S.

well_formed_block(#block{slot = Sl, parent = P, payload = Pl, timestamp = Ts}) ->
    is_slot(Sl) andalso is_slot(P) andalso is_slot(Ts)
        andalso well_formed_block_payload(Pl);
well_formed_block(_) -> false.

well_formed_block_payload(Pl) ->
    proper_transaction_list(Pl)
        andalso length(Pl) =< ?MAX_BATCH_TXS
        andalso byte_size(term_to_binary(Pl, [deterministic])) =< ?MAX_BLOCK_BYTES
        andalso lists:all(fun well_formed_transaction/1, Pl)
        andalso unique_tx_ids(Pl).
well_formed_share(#share{kind = K, slot = Sl, block_hash = BH, signer = Sg, sig = Sig}) ->
    is_slot(Sl) andalso valid_shape(K, BH) andalso valid_signer_signature(Sg, Sig);
well_formed_share(_) -> false.
well_formed_cert(#cert{kind = K, slot = Sl, block_hash = BH, sigs = Sigs}) ->
    is_slot(Sl) andalso valid_shape(K, BH) andalso proper_signatures(Sigs);
well_formed_cert(_) -> false.
is_slot(X) -> is_integer(X) andalso X >= 0 andalso X =< ?MAX_SLOT.

%% A support certificate authorizes block retrieval from any committee member: the sender is only a
%% transport source, while the quorum certificate and block hash authenticate the content. Responses are
%% point-to-point and demand-driven, avoiding an O(N^2 * block-size) recovery flood.
serve_certified_block(Peer, Slot, BH, S = #s{eng = Eng}) ->
    case lists:member(Peer, active_validators(S)) of
        false -> S;
        true ->
            case {block_for(BH, Eng), persisted_cert(support, Slot, BH, Eng)} of
                {#block{slot = Slot} = Block, #cert{} = Cert} ->
                    send_frame(Peer, encode(S#s.ns, {certified_block, Block, Cert}), S);
                _ ->
                    S
            end
    end.

%% Responses are accepted only for a currently outstanding exact request. This keeps an authenticated but
%% faulty validator from making the consensus process repeatedly validate unsolicited full blocks.
ingest_certified_block(Peer, Block = #block{slot = Slot}, Cert,
                       S = #s{block_requests = Requests}) ->
    BH = block_hash(Block),
    case maps:is_key({Slot, BH}, Requests)
             andalso lists:member(Peer, active_validators(S))
             andalso certified_block_context(Block, Cert, S) of
        false ->
            S;
        true ->
            %% Ingest the certificate first. The engine sanitizes every signature against the current
            %% committee; only a certificate that survives that boundary may authorize a non-leader block.
            S1 = engine_step([{cert, Cert}], S),
            case persisted_cert(support, Slot, BH, S1#s.eng) of
                #cert{} ->
                    Requests1 = maps:remove({Slot, BH}, S1#s.block_requests),
                    engine_step([{block, BH, Block}], S1#s{block_requests = Requests1});
                none ->
                    S1
            end
    end.

certified_block_context(
  #block{slot = Slot, parent = Parent} = Block,
  #cert{kind = support, slot = Slot, block_hash = BH},
  S = #s{slot = Committed}) ->
    ContextValid = live_pipeline_slot(Slot, Committed)
                   andalso Parent =:= Slot - 1
                   andalso block_hash(Block) =:= BH
                   andalso compatible_local_final_vote(Slot, BH, S),
    case ContextValid andalso recoverable_parent_timestamp(Parent, S) of
        false ->
            false;
        unavailable ->
            false;
        ParentTs ->
            block_admissible(Block, ParentTs, S)
    end;
certified_block_context(_Block, _Cert, _S) ->
    false.

recoverable_parent_timestamp(Parent, #s{slot = Parent, last_ts = LastTs}) -> LastTs;
recoverable_parent_timestamp(Parent, #s{eng = #eng{tree = Tree}}) ->
    case maps:get(Parent, Tree, undefined) of
        #block{timestamp = Ts} -> Ts;
        undefined -> unavailable
    end.

%% A support latch names only the proposal this validator supported; it does not prevent committing the
%% unique block another support quorum notarized. Only an existing commit for another hash conflicts.
compatible_local_final_vote(Slot, BH, S) ->
    case round_state(Slot, S) of
        #round{final = {commit, Other}} when Other =/= BH -> false;
        _ -> true
    end.

%% A leader's proposal: accept it only from the slot's actual leader and at the next APPROVED slot,
%% extending that approved parent. At most one uncommitted approved parent may be extended,
%% and the payload is a bounded, structurally valid transaction batch. This prevents future-slot flooding
%% and ensures commit_block only receives blocks whose full apply shape was checked before voting.
%% Reject a non-leader before transaction verification. Keep the explicit positive
%% slot guard before leader/2 so a crafted slot 0 cannot reach lists:nth/2.
on_propose(Peer, #block{slot = Sl} = Block, S) ->
    BH = block_hash(Block),
    %% A redrive of the exact block we already supported was fully validated on
    %% first receipt. Check the hash latch first to avoid repeating every
    %% transaction's Ed25519 verification on each delta timeout.
    FromLeader = is_integer(Sl) andalso Sl >= 1
                 andalso leader(Sl, active_validators(S)) =:= Peer,
    Valid = FromLeader
            andalso (known_proposal(Sl, BH, S) orelse valid_proposal(Block, S)),
    case Valid of
        %% Recovery may ingest the block and certificates as evidence, but only a ready voter starts local
        %% validation, timers, or signatures. The leader's redrive presents the proposal again after recovery.
        true  -> S1 = engine_step([{block, BH, Block}], S),
                 case may_vote(S1) of
                     true  -> support_or_validate(Block, BH, watch_proposal(Sl, S1));
                     false -> S1
                 end;
        false -> S
    end.

%% A plain content proposal is supported immediately. A COMMITTEE-changing proposal defers its support
%% share until this node's own KB judges it (`quod_prolog:request_membership_verdict/5`, pinned to the
%% proposal's parent height): we record `validating` and support only on a `valid` verdict — so a Byzantine
%% leader's unauthorized membership change never collects an honest support quorum. Local and remote
%% proposals use this same path; the asynchronous Prolog/consensus boundary needs no leader exception.
%% The verdict is correlated to the exact block by its HASH (the Tag is `{Sl, BlockHash}`), so a Byzantine
%% leader that EQUIVOCATES (two different blocks for one slot) can never have block A's verdict endorse
%% block B. Re-proposing the SAME block is idempotent (we're already validating it — no duplicate request).
support_or_validate(#block{slot = Sl}, _BH, S) when Sl =< S#s.slot -> S;   %% cert raced ahead: slot already final
%% Slot already judged INVALID: we never endorse it at any phase, so a REDRIVEN copy must not re-request
%% a verdict (it would re-prove per Δ and double-count the reject). Checked before hashing — no work.
support_or_validate(#block{slot = Sl}, _BH, S) ->
    case (round_state(Sl, S))#round.invalid of
        true -> S;
        false -> support_or_validate_ready(Sl, _BH, S)
    end.

support_or_validate_ready(Sl, BH, S) ->
    #block{payload = Payload} = Block = block_for(BH, S#s.eng),
    case payload_touches_committee(Payload) of
        false -> support_block(Block, BH, S);
        true  ->
            Round = round_state(Sl, S),
            case Round#round.supporting =:= BH of
                %% judged VALID + support-signed already: a redriven copy takes the plain support path,
                %% whose duplicate branch re-echoes our share — never a KB re-proof per Δ
                true  -> support_block(Block, BH, S);
                false ->
                    case Round#round.validating of
                        BH -> S;
                        _ -> [Change] = Payload,   %% acceptable_payload makes membership blocks singleton
                             _ = quod_prolog:request_membership_verdict(S#s.ns, Change, Sl,
                                                                        self(), {Sl, BH}),
                             put_round(Sl, Round#round{validating = BH}, S)
                    end
            end
    end.

%% The KB verdict for a membership proposal we deferred, correlated to the exact block by `{Sl, BH}`: `valid`
%% ⇒ emit the deferred support share; `invalid` ⇒ latch `#round.invalid` (so we never endorse it at any phase —
%% see `apply_event({notarized,...})`) and count it; `abstain` ⇒ neither (a peer-formed support cert may still
%% notarize; if enough nodes abstain the slot Δ-skips). A verdict is acted on ONLY if `{Sl, BH}` still matches
%% what we are validating AND `Sl` is still head+1 — so a stale verdict (slot finalized, or a DIFFERENT block
%% now validating under leader equivocation) is dropped, never applied to the wrong block.
on_membership_verdict(Sl, BH, Verdict, S = #s{approved = Approved}) when Sl =:= Approved + 1 ->
    Round = round_state(Sl, S),
    case Round#round.validating of
        BH ->
            S1 = put_round(Sl, Round#round{validating = none}, S),
            case Verdict of
                valid        -> case block_for(BH, S1#s.eng) of
                                    #block{} = Block -> support_block(Block, BH, S1);
                                    _                -> S1
                                end;
                {invalid, _} ->
                    S2 = put_round(Sl, (round_state(Sl, S1))#round{invalid = true},
                                   S1#s{membership_rejects = S1#s.membership_rejects + 1}),
                    choose_final_vote(Sl, rejected, S2);
                abstain      -> S1
            end;
        _ -> S
    end;
on_membership_verdict(_Sl, _BH, _Verdict, S) -> S.

%% The oldest non-final slot is an explicit local protocol state. The former `active_slot` latch followed
%% `approved+1`; consequently a support certificate cleared its timer even though the slot was not durable.
%% Under an over-f outage, returning validators could then miss the one-shot notarization event and no node
%% remained responsible for moving the finality frontier. These transitions instead follow `committed+1`
%% until commit/skip and expose the actual phase for diagnostics.
%% A selected complaint can complete a skip synchronously inside `choose_final_vote/3`; callers that then
%% try to retain demand for that same slot must not resurrect already-finalized state.
watch_requested(V, S = #s{slot = Committed}) when V =< Committed ->
    clear_requested_le(Committed, S);
watch_requested(V, S = #s{requested_slot = Requested}) ->
    Earliest = case Requested of none -> V; _ -> min(V, Requested) end,
    watch_head(V, awaiting_proposal, S#s{requested_slot = Earliest}).
watch_proposal(V, S)  -> watch_head(V, awaiting_notarization, clear_requested_le(V, S)).
watch_notarized(V, S) -> watch_head(V, awaiting_commit, S).

watch_head(V, Phase, S = #s{slot = Committed}) when V =:= Committed + 1 ->
    Current = case S#s.head_progress of
                  #head_progress{slot = V, phase = P} -> later_phase(P, Phase);
                  _                                   -> Phase
              end,
    Ready = quorum_ready(S),
    S#s{head_progress = next_head_progress(
                           V, Current, Ready, S#s.head_progress)};
watch_head(_V, _Phase, S) ->
    S.

later_phase(awaiting_commit, _Phase) -> awaiting_commit;
later_phase(_Phase, awaiting_commit) -> awaiting_commit;
later_phase(awaiting_notarization, _Phase) -> awaiting_notarization;
later_phase(_Phase, awaiting_notarization) -> awaiting_notarization;
later_phase(awaiting_proposal, awaiting_proposal) -> awaiting_proposal.

%% Re-derive the oldest-head state after every transition. `awaiting_proposal` is demand evidence and has
%% no engine object yet, so it is retained for the same head. Every later phase derives from concrete
%% consensus state and therefore self-heals after event reordering.
reconcile_head_progress(S = #s{slot = Committed, approved = Approved}) ->
    V = Committed + 1,
    Phase = case Approved >= V of
                true  -> awaiting_commit;
                false -> case may_vote(S) andalso head_has_evidence(V, S) of
                             true  -> awaiting_notarization;
                             false -> retained_request(V, S)
                         end
            end,
    case Phase of
        idle ->
            S#s{head_progress = idle};
        _ ->
            Ready = quorum_ready(S),
            S#s{head_progress = next_head_progress(
                                   V, Phase, Ready, S#s.head_progress)}
    end.

next_head_progress(V, Phase, Ready,
                   #head_progress{slot = V, phase = Phase,
                                  quorum_ready = WasReady,
                                  quorum_rearms = Rearms,
                                  support_grace_used = GraceUsed}) ->
    {Rearms1, GraceUsed1} =
        case {WasReady, Ready, Rearms < ?MAX_QUORUM_REARMS} of
            %% A bounded quorum restoration starts a fresh Delta and a fresh support-redrive grace.
            %% Once the rearm cap is exhausted, neither deadline nor grace can be renewed by flapping.
            {false, true, true} -> {Rearms + 1, false};
            _                   -> {Rearms, GraceUsed}
        end,
    #head_progress{slot = V, phase = Phase, quorum_ready = Ready,
                   quorum_rearms = Rearms1, support_grace_used = GraceUsed1};
next_head_progress(V, Phase, Ready, _Previous) ->
    #head_progress{slot = V, phase = Phase, quorum_ready = Ready}.

retained_request(V, #s{requested_slot = V}) -> awaiting_proposal;
retained_request(V, #s{head_progress = #head_progress{slot = V,
                                                       phase = awaiting_proposal}}) ->
    awaiting_proposal;
retained_request(_V, _S) -> idle.

clear_requested_le(V, S = #s{requested_slot = Requested})
  when is_integer(Requested), Requested =< V ->
    S#s{requested_slot = none};
clear_requested_le(_V, S) ->
    S.

head_has_evidence(V, #s{eng = #eng{blocks = Blocks}, rounds = Rounds,
                        local_proposals = Local, collecting = Collecting,
                        commit_buf = CommitBuf}) ->
    maps:is_key(V, Rounds)
        orelse maps:is_key(V, Local)
        orelse maps:is_key(V, CommitBuf)
        orelse lists:any(fun(#block{slot = Sl}) -> Sl =:= V end, maps:values(Blocks))
        orelse case Collecting of #batch{slot = V} -> true; _ -> false end;
head_has_evidence(_V, _S) ->
    false.

quorum_ready(#s{self = Self, slot = Height,
                inbound_conns = Inbound, peer_readiness = Readiness} = S) ->
    Validators = active_validators(S),
    case may_vote(S) andalso length(Validators) > 0 of
        false -> false;
        true ->
            ReadyPeers = [P || P <- Validators, P =/= Self,
                               peer_ready_at(P, Height, Inbound, Readiness)],
            1 + length(ReadyPeers) >= quorum(length(Validators))
    end.

%% A readiness claim is useful only on the exact authenticated inbound consensus link that carried it.
%% Replacing or losing that link removes the claim, so a restarted process cannot inherit its predecessor's
%% readiness merely because it uses the same long-lived node key.
peer_ready_at(Peer, Height, Inbound, Readiness) ->
    case {maps:get(Peer, Inbound, undefined), maps:get(Peer, Readiness, undefined)} of
        {{Pid, _Ref}, {Pid, PeerHeight, true, SeenAt}} when PeerHeight >= Height ->
            is_process_alive(Pid)
                andalso quod_time:mono_ms() - SeenAt =< ?READINESS_FRESH_MS;
        _ ->
            false
    end.

record_peer_readiness(Peer, Height, Ready,
                      S = #s{inbound_conns = Inbound, peer_readiness = Readiness}) ->
    case {lists:member(Peer, active_validators(S)), maps:get(Peer, Inbound, undefined)} of
        {true, {Pid, _Ref}} when is_pid(Pid) ->
            SeenAt = quod_time:mono_ms(),
            S#s{peer_readiness = Readiness#{Peer => {Pid, Height, Ready, SeenAt}}};
        _ ->
            S
    end.

drop_peer_readiness(Peer, S = #s{peer_readiness = Readiness}) ->
    S#s{peer_readiness = maps:remove(Peer, Readiness)}.

live_link(Peer, Links) ->
    case maps:get(Peer, Links, undefined) of
        {Pid, _Ref} when is_pid(Pid) -> is_process_alive(Pid);
        _                            -> false
    end.

%% All normal state transitions pass through here. A phase change resets the full Delta. Quorum restoration
%% may reset it only within the bounded per-phase budget; losing quorum leaves the existing timer running,
%% whose expiry only probes/re-drives.
keep_progress(S0, S1, Actions) ->
    keep_progress(S0, S1, Actions, normal).

keep_progress(S0, S1, Actions, TimerMode) ->
    SReady = settle_readiness(S0, maybe_mark_ready(S1)),
    SRecovered = reconcile_block_requests(SReady),
    %% Drain BEFORE head reconciliation and the timer diff: a drain-created proposal
    %% moves head_progress, and the watchdog must be armed against the post-drain head.
    {SDrained, DrainActions} = drain_ingress(SRecovered),
    SAdvertised = refresh_readiness(SDrained),
    S2 = reconcile_head_progress(SAdvertised),
    log_progress_transition(S0#s.head_progress, S2#s.head_progress, S2),
    TimerActions = case TimerMode of
                       rearm -> rearm_progress_timer(S2);
                       normal -> progress_timer_actions(S0, S2)
                   end,
    {keep_state, S2, Actions ++ DrainActions ++ TimerActions}.

%% Readiness is consensus state, so advertise it on the authenticated consensus channel rather than infer
%% it from socket existence or a separate dissemination process. Capability/height changes go immediately;
%% an unchanged state refreshes once per second so a failed dial is retried and a half-open link cannot
%% leave an immortal claim. Readiness frames are intentionally not queued: `handle_link_up/3` sends the
%% current value, so retaining older values would only bloat the protocol outbox during a long outage.
refresh_readiness(S1) ->
    {Height, Ready} = local_readiness(S1),
    {LastHeight, LastReady, LastAt} = S1#s.readiness_advertised,
    Now = quod_time:mono_ms(),
    case {Height, Ready} =/= {LastHeight, LastReady}
             orelse Now - LastAt >= ?READINESS_MS of
        true  -> advertise_readiness(Height, Ready, Now, S1);
        false -> S1
    end.

local_readiness(S) -> {S#s.slot, may_vote(S)}.

advertise_readiness(Height, Ready, Now, S = #s{self = Self}) ->
    Frame = encode(S#s.ns, {readiness, Height, Ready}),
    S1 = lists:foldl(fun(Peer, Acc) -> send_readiness(Peer, Frame, Acc) end,
                     S, active_validators(S) -- [Self]),
    S1#s{readiness_advertised = {Height, Ready, Now}}.

%% One capability edge owns recovery reconciliation. This catches explicit sync completion, periodic
%% readiness, and live commit/skip self-corroboration without each caller remembering a special hook.
settle_readiness(S0, S1) ->
    case {may_vote(S0), may_vote(S1)} of
        {false, true} -> resume_ready_rounds(S1);
        _             -> S1
    end.

progress_timer_actions(#s{head_progress = P}, #s{head_progress = P}) -> [];
progress_timer_actions(_S0, #s{head_progress = idle}) ->
    [{{timeout, progress}, cancel}];
%% Losing visible quorum suppresses complaint signing but does not reset the existing timeout. A later
%% false->true transition may replace it with one fresh full Delta, up to the per-phase cap below.
progress_timer_actions(
  #s{head_progress = #head_progress{slot = V, phase = Phase, quorum_ready = true}},
  #s{head_progress = #head_progress{slot = V, phase = Phase, quorum_ready = false}}) ->
    [];
%% A restoration grants a fresh Delta only a bounded number of times for one unchanged slot/phase.
%% Once exhausted, the existing named timer keeps its original deadline, so a flapping link cannot
%% postpone complaint progress forever. Advancing slot or phase creates a fresh budget.
progress_timer_actions(
  #s{head_progress = #head_progress{slot = V, phase = Phase,
                                   quorum_ready = false,
                                   quorum_rearms = Rearms}},
  #s{head_progress = #head_progress{slot = V, phase = Phase,
                                   quorum_ready = true}})
  when Rearms >= ?MAX_QUORUM_REARMS ->
    [];
progress_timer_actions(_S0, #s{head_progress = #head_progress{slot = V}}) ->
    [progress_timeout(V)].

rearm_progress_timer(#s{head_progress = idle}) ->
    [{{timeout, progress}, cancel}];
rearm_progress_timer(#s{head_progress = #head_progress{slot = V}}) ->
    [progress_timeout(V)].

progress_timeout(V) ->
    {{timeout, progress}, delta_ms(), {progress_timeout, V}}.

log_progress_transition(P, P, _S) -> ok;
log_progress_transition(_Old, idle, #s{ns = Ns, slot = Slot}) ->
    logger:debug("quod[~s]: head progress idle at committed slot ~b", [Ns, Slot]);
log_progress_transition(_Old,
                        #head_progress{slot = V, phase = Phase,
                                       quorum_ready = Ready},
                        #s{ns = Ns}) ->
    logger:debug("quod[~s]: head ~b phase=~p quorum_ready=~p",
                 [Ns, V, Phase, Ready]).

delta_ms() ->
    case application:get_env(quod, simplex_delta_ms, ?DELTA_MS) of
        N when is_integer(N), N > 0 -> N;
        _                           -> ?DELTA_MS   %% a mistyped override must not crash the timer action
    end.

%% Δ fired for the oldest non-final slot. Finality always re-drives; before notarization, a complaint is
%% emitted only while a certificate quorum has authenticated inbound streams carrying fresh readiness at
%% this node's durable height. During a known over-f outage we retain and re-send the proposal but
%% deliberately do not accumulate complaint votes. An already-supporting follower re-echoes once after a
%% bounded quorum restoration
%% before it may complain, giving the leader's redrive one final Delta to reach recovered validators. The
%% bounded rearm budget keeps repeated link flaps from postponing complaint progress forever.
on_progress_timeout(V,
        S0 = #s{head_progress = #head_progress{slot = V, phase = Phase}}) ->
    S1 = S0#s{progress_timeouts = S0#s.progress_timeouts + 1},
    case may_vote(S1) of
        false ->
            probe_committee(S1);
        true when Phase =:= awaiting_commit ->
            probe_committee(redrive_head(V, S1));
        true ->
            case quorum_ready(S1) of
                false ->
                    S2 = case leads_inflight(V, S1) of
                             true  -> redrive_head(V, S1);
                             false -> S1
                         end,
                    probe_committee(S2#s{quorum_pauses = S2#s.quorum_pauses + 1});
                true ->
                    on_pre_notarization_timeout(V, S1)
            end
    end;
on_progress_timeout(_V, S) ->
    S.

on_pre_notarization_timeout(V, S) ->
    case leads_inflight(V, S) of
        false ->
            case held_unsupported_proposal(V, S) of
                {resume, Block, BH} -> support_or_validate(Block, BH, S);
                validating         -> S;
                none ->
                    case retry_supported_proposal(V, S) of
                        {retried, S1} -> S1;
                        none          -> choose_final_vote(V, timeout, S)
                    end
            end;
        true  ->
            %% Camp decision first (amplified evidence may pick the skip), then ALWAYS
            %% redrive: a leader latched into either camp still owns the only
            %% authenticated resend of its in-flight proposal, and the lossy
            %% fire-and-forget link makes the Δ re-fire THE retransmit. Suppressing it
            %% for a latched leader wedged a burst live: the lost proposal was never
            %% re-sent, so no follower could ever support it.
            redrive_head(V, choose_final_vote(V, notarized, S))
    end.

%% A recovering voter can ingest a valid leader proposal while signing is disabled. The engine retains the
%% block, but no support latch exists and the original proposal event will not repeat. On the first ready
%% timeout, run that held proposal through the normal support/membership-verdict path before considering a
%% complaint. Blocks enter `eng.blocks` only through authenticated leader + full proposal validation.
held_unsupported_proposal(V, S = #s{eng = #eng{blocks = Blocks}}) ->
    Round = round_state(V, S),
    case {Round#round.supporting, Round#round.validating, Round#round.invalid} of
        {none, BH, false} when is_binary(BH) ->
            validating;
        {none, none, false} ->
            Candidates = lists:sort(
                           [{BH, Block}
                            || {BH, #block{slot = Sl} = Block} <- maps:to_list(Blocks),
                               Sl =:= V, valid_proposal(Block, S)]),
            case Candidates of
                [{BH, Block} | _] -> {resume, Block, BH};
                []                -> none
            end;
        _ ->
            none
    end.

%% A quorum can return after a long outage while the surviving followers already hold support latches.
%% Complaining immediately races the leader's proposal redrive and can skip a valid retained slot before a
%% recovered validator sees it. Re-echo our support once and grant one final Delta; the next timeout may
%% complain normally. The grace resets only on a phase change or one of the bounded quorum restorations.
retry_supported_proposal(
  V, S = #s{head_progress = P = #head_progress{slot = V,
                                               phase = awaiting_notarization,
                                               support_grace_used = false}}) ->
    case round_state(V, S) of
        #round{supporting = BH, final = Final, invalid = false}
          when is_binary(BH), Final =/= complaint ->
            case block_for(BH, S#s.eng) of
                #block{} = Block ->
                    S1 = S#s{head_progress = P#head_progress{support_grace_used = true}},
                    {retried, support_block(Block, BH, S1)};
                _ ->
                    none
            end;
        _ ->
            none
    end;
retry_supported_proposal(_V, _S) ->
    none.

%% Complaint ingestion re-runs the same final-vote decision as notarization and recovery. Both live
%% pipeline slots are eligible: resolving a certified child need not wait for the durable head to finish.
%% Only a newly selected complaint at the head creates watchdog demand; a child finalizer is buffered by
%% the normal contiguous-finalization path.
maybe_join_complaint(#share{kind = complaint, slot = V}, S0 = #s{slot = Committed}) ->
    Before = (round_state(V, S0))#round.final,
    S1 = choose_final_vote(V, complaint_evidence, S0),
    case {V =:= Committed + 1, Before, (round_state(V, S1))#round.final} of
        {true, none, complaint} -> watch_requested(V, S1);
        _                       -> S1
    end;
maybe_join_complaint(_Share, S) -> S.

%% Are we the leader of V with our own proposal still in flight?
leads_inflight(V, S = #s{self = Self, local_proposals = Local}) ->
    maps:is_key(V, Local) andalso leader(V, active_validators(S)) =:= Self.

%% `f+1` distinct PEER complaint shares for V in the pool — proof at least one HONEST member wants the
%% skip (at most `f` Byzantine members exist, and complaint shares are signature-verified + set-checked
%% at ingest, so an outsider can't manufacture evidence).
complaint_evidence(V, S = #s{self = Self, eng = #eng{shares = Shares}}) ->
    Bucket = maps:get({complaint, V, none}, Shares, #{}),
    complaint_amplified(Self, active_validators(S), Bucket).

%% Pure threshold: at least `f+1` DISTINCT CURRENT peer signers (self excluded — our own share isn't
%% independent evidence). Projecting onto `Validators` is load-bearing across a committed membership change:
%% an authenticated share cached from a removed validator is no longer evidence in the new committee. `f` is
%% derived from the quorum rule (`quorum = N - f`), never restated, and the bucket map gives distinctness.
complaint_amplified(Self, Validators, Bucket) ->
    N = length(Validators),
    CurrentPeers = [Signer || Signer <- maps:keys(Bucket),
                              Signer =/= Self,
                              lists:member(Signer, Validators)],
    length(CurrentPeers) >= (N - quorum(N)) + 1.

%% One evidence-redrive path owns the in-flight window. The 300 ms tick re-emits only this
%% validator's tiny, durably latched shares. The durable-head watchdog additionally re-emits a
%% locally owned proposal and pooled certificates. Complete blocks held by non-leaders are never
%% flooded here; laggards recover them through the request/response anti-entropy path below.
redrive_head(Slot, S) -> emit_slot_evidence(Slot, full, S).

redrive_inflight(S) ->
    case may_vote(S) of
        false -> S;
        true  -> lists:foldl(
                   fun(Slot, Acc) -> emit_slot_evidence(Slot, votes, Acc) end,
                   S, lists:sort([Slot || Slot <- maps:keys(S#s.rounds), Slot > S#s.slot]))
    end.

emit_slot_evidence(_Slot, _Scope, S) when S#s.sync =/= ready -> S;
emit_slot_evidence(Slot, Scope, S0) ->
    {Proposal, S1} = case Scope of
                         full  -> local_proposal_evidence(Slot, S0);
                         votes -> {[], S0}
                     end,
    Own = own_vote_evidence(Slot, S1),
    Certs = case Scope of
                full  -> certificate_evidence(Slot, S1);
                votes -> []
            end,
    lists:foldl(fun broadcast/2, S1, Proposal ++ Own ++ Certs).

local_proposal_evidence(Slot, S0 = #s{local_proposals = Local}) ->
    case maps:get(Slot, Local, undefined) of
        #local_proposal{hash = BH} ->
            case block_for(BH, S0#s.eng) of
                #block{} = Block ->
                    %% Membership proposals re-enter their common verdict path; an outstanding verdict is
                    %% idempotent, and an abstention may be retried. Do this before rebuilding vote frames.
                    S1 = support_or_validate(Block, BH, S0),
                    case Slot > S1#s.slot of
                        true  -> {[{propose, Block}], S1#s{redrives = S1#s.redrives + 1}};
                        false -> {[], S1}
                    end;
                undefined ->
                    {[], S0}
            end;
        undefined ->
            {[], S0}
    end.

own_vote_evidence(Slot, S) ->
    case maps:get(Slot, S#s.rounds, undefined) of
        #round{supporting = SupportBH, final = Final} ->
            Support = case SupportBH of
                          none -> [];
                          _ -> {ok, SupportShare} = own_share(support, Slot, SupportBH, S),
                               [{share, SupportShare}]
                      end,
            FinalEvidence = case Final of
                                none -> [];
                                complaint ->
                                    {ok, ComplaintShare} = own_share(complaint, Slot, none, S),
                                    [{share, ComplaintShare}];
                                {commit, CommitBH} ->
                                    {ok, CommitShare} = own_share(commit, Slot, CommitBH, S),
                                    [{share, CommitShare}]
                            end,
            Support ++ FinalEvidence;
        undefined ->
            []
    end.

certificate_evidence(Slot, #s{eng = #eng{certs = Certs}}) ->
    [{cert, Cert} || {{_Kind, CertSlot, _BH}, Cert} <- maps:to_list(Certs),
                     CertSlot =:= Slot].

%% Recover one missing certified block at a time, in slot order. A request rotates through certificate
%% signers and then the rest of the committee, one peer per retry. The support certificate is already in
%% the local engine, so the response can be checked without trusting the selected holder.
reconcile_block_requests(S = #s{eng = undefined}) -> S;
reconcile_block_requests(S0 = #s{slot = Committed, eng = Eng, block_requests = Requests0}) ->
    Missing = lists:sort(
                [{Slot, BH, Cert}
                 || {{support, Slot, BH}, #cert{} = Cert} <- maps:to_list(Eng#eng.certs),
                    live_pipeline_slot(Slot, Committed),
                    block_for(BH, Eng) =:= undefined]),
    LiveKeys = [{Slot, BH} || {Slot, BH, _Cert} <- Missing],
    Requests1 = maps:filter(fun(Key, _Value) -> lists:member(Key, LiveKeys) end, Requests0),
    S1 = S0#s{block_requests = Requests1},
    case first_requestable_block(Missing, S1) of
        none -> S1;
        {Slot, BH, Cert} -> maybe_request_block(Slot, BH, Cert, S1)
    end.

first_requestable_block([], _S) -> none;
first_requestable_block([{Slot, _BH, _Cert} = Missing | Rest],
                        S = #s{slot = Committed, eng = #eng{tree = Tree}}) ->
    case Slot =:= Committed + 1 orelse maps:is_key(Slot - 1, Tree) of
        true  -> Missing;
        false -> first_requestable_block(Rest, S)
    end.

maybe_request_block(Slot, BH, #cert{sigs = Sigs},
                    S = #s{self = Self, block_requests = Requests}) ->
    Now = quod_time:mono_ms(),
    {Attempt, NextAt} = maps:get({Slot, BH}, Requests, {0, Now}),
    case Now < NextAt of
        true ->
            S;
        false ->
            Signers = [Signer || {Signer, _Sig} <- Sigs],
            Candidates = ordered_unique(Signers ++ active_validators(S), Self),
            case Candidates of
                [] -> S;
                _ ->
                    Peer = lists:nth((Attempt rem length(Candidates)) + 1, Candidates),
                    Frame = encode(S#s.ns, {block_request, Slot, BH}),
                    S1 = send_frame(Peer, Frame, S),
                    S1#s{block_requests = (S1#s.block_requests)#{{Slot, BH} =>
                              {Attempt + 1, Now + ?BLOCK_REQUEST_RETRY_MS}}}
            end
    end.

ordered_unique(Candidates, Excluded) ->
    {_, Rev} = lists:foldl(
                 fun(Candidate, {Seen, Acc}) ->
                         case Candidate =:= Excluded orelse maps:is_key(Candidate, Seen) of
                             true  -> {Seen, Acc};
                             false -> {Seen#{Candidate => true}, [Candidate | Acc]}
                         end
                 end, {#{}, []}, Candidates),
    lists:reverse(Rev).

%% A recovering member may have accepted and notarized a block while `may_vote=false`. Engine events are
%% edge-triggered, so becoming ready does not naturally emit `{notarized,...}` again. Reconcile the complete
%% tree into the approval/commit latches and emit any commit share that was intentionally withheld during
%% recovery. Do NOT invent a support vote here: a committee-changing proposal requires this node's
%% asynchronous KB verdict before support, and recovery deliberately skipped that validation. The existing
%% notarization certificate is sufficient authority to cast the final vote. The operation is idempotent
%% (`#round.final` is the latch) and runs on ready transitions/ticks.
resume_ready_rounds(S) ->
    case may_vote(S) of
        false -> S;
        true ->
            %% Snapshot only slot numbers. A vote in an earlier iteration can finalize and prune later
            %% entries via commit_buf; resume_ready_slot/2 re-reads the current tree on every step.
            Slots = lists:sort([Sl || Sl <- maps:keys((S#s.eng)#eng.tree),
                                     Sl > S#s.slot]),
            lists:foldl(
              fun resume_ready_slot/2,
              S, Slots)
    end.

resume_ready_slot(Sl, S = #s{slot = Committed}) when Sl =< Committed ->
    S;
resume_ready_slot(Sl, S = #s{eng = #eng{tree = Tree}}) ->
    case maps:get(Sl, Tree, undefined) of
        #block{} = Block ->
            choose_final_vote(Sl, notarized, approve_block(Block, S));
        undefined ->
            S
    end.

%% A timeout observed with fewer than a certificate quorum ready must not sign an irreversible complaint.
%% Open missing committee links without queuing duplicate protocol frames; a peer counts only after it
%% reports readiness on its current authenticated inbound link.
probe_committee(S = #s{self = Self, conns = Conns, dialing = Dialing, chan = Chan}) ->
    Missing = [P || P <- active_validators(S), P =/= Self,
                    not live_link(P, Conns), not maps:is_key(P, Dialing)],
    lists:foldl(
      fun(P, Acc) ->
              _ = quod_quic:open_link(P, Chan),
              Acc#s{dialing = (Acc#s.dialing)#{P => dial_deadline()}}
      end, S, Missing).

%% One owner chooses every first final vote in the live pipeline. Amplified complaint evidence has priority.
%% A notarization edge (including ready recovery) may otherwise select commit; complaint-share ingestion may
%% only join amplified evidence; a watchdog may fall back to skip; and an invalid-membership verdict may only
%% skip. These trigger policies feed one decision table and one durable emission path.
-spec choose_final_vote(slot(), final_vote_trigger(), #s{}) -> #s{}.
choose_final_vote(V, Trigger, S = #s{slot = Committed}) ->
    case live_pipeline_slot(V, Committed) of
        false ->
            S;
        true ->
            Round = round_state(V, S),
            case {may_vote(S), Round#round.final} of
                {false, _}    -> S;
                {true, none}  -> choose_unlatched_final_vote(
                                   V, final_vote_policy(Trigger), Round, S);
                {true, _Vote} -> S
            end
    end.

final_vote_policy(notarized)          -> {commit, wait};
final_vote_policy(complaint_evidence) -> {hold, wait};
final_vote_policy(timeout)            -> {commit, complaint};
final_vote_policy(rejected)           -> {hold, complaint}.

choose_unlatched_final_vote(V, {CommitPolicy, Fallback}, Round, S) ->
    CanComplain = may_complain(V, committed_slots(S)),
    case CanComplain andalso complaint_evidence(V, S) of
        true ->
            emit_final_vote(complaint, V, none, S);
        false ->
            case {Round#round.invalid, notarized_hash(V, S),
                  may_commit(V, complained_slots(S))} of
                {false, {ok, BH}, true} when CommitPolicy =:= commit ->
                    emit_final_vote(commit, V, BH, S);
                _ when Fallback =:= complaint, CanComplain =:= true ->
                    emit_final_vote(complaint, V, none, S);
                _ ->
                    S
            end
    end.

notarized_hash(V, #s{eng = #eng{tree_hashes = Hashes}}) ->
    case maps:get(V, Hashes, undefined) of
        BH when is_binary(BH) -> {ok, BH};
        undefined             -> none
    end;
notarized_hash(_V, _S) ->
    none.

emit_final_vote(Kind, V, BH, S) ->
    case record_share(Kind, V, BH, S) of
        blocked -> S;
        {ok, Share, S1} ->
            %% The durable latch is installed before the share enters either the engine or transport. If this
            %% share completes a certificate synchronously, every nested event sees the same final decision.
            engine_step([{share, Share}], broadcast({share, Share}, S1))
    end.

%% The sole constructor for NEW runtime consensus evidence. The decision is durable before the
%% signature can become network-visible; an I/O failure fail-stops this validator before it can
%% equivocate. Redrive reconstructs an identical Ed25519 share only from the resulting latch.
record_share(Kind, Slot, BlockHash, S = #s{vote_journal = Journal}) ->
    case may_vote(S) of
        false ->
            blocked;
        true ->
            TraceCtx = trace_context_for_slot(Slot, S),
            {ok, Journal1} = quod_trace:with_optional_span(
                               TraceCtx, <<"quod.vote_journal.sync">>, internal,
                               #{'quod.namespace' => S#s.ns,
                                 'quod.consensus.slot' => Slot,
                                 'quod.vote.kind' => atom_to_binary(Kind, utf8)},
                               fun() ->
                                   record_vote(S#s.ns, Journal, Kind, Slot, BlockHash)
                               end),
            Round = round_state(Slot, S),
            Round1 = case Kind of
                         support   -> Round#round{supporting = BlockHash};
                         commit    -> Round#round{final = {commit, BlockHash}};
                         complaint -> Round#round{final = complaint}
                     end,
            S1 = put_round(Slot, Round1, S#s{vote_journal = Journal1}),
            {ok, make_share(Kind, Slot, BlockHash, S#s.id), S1}
    end.

record_vote(_Ns, memory, _Kind, _Slot, _BlockHash) -> {ok, memory};
record_vote(_Ns, undefined, Kind, Slot, BlockHash) ->
    error({vote_journal_unavailable, Kind, Slot, BlockHash});
record_vote(Ns, Journal, Kind, Slot, BlockHash) ->
    Started = erlang:monotonic_time(),
    Result = quod_vote_journal:record(Journal, Kind, Slot, BlockHash),
    quod_metrics:observe_vote_journal_sync(Ns, erlang:monotonic_time() - Started),
    Result.

%% Reconstruct already-durable evidence for retransmission. The latch check is part of this function,
%% so no caller can turn it into an unjournaled share constructor by supplying arbitrary arguments.
%% Tests and certificate verification use `make_share/4` directly; normal first emission must pass
%% through `record_share/4` above.
own_share(Kind, Slot, BlockHash, #s{id = Id} = S) ->
    case may_vote(S) andalso vote_is_latched(Kind, BlockHash, round_state(Slot, S)) of
        true  -> {ok, make_share(Kind, Slot, BlockHash, Id)};
        false -> blocked
    end.

vote_is_latched(support, BH, #round{supporting = BH}) -> true;
vote_is_latched(commit, BH, #round{final = {commit, BH}}) -> true;
vote_is_latched(complaint, none, #round{final = complaint}) -> true;
vote_is_latched(_Kind, _BH, #round{}) -> false.

valid_proposal(#block{slot = Sl, parent = P} = Block,
               #s{slot = Committed, approved = Approved} = S) ->
    Sl =:= Approved + 1
        andalso P =:= Approved
        andalso live_pipeline_slot(Sl, Committed)
        andalso block_admissible(Block, parent_timestamp(P, S), S).

%% Normal leader proposals and certificate-authorized block recovery have different position/hash gates,
%% but must accept exactly the same timestamp and transaction content. Keep that consensus-sensitive tail
%% in one predicate so a future admission rule cannot make live voting and recovery disagree.
block_admissible(#block{payload = Payload, timestamp = Ts}, ParentTs, S) ->
    not membership_barrier(S)
        andalso ts_acceptable(Ts, ParentTs, quod_time:now_ms())
        andalso acceptable_payload(Payload, S).

%% A leader redrive for an already-supported in-flight block is accepted even after
%% the approved frontier moved past it. The locally latched hash makes this exact and
%% cannot authorize a different block for the same slot.
known_proposal(Sl, BH, S) when Sl > S#s.slot ->
    (round_state(Sl, S))#round.supporting =:= BH;
known_proposal(_Sl, _BH, _S) -> false.

%% A proposed block's `timestamp` is acceptable iff it is a non-negative integer (`well_formed_block`
%% guarantees this for wire input, but we re-check so the predicate is total + directly testable),
%% MONOTONIC (≥ the parent block's time `Last`), and not implausibly far in the FUTURE relative to the
%% verifier's clock (`Now + ?MAX_FUTURE_MS`). Without the future bound, one Byzantine proposal could pin
%% `last_ts` decades ahead and freeze block-time forever (max/2 at propose never comes back down); cf.
%% Bitcoin's MAX_FUTURE_BLOCK_TIME (+2h). The skew is deliberately generous to avoid false-rejecting an
%% honest leader whose clock differs from ours by seconds. Accepted edge: a node whose wall clock is off
%% by MORE than the bound drops out of voting (it rejects, or is rejected, until it re-syncs) — a bounded,
%% chain-SAFE degradation of that one outlier, never a halt, since the honest majority still forms quorums.
-spec ts_acceptable(term(), non_neg_integer(), non_neg_integer()) -> boolean().
ts_acceptable(Ts, Last, Now) ->
    is_integer(Ts) andalso Ts >= Last andalso Ts =< Now + ?MAX_FUTURE_MS.

%% A change this node will PROPOSE or SUPPORT: a fully well-formed `#transaction{}`.
%% Membership changes are ordinary transactions whose diff asserts/retracts `peer_admitted`
%% (submitted via a `can_join`-gated external predicate) — a transaction that TOUCHES the committee
%% additionally passes the membership gate (`membership_change_ok/2`): shape + never-empty floor,
%% enforced at BOTH proposal seams (the leader gates its own input in `handle_append`; every validator
%% gates a peer's proposal in `valid_proposal` before support-signing) — so an unacceptable membership
%% change never reaches a support quorum and can never commit. This is the PURE shape+floor gate; a peer
%% that passes it then also defers its support to a KB verdict (`support_or_validate/2` →
%% `quod_prolog:request_membership_verdict/5`). Committed history is both cert-verified and checked against
%% the signed-transaction rules during catch-up and local rebuild.
%% The whole transaction is checked before voting: identifiers and timestamps have their canonical
%% shapes, the OCC read-set is a map of predicate hashes, and every diff element is a legal
%% assert/retract over an Erlog clause. This makes apply/restart a total operation over every block an
%% honest validator can endorse. The recursive diff check also rejects an improper list such as
%% `[Op | junk]`, which a shallow cons-cell match would otherwise admit from the untrusted wire.
acceptable_payload([#transaction{} | _] = Payload, S = #s{ns = Ns}) ->
    proper_transaction_list(Payload)
        andalso length(Payload) =< ?MAX_BATCH_TXS
        andalso byte_size(term_to_binary(Payload, [deterministic])) =< ?MAX_BLOCK_BYTES
        andalso lists:all(
                  fun(Change) -> ingress_change_acceptable(Change, S) end,
                  Payload)
        andalso verify_transaction_signatures(Ns, Payload, live)
        andalso unique_tx_ids(Payload)
        andalso sequence_payload_ok(Payload, S)
        andalso membership_payload_ok(Payload, S);
acceptable_payload(_Payload, _S) -> false.

%% Transactions entering this node's local batch have one of two trusted
%% provenance checks: this node just signed them, or a relay submission was
%% authenticated and verified before its opaque bytes were decoded. Keep the
%% structural/authorization checks here. The leader does not cryptographically
%% verify signatures it just created, and relay signatures were already verified
%% over opaque bytes before decode. Every other validator independently verifies
%% the complete proposed batch in acceptable_payload/2 before voting.
acceptable_collected_payload([#transaction{} | _] = Payload, S) ->
    proper_transaction_list(Payload)
        andalso length(Payload) =< ?MAX_BATCH_TXS
        andalso byte_size(term_to_binary(Payload, [deterministic])) =< ?MAX_BLOCK_BYTES
        andalso lists:all(fun(Change) -> ingress_change_acceptable(Change, S) end,
                          Payload)
        andalso unique_tx_ids(Payload)
        andalso sequence_payload_ok(Payload, S)
        andalso membership_payload_ok(Payload, S);
acceptable_collected_payload(_Payload, _S) ->
    false.

ingress_change_acceptable(#transaction{caller_ns = Ns, author = Author} = Change,
                          #s{ns = Ns, validators = Vs}) ->
    lists:member(Author, Vs) andalso change_acceptable(Change, Vs);
ingress_change_acceptable(_Change, _S) ->
    false.

proper_transaction_list([#transaction{} | Rest]) -> proper_transaction_list(Rest);
proper_transaction_list([]) -> true;
proper_transaction_list(_) -> false.

unique_tx_ids(Payload) ->
    Ids = [Id || #transaction{tx_id = Id} <- Payload],
    length(Ids) =:= length(lists:usort(Ids)).

%% Exact committed replay protection. A signed sequence may skip values, but it
%% must be newer than that author's approved history and unique within the block.
%% Including the approved parent is load-bearing for the depth-one pipeline:
%% H+2 cannot reuse a sequence notarized in H+1 while H+1 is not durable yet.
sequence_payload_ok(Payload, S) ->
    case approved_author_seqs(S) of
        {ok, Floor} -> sequence_payload_ok(Payload, Floor, #{});
        error       -> false
    end.

sequence_payload_ok([], _Floor, _Seen) ->
    true;
sequence_payload_ok(
  [#transaction{author = Author, author_seq = Seq} | Rest], Floor, Seen)
  when is_integer(Seq), Seq > 0 ->
    Seq > maps:get(Author, Floor, 0)
        andalso not maps:is_key({Author, Seq}, Seen)
        andalso sequence_payload_ok(Rest, Floor, Seen#{{Author, Seq} => true});
sequence_payload_ok(_Payload, _Floor, _Seen) ->
    false.

approved_author_seqs(#s{author_seqs = Seqs, approved = Approved,
                        slot = Committed})
  when Approved =:= Committed ->
    {ok, Seqs};
approved_author_seqs(#s{author_seqs = Seqs, approved = Approved,
                        eng = #eng{tree = Tree}}) ->
    case maps:get(Approved, Tree, undefined) of
        #block{payload = Payload} ->
            {ok, advance_author_seqs(Payload, Seqs)};
        undefined ->
            error
    end.

advance_author_seqs({batch, Payload}, Seqs) ->
    advance_author_seqs(Payload, Seqs);
advance_author_seqs(Payload, Seqs) when is_list(Payload) ->
    lists:foldl(
      fun(#transaction{author = Author, author_seq = Seq}, Acc)
            when is_integer(Seq), Seq >= 0 ->
              Acc#{Author => max(Seq, maps:get(Author, Acc, 0))};
         (_, Acc) ->
              Acc
      end, Seqs, Payload);
advance_author_seqs(_Data, Seqs) ->
    Seqs.

membership_payload_ok(Payload, #s{approved = Approved, slot = Committed}) ->
    Membership = [T || T <- Payload, is_membership_change(T)],
    case Membership of
        []  -> true;
        [_] -> membership_batch_shape_ok(Payload) andalso Approved =:= Committed;
        _   -> false
    end.

membership_batch_shape_ok(Payload) ->
    case [T || T <- Payload, is_membership_change(T)] of
        []  -> true;
        [_] -> length(Payload) =:= 1;
        _   -> false
    end.

payload_touches_committee(Payload) ->
    lists:any(fun is_membership_change/1, Payload).

is_membership_change(Change) -> committee_delta(Change) =/= {[], []}.

%% The pure acceptance decision over a validator LIST (exported for eunit; the `#s`-wrapper above is
%% what the propose/support call sites use).
change_acceptable(#transaction{tx_id = TxId, caller_ns = CallerNs, diff = Diff,
                               read_check = ReadCheck, author = Author,
                               author_seq = AuthorSeq,
                               submitted_at = SubmittedAt, sig = Sig} = T, Vs) ->
    well_formed_transaction_fields(TxId, CallerNs, Diff, ReadCheck, Author,
                                   AuthorSeq, SubmittedAt, Sig)
        andalso (not touches_committee(Diff) orelse membership_change_ok(T, Vs));
change_acceptable(_, _)      -> false.

-spec well_formed_transaction(term()) -> boolean().
well_formed_transaction(#transaction{tx_id = TxId, caller_ns = CallerNs, diff = Diff,
                                     read_check = ReadCheck, author = Author,
                                     author_seq = AuthorSeq,
                                     submitted_at = SubmittedAt, sig = Sig}) ->
    well_formed_transaction_fields(TxId, CallerNs, Diff, ReadCheck, Author,
                                   AuthorSeq, SubmittedAt, Sig);
well_formed_transaction(_) -> false.

well_formed_transaction_fields(TxId, CallerNs, Diff, ReadCheck, Author,
                               AuthorSeq, SubmittedAt, Sig) ->
    nonempty_binary(TxId)
        andalso nonempty_binary(CallerNs)
        andalso is_binary(Author) andalso byte_size(Author) =:= 32
        andalso is_integer(AuthorSeq) andalso AuthorSeq >= 0
        andalso is_integer(SubmittedAt) andalso SubmittedAt >= 0
        andalso (Sig =:= none orelse
                 (is_binary(Sig) andalso byte_size(Sig) =:= 64))
        andalso valid_read_check(ReadCheck)
        andalso valid_diff(Diff).

-doc """
Validate the transaction rules of one historical entry under the committee
as-of that slot. This is deliberately independent of certificate validation:
rebuild and catch-up both enforce the current signed-transaction protocol.
Only the explicitly positioned slot-1 genesis transaction may be unsigned.
""".
-spec valid_history_entry(binary(), pos_integer(), term(), [node_id()]) -> boolean().
valid_history_entry(Ns, 1, {batch, [#transaction{caller_ns = Ns, sig = none} = Genesis]}, [])
  when is_binary(Ns) ->
    well_formed_transaction(Genesis);
valid_history_entry(_Ns, I, noop, _Committee) when is_integer(I), I > 1 ->
    true;
valid_history_entry(Ns, I, {batch, Payload}, Committee)
  when is_binary(Ns), is_integer(I), I > 1, is_list(Committee) ->
    proper_transaction_list(Payload)
        andalso Payload =/= []
        andalso length(Payload) =< ?MAX_BATCH_TXS
        andalso byte_size(term_to_binary(Payload, [deterministic])) =< ?MAX_BLOCK_BYTES
        andalso lists:all(
                  fun(Change) ->
                      historical_change_shape_acceptable(Ns, Change, Committee)
                  end,
                  Payload)
        andalso verify_transaction_signatures(Ns, Payload, replay)
        andalso unique_tx_ids(Payload)
        andalso membership_batch_shape_ok(Payload);
valid_history_entry(_Ns, _I, _Data, _Committee) ->
    false.

historical_change_shape_acceptable(
  Ns, #transaction{caller_ns = Ns, author = Author, author_seq = Seq} = Change,
  Committee) ->
    lists:member(Author, Committee)
        andalso is_integer(Seq) andalso Seq > 0
        andalso change_acceptable(Change, Committee);
historical_change_shape_acceptable(_Ns, _Change, _Committee) ->
    false.

verify_transaction_signatures(_Ns, [], _Origin) ->
    true;
verify_transaction_signatures(Ns, Transactions, Origin)
  when length(Transactions) < 128 ->
    lists:all(fun(Transaction) ->
                      verify_transaction_signature(Ns, Transaction, Origin)
              end, Transactions);
verify_transaction_signatures(Ns, Transactions, Origin) ->
    WorkerCount = min(8, min(erlang:system_info(schedulers_online),
                             length(Transactions))),
    Chunks = transaction_chunks(Transactions, WorkerCount),
    Parent = self(),
    Workers =
        [begin
             Job = make_ref(),
             {Pid, Monitor} =
                 spawn_monitor(
                   fun() ->
                       Valid =
                           try lists:all(
                                 fun(Transaction) ->
                                     verify_transaction_signature(Ns, Transaction,
                                                                  Origin)
                                 end, Chunk)
                           catch
                               _:_ -> false
                           end,
                       Parent ! {transaction_signatures_verified, Job, Valid}
                   end),
             {Job, Pid, Monitor}
         end || Chunk <- Chunks],
    collect_signature_results(
      maps:from_list([{Job, {Pid, Monitor}} || {Job, Pid, Monitor} <- Workers]),
      maps:from_list([{Monitor, Job} || {Job, _Pid, Monitor} <- Workers]),
      true, quod_time:mono_ms() + ?SIGNATURE_VERIFY_TIMEOUT_MS).

transaction_chunks(Transactions, WorkerCount) ->
    ChunkSize = (length(Transactions) + WorkerCount - 1) div WorkerCount,
    transaction_chunks(Transactions, ChunkSize, []).

transaction_chunks([], _ChunkSize, Acc) ->
    lists:reverse(Acc);
transaction_chunks(Transactions, ChunkSize, Acc) ->
    {Chunk, Rest} = lists:split(min(ChunkSize, length(Transactions)),
                                Transactions),
    transaction_chunks(Rest, ChunkSize, [Chunk | Acc]).

collect_signature_results(ByJob, _ByMonitor, Valid, _Deadline)
  when map_size(ByJob) =:= 0 ->
    Valid;
collect_signature_results(ByJob, ByMonitor, Valid0, Deadline) ->
    Remaining = max(0, Deadline - quod_time:mono_ms()),
    receive
        {transaction_signatures_verified, Job, Valid}
          when is_map_key(Job, ByJob) ->
            {_Pid, Monitor} = maps:get(Job, ByJob),
            _ = erlang:demonitor(Monitor, [flush]),
            collect_signature_results(maps:remove(Job, ByJob),
                                      maps:remove(Monitor, ByMonitor),
                                      Valid0 andalso Valid, Deadline);
        {'DOWN', Monitor, process, _Pid, _Reason}
          when is_map_key(Monitor, ByMonitor) ->
            Job = maps:get(Monitor, ByMonitor),
            collect_signature_results(maps:remove(Job, ByJob),
                                      maps:remove(Monitor, ByMonitor),
                                      false, Deadline)
    after Remaining ->
        maps:foreach(
          fun(_Job, {Pid, Monitor}) ->
                  exit(Pid, kill),
                  _ = erlang:demonitor(Monitor, [flush])
          end, ByJob),
        false
    end.

verify_transaction_signature(Ns, Change, live) ->
    Started = erlang:monotonic_time(),
    Valid = quod_transaction:verify(Ns, Change),
    quod_metrics:observe_transaction_signature(
      Ns, Valid, erlang:monotonic_time() - Started),
    Valid;
verify_transaction_signature(Ns, Change, replay) ->
    quod_transaction:verify(Ns, Change).

nonempty_binary(Value) -> is_binary(Value) andalso byte_size(Value) > 0.

valid_read_check(ReadCheck) when is_map(ReadCheck) ->
    maps:fold(
      fun({Functor, Arity}, Hash, true) ->
              is_atom(Functor) andalso is_integer(Arity) andalso Arity >= 0
                  andalso is_integer(Hash) andalso Hash >= 0;
         (_Key, _Hash, _Acc) ->
              false
      end, true, ReadCheck);
valid_read_check(_) -> false.

%% Walk to `[]` and validate every operation, so both `quod_diff:apply_ops/2` and
%% the committee projection can consume any accepted diff without a catch-all path.
valid_diff([Op | Rest]) -> valid_op(Op) andalso valid_diff(Rest);
valid_diff([]) -> true;
valid_diff(_) -> false.

valid_op({Kind, {Head, Body}}) when Kind =:= assert; Kind =:= retract ->
    callable_head(Head) andalso valid_stored_term(Head) andalso valid_clause_body(Body);
valid_op(_) -> false.

callable_head(Head) when is_atom(Head) -> true;
callable_head(Head) when is_tuple(Head), tuple_size(Head) >= 2 -> is_atom(element(1, Head));
callable_head(_) -> false.

%% Erlog stores clause bodies in compiled `{Code, HasCut}` form. Legacy/manual
%% transactions may carry a legal source body instead; `quod_diff` normalizes that
%% deterministically before applying it. Validate both representations completely.
valid_clause_body(Body) -> valid_compiled_body(Body) orelse valid_raw_body(Body).

valid_compiled_body({Code, HasCut}) when is_boolean(HasCut) -> valid_code(Code);
valid_compiled_body(_) -> false.

valid_code([Instruction | Rest]) -> valid_instruction(Instruction) andalso valid_code(Rest);
valid_code([]) -> true;
valid_code(_) -> false.

valid_instruction({{disj}, Left, Right}) ->
    valid_code(Left) andalso valid_code(Right);
valid_instruction({{if_then}, Cond, Then, Label}) ->
    valid_code(Cond) andalso valid_code(Then) andalso valid_code_label(Label);
valid_instruction({{if_then_else}, Cond, Then, Else, Label}) ->
    valid_code(Cond) andalso valid_code(Then) andalso valid_code(Else)
        andalso valid_code_label(Label);
valid_instruction({{once}, Goal, Label}) ->
    valid_code(Goal) andalso valid_code_label(Label);
valid_instruction({{cut}, Label, Last}) ->
    valid_code_label(Label) andalso is_boolean(Last);
valid_instruction({call, {Variable}}) ->
    valid_variable(Variable);
valid_instruction(Goal) ->
    callable_head(Goal) andalso valid_stored_term(Goal).

valid_raw_body(Body) -> callable_body(Body) andalso valid_stored_term(Body).

callable_body(Body) when is_atom(Body) -> true;
callable_body({Variable}) -> valid_variable(Variable);
callable_body(Body) -> callable_head(Body).

valid_code_label(Label) -> is_atom(Label) orelse (is_integer(Label) andalso Label >= 0).
valid_variable(Variable) -> is_atom(Variable) orelse (is_integer(Variable) andalso Variable >= 0).

%% Stored clauses use integer variable ids after compilation (`{0}`, `{1}`, ...),
%% while source terms use atom ids. Erlog's public `is_legal_term/1` only accepts the
%% latter, so the durable representation needs this small explicit walker.
valid_stored_term({Variable}) -> valid_variable(Variable);
valid_stored_term(Term) when is_tuple(Term), tuple_size(Term) >= 2,
                             is_atom(element(1, Term)) ->
    valid_tuple_args(Term, 2, tuple_size(Term));
valid_stored_term([Head | Tail]) ->
    valid_stored_term(Head) andalso valid_stored_term(Tail);
valid_stored_term(Term) ->
    not is_tuple(Term) andalso not (is_list(Term) andalso Term =/= []).

valid_tuple_args(_Term, Index, Size) when Index > Size -> true;
valid_tuple_args(Term, Index, Size) ->
    valid_stored_term(element(Index, Term))
        andalso valid_tuple_args(Term, Index + 1, Size).

%% Does a diff touch the committee (any `peer_admitted` assert/retract)? Hostile diffs can hold ANY
%% term as an element — the catch-all keeps the scan total.
touches_committee(Diff) ->
    lists:any(fun({_K, {{peer_admitted, _, _, _, _}, _}}) -> true;
                 (_)                                      -> false
              end, Diff).

%% The membership gate — PURE (no KB access; the KB `can_join` re-proof is the deferred support in
%% `support_or_validate/2`): a
%% committee-changing transaction must be EXACTLY ONE well-formed `peer_admitted` op and must not
%% empty the committee.
%%
%% - ONE op, NOTHING else: kills a mass retract (one tx emptying the set), a mixed
%%   content+membership diff (which would smuggle content ops onto the membership apply path), and
%%   matches the honest vocabulary exactly (`admit`/`remove` each stage exactly one op).
%% - `Id =:= Pk`, binary: the fact's NodeId IS its pubkey (A.3); an op whose Id differs would poison
%%   the address book while the committee keys on the pubkey (element 5).
%% - Non-empty result: the wedge guard — an empty committee has no leader (`leader/2` → `none`) and
%%   the namespace could never commit again. The floor is STEPWISE (4→3→2→1 is legal, one
%%   quorum-endorsed member per block); the hard `3f+1` Byzantine-tolerance floor is deliberately NOT
%%   enforced (deferred.md §3(c) stays open — it needs a network-target-f concept).
membership_change_ok(#transaction{diff = [{Kind, {{peer_admitted, Id, _H, _P, Pk}, _B}}]} = T, Vs)
  when (Kind =:= assert orelse Kind =:= retract), is_binary(Pk), Id =:= Pk ->
    apply_committee_delta(T, Vs) =/= [];
membership_change_ok(#transaction{}, _Vs) ->
    false.   %% >1 op, mixed with content ops, malformed head, Id =/= Pk, non-binary pubkey

%% Send a consensus message to every OTHER member of the ACTIVE voting set, each on our own outbound link.
broadcast(Msg, S = #s{self = Self}) ->
    Frame = encode(S#s.ns, Msg),
    lists:foldl(fun(P, Acc) -> send_frame(P, Frame, Acc) end,
                S, active_validators(S) -- [Self]).

%% Send to one peer on our outbound link, dialing on demand; frames buffer (bounded) in the outbox until
%% `link_up` flushes them. We transmit only on our OWN outbound link, never a peer's inbound stream, so
%% every directed pair stays reachable (mirrors the removed Raft transport). The `dialing` marker keeps
%% at most one dial in flight per peer (a second `open_link` would register a duplicate waiter).
send_frame(Peer, Frame, S = #s{chan = Chan, conns = Conns, outbox = Outbox, dialing = Dialing}) ->
    case maps:get(Peer, Conns, undefined) of
        {LinkPid, _Ref} ->
            _ = quod_link:send(LinkPid, Frame),
            S;
        undefined ->
            Buffered = buffer_frame(Frame, maps:get(Peer, Outbox, [])),
            S1 = S#s{outbox = Outbox#{Peer => Buffered}},
            case maps:is_key(Peer, Dialing) of
                true  -> S1;                                  %% a dial is already in flight for this peer
                false -> _ = quod_quic:open_link(Peer, Chan),
                         S1#s{dialing = Dialing#{Peer => dial_deadline()}}
            end
    end.

%% Latest-value control frame. Never queue it: a successful link-up sends the then-current value directly,
%% while the periodic refresh retries a failed dial. This keeps a long-disconnected peer from accumulating
%% one obsolete readiness frame per committed height and displacing consensus evidence from the outbox.
send_readiness(Peer, Frame, S = #s{chan = Chan, conns = Conns, dialing = Dialing}) ->
    case maps:get(Peer, Conns, undefined) of
        {LinkPid, _Ref} ->
            _ = quod_link:send(LinkPid, Frame),
            S;
        undefined ->
            case maps:is_key(Peer, Dialing) of
                true  -> S;
                false -> _ = quod_quic:open_link(Peer, Chan),
                         S#s{dialing = Dialing#{Peer => dial_deadline()}}
            end
    end.

buffer_frame(Frame, Frames) ->
    %% Periodic vote redrive must leave one recoverable copy for a disconnected peer,
    %% not fill the bounded outbox with the same signed bytes every tick.
    case lists:member(Frame, Frames) of
        true  -> Frames;
        false -> lists:sublist([Frame | Frames], ?MAX_OUTBOX)
    end.

%% Re-drive (tick): re-dial every peer with buffered frames but no live link and no dial in flight — the
%% recovery path for a dial that failed (its `dialing` marker was cleared by `link_error`, its frames kept).
redial_pending(S = #s{conns = Conns, outbox = Outbox, dialing = Dialing, chan = Chan}) ->
    Pending = [P || P <- maps:keys(Outbox),
                    not maps:is_key(P, Conns), not maps:is_key(P, Dialing)],
    lists:foldl(fun(P, Acc) ->
                    _ = quod_quic:open_link(P, Chan),
                    Acc#s{dialing = (Acc#s.dialing)#{P => dial_deadline()}}
                end, S, Pending).

%% The `dialing` marker is normally cleared when the dial resolves (link_up / link_error). A dial that
%% resolves to NEITHER — its conn process died mid-handshake, or the `open_link` was dropped — would
%% otherwise pin the peer out of `redial_pending` forever (a permanent one-peer partition). Sweep every
%% marker past its deadline so the same tick re-dials it; the peer's frames are still in the outbox
%% (link_error keeps them, and a stuck dial never flushed them), so `redial_pending` picks it back up.
sweep_stale_dials(S = #s{dialing = Dialing}) ->
    S#s{dialing = prune_dials(Dialing, quod_time:mono_ms())}.

%% pure: keep only the dials whose deadline is still in the future.
prune_dials(Dialing, Now) ->
    maps:filter(fun(_Peer, Deadline) -> Now < Deadline end, Dialing).

%% Monotonic-ms deadline after which an unresolved dial is presumed lost. `?DIAL_TIMEOUT_MS` is a FIXED
%% constant, deliberately not an app-env knob: it must stay above the transport's worst-case dial
%% resolution (quod_conn connect ~5s + link-ack ~5s) so a legitimately in-flight dial is never swept
%% early. A too-short value would sweep a LIVE dial and re-open it (a second waiter on the same link,
%% resolving to a self-closing duplicate link_up), so the timeout is intentionally not tunable down.
dial_deadline() -> quod_time:mono_ms() + ?DIAL_TIMEOUT_MS.

%%%===================================================================
%%% transaction relay
%%%===================================================================

dispatch_relay(Peer, {relay_submit, ReqId,
                      {submit, Author, _Signature, _Canonical} = Submission,
                      TraceCarrier},
               S = #s{relay_results = Results, relay_inflight = Inflight}) ->
    case ReqId =:= quod_transaction:submission_id(Submission) of
        false ->
            {S, []};
        true ->
            case maps:get(ReqId, Results, undefined) of
                {Peer, Reply, _Expires} ->
                    {send_relay_result(Peer, ReqId, Reply, S), []};
                _ ->
                    case Peer =:= Author andalso
                         lists:member(Peer, active_validators(S)) of
                        false ->
                            reply_now({relay, Peer, ReqId},
                                      {error, bad_change}, S);
                        true ->
                            case maps:is_key(ReqId, Inflight) of
                                true ->
                                    {S, []};
                                false ->
                                    verify_and_accept_relay(
                                      Peer, ReqId, Submission, TraceCarrier, S)
                            end
                    end
            end
    end;
dispatch_relay(Peer, {relay_result, ReqId, Result}, S) ->
    {handle_relay_result(Peer, ReqId, Result, S), []}.

verify_and_accept_relay(Peer, ReqId, Submission, TraceCarrier,
                        S = #s{ns = Ns}) ->
    Started = erlang:monotonic_time(),
    Valid = quod_transaction:verify_submission(Submission),
    quod_metrics:observe_transaction_signature(
      Ns, Valid, erlang:monotonic_time() - Started),
    case Valid of
        false ->
            reply_now({relay, Peer, ReqId}, {error, bad_change}, S);
        true ->
            case quod_transaction:decode_verified_submission(Ns, Submission) of
                {ok, Change} ->
                    Inflight = (S#s.relay_inflight)#{ReqId => Peer},
                    ParentCtx = quod_trace:extract(TraceCarrier),
                    Waiter = new_waiter(
                               {relay, Peer, ReqId}, ParentCtx, Change, Ns, true),
                    _ = quod_trace:add_event(
                          waiter_trace_ctx(Waiter), <<"consensus.relay_received">>,
                          #{'quod.relay.source' => trace_node_id(Peer)}),
                    handle_relayed_append(
                      Waiter, Change, S#s{relay_inflight = Inflight});
                {error, _} ->
                    reply_now({relay, Peer, ReqId}, {error, bad_change}, S)
            end
    end.

handle_relay_result(Peer, ReqId, Result,
                    S = #s{relay_pending = Pending, validators = Validators}) ->
    case maps:get(ReqId, Pending, undefined) of
        #relay_pending{from = From, target = Peer, frame = Frame,
                       deadline = Deadline, redirects = Redirects} = Relay ->
            Now = quod_time:mono_ms(),
            case Result of
                {error, not_in_charge, Hint0}
                  when Now < Deadline, Redirects < 3 ->
                    %% Pre-positioning makes redirects rare (the target is computed,
                    %% not chased), but a residual misroute still resolves by hopping;
                    %% the budget bounds a Byzantine redirect ping-pong. A useless
                    %% hint (`none` from a recovering target, garbage, or the refusing
                    %% peer itself) is RESCUED with a locally recomputed seat rather
                    %% than surfaced as a terminal client error. Hint-paced
                    %% (immediate), not timer-paced.
                    case usable_hint(Hint0, Peer, Validators, S) of
                        {chase, Hint} ->
                            Relay1 = Relay#relay_pending{
                                       target = Hint,
                                       redirects = Redirects + 1,
                                       next_retry = Now + ?RELAY_RETRY_MS},
                            S1 = send_frame(Hint, Frame, S),
                            S1#s{relay_pending =
                                    (S1#s.relay_pending)#{ReqId => Relay1}};
                        self_leads ->
                            %% rotation came back around to US mid-relay: `skipped` is
                            %% the honest retryable verdict (quod_prolog re-proves and
                            %% the fresh append routes straight into our own batch)
                            reply_waiter(
                              From, {error, skipped},
                              S#s{relay_pending = maps:remove(ReqId, Pending)});
                        stuck ->
                            reply_waiter(
                              From, Result,
                              S#s{relay_pending = maps:remove(ReqId, Pending)})
                    end;
                _ ->
                    reply_waiter(
                      From, Result,
                      S#s{relay_pending = maps:remove(ReqId, Pending)})
            end;
        _ ->
            S
    end.

%% Pick the next relay target after a refusal. The peer's hint wins when it is a
%% real third validator; otherwise fall back to the seat we can compute ourselves
%% (`first_seat` over the local pipeline floor). `self_leads` when that seat is
%% ours — the caller retries locally instead of relaying to itself; `stuck` when
%% no forward target exists (refuser still leads from our view, empty committee).
usable_hint(Hint, Peer, Validators, S = #s{self = Self}) ->
    case is_binary(Hint) andalso Hint =/= Peer andalso Hint =/= Self
             andalso lists:member(Hint, Validators) of
        true ->
            {chase, Hint};
        false ->
            case leader(first_seat(S#s.approved + 1, S), active_validators(S)) of
                Self                            -> self_leads;
                L when is_binary(L), L =/= Peer -> {chase, L};
                _                               -> stuck
            end
    end.

reply_relay(Peer, ReqId, Reply, S) ->
    S1 = send_relay_result(Peer, ReqId, Reply, S),
    Results1 = quod_relay:put_result(
                 ReqId,
                 {Peer, Reply,
                  quod_time:mono_ms() + S1#s.relay_timeout_ms},
                 S1#s.relay_results),
    S1#s{relay_inflight = maps:remove(ReqId, S1#s.relay_inflight),
         relay_results = Results1}.

send_relay_result(Peer, ReqId, Reply, S = #s{ns = Ns}) ->
    send_frame(Peer, quod_relay:encode(Ns, {relay_result, ReqId, Reply}), S).

redrive_relays(S = #s{relay_pending = Pending, relay_results = Results}) ->
    Now = quod_time:mono_ms(),
    S1 = S#s{relay_results = quod_relay:prune_results(Results)},
    maps:fold(
      fun(ReqId,
          #relay_pending{from = From, target = Target, frame = Frame,
                         deadline = Deadline, next_retry = Retry} = Relay,
          Acc) ->
              case Now >= Deadline of
                  true ->
                      reply_waiter(
                        From, {error, not_in_charge, unavailable},
                        Acc#s{relay_pending =
                                  maps:remove(ReqId, Acc#s.relay_pending)});
                  false when Now >= Retry ->
                      Acc1 = send_frame(Target, Frame, Acc),
                      Relay1 = Relay#relay_pending{
                                   next_retry = Now + ?RELAY_RETRY_MS},
                      Acc1#s{relay_pending =
                                 (Acc1#s.relay_pending)#{ReqId => Relay1}};
                  false ->
                      Acc
              end
      end, S1, Pending).

encode(Ns, Msg) ->
    Inner = term_to_binary(Msg, [deterministic]),
    term_to_binary({sx, Ns, Inner}, [deterministic]).

%% The envelope is `[safe]` (known atoms only); the inner message carries `#transaction` diffs whose
%% Prolog atoms the receiver may not have seen yet, so it decodes WITHOUT `[safe]` — the same
%% trusted-committee posture as the removed Raft transport (bounded by the committee link scope;
%% doc/deferred.md §2). Returns `error` on anything malformed or for another namespace.
%% Our outbound link to a peer opened: adopt it (monitor + flush the outbox), unless we already hold a
%% LIVE link to it or it is not in the ACTIVE voting set (consensus links are scoped to the active set,
%% matching `broadcast/2`). A stored conn whose pid is DEAD (its `DOWN` not yet processed) is replaced —
%% never treat a corpse as a live duplicate and close the newcomer, or the peer could never re-link.
handle_link_up(Peer, LinkPid, S0 = #s{outbox = Outbox}) ->
    S = S0#s{dialing = maps:remove(Peer, S0#s.dialing)},   %% the dial resolved
    LiveDup = case maps:get(Peer, S#s.conns, undefined) of
                  {Pid, _Ref} -> is_process_alive(Pid);
                  undefined   -> false
              end,
    case LiveDup orelse (not lists:member(Peer, active_validators(S))) of
        true  -> _ = quod_link:close(LinkPid), S;
        false -> S1  = drop_conn_by_peer(Peer, S),
                 Ref = erlang:monitor(process, LinkPid),
                 _   = [quod_link:send(LinkPid, F) || F <- lists:reverse(maps:get(Peer, Outbox, []))],
                 S2 = S1#s{conns = (S1#s.conns)#{Peer => {LinkPid, Ref}},
                           outbox = maps:remove(Peer, Outbox)},
                 {Height, Ready} = local_readiness(S2),
                 _ = quod_link:send(LinkPid, encode(S2#s.ns, {readiness, Height, Ready})),
                 S2
    end.

%% Track the authenticated inbound stream that carries this peer's votes and readiness. Readiness is bound
%% to this exact pid; replacing the stream removes the previous claim before the new process can count.
track_inbound(Peer, LinkPid, S = #s{inbound_conns = Inbound})
  when is_pid(LinkPid) ->
    case is_process_alive(LinkPid) of
        true  -> track_live_inbound(Peer, LinkPid, S, Inbound);
        false -> S
    end;
track_inbound(_Peer, _LinkPid, S) ->
    S.

track_live_inbound(Peer, LinkPid, S, Inbound) ->
    case {lists:member(Peer, active_validators(S)), maps:get(Peer, Inbound, undefined)} of
        {false, _} ->
            S;
        {true, {LinkPid, _Ref}} ->
            S;
        {true, {OldPid, OldRef}} ->
            _ = quod_link:close(OldPid),
            _ = erlang:demonitor(OldRef, [flush]),
            Ref = erlang:monitor(process, LinkPid),
            S1 = drop_peer_readiness(Peer, S),
            S1#s{inbound_conns = Inbound#{Peer => {LinkPid, Ref}}};
        {true, undefined} ->
            Ref = erlang:monitor(process, LinkPid),
            S1 = drop_peer_readiness(Peer, S),
            S1#s{inbound_conns = Inbound#{Peer => {LinkPid, Ref}}}
    end.

%% A tracked link died (DOWN): drop it from either direction. A later send/tick reopens outbound links.
drop_link(Pid, S) ->
    drop_inbound(Pid, drop_conn(Pid, S)).

drop_conn(Pid, S = #s{conns = Conns}) ->
    case [{P, R} || {P, {LP, R}} <- maps:to_list(Conns), LP =:= Pid] of
        [{Peer, Ref} | _] ->
            _ = erlang:demonitor(Ref, [flush]),
            S#s{conns = maps:remove(Peer, Conns)};
        []                -> S
    end.

drop_inbound(Pid, S = #s{inbound_conns = Inbound}) ->
    case [{P, R} || {P, {LP, R}} <- maps:to_list(Inbound), LP =:= Pid] of
        [{Peer, Ref} | _] ->
            _ = erlang:demonitor(Ref, [flush]),
            drop_peer_readiness(Peer, S#s{inbound_conns = maps:remove(Peer, Inbound)});
        [] ->
            S
    end.

drop_conn_by_peer(Peer, S = #s{conns = Conns}) ->
    case maps:get(Peer, Conns, undefined) of
        {_Pid, Ref} -> _ = erlang:demonitor(Ref, [flush]), S#s{conns = maps:remove(Peer, Conns)};
        undefined   -> S
    end.

%% Committee membership scopes consensus transport state. Once a committed transition removes a peer,
%% close both stream directions and discard its queued frames/dial attempt so repeated membership churn
%% cannot accumulate unreachable link processes or stale outboxes.
prune_consensus_links(S = #s{self = Self, conns = Conns, inbound_conns = Inbound,
                             peer_readiness = Readiness,
                             outbox = Outbox, dialing = Dialing}) ->
    Allowed = maps:from_keys(active_validators(S) -- [Self], true),
    {Conns1, RemovedOut} = partition_consensus_links(Allowed, Conns),
    {Inbound1, RemovedIn} = partition_consensus_links(Allowed, Inbound),
    maps:foreach(fun(_Peer, Link) -> close_tracked_link(Link) end, RemovedOut),
    maps:foreach(fun(_Peer, Link) -> close_tracked_link(Link) end, RemovedIn),
    S#s{conns = Conns1,
        inbound_conns = Inbound1,
        peer_readiness = maps:with(maps:keys(Allowed), Readiness),
        outbox = maps:with(maps:keys(Allowed), Outbox),
        dialing = maps:with(maps:keys(Allowed), Dialing)}.

partition_consensus_links(Allowed, Links) ->
    maps:fold(
      fun(Peer, Link, {Keep, Remove}) ->
              case maps:is_key(Peer, Allowed) of
                  true  -> {Keep#{Peer => Link}, Remove};
                  false -> {Keep, Remove#{Peer => Link}}
              end
      end, {#{}, #{}}, Links).

close_tracked_link({Pid, Ref}) ->
    _ = erlang:demonitor(Ref, [flush]),
    _ = quod_link:close(Pid),
    ok.

%% Post-commit hook for the LIVE-commit consumers (the dissemination feed `m:quod_feed`, and `m:quod_metrics`
%% for per-tx observability): announce a LIVE-finalized entry as `{committed, Slot, Entry}` on the
%% `{committed, Ns}` property. Called ONLY from commit_block/skip_block (the live finality points) — never
%% from apply_committed/apply_catchup_window (replay), so catch-up/rebuild never re-broadcasts history
%% (content-layer-design §14 live-vs-replay). A no-op if nobody is subscribed. Off the reply path, so it
%% never blocks propose→commit.
publish_feed(Slot, #entry{} = Entry, #s{ns = Ns}) ->
    _ = quod_reg:publish({committed, Ns}, {committed, Slot, Entry}),
    ok.

%% Apply a freshly-committed block using the IN-HAND payload — no read-back of what we just wrote.
%% Only when quod_prolog is up AND we are contiguous (last_applied == Slot-1); otherwise leave it and
%% let the rebuild handshake re-drive the gap from the store (apply_committed/1).
apply_live(Slot, Change, S = #s{ns = Ns, last_applied = LA}) when LA =:= Slot - 1 ->
    case quod_reg:where({quod_prolog, Ns}) of
        undefined -> S;
        _         -> _ = safe_apply_block(Ns, Slot, Change, live),   %% async cast (breaks the append<->apply deadlock)
                     S#s{last_applied = Slot}
    end;
apply_live(_Slot, _Change, S) -> S.

%% Apply committed-but-unapplied blocks into quod_prolog, in slot order — STREAMED from the store
%% (this process keeps no in-memory log, and re-applying already-counted commits must not recount them).
%% Rebuild/member/feed-gap callers use replay; a settled observer's verified next-block feed fast path
%% uses live so its runtime receives the incremental event. Deferred if quod_prolog is not up; lookup is
%% done ONCE here, not per block. apply_block is a cast by design (see quod_prolog:apply_block/4 — a sync call
%% would deadlock the live write path), so a long replay would flood quod_prolog's mailbox with the
%% whole log; every ?APPLY_SYNC_EVERY casts a synchronous no-op (`quod_prolog:sync/1`) drains the
%% queue — its reply proves every prior cast was consumed, bounding the mailbox to one window.
%% The barrier is deadlock-safe: apply_committed only runs while the KB is NOT ready
%% (rebuild/catch-up), and an unready quod_prolog rejects proves, so it can never be parked in an
%% `append` back into this statem. If quod_prolog dies mid-replay, the barrier exits `noproc`:
%% stop replaying with last_applied unchanged — its restart casts `rebuild` and re-drives the gap.
apply_committed(S) -> apply_committed(S, replay).

apply_committed(S = #s{last_applied = LA, slot = C}, _Origin) when LA >= C -> S;
apply_committed(S = #s{ns = Ns, store = Store, last_applied = LA, slot = C}, Origin) ->
    case quod_reg:where({quod_prolog, Ns}) of
        undefined -> S;
        _ ->
            try
                _ = quod_ledger_store:fold(Store, LA + 1, C,
                                           fun(#entry{index = I, data = Data}, N) ->
                                               _ = safe_apply_block(Ns, I, Data, Origin),
                                               N rem ?APPLY_SYNC_EVERY =:= 0
                                                   andalso (ok = quod_prolog:sync(Ns)),
                                               N + 1
                                           end, 1),
                S#s{last_applied = C}
            catch exit:{noproc, _} -> S   %% quod_prolog died mid-replay; its rebuild re-drives
            end
    end.

safe_apply_block(Ns, I, Data, Origin) ->
    try quod_prolog:apply_block(Ns, I, Data, Origin) catch _:_ -> ok end.

%% Tell quod_prolog its kb is rebuilt and it may serve proves — but only ONCE the committed prefix is
%% actually applied AND recovery is `ready`, so a node never answers from a half-built or uncorroborated
%% kb. A joiner/resuming member must NOT mark ready mid-sync: its height only reflects the windows sunk so
%% far. `prolog_ready` is monotone: a later-behind node keeps serving its
%% (stale-but-valid) reads while it gap-fills — it never drops back to unready.
maybe_mark_ready(S = #s{ns = Ns, prolog_ready = false, sync = ready}) ->
    Prolog = try quod_reg:where({quod_prolog, Ns}) catch _:_ -> undefined end,
    case (Prolog =/= undefined) andalso (S#s.last_applied >= S#s.slot) of
        true  -> _ = try quod_prolog:mark_ready(Ns) catch _:_ -> ok end,
                 S#s{prolog_ready = true};
        false -> S
    end;
maybe_mark_ready(S) -> S.   %% already marked ready, or recovery has not reached `ready` yet

%%%===================================================================
%%% mode=join — trustless catch-up (the joiner side of Simplex 4)
%%%===================================================================

%% The highest slot for which a FINALIZER cert (commit | complaint — the certs that advance the committed
%% height; a bare support cert only notarizes) sits in the pool ABOVE `base`. A finalizer cert is quorum-signed,
%% so a single Byzantine node cannot forge one — this is the VERIFIED "the committed head has moved past me"
%% signal, never a monotone `observed_head` integer a lying peer could poison. Seeded with `base` so an empty
%% pool yields `base` (no `lists:max([])` crash). See `behind/1`.
-spec ahead_cert_ceiling(#eng{}) -> slot().
ahead_cert_ceiling(#eng{certs = Certs, base = Base}) ->
    lists:max([Base | [Sl || {K, Sl, _BH} <- maps:keys(Certs),
                             Sl > Base, (K =:= commit orelse K =:= complaint)]]).

%% True iff a finalizer cert proves the committed head is beyond our approved frontier. If the cert names
%% the very next slot but its block is absent, this node is already behind: it must recover the durable entry
%% rather than remain vote-capable at a stale frontier. Recomputed on demand (never a stored latch), so it is
%% self-correcting: as a pull raises `slot`/`base`, `eng_prune` drops those certs and the ceiling falls.
%% Deliberately compare with `approved`, not mere raw block presence: a block held without its support path is
%% not a parent this validator may extend. A cert-before-block reorder can therefore revoke voting briefly;
%% synchronous engine settlement restores it as soon as the authenticated block reaches the tree.
-spec behind(#s{}) -> boolean().
behind(#s{eng = Eng, approved = Approved}) -> ahead_cert_ceiling(Eng) > Approved.

%% Facts-only participation: a member of the ACTIVE voting set. A recovering member still ingests verified
%% traffic so its gap detector can learn, but participation alone grants no signing capability.
is_participant(#s{self = Self} = S) -> lists:member(Self, active_validators(S)).

%% `ready` is the only recovery state with a corroborated tip. A live finalizer above the local window
%% revokes the capability immediately, before the paced recovery worker starts.
caught_up(#s{sync = ready} = S) -> not behind(S);
caught_up(_S) -> false.

%% Load-robust corroboration. The tip probe (recover_tip) confirms readiness by catching a QUORUM at an
%% EXACT quiet height — which a busy namespace almost never offers, so under sustained load a restarted
%% member could chase the moving head indefinitely and never resume voting. But a LIVE finalization —
%% commit_block/skip_block reached only from an ingested QUORUM cert on the `{log}` stream (never a
%% catch-up pull, which persists via apply_catchup_window) — already proves two things: this node is
%% connected to the CURRENT committee, and its just-finalized head is quorum-cert-verified. That is
%% exactly what `ready` asserts, so an `unconfirmed` member self-corroborates here, complementing (not
%% replacing) the idle-time probe. Safety holds: `behind/1` still gates `caught_up`, so flipping ready
%% over a head that is still behind cannot vote or lead on a stale slot — it only lets the member resume
%% once the residual gap clears. Fires only for a member (an observer never reaches commit_block live) and
%% only when idle between ticks; a live finalizer during an in-flight pull is handled by the `sync_done`
%% `Slot >= H` guard instead.
confirm_live(S = #s{sync = unconfirmed}) -> S#s{sync = ready, sync_arm = reset_pace()};
confirm_live(S)                          -> S.

%% Voting and leading share one capability boundary. Leadership remains a named predicate because callers
%% express intent, but neither can drift from the recovery policy.
may_vote(S) -> is_participant(S) andalso caught_up(S).
may_lead(S) -> may_vote(S).

%% An unconfirmed node always recovers. A ready member recovers when a verified finalizer is beyond its
%% approved frontier, including a finalized next block whose content never reached this node.
should_sync(#s{sync = unconfirmed}) -> true;
should_sync(#s{sync = ready} = S) -> behind(S).

%% The feed follows only in the sole settled state, so its puller and recovery can never own ingestion at
%% the same time.
syncing(#s{sync = Sy}) -> Sy =/= ready.

%% Catch-up ingestion is capability-based: one monitored recovery worker, or the feed while this node is a
%% ready observer. There is no state in which both sources are authorized.
may_sink({recovery, Pid}, #s{sync = {pulling, Pid}}) -> true;
may_sink({feed, Mode}, #s{sync = ready} = S) when Mode =:= live; Mode =:= replay ->
    not is_participant(S);
may_sink(_Source, _S) -> false.

%% Spawn the unified recovery coordinator. It owns ingestion for its lifetime, resumes from the current
%% durable snapshot before each source fetch, and reports `ready` only after the final height is corroborated by
%% a certificate quorum of the current committee. A raw `{ok, Height}` from one catch-up server is therefore
%% progress, never authority to vote.
start_sync_worker(S = #s{ns = Ns, self = Self, genesis_hash = GH}) ->
    Statem = self(),
    {Pid, _Ref} = spawn_monitor(
        fun() ->
            Owner = self(),
            Sink = fun(Es) ->
                       gen_statem:call(Statem, {sink_catchup, {recovery, Owner}, Es}, ?SINK_MS)
                   end,
            Result = run_recovery(Ns, GH, Statem, Self, Sink),
            gen_statem:cast(Statem, {sync_done, Owner, Result})
        end),
    S#s{sync = {pulling, Pid}}.

%% Fellow current members minus self, shuffled before each probe round. A behind member normally holds
%% their authenticated endpoints from live traffic; a fresh observer with no committee instead reaches
%% the bootstrap-source branch below.
committee_contacts(Self, Committee) ->
    Peers = lists:usort(Committee) -- [Self],
    quod_brahms:take_random(length(Peers), Peers).

%% Recovery has two deliberately separate jobs:
%%
%% 1. Probe every current committee peer at `local_height + 1`, in parallel. Empty replies at exactly the
%%    local height corroborate the tip; non-empty replies merely nominate a source that may be ahead.
%% 2. If needed, reconcile from ONE nominated source with the normal certificate-verifying catch-up fold,
%%    then probe the (possibly changed) committee again.
%%
%% This avoids both old failure modes: the first stale `{ok, [], H}` can never declare readiness, and cold
%% startup costs one network timeout rather than `committee_size * timeout`. A bootstrap endpoint may fetch
%% history but never corroborates a voting member because endpoint requests are not identity-bound.
run_recovery(Ns, GH, Statem, Self, Sink) ->
    recover_tip(Ns, GH, Statem, Self, Sink, ?RECOVERY_FETCHES, false,
                ?RECOVERY_HINT_WARMS).

recover_tip(Ns, GH, Statem, Self, Sink, FetchesLeft, FallbackUsed, HintWarms) ->
    case recovery_snapshot(Statem) of
        {ok, From, Committee} when From > 1 ->
            Height = From - 1,
            Peers = committee_contacts(Self, Committee),
            Needed = required_tip_peers(Committee, Self),
            Probes = probe_tips(Ns, Height, Peers, Needed),
            Exact = [Peer || {Peer, {ok, [], H}} <- Probes, H =:= Height],
            case tip_ready(Committee, Self, Exact) of
                true -> {ready, Height};
                false ->
                    case HintWarms > 0 andalso needs_hint_warm(Committee, Self) of
                        true ->
                            %% A cold node has endpoint seeds but no pubkey=>endpoint cache. Warm a
                            %% bounded set with tiny direct pulls; each authenticated header teaches the
                            %% resolver, then the NEXT pass remains the normal identity-bound quorum probe.
                            warm_contact_hints(Ns, Height),
                            recover_tip(Ns, GH, Statem, Self, Sink, FetchesLeft,
                                        FallbackUsed, HintWarms - 1);
                        false ->
                            Failure = {tip_unconfirmed, Height, length(lists:usort(Exact))},
                            continue_recovery(Ns, GH, Statem, Self, Sink, FetchesLeft,
                                              FallbackUsed, ahead_contacts(Probes), Exact, Failure)
                    end
            end;
        {ok, _From, _Committee} ->
            continue_recovery(Ns, GH, Statem, Self, Sink, FetchesLeft,
                              FallbackUsed, [], [], empty_namespace);
        {error, R} -> {error, {status, R}}
    end.

%% A member needs a quorum-minus-self of resolvable peers; an observer needs one current member. We only
%% warm when the address cache cannot possibly satisfy that threshold, so normal restarts add no traffic.
needs_hint_warm(Committee, Self) ->
    Needed = required_tip_peers(Committee, Self),
    Resolvable = length([Peer || Peer <- Committee -- [Self],
                                  quod_quic:resolve(Peer) =/= error]),
    Resolvable < Needed.

%% Direct endpoint pulls authenticate their link headers and populate the pubkey=>endpoint cache. Their
%% replies are intentionally discarded: only catch_up_from/6 is allowed to put data into the ledger.
warm_contact_hints(Ns, Height) ->
    Contacts = quod_catchup:contacts(Ns, ?RECOVERY_WARM_CONTACTS),
    Parent = self(),
    Ref = make_ref(),
    _ = [spawn(fun() ->
                   _ = catch quod_catchup:pull(Ns, Height + 1, Height + 1, Contact),
                   Parent ! {recovery_hint_warm, Ref}
               end) || Contact <- Contacts],
    wait_hint_warms(Ref, length(Contacts), quod_time:mono_ms() + ?TIP_PROBE_MS).

wait_hint_warms(_Ref, 0, _Deadline) -> ok;
wait_hint_warms(Ref, Left, Deadline) ->
    receive
        {recovery_hint_warm, Ref} -> wait_hint_warms(Ref, Left - 1, Deadline)
    after max(0, Deadline - quod_time:mono_ms()) ->
        ok
    end.

%% A voting member contributes its own durable head, so it needs `quorum(N)-1` peer confirmations. An
%% observer cannot vote and needs only one current member to confirm its read tip. N=1 therefore settles
%% without network traffic, matching the sole-validator bootstrap rule.
required_tip_peers(Committee, Self) ->
    case lists:member(Self, Committee) of
        true  -> max(0, quorum(length(Committee)) - 1);
        false -> 1
    end.

tip_ready(Committee, Self, ExactPeers) ->
    case lists:member(Self, Committee) of
        true  -> tip_quorum(Committee, Self, ExactPeers);
        false -> lists:any(fun(P) -> lists:member(P, Committee) end, ExactPeers)
    end.

ahead_contacts(Probes) ->
    lists:usort([Peer || {Peer, {ok, [_ | _], _Height}} <- Probes]).

continue_recovery(_Ns, _GH, _Statem, _Self, _Sink, 0,
                  _FallbackUsed, _Ahead, _Exact, Failure) ->
    {error, Failure};
continue_recovery(Ns, GH, Statem, Self, Sink, FetchesLeft,
                  FallbackUsed, Ahead, Exact, Failure) ->
    case recovery_sources(Ns, Ahead, Exact, FallbackUsed) of
        {[], _} -> {error, Failure};
        {Sources, FallbackUsed1} ->
            case try_recovery_sources(Ns, GH, Statem, Sources, Sink) of
                {ok, _} ->
                    recover_tip(Ns, GH, Statem, Self, Sink, FetchesLeft - 1, FallbackUsed1,
                                ?RECOVERY_HINT_WARMS);
                {error, _} -> {error, Failure}
            end
    end.

%% Only fall back to an unbound Brahms/seed endpoint when no current member supplied even one exact or
%% ahead response. It can teach us an address and provide verified history; the next identity-bound probe
%% still decides readiness.
recovery_sources(_Ns, Ahead, _Exact, FallbackUsed) when Ahead =/= [] ->
    {Ahead, FallbackUsed};
recovery_sources(Ns, [], [], false) ->
    case quod_catchup:contact(Ns) of
        none    -> {[], true};
        Contact -> {[Contact], true}
    end;
recovery_sources(_Ns, [], _Exact, FallbackUsed) -> {[], FallbackUsed}.

try_recovery_sources(_Ns, _GH, _Statem, [], _Sink) -> {error, no_source};
try_recovery_sources(Ns, GH, Statem, [Contact | Rest], Sink) ->
    case recovery_snapshot(Statem) of
        {ok, From, Committee} ->
            case catch_up_from(Ns, GH, From, Committee, Contact, Sink) of
                {ok, _} = Ok -> Ok;
                {error, _}   -> try_recovery_sources(Ns, GH, Statem, Rest, Sink)
            end;
        {error, R} -> {error, {status, R}}
    end.

probe_tips(_Ns, _Height, _Peers, Needed) when Needed =< 0 -> [];
probe_tips(_Ns, _Height, [], _Needed) -> [];
probe_tips(Ns, Height, Peers, Needed) ->
    Parent = self(),
    Ref = make_ref(),
    _ = [spawn(fun() ->
                   Result = try quod_catchup:pull(Ns, Height + 1,
                                                  Height + ?SYNC_WINDOW, Peer)
                            catch C:R -> {error, {C, R}}
                            end,
                   Parent ! {tip_probe, Ref, Peer, Result}
               end) || Peer <- Peers],
    Deadline = quod_time:mono_ms() + ?TIP_PROBE_MS,
    collect_tip_probes(Ref, Height, length(Peers), Needed, Deadline, 0, []).

collect_tip_probes(_Ref, _Height, 0, _Needed, _Deadline, _ExactN, Acc) ->
    lists:reverse(Acc);
collect_tip_probes(_Ref, _Height, _Left, Needed, _Deadline, ExactN, Acc)
        when ExactN >= Needed ->
    lists:reverse(Acc);
collect_tip_probes(Ref, Height, Left, Needed, Deadline, ExactN, Acc) ->
    Wait = max(0, Deadline - quod_time:mono_ms()),
    receive
        {tip_probe, Ref, Peer, Result} ->
            ExactN1 = case Result of {ok, [], Height} -> ExactN + 1; _ -> ExactN end,
            collect_tip_probes(Ref, Height, Left - 1, Needed, Deadline,
                               ExactN1, [{Peer, Result} | Acc])
    after Wait ->
        lists:reverse(Acc)
    end.

recovery_snapshot(Statem) ->
    try gen_statem:call(Statem, get_status, 5000) of
        #{slot := H, committee := Committee} when is_integer(H), is_list(Committee) ->
            {ok, H + 1, Committee};
        _ -> {error, bad_status}
    catch exit:R -> {error, R}
    end.

%% Self's durable head plus distinct, current committee peers at exactly that height must form a quorum.
%% Lower reports are stale; higher reports are consumed by catch-up and require another round if they were
%% observed too late for enough earlier contacts to corroborate the new final height.
tip_quorum([], _Self, _Peers) -> false;
tip_quorum(Committee, Self, Peers) ->
    Local = case lists:member(Self, Committee) of true -> [Self]; false -> [] end,
    Confirmed = lists:usort(Local ++ [P || P <- Peers, lists:member(P, Committee)]),
    length(Confirmed) >= quorum(length(Committee)).

catch_up_from(Ns, GH, From, Committee, Contact, Sink) ->
    Fetch = fun(F) -> quod_catchup:pull(Ns, F, F + ?SYNC_WINDOW - 1, Contact) end,
    quod_catchup:catch_up(Ns, GH, Fetch, Sink, From, Committee).

%% The single recovery armer, run each tick off the commit hot path. It owns gap hysteresis and failure
%% backoff; the recovery enum enforces single flight.
maybe_arm_sync(S = #s{sync = {pulling, _}}) -> S;
maybe_arm_sync(S0 = #s{sync = Sy}) when Sy =:= unconfirmed; Sy =:= ready ->
    S = pace_tick(S0),
    case should_sync(S) of
        false -> S#s{sync_arm = reset_pace()};   %% at the tip: clear pacing so a later gap starts fresh
        true  -> case arm_ready(S) andalso sibling_up(S) of
                     true  -> start_sync_worker(S);
                     false -> S
                 end
    end.

%% Advance the pacing counters one tick (pure bookkeeping — the arm decision is arm_ready/1): grow the
%% behind-hysteresis while `behind` (reset otherwise), and count down any active backoff cooldown.
pace_tick(S = #s{sync_arm = {Hyst, Cool, Int}}) ->
    Hyst1 = case behind(S) of true -> Hyst + 1; false -> 0 end,
    S#s{sync_arm = {Hyst1, max(0, Cool - 1), Int}}.

%% Unconfirmed nodes arm immediately once backoff expires; an established node waits for persistent gap
%% evidence so transient one-slot lag continues to use the cheap consensus redrive.
arm_ready(#s{sync = Sy, sync_arm = {Hyst, Cool, _Int}}) ->
    Cool =:= 0 andalso (Sy =:= unconfirmed orelse Hyst >= ?SYNC_HYSTERESIS).

recovery_failed(S) ->
    S#s{sync = unconfirmed, sync_arm = backoff(S#s.sync_arm)}.

%% Grow the failure backoff: double the interval (floored at ?SYNC_BACKOFF_MIN, capped at ?SYNC_BACKOFF_MAX
%% ticks), set the cooldown to a ±20%-jittered copy, and reset the hysteresis (a fresh attempt just failed).
backoff({_Hyst, _Cool, Int}) ->
    Int1 = min(?SYNC_BACKOFF_MAX, max(?SYNC_BACKOFF_MIN, Int * 2)),
    {0, jitter_ticks(Int1), Int1}.

reset_pace() -> {0, 0, 0}.

%% ±20% jitter (mirroring quod_feed's), floored at 1 tick — spreads a fleet's retry storms.
jitter_ticks(N) -> max(1, N - (N div 5) + rand:uniform(2 * (N div 5) + 1) - 1).

%% The catchup sibling (later in the rest_for_one chain) must be up before a worker can pull through it.
sibling_up(#s{ns = Ns}) -> quod_reg:where({quod_catchup, Ns}) =/= undefined.

%% Persist a verified, contiguous window (indices `slot+1..`) to the store, fold the committee across it,
%% and apply it into quod_prolog in slot order. Recovery and feed gap windows are replay; a settled
%% observer's verified next-block fast path is live and drives runtime handlers incrementally.
%% An APPEND error aborts the window cleanly (returns `{error, _}` ⇒ the driver fails over); nothing is
%% acked half-applied. The try covers ONLY the append: once the window is durable, reverting to the
%% pre-append state on a later throw would hand the retry a STALE handle whose re-append splices over
%% live bytes — so a post-append failure (a store read-back error in the replay) crashes the statem
%% instead, and the restart re-derives from the disk log, appended window included (fail-loud, no splice).
%% Both projections (validator set, KB) advance together from the one appended log.
apply_catchup_window(_Source, [], S) -> {S, ok};
apply_catchup_window(Source, Es0, S = #s{store = Store, validators = Vs}) ->
    %% Idempotency: the live engine may have committed a prefix of this window while the pull worker was
    %% fetching it (a VOTING member gap-fills while still ingesting live consensus). Drop the already-present
    %% prefix so the append stays contiguous instead of failing `assert_contiguous`.
    case drop_index_le(quod_ledger_store:last(Store), Es0) of
        []  -> {S, ok};   %% window entirely already-present — nothing new to sink
        Es  ->
    case try quod_ledger_store:append(Store, Es) catch _:R -> {error, R} end of
        {error, _} = Err -> {S, Err};
        {ok, Store1} ->
            {Vs1, Ts1, Seqs1} =
                log_projection(Es, {Vs, S#s.last_ts, S#s.author_seqs}),
            %% only re-walk the window for dial hints when it actually changed the committee — the common
            %% content-only window (Vs1 =:= Vs) skips the whole flatmap. (A same-window remove+re-add nets
            %% Vs1 =:= Vs and is skipped — the accepted address-refresh residual; heals via a header hint.)
            case Vs1 =/= Vs of
                true  -> learn_member_endpoints(Es, Vs1, S#s.self);   %% dial hints from replayed admit facts
                false -> ok
            end,
            Slot = (lists:last(Es))#entry.index,
            %% Re-seat the engine UNCONDITIONALLY at the new head (committee-as-of-new-head + reset every stale
            %% live-slot latch). For a VOTING member gap-filling this is load-bearing (its engine was pinned to
            %% the stale head); for a joiner/observer the resets are no-ops. The following
            %% `catchup_membership_transition` emits the S5b false->true notice. The caller
            %% (`sink_catchup`) passes the result through `keep_progress/3`, so the discarded head state
            %% cancels its named watchdog before voting resumes.
            S1 = reseat_engine(
                   Slot, S#s{store = Store1, validators = Vs1, slot = Slot,
                             last_ts = Ts1, author_seqs = Seqs1,
                             next_author_seq =
                                 max(S#s.next_author_seq,
                                     maps:get(S#s.self, Seqs1, 0) + 1)}),
            S2 = catchup_membership_transition(S, S1),
            {apply_committed(S2, catchup_origin(Source)), ok}
    end
    end.

catchup_origin({feed, live}) -> live;
catchup_origin(_)            -> replay.

%% Drop entries whose `#entry.index` is `=< LastI` (already durable) — keep only the genuinely-new tail so a
%% window that straddles a prefix the live engine committed meanwhile still appends contiguously.
drop_index_le(LastI, Es) -> [E || E <- Es, E#entry.index > LastI].

%% Learn dial hints from a REPLAYED catch-up window (`learn_if_absent` — historical addresses fill a void,
%% never clobber a live header hint; polarity verified: the reply-link header teaches the fresh address
%% before any window is sunk). Filtered to the post-fold committee `Committee` so replaying a long history
%% never stuffs the resolver with long-removed members' rotted endpoints; `maps:from_list` gives last-wins
%% within the window (a remove+re-add of one pk learns the re-add). Excludes Self.
learn_member_endpoints(Es, Committee, Self) ->
    Eps = maps:from_list(lists:flatmap(fun(#entry{data = D}) -> admitted_endpoints(D) end, Es)),
    maps:foreach(fun(Pk, Ep) ->
                     case Pk =/= Self andalso lists:member(Pk, Committee) of
                         true  -> quod_quic:learn_if_absent(Pk, Ep);
                         false -> ok
                     end
                 end, Eps).

%% A feed window can cross this node's admission. Re-seating updates the committee immediately, but promotion
%% revokes feed ownership and enters recovery before the first vote. If the node's own recovery worker sank
%% the admission, keep its `{pulling,Pid}` ownership: that same coordinator will corroborate the new committee.
catchup_membership_transition(S0, S1) ->
    case {is_participant(S0), is_participant(S1)} of
        {false, true} ->
            logger:notice("quod[~s]: admitted to the committee — recovering at slot ~b (committee ~b)",
                          [S1#s.ns, S1#s.slot, length(active_validators(S1))]),
            case S1#s.sync of
                ready -> S1#s{sync = unconfirmed, sync_arm = reset_pace()};
                _     -> S1
            end;
        _ -> S1
    end.

%% Re-seat the engine to `NewHead` after a catch-up window (or a promotion) advanced the committed height: a
%% fresh engine over the committee AS-OF the new head, PLUS a reset of every volatile consensus window.
%% Those slots are now decided history, so a lingering local proposal/timer would wedge the leader or
%% redrive a `=< base` slot; parked appends for discarded slots are nacked so the caller
%% retries. Called UNCONDITIONALLY from every catch-up window (`apply_catchup_window`), replacing the former
%% separate catch-up and promotion re-arms with one `eng_new/2` path. At
%% a joiner/observer site the latch resets are no-ops (no live-slot state); they are load-bearing for a VOTING
%% member gap-filling — the caller (`sink_catchup`) passes this through `keep_progress/3` to cancel a stale
%% head watchdog when `head_progress` is cleared here (a no-op where it is already idle).
reseat_engine(NewHead, S) ->
    S1 = prune_consensus_links(nack_inflight(S)),
    {ok, Journal1} = prune_vote_journal(NewHead, S1#s.vote_journal),
    S1#s{eng             = eng_new(active_validators(S1), NewHead),
          vote_journal    = Journal1,
          approved        = NewHead,
          commit_buf      = #{},
          block_requests  = #{},
          requested_slot  = none,
          head_progress   = idle,
          rounds          = vote_rounds(Journal1)}.

%% A recovery re-seat intentionally discards the whole volatile consensus window.
%% Its fresh engine cannot safely retain proposals or votes from the old base.
nack_inflight(S0 = #s{local_proposals = Local}) ->
    S1 = lists:foldl(fun nack_local/2, S0, maps:keys(Local)),
    nack_collecting(nack_ingress(S1)).

local_genesis_hash(#s{store = Store}) ->
    case quod_ledger_store:read_at(Store, 1) of
        {ok, #entry{} = E} -> case block_from_entry(E) of
                                  {ok, Block} -> block_hash(Block);
                                  error       -> undefined
                              end;
        _                  -> undefined
    end.

%%%===================================================================
%%% helpers
%%%===================================================================

%% Re-derive the notional #block{} from a persisted #entry{} (quod keeps no block header, so slot/parent
%% are implicit and the block time is mirrored into the entry). The single reconstruction point — every
%% cert / genesis-anchor check recomputes `block_hash` through here, so a hash-covered field can only be
%% added in ONE place. Used by `local_genesis_hash` and `quod_catchup` (verify_entry / anchor_ok).
-spec block_from_entry(term()) -> {ok, #block{}} | error.
block_from_entry(#entry{index = I, data = D, timestamp = Ts})
  when is_integer(I), I >= 1, is_integer(Ts), Ts >= 0 ->
    case quod_ledger:payload(D) of
        {ok, Payload} -> {ok, #block{slot = I, parent = I - 1,
                                    payload = Payload, timestamp = Ts}};
        error -> error
    end;
block_from_entry(_) -> error.

%% ONE pass over a run of committed entries yielding BOTH projections we need from the log: the validator
%% set (fold `peer_admitted` asserts/retracts through `apply_committee_delta/2`) and the monotonic
%% timestamp floor (max block time; `noop` skips carry 0 and never lower it). Seed `{[], 0}` for a full
%% boot re-fold (streamed straight off the store via `quod_ledger_store:fold/5` + `log_projection_step/2`),
%% or `{RunningVs, last_ts}` for an in-hand catch-up window — one step function, so the boot re-derive
%% and the running set/bound can never drift.
-spec log_projection([#entry{}],
                     {[node_id()], non_neg_integer(),
                      #{node_id() => non_neg_integer()}}) ->
        {[node_id()], non_neg_integer(),
         #{node_id() => non_neg_integer()}}.
log_projection(Entries, Seed) ->
    lists:foldl(fun log_projection_step/2, Seed, Entries).

log_projection_step(#entry{data = Data, timestamp = T}, {V, Ts, Seqs}) ->
    {apply_committee_delta(Data, V), max(T, Ts),
     advance_author_seqs(Data, Seqs)}.

checked_log_projection_step(
  Ns, #entry{index = I, data = Data} = Entry, {V, _Ts, Seqs} = Acc) ->
    case valid_history_entry(Ns, I, Data, V)
         andalso historical_sequences_ok(I, Data, Seqs) of
        true  -> log_projection_step(Entry, Acc);
        false -> error({invalid_transaction_history, I})
    end.

historical_sequences_ok(1, {batch, [_Genesis]}, _Seqs) ->
    true;
historical_sequences_ok(_I, {batch, Payload}, Seqs) ->
    historical_payload_sequences_ok(Payload, Seqs, #{});
historical_sequences_ok(_I, noop, _Seqs) ->
    true.

historical_payload_sequences_ok([], _Seqs, _Seen) ->
    true;
historical_payload_sequences_ok(
  [#transaction{author = Author, author_seq = Seq} | Rest], Seqs, Seen)
  when is_integer(Seq), Seq > 0 ->
    Seq > maps:get(Author, Seqs, 0)
        andalso not maps:is_key({Author, Seq}, Seen)
        andalso historical_payload_sequences_ok(
                  Rest, Seqs, Seen#{{Author, Seq} => true});
historical_payload_sequences_ok(_Payload, _Seqs, _Seen) ->
    false.

%% The committee change carried by one committed payload: the `peer_admitted` pubkeys it asserts (added)
%% and retracts (removed). Each transaction folds its diff (the validator id is the 4th arg / 5th element
%% of `peer_admitted(NodeId, Host, Port, Pubkey)`); a `noop` or malformed payload changes nothing. This ONE
%% function feeds BOTH the live commit-time swap (`adopt_committee/2`) and the boot/restart re-fold
%% (`log_projection/2`), so the running set can never drift from a fresh re-fold.
committee_delta(#transaction{} = Transaction) ->
    committee_transaction(Transaction, {[], []});
committee_delta({batch, _} = Batch) ->
    case quod_ledger:payload(Batch) of
        {ok, Transactions} -> lists:foldl(fun committee_transaction/2, {[], []}, Transactions);
        error              -> {[], []}
    end;
committee_delta(_) ->
    {[], []}.

committee_transaction(#transaction{diff = Diff}, Acc) ->
    case proper_list(Diff) of
        true  -> lists:foldl(fun committee_op/2, Acc, Diff);
        false -> Acc
    end.

committee_op({assert,  {{peer_admitted, _Id, _H, _P, Pk}, _B}}, {A, R}) -> {addq(Pk, A), R -- [Pk]};
committee_op({retract, {{peer_admitted, _Id, _H, _P, Pk}, _B}}, {A, R}) -> {A -- [Pk], addq(Pk, R)};
committee_op(_Op, Acc)                                                  -> Acc.

%% The dial hints carried by one committed payload: each `peer_admitted` ASSERT's `{Pk, {Host, Port}}`.
%% Kept separate from the pure pubkey-set fold consumed by catch-up induction and live membership.
%% Retracts yield nothing: a removal is a membership change, not a reachability change (no unlearn — a
%% removed member stays a gossiped-with observer). The `_ -> []` clause is REQUIRED, not defensive: a
%% catch-up window routinely carries `noop` skip entries, and this walks raw window payloads.
admitted_endpoints({batch, _} = Batch) ->
    case quod_ledger:payload(Batch) of
        {ok, Transactions} -> lists:flatmap(fun transaction_endpoints/1, Transactions);
        error              -> []
    end;
admitted_endpoints(_) ->
    [].

transaction_endpoints(#transaction{diff = Diff}) ->
    case proper_list(Diff) of
        true  -> [{Pk, {H, P}} || {assert, {{peer_admitted, _Id, H, P, Pk}, _B}} <- Diff];
        false -> []
    end.

proper_list([_ | Rest]) -> proper_list(Rest);
proper_list([])         -> true;
proper_list(_)          -> false.

%% Apply a committed payload's committee delta onto a validator set — sorted (deterministic, every node
%% agrees byte-for-byte) and idempotent (a re-asserted member is a no-op).
apply_committee_delta(Change, V) ->
    {Adds, Removes} = committee_delta(Change),
    lists:usort(lists:foldl(fun addq/2, V, Adds) -- Removes).

addq(M, L) -> case lists:member(M, L) of true -> L; false -> L ++ [M] end.   %% idempotent add

-doc """
The **active voting set** for consensus right now — the set that signs/verifies shares, forms quorums,
selects leaders, and receives consensus dissemination. Held deliberately separate from the committee
**FACTS** (`#s.validators`, the `peer_admitted` projection that changes at EVERY commit): this is the
**epoch projection** of the committee.

Today epoch length is **1** (every slot is an epoch boundary), so the active set is exactly the current
facts — this is the **IDENTITY** over `#s.validators`. It exists as the single seam where epoch-frozen
validators will land (simplex-extended step 1; `doc/deferred.md` §3): every "who votes / leads /
disseminates now" read routes through here, every "derive / report / floor-check the facts" read stays on
`#s.validators`. It is a **landing pad**, not the feature — turning on real epochs still adds an epoch
snapshot field + boundary detection and rewrites this body to return the set frozen at the epoch's start;
what the seam buys is that those read sites don't have to be hunted down and converted then.
""".
-spec active_validators(#s{}) -> [node_id()].
active_validators(#s{validators = V}) -> V.

%% Config validation: `node_id` is required; `committee` must be a list — `[]` = self-only (N=1), a
%% list of co-founders = a multi-validator committee (the founding validator set is frozen from it);
%% `mode` must be create|join, and a `join` node MUST carry the out-of-band `genesis_hash` anchor.
valid_cfg(Config, Cfg) ->
    case maps:get(node_id, Config, undefined) of
        undefined -> {error, missing_node_id};
        _         -> valid_committee(Cfg)
    end.

valid_committee(Cfg) ->
    case maps:get(committee, Cfg) of
        L ->
            case proper_list(L) andalso lists:all(fun valid_member/1, L) of
                true  -> valid_mode(Cfg);
                false -> {error, {bad_committee, L}}   %% a malformed element ⇒ fail-fast
            end
    end.

%% `join` without a genesis-hash anchor would boot unfounded and never be able to verify what it catches up —
%% fail fast at config time rather than run a silent zombie that reports healthy. A mistyped `mode` must not
%% fall through to `create` and silently found a divergent genesis.
valid_mode(Cfg) ->
    case maps:get(mode, Cfg) of
        create -> ok;
        join   -> case maps:get(genesis_hash, Cfg) of
                      H when is_binary(H) -> ok;
                      _                   -> {error, join_requires_genesis_hash}
                  end;
        Other  -> {error, {bad_mode, Other}}
    end.

%% A committee element is a bare pubkey or a `{Pubkey, Host, Port}` tuple — checked here so `founding/2`'s
%% `normalize_member/1` never function_clause-crashes `init` on a bad config.
valid_member(Pk)                when is_binary(Pk)   -> true;
valid_member({Pk, _Host, _Port}) when is_binary(Pk)  -> true;
valid_member(_)                                      -> false.

data_dir(Cfg) -> quod_ledger_store:data_dir(Cfg).

genesis_file(Cfg) ->
    case maps:get(genesis_file, Cfg, undefined) of
        undefined -> none;
        <<>>      -> none;
        ""        -> none;
        File      -> File
    end.

status_map(S) ->
    Role = case is_participant(S) of true -> validator; false -> observer end,
    {_ProgressSlot, ProgressPhase, ProgressQuorum} = progress_status(S#s.head_progress),
    ProposalSlot = S#s.approved + 1,
    #{role => Role, committee => S#s.validators, slot => S#s.slot,
      committed => S#s.slot, approved => S#s.approved, last_applied => S#s.last_applied,
      syncing => syncing(S), recovery => recovery_phase(S#s.sync),
      finality_slot => S#s.slot + 1,
      progress_phase => ProgressPhase, progress_quorum_ready => ProgressQuorum,
      proposal_slot => ProposalSlot,
      proposal_open => case proposal_slot(S) of {ok, ProposalSlot} -> true; _ -> false end}.

progress_status(idle) -> {0, idle, false};
progress_status(#head_progress{slot = Slot, phase = Phase,
                               quorum_ready = Ready}) ->
    {Slot, Phase, Ready}.

progress_phase_number(idle) -> 0;
progress_phase_number(awaiting_proposal) -> 1;
progress_phase_number(awaiting_notarization) -> 2;
progress_phase_number(awaiting_commit) -> 3.

recovery_phase({pulling, _}) -> pulling;
recovery_phase(Phase) -> Phase.

stats_map(S) ->
    {ProgressSlot, ProgressPhase, ProgressQuorum} = progress_status(S#s.head_progress),
    #{slot => S#s.slot, committed => S#s.slot, approved => S#s.approved,
      pipeline_gap => max(0, S#s.approved - S#s.slot), last_applied => S#s.last_applied,
      committee_size => length(S#s.validators), appends => S#s.appends,
      proposals => S#s.proposals, batched_txs => S#s.batched_txs,
      commits => S#s.commits, prolog_ready => S#s.prolog_ready,
      submitted => S#s.submitted, skips => S#s.skips, pending => pending_count(S),
      requested_slot => case S#s.requested_slot of none -> 0; Requested -> Requested end,
      r_busy => S#s.r_busy, r_redirect => S#s.r_redirect, r_bad => S#s.r_bad,
      r_stale => S#s.r_stale,
      ingress_queued => S#s.ingress_count,
      ingress_overflow => S#s.ingress_overflow,
      ingress_expired => S#s.ingress_expired,
      ingress_forwarded => S#s.ingress_forwarded,
      ingress_prepositioned => S#s.ingress_prepositioned,
      membership_rejects => S#s.membership_rejects, redrives => S#s.redrives,
      progress_slot => ProgressSlot,
      progress_phase_code => progress_phase_number(ProgressPhase),
      progress_quorum_ready => case ProgressQuorum of true -> 1; false -> 0 end,
      progress_timeouts => S#s.progress_timeouts, quorum_pauses => S#s.quorum_pauses,
      head_complaint_signed => head_complaint_signed(S),
      head_support_votes => head_vote_count(support, S),
      head_commit_votes => head_vote_count(commit, S),
      head_complaint_votes => head_vote_count(complaint, S),
      missing_certified_blocks => missing_certified_block_count(S),
      weak_cert_waits => S#s.weak_cert_waits,
      ahead_gap => max(0, ahead_cert_ceiling(S#s.eng) - S#s.slot),
      syncing => case syncing(S) of true -> 1; false -> 0 end,
      is_validator => case is_participant(S) of true -> 1; false -> 0 end}.

head_complaint_signed(#s{slot = Committed} = S) ->
    case round_complained(round_state(Committed + 1, S)) of
        true -> 1;
        false -> 0
    end.

head_vote_count(_Kind, #s{eng = undefined}) -> 0;
head_vote_count(Kind, #s{slot = Committed,
                         eng = #eng{shares = Shares, certs = Certs}}) ->
    Head = Committed + 1,
    ShareCounts = [map_size(Bucket)
                   || {{VoteKind, Slot, _BH}, Bucket} <- maps:to_list(Shares),
                      VoteKind =:= Kind, Slot =:= Head],
    CertCounts = [length(Sigs)
                  || {{VoteKind, Slot, _BH}, #cert{sigs = Sigs}} <- maps:to_list(Certs),
                     VoteKind =:= Kind, Slot =:= Head],
    lists:max(ShareCounts ++ CertCounts ++ [0]).

missing_certified_block_count(#s{eng = undefined}) -> 0;
missing_certified_block_count(#s{slot = Committed, eng = Eng}) ->
    length([ok
            || {{support, Slot, BH}, #cert{}} <- maps:to_list(Eng#eng.certs),
               live_pipeline_slot(Slot, Committed),
               block_for(BH, Eng) =:= undefined]).

pending_count(#s{collecting = Collecting, local_proposals = Local}) ->
    CollectingN = case Collecting of #batch{items_rev = Items} -> length(Items); none -> 0 end,
    CollectingN + lists:sum([length(P#local_proposal.waiters) || P <- maps:values(Local)]).
