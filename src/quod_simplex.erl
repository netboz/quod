-module(quod_simplex).
-export([entry_history_hash/1]).
-include("quod_dtx_owner.hrl").
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
transactions remain singleton barriers. Compatible DTX controls of one phase
form a canonical wave in one block; exact read/write/custody intersections,
rather than the mere presence of a group, decide whether ordinary content must
wait. A prepared role's Resolve installs a proof fence until ordered Prolog
apply/discard is published. Origin Complete publishes the terminal group
outcome and releases its origin role independently for each group in the wave.

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
A relay destination acknowledges once it holds the request. The sender keeps
one exact attempt on its reliable stream, reconstructing the retained ordered
prefix only when a replacement link opens. Only the origin's durable log
resolves inclusion or exclusion.

One explicit `head_progress` state watches the oldest non-final slot (`committed+1`) through
`awaiting_proposal`, `awaiting_notarization`, and `awaiting_commit`. Notarization changes phase; it
does not cancel the watchdog. Complaint signing pauses while fewer than a certificate quorum have
authenticated inbound consensus streams carrying fresh, height-compatible readiness reports. The first
three quorum restorations for one unchanged phase start a fresh full Delta; later flaps cannot extend its
deadline. A member that accepted a proposal while recovering runs that held proposal through the normal
support or membership-verdict path once ready.

A verified complaint from another current committee member also creates demand for this oldest-head
watchdog, allowing a single honest origin to move past a silent leader. Duplicate complaints do not
renew its deadline; readiness checks, durable vote guards and certificate thresholds still apply.
A faulty member can therefore keep an otherwise idle namespace advancing through timeout-paced,
certified `noop` skips while enough honest members remain ready. This consumes ledger space and
signing-journal/network I/O without changing application facts. For `N=4`, a skip still needs three
distinct signatures; two peer complaints permit amplification, not a two-signature certificate.

Every first support or final-vote decision is appended and synced through `m:quod_signing_journal`
before its signature can leave the node. Restart therefore reloads the same one-support and
commit-versus-complaint decisions instead of creating a second vote. One decision table owns every
first final vote in both live pipeline slots: `f+1` visible peer complaints select the skip camp;
otherwise a notarized block selects commit, while only the watchdog or an invalid-membership verdict may
create a complaint without amplified evidence. A member that has a support certificate but lacks the
corresponding block rotates point-to-point requests through certificate signers and then other committee
members, and accepts a response only after checking the certificate, block hash, parent, timestamp, payload,
and local final-vote compatibility.

These rules recover the observed mixed-camp and proposer-loss outages without copying the KB. A
support decision atomically retains that exact canonical block until its slot commits; this bounded
live-window custody lets any restarting supporter serve the body again. The Byzantine safety model remains `<=f`; durable latches additionally
preserve honest voting behavior across any number of process restarts. Recovery after a temporary
`>f` crash outage is a liveness extension, not an unconditional theorem: a final-vote split formed
before either side's `f+1` evidence becomes visible still needs a future view-change protocol.

The same engine handles N=1 and multi-validator namespaces, complaint-certified skips,
trustless catch-up, observer promotion, live member recovery, and deterministic Prolog apply.
Every non-genesis transaction is namespace-bound and Ed25519-signed by its author,
and every wire transaction is checked before an honest validator votes for it.
Remaining security work, notably author-aware authorization, epoch-frozen validator sets, and the
residual simultaneous final-vote split above, is tracked in `doc/deferred.md`.
""".

-include("quod_ledger.hrl").
-include("quod_ingress_limits.hrl").
-include("quod_proof_limits.hrl").
-include("quod_transport_limits.hrl").

-define(MAX_SLOT, 16#FFFFFFFFFFFFFFFF).   %% share_bytes/4 signs slots as unsigned 64-bit integers
-define(PIPELINE_DEPTH, 1).               %% at most one approved parent may remain uncommitted
%% v2: the V3 ledger break. A vote is bound to the format of the history it
%% attests, so a share signed under the old entry/transaction formats can never
%% verify against a V3 chain — no old share, cert or journal entry is decodable
%% into a valid vote here.
-define(SHARE_DOMAIN_VERSION, 2).
-define(SHARE_DOMAIN_TAG, <<"quod/simplex/domain">>).
-define(SHARE_MESSAGE_TAG, <<"quod/simplex/share">>).
-define(SKIPPED_SLOT_TAG, <<"quod/simplex/skipped-slot">>).
-define(SKIPPED_SLOT_VERSION, 1).
-define(GENESIS_TX_VERSION, 1).
-define(GENESIS_TX_TAG, "quod/genesis").

-behaviour(gen_statem).

%% Pure consensus core (also used by the gen_statem below, the catch-up verifier, and the tests).
-export([quorum/1, leader/2, prepare_genesis/3,
         block_hash/1, block_from_entry/1, consensus_domain/2, share_bytes/4,
         make_share/5, verify_share/2,
         verify_cert/3,
         may_commit/2, may_complain/2, well_formed_block/1,
         valid_genesis_transaction/2, genesis_predicate_manifest/1,
         valid_history_entry/4, valid_history_entry/5,
         history_projection/0, history_projection/1, history_projection/5,
         history_committee/1, history_committee_view/2,
         history_certifying_committee_view/2,
         history_validator_routes/1,
         history_advance/3, history_advance/4,
         history_validate_advance/3, history_validate_advance/4,
         history_preview_advance/5,
         committee_delta/1, apply_committee_delta/2,
         membership_diff_acceptable/2]).   %% committee = projection of peer_admitted facts

-export_type([history_projection/0, history_view/0]).

%% Per-namespace consensus process — API + gen_statem callbacks.
-export([start_link/2, rebuild/1, prolog_ready/4, operation_projection/4,
         await_operation_result/3,
         resolve_applied/4,
         handoff_effect/3,
         register_transaction_custody/3,
         start_transaction_custody_cancellation/2,
         activate_transaction_custody/2,
         cancel_transaction_custody/2,
         dtx_binding/1, dtx_ready_binding/1, register_dtx_vote/6, activate_dtx_vote/3,
         cancel_dtx_vote/3,
         dtx_endpoint_request/7, dtx_endpoint_local/4,
         history_view/3, history_view_at/3, history_view_live/1,
         operation_claim_evidence/4,
         operation_completion_evidence/4,
         dtx_local_evidence/4, dtx_applied_source/2,
         dtx_outcome_lookup/2,
         status/1, committee/1, genesis_hash/1,
         await_proof_access/3, check_proof_access/1,
         identity_view/1,
         stats/1, namespaces/0]).
-export([init/1, callback_mode/0, running/3, terminate/3]).

-ifdef(TEST).
-export([apply_operation_projection/3, await_operation_recovery/5,
         cancel_operation_waiter/4,
         finish_operation_target_result/5, install_operation_snapshot/2,
         drop_operation_recovery_owner/4, drop_operation_waiter/3,
         settle_operation_recovery/3, block_operation_recovery/4,
         test_operation_recoveries/1, test_seed_operation_worker/3,
         test_start_operation_recovery/3]).
%% consensus-engine surface driven by eunit (the #eng record is otherwise private)
-export([append/2, history_binding/3,
         form_cert/6,
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
         restore_signing_state/1, restore_signing_engine/1,
         proposal_slot/1, acceptable_payload/2, needs_hint_warm/2,
         reconcile_head_progress/1, resume_ready_rounds/1,
         on_progress_timeout/2, progress_timer_actions/2, watch_requested/2,
         settle_readiness/2, prune_consensus_links/1,
         dispatch/3, reconcile_block_requests/1,
         test_progress/1, test_progress_rearms/1, test_support_grace/1,
         test_round/2, test_dtx_round/2, test_dtx_round_hints/2,
         test_proposal_rejection/2, test_collected_payload/2,
         test_latch_dtx_validation/6, test_on_dtx_verdict/7,
         apply_dtx_verdict/7,
         test_dtx_source_identity/2,
         test_local_history_view/3, test_local_history_view/4,
         test_consensus_barrier/1, test_dtx_consensus_barrier/1,
         test_requested/1,
         test_progress_counts/1, test_engine_pool_sizes/1,
         test_committed_store/1, test_link_peers/1,
         test_retired_inbound/1,
         test_relay_link_peers/1, test_relay_chan/1,
         test_prune_relay_links/1,
         test_reconcile_relays/1,
         test_invalidate_relay_generation/2,
         test_close_relay_transport/1,
         test_relay_transport_counts/1,
         test_redrive_head/3, test_block_requests/1, test_signing_journal/1,
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
         test_expire_relay_results/1,
         test_reply_relay/7,
         test_custody/1, test_custody_authors/1,
         test_register_dormant_transaction/4,
         test_start_dormant_transaction_cancellation/4,
         test_activate_dormant_transaction/3,
         test_cancel_dormant_transaction/3,
         test_restart_dormant_custody_owner/4,
         test_custody_owner/2,
         test_place_transaction_custody/3,
         test_mark_custody_lane_ready/1,
         test_settle_recovery_custody/3,
         test_resolve_committed_submissions/3,
         test_drain_custody/1,
         test_keep_progress_transition/2,
         test_expire_custody/1,
         test_outbox/1,
         test_ingress_needs_drain/2,
         test_round_probe/1, test_route/4,
         test_trace_block/5, test_trace_block_event/5, test_start_content_validation/5,
         on_content_foreign_verdict/6,
         proposal_visible/2, reseat_engine/2,
         committee_view_id/4, test_committee_id/1,
         test_author_admissions/1,
         test_author_admission/1,
         test_set_author_admissions/2,
         test_retire_changed_admissions/3,
         test_install_projection/2, test_state_projection/1,
         test_dtx_slot_route/2,
         test_dtx_endpoint_ready/2,
         test_dtx_outcome_result/2,
         test_validate_dtx_reference_evidence/2,
         test_verify_content_requirements/2,
         test_content_reference_contacts/3,
         test_verify_complete_applied/3,
         test_relevant_validation_sidecar/2,
         test_merge_validation_sidecars/2,
         test_fit_consensus_validation_sidecar/2,
         test_dtx_endpoint_frame/6,
         test_dtx_outbound_message/5,
         test_seed_dtx_correlation/5,
         test_seed_opening_dtx_correlation/5,
         test_seed_opening_dtx_correlation/6,
         test_dtx_correlation_link_up/5,
         test_dtx_correlation_link_error/4,
         test_timeout_dtx_correlation/2,
         test_drop_dtx_correlation_caller/2,
         test_dtx_endpoint_result/3, test_dtx_endpoint_result_at/4,
         test_dtx_endpoint_result_with_hints/3,
         test_waiting_applied_key/2,
         test_seed_dtx_worker/5,
         test_finish_dtx_worker/3,
         test_start_local_dtx_endpoint_request/5,
         test_wake_dtx_snapshot_workers/2,
         test_drop_dtx_endpoint_owner/3,
         test_close_dtx_endpoint/1,
         test_seed_dtx_submission/3,
         test_seed_dtx_submission_at/4,
         test_eligible_dtx_wave/1,
         test_blocked_dtx_owner/2, test_drive_retained_dtx/1,
         test_propose_dtx_wave/4,
         test_bind_claimed_effect/5,
         test_dtx_drive_scheduled/1,
         test_resolve_committed_dtx/3, test_restore_pending_dtx/2,
         test_retain_dtx_record/3,
         test_dtx_retain_admissible/2,
         test_dtx_submission_waiters/1,
         test_retained_dtx_state/1, test_refresh_retained_readiness/1,
         test_refresh_retained_dtx_signatures/1,
         test_enqueue_dtx_intent/7, test_progress_dtx_admission/1,
         on_admission_verdict/7, on_admission_parent_applied/3,
         test_activate_dtx_intent/3, test_cancel_dtx_intent/3,
         test_dtx_admission_state/1, test_drop_dtx_admission_owner/1,
         test_reconcile_signing_state/1,
         test_finish_pending_votes_reconciliation/2,
         test_retire_invalid_dtx/3,
         test_reconcile_dtx_coordinator/1,
         test_reconcile_dtx_coordinators/2,
         test_drop_dtx_coordinator/4,
         test_start_dtx_coordinator_worker/3,
         test_dtx_coordinator_state/1,
         test_stop_dtx_coordinator/1,
         test_seed_running_dtx_coordinator/3,
         test_activate_dtx_coordinator/2,
         test_notify_dtx_coordinator_progress/2,
         test_dtx_endpoint_counts/1, test_dtx_correlation_timers/1, test_owner_stats/1,
         test_operation_target_result/2,
         test_operation_wait_before_projection/2,
         test_endpoint_terminal_result/1,
         test_dtx_worker_terminal_result/2,
         test_dtx_retirement_result/1,
         test_log_projection/3,
         test_apply_catchup_window/3, test_apply_catchup_window/4,
         test_genesis_tx/4, test_valid_genesis_source/1,
         test_valid_config/1,
         stats_map/1, encode/2]).   %% encode/2: the `{log, Ns}` wire frame — used by simplex_SUITE to inject a crafted propose
-endif.

%% These validate records decoded from UNTRUSTED peer input (binary_to_term yields any term, so a
%% typed record can still carry malformed fields at runtime). Dialyzer trusts the declared field types
%% and consequently marks their reject branches unreachable; weakening the canonical record types would
%% hide useful mistakes everywhere else.
-dialyzer({nowarn_function, [dispatch/3, well_formed_block/1, well_formed_share/1,
                             committee_transaction/2,
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
    quod_quorum:threshold(N).

%%%===================================================================
%%% block hashing + the bytes a share signs
%%%===================================================================

-doc "A block's content hash over the producer's exact canonical bytes.".
-spec block_hash(#block{}) -> binary().
block_hash(#block{} = Block) ->
    case quod_ledger:block_bytes(Block) of
        Bytes when is_binary(Bytes) -> crypto:hash(sha256, Bytes);
        error -> error(uncanonical_block)
    end.

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
form_cert(Domain, Kind, Slot, BlockHash, Shares, Validators) ->
    case {bounded_validator_count(Validators),
          is_slot(Slot) andalso valid_shape(Kind, BlockHash)} of
        {{ok, N}, true} when N > 0 ->
            Msg  = share_bytes(Domain, Kind, Slot, BlockHash),
            Sigs = distinct_valid([{S#share.signer, S#share.sig}
                                    || S <- Shares,
                                       S#share.kind =:= Kind,
                                       S#share.slot =:= Slot,
                                       S#share.block_hash =:= BlockHash],
                                   Msg, Validators),
            case length(Sigs) >= quorum(N) of
                true  -> {ok, #cert{kind = Kind, slot = Slot, block_hash = BlockHash, sigs = Sigs}};
                false -> {error, insufficient}
            end;
        _ ->
            {error, insufficient}                %% empty/oversized/malformed committee or cert shape
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
bounded_signatures(Signatures, Remaining) ->
    quod_quorum:valid_signature_list(Signatures, Remaining).

valid_signer_signature(Signer, Sig) ->
    is_binary(Signer) andalso byte_size(Signer) =:= 32
        andalso is_binary(Sig) andalso byte_size(Sig) =:= 64.

%% Keep one signature per signer, from validators in the set, whose signature verifies over `Msg`.
distinct_valid(Sigs, Msg, Validators) ->
    case quod_quorum:sanitize(Validators, Msg, Sigs) of
        {ok, Valid} -> Valid;
        error -> []
    end.

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

%% Swap the engine's voting set to the ACTIVE validator set (`active_validators/1`) when `adopt_projection/3`
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
            case payload_is_consensus_barrier(Payload) of
                true -> none;   %% committee and DTX transitions require explicit finality
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
    case bounded_validator_count(Validators) of
        {ok, N} when N > 0 ->
            sanitize_cert_bounded(
              Domain, C, K, Sl, BH, Sigs, Validators, N);
        _ ->
            error
    end.

sanitize_cert_bounded(Domain, C, K, Sl, BH, Sigs, Validators, N) ->
    case is_slot(Sl) andalso valid_shape(K, BH)
         andalso bounded_signatures(Sigs, N) of
        false -> error;
        true ->
            Valid = distinct_valid(
                      Sigs, share_bytes(Domain, K, Sl, BH), Validators),
            case length(Valid) >= quorum(N) of
                true  -> {ok, C#cert{sigs = Valid}};
                false -> error
            end
    end.

%% Validator lists come from authenticated history but still cross untrusted
%% replay/catch-up boundaries. Count only through the shared limit so an
%% oversized or improper list is rejected before signer traversal or crypto.
bounded_validator_count(Validators) ->
    quod_quorum:committee_size(Validators).

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
          genesis_diff => undefined,   %% precompiled initial content (mutually exclusive with file)
          genesis_hash => undefined,   %% join config pin; resolved to the immutable slot-1 anchor in every mode
          batch_window_ms => 25,        %% per-ontology micro-batch collection window
          data_dir     => undefined}).

-define(MAX_OUTBOX, 1024).   %% per-peer cap on frames buffered while a link opens (bounds memory vs a dead peer)
-define(TICK_MS,     300).   %% consensus re-drive cadence: re-dial peers whose link never came up (liveness)
-define(DIAL_TIMEOUT_MS, 15000).  %% presume a dial lost if neither link_up nor link_error arrives within this
-define(LINK_CLOSE_TIMEOUT_MS, 500). %% graceful incarnation boundary: allow the ordered link FIFO to drain,
                                  %% then sweep its marker so the tick re-dials (guards a conn that dies
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
-define(SYNC_BACKOFF_MIN, 3).  %% failure backoff floor (ticks) before re-arming a sync after no_contact/error
-define(SYNC_BACKOFF_MAX, 20). %% failure backoff cap (ticks) — exp-doubled, ±20% jittered, single-flight-paced
-define(APPLY_SYNC_EVERY, 256).  %% streamed replay: drain quod_prolog (sync barrier) every this many casts
-define(MAX_FUTURE_MS, (2 * 60 * 60 * 1000)).  %% block-timestamp future skew tolerance (2h, cf. Bitcoin MAX_FUTURE_BLOCK_TIME)
-define(INGRESS_TTL_MS, 7000).                    %% parked-item cutoff. One eligible slot may burn a full
                                                  %% quorum-flap complaint cycle
                                                  %% (Δ×(1+?MAX_QUORUM_REARMS) = 4s) before the skip lands;
                                                  %% flight time is negligible. 7s covers that worst legit
                                                  %% wait yet stays under the caller's 8s append timeout,
                                                  %% so a REAL stall still fails visibly (busy) while the
                                                  %% caller can still hear it — the queue never hides a wedge
-define(SIGNATURE_VERIFY_TIMEOUT_MS, 2000).       %% fail closed if a crypto worker wedges
-define(DTX_FOREIGN_VERIFY_MS, 6000).             %% cache-fill workers may outlive one Delta;
                                                  %% proposal redrive reuses the verified cache
-define(MAX_QUORUM_REARMS, 3).                    %% bound link-flap deadline extension per slot/phase
-define(READINESS_MS, 1000).                      %% readiness refresh; at or below the default Delta
-define(READINESS_FRESH_MS, 3000).                %% tolerate two missed refreshes, then fail closed
-define(BLOCK_REQUEST_RETRY_MS, 500).              %% rotate a missing certified block request to another holder

-type final_vote() :: none | {commit, binary()} | complaint.
-type final_vote_trigger() :: notarized | complaint_evidence | timeout | rejected.
-record(round, {supporting = none :: none | binary(),
                final = none :: final_vote(),
                invalid = none :: none | binary(),
                invalid_reason = none :: none | term(),
                validating = none :: none | binary(),
                validation = none :: none | content |
                    {content_foreign, pid(), reference()} |
                    {dtx, term(), pid(), reference(), integer()} |
                    {dtx_foreign, term(), pid(), reference(),
                     #{<<_:256>> => quod_atomic:group_history()}, integer()},
                %% An offered body has no admission/validation authority. Only
                %% the existing two-tuple arm is an admitted DTX candidate.
                candidate = none :: none | {offered, binary(), #block{}} |
                    {binary(), #block{}},
                validation_sidecar = [] :: [quod_dtx_endpoint:validation_item()],
                dtx_parent = none :: none |
                    {binary(), term(),
                     #{<<_:256>> => quod_atomic:group_history()},
                     quod_atomic:projection()}}).

-record(batch, {slot :: slot(),
                parent :: slot(),
                items_rev = [] :: [{term(), #transaction{}}],
                count = 0 :: non_neg_integer(),
                bytes = 0 :: non_neg_integer(),
                tx_ids = #{} :: #{binary() => true},
                operation_claims = #{} :: map(),
                sequences = #{} :: #{{node_id(), pos_integer()} => true},
                sequence_floor = #{} :: #{node_id() => non_neg_integer()},
                opened_at = 0 :: integer()}).   %% monotonic ms; measures collection wait on this proposer

-record(waiter, {reply_to :: term(),
                 submission_id = undefined :: binary() | undefined,
                 trace_ctx :: quod_trace:context(),
                 trace_span :: quod_trace:span_ctx() | undefined}).

-record(local_proposal, {hash :: binary(),
                         waiters = [] :: [term()],
                         trace_ctxs = [] :: [quod_trace:context()],
                         validation_sidecar = [] ::
                           [quod_dtx_endpoint:validation_item()]}).

%% Simplex owns accepted admission independently of the proof engine. The
%% existing monitor only invalidates proof reservations/validation replies;
%% the pure FIFO library carries no process or second ownership inventory.
-record(dtx_admission, {
    engine = none :: none | pid(),
    monitor = none :: none | reference(),
    waiting :: quod_atomic_admission:state()
}).

%% Volatile request ownership for the process-free DTX endpoint. The request is
%% not sent until the exact pinned link authenticates; its monitor then owns the
%% only accepted reply path. The timeout is a final silent-peer safeguard, not a
%% progress/retry clock.
-record(dtx_correlation, {
    target_ns :: binary(),
    peer :: node_id(),
    request :: quod_dtx_endpoint:request(),
    frame :: binary(),
    channel :: binary(),
    endpoint :: {inet:hostname(), inet:port_number()},
    open_ref :: reference(),
    link = none :: none | pid(),
    link_mref = none :: none | reference(),
    from :: term(),
    caller_mref :: reference(),
    timer :: reference(),
    timeout_tag :: reference(),
    started_at = undefined :: undefined | integer()
}).

%% Inbound endpoint work never runs in the consensus statem.  The monitor is
%% the sole lifecycle edge and the exact inbound link is the sole reply path.
-record(dtx_server_worker, {
    pid :: pid(),
    monitor :: reference(),
    owner_mref = none :: none | reference(),
    peer :: local | node_id(),
    contact = none :: none | {node_id(), term()},
    request :: quod_dtx_endpoint:request(),
    attestation = none :: none | term(),
    snapshot_resampled = -1 :: integer(),
    destination :: {link, pid()} | {caller, term()},
    started_at = undefined :: undefined | integer()
}).

%% One monitored driver for a local role. GroupId is its immutable ownership
%% identity; certification changes the role projection, not the child lifetime.
%% The installed own row already carries the material needed for recovery.
-record(dtx_coordinator_owner, {
    group_id :: <<_:256>>,
    %% Keep the original parent separate: a replacement is another attempt,
    %% never a child of the span this owner has already released.
    trace_ctx = #{} :: quod_trace:context(),
    coordinate_span = none :: quod_attempt_span:handle(),
    pid = none :: none | pid(),
    monitor = none :: none | reference()
}).

%% One volatile worker for durable claim recovery OR outstanding result
%% delivery. Completing the source receipt ends the first obligation, not the
%% second. The existing outcome index reconstructs late callers; terminal
%% history with no waiting caller retains neither a worker nor a result cache.
-record(operation_recovery_owner, {
    operation_ref :: term(),
    %% Live request ancestry only; reconstructed history has no trace parent.
    trace_ctx = #{} :: quod_trace:context(),
    attempt_span = none :: quod_attempt_span:handle(),
    claim_state = unknown :: unknown | unresolved | terminal,
    claim_slot = none :: none | pos_integer(),
    claim_tx_id = none :: none | <<_:256>>,
    target_refs = none :: none | [term()],
    %% One target-keyed volatile result set; no scalar result cache beside it.
    target_results = #{} :: map(),
    request_digest = none :: none | <<_:256>>,
    status = pending ::
        pending | running | blocked | settling,
    pid = none :: none | pid(),
    monitor = none :: none | reference(),
    waiters = #{} :: #{reference() => {gen_statem:from(), reference(), integer()}}
}).

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
                        accepted = false :: boolean()}).

%% One origin-owned, signed ordinary submission. The signature and canonical
%% envelope never change; only the unsigned exact-slot placement does. Caller
%% ownership lives here across local collection, sealed proposals, and outbound
%% relay attempts. A destination relay never creates custody and can never
%% retarget.
-type custody_placement() ::
        dormant
      | {cancelling, pid(), reference()}
      | ready
      | {local, slot(), binary()}
      | {relay, binary(), node_id(), slot(), binary()}.
-record(custody, {waiter :: #waiter{},
                  change :: #transaction{},
                  submission :: term(),
                  original_arrival :: integer(),
                  deadline :: integer(),
                  placement = ready :: custody_placement(),
                  dormant_owner = none :: none | {pid(), reference()},
                  attempts = 0 :: non_neg_integer(),
                  bytes :: pos_integer()}).

-ifdef(TEST).
-type signing_journal() :: quod_signing_journal:handle() | memory | undefined.
-else.
-type signing_journal() :: quod_signing_journal:handle() | undefined.
-endif.

-record(s, {ns           :: binary(),
            consensus_domain :: <<_:256>> | undefined,
            self         :: node_id(),               %% our pubkey == node_id
            id           :: signer() | undefined,    %% signing identity (pubkey + private key)
            store        :: quod_ledger_store:handle() | undefined,
            signing_journal :: signing_journal(),
            eng          :: #eng{} | undefined,      %% the consensus engine (certificate pool + block tree)
            chan         :: binary() | undefined,    %% term_to_binary({log, Ns}) — the transport channel
            relay_chan   :: binary() | undefined,    %% term_to_binary({ingress, Ns}) — relay-only stream
            dtx_chan     :: binary() | undefined,    %% bounded DTX recovery request/reply stream
            validators   = [] :: [node_id()],        %% the committee FACTS — sorted `peer_admitted` pubkeys,
                                                     %% the KB projection re-derived from the committed log
                                                     %% (in-process). The ACTIVE voting set derives from this
                                                     %% via `active_validators/1` (identity at epoch length 1);
                                                     %% "who votes now" reads route through THAT, not this field.
            validator_routes = #{} :: #{node_id() => {term(), pos_integer()}},
                                                     %% bounded endpoint projection from the same committed
                                                     %% peer_admitted facts; every use still pins TLS to the key
            committee_id = undefined :: binary() | undefined,
                                                     %% hash identity of the exact membership-adoption block;
                                                     %% undefined only while the namespace has no founded view
            committee_start = undefined :: slot() | undefined,
                                                     %% first slot governed by committee_id; retained so the
                                                     %% live one-row projection can distinguish its current era
                                                     %% from historical references without replaying current-era
                                                     %% history or relabelling old slots with today's committee
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
            trace_owner_turns = false :: boolean(),
            author_admissions = #{} :: #{node_id() => binary()},
            author_seqs = #{} :: #{node_id() => non_neg_integer()},
            dtx_projection = undefined :: undefined | quod_atomic:projection(),
            dtx_lanes = #{} :: #{{binary(), node_id()} => non_neg_integer()},
            dtx_admission = none :: none | #dtx_admission{},
            retained_dtx = quod_dtx_owner:new() :: quod_dtx_owner:state(),
            %% One mailbox edge coalesces every control already admitted by
            %% this process. It is deliberately a message, not a batching
            %% timer: controls already waiting in the mailbox join the same
            %% byte-bounded wave and the next turn drives it immediately.
            dtx_drive_scheduled = false :: boolean(),
            dtx_correlations = #{} ::
              #{binary() => #dtx_correlation{}},
            dtx_out_channels = #{} ::
              #{binary() => {binary(), pos_integer()}},
            dtx_workers = #{} :: #{pid() => #dtx_server_worker{}},
            owner_row_peaks = #{} :: #{{atom(), atom()} => non_neg_integer()},
            owner_byte_peaks = #{} :: #{atom() => non_neg_integer()},
            dtx_coordinators = #{}
              :: #{<<_:256>> => #dtx_coordinator_owner{}},
            operation_recoveries = #{} ::
              #{term() => #operation_recovery_owner{}},
            history_head = none :: none | {slot(), <<_:256>>},
            phase_index = undefined :: undefined | quod_dtx_phase_index:index(),
            next_author_seq = 1 :: pos_integer(),
            prolog_ready = false :: boolean(),
            %% Recovery is one explicit state machine. `unconfirmed` means the durable prefix is valid but
            %% its tip has not been corroborated; `{pulling,Pid}` gives one worker exclusive ownership of
            %% catch-up ingestion; only `ready` may emit consensus evidence. This single enum cannot
            %% represent the unsafe combinations the
            %% former `sync` latch + `confirmed` boolean allowed after a partial or failed pull.
            sync         = unconfirmed :: unconfirmed | {pulling, pid()} | ready,
            sync_arm     = {0, 0} :: {non_neg_integer(), non_neg_integer()},
                                        %% {failure cooldown ticks, backoff interval ticks}
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
            weak_cert_waits = 0 :: non_neg_integer(), %% sub-quorum finalizations refused
            validation_ttl_ms = ?QUOD_VALIDATION_TTL_MS :: non_neg_integer()}).

-ifdef(TEST).
%% Build a minimal #s{} for the Slice-4 gate-predicate eunit (the record is otherwise private). Only the
%% fields the pure predicates read carry meaning; every other field takes its record default.
test_state(Overrides) ->
    S0 = maps:fold(fun(approved, _V, Acc) -> Acc;
                     (ingress, _V, Acc) -> Acc;
                     (validators, _V, Acc) -> Acc;
                     (author_admissions, _V, Acc) -> Acc;
                     (K, V, Acc) -> test_state_set(K, V, Acc)
                  end,
                  #s{ns = <<"t">>, self = <<"self">>,
                     consensus_domain =
                         consensus_domain(<<"t">>, <<0:256>>),
                     genesis_hash = <<0:256>>,
                     chan = term_to_binary({log, <<"t">>}, [deterministic]),
                     relay_chan =
                         term_to_binary({ingress, <<"t">>}, [deterministic]),
                     signing_journal = memory},
                  Overrides),
    %% `validators` derives the default admission map, while an explicit
    %% `author_admissions` override must win.  Do not let maps:fold/3's
    %% unspecified traversal order decide that dependency.
    S1 = case maps:find(validators, Overrides) of
             {ok, Validators} -> test_state_set(validators, Validators, S0);
             error -> S0
         end,
    S2 =
        case maps:find(author_admissions, Overrides) of
            {ok, Admissions} ->
                test_state_set(author_admissions, Admissions, S1);
            error ->
                S1
        end,
    S3 = case maps:find(approved, Overrides) of
             {ok, Approved} -> S2#s{approved = Approved};
             error -> S2
        end,
    %% Production installs the initial DTX projection before the namespace is
    %% exposed. Keep the generic fixture faithful to that invariant; tests of
    %% the fail-closed pre-install state can still request `undefined`
    %% explicitly.
    S4 =
        case maps:is_key(dtx_projection, Overrides) of
            true -> S3;
            false ->
                S3#s{dtx_projection =
                         quod_atomic:initial_projection(
                           target_identity(S3), 0)}
        end,
    case maps:find(ingress, Overrides) of
        {ok, Items} -> test_state_set(ingress, Items, S4);
        error       -> S4
    end.
test_author_admission(Pubkey) ->
    crypto:hash(
      sha256,
      term_to_binary({quod_test_admission, Pubkey}, [deterministic])).
test_set_author_admissions(Admissions, S) ->
    S#s{author_admissions = Admissions}.
test_retire_changed_admissions(OldAdmissions, Admissions, S) ->
    retire_changed_admissions(OldAdmissions, Admissions, S).
test_install_projection(Projection, S) ->
    install_projection(Projection, S).
test_state_projection(S) ->
    state_projection(S).
test_enqueue_dtx_intent(From, EnginePid, IntentId, Material, GroupRef,
                        DeadlineMs, S) ->
    enqueue_dtx_intent(
      From, EnginePid, IntentId, Material, GroupRef, DeadlineMs, S).
test_progress_dtx_admission(S) ->
    {S1, ActionsRev} = progress_dtx_admission(S, []),
    {S1, lists:reverse(ActionsRev)}.
test_activate_dtx_intent(EnginePid, IntentId, S) ->
    activate_dtx_intent(EnginePid, IntentId, S).
test_cancel_dtx_intent(EnginePid, IntentId, S) ->
    cancel_dtx_intent(EnginePid, IntentId, S).
test_drop_dtx_admission_owner(
  S = #s{dtx_admission = #dtx_admission{engine = Engine, monitor = Monitor}}) ->
    drop_dtx_admission_monitor(Monitor, Engine, S).
test_dtx_admission_state(S) ->
    A = admission_state(S),
    {Active, Reserved} = quod_atomic_admission:counts(A#dtx_admission.waiting),
    #{engine => A#dtx_admission.engine, active => Active, reserved => Reserved}.
test_state_set(ns, V, S)         -> S#s{ns = V};
test_state_set(self, V, S)       -> S#s{self = V};
test_state_set(id, V, S)         -> S#s{id = V};
test_state_set(genesis_hash, V, S) -> S#s{genesis_hash = V};
test_state_set(consensus_domain, V, S) -> S#s{consensus_domain = V};
test_state_set(validators, V, S) ->
    S#s{validators = V,
        author_admissions =
            maps:from_list([{Pk, test_author_admission(Pk)} || Pk <- V])};
test_state_set(slot, V, S)       -> S#s{slot = V, approved = V};
test_state_set(approved, V, S)   -> S#s{approved = V};
test_state_set(eng, V, S)        -> S#s{eng = V};
test_state_set(sync, V, S)       -> S#s{sync = V};
test_state_set(last_applied, V, S) -> S#s{last_applied = V};
test_state_set(prolog_ready, V, S) -> S#s{prolog_ready = V};
test_state_set(author_seqs, V, S) -> S#s{author_seqs = V};
test_state_set(author_admissions, V, S) -> S#s{author_admissions = V};
test_state_set(dtx_projection, V, S) -> S#s{dtx_projection = V};
test_state_set(dtx_lanes, V, S) -> S#s{dtx_lanes = V};
test_state_set(history_head, V, S) -> S#s{history_head = V};
test_state_set(last_ts, V, S) -> S#s{last_ts = V};
test_state_set(phase_index, V, S) -> S#s{phase_index = V};
test_state_set(store, V, S)       -> S#s{store = V};
test_state_set(signing_journal, V, S) -> S#s{signing_journal = V};
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
test_state_set(validation_ttl_ms, V, S) -> S#s{validation_ttl_ms = V};
test_state_set(trace_owner_turns, V, S) -> S#s{trace_owner_turns = V};
test_state_set(committee_id, V, S) -> S#s{committee_id = V};
test_state_set(dtx_chan, V, S) -> S#s{dtx_chan = V};
test_state_set(retained_dtx, empty, S) ->
    S#s{retained_dtx = quod_dtx_owner:new()};
test_state_set(dtx_coordinators, V, S) -> S#s{dtx_coordinators = V};
test_state_set(local_proposal, {Slot, Hash}, S) ->   %% plant an in-flight sealed proposal
    S#s{local_proposals =
            (S#s.local_proposals)#{Slot => #local_proposal{hash = Hash, waiters = []}}};
test_state_set(local_proposal, {Slot, Hash, Contexts}, S) ->
    S#s{local_proposals = (S#s.local_proposals)#{
          Slot => #local_proposal{hash = Hash, trace_ctxs = Contexts}}};
%% Plant parked ingress items: [{Origin, From, Change, EnqueuedAtMonoMs}] — waiter
%% envelopes, byte accounting, and per-author counts are derived exactly as park_ingress
%% derives them, so drain/expiry tests exercise the real bookkeeping.
test_state_set(ingress, Items, S) ->
    lists:foldl(
      fun({local, From, Change, At}, Acc) ->
              Waiter = new_waiter(
                         From, otel_ctx:new(), Change, Acc, false),
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
                         {relay, Ref}, otel_ctx:new(), Change, Acc, true),
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
test_engine_pool_sizes(#s{eng = Eng}) -> eng_pool_sizes(Eng).
test_round(Slot, S) ->
    R = round_state(Slot, S),
    {R#round.supporting, round_committed(R), round_complained(R)}.
test_dtx_round(Slot, S) ->
    R = round_state(Slot, S),
    {R#round.validating, R#round.validation,
     R#round.candidate, R#round.dtx_parent,
     eng_retained_block(Slot, S#s.eng)}.
test_dtx_round_hints(Slot, S) ->
    (round_state(Slot, S))#round.validation_sidecar.
test_proposal_rejection(Slot, S) ->
    R = round_state(Slot, S),
    {R#round.invalid, R#round.invalid_reason}.
test_collected_payload(Payload, S) -> acceptable_collected_payload(Payload, S).
test_latch_dtx_validation(Slot, BH, ParentToken, EnginePid, Block, S) ->
    Monitor = erlang:monitor(process, EnginePid),
    R = round_state(Slot, S),
    {Monitor,
     put_round(
       Slot,
       R#round{validating = BH,
               validation = {dtx, ParentToken, EnginePid, Monitor,
                             quod_time:mono_ms() + S#s.validation_ttl_ms},
               candidate = {BH, Block}}, S)}.
test_on_dtx_verdict(Slot, BH, ParentToken, EnginePid, Floor, Verdict, S) ->
    on_dtx_verdict(
      Slot, BH, ParentToken, EnginePid, Floor, Verdict, S).
test_dtx_source_identity(Record, TargetIdentity) ->
    case dtx_source_reference(Record, TargetIdentity) of
        {ok, _Ref, Identity} -> {ok, Identity};
        none -> none
    end.

test_local_history_view(Identity, Requirement, S) ->
    local_history_view(Identity, Requirement, S).
test_local_history_view(Identity, Requirement, Deadline, S) ->
    local_history_view(Identity, Requirement, Deadline, S).
test_consensus_barrier(S) -> consensus_barrier(S).
test_dtx_consensus_barrier(S) -> consensus_barrier(S, ignore_retained_dtx).
test_dtx_slot_route(Slot, S) -> dtx_slot_route(Slot, S).
test_dtx_endpoint_ready(Request, S) ->
    dtx_endpoint_operation_ready(Request, S).
test_dtx_outcome_result(OutcomeRef, Result) ->
    dtx_outcome_result(OutcomeRef, Result).
test_validate_dtx_reference_evidence(Control, Evidence) ->
    validate_dtx_reference_evidence(Control, Evidence).
test_verify_content_requirements(Requirements, Seen) ->
    verify_content_requirements(
      Requirements, <<0:256>>, undefined, #{}, Seen,
      quod_time:mono_ms() + ?DTX_FOREIGN_VERIFY_MS).
test_content_reference_contacts(
  ReferencePlan, TargetIdentity, #s{dtx_workers = Workers}) ->
    content_reference_contacts(ReferencePlan, Workers, TargetIdentity).
test_verify_complete_applied(Control, Evidence, NetworkIdentity) ->
    case quod_atomic:control_kind(Control) of
        complete ->
            verify_complete_applied_certificates(
              Control, Evidence, NetworkIdentity);
        _OtherKind ->
            valid
    end.
test_relevant_validation_sidecar({submit, _, _} = Request, ValidationSidecar) ->
    relevant_validation_sidecar(Request, ValidationSidecar);
test_relevant_validation_sidecar(ControlOrRecord, ValidationSidecar) ->
    relevant_control_validation_sidecar(
      ControlOrRecord, ValidationSidecar).
test_merge_validation_sidecars(Existing, New) ->
    merge_validation_sidecars(Existing, New).
test_fit_consensus_validation_sidecar(Ns, ValidationSidecar) ->
    fit_consensus_validation_sidecar(
      Ns, fun(Hints) -> {test_validation_sidecar, Hints} end,
      ValidationSidecar).
test_dtx_endpoint_frame(TargetNs, Mode, Peer, Link, Frame, S) ->
    handle_dtx_endpoint_frame(TargetNs, Mode, Peer, Link, Frame, S).
test_dtx_outbound_message(PeerIdentity, Link, Channel, Payload, S) ->
    handle_dtx_outbound_message(PeerIdentity, Link, Channel, Payload, S).
test_seed_dtx_correlation(TargetNs, Peer, Request, From,
                          S) ->
    RequestId = quod_dtx_endpoint:request_id(Request),
    {ok, Frame} = quod_dtx_endpoint:encode_request(TargetNs, Request, []),
    Channel = quod_dtx_endpoint:channel(TargetNs),
    CallerMRef = erlang:monitor(process, element(1, From)),
    LinkMRef = erlang:monitor(process, self()),
    TimeoutTag = make_ref(),
    OpenRef = make_ref(),
    Timer = erlang:send_after(
              60000, self(),
              {dtx_endpoint_timeout, RequestId, TimeoutTag}),
    Correlation = #dtx_correlation{
                    target_ns = TargetNs, peer = Peer, request = Request,
                    frame = Frame, channel = Channel,
                    endpoint = {"127.0.0.1", 1}, open_ref = OpenRef,
                    link = self(), link_mref = LinkMRef,
                    from = From, caller_mref = CallerMRef, timer = Timer,
                    timeout_tag = TimeoutTag,
                    started_at = quod_time:mono_ms()},
    put_dtx_correlation(RequestId, Correlation, S).
test_seed_opening_dtx_correlation(TargetNs, Peer, Request, From, S) ->
    test_seed_opening_dtx_correlation(
      TargetNs, Peer, {"127.0.0.1", 1}, Request, From, S).
test_seed_opening_dtx_correlation(
  TargetNs, Peer, Endpoint, Request, From, S) ->
    RequestId = quod_dtx_endpoint:request_id(Request),
    {ok, Frame} = quod_dtx_endpoint:encode_request(TargetNs, Request, []),
    Channel = quod_dtx_endpoint:channel(TargetNs),
    OpenRef = make_ref(),
    CallerMRef = erlang:monitor(process, element(1, From)),
    TimeoutTag = make_ref(),
    Timer = erlang:send_after(
              60000, self(),
              {dtx_endpoint_timeout, RequestId, TimeoutTag}),
    Correlation = #dtx_correlation{
                    target_ns = TargetNs, peer = Peer, request = Request,
                    frame = Frame, channel = Channel, endpoint = Endpoint,
                    open_ref = OpenRef,
                    from = From, caller_mref = CallerMRef, timer = Timer,
                    timeout_tag = TimeoutTag,
                    started_at = quod_time:mono_ms()},
    {OpenRef, put_dtx_correlation(RequestId, Correlation, S)}.
test_dtx_correlation_link_up(OpenRef, Peer, Channel, Link, S) ->
    dtx_correlation_link_up(OpenRef, Peer, Channel, Link, S).
test_dtx_correlation_link_error(OpenRef, Peer, Channel, S) ->
    dtx_correlation_link_error(OpenRef, Peer, Channel, S).
test_timeout_dtx_correlation(RequestId, S) ->
    case maps:get(RequestId, S#s.dtx_correlations, undefined) of
        #dtx_correlation{timeout_tag = TimeoutTag} ->
            timeout_dtx_correlation(RequestId, TimeoutTag, S);
        undefined ->
            {S, []}
    end.
test_drop_dtx_correlation_caller(RequestId, S) ->
    case maps:get(RequestId, S#s.dtx_correlations, undefined) of
        #dtx_correlation{caller_mref = CallerMRef, from = {Caller, _}} ->
            drop_dtx_correlation_owner(CallerMRef, Caller, S);
        undefined ->
            false
    end.
test_dtx_endpoint_result(Request, Result, S) ->
    element(1, dtx_endpoint_result_response(Request, Result, S)).
test_dtx_endpoint_result_at(Request, Result, AdmissionS, ResponseS) ->
    Attestation = dtx_endpoint_attestation(Request, AdmissionS),
    element(1, dtx_endpoint_result_response(
                 Request, Result, Attestation, ResponseS)).
test_dtx_endpoint_result_with_hints(Request, Result, S) ->
    dtx_endpoint_result_response(Request, Result, S).
test_waiting_applied_key(Request, Result) ->
    waiting_applied_key(Request, Result).
test_seed_dtx_worker(Pid, Peer, Request, Destination,
                     S = #s{dtx_workers = Workers}) ->
    Monitor = erlang:monitor(process, Pid),
    WorkerPeer = endpoint_peer(Peer),
    {Monitor,
     track_owner_peaks(
       S#s{dtx_workers = Workers#{
             Pid => #dtx_server_worker{
                      pid = Pid, monitor = Monitor, peer = WorkerPeer,
                      contact = endpoint_contact(Peer),
                      request = Request, destination = Destination,
                      started_at = quod_time:mono_ms()}}})}.
test_finish_dtx_worker(Pid, Result, S) ->
    finish_dtx_server_worker(Pid, Result, S).
test_start_local_dtx_endpoint_request(Request, Hints, Timeout, From, S) ->
    start_local_dtx_endpoint_request(Request, Hints, Timeout, From, S).
test_wake_dtx_snapshot_workers(S0, S1) ->
    wake_dtx_snapshot_workers(S0, S1).
test_drop_dtx_endpoint_owner(Ref, Pid, S) ->
    drop_dtx_endpoint_owner(Ref, Pid, worker_down, S).
test_close_dtx_endpoint(
  #s{dtx_correlations = Correlations, dtx_workers = Workers}) ->
    close_dtx_endpoint(Correlations, Workers).
test_seed_dtx_submission(Control, Waiters, S) ->
    test_seed_dtx_submission_at(
      Control, Waiters, quod_time:mono_ms(), S).
test_seed_dtx_submission_at(
  Control, Waiters, InsertedAt, S = #s{retained_dtx = Registry}) ->
    Digest = quod_atomic:record_digest(Control),
    {ok, Envelope} = quod_atomic:encode_control(Control),
    Material = quod_atomic:control_material(Control),
    %% Direct Vote fixtures enter after parent selection. Other record kinds
    %% have no policy-selection token, just as in the production registry.
    Engine = case quod_reg:where({quod_prolog, S#s.ns}) of undefined -> none; Pid -> Pid end,
    Selection = case quod_atomic:control_kind(Control) of
        vote -> {quod_atomic_admission:selection_key(
                  {Engine, S#s.history_head}, vote_timestamp(S), Material), #{parent => true}};
        _ -> none
    end,
    Placement = test_retained_placement(retained_disposition(Material, S)),
    Submission =
        #dtx_submission{
          control = Control,
          envelope = Envelope, group_id = quod_atomic:group_id(Control),
          digest = Digest, inserted_at = InsertedAt,
          observation_started_at = InsertedAt, selection = Selection,
          placement = Placement, bytes = byte_size(Envelope),
          waiters = test_dtx_waiter_set(Waiters)},
    Seeded = S#s{retained_dtx = quod_dtx_owner:put_new(Submission, Registry)},
    case is_pid(Engine) andalso local_owned_vote(Submission, S) of
        true -> set_dtx_admission_engine(Engine, Seeded);
        false -> Seeded
    end.
test_retained_placement(ready) -> ready;
test_retained_placement({blocked, _}) -> blocked;
test_retained_placement(stale) -> error(stale_test_dtx_submission).
test_dtx_waiter_set(Waiters) ->
    maps:from_list([{Pid, true} || {dtx_endpoint, Pid} <- Waiters]).
test_eligible_dtx_wave(S) ->
    case eligible_dtx_wave(local, S) of
        none -> [];
        {Wave, _Block} ->
            [{Digest, quod_atomic:control_body(Control)}
             || {Digest, #dtx_submission{control = Control}} <- Wave]
    end.
test_drive_retained_dtx(S) -> drive_retained_dtx(S).
test_bind_claimed_effect(Ns, TargetRef, ClaimRef, Application, Deadline) ->
    bind_claimed_effect(Ns, TargetRef, ClaimRef, Application, Deadline).
test_blocked_dtx_owner(Parent, S) ->
    H = Parent#block.slot, Eng = S#s.eng,
    Owners = maps:map(fun(G, _OwnRow) ->
        #dtx_coordinator_owner{group_id = G, pid = self(), monitor = make_ref()}
    end, dtx_coordinator_desired(S)),
    S#s{slot = H - 1, approved = H, eng = Eng#eng{tree = #{H => Parent}},
        dtx_coordinators = Owners}.
test_dtx_drive_scheduled(#s{dtx_drive_scheduled = Scheduled}) -> Scheduled.
test_propose_dtx_wave(Slot, Envelopes, Hints, S) ->
    Parent = S#s.approved,
    {ok, Payload} = decode_dtx_wave(Envelopes),
    {ok, Block} = quod_ledger:new_block(Slot, Parent, Payload,
                      max(quod_time:now_ms(), parent_timestamp(Parent, S))),
    propose_dtx_wave(Block, Hints, S).
test_resolve_committed_dtx(Entry, Payload, S) ->
    resolve_committed_dtx(Entry, Payload, S).
test_restore_pending_dtx(S, Journal) -> restore_pending_dtx(S, Journal).
test_retain_dtx_record(Record, Waiter, S) ->
    case quod_atomic:admission_material(Record) of
        {ok, Material} -> retain_dtx_submission(Material, Waiter, [], sign, S);
        error -> {error, invalid_dtx_submission}
    end.
test_dtx_retain_admissible(Record, S) ->
    {ok, Material} = quod_atomic:admission_material(Record),
    case retention_disposition(Material, S) of
        {included, _} -> false;
        ready -> true;
        {blocked, _} -> true;
        {refused, _} -> false;
        stale -> false
    end.
test_dtx_submission_waiters(#s{retained_dtx = Registry}) ->
    quod_dtx_owner:waiter_count(Registry).
test_retained_dtx_state(#s{retained_dtx = Registry}) ->
    (quod_dtx_owner:stats(Registry))#{
      rows => maps:map(
                fun(_Digest,
                    #dtx_submission{inserted_at = InsertedAt,
                                    observation_started_at = ObservedAt,
                                    bytes = Bytes, envelope = Envelope,
                                    validation_sidecar = ValidationSidecar,
                                    placement = Placement,
                                    relay_placement = RelayPlacement}) ->
                        #{inserted_at => InsertedAt,
                          observation_started_at => ObservedAt,
                          bytes => Bytes, envelope => Envelope,
                          validation_sidecar => ValidationSidecar,
                          placement => Placement,
                          relay_placement => RelayPlacement}
                end, quod_dtx_owner:rows(Registry))}.
test_refresh_retained_readiness(S) ->
    finish_pending_votes_reconciliation(refresh_retained_readiness(S)).
test_refresh_retained_dtx_signatures(S) ->
    finish_pending_votes_reconciliation(refresh_retained_dtx_signatures(S)).
test_reconcile_signing_state(S) -> reconcile_signing_state(S).
test_finish_pending_votes_reconciliation(Transition, S) ->
    finish_pending_votes_reconciliation(Transition, S).
test_reconcile_dtx_coordinator(S) -> reconcile_dtx_coordinator(S).
test_reconcile_dtx_coordinators(Desired, S) ->
    reconcile_dtx_coordinators(Desired, S).
test_drop_dtx_coordinator(Ref, Pid, Reason, S) ->
    drop_dtx_coordinator_owner(Ref, Pid, Reason, S).
test_start_dtx_coordinator_worker(OwnRow, TraceCtx, S) ->
    start_dtx_coordinator_worker(OwnRow, TraceCtx, S).
test_dtx_coordinator_state(#s{dtx_coordinators = Coordinators}) ->
    maps:map(
      fun(_GroupId,
          #dtx_coordinator_owner{group_id = GroupId, pid = Pid,
                                 monitor = Monitor, trace_ctx = TraceCtx,
                                 coordinate_span = CoordinateSpan}) ->
              #{group_id => GroupId, pid => Pid,
                monitor => Monitor, trace_ctx => TraceCtx,
                coordinate_span => CoordinateSpan}
      end, Coordinators).
test_stop_dtx_coordinator(S = #s{dtx_coordinators = Coordinators}) ->
    lists:foldl(fun stop_dtx_coordinator/2, S, maps:keys(Coordinators)).
test_seed_running_dtx_coordinator(GroupId, Pid, S)
  when is_binary(GroupId), is_pid(Pid) ->
    put_dtx_coordinator(
      #dtx_coordinator_owner{group_id = GroupId,
                             pid = Pid, monitor = make_ref()}, S).
test_activate_dtx_coordinator(Pid, S) when is_pid(Pid) ->
    activate_dtx_coordinator(Pid, S).
test_notify_dtx_coordinator_progress(S0, S1) ->
    notify_dtx_coordinator_progress(S0, S1).
test_retire_invalid_dtx(Payload, Reasons, S) ->
    retire_invalid_dtx_submission(Payload, Reasons, S).
test_dtx_endpoint_counts(
  #s{dtx_correlations = Correlations, dtx_out_channels = Channels,
     dtx_workers = Workers, retained_dtx = Registry}) ->
    #{correlations => map_size(Correlations),
      channels => map_size(Channels), workers => map_size(Workers),
      submissions => quod_dtx_owner:count(Registry)}.
test_dtx_correlation_timers(#s{dtx_correlations = Correlations}) ->
    [Timer || #dtx_correlation{timer = Timer} <- maps:values(Correlations)].
test_owner_stats(S) ->
    {Current, CurrentBytes} = simplex_owner_current(S),
    #{owner_current => Current,
      owner_peak => simplex_owner_peaks(S, Current),
      owner_bytes_current => CurrentBytes,
      owner_bytes_peak => simplex_owner_byte_peaks(S, CurrentBytes)}.
test_operation_target_result(Result, TargetRef) ->
    OperationRef = {operation, <<"quod:test">>, <<0:256>>},
    Owner = #operation_recovery_owner{
               operation_ref = OperationRef,
               claim_state = unresolved,
               claim_slot = 1,
               target_refs = [TargetRef],
               request_digest = <<0:256>>,
               status = running,
               pid = self()},
    S0 = #s{operation_recoveries = #{OperationRef => Owner}},
    Tag = make_ref(),
    {wait, S1} = await_operation_recovery(
                   {self(), Tag}, make_ref(), OperationRef, quod_time:mono_ms() + 1000, S0),
    {true, SFinished} = finish_operation_target_result(
                          self(), OperationRef, Result, TargetRef, S1),
    Reply = receive
                {Tag, Value} -> Value
            after 1000 -> timeout
            end,
    Stored = maps:get(OperationRef, SFinished#s.operation_recoveries),
    Duplicate = finish_operation_target_result(
                  self(), OperationRef, Result, TargetRef, SFinished),
    #{reply => Reply,
      stored => operation_client_result(Stored),
      waiters => map_size(Stored#operation_recovery_owner.waiters),
      duplicate => Duplicate}.
test_operation_wait_before_projection(Slot, Claim = #transaction{}) ->
    {ok, #{operation_ref := OperationRef}} =
        quod_transaction:request_claim(Claim),
    Tag = make_ref(),
    {OriginNs, _} = Claim#transaction.origin,
    S0 = #s{ns = OriginNs, operation_recoveries = #{}},
    {wait, S1} = await_operation_recovery(
                   {self(), Tag}, make_ref(), OperationRef, quod_time:mono_ms() + 1000, S0),
    Waiting = maps:get(OperationRef, S1#s.operation_recoveries),
    [Monitor] = maps:keys(Waiting#operation_recovery_owner.waiters),
    {true, Abandoned} = drop_operation_waiter(Monitor, self(), S1),
    S2 = apply_operation_projection(Slot, Claim, S1),
    Projected = maps:get(OperationRef, S2#s.operation_recoveries),
    #{waiting_status => Waiting#operation_recovery_owner.status,
      waiting_count => map_size(Waiting#operation_recovery_owner.waiters),
      abandoned_present =>
          maps:is_key(OperationRef, Abandoned#s.operation_recoveries),
      projected_status => Projected#operation_recovery_owner.status,
      projected_slot => Projected#operation_recovery_owner.claim_slot,
      projected_waiters =>
          map_size(Projected#operation_recovery_owner.waiters)}.
test_operation_recoveries(#s{operation_recoveries = Recoveries}) ->
    maps:map(
      fun(_Ref, Owner = #operation_recovery_owner{
                  claim_state = State, status = Status, claim_slot = Slot,
                  target_refs = Target, request_digest = Digest, pid = Pid,
                  monitor = Monitor, target_results = Results, waiters = Waiters}) ->
          #{claim_state => State, status => Status, slot => Slot,
            target_ref => Target, digest => Digest, pid => Pid,
            monitor => Monitor, result => operation_client_result(Owner),
            results => Results, result_vector => operation_result_vector(Owner),
            waiters => Waiters, trace_ctx => Owner#operation_recovery_owner.trace_ctx,
            attempt_span => Owner#operation_recovery_owner.attempt_span}
      end, Recoveries).

test_start_operation_recovery(Ref, TraceCtx, S) ->
    Owner = #operation_recovery_owner{operation_ref = Ref,
              trace_ctx = TraceCtx, claim_state = unresolved},
    put_operation_owner(start_operation_recovery(Owner, S), S).
operation_result_vector(#operation_recovery_owner{target_refs = none}) -> pending;
operation_result_vector(#operation_recovery_owner{
                          target_refs = Refs, target_results = Results}) ->
    [{quod_operation_vector:target(Ref),
      maps:get(quod_operation_vector:target(Ref), Results, pending)} || Ref <- Refs].

test_seed_operation_worker(Ref, Pid, S = #s{operation_recoveries = Recoveries}) ->
    Owner = maps:get(Ref, Recoveries),
    S#s{operation_recoveries = Recoveries#{
          Ref => Owner#operation_recovery_owner{
                   status = running, pid = Pid,
                   monitor = erlang:monitor(process, Pid)}}}.
test_endpoint_terminal_result(Result) -> endpoint_terminal_result(Result).
test_dtx_worker_terminal_result(Result, Response) ->
    dtx_worker_terminal_result(Result, Response).
test_dtx_retirement_result(Reason) -> dtx_retirement_result(Reason).
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
test_reconcile_relays(S) -> reconcile_relays(S).
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
test_signing_journal(#s{signing_journal = Journal}) -> Journal.
%% Ingress-queue test surface: raw-From entry wrappers (the waiter/trace envelope is
%% built here exactly as the running/3 handlers build it), the queue view, and
%% clock-controlled drain/expiry.
test_append(From, Change, S) ->
    handle_append(new_waiter(From, otel_ctx:new(), Change, S, false), Change, S).
test_relayed_append(Peer, Change, S) ->
    TargetSlot = S#s.approved + 1,
    test_relayed_append(Peer, TargetSlot, Change, S).
test_relayed_append(Peer, TargetSlot, Change, S) ->
    Ref = test_relay_ref(Peer, Change, TargetSlot, S),
    handle_relayed_append(
      new_waiter({relay, Ref}, otel_ctx:new(), Change, S, true),
      Ref, Change, S).
test_relay_ref(Peer, Change, TargetSlot,
               #s{ns = Ns, self = Self, committee_id = CommitteeId0} = S) ->
    {ok, Submission} = transaction_submission(S, Change),
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
                operation_claims = OperationClaims,
                sequences = Sequences}}) ->
    #{count => Count, bytes => Bytes,
      tx_ids => TxIds, operation_claims => OperationClaims,
      sequences => Sequences}.
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
    [{relay_wire_id(Relay), Target, TargetSlot, Deadline, Accepted}
     || {_Key, #relay_pending{target = Target, target_slot = TargetSlot,
                             deadline = Deadline,
                             accepted = Accepted} = Relay}
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
                           deadline = 0},
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
test_custody_authors(#s{custody = Custody}) ->
    lists:usort(
      [Author
       || #custody{change = #transaction{author = Author}} <-
              maps:values(Custody)]).
test_register_dormant_transaction(Admission, Change, Owner, S) ->
    register_dormant_transaction(Admission, Change, Owner, S).
test_start_dormant_transaction_cancellation(TxId, Caller, S, Start) ->
    start_dormant_transaction_cancellation(TxId, Caller, S, Start).
test_activate_dormant_transaction(TxId, From, S) ->
    activate_dormant_transaction(TxId, element(1, From), From, S).
test_cancel_dormant_transaction(TxId, Caller, S) ->
    cancel_dormant_transaction(TxId, Caller, S).
test_restart_dormant_custody_owner(Ref, Pid, S, Start) ->
    restart_dormant_custody_owner(Ref, Pid, S, Start).
test_custody_owner(TxId, #s{custody = Custody}) ->
    case transaction_custody_by_id(TxId, Custody) of
        {ok, _SubmissionId,
         #custody{placement = Placement,
                  dormant_owner = DormantOwner}} ->
            Base = #{placement => test_custody_placement(Placement),
                     dormant_owner => DormantOwner},
            case Placement of
                {cancelling, Pid, _Monitor} ->
                    Base#{cancellation_owner => Pid};
                _ -> Base
            end;
        not_found -> not_found
    end.
test_place_transaction_custody(TxId, Placement,
                               S = #s{custody = Custody}) ->
    {ok, SubmissionId,
     #custody{placement = ready, change = Change}} =
        transaction_custody_by_id(TxId, Custody),
    ReadyKey = {Change#transaction.author_seq, SubmissionId},
    place_custody(
      SubmissionId, Placement, drop_custody_ready(ReadyKey, S)).
test_mark_custody_lane_ready(S) ->
    mark_custody_lane_ready(S).
test_settle_recovery_custody(NewHead, Included, S) ->
    settle_recovery_custody(NewHead, Included, S).
test_resolve_committed_submissions(Payload, Slot, S) ->
    resolve_committed_submissions(Payload, Slot, S).
test_custody_placement({local, Slot, _CommitteeId}) ->
    {local, Slot};
test_custody_placement({cancelling, _Pid, _Monitor}) ->
    cancelling;
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
test_trace_block(Slot, Hash, Name, S, Fun) ->
    trace_block_work(Slot, Hash, Name, #{}, S, Fun).
test_trace_block_event(Slot, Hash, Name, Attributes, S) ->
    trace_block_event(Slot, Hash, Name, Attributes, S).
test_start_content_validation(Transactions, Timestamp, Slot, Hash, S) ->
    start_content_validation(Transactions, Timestamp, Slot, Hash, S).
test_committee_id(#s{committee_id = CommitteeId}) -> CommitteeId.
test_author_admissions(#s{author_admissions = Admissions}) -> Admissions.
test_log_projection(Ns, Entries, Seed) ->
    log_projection(Ns, Entries, Seed).
test_apply_catchup_window(Source, Entries, S) ->
    Projection = log_projection(S#s.ns, Entries, state_projection(S)),
    apply_catchup_window(Source, Entries, Projection, quod_dtx_phase_index:new_delta(), S).
test_apply_catchup_window(Source, Entries, Projection, S) ->
    apply_catchup_window(Source, Entries, Projection, quod_dtx_phase_index:new_delta(), S).
-endif.

callback_mode() -> [state_functions].

%%%===================================================================
%%% API
%%%===================================================================

start_link(Ns, Config) ->
    gen_statem:start_link(quod_reg:via({quod_simplex, Ns}), ?MODULE, {Ns, Config}, []).

-doc "Durably accept one exact local effect transaction into signed custody.".
-spec handoff_effect(binary(), <<_:256>>, #transaction{}) ->
          ok | {error, busy | bad_change | not_in_charge |
                       unavailable | outcome_unknown}.
handoff_effect(Ns, <<_:256>> = Admission, #transaction{} = Change)
  when is_binary(Ns) ->
    try gen_statem:call(
          quod_reg:via({quod_simplex, Ns}),
          {handoff_effect, Admission, Change}, 8000)
    catch
        %% Process absence says nothing about durable authority. The node-wide
        %% effect journal starts before dynamically hosted ontologies are
        %% restored, so only a live Simplex may return `not_in_charge`.
        exit:{noproc, _} -> {error, unavailable};
        exit:{timeout, _} -> {error, outcome_unknown};
        exit:_ -> {error, outcome_unknown}
    end;
handoff_effect(_Ns, _Admission, _Change) ->
    {error, bad_change}.

-doc "Persist one exact signed transaction in dormant consensus custody.".
-spec register_transaction_custody(binary(), <<_:256>>, #transaction{}) ->
          {ok, {submit, binary(), binary(), binary()}} |
          {error, busy | bad_change | not_in_charge | unavailable}.
register_transaction_custody(Ns, <<_:256>> = Admission,
                             #transaction{} = Change)
  when is_binary(Ns) ->
    try gen_statem:call(
          quod_reg:via({quod_simplex, Ns}),
          {register_transaction_custody, Admission, Change}, 8000)
    catch
        exit:{noproc, _} -> {error, unavailable};
        exit:_ -> {error, unavailable}
    end;
register_transaction_custody(_Ns, _Admission, _Change) ->
    {error, bad_change}.

-doc "Let the exact dormant-custody owner start target cancellation.".
-spec start_transaction_custody_cancellation(binary(), <<_:256>>) ->
          ok | {error, not_found | already_active | not_in_charge | unavailable}.
start_transaction_custody_cancellation(Ns, <<_:256>> = TxId)
  when is_binary(Ns) ->
    try gen_statem:call(
          quod_reg:via({quod_simplex, Ns}),
          {start_transaction_custody_cancellation, TxId}, 8000)
    catch exit:_ -> {error, unavailable}
    end;
start_transaction_custody_cancellation(_Ns, _TxId) ->
    {error, not_found}.

-doc "Let the exact dormant-custody owner activate after every prerequisite is durable.".
-spec activate_transaction_custody(binary(), <<_:256>>) ->
          {ok, pos_integer()} |
          {error, not_found | already_active | not_in_charge |
                  unavailable | outcome_unknown}.
activate_transaction_custody(Ns, <<_:256>> = TxId) when is_binary(Ns) ->
    try gen_statem:call(
          quod_reg:via({quod_simplex, Ns}),
          {activate_transaction_custody, TxId}, 8000)
    catch
        exit:{timeout, _} -> {error, outcome_unknown};
        exit:_ -> {error, unavailable}
    end;
activate_transaction_custody(_Ns, _TxId) ->
    {error, not_found}.

-doc "Let the exact cancellation owner retire custody after its correlated proof.".
-spec cancel_transaction_custody(binary(), <<_:256>>) ->
          ok | {error, not_found | already_active | not_in_charge | unavailable}.
cancel_transaction_custody(Ns, <<_:256>> = TxId) when is_binary(Ns) ->
    try gen_statem:call(
          quod_reg:via({quod_simplex, Ns}),
          {cancel_transaction_custody, TxId}, 8000)
    catch exit:_ -> {error, unavailable}
    end;
cancel_transaction_custody(_Ns, _TxId) ->
    {error, not_found}.

-ifdef(TEST).
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
`{error, {outcome_unknown, OutcomeRef}}`: the transaction may still finalize,
so callers must inspect that target-anchored reference rather than submit the
same non-idempotent operation again.
""".
-spec append(binary(), #transaction{}) ->
        {ok, slot()} | {error, busy} | {error, skipped} | {error, bad_change}
      | {error, stale_seq}
      | {error, {outcome_unknown,
                 {transaction, binary(), binary(), binary()}}}
      | {error, not_in_charge, node_id() | none | unavailable}.
append(Ns, Change) ->
    OutcomeRef = append_outcome_ref(Ns, Change),
    try gen_statem:call(quod_reg:via({quod_simplex, Ns}),
                        {append, Change, quod_trace:context()}, 8000)
    catch
        exit:{noproc, _} -> {error, not_in_charge, unavailable};
        exit:{timeout, _} -> unknown_append_outcome(OutcomeRef);
        exit:_ -> unknown_append_outcome(OutcomeRef)
    end.

append_outcome_ref(Ns, #transaction{tx_id = TxId}) ->
    case genesis_hash(Ns) of
        <<_:256>> = Anchor ->
            {transaction, Ns, Anchor, TxId};
        _ ->
            unavailable
    end.

unknown_append_outcome(unavailable) ->
    {error, not_in_charge, unavailable};
unknown_append_outcome(OutcomeRef) ->
    {error, {outcome_unknown, OutcomeRef}}.
-endif.

-doc "Ask the consensus process to (re)drive committed blocks into a freshly-started `quod_prolog`.".
-spec rebuild(binary()) -> ok.
rebuild(Ns) -> gen_statem:cast(quod_reg:via({quod_simplex, Ns}), rebuild).

-doc "Acknowledge Prolog readiness with its exact unresolved-operation projection.".
-spec prolog_ready(binary(), pid(), non_neg_integer(), [map()]) -> ok.
prolog_ready(Ns, PrologPid, Height, Unresolved)
  when is_binary(Ns), is_pid(PrologPid),
       is_integer(Height), Height >= 0, is_list(Unresolved) ->
    case quod_reg:where({quod_simplex, Ns}) of
        undefined -> ok;
        SimplexPid ->
            gen_statem:cast(
              SimplexPid,
              {prolog_ready, PrologPid, Height, Unresolved})
    end.

-doc "Project one committed target-vector claim/completion into recovery custody.".
-spec operation_projection(binary(), pos_integer(), #transaction{},
                           quod_trace:context()) -> ok.
operation_projection(
  Ns, Slot, #transaction{} = Change, TraceCtx)
  when is_binary(Ns), is_integer(Slot), Slot > 0 ->
    %% Projection remains asynchronous for both live apply and replay.  A
    %% synchronous callback into Simplex would deadlock while Simplex is
    %% feeding replay entries to Prolog. On a locally executed live submit,
    %% Prolog sends this cast before releasing the parked submit_role caller,
    %% so mailbox order installs the owner first. A relayed leader reply may
    %% overtake this replica's apply; await_operation_recovery/5 parks that
    %% waiter in the same owner until this cast arrives.
    gen_statem:cast(
      quod_reg:via({quod_simplex, Ns}),
      {operation_projection, Slot, Change, TraceCtx}).

-doc "Wait for the durable recovery owner to certify one complete target-result vector.".
-spec await_operation_result(binary(), term(), pos_integer()) ->
          {operation_results, list()} |
          {error, {outcome_unknown, term()}}.
await_operation_result(Ns, OperationRef, TimeoutMs)
  when is_binary(Ns), is_integer(TimeoutMs), TimeoutMs > 0 ->
    Deadline = quod_time:mono_ms() + TimeoutMs,
    WaitRef = make_ref(),
    %% Bind cleanup to this exact owner incarnation, caller and request. A
    %% timeout expires the call alias, not the caller PID; its monitor alone
    %% therefore cannot release result-only work for a long-lived caller.
    Server = quod_reg:where({quod_simplex, Ns}),
    TraceCtx = quod_trace:context(),
    trace_operation_event(
      TraceCtx, <<"operation.result_wait_sent">>, OperationRef, Ns, #{}),
    try gen_statem:call(
          Server, {await_operation_result, WaitRef, OperationRef,
                   Deadline, TraceCtx}, TimeoutMs) of
        Reply ->
            case quod_time:mono_ms() < Deadline of
                true -> Reply;
                false -> {error, {outcome_unknown, OperationRef}}
            end
    catch
        exit:_ -> {error, {outcome_unknown, OperationRef}}
    after
        case is_pid(Server) of
            true -> gen_statem:cast(
                      Server, {cancel_operation_wait, self(), WaitRef, OperationRef});
            false -> ok
        end
    end;
await_operation_result(_Ns, OperationRef, _TimeoutMs) ->
    {error, {outcome_unknown, OperationRef}}.

-doc "Open a pending apply fence after the exact Resolve is durably visible.".
-spec resolve_applied(binary(), <<_:256>>, pos_integer(), non_neg_integer()) -> ok.
resolve_applied(Ns, GroupId, Slot, Generation)
  when is_binary(Ns), is_binary(GroupId), byte_size(GroupId) =:= 32,
       is_integer(Slot), Slot > 0,
       is_integer(Generation), Generation >= 0 ->
    case quod_reg:where({quod_simplex, Ns}) of
        undefined -> ok;
        SimplexPid ->
            gen_statem:cast(
              SimplexPid,
              {resolve_applied, GroupId, Slot, Generation})
    end.

-doc "Return the anchored participant binding; Vote admission waits for readiness in its existing FIFO.".
-spec dtx_binding(binary()) ->
          {ok, {binary(), <<_:256>>, <<_:256>>, <<_:256>>}} |
          {error, term()}.
dtx_binding(Ns) when is_binary(Ns) ->
    call(Ns, get_dtx_binding, {error, {ontology_unavailable, Ns}}).

-doc "Return the participant binding only while ready, for claims requiring immediate custody.".
-spec dtx_ready_binding(binary()) ->
          {ok, {binary(), <<_:256>>, <<_:256>>, <<_:256>>}} | {error, term()}.
dtx_ready_binding(Ns) when is_binary(Ns) ->
    call(Ns, get_dtx_ready_binding, {error, {ontology_unavailable, Ns}}).

-doc "Reserve the source's own authenticated vote before private effects bind; no foreign bundle enters the owner.".
-spec register_dtx_vote(binary(), pid(), reference(),
                         quod_atomic:admission_material(), term(), integer()) ->
          {ok, reference()} | {error, term()}.
register_dtx_vote(Ns, EnginePid, IntentId, Material, GroupRef, DeadlineMs)
  when is_binary(Ns), is_pid(EnginePid), is_reference(IntentId),
       is_integer(DeadlineMs) ->
    case quod_reg:where({quod_simplex, Ns}) of
        undefined -> {error, {ontology_unavailable, Ns}};
        SimplexPid ->
            {ok, gen_statem:send_request(
                   SimplexPid,
                   {register_dtx_vote, EnginePid, IntentId,
                    Material, GroupRef, DeadlineMs, quod_trace:context()})}
    end;
register_dtx_vote(_Ns, _EnginePid, _IntentId, _Material, _GroupRef,
                   _DeadlineMs) ->
    {error, invalid_dtx_intent}.

-doc "Activate an engine reservation; the existing FIFO selects the vote and transfers it to journal custody.".
-spec activate_dtx_vote(binary(), pid(), reference()) -> ok.
activate_dtx_vote(Ns, EnginePid, IntentId) ->
    gen_statem:cast(
      quod_reg:via({quod_simplex, Ns}),
      {activate_dtx_vote, EnginePid, IntentId}).

-doc "Cancel an inactive engine-owned vote reservation.".
-spec cancel_dtx_vote(binary(), pid(), reference()) -> ok.
cancel_dtx_vote(Ns, EnginePid, IntentId) ->
    gen_statem:cast(
      quod_reg:via({quod_simplex, Ns}),
      {cancel_dtx_vote, EnginePid, IntentId}).

-doc "Send one bounded DTX recovery request to an exact pinned validator.".
-spec dtx_endpoint_request(
        binary(), binary(), <<_:256>>, {inet:hostname(), inet:port_number()},
        quod_dtx_endpoint:request(), [quod_dtx_endpoint:validation_item()],
        pos_integer()) ->
          {ok, quod_dtx_endpoint:response(),
           [quod_dtx_endpoint:validation_item()]} |
          {error, busy | not_ready | invalid_request | timeout |
                  connection_lost}.
dtx_endpoint_request(
  OwnerNs, TargetNs, <<_:256>> = PeerKey, Endpoint, Request, ValidationSidecar,
  TimeoutMs)
  when is_binary(OwnerNs), byte_size(OwnerNs) > 0,
       is_binary(TargetNs), byte_size(TargetNs) > 0,
       is_integer(TimeoutMs), TimeoutMs > 0,
       TimeoutMs =< ?QUOD_DTX_ENDPOINT_WORKER_TIMEOUT_MS ->
    try gen_statem:call(
          quod_reg:via({quod_simplex, OwnerNs}),
          {dtx_endpoint_request, TargetNs, PeerKey, Endpoint,
           Request, ValidationSidecar, TimeoutMs, quod_trace:context()},
          infinity)
    catch
        exit:_ -> {error, not_ready}
    end;
dtx_endpoint_request(
  _OwnerNs, _TargetNs, _PeerKey, _Endpoint, _Request, _ValidationSidecar,
  _TimeoutMs) ->
    {error, invalid_request}.

-doc "Execute the same DTX endpoint operation on a co-hosted namespace.".
-spec dtx_endpoint_local(binary(), quod_dtx_endpoint:request(),
                         [quod_dtx_endpoint:validation_item()], pos_integer()) ->
          {ok, quod_dtx_endpoint:response(),
           [quod_dtx_endpoint:validation_item()]} |
          {error, busy | not_ready | invalid_request}.
dtx_endpoint_local(Ns, Request, ValidationSidecar, TimeoutMs)
  when is_binary(Ns), byte_size(Ns) > 0,
       is_integer(TimeoutMs), TimeoutMs > 0,
       TimeoutMs =< ?QUOD_DTX_ENDPOINT_WORKER_TIMEOUT_MS ->
    try gen_statem:call(
          quod_reg:via({quod_simplex, Ns}),
          {dtx_endpoint_local, Request, ValidationSidecar, TimeoutMs,
           quod_trace:context()}, infinity)
    catch
        exit:_ -> {error, not_ready}
    end;
dtx_endpoint_local(_Ns, _Request, _ValidationSidecar, _TimeoutMs) ->
    {error, invalid_request}.

-doc "Resolve one foreign anchored outcome through current pinned validators.".
-spec dtx_outcome_lookup(term(), pos_integer()) ->
          {ok, map()} | {error, term()}.
dtx_outcome_lookup(OutcomeRef, TimeoutMs)
  when is_integer(TimeoutMs), TimeoutMs > 0,
       TimeoutMs =< ?QUOD_DTX_ENDPOINT_WORKER_TIMEOUT_MS ->
    Deadline = quod_time:mono_ms() + TimeoutMs,
    case {quod_outcome:ref_identity(OutcomeRef),
          lists:sort(namespaces())} of
        {{ok, Identity}, [OwnerNs | _]} ->
            case quod_foreign_log:route_hints(Identity, []) of
                {ok, SourceRoutes} ->
                    case quod_dtx_current_view:lookup_outcome(
                           OwnerNs, {remote, SourceRoutes}, OutcomeRef,
                           Deadline) of
                        Result -> dtx_outcome_result(OutcomeRef, Result)
                    end;
                {error, _} ->
                    {error, {outcome_unknown, OutcomeRef}}
            end;
        _ ->
            {error, {outcome_unknown, OutcomeRef}}
    end;
dtx_outcome_lookup(OutcomeRef, _TimeoutMs) ->
    {error, {outcome_unknown, OutcomeRef}}.

-type history_view() ::
        #{owner := pid(), identity := {binary(), <<_:256>>},
          slot := non_neg_integer(), applied := non_neg_integer(),
          snapshot := quod_ledger_store:session(),
          projection := history_projection()}.

-doc """
Borrow the registered owner's immutable committed ledger and matching verified
projection in one turn. An exact identity pins the incarnation; a namespace
selects this local owner's incarnation. No path or file handle is returned.

`committed` serves the stored prefix even while Prolog is replaying, including
the empty prefix of a pinned joiner; this does not certify a genesis. `any`
requires the ordinary read-ready endpoint; `validator` additionally requires
local committee membership. Committed `slot` and Prolog `applied` are distinct:
`applied` is the owner's apply-sent frontier, not a new MVCC acknowledgement.
Borrowing bytes must not report a pending apply as completed. Later appends do
not invalidate this bounded view or any proof's separately pinned MVCC base.
`Deadline` is the caller's original absolute `quod_time:mono_ms()` deadline;
both queued admission and return publication must still fit that budget.
""".
-spec history_view(binary() | {binary(), <<_:256>>} |
                   {pid(), {binary(), <<_:256>>}},
                   committed | any | validator, integer()) ->
          {ok, history_view()} |
          {error, timeout | not_ready | invalid_identity | read_certificate_unavailable}.
history_view({Owner, {Ns, <<_:256>>} = Identity}, Requirement, Deadline)
  when is_pid(Owner), is_binary(Ns), byte_size(Ns) > 0, is_integer(Deadline),
       (Requirement =:= committed orelse Requirement =:= any orelse
        Requirement =:= validator) ->
    call_history_view(Owner, Ns, Identity, Requirement, Deadline);
history_view({Ns, <<_:256>>} = Identity, Requirement, Deadline)
  when is_binary(Ns), byte_size(Ns) > 0, is_integer(Deadline),
       (Requirement =:= committed orelse Requirement =:= any orelse
        Requirement =:= validator) ->
    registered_history_view(Ns, Identity, Requirement, Deadline);
history_view(Ns, Requirement, Deadline)
  when is_binary(Ns), byte_size(Ns) > 0, is_integer(Deadline),
       (Requirement =:= committed orelse Requirement =:= any orelse
        Requirement =:= validator) ->
    registered_history_view(Ns, Ns, Requirement, Deadline);
history_view(_Identity, _Requirement, _Deadline) ->
    {error, invalid_identity}.

registered_history_view(Ns, Identity, Requirement, Deadline) ->
    %% Resolve once. A replacement registration must never receive this call.
    try call_history_view(
          quod_reg:where({quod_simplex, Ns}), Ns, Identity, Requirement, Deadline)
    catch _:_ -> {error, not_ready}
    end.

-doc """
Capture one sufficient hosted view, waiting only for actual committed progress.

The request's exact owner and original deadline stay pinned while waiting.
An insufficient prefix returns only its height, not a snapshot: the one view
is captured only when the requested slot exists. Subscribe before checking so
a commit cannot cross the check/wait boundary unnoticed. Progress is a wake
hint, never evidence; the owner still supplies the coherent capture.

This blocking reader belongs in the existing proof/evidence workers, never in
the consensus owner. It opens no store, starts no process and uses no polling
or retry timer. An absent but still desired exact owner stays unavailable;
only an identity not hosted here may use the foreign owner.
""".
-spec history_view_at({binary(), <<_:256>>}, pos_integer(), integer()) ->
          {ok, history_view()} |
          {error, timeout | not_ready | not_hosted | invalid_identity}.
history_view_at({Ns, <<_:256>> = Anchor} = Identity, Slot, Deadline)
  when is_binary(Ns), byte_size(Ns) > 0,
       is_integer(Slot), Slot > 0, is_integer(Deadline) ->
    case Deadline > quod_time:mono_ms() of
        false -> {error, timeout};
        true ->
            try quod_reg:where({quod_simplex, Ns}) of
                Owner when is_pid(Owner) ->
                    capture_hosted_at(Owner, Identity, Slot, Deadline);
                undefined ->
                    case quod_ontology:genesis_anchor(Ns) of
                        {ok, Anchor} -> {error, not_ready};
                        {error, genesis_unavailable} -> {error, not_ready};
                        _ -> {error, not_hosted}
                    end
            catch
                error:badarg -> {error, not_ready};
                exit:_ -> {error, not_ready}
            end
    end;
history_view_at(_Identity, _Slot, _Deadline) -> {error, invalid_identity}.

capture_hosted_at(Owner, {Ns, _Anchor} = Identity, Slot, Deadline) ->
    Key = {committed, Ns},
    Subscribed =
        try gproc:get_value(quod_reg:prop(Key)) of
            _ -> false
        catch error:badarg -> quod_reg:subscribe(Key)
        end,
    Monitor = erlang:monitor(process, Owner),
    try capture_hosted_progress(Owner, Identity, Slot, Deadline, Monitor)
    after
        erlang:demonitor(Monitor, [flush]),
        case Subscribed of
            true -> _ = catch quod_reg:unsubscribe(Key);
            false -> ok
        end
    end.

capture_hosted_progress(Owner, {Ns, _Anchor} = Identity, Slot, Deadline, Monitor) ->
    case call_history_view(Owner, Ns, Identity, {committed, Slot}, Deadline) of
        {pending, Height} ->
            await_hosted_progress(Owner, Identity, Slot, Height, Deadline, Monitor);
        Result -> Result
    end.

await_hosted_progress(Owner, {Ns, _Anchor} = Identity, Slot, Height, Deadline, Monitor) ->
    case Deadline - quod_time:mono_ms() of
        Remaining when Remaining > 0 ->
            receive
                {committed, Ns, Advanced, _Entry} ->
                    continue_hosted_progress(
                      Advanced, Owner, Identity, Slot, Height, Deadline, Monitor);
                {certified_head, Ns, Advanced} ->
                    continue_hosted_progress(
                      Advanced, Owner, Identity, Slot, Height, Deadline, Monitor);
                {'DOWN', Monitor, process, Owner, _Reason} ->
                    {error, not_ready}
            after Remaining -> {error, timeout}
            end;
        _ -> {error, timeout}
    end.

continue_hosted_progress(Advanced, Owner, Identity, Slot, Height, Deadline, Monitor)
  when is_integer(Advanced), Advanced > Height, Advanced >= Slot ->
    capture_hosted_progress(Owner, Identity, Slot, Deadline, Monitor);
continue_hosted_progress(_Advanced, Owner, Identity, Slot, Height, Deadline, Monitor) ->
    await_hosted_progress(Owner, Identity, Slot, Height, Deadline, Monitor).

call_history_view(Owner, Ns, Identity, Requirement, Deadline) ->
    case max(0, Deadline - quod_time:mono_ms()) of
        0 -> {error, timeout};
        Remaining ->
            case history_owner_live(Owner, Ns) of
                false -> {error, not_ready};
                true ->
                    try gen_statem:call(
                          Owner, {history_view, Identity, Requirement, Deadline}, Remaining) of
                        {ok, #{owner := Owner} = View} ->
                            case {Deadline > quod_time:mono_ms(), history_view_live(View)} of
                                {false, _} -> {error, timeout};
                                {true, true} -> {ok, View};
                                {true, false} -> {error, not_ready}
                            end;
                        {pending, Height} when is_integer(Height), Height >= 0 ->
                            case {Deadline > quod_time:mono_ms(),
                                  history_owner_live(Owner, Ns)} of
                                {false, _} -> {error, timeout};
                                {true, false} -> {error, not_ready};
                                {true, true} -> {pending, Height}
                            end;
                        {error, _} = Error -> Error;
                        _ -> {error, not_ready}
                    catch
                        exit:{timeout, _} -> {error, timeout};
                        exit:_ -> {error, not_ready}
                    end
            end
    end.

-doc "Check the captured local owner incarnation; this confers no certificate authority.".
-spec history_view_live(history_view() |
                          #{owner := pid(), identity := {binary(), <<_:256>>}}) ->
          boolean().
history_view_live(#{owner := Owner, identity := {Ns, _Anchor}}) when is_pid(Owner) ->
    history_owner_live(Owner, Ns);
history_view_live(_) -> false.

history_owner_live(Owner, Ns) when is_pid(Owner) ->
    try quod_reg:where({quod_simplex, Ns}) =:= Owner andalso is_process_alive(Owner)
    catch _:_ -> false
    end;
history_owner_live(_, _) -> false.

-doc "Return the exact certified claim at its projected first slot.".
-spec operation_claim_evidence(binary(), pos_integer(), term(), integer()) ->
          {ok, quod_dtx:certified_ref(), #transaction{}} |
          {error, timeout | not_ready | not_found | invalid_request}.
operation_claim_evidence(Ns, Slot, OperationRef, Deadline)
  when is_binary(Ns), byte_size(Ns) > 0,
       is_integer(Slot), Slot > 0, is_integer(Deadline) ->
    case history_view(Ns, any, Deadline) of
        {ok, View} -> evidence_at(View, Slot, {claim, OperationRef});
        {error, _} = Error -> Error
    end;
operation_claim_evidence(_Ns, _Slot, _OperationRef, _Deadline) ->
    {error, invalid_request}.

-doc "Read the exact completion at the durable outcome's receipt height.".
-spec operation_completion_evidence(binary(), pos_integer(), term(), integer()) ->
          {ok, quod_dtx:certified_ref(), #transaction{}} |
          {error, timeout | not_ready | not_found | invalid_request}.
operation_completion_evidence(Ns, Slot, OperationRef, Deadline)
  when is_binary(Ns), byte_size(Ns) > 0,
       is_integer(Slot), Slot > 0, is_integer(Deadline) ->
    case history_view(Ns, any, Deadline) of
        {ok, View} -> operation_completion_evidence(View, Slot, OperationRef);
        {error, _} = Error -> Error
    end;
operation_completion_evidence(_, _, _, _) -> {error, invalid_request}.

%% Read the completion from the caller's pinned source view, without recapture.
-spec operation_completion_evidence(history_view(), pos_integer(), term()) ->
          {ok, quod_dtx:certified_ref(), #transaction{}} | {error, term()}.
operation_completion_evidence(#{identity := {Ns, Anchor}} = View, Slot,
                              {operation, Ns, Anchor, _, _} = OperationRef) ->
    case history_view_live(View) of
        true ->
            Result = evidence_at(View, Slot, {completion, OperationRef}),
            case history_view_live(View) of true -> Result; false -> {error, not_ready} end;
        false -> {error, not_ready}
    end;
operation_completion_evidence(_, _, _) -> {error, invalid_request}.

evidence_at(View, Slot, Selection) ->
    case read_evidence_at(View, Slot, Selection) of
        {ok, Ref, Transaction, _Entry} -> {ok, Ref, Transaction};
        {error, _} = Error -> Error
    end.

read_evidence_at(#{identity := {Ns, _} = Identity, snapshot := Snapshot},
            Slot, {Kind, _} = Selection) ->
    Attributes = #{'quod.namespace' => Ns, 'quod.ledger.slot' => Slot,
                   'quod.evidence.kind' => atom_to_binary(Kind)},
    case quod_trace:with_optional_span(
           quod_trace:context(), <<"quod.evidence.ledger_open">>, internal,
           Attributes,
           fun() -> quod_ledger_store:open_ro_snapshot(Snapshot) end) of
        {ok, Store} ->
            try
                case quod_trace:with_optional_span(
                       quod_trace:context(), <<"quod.evidence.read_at">>, internal,
                       Attributes,
                       fun() -> quod_ledger_store:read_at(Store, Slot, Selection) end) of
                    {ok, Entry} ->
                        case quod_ledger:selected_record(Entry) of
                            #transaction{} = Transaction ->
                                case quod_dtx:certified_entry_ref(Identity, Entry, Transaction) of
                                    {ok, Ref} -> {ok, Ref, Transaction, Entry};
                                    _ -> {error, invalid_request}
                                end;
                            none -> {error, not_found}
                        end;
                    _ ->
                        {error, not_found}
                end
            after quod_ledger_store:close(Store)
            end;
        _ ->
            {error, not_ready}
    end.

dtx_outcome_result(_OutcomeRef, {ok, Status}) when is_map(Status) ->
    {ok, Status};
dtx_outcome_result(OutcomeRef, {error, _}) ->
    {error, {outcome_unknown, OutcomeRef}}.

-doc "Verify exact local-only evidence within the serving request's absolute deadline.".
-spec dtx_local_evidence(binary(), quod_dtx:certified_ref(),
                         entry | transaction | vote | resolve | complete, integer()) ->
          {ok, map()} |
          {error, not_ready | not_found | invalid_request}.
dtx_local_evidence(Ns, Ref, ExpectedPhase, Deadline)
  when is_binary(Ns), byte_size(Ns) > 0, is_integer(Deadline) ->
    case {valid_dtx_phase(ExpectedPhase), quod_dtx:certified_ref_binding(Ref)} of
        {true, {ok, {Ns, _Anchor} = Identity, Slot, _Digest}} ->
            case history_view(Identity, any, Deadline) of
                {ok, #{slot := Height} = View} when Height >= Slot ->
                    local_evidence_result(quod_foreign_log:verify_local_deadline(
                      View, Ref, ExpectedPhase, Deadline));
                {ok, _Lagging} -> {error, not_found};
                {error, invalid_identity} -> {error, invalid_request};
                {error, _Unavailable} -> {error, not_ready}
            end;
        _ -> {error, invalid_request}
    end;
dtx_local_evidence(_Ns, _Ref, _ExpectedPhase, _Deadline) ->
    {error, invalid_request}.

local_evidence_result({ok, Evidence}) -> {ok, Evidence};
local_evidence_result({error, phase_mismatch}) -> {error, invalid_request};
local_evidence_result({error, invalid_foreign_reference}) ->
    {error, invalid_request};
local_evidence_result({error, bad_foreign_reference}) ->
    {error, invalid_request};
local_evidence_result({error, _Unavailable}) -> {error, not_ready}.

-doc "Return the verified local-ledger source for an exact Resolve reference.".
-spec dtx_applied_source(binary(), quod_dtx:certified_ref()) ->
          {ok, {local, map()}} |
          {error, not_ready | not_found | invalid_request}.
dtx_applied_source(Ns, ResolveRef)
  when is_binary(Ns), byte_size(Ns) > 0 ->
    try
        case gen_statem:call(
               quod_reg:via({quod_simplex, Ns}),
               {dtx_local_evidence_source, ResolveRef, resolve}, 1000) of
            {ok, LocalSource} ->
                {ok, {local, LocalSource}};
            {error, _} = Error -> Error
        end
    catch exit:_ -> {error, not_ready}
    end;
dtx_applied_source(_Ns, _ResolveRef) ->
    {error, invalid_request}.

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

-doc "Revalidate a previously acquired proof-access generation.".
-spec check_proof_access(term()) -> ok | {error, term()}.
check_proof_access({quod_proof_access, Ns, Owner, ExpectedGeneration, CommitteeId})
  when is_binary(Ns), is_pid(Owner), is_integer(ExpectedGeneration), ExpectedGeneration >= 0 ->
    case proof_gate_row(Ns) of
        {ok, Owner, _Ready, _Generation, CommitteeId,
         [{GroupId, _Slot, _GroupGeneration} | _]} ->
            {error, {transaction_pending, GroupId}};
        {ok, Owner, false, _Generation, CommitteeId, []} ->
            {error, {ontology_rebuilding, Ns}};
        {ok, Owner, true, ExpectedGeneration, CommitteeId, []} ->
            ok;
        {ok, Owner, _Ready, _ChangedGeneration, _CommitteeId, _Fences} ->
            {error, {ontology_busy, Ns}};
        _ ->
            {error, {ontology_rebuilding, Ns}}
    end;
check_proof_access(_Token) ->
    {error, invalid_proof_access}.

proof_gate_row(Ns) ->
    try
        Table = ets:whereis(binary_to_existing_atom(genesis_table_name(Ns), utf8)),
        Owner = ets:info(Table, owner),
        [{proof_gate, Ready, Generation, BlockingFences,
          _Self, _Committee, CommitteeId, _Routes}] = ets:lookup(Table, proof_gate),
        true = is_pid(Owner) andalso is_boolean(Ready) andalso
            is_integer(Generation) andalso Generation >= 0 andalso
            is_binary(CommitteeId) andalso byte_size(CommitteeId) =:= 32 andalso
            valid_blocking_fences(BlockingFences),
        {ok, Owner, Ready, Generation, CommitteeId, BlockingFences}
    catch error:_ -> unavailable
    end.

-doc """
Wait for attestation access in an existing worker under its absolute deadline.
Subscribe before checking; only the exact cleared fence wakes this acquisition.
Owner death and the caller-owned cancellation monitors terminate the wait.
There is no owner queue, polling, snapshot or signature while waiting.
""".
-spec await_proof_access(binary(), integer(), #{reference() => true}) ->
          {ok, quod_erlog_db_local_prove:access_guard()} | {error, term()}.
await_proof_access(Ns, Deadline, CancelMonitors) ->
    case {identity_view(Ns), proof_gate_row(Ns)} of
        {{ok, #{committee_id := CommitteeId}}, {ok, Owner, _, _, CommitteeId, _}} ->
            Key = {proof_gate, {Ns, Owner}},
            true = quod_reg:subscribe(Key),
            Monitor = monitor(process, Owner),
            try acquire_attestation_access(Ns, {Owner, CommitteeId}, Deadline,
                                           CancelMonitors#{Monitor => true})
            after
                demonitor(Monitor, [flush]),
                quod_reg:unsubscribe(Key)
            end;
        {{error, Reason}, _} -> {error, Reason};
        _ -> {error, unavailable}
    end.

acquire_attestation_access(Ns, Binding, Deadline, Monitors) ->
    receive
        {'DOWN', Ref, process, _, _} when is_map_key(Ref, Monitors) -> {error, unavailable}
    after 0 -> acquire_attestation_gate(Ns, Binding, Deadline, Monitors)
    end.

acquire_attestation_gate(Ns, {Owner, CommitteeId} = Binding, Deadline, Monitors) ->
    case Deadline > quod_time:mono_ms() of
        false -> {error, timeout};
        true ->
            case proof_gate_row(Ns) of
                {ok, Owner, false, _, CommitteeId, _} ->
                    {error, {ontology_rebuilding, Ns}};
                {ok, Owner, true, Generation, CommitteeId, []} ->
                    {ok, {quod_proof_access, Ns, Owner, Generation, CommitteeId}};
                {ok, Owner, true, _, CommitteeId, [Fence | _]} ->
                    receive
                        {proof_fence_cleared, Owner, Fence} ->
                            acquire_attestation_access(Ns, Binding, Deadline, Monitors);
                        {proof_gate_invalidated, Owner} -> {error, unavailable};
                        {'DOWN', Ref, process, _, _} when is_map_key(Ref, Monitors) ->
                            {error, unavailable}
                    after max(0, Deadline - quod_time:mono_ms()) -> {error, timeout}
                    end;
                _ -> {error, unavailable}
            end
    end.

publish_proof_gate_changes(Before, {proof_gate, Ready, _, Fences, _, _, CommitteeId, _}, Ns) ->
    case proof_gate_row_for_state(Before) of
        {proof_gate, WasReady, _, Previous, _, _, OldCommitteeId, _} ->
            case (WasReady andalso not Ready) orelse CommitteeId =/= OldCommitteeId of
                true -> quod_reg:publish({proof_gate, {Ns, self()}}, {proof_gate_invalidated, self()});
                false -> ok
            end,
            lists:foreach(fun(Fence) ->
                quod_reg:publish({proof_gate, {Ns, self()}},
                                 {proof_fence_cleared, self(), Fence})
            end, Previous -- Fences);
        undefined -> ok
    end.

valid_blocking_fences(Fences) when is_list(Fences) ->
    Fences =:= lists:usort(Fences) andalso
        lists:all(
          fun({<<_:256>>, Slot, Generation}) ->
                  is_integer(Slot) andalso Slot > 0 andalso
                      is_integer(Generation) andalso Generation >= 0;
             (_) -> false
          end, Fences);
valid_blocking_fences(_) -> false.

blocking_fences(#{apply_fences := Fences}) ->
    lists:sort(
      maps:fold(
        fun(GroupId,
            #{slot := Slot, generation := GroupGeneration,
              blocking := true}, Acc) ->
                [{GroupId, Slot, GroupGeneration} | Acc];
           (_GroupId, _NonBlocking, Acc) ->
                Acc
        end, [], Fences)).

proof_gate_tuple(
  Ready,
  #s{self = Self, validators = Validators,
     committee_id = CommitteeId, validator_routes = Routes,
     dtx_projection = #{generation := Generation} = Projection})
  when is_boolean(Ready) ->
    BlockingFences = blocking_fences(Projection),
    {proof_gate, Ready, Generation, BlockingFences,
     Self, lists:sort(Validators), CommitteeId, Routes}.

%% The Simplex owner is the sole writer of this protected row.  Compare the
%% projected value first so ordinary content commits pay no ETS-write cost.
%% During pre-table startup the existing-atom lookup fails; init/1 publishes
%% the initial closed row atomically with the anchor immediately afterwards.
refresh_proof_gate(
  Before,
  #s{ns = Ns,
     dtx_projection = #{generation := _Generation,
                        apply_fences := _Fences}} = S)
  when is_record(Before, s) ->
    CurrentRow = proof_gate_tuple(S#s.prolog_ready, S),
    %% Before storage initialization there is deliberately no DTX projection
    %% and therefore no publishable gate row.  Compare only complete rows; the
    %% first complete state must always be installed.
    case proof_gate_row_for_state(Before) =:= CurrentRow of
        true -> ok;
        false ->
            try
                true = ets:insert(
                         binary_to_existing_atom(genesis_table_name(Ns), utf8),
                         CurrentRow),
                publish_proof_gate_changes(Before, CurrentRow, Ns)
            catch
                error:badarg -> ok
            end
    end,
    S;
refresh_proof_gate(_Before, S) ->
    S.

proof_gate_row_for_state(
  #s{dtx_projection = #{generation := _Generation,
                        apply_fences := _Fences}} = S) ->
    proof_gate_tuple(S#s.prolog_ready, S);
proof_gate_row_for_state(#s{}) ->
    undefined.

-doc "Read consensus-installed membership and routes, independently of local KB apply readiness.".
-spec identity_view(binary()) ->
          {ok, map()} | {error, unavailable | not_validator}.
identity_view(Ns) when is_binary(Ns) ->
    try
        Table = ets:whereis(binary_to_existing_atom(genesis_table_name(Ns), utf8)),
        [{anchor, <<_:256>> = Anchor}] = ets:lookup(Table, anchor),
        ets:lookup(Table, proof_gate)
    of
        [{proof_gate, _Ready, _Generation, _Fences,
          <<_:256>> = Self, Committee, <<_:256>> = CommitteeId, Routes}]
          when is_list(Committee), is_map(Routes) ->
            case lists:member(Self, Committee) of
                true ->
                    {ok, #{identity => {Ns, Anchor}, self => Self,
                           committee => Committee,
                           committee_id => CommitteeId,
                           route_candidates =>
                               [{Key, [Endpoint]}
                                || {Key, Endpoint} <- lists:sort(
                                                       maps:to_list(Routes))]}};
                false -> {error, not_validator}
            end;
        _ -> {error, unavailable}
    catch
        error:_ -> {error, unavailable}
    end;
identity_view(_Ns) ->
    {error, unavailable}.

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
    DtxChan = quod_dtx_endpoint:channel(Ns),
    quod_reg:subscribe({channel, Chan}),                 %% receive peers' proposals/shares/certs
    quod_reg:subscribe({channel, RelayChan}),             %% receive bounded transaction-relay frames
    quod_reg:subscribe({channel, DtxChan}),               %% receive bounded DTX recovery requests/replies
    quod_reg:subscribe({quod_prolog, Ns}),                 %% actual parent application, not a timer retry
    RelayTimeout = relay_timeout_ms(Cfg),
    S0 = #s{ns = Ns, self = maps:get(pubkey, Id), id = Id, store = Store,
            chan = Chan, relay_chan = RelayChan, dtx_chan = DtxChan,
            relay_timeout_ms = RelayTimeout,
            batch_window_ms = maps:get(batch_window_ms, Cfg),
            validation_ttl_ms = maps:get(validation_ttl_ms, Cfg, ?QUOD_VALIDATION_TTL_MS),
            detailed_metrics = maps:get(detailed_consensus_metrics, Cfg, false),
            %% Node-local diagnostics must not ride a prepared lifecycle config
            %% into a journal or committed hosting fact. Read once at owner boot.
            trace_owner_turns = application:get_env(quod, consensus_owner_tracing, false)},
    %% Storage recovery owns one strict order: establish the immutable anchor,
    %% bind/recover the signing journal, validate the full ledger projection,
    %% then reconcile retained signing state. A fresh founder creates the
    %% domain-bound journal before appending genesis; an existing ledger never
    %% creates or mutates a missing journal.
    try restore_storage(S0, Cfg) of
        {S1, GenesisHash, Journal} ->
            Domain = consensus_domain(Ns, GenesisHash),
            Committed = S1#s.slot,
            %% One table per operator-created namespace. `genesis_hash/1` uses
            %% binary_to_existing_atom/2, so readers never mint table-name atoms.
            %% The proof gate starts closed and opens only after the ordered
            %% replay reaches this validated head and that Prolog incarnation
            %% explicitly acknowledges the height.
            GenesisTable = ets:new(
                             genesis_table(Ns),
                             [named_table, protected, set]),
            true = ets:insert(
                     GenesisTable,
                     [{anchor, GenesisHash},
                      proof_gate_tuple(false, S1)]),
            S2 = restore_signing_state(
                   S1#s{signing_journal = Journal,
                        genesis_hash = GenesisHash,
                        consensus_domain = Domain}),
            Eng = eng_new(Domain, active_validators(S2), Committed),
            %% The common owner reconciliation arms boot/gap recovery once its
            %% catch-up sibling is up. The tick handles redials and failed-pull
            %% backoff, and notices sibling startup even without peer traffic.
            {ok, running,
             S2#s{last_applied = 0, approved = Committed, eng = Eng},
             [{next_event, internal, restore_signing_engine},
              tick_timeout()]}
    catch
        throw:{genesis_failed, _} = Reason -> {stop, Reason}
    end.

restore_signing_state(S = #s{signing_journal = Journal}) ->
    restore_pending_transactions(
      restore_pending_dtx(
        S#s{rounds = signing_rounds(Journal)}, Journal), Journal).

%% Rebuild the volatile engine from the exact block and vote decisions owned by
%% the signing journal.  Feed them through the ordinary engine ingestion path:
%% restart is not a second consensus path, and any certificate/finality that
%% becomes derivable is handled by the same event reducer as live traffic.
-ifdef(TEST).
restore_signing_engine(S = #s{signing_journal = memory}) ->
    S;
restore_signing_engine(S = #s{signing_journal = Journal}) ->
    restore_signing_engine_from_journal(Journal, S).
-else.
restore_signing_engine(S = #s{signing_journal = Journal}) ->
    restore_signing_engine_from_journal(Journal, S).
-endif.
restore_signing_engine_from_journal(Journal, S = #s{slot = Committed}) ->
    Blocks = [{Slot, Block}
              || {Slot, Block} <- maps:to_list(
                                    quod_signing_journal:supported_blocks(
                                      Journal)),
                 Slot > Committed],
    S1 = engine_step(
           [{block, block_hash(Block), Block}
            || {_Slot, Block} <- lists:sort(Blocks)], S),
    Shares = lists:flatmap(
               fun({Slot, #round{supporting = Support,
                                 final = Final}}) ->
                       restored_own_shares(Slot, Support, Final, S1)
               end,
               lists:sort(maps:to_list(S1#s.rounds))),
    engine_step([{share, Share} || Share <- Shares], S1).

restored_own_shares(Slot, Support, Final, S) ->
    SupportShares =
        case Support of
            none -> [];
            SupportBH ->
                {ok, SupportShare} =
                    latched_share(support, Slot, SupportBH, S),
                [SupportShare]
        end,
    FinalShares =
        case Final of
            none -> [];
            complaint ->
                {ok, ComplaintShare} =
                    latched_share(complaint, Slot, none, S),
                [ComplaintShare];
            {commit, CommitBH} ->
                {ok, CommitShare} =
                    latched_share(commit, Slot, CommitBH, S),
                [CommitShare]
        end,
    SupportShares ++ FinalShares.

-ifdef(TEST).
restore_pending_transactions(S, memory) -> S;
restore_pending_transactions(S, Journal) ->
    restore_pending_transactions_journal(S, Journal).
-else.
restore_pending_transactions(S, Journal) ->
    restore_pending_transactions_journal(S, Journal).
-endif.

restore_pending_transactions_journal(S0, Journal) ->
    maps:fold(
      fun(TxId, Row, S) -> restore_pending_transaction(TxId, Row, S) end,
      S0, quod_signing_journal:pending_transactions(Journal)).

restore_pending_transaction(
  TxId, #{admission := RecordedAdmission, sequence := Sequence,
          state := State, envelope := Envelope},
  S = #s{ns = Ns, genesis_hash = Anchor, self = Self, custody = Custody,
         custody_ready = Ready, custody_deadlines = Deadlines,
         custody_bytes = Bytes0}) ->
    Submission = binary_to_term(Envelope, [safe]),
    RecordedBinding = {Ns, Anchor, RecordedAdmission},
    case quod_transaction:decode_verified_submission(
           RecordedBinding, Submission) of
        {ok, #transaction{tx_id = TxId, author = Self,
                          author_seq = Sequence} = Change} ->
            OperationCustody = operation_custody_submission(Submission),
            CurrentAdmission = current_effect_admission(S),
            case CurrentAdmission =:= RecordedAdmission orelse
                 OperationCustody of
                true ->
                    SubmissionId = quod_transaction:submission_id(Submission),
                    Bytes = byte_size(Envelope),
                    Deadline = ?MAX_SLOT,
                    Waiter = #waiter{
                               reply_to = {transaction_custody, TxId},
                                     submission_id = SubmissionId,
                                     trace_ctx = otel_ctx:new(),
                                     trace_span = undefined},
                    Record0 = #custody{waiter = Waiter, change = Change,
                                       submission = Submission,
                                       original_arrival = quod_time:mono_ms(),
                                       deadline = Deadline, bytes = Bytes},
                    Record = restore_transaction_custody(
                               State, Ns,
                               State =:= dormant orelse
                                 CurrentAdmission =/= RecordedAdmission,
                               Record0),
                    Placement = Record#custody.placement,
                    S#s{custody = Custody#{SubmissionId => Record},
                        custody_ready = case Placement of
                            ready ->
                                gb_sets:add_element(
                                       {Sequence, SubmissionId}, Ready);
                            {cancelling, _Pid, _Monitor} -> Ready
                        end,
                        custody_deadlines = gb_sets:add_element(
                                              {Deadline, SubmissionId},
                                              Deadlines),
                        custody_bytes = Bytes0 + Bytes};
                false ->
                    error({signing_journal_transaction_not_in_charge, TxId})
            end;
        _ -> error({signing_journal_bad_transaction, TxId})
    end.

%% A dormant signing row has no surviving proof worker after restart. Restore
%% it directly under the one cancellation owner; leaving it merely dormant
%% would strand a target-side reservation or operation row forever.
restore_transaction_custody(_State, Ns, true,
                            Record = #custody{submission = Submission}) ->
    case start_dormant_cancellation_owner(Ns, Submission) of
        {ok, Pid, Monitor} ->
            Record#custody{placement = {cancelling, Pid, Monitor}};
        {error, Reason} ->
            error({dormant_operation_recovery, Reason})
    end;
%% A fsynced bound row proves target preparation completed. Recovery may
%% therefore resume consensus directly.
restore_transaction_custody(State, _Ns, false, Record)
  when State =:= bound; State =:= ready ->
    Record#custody{placement = ready}.

-ifdef(TEST).
signing_rounds(memory) -> #{};
signing_rounds(Journal) -> signing_rounds_journal(Journal).
-else.
signing_rounds(Journal) -> signing_rounds_journal(Journal).
-endif.
signing_rounds_journal(Journal) ->
    maps:map(
      fun(_Slot, #{support := Support, final := Final}) ->
              #round{supporting = Support, final = Final}
      end, quod_signing_journal:rounds(Journal)).

-ifdef(TEST).
restore_pending_dtx(S, memory) ->
    S;
restore_pending_dtx(S, Journal) ->
    restore_pending_dtx_journal(S, Journal).
-else.
restore_pending_dtx(S, Journal) ->
    restore_pending_dtx_journal(S, Journal).
-endif.
restore_pending_dtx_journal(S, Journal) ->
    lists:foldl(
      fun({GroupId, Pending}, Acc) ->
              restore_pending_dtx(GroupId, Pending, Acc)
      end, S,
      lists:sort(maps:to_list(
                   quod_signing_journal:pending_dtx(Journal)))).

restore_pending_dtx(
  _GroupId, #{sequence := 0, envelope := none, material := Material}, S) ->
    A = admission_state(S),
    S#s{dtx_admission = A#dtx_admission{waiting =
        quod_atomic_admission:admit(Material, none, #{}, A#dtx_admission.waiting)}};
restore_pending_dtx(
  GroupId, #{body := Body, envelope := Envelope}, S)
  when is_binary(GroupId), byte_size(GroupId) =:= 32,
       is_binary(Body), is_binary(Envelope) ->
    case quod_atomic:decode_control(Envelope) of
        {ok, Control} ->
            {Record, Digest, _} = quod_atomic:control_material(Control),
            case quod_atomic:group_id(Control) =:= GroupId andalso
                 term_to_binary(Record, [deterministic]) =:= Body of
                true ->
                    InsertedAt = quod_time:mono_ms(),
                    Submission =
                        #dtx_submission{
                          control = Control,
                          envelope = Envelope, group_id = GroupId,
                          digest = Digest,
                          inserted_at = InsertedAt,
                          observation_started_at = InsertedAt,
                          placement = blocked,
                          bytes = byte_size(Envelope)},
                    A = admission_state(S),
                    S#s{dtx_admission = A#dtx_admission{waiting =
                        quod_atomic_admission:recheck(Submission, A#dtx_admission.waiting)}};
                _ ->
                    error({signing_journal_bad_pending, GroupId})
            end;
        {error, Reason} ->
            error({signing_journal_bad_pending, GroupId, Reason})
    end;
restore_pending_dtx(GroupId, _Pending, _S) ->
    error({signing_journal_bad_pending, GroupId}).

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

%% Recover the one durable state machine. Existing ledgers require an existing
%% domain-bound signing journal; empty ledgers initialize it before genesis or
%% catch-up can append anything. The complete semantic fold precedes the sole
%% reconciliation/pruning call, so raw height can never erase signing evidence.
restore_storage(S0 = #s{store = Store}, Cfg) ->
    Root = quod_ledger_store:ledger_dir(Cfg),
    ok = quod_dtx_phase_index:cleanup(Root, S0#s.ns),
    {ok, Index} = quod_dtx_phase_index:open(Root, S0#s.ns),
    S = S0#s{phase_index = Index},
    try case quod_ledger_store:last(Store) of
        0 -> initialize_empty_storage(S, Cfg);
        Last -> recover_existing_storage(S, Cfg, Last)
    end
    catch Class:Reason:Stack ->
        _ = quod_dtx_phase_index:close(Index),
        erlang:raise(Class, Reason, Stack)
    end.

recover_existing_storage(S0 = #s{ns = Ns, store = Store, phase_index = PhaseIndex}, Cfg, Last) ->
    Anchor =
        case local_genesis_hash(S0) of
            <<_:256>> = Hash -> Hash;
            undefined -> error({invalid_transaction_history, 1})
        end,
    ok = require_configured_anchor(Anchor, Cfg),
    Domain = consensus_domain(Ns, Anchor),
    {ok, Journal0} = quod_signing_journal:recover(
                       Ns, Domain, data_dir(Cfg)),
    Binding = {Ns, Anchor},
    Projection0 = history_projection(Binding),
    PendingTransactions0 =
        quod_signing_journal:pending_transactions(Journal0),
    {Projection, UncommittedTransactions} =
            quod_ledger_store:fold(
              Store, 1, Last,
              fun(E, {Acc, PendingEffects}) ->
                      #entry{data = Data} = quod_ledger:entry_view(E),
                      P = checked_log_projection_step(Binding, E, Acc, PhaseIndex),
                      {retain_owner_projection(P, quod_dtx_phase_index:new_delta(), S0),
                       remove_committed_effect_ids(Data, PendingEffects)}
              end,
              {Projection0, PendingTransactions0}),
    S1 = install_projection(Projection, S0#s{slot = Last}),
    {ok, Journal1} = quod_dtx_owner:reconcile_journal(
                       Last, Projection, PhaseIndex, Journal0),
    Journal2 = retire_recovered_transactions(
                 PendingTransactions0, UncommittedTransactions, Journal1),
    S2 = reconcile_transaction_signing_custody(
           S1#s{signing_journal = Journal2}),
    finalize_restored_storage(S2, Anchor, S2#s.signing_journal).

remove_committed_effect_ids(Data, Pending) ->
    case quod_ledger:classify(Data) of
        {content, Transactions} ->
            lists:foldl(
              fun(#transaction{tx_id = TxId}, Acc) ->
                      maps:remove(TxId, Acc);
                 (_, Acc) -> Acc
              end, Pending, Transactions);
        _ -> Pending
    end.

retire_recovered_transactions(Before, After, Journal0) ->
    maps:fold(
      fun(TxId, _Row, Journal) ->
              case maps:is_key(TxId, After) of
                  true -> Journal;
                  false ->
                      {ok, Journal1} =
                          quod_signing_journal:retire_transaction(
                            Journal, TxId),
                      Journal1
              end
      end, Journal0, Before).

initialize_empty_storage(S0 = #s{ns = Ns}, #{mode := join} = Cfg) ->
    {ok, Anchor} = consensus_anchor(S0, Cfg),
    Domain = consensus_domain(Ns, Anchor),
    {ok, Journal0} = quod_signing_journal:initialize(
                       Ns, Domain, data_dir(Cfg)),
    Projection = history_projection({Ns, Anchor}),
    {ok, Journal1} = quod_dtx_owner:reconcile_journal(
                       0, Projection, S0#s.phase_index, Journal0),
    finalize_restored_storage(
      install_projection(Projection, S0), Anchor, Journal1);
initialize_empty_storage(S0 = #s{ns = Ns}, #{mode := create} = Cfg) ->
    Entry = genesis_entry(Cfg, S0),
    Anchor = entry_block_hash(Entry),
    Domain = consensus_domain(Ns, Anchor),
    %% Once a signature has ever been exposed this initialization refuses to
    %% replace the journal, even if the ledger was removed independently.
    {ok, Journal0} = quod_signing_journal:initialize(
                       Ns, Domain, data_dir(Cfg)),
    SAppended = append_genesis(Entry, S0),
    Projection0 = checked_log_projection_step(
                   {Ns, Anchor}, Entry,
                   history_projection({Ns, Anchor})),
    Projection = retain_owner_projection(Projection0, quod_dtx_phase_index:new_delta(), SAppended),
    S1 = install_projection(Projection, SAppended#s{slot = 1}),
    {ok, Journal1} = quod_dtx_owner:reconcile_journal(
                       1, Projection, S1#s.phase_index, Journal0),
    finalize_restored_storage(S1, Anchor, Journal1).

finalize_restored_storage(S0, Anchor, Journal) ->
    S1 = S0#s{sync = initial_sync(S0),
              next_author_seq =
                  maps:get(S0#s.self, S0#s.author_seqs, 0) + 1},
    {S1, Anchor, Journal}.

require_configured_anchor(_Anchor, #{mode := create}) -> ok;
require_configured_anchor(Anchor, #{mode := join, genesis_hash := Anchor}) -> ok;
require_configured_anchor(_Anchor, #{mode := join}) ->
    error({bad_config, genesis_anchor_mismatch}).

%% Resolve the one immutable chain anchor used by every vote in this process.
%% A founder derives it from its durable slot-1 block. A fresh joiner uses the
%% configured out-of-band pin; once any prefix exists, that pin must equal the
%% locally reconstructed genesis or startup fails before a vote can be restored.
consensus_anchor(#s{slot = 0}, #{mode := join, genesis_hash := GenesisHash})
  when is_binary(GenesisHash), byte_size(GenesisHash) =:= 32 ->
    {ok, GenesisHash};
consensus_anchor(_S, _Cfg) ->
    {error, missing_genesis_anchor}.

%% The sole validator is ready immediately because no other node could have committed past its durable head.
%% Every other shape must corroborate its tip through recovery before it can emit consensus evidence.
initial_sync(#s{self = Self} = S) ->
    case active_validators(S) of
        [Self] -> ready;
        _      -> unconfirmed
    end.

%% Fresh create: the canonical founder mints a random incarnation and constructs ONE genesis block
%% (slot 1). Its transaction asserts `consensus_incarnation/1`, every founding member's
%% `peer_admitted` fact, and the ontology's configured initial content. The incarnation makes
%% two fresh foundings cryptographically distinct even when every operator input is byte-identical.
%% The caller binds the signing journal to the resulting anchor before append.
%% Loading or compiling initial content may throw `{genesis_failed,_}` before
%% either durable file changes.
genesis_entry(#{prepared_genesis_entry := View} = Cfg,
              #s{ns = Ns, self = Self}) ->
    Anchor = maps:get(genesis_hash, Cfg, undefined),
    case quod_ledger:from_entry_view(View) of
        {ok, Entry} ->
            case valid_prepared_genesis(View, Ns, Self) andalso
                 entry_block_hash(Entry) =:= Anchor of
                true -> Entry;
                false -> throw({genesis_failed, invalid_prepared_genesis})
            end;
        {error, _} -> throw({genesis_failed, invalid_prepared_genesis})
    end;
genesis_entry(Cfg, #s{ns = Ns, self = Self}) ->
    {ok, Entry, _Anchor} = prepare_genesis(Cfg, Ns, Self),
    Entry.

-doc "Freeze and hash the exact slot-1 genesis entry used by runtime creation.".
-spec prepare_genesis(map(), binary(), binary()) ->
          {ok, quod_ledger:entry_artifact(), <<_:256>>} | {error, term()}.
prepare_genesis(Cfg, Ns, <<_:256>> = Self)
  when is_map(Cfg), is_binary(Ns), byte_size(Ns) > 0 ->
    try
        Incarnation = crypto:strong_rand_bytes(32),
        {ok, Block} = quod_ledger:new_block(
                        1, 0,
                        {batch, [genesis_tx(Cfg, Ns, Self, Incarnation)]},
                        0),
        Entry = quod_ledger:entry(Block, none),
        {ok, Entry, entry_block_hash(Entry)}
    catch
        throw:{genesis_failed, Reason} -> {error, Reason};
        error:Reason -> {error, Reason}
    end;
prepare_genesis(_Cfg, _Ns, _Self) ->
    {error, invalid_generated_genesis}.

valid_prepared_genesis(
  #entry{index = 1, timestamp = 0,
         data = {batch, [#transaction{author = Author} = Tx]},
         block_bytes = Bytes, cert = none},
  Ns, Self) ->
    is_binary(Bytes) andalso Author =:= Self
        andalso valid_genesis_transaction(Ns, Tx, [Self]);
valid_prepared_genesis(_, _, _) -> false.

entry_block_hash(Entry) ->
    {ok, Block} = block_from_entry(Entry),
    block_hash(Block).

append_genesis(Entry, S = #s{store = Store}) ->
    {ok, Store1} = quod_ledger_store:append(Store, [Entry]),
    S#s{store = Store1}.

%% The genesis transaction compiles caller-provided file/term content exactly once. Runtime creation
%% instead supplies its already-compiled, bounded `genesis_diff`. Generated incarnation/committee facts
%% are compiled separately, then prepended to that initial diff in one linear pass. This preserves the
%% initial diff's clause/order contract without reading or compiling its source again.
%% `consensus_incarnation/1` is therefore ordinary queryable ontology truth as well as part of the anchor.
%% The predicate is reserved to this one generated fact.
%% The founding set is `[]` => self-only (N=1) or a list of founding members; each entry is a bare pubkey
%% or `{Pubkey, Host, Port}`. The lexicographically-smallest pubkey is both the sole permitted creator and
%% the unsigned transaction author. All other founding members start in `mode=join` against its anchor.
genesis_tx(Cfg, Ns, Self, Incarnation) ->
    Founders   = founding(Cfg, Self),
    [{GenesisAuthor, _, _} | _] = Founders,
    InitialDiff = genesis_initial_diff(Cfg),
    Modules = maps:get(external_predicate_modules, Cfg, []),
    Manifest =
        case quod_predicates:module_manifest(Modules) of
            {ok, Value} -> Value;
            {error, Reason} -> throw({genesis_failed, Reason})
        end,
    case quod_diff:touches_functor(
           InitialDiff, {external_predicate_modules, 1}) of
        true -> throw({genesis_failed, reserved_genesis_manifest});
        false -> ok
    end,
    GeneratedTerms =
        lists:foldr(
          fun({Pk, Host, Port}, Acc) ->
                  [{peer_admitted, Pk, Host, Port, Pk} | Acc]
          end, [], Founders),
    %% Every ontology is born able to answer its own host. The bodyless
    %% host-entry default admits a proof entered here with no caller ahead of
    %% it (an empty call chain) — which only ever happens for this node's own
    %% top-level proof, since a scope open always carries its origin. It reads
    %% no committed state, so it cannot hit the not-yet-applied-policy race, and
    %% because founding injects it, an author can never omit it and lock the
    %% host out. Remote and cross-ontology callers (a non-empty chain) match
    %% nothing here and stay fail-closed until author clauses admit them.
    HostEntryPolicy = {can_invoke, {'Goal'}, {'Principal'}, [], {'Namespace'}},
    GeneratedDiff =
        quod_prolog:terms_to_diff(
          [{consensus_incarnation, Incarnation},
           {external_predicate_modules, Manifest}, HostEntryPolicy
           | GeneratedTerms]),
    %% `foldr` is the single list-spine copy needed to prepend generated ops;
    %% InitialDiff itself is retained byte-for-byte and is never repeatedly appended.
    Diff = lists:foldr(fun(Op, Acc) -> [Op | Acc] end,
                       InitialDiff, GeneratedDiff),
    %% Genesis cannot carry its own anchor (the anchor IS the hash of the
    %% block holding this transaction), so its origin anchor is the fixed
    %% zero sentinel and it stays the only unsigned, plan-less transaction.
    Genesis =
        #transaction{tx_id = genesis_tx_id(Ns, Incarnation),
                     origin = {Ns, <<0:256>>},
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

-ifdef(TEST).
test_genesis_tx(Config, Ns, Self, Incarnation) ->
    genesis_tx(maps:merge(?DEFAULTS, Config), Ns, Self, Incarnation).

test_valid_genesis_source(Config) ->
    valid_genesis_source(maps:merge(?DEFAULTS, Config)).

test_valid_config(Config) ->
    Cfg = maps:merge(?DEFAULTS, Config),
    valid_cfg(Config, Cfg).
-endif.

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

-doc "Extract the one immutable external-predicate manifest from genesis.".
-spec genesis_predicate_manifest(term()) ->
          {ok, quod_predicates:module_manifest()} | error.
genesis_predicate_manifest(#transaction{diff = Diff}) ->
    %% Inspect every clause with the reserved head, not only well-formed
    %% assertions.  A malformed or second clause must not hide beside the one
    %% canonical generated fact.
    case [{Action, Manifest, Body}
          || {Action, {{external_predicate_modules, Manifest}, Body}} <- Diff]
    of
        [{assert, Manifest, {[], false}}] ->
            case quod_predicates:valid_manifest_shape(Manifest) of
                true -> {ok, Manifest};
                false -> error
            end;
        _ -> error
    end;
genesis_predicate_manifest(_) -> error.

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

%% One boundary covers decode, dispatch and keep_progress, including autonomous
%% receipt work with no live request context. No protocol turn or OTP action is
%% added. Tracing is independent of the expensive synchronous metric probes.
running(EventType, Content, S = #s{trace_owner_turns = true}) ->
    quod_trace:with_owner_turn(
      #{'quod.namespace' => S#s.ns,
        'quod.owner.event' => atom_to_binary(event_class(EventType, Content)),
        'quod.owner.committed_height_at_entry' => S#s.slot,
        'quod.owner.approved_height_at_entry' => S#s.approved},
      fun() -> running_measured(EventType, Content, S) end);
running(EventType, Content, S) ->
    running_measured(EventType, Content, S).

%% These pre-existing Prometheus probes are independently diagnostic-only: they
%% update histograms synchronously inside the serial process, unlike OTLP export.
running_measured(EventType, Content, S = #s{detailed_metrics = false}) ->
    running_impl(EventType, Content, S);
running_measured(EventType, Content, S) ->
    {message_queue_len, QLen} = process_info(self(), message_queue_len),
    T0 = erlang:monotonic_time(microsecond),
    Result = running_impl(EventType, Content, S),
    quod_metrics:observe_consensus_event(
      S#s.ns, event_class(EventType, Content),
      erlang:monotonic_time(microsecond) - T0, QLen),
    Result.

%% Reuse the named synchronous seams for both diagnostic views: nested owner
%% spans locate a slow turn; aggregate histograms remain independently opt-in.
timed_step(S = #s{trace_owner_turns = true}, Step, Fun) ->
    quod_trace:with_owner_step(Step, fun() -> measured_step(S, Step, Fun) end);
timed_step(S, Step, Fun) ->
    measured_step(S, Step, Fun).

measured_step(#s{detailed_metrics = false}, _Step, Fun) ->
    Fun();
measured_step(#s{ns = Ns}, Step, Fun) ->
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
event_class(_, {link_up, _, _, _, _})          -> link;
event_class(_, {link_error, _, _, _})          -> link;
event_class(_, {link_up, _, _, _})             -> link;
event_class(_, {link_error, _, _})             -> link;
event_class(_, {'DOWN', _, _, _, _})           -> link;
event_class(cast, _)                           -> cast;
event_class(_, _)                              -> other.

running_impl({call, From}, {append, Change, TraceCtx}, S0) ->
    Waiter = new_waiter(From, TraceCtx, Change, S0, false),
    {S1, Reply} = handle_append(
                    Waiter, Change,
                    S0#s{submitted = S0#s.submitted + 1}),
    keep_progress(S0, S1, Reply);
running_impl(internal, restore_signing_engine, S0) ->
    keep_progress(S0, restore_signing_engine(S0), []);
running_impl({call, From}, {handoff_effect, Admission, Change}, S0) ->
    case handoff_effect_change(Admission, Change, S0) of
        {ok, S1} ->
            keep_progress(S0, S1, [{reply, From, ok}]);
        {error, Reason, S1} ->
            {keep_state, S1, [{reply, From, {error, Reason}}]}
    end;
running_impl(
  {call, From},
  {register_transaction_custody, Admission, Change}, S0) ->
    case register_dormant_transaction(
           Admission, Change, element(1, From), S0) of
        {ok, Submission, S1} ->
            keep_progress(S0, S1, [{reply, From, {ok, Submission}}]);
        {error, Reason, S1} ->
            {keep_state, S1, [{reply, From, {error, Reason}}]}
    end;
running_impl(
  {call, From}, {start_transaction_custody_cancellation, TxId}, S0) ->
    case start_dormant_transaction_cancellation(
           TxId, element(1, From), S0) of
        {ok, S1} ->
            {keep_state, S1, [{reply, From, ok}]};
        {error, Reason, S1} ->
            {keep_state, S1, [{reply, From, {error, Reason}}]}
    end;
running_impl(
  {call, From}, {activate_transaction_custody, TxId}, S0) ->
    case activate_dormant_transaction(
           TxId, element(1, From), From, S0) of
        {ok, S1} ->
            keep_progress(S0, S1, []);
        {error, Reason, S1} ->
            {keep_state, S1, [{reply, From, {error, Reason}}]}
    end;
running_impl(
  {call, From}, {cancel_transaction_custody, TxId}, S0) ->
    case cancel_dormant_transaction(TxId, element(1, From), S0) of
        {ok, S1} ->
            {keep_state, S1, [{reply, From, ok}]};
        {error, Reason, S1} ->
            {keep_state, S1, [{reply, From, {error, Reason}}]}
    end;
running_impl(
  {call, From},
  {dtx_endpoint_request, TargetNs, PeerKey, Endpoint, Request, ValidationSidecar,
   TimeoutMs, TraceCtx},
  S0) ->
    case quod_trace:with_context(TraceCtx, fun() ->
             start_dtx_endpoint_request(
               TargetNs, PeerKey, Endpoint, Request, ValidationSidecar, TimeoutMs,
               From, S0)
         end) of
        {ok, S1} ->
            {keep_state, S1};
        {error, Reason} ->
            {keep_state, S0, [{reply, From, {error, Reason}}]}
    end;
running_impl(
  {call, From}, {dtx_endpoint_local, Request, ValidationSidecar, TimeoutMs, TraceCtx}, S0) ->
    case quod_trace:with_context(TraceCtx, fun() ->
             start_local_dtx_endpoint_request(
               Request, ValidationSidecar, TimeoutMs, From, S0)
         end) of
        {ok, S1, Actions} ->
            %% A local submit retains the same semantic DTX record as remote
            %% endpoint ingress. Drive it in this callback instead of leaving
            %% it parked until the periodic consensus re-drive tick.
            keep_progress(S0, S1, Actions);
        {error, Reason} ->
            {keep_state, S0, [{reply, From, {error, Reason}}]}
    end;
running_impl(
  {call, From}, {dtx_local_evidence_source, Ref, ExpectedPhase}, S) ->
    {keep_state, S,
     [{reply, From,
       local_dtx_evidence_source(Ref, ExpectedPhase, S)}]};
running_impl({call, From}, {history_view, Identity, Requirement, Deadline}, S) ->
    {keep_state, S,
     [{reply, From,
       local_history_view(Identity, Requirement, Deadline, S)}]};
running_impl({call, From}, get_dtx_binding, S) ->
    {keep_state, S, [{reply, From, dtx_owner_binding(S)}]};
running_impl({call, From}, get_dtx_ready_binding, S) ->
    {keep_state, S, [{reply, From, current_dtx_binding(S)}]};
running_impl(
  {call, From},
  {register_dtx_vote, EnginePid, IntentId, Material, GroupRef, DeadlineMs,
   TraceCtx}, S0) ->
    case quod_trace:with_context(TraceCtx, fun() ->
             enqueue_dtx_intent(
               From, EnginePid, IntentId, Material, GroupRef, DeadlineMs, S0)
         end) of
        {ok, S1} ->
            keep_progress(S0, S1, [{reply, From, {accepted, IntentId}}]);
        {error, Reason} ->
            {keep_state, S0, [{reply, From, {error, Reason}}]}
    end;
running_impl(
  cast, {activate_dtx_vote, EnginePid, IntentId}, S0) ->
    S1 = activate_dtx_intent(EnginePid, IntentId, S0),
    keep_progress(S0, S1, []);
running_impl(
  cast, {cancel_dtx_vote, EnginePid, IntentId}, S0) ->
    keep_progress(S0, cancel_dtx_intent(EnginePid, IntentId, S0), []);
%% A freshly-(re)started quod_prolog: re-drive committed blocks from the start (async casts, in slot
%% order), then mark it ready ONLY once its kb is caught up — never a prove over a half-built kb.
running_impl(cast, rebuild, S0) ->
    %% Close the lock-free gate before replay work begins.
    SClosed = refresh_proof_gate(
                S0, S0#s{last_applied = 0, prolog_ready = false}),
    %% The journal is the sole durable owner before Vote commits. Seed its
    %% reconciled pending identity into the rebuildable outcome projection
    %% before any replayed ledger entry, preserving FIFO projection order.
    ok = project_pending_votes(
           S0#s.ns, S0#s.signing_journal),
    S1 = apply_committed(SClosed),
    keep_progress(S0, S1, []);
%% Only the current registered Prolog incarnation may acknowledge readiness,
%% and only at the exact committed height it actually consumed.  A stale
%% owner or an acknowledgement overtaken by a newer commit is inert.
running_impl(
  cast, {prolog_ready, PrologPid, Height, Unresolved},
  S0 = #s{ns = Ns, slot = Height, last_applied = Height,
          sync = ready, prolog_ready = false})
  when is_pid(PrologPid), is_integer(Height), Height >= 0,
       is_list(Unresolved) ->
    case quod_reg:where({quod_prolog, Ns}) of
        PrologPid ->
            SProjected = install_operation_snapshot(Unresolved, S0),
            S1 = refresh_proof_gate(
                   S0, wake_operation_recoveries(
                         SProjected#s{prolog_ready = true})),
            keep_progress(S0, S1, []);
        _Other ->
            {keep_state, S0}
    end;
running_impl(cast, {prolog_ready, _PrologPid, _Height, _Unresolved}, S) ->
    {keep_state, S};
running_impl(
  {call, From}, {await_operation_result, WaitRef, OperationRef, Deadline, TraceCtx}, S0)
  when is_reference(WaitRef), is_integer(Deadline) ->
    trace_operation_event(
      TraceCtx, <<"operation.result_wait_received">>, OperationRef, S0#s.ns, #{}),
    case quod_trace:with_context(TraceCtx, fun() ->
             await_operation_recovery(From, WaitRef, OperationRef, Deadline, S0)
         end) of
        {reply, Reply, S1} ->
            trace_operation_event(
              TraceCtx, <<"operation.result_immediate_reply">>,
              OperationRef, S0#s.ns, #{}),
            {keep_state, S1, [{reply, From, Reply}]};
        {wait, S1} ->
            keep_progress(S0, S1, [])
    end;
running_impl(
  cast, {cancel_operation_wait, Caller, WaitRef, OperationRef}, S0) ->
    S1 = cancel_operation_waiter(Caller, WaitRef, OperationRef, S0),
    keep_progress(S0, S1, []);
running_impl(
  cast,
  {operation_projection, Slot, #transaction{} = Change, TraceCtx}, S0) ->
    S1 = quod_trace:with_context(TraceCtx, fun() ->
             apply_operation_projection(Slot, Change, S0)
         end),
    keep_progress(S0, S1, []);
%% Prolog emits this only after the resolved plan's outcome index has been
%% flushed and its MVCC revision published.  Every exact waiter is woken and
%% re-reads that durable state.  Only an exact pending proof fence is mutated;
%% a no-fence or duplicate notification remains state-neutral.
running_impl(
  cast, {resolve_applied, GroupId, Slot, Generation},
  S0 = #s{dtx_projection = Projection0}) ->
    case quod_atomic:acknowledge_resolve(
           GroupId, Slot, Generation, Projection0) of
        {ok, Projection1} ->
            S1 = refresh_proof_gate(
                   S0, S0#s{dtx_projection = Projection1}),
            wake_dtx_applied_workers(
              {GroupId, Slot, Generation}, S1#s.dtx_workers),
            keep_progress(S0, S1, []);
        {error, stale_resolve_ack} ->
            wake_dtx_applied_workers(
              {GroupId, Slot, Generation}, S0#s.dtx_workers),
            {keep_state, S0}
    end;
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
%% DTX recovery uses one bidirectional namespace channel.  Responses are
%% accepted only for an exact peer/request correlation; requests are charged
%% to the authenticated peer before any worker or monitor is allocated.
running_impl(
  info, {quod_message, {{Peer, Addr}, InLink}, DtxChan, Payload},
  S0 = #s{dtx_chan = DtxChan}) ->
    {S1, Actions} = handle_dtx_endpoint_frame(
                      S0#s.ns, serve, {Peer, Addr}, InLink, Payload, S0),
    keep_progress(S0, S1, Actions);
running_impl(
  info, {quod_message, {PeerIdentity, Link}, Channel, Payload}, S0) ->
    case handle_dtx_outbound_message(
           PeerIdentity, Link, Channel, Payload, S0) of
        {handled, S1, Actions} ->
            keep_progress(S0, S1, Actions);
        ignore ->
            {keep_state, S0}
    end;
running_impl(
  info, {dtx_endpoint_worker_result, Pid, Result}, S0) ->
    {S1, Actions} = finish_dtx_server_worker(Pid, Result, S0),
    keep_progress(S0, S1, Actions);
running_impl(info, dtx_drive, S0 = #s{dtx_drive_scheduled = true}) ->
    %% This self-message sits behind every control already in the mailbox.
    %% Clearing the latch before keep_progress lets the one retained owner
    %% select the largest legal wave without sleeping or polling.
    keep_progress(S0, S0#s{dtx_drive_scheduled = false}, []);
running_impl(info, dtx_drive, S) ->
    {keep_state, S};
running_impl(
  info,
  {dtx_coordinator, Pid,
   {operation, _, _, _, _} = OperationRef,
   {claim_state, ClaimState, Slot, Digest, TargetRef}}, S0) ->
    case maps:get(OperationRef, S0#s.operation_recoveries, undefined) of
        Owner = #operation_recovery_owner{pid = Pid, status = running} ->
            Bound = bind_operation_claim(Owner, Slot, Digest, TargetRef),
            Updated = Bound#operation_recovery_owner{
                        claim_state = merge_operation_claim_state(
                                        Bound#operation_recovery_owner.claim_state,
                                        ClaimState)},
            S1 = put_operation_owner(Updated, S0),
            keep_progress(S0, S1, []);
        _ -> {keep_state, S0}
    end;
running_impl(
  info,
  {dtx_coordinator, Pid,
   {operation, _, _, _, _} = OperationRef,
   {target_result, Result, TargetRef}},
  S0) ->
    case finish_operation_target_result(
           Pid, OperationRef, Result, TargetRef, S0) of
        {true, S1} -> keep_progress(S0, S1, []);
        false -> {keep_state, S0}
    end;
running_impl(
  info,
  {dtx_coordinator, Pid,
   {operation, _, _, _, _} = OperationRef, {done, OperationRef}},
  S0) ->
    case settle_operation_recovery(Pid, OperationRef, S0) of
        {true, S1} -> keep_progress(S0, S1, []);
        false -> {keep_state, S0}
    end;
running_impl(
  info,
  {dtx_coordinator, Pid,
   {operation, _, _, _, _} = OperationRef, {error, Reason}},
  S0) ->
    case block_operation_recovery(Pid, OperationRef, Reason, S0) of
        {true, S1} -> keep_progress(S0, S1, []);
        false -> {keep_state, S0}
    end;
running_impl(
  info, {dtx_coordinator, Pid, GroupId, {progress, Phase}},
  S) ->
    case dtx_coordinator_owner(GroupId, S) of
        #dtx_coordinator_owner{pid = Pid} ->
            logger:debug(
              "quod[~s]: DTX group ~p recovery advanced to ~p",
              [S#s.ns, GroupId, Phase]),
            {keep_state, S};
        _ ->
            {keep_state, S}
    end;
running_impl(
  info, {dtx_coordinator, Pid, GroupId, {terminal, Terminal}},
  S) when is_map(Terminal) ->
    case dtx_coordinator_owner(GroupId, S) of
        #dtx_coordinator_owner{pid = Pid} ->
            %% Every participant is already certified applied.  Release the
            %% exact live caller while this coordinator appends Complete.
            ok = quod_prolog:dtx_group_terminal(
                   S#s.ns, committed_group_ref(GroupId, S), Terminal),
            {keep_state, S};
        _ ->
            {keep_state, S}
    end;
running_impl(
  info, {dtx_coordinator, Pid, GroupId, {done, _CompleteRef}},
  S) ->
    case dtx_coordinator_owner(GroupId, S) of
        Owner = #dtx_coordinator_owner{pid = Pid} ->
            dtx_coordinator_event(Owner, <<"dtx.done_observed">>),
            %% Complete is authoritative only through the installed
            %% projection; reconciliation affects this exact GroupId only.
            keep_progress(S, reconcile_dtx_coordinator(S), []);
        _ ->
            {keep_state, S}
    end;
running_impl(
  info, {dtx_coordinator, Pid, GroupId, {error, Reason}},
  S) ->
    case dtx_coordinator_owner(GroupId, S) of
        Owner = #dtx_coordinator_owner{pid = Pid} ->
            %% The fatal path retains this row for terminate/3 to release.
            %% Never export the reason or end a still-owned handle here.
            dtx_coordinator_event(Owner, <<"dtx.worker_error">>),
            %% Temporary reachability and history gaps remain parked inside
            %% the message-driven coordinator.  Reaching this event therefore
            %% means its certified state is internally inconsistent; silently
            %% restarting the same state would only hide the defect in a
            %% timer-driven crash loop.
            error({dtx_coordinator_failed, S#s.ns, GroupId, Reason});
        _ ->
            {keep_state, S}
    end;
running_impl(info, {dtx_coordinator, _Pid, _GroupId, _Event}, S) ->
    {keep_state, S};
running_impl(
  info, {dtx_endpoint_timeout, RequestId, TimeoutTag}, S0) ->
    {S1, Actions} = timeout_dtx_correlation(
                      RequestId, TimeoutTag, S0),
    keep_progress(S0, S1, Actions);
running_impl(info, {link_up, OpenRef, Peer, Channel, LinkPid}, S0) ->
    case dtx_correlation_link_up(
           OpenRef, Peer, Channel, LinkPid, S0) of
        {handled, S1, Actions} -> keep_progress(S0, S1, Actions);
        ignore -> {keep_state, S0}
    end;
running_impl(info, {link_error, OpenRef, Peer, Channel}, S0) ->
    case dtx_correlation_link_error(OpenRef, Peer, Channel, S0) of
        {handled, S1, Actions} -> keep_progress(S0, S1, Actions);
        ignore -> {keep_state, S0}
    end;
%% A membership verdict from our own quod_prolog (a plain message from `deliver_verdict`): emit or withhold
%% the deferred support share. The tag echoes the `{Slot, BlockHash}` we requested with, so the verdict binds
%% to the exact block. Support can advance/skip the head, so reflect that in the Δ timer.
running_impl(info, {content_verdict, {Sl, BH}, Verdict}, S0) ->
    S1 = on_content_verdict(Sl, BH, Verdict, S0),
    keep_progress(S0, S1, []);
running_impl(info, {projection_advanced, Engine, Parent, Changes}, S0) ->
    case on_admission_parent_applied(Engine, {Parent, Changes}, S0) of
        S0 -> {keep_state, S0};
        S1 -> keep_progress(S0, S1, [])
    end;
running_impl(
  info,
  {dtx_verdict, {dtx_admission, Tag, Key, Timestamp}, EnginePid, AppliedFloor, Verdict},
  S0) ->
    S1 = on_admission_verdict(Tag, Key, Timestamp, EnginePid, AppliedFloor, Verdict, S0),
    keep_progress(S0, S1, []);
running_impl(
  info,
  {dtx_verdict, {Sl, BH, ParentToken}, EnginePid, AppliedFloor, Verdict},
  S0) ->
    S1 = on_dtx_verdict(
           Sl, BH, ParentToken, EnginePid, AppliedFloor, Verdict, S0),
    keep_progress(S0, S1, []);
running_impl(
  info,
  {content_foreign_verdict, {Sl, BH}, WorkerPid, Deadline, Verdict}, S0) ->
    S1 = on_content_foreign_verdict(
           Sl, BH, WorkerPid, Deadline, Verdict, S0),
    keep_progress(S0, S1, []);
running_impl(
  info,
  {dtx_foreign_verdict, {Sl, BH, ParentToken}, WorkerPid, Deadline, Verdict}, S0) ->
    S1 = on_dtx_foreign_verdict(
           Sl, BH, ParentToken, WorkerPid, Deadline, Verdict, S0),
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
running_impl(info, {'DOWN', Ref, process, Pid, Reason}, S0) ->
    case restart_dormant_custody_owner(Ref, Pid, S0) of
        {true, S1} ->
            keep_progress(S0, S1, []);
        false ->
            case drop_operation_recovery_owner(Ref, Pid, Reason, S0) of
                {true, S1} ->
                    keep_progress(S0, S1, []);
                false ->
                    case drop_operation_waiter(Ref, Pid, S0) of
                        {true, S1} ->
                            keep_progress(S0, S1, []);
                        false ->
                            case drop_dtx_coordinator_owner(
                                   Ref, Pid, Reason, S0) of
                                {true, S1} ->
                                    keep_progress(S0, S1, []);
                                false ->
                                    case drop_dtx_endpoint_owner(
                                           Ref, Pid, worker_down, S0) of
                                        {true, S1, Actions} ->
                                            keep_progress(S0, S1, Actions);
                                        false ->
                                            case drop_dtx_admission_monitor(
                                                   Ref, Pid, S0) of
                                                {true, S1} ->
                                                    keep_progress(
                                                      S0, S1, []);
                                                false ->
                                                    case drop_dtx_validation_monitor(
                                                           Ref, Pid, S0) of
                                                        {true, S1} ->
                                                            keep_progress(
                                                              S0, S1, []);
                                                        false ->
                                                            keep_progress(
                                                              S0,
                                                              drop_link(Pid, S0), [])
                                                    end
                                            end
                                    end
                            end
                    end
            end
    end;
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
%% Consensus recovery: sweep any dial that resolved to neither link_up nor link_error (presumed lost),
%% re-dial every peer whose link never came up (its frames are still buffered), expire final caller
%% deadlines, and spend failure backoff. The common owner reconciliation arms
%% recovery from authenticated finality immediately, not after tick hysteresis.
running_impl({timeout, tick}, tick, S0) ->
    S1 = pace_tick(
           reconcile_relays(redrive_inflight(redial_pending(
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
    %% The owner requests closure on the same FIFO cast channel as every
    %% preceding replay apply, even when Prolog was already acknowledged.
    %% Only Prolog supplies the interval ID/floor. Initial proof readiness
    %% still requires its unchanged pid- and height-bound acknowledgement.
    keep_progress(S0, S2, [], normal, replay_complete);
%% Any incomplete round returns to the single `unconfirmed` state. Partial windows stay durable and the
%% next worker resumes from the resulting height, but no signing capability survives the failure.
running_impl(cast, {sync_done, Pid, _Result}, S0 = #s{sync = {pulling, Pid}}) ->
    keep_progress(S0, recovery_failed(S0), []);
%% A superseded in-flight worker may still deliver its final cast after recovery
%% ownership moved. The pid-bound clauses above are the only ones allowed to
%% change state; this stale completion is deliberately ignored.
running_impl(cast, {sync_done, _Pid, _}, S) -> {keep_state, S};
%% The sync worker — and, for an observer, the feed's anti-entropy pull — hands each verified, contiguous
%% window here to persist + replay in slot order. The caller presents an explicit source capability:
%% `{recovery,Pid}` must match the one monitored recovery owner; `feed` is accepted only by a settled
%% observer. This keeps the sole-writer rule local and makes a promotion crossing deterministic.
running_impl({call, From}, {sink_catchup, Source, Es, Projection, Delta}, S0) ->
    case may_sink(Source, S0) of
        %% `reseat_engine` discards the obsolete volatile round and its head watchdog. The common
        %% transition helper cancels the named timer before the recovered member can vote again.
        true  -> {S1, Reply} = apply_catchup_window(
                                Source, Es, Projection, Delta, S0),
                 %% Return the same writer-turn view with the sink acknowledgement.
                 %% The next window borrows this installed index, without
                 %% recapturing or reopening the ledger path.
                 Result = case Reply of
                              ok -> {ok, local_history_view(S1)};
                              {error, _} = Error -> Error
                          end,
                 keep_progress(S0, S1, [{reply, From, Result}]);
        false -> {keep_state, S0, [{reply, From, {error, not_following}}]}
    end;
%% The feed puller closes its whole multi-window replay through this process. All apply casts
%% above and this ready cast therefore have one sender and preserve mailbox order at Prolog.
running_impl({call, From}, finish_feed_replay, S = #s{sync = ready}) ->
    case is_participant(S) of
        false -> S1 = maybe_mark_ready(S),
                 {keep_state, S1, [{reply, From, ok}]};
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
  #s{ns = Ns, chan = Chan, relay_chan = RelayChan, dtx_chan = DtxChan,
     store = Store, signing_journal = Journal, phase_index = PhaseIndex,
     dtx_correlations = DtxCorrelations,
     dtx_out_channels = DtxOutChannels,
     dtx_workers = DtxWorkers,
     dtx_coordinators = DtxCoordinators,
     operation_recoveries = OperationRecoveries,
     conns = Conns, inbound_conns = Inbound,
     relay_conns = RelayConns,
     relay_inbound_conns = RelayInbound,
     retired_inbound = RetiredInbound}) ->
    %% Custody and accepted inbound relay state share this process incarnation.
    %% Tear down every tracked stream before either can disappear, forcing peers
    %% to reconnect and replay their retained prefixes in author order.
    close_link_maps(
      Conns, Inbound, RelayConns, RelayInbound, RetiredInbound),
    _ = catch quod_reg:unsubscribe({quod_prolog, Ns}),
    _ = case Chan of undefined -> ok; _ -> catch quod_reg:unsubscribe({channel, Chan}) end,
    _ = case RelayChan of
            undefined -> ok;
            _ -> catch quod_reg:unsubscribe({channel, RelayChan})
        end,
    _ = case DtxChan of
            undefined -> ok;
            _ -> catch quod_reg:unsubscribe({channel, DtxChan})
        end,
    maps:foreach(
      fun(Channel, {_TargetNs, _Count}) ->
              _ = catch quod_reg:unsubscribe({channel, Channel}),
              ok
      end, DtxOutChannels),
    close_dtx_endpoint(DtxCorrelations, DtxWorkers),
    maps:foreach(
      fun(_GroupId, Owner) ->
              Released = close_dtx_coordinator_span(
                           Owner, <<"owner_terminating">>, #{}),
              stop_dtx_coordinator_process(Released)
      end,
      DtxCoordinators),
    %% Operation workers already monitor this owner. Preserve that shutdown
    %% behavior; release only the handles in the installed owner snapshot.
    maps:foreach(fun(_Ref, Owner) ->
        _ = close_operation_span(Owner, <<"owner_terminating">>, #{}), ok
    end, OperationRecoveries),
    _ = case Store of
            undefined -> ok;
            _         -> try quod_ledger_store:close(Store) catch _:_ -> ok end
        end,
    _ = case PhaseIndex of
            undefined -> ok;
            _ -> catch quod_dtx_phase_index:close(PhaseIndex)
        end,
    _ = close_signing_journal(Journal),
    ok.

-ifdef(TEST).
close_signing_journal(undefined) ->
    ok;
close_signing_journal(memory) ->
    ok;
close_signing_journal(Journal) ->
    close_signing_journal_handle(Journal).
-else.
close_signing_journal(undefined) ->
    ok;
close_signing_journal(Journal) ->
    close_signing_journal_handle(Journal).
-endif.
close_signing_journal_handle(Journal) ->
    try quod_signing_journal:close(Journal) catch _:_ -> ok end.

%%%===================================================================
%%% durable distributed-control ownership
%%%===================================================================

current_dtx_binding(#s{sync = ready} = S) ->
    dtx_owner_binding(S);
current_dtx_binding(#s{ns = Ns}) ->
    {error, {ontology_unavailable, Ns}}.

%% Membership/admission owns recovery; readiness only grants execution.
%% Source reservation and recovery presentation use this binding during catch-up.
%% The existing FIFO owns the wait; signing stays execution-ready and deadline-bound.
dtx_owner_binding(
  #s{ns = Ns, genesis_hash = Anchor, self = Self,
     author_admissions = Admissions,
     dtx_projection = Projection} = S) ->
    quod_dtx_owner:binding(Ns, Anchor, Self, Admissions, is_participant(S), Projection).

enqueue_dtx_intent(_From, EnginePid, IntentId, Material, GroupRef, DeadlineMs, S0) ->
    case {quod_reg:where({quod_prolog, S0#s.ns}) =:= EnginePid,
          vote_admission_binding(Material, S0), DeadlineMs > quod_time:mono_ms(),
          quod_atomic:source_group_ref(Material)} of
        {true, ok, true, {ok, GroupRef}} ->
            Admission = admission_state(S0),
            PriorRows = admission_rows_for(EnginePid, Admission),
            case {maps:is_key(element(6, GroupRef), pending_votes_snapshot(S0#s.signing_journal)),
                  quod_atomic_admission:reserve(
                   EnginePid, IntentId, Material, quod_trace:context(),
                   PriorRows)} of
                {false, {ok, Rows}} ->
                    %% Responsibility is synced before Prolog may bind even
                    %% the first private effect. Missing material is not a
                    %% prepared vote; restart can only obtain certified refusal.
                    {ok, Journal} = quod_signing_journal:record_dtx_intent(
                        S0#s.signing_journal, quod_atomic:source_presentation(Material)),
                    %% Install a monitor only after pure admission succeeds,
                    %% and pin the checked engine, not a second registry read.
                    S = set_dtx_admission_engine(EnginePid, S0#s{signing_journal = Journal}),
                    Owned = admission_state(S),
                    project_pending_votes(S#s.ns, Journal),
                    {ok, S#s{dtx_admission = Owned#dtx_admission{waiting = Rows}}};
                {false, {error, busy}} -> {error, busy};
                _ -> {error, invalid_dtx_intent}
            end;
        {false, _, _, _} -> {error, stale_engine};
        {_, _, false, _} -> {error, {proof_limit_exceeded, S0#s.ns}};
        _ -> {error, invalid_dtx_intent}
    end.

admission_state(#s{dtx_admission = none}) ->
    #dtx_admission{waiting = quod_atomic_admission:new()};
admission_state(#s{dtx_admission = A}) -> A.

refresh_dtx_admission_engine(S = #s{ns = Ns}) ->
    Engine = case quod_reg:where({quod_prolog, Ns}) of undefined -> none; P -> P end,
    set_dtx_admission_engine(Engine, S).

admission_rows_for(Engine, #dtx_admission{engine = Engine, waiting = Rows}) -> Rows;
admission_rows_for(_, #dtx_admission{engine = Old, waiting = Rows}) ->
    quod_atomic_admission:engine_lost(Old, Rows).

set_dtx_admission_engine(Engine, S) ->
    A = admission_state(S),
    case A#dtx_admission.engine =:= Engine of
        true -> S;
        false ->
            demonitor_if_set(A#dtx_admission.monitor),
            Rows = admission_rows_for(Engine, A),
            Monitor = case Engine of none -> none; _ -> erlang:monitor(process, Engine) end,
            S#s{dtx_admission = #dtx_admission{engine = Engine, monitor = Monitor, waiting = Rows}}
    end.

vote_admission_binding({{quod_dtx_vote, 4, _, Target, _, _}, _, _}, S) ->
    case dtx_owner_binding(S) of
        {ok, {Ns, Anchor, _, _}} when Target =:= {Ns, Anchor} -> ok;
        _ -> error
    end;
vote_admission_binding(_, _) -> error.

%% Inbound own material and compact presentations join the same FIFO. They
%% already crossed the endpoint's sole authenticated decode boundary.
admit_owned_vote(Material = {Record, _, _}, Waiter, S0) ->
    case vote_admission_binding(Material, S0) of
        ok ->
            Id = quod_atomic:group_id(Record),
            Owned = [Digest || #dtx_submission{group_id = Group, digest = Digest, control = C}
                                  <- maps:values(quod_dtx_owner:rows(S0#s.retained_dtx)),
                               Group =:= Id, quod_atomic:control_kind(C) =:= vote,
                               maps:get(author, quod_atomic:control_metadata(C)) =:= S0#s.self],
            case Owned of
                [Digest] ->
                    %% Accepted work already crossed into journal custody.
                    %% A repeated presentation cannot create a second FIFO row
                    %% or replace that body's intent with missing material.
                    {ok, Registry} = quod_dtx_owner:attach_waiter(Digest, Waiter, S0#s.retained_dtx),
                    {ok, schedule_dtx_drive(S0#s{retained_dtx = Registry})};
                [] ->
                    Prior = admission_state(S0),
                    %% A duplicate cannot replace durable missing/bound
                    %% preparation permission with peer-supplied own material.
                    Pending = pending_votes_snapshot(S0#s.signing_journal),
                    Chosen = case maps:find(Id, Pending) of
                        {ok, #{material := Saved}} -> Saved;
                        error -> Material
                    end,
                    case maps:is_key(Id, Pending) orelse
                         quod_atomic_admission:has_capacity(Id, Prior#dtx_admission.waiting) of
                        false -> {error, busy};
                        true ->
                            %% Rejected admissions install no monitor or other
                            %% side effect which their unchanged state would lose.
                            S = refresh_dtx_admission_engine(S0), A = admission_state(S),
                            Rows = quod_atomic_admission:admit(
                                     Chosen, Waiter, quod_trace:context(), A#dtx_admission.waiting),
                            {ok, schedule_dtx_drive(S#s{dtx_admission = A#dtx_admission{waiting = Rows}})}
                    end
            end;
        error -> {error, invalid_dtx_submission}
    end.

progress_dtx_admission(S = #s{dtx_admission = none}, Actions) -> {S, Actions};
progress_dtx_admission(S0, Actions) ->
    S = refresh_dtx_admission_engine(S0),
    A = admission_state(S),
    case {endpoint_write_ready(S), A#dtx_admission.engine, S#s.history_head} of
        {true, Engine, {Slot, <<_:256>>} = Parent} when is_pid(Engine), Slot =:= S#s.slot ->
            Timestamp = vote_timestamp(S),
            Key = {Engine, Parent},
            {Requests, Rows} = quod_atomic_admission:next(Key, Timestamp, A#dtx_admission.waiting),
            S1 = lists:foldl(fun({Id, Tag, Material, Trace}, Acc) ->
                case retention_disposition(Material, Acc) of
                    {included, Ref} -> finish_indexed_vote(Id, {ok, Ref, []}, Acc);
                    stale -> finish_indexed_vote(Id, {error, stale_dtx_submission}, Acc);
                    _ when Tag =:= selected -> drain_selected_vote(Id, Acc);
                    _ ->
                        ok = quod_trace:with_context(Trace, fun() ->
                            quod_prolog:request_dtx_verdict(
                              Acc#s.ns, {vote, Material}, Timestamp, Slot + 1,
                              self(), {dtx_admission, Tag, Key, Timestamp})
                        end),
                        Acc
                end
            end, S#s{dtx_admission = A#dtx_admission{waiting = Rows}}, Requests),
            {compact_dtx_admission(S1), Actions};
        _ -> {compact_dtx_admission(S), Actions}
    end.

on_admission_parent_applied(Engine, {Parent, Changes},
  S = #s{ns = Ns, dtx_admission = A = #dtx_admission{engine = Engine}}) ->
    case Engine =:= quod_reg:where({quod_prolog, Ns}) of
        true ->
            Rows = quod_atomic_admission:parent_applied(
                     {Engine, Parent}, Changes, A#dtx_admission.waiting),
            S#s{dtx_admission = A#dtx_admission{waiting = Rows}};
        false -> S
    end;
on_admission_parent_applied(_, _, S) -> S.

finish_indexed_vote(Id, Reply, S = #s{dtx_admission = A}) ->
    {#{waiters := Waiters}, Rows} = quod_atomic_admission:take(Id, A#dtx_admission.waiting),
    reply_waiters([{dtx_endpoint, P} || P <- Waiters], Reply,
                  S#s{dtx_admission = A#dtx_admission{waiting = Rows}}).

on_admission_verdict(Tag, Key = {Engine, Parent}, Timestamp, Engine, Floor, Reply,
                     S = #s{history_head = Parent, dtx_admission = A})
  when is_record(A, dtx_admission), A#dtx_admission.engine =:= Engine,
       (Floor =:= S#s.slot orelse (Reply =:= abstain andalso Floor < S#s.slot)) ->
    {Result, Basis} = case Reply of
        {selection, Verdict, Observations} -> {Verdict, Observations};
        _ -> {Reply, #{parent => true}}
    end,
    Current = quod_reg:where({quod_prolog, S#s.ns}),
    SameRegion = case Result of
        {vote, {_, _, #{group := #{vote_deadline_ms := Deadline}}}} ->
            (Timestamp > Deadline) =:= (vote_timestamp(S) > Deadline);
        _ -> true
    end,
    case Current =:= Engine andalso SameRegion of
        false -> S;
        true ->
            %% The existing verdict floor names the missing dependency. A
            %% policy abstention at the published parent is not an apply wait.
            Readiness = case Result =:= abstain andalso Floor < S#s.slot of
                true -> await_parent;
                false -> Result
            end,
            case quod_atomic_admission:verdict(Tag, Key, {Readiness, Basis}, A#dtx_admission.waiting) of
                {selected, _Row, Rows} ->
                    %% A readiness pause does not discard verified work. The
                    %% normal admission drive consumes this cached verdict
                    %% only while its parent/deadline binding still matches.
                    S#s{dtx_admission = A#dtx_admission{waiting = Rows}};
                {waiting, Rows} -> S#s{dtx_admission = A#dtx_admission{waiting = Rows}};
                stale -> S
            end
    end;
on_admission_verdict(_, _, _, _, _, _, S) -> S.

drain_selected_vote(Id, S = #s{dtx_admission = A}) ->
    {Row, Rows} = quod_atomic_admission:take(Id, A#dtx_admission.waiting),
    %% Build the post-transfer state before the signing effect. A returned
    %% availability error retains the selected row, not another validation.
    Removed = S#s{dtx_admission = A#dtx_admission{waiting = Rows}},
    case retain_selected_vote(Row, Removed) of
        {ok, Next} -> Next;
        {error, _} -> S
    end.

retain_selected_vote(#{material := Material = {_, Digest, _}, retained := Previous,
                       selection := Selection, waiters := Waiters, trace_ctx := Trace}, S) ->
    quod_trace:with_context(Trace, fun() ->
        case retention_disposition(Material, S) of
            {included, Ref} ->
                {ok, reply_waiters([{dtx_endpoint, P} || P <- Waiters], {ok, Ref, []}, S)};
            _ ->
                case retain_selected_envelope(Material, Previous, S) of
                    {ok, Next} ->
                        Row = maps:get(Digest, quod_dtx_owner:rows(Next#s.retained_dtx)),
                        %% Reselection is the same accepted work, including
                        %% its FIFO age and observation interval.
                        Timed = case Previous of
                            none -> Row;
                            #dtx_submission{inserted_at = At, observation_started_at = Started} ->
                                Row#dtx_submission{inserted_at = At, observation_started_at = Started}
                        end,
                        Selected = quod_dtx_owner:replace(Timed#dtx_submission{selection = Selection},
                                                         Next#s.retained_dtx),
                        Registry = lists:foldl(fun(Pid, Acc) ->
                            {ok, R} = quod_dtx_owner:attach_waiter(Digest, {dtx_endpoint, Pid}, Acc), R
                        end, Selected, Waiters),
                        {ok, Next#s{retained_dtx = Registry}};
                    {error, _} = Error -> Error
                end
        end
    end).

retain_selected_envelope(Material, #dtx_submission{control = Control} = Previous, S) ->
    #{author := Author, author_admission := Admission, sequence := Seq} =
        quod_atomic:control_metadata(Control),
    case quod_atomic:control_material(Control) =:= Material andalso
         maps:get(Author, S#s.author_admissions, none) =:= Admission andalso
         Seq > maps:get({Admission, Author}, S#s.dtx_lanes, 0) of
        true ->
            %% Another author may have relayed this semantic vote while local
            %% selection waited. Rejoin the shared retention boundary.
            retain_dtx_submission(Material, none, Previous#dtx_submission.validation_sidecar,
                {signed, Control, Previous#dtx_submission.envelope}, S);
        false -> retain_dtx_submission(Material, none, [], sign, S)
    end;
retain_selected_envelope(Material, none, S) ->
    retain_dtx_submission(Material, none, [], sign, S).

activate_dtx_intent(Engine, Token, S = #s{dtx_admission = A}) when is_record(A, dtx_admission) ->
    case quod_atomic_admission:activate(Engine, Token, A#dtx_admission.waiting) of
        {none, _} -> S;
        {{Vote, _, _} = Material, Rows} ->
            case maps:find(quod_atomic:group_id(Vote), pending_votes_snapshot(S#s.signing_journal)) of
                {ok, #{sequence := 0}} ->
                    %% This callback follows all successful private binds.
                    %% Sync readiness before installing the executable row.
                    {ok, Journal} = quod_signing_journal:record_dtx_intent(S#s.signing_journal, Material),
                    S#s{signing_journal = Journal, dtx_admission = A#dtx_admission{waiting = Rows}};
                _ ->
                    %% History may already have closed the group. A late
                    %% activation cannot recreate custody or preparation.
                    cancel_dtx_intent(Engine, Token, S)
            end
    end;
activate_dtx_intent(_, _, S) -> S.

cancel_dtx_intent(Engine, Token, S = #s{dtx_admission = A}) when is_record(A, dtx_admission) ->
    compact_dtx_admission(S#s{dtx_admission = A#dtx_admission{
      waiting = quod_atomic_admission:cancel(Engine, Token, A#dtx_admission.waiting)}});
cancel_dtx_intent(_, _, S) -> S.

compact_dtx_admission(S = #s{dtx_admission = #dtx_admission{waiting = Waiting, monitor = Monitor}}) ->
    case Waiting =:= quod_atomic_admission:new() andalso
         not lists:any(fun(Row) -> local_owned_vote(Row, S) end,
                       maps:values(quod_dtx_owner:rows(S#s.retained_dtx))) of
        true -> demonitor_if_set(Monitor), S#s{dtx_admission = none};
        false -> S
    end;
compact_dtx_admission(S) -> S.

%% Only the installed membership transition calls this. Readiness pauses and
%% Prolog restarts retain accepted work. The journal is reconciled separately
%% at the existing post-ledger boundary; releasing a row cannot invent abort.
retire_dtx_admission(S = #s{dtx_admission = none}) -> S;
retire_dtx_admission(S = #s{dtx_admission = A}) ->
    Rows = quod_atomic_admission:take_all(A#dtx_admission.waiting),
    Cleared = compact_dtx_admission(S#s{dtx_admission = A#dtx_admission{waiting = quod_atomic_admission:new()}}),
    lists:foldl(fun(#{waiters := Waiters, retained := Retained}, Acc) ->
        Reply = {error, not_in_charge},
        case Retained of
            none -> reply_waiters([{dtx_endpoint, P} || P <- Waiters], Reply, Acc);
            #dtx_submission{} ->
                {Next, none} = finish_detached_retained_dtx(
                    Retained#dtx_submission{waiters = maps:from_keys(Waiters, true)},
                    unavailable, Reply, Acc),
                Next
        end
    end, Cleared, Rows).

drop_dtx_admission_monitor(Ref, Engine,
  S = #s{dtx_admission = #dtx_admission{engine = Engine, monitor = Ref} = A}) ->
    Rows = quod_atomic_admission:engine_lost(Engine, A#dtx_admission.waiting),
    {true, compact_dtx_admission(S#s{dtx_admission = #dtx_admission{waiting = Rows}})};
drop_dtx_admission_monitor(_, _, _) -> false.

apply_operation_projection(
  Slot,
  #transaction{tx_id = ClaimTxId,
               role = {remote_claim, _Manifest, _Bundles, _Predicted}} = Claim,
  S = #s{ns = Ns, operation_recoveries = Recoveries}) ->
    case quod_transaction:request_claim(Claim) of
        {ok, #{operation_ref := OperationRef,
               digest := <<_:256>> = Digest}} ->
            {ok, TargetRefs} = quod_transaction:remote_claim_references(Claim),
            Owner = maps:get(
                      OperationRef, Recoveries,
                      #operation_recovery_owner{operation_ref = OperationRef,
                                                trace_ctx = quod_trace:context()}),
            Bound = bind_operation_claim(Owner, Slot, Digest, TargetRefs),
            case Bound#operation_recovery_owner.claim_tx_id of
                Old when Old =:= none; Old =:= ClaimTxId -> ok;
                _ -> error({operation_recovery_conflict, Ns, OperationRef})
            end,
            Projected = Bound#operation_recovery_owner{
                          claim_tx_id = ClaimTxId,
                          claim_state = merge_operation_claim_state(
                                          Bound#operation_recovery_owner.claim_state,
                                          unresolved)},
            put_operation_owner(wake_operation_owner(Projected, S), S);
        _ ->
            error({invalid_operation_projection, Ns, Slot})
    end;
apply_operation_projection(
  _Slot,
  #transaction{role = {remote_complete, OperationRef, Digest, Receipt}},
  S = #s{operation_recoveries = Recoveries}) ->
    case maps:get(OperationRef, Recoveries, undefined) of
        Owner = #operation_recovery_owner{claim_slot = Slot} ->
            {ok, TargetRefs} = quod_operation_vector:receipt_references(Receipt),
            Bound = bind_operation_claim(Owner, Slot, Digest, TargetRefs),
            %% A different validator may append the receipt before this
            %% replica's worker finishes. Keep result custody for its callers.
            Completed = Bound#operation_recovery_owner{claim_state = terminal},
            put_operation_owner(wake_operation_owner(Completed, S), S);
        undefined ->
            S
    end;
apply_operation_projection(_Slot, #transaction{}, S) ->
    S.

await_operation_recovery(
  From, WaitRef, OperationRef, Deadline, S) ->
    case quod_time:mono_ms() < Deadline of
        true -> await_live_operation(From, WaitRef, OperationRef, Deadline, S);
        false -> {reply, {error, {outcome_unknown, OperationRef}}, S}
    end.

await_live_operation(
  From, WaitRef, OperationRef, Deadline,
  S = #s{operation_recoveries = Recoveries}) ->
    case maps:get(OperationRef, Recoveries, undefined) of
        Owner = #operation_recovery_owner{} ->
            case operation_client_result(Owner) of
                pending -> park_operation_waiter(From, WaitRef, OperationRef, Deadline, Owner, S);
                Result -> {reply, Result, S}
            end;
        undefined ->
            %% The claim may be ahead of local apply OR already completed.
            %% The same worker reads the outcome index to distinguish them;
            %% a late caller never waits for an already-consumed event.
            Owner = #operation_recovery_owner{
                       operation_ref = OperationRef,
                       trace_ctx = quod_trace:context()},
            park_operation_waiter(From, WaitRef, OperationRef, Deadline, Owner, S)
    end.

%% Correlation only: never log principal bytes, payloads or failure terms.
%% These events use the existing owner/request context, not another waiter map.
trace_operation_event(Ctx, Name, {operation, _, <<_:256>>, _, <<_:256>> = Id},
                      Ns, Attributes) ->
    quod_trace:add_event(
      Ctx, Name, Attributes#{'quod.namespace' => Ns,
                            'quod.operation.id' => quod_trace:tx_id(Id)});
trace_operation_event(_Ctx, _Name, _Ref, _Ns, _Attributes) -> ok.

park_operation_waiter(
  From = {Caller, _Tag}, WaitRef, OperationRef, Deadline,
  Owner = #operation_recovery_owner{waiters = Waiters},
  S = #s{operation_recoveries = Recoveries}) ->
    Monitor = erlang:monitor(process, Caller),
    {wait,
     S#s{operation_recoveries = Recoveries#{
           OperationRef => Owner#operation_recovery_owner{
             waiters = Waiters#{Monitor => {From, WaitRef, Deadline}}}}}}.

cancel_operation_waiter(
  Caller, WaitRef, OperationRef,
  S = #s{operation_recoveries = Recoveries}) ->
    case maps:get(OperationRef, Recoveries, undefined) of
        Owner = #operation_recovery_owner{waiters = Waiters} ->
            Remaining = maps:filter(
              fun(Monitor, {{Pid, _Tag}, Ref, _Deadline})
                    when Pid =:= Caller, Ref =:= WaitRef ->
                      _ = erlang:demonitor(Monitor, [flush]),
                      false;
                 (_Monitor, _Waiter) -> true
              end, Waiters),
            put_operation_owner(Owner#operation_recovery_owner{waiters = Remaining}, S);
        undefined -> S
    end.

finish_operation_target_result(
  Pid, OperationRef, Result0, TargetRef,
  S = #s{operation_recoveries = Recoveries}) ->
    Result = operation_target_result(Result0, TargetRef),
    case maps:get(OperationRef, Recoveries, undefined) of
        Owner = #operation_recovery_owner{
                  status = Status, pid = Pid,
                  target_refs = TargetRefs, target_results = Results,
                  waiters = Waiters}
          when Result =/= error,
               (Status =:= running orelse Status =:= settling) ->
            case is_list(TargetRefs) andalso lists:member(TargetRef, TargetRefs) of
                false -> false;
                true ->
                    Target = quod_operation_vector:target(TargetRef),
                    case maps:find(Target, Results) of
                        {ok, Result} -> {true, S};
                        {ok, _Conflict} -> false;
                        error when Status =:= running ->
                            Bound = Owner#operation_recovery_owner{
                                      target_results = Results#{Target => Result}},
                            case operation_client_result(Bound) of
                                pending -> {true, put_operation_owner(Bound, S)};
                                Reply -> finish_operation_result_delivery(
                                           Bound, Reply, Waiters, OperationRef, S)
                            end;
                        error -> false
                    end
            end;
        _ ->
            false
    end.

finish_operation_result_delivery(Owner, Result, Waiters, OperationRef, S) ->
            %% The captured claim span may already have ended. Export this
            %% synchronous delivery independently, before receipt retirement;
            %% events on the captured span alone could silently disappear.
            quod_trace:with_optional_span(
              Owner#operation_recovery_owner.trace_ctx,
              <<"quod.operation.result_delivery">>, internal,
              #{'quod.namespace' => S#s.ns, 'quod.waiter.count' => map_size(Waiters)},
              fun() ->
                  trace_operation_event(
                    quod_trace:context(), <<"operation.target_result_accepted">>,
                    OperationRef, S#s.ns, #{'quod.waiter.count' => map_size(Waiters)}),
                  trace_operation_event(
                    quod_trace:context(), <<"operation.result_reply_ready">>,
                    OperationRef, S#s.ns, #{}),
                  reply_operation_waiters(Waiters, Result, OperationRef)
              end),
            {true, put_operation_owner(
                     Owner#operation_recovery_owner{
                       waiters = #{}}, S)}.

%% Canonical order comes only from the bound claim, never arrival order.
%% This is volatile verified-result bookkeeping, not receipt evidence: an
%% included receipt row cannot manufacture one of these verdicts.
%% The owner always returns a vector. Scalar presentation belongs at the
%% public proof API, never in recovery or completion bookkeeping.
operation_client_result(#operation_recovery_owner{target_refs = none}) -> pending;
operation_client_result(#operation_recovery_owner{target_refs = Refs, target_results = Results}) ->
    case quod_operation_vector:results(Refs, Results) of
        {ok, Rows} -> {operation_results, Rows};
        pending -> pending
    end.

operation_target_result(committed, TargetRef) ->
    {committed, TargetRef};
operation_target_result({rejected, Reason}, TargetRef) when is_atom(Reason) ->
    {{rejected, Reason}, TargetRef};
operation_target_result(_Result, _TargetRef) ->
    error.

reply_operation_waiters(Waiters, Reply, OperationRef) ->
    maps:foreach(
      fun(Monitor, {From, _WaitRef, Deadline}) ->
          _ = erlang:demonitor(Monitor, [flush]),
          Published = case quod_time:mono_ms() < Deadline of
              true -> Reply;
              false -> {error, {outcome_unknown, OperationRef}}
          end,
          gen_statem:reply(From, Published)
      end, Waiters).

drop_operation_waiter(
  Monitor, Pid, S = #s{operation_recoveries = Recoveries}) ->
    {Found, Recoveries1} = maps:fold(
      fun(OperationRef,
          Owner = #operation_recovery_owner{waiters = Waiters},
          {Found0, Acc}) ->
          case maps:get(Monitor, Waiters, undefined) of
              {{Pid, _Tag}, _WaitRef, _Deadline} ->
                  Remaining = maps:remove(Monitor, Waiters),
                  Updated = Owner#operation_recovery_owner{waiters = Remaining},
                  case operation_owner_needed(Updated) of
                      false ->
                          stop_operation_recovery_process(Updated),
                          {true, Acc};
                      true ->
                          {true, Acc#{OperationRef => Updated}}
                  end;
              _ ->
                  {Found0, Acc#{OperationRef => Owner}}
          end
      end, {false, #{}}, Recoveries),
    case Found of
        true -> {true, S#s{operation_recoveries = Recoveries1}};
        false -> false
    end.

install_operation_snapshot(Rows, S = #s{ns = Ns}) ->
    Desired = lists:foldl(
                fun(Row, Acc) ->
                    Owner = operation_owner_from_row(Ns, Row),
                    OperationRef = Owner#operation_recovery_owner.operation_ref,
                    Acc#{OperationRef => Owner}
                end, #{}, Rows),
    install_operation_desired(Desired, S).

operation_owner_from_row(
  Ns,
  #{type := operation,
    ref := {operation, Ns, <<_:256>>, _AgentRef, <<_:256>>} = OperationRef,
    request_digest := <<_:256>> = Digest,
    outcome_ref := {applications, TargetRefs}, included := [],
    first_slot := Slot, state := unresolved})
  when is_integer(Slot), Slot > 0 ->
    {ok, TargetRefs} = quod_operation_vector:references(TargetRefs),
    #operation_recovery_owner{
       operation_ref = OperationRef, claim_state = unresolved, claim_slot = Slot,
       target_refs = TargetRefs, request_digest = Digest};
operation_owner_from_row(Ns, Row) ->
    error({invalid_unresolved_operation_projection, Ns, Row}).

install_operation_desired(
  Desired0, S = #s{operation_recoveries = Existing}) ->
    Desired = maps:map(
                fun(OperationRef, Owner) ->
                    case maps:get(OperationRef, Existing, undefined) of
                        #operation_recovery_owner{} = Current ->
                            (bind_operation_claim(
                               Current, Owner#operation_recovery_owner.claim_slot,
                               Owner#operation_recovery_owner.request_digest,
                               Owner#operation_recovery_owner.target_refs)
                            )#operation_recovery_owner{
                                claim_state = merge_operation_claim_state(
                                                Current#operation_recovery_owner.claim_state,
                                                unresolved)};
                        undefined ->
                            Owner
                    end
                end, Desired0),
    Retained = maps:fold(
      fun(OperationRef, Owner, Acc) ->
          case maps:is_key(OperationRef, Desired) of
              true -> Acc;
              false ->
                  %% Missing from *unresolved* is not cancellation of result
                  %% delivery. Re-read the durable row under the same worker.
                  State = case Owner#operation_recovery_owner.claim_state of
                              terminal -> terminal;
                              _ -> unknown
                          end,
                  Retiring = Owner#operation_recovery_owner{claim_state = State},
                  case operation_owner_needed(Retiring) of
                      true -> Acc#{OperationRef => wake_operation_owner(Retiring, S)};
                      false -> stop_operation_recovery_process(Retiring), Acc
                  end
          end
      end, Desired, Existing),
    S#s{operation_recoveries = Retained}.

reconcile_operation_recoveries(
  S = #s{sync = ready, prolog_ready = true,
         operation_recoveries = Recoveries}) ->
    Recoveries1 = maps:map(
                    fun(_Ref, Owner) ->
                        start_operation_recovery(Owner, S)
                    end, Recoveries),
    S#s{operation_recoveries = Recoveries1};
reconcile_operation_recoveries(S) ->
    S.

start_operation_recovery(
  Owner = #operation_recovery_owner{
            status = pending,
            operation_ref = OperationRef, trace_ctx = TraceCtx},
  S = #s{ns = Ns}) ->
    trace_operation_event(
      TraceCtx, <<"operation.recovery_spawn">>, OperationRef, Ns, #{}),
    {ChildCtx, Span} = quod_trace:start_span(
      TraceCtx, <<"quod.operation.recover">>, internal,
      #{'quod.namespace' => Ns,
        'quod.operation.id' => quod_trace:tx_id(element(5, OperationRef)),
        'quod.operation.ancestry' => quod_attempt_span:ancestry(TraceCtx),
        'quod.operation.duration_scope' => <<"owner_observed_attempt">>}),
    Tentative = Owner#operation_recovery_owner{
      attempt_span = quod_attempt_span:owned(TraceCtx, ChildCtx, Span)},
    Started = try quod_trace:with_context(ChildCtx, fun() ->
             quod_dtx_coordinator:start_operation_monitor(
               self(), Ns, OperationRef, #{})
         end)
         catch StartClass:StartReason:StartStack ->
             _ = close_operation_span(Tentative, <<"start_failed">>, #{}),
             erlang:raise(StartClass, StartReason, StartStack)
         end,
    case Started of
        {ok, Pid, Monitor} ->
            activate_dtx_coordinator(Pid, S),
            Tentative#operation_recovery_owner{
              status = running, pid = Pid, monitor = Monitor};
        {error, Reason} ->
            logger:error(
              "quod[~s]: operation recovery start failed for ~p: ~p",
              [Ns, OperationRef, Reason]),
            Released = close_operation_span(Tentative, <<"start_failed">>, #{}),
            Released#operation_recovery_owner{status = blocked}
    end;
start_operation_recovery(Owner, _S) ->
    Owner.

settle_operation_recovery(
  Pid, OperationRef,
  S = #s{operation_recoveries = Recoveries}) ->
    case maps:get(OperationRef, Recoveries, undefined) of
        Owner = #operation_recovery_owner{
                  status = running, pid = Pid, monitor = Monitor} ->
            _ = erlang:demonitor(Monitor, [flush]),
            Released = close_operation_span(Owner, <<"done_observed">>, #{}),
            {true,
             S#s{operation_recoveries = Recoveries#{
                   OperationRef => Released#operation_recovery_owner{
                     status = settling, pid = none, monitor = none}}}};
        _ -> false
    end.

block_operation_recovery(
  Pid, OperationRef, Reason,
  S = #s{ns = Ns, operation_recoveries = Recoveries}) ->
    case maps:get(OperationRef, Recoveries, undefined) of
        Owner = #operation_recovery_owner{
                  status = running, pid = Pid, monitor = Monitor} ->
            _ = erlang:demonitor(Monitor, [flush]),
            logger:error(
              "quod[~ts]: durable remote operation ~p blocked: ~p",
              [Ns, OperationRef, Reason]),
            Released = close_operation_span(Owner, <<"error_observed">>, #{}),
            {true,
             S#s{operation_recoveries = Recoveries#{
                   OperationRef => Released#operation_recovery_owner{
                     status = blocked, pid = none, monitor = none}}}};
        _ -> false
    end.

drop_operation_recovery_owner(
  Monitor, Pid, Reason,
  S = #s{operation_recoveries = Recoveries}) ->
    Matches =
        [{OperationRef, Owner}
         || {OperationRef,
             #operation_recovery_owner{pid = OwnerPid,
                                       monitor = OwnerMonitor} = Owner}
                <- maps:to_list(Recoveries),
            OwnerPid =:= Pid, OwnerMonitor =:= Monitor],
    case Matches of
        [{_OperationRef, Owner}] ->
            %% Operational termination is itself a wake. A programming fault
            %% is instead loud and blocked: repeatedly spawning the same
            %% crashing function is not recovery or progress.
            Status = case {Reason, operation_client_result(Owner)} of
                         {normal, Result} when Result =/= pending -> settling;
                         {Signal, _} when Signal =:= killed; Signal =:= shutdown;
                                          Signal =:= noproc -> pending;
                         _ ->
                             logger:error(
                               "quod[~ts]: operation worker failed for ~p: ~p",
                               [S#s.ns, Owner#operation_recovery_owner.operation_ref,
                                Reason]),
                             blocked
                     end,
            Released = close_operation_span(Owner, <<"worker_exit">>,
              #{'quod.operation.exit_class' => quod_attempt_span:exit_class(Reason)}),
            {true, put_operation_owner(
                     Released#operation_recovery_owner{
                       status = Status, pid = none, monitor = none}, S)};
        [] -> false
    end.

wake_operation_recoveries(
  S = #s{operation_recoveries = Recoveries}) ->
    Recoveries1 = maps:map(
                    fun(_Ref, Owner) -> wake_operation_owner(Owner, S) end, Recoveries),
    S#s{operation_recoveries = Recoveries1}.

wake_operation_owner(Owner = #operation_recovery_owner{
                              status = running, pid = Pid}, S) ->
    activate_dtx_coordinator(Pid, S),
    Owner;
wake_operation_owner(Owner = #operation_recovery_owner{status = blocked}, _S) ->
    Owner#operation_recovery_owner{status = pending};
wake_operation_owner(Owner, _S) -> Owner.

bind_operation_claim(Owner = #operation_recovery_owner{
                              operation_ref = Ref, claim_slot = OldSlot,
                              request_digest = OldDigest, target_refs = OldTargets},
                     Slot, Digest, TargetRefs) ->
    case (OldSlot =:= none orelse OldSlot =:= Slot) andalso
         (OldDigest =:= none orelse OldDigest =:= Digest) andalso
         quod_operation_vector:references(TargetRefs) =:= {ok, TargetRefs} andalso
         (OldTargets =:= none orelse OldTargets =:= TargetRefs) of
        true -> Owner#operation_recovery_owner{
                  claim_slot = Slot, request_digest = Digest, target_refs = TargetRefs};
        false -> error({operation_recovery_binding_conflict, Ref})
    end.

merge_operation_claim_state(terminal, _State) -> terminal;
merge_operation_claim_state(_Old, State)
  when State =:= unresolved; State =:= terminal -> State.

operation_owner_needed(#operation_recovery_owner{claim_state = unresolved}) -> true;
operation_owner_needed(#operation_recovery_owner{waiters = Waiters}) ->
    map_size(Waiters) > 0.

put_operation_owner(Owner = #operation_recovery_owner{operation_ref = Ref},
                    S = #s{operation_recoveries = Recoveries}) ->
    case operation_owner_needed(Owner) of
        true -> S#s{operation_recoveries = Recoveries#{Ref => Owner}};
        false ->
            stop_operation_recovery_process(Owner),
            S#s{operation_recoveries = maps:remove(Ref, Recoveries)}
    end.

stop_operation_recovery_process(Owner) ->
    Released = close_operation_span(Owner, <<"retirement_requested">>, #{}),
    stop_operation_recovery_worker(Released).

close_operation_span(Owner = #operation_recovery_owner{attempt_span = Handle}, Closure, Attributes) ->
    Released = Owner#operation_recovery_owner{attempt_span = none},
    ok = quod_attempt_span:close(Handle, Attributes#{'quod.operation.closure' => Closure}),
    Released.

stop_operation_recovery_worker(
  #operation_recovery_owner{pid = Pid, monitor = Monitor, waiters = Waiters})
  when is_pid(Pid), is_reference(Monitor) ->
    0 = map_size(Waiters),
    _ = erlang:demonitor(Monitor, [flush]),
    exit(Pid, shutdown),
    ok;
stop_operation_recovery_worker(#operation_recovery_owner{waiters = Waiters}) ->
    0 = map_size(Waiters),
    ok.

%% Recovery coordination is volatile but its source is not: before its Vote
%% commits the signing journal owns its exact own material, and afterwards
%% the committed projection owns that material and certified reference. Distinct
%% GroupIds therefore own distinct monitored coordinators; no global active
%% slot serializes unrelated groups.
reconcile_dtx_coordinator(S) ->
    reconcile_dtx_coordinators(dtx_coordinator_desired(S), S).

%% A source coordinator is a monitored child of this exact ontology owner.
%% When the owner's committed view or endpoint readiness advances, wake that
%% child directly through the pid already held in the ownership record. This
%% is the local counterpart of a remote foreign-follow edge: it carries no
%% evidence, and the coordinator rechecks the authoritative local snapshot
%% before making progress.
notify_dtx_coordinator_progress(
  S0, S1 = #s{dtx_coordinators = Coordinators, operation_recoveries = Operations}) ->
    case (map_size(Coordinators) > 0 orelse map_size(Operations) > 0) andalso
         local_dtx_progress_changed(S0, S1) of
        true ->
            Identity = target_identity(S1),
            Slot = S1#s.slot,
            Ready = endpoint_read_ready(S1),
            maps:foreach(
              fun(_GroupId,
                  #dtx_coordinator_owner{pid = Pid})
                    when is_pid(Pid) ->
                      send_dtx_coordinator_progress(Pid, Identity, Slot, Ready);
                 (_GroupId, _Malformed) ->
                      ok
              end, Coordinators),
            maps:foreach(
              fun(_Ref, #operation_recovery_owner{status = running, pid = Pid}) when is_pid(Pid) ->
                      send_dtx_coordinator_progress(Pid, Identity, Slot, endpoint_write_ready(S1));
                 (_, _) -> ok
              end, Operations),
            ok;
        false ->
            ok
    end.

activate_dtx_coordinator(Pid, S) when is_pid(Pid) ->
    send_dtx_coordinator_progress(
        Pid, target_identity(S), S#s.slot, endpoint_write_ready(S)).

send_dtx_coordinator_progress(Pid, Identity, Slot, Ready) ->
    Pid ! {local_dtx_progress, self(), Identity, Slot, Ready},
    ok.

local_dtx_progress_changed(S0, S1) ->
    S1#s.slot > S0#s.slot orelse
        endpoint_read_ready(S0) =/= endpoint_read_ready(S1) orelse
        endpoint_write_ready(S0) =/= endpoint_write_ready(S1).

dtx_coordinator_desired(S = #s{dtx_projection = Projection}) ->
    Journaled = pending_votes_snapshot(S#s.signing_journal),
    Pending = [M || #{material := M} <- maps:values(Journaled)],
    quod_dtx_owner:desired(dtx_owner_binding(S), Projection, Pending, quod_time:now_ms()).

committed_group_ref(GroupId, #s{dtx_projection = #{groups := Groups}}) ->
    #{material := {_, _, #{group := #{origin := {Ns, Anchor}, coordinator := Coordinator,
                                     admission := Admission}}}} = maps:get(GroupId, Groups),
    {group, Ns, Anchor, Coordinator, Admission, GroupId}.

reconcile_dtx_coordinators(
  Desired, S0 = #s{dtx_coordinators = Existing}) ->
    S1 = maps:fold(
           fun(GroupId, _Owner, S) ->
                   case maps:is_key(GroupId, Desired) of
                       true -> S;
                       false -> stop_dtx_coordinator(GroupId, S)
                   end
           end, S0, Existing),
    lists:foldl(
      fun({GroupId, Wanted}, S) ->
              reconcile_dtx_coordinator(GroupId, Wanted, S)
      end, S1, lists:sort(maps:to_list(Desired))).

reconcile_dtx_coordinator(
  GroupId, Desired, S = #s{dtx_coordinators = Coordinators}) ->
    case maps:get(GroupId, Coordinators, none) of
        none ->
            start_dtx_coordinator(
              Desired, desired_dtx_trace_context(Desired, S), S);
        Owner ->
            reconcile_dtx_coordinator_owner(Desired, Owner, S)
    end.

reconcile_dtx_coordinator_owner(Desired, Owner, S) ->
    case dtx_coordinator_matches(Desired, Owner, S) of
        keep ->
            S;
        replace ->
            start_dtx_coordinator(
              Desired,
              Owner#dtx_coordinator_owner.trace_ctx,
              stop_dtx_coordinator(
                Owner#dtx_coordinator_owner.group_id, S))
    end.

dtx_coordinator_matches(
  #{material := {Vote, _, _}}, #dtx_coordinator_owner{group_id = GroupId}, _S) ->
    case quod_atomic:group_id(Vote) =:= GroupId of true -> keep; false -> replace end.

%% A live row retains its original caller ancestry across certification.
%% A history-only restart never borrows another request's ambient span.
desired_dtx_trace_context(#{material := {Vote, _, _}, ref := none}, S) ->
    Context = retained_dtx_trace_context(Vote, S),
    case quod_trace:shared_context([otel_tracer:current_span_ctx(Context)]) of
        none -> otel_ctx:new();
        {Parent, []} -> Parent
    end;
desired_dtx_trace_context(_Recovered, _S) ->
    otel_ctx:new().

retained_dtx_trace_context(Record, #s{retained_dtx = Registry, dtx_admission = Admission}) ->
    case maps:get(quod_atomic:record_digest(Record), quod_dtx_owner:rows(Registry), none) of
        #dtx_submission{trace_ctx = Context} -> Context;
        none ->
            case Admission of
                #dtx_admission{waiting = Rows} ->
                    quod_atomic_admission:trace_context(quod_atomic:group_id(Record), Rows);
                none -> otel_ctx:new()
            end
    end.

start_dtx_coordinator(Desired, TraceCtx, S) ->
    start_dtx_coordinator_worker(Desired, TraceCtx, S).

start_dtx_coordinator_worker(
  #{material := {Vote, _, _}} = OwnRow, TraceCtx,
  S = #s{ns = Ns}) ->
    GroupId = quod_atomic:group_id(Vote),
    {ChildCtx, Span} = quod_trace:start_span(
      TraceCtx, <<"quod.dtx.coordinate">>, internal,
      #{'quod.namespace' => Ns,
        'quod.dtx.group_id' => quod_trace:tx_id(GroupId),
        'quod.dtx.ancestry' => quod_attempt_span:ancestry(TraceCtx),
        'quod.dtx.duration_scope' => <<"owner_observed_attempt">>}),
    Owner = #dtx_coordinator_owner{
              group_id = GroupId,
              trace_ctx = TraceCtx,
              coordinate_span = quod_attempt_span:owned(TraceCtx, ChildCtx, Span)},
    %% Only child start is inside this catch. OTP installs the returned row
    %% only when the whole callback returns. A later uncaught unwind can lose
    %% this tentative span; terminate has the old snapshot (see B amendment).
    %% Preserve the exact pre-install exception/stack, with no new tracking.
    Started = try quod_trace:with_context(ChildCtx, fun() ->
                      quod_dtx_coordinator:start_monitor(
                        self(), Ns, OwnRow, #{})
                  end)
              catch StartClass:StartReason:StartStack ->
                  _ = close_dtx_coordinator_span(Owner, <<"start_failed">>, #{}),
                  erlang:raise(StartClass, StartReason, StartStack)
              end,
    case Started of
        {ok, Pid, Monitor} ->
            S1 = put_dtx_coordinator(
                   Owner#dtx_coordinator_owner{pid = Pid, monitor = Monitor}, S),
            %% Establish execution capability after recording the exact pid.
            %% Before this stream arrives the child is parked, not allowed to
            %% race its initial drive against installation of the owner row.
            %% Delivery needs the owned committed view, not voting rights.
            %% A departed signer still owes its pre-vote journaled source work
            %% to the current committee. Endpoint admission retains signing authority.
            ok = send_dtx_coordinator_progress(Pid, target_identity(S1), S1#s.slot,
                                                endpoint_read_ready(S1)),
            S1;
        {error, Reason} ->
            _ = close_dtx_coordinator_span(Owner, <<"start_failed">>, #{}),
            error({dtx_coordinator_start_failed, Ns, GroupId, Reason})
    end.

drop_dtx_coordinator_owner(
  Ref, Pid, Reason, S = #s{dtx_coordinators = Coordinators}) ->
    Matches =
        [{GroupId, Owner}
         || {GroupId,
             #dtx_coordinator_owner{pid = OwnerPid,
                                    monitor = OwnerMonitor} = Owner}
                <- maps:to_list(Coordinators),
            OwnerPid =:= Pid, OwnerMonitor =:= Ref],
    case Matches of
        [{GroupId, Owner}] ->
            S1 = remove_dtx_coordinator(GroupId, S),
            _ = close_dtx_coordinator_span(
                  Owner, <<"worker_exit">>,
                  #{'quod.dtx.exit_class' => quod_attempt_span:exit_class(Reason)}),
            case Reason of
                normal -> ok;
                shutdown -> ok;
                _ ->
                    logger:warning(
                      "quod[~s]: DTX coordinator worker for ~p exited: ~p",
                      [S#s.ns, GroupId, Reason])
            end,
            %% Removal preserves the existing restart order. With no carrying
            %% row, a history rebuild is honestly parentless, not retained
            %% ancestry inferred from this released attempt.
            {true, reconcile_dtx_coordinator(S1)};
        [] ->
            false
    end.

dtx_coordinator_owner(GroupId, #s{dtx_coordinators = Coordinators}) ->
    maps:get(GroupId, Coordinators, none).

put_dtx_coordinator(
  Owner = #dtx_coordinator_owner{group_id = GroupId},
  S = #s{dtx_coordinators = Coordinators}) ->
    S#s{dtx_coordinators = Coordinators#{GroupId => Owner}}.

remove_dtx_coordinator(
  GroupId, S = #s{dtx_coordinators = Coordinators}) ->
    S#s{dtx_coordinators = maps:remove(GroupId, Coordinators)}.

stop_dtx_coordinator(GroupId, S) ->
    case dtx_coordinator_owner(GroupId, S) of
        none -> S;
        Owner ->
            S1 = remove_dtx_coordinator(GroupId, S),
            Released = close_dtx_coordinator_span(
                         Owner, <<"retirement_requested">>, #{}),
            stop_dtx_coordinator_process(Released),
            S1
    end.

%% Span membership follows the existing owner row, not is_recording/1 (whose
%% immutable flag cannot tell whether an SDK span has ended). These are release
%% observations, not durable results or a claim that the child has stopped.
%% End-once applies to installed states. On fatal callback unwind, terminate
%% can see a stale token: the pinned SDK's end-after-take no-op is intentional.
close_dtx_coordinator_span(
  Owner = #dtx_coordinator_owner{coordinate_span = Handle},
  Closure, Attributes) ->
    Released = Owner#dtx_coordinator_owner{coordinate_span = none},
    %% Observation release must never mask the original start exception or
    %% interrupt the existing shutdown path if the SDK has already stopped.
    ok = quod_attempt_span:close(Handle, Attributes#{'quod.dtx.closure' => Closure}),
    Released.

dtx_coordinator_event(#dtx_coordinator_owner{coordinate_span = Handle}, Name) ->
    quod_attempt_span:event(Handle, Name).

stop_dtx_coordinator_process(
  #dtx_coordinator_owner{pid = Pid, monitor = Monitor})
  when is_pid(Pid), is_reference(Monitor) ->
    _ = erlang:demonitor(Monitor, [flush]),
    exit(Pid, shutdown),
    ok;
stop_dtx_coordinator_process(_NoneOrIdle) ->
    ok.

%%%===================================================================
%%% bounded DTX recovery endpoint
%%%===================================================================

start_dtx_endpoint_request(
  TargetNs, PeerKey, Endpoint, Request, ValidationSidecar, TimeoutMs, From,
  S = #s{dtx_correlations = Correlations}) ->
    RequestId = quod_dtx_endpoint:request_id(Request),
    Checks =
        is_binary(TargetNs) andalso byte_size(TargetNs) > 0 andalso
        is_binary(PeerKey) andalso byte_size(PeerKey) =:= 32 andalso
        quod_quic:valid_endpoint(Endpoint) andalso
        is_integer(TimeoutMs) andalso TimeoutMs > 0 andalso
        RequestId =/= error,
    case {Checks, maps:is_key(RequestId, Correlations),
          encode_dtx_request_with_hints(
            TargetNs, Request, relevant_validation_sidecar(Request, ValidationSidecar))} of
        {true, false, {ok, Frame, _SentHints}} ->
            CallerMRef = erlang:monitor(process, element(1, From)),
            TimeoutTag = make_ref(),
            Timer = erlang:send_after(
                      TimeoutMs, self(),
                      {dtx_endpoint_timeout, RequestId, TimeoutTag}),
            Channel = quod_dtx_endpoint:channel(TargetNs),
            OpenRef = quod_quic:open_link_pinned_lease(
                        PeerKey, Endpoint, Channel),
            Correlation =
                #dtx_correlation{
                  target_ns = TargetNs, peer = PeerKey, request = Request,
                  frame = Frame, channel = Channel, endpoint = Endpoint,
                  open_ref = OpenRef,
                  from = From, caller_mref = CallerMRef, timer = Timer,
                  timeout_tag = TimeoutTag,
                  started_at = quod_time:mono_ms()},
            S1 = put_dtx_correlation(RequestId, Correlation, S),
            {ok, S1};
        {false, _, _} ->
            {error, invalid_request};
        {_, true, _} ->
            {error, busy};
        {_, _, {error, _}} ->
            {error, invalid_request}
    end.

put_dtx_correlation(
  RequestId, Correlation = #dtx_correlation{target_ns = TargetNs},
  S = #s{dtx_correlations = Correlations}) ->
    track_owner_peaks(
      retain_dtx_target_channel(
        TargetNs,
        S#s{dtx_correlations = Correlations#{RequestId => Correlation}})).

%% A DTX request owns one exact asynchronous pinned-link open. Authentication
%% completes before this callback; only then is the request queued on the
%% flow-control-aware ordered FIFO. The Simplex state machine never waits for
%% local QUIC acceptance.
dtx_correlation_link_up(
  OpenRef, Peer, Channel, LinkPid,
  S = #s{dtx_correlations = Correlations}) when is_pid(LinkPid) ->
    case find_opening_dtx_correlation(
           OpenRef, Peer, Channel, Correlations) of
        {RequestId,
         Correlation = #dtx_correlation{frame = Frame, link = none,
                                        link_mref = none}} ->
            LinkMRef = erlang:monitor(process, LinkPid),
            ok = quod_link:send_ordered(LinkPid, Frame),
            Correlation1 = Correlation#dtx_correlation{
                             link = LinkPid, link_mref = LinkMRef},
            {handled,
             S#s{dtx_correlations =
                   Correlations#{RequestId => Correlation1}}, []};
        none ->
            ignore
    end;
dtx_correlation_link_up(_OpenRef, _Peer, _Channel, _LinkPid, _S) ->
    ignore.

dtx_correlation_link_error(
  OpenRef, Peer, Channel,
  S = #s{dtx_correlations = Correlations}) ->
    case find_opening_dtx_correlation(
           OpenRef, Peer, Channel, Correlations) of
        {RequestId, Correlation} ->
            {S1, Actions} = finish_dtx_correlation(
                              RequestId, Correlation,
                              {error, not_ready}, S),
            {handled, S1, Actions};
        none ->
            ignore
    end.

find_opening_dtx_correlation(OpenRef, Peer, Channel, Correlations)
  when is_reference(OpenRef) ->
    maps:fold(
      fun(RequestId,
          #dtx_correlation{open_ref = CandidateRef,
                           peer = CandidatePeer,
                           channel = CandidateChannel,
                           link = none} = Correlation,
          none)
            when CandidateRef =:= OpenRef,
                 CandidatePeer =:= Peer,
                 CandidateChannel =:= Channel ->
              {RequestId, Correlation};
         (_RequestId, _Correlation, Found) ->
              Found
      end, none, Correlations);
find_opening_dtx_correlation(_OpenRef, _Peer, _Channel, _Correlations) ->
    none.

release_dtx_correlation_lease(
  #dtx_correlation{peer = Peer, endpoint = Endpoint, channel = Channel,
                   open_ref = OpenRef}) ->
    quod_quic:release_link_pinned(Peer, Endpoint, Channel, OpenRef).

retain_dtx_target_channel(TargetNs, S = #s{ns = TargetNs}) ->
    S;
retain_dtx_target_channel(
  TargetNs, S = #s{dtx_out_channels = Channels}) ->
    Channel = quod_dtx_endpoint:channel(TargetNs),
    case maps:get(Channel, Channels, undefined) of
        undefined ->
            true = quod_reg:subscribe({channel, Channel}),
            S#s{dtx_out_channels = Channels#{Channel => {TargetNs, 1}}};
        {TargetNs, Count} ->
            S#s{dtx_out_channels =
                    Channels#{Channel => {TargetNs, Count + 1}}}
    end.

release_dtx_target_channel(TargetNs, S = #s{ns = TargetNs}) ->
    S;
release_dtx_target_channel(
  TargetNs, S = #s{dtx_out_channels = Channels}) ->
    Channel = quod_dtx_endpoint:channel(TargetNs),
    case maps:get(Channel, Channels, undefined) of
        {TargetNs, 1} ->
            true = quod_reg:unsubscribe({channel, Channel}),
            S#s{dtx_out_channels = maps:remove(Channel, Channels)};
        {TargetNs, Count} when Count > 1 ->
            S#s{dtx_out_channels =
                    Channels#{Channel => {TargetNs, Count - 1}}};
        undefined ->
            S
    end.

handle_dtx_endpoint_frame(
  TargetNs, serve, PeerIdentity, InLink, Payload, S)
  when is_pid(InLink), is_binary(Payload) ->
    case quod_link:peer_key(PeerIdentity) of
        <<_:256>> = Peer ->
            case quod_dtx_endpoint:decode_response(TargetNs, Payload) of
                {ok, Response, ValidationSidecar} ->
                    accept_dtx_endpoint_response(
                      Peer, InLink, Response, ValidationSidecar, S);
                {error, _} ->
                    case quod_dtx_endpoint:decode_request(TargetNs, Payload) of
                        {ok, Request, ValidationSidecar, Carrier} ->
                            quod_trace:with_context(quod_trace:extract(Carrier), fun() ->
                                admit_dtx_endpoint_request(
                                  PeerIdentity, InLink, Request, ValidationSidecar, S)
                            end);
                        {error, _} ->
                            {S, []}
                    end
            end;
        undefined ->
            {S, []}
    end;
handle_dtx_endpoint_frame(_TargetNs, _Mode, _Peer, _InLink, _Payload, S) ->
    {S, []}.

handle_dtx_endpoint_response(TargetNs, Peer, Link, Payload, S)
  when is_binary(Peer), byte_size(Peer) =:= 32, is_pid(Link),
       is_binary(Payload) ->
    case quod_dtx_endpoint:decode_response(TargetNs, Payload) of
        {ok, Response, ValidationSidecar} ->
            accept_dtx_endpoint_response(
              Peer, Link, Response, ValidationSidecar, S);
        {error, _} -> {S, []}
    end;
handle_dtx_endpoint_response(_TargetNs, _Peer, _Link, _Payload, S) ->
    {S, []}.

%% The transport publishes an authenticated inbound header as
%% `{PeerKey, Endpoint}` and a TLS-pinned outbound link as `PeerKey`.  DTX
%% replies use the same bidirectional stream as their request, so normalize
%% those two transport-owned forms before applying the exact correlation
%% check.  No endpoint value participates in response authority.
handle_dtx_outbound_message(
  PeerIdentity, Link, Channel, Payload, S) ->
    case {dtx_outbound_target(Channel, S),
          quod_link:peer_key(PeerIdentity)} of
        {{ok, TargetNs}, <<_:256>> = PeerKey} ->
            {S1, Actions} = handle_dtx_endpoint_response(
                              TargetNs, PeerKey, Link, Payload, S),
            {handled, S1, Actions};
        _ ->
            ignore
    end.

dtx_outbound_target(Channel, #s{ns = Ns, dtx_chan = Channel}) ->
    {ok, Ns};
dtx_outbound_target(Channel, #s{dtx_out_channels = OutChannels}) ->
    case maps:find(Channel, OutChannels) of
        {ok, {TargetNs, _Count}} -> {ok, TargetNs};
        error -> error
    end.

accept_dtx_endpoint_response(
  Peer, Link, Response, ValidationSidecar,
  S = #s{dtx_correlations = Correlations}) ->
    RequestId = quod_dtx_endpoint:response_id(Response),
    case maps:get(RequestId, Correlations, undefined) of
        #dtx_correlation{peer = Peer, link = Link,
                         request = Request} = Correlation ->
            case quod_dtx_endpoint:correlates(Request, Response) of
                true ->
                    finish_dtx_correlation(
                      RequestId, Correlation,
                      {ok, Response,
                       relevant_response_hints(Response, ValidationSidecar)}, S);
                false ->
                    {S, []}
            end;
        _ ->
            {S, []}
    end.

finish_dtx_correlation(
  RequestId,
  Correlation = #dtx_correlation{
                   target_ns = TargetNs, from = From,
                   caller_mref = CallerMRef, timer = Timer,
                   link_mref = LinkMRef, started_at = StartedAt}, Reply,
  S = #s{dtx_correlations = Correlations}) ->
    _ = erlang:cancel_timer(Timer),
    _ = erlang:demonitor(CallerMRef, [flush]),
    demonitor_if_set(LinkMRef),
    Remaining = maps:remove(RequestId, Correlations),
    release_dtx_correlation_lease(Correlation),
    S1 = release_dtx_target_channel(
           TargetNs,
           S#s{dtx_correlations = Remaining}),
    observe_simplex_owner_terminal(
      S, dtx_endpoint, outbound, endpoint_terminal_result(Reply), StartedAt),
    {S1, [{reply, From, Reply}]}.

timeout_dtx_correlation(
  RequestId, TimeoutTag,
  S = #s{dtx_correlations = Correlations}) ->
    case maps:get(RequestId, Correlations, undefined) of
        #dtx_correlation{timeout_tag = TimeoutTag} = Correlation ->
            finish_dtx_correlation(
              RequestId, Correlation, {error, timeout}, S);
        _ ->
            {S, []}
    end.

admit_dtx_endpoint_request(PeerIdentity, InLink, Request, ValidationSidecar, S) ->
    admit_dtx_endpoint_worker(
      PeerIdentity, InLink, Request, ValidationSidecar, S).

admit_dtx_endpoint_worker(
  PeerIdentity, InLink, Request, ValidationSidecar,
  S = #s{dtx_workers = Workers}) ->
    Peer = endpoint_peer(PeerIdentity),
    RequestId = quod_dtx_endpoint:request_id(Request),
    case {dtx_endpoint_operation_ready(Request, S),
          dtx_worker_pending(Peer, RequestId, Workers)} of
        {false, _} ->
            send_dtx_endpoint_response(
              InLink, {error, RequestId, not_ready}, [], S),
            {S, []};
        {true, true} ->
            send_dtx_endpoint_response(
              InLink, {error, RequestId, busy}, [], S),
            {S, []};
        {true, false} ->
            case start_dtx_endpoint_operation(
                   PeerIdentity, {link, InLink}, Request, ValidationSidecar,
                   ?QUOD_DTX_ENDPOINT_WORKER_TIMEOUT_MS, S) of
                {ok, S1, Actions} ->
                    {S1, Actions};
                {error, Reason} ->
                    send_dtx_endpoint_response(
                      InLink, {error, RequestId, Reason}, [], S),
                    {S, []}
            end
    end.

start_local_dtx_endpoint_request(
  Request, ValidationSidecar, TimeoutMs, From,
  S = #s{ns = Ns, dtx_workers = Workers}) ->
    Hints = relevant_validation_sidecar(Request, ValidationSidecar),
    case {dtx_endpoint_operation_ready(Request, S),
          encode_dtx_request_with_hints(Ns, Request, Hints),
          dtx_worker_pending(
            local, quod_dtx_endpoint:request_id(Request), Workers)} of
        {false, _, _} ->
            {error, not_ready};
        {true, {error, _}, _} ->
            {error, invalid_request};
        {true, {ok, _CanonicalFrame, _FittedHints}, true} ->
            {error, busy};
        {true, {ok, _CanonicalFrame, FittedHints}, false} ->
            start_dtx_endpoint_operation(
              local, {caller, From}, Request, FittedHints, TimeoutMs, S)
    end.

start_dtx_endpoint_operation(Peer, Destination,
                             {submit, _RequestId, _RecordBlob} = Request,
                             ValidationSidecar,
                             TimeoutMs, S) ->
    case start_dtx_submit_owner(Peer, Destination, Request, ValidationSidecar, TimeoutMs, S) of
        {ok, Next} -> {ok, Next, []};
        {error, _} = Error -> Error
    end;
start_dtx_endpoint_operation(_Peer, Destination,
                             {present, RequestId, GroupId, Blob}, _Hints, _TimeoutMs, S) ->
    case quod_atomic:decode_presentation(target_identity(S), GroupId, Blob) of
        {ok, Material} ->
            Accepted = case retention_disposition(Material, S) of
                {included, _} -> {ok, S};
                stale -> {ok, S}; %% Already-resolved tombstone, never reopen it.
                _ -> admit_owned_vote(Material, none, S)
            end,
            case Accepted of
                {ok, Next} ->
                    %% The response acknowledges this owner turn's custody,
                    %% not a vote/outcome. No per-request worker owns the plan.
                    {Delivered, Actions} = deliver_dtx_endpoint_response(
                        Destination, {presented, RequestId, GroupId}, [], Next),
                    {ok, Delivered, Actions};
                {error, busy} = Busy -> Busy;
                {error, _} -> {error, not_ready}
            end;
        error -> {error, invalid_request}
    end;
start_dtx_endpoint_operation(Peer, Destination, Request, _ValidationSidecar,
                             TimeoutMs, S) ->
    {ok, start_dtx_server_worker(
           Peer, Destination, Request, TimeoutMs, S), []}.

%% Decode and retain a submit in the owning statem turn.  The helper process
%% owns only the caller deadline; it never calls back into Simplex.
%% Consequently a later phase query cannot overtake submit admission and see
%% a false absence while the semantic record is already in flight.
start_dtx_submit_owner(
  PeerIdentity, Destination,
  Request = {submit, _RequestId, RecordBlob}, ValidationSidecar, TimeoutMs,
  S = #s{dtx_workers = Workers}) ->
    case quod_atomic:decode_material(RecordBlob) of
        {ok, Material = {Record, Digest, _}} ->
            Peer = endpoint_peer(PeerIdentity),
            %% Bound the admission start by this turn's entry and this decoded
            %% boundary. No payload, new clock, or request ancestry is retained.
            case quod_trace:owner_context() of
                undefined -> ok;
                Ctx ->
                    _ = try quod_trace:add_event(Ctx, <<"consensus.control_admission_decoded">>,
                            #{'quod.dtx.record_digest' => Digest,
                              'quod.dtx.phase' => atom_to_binary(quod_atomic:record_kind(Record))})
                        catch _:_ -> false end
            end,
            Parent = self(),
            OwnerMRef = dtx_worker_owner_monitor(Destination),
            {Pid, Monitor} = spawn_monitor(
                               fun() ->
                                   await_dtx_submit_result(
                                     Parent, Digest, TimeoutMs)
                               end),
            Worker = #dtx_server_worker{
                       pid = Pid, monitor = Monitor,
                       owner_mref = OwnerMRef, peer = Peer,
                       contact = endpoint_contact(PeerIdentity),
                       request = Request, destination = Destination,
                       started_at = quod_time:mono_ms()},
            S1 = S#s{dtx_workers = Workers#{Pid => Worker}},
            case retain_dtx_submission(
                   Material, {dtx_endpoint, Pid}, ValidationSidecar, select, S1) of
                {ok, S2} ->
                    {ok, S2};
                {error, Reason} ->
                    ok = remove_new_dtx_submit_owner(Pid, Worker),
                    {error, endpoint_submit_error(Reason)}
            end;
        error ->
            {error, invalid_request}
    end.

await_dtx_submit_result(Parent, Digest, TimeoutMs) ->
    receive
        {dtx_submit_result, Result} ->
            Parent ! {dtx_endpoint_worker_result, self(),
                      {submit_result, Digest, Result}}
    after TimeoutMs ->
        Parent ! {dtx_endpoint_worker_result, self(),
                  {submit_result, Digest, {error, timeout}}}
    end.

remove_new_dtx_submit_owner(
  Pid, #dtx_server_worker{monitor = Monitor, owner_mref = OwnerMRef}) ->
    _ = erlang:demonitor(Monitor, [flush]),
    demonitor_if_set(OwnerMRef),
    exit(Pid, shutdown),
    ok.

endpoint_submit_error(invalid_dtx_submission) -> invalid_request;
endpoint_submit_error(_) -> not_ready.

start_dtx_server_worker(PeerIdentity, Destination, Request, TimeoutMs,
                        S = #s{ns = Ns, dtx_workers = Workers}) ->
    Peer = endpoint_peer(PeerIdentity),
    Parent = self(),
    OwnerMRef = dtx_worker_owner_monitor(Destination),
    TraceCtx = quod_trace:context(),
    Deadline = quod_time:mono_ms() + TimeoutMs,
    {Pid, Monitor} = spawn_monitor(
                       fun() ->
                           quod_trace:with_optional_span(
                             TraceCtx, <<"quod.dtx.endpoint.serve">>, server,
                             #{'quod.namespace' => Ns,
                               'quod.endpoint.kind' => atom_to_binary(element(1, Request), utf8)},
                             fun() ->
                                 run_dtx_endpoint_worker(
                                   Parent, Ns, Peer, Request,
                                   Deadline)
                             end)
                       end),
    Worker = #dtx_server_worker{
               pid = Pid, monitor = Monitor, owner_mref = OwnerMRef,
               peer = Peer, contact = endpoint_contact(PeerIdentity),
               request = Request,
               attestation = dtx_endpoint_attestation(Request, S),
               destination = Destination,
               started_at = quod_time:mono_ms()},
    S#s{dtx_workers = Workers#{Pid => Worker}}.

run_dtx_endpoint_worker(Parent, Ns, Peer, Request, Deadline) ->
    ParentMonitor = erlang:monitor(process, Parent),
    IsSnapshot = outcome_request_claim(Request) =/= none,
    %% Subscribe before reading: committed-height feed notices can precede
    %% Prolog apply/replay readiness, including at an otherwise quiet head.
    IsSnapshot andalso quod_reg:subscribe({runtime, Ns}),
    Context = {Parent, ParentMonitor, Ns, Peer, Request, Deadline, none},
    try run_dtx_endpoint_query(Context)
    after
        _ = erlang:demonitor(ParentMonitor, [flush]),
        IsSnapshot andalso quod_reg:unsubscribe({runtime, Ns})
    end.

run_dtx_endpoint_query(
  Context = {Parent, _ParentMonitor, Ns, Peer, Request, Deadline, Evidence}) ->
    case max(0, Deadline - quod_time:mono_ms()) of
        0 -> endpoint_worker_expired(Parent);
        Remaining ->
            Result = execute_dtx_endpoint_request(Ns, Peer, Request, Remaining, Deadline, Evidence),
            Pinned = pin_endpoint_evidence(Context, Result),
            case waiting_applied_key(Request, Result) of
                {wait, Key} ->
                    wait_dtx_endpoint_progress(Pinned, {applied, Key});
                ready ->
                    Parent ! {dtx_endpoint_worker_result, self(), Result},
                    case outcome_request_claim(Request) of
                        none -> ok;
                        _ -> wait_dtx_snapshot_decision(
                               Pinned, outcome_snapshot_floor(Result))
                    end
            end
    end.

%% A snapshot is not terminal merely because the helper obtained it. The
%% consensus owner accepts it against its current era/head or retains this
%% same worker. Runtime messages stay queued until that serialized decision.
wait_dtx_snapshot_decision(
  Context = {Parent, ParentMonitor, _Ns, _Peer, _Request, Deadline, _Evidence}, Floor) ->
    Remaining = max(0, Deadline - quod_time:mono_ms()),
    receive
        {dtx_snapshot_decision, Parent, done} -> ok;
        {dtx_snapshot_decision, Parent, resample} ->
            run_dtx_endpoint_query(Context);
        {dtx_snapshot_decision, Parent, wait} ->
            wait_dtx_endpoint_progress(Context, {snapshot, Floor});
        {'DOWN', ParentMonitor, process, Parent, _Reason} -> ok
    after Remaining -> endpoint_worker_expired(Parent)
    end.

wait_dtx_endpoint_progress(
  Context = {Parent, ParentMonitor, _Ns, _Peer, _Request, Deadline, _Evidence}, Requirement) ->
    Remaining = max(0, Deadline - quod_time:mono_ms()),
    receive
        {'DOWN', ParentMonitor, process, Parent, _Reason} -> ok;
        {dtx_snapshot_decision, Parent, done} -> ok;
        {dtx_resolve_applied, Key} when Requirement =:= {applied, Key} ->
            run_dtx_endpoint_query(Context);
        {dtx_snapshot_progress, Parent} when element(1, Requirement) =:= snapshot ->
            run_dtx_endpoint_query(Context);
        {projection_advanced, _Engine, Height}
          when element(1, Requirement) =:= snapshot,
               Height > element(2, Requirement) ->
            run_dtx_endpoint_query(Context);
        {replay_ready, _ReplayId, _Height}
          when element(1, Requirement) =:= snapshot ->
            run_dtx_endpoint_query(Context);
        _Unrelated -> wait_dtx_endpoint_progress(Context, Requirement)
    after Remaining -> endpoint_worker_expired(Parent)
    end.

endpoint_worker_expired(Parent) ->
    Parent ! {dtx_endpoint_worker_result, self(), {error, timeout}},
    ok.

outcome_snapshot_floor({outcome_state, #{applied_floor := Floor}})
  when is_integer(Floor), Floor >= 0 -> Floor;
outcome_snapshot_floor({operation_applied_state, _Evidence, #{applied_floor := Floor}})
  when is_integer(Floor), Floor >= 0 -> Floor;
outcome_snapshot_floor(_Result) -> -1.

%% Exact entry evidence is immutable for this owner-bound request. Waiting for
%% Prolog publication may refresh the outcome, never re-read/re-verify history.
pin_endpoint_evidence(Context, {applied_state, Evidence, _State}) ->
    setelement(7, Context, Evidence);
pin_endpoint_evidence(Context, {operation_applied_state, Evidence, _Snapshot}) ->
    setelement(7, Context, Evidence);
pin_endpoint_evidence(Context, _Result) -> Context.

waiting_applied_key(
  {applied, _RequestId, GroupId, ResolveRef, Generation, Verdict},
  {applied_state, Evidence, State}) ->
    case applied_claim_status(
           GroupId, ResolveRef, Generation, Verdict, Evidence, State) of
        {applied, _TargetIdentity} ->
            ready;
        pending ->
            {wait, {GroupId, ResolveRef, Generation, Verdict}};
        invalid ->
            ready
    end;
waiting_applied_key(_Request, _Result) ->
    ready.

wake_dtx_applied_workers(
  {ExpectedGroupId, Slot, ExpectedGeneration}, Workers) ->
    maps:foreach(
      fun(Pid,
          #dtx_server_worker{
            request = {applied, _RequestId, GroupId, ResolveRef,
                       Generation, Verdict}})
            when GroupId =:= ExpectedGroupId,
                 Generation =:= ExpectedGeneration ->
              case quod_dtx:certified_ref_binding(ResolveRef) of
                  {ok, _Target, Slot, _Digest} ->
                      Pid ! {dtx_resolve_applied,
                             {GroupId, ResolveRef, Generation, Verdict}};
                  _ ->
                      ok
              end;
         (_Pid, _Worker) ->
              ok
      end, Workers).

dtx_worker_owner_monitor({caller, {Caller, _Tag}}) when is_pid(Caller) ->
    erlang:monitor(process, Caller);
dtx_worker_owner_monitor(_Destination) ->
    none.

demonitor_if_set(none) -> ok;
demonitor_if_set(Ref) when is_reference(Ref) ->
    _ = erlang:demonitor(Ref, [flush]),
    ok.

dtx_worker_pending(Peer, RequestId, Workers) ->
    maps:fold(
      fun(_Pid,
          #dtx_server_worker{peer = WorkerPeer, request = Request}, Found) ->
              Found orelse
                  (WorkerPeer =:= Peer andalso
                   quod_dtx_endpoint:request_id(Request) =:= RequestId)
      end, false, Workers).

endpoint_peer(local) -> local;
endpoint_peer({<<_:256>> = Peer, _Endpoint}) -> Peer.

endpoint_contact({<<_:256>> = Peer, Endpoint}) -> {Peer, Endpoint};
endpoint_contact(local) -> none.

dtx_source_reference({quod_dtx_resolve, 4, _, _, _, _, Ref, _, _, _, _}, TargetIdentity) ->
    foreign_ref_source(Ref, TargetIdentity);
dtx_source_reference(_Record, _TargetIdentity) ->
    none.

foreign_ref_source(Ref, TargetIdentity) ->
    case quod_dtx:certified_ref_binding(Ref) of
        {ok, Identity, _Slot, _Digest} when Identity =/= TargetIdentity ->
            {ok, Ref, Identity};
        _ ->
            none
    end.

%% Transport contacts stay inside the endpoint workers that already own the
%% corresponding request. Match its exact claim bytes to the candidate's
%% attached evidence, encoded once per candidate (never decoded per worker).
%% This is only contact selection, not authentication: the ordinary reference
%% verifier still verifies the candidate and owns any reusable route promotion.
content_reference_contacts(ReferencePlan, Workers, TargetIdentity) ->
    Claims = maps:from_list(
      [{Bytes, {Ref, Identity}}
       || {#transaction{evidence = {Ref, #transaction{origin = Identity} = Claim}},
           References} <- ReferencePlan,
          Identity =/= TargetIdentity,
          lists:member({transaction, Ref}, References),
          {ok, Bytes} <- [quod_transaction:encode_evidence(Ref, Claim)]]),
    maps:fold(
      fun(_Pid,
          #dtx_server_worker{
            contact = {<<_:256>>, _} = Contact,
            request = {apply_claim, _RequestId, WorkerTarget, EvidenceBlob}}, Acc)
            when WorkerTarget =:= TargetIdentity ->
              case maps:find(EvidenceBlob, Claims) of
                  {ok, {Ref, Identity}} -> Acc#{Ref => {Identity, Contact}};
                  error -> Acc
              end;
         (_Pid, _Worker, Acc) ->
              Acc
      end, #{}, Workers).

dtx_reference_contacts(ReferencePlan, Workers, TargetIdentity)
  when is_list(ReferencePlan) ->
    SourcesByBlob = maps:from_list(
                     [{Blob, Source}
                      || {Control, _References} <- ReferencePlan,
                         Record <- [quod_atomic:control_body(Control)],
                         Source = {ok, _, _} <- [dtx_source_reference(Record, TargetIdentity)],
                         {ok, Blob} <- [quod_atomic:encode_record(Record)]]),
    maps:fold(
      fun(_Pid,
          #dtx_server_worker{
            contact = {<<_:256>>, _} = Contact,
            request = {submit, _RequestId, RecordBlob}}, Acc) ->
              case maps:get(RecordBlob, SourcesByBlob, none) of
                  {ok, Ref, Identity} -> Acc#{Ref => {Identity, Contact}};
                  none -> Acc
              end;
         (_Pid, _Worker, Acc) ->
              Acc
      end, #{}, Workers).

reference_contact(Ref, Identity, Contacts) ->
    case maps:get(Ref, Contacts, none) of
        {Identity, Contact} -> Contact;
        _ -> none
    end.

observe_verified_reference_contacts(valid, Contacts) ->
    maps:foreach(
      fun(_Ref, {Identity, Contact}) ->
              quod_foreign_log:observe_candidate(Identity, Contact)
      end, Contacts),
    ok;
observe_verified_reference_contacts(_Verdict, _Contacts) ->
    ok.

endpoint_write_ready(S = #s{sync = ready, prolog_ready = true}) ->
    case current_dtx_binding(S) of
        {ok, _Binding} -> true;
        {error, _} -> false
    end;
endpoint_write_ready(_S) ->
    false.

endpoint_read_ready(
  #s{sync = ready, prolog_ready = true,
     genesis_hash = <<_:256>>, store = Store}) ->
    Store =/= undefined;
endpoint_read_ready(_S) ->
    false.

dtx_endpoint_operation_ready({submit, _, _}, S) ->
    endpoint_write_ready(S);
dtx_endpoint_operation_ready({present, _, _, _}, S) ->
    case dtx_owner_binding(S) of {ok, _} -> true; {error, _} -> false end;
dtx_endpoint_operation_ready({apply_claim, _, {Ns, Anchor}, _},
                             S = #s{ns = Ns, genesis_hash = Anchor}) ->
    endpoint_write_ready(S);
dtx_endpoint_operation_ready({cancel_operation_effect, _, {Ns, Anchor}, _},
                             S = #s{ns = Ns, genesis_hash = Anchor}) ->
    endpoint_read_ready(S);
dtx_endpoint_operation_ready({phase, _, _, _}, S) ->
    endpoint_read_ready(S);
dtx_endpoint_operation_ready({outcome, _, _, _, _} = Request, S) ->
    outcome_request_binding(Request, S);
dtx_endpoint_operation_ready({read_attest, _, _}, S) ->
    endpoint_read_ready(S);
dtx_endpoint_operation_ready({operation_applied, _, _} = Request, S) ->
    endpoint_read_ready(S) andalso outcome_request_binding(Request, S);
dtx_endpoint_operation_ready({operation_receipt, _, {operation, Ns, Anchor, _, _}, _},
                            S = #s{ns = Ns, genesis_hash = Anchor}) ->
    endpoint_read_ready(S);
dtx_endpoint_operation_ready({applied, _, _, _, _, _}, S) ->
    endpoint_read_ready(S);
dtx_endpoint_operation_ready(_, _S) ->
    false.

execute_dtx_endpoint_request(
  Ns, _Peer, {apply_claim, _RequestId, {Ns, _} = Target, EvidenceBlob}, _TimeoutMs, Deadline, _Evidence) ->
    execute_claimed_application(Target, EvidenceBlob, Deadline);
execute_dtx_endpoint_request(
  Ns, Peer,
  {cancel_operation_effect, _RequestId, {Ns, _} = Target, SubmissionBlob},
  _TimeoutMs, _Deadline, _Evidence) ->
    case quod_effect_journal:cancel_operation(
           Peer, Target, SubmissionBlob) of
        cancelled -> {operation_effect_cancelled, cancelled};
        not_found -> {operation_effect_cancelled, not_found};
        {error, _} -> {error, invalid_request}
    end;
execute_dtx_endpoint_request(
  Ns, _Peer, {phase, _RequestId, GroupId, _Kind}, _TimeoutMs, _Deadline, _Evidence) ->
    case quod_prolog:dtx_group_state(Ns, GroupId) of
        {ok, State} -> {phase_state, State};
        {error, _} -> {error, not_ready}
    end;
execute_dtx_endpoint_request(
  Ns, _Peer, {outcome, _RequestId, OutcomeRef, _CommitteeId,
       _MinimumSlot}, TimeoutMs, _Deadline, _Evidence) ->
    execute_outcome_snapshot(Ns, OutcomeRef, TimeoutMs);
execute_dtx_endpoint_request(
  Ns, _Peer, {read_attest, _RequestId, PlanBlob}, TimeoutMs, _Deadline, _Evidence) ->
    case quod_dtx:decode(PlanBlob) of
        {ok, Plan} ->
            case quod_prolog:validate_read_plan(Ns, Plan, TimeoutMs) of
                {ok, Applied} -> {read_plan_valid, Plan, Applied};
                {error, conflict_retry} -> {error, conflict_retry};
                {error, invalid_read_plan} -> {error, invalid_request};
                {error, _} -> {error, read_certificate_unavailable}
            end;
        {error, _} ->
            {error, invalid_request}
    end;
execute_dtx_endpoint_request(
  Ns, _Peer, {applied, _RequestId, GroupId, ResolveRef,
       _Generation, _Verdict}, _TimeoutMs, Deadline, CachedEvidence) ->
    case endpoint_exact_evidence(Ns, ResolveRef, resolve, Deadline, CachedEvidence) of
        {ok, Evidence} ->
            case quod_prolog:dtx_group_state(Ns, GroupId) of
                {ok, State} -> {applied_state, Evidence, State};
                {error, _} -> {error, not_ready}
            end;
        {error, invalid_request} ->
            {error, invalid_request};
        {error, not_found} ->
            {error, not_found};
        {error, not_ready} ->
            {error, not_ready}
    end;
execute_dtx_endpoint_request(
  Ns, _Peer, {operation_receipt, _RequestId, OperationRef, Slot}, _TimeoutMs, Deadline, _Cached) ->
    case operation_completion_evidence(Ns, Slot, OperationRef, Deadline) of
        {ok, Ref, Complete} ->
            case quod_transaction:encode_evidence(Ref, Complete) of
                {ok, Blob} -> {operation_receipt_evidence, Blob};
                {error, _} -> {error, not_ready}
            end;
        {error, Reason} -> {error, Reason}
    end;
execute_dtx_endpoint_request(
  Ns, _Peer, {operation_applied, _RequestId, Ref}, _TimeoutMs, Deadline, CachedEvidence) ->
    case endpoint_exact_evidence(Ns, Ref, transaction, Deadline, CachedEvidence) of
        {ok, Evidence} ->
            case max(0, Deadline - quod_time:mono_ms()) of
                0 -> {error, timeout};
                Remaining ->
                    case execute_outcome_snapshot(
                           Ns, quod_transaction:stable_ref(Ref), Remaining) of
                        {outcome_state, Snapshot} -> {operation_applied_state, Evidence, Snapshot};
                        {error, not_ready} -> {operation_applied_state, Evidence, not_ready};
                        Error -> Error
                    end
            end;
        {error, Reason} -> {error, Reason}
    end.

endpoint_exact_evidence(Ns, Ref, Phase, Deadline, none) ->
    dtx_local_evidence(Ns, Ref, Phase, Deadline);
endpoint_exact_evidence(_Ns, _Ref, _Phase, _Deadline, Evidence) when is_map(Evidence) ->
    {ok, Evidence}.

execute_claimed_application({Ns, Anchor} = Target, EvidenceBlob, Deadline) ->
    Started = erlang:monotonic_time(),
    case decode_claimed_application(Target, EvidenceBlob) of
        {ok, ClaimRef, Claim, Application} ->
            ok = quod_metrics:observe_remote_operation_stage(
                   Ns, claim_verification, ok,
                   erlang:monotonic_time() - Started),
            case quod_transaction:validate_independent_claim(Claim) of
                ok ->
                    TargetRef = {transaction, Ns, Anchor, Application#transaction.tx_id},
                    submit_claimed_application(Ns, TargetRef, ClaimRef, Application, Deadline);
                {error, independent_scope_required} -> {error, independent_scope_required};
                {error, _} -> {error, invalid_request}
            end;
        error ->
            ok = quod_metrics:observe_remote_operation_stage(
                   Ns, claim_verification, failed,
                   erlang:monotonic_time() - Started),
            {error, invalid_request}
    end.

decode_claimed_application(Target, EvidenceBlob) ->
    case quod_transaction:decode_evidence(EvidenceBlob) of
        {ok, CertifiedClaimRef,
         #transaction{role = {remote_claim, _, _, _}} = Claim} ->
            try
                ClaimRef = quod_transaction:stable_ref(CertifiedClaimRef),
                {transaction, _, _, _} = ClaimRef,
                Application0 = quod_transaction:remote_application(
                                 ClaimRef, Claim, Target),
                Application = quod_transaction:attach_evidence(
                                Application0, CertifiedClaimRef, Claim),
                {ok, ClaimRef, Claim, Application}
            catch _:_ ->
                error
            end;
        _ ->
            error
    end.

%% Ordinary applications go straight to Prolog's single new/pending/terminal
%% admission: an exact pending delivery joins its existing waiters. Only private
%% effects need a terminal lookup before journal custody, because their prepared
%% material may already be retired. Neither path creates another application.
submit_claimed_application(
  Ns, TargetRef, _ClaimRef,
  #transaction{tx_id = TxId, effects = []} = Application, Deadline) ->
    Submission = case max(0, Deadline - quod_time:mono_ms()) of
                     0 -> {error, timeout};
                     Remaining -> quod_prolog:submit_role(Ns, Application, [], Remaining)
                 end,
    claimed_application_outcome(Ns, TargetRef, TxId, Submission, Deadline);
submit_claimed_application(
  Ns, TargetRef, ClaimRef, Application = #transaction{tx_id = TxId, effects = [_]}, Deadline) ->
    case claimed_terminal_application(Ns, TargetRef, TxId, Deadline) of
        nonterminal -> bind_claimed_effect(Ns, TargetRef, ClaimRef, Application, Deadline);
        Result -> Result
    end;
submit_claimed_application(_Ns, _TargetRef, _ClaimRef, _Application, _Deadline) ->
    {error, invalid_request}.

%% The journal already checks its persisted plan signer, executor, exact
%% application and prepared material. Do not duplicate that custody decision.
bind_claimed_effect(Ns, TargetRef, ClaimRef, Application0, Deadline) ->
    case dtx_ready_binding(Ns) of
        {ok, {Ns, _, Self, _}} ->
            Application = Application0#transaction{author = Self, submitted_at = quod_time:now_ms()},
            case quod_effect_journal:bind_operation_transaction(ClaimRef, TargetRef, Application) of
                {ok, EffectId} ->
                    claimed_effect_application(Ns, TargetRef, Application#transaction.tx_id,
                                               EffectId, Deadline);
                {error, not_found} -> {error, not_ready};
                {error, Reason} ->
                    logger:warning("quod[~ts]: operation effect binding failed: ~p", [Ns, Reason]),
                    {error, not_ready}
            end;
        _ -> {error, not_ready}
    end.

claimed_effect_application(
  Ns, TargetRef, TxId, EffectId, Deadline) ->
    case quod_effect_journal:handoff(EffectId) of
        ok ->
            Await = case max(0, Deadline - quod_time:mono_ms()) of
                        0 -> {error, timeout};
                        Remaining -> quod_effect_journal:await(EffectId, Remaining)
                    end,
            claimed_application_outcome(
              Ns, TargetRef, TxId,
              case Await of
                  ok -> {error, committed_outcome_lookup};
                  {error, Reason} -> {error, Reason}
              end, Deadline);
        {error, not_in_charge} ->
            {error, not_ready};
        {error, _} ->
            %% The durable row remains recoverable by the journal. A caller
            %% timeout is uncertainty, never permission to resubmit a new T.
            {error, not_ready}
    end.

claimed_application_outcome(
  Ns, _TargetRef, TxId, {ok, _Bindings, Slot, TxId}, Deadline) ->
    claimed_application_evidence(Ns, Slot, TxId, committed, Deadline);
claimed_application_outcome(Ns, TargetRef, TxId, {error, _Reason}, Deadline) ->
    case claimed_terminal_application(Ns, TargetRef, TxId, Deadline) of
        nonterminal -> {error, not_ready};
        Result -> Result
    end;
claimed_application_outcome(_Ns, _TargetRef, _TxId, _Other, _Deadline) ->
    {error, not_ready}.

claimed_terminal_application(Ns, TargetRef, TxId, Deadline) ->
    Snapshot = case max(0, Deadline - quod_time:mono_ms()) of
                   0 -> {error, timeout};
                   Remaining -> quod_prolog:outcome_snapshot(Ns, TargetRef, Remaining)
               end,
    case Snapshot of
        {ok, #{outcome := not_found}} -> nonterminal;
        {ok, #{outcome := #{status := pending}}} -> nonterminal;
        {ok, #{outcome := #{status := committed, height := Slot}}} ->
            claimed_application_evidence(Ns, Slot, TxId, committed, Deadline);
        {ok, #{outcome := #{status := rejected, reason := Reason, height := Slot}}}
          when is_atom(Reason) ->
            claimed_application_evidence(
              Ns, Slot, TxId, {rejected, Reason}, Deadline);
        _ ->
            {error, not_ready}
    end.

claimed_application_evidence(Ns, Slot, TxId, Result, Deadline) ->
    case application_result_evidence(Ns, Slot, TxId, Deadline) of
        {ok, Ref, Entry, Evidence = #{transaction := Transaction}} ->
            case quod_transaction:encode_evidence(Ref, Transaction) of
                {ok, EvidenceBlob} ->
                    {application_result, Result, EvidenceBlob,
                     Ref, Entry, Evidence};
                {error, _} ->
                    {error, not_ready}
            end;
        {error, _} ->
            {error, not_ready}
    end.

%% Read the application once. The same checked selection supplies the
%% discovery bytes, exact-history acceleration and this member's AM3 vote.
%% It never leaves as authority: the receiver runs the ordinary exact verifier.
application_result_evidence(Ns, Slot, <<_:256>> = TxId, Deadline) ->
    case history_view(Ns, any, Deadline) of
        {ok, View} ->
            case read_evidence_at(View, Slot, {application, TxId}) of
                {ok, Ref, _Transaction, Entry} ->
                    case quod_foreign_log:verify_local_entry_deadline(
                           View, Ref, transaction, Entry, Deadline) of
                        {ok, Evidence} -> {ok, Ref, Entry, Evidence};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
application_result_evidence(_Ns, _Slot, _TxId, _Deadline) ->
    {error, invalid_request}.

execute_outcome_snapshot(Ns, OutcomeRef, TimeoutMs) ->
    case quod_outcome:ref_identity(OutcomeRef) of
        {ok, {Ns, _Anchor}} ->
            case quod_prolog:outcome_snapshot(Ns, OutcomeRef, TimeoutMs) of
                {ok, Snapshot} -> {outcome_state, Snapshot};
                {error, bad_outcome_ref} -> {error, invalid_request};
                {error, timeout} -> {error, timeout};
                {error, _} -> {error, not_ready}
            end;
        _ ->
            {error, invalid_request}
    end.

finish_dtx_server_worker(
  Pid, Result, S = #s{dtx_workers = Workers}) ->
    case maps:get(Pid, Workers, undefined) of
        #dtx_server_worker{request = Request} = Worker ->
            case outcome_snapshot_wait(Request, Result, S) of
                wait ->
                    Floor = outcome_snapshot_floor(Result),
                    Slot = S#s.slot,
                    Resampled = Worker#dtx_server_worker.snapshot_resampled,
                    case endpoint_read_ready(S) andalso Slot > Floor andalso
                         Slot > Resampled of
                        true ->
                            %% A newer committed head is a concrete edge, not
                            %% permission to spin on the same stale snapshot.
                            Pid ! {dtx_snapshot_decision, self(), resample},
                            {S#s{dtx_workers = Workers#{
                                  Pid => Worker#dtx_server_worker{
                                           snapshot_resampled = Slot}}}, []};
                        false ->
                            Pid ! {dtx_snapshot_decision, self(), wait},
                            {S, []}
                    end;
                ready -> complete_dtx_server_worker(Pid, Result, S)
            end;
        undefined -> {S, []}
    end.

outcome_snapshot_wait(Request, Result, S) ->
    case outcome_request_claim(Request) of
        {exact, Ref} ->
            case {outcome_request_binding(Request, S), endpoint_read_ready(S), Result} of
                {true, true, {operation_applied_state, Evidence, Snapshot}} ->
                    case quod_operation:applied_result(Ref, Evidence, Snapshot) =:= pending of
                        true -> wait;
                        false -> ready
                    end;
                {true, false, _} -> wait;
                {true, _, {error, not_ready}} -> wait;
                _ -> ready
            end;
        {OutcomeRef, CommitteeId, MinimumSlot} ->
            case {outcome_request_binding(Request, S), Result} of
                {true, {outcome_state,
                        #{applied_floor := Floor, outcome := _} = Snapshot}}
                  when map_size(Snapshot) =:= 2,
                       is_integer(Floor), Floor >= 0, Floor =< S#s.slot ->
                    case current_outcome_snapshot(
                           OutcomeRef, CommitteeId, MinimumSlot, Snapshot, S) of
                        {ok, _, _, _} -> ready;
                        error -> wait
                    end;
                {true, {error, not_ready}} -> wait;
                _ -> ready
            end;
        none -> ready
    end.

outcome_request_claim({outcome, _RequestId, Ref, CommitteeId, MinimumSlot}) ->
    {Ref, CommitteeId, MinimumSlot};
outcome_request_claim({operation_applied, _RequestId, Ref}) -> {exact, Ref};
outcome_request_claim(_Request) -> none.

outcome_request_binding(Request, S = #s{committee_id = CommitteeId, self = Self}) ->
    case outcome_request_claim(Request) of
        {exact, Ref} ->
            case quod_dtx:certified_ref_binding(Ref) of
                {ok, Target, _Slot, _Digest} -> Target =:= target_identity(S);
                _ -> false
            end;
        {Ref, CommitteeId, MinimumSlot}
          when is_binary(CommitteeId), byte_size(CommitteeId) =:= 32,
               is_integer(MinimumSlot), MinimumSlot >= 0 ->
            quod_outcome:ref_identity(Ref) =:= {ok, target_identity(S)} andalso
                lists:member(Self, active_validators(S));
        _ -> false
    end.

%% The existing request map is also the wait registry. Do not infer apply
%% readiness from a feed height: local replay can become ready at the same
%% committed head. Committee changes wake old requests to refuse their stale
%% binding, rather than retaining them until an unrelated new block.
wake_dtx_snapshot_workers(S0, S1 = #s{dtx_workers = Workers}) ->
    case endpoint_read_ready(S0) =/= endpoint_read_ready(S1) orelse
         S0#s.committee_id =/= S1#s.committee_id orelse
         S1#s.slot > S0#s.slot of
        true ->
            maps:foreach(
              fun(Pid, #dtx_server_worker{request = Request}) ->
                  case outcome_request_claim(Request) of
                      none -> ok;
                      _ -> Pid ! {dtx_snapshot_progress, self()}
                  end
              end, Workers);
        false -> ok
    end.

complete_dtx_server_worker(
  Pid, Result, S = #s{dtx_workers = Workers}) ->
    case maps:take(Pid, Workers) of
        {#dtx_server_worker{monitor = Monitor, request = Request,
                            owner_mref = OwnerMRef,
                            attestation = Attestation,
                            destination = Destination,
                            started_at = StartedAt}, Rest} ->
            Pid ! {dtx_snapshot_decision, self(), done},
            _ = erlang:demonitor(Monitor, [flush]),
            demonitor_if_set(OwnerMRef),
            S1 = detach_dtx_endpoint_waiter(
                   Pid, S#s{dtx_workers = Rest}),
            Response0 = dtx_endpoint_result_response(
                          Request, Result, Attestation, S1),
            {Response, ValidationSidecar} = valid_generated_dtx_response(
                                       Request, Response0, S1#s.ns),
            observe_simplex_owner_terminal(
              S, dtx_endpoint, inbound,
              dtx_worker_terminal_result(Result, Response), StartedAt),
            FlushStarted = erlang:monotonic_time(),
            Delivered = deliver_dtx_endpoint_response(
                          Destination, Response, ValidationSidecar, S1),
            ok = observe_operation_response_flush(
                   Request, Response, S1#s.ns, FlushStarted),
            Delivered;
        error ->
            {S, []}
    end.

observe_operation_response_flush(
  {apply_claim, _, _, _}, {application, _, committed, _}, Ns, Started) ->
    quod_metrics:observe_remote_operation_stage(
      Ns, response_flush, ok, erlang:monotonic_time() - Started);
observe_operation_response_flush(
  {apply_claim, _, _, _}, {application, _, {rejected, _}, _}, Ns, Started) ->
    quod_metrics:observe_remote_operation_stage(
      Ns, response_flush, rejected, erlang:monotonic_time() - Started);
observe_operation_response_flush(
  {apply_claim, _, _, _}, _Response, Ns, Started) ->
    quod_metrics:observe_remote_operation_stage(
      Ns, response_flush, failed, erlang:monotonic_time() - Started);
observe_operation_response_flush(_Request, _Response, _Ns, _Started) -> ok.

dtx_endpoint_result_response(
  {submit, RequestId, _RecordBlob}, {submit_result, Digest, Result}, S) ->
    TargetIdentity = target_identity(S),
    case Result of
        {ok, Ref, ValidationSidecar} ->
            case quod_dtx:certified_ref_binding(Ref) of
                {ok, TargetIdentity, _Slot, _CertifiedDigest} ->
                    {{accepted, RequestId, Digest, Ref}, ValidationSidecar};
                _ ->
                    {{error, RequestId, not_ready}, []}
            end;
        {error, busy} ->
            {{error, RequestId, busy}, []};
        {error, invalid_dtx_submission} ->
            {{error, RequestId, invalid_request}, []};
        {error, _} ->
            {{error, RequestId, not_ready}, []}
    end;
dtx_endpoint_result_response(
  {apply_claim, RequestId, _Target, _ClaimEvidence},
  {application_result, Result, TargetEvidence, Ref,
   Entry, Evidence}, S) ->
    Vote = operation_vote_hint(Ref, application_vote_result(Result), Evidence, S),
    Hints = case Vote of
                none -> [{Ref, Entry}];
                _ -> [{Ref, Entry}, Vote]
            end,
    {{application, RequestId, Result, TargetEvidence},
     quod_dtx_endpoint:normalize_sidecar(Hints)};
dtx_endpoint_result_response(
  {cancel_operation_effect, RequestId, _Target, _SubmissionBlob},
  {operation_effect_cancelled, Status}, _S) ->
    {{operation_effect_cancelled, RequestId, Status}, []};
dtx_endpoint_result_response(
  {phase, RequestId, GroupId, Kind}, {phase_state, State}, S) ->
    {phase_endpoint_response(RequestId, GroupId, Kind, State, S), []};
dtx_endpoint_result_response(
  {outcome, RequestId, OutcomeRef, CommitteeId, MinimumSlot},
  {outcome_state, Snapshot}, S) ->
    {outcome_endpoint_response(
       RequestId, OutcomeRef, CommitteeId, MinimumSlot, Snapshot, S), []};
dtx_endpoint_result_response(
  {operation_receipt, RequestId, OperationRef, Slot},
  {operation_receipt_evidence, Blob}, _S) ->
    {{operation_receipt, RequestId, OperationRef, Slot, Blob}, []};
dtx_endpoint_result_response(
  {operation_applied, RequestId, Ref},
  {operation_applied_state, Evidence, Snapshot}, S) ->
    {operation_applied_response(RequestId, Ref, Evidence, Snapshot, S), []};
dtx_endpoint_result_response(
  {read_attest, RequestId, _PlanBlob},
  {read_plan_valid, Plan, Applied}, S) ->
    Attestation = dtx_endpoint_attestation(
                    {read_attest, RequestId, <<>>}, S),
    {read_attest_endpoint_response(
       RequestId, Plan, Applied, Attestation, S), []};
dtx_endpoint_result_response(
  {applied, RequestId, GroupId, ResolveRef, Generation, Verdict},
  {applied_state, Evidence, State}, S) ->
    {applied_endpoint_response(
       RequestId, GroupId, ResolveRef, Generation, Verdict,
       Evidence, State, S), []};
dtx_endpoint_result_response(Request, {error, Reason}, _S) ->
    %% The endpoint codec is the sole owner of the bounded refusal vocabulary.
    Id = quod_dtx_endpoint:request_id(Request),
    {quod_dtx_endpoint:error_response(Id, Reason), []};
dtx_endpoint_result_response(Request, _Result, _S) ->
    {{error, quod_dtx_endpoint:request_id(Request), not_ready}, []}.

dtx_endpoint_result_response(
  {read_attest, RequestId, _PlanBlob},
  {read_plan_valid, Plan, Applied}, Attestation, S) ->
    {read_attest_endpoint_response(
       RequestId, Plan, Applied, Attestation, S), []};
dtx_endpoint_result_response(Request, Result, _Attestation, S) ->
    dtx_endpoint_result_response(Request, Result, S).

outcome_endpoint_response(
  RequestId, OutcomeRef, CommitteeId, MinimumSlot, Snapshot, S) ->
    case current_outcome_snapshot(
           OutcomeRef, CommitteeId, MinimumSlot, Snapshot, S) of
        {ok, TargetIdentity, AppliedFloor, Outcome} ->
            {outcome, RequestId, TargetIdentity, CommitteeId,
             AppliedFloor, Outcome};
        error ->
            {error, RequestId, not_ready}
    end.

current_outcome_snapshot(
  OutcomeRef, CommitteeId, MinimumSlot,
  #{applied_floor := AppliedFloor, outcome := Outcome} = Snapshot,
  S = #s{slot = AppliedFloor, committee_id = CommitteeId, self = Self})
  when map_size(Snapshot) =:= 2,
       is_integer(AppliedFloor), AppliedFloor >= MinimumSlot ->
    case quod_outcome:ref_identity(OutcomeRef) =:=
             {ok, target_identity(S)} andalso
         endpoint_read_ready(S) andalso
         lists:member(Self, active_validators(S)) of
        true -> {ok, target_identity(S), AppliedFloor, Outcome};
        false -> error
    end;
current_outcome_snapshot(
  _OutcomeRef, _CommitteeId, _MinimumSlot, _Snapshot, _S) ->
    error.

valid_generated_dtx_response(Request, {Response, ValidationSidecar}, Ns) ->
    case quod_dtx_endpoint:encode_response(Ns, Response, ValidationSidecar) of
        {ok, _Frame} -> {Response, ValidationSidecar};
        {error, {too_large, dtx_endpoint}} when ValidationSidecar =/= [] ->
            case drop_optional_entry_hint(ValidationSidecar) of
                {ok, Reduced} ->
                    valid_generated_dtx_response(
                      Request, {Response, Reduced}, Ns);
                error ->
                    valid_generated_dtx_response(Request, {Response, []}, Ns)
            end;
        {error, _} ->
            {{error, quod_dtx_endpoint:request_id(Request), not_ready}, []}
    end.

phase_endpoint_response(RequestId, GroupId, Kind,
                        State = #{history := History,
                                  generation := Generation}, S) ->
    case endpoint_snapshot_fresh(State, S) of
        false ->
            {error, RequestId, not_ready};
        true ->
            Phase = case History of
                        none -> pending_or_absent_dtx_phase(
                                  GroupId, Kind, S);
                        _ ->
                            case quod_atomic:history_phase(Kind, History) of
                                {ok, Ref} -> {committed, Ref};
                                not_found -> pending_or_absent_dtx_phase(
                                               GroupId, Kind, S)
                            end
                    end,
            {phase, RequestId, Generation, Phase}
    end;
phase_endpoint_response(RequestId, _GroupId, _Kind, _State, _S) ->
    {error, RequestId, not_ready}.

pending_or_absent_dtx_phase(GroupId, Kind, S) ->
    case local_dtx_phase_pending(GroupId, Kind, S) of
        true -> pending;
        false -> not_found
    end.

local_dtx_phase_pending(
  GroupId, vote,
  #s{dtx_admission = #dtx_admission{} = Admission} = S) ->
    quod_atomic_admission:contains(GroupId, Admission#dtx_admission.waiting) orelse
        retained_dtx_phase_pending(GroupId, vote, S);
local_dtx_phase_pending(GroupId, Kind, S) ->
    retained_dtx_phase_pending(GroupId, Kind, S).

retained_dtx_phase_pending(
  GroupId, Kind, #s{retained_dtx = Registry}) ->
    Submissions = quod_dtx_owner:rows(Registry),
    maps:fold(
      fun(_Digest,
          #dtx_submission{group_id = PendingGroup, control = Control}, Found) ->
              Found orelse
                  (PendingGroup =:= GroupId andalso
                   quod_atomic:control_kind(Control) =:= Kind)
      end, false, Submissions).

operation_applied_response(RequestId, Ref, Evidence, Snapshot,
                           S) ->
    case quod_operation:applied_result(Ref, Evidence, Snapshot) of
        {ok, Result} ->
            case operation_vote_hint(Ref, Result, Evidence, S) of
                {{operation_vote, Ref, Self}, {Statement, Signature}} ->
                    {operation_applied, RequestId, Ref, Statement, Self, Signature};
                none -> {error, RequestId, not_ready}
            end;
        _ -> {error, RequestId, not_ready}
    end.

application_vote_result(committed) -> applied;
application_vote_result({rejected, Reason}) -> {rejected, Reason}.

operation_vote_hint(Ref, Result, Evidence,
                    S = #s{self = Self, id = Signer}) ->
    case {endpoint_read_ready(S),
          applied_evidence_committee(target_identity(S), Evidence),
          quod_ontology:network_identity()} of
        {true, {ok, Committee, _CommitteeId}, {ok, Network}} ->
            case lists:member(Self, Committee) andalso
                 applied_signer_matches(Self, Signer) of
                true ->
                    case quod_applied_certificate:operation_statement(
                           Network, Evidence, Result) of
                        {ok, Statement} ->
                            case quod_applied_certificate:sign_operation_vote(
                                   Statement, Signer) of
                                {ok, {Self, Signature}} ->
                                    {{operation_vote, Ref, Self},
                                     {Statement, Signature}};
                                error -> none
                            end;
                        error -> none
                    end;
                false -> none
            end;
        _ -> none
    end.

applied_endpoint_response(
  RequestId, GroupId, ResolveRef, Generation, Verdict,
  Evidence, State,
  S = #s{self = Self, id = Signer}) ->
    CurrentTarget = target_identity(S),
    case {endpoint_snapshot_fresh(State, S),
          applied_claim_status(
            GroupId, ResolveRef, Generation, Verdict, Evidence, State),
          applied_evidence_committee(CurrentTarget, Evidence),
          quod_ontology:network_identity()} of
        {true, {applied, CurrentTarget},
         {ok, Committee, ResolveCommitteeId},
         {ok, NetworkIdentity}} ->
            case lists:member(Self, Committee) andalso
                 applied_signer_matches(Self, Signer) of
                true ->
                    case quod_applied_certificate:sign_applied_vote(
                           NetworkIdentity, CurrentTarget,
                           ResolveCommitteeId, GroupId, ResolveRef,
                           Generation, Verdict, Signer) of
                        {ok, {Self, Signature}} ->
                            {applied, RequestId, CurrentTarget,
                             ResolveCommitteeId, GroupId, ResolveRef,
                             Generation, Verdict, Self, Signature};
                        error ->
                            {error, RequestId, not_ready}
                    end;
                false ->
                    {error, RequestId, not_ready}
            end;
        {true, {applied, CurrentTarget}, _BadCommitteeOrNetwork, _} ->
            {error, RequestId, not_ready};
        {true, _NotApplied, _Committee, _Network} ->
            {error, RequestId, not_found};
        {false, _, _, _} ->
            {error, RequestId, not_ready}
    end.

%% Validation runs outside the consensus owner. Capture the exact committed
%% snapshot at admission so a later block cannot turn a valid result into a
%% false refusal. The certificate remains bound to that older certified
%% anchor and committee; a later commit is deliberately not a read lock.
dtx_endpoint_attestation(
  {read_attest, _RequestId, _PlanBlob},
  S = #s{slot = Applied, last_applied = Applied,
         self = Self, id = Signer, committee_id = CommitteeId})
  when Applied > 0 ->
    case endpoint_read_ready(S) andalso
         lists:member(Self, active_validators(S)) andalso
         applied_signer_matches(Self, Signer) of
        true ->
            {read_attest, target_identity(S), Applied,
             CommitteeId, Self, Signer};
        false ->
            none
    end;
dtx_endpoint_attestation(_Request, _S) ->
    none.

read_attest_endpoint_response(
  RequestId, Plan, Applied,
  {read_attest, Target, Applied, CommitteeId, Self, Signer},
  S = #s{store = Store}) ->
    case target_identity(S) =:= Target andalso
         quod_dtx:target(Plan) =:= Target of
        true ->
            case read_certificate_anchor(Store, Target, Applied) of
                {ok, AnchorRef} ->
                    ProofId = quod_dtx:proof_id(Plan),
                    PlanDigest = quod_dtx:digest(Plan),
                    case quod_read_certificate:sign(
                           Target, ProofId, PlanDigest, AnchorRef,
                           CommitteeId, Signer) of
                        {ok, {Self, Signature}} ->
                            {read_attest, RequestId, Target, ProofId,
                             PlanDigest, AnchorRef, CommitteeId,
                             Self, Signature};
                        error ->
                            {error, RequestId, read_certificate_unavailable}
                    end;
                {error, _} ->
                    {error, RequestId, read_certificate_unavailable}
            end;
        false ->
            {error, RequestId, read_certificate_unavailable}
    end;
read_attest_endpoint_response(
  RequestId, _Plan, _Applied, _Attestation, _S) ->
    {error, RequestId, read_certificate_unavailable}.

%% Complaint skips carry no state change, so the nearest preceding committed
%% payload is the exact state anchor.  A non-noop row that cannot itself form a
%% portable certified reference is never skipped: doing so would attest newer
%% state under an older committee.
read_certificate_anchor(_Store, _Target, Slot) when Slot < 1 ->
    {error, unavailable};
read_certificate_anchor(Store, Target, Slot) ->
    case quod_ledger_store:read_at(Store, Slot) of
        {ok, Entry} ->
            #entry{data = Data} = quod_ledger:entry_view(Entry),
            case quod_ledger:classify(Data) of
                noop -> read_certificate_anchor(Store, Target, Slot - 1);
                {content, [Transaction | _]} ->
                    quod_dtx:certified_entry_ref(Target, Entry, Transaction);
                {controls, [{_Kind, Control} | _]} ->
                    quod_dtx:certified_entry_ref(Target, Entry, Control);
                invalid -> {error, unavailable}
            end;
        _ ->
            {error, unavailable}
    end.

applied_evidence_committee(
  Target,
  #{identity := Target, committee := Committee,
    committee_id := <<_:256>> = CommitteeId})
  when is_list(Committee), Committee =/= [],
       length(Committee) =< ?MAX_VALIDATORS ->
    case quod_quorum:committee_size(Committee) of
        {ok, N} when N =:= length(Committee) -> {ok, Committee, CommitteeId};
        _ -> error
    end;
applied_evidence_committee(_Target, _Evidence) ->
    error.

applied_signer_matches(
  Self, #{pubkey := Self, key := _}) -> true;
applied_signer_matches(_Self, _Signer) -> false.

applied_claim_status(
  GroupId, ResolveRef, Generation, Verdict, Evidence,
  #{applied_floor := AppliedFloor}) ->
    case {quod_applied_certificate:exact_resolve_binding(Evidence, ResolveRef),
          quod_dtx:certified_ref_binding(ResolveRef)} of
        {{ok, GroupId, ResolveRef, Generation, Verdict},
         {ok, TargetIdentity, ResolveSlot, _}} when AppliedFloor >= ResolveSlot ->
            %% One authority: the exact certified Resolve and its published
            %% floor. A staged group row cannot authorize an early AM3 vote;
            %% row retirement or a missed wake cannot suppress a durable one.
            %% Generation belongs to that Resolve, not the current proof epoch.
            {applied, TargetIdentity};
        {{ok, GroupId, ResolveRef, Generation, Verdict}, {ok, _, _, _}} -> pending;
        _ ->
            invalid
    end;
applied_claim_status(
  _GroupId, _ResolveRef, _Generation, _Verdict, _Evidence, _State) ->
    invalid.

endpoint_snapshot_fresh(
  #{applied_floor := Floor, generation := Generation},
  S = #s{slot = Floor,
         dtx_projection = #{generation := Generation}}) ->
    endpoint_read_ready(S);
endpoint_snapshot_fresh(_State, _S) ->
    false.

send_dtx_endpoint_response(ReplyLink, Response, ValidationSidecar, #s{ns = Ns}) ->
    case quod_dtx_endpoint:encode_response(Ns, Response, ValidationSidecar) of
        {ok, Frame} -> quod_link:send_ordered(ReplyLink, Frame);
        {error, _} -> ok
    end.

deliver_dtx_endpoint_response({link, ReplyLink}, Response, ValidationSidecar, S) ->
    send_dtx_endpoint_response(ReplyLink, Response, ValidationSidecar, S),
    {S, []};
deliver_dtx_endpoint_response({caller, From}, Response, ValidationSidecar, S) ->
    {S, [{reply, From, {ok, Response, ValidationSidecar}}]}.

drop_dtx_endpoint_owner(Ref, Pid, Result,
                        S = #s{dtx_workers = Workers}) ->
    case maps:get(Pid, Workers, undefined) of
        #dtx_server_worker{monitor = Ref, request = Request,
                           owner_mref = OwnerMRef,
                           destination = Destination,
                           started_at = StartedAt} ->
            demonitor_if_set(OwnerMRef),
            S1 = detach_dtx_endpoint_waiter(
                   Pid, S#s{dtx_workers = maps:remove(Pid, Workers)}),
            Response =
                {error, quod_dtx_endpoint:request_id(Request), not_ready},
            {S2, Actions} =
                deliver_dtx_endpoint_response(
                  Destination, Response, [], S1),
            observe_simplex_owner_terminal(
              S, dtx_endpoint, inbound, Result, StartedAt),
            {true, S2, Actions};
        _ ->
            case drop_dtx_worker_caller(Ref, Pid, S) of
                {true, _S1, _Actions} = Dropped -> Dropped;
                false -> drop_dtx_correlation_owner(Ref, Pid, S)
            end
    end.

drop_dtx_worker_caller(
  Ref, Pid, S = #s{dtx_workers = Workers}) ->
    case maps:fold(
           fun(WorkerPid,
               #dtx_server_worker{
                 owner_mref = OwnerMRef,
                 destination = {caller, {Caller, _Tag}}}, Found) ->
                   case Found of
                       none when OwnerMRef =:= Ref, Caller =:= Pid ->
                           WorkerPid;
                       _ -> Found
                   end;
              (_WorkerPid, _Worker, Found) ->
                   Found
           end, none, Workers) of
        none ->
            false;
        WorkerPid ->
            #dtx_server_worker{monitor = Monitor, started_at = StartedAt} =
                maps:get(WorkerPid, Workers),
            _ = erlang:demonitor(Monitor, [flush]),
            exit(WorkerPid, shutdown),
            observe_simplex_owner_terminal(
              S, dtx_endpoint, inbound, caller_down, StartedAt),
            {true,
             detach_dtx_endpoint_waiter(
               WorkerPid,
               S#s{dtx_workers = maps:remove(WorkerPid, Workers)}), []}
    end.

detach_dtx_endpoint_waiter(
  Pid, S = #s{retained_dtx = Registry}) ->
    {_Found, Registry1} = quod_dtx_owner:detach_waiter(Pid, Registry),
    A = admission_state(S),
    Rows = quod_atomic_admission:detach_waiter(Pid, A#dtx_admission.waiting),
    compact_dtx_admission(S#s{retained_dtx = Registry1,
                              dtx_admission = A#dtx_admission{waiting = Rows}}).

drop_dtx_correlation_owner(
  Ref, Pid, S = #s{dtx_correlations = Correlations}) ->
    case maps:fold(
           fun(RequestId,
               #dtx_correlation{caller_mref = MRef, from = {Caller, _}},
               Found) ->
                   case Found of
                       none when MRef =:= Ref, Caller =:= Pid -> RequestId;
                       _ -> Found
                   end
           end, none, Correlations) of
        none ->
            drop_dtx_correlation_link(Ref, Pid, S);
        RequestId ->
            Correlation = maps:get(RequestId, Correlations),
            {S1, _NoReply} = drop_dtx_correlation(
                                RequestId, Correlation, caller_down, S),
            {true, S1, []}
    end.

drop_dtx_correlation_link(
  Ref, Pid, S = #s{dtx_correlations = Correlations}) ->
    case maps:fold(
           fun(RequestId,
               #dtx_correlation{link_mref = LinkMRef, link = Link}, none)
                 when LinkMRef =:= Ref, Link =:= Pid ->
                   RequestId;
              (_RequestId, _Correlation, Found) ->
                   Found
           end, none, Correlations) of
        none ->
            false;
        RequestId ->
            Correlation = maps:get(RequestId, Correlations),
            {S1, Actions} = finish_dtx_correlation(
                              RequestId, Correlation,
                              {error, connection_lost}, S),
            {true, S1, Actions}
    end.

drop_dtx_correlation(
  RequestId,
  Correlation = #dtx_correlation{
                   target_ns = TargetNs, caller_mref = CallerMRef,
                   link_mref = LinkMRef, timer = Timer,
                   started_at = StartedAt}, Result,
  S = #s{dtx_correlations = Correlations}) ->
    _ = erlang:cancel_timer(Timer),
    _ = erlang:demonitor(CallerMRef, [flush]),
    demonitor_if_set(LinkMRef),
    observe_simplex_owner_terminal(
      S, dtx_endpoint, outbound, Result, StartedAt),
    Remaining = maps:remove(RequestId, Correlations),
    release_dtx_correlation_lease(Correlation),
    {release_dtx_target_channel(
       TargetNs,
       S#s{dtx_correlations = Remaining}), []}.

close_dtx_endpoint(Correlations, Workers) ->
    maps:foreach(
      fun(_RequestId,
          Correlation = #dtx_correlation{
                           from = From, caller_mref = CallerMRef,
                           link_mref = LinkMRef, timer = Timer}) ->
              _ = erlang:cancel_timer(Timer),
              _ = erlang:demonitor(CallerMRef, [flush]),
              demonitor_if_set(LinkMRef),
              release_dtx_correlation_lease(Correlation),
              _ = gen_statem:reply(From, {error, not_ready}),
              ok
      end, Correlations),
    maps:foreach(
      fun(Pid, #dtx_server_worker{monitor = Monitor,
                                  owner_mref = OwnerMRef}) ->
              _ = erlang:demonitor(Monitor, [flush]),
              demonitor_if_set(OwnerMRef),
              exit(Pid, shutdown)
      end, Workers),
    ok.

%% Sidecars carry optional exact-entry acceleration only. Required application
%% certificates are part of Complete itself, never optional transport hints.
relevant_validation_sidecar({submit, _RequestId, RecordBlob}, ValidationSidecar) ->
    case quod_atomic:encoded_reference_requirements(RecordBlob) of
        {ok, Refs} -> select_validation_sidecar(Refs, ValidationSidecar);
        error -> []
    end;
relevant_validation_sidecar(_Request, _ValidationSidecar) ->
    [].

encode_dtx_request_with_hints(Ns, Request, ValidationSidecar) ->
    case quod_dtx_endpoint:encode_request(
           Ns, Request, ValidationSidecar, quod_trace:inject(quod_trace:context())) of
        {ok, Frame} -> {ok, Frame, ValidationSidecar};
        {error, {too_large, dtx_endpoint}} when ValidationSidecar =/= [] ->
            case drop_optional_entry_hint(ValidationSidecar) of
                {ok, Reduced} ->
                    encode_dtx_request_with_hints(Ns, Request, Reduced);
                error ->
                    {error, {too_large, dtx_endpoint}}
            end;
        {error, _} = Error -> Error
    end.

relevant_response_hints(
  {accepted, _RequestId, _Digest, Ref}, ValidationSidecar) ->
    case maps:from_list(quod_dtx_endpoint:normalize_sidecar(ValidationSidecar)) of
        #{Ref := Entry} -> [{Ref, Entry}];
        _ -> []
    end;
relevant_response_hints(
  {application, _RequestId, _Result, _EvidenceBlob}, ValidationSidecar) ->
    %% The worker authenticates the blob and selects its exact reference.
    %% The transport owner must not repeat that work to filter optional hints.
    quod_dtx_endpoint:normalize_sidecar(ValidationSidecar);
relevant_response_hints(_Response, _ValidationSidecar) ->
    [].

relevant_control_validation_sidecar(Record, ValidationSidecar) ->
    select_validation_sidecar(quod_atomic:reference_requirements(Record), ValidationSidecar).

select_validation_sidecar(Refs, ValidationSidecar) ->
    Hints = maps:from_list(quod_dtx_endpoint:normalize_sidecar(ValidationSidecar)),
    quod_dtx_endpoint:normalize_sidecar(
      [{Ref, Entry} || {_Phase, Ref} <- Refs,
                       {ok, Entry} <- [maps:find(Ref, Hints)]]).

drop_optional_entry_hint(Hints) ->
    drop_optional_entry_hint(lists:reverse(Hints), []).

drop_optional_entry_hint([], _Prefix) ->
    error;
drop_optional_entry_hint([{{applied, _, _}, _} = Hint | Rest], Prefix) ->
    drop_optional_entry_hint(Rest, [Hint | Prefix]);
drop_optional_entry_hint([{{operation_vote, _, _}, _} = Hint | Rest], Prefix) ->
    drop_optional_entry_hint(Rest, [Hint | Prefix]);
drop_optional_entry_hint([{_Ref, _Entry} | Rest], Prefix) ->
    {ok, lists:reverse(Rest) ++ lists:reverse(Prefix)}.

merge_submission_validation_sidecar(
  Row = #dtx_submission{control = Control, validation_sidecar = Existing,
                        bytes = Bytes}, NewHints) ->
    Merged = relevant_control_validation_sidecar(
               quod_atomic:control_body(Control), merge_validation_sidecars(Existing, NewHints)),
    case Merged =:= Existing of
        true ->
            Row;
        false ->
            %% Better evidence changes the relay frame.  It must cross the
            %% current link once even when the semantic control was already
            %% placed there.
            Row#dtx_submission{
              validation_sidecar = Merged,
              relay_placement = none,
              bytes = Bytes - validation_sidecar_bytes(Existing) +
                  validation_sidecar_bytes(Merged)}
    end.

%% Exact-entry hints are immutable acceleration and keep their first valid
%% value. Applied certificates are replaceable proposal evidence: a malformed
%% or cryptographically wrong first certificate must not shadow a later valid
%% redrive for the same semantic block.
merge_validation_sidecars(Existing0, New0) ->
    Existing = quod_dtx_endpoint:normalize_sidecar(Existing0),
    New = quod_dtx_endpoint:normalize_sidecar(New0),
    {NewApplied, NewEntries} = lists:partition(
                                 fun({{applied, _, _}, _}) -> true;
                                    (_) -> false
                                 end, New),
    prioritize_validation_sidecar(NewApplied ++ Existing ++ NewEntries).

validation_sidecar_bytes([]) -> 0;
validation_sidecar_bytes(Hints) ->
    {ok, WireHints} = quod_dtx_endpoint:encode_validation_sidecar(Hints),
    byte_size(term_to_binary(WireHints, [deterministic])).

%% decode_dtx_wave checked canonical bytes; acceptable_payload authenticated
%% their author and admission. Own vote echoes join existing selection/journal
%% custody; other authors keep their exact signed envelope in shared retention.
retain_relayed_dtx_control(Control, Envelope, ValidationSidecar, S) ->
    Mode = case local_owned_vote(Control, S) of
        true -> select;
        false -> {signed, Control, Envelope}
    end,
    retain_dtx_submission(quod_atomic:control_material(Control), none,
                          ValidationSidecar, Mode, S).

retain_dtx_submission(Material = {Record, Digest, _}, Waiter, ValidationSidecar,
                      NewSubmission,
                      S = #s{retained_dtx = Registry}) ->
    Kind = quod_atomic:record_kind(Record),
    case retention_disposition(Material, S) of
        {included, Ref} ->
            %% No signature, registry row or proposal for already-certified
            %% work. The ordinary response carries its exact reference; the
            %% consumer verifies it through the existing evidence resolver.
            Waiters = [{dtx_endpoint, Pid} || Pid <- maps:keys(dtx_waiter_set(Waiter))],
            {ok, reply_waiters(Waiters, {ok, Ref, []}, S)};
        stale ->
            {error, stale_dtx_submission};
        _ when Kind =:= vote, NewSubmission =:= select ->
            admit_owned_vote(Material, Waiter, S);
        _Retained ->
            case maps:get(Digest, quod_dtx_owner:rows(Registry), undefined) of
                Existing = #dtx_submission{} ->
                    Updated = merge_submission_validation_sidecar(
                                Existing, ValidationSidecar),
                    Registry0 = quod_dtx_owner:replace(Updated, Registry),
                    case quod_dtx_owner:attach_waiter(Digest, Waiter, Registry0) of
                        {ok, Registry1} ->
                            {ok, schedule_dtx_drive(
                                   S#s{retained_dtx = Registry1})};
                        {error, Reason} ->
                            {error, Reason}
                    end;
                undefined ->
                    Hints = relevant_control_validation_sidecar(
                              Record, ValidationSidecar),
                    case NewSubmission of
                        Mode when Mode =:= sign; Mode =:= select ->
                            sign_and_retain_dtx(
                              Material, Waiter, Hints, none, S);
                        {signed, Control, Envelope} ->
                            install_dtx_submission(
                              Material, Control, Envelope,
                              Waiter, Hints, none, S)
                    end
            end
    end.

schedule_dtx_drive(S = #s{dtx_drive_scheduled = true}) ->
    S;
schedule_dtx_drive(S) ->
    self() ! dtx_drive,
    S#s{dtx_drive_scheduled = true}.

%% One monotone admission rule: indexed inclusion before active readiness.
%% The index is already current in this owner turn; no history replay, copied
%% inventory or additional process is needed to recognize a late delivery.
retention_disposition(Material = {Record, _, _}, S) ->
    GroupId = quod_atomic:group_id(Record),
    quod_dtx_owner:admission(
      Material, retention_history(GroupId, S), S#s.dtx_projection).

-ifdef(TEST).
retention_history(_GroupId, #s{phase_index = undefined}) ->
    quod_atomic:initial_group_history();
retention_history(GroupId, S) -> indexed_retention_history(GroupId, S).
-else.
retention_history(GroupId, S) -> indexed_retention_history(GroupId, S).
-endif.

indexed_retention_history(GroupId, #s{phase_index = Index}) ->
    {ok, History} = quod_dtx_phase_index:history(Index, GroupId),
    History.

retained_placement(ready) -> ready;
retained_placement({blocked, _}) -> blocked;
retained_placement(stale) -> error(stale_retained_dtx).

sign_and_retain_dtx(Material = {Record, _, _}, Waiter, ValidationSidecar, OldSequence,
                    S = #s{id = Signer, self = Self,
                           signing_journal = Journal,
                           dtx_lanes = CommittedFloors}) ->
    case current_dtx_binding(S) of
        {ok, {_Ns, _Anchor, Self, Admission}} ->
            Lane = {Admission, Self},
            LocalFloor = quod_signing_journal:dtx_floor(Journal, Lane),
            CommittedFloor = maps:get(Lane, CommittedFloors, 0),
            Floor = erlang:max(LocalFloor, CommittedFloor),
            Sequence = Floor + 1,
            case advance_signed_sequence(
                   dtx, Lane, Sequence, #{Lane => Floor}, #{}) of
                {ok, _Seen} ->
                    case quod_atomic:sign_control(
                           target_identity(S), Material, Admission, Sequence,
                           quod_time:now_ms(), Signer) of
                        {ok, Control} ->
                            {ok, Journal1, Envelope} =
                                quod_signing_journal:record_dtx(
                                  Journal, Control),
                            ok = maybe_project_pending_votes(
                                   quod_atomic:record_kind(Record), S#s.ns, Journal1),
                            install_dtx_submission(
                              Material, Control, Envelope, Waiter,
                              ValidationSidecar, OldSequence,
                              S#s{signing_journal = Journal1});
                        {error, Reason} ->
                            {error, Reason}
                    end;
                error ->
                    {error, stale_sequence}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

install_dtx_submission(Material = {_Record, Digest, _}, Control, Envelope, Waiter,
                       ValidationSidecar, OldSequence,
                       S = #s{retained_dtx = Registry}) ->
    InsertedAt = quod_time:mono_ms(),
    Submission =
        #dtx_submission{
          control = Control, envelope = Envelope,
          group_id = quod_atomic:group_id(Control), digest = Digest,
          inserted_at = InsertedAt,
          observation_started_at = InsertedAt,
          trace_ctx = quod_trace:context(),
          validation_sidecar = ValidationSidecar,
          placement = retained_installation_placement(
                        Material, Control, OldSequence, S),
          bytes = byte_size(Envelope) +
              validation_sidecar_bytes(ValidationSidecar),
          waiters = dtx_waiter_set(Waiter)},
    {ok, schedule_dtx_drive(
           S#s{retained_dtx = quod_dtx_owner:put_new(Submission, Registry)})}.

%% A committed phase has no place in volatile proposal custody, whether its
%% exact digest or an equivalent reference variant won. Reuse admission's
%% bounded index lookup; never infer freshness from active-row absence.
retained_disposition(Material, S) ->
    case retention_disposition(Material, S) of
        {included, _} -> stale;
        Other -> Other
    end.

retained_installation_placement(Material = {Record, Digest, _}, Control, OldSequence, S) ->
    Disposition = retained_disposition(Material, S),
    case Disposition of
        stale ->
            %% Emit the bounded identifiers before the ordinary invariant
            %% exception. No state/journal/control dump and no hidden recovery;
            %% the existing formatter still sanitizes and bounds the report.
            Meta = quod_atomic:control_metadata(Control),
            Lane = {maps:get(author_admission, Meta), maps:get(author, Meta)},
            logger:error(quod_log_formatter:redact(
              #{event => stale_retained_dtx,
                namespace => retained_diagnostic_namespace(S#s.ns),
                group_digest => binary:encode_hex(quod_atomic:group_id(Control)),
                record_digest => binary:encode_hex(Digest),
                phase => quod_atomic:record_kind(Record),
                committed_height => S#s.slot,
                old_sequence => OldSequence,
                proposed_sequence => maps:get(sequence, Meta),
                committed_floor => maps:get(Lane, S#s.dtx_lanes, 0),
                readiness => stale}));
        _ -> ok
    end,
    retained_placement(Disposition).

retained_diagnostic_namespace(Ns) when byte_size(Ns) =< 255 -> Ns;
retained_diagnostic_namespace(Ns) ->
    {truncated, binary:part(Ns, 0, 255), byte_size(Ns)}.

-ifdef(TEST).
pending_votes_snapshot(memory) -> #{};
pending_votes_snapshot(Journal) ->
    quod_signing_journal:pending_dtx(Journal).
-else.
pending_votes_snapshot(Journal) ->
    quod_signing_journal:pending_dtx(Journal).
-endif.

pending_vote_rows(PendingVotes) ->
    [maps:get(group_ref, Pending)
     || {_GroupId, Pending} <- lists:sort(maps:to_list(PendingVotes))].

project_pending_votes(Ns, Journal) ->
    quod_prolog:project_pending_votes(
      Ns, pending_vote_rows(pending_votes_snapshot(Journal))).

maybe_project_pending_votes(vote, Ns, Journal) ->
    project_pending_votes(Ns, Journal);
maybe_project_pending_votes(_Kind, _Ns, _Journal) ->
    ok.

dtx_waiter_set(none) -> #{};
dtx_waiter_set({dtx_endpoint, Pid}) when is_pid(Pid) -> #{Pid => true}.

refresh_retained_readiness(SBefore) ->
    S0 = #s{retained_dtx = Registry, dtx_projection = Projection} = reselect_owned_votes(SBefore),
    {Classified, Retired} = quod_dtx_owner:classify(
      {S0#s.history_head, Projection}, fun(M) -> retained_disposition(M, S0) end, Registry),
    lists:foldl(
      fun({Row, Reason}, {S, Pending}) ->
          case Reason =:= {refused, conflict} andalso local_owned_vote(Row, S) of
              true -> {queue_detached_vote(Row, S), Pending};
              false ->
                  {Next, Cleared} = finish_detached_retained_dtx(Row, stale, {error, retry}, S),
                  {Next, merge_pending_votes_reconciliation(Pending, Cleared)}
          end
      end, {S0#s{retained_dtx = Classified}, none}, Retired).

%% The parent/deadline token is a cache binding, not another validation path.
%% Remove a local signed row before transferring it to the same FIFO; retain
%% its exact envelope there so an unchanged choice requires no new signature.
reselect_owned_votes(S0) ->
    lists:foldl(fun(Row = #dtx_submission{control = C, selection = Selected}, S) ->
        case local_owned_vote(Row, S) of
            false -> S;
            true ->
                Engine = case quod_reg:where({quod_prolog, S0#s.ns}) of undefined -> none; P -> P end,
                M = quod_atomic:control_material(C),
                Key = quod_atomic_admission:selection_key(
                            {Engine, S0#s.history_head}, vote_timestamp(S0), M),
                case Selected of
                    {Key, _} -> S;
                    _ ->
                        case retention_disposition(M, S) of
                            {included, _} -> S;
                            stale -> S;
                            _ -> requeue_owned_vote(Row, S)
                        end
                end
        end
    end, S0, maps:values(quod_dtx_owner:rows(S0#s.retained_dtx))).

requeue_owned_vote(Row = #dtx_submission{digest = Digest}, S) ->
    {Row, Registry} = quod_dtx_owner:take(Digest, S#s.retained_dtx),
    queue_detached_vote(Row, S#s{retained_dtx = Registry}).

local_owned_vote(#dtx_submission{control = C}, S) -> local_owned_vote(C, S);
local_owned_vote(C, #s{self = Self}) ->
    quod_atomic:control_kind(C) =:= vote andalso
      maps:get(author, quod_atomic:control_metadata(C)) =:= Self.

queue_detached_vote(Row, S) ->
    A = admission_state(S),
    S#s{dtx_admission = A#dtx_admission{waiting =
        quod_atomic_admission:recheck(Row, A#dtx_admission.waiting)}}.

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
         relay_pending = Pending, author_seqs = AuthorSeqs,
         dtx_projection = DtxProjection}) ->
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
     CustodyPendingCount, CustodyAuthorSeqs, DtxProjection}.

ingress_view_facts(
  S = #s{self = Self, slot = Durable,
         approved = Approved, committee_id = CommitteeId,
         custody_lane = CustodyLane, custody_ready = CustodyReady,
         relay_pending = Pending}) ->
    Floor = Approved + 1,
    Validators = active_validators(S),
    Barrier = consensus_barrier(S),
    #{self => Self,
      capability => ingress_capability(S),
      committee_id => CommitteeId,
      validators => Validators,
      durable_head => Durable,
      approved => Approved,
      proposal_visible => proposal_visible(Floor, S),
      proposal_slot => proposal_slot(S, Barrier),
      consensus_barrier => Barrier,
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
    case content_ingress_disposition(Change, Decision, S) of
        {park, Cause} ->
            park_ingress(Origin, Cause, From, Request, Anchor, S);
        ready ->
            execute_ready(
              Pass, Origin, From, Request, Anchor, Decision,
              Change, Membership, S)
    end.

content_ingress_disposition(_Change, {reject, _Why}, _S) -> ready;
content_ingress_disposition(_Change, {park, _Cause}, _S) -> ready;
content_ingress_disposition(Change, _Decision,
                            #s{dtx_projection = Projection}) ->
    case quod_atomic:content_readiness(Change, Projection) of
        ready -> ready;
        {blocked, active_group} -> {park, dtx_conflict}
    end.

execute_ready(Pass, Origin, From, Request, Anchor, Decision,
              Change, Membership, S) ->
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
        {ok, Signed, Submission, S1} ->
            SubmissionId = quod_transaction:submission_id(Submission),
            Bytes = byte_size(term_to_binary(Submission, [deterministic])),
            Bound = bind_waiter_submission_id(From, SubmissionId),
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
                        {error, bad_change, S2} ->
                            reject_append(Bound, bad_change, S2)
                    end
            end
    end.

retain_custody(Waiter, Change, Submission, SubmissionId, Bytes, Anchor,
               S = #s{custody = Custody,
                      custody_deadlines = Deadlines,
                      relay_timeout_ms = RelayTimeout}) ->
    case maps:is_key(SubmissionId, Custody) of
        true ->
            {error, bad_change, S};
        false ->
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
%% the same key again; a later view or lane transition retries it.
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

%% An effect-bearing remote claim uses the ordinary content lane, but its signed
%% envelope is custody-owned before the proof worker is allowed to continue.
%% This is one idempotent hand-off: an exact retained semantic transaction is
%% success, and a different continuous admission can never re-sign it.
register_dormant_transaction(
  <<_:256>> = ExpectedAdmission,
  #transaction{tx_id = <<_:256>> = TxId,
               author_seq = 0, sig = none} = Change,
  Owner, S = #s{self = Self, custody = Custody})
  when is_pid(Owner) ->
    case {current_dtx_binding(S),
          find_transaction_custody(TxId, Change, Custody)} of
        {{ok, {_Ns, _Anchor, Self, ExpectedAdmission}},
         {ok, SubmissionId}} ->
            {ok, (maps:get(SubmissionId, Custody))#custody.submission, S};
        {{ok, {_Ns, _Anchor, Self, ExpectedAdmission}}, not_found} ->
            case local_change_acceptable(Change, S) of
                false -> {error, busy, S};
                true -> sign_and_retain_dormant(Change, Owner, S)
            end;
        {{ok, {_Ns, _Anchor, Self, _OtherAdmission}}, _} ->
            {error, not_in_charge, S};
        _ ->
            {error, not_in_charge, S}
    end;
register_dormant_transaction(_Admission, _Change, _Owner, S) ->
    {error, bad_change, S}.

sign_and_retain_dormant(Change, Owner, S0) ->
    case sign_local_change(Change, none, S0) of
        {ok, Signed, Submission, S1} ->
            case quod_transaction:encode_operation_submission(Submission) of
                {ok, _SubmissionBlob} ->
                    {ok, Journal1} = quod_signing_journal:record_transaction(
                                       S1#s.signing_journal,
                                       Signed, Submission, dormant),
                    SubmissionId = quod_transaction:submission_id(Submission),
                    Envelope = term_to_binary(Submission, [deterministic]),
                    Bytes = byte_size(Envelope),
                    TxId = Signed#transaction.tx_id,
                    Waiter = #waiter{
                               reply_to = {transaction_custody, TxId},
                               submission_id = SubmissionId,
                               trace_ctx = otel_ctx:new(),
                               trace_span = undefined},
                    OwnerMonitor = erlang:monitor(process, Owner),
                    Record = #custody{
                               waiter = Waiter, change = Signed,
                               submission = Submission,
                               original_arrival = quod_time:mono_ms(),
                               deadline = ?MAX_SLOT, placement = dormant,
                               dormant_owner = {Owner, OwnerMonitor},
                               bytes = Bytes},
                    {ok, Submission,
                     S1#s{
                       signing_journal = Journal1,
                       custody = (S1#s.custody)#{SubmissionId => Record},
                       custody_deadlines = gb_sets:add_element(
                                             {?MAX_SLOT, SubmissionId},
                                             S1#s.custody_deadlines),
                       custody_bytes = S1#s.custody_bytes + Bytes}};
                {error, _} ->
                    %% Registration owns only signed remote operation claims.
                    %% Reject before any volatile custody or owner monitor is
                    %% installed; the signing journal retains no malformed row.
                    {error, bad_change, S0}
            end;
        {error, _} ->
            {error, bad_change, S0}
    end.

start_dormant_transaction_cancellation(TxId, Caller, S) ->
    start_dormant_transaction_cancellation(
      TxId, Caller, S, fun start_dormant_cancellation_owner/2).

start_dormant_transaction_cancellation(
  TxId, Caller, S = #s{custody = Custody}, Start) when is_pid(Caller) ->
    case transaction_custody_by_id(TxId, Custody) of
        {ok, SubmissionId,
         Record = #custody{placement = dormant,
                           dormant_owner = {Caller, _Monitor}}} ->
            begin_transaction_custody_cancellation(
              SubmissionId, Record, S, Start);
        {ok, _SubmissionId,
         #custody{placement = dormant}} ->
            {error, not_in_charge, S};
        {ok, _SubmissionId,
         #custody{placement = {cancelling, Caller, _Monitor}}} ->
            %% The exact cancellation owner observes its existing transition.
            {ok, S};
        {ok, _SubmissionId,
         #custody{placement = {cancelling, _Pid, _Monitor}}} ->
            {error, not_in_charge, S};
        {ok, _SubmissionId, #custody{}} ->
            {error, already_active, S};
        not_found ->
            {error, not_found, S}
    end;
start_dormant_transaction_cancellation(_TxId, _Caller, S, _Start) ->
    {error, not_in_charge, S}.

begin_transaction_custody_cancellation(
  SubmissionId, Record = #custody{submission = Submission},
  S = #s{ns = Ns}, Start) ->
    case Start(Ns, Submission) of
        {ok, Pid, Monitor} ->
            S1 = withdraw_transaction_custody(SubmissionId, Record, S),
            Current = maps:get(SubmissionId, S1#s.custody),
            Record1 = clear_dormant_owner(Current),
            {ok,
             S1#s{custody = (S1#s.custody)#{
                 SubmissionId =>
                     Record1#custody{
                       placement = {cancelling, Pid, Monitor}}}}};
        {error, Reason} ->
            {error, Reason, S}
    end.

start_dormant_cancellation_owner(Ns, Submission) ->
    case quod_dtx_coordinator:start_dormant_operation_monitor(
           self(), Ns, Submission) of
        {ok, Pid} -> {ok, Pid, erlang:monitor(process, Pid)};
        {error, _} = Error -> Error
    end.

%% Both the proof worker that registered dormant custody and the coordinator
%% that cancels it are process-owned edges. Their exact monitor is serialized
%% here with activation/cancellation calls in this statem, so no timer or
%% second cleanup authority is needed.
restart_dormant_custody_owner(Ref, Pid, S) ->
    restart_dormant_custody_owner(
      Ref, Pid, S, fun start_dormant_cancellation_owner/2).

restart_dormant_custody_owner(
  Ref, Pid, S = #s{custody = Custody}, Start) ->
    case dormant_custody_monitor(Ref, Pid, Custody) of
        {registration, SubmissionId,
         Record = #custody{change = #transaction{}}} ->
            Record1 = Record#custody{dormant_owner = none},
            S1 = S#s{custody = Custody#{SubmissionId => Record1}},
            case begin_transaction_custody_cancellation(
                   SubmissionId, Record1, S1, Start) of
                {ok, S2} -> {true, S2};
                {error, Reason, _} ->
                    error({dormant_operation_owner_down, Reason})
            end;
        {cancellation, SubmissionId,
         Record = #custody{change = #transaction{}}} ->
            %% The DOWN consumed this coordinator monitor. Return the exact
            %% custody to dormant only as an internal transition, then start
            %% its sole replacement immediately from the retained Submission.
            Record1 = Record#custody{placement = dormant},
            S1 = S#s{custody = Custody#{SubmissionId => Record1}},
            case begin_transaction_custody_cancellation(
                   SubmissionId, Record1, S1, Start) of
                {ok, S2} -> {true, S2};
                {error, Reason, _} ->
                    error({dormant_operation_restart, Reason})
            end;
        not_found ->
            false
    end.

dormant_custody_monitor(Ref, Pid, Custody) ->
    Matches =
        maps:fold(
          fun(SubmissionId,
              Record = #custody{placement = Placement,
                                dormant_owner = DormantOwner}, Acc) ->
                  case {DormantOwner, Placement} of
                      {{Pid, Ref}, dormant} ->
                          [{registration, SubmissionId, Record} | Acc];
                      {none, {cancelling, Pid, Ref}} ->
                          [{cancellation, SubmissionId, Record} | Acc];
                      _ -> Acc
                  end
          end, [], Custody),
    case Matches of
        [Match] -> Match;
        [] -> not_found;
        _ -> error({dormant_custody_monitor_conflict, Ref, Pid})
    end.

clear_dormant_owner(Record = #custody{dormant_owner = none}) ->
    Record;
clear_dormant_owner(
  Record = #custody{dormant_owner = {_Owner, Monitor}}) ->
    _ = erlang:demonitor(Monitor, [flush]),
    Record#custody{dormant_owner = none}.

activate_dormant_transaction(
  TxId, Caller, From, S = #s{custody = Custody,
               custody_ready = Ready,
               signing_journal = Journal0}) ->
    case transaction_custody_by_id(TxId, Custody) of
        {ok, SubmissionId,
         Record = #custody{placement = dormant, change = Change,
                           waiter = Waiter0,
                           dormant_owner = {Caller, _Monitor}}} ->
            %% `bound` is fsynced before activation. A crash between these
            %% two records restores the exact transaction into the ready
            %% queue; it can never forget that the target prerequisite was
            %% durable and can never activate a merely registered intent.
            {ok, JournalBound} = quod_signing_journal:bind_transaction(
                                   Journal0, TxId),
            {ok, Journal1} = quod_signing_journal:activate_transaction(
                               JournalBound, TxId),
            ReadyKey = {Change#transaction.author_seq, SubmissionId},
            Waiter = Waiter0#waiter{reply_to = From},
            Record1 = clear_dormant_owner(Record),
            {ok,
             S#s{signing_journal = Journal1,
                 custody = Custody#{SubmissionId =>
                    Record1#custody{placement = ready, waiter = Waiter}},
                 custody_ready = gb_sets:add_element(ReadyKey, Ready)}};
        {ok, _SubmissionId,
         #custody{placement = dormant}} ->
            {error, not_in_charge, S};
        {ok, _SubmissionId, #custody{placement = ready}} ->
            {error, already_active, S};
        {ok, _SubmissionId, #custody{}} ->
            {error, already_active, S};
        not_found ->
            {error, not_found, S}
    end.

cancel_dormant_transaction(
  TxId, Caller,
  S = #s{custody = Custody, signing_journal = Journal0}) ->
    case transaction_custody_by_id(TxId, Custody) of
        {ok, SubmissionId,
         #custody{placement = {cancelling, Caller, _Monitor}}} ->
            retire_dormant_transaction_custody(
              SubmissionId, TxId, Journal0, S);
        {ok, _SubmissionId,
         #custody{placement = dormant}} ->
            {error, not_in_charge, S};
        {ok, _SubmissionId,
         #custody{placement = {cancelling, _Pid, _Monitor}}} ->
            {error, not_in_charge, S};
        {ok, _SubmissionId, #custody{}} ->
            {error, already_active, S};
        not_found ->
            {error, not_found, S}
    end.

retire_dormant_transaction_custody(SubmissionId, TxId, Journal0, S) ->
    S1 = complete_custody(SubmissionId, {error, cancelled}, S),
    {ok, Journal1} = quod_signing_journal:retire_transaction(
                       Journal0, TxId),
    {ok, S1#s{signing_journal = Journal1}}.

operation_custody_record(#custody{submission = Submission}) ->
    operation_custody_submission(Submission).

operation_custody_submission(Submission) ->
    case quod_transaction:encode_operation_submission(Submission) of
        {ok, _Blob} -> true;
        {error, invalid_operation_submission} -> false
    end.

operation_custody_row(#{envelope := Envelope}) when is_binary(Envelope) ->
    try binary_to_term(Envelope, [safe]) of
        Submission -> operation_custody_submission(Submission)
    catch _:_ ->
        error(invalid_transaction_signing_custody)
    end;
operation_custody_row(_Row) ->
    error(invalid_transaction_signing_custody).

ensure_operation_custody_cancellation(
  TxId, S = #s{custody = Custody}) ->
    case transaction_custody_by_id(TxId, Custody) of
        {ok, _SubmissionId,
         #custody{placement = {cancelling, _Pid, _Monitor}}} ->
            S;
        {ok, SubmissionId, Record} ->
            case operation_custody_record(Record) of
                true ->
                    case begin_transaction_custody_cancellation(
                           SubmissionId, Record, S,
                           fun start_dormant_cancellation_owner/2) of
                        {ok, S1} -> S1;
                        {error, Reason, _} ->
                            error({operation_custody_cancellation, Reason})
                    end;
                false ->
                    error({invalid_operation_custody, TxId})
            end;
        not_found ->
            %% During boot the durable journal is reconciled before volatile
            %% custody is reconstructed. Preserve the row; restore_signing_state
            %% below installs its sole cancellation owner from the recorded
            %% admission-bound Submission.
            S
    end.

transaction_custody_by_id(TxId, Custody) ->
    case [{SubmissionId, Record}
          || {SubmissionId,
              #custody{change = #transaction{tx_id = RowTxId}} = Record}
                 <- maps:to_list(Custody),
             RowTxId =:= TxId] of
        [{SubmissionId, Record}] -> {ok, SubmissionId, Record};
        [] -> not_found;
        _ -> error({transaction_custody_conflict, TxId})
    end.

find_transaction_custody(TxId, Expected, Custody) ->
    case transaction_custody_by_id(TxId, Custody) of
        {ok, SubmissionId, #custody{change = Change}} ->
            case unsigned_envelope(Change) =:= Expected of
                true -> {ok, SubmissionId};
                false -> error(transaction_custody_conflict)
            end;
        not_found -> not_found
    end.

handoff_effect_change(
  <<_:256>> = ExpectedAdmission,
  #transaction{tx_id = <<_:256>> = TxId, effects = [_],
               author_seq = 0, sig = none} = Change,
  S = #s{self = Self, custody = Custody}) ->
    case {current_dtx_binding(S), find_effect_custody(TxId, Change, Custody)} of
        {{ok, {_Ns, _Anchor, Self, ExpectedAdmission}}, {ok, _SubmissionId}} ->
            {ok, S};
        {{ok, {_Ns, _Anchor, Self, ExpectedAdmission}}, not_found} ->
            case local_change_acceptable(Change, S) of
                false -> {error, busy, S};
                true -> sign_and_retain_effect(Change, S)
            end;
        {{ok, {_Ns, _Anchor, Self, _OtherAdmission}}, _} ->
            {error, not_in_charge, S};
        _ ->
            {error, not_in_charge, S}
    end;
handoff_effect_change(_Admission, _Change, S) ->
    {error, bad_change, S}.

find_effect_custody(TxId, Expected, Custody) ->
    Matches =
        [SubmissionId
         || {SubmissionId, #custody{change = Change}} <- maps:to_list(Custody),
            Change#transaction.tx_id =:= TxId,
            unsigned_envelope(Change) =:= Expected],
    case Matches of
        [SubmissionId] -> {ok, SubmissionId};
        [] -> not_found;
        _ -> error(effect_custody_conflict)
    end.

unsigned_envelope(Change = #transaction{}) ->
    Change#transaction{author_seq = 0, sig = none, signed_bytes = none,
                       authentication = none}.

sign_and_retain_effect(Change, S0) ->
    case sign_local_change(Change, S0) of
        {ok, Signed, Submission, S1} ->
            SubmissionId = quod_transaction:submission_id(Submission),
            Envelope = term_to_binary(Submission, [deterministic]),
            Bytes = byte_size(Envelope),
            Waiter = #waiter{reply_to =
                                 {effect_custody, Change#transaction.tx_id},
                             submission_id = SubmissionId,
                             trace_ctx = otel_ctx:new(),
                             trace_span = undefined},
            Record = #custody{waiter = Waiter, change = Signed,
                              submission = Submission,
                              original_arrival = quod_time:mono_ms(),
                              deadline = ?MAX_SLOT, bytes = Bytes},
            Custody = S1#s.custody,
            Ready = S1#s.custody_ready,
            Deadlines = S1#s.custody_deadlines,
            S2 = S1#s{custody = Custody#{SubmissionId => Record},
                      custody_ready = gb_sets:add_element(
                                          {Signed#transaction.author_seq,
                                           SubmissionId}, Ready),
                      custody_deadlines = gb_sets:add_element(
                                             {?MAX_SLOT, SubmissionId},
                                             Deadlines),
                      custody_bytes = S1#s.custody_bytes + Bytes},
            {ok, S2};
        {error, _} ->
            {error, bad_change, S0}
    end.

%% The local append API accepts only a structurally valid unsigned transaction
%% authored by this node. Routing reserves bounded signature-growth headroom;
%% the item is signed exactly once when it leaves the unsigned queue, before it
%% enters custody, batching, or relay. Custody owns accepted submissions until
%% their individual deadlines; its byte/depth counters are observability, not
%% compiled refusal thresholds.
local_change_acceptable(
  #transaction{author = Self, sig = none} = Change,
  #s{self = Self} = S) ->
    ingress_change_acceptable(Change, S);
local_change_acceptable(_Change, _S) ->
    false.

sign_local_change(Change, S) ->
    sign_local_change(Change, ready, S).

sign_local_change(#transaction{author = Self, sig = none} = Change,
                  InitialState,
                  #s{self = Self, id = #{pubkey := Self} = Id,
                     next_author_seq = Seq} = S)
  when (InitialState =:= none orelse InitialState =:= dormant
        orelse InitialState =:= ready),
       is_binary(Self), byte_size(Self) =:= 32 ->
    case binding(S, Self) of
        {ok, TargetBinding} ->
            case quod_transaction:sign_submission(
                   TargetBinding, Change#transaction{author_seq = Seq}, Id) of
                {ok, Signed, Submission} ->
                    case Signed#transaction.effects of
                        [] ->
                            {ok, Signed, Submission,
                             S#s{next_author_seq = Seq + 1}};
                        [_Effect] when InitialState =:= none ->
                            {ok, Signed, Submission,
                             S#s{next_author_seq = Seq + 1}};
                        [_Effect] ->
                            {ok, Journal1} =
                                quod_signing_journal:record_transaction(
                                  S#s.signing_journal, Signed, Submission,
                                  InitialState),
                            {ok, Signed, Submission,
                             S#s{next_author_seq = Seq + 1,
                                 signing_journal = Journal1}}
                    end;
                {error, _} = Error -> Error
            end;
        error ->
            {error, unknown_author}
    end;
sign_local_change(#transaction{}, _InitialState, _S) ->
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
%% from that author is held too, preserving signed author-sequence order. Consensus
%% barriers are global: an in-flight barrier or a queued membership change stops the
%% pass so the pipeline must quiesce and the committee transition cannot starve. Held
%% items retain their relative order, so TTL expiry remains oldest-first.
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

%% Retire a whole consensus lane in one bounded pass. Dormant operation custody
%% and its cancellation owner are not lane placements and remain untouched.
%% Build the sole ordered index once and remove only relay attempts named by
%% records that belonged to the retired lane.
mark_custody_lane_ready(
  S = #s{custody = Custody, relay_pending = Pending}) ->
    {Custody1, Pending1, ReadyKeys} =
        maps:fold(
          fun(SubmissionId,
              Record = #custody{placement = Placement,
                                change = Change},
              {CustodyAcc, PendingAcc, KeysAcc}) ->
                  case Placement of
                      dormant ->
                          {CustodyAcc#{SubmissionId => Record},
                           PendingAcc, KeysAcc};
                      {cancelling, _Pid, _Monitor} ->
                          {CustodyAcc#{SubmissionId => Record},
                           PendingAcc, KeysAcc};
                      {relay, AttemptId, _Target,
                       _Slot, _CommitteeId} ->
                          {CustodyAcc#{
                             SubmissionId =>
                                 Record#custody{placement = ready}},
                           maps:remove(AttemptId, PendingAcc),
                           [{Change#transaction.author_seq,
                             SubmissionId} | KeysAcc]};
                      ready ->
                          {CustodyAcc#{SubmissionId => Record},
                           PendingAcc,
                           [{Change#transaction.author_seq,
                             SubmissionId} | KeysAcc]};
                      {local, _Slot, _CommitteeId} ->
                          {CustodyAcc#{
                             SubmissionId =>
                                 Record#custody{placement = ready}},
                           PendingAcc,
                           [{Change#transaction.author_seq,
                             SubmissionId} | KeysAcc]}
                  end
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
%% and completion, so it tracks exactly the live custody rows.
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
                    case maps:is_key(AttemptId, Pending) of
                        true when is_binary(CustodyId) ->
                            %% A stale/idempotent attempt collision cannot
                            %% release retained content or classify it as bad.
                            {defer_custody_placement(CustodyId, S), []};
                        true ->
                            reject_append(From, bad_change, S);
                        false ->
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
                                             Anchor + RelayTimeout, S)},
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

relay_submission(undefined, _Ns, Change, S) ->
    transaction_submission(S, Change);
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
%% A durable support latch also keeps a restarted leader on its exact retained
%% proposal; proposal construction may never compete with its own prior signature.
proposal_slot(S = #s{}) ->
    proposal_slot(S, consensus_barrier(S)).

proposal_slot(S = #s{slot = Committed, approved = Approved,
                     collecting = Collecting,
                     local_proposals = Local, commit_buf = Buf},
              ConsensusBarrier) ->
    Next = Approved + 1,
    HasBatch = case Collecting of #batch{slot = Next} -> true; _ -> false end,
    Open = live_pipeline_slot(Next, Committed)
           andalso (HasBatch orelse not maps:is_key(Next, Local))
           andalso not maps:is_key(Next, Buf)
           andalso not proposal_visible(Next, S)
           andalso not ConsensusBarrier,
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
    case {approved_author_seqs(S), operation_claim(Change)} of
        {error, _} ->
            reject_append(From, stale_seq, S);
        {_, error} ->
            reject_append(From, bad_change, S);
        {{ok, SequenceFloor}, Claim} ->
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
                               operation_claims = add_operation_claim(
                                                    Claim, #{}),
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
                                          operation_claims = OperationClaims,
                                          sequences = Sequences,
                                          sequence_floor = SequenceFloor} = Batch}) ->
    Added = encoded_change_size(Change),
    TxId = Change#transaction.tx_id,
    case {maps:is_key(TxId, TxIds),
          classify_operation_claim(Change, OperationClaims)} of
        {true, _} ->
            retain_transaction_alias(From, S);
        {false, error} ->
            reject_append(From, bad_change, S);
        {false, {conflict, _OperationRef}} ->
            reject_append(From, bad_change, S);
        {false, {alias, OperationRef}} ->
            retain_operation_alias(From, OperationRef, S);
        {false, {new, OperationClaims1}} ->
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
                          operation_claims = OperationClaims1,
                          sequences = Sequences1},
                    S1 = S#s{
                           collecting = Batch1,
                           appends = S#s.appends + 1},
                    {S1, []}
            end
    end.

operation_claim(Change = #transaction{}) ->
    case quod_transaction:request_claim(Change) of
        none -> none;
        {ok, #{key := Key, digest := Digest,
               operation_ref := OperationRef}}
          when is_tuple(Key), is_binary(Digest), byte_size(Digest) =:= 32 ->
            {claim, Key, Digest, OperationRef};
        _ -> error
    end.

add_operation_claim(none, Claims) -> Claims;
add_operation_claim({claim, Key, Digest, OperationRef}, Claims) ->
    Claims#{Key => {Digest, OperationRef}}.

classify_operation_claim(Change, Claims) ->
    case operation_claim(Change) of
        none -> {new, Claims};
        error -> error;
        {claim, Key, Digest, _OperationRef} = Claim ->
            case maps:get(Key, Claims, undefined) of
                undefined -> {new, add_operation_claim(Claim, Claims)};
                {Digest, ExistingRef} -> {alias, ExistingRef};
                {_OtherDigest, ExistingRef} ->
                    {conflict, ExistingRef}
            end
    end.

%% The first candidate remains the sole ledger write.  A second local custody
%% record stays attached to the same slot and is released only after that slot
%% certifies the matching operation claim.  A relay source likewise keeps its
%% own custody until it observes the certified slot; the proposer owns no
%% second durable-status path.
retain_operation_alias(
  #waiter{reply_to = {custody, _SubmissionId}}, _OperationRef, S) ->
    {S, []};
retain_operation_alias(
  Waiter = #waiter{reply_to = {relay, #relay_ref{}}}, _OperationRef, S) ->
    reply_now(Waiter, {error, not_in_charge, none}, S);
retain_operation_alias(From, OperationRef, S) ->
    reply_now(From, {error, {outcome_unknown, OperationRef}}, S).

%% A semantic transaction id excludes the validator author envelope. If two
%% target validators submit the same T, the first envelope is the sole ledger
%% item and every other validator keeps its own durable custody until that T is
%% observed in committed history. No validator is selected as a special owner.
retain_transaction_alias(
  #waiter{reply_to = {custody, _SubmissionId}}, S) ->
    {S, []};
retain_transaction_alias(
  #waiter{reply_to = {relay, #relay_ref{}}}, S) ->
    {S, []};
retain_transaction_alias(From, S) ->
    reject_append(From, bad_change, S).

advance_transaction_sequence(
  #transaction{author = Author, author_seq = Seq},
  SequenceFloor, Seen)
  when is_integer(Seq), Seq > 0 ->
    advance_signed_sequence(content, Author, Seq, SequenceFloor, Seen);
advance_transaction_sequence(_Change, _SequenceFloor, _Seen) ->
    error.

%% One allocator/check owns both signed sequence lanes. Content is keyed by
%% author; DTX is keyed by the admission-scoped `{Admission, Author}` lane.
%% The caller supplies the correct committed/journal floor projection, while
%% this function enforces the identical strictly-newer/no-duplicate rule.
advance_signed_sequence(Kind, Owner, Sequence, Floors, Seen)
  when (Kind =:= content orelse Kind =:= dtx),
       is_integer(Sequence), Sequence > 0, is_map(Floors), is_map(Seen) ->
    SeenKey = {Kind, Owner, Sequence},
    case Sequence > maps:get(Owner, Floors, 0)
             andalso not maps:is_key(SeenKey, Seen) of
        true -> {ok, Seen#{SeenKey => true}};
        false -> error
    end;
advance_signed_sequence(_Kind, _Owner, _Sequence, _Floors, _Seen) ->
    error.

flush_batch(Slot, S = #s{collecting = #batch{slot = Slot, parent = Parent,
                                              items_rev = ItemsRev,
                                              count = Count,
                                              opened_at = OpenedAt}}) ->
    Items = lists:reverse(ItemsRev),
    Transactions = [Change || {_From, Change} <- Items],
    case acceptable_collected_payload(Transactions, S) of
        false -> reject_collected_batch(Items, Count, S);
        true  -> propose_batch(Slot, Parent, Items, Transactions, Count,
                               max(0, quod_time:mono_ms() - OpenedAt), S)
    end;
flush_batch(_Slot, S) -> S.   %% stale named timeout after an early/full flush

propose_batch(Slot, Parent, Items, Transactions, Count, WaitMs, S) ->
    Waiters = [From || {From, _Change} <- Items],
    {ok, Block} = quod_ledger:new_block(
                    Slot, Parent, {batch, Transactions},
                    max(quod_time:now_ms(), parent_timestamp(Parent, S))),
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
    trace_block_event(
      Slot, BH, <<"consensus.proposal_created">>,
      #{'quod.consensus.parent' => Parent, 'quod.proposal.kind' => <<"content">>,
        'quod.batch.transactions' => Count, 'quod.batch.wait_ms' => WaitMs}, S1),
    S2 = broadcast({propose, Block, []}, S1),
    S3 = engine_step([{block, BH, Block}], S2),
    case block_for(BH, S3#s.eng) of
        #block{} -> watch_proposal(Slot, support_or_validate(Block, BH, S3));
        undefined -> S3
    end.

drive_retained_dtx(S = #s{dtx_drive_scheduled = true}) ->
    S;
drive_retained_dtx(S = #s{retained_dtx = Registry}) ->
    case quod_dtx_owner:count(Registry) of
        0 -> S;
        _ -> drive_retained_dtx_nonempty(S)
    end.

drive_retained_dtx_nonempty(S = #s{collecting = #batch{slot = Slot}}) ->
    %% A DTX barrier never discards already-accepted content. Seal that batch;
    %% the retained control takes the next legal slot.
    flush_batch(Slot, S);
drive_retained_dtx_nonempty(S) ->
    %% Classification has just used the installed projection in this owner
    %% turn. Check the slot before constructing a wave: while a prior proposal
    %% or validation is outstanding there is no candidate work to perform.
    case may_vote(S) andalso
         proposal_slot(S, consensus_barrier(S, ignore_retained_dtx)) of
        Blocked when Blocked =:= false; Blocked =:= blocked ->
            S;
        {ok, Slot} ->
            case dtx_slot_route(Slot, S) of
                blocked -> S;
                Route ->
                    case eligible_dtx_wave(Route, S) of
                        none -> S;
                        {Wave, Block} -> drive_dtx_route(Route, Wave, Block, S)
                    end
            end
    end.

eligible_dtx_wave(Route, S = #s{retained_dtx = Registry}) ->
    case quod_dtx_owner:ready_rows(Registry) of
        [] -> none;
        Ordered ->
            [{_FirstDigest,
              #dtx_submission{control = FirstControl}} | _] = Ordered,
            Phase = quod_atomic:control_kind(FirstControl),
            SamePhase =
                [Row || {_Digest, #dtx_submission{control = Control}} = Row
                            <- Ordered,
                        quod_atomic:control_kind(Control) =:= Phase],
            %% Placement is work eligibility, not just duplicate-send filtering.
            %% Keep the complete canonical phase for selection: a newly queued
            %% row must not bypass conflicts/size checks against placed rows.
            case unplaced_dtx_wave(Route, SamePhase, S) of
                [] -> none;
                _ -> select_dtx_wave(SamePhase, S, S#s.dtx_projection, #{}, {[], none})
            end
    end.

unplaced_dtx_wave(local, Wave, _S) -> Wave;
unplaced_dtx_wave({relay, Peer}, Wave, #s{conns = Conns}) ->
    Link = case maps:get(Peer, Conns, none) of {Pid, _} -> Pid; none -> none end,
    [{Digest, Row} || {Digest, #dtx_submission{relay_placement = Placement} = Row} <- Wave,
                      Placement =/= {Peer, Link}].

select_dtx_wave([], _S, _Projection, _SelectedGroups, {[], none}) -> none;
select_dtx_wave([], _S, _Projection, _SelectedGroups, {SelectedRev, Block}) ->
    {lists:reverse(SelectedRev), Block};
select_dtx_wave(
  [{_Digest, #dtx_submission{control = Control} = Row} = Candidate | Rest],
  S, Projection, SelectedGroups, {SelectedRev, _Block} = Selected) ->
    GroupId = quod_atomic:group_id(Control),
    case maps:is_key(GroupId, SelectedGroups) of
        true ->
            %% Every control advances one group by one phase. Alternative
            %% certified-reference proof subsets may produce different
            %% signed records for that same transition, but no reducer can
            %% apply both against one parent. Keep the canonical retained
            %% order and let the committed first transition retire the rest.
            select_dtx_wave(
              Rest, S, Projection, SelectedGroups, Selected);
        false ->
            Proposed = lists:reverse([Candidate | SelectedRev]),
            Payload = {batch, [{dtx, C} || {_, #dtx_submission{control = C}} <- Proposed]},
            case encoded_block_payload_fits(Payload)
                     andalso dtx_wave_candidate(Row, Proposed, Payload, S, Projection) of
                {ok, NextProjection, Block} ->
                    select_dtx_wave(
                      Rest, S, NextProjection, SelectedGroups#{GroupId => true},
                      {[Candidate | SelectedRev], Block});
                _ ->
                    select_dtx_wave(
                      Rest, S, Projection, SelectedGroups, Selected)
            end
    end.

%% One prospective fold, carrying only its returned projection. Rebuilding
%% every previously selected prefix repeats both authentication and reduction.
%% The installed owner state is never changed by this call-local preview.
dtx_wave_candidate(#dtx_submission{control = Control, selection = Selection} = Row,
                   Wave, Payload, S = #s{approved = Parent, ns = Ns}, Projection) ->
    Timestamp = vote_timestamp(S),
    Engine = case quod_reg:where({quod_prolog, Ns}) of undefined -> none; P -> P end,
    SelectionCurrent = not local_owned_vote(Row, S) orelse
        case Selection of
            {Key, _Basis} -> Key =:= quod_atomic_admission:selection_key(
                        {Engine, S#s.history_head}, Timestamp, quod_atomic:control_material(Control));
            none -> false
        end,
    %% The clock may cross the deadline between classification and this wave.
    %% A local cached choice must still match this exact prospective time;
    %% the existing tick reselects it, never backdates a proposal or signs here.
    Preview = case SelectionCurrent andalso quod_atomic:control_kind(Control) of
        false -> {error, stale_selection};
        vote ->
            Candidate = {Control, target_identity(S), S#s.approved + 1, <<0:256>>},
            case quod_atomic:preview_batch([Candidate], #{}, Projection) of
                {ok, _, Next, _} -> {ok, Next};
                {error, _} = Error -> Error
            end;
        _ -> {ok, Projection}
    end,
    case Preview of
        {ok, NextProjection} ->
            {ok, Block} = quod_ledger:new_block(Parent + 1, Parent, Payload, Timestamp),
            Required = [Hint || Hint = {{applied, _, _}, _} <- dtx_wave_validation_sidecar(Wave)],
            byte_size(encode(Ns, {propose, Block, Required})) =< ?QUOD_TRANSPORT_MAX_FRAME_BYTES
                andalso {ok, NextProjection, Block};
        {error, _} -> false
    end.

%% Relayed bytes cross the same atomic codec once. Native block construction
%% and its canonical size checks retain that authenticated material thereafter.
decode_dtx_wave(Envelopes) ->
    try
        {ok, {batch, [begin
            {ok, Control} = quod_atomic:decode_control(Envelope), {dtx, Control}
        end || Envelope <- Envelopes]}}
    catch _:_ -> error end.

%% Mixed local DTX waves use the ordinary local-proposal parent/link policy.
%% A consensus-relayed control has no request carrier on that channel; its
%% caller ancestry stays absent; opt-in owner diagnostics cover its boundaries.
dtx_control_trace_contexts(Controls, S) ->
    [retained_dtx_trace_context(quod_atomic:control_body(Control), S)
     || Control <- Controls].

drive_dtx_route(local, Wave, Block, S) ->
    propose_dtx_wave(Block, dtx_wave_validation_sidecar(Wave), S);
drive_dtx_route({relay, Peer}, Wave, _Block, S) ->
    send_dtx_relay(Peer, Wave, S).

dtx_wave_validation_sidecar(Wave) ->
    prioritize_validation_sidecar(
      lists:flatmap(
        fun({_Digest, #dtx_submission{control = Control,
                                      validation_sidecar = Hints}}) ->
                relevant_control_validation_sidecar(Control, Hints)
        end, Wave)).

dtx_slot_route(Slot, S = #s{self = Self}) ->
    case leader(Slot, active_validators(S)) of
        Self -> local;
        Peer when is_binary(Peer) ->
            %% The node transport can outlive this ontology process on the
            %% destination.  Place retained custody only after that exact
            %% committee peer has announced, on its authenticated inbound
            %% consensus generation, that it can receive the child slot.
            %% The readiness frame is also the event that re-drives a parked
            %% row through keep_progress/3; no relay retry path is needed.
            case peer_ready_at(
                   Peer, Slot - 1,
                   S#s.inbound_conns, S#s.peer_readiness) of
                true -> {relay, Peer};
                false -> blocked
            end;
        none -> blocked
    end.

propose_dtx_wave(Block = #block{slot = Slot, parent = Parent, payload = Payload},
                  ValidationSidecar0, S = #s{approved = Parent}) ->
    case acceptable_payload(Payload, S) of
        false -> S;
        true ->
            {controls, Classified} = quod_ledger:classify(Payload),
            Controls = [Control || {_Kind, Control} <- Classified],
            ValidationSidecar = fit_consensus_validation_sidecar(
                           S#s.ns,
                           fun(Hints) -> {propose, Block, Hints} end,
                           dtx_controls_validation_sidecar(
                             Controls, ValidationSidecar0)),
            BH = block_hash(Block),
            Local = #local_proposal{
                      hash = BH, validation_sidecar = ValidationSidecar,
                      trace_ctxs = dtx_control_trace_contexts(Controls, S)},
            S1 = S#s{
                   local_proposals =
                     (S#s.local_proposals)#{Slot => Local},
                   proposals = S#s.proposals + 1,
                   round_probe =
                     (S#s.round_probe)#{Slot =>
                                           {quod_time:mono_ms(), none}}},
            %% An ended submitter cannot accept another event. Record the
            %% actual proposal as its own boundary under the existing local
            %% proposal's parent/links, before any broadcast or local verdict.
            trace_block_event(
              Slot, BH, <<"consensus.proposal_created">>,
              #{'quod.consensus.parent' => Parent,
                'quod.proposal.kind' => <<"dtx">>,
                'quod.batch.transactions' => length(Controls)}, S1),
            S2 = broadcast({propose, Block, ValidationSidecar}, S1),
            %% Local and relayed leaders must enter through the same DTX
            %% candidate/validation path as an inbound leader proposal.  A
            %% DTX block is offered to the consensus engine only after that
            %% exact candidate's deterministic verdict is accepted.
            on_propose(BH, Block, ValidationSidecar, true, S2)
    end.

handle_dtx_submit(_Peer, Envelopes, _ValidationSidecar, S)
  when not is_list(Envelopes); Envelopes =:= [] ->
    S;
handle_dtx_submit(_Peer, Envelopes, ValidationSidecar, S) ->
    case decode_dtx_wave(Envelopes) of
        error -> S;
        {ok, Payload} -> handle_decoded_dtx_submit(Payload, Envelopes, ValidationSidecar, S)
    end.

handle_decoded_dtx_submit(Payload, Envelopes, ValidationSidecar, S) ->
    case acceptable_payload(Payload, S) of
        false -> S;
        true ->
            {controls, Classified} = quod_ledger:classify(Payload),
            %% The source remains the durable custody owner.  The current
            %% leader retains each already-authenticated signed control only
            %% as the transient input to the shared proposal owner; it must
            %% not replace the source author by signing the record again.
            lists:foldl(
              fun({{_Kind, Control}, Envelope}, Acc) ->
                      Hints = relevant_control_validation_sidecar(
                                Control, ValidationSidecar),
                      case retain_relayed_dtx_control(
                             Control, Envelope, Hints, Acc) of
                          {ok, Acc1} -> Acc1;
                          {error, _CurrentStateRefusal} -> Acc
                      end
              end, S, lists:zip(Classified, Envelopes))
    end.

dtx_controls_validation_sidecar(Controls, ValidationSidecar) ->
    prioritize_validation_sidecar(
      lists:flatmap(
        fun(Control) ->
                relevant_control_validation_sidecar(Control, ValidationSidecar)
        end, Controls)).

prioritize_validation_sidecar(Hints0) ->
    Hints = quod_dtx_endpoint:normalize_sidecar(Hints0),
    {Applied, Entries} = lists:partition(
                           fun({{applied, _, _}, _}) -> true;
                              (_) -> false
                           end, Hints),
    Applied ++ Entries.

update_dtx_submission(Digest, Submission,
                      S = #s{retained_dtx = Registry}) ->
    Digest = Submission#dtx_submission.digest,
    S#s{retained_dtx = quod_dtx_owner:replace(Submission, Registry)}.

reject_collected_batch(Items, Count, S) ->
    S1 = reply_waiters([From || {From, _Change} <- Items],
                       {error, bad_change}, S),
    S1#s{collecting = none, r_bad = S1#s.r_bad + Count}.

encoded_change_size(Change) ->
    case quod_transaction:encode_ledger_transaction(Change) of
        {ok, Blob} -> byte_size(Blob);
        {error, _} -> ?MAX_BLOCK_BYTES + 1
    end.

consensus_barrier(S) ->
    consensus_barrier(S, include_retained_dtx).

consensus_barrier(#s{slot = Committed, eng = #eng{tree = Tree},
                     rounds = Rounds,
                     retained_dtx = Registry}, RetainedMode) ->
    VolatileBlock =
        lists:any(fun({Sl, #block{payload = Payload}}) ->
                          Sl > Committed
                              andalso payload_is_consensus_barrier(Payload)
                  end, maps:to_list(Tree)),
    PendingDtx =
        lists:any(
          fun({Sl, Round}) ->
                  Sl > Committed andalso dtx_validation_active(Round)
          end, maps:to_list(Rounds)),
    RetainedDtx = RetainedMode =:= include_retained_dtx
                  andalso quod_dtx_owner:ready_count(Registry) > 0,
    VolatileBlock orelse PendingDtx orelse RetainedDtx.

%% Admission and proposal construction must classify the same prospective
%% block time. An approved parent may lead normal commit; the committed
%% frontier may lead the old engine during catch-up's journal reconciliation.
vote_timestamp(S = #s{approved = Approved, slot = Committed}) ->
    max(quod_time:now_ms(), parent_timestamp(max(Approved, Committed), S)).

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
apply_event({notarized, #block{slot = Slot} = Block}, S0) ->
    trace_block_event(Slot, engine_block_hash(Slot, S0),
                      <<"consensus.notarized">>, #{}, S0),
    choose_final_vote(Block#block.slot, notarized, approve_block(Block, S0));
%% A block is final: apply it, in slot order (out-of-order finalizations are buffered — contiguous apply).
apply_event({committed, Slot, Block}, S) ->
    trace_block_event(Slot, engine_block_hash(Slot, S),
                      <<"consensus.finality_received">>, #{}, S),
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

%% Persist the committed tagged payload byte-for-byte (durable before we ack), apply it into
%% quod_prolog, and advance the height. Content commits additionally resolve their batch callers;
%% DTX control records use their own durable coordinator path.
commit_block(Slot, #block{payload = Payload} = Block,
             S = #s{store = Store, eng = Eng}) ->
    BH = engine_block_hash(Slot, S),
    case persisted_finality(Slot, BH, Eng) of
        none -> weak_cert_wait(commit, Slot, BH, S);   %% Slice E: don't finalize on a sub-quorum cert
        Cert ->
            E = quod_ledger:entry(Block, Cert),
            {ok, Store1} = timed_step(S, persist,
                                      fun() -> persist_entry(Store, E, Slot, S) end),
            trace_block_event(Slot, BH, <<"consensus.durable">>, #{}, S),
            {Projected, IndexDelta} = committed_projection(E, BH, round_state(Slot, S), S),
            Projection1 = retain_owner_projection(Projected, IndexDelta, S),
            timed_step(S, feed, fun() -> publish_feed(Slot, E, S) end),
            SCommitted = timed_step(S, resolve, fun() ->
                             resolve_committed_submissions(
                               Payload, Slot,
                               S#s{store = Store1,
                                   commits = S#s.commits + 1})
                         end),
            SResolved = resolve_committed_dtx(E, Payload, SCommitted),
            S0 = ack_local(Slot, probe_committed(Slot, SResolved)),
            {S1, PendingTransition} = reconcile_signing_state(
                                        adopt_projection(
                                          E, Projection1,
                                          finalize(Slot, S0))),
            S2 = timed_step(
                   S, apply, fun() -> apply_live(E, confirm_live(S1)) end),
            finish_pending_votes_reconciliation(PendingTransition, S2)
    end.

persist_entry(Store, Entry, Slot, S) ->
    Hash = case quod_ledger:block_from_entry(Entry) of
               {ok, _Block} -> engine_block_hash(Slot, S);
               error -> none
           end,
    trace_block_work(
      Slot, Hash, <<"quod.ledger.sync">>, #{}, S,
      fun() -> quod_ledger_store:append(Store, [Entry]) end).

resolve_committed_submissions(Payload, Slot, S) ->
    Included = payload_submission_ids(Payload),
    TransactionIds = payload_transaction_ids(Payload),
    OperationClaims = payload_operation_claims(Payload),
    retire_committed_transaction_custody(
      TransactionIds,
      resolve_committed_relays(
      Included, Slot,
      resolve_committed_custody(
        Included, TransactionIds, OperationClaims, Slot, S))).

-ifdef(TEST).
retire_committed_transaction_custody(_Included,
                                     S = #s{signing_journal = memory}) ->
    S;
retire_committed_transaction_custody(Included,
                                S = #s{signing_journal = Journal}) ->
    retire_committed_transaction_custody_journal(Included, Journal, S).
-else.
retire_committed_transaction_custody(Included,
                                S = #s{signing_journal = Journal}) ->
    retire_committed_transaction_custody_journal(Included, Journal, S).
-endif.

retire_committed_transaction_custody_journal(Included, Journal, S) ->
    Journal1 = maps:fold(
                 fun(TxId, _Present, AccJournal) ->
                     case maps:is_key(
                            TxId,
                            quod_signing_journal:pending_transactions(
                              AccJournal)) of
                         true ->
                             {ok, Next} =
                                 quod_signing_journal:retire_transaction(
                                   AccJournal, TxId),
                             Next;
                         false -> AccJournal
                     end
                 end, Journal, Included),
    S#s{signing_journal = Journal1}.

payload_transaction_ids(Data) ->
    case quod_ledger:classify(Data) of
        {content, Transactions} ->
            maps:from_keys(
              [TxId || #transaction{tx_id = <<_:256>> = TxId}
                           <- Transactions],
              true);
        _ ->
            #{}
    end.

resolve_committed_custody(
  _Included, _TransactionIds, _OperationClaims, _Slot,
  S = #s{custody = Custody})
  when map_size(Custody) =:= 0 ->
    S;
resolve_committed_custody(
  Included, TransactionIds, OperationClaims, Slot, S0) ->
    S1 = maps:fold(
      fun(SubmissionId, _Present, Acc) ->
              complete_custody(
                SubmissionId, {ok, Slot}, Acc)
      end, S0, Included),
    maps:fold(
      fun(SubmissionId, #custody{change = Change}, Acc) ->
              case maps:is_key(Change#transaction.tx_id, TransactionIds) of
                  true ->
                      complete_custody(SubmissionId, {ok, Slot}, Acc);
                  false ->
                      case committed_operation_alias(
                             Change, OperationClaims) of
                          {ok, OperationRef} ->
                              complete_custody(
                                SubmissionId,
                                {error, {outcome_unknown, OperationRef}}, Acc);
                          false ->
                              Acc
                      end
              end
      end, S1, S1#s.custody).

committed_operation_alias(Change, Claims) ->
    case operation_claim(Change) of
        {claim, Key, Digest, _OperationRef} ->
            case maps:get(Key, Claims, undefined) of
                {Digest, FirstOperationRef} -> {ok, FirstOperationRef};
                _ -> false
            end;
        _ -> false
    end.

payload_operation_claims(Data) ->
    case quod_ledger:classify(Data) of
        {content, Transactions} ->
            lists:foldl(
              fun(Change, Claims) ->
                      case operation_claim(Change) of
                          {claim, Key, Digest, OperationRef} ->
                              Claims#{Key => {Digest, OperationRef}};
                          none -> Claims;
                          error -> Claims
                      end
              end, #{}, Transactions);
        _ ->
            #{}
    end.

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

payload_submission_ids(Data) ->
    case quod_ledger:classify(Data) of
        {content, Transactions} ->
            maps:from_keys(
              [signed_submission_id(Transaction)
               || #transaction{sig = Signature} = Transaction <- Transactions,
                  is_binary(Signature)],
              true);
        {controls, _Controls} -> #{};
        noop -> #{};
        invalid -> #{}
    end.

resolve_committed_dtx(Entry, Payload, S = #s{retained_dtx = Registry}) ->
    case quod_ledger:classify(Payload) of
        {controls, Controls} ->
            %% Match one whole committed wave against the pending registry.
            %% A role's Vote answers every proposed choice for that group;
            %% later phases still require their exact semantic record.
            Receipts = maps:from_list([begin
                {ok, Ref} = quod_dtx:certified_entry_ref(target_identity(S), Entry, Control),
                {dtx_receipt_key(Control), Ref}
            end || {_Kind, Control} <- Controls]),
            maps:fold(fun(Digest, #dtx_submission{control = C}, Acc) ->
                case maps:find(dtx_receipt_key(C), Receipts) of
                    {ok, Ref} ->
                        {Next, none} = finish_retained_dtx(
                                        Digest, completed, {ok, Ref, [{Ref, Entry}]}, Acc),
                        Next;
                    error -> Acc
                end
            end, S, quod_dtx_owner:rows(Registry));
        _ -> S
    end.

dtx_receipt_key(Control) ->
    case quod_atomic:control_kind(Control) of
        vote -> {vote, quod_atomic:group_id(Control)};
        _ -> {record, quod_atomic:record_digest(Control)}
    end.



signed_submission_id(#transaction{author = Author, sig = Signature}) ->
    quod_transaction:submission_id(
      {submit, Author, Signature, <<>>}).

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
adopt_projection(Entry, Projection1,
                 S = #s{validators = V, self = Self, eng = Eng}) ->
    #entry{data = Change} = quod_ledger:entry_view(Entry),
    V1 = history_committee(Projection1),
    SProjected = install_projection(Projection1, S),
    case V1 =:= V of
        true -> SProjected;
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
                     SProjected),
              %% Receipt authority belonged to the old committee. Discard
              %% only unadmitted bodies; all vote/validation latches survive.
              Rounds = maps:map(
                         fun(_Slot, R = #round{candidate = {offered, _, _}}) ->
                                 R#round{candidate = none, validation_sidecar = []};
                            (_Slot, R) -> R
                         end, S1#s.rounds),
              S1#s{eng = eng_set_validators(active_validators(S1), Eng),
                    rounds = Rounds}
    end.

committed_projection(
  Entry, BH,
  Round, S = #s{ns = Ns}) ->
    #entry{index = Slot, data = Payload} = quod_ledger:entry_view(Entry),
    case quod_ledger:classify(Payload) of
        {content, _Transactions} ->
            {history_advance_known(Ns, Entry, BH, state_projection(S)),
             quod_dtx_phase_index:new_delta()};
        {controls, Classified} ->
            live_dtx_projection(
              [Control || {_Kind, Control} <- Classified],
              Entry, BH, Round, S);
        noop ->
            {history_advance_known(Ns, Entry, entry_history_hash(Entry),
                                   state_projection(S)), quod_dtx_phase_index:new_delta()};
        invalid ->
            error({invalid_committed_history, Slot})
    end.

live_dtx_projection(
  Controls, Entry, BH,
  #round{dtx_parent = {BH, ParentToken, Histories, ParentDtx}},
  S = #s{ns = Ns, genesis_hash = Anchor,
         history_head = ParentToken, dtx_projection = ParentDtx}) ->
    #entry{index = Slot} = quod_ledger:entry_view(Entry),
    Projection0 = state_projection(S),
    case validated_dtx_entries(
           {Ns, Anchor}, Entry, Controls, Projection0) of
        {ok, ControlRefs, LaneSequences} ->
            case quod_atomic:reduce_batch(
                   ControlRefs, Histories, ParentDtx) of
                {ok, Histories1, _Dtx1, Items} ->
                    {ok, Delta} = quod_dtx_phase_index:preview_histories(
                        quod_dtx_phase_index:new_delta(), Histories1),
                    {(project_dtx_batch_items(
                       Items, LaneSequences, Entry, Projection0))#{
                      history_head := {Slot, BH}}, Delta};
                {error, Reason} ->
                    error({invalid_committed_dtx, Slot, Reason})
            end;
        error ->
            error({invalid_committed_dtx, Slot})
    end;
live_dtx_projection(_Controls, Entry, _BH, _Round, _S) ->
    #entry{index = Slot} = quod_ledger:entry_view(Entry),
    error({missing_dtx_parent_validation, Slot}).

validated_dtx_entries(Binding, Entry, Controls, Projection0) ->
    validated_dtx_entries(
      Binding, Entry, Controls, Projection0, [], []).

validated_dtx_entries(
  _Binding, _Entry, [], _Projection, ControlRefsRev, LaneSequencesRev) ->
    {ok, lists:reverse(ControlRefsRev), lists:reverse(LaneSequencesRev)};
validated_dtx_entries(
  Binding, Entry, [Control | Rest], Projection0, ControlRefsRev,
  LaneSequencesRev) ->
    case validated_dtx_entry(Binding, Entry, Control, Projection0) of
        {ok, Ref, Lane, Sequence} ->
            Lanes0 = maps:get(dtx_lanes, Projection0),
            Projection1 = Projection0#{dtx_lanes := Lanes0#{Lane => Sequence}},
            validated_dtx_entries(
              Binding, Entry, Rest, Projection1,
              [{Control, Ref} | ControlRefsRev],
              [{Lane, Sequence} | LaneSequencesRev]);
        error ->
            error
    end.

project_dtx_batch_items(Items, LaneSequences, Entry, Projection0) ->
    lists:foldl(
      fun({#{projection := DtxAfterItem},
           {Lane, Sequence}}, Projection) ->
              project_dtx_transition(
                Entry, DtxAfterItem, Lane, Sequence, Projection)
      end, Projection0, lists:zip(Items, LaneSequences)).

%% A complaint cert skipped this slot: persist an empty `noop` entry so the
%% store height advances contiguously. Ordinary custody ignores the provisional
%% nack and is marked ready by durable finalization; non-custodied membership
%% callers retain their terminal re-proof response. `quod_prolog` applies a
%% `noop` as a pure cursor advance.
skip_block(Slot, S = #s{store = Store, eng = Eng}) ->
    case persisted_cert(complaint, Slot, none, Eng) of   %% minimal complaint cert that skipped this slot
        none -> weak_cert_wait(complaint, Slot, none, S);   %% Slice E: don't skip-finalize on a sub-quorum cert
        Cert ->
            E = quod_ledger:noop_entry(Slot, Cert),
            {ok, Store1} = persist_entry(Store, E, Slot, S),
            Projection1 = retain_owner_projection(
                history_advance(S#s.ns, E, state_projection(S)),
                quod_dtx_phase_index:new_delta(), S),
            publish_feed(Slot, E, S),   %% a committed `noop` skip disseminates too, so followers stay contiguous
            S0 = nack_local(Slot, S#s{store = Store1, skips = S#s.skips + 1}),
            {S1, PendingTransition} = reconcile_signing_state(
                                        adopt_projection(
                                          E, Projection1, finalize(Slot, S0))),
            S2 = S1#s{approved = max(S1#s.approved, Slot)},
            S3 = apply_live(E, confirm_live(S2)),
            finish_pending_votes_reconciliation(PendingTransition, S3)
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
    _ = release_validation_monitor(round_state(Slot, S0)),
    SCollected = nack_collecting_le(Slot, S0),
    SExcluded = mark_custody_excluded_le(Slot, SCollected),
    S = probe_prune(Slot, nack_relays_le(Slot, SExcluded)),
    clear_requested_le(
      Slot,
      S#s{slot = Slot,
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
reply_waiter(#waiter{reply_to = {effect_custody, _TxId}}, _Reply, S) ->
    S;
reply_waiter(#waiter{reply_to = {transaction_custody, _TxId}}, _Reply, S) ->
    S;
reply_waiter(Waiter = #waiter{reply_to = ReplyTo}, Reply, S) ->
    finish_waiter_trace(Waiter, Reply),
    reply_waiter(ReplyTo, Reply, S);
reply_waiter({relay, RelayRef = #relay_ref{}}, Reply, S) ->
    reply_relay(RelayRef, Reply, S);
reply_waiter({dtx_endpoint, Pid}, Reply, S) when is_pid(Pid) ->
    Pid ! {dtx_submit_result, Reply},
    S;
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

%% Remove one retained transaction from every volatile consensus placement
%% before its exact signed bytes move under the target-cancellation owner.  A
%% still-open local batch is discarded through the existing nack path first;
%% that path preserves every custody record, and the ordinary lane reconciler
%% then makes all of them eligible for a later view.  No stale batch or relay
%% may outlive the admission generation that authorized it.
withdraw_transaction_custody(SubmissionId, _Record, S0) ->
    S1 =
        case collecting_has_custody(SubmissionId, S0#s.collecting) of
            true -> mark_custody_lane_ready(nack_collecting(S0));
            false -> S0
        end,
    S2 =
        case maps:get(SubmissionId, S1#s.custody, undefined) of
            #custody{placement = Placement}
              when is_tuple(Placement),
                   (element(1, Placement) =:= local orelse
                    element(1, Placement) =:= relay) ->
                mark_custody_ready(SubmissionId, S1);
            _ -> S1
        end,
    case maps:get(SubmissionId, S2#s.custody, undefined) of
        #custody{placement = ready, change = Change} ->
            drop_custody_ready(
              {Change#transaction.author_seq, SubmissionId}, S2);
        _ -> S2
    end.

collecting_has_custody(
  SubmissionId, #batch{items_rev = Items}) ->
    lists:any(
      fun({#waiter{reply_to = {custody, Candidate}}, _Change}) ->
              Candidate =:= SubmissionId;
         (_) -> false
      end, Items);
collecting_has_custody(_SubmissionId, _Collecting) ->
    false.

release_custody(
  SubmissionId, S = #s{custody = Custody}) ->
    case maps:take(SubmissionId, Custody) of
        {Record = #custody{waiter = Waiter, placement = Placement,
                  change = Change, deadline = Deadline,
                  attempts = Attempts, bytes = Bytes},
         Custody1} ->
            ok = stop_custody_process_owners(Record),
            S1 = retire_custody_placement(
                   SubmissionId, Record, S),
            Ready1 = remove_custody_ready_key(
                       Placement, Change, SubmissionId,
                       S1#s.custody_ready),
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

remove_custody_ready_key(ready, Change, SubmissionId, Ready) ->
    gb_sets:del_element(
      {Change#transaction.author_seq, SubmissionId}, Ready);
remove_custody_ready_key(_Placement, _Change, _SubmissionId, Ready) ->
    Ready.

observe_custody_hops(Ns, Attempts) ->
    quod_metrics:observe_ingress_retarget_hops(
      Ns, max(0, Attempts - 1)).

retire_custody_placement(
  _SubmissionId, #custody{placement = ready}, S) ->
    S;
retire_custody_placement(
  _SubmissionId, #custody{placement = dormant}, S) ->
    S;
retire_custody_placement(
  _SubmissionId,
  #custody{placement = {cancelling, _Pid, _Monitor}}, S) ->
    S;
retire_custody_placement(
  _SubmissionId,
  #custody{placement = Placement},
  S = #s{custody = Custody}) ->
    %% At stable boundaries custody is partitioned into placed records and the
    %% sole ordered ready set. The current record is still in Custody here.
    %% Clearing on <=1 removes the last active placement without maintaining a
    %% second ordered projection that could drift and strand work.
    PlacedCount = maps:fold(
                    fun(_Id, #custody{placement = {local, _, _}}, N) ->
                            N + 1;
                       (_Id, #custody{placement = {relay, _, _, _, _}}, N) ->
                            N + 1;
                       (_Id, _Record, N) -> N
                    end, 0, Custody),
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

stop_custody_process_owners(
  #custody{dormant_owner = DormantOwner, placement = Placement}) ->
    case DormantOwner of
        {_Owner, OwnerMonitor} ->
            _ = erlang:demonitor(OwnerMonitor, [flush]);
        none -> ok
    end,
    case Placement of
        {cancelling, Pid, Monitor} ->
            _ = erlang:demonitor(Monitor, [flush]),
            exit(Pid, shutdown);
        _ -> ok
    end,
    ok.

waiter_trace_ctx(#waiter{trace_ctx = TraceCtx}) -> TraceCtx;
waiter_trace_ctx(_) -> otel_ctx:new().

new_waiter(ReplyTo, ParentCtx, Change, #s{ns = Ns}, Relayed) ->
    new_waiter(
      ReplyTo, ParentCtx, Change, Ns, Relayed,
      change_submission_id(Change)).

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

change_submission_id(#transaction{sig = Signature} = Change)
  when is_binary(Signature), byte_size(Signature) =:= 64 ->
    signed_submission_id(Change);
change_submission_id(_Change) ->
    undefined.

finish_waiter_trace(#waiter{trace_ctx = TraceCtx, trace_span = SpanCtx}, Reply) ->
    _ = quod_trace:add_event(
          TraceCtx, <<"consensus.append_result">>, trace_reply_attributes(Reply)),
    quod_trace:finish_span(SpanCtx, Reply).

trace_reply_attributes({ok, Slot}) ->
    #{'quod.outcome' => <<"committed">>, 'quod.consensus.slot' => Slot};
trace_reply_attributes({error, Reason}) when is_atom(Reason) ->
    #{'quod.outcome' => atom_to_binary(Reason, utf8)};
trace_reply_attributes({error, {outcome_unknown, _OperationRef}}) ->
    #{'quod.outcome' => <<"outcome_unknown">>};
trace_reply_attributes({error, not_in_charge, _Hint}) ->
    #{'quod.outcome' => <<"not_in_charge">>}.

trace_node_id(Id) when is_binary(Id) -> binary:encode_hex(Id, lowercase);
trace_node_id({Host, Port}) ->
    iolist_to_binary(io_lib:format("~ts:~B", [Host, Port])).

%% Shared block work must not disappear behind an unsampled first receipt.
%% This is the same recording-parent/link policy as committed Prolog apply.
%% Relayed blocks without caller ancestry use the opt-in diagnostic turn.
%% Capture here so existing asynchronous validation carries that same context.
%% Complaints/skips claim a slot; a different block never borrows its caller.
trace_for_block(Slot, Hash, #s{local_proposals = Local}) ->
    Contexts = case maps:get(Slot, Local, undefined) of
        #local_proposal{hash = Proposed, trace_ctxs = Cs}
          when Hash =:= none; Hash =:= Proposed -> Cs;
        _ -> []
    end,
    case quod_trace:shared_context([otel_tracer:current_span_ctx(Ctx) || Ctx <- Contexts]) of
        none ->
            case quod_trace:owner_context() of
                undefined -> none;
                Owner -> {Owner, []}
            end;
        Parent -> Parent
    end.

trace_block_work(Slot, Hash, Name, Attributes, S, Fun) ->
    quod_consensus_trace:work(trace_for_block(Slot, Hash, S),
                             {S#s.ns, Slot, Hash}, Name, Attributes, Fun).

trace_block_event(Slot, Hash, Name, Attributes, S) ->
    quod_consensus_trace:event(trace_for_block(Slot, Hash, S),
                              {S#s.ns, Slot, Hash}, Name, Attributes).

trace_slot_event(Slot, Name, Attributes, S) ->
    trace_block_event(Slot, none, Name, Attributes, S).

trace_validation_class(valid) -> <<"valid">>;
trace_validation_class({valid, _Histories}) -> <<"valid">>;
trace_validation_class({invalid, _Reason}) -> <<"invalid">>;
trace_validation_class(abstain) -> <<"abstain">>;
trace_validation_class(_) -> <<"unexpected">>.

trace_validation_kind(#round{validation = {content_foreign, _, _}}) -> <<"content_foreign">>;
trace_validation_kind(#round{validation = content}) -> <<"content_parent">>;
trace_validation_kind(#round{validation = {dtx, _, _, _, _}}) -> <<"dtx_parent">>;
trace_validation_kind(#round{validation = {dtx_foreign, _, _, _, _, _}}) -> <<"dtx_foreign">>;
trace_validation_kind(#round{}) -> <<"none">>.

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

-ifdef(TEST).
reconcile_signing_state(S = #s{signing_journal = memory}) -> {S, none};
reconcile_signing_state(S) -> reconcile_signing_state_journal(S).
-else.
reconcile_signing_state(S) -> reconcile_signing_state_journal(S).
-endif.
reconcile_signing_state_journal(
  S = #s{slot = Slot, signing_journal = Journal, ns = Ns}) ->
    Pending0 = pending_votes_snapshot(Journal),
    {ok, Journal1} = quod_dtx_owner:reconcile_journal(
                       Slot, state_projection(S), S#s.phase_index, Journal),
    Pending1 = pending_votes_snapshot(Journal1),
    Transition = pending_votes_reconciliation(Pending0, Pending1, S),
    %% This cast precedes the ordered ledger apply.  The matching resolution
    %% notification is deliberately deferred until after that apply, when
    %% quod_prolog's publication floor can make the absence classification
    %% definitive rather than outcome-unknown.
    ok = project_pending_votes(Ns, Journal1),
    %% Semantic alternatives may survive exact-digest commit resolution, but
    %% must not acquire a new signature after the projection made them stale.
    %% Both classification and signature retirement return pending resolutions
    %% to the caller's existing post-apply boundary.
    {Classified, Retired} = refresh_retained_readiness(
                             reconcile_transaction_signing_custody(
                               S#s{signing_journal = Journal1})),
    {Renewed, SignatureRetired} = refresh_retained_dtx_signatures(Classified),
    {Renewed, merge_pending_votes_reconciliation(
                Transition,
                merge_pending_votes_reconciliation(Retired, SignatureRetired))}.

reconcile_transaction_signing_custody(
  S0 = #s{signing_journal = Journal0}) ->
    ExpectedAdmission = current_effect_admission(S0),
    maps:fold(
      fun(TxId, Row = #{admission := Admission}, S) ->
              case ExpectedAdmission of
                  Admission -> S;
                  _ ->
                      case operation_custody_row(Row) of
                          true ->
                              ensure_operation_custody_cancellation(TxId, S);
                          false ->
                              retire_transaction_signing_custody(TxId, S)
                      end
              end
      end, S0,
      quod_signing_journal:pending_transactions(Journal0)).

current_effect_admission(S = #s{self = Self,
                                author_admissions = Admissions}) ->
    case {is_participant(S), maps:get(Self, Admissions, undefined)} of
        {true, <<_:256>> = Admission} -> Admission;
        _ -> none
    end.

retire_transaction_signing_custody(
  TxId, S0 = #s{signing_journal = Journal0, custody = Custody}) ->
    SubmissionIds =
        [SubmissionId
         || {SubmissionId, #custody{change = #transaction{tx_id = RowTxId}}}
                <- maps:to_list(Custody),
            RowTxId =:= TxId],
    S1 = lists:foldl(
           fun(SubmissionId, S) ->
                   complete_custody(
                     SubmissionId, {error, not_in_charge, unavailable}, S)
           end, S0, SubmissionIds),
    {ok, Journal1} = quod_signing_journal:retire_transaction(
                       Journal0, TxId),
    quod_effect_journal:retire_transaction(TxId, not_in_charge),
    S1#s{signing_journal = Journal1}.

pending_votes_reconciliation(
  Before, After,
  #s{ns = Ns, genesis_hash = <<_:256>> = Anchor}) ->
    Cleared =
        [Ref
         || GroupId <- lists:sort(maps:keys(Before)),
            not maps:is_key(GroupId, After),
            Ref <- [maps:get(group_ref, maps:get(GroupId, Before))],
            quod_outcome:ref_identity(Ref) =:= {ok, {Ns, Anchor}}],
    case Cleared of
        [] -> none;
        _ -> {cleared_pending_votes, Cleared}
    end.

merge_pending_votes_reconciliation(none, Transition) -> Transition;
merge_pending_votes_reconciliation(Transition, none) -> Transition;
merge_pending_votes_reconciliation(
  {cleared_pending_votes, Left}, {cleared_pending_votes, Right}) ->
    {cleared_pending_votes, lists:usort(Left ++ Right)}.

%% Ordinary retirement has no enclosing ledger apply. Complete its returned
%% transition at that existing boundary; commit/skip/catch-up use /2 later.
finish_pending_votes_reconciliation({S, Transition}) ->
    finish_pending_votes_reconciliation(Transition, S).

finish_pending_votes_reconciliation(
  {cleared_pending_votes, GroupRefs}, S = #s{ns = Ns}) ->
    lists:foreach(
      fun(GroupRef) -> ok = quod_prolog:dtx_group_resolved(Ns, GroupRef) end,
      GroupRefs),
    S;
finish_pending_votes_reconciliation(none, S) ->
    S.

refresh_retained_dtx_signatures(
  S = #s{retained_dtx = Registry}) ->
    case quod_dtx_owner:count(Registry) of
        0 -> {S, none};
        _ -> refresh_retained_dtx_signatures_nonempty(S)
    end.

refresh_retained_dtx_signatures_nonempty(S0) ->
    Actions = quod_dtx_owner:signature_actions(
                dtx_owner_binding(S0), endpoint_write_ready(S0),
                S0#s.author_admissions, S0#s.dtx_lanes, S0#s.retained_dtx),
    lists:foldl(
      fun({Row = #dtx_submission{digest = Digest}, Action}, {S, Pending}) ->
          {Next, Cleared} = case Action of
              retire -> retire_dtx_submission(Digest, not_in_charge, S);
              renew -> renew_dtx_submission(Row, S)
          end,
          {Next, merge_pending_votes_reconciliation(Pending, Cleared)}
      end, {S0, none}, Actions).

renew_dtx_submission(
  #dtx_submission{digest = Digest, control = Control,
                  observation_started_at = ObservationStartedAt,
                  validation_sidecar = ValidationSidecar},
  S) ->
    Meta = quod_atomic:control_metadata(Control),
    Sequence = maps:get(sequence, Meta),
    {Old, RegistryWithout} = quod_dtx_owner:take(Digest, S#s.retained_dtx),
    SWithout = S#s{retained_dtx = RegistryWithout},
    case sign_and_retain_dtx(
           quod_atomic:control_material(Control), none, ValidationSidecar, Sequence, SWithout) of
        {ok, S1 = #s{retained_dtx = Renewed}} ->
            New = maps:get(Digest, quod_dtx_owner:rows(Renewed)),
            {update_dtx_submission(
              Digest,
              New#dtx_submission{waiters = Old#dtx_submission.waiters,
                                 selection = Old#dtx_submission.selection,
                                 trace_ctx = Old#dtx_submission.trace_ctx,
                                 observation_started_at = ObservationStartedAt}, S1), none};
        {error, Reason} ->
            logger:error(
              "quod[~s]: unable to re-envelope retained DTX control: ~p",
              [S#s.ns, Reason]),
            finish_detached_retained_dtx(
              Old, dtx_retirement_result(Reason), {error, Reason}, SWithout)
    end.

retire_dtx_submission(Digest, Reason, S) ->
    finish_retained_dtx(
      Digest, dtx_retirement_result(Reason), {error, Reason}, S).

finish_retained_dtx(Digest, Result, Reply,
                    S = #s{retained_dtx = Registry}) ->
    case quod_dtx_owner:take(Digest, Registry) of
        {Row, Registry1} ->
            finish_detached_retained_dtx(
              Row, Result, Reply, S#s{retained_dtx = Registry1});
        error ->
            {S, none}
    end.

finish_detached_retained_dtx(
  Row = #dtx_submission{control = Control, observation_started_at = StartedAt},
  Result, Reply, S) ->
    %% Dropping a volatile envelope is not outcome authority. Only installed
    %% history/admission reconciliation prunes the journal's pending intent,
    %% and its public notification stays at the caller's post-apply boundary.
    observe_simplex_owner_terminal(
      S, dtx_control, quod_atomic:control_kind(Control), Result, StartedAt),
    {reply_waiters(quod_dtx_owner:waiter_tags(Row), Reply, S), none}.

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
support_block_ready(#block{slot = Sl} = Block, BH, S) ->
    Round = round_state(Sl, S),
    case Round#round.supporting of
        none -> case record_share(support, Sl, BH, Block, S) of
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

%% Route inbound consensus messages through the owner. Receipt may retain a
%% bounded unadmitted offer; only full admission can give it engine authority.
dispatch(Peer, {propose, #block{} = B, ValidationSidecar}, S) ->
    preflight_proposal(Peer, B, ValidationSidecar, S);
dispatch(_Peer, {share, #share{} = Sh}, S) ->
    case well_formed_share(Sh) of
        true ->
            %% Receipt of a well-shaped share is not proof it verifies. The
            %% engine below still owns authentication, dedup and quorum weight.
            trace_block_event(
              Sh#share.slot, Sh#share.block_hash, <<"consensus.share_received">>,
              #{'quod.vote.kind' => atom_to_binary(Sh#share.kind, utf8)}, S),
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
dispatch(Peer, {certified_block, #block{} = Block, Hash}, S) ->
    ingest_certified_block(Peer, Block, Hash, S);
dispatch(Peer, {readiness, Height, Ready}, S)
  when is_integer(Height), Height >= 0, is_boolean(Ready) ->
    record_peer_readiness(Peer, Height, Ready, S);
dispatch(Peer, {dtx_submit, Envelopes, ValidationSidecar}, S) ->
    handle_dtx_submit(Peer, Envelopes, ValidationSidecar, S);
dispatch(_Peer, _Other, S)                 -> S.

well_formed_block(#block{slot = Sl, parent = P, payload = Pl,
                         timestamp = Ts} = Block) ->
    well_formed_block_header(Sl, P, Ts)
        andalso quod_ledger:valid_block_view(Block)
        andalso well_formed_block_payload(Pl);
well_formed_block(_) -> false.

well_formed_block_header(Slot, Parent, Timestamp) ->
    is_slot(Slot) andalso is_slot(Parent) andalso is_slot(Timestamp).

%% valid_block_view/1 already checked canonical byte binding and payload size.
well_formed_block_payload(Pl) ->
    case quod_ledger:classify(Pl) of
        {content, Transactions} ->
            bounded_transaction_list(Transactions)
                andalso lists:all(fun well_formed_transaction/1, Transactions)
                andalso unique_tx_ids(Transactions);
        {controls, _Controls} -> true;
        noop -> false;
        invalid -> false
    end.

encoded_block_payload_fits(Payload) ->
    case quod_ledger:encoded_payload_size(Payload) of
        {ok, Bytes} -> Bytes =< ?MAX_BLOCK_BYTES;
        error -> false
    end.
well_formed_share(#share{kind = K, slot = Sl, block_hash = BH, signer = Sg, sig = Sig}) ->
    is_slot(Sl) andalso valid_shape(K, BH) andalso valid_signer_signature(Sg, Sig);
well_formed_share(_) -> false.
is_slot(X) -> is_integer(X) andalso X >= 0 andalso X =< ?MAX_SLOT.

%% The requester's verified support certificate authorizes this exact hash.
%% Serving bytes must survive the handoff from the live engine to the ledger;
%% pruning consensus memory never makes an already-durable block unavailable.
serve_certified_block(Peer, Slot, BH, S) ->
    case lists:member(Peer, active_validators(S)) andalso available_block(Slot, BH, S) of
        {ok, Block} ->
            case block_hash(Block) =:= BH of
                true -> send_frame(Peer, encode(S#s.ns, {certified_block, Block, BH}), S);
                false -> S
            end;
        _ -> S
    end.

available_block(Slot, _BH, #s{slot = Committed, store = Store}) when Slot =< Committed ->
    case quod_ledger_store:read_at(Store, Slot) of
        {ok, Entry} -> quod_ledger:block_from_entry(Entry);
        not_found -> error
    end;
available_block(Slot, BH, #s{eng = Eng}) ->
    case block_for(BH, Eng) of #block{slot = Slot} = Block -> {ok, Block}; _ -> error end.

%% Only an outstanding exact request backed by our authenticated certificate
%% admits a reply. Cheap sender/header gates precede hashing and content checks.
ingest_certified_block(
  Peer, Block = #block{slot = Slot, parent = Parent, timestamp = Timestamp},
  ExpectedBH, S = #s{block_requests = Requests, eng = Eng})
  when is_binary(ExpectedBH), byte_size(ExpectedBH) =:= 32 ->
    Preflight =
        maps:is_key({Slot, ExpectedBH}, Requests)
        andalso lists:member(Peer, active_validators(S))
        andalso well_formed_block_header(Slot, Parent, Timestamp)
        andalso is_record(persisted_cert(support, Slot, ExpectedBH, Eng), cert),
    case Preflight andalso well_formed_block(Block)
         andalso block_hash(Block) =:= ExpectedBH
         andalso certified_block_context(Block, ExpectedBH, S) of
        false ->
            S;
        true ->
            %% The certificate authorizes replacement input, not admission.
            %% Both receipt paths advance through the same parent boundary.
            S1 = S#s{block_requests = maps:remove({Slot, ExpectedBH}, Requests)},
            case (round_state(Slot, S1))#round.candidate of
                {OtherBH, _} when OtherBH =/= ExpectedBH -> S;
                {_, _} -> on_propose(ExpectedBH, Block, [], false, S1);
                _ -> offer_proposal(ExpectedBH, Block, [], S1)
            end
    end;
ingest_certified_block(_Peer, _Block, _Hash, S) ->
    S.

certified_block_context(
  #block{slot = Slot, parent = Parent, timestamp = Timestamp},
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
            ts_acceptable(Timestamp, ParentTs, quod_time:now_ms())
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

%% Receipt is not admission. A canonical leader offer fits the existing durable
%% two-slot window even while its parent is still being validated. Keeping its
%% body here grants no signature, engine insertion or parent-verdict authority.
%% Exact retained redrives reuse admission; certified replies retain their
%% separate certificate authority for replacing an unadmitted first offer.
preflight_proposal(
  Peer, #block{slot = Sl, timestamp = Timestamp} = Block, ValidationSidecar,
  S = #s{slot = Committed,
         eng = #eng{block_slots = BlockSlots}}) ->
    PotentiallyLive =
        maps:is_key(Sl, BlockSlots)
        orelse live_pipeline_slot(Sl, Committed),
    FromLeader =
        PotentiallyLive
        andalso is_slot(Sl) andalso Sl >= 1
        andalso leader(Sl, active_validators(S)) =:= Peer,
    %% Network ingress already decodes only canonical block bytes. Keep this
    %% internal boundary total as well: test hooks and future in-VM callers
    %% must not reach block_hash/1 with a fabricated materialized view.
    case FromLeader andalso well_formed_block(Block)
         andalso Block#block.parent =:= Sl - 1
         andalso ts_acceptable(Timestamp, S#s.last_ts, quod_time:now_ms()) of
        false ->
            S;
        true ->
            BH = block_hash(Block),
            case maps:get(Sl, BlockSlots, undefined) of
                undefined ->
                    on_propose(BH, Block, ValidationSidecar, false, S);
                BH ->
                    on_propose(BH, Block, ValidationSidecar, true, S);
                _OtherBH ->
                    S
            end
    end.

%% Known means admission was already paid by the local proposer or live engine.
%% A received body instead advances through the same round's offered state.
on_propose(BH, #block{slot = Sl} = Block, ValidationSidecar, Known, S) ->
    Round = round_state(Sl, S),
    case {Known, Round#round.candidate} of
        {true, _} ->
            admit_proposed_block(BH, Block, ValidationSidecar, S);
        {false, {BH, Block}} ->
            admit_proposed_block(BH, Block, ValidationSidecar, S);
        {false, {offered, BH, Block}} ->
            Merged = merge_validation_sidecars(Round#round.validation_sidecar,
                                               ValidationSidecar),
            offer_proposal(BH, Block, Merged, S);
        {false, none} when Round#round.invalid =/= BH ->
            offer_proposal(BH, Block, ValidationSidecar, S);
        _ -> S
    end.

offer_proposal(BH, Block = #block{slot = Sl}, ValidationSidecar, S) ->
    Round = round_state(Sl, S),
    Offered = Round#round{
                candidate = {offered, BH, Block},
                validation_sidecar = dtx_block_validation_sidecar(Block, ValidationSidecar)},
    advance_proposal(Sl, put_round(Sl, Offered, S)).

%% Read the current row at every step: an earlier candidate may have committed
%% and pruned this slot. DTX input waits for its actual durable parent, not an
%% approval or another candidate's unverified parent assumptions.
advance_proposal(Sl, S = #s{slot = Committed, approved = Approved,
                           history_head = ParentToken}) ->
    Round = round_state(Sl, S),
    case Round#round.candidate of
        {offered, BH, Block} ->
            case {Sl =:= Approved + 1, live_pipeline_slot(Sl, Committed),
                  quod_ledger:classify(Block#block.payload), ParentToken} of
                {true, true, {controls, _}, {Approved, <<_:256>>}} ->
                    admit_offered_proposal(BH, Block, Round, S);
                {true, true, {controls, _}, _} -> S;
                {true, true, _, _} ->
                    admit_offered_proposal(BH, Block, Round, S);
                {false, true, _, _} when Sl > Approved -> S;
                %% At/below Approved the body is durable or already engine-
                %% owned. Certificates alone never advance that frontier.
                _ -> put_round(Sl, Round#round{candidate = none,
                                               validation_sidecar = []}, S)
            end;
        {BH, Block} when Sl > Committed -> support_or_validate(Block, BH, S);
        _ -> S
    end.

admit_offered_proposal(BH, Block = #block{slot = Sl}, Round, S) ->
    case Round#round.invalid =/= BH
         andalso payload_admission_open(Sl, Block#block.payload, S) of
        false -> S;
        true -> authenticate_offered_proposal(BH, Block, Round, S)
    end.

authenticate_offered_proposal(BH, Block = #block{slot = Sl, parent = Parent}, Round, S) ->
    case block_material_admissible(Block, parent_timestamp(Parent, S), S) of
        true ->
            admit_proposed_block(BH, Block, Round#round.validation_sidecar, S);
        false ->
            %% Keep the bounded input latched: neither exact redrives nor
            %% alternating invalid offers buy another authentication. Only
            %% certificate-authorized replacement can change this receipt.
            put_round(Sl, Round#round{validation_sidecar = [], invalid = BH,
                                      invalid_reason = proposal_admission}, S)
    end.

admit_proposed_block(BH, #block{slot = Sl} = Block, ValidationSidecar, S) ->
    case quod_ledger:classify(Block#block.payload) of
        {controls, _Controls} ->
            %% Every DTX redrive stays here. Only support_validated_dtx/3
            %% inserts it into the engine after the exact parent verdict.
            S1 = retain_dtx_candidate(
                   Block, BH, ValidationSidecar, watch_proposal(Sl, S)),
            support_or_validate(Block, BH, S1);
        _ ->
            %% Ordinary bodies have one home after admission: the engine.
            Round = round_state(Sl, S),
            Admitted = put_round(Sl, Round#round{candidate = none,
                                                validation_sidecar = []}, S),
            S1 = engine_step([{block, BH, Block}], Admitted),
            %% Only the engine's exact retained hash can acquire a vote.
            case block_for(BH, S1#s.eng) of
                #block{} ->
                    %% Quorum needs no fresh support, but an existing share
                    %% still re-echoes to heal a leader's lost vote delivery.
                    Supported = (round_state(Sl, S1))#round.supporting =:= BH,
                    case may_vote(S1) andalso (Sl > S1#s.approved orelse Supported) of
                        true -> support_or_validate(Block, BH, watch_proposal(Sl, S1));
                        false -> S1
                    end;
                undefined -> S1
            end
    end.

retain_dtx_candidate(Block = #block{slot = Sl}, BH, ValidationSidecar0, S) ->
    Round = round_state(Sl, S),
    ValidationSidecar = dtx_block_validation_sidecar(Block, ValidationSidecar0),
    case Round#round.candidate of
        Candidate when Candidate =:= none;
                       element(1, Candidate) =:= offered -> put_round(
                  Sl,
                  Round#round{candidate = {BH, Block},
                              validation_sidecar = ValidationSidecar}, S);
        {BH, Block} ->
            Merged = dtx_block_validation_sidecar(
                       Block,
                       merge_validation_sidecars(
                         Round#round.validation_sidecar,
                         ValidationSidecar)),
            put_round(Sl, Round#round{validation_sidecar = Merged}, S);
        {_OtherBH, _OtherBlock} -> S
    end.

dtx_block_validation_sidecar(#block{payload = Payload}, ValidationSidecar) ->
    case quod_ledger:classify(Payload) of
        {controls, Controls} ->
            prioritize_validation_sidecar(
              lists:flatmap(
                fun({_Kind, Control}) ->
                        relevant_control_validation_sidecar(
                          Control, ValidationSidecar)
                end, Controls));
        _ ->
            []
    end.

%% Content that requires parent-state validation defers its support share until
%% this node's own KB judges it through `quod_prolog:request_content_verdict/6`,
%% pinned to the proposal parent. This one path covers signed authorization and
%% committee policy; local and remote proposals use it identically. DTX controls
%% use the adjacent exact-history verdict path.
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
    Round = round_state(Sl, S),
    Block =
        case block_for(BH, S#s.eng) of
            #block{} = Stored -> Stored;
            undefined ->
                case Round#round.candidate of
                    {BH, #block{} = Candidate} -> Candidate;
                    _ -> undefined
                end
        end,
    support_or_validate_candidate(Block, Sl, BH, S).

support_or_validate_candidate(undefined, _Sl, _BH, S) ->
    S;
support_or_validate_candidate(#block{payload = Payload} = Block, Sl, BH, S) ->
    case quod_ledger:classify(Payload) of
        {content, Transactions} ->
            support_or_validate_content(
              Transactions, Block, Sl, BH, S);
        {controls, Controls} ->
            support_or_validate_dtx(
              [Control || {_Kind, Control} <- Controls],
              Block, Sl, BH, S);
        noop -> S;
        invalid -> S
    end.

support_or_validate_content(
  Transactions, Block = #block{timestamp = BlockTimestamp}, Sl, BH, S) ->
    case transactions_require_parent_validation(Transactions) of
        false -> support_block(Block, BH, S);
        true ->
            Round = round_state(Sl, S),
            case Round#round.supporting =:= BH of
                %% judged VALID + support-signed already: a redriven copy takes the plain support path,
                %% whose duplicate branch re-echoes our share — never a KB re-proof per Δ
                true  -> support_block(Block, BH, S);
                false ->
                    case Round#round.validating of
                        BH -> S;
                        _ -> start_content_validation(
                               Transactions, BlockTimestamp, Sl, BH, S)
                    end
            end
    end.

start_content_validation(Transactions, BlockTimestamp, Sl, BH,
                         S = #s{dtx_workers = DtxWorkers}) ->
    case content_reference_plan(Transactions) of
        {ok, []} ->
            request_content_validation(
              Transactions, BlockTimestamp, Sl, BH, S);
        {ok, ReferencePlan} ->
            Deadline = quod_time:mono_ms() + ?DTX_FOREIGN_VERIFY_MS,
            LocalIdentity = target_identity(S),
            LocalSource = local_history_view(S),
            {Worker, Monitor} = spawn_foreign_validation(
                {Sl, BH}, {content_foreign_verdict, {Sl, BH}}, Deadline,
                #{'quod.validation.transactions' => length(ReferencePlan)}, S,
                fun() ->
                    Contacts = content_reference_contacts(ReferencePlan, DtxWorkers, LocalIdentity),
                    {verify_content_foreign_references(
                        ReferencePlan, LocalIdentity, LocalSource, Contacts, Deadline), Contacts}
                end),
            Round = round_state(Sl, S),
            put_round(
              Sl, Round#round{validating = BH,
                              validation = {content_foreign,
                                            Worker, Monitor}}, S);
        {error, _} ->
            reject_content_candidate(Sl, BH, malformed_foreign_references, S)
    end.

request_content_validation(Transactions, BlockTimestamp, Sl, BH, S) ->
    _ = with_block_context(Sl, BH, S,
          fun() -> quod_prolog:request_content_verdict(
                     S#s.ns, Transactions, BlockTimestamp, Sl, self(), {Sl, BH}) end),
    Round = round_state(Sl, S),
    put_round(Sl, Round#round{validating = BH, validation = content}, S).

%% Both Prolog request kinds carry ancestry on their existing asynchronous cast.
with_block_context(Sl, BH, S, Fun) ->
    Ctx = case trace_for_block(Sl, BH, S) of
              {Parent, _Links} -> Parent;
              none -> otel_ctx:new()
          end,
    quod_trace:with_context(Ctx, Fun).

on_content_foreign_verdict(Sl, BH, WorkerPid, Deadline, Verdict0,
                           S = #s{approved = Approved})
  when Sl =:= Approved + 1 ->
    Round = round_state(Sl, S),
    case {Round#round.validating, Round#round.validation,
          block_for(BH, S#s.eng)} of
        {BH, {content_foreign, WorkerPid, Monitor},
         #block{timestamp = Timestamp,
                payload = {batch, Transactions}}} ->
            Verdict = reference_deadline_result(Deadline, Verdict0),
            trace_block_event(
              Sl, BH, <<"consensus.foreign_validation_received">>,
              #{'quod.validation.verdict' => trace_validation_class(Verdict)}, S),
            _ = erlang:demonitor(Monitor, [flush]),
            S1 = put_round(
                   Sl, Round#round{validating = none,
                                   validation = none}, S),
            case Verdict of
                valid -> request_content_validation(
                           Transactions, Timestamp, Sl, BH, S1);
                {invalid, Reason} ->
                    reject_content_candidate(Sl, BH, Reason, S1);
                abstain -> S1
            end;
        _ -> S
    end;
on_content_foreign_verdict(_Sl, _BH, _WorkerPid, _Deadline, _Verdict, S) -> S.

reject_content_candidate(Sl, BH, _Reason, S) ->
    Round = round_state(Sl, S),
    S1 = put_round(
           Sl, Round#round{validating = none, validation = none,
                           invalid = BH}, S),
    choose_final_vote(Sl, rejected, S1).

content_reference_plan(Transactions) when is_list(Transactions) ->
    %% Keep each requirement bound to the immutable candidate item.  The
    %% network worker consumes this plan directly; it must not reinterpret the
    %% transaction after the pre-scan has selected the foreign-verification
    %% path.
    content_reference_plan(Transactions, []).

content_reference_plan([], PlanRev) ->
    {ok, lists:reverse(PlanRev)};
content_reference_plan([Transaction | Rest], PlanRev) ->
    case quod_transaction:required_references(Transaction) of
        [] ->
            content_reference_plan(Rest, PlanRev);
        References when is_list(References) ->
            content_reference_plan(
              Rest, [{Transaction, References} | PlanRev]);
        error ->
            {error, malformed_foreign_references}
    end.

verify_content_foreign_references(
  ReferencePlan, LocalIdentity, LedgerRoot, Contacts, Deadline) ->
    reference_deadline_result(Deadline,
      verify_content_foreign_references(
        ReferencePlan, LocalIdentity, LedgerRoot, Contacts, #{}, Deadline)).

verify_content_foreign_references(
  [], _LocalIdentity, _LedgerRoot, _Contacts, _Seen, _Deadline) ->
    valid;
verify_content_foreign_references(
  [{#transaction{} = Transaction, References} | Rest],
  LocalIdentity, LedgerRoot,
  Contacts, Seen0, Deadline) ->
    case verify_content_requirements(
           References, LocalIdentity, LedgerRoot, Contacts, Seen0, Deadline) of
        {valid, Seen1} ->
            verify_content_reference_binding(
              Transaction, Rest, LocalIdentity, LedgerRoot, Contacts, Seen1, Deadline);
        Other -> Other
    end;
verify_content_foreign_references(
  _Malformed, _LocalIdentity, _LedgerRoot, _Contacts, _Seen, _Deadline) ->
    {invalid, malformed_foreign_references}.

verify_content_requirements([], _LocalIdentity, _LedgerRoot, _Contacts, Seen, _Deadline) ->
    {valid, Seen};
verify_content_requirements([{Phase, Ref} | Rest],
                            LocalIdentity, LedgerRoot, Contacts, Seen0, Deadline) ->
    case maps:find(Ref, Seen0) of
        {ok, Evidence} ->
            case reference_evidence_satisfies(Phase, Evidence) of
                true ->
                    verify_content_requirements(
                      Rest, LocalIdentity, LedgerRoot, Contacts, Seen0, Deadline);
                false -> {invalid, foreign_reference}
            end;
        error ->
            case verify_content_reference(
                   Ref, Phase, LocalIdentity, LedgerRoot, Contacts, Deadline) of
                {valid, Evidence} ->
                    verify_content_requirements(
                      Rest, LocalIdentity, LedgerRoot, Contacts,
                      Seen0#{Ref => Evidence}, Deadline);
                Other -> Other
            end
    end;
verify_content_requirements(_Malformed, _LocalIdentity, _LedgerRoot,
                            _Contacts, _Seen, _Deadline) ->
    {invalid, malformed_foreign_references}.

reference_evidence_satisfies(transaction,
                             #{transaction := #transaction{}}) -> true;
reference_evidence_satisfies(entry, #{entry := Entry}) ->
    try quod_ledger:entry_index(Entry) of
        I when is_integer(I), I > 0 -> true
    catch error:_ -> false
    end;
reference_evidence_satisfies(_Phase, _Evidence) -> false.

verify_content_reference_binding(Transaction, Rest,
                                 LocalIdentity, LedgerRoot, Contacts, Seen, Deadline) ->
    case quod_commit_validation:validate_evidence(Transaction, Seen) of
        ok ->
            verify_content_foreign_references(
              Rest, LocalIdentity, LedgerRoot, Contacts, Seen, Deadline);
        abstain -> abstain;
        {error, Reason} -> {invalid, Reason}
    end.

verify_content_reference(Ref, Phase, LocalIdentity, LedgerRoot, Contacts, Deadline) ->
    case quod_dtx:certified_ref_binding(Ref) of
        {ok, LocalIdentity, _Slot, _Digest} ->
            verify_local_dtx_reference(
              Ref, Phase, LocalIdentity, LedgerRoot, Deadline);
        {ok, ForeignIdentity, _Slot, _Digest} ->
            verify_remote_dtx_reference(
              Ref, Phase, ForeignIdentity,
              reference_contact(Ref, ForeignIdentity, Contacts), Deadline);
        error -> {invalid, malformed_foreign_reference}
    end.

support_or_validate_dtx(Controls, Block, Sl, BH, S)
  when is_list(Controls), Controls =/= [] ->
    Round = round_state(Sl, S),
    %% A finalizer ahead of the approved frontier revokes voting, not the
    %% exact-parent validation required to install that very finalizer.
    case {is_participant(S), Round#round.dtx_parent} of
        {false, _} -> S;
        {true, {BH, _ParentToken, _Histories, _Projection}} ->
            support_validated_dtx(Block, BH, S);
        {true, _} ->
            case Round#round.validating of
                BH -> S;
                none -> request_dtx_validation(Controls, Block, Sl, BH, S);
                _OtherBH -> S
            end
    end.

request_dtx_validation(Controls, #block{timestamp = BlockTimestamp}, Sl, BH,
                       S = #s{ns = Ns, history_head = ParentToken}) ->
    case {ParentToken, quod_reg:where({quod_prolog, Ns})} of
        {{Parent, <<_:256>>} = Token, Pid}
          when Parent =:= Sl - 1, is_pid(Pid) ->
            Monitor = erlang:monitor(process, Pid),
            Tag = {Sl, BH, Token},
            DeadlineMs = quod_time:mono_ms() + S#s.validation_ttl_ms,
            ok = with_block_context(Sl, BH, S, fun() ->
                quod_prolog:request_dtx_verdict(
                  Ns, {wave, Controls}, BlockTimestamp, Sl, self(), Tag) end),
            Round = round_state(Sl, S),
            put_round(
              Sl,
              Round#round{validating = BH,
                          validation = {dtx, Token, Pid, Monitor, DeadlineMs}}, S);
        _ ->
            S
    end.

support_validated_dtx(Block = #block{slot = Sl}, BH, S) ->
    S1 = engine_step([{block, BH, Block}], S),
    case block_for(BH, S1#s.eng) of
        #block{} -> support_block(Block, BH, S1);
        undefined ->
            clear_dtx_validation(Sl, S1)
    end.

on_dtx_verdict(Sl, BH, ParentToken, EnginePid, AppliedFloor, Verdict,
               S = #s{approved = Approved, history_head = ParentToken})
  when Sl =:= Approved + 1, AppliedFloor >= Sl - 1 ->
    Round = round_state(Sl, S),
    case {Round#round.validating, Round#round.validation,
          Round#round.candidate} of
        {BH, {dtx, ParentToken, EnginePid, _Monitor, DeadlineMs},
         {BH, #block{payload = Payload} = Block}} ->
            trace_block_event(
              Sl, BH, <<"consensus.parent_verdict_received">>,
              #{'quod.validation.kind' => trace_validation_kind(Round),
                'quod.validation.verdict' => trace_validation_class(Verdict)}, S),
            Round0 = release_dtx_validation_round(Round),
            S0 = put_round(Sl, Round0, S),
            continue_dtx_verdict(
              Verdict, Payload, Block, Sl, BH, ParentToken, DeadlineMs, S0);
        _ ->
            discard_stale_dtx_validation(
              Sl, BH, ParentToken, EnginePid, S)
    end;
on_dtx_verdict(Sl, BH, ParentToken, EnginePid, _Floor, _Verdict, S) ->
    discard_stale_dtx_validation(
      Sl, BH, ParentToken, EnginePid, S).

continue_dtx_verdict(
  {valid, Histories}, Payload, Block, Sl, BH, ParentToken, DeadlineMs, S)
  when is_map(Histories) ->
    case quod_ledger:classify(Payload) of
        {controls, Classified} ->
            Controls = [Control || {_Kind, Control} <- Classified],
            case dtx_reference_plan(Controls) of
                {ok, []} ->
                    apply_dtx_verdict(
                      {valid, Histories}, Payload, Block, Sl, BH,
                      ParentToken, S);
                {ok, ReferencePlan} ->
                    start_dtx_foreign_validation(
                      ReferencePlan, Histories, Sl, BH, ParentToken, DeadlineMs, S)
            end;
        _ ->
            reject_dtx_candidate(Sl, BH, malformed_control, S)
    end;
continue_dtx_verdict(Verdict, Payload, Block, Sl, BH, ParentToken, _DeadlineMs, S) ->
    apply_dtx_verdict(
      Verdict, Payload, Block, Sl, BH, ParentToken, S).

start_dtx_foreign_validation(
  ReferencePlan, Histories, Sl, BH, ParentToken, DeadlineMs,
  S = #s{dtx_workers = DtxWorkers}) ->
    Deadline = quod_time:mono_ms() + ?DTX_FOREIGN_VERIFY_MS,
    LocalIdentity = target_identity(S),
    LocalSource = local_history_view(S),
    ValidationSidecar = (round_state(Sl, S))#round.validation_sidecar,
    Contacts = dtx_reference_contacts(
                 ReferencePlan, DtxWorkers, LocalIdentity),
    {Worker, Monitor} = spawn_foreign_validation(
        {Sl, BH}, {dtx_foreign_verdict, {Sl, BH, ParentToken}}, Deadline,
        #{'quod.validation.controls' => length(ReferencePlan)}, S,
        fun() -> {verify_dtx_foreign_references(
            ReferencePlan, LocalIdentity, LocalSource, Contacts, ValidationSidecar, Deadline), Contacts} end),
    Round = round_state(Sl, S),
    put_round(
      Sl,
      Round#round{
        validating = BH,
        validation =
          {dtx_foreign, ParentToken, Worker, Monitor, Histories, DeadlineMs}}, S).

%% Content and atomic controls have the same finite foreign-verification
%% lifetime. Carry its observation context across the process boundary too:
%% a local parent verdict is not yet permission to vote on foreign evidence.
spawn_foreign_validation({Sl, BH}, {Event, Tag}, Deadline, Attributes, S, Verify) ->
    Owner = self(),
    Trace = trace_for_block(Sl, BH, S),
    Location = {S#s.ns, Sl, BH},
    trace_block_event(Sl, BH, <<"consensus.foreign_validation_queued">>, #{}, S),
    spawn_monitor(fun() ->
        {Verdict, Contacts} = quod_consensus_trace:work(
            Trace, Location, <<"quod.consensus.foreign_validation">>, Attributes,
            fun() ->
                {Result, _Contacts} = Verified = Verify(),
                _ = try quod_trace:add_event(quod_trace:context(),
                        <<"consensus.foreign_validation_finished">>,
                        #{'quod.validation.verdict' => trace_validation_class(Result)})
                    catch _:_ -> false end,
                Verified
            end),
        ok = observe_verified_reference_contacts(Verdict, Contacts),
        Owner ! {Event, Tag, self(), Deadline, reference_deadline_result(Deadline, Verdict)}
    end).

on_dtx_foreign_verdict(
  Sl, BH, ParentToken, WorkerPid, Deadline, Verdict0,
  S = #s{approved = Approved, history_head = ParentToken})
  when Sl =:= Approved + 1 ->
    Round = round_state(Sl, S),
    case {Round#round.validating, Round#round.validation,
          Round#round.candidate} of
        {BH,
         {dtx_foreign, ParentToken, WorkerPid, _Monitor, Histories, _DeadlineMs},
         {BH, #block{payload = Payload} = Block}} ->
            Verdict = reference_deadline_result(Deadline, Verdict0),
            trace_block_event(
              Sl, BH, <<"consensus.foreign_validation_received">>,
              #{'quod.validation.verdict' => trace_validation_class(Verdict)}, S),
            S0 = put_round(
                   Sl,
                   release_dtx_validation_round(Round), S),
            case Verdict of
                valid ->
                    apply_dtx_verdict(
                      {valid, Histories}, Payload, Block, Sl, BH,
                      ParentToken, S0);
                {invalid, Reason} ->
                    apply_dtx_verdict(
                      {invalid, Reason}, Payload, Block, Sl, BH,
                      ParentToken, S0);
                abstain ->
                    quod_metrics:count_dtx_validation(S0#s.ns, abstain),
                    clear_dtx_validation(Sl, S0)
            end;
        _ ->
            discard_stale_dtx_validation(
              Sl, BH, ParentToken, WorkerPid, S)
    end;
on_dtx_foreign_verdict(
  Sl, BH, ParentToken, WorkerPid, _Deadline, _Verdict, S) ->
    discard_stale_dtx_validation(
      Sl, BH, ParentToken, WorkerPid, S).

dtx_reference_plan(Controls) when is_list(Controls) ->
    %% The pure extractor is exhaustive over control kinds. Preserve its
    %% per-control result for contact selection, evidence verification, and
    %% final semantic binding instead of deriving the same rows three times.
    dtx_reference_plan(Controls, []).

dtx_reference_plan([], PlanRev) ->
    {ok, lists:reverse(PlanRev)};
dtx_reference_plan([Control | Rest], PlanRev) ->
    case quod_atomic:reference_requirements(quod_atomic:control_material(Control)) of
        [] ->
            dtx_reference_plan(Rest, PlanRev);
        References ->
            dtx_reference_plan(Rest, [{Control, References} | PlanRev])
    end.

verify_dtx_foreign_references(
  ReferencePlan, LocalIdentity, LedgerRoot, Contacts, ValidationSidecar, Deadline)
  when is_list(ReferencePlan) ->
    reference_deadline_result(Deadline,
      verify_dtx_foreign_controls(
        ReferencePlan, LocalIdentity, LedgerRoot, Contacts, ValidationSidecar, Deadline)).

verify_dtx_foreign_controls(
  [], _LocalIdentity, _LedgerRoot, _Contacts, _ValidationSidecar, _Deadline) ->
    valid;
verify_dtx_foreign_controls(
  [{Control, References} | Rest], LocalIdentity, LedgerRoot, Contacts,
  ValidationSidecar, Deadline) ->
    case verify_dtx_control_foreign_references(
           Control, References, LocalIdentity, LedgerRoot, Contacts,
           ValidationSidecar, Deadline) of
        valid ->
            verify_dtx_foreign_controls(
              Rest, LocalIdentity, LedgerRoot, Contacts, ValidationSidecar, Deadline);
        Other -> Other
    end.

verify_dtx_control_foreign_references(
  Control, References, LocalIdentity, LedgerRoot, Contacts,
  ValidationSidecar, Deadline) ->
    verify_dtx_reference_list(
      References, Control, LocalIdentity, LedgerRoot, Contacts,
      maps:from_list(ValidationSidecar), [], Deadline).

verify_dtx_reference_list(
  [], Control, _LocalIdentity, _LedgerRoot, _Contacts, _ValidationSidecar,
  EvidenceRev, _Deadline) ->
    Evidence = lists:reverse(EvidenceRev),
    Bindings = [{Phase, Ref, maps:get(control, Row)}
                || {Phase, Ref, Row} <- Evidence],
    case validate_dtx_reference_evidence(Control, Bindings) of
        ok -> verify_complete_applied(Control, Evidence);
        {error, _} -> {invalid, foreign_reference_binding}
    end;
verify_dtx_reference_list(
  [{Phase, Ref} | Rest], Control, LocalIdentity, LedgerRoot,
  Contacts, ValidationSidecar, EvidenceRev, Deadline) ->
    Result = case quod_dtx:certified_ref_binding(Ref) of
                 {ok, LocalIdentity, _Slot, _Digest} ->
                     verify_local_dtx_reference(
                       Ref, Phase, LocalIdentity, LedgerRoot, Deadline);
                 {ok, ForeignIdentity, _Slot, _Digest} ->
                     verify_remote_dtx_reference(
                       Ref, Phase, ForeignIdentity,
                       reference_contact(Ref, ForeignIdentity, Contacts),
                       maps:get(Ref, ValidationSidecar, none), Deadline);
                 error ->
                     {invalid, malformed_foreign_reference}
             end,
    case Result of
        {valid, ReferencedEvidence} ->
            verify_dtx_reference_list(
              Rest, Control, LocalIdentity, LedgerRoot, Contacts, ValidationSidecar,
              [{Phase, Ref, ReferencedEvidence} | EvidenceRev], Deadline);
        {invalid, _} = Invalid ->
            Invalid;
        abstain ->
            abstain
    end.


verify_complete_applied(Control, Evidence) ->
    case quod_atomic:control_body(Control) of
        {quod_dtx_complete, 4, _, _, _, _, _, []} -> valid;
        {quod_dtx_complete, 4, _, _, _, _, _, _Certificates} ->
            case quod_ontology:network_identity() of
                {ok, NetworkIdentity} ->
                    verify_complete_applied_certificates(Control, Evidence, NetworkIdentity);
                {error, _Unavailable} -> abstain
            end;
        _ -> valid
    end.

%% Exact role/reference/generation correspondence is already checked by the
%% codec's reference binder. The existing AM3 verifier alone checks signatures.
%% These certificates are signed record content, not replaceable sidecars.
verify_complete_applied_certificates(Control, Evidence, NetworkIdentity) ->
    {quod_dtx_complete, 4, _, _, _, _, _, Certificates} = quod_atomic:control_body(Control),
    Rows = maps:from_list([{maps:get(identity, Row), Row} || {resolve, _, Row} <- Evidence]),
    verify_complete_applied_rows(Certificates, Rows, NetworkIdentity).

verify_complete_applied_rows([], _Evidence, _NetworkIdentity) -> valid;
verify_complete_applied_rows([{Target, Certificate} | Rest], Evidence, NetworkIdentity) ->
    case quod_applied_certificate:verify_applied_certificate(
           Certificate, NetworkIdentity, maps:get(Target, Evidence)) of
        true -> verify_complete_applied_rows(Rest, Evidence, NetworkIdentity);
        false -> {invalid, malformed_applied_claim}
    end.

validate_dtx_reference_evidence(Control, Evidence) ->
    quod_atomic:validate_references(
      Control, [{Phase, Ref, quod_atomic:control_material(Referenced)}
                 || {Phase, Ref, Referenced} <- Evidence]).

verify_local_dtx_reference(
  Ref, Phase, _Identity, LocalSource, Deadline) ->
    verify_local_dtx_reference_result(
      quod_foreign_log:verify_local_deadline(LocalSource, Ref, Phase, Deadline)).

reference_deadline_result(Deadline, Result) ->
    case Deadline > quod_time:mono_ms() of
        true -> Result;
        false -> abstain
    end.

%% One captured object for both callers and internal validation workers. The
%% session owns no descriptor; borrowers open and close their own bounded read.
local_history_view(S = #s{store = Store, slot = Slot, last_applied = Applied}) ->
    #{owner => self(), identity => target_identity(S),
      slot => Slot, applied => Applied,
      snapshot => quod_ledger_store:snapshot(Store),
      projection => captured_history_projection(S)}.

-ifdef(TEST).
%% Pure gate fixtures may omit storage. Every founded production owner has
%% an index; retained-history regressions use the real index, never this arm.
captured_history_projection(S = #s{phase_index = undefined}) -> state_projection(S);
captured_history_projection(S) -> captured_history_projection_indexed(S).
-else.
captured_history_projection(S) -> captured_history_projection_indexed(S).
-endif.

captured_history_projection_indexed(S = #s{phase_index = Index, slot = H}) ->
    {ok, View} = quod_dtx_phase_index:capture(Index, H),
    (state_projection(S))#{history_index => View}.

-ifdef(TEST).
retain_owner_projection(P, _Delta, #s{phase_index = undefined}) -> P;
retain_owner_projection(P, Delta, S) -> retain_owner_projection_indexed(P, Delta, S).
-else.
retain_owner_projection(P, Delta, S) -> retain_owner_projection_indexed(P, Delta, S).
-endif.

retain_owner_projection_indexed(P = #{committee_views := Views}, Delta0, #s{phase_index = Index}) ->
    Delta = case Views of
        [Current | _] -> quod_dtx_phase_index:preview_committee(Delta0, Current);
        [] -> Delta0
    end,
    %% The ledger is already durable. Failure here is engine death, never a
    %% return to a pre-append state or publication with an outdated index.
    ok = quod_dtx_phase_index:commit_delta(Index, Delta),
    P#{committee_views := lists:sublist(Views, 1)}.

verify_local_dtx_reference_result(
  {ok, #{transaction := _Transaction} = Evidence}) ->
    {valid, Evidence};
verify_local_dtx_reference_result(
  {ok, #{control := _Control} = Evidence}) ->
    {valid, Evidence};
verify_local_dtx_reference_result({ok, _MalformedEvidence}) ->
    {invalid, foreign_reference};
verify_local_dtx_reference_result({error, phase_mismatch}) ->
    {invalid, foreign_phase};
verify_local_dtx_reference_result({error, invalid_foreign_reference}) ->
    {invalid, foreign_reference};
verify_local_dtx_reference_result({error, bad_foreign_reference}) ->
    {invalid, foreign_reference};
verify_local_dtx_reference_result({error, _Unavailable}) ->
    abstain.

local_dtx_evidence_source(
  Ref, ExpectedPhase,
  S = #s{slot = Committed}) ->
    TargetIdentity = target_identity(S),
    case {local_history_view(TargetIdentity, any, S),
          valid_dtx_phase(ExpectedPhase),
          quod_dtx:certified_ref_binding(Ref)} of
        {{ok, View}, true, {ok, TargetIdentity, Slot, _Digest}}
          when Slot =< Committed ->
            {ok, View};
        {{ok, _View}, true, {ok, TargetIdentity, Slot, _Digest}}
          when Slot > Committed ->
            {error, not_found};
        {{error, not_ready}, _, _} ->
            {error, not_ready};
        _ ->
            {error, invalid_request}
    end.

local_history_view(Identity, Requirement, Deadline, S) ->
    case {Deadline > quod_time:mono_ms(),
          history_view_live(#{owner => self(), identity => target_identity(S)})} of
        {false, _} -> {error, timeout};
        {true, false} -> {error, not_ready};
        {true, true} -> local_history_view(Identity, Requirement, S)
    end.

local_history_view(Identity, Requirement, S = #s{ns = Ns, store = Store}) ->
    ExactIdentity = target_identity(S),
    {Committed, Minimum} = case Requirement of
        {committed, Slot} when is_integer(Slot), Slot > 0 -> {true, Slot};
        committed -> {true, 0};
        _ -> {false, 0}
    end,
    case {Identity =:= Ns orelse Identity =:= ExactIdentity,
          Requirement =/= validator orelse is_participant(S),
          Committed orelse endpoint_read_ready(S),
          ExactIdentity, Store} of
        {false, _, _, _, _} -> {error, invalid_identity};
        {true, false, _, _, _} -> {error, read_certificate_unavailable};
        {true, true, true, {Ns, <<_:256>>}, Store} when Store =/= undefined ->
            case quod_ledger_store:last(Store) =:= S#s.slot andalso
                 (S#s.slot > 0 orelse Committed) of
                true when S#s.slot >= Minimum -> {ok, local_history_view(S)};
                true -> {pending, S#s.slot};
                false -> {error, not_ready}
            end;
        _ -> {error, not_ready}
    end.

valid_dtx_phase(entry) -> true;
valid_dtx_phase(transaction) -> true;
valid_dtx_phase(vote) -> true;
valid_dtx_phase(resolve) -> true;
valid_dtx_phase(complete) -> true;
valid_dtx_phase(_) -> false.

verify_remote_dtx_reference(Ref, Phase, Identity, Contact, Deadline) ->
    verify_remote_dtx_reference(Ref, Phase, Identity, Contact, none, Deadline).

verify_remote_dtx_reference(Ref, Phase, Identity, Contact, EntryHint, Deadline) ->
    verify_remote_dtx_reference_result(
      quod_foreign_log:resolve_reference(
        Identity, Ref, Phase, Contact, EntryHint, Deadline)).

verify_remote_dtx_reference_result(Result) ->
    case Result of
        {ok, #{transaction := _Transaction} = Evidence} ->
            {valid, Evidence};
        {ok, #{control := _Control} = Evidence} ->
            {valid, Evidence};
        {ok, _MalformedEvidence} ->
            {invalid, foreign_reference};
        {error, phase_mismatch} ->
            {invalid, foreign_reference};
        {error, invalid_foreign_reference} ->
            {invalid, foreign_reference};
        {error, bad_foreign_reference} ->
            {invalid, foreign_reference};
        {error, _Unavailable} ->
            abstain
    end.

apply_dtx_verdict({valid, Histories}, Payload, Block, Sl, BH, ParentToken,
                  S = #s{dtx_projection = ParentProjection}) ->
    case quod_ledger:classify(Payload) of
        {controls, Classified} ->
            case preview_dtx_controls(Classified, {target_identity(S), Sl, BH},
                                      Histories, ParentProjection, []) of
                {ok, _PreviewHistories, _PreviewProjection, _Items} ->
                    Round = round_state(Sl, S),
                    S1 = put_round(
                           Sl,
                           Round#round{
                             dtx_parent =
                                 {BH, ParentToken, Histories,
                                  ParentProjection}}, S),
                    support_validated_dtx(Block, BH, S1);
                {error, Reason} ->
                    reject_invalid_dtx_candidate(
                      Payload, Sl, BH, Reason, S)
            end;
        _ ->
            reject_dtx_candidate(Sl, BH, malformed_control, S)
    end;
apply_dtx_verdict({invalid, Reasons}, Payload, _Block, Sl, BH,
                  _ParentToken, S0) ->
    %% Retained local work owns a caller even when an equivalent peer envelope
    %% wins proposal placement.  A deterministic invalid verdict therefore
    %% removes the exact candidate from proposal work. Own Votes return to the
    %% same admission FIFO for parent-bound reselection; other records release
    %% their waiter as retryable. No uncommitted rejection decides the group.
    reject_invalid_dtx_candidate(Payload, Sl, BH, Reasons, S0);
apply_dtx_verdict(abstain, _Payload, _Block, Sl, _BH, _ParentToken,
                  S = #s{ns = Ns}) ->
    quod_metrics:count_dtx_validation(Ns, abstain),
    clear_dtx_validation(Sl, S);
apply_dtx_verdict(_Malformed, _Payload, _Block, Sl, BH, _ParentToken, S) ->
    reject_dtx_candidate(Sl, BH, malformed_verdict, S).

%% Decoded controls already own authenticated material. Preview never repeats
%% plan/signature validation or stores a second material copy per candidate.
preview_dtx_controls([], _Location, Histories, Projection, Candidates) ->
    quod_atomic:preview_batch(lists:reverse(Candidates), Histories, Projection);
preview_dtx_controls([{_Kind, Control} | Rest], {Target, Sl, BH} = Location,
                     Histories, Projection, Candidates) ->
    preview_dtx_controls(Rest, Location, Histories, Projection,
                         [{Control, Target, Sl, BH} | Candidates]).

%% Reference verification and the pure committed-state preview are the two
%% halves of one candidate verdict.  Once either half deterministically
%% rejects an exact locally retained control, leaving it proposal-ready would
%% make consensus select and reject the same immutable bytes forever.
reject_invalid_dtx_candidate(Payload, Sl, BH, Reason, S0) ->
    Reasons = invalid_dtx_submission_reasons(Reason),
    S = retire_invalid_dtx_submission(Payload, Reasons, S0),
    reject_dtx_candidate(Sl, BH, Reason, S).

invalid_dtx_submission_reasons([_ | _] = Reasons) -> Reasons;
invalid_dtx_submission_reasons(Reason) -> [Reason].

reject_dtx_candidate(Sl, BH, Reason, S) ->
    Round = round_state(Sl, S),
    S1 = put_round(
           Sl,
           Round#round{invalid = BH, invalid_reason = Reason,
                       validating = none, validation = none,
                       candidate = none, validation_sidecar = [],
                       dtx_parent = none}, S),
    choose_final_vote(Sl, rejected, S1).

retire_invalid_dtx_submission(Payload, _Reasons, S) ->
    case quod_ledger:classify(Payload) of
        {controls, Controls} ->
            lists:foldl(fun({_Kind, Control}, Acc) ->
                Digest = quod_atomic:record_digest(Control),
                case maps:find(Digest, quod_dtx_owner:rows(Acc#s.retained_dtx)) of
                    {ok, Row} ->
                        case local_owned_vote(Row, Acc) of
                            true -> requeue_owned_vote(Row, Acc);
                            false -> finish_pending_votes_reconciliation(
                                       finish_retained_dtx(Digest, rejected, {error, retry}, Acc))
                        end;
                    error -> Acc
                end
            end, S, Controls);
        _ -> S
    end.

clear_dtx_validation(Sl, S) ->
    Round = round_state(Sl, S),
    put_round(
      Sl,
      (release_dtx_validation_round(Round))#round{
        candidate = none, validation_sidecar = []}, S).

release_dtx_validation_round(Round) ->
    _ = release_validation_monitor(Round),
    Round#round{validating = none, validation = none,
                dtx_parent = none}.

release_validation_monitor(
  #round{validation = {content_foreign, _Pid, Monitor}}) ->
    erlang:demonitor(Monitor, [flush]);
release_validation_monitor(
  #round{validation = {dtx, _Token, _Pid, Monitor, _DeadlineMs}}) ->
    erlang:demonitor(Monitor, [flush]);
release_validation_monitor(
  #round{validation = {dtx_foreign, _Token, _Pid, Monitor, _History, _DeadlineMs}}) ->
    erlang:demonitor(Monitor, [flush]);
release_validation_monitor(#round{}) ->
    false.

dtx_validation_active(#round{validation = {dtx, _, _, _, _}}) -> true;
dtx_validation_active(
  #round{validation = {dtx_foreign, _, _, _, _, _}}) -> true;
dtx_validation_active(#round{}) -> false.

%% A verdict whose exact request no longer matches the candidate/head/floor is
%% obsolete. Discard that request and candidate together; normal progress is
%% never a timer-driven revalidation loop. A late verdict from an older owner
%% remains an exact no-op and cannot clear a newer request for the same slot.
discard_stale_dtx_validation(Sl, BH, ParentToken, EnginePid, S) ->
    Round = round_state(Sl, S),
    case {Round#round.validating, dtx_validation_owner(Round)} of
        {BH, {ParentToken, EnginePid, _DeadlineMs}} ->
            clear_dtx_validation(Sl, S);
        _ ->
            S
    end.

dtx_validation_owner(
  #round{validation = {dtx, ParentToken, Pid, _Monitor, DeadlineMs}}) ->
    {ParentToken, Pid, DeadlineMs};
dtx_validation_owner(
  #round{validation =
           {dtx_foreign, ParentToken, Pid, _Monitor, _History, DeadlineMs}}) ->
    {ParentToken, Pid, DeadlineMs};
dtx_validation_owner(#round{}) ->
    none.

drop_dtx_validation_monitor(Ref, Pid, S = #s{rounds = Rounds}) ->
    case [Sl || {Sl, Round} <- maps:to_list(Rounds),
                dtx_validation_monitor(Round) =:= {Pid, Ref}] of
        [Sl] ->
            Round = round_state(Sl, S),
            trace_block_event(
              Sl, Round#round.validating, <<"consensus.validation_worker_down">>,
              #{'quod.validation.kind' => trace_validation_kind(Round)}, S),
            {true, put_round(
                     Sl, release_dtx_validation_round(Round), S)};
        [] ->
            false
    end.

dtx_validation_monitor(#round{validation = {dtx, _Token, Pid, Ref, _DeadlineMs}}) ->
    {Pid, Ref};
dtx_validation_monitor(
  #round{validation = {content_foreign, Pid, Ref}}) ->
    {Pid, Ref};
dtx_validation_monitor(
  #round{validation = {dtx_foreign, _Token, Pid, Ref, _History, _DeadlineMs}}) ->
    {Pid, Ref};
dtx_validation_monitor(#round{}) ->
    none.

%% The KB verdict for a membership proposal we deferred, correlated to the exact block by `{Sl, BH}`: `valid`
%% ⇒ emit the deferred support share; `invalid` ⇒ latch its hash in `#round.invalid` (so we never endorse it at any phase —
%% see `apply_event({notarized,...})`) and count it; `abstain` ⇒ neither (a peer-formed support cert may still
%% notarize; if enough nodes abstain the slot Δ-skips). A verdict is acted on ONLY if `{Sl, BH}` still matches
%% what we are validating AND `Sl` is still head+1 — so a stale verdict (slot finalized, or a DIFFERENT block
%% now validating under leader equivocation) is dropped, never applied to the wrong block.
on_content_verdict(Sl, BH, Verdict, S = #s{approved = Approved})
  when Sl =:= Approved + 1 ->
    Round = round_state(Sl, S),
    case {Round#round.validating, Round#round.validation} of
        {BH, content} ->
            trace_block_event(
              Sl, BH, <<"consensus.parent_verdict_received">>,
              #{'quod.validation.verdict' => trace_validation_class(Verdict)}, S),
            S1 = put_round(
                   Sl,
                   Round#round{validating = none, validation = none}, S),
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
on_content_verdict(_Sl, _BH, _Verdict, S) -> S.

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

head_has_evidence(V, #s{eng = #eng{blocks = Blocks, shares = Shares}, self = Self,
                        rounds = Rounds,
                        local_proposals = Local, collecting = Collecting,
                        commit_buf = CommitBuf} = S) ->
    Complaints = maps:get({complaint, V, none}, Shares, #{}),
    maps:is_key(V, Rounds)
        orelse maps:is_key(V, Local)
        orelse maps:is_key(V, CommitBuf)
        orelse lists:any(fun(#block{slot = Sl}) -> Sl =:= V end, maps:values(Blocks))
        orelse case Collecting of #batch{slot = V} -> true; _ -> false end
        %% Only the engine's verified current-peer evidence creates demand.
        %% It arms the existing head watchdog; choosing a final vote still
        %% requires the ordinary timeout/readiness or f+1 amplification path.
        orelse lists:any(fun(Peer) -> Peer =/= Self andalso maps:is_key(Peer, Complaints) end,
                         active_validators(S));
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
    keep_progress(S0, S1, Actions, TimerMode, ordinary).

keep_progress(S0, S1, Actions, TimerMode, ReadyBoundary) ->
    ActionsRev0 = lists:reverse(Actions),
    BeforeIngress = (refresh_ingress_view(S0))#s.ingress,
    SReady = timed_step(S1, readiness,
                        fun() -> settle_readiness(
                                   S0, maybe_mark_ready(S1, ReadyBoundary)) end),
    SRecovered = timed_step(SReady, reconcile,
                            fun() -> reconcile_block_requests(SReady) end),
    SClassified = timed_step(
                    SRecovered, dtx_reclassify,
                    fun() -> finish_pending_votes_reconciliation(
                               settle_retained_dtx(S0, SRecovered)) end),
    {SAdmitted, ActionsRevAdmission} =
        timed_step(SClassified, dtx_admission,
                   fun() -> progress_dtx_admission(SClassified, ActionsRev0) end),
    SCoordinated = timed_step(
                     SAdmitted, dtx_coordinator,
                     fun() -> reconcile_dtx_coordinator(SAdmitted) end),
    SOperations = timed_step(
                    SCoordinated, operation_recovery,
                    fun() -> reconcile_operation_recoveries(
                               SCoordinated) end),
    SDtx = timed_step(SOperations, dtx_drive,
                      fun() -> drive_retained_dtx(SOperations) end),
    SCustodyReady =
        timed_step(
          SDtx, custody_reconcile,
          fun() -> reconcile_custody_lane(SDtx) end),
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
                            SCustodyView, ActionsRevAdmission, 0);
                      none ->
                          {SCustodyView, ActionsRevAdmission}
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
    S2 = track_owner_peaks(
           timed_step(SAdvertised, head_reconcile,
                      fun() -> reconcile_head_progress(SAdvertised) end)),
    ok = notify_dtx_coordinator_progress(S0, S2),
    ok = wake_dtx_snapshot_workers(S0, S2),
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
%% A pause retains custody but cannot renew its signature. The original owner
%% readiness edge resumes the same classified rows before their next drive.
settle_retained_dtx(S0, S1) ->
    {Classified, Retired} = refresh_retained_readiness(S1),
    case not endpoint_write_ready(S0) andalso endpoint_write_ready(Classified) of
        true ->
            {Renewed, Cleared} = refresh_retained_dtx_signatures(Classified),
            {Renewed, merge_pending_votes_reconciliation(Retired, Cleared)};
        false -> {Classified, Retired}
    end.

settle_readiness(S0, S1) ->
    %% The installed parent is a readiness edge even if voting never changed.
    case {S0#s.history_head, may_vote(S0)} =:= {S1#s.history_head, may_vote(S1)} of
        true -> S1;
        false -> resume_ready_rounds(S1)
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
    trace_slot_event(
      V, <<"consensus.watchdog_fired">>,
      #{'quod.consensus.phase' => atom_to_binary(Phase, utf8),
        'quod.validation.kind' => trace_validation_kind(round_state(V, S0)),
        'quod.kb.last_dispatched_height' => S0#s.last_applied}, S0),
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
        #local_proposal{hash = BH, validation_sidecar = ValidationSidecar} ->
            case block_for(BH, S0#s.eng) of
                #block{} = Block ->
                    %% Membership proposals re-enter their common verdict path; an outstanding verdict is
                    %% idempotent, and an abstention may be retried. Do this before rebuilding vote frames.
                    S1 = support_or_validate(Block, BH, S0),
                    case Slot > S1#s.slot of
                        true  ->
                            trace_block_event(
                              Slot, BH, <<"consensus.proposal_redriven">>,
                              #{'quod.validation.kind' => trace_validation_kind(round_state(Slot, S1))}, S1),
                            {[{propose, Block, ValidationSidecar}],
                             S1#s{redrives = S1#s.redrives + 1}};
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

%% One recovery selection: finality belongs to the certified-history worker;
%% only not-yet-finalized proposals need the support-certificate block walk.
%% Finality is authenticated engine state, never a peer height or readiness hint.
reconcile_block_requests(S = #s{eng = undefined}) -> S;
reconcile_block_requests(S0 = #s{slot = Committed, eng = Eng, block_requests = Requests0}) ->
    Recovering = maybe_arm_sync(S0),
    FinalizedThrough = ahead_cert_ceiling(Eng),
    Missing = lists:sort(
                [{Slot, BH, Cert}
                 || {{support, Slot, BH}, #cert{} = Cert} <- maps:to_list(Eng#eng.certs),
                    live_pipeline_slot(Slot, Committed),
                    Slot > FinalizedThrough,
                    block_for(BH, Eng) =:= undefined]),
    LiveKeys = [{Slot, BH} || {Slot, BH, _Cert} <- Missing],
    Requests1 = maps:filter(fun(Key, _Value) -> lists:member(Key, LiveKeys) end, Requests0),
    S1 = Recovering#s{block_requests = Requests1},
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

%% Reconcile a member's bounded live rounds on parent/capability progress.
%% Certified tree entries restore final-vote latches through the existing
%% signing gate. Pending DTX candidates request their exact-parent verdict;
%% a later finalizer must not make that validation depend on voting readiness.
%% Neither action invents a support vote or bypasses the Prolog verdict.
resume_ready_rounds(S) ->
    case is_participant(S) of
        false -> S;
        true ->
            %% Snapshot only slot numbers. A vote in an earlier iteration can finalize and prune later
            %% entries via commit_buf; resume_ready_slot/2 re-reads the current tree on every step.
            Slots = lists:sort([Sl || Sl <- maps:keys((S#s.eng)#eng.tree),
                                     Sl > S#s.slot]),
            S1 = lists:foldl(
                   fun resume_ready_slot/2,
                   S, Slots),
            resume_proposals(S1)
    end.

resume_proposals(S = #s{rounds = Rounds}) ->
    lists:foldl(fun advance_proposal/2, S, lists:sort(maps:keys(Rounds))).

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
    case record_share(Kind, V, BH, none, S) of
        blocked -> S;
        {ok, Share, S1} ->
            %% The durable latch is installed before the share enters either the engine or transport. If this
            %% share completes a certificate synchronously, every nested event sees the same final decision.
            engine_step([{share, Share}], broadcast({share, Share}, S1))
    end.

%% The sole constructor for NEW runtime consensus evidence. The decision is durable before the
%% signature can become network-visible; an I/O failure fail-stops this validator before it can
%% equivocate. Redrive reconstructs an identical Ed25519 share only from the resulting latch.
record_share(Kind, Slot, BlockHash, Block,
             S = #s{signing_journal = Journal}) ->
    case may_vote(S) of
        false ->
            blocked;
        true ->
            {ok, Journal1} = trace_block_work(
                               Slot, BlockHash, <<"quod.signing_journal.vote_sync">>,
                               #{'quod.vote.kind' => atom_to_binary(Kind, utf8)}, S,
                               fun() ->
                                   record_signing_decision(
                                     S#s.ns, Journal, Kind, Slot,
                                     BlockHash, Block)
                               end),
            Round = round_state(Slot, S),
            Round1 = case Kind of
                         support   -> Round#round{supporting = BlockHash};
                         commit    -> Round#round{final = {commit, BlockHash}};
                         complaint -> Round#round{final = complaint}
                     end,
            S1 = put_round(Slot, Round1, S#s{signing_journal = Journal1}),
            trace_block_event(
              Slot, BlockHash, <<"consensus.vote_durable">>,
              #{'quod.vote.kind' => atom_to_binary(Kind, utf8)}, S1),
            {ok, make_share(S#s.consensus_domain, Kind, Slot, BlockHash, S#s.id), S1}
    end.

-ifdef(TEST).
record_signing_decision(_Ns, memory, _Kind, _Slot, _BlockHash, _Block) ->
    {ok, memory};
record_signing_decision(Ns, Journal, Kind, Slot, BlockHash, Block) ->
    record_signing_decision_journal(
      Ns, Journal, Kind, Slot, BlockHash, Block).
-else.
record_signing_decision(Ns, Journal, Kind, Slot, BlockHash, Block) ->
    record_signing_decision_journal(
      Ns, Journal, Kind, Slot, BlockHash, Block).
-endif.
record_signing_decision_journal(
  _Ns, undefined, Kind, Slot, BlockHash, _Block) ->
    error({signing_journal_unavailable, Kind, Slot, BlockHash});
record_signing_decision_journal(
  Ns, Journal, support, Slot, BlockHash,
  #block{slot = Slot} = Block) ->
    true = block_hash(Block) =:= BlockHash,
    Started = erlang:monotonic_time(),
    Result = quod_signing_journal:record_support(Journal, Block),
    quod_metrics:observe_signing_journal_vote_sync(
      Ns, erlang:monotonic_time() - Started),
    Result;
record_signing_decision_journal(
  Ns, Journal, Kind, Slot, BlockHash, none)
  when Kind =:= commit; Kind =:= complaint ->
    Started = erlang:monotonic_time(),
    Result = quod_signing_journal:record_vote(
               Journal, Kind, Slot, BlockHash),
    quod_metrics:observe_signing_journal_vote_sync(
      Ns, erlang:monotonic_time() - Started),
    Result.

%% Reconstruct already-durable evidence for retransmission. The latch check is part of this function,
%% so no caller can turn it into an unjournaled share constructor by supplying arbitrary arguments.
%% Tests and certificate verification use `make_share/5` directly; normal first emission must pass
%% through `record_share/5` above.
own_share(Kind, Slot, BlockHash, S = #s{}) ->
    case may_vote(S) of
        true -> latched_share(Kind, Slot, BlockHash, S);
        false -> blocked
    end.

%% Recovery may reconstruct an identical already-exposed signature before tip
%% corroboration, but it can never create a new decision: the durable latch is
%% still the sole authority. The share enters the ordinary engine locally;
%% normal readiness gates continue to own outbound evidence and fresh votes.
latched_share(Kind, Slot, BlockHash,
              #s{id = Id, consensus_domain = Domain} = S) ->
    case vote_is_latched(Kind, BlockHash, round_state(Slot, S)) of
        true -> {ok, make_share(Domain, Kind, Slot, BlockHash, Id)};
        false -> blocked
    end.

vote_is_latched(support, BH, #round{supporting = BH}) -> true;
vote_is_latched(commit, BH, #round{final = {commit, BH}}) -> true;
vote_is_latched(complaint, none, #round{final = complaint}) -> true;
vote_is_latched(_Kind, _BH, #round{}) -> false.

valid_proposal(#block{slot = Sl, parent = P, payload = Payload} = Block,
               #s{slot = Committed, approved = Approved} = S) ->
    Sl =:= Approved + 1
        andalso P =:= Approved
        andalso live_pipeline_slot(Sl, Committed)
        andalso payload_admission_open(Sl, Payload, S)
        andalso block_material_admissible(Block, parent_timestamp(P, S), S).

%% Both receipt authorities use this one material check after eligibility.
%% The existing held-proposal timeout check shares its consensus-sensitive tail.
block_material_admissible(#block{payload = Payload, timestamp = Ts}, ParentTs, S) ->
    ts_acceptable(Ts, ParentTs, quod_time:now_ms())
        andalso acceptable_payload(Payload, S).

payload_admission_open(Slot, Payload, S) ->
    case quod_ledger:classify(Payload) of
        {content, Transactions} ->
            not consensus_barrier(S)
                andalso membership_admission_open(Transactions, S)
                andalso lists:all(
                          fun(Transaction) ->
                                  quod_atomic:content_readiness(
                                    Transaction, S#s.dtx_projection) =:= ready
                          end, Transactions);
        {controls, _Controls} ->
            dtx_payload_admission_open(Slot, S);
        noop ->
            false;
        invalid ->
            false
    end.

dtx_payload_admission_open(
  Slot, #s{slot = Committed, eng = #eng{tree = Tree}, rounds = Rounds}) ->
    EarlierBarrier =
        lists:any(
          fun({Sl, #block{payload = Payload}}) ->
                  Sl > Committed andalso Sl < Slot
                      andalso payload_is_consensus_barrier(Payload)
          end, maps:to_list(Tree)),
    EarlierValidation =
        lists:any(
          fun({Sl, Round}) ->
                  Sl > Committed andalso Sl < Slot
                      andalso dtx_validation_active(Round)
          end, maps:to_list(Rounds)),
    not EarlierBarrier andalso not EarlierValidation.

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
%% additionally passes the membership gate (`membership_change_ok/2`): shape, never-empty floor, and
%% the shared validator cap,
%% enforced at BOTH proposal seams (the leader gates its own input in `handle_append`; every validator
%% gates a peer's proposal in `block_material_admissible` before support-signing) — so an unacceptable membership
%% change never reaches a support quorum and can never commit. This is the PURE shape+floor+cap gate; a peer
%% that passes it then also defers its support to the shared KB content verdict
%% (`support_or_validate/2` → `quod_prolog:request_content_verdict/6`).
%% Committed history is both cert-verified and checked against
%% the signed-transaction rules during catch-up and local rebuild.
%% The whole transaction is checked before voting: identifiers and timestamps have their canonical
%% shapes, the OCC read-set is a map of exact mutation-version tokens, and every diff element is a legal
%% assert/retract over an Erlog clause. This makes apply/restart a total operation over every block an
%% honest validator can endorse. The recursive diff check also rejects an improper list such as
%% `[Op | junk]`, which a shallow cons-cell match would otherwise admit from the untrusted wire.
acceptable_payload({batch, [#transaction{} | _] = Transactions}, S) ->
    acceptable_payload_content(Transactions, S, verify_id)
        andalso verify_transaction_signatures(
                  target_identity(S), S#s.author_admissions,
                  Transactions, live);
%% DTX controls are canonical same-phase barriers. This seam pays only bounded
%% envelope, signature, admission-generation and sequence checks; exact group
%% history and (for Vote) parent-KB policy are validated asynchronously
%% before the block enters the consensus engine.
acceptable_payload({batch, [{dtx, _} | _]} = Payload, S) ->
    encoded_block_payload_fits(Payload)
        andalso dtx_payload_acceptable(quod_ledger:classify(Payload), S);
acceptable_payload(_Payload, _S) -> false.

dtx_payload_acceptable({controls, Controls},
                       S = #s{author_admissions = Admissions,
                              dtx_lanes = Lanes,
dtx_projection = Dtx}) ->
    Dtx =/= undefined andalso
        lists:all(
          fun({_Kind, Control}) ->
                  dtx_control_acceptable(Control, Admissions, Lanes, S)
          end, Controls);
dtx_payload_acceptable(_Classified, _S) ->
    false.

dtx_control_acceptable(Control, Admissions, Lanes, S) ->
    Meta = quod_atomic:control_metadata(Control),
    Author = maps:get(author, Meta),
    Admission = maps:get(author_admission, Meta),
    Sequence = maps:get(sequence, Meta),
    Lane = {Admission, Author},
    maps:get(Author, Admissions, undefined) =:= Admission
        andalso Sequence > maps:get(Lane, Lanes, 0)
        andalso quod_atomic:verify_control(target_identity(S), Control).

%% Transactions entering this node's local batch have one of two trusted
%% provenance checks: this node just signed them, or a relay submission was
%% authenticated and verified before its opaque bytes were decoded. Keep the
%% structural/authorization checks here. The leader does not cryptographically
%% verify signatures it just created, and relay signatures were already verified
%% over opaque bytes before decode. Every other validator independently verifies
%% the complete proposed batch in acceptable_payload/2 before voting.
acceptable_collected_payload([#transaction{} | _] = Payload, S) ->
    membership_admission_open(Payload, S)
        andalso acceptable_payload_content(Payload, S, prevalidated);
acceptable_collected_payload(_Payload, _S) ->
    false.

acceptable_payload_content(Payload, S, Validation) ->
    bounded_transaction_list(Payload)
        andalso encoded_block_payload_fits({batch, Payload})
        andalso lists:all(
                  fun(Change) ->
                      collected_change_acceptable(Validation, Change, S)
                  end, Payload)
        andalso unique_tx_ids(Payload)
        andalso sequence_payload_ok(Payload, S)
        andalso membership_batch_shape_ok(Payload).

collected_change_acceptable(verify_id, Change, S) ->
    ingress_change_acceptable(Change, S);
collected_change_acceptable(
  prevalidated,
  #transaction{author = Author, proof_id = ProofId} = Change,
  #s{validators = Vs}) ->
    %% Each collected request already passed ingress validation before it was
    %% queued. Local signing changes only author_seq/sig, neither of which is
    %% part of the semantic id; custody/relay bytes were authenticated before
    %% decode. Re-run the bounded shape/authorization checks, but do not hash
    %% the full transaction a second time on the serial proposal path.
    lists:member(Author, Vs)
        andalso ProofId =/= none
        andalso change_acceptable(Change, Vs);
collected_change_acceptable(prevalidated, _Change, _S) ->
    false.

%% The origin identity is any well-shaped ontology identity — foreign origins
%% are the point of the plan-carrying envelope. The target binding is enforced
%% by the signature itself (`quod_transaction:bytes/2` covers this validator's
%% own `{Ns, Anchor}`), not by a field comparison. Plan provenance is required
%% HERE, at ingress, for the same reason history validation requires it: live
%% acceptance and replay must agree on every committed byte, and only genesis
%% is plan-less.
ingress_change_acceptable(#transaction{author = Author,
                                       proof_id = ProofId} = Change,
                          #s{validators = Vs} = S) ->
    lists:member(Author, Vs)
        andalso ProofId =/= none
        andalso valid_target_transaction_id(target_identity(S), Change)
        andalso change_acceptable(Change, Vs);
ingress_change_acceptable(_Change, _S) ->
    false.

bounded_transaction_list([]) ->
    true;
bounded_transaction_list([#transaction{} | Rest]) ->
    bounded_transaction_list(Rest);
bounded_transaction_list(_Other) ->
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

%% Advance the ordinary-content sequence projection from one exact tagged
%% block/entry payload. DTX owns a separate admission-scoped lane; its five
%% cases stay explicit here so they cannot accidentally contaminate this map.
advance_author_seqs(Data, Seqs) ->
    case quod_ledger:classify(Data) of
        {content, Transactions} -> advance_content_author_seqs(Transactions, Seqs);
        {controls, _Controls} -> Seqs;
        noop -> Seqs;
        invalid -> Seqs
    end.

advance_content_author_seqs(Transactions, Seqs) ->
    lists:foldl(
      fun(#transaction{author = Author, author_seq = Seq}, Acc)
            when is_integer(Seq), Seq >= 0 ->
              Acc#{Author => max(Seq, maps:get(Author, Acc, 0))};
         (_, Acc) ->
              Acc
      end, Seqs, Transactions).

%% Durable-parent readiness is eligibility, not permanent material invalidity.
%% Invalid batch shapes still reach the shared material gate, never wait here.
membership_admission_open(Payload, #s{approved = Approved, slot = Committed}) ->
    case membership_payload_shape(Payload) of
        singleton -> Approved =:= Committed;
        _ -> true
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

transactions_touch_committee(Transactions) ->
    lists:any(fun is_membership_change/1, Transactions).

transactions_require_parent_validation(Transactions) ->
    transactions_touch_committee(Transactions) orelse
        quod_transaction:requires_network_identity(Transactions).

%% A DTX-tagged batch is a barrier even if malformed. The owner need not
%% decode its signed contents to answer this conservative scheduling query.
payload_is_consensus_barrier({batch, [{dtx, _} | _]}) -> true;
payload_is_consensus_barrier(Data) ->
    case quod_ledger:classify(Data) of
        {content, Transactions} -> transactions_touch_committee(Transactions);
        {controls, _Controls} -> true;
        noop -> false;
        invalid -> true
    end.

is_membership_change(Change) -> committee_delta(Change) =/= {[], []}.

%% The pure acceptance decision over a validator LIST (exported for eunit; the `#s`-wrapper above is
%% what the propose/support call sites use).
change_acceptable(#transaction{tx_id = TxId, origin = Origin,
                               proof_id = ProofId, plan_digest = PlanDigest,
                               goal = Goal, result = Result,
                               diff = Diff,
                               read_check = ReadCheck, author = Author,
                               author_seq = AuthorSeq,
                               submitted_at = SubmittedAt, sig = Sig} = T, Vs) ->
    well_formed_transaction_fields(TxId, Origin, ProofId, PlanDigest,
                                   Goal, Result,
                                   Diff, ReadCheck, Author,
                                   AuthorSeq, SubmittedAt, Sig)
        andalso (not touches_committee(Diff) orelse membership_change_ok(T, Vs));
change_acceptable(_, _)      -> false.

-spec well_formed_transaction(term()) -> boolean().
well_formed_transaction(#transaction{tx_id = TxId, origin = Origin,
                                     proof_id = ProofId,
                                     plan_digest = PlanDigest,
                                     goal = Goal, result = Result, diff = Diff,
                                     read_check = ReadCheck, author = Author,
                                     author_seq = AuthorSeq,
                                     submitted_at = SubmittedAt, sig = Sig}) ->
    well_formed_transaction_fields(TxId, Origin, ProofId, PlanDigest,
                                   Goal, Result,
                                   Diff, ReadCheck, Author,
                                   AuthorSeq, SubmittedAt, Sig);
well_formed_transaction(_) -> false.

well_formed_transaction_fields(TxId, Origin, ProofId, PlanDigest,
                               Goal, Result,
                               Diff, ReadCheck, Author,
                               AuthorSeq, SubmittedAt, Sig) ->
    nonempty_binary(TxId)
        andalso valid_transaction_origin(Origin)
        andalso valid_plan_binding(ProofId, PlanDigest)
        andalso valid_durable_proof(ProofId, Goal, Result)
        andalso is_binary(Author) andalso byte_size(Author) =:= 32
        andalso is_integer(AuthorSeq) andalso AuthorSeq >= 0
        andalso is_integer(SubmittedAt) andalso SubmittedAt >= 0
        andalso (Sig =:= none orelse
                 (is_binary(Sig) andalso byte_size(Sig) =:= 64))
        andalso quod_diff:valid_read_check(ReadCheck)
        andalso quod_diff:valid_ops(Diff).

valid_durable_proof(none, undefined, undefined) ->
    true;
valid_durable_proof(ProofId, GoalBlob, ResultBlob) when ProofId =/= none ->
    case {quod_durable_term:decode_goal(GoalBlob),
          quod_durable_term:decode_result(ResultBlob)} of
        {{ok, _Goal}, {ok, _Result}} -> true;
        _ -> false
    end;
valid_durable_proof(_ProofId, _Goal, _Result) ->
    false.

%% Expression-style rather than clause-style: the record type promises the
%% valid shape, but a decoded wire submission can carry anything, so this must
%% stay total without an (analysis-unreachable) catch-all clause.
valid_transaction_origin(Origin) ->
    is_tuple(Origin) andalso tuple_size(Origin) =:= 2
        andalso nonempty_binary(element(1, Origin))
        andalso is_binary(element(2, Origin))
        andalso byte_size(element(2, Origin)) =:= 32.

%% Every ordinary transaction is built from a sealed local plan
%% (`m:quod_dtx`), so it names the proof and the exact plan bytes it commits;
%% only genesis carries neither (its own validator pins both to `none`).
%% Shape-level: both present or both absent — history validation additionally
%% requires presence for every committed non-genesis entry.
valid_plan_binding(none, none) -> true;
valid_plan_binding(ProofId, PlanDigest) ->
    is_binary(ProofId) andalso byte_size(ProofId) =:= 32
        andalso is_binary(PlanDigest) andalso byte_size(PlanDigest) =:= 32.

-doc """
Validate the transaction rules of one historical entry under the committee
as-of that slot. This is deliberately independent of certificate validation:
rebuild and catch-up both enforce the current signed-transaction protocol.
Only the explicitly positioned slot-1 genesis transaction may be unsigned.
""".
-spec valid_history_entry({binary(), binary()}, pos_integer(), term(),
                          history_projection()) -> boolean().
valid_history_entry(Binding, Index, Data, Projection) ->
    valid_history_entry(Binding, Index, Data, 0, Projection).

-spec valid_history_entry({binary(), binary()}, pos_integer(), term(),
                          non_neg_integer(), history_projection()) -> boolean().
valid_history_entry(Binding, Index, Data, Timestamp, Projection) ->
    valid_history_entry(
      Binding, Index, Data, Timestamp, Projection, verify_id).

valid_history_entry({Ns, _Anchor}, 1,
                    {batch, [#transaction{origin = {Ns, <<0:256>>},
                                          sig = none} = Genesis]},
                    _Timestamp, #{committee := []}, _IdMode)
  when is_binary(Ns) ->
    valid_genesis_transaction(Ns, Genesis);
valid_history_entry(_Binding, I, noop, _Timestamp, _Projection, _IdMode)
  when is_integer(I), I > 1 ->
    true;
valid_history_entry({Ns, Anchor} = Target, I, Data,
                    Timestamp,
                    #{committee := Committee, admissions := Admissions},
                    IdMode)
  when is_binary(Ns), is_binary(Anchor), is_integer(I), I > 1,
       is_list(Committee) ->
    case quod_ledger:classify(Data) of
        {content, Payload} ->
            history_content_verdict(
              Target, I, Payload, Timestamp,
              Committee, Admissions, IdMode) =:= valid;
        %% Control history is valid only through the phase-index reducer.
        {controls, _Controls} -> false;
        noop -> false;
        invalid -> false
    end;
valid_history_entry(_Binding, _I, _Data, _Timestamp, _Committee, _IdMode) ->
    false.

history_content_verdict(
  Target, _I, Payload, Timestamp, Committee, Admissions, IdMode) ->
    BasicValid =
        bounded_transaction_list(Payload)
        andalso encoded_block_payload_fits({batch, Payload})
        andalso lists:all(
                  fun(Change) ->
                      historical_change_shape_acceptable(Change, Committee)
                          andalso history_id_valid(IdMode, Target, Change)
                  end,
                  Payload)
        andalso verify_transaction_signatures(
                  Target, Admissions, Payload, replay)
        andalso unique_tx_ids(Payload)
        andalso membership_batch_shape_ok(Payload),
    case BasicValid of
        false ->
            invalid;
        true ->
            history_request_verdict(Target, Timestamp, Payload)
    end.

history_request_verdict(Target, Timestamp, Payload) ->
    case content_network_identity(Target, Payload) of
        {ok, Network} ->
            case lists:all(
                   fun(Transaction) ->
                           case quod_transaction:validate_request(
                                  Network, Target, Timestamp, Transaction) of
                               {ok, _} -> true;
                               {error, _} -> false
                           end
                   end, Payload) of
                true -> valid;
                false -> invalid
            end;
        {error, Reason} ->
            {unavailable, network_identity, Reason}
    end.

content_network_identity(Target, Transactions) ->
    quod_ontology:network_identity(
      quod_transaction:requires_network_identity(Transactions), Target).

history_id_valid(verify_id, Target, Change) ->
    valid_target_transaction_id(Target, Change).

valid_genesis_transaction(Ns, Genesis) ->
    valid_genesis_transaction(Ns, Genesis, any_founding_set).

valid_genesis_transaction(
  Ns, #transaction{tx_id = TxId, origin = {Ns, <<0:256>>},
                   proof_id = none, plan_digest = none,
                   goal = undefined, result = undefined,
                   diff = Diff, read_check = ReadCheck, author = Author,
                   author_seq = 0, submitted_at = 0} = Genesis,
  ExpectedFounders)
  %% `#{}` in a head pattern matches ANY map; genesis must carry no read set.
  when map_size(ReadCheck) =:= 0 ->
    genesis_payload_bounded(Genesis)
        andalso well_formed_transaction(Genesis)
        %% Assertion-only + an asserted {can_invoke,4} head: `can_invoke/4`
        %% gates every entry including this host's own top-level proofs, so an
        %% ontology born without a policy could never be given one — it would
        %% deny the very proof that asserts it. Enforced here so founding
        %% (genesis_tx self-validates through this function), restart replay
        %% and catch-up all refuse a policy-less or non-assert genesis.
        andalso quod_diff:assertion_only(Diff)
        andalso quod_diff:asserts_functor(Diff, {can_invoke, 4})
        andalso valid_genesis_identity(
                  decode_genesis_tx_id(Ns, TxId), Diff, Author,
                  Genesis, ExpectedFounders);
valid_genesis_transaction(_Ns, _Genesis, _ExpectedFounders) ->
    false.

valid_genesis_identity(
  {ok, Incarnation}, Diff, Author, Genesis, ExpectedFounders) ->
    {Adds, Removes} = committee_delta(Genesis),
    genesis_incarnation_matches(Diff, Incarnation)
        andalso genesis_predicate_manifest(Genesis) =/= error
        andalso Removes =:= []
        andalso Adds =/= []
        andalso length(Adds) =< ?MAX_VALIDATORS
        andalso Author =:= lists:min(Adds)
        andalso founding_set_matches(ExpectedFounders, Adds);
valid_genesis_identity(
  error, _Diff, _Author, _Genesis, _ExpectedFounders) ->
    false.

founding_set_matches(any_founding_set, _Adds) ->
    true;
founding_set_matches(ExpectedFounders, Adds) ->
    lists:sort(Adds) =:= ExpectedFounders.

genesis_payload_bounded(Genesis) ->
    try encoded_block_payload_fits({batch, [Genesis]})
    catch
        _:_ -> false
    end.

historical_change_shape_acceptable(
  #transaction{author = Author, author_seq = Seq,
               proof_id = ProofId} = Change, Committee) ->
    lists:member(Author, Committee)
        andalso is_integer(Seq) andalso Seq > 0
        %% Committed non-genesis history must carry its plan provenance; the
        %% shape check then guarantees the digest rides with it.
        andalso ProofId =/= none
        andalso change_acceptable(Change, Committee);
historical_change_shape_acceptable(_Change, _Committee) ->
    false.

verify_transaction_signatures(Target, Admissions, [Transaction], Origin) ->
    verify_transaction_signature(Target, Admissions, Transaction, Origin);
verify_transaction_signatures(Target, Admissions, Transactions, Origin) ->
    %% Signature verification is CPU work. Let the VM's configured scheduler
    %% count own its parallelism instead of imposing another fixed throughput
    %% ceiling here; one worker handles each resulting chunk.
    WorkerCount = min(erlang:system_info(schedulers_online),
                      length(Transactions)),
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
                                     verify_transaction_signature(
                                       Target, Admissions,
                                       Transaction, Origin)
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

verify_transaction_signature({Ns, _Anchor} = Target, Admissions,
                             #transaction{author = Author} = Change, live) ->
    Started = erlang:monotonic_time(),
    Valid = verify_author_transaction(Target, Admissions, Author, Change),
    quod_metrics:observe_transaction_signature(
      Ns, Valid, erlang:monotonic_time() - Started),
    Valid;
verify_transaction_signature(Target, Admissions,
                             #transaction{author = Author} = Change, replay) ->
    verify_author_transaction(Target, Admissions, Author, Change).

verify_author_transaction({Ns, Anchor}, Admissions, Author, Change) ->
    case maps:get(Author, Admissions, undefined) of
        <<_:256>> = Admission ->
            quod_transaction:verify({Ns, Anchor, Admission}, Change);
        undefined ->
            false
    end.

valid_target_transaction_id(Target, #transaction{} = Change) ->
    quod_transaction:valid_id(Target, Change);
valid_target_transaction_id(_Target, _Change) -> false.

nonempty_binary(Value) -> is_binary(Value) andalso byte_size(Value) > 0.

%% Does a diff touch the committee (any `peer_admitted` assert/retract)? Hostile diffs can hold ANY
%% term as an element — the catch-all keeps the scan total.
touches_committee(Diff) ->
    lists:any(fun({K, {{peer_admitted, _, _, _, _}, _}})
                    when K =:= assert; K =:= retract -> true;
                 (_)                                      -> false
              end, Diff).

%% The membership gate — PURE (no KB access; the KB `can_join` re-proof is the deferred support in
%% `support_or_validate/2`): a
%% committee-changing transaction must be EXACTLY ONE well-formed `peer_admitted` op and must not
%% empty the committee or grow it beyond the shared validator cap.
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
membership_change_ok(#transaction{diff = Diff}, Vs) ->
    membership_diff_acceptable(Diff, Vs).

-doc "Whether one exact membership diff preserves the committee bounds.".
-spec membership_diff_acceptable(list(), [node_id()]) -> boolean().
membership_diff_acceptable(Diff, Validators) ->
    case quod_committee_predicates:membership_diff(Diff) of
        false -> false;
        true ->
            Next = apply_membership_diff(Diff, Validators),
            Next =/= [] andalso length(Next) =< ?MAX_VALIDATORS
    end.
        %% False for >1 op, mixed content, malformed heads, Id =/= Pk,
        %% non-binary keys, and a transition that would empty the committee.

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

%% DTX controls remain in `retained_dtx` until certified commit, so the wire
%% needs no second outbox. A live stream uses the link's message-driven ordered
%% FIFO; QUIC `send_ready` resumes local flow control. With no stream, link-up
%% is the exact wake that re-drives the retained rows. The consensus progress
%% timer remains only the final failed-dial safeguard.
send_dtx_relay(
  Peer, Wave,
  S = #s{chan = Chan, conns = Conns, dialing = Dialing}) ->
    case maps:get(Peer, Conns, undefined) of
        {LinkPid, _Ref} ->
            Pending = unplaced_dtx_wave({relay, Peer}, Wave, S),
            send_pending_dtx_relay(Peer, LinkPid, Pending, S);
        undefined ->
            case maps:is_key(Peer, Dialing) of
                true -> S;
                false ->
                    _ = quod_quic:open_link(Peer, Chan),
                    S#s{dialing = Dialing#{Peer => dial_deadline()}}
            end
    end.

send_pending_dtx_relay(_Peer, _LinkPid, [], S) ->
    S;
send_pending_dtx_relay(Peer, LinkPid, Pending, S) ->
    Envelopes = [Envelope
                 || {_Digest, #dtx_submission{envelope = Envelope}}
                        <- Pending],
    ValidationSidecar = dtx_wave_validation_sidecar(Pending),
    SentHints = fit_consensus_validation_sidecar(
                  S#s.ns,
                  fun(Hints) -> {dtx_submit, Envelopes, Hints} end,
                  ValidationSidecar),
    Frame = encode(S#s.ns, {dtx_submit, Envelopes, SentHints}),
    ok = quod_link:send_ordered(LinkPid, Frame),
    mark_dtx_relay_placed(Pending, Peer, LinkPid, S).

mark_dtx_relay_placed(Pending, Peer, LinkPid,
                      S = #s{retained_dtx = Registry0}) ->
    Registry1 =
        lists:foldl(
          fun({Digest, _Row}, Registry) ->
                  Current = maps:get(Digest, quod_dtx_owner:rows(Registry)),
                  quod_dtx_owner:replace(
                    Current#dtx_submission{
                      relay_placement = {Peer, LinkPid}},
                    Registry)
          end, Registry0, Pending),
    S#s{retained_dtx = Registry1}.

%% Relay submissions are already retained in `relay_pending`; duplicating them
%% into the generic bounded outbox would let unrelated consensus traffic evict
%% an early author sequence while keeping a later one. A disconnected link only
%% needs a dial. Link-up reconstructs the complete ordered prefix directly
%% from pending custody. A live reliable stream is never polled or re-sent on
%% a timer.
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
  #s{store = Store, slot = DurableHead})
  when TargetSlot =< DurableHead ->
    case catch quod_ledger_store:read_at(Store, TargetSlot) of
        {ok, Entry} ->
            #entry{data = Data} = quod_ledger:entry_view(Entry),
            case quod_ledger:classify(Data) of
                {content, Transactions} ->
                    case payload_has_submission(SubmissionId, Transactions) of
                        true ->
                            {final, {ok, TargetSlot}};
                        false ->
                            {final, {error, not_in_charge, none}}
                    end;
                {controls, _Controls} ->
                    {final, {error, not_in_charge, none}};
                noop ->
                    {final, {error, not_in_charge, none}};
                invalid ->
                    unknown
            end;
        _ ->
            unknown
    end;
durable_relay_result(_SubmissionId, _TargetSlot, _S) ->
    pending.

payload_has_submission(SubmissionId, Payload) ->
    lists:any(
      fun(#transaction{sig = Signature} = Transaction)
            when is_binary(Signature) ->
              signed_submission_id(Transaction) =:= SubmissionId;
         (_) ->
              false
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
  Submission = {submit, Author, _Signature, _Canonical}, TraceCarrier,
  S = #s{ns = Ns}) ->
    case decode_verified_submission(S, Author, Submission) of
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
    Relay1 = Relay#relay_pending{accepted = true},
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

%% Reconcile ownership and final deadlines without re-sending live work. A
%% disconnected stream is re-opened, and its exact link-up event reconstructs
%% the retained ordered prefix once.
reconcile_relays(S = #s{relay_pending = Pending, relay_results = Results}) ->
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
    prune_relay_links(S3).

ordered_relays(Pending) ->
    lists:sort(
      [{AuthorSeq, AttemptId, Relay}
       || {AttemptId,
           Relay = #relay_pending{author_seq = AuthorSeq}} <-
              maps:to_list(Pending)]).

custody_submission_id(
  #waiter{reply_to = {custody, SubmissionId}})
  when is_binary(SubmissionId) ->
    {ok, SubmissionId};
custody_submission_id(_) ->
    error.

encode(Ns, Msg) ->
    quod_relay:encode_consensus_frame(Ns, Msg).

%% Optional exact-entry acceleration yields to the transport-frame owner.
%% Applied certificates are mandatory live-validation evidence for Complete
%% and are never silently trimmed. Their protocol-bounded maximum is below the
%% shared transport frame; exceeding it is therefore an internal format error.
fit_consensus_validation_sidecar(Ns, MakeMessage, ValidationSidecar) ->
    Frame = encode(Ns, MakeMessage(ValidationSidecar)),
    case byte_size(Frame) =< ?QUOD_TRANSPORT_MAX_FRAME_BYTES of
        true -> ValidationSidecar;
        false when ValidationSidecar =/= [] ->
            case drop_optional_entry_hint(ValidationSidecar) of
                {ok, Reduced} ->
                    fit_consensus_validation_sidecar(
                      Ns, MakeMessage, Reduced);
                error ->
                    error(dtx_validation_evidence_exceeds_transport)
            end;
        false ->
            []
    end.

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

%% Post-commit hook for LIVE-entry consumers (the dissemination feed,
%% metrics, and Explorer): announce `{committed, Ns, Slot, Entry}` on the
%% shared `{committed, Ns}` property.  This full-entry shape is emitted only
%% from the live finality points, never from replay or catch-up, so history is
%% not re-broadcast and event consumers cannot re-fire old occurrences.
publish_feed(Slot, Entry, #s{ns = Ns}) ->
    #entry{} = quod_ledger:entry_view(Entry),
    _ = quod_reg:publish({committed, Ns}, {committed, Ns, Slot, Entry}),
    ok.

%% A verified catch-up window advances the same durable head without becoming
%% a live event stream.  Publish one height-only shape on the same property so
%% volatile followers wake immediately; consumers of full live entries ignore
%% it.  Never publish the caught-up entries themselves.
publish_certified_head(Slot, #s{ns = Ns}) ->
    _ = quod_reg:publish(
          {committed, Ns}, {certified_head, Ns, Slot}),
    ok.

%% Apply a freshly-committed block using the IN-HAND certified entry — no read-back of what we just wrote.
%% Only when quod_prolog is up AND we are contiguous (last_applied == Slot-1); otherwise leave it and
%% let the rebuild handshake re-drive the gap from the store (apply_committed/1).
apply_live(Entry, S) ->
    apply_live_view(Entry, quod_ledger:entry_view(Entry), S).

apply_live_view(Entry, #entry{index = Slot},
                S = #s{ns = Ns, last_applied = LA}) when LA =:= Slot - 1 ->
    case quod_reg:where({quod_prolog, Ns}) of
        undefined -> S;
        _         -> ok = quod_prolog:apply_entry(Ns, Entry, live),
                     S#s{last_applied = Slot}
    end;
apply_live_view(_Entry, _View, S) -> S.

%% Apply committed-but-unapplied blocks into quod_prolog, in slot order — STREAMED from the store
%% (this process keeps no in-memory log, and re-applying already-counted commits must not recount them).
%% Rebuild/member/feed-gap callers use replay; a settled observer's verified next-block feed fast path
%% uses live so its runtime receives the incremental event. Deferred if quod_prolog is not up; lookup is
%% done ONCE here, not per block. apply_entry is a cast by design (see quod_prolog:apply_entry/3 — a sync call
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
                                           fun(Entry, N) ->
                                               ok = quod_prolog:apply_entry(Ns, Entry, Origin),
                                               N rem ?APPLY_SYNC_EVERY =:= 0
                                                   andalso (ok = quod_prolog:sync(Ns)),
                                               N + 1
                                           end, 1),
                S#s{last_applied = C}
            catch exit:{noproc, _} -> S   %% quod_prolog died mid-replay; its rebuild re-drives
            end
    end.

%% Ordinary progress retains the initial-readiness handshake. In particular,
%% a settled observer stays sync=ready across all feed windows and ticks;
%% those turns must not close an already-ready Prolog's replay per window.
%% The member sync_done and finish_feed_replay completion seams explicitly
%% request interval closure independently of the old acknowledgement.
maybe_mark_ready(S = #s{prolog_ready = true}, ordinary) -> S;
maybe_mark_ready(S, _Boundary) -> maybe_mark_ready(S).

%% Request readiness/interval closure only after dispatching the committed
%% prefix and reaching the path's completion boundary. Prolog owns the actual
%% ID/floor and refuses dependency/projection failures. An already-ready ack
%% is inert; initial proof readiness still needs the exact current pid/height.
maybe_mark_ready(S = #s{ns = Ns, sync = ready}) ->
    Prolog = try quod_reg:where({quod_prolog, Ns}) catch _:_ -> undefined end,
    case (Prolog =/= undefined) andalso (S#s.last_applied >= S#s.slot) of
        true  -> _ = try quod_prolog:mark_ready(Ns) catch _:_ -> ok end,
                 S;
        false -> S
    end;
maybe_mark_ready(S) -> S.   %% recovery has not reached `ready` yet

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

%% `ready` is the only recovery state with a corroborated tip. An ahead
%% finalizer revokes voting immediately, even while its pending verdict is owned.
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

%% Prefer the installed next-parent request: worker exit can leave a queued verdict.
%% Verdict or DOWN releases ownership. The original allowance bounds only this
%% preference; existing ticks handle expiry without granting voting readiness.
should_sync(#s{sync = unconfirmed}) -> true;
should_sync(#s{sync = ready, approved = Approved, history_head = Token, eng = Eng} = S) ->
    case ahead_cert_ceiling(Eng) of
        Ahead when Ahead =< Approved -> false;
        Next when Next =:= Approved + 1 ->
            Round = round_state(Next, S),
            case {Round#round.candidate, Round#round.validating, dtx_validation_owner(Round)} of
                {{Hash, #block{slot = Next}}, Hash, {Token = {Approved, _}, _Owner, DeadlineMs}} ->
                    not (quod_time:mono_ms() < DeadlineMs andalso
                         persisted_cert(support, Next, Hash, Eng) =/= none andalso
                         persisted_cert(commit, Next, Hash, Eng) =/= none);
                _ -> true
            end;
        _ -> true
    end.

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
            _ = quod_process:kill_when_owner_dies(Statem, self()),
            Owner = self(),
            Sink = fun(Es, Projection1, Delta) ->
                       gen_statem:call(
                         Statem,
                         {sink_catchup, {recovery, Owner}, Es, Projection1, Delta},
                         ?SINK_MS)
                   end,
            Result = run_recovery(
                       Ns, GH, Statem, Self, Sink),
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
    recover_tip(Ns, GH, Statem, Self, Sink,
                ?RECOVERY_FETCHES, false,
                ?RECOVERY_HINT_WARMS).

recover_tip(Ns, GH, Statem, Self, Sink,
            FetchesLeft, FallbackUsed, HintWarms) ->
    case recovery_snapshot(Statem, Ns, GH) of
        {ok, #{slot := Height, projection := Projection}} when Height > 0 ->
            Committee = history_committee(Projection),
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
                            %% bounded set with tiny identified pulls; each TLS-bound link teaches the
                            %% resolver, then the NEXT pass remains the normal identity-bound quorum probe.
                            warm_contact_hints(Ns, Height),
                            recover_tip(Ns, GH, Statem, Self, Sink,
                                        FetchesLeft,
                                        FallbackUsed, HintWarms - 1);
                        false ->
                            Failure = {tip_unconfirmed, Height, length(lists:usort(Exact))},
                            continue_recovery(Ns, GH, Statem, Self, Sink,
                                              FetchesLeft,
                                              FallbackUsed, ahead_contacts(Probes), Exact, Failure)
                    end
            end;
        {ok, #{slot := 0}} ->
            continue_recovery(Ns, GH, Statem, Self, Sink,
                              FetchesLeft,
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
%% replies are intentionally discarded: only catch_up_from/5 is allowed to put data into the ledger.
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
            case try_recovery_sources(
                   Ns, GH, Statem, Sources, Sink) of
                {ok, _} ->
                    recover_tip(Ns, GH, Statem, Self, Sink,
                                FetchesLeft - 1, FallbackUsed1,
                                ?RECOVERY_HINT_WARMS);
                {error, _} -> {error, Failure}
            end
    end.

%% Only fall back to a Brahms/seed endpoint when no current member supplied even
%% one exact or ahead response. The identified open binds its TLS key before the
%% pull, and verified history advances state; the next committee-key probe still
%% decides readiness.
recovery_sources(_Ns, Ahead, _Exact, FallbackUsed) when Ahead =/= [] ->
    {Ahead, FallbackUsed};
recovery_sources(Ns, [], [], false) ->
    case quod_catchup:contact(Ns) of
        none    -> {[], true};
        Contact -> {[Contact], true}
    end;
recovery_sources(_Ns, [], _Exact, FallbackUsed) -> {[], FallbackUsed}.

try_recovery_sources(_Ns, _GH, _Statem, [], _Sink) ->
    {error, no_source};
try_recovery_sources(Ns, GH, Statem, [Contact | Rest], Sink) ->
    case recovery_snapshot(Statem, Ns, GH) of
        {ok, View} ->
            case catch_up_from(
                   Ns, GH, View, Contact, Sink) of
                {ok, _} = Ok -> Ok;
                {error, _}   -> try_recovery_sources(
                                  Ns, GH, Statem, Rest, Sink)
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

recovery_snapshot(Statem, Ns, GH) ->
    %% Preserve this recovery capture's existing five-second budget. Capture
    %% bytes and projection together, from the exact worker-owning incarnation.
    history_view({Statem, {Ns, GH}}, committed, quod_time:mono_ms() + 5000).

%% Self's durable head plus distinct, current committee peers at exactly that height must form a quorum.
%% Lower reports are stale; higher reports are consumed by catch-up and require another round if they were
%% observed too late for enough earlier contacts to corroborate the new final height.
tip_quorum([], _Self, _Peers) -> false;
tip_quorum(Committee, Self, Peers) ->
    Local = case lists:member(Self, Committee) of true -> [Self]; false -> [] end,
    Confirmed = lists:usort(Local ++ [P || P <- Peers, lists:member(P, Committee)]),
    length(Confirmed) >= quorum(length(Committee)).

catch_up_from(Ns, GH, View = #{slot := Height, projection := Projection},
              Contact, Sink) ->
    Fetch = fun(F) -> quod_catchup:pull(Ns, F, F + ?SYNC_WINDOW - 1, Contact) end,
    quod_catchup:catch_up(
      Ns, GH, Fetch, Sink, Height + 1, Projection,
      #{history_view => View}).

%% The single recovery armer runs at the owner reconciliation boundary. A
%% verified finalizer already proves a gap; no timer needs to confirm it again.
%% Failed acquisition retains its existing backoff; the enum owns single flight.
maybe_arm_sync(S = #s{sync = {pulling, _}}) -> S;
maybe_arm_sync(S = #s{sync = Sy}) when Sy =:= unconfirmed; Sy =:= ready ->
    case should_sync(S) of
        false -> S#s{sync_arm = reset_pace()};   %% at the tip: clear pacing so a later gap starts fresh
        true  -> case arm_ready(S) andalso sibling_up(S) of
                     true  -> start_sync_worker(S);
                     false -> S
                 end
    end.

%% Only the existing tick spends failure backoff; peer traffic cannot do so.
pace_tick(S = #s{sync_arm = {Cool, Int}}) ->
    S#s{sync_arm = {max(0, Cool - 1), Int}}.

arm_ready(#s{sync_arm = {Cool, _Int}}) -> Cool =:= 0.

recovery_failed(S) ->
    S#s{sync = unconfirmed, sync_arm = backoff(S#s.sync_arm)}.

%% Grow the failure backoff: double the interval (floored at ?SYNC_BACKOFF_MIN, capped at ?SYNC_BACKOFF_MAX
%% ticks) and set the cooldown to a ±20%-jittered copy after a failed attempt.
backoff({_Cool, Int}) ->
    Int1 = min(?SYNC_BACKOFF_MAX, max(?SYNC_BACKOFF_MIN, Int * 2)),
    {jitter_ticks(Int1), Int1}.

reset_pace() -> {0, 0}.

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
apply_catchup_window(_Source, [], _Projection, _Delta, S) -> {S, ok};
apply_catchup_window(
  Source, Es, Projection, Delta,
  S = #s{store = Store}) ->
    %% The verifier's projection is bound to its exact starting snapshot. If
    %% live consensus advanced while it fetched, reject the whole stale window
    %% instead of detaching that projection by trimming an already-durable
    %% prefix. Recovery resumes from a fresh snapshot.
    Next = quod_ledger_store:last(Store) + 1,
    #entry{index = First} = quod_ledger:entry_view(hd(Es)),
    case First =:= Next of
        false ->
            {S, {error, stale_window}};
        true ->
    case try quod_ledger_store:append(Store, Es) catch _:R -> {error, R} end of
        {error, _} = Err -> {S, Err};
        {ok, Store1} ->
            %% Install before routes, owner reconciliation, Prolog application,
            %% or any published head. Failure after append must unwind; an old
            %% index is not a state to which the owner can return.
            Projection1 = retain_owner_projection(Projection, Delta, S),
            Included = committed_submission_slots(Es),
            learn_validator_routes(Projection1, S#s.self),
            #entry{index = Slot} = quod_ledger:entry_view(lists:last(Es)),
            %% Re-seat the engine UNCONDITIONALLY at the new head (committee-as-of-new-head + reset every stale
            %% live-slot latch). For a VOTING member gap-filling this is load-bearing (its engine was pinned to
            %% the stale head); for a joiner/observer the resets are no-ops. The following
            %% `catchup_membership_transition` emits the S5b false->true notice. The caller
            %% (`sink_catchup`) passes the result through `keep_progress/3`, so the discarded head state
            %% cancels its named watchdog before voting resumes.
            Recovered0 =
                install_projection(
                  Projection1, S#s{store = Store1, slot = Slot}),
            Recovered1 = settle_recovery_dtx(Es, Recovered0),
            Recovered2 =
                settle_recovery_custody(Slot, Included, Recovered1),
            %% Live commit and catch-up retire effect signing custody through
            %% the same semantic-TxId path.  Otherwise a later restart can
            %% restore and re-drive an effect transaction already present in
            %% this certified window.
            Recovered3 = retire_committed_transaction_custody(
                           entry_effect_transaction_ids(Es), Recovered2),
            Recovered =
                settle_recovery_relays(Slot, Included, Recovered3),
            {Reconciled, PendingTransition} =
                reconcile_signing_state(Recovered),
            S1 = reseat_engine(Slot, Reconciled, Included),
            S2 = catchup_membership_transition(S, S1),
            S3 = apply_committed(S2, catchup_origin(Source)),
            S4 = finish_pending_votes_reconciliation(
                   PendingTransition, S3),
            publish_certified_head(Slot, S4),
            {S4, ok}
    end
    end.

catchup_origin({feed, live}) -> live;
catchup_origin(_)            -> replay.

committed_submission_slots(Entries) ->
    lists:foldl(
      fun(Entry, Acc0) ->
              #entry{index = Slot, data = Data} = quod_ledger:entry_view(Entry),
              case quod_ledger:classify(Data) of
                  {content, Transactions} ->
                      lists:foldl(
                        fun(#transaction{sig = Signature} = Transaction, Acc)
                              when is_binary(Signature) ->
                                Acc#{signed_submission_id(Transaction) => Slot};
                           (_, Acc) ->
                                Acc
                        end, Acc0, Transactions);
                  {controls, _Controls} -> Acc0;
                  noop -> Acc0;
                  invalid -> Acc0
              end
      end, #{}, Entries).

entry_effect_transaction_ids(Entries) ->
    lists:foldl(
      fun(Entry, Acc) ->
              #entry{data = Data} = quod_ledger:entry_view(Entry),
              maps:merge(Acc, payload_transaction_ids(Data))
      end, #{}, Entries).

settle_recovery_dtx(Entries, S) ->
    lists:foldl(
      fun(Entry, Acc) ->
              #entry{data = Payload} = quod_ledger:entry_view(Entry),
              resolve_committed_dtx(Entry, Payload, Acc)
      end, S, Entries).

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
                              Acc;
                          dormant ->
                              Acc;
                          {cancelling, _Pid, _Monitor} ->
                              Acc
                      end
              end
      end, S, S#s.custody).

%% The verified post-window projection already owns the bounded current
%% committee routes.  Fill resolver voids from that authority after every
%% nonempty replay, including a content-only gap after transport restart;
%% historical hints never clobber a fresher authenticated header sighting.
learn_validator_routes(Projection, Self) ->
    maps:foreach(
      fun(Peer, Endpoint) when Peer =/= Self ->
              quod_quic:learn_if_absent(Peer, Endpoint);
         (_Self, _Endpoint) ->
              ok
      end,
      history_validator_routes(Projection)).

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
    maps:foreach(fun(_, Round) -> release_validation_monitor(Round) end, S1#s.rounds),
    restore_signing_engine(
      S1#s{eng             = eng_new(S1#s.consensus_domain,
                                      active_validators(S1), NewHead),
            approved        = NewHead,
            commit_buf      = #{},
            block_requests  = #{},
            requested_slot  = none,
            head_progress   = idle,
            rounds          = signing_rounds(S1#s.signing_journal)}).

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

%% The target identity every ordinary transaction signature binds. The
%% admission id changes only when this exact author leaves and later rejoins;
%% unrelated membership changes therefore preserve retained custody.
target_identity(#s{ns = Ns, genesis_hash = <<_:256>> = Anchor}) ->
    {Ns, Anchor}.

binding(#s{author_admissions = Admissions} = S, Author) ->
    {Ns, Anchor} = target_identity(S),
    case maps:get(Author, Admissions, undefined) of
        <<_:256>> = Admission -> {ok, {Ns, Anchor, Admission}};
        undefined -> error
    end.

transaction_submission(S, #transaction{author = Author} = Change) ->
    case binding(S, Author) of
        {ok, TargetBinding} ->
            quod_transaction:submission(TargetBinding, Change);
        error ->
            {error, unknown_author}
    end.

decode_verified_submission(S, Author, Submission) ->
    case binding(S, Author) of
        {ok, TargetBinding} ->
            quod_transaction:decode_verified_submission(
              TargetBinding, Submission);
        error ->
            {error, unknown_author}
    end.

local_genesis_hash(#s{store = Store}) ->
    case quod_ledger_store:read_at(Store, 1) of
        {ok, E} -> case block_from_entry(E) of
                                  {ok, Block} -> block_hash(Block);
                                  error       -> undefined
                              end;
        _                  -> undefined
    end.

%%%===================================================================
%%% helpers
%%%===================================================================

%% Read the already-bound block view retained by the entry. `#block{}` is only
%% the engine's in-memory view; the bytes remain the consensus identity.
-spec block_from_entry(term()) -> {ok, #block{}} | error.
block_from_entry(Entry) -> quod_ledger:block_from_entry(Entry).

%% ONE bounded projection owns every history-derived ordering fact. It is
%% threaded unchanged through live commit, restart replay, feed and catch-up;
%% there is no second committee/sequence interpretation to drift. Admissions
%% contain only current validators and sequences are pruned to the same set.
-type history_projection() ::
        #{committee := [node_id()],
          validator_routes := #{node_id() => {term(), pos_integer()}},
          committee_id := binary() | undefined,
          committee_views := [{slot(), [node_id()], binary(),
                               #{node_id() => {term(), pos_integer()}}}],
          admissions := #{node_id() => binary()},
          sequences := #{node_id() => non_neg_integer()},
          timestamp := non_neg_integer(),
          dtx := undefined | quod_atomic:projection(),
          dtx_lanes := #{{binary(), node_id()} => non_neg_integer()},
          history_head := none | {slot(), <<_:256>>},
          %% Ephemeral owner capture only; never persisted as projection data.
          history_index => quod_dtx_phase_index:index()}.

-doc "Return the empty authoritative history projection used before genesis.".
-spec history_projection() -> history_projection().
history_projection() ->
    history_projection([], undefined, #{}, #{}, 0).

-doc "Bind an empty history projection to one exact ontology founding.".
-spec history_projection({binary(), <<_:256>>}) -> history_projection().
history_projection({Ns, <<_:256>>} = Target) when is_binary(Ns) ->
    (history_projection())#{dtx := quod_atomic:initial_projection(Target, 0)}.

-doc "Build an explicit authoritative history projection from persisted ordering facts.".
-spec history_projection([node_id()], binary() | undefined,
                         #{node_id() => binary()},
                         #{node_id() => non_neg_integer()},
                         non_neg_integer()) -> history_projection().
history_projection(Committee, CommitteeId, Admissions, Sequences, Timestamp) ->
    #{committee => Committee, validator_routes => #{},
      committee_id => CommitteeId,
      committee_views => [],
      admissions => Admissions, sequences => Sequences,
      timestamp => Timestamp, dtx => undefined, dtx_lanes => #{},
      history_head => none}.

state_projection(
  #s{validators = Committee, validator_routes = ValidatorRoutes,
     committee_id = CommitteeId,
     committee_start = CommitteeStart,
     author_admissions = Admissions, author_seqs = Sequences,
     last_ts = Timestamp, dtx_projection = Dtx, dtx_lanes = DtxLanes,
     history_head = HistoryHead}) ->
    Projection = (history_projection(
       Committee, CommitteeId, Admissions, Sequences, Timestamp))#{
      validator_routes := ValidatorRoutes,
      dtx := Dtx, dtx_lanes := DtxLanes,
      history_head := HistoryHead},
    seed_current_committee_view(Projection, CommitteeStart).

install_projection(
  #{committee := Committee, validator_routes := ValidatorRoutes,
    committee_id := CommitteeId,
    committee_views := CommitteeViews,
    admissions := Admissions, sequences := Sequences,
    timestamp := Timestamp, dtx := Dtx, dtx_lanes := DtxLanes,
    history_head := HistoryHead},
  S = #s{self = Self, author_admissions = OldAdmissions,
         next_author_seq = Next}) ->
    %% A worker captures ledger state, not ownership of local apply progress.
    %% The previous history token remains pinned even when `slot` was already
    %% advanced by the appender. Initial replay has no live acknowledgements.
    InstalledDtx = case S#s.history_head of
        none -> Dtx;
        {Height, _} -> quod_atomic:install_projection(Dtx, S#s.dtx_projection, Height)
    end,
    OldAdmission = maps:get(Self, OldAdmissions, undefined),
    NewAdmission = maps:get(Self, Admissions, undefined),
    Floor = maps:get(Self, Sequences, 0) + 1,
    Next1 =
        case NewAdmission =/= OldAdmission of
            true  -> Floor;
            false -> max(Next, Floor)
        end,
    S1 = S#s{validators = Committee, validator_routes = ValidatorRoutes,
             committee_id = CommitteeId,
             committee_start = current_committee_start(
                                 CommitteeId, CommitteeViews),
             author_admissions = Admissions, author_seqs = Sequences,
             last_ts = Timestamp, dtx_projection = InstalledDtx,
             dtx_lanes = DtxLanes,
             history_head = HistoryHead,
             next_author_seq = Next1},
    S2 = retire_changed_admissions(OldAdmissions, Admissions, S1),
    refresh_proof_gate(S, S2).

%% Custody retains exact signed bytes. Once an author's admission generation
%% changes those bytes can never enter consensus again. Ordinary custody is
%% retired through the one release path. A remote operation claim is different:
%% its target may already have durably prepared private state, so the retained
%% Submission moves under the existing sole cancellation owner and remains
%% signed-journal-backed until that target proves `cancelled` or `not_found`.
retire_changed_admissions(OldAdmissions, Admissions,
                          S = #s{custody = Custody}) ->
    Changed = maps:fold(
                fun(Author, OldAdmission, Acc) ->
                    case maps:get(Author, Admissions, undefined) of
                        OldAdmission -> Acc;
                        _NewAdmission -> Acc#{Author => true}
                    end
                end, #{}, OldAdmissions),
    case map_size(Changed) of
        0 -> S;
        _ ->
            S1 = case maps:is_key(S#s.self, Changed) of
                true -> retire_dtx_admission(S);
                false -> S
            end,
            Retired =
                [SubmissionId
                 || {SubmissionId,
                     #custody{change = #transaction{author = Author}}}
                        <- maps:to_list(Custody),
                    maps:is_key(Author, Changed)],
            lists:foldl(
              fun(SubmissionId, Acc) ->
                  case maps:get(SubmissionId, Acc#s.custody, undefined) of
                      Record = #custody{} ->
                          case operation_custody_record(Record) of
                              true ->
                                  ensure_operation_custody_cancellation(
                                    (Record#custody.change)#transaction.tx_id,
                                    Acc);
                              false ->
                                  complete_custody(
                                    SubmissionId,
                                    {error, not_in_charge, unavailable}, Acc)
                          end;
                      undefined ->
                          Acc
                  end
              end, S1, Retired)
    end.

-doc "Read the canonical validator set from a history projection.".
-spec history_committee(history_projection()) -> [node_id()].
history_committee(#{committee := Committee}) -> Committee.

-doc "Return the certified post-slot committee view for one exact history slot.".
-spec history_committee_view(slot(), history_projection()) ->
          {ok, [node_id()], binary(),
           #{node_id() => {term(), pos_integer()}}} | error.
history_committee_view(
  Slot, #{history_head := {Height, _Hash}, committee_views := Views} = Projection)
  when is_integer(Slot), Slot > 0, Slot =< Height, is_list(Views) ->
    case committee_view_at(Slot, Views) of
        {ok, _, _, _} = Found -> Found;
        error ->
            case maps:find(history_index, Projection) of
                {ok, Index} ->
                    case quod_dtx_phase_index:committee(Index, Slot) of
                        {ok, {_Start, Committee, Id, Routes}} -> {ok, Committee, Id, Routes};
                        not_found -> error;
                        {error, Reason} -> erlang:error({history_index_unavailable, Reason})
                    end;
                error -> error
            end
    end;
history_committee_view(_Slot, _Projection) ->
    error.

-doc "Return the committee and routes which certified one exact history slot.".
-spec history_certifying_committee_view(slot(), history_projection()) ->
          {ok, [node_id()], binary(),
           #{node_id() => {term(), pos_integer()}}} | error.
history_certifying_committee_view(1, Projection) ->
    %% Genesis has no quorum certificate. Its post-slot founding view is the
    %% only committee era and keeps exact genesis evidence self-contained.
    history_committee_view(1, Projection);
history_certifying_committee_view(Slot, Projection)
  when is_integer(Slot), Slot > 1 ->
    %% A membership transaction changes authority only after this block is
    %% certified. The block's certificate therefore belongs to the post-parent
    %% era, while history_committee_view/2 deliberately remains post-slot.
    history_committee_view(Slot - 1, Projection);
history_certifying_committee_view(_Slot, _Projection) ->
    error.

committee_view_at(Slot, [{Start, Committee, CommitteeId, Routes} | _Rest])
  when Start =< Slot ->
    {ok, Committee, CommitteeId, Routes};
committee_view_at(Slot, [_Later | Rest]) ->
    committee_view_at(Slot, Rest);
committee_view_at(_Slot, []) ->
    error.

-doc "Read the bounded validator key-to-endpoint map from a history projection.".
-spec history_validator_routes(history_projection()) ->
          #{node_id() => {term(), pos_integer()}}.
history_validator_routes(#{validator_routes := Routes}) -> Routes.

-ifdef(TEST).
-doc "Resolve one current validator's admission-bound transaction signature target.".
-spec history_binding({binary(), binary()}, node_id(), history_projection()) ->
        {ok, quod_transaction:target_binding()} | error.
history_binding({Ns, Anchor}, Author, #{admissions := Admissions}) ->
    case maps:get(Author, Admissions, undefined) of
        <<_:256>> = Admission -> {ok, {Ns, Anchor, Admission}};
        undefined -> error
    end.
-endif.

-ifdef(TEST).
-spec log_projection(binary(), [quod_ledger:entry_artifact()], history_projection()) ->
        history_projection().
log_projection(Ns, Entries, Seed) ->
    lists:foldl(fun(Entry, Acc) -> history_advance(Ns, Entry, Acc) end,
                Seed, Entries).
-endif.

-doc "Advance the content/noop projection by one already-verified committed entry.".
%% Content-only blocks touch no
%% admission map and perform only the bounded sequence fold; membership blocks
%% additionally retain the intersection, mint IDs for newly admitted keys and
%% prune sequence floors for departed keys.
-spec history_advance(binary(), quod_ledger:entry_artifact(), history_projection()) ->
        history_projection().
history_advance(
  Ns, Entry, Projection) ->
    history_advance_known(Ns, Entry, entry_history_hash(Entry), Projection).

history_advance_known(
  Ns, Entry, HeadHash, Projection) ->
    #entry{index = Slot} = quod_ledger:entry_view(Entry),
    Projection1 = history_advance_payload(Ns, Entry, Projection),
    Projection1#{history_head => {Slot, HeadHash}}.

history_advance_payload(
  Ns, Entry, Projection) ->
    #entry{data = Data, timestamp = T} = quod_ledger:entry_view(Entry),
    case quod_ledger:classify(Data) of
        {content, _Transactions} ->
            history_advance_content(Ns, Entry, Projection);
        %% Control history must pass through the phase-aware /4 or /5 APIs;
        %% this content-only seam fails loudly if a caller bypasses them.
        {controls, _Controls} -> error(dtx_phase_history_required);
        noop ->
            Projection#{timestamp => max(T, maps:get(timestamp, Projection))};
        invalid ->
            error(invalid_committed_history)
    end.

-doc "Return the canonical identity of an installed parent, including certified skips.".
entry_history_hash(Entry) ->
    entry_history_hash_view(Entry, quod_ledger:entry_view(Entry)).

entry_history_hash_view(_Entry, #entry{index = Slot, data = noop, block_bytes = none}) ->
    %% A complaint skip's identity is the statement every validator signed,
    %% not the incidental quorum subset a replica first retained.  The target
    %% ontology identity accompanies every use of history_head, just as it
    %% accompanies an ordinary block hash; within that chain the slot uniquely
    %% identifies this certified no-op transition.
    crypto:hash(
      sha256,
      <<?SKIPPED_SLOT_TAG/binary, 0, ?SKIPPED_SLOT_VERSION:8,
        Slot:64/unsigned-big>>);
entry_history_hash_view(Entry, #entry{}) ->
    case block_from_entry(Entry) of
        {ok, Block} -> block_hash(Block);
        error -> error(uncanonical_entry)
    end.

-doc "Validate and reduce one certified committed entry with exact DTX history.".
-spec history_advance({binary(), <<_:256>>}, quod_ledger:entry_artifact(), history_projection(),
                      quod_dtx_phase_index:index()) ->
          {ok, history_projection(), list()} |
          {error, {invalid_transaction, pos_integer()} |
                  {unavailable, network_identity, term()}}.
history_advance(Binding, Entry, Projection, PhaseIndex) ->
    history_validate_advance(Binding, Entry, Projection, PhaseIndex).

history_advance_content(
  Ns, Entry,
  #{committee := V,
    validator_routes := Routes,
    admissions := Admissions, sequences := Seqs,
    timestamp := Ts} = Projection) ->
    #entry{index = Slot, data = Data, timestamp = T} = quod_ledger:entry_view(Entry),
    Seqs0 = advance_author_seqs(Data, Seqs),
    Routes0 = advance_validator_routes(Data, Routes),
    case committee_delta(Data) of
        {[], []} ->
            record_committee_view(
              Slot, V, maps:get(committee_id, Projection),
              maps:with(V, Routes0),
              Projection#{validator_routes => maps:with(V, Routes0),
                          sequences => Seqs0, timestamp => max(T, Ts)});
        {Adds, _Removes} ->
            V1 = apply_committee_delta(Data, V),
            case V1 =:= V of
                true ->
                    %% Reasserting an existing member may refresh its endpoint
                    %% in Prolog, but it is not a leave/rejoin and must not
                    %% rotate admission identity or sequence state.
                    record_committee_view(
                      Slot, V, maps:get(committee_id, Projection),
                      maps:with(V, Routes0),
                      Projection#{validator_routes => maps:with(V, Routes0),
                                  sequences => Seqs0,
                                  timestamp => max(T, Ts)});
                false ->
                    {ok, Block} = block_from_entry(Entry),
                    BlockHash = block_hash(Block),
                    CommitteeId1 = committee_view_id(
                                     Ns, Slot, BlockHash, V1),
                    NewlyAdmitted =
                        [Pubkey || Pubkey <- Adds,
                                   not maps:is_key(Pubkey, Admissions),
                                   lists:member(Pubkey, V1)],
                    Admissions1 =
                        lists:foldl(
                          fun(Pubkey, Acc) ->
                                  Acc#{Pubkey => admission_id(
                                                   Ns, Slot, BlockHash,
                                                   Pubkey)}
                          end,
                          maps:with(V1, Admissions), NewlyAdmitted),
                    DtxLanes1 = prune_dtx_lanes(
                                  Admissions1,
                                  maps:get(dtx_lanes, Projection, #{})),
                    Routes1 = maps:with(V1, Routes0),
                    record_committee_view(
                      Slot, V1, CommitteeId1, Routes1,
                      Projection#{committee => V1,
                                  validator_routes => Routes1,
                                  committee_id => CommitteeId1,
                                  admissions => Admissions1,
                                  sequences => maps:without(
                                                 NewlyAdmitted,
                                                 maps:with(V1, Seqs0)),
                                  dtx_lanes => DtxLanes1,
                                  timestamp => max(T, Ts)})
            end
    end.

seed_current_committee_view(
  Projection = #{history_head := {_Height, _Hash},
                 committee := [_ | _] = Committee,
                 committee_id := <<_:256>> = CommitteeId,
                 validator_routes := Routes}, Slot)
  when is_integer(Slot), Slot > 0 ->
    record_committee_view(
      Slot, Committee, CommitteeId, Routes, Projection);
seed_current_committee_view(Projection, undefined) ->
    Projection.

current_committee_start(undefined, []) ->
    undefined;
current_committee_start(<<_:256>>, []) ->
    %% A projection without an era row cannot authorize the resident-history
    %% fast path. This occurs only in deliberately partial test/recovery
    %% fixtures; production replay creates the row from certified genesis.
    undefined;
current_committee_start(
  <<_:256>> = CommitteeId,
  [{Start, _Committee, CommitteeId, _Routes} | _])
  when is_integer(Start), Start > 0 ->
    Start;
current_committee_start(CommitteeId, CommitteeViews) ->
    error({invalid_current_committee_view, CommitteeId, CommitteeViews}).

%% Views are ordered newest first. A row starts only when the committee or its
%% routes change; preserving the previous row keeps as-of captures stable. Routes are
%% reachability hints, while the committee and id are the authority fixed by
%% the certified history fold.
record_committee_view(
  _Slot, _Committee, undefined, _Routes, Projection) ->
    %% A committee era begins only once genesis (or another membership entry)
    %% has established its signed view id.  A content-only pre-genesis fold is
    %% invalid as history, but keeping this pure projector neutral lets its
    %% caller return the existing typed history error instead of manufacturing
    %% a corrupt resident row containing `undefined`.
    Projection;
record_committee_view(
  Slot, Committee, CommitteeId, Routes,
  Projection = #{committee_views := Views}) when is_binary(CommitteeId),
                                                  byte_size(CommitteeId) =:= 32 ->
    View = {Slot, Committee, CommitteeId, Routes},
    case Views of
        [{Start, Committee, CommitteeId, Routes} | Rest] ->
            Projection#{committee_views :=
                            [{Start, Committee, CommitteeId, Routes} | Rest]};
        _ ->
            Projection#{committee_views := [View | Views]}
    end.

prune_dtx_lanes(Admissions, DtxLanes) ->
    Live = [{Admission, Author}
            || {Author, Admission} <- maps:to_list(Admissions),
               is_binary(Author), byte_size(Author) =:= 32,
               is_binary(Admission), byte_size(Admission) =:= 32],
    maps:with(Live, DtxLanes).

admission_id(Ns, Slot, BlockHash, Pubkey) ->
    crypto:hash(
      sha256,
      term_to_binary(
        {quod_validator_admission, 1, Ns, Slot, BlockHash, Pubkey},
        [deterministic])).

checked_log_projection_step(
  Binding, Entry, Projection) ->
    #entry{index = I} = quod_ledger:entry_view(Entry),
    case history_validate_advance(Binding, Entry, Projection) of
        {ok, Projection1} -> Projection1;
        {error, {unavailable, network_identity, Reason}} ->
            error({history_dependency_unavailable, network_identity, Reason});
        {error, _} -> error({invalid_transaction_history, I})
    end.

checked_log_projection_step(
  Binding, Entry, Projection, PhaseIndex) ->
    #entry{index = I} = quod_ledger:entry_view(Entry),
    case history_validate_advance(Binding, Entry, Projection, PhaseIndex) of
        {ok, Projection1, _Effects} -> Projection1;
        {error, {unavailable, network_identity, Reason}} ->
            error({history_dependency_unavailable, network_identity, Reason});
        {error, _} -> error({invalid_transaction_history, I})
    end.

-doc "Validate one historical entry and advance the projection atomically on success.".
-spec history_validate_advance({binary(), binary()}, quod_ledger:entry_artifact(),
                               history_projection()) ->
        {ok, history_projection()} |
        {error, {invalid_transaction, pos_integer()} |
                {unavailable, network_identity, term()}}.
history_validate_advance(
  Binding, Entry, Projection) ->
    #entry{index = I} = quod_ledger:entry_view(Entry),
    case history_projection_before_entry(I, Projection) of
        {ok, Projection1} ->
            history_validate_content(Binding, Entry, Projection1);
        error ->
            {error, {invalid_transaction, I}}
    end.

history_validate_content(
  {Ns, _Anchor} = Binding,
  Entry,
  #{sequences := Seqs} = Projection) ->
    #entry{index = I, data = Data, timestamp = Timestamp} = quod_ledger:entry_view(Entry),
    case history_entry_verdict(
           Binding, I, Data, Timestamp, Projection, verify_id) of
        valid ->
            case historical_sequences_ok(I, Data, Seqs) of
                true -> {ok, history_advance(Ns, Entry, Projection)};
                false -> {error, {invalid_transaction, I}}
            end;
        {unavailable, network_identity, _Reason} = Unavailable ->
            {error, Unavailable};
        invalid ->
            {error, {invalid_transaction, I}}
    end.

history_entry_verdict(
  Target = {Ns, Anchor}, I, Data, Timestamp,
  #{committee := Committee, admissions := Admissions}, IdMode)
  when is_binary(Ns), is_binary(Anchor), is_integer(I), I > 1,
       is_list(Committee) ->
    case quod_ledger:classify(Data) of
        {content, Payload} ->
            history_content_verdict(
              Target, I, Payload, Timestamp,
              Committee, Admissions, IdMode);
        noop ->
            valid;
        {controls, _Controls} ->
            invalid;
        invalid ->
            invalid
    end;
history_entry_verdict(Binding, I, Data, Timestamp, Projection, IdMode) ->
    case valid_history_entry(
           Binding, I, Data, Timestamp, Projection, IdMode) of
        true -> valid;
        false -> invalid
    end.

-doc "Verify local finality, then advance content or exact DTX history.".
-spec history_validate_advance({binary(), binary()}, quod_ledger:entry_artifact(),
                               history_projection(),
                               quod_dtx_phase_index:index()) ->
        {ok, history_projection(), list()} |
        {error, {invalid_transaction, pos_integer()} |
                {unavailable, network_identity, term()}}.
history_validate_advance(
  Binding, Entry, Projection, PhaseIndex) ->
    #entry{index = I} = quod_ledger:entry_view(Entry),
    case history_projection_before_entry(I, Projection) of
        {ok, Projection1} ->
            case quod_catchup:verify_entry(Binding, Entry, Projection1) of
                ok ->
                    history_advance_verified(
                      Binding, Entry, Projection1, PhaseIndex);
                {error, _} ->
                    {error, {invalid_transaction, I}}
            end;
        error ->
            {error, {invalid_transaction, I}}
    end.

%% Replay never infers an apply acknowledgement from a later slot.  The
%% committed reducer owns exact per-group acknowledgements after effects apply;
%% this history seam only validates the projection it was given.
history_projection_before_entry(_NextSlot, #{dtx := _Dtx} = Projection) ->
    {ok, Projection};
history_projection_before_entry(_NextSlot, _Projection) ->
    error.

%% Live finality already supplies a sanitized local commit certificate. Keeping
%% the semantic reducer separate avoids repeating quorum cryptography on the
%% commit hot path; startup/catch-up enter only through the public checked API.
history_advance_verified(
  Binding, Entry, Projection, PhaseIndex) ->
    #entry{index = I, data = Data} = quod_ledger:entry_view(Entry),
    case quod_ledger:classify(Data) of
        {content, _Transactions} ->
            case history_validate_content(Binding, Entry, Projection) of
                {ok, Projection1} -> {ok, Projection1, []};
                {error, _} = Error -> Error
            end;
        {controls, Classified} ->
            history_advance_dtx_batch(
              Binding, Entry,
              [Control || {_Kind, Control} <- Classified],
              Projection, PhaseIndex);
        noop ->
            case history_validate_content(Binding, Entry, Projection) of
                {ok, Projection1} -> {ok, Projection1, []};
                {error, _} = Error -> Error
            end;
        invalid ->
            {error, {invalid_transaction, I}}
    end.

history_advance_dtx_batch(
  Binding, Entry, Controls,
  #{dtx := Dtx0} = Projection, PhaseIndex) ->
    #entry{index = I} = quod_ledger:entry_view(Entry),
    case valid_dtx_history_requests(Binding, Entry, Controls) of
        valid ->
            case validated_dtx_entries(
                   Binding, Entry, Controls, Projection) of
                {ok, ControlRefs, LaneSequences} ->
                    case quod_dtx_phase_index:apply_batch(
                           PhaseIndex, ControlRefs, Dtx0) of
                        {ok, _Dtx1, Items} ->
                            Projection1 = project_dtx_batch_items(
                                            Items, LaneSequences,
                                            Entry, Projection),
                            {ok,
                             Projection1#{history_head :=
                                 {I, entry_history_hash(Entry)}},
                             dtx_batch_effects(Items)};
                        {error, _} ->
                            {error, {invalid_transaction, I}}
                    end;
                error ->
                    {error, {invalid_transaction, I}}
            end;
        {unavailable, network_identity, _Reason} = Unavailable ->
            {error, Unavailable};
        invalid ->
            {error, {invalid_transaction, I}}
    end.

valid_dtx_history_requests(_Binding, _Entry, []) -> valid;
valid_dtx_history_requests(Binding, Entry, [Control | Rest]) ->
    case valid_dtx_history_request(Binding, Entry, Control) of
        valid -> valid_dtx_history_requests(Binding, Entry, Rest);
        Other -> Other
    end.

dtx_batch_effects(Items) ->
    lists:flatmap(fun(#{effects := Effects}) -> Effects end, Items).

valid_dtx_history_request(
  Binding, Entry, Control) ->
    #entry{timestamp = Timestamp} = quod_ledger:entry_view(Entry),
    Material = quod_atomic:control_material(Control),
    case quod_ontology:network_identity(quod_atomic:requires_network_identity(Material), Binding) of
        {ok, Network} ->
            case quod_atomic:validate_request(Network, Binding, Timestamp, Material) of
                {ok, _} -> valid;
                {error, _} -> invalid
            end;
        {error, Reason} -> {unavailable, network_identity, Reason}
    end.

validated_dtx_entry(
  Binding, Entry, Control,
  #{admissions := Admissions, dtx := Dtx0, dtx_lanes := Lanes0}) ->
    Meta = quod_atomic:control_metadata(Control),
    Author = maps:get(author, Meta),
    Admission = maps:get(author_admission, Meta),
    Sequence = maps:get(sequence, Meta),
    Lane = {Admission, Author},
    case quod_atomic:verify_control(Binding, Control)
         andalso maps:get(Author, Admissions, undefined) =:= Admission
         andalso Sequence > maps:get(Lane, Lanes0, 0)
         andalso Dtx0 =/= undefined of
        false ->
            error;
        true ->
            case quod_dtx:certified_entry_ref(Binding, Entry, Control) of
                {ok, Ref} -> {ok, Ref, Lane, Sequence};
                {error, _} -> error
            end
    end.

project_dtx_transition(
  Entry, Dtx1, Lane, Sequence,
  #{dtx_lanes := Lanes0, timestamp := Timestamp0} = Projection) ->
    #entry{timestamp = Timestamp} = quod_ledger:entry_view(Entry),
    Projection#{dtx := Dtx1,
                dtx_lanes := Lanes0#{Lane => Sequence},
                timestamp := max(Timestamp, Timestamp0)}.

-doc "Preview one catch-up entry against an uncommitted phase-index delta.".
-spec history_preview_advance(
        {binary(), binary()}, quod_ledger:entry_artifact(), history_projection(),
        quod_dtx_phase_index:index(), quod_dtx_phase_index:delta()) ->
          {ok, history_projection(), list(), quod_dtx_phase_index:delta()} |
          {error, {invalid_transaction, pos_integer()} |
                  {unavailable, network_identity, term()}}.
history_preview_advance(
  Binding, Entry,
  Projection, PhaseIndex, Delta0) ->
    #entry{index = I, data = Data} = quod_ledger:entry_view(Entry),
    case history_projection_before_entry(I, Projection) of
        {ok, Projection1} ->
            case quod_catchup:verify_entry(Binding, Entry, Projection1) of
                ok ->
                    case quod_ledger:classify(Data) of
                        {content, _} ->
                            preview_content(
                              Binding, Entry, Projection1, Delta0);
                        noop ->
                            preview_content(
                              Binding, Entry, Projection1, Delta0);
                        {controls, Classified} ->
                            preview_dtx_batch(
                              Binding, Entry,
                              [Control || {_Kind, Control} <- Classified],
                              Projection1,
                              PhaseIndex, Delta0);
                        invalid ->
                            {error, {invalid_transaction, I}}
                    end;
                {error, _} = Error ->
                    Error
            end;
        error ->
            {error, {invalid_transaction, I}}
    end.

preview_content(Binding, Entry, Projection, Delta) ->
    case history_validate_content(Binding, Entry, Projection) of
        {ok, #{committee_views := Views} = Projection1} ->
            %% Stage every changed era in this window, not just its final era.
            %% No historical rows are copied from the borrowed index.
            Delta1 = case Views of
                [Current | _] -> quod_dtx_phase_index:preview_committee(Delta, Current);
                [] -> Delta
            end,
            {ok, Projection1, [], Delta1};
        {error, _} = Error -> Error
    end.

preview_dtx_batch(Binding, Entry, Controls,
                  #{dtx := Dtx0} = Projection, PhaseIndex, Delta0) ->
    #entry{index = I} = quod_ledger:entry_view(Entry),
    case valid_dtx_history_requests(Binding, Entry, Controls) of
        valid ->
            case validated_dtx_entries(
                   Binding, Entry, Controls, Projection) of
                {ok, ControlRefs, LaneSequences} ->
                    case quod_dtx_phase_index:preview_batch(
                           PhaseIndex, Delta0, ControlRefs, Dtx0) of
                        {ok, Delta1, _Dtx1, Items} ->
                            Projection1 = project_dtx_batch_items(
                                            Items, LaneSequences,
                                            Entry, Projection),
                            {ok,
                             Projection1#{history_head :=
                                 {I, entry_history_hash(Entry)}},
                             dtx_batch_effects(Items), Delta1};
                        {error, _Reason} ->
                            {error, {invalid_transaction, I}}
                    end;
                error ->
                    {error, {invalid_transaction, I}}
            end;
        {unavailable, network_identity, _Reason} = Unavailable ->
            {error, Unavailable};
        invalid ->
            {error, {invalid_transaction, I}}
    end.

%% Project one persisted entry onto the authoritative committee view. Reconstructing the committed block
%% here is load-bearing: the view id is bound to the same block hash that its finality certificate covered,
%% without adding a second hash representation to the ledger. A changed set can only come from a canonical
%% batch, so block reconstruction must succeed after history/catch-up verification.
-spec committee_view_id(binary(), slot(), binary(), [node_id()]) -> binary().
committee_view_id(Ns, AdoptionSlot, AdoptionBlockHash, NewValidators) ->
    crypto:hash(
      sha256,
      term_to_binary(
        {quod_committee_view, 2, Ns, AdoptionSlot, AdoptionBlockHash,
         lists:sort(NewValidators)},
        [deterministic])).

historical_sequences_ok(I, Data, Seqs) ->
    case quod_ledger:classify(Data) of
        {content, [_Genesis]} when I =:= 1 -> true;
        {content, Payload} -> transaction_sequences_ok(Payload, Seqs, #{});
        %% The DTX lane is checked by its own admission-scoped high-water in
        %% the shared history reducer. Until that projection is installed, a
        %% control record is not valid history.
        {controls, _Controls} -> false;
        noop -> true;
        invalid -> false
    end.

%% The committee change carried by one committed payload: the `peer_admitted` pubkeys it asserts (added)
%% and retracts (removed). Each transaction folds its diff (the validator id is the 4th arg / 5th element
%% of `peer_admitted(NodeId, Host, Port, Pubkey)`); a `noop` or malformed payload changes nothing. This ONE
%% function feeds both the live history projection and the boot/restart re-fold
%% (`log_projection/3`), so the running set can never drift from a fresh re-fold.
committee_delta(#transaction{} = Transaction) ->
    committee_transaction(Transaction, {[], []});
committee_delta(Data) ->
    case quod_ledger:classify(Data) of
        {content, Transactions} ->
            lists:foldl(fun committee_transaction/2, {[], []}, Transactions);
        {controls, _Controls} -> {[], []};
        noop -> {[], []};
        invalid -> {[], []}
    end.

committee_transaction(#transaction{diff = Diff}, Acc) ->
    committee_diff(Diff, Acc).

committee_diff(Diff, Acc) ->
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
%% removed member stays a gossiped-with observer). The non-content kinds yield nothing by design, not
%% defensively: a catch-up window routinely carries `noop` skip entries, and this walks raw window payloads.
admitted_endpoints(Data) ->
    case quod_ledger:classify(Data) of
        {content, Transactions} ->
            lists:flatmap(fun transaction_endpoints/1, Transactions);
        {controls, _Controls} -> [];
        noop -> [];
        invalid -> []
    end.

transaction_endpoints(#transaction{diff = Diff}) ->
    case proper_list(Diff) of
        true  -> [{Pk, {H, P}} || {assert, {{peer_admitted, _Id, H, P, Pk}, _B}} <- Diff];
        false -> []
    end.

%% Keep recovery routing in the same bounded, replayed projection as committee
%% membership.  Endpoints are authenticated hints: every dial still pins the
%% TLS peer to the map key.  Invalid historical address terms are ignored
%% rather than allowed to poison replay or the recovery candidate set.
advance_validator_routes(Data, Routes) ->
    case quod_ledger:classify(Data) of
        {content, Transactions} ->
            lists:foldl(fun transaction_validator_routes/2,
                        Routes, Transactions);
        {controls, _Controls} -> Routes;
        noop -> Routes;
        invalid -> Routes
    end.

transaction_validator_routes(#transaction{diff = Diff}, Routes) ->
    case proper_list(Diff) of
        true -> lists:foldl(fun validator_route_op/2, Routes, Diff);
        false -> Routes
    end.

validator_route_op(
  {assert, {{peer_admitted, _Id, Host, Port, <<_:256>> = Key}, _Body}},
  Routes) ->
    Endpoint = {Host, Port},
    case quod_quic:valid_endpoint(Endpoint) of
        true -> Routes#{Key => Endpoint};
        false -> Routes
    end;
validator_route_op(
  {retract, {{peer_admitted, _Id, _Host, _Port, <<_:256>> = Key}, _Body}},
  Routes) ->
    maps:remove(Key, Routes);
validator_route_op(_Op, Routes) ->
    Routes.

proper_list([_ | Rest]) -> proper_list(Rest);
proper_list([])         -> true;
proper_list(_)          -> false.

%% Apply a committed payload's committee delta onto a validator set — sorted (deterministic, every node
%% agrees byte-for-byte) and idempotent (a re-asserted member is a no-op).
apply_committee_delta(Change, V) ->
    apply_committee_delta_rows(committee_delta(Change), V).

apply_membership_diff(Diff, V) ->
    apply_committee_delta_rows(committee_diff(Diff, {[], []}), V).

apply_committee_delta_rows({Adds, Removes}, V) ->
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
    case genesis_source(Cfg) of
        {ok, _Source} -> valid_batch_window(Cfg);
        {error, _} = Error -> Error
    end.

genesis_source(Cfg) ->
    File = genesis_file(Cfg),
    Diff = maps:get(genesis_diff, Cfg, undefined),
    case [Source || Source <- [{file, File}, {diff, Diff}],
                    source_present(Source)] of
        [] ->
            {ok, none};
        [{file, SourceFile}] ->
            {ok, {file, SourceFile}};
        [{diff, SourceDiff}] ->
            validate_genesis_diff(SourceDiff);
        _Multiple ->
            {error, multiple_genesis_sources}
    end.

source_present({file, none}) -> false;
source_present({_Kind, undefined}) -> false;
source_present({_Kind, _Value}) -> true.

%% Config-time shape/size check for the genesis_diff option. It deliberately
%% does NOT require a policy clause: a RESUME passes its (ignored) genesis_diff
%% through here too, and forcing policy would reject a valid resume. Fresh
%% founding adds the host-entry policy before valid_genesis_transaction/3
%% enforces policy presence; restart replay and catch-up use that same validator.
validate_genesis_diff(Diff) ->
    case quod_diff:valid_ops(Diff) of
        false ->
            {error, invalid_genesis_diff};
        true ->
            try byte_size(term_to_binary(Diff, [deterministic])) of
                Bytes when Bytes =< ?MAX_GENESIS_INITIAL_DIFF_BYTES ->
                    {ok, {diff, Diff}};
                _TooLarge ->
                    {error, initial_content_too_large}
            catch
                _:_ -> {error, invalid_genesis_diff}
            end
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
                true ->
                    Count = length(founding(Cfg, maps:get(node_id, Cfg))),
                    case Count =< ?MAX_VALIDATORS of
                        true  -> valid_mode(Cfg);
                        false -> {error, {committee_too_large, Count}}
                    end;
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

genesis_initial_diff(Cfg) ->
    case genesis_source(Cfg) of
        {ok, none} ->
            [];
        {ok, {diff, Diff}} ->
            Diff;
        {ok, {file, File}} ->
            validate_compiled_genesis_diff(quod_prolog:genesis_diff(File));
        {error, Reason} ->
            throw({genesis_failed, Reason})
    end.

validate_compiled_genesis_diff(Diff) ->
    case validate_genesis_diff(Diff) of
        {ok, {diff, Diff}} -> Diff;
        {error, Reason} -> throw({genesis_failed, Reason})
    end.

status_map(S) ->
    {DtxWaiting, DtxDormant} = dtx_admission_counts(S#s.dtx_admission),
    Role = case is_participant(S) of true -> validator; false -> observer end,
    {_ProgressSlot, ProgressPhase, ProgressQuorum} = progress_status(S#s.head_progress),
    ProposalSlot = S#s.approved + 1,
    #{role => Role, committee => S#s.validators,
      committee_id => S#s.committee_id,
      history_projection => state_projection(S),
      slot => S#s.slot,
      committed => S#s.slot, approved => S#s.approved, last_applied => S#s.last_applied,
      syncing => syncing(S), recovery => recovery_phase(S#s.sync),
      finality_slot => S#s.slot + 1,
      dtx_coordinators => dtx_coordinator_status(S#s.dtx_coordinators),
      dtx_admission_waiting => DtxWaiting, dtx_admission_dormant => DtxDormant,
      progress_phase => ProgressPhase, progress_quorum_ready => ProgressQuorum,
      proposal_slot => ProposalSlot,
      proposal_open => case proposal_slot(S) of {ok, ProposalSlot} -> true; _ -> false end}.

dtx_coordinator_status(Coordinators) when is_map(Coordinators) ->
    maps:map(
      fun(_GroupId,
          #dtx_coordinator_owner{group_id = GroupId}) ->
              #{group_id => GroupId}
      end, Coordinators).

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
    {DtxWaiting, DtxDormant} = dtx_admission_counts(S#s.dtx_admission),
    {OwnerCurrent, OwnerBytesCurrent} = simplex_owner_current(S),
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
      dtx_admission_waiting => DtxWaiting,
      dtx_admission_dormant => DtxDormant,
      owner_current => OwnerCurrent,
      owner_peak => simplex_owner_peaks(S, OwnerCurrent),
      owner_bytes_current => OwnerBytesCurrent,
      owner_bytes_peak => simplex_owner_byte_peaks(S, OwnerBytesCurrent),
      ingress_retargets => S#s.ingress_retargets,
      relay_accepted => S#s.relay_accepted,
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

simplex_owner_current(
  #s{retained_dtx = Registry, dtx_correlations = Correlations,
     dtx_workers = Workers}) ->
    {#{dtx_control => #{retained => quod_dtx_owner:count(Registry),
                        ready => quod_dtx_owner:ready_count(Registry),
                        blocked => quod_dtx_owner:blocked_count(Registry),
                        waiters => quod_dtx_owner:waiter_count(Registry)},
       dtx_endpoint => #{outbound => map_size(Correlations),
                         inbound => map_size(Workers)}},
     #{dtx_control => quod_dtx_owner:bytes(Registry)}}.

track_owner_peaks(S = #s{owner_row_peaks = RowPeaks0,
                         owner_byte_peaks = BytePeaks0}) ->
    {Current, CurrentBytes} = simplex_owner_current(S),
    RowPeaks = maps:fold(
                 fun(Component, States, Acc0) ->
                         maps:fold(
                           fun(State, Value, Acc) ->
                                   Key = {Component, State},
                                   Acc#{Key => max(Value,
                                                   maps:get(Key, Acc, 0))}
                           end, Acc0, States)
                 end, RowPeaks0, Current),
    BytePeaks = maps:fold(
                  fun(Component, Value, Acc) ->
                          Acc#{Component => max(Value,
                                                maps:get(Component, Acc, 0))}
                  end, BytePeaks0, CurrentBytes),
    S#s{owner_row_peaks = RowPeaks, owner_byte_peaks = BytePeaks}.

simplex_owner_peaks(#s{owner_row_peaks = Peaks}, Current) ->
    maps:map(
      fun(Component, States) ->
              maps:map(
                fun(State, Value) ->
                        max(Value, maps:get({Component, State}, Peaks, 0))
                end, States)
      end, Current).

simplex_owner_byte_peaks(#s{owner_byte_peaks = Peaks}, Current) ->
    maps:map(
      fun(Component, Value) ->
              max(Value, maps:get(Component, Peaks, 0))
      end, Current).

observe_simplex_owner_terminal(
  #s{ns = Ns}, Component, Phase, Result, StartedAt)
  when is_integer(StartedAt) ->
    quod_metrics:observe_ontology_owner_terminal(
      Ns, Component, Phase, Result,
      max(0, quod_time:mono_ms() - StartedAt)),
    ok;
observe_simplex_owner_terminal(
  #s{}, _Component, _Phase, _Result, _StartedAt) ->
    ok.

endpoint_terminal_result({ok, Response, _ValidationSidecar}) ->
    endpoint_terminal_result(Response);
endpoint_terminal_result({error, timeout}) -> timeout;
endpoint_terminal_result({error, not_ready}) -> unavailable;
endpoint_terminal_result({error, not_found}) -> not_found;
endpoint_terminal_result({error, busy}) -> busy;
endpoint_terminal_result({error, invalid_request}) -> rejected;
endpoint_terminal_result({error, {prepare_refused, _, _, _, _}}) -> rejected;
endpoint_terminal_result({error, _}) -> error;
endpoint_terminal_result({error, _RequestId, not_ready}) -> unavailable;
endpoint_terminal_result({error, _RequestId, not_found}) -> not_found;
endpoint_terminal_result({error, _RequestId, busy}) -> busy;
endpoint_terminal_result({error, _RequestId, invalid_request}) -> rejected;
endpoint_terminal_result({refused, _RequestId, _, _, _, _}) -> rejected;
endpoint_terminal_result(_) -> completed.

dtx_worker_terminal_result({submit_result, _Digest, Result}, Response) ->
    prefer_terminal_result(endpoint_terminal_result(Result), Response);
dtx_worker_terminal_result(Result, Response) ->
    prefer_terminal_result(endpoint_terminal_result(Result), Response).

prefer_terminal_result(completed, Response) ->
    endpoint_terminal_result(Response);
prefer_terminal_result(Result, _Response) ->
    Result.

dtx_retirement_result(not_in_charge) -> unavailable;
dtx_retirement_result(_) -> error.

dtx_admission_counts(none) -> {0, 0};
dtx_admission_counts(#dtx_admission{waiting = Waiting}) ->
    quod_atomic_admission:counts(Waiting).

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
