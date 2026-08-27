-module(quod_effect_journal).
-moduledoc """
Crash-durable local custody for direct effects authored by this node.

The controlling ontology ledger records the small public descriptor. This
journal retains the
exact private preparation needed to execute that descriptor after ordered
apply.  It is deliberately not a catalogue or an authorization database: a
row can execute only after its matching applied transaction releases it. On
recovery the same P-before-E frontier must cover the committed height before
the journal may infer that release from the outcome index.

Active custody follows the capacity projected from committed root
policy. The journal starts unavailable for new reservations until that
projection arrives, and persists the last projected value beside its rows so a
journal-only restart cannot briefly restore a different policy. Every mutation
rewrites one checksummed snapshot through datasync + atomic rename. That keeps
recovery and compaction to one format and one authority path.
""".

-behaviour(gen_server).

-include("quod_ledger.hrl").
-include("quod_proof_limits.hrl").

-export([start_link/0, configure_capacity/1, capacity/0, stats/0,
         reserve/1, release_reservation/1,
         stage/5, bind_transaction/3, bind_group/5,
         bind_operation/8, bind_operation_transaction/3,
         cancel_operation/3,
         release_applied/2,
         activate/1, handoff/1, retire/2, retire_transaction/2,
         retire_group/4, retire_operation/3,
         await/2, reconcile/0,
         status/1, status_ref/1, rows/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2]).

-ifdef(TEST).
-export([start_link/1, test_desired_state/3]).
-endif.

-define(MAGIC, 16#51454A31). %% "QEJ1"
-define(HEADER_BYTES, 40).
-define(DEFAULT_AWAIT_MS, 60000).

-type capacity() :: non_neg_integer() | unlimited.

-record(row, {
    effect :: quod_effect:effect(),
    action :: binary(),
    desired :: binary(),
    prepared :: binary(),
    commit :: binary(),
    ref :: term(),
    admission :: <<_:256>>,
    state = transaction_bound ::
        transaction_bound | transaction_ready | transaction_submitted |
        group_pending | operation_pending |
        released | applied | retired | operator_error,
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
    capacity = unconfigured :: unconfigured | capacity(),
    rows = #{} :: #{binary() => #row{}},
    reservations = #{} :: #{reference() => #reservation{}},
    waiters = #{} :: #{binary() => [{gen_server:from(), reference()}]},
    running = none :: none | {binary(), pid(), reference()},
    reconciling = none :: none | {pid(), reference()},
    retry_timer = undefined :: undefined | reference(),
    retry_ms = 1000 :: pos_integer(),
    %% A bound row is durable but deliberately ineligible until its owning
    %% Prolog engine has exposed the exact recovery reference. Monitoring that
    %% short hand-off closes the engine-crash gap without another timer/store.
    bound_owners = #{} :: #{binary() => {pid(), reference()}}
}).

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    start_link_at(journal_data_dir()).

-ifdef(TEST).
-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Config) ->
    start_link_at(quod_ledger_store:data_dir(Config)).
-endif.

start_link_at(DataDir) ->
    gen_server:start_link(quod_reg:via({quod_effect_journal, node}),
                          ?MODULE, DataDir, []).

journal_data_dir() ->
    application:get_env(
      quod, effect_journal_data_dir, quod_ledger_store:default_data_dir()).

-doc "Install the exact committed root-policy projection used for new custody.".
-spec configure_capacity(capacity()) -> ok | {error, term()}.
configure_capacity(Capacity) ->
    call({configure_capacity, Capacity}).

-spec capacity() -> unconfigured | capacity() | {error, unavailable}.
capacity() ->
    call(capacity).

-doc "Return the node-wide custody policy and current pressure in one snapshot.".
-spec stats() ->
          #{capacity := unconfigured | capacity(),
            active := non_neg_integer(), group_active := non_neg_integer(),
            operation_active := non_neg_integer(),
            reservations := non_neg_integer(),
            terminal := non_neg_integer()} |
          {error, unavailable}.
stats() ->
    call(stats).

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

-doc "Persist one prepared effect under an already-registered dormant group intent.".
-spec bind_group(quod_dtx:plan(), term(), {binary(), <<_:256>>}, <<_:256>>,
                 {term(), term(), quod_effect:effect(), term()}) ->
          ok | {error, term()}.
bind_group(Plan, GroupRef, Target, PlanDigest, PreparedEffect) ->
    call({bind_group, Plan, GroupRef, Target, PlanDigest, PreparedEffect}).

-doc "Persist one prepared effect under an already-registered source claim.".
-spec bind_operation(quod_dtx:plan(), term(), #transaction{}, term(),
                     {binary(), <<_:256>>}, <<_:256>>, <<_:256>>,
                     {term(), term(), quod_effect:effect(), term()}) ->
          {ok, binary()} | {error, term()}.
bind_operation(Plan, ClaimRef, Claim, TargetRef, Target, CancelToken,
               PlanDigest,
               PreparedEffect) ->
    call({bind_operation, Plan, ClaimRef, Claim, TargetRef, Target,
          CancelToken, PlanDigest, PreparedEffect}).

-doc "Cancel one still-private operation effect with its source custody token.".
-spec cancel_operation(term(), term(), <<_:256>>) ->
          cancelled | not_found | {error, term()}.
cancel_operation(ClaimRef, TargetRef, <<_:256>> = CancelToken) ->
    call({cancel_operation, ClaimRef, TargetRef, CancelToken});
cancel_operation(_ClaimRef, _TargetRef, _CancelToken) ->
    {error, invalid_operation_effect}.

