-module(quod_brahms_nest).
-moduledoc """
Network-size estimator (`n̂`) — a windowed **KMV** (k-minimum-values) distinct
counter over recently **directly observed** node identities.

Brahms prescribes per-node structure sizes of `Θ(∛n)` and notes a node can
estimate `n` from its own sample (each id is seen with probability `1/n`). This
module turns that into a concrete estimate so `m:quod_brahms` can later size the
view/sample from it. **Phase 1 only exposes `n̂` as a metric; nothing is sized
from it yet.**

## How it works

Hash every observed id to a 64-bit value with a *secret-keyed* HMAC (like
`m:quod_brahms_sampler`, so a flooder cannot bias it), and keep the `K` smallest
**distinct** hashes. The K-th smallest, `v_K`, concentrates around `K/n`, giving
the unbiased estimator `n̂ = (K-1) · 2^64 / v_K`. While fewer than `K` distinct
ids have been seen the count is **exact** (so at small scale `n̂` is just the live
id count). Relative error is `≈ 1/√K`.

## Windowing

A plain KMV would also count *departed* ids forever. So the sketch is windowed:
`rotate/1` (called once per `nest_window` rounds by `m:quod_brahms`) shifts the
current window to `prev` and starts a fresh `cur`; `estimate/1` reports over
`cur ∪ prev`. The local identity is re-observed every round, and a remote identity
is observed only when it appears in an authenticated direct link header. Third-party
gossip is intentionally excluded: an old address may be useful as a reconnection
candidate, but it is not evidence that its node is still alive. A departed identity
therefore ages out within ~two windows instead of being kept alive by stale views.
""".

-export([new/1, observe/2, observe_all/2, rotate/1, estimate/1]).
-export_type([nest/0]).

-define(KEYBYTES, 16).
-define(POW64, 16#10000000000000000).   %% 2^64

-record(nest, {key  :: binary(),
               k    :: pos_integer(),
               cur  = [] :: [non_neg_integer()],   %% ≤K smallest DISTINCT hashes this window (asc)
               prev = [] :: [non_neg_integer()]}). %% same, previous window

-opaque nest() :: #nest{}.

-doc "A fresh estimator keeping the `K` smallest hashes, with a secret key.".
-spec new(pos_integer()) -> nest().
new(K) when is_integer(K), K > 0 ->
    #nest{key = crypto:strong_rand_bytes(?KEYBYTES), k = K}.

-doc "Feed one id into the current window.".
-spec observe(term(), nest()) -> nest().
observe(Id, N = #nest{key = Key, k = K, cur = Cur}) ->
    H = h(Key, term_to_binary(Id, [deterministic])),
    N#nest{cur = kmin_insert(H, K, Cur)}.

-doc "Feed a batch of ids (order-independent).".
-spec observe_all([term()], nest()) -> nest().
observe_all(Ids, N) -> lists:foldl(fun observe/2, N, Ids).

-doc "Close the current window: it becomes `prev`, a fresh `cur` begins.".
-spec rotate(nest()) -> nest().
rotate(N = #nest{cur = Cur}) -> N#nest{prev = Cur, cur = []}.

-doc "Estimated network size over the current ∪ previous window.".
-spec estimate(nest()) -> non_neg_integer().
estimate(#nest{cur = Cur, prev = Prev, k = K}) ->
    kmin_estimate(lists:sublist(lists:umerge(Cur, Prev), K), K).

%% --- internal ------------------------------------------------------------

%% Keep the K smallest DISTINCT values (both lists kept sorted ascending).
kmin_insert(H, K, L) ->
    case lists:member(H, L) of
        true  -> L;
        false -> lists:sublist(lists:merge([H], L), K)
    end.

%% KMV cardinality from the K smallest hashes (ascending). Exact while < K seen.
kmin_estimate(L, K) ->
    case length(L) of
        Len when Len < K -> Len;
        _ ->
            VK = lists:nth(K, L),                 %% K-th smallest 64-bit hash
            (K - 1) * ?POW64 div max(VK, 1)       %% (K-1)·2^64 / v_K, integer
    end.

%% Secret-keyed 64-bit hash (HMAC-SHA256), mirroring m:quod_brahms_sampler.
h(Key, Bin) ->
    <<N:64/big, _/binary>> = crypto:mac(hmac, sha256, Key, Bin),
    N.
