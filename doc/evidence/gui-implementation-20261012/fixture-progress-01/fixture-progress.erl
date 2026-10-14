-module('fixture-progress').
-export([run/0]).
run() ->
    Dir = filename:join("/tmp", "quod-gui-progress-" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))),
    Ctx = quod_lobby_tests:start(Dir),
    {ontology_ref, Ns, Anchor} = maps:get(lobby,Ctx), Identity = {Ns,Anchor},
    try
        Before = quod_foreign_log:follow_request(Identity,progress),
        {error,unavailable} = Before,
        {ok,Owner} = quod_foreign_log:start_link(#{cache_dir => filename:join(Dir,"foreign")}),
        try
            {ok,Request} = quod_foreign_log:follow_request(Identity,progress),
            {reply,{ok,Follow}} = gen_server:wait_response(Request,5000),
            try
                Height = certified(Follow,Identity),
                {ok,_,{normalized,{committed,_,_}}} = quod_lobby_tests:submit(Ctx,execute,
                    {'::',Ns,{',',{current_ontology_identity,Ns,Anchor},{assertz,fixture_progress_probe}}}),
                Next = advanced(Follow,Identity,Height),
                #{projection_workers := 0} = quod_foreign_log:stats(),
                io:format("FIXTURE_PROGRESS ~p~n",[#{before => Before,initial => Height,updated => Next,projection_workers => 0}])
            after ok = quod_foreign_log:unfollow(Follow) end
        after gen_server:stop(Owner) end
    after quod_lobby_tests:stop(Ctx), file:del_dir_r(Dir) end.
certified(Follow,Identity) ->
    receive
        {quod_foreign_follow,Follow,Notice,Identity,{certified,Height,_}} ->
            ok = quod_foreign_log:ack(Follow,Notice), Height;
        {quod_foreign_follow,Follow,Notice,Identity,_Status} ->
            ok = quod_foreign_log:ack(Follow,Notice), certified(Follow,Identity)
    after 5000 -> error(missing_certified_progress) end.
advanced(Follow,Identity,Height) ->
    case certified(Follow,Identity) of
        Next when Next > Height -> Next;
        _ -> advanced(Follow,Identity,Height)
    end.
