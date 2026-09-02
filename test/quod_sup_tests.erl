-module(quod_sup_tests).
-include_lib("eunit/include/eunit.hrl").

%% init/1 returns valid, well-formed child specs without starting anything.
childspecs_test() ->
    {ok, {SupFlags, ChildSpecs}} = quod_sup:init([]),
    ?assertMatch(#{strategy := one_for_one, intensity := 10, period := 10},
                 SupFlags),
    ?assertEqual(ok, supervisor:check_childspecs(ChildSpecs)),
    ?assert(lists:any(fun(#{id := Id}) -> Id =:= quod_quic end, ChildSpecs)),
    ?assert(lists:any(fun(#{id := Id}) -> Id =:= quod_foreign_log end,
                      ChildSpecs)),
    %% Catalogue worker faults deliberately kill this existing owner. Its
    %% ordinary permanent child spec and the bounded supervisor intensity are
    %% the visible unhealthy boundary for a persistent fault.
    ?assert(lists:any(
              fun(#{id := quod_namespace_manager} = Spec) ->
                      maps:get(restart, Spec, permanent) =:= permanent;
                 (_) -> false
              end, ChildSpecs)).
