-module(quod_scope_session_tests).

-include_lib("eunit/include/eunit.hrl").

startup_failure_is_asynchronous_and_monitored_test() ->
    ProofId = crypto:strong_rand_bytes(32),
    Anchor = crypto:strong_rand_bytes(32),
    {Handle, WorkerMRef} =
        quod_scope_session:start(
          ProofId, self(), <<"quod:broken-scope">>, Anchor, 0,
          {not_an_erlog_state}, self(), #{}),
    Worker = quod_scope_session:pid(Handle),
    receive
        {'DOWN', WorkerMRef, process, Worker, _Reason} -> ok
    after 1000 ->
        ?assert(false)
    end.
