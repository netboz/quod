-module(quod_read_set_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("quod_ledger.hrl").
-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([reconnect_mixed_symbols/1, reconnect_missing_route/1,
         reconnect_route_recovery/1, application_reference/2,
         resolve_application/2]).

all() -> [reconnect_mixed_symbols, reconnect_missing_route, reconnect_route_recovery].

%% Each case owns a fresh three-node fixture. No route is removed or shared
%% with another case, and standalone/combined execution has identical setup.
init_per_testcase(Case, Config) ->
    Dir = filename:join(?config(priv_dir, Config), atom_to_list(Case)),
    ok = file:make_dir(Dir),
    quod_ask_SUITE:init_per_suite(lists:keystore(priv_dir, 1, Config, {priv_dir, Dir})).
end_per_testcase(_Case, Config) -> quod_ask_SUITE:end_per_suite(Config).

reconnect_mixed_symbols(Config) ->
    F = committed_request(Config),
    install_target_route(Config),
    verify_reconnect(Config, F).

reconnect_missing_route(Config) ->
    F = committed_request(Config),
    assert_no_route(Config),
    ?assertEqual({error, retry}, resolve_evidence(Config, F)),
    ?assertMatch({ok, _, {operation_pending, _}}, reconnect(Config, F)),
    assert_target_fact(Config, F).

reconnect_route_recovery(Config) ->
    F = committed_request(Config),
    assert_no_route(Config),
    ?assertEqual({error, retry}, resolve_evidence(Config, F)),
    install_target_route(Config),
    %% Only evidence discovery is retried. The request/signature/claim and
    %% application identity are unchanged; there is no second submission.
    verify_reconnect(Config, F).

committed_request(Config) ->
    Third = ?config(third, Config),
    Name = <<"a_readset_reconnect_", (binary:encode_hex(crypto:strong_rand_bytes(12)))/binary>>,
    Symbol = peer:call(Third, erlang, binary_to_atom, [Name, utf8]),
    ?assertMatch({ok, [_], _}, peer:call(Third, quod_prolog, prove,
      [<<"third">>, {assertz, {Symbol, exists}}], 60000)),
    Tag = erlang:unique_integer([positive]),
    Goal = iolist_to_binary(["third::(", Name, "(exists), assertz(readset_committed(",
                            integer_to_binary(Tag), ")))."]),
    Session = ?config(client_session, Config),
    Request = quod_ct:signed_goal_fixture(#{
      target => {<<"pets">>, ?config(asker_anchor, Config)},
      network => ?config(network_id, Config), key_pair => ?config(agent_key, Config),
      operation_id => crypto:strong_rand_bytes(32), goal_text => Goal,
      deadline => min(maps:get(expires_ms, Session), quod_time:now_ms() + 30000)}),
    Bytes = maps:get(request_bytes, Request), Signature = maps:get(signature, Request),
    {ok, Evidence, {normalized, {committed, [_], Ref}}} = peer:call(
      ?config(asker, Config), quod_client_goal_ingress, submit,
      [execute, maps:get(session_id, Session), Bytes, Signature, ?config(client_peer, Config)], 60000),
    {transaction, <<"third">>, _, TxId} = Ref,
    {Certified, TxBytes, Names} = peer:call(Third, ?MODULE, application_reference,
                                         [<<"third">>, TxId]),
    ?assert(lists:member({Name, 1}, Names)),
    ?assert(lists:member({<<"can_invoke">>, 4}, Names)),
    F = #{request => Request, evidence => Evidence, ref => Ref, certified => Certified,
          tx_bytes => TxBytes, name => Name, tag => Tag, session => gateway_session(Config)},
    assert_unknown(Config, F),
    F.

