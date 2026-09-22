-module(quod_lens_tests).

%% The `quod:lens` ontology (priv/ontologies/quod_lens.pl): a lens and its
%% encoding declared apart, an encoding's preconditions actually refusing a
%% picture the data does not support, and one authored lens over `quod:licence`
%% producing descriptors that `quod:present` accepts.
%%
%% The end-to-end tests load both sources into one engine whose proof context is
%% `quod:licence`, so the lens's `::` asks take the real self-ask path in
%% `quod_ask` rather than a stub standing in for it.

-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").
-include("quod_vm_limits.hrl").

%% The components this ontology's own release actually has, in miniature: two
%% licences whose copyleft stops at the file, one that stops at the library's
%% own text, and one part nobody has established.
-define(PARTS,
        <<"component(<<\"quod\">>, <<\"cowboy\">>, <<\"ISC\">>).\n"
          "component(<<\"quod\">>, <<\"erlog\">>, <<\"Apache-2.0\">>).\n"
          "component(<<\"quod\">>, <<\"ranch\">>, <<\"ISC\">>).\n"
          "component(<<\"quod\">>, <<\"book\">>, <<\"OGL-1.0a\">>).\n"
          "component(<<\"quod\">>, <<\"quantile_estimator\">>, <<\"NOASSERTION\">>).\n">>).

%% --- the two declarations stay apart ----------------------------------------

a_lens_and_its_encoding_are_separate_test() ->
    with_lens(fun(St) ->
        %% the lens says what is asked, and names no mark, channel or colour
        ?assertEqual([<<"what may this work ship under">>],
                     solutions({'P'}, {lens, <<"work_licences">>, {'P'}}, St)),
        ?assertEqual([{<<"quod:licence">>, <<"component">>}],
                     [{Ns, S} || [Ns, S] <-
                          solutions([{'N'}, {'S'}],
                                    {lens_subject, <<"work_licences">>, {'N'}, {'S'}}, St)]),
        ?assertEqual([{<<"family">>, <<"nominal">>}, {<<"reach">>, <<"ordinal">>}],
                     lists:sort([{M, S} || [M, S] <-
                          solutions([{'M'}, {'S'}],
                                    {lens_measure, <<"work_licences">>, {'M'}, {'S'}}, St)])),
        %% the encoding says how it is shown, and is reached through the lens
        ?assertEqual([<<"reach_columns">>],
                     solutions({'E'}, {encoding, {'E'}, <<"work_licences">>, {'_'}}, St)),
        ?assertEqual([<<"quod:present">>],
                     solutions({'P'}, {encoding, <<"reach_columns">>, {'_'}, {'P'}}, St)),
        ?assertEqual([<<"box">>],
                     solutions({'K'}, {encoding_mark, <<"reach_columns">>, {'K'}}, St)),
        %% reach is carried by a channel; it is not an intrinsic shape of reach
        ?assertEqual([<<"high">>],
                     solutions({'C'},
                               {encoding_channel, <<"reach_columns">>, {'C'}, <<"reach">>},
                               St))
    end).

every_group_has_a_declared_position_and_colour_test() ->
    with_lens(fun(St) ->
        Groups = solutions({'G'}, {group_at, {'G'}, {'_'}}, St),
        %% nothing is laid out or coloured by the order its facts are written
        lists:foreach(
          fun(Group) ->
              ?assertMatch([_], solutions({'C'}, {group_colour, Group, {'C'}}, St))
          end, Groups),
        Colours = solutions({'C'}, {group_colour, {'_'}, {'C'}}, St),
        ?assertEqual(length(Colours), length(lists:usort(Colours))),
        ?assertEqual(length(Groups), length(Colours))
    end).

%% --- the preconditions ------------------------------------------------------

single_valued_refuses_a_subject_with_two_values_test() ->
    with_lens(fun(St) ->
        One = [row(thing_a, <<"gpl">>, 3, <<"a">>)],
        Two = [row(thing_a, <<"gpl">>, 3, <<"a">>),
               row(thing_a, <<"mpl">>, 1, <<"a">>)],
        holds({satisfied, {single_valued, <<"reach">>}, One}, St),
        fails({satisfied, {single_valued, <<"reach">>}, Two}, St),
        %% two groups at the SAME rank is not a conflict: it is one subject
        %% under two parents, and both marks stay
        Both = [row(thing_a, <<"gpl">>, 3, <<"a">>),
                row(thing_a, <<"cc">>, 3, <<"a">>)],
        holds({satisfied, {single_valued, <<"reach">>}, Both}, St)
    end).

