-module(quod_receiver_decode_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").
-include("quod_proof_limits.hrl").

%% Signed byte-ingress tests, not consensus-admission or current-view fixtures.
%% Those authorities still run after this call-local decoding boundary.
page_preserves_occurrences_while_authenticating_once_test() ->
    {Tx, _Signer, _Binding} = signed(),
    B = entry_bytes(Tx, 2),
    {{ok, Entries}, 1} = counted(fun() -> decode_entries([B, B, B], wrapped) end),
    ?assertEqual([B, B, B], [entry_bytes(E) || E <- Entries]).

nested_claim_application_completion_share_one_decode_test() ->
    F = quod_ct:remote_operation_fixture(#{}),
    Identity = maps:get(node_identity, F),
    {Ns, Anchor} = maps:get(origin, F),
    {ok, Complete} = quod_transaction:sign(
      {Ns, Anchor, maps:get(admission, F)},
      (maps:get(completion, F))#transaction{author = maps:get(pubkey, Identity),
                                           author_seq = 2, submitted_at = 2}, Identity),
    Blobs = [entry_bytes(maps:get(claim, F), 2),
             entry_bytes(maps:get(application, F), 3), entry_bytes(Complete, 4)],
    %% Four checks for the one-target claim, plus each enclosing author.
    {{ok, Entries}, 6} = counted(fun() -> decode_entries(Blobs, wrapped) end),
    ?assertEqual(Blobs, [entry_bytes(E) || E <- Entries]).

different_pages_do_not_share_authentication_test() ->
    {Tx, _, _} = signed(), B = entry_bytes(Tx, 2),
    {ok, 3} = counted(fun() ->
        [{ok, [_]} = decode_entries([B], wrapped) || _ <- lists:seq(1, 3)], ok
    end).

compact_head_selection_authenticates_the_record_not_finality_test() ->
    {Tx, _, _} = signed(), Bytes = entry_bytes(Tx, 2),
    %% The shape-only head grants no finality. Selecting the application still
    %% checks its signature; archive ancestry is verified at consumption.
    {{ok, Selected}, 1} = counted(fun() ->
        quod_ledger:select_entry(Bytes, {application, Tx#transaction.tx_id}, wrapped)
    end),
    ?assertEqual(Tx#transaction.tx_id,
                 (quod_ledger:selected_record(Selected))#transaction.tx_id).

same_semantic_id_different_envelopes_are_not_reused_test() ->
    {Tx, Signer, Binding} = signed(),
    {ok, Other} = quod_transaction:sign(Binding,
      Tx#transaction{author_seq = 2, sig = none, signed_bytes = none,
                     authentication = none}, Signer),
    ?assertEqual(Tx#transaction.tx_id, Other#transaction.tx_id),
    ?assertNotEqual(tx_bytes(Tx), tx_bytes(Other)),
    Blobs = [entry_bytes(Tx, 2), entry_bytes(Other, 3)],
    {{ok, Entries}, 2} = counted(fun() -> decode_entries(Blobs, wrapped) end),
    ?assertEqual(Blobs, [entry_bytes(E) || E <- Entries]).

changed_signature_cannot_borrow_a_completed_record_test() ->
    {Tx, _, _} = signed(), B = tx_bytes(Tx),
    {ok, _, Context} = quod_transaction:decode_ledger_transaction(B, wrapped,
                                      quod_transaction:decode_context()),
    ?assertMatch({error, _}, quod_transaction:decode_ledger_transaction(
                              bad_signature(B), wrapped, Context)).

resigned_outer_envelope_does_not_hide_bad_nested_signature_test() ->
    F = quod_ct:remote_operation_fixture(#{}),
    ClaimBytes = tx_bytes(maps:get(claim, F)),
    {ok, _, Context} = quod_transaction:decode_ledger_transaction(
                        ClaimBytes, wrapped, quod_transaction:decode_context()),
    Bad = replace_evidence(maps:get(application, F),
             {certified_transaction, maps:get(certified_claim_ref, F),
              bad_signature(ClaimBytes)}, maps:get(node_identity, F)),
    ?assertEqual({error, malformed_material},
                 quod_transaction:decode_ledger_transaction(Bad, wrapped, Context)).

enclosing_references_are_checked_even_when_nested_record_is_reused_test() ->
    F = quod_ct:remote_operation_fixture(#{}), Claim = maps:get(claim, F),
    ClaimBytes = tx_bytes(Claim),
    {ok, _, Context} = quod_transaction:decode_ledger_transaction(
                        ClaimBytes, wrapped, quod_transaction:decode_context()),
    {Ns, Anchor} = maps:get(origin, F),
    {ok, WrongIdentity} = quod_dtx:certified_ref(
                           Ns, <<88:256>>, 2, <<213:256>>, Claim#transaction.tx_id, quod_ct:fixture_finality(1, <<213:256>>)),
    {ok, WrongTransaction} = quod_dtx:certified_ref(
                              Ns, Anchor, 2, <<213:256>>, <<89:256>>, quod_ct:fixture_finality(1, <<213:256>>)),
    Wires = [replace_evidence(maps:get(application, F),
                {certified_transaction, Ref, ClaimBytes}, maps:get(node_identity, F))
             || Ref <- [WrongIdentity, WrongTransaction]],
    %% Each valid outer signature is checked; neither enclosing binding may
    %% borrow a verdict from the identical, already-authenticated inner claim.
    {ok, 2} = counted(fun() ->
        [?assertEqual({error, malformed_material},
             quod_transaction:decode_ledger_transaction(Wire, wrapped, Context)) || Wire <- Wires], ok
    end),
    ?assertMatch({ok, _, _}, quod_transaction:decode_ledger_transaction(
                              tx_bytes(maps:get(application, F)), wrapped, Context)).

symbol_modes_do_not_share_materialized_records_test() ->
    Name = <<"receiver_unknown_", (binary:encode_hex(crypto:strong_rand_bytes(8)))/binary>>,
    Symbol = {'$quod_symbol', Name},
    {Tx, _, _} = signed(Symbol), B = tx_bytes(Tx),
    ?assertError(badarg, binary_to_existing_atom(Name, utf8)),
    {ok, 2} = counted(fun() ->
        {ok, Wrapped, Context} = quod_transaction:decode_ledger_transaction(
                                  B, wrapped, quod_transaction:decode_context()),
        ?assertEqual([{assert, {{Symbol, 1}, true}}], Wrapped#transaction.diff),
        ?assertError(badarg, binary_to_existing_atom(Name, utf8)),
        {ok, Materialized, _} = quod_transaction:decode_ledger_transaction(B, materialized, Context),
        Atom = binary_to_existing_atom(Name, utf8),
        ?assertEqual([{assert, {{Atom, 1}, true}}], Materialized#transaction.diff),
        ?assertEqual(B, tx_bytes(Materialized)), ok
    end).

context_has_no_wire_form_or_public_map_seed_test() ->
    {Tx, _, _} = signed(), B = tx_bytes(Tx),
    {ok, _, Context} = quod_transaction:decode_ledger_transaction(
                        B, wrapped, quod_transaction:decode_context()),
    ?assertMatch({error, _}, quod_transaction:decode_ledger_transaction(
                              B, wrapped, #{{B, wrapped} => Tx})),
    [?assertMatch({error, _}, quod_transaction:decode_ledger_transaction(
                               canonical(Native), wrapped)) || Native <- [Context, Tx]],
    ?assertEqual({error, bad_frame}, decode_entries([canonical(Context)], wrapped)).

failed_page_does_not_publish_or_retain_a_partial_context_test() ->
    {Tx, _, _} = signed(), B = entry_bytes(Tx, 2),
    {ok, 2} = counted(fun() ->
        ?assertEqual({error, bad_frame}, decode_entries([B, <<0>>], wrapped)),
        ?assertMatch({ok, [_, _]}, decode_entries([B, B], wrapped)), ok
    end).

page_count_limit_still_precedes_decoding_test() ->
    {Tx, _, _} = signed(), Count = ?QUOD_MAX_FOREIGN_PAGE_ENTRIES,
    Parts = [{entry, entry_bytes(Tx, I)} || I <- lists:seq(2, Count + 1)],
    ?assert(lists:sum([byte_size(B) || {entry, B} <- Parts]) =< ?QUOD_MAX_FOREIGN_PAGE_BYTES),
    F = quod_ct:protocol_fixture(<<"receiver:limit">>),
    Path = filename:join("/tmp", "quod-receiver-limit-" ++
        binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8)))),
    quod_ledger_store:with_proof_stage(Path, fun(Stage) ->
        {ok, Transfer} = quod_catchup:transfer_begin(maps:get(identity, F), Count + 2,
            maps:get(projection, F), none, wrapped, Stage),
        {{more, _}, 1} = counted(fun() -> quod_catchup:transfer_accept(Transfer, Parts, more) end),
        {{error, malformed_transfer_page}, 0} = counted(fun() ->
            quod_catchup:transfer_accept(Transfer, [hd(Parts) | Parts], more)
        end)
    end).

reused_claim_does_not_cache_request_validity_test() ->
    F = quod_ct:remote_operation_fixture(#{}), B = tx_bytes(maps:get(claim, F)),
    {ok, Claim, Context} = quod_transaction:decode_ledger_transaction(
                            B, wrapped, quod_transaction:decode_context()),
    {{ok, Claim, Context}, 0} = counted(fun() ->
        quod_transaction:decode_ledger_transaction(B, wrapped, Context)
    end),
    {agent_goal_v1, _, RequestBytes, _} = Claim#transaction.request_auth,
    {ok, #{not_after_ms := Expiry}} = quod_client_goal:decode(RequestBytes),
    Origin = maps:get(origin, F), Network = maps:get(network, F),
    ?assertMatch({ok, _}, quod_transaction:validate_request(Network, Origin, Expiry, Claim)),
    ?assertEqual({error, expired}, quod_transaction:validate_request(Network, Origin, Expiry+1, Claim)),
    ?assertEqual({error, wrong_network}, quod_transaction:validate_request(<<0:256>>, Origin, Expiry, Claim)),
    ?assertEqual({error, invalid_request_binding}, quod_transaction:validate_request(
                      Network, {element(1, Origin), <<0:256>>}, Expiry, Claim)).

reused_record_does_not_validate_another_certificate_or_admission_test() ->
    quod_operation_fixture:with(2, fun(F) ->
        Target = maps:get(target, F),
        B = entry_bytes(maps:get(entry, F)),
        {quod_entry, 2, I, Block, Cert} = binary_to_term(B, [safe]),
        Author = (maps:get(application, F))#transaction.author,
        BadBytes = canonical({quod_entry, 2, I, Block, setelement(6, Cert, [{Author, <<0:512>>}])}),
        %% The second entry shares the transaction, not the first entry's
        %% certificate or historical-authority verdict.
        {ok, [Good, Bad]} = decode_entries([B, BadBytes], wrapped),
        Projection = maps:get(projection, F),
        ?assertEqual(ok, quod_ct:verify_finality(Target, Good, Projection)),
        ?assertEqual({error, {bad_cert, 2}}, quod_ct:verify_finality(Target, Bad, Projection)),
        ?assertEqual({error, {invalid_transaction, 2}}, quod_simplex:history_validate_advance(
            Target, Good, Projection#{admissions := #{Author => <<0:256>>}}))
    end).

%% Drive the actual codec's call-local context. Transport admission/count
%% checks are exercised separately above through transfer_accept/3.
decode_entries(Blobs, Mode) ->
    decode_entries(Blobs, Mode, quod_transaction:decode_context(), []).
decode_entries([], _Mode, _Context, Entries) -> {ok, lists:reverse(Entries)};
decode_entries([B | Rest], Mode, Context, Entries) ->
    case quod_ledger:decode_entry(B, Mode, Context) of
        {ok, Entry, Next} -> decode_entries(Rest, Mode, Next, [Entry | Entries]);
        {error, _} -> {error, bad_frame}
    end.

signed() -> signed(receiver_value).
signed(Symbol) ->
    {Pub, Seed} = quod_identity:generate(),
    Signer = #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})},
    Target = {<<"receiver:test">>, <<91:256>>}, Binding = {element(1, Target), element(2, Target), <<92:256>>},
    {ok, Goal} = quod_durable_term:encode_goal(true),
    {ok, Result} = quod_durable_term:encode_result(#{}),
    Tx = quod_transaction:bind_id(Target,
      #transaction{origin = Target, proof_id = <<93:256>>, plan_digest = <<94:256>>,
        goal = Goal, result = Result, diff = [{assert, {{Symbol, 1}, true}}],
        read_check = #{}, author = Pub, author_seq = 1, submitted_at = 1}),
    {ok, Signed} = quod_transaction:sign(Binding, Tx, Signer),
    {Signed, Signer, Binding}.

entry_bytes(Tx, Slot) ->
    entry_bytes(quod_ct:committed_entry(<<"receiver:test">>, Slot, {batch, [Tx]})).
entry_bytes(E) -> {ok, B} = quod_ledger:encode_entry(E), B.
tx_bytes(Tx) -> {ok, B} = quod_transaction:encode_ledger_transaction(Tx), B.
canonical(Term) -> term_to_binary(Term, [deterministic]).
bad_signature(Bytes) ->
    {submit, Author, <<First, Rest/binary>>, Canonical} = binary_to_term(Bytes, [safe]),
    canonical({submit, Author, <<(First bxor 1), Rest/binary>>, Canonical}).
replace_evidence(Tx, Evidence, Signer) ->
    %% Re-sign malformed inner material so rejection cannot be attributed to
    %% a bad outer signature. Only the production decoder decides validity.
    Canonical = canonical(setelement(15, binary_to_term(Tx#transaction.signed_bytes, [safe]), Evidence)),
    canonical({submit, Tx#transaction.author, quod_identity:sign(Canonical, Signer), Canonical}).

counted(Fun) ->
    {module, crypto} = code:ensure_loaded(crypto),
    Parent = self(),
    {Worker, Monitor} = spawn_monitor(fun() ->
        receive run -> Parent ! {result, self(), Fun()}, receive stop -> ok end end
    end),
    try
        1 = erlang:trace_pattern({crypto, verify, 5}, true, [local]),
        1 = erlang:trace(Worker, true, [call, {tracer, self()}]), Worker ! run,
        Result = receive
            {result, Worker, R} -> R;
            {'DOWN', Monitor, process, Worker, Why} -> error({decode_worker, Why})
        after 3000 -> error(decode_timeout) end,
        Barrier = erlang:trace_delivered(Worker),
        {Result, count(Worker, Barrier, 0)}
    after
        erlang:trace_pattern({crypto, verify, 5}, false, [local]),
        exit(Worker, kill), demonitor(Monitor, [flush])
    end.
count(Worker, Barrier, N) ->
    receive
        {trace, Worker, call, {crypto, verify, _}} -> count(Worker, Barrier, N+1);
        {trace_delivered, Worker, Barrier} -> N
    after 3000 -> error(trace_flush_timeout) end.
