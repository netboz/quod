-module(quod_peer_capacity_SUITE).
-include_lib("common_test/include/ct.hrl").
-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2,
         acquired_contact_is_retained_before_loss_subscription/1,
         last_consumer_death_releases_capacity/1,
         dead_queued_acquisition_preserves_capacity_wakeup/1,
         withdrawn_contact_releases_waiting_observers/1,
         idle_contact_survives_until_acquisition_pressure/1,
         node_key_rotation_replaces_the_retained_slot/1]).

all() -> [acquired_contact_is_retained_before_loss_subscription,
          last_consumer_death_releases_capacity,
          dead_queued_acquisition_preserves_capacity_wakeup,
          withdrawn_contact_releases_waiting_observers,
          idle_contact_survives_until_acquisition_pressure,
          node_key_rotation_replaces_the_retained_slot].

init_per_suite(Config) ->
    application:load(quod),
    Previous = application:get_env(quod, peer_observation_limit),
    ok = application:set_env(quod, peer_observation_limit, 1),
    [{previous_limit, Previous} | quod_quic_SUITE:init_per_suite(Config)].

end_per_suite(Config) ->
    ok = quod_quic_SUITE:end_per_suite(Config),
    case ?config(previous_limit, Config) of
        undefined -> application:unset_env(quod, peer_observation_limit);
        {ok, Value} -> application:set_env(quod, peer_observation_limit, Value)
    end.

init_per_testcase(_, Config) ->
    Sup = quod_reg:where({sup, node}),
    ok = supervisor:terminate_child(Sup, quod_quic),
    {ok, _} = supervisor:restart_child(Sup, quod_quic),
    Config.

acquired_contact_is_retained_before_loss_subscription(_Config) ->
    T = quod_reg:where({transport, node}),
    {A, _} = install_contact(),
    {B, _} = install_contact(),
    true = quod_reg:subscribe_tracked({node_identity_route, A}),
    true = quod_reg:subscribe_tracked({node_identity_route, B}),
    true = quod_reg:subscribe({peer_observation_capacity, T}),
    try
        {ok, Contact} = contact(T, A),
        %% There is deliberately no peer_loss subscription yet. The route
        %% interest already protects the just-acquired exact contact.
        {blocked, capacity} = contact(T, B),
        {ok, Contact} = contact(T, A),
        %% A queued zero from a prior interest incarnation cannot release an
        %% already renewed interest. The following reply is a processing fence.
        T ! {gproc, resource_on_zero, l, {node_identity_route, A}, T},
        {blocked, capacity} = contact(T, B),
        receive
            {peer_observation_capacity, T, available} -> ct:fail(stale_zero_woke_capacity)
        after 0 -> ok
        end,
        true = quod_reg:unsubscribe_tracked({node_identity_route, A}),
        capacity_released(T),
        {ok, _} = contact(T, B)
    after
        unsubscribe_if_present(A),
        unsubscribe_if_present(B),
        quod_reg:unsubscribe({peer_observation_capacity, T})
    end.

last_consumer_death_releases_capacity(_Config) ->
    T = quod_reg:where({transport, node}),
    {A, _} = install_contact(),
    {B, _} = install_contact(),
    Parent = self(),
    {Consumer, Monitor} = spawn_monitor(fun() ->
        true = quod_reg:subscribe_tracked({node_identity_route, A}),
        {ok, C} = contact(T, A),
        Parent ! {acquired, self(), C},
        receive stop -> ok end
    end),
    receive {acquired, Consumer, _} -> ok
    after 1000 -> ct:fail(consumer_not_acquired) end,
    true = quod_reg:subscribe_tracked({node_identity_route, A}),
    true = quod_reg:subscribe_tracked({node_identity_route, B}),
    true = quod_reg:subscribe({peer_observation_capacity, T}),
    try
        {blocked, capacity} = contact(T, B),
        true = quod_reg:unsubscribe_tracked({node_identity_route, A}),
        %% Another ontology still depends on A: releasing only one consumer
        %% must not permit pressure to evict the shared physical contact.
        {blocked, capacity} = contact(T, B),
        Consumer ! stop,
        receive {'DOWN', Monitor, process, Consumer, normal} -> ok
        after 1000 -> ct:fail(consumer_not_stopped) end,
        capacity_released(T),
        {ok, _} = contact(T, B)
    after
        Consumer ! stop,
        unsubscribe_if_present(A),
        unsubscribe_if_present(B),
        quod_reg:unsubscribe({peer_observation_capacity, T})
    end.

