-module(quod_simplex).
-moduledoc """
Per-namespace **DispersedSimplex** Byzantine consensus — quod's ordering layer,
replacing the earlier hand-rolled Raft ledger. One consensus instance per
namespace; the committee (validator set) is the set of **`peer_admitted` FACTS**,
derived from the committed log — asserted in the genesis block at bootstrap, then
changed by committed transactions whose diff asserts/retracts `peer_admitted`
(adopted live, in-process, at the slot boundary). The KB (`quod_prolog`) is the
other projection of the same log; the two never drift. Slot 1 also carries a
fresh queryable `consensus_incarnation/1` fact, making every re-founding a new
consensus signature domain. See the approved plan and
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
verified against both the validator set and a locally derived namespace/genesis domain — which is exactly
the P2 relayed-commit proof a subscriber checks without accepting cross-ontology evidence.

The runtime keeps two frontiers: **approved** (support-certified, safe to extend) and
**committed** (durable and externally visible). Leaders micro-batch ordered transactions
into one block and may build one child over an uncommitted approved parent. A child commit also
finalizes its approved parent; catch-up persists and verifies that implicit proof. Committee
transactions are singleton barriers, so a voting-set change is explicitly committed before
the next proposal opens.

Ingress names the first slot a request can still enter and sends that slot with the signed
submission to its deterministic proposer. The receiver may collect or park the request only
for that exact slot; it never reinterprets the author's intent from a different local
frontier. The origin retains each ordinary signed submission until its own durable log
proves inclusion or exclusion. Exclusion places the same signed bytes at the next earliest
usable proposer without a public retry; membership changes retain their terminal re-proof
contract. While an exact-slot lane remains open, later local changes share it, preserving
author-sequence order.
Temporarily blocked changes wait in a bounded queue whose drain may pass one blocked author
to keep others moving. Membership changes remain a global barrier so sustained writes
cannot starve a committee transition. `{error, busy}` means queue overflow or TTL expiry,
not routine backpressure.
A relay destination acknowledges once it holds the request: the sender then replaces its
300 ms lost-send retry with a slow result-hint probe. Only the origin's durable
log resolves inclusion or exclusion.

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
-include("quod_ingress_limits.hrl").

-define(MAX_SLOT, 16#FFFFFFFFFFFFFFFF).   %% share_bytes/4 signs slots as unsigned 64-bit integers
-define(PIPELINE_DEPTH, 1).               %% at most one approved parent may remain uncommitted
-define(SHARE_DOMAIN_VERSION, 1).
-define(SHARE_DOMAIN_TAG, <<"quod/simplex/domain">>).
-define(SHARE_MESSAGE_TAG, <<"quod/simplex/share">>).
-define(GENESIS_TX_VERSION, 1).
-define(GENESIS_TX_TAG, "quod/genesis").

-behaviour(gen_statem).

%% Pure consensus core (also used by the gen_statem below, the catch-up verifier, and the tests).
-export([quorum/1, leader/2,
         block_hash/1, block_from_entry/1, consensus_domain/2, share_bytes/4,
         make_share/5, verify_share/2,
         verify_cert/3,
         may_commit/2, may_complain/2, well_formed_block/1,
         valid_history_entry/4,
         committee_delta/1, apply_committee_delta/2]).   %% committee = projection of peer_admitted facts

%% Per-namespace consensus process — API + gen_statem callbacks.
-export([start_link/2, append/2, rebuild/1, status/1, committee/1, genesis_hash/1, stats/1, namespaces/0]).
-export([init/1, callback_mode/0, running/3, terminate/3]).

-ifdef(TEST).
%% consensus-engine surface driven by eunit (the #eng record is otherwise private)
-export([form_cert/6,
         eng_new/3, eng_offer/2, eng_prune/2, eng_tree/1, eng_committed/1, ts_acceptable/3,
         prune_dials/2, membership_change_ok/2, change_acceptable/2, complaint_amplified/3,
         admitted_endpoints/1, persisted_cert/4, eng_evict_final/4, eng_set_validators/2,
         ahead_cert_ceiling/1, eng_with_certs/2, eng_buffered_commit/4,
         eng_pool_sizes/1, eng_retained_block/2,
                                                     %% Slice 1: the gap detector's pure core
         is_participant/1, may_vote/1, caught_up/1, should_sync/1, syncing/1, confirm_live/1,
         initial_sync/1, tip_quorum/3, pace_tick/1, arm_ready/1, backoff/1,
         recovery_failed/1, may_sink/2, reset_pace/0, approve_block/2, finalize/2,
         catchup_origin/1,
         test_state/1, test_arm/1, test_sync/1,
         restore_vote_rounds/1,
         proposal_slot/1, acceptable_payload/2, needs_hint_warm/2,
         reconcile_head_progress/1, resume_ready_rounds/1,
         on_progress_timeout/2, progress_timer_actions/2, watch_requested/2,
         settle_readiness/2, prune_consensus_links/1,
         dispatch/3, reconcile_block_requests/1,
         test_progress/1, test_progress_rearms/1, test_support_grace/1,
         test_round/2, test_requested/1,
         test_progress_counts/1, test_committed_store/1, test_link_peers/1,
         test_retired_inbound/1,
         test_relay_link_peers/1, test_relay_chan/1,
         test_prune_relay_links/1,
         test_invalidate_relay_generation/2,
         test_close_relay_transport/1,
         test_relay_transport_counts/1,
         test_redrive_head/3, test_block_requests/1, test_vote_journal/1,
         test_append/3, test_relayed_append/3, test_relayed_append/4,
         test_relay_origin/4,
         test_ingress/1, test_ingress_view_source/1,
         test_batch/1, test_drain/1,
         test_expire_ingress/1, test_state_set/3, test_relay_pending/1,
         test_relay_pending_detail/1, test_relay_result/4,
         test_relay_accepted/3, test_dispatch_relay/3,
         test_put_pending_relay/3, test_copy_relay_pending/2,
         test_relay_custody/4,
         test_remove_pending_relay/2,
         test_relay_state_keys/1, test_relay_result_entries/1,
         test_expire_relay_results/1, test_redrive_relays/1,
         test_reply_relay/7,
         test_custody/1, test_drain_custody/1,
         test_keep_progress_transition/2,
         test_expire_custody/1,
         test_outbox/1,
         test_ingress_needs_drain/2,
         test_round_probe/1, test_route/4,
         proposal_visible/2, reseat_engine/2,
         committee_view_id/4, test_committee_id/1,
         test_log_projection/3,
         test_apply_catchup_window/3,
         stats_map/1, encode/2]).   %% encode/2: the `{log, Ns}` wire frame — used by simplex_SUITE to inject a crafted propose
-endif.

%% These validate records decoded from UNTRUSTED peer input (binary_to_term yields any term, so a
%% typed record can still carry malformed fields at runtime). Dialyzer trusts the declared field types
%% and consequently marks their reject branches unreachable; weakening the canonical record types would
%% hide useful mistakes everywhere else.
-dialyzer({nowarn_function, [dispatch/3, well_formed_block/1, well_formed_share/1,
                             valid_read_check/1, valid_diff/1, committee_transaction/2,
                             transaction_endpoints/1, proper_list/1,
                             change_acceptable/2]}).

%% A node's SIGNING identity: the subset of `t:quod_identity:identity/0` consensus needs (pubkey +
%% private key), without the TLS cert. `make_share/5` signs with `key`; the share's signer is `pubkey`.
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
Derive the fixed-size signature domain for one consensus chain. It binds both the
ontology namespace and its pinned genesis block, so a vote from another ontology
or from a chain with a different anchored genesis cannot verify here.
""".
-spec consensus_domain(binary(), binary()) -> <<_:256>>.
consensus_domain(Ns, GenesisHash)
  when is_binary(Ns), byte_size(Ns) > 0,
       is_binary(GenesisHash), byte_size(GenesisHash) =:= 32 ->
    crypto:hash(
      sha256,
      <<?SHARE_DOMAIN_TAG/binary, 0, ?SHARE_DOMAIN_VERSION:8,
        (byte_size(Ns)):32, Ns/binary, GenesisHash/binary>>).

-doc """
The canonical bytes a share signs: a versioned protocol tag, the 32-byte
namespace/genesis consensus domain, a one-byte vote-kind tag (so a `support`
signature cannot be replayed as a `commit` or `complaint`), the slot, and the
bound block hash (empty for a slot-only `complaint`).
""".
-spec share_bytes(<<_:256>>, support | commit | complaint, slot(), binary() | none) -> binary().
share_bytes(Domain, Kind, Slot, BlockHash)
  when is_binary(Domain), byte_size(Domain) =:= 32,
       is_integer(Slot), Slot >= 0, Slot =< ?MAX_SLOT ->
    BH = case BlockHash of none -> <<>>; H when is_binary(H) -> H end,
    <<?SHARE_MESSAGE_TAG/binary, 0, ?SHARE_DOMAIN_VERSION:8,
      Domain/binary, (tag(Kind)):8, Slot:64, BH/binary>>.

tag(support)   -> $S;
tag(commit)    -> $C;
tag(complaint) -> $X.

%%%===================================================================
%%% shares
%%%===================================================================

-doc "Build and Ed25519-sign one domain-bound share of `Kind` for `Slot`/`BlockHash`.".
-spec make_share(<<_:256>>, support | commit | complaint, slot(),
                 binary() | none, signer()) -> #share{}.
