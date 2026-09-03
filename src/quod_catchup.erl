-module(quod_catchup).
-moduledoc """
Per-namespace **catch-up** endpoint — the path by which a joining node pulls the committed block log
(each block with the quorum certificate that finalized it) so it can **trustlessly** replay a namespace it
was not present for (`mode=join`, Simplex 4).

Two halves in one `gen_server`, riding a dedicated **`{catchup, Ns}`** `quod_link`
channel, separate from `quod_simplex`'s `{log, Ns}` channel:

- **Server** (any Member holding the durable log): asks the existing consensus owner for a copy of its
  already-verified sparse ledger index, then reads the committed `#entry{}` range through a separate
  **read-only** handle. The worker never shares the writer's raw descriptor and never rescans the full
  log. Each request runs in a worker; concurrency + range + frame size are bounded (hostile-net +
  memory caps).
- **Client** (a joiner): `contact/1` samples ONE download contact — the live, self-filtered Brahms view
  first, the static seeds (minus this node's own `node_addr`) as the cold-start fallback
  (`quod_brahms:sample_contact/2`) — and `pull/4` requests `[From, To]` from it. The contact is STICKY for
  a whole catch-up run and re-sampled only on the next attempt (see `contact/1`). The caller (`mode=join`
  init) drives the loop and **verifies each block's cert** against the committee it reconstructs — the
  server is never trusted (the certificate is the proof).

Committed entries cross this channel only as their canonical byte envelopes.
The endpoint decodes those bytes into local views; trustlessness still comes
from certificate verification at the caller, never from the serving peer.
""".
-behaviour(gen_server).
-include("quod_ledger.hrl").
-include("quod_transport_limits.hrl").
-include("quod_proof_limits.hrl").

-export([start_link/2, contact/1, contacts/2, pull/4, serve_blocks/4, stats/1,
         channel/1, encode_frame/2, decode_frame/2, page_stats/1,
         verify_forward/5, verify_forward/6, verify_entry/3,
         catch_up/5, catch_up/7]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-ifdef(TEST).
-export([peer_matches/2, contact_candidates/3,
         test_state/2, test_state/3]).
-endif.

-define(REQ_TIMEOUT_MS,  8000).
-define(MAX_INFLIGHT,    32).            %% server: concurrent read workers (bound a pull-flood)
-define(MAX_BLOCKS,      ?QUOD_MAX_FOREIGN_PAGE_ENTRIES).
-define(RESP_BUDGET,     ?QUOD_MAX_FOREIGN_PAGE_BYTES).
                                         %% frame MUST fit quod_link's 1 MiB cap (it EXITs the link on a
                                         %% larger frame), so we leave headroom for the envelope

-record(client_pull, {
          from :: gen_server:from(),
          timer :: reference(),
          expected_peer :: {bound, node_id()} | {opening, reference()},
          started_ms :: integer()
         }).

-record(s, {ns       :: binary(),
            self     :: node_id(),
            chan     :: binary(),                       %% term_to_binary({catchup, Ns}, [deterministic])
            data_dir :: file:filename_all(),
            seeds    = []  :: [endpoint()],             %% static cold-start contacts (sample_contact fallback)
            pending  = #{} :: #{reference() => #client_pull{}},
                                      %% client: one exact owned row per pull
            pending_peak = 0 :: non_neg_integer(),
            openings = #{} :: #{reference() =>
                                  {reference(), endpoint(), binary()}},
                                      %% identified OpenRef=>{ReqId,Endpoint,Frame}
            inflight = #{} :: #{reference() => integer()},
                                      %% server: one exact row per live read worker
            inflight_peak = 0 :: non_neg_integer()}).

