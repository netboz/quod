-module(quod_client_tests).

-include_lib("eunit/include/eunit.hrl").

client_schema_defaults_test() ->
    Fields = maps:from_list(quod_schema:fields(client)),
    ?assertEqual(false, maps:get(default, maps:get(enabled, Fields))),
    ?assertEqual(14570, maps:get(default, maps:get(port, Fields))),
    %% Empty means "serve the node's own self-signed certificate", which is why
    %% there is no plaintext option to fall back to.
    ?assertEqual(<<>>, maps:get(default, maps:get(certfile, Fields))),
    ?assertEqual(<<>>, maps:get(default, maps:get(keyfile, Fields))).

client_listener_is_opt_in_test() ->
    with_env(#{client_enabled => false},
             fun() ->
                 ?assertEqual(ignore, quod_client:start_link()),
                 {ok, {_Flags, Children}} = quod_sup:init([]),
                 Ids = [maps:get(id, Child) || Child <- Children],
                 ?assert(lists:member(quod_client_auth, Ids)),
                 ?assert(lists:member(quod_client_cursor, Ids)),
                 ?assert(lists:member(quod_client_goal_router, Ids)),
                 ?assert(lists:member(quod_client, Ids))
             end).

%% The path that only ever runs in production: application env to a bound,
%% serving HTTPS listener. The handler tests drive the routes directly, so
%% without this nothing exercises the configuration plumbing in between.
client_serves_https_from_config_test() ->
    Dir = scratch_dir(),
    with_env(#{client_enabled => true, client_ip => {127, 0, 0, 1},
               client_port => 0, identity_dir => Dir,
               client_certfile => <<>>, client_keyfile => <<>>},
      fun() ->
          {ok, Pid} = quod_client:start_link(),
          try
              Port = ranch:get_port(quod_client_listener),
              ?assertEqual(<<"ok\n">>, get_health(Port)),
              {308, RedirectHead, <<>>} =
                  get_response(Port, <<"/explorer">>),
              ?assertNotEqual(
                 nomatch,
                 binary:match(
                   RedirectHead, <<"\r\nlocation: /explorer/">>)),
              {200, Explorer} = get_path(Port, <<"/explorer/">>),
              ?assertNotEqual(nomatch, binary:match(Explorer, <<"root">>)),
              %% The keypair is persisted, so a visitor's accepted certificate
              %% keeps working across restarts.
              ?assert(filelib:is_regular(filename:join(Dir, "client_tls.key"))),
              ?assert(filelib:is_regular(filename:join(Dir, "client_tls.crt")))
          after stop(Pid)
          end
      end).

%% A browser endpoint fault must not stop consensus boot. The client stays
%% alive, retries its own listener, and becomes reachable once the port clears.
client_retries_a_listener_failure_without_stopping_test() ->
    {ok, Blocker} = ssl_free_socket(),
    {ok, {{127, 0, 0, 1}, Port}} = inet:sockname(Blocker),
    try
        with_env(#{client_enabled => true, client_ip => {127, 0, 0, 1},
                   client_port => Port, identity_dir => scratch_dir(),
                   client_certfile => <<>>, client_keyfile => <<>>},
          fun() ->
              {ok, Pid} = quod_client:start_link(),
              try
                  ?assert(is_process_alive(Pid)),
                  ?assertEqual(undefined, whereis(quod_client_listener)),
                  gen_tcp:close(Blocker),
                  Pid ! retry_listener,
                  ok = wait_for_health(Port, 100)
              after
                  stop(Pid)
              end
          end)
    after catch gen_tcp:close(Blocker)
    end.

%% A brutal owner death leaves Cowboy running.  The replacement client must not
%% merely adopt that listener: its old TLS options would otherwise outlive the
%% certificate configured by the new process.
client_replaces_orphaned_listener_with_current_tls_test() ->
    FirstDir = scratch_dir(),
    SecondDir = scratch_dir(),
    with_env(#{client_enabled => true, client_ip => {127, 0, 0, 1},
               client_port => 0, identity_dir => FirstDir,
               client_certfile => <<>>, client_keyfile => <<>>},
      fun() ->
          {ok, First} = quod_client:start_link(),
          FirstPort = ranch:get_port(quod_client_listener),
          FirstCert = peer_cert(FirstPort),
          unlink(First),
          MRef = monitor(process, First),
          exit(First, kill),
          receive {'DOWN', MRef, process, First, killed} -> ok after 5000 -> error(first_client_survived) end,
          %% `terminate/2` does not run on kill, so this assertion proves the
          %% next start really takes the `already_started` branch.
          ?assertEqual(FirstPort, ranch:get_port(quod_client_listener)),
          application:set_env(quod, identity_dir, SecondDir),
          {ok, Second} = quod_client:start_link(),
          try
              SecondPort = ranch:get_port(quod_client_listener),
              ?assertNotEqual(FirstCert, peer_cert(SecondPort)),
              ?assertEqual(<<"ok\n">>, get_health(SecondPort))
          after
              stop(Second)
          end
      end).

