#!/usr/bin/env escript
%%! +S 4:4
-mode(compile).
-include("/home/yan/src/quod/_build/test/lib/erlog/src/erlog_int.hrl").
main([Root,Out]) ->
 lists:foreach(fun code:add_patha/1,filelib:wildcard(Root++"/_build/test/lib/*/ebin")),
 Files=["agent_instance.pl","quod_physics.pl"],
 Terms=lists:append([quod_prolog:read_terms(Root++"/priv/ontologies/"++F)||F<-Files]),
 Groups=lists:foldl(fun(T,M)->H=case T of {':-',Head,_}->Head;_->T end,
   F=erlog_int:functor(H),maps:update_with(F,fun(X)->X++[T] end,[T],M) end,#{},Terms),
 Base=quod_committed_projection:new_est(),
 Compiler=Base#est{db=lists:foldl(fun erlog_int:assertz_clause/2,Base#est.db,
     quod_prolog:read_terms(Root++"/priv/ontologies/quod_prolog.pl"))},
 Vocabulary=maps:from_keys([atom_to_binary(A,utf8)||A<-maps:keys(quod_wire_term:release_vocabulary())],true),
 Rows=lists:map(fun({{Name,Arity},Cs})->
   Source=iolist_to_binary([begin {N,_,_}=erlog_int:term_instance(C,0),
           {ok,S}=quod_client_goal_parser:format_clause(N),[S,$\n] end||C<-Cs]),
   Query={prolog_edit_goal,{ontology_ref,<<"composition-audit-world">>,<<17:256>>},{'/',Name,Arity},<<>>,Source,{'Edit'}},
   {succeed,Done}=erlog_int:prove_goal(Query,Compiler),
   Edit=erlog_int:dderef({'Edit'},Done#est.bs), {N,_,_}=erlog_int:term_instance(Edit,0),
   {ok,B}=quod_wire_term:encode_canonical(N),
   {ok,TargetText}=quod_client_goal_parser:format_clause(N),
   {ok,#{goal:={'::',_,TargetGoal}}}=quod_client_goal_parser:parse(TargetText,3),
   {ok,Callables}=quod_wire_term:goal_symbol_names(TargetGoal),
   Cold=[C||C<-Callables,not maps:is_key(C,Vocabulary)],
   Material=quod_wire_term:cold_new_symbols(Cs),
   true=length(Callables)=<512, true=length(Material)=<512,
   Format=case quod_client_goal_parser:format_clause(N) of
     {ok,Text}->case quod_client_goal_parser:parse(Text,3) of {ok,_}->#{ok=>true,bytes=>byte_size(Text)};Error->#{error=>iolist_to_binary(io_lib:format("~p",[Error]))} end;
     Error->#{error=>iolist_to_binary(io_lib:format("~p",[Error]))} end,
   Result=case quod_durable_term:encode_result(#{<<"Edit">>=>N}) of {ok,R}->#{ok=>true,bytes=>byte_size(R)};Err->#{error=>iolist_to_binary(io_lib:format("~p",[Err]))} end,
   #{predicate=>iolist_to_binary(io_lib:format("~s/~b",[Name,Arity])),clauses=>length(Cs),source_bytes=>byte_size(Source),callable_symbols=>length(Callables),cold_callable_symbols=>length(Cold),cold_material_symbols=>length(Material),goal_bytes=>byte_size(B),format=>Format,result=>Result}
 end,lists:sort(maps:to_list(Groups))),
 ok=file:write_file(Out,json:encode(#{predicates=>length(Rows),clauses=>length(Terms),rows=>Rows})),
 io:format("predicates=~p clauses=~p failing=~p max_goal=~p~n",[length(Rows),length(Terms),
 [R||R=#{format:=F,result:=Z}<-Rows,not maps:is_key(ok,F) orelse not maps:is_key(ok,Z)],
 lists:max([maps:get(goal_bytes,R)||R<-Rows])]).
