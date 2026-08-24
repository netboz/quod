-module(quod_agent_ref_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_vm_limits.hrl").

-define(NS, <<"quod:agent-ref-test">>).
-define(ANCHOR, <<16#a7:256>>).

canonical_ground_reference_roundtrip_test() ->
    {ok, Decoded} = quod_agent_ref:from_text(
                      ?NS, ?ANCHOR,
                      <<"human_user(alice, <<\"opaque-id\">>).">>, 2),
    Blob = maps:get(blob, Decoded),
    ?assertEqual({ok, {?NS, ?ANCHOR}}, quod_agent_ref:identity(Blob)),
    ?assertEqual({ok, {agent, Blob}}, quod_agent_ref:principal(Blob)),
    ?assertMatch(
       {ok, {agent_instance_ref, ?NS, ?ANCHOR,
             {human_user, alice, <<"opaque-id">>}}},
       quod_agent_ref:materialize(Blob)),
    ?assertMatch(
       {ok, #{blob := Blob, identity := {?NS, ?ANCHOR}}},
       quod_agent_ref:decode(Blob)).

variables_and_noncanonical_blobs_are_rejected_test() ->
    ?assertEqual(
       {error, invalid_agent_reference},
       quod_agent_ref:from_text(?NS, ?ANCHOR, <<"human_user(X).">>, 2)),
    {ok, #{blob := Blob}} = quod_agent_ref:from_text(
                             ?NS, ?ANCHOR, <<"human_user(alice).">>, 2),
    ?assertEqual(
       {error, invalid_agent_reference},
       quod_agent_ref:decode(<<Blob/binary, 0>>)).

symbol_budget_is_vm_independent_test() ->
    Names = [<<"identity_symbol_", (integer_to_binary(I))/binary>>
             || I <- lists:seq(1, ?QUOD_MAX_NEW_MATERIAL_ATOMS + 1)],
    Text = iolist_to_binary([
             "identity(", lists:join($,, [[$', Name, $'] || Name <- Names]), ")."]),
    ?assertEqual(
       {error, invalid_agent_reference},
       quod_agent_ref:from_text(?NS, ?ANCHOR, Text, 2)).
