#!/usr/bin/env escript
%%! +S 4:4
-mode(compile).
main([Root,Out]) ->
 [code:add_patha(P)||P<-filelib:wildcard(Root++"/_build/test/lib/*/ebin")],
 code:add_patha(Root++"/_build/test/lib/quod/test"),
 {ok,quod_lobby_tests,Bin}=compile:file(Root++"/test/quod_lobby_tests.erl",[binary,export_all,{i,Root++"/include"}]),
 {module,quod_lobby_tests}=code:load_binary(quod_lobby_tests,"source-composition-diagnostic",Bin),
 Ctx=quod_lobby_tests:start(Out++"/fixture"),
 Ns = <<"lobby-test-source-replacement">>,
 {_,Config}=maps:get(<<"lobby-test-personal">>,maps:get(ontologies,Ctx)),
 {ActorNs,ActorAnchor}=maps:get(agent,Ctx),Owner={agent_instance_ref,ActorNs,ActorAnchor,{human_user,test_agent}},
 {Sup,_}=quod_lobby_tests:start_namespace(Ns,Config#{
   data_dir=>Out++"/fixture/source-replacement",
   genesis_diff=>quod_prolog:genesis_diff(Out++"/old-physics.pl") ++
      quod_prolog:terms_to_diff([{can_invoke,{'_'},Owner,{'_'},{'_'}}])}),
 try
  Target={ontology_ref,Ns,quod_simplex:genesis_hash(Ns)},
  {ok,Bytes}=file:read_file(Root++"/_build/quod36/source-preparation/replacement-drafts.json"),Rows=json:decode(Bytes),
  Goals=[begin
    {ok,#{goal:=Wire}}=quod_client_goal_parser:parse(<<(maps:get(<<"indicator">>,R))/binary,".">>,3),
    {ok,I}=quod_wire_term:materialize_symbols(Wire),Var={list_to_atom("Edit_"++integer_to_list(N))},
    {',',{'::',<<"quod:prolog">>,{prolog_edit_goal,Target,I,maps:get(<<"expected">>,R),maps:get(<<"draft">>,R),Var}},{call,Var}}
  end || {R,N}<-lists:zip(Rows,lists:seq(1,length(Rows)))],
  Goal={transaction,{',',{'::',<<"quod:prolog">>,{current_ontology_identity,<<"quod:prolog">>,quod_simplex:genesis_hash(<<"quod:prolog">>)}},{findall,ok,balanced(Goals),[ok]}}},
  {Numbered,_,_}=erlog_int:term_instance(Goal,0),
  {ok,Text}=quod_client_goal_parser:format_clause(Numbered),
  {ok,EncodedGoal}=quod_wire_term:encode_canonical(Numbered),
  ok=file:write_file(Out++"/submitted.prolog",Text),
  {AgentNs,AgentAnchor}=maps:get(agent,Ctx),{Public,_}=KeyPair=maps:get(key_pair,Ctx),
  Request=#{network_identity=>maps:get(network,Ctx),signing_public_key=>Public,operation_id=>crypto:strong_rand_bytes(32),
    agent_namespace=>AgentNs,agent_genesis_anchor=>AgentAnchor,agent_instance_text=><<"human_user(test_agent).">>,
    mode=>execute,parser_version=>3,not_after_ms=>quod_time:now_ms()+30000,goal_text=>Text},
  {ok,RequestBytes}=quod_client_goal:encode(Request),Signature=quod_identity:sign(RequestBytes,quod_identity:key_term(KeyPair)),
  ok=file:write_file(Out++"/original-operation.term",term_to_binary({RequestBytes,Signature})),
  Before=quod_prolog:applied(Ns),Result=quod_client_goal_ingress:submit(RequestBytes,Signature),
  ok=file:write_file(Out++"/result.term",term_to_binary(Result)),
  Brief=case Result of {ok,_,{normalized,{committed,Answers,_}}}->{committed,length(Answers)};
    {ok,_,{normalized,{failed,Reasons}}}->quod_wire_term:decode_failure_reasons(Reasons);Other->Other end,
  io:format("text_bytes=~p canonical_bytes=~p before=~p after=~p result=~0p~n",[byte_size(Text),byte_size(EncodedGoal),Before,quod_prolog:applied(Ns),Brief]),
  {ok,_,{normalized,{committed,_,_}}}=Result,
  true=quod_prolog:applied(Ns)=:=Before+1,
  [begin
    {ok,#{goal:=WireI}}=quod_client_goal_parser:parse(<<(maps:get(<<"indicator">>,R))/binary,".">>,3),
    {ok,I}=quod_wire_term:materialize_symbols(WireI),After=quod_lobby_tests:editor_source(Ctx,Target,I),
    true=After=:=maps:get(<<"draft">>,R)
  end || R<-Rows],
  io:format("all_58_predicates_verified~n")
 after quod_lobby_tests:stop_process(Sup),quod_lobby_tests:stop(Ctx) end.
balanced([])->true;
balanced([G])->G;
balanced(Gs)->{A,B}=lists:split(length(Gs) div 2,Gs),{',',balanced(A),balanced(B)}.
