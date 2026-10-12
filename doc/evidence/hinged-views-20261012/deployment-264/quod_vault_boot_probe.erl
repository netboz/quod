-module(quod_vault_boot_probe).
-export([run/0]).

run() ->
    try
        true = is_pid(quod_reg:where({agent_vault, node})),
        {ok, #{provider := none}} = application:get_env(quod, agent_vault),
        Ns = <<"quod:root">>,
        true = quod_reg:subscribe({runtime, Ns}),
        try ready(Ns, erlang:monotonic_time(millisecond) + 30000)
        after quod_reg:unsubscribe({runtime, Ns}) end,
        {ok, Version} = application:get_key(quod, vsn),
        Result = #{passed => true, version => list_to_binary(Version),
                   root_ready => true, vault_ready => true,
                   network_provider => disabled},
        ok = file:write_file("/evidence/boot-result.json", json:encode(Result)),
        ok = file:change_mode("/evidence/boot-result.json", 8#644),
        io:format("VAULT_BOOT_PROBE_OK~n"),
        init:stop()
    catch Class:Reason:Stack ->
        io:format("VAULT_BOOT_PROBE_FAILED ~p ~p ~p~n", [Class, Reason, Stack]),
        halt(1)
    end.

ready(Ns, Deadline) ->
    case quod_ontology:local_state(Ns) of
        {ok, ready} -> ok;
        Other ->
            receive _ -> ready(Ns, Deadline)
            after max(0, Deadline - erlang:monotonic_time(millisecond)) ->
                error({root_not_ready, Other})
            end
    end.
