-module(quod_catchup).
-moduledoc """
The existing per-namespace certified-history endpoint and shared proof verifier.

The server captures one immutable archive view from Simplex and streams
complete proof/material groups through bounded, credited pages. One retained
reader owns that source descriptor and cursor across continuations, under its
original deadline and exact source/link lifetimes. An entry-only response is
not a proof format: empty protocol carriers live in the selected witness and
never become material ledger rows.

The existing recovery, foreign-history or observer worker consumes each page,
verifies the descendant-to-prefix ancestry and transactions once, then hands
complete groups to its existing writer. A staging file is temporary, unlinked
before bytes are written and closed on worker death. Append acknowledgement
precedes staging reuse, projection publication and journal custody release.
Transport receipt or caller-supplied witness preference grants no authority.

`pull/5` retains page credit through the calling worker's consumption. `catch_up/7`
drives the same group verifier for hosted recovery and observers, pinning the
original owner and returning its installed views between groups. Foreign jobs
thread their existing cache cursor through `range_begin/7` and `range_accept/5`.
Local consumers materialize application symbols; foreign readers retain the
wrapped vocabulary. All finality uses the caller-pinned namespace/genesis
identity and the historical certifying committee, never the serving peer.
""".
-behaviour(gen_server).
-include("quod_ledger.hrl").
-include("quod_transport_limits.hrl").
-include("quod_proof_limits.hrl").

-export([start_link/2, contact/1, contacts/2, pull/5, read_blocks/3, stats/1,
         channel/1, encode_frame/2, decode_frame/2,
         finality_begin/3, finality_block/2, verify_finality/4, verify_forward_group/5,
         transfer_open/3, transfer_page/2, transfer_begin/6, transfer_accept/3,
         range_begin/7, range_accept/5, range_context/1,
         catch_up/7]).
-export_type([finality_cursor/0, transfer/0, transfer_sender/0, range_receiver/0]).
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
          from :: gen_server:from() | none,
          caller :: pid(),
          timer :: reference(),
          caller_monitor :: reference(),
          contact :: term(),
          query :: term(),
          deadline :: integer(),
          sent = none :: none | {pid(), reference(), binary()} |
                              {decoding, pid(), reference(), binary(), binary()},
          started_ms :: integer()
         }).

