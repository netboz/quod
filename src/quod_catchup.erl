-module(quod_catchup).
-moduledoc """
Per-namespace **catch-up** endpoint — the path by which a joining node pulls the committed block log
(each block with the quorum certificate that finalized it) so it can **trustlessly** replay a namespace it
was not present for (`mode=join`, Simplex 4).

Two halves in one `gen_server`, riding a dedicated **`{catchup, Ns}`** `quod_link`
channel, separate from `quod_simplex`'s `{log, Ns}` channel:

- **Server** (any Member holding the durable log): serves a `{blocks_req, From, To}` by reading the
  committed `#entry{}` range from the store via `quod_ledger_store:open_ro/2` — a **read-only,
  non-truncating** handle opened alongside the live writer, so a slow/large pull never touches the
  consensus `gen_statem` and never corrupts the log. Each request runs in a worker; concurrency + range +
  frame size are bounded (hostile-net + memory caps).
- **Client** (a joiner): `contact/1` samples ONE download contact — the live, self-filtered Brahms view
  first, the static seeds (minus this node's own `node_addr`) as the cold-start fallback
  (`quod_brahms:sample_contact/2`) — and `pull/4` requests `[From, To]` from it. The contact is STICKY for
  a whole catch-up run and re-sampled only on the next attempt (see `contact/1`). The caller (`mode=join`
  init) drives the loop and **verifies each block's cert** against the committee it reconstructs — the
  server is never trusted (the certificate is the proof).

**Trust (trusted-fleet P1):** the inner record decodes without `[safe]`, like the
consensus log transport. Trustlessness comes from certificate verification at
the caller, not from trusting this transport.
""".
-behaviour(gen_server).
-include("quod_ledger.hrl").
-include("quod_transport_limits.hrl").

-export([start_link/2, contact/1, contacts/2, pull/4, serve_blocks/4,
         verify_forward/5, catch_up/4, catch_up/6]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-ifdef(TEST).
-export([peer_matches/2, contact_candidates/3]).
-endif.

-define(REQ_TIMEOUT_MS,  8000).
-define(MAX_INFLIGHT,    32).            %% server: concurrent read workers (bound a pull-flood)
-define(MAX_BLOCKS,      256).           %% server: max entries served per request (a coarse count cap)
-define(RESP_BUDGET,     (900 bsl 10)).  %% server: byte budget for the served entries — the whole response
                                         %% frame MUST fit quod_link's 1 MiB cap (it EXITs the link on a
                                         %% larger frame), so we leave headroom for the envelope

-record(s, {ns       :: binary(),
            self     :: node_id(),
            chan     :: binary(),                       %% term_to_binary({catchup, Ns}, [deterministic])
            data_dir :: file:filename_all(),
            seeds    = []  :: [endpoint()],             %% static cold-start contacts (sample_contact fallback)
            pending  = #{} :: #{reference() =>
                                  {gen_server:from(), reference(), {bound, node_id()} | unbound}},
                                      %% client: ReqId=>{From,TRef,ExpectedPeer}
            inflight = 0   :: non_neg_integer()}).       %% server: live read workers

%%%===================================================================
%%% API
%%%===================================================================

start_link(Ns, Config) ->
    gen_server:start_link(quod_reg:via({quod_catchup, Ns}), ?MODULE, {Ns, Config}, []).

-doc """
Sample ONE download contact for a catch-up run: the live, self-filtered Brahms view of `Ns` first,
this namespace's static seeds — minus this node's own `node_addr` — as the cold-start fallback
(`quod_brahms:sample_contact/2`). `none` when the node is isolated (no view, no usable seed).

The caller passes the pick EXPLICITLY to every `pull/4` of the run — ONE contact per attempt,
re-sampled only on the NEXT attempt: consecutive windows from different-height contacts would trip
`catch_up`'s `no_progress` guard mid-run (and a run must stay glued to one fully-caught-up contact,
the shape the 24-joiner/81k-slot cold-join relied on).
""".
-spec contact(binary()) -> endpoint() | none.
contact(Ns) ->
    case quod_reg:where({quod_catchup, Ns}) of
        undefined -> none;
        Pid -> try gen_server:call(Pid, contact, 5000) catch exit:_ -> none end
    end.

