-module(quod_client_goal_ingress_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

-define(NETWORK, <<16#71:256>>).
-define(ANCHOR, <<16#72:256>>).
-define(PEER, {127, 0, 0, 1}).

signed_local_read_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     fun(Ctx) ->
         [?_test(local_read_uses_agent_acl_and_returns_named_bindings(Ctx)),
          ?_test(forged_request_never_materializes_its_functor(Ctx)),
          ?_test(read_mode_cannot_write_or_open_a_foreign_scope(Ctx)),
          ?_test(same_ontology_scope_keeps_the_agent_principal(Ctx)),
          ?_test(opaque_data_binding_renders_as_the_original_symbol(Ctx)),
          ?_test(anchor_is_checked_at_ingress_and_inside_the_worker(Ctx)),
          ?_test(session_and_signed_deadline_are_both_bound(Ctx)),
          ?_test(cursor_commands_reuse_the_session_signing_key(Ctx)),
          ?_test(wrong_network_and_expired_request_stop_at_ingress(Ctx)),
          ?_test(route_eligible_refusals_advance_to_the_next_validator(Ctx)),
          ?_test(directory_anchor_conflict_is_not_flattened(Ctx)),
          ?_test(operation_absence_remains_unresolved(Ctx)),
          ?_test(operation_resolution_follows_the_existing_claim(Ctx))]
     end}.

local_read_uses_agent_acl_and_returns_named_bindings(
  #{namespace := Ns, key_pair := KeyPair,
    session := Session}) ->
    {Bytes, Signature} = signed_read(
                           Ns, ?ANCHOR, KeyPair, Session,
                           <<"lookup(X).">>),
    {ok, #{variables := [{<<"X">>, 0}]},
     {normalized, {answers, 1, [_]}}} =
        quod_client_goal_ingress:submit(read,
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
       quod_client_goal_ingress:submit(read,
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
       {ok, _, {normalized, {error, read_only}}},
       quod_client_goal_ingress:submit(read,
         SessionId, WriteBytes, WriteSignature, ?PEER)),
    {AbsentBytes, AbsentSignature} = signed_read(
                                       Ns, ?ANCHOR, KeyPair, Session,
                                       <<"should_not_exist.">>),
    ?assertMatch(
       {ok, _, {normalized, {failed, _Reasons}}},
       quod_client_goal_ingress:submit(read,
         SessionId, AbsentBytes, AbsentSignature, ?PEER)),
    {ScopeBytes, ScopeSignature} = signed_read(
                                     Ns, ?ANCHOR, KeyPair, Session,
                                     <<"\"foreign\"::true.">>),
    ?assertMatch(
       {ok, _, {normalized, {error, proof_unavailable}}},
       quod_client_goal_ingress:submit(read,
         SessionId, ScopeBytes, ScopeSignature, ?PEER)).

same_ontology_scope_keeps_the_agent_principal(
  #{namespace := Ns, key_pair := KeyPair,
    session := Session}) ->
    Text = <<$", Ns/binary, "\"::lookup(X).">>,
    {Bytes, Signature} = signed_read(Ns, ?ANCHOR, KeyPair, Session, Text),
    ?assertMatch(
       {ok, _, {normalized, {answers, 1, [_]}}},
       quod_client_goal_ingress:submit(read,
         maps:get(session_id, Session), Bytes, Signature, ?PEER)).

opaque_data_binding_renders_as_the_original_symbol(
  #{namespace := Ns, key_pair := KeyPair,
    session := Session}) ->
    Symbol = unique_symbol(<<"signed_data_answer_">>),
    ?assertError(badarg, binary_to_existing_atom(Symbol, utf8)),
    Text = <<"X = ", Symbol/binary, ".">>,
    {Bytes, Signature} = signed_read(Ns, ?ANCHOR, KeyPair, Session, Text),
    {ok, Evidence, Result} = quod_client_goal_ingress:submit(read,
                               maps:get(session_id, Session), Bytes,
                               Signature, ?PEER),
    ?assertMatch({normalized, {answers, 1, [_]}}, Result),
    ?assertMatch(
       {200, #{bindings := [#{<<"X">> := Symbol}]}},
       quod_client_http:signed_goal_result({ok, Evidence, Result})),
    ?assertError(badarg, binary_to_existing_atom(Symbol, utf8)).

anchor_is_checked_at_ingress_and_inside_the_worker(
  #{namespace := Ns, engine := Engine, table := Table,
    key_pair := KeyPair, session := Session}) ->
    OtherAnchor = <<16#75:256>>,
    SessionId = maps:get(session_id, Session),
    {WrongBytes, WrongSignature} =
        signed_read(Ns, OtherAnchor, KeyPair, Session, <<"lookup(X).">>),
    ?assertEqual(
       {error, wrong_target},
       quod_client_goal_ingress:submit(
         read, SessionId, WrongBytes, WrongSignature, ?PEER)),
    %% Freeze the engine after the public check, wait until the anchored request
    %% is in its mailbox, then simulate an incarnation change.  The worker must
    %% compare the carried anchor again and refuse the old request.
    ok = sys:suspend(Engine),
    {Bytes, Signature} =
        signed_read(Ns, ?ANCHOR, KeyPair, Session, <<"lookup(X).">>),
    Parent = self(),
    Caller = spawn(
               fun() ->
                   Parent ! {anchored_proof_result, self(),
                             quod_client_goal_ingress:submit(
                               read, SessionId, Bytes, Signature, ?PEER)}
               end),
    try
        ok = await_anchored_public_cast(Engine, 1000),
        true = ets:insert(Table, {anchor, OtherAnchor}),
        ok = sys:resume(Engine),
        receive
            {anchored_proof_result, Caller, Reply} ->
                ?assertMatch(
                   {ok, _Evidence,
                    {normalized, {error, target_unavailable}}}, Reply)
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
       quod_client_goal_ingress:submit(read,
         maps:get(session_id, Session), Bytes, Signature, ?PEER)),
    ?assertEqual(
       {error, invalid_session},
       quod_client_goal_ingress:submit(read,
         <<0:256>>, Bytes, Signature, ?PEER)).

