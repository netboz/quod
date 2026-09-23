-module(quod_agent_vault_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").
-include_lib("public_key/include/public_key.hrl").

empty_custody_paths_refused_at_boot_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Parent = self(), Tag = make_ref(),
    {Pid, Monitor} = spawn_monitor(fun() ->
        process_flag(trap_exit, true),
        Parent ! {Tag, quod_agent_vault:start_link(#{directory => <<>>, unlock_file => <<>>})}
    end),
    receive {Tag, Result} -> ?assertEqual({error, invalid_vault_configuration}, Result)
    after 5000 -> error(no_vault_boot_result) end,
    receive {'DOWN', Monitor, process, Pid, normal} -> ok
    after 5000 -> error(vault_boot_probe_not_done) end.

custody_survives_restart_and_binds_exact_request_test() ->
    with_vault(fun(Config, Ref, Request0) ->
        {ok, Pub} = quod_agent_vault:generate(Ref),
        Request = Request0#{signing_public_key => Pub},
        {ok, Bytes, Signature} = sign(Request),
        ?assertMatch({ok, #{agent_ref_blob := Ref}}, quod_client_goal:verify(Bytes, Signature)),
        ?assertEqual({ok, Bytes}, quod_client_goal:encode(Request)),
        {ok, [File]} = file:list_dir(maps:get(directory, Config)),
        Path = filename:join(maps:get(directory, Config), File),
        {ok, #file_info{mode = Mode, size = 100}} = file:read_file_info(Path),
        ?assertEqual(8#600, Mode band 8#777),
        Vault = quod_reg:where({agent_vault, node}),
        ?assertMatch(#{state := encrypted_custody},
                     quod_agent_vault:format_status(#{state => sys:get_state(Vault)})),
        ok = gen_server:stop(Vault),
        ?assertEqual({error, vault_unavailable}, sign(Request)),
        {ok, _} = quod_agent_vault:start_link(Config),
        ?assertEqual({ok, Bytes, Signature}, sign(Request)),
        [?assertEqual({error, vault_key_unavailable}, sign(Other))
         || Other <- [Request#{agent_genesis_anchor => <<2:256>>},
                       Request#{agent_namespace => <<"other">>},
                       Request#{agent_instance_text => <<"other_agent.">>}]],
        ?assertEqual({error, wrong_network}, sign(Request#{network_identity => <<2:256>>})),
        ?assertEqual({error, expired}, sign(Request#{not_after_ms => 1})),
        ?assertEqual({error, invalid_request}, sign(<<"arbitrary bytes">>)),
        ?assertEqual({error, invalid_request}, sign(Request#{goal_text => <<"(">>})),
        ok = quod_agent_vault:delete(Ref, Pub),
        ?assertEqual({error, vault_key_unavailable}, sign(Request))
    end).

preparation_is_stable_and_preserves_old_custody_test() ->
    with_vault(fun(Config, Ref, Request0) ->
        {ok, First} = quod_agent_vault:prepare(Ref, 1),
        ?assertEqual({ok, First}, quod_agent_vault:prepare(Ref, 1)),
        {Slot, [KeyFile]} = custody_files(Config),
        {ok, #file_info{inode = Inode, links = 2, mode = Mode}} = file:read_file_info(Slot),
        ?assertMatch({ok, #file_info{inode = Inode, links = 2}}, file:read_file_info(KeyFile)),
        ?assertEqual(8#600, Mode band 8#777),
        ok = gen_server:stop(quod_reg:where({agent_vault, node})),
        {ok, _} = quod_agent_vault:start_link(Config),
        ?assertEqual({ok, First}, quod_agent_vault:prepare(Ref, 1)),
        {ok, Second} = quod_agent_vault:prepare(Ref, 2),
        ?assertNotEqual(First, Second),
        ?assertEqual({error, stale_preparation}, quod_agent_vault:prepare(Ref, 1)),
        ?assertEqual({error, invalid_preparation_epoch}, quod_agent_vault:prepare(Ref, 0)),
        ?assertMatch({ok, _, _}, sign(Request0#{signing_public_key => First})),
        ?assertMatch({ok, _, _}, sign(Request0#{signing_public_key => Second})),
        {Slot, [_, _]} = custody_files(Config),
        ?assertMatch({ok, #file_info{inode = Inode, links = 1}}, file:read_file_info(KeyFile)),
        ok = quod_agent_vault:delete(Ref, First),
        ?assertEqual({ok, Second}, quod_agent_vault:prepare(Ref, 2)),
        ok = quod_agent_vault:delete(Ref, Second),
        ?assertEqual({error, vault_key_unavailable}, sign(Request0#{signing_public_key => Second})),
        ?assertEqual({ok, []}, file:list_dir(maps:get(directory, Config)))
    end).

preparation_recovers_slot_only_crash_image_test() ->
    with_vault(fun(Config, Ref, Request0) ->
        {ok, Pub} = quod_agent_vault:prepare(Ref, 1),
        {_Slot, [KeyFile]} = custody_files(Config),
        ok = gen_server:stop(quod_reg:where({agent_vault, node})),
        %% This is the exact durable image between atomic slot installation
        %% and public-key link creation. The interrupted caller has no reply.
        ok = file:delete(KeyFile),
        {ok, Vault} = quod_agent_vault:start_link(Config),
        ?assertEqual({error, vault_key_unavailable}, sign(Request0#{signing_public_key => Pub})),
        ?assertEqual({ok, Pub}, quod_agent_vault:prepare(Ref, 1)),
        ?assertMatch({ok, _, _}, sign(Request0#{signing_public_key => Pub})),
        %% An abrupt vault loss after preparation also retains the same slot.
        unlink(Vault), Monitor = monitor(process, Vault), exit(Vault, kill),
        receive {'DOWN', Monitor, process, Vault, killed} -> ok
        after 5000 -> error(vault_not_stopped) end,
        {ok, _} = quod_agent_vault:start_link(Config),
        ?assertEqual({ok, Pub}, quod_agent_vault:prepare(Ref, 1))
    end).

preparation_refuses_conflicting_alias_and_foreign_slot_test() ->
    with_vault(fun(Config, Ref, _Request0) ->
        {ok, Pub} = quod_agent_vault:prepare(Ref, 1),
        {Slot, [KeyFile]} = custody_files(Config),
        {ok, Bytes} = file:read_file(KeyFile),
        %% A different inode is not silently replaced, even with equal bytes.
        ok = file:delete(KeyFile),
        ok = file:write_file(KeyFile, Bytes),
        ?assertEqual({error, conflicting_vault_custody}, quod_agent_vault:prepare(Ref, 1)),
        ok = file:delete(KeyFile),
        ?assertEqual({ok, Pub}, quod_agent_vault:prepare(Ref, 1)),
        {ok, Term} = quod_agent_ref:materialize(Ref),
        {ok, Other} = quod_wire_term:encode_canonical(setelement(4, Term, other)),
        {ok, _} = quod_agent_vault:prepare(Other, 1),
        {ok, Files} = file:list_dir(maps:get(directory, Config)),
        [OtherSlot] = [filename:join(maps:get(directory, Config), F) || F <- Files,
                       lists:prefix("prepare-", F),
                       filename:join(maps:get(directory, Config), F) =/= Slot],
        ok = file:write_file(OtherSlot, Bytes),
        ?assertEqual({error, invalid_vault_key}, quod_agent_vault:prepare(Other, 1)),
        ?assertEqual({ok, Pub}, quod_agent_vault:prepare(Ref, 1))
    end).

custody_files(Config) ->
    Dir = maps:get(directory, Config),
    {ok, Files} = file:list_dir(Dir),
    {[Slot], Keys} = lists:partition(fun(F) -> lists:prefix("prepare-", F) end, Files),
    {filename:join(Dir, Slot), [filename:join(Dir, F) || F <- Keys]}.

wrong_unlock_and_corrupt_ciphertext_fail_closed_test() ->
    with_vault(fun(Config, Ref, Request0) ->
        {ok, Pub} = quod_agent_vault:generate(Ref),
        Request = Request0#{signing_public_key => Pub},
        {ok, [Name]} = file:list_dir(maps:get(directory, Config)),
        Path = filename:join(maps:get(directory, Config), Name),
        {ok, <<Byte, Rest/binary>>} = file:read_file(Path),
        ok = file:write_file(Path, <<(Byte bxor 1), Rest/binary>>),
        ?assertEqual({error, invalid_vault_key}, sign(Request)),
        ok = file:write_file(Path, <<Byte, Rest/binary>>),
        ok = gen_server:stop(quod_reg:where({agent_vault, node})),
        ok = file:write_file(maps:get(unlock_file, Config), crypto:strong_rand_bytes(32)),
        {ok, _} = quod_agent_vault:start_link(Config),
        ?assertEqual({error, invalid_vault_key}, sign(Request))
    end).

governed_signing_requires_committed_host_key_and_read_only_session_test() ->
    with_vault(fun(_Config, Ref, Request0) ->
        {ok, Pub} = quod_agent_vault:generate(Ref),
        {ok, AgentRef} = quod_agent_ref:materialize(Ref),
        #{principal := Principal, agent_reference := NodeRef,
          evidence := Evidence} = quod_ct:signed_goal_fixture(#{goal_text => <<"true.">>}),
        Previous = application:get_env(quod, node_actor_principal),
        application:set_env(quod, node_actor_principal, Principal),
        _ = quod_proof_context:start(crypto:strong_rand_bytes(32), true,
              {<<"agents">>, <<3:256>>}, quod_time:mono_ms() + 5000, Principal, Evidence),
        try
            Request = Request0#{signing_public_key => Pub},
            Typed = {agent_goal_v1, maps:get(network_identity, Request), AgentRef,
                     maps:get(agent_instance_text, Request), Pub,
                     maps:get(operation_id, Request), maps:get(not_after_ms, Request),
                     execute, 2, <<"true.">>},
            Goal = {sign_agent_request, Typed, {'Signature'}},
            Grant = {can_request_agent_signature, NodeRef, worker, Typed},
            Host = {agent_host, worker, NodeRef, 1, Pub},
            Key = {agent_key, worker, Pub, active},
            Facts = [Grant, Host, Key],
            {ok, Bindings} = signing_proof(Facts, true, Goal),
            {ok, Bytes} = quod_client_goal:encode(Request),
            ?assert(quod_identity:verify(maps:get('Signature', Bindings), Bytes, Pub)),
            ?assertEqual(fail, signing_proof([Host, Key], true, Goal)),
            %% A foreign ontology's permissive policy cannot release another
            %% ontology's custody, even when it pins the same bridge module.
            ?assertEqual(fail, signing_proof([], true, Goal,
              #{source => <<"can_sign_agent_request(_,_,_).">>,
                identity => {<<"hostile">>, <<4:256>>}})),
            ?assertEqual(fail, signing_proof([], true, Goal,
              #{source => <<"can_sign_agent_request(_,_,_).">>,
                identity => {<<"agents">>, <<4:256>>}})),
            ?assertEqual(fail, signing_proof(Facts, true,
              {sign_agent_request, setelement(10, Typed, <<"assertz(unapproved).">>), {'Signature'}})),
            Catch = {';', {'catch', Goal, {'Error'}, {'=', {'Caught'}, yes}},
                     {'=', {'Result'}, denied}},
            {ok, Denied} = signing_proof([], true, Catch,
              #{source => <<"can_sign_agent_request(_,_,_) :- throw(policy_fault).">>}),
            ?assertEqual(denied, maps:get('Result', Denied)),
            ?assertEqual({error, deadline_exceeded},
              quod_agent_vault:sign(Request, quod_time:mono_ms() - 1)),
            ?assertEqual(fail, signing_proof([Grant, Host, setelement(4, Key, revoked)], true, Goal)),
            ?assertEqual(fail, signing_proof([Grant, Host, setelement(4, Key, staged)], true, Goal)),
            ?assertEqual(fail, signing_proof([Grant, setelement(3, Host, other_host), Key], true, Goal)),
            ?assertEqual(fail, signing_proof(Facts, false, Goal)),
            StagedGrant = {',', {assertz, Grant}, {'$quod_state_check', Goal}},
            ?assertEqual(fail, signing_proof([Host, Key], false, StagedGrant)),
            ?assertEqual(fail, signing_proof(Facts, true,
              {sign_agent_request, setelement(4, Typed, <<"different_agent.">>), {'Signature'}})),
            ?assertEqual(fail, signing_proof(Facts, true,
              {sign_agent_request, <<"arbitrary bytes">>, {'Signature'}}))
        after
            quod_proof_context:stop(fun(_) -> ok end, fun(_) -> ok end),
            case Previous of
                undefined -> application:unset_env(quod, node_actor_principal);
                {ok, Value} -> application:set_env(quod, node_actor_principal, Value)
            end
        end
    end).

%% Exercise the actual signed ingress and foreign read-only scope. The engine
%% owns both committed snapshots; only consensus transport is outside this seam.
signing_through_signed_ingress_and_foreign_scope_test() ->
    with_vault(fun(Config, Ref, Request0) ->
        {ok, Pub} = quod_agent_vault:generate(Ref),
        {ok, AgentRef} = quod_agent_ref:materialize(Ref),
        NodeNs = <<"vault-node">>, NodeAnchor = <<5:256>>,
        Fixture = #{principal := Principal, agent_reference := NodeRef,
                    signing_key := NodeKey} = quod_ct:signed_goal_fixture(
          #{target => {NodeNs, NodeAnchor}, network => <<1:256>>, mode => read,
            deadline => quod_time:now_ms() + 30000,
            goal_text => <<"\"agents\"::(signing_request(R),sign_agent_request(R,S)).">>}),
        Request = Request0#{signing_public_key => Pub},
        Typed = {agent_goal_v1, <<1:256>>, AgentRef, <<"worker.">>, Pub,
                 maps:get(operation_id, Request), maps:get(not_after_ms, Request),
                 execute, 2, <<"true.">>},
        Previous = application:get_env(quod, node_actor_principal),
        PreviousKey = application:get_env(quod, node_pubkey),
        application:set_env(quod, node_pubkey, NodeKey),
        {ok, Router} = quod_ask_router:start_link(),
        application:set_env(quod, node_actor_principal, Principal),
        {ok, Auth} = quod_client_auth:start_link(
          #{network_id => <<1:256>>, node_key => NodeKey, session_ttl_ms => 60000}),
        Node = start_engine(NodeNs, NodeAnchor, maps:get(identity, Fixture), [], [],
          quod_ct:signed_agent_facts(Fixture) ++
          [{can_invoke, {'Goal'}, NodeRef, {'Chain'}, NodeNs}]),
        Source = filename:join(code:priv_dir(quod), "ontologies/agent_instance.pl"),
        Actor = start_engine(<<"agents">>, <<3:256>>, maps:get(identity, Fixture), [quod_agent_predicates],
          quod_prolog:genesis_diff(Source),
          [{agent_host, worker, NodeRef, 1, Pub}, {agent_key, worker, Pub, active},
           {can_request_agent_signature, NodeRef, worker, Typed},
           {signing_request, Typed},
           {can_invoke, {'Goal'}, NodeRef, {'Chain'}, <<"agents">>}]),
        try
            %% Signing runs where custody lives, including a local observer.
            %% Read-only :: must not route this query to a remote validator.
            {_ActorPid, ActorTable} = Actor,
            true = ets:insert(ActorTable,
              {proof_gate, true, 1, [], NodeKey, [<<10:256>>], <<11:256>>, #{}}),
            ?assertEqual({error, not_validator}, quod_simplex:identity_view(<<"agents">>)),
            Result = quod_client_goal_ingress:submit(
              maps:get(request_bytes, Fixture), maps:get(signature, Fixture), NodeKey),
            ?assertMatch({ok, _, {normalized, {answers, 1, [_]}}}, Result),
            {ok, _, {normalized, {answers, 1, [Bindings]}}} = Result,
            %% Verify the emitted signature, not just policy success.
            {ok, Bytes} = quod_client_goal:encode(Request),
            {ok, Decoded} = quod_durable_term:decode_result(Bindings),
            ?assert(quod_identity:verify(proplists:get_value(<<"S">>, Decoded), Bytes, Pub)),
            with_provider(Config, fun(Port, Options, Client, _Other) ->
                {ok, Socket} = provider_connect(Port, Options, Client),
                try
                    Body = json:encode(#{
                      request => base64:encode(maps:get(request_bytes, Fixture), #{mode => urlsafe, padding => false}),
                      signature => base64:encode(maps:get(signature, Fixture), #{mode => urlsafe, padding => false})}),
                    {200, _, Reply} = quod_ct:https_request(Socket, post, "/read", iolist_to_binary(Body)),
                    {200, Expected} = quod_client_http:signed_goal_result(Result),
                    ?assertEqual(json:decode(iolist_to_binary(json:encode(Expected))), json:decode(Reply))
                after ssl:close(Socket) end
            end),
            ok = gen_server:stop(quod_reg:where({agent_vault, node})),
            ?assertMatch({ok, _, {normalized, {failed, _}}},
              quod_client_goal_ingress:submit(maps:get(request_bytes, Fixture),
                                               maps:get(signature, Fixture), NodeKey))
        after
            stop_engine(Actor), stop_engine(Node), gen_server:stop(Auth), gen_server:stop(Router),
            case PreviousKey of
                undefined -> application:unset_env(quod, node_pubkey);
                {ok, OldKey} -> application:set_env(quod, node_pubkey, OldKey)
            end,
            case Previous of
                undefined -> application:unset_env(quod, node_actor_principal);
                {ok, Value} -> application:set_env(quod, node_actor_principal, Value)
            end
        end
    end).

start_engine(Ns, Anchor, Identity = #{pubkey := PublicKey}, Modules, Diff, Facts) ->
    Table = binary_to_atom(<<"quod_simplex_genesis_", Ns/binary>>, utf8),
    Table = ets:new(Table, [named_table, set]),
    true = ets:insert(Table, {anchor, Anchor}),
    true = ets:insert(Table, {proof_gate, true, 1, [], PublicKey, [PublicKey], <<9:256>>, #{}}),
    {ok, Pid} = quod_prolog:start_link(Ns,
      #{node_id => PublicKey, identity => Identity, outcome_backend => memory}),
    Genesis = quod_simplex:test_genesis_tx(
      #{mode => create, node_id => <<7:256>>, committee => [],
        external_predicate_modules => Modules,
        genesis_diff => Diff ++ quod_prolog:terms_to_diff(Facts)}, Ns, <<7:256>>, <<8:256>>),
    ok = quod_prolog:apply_entry(Ns, quod_ct:committed_entry(Ns, 1, {batch, [Genesis]}), live),
    ok = quod_prolog:mark_ready(Ns),
    {Pid, Table}.

stop_engine({Pid, Table}) ->
    gen_server:stop(Pid), ets:delete(Table).

signing_proof(Facts, ReadOnly, Goal) -> signing_proof(Facts, ReadOnly, Goal, #{}).

signing_proof(Facts, ReadOnly, Goal, Options) ->
    {ok, DefaultSource} = file:read_file(filename:join(code:priv_dir(quod), "ontologies/agent_instance.pl")),
    KB = quod_ct:action_kb(maps:get(source, Options, DefaultSource), [quod_agent_predicates], Facts),
    Session = quod_proof_session:start(KB, #{read_set => true, read_only => ReadOnly}),
    Id = crypto:strong_rand_bytes(16),
    {Ns, _} = Identity = maps:get(identity, Options, {<<"agents">>, <<3:256>>}),
    Context = quod_predicates:proof_context(Ns, 1, undefined, [Identity]),
    try
        ok = quod_proof_session:open(Session, Id, Goal, allowed, Context, quod_transaction_scope:empty_selection()),
        case quod_proof_session:next(Session, Id) of
            {solution, _} -> quod_proof_session:bindings(Session, Id);
            {complete, _} -> fail;
            Other -> Other
        end
    after quod_proof_session:stop(Session) end.

provider_requires_mtls_and_refuses_execute_test() ->
    with_vault(fun(Config, _Ref, _Request) ->
        with_provider(Config, fun(Port, Options, Client, Other) ->
            %% TLS 1.3 may return the client socket before the server's certificate
            %% requirement alert arrives. In either case no HTTP response is allowed.
            case ssl:connect("127.0.0.1", Port, Options, 5000) of
                {error, _} -> ok;
                {ok, Unauthenticated} ->
                    try
                        _ = ssl:send(Unauthenticated, <<"GET /read HTTP/1.1\r\nhost: localhost\r\n\r\n">>),
                        ?assertMatch({error, _}, ssl:recv(Unauthenticated, 0, 5000))
                    after ssl:close(Unauthenticated) end
            end,
            {ok, Rejected} = provider_connect(Port, Options, Other),
            try ?assertMatch({403, _, _}, quod_ct:https_request(Rejected, post, "/read", <<"{}">>))
            after ssl:close(Rejected) end,
            {ok, Allowed} = provider_connect(Port, Options, Client),
            try
                ?assertMatch({400, _, _}, quod_ct:https_request(Allowed, post, "/read", <<"{}">>)),
                #{request_bytes := Bytes, signature := Signature} = quod_ct:signed_goal_fixture(#{mode => execute}),
                Body = json:encode(#{request => base64:encode(Bytes, #{mode => urlsafe, padding => false}),
                                     signature => base64:encode(Signature, #{mode => urlsafe, padding => false})}),
                {400, _, Encoded} = quod_ct:https_request(Allowed, post, "/read", iolist_to_binary(Body)),
                ?assertEqual(#{<<"error">> => <<"unsupported_goal_mode">>}, json:decode(Encoded))
            after ssl:close(Allowed) end
        end)
    end).

with_provider(Config, Fun) ->
    {ok, _} = application:ensure_all_started(ssl),
    {ok, _} = application:ensure_all_started(cowboy),
    Dir = filename:dirname(maps:get(unlock_file, Config)),
    TLSDir = filename:join(Dir, "tls"),
    ok = filelib:ensure_dir(filename:join(TLSDir, "cert")),
    Root = public_key:pkix_test_root_cert("vault test root",
             [{key, {namedCurve, ?'secp256r1'}}, {digest, sha256}]),
    Server = public_key:pkix_test_data(#{root => Root, intermediates => [],
      peer => [{key, {namedCurve, ?'secp256r1'}}, {digest, sha256},
               {extensions, [#'Extension'{extnID = ?'id-ce-subjectAltName',
                    extnValue = [{dNSName, "localhost"}], critical = false}]}]}),
    ClientPair = {ClientKey, _} = quod_identity:generate(),
    Client = provider_certificate(Root, ClientPair),
    Other = provider_certificate(Root, quod_identity:generate()),
    CAFile = filename:join(Dir, "clients.pem"),
    ok = file:write_file(CAFile, public_key:pem_encode(
      [{'Certificate', maps:get(cert, Root), not_encrypted}])),
    ServerCert = filename:join(TLSDir, "server.crt.pem"),
    ServerKeyFile = filename:join(TLSDir, "server.key.pem"),
    ok = file:write_file(ServerCert, public_key:pem_encode(
            [{'Certificate', proplists:get_value(cert, Server), not_encrypted}])),
    {KeyType, KeyDER} = proplists:get_value(key, Server),
    ok = quod_file:write_atomic(ServerKeyFile, public_key:pem_encode(
            [{KeyType, KeyDER, not_encrypted}]), 8#600),
    Provider = #{ip => {127,0,0,1}, port => 0, peer_keys => [ClientKey],
                 tls => #{certfile => ServerCert,
                          keyfile => ServerKeyFile,
                          client_ca_file => CAFile}},
    ok = gen_server:stop(quod_reg:where({agent_vault, node})),
    {ok, _} = quod_agent_vault:start_link(Config#{provider => Provider}),
    Port = ranch:get_port(quod_agent_vault_listener),
    Options = [binary, {active, false}, {verify, verify_peer},
               {cacertfile, CAFile}, {server_name_indication, "localhost"}],
    Fun(Port, Options, Client, Other).

provider_certificate(Root, Pair) ->
    public_key:pkix_test_data(#{root => Root, intermediates => [],
      peer => [{key, quod_identity:key_term(Pair)}, {digest, sha256}]}).

provider_connect(Port, Options, CertificateOptions) ->
    ssl:connect("127.0.0.1", Port, proplists:delete(cacerts, CertificateOptions) ++ Options, 5000).

with_vault(Fun) ->
    {ok, _} = application:ensure_all_started(gproc),
    Previous = application:get_env(quod, namespace_desired),
    Network = <<1:256>>, Anchor = <<3:256>>,
    application:set_env(quod, namespace_desired,
      #{content => #{quod_ontology:root_ns() => #{genesis_hash => Network}}, brahms => #{}}),
    Dir = filename:join("/tmp", "quod_vault_" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8)))),
    Config = #{directory => filename:join(Dir, "keys"), unlock_file => filename:join(Dir, "unlock")},
    ok = filelib:ensure_dir(maps:get(unlock_file, Config)),
    ok = quod_file:write_atomic(maps:get(unlock_file, Config), crypto:strong_rand_bytes(32), 8#600),
    {ok, #{blob := Ref}} = quod_agent_ref:from_text(<<"agents">>, Anchor, <<"worker.">>, 2),
    {ok, _} = quod_agent_vault:start_link(Config),
    Request = #{network_identity => Network, agent_namespace => <<"agents">>,
                agent_genesis_anchor => Anchor, agent_instance_text => <<"worker.">>,
                operation_id => crypto:strong_rand_bytes(32), not_after_ms => quod_time:now_ms() + 30000,
                mode => execute, parser_version => 2, goal_text => <<"true.">>},
    try Fun(Config, Ref, Request)
    after
        case quod_reg:where({agent_vault, node}) of undefined -> ok; Pid -> gen_server:stop(Pid) end,
        ok = file:del_dir_r(Dir),
        case Previous of
            undefined -> application:unset_env(quod, namespace_desired);
            {ok, Value} -> application:set_env(quod, namespace_desired, Value)
        end
    end.

sign(Request) -> quod_agent_vault:sign(Request, quod_time:mono_ms() + 5000).
