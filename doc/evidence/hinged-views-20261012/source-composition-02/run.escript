#!/usr/bin/env escript
%%! +S 4:4
-mode(compile).
main([Root,Out]) ->
 [code:add_patha(P)||P<-filelib:wildcard(Root++"/_build/test/lib/*/ebin")],
 code:add_patha(Root++"/_build/test/lib/quod/test"),
 {ok,quod_lobby_tests,Bin}=compile:file(Root++"/test/quod_lobby_tests.erl",[binary,export_all,{i,Root++"/include"}]),
 {module,quod_lobby_tests}=code:load_binary(quod_lobby_tests,"source-composition-diagnostic",Bin),
 Ctx=quod_lobby_tests:start(Out++"/fixture"),
 try
  Ns= <<"lobby-test-personal">>,Target={ontology_ref,Ns,quod_simplex:genesis_hash(Ns)},
  Draft = <<"hinged_composition_probe(ok).">>,
  Goal={transaction,{',',quod_lobby_tests:editor_scope(<<"quod:prolog">>,
    {prolog_edit_goal,Target,{'/',{'$quod_symbol',<<"hinged_composition_probe">>},1},<<>>,Draft,{'Edit'}}),{call,{'Edit'}}}},
  Result=quod_lobby_tests:submit(Ctx,execute,{findall,ok,Goal,[ok]}),
  ok=file:write_file(Out++"/result.term",term_to_binary(Result)),
  io:format("~0p~n",[case Result of {ok,_,{normalized,{committed,Answers,_}}}->{committed,Answers};Other->Other end]),
  {ok,_,{normalized,{committed,_,_}}}=Result,
  After=quod_lobby_tests:editor_source(Ctx,Target,{'/',{'$quod_symbol',<<"hinged_composition_probe">>},1}),
  io:format("source=~p~n",[After]),
  <<"hinged_composition_probe(ok) :- true.\n">>=After
 after quod_lobby_tests:stop(Ctx) end.