cursor_commands_reuse_the_session_signing_key(
  #{namespace := Ns, key_pair := KeyPair, session := Session}) ->
    Request = (request(Ns, ?ANCHOR, KeyPair, Session, <<"lookup(X).">>))#{
                mode => cursor},
    {ok, Bytes} = quod_client_goal:encode(Request),
    Signature = quod_identity:sign(
                  Bytes, quod_identity:key_term(KeyPair)),
    SessionId = maps:get(session_id, Session),
    {ok, _, {normalized, {solution, CursorId, _, _}}} =
        quod_client_goal_ingress:submit(
          cursor, SessionId, Bytes, Signature, ?PEER),
    ?assertMatch(
       {ok, _, {normalized, stopped}},
       quod_client_goal_ingress:cursor_command(
         SessionId, CursorId, stop, ?PEER)).

wrong_network_and_expired_request_stop_at_ingress(
  #{namespace := Ns, key_pair := KeyPair, session := Session}) ->
    SessionId = maps:get(session_id, Session),
    WrongNetwork = quod_ct:signed_goal_fixture(
                     #{network => <<16#76:256>>,
                       target => {Ns, ?ANCHOR}, mode => read,
                       key_pair => KeyPair,
                       deadline => quod_time:now_ms() + 30000,
                       goal_text => <<"lookup(X).">>}),
    ?assertEqual(
       {error, wrong_network},
       quod_client_goal_ingress:submit(
         read, SessionId, maps:get(request_bytes, WrongNetwork),
         maps:get(signature, WrongNetwork), ?PEER)),
    Expired = quod_ct:signed_goal_fixture(
                #{network => ?NETWORK, target => {Ns, ?ANCHOR}, mode => read,
                  key_pair => KeyPair, deadline => quod_time:now_ms() - 1,
                  goal_text => <<"lookup(X).">>}),
    ?assertEqual(
       {error, expired},
       quod_client_goal_ingress:submit(
         read, SessionId, maps:get(request_bytes, Expired),
         maps:get(signature, Expired), ?PEER)).

