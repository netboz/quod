-module(quod_sup_tests).
-include_lib("eunit/include/eunit.hrl").

%% init/1 returns valid, well-formed child specs without starting anything.
childspecs_test() ->
    {ok, {SupFlags, ChildSpecs}} = quod_sup:init([]),
    ?assertMatch(#{strategy := one_for_one}, SupFlags),
    ?assertEqual(ok, supervisor:check_childspecs(ChildSpecs)),
    ?assert(lists:any(fun(#{id := Id}) -> Id =:= quod_quic end, ChildSpecs)).
