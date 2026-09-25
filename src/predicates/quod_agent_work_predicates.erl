-module(quod_agent_work_predicates).
-moduledoc """
Opt-in projection bridges for guarded agent continuations.

New ontologies pin this extension alongside `quod_agent_predicates`. Keeping
these bridges separate preserves the immutable module digest of existing agent
histories. The existing runtime owns scheduling; Prolog selects domain work.
""".

-include_lib("erlog/src/erlog_int.hrl").
-export([quod_predicate_module/0, load/1, agent_work_cursor/3, project_agent_goal/3]).

quod_predicate_module() -> true.

-spec load(tuple()) -> tuple().
load(Est) ->
    WithCursor = quod_predicates:register(Est, {agent_work_cursor, 3}, projection,
                                         ?MODULE, agent_work_cursor),
    quod_predicates:register(WithCursor, {project_agent_goal, 2}, projection,
                             ?MODULE, project_agent_goal).

-doc "Read the current finite pass cursor under its one founding projection owner.".
agent_work_cursor({agent_work_cursor, Instance0, Wake0, Cursor}, Next, #est{bs = Bs} = St) ->
    [Instance, Wake] = erlog_int:dderef([Instance0, Wake0], Bs),
    case quod_wire_term:is_ground(Instance) andalso
         (Wake =:= changed orelse Wake =:= continue) of
        true ->
            case project_work(Instance, {cursor, Wake}, St) of
                {ok, Value} -> erlog_int:unify_prove_body(Cursor, Value, Next, St);
                skip -> erlog_int:fail(St)
            end;
        false -> erlog_int:fail(St)
    end.

-doc "Queue one Prolog-selected guarded domain step, or finish the current pass.".
project_agent_goal({project_agent_goal, Instance0, Step0}, Next, #est{bs = Bs} = St) ->
    [Instance, Step] = erlog_int:dderef([Instance0, Step0], Bs),
    Valid = case Step of
        none -> true;
        {work, Key, Goal, Budget} when is_binary(Key), is_integer(Budget),
                                      Budget > 0, Budget =< 60000 ->
            quod_wire_term:is_ground(Goal) andalso
                element(1, quod_client_goal_parser:format(Goal)) =:= ok;
        _ -> false
    end,
    case quod_wire_term:is_ground(Instance) andalso Valid of
        true ->
            _ = project_work(Instance, Step, St),
            erlog_int:prove_body(Next, St);
        false -> erlog_int:fail(St)
    end.

project_work(Instance, Step, St) ->
    Ctx = quod_predicates:context(St),
    case quod_runtime:project_agent_work(quod_predicates:ctx_ns(Ctx),
           quod_predicates:ctx_handler(Ctx), quod_predicates:ctx_height(Ctx), Instance, Step) of
        {error, Reason} -> throw({erlog_error, {agent_work_projection_failed, Reason}});
        Result -> Result
    end.
