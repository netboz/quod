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

-export([new/4, tick/2, merge/2, records/1, self_record/1, estimate/1, count/1]).
-export_type([population/0, record/0]).

-define(DOMAIN, <<"quod-brahms-population-v1">>).
-define(POW64, 16#10000000000000000).

-record(p, {identity = undefined :: undefined | #{pubkey := binary(), key := term()},
            k :: pos_integer(),
            reserve :: pos_integer(),
            ttl_ms :: pos_integer(),
            max_future_ms :: non_neg_integer(),
            entries = #{} :: #{binary() => record()}}).

-type record() :: {population_v1, binary(), non_neg_integer(), binary()}.
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
    Sig = quod_identity:sign(signed_bytes(Pub, Now), Key),
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
    lists:sublist(sorted_records(P), P#p.k).

-spec self_record(population()) -> record() | none.
self_record(#p{identity = undefined}) -> none;
self_record(#p{identity = #{pubkey := Pub}, entries = Entries}) ->
    maps:get(Pub, Entries, none).

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

merge_one(R = {population_v1, Pub, At, _Sig}, P = #p{entries = Entries})
  when is_binary(Pub), byte_size(Pub) =:= 32, is_integer(At), At >= 0 ->
    case maps:get(Pub, Entries, undefined) of
        {population_v1, Pub, SeenAt, _} when SeenAt >= At -> P;
        _ ->
            case valid(R, P, now_ms()) of
                true  -> P#p{entries = Entries#{Pub => R}};
                false -> P
            end
    end;
merge_one(_, P) -> P.

valid({population_v1, Pub, At, Sig}, #p{ttl_ms = Ttl, max_future_ms = Future}, Now) ->
    At =< Now + Future andalso Now - At =< Ttl andalso
        quod_identity:verify(Sig, signed_bytes(Pub, At), Pub).

prune(P = #p{entries = Entries, ttl_ms = Ttl, max_future_ms = Future}, Now) ->
    P#p{entries = maps:filter(
                    fun(_Pub, {population_v1, _P, At, _Sig}) ->
                        At =< Now + Future andalso Now - At =< Ttl
                    end, Entries)}.

trim(P = #p{entries = Entries, reserve = Reserve}) when map_size(Entries) =< Reserve -> P;
trim(P = #p{reserve = Reserve}) ->
    Keep = lists:sublist(sorted_records(P), Reserve),
    P#p{entries = maps:from_list([{Pub, R} || R = {population_v1, Pub, _, _} <- Keep])}.

sorted_records(#p{entries = Entries}) ->
    lists:sort(fun({population_v1, A, _, _}, {population_v1, B, _, _}) ->
                       {rank(A), A} < {rank(B), B}
               end,
               maps:values(Entries)).

rank(Pub) ->
    <<N:64/big, _/binary>> = crypto:hash(sha256, <<?DOMAIN/binary, Pub/binary>>),
    N.

signed_bytes(Pub, At) -> term_to_binary({quod_brahms_population, 1, Pub, At}, [deterministic]).

now_ms() -> erlang:system_time(millisecond).
