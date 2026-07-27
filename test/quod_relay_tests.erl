-module(quod_relay_tests).

-include_lib("eunit/include/eunit.hrl").

frame_dispatch_test() ->
    Ns = <<"relay:test">>,
    ReqId = <<1:128>>,
    Result = {relay_result, ReqId, {ok, 7}},
    ?assertEqual({relay, Result},
                 quod_relay:decode_frame(quod_relay:encode(Ns, Result), Ns)),
    Accepted = {relay_accepted, ReqId},
    ?assertEqual({relay, Accepted},
                 quod_relay:decode_frame(quod_relay:encode(Ns, Accepted), Ns)),
    Consensus = {share, example},
    Inner = term_to_binary(Consensus, [deterministic]),
    Frame = term_to_binary({sx, Ns, Inner}, [deterministic]),
    ?assertEqual({consensus, Consensus},
                 quod_relay:decode_frame(Frame, Ns)),
    ?assertEqual(error, quod_relay:decode_frame(Frame, <<"other">>)),
    Submit = {relay_submit, ReqId, 7,
              {submit, <<2:256>>, <<3:512>>, <<4, 5, 6>>},
              [{<<"traceparent">>,
                <<"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01">>}]},
    ?assertEqual({relay, Submit},
                 quod_relay:decode_frame(quod_relay:encode(Ns, Submit), Ns)),
    [BadSlot0, BadSlotHuge, BadSlotType] =
        [setelement(3, Submit, Slot)
         || Slot <- [0, 16#10000000000000000, <<"7">>]],
    [?assertEqual(error,
                  quod_relay:decode_frame(quod_relay:encode(Ns, Bad), Ns))
     || Bad <- [BadSlot0, BadSlotHuge, BadSlotType]],
    {relay_submit, ReqId, _Slot, Envelope, Carrier} = Submit,
    Legacy = {relay_submit, ReqId, Envelope, Carrier},
    ?assertEqual(error,
                 quod_relay:decode_frame(quod_relay:encode(Ns, Legacy), Ns)),
    BadCarrier = setelement(5, Submit, [{<<"baggage">>, <<"not-accepted">>}]),
    ?assertEqual(error,
                 quod_relay:decode_frame(quod_relay:encode(Ns, BadCarrier), Ns)).

bounded_result_cache_test() ->
    Now = quod_time:mono_ms(),
    Expired = #{<<0:128>> => {peer, old, Now - 1}},
    Live = quod_relay:put_result(
             <<1:128>>, {peer, fresh, Now + 1000}, Expired),
    ?assertEqual(false, maps:is_key(<<0:128>>, Live)),
    ?assertEqual({peer, fresh, Now + 1000}, maps:get(<<1:128>>, Live)).

v2_frame_dispatch_test() ->
    Ns = <<"relay:v2">>,
    SubmissionId = <<1:128>>,
    AttemptId = <<2:128>>,
    CommitteeId = <<8:256>>,
    Slot = 17,
    Submission = {submit, <<3:256>>, <<4:512>>, <<5, 6, 7>>},
    Carrier =
        [{<<"traceparent">>,
          <<"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01">>}],
    Submit =
        {relay_submit_v2, SubmissionId, AttemptId, CommitteeId, Slot,
         Submission, Carrier},
    Accepted =
        {relay_accepted_v2, SubmissionId, AttemptId, CommitteeId, Slot},
    Result =
        {relay_result_v2, SubmissionId, AttemptId, CommitteeId,
         Slot, {ok, Slot}},
    [?assertEqual(
       {relay, Message},
       quod_relay:decode_frame(quod_relay:encode(Ns, Message), Ns))
     || Message <- [Submit, Accepted, Result]],
    MaxSlotSubmit = setelement(5, Submit, 16#FFFFFFFFFFFFFFFF),
    ?assertEqual(
       {relay, MaxSlotSubmit},
       quod_relay:decode_frame(
         quod_relay:encode(Ns, MaxSlotSubmit), Ns)),
    ?assertEqual(
       error,
       quod_relay:decode_frame(quod_relay:encode(Ns, Submit),
                               <<"other:ontology">>)).

v2_frame_shape_rejection_test() ->
    Ns = <<"relay:v2:bounds">>,
    Sid = <<1:128>>,
    Aid = <<2:128>>,
    CommitteeId = <<8:256>>,
    Slot = 7,
    Author = <<3:256>>,
    Signature = <<4:512>>,
    Submission = {submit, Author, Signature, <<5, 6, 7>>},
    Carrier = [],
    Submit =
        {relay_submit_v2, Sid, Aid, CommitteeId, Slot, Submission, Carrier},
    BadSubmits =
        [setelement(2, Submit, <<1:120>>),
         setelement(3, Submit, <<2:120>>),
         setelement(4, Submit, <<8:248>>),
         setelement(5, Submit, 0),
         setelement(5, Submit, 16#10000000000000000),
         setelement(5, Submit, <<"7">>),
         setelement(6, Submit,
                    {submit, <<3:248>>, Signature, <<5, 6, 7>>}),
         setelement(6, Submit,
                    {submit, Author, <<4:504>>, <<5, 6, 7>>}),
         setelement(6, Submit,
                    {submit, Author, Signature, <<0:(256 * 1024 + 1)/unit:8>>}),
         setelement(7, Submit, [{<<"baggage">>, <<"not-accepted">>}])],
    [?assertEqual(
       error, quod_relay:decode_frame(quod_relay:encode(Ns, Bad), Ns))
     || Bad <- BadSubmits],
    Accepted = {relay_accepted_v2, Sid, Aid, CommitteeId, Slot},
    Result = {relay_result_v2, Sid, Aid, CommitteeId, Slot, {ok, Slot}},
    BadReplies =
        [setelement(2, Accepted, <<1:120>>),
         setelement(3, Accepted, <<2:120>>),
         setelement(4, Accepted, <<8:248>>),
         setelement(5, Accepted, 0),
         setelement(2, Result, <<1:120>>),
         setelement(3, Result, <<2:120>>),
         setelement(4, Result, <<8:248>>),
         setelement(5, Result, 16#10000000000000000),
         setelement(6, Result, {ok, 0}),
         setelement(6, Result, {error, unknown})],
    [?assertEqual(
       error, quod_relay:decode_frame(quod_relay:encode(Ns, Bad), Ns))
     || Bad <- BadReplies].
