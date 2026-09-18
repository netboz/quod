-module(quod_common_primitives_tests).

%% `'$quod_draw'/3` and `binary_codes/2` on the base engine every ontology
%% starts from. The draw runs inside real proof sessions: an origin session
%% with a started proof context, a scope session carrying the same proof id,
%% and the contexts where it must refuse (no proof, verdict engines).

-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").

-define(NS, <<"test:primitives">>).
-define(DRAW, '$quod_draw').

binary_codes_test() ->
    St = bare(),
    ?assertEqual([$U, $g], value({'C'}, {binary_codes, <<"Ug">>, {'C'}}, St)),
    ?assertEqual(<<"Ug">>, value({'B'}, {binary_codes, {'B'}, [$U, $g]}, St)),
    ?assertEqual([], value({'C'}, {binary_codes, <<>>, {'C'}}, St)),
    ?assertEqual(<<>>, value({'B'}, {binary_codes, {'B'}, []}, St)),
    ?assertEqual(<<0, 255>>, value({'B'}, {binary_codes, {'B'}, [0, 255]}, St)),
    ?assertMatch({succeed, _},
                 erlog_int:prove_goal({binary_codes, <<"Ug">>, [$U, $g]}, St)),
    lists:foreach(
      fun(Goal) -> ?assertMatch({fail, _}, erlog_int:prove_goal(Goal, St)) end,
      [{binary_codes, <<"Ug">>, [$U]},
       {binary_codes, ug, {'C'}},
       {binary_codes, 42, {'C'}},
       {binary_codes, [$U], {'C'}},
       {binary_codes, {'B'}, [300]},
       {binary_codes, {'B'}, [-1]},
       {binary_codes, {'B'}, [a]},
       {binary_codes, {'B'}, foo},
       {binary_codes, {'B'}, [$U | {'T'}]},
       {binary_codes, {'B'}, {'C'}}]).

origin_draw_test() ->
    ProofId = crypto:strong_rand_bytes(32),
    with_committed(fun(Committed) ->
        with_origin(ProofId, fun() ->
            Draw = fun(Salt, N) ->
                           draw(Committed, {origin, test}, Salt, N)
                   end,
            ?assertEqual(expected(ProofId, salt, 10), Draw(salt, 10)),
            ?assertEqual(Draw(salt, 10), Draw(salt, 10)),
            ?assertEqual(expected(ProofId, {agent, 1, [x]}, 1000),
                         Draw({agent, 1, [x]}, 1000)),
            ?assertEqual(0, Draw(salt, 1)),
            ?assert(lists:all(fun(I) -> I >= 0 andalso I < 7 end,
                              [Draw(S, 7) || S <- lists:seq(1, 20)])),
            Spread = [Draw(S, 1000000) || S <- lists:seq(1, 8)],
            ?assert(length(lists:usort(Spread)) > 1),
            %% The wrapper every ontology calls.
            ?assertEqual(Draw(salt, 10),
                         solve(Committed, {origin, test},
                               {proof_draw, salt, 10, {'I'}}, 'I')),
            %% Backtracking re-asks the same question and gets the same answer.
            ?assertEqual([Draw(s, 100), Draw(s, 100)],
                         solve(Committed, {origin, test},
                               {findall, {'I'},
                                {';', {?DRAW, s, 100, {'I'}},
                                 {?DRAW, s, 100, {'I'}}}, {'L'}}, 'L'))
        end)
    end).

scope_draw_matches_origin_test() ->
    ProofId = crypto:strong_rand_bytes(32),
    Scope = {scope, ProofId, self(), make_ref(), <<1:128>>},
    with_committed(fun(Committed) ->
        ?assertEqual(expected(ProofId, salt, 10),
                     draw(Committed, Scope, salt, 10)),
        with_origin(ProofId, fun() ->
            ?assertEqual(draw(Committed, {origin, test}, salt, 10),
                         draw(Committed, Scope, salt, 10))
        end)
    end).

