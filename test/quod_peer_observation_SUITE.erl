-module(quod_peer_observation_SUITE).
-include_lib("common_test/include/ct.hrl").
-export([all/0, init_per_suite/1, end_per_suite/1,
         cold_timeout_is_shared_physical_suspicion/1,
         contact_survives_consumer_restart_and_expiry/1,
         newer_contact_fences_same_key_history/1,
         withdrawal_fences_pending_physical_completion/1]).

all() -> [cold_timeout_is_shared_physical_suspicion,
          contact_survives_consumer_restart_and_expiry,
          newer_contact_fences_same_key_history,
          withdrawal_fences_pending_physical_completion].

init_per_suite(Config) -> quod_quic_SUITE:init_per_suite(Config).
end_per_suite(Config) -> quod_quic_SUITE:end_per_suite(Config).

cold_timeout_is_shared_physical_suspicion(_Config) ->
    T = quod_reg:where({transport, node}),
    Key = crypto:strong_rand_bytes(32),
    {Socket, Endpoint} = blackhole(),
    Host = install_contact(Key, Endpoint, 1, hosted),
    true = quod_reg:subscribe_tracked({node_identity_route, Host}),
    true = quod_reg:subscribe({peer_loss, Key}),
    Since = quod_time:mono_ms(),
    try
        {ok, Contact} = contact(T, Host),
        Snapshot = quod_quic:peer_connections(T, Key),
        receive {Snapshot, {peer_connections, T, _, Key, []}} -> ok
        after 1000 -> ct:fail(cold_peer_already_authenticated) end,
        {Episode, waiting, none} = observation(T, Contact, Since),
        Parent = self(),
        {Consumer, Monitor} = spawn_monitor(fun() ->
            true = quod_reg:subscribe({peer_loss, Key}),
            Parent ! {second_snapshot, self(), observation(T, Contact, Since)},
            Parent ! {second_observation, self(), completion(T, Key, Episode)}
        end),
        receive {second_snapshot, Consumer, {Episode, waiting, none}} -> ok
        after 1000 -> ct:fail(physical_probe_not_shared) end,
        %% A real QUIC Initial proves that missing prior coverage was not used
        %% as failure evidence; suspicion requires this attempt to time out.
        _ = initial(Socket, quod_time:mono_ms() + 4000),
        {suspected_unreachable, At} = completion(T, Key, Episode),
        receive {second_observation, Consumer, {suspected_unreachable, At}} -> ok
        after 1000 -> ct:fail(physical_completion_not_shared) end,
        receive {'DOWN', Monitor, process, Consumer, normal} -> ok
        after 1000 -> ct:fail(consumer_not_finished) end,
        {Episode, suspected_unreachable, At} = observation(T, Contact, Since),
        %% A notice captured before a new dependency can only wake it. Its
        %% snapshot must request new physical work, not reuse the old result.
        {Fresh, waiting, none} = observation(T, Contact, quod_time:mono_ms()),
        true = Fresh =/= Episode
    after
        quod_reg:unsubscribe({peer_loss, Key}),
        quod_reg:unsubscribe_tracked({node_identity_route, Host}),
        gen_udp:close(Socket)
    end.

withdrawal_fences_pending_physical_completion(_Config) ->
    T = quod_reg:where({transport, node}),
    Key = crypto:strong_rand_bytes(32),
    {Socket, Endpoint} = blackhole(),
    Host = install_contact(Key, Endpoint, 1, hosted),
    true = quod_reg:subscribe({peer_loss, Key}),
    try
        {ok, Contact} = contact(T, Host),
        {Episode, waiting, none} = observation(T, Contact, quod_time:mono_ms()),
        _ = initial(Socket, quod_time:mono_ms() + 4000),
        Host = install_contact(Key, Endpoint, 2, withdrawn),
        false = quod_directory:node_contact_current(Contact),
        {{unknown, stale_contact}, _} = completion(T, Key, Episode),
        unknown = contact(T, Host)
    after
        quod_reg:unsubscribe({peer_loss, Key}),
        gen_udp:close(Socket)
    end.

contact_survives_consumer_restart_and_expiry(Config) ->
    T = quod_reg:where({transport, node}),
    Key = ?config(self_pubkey, Config),
    {ok, Endpoint} = application:get_env(quod, node_addr),
    Host = install_contact(Key, Endpoint, 1, hosted),
    Parent = self(),
    {Consumer, Monitor} = spawn_monitor(fun() ->
        true = quod_reg:subscribe({peer_loss, Key}),
        {ok, Contact0} = contact(T, Host),
        {Episode0, waiting, none} = observation(T, Contact0, quod_time:mono_ms()),
        {reachable, _} = completion(T, Key, Episode0),
        Parent ! {acquired_contact, self(), Contact0, Episode0}
    end),
    {Contact, Episode} = receive
        {acquired_contact, Consumer, C, E} -> {C, E}
    after 8000 -> ct:fail(contact_not_acquired) end,
    receive {'DOWN', Monitor, process, Consumer, normal} -> ok
    after 1000 -> ct:fail(first_consumer_not_finished) end,
    ok = quod_directory:expire(maps:get(expiry, Contact)),
    unknown = quod_directory:node_transport_route(Host),
    true = quod_directory:node_contact_current(Contact),
    true = quod_reg:subscribe({peer_loss, Key}),
    try
        {ok, Contact} = contact(T, Host),
        {Fresh, waiting, none} = observation(T, Contact, quod_time:mono_ms()),
        true = Fresh =/= Episode,
        {reachable, _} = completion(T, Key, Fresh),
        %% Only the transport owns retention. Replacing that owner cannot
        %% reacquire an expired route from another consumer's old reference.
        Sup = quod_reg:where({sup, node}),
        ok = supervisor:terminate_child(Sup, quod_quic),
        {ok, NextT} = supervisor:restart_child(Sup, quod_quic),
        true = NextT =/= T,
        unknown = contact(NextT, Host),
        Ref = quod_quic:confirm_peer_loss(NextT, Contact, quod_time:mono_ms()),
        receive {Ref, {unknown, route_unavailable}} -> ok
        after 1000 -> ct:fail(old_owner_contact_was_reacquired) end
    after quod_reg:unsubscribe({peer_loss, Key}) end.