%% A configured certificate belongs to the operator.  It must boot normally,
%% be served verbatim, and never enter the self-signed renewal path.
client_serves_operator_managed_tls_without_renewal_test() ->
    Dir = scratch_dir(),
    {ok, #{cert := Cert, key := Key}} = quod_client_tls:ensure(Dir),
    CertPath = filename:join(Dir, "operator.crt"),
    KeyPath = filename:join(Dir, "operator.key"),
    ok = file:write_file(
           CertPath,
           public_key:pem_encode(
             [{'Certificate', Cert, not_encrypted}])),
    ok = file:write_file(
           KeyPath,
           public_key:pem_encode(
             [{'ECPrivateKey',
               public_key:der_encode('ECPrivateKey', Key),
               not_encrypted}])),
    {ok, KeyBefore} = file:read_file(KeyPath),
    with_env(#{client_enabled => true, client_ip => {127, 0, 0, 1},
               client_port => 0, identity_dir => scratch_dir(),
               client_certfile => CertPath, client_keyfile => KeyPath},
      fun() ->
          {ok, Pid} = quod_client:start_link(),
          try
              Port = ranch:get_port(quod_client_listener),
              ?assertEqual(Cert, peer_cert(Port)),
              ?assertEqual(<<"ok\n">>, get_health(Port)),
              ?assertEqual({ok, KeyBefore}, file:read_file(KeyPath))
          after
              stop(Pid)
          end
      end).

%% ======================================================================
%% harness
%% ======================================================================

get_health(Port) ->
    {200, Body} = get_path(Port, <<"/health">>),
    Body.

get_path(Port, Path) ->
    {Status, _Head, Body} = get_response(Port, Path),
    {Status, Body}.

get_response(Port, Path) ->
    {ok, Socket} = ssl:connect("127.0.0.1", Port,
                               [binary, {active, false}, {verify, verify_none}],
                               5000),
    try
        ok = ssl:send(
               Socket,
               <<"GET ", Path/binary, " HTTP/1.1\r\nhost: localhost\r\n"
                 "connection: close\r\n\r\n">>),
        [Head, Body] = binary:split(
                         recv_all(Socket, <<>>), <<"\r\n\r\n">>),
        [StatusLine | _] = binary:split(Head, <<"\r\n">>, [global]),
        [<<"HTTP/1.1">>, Status | _ReasonWords] =
            binary:split(StatusLine, <<" ">>, [global]),
        {binary_to_integer(Status), Head, Body}
    after ssl:close(Socket)
    end.

peer_cert(Port) ->
    {ok, Socket} = ssl:connect("127.0.0.1", Port,
                               [binary, {active, false}, {verify, verify_none}],
                               5000),
    try
        {ok, Cert} = ssl:peercert(Socket),
        Cert
    after ssl:close(Socket)
    end.

recv_all(Socket, Acc) ->
    case ssl:recv(Socket, 0, 5000) of
        {ok, Data} -> recv_all(Socket, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc
    end.

wait_for_health(_Port, 0) -> error(client_listener_did_not_retry);
wait_for_health(Port, Attempts) ->
    try
        ?assertEqual(<<"ok\n">>, get_health(Port)),
        ok
    catch _:_ ->
        receive after 20 -> wait_for_health(Port, Attempts - 1) end
    end.

ssl_free_socket() ->
    gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}, {reuseaddr, false}]).

scratch_dir() ->
    Dir = filename:join(["/tmp", "quod-client-tests",
                         integer_to_list(erlang:unique_integer([positive]))]),
    ok = filelib:ensure_path(Dir),
    Dir.

stop(Pid) ->
    unlink(Pid),
    MRef = monitor(process, Pid),
    exit(Pid, shutdown),
    receive {'DOWN', MRef, process, Pid, _} -> ok after 5000 -> ok end.

with_env(Env, Fun) ->
    {ok, _} = application:ensure_all_started(ssl),
    {ok, _} = application:ensure_all_started(cowboy),
    Saved = [{K, application:get_env(quod, K)} || K <- maps:keys(Env)],
    maps:foreach(fun(K, V) -> application:set_env(quod, K, V) end, Env),
    try Fun()
    after
        [case Old of
             {ok, Value} -> application:set_env(quod, K, Value);
             undefined -> application:unset_env(quod, K)
         end || {K, Old} <- Saved]
    end.