-doc "Attach the exact target transaction to its already-prepared operation effect.".
-spec bind_operation_transaction(term(), term(), #transaction{}) ->
          {ok, binary()} | {error, term()}.
bind_operation_transaction(ClaimRef, TargetRef, Transaction) ->
    call({bind_operation_transaction, ClaimRef, TargetRef, Transaction}).

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

-spec retire_group(term(), {binary(), <<_:256>>}, <<_:256>>, term()) -> ok.
retire_group(GroupRef, Target, PlanDigest, Reason) ->
    gen_server:cast(
      quod_reg:via({quod_effect_journal, node}),
      {retire_group, GroupRef, Target, PlanDigest, Reason}).

-spec retire_operation(term(), term(), term()) -> ok.
retire_operation(ClaimRef, TargetRef, Reason) ->
    gen_server:cast(
      quod_reg:via({quod_effect_journal, node}),
      {retire_operation, ClaimRef, TargetRef, Reason}).

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

init(DataDir) ->
    Path = filename:join(DataDir, "direct_effects.qej"),
    ok = filelib:ensure_dir(Path),
    {Capacity, Rows0} = load(Path),
    Rows = retire_unactivated_rows(Rows0),
    S0 = #s{path = Path, capacity = Capacity, rows = Rows},
    S1 = case Rows =:= Rows0 of
             true -> S0;
             false -> persist(S0)
         end,
    {ok, schedule_reconcile(S1)}.

handle_call({configure_capacity, Capacity}, _From, S0)
  when (is_integer(Capacity) andalso Capacity >= 0) orelse
       Capacity =:= unlimited ->
    S1 = install_capacity(Capacity, S0),
    {reply, ok, S1};
handle_call({configure_capacity, _Capacity}, _From, S) ->
    {reply, {error, invalid_capacity}, S};
handle_call(capacity, _From, S) ->
    {reply, S#s.capacity, S};
handle_call(stats, _From,
            S = #s{capacity = Capacity, rows = Rows,
                   reservations = Reservations}) ->
    Active = active_row_count(Rows),
    {reply,
     #{capacity => Capacity,
       active => Active,
       group_active => active_group_row_count(Rows),
       operation_active => active_operation_row_count(Rows),
       reservations => map_size(Reservations),
       terminal => map_size(Rows) - Active},
     S};

handle_call({reserve, Owner}, _From,
            S = #s{capacity = Capacity, rows = Rows,
                   reservations = Reservations}) ->
    case capacity_allows(Capacity,
                         active_row_count(Rows) + map_size(Reservations)) of
        unavailable ->
            {reply, {error, unavailable}, S};
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
handle_call({bind_transaction, Effect, Transaction, Ref}, {Owner, _}, S0) ->
    case bind_transaction_row(Effect, Transaction, Ref, S0) of
        {ok, S1} ->
            EffectId = quod_effect:effect_id(Effect),
            case track_bound_owner(EffectId, Owner, S1) of
                {ok, S2} -> {reply, ok, schedule_reconcile(S2)};
                {error, Reason} -> {reply, {error, Reason}, S1}
            end;
        {error, Reason} -> {reply, {error, Reason}, S0}
    end;
handle_call(
  {bind_group, Plan, GroupRef, Target, PlanDigest, PreparedEffect},
  _From, S0) ->
    case bind_group_row(
           Plan, GroupRef, Target, PlanDigest, PreparedEffect, S0) of
        {ok, S1} -> {reply, ok, schedule_reconcile(S1)};
        {error, Reason} -> {reply, {error, Reason}, S0}
    end;
handle_call(
  {bind_operation, Plan, ClaimRef, Claim, TargetRef, Target, CancelToken,
   PlanDigest, PreparedEffect}, _From, S0) ->
    case bind_operation_row(
           Plan, ClaimRef, Claim, TargetRef, Target, CancelToken, PlanDigest,
           PreparedEffect, S0) of
        {ok, EffectId, S1} ->
            {reply, {ok, EffectId}, S1};
        {error, Reason} ->
            {reply, {error, Reason}, S0}
    end;
handle_call(
  {cancel_operation, ClaimRef, TargetRef, CancelToken}, _From, S0) ->
    case cancel_operation_row(ClaimRef, TargetRef, CancelToken, S0) of
        {ok, Status, S1} -> {reply, Status, S1};
        {error, Reason} -> {reply, {error, Reason}, S0}
    end;
handle_call(
  {bind_operation_transaction, ClaimRef, TargetRef, Transaction},
  _From, S0) ->
    case bind_operation_transaction_row(
           ClaimRef, TargetRef, Transaction, S0) of
        {ok, EffectId, S1} ->
            {reply, {ok, EffectId}, schedule_reconcile(S1)};
        {error, Reason} ->
            {reply, {error, Reason}, S0}
    end;
