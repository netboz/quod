#!/usr/bin/env escript
%%! +S 4:4
-mode(compile).
-include_lib("erlog/src/erlog_int.hrl").
main([Root,Out]) ->
 [code:add_patha(P)||P<-filelib:wildcard(Root++"/_build/test/lib/*/ebin")],
 code:add_patha(Root++"/_build/test/lib/quod/test"),
 {ok,Bytes}=file:read_file(Out++"/replacement-drafts.json"),Rows=json:decode(Bytes),
 Base=quod_committed_projection:new_est(),
 Compiler=quod_prolog:read_terms(Root++"/priv/ontologies/quod_prolog.pl"),
 E=quod_ct:assert_facts([{':-',{current_principal,{'_'}},fail}|Compiler],Base),
 Ns = <<"human:5pU3X8evhfH09g1ctl0LRRP80zmhd6M7g8OQ7DyOeaE/lobby">>,
 Anchor=binary:decode_hex(<<"7082C150269E5B82754C06CB7928F6E55FFBCEDABD25E642C2CCF874A3A6F77F">>),
 Edits=[begin
   {ok,#{goal:=Wire}}=quod_client_goal_parser:parse(<<(maps:get(<<"indicator">>,R))/binary,".">>,3),
   {ok,I}=quod_wire_term:materialize_symbols(Wire),
   {succeed,Final}=erlog_int:prove_goal({prolog_edit_goal,{ontology_ref,Ns,Anchor},I,
       maps:get(<<"expected">>,R),maps:get(<<"draft">>,R),{'Edit'}},E),
   {'::',Ns,{',',{current_ontology_identity,Ns,Anchor},{transaction,Body}}}=
       erlog_int:dderef({'Edit'},Final#est.bs), Body
 end || R <- Rows],
 Goal={'::',Ns,{',',{current_ontology_identity,Ns,Anchor},{transaction,balanced(Edits)}}},
 {Canonical,_,_}=erlog_int:term_instance(Goal,0),
 Text = <<(quod_client_goal_parser:value_text(Canonical))/binary,".">>,
 ok=file:write_file(Out++"/library-replacement.prolog",Text),
 {ok,WireGoal}=quod_wire_term:encode_canonical(Canonical),
 Fmt=quod_client_goal_parser:format_clause(Canonical),Parse=quod_client_goal_parser:parse(Text,3),
 Report=#{predicates=>length(Rows),text_bytes=>byte_size(Text),canonical_bytes=>byte_size(WireGoal),
   parser_result=>iolist_to_binary(io_lib:format("~0p",[Parse])),
   formatter_result=>iolist_to_binary(io_lib:format("~0p",[Fmt])),
   max_depth=>depth(Canonical),nodes=>nodes(Canonical),
   text_sha256=>binary:encode_hex(crypto:hash(sha256,Text))},
 ok=file:write_file(Out++"/replacement-diagnostic.json",json:encode(Report)),
 io:format("~s~n",[json:encode(Report)]).
depth(T) when is_tuple(T)->1+lists:max([depth(X)||X<-tuple_to_list(T)]);
depth([H|T])->1+max(depth(H),depth(T));
depth(_)->0.
nodes(T) when is_tuple(T)->1+lists:sum([nodes(X)||X<-tuple_to_list(T)]);
nodes([H|T])->1+nodes(H)+nodes(T);
nodes(_)->1.

balanced([])->true;
balanced([G])->G;
balanced(Gs)->{A,B}=lists:split(length(Gs) div 2,Gs),{',',balanced(A),balanced(B)}.
