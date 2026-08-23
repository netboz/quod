-module(quod_runtime_predicates).
-moduledoc """
Governed Erlog bridges for `m:quod_runtime`.

`enqueue_projection(Resource, Job)` is a `projection`-class predicate a
state handler calls to push heavy rebuild work into the existing supervised,
per-resource worker tier. The event height becomes the requested revision;
success installs that revision and releases `quod_runtime:await_revision/4`
callers.

The private `$quod_reaction_*` predicates form one Erlog continuation for a
local or subscribed reaction: `erlog_int:unify_prove_body/4` binds the event pattern, ordinary
Prolog resolves the executor's unique node, and the bound Handler runs in the
same read-only frame. They are registered with the existing predicate
dispatcher under class `reaction`; they are not another registry or matcher.

`Job` is a complete Prolog goal (no scope appended), proved under a projection
context against the newest pinned snapshot when its worker starts. Enqueue is
synchronous and bounded: an oversized job or full pending-resource queue fails
the state handler loudly instead of retaining unbounded work.
""".

-include_lib("erlog/src/erlog_int.hrl").
-include("quod_ledger.hrl").

-export([quod_predicate_module/0, load/1, diff_to_events/1, run_reaction/6,
         projection_noop_1/3, enqueue_projection_2/3,
         reaction_dispatch_6/3, reaction_owner_4/3,
         reaction_complete_1/3]).

quod_predicate_module() -> true.

-spec load(tuple()) -> tuple().
load(Est0) ->
    Est1 = quod_predicates:register(
             Est0, {projection_noop, 1}, projection,
             ?MODULE, projection_noop_1),
    Est2 = quod_predicates:register(
      Est1, {enqueue_projection, 2}, projection,
      ?MODULE, enqueue_projection_2),
    Est3 = quod_predicates:register(
             Est2, {'$quod_reaction_dispatch', 6}, reaction,
             ?MODULE, reaction_dispatch_6),
    Est4 = quod_predicates:register(
             Est3, {'$quod_reaction_owner', 4}, reaction,
             ?MODULE, reaction_owner_4),
    quod_predicates:register(
      Est4, {'$quod_reaction_complete', 1}, reaction,
      ?MODULE, reaction_complete_1).

-doc "Convert canonical applied fact operations to ordered reaction events.".
-spec diff_to_events([op()]) -> [term()].
diff_to_events(AppliedOps) when is_list(AppliedOps) ->
    lists:filtermap(
      fun({Kind, {Fact, {[], false}}})
            when Kind =:= assert; Kind =:= retract ->
              {true, {Kind, Fact}};
         (_) ->
              false
      end, AppliedOps).

-doc "Unify one event with one active reaction and continue its Handler once.".
-spec run_reaction(binary(), non_neg_integer(), <<_:256>>, tuple(), term(), tuple()) ->
          executed | unmatched | {inert, term()} | {failed, term()}.
run_reaction(Ns, Height, <<_:256>> = Self,
             {react_on, Executor, Pattern, Handler}, Event, Est) ->
    Ref = make_ref(),
    Key = reaction_marker_key(Ref),
    put(Key, unmatched),
    Goal = {'$quod_reaction_dispatch', Ref, Self,
            Executor, Pattern, Handler, Event},
    Ctx = quod_predicates:reaction_context(Ns, Height),
    {Result, Marker} =
        try
            ProofResult = quod_prolog:prove_est(
                            Goal, quod_predicates:set_context(Est, Ctx)),
            {ProofResult, get(Key)}
        after
            erase(Key)
        end,
    reaction_result(Result, Marker).

reaction_result({ok, _Bindings, [], _ReadSet}, complete) -> executed;
reaction_result({ok, _Bindings, Staged, _ReadSet}, _Marker)
  when Staged =/= [] ->
    {failed, {handler_staged_d, Staged}};
reaction_result(fail, unmatched) -> unmatched;
reaction_result(fail, {inert, Reason}) -> {inert, Reason};
reaction_result(fail, selected) -> {failed, handler_failed};
reaction_result({error, Reason}, selected) -> {failed, {handler_error, Reason}};
reaction_result(Result, Marker) ->
    {failed, {invalid_reaction_result, Result, Marker}}.

