-module(quod_runtime_predicates).
-moduledoc """
Reality-bridge predicates for `m:quod_runtime`'s heavy-worker framework (agent-fipa-plan §8).

One bridge for now: `enqueue_projection(Resource, Job)` — a `projection`-class predicate a
handler's ConvergeGoal calls to push work that is TOO HEAVY for the ordered tier (large
scans, mesh building, asset work) into a supervised, queue-fed, per-resource worker outside
the namespace pipeline. The event height at the calling context becomes the job's requested
**revision**; the worker's success installs it, releasing `quod_runtime:await_revision/4`
callers — the per-resource barrier heavy-dependent effects will use instead of the
namespace-wide P-before-E frontier.

`Job` in this slice is a complete Prolog goal (no scope appended), proved under a projection
context against the newest pinned snapshot when its worker starts; Erlang job kinds arrive
with the first real worker. Enqueue is synchronous and bounded: an oversized job or full
pending-resource queue fails the handler loudly instead of retaining unbounded work.
""".

-include_lib("erlog/src/erlog_int.hrl").

-export([enqueue_projection_2/3]).

-ifdef(TEST).
-export([is_ground/1]).
-endif.

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
    case is_ground({Resource, Job}) of
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

%% True iff the (dderef'd) term has no unbound erlog variable. `erlog:vars_in/1` deliberately
%% SKIPS the anonymous `{'_'}` ("Never in!"), so a bare `_` in a resource/job would slip its
%% gate; every erlog var is a 1-arity tuple (`{Name}` or `{'_'}`), and a real compound is
%% `{Functor, Arg...}` (arity >= 2), so "no 1-tuple anywhere" is the exact groundness test.
is_ground(T) when is_tuple(T), tuple_size(T) =:= 1 -> false;
is_ground(T) when is_tuple(T) -> lists:all(fun is_ground/1, tuple_to_list(T));
is_ground([H | Tl]) -> is_ground(H) andalso is_ground(Tl);
is_ground(_) -> true.
