-module(class_selection_probe).
-export([start/0]).
-define(L, quod_lifecycle_single_path_tests).

%% Test-only endpoint. Reuses the qualified M1a factory and the same production
%% founding, enrollment, atomic setup, auth, vault and view owners.
start() ->
    F = ?L:setup(genesis),
    #{dir := Dir, manager := Manager} = F,
    {ok,Network} = quod_ontology:network_identity(),
    {ok,Auth} = quod_client_auth:start_link(), unlink(Auth),
    Unlock = filename:join(Dir,"m1b-unlock"),
    ok = quod_file:write_atomic(Unlock,crypto:strong_rand_bytes(32),8#600),
    {ok,Vault} = quod_agent_vault:start_link(#{directory=>filename:join(Dir,"vault"),unlock_file=>Unlock}), unlink(Vault),
    try
        #{node := Node,user := UserClass} = ?L:m1a_foundations(F),
        User = ?L:m1a_setup(?L:m1a_signup(Network,UserClass,Node)),
        io:format("CLASSES ~tp~n",[?L:m1a_read(User,{gui_operation_classes,{0}})])
    after ?L:stop_process(Auth), ?L:cleanup(F), ?L:stop_process(Vault) end.

