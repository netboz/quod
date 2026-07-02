-module(quod_simplex).
-moduledoc """
Per-namespace **DispersedSimplex** Byzantine consensus — quod's ordering layer,
replacing the earlier hand-rolled Raft (`quod_ledger`). One consensus instance per
namespace; the committee is the namespace's validator set (`peer_admitted` facts,
epoch-frozen). See the approved plan and `doc/simplex_extended.pdf` (§2 = the spec).

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
> **Stage 1 (here):** the pure consensus core (quorum math, share signing, certificate
> formation/verification, the commit guards) **plus** the per-namespace `gen_statem` for the
> **single-validator (N=1)** case — propose → commit (the sole validator IS the `⅔` quorum) → apply →
> persist, single-node parity with the former Raft founder. **Stage 2 (next):** the real `⅔` share/cert
> collection, the `Δ_timeout` complaint timer, and the `quod_link` transport for a multi-node committee.
""".

-include("quod_ledger.hrl").

-behaviour(gen_statem).

%% Pure consensus core (also used by the gen_statem below and by the tests).
-export([quorum/1,
         block_hash/1, share_bytes/3,
         make_share/4, verify_share/1,
         form_cert/5, verify_cert/2,
         may_commit/2, may_complain/2]).

%% Per-namespace consensus process — API + gen_statem callbacks.
-export([start_link/2, append/2, rebuild/1, status/1, committee/1, stats/1, namespaces/0]).
-export([init/1, callback_mode/0, running/3, terminate/3]).

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

-doc "Build and Ed25519-sign one share of `Kind` for `Slot`/`BlockHash` with this node's identity.".
-spec make_share(support | commit | complaint, slot(), binary() | none, quod_identity:identity()) ->
          #share{}.
make_share(Kind, Slot, BlockHash, #{pubkey := Pub} = Id) ->
    Sig = quod_identity:sign(share_bytes(Kind, Slot, BlockHash), Id),
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
%%% gen_statem — the per-namespace consensus process (Stage 1: N=1)
%%%===================================================================
%%
%% One process per namespace, one logical state (`running`) — Simplex validators are
%% symmetric (no follower/candidate/leader roles; "leader for slot v" is a function of the
%% slot, not a process state). At N=1 the sole validator IS the quorum, so a block commits
%% the instant it is durable: no shares, certs, complaint timer, or transport yet — those
%% are Stage 2. The durable block list lives in `quod_ledger_store`; this process keeps only
%% the derived height + validator set, never the blocks (KB = projection, store = archive).

-define(DEFAULTS,
        #{node_id      => undefined,   %% our pubkey == node_id; REQUIRED
          committee    => [],          %% Stage 1 is single-validator; a non-empty committee is rejected (Stage 2)
          genesis_file => undefined,   %% root .pl to seed on create (founder only)
          data_dir     => undefined}).

-record(s, {ns           :: binary(),
            self         :: node_id(),               %% our pubkey == node_id
            store        :: quod_ledger_store:handle() | undefined,
            validators   = [] :: [node_id()],        %% epoch-frozen committee (self-only at N=1)
            slot         = 0  :: slot(),             %% height: index of the last block
            committed    = 0  :: slot(),             %% highest committed slot (== slot at N=1; Stage 2
                                                     %% lets it lag `slot` for not-yet-committed blocks)
            last_applied = 0  :: slot(),             %% highest slot handed to quod_prolog
            prolog_ready = false :: boolean(),
            appends = 0  :: non_neg_integer(),
            commits = 0  :: non_neg_integer()}).

callback_mode() -> [state_functions].

%%%===================================================================
%%% API
%%%===================================================================

start_link(Ns, Config) ->
    gen_statem:start_link(quod_reg:via({quod_simplex, Ns}), ?MODULE, {Ns, Config}, []).

