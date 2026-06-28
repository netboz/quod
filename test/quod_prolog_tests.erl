-module(quod_prolog_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").
-include("quod_ledger.hrl").

%%%===================================================================
%%% fixtures
%%%===================================================================

setup() ->
    {ok, _} = application:ensure_all_started(gproc),
    Ns = <<"test:", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    {ok, Pid} = quod_prolog:start_link(Ns, #{node_id => {"127.0.0.1", 5000}}),
    %% no quod_ledger in these isolated tests — simulate the rebuild handshake completing
    ok = quod_prolog:mark_ready(Ns),
    {Ns, Pid}.

cleanup({_Ns, Pid}) ->
    case is_process_alive(Pid) of true -> gen_server:stop(Pid); false -> ok end,
    ok.

prolog_test_() ->
    {foreach, fun setup/0, fun cleanup/1,
     [fun t_unknown_fails/1,
      fun t_apply_and_read/1,
      fun t_occ_reject/1]}.

%%%===================================================================
%%% helpers
%%%===================================================================

%% a real content-diff for asserting `Fact` (erlog term) — built via the overlay
%% so the clause body form matches what quod_prolog produces.
diff_for(Fact) ->
    Tab = list_to_atom("qpt_" ++ integer_to_list(erlang:unique_integer([positive]))),
    {ok, C} = erlog_int:new(erlog_db_ets, Tab),
    W0 = quod_erlog_db_local_prove:wrap_state(C, #{read_set => true}),
    {succeed, W1} = erlog_int:prove_goal({assertz, Fact}, W0),
    Diff = quod_erlog_db_local_prove:get_local_changes((W1#est.db)#db.ref),
    quod_erlog_db_local_prove:cleanup_read_set(W1),
    Diff.

change(Ns, Diff, RC) ->
    #transaction{tx_id = integer_to_binary(erlang:unique_integer([positive])),
            caller_ns = Ns, diff = Diff, read_check = RC,
            author = {"127.0.0.1", 5000}, sig = none}.

%%%===================================================================
%%% tests
%%%===================================================================

t_unknown_fails({Ns, _}) ->
    fun() ->
        %% a goal over a predicate the ontology doesn't define → fail, not crash
        ?assertEqual(fail, quod_prolog:prove(Ns, {nonexistent, foo}, Ns)),
        %% routing: unknown namespace is distinct from goal-failure
        ?assertEqual({error, no_such_namespace},
                     quod_prolog:prove(<<"nope">>, {anything, x}, <<"nope">>))
    end.

t_apply_and_read({Ns, _}) ->
    fun() ->
        ok = quod_prolog:apply_block(Ns, 1, change(Ns, diff_for({parent, tom, bob}), #{})),
        %% a bound read returns the binding and the height read
        ?assertMatch({ok, [#{'X' := bob}], 1}, quod_prolog:prove(Ns, {parent, tom, {'X'}}, Ns)),
        %% a ground read succeeds with an empty binding set
        ?assertEqual({ok, [#{}], 1}, quod_prolog:prove(Ns, {parent, tom, bob}, Ns)),
        %% a second committed block advances the applied height
        ok = quod_prolog:apply_block(Ns, 2, change(Ns, diff_for({parent, ann, eve}), #{})),
        ?assertMatch({ok, [#{'P' := ann}], 2}, quod_prolog:prove(Ns, {parent, {'P'}, eve}, Ns))
    end.

t_occ_reject({Ns, _}) ->
    fun() ->
        ok = quod_prolog:apply_block(Ns, 1, change(Ns, diff_for({parent, tom, bob}), #{})),
        %% a change whose read-set expects a stale hash of parent/2 → rejected at apply.
        %% apply_block is an async cast (returns ok); the OCC reject is observed by its
        %% EFFECT — the block changes no facts (sibling/1 stays absent). The apply_block cast
        %% is FIFO-ordered before the following prove call, so the effect is visible.
        Stale = change(Ns, diff_for({sibling, x}), #{{parent, 2} => 12345}),
        ok = quod_prolog:apply_block(Ns, 2, Stale),
        ?assertEqual(fail, quod_prolog:prove(Ns, {sibling, x}, Ns)),
        %% a non-stale read-set (parent/2 matches its real hash) commits fine
        M = real_hash(Ns, {parent, 2}),
        Good = change(Ns, diff_for({sibling, y}), #{{parent, 2} => M}),
        ?assertEqual(ok, quod_prolog:apply_block(Ns, 3, Good)),
        ?assertEqual({ok, [#{}], 3}, quod_prolog:prove(Ns, {sibling, y}, Ns))
    end.

%% read the committed hash of a predicate by asking quod_prolog to prove a probe
%% that records it — simplest is to recompute against a mirror of the same facts.
real_hash(_Ns, Functor) ->
    %% mirror the committed parent(tom,bob) into a throwaway db and hash it
    Tab = list_to_atom("qph_" ++ integer_to_list(erlang:unique_integer([positive]))),
    {ok, C0} = erlog_int:new(erlog_db_ets, Tab),
    {succeed, C1} = erlog_int:prove_goal({assertz, {parent, tom, bob}}, C0),
    quod_diff:functor_hash((C1#est.db)#db.mod, (C1#est.db)#db.ref, Functor).
