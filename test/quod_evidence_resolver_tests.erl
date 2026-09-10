-module(quod_evidence_resolver_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

%% Resolver-only sidecar for contract A. No coordinator dependency injection:
%% every result below comes from real signed bytes and the production verifier.
%% The registered source implements the existing private history_view protocol,
%% just as the foreign-log/current-view fixtures do; it is not a consensus node.
%% Run sequentially: these tests own the VM's foreign-log registration and
%% temporary call-trace patterns. Gates acknowledge real queue/custody edges;
%% sleeps only cross an already captured absolute deadline. They do not model
%% transport delivery, endpoint readiness, or shared-caller expiry isolation.
%% Unknown-vocabulary/atom-count gates remain in the ledger-artifact, catchup,
%% DTX-endpoint, transaction, safe-term, and current-view test modules.

current_era_hit_has_one_committed_capture_and_zero_foreign_work_test() ->
    F = fixture(),
    with_case(F, current, fun(C) ->
        D = deadline(3000),
        ?assertMatch({ok, #{phase := finalize}}, resolve(C, maps:get(ref, F), finalize, D)),
        ?assertEqual([{identity(F), committed, D}], captures(C)),
        T = traces(),
        ?assertEqual(1, calls(T, quod_simplex, history_view, 3)),
        ?assertEqual(1, calls(T, quod_foreign_log, verify_resident_local_reference, 4)),
        ?assertEqual(1, calls(T, quod_ledger_store, open_ro_snapshot, 1)),
        ?assertEqual(1, calls(T, quod_ledger_store, read_at, 2)),
        assert_no_foreign_work(T),
        assert_no_fetch()
    end).

malformed_requests_are_refused_before_owner_work_test() ->
    F = fixture(),
    Ref = maps:get(ref, F),
    with_case(F, current, fun(C) ->
        WrongTarget = {maps:get(ns, F), digest(wrong_expected_anchor)},
        Cases = [{identity(F), malformed, finalize},
                 {WrongTarget, Ref, finalize},
                 {identity(F), setelement(3, Ref, <<"wrong:namespace">>), finalize},
                 {identity(F), setelement(4, Ref, digest(wrong_ref_anchor)), finalize},
                 {identity(F), Ref, unknown_phase},
                 {malformed, Ref, finalize}],
        lists:foreach(fun({Target, R, Phase}) ->
            ?assertEqual({error, bad_foreign_reference},
                         resolve(C#{target := Target}, R, Phase, deadline(3000)))
        end, Cases),
        ?assertEqual({error, bad_foreign_reference},
                     resolve(C#{contact := maps:get(pub, F)}, Ref, finalize, deadline(3000))),
        ?assertEqual([], captures(C)),
        T = traces(),
        ?assertEqual(0, calls(T, quod_simplex, history_view, 3)),
        ?assertEqual(0, calls(T, quod_foreign_log, verification_call, 2)),
        assert_no_foreign_work(T),
        assert_no_fetch()
    end).

wrong_target_refusal_has_a_real_routed_primitive_control_test() ->
    F = fixture(),
    Other = quod_foreign_log_tests:foreign_fixture(maps:get(ns, F)),
    Ref = maps:get(ref, F),
    ?assertNotEqual(identity(F), identity(Other)),
    with_case(F, current, fun(C) ->
        %% The old route-only primitive lacks an expected-target argument and
        %% really authenticates these bytes. Rejection below cannot pass just
        %% because the reference is forged or its source is unreachable.
        {ok, Evidence} = result(traced_async(fun() ->
            quod_foreign_log:verify_reference(Ref, finalize, maps:get(contact, C), none, 3000)
        end)),
        ?assertEqual(identity(F), maps:get(identity, Evidence)),
        Positive = traces(),
        ?assertEqual(1, calls(Positive, quod_foreign_log, start_distinct_routed_worker, 5)),
        ?assertEqual(1, calls(Positive, quod_foreign_log, spawn_verification_worker, 3)),
        flush_fetches(),
        ?assertEqual({error, bad_foreign_reference},
                     resolve(C#{target := identity(Other)}, Ref, finalize, deadline(3000))),
        ?assertEqual([], captures(C)),
        Negative = traces(),
        ?assertEqual(0, calls(Negative, quod_simplex, history_view, 3)),
        ?assertEqual(0, calls(Negative, quod_foreign_log, verification_call, 2)),
        assert_no_foreign_work(Negative),
        assert_no_fetch()
    end).

unavailable_local_copy_routes_once_test_() ->
    [{atom_to_list(Mode), fun() -> unavailable_local_copy_routes_once(Mode) end}
     || Mode <- [none, lagging, replaced_incarnation, capture_unavailable]].

unavailable_local_copy_routes_once(Mode) ->
    F = fixture(),
    with_case(F, Mode, fun(C) ->
        D = deadline(3000),
        Ref = maps:get(ref, F),
        Hint = lists:last(maps:get(chain, F)),
        ?assertMatch({ok, #{phase := finalize}},
                     resolve(C#{hint := Hint}, Ref, finalize, D)),
        T = traces(),
        ?assertEqual(1, calls(T, quod_simplex, history_view, 3)),
        ?assertEqual(0, calls(T, quod_foreign_log, verify_resident_local_reference, 4)),
        assert_one_routed(T, C, Ref, finalize, Hint, D),
        %% Cold routed work positively controls full-open and forward-fold
        %% tracing. Persisted-cache replay has its own restart control below.
        ?assert(calls(T, quod_foreign_log, open_cache, 6) > 0),
        ?assert(calls(T, quod_catchup, verify_forward, 6) > 0),
        ?assert(calls(T, quod_ledger_store, open, 3) > 0),
        receive {resolver_fetch, _, _} -> ok
        after 0 -> error(routed_positive_control_did_not_fetch)
        end,
        case Mode of
            none -> ok;
            _ -> ?assertEqual([{identity(F), committed, D}], captures(C))
        end
    end).

persisted_cache_restart_is_a_positive_replay_trace_control_test() ->
    F = fixture(),
    with_case(F, none, fun(C) ->
        Ref = maps:get(ref, F),
        ?assertMatch({ok, _}, resolve(C, Ref, finalize, deadline(3000))),
        _ = traces(),
        flush_fetches(),
        quod_foreign_log_tests:stop_owner(maps:get(foreign, C)),
        New = quod_foreign_log_tests:start_owner(maps:get(cache_dir, C), maps:get(fetch, C)),
        try
            start_trace(New),
            ?assertMatch({ok, _}, resolve(C#{foreign := New}, Ref, finalize, deadline(3000))),
            T = traces(),
            ?assert(calls(T, quod_foreign_log, replay_cache, 7) > 0),
            ?assert(calls(T, quod_ledger_store, open, 3) > 0),
            ?assertEqual(1, calls(T, quod_foreign_log, spawn_verification_worker, 3)),
            assert_no_fetch()
        after
            stop_trace(New),
            quod_foreign_log_tests:stop_owner(New)
        end
    end).

capture_owner_death_before_a_usable_view_routes_once_test() ->
    F = fixture(),
    with_case(F, hold_capture, fun(C) ->
        D = deadline(3000),
        Ref = maps:get(ref, F),
        Caller = resolve_async(C, Ref, finalize, D),
        Source = source_pid(C),
        receive {resolver_capture_held, Source, D} -> ok
        after 1000 -> error(capture_not_held)
        end,
        try
            stop_source(maps:get(source, C)),
            ?assertMatch({ok, #{phase := finalize}}, result(Caller)),
            T = traces(),
            ?assertEqual(1, calls(T, quod_simplex, history_view, 3)),
            assert_one_routed(T, C, Ref, finalize, none, D)
        after
            exit(Caller, kill)
        end
    end).

sufficient_invalid_local_evidence_never_falls_back_test() ->
    F = fixture(),
    Ref = maps:get(ref, F),
    Cert = binary_to_term(element(8, Ref), [safe]),
    [{Pub, _}] = Cert#cert.sigs,
    BadSig = setelement(8, Ref, term_to_binary(Cert#cert{sigs = [{Pub, <<0:512>>}]})),
    Cases = [{setelement(6, Ref, digest(changed_hash)), finalize, invalid_foreign_reference},
             {setelement(7, Ref, digest(changed_record)), finalize, invalid_foreign_reference},
             {setelement(8, Ref, <<"malformed-finality">>), finalize, invalid_foreign_reference},
             {BadSig, finalize, invalid_foreign_reference},
             {Ref, decision, phase_mismatch}],
    with_case(F, current, fun(C) ->
        lists:foreach(fun({R, Phase, Error}) ->
            ?assertEqual({error, Error}, resolve(C, R, Phase, deadline(3000)))
        end, Cases),
        T = traces(),
        ?assertEqual(length(Cases), calls(T, quod_simplex, history_view, 3)),
        assert_no_foreign_work(T),
        assert_no_fetch()
    end).

current_era_accepts_distinct_valid_quorum_subsets_test() ->
    F = committee_fixture(false),
    Ref = maps:get(ref, F),
    Members = maps:get(members, F),
    Other = reference_with_signers(F, Ref, tl(Members)),
    ?assertNotEqual(element(8, Ref), element(8, Other)),
    ?assert(quod_dtx:same_certified_ref(Ref, Other)),
    with_case(F, current, fun(C) ->
        {ok, A} = resolve(C, Ref, transaction, deadline(3000)),
        {ok, B} = resolve(C, Other, transaction, deadline(3000)),
        ?assertEqual(A, B),
        ?assertEqual(5, length(maps:get(committee, A))),
        %% This certificate really verifies under a different committee, but
        %% cannot authenticate an equal claim against this resident era.
        Outsiders = new_members(4),
        WrongEra = reference_with_signers(F, Ref, lists:sublist(Outsiders, 3)),
        assert_cert_valid_for(F, WrongEra, Outsiders),
        ?assertEqual({error, invalid_foreign_reference},
                     resolve(C, WrongEra, transaction, deadline(3000))),
        assert_no_foreign_work(traces()),
        assert_no_fetch()
    end).

historical_era_keeps_its_committee_and_checks_supplied_proofs_test() ->
    F = committee_fixture(true),
    Ref = maps:get(ref, F),
    Members = maps:get(members, F),
    OldKeys = [K || {K, _} <- Members],
    NewMembers = lists:sublist(Members, 4),
    WrongEra = reference_with_signers(F, Ref, lists:sublist(NewMembers, 3)),
    assert_cert_valid_for(F, WrongEra, NewMembers),
    Cert = binary_to_term(element(8, Ref), [safe]),
    [{Pub, _} | Rest] = Cert#cert.sigs,
    BadSig = setelement(8, Ref, term_to_binary(Cert#cert{sigs = [{Pub, <<0:512>>} | Rest]})),
    Alternate = reference_with_signers(F, Ref, tl(Members)),
    with_case(F, current, fun(C) ->
        {ok, A} = resolve(C, Ref, transaction, deadline(3000)),
        ?assertEqual(OldKeys, maps:get(committee, A)),
        {ok, B} = resolve(C, Alternate, transaction, deadline(3000)),
        ?assertEqual(A, B),
        lists:foreach(fun(R) ->
            ?assert(quod_dtx:same_certified_ref(Ref, R)),
            ?assertEqual({error, invalid_foreign_reference},
                         resolve(C, R, transaction, deadline(3000)))
        end, [WrongEra, BadSig, setelement(8, Ref, <<"malformed-finality">>)]),
        T = traces(),
        ?assertEqual(5, calls(T, quod_simplex, history_view, 3)),
        ?assertEqual(5, calls(T, quod_foreign_log, spawn_verification_worker, 3)),
        ?assertEqual(0, calls(T, quod_foreign_log, start_distinct_routed_worker, 5)),
        assert_no_fetch()
    end).

pinned_owner_loss_never_recaptures_or_routes_test_() ->
    [{atom_to_list(Stage), fun() -> pinned_owner_loss(Stage) end}
     || Stage <- [before_verification, after_verification]].

pinned_owner_loss(Stage) ->
    F = historical_fixture(),
    with_case(F, current, fun(C) ->
        Owner = maps:get(foreign, C),
        case Stage of after_verification -> warm_historical_cache(C); _ -> ok end,
        {Caller, Worker, Request, Token} = held_historical_call(C, deadline(3000)),
        try
            case Stage of
                before_verification -> ok;
                after_verification ->
                    ok = sys:suspend(Owner),
                    Worker ! {release_local_worker, Token},
                    wait_completion(Owner, Request)
            end,
            ?assertEqual(1, length(captures(C))),
            stop_source(maps:get(source, C)),
            ReplacementDir = temp_dir("replacement"),
            Replacement = start_source(ReplacementDir, F, current),
            try
                case Stage of
                    before_verification -> Worker ! {release_local_worker, Token};
                    after_verification -> ok = sys:resume(Owner)
                end,
                ?assertEqual({error, retry}, result(Caller)),
                ?assertEqual([], source_captures(Replacement)),
                T = traces(),
                ?assertEqual(1, calls(T, quod_simplex, history_view, 3)),
                ?assertEqual(1, calls(T, quod_foreign_log, spawn_verification_worker, 3)),
                ?assertEqual(0, calls(T, quod_foreign_log, start_distinct_routed_worker, 5)),
                assert_no_fetch()
            after
                stop_source(Replacement),
                _ = file:del_dir_r(ReplacementDir)
            end
        after
            _ = catch sys:resume(Owner),
            exit(Caller, kill),
            exit(Worker, kill)
        end
    end).

expired_or_invalid_deadline_never_starts_capture_test() ->
    F = fixture(),
    with_case(F, current, fun(C) ->
        ?assertEqual({error, retry}, resolve(C, maps:get(ref, F), finalize, deadline(-1))),
        lists:foreach(fun(D) ->
            ?assertEqual({error, bad_foreign_reference}, resolve(C, maps:get(ref, F), finalize, D))
        end, [infinity, 1.5, invalid]),
        ?assertEqual([], captures(C)),
        T = traces(),
        ?assertEqual(0, calls(T, quod_simplex, history_view, 3)),
        assert_no_foreign_work(T)
    end).

queued_capture_cannot_launch_after_expiry_test() ->
    F = fixture(),
    with_case(F, hold_capture, fun(C) ->
        D = deadline(400),
        Caller = resolve_async(C, maps:get(ref, F), finalize, D),
        Source = source_pid(C),
        receive {resolver_capture_held, Source, D} -> ok
        after 1000 -> error(capture_not_held)
        end,
        try
            wait_expired(D),
            Source ! release_capture,
            ?assertEqual({error, retry}, result(Caller)),
            ?assertEqual([{identity(F), committed, D}], captures(C)),
            T = traces(),
            ?assertEqual(1, calls(T, quod_simplex, history_view, 3)),
            ?assertEqual(0, calls(T, quod_foreign_log, verify_resident_local_reference, 4)),
            assert_no_foreign_work(T),
            assert_no_fetch()
        after
            Source ! release_capture,
            exit(Caller, kill)
        end
    end).

queued_admission_preserves_capture_deadline_test_() ->
    [{atom_to_list(Kind), fun() -> queued_admission_preserves_capture_deadline(Kind) end}
     || Kind <- [routed, historical_local]].

queued_admission_preserves_capture_deadline(Kind) ->
    {F, Mode, RequestKind} = case Kind of
        routed -> {fixture(), held_unavailable, verify_reference};
        historical_local -> {historical_fixture(), hold_capture, verify_local}
    end,
    with_case(F, Mode, fun(C) ->
        Owner = maps:get(foreign, C),
        Source = source_pid(C),
        D = deadline(600),
        Caller = resolve_async(C, maps:get(ref, F), finalize, D),
        receive {resolver_capture_held, Source, D} -> ok
        after 1000 -> error(capture_not_held)
        end,
        try
            ok = sys:suspend(Owner),
            Source ! release_capture,
            Envelope = wait_message(Owner, fun
                ({'$gen_call', _, {verification, _, _, _, Request}}) -> element(1, Request) =:= RequestKind;
                (_) -> false
            end),
            {'$gen_call', _, {verification, ActualDeadline, _, _, _}} = Envelope,
            ?assertEqual(D, ActualDeadline),
            ?assert(D > quod_time:mono_ms()),
            wait_expired(D),
            ok = sys:resume(Owner),
            ?assertEqual({error, retry}, result(Caller)),
            ?assertEqual([{identity(F), committed, D}], captures(C)),
            T = traces(),
            ?assertEqual(1, calls(T, quod_foreign_log, verification_call, 2)),
            assert_no_foreign_work(T),
            assert_no_fetch()
        after
            Source ! release_capture,
            _ = catch sys:resume(Owner),
            exit(Caller, kill)
        end
    end).

queued_verified_success_cannot_publish_after_expiry_test() ->
    F = historical_fixture(),
    with_case(F, current, fun(C) ->
        Owner = maps:get(foreign, C),
        warm_historical_cache(C),
        D = deadline(1000),
        {Caller, Worker, Request, Token} = held_historical_call(C, D),
        try
            ok = sys:suspend(Owner),
            Worker ! {release_local_worker, Token},
            wait_completion(Owner, Request),
            ?assert(D > quod_time:mono_ms()),
            wait_expired(D),
            ok = sys:resume(Owner),
            ?assertEqual({error, retry}, result(Caller)),
            ?assertEqual([{identity(F), committed, D}], captures(C)),
            T = traces(),
            ?assertEqual(1, calls(T, quod_foreign_log, spawn_verification_worker, 3)),
            ?assertEqual(0, calls(T, quod_foreign_log, start_distinct_routed_worker, 5)),
            assert_no_fetch()
        after
            _ = catch sys:resume(Owner),
            exit(Caller, kill),
            exit(Worker, kill)
        end
    end).

append_after_capture_preserves_the_borrowed_prefix_test() ->
    Full = historical_fixture(),
    Chain = maps:get(chain, Full),
    F = Full#{chain := lists:sublist(Chain, 2)},
    with_case(F, {append_before_reply, [lists:last(Chain)]}, fun(C) ->
        ?assertMatch({ok, #{phase := finalize, slot := 2}},
                     resolve(C, maps:get(ref, F), finalize, deadline(3000))),
        ?assertEqual(3, gen_server:call(source_pid(C), height)),
        T = traces(),
        ?assertEqual(1, calls(T, quod_simplex, history_view, 3)),
        ?assertEqual(1, calls(T, quod_ledger_store, open_ro_snapshot, 1)),
        assert_no_foreign_work(T),
        assert_no_fetch()
    end).

%% Serving-API adapter coverage only. The fixture below is NOT a running
%% Simplex readiness endpoint: readiness/applied-state and reference-worker
%% result handling are tested separately by their owners.
local_serving_uses_any_capture_and_unchanged_absolute_deadline_test() ->
    F = fixture(),
    Ref = maps:get(ref, F),
    with_case(F, current, fun(C) ->
        D = deadline(3000),
        ?assertMatch({ok, #{phase := finalize}},
                     local_evidence(C, maps:get(ns, F), Ref, finalize, D)),
        ?assertEqual([{identity(F), any, D}], captures(C)),
        T = traces(),
        LocalCalls = [Args || {trace, _, call, {quod_foreign_log, verify_local_deadline, Args}} <- T],
        ?assertMatch([[#{owner := _, identity := _, snapshot := _}, Ref, finalize, D]], LocalCalls),
        [[View, _, _, _]] = LocalCalls,
        ?assertEqual(identity(F), maps:get(identity, View)),
        ?assertEqual(source_pid(C), maps:get(owner, View)),
        ?assertEqual(1, calls(T, quod_simplex, history_view, 3)),
        ?assertEqual(1, calls(T, quod_ledger_store, read_at, 2)),
        assert_no_foreign_work(T),
        assert_no_fetch()
    end).

local_serving_expiry_is_not_ready_without_routed_fallback_test_() ->
    [{atom_to_list(Stage), fun() -> local_serving_expiry(Stage) end}
     || Stage <- [already_expired, queued_capture]].

local_serving_expiry(Stage) ->
    F = fixture(),
    with_case(F, hold_capture, fun(C) ->
        D = case Stage of already_expired -> deadline(-1); queued_capture -> deadline(400) end,
        Source = source_pid(C),
        Caller = local_evidence_async(maps:get(ns, F), maps:get(ref, F), finalize, D),
        try
            case Stage of
                already_expired -> ok;
                queued_capture ->
                    receive {resolver_capture_held, Source, D} -> ok
                    after 1000 -> error(capture_not_held)
                    end,
                    wait_expired(D),
                    Source ! release_capture
            end,
            ?assertEqual({error, not_ready}, result(Caller)),
            ExpectedCaptures = case Stage of
                already_expired -> [];
                queued_capture -> [{identity(F), any, D}]
            end,
            ?assertEqual(ExpectedCaptures, captures(C)),
            T = traces(),
            ?assertEqual(0, calls(T, quod_foreign_log, verify_local_deadline, 4)),
            assert_no_foreign_work(T),
            assert_no_fetch()
        after
            Source ! release_capture,
            exit(Caller, kill)
        end
    end).

local_serving_unavailable_copy_never_routes_test_() ->
    [{atom_to_list(Mode), fun() -> local_serving_unavailable_copy(Mode, Error) end}
     || {Mode, Error} <- [{lagging, not_found}, {none, not_ready},
                          {replaced_incarnation, invalid_request}]].

local_serving_unavailable_copy(Mode, Error) ->
    F = fixture(),
    with_case(F, Mode, fun(C) ->
        D = deadline(3000),
        ?assertEqual({error, Error},
                     local_evidence(C, maps:get(ns, F), maps:get(ref, F), finalize, D)),
        case Mode of
            none -> ok;
            _ -> ?assertEqual([{identity(F), any, D}], captures(C))
        end,
        T = traces(),
        ?assertEqual(0, calls(T, quod_foreign_log, verify_local_deadline, 4)),
        assert_no_foreign_work(T),
        assert_no_fetch()
    end).

local_serving_wrong_expected_namespace_is_invalid_before_capture_test() ->
    F = fixture(),
    with_case(F, current, fun(C) ->
        ?assertEqual({error, invalid_request},
                     local_evidence(C, <<"wrong:serving:namespace">>, maps:get(ref, F), finalize, deadline(3000))),
        ?assertEqual([], captures(C)),
        T = traces(),
        ?assertEqual(0, calls(T, quod_simplex, history_view, 3)),
        ?assertEqual(0, calls(T, quod_foreign_log, verify_local_deadline, 4)),
        assert_no_foreign_work(T),
        assert_no_fetch()
    end).

%% Harness: reuse the foreign-log suite's signed genesis/control fixtures,
%% verified projection constructor, real fetch bytes, and real foreign owner.
fixture() -> quod_foreign_log_tests:foreign_fixture(quod_foreign_log_tests:unique_ns()).
historical_fixture() ->
    quod_foreign_log_tests:membership_after_finalize_fixture(quod_foreign_log_tests:unique_ns()).
identity(F) -> {maps:get(ns, F), maps:get(anchor, F)}.
deadline(Ms) -> quod_time:mono_ms() + Ms.
digest(Term) -> crypto:hash(sha256, term_to_binary({resolver_test, Term})).
temp_dir(Label) -> quod_foreign_log_tests:temp_dir("resolver-" ++ Label).

with_case(F, Mode, Fun) ->
    {ok, _} = application:ensure_all_started(gproc),
    CacheDir = temp_dir("cache"),
    SourceDir = temp_dir("source"),
    Parent = self(),
    Fetch0 = quod_foreign_log_tests:chain_fetch(maps:get(ns, F), maps:get(chain, F)),
    Fetch = fun(Peer, Endpoint, Ns, From, To) ->
        Parent ! {resolver_fetch, From, To},
        Fetch0(Peer, Endpoint, Ns, From, To)
    end,
    Owner = quod_foreign_log_tests:start_owner(CacheDir, Fetch),
    Source = case Mode of
        none -> none;
        lagging -> start_source(SourceDir, F#{chain := [hd(maps:get(chain, F))]}, current);
        replaced_incarnation ->
            start_source(SourceDir, quod_foreign_log_tests:foreign_fixture(maps:get(ns, F)), current);
        _ -> start_source(SourceDir, F, Mode)
    end,
    C = #{fixture => F, target => identity(F), foreign => Owner, source => Source,
          contact => {maps:get(pub, F), {"127.0.0.1", 19000}}, hint => none,
          cache_dir => CacheDir, fetch => Fetch},
    try
        start_trace(Owner),
        Fun(C)
    after
        stop_trace(Owner),
        stop_source(Source),
        quod_foreign_log_tests:stop_owner(Owner),
        _ = file:del_dir_r(SourceDir),
        _ = file:del_dir_r(CacheDir),
        flush_fetches()
    end.

start_source(Dir, F, Mode) ->
    Parent = self(),
    {Pid, Monitor} = spawn_monitor(fun() ->
        {ok, Store0} = quod_ledger_store:open(maps:get(ns, F), Dir),
        {ok, Store} = quod_ledger_store:append(Store0, maps:get(chain, F)),
        FullView = quod_foreign_log_tests:local_fixture_view(Store, F),
        Projection = maps:get(projection, FullView),
        [Current | _] = maps:get(committee_views, Projection),
        %% Applied=0 deliberately proves this is a committed-history borrow,
        %% not an execution-readiness requirement. Keep only the real live era.
        View = FullView#{applied := 0, projection := Projection#{committee_views := [Current]}},
        Parent ! {resolver_source_ready, self()},
        source_loop(Store, View, Mode, Parent, [])
    end),
    receive
        {resolver_source_ready, Pid} -> {Pid, Monitor};
        {'DOWN', Monitor, process, Pid, Reason} -> error({source_failed, Reason})
    after 3000 -> exit(Pid, kill), error(source_start_timeout)
    end.

source_loop(Store, View, Mode, Parent, Captures) ->
    receive
        {'$gen_call', From, {history_view, Target, Requirement, D}} ->
            Captures1 = [{Target, Requirement, D} | Captures],
            case Mode of
                hold_capture -> hold_capture(Parent, D);
                held_unavailable -> hold_capture(Parent, D);
                _ -> ok
            end,
            {Store1, View1} = case Mode of
                {append_before_reply, Entries} ->
                    {ok, Appended} = quod_ledger_store:append(Store, Entries),
                    {Ns, _} = maps:get(identity, View),
                    Projection = lists:foldl(fun(E, P) -> quod_simplex:history_advance(Ns, E, P) end,
                                             maps:get(projection, View), Entries),
                    {Appended, View#{slot := quod_ledger_store:last(Appended),
                                     snapshot := quod_ledger_store:snapshot(Appended),
                                     projection := Projection}};
                _ -> {Store, View}
            end,
            Reply = case {Target =:= maps:get(identity, View), Requirement,
                          Mode, D > quod_time:mono_ms()} of
                {_, _, _, false} -> {error, timeout};
                {false, _, _, true} -> {error, invalid_identity};
                {true, _, capture_unavailable, true} -> {error, not_ready};
                {true, _, held_unavailable, true} -> {error, not_ready};
                {true, R, _, true} when R =:= committed; R =:= any -> {ok, View};
                _ -> {error, not_ready}
            end,
            gen:reply(From, Reply),
            source_loop(Store1, View1, current, Parent, Captures1);
        {'$gen_call', From, captures} ->
            gen:reply(From, lists:reverse(Captures)),
            source_loop(Store, View, Mode, Parent, Captures);
        {'$gen_call', From, height} ->
            gen:reply(From, quod_ledger_store:last(Store)),
            source_loop(Store, View, Mode, Parent, Captures);
        {'$gen_call', From, view} ->
            gen:reply(From, View),
            source_loop(Store, View, Mode, Parent, Captures);
        stop -> quod_ledger_store:close(Store)
    end.

hold_capture(Parent, D) ->
    Parent ! {resolver_capture_held, self(), D},
    receive release_capture -> ok end.

source_pid(C) -> element(1, maps:get(source, C)).
captures(C) -> source_captures(maps:get(source, C)).
source_captures({Pid, _}) -> gen_server:call(Pid, captures).

stop_source(none) -> ok;
stop_source({Pid, Monitor}) ->
    case is_process_alive(Pid) of
        true ->
            exit(Pid, kill),
            receive {'DOWN', Monitor, process, Pid, _} -> ok
            after 2000 -> error(source_stop_timeout)
            end;
        false -> erlang:demonitor(Monitor, [flush]), ok
    end.

resolve(C, Ref, Phase, D) -> result(resolve_async(C, Ref, Phase, D)).
resolve_async(C, Ref, Phase, D) ->
    traced_async(fun() ->
        quod_foreign_log:resolve_reference(maps:get(target, C), Ref, Phase,
                                           maps:get(contact, C), maps:get(hint, C), D)
    end).

local_evidence(_C, Ns, Ref, Phase, D) -> result(local_evidence_async(Ns, Ref, Phase, D)).
local_evidence_async(Ns, Ref, Phase, D) ->
    traced_async(fun() -> quod_simplex:dtx_local_evidence(Ns, Ref, Phase, D) end).

traced_async(Fun) ->
    Parent = self(),
    Caller = spawn(fun() ->
        receive go -> ok end,
        try Fun() of
            Result -> Parent ! {resolver_result, self(), Result}
        catch Class:Reason:Stack ->
            Parent ! {resolver_exception, self(), Class, Reason, Stack}
        end
    end),
    1 = erlang:trace(Caller, true, [call, set_on_spawn, {tracer, self()}]),
    Caller ! go,
    Caller.

result(Caller) ->
    receive
        {resolver_result, Caller, Result} -> Result;
        {resolver_exception, Caller, Class, Reason, Stack} -> erlang:raise(Class, Reason, Stack)
    after 4000 -> exit(Caller, kill), error(resolver_result_timeout)
    end.

warm_historical_cache(C) ->
    %% First populate it through the real historical verifier. A subsequent
    %% held reader can finish with the owner suspended: cold append would need
    %% reserve_page/set_cache_size admission before reaching publication.
    View = gen_server:call(source_pid(C), view),
    ?assertMatch({ok, #{phase := finalize}},
                 quod_foreign_log:verify_local(View, maps:get(ref, maps:get(fixture, C)), finalize, 3000)),
    _ = traces(),
    ok.

held_historical_call(C, D) ->
    Token = make_ref(),
    ok = gen_server:call(maps:get(foreign, C), {test_hold_next_local_worker, self(), Token}),
    Caller = resolve_async(C, maps:get(ref, maps:get(fixture, C)), finalize, D),
    receive {local_worker_held, Token, Request, Worker} -> {Caller, Worker, Request, Token}
    after 2000 -> exit(Caller, kill), error(historical_worker_not_held)
    end.

wait_completion(Owner, Request) ->
    _ = wait_message(Owner, fun
        ({foreign_worker_done, R, {ok, _}, _}) when R =:= Request -> true;
        (_) -> false
    end),
    ok.

wait_message(Pid, Predicate) -> wait_message(Pid, Predicate, deadline(2000)).
wait_message(Pid, Predicate, D) ->
    {messages, Messages} = process_info(Pid, messages),
    case lists:filter(Predicate, Messages) of
        [Message | _] -> Message;
        [] ->
            case D > quod_time:mono_ms() of
                true -> receive after 2 -> ok end, wait_message(Pid, Predicate, D);
                false -> error(expected_owner_message_not_queued)
            end
    end.

wait_expired(D) -> receive after max(0, D - quod_time:mono_ms()) + 20 -> ok end.

trace_patterns() ->
    [{quod_simplex, history_view, 3},
     {quod_foreign_log, verification_call, 2},
     {quod_foreign_log, verify_local_deadline, 4},
     {quod_foreign_log, verify_resident_local_reference, 4},
     {quod_foreign_log, start_distinct_routed_worker, 5},
     {quod_foreign_log, spawn_verification_worker, 3},
     {quod_foreign_log, open_cache, 6},
     {quod_foreign_log, replay_cache, 7},
     {quod_catchup, verify_forward, 6},
     {quod_ledger_store, open, 3},
     {quod_ledger_store, open_ro, 3},
     {quod_ledger_store, open_ro_snapshot, 1},
     {quod_ledger_store, read_at, 2}].

start_trace(Owner) ->
    lists:foreach(fun({M, _, _} = MFA) ->
        {module, M} = code:ensure_loaded(M),
        1 = erlang:trace_pattern(MFA, true, [local])
    end, trace_patterns()),
    1 = erlang:trace(Owner, true, [call, set_on_spawn, {tracer, self()}]).

stop_trace(Owner) ->
    _ = catch erlang:trace(Owner, false, [call, set_on_spawn]),
    lists:foreach(fun(MFA) -> erlang:trace_pattern(MFA, false, [local]) end, trace_patterns()),
    _ = traces(),
    ok.

traces() ->
    Barrier = erlang:trace_delivered(all),
    receive {trace_delivered, all, Barrier} -> ok
    after 2000 -> error(trace_barrier_timeout)
    end,
    collect_traces([]).
collect_traces(Acc) ->
    receive {trace, _, call, _} = T -> collect_traces([T | Acc])
    after 0 -> lists:reverse(Acc)
    end.
calls(T, M, F, A) -> length([ok || {trace, _, call, {TM, TF, Args}} <- T,
                                                TM =:= M, TF =:= F, length(Args) =:= A]).

assert_no_foreign_work(T) ->
    lists:foreach(fun({M, F, A}) -> ?assertEqual(0, calls(T, M, F, A)) end,
                  [{quod_foreign_log, start_distinct_routed_worker, 5},
                   {quod_foreign_log, spawn_verification_worker, 3},
                   {quod_foreign_log, open_cache, 6},
                   {quod_foreign_log, replay_cache, 7},
                   {quod_catchup, verify_forward, 6},
                   {quod_ledger_store, open, 3},
                   {quod_ledger_store, open_ro, 3}]).

assert_one_routed(T, C, Ref, Phase, Hint, D) ->
    ?assertEqual(1, calls(T, quod_foreign_log, start_distinct_routed_worker, 5)),
    ?assertEqual(1, calls(T, quod_foreign_log, spawn_verification_worker, 3)),
    Requests = [{R, Deadline} || {trace, _, call, {quod_foreign_log, verification_call, [R, Deadline]}} <- T],
    ?assertMatch([{{verify_reference, Ref, Phase, _, Hint, _}, D}], Requests),
    [{{verify_reference, _, _, Contact, _, _}, _}] = Requests,
    ?assertEqual(maps:get(contact, C), Contact).

assert_no_fetch() -> receive {resolver_fetch, _, _} -> error(unexpected_network_fetch) after 0 -> ok end.
flush_fetches() -> receive {resolver_fetch, _, _} -> flush_fetches() after 0 -> ok end.

%% Five real members allow distinct 4-of-5 certificates. The optional signed
%% removal changes the live era to four members; a new-era 3-of-4 proof must
%% never authenticate the older slot. This follows the existing shrink fixture.
committee_fixture(RemoveMember) ->
    Ns = quod_foreign_log_tests:unique_ns(),
    Members = new_members(5),
    [{Author, Signer} | _] = Members,
    Keys = [K || {K, _} <- Members],
    GenesisTx = quod_simplex:test_genesis_tx(#{committee => tl(Keys), node_addr => {"127.0.0.1", 19000}},
                                              Ns, Author, digest(genesis_incarnation)),
    {ok, Genesis} = quod_ledger:new_entry(1, {batch, [GenesisTx]}, 0, none),
    {ok, Block} = quod_ledger:block_from_entry(Genesis),
    Anchor = quod_simplex:block_hash(Block),
    Identity = {Ns, Anchor},
    {ok, [Genesis], P} = quod_catchup:verify_forward(Ns, Anchor, quod_simplex:history_projection(Identity), 1, [Genesis]),
    {ok, Binding} = quod_simplex:history_binding(Identity, Author, P),
    Tx = signed_transaction(Identity, Binding, Author, Signer, 1,
                            [{assert, {{resolver_fact, true}, true}}]),
    Entry = committee_entry(Identity, Members, 2, Tx),
    {ok, Ref} = quod_dtx:certified_entry_ref(Identity, Entry, Tx),
    Tail = case RemoveMember of
        false -> [];
        true ->
            Removed = lists:last(Keys),
            Removal = signed_transaction(Identity, Binding, Author, Signer, 2,
                                         [{retract, {{peer_admitted, Removed, undefined, undefined, Removed}, true}}]),
            [committee_entry(Identity, Members, 3, Removal)]
    end,
    #{ns => Ns, anchor => Anchor, pub => Author, members => Members,
      ref => Ref, chain => [Genesis, Entry | Tail]}.

new_members(N) ->
    lists:sort([begin
        {Pub, Seed} = quod_identity:generate(),
        {Pub, #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})}}
    end || _ <- lists:seq(1, N)]).

signed_transaction(Identity, Binding, Author, Signer, Seq, Diff) ->
    {ok, Goal} = quod_durable_term:encode_goal({resolver_transaction, Seq}),
    {ok, Result} = quod_durable_term:encode_result(#{}),
    Tx0 = #transaction{origin = Identity, proof_id = digest({proof, Seq}),
                       plan_digest = digest({plan, Seq}), goal = Goal, result = Result,
                       diff = Diff, read_check = #{}, author = Author,
                       author_seq = Seq, submitted_at = Seq, sig = none},
    {ok, Tx} = quod_transaction:sign(Binding, quod_transaction:bind_id(Identity, Tx0), Signer),
    Tx.

committee_entry({Ns, Anchor}, Members, Slot, Tx) ->
    {ok, Block} = quod_ledger:new_block(Slot, Slot - 1, {batch, [Tx]}, 0),
    Hash = quod_simplex:block_hash(Block),
    Domain = quod_simplex:consensus_domain(Ns, Anchor),
    Sigs = [{Pub, (quod_simplex:make_share(Domain, commit, Slot, Hash, Signer))#share.sig}
            || {Pub, Signer} <- lists:sublist(Members, 4)],
    quod_ledger:entry(Block, #cert{kind = commit, slot = Slot, block_hash = Hash, sigs = Sigs}).

reference_with_signers(F, Ref, Signers) ->
    Slot = element(5, Ref),
    Hash = element(6, Ref),
    Domain = quod_simplex:consensus_domain(maps:get(ns, F), maps:get(anchor, F)),
    Sigs = [{Pub, (quod_simplex:make_share(Domain, commit, Slot, Hash, Signer))#share.sig}
            || {Pub, Signer} <- Signers],
    setelement(8, Ref, term_to_binary(#cert{kind = commit, slot = Slot, block_hash = Hash, sigs = Sigs}, [deterministic])).

assert_cert_valid_for(F, Ref, Members) ->
    Domain = quod_simplex:consensus_domain(maps:get(ns, F), maps:get(anchor, F)),
    ?assert(quod_simplex:verify_cert(Domain, binary_to_term(element(8, Ref), [safe]),
                                    [K || {K, _} <- Members])).
