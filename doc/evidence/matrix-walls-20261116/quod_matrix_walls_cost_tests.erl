-module(quod_matrix_walls_cost_tests).
-include_lib("eunit/include/eunit.hrl").
%% Matrix walls cost, through the signed human path, from inside a finite
%% room. Copied into test/ of the tree being measured, run alone, then removed.
%%
%% 1. The whole-source read of quod:space with the Source panel's goal
%%    (quod:gui prolog_source/2 as a cursor): bytes, chunks, median time of a
%%    complete read, and which shared rule files it carries.
%% 2. Pie and world view medians (41 reads after 5 warm-ups), the instance
%%    choosing Matrix walls.
cost_test_() ->
    {timeout,900,fun() -> quod_gui_menu_tests:with_menus(fun(C=#{namespace:=Ns}) ->
        A = quod_simplex:genesis_hash(Ns), Room = {entity_ref,Ns,A,room}, T = {transform,0,0,0,0,0,0},
        quod_gui_menu_tests:edit(Ns,quod_gui_menu_tests:conj([{assertz,{account_setup,me,{complete,cost_fixture}}},
            {assertz,{space_assignment_state,personal,1,Room}},
            {assertz,{space_placement,room,{entity_ref,Ns,A,personal},1}},
            {assertz,{attribute,room,dimensions,{box,{q,4,<<"m">>},{q,3,<<"m">>},{q,5,<<"m">>}}}},
            {assertz,{attribute,room,exterior,solid}},{assertz,{attribute,room,transform,T}},
            {assertz,{attribute,room,interior,matrix}}])),
        Space = {ontology_ref,<<"quod:space">>,SpaceAnchor = quod_simplex:genesis_hash(<<"quod:space">>)},
        %% As live, quod:space's source is readable by anyone. This fixture's
        %% root holds facts only; the fact stands for quod_root.pl's rule.
        quod_gui_menu_tests:edit(quod_ontology:root_ns(),{assertz,{system_source_access,Space,read_only}}),
        Goal = {'::',<<"quod:gui">>,{prolog_source,Space,{'Source'}}},
        {ok,Cursors} = quod_client_cursor:start_link(), unlink(Cursors),
        {Text,Chunks} = source(C,Goal),
        Markers = [{"common_predicates.pl",<<"system_prolog_introspection(">>},
                   {"construction.pl",<<"with_build_plan(">>},
                   {"material_policy.pl",<<"material_default_limit(">>},
                   {"gui_forms.pl",<<"gui_definition/6">>},
                   {"geometry_schema.pl",<<"physics_valid_body/6">>},
                   {"quod_space.pl",<<"space_whole_mm(">>}],
        Carried = [{F,binary:match(Text,M) =/= nomatch} || {F,M} <- Markers],
        NonWhite = length([X || <<X>> <= Text, not lists:member(X,[$\s,$\t,$\n,$\r])]),
        Read = fun(G) -> {Us,_} = timer:tc(fun() -> G() end), Us end,
        Median = fun(G,N) -> _ = [Read(G) || _ <- lists:seq(1,5)],
                             L = lists:sort([Read(G) || _ <- lists:seq(1,N)]), lists:nth(N div 2 + 1,L) end,
        SourceUs = Median(fun() -> {Text,_} = source(C,Goal) end,21),
        io:format(user,"~nSOURCE bytes=~p non_white_bytes=~p chunks=~p complete_read_median_us=~p carried=~p~n",
                  [byte_size(Text),NonWhite,Chunks,SourceUs,Carried]),
        Pie = Median(fun() -> read(C,{client_menu,room,{'V'}}) end,41),
        World = Median(fun() -> read(C,{'::',<<"quod:space">>,{world_view,Room,playing,{'M'}}}) end,41),
        io:format(user,"~nCOST matrix_walls pie_us=~p world_view_us=~p~n",[Pie,World]),
        {ok,Out} = file:open(filename:join(os:getenv("MATRIX_EVIDENCE","/dev/null"),"space-source.pl"),[write,binary]),
        ok = file:write(Out,Text), ok = file:close(Out),
        exit(Cursors,shutdown)
    end) end}.

read(C,Goal) ->
    {Bytes,Signature} = quod_personal_agent_tests:request(C,read,Goal),
    {ok,_,{normalized,{read,_,{answers,_,[_]}}}} = quod_client_goal_ingress:submit(Bytes,Signature), ok.

%% The client's cursor read: open, next until done, stop.
source(C,Goal) ->
    {Bytes,Signature} = quod_personal_agent_tests:request(C,cursor,Goal),
    {ok,Evidence = #{request := #{signing_public_key := Key}}} = quod_client_goal_target:verify_request(Bytes,Signature),
    {ok,Peer} = application:get_env(quod,node_pubkey),
    Owner = {session,crypto:strong_rand_bytes(32),Key}, Id = crypto:strong_rand_bytes(32),
    {ok,{Evidence,Materialized,Principal,Owner}} = quod_client_goal_target:prepare_local(Evidence,Peer,Owner,Id),
    Blob = case quod_client_goal_target:execute(Evidence,Materialized,Principal,Owner,Id) of
        {ok,Evidence,{normalized,{solution,Id,_,B}}} -> B;
        {ok,_,{normalized,{failed,F}}} -> {ok,Reasons} = quod_wire_term:decode_failure_reasons(F),
            error({source_read_failed,lists:flatten(io_lib:format("~P",[Reasons,30]))});
        Other -> error({source_read,Other})
    end,
    {ok,[{_,First}]} = quod_client_result:decode_binding(Blob),
    finish(Owner,Id,Evidence,First,[],1).

finish(Owner,Id,Evidence,{source_chunk,done,Text},Acc,N) ->
    {ok,Evidence,_} = quod_client_cursor:command(Owner,Id,stop),
    {iolist_to_binary(lists:reverse([Text|Acc])),N};
finish(Owner,Id,Evidence,{source_chunk,more,Text},Acc,N) ->
    {ok,Evidence,Raw} = quod_client_cursor:command(Owner,Id,next),
    {solution,Id,_,Blob} = quod_client_result:normalize(Evidence,Raw),
    {ok,[{_,Chunk}]} = quod_client_result:decode_binding(Blob),
    finish(Owner,Id,Evidence,Chunk,[Text|Acc],N+1).
