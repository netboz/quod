-module(quod_readiness_probe_tests).
-include_lib("eunit/include/eunit.hrl").
repeated_creation_test_() ->
    [{integer_to_list(N), quod_space_creation_tests:authorization_and_lookup_failures_never_fall_back_test_()}
     || N <- lists:seq(1, 10)].
