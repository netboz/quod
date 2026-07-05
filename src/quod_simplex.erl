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

> #### Status {: .info }
>
> **Stage 2c (here):** the pure consensus core (quorum math, share signing, certificate
> formation/verification, the commit guards), the **consensus engine** (§2.3 certificate pool + complete
> block tree), the per-namespace `gen_statem` over the `{log, Ns}` transport, and **failover** — a
> **round-robin per-slot leader**, the `Δ_timeout` **complaint timer**, the `may_commit`/`may_complain`
> guards, and a `⅔` **complaint cert** that skips a stuck slot (a `noop` entry) so the rotated leader
> proposes the next. At **N=1** each quorum self-satisfies, so an append commits synchronously. **Next:**
> epoch validators + membership/join from `peer_admitted` (Stage 3), stable per-epoch leaders (Stage 4),
> and per-message retransmit hardening (a dial-retry tick is in; see `doc/deferred.md` §3).
""".

-include("quod_ledger.hrl").

-behaviour(gen_statem).

%% Pure consensus core (also used by the gen_statem below, the catch-up verifier, and the tests).
-export([quorum/1, leader/2,
         block_hash/1, share_bytes/3,
         make_share/4, verify_share/1,
         form_cert/5, verify_cert/2,
         may_commit/2, may_complain/2, well_formed_cert/1,
         committee_delta/1, apply_committee_delta/2]).   %% committee = projection of peer_admitted facts

%% Per-namespace consensus process — API + gen_statem callbacks.
-export([start_link/2, append/2, rebuild/1, status/1, committee/1, genesis_hash/1, stats/1, namespaces/0]).
-export([init/1, callback_mode/0, running/3, terminate/3]).

-ifdef(TEST).
%% consensus-engine surface driven by eunit (the #eng record is otherwise private)
-export([eng_new/2, eng_offer/2, eng_prune/2, eng_tree/1, eng_committed/1]).
-endif.

%% These validate records decoded from UNTRUSTED peer input (binary_to_term yields any term, so a
%% #share{} off the wire can carry a non-integer slot etc.); dialyzer trusts the declared field types
%% and so thinks the false/reject branches are dead — they are not, at runtime.
-dialyzer({nowarn_function, [dispatch/3, well_formed_block/1, well_formed_share/1, well_formed_cert/1]}).

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
share_bytes(Kind, Slot, BlockHash) ->
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
    valid_shape(K, BH)
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
    case valid_shape(Kind, BlockHash) of
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
verify_cert(#cert{sigs = Sigs}, Validators)
  when Validators =:= []; length(Sigs) > length(Validators) ->
    false;
verify_cert(#cert{kind = K, slot = Sl, block_hash = BH, sigs = Sigs}, Validators) ->
    valid_shape(K, BH)
        andalso length(distinct_valid(Sigs, share_bytes(K, Sl, BH), Validators))
                >= quorum(length(Validators)).

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
              committed = #{} :: #{slot() => #block{}},                %% committed (final) in-flight blocks
              skipped  = #{} :: #{slot() => true}}).                   %% slots a complaint cert has skipped

-type share_key() :: {support | commit | complaint, slot(), binary() | none}.
-type eng_event() :: {broadcast, #cert{}} | {notarized, #block{}}
                   | {committed, slot(), #block{}} | {skipped, slot()}.

-doc """
A fresh engine for a validator set (the epoch-frozen committee), with `Base` = the durable committed
floor (the last slot already final in the store). Blocks `=< Base` are treated as committed history so a
new proposal's parent resolves without the engine holding the whole chain.
""".
-spec eng_new([node_id()], slot()) -> #eng{}.
eng_new(Validators, Base) ->
    #eng{validators = Validators, base = Base}.

%% Swap the engine's validator set when a committed transaction changes the committee (`adopt_committee/2`).
%% Safe at the slot boundary: the just-committed slot is already pruned (`base` raised), so no in-flight
%% share/cert is re-verified under the new set; the next slot's shares/certs verify against it.
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
            Min = distinct_valid(S, share_bytes(Kind, Slot, BH), Vs),
            case length(Min) >= quorum(length(Vs)) of
                true  -> #cert{kind = Kind, slot = Slot, block_hash = BH, sigs = Min};
                false -> none
            end
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
    settle(Eng#eng{blocks = (Eng#eng.blocks)#{block_hash(B) => B}});
eng_offer({share, #share{signer = Signer} = Sh}, Eng) ->
    case verify_share(Sh) andalso lists:member(Signer, Eng#eng.validators) of
        false -> {Eng, []};                       %% junk / outsider: ignore
        true  -> ingest_share(Sh, Eng)
    end;
eng_offer({cert, #cert{} = C}, Eng) ->
    Key = cert_key(C),
    case (not maps:is_key(Key, Eng#eng.certs)) andalso verify_cert(C, Eng#eng.validators) of
        false -> settle(Eng);                     %% already have it, or invalid
        true  -> {Eng1, Evs} = settle(Eng#eng{certs = (Eng#eng.certs)#{Key => C}}),
                 {Eng1, [{broadcast, C} | Evs]}   %% relay a newly-learned cert once (§2.3.1)
    end.

%% Add a verified share to its (kind, slot, block) bucket; if that reaches the `⅔` quorum for the first
%% time, form the cert and re-disseminate it, then settle the tree/commits.
ingest_share(#share{kind = K, slot = Sl, block_hash = BH, signer = Signer} = Sh, Eng) ->
    Key    = {K, Sl, BH},
    Bucket = maps:get(Key, Eng#eng.shares, #{}),
    Eng1   = Eng#eng{shares = (Eng#eng.shares)#{Key => Bucket#{Signer => Sh}}},
    case maps:is_key(Key, Eng1#eng.certs) of
        true  -> settle(Eng1);                    %% cert already formed for this key
        false ->
            Shares = maps:values(maps:get(Key, Eng1#eng.shares)),
            case form_cert(K, Sl, BH, Shares, Eng1#eng.validators) of
                {ok, Cert}            -> {Eng2, Evs} = settle(Eng1#eng{certs = (Eng1#eng.certs)#{Key => Cert}}),
                                         {Eng2, [{broadcast, Cert} | Evs]};
                {error, insufficient} -> {Eng1, []}
            end
    end.

cert_key(#cert{kind = K, slot = Sl, block_hash = BH}) -> {K, Sl, BH}.

%% Recompute the tree then the commits to a fixpoint — a newly-notarized block can enable its child's
%% notarization — returning the newly-notarized + newly-committed events in order.
settle(Eng) -> settle(Eng, []).
settle(Eng, Acc) ->
    case grow_tree(Eng) of
        {Eng1, [_ | _] = New} -> settle(Eng1, Acc ++ New);
        {Eng1, []}            -> {Eng2, Commits} = detect_commits(Eng1),
                                 {Eng3, Skips}   = detect_complaints(Eng2),
                                 {Eng3, Acc ++ Commits ++ Skips}
    end.

%% Add every block that now has a support cert AND whose parent is in the tree (or is genesis) AND
%% whose payload we hold — one pass (settle/2 loops it to a fixpoint).
grow_tree(Eng = #eng{certs = Certs, tree = Tree}) ->
    Ready = lists:filtermap(
              fun({{support, Sl, BH}, _Cert}) ->
                      case (not maps:is_key(Sl, Tree)) andalso block_for(BH, Eng) of
                          #block{} = B -> case parent_ok(B, Eng) of true -> {true, B}; false -> false end;
                          _            -> false
                      end;
                 (_) -> false
              end, maps:to_list(Certs)),
    case lists:keysort(#block.slot, Ready) of   %% slot-ascending, so parents are handed over before children
        [] -> {Eng, []};
        Sorted -> Tree1 = lists:foldl(fun(B, T) -> T#{B#block.slot => B} end, Tree, Sorted),
                  {Eng#eng{tree = Tree1}, [{notarized, B} || B <- Sorted]}
    end.

%% A block is committed once it is in the tree AND the pool has a commit cert for it (block-bound:
%% the commit cert names this block, so the proof is self-contained). Emitted in slot order so the
%% driver's contiguous store append never sees a gap within a single settle.
detect_commits(Eng = #eng{certs = Certs, tree = Tree, committed = Committed}) ->
    New = lists:sort(lists:filtermap(
            fun({{commit, Sl, BH}, _Cert}) ->
                    case (not maps:is_key(Sl, Committed)) andalso maps:get(Sl, Tree, undefined) of
                        #block{} = B -> case block_hash(B) =:= BH of true -> {true, {Sl, B}}; false -> false end;
                        _            -> false
                    end;
               (_) -> false
            end, maps:to_list(Certs))),
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
-spec eng_prune(slot(), #eng{}) -> #eng{}.
eng_prune(Committed, Eng = #eng{base = Base}) ->
    Above = fun(Sl) -> Sl > Committed end,
    Eng#eng{base      = max(Committed, Base),
            blocks    = maps:filter(fun(_BH, #block{slot = Sl}) -> Above(Sl) end, Eng#eng.blocks),
            shares    = maps:filter(fun({_K, Sl, _BH}, _) -> Above(Sl) end, Eng#eng.shares),
            certs     = maps:filter(fun({_K, Sl, _BH}, _) -> Above(Sl) end, Eng#eng.certs),
            tree      = maps:filter(fun(Sl, _) -> Above(Sl) end, Eng#eng.tree),
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
%% Stage 2a (here): the engine drives commit for N=1 (unified path). The `{log, Ns}` transport for a
%% multi-node committee, the complaint timer, and epoch validators are the following sub-increments.

-define(DEFAULTS,
        #{node_id      => undefined,   %% our pubkey == node_id; REQUIRED
          mode         => create,      %% create = found genesis; join = trustlessly catch up from a contact
          committee    => [],          %% co-founders; `[]` = self-only (N=1), a list = a multi-validator committee
          genesis_file => undefined,   %% root .pl to seed on create (founder only)
          genesis_hash => undefined,   %% join only: the out-of-band-pinned slot-1 block_hash (the trust anchor)
          data_dir     => undefined}).

-define(MAX_OUTBOX, 1024).   %% per-peer cap on frames buffered while a link opens (bounds memory vs a dead peer)
-define(TICK_MS,     300).   %% consensus re-drive cadence: re-dial peers whose link never came up (liveness)
-define(DELTA_MS,   1000).   %% Δ_timeout: a proposed-but-stuck head slot is complained (skipped) after this;
                             %% must exceed real commit latency (override via app-env `simplex_delta_ms`)
-define(JOIN_KICK_MS, 500).  %% mode=join: delay before (re)trying catch-up, so the catchup sibling is up first
-define(JOIN_WINDOW,  256).  %% mode=join: entries requested per catch-up fetch (matches the server's block cap)
-define(SINK_MS,     30000). %% mode=join: budget for one sink window (store append + KB replay) — generous

-record(s, {ns           :: binary(),
            self         :: node_id(),               %% our pubkey == node_id
            id           :: signer() | undefined,    %% signing identity (pubkey + private key)
            store        :: quod_ledger_store:handle() | undefined,
            eng          :: #eng{} | undefined,      %% the consensus engine (certificate pool + block tree)
            chan         :: binary() | undefined,    %% term_to_binary({log, Ns}) — the transport channel
            validators   = [] :: [node_id()],        %% the voting committee — sorted `peer_admitted` pubkeys,
                                                     %% derived from the committed log (a projection, in-process)
            slot         = 0  :: slot(),             %% height: index of the last COMMITTED block (commits are
                                                     %% strictly in order, so this is also the committed floor)
            last_applied = 0  :: slot(),             %% highest slot handed to quod_prolog
            pending    = #{} :: #{slot() => gen_statem:from()},  %% appends parked until commit (leader)
            proposing  = none :: none | slot(),      %% the leader's in-flight proposed slot (one at a time)
            supported  = #{} :: #{slot() => binary()},  %% slot => block_hash we support-signed (no double-sign)
            commit_signed = #{} :: #{slot() => true},    %% slots we commit-signed (⇒ may_complain false: safety)
            complained    = #{} :: #{slot() => true},    %% slots we complaint-signed (⇒ may_commit false: safety)
            active_slot   = none :: none | slot(),       %% the head+1 slot the Δ complaint timer is armed for
            commit_buf = #{} :: #{slot() => {commit, #block{}} | skip},  %% out-of-order finalizations, drained in order
            conns      = #{} :: #{node_id() => {pid(), reference()}},  %% our OUTBOUND links to peers
            outbox     = #{} :: #{node_id() => [binary()]},            %% frames buffered while a link opens
            dialing    = #{} :: #{node_id() => true},                  %% peers with an open_link dial in flight
            prolog_ready = false :: boolean(),
            join         = none :: none | pending | {worker, pid()} | done,  %% mode=join catch-up lifecycle
            genesis_hash = undefined :: binary() | undefined,  %% join trust anchor: the pinned slot-1 block_hash
            appends = 0  :: non_neg_integer(),
            commits = 0  :: non_neg_integer()}).

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
            Eng = eng_new(S1#s.validators, Committed),
            {ok, running, S1#s{last_applied = 0, eng = Eng}, [tick_timeout() | join_actions(S1)]}
    catch
        throw:{genesis_failed, _} = Reason -> {stop, Reason}
    end.

%% A fresh `mode=join` node boots UNFOUNDED and must drive catch-up — arm the join kick (deferred so the
%% catchup sibling, later in the rest_for_one chain, is up first). Every other boot participates immediately.
join_actions(#s{join = pending}) -> [join_timeout()];
join_actions(_)                  -> [].

join_timeout() -> {{timeout, join}, ?JOIN_KICK_MS, start_join}.

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
%% out of the committed log's transaction diffs (`committee_from_log/1`), and take the last index. The
%% blocks themselves are NOT kept in RAM — the store is the archive, quod_prolog holds the KB projection;
%% this consensus process holds only the validator-set projection. A brand-new namespace is bootstrapped.
%% Re-folding the committee from the log is the accepted cost of running without a committee checkpoint;
%% `last/1` gives the height in O(1). Both projections derive from the same committed log, so they can't drift.
%% Derive the durable state, then decide by mode. A `join` node ALWAYS (re)enters catch-up — from slot 0 when
%% fresh (unfounded, anchored at genesis) OR RESUMING from a partial prefix left by a crash/restart (`start_join_worker`
%% resumes at `slot+1`, so a retry never re-appends what is already on disk, and a partial log is never mistaken for
%% complete — `maybe_mark_ready` stays gated until `join=done`). A fresh `create` node founds genesis; a restarted
%% `create` node (or an admitted member) just re-derives. Both projections come from the one committed log.
load_or_bootstrap(S0 = #s{store = Store}, Cfg) ->
    Base = case maps:get(log, quod_ledger_store:load(Store)) of
               []  -> S0;   %% empty ⇒ unfounded (slot 0)
               Log -> {LastI, _} = quod_ledger_store:last(Store),
                      S0#s{validators = committee_from_log(Log), slot = LastI}
           end,
    case {maps:get(mode, Cfg), Base#s.slot} of
        {join,   _} -> Base#s{join = pending, genesis_hash = maps:get(genesis_hash, Cfg)};
        {create, 0} -> bootstrap(Cfg, Base);   %% fresh founder
        {create, _} -> Base                    %% restarted founder / admitted member
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
    E = #entry{index = 1, term = 0, kind = block, data = GenesisTx},
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
    {S1, Reply} = handle_append(From, Change, S0),
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
running(info, {link_up, Peer, Chan, LinkPid}, S = #s{chan = Chan}) ->
    {keep_state, handle_link_up(Peer, LinkPid, S)};
running(info, {link_error, Peer, Chan}, S = #s{chan = Chan}) ->
    %% the dial failed — clear the in-flight marker but KEEP the buffered frames; the tick re-dials
    %% (consensus emits each propose/share only once, so dropping them would stall the slot forever).
    {keep_state, S#s{dialing = maps:remove(Peer, S#s.dialing)}};
%% The catch-up worker died while still `{worker,Pid}` — i.e. it CRASHED before casting `{join_done,_}` (a
%% normal exit always casts first, and that cast, sent before the exit, is processed before this DOWN, flipping
%% `join` away from `{worker,Pid}` to the generic clause below). Re-arm a retry; `start_join_worker` resumes from
%% the persisted height, so the retry continues from the prefix already on disk — never re-appending from slot 1.
running(info, {'DOWN', _Ref, process, Pid, _Reason}, S = #s{join = {worker, Pid}}) ->
    {keep_state, S#s{join = pending}, [join_timeout()]};
running(info, {'DOWN', _Ref, process, Pid, _}, S) ->
    {keep_state, drop_conn(Pid, S)};
%% Δ_timeout fired for slot V (armed when V=head+1 became an *active* view — a proposal seen, or a
%% local client write we couldn't lead). If V is still the stuck head and we haven't commit-signed it,
%% broadcast our complaint share; a `⅔` complaint cert then skips V. Re-arm while V stays stuck (a
%% retransmit, over the send-once transport); stop once the head advances (commit or skip).
running({timeout, complain}, {complain, V}, S0) ->
    S1 = on_complain_timeout(V, S0),
    Actions = case S1#s.active_slot of
                  V -> [{{timeout, complain}, delta_ms(), {complain, V}}];   %% still stuck ⇒ keep pressing
                  _ -> timer_actions(S0, S1)                                 %% advanced/resolved ⇒ cancel or re-arm
              end,
    {keep_state, S1, Actions};
%% Consensus re-drive: re-dial any peer whose link never came up (its frames are still buffered).
running({timeout, tick}, tick, S) ->
    {keep_state, redial_pending(S), [tick_timeout()]};
%% mode=join: kick trustless catch-up. Wait (re-arm) until the catchup sibling is up, then spawn the worker.
%% (`valid_cfg` guarantees a `join` node has a binary `genesis_hash`, so there is no anchor-less arm here.)
running({timeout, join}, start_join, S = #s{join = pending, ns = Ns}) ->
    case quod_reg:where({quod_catchup, Ns}) of
        undefined -> {keep_state, S, [join_timeout()]};   %% sibling not up yet — retry shortly
        _         -> {keep_state, start_join_worker(S)}
    end;
running({timeout, join}, start_join, S) ->
    {keep_state, S};   %% no longer pending (worker running, or already done)
%% mode=join: the catch-up worker finished. `{ok,Slot≥1}` ⇒ genesis was anchored and the log+KB are caught up
%% (each window replayed as it landed); re-drive any deferred apply, refresh the engine to the height/committee
%% reached, mark the KB ready. `{ok,0}` means the contact served an EMPTY log (genesis never anchored) — treat
%% it like a failure and retry, never declare a read node "done" over nothing.
running(cast, {join_done, {ok, _H}}, S = #s{join = {worker, _}, slot = Slot}) when Slot >= 1 ->
    {keep_state, maybe_mark_ready(apply_committed(S#s{join = done, eng = eng_new(S#s.validators, Slot)}))};
running(cast, {join_done, Result}, S = #s{join = {worker, _}}) ->
    logger:warning("quod[~s]: catch-up attempt inconclusive (~p) — retrying", [S#s.ns, Result]),
    {keep_state, S#s{join = pending}, [join_timeout()]};
running(cast, {join_done, _}, S) -> {keep_state, S};   %% stale result (already retried / done)
%% mode=join: the worker hands each verified, contiguous window here to persist + replay in slot order.
running({call, From}, {sink_catchup, Es}, S) ->
    {S1, Reply} = apply_catchup_window(Es, S),
    {keep_state, S1, [{reply, From, Reply}]};
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

%% A client change enters consensus here. Only the slot's leader may propose; anyone else redirects.
%% The leader builds the block, feeds it + its own support share to the engine, and parks the caller
%% until that block commits. At N=1 the engine reaches commit synchronously, so the ack is immediate;
%% with peers the commit cert arrives later and `commit_block/3` acks then (or a complaint cert skips the
%% slot and `skip_block/2` nacks the caller `{error,skipped}`).
%% Returns `{NewState, ReplyActions}` (the caller wraps it + arms/cancels the Δ timer). The leader parks
%% the caller (no reply — `commit_block`/`skip_block` answers it) and arms the Δ timer on its own
%% proposal; a non-leader redirects AND arms the Δ timer for this wanted slot — so if the real leader is
%% dead, its own timer fires and it complains toward a skip (the client-driven activation of §failover).
handle_append(From, _Change, S = #s{proposing = P}) when P =/= none ->
    {S, [{reply, From, {error, busy}}]};   %% one proposal in flight at a time (non-pipelined)
handle_append(From, Change, S = #s{self = Self, validators = Vs, slot = Sl}) ->
    case lists:member(Self, Vs) of
        false -> {S, [{reply, From, {error, not_in_charge, none}}]};   %% not a committee member (joining/read-only)
        true  -> case acceptable_change(Change, S) of
                     false -> {S, [{reply, From, {error, bad_change}}]};   %% gate the leader's own input too
                     true  -> handle_append_leader(From, Change, Self, Vs, Sl, S)
                 end
    end.

handle_append_leader(From, Change, Self, Vs, Sl, S) ->
    Next = Sl + 1,
    case leader(Next, Vs) of
        Self ->
            Block = #block{slot = Next, parent = Sl, payload = [Change]},
            S1 = S#s{pending = (S#s.pending)#{Next => From}, proposing = Next, appends = S#s.appends + 1},
            S2 = broadcast({propose, Block}, S1),        %% send the proposal to the committee
            S3 = engine_step([{block, Block}], S2),      %% offer the block to our own engine
            {arm_complaint(Next, support_block(Block, S3)), []};   %% support it; park the caller; arm Δ
        Leader ->
            {arm_complaint(Next, S), [{reply, From, {error, not_in_charge, Leader}}]}
    end.

%% Offer items to the consensus engine and act on every event it emits (to a fixpoint), returning the
%% new state. Commit replies are sent inline via `gen_statem:reply` (the caller for that slot is parked).
engine_step(Items, S) ->
    {Eng1, Events} = lists:foldl(fun(It, {E, Evs}) ->
                                     {E1, Es} = eng_offer(It, E),
                                     {E1, Evs ++ Es}
                                 end, {S#s.eng, []}, Items),
    apply_events(Events, S#s{eng = Eng1}).

apply_events([], S)             -> S;
apply_events([Event | Rest], S) -> apply_events(Rest, apply_event(Event, S)).

%% A newly-formed (or first-learned) cert: disseminate it to the committee (§2.3.1).
apply_event({broadcast, Cert}, S) ->
    broadcast({cert, Cert}, S);
%% A block was notarized: sign + emit our commit share — UNLESS we already complaint-signed this slot
%% (`may_commit` guard). Recording `commit_signed[Sl]` makes the symmetric `may_complain` guard hold, so
%% an honest node contributes to at most one of {commit cert, complaint cert} per slot — the safety rule.
apply_event({notarized, #block{slot = Sl} = Block}, S = #s{id = Id, complained = Cd}) ->
    case may_commit(Sl, maps:keys(Cd)) of
        false -> S;                                    %% already complained Sl ⇒ never commit it
        true  -> Share = make_share(commit, Sl, block_hash(Block), Id),
                 engine_step([{share, Share}],
                             broadcast({share, Share}, S#s{commit_signed = (S#s.commit_signed)#{Sl => true}}))
    end;
%% A block is final: apply it, in slot order (out-of-order finalizations are buffered — contiguous apply).
apply_event({committed, Slot, Block}, S) ->
    commit_contiguous(Slot, Block, S);
%% A slot was complaint-skipped: finalize it as an empty (`noop`) slot, in order — advancing the height
%% so the rotated leader for the next slot proposes.
apply_event({skipped, Slot}, S) ->
    skip_contiguous(Slot, S).

%% Persist the committed block (durable before we ack), apply it into quod_prolog, advance the height,
%% clear the per-slot latches, and reply `{ok, Slot}` to the parked caller. The payload is a single change
%% (the non-pipelined proposer builds one-change blocks; batching is a later throughput step).
commit_block(Slot, #block{payload = [Change]} = Block, S = #s{store = Store, eng = Eng}) ->
    Cert = persisted_cert(commit, Slot, block_hash(Block), Eng),   %% minimal, committee-as-of-slot; pre-prune
    E = #entry{index = Slot, term = 0, kind = block, data = Change, cert = Cert},
    {ok, Store1} = quod_ledger_store:append(Store, [E]),
    S1 = adopt_committee(Change, finalize(Slot, S#s{store = Store1, commits = S#s.commits + 1})),
    maybe_mark_ready(ack_pending(Slot, apply_live(Slot, Change, S1))).

%% A committed transaction updates the LIVE committee at the slot boundary, IN-PROCESS — by reading the
%% `peer_admitted` asserts/retracts out of the block we just committed. Never from a message or a call: an
%% outside notification could land after we already began the next slot under the old set, and the nodes
%% would disagree. Safe without epochs because consensus is strictly non-pipelined: the just-committed
%% slot's certs are already formed + pruned under the OLD set, the set is a pure function of the committed
%% prefix, and slot+1 is the first slot voted under the NEW set — so every node crosses the boundary at the
%% same logical point. The delta folds via the SAME `apply_committee_delta/2` as the restart re-fold, so
%% the running set can never drift from a fresh re-fold.
adopt_committee(Change, S = #s{validators = V, eng = Eng}) ->
    case apply_committee_delta(Change, V) of
        V  -> S;                                                       %% no `peer_admitted` change
        V1 -> S#s{validators = V1, eng = eng_set_validators(V1, Eng)}
    end.

%% A complaint cert skipped this slot: persist an empty `noop` entry so the store height (and every
%% node's) advances contiguously, then nack any caller that had proposed it so the client retries under
%% the rotated leader. `quod_prolog` applies a `noop` as a pure cursor advance (no fact change).
skip_block(Slot, S = #s{store = Store, eng = Eng}) ->
    Cert = persisted_cert(complaint, Slot, none, Eng),   %% minimal complaint cert that skipped this slot
    E = #entry{index = Slot, term = 0, kind = block, data = noop, cert = Cert},
    {ok, Store1} = quod_ledger_store:append(Store, [E]),
    S1 = finalize(Slot, S#s{store = Store1}),
    maybe_mark_ready(apply_live(Slot, noop, nack_pending(Slot, S1))).

%% Advance the height past a now-durable slot and drop its per-slot in-flight state: the engine window,
%% the proposing latch, and the support/commit/complaint sign-latches (bounded to the in-flight window).
finalize(Slot, S) ->
    S#s{slot = Slot,
        eng = eng_prune(Slot, S#s.eng),   %% this slot is durable now — drop it from the in-flight pool
        proposing     = case S#s.proposing of Slot -> none; Other -> Other end,
        active_slot   = case S#s.active_slot of Slot -> none; A -> A end,
        supported     = maps:remove(Slot, S#s.supported),
        commit_signed = maps:remove(Slot, S#s.commit_signed),
        complained    = maps:remove(Slot, S#s.complained)}.

%% Reply `{ok, Slot}` to the caller parked on this slot (only the proposing node has one).
ack_pending(Slot, S = #s{pending = P}) ->
    case maps:take(Slot, P) of
        {From, P1} -> _ = gen_statem:reply(From, {ok, Slot}), S#s{pending = P1};
        error      -> S
    end.

%% Its slot was skipped, not committed: tell the parked proposer to retry (the write was never ordered).
nack_pending(Slot, S = #s{pending = P}) ->
    case maps:take(Slot, P) of
        {From, P1} -> _ = gen_statem:reply(From, {error, skipped}), S#s{pending = P1};
        error      -> S
    end.

%% Sign + emit our SUPPORT share for a block — offer it to our engine AND broadcast it — unless the slot
%% is already committed history, or we already supported a block for this slot (no double-support, the
%% honest-party one-block-per-slot invariant).
support_block(#block{slot = Sl}, S) when Sl =< S#s.slot -> S;
support_block(#block{slot = Sl} = Block, S = #s{supported = Sup, id = Id}) ->
    case maps:is_key(Sl, Sup) of
        true  -> S;
        false -> Share = make_share(support, Sl, block_hash(Block), Id),
                 engine_step([{share, Share}],
                             broadcast({share, Share}, S#s{supported = Sup#{Sl => block_hash(Block)}}))
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
dispatch(_Peer, {share, #share{} = Sh}, S) -> case well_formed_share(Sh) of true -> engine_step([{share, Sh}], S); false -> S end;
dispatch(_Peer, {cert,  #cert{}  = C},  S) -> case well_formed_cert(C)  of true -> engine_step([{cert, C}], S);   false -> S end;
dispatch(_Peer, _Other, S)                 -> S.

well_formed_block(#block{slot = Sl, parent = P, payload = Pl}) ->
    is_slot(Sl) andalso is_slot(P) andalso is_list(Pl);
well_formed_block(_) -> false.
well_formed_share(#share{kind = K, slot = Sl, block_hash = BH, signer = Sg, sig = Sig}) ->
    is_kind(K) andalso is_slot(Sl) andalso is_hash_or_none(BH) andalso is_binary(Sg) andalso is_binary(Sig);
well_formed_share(_) -> false.
well_formed_cert(#cert{kind = K, slot = Sl, block_hash = BH, sigs = Sigs}) ->
    is_kind(K) andalso is_slot(Sl) andalso is_hash_or_none(BH) andalso is_list(Sigs);
well_formed_cert(_) -> false.
is_slot(X)         -> is_integer(X) andalso X >= 0.
is_kind(K)         -> K =:= support orelse K =:= commit orelse K =:= complaint.
is_hash_or_none(H) -> H =:= none orelse is_binary(H).

%% A leader's proposal: accept it only from the slot's actual leader AND only when it is the NEXT block
%% we expect — slot = committed+1 extending our committed tip, with a single payload item. This bounds a
%% Byzantine leader (no jumping ahead / flooding future slots) and means we never support a block on a
%% chain we cannot verify, nor ever hand a malformed payload to commit_block.
%% `valid_proposal` is checked FIRST (it pins `Sl =:= H+1 ≥ 1`) so `leader/2` is never evaluated on an
%% untrusted `Sl` — a crafted `slot=0` would otherwise make `leader(0,_)` do `lists:nth(0,_)` and crash us.
on_propose(Peer, #block{slot = Sl} = Block, S = #s{validators = Vs}) ->
    case valid_proposal(Block, S) andalso leader(Sl, Vs) =:= Peer of
        true  -> arm_complaint(Sl, support_block(Block, engine_step([{block, Block}], S)));
        false -> S
    end.

%% The head+1 slot is now an ACTIVE view (a proposal seen, or a local write we couldn't lead): arm the
%% Δ complaint timer for it. Idempotent per slot (`A =/= V`) so repeat evidence never pushes the deadline
%% out; only ever `head+1`, so a single named timer suffices. An idle committee acquires no evidence, so
%% the timer is never armed — the client-driven model never skips a slot nobody wants.
arm_complaint(V, S = #s{slot = H, active_slot = A}) when V =:= H + 1, A =/= V -> S#s{active_slot = V};
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

%% Δ fired: if V is still the stuck head and we may still complain it (haven't commit-signed it), sign +
%% (re)broadcast our complaint share and offer it to the engine — a `⅔` complaint cert skips V. Latch
%% `complained[V]` so `may_commit` bars us from ever commit-signing V (the mutual-exclusion safety half).
on_complain_timeout(V, S = #s{slot = H, id = Id, commit_signed = Cs}) when V =:= H + 1 ->
    case may_complain(V, maps:keys(Cs)) of
        false -> S;
        true  -> Share = make_share(complaint, V, none, Id),
                 %% latch complained[V] BEFORE offering the share: if our own complaint completes the ⅔
                 %% cert, engine_step skips V and finalize/2 clears the latch — so the pre-set doesn't
                 %% leak; and any {notarized,V} inside that same engine_step now sees complained[V] and
                 %% is barred from a commit share (the mutual-exclusion safety half, self-enforced here).
                 S1 = S#s{complained = (S#s.complained)#{V => true}},
                 engine_step([{share, Share}], broadcast({share, Share}, S1))
    end;
on_complain_timeout(_V, S) -> S.

valid_proposal(#block{slot = Sl, parent = P, payload = [Change]}, #s{slot = H} = S) ->
    Sl =:= H + 1 andalso P =:= H andalso acceptable_change(Change, S);
valid_proposal(_Block, _S) -> false.

%% A change this node will PROPOSE or SUPPORT: a `#transaction` or a `noop`. Membership changes are now
%% ordinary transactions whose diff asserts/retracts `peer_admitted` (submitted via a `can_join`-gated
%% external predicate), so they flow through the transaction arm — no separate member-op vocabulary.
%% (Re-validating a committee-changing transaction on every node so a Byzantine leader can't pack the
%% committee is the deferred membership-safety slice.)
acceptable_change(#transaction{}, _S) -> true;
acceptable_change(noop, _S)           -> true;
acceptable_change(_, _)               -> false.

%% Send a consensus message to every OTHER validator, each on our own outbound link.
broadcast(Msg, S = #s{self = Self, validators = Vs}) ->
    lists:foldl(fun(P, Acc) -> send(P, Msg, Acc) end, S, Vs -- [Self]).

%% Send to one peer on our outbound link, dialing on demand; frames buffer (bounded) in the outbox until
%% `link_up` flushes them. We transmit only on our OWN outbound link, never a peer's inbound stream, so
%% every directed pair stays reachable (mirrors the removed Raft transport). The `dialing` marker keeps
%% at most one dial in flight per peer (a second `open_link` would register a duplicate waiter).
send(Peer, Msg, S = #s{ns = Ns, chan = Chan, conns = Conns, outbox = Outbox, dialing = Dialing}) ->
    Frame = encode(Ns, Msg),
    case maps:get(Peer, Conns, undefined) of
        {LinkPid, _Ref} ->
            _ = quod_link:send(LinkPid, Frame),
            S;
        undefined ->
            Buffered = lists:sublist([Frame | maps:get(Peer, Outbox, [])], ?MAX_OUTBOX),
            S1 = S#s{outbox = Outbox#{Peer => Buffered}},
            case maps:is_key(Peer, Dialing) of
                true  -> S1;                                  %% a dial is already in flight for this peer
                false -> _ = quod_quic:open_link(Peer, Chan),
                         S1#s{dialing = Dialing#{Peer => true}}
            end
    end.

%% Re-drive (tick): re-dial every peer with buffered frames but no live link and no dial in flight — the
%% recovery path for a dial that failed (its `dialing` marker was cleared by `link_error`, its frames kept).
redial_pending(S = #s{conns = Conns, outbox = Outbox, dialing = Dialing, chan = Chan}) ->
    Pending = [P || P <- maps:keys(Outbox),
                    not maps:is_key(P, Conns), not maps:is_key(P, Dialing)],
    lists:foldl(fun(P, Acc) ->
                    _ = quod_quic:open_link(P, Chan),
                    Acc#s{dialing = (Acc#s.dialing)#{P => true}}
                end, S, Pending).

encode(Ns, Msg) -> term_to_binary({sx, Ns, term_to_binary(Msg)}).

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
%% LIVE link to it or it is not a committee member (links are scoped to the committee). A stored conn
%% whose pid is DEAD (its `DOWN` not yet processed) is replaced — never treat a corpse as a live
%% duplicate and close the newcomer, or the peer could never re-link.
handle_link_up(Peer, LinkPid, S0 = #s{outbox = Outbox, validators = Vs}) ->
    S = S0#s{dialing = maps:remove(Peer, S0#s.dialing)},   %% the dial resolved
    LiveDup = case maps:get(Peer, S#s.conns, undefined) of
                  {Pid, _Ref} -> is_process_alive(Pid);
                  undefined   -> false
              end,
    case LiveDup orelse (not lists:member(Peer, Vs)) of
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

%% Apply committed-but-unapplied blocks into quod_prolog, in slot order — reading each from the store
%% (the rebuild path; this process keeps no in-memory log). Deferred if quod_prolog is not up yet.
%% The registry lookup is done ONCE here, not per block.
apply_committed(S = #s{last_applied = LA, slot = C}) when LA >= C -> S;
apply_committed(S = #s{ns = Ns}) ->
    case quod_reg:where({quod_prolog, Ns}) of
        undefined -> S;
        _         -> apply_loop(S)
    end.

apply_loop(S = #s{last_applied = LA, slot = C}) when LA >= C -> S;
apply_loop(S = #s{ns = Ns, store = Store, last_applied = LA}) ->
    I = LA + 1,
    {ok, #entry{data = Data}} = quod_ledger_store:read_at(Store, I),
    _ = safe_apply_block(Ns, I, Data),
    apply_loop(S#s{last_applied = I}).   %% re-applying already-counted commits (rebuild) — don't recount

safe_apply_block(Ns, I, Data) ->
    try quod_prolog:apply_block(Ns, I, Data) catch _:_ -> ok end.

%% Tell quod_prolog its kb is rebuilt and it may serve proves — but only ONCE the committed prefix
%% is actually applied, so a (re)started member never answers from a half-built kb.
%% A joiner (join = pending | {worker,_}) must NOT mark its KB ready mid-catch-up: its height only reflects
%% the windows sunk so far, so a prove would answer from a partial prefix. Only `none` (create / a member)
%% and `done` (caught up) may go ready.
maybe_mark_ready(S = #s{ns = Ns, prolog_ready = false, join = Join}) when Join =:= none; Join =:= done ->
    case (quod_reg:where({quod_prolog, Ns}) =/= undefined) andalso (S#s.last_applied >= S#s.slot) of
        true  -> _ = try quod_prolog:mark_ready(Ns) catch _:_ -> ok end,
                 S#s{prolog_ready = true};
        false -> S
    end;
maybe_mark_ready(S) -> S.   %% already marked ready, OR still joining (serve proves only once caught up)

%%%===================================================================
%%% mode=join — trustless catch-up (the joiner side of Simplex 4)
%%%===================================================================

%% A member of the current committee that may act on live consensus traffic + propose. A node still catching
%% up (`join = pending | {worker,_}`) is NEVER a participant — even if a catch-up window transiently folds its
%% OWN pubkey into `validators`, it must stay a read-only observer over its (stale, mid-build) engine until
%% `join=done` refreshes the engine to the caught-up height. `none` (create / member) and `done` may participate.
is_participant(#s{join = J}) when J =/= none, J =/= done -> false;
is_participant(#s{self = Self, validators = Vs})         -> lists:member(Self, Vs).

%% Spawn the (monitored) catch-up worker. It runs the driver loop OFF the statem: pull a window via the
%% catchup sibling, hand each verified window back to us (`sink_catchup`) to persist + replay, and finally
%% cast `{join_done, Result}`. Monitored so a crash mid-catch-up re-arms a retry (see the `'DOWN'` clause).
%% RESUME from the persisted height: `From = slot+1`, `Committee` = the set as of that slot. A fresh joiner
%% (`slot=0`) starts at `From=1` with `[]`, so slot 1 is anchored against `genesis_hash`; a retry/restart over a
%% partial prefix resumes past it (no re-append of what is already on disk, no re-anchor of an already-verified prefix).
start_join_worker(S = #s{ns = Ns, genesis_hash = GH, slot = Slot, validators = Vs}) ->
    Statem = self(),
    From   = Slot + 1,
    {Pid, _Ref} = spawn_monitor(
        fun() ->
            Fetch = fun(F)  -> quod_catchup:pull(Ns, F, F + ?JOIN_WINDOW - 1) end,
            Sink  = fun(Es) -> gen_statem:call(Statem, {sink_catchup, Es}, ?SINK_MS) end,
            gen_statem:cast(Statem, {join_done, quod_catchup:catch_up(GH, Fetch, Sink, From, Vs)})
        end),
    S#s{join = {worker, Pid}}.

%% Persist a verified, contiguous window (indices `slot+1..`) to the store, fold the committee across it,
%% and replay it into quod_prolog in slot order (`apply_committed` — the same path a restart-rebuild uses).
%% A store error aborts the window cleanly (returns `{error, _}` ⇒ the driver fails over); nothing is acked
%% half-applied. Both projections (validator set, KB) advance together from the one appended log.
apply_catchup_window([], S) -> {S, ok};
apply_catchup_window(Es, S = #s{store = Store, validators = Vs}) ->
    try quod_ledger_store:append(Store, Es) of
        {ok, Store1} ->
            Vs1  = committee_fold(Es, Vs),
            Slot = (lists:last(Es))#entry.index,
            S1   = maybe_mark_ready(apply_committed(S#s{store = Store1, validators = Vs1, slot = Slot})),
            {S1, ok}
    catch _:R -> {S, {error, R}}
    end.

local_genesis_hash(#s{store = Store}) ->
    case quod_ledger_store:read_at(Store, 1) of
        {ok, #entry{data = D}} -> block_hash(#block{slot = 1, parent = 0, payload = [D]});
        _                      -> undefined
    end.

%%%===================================================================
%%% helpers
%%%===================================================================

%% The committee = the set of `peer_admitted` pubkeys, derived from the committed log's transaction diffs.
%% Folds every committed entry's payload through `apply_committee_delta/2` in slot order (a `noop` payload
%% carries no committee change, so matching `data` alone is total over every `#entry`).
committee_from_log(Log) -> committee_fold(Log, []).

%% Fold a run of committed entries onto a validator set: seed `[]` for a full re-fold (`committee_from_log`),
%% or the running set for an incremental catch-up window (`apply_catchup_window`). One definition, so the two
%% callers can never drift.
committee_fold(Entries, Seed) ->
    lists:foldl(fun(#entry{data = Data}, V) -> apply_committee_delta(Data, V) end, Seed, Entries).

%% The committee change carried by one committed payload: the `peer_admitted` pubkeys it asserts (added)
%% and retracts (removed). A `#transaction` folds its diff (the validator id is the 4th arg / 5th element
%% of `peer_admitted(NodeId, Host, Port, Pubkey)`); a `noop` or anything else changes nothing. This ONE
%% function feeds BOTH the live commit-time swap (`adopt_committee/2`) and the boot/restart re-fold
%% (`committee_from_log/1`), so the running set can never drift from a fresh re-fold.
committee_delta(#transaction{diff = Diff}) -> lists:foldl(fun committee_op/2, {[], []}, Diff);
committee_delta(_)                         -> {[], []}.

committee_op({assert,  {{peer_admitted, _Id, _H, _P, Pk}, _B}}, {A, R}) -> {addq(Pk, A), R -- [Pk]};
committee_op({retract, {{peer_admitted, _Id, _H, _P, Pk}, _B}}, {A, R}) -> {A -- [Pk], addq(Pk, R)};
committee_op(_Op, Acc)                                                  -> Acc.

%% Apply a committed payload's committee delta onto a validator set — sorted (deterministic, every node
%% agrees byte-for-byte) and idempotent (a re-asserted member is a no-op).
apply_committee_delta(Change, V) ->
    {Adds, Removes} = committee_delta(Change),
    lists:usort(lists:foldl(fun addq/2, V, Adds) -- Removes).

addq(M, L) -> case lists:member(M, L) of true -> L; false -> L ++ [M] end.   %% idempotent add

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
        L when is_list(L) ->
            case lists:all(fun valid_member/1, L) of
                true  -> valid_mode(Cfg);
                false -> {error, {bad_committee, L}}   %% a malformed element ⇒ fail-fast
            end;
        Other -> {error, {bad_committee, Other}}
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
    #{role => validator, committee => S#s.validators, slot => S#s.slot,
      committed => S#s.slot, last_applied => S#s.last_applied, join => join_state(S)}.

%% Normalise the join lifecycle for `status/1`: `none` (create / a member) | `pending` | `catching_up` | `done`.
join_state(#s{join = {worker, _}}) -> catching_up;
join_state(#s{join = J})           -> J.

stats_map(S) ->
    #{slot => S#s.slot, committed => S#s.slot, last_applied => S#s.last_applied,
      committee_size => length(S#s.validators), appends => S#s.appends,
      commits => S#s.commits, prolog_ready => S#s.prolog_ready}.
