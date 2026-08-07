-module(quod_create_root_tests).
-include_lib("eunit/include/eunit.hrl").
-import(quod_ct, [rp/2]).

%%%===================================================================
%%% create-a-network: the founder reads quod_root.pl once and commits it
%%% into the ledger as the genesis; the content is queryable; a restart
%%% REPLAYS it (does not re-create); a bad genesis .pl fails the start.
%%%===================================================================

setup() ->
    {ok, _} = application:ensure_all_started(gproc),
    U   = integer_to_list(erlang:unique_integer([positive])),
    Dir = filename:join("/tmp", "quod_create_root_" ++ U),
    Ns  = list_to_binary("createroot:" ++ U),
    ok = establish_identity(),
    Content = #{namespace    => Ns,
                mode         => create,
                genesis_file => <<"ontologies/quod_root.pl">>,
                data_dir     => list_to_binary(Dir),
                seeds        => []},
    {Dir, Ns, Content}.

cleanup({Dir, Ns, _}) ->
    case quod_reg:where({quod_ns, Ns}) of
        undefined -> ok;
        Pid       -> stop_ns(Pid)
    end,
    ok = clear_identity(),
    _ = file:del_dir_r(Dir),
    ok.

%% Establish/clear a node identity in the app env, exactly as quod_app:apply_identity does
%% at boot — build_ns_config reads node_pubkey and consensus signs shares with identity_key.
%% ONE home for the pattern, shared by the fixture and the two-ontologies test.
establish_identity() ->
    {Pub, Seed} = quod_identity:generate(),
    application:set_env(quod, node_pubkey, Pub),
    application:set_env(quod, identity_key, quod_identity:key_term({Pub, Seed})).

clear_identity() ->
    application:unset_env(quod, node_pubkey),
    application:unset_env(quod, identity_key).

create_root_test_() ->
    {foreach, fun setup/0, fun cleanup/1,
     [fun t_create_root/1,
      fun t_create_root_restart/1,
      fun t_genesis_failure/1,
      fun t_genesis_sources_are_exclusive/1,
      fun t_invalid_precompiled_genesis_is_preflighted/1]}.

%% genesis_diff compiles the real quod_root.pl into write-set ops (compiled clause
%% bodies, the on-disk form). Every op is an assert; the acl_sovereign head is present.
genesis_diff_test() ->
    File = filename:join(code:priv_dir(quod), "ontologies/quod_root.pl"),
    Ops  = quod_prolog:genesis_diff(File),
    ?assert(length(Ops) >= 3),
    ?assert(lists:all(fun({assert, {_H, _B}}) -> true; (_) -> false end, Ops)),
    Heads = [H || {assert, {H, _B}} <- Ops],
    ?assert(lists:member({acl_sovereign, {':', quod, root}}, Heads)).

%%%===================================================================
%%% helpers (mirror quod_e2e_tests)
%%%===================================================================

start_ns(Ns, Cfg) ->
    {ok, Pid} = quod_ns:start_link(Ns, Cfg),
    unlink(Pid),
    Pid.

stop_ns(Pid) ->
    Ref = monitor(process, Pid),
    exit(Pid, shutdown),
    receive {'DOWN', Ref, process, Pid, _} -> ok after 5000 -> ok end.


%%%===================================================================
%%% tests
%%%===================================================================

