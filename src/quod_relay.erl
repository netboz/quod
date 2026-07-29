-module(quod_relay).
-moduledoc """
Transaction-relay wire framing and bounded completed-result cache.

Relay metadata uses safe ETF. Consensus payloads retain the
trusted-committee atom posture, but each strict decoder accepts only its
dedicated transport channel's envelope.
""".

-export([encode/2, decode_consensus_frame/2,
         decode_relay_frame/2,
         put_result/3, prune_results/1]).

-define(MAX_RESULTS, 2048).
-define(MAX_CANONICAL_BYTES, (256 * 1024)).

-spec encode(binary(), term()) -> binary().
encode(Ns, Relay) ->
    Inner = term_to_binary(Relay, [deterministic]),
    term_to_binary({sx_relay, Ns, Inner}, [deterministic]).

-spec decode_consensus_frame(binary(), binary()) ->
        {consensus, term()} | error.
decode_consensus_frame(Payload, Ns) ->
    case decode_outer(Payload, Ns) of
        {consensus, Inner} ->
            try {consensus, binary_to_term(Inner)}
            catch _:_ -> error
            end;
        _ ->
            error
    end.

-doc """
Decode only the bounded safe relay envelope.

Observers use this path to recover attempts from durable history without ever
decoding the unrestricted consensus inner term they are not permitted to act
on.
""".
-spec decode_relay_frame(binary(), binary()) -> {relay, term()} | error.
decode_relay_frame(Payload, Ns) ->
    case decode_outer(Payload, Ns) of
        {relay, Inner} -> decode_relay_inner(Inner);
        _ -> error
    end.

decode_outer(Payload, Ns) ->
    try binary_to_term(Payload, [safe]) of
        {sx_relay, Ns, Inner} when is_binary(Inner) -> {relay, Inner};
        {sx2, Ns, Inner} when is_binary(Inner) -> {consensus, Inner};
        _ -> error
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

valid_wire({relay_submit, SubmissionId, AttemptId, CommitteeId, TargetSlot,
            {submit, Author, Signature, Canonical}, TraceCarrier})
  when is_binary(SubmissionId), byte_size(SubmissionId) =:= 16,
       is_binary(AttemptId), byte_size(AttemptId) =:= 16,
       is_binary(CommitteeId), byte_size(CommitteeId) =:= 32,
       is_integer(TargetSlot), TargetSlot >= 1,
       TargetSlot =< 16#FFFFFFFFFFFFFFFF,
       is_binary(Author), byte_size(Author) =:= 32,
       is_binary(Signature), byte_size(Signature) =:= 64,
       is_binary(Canonical), byte_size(Canonical) =< ?MAX_CANONICAL_BYTES ->
    quod_trace:valid_carrier(TraceCarrier);
valid_wire({relay_result, SubmissionId, AttemptId, CommitteeId,
            TargetSlot, Result})
  when is_binary(SubmissionId), byte_size(SubmissionId) =:= 16,
       is_binary(AttemptId), byte_size(AttemptId) =:= 16,
       is_binary(CommitteeId), byte_size(CommitteeId) =:= 32,
       is_integer(TargetSlot), TargetSlot >= 1,
       TargetSlot =< 16#FFFFFFFFFFFFFFFF ->
    valid_result(Result);
valid_wire({relay_accepted, SubmissionId, AttemptId, CommitteeId, TargetSlot})
  when is_binary(SubmissionId), byte_size(SubmissionId) =:= 16,
       is_binary(AttemptId), byte_size(AttemptId) =:= 16,
       is_binary(CommitteeId), byte_size(CommitteeId) =:= 32,
       is_integer(TargetSlot), TargetSlot >= 1,
       TargetSlot =< 16#FFFFFFFFFFFFFFFF ->
    true;
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
put_result(Key, Result, Results) ->
    Live = prune_results(Results),
    case maps:is_key(Key, Live) of
        true  -> Live;
        false -> trim(Live#{Key => Result})
    end.

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
