-module(quod_retained_message_probe_tests).
-include_lib("eunit/include/eunit.hrl").
sequence_test_() -> [{module,M} || M <- [quod_catchup_verify_tests,quod_foreign_queue_observation_tests,quod_foreign_residency_tests,quod_history_view_tests,quod_node_context_tests,quod_operation_recovery_tests,quod_outcome_endpoint_tests,quod_outcome_result_tests,quod_physics_control_tests]] ++ [fun snapshot/0].
snapshot() ->
    {messages,Messages}=process_info(self(),messages),
    Rows=lists:foldl(fun(M,A)-> K=tag(M),{N,W,B}=maps:get(K,A,{0,0,0}),
       A#{K=>{N+1,W+erts_debug:flat_size(M),B+binary_bytes(M)}} end,#{},Messages),
    ok=file:write_file("/home/yan/src/quod/doc/evidence/quo-58-webxr-20261026/view-correction-01/timeout-triage-13/retained-by-owner.term",io_lib:format("~p.~n",[Rows])).
tag({committed,Ns,_,_}) -> {committed,Ns};
tag({trace,_,call,{M,F,_}}) -> {trace,M,F};
tag({trace,_,return_from,{M,F,_},_}) -> {return_trace,M,F};
tag(M) when is_tuple(M),tuple_size(M)>0,is_atom(element(1,M)) -> element(1,M);
tag(_) -> other.
binary_bytes(B) when is_binary(B) -> binary:referenced_byte_size(B);
binary_bytes(T) when is_tuple(T) -> binary_bytes(tuple_to_list(T));
binary_bytes(M) when is_map(M) -> binary_bytes(maps:to_list(M));
binary_bytes([H|T]) -> binary_bytes(H)+binary_bytes(T);
binary_bytes(_) -> 0.