dead_queued_acquisition_preserves_capacity_wakeup(_Config) ->
    T = quod_reg:where({transport, node}),
    {A, _} = install_contact(),
    {B, _} = install_contact(),
    {C, _} = install_contact(),
    true = quod_reg:subscribe_tracked({node_identity_route, A}),
    true = quod_reg:subscribe_tracked({node_identity_route, B}),
    true = quod_reg:subscribe({peer_observation_capacity, T}),
    try
        {ok, _} = contact(T, A),
        {blocked, capacity} = contact(T, B),
        ok = sys:suspend(T),
        try
            Parent = self(),
            {Consumer, Monitor} = spawn_monitor(fun() ->
                true = quod_reg:subscribe_tracked({node_identity_route, C}),
                Ref = quod_quic:peer_contact(T, C),
                true = quod_reg:unsubscribe_tracked({node_identity_route, C}),
                Parent ! {queued_acquisition, self(), Ref}
            end),
            Ref = receive {queued_acquisition, Consumer, R} -> R
            after 1000 -> ct:fail(acquisition_not_queued) end,
            receive {'DOWN', Monitor, process, Consumer, normal} -> ok
            after 1000 -> ct:fail(queued_caller_not_stopped) end,
            %% Delivery evidence fixes C's queued request before A's release.
            %% C will evict A and register an initially-zero counter. A's old
            %% zero notice no longer owns a retained contact at that point.
            {messages, Messages} = process_info(T, messages),
            true = lists:member({peer_contact, Consumer, Ref, C}, Messages),
            true = quod_reg:unsubscribe_tracked({node_identity_route, A})
        after ok = sys:resume(T) end,
        capacity_released(T),
        {ok, _} = contact(T, B)
    after
        unsubscribe_if_present(A),
        unsubscribe_if_present(B),
        quod_reg:unsubscribe({peer_observation_capacity, T})
    end.

withdrawn_contact_releases_waiting_observers(_Config) ->
    T = quod_reg:where({transport, node}),
    {A, KeyA} = install_contact(),
    {B, KeyB} = install_contact(),
    {C, _} = install_contact(),
    true = quod_reg:subscribe_tracked({node_identity_route, A}),
    true = quod_reg:subscribe_tracked({node_identity_route, B}),
    true = quod_reg:subscribe_tracked({node_identity_route, C}),
    true = quod_reg:subscribe({peer_observation_capacity, T}),
    try
        {ok, Old} = contact(T, A),
        {blocked, capacity} = contact(T, B),
        install_contact(A, KeyA, 2, []),
        false = quod_directory:node_contact_current(Old),
        %% The committed assignment can remain desired after withdrawal.
        %% Its existing route-change acquisition must retire unusable custody
        %% and wake B even though A's tracked interest is still installed.
        unknown = contact(T, A),
        capacity_released(T),
        {ok, _} = contact(T, B),
        {blocked, capacity} = contact(T, C),
        install_contact(B, KeyB, 2, []),
        %% Pressure also collects a stale contact before its own observer
        %% processes the route-change notice; current expired leases differ.
        {ok, _} = contact(T, C)
    after
        unsubscribe_if_present(A),
        unsubscribe_if_present(B),
        unsubscribe_if_present(C),
        quod_reg:unsubscribe({peer_observation_capacity, T})
    end.

