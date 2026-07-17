-module(quod_brahms_population).
-moduledoc """
Bounded, authenticated live-population sketch for Brahms.

Every production node periodically signs a short heartbeat containing its stable
Ed25519 public key and timestamp.  Brahms gossips the lowest-ranked valid
heartbeats, not a membership list or any ontology data.  A heartbeat can only
be refreshed by its owner, so forwarding cannot keep a dead node alive.

The sketch is exact while the live population fits in `k` entries.  Above that,
the bottom-`k` estimator has relative standard error close to `1/sqrt(k)`.
`reserve` keeps replacements locally when low-ranked members expire; it is
bounded and never approaches a knowledge-base copy.
""".

-export([new/4, tick/2, merge/2, records/1, self_record/1, leave_record/2, estimate/1, count/1]).
-export_type([population/0, record/0]).

-define(DOMAIN, <<"quod-brahms-population-v1">>).
-define(POW64, 16#10000000000000000).

-record(p, {identity = undefined :: undefined | #{pubkey := binary(), key := term()},
            k :: pos_integer(),
            reserve :: pos_integer(),
            ttl_ms :: pos_integer(),
            max_future_ms :: non_neg_integer(),
            entries = #{} :: #{binary() => record()}}).

-type record() :: {population_v1 | population_leave_v1, binary(), non_neg_integer(), binary()}.
-opaque population() :: #p{}.

-spec new(undefined | #{pubkey := binary(), key := term()}, pos_integer(), pos_integer(),
          pos_integer()) -> population().
new(Identity, K, TtlMs, MaxFutureMs)
  when is_integer(K), K > 0, is_integer(TtlMs), TtlMs > 0,
       is_integer(MaxFutureMs), MaxFutureMs >= 0 ->
    #p{identity = valid_identity(Identity), k = K, reserve = 4 * K,
       ttl_ms = TtlMs, max_future_ms = MaxFutureMs}.

-doc "Refresh this node's signed heartbeat and expire old records.".
-spec tick(population(), non_neg_integer()) -> population().
tick(P = #p{identity = undefined}, Now) -> prune(P, Now);
tick(P = #p{identity = #{pubkey := Pub, key := Key}}, Now) ->
    Sig = quod_identity:sign(signed_bytes(alive, Pub, Now), Key),
    merge([{population_v1, Pub, Now, Sig}], prune(P, Now)).

-doc "Merge signed owner heartbeats. Invalid, expired, and duplicate records are ignored.".
-spec merge([term()], population()) -> population().
merge(Records, P0) when is_list(Records) ->
    P = prune(P0, now_ms()),
    trim(lists:foldl(fun merge_one/2, P, Records));
merge(_, P) -> P.

-doc "The bounded bottom-k heartbeat records that Brahms sends in pull responses.".
-spec records(population()) -> [record()].
records(P0) ->
    P = prune(P0, now_ms()),
    %% A leave is short-lived but must travel with the live sample: otherwise an old forwarded heartbeat
    %% could re-add a gracefully departed identity before its normal TTL expires.  Keep the two bounded
    %% pools separate so leaves never crowd live bottom-k records out of the estimator.
    lists:sublist(sorted_records(P), P#p.k) ++ lists:sublist(sorted_leaves(P), P#p.k).

-spec self_record(population()) -> record() | none.
self_record(#p{identity = undefined}) -> none;
self_record(#p{identity = #{pubkey := Pub}, entries = Entries}) ->
    maps:get(Pub, Entries, none).

-doc "An owner-signed graceful departure. It is accepted only for the owner's public key.".
-spec leave_record(population(), non_neg_integer()) -> record() | none.
leave_record(#p{identity = undefined}, _Now) -> none;
leave_record(#p{identity = #{pubkey := Pub, key := Key}}, Now) ->
    {population_leave_v1, Pub, Now, quod_identity:sign(signed_bytes(leave, Pub, Now), Key)}.

-doc "Estimated total number of live nodes in the connected overlay component.".
-spec estimate(population()) -> non_neg_integer().
estimate(P0) ->
    P = prune(P0, now_ms()),
    Rs = sorted_records(P),
    case length(Rs) of
        Len when Len < P#p.k -> Len;
        _ ->
            {_Tag, Pub, _At, _Sig} = lists:nth(P#p.k, Rs),
            (P#p.k - 1) * ?POW64 div max(rank(Pub), 1)
    end.

-spec count(population()) -> non_neg_integer().
count(P0) -> map_size((prune(P0, now_ms()))#p.entries).

%% --- internal ------------------------------------------------------------

valid_identity(#{pubkey := Pub, key := Key}) when is_binary(Pub), byte_size(Pub) =:= 32 ->
    #{pubkey => Pub, key => Key};
valid_identity(_) -> undefined.

merge_one(R = {Tag, Pub, At, _Sig}, P = #p{entries = Entries})
  when (Tag =:= population_v1 orelse Tag =:= population_leave_v1),
       is_binary(Pub), byte_size(Pub) =:= 32, is_integer(At), At >= 0 ->
    case newer(R, maps:get(Pub, Entries, undefined)) of
        false -> P;
        true ->
            case valid(R, P, now_ms()) of
                true  -> P#p{entries = Entries#{Pub => R}};
                false -> P
            end
    end;
merge_one(_, P) -> P.

newer({_Tag, _Pub, _At, _Sig}, undefined) -> true;
newer({Tag, _Pub, At, _Sig}, {SeenTag, _SeenPub, SeenAt, _SeenSig}) when At =:= SeenAt ->
    Tag =:= population_leave_v1 andalso SeenTag =/= population_leave_v1;
newer({_Tag, _Pub, At, _Sig}, {_SeenTag, _SeenPub, SeenAt, _SeenSig}) -> At > SeenAt.

valid({population_v1, Pub, At, Sig}, #p{ttl_ms = Ttl, max_future_ms = Future}, Now) ->
    At =< Now + Future andalso Now - At =< Ttl andalso
        quod_identity:verify(Sig, signed_bytes(alive, Pub, At), Pub);
valid({population_leave_v1, Pub, At, Sig}, #p{ttl_ms = Ttl, max_future_ms = Future}, Now) ->
    At =< Now + Future andalso Now - At =< Ttl andalso
        quod_identity:verify(Sig, signed_bytes(leave, Pub, At), Pub).

prune(P = #p{entries = Entries, ttl_ms = Ttl, max_future_ms = Future}, Now) ->
    P#p{entries = maps:filter(
                    fun(_Pub, {_Tag, _P, At, _Sig}) ->
                        At =< Now + Future andalso Now - At =< Ttl
                    end, Entries)}.

trim(P = #p{entries = Entries, reserve = Reserve}) when map_size(Entries) =< Reserve -> P;
trim(P = #p{reserve = Reserve}) ->
    Keep = lists:sublist(sorted_entries(P), Reserve),
    P#p{entries = maps:from_list([{Pub, R} || R = {_Tag, Pub, _, _} <- Keep])}.

sorted_records(#p{entries = Entries}) ->
    lists:filter(fun({population_v1, _, _, _}) -> true; (_) -> false end, sorted_entries(Entries)).

sorted_leaves(#p{entries = Entries}) ->
    lists:filter(fun({population_leave_v1, _, _, _}) -> true; (_) -> false end, sorted_entries(Entries)).

sorted_entries(#p{entries = Entries}) -> sorted_entries(Entries);
sorted_entries(Entries) ->
    lists:sort(fun({_TagA, A, _, _}, {_TagB, B, _, _}) ->
                       {rank(A), A} < {rank(B), B}
               end,
               maps:values(Entries)).

rank(Pub) ->
    <<N:64/big, _/binary>> = crypto:hash(sha256, <<?DOMAIN/binary, Pub/binary>>),
    N.

signed_bytes(alive, Pub, At) -> term_to_binary({quod_brahms_population, 1, Pub, At}, [deterministic]);
signed_bytes(leave, Pub, At) -> term_to_binary({quod_brahms_population, 1, leave, Pub, At}, [deterministic]).

now_ms() -> erlang:system_time(millisecond).
