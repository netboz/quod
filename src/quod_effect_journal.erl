-module(quod_effect_journal).
-moduledoc """
Crash-durable local custody for direct effects authored by this node.

The root ledger records the small public descriptor.  This journal retains the
exact private preparation needed to execute that descriptor after ordered
apply.  It is deliberately not a catalogue or an authorization database: a
row can execute only after a matching applied root transaction releases it.

Lifecycle actions are rare and the table is strictly bounded, so every
mutation rewrites one checksummed snapshot through datasync + atomic rename.
That keeps recovery and compaction to one format and one authority path.
""".

-behaviour(gen_server).

-include("quod_ledger.hrl").
-include("quod_proof_limits.hrl").

-export([start_link/1, reserve/1, release_reservation/1,
         stage/5, bind_transaction/3, release_applied/2,
         activate/1, handoff/1, retire/2, retire_transaction/2,
         await/2, reconcile/0,
         status/1, status_ref/1, rows/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2]).

-ifdef(TEST).
-export([test_desired_state/2]).
-endif.

-define(ROOT_NS, <<"quod:root">>).
-define(MAGIC, 16#51454A31). %% "QEJ1"
-define(HEADER_BYTES, 40).
-define(DEFAULT_AWAIT_MS, 60000).

-record(row, {
    effect :: quod_effect:effect(),
    action :: binary(),
    desired :: binary(),
    prepared :: binary(),
    transaction :: binary(),
    ref :: term(),
    admission :: <<_:256>>,
    state = bound :: bound | prepared | handed_off | committed | applied |
                          retired | operator_error,
    height = 0 :: non_neg_integer(),
    result = none :: term()
}).

-record(reservation, {
    owner :: pid(),
    monitor :: reference(),
    staged = none :: none |
        {quod_effect:effect(), binary(), binary(), binary()}
}).

-record(s, {
    path :: file:filename_all(),
    rows = #{} :: #{binary() => #row{}},
    reservations = #{} :: #{reference() => #reservation{}},
    waiters = #{} :: #{binary() => [{gen_server:from(), reference()}]},
    running = none :: none | {binary(), pid(), reference()},
    reconciling = none :: none | {pid(), reference()},
    retry_timer = undefined :: undefined | reference(),
    retry_ms = 1000 :: pos_integer()
}).

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Config) ->
    gen_server:start_link(quod_reg:via({quod_effect_journal, node}),
                          ?MODULE, Config, []).

-spec reserve(pid()) -> {ok, reference()} | {error, busy | unavailable}.
reserve(Owner) when is_pid(Owner) ->
    call({reserve, Owner});
reserve(_) ->
    {error, busy}.

-spec release_reservation(reference()) -> ok.
release_reservation(Token) ->
    _ = call({release_reservation, Token}),
    ok.

-spec stage(reference(), term(), term(), quod_effect:effect(), term()) ->
          ok | {error, term()}.
stage(Token, Action, Desired, Effect, Prepared) ->
    call({stage, Token, Action, Desired, Effect, Prepared}).

