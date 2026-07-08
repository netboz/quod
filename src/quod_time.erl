-module(quod_time).
-moduledoc """
Wall-clock time helpers, shared across the content layer.

Kept in one place so the "what clock do we stamp with" decision lives in a single spot — the block
timestamp (`quod_simplex`) and the transaction submit time (`quod_prolog`) must use the SAME source for
`commit_time − submitted_at` to be meaningful.
""".
-export([now_ms/0]).

-doc """
Milliseconds since the Unix epoch. This is the block-timestamp / submit-time source: it is comparable
across nodes (unlike `erlang:monotonic_time/1`, whose origin is per-VM and arbitrary), at the cost of
being non-monotonic under NTP steps — callers that need a floor clamp with `max/2`.
""".
-spec now_ms() -> non_neg_integer().
now_ms() -> erlang:system_time(millisecond).