handle_call({activate, EffectId}, _From, S = #s{rows = Rows}) ->
    case maps:get(EffectId, Rows, undefined) of
        #row{state = transaction_bound} = Row ->
            S1 = persist(S#s{rows = Rows#{EffectId =>
                                  Row#row{state = transaction_ready}}}),
            {reply, ok,
             schedule_reconcile(drop_bound_owner(EffectId, S1))};
        #row{state = State}
          when State =:= transaction_ready;
               State =:= transaction_submitted;
               State =:= released; State =:= applied ->
            {reply, ok, S};
        #row{state = group_pending} ->
            {reply, {error, invalid_group_effect_state}, S};
        #row{state = operation_pending} ->
            {reply, {error, operation_effect_not_attached}, S};
        #row{state = retired, result = Reason} ->
            {reply, {error, Reason}, S};
        #row{state = operator_error, result = Reason} ->
            {reply, {error, {operator_error, Reason}}, S};
        undefined ->
            {reply, {error, not_found}, S}
    end;
handle_call({handoff, EffectId}, _From, S = #s{rows = Rows}) ->
    case maps:get(EffectId, Rows, undefined) of
        #row{state = transaction_ready} = Row ->
            case handoff_row(Row) of
                ok -> {reply, ok, mark_transaction_submitted(EffectId, S)};
                {error, _} = Error ->
                    {reply, Error, schedule_reconcile(S)}
            end;
        #row{state = transaction_bound} ->
            {reply, {error, not_activated}, S};
        #row{state = group_pending} ->
            {reply, {error, invalid_group_effect_state}, S};
        #row{state = operation_pending} ->
            {reply, {error, operation_effect_not_attached}, S};
        #row{state = State}
          when State =:= transaction_submitted; State =:= released;
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
    {noreply, maybe_start(release_applied_rows(Height, Effects, S0))};
handle_cast({retire, Effects, Reason}, S0) ->
    {noreply, retire_rows(Effects, Reason, S0)};
handle_cast({retire_transaction, TxId, Reason}, S0) ->
    {noreply, retire_transaction_row(TxId, Reason, S0)};
handle_cast({retire_group, GroupRef, Target, PlanDigest, Reason}, S0) ->
    {noreply, retire_group_row(
                GroupRef, Target, PlanDigest, Reason, S0)};
handle_cast({retire_operation, ClaimRef, TargetRef, Reason}, S0) ->
    {noreply, retire_operation_row(
                ClaimRef, TargetRef, Reason, S0)};
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
    {noreply,
     drop_reservation_monitor(
       MRef, retire_bound_owner_monitor(MRef, S))};
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

bind_transaction_row(Effect, Transaction, Ref,
                     S = #s{capacity = Capacity, rows = Rows,
                            reservations = Reservations}) ->
    EffectId = safe_effect_id(Effect),
    case maps:get(EffectId, Rows, undefined) of
        #row{effect = Effect, commit = Existing, ref = Ref} ->
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
                                    Rows1 = make_room_for_active_row(
                                              Rows, Capacity),
                                    Row = #row{effect = Effect, action = Action,
                                               desired = Desired,
                                               prepared = Prepared,
                                               commit =
                                                   encode_transaction(Transaction),
                                               ref = Ref,
                                               admission = Admission,
                                               state = transaction_bound},
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

bind_group_row(
  Plan, GroupRef, Target, PlanDigest,
  {Action, Desired, Effect, Prepared},
  S = #s{capacity = Capacity, rows = Rows}) ->
    EffectId = safe_effect_id(Effect),
    Ref = {group_effect, 1, GroupRef, Target, PlanDigest},
    case maps:get(EffectId, Rows, undefined) of
        #row{effect = Effect, commit = Existing, ref = Ref,
             state = State}
          when State =:= group_pending; State =:= released;
               State =:= applied; State =:= retired;
               State =:= operator_error ->
            case encode_group_plan(Plan) of
                {ok, Existing} -> {ok, S};
                _ -> {error, effect_journal_conflict}
            end;
        #row{} ->
            {error, effect_journal_conflict};
        undefined ->
            case {capacity_allows(Capacity, active_row_count(Rows)),
                  encode_staged(Action, Desired, Effect, Prepared),
                  valid_bound_group(Effect, Plan, GroupRef, Target, PlanDigest),
                  effect_admission(Effect, Target)} of
                {unavailable, _, _, _} ->
                    {error, unavailable};
                {false, _, _, _} ->
                    {error, busy};
                {true, {ok, {Effect, ActionBytes, DesiredBytes,
                             PreparedBytes}}, true, {ok, Admission}} ->
                    {ok, PlanBlob} = encode_group_plan(Plan),
                    Rows1 = make_room_for_active_row(Rows, Capacity),
                    Row = #row{effect = Effect, action = ActionBytes,
                               desired = DesiredBytes,
                               prepared = PreparedBytes,
                               commit = PlanBlob, ref = Ref,
                               admission = Admission, state = group_pending},
                    {ok, persist(S#s{rows = Rows1#{EffectId => Row}})};
                {true, {error, _}, _, _} ->
                    {error, invalid_direct_effect};
                {true, _, false, _} ->
                    {error, invalid_group_effect};
                {true, _, _, {error, _} = Error} ->
                    Error
            end
    end;
bind_group_row(_Plan, _GroupRef, _Target, _PlanDigest,
               _PreparedEffect, _S) ->
    {error, invalid_direct_effect}.

bind_operation_row(
  Plan, ClaimRef, Claim, TargetRef, Target, CancelToken, PlanDigest,
  {Action, Desired, Effect, Prepared},
  S = #s{capacity = Capacity, rows = Rows}) ->
    EffectId = safe_effect_id(Effect),
    Ref = {operation_effect, 1, ClaimRef, TargetRef, Target,
           crypto:hash(sha256, CancelToken), PlanDigest},
    case maps:get(EffectId, Rows, undefined) of
        #row{effect = Effect, commit = Existing, ref = Ref,
             state = State}
          when State =:= operation_pending; State =:= released;
               State =:= applied; State =:= retired;
               State =:= operator_error ->
            case encode_operation_plan(Plan, Claim) of
                {ok, Existing} -> {ok, EffectId, S};
                _ -> {error, effect_journal_conflict}
            end;
        #row{} ->
            {error, effect_journal_conflict};
        undefined ->
            case {capacity_allows(Capacity, active_row_count(Rows)),
                  encode_staged(Action, Desired, Effect, Prepared),
                  valid_bound_operation(
                    Effect, Plan, ClaimRef, Claim, TargetRef,
                    Target, PlanDigest),
                  effect_admission(Effect, Target)} of
                {unavailable, _, _, _} ->
                    {error, unavailable};
                {false, _, _, _} ->
                    {error, busy};
                {true, {ok, {Effect, ActionBytes, DesiredBytes,
                             PreparedBytes}}, true, {ok, Admission}} ->
                    case encode_operation_plan(Plan, Claim) of
                        {ok, Commit} ->
                            Rows1 = make_room_for_active_row(Rows, Capacity),
                            Row = #row{effect = Effect, action = ActionBytes,
                                       desired = DesiredBytes,
                                       prepared = PreparedBytes,
                                       commit = Commit, ref = Ref,
                                       admission = Admission,
                                       state = operation_pending},
                            S1 = persist(S#s{rows = Rows1#{EffectId => Row}}),
                            {ok, EffectId, S1};
                        {error, _} ->
                            {error, invalid_operation_effect}
                    end;
                {true, {error, _}, _, _} ->
                    {error, invalid_direct_effect};
                {true, _, false, _} ->
                    {error, invalid_operation_effect};
                {true, _, _, {error, _} = Error} ->
                    Error
            end
    end;
bind_operation_row(_Plan, _ClaimRef, _Claim, _TargetRef, _Target,
                   _CancelToken, _PlanDigest, _PreparedEffect, _S) ->
    {error, invalid_direct_effect}.

bind_operation_transaction_row(
  ClaimRef, TargetRef, Transaction,
  S = #s{rows = Rows}) ->
    Matches =
        [{EffectId, Row}
         || {EffectId,
             #row{ref = {operation_effect, 1, RowClaimRef, RowTargetRef,
                         _Target, _CancelDigest, _PlanDigest},
                  state = operation_pending} = Row} <- maps:to_list(Rows),
            RowClaimRef =:= ClaimRef, RowTargetRef =:= TargetRef],
    case Matches of
        [{EffectId, Row}] ->
            case validate_operation_transaction(Row, Transaction) of
                ok ->
                    Bound = Row#row{commit = encode_transaction(Transaction),
                                    ref = TargetRef,
                                    state = transaction_ready},
                    {ok, EffectId,
                     persist(S#s{rows = Rows#{EffectId => Bound}})};
                {error, Reason} ->
                    {error, Reason}
            end;
        [] ->
            case find_attached_operation(TargetRef, Transaction, Rows) of
                {ok, EffectId} -> {ok, EffectId, S};
                error -> {error, not_found};
                conflict -> {error, effect_journal_conflict}
            end;
        _ ->
            {error, effect_journal_conflict}
    end.

find_attached_operation(TargetRef, Transaction, Rows) ->
    Matches =
        [EffectId || {EffectId, Row} <- maps:to_list(Rows),
                     attached_operation_matches(
                       TargetRef, Transaction, Row)],
    case Matches of
        [EffectId] -> {ok, EffectId};
        [] -> error;
        _ -> conflict
    end.

%% Different validators may certify the same source claim with different
%% envelopes.  The target transaction id deliberately excludes that evidence,
%% so duplicate application attempts converge on T after each envelope has
%% independently passed the ordinary transaction byte validator.
attached_operation_matches(
  {transaction, TargetNs, <<_:256>> = TargetAnchor,
   <<_:256>> = TargetTxId} = TargetRef,
  Transaction = #transaction{tx_id = TargetTxId, effects = [Effect],
                             author = Author},
  #row{ref = TargetRef, effect = Effect, admission = Admission,
       commit = ExistingBytes, state = State})
  when State =:= transaction_ready; State =:= transaction_submitted;
       State =:= released; State =:= applied ->
    Target = {TargetNs, TargetAnchor},
    case quod_safe_term:decode(ExistingBytes, ?QUOD_MAX_DTX_BODY_BYTES) of
        {ok, #transaction{tx_id = TargetTxId, effects = [Effect]}} ->
            quod_transaction:valid_id(Target, Transaction) andalso
                case quod_transaction:bytes(
                       {TargetNs, TargetAnchor, Admission}, Transaction) of
                    {ok, _} ->
                        quod_effect:validate_transaction(
                          TargetNs, TargetAnchor, Author, [Effect]);
                    {error, _} -> false
                end;
        _ -> false
    end;
attached_operation_matches(_TargetRef, _Transaction, _Row) -> false.

valid_bound_operation(
  Effect, Plan,
  {transaction, OriginNs, <<_:256>> = OriginAnchor, <<_:256>>} = ClaimRef,
  Claim = #transaction{origin = {OriginNs, OriginAnchor}},
  {transaction, TargetNs, <<_:256>> = TargetAnchor, <<_:256>> = TargetTxId},
  {TargetNs, TargetAnchor} = Target, <<_:256>> = PlanDigest)
  when is_binary(OriginNs), byte_size(OriginNs) > 0,
       is_binary(TargetNs), byte_size(TargetNs) > 0 ->
    try quod_transaction:remote_application(ClaimRef, Claim) of
        #transaction{tx_id = TargetTxId, effects = [Effect]} ->
            case quod_dtx:material(Plan) of
                {ok, #{effects := [Effect]} = Material} ->
                    quod_dtx:target(Plan) =:= Target andalso
                        quod_dtx:digest(Plan) =:= PlanDigest andalso
                        quod_effect:validate_plan(Plan, Material);
                _ -> false
            end
    catch _:_ -> false
    end;
valid_bound_operation(_Effect, _Plan, _ClaimRef, _Claim, _TargetRef,
                      _Target, _PlanDigest) ->
    false.

validate_operation_transaction(
  #row{effect = Effect,
       ref = {operation_effect, 1, ClaimRef, TargetRef,
              Target, _CancelDigest, PlanDigest}, commit = Commit},
  Transaction = #transaction{author = Author, author_seq = 0, sig = none,
                             effects = [Effect]}) ->
    case decode_operation_plan(Commit) of
        {ok, Plan, Claim} ->
            validate_operation_transaction_fields(
              Plan, Claim, ClaimRef, TargetRef, Target, PlanDigest,
              Transaction, Author, Effect);
        error -> {error, invalid_operation_plan}
    end;
