#!/usr/bin/env escript
%%! -pa _build/test/lib/quod/ebin
-mode(compile).
-include("/work/include/quod_ledger.hrl").
main(_) ->
    [code:add_pathz(P)||P<-filelib:wildcard("_build/test/lib/*/ebin")],
    {ok,_}=application:ensure_all_started(crypto),
    Files=["quod_space.pl","agent_instance.pl","quod_physics.pl","lobby_instance.pl",
           "voxel_world.pl","voxel_world_view.pl","gui_instance.pl","voxel_world_gui.pl","lobby_worlds.pl"],
    Diff=quod_prolog:terms_to_diff(lists:append([quod_prolog:read_terms("priv/ontologies/"++F)||F<-Files])),
    Invalid=[element(1,Head)||Op={assert,{Head,_}}<-Diff,not quod_diff:valid_ops([Op])],
    InvalidWire=[element(1,Head)||Op={assert,{Head,_}}<-Diff,
                    quod_wire_term:encode_canonical(Op) =:= {error,bad_term}],
    InvalidNested=[{element(1,Head),depth(Op)}||Op={assert,{Head,_}}<-Diff,
                    quod_wire_term:encode_canonical([Op]) =:= {error,bad_term}],
    {ok,Wire}=quod_wire_term:encode_canonical(Diff),
    Sizes=[begin {ok,B}=quod_wire_term:encode_canonical(quod_prolog:terms_to_diff(
                 quod_prolog:read_terms("priv/ontologies/"++F))),{F,byte_size(B)} end||F<-Files],
    Tx=#transaction{tx_id= <<1>>,origin={<<"diagnostic">>,<<0:256>>},diff=Diff,read_check=#{},author= <<1:256>>},
    io:format("~p~n",[#{operations=>length(Diff),invalid_heads=>Invalid,invalid_wire_heads=>InvalidWire,
       invalid_nested_heads=>InvalidNested,diff_bytes=>byte_size(Wire),file_bytes=>Sizes,
       unique_operations=>length(lists:usort(Diff)),
       unique_bytes=>begin {ok,U}=quod_wire_term:encode_canonical(lists:usort(Diff)),byte_size(U) end,
       payload_size=>quod_ledger:encoded_payload_size({batch,[Tx]}),
       transaction_encoding=>case quod_transaction:encode_ledger_transaction(Tx) of
          {ok,Blob}->{ok,byte_size(Blob)};Error->Error end}]).
depth(T) when is_tuple(T)->1+lists:max([0|[depth(X)||X<-tuple_to_list(T)]]);
depth(L) when is_list(L)->1+lists:max([0|[depth(X)||X<-L]]);
depth(_)->0.
