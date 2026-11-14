-module(zz_pie_goals_tests).
-include_lib("eunit/include/eunit.hrl").

%% Scratch measurement for the VR fixes plan, Phase 5 (delete before commit):
%% which goals a space pie's proof calls in other ontologies, and how many,
%% with 0 and 1 child space under "Go to". Counts come from Erlang call
%% tracing of quod_ask:open/5; the menu read is the ordinary signed read.

pie_goals_test_() ->
    {timeout,600,fun() -> quod_gui_menu_tests:with_menus(fun(C=#{namespace:=Ns}) ->
        Anchor = quod_simplex:genesis_hash(Ns),
        Room = {entity_ref,Ns,Anchor,room},
        Edit = fun(G) -> quod_gui_menu_tests:edit(Ns,G) end,
        Edit(quod_gui_menu_tests:conj([{assertz,{account_setup,me,{complete,menu_fixture}}},
            {assertz,{space_assignment_state,personal,1,Room}},
            {assertz,{space_placement,room,{entity_ref,Ns,Anchor,personal},1}},
            {assertz,{attribute,room,name,<<"Workshop">>}},
            {assertz,{attribute,room,dimensions,{box,{q,4,<<"m">>},{q,3,<<"m">>},{q,5,<<"m">>}}}},
            {assertz,{attribute,room,exterior,solid}},{assertz,{attribute,room,transform,{transform,0,0,0,0,0,0}}}])),
        Child = fun() -> Edit(quod_gui_menu_tests:conj([{assertz,{attribute,closed,name,<<"Closet">>}},
            {assertz,{space_member,room,{entity_ref,Ns,Anchor,closed}}}])) end,
        Measure = fun(Label) ->
            _ = quod_gui_menu_tests:property(element(2,menu(C)),label),
            Self = self(),
            Tracer = spawn_link(fun() -> collect(Self,#{}) end),
            erlang:trace_pattern({quod_ask,open,5},true,[local]),
            erlang:trace(all,true,[call,{tracer,Tracer}]),
            {Us,{menu,_}} = timer:tc(fun() -> menu(C) end),
            erlang:trace(all,false,[call]),
            erlang:trace_pattern({quod_ask,open,5},false,[local]),
            Tracer ! {done,Self},
            Counts = receive {counts,Map} -> Map after 10000 -> error(no_counts) end,
            Rows = lists:reverse(lists:keysort(2,maps:to_list(Counts))),
            {Label,Us div 1000,lists:sum(maps:values(Counts)),Rows}
        end,
        R0 = Measure(no_child),
        Child(), R1 = Measure(one_child),
        File = "doc/evidence/vr-retest-20261114/p5-pie-goals-local.txt",
        ok = file:write_file(File,[
            "# Local measurement (scratch test, 2026-11-14): cross-ontology calls made by one space pie's\n",
            "# proof, counted by the called ontology and goal (quod_ask:open/5 call trace). Second read of each\n",
            "# (the first warms caches); wall time includes the trace's own cost.\n",
            [io_lib:format("~n== ~p: ~p ms, ~p calls~n~s",[L,Ms,Total,
                [io_lib:format("~6b  ~s  ~s~n",[N,T,G]) || {{T,G},N} <- Rows]]) || {L,Ms,Total,Rows} <- [R0,R1]]]),
        io:format(user,"PIE_GOALS written to ~s~n",[File])
    end) end}.

menu(C) -> quod_gui_menu_tests_read(C,{client_menu,room,{'View'}}).
quod_gui_menu_tests_read(C,Goal) ->
    {Bytes,Signature} = quod_personal_agent_tests:request(C,read,Goal),
    {ok,_,{normalized,{read,_,{answers,_,[Binding]}}}} = quod_client_goal_ingress:submit(Bytes,Signature),
    {ok,[{_,Value}]} = quod_client_result:decode_binding(Binding), Value.

collect(Parent,Counts) ->
    receive
        {trace,_,call,{quod_ask,open,[_,Target,Goal,_,_]}} ->
            Key = {Target,iolist_to_binary(names(Goal))},
            collect(Parent,maps:update_with(Key,fun(N) -> N + 1 end,1,Counts));
        {done,Parent} -> Parent ! {counts,Counts};
        _ -> collect(Parent,Counts)
    end.

names({',',L,R}) -> [indicator(L),",",names(R)];
names(G) -> indicator(G).
indicator(G) when is_atom(G) -> [atom_to_list(G),"/0"];
indicator(G) when is_tuple(G), tuple_size(G) > 1, is_atom(element(1,G)) ->
    [atom_to_list(element(1,G)),"/",integer_to_list(tuple_size(G)-1)];
indicator(_) -> "_".
