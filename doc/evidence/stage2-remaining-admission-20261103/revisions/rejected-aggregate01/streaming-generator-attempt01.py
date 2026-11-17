exec(compile((__import__('pathlib').Path(__file__).parent/'proposal-final.py').read_text(),'proposal-final.py','exec'))
n='src/quod_catchup.erl'
rep(n,'transfer_open/3, transfer_page/2,','transfer_open/3, transfer_page/3,')
rep(n,'current = none, selections = range','current = none, pending = none, selections = range')
rep(n,'''                                         %% frame MUST fit quod_link's 1 MiB cap (it EXITs the link on a
                                         %% larger frame), so we leave headroom for the envelope
''','')
rep(n,'case transfer_page(Store, Cursor) of','case transfer_page(Store, Cursor,\n                       {quod_ledger_store:namespace(Store), {Token, Sequence + 1}}) of')
cut(n,'-doc "Produce the complete selected snapshot','next_transfer_part(_Store', '''-doc "Page one retained proof cursor against its complete consumer frame.".
-spec transfer_page(quod_ledger_store:handle(), transfer_sender() | done,
                    unlimited | {binary(), {binary(), pos_integer()}}) ->
          {ok, [term()], transfer_sender() | done} | {error, term()}.
transfer_page(_Store, done, _Context) -> {ok, [], done};
transfer_page(Store, State, Context) ->
    case page_allowances(Store, Context) of
        {ok, Allowances} -> transfer_page(Store, State, Allowances, [], 0);
        {error, _} = Error -> Error
    end.

page_allowances(_Store, unlimited) -> {ok, {unlimited, unlimited}};
page_allowances(Store, {Ns, Continuation}) ->
    Height = quod_ledger_store:last(Store),
    case {page_part_allowance(Ns, Height, Continuation),
          page_part_allowance(Ns, Height, done)} of
        {{ok, More}, {ok, Done}} -> {ok, {More, Done}};
        _ -> {error, frame_unrepresentable}
    end.

%% The envelope includes the actual namespace, height and continuation integer.
%% Fixed-width request/grant values have identical encoded sizes for every value.
%% Measure the nonempty list wrapper once; each part contributes its ETF body.
page_part_allowance(Ns, Height, Continuation) ->
    Sample = {history_page3, <<0:128>>, <<0:128>>, [end_group], Height,
              Continuation, <<1:128>>},
    {ok, <<131, Body/binary>>} = quod_safe_term:encode_canonical(end_group, unlimited),
    case encode_frame(Ns, Sample) of
        {ok, Frame} -> {ok, ?QUOD_LINK_PAYLOAD_CAPACITY - byte_size(Frame) + byte_size(Body)};
        {error, _} = Error -> Error
    end.

transfer_page(Store, State = #transfer_sender{pending = Pending},
              Allowances = {More, Done}, Acc, Size) ->
    Next = case Pending of
        none -> next_transfer_part(Store, State);
        _ -> {ok, Pending, State#transfer_sender{pending = none}}
    end,
    case Next of
        done -> {ok, lists:reverse(Acc), done};
        {ok, Part, State1} ->
            {ok, <<131, Body/binary>>} = quod_safe_term:encode_canonical(Part, unlimited),
            Allowance = case transfer_complete(State1) of true -> Done; false -> More end,
            Added = byte_size(Body),
            case Allowance =:= unlimited orelse Size + Added =< Allowance of
                true -> transfer_page(Store, State1, Allowances, [Part | Acc], Size + Added);
                false when Acc =:= [] -> {error, frame_unrepresentable};
                false -> {ok, lists:reverse(Acc), State1#transfer_sender{pending = Part}}
            end
    end.

transfer_complete(#transfer_sender{pending = none, current = none, selections = []}) -> true;
transfer_complete(#transfer_sender{pending = none, current = none, selections = range,
                                    next = Next, last = Last}) -> Next > Last;
transfer_complete(_) -> false.

next_transfer_part(Store, State) ->
    case transfer_complete(State) of
        true -> done;
        false -> transfer_part(Store, State)
    end.

''')
rep(n,'next_transfer_part(_Store, #transfer_sender{current = none, selections = []}) -> done;\n','')
rep(n,'next_transfer_part(_Store, #transfer_sender{current = none, selections = range, next = Next, last = Last})\n  when Next > Last -> done;\n','')
# Rename only clause heads, leaving the shared wrapper above as the sole completion owner.
s=get(n);s=re.sub(r'^next_transfer_part\(([^\n]*#transfer_sender[^\n]*)',r'transfer_part(\1',s,flags=re.M);put(n,s)
rep(n,'(Reason =:= not_ready orelse Reason =:= server_error)','(Reason =:= not_ready orelse Reason =:= server_error orelse Reason =:= frame_unrepresentable)')
rep(n,'            {error, _} -> Owner ! {reader_result, Token, self(), {error, not_ready}}','''            {error, frame_unrepresentable} = Error ->
                Owner ! {reader_result, Token, self(), Error};
            {error, _} -> Owner ! {reader_result, Token, self(), {error, not_ready}}''')