newer_contact_fences_same_key_history(Config) ->
    T = quod_reg:where({transport, node}),
    {Peer, Key, Endpoint} = quod_agent_peer:start(
        filename:join(?config(priv_dir, Config), "generation-peer")),
    {Socket, SilentEndpoint} = blackhole(),
    Host = install_contact(Key, Endpoint, 1, hosted),
    true = quod_reg:subscribe({peer_loss, Key}),
    try
        {ok, First} = contact(T, Host),
        {Healthy, waiting, none} = observation(T, First, quod_time:mono_ms()),
        {reachable, _} = completion(T, Key, Healthy),
        Host = install_contact(Key, SilentEndpoint, 2, hosted),
        Ref = quod_quic:confirm_peer_loss(T, First, quod_time:mono_ms()),
        receive {Ref, {unknown, route_unavailable}} -> ok
        after 1000 -> ct:fail(old_generation_was_not_fenced) end,
        {ok, Second} = contact(T, Host),
        SilentEndpoint = maps:get(endpoint, Second),
        {Pending, waiting, none} = observation(T, Second, quod_time:mono_ms()),
        %% The earlier endpoint still authenticates the SAME key. Only the
        %% current endpoint's actual completion can satisfy this dependency.
        _ = initial(Socket, quod_time:mono_ms() + 4000),
        {suspected_unreachable, _} = completion(T, Key, Pending),
        Host = install_contact(Key, SilentEndpoint, 3, withdrawn),
        unknown = contact(T, Host),
        Withdrawn = quod_quic:confirm_peer_loss(T, Second, quod_time:mono_ms()),
        receive {Withdrawn, {unknown, route_unavailable}} -> ok
        after 1000 -> ct:fail(withdrawal_did_not_fence_retained_contact) end,
        Host = install_contact(Key, Endpoint, 4, hosted),
        {ok, Third} = contact(T, Host),
        Sup = quod_reg:where({sup, node}),
        ok = supervisor:terminate_child(Sup, quod_directory),
        {ok, _} = supervisor:restart_child(Sup, quod_directory),
        false = quod_directory:node_contact_current(Third),
        unknown = contact(T, Host)
    after
        quod_reg:unsubscribe({peer_loss, Key}),
        gen_udp:close(Socket),
        quod_agent_peer:stop(Peer)
    end.

blackhole() ->
    {ok, Socket} = gen_udp:open(0, [binary, {active, false}]),
    {ok, Port} = inet:port(Socket),
    {Socket, {"127.0.0.1", Port}}.

install_contact(Key, Endpoint, Generation, Kind) ->
    Ns = <<"observation-test:", (binary:encode_hex(Key))/binary>>,
    Anchor = crypto:hash(sha256, Ns),
    Host = {agent_instance_ref, Ns, Anchor, physical_node},
    {ok, Blob} = quod_wire_term:encode_canonical(Host),
    Hosted = case Kind of hosted -> [{Ns, Anchor, observer, node}]; withdrawn -> [] end,
    {ok, _} = quod_directory:install_generation(
        #{author => {node_actor, Blob}, node_key => Key, endpoint => Endpoint,
          epoch => 1, generation => Generation, page => 0, last => true, hosted => Hosted}),
    Host.

contact(T, Host) ->
    Ref = quod_quic:peer_contact(T, Host),
    receive {Ref, {peer_contact, T, Host, Result}} -> Result
    after 1000 -> ct:fail(no_contact_snapshot) end.

observation(T, #{node_key := Key} = Contact, Since) ->
    Ref = quod_quic:confirm_peer_loss(T, Contact, Since),
    receive {Ref, {peer_loss, T, Key, Episode, Status, At}} -> {Episode, Status, At}
    after 1000 -> ct:fail(no_observation_snapshot) end.

completion(T, Key, Episode) ->
    receive
        {peer_loss, T, Key, Episode, Status, At} when is_integer(At) -> {Status, At}
    after 8000 -> ct:fail(no_physical_completion) end.

initial(Socket, Deadline) ->
    case gen_udp:recv(Socket, 0, max(0, Deadline - quod_time:mono_ms())) of
        {ok, {_, _, <<1:1, 1:1, 0:2, _:4, 1:32, Length:8, Cid:Length/binary, _/binary>>}} -> Cid;
        {ok, _} -> initial(Socket, Deadline);
        {error, Reason} -> ct:fail({no_actual_connection_attempt, Reason})
    end.
