-module(quod_peer_route).
-moduledoc """
Ordered address selection inside an existing peer worker. This library owns no
process or transport: the caller pins the peer, performs I/O and interprets the
reply. A route is not another signer or a second copy of an ontology's state.
""".
-export([walk/5]).

-doc """
Try addresses under one absolute monotonic deadline, sharing its remaining
allowance among alternatives. Select returns `done` or carries the next fallback
result. Exhaustion/expiry returns that fallback unchanged. Exceptions propagate;
the existing worker owns cancellation and the caller checks result freshness.
""".
-spec walk([Endpoint], integer(), fun((Endpoint, pos_integer()) -> Reply),
           fun((Reply, Result) -> {done, Result} | {next, Result}), Result) -> Result.
walk([], _Deadline, _Attempt, _Select, Last) -> Last;
walk([Endpoint | Rest], Deadline, Attempt, Select, Last) ->
    case Deadline - quod_time:mono_ms() of
        Remaining when Remaining =< 0 -> Last;
        Remaining ->
            Timeout = max(1, Remaining div (length(Rest) + 1)),
            case Select(Attempt(Endpoint, Timeout), Last) of
                {done, Result} -> Result;
                {next, Next} -> walk(Rest, Deadline, Attempt, Select, Next)
            end
    end.