n='src/quod_link.erl'
rep(n,'{error, not_ready | server_error})','{error, not_ready | server_error | frame_unrepresentable})')
rep(n,'Reason =:= not_ready; Reason =:= server_error ->','Reason =:= not_ready; Reason =:= server_error; Reason =:= frame_unrepresentable ->')
rep(n,'''        {error, _} -> quod_catchup:encode_frame(
                       Ns, {history_error3, Grant, ReqId, server_error, Next})''','''        {error, too_large} -> quod_catchup:encode_frame(
                              Ns, {history_error3, Grant, ReqId, frame_unrepresentable, Next});
        {error, Reason} -> protocol_failed(Reason, S)''')
# The local borrowed-view consumer has no enclosing transport frame.
rep('src/quod_foreign_log.erl','quod_catchup:transfer_page(Store, Sender)','quod_catchup:transfer_page(Store, Sender, unlimited)')
# Existing local cursor fixtures explicitly select their actual local consumer.
# Their legacy quota assertions are separately inventoried for replacement, not silently deleted.
def add_argument(s,needle,arg):
 at=0
 while True:
  at=s.find(needle,at)
  if at<0:return s
  start=at+len(needle);depth=1;i=start;quote=None;escape=False
  while depth:
   c=s[i]
   if quote:
    if escape:escape=False
    elif c=='\\':escape=True
    elif c==quote:quote=None
   elif c in ['"',"'"]:quote=c
   elif c=='(':depth+=1
   elif c==')':depth-=1
   i+=1
  s=s[:i-1]+', '+arg+s[i-1:];at=i+len(arg)+2
for n in ['test/quod_catchup_tests.erl','test/quod_foreign_log_tests.erl','test/quod_entry_selection_tests.erl']:
 put(n,add_argument(get(n),'quod_catchup:transfer_page(','unlimited'))
# Records/counters remain ABI-compatible with Quod's fresh/committed state resets.
# Erlog count ceilings are removed; the counters still report proof-local state.
rep('_build/default/lib/erlog/src/erlog_int.hrl','default uses Erlog\'s native portable-term bounds; embedders may','default checks native portable terms; embedders may')
emit()
# Keep dependency changes out of any worktree application patch.
p=E/'proposals';m=json.loads((p/'manifest.json').read_text());repo=[];dep=[]
for n in m['files']:
 diff=list(difflib.unified_diff(B[n].splitlines(True),D[n].splitlines(True),fromfile='a/'+n,tofile='b/'+n))
 if n.startswith('_build/default/lib/erlog/'):
  diff=[x.replace('_build/default/lib/erlog/','') if x.startswith(('---','+++')) else x for x in diff];dep.extend(diff)
 else:repo.extend(diff)
(p/'remaining-owners.patch').write_text(''.join(repo));(p/'erlog-diagnostics.patch').write_text(''.join(dep))
m['dependency']={'pin':'535395c60b2133703308bbe529a63309672cb7a0','patch':'erlog-diagnostics.patch','installed':False,'pin_changed':False,'requires_reviewed_dependency_revision':True}
m['production_applied_delta']={'added':0,'removed':0};m['revision']='streaming02'
(p/'manifest.json').write_text(json.dumps(m,indent=2)+'\n')