a_missing_value_is_absent_not_out_of_band_test() ->
    with_lens(fun(St) ->
        Absent = [row(thing_a, <<"unestablished">>, none, <<"a">>)],
        holds({satisfied, {ranked, <<"reach">>, 0, 4}, Absent}, St),
        fails({satisfied, {ranked, <<"reach">>, 0, 4}},
              [row(thing_a, <<"gpl">>, 5, <<"a">>)], St),
        %% and it is not treated as a zero
        ?assertEqual([300], solutions({'H'}, {lifted, <<"reach_columns">>, none, {'H'}}, St)),
        ?assertEqual([300], solutions({'H'}, {lifted, <<"reach_columns">>, 0, {'H'}}, St)),
        ?assertEqual([1500], solutions({'H'}, {lifted, <<"reach_columns">>, 4, {'H'}}, St))
    end).

an_undeclared_group_refuses_the_view_test() ->
    with_lens(fun(St) ->
        Known = [row(thing_a, <<"gpl">>, 3, <<"a">>)],
        Unknown = [row(thing_a, <<"vermilion">>, 3, <<"a">>)],
        holds({satisfied, {ordered, <<"family">>}, Known}, St),
        holds({satisfied, {distinct_colours, <<"family">>}, Known}, St),
        fails({satisfied, {ordered, <<"family">>}, Unknown}, St),
        fails({satisfied, {distinct_colours, <<"family">>}, Unknown}, St)
    end).

the_scene_bound_is_its_own_test() ->
    with_lens(fun(St) ->
        ?assertEqual([256], solutions({'N'}, {limit, <<"marks">>, {'N'}}, St)),
        Rows = [row(N, <<"gpl">>, 3, <<"a">>) || N <- lists:seq(1, 257)],
        fails({satisfied, {within, <<"marks">>}, Rows}, St),
        holds({satisfied, {within, <<"marks">>}, tl(Rows)}, St)
    end).

%% The lens never produces more marks, or longer labels, than `quod:present`
%% accepts. Each ontology owns its own bound; this is the check that the two
%% agree, so neither has to restate the other's number.
the_lens_bounds_sit_inside_the_presentation_bounds_test() ->
    Lens = terms(lens_source()),
    Present = terms(present_source()),
    ?assertEqual(true, limit_of(Lens, <<"marks">>) =< limit_of(Present, <<"scene">>)),
    ?assertEqual(true, limit_of(Lens, <<"label">>) =< limit_of(Present, <<"label">>)).

%% --- the authored lens, end to end ------------------------------------------
%% `quod:licence` ships the rules, not anybody's parts list, so each of these
%% supplies the components it is about.

the_view_answers_what_this_work_may_ship_under_test() ->
    with_work(?PARTS, fun(St) ->
        Marks = view(<<"quod">>, St),
        ?assertEqual(6, length(Marks)),
        %% the front row is the answer: every licence the combination admits.
        %% One unestablished part is enough to make that answer a single
        %% licence nobody may actually ship under.
        Front = [Mark || Mark <- Marks, group_of(Mark) =:= <<"#F9C80E">>],
        ?assertEqual([<<"NOASSERTION">>], [label_of(M) || M <- Front]),
        %% and it depicts the licence fact it came from, in its own ontology
        ?assertEqual([{depicts, <<"quod:licence">>,
                       {ships, <<"quod">>, <<"NOASSERTION">>}}],
                     [depicts_of(M) || M <- Front]),
        %% the rows behind are why: one mark per component, each depicting its
        %% own entity rather than a mesh name
        Parts = [depicts_of(M) || M <- Marks, depicts_of(M) =/= depicts_nothing,
                 element(1, element(3, depicts_of(M))) =:= component],
        ?assertEqual(5, length(Parts)),
        ?assert(lists:member({depicts, <<"quod:licence">>,
                              {component, <<"quod">>, <<"cowboy">>}}, Parts)),
        %% reach is stepped evenly, and the step is the encoding's, not a ratio
        ?assertEqual(300, height_of(mark_for(Marks, <<"cowboy">>))),
        ?assertEqual(600, height_of(mark_for(Marks, <<"book">>))),
        ?assertEqual(1500, height_of(mark_for(Marks, <<"quantile_estimator">>))),
        %% NOASSERTION is not a missing value: quod:licence declares that it
        %% reaches the whole work, which is why it stands at full height in the
        %% family of things nobody has established
        ?assertEqual(<<"#5B6273">>,
                     group_of(mark_for(Marks, <<"quantile_estimator">>)))
    end).

