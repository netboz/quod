#!/usr/bin/env escript
%%! +S 4:4
-mode(compile).
main([Root,Source,Out]) ->
 [code:add_patha(P)||P<-filelib:wildcard(Root++"/_build/test/lib/*/ebin")],
 {ok,quod_lobby_tests,Bin}=compile:file(Root++"/test/quod_lobby_tests.erl",[binary,export_all,{i,Root++"/include"}]),
 {module,quod_lobby_tests}=code:load_binary(quod_lobby_tests,"local-source-preparation",Bin),
 {ok,B}=file:read_file(Source),Ds=quod_lobby_tests:source_predicate_drafts(B),
 Rows=[begin {ok,I}=quod_client_goal_parser:format_clause(Indicator),
 #{indicator=>string:trim(I,trailing,".\n"),draft=>D} end||{Indicator,D}<-Ds],
 ok=file:write_file(Out,json:encode(Rows)),io:format("predicates=~p~n",[length(Rows)]).