-spec bind_transaction(quod_effect:effect(), #transaction{}, term()) ->
          ok | {error, term()}.
bind_transaction(Effect, Transaction, Ref) ->
    call({bind_transaction, Effect, Transaction, Ref}).

-doc "Idempotently transfer one prepared row into Simplex's durable signed custody.".
-spec handoff(binary()) -> ok | {error, term()}.
handoff(EffectId) -> call({handoff, EffectId}).

-doc "Activate one durable bound row only after its outcome reference was checkpointed.".
-spec activate(binary()) -> ok | {error, term()}.
activate(EffectId) -> call({activate, EffectId}).

-spec release_applied(pos_integer(), [quod_effect:effect()]) -> ok.
release_applied(Height, Effects) ->
    gen_server:cast(quod_reg:via({quod_effect_journal, node}),
                    {release_applied, Height, Effects}).

-spec retire([quod_effect:effect()], term()) -> ok.
retire(Effects, Reason) ->
    gen_server:cast(quod_reg:via({quod_effect_journal, node}),
                    {retire, Effects, Reason}).

-spec retire_transaction(<<_:256>>, term()) -> ok.
retire_transaction(TxId, Reason) ->
    gen_server:cast(quod_reg:via({quod_effect_journal, node}),
                    {retire_transaction, TxId, Reason}).

-spec await(binary(), timeout()) -> ok | {error, term()}.
await(EffectId, Timeout) when is_binary(EffectId), byte_size(EffectId) =:= 32 ->
    try gen_server:call(quod_reg:via({quod_effect_journal, node}),
                        {await, EffectId, Timeout}, infinity)
    catch exit:_ -> {error, outcome_unknown}
    end;
await(_, _) ->
    {error, invalid_direct_effect}.

-spec reconcile() -> ok.
reconcile() ->
    gen_server:cast(quod_reg:via({quod_effect_journal, node}), reconcile).

-spec status(binary()) -> {ok, map()} | {error, not_found | unavailable}.
status(EffectId) -> call({status, EffectId}).

-spec status_ref(term()) ->
          {ok, map()} |
          {error, not_found | unavailable | effect_journal_conflict}.
status_ref(Ref) -> call({status_ref, Ref}).

-spec rows() -> [map()].
rows() ->
    case call(rows) of
        Rows when is_list(Rows) -> Rows;
        _ -> []
    end.

call(Request) ->
    try gen_server:call(quod_reg:via({quod_effect_journal, node}),
                        Request, 5000)
    catch exit:_ -> {error, unavailable}
    end.

%%%===================================================================
%%% gen_server
%%%===================================================================

init(Config) ->
    DataDir = quod_ledger_store:data_dir(Config),
    Dir = quod_ledger_store:ns_dir(DataDir, ?ROOT_NS),
    Path = filename:join(Dir, "direct_effects.qej"),
    ok = filelib:ensure_dir(Path),
    Rows0 = load(Path),
    Rows = retire_unactivated_rows(Rows0),
    S0 = #s{path = Path, rows = Rows},
    S1 = case Rows =:= Rows0 of
             true -> S0;
             false -> persist(S0)
         end,
    {ok, schedule_reconcile(S1)}.

handle_call({reserve, Owner}, _From,
            S = #s{rows = Rows, reservations = Reservations}) ->
    case active_row_count(Rows) + map_size(Reservations) <
         ?QUOD_MAX_PREPARED_EFFECTS of
        false ->
            {reply, {error, busy}, S};
        true ->
            Token = make_ref(),
            MRef = monitor(process, Owner),
            Reservation = #reservation{owner = Owner, monitor = MRef},
            {reply, {ok, Token},
             S#s{reservations = Reservations#{Token => Reservation}}}
    end;
handle_call({release_reservation, Token}, _From, S) ->
    {reply, ok, drop_reservation(Token, S)};
handle_call({stage, Token, Action, Desired, Effect, Prepared},
            {Owner, _}, S = #s{reservations = Reservations}) ->
    case maps:get(Token, Reservations, undefined) of
        #reservation{owner = Owner, staged = none} = Reservation ->
            case encode_staged(Action, Desired, Effect, Prepared) of
                {ok, Staged} ->
                    {reply, ok,
                     S#s{reservations =
                             Reservations#{Token =>
                                 Reservation#reservation{staged = Staged}}}};
                {error, _} = Error ->
                    {reply, Error, S}
            end;
        _ ->
            {reply, {error, invalid_reservation}, S}
    end;
handle_call({bind_transaction, Effect, Transaction, Ref}, _From, S0) ->
    case bind_row(Effect, Transaction, Ref, S0) of
        {ok, S1} -> {reply, ok, schedule_reconcile(S1)};
        {error, Reason} -> {reply, {error, Reason}, S0}
    end;
handle_call({activate, EffectId}, _From, S = #s{rows = Rows}) ->
    case maps:get(EffectId, Rows, undefined) of
        #row{state = bound} = Row ->
            S1 = persist(S#s{rows = Rows#{EffectId =>
                                             Row#row{state = prepared}}}),
            {reply, ok, schedule_reconcile(S1)};
        #row{state = State}
          when State =:= prepared; State =:= handed_off;
               State =:= committed; State =:= applied ->
            {reply, ok, S};
        #row{state = retired, result = Reason} ->
            {reply, {error, Reason}, S};
        #row{state = operator_error, result = Reason} ->
            {reply, {error, {operator_error, Reason}}, S};
        undefined ->
            {reply, {error, not_found}, S}
    end;
handle_call({handoff, EffectId}, _From, S = #s{rows = Rows}) ->
    case maps:get(EffectId, Rows, undefined) of
        #row{state = prepared} = Row ->
            case handoff_row(Row) of
                ok -> {reply, ok, mark_handed_off(EffectId, S)};
                {error, _} = Error ->
                    {reply, Error, schedule_reconcile(S)}
            end;
        #row{state = bound} ->
            {reply, {error, not_activated}, S};
        #row{state = State}
          when State =:= handed_off; State =:= committed;
               State =:= applied ->
            %% Commit/apply can overtake the acknowledgement message.  Those
            %% stronger states remain authoritative.
            {reply, ok, S};
        #row{state = retired, result = Reason} ->
            {reply, {error, Reason}, S};
        #row{state = operator_error, result = Reason} ->
            {reply, {error, {operator_error, Reason}}, S};
        undefined ->
            {reply, {error, not_found}, S}
    end;
handle_call({await, EffectId, Timeout0}, From, S = #s{rows = Rows}) ->
    case maps:get(EffectId, Rows, undefined) of
        #row{state = applied} ->
            {reply, ok, S};
        #row{state = retired, result = Reason} ->
            {reply, {error, Reason}, S};
        #row{state = operator_error, result = Reason} ->
            {reply, {error, {operator_error, Reason}}, S};
        #row{} ->
            Timeout = normalize_timeout(Timeout0),
            Tag = make_ref(),
            TRef = erlang:send_after(Timeout, self(),
                                     {await_timeout, EffectId, Tag}),
            Waiters = S#s.waiters,
            Existing = maps:get(EffectId, Waiters, []),
            {noreply, S#s{waiters =
                              Waiters#{EffectId => [{From, {Tag, TRef}} |
                                                    Existing]}}};
        undefined ->
            {reply, {error, not_found}, S}
    end;
handle_call({status, EffectId}, _From, S = #s{rows = Rows}) ->
    Reply = case maps:get(EffectId, Rows, undefined) of
                #row{} = Row -> {ok, public_row(Row)};
                undefined -> {error, not_found}
    end,
    {reply, Reply, S};
handle_call({status_ref, Ref}, _From, S = #s{rows = Rows}) ->
    Matches = [public_row(Row) || {_EffectId, #row{ref = RowRef} = Row}
                                      <- maps:to_list(Rows),
                                  RowRef =:= Ref],
    Reply = case Matches of
                [Status] -> {ok, Status};
                [] -> {error, not_found};
                _ -> {error, effect_journal_conflict}
            end,
    {reply, Reply, S};
handle_call(rows, _From, S = #s{rows = Rows}) ->
    {reply, [public_row(Row) || {_Id, Row} <- lists:sort(maps:to_list(Rows))], S};
handle_call(_Request, _From, S) ->
    {reply, {error, bad_request}, S}.

handle_cast({release_applied, Height, Effects}, S0) ->
    {noreply, maybe_start(mark_committed(Height, Effects, S0))};
handle_cast({retire, Effects, Reason}, S0) ->
    {noreply, retire_rows(Effects, Reason, S0)};
handle_cast({retire_transaction, TxId, Reason}, S0) ->
    {noreply, retire_transaction_row(TxId, Reason, S0)};
handle_cast(reconcile, S = #s{reconciling = none, rows = Rows}) ->
    Parent = self(),
    {Pid, MRef} = spawn_monitor(
                    fun() -> Parent ! {reconciled, self(),
                                       reconcile_rows(Rows)} end),
    {noreply, S#s{reconciling = {Pid, MRef}}};
handle_cast(reconcile, S) ->
    {noreply, S};
handle_cast(_Message, S) ->
    {noreply, S}.

handle_info({'DOWN', MRef, process, _Pid, _Reason},
            S = #s{running = {_EffectId, _Worker, MRef}}) ->
    {noreply, maybe_start(S#s{running = none})};
handle_info({'DOWN', MRef, process, Pid, _Reason},
            S = #s{reconciling = {Pid, MRef}}) ->
    {noreply, schedule_reconcile(S#s{reconciling = none})};
handle_info({'DOWN', MRef, process, _Pid, _Reason}, S) ->
    {noreply, drop_reservation_monitor(MRef, S)};
handle_info({effect_result, EffectId, Worker, Result},
            S = #s{running = {EffectId, Worker, MRef}}) ->
    demonitor(MRef, [flush]),
    S1 = S#s{running = none},
    case Result of
        {retry, _Reason} ->
            %% Uncertainty is not a failed effect.  Keep the committed row
            %% intact and let the existing bounded reconciliation timer check
            %% the ledger and desired state again; never spin or rebuild the
            %% operation in this process.
            {noreply, schedule_reconcile(S1)};
        _ ->
            {noreply, maybe_start(finish_effect(EffectId, Result, S1))}
    end;
handle_info({await_timeout, EffectId, Tag}, S) ->
    {noreply, timeout_waiter(EffectId, Tag, S)};
handle_info({reconciled, Pid, Outcomes},
            S0 = #s{reconciling = {Pid, MRef}}) ->
    demonitor(MRef, [flush]),
    S1 = maybe_start(
           apply_reconciliation(
             Outcomes, S0#s{reconciling = none, retry_ms = 1000})),
    {noreply, schedule_reconcile(S1)};
handle_info(reconcile_retry, S0) ->
    S1 = S0#s{retry_timer = undefined},
    case unfinished_rows(S1#s.rows) of
        true ->
            gen_server:cast(self(), reconcile),
            {noreply, S1};
        false -> {noreply, S1#s{retry_ms = 1000}}
    end;
handle_info(_Message, S) ->
    {noreply, S}.

terminate(_Reason, _S) -> ok.

%%%===================================================================
%%% staging + binding
%%%===================================================================

encode_staged(Action, Desired, Effect, Prepared) ->
    case {quod_effect:validate(Effect),
          quod_durable_term:encode_goal(Action),
          quod_durable_term:encode_goal(Desired),
          quod_ontology:prepared_bytes(Prepared)} of
        {true, {ok, ActionBytes}, {ok, DesiredBytes}, {ok, PreparedBytes}} ->
            case crypto:hash(sha256, ActionBytes) =:=
                     quod_effect:request_digest(Effect) andalso
                 crypto:hash(sha256, PreparedBytes) =:=
                     quod_effect:prepared_digest(Effect) of
                true -> {ok, {Effect, ActionBytes, DesiredBytes, PreparedBytes}};
                false -> {error, invalid_direct_effect}
            end;
        _ ->
            {error, invalid_direct_effect}
    end.

bind_row(Effect, Transaction, Ref,
         S = #s{rows = Rows, reservations = Reservations}) ->
    EffectId = safe_effect_id(Effect),
    case maps:get(EffectId, Rows, undefined) of
        #row{effect = Effect, transaction = Existing, ref = Ref} ->
            case Existing =:= encode_transaction(Transaction) of
                true -> {ok, S};
                false -> {error, effect_journal_conflict}
            end;
        #row{} ->
            {error, effect_journal_conflict};
        undefined ->
            case find_staged(EffectId, Effect, Reservations) of
                {ok, Token, {Effect, Action, Desired, Prepared}} ->
                    case valid_bound_transaction(Effect, Transaction, Ref) of
                        true ->
                            case effect_admission(Effect, Ref) of
                                {ok, Admission} ->
                                    Rows1 = make_room_for_active_row(Rows),
                                    Row = #row{effect = Effect, action = Action,
                                               desired = Desired,
                                               prepared = Prepared,
                                               transaction =
                                                   encode_transaction(Transaction),
                                               ref = Ref,
                                               admission = Admission},
                                    S1 = drop_reservation(
                                           Token,
                                           S#s{rows = Rows1#{EffectId => Row}}),
                                    {ok, persist(S1)};
                                {error, _} = Error -> Error
                            end;
                        false ->
                            {error, invalid_direct_effect_transaction}
                    end;
                error ->
                    {error, missing_effect_preparation}
            end
    end.

find_staged(EffectId, Effect, Reservations) ->
    Matches =
        [{Token, Staged}
         || {Token, #reservation{staged =
                    {StagedEffect, _, _, _} = Staged}} <- maps:to_list(Reservations),
            safe_effect_id(StagedEffect) =:= EffectId,
            StagedEffect =:= Effect],
    case Matches of
        [{Token, Staged}] -> {ok, Token, Staged};
        _ -> error
    end.

valid_bound_transaction(Effect, #transaction{effects = [Effect]} = Tx,
                        {transaction, ?ROOT_NS, Anchor, TxId}) ->
    Tx#transaction.tx_id =:= TxId andalso
        quod_transaction:valid_id({?ROOT_NS, Anchor}, Tx) andalso
        quod_effect:validate_transaction(?ROOT_NS, Anchor,
                                         Tx#transaction.author, [Effect]);
valid_bound_transaction(_Effect, _Transaction, _Ref) -> false.

encode_transaction(#transaction{} = Transaction) ->
    term_to_binary(Transaction, [deterministic]);
encode_transaction(_) -> <<>>.

%%%===================================================================
%%% ordered release + execution
%%%===================================================================

mark_committed(Height, Effects, S0) when is_integer(Height), Height > 0,
                                         is_list(Effects) ->
    lists:foldl(
      fun(Effect, S) -> mark_one_committed(Height, Effect, S) end,
      S0, Effects);
mark_committed(_Height, _Effects, S) -> S.

mark_one_committed(Height, Effect, S = #s{rows = Rows}) ->
    EffectId = safe_effect_id(Effect),
    case maps:get(EffectId, Rows, undefined) of
        #row{effect = Effect, state = State} = Row
          when State =:= bound; State =:= prepared; State =:= handed_off;
               State =:= committed ->
            persist(S#s{rows = Rows#{EffectId =>
                              Row#row{state = committed, height = Height}}});
        #row{effect = Effect, state = applied} -> S;
        #row{effect = Effect, state = operator_error} -> S;
        #row{} ->
            %% Restarting cannot repair a committed descriptor that reuses a
            %% locally prepared id for different bytes. Retire any private
            %% preparation, wake its caller with one bounded result, and keep
            %% the journal alive so the conflict remains inspectable.
            logger:error(
              "quod effect journal: committed descriptor conflicts with "
              "local effect id ~p", [EffectId]),
            retire_id(EffectId, effect_journal_conflict, S);
        undefined ->
            %% The committed descriptor remains auditable, but this node has
            %% no private payload and therefore must never invent local IO.
            S
    end.

maybe_start(S = #s{running = none, rows = Rows}) ->
    Pending = lists:sort(
                [{Row#row.height, EffectId, Row}
                 || {EffectId, #row{state = committed} = Row}
                        <- maps:to_list(Rows)]),
    case Pending of
        [{_Height, EffectId, Row} | _] ->
            Parent = self(),
            {Pid, MRef} = spawn_monitor(
                            fun() ->
                                Parent ! {effect_result, EffectId, self(),
                                          execute_row(Row)}
                            end),
            S#s{running = {EffectId, Pid, MRef}};
        [] -> S
    end;
maybe_start(S) -> S.

execute_row(#row{effect = Effect, action = ActionBytes,
                 desired = DesiredBytes, prepared = PreparedBytes}) ->
    case {quod_ontology:decode_prepared(PreparedBytes),
          quod_durable_term:decode_goal(ActionBytes),
          quod_durable_term:decode_goal(DesiredBytes)} of
        {{ok, Prepared}, {ok, _Action}, {ok, Desired}} ->
            %% The desired state is the idempotency key.  A crash after the
            %% manager mutation but before this journal records `applied`
            %% restarts here and observes success without issuing a second
            %% create/join request.
            case desired_state(Desired, Effect) of
                satisfied -> ok;
                absent -> execute_and_verify(Effect, Prepared, Desired);
                incompatible -> {error, incompatible_local_state};
                {unavailable, Reason} -> {retry, Reason}
            end;
        _ ->
            {error, corrupt_prepared_effect}
    end.

execute_and_verify(Effect, Prepared, Desired) ->
    case quod_ontology:execute_prepared(Prepared) of
        {ok, _Status, Ns, Anchor} ->
            case quod_effect:target(Effect) =:= {Ns, Anchor} of
                true ->
                    maybe_test_after_execute(),
                    finish_desired_verification(Desired, Effect);
                false ->
                    {error, lifecycle_anchor_mismatch}
            end;
        {error, outcome_unknown} ->
            {retry, outcome_unknown};
        {error, {already_configured, _Ns}} ->
            %% A manager reply can be lost after its durable desired-state
            %% update.  Resolve that ambiguity through the same postcondition,
            %% never by treating the duplicate call as success on its own.
            finish_existing_verification(Desired, Effect);
        {error, Reason} ->
            {error, Reason}
    end.

finish_desired_verification(Desired, Effect) ->
    case desired_state(Desired, Effect) of
        satisfied -> ok;
        absent -> {error, postcondition_failed};
        incompatible -> {error, incompatible_local_state};
        {unavailable, Reason} -> {retry, Reason}
    end.

finish_existing_verification(Desired, Effect) ->
    case desired_state(Desired, Effect) of
        satisfied -> ok;
        absent -> {error, incompatible_local_state};
        incompatible -> {error, incompatible_local_state};
        {unavailable, Reason} -> {retry, Reason}
    end.

desired_state(Desired, Effect) ->
    case quod_prolog:prove_ro(?ROOT_NS, Desired) of
        {ok, [_ | _], _} -> desired_target_state(Effect);
        {ok, [], _} -> absent;
        {fail, _Reasons} -> absent;
        Other -> {unavailable, bounded_reason(Other)}
    end.

desired_target_state(Effect) ->
    {Ns, ExpectedAnchor} = quod_effect:target(Effect),
    case quod_ontology:genesis_anchor(Ns) of
        {ok, ExpectedAnchor} -> satisfied;
        {ok, <<_:256>>} -> incompatible;
        {error, not_hosted} -> absent;
        {error, Reason} -> {unavailable, bounded_reason(Reason)}
    end.

-ifdef(TEST).
test_desired_state(Desired, Effect) -> desired_state(Desired, Effect).
-endif.

-ifdef(TEST).
maybe_test_after_execute() ->
    case application:get_env(quod, effect_test_after_execute) of
        {ok, {Owner, Tag}} when is_pid(Owner) ->
            Journal = quod_reg:where({quod_effect_journal, node}),
            MRef = monitor(process, Journal),
            Owner ! {effect_after_execute, Tag, self()},
            receive
                {continue_effect, Tag} ->
                    demonitor(MRef, [flush]),
                    ok;
                {'DOWN', MRef, process, Journal, _Reason} ->
                    exit(normal)
            end;
        _ -> ok
    end.
-else.
maybe_test_after_execute() -> ok.
-endif.

finish_effect(EffectId, Result, S = #s{rows = Rows}) ->
    case maps:get(EffectId, Rows, undefined) of
        #row{} = Row ->
            {State, StoredResult, Reply} =
                case Result of
                    ok -> {applied, ok, ok};
                    {error, Reason} ->
                        {operator_error, bounded_reason(Reason),
                         {error, {operator_error, bounded_reason(Reason)}}}
                end,
            Terminal = compact_terminal_row(
                         Row#row{state = State, result = StoredResult}),
            S1 = persist(S#s{rows = Rows#{EffectId => Terminal}}),
            reply_waiters(EffectId, Reply, S1);
        undefined -> S
    end.

retire_rows(Effects, Reason, S0) ->
    lists:foldl(fun(Effect, S) -> retire_one(Effect, Reason, S) end,
                S0, Effects).

retire_one(Effect, Reason, S = #s{rows = Rows}) ->
    EffectId = safe_effect_id(Effect),
    case maps:get(EffectId, Rows, undefined) of
        #row{effect = Effect, state = State} = Row
          when State =:= prepared; State =:= handed_off;
               State =:= committed ->
            Reason1 = bounded_reason(Reason),
            Terminal = compact_terminal_row(
                         Row#row{state = retired, result = Reason1}),
            S1 = persist(S#s{rows = Rows#{EffectId => Terminal}}),
            reply_waiters(EffectId, {error, Reason1}, S1);
        _ -> S
    end.

retire_transaction_row(TxId, Reason, S = #s{rows = Rows}) ->
    case [EffectId || {EffectId,
                       #row{ref = {transaction, ?ROOT_NS, _Anchor, RowTxId}}}
                          <- maps:to_list(Rows),
                      RowTxId =:= TxId] of
        [EffectId] -> retire_id(EffectId, Reason, S);
        [] -> S;
        _ ->
            logger:error(
              "quod effect journal: duplicate transaction reference ~p",
              [TxId]),
            S
    end.

%%%===================================================================
%%% recovery + waiters
%%%===================================================================

reconcile_rows(Rows) ->
    [{EffectId, Row#row.state, reconcile_row(Row)}
     || {EffectId, Row} <- maps:to_list(Rows),
        Row#row.state =:= prepared orelse
        Row#row.state =:= handed_off orelse
        Row#row.state =:= committed].

reconcile_row(#row{state = prepared} = Row) ->
    {handoff, handoff_row(Row)};
reconcile_row(#row{ref = Ref}) ->
    {outcome, quod_prolog:outcome(Ref)}.

apply_reconciliation(Outcomes, S0) ->
    lists:foldl(
      fun({EffectId, prepared, {handoff, ok}}, S) ->
              mark_handed_off(EffectId, S);
         ({EffectId, prepared, {handoff, {error, not_in_charge}}}, S) ->
              retire_id(EffectId, not_in_charge, S);
         ({EffectId, prepared, {error, Reason}}, S) ->
              retire_id(EffectId, Reason, S);
         ({EffectId, _State,
           {outcome, {ok, #{status := committed, height := Height}}}}, S) ->
              mark_reconciled_committed(EffectId, Height, S);
         ({EffectId, _State,
           {outcome, {ok, #{status := rejected, reason := Reason}}}}, S) ->
              retire_id(EffectId, Reason, S);
         (_PendingOrUnavailable, S) -> S
      end, S0, Outcomes).

mark_handed_off(EffectId, S = #s{rows = Rows}) ->
    case maps:get(EffectId, Rows, undefined) of
        #row{state = prepared} = Row ->
            persist(S#s{rows = Rows#{EffectId =>
                              Row#row{state = handed_off}}});
        _ -> S
    end.

mark_reconciled_committed(EffectId, Height, S = #s{rows = Rows}) ->
    case maps:get(EffectId, Rows, undefined) of
        #row{} = Row ->
            persist(S#s{rows = Rows#{EffectId =>
                              Row#row{state = committed, height = Height}}});
        undefined -> S
    end.

retire_id(EffectId, Reason, S = #s{rows = Rows}) ->
    case maps:get(EffectId, Rows, undefined) of
        #row{state = State} = Row
          when State =:= bound; State =:= prepared; State =:= handed_off;
               State =:= committed ->
            Reason1 = bounded_reason(Reason),
            Terminal = compact_terminal_row(
                         Row#row{state = retired, result = Reason1}),
            S1 = persist(S#s{rows = Rows#{EffectId => Terminal}}),
            reply_waiters(EffectId, {error, Reason1}, S1);
        _ -> S
    end.

reply_waiters(EffectId, Reply, S = #s{waiters = Waiters}) ->
    lists:foreach(
      fun({From, {_Tag, TRef}}) ->
          _ = erlang:cancel_timer(TRef),
          gen_server:reply(From, Reply)
      end, maps:get(EffectId, Waiters, [])),
    S#s{waiters = maps:remove(EffectId, Waiters)}.

timeout_waiter(EffectId, Tag, S = #s{waiters = Waiters}) ->
    Existing = maps:get(EffectId, Waiters, []),
    {Expired, Keep} = lists:partition(
                        fun({_From, {WaitTag, _TRef}}) -> WaitTag =:= Tag end,
                        Existing),
    lists:foreach(fun({From, _}) ->
                      gen_server:reply(From, {error, outcome_unknown})
                  end, Expired),
    Waiters1 = case Keep of
                   [] -> maps:remove(EffectId, Waiters);
                   _ -> Waiters#{EffectId => Keep}
               end,
    S#s{waiters = Waiters1}.

normalize_timeout(infinity) -> ?DEFAULT_AWAIT_MS;
normalize_timeout(T) when is_integer(T), T > 0 -> min(T, ?DEFAULT_AWAIT_MS);
normalize_timeout(_) -> ?DEFAULT_AWAIT_MS.

drop_reservation(Token, S = #s{reservations = Reservations}) ->
    case maps:take(Token, Reservations) of
        {#reservation{monitor = MRef}, Rest} ->
            demonitor(MRef, [flush]),
            S#s{reservations = Rest};
        error -> S
    end.

drop_reservation_monitor(MRef, S = #s{reservations = Reservations}) ->
    Rest = maps:filter(
             fun(_Token, #reservation{monitor = Ref}) -> Ref =/= MRef end,
             Reservations),
    S#s{reservations = Rest}.

%%%===================================================================
%%% durable snapshot
%%%===================================================================

persist(S = #s{path = Path, rows = Rows}) ->
    Payload = term_to_binary(
                {quod_effect_journal, 1,
                 [encode_row(EffectId, Row)
                  || {EffectId, Row} <- lists:sort(maps:to_list(Rows))]},
                [deterministic]),
    true = byte_size(Payload) =< ?QUOD_MAX_PREPARED_EFFECT_TOTAL_BYTES,
    Digest = crypto:hash(sha256, Payload),
    Bytes = <<?MAGIC:32/unsigned-big, (byte_size(Payload)):32/unsigned-big,
              Digest/binary, Payload/binary>>,
    Tmp = Path ++ ".tmp",
    _ = file:delete(Tmp),
    {ok, Fd} = file:open(Tmp, [write, raw, binary, exclusive]),
    try
        ok = file:write(Fd, Bytes),
        ok = file:datasync(Fd)
    after
        ok = file:close(Fd)
    end,
    ok = file:rename(Tmp, Path),
    ok = sync_dir(filename:dirname(Path)),
    S.

load(Path) ->
    case file:read_file(Path) of
        {error, enoent} -> #{};
        {ok, <<?MAGIC:32/unsigned-big, Size:32/unsigned-big,
               Digest:32/binary, Payload:Size/binary>>}
          when byte_size(Payload) =< ?QUOD_MAX_PREPARED_EFFECT_TOTAL_BYTES ->
            Digest = crypto:hash(sha256, Payload),
            decode_snapshot(binary_to_term(Payload, [safe]));
        {ok, _} -> error(effect_journal_corrupt);
        {error, Reason} -> error({effect_journal_io, Reason})
    end.

decode_snapshot({quod_effect_journal, 1, Encoded})
  when is_list(Encoded), length(Encoded) =< ?QUOD_MAX_PREPARED_EFFECTS ->
    Rows = maps:from_list([decode_row(Row) || Row <- Encoded]),
    case map_size(Rows) =:= length(Encoded) of
        true -> Rows;
        false -> error(effect_journal_conflict)
    end;
decode_snapshot(_) -> error(effect_journal_corrupt).

encode_row(EffectId, #row{effect = Effect, action = Action,
                          desired = Desired, prepared = Prepared,
                          transaction = Transaction, ref = Ref,
                          admission = Admission, state = State,
                          height = Height, result = Result}) ->
    {quod_effect_row, 1, EffectId, Effect, Action, Desired, Prepared,
     Transaction, Ref, Admission, State, Height, Result}.

decode_row({quod_effect_row, 1, EffectId, Effect, Action, Desired, Prepared,
            Transaction, Ref, Admission, State, Height, Result}) ->
    Row = #row{effect = Effect, action = Action, desired = Desired,
               prepared = Prepared, transaction = Transaction, ref = Ref,
               admission = Admission, state = State,
               height = Height, result = Result},
    case valid_loaded_row(EffectId, Row) of
        true -> {EffectId, Row};
        false -> error(effect_journal_corrupt)
    end;
decode_row(_) -> error(effect_journal_corrupt).

valid_loaded_row(EffectId,
                 #row{effect = Effect, action = Action, desired = Desired,
                      prepared = Prepared, transaction = Transaction,
                      ref = {transaction, ?ROOT_NS, Anchor, TxId},
                      admission = Admission, state = State,
                      height = Height, result = Result}) ->
    safe_effect_id(Effect) =:= EffectId andalso
        quod_effect:validate(Effect) andalso
        is_binary(Action) andalso is_binary(Desired) andalso
        is_binary(Prepared) andalso is_binary(Transaction) andalso
        valid_row_payload(State, Effect, Action, Desired,
                          Prepared, Transaction) andalso
        is_binary(Anchor) andalso byte_size(Anchor) =:= 32 andalso
        is_binary(TxId) andalso byte_size(TxId) =:= 32 andalso
        is_binary(Admission) andalso byte_size(Admission) =:= 32 andalso
        lists:member(State, [bound, prepared, handed_off, committed, applied,
                             retired, operator_error]) andalso
        is_integer(Height) andalso Height >= 0 andalso
        byte_size(term_to_binary(Result, [deterministic])) =< 4096;
valid_loaded_row(_, _) -> false.

valid_row_payload(State, _Effect, <<>>, <<>>, <<>>, <<>>)
  when State =:= applied; State =:= retired; State =:= operator_error ->
    true;
valid_row_payload(State, Effect, Action, _Desired, Prepared, Transaction)
  when State =:= bound; State =:= prepared;
       State =:= handed_off; State =:= committed ->
    crypto:hash(sha256, Action) =:= quod_effect:request_digest(Effect) andalso
        crypto:hash(sha256, Prepared) =:=
            quod_effect:prepared_digest(Effect) andalso
        byte_size(Prepared) =< ?QUOD_MAX_PREPARED_EFFECT_BYTES andalso
        decode_transaction(Transaction) =/= error;
valid_row_payload(_, _, _, _, _, _) -> false.

decode_transaction(Bytes) when is_binary(Bytes) ->
    try binary_to_term(Bytes, [safe]) of
        #transaction{} = Transaction -> {ok, Transaction};
        _ -> error
    catch _:_ -> error
    end.

effect_admission(Effect, {transaction, ?ROOT_NS, Anchor, _TxId}) ->
    case quod_simplex:dtx_binding(?ROOT_NS) of
        {ok, {?ROOT_NS, Anchor, Executor, <<_:256>> = Admission}} ->
            case Executor =:= quod_effect:executor(Effect) of
                true -> {ok, Admission};
                false -> {error, not_in_charge}
            end;
        _ -> {error, not_in_charge}
    end.

handoff_row(#row{transaction = Bytes, admission = Admission}) ->
    handoff_row_bytes(Bytes, Admission).

handoff_row_bytes(Bytes, <<_:256>> = Admission) ->
    case decode_transaction(Bytes) of
        {ok, #transaction{effects = [_Effect]} = Transaction} ->
            quod_simplex:handoff_effect(
              ?ROOT_NS, Admission, Transaction);
        error -> {error, corrupt_prepared_effect}
    end.

active_row_count(Rows) ->
    maps:fold(
      fun(_Id, #row{state = State}, Count)
            when State =:= bound; State =:= prepared; State =:= handed_off;
                 State =:= committed -> Count + 1;
         (_Id, _Row, Count) -> Count
      end, 0, Rows).

make_room_for_active_row(Rows) when map_size(Rows) < ?QUOD_MAX_PREPARED_EFFECTS ->
    Rows;
make_room_for_active_row(Rows) ->
    Terminal = lists:sort(
                 [{Row#row.height, EffectId}
                  || {EffectId, #row{state = State} = Row} <- maps:to_list(Rows),
                     State =:= applied orelse State =:= retired orelse
                     State =:= operator_error]),
    case Terminal of
        [{_Height, EffectId} | _] -> maps:remove(EffectId, Rows);
        [] -> error(effect_journal_capacity_invariant)
    end.

compact_terminal_row(Row) ->
    Row#row{action = <<>>, desired = <<>>, prepared = <<>>,
            transaction = <<>>}.

retire_unactivated_rows(Rows) ->
    maps:map(
      fun(_EffectId, #row{state = bound} = Row) ->
              compact_terminal_row(
                Row#row{state = retired, result = not_activated});
         (_EffectId, Row) -> Row
      end, Rows).

unfinished_rows(Rows) ->
    maps:fold(
      fun(_Id, #row{state = State}, Found) ->
              Found orelse State =:= prepared orelse
                  State =:= handed_off orelse State =:= committed
      end, false, Rows).

schedule_reconcile(S = #s{retry_timer = undefined, rows = Rows,
                          retry_ms = Delay}) ->
    case unfinished_rows(Rows) of
        true ->
            TRef = erlang:send_after(Delay, self(), reconcile_retry),
            S#s{retry_timer = TRef, retry_ms = min(Delay * 2, 30000)};
        false -> S#s{retry_ms = 1000}
    end;
schedule_reconcile(S) -> S.

sync_dir(Dir) ->
    case file:open(Dir, [read, raw]) of
        {ok, Fd} ->
            try file:sync(Fd)
            after _ = file:close(Fd)
            end;
        {error, eisdir} -> ok;
        {error, enotsup} -> ok;
        {error, Reason} -> error({effect_journal_dir_sync, Reason})
    end.

safe_effect_id(Effect) ->
    try quod_effect:effect_id(Effect)
    catch _:_ -> <<>>
    end.

bounded_reason(Reason) ->
    case byte_size(term_to_binary(Reason, [deterministic])) =< 4096 of
        true -> Reason;
        false -> oversized_reason
    end.

public_row(#row{effect = Effect, ref = Ref, state = State,
                height = Height, result = Result}) ->
    #{effect_id => quod_effect:effect_id(Effect),
      operation => quod_effect:operation(Effect),
      target => quod_effect:target(Effect),
      ref => Ref, state => State, height => Height, result => Result}.
