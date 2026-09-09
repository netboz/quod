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
  log. One authenticated link grant admits one reader through ordered response
  acceptance. Concurrent logical requests remain in their producer's rows;
  range and frame bounds protect the byte grammar, not a worker population cap.
- **Client** (a joiner): `contact/1` samples ONE download contact — the live, self-filtered Brahms view
  first, the static seeds (minus this node's own `node_addr`) as the cold-start fallback
  (`quod_brahms:sample_contact/2`) — and `pull/4` requests `[From, To]` from it. The contact is STICKY for
  a whole catch-up run and re-sampled only on the next attempt (see `contact/1`). The caller (`mode=join`
  init) drives the loop and **verifies each block's cert** against the committee it reconstructs — the
  server is never trusted (the certificate is the proof).

Committed entries cross this channel only as their canonical byte envelopes.
The target endpoint decodes those bytes into its local view; a foreign-history
consumer keeps unknown application symbols opaque. Catch-up request ids are
random 128-bit binaries, so the bounded inner grammar needs no fleet-local
runtime terms or unsafe decoder. Trustlessness still comes from certificate
verification at the caller, never from the serving peer.
""".
-behaviour(gen_server).
-include("quod_ledger.hrl").
-include("quod_transport_limits.hrl").
-include("quod_proof_limits.hrl").

-export([start_link/2, contact/1, contacts/2, pull/4, serve_blocks/4, read_blocks/3, stats/1,
         channel/1, encode_frame/2, decode_frame/2, decode_entries/2, page_stats/1,
         verify_forward/5, verify_forward/6, verify_entry/3,
         catch_up/5, catch_up/7]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-ifdef(TEST).
-export([contact_candidates/3, test_recovery_state/1, test_hold_next_reader/3]).
-endif.

-define(REQ_TIMEOUT_MS,  8000).
-define(MAX_BLOCKS,      ?QUOD_MAX_FOREIGN_PAGE_ENTRIES).
-define(RESP_BUDGET,     ?QUOD_MAX_FOREIGN_PAGE_BYTES).
                                         %% frame MUST fit quod_link's 1 MiB cap (it EXITs the link on a
                                         %% larger frame), so we leave headroom for the envelope

-record(client_pull, {
          from :: gen_server:from(),
          timer :: reference(),
          caller_monitor :: reference(),
          contact :: term(),
          range :: {pos_integer(), log_index()},
          deadline :: integer(),
          sent = none :: none | {pid(), reference(), binary()},
          started_ms :: integer()
         }).

-record(binding, {ref :: reference(), contact, open_ref = none, link = none,
                  monitor = none, credit = none, active = none,
                  waiting = {[], []}, borrowers = #{}, retiring = false}).
-record(reader, {link :: pid(), link_monitor :: reference(), worker :: pid() | none,
                 monitor = none :: reference() | none, timer = none :: reference() | none,
                 source = none, result = none, retiring = false,
                 started_ms :: integer()}).

-record(s, {ns       :: binary(),
            chan     :: binary(),                       %% term_to_binary({catchup, Ns}, [deterministic])
            seeds    = []  :: [endpoint()],             %% static cold-start contacts (sample_contact fallback)
            pending  = #{} :: #{<<_:128>> => #client_pull{}},
                                      %% client: one exact owned row per pull
            pending_peak = 0 :: non_neg_integer(),
            openings = #{} :: #{reference() => term()},
            bindings = #{} :: #{term() => #binding{}},
            contacts = #{} :: #{term() => reference()},
            transport_monitor :: reference(),
            inflight = #{} :: #{reference() => #reader{}},
                                      %% server: one exact row per live read worker
            inflight_peak = 0 :: non_neg_integer()}).

-ifdef(TEST).
test_recovery_state(Pid) -> gen_server:call(Pid, test_recovery_state).
test_hold_next_reader(Pid, Point, TestPid) ->
    gen_server:call(Pid, {test_hold_next_reader, Point, TestPid}).
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
    Started = quod_time:mono_ms(),
    case quod_reg:where({quod_catchup, Ns}) of
        undefined -> {error, no_catchup_endpoint};
        Pid -> try gen_server:call(Pid, {pull, From, To, Contact, Started},
                                  ?REQ_TIMEOUT_MS + 1000)
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
    {ok, Term, _} = decode_wire_term(Term, 0),
    {ok, Inner} = quod_safe_term:encode_canonical(
                    Term, ?QUOD_TRANSPORT_MAX_FRAME_BYTES),
    {ok, Outer} = quod_safe_term:encode_canonical(
      {catchup, Ns, Inner},
      ?QUOD_TRANSPORT_MAX_FRAME_BYTES),
    Outer.

-doc "Decode one existing catch-up frame, returning its inner encoded byte count.".
-spec decode_frame(binary(), binary()) ->
          {ok, term(), non_neg_integer()} | {error, term()}.
decode_frame(Ns, Payload)
  when is_binary(Ns), is_binary(Payload),
       byte_size(Payload) =< ?QUOD_TRANSPORT_MAX_FRAME_BYTES ->
    case quod_safe_term:decode_wrapped(Payload, ?QUOD_TRANSPORT_MAX_FRAME_BYTES) of
        {ok, {catchup, Ns, Bin}}
          when is_binary(Bin),
               byte_size(Bin) =< ?QUOD_TRANSPORT_MAX_FRAME_BYTES ->
            case quod_safe_term:decode_wrapped(
                   Bin, ?QUOD_TRANSPORT_MAX_FRAME_BYTES) of
                {ok, WireTerm} ->
                    decode_wire_term(WireTerm, byte_size(Bin));
                {error, _} ->
                    {error, bad_frame}
            end;
        _ ->
            {error, bad_frame}
    end;
decode_frame(_Ns, _Payload) ->
    {error, frame_too_large}.

decode_wire_term({blocks_credit, <<_:128>> = Grant}, Bytes) ->
    {ok, {blocks_credit, Grant}, Bytes};
decode_wire_term({blocks_req, <<_:128>> = Grant, <<_:128>> = ReqId, From, To}, Bytes)
  when is_integer(From), From > 0, is_integer(To), To >= From ->
    {ok, {blocks_req, Grant, ReqId, From, To}, Bytes};
decode_wire_term(
  {blocks_resp_bytes, <<_:128>> = Grant, <<_:128>>,
   EntryBlobs, Height, <<_:128>> = Next} = Term, Bytes)
  when is_list(EntryBlobs), is_integer(Height), Height >= 0 ->
    case Grant =/= Next andalso valid_blob_page(EntryBlobs, 0, 0) of
        true -> {ok, Term, Bytes};
        false -> {error, bad_frame}
    end;
decode_wire_term(
  {blocks_err, <<_:128>> = Grant, <<_:128>>, Reason, <<_:128>> = Next} = Term, Bytes)
  when Grant =/= Next, (Reason =:= not_ready orelse Reason =:= server_error) ->
    {ok, Term, Bytes};
decode_wire_term(_Term, _Bytes) ->
    {error, bad_frame}.

valid_blob_page([], _Count, _Bytes) -> true;
valid_blob_page([Blob | Rest], Count, Bytes)
  when is_binary(Blob), Count < ?QUOD_MAX_FOREIGN_PAGE_ENTRIES,
       Bytes + byte_size(Blob) =< ?QUOD_MAX_FOREIGN_PAGE_BYTES ->
    valid_blob_page(Rest, Count + 1, Bytes + byte_size(Blob));
valid_blob_page(_, _, _) -> false.

%% The transport validates only opaque blob bounds. The receiving reader owns
%% this one decode, selecting local or wrapped vocabulary before verification.
-spec decode_entries([binary()], materialized | wrapped) ->
          {ok, [#entry{}]} | {error, bad_frame}.
decode_entries(Blobs, SymbolMode)
  when SymbolMode =:= materialized; SymbolMode =:= wrapped ->
    case valid_blob_page(Blobs, 0, 0) of
        true -> decode_entry_blobs(Blobs, SymbolMode, []);
        false -> {error, bad_frame}
    end.

decode_entry_blobs([Blob | Rest], SymbolMode, Acc) when is_binary(Blob) ->
    case quod_ledger:decode_entry(Blob, SymbolMode) of
        {ok, Entry} -> decode_entry_blobs(Rest, SymbolMode, [Entry | Acc]);
        {error, _} -> {error, bad_frame}
    end;
decode_entry_blobs([], _SymbolMode, Acc) ->
    {ok, lists:reverse(Acc)};
decode_entry_blobs(_Malformed, _SymbolMode, _Acc) ->
    {error, bad_frame}.

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
READ-ONLY store view. Returns the entries + the snapshot's captured committed height. Used by the server
worker; pure w.r.t. the gen_server (opens/closes its own handle).
""".
-spec serve_blocks(binary(), quod_ledger_store:session(), non_neg_integer(), log_index()) ->
        {ok, [#entry{}], log_index()} | {error, term()}.
serve_blocks(Ns, Snapshot, From, To) ->
    StartedNative = erlang:monotonic_time(),
    Result = serve_blocks_measured(Ns, Snapshot, From, To),
    observe_serve_stage(serve_read_total, Result, StartedNative),
    Result.

serve_blocks_measured(Ns, Snapshot, From, To) ->
    case measure_serve_stage(
           serve_snapshot_resume,
           fun() -> quod_ledger_store:open_ro_snapshot(Snapshot) end) of
        {error, _} = E -> E;
        {ok, Store}    ->
            try
                case quod_ledger_store:namespace(Store) of
                    Ns -> read_blocks(Store, From, To);
                    _ -> {error, wrong_namespace}
                end
            after quod_ledger_store:close(Store)
            end
    end.

%% Cold cache recovery already owns an opened store. It uses this same bounded
%% page reader directly, not a new open (and index scan) for each replay page.
-spec read_blocks(quod_ledger_store:handle(), non_neg_integer(), log_index()) ->
          {ok, [#entry{}], log_index()} | {error, term()}.
read_blocks(Store, From0, To) ->
    From = max(1, From0),
    try
        LastI = quod_ledger_store:last(Store),
        To1 = lists:min([To, LastI, From + ?MAX_BLOCKS - 1]),
        {ok, Es} = measure_serve_stage(
                     serve_range_read,
                     fun() -> quod_ledger_store:read_range(Store, From, To1) end),
        {ok, cap_bytes(Es, 0), LastI}
    catch _:R -> {error, R}
    end.

serve_hosted_blocks(Ns, From, To, Deadline, Owner, OperationRef) ->
    case measure_serve_stage(
           serve_snapshot_lookup,
           fun() -> quod_simplex:history_view(Ns, committed, Deadline) end) of
        {ok, #{snapshot := Snapshot} = View} ->
            case gen_server:call(Owner, {page_source, OperationRef, View},
                                 max(0, Deadline - quod_time:mono_ms())) of
                ok -> serve_blocks(Ns, Snapshot, From, To);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

measure_serve_stage(Stage, Fun) ->
    StartedNative = erlang:monotonic_time(),
    Result = Fun(),
    observe_serve_stage(Stage, Result, StartedNative),
    Result.

observe_serve_stage(Stage, Result, StartedNative) ->
    quod_metrics:observe_foreign_history_stage(
      Stage, serve_stage_result(Result),
      erlang:monotonic_time() - StartedNative).

serve_stage_result({ok, _}) -> ok;
serve_stage_result({ok, _, _}) -> ok;
serve_stage_result({error, _}) -> failed.

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
Projection)` atomically appends that verified window and returns `{ok, View}`:
the writer's immutable history view from that same turn.

`Options` contains the local `ledger_root` for scratch phase-index output only.
Resumed catch-up also carries the initial `history_view`, matching `From` and
`Projection`. Content-only catch-up never opens a phase index. On the first fetched DTX control, the driver
opens one session-unique phase index, backfills the exact already-sunk local
prefix from the retained writer snapshot, and retains the index for every remaining window. A window
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
                {ok, quod_simplex:history_view()} | {error, term()}),
        #{ledger_root := file:filename_all()}) ->
          {ok, log_index()} | {error, term()}.
catch_up(Ns, <<_:256>> = GenesisHash, Fetch, Sink,
         #{ledger_root := LedgerRoot})
  when is_binary(Ns), byte_size(Ns) > 0,
       is_function(Fetch, 1), is_function(Sink, 2) ->
    Projection = quod_simplex:history_projection({Ns, GenesisHash}),
    catch_up_loop(
      Ns, GenesisHash, Fetch, Sink, {LedgerRoot, none}, 1, Projection, 0, none);
catch_up(_Ns, _GenesisHash, _Fetch, _Sink, _Options) ->
    {error, bad_catchup_options}.

-spec catch_up(
        binary(), binary(),
        fun((pos_integer()) ->
                {ok, [#entry{}], log_index()} | {error, term()}),
        fun(([#entry{}], quod_simplex:history_projection()) ->
                {ok, quod_simplex:history_view()} | {error, term()}),
        pos_integer(), quod_simplex:history_projection(),
        #{ledger_root := file:filename_all(),
          history_view := quod_simplex:history_view()}) ->
          {ok, log_index()} | {error, term()}.
catch_up(Ns, <<_:256>> = GenesisHash, Fetch, Sink, From, Projection,
         #{ledger_root := LedgerRoot,
           history_view := #{identity := {Ns, GenesisHash}, slot := Height,
                             owner := Owner, snapshot := _,
                             projection := Projection} = View})
  when is_binary(Ns), byte_size(Ns) > 0,
       is_function(Fetch, 1), is_function(Sink, 2),
       is_integer(From), From >= 1, From =:= Height + 1,
       is_map(Projection), is_pid(Owner) ->
    catch_up_loop(
      Ns, GenesisHash, Fetch, Sink, {LedgerRoot, View},
      From, Projection, 0, none);
catch_up(_Ns, _GenesisHash, _Fetch, _Sink, _From, _Projection, _Options) ->
    {error, bad_catchup_options}.

catch_up_loop(Ns, GenesisHash, Fetch, Sink, Context,
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
                      Ns, GenesisHash, Fetch, Sink, Context,
                      From, Projection, Target, Entries, PhaseIndex)
            end;
        _MalformedResponse ->
            {error, {fetch, bad_response}}
    end.

catch_up_entries(Ns, GenesisHash, Fetch, Sink, Context,
                 From, Projection, Target, Entries, none) ->
    case window_has_dtx(Entries) of
        false ->
            catch_up_content_window(
              Ns, GenesisHash, Fetch, Sink, Context,
              From, Projection, Target, Entries);
        true ->
            case open_phase_index(Ns, GenesisHash, Context, From) of
                {ok, PhaseIndex} ->
                    try
                        catch_up_phase_window(
                          Ns, GenesisHash, Fetch, Sink, Context,
                          From, Projection, Target, Entries, PhaseIndex)
                    after
                        _ = quod_dtx_phase_index:close(PhaseIndex)
                    end;
                {error, _} = Error ->
                    Error
            end
    end;
catch_up_entries(Ns, GenesisHash, Fetch, Sink, Context,
                 From, Projection, Target, Entries, PhaseIndex) ->
    catch_up_phase_window(
      Ns, GenesisHash, Fetch, Sink, Context,
      From, Projection, Target, Entries, PhaseIndex).

catch_up_content_window(Ns, GenesisHash, Fetch, Sink, Context,
                        From, Projection, Target, Entries) ->
    case verify_forward(Ns, GenesisHash, Projection, From, Entries) of
        {ok, Verified, Projection1} ->
            case sink_window(Sink, Verified, Projection1, Context,
                             {Ns, GenesisHash}) of
                {ok, NextContext} ->
                    continue_catch_up(
                      Ns, GenesisHash, Fetch, Sink,
                      NextContext,
                      From, Verified, Projection1, Target, none);
                {error, R} ->
                    {error, {sink, R}}
            end;
        {error, bad_anchor} ->
            {error, bad_anchor};
        {error, R} ->
            {error, {verify, R}}
    end.

catch_up_phase_window(Ns, GenesisHash, Fetch, Sink, Context,
                      From, Projection, Target, Entries, PhaseIndex) ->
    case verify_forward(
           Ns, GenesisHash, Projection, From, Entries, PhaseIndex) of
        {ok, Verified, Projection1, Delta} ->
            case sink_window(Sink, Verified, Projection1, Context,
                             {Ns, GenesisHash}) of
                {ok, NextContext} ->
                    case quod_dtx_phase_index:commit_delta(PhaseIndex, Delta) of
                        ok ->
                            continue_catch_up(
                              Ns, GenesisHash, Fetch, Sink,
                              NextContext,
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

%% Bind the sink acknowledgement to the exact window and original writer.
%% This is source coherence, not a second certificate check: verify_forward
%% remains the one verifier, and the writer remains the one append owner.
sink_window(Sink, Verified, Projection, {Scratch, Previous}, Identity) ->
    Height = (lists:last(Verified))#entry.index,
    Head = maps:get(history_head, Projection),
    case Sink(Verified, Projection) of
        {ok, #{owner := Owner, identity := Identity, slot := Height,
               snapshot := _, projection := #{history_head := Head}} = View}
          when is_pid(Owner) ->
            %% The verifier retains historical committee eras; the live
            %% writer retains its current era only. Their map representations
            %% need not match. Bind the immutable committed head, not that
            %% historical bookkeeping, and keep the verifier's own projection.
            case Previous of
                none -> {ok, {Scratch, View}};
                #{owner := Owner} -> {ok, {Scratch, View}};
                _ -> {error, invalid_history_view}
            end;
        {error, _} = Error -> Error;
        _ -> {error, invalid_history_view}
    end.

continue_catch_up(Ns, GenesisHash, Fetch, Sink, Context,
                  From, Verified, Projection, Target, PhaseIndex) ->
    Next = From + length(Verified),
    case Next > Target of
        true ->
            {ok, Target};
        false ->
            catch_up_loop(
              Ns, GenesisHash, Fetch, Sink, Context,
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

open_phase_index(Ns, GenesisHash, {LedgerRoot, View}, From) ->
    case quod_dtx_phase_index:open(LedgerRoot, Ns) of
        {ok, PhaseIndex} ->
            case backfill_phase_index(
                   Ns, GenesisHash, View, From - 1, PhaseIndex) of
                ok ->
                    {ok, PhaseIndex};
                {error, _} = Error ->
                    _ = quod_dtx_phase_index:close(PhaseIndex),
                    Error
            end;
        {error, R} ->
            {error, {phase_index, R}}
    end.

backfill_phase_index(_Ns, _GenesisHash, _View, 0, _PhaseIndex) ->
    ok;
backfill_phase_index(Ns, GenesisHash,
                     #{identity := {Ns, GenesisHash}, slot := PrefixHeight,
                       snapshot := Snapshot}, PrefixHeight, PhaseIndex) ->
    case quod_ledger_store:open_ro_snapshot(Snapshot) of
        {ok, Store} ->
            try
                case quod_ledger_store:namespace(Store) =:= Ns andalso
                     quod_ledger_store:last(Store) =:= PrefixHeight of
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
    end;
backfill_phase_index(_Ns, _GenesisHash, _View, _PrefixHeight, _PhaseIndex) ->
    {error, {phase_index_backfill, invalid_history_view}}.

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
    process_flag(trap_exit, true),
    TransportMonitor = quod_reg:monitor_name({transport, node}, follow),
    {ok, #s{ns = Ns, chan = channel(Ns),
            transport_monitor = TransportMonitor,
            seeds = maps:get(seed_peers, Config, [])}}.

handle_call(contact, _From, S = #s{ns = Ns, seeds = Seeds}) ->
    {reply, quod_brahms:sample_contact(Ns, Seeds), S};
handle_call({contacts, Limit}, _From, S = #s{ns = Ns, seeds = Seeds}) ->
    {reply, contact_candidates(Ns, Seeds, Limit), S};
handle_call({pull, From, To, Contact, Started}, ReplyTo, S) ->
    begin_pull(Contact, From, To, Started, ReplyTo, S);
handle_call({page_source, Op, View}, {Worker, _}, S0) ->
    case maps:get(Op, S0#s.inflight, undefined) of
        #reader{worker = Worker, source = none, retiring = false} = Row ->
            case Row#reader.started_ms + ?REQ_TIMEOUT_MS > quod_time:mono_ms() andalso
                 is_process_alive(Worker) andalso quod_simplex:history_view_live(View) of
                true ->
                    Source = maps:get(owner, View),
                    MRef = erlang:monitor(process, Source, [{tag, {page_source_down, Op}}]),
                    {reply, ok, S0#s{inflight = (S0#s.inflight)#{
                                     Op => Row#reader{source =
                                       {Source, maps:get(identity, View), MRef}}}}};
                false -> {reply, {error, not_ready}, S0}
            end;
        _ -> {reply, {error, not_ready}, S0}
    end;
handle_call(stats, _From, S) ->
    {reply, #{client_pending => map_size(S#s.pending),
              client_pending_peak => S#s.pending_peak,
              server_inflight => map_size(S#s.inflight),
              server_inflight_peak => S#s.inflight_peak}, S};
handle_call(Request, _From, S) -> test_call(Request, S).

-ifdef(TEST).
test_call(test_recovery_state, S) ->
    {reply, #{openings => S#s.openings, contacts => S#s.contacts,
              bindings => maps:map(
                fun(_, B) -> #{open_ref => B#binding.open_ref, link => B#binding.link,
                               retiring => B#binding.retiring,
                               borrowers => map_size(B#binding.borrowers),
                               waiting => queue:len(B#binding.waiting),
                               active => B#binding.active} end,
                S#s.bindings),
              readers => maps:map(
                fun(_, R) -> #{worker => R#reader.worker, link => R#reader.link,
                               result => R#reader.result, retiring => R#reader.retiring} end,
                S#s.inflight)}, S};
test_call({test_hold_next_reader, Point, TestPid}, S)
  when (Point =:= before_read orelse Point =:= after_result), is_pid(TestPid) ->
    put({?MODULE, reader_gate}, {Point, TestPid}),
    {reply, ok, S};
test_call(_, S) -> {reply, {error, unknown_call}, S}.

take_reader_gate() -> erase({?MODULE, reader_gate}).
reader_gate(Point, {Point, TestPid}, Op) ->
    TestPid ! {reader_held, self(), Op, Point},
    receive {release_reader, Op} -> ok end;
reader_gate(_, _, _) -> ok.
-else.
test_call(_, S) -> {reply, {error, unknown_call}, S}.
take_reader_gate() -> none.
reader_gate(_, _, _) -> ok.
-endif.

handle_cast(_Msg, S) -> {noreply, S}.

handle_info({catchup_request, Link, Op, From, To, StartedMs}, S)
  when is_pid(Link), is_reference(Op), is_integer(From), From > 0,
       is_integer(To), To >= From, is_integer(StartedMs) ->
    {noreply, start_reader(Link, Op, From, To, StartedMs, S)};
handle_info({reader_result, Op, Worker, Result}, S0) ->
    case maps:get(Op, S0#s.inflight, undefined) of
        #reader{worker = Worker, result = none, retiring = false} = Row ->
            {noreply, put_reader(Op, Row#reader{result = Result}, S0)};
        _ -> {noreply, S0}
    end;
handle_info({catchup_page_sent, Link, Op}, S0) ->
    case maps:get(Op, S0#s.inflight, undefined) of
        #reader{link = Link, worker = none, result = Result} = Row ->
            {noreply, retire_reader(Op, Row, terminal_result(Result), S0)};
        _ -> {noreply, S0}
    end;
handle_info({page_deadline, Op}, S0) ->
    {noreply, cancel_reader(Op, {error, not_ready}, false, S0)};
handle_info({{page_source_down, Op}, MRef, process, Source, _}, S0) ->
    case maps:get(Op, S0#s.inflight, undefined) of
        #reader{source = {Source, _Identity, MRef}} ->
            {noreply, cancel_reader(Op, {error, not_ready}, false, S0)};
        _ -> {noreply, S0}
    end;
handle_info({{page_worker_down, Op}, MRef, process, Worker, _}, S0) ->
    {noreply, reader_down(Op, MRef, Worker, S0)};
handle_info({{page_link_down, Op}, MRef, process, Link, _}, S0) ->
    case maps:get(Op, S0#s.inflight, undefined) of
        #reader{link = Link, link_monitor = MRef} ->
            {noreply, cancel_reader(Op, {error, server_error}, true, S0)};
        _ -> {noreply, S0}
    end;
handle_info({link_up, OpenRef, Peer, Chan, Link}, S = #s{chan = Chan})
  when is_reference(OpenRef), is_pid(Link) ->
    {noreply, finish_open(OpenRef, Peer, Link, S)};
handle_info({link_error, OpenRef, _Peer, Chan}, S = #s{chan = Chan}) ->
    {noreply, fail_open(OpenRef, S)};
handle_info({catchup_credit, Link, Ref, Grant}, S0) ->
    case maps:get(Ref, S0#s.bindings, undefined) of
        #binding{link = Link, retiring = false, active = none, credit = none} = B ->
            {noreply, drive_binding(Ref, put_binding(B#binding{credit = Grant}, S0))};
        _ -> {noreply, S0}
    end;
handle_info({catchup_page, Link, Ref, Grant, ReqId, Result, NextGrant}, S0) ->
    {noreply, finish_page(Link, Ref, Grant, ReqId, Result, NextGrant, S0)};
handle_info({req_timeout, ReqId}, S) ->
    {noreply, cancel_pull(ReqId, {error, timeout}, S)};
handle_info({{pull_caller_down, ReqId}, MRef, process, _Pid, _}, S) ->
    case maps:get(ReqId, S#s.pending, undefined) of
        #client_pull{caller_monitor = MRef} ->
            {noreply, cancel_pull(ReqId, {error, caller_down}, S)};
        _ -> {noreply, S}
    end;
handle_info({{catchup_borrower_down, Ref, Caller}, MRef, process, Caller, _}, S0) ->
    {noreply, borrower_down(Ref, Caller, MRef, S0)};
handle_info({{catchup_link_down, Ref}, MRef, process, Link, _}, S0) ->
    {noreply, binding_down(Ref, MRef, Link, S0)};
handle_info({gproc, unreg, Monitor, _}, S = #s{transport_monitor = Monitor}) ->
    {noreply, retire_transport(S)};
handle_info({gproc, registered, Monitor, _}, S = #s{transport_monitor = Monitor}) ->
    {noreply, maps:fold(fun(Ref, _, Acc) -> ensure_open(Ref, Acc) end, S, S#s.bindings)};
%% Linked reader faults are retired by the corresponding monitored DOWN only.
handle_info({'EXIT', _Pid, _Reason}, S) -> {noreply, S};
handle_info(_Info, S) -> {noreply, S}.

terminate(_Reason, S) ->
    _ = catch quod_reg:demonitor_name({transport, node}, S#s.transport_monitor),
    maps:foreach(fun(_, B) -> close_binding(B) end, S#s.bindings),
    maps:foreach(fun(_, R) ->
        case R#reader.worker of none -> ok; Pid -> exit(Pid, kill) end,
        quod_link:close(R#reader.link),
        cleanup_reader(R)
    end, S#s.inflight),
    maps:foreach(fun(_, P) ->
        cancel_timer(P#client_pull.timer),
        erlang:demonitor(P#client_pull.caller_monitor, [flush]),
        gen_server:reply(P#client_pull.from, {error, unavailable})
    end, S#s.pending),
    ok.

start_reader(Link, Op, From, To, Started, S = #s{ns = Ns}) ->
    %% The link has already spent its one grant. There is no population cap.
    %% The linked worker and its exact row survive result delivery until DOWN.
    case maps:is_key(Op, S#s.inflight) orelse not is_process_alive(Link) of
        true -> S;
        false ->
            Deadline = Started + ?REQ_TIMEOUT_MS,
            LinkMonitor = erlang:monitor(process, Link, [{tag, {page_link_down, Op}}]),
            Row = #reader{link = Link, link_monitor = LinkMonitor,
                          worker = none, started_ms = Started},
            case Deadline =< quod_time:mono_ms() of
                true -> send_reader_result(Op, Row#reader{result = {error, not_ready}}, S);
                false -> spawn_reader(Ns, Op, From, To, Deadline, Row, S)
            end
    end.

spawn_reader(Ns, Op, From, To, Deadline, Row, S) ->
            Owner = self(),
            Gate = take_reader_gate(),
            {Worker, MRef} = spawn_opt(fun() ->
                reader_gate(before_read, Gate, Op),
                Result = try
                    case serve_hosted_blocks(Ns, From, To, Deadline, Owner, Op) of
                        {ok, Entries, Height} ->
                            {ok, Blobs} = measure_serve_stage(serve_encode,
                              fun() ->
                                  {ok, [begin {ok, Blob} = quod_ledger:encode_entry(E), Blob end
                                        || E <- Entries]}
                              end),
                            {ok, Blobs, Height};
                        {error, _} -> {error, not_ready}
                    end
                catch _:_ -> {error, server_error}
                end,
                Owner ! {reader_result, Op, self(), Result},
                reader_gate(after_result, Gate, Op)
            end, [link, {monitor, [{tag, {page_worker_down, Op}}]}]),
            Timer = erlang:send_after(max(0, Deadline - quod_time:mono_ms()),
                                     self(), {page_deadline, Op}),
            put_reader(Op, Row#reader{worker = Worker, monitor = MRef, timer = Timer}, S).

put_reader(Op, R, S) ->
    Rows = (S#s.inflight)#{Op => R},
    S#s{inflight = Rows, inflight_peak = max(S#s.inflight_peak, map_size(Rows))}.

reader_down(Op, MRef, Worker, S) ->
    case maps:get(Op, S#s.inflight, undefined) of
        #reader{worker = Worker, monitor = MRef} = Row0 ->
            Result = case reader_result_live(Row0) of
                false -> {error, not_ready};
                true -> case Row0#reader.result of
                            none -> {error, server_error}; R -> R
                        end
            end,
            cleanup_source(Row0#reader.source),
            cancel_timer(Row0#reader.timer),
            Row = Row0#reader{worker = none, source = none, timer = none, result = Result},
            send_reader_result(Op, Row, S);
        _ -> S
    end.

send_reader_result(Op, Row, S) ->
    case Row#reader.retiring orelse not is_process_alive(Row#reader.link) of
        true -> retire_reader(Op, Row, link_down, S);
        false ->
            quod_link:complete_page(Row#reader.link, Op, Row#reader.result),
            put_reader(Op, Row, S)
    end.

reader_result_live(#reader{started_ms = Started, source = Source}) ->
    Started + ?REQ_TIMEOUT_MS > quod_time:mono_ms() andalso
    case Source of
        none -> true;
        {Pid, Identity, _} ->
            quod_simplex:history_view_live(#{owner => Pid, identity => Identity})
    end.

cancel_reader(Op, Result, Retiring, S) ->
    case maps:get(Op, S#s.inflight, undefined) of
        #reader{worker = none} = Row when Retiring ->
            retire_reader(Op, Row, link_down, S);
        #reader{worker = none} -> S;
        #reader{worker = Worker} = Row ->
            exit(Worker, kill),
            put_reader(Op, Row#reader{result = Result,
                                     retiring = Retiring orelse Row#reader.retiring}, S);
        _ -> S
    end.

cleanup_source({_, _, MRef}) -> erlang:demonitor(MRef, [flush]), ok;
cleanup_source(none) -> ok.
cancel_timer(none) -> ok;
cancel_timer(Ref) -> _ = erlang:cancel_timer(Ref), ok.
cleanup_reader(R) ->
    cancel_timer(R#reader.timer),
    cleanup_source(R#reader.source),
    case R#reader.monitor of none -> ok; MRef -> erlang:demonitor(MRef, [flush]) end,
    erlang:demonitor(R#reader.link_monitor, [flush]),
    ok.
retire_reader(Op, Row, Result, S) ->
    cleanup_reader(Row),
    record_server_terminal(Result, elapsed_ms(Row#reader.started_ms),
                           S#s{inflight = maps:remove(Op, S#s.inflight)}).

begin_pull(Contact, From, To, Started, ReplyTo, S0)
  when is_integer(From), From > 0, is_integer(To), To >= From,
       is_integer(Started) ->
    case is_binary(Contact) andalso byte_size(Contact) =:= 32 orelse
         quod_quic:valid_endpoint(Contact) of
        false -> {reply, {error, bad_contact}, S0};
        true ->
            Deadline = Started + ?REQ_TIMEOUT_MS,
            Remaining = Deadline - quod_time:mono_ms(),
            Caller = element(1, ReplyTo),
            case {Remaining > 0, is_process_alive(Caller)} of
                {false, _} -> {reply, {error, timeout}, S0};
                {true, false} -> {reply, {error, caller_down}, S0};
                {true, true} ->
                    ReqId = crypto:strong_rand_bytes(16),
                    Timer = erlang:send_after(max(0, Deadline - quod_time:mono_ms()),
                                              self(), {req_timeout, ReqId}),
                    MRef = erlang:monitor(process, Caller,
                                          [{tag, {pull_caller_down, ReqId}}]),
                    {Ref, S1} = ensure_binding(Contact, Caller, S0),
                    B = maps:get(Ref, S1#s.bindings),
                    Pull = #client_pull{from = ReplyTo, timer = Timer,
                                        caller_monitor = MRef, contact = Contact,
                                        range = {From, To}, deadline = Deadline,
                                        started_ms = Started},
                    S2 = put_client_pull(ReqId, Pull,
                           put_binding(B#binding{waiting = queue:in(ReqId, B#binding.waiting)}, S1)),
                    {noreply, drive_binding(Ref, ensure_open(Ref, S2))}
            end
    end;
begin_pull(_, _, _, _, _, S) -> {reply, {error, bad_range}, S}.

ensure_binding(Contact, Caller, S) ->
    case maps:find(Contact, S#s.contacts) of
        {ok, Ref} -> {Ref, retain_borrower(Ref, Caller, S)};
        error ->
            Ref = make_ref(),
            {Ref, retain_borrower(Ref, Caller,
                    put_binding(#binding{ref = Ref, contact = Contact},
                                S#s{contacts = (S#s.contacts)#{Contact => Ref}}))}
    end.
put_binding(B, S) -> S#s{bindings = (S#s.bindings)#{B#binding.ref => B}}.

%% All production pull callers are the existing recovery/feed pull workers.
%% Their lifetime spans the gaps between pages of one catch-up run. Retaining
%% that exact borrower, not a clock or the namespace's lifetime, keeps its
%% stream usable between pages and releases the binding when the run ends.
retain_borrower(Ref, Caller, S) ->
    B = maps:get(Ref, S#s.bindings),
    case maps:is_key(Caller, B#binding.borrowers) of
        true -> S;
        false ->
            MRef = erlang:monitor(process, Caller,
                                 [{tag, {catchup_borrower_down, Ref, Caller}}]),
            put_binding(B#binding{borrowers = (B#binding.borrowers)#{Caller => MRef}}, S)
    end.

borrower_down(Ref, Caller, MRef, S0) ->
    case maps:get(Ref, S0#s.bindings, undefined) of
        #binding{borrowers = Borrowers} = B ->
            case maps:get(Caller, Borrowers, none) of
                MRef ->
                    S1 = put_binding(B#binding{borrowers = maps:remove(Caller, Borrowers)}, S0),
                    Owned = [Id || {Id, #client_pull{from = {Pid, _}, contact = Contact}} <-
                                       maps:to_list(S1#s.pending),
                                   Pid =:= Caller, Contact =:= B#binding.contact],
                    S2 = lists:foldl(fun(Id, Acc) ->
                                        cancel_pull(Id, {error, caller_down}, Acc)
                                    end, S1, Owned),
                    release_unused_binding(Ref, S2);
                _ -> S0
            end;
        _ -> S0
    end.

release_unused_binding(Ref, S0) ->
    case maps:get(Ref, S0#s.bindings, undefined) of
        #binding{borrowers = Borrowers, link = Link} = B when map_size(Borrowers) =:= 0 ->
            case Link of
                none when B#binding.open_ref =:= none -> remove_binding(B, S0);
                none -> put_binding(B#binding{retiring = true}, S0);
                _ -> quod_link:close(Link), put_binding(B#binding{retiring = true, credit = none}, S0)
            end;
        _ -> S0
    end.

remove_binding(B, S) ->
    S#s{bindings = maps:remove(B#binding.ref, S#s.bindings),
        contacts = maps:remove(B#binding.contact, S#s.contacts),
        openings = maps:remove(B#binding.open_ref, S#s.openings)}.

ensure_open(Ref, S) ->
    case maps:get(Ref, S#s.bindings) of
        #binding{link = none, open_ref = none, retiring = false, contact = Contact,
                 waiting = Waiting} = B ->
            case queue:is_empty(Waiting) orelse quod_reg:where({transport, node}) =:= undefined of
                true -> S;
                false ->
                    OpenRef = case Contact of
                        <<_:256>> -> quod_quic:open_link_tagged(Contact, S#s.chan);
                        _ -> quod_quic:open_link_identified(Contact, S#s.chan)
                    end,
                    put_binding(B#binding{open_ref = OpenRef},
                                S#s{openings = (S#s.openings)#{OpenRef => Ref}})
            end;
        _ -> S
    end.

finish_open(OpenRef, Peer, Link, S0) ->
    case maps:take(OpenRef, S0#s.openings) of
        {Ref, Openings} ->
            case maps:get(Ref, S0#s.bindings, undefined) of
                #binding{open_ref = OpenRef, contact = Contact} = B ->
                    case Contact of <<_:256>> -> ok; _ -> quod_quic:learn(Peer, Contact) end,
                    MRef = erlang:monitor(process, Link, [{tag, {catchup_link_down, Ref}}]),
                    S1 = put_binding(B#binding{open_ref = none, link = Link, monitor = MRef},
                                     S0#s{openings = Openings}),
                    case B#binding.retiring of
                        true -> quod_link:close(Link), S1;
                        false -> quod_link:bind_catchup(Link, Ref), S1
                    end;
                _ -> S0#s{openings = Openings}
            end;
        error -> S0
    end.

fail_open(OpenRef, S0) ->
    case maps:take(OpenRef, S0#s.openings) of
        {Ref, Openings} ->
            B = maps:get(Ref, S0#s.bindings),
            S1 = put_binding(B#binding{open_ref = none, waiting = queue:new(), retiring = false},
                             S0#s{openings = Openings}),
            release_unused_binding(Ref,
              lists:foldl(fun(Id, S) -> complete_pull(Id, {error, link_down}, S) end,
                          S1, queue:to_list(B#binding.waiting)));
        error -> S0
    end.

drive_binding(Ref, S0) ->
    case maps:get(Ref, S0#s.bindings) of
        #binding{link = Link, credit = Grant, active = none,
                 retiring = false, waiting = Waiting} = B
          when is_pid(Link), is_binary(Grant) ->
            case queue:out(Waiting) of
                {empty, _} -> S0;
                {{value, ReqId}, Rest} ->
                    S1 = put_binding(B#binding{waiting = Rest}, S0),
                    case maps:get(ReqId, S1#s.pending, undefined) of
                        undefined -> drive_binding(Ref, S1);
                        #client_pull{range = {From, To}} = P ->
                            case P#client_pull.deadline =< quod_time:mono_ms() of
                                true -> drive_binding(Ref, complete_pull(ReqId, {error, timeout}, S1));
                                false ->
                                    quod_link:request_page(Link, Ref, Grant, ReqId, From, To),
                                    Pending = (S1#s.pending)#{ReqId => P#client_pull{
                                                sent = {Link, Ref, Grant}}},
                                    put_binding(B#binding{waiting = Rest, active = ReqId, credit = none},
                                                S1#s{pending = Pending})
                            end
                    end
            end;
        _ -> S0
    end.

finish_page(Link, Ref, Grant, ReqId, Result, NextGrant, S0) ->
    case {maps:get(Ref, S0#s.bindings, undefined), maps:get(ReqId, S0#s.pending, undefined)} of
        {#binding{link = Link, active = ReqId, retiring = false} = B,
         #client_pull{sent = {Link, Ref, Grant}, deadline = Deadline}} ->
            case Deadline > quod_time:mono_ms() of
              false -> cancel_pull(ReqId, {error, timeout}, S0);
              true ->
               Reply = case Result of
                {ok, Blobs, Height} ->
                    case decode_entries(Blobs, materialized) of
                        {ok, Entries} -> {ok, Entries, Height};
                        {error, _} -> {error, malformed_page}
                    end;
                {error, Reason} -> {error, Reason}
            end,
            S1 = complete_pull(ReqId, Reply, S0),
               drive_binding(Ref, put_binding(B#binding{active = none, credit = NextGrant}, S1))
            end;
        _ -> S0
    end.

complete_pull(ReqId, Reply, S) ->
    case maps:take(ReqId, S#s.pending) of
        {P, Pending} ->
            cancel_timer(P#client_pull.timer),
            erlang:demonitor(P#client_pull.caller_monitor, [flush]),
            gen_server:reply(P#client_pull.from, Reply),
            record_client_terminal(terminal_result(Reply), elapsed_ms(P#client_pull.started_ms),
                                   S#s{pending = Pending});
        error -> S
    end.

cancel_pull(ReqId, Reply, S0) ->
    case maps:get(ReqId, S0#s.pending, undefined) of
        #client_pull{sent = {Link, Ref, _}} ->
            B = maps:get(Ref, S0#s.bindings),
            quod_link:close(Link),
            put_binding(B#binding{retiring = true, credit = none},
                        complete_pull(ReqId, Reply, S0));
        #client_pull{contact = Contact} ->
            Ref = maps:get(Contact, S0#s.contacts),
            B = maps:get(Ref, S0#s.bindings),
            Waiting = queue:filter(fun(Id) -> Id =/= ReqId end, B#binding.waiting),
            drive_binding(Ref, put_binding(B#binding{waiting = Waiting},
                                          complete_pull(ReqId, Reply, S0)));
        undefined -> S0
    end.

binding_down(Ref, MRef, Link, S0) ->
    case maps:get(Ref, S0#s.bindings, undefined) of
        #binding{link = Link, monitor = MRef, active = Active} = B ->
            S1 = case Active of none -> S0; _ -> complete_pull(Active, {error, link_down}, S0) end,
            S2 = put_binding(B#binding{link = none, monitor = none,
                                      active = none, credit = none, retiring = false}, S1),
            case map_size(B#binding.borrowers) of
                0 -> remove_binding(B, S2);
                _ -> ensure_open(Ref, S2)
            end;
        _ -> S0
    end.
close_binding(B) ->
    maps:foreach(fun(_, MRef) -> erlang:demonitor(MRef, [flush]) end, B#binding.borrowers),
    case B#binding.link of Link when is_pid(Link) -> quod_link:close(Link); _ -> ok end.
retire_transport(S0) ->
    maps:fold(fun(_Ref, B, S) ->
        case B#binding.link of
            none when map_size(B#binding.borrowers) =:= 0 -> remove_binding(B, S);
            none -> put_binding(B#binding{open_ref = none, retiring = false}, S);
            Link -> quod_link:close(Link),
                    put_binding(B#binding{credit = none, retiring = true}, S)
        end
    end, S0#s{openings = #{}}, S0#s.bindings).

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
