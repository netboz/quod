-module(quod_relay).
-moduledoc """
Transaction-relay wire framing and bounded completed-result cache.

The outer consensus envelope is decoded once. Relay metadata uses safe ETF;
ordinary consensus payloads retain the trusted-committee atom posture.
""".

-export([encode/2, decode_frame/2, put_result/3, prune_results/1]).

-define(MAX_RESULTS, 2048).
-define(MAX_CANONICAL_BYTES, (256 * 1024)).

-spec encode(binary(), term()) -> binary().
encode(Ns, Relay) ->
    Inner = term_to_binary(Relay, [deterministic]),
    term_to_binary({sx_relay, Ns, Inner}, [deterministic]).

-spec decode_frame(binary(), binary()) ->
        {relay, term()} | {consensus, term()} | error.
decode_frame(Payload, Ns) ->
    try binary_to_term(Payload, [safe]) of
        {sx_relay, Ns, Inner} when is_binary(Inner) ->
            decode_relay_inner(Inner);
        {sx, Ns, Inner} when is_binary(Inner) ->
            try {consensus, binary_to_term(Inner)}
            catch _:_ -> error
            end;
        _ ->
            error
    catch
        _:_ -> error
    end.

decode_relay_inner(Inner) ->
    try binary_to_term(Inner, [safe]) of
        Relay ->
            case valid_wire(Relay) of
                true  -> {relay, Relay};
                false -> error
            end
    catch
        _:_ -> error
    end.

valid_wire({relay_submit, ReqId,
            {submit, Author, Signature, Canonical}, TraceCarrier})
  when is_binary(ReqId), byte_size(ReqId) =:= 16,
       is_binary(Author), byte_size(Author) =:= 32,
       is_binary(Signature), byte_size(Signature) =:= 64,
       is_binary(Canonical), byte_size(Canonical) =< ?MAX_CANONICAL_BYTES ->
    quod_trace:valid_carrier(TraceCarrier);
valid_wire({relay_result, ReqId, Result})
  when is_binary(ReqId), byte_size(ReqId) =:= 16 ->
    valid_result(Result);
valid_wire(_) ->
    false.

valid_result({ok, Slot}) ->
    is_integer(Slot) andalso Slot >= 1 andalso Slot =< 16#FFFFFFFFFFFFFFFF;
valid_result({error, Reason})
  when Reason =:= busy; Reason =:= skipped; Reason =:= bad_change;
       Reason =:= too_large; Reason =:= stale_seq ->
    true;
valid_result({error, not_in_charge, Hint}) ->
    Hint =:= none orelse Hint =:= unavailable orelse
        (is_binary(Hint) andalso byte_size(Hint) =:= 32);
valid_result(_) ->
    false.

-spec put_result(binary(), {term(), term(), integer()}, map()) -> map().
put_result(ReqId, Result, Results) ->
    Live = prune_results(Results),
    trim(Live#{ReqId => Result}).

-spec prune_results(map()) -> map().
prune_results(Results) ->
    Now = quod_time:mono_ms(),
    maps:filter(fun(_Id, {_Peer, _Reply, Expires}) -> Expires > Now end,
                Results).

trim(Results) when map_size(Results) =< ?MAX_RESULTS ->
    Results;
trim(Results) ->
    Newest =
        lists:sublist(
          lists:sort(
            fun({_A, {_, _, EA}}, {_B, {_, _, EB}}) -> EA > EB end,
            maps:to_list(Results)),
          ?MAX_RESULTS),
    maps:from_list(Newest).
