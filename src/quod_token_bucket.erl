-module(quod_token_bucket).
-moduledoc """
Small pure token-bucket table used at authenticated network boundaries.

Tokens are stored in thousandths so refill remains integer-only.  The caller
owns the bounded map and supplies the shared rate, burst, cardinality, and idle
limits; this module owns the one admission rule so scope and DTX endpoints
cannot drift into subtly different implementations.
""".

-export([charge/7]).

-type bucket() :: {non_neg_integer(), integer(), integer()}.
-type table(Key) :: #{Key => bucket()}.

-doc """
Consume one token for `Key` at monotonic millisecond `Now`.

Returns the updated bounded table on both acceptance and refusal.  When the
table is full, idle entries are pruned before a new key is refused.
""".
-spec charge(Key, integer(), pos_integer(), pos_integer(), pos_integer(),
             pos_integer(), table(Key)) ->
          {ok, table(Key)} | {error, table(Key)}.
charge(Key, Now, RatePerSecond, Burst, MaxBuckets, IdleMs, Table0)
  when is_integer(Now), is_integer(RatePerSecond), RatePerSecond > 0,
       is_integer(Burst), Burst > 0,
       is_integer(MaxBuckets), MaxBuckets > 0,
       is_integer(IdleMs), IdleMs > 0, is_map(Table0) ->
    Table = maybe_prune(Now, MaxBuckets, IdleMs, Table0),
    case maps:find(Key, Table) of
        {ok, {Tokens0, LastRefill, _LastSeen}}
          when is_integer(Tokens0), Tokens0 >= 0,
               is_integer(LastRefill) ->
            Capacity = Burst * 1000,
            Tokens = min(
                       Capacity,
                       Tokens0 + max(0, Now - LastRefill) * RatePerSecond),
            case Tokens >= 1000 of
                true ->
                    {ok, Table#{Key => {Tokens - 1000, Now, Now}}};
                false ->
                    {error, Table#{Key => {Tokens, Now, Now}}}
            end;
        {ok, _Malformed} ->
            %% State is process-private, but fail closed if a bad fixture or
            %% future refactor corrupts one row.
            {error, maps:remove(Key, Table)};
        error when map_size(Table) >= MaxBuckets ->
            {error, Table};
        error ->
            {ok, Table#{Key => {(Burst - 1) * 1000, Now, Now}}}
    end;
charge(_Key, _Now, _RatePerSecond, _Burst, _MaxBuckets, _IdleMs, Table)
  when is_map(Table) ->
    {error, Table}.

maybe_prune(Now, MaxBuckets, IdleMs, Table)
  when map_size(Table) >= MaxBuckets ->
    maps:filter(
      fun(_Key, {_Tokens, _LastRefill, LastSeen})
            when is_integer(LastSeen) ->
              Now - LastSeen < IdleMs;
         (_Key, _Malformed) ->
              false
      end, Table);
maybe_prune(_Now, _MaxBuckets, _IdleMs, Table) ->
    Table.