refuses_outside_a_proof_test() ->
    ProofId = crypto:strong_rand_bytes(32),
    Scope = {scope, ProofId, self(), make_ref(), <<1:128>>},
    Goal = {?DRAW, salt, 10, {'I'}},
    with_committed(fun(Committed) ->
        %% No session metadata at all, and an origin whose proof context was
        %% never started.
        ?assertEqual(fail, quod_ct:session_prove(
                             Committed, undefined, proof_ctx(), Goal)),
        ?assertEqual(fail, quod_ct:session_prove(
                             Committed, {origin, test}, proof_ctx(), Goal)),
        %% Verdict engines never draw, whatever the session carries.
        ?assertEqual(fail, quod_ct:session_prove(
                             Committed, Scope,
                             quod_predicates:verdict_context(?NS, 1), Goal)),
        ?assertEqual(fail, quod_ct:session_prove(
                             Committed, Scope,
                             quod_predicates:policy_verdict_context(?NS, 1),
                             Goal)),
        %% A bare engine without any session fails plainly too.
        ?assertMatch({fail, _}, erlog_int:prove_goal(Goal, bare())),
        ?assertMatch({fail, _}, erlog_int:prove_goal(
                                  {proof_draw, salt, 10, {'I'}}, bare()))
    end).

invalid_inputs_fail_plainly_test() ->
    ProofId = crypto:strong_rand_bytes(32),
    Scope = {scope, ProofId, self(), make_ref(), <<1:128>>},
    with_committed(fun(Committed) ->
        lists:foreach(
          fun(Goal) ->
                  ?assertEqual(fail, quod_ct:session_prove(
                                       Committed, Scope, proof_ctx(), Goal))
          end,
          [{?DRAW, salt, 0, {'I'}},
           {?DRAW, salt, -3, {'I'}},
           {?DRAW, salt, ten, {'I'}},
           {?DRAW, salt, {'N'}, {'I'}},
           {?DRAW, {'Salt'}, 10, {'I'}},
           {?DRAW, {f, {'X'}}, 10, {'I'}},
           {?DRAW, [a | {'T'}], 10, {'I'}},
           {?DRAW, salt, 10, 99}]),
        %% A ground compound salt, and a bound I that matches, succeed.
        I = draw(Committed, Scope, {f, [1, <<"b">>, c]}, 10),
        ?assertMatch({ok, _}, quod_ct:session_prove(
                                Committed, Scope, proof_ctx(),
                                {?DRAW, {f, [1, <<"b">>, c]}, 10, I}))
    end).

%% --- helpers ---------------------------------------------------------------

expected(ProofId, Salt, N) ->
    {ok, Bytes} = quod_wire_term:encode_canonical(Salt),
    binary:decode_unsigned(crypto:mac(hmac, sha256, ProofId, Bytes)) rem N.

draw(Committed, Metadata, Salt, N) ->
    solve(Committed, Metadata, {?DRAW, Salt, N, {'I'}}, 'I').

solve(Committed, Metadata, Goal, Var) ->
    {ok, Bindings} = quod_ct:session_prove(
                       Committed, Metadata, proof_ctx(), Goal),
    maps:get(Var, Bindings).

proof_ctx() -> quod_predicates:proof_context(?NS, 1, undefined).

with_origin(ProofId, Fun) ->
    _ = quod_proof_context:start(
          ProofId, false, {?NS, <<0:256>>},
          quod_time:mono_ms() + 60000, anonymous),
    try Fun()
    after quod_proof_context:stop(fun(_) -> ok end, fun(_) -> ok end)
    end.

with_committed(Fun) ->
    Committed = quod_ct:commit_kb(quod_committed_projection:new_est()),
    try Fun(Committed)
    after
        #est{db = #db{ref = Ref}} = Committed,
        quod_erlog_db_mvcc:delete(Ref)
    end.

bare() ->
    quod_erlog_db_local_prove:wrap_state(
      quod_ct:commit_kb(quod_committed_projection:new_est()),
      #{read_set => true}).

value(Var, Goal, St) ->
    {succeed, Final} = erlog_int:prove_goal(Goal, St),
    erlog_int:dderef(Var, Final#est.bs).