verify_reconnect(Config, F) ->
    %% The .174 client uses current-view outcomes, whereas S8 additionally
    %% requires exact historical application evidence. Exercise that shared
    %% production reconnect seam here without importing S8's AM3/vector API.
    ?assertEqual({ok, maps:get(tx_bytes, F)}, resolve_evidence(Config, F)),
    ?assertMatch({ok, _, {operation_outcome, _, #{status := committed}}}, reconnect(Config, F)),
    assert_unknown(Config, F),
    assert_target_fact(Config, F).

resolve_evidence(Config, F) ->
    peer:call(?config(target, Config), ?MODULE, resolve_application,
      [{<<"third">>, ?config(third_anchor, Config)}, maps:get(certified, F)], 10000).

resolve_application(Target, Ref) ->
    case quod_foreign_log:resolve_reference(Target, Ref, transaction, none, none,
                                            quod_time:mono_ms() + 5000) of
        {ok, #{transaction := Tx}} -> quod_transaction:encode_ledger_transaction(Tx);
        {error, _} = Error -> Error
    end.

reconnect(Config, F) ->
    Request = maps:get(request, F),
    peer:call(?config(target, Config), quod_client_goal_ingress, resolve_operation,
      [maps:get(session_id, maps:get(session, F)), maps:get(request_bytes, Request),
       maps:get(signature, Request), ?config(client_peer, Config)], 15000).

assert_target_fact(Config, F) ->
    Third = ?config(third, Config),
    {transaction, _, _, TxId} = maps:get(ref, F),
    ?assertMatch([_], peer:call(Third, quod_ask_SUITE, claim_application_occurrences,
                               [<<"third">>, TxId])),
    ?assertMatch({ok, [_], _}, peer:call(Third, quod_prolog, prove,
      [<<"third">>, {readset_committed, maps:get(tag, F)}], 10000)).

assert_unknown(Config, F) ->
    Name = maps:get(name, F),
    ?assertEqual({ok, {'$quod_symbol', Name}}, peer:call(?config(target, Config),
                 quod_wire_term, decode, [{0, Name}])).

assert_no_route(Config) ->
    ?assertEqual({error, unavailable}, peer:call(?config(target, Config),
      quod_foreign_log, route_hints, [{<<"third">>, ?config(third_anchor, Config)}, []])).

install_target_route(Config) ->
    {ok, _} = peer:call(?config(target, Config), quod_ct, install_directory_generation,
      [?config(third_pub, Config), ?config(third_addr, Config),
       [{<<"third">>, ?config(third_anchor, Config), validator}], 1, 1]),
    ?assertMatch({ok, [_ | _]}, peer:call(?config(target, Config), quod_foreign_log,
      route_hints, [{<<"third">>, ?config(third_anchor, Config)}, []])).

application_reference(Ns, TxId) ->
    {ok, #{snapshot := Snapshot, slot := Height, identity := Identity}} =
        quod_simplex:history_view(Ns, any, quod_time:mono_ms() + 5000),
    {ok, Store} = quod_ledger_store:open_ro_snapshot(Snapshot),
    try
        [Result] = quod_ledger_store:fold(Store, 1, Height, fun(Entry, Acc) ->
            case quod_ledger:entry_view(Entry) of
                #entry{data = {batch, Transactions}} ->
                    lists:foldl(fun(#transaction{tx_id = Id} = Tx, A) when Id =:= TxId ->
                        {ok, Ref} = quod_dtx:certified_entry_ref(Identity, Entry, Tx),
                        {ok, Bytes} = quod_transaction:encode_ledger_transaction(Tx),
                        Names = [{atom_to_binary(Name, utf8), Arity}
                                 || {Name, Arity} <- maps:keys(Tx#transaction.read_check)],
                        [{Ref, Bytes, Names} | A]; (_, A) -> A end, Acc, Transactions);
                _ -> Acc
            end
        end, []),
        Result
    after quod_ledger_store:close(Store)
    end.

gateway_session(Config) ->
    Gateway = ?config(target, Config), KeyPair = ?config(agent_key, Config),
    {Pub, _} = KeyPair, Nonce = crypto:strong_rand_bytes(32),
    {ok, C} = peer:call(Gateway, quod_client_auth, issue_challenge,
                       [Pub, Nonce, ?config(client_peer, Config)]),
    Id = maps:get(challenge_id, C),
    {ok, Bytes} = quod_client_auth:challenge_bytes(?config(network_id, Config),
      ?config(target_pub, Config), Id, Pub, Nonce, maps:get(server_nonce, C), maps:get(expires_ms, C)),
    Sig = quod_identity:sign(Bytes, quod_identity:key_term(KeyPair)),
    {ok, Session} = peer:call(Gateway, quod_client_auth, complete_challenge, [Id, Sig]),
    Session.