a_value_nobody_declared_is_shown_absent_not_as_zero_test() ->
    %% A part whose licence has no licence/3 fact at all has no reach. It keeps
    %% its mark, in the group `absent/3` declares, at the base height.
    Odd = <<"component(<<\"odd\">>, <<\"mystery\">>, <<\"WTFPL\">>).">>,
    with_work(Odd, fun(St) ->
        Marks = view(<<"odd">>, St),
        Mystery = mark_for(Marks, <<"mystery">>),
        ?assertEqual(<<"#2E3340">>, group_of(Mystery)),
        ?assertEqual(300, height_of(Mystery)),
        ?assertEqual({depicts, <<"quod:licence">>,
                      {component, <<"odd">>, <<"mystery">>}}, depicts_of(Mystery))
    end).

the_view_is_a_scene_quod_present_accepts_test() ->
    Marks = with_work(?PARTS, fun(St) -> view(<<"quod">>, St) end),
    with_present(fun(Present) -> holds({well_formed_scene, Marks}, Present) end).

%% Every generated binary stays clear of the 32-byte width at which the signed
%% reply renderer reads a binary as an Ed25519 key. Domain text a descriptor
%% carries unchanged — an entity name — is the domain's business; what this
%% ontology mints is bounded here.
generated_text_is_short_test() ->
    with_work(?PARTS, fun(St) ->
        lists:foreach(
          fun({mark, Id, _Kind, _Size, _T, {material, Colour, _F}, Label, _D}) ->
              ?assert(byte_size(Id) =< 16),
              ?assertEqual(7, byte_size(Colour)),
              case Label of
                  {label, Text, _Placement} -> ?assert(byte_size(Text) =< 24);
                  unlabelled -> ok
              end
          end, view(<<"quod">>, St))
    end).

the_layout_is_deterministic_and_grouped_test() ->
    with_work(?PARTS, fun(St) ->
        Marks = view(<<"quod">>, St),
        ?assertEqual(Marks, view(<<"quod">>, St)),
        %% mark ids are view-scoped occurrences: distinct, and no domain name
        Ids = [element(2, M) || M <- Marks],
        ?assertEqual(length(Ids), length(lists:usort(Ids))),
        %% one row per group, in declared order: the answer in front, then the
        %% families, each one step further back
        ?assertEqual([0, 900, 1800, 2700], lists:usort([back_of(M) || M <- Marks])),
        %% within a group the marks run across from the origin without gaps
        ?assertEqual([0, 600, 1200],
                     lists:sort([across_of(M) || M <- Marks, back_of(M) =:= 900]))
    end).

a_component_under_two_families_is_shown_twice_test() ->
    %% quod:licence gives each licence one family, so this asserts a second one
    %% to prove the layout does not quietly pick a parent. isa/2 is not a tree,
    %% and neither is the grouping built on it.
    Extra = <<(?PARTS)/binary, "licence(<<\"ISC\">>, <<\"cc\">>, 0).">>,
    with_work(Extra, fun(St) ->
        Marks = view(<<"quod">>, St),
        Cowboy = [M || M <- Marks,
                       depicts_of(M) =:= {depicts, <<"quod:licence">>,
                                          {component, <<"quod">>, <<"cowboy">>}}],
        ?assertEqual(2, length(Cowboy)),
        ?assertEqual([<<"#698F3F">>, <<"#C9A227">>],
                     lists:sort([group_of(M) || M <- Cowboy])),
        %% same subject, distinct mark identities
        ?assertEqual(2, length(lists:usort([element(2, M) || M <- Cowboy])))
    end).

a_conflicting_second_value_refuses_the_view_and_names_why_test() ->
    %% The same second family, but at a different reach: one subject would then
    %% carry two heights, which the encoding says it cannot show.
    Extra = <<(?PARTS)/binary, "licence(<<\"ISC\">>, <<\"cc\">>, 3).">>,
    with_work(Extra, fun(St) ->
        fails({view, <<"work_licences">>, [<<"quod">>], {'M'}}, St),
        ?assertEqual([{single_valued, <<"reach">>}],
                     solutions({'R'},
                               {diagnosis, <<"work_licences">>, [<<"quod">>], {'R'}},
                               St))
    end).

