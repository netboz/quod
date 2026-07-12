-module(quod_time).
-moduledoc """
Time helpers, shared across the content layer — the single place the "which clock" decision lives.

Two clocks, two jobs; picking the wrong one is exactly the bug class this module centralizes away:

- `now_ms/0` — **wall clock** (Unix epoch ms). For values compared ACROSS nodes: block timestamps
  (`quod_simplex`) and transaction submit times (`quod_prolog`) must share it for `commit_time −
  submitted_at` to mean anything. Non-monotonic under NTP steps — clamp with `max/2` where a floor matters.
- `mono_ms/0` — **monotonic clock** (VM-local ms). For node-LOCAL ages and deadlines: digest freshness
  (`quod_feed`) and dial timeouts (`quod_simplex`). Immune to NTP steps; never comparable across nodes.
""".
-export([now_ms/0, mono_ms/0]).

-doc """
Milliseconds since the Unix epoch. This is the block-timestamp / submit-time source: it is comparable
across nodes (unlike `mono_ms/0`, whose origin is per-VM and arbitrary), at the cost of being
non-monotonic under NTP steps — callers that need a floor clamp with `max/2`.
""".
-spec now_ms() -> non_neg_integer().
now_ms() -> erlang:system_time(millisecond).

-doc """
Milliseconds on the VM's MONOTONIC clock — for node-local ages and deadlines (a difference of two
readings on the same node is a true elapsed duration, immune to NTP steps). Never comparable across
nodes (the origin is per-VM and arbitrary), so never stamp anything that leaves the node with it.
""".
-spec mono_ms() -> integer().
mono_ms() -> erlang:monotonic_time(millisecond).
