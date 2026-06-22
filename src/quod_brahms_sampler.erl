-module(quod_brahms_sampler).
-moduledoc """
Brahms min-wise sampler — the uniform, flood-resistant half of Brahms.

A sampler is `K` independent **slots**. Each slot holds a *secret* random key
that defines a hash `h_i`; for every id observed, the slot keeps the id with the
minimum `h_i(id)` seen so far. Because the key is secret and HMAC behaves like a
random oracle, the retained id is ~uniform over the **distinct** ids observed,
*independent of how many times each appears*. So a Byzantine node that floods its
id a million times is no likelier to be sampled than an honest id seen once.

This is a **pure data structure** (no process): the per-namespace `gen_statem`
holds it as state and feeds it every id it sees.

## Scope of the guarantee

It resists **multiplicity** flooding (one id presented many times). It does NOT
resist **sybil** flooding (many *distinct* attacker ids) — every distinct id gets
equal weight by design, so bounding the number of distinct attacker ids is the
job of the gossip/admission layer above, not the sampler.

> #### Security note {: .warning }
>
> The hash MUST be a secret-keyed, oracle-like function. Using `phash2` (or any
> public/predictable hash) lets a flooder craft ids that always win the min and
> breaks the guarantee. We use HMAC-SHA256 keyed by a per-slot secret.

`undefined` is reserved as the empty-slot marker and must not be used as a node id.
""".

-export([new/1, observe/2, observe_all/2, sample/1, invalidate/2, slots/1]).
-export_type([sampler/0]).

-define(KEYBYTES, 16).

-record(slot, {key  :: binary(),
               id   :: term() | undefined,
               hash :: non_neg_integer() | undefined}).

-opaque sampler() :: [#slot{}].

-doc "A sampler of `K` empty slots, each with a fresh secret key.".
-spec new(pos_integer()) -> sampler().
new(K) when is_integer(K), K > 0 ->
    [fresh_slot() || _ <- lists:seq(1, K)].

-doc "Present `Id` to every slot; each keeps its own min-hash id.".
-spec observe(term(), sampler()) -> sampler().
observe(Id, Slots) ->
    Bin = term_to_binary(Id, [deterministic]),     %% hash the same bytes once per slot
    [observe_slot(Id, Bin, S) || S <- Slots].

-doc "Present a batch of ids (order-independent).".
-spec observe_all([term()], sampler()) -> sampler().
observe_all(Ids, Slots) ->
    lists:foldl(fun observe/2, Slots, Ids).

-doc """
The currently sampled ids as a **multiset** in slot order (empty slots skipped;
duplicates kept — two slots legitimately collide). The caller dedupes if it wants
a set.
""".
-spec sample(sampler()) -> [term()].
sample(Slots) ->
    [Id || #slot{id = Id} <- Slots, Id =/= undefined].

-doc """
A sampled id failed liveness — reset every slot holding it so it re-samples from
scratch. Resetting mints a **new key** (i.e. a new hash function), which is what
Brahms specifies for a sampler reset.
""".
-spec invalidate(term(), sampler()) -> sampler().
invalidate(Id, Slots) ->
    [case S of #slot{id = Id} -> fresh_slot(); _ -> S end || S <- Slots].

-doc "Number of slots `K`.".
-spec slots(sampler()) -> non_neg_integer().
slots(Slots) -> length(Slots).

%% --- internal ------------------------------------------------------------

fresh_slot() ->
    #slot{key = crypto:strong_rand_bytes(?KEYBYTES), id = undefined, hash = undefined}.

observe_slot(Id, Bin, #slot{key = Key, id = CurId, hash = Best} = S) ->
    H = h(Key, Bin),
    if
        Best =:= undefined  -> S#slot{id = Id, hash = H};
        H < Best            -> S#slot{id = Id, hash = H};
        %% deterministic tie-break on a hash collision -> result is a pure
        %% function of the SET observed, never of arrival order.
        H =:= Best, Id < CurId -> S#slot{id = Id, hash = H};
        true                -> S
    end.

%% Secret-keyed hash -> 64-bit integer. HMAC-SHA256 with the slot's secret key
%% means a flooder cannot predict (or craft) low-hashing ids.
h(Key, Bin) ->
    <<N:64/big, _/binary>> = crypto:mac(hmac, sha256, Key, Bin),
    N.
