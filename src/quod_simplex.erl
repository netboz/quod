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

**Safety** rests on one guard: a validator issues a *commit* share for `v` only if it has NOT issued a
*complaint* share for `v` — so a slot can never carry both a commit cert and a complaint cert (any two
`⅔`-quorums overlap on ≥1 honest party who does at most one). Hence a committed block is unique and
irreversible. Everything is plain **Ed25519**: a certificate is a bag of `⅔` signatures, self-verifying
against the validator set — which is exactly the P2 relayed-commit proof a subscriber checks.

The runtime keeps two frontiers: **approved** (support-certified, safe to extend) and
**committed** (durable and externally visible). Leaders micro-batch ordered transactions
into one block and may build one child over an uncommitted approved parent. A child commit also
finalizes its approved parent; catch-up persists and verifies that implicit proof. Committee
transactions are singleton barriers, so a voting-set change is explicitly committed before
the next proposal opens.

The same engine handles N=1 and multi-validator namespaces, complaint-certified skips,
trustless catch-up, observer promotion, live member recovery, and deterministic Prolog apply.
Every wire transaction is structurally checked before an honest validator signs it. Remaining
security work, notably transaction-author signatures, vote-latch persistence, and epoch-frozen
validator sets, is tracked in `doc/deferred.md`.
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
         well_formed_transaction/1,
         committee_delta/1, apply_committee_delta/2]).   %% committee = projection of peer_admitted facts

%% Per-namespace consensus process — API + gen_statem callbacks.
-export([start_link/2, append/2, rebuild/1, status/1, committee/1, genesis_hash/1, stats/1, namespaces/0]).
-export([init/1, callback_mode/0, running/3, terminate/3]).

