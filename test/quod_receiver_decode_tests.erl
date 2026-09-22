-module(quod_receiver_decode_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").
-include("quod_proof_limits.hrl").

%% Signed byte-ingress tests, not consensus-admission or current-view fixtures.
%% Those authorities still run after this call-local decoding boundary.
page_preserves_occurrences_while_authenticating_once_test() ->
    {Tx, _Signer, _Binding} = signed(),
    B = entry_bytes(Tx, 2),
    {{ok, Entries}, 1} = counted(fun() -> quod_catchup:decode_entries([B, B, B], wrapped) end),
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
    {{ok, Entries}, 6} = counted(fun() -> quod_catchup:decode_entries(Blobs, wrapped) end),
    ?assertEqual(Blobs, [entry_bytes(E) || E <- Entries]).

different_pages_do_not_share_authentication_test() ->
    {Tx, _, _} = signed(), B = entry_bytes(Tx, 2),
    {ok, 3} = counted(fun() ->
        [{ok, [_]} = quod_catchup:decode_entries([B], wrapped) || _ <- lists:seq(1, 3)], ok
    end).

implicit_child_and_selected_parent_share_decode_not_finality_test() ->
    {Tx, _, _} = signed(),
    {quod_entry, 1, 2, Parent, none} = binary_to_term(entry_bytes(Tx, 2), [safe]),
    {quod_entry, 1, 3, Child, none} = binary_to_term(entry_bytes(Tx, 3), [safe]),
    %% This is a byte-decoder fixture, not a valid consensus certificate.
    %% The same envelope in the implicit child must not be decoded twice
    %% when the selected parent item is subsequently materialized.
    Bytes = canonical({quod_entry, 1, 2, Parent, {implicit, none, Child, none}}),
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
    {{ok, Entries}, 2} = counted(fun() -> quod_catchup:decode_entries(Blobs, wrapped) end),
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
                           Ns, <<88:256>>, 2, <<213:256>>, Claim#transaction.tx_id, <<"qc">>),
    {ok, WrongTransaction} = quod_dtx:certified_ref(
                              Ns, Anchor, 2, <<213:256>>, <<89:256>>, <<"qc">>),
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
    ?assertEqual({error, bad_frame}, quod_catchup:decode_entries([canonical(Context)], wrapped)).

failed_page_does_not_publish_or_retain_a_partial_context_test() ->
    {Tx, _, _} = signed(), B = entry_bytes(Tx, 2),
    {ok, 2} = counted(fun() ->
        ?assertEqual({error, bad_frame}, quod_catchup:decode_entries([B, <<0>>], wrapped)),
        ?assertMatch({ok, [_, _]}, quod_catchup:decode_entries([B, B], wrapped)), ok
    end).

page_count_limit_still_precedes_decoding_test() ->
    {Tx, _, _} = signed(), B = entry_bytes(Tx, 2),
    Blobs = lists:duplicate(?QUOD_MAX_FOREIGN_PAGE_ENTRIES, B),
    %% Ordinary small signed entries fit the byte bound at the count limit.
    ?assert(lists:sum([byte_size(X) || X <- Blobs]) =< ?QUOD_MAX_FOREIGN_PAGE_BYTES),
    {{ok, Entries}, 1} = counted(fun() -> quod_catchup:decode_entries(Blobs, wrapped) end),
    ?assertEqual(length(Blobs), length(Entries)),
    {{error, bad_frame}, 0} = counted(fun() -> quod_catchup:decode_entries([B | Blobs], wrapped) end).

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
        Target = {Ns, Anchor} = maps:get(target, F),
        B = entry_bytes(maps:get(entry, F)),
        {quod_entry, 1, I, Block, Cert} = binary_to_term(B, [safe]),
        Author = (maps:get(application, F))#transaction.author,
        BadBytes = canonical({quod_entry, 1, I, Block, Cert#cert{sigs = [{Author, <<0:512>>}]}}),
        %% The second entry shares the transaction, not the first entry's
        %% certificate or historical-authority verdict.
        {ok, [Good, Bad]} = quod_catchup:decode_entries([B, BadBytes], wrapped),
        Projection = maps:get(projection, F),
        ?assertMatch({ok, [_], _}, quod_catchup:verify_forward(Ns, Anchor, Projection, 2, [Good])),
        ?assertEqual({error, {bad_cert, 2}}, quod_catchup:verify_forward(Ns, Anchor, Projection, 2, [Bad])),
        ?assertEqual({error, {invalid_transaction, 2}}, quod_simplex:history_validate_advance(
            Target, Good, Projection#{admissions := #{Author => <<0:256>>}}))
    end).

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
    {ok, E} = quod_ledger:new_entry(Slot, {batch, [Tx]}, 1, none), entry_bytes(E).
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
