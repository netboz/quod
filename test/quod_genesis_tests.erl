-module(quod_genesis_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").
-include("quod_ingress_limits.hrl").

base_config(Self) ->
    #{node_id => Self, mode => create, committee => []}.

encoded_size(Term) ->
    byte_size(term_to_binary(Term, [deterministic])).

sized_diff(Bytes) when Bytes >= 64 ->
    Empty = [{assert, {{genesis_payload, <<>>}, true}}],
    PayloadBytes = Bytes - encoded_size(Empty),
    Diff = [{assert, {{genesis_payload, <<0:PayloadBytes/unit:8>>}, true}}],
    Bytes = encoded_size(Diff),
    Diff.

genesis_source_validation_test() ->
    Self = <<0:256>>,
    Base = base_config(Self),
    InitialDiff = quod_prolog:terms_to_diff([{initial_fact, ok}]),
    ?assertEqual(ok, quod_simplex:test_valid_genesis_source(Base)),
    ?assertEqual(
       ok,
       quod_simplex:test_valid_genesis_source(
         Base#{genesis_file => "initial.pl"})),
    ?assertEqual(
       ok,
       quod_simplex:test_valid_genesis_source(
         Base#{genesis_diff => InitialDiff})),
    ?assertEqual(
       {error, multiple_genesis_sources},
       quod_simplex:test_valid_genesis_source(
         Base#{genesis_file => "initial.pl",
               genesis_diff => InitialDiff})),
    ?assertEqual(
       {error, invalid_genesis_diff},
       quod_simplex:test_valid_genesis_source(
         Base#{genesis_diff => [{not_an_op, invalid}]})),
    ?assertEqual(
       {error, invalid_genesis_diff},
       quod_simplex:test_valid_genesis_source(
         Base#{genesis_diff => [
                  {assert, {{valid_prefix, ok}, true}} | improper_tail]})).

founding_committee_cap_test() ->
    Self = <<0:256>>,
    Members = [<<I:256>> || I <- lists:seq(1, ?MAX_VALIDATORS)],
    AtLimit = (base_config(Self))#{committee => lists:sublist(
                                                  Members,
                                                  ?MAX_VALIDATORS - 1)},
    AboveLimit = (base_config(Self))#{committee => Members},
    ?assertEqual(ok, quod_simplex:test_valid_config(AtLimit)),
    ?assertEqual(
       {error, {committee_too_large, ?MAX_VALIDATORS + 1}},
       quod_simplex:test_valid_config(AboveLimit)).

genesis_initial_diff_boundary_test() ->
    Self = <<0:256>>,
    Base = base_config(Self),
    AtLimit = sized_diff(?MAX_GENESIS_INITIAL_DIFF_BYTES),
    AboveLimit = sized_diff(?MAX_GENESIS_INITIAL_DIFF_BYTES + 1),
    ?assertEqual(
       ok,
       quod_simplex:test_valid_genesis_source(
         Base#{genesis_diff => AtLimit})),
    ?assertEqual(
       {error, initial_content_too_large},
       quod_simplex:test_valid_genesis_source(
         Base#{genesis_diff => AboveLimit})).

generated_genesis_source_equivalence_test() ->
    Self = <<0:256>>,
    Ns = <<"genesis:equivalence">>,
    Incarnation = <<16#5a:256>>,
    File = filename:join(code:priv_dir(quod), "ontologies/animals.pl"),
    Terms = quod_prolog:read_terms(File),
    InitialDiff = quod_prolog:terms_to_diff(Terms),
    Base = base_config(Self),
    FromFile =
        quod_simplex:test_genesis_tx(
          Base#{genesis_file => File}, Ns, Self, Incarnation),
    FromDiff =
        quod_simplex:test_genesis_tx(
          Base#{genesis_diff => InitialDiff}, Ns, Self, Incarnation),
    ?assertEqual(FromFile, FromDiff),
    #transaction{diff = FullDiff} = FromDiff,
    InitialOffset = length(FullDiff) - length(InitialDiff),
    ?assertEqual(InitialDiff, lists:nthtail(InitialOffset, FullDiff)).

complete_genesis_keeps_block_bound_test() ->
    Self = <<0:256>>,
    Ns = <<"genesis:complete-bound">>,
    Incarnation = <<16#6b:256>>,
    InitialDiff = sized_diff(?MAX_GENESIS_INITIAL_DIFF_BYTES),
    %% Initial content is independently within its limit. The generated
    %% committee fact pushes the complete transaction above the block limit.
    OversizedHost = binary:copy(<<"h">>, 70 * 1024),
    Config =
        (base_config(Self))#{
          committee => [{<<1:256>>, OversizedHost, 14567}],
          genesis_diff => InitialDiff},
    ?assertThrow(
       {genesis_failed, invalid_generated_genesis},
       quod_simplex:test_genesis_tx(Config, Ns, Self, Incarnation)).
