"""Prepare UNAPPLIED review artifacts only. Never writes production files."""
from pathlib import Path
import difflib,json,hashlib
r=Path('/home/yan/src/quod_worktrees/pearl-stone');e=Path(__file__).resolve().parent
out=e/'proposals';out.mkdir(exist_ok=True)
changes={}
def change(n,fn):
 before=(r/n).read_text();after=fn(before);assert before!=after,n
 changes[n]=(before,after)
def emit(label):
 patch=[];rows=[]
 for n,(before,after) in changes.items():
  d=list(difflib.unified_diff(before.splitlines(True),after.splitlines(True),fromfile='a/'+n,tofile='b/'+n));patch+=d
  rows.append({'path':n,'before_sha256':hashlib.sha256(before.encode()).hexdigest(),'proposed_sha256':hashlib.sha256(after.encode()).hexdigest(),'added':sum(x.startswith('+') and not x.startswith('+++') for x in d),'removed':sum(x.startswith('-') and not x.startswith('---') for x in d)})
 (out/(label+'.patch')).write_text(''.join(patch));(out/(label+'.json')).write_text(json.dumps({'applied':False,'compiled_or_executed':False,'files':rows,'added':sum(x['added'] for x in rows),'removed':sum(x['removed'] for x in rows)},indent=2)+'\n');changes.clear()
change('include/quod_proof_limits.hrl',lambda s:s.replace('-define(QUOD_MAX_NESTED_GOAL_BYTES, ?QUOD_MAX_TOPLEVEL_GOAL_BYTES).\n',''))
change('src/quod_scope_session.erl',lambda s:s.replace('valid_invocation_input(InvocationId, Goal, Chain, Selection)','valid_invocation_input(InvocationId, Chain, Selection)').replace('    quod_transaction_scope:valid_selection(Selection) andalso\n    erlang:external_size(Goal) =< ?QUOD_MAX_NESTED_GOAL_BYTES.','    quod_transaction_scope:valid_selection(Selection).'))
change('src/quod_proof_session.erl',lambda s:s.replace('{ok, RequestedGoalBin}\n          when byte_size(RequestedGoalBin) =< ?QUOD_MAX_NESTED_GOAL_BYTES ->','{ok, RequestedGoalBin} ->'))
change('src/quod_scope_wire.erl',lambda s:s.replace('payload_limit(goal) -> {ok, ?QUOD_MAX_NESTED_GOAL_BYTES};','payload_limit(goal) -> {ok, ?QUOD_SCOPE_WIRE_MAX_ENVELOPE_BYTES};'))
change('src/quod_dtx.erl',lambda s:s.replace('when is_binary(GoalBlob),\n       byte_size(GoalBlob) =< ?QUOD_MAX_NESTED_GOAL_BYTES ->','when is_binary(GoalBlob) ->').replace('GoalBlob, ?QUOD_MAX_NESTED_GOAL_BYTES','GoalBlob, byte_size(GoalBlob)').replace('        byte_size(GoalBin) =< ?QUOD_MAX_NESTED_GOAL_BYTES andalso\n',''))
change('src/predicates/quod_ask.erl',lambda s:s.replace('GoalBlob, ?QUOD_MAX_NESTED_GOAL_BYTES','GoalBlob, byte_size(GoalBlob)'))
emit('nested-goal-owner')
def wire(s):
 return s.replace('-spec encode_bindings(map(), non_neg_integer()) ->','-spec encode_bindings(map(), non_neg_integer() | unlimited) ->').replace('is_integer(MaxBytes), MaxBytes >= 0 ->\n    case binding_pairs(Bindings)','(MaxBytes =:= unlimited orelse (is_integer(MaxBytes) andalso MaxBytes >= 0)) ->\n    case binding_pairs(Bindings)').replace('{ok, Blob} when byte_size(Blob) =< MaxBytes -> {ok, Blob};','{ok, Blob} when MaxBytes =:= unlimited; byte_size(Blob) =< MaxBytes -> {ok, Blob};')