%% This is the only event matcher. Pattern variables shared by Executor and
%% Handler are bound before the ownership proof and Handler continuation run.
-spec reaction_dispatch_6(term(), term(), tuple()) -> term().
reaction_dispatch_6(
  {'$quod_reaction_dispatch', Ref, Self, Executor, Pattern, Handler, Event},
  Next, #est{vn = Vn} = St) ->
    Owner = {Vn},
    Owners = {Vn + 1},
    Continue =
        [{findall, Owner, {executor_owner_node, Executor, Owner}, Owners},
         {'$quod_reaction_owner', Ref, Self, Executor, Owners},
         Handler,
         {'$quod_reaction_complete', Ref} | Next],
    erlog_int:unify_prove_body(Pattern, Event, Continue,
                               St#est{vn = Vn + 2}).

-spec reaction_owner_4(term(), term(), tuple()) -> term().
reaction_owner_4(
  {'$quod_reaction_owner', Ref, Self0, Executor0, Owners0}, Next,
  #est{bs = Bs} = St) ->
    Key = reaction_marker_key(Ref),
    case get(Key) of
        unmatched ->
            Self = erlog_int:dderef(Self0, Bs),
            Executor = erlog_int:dderef(Executor0, Bs),
            Owners = erlog_int:dderef(Owners0, Bs),
            case executor_owner(Executor, Self, Owners) of
                selected ->
                    put(Key, selected),
                    erlog_int:prove_body(Next, St);
                {inert, _Reason} = Inert ->
                    put(Key, Inert),
                    erlog_int:fail(St)
            end;
        _ ->
            erlog_int:fail(St)
    end.

executor_owner({node, <<_:256>> = Self}, Self, _Owners) -> selected;
executor_owner({node, <<_:256>>}, _Self, _Owners) -> {inert, remote_node};
executor_owner(_Executor, Self, Owners) when is_list(Owners) ->
    case lists:all(
           fun(Owner) -> is_binary(Owner) andalso byte_size(Owner) =:= 32 end,
           Owners) of
        false ->
            {inert, malformed_executor_owners};
        true ->
            case lists:usort(Owners) of
                [Self] -> selected;
                [] -> {inert, unresolved_executor};
                [_One] -> {inert, remote_executor};
                _ -> {inert, ambiguous_executor}
            end
    end;
executor_owner(_Executor, _Self, _Owners) ->
    {inert, malformed_executor_owners}.

-spec reaction_complete_1(term(), term(), tuple()) -> term().
reaction_complete_1({'$quod_reaction_complete', Ref}, Next, St) ->
    Key = reaction_marker_key(Ref),
    case get(Key) of
        selected ->
            put(Key, complete),
            erlog_int:prove_body(Next, St);
        _ ->
            erlog_int:fail(St)
    end.

reaction_marker_key(Ref) -> {?MODULE, reaction, Ref}.

-spec projection_noop_1(term(), term(), tuple()) -> term().
projection_noop_1(_Goal, Next, St) ->
    erlog_int:prove_body(Next, St).

%% The erlog handler behind the governed `{enqueue_projection, 2}` functor (class
%% `projection` — dispatchable only from a handler's converge run). Ground both args,
%% read ns/height from the execution context, hand the runtime the job.
-spec enqueue_projection_2(term(), term(), tuple()) -> term().
enqueue_projection_2({enqueue_projection, Resource0, Job0}, Next, St) ->
    Resource = erlog_int:dderef(Resource0, St#est.bs),
    Job = erlog_int:dderef(Job0, St#est.bs),
    Ctx = quod_predicates:context(St),
    Ns = quod_predicates:ctx_ns(Ctx),
    Height = quod_predicates:ctx_height(Ctx),
    case quod_predicates:is_ground({Resource, Job}) of
        true ->
            case quod_runtime:enqueue_heavy(Ns, Resource, Height, Job) of
                ok ->
                    erlog_int:prove_body(Next, St);
                {error, Reason} ->
                    throw({erlog_error, {projection_enqueue_failed, Resource, Reason}})
            end;
        false ->
            erlog_int:fail(St)   %% a nonground resource/job is not a schedulable job
    end.