route_eligible_refusals_advance_to_the_next_validator(
  #{namespace := Ns, key_pair := KeyPair, session := Session}) ->
    {Bytes, Signature} = signed_read(Ns, ?ANCHOR, KeyPair, Session, <<"true.">>),
    {ok, Evidence} = quod_client_goal_target:verify_request(Bytes, Signature),
    First = #{node_key => <<1:256>>, endpoint => {{127, 0, 0, 1}, 5001}},
    Second = #{node_key => <<2:256>>, endpoint => {{127, 0, 0, 1}, 5002}},
    lists:foreach(
      fun(Refusal) ->
          Parent = self(),
          Submit =
              fun(#{node_key := <<1:256>>}, _Owner, _Ev, _Req, _Sig,
                  _Cursor, _Trace, _Expires, _Timeout) ->
                      Parent ! {attempt, Refusal, first},
                      {error, {refused, Refusal}};
                 (#{node_key := <<2:256>>}, _Owner, Ev, _Req, _Sig,
                  _Cursor, _Trace, _Expires, _Timeout) ->
                      Parent ! {attempt, Refusal, second},
                      {ok, Ev, {normalized, fail}}
              end,
          ?assertEqual(
             {ok, Evidence, {normalized, fail}},
             quod_client_goal_ingress:test_forward_routes(
               [First, Second], Evidence, Submit)),
          receive {attempt, Refusal, first} -> ok
          after 0 -> error(first_route_not_attempted)
          end,
          receive {attempt, Refusal, second} -> ok
          after 0 -> error(second_route_not_attempted)
          end
      end, [not_ready, busy, rate_limited]).

directory_anchor_conflict_is_not_flattened(
  #{key_pair := KeyPair, session := Session}) ->
    Ns = <<"signed-conflict:",
           (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Expected = crypto:hash(sha256, <<Ns/binary, ":expected">>),
    Other = crypto:hash(sha256, <<Ns/binary, ":other">>),
    K1 = <<16#78:256>>,
    K2 = <<16#79:256>>,
    stop_directory(),
    {ok, Directory} = quod_directory:start_link(
                        #{expire_tick_ms => 60000, ttl_ms => 10000}),
    try
        {ok, _} = quod_ct:install_directory_generation(
                    K1, {"127.0.0.1", 5001},
                    [{Ns, Expected, validator}], 1, 1),
        {ok, _} = quod_ct:install_directory_generation(
                    K2, {"127.0.0.1", 5002},
                    [{Ns, Other, validator}], 1, 1),
        {Bytes, Signature} = signed_read(
                               Ns, Expected, KeyPair, Session, <<"true.">>),
        ?assertEqual(
           {error, {anchor_conflict, Ns}},
           quod_client_goal_ingress:submit(
             read, maps:get(session_id, Session), Bytes, Signature, ?PEER)),
        ?assertEqual(
           {409, #{error => anchor_conflict, namespace => Ns}},
           quod_client_http:signed_goal_result(
             {error, {anchor_conflict, Ns}}))
    after
        gen_server:stop(Directory)
    end.

operation_absence_remains_unresolved(
  #{namespace := Ns, key_pair := KeyPair, session := Session}) ->
    {Bytes, Signature} = signed_read(
                           Ns, ?ANCHOR, KeyPair, Session, <<"true.">>),
    ?assertMatch(
       {ok, _Evidence, {operation_pending, {operation, Ns, ?ANCHOR, _, _}}},
       quod_client_goal_ingress:resolve_operation(
         maps:get(session_id, Session), Bytes, Signature, ?PEER)).

operation_resolution_follows_the_existing_claim(
  #{namespace := Ns, key_pair := KeyPair, session := Session}) ->
    Deadline = min(maps:get(expires_ms, Session),
                   quod_time:now_ms() + 30000),
    Fixture = quod_ct:signed_dtx_begin_fixture(
                #{network => ?NETWORK, target => {Ns, ?ANCHOR},
                  key_pair => KeyPair,
                  deadline => Deadline,
                  submitted_at => 2}),
    Transaction = maps:get(transaction, Fixture),
    ok = quod_prolog:apply_entry(
           Ns, #entry{index = 2, data = {batch, [Transaction]}}, live),
    ?assertMatch(
       {ok, _Evidence,
        {operation_outcome,
         #{status := claimed, request_digest := _},
         #{status := committed, height := 2}}},
       quod_client_goal_ingress:resolve_operation(
         maps:get(session_id, Session), maps:get(request_bytes, Fixture),
         maps:get(signature, Fixture), ?PEER)),
    Other = quod_ct:signed_goal_fixture(
              #{network => ?NETWORK, target => {Ns, ?ANCHOR},
                key_pair => KeyPair,
                operation_id => maps:get(operation_id, Fixture),
                deadline => Deadline,
                goal_text => <<"assertz(saved(other)).">>}),
    ?assertEqual(
       {error, operation_conflict},
       quod_client_goal_ingress:resolve_operation(
         maps:get(session_id, Session), maps:get(request_bytes, Other),
         maps:get(signature, Other), ?PEER)).

%% ===================================================================
%% fixture
%% ===================================================================

setup() ->
    {ok, _} = application:ensure_all_started(gproc),
    stop_auth(),
    stop_cursor(),
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
    Instance = {human_user, test_agent},
    AgentRef = {agent_instance_ref, Ns, ?ANCHOR, Instance},
    Policy = {can_invoke, {'Goal'}, AgentRef, {'Chain'}, Ns},
    GenesisAuthor = <<16#76:256>>,
    GenesisDiff =
        quod_ct:diff_for({lookup, bob}) ++
        quod_ct:diff_for({agent_key, Instance, PublicKey, active}) ++
        quod_ct:diff_for(Policy),
    Genesis = quod_simplex:test_genesis_tx(
                #{mode => create, node_id => GenesisAuthor,
                  committee => [], genesis_diff => GenesisDiff},
                Ns, GenesisAuthor, <<16#77:256>>),
    ok = quod_prolog:apply_entry(
           Ns, #entry{index = 1, data = {batch, [Genesis]}}, live),
    ok = quod_prolog:mark_ready(Ns),
    1 = quod_prolog:applied(Ns),
    {ok, AuthPid} = quod_client_auth:start_link(
                      #{network_id => ?NETWORK, node_key => <<16#73:256>>,
                        session_ttl_ms => 60000}),
    {ok, CursorPid} = quod_client_cursor:start_link(),
    Session = open_session(KeyPair),
    #{namespace => Ns, engine => Pid, auth => AuthPid, cursor => CursorPid,
      table => Table, key_pair => KeyPair, session => Session,
      previous_desired => PreviousDesired}.

cleanup(#{engine := Engine, auth := Auth, cursor := Cursor, table := Table,
          previous_desired := PreviousDesired}) ->
    stop_process(Cursor),
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
    {ok, ChallengeBytes} = quod_client_auth:challenge_bytes(
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
      signing_public_key => PublicKey,
      operation_id => crypto:strong_rand_bytes(32),
      agent_namespace => Ns,
      agent_genesis_anchor => Anchor,
      agent_instance_text => <<"human_user(test_agent).">>,
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
                 {proof_request, _TraceCtx, {agent, _AgentRef},
                  ?ANCHOR, _RequestAuth, _StartedNative}}}) ->
    true;
is_anchored_public_cast(_) ->
    false.

stop_auth() ->
    case whereis(quod_client_auth) of
        undefined -> ok;
        Pid -> stop_process(Pid)
    end.

stop_cursor() ->
    case whereis(quod_client_cursor) of
        undefined -> ok;
        Pid -> stop_process(Pid)
    end.

stop_directory() ->
    case quod_reg:where({directory, node}) of
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
