-module(quod_relay_tests).

-include_lib("eunit/include/eunit.hrl").

frame_dispatch_test() ->
    Ns = <<"relay:test">>,
    SubmissionId = <<1:128>>,
    AttemptId = <<2:128>>,
    CommitteeId = <<8:256>>,
    Slot = 17,
    Submission = {submit, <<3:256>>, <<4:512>>, <<5, 6, 7>>},
    Carrier =
        [{<<"traceparent">>,
          <<"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01">>}],
    Submit =
        {relay_submit, SubmissionId, AttemptId, CommitteeId, Slot,
         Submission, Carrier},
    Accepted =
        {relay_accepted, SubmissionId, AttemptId, CommitteeId, Slot},
    Result =
        {relay_result, SubmissionId, AttemptId, CommitteeId,
         Slot, {ok, Slot}},
    [?assertEqual(
       {relay, Message},
       quod_relay:decode_relay_frame(
         quod_relay:encode(Ns, Message), Ns))
     || Message <- [Submit, Accepted, Result]],
    MaxSlotSubmit = setelement(5, Submit, 16#FFFFFFFFFFFFFFFF),
    ?assertEqual(
       {relay, MaxSlotSubmit},
       quod_relay:decode_relay_frame(
         quod_relay:encode(Ns, MaxSlotSubmit), Ns)),
    ?assertEqual(
       error,
       quod_relay:decode_relay_frame(
         quod_relay:encode(Ns, Submit), <<"other:ontology">>)),

    Consensus = {share, example},
    Inner = term_to_binary(Consensus, [deterministic]),
    Frame = term_to_binary({sx2, Ns, Inner}, [deterministic]),
    ?assertEqual({consensus, Consensus},
                 quod_relay:decode_consensus_frame(Frame, Ns)),
    ?assertEqual(error, quod_relay:decode_relay_frame(Frame, Ns)),
    ?assertEqual(
       error, quod_relay:decode_consensus_frame(Frame, <<"other">>)),
    ?assertEqual(
       error,
       quod_relay:decode_consensus_frame(
         quod_relay:encode(Ns, Submit), Ns)),
    OldFrame = term_to_binary({sx, Ns, Inner}, [deterministic]),
    ?assertEqual(error, quod_relay:decode_consensus_frame(OldFrame, Ns)).

bounded_result_cache_test() ->
    Now = quod_time:mono_ms(),
    AttemptId = <<1:128>>,
    Expired = #{<<0:128>> => {peer, old, Now - 1}},
    Live = quod_relay:put_result(
             AttemptId, {peer, fresh, Now + 1000}, Expired),
    ?assertEqual(false, maps:is_key(<<0:128>>, Live)),
    ?assertEqual(
       {peer, fresh, Now + 1000}, maps:get(AttemptId, Live)),
    NotOverwritten =
        quod_relay:put_result(
          AttemptId, {other_peer, divergent, Now + 9000}, Live),
    ?assertEqual(Live, NotOverwritten).

frame_shape_rejection_test() ->
    Ns = <<"relay:bounds">>,
    Sid = <<1:128>>,
    Aid = <<2:128>>,
    CommitteeId = <<8:256>>,
    Slot = 7,
    Author = <<3:256>>,
    Signature = <<4:512>>,
    Submission = {submit, Author, Signature, <<5, 6, 7>>},
    Carrier = [],
    Submit =
        {relay_submit, Sid, Aid, CommitteeId, Slot, Submission, Carrier},
    UnsupportedShapes =
        [{relay_submit, Sid, Slot, Submission, Carrier},
         {relay_accepted, Sid},
         {relay_result, Sid, {ok, Slot}}],
    [?assertEqual(
       error,
       quod_relay:decode_relay_frame(
         quod_relay:encode(Ns, Unsupported), Ns))
     || Unsupported <- UnsupportedShapes],
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
       error,
       quod_relay:decode_relay_frame(
         quod_relay:encode(Ns, Bad), Ns))
     || Bad <- BadSubmits],
    Accepted = {relay_accepted, Sid, Aid, CommitteeId, Slot},
    Result = {relay_result, Sid, Aid, CommitteeId, Slot, {ok, Slot}},
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
       error,
       quod_relay:decode_relay_frame(
         quod_relay:encode(Ns, Bad), Ns))
     || Bad <- BadReplies].
