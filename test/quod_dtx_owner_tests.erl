-module(quod_dtx_owner_tests).
-include_lib("eunit/include/eunit.hrl").

retained_registry_has_one_implementation_test() ->
    Simplex = forms(quod_simplex), Owner = forms(quod_dtx_owner),
    ?assertEqual([], [N || {attribute, _, record, {N, _}} <- Simplex, N =:= retained_dtx]),
    ?assertEqual([retained_dtx], [N || {attribute, _, record, {N, _}} <- Owner, N =:= retained_dtx]),
    [Fields] = [Fs || {attribute, _, record, {s, Fs}} <- Simplex],
    ?assertNot(lists:member(dtx_pending, [field_name(F) || F <- Fields])),
    Deleted = [abandon_retained_dtx, seed_pending_begins, reconciled_pending_begins,
               reconcile_signing_journal, dtx_pending_after, reclassify_retained_rows,
               reclassify_retained_row, refresh_dtx_submission, retained_put_new,
               retained_take, retained_replace, pending_origin_begins, committed_origin_recoveries],
    ?assertEqual([], [F || {function, _, F, _, _} <- Simplex, lists:member(F, Deleted)]),
    ?assertEqual([], [N || {attribute, _, record, {N, _}} <- Owner, N =:= s]),
    ?assertNot(walk(fun
        ({'receive', _, _, _}) -> true;
        ({'receive', _, _, _, _}) -> true;
        ({'receive', _, _}) -> true;
        ({call, _, {atom, _, F}, _}) -> lists:member(F, [spawn, spawn_link, spawn_monitor, send_after]);
        ({call, _, {remote, _, {atom, _, quod_simplex}, _}, _}) -> true;
        (_) -> false
    end, Owner)).

