-module('schema-profile').
-export([run/0]).
run() ->
    Dir = filename:join("/tmp", "quod-gui-schema-profile-" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))),
    Terms = quod_prolog:read_terms("priv/ontologies/gui_instance.pl") ++
            quod_prolog:read_terms("test/fixtures/gui-components.pl"),
    Ctx = quod_lobby_tests:start(Dir, [], base_system_catalogue, Terms),
    {ontology_ref, Ns, Anchor} = maps:get(lobby, Ctx),
    try
        Query = {'::', Ns, {',', {current_ontology_identity, Ns, Anchor}, {gui_schema, settings, {0}, {1}}}},
        Samples = [begin
            {Micros, {Reply, Profile}} = timer:tc(fun() ->
                tprof:profile(fun() -> quod_lobby_tests:read(Ctx, Query) end,
                    #{type => call_count, report => return, timeout => 30000,
                      pattern => [{erlog_int, prove_goal, 3}, {erlog_int, unify, 3},
                                  {quod_proof_session, open, 6}]})
            end),
            {ok, [_], _} = Reply,
            {Round, Micros, Profile}
        end || Round <- [first, repeated]],
        io:format("SCHEMA_PROFILE ~p~n", [Samples])
    after quod_lobby_tests:stop(Ctx), file:del_dir_r(Dir) end.
