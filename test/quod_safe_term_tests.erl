-module(quod_safe_term_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_term_limits.hrl").

untrusted_etf_guards_test() ->
    Encoded = term_to_binary({ok, <<1, 2, 3>>}, [deterministic]),
    ?assertEqual(
       {ok, {ok, <<1, 2, 3>>}},
       quod_safe_term:decode(Encoded, byte_size(Encoded))),
    ?assertEqual(
       {error, too_large},
       quod_safe_term:decode(Encoded, byte_size(Encoded) - 1)),
    ?assertEqual(
       {error, trailing_data},
       quod_safe_term:decode(<<Encoded/binary, 0>>, byte_size(Encoded) + 1)),
    Compressed = term_to_binary(
                   {binary:copy(<<"compress">>, 200)}, [{compressed, 9}]),
    ?assertMatch(<<131, 80, _/binary>>, Compressed),
    ?assertEqual(
       {error, compressed},
       quod_safe_term:decode(Compressed, byte_size(Compressed))),
    Unknown = <<"quod_safe_term_unknown_atom_6f1868f4">>,
    UnknownAtomEtf = <<131, 119, (byte_size(Unknown)):8, Unknown/binary>>,
    ?assertEqual(
       {error, bad_term},
       quod_safe_term:decode(
         UnknownAtomEtf, byte_size(UnknownAtomEtf))).

wrapped_decode_matches_materialized_decode_test() ->
    Terms = [
        {known, 1, -1, 256, 18446744073709551616, 1.5},
        #{a => [1, 2, 3], b => {<<0, 255>>, <<3:2>>}},
        {[a | b], {}, []}
    ],
    lists:foreach(
      fun(Term) ->
          Blob = term_to_binary(Term, [deterministic]),
          ?assertEqual(quod_safe_term:decode(Blob, byte_size(Blob)),
                       quod_safe_term:decode_wrapped(Blob, byte_size(Blob)))
      end, Terms).

wrapped_decode_canonical_round_trip_property_test() ->
    lists:foreach(
      fun(N) ->
          Term = generated_term(N),
          Blob = term_to_binary(Term, [deterministic]),
          ?assertEqual({ok, Term},
                       quod_safe_term:decode_wrapped(Blob, byte_size(Blob)))
      end, lists:seq(1, 256)).

wrapped_decode_creates_no_atoms_test() ->
    Name = fresh_name(<<"zero_atom_creation">>),
    Blob = atom_blob(Name),
    ?assertError(badarg, binary_to_existing_atom(Name, utf8)),
    Before = erlang:system_info(atom_count),
    ?assertEqual({ok, {'$quod_symbol', Name}},
                 quod_safe_term:decode_wrapped(Blob, byte_size(Blob))),
    ?assertEqual(Before, erlang:system_info(atom_count)),
    ?assertError(badarg, binary_to_existing_atom(Name, utf8)).

wrapped_decode_canonical_and_bounds_test() ->
    Canonical = term_to_binary({ok, [1, 2]}, [deterministic]),
    ?assertMatch({ok, _}, quod_safe_term:decode_wrapped(
                            Canonical, byte_size(Canonical))),
    ?assertEqual({error, too_large}, quod_safe_term:decode_wrapped(
                                      Canonical, byte_size(Canonical) - 1)),
    ?assertEqual({error, trailing_data}, quod_safe_term:decode_wrapped(
                                          <<Canonical/binary, 0>>,
                                          byte_size(Canonical) + 1)),
    %% INTEGER_EXT is a valid ETF representation of 1, but deterministic ETF
    %% uses SMALL_INTEGER_EXT. Signed artifacts accept only the latter.
    ?assertEqual({error, bad_term},
                 quod_safe_term:decode_wrapped(<<131, 98, 0, 0, 0, 1>>, 6)),
    Compressed = term_to_binary({lists:duplicate(100, a)}, [{compressed, 9}]),
    ?assertEqual({error, compressed},
                 quod_safe_term:decode_wrapped(Compressed,
                                               byte_size(Compressed))).

wrapped_decode_rejects_degenerate_list_encodings_test() ->
    CanonicalEmpty = term_to_binary([], [deterministic]),
    CanonicalFlat = term_to_binary([256, 257], [deterministic]),
    ?assertEqual({ok, []}, decode_wrapped(CanonicalEmpty)),
    ?assertEqual({ok, [256, 257]}, decode_wrapped(CanonicalFlat)),
    %% Empty STRING_EXT and zero-element LIST_EXT are alternate encodings of
    %% [] and of the LIST_EXT tail respectively. Deterministic ETF emits
    %% NIL_EXT, so neither form is canonical.
    ?assertEqual({error, bad_term},
                 decode_wrapped(<<131, 107, 0, 0>>)),
    ?assertEqual({error, bad_term},
                 decode_wrapped(<<131, 108, 0, 0, 0, 0, 106>>)),
    ?assertEqual(
       {error, bad_term},
       decode_wrapped(<<131, 108, 0, 0, 0, 0,
                        108, 0, 0, 0, 0, 106>>)),
    %% A LIST_EXT tail that is itself a list has the same value as one flat
    %% LIST_EXT. Keep only the deterministic flat representation.
    NestedTail = <<131,
                   108, 0, 0, 0, 1, 98, 0, 0, 1, 0,
                   108, 0, 0, 0, 1, 98, 0, 0, 1, 1, 106>>,
    ?assertEqual({error, bad_term}, decode_wrapped(NestedTail)),
    StringTail = <<131,
                   108, 0, 0, 0, 1, 98, 0, 0, 1, 0,
                   107, 0, 1, 1>>,
    ?assertEqual({error, bad_term}, decode_wrapped(StringTail)).

wrapped_decode_unicode_atom_character_boundary_test() ->
    %% 200 Unicode characters occupy 400 UTF-8 bytes. ETF uses the 16-bit
    %% UTF-8 atom tag, while Erlang's atom boundary is measured in characters.
    Name = binary:copy(<<16#c3, 16#a9>>, 200),
    Atom = binary_to_atom(Name, utf8),
    Blob = term_to_binary(Atom, [deterministic]),
    ?assertMatch(<<131, 118, _/binary>>, Blob),
    ?assertEqual({ok, Atom}, decode_wrapped(Blob)).

wrapped_decode_canonical_composite_map_keys_test() ->
    Term = #{[a, b] => proper_list,
             [a | <<>>] => improper_list,
             <<"aa">> => longer_binary,
             <<"z">> => shorter_binary},
    Blob = term_to_binary(Term, [deterministic]),
    ?assertEqual({ok, Term}, decode_wrapped(Blob)).

wrapped_decode_rejects_maps_nested_in_map_keys_test() ->
    K1 = etf_body(#{a => 1, z => 0}),
    K2 = etf_body(#{a => 2, b => 0}),
    One = etf_body(one),
    Two = etf_body(two),
    %% Supported OTP releases can emit either order from fresh VMs even with
    %% the deterministic option. Neither is admitted to the canonical subset.
    K1First = <<131, 116, 0, 0, 0, 2,
                K1/binary, One/binary, K2/binary, Two/binary>>,
    K2First = <<131, 116, 0, 0, 0, 2,
                K2/binary, Two/binary, K1/binary, One/binary>>,
    ?assertEqual({error, bad_term}, decode_wrapped(K1First)),
    ?assertEqual({error, bad_term}, decode_wrapped(K2First)),
    TupleKey = term_to_binary(#{{#{a => 1}} => nested}, [deterministic]),
    ?assertEqual({error, bad_term}, decode_wrapped(TupleKey)).

wrapped_decode_depth_bound_test() ->
    Accepted = nested_tuple(?QUOD_MAX_TERM_DEPTH),
    AcceptedBlob = term_to_binary(Accepted, [deterministic]),
    ?assertEqual({ok, Accepted},
                 quod_safe_term:decode_wrapped(AcceptedBlob,
                                               byte_size(AcceptedBlob))),
    Refused = nested_tuple(?QUOD_MAX_TERM_DEPTH + 1),
    RefusedBlob = term_to_binary(Refused, [deterministic]),
    ?assertEqual({error, bad_term},
                 quod_safe_term:decode_wrapped(RefusedBlob,
                                               byte_size(RefusedBlob))).

wrapped_decode_loaded_and_unloaded_vms_compare_identically_test_() ->
    %% Two peer boots (15 s each), three RPCs (5 s each), and two
    %% shutdowns (5 s each) already have a 55 s aggregate bound. EUnit's
    %% default 5 s must not kill the owner before those bounds can report.
    {timeout, 60, fun wrapped_decode_loaded_and_unloaded_vms_compare_identically/0}.

wrapped_decode_loaded_and_unloaded_vms_compare_identically() ->
    Name = fresh_name(<<"loaded_unloaded">>),
    Blob = atom_blob(Name),
    Path = code:get_path(),
    PeerName1 = list_to_atom(
                  "safe_term_unloaded_"
                  ++ integer_to_list(erlang:unique_integer([positive]))),
    PeerName2 = list_to_atom(
                  "safe_term_loaded_"
                  ++ integer_to_list(erlang:unique_integer([positive]))),
    {ok, UnloadedPeer, _} = peer:start_link(
                              #{name => PeerName1, connection => standard_io,
                                args => ["-pa" | Path]}),
    try
        {ok, LoadedPeer, _} = peer:start_link(
                                #{name => PeerName2, connection => standard_io,
                                  args => ["-pa" | Path]}),
        try
            {ok, Wrapped} = peer:call(
                              UnloadedPeer, quod_safe_term, decode_wrapped,
                              [Blob, byte_size(Blob)]),
            _ = peer:call(LoadedPeer, erlang, binary_to_atom, [Name, utf8]),
            {ok, Loaded} = peer:call(
                             LoadedPeer, quod_safe_term, decode_wrapped,
                             [Blob, byte_size(Blob)]),
            ?assertEqual({{'$quod_symbol', Name}, {'$quod_symbol', Name}},
                         quod_wire_term:normalize_answer_symbols(Wrapped, Loaded))
        after
            _ = peer:stop(LoadedPeer)
        end
    after
        _ = peer:stop(UnloadedPeer)
    end.

wrapped_decode_unknown_nested_canonical_test() ->
    Name = fresh_name(<<"nested">>),
    Atom = atom_blob_body(Name),
    %% #{unknown => [unknown]} in deterministic map/list order.
    Blob = <<131, 116, 0, 0, 0, 1, Atom/binary,
             108, 0, 0, 0, 1, Atom/binary, 106>>,
    Symbol = {'$quod_symbol', Name},
    ?assertEqual({ok, #{Symbol => [Symbol]}},
                 quod_safe_term:decode_wrapped(Blob, byte_size(Blob))).

fresh_name(Prefix) ->
    Suffix = binary:encode_hex(crypto:strong_rand_bytes(12), lowercase),
    <<"quod_safe_term_", Prefix/binary, "_", Suffix/binary>>.

atom_blob(Name) -> <<131, (atom_blob_body(Name))/binary>>.

atom_blob_body(Name) when byte_size(Name) < 256 ->
    <<119, (byte_size(Name)):8, Name/binary>>.

generated_term(N) when N rem 8 =:= 0 ->
    #{N => {known, N - 1000}, a => [N band 255, <<N:32>>]};
generated_term(N) when N rem 8 =:= 1 ->
    {[N, N * N | tail], <<N:13>>, N / 3};
generated_term(N) when N rem 8 =:= 2 ->
    1 bsl (N + 64);
generated_term(N) when N rem 8 =:= 3 ->
    -(1 bsl (N + 32));
generated_term(N) when N rem 8 =:= 4 ->
    [N band 255 || _ <- lists:seq(1, N rem 40)];
generated_term(N) when N rem 8 =:= 5 ->
    #{1 => integer, 1.0 => float, {N} => tuple};
generated_term(N) when N rem 8 =:= 6 ->
    <<N:7, (N band 3):2>>;
generated_term(N) ->
    {[], {}, <<>>, N}.

nested_tuple(0) -> leaf;
nested_tuple(N) -> {nested_tuple(N - 1)}.

decode_wrapped(Blob) ->
    quod_safe_term:decode_wrapped(Blob, byte_size(Blob)).

etf_body(Term) ->
    <<131, Body/binary>> = term_to_binary(Term, [deterministic]),
    Body.
