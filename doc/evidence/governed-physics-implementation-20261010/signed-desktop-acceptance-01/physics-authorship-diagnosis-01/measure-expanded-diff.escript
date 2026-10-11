#!/usr/bin/env escript
%%! +S 4:4
main([Root]) ->
 lists:foreach(fun code:add_patha/1, filelib:wildcard(Root ++ "/_build/test/lib/*/ebin")),
 {ok,A}=erlog_io:read_file(Root ++ "/priv/ontologies/agent_instance.pl"),
 {ok,P}=erlog_io:read_file(Root ++ "/priv/ontologies/quod_physics.pl"),
 {As,_}=lists:mapfoldl(fun(T,V) -> {F,_,N}=erlog_int:term_instance(T,V), {{assertz,F},N} end,0,A++P),
 Goal={transaction,balanced(As)},
 {ok,B}=quod_wire_term:encode_canonical(Goal),
 D=quod_prolog:terms_to_diff(A++P),
 {ok,DB}=quod_wire_term:encode_canonical(D),
 io:format("diff_ops=~p canonical_diff_bytes=~p~n",[length(D),byte_size(DB)]),
 F=quod_client_goal_parser:format_clause(Goal),
 io:format("clauses=~p canonical_goal_bytes=~p formatted_goal=~p~n",[length(As),byte_size(B),case F of {ok,T}-> {bytes,byte_size(T),parse,quod_client_goal_parser:parse(T,3)}; Other->Other end]).
balanced([G])->G;
balanced(Gs)->{L,R}=lists:split(length(Gs) div 2,Gs),{',',balanced(L),balanced(R)}.
