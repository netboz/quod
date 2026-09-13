-module(quod_action_predicates).
-moduledoc """
Internal mechanics for the common `action/3` relation.

The public model remains Prolog: `goal/1` enumerates declarations. These private
mechanics validate candidate shape, scope state queries read-only and run the
existing candidate body under the shared internal proof savepoint. Rollback
does not select atomic intent; no generic savepoint control is exposed.
""".

-include_lib("erlog/src/erlog_int.hrl").

-export([load/1, callable_1/3, action_shape_3/3,
         state_check_1/3, state_check_yield_1/3, candidate_4/3]).

-define(CALLABLE, '$quod_callable').
-define(ACTION_SHAPE, '$quod_action_shape').
-define(STATE_CHECK, '$quod_state_check').
-define(STATE_CHECK_YIELD, '$quod_state_check_yield').
-define(CANDIDATE, '$quod_action_candidate').

-record(read_scope, {
    ref         :: reference(),
    frame       :: term(),
    caller_next :: list()
}).

-doc "Register the private action mechanics before common predicates load.".
-spec load(tuple()) -> tuple().
load(#est{db = Db0} = Est) ->
    Db1 = erlog_int:add_compiled_proc(
            {?CALLABLE, 1}, ?MODULE, callable_1, Db0),
    Db2 = erlog_int:add_compiled_proc(
            {?ACTION_SHAPE, 3}, ?MODULE, action_shape_3, Db1),
    Db3 = erlog_int:add_compiled_proc(
            {?STATE_CHECK, 1}, ?MODULE, state_check_1, Db2),
    Db4 = erlog_int:add_compiled_proc({?CANDIDATE, 4}, ?MODULE, candidate_4, Db3),
    Est#est{db = erlog_int:add_compiled_proc(
                   {?STATE_CHECK_YIELD, 1}, ?MODULE,
                   state_check_yield_1, Db4)}.

%% This action-specific mechanics seam calls the same Prolog prerequisites,
%% transition and postcondition as before. It exposes no generic rollback goal.
-spec candidate_4(term(), list(), tuple()) -> term().
candidate_4({?CANDIDATE, Transition, Prerequisites, DesiredState, Visited}, Next, St) ->
    Inner = {',', {satisfy_prerequisites, Prerequisites, Visited},
             {',', {run_transition, Transition}, {?STATE_CHECK, DesiredState}}},
    quod_proof_savepoint:run(
      Inner, Next, St, quod_erlog_db_local_prove:write_intent(St)).

