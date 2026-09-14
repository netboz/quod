-module(quod_dtx_parent_progress_tests).
-moduledoc """
Consensus validation follows the exact durable parent, not signing permission.

Real signed Begin controls and certified N=4 history. A registered Prolog
receiver captures actual casts; the tests supply explicit verdicts at that
boundary, not a second evaluator. No tick, sleep or recovery pull releases work.
""".
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

parent_progress_wakes_waiting_child_test_() ->
    isolated(fun() -> with_fixture(fun(F, S0, _Keys) ->
        %% Approved content can precede its durable commit in the pipeline.
        %% The approved-parent fixture is structural, not consensus-admitted.
        {ok, Parent} = quod_ledger:new_block(2, 1,
                         {batch, [maps:get(transaction, F)]}, quod_time:now_ms()),
        Approved = quod_simplex:test_blocked_dtx_owner(Parent, S0),
        {ok, Blob} = quod_dtx:encode_control(maps:get(begin_control, F)),
        Waiting = quod_simplex:test_propose_dtx_wave(3, [Blob], [], Approved),
        ?assertMatch({none, none, {_, _}, none, undefined},
                     quod_simplex:test_dtx_round(3, Waiting)),
        assert_no_request(),
        Token = {2, quod_simplex:block_hash(Parent)},
        Installed = quod_simplex:test_state_set(history_head, Token,
                      quod_simplex:test_state_set(slot, 2, Waiting)),
        Resumed = quod_simplex:settle_readiness(Waiting, Installed),
        {Hash, Token, Owner} = take_request(3),
        ?assertEqual(self(), Owner),
        ?assertMatch({Hash, {dtx, Token, Owner, _}, _, none, undefined},
                     quod_simplex:test_dtx_round(3, Resumed)),
        %% Neither duplicate progress nor ordinary mailbox turns re-issue it.
        ?assertEqual(Resumed, quod_simplex:settle_readiness(Resumed, Resumed)),
        assert_no_request(),
        _ = quod_simplex:test_on_dtx_verdict(3, Hash, Token, Owner, 2, abstain, Resumed),
        ok
    end) end).

