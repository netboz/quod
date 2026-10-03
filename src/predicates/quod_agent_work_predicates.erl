-module(quod_agent_work_predicates).
-moduledoc """
Governed request for the existing hosted-agent continuation owner.
The runtime selects the next goal from current committed Prolog rules using
its retained cursor. Callers supply neither a goal nor desired-state rows.
""".

-include_lib("erlog/src/erlog_int.hrl").
-export([quod_predicate_module/0, load/1, continue_agent_work/3]).

quod_predicate_module() -> true.

load(Est) ->
    quod_predicates:register(Est, {continue_agent_work, 2}, query,
                             ?MODULE, continue_agent_work).

continue_agent_work({continue_agent_work, Instance0, Wake0}, Next, #est{bs = Bs} = St) ->
    [Instance, Wake] = erlog_int:dderef([Instance0, Wake0], Bs),
    case quod_wire_term:is_ground(Instance) andalso
         (Wake =:= changed orelse Wake =:= continue) of
        true -> quod_runtime_predicates:request_resource(agent_work, {Instance, Wake}, Next, St);
        false -> erlog_int:fail(St)
    end.