-doc "Submit a change. Blocks until the block commits (`{ok, Slot}`). At N=1 that is its own fsync.".
-spec append(binary(), #transaction{}) -> {ok, slot()} | {error, not_in_charge, unavailable}.
append(Ns, Change) ->
    try gen_statem:call(quod_reg:via({quod_simplex, Ns}), {append, Change}, 5000)
    catch exit:_ -> {error, not_in_charge, unavailable} end.

-doc "Ask the consensus process to (re)drive committed blocks into a freshly-started `quod_prolog`.".
-spec rebuild(binary()) -> ok.
rebuild(Ns) -> gen_statem:cast(quod_reg:via({quod_simplex, Ns}), rebuild).

status(Ns)    -> call(Ns, get_status, #{}).
committee(Ns) -> call(Ns, get_committee, []).
stats(Ns)     -> call(Ns, get_stats, undefined).

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
            Self    = maps:get(node_id, Cfg),
            DataDir = data_dir(Cfg),
            {ok, Store} = quod_ledger_store:open(Ns, DataDir),
            S0 = #s{ns = Ns, self = Self, store = Store},
            %% A bad/missing genesis `.pl` on create is fatal — fail-fast, the app stops.
            try load_or_bootstrap(S0, Cfg) of
                S1 -> {ok, running, S1#s{committed = S1#s.slot, last_applied = 0}}
            catch
                throw:{genesis_failed, _} = Reason -> {stop, Reason}
            end
    end.

%% Restart reloads durable state (re-fold the committee from the on-disk config entries + take the
%% last index; the blocks themselves are NOT kept — the store is the archive, quod_prolog holds the
%% projection). A brand-new namespace is bootstrapped. Reading the log to re-fold the committee is
%% the accepted cost of running without a committee checkpoint; `last/1` gives the height in O(1).
load_or_bootstrap(S0 = #s{store = Store}, Cfg) ->
    L       = quod_ledger_store:load(Store),
    SnapCfg = maps:get(snap_cfg, L),
    Log     = maps:get(log, L),
    case Log =/= [] orelse SnapCfg =/= [] of
        true  -> {LastI, _} = quod_ledger_store:last(Store),
                 S0#s{validators = committee_of(SnapCfg, Log), slot = LastI};
        false -> bootstrap(Cfg, S0)
    end.

%% Fresh create (N=1): durably seed the sole validator as an `{add, self}` config entry (slot 1),
%% plus the genesis content block (slot 2) if a `.pl` is configured. `quod_prolog:genesis_diff/1` is
%% evaluated FIRST (it may throw `{genesis_failed,_}`) and both entries land in ONE atomic append —
%% so a bad `.pl` persists NOTHING: init stops and the next boot retries fresh, rather than leaving a
%% committee-only log that the next boot would mistake for a restart and never re-seed.
bootstrap(Cfg, S = #s{ns = Ns, self = Self, store = Store}) ->
    Committee = [#entry{index = 1, term = 0, kind = config, data = {add, Self}}],
    Genesis   = genesis_entries(Cfg, Ns, Self, length(Committee)),
    {ok, Store1} = quod_ledger_store:append(Store, Committee ++ Genesis),
    S#s{store = Store1, validators = [Self], slot = length(Committee) + length(Genesis)}.

%% The genesis content block at slot `K+1` (or `[]` with no genesis file). Evaluated before
%% bootstrap/2's single append, so a `genesis_diff/1` throw persists nothing.
genesis_entries(Cfg, Ns, Self, K) ->
    case genesis_file(Cfg) of
        none -> [];
        File ->
            Tx = #transaction{tx_id = <<"genesis:", Ns/binary>>, caller_ns = Ns,
                              diff = quod_prolog:genesis_diff(File), read_check = #{},
                              author = Self, sig = none},
            [#entry{index = K + 1, term = 0, kind = block, data = Tx}]
    end.

%%%===================================================================
%%% running
%%%===================================================================

running({call, From}, {append, Change}, S) -> handle_append(From, Change, S);
%% A freshly-(re)started quod_prolog: re-drive committed blocks from the start (async casts, in slot
%% order), then mark it ready ONLY once its kb is caught up — never a prove over a half-built kb.
running(cast, rebuild, S) ->
    {keep_state, maybe_mark_ready(apply_committed(S#s{last_applied = 0, prolog_ready = false}))};
running({call, From}, get_status, S)       -> {keep_state, S, [{reply, From, status_map(S)}]};
running({call, From}, get_committee, S)    -> {keep_state, S, [{reply, From, S#s.validators}]};
running({call, From}, get_stats, S)        -> {keep_state, S, [{reply, From, stats_map(S)}]};
running(_EventType, _Event, S)             -> {keep_state, S}.

terminate(_Reason, _State, #s{store = Store}) ->
    _ = case Store of
            undefined -> ok;
            _         -> try quod_ledger_store:close(Store) catch _:_ -> ok end
        end,
    ok.

%%%===================================================================
%%% append → commit → apply
%%%===================================================================

handle_append(From, Change, S = #s{store = Store}) ->
    I  = S#s.slot + 1,
    E  = #entry{index = I, term = 0, kind = block, data = Change},
    {ok, Store1} = quod_ledger_store:append(Store, [E]),   %% durable before we ack the commit
    %% N=1: the sole validator is the `⅔` quorum, so the block commits on its own fsync. Ack {ok, I}
    %% at commit; the OCC verdict still reaches the prove-client via quod_prolog's own park/release.
    S1 = apply_live(I, Change, S#s{store = Store1, slot = I, committed = I, appends = S#s.appends + 1}),
    {keep_state, maybe_mark_ready(S1), [{reply, From, {ok, I}}]}.

%% Apply a freshly-committed block using the IN-HAND payload — no read-back of what we just wrote.
%% Only when quod_prolog is up AND we are contiguous (last_applied == I-1); otherwise leave it and
%% let the rebuild handshake re-drive the gap from the store (apply_committed/1).
apply_live(I, Change, S = #s{ns = Ns, last_applied = LA}) when LA =:= I - 1 ->
    case quod_reg:where({quod_prolog, Ns}) of
        undefined -> S;
        _         -> _ = safe_apply_block(Ns, I, Change),   %% async cast (breaks the append<->apply deadlock)
                     S#s{last_applied = I, commits = S#s.commits + 1}
    end;
apply_live(_I, _Change, S) -> S.

%% Apply committed-but-unapplied blocks into quod_prolog, in slot order — reading each from the store
%% (the rebuild path; this process keeps no in-memory log). Deferred if quod_prolog is not up yet.
%% The registry lookup is done ONCE here, not per block.
apply_committed(S = #s{last_applied = LA, committed = C}) when LA >= C -> S;
apply_committed(S = #s{ns = Ns}) ->
    case quod_reg:where({quod_prolog, Ns}) of
        undefined -> S;
        _         -> apply_loop(S)
    end.

apply_loop(S = #s{last_applied = LA, committed = C}) when LA >= C -> S;
apply_loop(S = #s{ns = Ns, store = Store, last_applied = LA}) ->
    I = LA + 1,
    {ok, #entry{data = Data}} = quod_ledger_store:read_at(Store, I),
    _ = safe_apply_block(Ns, I, Data),
    apply_loop(S#s{last_applied = I, commits = S#s.commits + 1}).

safe_apply_block(Ns, I, Data) ->
    try quod_prolog:apply_block(Ns, I, Data) catch _:_ -> ok end.

%% Tell quod_prolog its kb is rebuilt and it may serve proves — but only ONCE the committed prefix
%% is actually applied, so a (re)started member never answers from a half-built kb.
maybe_mark_ready(S = #s{ns = Ns, prolog_ready = false}) ->
    case (quod_reg:where({quod_prolog, Ns}) =/= undefined) andalso (S#s.last_applied >= S#s.committed) of
        true  -> _ = try quod_prolog:mark_ready(Ns) catch _:_ -> ok end,
                 S#s{prolog_ready = true};
        false -> S
    end;
maybe_mark_ready(S) -> S.   %% already marked ready

%%%===================================================================
%%% helpers
%%%===================================================================

%% The validator set derived from the log's `config` entries (over an optional snapshot base).
%% Stage 1 only ever produces `{add, M}` (the founding committee); `{promote}`/`{remove}`/learners
%% land with membership changes (Stage 3) and extend this fold then.
committee_of(Base, Log) ->
    lists:foldl(fun(#entry{kind = config, data = {add, M}}, V) -> [M | V -- [M]];
                   (_, V) -> V
                end, Base, Log).

%% Stage 1 is strictly single-validator: a non-empty `committee` (co-founders) needs the multi-node
%% consensus that lands in Stage 2, so it is rejected here rather than silently mis-committed by the
%% N=1 fast path (which has no quorum/cert check).
valid_cfg(Config, Cfg) ->
    case maps:get(node_id, Config, undefined) of
        undefined -> {error, missing_node_id};
        _         ->
            case maps:get(committee, Cfg) of
                []                -> ok;
                L when is_list(L) -> {error, {multi_validator_unsupported_stage1, length(L)}};
                Other             -> {error, {bad_committee, Other}}
            end
    end.

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
      committed => S#s.committed, last_applied => S#s.last_applied}.

stats_map(S) ->
    #{slot => S#s.slot, committed => S#s.committed, last_applied => S#s.last_applied,
      committee_size => length(S#s.validators), appends => S#s.appends,
      commits => S#s.commits, prolog_ready => S#s.prolog_ready}.