a_height_channel_must_carry_an_ordinal_measure_test() ->
    %% A lens and an encoding declared exactly like the authored pair, except
    %% that the channel which lifts each mark is pointed at a nominal measure.
    %% Height steps evenly and so asserts an order; the view refuses rather
    %% than drawing one over a measure nobody said was ordered.
    Nominal =
        <<(?PARTS)/binary,
          "lens(<<\"by_family\">>, <<\"which families are here\">>).\n"
          "lens_subject(<<\"by_family\">>, <<\"quod:licence\">>, <<\"component\">>).\n"
          "lens_measure(<<\"by_family\">>, <<\"family\">>, <<\"nominal\">>).\n"
          "encoding(<<\"family_columns\">>, <<\"by_family\">>, <<\"quod:present\">>).\n"
          "encoding_mark(<<\"family_columns\">>, <<\"box\">>).\n"
          "encoding_layout(<<\"family_columns\">>, <<\"grouped_columns\">>).\n"
          "encoding_channel(<<\"family_columns\">>, <<\"high\">>, <<\"family\">>).\n"
          "encoding_step(<<\"family_columns\">>, <<\"high\">>, 300, 300).\n"
          "encoding_step(<<\"family_columns\">>, <<\"across\">>, 0, 600).\n"
          "encoding_step(<<\"family_columns\">>, <<\"back\">>, 0, 900).\n"
          "encoding_extent(<<\"family_columns\">>, 400).\n"
          "rows(<<\"by_family\">>, Parameters, Rows) :- "
          "rows(<<\"work_licences\">>, Parameters, Rows).\n">>,
    with_work(Nominal, fun(St) ->
        %% its requirements are all met — nothing is wrong with the data
        holds({met, <<"family_columns">>, []}, St),
        %% and the authored pair, whose height channel is ordinal, still draws
        ?assertEqual(6, length(view(<<"quod">>, St))),
        fails({view, <<"by_family">>, [<<"quod">>], {'M'}}, St)
    end).

a_work_nothing_may_carry_says_so_test() ->
    %% GPL-2.0-only cannot take in Apache-2.0's patent terms and nothing else
    %% may carry GPL-2.0-only, so no licence admits the pair. The view says that
    %% rather than showing an empty front row.
    Conflicted = <<"component(<<\"conflicted\">>, <<\"core\">>, <<\"GPL-2.0-only\">>).\n"
                   "component(<<\"conflicted\">>, <<\"http\">>, <<\"Apache-2.0\">>).">>,
    with_work(Conflicted, fun(St) ->
        Marks = view(<<"conflicted">>, St),
        ?assertEqual(3, length(Marks)),
        [Verdict] = [M || M <- Marks, back_of(M) =:= 0],
        ?assertEqual(<<"nothing may carry it">>, label_of(Verdict)),
        ?assertEqual(<<"#C14953">>, group_of(Verdict)),
        %% it stands for the view's own reading, so it depicts no entity
        ?assertEqual(depicts_nothing, depicts_of(Verdict))
    end).

%% --- policy and budget ------------------------------------------------------

policy_test() ->
    with_committed_lens(<<"peer_admitted(k, h, p, k).">>, fun(_C, St) ->
        lists:foreach(fun(Goal) -> holds({can_invoke, Goal, anyone, [], ns}, St) end,
                      [{lens, <<"work_licences">>, {'P'}},
                       {encoding, {'E'}, <<"work_licences">>, {'P'}},
                       {requires, <<"reach_columns">>, {'R'}},
                       {group_colour, <<"gpl">>, {'C'}}]),
        Change = {assertz, {group_colour, <<"gpl">>, <<"#000000">>}},
        fails({can_invoke, Change, anyone, [], ns}, St),
        holds({can_invoke, Change, {node, k}, [], ns}, St)
    end).

the_class_view_is_derived_test() ->
    with_lens(fun(St) ->
        holds({isa, lens, thing}, St),
        ?assertEqual([<<"work_licences">>],
                     solutions({'L'}, {instance_of, lens, {'L'}}, St)),
        ?assertEqual([<<"reach_columns">>],
                     solutions({'E'}, {instance_of, encoding, {'E'}}, St)),
        ?assertEqual([<<"family">>, <<"reach">>],
                     lists:sort(solutions({'M'},
                                          {attribute, <<"work_licences">>, measure, {'M'}},
                                          St))),
        ?assertEqual(5, length(solutions({'R'},
                                         {attribute, <<"reach_columns">>, requires, {'R'}},
                                         St)))
    end).

vocabulary_fits_the_genesis_budget_test() ->
    Terms = terms(lens_source()),
    New = quod_wire_term:cold_new_symbols(Terms),
    ?assert(length(New) =< ?QUOD_MAX_NEW_MATERIAL_ATOMS - 10, {New, length(New)}),
    ?assertNot(lists:any(fun has_float/1, Terms)).