idle_contact_survives_until_acquisition_pressure(_Config) ->
    T = quod_reg:where({transport, node}),
    {A, _} = install_contact(),
    true = quod_reg:subscribe_tracked({node_identity_route, A}),
    true = quod_reg:subscribe({peer_observation_capacity, T}),
    {ok, Contact} = contact(T, A),
    true = quod_reg:unsubscribe_tracked({node_identity_route, A}),
    capacity_released(T),
    ok = quod_directory:expire(maps:get(expiry, Contact)),
    unknown = quod_directory:node_transport_route(A),
    true = quod_reg:subscribe_tracked({node_identity_route, A}),
    {ok, Contact} = contact(T, A),
    true = quod_reg:unsubscribe_tracked({node_identity_route, A}),
    capacity_released(T),
    {B, _} = install_contact(),
    true = quod_reg:subscribe_tracked({node_identity_route, B}),
    try
        {ok, _} = contact(T, B),
        %% Pressure may discard an idle contact, but an expired route cannot
        %% recreate it. No directory renewal or private copy repairs the read.
        true = quod_reg:subscribe_tracked({node_identity_route, A}),
        unknown = contact(T, A)
    after
        unsubscribe_if_present(A),
        unsubscribe_if_present(B),
        quod_reg:unsubscribe({peer_observation_capacity, T})
    end.

node_key_rotation_replaces_the_retained_slot(_Config) ->
    T = quod_reg:where({transport, node}),
    {Host, Key} = install_contact(),
    true = quod_reg:subscribe_tracked({node_identity_route, Host}),
    try
        {ok, Old} = contact(T, Host),
        Key = maps:get(node_key, Old),
        NextKey = crypto:strong_rand_bytes(32),
        install_contact(Host, NextKey, 2),
        Owner = quod_reg:where({directory, node}),
        receive {node_identity_route_changed, Owner, Host} -> ok
        after 1000 -> ct:fail(tracked_route_event_not_delivered) end,
        {ok, Current} = contact(T, Host),
        NextKey = maps:get(node_key, Current),
        false = quod_directory:node_contact_current(Old),
        true = quod_directory:node_contact_current(Current),
        %% The node actor still has exactly one tracked counter and slot.
        1 = gproc:lookup_value({rc, l, {node_identity_route, Host}}),
        {ok, Current} = contact(T, Host)
    after quod_reg:unsubscribe_tracked({node_identity_route, Host}) end.

install_contact() ->
    Key = crypto:strong_rand_bytes(32),
    Ns = <<"peer-capacity:", (binary:encode_hex(Key))/binary>>,
    Host = {agent_instance_ref, Ns, crypto:hash(sha256, Ns), node},
    install_contact(Host, Key, 1),
    {Host, Key}.

install_contact({agent_instance_ref, Ns, Anchor, _} = Host, Key, Generation) ->
    install_contact(Host, Key, Generation, [{Ns, Anchor, observer, node}]).

install_contact(Host, Key, Generation, Hosted) ->
    {ok, Blob} = quod_wire_term:encode_canonical(Host),
    {ok, _} = quod_directory:install_generation(
        #{author => {node_actor, Blob}, node_key => Key,
          endpoint => {"127.0.0.1", 14599}, epoch => 1, generation => Generation,
          page => 0, last => true, hosted => Hosted}),
    ok.

contact(T, Host) ->
    Ref = quod_quic:peer_contact(T, Host),
    receive {Ref, {peer_contact, T, Host, Result}} -> Result
    after 1000 -> ct:fail(no_contact_snapshot) end.

capacity_released(T) ->
    receive {peer_observation_capacity, T, available} -> ok
    after 1000 -> ct:fail(no_capacity_release_notification) end.

unsubscribe_if_present(Host) ->
    case lists:member(self(), quod_reg:tracked_subscribers({node_identity_route, Host})) of
        true -> quod_reg:unsubscribe_tracked({node_identity_route, Host});
        false -> ok
    end.
