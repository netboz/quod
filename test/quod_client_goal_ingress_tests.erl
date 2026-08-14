-module(quod_client_goal_ingress_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

-define(NETWORK, <<16#71:256>>).
-define(ANCHOR, <<16#72:256>>).
-define(PEER, {127, 0, 0, 1}).

signed_local_read_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     fun(Ctx) ->
         [?_test(local_read_uses_user_acl_and_returns_named_bindings(Ctx)),
          ?_test(forged_request_never_materializes_its_functor(Ctx)),
          ?_test(read_mode_cannot_write_or_open_a_foreign_scope(Ctx)),
          ?_test(same_ontology_scope_keeps_the_user_principal(Ctx)),
          ?_test(opaque_data_binding_renders_as_the_original_symbol(Ctx)),
          ?_test(anchor_is_checked_at_ingress_and_inside_the_worker(Ctx)),
          ?_test(session_and_signed_deadline_are_both_bound(Ctx))]
     end}.

local_read_uses_user_acl_and_returns_named_bindings(
  #{namespace := Ns, key_pair := KeyPair,
    session := Session}) ->
    {Bytes, Signature} = signed_read(
                           Ns, ?ANCHOR, KeyPair, Session,
                           <<"lookup(X).">>),
    {ok, #{variables := [{<<"X">>, 0}]},
     {ok, [#{0 := bob}], 1}} =
        quod_client_goal_ingress:read(
          maps:get(session_id, Session), Bytes, Signature, ?PEER).

forged_request_never_materializes_its_functor(
  #{namespace := Ns, key_pair := KeyPair,
    session := Session}) ->
    Functor = unique_symbol(<<"forged_signed_goal_">>),
    ?assertError(badarg, binary_to_existing_atom(Functor, utf8)),
    Text = <<Functor/binary, ".">>,
    {Bytes, _Signature} = signed_read(Ns, ?ANCHOR, KeyPair, Session, Text),
    ?assertEqual(
       {error, invalid_signature},
       quod_client_goal_ingress:read(
         maps:get(session_id, Session), Bytes, <<0:512>>, ?PEER)),
    ?assertError(badarg, binary_to_existing_atom(Functor, utf8)).

read_mode_cannot_write_or_open_a_foreign_scope(
  #{namespace := Ns, key_pair := KeyPair,
    session := Session}) ->
    SessionId = maps:get(session_id, Session),
    {WriteBytes, WriteSignature} = signed_read(
                                     Ns, ?ANCHOR, KeyPair, Session,
                                     <<"assertz(should_not_exist).">>),
    ?assertMatch(
       {ok, _, {error, read_only}},
       quod_client_goal_ingress:read(
         SessionId, WriteBytes, WriteSignature, ?PEER)),
    {AbsentBytes, AbsentSignature} = signed_read(
                                       Ns, ?ANCHOR, KeyPair, Session,
                                       <<"should_not_exist.">>),
    ?assertMatch(
       {ok, _, {fail, _}},
       quod_client_goal_ingress:read(
         SessionId, AbsentBytes, AbsentSignature, ?PEER)),
    {ScopeBytes, ScopeSignature} = signed_read(
                                     Ns, ?ANCHOR, KeyPair, Session,
                                     <<"\"foreign\"::true.">>),
    ?assertMatch(
       {ok, _, {error, signed_scope_unavailable}},
       quod_client_goal_ingress:read(
         SessionId, ScopeBytes, ScopeSignature, ?PEER)).

same_ontology_scope_keeps_the_user_principal(
  #{namespace := Ns, key_pair := KeyPair,
    session := Session}) ->
    Text = <<$", Ns/binary, "\"::lookup(X).">>,
    {Bytes, Signature} = signed_read(Ns, ?ANCHOR, KeyPair, Session, Text),
    ?assertMatch(
       {ok, _, {ok, [#{0 := bob}], 1}},
       quod_client_goal_ingress:read(
         maps:get(session_id, Session), Bytes, Signature, ?PEER)).

opaque_data_binding_renders_as_the_original_symbol(
  #{namespace := Ns, key_pair := KeyPair,
    session := Session}) ->
    Symbol = unique_symbol(<<"signed_data_answer_">>),
    ?assertError(badarg, binary_to_existing_atom(Symbol, utf8)),
    Text = <<"X = ", Symbol/binary, ".">>,
    {Bytes, Signature} = signed_read(Ns, ?ANCHOR, KeyPair, Session, Text),
    {ok, Evidence, Result} = quod_client_goal_ingress:read(
                               maps:get(session_id, Session), Bytes,
                               Signature, ?PEER),
    ?assertMatch({ok, [#{0 := {'$quod_symbol', Symbol}}], 1}, Result),
    ?assertMatch(
       {200, #{bindings := [#{<<"X">> := Symbol}]}},
       quod_client_http:signed_read_result({ok, Evidence, Result})),
    ?assertError(badarg, binary_to_existing_atom(Symbol, utf8)).

anchor_is_checked_at_ingress_and_inside_the_worker(
  #{namespace := Ns, engine := Engine, table := Table,
    key_pair := {PublicKey, _}}) ->
    OtherAnchor = <<16#75:256>>,
    User = {user, PublicKey},
    ?assertEqual(
       {error, wrong_genesis_anchor},
       quod_prolog:prove_ro_as({Ns, OtherAnchor}, {lookup, {0}}, User)),
    %% Freeze the engine after the public check, wait until the anchored request
    %% is in its mailbox, then simulate an incarnation change.  The worker must
    %% compare the carried anchor again and refuse the old request.
    ok = sys:suspend(Engine),
    Parent = self(),
    Caller = spawn(
               fun() ->
                   Parent ! {anchored_proof_result, self(),
                             quod_prolog:prove_ro_as(
                               {Ns, ?ANCHOR}, {lookup, {0}}, User)}
               end),
    try
        ok = await_anchored_public_cast(Engine, 1000),
        true = ets:insert(Table, {anchor, OtherAnchor}),
        ok = sys:resume(Engine),
        receive
            {anchored_proof_result, Caller, Reply} ->
                ?assertEqual({error, wrong_genesis_anchor}, Reply)
        after 5000 ->
            error(anchored_proof_timeout)
        end
    after
        _ = catch sys:resume(Engine),
        true = ets:insert(Table, {anchor, ?ANCHOR}),
        case is_process_alive(Caller) of
            true -> exit(Caller, kill);
            false -> ok
        end
    end.

session_and_signed_deadline_are_both_bound(
  #{namespace := Ns, key_pair := KeyPair,
    session := Session}) ->
    Request = (request(Ns, ?ANCHOR, KeyPair, Session, <<"true.">>))#{
                not_after_ms => maps:get(expires_ms, Session) + 1},
    {ok, Bytes} = quod_client_goal:encode(Request),
    Signature = quod_identity:sign(
                  Bytes, quod_identity:key_term(KeyPair)),
    ?assertEqual(
       {error, deadline_exceeds_session},
       quod_client_goal_ingress:read(
         maps:get(session_id, Session), Bytes, Signature, ?PEER)),
    ?assertEqual(
       {error, invalid_session},
       quod_client_goal_ingress:read(
         <<0:256>>, Bytes, Signature, ?PEER)).

%% ===================================================================
%% fixture
%% ===================================================================

setup() ->
    {ok, _} = application:ensure_all_started(gproc),
    stop_auth(),
    PreviousDesired = application:get_env(quod, namespace_desired),
    application:set_env(
      quod, namespace_desired,
      #{content => #{quod_ontology:root_ns() =>
                         #{genesis_hash => ?NETWORK}},
        brahms => #{}}),
    Ns = <<"signed-read:",
           (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Table = binary_to_atom(<<"quod_simplex_genesis_", Ns/binary>>, utf8),
    %% Public only inside this fixture: the anchor-race test must mutate the
    %% fake Simplex identity from its EUnit worker process.
    Table = ets:new(Table, [named_table, public, set]),
    true = ets:insert(Table, {anchor, ?ANCHOR}),
    {ok, Pid} = quod_prolog:start_link(
                  Ns, #{node_id => {"127.0.0.1", 5000},
                        outcome_backend => memory}),
    KeyPair = quod_identity:generate(),
    {PublicKey, _} = KeyPair,
    User = {user, PublicKey},
    Policy = {can_invoke, {'Goal'}, User, {'Chain'}, Ns},
    Transactions =
        [quod_ct:change(Ns, quod_ct:diff_for({lookup, bob}), #{}),
         quod_ct:change(Ns, quod_ct:diff_for(Policy), #{})],
    ok = quod_prolog:apply_entry(
           Ns, #entry{index = 1, data = {batch, Transactions}}, live),
    ok = quod_prolog:mark_ready(Ns),
    1 = quod_prolog:applied(Ns),
    {ok, AuthPid} = quod_client_auth:start_link(
                      #{network_id => ?NETWORK, node_key => <<16#73:256>>,
                        session_ttl_ms => 60000}),
    Session = open_session(KeyPair),
    #{namespace => Ns, engine => Pid, auth => AuthPid,
      table => Table, key_pair => KeyPair, session => Session,
      previous_desired => PreviousDesired}.

cleanup(#{engine := Engine, auth := Auth, table := Table,
          previous_desired := PreviousDesired}) ->
    stop_process(Auth),
    case is_process_alive(Engine) of
        true -> gen_server:stop(Engine);
        false -> ok
    end,
    ets:delete(Table),
    restore_env(namespace_desired, PreviousDesired).

open_session(KeyPair) ->
    {PublicKey, _} = KeyPair,
    ClientNonce = <<16#74:256>>,
    {ok, Challenge} = quod_client_auth:issue_challenge(
                        PublicKey, ClientNonce, ?PEER),
    ChallengeId = maps:get(challenge_id, Challenge),
    {ok, ChallengeBytes} = quod_user:challenge_bytes(
                             ?NETWORK, <<16#73:256>>, ChallengeId,
                             PublicKey, ClientNonce,
                             maps:get(server_nonce, Challenge),
                             maps:get(expires_ms, Challenge)),
    ChallengeSignature = quod_identity:sign(
                           ChallengeBytes,
                           quod_identity:key_term(KeyPair)),
    {ok, Session} = quod_client_auth:complete_challenge(
                      ChallengeId, ChallengeSignature),
    Session.

signed_read(Ns, Anchor, KeyPair, Session, Text) ->
    Request = request(Ns, Anchor, KeyPair, Session, Text),
    {ok, Bytes} = quod_client_goal:encode(Request),
    {Bytes, quod_identity:sign(Bytes, quod_identity:key_term(KeyPair))}.

request(Ns, Anchor, {PublicKey, _}, Session, Text) ->
    #{network_identity => ?NETWORK,
      user_public_key => PublicKey,
      operation_id => crypto:strong_rand_bytes(32),
      target_namespace => Ns,
      target_genesis_anchor => Anchor,
      mode => read,
      parser_version => 1,
      not_after_ms => min(maps:get(expires_ms, Session),
                          quod_time:now_ms() + 30000),
      goal_text => Text}.

unique_symbol(Prefix) ->
    <<Prefix/binary,
      (integer_to_binary(erlang:unique_integer([positive])))/binary>>.

await_anchored_public_cast(_Engine, 0) ->
    error(anchored_public_cast_timeout);
await_anchored_public_cast(Engine, Remaining) ->
    {messages, Messages} = process_info(Engine, messages),
    case lists:any(fun is_anchored_public_cast/1, Messages) of
        true -> ok;
        false ->
            receive after 1 -> ok end,
            await_anchored_public_cast(Engine, Remaining - 1)
    end.

is_anchored_public_cast(
  {'$gen_cast', {public_proof, _Caller, _CallRef, prove_ro, _Goal,
                 _TraceCtx, {user, <<_:256>>}, ?ANCHOR}}) ->
    true;
is_anchored_public_cast(_) ->
    false.

stop_auth() ->
    case whereis(quod_client_auth) of
        undefined -> ok;
        Pid -> stop_process(Pid)
    end.

stop_process(Pid) ->
    unlink(Pid),
    MRef = monitor(process, Pid),
    exit(Pid, shutdown),
    receive {'DOWN', MRef, process, Pid, _} -> ok
    after 5000 -> error(process_stop_timeout)
    end.

restore_env(Key, undefined) -> application:unset_env(quod, Key);
restore_env(Key, {ok, Value}) -> application:set_env(quod, Key, Value).