has_float(T) when is_float(T) -> true;
has_float([Head | Tail]) -> has_float(Head) orelse has_float(Tail);
has_float(T) when is_tuple(T) -> lists:any(fun has_float/1, tuple_to_list(T));
has_float(_) -> false.

%% --- helpers ---------------------------------------------------------------

lens_source() -> filename:join(code:priv_dir(quod), "ontologies/quod_lens.pl").
licence_source() -> filename:join(code:priv_dir(quod), "ontologies/quod_licence.pl").
present_source() -> filename:join(code:priv_dir(quod), "ontologies/quod_present.pl").

terms(Path) -> quod_committed_projection:read_terms(Path).

limit_of(Terms, What) ->
    [Max] = [N || {limit, W, N} <- Terms, W =:= What],
    Max.

row(Thing, Group, Rank, Text) -> {row, Thing, Group, Rank, Text}.

%% One solution of view/3 is the whole bounded list of descriptors.
view(Work, St) ->
    [Marks] = solutions({'M'}, {view, <<"work_licences">>, [Work], {'M'}}, St),
    Marks.

group_of({mark, _Id, _K, _S, _T, {material, Colour, _F}, _L, _D}) -> Colour.
label_of({mark, _Id, _K, _S, _T, _M, {label, Text, _P}, _D}) -> Text.
depicts_of({mark, _Id, _K, _S, _T, _M, _L, Depicts}) -> Depicts.
across_of({mark, _Id, _K, _S, {transform, X, _Y, _Z, _A, _B, _C}, _M, _L, _D}) -> X.
back_of({mark, _Id, _K, _S, {transform, _X, _Y, Z, _A, _B, _C}, _M, _L, _D}) -> Z.
height_of({mark, _Id, _K, Size, _T, _M, _L, _D}) ->
    [Height] = [V || {f, <<"height">>, V} <- Size],
    Height.

mark_for(Marks, Part) ->
    [Mark] = [M || M <- Marks, label_of(M) =:= Part],
    Mark.

holds(Goal, St) -> ?assertMatch({succeed, _}, erlog_int:prove_goal(Goal, St)).
fails(Goal, St) -> ?assertMatch({fail, _}, erlog_int:prove_goal(Goal, St)).
fails(Goal, Rows, St) -> fails(erlang:append_element(Goal, Rows), St).

solutions(Template, Goal, St) ->
    {succeed, Final} = erlog_int:prove_goal({findall, Template, Goal, {'L'}}, St),
    erlog_int:dderef({'L'}, Final#est.bs).

with_lens(Fun) ->
    with_committed_lens(<<>>, fun(_Committed, St) -> Fun(St) end).

with_committed_lens(Extra, Fun) ->
    with_sources([lens_source()], Extra, undefined, Fun).

with_present(Fun) ->
    with_sources([present_source()], <<>>, undefined,
                 fun(_Committed, St) -> Fun(St) end).

%% The lens and the ontology it looks at, in one engine whose proof context is
%% that ontology: `::` then takes quod_ask's self-ask path and proves in place.
with_work(Extra, Fun) ->
    with_sources([lens_source(), licence_source()], Extra, <<"quod:licence">>,
                 fun(_Committed, St) -> Fun(St) end).

with_sources(Sources, Extra, ContextNs, Fun) ->
    Base = quod_committed_projection:new_est(),
    Loaded = lists:foldl(fun(Source, St) -> load_terms(terms(Source), St) end,
                         Base, Sources),
    Committed0 = quod_ct:commit_kb(load_source(Extra, Loaded)),
    Committed = context(ContextNs, Committed0),
    St = quod_erlog_db_local_prove:wrap_state(Committed, #{read_set => true}),
    try Fun(Committed, St)
    after
        #est{db = #db{ref = Ref}} = Committed,
        quod_erlog_db_mvcc:delete(Ref)
    end.

context(undefined, St) -> St;
context(Ns, St) ->
    quod_predicates:set_context(St, quod_predicates:proof_context(Ns, 1, undefined)).

load_source(<<>>, St) -> St;
load_source(Source, St) ->
    {ok, Terms} = erlog_io:read_string_terms(unicode:characters_to_list(Source)),
    load_terms(Terms, St).

load_terms(Terms, #est{db = Db0} = St) ->
    St#est{db = lists:foldl(fun erlog_int:assertz_clause/2, Db0, Terms)}.