-ifdef(TEST).
test_state(Ns, LedgerDir) ->
    test_state(Ns, LedgerDir, #{}).

test_state(Ns, LedgerDir, Opts) ->
    Pending = normalize_test_pending(maps:get(pending, Opts, #{})),
    #s{ns = Ns, self = <<0:256>>, chan = channel(Ns),
       data_dir = LedgerDir,
       pending = Pending,
       pending_peak = map_size(Pending),
       openings = maps:get(openings, Opts, #{})}.

normalize_test_pending(Pending) ->
    maps:map(
      fun(_ReqId, {From, Timer, ExpectedPeer}) ->
              #client_pull{from = From, timer = Timer,
                           expected_peer = ExpectedPeer,
                           started_ms = quod_time:mono_ms()};
         (_ReqId, #client_pull{} = Pull) ->
              Pull
      end, Pending).
-endif.

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

-doc "Current catch-up work and owner-lifetime peaks for one hosted ontology.".
-spec stats(binary()) -> map().
stats(Ns) when is_binary(Ns) ->
    case quod_reg:where({quod_catchup, Ns}) of
        Pid when is_pid(Pid) ->
            try gen_server:call(Pid, stats, 5000)
            catch exit:_ -> empty_stats()
            end;
        undefined -> empty_stats()
    end.

empty_stats() ->
    #{client_pending => 0, client_pending_peak => 0,
      server_inflight => 0, server_inflight_peak => 0}.

-doc "The one canonical catch-up channel name for an ontology.".
-spec channel(binary()) -> binary().
channel(Ns) when is_binary(Ns) ->
    term_to_binary({catchup, Ns}, [deterministic]).

-doc "Encode one catch-up frame; committed entries travel only as their canonical blobs.".
-spec encode_frame(binary(), term()) -> binary().
encode_frame(Ns, Term) when is_binary(Ns) ->
    WireTerm = encode_wire_term(Term),
    term_to_binary(
      {catchup, Ns, term_to_binary(WireTerm, [deterministic])},
      [deterministic]).

encode_wire_term({blocks_resp, ReqId, Entries, Height}) when is_list(Entries) ->
    EntryBlobs =
        [begin
             {ok, Blob} = quod_ledger:encode_entry(Entry),
             Blob
         end || Entry <- Entries],
    {blocks_resp_bytes, ReqId, EntryBlobs, Height};
encode_wire_term(Term) ->
    Term.

-doc "Decode one existing catch-up frame, returning its inner encoded byte count.".
-spec decode_frame(binary(), binary()) ->
          {ok, term(), non_neg_integer()} | {error, term()}.
decode_frame(Ns, Payload)
  when is_binary(Ns), is_binary(Payload),
       byte_size(Payload) =< ?QUOD_TRANSPORT_MAX_FRAME_BYTES ->
    try binary_to_term(Payload, [safe]) of
        {catchup, Ns, Bin}
          when is_binary(Bin),
               byte_size(Bin) =< ?QUOD_TRANSPORT_MAX_FRAME_BYTES ->
            %% R2 changes only the committed-entry identity to exact bytes.
            %% The existing catch-up control grammar still carries Erlang
            %% references whose node-name atom may be unknown here; R3 owns
            %% replacing this trusted-fleet decode with the wrapped decoder.
            try decode_wire_term(binary_to_term(Bin), byte_size(Bin))
            catch _:_ -> {error, bad_frame}
            end;
        _ ->
            {error, bad_frame}
    catch _:_ ->
        {error, bad_frame}
    end;
decode_frame(_Ns, _Payload) ->
    {error, frame_too_large}.

decode_wire_term({blocks_resp_bytes, ReqId, EntryBlobs, Height}, Bytes)
  when is_list(EntryBlobs) ->
    case decode_entry_blobs(EntryBlobs, []) of
        {ok, Entries} ->
            {ok, {blocks_resp, ReqId, Entries, Height}, Bytes};
        error ->
            {error, bad_frame}
    end;
decode_wire_term({blocks_resp, _ReqId, _Entries, _Height}, _Bytes) ->
    %% There is no record-carrying compatibility wire in this format cut.
    {error, bad_frame};
decode_wire_term(Term, Bytes) ->
    {ok, Term, Bytes}.

decode_entry_blobs([Blob | Rest], Acc) when is_binary(Blob) ->
    case quod_ledger:decode_entry(Blob) of
        {ok, Entry} -> decode_entry_blobs(Rest, [Entry | Acc]);
        {error, _} -> error
    end;
decode_entry_blobs([], Acc) ->
    {ok, lists:reverse(Acc)};
decode_entry_blobs(_Malformed, _Acc) ->
    error.

-doc "Bound a decoded catch-up page by the shared entry-count and encoded-byte limits.".
-spec page_stats(term()) ->
          {ok, non_neg_integer(), non_neg_integer()} | {error, term()}.
page_stats(Entries) ->
    page_stats(Entries, 0, 0).

page_stats([], Count, Bytes) ->
    {ok, Count, Bytes};
page_stats([#entry{} = Entry | Rest], Count, Bytes)
  when Count < ?QUOD_MAX_FOREIGN_PAGE_ENTRIES ->
    case quod_ledger:encode_entry(Entry) of
        {ok, EntryBytes} ->
            Bytes1 = Bytes + byte_size(EntryBytes),
            case Bytes1 =< ?QUOD_MAX_FOREIGN_PAGE_BYTES of
                true -> page_stats(Rest, Count + 1, Bytes1);
                false -> {error, page_too_large}
            end;
        {error, _} ->
            {error, malformed_page}
    end;
page_stats([#entry{} | _], _Count, _Bytes) ->
    {error, too_many_entries};
page_stats(_Malformed, _Count, _Bytes) ->
    {error, malformed_page}.

-doc """
Read the committed `#entry{}` range `[From, To]` (capped to `?MAX_BLOCKS` and the readable height) from a
READ-ONLY store view. Returns the entries + the server's current committed height. Used by the server
worker; pure w.r.t. the gen_server (opens/closes its own handle).
""".
-spec serve_blocks(binary(), file:filename_all(), pos_integer(), log_index()) ->
        {ok, [#entry{}], log_index()} | {error, term()}.
serve_blocks(Ns, DataDir, From0, To) ->
    From = max(1, From0),
    case open_read_view(Ns, DataDir) of
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

%% A hosted namespace already owns the one verified sparse index in Simplex.
%% Reusing a snapshot avoids an O(history) rescan for every tiny catch-up page.
%% The fallback is the same offline/startup reader used before this optimization;
%% it is not another source of truth and every returned frame is still checked.
open_read_view(Ns, DataDir) ->
    case quod_simplex:ledger_read_snapshot(Ns) of
        {ok, Snapshot} ->
            quod_ledger_store:open_ro_snapshot(Snapshot);
        {error, not_ready} ->
            quod_ledger_store:open_ro(Ns, DataDir)
    end.

%% The longest PREFIX of `Es` whose serialized size stays within ?RESP_BUDGET, so the whole response frame
%% fits quod_link's 1 MiB cap (it EXITs the link on a larger frame). Always keeps ≥ 1 entry so a joiner
%% makes progress and loops for the rest. The shared singleton-block ceiling guarantees that one maximum
%% canonical entry plus its certificate and response framing fits this budget; the boundary test pins that
%% invariant, so no separate chunking protocol exists.
cap_bytes([], _Acc) -> [];
cap_bytes([E | Rest], Acc) ->
    {ok, EntryBytes} = quod_ledger:encode_entry(E),
    Acc1 = Acc + byte_size(EntryBytes),
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
tagged block; an **implicit** proof is restricted to an ordinary non-membership batch and binds the parent's
support cert and its immediate child's commit cert; and a **complaint** cert (block_hash=none) finalizes a
canonical `noop` skip (it authorizes no payload). DTX controls are explicit-finality barriers and can never
be finalized implicitly. The genesis block (slot 1) uses the canonical batch encoding and carries
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

-doc """
Verify one fetched window through the exact DTX phase index without mutating it.

The returned opaque delta contains every phase-history change in this window.
The catch-up driver commits it only after the same window and its resulting
projection have been accepted by the ledger sink.
""".
-spec verify_forward(binary(), binary(), quod_simplex:history_projection(),
                     pos_integer(), [#entry{}],
                     quod_dtx_phase_index:index()) ->
        {ok, [#entry{}], quod_simplex:history_projection(),
         quod_dtx_phase_index:delta()} |
        {error, term()}.
verify_forward(Ns, GenesisHash, Projection0, From, Entries, PhaseIndex)
  when is_binary(Ns), byte_size(Ns) > 0,
       is_binary(GenesisHash), byte_size(GenesisHash) =:= 32 ->
    Binding = {Ns, GenesisHash},
    Delta0 = quod_dtx_phase_index:new_delta(),
    case verify_forward_phase(
           Binding, Projection0, From, Entries, PhaseIndex, Delta0, []) of
        {ok, Verified, Projection1, Delta1} ->
            case anchor_ok(From, Verified, GenesisHash) of
                true -> {ok, Verified, Projection1, Delta1};
                false -> {error, bad_anchor}
            end;
        {error, _} = Error ->
            Error
    end;
verify_forward(_Ns, _GenesisHash, _Projection0, _From, _Entries, _PhaseIndex) ->
    {error, bad_anchor}.

verify_forward_phase(_Binding, Projection, _Next, [], _PhaseIndex, Delta, Acc) ->
    {ok, lists:reverse(Acc), Projection, Delta};
verify_forward_phase(Binding, Projection, Next,
                     [#entry{index = Next} = Entry | Rest],
                     PhaseIndex, Delta0, Acc) ->
    case quod_simplex:history_preview_advance(
           Binding, Entry, Projection, PhaseIndex, Delta0) of
        {ok, Projection1, _Effects, Delta1} ->
            verify_forward_phase(
              Binding, Projection1, Next + 1, Rest,
              PhaseIndex, Delta1, [Entry | Acc]);
        {error, _} = Error ->
            Error
    end;
verify_forward_phase(_Binding, _Projection, Next,
                     [#entry{index = I} | _], _PhaseIndex, _Delta, _Acc) ->
    {error, {noncontiguous, Next, I}};
verify_forward_phase(_Binding, _Projection, Next, [_NotAnEntry | _],
                     _PhaseIndex, _Delta, _Acc) ->
    {error, {malformed_entry, Next}};
verify_forward_phase(_Binding, _Projection, Next, _ImproperTail,
                     _PhaseIndex, _Delta, _Acc) ->
    {error, {malformed_entry, Next}}.

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

-doc "Verify one persisted entry's local finality against its parent projection.".
-spec verify_entry({binary(), <<_:256>>}, #entry{},
                   quod_simplex:history_projection()) ->
          ok | {error, term()}.
verify_entry({Ns, <<_:256>> = Anchor} = Binding, #entry{} = Entry,
             Projection) when is_binary(Ns) ->
    verify_entry(
      Binding, quod_simplex:consensus_domain(Ns, Anchor), Entry, Projection).

%% Verify ONE entry's finalizing cert against the committee-as-of-its-slot. Branch on the CERT kind (not the
%% payload): a complaint cert finalizes a `noop` SKIP; a commit cert finalizes a tagged content/DTX block.
%% A complaint cert over non-`noop` data, or any other cert shape, is rejected — a complaint proves
%% "skip slot I" and authorizes no payload.
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
            ImplicitEligible = implicit_content(entry_data(E))
                               andalso implicit_content(ChildPayload),
            case ImplicitEligible of
                true ->
                    case verify_finalizer(
                           Domain, Support, support, I, ParentBH, Committee) of
                        ok ->
                            case verify_finalizer(
                                   Domain, Commit, commit, ChildSlot, ChildBH,
                                   Committee) of
                                ok ->
                                    ValidChild =
                                        quod_simplex:valid_history_entry(
                                          Binding, ChildSlot, ChildPayload,
                                          ChildTs,
                                          Projection),
                                    case ValidChild andalso
                                         ChildTs >= Parent#block.timestamp of
                                        true  -> ok;
                                        false -> {error, {cert_mismatch, I}}
                                    end;
                                {error, _} -> {error, {bad_implicit_cert, I}}
                            end;
                        {error, _} -> {error, {bad_implicit_cert, I}}
                    end;
                false ->
                    {error, {cert_mismatch, I}}
            end;
        _ ->
            {error, {malformed_entry, I}}
    end;
verify_implicit(_Binding, _Domain, _E, I, _Proof, _Committee, _Projection) ->
    {error, {cert_mismatch, I}}.

%% Implicit finality relies on a child being valid under exactly the same
%% committee as its parent. Membership batches and every DTX control are
%% explicit barriers, so only an ordinary committee-stable content batch is
%% eligible. Keep the full union explicit: a future payload kind must choose.
implicit_content(Data) ->
    case quod_ledger:classify(Data) of
        {content, _Transactions} ->
            quod_simplex:committee_delta(Data) =:= {[], []};
        {controls, _Controls} -> false;
        noop -> false;
        invalid -> false
    end.

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
Drive trustless catch-up to completion for a fresh or partially caught-up
joiner. Each fetched window is verified forward and handed to the sink together
with its resulting authoritative projection.

`GenesisHash` is the out-of-band-pinned slot-1 block hash. `Fetch(From)` returns
one bounded entry window and the untrusted server height. `Sink(Entries,
Projection)` atomically appends that verified window and accepts its exact
resulting projection.

`Options` contains the local `ledger_root`. Content-only catch-up never reads
it and never opens a phase index. On the first fetched DTX control, the driver
opens one session-unique phase index, backfills the exact already-sunk local
prefix from slot 1, and retains the index for every remaining window. A window
is first previewed into a bounded phase delta; the sink runs next; only a
successful sink is followed by `quod_dtx_phase_index:commit_delta/2`. The index
is always closed and deleted when the catch-up attempt ends.

The target height is the maximum ever reported in this run, so a regressing or
under-reporting contact cannot truncate catch-up. Use `catch_up/7` to resume:
`From` is the local height plus one and `Projection` is the complete projection
at that point. `catch_up/5` starts at slot 1 and checks the genesis anchor.
""".
-spec catch_up(
        binary(), binary(),
        fun((pos_integer()) ->
                {ok, [#entry{}], log_index()} | {error, term()}),
        fun(([#entry{}], quod_simplex:history_projection()) ->
                ok | {error, term()}),
        #{ledger_root := file:filename_all()}) ->
          {ok, log_index()} | {error, term()}.
catch_up(Ns, <<_:256>> = GenesisHash, Fetch, Sink,
         #{ledger_root := LedgerRoot})
  when is_binary(Ns), byte_size(Ns) > 0,
       is_function(Fetch, 1), is_function(Sink, 2) ->
    Projection = quod_simplex:history_projection({Ns, GenesisHash}),
    catch_up_loop(
      Ns, GenesisHash, Fetch, Sink, LedgerRoot, 1, Projection, 0, none);
catch_up(_Ns, _GenesisHash, _Fetch, _Sink, _Options) ->
    {error, bad_catchup_options}.

-spec catch_up(
        binary(), binary(),
        fun((pos_integer()) ->
                {ok, [#entry{}], log_index()} | {error, term()}),
        fun(([#entry{}], quod_simplex:history_projection()) ->
                ok | {error, term()}),
        pos_integer(), quod_simplex:history_projection(),
        #{ledger_root := file:filename_all()}) ->
          {ok, log_index()} | {error, term()}.
catch_up(Ns, <<_:256>> = GenesisHash, Fetch, Sink, From, Projection,
         #{ledger_root := LedgerRoot})
  when is_binary(Ns), byte_size(Ns) > 0,
       is_function(Fetch, 1), is_function(Sink, 2),
       is_integer(From), From >= 1, is_map(Projection) ->
    catch_up_loop(
      Ns, GenesisHash, Fetch, Sink, LedgerRoot,
      From, Projection, 0, none);
catch_up(_Ns, _GenesisHash, _Fetch, _Sink, _From, _Projection, _Options) ->
    {error, bad_catchup_options}.

catch_up_loop(Ns, GenesisHash, Fetch, Sink, LedgerRoot,
              From, Projection, MaxH, PhaseIndex) ->
    case Fetch(From) of
        {error, R} ->
            {error, {fetch, R}};
        {ok, Entries, H} when is_integer(H), H >= 0 ->
            Target = max(MaxH, H),
            case Entries of
                [] when From > Target -> {ok, Target};
                [] -> {error, no_progress};
                _ ->
                    catch_up_entries(
                      Ns, GenesisHash, Fetch, Sink, LedgerRoot,
                      From, Projection, Target, Entries, PhaseIndex)
            end;
        _MalformedResponse ->
            {error, {fetch, bad_response}}
    end.

catch_up_entries(Ns, GenesisHash, Fetch, Sink, LedgerRoot,
                 From, Projection, Target, Entries, none) ->
    case window_has_dtx(Entries) of
        false ->
            catch_up_content_window(
              Ns, GenesisHash, Fetch, Sink, LedgerRoot,
              From, Projection, Target, Entries);
        true ->
            case open_phase_index(Ns, GenesisHash, LedgerRoot, From) of
                {ok, PhaseIndex} ->
                    try
                        catch_up_phase_window(
                          Ns, GenesisHash, Fetch, Sink, LedgerRoot,
                          From, Projection, Target, Entries, PhaseIndex)
                    after
                        _ = quod_dtx_phase_index:close(PhaseIndex)
                    end;
                {error, _} = Error ->
                    Error
            end
    end;
catch_up_entries(Ns, GenesisHash, Fetch, Sink, LedgerRoot,
                 From, Projection, Target, Entries, PhaseIndex) ->
    catch_up_phase_window(
      Ns, GenesisHash, Fetch, Sink, LedgerRoot,
      From, Projection, Target, Entries, PhaseIndex).

catch_up_content_window(Ns, GenesisHash, Fetch, Sink, LedgerRoot,
                        From, Projection, Target, Entries) ->
    case verify_forward(Ns, GenesisHash, Projection, From, Entries) of
        {ok, Verified, Projection1} ->
            case Sink(Verified, Projection1) of
                ok ->
                    continue_catch_up(
                      Ns, GenesisHash, Fetch, Sink, LedgerRoot,
                      From, Verified, Projection1, Target, none);
                {error, R} ->
                    {error, {sink, R}}
            end;
        {error, bad_anchor} ->
            {error, bad_anchor};
        {error, R} ->
            {error, {verify, R}}
    end.

catch_up_phase_window(Ns, GenesisHash, Fetch, Sink, LedgerRoot,
                      From, Projection, Target, Entries, PhaseIndex) ->
    case verify_forward(
           Ns, GenesisHash, Projection, From, Entries, PhaseIndex) of
        {ok, Verified, Projection1, Delta} ->
            case Sink(Verified, Projection1) of
                ok ->
                    case quod_dtx_phase_index:commit_delta(PhaseIndex, Delta) of
                        ok ->
                            continue_catch_up(
                              Ns, GenesisHash, Fetch, Sink, LedgerRoot,
                              From, Verified, Projection1, Target, PhaseIndex);
                        {error, R} ->
                            {error, {phase_index, R}}
                    end;
                {error, R} ->
                    {error, {sink, R}}
            end;
        {error, bad_anchor} ->
            {error, bad_anchor};
        {error, R} ->
            {error, {verify, R}}
    end.

continue_catch_up(Ns, GenesisHash, Fetch, Sink, LedgerRoot,
                  From, Verified, Projection, Target, PhaseIndex) ->
    Next = From + length(Verified),
    case Next > Target of
        true ->
            {ok, Target};
        false ->
            catch_up_loop(
              Ns, GenesisHash, Fetch, Sink, LedgerRoot,
              Next, Projection, Target, PhaseIndex)
    end.

window_has_dtx([#entry{data = Data} | Rest]) ->
    case quod_ledger:classify(Data) of
        {controls, _Controls} -> true;
        {content, _} -> window_has_dtx(Rest);
        noop -> window_has_dtx(Rest);
        invalid -> window_has_dtx(Rest)
    end;
window_has_dtx([_Malformed | Rest]) ->
    window_has_dtx(Rest);
window_has_dtx(_) ->
    false.

open_phase_index(Ns, GenesisHash, LedgerRoot, From) ->
    case quod_dtx_phase_index:open(LedgerRoot, Ns) of
        {ok, PhaseIndex} ->
            case backfill_phase_index(
                   Ns, GenesisHash, LedgerRoot, From - 1, PhaseIndex) of
                ok ->
                    {ok, PhaseIndex};
                {error, _} = Error ->
                    _ = quod_dtx_phase_index:close(PhaseIndex),
                    Error
            end;
        {error, R} ->
            {error, {phase_index, R}}
    end.

backfill_phase_index(_Ns, _GenesisHash, _LedgerRoot, 0, _PhaseIndex) ->
    ok;
backfill_phase_index(Ns, GenesisHash, LedgerRoot, PrefixHeight, PhaseIndex) ->
    case quod_ledger_store:open_ro(Ns, LedgerRoot) of
        {ok, Store} ->
            try
                case quod_ledger_store:last(Store) >= PrefixHeight of
                    true ->
                        Projection = quod_simplex:history_projection(
                                       {Ns, GenesisHash}),
                        backfill_phase_windows(
                          Store, Ns, GenesisHash, 1, PrefixHeight,
                          Projection, PhaseIndex);
                    false ->
                        {error, {phase_index_backfill, incomplete_prefix}}
                end
            after
                quod_ledger_store:close(Store)
            end;
        {error, R} ->
            {error, {phase_index_backfill, R}}
    end.

backfill_phase_windows(_Store, _Ns, _GenesisHash, From, PrefixHeight,
                       _Projection, _PhaseIndex)
  when From > PrefixHeight ->
    ok;
backfill_phase_windows(Store, Ns, GenesisHash, From, PrefixHeight,
                       Projection, PhaseIndex) ->
    To = min(PrefixHeight, From + ?MAX_BLOCKS - 1),
    case quod_ledger_store:read_range(Store, From, To) of
        {ok, Entries} ->
            case verify_forward(
                   Ns, GenesisHash, Projection, From, Entries, PhaseIndex) of
                {ok, Verified, Projection1, Delta}
                  when length(Verified) =:= To - From + 1 ->
                    case quod_dtx_phase_index:commit_delta(PhaseIndex, Delta) of
                        ok ->
                            backfill_phase_windows(
                              Store, Ns, GenesisHash, To + 1,
                              PrefixHeight, Projection1, PhaseIndex);
                        {error, R} ->
                            {error, {phase_index_backfill, R}}
                    end;
                {ok, _Short, _Projection1, _Delta} ->
                    {error, {phase_index_backfill, incomplete_prefix}};
                {error, R} ->
                    {error, {phase_index_backfill, R}}
            end
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
    Chan = channel(Ns),
    quod_reg:subscribe({channel, Chan}),
    {ok, #s{ns = Ns, self = Self, chan = Chan,
            data_dir = quod_ledger_store:ledger_dir(Config),
            seeds = maps:get(seed_peers, Config, [])}}.

handle_call(contact, _From, S = #s{ns = Ns, seeds = Seeds}) ->
    {reply, quod_brahms:sample_contact(Ns, Seeds), S};
handle_call({contacts, Limit}, _From, S = #s{ns = Ns, seeds = Seeds}) ->
    {reply, contact_candidates(Ns, Seeds, Limit), S};
handle_call({pull, From, To, Contact}, ReplyTo, S) ->
    begin_pull(Contact, From, To, ReplyTo, S);
handle_call(stats, _From, S) ->
    {reply,
     #{client_pending => map_size(S#s.pending),
       client_pending_peak => S#s.pending_peak,
       server_inflight => map_size(S#s.inflight),
       server_inflight_peak => S#s.inflight_peak},
     S};
handle_call(_Req, _From, S) -> {reply, {error, unknown_call}, S}.

handle_cast({send_resp, OwnerRef, ReplyLink, Resp, Result}, S0) ->
    case maps:take(OwnerRef, S0#s.inflight) of
        {StartedMs, Inflight1} ->
            %% A certified page is protocol data, not a lossy freshness cue.
            %% Keep it on the request's authenticated link and let QUIC's
            %% send_ready event release transient flow-control pressure.
            ok = quod_link:send_ordered(
                   ReplyLink, encode_frame(S0#s.ns, Resp)),
            S1 = S0#s{inflight = Inflight1},
            {noreply,
             record_server_terminal(Result, elapsed_ms(StartedMs), S1)};
        error ->
            {noreply, S0}
    end;
handle_cast(_Msg, S) -> {noreply, S}.

handle_info(
  {quod_message, {PeerIdentity, ReplyLink}, Chan, Payload},
  S = #s{chan = Chan}) when is_pid(ReplyLink) ->
    case quod_link:peer_key(PeerIdentity) of
        undefined -> {noreply, S};
        Peer -> {noreply, inbound(Peer, ReplyLink, Payload, S)}
    end;
handle_info(
  {link_up, OpenRef, <<_:256>> = Peer, Chan, ReplyLink},
  S = #s{chan = Chan}) when is_reference(OpenRef), is_pid(ReplyLink) ->
    {noreply, finish_identified_open(OpenRef, Peer, ReplyLink, S)};
handle_info(
  {link_error, OpenRef, _Peer, Chan},
  S = #s{chan = Chan}) when is_reference(OpenRef) ->
    {noreply, fail_identified_open(OpenRef, S)};
handle_info({quod_message, _, _OtherChan, _}, S) -> {noreply, S};
handle_info({req_timeout, ReqId}, S) ->
    case maps:take(ReqId, S#s.pending) of
        {#client_pull{from = From, expected_peer = ExpectedPeer,
                      started_ms = StartedMs}, P1} ->
            gen_server:reply(From, {error, timeout}),
            S1 = S#s{pending = P1,
                     openings = drop_opening(ExpectedPeer, S#s.openings)},
            {noreply, record_client_terminal(
                        timeout, elapsed_ms(StartedMs), S1)};
        error -> {noreply, S}
    end;
handle_info(_Info, S) -> {noreply, S}.

terminate(_Reason, #s{chan = Chan}) ->
    _ = try quod_reg:unsubscribe({channel, Chan}) catch _:_ -> ok end,
    ok.

%%%===================================================================
%%% wire / dispatch
%%%===================================================================

inbound(_Peer, _ReplyLink, Payload, S)
  when byte_size(Payload) > ?QUOD_TRANSPORT_MAX_FRAME_BYTES ->
    S;   %% drop an oversized frame BEFORE decoding — bound binary_to_term memory (hostile peer)
inbound(Peer, ReplyLink, Payload, S) ->
    case decode_frame(S#s.ns, Payload) of
        {ok, Term, _Bytes} ->
            try route(Peer, ReplyLink, Term, S) catch _:_ -> S end;
        {error, _} -> S
    end.

route(_Peer, ReplyLink, {blocks_req, ReqId, From, To}, S) ->
    handle_req(ReplyLink, ReqId, From, To, S);
route(Peer, _ReplyLink, {blocks_resp, ReqId, Entries, Height}, S) ->
    handle_resp(Peer, ReqId, Entries, Height, S);
route(Peer, _ReplyLink, {blocks_err, ReqId}, S) ->
    handle_err(Peer, ReqId, S);
route(_Peer, _ReplyLink, _Other, S) -> S.

%% Server: read the requested range in a worker (never block the endpoint; concurrency-capped). Over the
%% cap ⇒ drop; the client times out and retries a fresher/other peer.
handle_req(ReplyLink, ReqId, From, To, S = #s{ns = Ns, data_dir = Dir})
  when is_integer(From), is_integer(To) ->
    case map_size(S#s.inflight) < ?MAX_INFLIGHT of
        false -> S;
        true  ->
            Self = self(),
            OwnerRef = make_ref(),
            StartedMs = quod_time:mono_ms(),
            %% The worker ALWAYS casts a response (whole body in try/catch), so `inflight` is decremented
            %% even if serve_blocks throws — otherwise a crashed worker would leak a slot and, after
            %% ?MAX_INFLIGHT such crashes, wedge the endpoint. An error sends a distinct `blocks_err` (never
            %% a misleading empty `{[], 0}` that a joiner would read as "namespace empty").
            _ = spawn(fun() ->
                          {Resp, Result} =
                              try case serve_blocks(Ns, Dir, From, To) of
                                      {ok, Es, H} ->
                                          {{blocks_resp, ReqId, Es, H}, completed};
                                      {error, _} ->
                                          {{blocks_err, ReqId}, error}
                                  end
                              catch _:_ -> {{blocks_err, ReqId}, error}
                              end,
                          gen_server:cast(
                            Self, {send_resp, OwnerRef, ReplyLink, Resp, Result})
                      end),
            Inflight1 = (S#s.inflight)#{OwnerRef => StartedMs},
            S#s{inflight = Inflight1,
                inflight_peak = max(S#s.inflight_peak, map_size(Inflight1))}
    end;
handle_req(_ReplyLink, _ReqId, _From, _To, S) ->
    S.   %% malformed range ⇒ drop; no owned row was admitted

%% Client: match a response to its parked caller.
handle_resp(Peer, ReqId, Entries, Height, S) ->
    reply_pending(Peer, ReqId, {ok, Entries, Height}, S).

%% Client: the server hit a read error (distinct from an empty log) — fail the pull so the caller retries
%% another contact rather than concluding the namespace is empty.
handle_err(Peer, ReqId, S) ->
    reply_pending(Peer, ReqId, {error, server_error}, S).

reply_pending(Peer, ReqId, Reply, S) ->
    case maps:get(ReqId, S#s.pending, undefined) of
        #client_pull{expected_peer = ExpectedPeer} ->
            case peer_matches(Peer, ExpectedPeer) of
                false -> S;   %% authenticated response, but not from the node this request targeted
                true  ->
                    {#client_pull{from = From, timer = TRef,
                                  started_ms = StartedMs}, P1} =
                        maps:take(ReqId, S#s.pending),
                    _ = erlang:cancel_timer(TRef),
                    gen_server:reply(From, Reply),
                    record_client_terminal(
                      terminal_result(Reply), elapsed_ms(StartedMs),
                      S#s{pending = P1})
            end;
        undefined -> S   %% unknown / already-timed-out ReqId
    end.

peer_matches(Peer, {bound, Peer}) -> true;
peer_matches(_Peer, {bound, _ExpectedPeer}) -> false.

begin_pull(Contact, From, To, ReplyTo, S = #s{ns = Ns, chan = Chan}) ->
    ReqId = make_ref(),
    StartedMs = quod_time:mono_ms(),
    Frame = encode_frame(Ns, {blocks_req, ReqId, From, To}),
    TRef = erlang:send_after(
             ?REQ_TIMEOUT_MS, self(), {req_timeout, ReqId}),
    case Contact of
        <<_:256>> = Peer ->
            ok = quod_quic:send(Peer, Chan, Frame),
            Pull = #client_pull{from = ReplyTo, timer = TRef,
                                expected_peer = {bound, Peer},
                                started_ms = StartedMs},
            {noreply, put_client_pull(ReqId, Pull, S)};
        _ ->
            case quod_quic:valid_endpoint(Contact) of
                true ->
                    OpenRef = quod_quic:open_link_identified(Contact, Chan),
                    Pull = #client_pull{from = ReplyTo, timer = TRef,
                                        expected_peer = {opening, OpenRef},
                                        started_ms = StartedMs},
                    Openings1 = (S#s.openings)#{
                                  OpenRef => {ReqId, Contact, Frame}},
                    S1 = put_client_pull(ReqId, Pull, S),
                    {noreply, S1#s{openings = Openings1}};
                false ->
                    _ = erlang:cancel_timer(TRef),
                    {reply, {error, bad_contact}, S}
            end
    end.

finish_identified_open(OpenRef, Peer, ReplyLink,
                       S = #s{openings = Openings, pending = Pending}) ->
    case maps:take(OpenRef, Openings) of
        {{ReqId, Endpoint, Frame}, Openings1} ->
            case maps:get(ReqId, Pending, undefined) of
                #client_pull{expected_peer = {opening, OpenRef}} = Pull ->
                    ok = quod_quic:learn(Peer, Endpoint),
                    ok = quod_link:send(ReplyLink, Frame),
                    Pending1 = Pending#{
                                 ReqId => Pull#client_pull{
                                            expected_peer = {bound, Peer}}},
                    S#s{pending = Pending1, openings = Openings1};
                _ ->
                    S#s{openings = Openings1}
            end;
        error ->
            S
    end.

fail_identified_open(OpenRef,
                     S = #s{openings = Openings, pending = Pending}) ->
    case maps:take(OpenRef, Openings) of
        {{ReqId, _Endpoint, _Frame}, Openings1} ->
            case maps:take(ReqId, Pending) of
                {#client_pull{from = From, timer = TRef,
                              expected_peer = {opening, OpenRef},
                              started_ms = StartedMs}, Pending1} ->
                    _ = erlang:cancel_timer(TRef),
                    gen_server:reply(From, {error, timeout}),
                    record_client_terminal(
                      link_down, elapsed_ms(StartedMs),
                      S#s{pending = Pending1, openings = Openings1});
                _ ->
                    S#s{openings = Openings1}
            end;
        error ->
            S
    end.

drop_opening({opening, OpenRef}, Openings) ->
    maps:remove(OpenRef, Openings);
drop_opening({bound, _Peer}, Openings) ->
    Openings.

put_client_pull(ReqId, Pull, S0) ->
    Pending1 = (S0#s.pending)#{ReqId => Pull},
    S0#s{pending = Pending1,
         pending_peak = max(S0#s.pending_peak, map_size(Pending1))}.

terminal_result({ok, _, _}) -> completed;
terminal_result({error, _}) -> error.

record_client_terminal(Result, DurationMs, S0) ->
    ok = quod_metrics:observe_ontology_owner_terminal(
           S0#s.ns, catchup_read, client, Result, DurationMs),
    S0.

record_server_terminal(Result, DurationMs, S0) ->
    ok = quod_metrics:observe_ontology_owner_terminal(
           S0#s.ns, catchup_read, server, Result, DurationMs),
    S0.

elapsed_ms(StartedMs) ->
    max(0, quod_time:mono_ms() - StartedMs).

%%%===================================================================
%%% transport
%%%===================================================================

%% A restarted node initially knows only addresses.  The identified dial binds
%% the server's TLS key to the seed endpoint before sending; the authenticated
%% request header likewise teaches the server the requester's hint.  Certified
%% history, not either routing hint, decides committee authority.  Keep
%% candidates endpoint-only and self-filtered: this is discovery, not trust.
contact_candidates(Ns, Seeds, Limit) ->
    SelfAddr = application:get_env(quod, node_addr, undefined),
    Pool = [P || P <- lists:usort(quod_brahms:sample(Ns) ++ Seeds), P =/= SelfAddr],
    quod_brahms:take_random(min(Limit, length(Pool)), Pool).