-ifdef(TEST).
%% consensus-engine surface driven by eunit (the #eng record is otherwise private)
-export([eng_new/2, eng_offer/2, eng_prune/2, eng_tree/1, eng_committed/1, ts_acceptable/3,
         prune_dials/2, membership_change_ok/2, change_acceptable/2, complaint_amplified/3,
         admitted_endpoints/1, persisted_cert/4, eng_evict_final/4, eng_set_validators/2,
         ahead_cert_ceiling/1, eng_with_certs/2,   %% Slice 1: the gap detector's pure core
         is_participant/1, may_vote/1, caught_up/1, may_lead/1, should_sync/1, syncing/1,
         initial_sync/1, tip_quorum/3, maybe_arm_sync/1, pace_tick/1, arm_ready/1, backoff/1,
         recovery_failed/1, may_sink/2, reset_pace/0, test_state/1, test_arm/1, test_sync/1,
         proposal_slot/1, acceptable_payload/2,
         encode/2]).   %% encode/2: the `{log, Ns}` wire frame — used by simplex_SUITE to inject a crafted propose
-endif.

%% These validate records decoded from UNTRUSTED peer input (binary_to_term yields any term, so a
%% typed record can still carry malformed fields at runtime). Dialyzer trusts the declared field types
%% and consequently marks their reject branches unreachable; weakening the canonical record types would
%% hide useful mistakes everywhere else.
-dialyzer({nowarn_function, [dispatch/3, well_formed_block/1, well_formed_share/1, well_formed_cert/1,
                             valid_read_check/1, valid_diff/1, committee_transaction/2,
                             transaction_endpoints/1, proper_signatures/1, proper_list/1]}).

%% A node's SIGNING identity: the subset of `t:quod_identity:identity/0` consensus needs (pubkey +
%% private key), without the TLS cert. `make_share/4` signs with `key`; the share's signer is `pubkey`.
-type signer() :: #{pubkey := node_id(), key := quod_identity:key_term()}.

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
May this validator issue a **commit** share for `Slot`? Only if it has NOT already issued a
**complaint** share for `Slot`. Together with `may_complain/2` this is the whole safety argument: an
honest validator contributes to at most ONE of {commit cert, complaint cert} per slot, so the two can
never both form (their `⅔`-quorums would have to overlap only on it) — a committed block is unique and
permanent. `ComplainedSlots` is any plain list (membership is checked directly — no ordering contract,
so a caller can't silently break it by passing an unsorted list).
""".
-spec may_commit(slot(), [slot()]) -> boolean().
may_commit(Slot, ComplainedSlots) ->
    not lists:member(Slot, ComplainedSlots).

-doc """
May this validator issue a **complaint** (skip) share for `Slot`? Only if it has NOT already issued a
**commit** share for `Slot` — the symmetric half of the mutual-exclusion guard (`may_commit/2`).
`CommittedSlots` is any plain list.
""".
-spec may_complain(slot(), [slot()]) -> boolean().
may_complain(Slot, CommittedSlots) ->
    not lists:member(Slot, CommittedSlots).

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
set, so a client (or a follower redirect) can reach the right proposer, and a complaint-skip of slot
`v` moves slot `v+1` to a *different* leader — that rotation IS the failover. `Slot ≥ 1` (genesis is 0).
Stable per-epoch leaders (keep one leader for K slots) are the Stage-4 optimization; this rotates each slot.
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
%% `{log, Ns}` transport, the complaint timer, and the per-slot committee.

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
-define(DELTA_MS,   1000).   %% Δ_timeout: a proposed-but-stuck head slot is complained (skipped) after this;
                             %% must exceed real commit latency (override via app-env `simplex_delta_ms`)
-define(SYNC_WINDOW,  256).  %% entries requested per catch-up / gap-fill fetch (matches the server's block cap)
-define(SINK_MS,     30000). %% budget for one sink window (store append + KB replay) — generous
-define(TIP_PROBE_MS, 9500). %% one parallel tip round; exceeds quod_catchup's 9s public pull budget
-define(RECOVERY_FETCHES, 2). %% bound source changes inside one recovery worker (retries resume durably)
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

-record(round, {supporting = none :: none | binary(),
                commit = false :: boolean(),
                complaint = false :: boolean(),
                invalid = false :: boolean(),
                validating = none :: none | binary()}).

-record(batch, {slot :: slot(),
                parent :: slot(),
                items_rev = [] :: [{gen_statem:from(), #transaction{}}],
                bytes = 0 :: non_neg_integer()}).

-record(local_proposal, {hash :: binary(),
                         waiters = [] :: [gen_statem:from()]}).

-record(s, {ns           :: binary(),
            self         :: node_id(),               %% our pubkey == node_id
            id           :: signer() | undefined,    %% signing identity (pubkey + private key)
            store        :: quod_ledger_store:handle() | undefined,
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
            active_slot   = none :: none | slot(),       %% the head+1 slot the Δ complaint timer is armed for
            commit_buf = #{} :: #{slot() => {commit, #block{}} | skip},  %% out-of-order finalizations, drained in order
            conns      = #{} :: #{node_id() => {pid(), reference()}},  %% our OUTBOUND links to peers
            outbox     = #{} :: #{node_id() => [binary()]},            %% frames buffered while a link opens
            dialing    = #{} :: #{node_id() => integer()},             %% peer => monotonic-ms deadline of its in-flight open_link dial
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
            r_busy     = 0 :: non_neg_integer(),   %% append rejected: batch/pipeline capacity unavailable
            r_redirect = 0 :: non_neg_integer(),   %% append not-in-charge: not this slot's leader / not a member (redirect)
            r_bad      = 0 :: non_neg_integer(),    %% append rejected: unacceptable change
            membership_rejects = 0 :: non_neg_integer(),   %% membership proposals a KB verdict rejected as invalid
            redrives   = 0 :: non_neg_integer(),   %% Δ re-fires that re-broadcast our own in-flight proposal
            weak_cert_waits = 0 :: non_neg_integer()}).  %% finalizations refused on a sub-quorum cert (Slice E,
                                                         %% the stale-cert hazard) — climbing = a laggard waiting

-ifdef(TEST).
%% Build a minimal #s{} for the Slice-4 gate-predicate eunit (the record is otherwise private). Only the
%% fields the pure predicates read carry meaning; every other field takes its record default.
test_state(Overrides) ->
    S = maps:fold(fun(approved, _V, Acc) -> Acc;
                     (K, V, Acc) -> test_state_set(K, V, Acc)
                  end, #s{ns = <<"t">>, self = <<"self">>}, Overrides),
    case maps:find(approved, Overrides) of
        {ok, V} -> S#s{approved = V};
        error   -> S
    end.
test_state_set(self, V, S)       -> S#s{self = V};
test_state_set(validators, V, S) -> S#s{validators = V};
test_state_set(slot, V, S)       -> S#s{slot = V, approved = V};
test_state_set(approved, V, S)   -> S#s{approved = V};
test_state_set(eng, V, S)        -> S#s{eng = V};
test_state_set(sync, V, S)       -> S#s{sync = V};
test_state_set(last_applied, V, S) -> S#s{last_applied = V};
test_state_set(prolog_ready, V, S) -> S#s{prolog_ready = V};
test_state_set(sync_arm, V, S)   -> S#s{sync_arm = V}.
test_arm(#s{sync_arm = A})       -> A.   %% read the pacing tuple back out of a state (record is private)
test_sync(#s{sync = Sy})         -> Sy.
-endif.

callback_mode() -> [state_functions].

%%%===================================================================
%%% API
%%%===================================================================

start_link(Ns, Config) ->
    gen_statem:start_link(quod_reg:via({quod_simplex, Ns}), ?MODULE, {Ns, Config}, []).

-doc """
Submit a change. Blocks until the block commits (`{ok, Slot}`); at N=1 that is its own fsync. The error
arms are the stable consensus-append contract `quod_prolog` handles: `busy` (a proposal already in
flight), `not_in_charge` (this node isn't the slot's leader — a redirect hint, or `unavailable` if this
process is unreachable), and `skipped` (a multi-node committee complaint-skipped our proposed slot →
retry). At N=1 only the sole-validator commit path runs, so an append just returns `{ok, Slot}`.
""".
-spec append(binary(), #transaction{}) ->
        {ok, slot()} | {error, busy} | {error, skipped} | {error, bad_change}
      | {error, not_in_charge, node_id() | none | unavailable}.
append(Ns, Change) ->
    try gen_statem:call(quod_reg:via({quod_simplex, Ns}), {append, Change}, 5000)
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
    S0 = #s{ns = Ns, self = maps:get(pubkey, Id), id = Id, store = Store, chan = Chan},
    %% A bad/missing genesis `.pl` on create is fatal — fail-fast, the app stops.
    try load_or_bootstrap(S0, Cfg) of
        S1 ->
            Committed = S1#s.slot,   %% commits are in order, so the height IS the committed floor
            Eng = eng_new(active_validators(S1), Committed),   %% seed the engine's voting set (active set)
            %% One periodic tick drives everything post-boot: peer redials AND the sync armer (`maybe_arm_sync`)
            %% that kicks boot-sync/gap-fill. A fresh `mode=join` node boots `unconfirmed`, so `should_sync`
            %% arms its catch-up at the first tick — no separate join kick.
            {ok, running, S1#s{last_applied = 0, approved = Committed, eng = Eng}, [tick_timeout()]}
    catch
        throw:{genesis_failed, _} = Reason -> {stop, Reason}
    end.

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
load_or_bootstrap(S0 = #s{store = Store}, Cfg) ->
    Base = case quod_ledger_store:last(Store) of
               0     -> S0;   %% empty ⇒ unfounded (slot 0)
               LastI -> {Vs, Ts} = quod_ledger_store:fold(Store, 1, LastI,
                                                          fun log_projection_step/2, {[], 0}),
                        S0#s{validators = Vs, slot = LastI, last_ts = Ts}
           end,
    S1 = case {maps:get(mode, Cfg), Base#s.slot} of
             {join,   _} -> Base#s{genesis_hash = maps:get(genesis_hash, Cfg)};
             {create, 0} -> bootstrap(Cfg, Base);   %% fresh founder
             {create, _} -> Base                    %% restarted founder / admitted member
         end,
    S1#s{sync = initial_sync(S1)}.

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
    E = #entry{index = 1, data = GenesisTx},
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
    {S1, Reply} = handle_append(From, Change, S0#s{submitted = S0#s.submitted + 1}),
    {keep_state, S1, Reply ++ timer_actions(S0, S1)};
%% A freshly-(re)started quod_prolog: re-drive committed blocks from the start (async casts, in slot
%% order), then mark it ready ONLY once its kb is caught up — never a prove over a half-built kb.
running(cast, rebuild, S) ->
    {keep_state, maybe_mark_ready(apply_committed(S#s{last_applied = 0, prolog_ready = false}))};
%% A peer's consensus message (proposal / share / cert) on our `{log, Ns}` channel. `Peer` is the
%% sender's authenticated node_id (pubkey); the address is a routing hint we ignore. Processing it can
%% advance/skip the head (arming or cancelling the Δ timer) — `timer_actions/2` reflects that.
running(info, {quod_message, {{Peer, _Addr}, _InLink}, Chan, Payload}, S0 = #s{chan = Chan}) ->
    %% Only a committee member acts on consensus traffic. A node that is still joining, or caught up but
    %% not (yet) admitted, is a read-only observer — it stays current via catch-up + its KB, never by
    %% voting — so it drops the committee's propose/share/cert stream (also guards `leader/2` on `[]`).
    case is_participant(S0) andalso decode(Payload, S0#s.ns) of
        false -> {keep_state, S0};   %% not a member ⇒ ignore, OR a member that got an undecodable frame
        error -> {keep_state, S0};
        Msg   -> S1 = dispatch(Peer, Msg, S0),
                 {keep_state, S1, timer_actions(S0, S1)}
    end;
running(info, {quod_message, _, _OtherChan, _}, S) -> {keep_state, S};   %% Brahms / another namespace's log
%% A membership verdict from our own quod_prolog (a plain message from `deliver_verdict`): emit or withhold
%% the deferred support share. The tag echoes the `{Slot, BlockHash}` we requested with, so the verdict binds
%% to the exact block. Support can advance/skip the head, so reflect that in the Δ timer.
running(info, {membership_verdict, {Sl, BH}, Verdict}, S0) ->
    S1 = on_membership_verdict(Sl, BH, Verdict, S0),
    {keep_state, S1, timer_actions(S0, S1)};
running(info, {link_up, Peer, Chan, LinkPid}, S = #s{chan = Chan}) ->
    {keep_state, handle_link_up(Peer, LinkPid, S)};
running(info, {link_error, Peer, Chan}, S = #s{chan = Chan}) ->
    %% the dial failed — clear the in-flight marker but KEEP the buffered frames; the tick re-dials
    %% (consensus emits each propose/share only once, so dropping them would stall the slot forever).
    {keep_state, S#s{dialing = maps:remove(Peer, S#s.dialing)}};
%% The sync worker CRASHED before casting `{sync_done,_}` (a normal exit always casts first, and that cast,
%% sent before the exit, is processed before this DOWN — flipping `sync` away from `{pulling,Pid}` to the
%% generic clause below). Clear the single-flight latch + back off; the tick re-arms if still `should_sync`.
%% The worker resumes from the persisted height, so a retry continues from the prefix already on disk.
running(info, {'DOWN', _Ref, process, Pid, _Reason}, S = #s{sync = {pulling, Pid}}) ->
    {keep_state, recovery_failed(S)};
running(info, {'DOWN', _Ref, process, Pid, _}, S) ->
    {keep_state, drop_conn(Pid, S)};
%% Seal the current micro-batch. A stale timeout is harmless: flush_batch/2 only
%% acts when the collecting slot still matches.
running({timeout, batch}, {flush_batch, V}, S0) ->
    S1 = flush_batch(V, S0),
    {keep_state, S1, timer_actions(S0, S1)};
%% Δ_timeout fired for slot V (armed when V=head+1 became an *active* view — a proposal seen, or a
%% local client write we couldn't lead). The redrive-or-complain decision lives in `on_complain_timeout/2`;
%% this clause owns only the timer mechanics: re-arm while V stays stuck (the Δ re-fire IS the retransmit
%% over the send-once transport), stop once the head advances (commit or skip). See on_complain_timeout/2.
running({timeout, complain}, {complain, V}, S0) ->
    S1 = on_complain_timeout(V, S0),
    Actions = case S1#s.active_slot of
                  V -> [{{timeout, complain}, delta_ms(), {complain, V}}];   %% still stuck ⇒ keep pressing
                  _ -> timer_actions(S0, S1)                                 %% advanced/resolved ⇒ cancel or re-arm
              end,
    {keep_state, S1, Actions};
%% Consensus re-drive: sweep any dial that resolved to neither link_up nor link_error (presumed lost),
%% re-dial every peer whose link never came up (its frames are still buffered), AND arm sync — the one
%% place a boot-sync / member gap-fill is kicked (`maybe_arm_sync`, single-flight + paced, off the hot path).
running({timeout, tick}, tick, S) ->
    S1 = maybe_arm_sync(redrive_votes(redial_pending(sweep_stale_dials(S)))),
    {keep_state, maybe_mark_ready(S1), [tick_timeout()]};
%% Only the recovery coordinator can produce `{ready, Height}`: it has pulled every available committee
%% source and observed a certificate quorum at the final local height. Bind completion to the monitored
%% worker pid and the exact height it corroborated. There is no intermediate state: allowing consensus
%% ingestion during a hold-down could advance the durable head and then grant readiness to that newer,
%% uncorroborated height.
running(cast, {sync_done, Pid, {ready, H}},
        S = #s{sync = {pulling, Pid}, slot = H}) when H >= 1 ->
    S1 = S#s{sync = ready, sync_arm = reset_pace()},
    {keep_state, maybe_mark_ready(apply_committed(S1))};
%% Any incomplete round returns to the single `unconfirmed` state. Partial windows stay durable and the
%% next worker resumes from the resulting height, but no signing capability survives the failure.
running(cast, {sync_done, Pid, _Result}, S = #s{sync = {pulling, Pid}}) ->
    {keep_state, recovery_failed(S)};
running(cast, {sync_done, _Pid, _}, S) -> {keep_state, S};   %% result from an obsolete worker
%% The sync worker — and, for an observer, the feed's anti-entropy pull — hands each verified, contiguous
%% window here to persist + replay in slot order. The caller presents an explicit source capability:
%% `{recovery,Pid}` must match the one monitored recovery owner; `feed` is accepted only by a settled
%% observer. This keeps the sole-writer rule local and makes a promotion crossing deterministic.
running({call, From}, {sink_catchup, Source, Es}, S) ->
    case may_sink(Source, S) of
        %% `reseat_engine` inside may clear `active_slot`; `timer_actions/2` cancels the stale complain timer
        %% (a no-op for a joiner/observer, load-bearing when a VOTING member gap-fills — DA review).
        true  -> {S1, Reply} = apply_catchup_window(Es, S),
                 {keep_state, S1, [{reply, From, Reply} | timer_actions(S, S1)]};
        false -> {keep_state, S, [{reply, From, {error, not_following}}]}
    end;
running({call, From}, get_status, S)       -> {keep_state, S, [{reply, From, status_map(S)}]};
running({call, From}, get_committee, S)    -> {keep_state, S, [{reply, From, S#s.validators}]};
running({call, From}, get_genesis_hash, S) -> {keep_state, S, [{reply, From, local_genesis_hash(S)}]};
running({call, From}, get_stats, S)        -> {keep_state, S, [{reply, From, stats_map(S)}]};
running(_EventType, _Event, S)             -> {keep_state, S}.

terminate(_Reason, _State, #s{chan = Chan, store = Store}) ->
    _ = case Chan of undefined -> ok; _ -> catch quod_reg:unsubscribe({channel, Chan}) end,
    _ = case Store of
            undefined -> ok;
            _         -> try quod_ledger_store:close(Store) catch _:_ -> ok end
        end,
    ok.

%%%===================================================================
%%% append (propose) → engine → commit → apply
%%%===================================================================

%% Appends collect for a few milliseconds into one block. A sealed proposal owns its
%% parked callers until commit/skip; the next slot may open as soon as that block is
%% notarized, even though the durable committed frontier has not caught up yet.
handle_append(From, Change, S = #s{self = Self}) ->
    case may_lead(S) of
        false -> redirect_append(From, none, S);
        true ->
            case acceptable_change(Change, S) of
                false -> reject_append(From, bad_change, S);
                true ->
                    case proposal_slot(S) of
                        blocked -> reject_append(From, busy, S);
                        {ok, Next} ->
                            Vs = active_validators(S),
                            case leader(Next, Vs) of
                                Self   -> collect_append(From, Change, Next, S);
                                Leader -> redirect_append(From, Leader, arm_complaint(Next, S))
                            end
                    end
            end
    end.

reject_append(From, bad_change, S) ->
    {S#s{r_bad = S#s.r_bad + 1}, [{reply, From, {error, bad_change}}]};
reject_append(From, too_large, S) ->
    {S#s{r_bad = S#s.r_bad + 1}, [{reply, From, {error, too_large}}]};
reject_append(From, busy, S) ->
    {S#s{r_busy = S#s.r_busy + 1}, [{reply, From, {error, busy}}]}.

redirect_append(From, Leader, S) ->
    {S#s{r_redirect = S#s.r_redirect + 1},
     [{reply, From, {error, not_in_charge, Leader}}]}.

%% A depth-one pipeline permits proposing H+2 after H+1 is approved but before it
%% commits. It stops there until commit catches up. Membership blocks are barriers,
%% and a complaint-finalized slot waiting behind an earlier commit is not reopened.
proposal_slot(S = #s{slot = Committed, approved = Approved, collecting = Collecting,
                     local_proposals = Local, commit_buf = Buf}) ->
    Next = Approved + 1,
    HasBatch = case Collecting of #batch{slot = Next} -> true; _ -> false end,
    Open = Approved =< Committed + ?PIPELINE_DEPTH
           andalso (HasBatch orelse not maps:is_key(Next, Local))
           andalso not maps:is_key(Next, Buf)
           andalso not membership_barrier(S),
    case Open of true -> {ok, Next}; false -> blocked end.

collect_append(From, Change, Slot, S = #s{collecting = none}) ->
    Bytes = ?BATCH_ENVELOPE_BYTES + encoded_change_size(Change),
    case Bytes =< ?MAX_BLOCK_BYTES andalso membership_can_enter(Change, S) of
        false when Bytes > ?MAX_BLOCK_BYTES -> reject_append(From, too_large, S);
        false -> reject_append(From, busy, S);
        true ->
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
    Full = length(Items) >= ?MAX_BATCH_TXS orelse Bytes + Added > ?MAX_BLOCK_BYTES,
    Duplicate = lists:any(fun({_From, T}) -> T#transaction.tx_id =:= Change#transaction.tx_id end, Items),
    case {Duplicate, is_membership_change(Change) orelse Full} of
        {true, _} -> reject_append(From, bad_change, S);
        {false, true} -> reject_append(From, busy, S);
        {false, false} ->
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
    case acceptable_payload(Payload, S) of
        false -> reject_collected_batch(Items, S);
        true  -> propose_batch(Slot, Parent, Items, Payload, S)
    end;
flush_batch(_Slot, S) -> S.   %% stale named timeout after an early/full flush

propose_batch(Slot, Parent, Items, Payload, S) ->
    Waiters = [From || {From, _Change} <- Items],
    Block = #block{slot = Slot, parent = Parent, payload = Payload,
                   timestamp = max(quod_time:now_ms(), parent_timestamp(Parent, S))},
    BH = block_hash(Block),
    Local = #local_proposal{hash = BH, waiters = Waiters},
    S1 = S#s{collecting = none,
             local_proposals = (S#s.local_proposals)#{Slot => Local},
             proposals = S#s.proposals + 1,
             batched_txs = S#s.batched_txs + length(Payload)},
    S2 = broadcast({propose, Block}, S1),
    S3 = engine_step([{block, BH, Block}], S2),
    arm_complaint(Slot, support_or_validate(Block, BH, S3)).

reject_collected_batch(Items, S) ->
    _ = [gen_statem:reply(From, {error, bad_change}) || {From, _Change} <- Items],
    S#s{collecting = none, r_bad = S#s.r_bad + length(Items)}.

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
apply_event({notarized, #block{slot = Sl} = Block}, S0) ->
    S = approve_block(Block, S0),
    Round = round_state(Sl, S),
    case may_commit(Sl, complained_slots(S)) andalso not Round#round.invalid of
        false -> S;
        true  -> case own_share(commit, Sl, engine_block_hash(Sl, S), S) of
                     blocked -> S;
                     {ok, Share} ->
                         S1 = put_round(Sl, Round#round{commit = true}, S),
                         engine_step([{share, Share}], broadcast({share, Share}, S1))
                 end
    end;
%% A block is final: apply it, in slot order (out-of-order finalizations are buffered — contiguous apply).
apply_event({committed, Slot, Block}, S) ->
    commit_contiguous(Slot, Block, S);
%% A slot was complaint-skipped: finalize it as an empty (`noop`) slot, in order — advancing the height
%% so the rotated leader for the next slot proposes.
apply_event({skipped, Slot}, S) ->
    skip_contiguous(Slot, clear_active(Slot, S)).

approve_block(#block{slot = Sl}, S = #s{approved = Approved}) ->
    S#s{approved = max(Approved, Sl),
        active_slot = case S#s.active_slot of Sl -> none; A -> A end}.

%% Persist the committed block (durable before we ack), apply it into quod_prolog, advance the height,
%% clear the per-slot latches, and reply `{ok, Slot}` to every caller in the batch.
commit_block(Slot, #block{payload = Payload, timestamp = BlockTs}, S = #s{store = Store, eng = Eng}) ->
    BH = engine_block_hash(Slot, S),
    case persisted_finality(Slot, BH, Eng) of
        none -> weak_cert_wait(commit, Slot, BH, S);   %% Slice E: don't finalize on a sub-quorum cert
        Cert ->
            Data = quod_ledger:data(Payload),
            E = #entry{index = Slot, data = Data, timestamp = BlockTs, cert = Cert},
            {ok, Store1} = quod_ledger_store:append(Store, [E]),
            publish_feed(Slot, E, S),   %% LIVE commit ⇒ let the dissemination feed push it (never on replay/rebuild)
            S0 = ack_local(Slot, S#s{store = Store1, commits = S#s.commits + 1,
                                     last_ts = max(S#s.last_ts, BlockTs)}),
            S1 = adopt_committee(Data, finalize(Slot, S0)),
            maybe_mark_ready(apply_live(Slot, Data, S1))
    end.

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
              %% DEMOTION log-event (pairs with log_promotion's promotion notice): a member commit-signs its
              %% own removal as a voter, so it reaches here still a member and observes itself drop out.
              _ = case lists:member(Self, V) andalso not lists:member(Self, V1) of
                      true  -> logger:notice("quod[~s]: removed from the committee — now a read-only "
                                             "observer (committee ~b)", [S#s.ns, length(V1)]);
                      false -> ok
                  end,
              S1 = S#s{validators = V1},            %% FACTS advance
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
            {ok, Store1} = quod_ledger_store:append(Store, [E]),
            publish_feed(Slot, E, S),   %% a committed `noop` skip disseminates too, so followers stay contiguous
            S0 = nack_local(Slot, S#s{store = Store1, skips = S#s.skips + 1}),
            S1 = finalize(Slot, S0),
            S2 = S1#s{approved = max(S1#s.approved, Slot)},
            maybe_mark_ready(apply_live(Slot, noop, S2))
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
finalize(Slot, S) ->
    S#s{slot = Slot,
        eng = eng_prune(Slot, S#s.eng),   %% this slot is durable now — drop it from the in-flight pool
        active_slot   = case S#s.active_slot of Slot -> none; A -> A end,
        rounds = maps:remove(Slot, S#s.rounds),
        local_proposals = maps:remove(Slot, S#s.local_proposals),
        collecting = clear_collecting_le(Slot, S#s.collecting)}.

ack_local(Slot, S) -> reply_local(Slot, {ok, Slot}, S).
nack_local(Slot, S) -> reply_local(Slot, {error, skipped}, S).

reply_local(Slot, Reply, S = #s{local_proposals = Local}) ->
    case maps:take(Slot, Local) of
        {#local_proposal{waiters = Waiters}, Local1} ->
            _ = [gen_statem:reply(From, Reply) || From <- Waiters],
            S#s{local_proposals = Local1};
        error -> S
    end.

clear_collecting_le(Slot, #batch{slot = Sl}) when Sl =< Slot -> none;
clear_collecting_le(_Slot, Collecting) -> Collecting.

clear_active(Slot, S = #s{active_slot = Slot}) -> S#s{active_slot = none};
clear_active(_Slot, S) -> S.

round_state(Slot, #s{rounds = Rounds}) ->
    maps:get(Slot, Rounds, #round{}).

put_round(Slot, Round, S = #s{rounds = Rounds}) ->
    S#s{rounds = Rounds#{Slot => Round}}.

complained_slots(#s{rounds = Rounds}) ->
    [Sl || {Sl, #round{complaint = true}} <- maps:to_list(Rounds)].

committed_slots(#s{rounds = Rounds}) ->
    [Sl || {Sl, #round{commit = true}} <- maps:to_list(Rounds)].

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
        none -> {ok, Share} = own_share(support, Sl, BH, S),
                S1 = put_round(Sl, Round#round{supporting = BH}, S),
                engine_step([{share, Share}],
                            broadcast({share, Share}, S1));
        SupportedBH ->
            case BH of
                %% The SAME block again = the leader is REDRIVING the stuck slot — which means it is
                %% missing votes, possibly OURS (our frames to it were lost; the transport is send-once).
                %% Re-echo our own share(s) for it — deterministic Ed25519 re-signs to identical bytes —
                %% so a redrive heals both directions. Bounded by the leader's Δ (one echo per re-fire).
                SupportedBH -> {ok, Support} = own_share(support, Sl, BH, S),
                      Commit = case Round#round.commit of
                                   true  -> {ok, Sh} = own_share(commit, Sl, BH, S), [{share, Sh}];
                                   false -> []
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
dispatch(_Peer, _Other, S)                 -> S.

well_formed_block(#block{slot = Sl, parent = P, payload = Pl, timestamp = Ts}) ->
    is_slot(Sl) andalso is_slot(P) andalso is_slot(Ts)
        andalso well_formed_block_payload(Pl);
well_formed_block(_) -> false.

well_formed_block_payload([noop]) -> true;   %% persisted legacy explicit empty block
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

%% A leader's proposal: accept it only from the slot's actual leader and at the next APPROVED slot,
%% extending that approved parent. At most one uncommitted approved parent may be extended,
%% and the payload is a bounded, structurally valid transaction batch. This prevents future-slot flooding
%% and ensures commit_block only receives blocks whose full apply shape was checked before voting.
%% `valid_proposal` is checked FIRST (it pins `Sl =:= H+1 ≥ 1`) so `leader/2` is never evaluated on an
%% untrusted `Sl` — a crafted `slot=0` would otherwise make `leader(0,_)` do `lists:nth(0,_)` and crash us.
on_propose(Peer, #block{slot = Sl} = Block, S) ->
    BH = block_hash(Block),
    Valid = valid_proposal(Block, S) orelse known_proposal(Sl, BH, S),
    case Valid andalso leader(Sl, active_validators(S)) =:= Peer of
        %% Recovery may ingest the block and certificates as evidence, but only a ready voter starts local
        %% validation, timers, or signatures. The leader's redrive presents the proposal again after recovery.
        true  -> S1 = engine_step([{block, BH, Block}], S),
                 case may_vote(S1) of
                     true  -> support_or_validate(Block, BH, arm_complaint(Sl, S1));
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
                    complain_slot(Sl, S2);
                abstain      -> S1
            end;
        _ -> S
    end;
on_membership_verdict(_Sl, _BH, _Verdict, S) -> S.

%% The head+1 slot is now an ACTIVE view (a proposal seen, or a local write we couldn't lead): arm the
%% Δ complaint timer for it. Idempotent per slot (`A =/= V`) so repeat evidence never pushes the deadline
%% out; only ever `head+1`, so a single named timer suffices. An idle committee acquires no evidence, so
%% the timer is never armed — the client-driven model never skips a slot nobody wants.
arm_complaint(V, S = #s{approved = Approved, active_slot = A})
        when V =:= Approved + 1, A =/= V ->
    S#s{active_slot = V};
arm_complaint(_V, S) -> S.

%% Translate an `active_slot` transition into the gen_statem timer action for the named `complain` timer
%% (unchanged ⇒ leave it running; `none` ⇒ cancel; a slot ⇒ (re)arm for Δ). A named timeout is not
%% cancelled by unrelated events, so only the head-advancing / arming clauses touch it.
timer_actions(#s{active_slot = A}, #s{active_slot = A}) -> [];
timer_actions(_S0, #s{active_slot = none})             -> [{{timeout, complain}, cancel}];
timer_actions(_S0, #s{active_slot = V})                -> [{{timeout, complain}, delta_ms(), {complain, V}}].

delta_ms() ->
    case application:get_env(quod, simplex_delta_ms, ?DELTA_MS) of
        N when is_integer(N), N > 0 -> N;
        _                           -> ?DELTA_MS   %% a mistyped override must not crash the timer action
    end.

%% Δ fired for the stuck head V. The decision:
%%
%% - **A follower complains** (if it hasn't commit-signed V) — its own expired Δ IS the evidence of a
%%   stall, and its share is what seeds the `f+1` amplification below.
%% - **The LEADER of its own in-flight proposal REDRIVES instead of giving up.** Complaining would latch
%%   `complained[V]` and bar our own commit share forever — at the quorum=N committee sizes (2, 3) that
%%   wedges the slot PERMANENTLY (the promotion race: our proposal reached a member that had not yet
%%   promoted, was dropped, and nothing retransmits over the send-once transport). So each Δ re-fire
%%   re-broadcasts the in-flight state (proposal + our shares + pooled certs) — self-healing the moment
%%   the counterpart can act. The leader JOINS a complaint only on the `f+1` evidence (below) — and if it
%%   already commit-signed V (so it may never complain), it keeps REDRIVING: retransmitting the pooled
%%   support cert + its commit share is exactly what heals a follower whose copy was lost.
on_complain_timeout(V, S = #s{approved = Approved}) when V =:= Approved + 1 ->
    case leads_inflight(V, S) of
        false -> complain_slot(V, S);
        true  -> case complaint_evidence(V, S) andalso may_complain(V, committed_slots(S)) of
                     true  -> complain_slot(V, S);
                     false -> redrive_slot(V, S)
                 end
    end;
on_complain_timeout(_V, S) -> S.

%% **f+1 complaint amplification** (deferred.md §3, landed with growth): on ingesting a complaint share
%% for the in-flight head with `f+1` distinct PEER complaints pooled, JOIN the complaint immediately —
%% don't wait for our own Δ, which may never have armed (a member that never received the proposal holds
%% no evidence of its own). This is what completes a skip at the quorum=N sizes: the skip cert needs
%% EVERY member's share there, and a late-promoting member only learns of the stall from the re-broadcast
%% complaint shares — on arrival it joins, and the cert closes. `complain_slot`'s `may_complain` keeps the
%% commit/complaint mutual exclusion; `arm_complaint` puts the re-broadcast of our own share on our Δ.
maybe_join_complaint(#share{kind = complaint, slot = V}, S = #s{approved = Approved})
        when V =:= Approved + 1 ->
    case may_vote(S) andalso not (round_state(V, S))#round.complaint
         andalso complaint_evidence(V, S) of
        true  -> arm_complaint(V, complain_slot(V, S));
        false -> S
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

%% Pure threshold: at least `f+1` DISTINCT PEER signers (self excluded — our own share isn't independent
%% evidence). `f` is DERIVED from the quorum rule (`quorum = N − f`), never restated, so this can't drift
%% from the cert arithmetic. `Bucket` is a `signer => share` map, so distinctness is free.
complaint_amplified(Self, Validators, Bucket) ->
    N = length(Validators),
    map_size(maps:remove(Self, Bucket)) >= (N - quorum(N)) + 1.

%% Re-broadcast slot V's in-flight state: the local proposal block (pinned by its stored hash
%% and cleared in `finalize/2`), our own support/commit
%% shares (re-signed — Ed25519 is deterministic, so the bytes are identical to the originals), and any
%% pooled certs. The Δ re-fire IS the retransmit over the send-once transport. Idempotent at every
%% receiver: duplicate blocks/shares/certs are absorbed by the engine, and a duplicate proposal makes the
%% receiver RE-ECHO its own shares (see `support_block`) — healing the reverse direction too. Sent only
%% to peers with a LIVE conn: a peer we cannot reach yet has the original frames in its outbox already
%% (flushed on link_up); buffering per-Δ duplicates would only bloat it toward the ?MAX_OUTBOX cap.
redrive_slot(V, S) ->
    case may_vote(S) of
        true  -> redrive_slot_ready(V, S);
        false -> S
    end.

redrive_slot_ready(V, S0 = #s{local_proposals = Local}) ->
    case maps:get(V, Local, undefined) of
        undefined -> S0;
        #local_proposal{hash = BH} ->
            case block_for(BH, S0#s.eng) of
                #block{} = Block -> redrive_local_block(V, Block, BH, S0);
                _                -> S0
            end
    end.

redrive_local_block(V, Block, BH, S0) ->
    %% A membership proposal may still be waiting for its local KB verdict. Re-entering
    %% the common path re-requests only after an abstention; an outstanding request is
    %% idempotent. The proposal itself is always retransmitted, even before support.
    S1 = support_or_validate(Block, BH, S0),
    #s{self = Self, conns = Conns, eng = #eng{certs = Certs}} = S1,
    Round = round_state(V, S1),
    Own = case Round#round.supporting =:= BH of
              true ->
                  {ok, Support} = own_share(support, V, BH, S1),
                  Commit = case Round#round.commit of
                               true  -> {ok, Sh} = own_share(commit, V, BH, S1), [{share, Sh}];
                               false -> []
                           end,
                  [{share, Support} | Commit];
              false -> []
          end,
    Cs   = [{cert, C} || {{_K, Sl, _B}, C} <- maps:to_list(Certs), Sl =:= V],
    Live = [P || P <- active_validators(S1) -- [Self], maps:is_key(P, Conns)],
    S2   = S1#s{redrives = S1#s.redrives + 1},
    lists:foldl(fun(Msg, Acc) ->
                        Frame = encode(Acc#s.ns, Msg),
                        lists:foldl(fun(P, A) -> send_frame(P, Frame, A) end, Acc, Live)
                end, S2, [{propose, Block} | Own ++ Cs]).

%% Reliable channels are built from reconnecting send-once links. Re-emit this
%% validator's bounded in-flight evidence on the existing tick so notarization can
%% safely cancel the complaint timer without also cancelling commit liveness. This
%% covers the important case where the slot leader dies after a bare support quorum:
%% the remaining notarizers continue exchanging commit shares and finish the slot.
redrive_votes(S) ->
    case may_vote(S) of
        false -> S;
        true ->
            lists:foldl(
              fun({Sl, #round{supporting = BH, commit = Commit, complaint = Complaint}}, Acc0) ->
                      Evidence0 = case BH of
                                      none -> [];
                                      _    -> {ok, Support} = own_share(support, Sl, BH, Acc0),
                                              [{share, Support}]
                                  end,
                      Evidence1 = case Commit andalso BH =/= none of
                                      true  -> {ok, CommitShare} = own_share(commit, Sl, BH, Acc0),
                                               [{share, CommitShare} | Evidence0];
                                      false -> Evidence0
                                  end,
                      Evidence = case Complaint of
                                     true  -> {ok, ComplaintShare} = own_share(complaint, Sl, none, Acc0),
                                              [{share, ComplaintShare} | Evidence1];
                                     false -> Evidence1
                                 end,
                      lists:foldl(fun broadcast/2, Acc0, Evidence)
              end, S, [{Sl, R} || {Sl, R} <- maps:to_list(S#s.rounds), Sl > S#s.slot])
    end.

%% Sign + (re)broadcast our complaint share and offer it to the engine, unless we commit-signed V.
complain_slot(V, S) ->
    case may_vote(S) andalso may_complain(V, committed_slots(S)) of
        false -> S;
        true  -> {ok, Share} = own_share(complaint, V, none, S),
                 %% latch complained[V] BEFORE offering the share: if our own complaint completes the ⅔
                 %% cert, engine_step skips V and finalize/2 clears the latch — so the pre-set doesn't
                 %% leak; and any {notarized,V} inside that same engine_step now sees complained[V] and
                 %% is barred from a commit share (the mutual-exclusion safety half, self-enforced here).
                 Round = round_state(V, S),
                 S1 = put_round(V, Round#round{complaint = true}, S),
                 engine_step([{share, Share}], broadcast({share, Share}, S1))
    end.

%% The sole constructor for runtime consensus evidence. Tests and certificate verification use
%% `make_share/4` directly; the state machine must come through this capability boundary.
own_share(Kind, Slot, BlockHash, #s{id = Id} = S) ->
    case may_vote(S) of
        true  -> {ok, make_share(Kind, Slot, BlockHash, Id)};
        false -> blocked
    end.

valid_proposal(#block{slot = Sl, parent = P, payload = Payload, timestamp = Ts},
               #s{slot = Committed, approved = Approved} = S) ->
    Sl =:= Approved + 1
        andalso P =:= Approved
        andalso Approved =< Committed + ?PIPELINE_DEPTH
        andalso not membership_barrier(S)
        andalso ts_acceptable(Ts, parent_timestamp(P, S), quod_time:now_ms())
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
%% `quod_prolog:request_membership_verdict/5`). Committed history stays cert-trusted (catch-up folds it
%% unconditionally, by design).
%% The whole transaction is checked before voting: identifiers and timestamps have their canonical
%% shapes, the OCC read-set is a map of predicate hashes, and every diff element is a legal
%% assert/retract over an Erlog clause. This makes apply/restart a total operation over every block an
%% honest validator can endorse. The recursive diff check also rejects an improper list such as
%% `[Op | junk]`, which a shallow cons-cell match would otherwise admit from the untrusted wire.
acceptable_change(Change, #s{validators = Vs}) -> change_acceptable(Change, Vs).

acceptable_payload([#transaction{} | _] = Payload, S) ->
    proper_transaction_list(Payload)
        andalso length(Payload) =< ?MAX_BATCH_TXS
        andalso byte_size(term_to_binary(Payload, [deterministic])) =< ?MAX_BLOCK_BYTES
        andalso lists:all(fun(Change) -> acceptable_change(Change, S) end, Payload)
        andalso unique_tx_ids(Payload)
        andalso membership_payload_ok(Payload, S);
acceptable_payload(_Payload, _S) -> false.

proper_transaction_list([#transaction{} | Rest]) -> proper_transaction_list(Rest);
proper_transaction_list([]) -> true;
proper_transaction_list(_) -> false.

unique_tx_ids(Payload) ->
    Ids = [Id || #transaction{tx_id = Id} <- Payload],
    length(Ids) =:= length(lists:usort(Ids)).

membership_payload_ok(Payload, #s{approved = Approved, slot = Committed}) ->
    Membership = [T || T <- Payload, is_membership_change(T)],
    case Membership of
        []  -> true;
        [_] -> length(Payload) =:= 1 andalso Approved =:= Committed;
        _   -> false
    end.

payload_touches_committee(Payload) ->
    lists:any(fun is_membership_change/1, Payload).

is_membership_change(Change) -> committee_delta(Change) =/= {[], []}.

%% The pure acceptance decision over a validator LIST (exported for eunit; the `#s`-wrapper above is
%% what the propose/support call sites use).
change_acceptable(#transaction{tx_id = TxId, caller_ns = CallerNs, diff = Diff,
                               read_check = ReadCheck, author = Author,
                               submitted_at = SubmittedAt, sig = Sig} = T, Vs) ->
    well_formed_transaction_fields(TxId, CallerNs, Diff, ReadCheck, Author, SubmittedAt, Sig)
        andalso (not touches_committee(Diff) orelse membership_change_ok(T, Vs));
change_acceptable(_, _)      -> false.

-spec well_formed_transaction(term()) -> boolean().
well_formed_transaction(#transaction{tx_id = TxId, caller_ns = CallerNs, diff = Diff,
                                     read_check = ReadCheck, author = Author,
                                     submitted_at = SubmittedAt, sig = Sig}) ->
    well_formed_transaction_fields(TxId, CallerNs, Diff, ReadCheck, Author, SubmittedAt, Sig);
well_formed_transaction(_) -> false.

well_formed_transaction_fields(TxId, CallerNs, Diff, ReadCheck, Author, SubmittedAt, Sig) ->
    nonempty_binary(TxId)
        andalso nonempty_binary(CallerNs)
        andalso nonempty_binary(Author)
        andalso is_integer(SubmittedAt) andalso SubmittedAt >= 0
        andalso (Sig =:= none orelse is_binary(Sig))
        andalso valid_read_check(ReadCheck)
        andalso valid_diff(Diff).

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

encode(Ns, Msg) ->
    Inner = term_to_binary(Msg, [deterministic]),
    term_to_binary({sx, Ns, Inner}, [deterministic]).

%% The envelope is `[safe]` (known atoms only); the inner message carries `#transaction` diffs whose
%% Prolog atoms the receiver may not have seen yet, so it decodes WITHOUT `[safe]` — the same
%% trusted-committee posture as the removed Raft transport (bounded by the committee link scope;
%% doc/deferred.md §2). Returns `error` on anything malformed or for another namespace.
decode(Payload, Ns) ->
    try binary_to_term(Payload, [safe]) of
        {sx, Ns, Inner} -> try binary_to_term(Inner) catch _:_ -> error end;
        _               -> error
    catch _:_ -> error end.

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
        false -> S1  = drop_conn_by_peer(Peer, S),         %% demonitor + drop any dead stored conn
                 Ref = erlang:monitor(process, LinkPid),
                 _   = [quod_link:send(LinkPid, F) || F <- lists:reverse(maps:get(Peer, Outbox, []))],
                 S1#s{conns = (S1#s.conns)#{Peer => {LinkPid, Ref}}, outbox = maps:remove(Peer, Outbox)}
    end.

%% A tracked outbound link died (DOWN): drop it (a later send / the tick re-dials + re-buffers).
drop_conn(Pid, S = #s{conns = Conns}) ->
    case [{P, R} || {P, {LP, R}} <- maps:to_list(Conns), LP =:= Pid] of
        [{Peer, Ref} | _] -> _ = erlang:demonitor(Ref, [flush]), S#s{conns = maps:remove(Peer, Conns)};
        []                -> S
    end.

drop_conn_by_peer(Peer, S = #s{conns = Conns}) ->
    case maps:get(Peer, Conns, undefined) of
        {_Pid, Ref} -> _ = erlang:demonitor(Ref, [flush]), S#s{conns = maps:remove(Peer, Conns)};
        undefined   -> S
    end.

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
        _         -> _ = safe_apply_block(Ns, Slot, Change),   %% async cast (breaks the append<->apply deadlock)
                     S#s{last_applied = Slot}
    end;
apply_live(_Slot, _Change, S) -> S.

%% Apply committed-but-unapplied blocks into quod_prolog, in slot order — STREAMED from the store
%% (the rebuild path; this process keeps no in-memory log, and re-applying already-counted commits
%% must not recount them). Deferred if quod_prolog is not up yet; the registry lookup is done ONCE
%% here, not per block. apply_block is a cast by design (see quod_prolog:apply_block/3 — a sync call
%% would deadlock the live write path), so a long replay would flood quod_prolog's mailbox with the
%% whole log; every ?APPLY_SYNC_EVERY casts a synchronous no-op (`quod_prolog:sync/1`) drains the
%% queue — its reply proves every prior cast was consumed, bounding the mailbox to one window.
%% The barrier is deadlock-safe: apply_committed only runs while the KB is NOT ready
%% (rebuild/catch-up), and an unready quod_prolog rejects proves, so it can never be parked in an
%% `append` back into this statem. If quod_prolog dies mid-replay, the barrier exits `noproc`:
%% stop replaying with last_applied unchanged — its restart casts `rebuild` and re-drives the gap.
apply_committed(S = #s{last_applied = LA, slot = C}) when LA >= C -> S;
apply_committed(S = #s{ns = Ns, store = Store, last_applied = LA, slot = C}) ->
    case quod_reg:where({quod_prolog, Ns}) of
        undefined -> S;
        _ ->
            try
                _ = quod_ledger_store:fold(Store, LA + 1, C,
                                           fun(#entry{index = I, data = Data}, N) ->
                                               _ = safe_apply_block(Ns, I, Data),
                                               N rem ?APPLY_SYNC_EVERY =:= 0
                                                   andalso (ok = quod_prolog:sync(Ns)),
                                               N + 1
                                           end, 1),
                S#s{last_applied = C}
            catch exit:{noproc, _} -> S   %% quod_prolog died mid-replay; its rebuild re-drives
            end
    end.

safe_apply_block(Ns, I, Data) ->
    try quod_prolog:apply_block(Ns, I, Data) catch _:_ -> ok end.

%% Tell quod_prolog its kb is rebuilt and it may serve proves — but only ONCE the committed prefix is
%% actually applied AND recovery is `ready`, so a node never answers from a half-built or uncorroborated
%% kb. A joiner/resuming member must NOT mark ready mid-sync: its height only reflects the windows sunk so
%% far. `prolog_ready` is monotone: a later-behind node keeps serving its
%% (stale-but-valid) reads while it gap-fills — it never drops back to unready.
maybe_mark_ready(S = #s{ns = Ns, prolog_ready = false, sync = ready}) ->
    case (quod_reg:where({quod_prolog, Ns}) =/= undefined) andalso (S#s.last_applied >= S#s.slot) of
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

%% True iff a finalizer cert proves the committed head is past our next slot (`slot+1`) — i.e. we have fallen
%% behind the in-flight window and must gap-fill. Recomputed on demand (never a stored latch), so it is
%% self-correcting: as a pull raises `slot`/`base`, `eng_prune` drops those certs and the ceiling falls.
-spec behind(#s{}) -> boolean().
behind(#s{eng = Eng, approved = Approved}) -> ahead_cert_ceiling(Eng) > Approved + 1.

%% Facts-only participation: a member of the ACTIVE voting set. A recovering member still ingests verified
%% traffic so its gap detector can learn, but participation alone grants no signing capability.
is_participant(#s{self = Self} = S) -> lists:member(Self, active_validators(S)).

%% `ready` is the only recovery state with a corroborated tip. A live finalizer above the local window
%% revokes the capability immediately, before the paced recovery worker starts.
caught_up(#s{sync = ready} = S) -> not behind(S);
caught_up(_S) -> false.

%% Voting and leading share one capability boundary. Leadership remains a named predicate because callers
%% express intent, but neither can drift from the recovery policy.
may_vote(S) -> is_participant(S) andalso caught_up(S).
may_lead(S) -> may_vote(S).

%% An unconfirmed node always recovers. A ready member recovers when a verified finalizer proves a gap.
should_sync(#s{sync = unconfirmed}) -> true;
should_sync(#s{sync = ready} = S) -> behind(S).

%% The feed follows only in the sole settled state, so its puller and recovery can never own ingestion at
%% the same time.
syncing(#s{sync = Sy}) -> Sy =/= ready.

%% Catch-up ingestion is capability-based: one monitored recovery worker, or the feed while this node is a
%% ready observer. There is no state in which both sources are authorized.
may_sink({recovery, Pid}, #s{sync = {pulling, Pid}}) -> true;
may_sink(feed, #s{sync = ready} = S) -> not is_participant(S);
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
    recover_tip(Ns, GH, Statem, Self, Sink, ?RECOVERY_FETCHES, false).

recover_tip(Ns, GH, Statem, Self, Sink, FetchesLeft, FallbackUsed) ->
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
                    Failure = {tip_unconfirmed, Height, length(lists:usort(Exact))},
                    continue_recovery(Ns, GH, Statem, Self, Sink, FetchesLeft,
                                      FallbackUsed, ahead_contacts(Probes), Exact, Failure)
            end;
        {ok, _From, _Committee} ->
            continue_recovery(Ns, GH, Statem, Self, Sink, FetchesLeft,
                              FallbackUsed, [], [], empty_namespace);
        {error, R} -> {error, {status, R}}
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
                    recover_tip(Ns, GH, Statem, Self, Sink, FetchesLeft - 1, FallbackUsed1);
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
    quod_catchup:catch_up(GH, Fetch, Sink, From, Committee).

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
%% and replay it into quod_prolog in slot order (`apply_committed` — the same path a restart-rebuild uses).
%% An APPEND error aborts the window cleanly (returns `{error, _}` ⇒ the driver fails over); nothing is
%% acked half-applied. The try covers ONLY the append: once the window is durable, reverting to the
%% pre-append state on a later throw would hand the retry a STALE handle whose re-append splices over
%% live bytes — so a post-append failure (a store read-back error in the replay) crashes the statem
%% instead, and the restart re-derives from the disk log, appended window included (fail-loud, no splice).
%% Both projections (validator set, KB) advance together from the one appended log.
apply_catchup_window([], S) -> {S, ok};
apply_catchup_window(Es0, S = #s{store = Store, validators = Vs}) ->
    %% Idempotency: the live engine may have committed a prefix of this window while the pull worker was
    %% fetching it (a VOTING member gap-fills while still ingesting live consensus). Drop the already-present
    %% prefix so the append stays contiguous instead of failing `assert_contiguous`.
    case drop_index_le(quod_ledger_store:last(Store), Es0) of
        []  -> {S, ok};   %% window entirely already-present — nothing new to sink
        Es  ->
    case try quod_ledger_store:append(Store, Es) catch _:R -> {error, R} end of
        {error, _} = Err -> {S, Err};
        {ok, Store1} ->
            {Vs1, Ts1} = log_projection(Es, {Vs, S#s.last_ts}),   %% committee + monotonic bound live in one pass
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
            %% the stale head); for a joiner/observer the resets are no-ops. `log_promotion` keeps the S5b
            %% false->true notice now that the re-seat no longer rides `maybe_promote`. The caller
            %% (`sink_catchup`) pairs this with `timer_actions/2` so a cleared `active_slot` cancels the timer.
            S1 = reseat_engine(Slot, S#s{store = Store1, validators = Vs1, slot = Slot, last_ts = Ts1}),
            S2 = catchup_membership_transition(S, S1),
            {maybe_mark_ready(apply_committed(S2)), ok}
    end
    end.

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
%% retries. Called UNCONDITIONALLY from every catch-up window (`apply_catchup_window`), collapsing the former
%% split re-arm (a per-catch-up-completion re-arm + a `maybe_promote` conditional re-arm, both `eng_new/2`). At
%% a joiner/observer site the latch resets are no-ops (no live-slot state); they are load-bearing for a VOTING
%% member gap-filling — the caller (`sink_catchup`) pairs this with `timer_actions/2` to cancel a stale
%% complain timer when `active_slot` is cleared here (a no-op where `active_slot` is already `none`).
reseat_engine(NewHead, S) ->
    S1 = nack_inflight(S),
    S1#s{eng             = eng_new(active_validators(S1), NewHead),
          approved        = NewHead,
          commit_buf      = #{},
          active_slot     = none,
          rounds          = #{}}.

%% A recovery re-seat intentionally discards the whole volatile consensus window.
%% Its fresh engine cannot safely retain proposals or votes from the old base.
nack_inflight(S0 = #s{local_proposals = Local}) ->
    S1 = lists:foldl(fun nack_local/2, S0, maps:keys(Local)),
    case S1#s.collecting of
        #batch{items_rev = Items} ->
            _ = [gen_statem:reply(From, {error, skipped}) || {From, _} <- Items],
            S1#s{collecting = none};
        _ -> S1
    end.

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
-spec log_projection([#entry{}], {[node_id()], non_neg_integer()}) -> {[node_id()], non_neg_integer()}.
log_projection(Entries, Seed) ->
    lists:foldl(fun log_projection_step/2, Seed, Entries).

log_projection_step(#entry{data = Data, timestamp = T}, {V, Ts}) ->
    {apply_committee_delta(Data, V), max(T, Ts)}.

%% The committee change carried by one committed payload: the `peer_admitted` pubkeys it asserts (added)
%% and retracts (removed). Each transaction folds its diff (the validator id is the 4th arg / 5th element
%% of `peer_admitted(NodeId, Host, Port, Pubkey)`); a `noop` or malformed payload changes nothing. This ONE
%% function feeds BOTH the live commit-time swap (`adopt_committee/2`) and the boot/restart re-fold
%% (`log_projection/2`), so the running set can never drift from a fresh re-fold.
committee_delta(Change) ->
    case quod_ledger:payload(Change) of
        {ok, Transactions} -> lists:foldl(fun committee_transaction/2, {[], []}, Transactions);
        error              -> {[], []}
    end.

committee_transaction(#transaction{diff = Diff}, Acc) ->
    case proper_list(Diff) of
        true  -> lists:foldl(fun committee_op/2, Acc, Diff);
        false -> Acc
    end;
committee_transaction(noop, Acc) -> Acc.

committee_op({assert,  {{peer_admitted, _Id, _H, _P, Pk}, _B}}, {A, R}) -> {addq(Pk, A), R -- [Pk]};
committee_op({retract, {{peer_admitted, _Id, _H, _P, Pk}, _B}}, {A, R}) -> {A -- [Pk], addq(Pk, R)};
committee_op(_Op, Acc)                                                  -> Acc.

%% The dial hints carried by one committed payload: each `peer_admitted` ASSERT's `{Pk, {Host, Port}}`.
%% Kept separate from the pure pubkey-set fold consumed by catch-up induction and live membership.
%% Retracts yield nothing: a removal is a membership change, not a reachability change (no unlearn — a
%% removed member stays a gossiped-with observer). The `_ -> []` clause is REQUIRED, not defensive: a
%% catch-up window routinely carries `noop` skip entries, and this walks raw window payloads.
admitted_endpoints(Change) ->
    case quod_ledger:payload(Change) of
        {ok, Transactions} -> lists:flatmap(fun transaction_endpoints/1, Transactions);
        error              -> []
    end.

transaction_endpoints(#transaction{diff = Diff}) ->
    case proper_list(Diff) of
        true  -> [{Pk, {H, P}} || {assert, {{peer_admitted, _Id, H, P, Pk}, _B}} <- Diff];
        false -> []
    end;
transaction_endpoints(noop) -> [].

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

data_dir(Cfg) ->
    case maps:get(data_dir, Cfg) of
        undefined -> filename:join(filename:basedir(user_cache, "quod"), "data");
        Dir       -> Dir
    end.

genesis_file(Cfg) ->
    case maps:get(genesis_file, Cfg, undefined) of
        undefined -> none;
        <<>>      -> none;
        ""        -> none;
        File      -> File
    end.

status_map(S) ->
    Role = case is_participant(S) of true -> validator; false -> observer end,
    #{role => Role, committee => S#s.validators, slot => S#s.slot,
      committed => S#s.slot, approved => S#s.approved, last_applied => S#s.last_applied,
      syncing => syncing(S), recovery => recovery_phase(S#s.sync)}.

recovery_phase({pulling, _}) -> pulling;
recovery_phase(Phase) -> Phase.

stats_map(S) ->
    #{slot => S#s.slot, committed => S#s.slot, approved => S#s.approved,
      pipeline_gap => max(0, S#s.approved - S#s.slot), last_applied => S#s.last_applied,
      committee_size => length(S#s.validators), appends => S#s.appends,
      proposals => S#s.proposals, batched_txs => S#s.batched_txs,
      commits => S#s.commits, prolog_ready => S#s.prolog_ready,
      submitted => S#s.submitted, skips => S#s.skips, pending => pending_count(S),
      r_busy => S#s.r_busy, r_redirect => S#s.r_redirect, r_bad => S#s.r_bad,
      membership_rejects => S#s.membership_rejects, redrives => S#s.redrives,
      weak_cert_waits => S#s.weak_cert_waits,
      ahead_gap => max(0, ahead_cert_ceiling(S#s.eng) - S#s.slot),
      syncing => case syncing(S) of true -> 1; false -> 0 end,
      is_validator => case is_participant(S) of true -> 1; false -> 0 end}.

pending_count(#s{collecting = Collecting, local_proposals = Local}) ->
    CollectingN = case Collecting of #batch{items_rev = Items} -> length(Items); none -> 0 end,
    CollectingN + lists:sum([length(P#local_proposal.waiters) || P <- maps:values(Local)]).
