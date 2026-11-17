%% Checks current unchanged production codecs, not proposed modules.
-module(frame_accounting_checks).
-include_lib("eunit/include/eunit.hrl").
-include("quod_transport_limits.hrl").

complete_envelope_body_accounting_is_exact_test() ->
    {ok,<<131,EndBody/binary>>} = quod_safe_term:encode_canonical(end_group,unlimited),
    lists:foreach(fun({Ns,Height,Continuation,Parts}) ->
        Page = fun(P) -> {history_page3,<<0:128>>,<<0:128>>,P,Height,Continuation,<<1:128>>} end,
        Sample = quod_catchup:encode_frame(Ns,Page([end_group])),
        Actual = quod_catchup:encode_frame(Ns,Page(Parts)),
        Bodies = [begin {ok,<<131,B/binary>>} = quod_safe_term:encode_canonical(P,unlimited), byte_size(B) end || P <- Parts],
        Overhead = byte_size(Sample)-byte_size(EndBody),
        ?assertEqual(byte_size(Actual),Overhead+lists:sum(Bodies)),
        Available = ?QUOD_LINK_PAYLOAD_CAPACITY-Overhead,
        ?assertEqual(?QUOD_LINK_PAYLOAD_CAPACITY,Overhead+Available),
        ?assertEqual(?QUOD_LINK_PAYLOAD_CAPACITY+1,Overhead+Available+1)
    end,[{binary:copy(<<"n">>,N),H,C,[{group,I,I} || I <- lists:seq(1,K)] ++
                                  [{entry,binary:copy(<<0>>,2048)},end_group]}
         || N <- [1,255,1024],H <- [1,16#FFFFFFFFFFFFFFFF],
            C <- [done,{<<2:128>>,1},{<<2:128>>,1 bsl 80}],K <- [1,2,64]]).