change('src/quod_wire_term.erl',wire)
def result(s):
 s=s.replace('Normalize one target-engine result and enforce the aggregate reply cap.','Normalize one admitted target-engine result without a second allocation policy.')
 s=s.replace('encode_binding(Evidence, Bindings, ?QUOD_CLIENT_GOAL_MAX_REPLY_BYTES)','encode_binding(Evidence, Bindings)').replace('encode_bindings(Evidence, Bindings, ?QUOD_CLIENT_GOAL_MAX_REPLY_BYTES, [])','encode_bindings(Evidence, Bindings, [])').replace('encode_bindings(_Evidence, [], _Remaining, Acc)','encode_bindings(_Evidence, [], Acc)').replace('encode_bindings(Evidence, [Bindings | Rest], Remaining, Acc)','encode_bindings(Evidence, [Bindings | Rest], Acc)').replace('encode_binding(Evidence, Bindings, Remaining)','encode_binding(Evidence, Bindings)').replace('encode_bindings(Evidence, Rest, Remaining - byte_size(Blob), [Blob | Acc])','encode_bindings(Evidence, Rest, [Blob | Acc])').replace('encode_bindings(_Evidence, _Bindings, _Remaining, _Acc)','encode_bindings(_Evidence, _Bindings, _Acc)').replace('quod_wire_term:encode_bindings(Named, Remaining)','quod_wire_term:encode_bindings(Named, unlimited)').replace('encode_binding(_Evidence, _Bindings, _Remaining)','encode_binding(_Evidence, _Bindings)')
 s=s.replace('    %% Valid dependencies are bounded by both scope count and namespace size;\n    %% their error envelope always fits the aggregate reply limit.','    %% Preserve dependency withdrawal even when the result itself is invalid.')
 a=s.index('encode(Result) ->');b=s.index('-doc "Decode,',a)
 s=s[:a]+'''encode(Result) ->
    case valid_result(Result) of
        true -> {ok, term_to_binary(Result, [deterministic])};
        false -> {error, invalid_result}
    end.

'''+s[b:]
 s=s.replace('decode(Blob)\n  when is_binary(Blob),\n       byte_size(Blob) =< ?QUOD_CLIENT_GOAL_MAX_REPLY_BYTES ->\n    case quod_safe_term:decode(Blob, ?QUOD_CLIENT_GOAL_MAX_REPLY_BYTES) of','decode(Blob) when is_binary(Blob) ->\n    case quod_safe_term:decode(Blob, byte_size(Blob)) of').replace('decode(Blob) when is_binary(Blob) ->\n    {error, result_too_large};\n','')
 return s.replace('decode_binding(Blob) ->\n    quod_wire_term:decode_bindings(Blob, ?QUOD_CLIENT_GOAL_MAX_REPLY_BYTES).','decode_binding(Blob) when is_binary(Blob) ->\n    quod_wire_term:decode_bindings(Blob, byte_size(Blob));\ndecode_binding(_) -> {error, bad_term}.')
change('src/quod_client_result.erl',result)
def view(s):
 a=s.index('    case byte_size(Encoded) =< ?QUOD_CLIENT_GOAL_MAX_REPLY_BYTES of');b=s.index('\ndecimal(N)',a)
 s=s[:a]+'''    case Message of
        %% Allocation belongs to the admitted proof and authored resources.
        %% Quiet views retain their original signed lease.
        #{type := projection,expires_ms := Expiry} ->
            {[{set_options,#{idle_timeout => max(0,binary_to_integer(Expiry)-quod_time:now_ms())}},
              {text,Encoded}],S};
        _ -> {reply,{text,Encoded},S}
    end.
'''+s[b:]
 s=s.replace('                            case byte_size(Encoded) =< ?QUOD_CLIENT_GOAL_MAX_REPLY_BYTES of\n                                false -> gui_reply(From,{error,unsupported_presentation},S);\n                                true ->\n','')
 return s.replace('                                    end\n                            end\n                    end;\n                none -> gui_reply(From,{error,presentation_capacity},S)','                                    end\n                    end;\n                none -> gui_reply(From,{error,presentation_capacity},S)')
change('src/quod_client_view.erl',view)
def endpoint(s):
 a=s.index('-if(?QUOD_CLIENT_GOAL_MAX_ENVELOPE_BYTES');b=s.index('-type request_id()',a);s=s[:a]+s[b:]
 # Keep complete-envelope refusal at the existing network admission owner.
 s=s.replace('?QUOD_CLIENT_GOAL_MAX_ENVELOPE_BYTES','?QUOD_TRANSPORT_MAX_FRAME_BYTES')
 return s.replace('    is_binary(Blob) andalso\n        byte_size(Blob) =< ?QUOD_CLIENT_GOAL_MAX_REPLY_BYTES.','    is_binary(Blob).')
change('src/quod_client_goal_endpoint.erl',endpoint)
def header(s):
 a=s.index('%% One complete signed-client reply');b=s.index('%% Node-wide signed-goal routing',a)
 return s[:a]+"%% Legacy terrain resource packing quota; its remaining callers are separately\n%% identified for retirement. Ordinary signed results/views have no subquota.\n-define(QUOD_CLIENT_GOAL_MAX_REPLY_BYTES, (512 * 1024)).\n\n"+s[b:]
change('include/quod_client_goal_limits.hrl',header)
emit('presentation-reply-owner')

change('test/quod_scope_wire_tests.erl',lambda s:s.replace('exact_payload_boundary(goal, ?QUOD_MAX_NESTED_GOAL_BYTES)','exact_payload_boundary(goal, ?QUOD_SCOPE_WIRE_MAX_ENVELOPE_BYTES)'))
def dtx_test(s):
 a=s.index('oversized_goal_is_refused_before_invocation_exists_test()');b=s.index('\n\n',s.index('    end.',a))
 return s[:a]+"""nested_goal_is_not_readmitted_against_signed_input_quota_test() ->
    Session = session([]),
    Id = <<3:128>>,
    Goal = {pad,binary:copy(<<$p>>,160000)},
    try
        ?assertEqual(ok,open(Session,Id,Goal)),
        {Entries,_}=quod_proof_session:transcript(Session),
        ?assertMatch([_],Entries)
    after quod_proof_session:stop(Session) end."""+s[b:]