make_share(Domain, Kind, Slot, BlockHash, #{pubkey := Pub, key := Key}) ->
    Sig = quod_identity:sign(share_bytes(Domain, Kind, Slot, BlockHash), Key),
    #share{kind = Kind, slot = Slot, block_hash = BlockHash, signer = Pub, sig = Sig}.

-doc """
Is a share well-formed AND its Ed25519 signature valid for its own signer? Well-formed = the right
`block_hash` shape for its kind (a 32-byte hash for `support`/`commit`, `none` for `complaint`) — so a
malformed share (e.g. a complaint carrying a hash, or a support with a bogus-length hash) is rejected
before it can be aggregated. (Set-membership is checked separately, in the cert functions.)
""".
-spec verify_share(<<_:256>>, #share{}) -> boolean().
verify_share(Domain, #share{kind = K, slot = Sl, block_hash = BH,
                            signer = Signer, sig = Sig}) ->
    is_slot(Sl)
        andalso valid_signer_signature(Signer, Sig)
        andalso valid_shape(K, BH)
        andalso quod_identity:verify(
                  Sig, share_bytes(Domain, K, Sl, BH), Signer).

%% A share/cert is well-formed iff its block_hash matches its kind: a 32-byte block hash binds a
%% support/commit; a complaint is slot-only (`none`). Guards the trustless path against malformed input.
valid_shape(complaint, none) -> true;
valid_shape(K, BH) when (K =:= support orelse K =:= commit),
                        is_binary(BH), byte_size(BH) =:= 32 -> true;
valid_shape(_K, _BH) -> false.

%%%===================================================================
%%% certificates
%%%===================================================================

-ifdef(TEST).
-doc """
Form a certificate from a pool of shares: keep the shares of the SAME `(Kind, Slot, BlockHash)` that
are from **distinct validators in the set** and whose signatures verify; if that reaches `quorum(N)`,
return `{ok, #cert{}}`, else `{error, insufficient}`. A Byzantine node's duplicate/extra shares can't
inflate the count — signers are deduplicated.
""".
-spec form_cert(<<_:256>>, support | commit | complaint, slot(),
                binary() | none, [#share{}], [node_id()]) ->
          {ok, #cert{}} | {error, insufficient}.
form_cert(_Domain, _Kind, _Slot, _BlockHash, _Shares, []) ->
    {error, insufficient};                       %% no validators yet ⇒ no quorum (never quorum(0))
form_cert(Domain, Kind, Slot, BlockHash, Shares, Validators) ->
    case is_slot(Slot) andalso valid_shape(Kind, BlockHash) of
        false -> {error, insufficient};          %% malformed (kind/block_hash mismatch)
        true  ->
            Msg  = share_bytes(Domain, Kind, Slot, BlockHash),
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
-endif.

-doc """
Verify a certificate independently against a trusted local consensus domain and known validator set: it
carries `≥ quorum(N)` signatures from **distinct** set members that all verify over the certificate's
`(domain, kind, slot, block_hash)`. This
is the trustless check — a subscriber/relay-receiver validates a committed block by its commit cert
without trusting whoever handed it over.
""".
-spec verify_cert(<<_:256>>, #cert{}, [node_id()]) -> boolean().
%% Reject before any signature work: an empty set has no quorum (never quorum(0)); and a legitimate
%% cert never carries MORE than |Validators| signatures — capping the length first stops a hostile
%% relay from forcing thousands of Ed25519 verifications (a CPU-amplification DoS on the trustless path).
verify_cert(Domain, #cert{} = Cert, Validators) ->
    case sanitize_cert(Domain, Cert, Validators) of
        {ok, _Clean} -> true;
        error        -> false
    end.

%% A certificate can carry at most one signature per validator. This bounded recursive check both
%% rejects improper tails before any list BIF can raise and caps hostile crypto work before verification.
bounded_signatures([], _Remaining) -> true;
bounded_signatures([{Signer, Sig} | Rest], Remaining) when Remaining > 0 ->
    valid_signer_signature(Signer, Sig) andalso bounded_signatures(Rest, Remaining - 1);
bounded_signatures(_MalformedOrTooLong, _Remaining) -> false.

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
%% fragment decode (that is Stage 4). The pool's distinct-signer `⅔` check uses the
%% same domain-bound signature encoding as the public certificate API.
%%
%% Events: `{broadcast, Cert}` (a cert we just formed or first learned — re-disseminate),
%% `{notarized, Block}` (a block joined the tree), `{committed, Slot, Block}` (a block is final → apply).

-record(eng, {domain       :: <<_:256>>,
              validators   :: [node_id()],
              base     = 0   :: slot(),                                %% durable committed floor: slots =<
                                                                       %% base are final (in the store) and
                                                                       %% pruned from the maps below; a
                                                                       %% commit advances it (eng_prune/2)
              blocks   = #{} :: #{binary() => #block{}},               %% at most one retained block per live slot
              block_slots = #{} :: #{slot() => binary()},              %% slot => the retained block hash
              shares   = #{} :: #{share_key() => #{node_id() => #share{}}},
              seen_votes = #{} :: #{{support | commit | complaint,
                                      slot(), node_id()} => binary() | none},
                                                                       %% first valid hash per signer/kind/slot
              certs    = #{} :: #{share_key() => #cert{}},
              tree     = #{} :: #{slot() => #block{}},                 %% notarized blocks (in-flight window)
              tree_hashes = #{} :: #{slot() => binary()},              %% slot => verified key in `blocks`
              committed = #{} :: #{slot() => #block{}},                %% committed (final) in-flight blocks
              skipped  = #{} :: #{slot() => true},                     %% slots a complaint cert has skipped
              ahead_finalizer = 0 :: slot()}).                          %% highest verified commit/complaint
                                                                        %% beyond the retained depth-one window;
                                                                        %% O(1) recovery evidence, never a pool item

-type share_key() :: {support | commit | complaint, slot(), binary() | none}.
-type eng_event() :: {broadcast, #cert{}} | {notarized, #block{}}
                   | {committed, slot(), #block{}} | {skipped, slot()}.

-doc """
A fresh engine for one namespace/genesis signature `Domain` and validator set
(the active voting set — `active_validators/1`; at epoch length 1 that is the
current committee), with `Base` = the durable committed floor. Blocks `=< Base`
are treated as committed history so a new proposal's parent resolves without
the engine holding the whole chain.
""".
-spec eng_new(<<_:256>>, [node_id()], slot()) -> #eng{}.
eng_new(Domain, Validators, Base)
  when is_binary(Domain), byte_size(Domain) =:= 32 ->
    #eng{domain = Domain, validators = Validators, base = Base}.

%% Swap the engine's voting set to the ACTIVE validator set (`active_validators/1`) when `adopt_committee/2`
%% crosses a boundary. Today (epoch length 1) the active set IS the committee facts, so this fires on every
%% committee-changing commit; under real epochs it fires only at an epoch boundary, and a mid-epoch facts
%% change leaves the engine's set untouched. Retained share buckets are projected onto the new set when
%% forming a certificate, and existing certificates must pass `persisted_cert/4` against it before durable
%% use. The signature-free far-finalizer hint cannot be revalidated, so it is cleared here.
eng_set_validators(Validators, Eng) ->
    %% A far-finalizer hint was verified only against the former set and carries
    %% no retained signatures with which to revalidate it. A committee boundary
    %% therefore invalidates that hint; fresh traffic can establish a new one.
    Eng#eng{validators = Validators, ahead_finalizer = Eng#eng.base}.

%% The certificate to PERSIST on a finalized `#entry`, captured before `finalize`→`eng_prune` drops it from
%% the pool. NOT the raw pool cert: we re-minimise it to the distinct VALID signatures of the committee
%% AS-OF-this-slot (`eng.validators`, already swapped to the post-slot-N-1 set) — so (a) a peer's padded /
%% relayed junk signatures can never bake into the append-only log (only ≤ N genuine committee sigs remain),
%% and (b) the persisted cert verifies against the committee a catch-up joiner reconstructs for this slot.
%% `none` only if the pool cert lacks a quorum under the current set — a lagging node that finalized under a
%% STALE committee (the mid-flight committee-change hazard; see doc/deferred.md §3).
persisted_cert(Kind, Slot, BH, #eng{certs = Certs, validators = Vs}) ->
    case {Vs, maps:get({Kind, Slot, BH}, Certs, none)} of
        {[], _} ->
            none;
        {_, none} ->
            none;
        {_, #cert{sigs = S}} ->
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
eng_offer({block, #block{slot = Sl}}, #eng{base = Base} = Eng)
  when Sl =< Base; Sl > Base + ?PIPELINE_DEPTH + 1 -> {Eng, []};
eng_offer({share, #share{slot = Sl}}, #eng{base = Base} = Eng)
  when Sl =< Base; Sl > Base + ?PIPELINE_DEPTH + 1 -> {Eng, []};
eng_offer({cert, #cert{slot = Sl}}, #eng{base = Base} = Eng) when Sl =< Base ->
    {Eng, []};
%% A finalizer beyond the volatile depth-one window is useful only as proof that
%% this node is behind. Verify it once when it raises the ceiling, retain only
%% that scalar, and let recovery fetch the contiguous history. Blocks, shares,
%% and support certs beyond the window carry no such finality signal and are
%% dropped by the adjacent clauses without allocating engine state.
eng_offer({cert, #cert{kind = Kind, slot = Sl} = Cert},
          Eng = #eng{base = Base, ahead_finalizer = Ahead})
  when Sl > Base + ?PIPELINE_DEPTH + 1,
       (Kind =:= commit orelse Kind =:= complaint) ->
    case Sl =< Ahead of
        true ->
            {Eng, []};
        false ->
            case sanitize_cert(Eng#eng.domain, Cert, Eng#eng.validators) of
                {ok, _Clean} -> {Eng#eng{ahead_finalizer = Sl}, []};
                error        -> {Eng, []}
            end
    end;
eng_offer({cert, #cert{slot = Sl}}, #eng{base = Base} = Eng)
  when Sl > Base + ?PIPELINE_DEPTH + 1 -> {Eng, []};
eng_offer({block, #block{} = B}, Eng) ->
    eng_offer_hashed(block_hash(B), B, Eng);
eng_offer({share, #share{kind = K, slot = Sl, block_hash = BH,
                         signer = Signer} = Sh},
          Eng = #eng{domain = Domain}) ->
    Key = {K, Sl, BH},
    Bucket = maps:get(Key, Eng#eng.shares, #{}),
    VoteKey = {K, Sl, Signer},
    %% Reject outsiders before Ed25519 work. A duplicate is already trusted in the bucket, so do not verify
    %% it again; it can still trigger re-formation after `weak_cert_wait` evicted a stale old-committee cert.
    %% The first verified hash per signer/kind/slot wins. Without that O(N)-bounded latch, one Byzantine
    %% validator could sign arbitrarily many hashes and create an unbounded number of live share buckets.
    case lists:member(Signer, Eng#eng.validators) of
        false -> {Eng, []};
        true  ->
            case maps:get(VoteKey, Eng#eng.seen_votes, undefined) of
                BH ->
                    maybe_form_bucket_cert(K, Sl, BH, Bucket, Eng);
                undefined ->
                    case verify_share(Domain, Sh) of
                        true  -> ingest_share(Sh, Bucket, Eng);
                        false -> {Eng, []}
                    end;
                _ConflictingHash ->
                    {Eng, []}
            end
    end;
eng_offer({cert, #cert{} = C}, Eng = #eng{domain = Domain}) ->
    Key = cert_key(C),
    case maps:is_key(Key, Eng#eng.certs) of
        true -> {Eng, []};
        false ->
            case sanitize_cert(Domain, C, Eng#eng.validators) of
                error -> settle(Eng);
                {ok, Clean} ->
                    {Eng1, Evs} = settle(Eng#eng{certs = (Eng#eng.certs)#{Key => Clean}}),
                    {Eng1, [{broadcast, Clean} | Evs]}   %% relay a newly-learned cert once (§2.3.1)
            end
    end.

%% The state-machine driver already computed the proposal hash for signing. Keep that trusted fast path
%% private; external users of the pure engine enter through `eng_offer({block,B}, ...)`, which derives it.
eng_offer_hashed(_BH, #block{slot = Sl}, #eng{base = Base} = Eng)
  when Sl =< Base; Sl > Base + ?PIPELINE_DEPTH + 1 -> {Eng, []};
eng_offer_hashed(BH, #block{slot = Sl} = B,
                 Eng = #eng{blocks = Blocks, block_slots = Slots,
                            tree = Tree}) ->
    case maps:get(Sl, Slots, undefined) of
        undefined ->
            settle(Eng#eng{blocks = Blocks#{BH => B},
                           block_slots = Slots#{Sl => BH}});
        BH ->
            settle(Eng);
        OldBH ->
            %% Ordinary leader traffic is first-block-wins, bounding equivocation
            %% state to one block per live slot. A later quorum-certified block may
            %% replace an unnotarized first copy: certified-block recovery always
            %% ingests and verifies its support cert before offering the payload.
            %% If the old block is already in the tree, accepting a second support
            %% path would require the quorum-intersection safety assumption to have
            %% failed, so keep the existing notarized value.
            case not maps:is_key(Sl, Tree)
                 andalso not maps:is_key(Sl, Eng#eng.committed)
                 andalso not maps:is_key(Sl, Eng#eng.skipped)
                 andalso persisted_cert(support, Sl, BH, Eng) =/= none of
                true ->
                    settle(Eng#eng{blocks = (maps:remove(OldBH, Blocks))#{BH => B},
                                   block_slots = Slots#{Sl => BH}});
                false ->
                    {Eng, []}
            end
    end.

%% Add a verified share to its (kind, slot, block) bucket; if that reaches the `⅔` quorum for the first
%% time, form the cert and re-disseminate it, then settle the tree/commits.
ingest_share(#share{kind = K, slot = Sl, block_hash = BH, signer = Signer} = Sh, Bucket, Eng) ->
    Key    = {K, Sl, BH},
    Bucket1 = Bucket#{Signer => Sh},
    Seen1 = (Eng#eng.seen_votes)#{{K, Sl, Signer} => BH},
    Eng1   = Eng#eng{shares = (Eng#eng.shares)#{Key => Bucket1},
                     seen_votes = Seen1},
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

sanitize_cert(Domain,
              #cert{kind = K, slot = Sl, block_hash = BH, sigs = Sigs} = C,
              Validators) ->
    N = length(Validators),
    case N > 0 andalso is_slot(Sl) andalso valid_shape(K, BH)
         andalso bounded_signatures(Sigs, N) of
        false -> error;
        true  ->
            Valid = distinct_valid(
                      Sigs, share_bytes(Domain, K, Sl, BH), Validators),
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
            block_slots = maps:filter(fun(Sl, _BH) -> Above(Sl) end, Eng#eng.block_slots),
            shares    = maps:filter(fun({_K, Sl, _BH}, _) -> Above(Sl) end, Eng#eng.shares),
            seen_votes = maps:filter(fun({_K, Sl, _Signer}, _BH) -> Above(Sl) end,
                                     Eng#eng.seen_votes),
            certs     = maps:filter(fun({_K, Sl, _BH}, _) -> Above(Sl) end, Eng#eng.certs),
            tree      = maps:filter(fun(Sl, _) -> Above(Sl) end, Eng#eng.tree),
            tree_hashes = maps:filter(fun(Sl, _) -> Above(Sl) end, Eng#eng.tree_hashes),
            committed = maps:filter(fun(Sl, _) -> Above(Sl) end, Eng#eng.committed),
            skipped   = maps:filter(fun(Sl, _) -> Above(Sl) end, Eng#eng.skipped),
            ahead_finalizer =
                case Eng#eng.ahead_finalizer > Committed of
                    true  -> Eng#eng.ahead_finalizer;
                    false -> max(Committed, Base)
                end}.

-doc """
The deterministic leader (proposer) for a slot: **round-robin** over the sorted validator set,
`sort(V)[(Slot-1) rem N]`. Every node computes the same leader for a given slot from the same frozen
set. `quod_ingress_state:route/5` binds each relay to the earliest usable slot, while
a complaint-skip of slot `v` moves slot `v+1` to a *different* leader: that rotation is the failover.
`Slot ≥ 1` (genesis is 0). Stable per-epoch leaders (keeping one leader for K slots) remain
deliberately unused because a dead tenured leader would cost K complaint rounds instead of one.
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
eng_pool_sizes(#eng{blocks = Blocks, shares = Shares, seen_votes = Seen,
                    certs = Certs}) ->
    #{blocks => map_size(Blocks), share_buckets => map_size(Shares),
      seen_votes => map_size(Seen), certs => map_size(Certs)}.
eng_retained_block(Slot, Eng = #eng{block_slots = Slots}) ->
    case maps:get(Slot, Slots, undefined) of
        undefined -> undefined;
        BH -> block_for(BH, Eng)
    end.
%% Build a minimal test engine with selected cert keys planted without
%% verification. Pure gate/state fixtures use it when certificate presence,
%% rather than cryptographic formation, is the condition under test.
eng_with_certs(Base, KindSlots) ->
    Certs = maps:from_list([{{K, Sl, <<>>}, #cert{kind = K, slot = Sl, block_hash = <<>>, sigs = []}}
                            || {K, Sl} <- KindSlots]),
    #eng{domain = <<0:256>>, validators = [], base = Base, certs = Certs}.

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
          committee    => [],          %% complete founding set besides self; only its smallest key may create
          genesis_file => undefined,   %% root .pl to seed on create (founder only)
          genesis_terms => undefined,  %% in-memory ontology terms to seed on create (mutually exclusive)
          genesis_hash => undefined,   %% join config pin; resolved to the immutable slot-1 anchor in every mode
          batch_window_ms => 25,        %% per-ontology micro-batch collection window
          data_dir     => undefined}).

-define(MAX_OUTBOX, 1024).   %% per-peer cap on frames buffered while a link opens (bounds memory vs a dead peer)
-define(TICK_MS,     300).   %% consensus re-drive cadence: re-dial peers whose link never came up (liveness)
-define(DIAL_TIMEOUT_MS, 15000).  %% presume a dial lost if neither link_up nor link_error arrives within this
-define(LINK_CLOSE_TIMEOUT_MS, 500). %% graceful incarnation boundary; ordered sends may retry for 250 ms
                                  %% long, and sweep its marker so the tick re-dials (guards a conn that dies
                                  %% mid-handshake); safely exceeds the worst-case legit dial (connect ~5s +
                                  %% link-ack ~5s, quod_conn), so an in-flight dial is never swept early
-define(DELTA_MS,   1000).   %% oldest-head progress timeout: redrive or complain while waiting for proposal,
                             %% notarization, or commit; must exceed real commit latency.
                             %% Tested at 500ms after the local-disk migration (2026-07-24): it TRIPLED
                             %% skips (4.4->12.4/node) and blew up the tail (p90/p99 -> 10s), because
                             %% under a 40-tx burst the single-statem mailbox backs up and a healthy
                             %% round transiently exceeds 500ms, so Δ=500 spuriously skips it and the
                             %% skip->retry feeds the storm. A LOWER fixed Δ is the wrong lever; the tail
                             %% needs the burst-amplification fixes (deferred.md §3, "Latency tail").
                             %% Adaptive Δ (track live round p99) is the real follow-up.
                             %% Override via app-env `simplex_delta_ms`.
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
-define(RELAY_RETRY_MS, 300).                    %% retry until the destination acknowledges receipt
-define(RELAY_ACCEPTED_RETRY_MS, 5000).          %% after receipt, a slow status retry recovers a lost
                                                  %% result hint without flooding the consensus mailbox
-define(MAX_RELAY_PENDING, 2048).                 %% bound parked callers and redrive state
-define(MAX_CUSTODY, 2048).                       %% bound origin-owned signed submissions/callers
-define(MAX_CUSTODY_BYTES, (8 * ?MAX_BLOCK_BYTES)). %% independent retained-envelope byte bound
-define(INGRESS_TTL_MS, 7000).                    %% parked-item cutoff. One eligible slot may burn a full
                                                  %% quorum-flap complaint cycle
                                                  %% (Δ×(1+?MAX_QUORUM_REARMS) = 4s) before the skip lands;
                                                  %% flight time is negligible. 7s covers that worst legit
                                                  %% wait yet stays under the caller's 8s append timeout,
                                                  %% so a REAL stall still fails visibly (busy) while the
                                                  %% caller can still hear it — the queue never hides a wedge
-define(SIGNATURE_VERIFY_TIMEOUT_MS, 2000).       %% fail closed if a crypto worker wedges
-define(MAX_QUORUM_REARMS, 3).                    %% bound link-flap deadline extension per slot/phase
-define(READINESS_MS, 1000).                      %% readiness refresh; at or below the default Delta
-define(READINESS_FRESH_MS, 3000).                %% tolerate two missed refreshes, then fail closed
-define(BLOCK_REQUEST_RETRY_MS, 500).              %% rotate a missing certified block request to another holder

-type final_vote() :: none | {commit, binary()} | complaint.
-type final_vote_trigger() :: notarized | complaint_evidence | timeout | rejected.
-record(round, {supporting = none :: none | binary(),
                final = none :: final_vote(),
                invalid = none :: none | binary(),
                validating = none :: none | binary()}).

-record(batch, {slot :: slot(),
                parent :: slot(),
                items_rev = [] :: [{term(), #transaction{}}],
                count = 0 :: non_neg_integer(),
                bytes = 0 :: non_neg_integer(),
                tx_ids = #{} :: #{binary() => true},
                sequences = #{} :: #{{node_id(), pos_integer()} => true},
                sequence_floor = #{} :: #{node_id() => non_neg_integer()},
                opened_at = 0 :: integer()}).   %% monotonic ms; measures collection wait on this proposer

-record(waiter, {reply_to :: term(),
                 submission_id = undefined :: binary() | undefined,
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

-record(relay_ref, {peer :: node_id(),
                    submission_id :: binary(),
                    attempt_id :: binary(),
                    committee_id :: binary(),
                    target_slot :: slot()}).

-record(relay_pending, {from :: term(),
                        target :: node_id(),
                        target_slot :: slot(),
                        author_seq :: pos_integer(),
                        submission_id :: binary(),
                        attempt_id :: binary(),
                        committee_id :: binary(),
                        frame :: binary(),
                        deadline :: integer(),
                        next_retry :: integer(),
                        accepted = false :: boolean()}).

%% One origin-owned, signed ordinary submission. The signature and canonical
%% envelope never change; only the unsigned exact-slot placement does. Caller
%% ownership lives here across local collection, sealed proposals, and outbound
%% relay attempts. A destination relay never creates custody and can never
%% retarget.
-type custody_placement() ::
        ready
      | {local, slot(), binary()}
      | {relay, binary(), node_id(), slot(), binary()}.
-record(custody, {waiter :: #waiter{},
                  change :: #transaction{},
                  submission :: term(),
                  original_arrival :: integer(),
                  deadline :: integer(),
                  placement = ready :: custody_placement(),
                  attempts = 0 :: non_neg_integer(),
                  bytes :: pos_integer()}).

-record(s, {ns           :: binary(),
            consensus_domain :: <<_:256>> | undefined,
            self         :: node_id(),               %% our pubkey == node_id
            id           :: signer() | undefined,    %% signing identity (pubkey + private key)
            store        :: quod_ledger_store:handle() | undefined,
            vote_journal :: quod_vote_journal:handle() | memory | undefined,
            eng          :: #eng{} | undefined,      %% the consensus engine (certificate pool + block tree)
            chan         :: binary() | undefined,    %% term_to_binary({log, Ns}) — the transport channel
            relay_chan   :: binary() | undefined,    %% term_to_binary({ingress, Ns}) — relay-only stream
            validators   = [] :: [node_id()],        %% the committee FACTS — sorted `peer_admitted` pubkeys,
                                                     %% the KB projection re-derived from the committed log
                                                     %% (in-process). The ACTIVE voting set derives from this
                                                     %% via `active_validators/1` (identity at epoch length 1);
                                                     %% "who votes now" reads route through THAT, not this field.
            committee_id = undefined :: binary() | undefined,
                                                     %% hash identity of the exact membership-adoption block;
                                                     %% undefined only while the namespace has no founded view
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
            relay_conns = #{} :: #{node_id() => {pid(), reference()}},
            relay_inbound_conns = #{} :: #{node_id() => {pid(), reference()}},
            relay_dialing = #{} :: #{node_id() => integer()},
            retired_inbound = #{} :: #{pid() => reference()},
                                                     %% superseded inbound stream generations kept
                                                     %% monitored until DOWN so live stale frames
                                                     %% cannot re-adopt themselves
            relay_pending = #{} :: #{binary() => #relay_pending{}},
            relay_inflight = #{} :: #{binary() => #relay_ref{}},
            relay_results = #{} :: #{binary() =>
                                      {#relay_ref{}, term(), integer()}},
            custody = #{} :: #{binary() => #custody{}},
            custody_lane = empty
              :: empty | {node_id(), slot(), binary()},
            custody_ready = gb_sets:empty()
              :: gb_sets:set({pos_integer(), binary()}),
            custody_deadlines = gb_sets:empty()
              :: gb_sets:set({integer(), binary()}),
            custody_bytes = 0 :: non_neg_integer(),
            block_requests = #{} :: #{{slot(), binary()} =>
                                       {non_neg_integer(), integer()}},
                                                     %% certified block anti-entropy: attempt + next retry time
            %% Pure routing view + bounded park queue. Consensus-private facts
            %% are projected into this state; signing, I/O, replies, and batch
            %% effects remain in this process.
            ingress = quod_ingress_state:new()
              :: quod_ingress_state:state(),
            relay_timeout_ms = 31000 :: pos_integer(),
            batch_window_ms = 25 :: 0..1000,
            detailed_metrics = false :: boolean(),
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
            genesis_hash = undefined :: binary() | undefined,  %% pinned slot-1 block hash for every mode
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
            r_redirect = 0 :: non_neg_integer(),   %% append not-in-charge: unavailable, wrong proposer, or target closed
            r_bad      = 0 :: non_neg_integer(),    %% append rejected: unacceptable change
            r_stale    = 0 :: non_neg_integer(),    %% author sequence superseded (stale_seq — retryable,
                                                    %% NOT malformed; keeping it out of r_bad keeps the
                                                    %% "malformed workload" alarm honest)
            ingress_overflow  = 0 :: non_neg_integer(),  %% parks refused: queue item/byte/per-author bound hit
            ingress_expired   = 0 :: non_neg_integer(),  %% parked items cut by ?INGRESS_TTL_MS
            ingress_forwarded = 0 :: non_neg_integer(),  %% drained items routed onward after state moved
            ingress_retargets = 0 :: non_neg_integer(),  %% exact signed submissions placed again after local exclusion
            relay_accepted = 0 :: non_neg_integer(),     %% destinations that acknowledged holding a relay
            relay_redrives = 0 :: non_neg_integer(),     %% relay request retries (fast before ack, slow after)
            relay_duplicates = 0 :: non_neg_integer(),   %% duplicate submits received while already in flight
            round_probe = #{} :: #{slot() => {integer(), none | integer()}},
                                                    %% OWN proposals only: slot => {proposed_at,
                                                    %% approved_at|none}, mono-ms on THIS node — feeds the
                                                    %% round-phase histograms that localize where a
                                                    %% consensus round spends its time; bounded by the
                                                    %% pipeline depth, pruned in finalize/2
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
    S0 = maps:fold(fun(approved, _V, Acc) -> Acc;
                     (ingress, _V, Acc) -> Acc;
                     (K, V, Acc) -> test_state_set(K, V, Acc)
                  end,
                  #s{ns = <<"t">>, self = <<"self">>,
                     consensus_domain =
                         consensus_domain(<<"t">>, <<0:256>>),
                     genesis_hash = <<0:256>>,
                     chan = term_to_binary({log, <<"t">>}, [deterministic]),
                     relay_chan =
                         term_to_binary({ingress, <<"t">>}, [deterministic]),
                     vote_journal = memory},
                  Overrides),
    S1 = case maps:find(approved, Overrides) of
             {ok, V} -> S0#s{approved = V};
             error   -> S0
         end,
    case maps:find(ingress, Overrides) of
        {ok, Items} -> test_state_set(ingress, Items, S1);
        error       -> S1
    end.
test_state_set(self, V, S)       -> S#s{self = V};
test_state_set(id, V, S)         -> S#s{id = V};
test_state_set(consensus_domain, V, S) -> S#s{consensus_domain = V};
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
test_state_set(relay_conns, V, S) -> S#s{relay_conns = V};
test_state_set(relay_inbound_conns, V, S) ->
    S#s{relay_inbound_conns = V};
test_state_set(relay_dialing, V, S) -> S#s{relay_dialing = V};
test_state_set(block_requests, V, S) -> S#s{block_requests = V};
test_state_set(relay_inflight, V, S) -> S#s{relay_inflight = V};
test_state_set(batch_window_ms, V, S) -> S#s{batch_window_ms = V};
test_state_set(committee_id, V, S) -> S#s{committee_id = V};
test_state_set(local_proposal, {Slot, Hash}, S) ->   %% plant an in-flight sealed proposal
    S#s{local_proposals =
            (S#s.local_proposals)#{Slot => #local_proposal{hash = Hash, waiters = []}}};
%% Plant parked ingress items: [{Origin, From, Change, EnqueuedAtMonoMs}] — waiter
%% envelopes, byte accounting, and per-author counts are derived exactly as park_ingress
%% derives them, so drain/expiry tests exercise the real bookkeeping.
test_state_set(ingress, Items, S) ->
    lists:foldl(
      fun({local, From, Change, At}, Acc) ->
              Waiter = new_waiter(
                         From, otel_ctx:new(), Change, Acc#s.ns, false),
              {_Decision, Request, Routed} =
                  ingress_route(entry, local, Change, Acc),
              {Acc1, []} = park_ingress(
                             local, awaiting_turn,
                             Waiter, Request, At, Routed),
              Acc1;
         ({relayed, Peer, TargetSlot, Change, At}, Acc) ->
              Ref = test_relay_ref(Peer, Change, TargetSlot, Acc),
              Origin = {relayed, Ref},
              Waiter = new_waiter(
                         {relay, Ref}, otel_ctx:new(), Change, Acc#s.ns, true),
              {_Decision, Request, Routed} =
                  ingress_route(entry, Origin, Change, Acc),
              {Acc1, []} = park_ingress(
                             Origin, awaiting_turn,
                             Waiter, Request, At, Routed),
              Acc1
      end, S, Items);
test_state_set(collecting, {Slot, Froms}, S) ->
    %% Plant a not-yet-sealed batch that owns these test callers.
    S#s{collecting = #batch{
                       slot = Slot,
                       parent = Slot - 1,
                       items_rev = [{From, noop} || From <- Froms],
                       count = length(Froms),
                       bytes = 0}};
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
test_retired_inbound(#s{retired_inbound = Retired}) ->
    lists:sort(maps:keys(Retired)).
test_relay_link_peers(
  #s{relay_conns = Conns, relay_inbound_conns = Inbound,
     relay_dialing = Dialing}) ->
    {lists:sort(maps:keys(Conns)), lists:sort(maps:keys(Inbound)),
     lists:sort(maps:keys(Dialing))}.
test_relay_chan(#s{relay_chan = Chan}) -> Chan.
test_prune_relay_links(S) -> prune_relay_links(S).
test_invalidate_relay_generation(NewHead, S) ->
    invalidate_relay_generation(NewHead, S).
test_close_relay_transport(Ns) ->
    case quod_reg:where({quod_simplex, Ns}) of
        Pid when is_pid(Pid) ->
            {_StateName,
             #s{relay_conns = Outbound,
                relay_inbound_conns = Inbound}} =
                sys:get_state(Pid),
            Links =
                lists:usort(
                  [LinkPid
                   || {LinkPid, _Ref} <-
                          maps:values(Outbound)
                          ++ maps:values(Inbound)]),
            _ = [quod_link:close(LinkPid) || LinkPid <- Links],
            length(Links);
        undefined ->
            0
    end.
test_relay_transport_counts(Ns) ->
    case quod_reg:where({quod_simplex, Ns}) of
        Pid when is_pid(Pid) ->
            {_StateName,
             #s{relay_conns = Outbound,
                relay_inbound_conns = Inbound}} =
                sys:get_state(Pid),
            {map_size(Outbound), map_size(Inbound)};
        undefined ->
            {0, 0}
    end.
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
test_relayed_append(Peer, Change, S) ->
    TargetSlot = S#s.approved + 1,
    test_relayed_append(Peer, TargetSlot, Change, S).
test_relayed_append(Peer, TargetSlot, Change, S) ->
    Ref = test_relay_ref(Peer, Change, TargetSlot, S),
    handle_relayed_append(
      new_waiter({relay, Ref}, otel_ctx:new(), Change, S#s.ns, true),
      Ref, Change, S).
test_relay_ref(Peer, Change, TargetSlot,
               #s{ns = Ns, self = Self, committee_id = CommitteeId0}) ->
    {ok, Submission} = quod_transaction:submission(Ns, Change),
    SubmissionId = quod_transaction:submission_id(Submission),
    CommitteeId =
        case CommitteeId0 of
            undefined -> <<0:256>>;
            Cid -> Cid
        end,
    AttemptId =
        quod_transaction:relay_attempt_id(
          Ns, SubmissionId, CommitteeId, TargetSlot, Self),
    #relay_ref{peer = Peer, submission_id = SubmissionId,
               attempt_id = AttemptId, committee_id = CommitteeId,
               target_slot = TargetSlot}.
test_relay_origin(Peer, TargetSlot, Change, S) ->
    {relayed,
     test_relay_ref(Peer, Change, TargetSlot, S)}.
test_ingress(#s{ingress = Ingress}) ->
    #{count := Count, bytes := Bytes, authors := Authors} =
        quod_ingress_state:summary(Ingress),
    {Count, Bytes, Authors,
     [begin
          {Origin, _Waiter, Request, Anchor} =
              quod_ingress_state:item(Item),
          Change = quod_ingress_state:request_change(Request),
          {test_origin(Origin), Change#transaction.tx_id, Anchor}
      end || Item <- quod_ingress_state:items(Ingress)]}.
test_ingress_view_source(#s{ingress = Ingress}) ->
    quod_ingress_state:view_source(Ingress).
test_batch(#s{collecting = none}) ->
    none;
test_batch(
  #s{collecting =
         #batch{count = Count, bytes = Bytes, tx_ids = TxIds,
                sequences = Sequences}}) ->
    #{count => Count, bytes => Bytes,
      tx_ids => TxIds, sequences => Sequences}.
test_origin(local) -> local;
test_origin({relayed, #relay_ref{}}) -> relayed.
test_drain(S0) ->
    S = refresh_ingress_view(S0),
    drain_ingress(
      S, quod_ingress_state:route_fingerprint(S#s.ingress)).
test_expire_ingress(S) -> expire_ingress(S).
test_relay_pending(#s{relay_pending = Pending}) ->
    [{relay_wire_id(Relay), Target, TargetSlot, Deadline}
     || {_Key, #relay_pending{target = Target, target_slot = TargetSlot,
                             deadline = Deadline} = Relay}
            <- maps:to_list(Pending)].
test_relay_pending_detail(#s{relay_pending = Pending}) ->
    [{relay_wire_id(Relay), Target, TargetSlot, Deadline, NextRetry, Accepted}
     || {_Key, #relay_pending{target = Target, target_slot = TargetSlot,
                             deadline = Deadline,
                             next_retry = NextRetry, accepted = Accepted} = Relay}
            <- maps:to_list(Pending)].
relay_wire_id(#relay_pending{attempt_id = AttemptId}) ->
    AttemptId.
test_relay_result(Peer, AttemptId, Result,
                  S = #s{relay_pending = Pending}) ->
    case maps:get(AttemptId, Pending, undefined) of
        #relay_pending{submission_id = SubmissionId,
                       committee_id = CommitteeId,
                       target_slot = TargetSlot} ->
            handle_relay_result(
              Peer, SubmissionId, AttemptId, CommitteeId,
              TargetSlot, Result, S);
        undefined ->
            S
    end.
test_relay_accepted(Peer, AttemptId,
                    S = #s{relay_pending = Pending}) ->
    case maps:get(AttemptId, Pending, undefined) of
        #relay_pending{submission_id = SubmissionId,
                       committee_id = CommitteeId,
                       target_slot = TargetSlot} ->
            handle_relay_accepted(
              Peer, SubmissionId, AttemptId, CommitteeId,
              TargetSlot, S);
        undefined ->
            S
    end.
test_dispatch_relay(Peer, Msg, S) ->
    dispatch_relay(Peer, Msg, S).
test_put_pending_relay(Target, TargetSlot,
                       S = #s{ns = Ns, relay_pending = Pending}) ->
    <<SubmissionId:16/binary, _/binary>> =
        crypto:hash(sha256, term_to_binary(make_ref())),
    CommitteeId =
        case S#s.committee_id of
            undefined -> <<0:256>>;
            Cid -> Cid
        end,
    AttemptId =
        quod_transaction:relay_attempt_id(
          Ns, SubmissionId, CommitteeId, TargetSlot, Target),
    Relay = #relay_pending{from = test, target = Target,
                           target_slot = TargetSlot,
                           author_seq = map_size(Pending) + 1,
                           submission_id = SubmissionId,
                           attempt_id = AttemptId,
                           committee_id = CommitteeId,
                           frame = <<>>,
                           deadline = 0, next_retry = 0},
    case put_pending_relay(AttemptId, Relay, Pending) of
        {ok, Pending1} -> {ok, S#s{relay_pending = Pending1}};
        {error, _} = Error -> Error
    end.
test_copy_relay_pending(#s{relay_pending = Pending}, S) ->
    S#s{relay_pending = Pending}.
test_relay_custody(SubmissionId, Target, TargetSlot,
                   S = #s{custody = Custody}) ->
    Record = #custody{change = Change, original_arrival = Anchor} =
        maps:get(SubmissionId, Custody),
    ReadyKey = {Change#transaction.author_seq, SubmissionId},
    relay_custody(
      {custody, SubmissionId}, custody_marker(SubmissionId, Record),
      Target, TargetSlot, Change, Anchor,
      drop_custody_ready(ReadyKey, S)).
test_remove_pending_relay(AttemptId, S) ->
    remove_pending_relay(AttemptId, S).
test_relay_state_keys(#s{relay_pending = Pending, relay_inflight = Inflight,
                         relay_results = Results}) ->
    {lists:sort(maps:keys(Pending)),
     lists:sort(maps:keys(Inflight)),
     lists:sort(maps:keys(Results))}.
test_relay_result_entries(#s{relay_results = Results}) ->
    lists:sort(
      [{Key, Reply, Expires}
       || {Key, {_Ref, Reply, Expires}} <- maps:to_list(Results)]).
test_expire_relay_results(S = #s{relay_results = Results}) ->
    Expired =
        maps:map(
          fun(_Key, {Ref, Reply, _Expires}) ->
                  {Ref, Reply, quod_time:mono_ms() - 1}
          end, Results),
    S#s{relay_results = Expired}.
test_redrive_relays(S = #s{relay_pending = Pending}) ->
    DueAt = quod_time:mono_ms() - 1,
    Due =
        maps:map(
          fun(_Key, Relay) ->
                  Relay#relay_pending{next_retry = DueAt}
          end, Pending),
    redrive_relays(S#s{relay_pending = Due}).
test_reply_relay(
  Peer, SubmissionId, AttemptId, CommitteeId, TargetSlot, Reply, S) ->
    reply_relay(
      #relay_ref{peer = Peer, submission_id = SubmissionId,
                 attempt_id = AttemptId,
                 committee_id = CommitteeId, target_slot = TargetSlot},
      Reply, S).
test_custody(#s{custody = Custody}) ->
    lists:sort(
      [{SubmissionId, Change#transaction.author_seq,
        Submission, test_custody_placement(Placement),
        Deadline, Attempts}
       || {SubmissionId,
           #custody{change = Change, submission = Submission,
                    placement = Placement, deadline = Deadline,
                    attempts = Attempts}} <- maps:to_list(Custody)]).
test_custody_placement({local, Slot, _CommitteeId}) ->
    {local, Slot};
test_custody_placement(Placement) ->
    Placement.
test_drain_custody(S) -> drain_custody(S).
test_keep_progress_transition(S0, S1) ->
    keep_progress(S0, S1, []).
test_expire_custody(S = #s{custody = Custody}) ->
    ExpiredAt = quod_time:mono_ms() - 1,
    Custody1 =
        maps:map(
          fun(_SubmissionId, Record) ->
                  Record#custody{deadline = ExpiredAt}
          end, Custody),
    Deadlines =
        gb_sets:from_list(
          [{ExpiredAt, SubmissionId}
           || SubmissionId <- maps:keys(Custody1)]),
    expire_custody(
      S#s{custody = Custody1,
          custody_deadlines = Deadlines}).
test_outbox(#s{outbox = Outbox}) -> Outbox.
test_ingress_needs_drain(S0, S1) ->
    Before = (refresh_ingress_view(S0))#s.ingress,
    After = (refresh_ingress_view(S1))#s.ingress,
    ingress_drain_decision(Before, After) =/= none.
test_route(Pass, Origin, Change, S) ->
    {Decision, _Request, _S1} =
        ingress_route(Pass, Origin, Change, S),
    Decision.
test_round_probe(#s{round_probe = Probe}) -> Probe.
test_committee_id(#s{committee_id = CommitteeId}) -> CommitteeId.
test_log_projection(Ns, Entries, Seed) ->
    log_projection(Ns, Entries, Seed).
test_apply_catchup_window(Source, Entries, S) ->
    apply_catchup_window(Source, Entries, S).
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
signal, no longer routine backpressure), `stale_seq` (newer approved history superseded this signed
sequence — retry), `not_in_charge` (this process cannot currently accept local work, with `unavailable`
when it cannot be reached), and `skipped` for the terminal membership re-proof path. Ordinary
signed content remains in origin custody across slot exclusion and proposer removal. At N=1
only the sole-validator commit path runs, so an append just returns `{ok, Slot}`.
The call timeout sits above the ingress TTL so a parked direct append cannot race its own expiry reply.
If that deadline is nevertheless reached after consensus accepted the call, the result is
`{error, {outcome_unknown, TxId}}`: the transaction may still finalize, so callers must inspect that
transaction id rather than submit the same non-idempotent operation again.
""".
-spec append(binary(), #transaction{}) ->
        {ok, slot()} | {error, busy} | {error, skipped} | {error, bad_change}
      | {error, stale_seq}
      | {error, {outcome_unknown, binary()}}
      | {error, not_in_charge, node_id() | none | unavailable}.
append(Ns, Change) ->
    try gen_statem:call(quod_reg:via({quod_simplex, Ns}),
                        {append, Change, quod_trace:context()}, 8000)
    catch
        exit:{noproc, _} -> {error, not_in_charge, unavailable};
        exit:{timeout, _} -> {error, {outcome_unknown, Change#transaction.tx_id}};
        exit:_ -> {error, {outcome_unknown, Change#transaction.tx_id}}
    end.

-doc "Ask the consensus process to (re)drive committed blocks into a freshly-started `quod_prolog`.".
-spec rebuild(binary()) -> ok.
rebuild(Ns) -> gen_statem:cast(quod_reg:via({quod_simplex, Ns}), rebuild).

status(Ns)    -> call(Ns, get_status, #{}).
committee(Ns) -> call(Ns, get_committee, []).
stats(Ns)     -> call(Ns, get_stats, undefined).

-doc "The immutable 32-byte slot-1 genesis anchor for this consensus process, including before a fresh joiner has downloaded slot 1.".
-spec genesis_hash(binary()) -> binary() | undefined.
genesis_hash(Ns) ->
    %% This deliberately does not call the statem: rebuilding the Prolog projection can keep its
    %% mailbox busy for seconds, while the anchor was validated before `init/1` returned and never
    %% changes. The protected table remains directly readable but dies with its simplex owner, so a
    %% re-found namespace cannot inherit a stale anchor from the prior process.
    try ets:lookup(binary_to_existing_atom(genesis_table_name(Ns), utf8), anchor) of
        [{anchor, <<_:256>> = GenesisHash}] -> GenesisHash;
        _ -> undefined
    catch
        error:badarg -> undefined
    end.

namespaces() -> gproc:select([{{{n, l, {quod_simplex, '$1'}}, '_', '_'}, [], ['$1']}]).

call(Ns, Req, Default) ->
    try gen_statem:call(quod_reg:via({quod_simplex, Ns}), Req, 1000) catch exit:_ -> Default end.

%% The writer creates this after resolving the immutable anchor; readers only resolve an existing
%% table name, which fails closed while the namespace is down or being initialized.
genesis_table(Ns) -> binary_to_atom(genesis_table_name(Ns), utf8).

genesis_table_name(Ns) -> <<"quod_simplex_genesis_", Ns/binary>>.

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
    {ok, Store} = quod_ledger_store:open(Ns, quod_ledger_store:ledger_dir(Cfg)),
    Chan = term_to_binary({log, Ns}, [deterministic]),   %% the committee's consensus channel
    RelayChan = term_to_binary({ingress, Ns}, [deterministic]),
    quod_reg:subscribe({channel, Chan}),                 %% receive peers' proposals/shares/certs
    quod_reg:subscribe({channel, RelayChan}),             %% receive bounded transaction-relay frames
    RelayTimeout = relay_timeout_ms(Cfg),
    S0 = #s{ns = Ns, self = maps:get(pubkey, Id), id = Id, store = Store,
            chan = Chan, relay_chan = RelayChan,
            relay_timeout_ms = RelayTimeout,
            batch_window_ms = maps:get(batch_window_ms, Cfg),
            detailed_metrics = maps:get(detailed_consensus_metrics, Cfg, false)},
    %% A bad/missing genesis `.pl` on create is fatal — fail-fast, the app stops.
    try load_or_bootstrap(S0, Cfg) of
        S1 ->
            Committed = S1#s.slot,   %% commits are in order, so the height IS the committed floor
            case consensus_anchor(S1, Cfg) of
                {error, Reason} ->
                    {stop, {bad_config, Reason}};
                {ok, GenesisHash} ->
                    Domain = consensus_domain(Ns, GenesisHash),
                    %% One table per operator-created namespace. `genesis_hash/1` uses
                    %% binary_to_existing_atom/2, so readers never mint table-name atoms.
                    GenesisTable = ets:new(
                                     genesis_table(Ns),
                                     [named_table, protected, set]),
                    true = ets:insert(GenesisTable, {anchor, GenesisHash}),
                    {ok, Journal} =
                        quod_vote_journal:open(
                          Ns, Domain, data_dir(Cfg), Committed),
                    S2 = restore_vote_rounds(
                           S1#s{vote_journal = Journal,
                                genesis_hash = GenesisHash,
                                consensus_domain = Domain}),
                    Eng = eng_new(
                            Domain, active_validators(S2), Committed),
                    %% One periodic tick drives everything post-boot: peer redials AND the sync armer
                    %% (`maybe_arm_sync`) that kicks boot-sync/gap-fill. A fresh `mode=join` node
                    %% boots `unconfirmed`, so `should_sync` arms its catch-up at the first tick.
                    {ok, running,
                     S2#s{last_applied = 0, approved = Committed, eng = Eng},
                     [tick_timeout()]}
            end
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
    case maps:get(transaction_ttl_ms, Cfg, 30000) of
        N when is_integer(N), N > 0 -> N + 1000;
        _                           -> 31000
    end.

%% Restart reloads durable state: re-derive the committee by folding the `peer_admitted` asserts/retracts
%% out of the committed log's transaction diffs (`log_projection_step/3`, which also recovers the timestamp
%% floor `last_ts` in the same pass), STREAMED from the store in bounded windows — the log is never
%% materialized in RAM (the store is the archive, quod_prolog holds the KB projection; this consensus
%% process holds only the validator-set projection). A brand-new namespace is bootstrapped.
%% Re-folding the committee from the log is the accepted cost of running without a committee checkpoint;
%% `last/1` gives the height in O(1). Both projections derive from the same committed log, so they can't drift.
%% Derive the durable state, then decide by mode — `mode` is read HERE ONCE and then discarded (it is boot
%% config, not running state). `create` founds genesis when fresh (slot 0) or just re-derives on restart;
%% `join` starts UNFOUNDED (slot 0) or RESUMES a partial prefix (slot≥1) — either way it catches up via
%% the tick's `should_sync` arm (from slot+1, so a retry never
%% re-appends disk-present bytes, and `maybe_mark_ready` stays gated on recovery reaching `ready`).
%% `init_store/3` resolves and installs the configured/local genesis anchor
%% after this projection, so the boot pin is never copied into intermediate state.
%%
%% The initial recovery state is seeded PURELY FROM THE FACTS, not the mode: only the sole validator can
%% trust its head is the tip (`active_validators == [Self]` — nobody else could have moved it). Everyone
%% else — a founding joiner, a later joiner, or a resuming member — boots `unconfirmed` and runs recovery. So `mode`
%% leaves zero running-state residual.
load_or_bootstrap(S0 = #s{ns = Ns, store = Store}, Cfg) ->
    Base = case quod_ledger_store:last(Store) of
               0     -> S0;   %% empty ⇒ unfounded (slot 0)
               LastI -> {Vs, CommitteeId, Ts, Seqs} =
                            quod_ledger_store:fold(
                              Store, 1, LastI,
                              fun(E, Acc) ->
                                  checked_log_projection_step(Ns, E, Acc)
                              end, {[], undefined, 0, #{}}),
                        S0#s{validators = Vs, committee_id = CommitteeId,
                             slot = LastI, last_ts = Ts, author_seqs = Seqs}
           end,
    S1 = case {maps:get(mode, Cfg), Base#s.slot} of
             {create, 0} -> bootstrap(Cfg, Base);   %% fresh founder
             {_Mode, _}  -> Base                    %% join, or restarted founder/admitted member
         end,
    S1#s{sync = initial_sync(S1),
         next_author_seq = maps:get(S1#s.self, S1#s.author_seqs, 0) + 1}.

%% Resolve the one immutable chain anchor used by every vote in this process.
%% A founder derives it from its durable slot-1 block. A fresh joiner uses the
%% configured out-of-band pin; once any prefix exists, that pin must equal the
%% locally reconstructed genesis or startup fails before a vote can be restored.
consensus_anchor(#s{slot = 0}, #{mode := join, genesis_hash := GenesisHash})
  when is_binary(GenesisHash), byte_size(GenesisHash) =:= 32 ->
    {ok, GenesisHash};
consensus_anchor(S = #s{slot = Slot}, Cfg) when Slot >= 1 ->
    case {local_genesis_hash(S), maps:get(mode, Cfg)} of
        {GenesisHash, create}
          when is_binary(GenesisHash), byte_size(GenesisHash) =:= 32 ->
            {ok, GenesisHash};
        {GenesisHash, join}
          when is_binary(GenesisHash), byte_size(GenesisHash) =:= 32 ->
            case maps:get(genesis_hash, Cfg) of
                GenesisHash -> {ok, GenesisHash};
                _Other      -> {error, genesis_anchor_mismatch}
            end;
        _ ->
            {error, invalid_local_genesis}
    end;
consensus_anchor(_S, _Cfg) ->
    {error, missing_genesis_anchor}.

%% The sole validator is ready immediately because no other node could have committed past its durable head.
%% Every other shape must corroborate its tip through recovery before it can emit consensus evidence.
initial_sync(#s{self = Self} = S) ->
    case active_validators(S) of
        [Self] -> ready;
        _      -> unconfirmed
    end.

%% Fresh create: the canonical founder mints a random incarnation and durably commits ONE genesis block
%% (slot 1). Its transaction asserts `consensus_incarnation/1`, every founding member's
%% `peer_admitted` fact, and the ontology's configured initial content. The incarnation makes
%% two fresh foundings cryptographically distinct even when every operator input is byte-identical.
%% The committee is then DERIVED from that same transaction (`apply_committee_delta`), so bootstrap and
%% restart re-fold cannot disagree. Loading or compiling initial content may throw
%% `{genesis_failed,_}`; the whole transaction lands in ONE atomic append, so bad
%% content persists nothing and the next boot retries fresh.
bootstrap(Cfg, S = #s{ns = Ns, self = Self, store = Store}) ->
    Incarnation = crypto:strong_rand_bytes(32),
    GenesisTx = genesis_tx(Cfg, Ns, Self, Incarnation),
    E = #entry{index = 1, data = quod_ledger:data([GenesisTx])},
    {ok, Store1} = quod_ledger_store:append(Store, [E]),
    {Validators, CommitteeId, _Ts, _Seqs} =
        log_projection(Ns, [E], {[], undefined, 0, #{}}),
    S#s{store = Store1, validators = Validators,
        committee_id = CommitteeId, slot = 1}.

%% The genesis transaction compiles the incarnation, founding committee, and optional content
%% through the erlog overlay together. `consensus_incarnation/1` is therefore ordinary queryable ontology
%% truth as well as part of the anchor. The predicate is reserved to this one generated fact.
%% The founding set is `[]` => self-only (N=1) or a list of founding members; each entry is a bare pubkey
%% or `{Pubkey, Host, Port}`. The lexicographically-smallest pubkey is both the sole permitted creator and
%% the unsigned transaction author. All other founding members start in `mode=join` against its anchor.
genesis_tx(Cfg, Ns, Self, Incarnation) ->
    Founders   = founding(Cfg, Self),
    [{GenesisAuthor, _, _} | _] = Founders,
    InitialTerms = genesis_terms(Cfg),
    PeerAndInitialTerms =
        lists:foldr(
          fun({Pk, Host, Port}, Acc) ->
                  [{peer_admitted, Pk, Host, Port, Pk} | Acc]
          end, InitialTerms, Founders),
    Diff = quod_prolog:terms_to_diff(
             [{consensus_incarnation, Incarnation} | PeerAndInitialTerms]),
    Genesis =
        #transaction{tx_id = genesis_tx_id(Ns, Incarnation), caller_ns = Ns,
                     diff = Diff, read_check = #{},
                     author = GenesisAuthor, sig = none},
    ExpectedFounders = [Pk || {Pk, _Host, _Port} <- Founders],
    case valid_genesis_transaction(Ns, Genesis, ExpectedFounders) of
        true ->
            Genesis;
        false ->
            throw({genesis_failed,
                   invalid_generated_genesis})
    end.

genesis_tx_id(Ns, Incarnation)
  when is_binary(Ns), is_binary(Incarnation), byte_size(Incarnation) =:= 32 ->
    <<?GENESIS_TX_TAG, 0, ?GENESIS_TX_VERSION:8,
      (byte_size(Ns)):32, Ns/binary, Incarnation/binary>>.

decode_genesis_tx_id(Ns, TxId) when is_binary(Ns), is_binary(TxId) ->
    NsLen = byte_size(Ns),
    case TxId of
        <<?GENESIS_TX_TAG, 0, ?GENESIS_TX_VERSION:8, NsLen:32,
          Ns:NsLen/binary, Incarnation:32/binary>> ->
            {ok, Incarnation};
        _ ->
            error
    end.

genesis_incarnation_matches(Diff, Incarnation) ->
    case [Op || Op = {_Action, {Head, _Body}} <- Diff,
                is_tuple(Head), tuple_size(Head) > 0,
                element(1, Head) =:= consensus_incarnation] of
        [{assert, {{consensus_incarnation, Incarnation}, _CompiledBody}}] ->
            true;
        _ ->
            false
    end.

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

%% Detailed per-event probes are diagnostic-only. They synchronously update several
%% Prometheus histograms from this serial process, so production keeps them disabled.
running(EventType, Content, S = #s{detailed_metrics = false}) ->
    running_impl(EventType, Content, S);
running(EventType, Content, S) ->
    {message_queue_len, QLen} = process_info(self(), message_queue_len),
    T0 = erlang:monotonic_time(microsecond),
    Result = running_impl(EventType, Content, S),
    quod_metrics:observe_consensus_event(
      S#s.ns, event_class(EventType, Content),
      erlang:monotonic_time(microsecond) - T0, QLen),
    Result.

%% Time one named sub-step of a handler; the step histogram is the slow-handler
%% decomposition (which seam inside a 200ms handler actually holds the time).
timed_step(#s{detailed_metrics = false}, _Step, Fun) ->
    Fun();
timed_step(#s{ns = Ns}, Step, Fun) ->
    T0 = erlang:monotonic_time(microsecond),
    Result = Fun(),
    quod_metrics:observe_consensus_step(
      Ns, Step, erlang:monotonic_time(microsecond) - T0),
    Result.

event_class({call, _}, {append, _, _})         -> append;
event_class({call, _}, _)                      -> call;
event_class(info, {quod_message, _, _, _})     -> frame;
event_class({timeout, batch}, _)               -> timeout_batch;
event_class({timeout, progress}, _)            -> timeout_progress;
event_class({timeout, tick}, _)                -> timeout_tick;
event_class({timeout, _}, _)                   -> timeout_other;
event_class(_, {link_up, _, _, _})             -> link;
event_class(_, {link_error, _, _})             -> link;
event_class(_, {'DOWN', _, _, _, _})           -> link;
event_class(cast, _)                           -> cast;
event_class(_, _)                              -> other.

running_impl({call, From}, {append, Change, TraceCtx}, S0) ->
    Waiter = new_waiter(From, TraceCtx, Change, S0#s.ns, false),
    {S1, Reply} = handle_append(
                    Waiter, Change,
                    S0#s{submitted = S0#s.submitted + 1}),
    keep_progress(S0, S1, Reply);
%% A freshly-(re)started quod_prolog: re-drive committed blocks from the start (async casts, in slot
%% order), then mark it ready ONLY once its kb is caught up — never a prove over a half-built kb.
running_impl(cast, rebuild, S0) ->
    S1 = apply_committed(S0#s{last_applied = 0, prolog_ready = false}),
    keep_progress(S0, S1, []);
%% `{log, Ns}` is consensus-only. Decode only after the authenticated peer is
%% known to be an active participant; a relay envelope on this channel is an
%% exact no-op and cannot replace a consensus/readiness generation.
running_impl(
  info, {quod_message, {{Peer, _Addr}, InLink}, Chan, Payload},
  S0 = #s{chan = Chan}) ->
    case is_participant(S0)
         andalso lists:member(Peer, active_validators(S0))
         andalso live_link(InLink) of
        false ->
            {keep_state, S0};
        true ->
            case quod_relay:decode_consensus_frame(Payload, S0#s.ns) of
                error ->
                    {keep_state, S0};
                {consensus, Msg} ->
                    SIn = track_inbound(Peer, InLink, S0),
                    case current_inbound_generation(Peer, InLink, SIn) of
                        false ->
                            keep_progress(S0, SIn, []);
                        true ->
                            S1 = dispatch(Peer, Msg, SIn),
                            keep_progress(S0, S1, [])
                    end
            end
    end;
%% `{ingress, Ns}` is relay-only and always uses the bounded safe grammar.
%% Current committee members and exact peers named by live attempts get one
%% inbound generation. Removed peers own no relay work: origin-side durable
%% finality resolves their retained callers without granting former members an
%% unbounded signature-verification and ledger-read surface.
running_impl(
  info, {quod_message, {{Peer, _Addr}, InLink}, RelayChan, Payload},
  S0 = #s{relay_chan = RelayChan}) ->
    case quod_relay:decode_relay_frame(Payload, S0#s.ns) of
        error ->
            close_untracked_relay_link(InLink),
            {keep_state, S0};
        {relay, Relay} ->
            case relay_peer_owned(Peer, Relay, S0) of
                true ->
                    SIn = track_relay_inbound(Peer, InLink, S0),
                    case current_relay_inbound_generation(
                           Peer, InLink, SIn) of
                        false ->
                            keep_progress(S0, SIn, []);
                        true ->
                            {S1, Actions} =
                                dispatch_relay(Peer, Relay, SIn),
                            keep_progress(S0, S1, Actions)
                    end;
                false ->
                    close_untracked_relay_link(InLink),
                    {keep_state, S0}
            end
    end;
running_impl(info, {quod_message, _, _OtherChan, _}, S) -> {keep_state, S};   %% Brahms / another namespace's log
%% A membership verdict from our own quod_prolog (a plain message from `deliver_verdict`): emit or withhold
%% the deferred support share. The tag echoes the `{Slot, BlockHash}` we requested with, so the verdict binds
%% to the exact block. Support can advance/skip the head, so reflect that in the Δ timer.
running_impl(info, {membership_verdict, {Sl, BH}, Verdict}, S0) ->
    S1 = on_membership_verdict(Sl, BH, Verdict, S0),
    keep_progress(S0, S1, []);
running_impl(info, {link_up, Peer, Chan, LinkPid}, S0 = #s{chan = Chan}) ->
    keep_progress(S0, handle_link_up(Peer, LinkPid, S0), []);
running_impl(info, {link_error, Peer, Chan}, S0 = #s{chan = Chan}) ->
    %% the dial failed — clear the in-flight marker but KEEP the buffered frames; the tick re-dials
    %% (consensus emits each propose/share only once, so dropping them would stall the slot forever).
    S1 = S0#s{dialing = maps:remove(Peer, S0#s.dialing)},
    keep_progress(S0, S1, []);
running_impl(
  info, {link_up, Peer, RelayChan, LinkPid},
  S0 = #s{relay_chan = RelayChan}) ->
    keep_progress(S0, handle_relay_link_up(Peer, LinkPid, S0), []);
running_impl(
  info, {link_error, Peer, RelayChan},
  S0 = #s{relay_chan = RelayChan}) ->
    S1 = S0#s{
           relay_dialing =
               maps:remove(Peer, S0#s.relay_dialing)},
    keep_progress(S0, S1, []);
%% The sync worker CRASHED before casting `{sync_done,_}` (a normal exit always casts first, and that cast,
%% sent before the exit, is processed before this DOWN — flipping `sync` away from `{pulling,Pid}` to the
%% generic clause below). Clear the single-flight latch + back off; the tick re-arms if still `should_sync`.
%% The worker resumes from the persisted height, so a retry continues from the prefix already on disk.
running_impl(info, {'DOWN', _Ref, process, Pid, _Reason}, S0 = #s{sync = {pulling, Pid}}) ->
    keep_progress(S0, recovery_failed(S0), []);
running_impl(info, {'DOWN', _Ref, process, Pid, _}, S0) ->
    keep_progress(S0, drop_link(Pid, S0), []);
%% Seal the current micro-batch. A stale timeout is harmless: flush_batch/2 only
%% acts when the collecting slot still matches.
running_impl({timeout, batch}, {flush_batch, V}, S0) ->
    S1 = flush_batch(V, S0),
    keep_progress(S0, S1, []);
%% The oldest non-final slot owns one Δ watchdog through all three phases. A timeout may redrive a
%% proposal/finality bundle or issue a complaint, but it never silently disappears at notarization.
running_impl({timeout, progress}, {progress_timeout, V}, S0) ->
    S1 = on_progress_timeout(V, S0),
    keep_progress(S0, S1, [], rearm);
%% Consensus re-drive: sweep any dial that resolved to neither link_up nor link_error (presumed lost),
%% re-dial every peer whose link never came up (its frames are still buffered), AND arm sync — the one
%% place a boot-sync / member gap-fill is kicked (`maybe_arm_sync`, single-flight + paced, off the hot path).
running_impl({timeout, tick}, tick, S0) ->
    S1 = maybe_arm_sync(
           redrive_relays(redrive_inflight(redial_pending(
             sweep_stale_dials(expire_custody(expire_ingress(S0))))))),
    keep_progress(S0, S1, [tick_timeout()]);
%% Only the recovery coordinator can produce `{ready, Height}`: it has pulled every available committee
%% source and observed a certificate quorum at the final local height. Bind completion to the monitored
%% worker pid. We accept the result when the durable head is AT OR PAST the corroborated `H` (`Slot >= H`),
%% not only exactly `H`: a member ingesting the live `{log}` stream during the pull can only advance its
%% head via `commit_block`/`skip_block`, each of which finalizes on a QUORUM cert (`persisted_finality`) —
%% so any slot past `H` is itself cert-corroborated, never a blind advance. Requiring `Slot =:= H` instead
%% would reject a member that stayed caught up under load (its head moved while the probe was in flight),
%% bouncing it back to `unconfirmed` forever — the load stall this guard must not cause.
running_impl(cast, {sync_done, Pid, {ready, H}},
        S0 = #s{sync = {pulling, Pid}, slot = Slot}) when H >= 1, Slot >= H ->
    S1 = S0#s{sync = ready, sync_arm = reset_pace()},
    S2 = apply_committed(S1),
    %% Close the runtime replay even when recovery reaches a quiet head. This cast follows all
    %% replay apply casts from this same process, so reconciliation sees the complete prefix.
    _ = quod_prolog:mark_ready(S2#s.ns),
    keep_progress(S0, S2, []);
%% Any incomplete round returns to the single `unconfirmed` state. Partial windows stay durable and the
%% next worker resumes from the resulting height, but no signing capability survives the failure.
running_impl(cast, {sync_done, Pid, _Result}, S0 = #s{sync = {pulling, Pid}}) ->
    keep_progress(S0, recovery_failed(S0), []);
running_impl(cast, {sync_done, _Pid, _}, S) -> {keep_state, S};   %% result from an obsolete worker
%% The sync worker — and, for an observer, the feed's anti-entropy pull — hands each verified, contiguous
%% window here to persist + replay in slot order. The caller presents an explicit source capability:
%% `{recovery,Pid}` must match the one monitored recovery owner; `feed` is accepted only by a settled
%% observer. This keeps the sole-writer rule local and makes a promotion crossing deterministic.
running_impl({call, From}, {sink_catchup, Source, Es}, S0) ->
    case may_sink(Source, S0) of
        %% `reseat_engine` discards the obsolete volatile round and its head watchdog. The common
        %% transition helper cancels the named timer before the recovered member can vote again.
        true  -> {S1, Reply} = apply_catchup_window(Source, Es, S0),
                 keep_progress(S0, S1, [{reply, From, Reply}]);
        false -> {keep_state, S0, [{reply, From, {error, not_following}}]}
    end;
%% The feed puller closes its whole multi-window replay through this process. All apply casts
%% above and this ready cast therefore have one sender and preserve mailbox order at Prolog.
running_impl({call, From}, finish_feed_replay, S = #s{sync = ready}) ->
    case is_participant(S) of
        false -> _ = quod_prolog:mark_ready(S#s.ns),
                 {keep_state, S, [{reply, From, ok}]};
        true  -> {keep_state, S, [{reply, From, {error, not_following}}]}
    end;
running_impl({call, From}, finish_feed_replay, S) ->
    %% Promotion can revoke feed ownership mid-window. Its member recovery will publish the
    %% ready edge after corroborating the new head; acknowledge the obsolete feed worker now.
    {keep_state, S, [{reply, From, ok}]};
running_impl({call, From}, get_status, S)       -> {keep_state, S, [{reply, From, status_map(S)}]};
running_impl({call, From}, get_committee, S)    -> {keep_state, S, [{reply, From, S#s.validators}]};
running_impl({call, From}, get_stats, S)        -> {keep_state, S, [{reply, From, stats_map(S)}]};
running_impl(_EventType, _Event, S)             -> {keep_state, S}.

terminate(
  _Reason, _State,
  #s{chan = Chan, relay_chan = RelayChan,
     store = Store, vote_journal = Journal,
     conns = Conns, inbound_conns = Inbound,
     relay_conns = RelayConns,
     relay_inbound_conns = RelayInbound,
     retired_inbound = RetiredInbound}) ->
    %% Custody and accepted inbound relay state share this process incarnation.
    %% Tear down every tracked stream before either can disappear, forcing peers
    %% to reconnect and replay their retained prefixes in author order.
    close_link_maps(
      Conns, Inbound, RelayConns, RelayInbound, RetiredInbound),
    _ = case Chan of undefined -> ok; _ -> catch quod_reg:unsubscribe({channel, Chan}) end,
    _ = case RelayChan of
            undefined -> ok;
            _ -> catch quod_reg:unsubscribe({channel, RelayChan})
        end,
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

%% Appends collect for the configured bounded window into one block. A sealed proposal owns its
%% parked callers until commit/skip; the next slot may open as soon as that block is
%% notarized, even though the durable committed frontier has not caught up yet.
handle_append(From = #waiter{trace_ctx = TraceCtx}, Change,
              S = #s{ns = Ns}) ->
    _ = quod_trace:add_event(
          TraceCtx, <<"consensus.append_received">>,
          #{'quod.namespace' => Ns,
            'quod.tx.id' => quod_trace:tx_id(Change#transaction.tx_id)}),
    append_entry(local, From, Change, S).

handle_relayed_append(Waiter, Ref = #relay_ref{}, Change, S) ->
    append_entry({relayed, Ref}, Waiter, Change, S).

%% Live arrival: stamp the mono-ms anchor so parking cannot reset ingress or relay
%% lifetime, then compute the route and execute it.
append_entry(Origin, From, Change, S) ->
    Anchor = quod_time:mono_ms(),
    {Decision, Request, S1} =
        ingress_route(entry, Origin, Change, S),
    execute(
      entry, Origin, From, Request, Anchor, Decision, S1).

%% ---------------------------------------------------------------------------
%% Consensus-private state is projected once into `quod_ingress_state`; its
%% cached canonical view owns every routing and wake decision. This adapter supplies
%% the current validation verdict and translates private relay references.
ingress_route(Pass, Origin, Change, S0) ->
    Request = quod_ingress_state:request(Change),
    {Decision, Prepared, S1} =
        ingress_route_request(Pass, Origin, Request, S0),
    {Decision, Prepared, S1}.

ingress_route_request(Pass, Origin, Request, S0) ->
    S = refresh_ingress_view(S0),
    Change = quod_ingress_state:request_change(Request),
    Validate =
        fun() ->
                case route_change_acceptable(Origin, Change, S) of
                    true ->
                        Membership =
                            case quod_ingress_state:request_membership(
                                   Request) of
                                unknown ->
                                    is_membership_change(Change);
                                Cached ->
                                    Cached
                            end,
                        {valid, Membership};
                    false ->
                        invalid
                end
        end,
    {Decision, Prepared} =
        quod_ingress_state:route(
          Pass, ingress_route_origin(Origin), Request, Validate,
          S#s.ingress),
    {Decision, Prepared, S}.

route_change_acceptable(local, Change, S) ->
    local_change_acceptable(Change, S);
route_change_acceptable({custody, _SubmissionId}, Change, S) ->
    ingress_change_acceptable(Change, S);
route_change_acceptable({relayed, #relay_ref{}}, Change, S) ->
    ingress_change_acceptable(Change, S).

ingress_route_origin(local) ->
    local;
ingress_route_origin({custody, _SubmissionId}) ->
    custody;
ingress_route_origin(
  {relayed, #relay_ref{committee_id = CommitteeId,
                       target_slot = TargetSlot}}) ->
    {relayed, CommitteeId, TargetSlot}.

refresh_ingress_view(S = #s{ingress = Ingress}) ->
    Source = ingress_view_source(S),
    case quod_ingress_state:view_source(Ingress) =:= Source of
        true ->
            S;
        false ->
            S#s{
              ingress =
                  quod_ingress_state:put_view(
                    Source, ingress_view_facts(S), Ingress)}
    end.

%% The token contains only immutable references or O(1) projections. An
%% unrelated mailbox event reuses it exactly and avoids rebuilding/sorting the
%% route view. Any fact consumed by ingress_view_facts/1 must have a source here.
ingress_view_source(
  S = #s{self = Self, slot = Durable,
         approved = Approved, committee_id = CommitteeId,
         validators = Validators, sync = Sync,
         eng = #eng{base = EngineBase, ahead_finalizer = AheadFinalizer,
                    certs = Certs, tree = Tree},
         local_proposals = Local, commit_buf = CommitBuf,
         custody_lane = CustodyLane, custody_ready = CustodyReady,
         relay_pending = Pending, author_seqs = AuthorSeqs}) ->
    Floor = Approved + 1,
    CustodyReadyCount = gb_sets:size(CustodyReady),
    CustodyPendingCount =
        custody_pending_count(CustodyReady, Pending),
    CustodyAuthorSeqs =
        case CustodyReadyCount of
            0 -> inactive;
            _ -> AuthorSeqs
    end,
    {Self, Durable, Approved, CommitteeId, Validators, Sync,
     EngineBase, AheadFinalizer, Certs, Tree,
     proposal_visible(Floor, S),
     maps:is_key(Floor, Local),
     maps:is_key(Floor, CommitBuf),
     collecting_gate(S#s.collecting),
     CustodyLane, CustodyReadyCount,
     pending_relay_lane(Pending),
     CustodyPendingCount, CustodyAuthorSeqs}.

ingress_view_facts(
  S = #s{self = Self, slot = Durable,
         approved = Approved, committee_id = CommitteeId,
         custody_lane = CustodyLane, custody_ready = CustodyReady,
         relay_pending = Pending}) ->
    Floor = Approved + 1,
    Validators = active_validators(S),
    Barrier = membership_barrier(S),
    #{self => Self,
      capability => ingress_capability(S),
      committee_id => CommitteeId,
      validators => Validators,
      durable_head => Durable,
      approved => Approved,
      proposal_visible => proposal_visible(Floor, S),
      proposal_slot => proposal_slot(S, Barrier),
      membership_barrier => Barrier,
      approved_author_seqs =>
          custody_author_sequence_floor(CustodyReady, S),
      collecting => collecting_gate(S#s.collecting),
      custody_lane => CustodyLane,
      custody_ready => gb_sets:size(CustodyReady),
      relay_lane => pending_relay_lane(Pending),
      relay_pending_count =>
          custody_pending_count(CustodyReady, Pending)}.

custody_author_sequence_floor(CustodyReady, S) ->
    case gb_sets:is_empty(CustodyReady) of
        true  -> inactive;
        false -> approved_author_seqs(S)
    end.

custody_pending_count(CustodyReady, Pending) ->
    case gb_sets:is_empty(CustodyReady) of
        true  -> inactive;
        false -> map_size(Pending)
    end.

pending_relay_lane(Pending) when map_size(Pending) =:= 0 ->
    empty;
pending_relay_lane(Pending) ->
    {_AttemptId,
     #relay_pending{target = Target, target_slot = TargetSlot},
     _Iterator} = maps:next(maps:iterator(Pending)),
    {Target, TargetSlot}.

%% Executor: the ONLY place a decision becomes effects. Entry parks to the queue
%% TAIL; the drain never executes `{park,_}` (drain_loop holds the head instead),
%% so a drained item can never re-park.
execute(Pass, Origin, From, Request, Anchor, Decision, S) ->
    Change = quod_ingress_state:request_change(Request),
    Membership =
        quod_ingress_state:request_membership(Request),
    case Decision of
        {reject, Why} ->
            reject_append(From, Why, S);
        redirect ->
            redirect_append(From, none, S);
        {park, Cause} ->
            park_ingress(Origin, Cause, From, Request, Anchor, S);
        {collect, Slot} when element(1, Origin) =:= relayed ->
            collect_append(From, Change, Membership, Slot, S);
        {collect, Slot} when element(1, Origin) =:= custody ->
            collect_custody(
              Origin, From, Change, Membership, Slot, S);
        {collect, Slot} ->
            sign_then(From, Change, Membership, Anchor, S,
                      fun(OwnedOrigin, F, Signed, S1) ->
                          case OwnedOrigin of
                              local ->
                                  collect_append(
                                    F, Signed, Membership, Slot, S1);
                              {custody, _} ->
                                  collect_custody(
                                    OwnedOrigin, F, Signed,
                                    Membership, Slot, S1)
                          end
                      end);
        {relay, Leader, WatchSlot} when element(1, Origin) =:= custody ->
            relay_custody(
              Origin, From, Leader, WatchSlot, Change, Anchor,
              watch_requested(WatchSlot, count_forwarded(Pass, S)));
        {relay, Leader, WatchSlot} ->   %% fresh LOCAL origin only
            sign_then(From, Change, Membership, Anchor, S,
                      fun(OwnedOrigin, F, Signed, S1) ->
                          S2 = watch_requested(
                                 WatchSlot, count_forwarded(Pass, S1)),
                          case OwnedOrigin of
                              local ->
                                  relay_append(
                                    F, Leader, WatchSlot, Signed, Anchor, S2);
                              {custody, _} ->
                                  relay_custody(
                                    OwnedOrigin, F, Leader, WatchSlot,
                                    Signed, Anchor, S2)
                          end
                      end)
    end.

%% Sign exactly once, on the pass that leaves the unsigned queue. Ordinary
%% content immediately enters origin custody; membership changes deliberately
%% keep their terminal skip/re-proof contract.
sign_then(From, Change, Membership, Anchor, S, Then)
  when is_boolean(Membership) ->
    case sign_local_change(Change, S) of
        {error, _} ->
            reject_append(From, bad_change, S);
        {ok, Signed, S1} ->
            case prepare_submission(S1#s.ns, Signed) of
                {error, _} ->
                    reject_append(From, bad_change, S1);
                {ok, Submission, SubmissionId, Bytes} ->
                    Bound =
                        bind_waiter_submission_id(
                          From, SubmissionId),
                    %% Signing changes only author identity, sequence, and
                    %% signature. Reuse the diff classification already
                    %% established by the routing validation pass.
                    case Membership of
                        true ->
                            Then(local, Bound, Signed, S1);
                        false ->
                            case retain_custody(
                                   Bound, Signed, Submission,
                                   SubmissionId, Bytes, Anchor, S1) of
                                {ok, Origin, Marker, S2} ->
                                    Then(Origin, Marker, Signed, S2);
                                {error, busy, S2} ->
                                    reject_append(Bound, busy, S2);
                                {error, bad_change, S2} ->
                                    reject_append(Bound, bad_change, S2)
                            end
                    end
            end
    end.

prepare_submission(Ns, Change) ->
    case quod_transaction:submission(Ns, Change) of
        {error, _} = Error ->
            Error;
        {ok, Submission} ->
            {ok, Submission,
             quod_transaction:submission_id(Submission),
             byte_size(term_to_binary(Submission, [deterministic]))}
    end.

retain_custody(Waiter, Change, Submission, SubmissionId, Bytes, Anchor,
               S = #s{custody = Custody,
                      custody_deadlines = Deadlines,
                      custody_bytes = CustodyBytes,
                      relay_timeout_ms = RelayTimeout}) ->
    case {maps:is_key(SubmissionId, Custody),
          map_size(Custody) >= ?MAX_CUSTODY,
          CustodyBytes + Bytes > ?MAX_CUSTODY_BYTES} of
        {true, _, _} ->
            {error, bad_change, S};
        {false, true, _} ->
            {error, busy, S};
        {false, false, true} ->
            {error, busy, S};
        {false, false, false} ->
            Deadline = Anchor + RelayTimeout,
            Record =
                #custody{waiter = Waiter, change = Change,
                         submission = Submission,
                         original_arrival = Anchor,
                         deadline = Deadline, bytes = Bytes},
            Marker = custody_marker(SubmissionId, Record),
            {ok, {custody, SubmissionId}, Marker,
             S#s{custody = Custody#{SubmissionId => Record},
                 custody_deadlines =
                     gb_sets:add_element(
                       {Deadline, SubmissionId}, Deadlines),
                 custody_bytes = S#s.custody_bytes + Bytes}}
    end.

collect_custody(
  {custody, SubmissionId}, Marker, Change, Membership, Slot, S) ->
    case place_custody(
           SubmissionId,
           {local, Slot, S#s.committee_id}, S) of
        {ok, S1} ->
            collect_append(
              Marker, Change, Membership, Slot, S1);
        {conflict, S1} ->
            {defer_custody_placement(SubmissionId, S1), []};
        {error, S1} ->
            %% The marker is internal and the only `error` is missing custody,
            %% which means another terminal path already removed it. Do not
            %% misclassify that lifecycle race as malformed client content.
            {S1, []}
    end.

relay_custody(
  {custody, SubmissionId}, Marker, Leader, TargetSlot, Change, Anchor, S) ->
    relay_append(
      Marker, Leader, TargetSlot, Change, Anchor, S, SubmissionId).

place_custody(SubmissionId, Placement,
              S = #s{custody = Custody,
                     custody_lane = ExistingLane}) ->
    case maps:get(SubmissionId, Custody, undefined) of
        #custody{placement = ready, attempts = Attempts} = Record ->
            Lane = custody_placement_lane(Placement, S#s.self),
            case ExistingLane =:= empty
                 orelse ExistingLane =:= Lane of
                false ->
                    {conflict, S};
                true ->
                    Attempts1 = Attempts + 1,
                    IsRetarget = Attempts > 0,
                    Record1 =
                        Record#custody{placement = Placement,
                                       attempts = Attempts1},
                    _ =
                        case IsRetarget of
                            true ->
                                quod_trace:add_event(
                                  waiter_trace_ctx(Record#custody.waiter),
                                  <<"consensus.retargeted">>,
                                  #{'quod.retarget.hop' => Attempts,
                                    'quod.consensus.slot' =>
                                        element(2, Lane),
                                    'quod.relay.target' =>
                                        trace_node_id(element(1, Lane))});
                            false ->
                                ok
                        end,
                    {ok,
                     S#s{custody =
                             Custody#{SubmissionId => Record1},
                         custody_lane = Lane,
                         ingress_retargets =
                             S#s.ingress_retargets
                             + case IsRetarget of
                                   true -> 1;
                                   false -> 0
                               end}}
            end;
        #custody{} ->
            %% A second placement decision for retained content is internal
            %% state contention, not malformed content. Its existing placement
            %% remains authoritative until reconciliation classifies it.
            {conflict, S};
        undefined ->
            {error, S}
    end.

%% A temporary placement refusal changes only where retained work may go; it
%% says nothing about the transaction's validity. Keep the exact submission in
%% the ordered ready set. The current drain pass then seals instead of selecting
%% the same key again; a later view/lane/capacity fingerprint transition retries it.
defer_custody_placement(
  SubmissionId,
  S = #s{custody = Custody, custody_ready = Ready}) ->
    case maps:get(SubmissionId, Custody, undefined) of
        #custody{placement = ready, change = Change} ->
            S#s{custody_ready =
                    gb_sets:add_element(
                      {Change#transaction.author_seq, SubmissionId},
                      Ready)};
        _ ->
            S
    end.

custody_placement_lane(
  {local, Slot, CommitteeId}, Self) ->
    {Self, Slot, CommitteeId};
custody_placement_lane(
  {relay, _AttemptId, Target, Slot, CommitteeId}, _Self) ->
    {Target, Slot, CommitteeId}.

custody_marker(
  SubmissionId,
  #custody{waiter = Waiter}) ->
    Waiter#waiter{reply_to = {custody, SubmissionId},
                  submission_id = SubmissionId}.

count_forwarded(drain, S) -> S#s{ingress_forwarded = S#s.ingress_forwarded + 1};
count_forwarded(entry, S) -> S.

%% Is the current slot's proposal already out, as seen from this node? True once we
%% supported it or it notarized — O(1) on existing latches. If the proposal exists but
%% has not reached us yet, relaying is still right: it joins the leader's open batch.
proposal_visible(Next, S = #s{eng = #eng{tree = Tree}}) ->
    (round_state(Next, S))#round.supporting =/= none
        orelse maps:is_key(Next, Tree).

%% The local append API accepts only a structurally valid unsigned transaction
%% authored by this node. Routing reserves bounded signature-growth headroom;
%% the item is signed exactly once when it leaves the unsigned queue, before it
%% enters custody, batching, or relay.
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
reject_append(From, stale_seq, S) ->   %% a newer sequence became approved first; retryable by contract,
                                       %% so it counts as r_stale, NEVER as r_bad — r_bad is
                                       %% the "malformed workload" alarm and must stay quiet
                                       %% for a locally confirmed sequence race
    reply_now(From, {error, stale_seq}, S#s{r_stale = S#s.r_stale + 1});
reject_append(From, busy, S) ->
    reply_now(From, {error, busy}, S#s{r_busy = S#s.r_busy + 1}).

%%%===================================================================
%%% ingress park queue — take a ticket, drain on the pipeline's own events
%%%===================================================================

%% Park one append at the queue tail. Overflow of any bound is the real backpressure
%% boundary. Custody and relay maps have independent bounds.
park_ingress(Origin, Cause, Waiter, Request, Anchor,
             S = #s{ingress = Ingress}) ->
    case quod_ingress_state:enqueue(
           Origin, Waiter, Request, Anchor, Ingress) of
        full ->
            {S1, Actions} = reject_append(Waiter, busy, S),
            {S1#s{ingress_overflow = S1#s.ingress_overflow + 1}, Actions};
        {ok, Depth, Ingress1} ->
            _ = quod_trace:add_event(
                  waiter_trace_ctx(Waiter), <<"consensus.parked">>,
                  #{'quod.ingress.depth' => Depth,
                    'quod.ingress.cause' => Cause}),
            S1 = S#s{ingress = Ingress1},
            %% Parked demand arms the head watchdog constructively: every park is a
            %% claim that the pipeline floor must move, so register it as demand
            %% instead of relying on the park cause to coincide with head evidence.
            {watch_requested(S1#s.approved + 1, S1), []}
    end.

%% Retained signed work drains before unsigned ingress. The ordered ready set
%% contains only origin-local submissions whose exact prior slot is durably
%% excluded; its `{author_seq, SubmissionId}` keys keep every exclusion cohort
%% in global author order, including across repeated partial retargets.
-ifdef(TEST).
drain_custody(S) ->
    {S1, ActionsRev} = drain_custody_rev(S, [], 0),
    {S1, lists:reverse(ActionsRev)}.
-endif.

drain_custody_rev(
  S = #s{custody_ready = Ready, custody = Custody},
  ActionsRev, N) ->
    case gb_sets:is_empty(Ready) of
        true ->
            seal_drained_rev(S, ActionsRev, N);
        false ->
            ReadyKey = {_AuthorSeq, SubmissionId} =
                gb_sets:smallest(Ready),
            case maps:get(SubmissionId, Custody, undefined) of
                #custody{placement = ready, change = Change,
                          original_arrival = Anchor,
                          deadline = Deadline} = Record ->
                    case quod_time:mono_ms() >= Deadline of
                        true ->
                            S1 = drop_custody_ready(ReadyKey, S),
                            S2 = complete_custody(
                                   SubmissionId,
                                   {error, not_in_charge, unavailable},
                                   S1),
                            drain_custody_rev(S2, ActionsRev, N);
                        false ->
                            Origin = {custody, SubmissionId},
                            {Decision, Request, SRoute} =
                                ingress_route(
                                  drain, Origin, Change, S),
                            case Decision of
                                {park, _Cause} ->
                                    seal_drained_rev(
                                      SRoute, ActionsRev, N);
                                _ ->
                                    Marker =
                                        custody_marker(
                                          SubmissionId, Record),
                                    S1 =
                                        drop_custody_ready(
                                          ReadyKey, SRoute),
                                    {S2, Actions} =
                                        execute(
                                          drain, Origin, Marker,
                                          Request, Anchor,
                                          Decision, S1),
                                    ActionsRev1 =
                                        lists:reverse(
                                          Actions, ActionsRev),
                                    case maps:get(
                                           SubmissionId,
                                           S2#s.custody,
                                           undefined) of
                                        #custody{placement = ready} ->
                                            %% A temporary placement refusal
                                            %% left this submission unplaced.
                                            %% Restore its exact ready key even
                                            %% if a future refusal arm forgets
                                            %% to do so itself.
                                            %% Stop this pass: immediately
                                            %% selecting it again would spin
                                            %% forever in one statem callback.
                                            %% A later custody-fingerprint
                                            %% transition (including removal
                                            %% of an obstructing relay) wakes
                                            %% the drain.
                                            seal_drained_rev(
                                              defer_custody_placement(
                                                SubmissionId, S2),
                                              ActionsRev1, N);
                                        _ ->
                                            drain_custody_rev(
                                              S2, ActionsRev1, N + 1)
                                    end
                            end
                    end;
                _ ->
                    %% Fail closed on impossible index drift: rebuild from
                    %% custody instead of choosing a later sequence.
                    drain_custody_rev(
                      S#s{custody_ready =
                              custody_ready_index(Custody)},
                      ActionsRev, N)
            end
    end.

drop_custody_ready(Key, S = #s{custody_ready = Ready}) ->
    S#s{custody_ready = gb_sets:del_element(Key, Ready)}.

custody_ready_index(Custody) ->
    gb_sets:from_list(
      [{Change#transaction.author_seq, SubmissionId}
       || {SubmissionId, #custody{placement = ready,
                                  change = Change}} <-
              maps:to_list(Custody)]).

%% Event-driven, work-conserving drain. One pass considers every item that was queued
%% at entry. An ordinary blocked item does not stop unrelated authors: it is held while
%% later authors are considered. Once one item for an author blocks, every later item
%% from that author is held too, preserving signed author-sequence order. Membership is
%% deliberately global: an in-flight membership barrier or a queued membership change
%% stops the pass so the pipeline must quiesce and the committee transition cannot
%% starve. Held items retain their relative order, so TTL expiry remains oldest-first.
-ifdef(TEST).
drain_ingress(S, Fingerprint) ->
    {S1, ActionsRev} =
        drain_ingress_rev(S, Fingerprint, []),
    {S1, lists:reverse(ActionsRev)}.
-endif.

drain_ingress_rev(S, RouteFingerprint, ActionsRev0) ->
    Remaining = quod_ingress_state:count(S#s.ingress),
    {S1, ActionsRev1, N} =
        drain_loop(
          S, Remaining, #{}, [], ActionsRev0, 0),
    SView = refresh_ingress_view(S1),
    case N > 0
         andalso quod_ingress_state:count(SView#s.ingress) > 0 of
        true ->
            NextRouteFingerprint =
                quod_ingress_state:route_fingerprint(
                  SView#s.ingress),
            case NextRouteFingerprint =/= RouteFingerprint of
                true ->
                    drain_ingress_rev(
                      SView, NextRouteFingerprint, ActionsRev1);
                false ->
                    {SView, ActionsRev1}
            end;
        false ->
            {SView, ActionsRev1}
    end.

drain_loop(S, 0, _BlockedAuthors, HeldRev, ActionsRev, N) ->
    {S1, ActionsRev1} =
        seal_drained_rev(
          restore_held(S, HeldRev), ActionsRev, N),
    {S1, ActionsRev1, N};
drain_loop(S = #s{ingress = Ingress}, Remaining, BlockedAuthors,
           HeldRev, ActionsRev, N) ->
    {Item, Ingress1} =
        quod_ingress_state:detach_front(Ingress),
    {QueuedContext, Waiter, Request, Anchor} =
        quod_ingress_state:item(Item),
    Change = quod_ingress_state:request_change(Request),
    Author = Change#transaction.author,
    Origin = QueuedContext,
    SWithoutHead = S#s{ingress = Ingress1},
    case maps:is_key(Author, BlockedAuthors) of
        true ->
            drain_loop(SWithoutHead, Remaining - 1, BlockedAuthors,
                       [Item | HeldRev], ActionsRev, N);
        false ->
            {Decision, RoutedRequest, SRoute} =
                ingress_route_request(
                  drain, Origin, Request, SWithoutHead),
            case Decision of
                {park, barrier} ->
                    {S1, ActionsRev1} =
                        seal_drained_rev(
                          restore_held(SRoute, [Item | HeldRev]),
                          ActionsRev, N),
                    {S1, ActionsRev1, N};
                {park, _Cause} ->
                    case quod_ingress_state:request_membership(
                           RoutedRequest) of
                        true ->
                            {S1, ActionsRev1} =
                                seal_drained_rev(
                                  restore_held(SRoute, [Item | HeldRev]),
                                  ActionsRev, N),
                            {S1, ActionsRev1, N};
                        false ->
                            drain_loop(SRoute, Remaining - 1,
                                       BlockedAuthors#{Author => true},
                                       [Item | HeldRev], ActionsRev, N)
                    end;
                _ ->
                    ConsumedIngress =
                        quod_ingress_state:consume_detached(
                          Item, SRoute#s.ingress),
                    SConsumed =
                        SRoute#s{ingress = ConsumedIngress},
                    _ = quod_trace:add_event(
                          waiter_trace_ctx(Waiter), <<"consensus.drained">>,
                          #{'quod.ingress.depth' =>
                                quod_ingress_state:count(
                                  ConsumedIngress)}),
                    {S2, Actions} =
                        execute(
                          drain, Origin, Waiter, RoutedRequest,
                          Anchor, Decision, SConsumed),
                    drain_loop(S2, Remaining - 1, BlockedAuthors, HeldRev,
                               lists:reverse(Actions, ActionsRev), N + 1)
            end
    end.

restore_held(S, []) ->
    S;
restore_held(S = #s{ingress = Ingress}, HeldRev) ->
    %% No callback can append concurrently while this gen_statem event is running.
    %% The queue contains only entries not part of this pass (normally none).
    S#s{
      ingress =
          quod_ingress_state:restore_detached_front_rev(
            HeldRev, Ingress)}.

%% A multi-item drain seals its batch NOW: the backlog already waited a full flight, a
%% configured window would only re-add latency (block N+1 = what arrived during block N
%% is already the natural batch). A SINGLETON drain keeps the normal micro-batch window so relays
%% landing in the same slot-open moment can still join it.
seal_drained_rev(
  S = #s{collecting = #batch{slot = Slot}}, ActionsRev, N)
  when N >= 2 ->
    {flush_batch(Slot, S),
     [{{timeout, batch}, cancel} | ActionsRev]};
seal_drained_rev(S, ActionsRev, _N) ->
    {S, ActionsRev}.

%% A canonical route change or useful queue-work revision wakes the bounded
%% scan. Same-author tail appends do not: the item that blocked that author
%% blocks its successors too. Raw consensus changes that project to the same
%% route view remain O(1).
ingress_drain_decision(Before, After) ->
    case quod_ingress_state:count(After) of
        0 ->
            none;
        _ ->
            Fingerprint =
                quod_ingress_state:fingerprint(After),
            case quod_ingress_state:fingerprint(Before)
                     =:= Fingerprint of
                true  -> none;
                false ->
                    {drain,
                     quod_ingress_state:route_fingerprint(After)}
            end
    end.

custody_drain_decision(
  Before, After, Ready) ->
    case gb_sets:is_empty(Ready) of
        true ->
            none;
        false ->
            Fingerprint =
                quod_ingress_state:custody_fingerprint(After),
            case quod_ingress_state:custody_fingerprint(Before)
                     =:= Fingerprint of
                true  -> none;
                false -> {drain, Fingerprint}
            end
    end.

%% A committed committee transition invalidates every still-active placement
%% created under the prior view, even when the same target remains a member.
%% Likewise, a lane at or below the durable head is authoritatively excluded.
%% Only mark here; `keep_progress/3` drains after all commit/recovery projection
%% updates for the event have settled.
reconcile_custody_lane(
  S = #s{custody_lane = empty}) ->
    %% Lane retirement atomically rebuilds the sole ready index. Do no custody
    %% map scan here: this hook runs for every vote, relay, and timer event.
    S;
reconcile_custody_lane(
  S = #s{custody_lane =
             {Target, TargetSlot, PlacementCommitteeId},
         committee_id = CurrentCommitteeId,
         slot = DurableHead}) ->
    Obsolete =
        PlacementCommitteeId =/= CurrentCommitteeId
        orelse TargetSlot =< DurableHead
        orelse not lists:member(Target, active_validators(S)),
    case Obsolete of
        false ->
            S;
        true ->
            mark_custody_lane_ready(S)
    end.

%% Retire a whole lane in one bounded pass. Every retained record is then ready,
%% so build the sole ordered index once and remove only relay attempts named by
%% those records. There is no per-record gb_set insertion or redundant sort.
mark_custody_lane_ready(
  S = #s{custody = Custody, relay_pending = Pending}) ->
    {Custody1, Pending1, ReadyKeys} =
        maps:fold(
          fun(SubmissionId,
              Record = #custody{placement = Placement,
                                change = Change},
              {CustodyAcc, PendingAcc, KeysAcc}) ->
                  PendingNext =
                      case Placement of
                          {relay, AttemptId, _Target,
                           _Slot, _CommitteeId} ->
                              maps:remove(AttemptId, PendingAcc);
                          _ ->
                              PendingAcc
                      end,
                  {CustodyAcc#{
                     SubmissionId =>
                         Record#custody{placement = ready}},
                   PendingNext,
                   [{Change#transaction.author_seq,
                     SubmissionId} | KeysAcc]}
          end, {#{}, Pending, []}, Custody),
    S#s{custody = Custody1,
        custody_lane = empty,
        custody_ready = gb_sets:from_list(ReadyKeys),
        relay_pending = Pending1}.

collecting_gate(none) ->
    none;
collecting_gate(#batch{slot = Slot, count = Count, bytes = Bytes}) ->
    {Slot, Count, Bytes}.

%% FIFO + one lifetime make expiry O(expired), free when the head is fresh.
%% Other waiter containers have independent lifecycles and are never swept here.
expire_ingress(S = #s{ingress = Ingress}) ->
    case quod_ingress_state:count(Ingress) of
        0 ->
            S;
        _ ->
            expire_ingress(
              quod_time:mono_ms() - ?INGRESS_TTL_MS, S)
    end.

expire_ingress(Cutoff, S = #s{ingress = Ingress}) ->
    {Expired, Ingress1} =
        quod_ingress_state:take_expired(
          Cutoff, Ingress),
    lists:foldl(
      fun(Item, Acc) ->
              {_Origin, Waiter, _Request, _Anchor} =
                  quod_ingress_state:item(Item),
              _ = quod_trace:add_event(
                    waiter_trace_ctx(Waiter),
                    <<"consensus.expired">>, #{}),
              Acc1 =
                  reply_waiter(
                    Waiter, {error, busy}, Acc),
              Acc1#s{
                ingress_expired =
                    Acc1#s.ingress_expired + 1,
                r_busy = Acc1#s.r_busy + 1}
      end, S#s{ingress = Ingress1}, Expired).

%% Custody lifetimes are anchored at the original unsigned arrival and never
%% reset by retargeting. The ordered deadline index is updated on both insert
%% and completion, so its size is always bounded by live custody.
expire_custody(S) ->
    expire_custody(quod_time:mono_ms(), S).

expire_custody(
  Now, S = #s{custody_deadlines = Deadlines,
              custody = Custody}) ->
    case gb_sets:is_empty(Deadlines) of
        true ->
            S;
        false ->
            DeadlineKey = {Deadline, SubmissionId} =
                gb_sets:smallest(Deadlines),
            case Deadline =< Now of
                false ->
                    S;
                true ->
                    case maps:get(SubmissionId, Custody, undefined) of
                        #custody{deadline = Deadline} ->
                            expire_custody(
                              Now,
                              complete_custody(
                                SubmissionId,
                                {error, not_in_charge, unavailable}, S));
                        _ ->
                            expire_custody(
                              Now,
                              S#s{custody_deadlines =
                                      gb_sets:del_element(
                                        DeadlineKey, Deadlines)})
                    end
            end
    end.

redirect_append(From, Leader, S) ->
    reply_now(From, {error, not_in_charge, Leader},
              S#s{r_redirect = S#s.r_redirect + 1}).

reply_now(
  #waiter{reply_to = {custody, SubmissionId}}, Reply, S) ->
    case release_custody(SubmissionId, S) of
        {ok, Waiter, Attempts, S1} ->
            observe_custody_hops(S#s.ns, Attempts),
            reply_now(Waiter, Reply, S1);
        error ->
            {S, []}
    end;
reply_now(Waiter = #waiter{reply_to = {relay, #relay_ref{}}}, Reply, S) ->
    {reply_waiter(Waiter, Reply, S), []};
reply_now(Waiter = #waiter{reply_to = From}, Reply, S) ->
    finish_waiter_trace(Waiter, Reply),
    {S, [{reply, From, Reply}]};
reply_now({relay, RelayRef = #relay_ref{}}, Reply, S) ->
    {reply_relay(RelayRef, Reply, S), []}.

%% `Anchor` = the submission's ORIGINAL arrival time (mono ms): a drained item's park
%% wait counts against the relay cleanup deadline. The caller may stop waiting first
%% and receive `outcome_unknown`; pending state then remains briefly so a racing
%% local finality event can still classify the attempt before bounded cleanup.
relay_append(From, Leader, TargetSlot, Change, Anchor,
             S) ->
    relay_append(From, Leader, TargetSlot, Change, Anchor, S, undefined).

relay_append(From, Leader, TargetSlot, Change, Anchor,
             S = #s{ns = Ns, relay_pending = Pending,
                    relay_timeout_ms = RelayTimeout,
                    committee_id = CommitteeId}, CustodyId) ->
    case relay_submission(CustodyId, Ns, Change, S) of
        {error, _} when is_binary(CustodyId) ->
            %% A stale internal custody marker has no client-owned operation
            %% left to classify and must not mint a malformed-workload reject.
            {S, []};
        {error, _} ->
            reject_append(From, bad_change, S);
        {ok, Submission} ->
            SubmissionId = quod_transaction:submission_id(Submission),
            TraceCtx = waiter_trace_ctx(From),
            case outbound_relay(
                   Ns, SubmissionId, CommitteeId, TargetSlot,
                   Leader, Submission, quod_trace:inject(TraceCtx)) of
                error ->
                    %% A missing/malformed committee view cannot create a
                    %% placement whose identity would be ambiguous. Retained
                    %% content waits for a valid route view; membership keeps
                    %% its terminal contract.
                    case CustodyId of
                        undefined ->
                            reply_now(
                              From,
                              {error, not_in_charge, unavailable}, S);
                        _ ->
                            {defer_custody_placement(CustodyId, S), []}
                    end;
                {ok, AttemptId, Frame} ->
                    case {maps:is_key(AttemptId, Pending),
                          map_size(Pending) >= ?MAX_RELAY_PENDING} of
                        {true, _} when is_binary(CustodyId) ->
                            %% A stale/idempotent attempt collision cannot
                            %% release retained content or classify it as bad.
                            {defer_custody_placement(CustodyId, S), []};
                        {true, _} ->
                            reject_append(From, bad_change, S);
                        {false, true} when is_binary(CustodyId) ->
                            %% Capacity pressure cannot erase an already-signed
                            %% retained operation or turn it into a public retry.
                            {defer_custody_placement(CustodyId, S), []};
                        {false, true} ->
                            reject_append(From, busy, S);
                        {false, false} ->
                            Relay = #relay_pending{
                                       from = From, target = Leader,
                                       target_slot = TargetSlot,
                                       author_seq =
                                           Change#transaction.author_seq,
                                       submission_id = SubmissionId,
                                       attempt_id = AttemptId,
                                       committee_id = CommitteeId,
                                       frame = Frame,
                                       deadline =
                                           custody_deadline(
                                             CustodyId,
                                             Anchor + RelayTimeout, S),
                                       next_retry =
                                           quod_time:mono_ms()
                                           + ?RELAY_RETRY_MS},
                            case put_pending_relay(
                                   AttemptId, Relay, Pending) of
                                {error, Conflict} ->
                                    logger:error(
                                      "quod[~s]: refusing divergent relay lane: ~0p",
                                      [Ns, Conflict]),
                                    case CustodyId of
                                        undefined ->
                                            %% Membership changes deliberately
                                            %% retain their terminal re-proof
                                            %% contract.
                                            reply_now(
                                              From, {error, skipped}, S);
                                        _ ->
                                            %% A divergent pending lane is
                                            %% placement state, never durable
                                            %% exclusion of retained content.
                                            {defer_custody_placement(
                                               CustodyId, S),
                                             []}
                                    end;
                                {ok, Pending1} ->
                                    SWithPending =
                                        S#s{relay_pending = Pending1},
                                    case place_relay_custody(
                                           CustodyId, AttemptId, Leader,
                                           TargetSlot, CommitteeId,
                                           SWithPending) of
                                        {conflict, SConflict} ->
                                            {defer_custody_placement(
                                               CustodyId,
                                               remove_pending_relay(
                                                 AttemptId, SConflict)),
                                             []};
                                        {error, SBad}
                                          when is_binary(CustodyId) ->
                                            %% Missing internal custody cannot
                                            %% be a client bad_change. Remove
                                            %% only the provisional attempt.
                                            {remove_pending_relay(
                                               AttemptId, SBad),
                                             []};
                                        {error, SBad} ->
                                            reject_append(
                                              From, bad_change,
                                              remove_pending_relay(
                                                AttemptId, SBad));
                                        {ok, SPlaced} ->
                                            _ = quod_trace:add_event(
                                                  TraceCtx,
                                                  <<"consensus.relayed">>,
                                                  #{'quod.relay.target' =>
                                                        trace_node_id(Leader)}),
                                            S1 = send_relay_submission(
                                                   Leader, Frame, SPlaced),
                                            {S1, []}
                                    end
                            end
                    end
            end
    end.

relay_submission(undefined, Ns, Change, _S) ->
    quod_transaction:submission(Ns, Change);
relay_submission(
  SubmissionId, _Ns, _Change,
  #s{custody = Custody}) when is_binary(SubmissionId) ->
    case maps:get(SubmissionId, Custody, undefined) of
        #custody{submission = Submission} ->
            {ok, Submission};
        undefined ->
            {error, missing_custody}
    end.

custody_deadline(undefined, Default, _S) ->
    Default;
custody_deadline(
  SubmissionId, Default, #s{custody = Custody}) ->
    case maps:get(SubmissionId, Custody, undefined) of
        #custody{deadline = Deadline} -> Deadline;
        undefined -> Default
    end.

place_relay_custody(undefined, _AttemptId, _Target, _TargetSlot,
                    _CommitteeId, S) ->
    {ok, S};
place_relay_custody(SubmissionId, AttemptId, Target, TargetSlot,
                    CommitteeId, S) ->
    place_custody(
      SubmissionId,
      {relay, AttemptId, Target, TargetSlot, CommitteeId}, S).

outbound_relay(Ns, SubmissionId, CommitteeId, TargetSlot, Target,
               Submission, TraceCarrier) ->
    case quod_transaction:relay_attempt_id(
           Ns, SubmissionId, CommitteeId, TargetSlot, Target) of
        AttemptId when is_binary(AttemptId) ->
            Frame =
                quod_relay:encode(
                  Ns, {relay_submit, SubmissionId, AttemptId,
                       CommitteeId, TargetSlot, Submission, TraceCarrier}),
            {ok, AttemptId, Frame};
        error ->
            error
    end.

%% There is one outbound author per node, so all unresolved requests deliberately
%% share one exact target and slot. Enforce that invariant at the only creation
%% point in O(1); later updates preserve both fields and removals cannot violate it.
put_pending_relay(AttemptId,
                  Relay = #relay_pending{target = Target,
                                         target_slot = TargetSlot,
                                         committee_id = CommitteeId},
                  Pending) ->
    case maps:next(maps:iterator(Pending)) of
        none ->
            {ok, Pending#{AttemptId => Relay}};
        {_ExistingAttemptId,
         #relay_pending{target = Target, target_slot = TargetSlot,
                        committee_id = CommitteeId},
         _Iter} ->
            {ok, Pending#{AttemptId => Relay}};
        {_ExistingAttemptId,
         #relay_pending{target = ExistingTarget,
                        target_slot = ExistingSlot,
                        committee_id = ExistingCommitteeId},
         _Iter} ->
            {error, {relay_lane_conflict,
                     {ExistingTarget, ExistingSlot, ExistingCommitteeId},
                     {Target, TargetSlot, CommitteeId}}}
    end.

%% A depth-one pipeline permits proposing H+2 after H+1 is approved but before it
%% commits. It stops there until commit catches up. Membership blocks are barriers,
%% and a complaint-finalized slot waiting behind an earlier commit is not reopened.
proposal_slot(S = #s{}) ->
    proposal_slot(S, membership_barrier(S)).

proposal_slot(#s{slot = Committed, approved = Approved,
                 collecting = Collecting,
                 local_proposals = Local, commit_buf = Buf},
              MembershipBarrier) ->
    Next = Approved + 1,
    HasBatch = case Collecting of #batch{slot = Next} -> true; _ -> false end,
    Open = live_pipeline_slot(Next, Committed)
           andalso (HasBatch orelse not maps:is_key(Next, Local))
           andalso not maps:is_key(Next, Buf)
           andalso not MembershipBarrier,
    case Open of true -> {ok, Next}; false -> blocked end.

%% One definition owns the complete volatile consensus window: the durable head's successor plus the
%% configured number of approved descendants. Proposal admission, final-vote selection, block recovery,
%% and its metrics must never drift onto different slot ranges.
-spec live_pipeline_slot(slot(), slot()) -> boolean().
live_pipeline_slot(Slot, Committed) ->
    Slot > Committed andalso Slot =< Committed + ?PIPELINE_DEPTH + 1.

%% Capacity and membership gating live in `quod_ingress_state` — inadmissible
%% work parks rather than rejecting. Only CONTENT verdicts remain here: a sequence below
%% the floor is `stale_seq` (retryable — newer approved history won first, while the
%% content remains valid), and a duplicate tx_id is `bad_change` (terminal).
collect_append(
  From, Change, Membership, Slot,
  S = #s{collecting = none})
  when is_boolean(Membership) ->
    Bytes = ?BATCH_ENVELOPE_BYTES + encoded_change_size(Change),
    case approved_author_seqs(S) of
        error ->
            reject_append(From, stale_seq, S);
        {ok, SequenceFloor} ->
            case advance_transaction_sequence(
                   Change, SequenceFloor, #{}) of
                error ->
                    reject_append(From, stale_seq, S);
                {ok, Sequences} ->
                    _ = quod_trace:add_event(
                          waiter_trace_ctx(From), <<"consensus.queued">>,
                          #{'quod.consensus.slot' => Slot}),
                    TxId = Change#transaction.tx_id,
                    Batch = #batch{
                               slot = Slot, parent = S#s.approved,
                               items_rev = [{From, Change}], count = 1,
                               bytes = Bytes, tx_ids = #{TxId => true},
                               sequences = Sequences,
                               sequence_floor = SequenceFloor,
                               opened_at = quod_time:mono_ms()},
                    S1 = S#s{collecting = Batch,
                             appends = S#s.appends + 1},
                    case Membership
                             orelse S#s.batch_window_ms =:= 0 of
                        true ->
                            {flush_batch(Slot, S1),
                             [{{timeout, batch}, cancel}]};
                        false ->
                            {S1,
                             [{{timeout, batch}, S#s.batch_window_ms,
                               {flush_batch, Slot}}]}
                    end
            end
    end;
collect_append(From, Change, _Membership, Slot,
               S = #s{collecting = #batch{slot = Slot, items_rev = Items,
                                          count = Count, bytes = Bytes,
                                          tx_ids = TxIds,
                                          sequences = Sequences,
                                          sequence_floor = SequenceFloor} = Batch}) ->
    Added = encoded_change_size(Change),
    TxId = Change#transaction.tx_id,
    case maps:is_key(TxId, TxIds) of
        true ->
            reject_append(From, bad_change, S);
        false ->
            case advance_transaction_sequence(
                   Change, SequenceFloor, Sequences) of
                error ->
                    reject_append(From, stale_seq, S);
                {ok, Sequences1} ->
                    _ = quod_trace:add_event(
                          waiter_trace_ctx(From), <<"consensus.queued">>,
                          #{'quod.consensus.slot' => Slot}),
                    Batch1 =
                        Batch#batch{
                          items_rev = [{From, Change} | Items],
                          count = Count + 1, bytes = Bytes + Added,
                          tx_ids = TxIds#{TxId => true},
                          sequences = Sequences1},
                    S1 = S#s{
                           collecting = Batch1,
                           appends = S#s.appends + 1},
                    case Batch1#batch.count >= ?MAX_BATCH_TXS of
                        true ->
                            {flush_batch(Slot, S1),
                             [{{timeout, batch}, cancel}]};
                        false ->
                            {S1, []}
                    end
            end
    end.

advance_transaction_sequence(
  #transaction{author = Author, author_seq = Seq},
  SequenceFloor, Seen)
  when is_integer(Seq), Seq > 0 ->
    Key = {Author, Seq},
    case Seq > maps:get(Author, SequenceFloor, 0)
             andalso not maps:is_key(Key, Seen) of
        true  -> {ok, Seen#{Key => true}};
        false -> error
    end;
advance_transaction_sequence(_Change, _SequenceFloor, _Seen) ->
    error.

flush_batch(Slot, S = #s{collecting = #batch{slot = Slot, parent = Parent,
                                              items_rev = ItemsRev,
                                              count = Count,
                                              opened_at = OpenedAt}}) ->
    Items = lists:reverse(ItemsRev),
    Payload = [Change || {_From, Change} <- Items],
    case acceptable_collected_payload(Payload, S) of
        false -> reject_collected_batch(Items, Count, S);
        true  -> propose_batch(Slot, Parent, Items, Payload, Count,
                               max(0, quod_time:mono_ms() - OpenedAt), S)
    end;
flush_batch(_Slot, S) -> S.   %% stale named timeout after an early/full flush

propose_batch(Slot, Parent, Items, Payload, Count, WaitMs, S) ->
    Waiters = [From || {From, _Change} <- Items],
    Block = #block{slot = Slot, parent = Parent, payload = Payload,
                   timestamp = max(quod_time:now_ms(), parent_timestamp(Parent, S))},
    BH = block_hash(Block),
    lists:foreach(
      fun({Waiter, _Change}) ->
              quod_trace:add_event(
                waiter_trace_ctx(Waiter), <<"consensus.proposed">>,
                #{'quod.consensus.slot' => Slot,
                  'quod.batch.transactions' => Count,
                  'quod.batch.wait_ms' => WaitMs})
      end, Items),
    quod_metrics:observe_batch(S#s.ns, Count, WaitMs),
    Local = #local_proposal{hash = BH, waiters = Waiters,
                            trace_ctxs = [waiter_trace_ctx(W) || W <- Waiters]},
    S1 = S#s{collecting = none,
             local_proposals = (S#s.local_proposals)#{Slot => Local},
             proposals = S#s.proposals + 1,
             batched_txs = S#s.batched_txs + Count,
             round_probe = (S#s.round_probe)#{Slot => {quod_time:mono_ms(), none}}},
    S2 = broadcast({propose, Block}, S1),
    S3 = engine_step([{block, BH, Block}], S2),
    case block_for(BH, S3#s.eng) of
        #block{} -> watch_proposal(Slot, support_or_validate(Block, BH, S3));
        undefined -> S3
    end.

reject_collected_batch(Items, Count, S) ->
    S1 = reply_waiters([From || {From, _Change} <- Items],
                       {error, bad_change}, S),
    S1#s{collecting = none, r_bad = S1#s.r_bad + Count}.

encoded_change_size(Change) ->
    byte_size(term_to_binary(Change, [deterministic])).

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
    timed_step(S, engine, fun() ->
        {Eng1, EventsRev} = lists:foldl(fun(It, {E, Acc}) ->
                                            {E1, Es} = offer_engine_item(It, E),
                                            {E1, lists:reverse(Es, Acc)}
                                        end, {S#s.eng, []}, Items),
        apply_events(lists:reverse(EventsRev), S#s{eng = Eng1})
    end).

offer_engine_item({block, BH, #block{} = B}, Eng) -> eng_offer_hashed(BH, B, Eng);
offer_engine_item(Item, Eng) -> eng_offer(Item, Eng).

apply_events([], S)             -> S;
apply_events([Event | Rest], S) -> apply_events(Rest, apply_event(Event, S)).

%% A newly-formed (or first-learned) cert: disseminate it to the committee (§2.3.1).
apply_event({broadcast, Cert}, S) ->
    broadcast({cert, Cert}, S);
%% A block was notarized: sign + emit our commit share — UNLESS we already complaint-signed this slot
%% (`may_commit` guard) OR we judged this exact membership block INVALID (`#round.invalid`). Recording
%% the round's `commit` latch makes the symmetric `may_complain` guard hold, so an honest node contributes to at
%% most one of {commit cert, complaint cert} per slot — the safety rule. The hash-scoped `invalid` guard is
%% belt-and-braces: a node that evaluated a membership proposal and rejected that block never endorses it at
%% ANY phase. It cannot poison a different quorum-certified block after leader equivocation.
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
    %% `collect_append` clause and crash the statem. The slot is now decided at
    %% the approval layer, so discard the obsolete collection before advancing;
    %% retained content waits for durable exclusion, while membership keeps its
    %% terminal retry contract.
    S1 = nack_collecting_le(Sl, S),
    watch_notarized(Sl, probe_approved(Sl, S1#s{approved = max(Approved, Sl)})).

%% ---- Round-phase probe: where does a consensus round spend its time? -------
%% Stamped in propose_batch, marked here at support-quorum approval, observed at
%% commit, pruned in finalize/2 (which both the commit and skip paths run). Own
%% proposals only, single monotonic clock on this node — the same discipline as
%% the tx-latency histogram: never a cross-node timestamp difference.
probe_approved(Sl, S = #s{round_probe = Probe}) ->
    case Probe of
        #{Sl := {ProposedAt, none}} ->
            Now = quod_time:mono_ms(),
            quod_metrics:observe_round_phase(S#s.ns, approve, Now - ProposedAt),
            S#s{round_probe = Probe#{Sl => {ProposedAt, Now}}};
        _ ->
            S   %% not ours, or approval already seen (re-offered cert)
    end.

probe_committed(Sl, S = #s{round_probe = Probe}) ->
    case Probe of
        #{Sl := {_ProposedAt, ApprovedAt}} when is_integer(ApprovedAt) ->
            quod_metrics:observe_round_phase(
              S#s.ns, commit, quod_time:mono_ms() - ApprovedAt);
        _ ->
            ok   %% not ours, or committed without a local approval mark (catch-up)
    end,
    S.

probe_prune(Sl, S = #s{round_probe = Probe}) when map_size(Probe) > 0 ->
    S#s{round_probe = maps:filter(fun(K, _) -> K > Sl end, Probe)};
probe_prune(_Sl, S) ->
    S.

%% Persist the committed block (durable before we ack), apply it into quod_prolog, advance the height,
%% clear the per-slot latches, and reply `{ok, Slot}` to every caller in the batch.
commit_block(Slot, #block{payload = Payload, timestamp = BlockTs}, S = #s{store = Store, eng = Eng}) ->
    BH = engine_block_hash(Slot, S),
    case persisted_finality(Slot, BH, Eng) of
        none -> weak_cert_wait(commit, Slot, BH, S);   %% Slice E: don't finalize on a sub-quorum cert
        Cert ->
            Data = quod_ledger:data(Payload),
            E = #entry{index = Slot, data = Data, timestamp = BlockTs, cert = Cert},
            {ok, Store1} = timed_step(S, persist,
                                      fun() -> persist_entry(Store, E, Slot, S) end),
            timed_step(S, feed, fun() -> publish_feed(Slot, E, S) end),
            SCommitted = timed_step(S, resolve, fun() ->
                             resolve_committed_submissions(
                               Payload, Slot,
                               S#s{store = Store1,
                                   commits = S#s.commits + 1,
                                   last_ts = max(S#s.last_ts, BlockTs),
                                   author_seqs =
                                       advance_author_seqs(
                                         Payload,
                                         S#s.author_seqs)})
                         end),
            S0 = ack_local(Slot, probe_committed(Slot, SCommitted)),
            %% Capture the hash while the finalized block is still present in the
            %% engine. finalize/2 prunes that tree entry before the committee view
            %% crosses its adoption boundary.
            S1 = adopt_committee(Data, Slot, BH, finalize(Slot, S0)),
            timed_step(S, apply, fun() -> apply_live(Slot, Data, confirm_live(S1)) end)
    end.

persist_entry(Store, Entry, Slot, S) ->
    quod_trace:with_optional_span(
      trace_context_for_slot(Slot, S), <<"quod.ledger.sync">>, internal,
      #{'quod.namespace' => S#s.ns, 'quod.consensus.slot' => Slot},
      fun() -> quod_ledger_store:append(Store, [Entry]) end).

resolve_committed_submissions(
  _Payload, _Slot,
  S = #s{custody = Custody, relay_pending = Pending})
  when map_size(Custody) =:= 0, map_size(Pending) =:= 0 ->
    S;
resolve_committed_submissions(Payload, Slot, S = #s{ns = Ns}) ->
    Included = payload_submission_ids(Ns, Payload),
    resolve_committed_relays(
      Included, Slot,
      resolve_committed_custody(Included, Slot, S)).

resolve_committed_custody(
  _Included, _Slot, S = #s{custody = Custody})
  when map_size(Custody) =:= 0 ->
    S;
resolve_committed_custody(Included, Slot, S) ->
    maps:fold(
      fun(SubmissionId, _Present, Acc) ->
              complete_custody(
                SubmissionId, {ok, Slot}, Acc)
      end, S, Included).

resolve_committed_relays(_Included, _Slot, S = #s{relay_pending = Pending})
  when map_size(Pending) =:= 0 ->
    S;
resolve_committed_relays(Included, Slot, S = #s{relay_pending = Pending}) ->
    maps:fold(
      fun(Key, #relay_pending{from = From,
                             submission_id = SubmissionId}, Acc) ->
              case maps:is_key(SubmissionId, Included) of
                  true ->
                      reply_waiter(
                        From, {ok, Slot},
                        remove_pending_relay(Key, Acc));
                  false ->
                      Acc
              end
      end, S, Pending).

payload_submission_ids(Ns, Payload) ->
    maps:from_keys(
      [quod_transaction:submission_id(Submission)
       || Transaction <- Payload,
          {ok, Submission} <-
              [quod_transaction:submission(Ns, Transaction)]],
      true).

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
adopt_committee(Change, Slot, BlockHash,
                S = #s{ns = Ns, validators = V, committee_id = CommitteeId,
                       self = Self, eng = Eng}) ->
    {V1, CommitteeId1} =
        advance_committee_view(
          Ns, Slot, BlockHash, Change, V, CommitteeId),
    case V1 =:= V of
        true -> S;                                   %% no `peer_admitted` change → facts/view unchanged
        false -> %% learn the fresh admit-fact address (OVERWRITE): the change just passed quorum-many
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
              S1 = prune_consensus_links(
                     S#s{validators = V1, committee_id = CommitteeId1}),
                                                            %% FACTS/view + transport scope advance
              S1#s{eng = eng_set_validators(active_validators(S1), Eng)}   %% engine tracks the active set
    end.

%% A complaint cert skipped this slot: persist an empty `noop` entry so the
%% store height advances contiguously. Ordinary custody ignores the provisional
%% nack and is marked ready by durable finalization; non-custodied membership
%% callers retain their terminal re-proof response. `quod_prolog` applies a
%% `noop` as a pure cursor advance.
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
    SCollected = nack_collecting_le(Slot, S0),
    SExcluded = mark_custody_excluded_le(Slot, SCollected),
    S = probe_prune(Slot, nack_relays_le(Slot, SExcluded)),
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

%% A batch still being collected (not yet sealed into a proposal) parks its
%% callers with no reply. If its slot finalizes first, the batch is discarded.
%% Custody markers ignore this provisional `skipped`; durable finalization marks
%% their exact submissions ready. Membership callers retain the terminal reply.
%% Recovery reuses the same cleanup through `nack_inflight/3`.
nack_collecting_le(Slot, S = #s{collecting = #batch{slot = Sl}}) when Sl =< Slot -> nack_collecting(S);
nack_collecting_le(_Slot, S) -> S.

%% Exact-slot relay ownership ends with that slot. Inclusion was already
%% resolved by SubmissionId. Ordinary custody was marked ready above, so
%% removing its attempt emits no public reply; non-custodied membership retains
%% the terminal `skipped` result.
nack_relays_le(Slot, S = #s{relay_pending = Pending}) ->
    maps:fold(
      fun(AttemptId, #relay_pending{from = From, target_slot = TargetSlot}, Acc)
            when TargetSlot =< Slot ->
              finish_relay(AttemptId, From, {error, skipped}, Acc);
         (_AttemptId, _Relay, Acc) ->
              Acc
      end, S, Pending).

mark_custody_excluded_le(
  _Slot, S = #s{custody_lane = empty}) ->
    S;
mark_custody_excluded_le(
  Slot,
  S = #s{custody_lane = {_Target, TargetSlot, _CommitteeId}})
  when TargetSlot =< Slot ->
    mark_custody_lane_ready(S);
mark_custody_excluded_le(_Slot, S) ->
    S.

mark_custody_ready(
  SubmissionId,
  S = #s{custody = Custody, custody_ready = Ready}) ->
    case maps:get(SubmissionId, Custody, undefined) of
        #custody{placement = ready} ->
            S;
        #custody{} = Record ->
            S1 = retire_custody_placement(
                   SubmissionId, Record, S),
            Custody1 = S1#s.custody,
            ReadyKey =
                {(Record#custody.change)#transaction.author_seq,
                 SubmissionId},
            S1#s{custody =
                     Custody1#{SubmissionId =>
                                   Record#custody{placement = ready}},
                 custody_ready =
                     gb_sets:add_element(ReadyKey, Ready)};
        undefined ->
            S
    end.

nack_collecting(S = #s{collecting = #batch{items_rev = Items}}) ->
    S1 = reply_waiters([From || {From, _Change} <- Items],
                       {error, skipped}, S),
    S1#s{collecting = none}.

reply_waiters(Waiters, Reply, S) ->
    lists:foldl(fun(Waiter, Acc) -> reply_waiter(Waiter, Reply, Acc) end,
                S, Waiters).

reply_waiter(
  #waiter{reply_to = {custody, _SubmissionId}},
  {error, skipped}, S) ->
    %% Slot displacement/notarization is not authoritative exclusion. The
    %% durable finalization path marks custody ready after the whole committed
    %% prefix and committee transition settle.
    S;
reply_waiter(
  #waiter{reply_to = {custody, SubmissionId}},
  Reply, S) ->
    complete_custody(SubmissionId, Reply, S);
reply_waiter(Waiter = #waiter{reply_to = ReplyTo}, Reply, S) ->
    finish_waiter_trace(Waiter, Reply),
    reply_waiter(ReplyTo, Reply, S);
reply_waiter({relay, RelayRef = #relay_ref{}}, Reply, S) ->
    reply_relay(RelayRef, Reply, S);
reply_waiter(From, Reply, S) ->
    gen_statem:reply(From, Reply),
    S.

complete_custody(SubmissionId, Reply, S) ->
    case release_custody(SubmissionId, S) of
        {ok, Waiter, Attempts, S1} ->
            observe_custody_hops(S#s.ns, Attempts),
            reply_waiter(Waiter, Reply, S1);
        error ->
            S
    end.

release_custody(
  SubmissionId, S = #s{custody = Custody}) ->
    case maps:take(SubmissionId, Custody) of
        {Record = #custody{waiter = Waiter, placement = Placement,
                  change = Change, deadline = Deadline,
                  attempts = Attempts, bytes = Bytes},
         Custody1} ->
            S1 = retire_custody_placement(
                   SubmissionId, Record, S),
            Ready1 =
                case Placement of
                    ready ->
                        gb_sets:del_element(
                          {Change#transaction.author_seq, SubmissionId},
                          S1#s.custody_ready);
                    _ ->
                        S1#s.custody_ready
                end,
            {ok, Waiter, Attempts,
             S1#s{custody = Custody1,
                  custody_ready = Ready1,
                  custody_deadlines =
                      gb_sets:del_element(
                        {Deadline, SubmissionId},
                        S1#s.custody_deadlines),
                  custody_bytes = S1#s.custody_bytes - Bytes}};
        error ->
            error
    end.

observe_custody_hops(Ns, Attempts) ->
    quod_metrics:observe_ingress_retarget_hops(
      Ns, max(0, Attempts - 1)).

retire_custody_placement(
  _SubmissionId, #custody{placement = ready}, S) ->
    S;
retire_custody_placement(
  _SubmissionId,
  #custody{placement = Placement},
  S = #s{custody = Custody, custody_ready = Ready}) ->
    %% At stable boundaries custody is partitioned into placed records and the
    %% sole ordered ready set. The current record is still in Custody here.
    %% Clearing on <=1 removes the last active placement without maintaining a
    %% second ordered projection that could drift and strand work.
    PlacedCount = map_size(Custody) - gb_sets:size(Ready),
    S1 =
        S#s{custody_lane =
                case {S#s.custody_lane, PlacedCount =< 1} of
                    {empty, _} -> empty;
                    {_, true} -> empty;
                    {Lane, false} -> Lane
                end},
    case Placement of
        {local, _Slot, _CommitteeId} ->
            S1;
        {relay, AttemptId, _Target, _Slot, _CommitteeId} ->
            remove_pending_relay(AttemptId, S1)
    end.

waiter_trace_ctx(#waiter{trace_ctx = TraceCtx}) -> TraceCtx;
waiter_trace_ctx(_) -> otel_ctx:new().

new_waiter(ReplyTo, ParentCtx, Change, Ns, Relayed) ->
    new_waiter(
      ReplyTo, ParentCtx, Change, Ns, Relayed,
      change_submission_id(Ns, Change)).

new_waiter(ReplyTo, ParentCtx, Change, Ns, Relayed, SubmissionId) ->
    {TraceCtx, SpanCtx} = quod_trace:start_span(
                            ParentCtx, <<"quod.consensus.append">>, internal,
                            #{'quod.namespace' => Ns,
                              'quod.tx.id' => quod_trace:tx_id(Change#transaction.tx_id),
                              'quod.relay.hop' => Relayed}),
    #waiter{reply_to = ReplyTo,
            submission_id = SubmissionId,
            trace_ctx = TraceCtx, trace_span = SpanCtx}.

bind_waiter_submission_id(Waiter = #waiter{}, SubmissionId) ->
    Waiter#waiter{submission_id = SubmissionId}.

change_submission_id(Ns, Change) ->
    case quod_transaction:submission(Ns, Change) of
        {ok, Submission} -> quod_transaction:submission_id(Submission);
        {error, _} -> undefined
    end.

finish_waiter_trace(#waiter{trace_ctx = TraceCtx, trace_span = SpanCtx}, Reply) ->
    _ = quod_trace:add_event(
          TraceCtx, <<"consensus.append_result">>, trace_reply_attributes(Reply)),
    quod_trace:finish_span(SpanCtx, Reply).

trace_reply_attributes({ok, Slot}) ->
    #{'quod.outcome' => <<"committed">>, 'quod.consensus.slot' => Slot};
trace_reply_attributes({error, Reason}) when is_atom(Reason) ->
    #{'quod.outcome' => atom_to_binary(Reason, utf8)};
trace_reply_attributes({error, not_in_charge, _Hint}) ->
    #{'quod.outcome' => <<"not_in_charge">>}.

trace_node_id(Id) when is_binary(Id) -> binary:encode_hex(Id, lowercase);
trace_node_id({Host, Port}) ->
    iolist_to_binary(io_lib:format("~ts:~B", [Host, Port])).

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

%% Route one inbound consensus message into the engine. A hostile peer can put any term on the wire.
%% Cheap source/slot/hash gates may drop it first; anything that reaches consensus state is then either
%% fully validated or an exact hash of a block already validated and retained locally.
dispatch(Peer, {propose, #block{} = B}, S) ->
    preflight_proposal(Peer, B, S);
dispatch(_Peer, {share, #share{} = Sh}, S) ->
    case well_formed_share(Sh) of
        true ->
            %% A peer's share for a slot WE proposed: its arrival lag since our own
            %% propose (one clock) is the direct in-production measure of how long
            %% votes take to come back — the number the round-phase histograms can
            %% only bound from outside.
            _ = case S#s.round_probe of
                    #{} = Probe when map_size(Probe) > 0 ->
                        case Probe of
                            #{(Sh#share.slot) := {ProposedAt, _}} ->
                                quod_metrics:observe_share_lag(
                                  S#s.ns, Sh#share.kind,
                                  quod_time:mono_ms() - ProposedAt);
                            _ -> ok
                        end;
                    _ -> ok
                end,
            maybe_join_complaint(Sh, engine_step([{share, Sh}], S));
        false -> S
    end;
dispatch(_Peer, {cert, #cert{} = C}, S) ->
    engine_step([{cert, C}], S);
dispatch(Peer, {block_request, Slot, BH}, S)
  when is_integer(Slot), Slot >= 1, is_binary(BH), byte_size(BH) =:= 32 ->
    serve_certified_block(Peer, Slot, BH, S);
dispatch(Peer, {certified_block, #block{} = Block, #cert{} = Cert}, S) ->
    ingest_certified_block(Peer, Block, Cert, S);
dispatch(Peer, {readiness, Height, Ready}, S)
  when is_integer(Height), Height >= 0, is_boolean(Ready) ->
    record_peer_readiness(Peer, Height, Ready, S);
dispatch(_Peer, _Other, S)                 -> S.

well_formed_block(#block{slot = Sl, parent = P, payload = Pl, timestamp = Ts}) ->
    well_formed_block_header(Sl, P, Ts)
        andalso well_formed_block_payload(Pl);
well_formed_block(_) -> false.

well_formed_block_header(Slot, Parent, Timestamp) ->
    is_slot(Slot) andalso is_slot(Parent) andalso is_slot(Timestamp).

well_formed_block_payload(Pl) ->
    bounded_transaction_list(Pl)
        andalso byte_size(term_to_binary(Pl, [deterministic])) =< ?MAX_BLOCK_BYTES
        andalso lists:all(fun well_formed_transaction/1, Pl)
        andalso unique_tx_ids(Pl).
well_formed_share(#share{kind = K, slot = Sl, block_hash = BH, signer = Sg, sig = Sig}) ->
    is_slot(Sl) andalso valid_shape(K, BH) andalso valid_signer_signature(Sg, Sig);
well_formed_share(_) -> false.
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

%% Responses are accepted only for a currently outstanding exact request. Cheap
%% source/header/certificate-shape gates precede one block hash and one shared content
%% validation, so an authenticated faulty validator cannot amplify unsolicited
%% recovery traffic or make the same payload pass twice.
ingest_certified_block(
  Peer, Block = #block{slot = Slot, parent = Parent, timestamp = Timestamp},
  Cert = #cert{kind = support, slot = Slot, block_hash = ExpectedBH},
  S = #s{block_requests = Requests})
  when is_binary(ExpectedBH), byte_size(ExpectedBH) =:= 32 ->
    Preflight =
        maps:is_key({Slot, ExpectedBH}, Requests)
        andalso lists:member(Peer, active_validators(S))
        andalso well_formed_block_header(Slot, Parent, Timestamp),
    case Preflight andalso block_hash(Block) =:= ExpectedBH
         andalso certified_block_context(Block, ExpectedBH, S) of
        false ->
            S;
        true ->
            %% Ingest the certificate first. The engine sanitizes every signature against the current
            %% committee; only a certificate that survives that boundary may authorize a non-leader block.
            S1 = engine_step([{cert, Cert}], S),
            case persisted_cert(support, Slot, ExpectedBH, S1#s.eng) of
                #cert{} ->
                    Requests1 =
                        maps:remove({Slot, ExpectedBH}, S1#s.block_requests),
                    engine_step(
                      [{block, ExpectedBH, Block}],
                      S1#s{block_requests = Requests1});
                none ->
                    S1
            end
    end;
ingest_certified_block(_Peer, _Block, _Cert, S) ->
    S.

certified_block_context(
  #block{slot = Slot, parent = Parent} = Block,
  BH,
  S = #s{slot = Committed}) ->
    ContextValid = live_pipeline_slot(Slot, Committed)
                   andalso Parent =:= Slot - 1
                   andalso compatible_local_final_vote(Slot, BH, S),
    case ContextValid andalso recoverable_parent_timestamp(Parent, S) of
        false ->
            false;
        unavailable ->
            false;
        ParentTs ->
            block_admissible(Block, ParentTs, S)
    end.

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

%% Reject unauthorised and repeated-heavy proposal traffic at the cheapest
%% available boundary. A non-leader is rejected before hashing or walking the
%% payload. For the authenticated leader, the first block pays structural and
%% transaction validation once; an exact retained redrive is already trusted,
%% while a different hash for that slot is dropped before signature work.
%% Certified recovery has its own support-certificate-authorized replacement
%% path and does not enter here.
preflight_proposal(
  Peer, #block{slot = Sl} = Block,
  S = #s{slot = Committed, approved = Approved,
         eng = #eng{block_slots = BlockSlots}}) ->
    PotentiallyLive =
        maps:is_key(Sl, BlockSlots)
        orelse (Sl =:= Approved + 1
                andalso live_pipeline_slot(Sl, Committed)),
    FromLeader =
        PotentiallyLive
        andalso is_slot(Sl) andalso Sl >= 1
        andalso leader(Sl, active_validators(S)) =:= Peer,
    case FromLeader of
        false ->
            S;
        true ->
            BH = block_hash(Block),
            case maps:get(Sl, BlockSlots, undefined) of
                undefined ->
                    on_propose(BH, Block, false, S);
                BH ->
                    on_propose(BH, Block, true, S);
                _OtherBH ->
                    S
            end
    end.

%% A new leader proposal is valid only at the next approved slot, extending
%% that approved parent, with one bounded transaction batch. A retained exact
%% redrive bypasses the checks already paid before that block entered the
%% engine. In both cases, recovery may retain evidence while only a ready voter
%% starts local validation, timers, or signatures.
on_propose(BH, #block{slot = Sl} = Block, Known, S) ->
    case Known orelse valid_proposal(Block, S) of
        %% Recovery may ingest the block and certificates as evidence, but only a ready voter starts local
        %% validation, timers, or signatures. The leader's redrive presents the proposal again after recovery.
        true  ->
            S1 = engine_step([{block, BH, Block}], S),
            %% A Byzantine leader may equivocate indefinitely. The engine retains
            %% only the first ordinary block for this slot, so validation and
            %% signing continue only if this exact hash was admitted.
            case block_for(BH, S1#s.eng) of
                #block{} ->
                    case may_vote(S1) of
                        true  -> support_or_validate(Block, BH, watch_proposal(Sl, S1));
                        false -> S1
                    end;
                undefined ->
                    S1
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
%% This exact block was already judged INVALID: never endorse or re-prove it. The hash scope matters:
%% an equivocated block for the same slot may later arrive with a valid quorum support certificate.
support_or_validate(#block{slot = Sl}, BH, S) ->
    case (round_state(Sl, S))#round.invalid of
        BH -> S;
        _  -> timed_step(S, support,
                         fun() -> support_or_validate_ready(Sl, BH, S) end)
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
%% ⇒ emit the deferred support share; `invalid` ⇒ latch its hash in `#round.invalid` (so we never endorse it at any phase —
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
                    S2 = put_round(Sl, (round_state(Sl, S1))#round{invalid = BH},
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
    ActionsRev0 = lists:reverse(Actions),
    BeforeIngress = (refresh_ingress_view(S0))#s.ingress,
    SReady = timed_step(S1, readiness,
                        fun() -> settle_readiness(S0, maybe_mark_ready(S1)) end),
    SRecovered = timed_step(SReady, reconcile,
                            fun() -> reconcile_block_requests(SReady) end),
    SCustodyReady =
        timed_step(
          SRecovered, custody_reconcile,
          fun() -> reconcile_custody_lane(SRecovered) end),
    SCustodyView = refresh_ingress_view(SCustodyReady),
    %% Durable exclusion becomes a new placement only here: the complete
    %% contiguous commit prefix, committee adoption, author floor, and recovery
    %% state have all settled. Retained signed work drains before unsigned
    %% ingress so a later author sequence cannot overtake it.
    {SCustody, ActionsRev1} =
        timed_step(
          SCustodyView, custody_drain,
          fun() ->
                  case custody_drain_decision(
                         BeforeIngress, SCustodyView#s.ingress,
                         SCustodyView#s.custody_ready) of
                      {drain, _Fingerprint} ->
                          drain_custody_rev(
                            SCustodyView, ActionsRev0, 0);
                      none ->
                          {SCustodyView, ActionsRev0}
                  end
          end),
    %% Drain BEFORE head reconciliation and the timer diff: a drain-created
    %% proposal moves head_progress, and the watchdog must be armed against the
    %% post-drain head. The fingerprint avoids a full queue scan after unrelated
    %% mailbox traffic.
    SIngressView = refresh_ingress_view(SCustody),
    {SDrained, ActionsRev2} =
        timed_step(
          SIngressView, drain,
          fun() ->
                  case ingress_drain_decision(
                         BeforeIngress, SIngressView#s.ingress) of
                      {drain, Fingerprint} ->
                          drain_ingress_rev(
                            SIngressView, Fingerprint, ActionsRev1);
                      none ->
                          {SIngressView, ActionsRev1}
                  end
          end),
    SAdvertised = timed_step(SDrained, advertise,
                             fun() -> refresh_readiness(SDrained) end),
    S2 = timed_step(SAdvertised, head_reconcile,
                    fun() -> reconcile_head_progress(SAdvertised) end),
    log_progress_transition(S0#s.head_progress, S2#s.head_progress, S2),
    TimerActions = case TimerMode of
                       rearm -> rearm_progress_timer(S2);
                       normal -> progress_timer_actions(S0, S2)
                   end,
    {keep_state, S2,
     lists:reverse(ActionsRev2, TimerActions)}.

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
        {none, BH, Invalid} when is_binary(BH), Invalid =/= BH ->
            validating;
        {none, none, Invalid} ->
            Candidates = lists:sort(
                           [{BH, Block}
                            || {BH, #block{slot = Sl} = Block} <- maps:to_list(Blocks),
                               Sl =:= V, BH =/= Invalid, valid_proposal(Block, S)]),
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
        #round{supporting = BH, final = Final, invalid = Invalid}
          when is_binary(BH), Final =/= complaint, Invalid =/= BH ->
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
            case {notarized_hash(V, S),
                  may_commit(V, complained_slots(S))} of
                {{ok, BH}, true}
                  when CommitPolicy =:= commit, Round#round.invalid =/= BH ->
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
            {ok, make_share(S#s.consensus_domain, Kind, Slot, BlockHash, S#s.id), S1}
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
%% Tests and certificate verification use `make_share/5` directly; normal first emission must pass
%% through `record_share/4` above.
own_share(Kind, Slot, BlockHash, #s{id = Id, consensus_domain = Domain} = S) ->
    case may_vote(S) andalso vote_is_latched(Kind, BlockHash, round_state(Slot, S)) of
        true  -> {ok, make_share(Domain, Kind, Slot, BlockHash, Id)};
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

%% A proposed block's `timestamp` is acceptable iff it is a non-negative integer. The check lives here
%% so ordinary proposal admission is total without a duplicate structural pass, while certified recovery
%% can share the same predicate after its own wire-shape gate. It must also be MONOTONIC
%% (≥ the parent block's time `Last`) and not implausibly far in the FUTURE relative to the
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
    acceptable_payload_content(Payload, S)
        andalso verify_transaction_signatures(Ns, Payload, live);
acceptable_payload(_Payload, _S) -> false.

%% Transactions entering this node's local batch have one of two trusted
%% provenance checks: this node just signed them, or a relay submission was
%% authenticated and verified before its opaque bytes were decoded. Keep the
%% structural/authorization checks here. The leader does not cryptographically
%% verify signatures it just created, and relay signatures were already verified
%% over opaque bytes before decode. Every other validator independently verifies
%% the complete proposed batch in acceptable_payload/2 before voting.
acceptable_collected_payload([#transaction{} | _] = Payload, S) ->
    acceptable_payload_content(Payload, S);
acceptable_collected_payload(_Payload, _S) ->
    false.

acceptable_payload_content(Payload, S) ->
    bounded_transaction_list(Payload)
        andalso byte_size(term_to_binary(Payload, [deterministic])) =< ?MAX_BLOCK_BYTES
        andalso lists:all(fun(Change) -> ingress_change_acceptable(Change, S) end,
                          Payload)
        andalso unique_tx_ids(Payload)
        andalso sequence_payload_ok(Payload, S)
        andalso membership_payload_ok(Payload, S).

ingress_change_acceptable(#transaction{caller_ns = Ns, author = Author} = Change,
                          #s{ns = Ns, validators = Vs}) ->
    lists:member(Author, Vs) andalso change_acceptable(Change, Vs);
ingress_change_acceptable(_Change, _S) ->
    false.

bounded_transaction_list(Transactions) ->
    bounded_transaction_list(Transactions, 0).

bounded_transaction_list([], _Count) ->
    true;
bounded_transaction_list([#transaction{} | Rest], Count)
  when Count < ?MAX_BATCH_TXS ->
    bounded_transaction_list(Rest, Count + 1);
bounded_transaction_list(_Other, _Count) ->
    false.

unique_tx_ids(Payload) ->
    unique_tx_ids(Payload, #{}).

unique_tx_ids([], _Seen) ->
    true;
unique_tx_ids([#transaction{tx_id = Id} | Rest], Seen) ->
    case maps:is_key(Id, Seen) of
        true  -> false;
        false -> unique_tx_ids(Rest, Seen#{Id => true})
    end;
unique_tx_ids(_Payload, _Seen) ->
    false.

%% Exact committed replay protection. A signed sequence may skip values, but it
%% must be newer than that author's approved history and unique within the block.
%% Including the approved parent is load-bearing for the depth-one pipeline:
%% H+2 cannot reuse a sequence notarized in H+1 while H+1 is not durable yet.
sequence_payload_ok(Payload, S) ->
    case approved_author_seqs(S) of
        {ok, Floor} -> transaction_sequences_ok(Payload, Floor, #{});
        error       -> false
    end.

transaction_sequences_ok([], _Floor, _Seen) ->
    true;
transaction_sequences_ok(
  [#transaction{} = Change | Rest], Floor, Seen) ->
    case advance_transaction_sequence(Change, Floor, Seen) of
        {ok, Seen1} ->
            transaction_sequences_ok(Rest, Floor, Seen1);
        error ->
            false
    end;
transaction_sequences_ok(_Payload, _Floor, _Seen) ->
    false.

approved_author_seqs(#s{author_seqs = Seqs, approved = Approved,
                        slot = Committed})
  when Approved =:= Committed ->
    {ok, Seqs};
approved_author_seqs(
  #s{approved = Approved,
     collecting =
         #batch{parent = Approved, sequence_floor = Floor}}) ->
    %% The batch opened from this exact approved parent. Reuse the immutable
    %% floor it already validated instead of folding the parent payload again
    %% after every collecting count/byte change.
    {ok, Floor};
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
    case membership_payload_shape(Payload) of
        none -> true;
        singleton -> Approved =:= Committed;
        invalid -> false
    end.

membership_batch_shape_ok(Payload) ->
    membership_payload_shape(Payload) =/= invalid.

membership_payload_shape([Change]) ->
    case is_membership_change(Change) of
        true -> singleton;
        false -> none
    end;
membership_payload_shape(Payload) ->
    case lists:any(fun is_membership_change/1, Payload) of
        true -> invalid;
        false -> none
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
    valid_genesis_transaction(Ns, Genesis);
valid_history_entry(_Ns, I, noop, _Committee) when is_integer(I), I > 1 ->
    true;
valid_history_entry(Ns, I, {batch, Payload}, Committee)
  when is_binary(Ns), is_integer(I), I > 1, is_list(Committee) ->
    bounded_transaction_list(Payload)
        andalso Payload =/= []
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

valid_genesis_transaction(Ns, Genesis) ->
    valid_genesis_transaction(Ns, Genesis, any_founding_set).

valid_genesis_transaction(
  Ns, #transaction{tx_id = TxId, goal = undefined, result = undefined,
                   diff = Diff, read_check = #{}, author = Author,
                   author_seq = 0, submitted_at = 0} = Genesis,
  ExpectedFounders) ->
    well_formed_transaction(Genesis)
        andalso valid_genesis_identity(
                  decode_genesis_tx_id(Ns, TxId), Diff, Author,
                  Genesis, ExpectedFounders);
valid_genesis_transaction(_Ns, _Genesis, _ExpectedFounders) ->
    false.

valid_genesis_identity(
  {ok, Incarnation}, Diff, Author, Genesis, ExpectedFounders) ->
    {Adds, Removes} = committee_delta(Genesis),
    genesis_incarnation_matches(Diff, Incarnation)
        andalso Removes =:= []
        andalso Adds =/= []
        andalso Author =:= lists:min(Adds)
        andalso founding_set_matches(ExpectedFounders, Adds);
valid_genesis_identity(
  error, _Diff, _Author, _Genesis, _ExpectedFounders) ->
    false.

founding_set_matches(any_founding_set, _Adds) ->
    true;
founding_set_matches(ExpectedFounders, Adds) ->
    lists:sort(Adds) =:= ExpectedFounders.

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

%% Erlog stores clause bodies in compiled `{Code, HasCut}` form. Explicitly
%% constructed transactions may carry a legal source body instead; `quod_diff`
%% normalizes it deterministically before applying it. Validate both forms fully.
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
    timed_step(S, bcast, fun() ->
        Frame = encode(S#s.ns, Msg),
        lists:foldl(fun(P, Acc) -> send_frame(P, Frame, Acc) end,
                    S, active_validators(S) -- [Self])
    end).

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

%% Relay submissions are already retained in `relay_pending`; duplicating them
%% into the generic bounded outbox would let unrelated consensus traffic evict
%% an early author sequence while keeping a later one. A disconnected link only
%% needs a dial. Link-up and periodic redrive reconstruct the complete ordered
%% prefix directly from pending custody.
send_relay_submission(
  Peer, Frame,
  S = #s{relay_conns = Conns}) ->
    case maps:get(Peer, Conns, undefined) of
        {LinkPid, _Ref} ->
            _ = quod_link:send_ordered(LinkPid, Frame),
            S;
        undefined ->
            ensure_relay_dial(Peer, S)
    end.

ensure_relay_dial(
  Peer, S = #s{relay_chan = Chan, relay_conns = Conns,
               relay_dialing = Dialing}) ->
    case maps:is_key(Peer, Conns)
         orelse maps:is_key(Peer, Dialing) of
        true ->
            S;
        false ->
            _ = quod_quic:open_link(Peer, Chan),
            S#s{relay_dialing =
                    Dialing#{Peer => dial_deadline()}}
    end.

%% Accepted/result frames are authenticated hints. They share the dedicated
%% ingress stream when we already own it; otherwise the transport opens/buffers
%% that relay-only channel. Loss is repaired by the retained submit prefix and
%% the destination's inflight/result cache, so no relay frame enters the
%% consensus outbox.
send_relay_control(
  Peer, Frame,
  S = #s{relay_chan = Chan, relay_conns = Conns}) ->
    case maps:get(Peer, Conns, undefined) of
        {LinkPid, _Ref} ->
            _ = quod_link:send(LinkPid, Frame),
            S;
        undefined ->
            _ = quod_quic:send(Peer, Chan, Frame),
            S
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
sweep_stale_dials(
  S = #s{dialing = Dialing, relay_dialing = RelayDialing}) ->
    Now = quod_time:mono_ms(),
    S#s{dialing = prune_dials(Dialing, Now),
        relay_dialing = prune_dials(RelayDialing, Now)}.

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

dispatch_relay(
  Peer, {relay_submit, SubmissionId, AttemptId, CommitteeId, TargetSlot,
         {submit, Author, _Signature, _Canonical} = Submission, TraceCarrier},
  S0 = #s{ns = Ns, self = Self}) ->
    DerivedSubmissionId = quod_transaction:submission_id(Submission),
    DerivedAttemptId =
        quod_transaction:relay_attempt_id(
          Ns, DerivedSubmissionId, CommitteeId, TargetSlot, Self),
    case Peer =:= Author
         andalso SubmissionId =:= DerivedSubmissionId
         andalso AttemptId =:= DerivedAttemptId of
        false ->
            {S0, []};
        true ->
            Ref = #relay_ref{peer = Peer, submission_id = SubmissionId,
                             attempt_id = AttemptId,
                             committee_id = CommitteeId,
                             target_slot = TargetSlot},
            case verify_relay_submission(Ns, Submission) of
                false ->
                    %% Invalid opaque bytes cannot prune/read/populate either
                    %% volatile recovery state or the durable target slot.
                    {S0, []};
                true ->
                    dispatch_relay_submit(
                      Ref, Author, Submission, TraceCarrier,
                      prune_relay_results(S0))
            end
    end;
dispatch_relay(
  Peer, {relay_result, SubmissionId, AttemptId, CommitteeId,
         TargetSlot, Result}, S) ->
    {handle_relay_result(
       Peer, SubmissionId, AttemptId, CommitteeId, TargetSlot, Result, S), []};
dispatch_relay(
  Peer, {relay_accepted, SubmissionId, AttemptId, CommitteeId,
         TargetSlot}, S) ->
    {handle_relay_accepted(
       Peer, SubmissionId, AttemptId, CommitteeId, TargetSlot, S), []};
dispatch_relay(_Peer, _Unsupported, S) ->
    {S, []}.

verify_relay_submission(Ns, Submission) ->
    Started = erlang:monotonic_time(),
    Valid = quod_transaction:verify_submission(Submission),
    quod_metrics:observe_transaction_signature(
      Ns, Valid, erlang:monotonic_time() - Started),
    Valid.

dispatch_relay_submit(
  Ref = #relay_ref{}, Author, Submission, TraceCarrier,
  S = #s{relay_results = Results, relay_inflight = Inflight}) ->
    Key = Ref#relay_ref.attempt_id,
    case maps:get(Key, Results, undefined) of
        {Ref, Reply, _Expires} ->
            %% A completed old-view attempt remains answerable from the exact
            %% immutable context that admitted it.
            {send_relay_result(Ref, Reply, S), []};
        {_OtherRef, _Reply, _Expires} ->
            %% A digest collision or divergent metadata can never overwrite or
            %% borrow an existing attempt.
            {S, []};
        undefined ->
            case maps:get(Key, Inflight, undefined) of
                Ref ->
                    {send_relay_accepted(
                       Ref,
                       S#s{relay_duplicates = S#s.relay_duplicates + 1}), []};
                #relay_ref{} ->
                    {S, []};
                undefined ->
                    case durable_relay_result(
                           Ref#relay_ref.submission_id,
                           Ref#relay_ref.target_slot, S) of
                        {final, Reply} ->
                            {reply_relay(Ref, Reply, S), []};
                        pending ->
                            first_admit_relay(
                              Ref, Author, Submission, TraceCarrier, S);
                        unknown ->
                            %% A durable slot that cannot be read or decoded is
                            %% ambiguous. Silence is safer than fabricating an
                            %% exclusion that could retry a committed write.
                            {S, []}
                    end
            end
    end.

durable_relay_result(
  SubmissionId, TargetSlot,
  #s{ns = Ns, store = Store, slot = DurableHead})
  when TargetSlot =< DurableHead ->
    case catch quod_ledger_store:read_at(Store, TargetSlot) of
        {ok, #entry{data = Data}} ->
            case quod_ledger:payload(Data) of
                {ok, Payload} ->
                    case payload_has_submission(Ns, SubmissionId, Payload) of
                        true ->
                            {final, {ok, TargetSlot}};
                        false ->
                            {final, {error, not_in_charge, none}}
                    end;
                error when Data =:= noop ->
                    {final, {error, not_in_charge, none}};
                error ->
                    unknown
            end;
        _ ->
            unknown
    end;
durable_relay_result(_SubmissionId, _TargetSlot, _S) ->
    pending.

payload_has_submission(Ns, SubmissionId, Payload) ->
    lists:any(
      fun(Transaction) ->
              case quod_transaction:submission(Ns, Transaction) of
                  {ok, Submission} ->
                      quod_transaction:submission_id(Submission)
                          =:= SubmissionId;
                  {error, _} ->
                      false
              end
      end, Payload).

first_admit_relay(
  Ref = #relay_ref{peer = Peer, committee_id = CommitteeId,
                   target_slot = TargetSlot},
  Author, Submission, TraceCarrier,
  S = #s{committee_id = CurrentCommitteeId}) ->
    case Peer =:= Author andalso
         lists:member(Peer, active_validators(S)) of
        false ->
            reply_now(relay_reply_to(Ref), {error, bad_change}, S);
        true when CommitteeId =/= CurrentCommitteeId ->
            reply_now(
              relay_reply_to(Ref), {error, not_in_charge, none}, S);
        true ->
            SView = refresh_ingress_view(S),
            case quod_ingress_state:relay_target_open(
                   {CommitteeId, TargetSlot},
                   SView#s.ingress) of
                false ->
                    reply_now(
                      relay_reply_to(Ref),
                      {error, not_in_charge, none}, SView);
                true ->
                    decode_and_accept_verified_relay(
                      Ref, Submission, TraceCarrier, SView)
            end
    end.

decode_and_accept_verified_relay(
  Ref = #relay_ref{peer = Peer, submission_id = SubmissionId},
  Submission, TraceCarrier, S = #s{ns = Ns}) ->
    case quod_transaction:decode_verified_submission(Ns, Submission) of
        {ok, Change} ->
            Key = Ref#relay_ref.attempt_id,
            Inflight = (S#s.relay_inflight)#{Key => Ref},
            ParentCtx = quod_trace:extract(TraceCarrier),
            Waiter = new_waiter(
                       relay_reply_to(Ref), ParentCtx,
                       Change, Ns, true, SubmissionId),
            _ = quod_trace:add_event(
                  waiter_trace_ctx(Waiter), <<"consensus.relay_received">>,
                  #{'quod.relay.source' => trace_node_id(Peer)}),
            {S1, Actions} = handle_relayed_append(
                              Waiter, Ref, Change,
                              S#s{relay_inflight = Inflight}),
            case maps:get(Key, S1#s.relay_inflight, undefined) of
                Ref -> {send_relay_accepted(Ref, S1), Actions};
                _   -> {S1, Actions}
            end;
        {error, _} ->
            reply_now(
              relay_reply_to(Ref), {error, bad_change}, S)
    end.

handle_relay_result(
  Peer, SubmissionId, AttemptId, CommitteeId, TargetSlot, Result,
  S = #s{relay_pending = Pending}) ->
    Key = AttemptId,
    case maps:get(Key, Pending, undefined) of
        #relay_pending{target = Peer,
                       submission_id = SubmissionId,
                       attempt_id = AttemptId,
                       committee_id = CommitteeId,
                       target_slot = TargetSlot} = Relay ->
            case valid_relay_result(Result, TargetSlot) of
                false ->
                    S;
                true ->
                    %% A destination result is an authenticated hint, not
                    %% finality evidence. Keep source ownership until the
                    %% origin's durable log includes SubmissionId or finalizes
                    %% TargetSlot without it. This prevents a Byzantine target
                    %% from fabricating either success or a safe retry.
                    accept_pending_relay(Key, Relay, S)
            end;
        _ ->
            %% Delayed or foreign replies are never compared with the current
            %% committee view; they simply fail the stored attempt match.
            S
    end.

valid_relay_result({ok, Slot}, TargetSlot) -> Slot =:= TargetSlot;
valid_relay_result(_Result, _TargetSlot) -> true.

finish_relay(Key, From, Result, S) ->
    reply_waiter(From, Result, remove_pending_relay(Key, S)).

remove_pending_relay(Key, S = #s{relay_pending = Pending}) ->
    S#s{relay_pending = maps:remove(Key, Pending)}.

handle_relay_accepted(
  Peer, SubmissionId, AttemptId, CommitteeId, TargetSlot,
  S = #s{relay_pending = Pending}) ->
    Key = AttemptId,
    case maps:get(Key, Pending, undefined) of
        #relay_pending{target = Peer,
                       submission_id = SubmissionId,
                       attempt_id = AttemptId,
                       committee_id = CommitteeId,
                       target_slot = TargetSlot} = Relay ->
            accept_pending_relay(Key, Relay, S);
        _ ->
            S
    end.

accept_pending_relay(Key,
                     Relay = #relay_pending{accepted = Accepted}, S) ->
    Relay1 = Relay#relay_pending{
               accepted = true,
               next_retry =
                   quod_time:mono_ms() + ?RELAY_ACCEPTED_RETRY_MS},
    S#s{relay_pending = (S#s.relay_pending)#{Key => Relay1},
        relay_accepted =
            S#s.relay_accepted
            + case Accepted of false -> 1; true -> 0 end}.

reply_relay(Ref, Reply, S) ->
    Key = Ref#relay_ref.attempt_id,
    S0 = prune_relay_results(S),
    case maps:get(Key, S0#s.relay_results, undefined) of
        undefined ->
            S1 = send_relay_result(Ref, Reply, S0),
            Results1 = quod_relay:put_result(
                         Key,
                         {Ref, Reply,
                          quod_time:mono_ms() + S1#s.relay_timeout_ms},
                         S1#s.relay_results),
            S1#s{
              relay_inflight = maps:remove(Key, S1#s.relay_inflight),
              relay_results = Results1};
        {Ref, Reply, _Expires} ->
            %% Repeating the exact terminal transition may re-send the stored
            %% answer, but it must not turn the cache TTL into a sliding lease.
            S1 = send_relay_result(Ref, Reply, S0),
            S1#s{relay_inflight =
                     maps:remove(Key, S1#s.relay_inflight)};
        {_StoredRef, _StoredReply, _Expires} ->
            %% A same-key divergent context/result is an invariant violation
            %% (or digest collision). Do not emit contradictory wire state and
            %% never overwrite the write-once cache. Drop volatile ownership so
            %% the origin observes ambiguity through its existing deadline.
            logger:error(
              "quod[~s]: refusing divergent relay terminal state for ~0p",
              [S0#s.ns, Key]),
            S0#s{relay_inflight =
                     maps:remove(Key, S0#s.relay_inflight)}
    end.

send_relay_result(
  #relay_ref{peer = Peer, submission_id = SubmissionId,
             attempt_id = AttemptId,
             committee_id = CommitteeId, target_slot = TargetSlot},
  Reply, S = #s{ns = Ns}) ->
    send_relay_control(
      Peer,
      quod_relay:encode(
        Ns, {relay_result, SubmissionId, AttemptId, CommitteeId,
             TargetSlot, Reply}), S).

send_relay_accepted(
  #relay_ref{peer = Peer, submission_id = SubmissionId,
             attempt_id = AttemptId,
             committee_id = CommitteeId, target_slot = TargetSlot},
  S = #s{ns = Ns}) ->
    send_relay_control(
      Peer,
      quod_relay:encode(
        Ns, {relay_accepted, SubmissionId, AttemptId, CommitteeId,
             TargetSlot}), S).

relay_reply_to(Ref = #relay_ref{}) ->
    {relay, Ref}.

prune_relay_results(S = #s{relay_results = Results}) ->
    S#s{relay_results = quod_relay:prune_results(Results)}.

redrive_relays(S = #s{relay_pending = Pending, relay_results = Results}) ->
    Now = quod_time:mono_ms(),
    S1 = S#s{relay_results = quod_relay:prune_results(Results)},
    Validators = active_validators(S1),
    Ordered0 = ordered_relays(Pending),
    S2 =
        lists:foldl(
          fun({_AuthorSeq, Key,
               #relay_pending{from = From, target = Target,
                              deadline = Deadline}}, Acc) ->
                  case {maps:is_key(Key, Acc#s.relay_pending),
                        lists:member(Target, Validators)} of
                      {false, _} ->
                          Acc;
                      {true, false} ->
                          case custody_submission_id(From) of
                              {ok, SubmissionId} ->
                                  mark_custody_ready(
                                    SubmissionId, Acc);
                              error ->
                                  finish_relay(
                                    Key, From,
                                    {error, skipped}, Acc)
                          end;
                      {true, true} when Now >= Deadline ->
                          reply_waiter(
                            From,
                            {error, not_in_charge, unavailable},
                            remove_pending_relay(Key, Acc));
                      {true, true} ->
                          Acc
                  end
          end, S1, Ordered0),
    Pending2 = S2#s.relay_pending,
    Ordered =
        [Entry
         || Entry = {_AuthorSeq, AttemptId, _Relay} <- Ordered0,
            maps:is_key(AttemptId, Pending2)],
    S3 =
        case Ordered of
            [] ->
                S2;
            [{_Seq, _AttemptId,
              #relay_pending{target = Target}} | _] ->
                ensure_relay_dial(Target, S2)
        end,
    S4 =
        case lists:reverse(
               [{AuthorSeq, AttemptId}
                || {AuthorSeq, AttemptId,
                    #relay_pending{next_retry = Retry}} <- Ordered,
                   Now >= Retry]) of
            [] ->
                S3;
            [DueCeiling | _] ->
                redrive_relay_prefix(
                  DueCeiling, Now, Ordered, S3)
        end,
    prune_relay_links(S4).

ordered_relays(Pending) ->
    lists:sort(
      [{AuthorSeq, AttemptId, Relay}
       || {AttemptId,
           Relay = #relay_pending{author_seq = AuthorSeq}} <-
              maps:to_list(Pending)]).

redrive_relay_prefix(
  DueCeiling, Now,
  [{AuthorSeq, AttemptId,
    Relay = #relay_pending{target = Target, frame = Frame,
                           accepted = Accepted}} | Rest],
  S)
  when {AuthorSeq, AttemptId} =< DueCeiling ->
    S1 = send_relay_submission(Target, Frame, S),
    Relay1 =
        Relay#relay_pending{
          next_retry =
              Now + case Accepted of
                        true  -> ?RELAY_ACCEPTED_RETRY_MS;
                        false -> ?RELAY_RETRY_MS
                    end},
    S2 =
        S1#s{relay_pending =
                 (S1#s.relay_pending)#{AttemptId => Relay1},
             relay_redrives = S1#s.relay_redrives + 1},
    redrive_relay_prefix(DueCeiling, Now, Rest, S2);
redrive_relay_prefix(_DueCeiling, _Now, _Rest, S) ->
    S.

custody_submission_id(
  #waiter{reply_to = {custody, SubmissionId}})
  when is_binary(SubmissionId) ->
    {ok, SubmissionId};
custody_submission_id(_) ->
    error.

encode(Ns, Msg) ->
    Inner = term_to_binary(Msg, [deterministic]),
    term_to_binary({sx2, Ns, Inner}, [deterministic]).

%% Our outbound consensus link to a peer opened: adopt it (monitor + flush the
%% consensus outbox), unless we already hold a
%% LIVE link to it or it is not in the ACTIVE voting set (consensus links are scoped to the active set,
%% matching `broadcast/2`). A stored conn whose pid is DEAD (its `DOWN` not yet processed) is replaced —
%% never treat a corpse as a live duplicate and close the newcomer, or the peer could never re-link.
handle_link_up(Peer, LinkPid, S0 = #s{outbox = Outbox}) ->
    S = S0#s{dialing = maps:remove(Peer, S0#s.dialing)},   %% the dial resolved
    case lists:member(Peer, active_validators(S)) of
        false ->
            _ = quod_link:close(LinkPid),
            S;
        true ->
            case maps:get(Peer, S#s.conns, undefined) of
                {LinkPid, _Ref} ->
                    %% quod_conn may notify several waiters when one channel
                    %% opens. Repeating the same link_up is idempotent.
                    S;
                {ExistingPid, _Ref} when is_pid(ExistingPid) ->
                    case is_process_alive(ExistingPid) of
                        true ->
                            _ = quod_link:close(LinkPid),
                            S;
                        false ->
                            adopt_consensus_link(
                              Peer, LinkPid, Outbox, S)
                    end;
                undefined ->
                    adopt_consensus_link(Peer, LinkPid, Outbox, S)
            end
    end.

adopt_consensus_link(Peer, LinkPid, Outbox, S) ->
    S1 = drop_conn_by_peer(Peer, S),
    Ref = erlang:monitor(process, LinkPid),
    _ = [quod_link:send(LinkPid, F)
         || F <- lists:reverse(maps:get(Peer, Outbox, []))],
    S2 = S1#s{conns = (S1#s.conns)#{Peer => {LinkPid, Ref}},
              outbox = maps:remove(Peer, Outbox)},
    {Height, Ready} = local_readiness(S2),
    _ = quod_link:send(
          LinkPid, encode(S2#s.ns, {readiness, Height, Ready})),
    S2.

%% Relay traffic has its own `{ingress,Ns}` QUIC stream. A link is useful only
%% while this origin retains a placement toward the peer. Link-up reconstructs
%% the complete ordered prefix; an ordered-send reset can therefore discard the
%% whole relay stream without touching `{log,Ns}` consensus delivery.
handle_relay_link_up(Peer, LinkPid, S0) ->
    S = S0#s{
          relay_dialing =
              maps:remove(Peer, S0#s.relay_dialing)},
    Ordered = ordered_peer_relays(Peer, S#s.relay_pending),
    case maps:get(Peer, S#s.relay_conns, undefined) of
        {LinkPid, _Ref} ->
            %% Multiple open_link waiters may receive the same link_up.
            S;
        {ExistingPid, _Ref} when is_pid(ExistingPid) ->
            case is_process_alive(ExistingPid) of
                true ->
                    _ = quod_link:close(LinkPid),
                    S;
                false ->
                    adopt_relay_link(Peer, LinkPid, Ordered, S)
            end;
        undefined when Ordered =:= [] ->
            _ = quod_link:close(LinkPid),
            S;
        undefined ->
            adopt_relay_link(Peer, LinkPid, Ordered, S)
    end.

adopt_relay_link(Peer, LinkPid, Ordered, S) ->
    S1 = drop_relay_conn_by_peer(Peer, S),
    Ref = erlang:monitor(process, LinkPid),
    _ = [quod_link:send_ordered(LinkPid, Frame)
         || {_Seq, _AttemptId, Frame} <- Ordered],
    S1#s{
      relay_conns =
          (S1#s.relay_conns)#{Peer => {LinkPid, Ref}}}.

ordered_peer_relays(Peer, Pending) ->
    [{AuthorSeq, AttemptId, Frame}
     || {AuthorSeq, AttemptId,
         #relay_pending{target = Target, frame = Frame}} <-
            ordered_relays(Pending),
        Target =:= Peer].

%% Track the authenticated inbound stream that carries this peer's votes and readiness. Readiness is bound
%% to this exact pid; replacing the stream removes the previous claim before the new process can count.
current_inbound_generation(
  Peer, LinkPid, #s{inbound_conns = Inbound}) ->
    case maps:get(Peer, Inbound, undefined) of
        {LinkPid, _Ref} -> live_link(LinkPid);
        _ -> false
    end.

live_link(LinkPid) when is_pid(LinkPid) ->
    is_process_alive(LinkPid);
live_link(_LinkPid) ->
    false.

track_inbound(
  Peer, LinkPid,
  S = #s{inbound_conns = Inbound,
         retired_inbound = Retired})
  when is_pid(LinkPid) ->
    case maps:is_key(LinkPid, Retired) of
        true ->
            %% A close is already in flight for this superseded generation.
            %% Its process may still be alive, but it can never become current
            %% again while the retained monitor waits for DOWN.
            S;
        false ->
            case is_process_alive(LinkPid) of
                true  -> track_live_inbound(Peer, LinkPid, S, Inbound);
                false -> S
            end
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
            SRetired =
                retire_inbound_link({OldPid, OldRef}, S),
            Ref = erlang:monitor(process, LinkPid),
            S1 = drop_peer_readiness(Peer, SRetired),
            S1#s{inbound_conns = Inbound#{Peer => {LinkPid, Ref}}};
        {true, undefined} ->
            Ref = erlang:monitor(process, LinkPid),
            S1 = drop_peer_readiness(Peer, S),
            S1#s{inbound_conns = Inbound#{Peer => {LinkPid, Ref}}}
    end.

current_relay_inbound_generation(
  Peer, LinkPid, #s{relay_inbound_conns = Inbound}) ->
    case maps:get(Peer, Inbound, undefined) of
        {LinkPid, _Ref} -> live_link(LinkPid);
        _ -> false
    end.

track_relay_inbound(
  Peer, LinkPid,
  S = #s{relay_inbound_conns = Inbound,
         retired_inbound = Retired})
  when is_pid(LinkPid) ->
    case maps:is_key(LinkPid, Retired) of
        true ->
            S;
        false ->
            case is_process_alive(LinkPid) of
                false ->
                    S;
                true ->
                    case maps:get(Peer, Inbound, undefined) of
                        {LinkPid, _Ref} ->
                            S;
                        {OldPid, OldRef} ->
                            SRetired =
                                retire_inbound_link(
                                  {OldPid, OldRef}, S),
                            Ref = erlang:monitor(
                                    process, LinkPid),
                            SRetired#s{
                              relay_inbound_conns =
                                  Inbound#{
                                    Peer => {LinkPid, Ref}}};
                        undefined ->
                            Ref = erlang:monitor(
                                    process, LinkPid),
                            S#s{
                              relay_inbound_conns =
                                  Inbound#{
                                    Peer => {LinkPid, Ref}}}
                    end
            end
    end;
track_relay_inbound(_Peer, _LinkPid, S) ->
    S.

%% A current committee member owns the relay channel for every relay frame,
%% including a routine result that arrives after its local attempt was already
%% resolved. Exact stored attempts additionally keep their peer answerable
%% across a committee transition. The per-attempt fallback stays O(1); there is
%% no scan across the bounded maps.
relay_peer_owned(Peer, Relay, S) ->
    lists:member(Peer, active_validators(S))
        orelse relay_attempt_owned(Peer, Relay, S).

relay_attempt_owned(
  Peer,
  {relay_submit, _SubmissionId, AttemptId, _CommitteeId,
   _TargetSlot, _Submission, _Carrier},
  S) ->
    case maps:get(AttemptId, S#s.relay_inflight, undefined) of
        #relay_ref{peer = Peer} -> true;
        _ -> false
    end;
relay_attempt_owned(
  Peer,
  {relay_result, _SubmissionId, AttemptId, _CommitteeId,
   _TargetSlot, _Result},
  #s{relay_pending = Pending}) ->
    case maps:get(AttemptId, Pending, undefined) of
        #relay_pending{target = Peer} -> true;
        _ -> false
    end;
relay_attempt_owned(
  Peer,
  {relay_accepted, _SubmissionId, AttemptId, _CommitteeId,
   _TargetSlot},
  #s{relay_pending = Pending}) ->
    case maps:get(AttemptId, Pending, undefined) of
        #relay_pending{target = Peer} -> true;
        _ -> false
    end;
relay_attempt_owned(_Peer, _Relay, _S) ->
    false.

close_untracked_relay_link(Pid) when Pid =:= self() ->
    ok;
close_untracked_relay_link(Pid) when is_pid(Pid) ->
    _ = quod_link:close(Pid),
    ok;
close_untracked_relay_link(_Pid) ->
    ok.

%% A tracked link died (DOWN): drop it from either direction. A later send/tick reopens outbound links.
drop_link(Pid, S) ->
    drop_retired_inbound(
      Pid,
      drop_relay_inbound(
        Pid, drop_relay_conn(
               Pid, drop_inbound(Pid, drop_conn(Pid, S))))).

drop_retired_inbound(
  Pid, S = #s{retired_inbound = Retired}) ->
    case maps:take(Pid, Retired) of
        {Ref, Retired1} ->
            _ = erlang:demonitor(Ref, [flush]),
            S#s{retired_inbound = Retired1};
        error ->
            S
    end.

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

drop_relay_conn(Pid, S = #s{relay_conns = Conns}) ->
    case [{P, R} || {P, {LP, R}} <- maps:to_list(Conns),
                    LP =:= Pid] of
        [{Peer, Ref} | _] ->
            _ = erlang:demonitor(Ref, [flush]),
            S#s{relay_conns = maps:remove(Peer, Conns)};
        [] ->
            S
    end.

drop_relay_inbound(
  Pid, S = #s{relay_inbound_conns = Inbound}) ->
    case [{P, R} || {P, {LP, R}} <- maps:to_list(Inbound),
                    LP =:= Pid] of
        [{Peer, Ref} | _] ->
            _ = erlang:demonitor(Ref, [flush]),
            S#s{
              relay_inbound_conns =
                  maps:remove(Peer, Inbound)};
        [] ->
            S
    end.

drop_conn_by_peer(Peer, S = #s{conns = Conns}) ->
    case maps:get(Peer, Conns, undefined) of
        {_Pid, Ref} -> _ = erlang:demonitor(Ref, [flush]), S#s{conns = maps:remove(Peer, Conns)};
        undefined   -> S
    end.

drop_relay_conn_by_peer(
  Peer, S = #s{relay_conns = Conns}) ->
    case maps:get(Peer, Conns, undefined) of
        {_Pid, Ref} ->
            _ = erlang:demonitor(Ref, [flush]),
            S#s{relay_conns = maps:remove(Peer, Conns)};
        undefined ->
            S
    end.

%% Committee membership scopes consensus transport state. Once a committed transition removes a peer,
%% close both stream directions and discard its queued frames/dial attempt so repeated membership churn
%% cannot accumulate unreachable link processes or stale outboxes.
prune_consensus_links(S = #s{self = Self, conns = Conns, inbound_conns = Inbound,
                             peer_readiness = Readiness,
                             outbox = Outbox, dialing = Dialing}) ->
    Allowed = maps:from_keys(active_validators(S) -- [Self], true),
    {Conns1, RemovedOut} = partition_links(Allowed, Conns),
    {Inbound1, RemovedIn} = partition_links(Allowed, Inbound),
    maps:foreach(fun(_Peer, Link) -> close_tracked_link(Link) end, RemovedOut),
    S1 =
        S#s{conns = Conns1,
            inbound_conns = Inbound1,
            peer_readiness = maps:with(maps:keys(Allowed), Readiness),
            outbox = maps:with(maps:keys(Allowed), Outbox),
            dialing = maps:with(maps:keys(Allowed), Dialing)},
    prune_relay_links(retire_inbound_links(RemovedIn, S1)).

%% Relay generations are scoped independently. Current committee peers remain
%% eligible, as do exact peers still named by pending/inflight attempts.
prune_relay_links(
  S = #s{self = Self, relay_conns = Conns,
         relay_inbound_conns = Inbound,
         relay_dialing = Dialing}) ->
    %% Build the union directly. The former list expression both allocated two
    %% intermediate lists plus a sort and was vulnerable to `--`/`++`
    %% right-association changing its meaning.
    Allowed0 = maps:from_keys(active_validators(S), true),
    Allowed1 =
        maps:fold(
          fun(_AttemptId, #relay_pending{target = Target}, Acc) ->
                  Acc#{Target => true}
          end, Allowed0, S#s.relay_pending),
    Allowed2 =
        maps:fold(
          fun(_AttemptId, #relay_ref{peer = Peer}, Acc) ->
                  Acc#{Peer => true}
          end, Allowed1, S#s.relay_inflight),
    Allowed = maps:remove(Self, Allowed2),
    {Conns1, RemovedOut} =
        partition_links(Allowed, Conns),
    {Inbound1, RemovedIn} =
        partition_links(Allowed, Inbound),
    maps:foreach(
      fun(_Peer, Link) -> close_tracked_link(Link) end,
      RemovedOut),
    S1 =
        S#s{
          relay_conns = Conns1,
          relay_inbound_conns = Inbound1,
          relay_dialing =
              maps:with(maps:keys(Allowed), Dialing)},
    retire_inbound_links(RemovedIn, S1).

partition_links(Allowed, Links) ->
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

%% Live generation replacement must never wait in the namespace's serial
%% statem. Keep the old monitor and remember the pid until DOWN: a queued frame
%% from that still-live process is then rejected instead of reversing the
%% replacement. In production the link handles `close` by resetting its stream
%% and exiting; `self()` exists only in pure mailbox tests.
retire_inbound_link(
  {Pid, Ref},
  S = #s{retired_inbound = Retired}) ->
    _ =
        case Pid =:= self() of
            true  -> ok;
            false -> quod_link:close(Pid)
        end,
    S#s{retired_inbound = Retired#{Pid => Ref}}.

retire_inbound_links(Links, S) ->
    maps:fold(
      fun(_Peer, Link, Acc) ->
              retire_inbound_link(Link, Acc)
      end, S, Links).

close_link_pid_sync(Pid) when Pid =:= self() ->
    %% A transport link is always a distinct process. Some pure tests use
    %% `self()` as a mailbox-only stand-in; never terminate the test owner.
    ok;
close_link_pid_sync(Pid) when is_pid(Pid) ->
    case is_process_alive(Pid) of
        false ->
            ok;
        true ->
            Ref = erlang:monitor(process, Pid),
            _ = quod_link:close(Pid),
            receive
                {'DOWN', Ref, process, Pid, _Reason} ->
                    ok
            after ?LINK_CLOSE_TIMEOUT_MS ->
                exit(Pid, kill),
                receive
                    {'DOWN', Ref, process, Pid, _Reason} -> ok
                after ?LINK_CLOSE_TIMEOUT_MS ->
                    _ = erlang:demonitor(Ref, [flush]),
                    ok
                end
            end
    end;
close_link_pid_sync(_Pid) ->
    ok.

close_link_maps(
  Outbound, Inbound, RelayOutbound, RelayInbound, RetiredInbound) ->
    Links =
        maps:values(Outbound)
        ++ maps:values(Inbound)
        ++ maps:values(RelayOutbound)
        ++ maps:values(RelayInbound)
        ++ maps:to_list(RetiredInbound),
    _ = [erlang:demonitor(Ref, [flush])
         || {_Pid, Ref} <- Links],
    _ = [close_link_pid_sync(Pid)
         || Pid <- lists:usort([P || {P, _Ref} <- Links])],
    ok.

%% Recovery discards volatile inbound attempt state. Reset only the source
%% streams whose inflight attempt or future-slot terminal cache is invalidated;
%% the source then reconnects and reconstructs its complete retained prefix.
invalidate_relay_generation(
  NewHead,
  S = #s{relay_inflight = Inflight,
         relay_results = Results,
         relay_inbound_conns = Inbound}) ->
    {Results1, CachedPeers} =
        maps:fold(
          fun(_Key,
              {#relay_ref{peer = Peer,
                          target_slot = TargetSlot},
               _Reply, _Expires},
              {Keep, Peers}) when TargetSlot > NewHead ->
                  {Keep, [Peer | Peers]};
             (Key, Value, {Keep, Peers}) ->
                  {Keep#{Key => Value}, Peers}
          end, {#{}, []}, Results),
    InflightPeers =
        [Peer
         || #relay_ref{peer = Peer} <- maps:values(Inflight)],
    ResetPeers = lists:usort(InflightPeers ++ CachedPeers),
    ResetLinks = maps:with(ResetPeers, Inbound),
    S1 =
        S#s{relay_results = Results1,
            relay_inbound_conns =
                maps:without(ResetPeers, Inbound)},
    retire_inbound_links(ResetLinks, S1).

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

%% The highest slot proved by a FINALIZER cert (commit | complaint — a bare support cert only notarizes).
%% Near finalizers remain in the bounded live pool; a valid far finalizer is reduced to the O(1)
%% `ahead_finalizer` recovery hint. A single Byzantine node cannot forge either signal. Seeded with `base`
%% so an empty pool/latch yields `base` (no `lists:max([])` crash). See `behind/1`.
-spec ahead_cert_ceiling(#eng{}) -> slot().
ahead_cert_ceiling(#eng{certs = Certs, base = Base,
                        ahead_finalizer = Ahead}) ->
    lists:max([Base, Ahead |
               [Sl || {K, Sl, _BH} <- maps:keys(Certs),
                      Sl > Base,
                      (K =:= commit orelse K =:= complaint)]]).

%% True iff a finalizer cert proves the committed head is beyond our approved frontier. If the cert names
%% the very next slot but its block is absent, this node is already behind: it must recover the durable entry
%% rather than remain vote-capable at a stale frontier. The near-pool part is recomputed on demand; the far
%% O(1) latch is cleared when the durable base reaches it, on engine reseat, or when its verifying committee
%% changes. Thus recovery evidence cannot retain unbounded peer objects or survive beyond its authority.
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

%% Compute the shared participation/capability facts once for ingress views;
%% voting and proposal admission cannot drift onto different recovery rules.
ingress_capability(S) ->
    case {is_participant(S), caught_up(S)} of
        {false, _} -> reject;
        {true, false} -> hold;
        {true, true} -> accept
    end.

may_vote(S) ->
    ingress_capability(S) =:= accept.

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
apply_catchup_window(
  Source, Es0,
  S = #s{ns = Ns, store = Store, validators = Vs,
         committee_id = CommitteeId}) ->
    %% Idempotency: the live engine may have committed a prefix of this window while the pull worker was
    %% fetching it (a VOTING member gap-fills while still ingesting live consensus). Drop the already-present
    %% prefix so the append stays contiguous instead of failing `assert_contiguous`.
    case drop_index_le(quod_ledger_store:last(Store), Es0) of
        []  -> {S, ok};   %% window entirely already-present — nothing new to sink
        Es  ->
    case try quod_ledger_store:append(Store, Es) catch _:R -> {error, R} end of
        {error, _} = Err -> {S, Err};
        {ok, Store1} ->
            {Vs1, CommitteeId1, Ts1, Seqs1} =
                log_projection(
                  Ns, Es,
                  {Vs, CommitteeId, S#s.last_ts, S#s.author_seqs}),
            Included = committed_submission_slots(Ns, Es),
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
            Recovered0 =
                S#s{store = Store1, validators = Vs1,
                    committee_id = CommitteeId1, slot = Slot,
                    last_ts = Ts1, author_seqs = Seqs1,
                    next_author_seq =
                        max(S#s.next_author_seq,
                            maps:get(S#s.self, Seqs1, 0) + 1)},
            Recovered =
                settle_recovery_relays(
                  Slot, Included,
                  settle_recovery_custody(
                    Slot, Included, Recovered0)),
            S1 = reseat_engine(Slot, Recovered, Included),
            S2 = catchup_membership_transition(S, S1),
            {apply_committed(S2, catchup_origin(Source)), ok}
    end
    end.

catchup_origin({feed, live}) -> live;
catchup_origin(_)            -> replay.

%% Drop entries whose `#entry.index` is `=< LastI` (already durable) — keep only the genuinely-new tail so a
%% window that straddles a prefix the live engine committed meanwhile still appends contiguously.
drop_index_le(LastI, Es) -> [E || E <- Es, E#entry.index > LastI].

committed_submission_slots(Ns, Entries) ->
    lists:foldl(
      fun(#entry{index = Slot, data = Data}, Acc0) ->
              case quod_ledger:payload(Data) of
                  {ok, Payload} ->
                      lists:foldl(
                        fun(Transaction, Acc) ->
                                case quod_transaction:submission(
                                       Ns, Transaction) of
                                    {ok, Submission} ->
                                        Acc#{
                                          quod_transaction:submission_id(
                                            Submission) => Slot};
                                    {error, _} ->
                                        Acc
                                end
                        end, Acc0, Payload);
                  error ->
                      Acc0
              end
      end, #{}, Entries).

settle_recovery_relays(
  NewHead, Included, S = #s{relay_pending = Pending}) ->
    maps:fold(
      fun(Key,
          #relay_pending{from = From, submission_id = SubmissionId,
                         target_slot = TargetSlot},
          Acc) ->
              case maps:find(SubmissionId, Included) of
                  {ok, CommitSlot} ->
                      finish_relay(Key, From, {ok, CommitSlot}, Acc);
                  error when TargetSlot =< NewHead ->
                      finish_relay(Key, From, {error, skipped}, Acc);
                  error ->
                      Acc
              end
      end, S, Pending).

settle_recovery_custody(
  _NewHead, _Included, S = #s{custody = Custody})
  when map_size(Custody) =:= 0 ->
    S;
settle_recovery_custody(NewHead, Included, S) ->
    maps:fold(
      fun(SubmissionId, #custody{placement = Placement}, Acc) ->
              case maps:find(SubmissionId, Included) of
                  {ok, CommitSlot} ->
                      complete_custody(
                        SubmissionId, {ok, CommitSlot}, Acc);
                  error ->
                      case Placement of
                          ready ->
                              Acc;
                          {relay, _AttemptId, _Target,
                           TargetSlot, _CommitteeId}
                            when TargetSlot =< NewHead ->
                              mark_custody_ready(
                                SubmissionId, Acc);
                          {relay, _AttemptId, _Target,
                           _TargetSlot, _CommitteeId} ->
                              %% The recovered prefix has not classified this
                              %% remote attempt. Keep it active and ambiguous.
                              Acc;
                          {local, TargetSlot, _CommitteeId}
                            when TargetSlot =< NewHead ->
                              mark_custody_ready(
                                SubmissionId, Acc);
                          {local, _TargetSlot, _CommitteeId} ->
                              %% `nack_inflight/3` still owns the distinction
                              %% between an unpublished collection (safe to
                              %% place again) and a published local proposal
                              %% above the recovered head (ambiguous).
                              Acc
                      end
              end
      end, S, S#s.custody).

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
%% separate catch-up and promotion re-arms with one `eng_new/3` path. At
%% a joiner/observer site the latch resets are no-ops (no live-slot state); they are load-bearing for a VOTING
%% member gap-filling — the caller (`sink_catchup`) passes this through `keep_progress/3` to cancel a stale
%% head watchdog when `head_progress` is cleared here (a no-op where it is already idle).
-ifdef(TEST).
reseat_engine(NewHead, S) ->
    reseat_engine(NewHead, S, #{}).
-endif.

reseat_engine(NewHead, S, Included) ->
    S1 = prune_consensus_links(nack_inflight(S, NewHead, Included)),
    {ok, Journal1} = prune_vote_journal(NewHead, S1#s.vote_journal),
    S1#s{eng             = eng_new(S1#s.consensus_domain,
                                    active_validators(S1), NewHead),
          vote_journal    = Journal1,
          approved        = NewHead,
          commit_buf      = #{},
          block_requests  = #{},
          requested_slot  = none,
          head_progress   = idle,
          rounds          = vote_rounds(Journal1)}.

%% A recovery re-seat intentionally discards the whole volatile consensus window.
%% Its fresh engine cannot safely retain proposals or votes from the old base.
nack_inflight(S0 = #s{local_proposals = Local}, NewHead, Included) ->
    S1 =
        maps:fold(
          fun(Slot, #local_proposal{waiters = Waiters}, Acc) ->
                  reply_recovery_waiters(
                    Waiters, {proposal, Slot}, NewHead, Included, Acc)
          end, S0, Local),
    S2 =
        case S1#s.collecting of
            #batch{items_rev = Items} ->
                reply_recovery_waiters(
                  [Waiter || {Waiter, _Change} <- Items],
                  unpublished, NewHead, Included, S1);
            none ->
                S1
        end,
    {IngressItems, ClearedIngress} =
        quod_ingress_state:take_all(S2#s.ingress),
    S3 =
        lists:foldl(
          fun(Item, Acc) ->
                  {_Context, Waiter, _Request, _Anchor} =
                      quod_ingress_state:item(Item),
                  reply_recovery_waiter(
                    Waiter, unpublished, NewHead, Included, Acc)
          end, S2#s{ingress = ClearedIngress}, IngressItems),
    %% Recovery discards accepted inbound relay state and future-slot terminal
    %% cache entries. Reset each affected source stream at the same boundary,
    %% so it reconnects and replays its full retained author prefix before a
    %% later submission can enter this fresh incarnation alone.
    S4 = invalidate_relay_generation(NewHead, S3),
    S4#s{local_proposals = #{}, collecting = none,
         relay_inflight = #{}}.

reply_recovery_waiters(Waiters, Context, NewHead, Included, S) ->
    lists:foldl(
      fun(Waiter, Acc) ->
              reply_recovery_waiter(
                Waiter, Context, NewHead, Included, Acc)
      end, S, Waiters).

reply_recovery_waiter(
  Waiter = #waiter{submission_id = SubmissionId},
  Context, NewHead, Included, S)
  when is_binary(SubmissionId) ->
    case maps:find(SubmissionId, Included) of
        {ok, CommitSlot} ->
            reply_waiter(Waiter, {ok, CommitSlot}, S);
        error ->
            reply_recovery_exclusion(
              Waiter, Context, NewHead, S)
    end;
reply_recovery_waiter(Waiter, Context, NewHead, _Included, S) ->
    reply_recovery_exclusion(Waiter, Context, NewHead, S).

reply_recovery_exclusion(
  Waiter = #waiter{
             reply_to =
                 {relay, #relay_ref{target_slot = TargetSlot}}},
  _Context, NewHead, S) when TargetSlot > NewHead ->
    %% This attempt may still finalize in the live network. Forget volatile
    %% ownership and let the immutable source redrive reconstruct it; emitting
    %% a retryable result here could duplicate a write after this node restarts
    %% and loses that non-durable answer.
    finish_waiter_trace(
      Waiter, {error, not_in_charge, unavailable}),
    S;
reply_recovery_exclusion(
  #waiter{reply_to = {custody, SubmissionId}},
  unpublished, _NewHead, S) ->
    %% Collection never published a block or left this process, so reseating
    %% proves there is no surviving placement to duplicate.
    mark_custody_ready(SubmissionId, S);
reply_recovery_exclusion(
  Waiter = #waiter{}, {proposal, Slot}, NewHead, S)
  when Slot > NewHead ->
    %% A sealed local proposal beyond the recovered durable head may still win.
    %% Surface ambiguity, never a retry instruction.
    reply_waiter(
      Waiter, {error, not_in_charge, unavailable}, S);
reply_recovery_exclusion(Waiter, _Context, _NewHead, S) ->
    reply_waiter(Waiter, {error, skipped}, S).

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

%% ONE pass over a run of committed entries yielding every durable ordering projection: validator facts,
%% their exact adoption-block identity, the monotonic timestamp floor, and author sequence floors. The
%% committee identity advances only when this exact entry changes the set. Content and `noop` entries
%% therefore retain it, while remove→re-add in one window advances twice and the recurring set has a new
%% identity. Boot replay and catch-up both use this per-entry step; the latter seeds the current view.
-spec log_projection(
        binary(), [#entry{}],
        {[node_id()], binary() | undefined, non_neg_integer(),
         #{node_id() => non_neg_integer()}}) ->
        {[node_id()], binary() | undefined, non_neg_integer(),
         #{node_id() => non_neg_integer()}}.
log_projection(Ns, Entries, Seed) ->
    lists:foldl(fun(Entry, Acc) -> log_projection_step(Ns, Entry, Acc) end,
                Seed, Entries).

log_projection_step(
  Ns, #entry{data = Data, timestamp = T} = Entry,
  {V, CommitteeId, Ts, Seqs}) ->
    {V1, CommitteeId1} =
        project_entry_committee_view(Ns, Entry, V, CommitteeId),
    {V1, CommitteeId1, max(T, Ts), advance_author_seqs(Data, Seqs)}.

checked_log_projection_step(
  Ns, #entry{index = I, data = Data} = Entry,
  {V, _CommitteeId, _Ts, Seqs} = Acc) ->
    case valid_history_entry(Ns, I, Data, V)
         andalso historical_sequences_ok(I, Data, Seqs) of
        true  -> log_projection_step(Ns, Entry, Acc);
        false -> error({invalid_transaction_history, I})
    end.

%% Project one persisted entry onto the authoritative committee view. Reconstructing the committed block
%% here is load-bearing: the view id is bound to the same block hash that its finality certificate covered,
%% without adding a second hash representation to the ledger. A changed set can only come from a canonical
%% batch, so block reconstruction must succeed after history/catch-up verification.
project_entry_committee_view(
  Ns, #entry{index = Slot, data = Data} = Entry, Validators, CommitteeId) ->
    Validators1 = apply_committee_delta(Data, Validators),
    case Validators1 =:= Validators of
        true ->
            {Validators, CommitteeId};
        false ->
            {ok, Block} = block_from_entry(Entry),
            advance_committee_view(
              Ns, Slot, block_hash(Block), Data, Validators, CommitteeId)
    end.

advance_committee_view(
  Ns, AdoptionSlot, AdoptionBlockHash, Change, Validators, CommitteeId) ->
    NewValidators = apply_committee_delta(Change, Validators),
    case NewValidators =:= Validators of
        true ->
            {Validators, CommitteeId};
        false ->
            {NewValidators,
             committee_view_id(
               Ns, AdoptionSlot, AdoptionBlockHash, NewValidators)}
    end.

-spec committee_view_id(binary(), slot(), binary(), [node_id()]) -> binary().
committee_view_id(Ns, AdoptionSlot, AdoptionBlockHash, NewValidators) ->
    crypto:hash(
      sha256,
      term_to_binary(
        {quod_committee_view, 1, Ns, AdoptionSlot, AdoptionBlockHash,
         lists:sort(NewValidators)},
        [deterministic])).

historical_sequences_ok(1, {batch, [_Genesis]}, _Seqs) ->
    true;
historical_sequences_ok(_I, {batch, Payload}, Seqs) ->
    transaction_sequences_ok(Payload, Seqs, #{});
historical_sequences_ok(_I, noop, _Seqs) ->
    true.

%% The committee change carried by one committed payload: the `peer_admitted` pubkeys it asserts (added)
%% and retracts (removed). Each transaction folds its diff (the validator id is the 4th arg / 5th element
%% of `peer_admitted(NodeId, Host, Port, Pubkey)`); a `noop` or malformed payload changes nothing. This ONE
%% function feeds BOTH the live commit-time swap (`adopt_committee/4`) and the boot/restart re-fold
%% (`log_projection/3`), so the running set can never drift from a fresh re-fold.
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

%% Set-like accumulation; callers sort before exposing the result, so prepend
%% avoids copying the growing list while preserving idempotence.
addq(M, L) ->
    case lists:member(M, L) of
        true  -> L;
        false -> [M | L]
    end.

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
    lists:usort(lists:reverse(Adds, V) -- Removes).

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

%% Config validation: `node_id` is required; `committee` is the complete founding set besides self
%% (`[]` = self-only). Only the smallest founding pubkey may use `mode=create`; every other founding
%% member uses `mode=join` pinned to the creator's anchor. `batch_window_ms` is bounded below the append
%% deadline, and every joiner must carry that out-of-band `genesis_hash`.
valid_cfg(Config, Cfg) ->
    case maps:get(node_id, Config, undefined) of
        undefined ->
            {error, missing_node_id};
        Pk when is_binary(Pk), byte_size(Pk) =:= 32 ->
            valid_genesis_source(Cfg);
        Other ->
            {error, {bad_node_id, Other}}
    end.

valid_genesis_source(Cfg) ->
    case {genesis_file(Cfg), maps:get(genesis_terms, Cfg, undefined)} of
        {none, undefined} -> valid_batch_window(Cfg);
        {none, Terms} when is_list(Terms) -> valid_batch_window(Cfg);
        {none, _InvalidTerms} -> {error, invalid_genesis_terms};
        {_File, undefined} -> valid_batch_window(Cfg);
        {_File, _Terms} -> {error, multiple_genesis_sources}
    end.

valid_batch_window(Cfg) ->
    case maps:get(batch_window_ms, Cfg) of
        N when is_integer(N), N >= 0, N =< 1000 ->
            valid_committee(Cfg);
        Other -> {error, {bad_batch_window_ms, Other}}
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
        create -> valid_creator(Cfg);
        join   -> case maps:get(genesis_hash, Cfg) of
                      H when is_binary(H), byte_size(H) =:= 32 -> ok;
                      _                   -> {error, join_requires_genesis_hash}
                  end;
        Other  -> {error, {bad_mode, Other}}
    end.

valid_creator(Cfg) ->
    Self = maps:get(node_id, Cfg),
    [{Canonical, _, _} | _] = founding(Cfg, Self),
    case Self =:= Canonical of
        true  -> ok;
        false -> {error, {create_requires_canonical_founder, Canonical}}
    end.

%% A committee element is a 32-byte public key or a `{Pubkey, Host, Port}` tuple — checked here so
%% canonical-founder ordering is always byte ordering over real Ed25519 key shapes.
valid_member(Pk) when is_binary(Pk), byte_size(Pk) =:= 32 ->
    true;
valid_member({Pk, _Host, _Port})
  when is_binary(Pk), byte_size(Pk) =:= 32 ->
    true;
valid_member(_) ->
    false.

data_dir(Cfg) -> quod_ledger_store:data_dir(Cfg).

genesis_file(Cfg) ->
    case maps:get(genesis_file, Cfg, undefined) of
        undefined -> none;
        <<>>      -> none;
        ""        -> none;
        File      -> File
    end.

genesis_terms(Cfg) ->
    case {genesis_file(Cfg), maps:get(genesis_terms, Cfg, undefined)} of
        {none, undefined} ->
            [];
        {none, Terms} when is_list(Terms) ->
            Terms;
        {File, undefined} ->
            quod_prolog:read_terms(File);
        {none, _InvalidTerms} ->
            throw({genesis_failed, invalid_genesis_terms});
        {_File, _Terms} ->
            throw({genesis_failed, multiple_genesis_sources})
    end.

status_map(S) ->
    Role = case is_participant(S) of true -> validator; false -> observer end,
    {_ProgressSlot, ProgressPhase, ProgressQuorum} = progress_status(S#s.head_progress),
    ProposalSlot = S#s.approved + 1,
    #{role => Role, committee => S#s.validators,
      committee_id => S#s.committee_id,
      slot => S#s.slot,
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
    IngressQueued = quod_ingress_state:count(S#s.ingress),
    #{slot => S#s.slot, committed => S#s.slot, approved => S#s.approved,
      pipeline_gap => max(0, S#s.approved - S#s.slot), last_applied => S#s.last_applied,
      committee_size => length(S#s.validators), appends => S#s.appends,
      proposals => S#s.proposals, batched_txs => S#s.batched_txs,
      batch_window_ms => S#s.batch_window_ms,
      commits => S#s.commits, prolog_ready => S#s.prolog_ready,
      submitted => S#s.submitted, skips => S#s.skips, pending => pending_count(S),
      requested_slot => case S#s.requested_slot of none -> 0; Requested -> Requested end,
      r_busy => S#s.r_busy, r_redirect => S#s.r_redirect, r_bad => S#s.r_bad,
      r_stale => S#s.r_stale,
      ingress_queued => IngressQueued,
      ingress_overflow => S#s.ingress_overflow,
      ingress_expired => S#s.ingress_expired,
      ingress_forwarded => S#s.ingress_forwarded,
      custody_depth => map_size(S#s.custody),
      custody_ready => gb_sets:size(S#s.custody_ready),
      custody_bytes => S#s.custody_bytes,
      ingress_retargets => S#s.ingress_retargets,
      relay_accepted => S#s.relay_accepted,
      relay_redrives => S#s.relay_redrives,
      relay_duplicates => S#s.relay_duplicates,
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
    CollectingN = case Collecting of #batch{count = Count} -> Count; none -> 0 end,
    CollectingN + lists:sum([length(P#local_proposal.waiters) || P <- maps:values(Local)]).
