#!/usr/bin/env escript
%%! +S 4:4
-mode(compile).
main([Root,Out]) ->
 [code:add_patha(P)||P<-filelib:wildcard(Root++"/_build/test/lib/*/ebin")],
 code:add_patha(Root++"/_build/test/lib/quod/test"),
 {ok,quod_lobby_tests,Bin}=compile:file(Root++"/test/quod_lobby_tests.erl",[binary,export_all,{i,Root++"/include"}]),
 {module,quod_lobby_tests}=code:load_binary(quod_lobby_tests,"inactive-source-installation",Bin),
 Ctx=quod_lobby_tests:start(Out++"/fixture"),Ns= <<"lobby-test-inactive-installation">>,
 {_,Config}=maps:get(<<"lobby-test-personal">>,maps:get(ontologies,Ctx)),
 {ActorNs,ActorAnchor}=maps:get(agent,Ctx),Owner={agent_instance_ref,ActorNs,ActorAnchor,{human_user,test_agent}},
 Bodies=[{physics_body_definition,room,N,1,fixed,{vector,N*1000,1000,0},{owned,{box,100,100,100},1}}||N<-lists:seq(1,4)],
 Terms=[{can_invoke,{'_'},Owner,{'_'},{'_'}},{instance_of,physical_space,room},
   {physics_space,room,disabled,physics_authority},{physics_run,room,0,none},{physics_structure,room,1},
   {physics_next_body,room,5},{physics_allowances,room,{limits,16,16,128,1000000,{geometry,32,256,256}},16667,-9810,10000}],
 {Sup,_}=quod_lobby_tests:start_namespace(Ns,Config#{data_dir=>Out++"/fixture/inactive-world",
   genesis_diff=>quod_prolog:genesis_diff(Out++"/old-physics.pl") ++
      quod_prolog:genesis_diff(Root++"/priv/ontologies/agent_instance.pl") ++
      quod_prolog:genesis_diff(Root++"/priv/ontologies/space.pl") ++quod_prolog:terms_to_diff(Terms++Bodies)}),
 try
  Anchor=quod_simplex:genesis_hash(Ns),Target={ontology_ref,Ns,Anchor},
  {ok,Bytes}=file:read_file(Root++"/_build/quod36/source-preparation/replacement-drafts-02.json"),Rows=json:decode(Bytes),
  [begin
    {ok,#{goal:=Wire}}=quod_client_goal_parser:parse(<<(maps:get(<<"indicator">>,R))/binary,".">>,3),
    {ok,I}=quod_wire_term:materialize_symbols(Wire),Before=quod_lobby_tests:editor_source(Ctx,Target,I),
    true=Before=:=maps:get(<<"expected">>,R),
    {'::',Ns,{',',{current_ontology_identity,Ns,Anchor},{transaction,Body}}}=
      quod_lobby_tests:compile_source_edit(Ctx,Target,I,Before,maps:get(<<"draft">>,R)),
    Edit={'::',Ns,{',',{current_ontology_identity,Ns,Anchor},{transaction,{',',{physics_space,room,disabled,physics_authority},Body}}}},
    quod_lobby_tests:commit_editor_goal(Ctx,Edit),
    After=quod_lobby_tests:editor_source(Ctx,Target,I),true=After=:=maps:get(<<"draft">>,R),
    ok=quod_runtime:reconcile_resource(Ns,quod_prolog:applied(Ns),physics_worlds,all,quod_time:mono_ms()+10000),
    {Runtime,_}=quod_runtime:agents(Ns),true=map_size(gen_server:call(Runtime,physics_worlds))=:=0,
    Anchor=quod_simplex:genesis_hash(Ns),
    {ok,[#{'Bs' := Bodies}],_}=quod_prolog:prove_ro(Ns,{findall,{physics_body_definition,room,{'B'},{'R'},{'K'},{'P'},{'D'}},{physics_body_definition,room,{'B'},{'R'},{'K'},{'P'},{'D'}},{'Bs'}}),
    io:format("installed ~p/~p ~s height=~p inactive=true~n",[N,length(Rows),maps:get(<<"indicator">>,R),quod_prolog:applied(Ns)])
  end || {R,N}<-lists:zip(Rows,lists:seq(1,length(Rows)))],
  io:format("complete~n")
 after quod_lobby_tests:stop_process(Sup),quod_lobby_tests:stop(Ctx) end.