foreign_history_never_carries_local_pending_custody_test() ->
    Identity = {<<"quod:owner-schema">>, <<31:256>>},
    P = quod_simplex:history_projection(Identity),
    ?assertNot(maps:is_key(dtx_pending, P)),
    ?assert(quod_foreign_log:valid_projection(P, Identity)),
    ?assertNot(quod_foreign_log:valid_projection(P#{dtx_pending => #{}}, Identity)),
    Compact = maps:remove(committee_views, P),
    ?assert(quod_foreign_log:valid_projection(Compact, Identity)),
    ?assertNot(quod_foreign_log:valid_projection(Compact#{dtx_pending => #{}}, Identity)).

old_foreign_cache_is_refused_by_name_without_mutation_test() ->
    isolated(fun() ->
        {ok, _} = application:ensure_all_started(gproc),
        process_flag(trap_exit, true),
        Root = filename:join("/tmp", "quod-owner-cache-" ++
                 binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8)))),
        Ns = <<"quod:owner-old-cache">>, Anchor = <<41:256>>, Identity = {Ns, Anchor},
        %% Exact .172 cache identity/manifest/checkpoint encoding, with a real
        %% V6 store. This is a format-admission control, not a history proof.
        CacheNs = crypto:hash(sha256, term_to_binary({quod_foreign_log, 3, Ns, Anchor}, [deterministic])),
        {ok, Store} = quod_ledger_store:open(CacheNs, Root, wrapped),
        ok = quod_ledger_store:close(Store),
        Dir = quod_ledger_store:ns_dir(Root, CacheNs),
        Projection = maps:remove(committee_views,
                       (quod_simplex:history_projection(Identity))#{dtx_pending => #{}}),
        Manifest = term_to_binary({quod_foreign_log_cache, 3, Ns, Anchor, CacheNs}, [deterministic]),
        Checkpoint = term_to_binary({quod_foreign_log_checkpoint, 3, Ns, Anchor, 0,
                         filelib:file_size(filename:join(Dir, "log.0001")), Projection}, [deterministic]),
        ok = file:write_file(filename:join(Dir, "identity.term"), Manifest),
        ok = file:write_file(filename:join(Dir, "checkpoint.term"), Checkpoint),
        {ok, Names} = file:list_dir(Dir),
        Before = [{Name, file:read_file(filename:join(Dir, Name))} || Name <- lists:sort(Names)],
        try
            case quod_foreign_log:start_link(#{cache_dir => Root}) of
                {error, {{unsupported_foreign_cache_format, 3}, _Stack}} -> ok;
                {ok, Owner} ->
                    unlink(Owner), gen_server:stop(Owner), error(old_cache_format_was_accepted);
                Other -> error({unexpected_format_refusal, Other})
            end,
            ?assertEqual(Before, [{Name, file:read_file(filename:join(Dir, Name))}
                                 || Name <- lists:sort(Names)])
        after ok = file:del_dir_r(Root)
        end
    end).

forms(Module) ->
    {ok, {Module, [{abstract_code, {raw_abstract_v1, Forms}}]}} =
        beam_lib:chunks(code:which(Module), [abstract_code]), Forms.
field_name({typed_record_field, F, _}) -> field_name(F);
field_name({record_field, _, {atom, _, N}, _}) -> N;
field_name({record_field, _, {atom, _, N}}) -> N.
walk(Pred, Term) ->
    Pred(Term) orelse case Term of
        T when is_tuple(T) -> lists:any(fun(X) -> walk(Pred, X) end, tuple_to_list(T));
        L when is_list(L) -> lists:any(fun(X) -> walk(Pred, X) end, L);
        _ -> false
    end.

%% Actual signed controls and durable journals. These fixtures exercise owner
%% transitions, not consensus admission; the certified-window tests cover it.
fresh_begin_survives_reconciliation_test_() ->
    [{atom_to_list(Mode), fun() -> isolated(fun() -> survives(Mode) end) end}
     || Mode <- [ready, unconfirmed, pulling, prolog_unready]].

survives(Mode) ->
    with_owner(fun(F, S0, Dir, Domain, Lane) ->
        Begin = maps:get('begin', F),
        %% Capture before this request exists, as a real recovery worker does.
        Captured = quod_simplex:test_state_projection(S0),
        {ok, Retained} = quod_simplex:test_retain_dtx_record(Begin, {dtx_endpoint, self()}, S0),
        Journal0 = quod_simplex:test_signing_journal(Retained),
        Pending = quod_signing_journal:pending_begins(Journal0),
        ?assertEqual(1, map_size(Pending)),
        Floor = quod_signing_journal:dtx_floor(Journal0, Lane),
        Installed = quod_simplex:test_install_projection(Captured, Retained),
        Paused = case Mode of
            ready -> Installed;
            prolog_unready -> quod_simplex:test_state_set(prolog_ready, false, Installed);
            pulling -> quod_simplex:test_state_set(sync, {pulling, self()}, Installed);
            unconfirmed -> quod_simplex:test_state_set(sync, unconfirmed, Installed)
        end,
        {After, none} = quod_simplex:test_reconcile_signing_state(Paused),
        {Again, none} = quod_simplex:test_reconcile_signing_state(After),
        ?assertEqual(quod_simplex:test_retained_dtx_state(Retained),
                     (quod_simplex:test_retained_dtx_state(Again))#{fingerprint := undefined}),
        Journal = quod_simplex:test_signing_journal(Again),
        ?assertEqual(Pending, quod_signing_journal:pending_begins(Journal)),
        ?assertEqual(Floor, quod_signing_journal:dtx_floor(Journal, Lane)),
        receive {dtx_submit_result, Reply} -> error({live_begin_retired, Reply}) after 0 -> ok end,
        ok = quod_signing_journal:close(Journal),
        {Ns, _} = maps:get(origin, F),
        {ok, Reopened} = quod_signing_journal:recover(Ns, Domain, Dir),
        try
            ?assertEqual(Pending, quod_signing_journal:pending_begins(Reopened)),
            ?assertEqual(Floor, quod_signing_journal:dtx_floor(Reopened, Lane))
        after ok = quod_signing_journal:close(Reopened)
        end
    end).

paused_consumed_sequence_preserves_exact_envelope_test_() ->
    [ {atom_to_list(Mode), fun() -> isolated(fun() ->
        with_owner(fun(F, S0, _Dir, _Domain, Lane) ->
            {ok, S1} = quod_simplex:test_retain_dtx_record(maps:get('begin', F), none, S0),
            Journal = quod_simplex:test_signing_journal(S1),
            Pending = quod_signing_journal:pending_begins(Journal),
            Floor = quod_signing_journal:dtx_floor(Journal, Lane),
            Consumed = quod_simplex:test_state_set(dtx_lanes, #{Lane => Floor}, S1),
            Paused = case Mode of
                prolog_unready -> quod_simplex:test_state_set(prolog_ready, false, Consumed);
                unconfirmed -> quod_simplex:test_state_set(sync, unconfirmed, Consumed)
            end,
            {After, none} = quod_simplex:test_reconcile_signing_state(Paused),
            ?assertEqual(Pending, quod_signing_journal:pending_begins(
                                  quod_simplex:test_signing_journal(After))),
            ?assertEqual(Floor, quod_signing_journal:dtx_floor(
                                  quod_simplex:test_signing_journal(After), Lane)),
            ?assertEqual(1, maps:get(retained, quod_simplex:test_retained_dtx_state(After)))
        end)
    end) end} || Mode <- [unconfirmed, prolog_unready] ].

with_owner(Fun) ->
    {ok, _} = application:ensure_all_started(gproc),
    F = quod_ct:dtx_prepare_fixture(),
    {Ns, Anchor} = maps:get(origin, F),
    {ok, {group, Ns, Anchor, Pub, Admission, _}} = quod_dtx:begin_group_ref(maps:get('begin', F)),
    Domain = quod_simplex:consensus_domain(Ns, Anchor),
    Dir = filename:join("/tmp", "quod-owner-" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8)))),
    {ok, Index} = quod_dtx_phase_index:open(Dir, Ns),
    {ok, Journal} = quod_signing_journal:initialize(Ns, Domain, Dir),
    true = quod_reg:reg({quod_prolog, Ns}),
    try
        S = quod_simplex:test_state(#{ns => Ns, genesis_hash => Anchor, self => Pub,
              id => maps:get(signer, F), validators => [Pub],
              author_admissions => #{Pub => Admission}, sync => ready, prolog_ready => true,
              consensus_domain => Domain, slot => 1, phase_index => Index, signing_journal => Journal}),
        Fun(F, S, Dir, Domain, {Admission, Pub})
    after
        _ = catch quod_signing_journal:close(Journal),
        ok = quod_dtx_phase_index:close(Index),
        true = gproc:unreg(quod_reg:name({quod_prolog, Ns})),
        ok = file:del_dir_r(Dir)
    end.

isolated(Fun) ->
    Caller = self(), Ref = make_ref(),
    {Pid, Monitor} = spawn_monitor(fun() ->
        Result = try Fun(), ok catch C:R:S -> {raise, C, R, S} end,
        Caller ! {Ref, Result}
    end),
    receive {Ref, Result} ->
        receive {'DOWN', Monitor, process, Pid, normal} -> ok end,
        case Result of ok -> ok; {raise, C, R, S} -> erlang:raise(C, R, S) end
    end.