t_create_root({_Dir, Ns, Content}) ->
    fun() ->
        {Ns, NsCfg} = quod_app:build_ns_config(Content),
        _Pid = start_ns(Ns, NsCfg),
        %% the genesis content from quod_root.pl is committed + applied into the kb
        ?assertMatch({ok, [#{}], _}, rp(Ns, {acl_sovereign, {':', quod, root}})),
        ?assertMatch({ok, [#{}], _},
                     rp(Ns, {system_ontology, {':', quod, root}, 'quod_root.pl', [], []})),
        %% the default-open can_invoke/4 rule unifies with anything
        ?assertMatch({ok, [#{}], _},
                     rp(Ns, {can_invoke, foo, {node, bar}, [], baz})),
        %% the founder is on its own committee, as a peer_admitted fact in the genesis kb
        ?assertMatch({ok, [#{}], _}, rp(Ns, {peer_admitted, {'_'}, {'_'}, {'_'}, {'_'}})),
        %% The fresh network incarnation is ordinary, queryable ontology truth.
        ?assertMatch(
           {ok, [#{'Nonce' := <<_:256>>}], _},
           rp(Ns, {consensus_incarnation, {'Nonce'}})),
        %% ONE genesis block (slot 1): incarnation + committee + root content
        ?assertMatch(#{committed := 1, last_applied := 1},
                     quod_simplex:stats(Ns))
    end.

t_create_root_restart({_Dir, Ns, Content}) ->
    fun() ->
        {Ns, NsCfg} = quod_app:build_ns_config(Content),
        Pid1 = start_ns(Ns, NsCfg),
        ?assertMatch({ok, [#{}], _}, rp(Ns, {acl_sovereign, {':', quod, root}})),
        {ok, [#{'Nonce' := Incarnation}], _} =
            rp(Ns, {consensus_incarnation, {'Nonce'}}),
        #{committed := CI1} = quod_simplex:stats(Ns),
        stop_ns(Pid1),
        %% restart from the same data_dir is a JOIN: replay the local ledger (the
        %% genesis is already there) — do NOT re-read the .pl, do NOT re-create.
        _Pid2 = start_ns(Ns, NsCfg),
        ?assertMatch({ok, [#{}], _}, rp(Ns, {acl_sovereign, {':', quod, root}})),
        ?assertMatch(
           {ok, [#{'Nonce' := Incarnation}], _},
           rp(Ns, {consensus_incarnation, {'Nonce'}})),
        #{committed := CI2} = quod_simplex:stats(Ns),
        ?assertEqual(CI1, CI2)   %% no extra genesis block appended
    end.

t_genesis_failure({_Dir, Ns, Content}) ->
    fun() ->
        Bad = Content#{genesis_file => <<"ontologies/does_not_exist.pl">>},
        {Ns, NsCfg} = quod_app:build_ns_config(Bad),
        %% quod_simplex init returns {stop, {genesis_failed, _}} ⇒ the sub-sup fails to
        %% start (fail-fast). Run it in a trap-exit helper so the failed supervisor's
        %% link doesn't take down the eunit test process.
        ?assertMatch({error, _}, start_link_isolated(Ns, NsCfg))
    end.

t_genesis_sources_are_exclusive({Dir, Ns, Content}) ->
    fun() ->
        {Ns, NsCfg0} = quod_app:build_ns_config(Content),
        InitialDiff = quod_prolog:terms_to_diff([{should_not_land, true}]),
        NsCfg = NsCfg0#{genesis_diff => InitialDiff},
        ?assertMatch({error, _}, start_link_isolated(Ns, NsCfg)),
        ?assertNot(
           filelib:is_dir(quod_ledger_store:ns_dir(Dir, Ns)))
    end.

t_invalid_precompiled_genesis_is_preflighted({Dir, Ns, Content}) ->
    fun() ->
        {Ns, FileCfg} = quod_app:build_ns_config(Content),
        DiffCfg =
            (maps:remove(genesis_file, FileCfg))#{
              genesis_diff => [{not_an_op, invalid}]},
        ?assertMatch({error, _}, start_link_isolated(Ns, DiffCfg)),
        %% Config validation runs before quod_ledger_store:open/2, so even the
        %% namespace directory is never created for an invalid prepared diff.
        ?assertNot(filelib:is_dir(quod_ledger_store:ns_dir(Dir, Ns)))
    end.

start_link_isolated(Ns, NsCfg) ->
    Parent = self(),
    spawn(fun() ->
              process_flag(trap_exit, true),
              Parent ! {start_result, (catch quod_ns:start_link(Ns, NsCfg))}
          end),
    receive {start_result, R} -> R after 5000 -> {error, timeout} end.

%%%===================================================================
%%% two ontologies on one node (doc/inter-ontology.md step 2)
%%%
%%% One node founds BOTH demo ontologies (animals + pets) side by side,
%%% sharing ONE data_dir (the ledger keeps one subdirectory per namespace).
%%% Each answers from its own kb; pets' cross-ontology links are stored as
%%% inert `:` names (following them is step 3 — nothing follows yet).
%%%===================================================================

two_ontologies_one_node_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    U   = integer_to_list(erlang:unique_integer([positive])),
    Dir = filename:join("/tmp", "quod_two_onts_" ++ U),
    ok = establish_identity(),
    Block = fun(Ns, File) ->
                    #{namespace => Ns, mode => create, genesis_file => File,
                      data_dir => list_to_binary(Dir), seeds => []}
            end,
    try
        {A, ACfg} = quod_app:build_ns_config(Block(<<"animals">>, <<"ontologies/animals.pl">>)),
        {P, PCfg} = quod_app:build_ns_config(Block(<<"pets">>,    <<"ontologies/pets.pl">>)),
        _ = start_ns(A, ACfg),
        _ = start_ns(P, PCfg),
        %% each ontology answers from its own kb
        ?assertMatch({ok, [#{}], _}, rp(A, {diet, dog, kibble})),
        ?assertMatch({ok, [#{}], _}, rp(A, {isa, dog, mammal})),
        ?assertMatch({ok, [#{}], _}, rp(P, {attribute, my_dog, name, rex})),
        %% the cross-ontology link is stored as an inert `:` name — plain data
        ?assertMatch({ok, [#{}], _}, rp(P, {isa, my_dog, {':', animals, dog}})),
        ?assertMatch({ok, [#{}], _}, rp(P, {no_follow, {'/', pedigree_ref, 2}})),
        %% pets holds NO dog diet locally — that answer lives in animals (step 3 follows it)
        ?assertNotMatch({ok, _, _}, rp(P, {diet, dog, {'DietVar'}})),
        %% one shared data_dir: each namespace kept its own subdirectory (the store's rule)
        ?assert(filelib:is_dir(quod_ledger_store:ns_dir(Dir, A))),
        ?assert(filelib:is_dir(quod_ledger_store:ns_dir(Dir, P)))
    after
        %% Teardown MUST run when an assert throws: look the namespaces up by NAME
        %% (no pid bindings needed), stop whatever started, clear the leaked env.
        lists:foreach(fun(Ns) ->
                              case quod_reg:where({quod_ns, Ns}) of
                                  undefined -> ok;
                                  Pid       -> stop_ns(Pid)
                              end
                      end, [<<"animals">>, <<"pets">>]),
        clear_identity(),
        _ = file:del_dir_r(Dir)
    end,
    ok.