change('test/quod_dtx_tests.erl',dtx_test)
emit('nested-goal-tests')
def endpoint_test(s):
 s=s.replace('?QUOD_CLIENT_GOAL_MAX_ENVELOPE_BYTES','?QUOD_TRANSPORT_MAX_FRAME_BYTES')
 a=s.index('limits_stay_below_transport_frame_test()');b=s.index('routing_decode_keeps_signed',a)
 return s[:a]+"""complete_envelope_uses_existing_transport_admission_test() ->
    Id = <<7:128>>,
    {ok,Payload}=quod_wire_term:encode_bindings(#{<<\"X\">>=>binary:copy(<<$x>>,600000)},unlimited),
    {ok,Result}=quod_client_result:encode({answers,1,[Payload]}),
    {ok,Envelope}=quod_client_goal_endpoint:encode_response({result,Id,Result}),
    ?assertEqual({ok,{result,Id,Result}},quod_client_goal_endpoint:decode_response(Envelope)),
    ?assertEqual({ok,{result,Id,Result}},quod_client_goal_endpoint:route_response(Envelope)),
    {ok,HugePayload}=quod_wire_term:encode_bindings(#{<<\"X\">>=>binary:copy(<<$x>>,?QUOD_TRANSPORT_MAX_FRAME_BYTES)},unlimited),
    {ok,Huge}=quod_client_result:encode({answers,1,[HugePayload]}),
    ?assertEqual({error,{too_large,client_goal_endpoint}},
        quod_client_goal_endpoint:encode_response({result,Id,Huge})),
    ?assertEqual(term_to_binary(quod_client_goal_v1,[deterministic]),quod_client_goal_endpoint:channel()).

"""+s[b:]
change('test/quod_client_goal_endpoint_tests.erl',endpoint_test)
def result_test(s):
 a=s.index('aggregate_result_bound_is_identical_before_transport_test()');b=s.index('transient_bindings_use_the_complete_reply_contract_test()',a)
 s=s[:a]+"""complete_results_and_dependencies_have_no_second_allocation_test() ->
    Evidence=maps:get(evidence,fixture()),
    Value=binary:copy(<<$x>>,600000),
    Deps=[{<<\"a\">>,<<1:256>>,7}],
    lists:foreach(fun(Raw) ->
        Result=quod_client_result:normalize(Evidence,{read,Deps,Raw}),
        ?assertMatch({read,Deps,{answers,7,_}},Result),
        {ok,Bytes}=quod_client_result:encode(Result),
        ?assertEqual({ok,Result},quod_client_result:decode(Bytes))
    end,[{ok,[#{0=>Value}],7},{ok,lists:duplicate(50,#{0=>binary:part(Value,0,12000)}),7}]),
    ?assertEqual({read,Deps,{error,proof_unavailable}},
        quod_client_result:normalize(Evidence,{read,Deps,{ok,[#{0=>self()}],7}})),
    ?assertEqual({read,[],{error,proof_unavailable}},
        quod_client_result:normalize(Evidence,{read,[{Value,<<1:256>>,7}],fail})),
    ?assertEqual({read,[],{error,proof_unavailable}},
        quod_client_result:normalize(Evidence,{read,[{<<\"a\">>,bad_anchor,7}],fail})).

"""+s[b:]
 a=s.index('single_and_aggregate_byte_overflow_remain_specific_errors_test()');b=s.index('client_binding_validation_retains_canonical_name_rules_test()',a)
 s=s[:a]+"""large_cursor_answers_preserve_invalid_result_refusal_test() ->
    Evidence=maps:get(evidence,fixture()),Value=binary:copy(<<$x>>,600000),
    ?assertMatch({solution,_,7,_},quod_client_result:normalize(Evidence,{solution,<<7:256>>,#{0=>Value},7})),
    ?assertEqual({error,result_too_large},quod_client_result:normalize(Evidence,{error,{too_large,result}})),
    ?assertEqual({error,invalid_result},quod_client_result:encode({answers,7,[Value]})),
    ?assertEqual({error,proof_unavailable},quod_client_result:normalize(Evidence,{ok,[#{0=>self()}],7})).

"""+s[b:]
 return s.replace('Oversized = <<0:(?QUOD_CLIENT_GOAL_MAX_REPLY_BYTES + 1)/unit:8>>,\n    ?assertEqual({error, result_too_large},','Oversized = <<0:600000/unit:8>>,\n    ?assertEqual({error, invalid_result},')
change('test/quod_client_result_tests.erl',result_test)
emit('presentation-reply-tests')