-doc "A bounded, shuffled set of non-self endpoint contacts for recovery address discovery.".
-spec contacts(binary(), pos_integer()) -> [endpoint()].
contacts(Ns, Limit) when is_integer(Limit), Limit > 0 ->
    case quod_reg:where({quod_catchup, Ns}) of
        undefined -> [];
        Pid -> try gen_server:call(Pid, {contacts, Limit}, 5000) catch exit:_ -> [] end
    end.

-doc "Pull committed entries `[From, To]` from a node id or `{Host, Port}` contact. Returns the entries + the server's height.".
-spec pull(binary(), pos_integer(), log_index(), node_id() | endpoint()) ->
        {ok, [#entry{}], log_index()} | {error, term()}.
pull(Ns, From, To, Contact) ->
    case quod_reg:where({quod_catchup, Ns}) of
        undefined -> {error, no_catchup_endpoint};
        Pid -> try gen_server:call(Pid, {pull, From, To, Contact}, ?REQ_TIMEOUT_MS + 1000)
               catch exit:_ -> {error, timeout} end
    end.

-doc """
Read the committed `#entry{}` range `[From, To]` (capped to `?MAX_BLOCKS` and the readable height) from a
READ-ONLY store view. Returns the entries + the server's current committed height. Used by the server
worker; pure w.r.t. the gen_server (opens/closes its own handle).
""".
-spec serve_blocks(binary(), file:filename_all(), pos_integer(), log_index()) ->
        {ok, [#entry{}], log_index()} | {error, term()}.
serve_blocks(Ns, DataDir, From0, To) ->
    From = max(1, From0),
    case quod_ledger_store:open_ro(Ns, DataDir) of
        {error, _} = E -> E;
        {ok, Store}    ->
            try
                LastI = quod_ledger_store:last(Store),
                To1 = lists:min([To, LastI, From + ?MAX_BLOCKS - 1]),
                {ok, Es} = quod_ledger_store:read_range(Store, From, To1),
                {ok, cap_bytes(Es, 0), LastI}   %% keep the response within one quod_link frame
            catch _:R -> {error, R}
            after quod_ledger_store:close(Store)
            end
    end.

%% The longest PREFIX of `Es` whose serialized size stays within ?RESP_BUDGET, so the whole response frame
%% fits quod_link's 1 MiB cap (it EXITs the link on a larger frame). Always keeps ≥ 1 entry so a joiner
%% makes progress and loops for the rest; a lone entry over budget is a genuinely oversized block that
%% needs chunking (deferred) — degenerate, not the common path.
cap_bytes([], _Acc) -> [];
cap_bytes([E | Rest], Acc) ->
    Acc1 = Acc + byte_size(term_to_binary(E, [deterministic])),
    case Acc =:= 0 orelse Acc1 =< ?RESP_BUDGET of
        true  -> [E | cap_bytes(Rest, Acc1)];
        false -> []
    end.

%%%===================================================================
%%% trustless forward-verification (the client's trust core)
%%%===================================================================

-doc """
Verify a pulled chain **by induction** — the joiner trusts nothing the server sent, only the certificates.
`GenesisHash` is the caller's trusted 32-byte slot-1 anchor. Together with `Ns`
it derives the consensus signature domain; neither value is accepted from the
serving peer. `Projection0` contains the committee and admission state AS OF
slot `From`; `Entries` MUST be a CONTIGUOUS ascending run starting at
`From` (a gap, reorder, or non-`#entry{}` element is a forged/incomplete history and is rejected — so a
malicious server cannot drop a committee-changing block to shift the fold, nor prepend a fake genesis to a
mid-chain window). For each entry, verify its finalizing certificate against the committee AS-OF-that-slot,
then advance the shared history projection. Returns `{ok, Verified, Projection1}` or `{error, Reason}` at
the first bad entry (which the caller must NOT persist).

Per entry, branching on the CERT kind (not the payload): an explicit **commit** cert binds the reconstructed
transaction-batch block; an **implicit** proof binds the parent's support cert and its immediate child's
commit cert; and a **complaint** cert (block_hash=none) finalizes a canonical `noop` skip (it authorizes no
payload). The genesis block (slot 1) uses the same canonical batch encoding and carries
**no** cert — it is the out-of-band trust anchor, so a genesis window
(`From=1`, an empty projection) is accepted only when that entry hashes to the supplied
`GenesisHash`. A malformed cert, a wrong
`(kind, slot, block_hash)`, or one that fails the `⅔` check against the committee-as-of-slot is rejected.
""".
-spec verify_forward(binary(), binary(), quod_simplex:history_projection(),
                     pos_integer(), [#entry{}]) ->
        {ok, [#entry{}], quod_simplex:history_projection()} | {error, term()}.
verify_forward(Ns, GenesisHash, Projection0, From, Entries)
  when is_binary(Ns), byte_size(Ns) > 0,
       is_binary(GenesisHash), byte_size(GenesisHash) =:= 32 ->
    Domain = quod_simplex:consensus_domain(Ns, GenesisHash),
    Binding = {Ns, GenesisHash},
    case verify_forward_domain(Binding, Domain, Projection0, From, Entries, []) of
        {ok, Verified, Projection1} ->
            case anchor_ok(From, Verified, GenesisHash) of
                true  -> {ok, Verified, Projection1};
                false -> {error, bad_anchor}
            end;
        {error, _} = Error ->
            Error
    end;
verify_forward(_Ns, _GenesisHash, _Projection0, _From, _Entries) ->
    {error, bad_anchor}.

verify_forward_domain(_Binding, _Domain, Projection, _Next, [], Acc) ->
    {ok, lists:reverse(Acc), Projection};
verify_forward_domain(Binding, Domain, Projection, Next,
                      [#entry{index = Next} = E | Rest], Acc) ->
    case verify_entry(Binding, Domain, E, Projection) of
        ok ->
            case quod_simplex:history_validate_advance(
                   Binding, E, Projection) of
                {ok, Projection1} ->
                    verify_forward_domain(
                      Binding, Domain, Projection1,
                      Next + 1, Rest, [E | Acc]);
                {error, _} = Error -> Error
            end;
        Error ->
            Error
    end;
verify_forward_domain(_Binding, _Domain, _Projection, Next,
                      [#entry{index = I} | _], _Acc) ->
    {error, {noncontiguous, Next, I}};   %% a gap/reorder — the server dropped or misordered an entry
verify_forward_domain(_Binding, _Domain, _Projection, Next, [_NotAnEntry | _], _Acc) ->
    {error, {malformed_entry, Next}};    %% a non-#entry element from a hostile server
verify_forward_domain(_Binding, _Domain, _Projection, Next, _ImproperTail, _Acc) ->
    {error, {malformed_entry, Next}}.    %% a hostile improper list after an otherwise-valid prefix

entry_data(#entry{data = Data}) -> Data.

%% Verify ONE entry's finalizing cert against the committee-as-of-its-slot. Branch on the CERT kind (not the
%% payload): a complaint cert finalizes a `noop` SKIP; a commit cert finalizes a block (payload a
%% #transaction OR a committed `noop`). A complaint cert over non-`noop` data, or any other cert shape, is
%% rejected — a complaint proves "skip slot I" and authorizes no payload.
verify_entry(Binding, Domain, #entry{} = E, Projection) ->
    Committee = quod_simplex:history_committee(Projection),
    case verify_entry_finality(Binding, Domain, E, Committee, Projection) of
        ok -> ok;
        {error, _} = Error ->
            Error
    end.

verify_entry_finality(_Binding, _Domain, #entry{index = 1, cert = none} = E,
                      _Committee, _Projection) ->
    case entry_block(E) of
        {ok, _Block} -> ok;   %% genesis is pinned out of band, but must still be structurally valid
        error -> {error, {malformed_entry, 1}}
    end;
verify_entry_finality(_Binding, _Domain, #entry{index = I, cert = none},
                      _Committee, _Projection) ->
    {error, {missing_cert, I}};   %% a non-genesis committed slot MUST carry a cert
verify_entry_finality(_Binding, Domain, #entry{index = I, data = noop, timestamp = 0,
                                          cert = #cert{kind = complaint} = Cert},
                      Committee, _Projection) ->
    verify_finalizer(Domain, Cert, complaint, I, none, Committee);
verify_entry_finality(Binding, Domain,
                      #entry{index = I, cert = #implicit_cert{} = Proof} = E,
                      Committee, Projection) ->
    verify_implicit(Binding, Domain, E, I, Proof, Committee, Projection);
verify_entry_finality(_Binding, Domain,
                      #entry{index = I, cert = #cert{kind = commit} = Cert} = E,
                      Committee, _Projection) ->
    case entry_block(E) of
        {ok, Block} ->
            BH = quod_simplex:block_hash(Block),
            verify_finalizer(Domain, Cert, commit, I, BH, Committee);
        error ->
            {error, {malformed_entry, I}}
    end;
verify_entry_finality(_Binding, _Domain, #entry{index = I},
                      _Committee, _Projection) ->
    {error, {cert_mismatch, I}}.   %% complaint cert over non-noop data, a support cert, a non-#cert, …

verify_implicit(Binding, Domain, E, I,
                #implicit_cert{support = Support,
                               child = #block{slot = ChildSlot, parent = I,
                                              payload = ChildPayload,
                                              timestamp = ChildTs} = Child,
                               commit = Commit}, Committee, Projection)
  when ChildSlot =:= I + 1 ->
    case {entry_block(E), quod_simplex:well_formed_block(Child)} of
        {{ok, Parent}, true} ->
            ParentBH = quod_simplex:block_hash(Parent),
            ChildBH = quod_simplex:block_hash(Child),
            StableCommittee = quod_simplex:committee_delta(entry_data(E)) =:= {[], []}
                              andalso quod_simplex:committee_delta({batch, ChildPayload}) =:= {[], []},
            case verify_finalizer(Domain, Support, support, I, ParentBH, Committee) of
                ok ->
                    case verify_finalizer(Domain, Commit, commit, ChildSlot, ChildBH,
                                          Committee) of
                        ok ->
                            ValidChild = quod_simplex:valid_history_entry(
                                           Binding, ChildSlot,
                                           {batch, ChildPayload}, Projection),
                            case StableCommittee andalso ValidChild
                                 andalso ChildTs >= Parent#block.timestamp of
                                true  -> ok;
                                false -> {error, {cert_mismatch, I}}
                            end;
                        {error, _} -> {error, {bad_implicit_cert, I}}
                    end;
                {error, _} -> {error, {bad_implicit_cert, I}}
            end;
        _ ->
            {error, {malformed_entry, I}}
    end;
verify_implicit(_Binding, _Domain, _E, I, _Proof, _Committee, _Projection) ->
    {error, {cert_mismatch, I}}.

entry_block(E) ->
    case quod_simplex:block_from_entry(E) of
        {ok, #block{} = Block} ->
            case quod_simplex:well_formed_block(Block) of
                true  -> {ok, Block};
                false -> error
            end;
        error -> error
    end.

%% The cert must name exactly this (kind, slot, block_hash) and carry ⅔ valid
%% signatures of the committee over the caller's locally derived
%% namespace/genesis domain. `verify_cert/3` is total and applies the
%% committee-size bound before signature-list traversal or crypto work.
verify_finalizer(Domain, #cert{kind = K, slot = Sl, block_hash = BH} = Cert,
                 K, Sl, BH, Committee) ->
    case quod_simplex:verify_cert(Domain, Cert, Committee) of
        true  -> ok;
        false -> {error, {bad_cert, Sl}}
    end;
verify_finalizer(_Domain, _Cert, _K, Sl, _BH, _Committee) ->
    {error, {cert_mismatch, Sl}}.

-doc """
Drive trustless catch-up to completion for a FRESH joiner: repeatedly FETCH a window of committed entries,
VERIFY it forward (`verify_forward/5`), and hand the verified entries to SINK (which appends them to the
local store), threading the committee, until caught up.

`GenesisHash` is the out-of-band-pinned `block_hash` of the genesis block (slot 1) — it pins the genesis's
FULL content (committee AND root ontology), not merely the derived committee; a genesis that hashes to
anything else is a forged anchor and catch-up aborts (`{error, bad_anchor}`). `Fetch` and `Sink` are
injected, so the driver is transport/store-agnostic (and unit-testable):
- `Fetch(From) -> {ok, [#entry{}], ServerHeight} | {error, term()}` — pull the window at `From` (the server
  may return FEWER than requested, e.g. under its byte budget; the loop continues from what it got).
- `Sink([#entry{}]) -> ok | {error, term()}` — append the just-verified, contiguous entries to the local
  store; an error aborts catch-up cleanly (`{error, {sink, _}}`).

`ServerHeight` is an UNTRUSTED, server-controlled number, used only for termination: the target is the MAX
height ever reported (`H` may not regress below what was already served), so a contact under-reporting its
height cannot truncate catch-up into a false "caught up". Returns `{ok, Height}` (caught up) or
`{error, Reason}` (forged chain / bad anchor / sink failure / fetch failure / a stuck server making no
progress — the caller should try another contact).

Use `catch_up/6` to RESUME from a partial prefix already on disk: `From` = `height+1` and `Projection` is
the complete history projection AS OF `From`. Resuming past slot 1
skips the genesis anchor (the persisted prefix was already verified when first sunk); a fresh joiner uses
`catch_up/4` (= `From=1`, empty projection) so slot 1 IS anchored against `GenesisHash`.
""".
-spec catch_up(binary(), binary(),
               fun((pos_integer()) -> {ok, [#entry{}], log_index()} | {error, term()}),
               fun(([#entry{}]) -> ok | {error, term()})) -> {ok, log_index()} | {error, term()}.
catch_up(Ns, GenesisHash, Fetch, Sink) ->
    catch_up(Ns, GenesisHash, Fetch, Sink, 1,
             quod_simplex:history_projection(), 0).

-spec catch_up(binary(), binary(),
               fun((pos_integer()) -> {ok, [#entry{}], log_index()} | {error, term()}),
               fun(([#entry{}]) -> ok | {error, term()}),
               pos_integer(), quod_simplex:history_projection()) ->
        {ok, log_index()} | {error, term()}.
catch_up(Ns, GenesisHash, Fetch, Sink, From, Projection) ->
    catch_up(Ns, GenesisHash, Fetch, Sink, From, Projection, 0).

catch_up(Ns, GenesisHash, Fetch, Sink, From, Projection, MaxH) ->
    case Fetch(From) of
        {error, R} -> {error, {fetch, R}};
        {ok, Entries, H} when is_integer(H), H >= 0 ->
            Target = max(MaxH, H),   %% untrusted, may regress ⇒ the target is the highest height ever seen
            case Entries of
                [] when From > Target -> {ok, Target};        %% nothing at/after the max height ⇒ caught up
                []                    -> {error, no_progress};  %% empty but more claimed/regressed H ⇒ stuck
                _ ->
                    case verify_forward(Ns, GenesisHash, Projection, From, Entries) of
                        {error, bad_anchor} -> {error, bad_anchor};
                        {error, R} -> {error, {verify, R}};
                        {ok, Verified, Projection1} ->
                            case Sink(Verified) of
                                {error, R} -> {error, {sink, R}};
                                ok ->
                                    Next = From + length(Verified),
                                    case Next > Target of
                                        true  -> {ok, Target};
                                        false -> catch_up(Ns, GenesisHash, Fetch, Sink,
                                                          Next, Projection1, Target)
                                    end
                            end
                    end
            end;
        _MalformedResponse ->
            {error, {fetch, bad_response}}
    end.

%% Only the FIRST window (From=1, containing genesis at slot 1) is anchor-checked: the genesis block must
%% HASH to the pinned genesis hash — pinning its full content (committee AND root ontology), so a server
%% can't forge a genesis that merely derives the right committee. Later windows are trusted through the
%% committee threaded from the (anchored) verified prefix.
anchor_ok(1, [#entry{index = 1} = E | _], GenesisHash) ->
    case entry_block(E) of
        {ok, Block} -> quod_simplex:block_hash(Block) =:= GenesisHash;
        error       -> false
    end;
anchor_ok(1, _Verified, _GenesisHash) -> false;   %% From=1 but the first entry isn't genesis
anchor_ok(_From, _Verified, _GenesisHash) -> true. %% mid-chain window

%%%===================================================================
%%% gen_server
%%%===================================================================

init({Ns, Config}) ->
    Self = maps:get(node_id, Config),
    Chan = term_to_binary({catchup, Ns}, [deterministic]),
    quod_reg:subscribe({channel, Chan}),
    {ok, #s{ns = Ns, self = Self, chan = Chan,
            data_dir = quod_ledger_store:ledger_dir(Config),
            seeds = maps:get(seed_peers, Config, [])}}.

handle_call(contact, _From, S = #s{ns = Ns, seeds = Seeds}) ->
    {reply, quod_brahms:sample_contact(Ns, Seeds), S};
handle_call({contacts, Limit}, _From, S = #s{ns = Ns, seeds = Seeds}) ->
    {reply, contact_candidates(Ns, Seeds, Limit), S};
handle_call({pull, From, To, Contact}, ReplyTo, S) ->
    ReqId = make_ref(),
    TRef  = erlang:send_after(?REQ_TIMEOUT_MS, self(), {req_timeout, ReqId}),
    S1    = send(Contact, {blocks_req, ReqId, From, To}, S),
    ExpectedPeer = expected_peer(Contact),
    {noreply, S1#s{pending = (S1#s.pending)#{ReqId => {ReplyTo, TRef, ExpectedPeer}}}};
handle_call(_Req, _From, S) -> {reply, {error, unknown_call}, S}.

handle_cast({send_resp, Peer, Resp}, S) ->
    {noreply, (send(Peer, Resp, S))#s{inflight = max(0, S#s.inflight - 1)}};
handle_cast(_Msg, S) -> {noreply, S}.

handle_info({quod_message, {{Peer, _Addr}, _In}, Chan, Payload}, S = #s{chan = Chan}) ->
    {noreply, inbound(Peer, Payload, S)};
handle_info({quod_message, _, _OtherChan, _}, S) -> {noreply, S};
handle_info({req_timeout, ReqId}, S) ->
    case maps:take(ReqId, S#s.pending) of
        {{From, _TRef, _ExpectedPeer}, P1} ->
            gen_server:reply(From, {error, timeout}),
            {noreply, S#s{pending = P1}};
        error -> {noreply, S}
    end;
handle_info(_Info, S) -> {noreply, S}.

terminate(_Reason, #s{chan = Chan}) ->
    _ = try quod_reg:unsubscribe({channel, Chan}) catch _:_ -> ok end,
    ok.

%%%===================================================================
%%% wire / dispatch
%%%===================================================================

inbound(_Peer, Payload, S) when byte_size(Payload) > ?QUOD_TRANSPORT_MAX_FRAME_BYTES ->
    S;   %% drop an oversized frame BEFORE decoding — bound binary_to_term memory (hostile peer)
inbound(Peer, Payload, S) ->
    try binary_to_term(Payload, [safe]) of
        {catchup, Ns, Bin} when Ns =:= S#s.ns ->
            try route(Peer, binary_to_term(Bin), S) catch _:_ -> S end;
        _ -> S
    catch _:_ -> S end.

route(Peer, {blocks_req, ReqId, From, To}, S) -> handle_req(Peer, ReqId, From, To, S);
route(Peer, {blocks_resp, ReqId, Entries, Height}, S) -> handle_resp(Peer, ReqId, Entries, Height, S);
route(Peer, {blocks_err, ReqId}, S) -> handle_err(Peer, ReqId, S);
route(_Peer, _Other, S) -> S.

%% Server: read the requested range in a worker (never block the endpoint; concurrency-capped). Over the
%% cap ⇒ drop; the client times out and retries a fresher/other peer.
handle_req(Peer, ReqId, From, To, S = #s{ns = Ns, data_dir = Dir}) when is_integer(From), is_integer(To) ->
    case S#s.inflight < ?MAX_INFLIGHT of
        false -> S;
        true  ->
            Self = self(),
            %% The worker ALWAYS casts a response (whole body in try/catch), so `inflight` is decremented
            %% even if serve_blocks throws — otherwise a crashed worker would leak a slot and, after
            %% ?MAX_INFLIGHT such crashes, wedge the endpoint. An error sends a distinct `blocks_err` (never
            %% a misleading empty `{[], 0}` that a joiner would read as "namespace empty").
            _ = spawn(fun() ->
                          Resp = try case serve_blocks(Ns, Dir, From, To) of
                                          {ok, Es, H} -> {blocks_resp, ReqId, Es, H};
                                          {error, _}  -> {blocks_err, ReqId}
                                      end
                                 catch _:_ -> {blocks_err, ReqId}
                                 end,
                          gen_server:cast(Self, {send_resp, Peer, Resp})
                      end),
            S#s{inflight = S#s.inflight + 1}
    end;
handle_req(_Peer, _ReqId, _From, _To, S) -> S.   %% malformed range ⇒ drop

%% Client: match a response to its parked caller.
handle_resp(Peer, ReqId, Entries, Height, S) ->
    reply_pending(Peer, ReqId, {ok, Entries, Height}, S).

%% Client: the server hit a read error (distinct from an empty log) — fail the pull so the caller retries
%% another contact rather than concluding the namespace is empty.
handle_err(Peer, ReqId, S) ->
    reply_pending(Peer, ReqId, {error, server_error}, S).

reply_pending(Peer, ReqId, Reply, S) ->
    case maps:get(ReqId, S#s.pending, undefined) of
        {_From, _TRef, ExpectedPeer} ->
            case peer_matches(Peer, ExpectedPeer) of
                false -> S;   %% authenticated response, but not from the node this request targeted
                true  ->
                    {{From, TRef, _}, P1} = maps:take(ReqId, S#s.pending),
                    _ = erlang:cancel_timer(TRef),
                    gen_server:reply(From, Reply),
                    S#s{pending = P1}
            end;
        undefined -> S   %% unknown / already-timed-out ReqId
    end.

expected_peer(Contact) when is_binary(Contact) -> {bound, Contact};
expected_peer(_Endpoint) -> unbound.

peer_matches(_Peer, unbound) -> true;
peer_matches(Peer, {bound, Peer}) -> true;
peer_matches(_Peer, {bound, _ExpectedPeer}) -> false.

%%%===================================================================
%%% transport
%%%===================================================================

%% Fire-and-forget send on our {catchup, Ns} channel — the transport (`quod_quic:send/3`) owns the link
%% (dial on demand, buffer until ready, reuse). A dropped frame just times out the pull and it retries.
send(Peer, Term, S = #s{ns = Ns, chan = Chan}) ->
    _ = quod_quic:send(Peer, Chan, term_to_binary({catchup, Ns, term_to_binary(Term)})),
    S.

%% A restarted node initially knows only addresses.  A direct catch-up request authenticates the remote
%% header and teaches `quod_quic` its pubkey=>endpoint hint, which lets Simplex make its later
%% identity-bound quorum probes.  Keep the candidates endpoint-only and self-filtered: this is discovery,
%% not trust; the catch-up and consensus layers still verify certificates and identities respectively.
contact_candidates(Ns, Seeds, Limit) ->
    SelfAddr = application:get_env(quod, node_addr, undefined),
    Pool = [P || P <- lists:usort(quod_brahms:sample(Ns) ++ Seeds), P =/= SelfAddr],
    quod_brahms:take_random(min(Limit, length(Pool)), Pool).