validate_operation_transaction(_Row, _Transaction) ->
    {error, invalid_direct_effect_transaction}.

validate_operation_transaction_fields(
  Plan, Claim, ClaimRef, TargetRef, Target, PlanDigest,
  Transaction, Author, Effect) ->
    try quod_transaction:remote_application(ClaimRef, Claim) of
        Expected ->
            operation_transaction_verdict(
              [{application_id,
                Expected#transaction.tx_id =:= Transaction#transaction.tx_id},
               {target_ref,
                element(4, TargetRef) =:= Transaction#transaction.tx_id},
               {transaction_id,
                quod_transaction:valid_id(Target, Transaction)},
               {plan_digest, quod_dtx:digest(Plan) =:= PlanDigest},
               {plan_signer, quod_dtx:signer(Plan) =:= Author},
               {effect,
                quod_effect:validate_transaction(
                  element(1, Target), element(2, Target), Author, [Effect])}])
    catch _:_ -> {error, invalid_operation_plan}
    end.

operation_transaction_verdict([]) -> ok;
operation_transaction_verdict([{_Name, true} | Rest]) ->
    operation_transaction_verdict(Rest);
operation_transaction_verdict([{Name, false} | _Rest]) ->
    {error, {invalid_operation_transaction, Name}}.

encode_operation_plan(Plan, #transaction{} = Claim) ->
    case quod_dtx:encode(Plan) of
        {ok, PlanBytes} ->
            Bytes = term_to_binary(
                      {quod_operation_effect, 1, PlanBytes, Claim},
                      [deterministic]),
            case byte_size(Bytes) =< ?QUOD_MAX_DTX_BODY_BYTES of
                true -> {ok, Bytes};
                false -> {error, too_large}
            end;
        {error, _} = Error -> Error
    end;
encode_operation_plan(_, _) -> {error, invalid_operation_effect}.

decode_operation_plan(Bytes) when is_binary(Bytes) ->
    case quod_safe_term:decode(Bytes, ?QUOD_MAX_DTX_BODY_BYTES) of
        {ok, {quod_operation_effect, 1, PlanBytes,
              #transaction{} = Claim} = Term}
          when is_binary(PlanBytes) ->
            case term_to_binary(Term, [deterministic]) =:= Bytes of
                true ->
                    case quod_dtx:decode(PlanBytes) of
                        {ok, Plan} -> {ok, Plan, Claim};
                        {error, _} -> error
                    end;
                false -> error
            end;
        _ -> error
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
                        {transaction, Ns, Anchor, TxId})
  when is_binary(Ns), byte_size(Ns) > 0 ->
    Tx#transaction.tx_id =:= TxId andalso
        quod_transaction:valid_id({Ns, Anchor}, Tx) andalso
        quod_effect:validate_transaction(Ns, Anchor,
                                         Tx#transaction.author, [Effect]);
valid_bound_transaction(_Effect, _Transaction, _Ref) -> false.

encode_transaction(#transaction{} = Transaction) ->
    term_to_binary(Transaction, [deterministic]);
encode_transaction(_) -> <<>>.

encode_group_plan(Plan) ->
    quod_dtx:encode(Plan).

valid_bound_group(
  Effect, Plan,
  {group, OriginNs, <<_:256>>, <<_:256>>, <<_:256>>, <<_:256>>},
  {TargetNs, <<_:256>>} = Target, <<_:256>> = PlanDigest)
  when is_binary(OriginNs), byte_size(OriginNs) > 0,
       is_binary(TargetNs), byte_size(TargetNs) > 0 ->
    case quod_dtx:material(Plan) of
        {ok, #{effects := [Effect]} = Material} ->
            quod_dtx:target(Plan) =:= Target andalso
                quod_dtx:digest(Plan) =:= PlanDigest andalso
                quod_effect:validate_plan(Plan, Material);
        _ ->
            false
    end;
valid_bound_group(_Effect, _Plan, _GroupRef, _Target, _PlanDigest) ->
    false.

%%%===================================================================
%%% ordered release + execution
%%%===================================================================

release_applied_rows(Height, Effects, S0)
  when is_integer(Height), Height > 0, is_list(Effects) ->
    lists:foldl(
      fun(Effect, S) -> release_applied_row(Height, Effect, S) end,
      S0, Effects);
release_applied_rows(_Height, _Effects, S) -> S.

release_applied_row(Height, Effect, S = #s{rows = Rows}) ->
    EffectId = safe_effect_id(Effect),
    case maps:get(EffectId, Rows, undefined) of
        #row{effect = Effect, state = State} = Row
          when State =:= transaction_bound;
               State =:= transaction_ready;
               State =:= transaction_submitted;
               State =:= group_pending;
               State =:= released ->
            persist(S#s{rows = Rows#{EffectId =>
                              Row#row{state = released, height = Height}}});
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
                 || {EffectId, #row{state = released} = Row}
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
                 desired = DesiredBytes, prepared = PreparedBytes,
                 ref = Ref}) ->
    ControlNs = control_namespace(Ref),
    case {quod_ontology:decode_prepared(PreparedBytes),
          quod_durable_term:decode_goal(ActionBytes),
          quod_durable_term:decode_goal(DesiredBytes)} of
        {{ok, Prepared}, {ok, _Action}, {ok, Desired}} ->
            %% The desired state is the idempotency key.  A crash after the
            %% manager mutation but before this journal records `applied`
            %% restarts here and observes success without issuing a second
            %% create/join request.
            case desired_state(ControlNs, Desired, Effect) of
                satisfied -> ok;
                absent -> execute_and_verify(
                            ControlNs, Effect, Prepared, Desired);
                incompatible -> {error, incompatible_local_state};
                {unavailable, Reason} -> {retry, Reason}
            end;
        _ ->
            {error, corrupt_prepared_effect}
    end.

control_namespace({transaction, Ns, _, _}) -> Ns;
control_namespace(
  {group_effect, 1, _GroupRef, {Ns, _Anchor}, _PlanDigest}) -> Ns.

execute_and_verify(ControlNs, Effect, Prepared, Desired) ->
    case quod_ontology:execute_prepared(Prepared) of
        {ok, _Status, Ns, Anchor} ->
            case quod_effect:target(Effect) =:= {Ns, Anchor} of
                true ->
                    maybe_test_after_execute(),
                    finish_desired_verification(ControlNs, Desired, Effect);
                false ->
                    {error, lifecycle_anchor_mismatch}
            end;
        {error, outcome_unknown} ->
            {retry, outcome_unknown};
        {error, {already_configured, _Ns}} ->
            %% A manager reply can be lost after its durable desired-state
            %% update.  Resolve that ambiguity through the same postcondition,
            %% never by treating the duplicate call as success on its own.
            finish_existing_verification(ControlNs, Desired, Effect);
        {error, Reason} ->
            {error, Reason}
    end.

finish_desired_verification(ControlNs, Desired, Effect) ->
    case desired_state(ControlNs, Desired, Effect) of
        satisfied -> ok;
        absent -> {error, postcondition_failed};
        incompatible -> {error, incompatible_local_state};
        {unavailable, Reason} -> {retry, Reason}
    end.

finish_existing_verification(ControlNs, Desired, Effect) ->
    case desired_state(ControlNs, Desired, Effect) of
        satisfied -> ok;
        absent -> {error, incompatible_local_state};
        incompatible -> {error, incompatible_local_state};
        {unavailable, Reason} -> {retry, Reason}
    end.

desired_state(ControlNs, Desired, Effect) ->
    case quod_prolog:prove_ro(ControlNs, Desired) of
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
test_desired_state(ControlNs, Desired, Effect) ->
    desired_state(ControlNs, Desired, Effect).
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
          when State =:= transaction_bound;
               State =:= transaction_ready;
               State =:= transaction_submitted;
               State =:= group_pending; State =:= operation_pending;
               State =:= released ->
            Reason1 = bounded_reason(Reason),
            Terminal = compact_terminal_row(
                         Row#row{state = retired, result = Reason1}),
            S1 = persist(S#s{rows = Rows#{EffectId => Terminal}}),
            reply_waiters(EffectId, {error, Reason1}, S1);
        _ -> S
    end.

retire_transaction_row(TxId, Reason, S = #s{rows = Rows}) ->
    case [EffectId || {EffectId,
                       #row{ref = {transaction, _Ns, _Anchor, RowTxId}}}
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

retire_group_row(GroupRef, Target, PlanDigest, Reason,
                 S = #s{rows = Rows}) ->
    Ref = {group_effect, 1, GroupRef, Target, PlanDigest},
    case [EffectId || {EffectId, #row{ref = RowRef}}
                          <- maps:to_list(Rows), RowRef =:= Ref] of
        [EffectId] -> retire_id(EffectId, Reason, S);
        [] -> S;
        _ ->
            logger:error(
              "quod effect journal: duplicate group effect reference ~p",
              [Ref]),
            S
    end.

retire_operation_row(ClaimRef, TargetRef, Reason,
                     S = #s{rows = Rows}) ->
    Matches =
        [EffectId
         || {EffectId,
             #row{ref = {operation_effect, 1, RowClaimRef, RowTargetRef,
                         _Target, _CancelDigest, _PlanDigest}}} <-
                 maps:to_list(Rows),
            RowClaimRef =:= ClaimRef, RowTargetRef =:= TargetRef],
    case Matches of
        [EffectId] -> retire_id(EffectId, Reason, S);
        [] -> S;
        _ ->
            logger:error(
              "quod effect journal: duplicate operation effect reference ~p",
              [{ClaimRef, TargetRef}]),
            S
    end.

cancel_operation_row(ClaimRef, TargetRef, CancelToken,
                     S = #s{rows = Rows}) ->
    CancelDigest = crypto:hash(sha256, CancelToken),
    Matches =
        [EffectId
         || {EffectId,
             #row{state = operation_pending,
                  ref = {operation_effect, 1, RowClaimRef, RowTargetRef,
                         _Target, RowCancelDigest, _PlanDigest}}} <-
                maps:to_list(Rows),
            RowClaimRef =:= ClaimRef, RowTargetRef =:= TargetRef,
            RowCancelDigest =:= CancelDigest],
    case Matches of
        [EffectId] ->
            {ok, cancelled,
             retire_id(EffectId, source_intent_cancelled, S)};
        [] ->
            {ok, not_found, S};
        _ ->
            {error, effect_journal_conflict}
    end.

%%%===================================================================
%%% recovery + waiters
%%%===================================================================

reconcile_rows(Rows) ->
    [{EffectId, Row#row.state, reconcile_row(Row)}
     || {EffectId, Row} <- maps:to_list(Rows),
        Row#row.state =:= transaction_ready orelse
        Row#row.state =:= transaction_submitted orelse
        Row#row.state =:= group_pending orelse
        Row#row.state =:= released].

reconcile_row(#row{state = transaction_ready} = Row) ->
    {handoff, handoff_row(Row)};
reconcile_row(#row{state = transaction_submitted,
                   ref = {transaction, ControlNs, _, _} = Ref}) ->
    case quod_prolog:outcome(Ref) of
        {ok, #{status := committed, height := Height}} = Outcome ->
            case quod_runtime:effect_frontier(ControlNs) of
                {ok, Frontier} when Frontier >= Height -> {outcome, Outcome};
                _ -> projection_pending
            end;
        Outcome -> {outcome, Outcome}
    end;
reconcile_row(
  #row{state = group_pending,
       ref = {group_effect, 1, GroupRef, Target, PlanDigest}}) ->
    {group, quod_prolog:effect_resolution(Target, GroupRef, PlanDigest)};
reconcile_row(#row{state = released}) ->
    released.

apply_reconciliation(Outcomes, S0) ->
    lists:foldl(
      fun({EffectId, transaction_ready, {handoff, ok}}, S) ->
              mark_transaction_submitted(EffectId, S);
         ({EffectId, transaction_ready,
           {handoff, {error, not_in_charge}}}, S) ->
              retire_id(EffectId, not_in_charge, S);
         ({EffectId, transaction_ready, {handoff, {error, Reason}}}, S)
           when Reason =:= bad_change;
                Reason =:= corrupt_prepared_effect ->
              retire_id(EffectId, Reason, S);
         ({EffectId, _State,
           {outcome, {ok, #{status := committed, height := Height}}}}, S) ->
              mark_reconciled_release(EffectId, Height, S);
         ({EffectId, _State,
           {outcome, {ok, #{status := rejected, reason := Reason}}}}, S) ->
              retire_id(EffectId, Reason, S);
         ({EffectId, group_pending,
           {group, {ok, {released, Height}}}}, S) ->
              mark_reconciled_release(EffectId, Height, S);
         ({EffectId, group_pending,
           {group, {ok, {retired, Reason}}}}, S) ->
              retire_id(EffectId, Reason, S);
         (_PendingOrUnavailable, S) -> S
      end, S0, Outcomes).

mark_transaction_submitted(EffectId, S = #s{rows = Rows}) ->
    case maps:get(EffectId, Rows, undefined) of
        #row{state = transaction_ready} = Row ->
            persist(S#s{rows = Rows#{EffectId =>
                              Row#row{state = transaction_submitted}}});
        _ -> S
    end.

mark_reconciled_release(EffectId, Height, S = #s{rows = Rows}) ->
    case maps:get(EffectId, Rows, undefined) of
        #row{state = State} = Row
          when State =:= transaction_bound;
               State =:= transaction_ready;
               State =:= transaction_submitted;
               State =:= group_pending; State =:= operation_pending;
               State =:= released ->
            persist(S#s{rows = Rows#{EffectId =>
                              Row#row{state = released, height = Height}}});
        _ -> S
    end.

retire_id(EffectId, Reason, S = #s{rows = Rows}) ->
    case maps:get(EffectId, Rows, undefined) of
        #row{state = State} = Row
          when State =:= transaction_bound;
               State =:= transaction_ready;
               State =:= transaction_submitted;
               State =:= group_pending; State =:= operation_pending;
               State =:= released ->
            Reason1 = bounded_reason(Reason),
            Terminal = compact_terminal_row(
                         Row#row{state = retired, result = Reason1}),
            S1 = persist(
                   drop_bound_owner(
                     EffectId,
                     S#s{rows = Rows#{EffectId => Terminal}})),
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

track_bound_owner(EffectId, Owner,
                  S = #s{rows = Rows, bound_owners = Owners}) ->
    case {maps:get(EffectId, Rows, undefined),
          maps:get(EffectId, Owners, undefined)} of
        {#row{state = transaction_bound}, undefined} ->
            MRef = monitor(process, Owner),
            {ok, S#s{bound_owners = Owners#{EffectId => {Owner, MRef}}}};
        {#row{state = transaction_bound}, {Owner, _MRef}} ->
            {ok, S};
        {#row{state = transaction_bound}, {_OtherOwner, _MRef}} ->
            {error, effect_journal_conflict};
        {#row{}, _} ->
            {ok, S};
        {undefined, _} ->
            {error, not_found}
    end.

drop_bound_owner(EffectId, S = #s{bound_owners = Owners}) ->
    case maps:take(EffectId, Owners) of
        {{_Owner, MRef}, Rest} ->
            demonitor(MRef, [flush]),
            S#s{bound_owners = Rest};
        error -> S
    end.

retire_bound_owner_monitor(MRef, S = #s{bound_owners = Owners}) ->
    case [EffectId || {EffectId, {_Owner, Ref}} <- maps:to_list(Owners),
                      Ref =:= MRef] of
        [EffectId] -> retire_id(EffectId, not_activated, S);
        [] -> S
    end.

%%%===================================================================
%%% durable snapshot
%%%===================================================================

persist(S = #s{path = Path, capacity = Capacity, rows = Rows}) ->
    Payload = term_to_binary(
                {quod_effect_journal, 5, Capacity,
                 [encode_row(EffectId, Row)
                  || {EffectId, Row} <- lists:sort(maps:to_list(Rows))]},
                [deterministic]),
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
        {error, enoent} -> {unconfigured, #{}};
        {ok, <<?MAGIC:32/unsigned-big, Size:32/unsigned-big,
               Digest:32/binary, Payload:Size/binary>>} ->
            Digest = crypto:hash(sha256, Payload),
            decode_snapshot(binary_to_term(Payload, [safe]));
        {ok, _} -> error(effect_journal_corrupt);
        {error, Reason} -> error({effect_journal_io, Reason})
    end.

decode_snapshot({quod_effect_journal, 5, Capacity, Encoded})
  when ((is_integer(Capacity) andalso Capacity >= 0) orelse
        Capacity =:= unlimited),
       is_list(Encoded) ->
    Rows = maps:from_list([decode_row(Row) || Row <- Encoded]),
    case map_size(Rows) =:= length(Encoded) of
        true -> {Capacity, Rows};
        false -> error(effect_journal_conflict)
    end;
decode_snapshot({quod_effect_journal, Version, _Encoded})
  when is_integer(Version) ->
    error({effect_journal_format_unsupported, Version});
decode_snapshot({quod_effect_journal, Version, _Capacity, _Encoded})
  when is_integer(Version) ->
    error({effect_journal_format_unsupported, Version});
decode_snapshot(_) -> error(effect_journal_corrupt).

encode_row(EffectId, #row{effect = Effect, action = Action,
                          desired = Desired, prepared = Prepared,
                          commit = Commit, ref = Ref,
                          admission = Admission, state = State,
                          height = Height, result = Result}) ->
    {quod_effect_row, 4, EffectId, Effect, Action, Desired, Prepared,
     Commit, Ref, Admission, State, Height, Result}.

decode_row({quod_effect_row, 4, EffectId, Effect, Action, Desired, Prepared,
            Commit, Ref, Admission, State, Height, Result}) ->
    Row = #row{effect = Effect, action = Action, desired = Desired,
               prepared = Prepared, commit = Commit, ref = Ref,
               admission = Admission, state = State,
               height = Height, result = Result},
    case valid_loaded_row(EffectId, Row) of
        true -> {EffectId, Row};
        false -> error(effect_journal_corrupt)
    end;
decode_row(_) -> error(effect_journal_corrupt).

valid_loaded_row(
  EffectId,
  #row{effect = Effect, action = Action, desired = Desired,
       prepared = Prepared, commit = Commit, ref = Ref,
       admission = Admission, state = State,
       height = Height, result = Result} = Row) ->
    safe_effect_id(Effect) =:= EffectId andalso
        quod_effect:validate(Effect) andalso
        is_binary(Action) andalso is_binary(Desired) andalso
        is_binary(Prepared) andalso is_binary(Commit) andalso
        is_binary(Admission) andalso byte_size(Admission) =:= 32 andalso
        valid_row_ref_state(Ref, State) andalso valid_row_payload(Row) andalso
        is_integer(Height) andalso Height >= 0 andalso
        byte_size(term_to_binary(Result, [deterministic])) =< 4096.

valid_row_ref_state(
  {transaction, Ns, <<_:256>>, <<_:256>>}, State)
  when is_binary(Ns), byte_size(Ns) > 0 ->
    lists:member(
      State, [transaction_bound, transaction_ready,
              transaction_submitted, released, applied,
              retired, operator_error]);
valid_row_ref_state(
  {group_effect, 1,
   {group, OriginNs, <<_:256>>, <<_:256>>, <<_:256>>, <<_:256>>},
   {TargetNs, <<_:256>>}, <<_:256>>}, State)
  when is_binary(OriginNs), byte_size(OriginNs) > 0,
       is_binary(TargetNs), byte_size(TargetNs) > 0 ->
    lists:member(
      State, [group_pending, released, applied, retired, operator_error]);
valid_row_ref_state(
  {operation_effect, 1,
   {transaction, OriginNs, <<_:256>>, <<_:256>>},
   {transaction, TargetNs, <<_:256>> = TargetAnchor, <<_:256>>},
   {TargetNs, TargetAnchor}, <<_:256>>, <<_:256>>}, operation_pending)
  when is_binary(OriginNs), byte_size(OriginNs) > 0,
       is_binary(TargetNs), byte_size(TargetNs) > 0 ->
    true;
valid_row_ref_state(_, _) -> false.

valid_row_payload(
  #row{state = State, action = <<>>, desired = <<>>,
       prepared = <<>>, commit = <<>>})
  when State =:= applied; State =:= retired; State =:= operator_error ->
    true;
valid_row_payload(
  #row{state = State, effect = Effect, action = Action,
       prepared = Prepared, commit = Commit,
       ref = {transaction, _, _, _}})
  when State =:= transaction_bound; State =:= transaction_ready;
       State =:= transaction_submitted; State =:= released ->
    crypto:hash(sha256, Action) =:= quod_effect:request_digest(Effect) andalso
        crypto:hash(sha256, Prepared) =:=
            quod_effect:prepared_digest(Effect) andalso
        byte_size(Prepared) =< ?QUOD_MAX_PREPARED_EFFECT_BYTES andalso
        decode_transaction(Commit) =/= error;
valid_row_payload(
  #row{state = State, effect = Effect, action = Action,
       prepared = Prepared, commit = Commit,
       ref = {group_effect, 1, _GroupRef, Target, PlanDigest}})
  when State =:= group_pending; State =:= released ->
    crypto:hash(sha256, Action) =:= quod_effect:request_digest(Effect) andalso
        crypto:hash(sha256, Prepared) =:=
            quod_effect:prepared_digest(Effect) andalso
        byte_size(Prepared) =< ?QUOD_MAX_PREPARED_EFFECT_BYTES andalso
        valid_group_commit(Commit, Effect, Target, PlanDigest);
valid_row_payload(
  #row{state = operation_pending, effect = Effect, action = Action,
       prepared = Prepared, commit = Commit,
       ref = {operation_effect, 1, ClaimRef, TargetRef,
              Target, _CancelDigest, PlanDigest}}) ->
    crypto:hash(sha256, Action) =:= quod_effect:request_digest(Effect) andalso
        crypto:hash(sha256, Prepared) =:=
            quod_effect:prepared_digest(Effect) andalso
        byte_size(Prepared) =< ?QUOD_MAX_PREPARED_EFFECT_BYTES andalso
        case decode_operation_plan(Commit) of
            {ok, Plan, Claim} ->
                valid_bound_operation(
                  Effect, Plan, ClaimRef, Claim, TargetRef,
                  Target, PlanDigest);
            error -> false
        end;
valid_row_payload(_) -> false.

valid_group_commit(Commit, Effect, Target, PlanDigest) ->
    case quod_dtx:decode(Commit) of
        {ok, Plan} ->
            case quod_dtx:material(Plan) of
                {ok, #{effects := [Effect]} = Material} ->
                    quod_dtx:target(Plan) =:= Target andalso
                        quod_dtx:digest(Plan) =:= PlanDigest andalso
                        quod_effect:validate_plan(Plan, Material);
                _ -> false
            end;
        {error, _} -> false
    end.

decode_transaction(Bytes) when is_binary(Bytes) ->
    try binary_to_term(Bytes, [safe]) of
        #transaction{} = Transaction -> {ok, Transaction};
        _ -> error
    catch _:_ -> error
    end.

effect_admission(Effect, {transaction, Ns, Anchor, _TxId}) ->
    effect_admission(Effect, {Ns, Anchor});
effect_admission(Effect, {Ns, Anchor}) ->
    case quod_simplex:dtx_binding(Ns) of
        {ok, {Ns, Anchor, Executor, <<_:256>> = Admission}} ->
            case Executor =:= quod_effect:executor(Effect) of
                true -> {ok, Admission};
                false -> {error, not_in_charge}
            end;
        _ -> {error, not_in_charge}
    end;
effect_admission(_Effect, _Binding) ->
    {error, not_in_charge}.

handoff_row(#row{commit = Bytes, admission = Admission,
                 ref = {transaction, Ns, _, _}}) ->
    handoff_row_bytes(Ns, Bytes, Admission).

handoff_row_bytes(Ns, Bytes, <<_:256>> = Admission) ->
    case decode_transaction(Bytes) of
        {ok, #transaction{effects = [_Effect]} = Transaction} ->
            quod_simplex:handoff_effect(Ns, Admission, Transaction);
        error -> {error, corrupt_prepared_effect}
    end.

active_row_count(Rows) ->
    maps:fold(
      fun(_Id, #row{state = State}, Count)
            when State =:= transaction_bound;
                 State =:= transaction_ready;
                 State =:= transaction_submitted;
                 State =:= group_pending; State =:= operation_pending;
                 State =:= released -> Count + 1;
         (_Id, _Row, Count) -> Count
      end, 0, Rows).

active_group_row_count(Rows) ->
    maps:fold(
      fun(_Id, #row{state = State,
                    ref = {group_effect, 1, _, _, _}}, Count)
            when State =:= group_pending; State =:= released -> Count + 1;
         (_Id, _Row, Count) -> Count
      end, 0, Rows).

active_operation_row_count(Rows) ->
    maps:fold(
      fun(_Id, #row{state = operation_pending,
                    ref = {operation_effect, 1, _, _, _, _, _}}, Count) ->
              Count + 1;
         (_Id, _Row, Count) -> Count
      end, 0, Rows).

capacity_allows(unconfigured, _Active) -> unavailable;
capacity_allows(unlimited, _Active) -> true;
capacity_allows(Capacity, Active)
  when is_integer(Capacity), Capacity >= 0 ->
    Active < Capacity.

install_capacity(Capacity,
                 S = #s{capacity = OldCapacity, rows = Rows}) ->
    Rows1 = trim_terminal_rows(Rows, Capacity),
    case Capacity =:= OldCapacity andalso Rows1 =:= Rows of
        true -> S;
        false -> persist(S#s{capacity = Capacity, rows = Rows1})
    end.

trim_terminal_rows(Rows, unlimited) ->
    Rows;
trim_terminal_rows(Rows, Capacity) when map_size(Rows) =< Capacity ->
    Rows;
trim_terminal_rows(Rows, Capacity) ->
    Terminal = lists:sort(
                 [{Row#row.height, EffectId}
                  || {EffectId, #row{state = State} = Row} <- maps:to_list(Rows),
                     State =:= applied orelse State =:= retired orelse
                     State =:= operator_error]),
    case Terminal of
        [{_Height, EffectId} | _] ->
            trim_terminal_rows(maps:remove(EffectId, Rows), Capacity);
        [] -> Rows
    end.

make_room_for_active_row(Rows, unconfigured) ->
    Rows;
make_room_for_active_row(Rows, unlimited) ->
    Rows;
make_room_for_active_row(Rows, Capacity) when map_size(Rows) < Capacity ->
    Rows;
make_room_for_active_row(Rows, Capacity) ->
    Terminal = lists:sort(
                 [{Row#row.height, EffectId}
                  || {EffectId, #row{state = State} = Row} <- maps:to_list(Rows),
                     State =:= applied orelse State =:= retired orelse
                     State =:= operator_error]),
    case Terminal of
        [{_Height, EffectId} | _] ->
            make_room_for_active_row(maps:remove(EffectId, Rows), Capacity);
        [] -> Rows
    end.

compact_terminal_row(Row) ->
    Row#row{action = <<>>, desired = <<>>, prepared = <<>>,
            commit = <<>>}.

retire_unactivated_rows(Rows) ->
    maps:map(
      fun(_EffectId, #row{state = transaction_bound} = Row) ->
              compact_terminal_row(
                Row#row{state = retired, result = not_activated});
         (_EffectId, Row) -> Row
      end, Rows).

unfinished_rows(Rows) ->
    maps:fold(
      fun(_Id, #row{state = State}, Found) ->
              Found orelse State =:= transaction_ready orelse
                  State =:= transaction_submitted orelse
                  State =:= group_pending orelse State =:= released
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