-record(binding, {ref :: reference(), contact, open_ref = none, link = none,
                  monitor = none, credit = none, active = none,
                  waiting = {[], []}, borrowers = #{}, retiring = false}).
-record(reader, {link :: pid(), link_monitor :: reference(), worker :: pid() | none,
                 monitor = none :: reference() | none, timer = none :: reference() | none,
                 source = none, result = none, retiring = false,
                 operation = none, sequence = 0, sent = false,
                 started_ms :: integer()}).

-record(transfer, {binding, last, next, projection, index, mode, stage,
                    entries = [], finality = pending}).
-opaque transfer() :: #transfer{}.
-record(transfer_sender, {next, last, current = none, pending = none}).
-opaque transfer_sender() :: #transfer_sender{}.
-record(range_receiver, {binding, to, mode, stage, context, projection, index,
                          transfer = none, height = none}).
-opaque range_receiver() :: #range_receiver{}.

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
            inflight = #{} :: #{binary() => #reader{}},
                                      %% server: one exact row per live read worker
            page_operations = #{} :: #{reference() => binary()},
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

The caller passes the pick EXPLICITLY to every `pull/5` of the run — ONE contact per attempt,
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

-doc "Consume one credited history page in its existing worker under the range's original deadline.".
-spec pull(binary(), term(), node_id() | endpoint(), integer(),
           fun(([term()], non_neg_integer(), done | {binary(), pos_integer()}) ->
                   {ok, term()} | {error, term()})) ->
          {ok, term(), non_neg_integer(), done | {binary(), pos_integer()}} | {error, term()}.
pull(Ns, Query, Contact, Deadline, Consume) when is_function(Consume, 3) ->
    Started = quod_time:mono_ms(),
    case quod_reg:where({quod_catchup, Ns}) of
        undefined -> {error, no_catchup_endpoint};
        Pid ->
            case pull_owner_call(Pid, {pull, Query, Contact, Started, Deadline}, Deadline) of
                {consume_page, Key, Parts, Height, Continuation} ->
                    case quod_time:mono_ms() < Deadline of
                        false -> {error, timeout};
                        true ->
                            Result = Consume(Parts, Height, Continuation),
                            Verdict = case Result of {ok, _} -> accepted; _ -> rejected end,
                            Completion = pull_owner_call(Pid, {complete_pull_page, Key, Verdict}, Deadline),
                            case {Completion, Result} of
                                {ok, {ok, Value}} -> {ok, Value, Height, Continuation};
                                {_, {error, _} = Error} -> Error;
                                _ -> {error, timeout}
                            end
                    end;
                {error, _} = Error -> Error
            end
    end.

pull_owner_call(Pid, Request, Deadline) ->
    case Deadline - quod_time:mono_ms() of
        Remaining when Remaining > 0 ->
            try gen_server:call(Pid, Request, Remaining)
            catch exit:_ -> {error, timeout} end;
        _ -> {error, timeout}
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
      {catchup, 3, Ns, Inner},
      ?QUOD_TRANSPORT_MAX_FRAME_BYTES),
    Outer.

-doc "Decode one existing catch-up frame, returning its inner encoded byte count.".
-spec decode_frame(binary(), binary()) ->
          {ok, term(), non_neg_integer()} | {error, term()}.
decode_frame(Ns, Payload)
  when is_binary(Ns), is_binary(Payload),
       byte_size(Payload) =< ?QUOD_TRANSPORT_MAX_FRAME_BYTES ->
    case quod_safe_term:decode_wrapped(Payload, ?QUOD_TRANSPORT_MAX_FRAME_BYTES) of
        {ok, {catchup, 3, Ns, Bin}}
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

decode_wire_term({history_credit3, <<_:128>> = Grant}, Bytes) ->
    {ok, {history_credit3, Grant}, Bytes};
decode_wire_term({history_request3, <<_:128>>, <<_:128>>, Query} = Term, Bytes) ->
    case valid_transfer_query(Query) of
        true -> {ok, Term, Bytes};
        false -> {error, bad_frame}
    end;
decode_wire_term(
  {history_page3, <<_:128>> = Grant, <<_:128>>, Parts, Height,
   Continuation, <<_:128>> = Next} = Term, Bytes)
  when is_integer(Height), Height >= 0 ->
    case Grant =/= Next andalso valid_transfer_continuation(Continuation)
         andalso valid_transfer_parts(Parts, 0, 0) of
        true -> {ok, Term, Bytes};
        false -> {error, bad_frame}
    end;
decode_wire_term(
  {history_error3, <<_:128>> = Grant, <<_:128>>, Reason, <<_:128>> = Next} = Term, Bytes)
  when Grant =/= Next, (Reason =:= not_ready orelse Reason =:= server_error) ->
    {ok, Term, Bytes};
decode_wire_term(_Term, _Bytes) ->
    {error, bad_frame}.

valid_transfer_query({range, From, To}) ->
    is_integer(From) andalso From > 0 andalso is_integer(To) andalso To >= From;
valid_transfer_query({continue, Token, Sequence}) ->
    valid_transfer_continuation({Token, Sequence});
valid_transfer_query(_) -> false.

valid_transfer_continuation(done) -> true;
valid_transfer_continuation({<<_:128>>, Sequence}) -> is_integer(Sequence) andalso Sequence > 0;
valid_transfer_continuation(_) -> false.

%% Read already-verified material for the derived foreign projection. This
%% bounded work unit is not a history transport or a certificate verifier.
-spec read_blocks(quod_ledger_store:handle(), non_neg_integer(), log_index()) ->
          {ok, [quod_ledger:entry_artifact()], log_index()} | {error, term()}.
read_blocks(Store, From0, To) ->
    From = max(1, From0),
    try
        LastI = quod_ledger_store:last(Store),
        To1 = lists:min([To, LastI, From + ?MAX_BLOCKS - 1]),
        {ok, Es} = measure_serve_stage(
                     serve_range_read,
                     fun() -> quod_ledger_store:read_range(Store, From, To1, all) end),
        {ok, cap_bytes(Es, 0), LastI}
    catch _:R -> {error, R}
    end.

serve_hosted_range(Ns, From, To, Deadline, Owner, Token, Gate) ->
    case measure_serve_stage(
           serve_snapshot_lookup,
           fun() -> quod_simplex:history_view(Ns, committed, Deadline) end) of
        {ok, #{snapshot := Snapshot} = View} ->
            case gen_server:call(Owner, {page_source, Token, View},
                                 max(0, Deadline - quod_time:mono_ms())) of
                ok ->
                    {ok, Store} = quod_ledger_store:open_ro_snapshot(Snapshot),
                    try
                        Ns = quod_ledger_store:namespace(Store),
                        serve_transfer_pages(Store, transfer_open(Store, From, To),
                                             Owner, Token, 0, Deadline, Gate)
                    after quod_ledger_store:close(Store) end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

serve_transfer_pages(Store, Cursor, Owner, Token, Sequence, Deadline, Gate) ->
    case transfer_page(Store, Cursor) of
        {ok, Parts, Next} ->
            Continuation = case Next of done -> done; _ -> {Token, Sequence + 1} end,
            Owner ! {reader_result, Token, self(),
                     {ok, Parts, quod_ledger_store:last(Store), Continuation}},
            reader_gate(after_result, Gate, Token),
            case Next of
                done -> ok;
                _ ->
                    receive
                        {continue_transfer, Token, NextSequence} when NextSequence =:= Sequence + 1 ->
                            serve_transfer_pages(Store, Next, Owner, Token, NextSequence, Deadline, Gate)
                    after max(0, Deadline - quod_time:mono_ms()) -> {error, not_ready}
                    end
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
serve_stage_result({error, _}) -> failed.

%% Keep one bounded materializer work unit, including at least one legal
%% material entry. Transport separately pages proof groups with its cursor.
cap_bytes([], _Acc) -> [];
cap_bytes([E | Rest], Acc) ->
    EntryBytes = case E of
        Bytes when is_binary(Bytes) -> Bytes;
        _ -> {ok, Bytes} = quod_ledger:encode_entry(E), Bytes
    end,
    Acc1 = Acc + byte_size(EntryBytes),
    case Acc =:= 0 orelse Acc1 =< ?RESP_BUDGET of
        true  -> [E | cap_bytes(Rest, Acc1)];
        false -> []
    end.

-doc """
Capture a material range for the existing reader. The last selected archive
group is completed even if it extends beyond To; certified material cannot be
silently discarded from its witness. Groups share pages instead of adding a
network round trip for every historical transaction.
""".
-spec transfer_open(quod_ledger_store:handle(), pos_integer(), pos_integer()) -> transfer_sender().
transfer_open(Store, From, To) when is_integer(From), From > 0, is_integer(To), To >= From ->
    #transfer_sender{next = From, last = min(To, quod_ledger_store:last(Store))}.

-doc "Produce a bounded page without restarting its proof cursor; retain one lookahead item.".
-spec transfer_page(quod_ledger_store:handle(),
                    transfer_sender() | done) ->
          {ok, [term()], transfer_sender() | done} | {error, term()}.
transfer_page(_Store, done) -> {ok, [], done};
transfer_page(Store, State) -> transfer_page(Store, State, [], 0, 0).

transfer_page(Store, State = #transfer_sender{pending = Pending}, Acc, Count, Size) ->
    Next = case Pending of
        none -> next_transfer_part(Store, State);
        _ -> {ok, Pending, State#transfer_sender{pending = none}}
    end,
    case Next of
        done -> {ok, lists:reverse(Acc), done};
        {ok, Part, State1} ->
            case quod_safe_term:encode_canonical(Part, ?RESP_BUDGET) of
                {ok, Encoded} when Count < ?MAX_BLOCKS, Size + byte_size(Encoded) =< ?RESP_BUDGET ->
                    transfer_page(Store, State1, [Part | Acc], Count + 1,
                                  Size + byte_size(Encoded));
                {ok, _} -> {ok, lists:reverse(Acc), State1#transfer_sender{pending = Part}};
                {error, _} -> {error, transfer_part_too_large}
            end
    end.

next_transfer_part(_Store, #transfer_sender{current = none, next = Next, last = Last})
  when Next > Last -> done;
next_transfer_part(Store, S = #transfer_sender{current = none, next = First}) ->
    {ok, Last, Cursor} = quod_ledger_store:transfer_cursor(Store, First),
    {ok, {group, First, Last}, S#transfer_sender{next = Last + 1, current = Cursor}};
next_transfer_part(Store, S = #transfer_sender{current = Cursor}) ->
    case quod_ledger_store:transfer_next(Store, Cursor) of
        done -> {ok, end_group, S#transfer_sender{current = none}};
        {ok, Part, Next} -> {ok, Part, S#transfer_sender{current = Next}}
    end.

-doc "Start one selected group under the caller's pinned projection and owned temporary stage.".
-spec transfer_begin({binary(), <<_:256>>}, pos_integer(), map(), term(),
                     materialized | wrapped, quod_ledger_store:proof_stage()) ->
          {ok, transfer()} | {error, term()}.
transfer_begin(Binding, Last, Projection, Index, Mode, Stage)
  when is_integer(Last), Last > 0, (Mode =:= materialized orelse Mode =:= wrapped) ->
    First = case maps:get(history_head, Projection, none) of
        none -> 1;
        {Height, _} -> Height + 1
    end,
    case Last >= First of
        true -> {ok, #transfer{binding = Binding, last = Last, next = First,
                               projection = Projection, index = Index, mode = Mode, stage = Stage}};
        false -> {error, stale_window}
    end;
transfer_begin(_, _, _, _, _, _) -> {error, malformed_transfer}.

-doc """
Consume bounded pages once, preserving the same finality cursor until the
exact certified prefix is reached. The existing fetch owner must charge bytes
and check its original deadline before this call. Only a complete selected
group returns append material and an index delta; an interrupted proof exposes
neither. The stage/source lifetime is the enclosing worker callback.
""".
-spec transfer_accept(transfer(), [{entry | proof, binary()}], more | done) ->
          {more, transfer()} | {done, map()} | {error, term()}.
transfer_accept(T, Parts, End) when End =:= more; End =:= done ->
    case valid_transfer_parts(Parts, 0, 0) of
        true ->
            case transfer_parts(Parts, T, quod_transaction:decode_context()) of
                {ok, T1, _Decoded} when End =:= more -> {more, T1};
                {ok, T1, _Decoded} -> finish_transfer(T1);
                {error, _} = Error -> Error
            end;
        false -> {error, malformed_transfer_page}
    end;
transfer_accept(_, _, _) -> {error, malformed_transfer_page}.

valid_transfer_parts([], _Count, _Bytes) -> true;
valid_transfer_parts([Part | Rest], Count, Size) when Count < ?MAX_BLOCKS ->
    case valid_transfer_part(Part) andalso quod_safe_term:encode_canonical(Part, ?RESP_BUDGET) of
        {ok, Encoded} when Size + byte_size(Encoded) =< ?RESP_BUDGET ->
            valid_transfer_parts(Rest, Count + 1, Size + byte_size(Encoded));
        _ -> false
    end;
valid_transfer_parts(_, _, _) -> false.

valid_transfer_part({Kind, Bytes}) when Kind =:= entry; Kind =:= proof -> is_binary(Bytes);
valid_transfer_part({group, First, Last}) ->
    is_integer(First) andalso First > 0 andalso is_integer(Last) andalso Last >= First;
valid_transfer_part(end_group) -> true;
valid_transfer_part(_) -> false.

transfer_parts([], T, Decoded) -> {ok, T, Decoded};
transfer_parts([{entry, Bytes} | Rest],
               T = #transfer{next = Next, last = Last, mode = Mode, entries = Entries}, Decoded)
  when Next =< Last ->
    case quod_ledger:decode_entry(Bytes, Mode, Decoded) of
        {ok, Entry, Decoded1} ->
            case quod_ledger:entry_index(Entry) of
                Next ->
                    T1 = T#transfer{entries = [Entry | Entries], next = Next + 1},
                    case begin_transfer_finality(T1) of
                        {ok, T2} -> transfer_parts(Rest, T2, Decoded1);
                        {error, _} = Error -> Error
                    end;
                _ -> {error, noncontiguous_transfer}
            end;
        {error, _} -> {error, malformed_entry}
    end;
transfer_parts([{proof, Bytes} | Rest], T = #transfer{finality = {more, Cursor}, stage = Stage}, Decoded) ->
    case finality_block(Cursor, Bytes, Decoded) of
        {{error, _} = Error, _} -> Error;
        {Progress, Decoded1} ->
            Stage1 = quod_ledger_store:stage_proof(Stage, Bytes),
            transfer_parts(Rest, T#transfer{finality = Progress, stage = Stage1}, Decoded1)
    end;
transfer_parts(_, _, _) -> {error, unexpected_transfer_part}.

begin_transfer_finality(T = #transfer{next = Next, last = Last}) when Next =< Last -> {ok, T};
begin_transfer_finality(T = #transfer{binding = Binding, entries = Entries, projection = P}) ->
    case finality_begin(Binding, lists:reverse(Entries), P) of
        ok -> {ok, T#transfer{finality = {done, genesis}}};
        {more, _} = Cursor -> {ok, T#transfer{finality = Cursor}};
        {error, _} = Error -> Error
    end.

finish_transfer(#transfer{binding = Binding, entries = Rev, projection = P,
                           index = Index, finality = {done, Summary}, stage = Stage}) ->
    Entries = lists:reverse(Rev),
    case preview_group(Binding, Entries, P, Index, quod_dtx_phase_index:new_delta()) of
        {ok, Projection, Delta} ->
            {done, #{entries => Entries, proof => quod_ledger_store:staged_proof_source(Stage),
                     projection => Projection, delta => Delta, finality => Summary}};
        {error, _} = Error -> Error
    end;
finish_transfer(_) -> {error, incomplete_transfer}.

-doc "Thread the existing fetch worker's context through complete groups on the shared page grammar.".
-spec range_begin({binary(), <<_:256>>}, pos_integer(), materialized | wrapped,
                  quod_ledger_store:proof_stage(), term(), map(), term()) -> range_receiver().
range_begin(Binding, To, Mode, Stage, Context, Projection, Index) ->
    #range_receiver{binding = Binding, to = To, mode = Mode, stage = Stage,
                     context = Context, projection = Projection, index = Index}.

-spec range_context(range_receiver()) -> term().
range_context(#range_receiver{context = Context}) -> Context.

-doc """
Consume a bounded, decoded transport page. Install receives one fully verified
group and the worker's context, and returns its new committed projection/index
view. No owner is mutated by verification. The same staged file is reclaimed
after each acknowledged group, not retained for the whole historical range.
""".
-spec range_accept(range_receiver(), [term()], non_neg_integer(),
                   done | {binary(), pos_integer()},
                   fun((map(), term()) -> {ok, term(), map(), term()} |
                                           {error, term()} | {error, term(), term()})) ->
          {ok, range_receiver()} | {error, term(), range_receiver()}.
range_accept(R = #range_receiver{height = Height, projection = P}, Parts, RemoteHeight, Continuation, Install)
  when is_integer(RemoteHeight), RemoteHeight >= 0,
       (Height =:= none orelse Height =:= RemoteHeight) ->
    LocalHeight = case maps:get(history_head, P, none) of none -> 0; {I, _} -> I end,
    case RemoteHeight >= LocalHeight of
        false -> {error, source_behind, R};
        true ->
            %% Authentication reuse belongs only to this bounded page. It is
            %% not retained in either cursor and cannot become authority for
            %% committee, reference, freshness or finality decisions.
            case valid_transfer_parts(Parts, 0, 0) of
                false -> {error, malformed_transfer_page, R};
                true ->
                    case consume_range_parts(Parts, R#range_receiver{height = RemoteHeight},
                                             Install, quod_transaction:decode_context()) of
                        {ok, Next = #range_receiver{transfer = Active}, _}
                          when Continuation =:= done, Active =/= none ->
                            {error, incomplete_transfer, Next};
                        {ok, Next, _} -> {ok, Next};
                        Other -> Other
                    end
            end
    end;
range_accept(R, _, _, _, _) -> {error, changed_transfer_height, R}.

consume_range_parts([], R, _Install, Decoded) -> {ok, R, Decoded};
consume_range_parts([{group, First, Last} | Rest],
  R = #range_receiver{transfer = none, binding = Binding, projection = P,
                       index = Index, mode = Mode, stage = Stage, to = To, height = H}, Install, Decoded)
  when First =< To, Last =< H ->
    Expected = case maps:get(history_head, P, none) of none -> 1; {I, _} -> I + 1 end,
    case First =:= Expected andalso transfer_begin(Binding, Last, P, Index, Mode, Stage) of
        {ok, Transfer} -> consume_range_parts(Rest, R#range_receiver{transfer = Transfer}, Install, Decoded);
        _ -> {error, noncontiguous_transfer, R}
    end;
consume_range_parts([end_group | Rest],
  R = #range_receiver{transfer = T, context = Context}, Install, Decoded) when T =/= none ->
    case finish_transfer(T) of
        {done, Group} ->
            case Install(Group, Context) of
                {ok, NextContext, P, Index} ->
                    Stage = quod_ledger_store:reset_proof_stage(T#transfer.stage),
                    consume_range_parts(Rest, R#range_receiver{transfer = none,
                        context = NextContext, projection = P, index = Index, stage = Stage}, Install, Decoded);
                {error, Why, FailedContext} -> {error, Why, R#range_receiver{context = FailedContext}};
                {error, Why} -> {error, Why, R}
            end;
        {error, Why} -> {error, Why, R}
    end;
consume_range_parts([Part | Rest], R = #range_receiver{transfer = T}, Install, Decoded) when T =/= none ->
    case transfer_parts([Part], T, Decoded) of
        {ok, T1, Decoded1} -> consume_range_parts(Rest, R#range_receiver{transfer = T1}, Install, Decoded1);
        {error, Why} -> {error, Why, R}
    end;
consume_range_parts(_, R, _, _) -> {error, unexpected_transfer_part, R}.

%% One backward proof cursor belongs to the existing verification job. Its
%% root is the already-certified material prefix, never a peer's declaration.
%% It retains neither the whole witness nor a second copy of ontology state.
-record(finality_cursor, {index, root, targets, expected, root_timestamp,
                          ceiling = infinity, found = false,
                          child_empty = false,
                          material_above = false, head,
                          head_timestamp = undefined, material_tip = none,
                          highest_claim}).
-opaque finality_cursor() :: #finality_cursor{}.

-doc "Verify streamed ancestry once, distinguishing an exact claim from complete material custody.".
-spec verify_finality({binary(), <<_:256>>}, quod_ledger:entry_artifact() | [quod_ledger:entry_artifact()],
                      quod_simplex:history_projection(), {fun((term()) -> term()), term()}) ->
          {ok, genesis | map()} | {error, term()}.
verify_finality(Binding, Entries, Projection, {Next, State}) when is_function(Next, 1) ->
    case finality_begin(Binding, Entries, Projection) of
        ok -> {ok, genesis};
        {more, Cursor} -> consume_finality(Cursor, Next, State);
        {error, _} = Error -> Error
    end.

-doc "Authenticate an archive group and preview its domain/index changes without mutating the owner.".
-spec verify_forward_group({binary(), <<_:256>>}, [quod_ledger:entry_artifact()],
                           quod_simplex:history_projection(), quod_dtx_phase_index:index(),
                           {fun((term()) -> term()), term()}) ->
          {ok, quod_simplex:history_projection(), quod_dtx_phase_index:delta(), genesis | map()} |
          {error, term()}.
verify_forward_group(Binding, Entries, Projection, PhaseIndex, Source) ->
    case verify_finality(Binding, Entries, Projection, Source) of
        {ok, Summary} ->
            case preview_group(Binding, Entries, Projection, PhaseIndex,
                               quod_dtx_phase_index:new_delta()) of
                {ok, P, Delta} -> {ok, P, Delta, Summary};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

preview_group(_Binding, [], Projection, _Index, Delta) -> {ok, Projection, Delta};
preview_group(Binding, [Entry | Rest], Projection, Index, Delta) ->
    case quod_simplex:history_preview_verified(Binding, Entry, Projection, Index, Delta) of
        {ok, P1, _Effects, Delta1} -> preview_group(Binding, Rest, P1, Index, Delta1);
        {error, _} = Error -> Error
    end.

consume_finality(Cursor, Next, State) ->
    case Next(State) of
        {ok, Bytes, State1} ->
            case finality_block(Cursor, Bytes) of
                {more, Cursor1} -> consume_finality(Cursor1, Next, State1);
                {done, Summary} -> {ok, Summary};
                {error, _} = Error -> Error
            end;
        done -> {error, {incomplete_finality, Cursor#finality_cursor.index}};
        {error, _} = Error -> Error
    end.

-doc "Check one head QC for contiguous material claims, retaining one cursor across proof pages.".
-spec finality_begin({binary(), <<_:256>>}, quod_ledger:entry_artifact() | [quod_ledger:entry_artifact()],
                     quod_simplex:history_projection()) ->
          ok | {more, finality_cursor()} | {error, term()}.
finality_begin(Binding, Entry, Projection) when not is_list(Entry) ->
    finality_begin(Binding, [Entry], Projection);
finality_begin({Ns, <<_:256>> = Anchor}, [Entry | Rest], Projection) when is_binary(Ns) ->
    #entry{index = I, cert = Cert} = quod_ledger:entry_view(Entry),
    {ok, B} = entry_block(Entry),
    Target = quod_ledger:block_ref(B),
    case {I, Target, Cert, maps:get(history_head, Projection, none),
          maps:get(protocol_root, Projection, none)} of
        {1, {genesis, 0, Anchor}, none, none, none} when Rest =:= [] -> ok;
        {I, {Era, V, _}, #cert{kind = commit, era = Era, slot = Head, block_hash = Hash},
         {Height, _}, {Era, RootView, _} = Root}
          when I =:= Height + 1, V > RootView, Head >= V ->
            Domain = quod_simplex:consensus_domain(Ns, Anchor),
            case finality_targets(Rest, I + 1, Era, V, Head, Cert, [Target]) of
                {ok, Targets} ->
                    case quod_simplex:verify_cert(Domain, Cert, quod_simplex:history_committee(Projection)) of
                        true -> {more, #finality_cursor{index = I, root = Root, targets = Targets,
                                          expected = {Era, Head, Hash}, head = {Era, Head, Hash},
                                          highest_claim = hd(Targets),
                                          root_timestamp = maps:get(timestamp, Projection)}};
                        false -> {error, {bad_cert, I}}
                    end;
                error -> {error, {invalid_finality_group, I}}
            end;
        _ -> {error, {cert_mismatch, I}}
    end.

%% One archive group shares one selected head. Its material claims are checked
%% together while the witness passes once, rather than once per ancestor.
finality_targets([], _Index, _Era, _Previous, _Head, _Cert, Acc) -> {ok, Acc};
finality_targets([Entry | Rest], Index, Era, Previous, Head, Cert, Acc) ->
    case {quod_ledger:entry_view(Entry), entry_block(Entry)} of
        {#entry{index = Index, cert = Cert}, {ok, #block{era = Era, slot = V} = B}}
          when V > Previous, V =< Head ->
            finality_targets(Rest, Index + 1, Era, V, Head, Cert, [quod_ledger:block_ref(B) | Acc]);
        _ -> error
    end;
finality_targets(_, _, _, _, _, _, _) -> error.

-doc "Authenticate one exact parent link; completion requires reaching the certified prefix.".
-spec finality_block(finality_cursor(), binary()) ->
          {done, map()} | {more, finality_cursor()} | {error, term()}.
finality_block(Cursor, Bytes) ->
    {Result, _} = finality_block(Cursor, Bytes, quod_transaction:decode_context()),
    Result.

finality_block(Cursor = #finality_cursor{index = I, expected = Expected}, Bytes, Decoded) ->
    case quod_ledger:decode_block(Bytes, wrapped, Decoded) of
        {ok, B, Decoded1} ->
            Result = case quod_ledger:block_ref(B) =:= Expected of
                true -> finality_link(Cursor, B);
                false -> {error, {wrong_finality_link, I}}
            end,
            {Result, Decoded1};
        {error, _} -> {{error, {malformed_finality_link, I}}, Decoded}
    end.

finality_link(C = #finality_cursor{index = I, root = Root, targets = Targets,
                                  expected = Expected, root_timestamp = RootTs,
                                  ceiling = Ceiling, found = Found,
                                  child_empty = ChildEmpty,
                                  material_above = Above},
              #block{parent = Parent, timestamp = Ts, payload = Payload}) ->
    Material = Payload =/= empty,
    Membership = case quod_ledger:classify(Payload) of
        {content, Transactions} ->
            lists:any(fun(T) -> quod_simplex:committee_delta(T) =/= {[], []} end, Transactions);
        _ -> false
    end,
    Matches = case Targets of [Expected | _] -> true; _ -> false end,
    %% A material descendant of terminal M is invalid even with a valid head
    %% certificate. Between supplied material heights only empty carriers are
    %% legal: a correctly signed proof must not conceal a missing ledger entry.
    case (Ceiling =:= infinity orelse Ts =< Ceiling) andalso Ts >= RootTs
         andalso (not ChildEmpty orelse Ts =:= Ceiling)
         andalso not (Membership andalso Above)
         andalso not (Found andalso Material andalso not Matches) of
        false -> {error, {invalid_finality_path, I}};
        true ->
            Remaining = case Matches of true -> tl(Targets); false -> Targets end,
            Found1 = Found orelse Matches,
            HeadTs = case C#finality_cursor.head_timestamp of undefined -> Ts; T -> T end,
            MaterialTip = case {C#finality_cursor.material_tip, Material} of
                {none, true} -> Expected;
                {Tip, _} -> Tip
            end,
            C1 = C#finality_cursor{expected = Parent, ceiling = Ts, targets = Remaining,
                                   child_empty = not Material,
                                   found = Found1, material_above = Above orelse Material,
                                   head_timestamp = HeadTs, material_tip = MaterialTip},
            MinView = case Remaining of [] -> element(2, Root); [{_, V, _} | _] -> V end,
            case Parent of
                Root when Remaining =:= [], Material orelse Ts =:= RootTs ->
                    {done, #{head => C1#finality_cursor.head, head_timestamp => HeadTs,
                             material_tip => MaterialTip,
                             complete_group => MaterialTip =:= C1#finality_cursor.highest_claim}};
                {_, ParentView, _} when ParentView > element(2, Root), ParentView >= MinView ->
                    {more, C1};
                _ -> {error, {wrong_finality_root, I}}
            end
    end.

entry_block(E) -> quod_ledger:block_from_entry(E).

-doc """
Drive trustless catch-up from one same-turn owner capture, including height zero.
Each window is verified once against that read-only phase/era index. The worker
never opens an index, replays a prefix, or mutates the owner's table.

`Sink(Group)` checks the base, appends proof and material together, installs the
verified delta, and returns the new owner view before any next window. An
overtaken window is refused, never trimmed or verified a second time.
The exact initial owner remains pinned throughout the run.

The target height is the maximum reported in this run: a regressing contact
cannot truncate catch-up. The slot-1 genesis hash is pinned out of band.
""".
-spec catch_up(
        binary(), binary(), fun((term(), integer(), function()) -> term()),
        fun((map()) -> {ok, quod_simplex:history_view()} | {error, term()}),
        pos_integer(), quod_simplex:history_projection(),
        #{history_view := quod_simplex:history_view(), stage_path := file:filename_all()}) ->
          {ok, log_index()} | {error, term()}.
catch_up(Ns, <<_:256>> = Anchor, Fetch, Sink, From,
         #{history_index := _} = Projection,
         #{history_view := #{identity := {Ns, Anchor}, slot := Height,
                             owner := Owner, snapshot := _, projection := Projection} = View,
           stage_path := Path})
  when is_binary(Ns), byte_size(Ns) > 0, is_function(Fetch, 3), is_function(Sink, 1),
       is_integer(From), From >= 1, From =:= Height + 1, is_pid(Owner) ->
    quod_ledger_store:with_proof_stage(Path, fun(Stage) ->
        catch_up_loop({Ns, Anchor}, Fetch, Sink, View, From, 0, Stage)
    end);
catch_up(_, _, _, _, _, _, _) -> {error, bad_catchup_options}.

catch_up_loop(Binding, Fetch, Sink, View = #{owner := Owner, projection := Projection},
              From, MaxHeight, Stage) ->
    To = From + ?MAX_BLOCKS - 1,
    Deadline = quod_time:mono_ms() + ?REQ_TIMEOUT_MS,
    Range = range_begin(Binding, To, materialized, Stage, View, Projection,
                        maps:get(history_index, Projection)),
    Install = fun(Group, CurrentView) ->
        case sink_window(Sink, Group, CurrentView) of
            {ok, NextView = #{projection := P}} ->
                {ok, NextView, P, maps:get(history_index, P)};
            {error, _} = Error -> Error
        end
    end,
    case fetch_range_pages(Fetch, {range, From, To}, Deadline, Range, Install, Owner) of
        {ok, Received, Height} ->
            NextView = #{slot := Last} = range_context(Received),
            Target = max(MaxHeight, Height),
            case Last >= Target of
                true -> {ok, Target};
                false when Last < From -> {error, no_progress};
                false -> catch_up_loop(Binding, Fetch, Sink, NextView, Last + 1, Target, Stage)
            end;
        {error, _} = Error -> Error
    end.

fetch_range_pages(Fetch, Query, Deadline, Range, Install, Owner) ->
    case is_process_alive(Owner) andalso Deadline > quod_time:mono_ms() of
        false -> {error, owner_unavailable};
        true ->
            Consume = fun(Parts, Height, Continuation) ->
                case is_process_alive(Owner) of
                    false -> {error, owner_down};
                    true ->
                        case range_accept(Range, Parts, Height, Continuation, Install) of
                            {ok, _} = Ok -> Ok;
                            {error, Why, _Retained} -> {error, Why}
                        end
                end
            end,
            case Fetch(Query, Deadline, Consume) of
                {ok, Next, Height, done} -> {ok, Next, Height};
                {ok, Next, _Height, {Token, Sequence}} ->
                    fetch_range_pages(Fetch, {continue, Token, Sequence}, Deadline, Next, Install, Owner);
                {error, _} = Error -> Error;
                _ -> {error, malformed_transfer_response}
            end
    end.

%% A complete group remains owned by the staging worker until the exact sink
%% acknowledges its archive append, delta installation and new captured view.
sink_window(Sink, Group = #{entries := Entries, projection := Projection},
            #{owner := Owner, identity := Identity}) ->
    Height = quod_ledger:entry_index(lists:last(Entries)),
    Head = maps:get(history_head, Projection),
    case is_process_alive(Owner) andalso Sink(Group) of
        {ok, #{owner := Owner, identity := Identity, slot := Height,
               snapshot := _, projection := #{history_head := Head,
                                              history_index := _}} = View} -> {ok, View};
        {error, _} = Error -> Error;
        false -> {error, owner_down};
        _ -> {error, invalid_history_view}
    end.

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
handle_call({pull, Query, Contact, Started, Deadline}, ReplyTo, S) ->
    begin_pull(Contact, Query, Deadline, Started, ReplyTo, S);
handle_call({complete_pull_page, Key, Verdict}, {Caller, _}, S) ->
    {Reply, Next} = complete_pull_page(Key, Verdict, Caller, S),
    {reply, Reply, Next};
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
                               result => R#reader.result, retiring => R#reader.retiring,
                               operation => R#reader.operation, sequence => R#reader.sequence,
                               started_ms => R#reader.started_ms} end,
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

handle_info({catchup_request, Link, Op, {range, From, To}, StartedMs}, S)
  when is_pid(Link), is_reference(Op), is_integer(From), From > 0,
       is_integer(To), To >= From, is_integer(StartedMs) ->
    {noreply, start_reader(Link, Op, From, To, StartedMs, S)};
handle_info({catchup_request, Link, Op, {continue, Token, Sequence}, _StartedMs}, S) ->
    {noreply, continue_reader(Link, Op, Token, Sequence, S)};
handle_info({reader_result, Token, Worker, Result}, S0) ->
    case maps:get(Token, S0#s.inflight, undefined) of
        #reader{worker = Worker, result = none, retiring = false} = Row ->
            Row1 = Row#reader{result = Result},
            case Result of
                {ok, _, _, {Token, _}} ->
                    case reader_result_live(Row1) of
                        true -> {noreply, send_reader_result(Token, Row1, S0)};
                        false -> {noreply, cancel_reader(Token, {error, not_ready}, false, S0)}
                    end;
                _ -> {noreply, put_reader(Token, Row1, S0)}
            end;
        _ -> {noreply, S0}
    end;
handle_info({catchup_page_sent, Link, Op}, S0) ->
    case maps:take(Op, S0#s.page_operations) of
        {Token, Operations} ->
            case maps:get(Token, S0#s.inflight, undefined) of
                #reader{link = Link, operation = Op, result = {ok, _, _, {Token, Seq}}} = Row ->
                    {noreply, put_reader(Token, Row#reader{operation = none, result = none,
                                            sent = false, sequence = Seq},
                                        S0#s{page_operations = Operations})};
                #reader{link = Link, operation = Op, worker = none, result = Result} = Row ->
                    {noreply, retire_reader(Token, Row, terminal_result(Result), S0)};
                _ -> {noreply, S0}
            end;
        error -> {noreply, S0}
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
        reply_pull(P#client_pull.from, {error, unavailable})
    end, S#s.pending),
    ok.

start_reader(Link, Op, From, To, Started, S = #s{ns = Ns}) ->
    %% A granted page opens one retained range reader, not another executor.
    %% Its original timer/source/link ownership spans all continuation pages.
    case maps:is_key(Op, S#s.page_operations) orelse not is_process_alive(Link) of
        true -> S;
        false ->
            Token = crypto:strong_rand_bytes(16),
            Deadline = Started + ?REQ_TIMEOUT_MS,
            LinkMonitor = erlang:monitor(process, Link, [{tag, {page_link_down, Token}}]),
            Row = #reader{link = Link, link_monitor = LinkMonitor,
                          operation = Op, worker = none, started_ms = Started},
            S1 = S#s{page_operations = (S#s.page_operations)#{Op => Token}},
            case Deadline =< quod_time:mono_ms() of
                true -> send_reader_result(Token, Row#reader{result = {error, not_ready}}, S1);
                false -> spawn_reader(Ns, Token, From, To, Deadline, Row, S1)
            end
    end.

continue_reader(Link, Op, Token, Sequence, S) ->
    case maps:get(Token, S#s.inflight, undefined) of
        #reader{link = Link, operation = none, sequence = Sequence, worker = Worker,
                 retiring = false, sent = false} = Row when is_pid(Worker) ->
            case reader_result_live(Row) andalso is_process_alive(Worker) of
                true ->
                    Worker ! {continue_transfer, Token, Sequence},
                    put_reader(Token, Row#reader{operation = Op},
                      S#s{page_operations = (S#s.page_operations)#{Op => Token}});
                false ->
                    quod_link:complete_page(Link, Op, {error, not_ready}),
                    cancel_reader(Token, {error, not_ready}, false, S)
            end;
        _ ->
            %% An old or foreign-link token cannot take over a retained cursor.
            quod_link:complete_page(Link, Op, {error, not_ready}),
            S
    end.

spawn_reader(Ns, Token, From, To, Deadline, Row, S) ->
    Owner = self(),
    Gate = take_reader_gate(),
    {Worker, MRef} = spawn_opt(fun() ->
        reader_gate(before_read, Gate, Token),
        Result = try serve_hosted_range(Ns, From, To, Deadline, Owner, Token, Gate)
                 catch _:_ -> {error, server_error}
                 end,
        case Result of
            ok -> ok;
            {error, _} -> Owner ! {reader_result, Token, self(), {error, not_ready}}
        end
    end, [link, {monitor, [{tag, {page_worker_down, Token}}]}]),
    Timer = erlang:send_after(max(0, Deadline - quod_time:mono_ms()),
                             self(), {page_deadline, Token}),
    put_reader(Token, Row#reader{worker = Worker, monitor = MRef, timer = Timer}, S).

put_reader(Op, R, S) ->
    Rows = (S#s.inflight)#{Op => R},
    S#s{inflight = Rows, inflight_peak = max(S#s.inflight_peak, map_size(Rows))}.

reader_down(Token, MRef, Worker, S) ->
    case maps:get(Token, S#s.inflight, undefined) of
        #reader{worker = Worker, monitor = MRef, sent = true} = Row ->
            %% A partial response already owns this grant; never send a second
            %% result for it after a worker fault. Link loss invalidates the turn.
            quod_link:close(Row#reader.link),
            retire_reader(Token, Row, error, S);
        #reader{worker = Worker, monitor = MRef, operation = none} = Row ->
            retire_reader(Token, Row, error, S);
        #reader{worker = Worker, monitor = MRef} = Row0 ->
            Result = case reader_result_live(Row0) of
                false -> {error, not_ready};
                true -> case Row0#reader.result of
                            none -> {error, server_error}; R -> R
                        end
            end,
            Row = Row0#reader{worker = none, monitor = none, result = Result},
            send_reader_result(Token, Row, S);
        _ -> S
    end.

send_reader_result(Token, Row, S) ->
    case Row#reader.retiring orelse not is_process_alive(Row#reader.link) of
        true -> retire_reader(Token, Row, link_down, S);
        false ->
            quod_link:complete_page(Row#reader.link, Row#reader.operation, Row#reader.result),
            put_reader(Token, Row#reader{sent = true}, S)
    end.

reader_result_live(#reader{started_ms = Started, source = Source}) ->
    Started + ?REQ_TIMEOUT_MS > quod_time:mono_ms() andalso
    case Source of
        none -> true;
        {Pid, Identity, _} ->
            quod_simplex:history_view_live(#{owner => Pid, identity => Identity})
    end.

cancel_reader(Token, Result, Retiring, S) ->
    case maps:get(Token, S#s.inflight, undefined) of
        #reader{worker = none} = Row ->
            quod_link:close(Row#reader.link),
            retire_reader(Token, Row, error, S);
        #reader{worker = Worker} = Row ->
            Retire = Retiring orelse Row#reader.sent orelse Row#reader.operation =:= none,
            case Row#reader.sent of true -> quod_link:close(Row#reader.link); false -> ok end,
            exit(Worker, kill),
            put_reader(Token, Row#reader{result = Result,
                           retiring = Retire orelse Row#reader.retiring}, S);
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
                           S#s{inflight = maps:remove(Op, S#s.inflight),
                                page_operations = maps:remove(Row#reader.operation, S#s.page_operations)}).

begin_pull(Contact, Query, Deadline, Started, ReplyTo, S0)
  when is_integer(Deadline), is_integer(Started) ->
    case valid_transfer_query(Query) andalso
         (is_binary(Contact) andalso byte_size(Contact) =:= 32 orelse
          quod_quic:valid_endpoint(Contact)) of
        false -> {reply, {error, bad_contact}, S0};
        true ->
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
                    Pull = #client_pull{from = ReplyTo, caller = Caller, timer = Timer,
                                        caller_monitor = MRef, contact = Contact,
                                        query = Query, deadline = Deadline,
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
                    Owned = [Id || {Id, #client_pull{caller = Pid, contact = Contact}} <-
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
                        #client_pull{query = Query} = P ->
                            case P#client_pull.deadline =< quod_time:mono_ms() of
                                true -> drive_binding(Ref, complete_pull(ReqId, {error, timeout}, S1));
                                false ->
                                    quod_link:request_page(Link, Ref, Grant, ReqId, Query),
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
         #client_pull{sent = {Link, Ref, Grant}, deadline = Deadline} = P} ->
            case Deadline > quod_time:mono_ms() of
                false -> cancel_pull(ReqId, {error, timeout}, S0);
                true ->
                    case Result of
                        {ok, Parts, Height, Continuation} ->
                            Key = {ReqId, Link, Ref, Grant},
                            gen_server:reply(P#client_pull.from,
                              {consume_page, Key, Parts, Height, Continuation}),
                            %% The caller consumes this page; the endpoint never
                            %% decodes application bytes or blocks on staging.
                            put_client_pull(ReqId, P#client_pull{from = none,
                                sent = {decoding, Link, Ref, Grant, NextGrant}}, S0);
                        {error, _} = Error ->
                            S1 = complete_pull(ReqId, Error, S0),
                            drive_binding(Ref, put_binding(B#binding{active = none, credit = NextGrant}, S1))
                    end
            end;
        _ -> S0
    end.

complete_pull_page({ReqId, Link, Ref, Grant}, Verdict, Caller, S0) ->
    case {maps:get(Ref, S0#s.bindings, undefined), maps:get(ReqId, S0#s.pending, undefined)} of
        {#binding{link = Link, active = ReqId, retiring = false} = B,
         #client_pull{caller = Caller, from = none, deadline = Deadline,
                       sent = {decoding, Link, Ref, Grant, NextGrant}}} ->
            case Verdict =:= accepted andalso Deadline > quod_time:mono_ms() of
                true ->
                    S1 = complete_pull(ReqId, ok, S0),
                    {ok, drive_binding(Ref, put_binding(B#binding{active = none, credit = NextGrant}, S1))};
                false -> {{error, timeout}, cancel_pull(ReqId, {error, malformed_page}, S0)}
            end;
        _ -> {{error, stale_page}, S0}
    end;
complete_pull_page(_, _, _, S) -> {{error, stale_page}, S}.

complete_pull(ReqId, Reply, S) ->
    case maps:take(ReqId, S#s.pending) of
        {P, Pending} ->
            cancel_timer(P#client_pull.timer),
            erlang:demonitor(P#client_pull.caller_monitor, [flush]),
            reply_pull(P#client_pull.from, Reply),
            record_client_terminal(terminal_result(Reply), elapsed_ms(P#client_pull.started_ms),
                                   S#s{pending = Pending});
        error -> S
    end.

cancel_pull(ReqId, Reply, S0) ->
    case maps:get(ReqId, S0#s.pending, undefined) of
        #client_pull{contact = Contact} ->
            Ref = maps:get(Contact, S0#s.contacts),
            B = maps:get(Ref, S0#s.bindings),
            case B#binding.active of
                ReqId ->
                    quod_link:close(B#binding.link),
                    put_binding(B#binding{retiring = true, credit = none},
                                complete_pull(ReqId, Reply, S0));
                _ ->
                    Waiting = queue:filter(fun(Id) -> Id =/= ReqId end, B#binding.waiting),
                    drive_binding(Ref, put_binding(B#binding{waiting = Waiting},
                                                  complete_pull(ReqId, Reply, S0)))
            end;
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

reply_pull(none, _) -> ok;
reply_pull(From, Reply) -> gen_server:reply(From, Reply).

terminal_result(ok) -> completed;
terminal_result({ok, _, _}) -> completed;
terminal_result({ok, _, _, _}) -> completed;
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
