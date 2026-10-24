#!/usr/bin/env escript
%%! +S 4:4 -pa _build/test/lib/quod/ebin _build/test/lib/erlog/ebin _build/test/lib/crypto/ebin
-mode(compile).
-include("../../../include/quod_ledger.hrl").
main(_) ->
    Files = ["space.pl","agent_instance.pl","quod_physics.pl","space_view.pl","lobby_instance.pl",
             "voxel_world.pl","voxel_world_view.pl","gui_instance.pl","gui_question.pl",
             "voxel_world_gui.pl","lobby_worlds.pl"],
    Terms = lists:append([quod_prolog:read_terms("priv/ontologies/" ++ F) || F <- Files]),
    Diff = quod_prolog:terms_to_diff(Terms),
    Ns = <<"composition-measurement">>,
    Base = quod_simplex:test_genesis_tx(#{}, Ns, <<1:256>>, <<2:256>>),
    Genesis = Base#transaction{diff = Base#transaction.diff ++ Diff},
    {ok, Wire} = quod_wire_term:encode_canonical(Genesis#transaction.diff),
    io:format("~p~n",[#{source_terms => length(Terms),
        initial_etf_bytes => byte_size(term_to_binary(Diff,[deterministic])),
        initial_cold_symbols => length(quod_wire_term:cold_new_symbols(Diff)),
        canonical_genesis_diff_bytes => byte_size(Wire),
        transaction_encoding => size_result(quod_transaction:encode_ledger_transaction(Genesis)),
        ledger_payload_size => quod_ledger:encoded_payload_size({batch,[Genesis]}),
        valid_genesis => quod_simplex:valid_genesis_transaction(Ns,Genesis)}]).
size_result({ok,B}) -> {ok,byte_size(B)};
size_result(Error) -> Error.
