-module(quod_ledger_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

%%%===================================================================
%%% classify/1 — the single enumeration of committed entry-data variants
%%%===================================================================

tx(I) ->
    #transaction{tx_id = integer_to_binary(I), origin = {<<"quod:root">>, <<0:256>>},
                 diff = [{assert, {{fact, I}, true}}], read_check = #{},
                 author = <<0:256>>, sig = none}.

%% The block and ledger use the same explicit content tag; payload/1 is a
%% deliberately content-only convenience for its existing callers.
content_classification_test() ->
    Txs = [tx(1), tx(2)],
    Data = {batch, Txs},
    ?assertEqual({batch, Txs}, Data),
    ?assertEqual({content, Txs}, quod_ledger:classify(Data)),
    ?assertEqual({ok, Txs}, quod_ledger:payload(Data)).

%% A complaint-certified skip carries nothing to fold and is NOT content — the
%% distinction every per-variant consumer dispatches on.
noop_is_its_own_kind_test() ->
    ?assertEqual(noop, quod_ledger:classify(noop)),
    ?assertEqual(error, quod_ledger:payload(noop)).

%% DTX input is untrusted at catch-up/replay. Non-binary and malformed blobs
%% are invalid rather than exceptions, content, or inert skips.
malformed_dtx_is_invalid_test() ->
    Malformed = [{dtx, not_a_binary},
                 {dtx, <<>>},
                 {dtx, <<"not etf">>}],
    lists:foreach(
      fun(Data) ->
          ?assertEqual(invalid, quod_ledger:classify(Data)),
          ?assertEqual(error, quod_ledger:payload(Data))
      end, Malformed).

%% Untrusted input reaches classify through catch-up windows and replay, so a
%% malformed batch is a tolerated classification rather than a crash.
malformed_is_invalid_test() ->
    Malformed = [{batch, []},
                 {batch, [tx(1) | not_a_list]},
                 {batch, [tx(1), not_a_transaction]},
                 {batch, not_a_list},
                 {batch, tx(1)}],
    lists:foreach(
      fun(Data) ->
          ?assertEqual(invalid, quod_ledger:classify(Data)),
          ?assertEqual(error, quod_ledger:payload(Data))
      end, Malformed).

%% The contract the later distributed-control-record work depends on: a variant
%% this release does not know is `invalid` — never silently folded as content or
%% mistaken for the inert skip. Adding it means extending classify/1 here, which
%% makes every consumer's exhaustive dispatch fail loudly until it decides what
%% the new kind means.
unknown_variant_is_invalid_test() ->
    Unknown = [{control, anything},
               {batch, [tx(1)], extra},
               undefined,
               <<"bytes">>,
               42,
               []],
    lists:foreach(
      fun(Data) ->
          Kind = quod_ledger:classify(Data),
          ?assertEqual(invalid, Kind),
          ?assertNotMatch({content, _}, Kind),
          ?assertNotEqual(noop, Kind)
      end, Unknown).
