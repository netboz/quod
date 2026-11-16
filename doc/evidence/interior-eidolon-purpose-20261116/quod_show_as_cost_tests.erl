-module(quod_show_as_cost_tests).
-include_lib("eunit/include/eunit.hrl").
%% Cost of opening the space pie and reading the world view, from inside a
%% finite room, through the signed human path. Copied into test/ of the tree
%% being measured, run alone, then removed. Prints medians in microseconds.
cost_test_() ->
    {timeout,600,fun() -> quod_gui_menu_tests:with_menus(fun(C=#{namespace:=Ns}) ->
        A = quod_simplex:genesis_hash(Ns), Room = {entity_ref,Ns,A,room}, T = {transform,0,0,0,0,0,0},
        quod_gui_menu_tests:edit(Ns,quod_gui_menu_tests:conj([{assertz,{account_setup,me,{complete,cost_fixture}}},
            {assertz,{space_assignment_state,personal,1,Room}},
            {assertz,{space_placement,room,{entity_ref,Ns,A,personal},1}},
            {assertz,{attribute,room,dimensions,{box,{q,4,<<"m">>},{q,3,<<"m">>},{q,5,<<"m">>}}}},
            {assertz,{attribute,room,exterior,solid}},{assertz,{attribute,room,transform,T}}])),
        Read = fun(G) -> {Us,_} = timer:tc(fun() -> read(C,G) end), Us end,
        Median = fun(G) -> _ = [Read(G) || _ <- lists:seq(1,5)],
                           L = lists:sort([Read(G) || _ <- lists:seq(1,41)]), lists:nth(21,L) end,
        Pie = Median({client_menu,room,{'V'}}),
        World = Median({'::',<<"quod:space">>,{world_view,Room,playing,{'M'}}}),
        io:format(user,"~nCOST no_walls pie_us=~p world_view_us=~p~n",[Pie,World]),
        %% The instance chooses wire walls, the same fact in both trees.
        quod_gui_menu_tests:edit(Ns,{assertz,{attribute,room,interior,wireframe}}),
        io:format(user,"~nCOST instance_walls pie_us=~p world_view_us=~p~n",
                  [Median({client_menu,room,{'V'}}),Median({'::',<<"quod:space">>,{world_view,Room,playing,{'M'}}})])
    end) end}.

read(C,Goal) ->
    {Bytes,Signature} = quod_personal_agent_tests:request(C,read,Goal),
    {ok,_,{normalized,{read,_,{answers,_,[_]}}}} = quod_client_goal_ingress:submit(Bytes,Signature), ok.
