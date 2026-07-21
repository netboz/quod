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
context against the enqueueing snapshot; Erlang job kinds arrive with the first real worker.
The cast is fire-and-forget by design: a handler must stay pure Prolog + bounded, and the
runtime coalesces/bounds the queues.
""".

-include_lib("erlog/src/erlog_int.hrl").

-export([enqueue_projection_2/3]).

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
    case erlog:vars_in({Resource, Job}) of
        [] ->
            ok = quod_runtime:enqueue_heavy(Ns, Resource, Height, Job),
            erlog_int:prove_body(Next, St);
        _  ->
            erlog_int:fail(St)   %% a nonground resource/job is not a schedulable job
    end.
