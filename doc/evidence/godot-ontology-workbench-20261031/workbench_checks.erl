-module(workbench_checks).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").

new_symbol_draft_does_not_allocate_atoms_test() ->
    Name = <<"workbench_pure_", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Symbol = {'$quod_symbol', Name},
    with_owner(fun(St) ->
        Text = draft(<<>>, {add, {isa, Symbol, thing}}, St),
        ?assert(is_binary(Text)), ?assertNotEqual(nomatch, binary:match(Text, Name)),
        ?assertError(badarg, binary_to_existing_atom(Name, utf8)),
        ?assertEqual([], changes(St))
    end).
remove_authored_fact_test() ->
    with_owner(fun(St) -> ?assertEqual(<<>>, draft(<<"isa(before,thing).\n">>, {remove,{isa,before,thing}}, St)) end).
replace_authored_text_attribute_test() ->
    with_owner(fun(St) ->
        Text = draft(<<"attribute(me,note,<<\"old\">>).\n">>,
            {replace,{attribute,me,note,<<"old">>},{attribute,me,note,<<"new">>}}, St),
        ?assertNotEqual(nomatch,binary:match(Text,<<"new">>)), ?assertEqual(nomatch,binary:match(Text,<<"old">>))
    end).
membership_creation_is_not_a_draft_shortcut_test() ->
    with_owner(fun(St) -> ?assertMatch({fail,_},erlog_int:prove_goal({prolog_workbench_draft,<<>>,{add,{instance_of,thing,chosen_id}},{'Draft'}},St)) end).
rule_creation_is_not_a_fact_edit_test() ->
    with_owner(fun(St) -> ?assertMatch({fail,_},erlog_int:prove_goal({prolog_workbench_draft,<<>>,{add,{':-',{isa,a,b},true}},{'Draft'}},St)) end).
duplicate_and_missing_targets_refuse_test() ->
    with_owner(fun(St) ->
        ?assertMatch({fail,_},erlog_int:prove_goal({prolog_workbench_draft,<<"isa(before,thing).\n">>,{add,{isa,before,thing}},{'Draft'}},St)),
        ?assertMatch({fail,_},erlog_int:prove_goal({prolog_workbench_draft,<<>>,{remove,{isa,before,thing}},{'Draft'}},St))
    end).
unchanged_replacement_preserves_clause_order_test() ->
    with_owner(fun(St) ->
        Source = <<"isa(before, thing).\nisa(other, thing).\n">>,
        ?assertEqual(Source,draft(Source,{replace,{isa,before,thing},{isa,before,thing}},St))
    end).
canonical_fact_identity_test() ->
    with_owner(fun(St) ->
        Before={attribute,{'$quod_symbol',<<"me">>},{'$quod_symbol',<<"note">>},<<"old">>},
        After={attribute,{'$quod_symbol',<<"me">>},{'$quod_symbol',<<"note">>},<<"new">>},
        Source = <<"attribute(me, note, <<\"old\">>).\n">>,
        Text=draft(Source,{replace,Before,After},St),
        ?assertNotEqual(nomatch,binary:match(Text,<<"new">>)),
        ?assertEqual(<<>>,draft(Source,{remove,Before},St)),
        ?assertMatch({fail,_},erlog_int:prove_goal({prolog_workbench_draft,Source,{add,Before},{'Draft'}},St)),
        ?assertEqual(Source,draft(Source,{replace,Before,Before},St)),
        ?assertEqual([],changes(St))
    end).
saved_fact_rule_spelling_test() ->
    with_owner(fun(St) ->
        Source = <<"attribute(me, note, <<\"old\">>) :- true.\n">>,
        Before={attribute,me,note,<<"old">>},After={attribute,me,note,<<"new">>},
        ?assertNotEqual(nomatch,binary:match(draft(Source,{replace,Before,After},St),<<"new">>)),
        ?assertEqual(<<>>,draft(Source,{remove,Before},St)),
        ?assertMatch({fail,_},erlog_int:prove_goal({prolog_workbench_draft,Source,{add,Before},{'Draft'}},St)),
        ?assertEqual(Source,draft(Source,{replace,Before,Before},St)),
        ?assertEqual([],changes(St))
    end).
draft(Source,Change,St) ->
    Chunks=chunks(Source,Change,St),
    ?assertMatch({source_chunk,done,_},lists:last(Chunks)),
    ?assert(lists:all(fun({source_chunk,more,_})->true;(_)->false end,lists:droplast(Chunks))),
    iolist_to_binary([Text||{source_chunk,_,Text}<-Chunks]).
chunks(Source,Change,St) ->
    {succeed,Next}=erlog_int:prove_goal({findall,{'Draft'},
        {prolog_workbench_draft,Source,Change,{'Draft'}},{'Chunks'}},St),
    erlog_int:dderef({'Chunks'},Next#est.bs).
large_draft_uses_the_existing_bounded_chunk_owner_test() ->
    with_owner(fun(St) ->
        Text=binary:copy(<<"retained-text-">>,100),
        Source=iolist_to_binary([io_lib:format("note(~B,<<\"~s\">>).~n",[N,Text])||N<-lists:seq(1,80)]),
        ?assertMatch({ok,_},quod_client_goal_parser:parse_program(Source,3)),
        Chunks=chunks(Source,{add,{isa,child,thing}},St),
        ?assert(length(Chunks)>1),
        ?assert(lists:all(fun({source_chunk,_,Part})->byte_size(Part)=<16384 end,Chunks)),
        ?assertMatch({source_chunk,done,_},lists:last(Chunks)),
        Joined=iolist_to_binary([Part||{source_chunk,_,Part}<-Chunks]),
        {ok,Program}=quod_client_goal_parser:parse_program(Joined,3),
        ?assertEqual(81,length(Program)),?assertEqual([],changes(St))
    end).
changes(#est{db=#db{ref=Ref}}) -> quod_erlog_db_local_prove:get_local_changes(Ref).
with_owner(Fun) ->
    {ok,Terms}=erlog_io:read_file("/input/gui_tools.pl"),
    Base=quod_committed_projection:new_est(),
    Committed=quod_ct:commit_kb(Base#est{db=lists:foldl(fun erlog_int:assertz_clause/2,Base#est.db,Terms)}),
    St=quod_erlog_db_local_prove:wrap_state(Committed,#{read_set=>true}),
    try Fun(St) after
        quod_erlog_db_local_prove:cleanup_read_set(St),
        #est{db=#db{ref=Ref}}=Committed,quod_erlog_db_mvcc:delete(Ref)
    end.