certified_candidate_validates_before_voting_readiness_test_() ->
    isolated(fun() -> without_signing(fun() -> with_fixture(fun(F, S0, Keys) ->
        {Block, Hash, WithCerts} = certified_first(F, S0, Keys),
        Mode = {pulling, self()},
        Paused = quod_simplex:test_state_set(sync, Mode, WithCerts),
        Proposed = quod_simplex:dispatch(leader(2, Keys), {propose, Block, []}, Paused),
        Token = maps:get(history_head, quod_simplex:test_state_projection(S0)),
        ?assertEqual({Hash, Token, self()}, take_request(2)),
        Repeated = quod_simplex:dispatch(leader(2, Keys), {propose, Block, []}, Proposed),
        ?assertEqual(quod_simplex:test_dtx_round(2, Proposed),
                     quod_simplex:test_dtx_round(2, Repeated)),
        assert_no_request(),
        ?assertEqual(1, element(1, quod_simplex:test_committed_store(Proposed))),
        ?assertEqual({none, false, false}, quod_simplex:test_round(2, Proposed)),
        %% The real exact-parent preview and certificate-driven applier run.
        %% The pending recovery mode forbids fresh votes throughout application.
        Done = quod_simplex:test_on_dtx_verdict(
                 2, Hash, Token, self(), 1, {valid, #{}}, Proposed),
        {2, Store} = quod_simplex:test_committed_store(Done),
        {ok, Entry} = quod_ledger_store:read_at(Store, 2),
        ?assertEqual(Hash, quod_simplex:block_hash(element(2, quod_ledger:block_from_entry(Entry)))),
        ?assertEqual(2, maps:get(last_applied, quod_simplex:stats_map(Done))),
        ?assertEqual(Mode, quod_simplex:test_sync(Done)),
        ?assertEqual({none, false, false}, quod_simplex:test_round(2, Done)),
        ?assertEqual(#{}, quod_signing_journal:rounds(quod_simplex:test_signing_journal(Done))),
        ok
    end) end) end).

paused_validation_does_not_authorize_fresh_votes_test_() ->
    [isolated(fun() -> without_signing(fun() -> with_fixture(fun(F, S0, Keys) ->
        {Block, Hash, WithCerts} = certified_first(F, S0, Keys, Kinds),
        Paused = quod_simplex:test_state_set(sync, {pulling, self()}, WithCerts),
        Proposed = quod_simplex:dispatch(leader(2, Keys), {propose, Block, []}, Paused),
        {Hash, Token, Owner} = take_request(2),
        Done = quod_simplex:test_on_dtx_verdict(2, Hash, Token, Owner, 1,
                                              {valid, #{}}, Proposed),
        ?assertEqual(1, element(1, quod_simplex:test_committed_store(Done))),
        ?assertMatch({none, false, _}, quod_simplex:test_round(2, Done)),
        ?assertEqual(#{}, quod_signing_journal:rounds(quod_simplex:test_signing_journal(Done))),
        ok
    end) end) end) || Kinds <- [[], [support]]].

nonparticipant_does_not_request_local_consensus_validation_test_() ->
    isolated(fun() -> with_fixture(fun(F, S0, Keys) ->
        {Outsider, _} = quod_identity:generate(),
        Observer = quod_simplex:test_state_set(self, Outsider, S0),
        {Block, _, WithCerts} = certified_first(F, Observer, Keys),
        Proposed = quod_simplex:dispatch(leader(2, Keys), {propose, Block, []}, WithCerts),
        ?assertEqual(1, element(1, quod_simplex:test_committed_store(Proposed))),
        assert_no_request()
    end) end).

certificates_never_substitute_for_a_valid_parent_verdict_test_() ->
    [isolated(fun() -> with_fixture(fun(F, S0, Keys) ->
        {Block, Hash, WithCerts} = certified_first(F, S0, Keys),
        Proposed = quod_simplex:dispatch(leader(2, Keys), {propose, Block, []}, WithCerts),
        {Hash, Token, Owner} = take_request(2),
        Done = quod_simplex:test_on_dtx_verdict(2, Hash, Token, Owner, 1, Verdict, Proposed),
        ?assertEqual(1, element(1, quod_simplex:test_committed_store(Done))),
        ?assertMatch({none, none, none, none, undefined}, quod_simplex:test_dtx_round(2, Done)),
        ?assertEqual({none, false, false}, quod_simplex:test_round(2, Done)),
        ok
    end) end) || Verdict <- [abstain, {invalid, refused}]].

missing_prolog_owner_never_uses_the_certificate_as_a_verdict_test_() ->
    isolated(fun() -> with_fixture(fun(F, S0, Keys) ->
        {Ns, _} = maps:get(origin, F),
        true = gproc:unreg(quod_reg:name({quod_prolog, Ns})),
        {Block, Hash, WithCerts} = certified_first(F, S0, Keys),
        Proposed = quod_simplex:dispatch(leader(2, Keys), {propose, Block, []}, WithCerts),
        ?assertMatch({none, none, {Hash, Block}, none, undefined}, quod_simplex:test_dtx_round(2, Proposed)),
        ?assertEqual(1, element(1, quod_simplex:test_committed_store(Proposed))),
        assert_no_request()
    end) end).

certified_first(F, S, Keys) ->
    certified_first(F, S, Keys, [support, commit]).

certified_first(F, S, Keys, Kinds) ->
    {Ns, Anchor} = maps:get(origin, F),
    Domain = quod_simplex:consensus_domain(Ns, Anchor),
    {ok, Blob} = quod_dtx:encode_control(maps:get(begin_control, F)),
    {ok, Block} = quod_ledger:new_block(2, 1, {batch, [{dtx, Blob}]}, quod_time:now_ms()),
    Hash = quod_simplex:block_hash(Block),
    Committee = lists:sort(maps:keys(Keys)),
    Certs = [begin
        Shares = [quod_simplex:make_share(Domain, Kind, 2, Hash, maps:get(P, Keys))
                  || P <- lists:sublist(Committee, 3)],
        {ok, Cert} = quod_simplex:form_cert(Domain, Kind, 2, Hash, Shares, Committee), Cert
    end || Kind <- Kinds],
    WithCerts = lists:foldl(fun(C, Acc) -> quod_simplex:dispatch(hd(Committee), {cert, C}, Acc) end, S, Certs),
    {Block, Hash, WithCerts}.

leader(Slot, Keys) -> quod_simplex:leader(Slot, lists:sort(maps:keys(Keys))).

take_request(Slot) ->
    receive {'$gen_cast', {dtx_verdict_req, [_], _, Slot, Owner,
                          {Slot, Hash, Token}, _}} -> {Hash, Token, Owner}
    after 0 -> error({parent_progress_not_delivered, Slot}) end.
assert_no_request() ->
    receive {'$gen_cast', {dtx_verdict_req, _, _, _, _, _, _}} -> error(duplicate_or_early_validation)
    after 0 -> ok end.

with_fixture(Fun) ->
    {ok, _} = application:ensure_all_started(gproc),
    Suffix = binary:encode_hex(crypto:strong_rand_bytes(8), lowercase),
    Ns = <<"quod:parent-progress-", Suffix/binary>>,
    Dir = filename:join("/tmp", "quod_parent_progress_" ++ binary_to_list(Suffix)),
    Keys = maps:from_list([begin
        {Pub, Seed} = quod_identity:generate(),
        {Pub, #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})}}
    end || _ <- lists:seq(1, 4)]),
    Committee = [Author | _] = lists:sort(maps:keys(Keys)),
    {ok, Genesis, Anchor} = quod_simplex:prepare_genesis(
        #{mode => create, committee => Committee, genesis_diff => []}, Ns, Author),
    Target = {Ns, Anchor}, Domain = quod_simplex:consensus_domain(Ns, Anchor),
    {ok, Projection} = quod_simplex:history_validate_advance(Target, Genesis, quod_simplex:history_projection(Target)),
    F = quod_ct:signed_dtx_begin_fixture(#{target => Target, node_identity => maps:get(Author, Keys),
            admission => maps:get(Author, maps:get(admissions, Projection))}),
    {ok, Journal} = quod_signing_journal:initialize(Ns, Domain, Dir),
    {ok, Store0} = quod_ledger_store:open(Ns, Dir),
    {ok, Store} = quod_ledger_store:append(Store0, [Genesis]),
    {ok, Index} = quod_dtx_phase_index:open(Dir, Ns),
    true = quod_reg:reg({quod_prolog, Ns}),
    try
        S = quod_simplex:test_install_projection(Projection,
            quod_simplex:test_state(#{ns => Ns, genesis_hash => Anchor, self => Author,
                id => maps:get(Author, Keys), consensus_domain => Domain,
                store => Store, signing_journal => Journal, phase_index => Index,
                slot => 1, last_applied => 1, sync => ready, prolog_ready => true,
                eng => quod_simplex:eng_new(Domain, Committee, 1)})),
        Fun(F, S, Keys)
    after
        catch gproc:unreg(quod_reg:name({quod_prolog, Ns})),
        quod_dtx_phase_index:close(Index),
        quod_ledger_store:close(Store),
        catch quod_signing_journal:close(Journal),
        file:del_dir_r(Dir)
    end.

isolated(Fun) -> {timeout, 30, {spawn, Fun}}.

without_signing(Fun) ->
    %% tprof owns a fresh worker: construct its file handles and correlated
    %% verdict request inside that same worker, never move a live owner state.
    {{ok, Owner}, {call_time, Counts}} = tprof:profile(fun() -> {Fun(), self()} end,
        #{type => call_time, report => return, set_on_spawn => false,
          pattern => [{quod_signing_journal, record_vote, 4},
                      {quod_signing_journal, record_support, 2}]}),
    ?assertEqual(0, lists:sum([N || {_, _, _, Ps} <- Counts,
                                  {Pid, N, _} <- Ps, Pid =:= Owner])).
