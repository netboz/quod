exec(compile((__import__('pathlib').Path(__file__).parent/'proposal-streaming.py').read_text(),'proposal-streaming.py','exec'))
n='src/quod_catchup.erl'
rep(n,'current = none, pending = none, selections = range','current = none, pending = [], selections = range')
cut(n,'transfer_page(Store, State = #transfer_sender{pending = Pending},','transfer_complete(#transfer_sender', '''transfer_page(Store, State, Allowances = {More, _Done}, Acc, Size) ->
    case take_transfer_part(Store, State) of
        done -> {ok, lists:reverse(Acc), done};
        {ok, Part, State1} ->
            Added = part_body_size(Part),
            case More =:= unlimited orelse Size + Added =< More of
                true -> transfer_page(Store, State1, Allowances, [Part | Acc], Size + Added);
                false -> finish_page(Store, State1, Allowances, Acc, [Part], Size + Added)
            end
    end.

%% A terminal envelope is smaller than a continuation envelope. Retain only
%% the lookahead which could still complete that terminal frame. If it cannot,
%% emit the already representable prefix and retain every read part exactly once.
finish_page(Store, State, Allowances = {_More, Done}, Prefix, Tail, Size) ->
    case Done =:= unlimited orelse Size =< Done of
        false -> deferred_page(State, Prefix, Tail);
        true ->
            case take_transfer_part(Store, State) of
                done -> {ok, lists:reverse(Prefix) ++ lists:reverse(Tail), done};
                {ok, Part, State1} ->
                    finish_page(Store, State1, Allowances, Prefix, [Part | Tail],
                                Size + part_body_size(Part))
            end
    end.

deferred_page(_State, [], _Tail) -> {error, frame_unrepresentable};
deferred_page(State = #transfer_sender{pending = Pending}, Prefix, Tail) ->
    {ok, lists:reverse(Prefix),
     State#transfer_sender{pending = lists:reverse(Tail) ++ Pending}}.

part_body_size(Part) ->
    {ok, <<131, Body/binary>>} = quod_safe_term:encode_canonical(Part, unlimited),
    byte_size(Body).

take_transfer_part(Store, State = #transfer_sender{pending = []}) ->
    next_transfer_part(Store, State);
take_transfer_part(_Store, State = #transfer_sender{pending = [Part | Rest]}) ->
    {ok, Part, State#transfer_sender{pending = Rest}}.

''')
rep(n,'#transfer_sender{pending = none, current = none','#transfer_sender{pending = [], current = none')
rep('src/quod_foreign_log.erl','         length(Endpoints) =< 2 andalso\n','')
# No pinned record layout change: proof-local diagnostic counters remain compatible.
emit()
# Preserve the runtime/dependency split for the review boundary.
p=E/'proposals';m=json.loads((p/'manifest.json').read_text());repo=[];dep=[]
for n in m['files']:
 diff=list(difflib.unified_diff(B[n].splitlines(True),D[n].splitlines(True),fromfile='a/'+n,tofile='b/'+n))
 if n.startswith('_build/default/lib/erlog/'):
  diff=[x.replace('_build/default/lib/erlog/','') if x.startswith(('---','+++')) else x for x in diff];dep.extend(diff)
 else:repo.extend(diff)
(p/'remaining-owners.patch').write_text(''.join(repo));(p/'erlog-diagnostics.patch').write_text(''.join(dep))
m['dependency']={'pin':'535395c60b2133703308bbe529a63309672cb7a0','patch':'erlog-diagnostics.patch','installed':False,'pin_changed':False,'requires_reviewed_dependency_revision':True}
m['production_applied_delta']={'added':0,'removed':0};m['revision']='streaming03'
(p/'manifest.json').write_text(json.dumps(m,indent=2)+'\n')
