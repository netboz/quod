-module(quod_consensus_trace).
-moduledoc """
Consensus observation lifetimes, independent of the proof that submitted work.

An ended proof span is still valid ancestry, but cannot accept later events.
Each consensus boundary therefore has its own short span. Its start timestamp
is the observed boundary, NOT a queue-residence or consensus-round duration.
Work spans measure their actual enclosed work. Both use the same parent/link
selection, sampler and exporter; no inventory, timer or second process exists.
""".

-export([work/5, event/4]).

-type parent() :: none | {quod_trace:context(), [opentelemetry:link()]}.
-type location() :: {binary(), non_neg_integer(), none | binary()}.

-spec work(parent(), location(), binary(), map(), fun(() -> T)) -> T.
work(none, _Location, _Name, _Attributes, Fun) -> Fun();
work({Ctx, Links}, Location, Name, Attributes, Fun) ->
    quod_trace:with_span(Ctx, Name, internal, attributes(Location, Attributes), Links,
                        fun(_Span) -> Fun() end).

-spec event(parent(), location(), binary(), map()) -> ok.
event(Parent, Location, Name, Attributes) ->
    %% Only the diagnostic effect is inside this guard. An SDK disappearance
    %% must never turn a successful protocol transition into owner death.
    try work(Parent, Location, Name,
             Attributes#{'quod.consensus.observation' => <<"boundary">>}, fun() -> ok end)
    catch _:_ -> ok
    end.

attributes({Ns, Slot, none}, Attributes) ->
    Attributes#{'quod.namespace' => Ns, 'quod.consensus.slot' => Slot};
attributes({Ns, Slot, Hash}, Attributes) ->
    (attributes({Ns, Slot, none}, Attributes))#{
      'quod.consensus.block_hash' => binary:encode_hex(Hash, lowercase)}.