-spec callable_1(term(), list(), tuple()) -> term().
callable_1({?CALLABLE, Term}, Next, St) ->
    continue_if(callable(Term, St#est.bs), Next, St).

-spec action_shape_3(term(), list(), tuple()) -> term().
action_shape_3({?ACTION_SHAPE, Transition, Prerequisites, DesiredState},
               Next, St) ->
    Bs = St#est.bs,
    Valid = erlog_int:deref(DesiredState, Bs) =/= true
            andalso callable(DesiredState, Bs)
            andalso proper_callable_list(Prerequisites, Bs, empty_allowed)
            andalso transition_shape(Transition, Bs),
    continue_if(Valid, Next, St).

-spec state_check_1(term(), list(), tuple()) -> term().
state_check_1({?STATE_CHECK, Inner}, Next,
              #est{cps = OuterCps, bs = Bs, vn = Vn} = St) ->
    Desired = erlog_int:dderef(Inner, Bs),
    case quod_erlog_db_local_prove:staged_desired_state(St, Desired) of
        true ->
            erlog_int:prove_body(Next, St);
        false ->
            {Frame, ReadOnly} =
                quod_erlog_db_local_prove:enter_read_only(St),
            Ref = make_ref(),
            Scope = #read_scope{ref = Ref, frame = Frame,
                                caller_next = Next},
            Failed = fun state_check_failed/3,
            Boundary = #cp{type = compiled, label = {?MODULE, Ref},
                           data = Failed, next = Scope, bs = Bs, vn = Vn},
            Active = ReadOnly#est{cps = [Boundary | OuterCps]},
            run_read_only(
              fun() ->
                  erlog_int:prove_body(
                    [{call, Inner}, {?STATE_CHECK_YIELD, Ref}], Active)
              end, Scope, Active)
    end.

-spec state_check_yield_1(term(), list(), tuple()) -> term().
state_check_yield_1({?STATE_CHECK_YIELD, Ref}, _InternalNext,
                    #est{cps = Cps, bs = Bs, vn = Vn} = St) ->
    case take_boundary(Ref, Cps, []) of
        {ok, InnerRev, Boundary,
         #read_scope{frame = Frame, caller_next = CallerNext} = Scope,
         OuterCps} ->
            Writable = quod_erlog_db_local_prove:leave_read_only(
                         St#est{cps = OuterCps}, Frame),
            RedoData = {Scope, Boundary, InnerRev},
            Redo = #cp{type = compiled, label = {?MODULE, Ref},
                       data = fun state_check_redo/3, next = RedoData,
                       bs = Bs, vn = Vn},
            WithRedo = erlog_int:push_choicepoint(Redo, Writable),
            quod_proof_continuation:prove(Ref, CallerNext, WithRedo);
        error ->
            erlog_int:erlog_error(
              {system_error, missing_state_check_boundary}, St)
    end.

state_check_redo(
  #cp{next = {#read_scope{} = Scope, Boundary, InnerRev},
      bs = Bs, vn = Vn},
  OuterCps, St) ->
    {Frame, ReadOnly0} = quod_erlog_db_local_prove:enter_read_only(
                           St#est{cps = OuterCps, bs = Bs, vn = Vn}),
    Scope1 = Scope#read_scope{frame = Frame},
    Boundary1 = Boundary#cp{next = Scope1},
    Active = ReadOnly0#est{
               cps = lists:reverse(InnerRev, [Boundary1 | OuterCps])},
    run_read_only(fun() -> erlog_int:fail(Active) end, Scope1, Active).

state_check_failed(#cp{next = #read_scope{frame = Frame}}, OuterCps, St) ->
    Writable = quod_erlog_db_local_prove:leave_read_only(
                 St#est{cps = OuterCps}, Frame),
    erlog_int:fail(Writable).

run_read_only(Fun, #read_scope{ref = Ref, frame = Frame}, Active) ->
    quod_proof_continuation:run(Ref, Fun, fun read_only_error/4, {Frame, Active}).

-spec read_only_error(atom(), term(), list(), {term(), tuple()}) -> no_return().
read_only_error(throw, {erlog_error, Error, ErrorSt}, _, {Frame, _}) ->
    erlog_int:erlog_error(
      Error, quod_erlog_db_local_prove:leave_read_only(ErrorSt, Frame));
read_only_error(throw, {erlog_error, Error}, _, {Frame, Active}) ->
    erlog_int:erlog_error(
      Error, quod_erlog_db_local_prove:leave_read_only(Active, Frame));
read_only_error(Class, Reason, Stacktrace, _) ->
    erlang:raise(Class, Reason, Stacktrace).

take_boundary(Ref,
              [#cp{type = compiled, label = {?MODULE, Ref},
                   next = #read_scope{ref = Ref} = Scope} = Boundary | Rest],
              InnerRev) ->
    {ok, InnerRev, Boundary, Scope, Rest};
take_boundary(Ref, [#cp{} = Cp | Rest], InnerRev) ->
    take_boundary(Ref, Rest, [Cp | InnerRev]);
take_boundary(Ref, [#cut{} = Cut | Rest], InnerRev) ->
    take_boundary(Ref, Rest, [Cut | InnerRev]);
take_boundary(_Ref, [], _InnerRev) ->
    error.

transition_shape(Transition0, Bs) ->
    case erlog_int:deref(Transition0, Bs) of
        [_ | _] = Transitions ->
            proper_callable_list(Transitions, Bs, nonempty);
        Transition ->
            callable_value(Transition)
    end.

proper_callable_list(List0, Bs, EmptyPolicy) ->
    case erlog_int:deref(List0, Bs) of
        [] -> EmptyPolicy =:= empty_allowed;
        [Head | Tail] ->
            callable(Head, Bs)
            andalso proper_callable_list(Tail, Bs, empty_allowed);
        _ -> false
    end.

callable(Term, Bs) ->
    callable_value(erlog_int:deref(Term, Bs)).

callable_value(Term) when is_atom(Term) -> true;
callable_value(Term)
  when is_tuple(Term), tuple_size(Term) >= 2,
       is_atom(element(1, Term)) -> true;
callable_value(_Term) -> false.

continue_if(true, Next, St) -> erlog_int:prove_body(Next, St);
continue_if(false, _Next, St) -> erlog_int:fail(St).
