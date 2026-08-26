-module(quod_rate).
-moduledoc """
A fixed-window request budget, counted in total and per key.

Optional ingress policy for the client boundary. Its current owner can apply
configured budgets to challenge issuance, signed goals, and symbol
materialization. It is deliberately a plain value with no process and no timer
— the owner threads it through its own state and supplies the clock.

Keys identify peer addresses or signing keys. The key table is itself capped,
because rotating keys would otherwise turn an enabled rate limiter into an
unbounded map; once it is full, an unseen key is refused rather than admitted.

Callers must supply a **monotonic** clock (`quod_time:mono_ms/0`). With a wall
clock an NTP step backwards would park the window start in the future and freeze
the budget at whatever it had reached.
""".

-export([new/1, allow/3]).

-record(rate, {window_ms :: pos_integer(),
               max_total :: pos_integer(),
               max_per_key :: pos_integer(),
               max_keys :: pos_integer(),
               started :: integer() | undefined,
               total = 0 :: non_neg_integer(),
               keys = #{} :: #{term() => pos_integer()}}).

-opaque limiter() :: #rate{}.
-export_type([limiter/0]).

-type config() :: #{window_ms := pos_integer(),
                    max_total := pos_integer(),
                    max_per_key := pos_integer(),
                    max_keys := pos_integer()}.

-doc "Build an empty limiter.".
-spec new(config()) -> limiter().
new(#{window_ms := Window, max_total := Total, max_per_key := PerKey,
      max_keys := MaxKeys}) ->
    #rate{window_ms = Window, max_total = Total, max_per_key = PerKey,
          max_keys = MaxKeys, started = undefined}.

-doc """
Charge one request for `Key` at monotonic time `Now`.

`{ok, Limiter}` admits it and records the charge. `busy` means the whole window
(or the key table) is full and says nothing about this caller; `rate_limited`
means this key alone has spent its share. Keeping them distinct lets the
boundary answer "the node is saturated" and "you are going too fast" differently.
""".
-spec allow(term(), integer(), limiter()) ->
          {ok, limiter()} | {busy | rate_limited, limiter()}.
allow(Key, Now, Rate0) ->
    Rate = roll(Now, Rate0),
    #rate{total = Total, max_total = MaxTotal, keys = Keys,
          max_per_key = PerKey, max_keys = MaxKeys} = Rate,
    Spent = maps:get(Key, Keys, 0),
    if
        Total >= MaxTotal -> {busy, Rate};
        Spent >= PerKey -> {rate_limited, Rate};
        Spent =:= 0 andalso map_size(Keys) >= MaxKeys -> {busy, Rate};
        true -> {ok, Rate#rate{total = Total + 1,
                               keys = Keys#{Key => Spent + 1}}}
    end.

roll(Now, Rate = #rate{started = undefined}) ->
    Rate#rate{started = Now};
roll(Now, Rate = #rate{started = Started, window_ms = Window})
  when Now - Started >= Window ->
    Rate#rate{started = Now, total = 0, keys = #{}};
roll(_Now, Rate) ->
    Rate.
