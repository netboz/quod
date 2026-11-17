from pathlib import Path
import re,difflib,json,hashlib,subprocess
R=Path('/home/yan/src/quod_worktrees/pearl-stone'); E=Path(__file__).resolve().parent
D={}; B={}
def get(n):
 if n not in D:
  B[n]=(R/n).read_text(); D[n]=B[n]
 return D[n]
def put(n,s): get(n);D[n]=s
def rep(n,a,b):
 s=get(n);assert a in s,(n,a);D[n]=s.replace(a,b)
def cut(n,a,b,replacement=''):
 s=get(n); i=s.index(a);j=s.index(b,i);D[n]=s[:i]+replacement+s[j:]
# Committee shape and certification remain shared; actual committee size owns signature counts.
n='src/quod_quorum.erl'
rep(n,'Shared bounded verification','Shared verification')
rep(n,'-include("quod_ingress_limits.hrl").\n\n','')
rep(n,'committee_size([<<_:256>> = Key | Rest], Count, Seen)\n  when Count < ?MAX_VALIDATORS ->','committee_size([<<_:256>> = Key | Rest], Count, Seen) ->')
rep(n,'_MalformedDuplicateOrTooLarge','_MalformedOrDuplicate')
rep(n,'nonempty bounded certificate','nonempty certificate')
rep(n,'valid_signature_list(Signatures, ?MAX_VALIDATORS)','valid_signature_list(Signatures, unlimited)')
rep(n,'-spec valid_signature_list(term(), non_neg_integer())','-spec valid_signature_list(term(), non_neg_integer() | unlimited)')
rep(n,'valid_signature_list(Signatures, Maximum) when','valid_signature_list(Signatures, unlimited) ->\n    signature_rows(Signatures);\nvalid_signature_list(Signatures, Maximum) when')
rep(n,'bounded_signatures([], _Remaining) -> true;', 'signature_rows([]) -> true;\nsignature_rows([{<<_:256>>, <<_:512>>} | Rest]) -> signature_rows(Rest);\nsignature_rows(_) -> false.\n\nbounded_signatures([], _Remaining) -> true;')
rep('src/quod_agent_identity.erl','?MAX_VALIDATORS','unlimited')
for n in ['src/quod_dtx_current_view.erl','src/quod_dtx_coordinator.erl','src/quod_signing_journal.erl','src/quod_foreign_log.erl','src/quod_simplex.erl']:
 s=get(n)
 s=re.sub(r',\s*(?:length|map_size)\([A-Za-z]+\) =< \?MAX_VALIDATORS','',s)
 s=s.replace(' andalso length(Adds) =< ?MAX_VALIDATORS','').replace(' andalso length(Next) =< ?MAX_VALIDATORS','')
 put(n,s)
n='src/quod_simplex.erl'
cut(n,'                    Count = length(founding(Cfg, maps:get(node_id, Cfg))),','                false -> {error, {bad_committee, L}}', '                    valid_mode(Cfg);\n')
n='src/predicates/quod_committee_predicates.erl'
rep(n,'case {self_ns(St), committee_size(St) < ?MAX_VALIDATORS} of\n                {undefined, _} -> erlog_int:fail(St);\n                {_Ns, false} -> quod_predicates:fail_reason(committee_full,St);\n                {Ns, true} ->','case self_ns(St) of\n                undefined -> erlog_int:fail(St);\n                Ns ->')
n='src/quod_foreign_log.erl'
rep(n,'-define(MAX_CURRENT_ROUTE_HINTS, (2 * ?MAX_VALIDATORS)).\n','')
rep(n,'normalize_route_candidates(Routes, 0, [])','normalize_route_candidates(Routes, [])')
rep(n,'normalize_route_candidates([], _Count, Acc)','normalize_route_candidates([], Acc)')
rep(n,'[{<<_:256>> = Peer, Endpoints0} | Rest], Count, Acc)\n  when is_list(Endpoints0), Count < ?MAX_VALIDATORS ->','[{<<_:256>> = Peer, Endpoints0} | Rest], Acc)\n  when is_list(Endpoints0) ->')
rep(n,'Rest, Count + 1, [{Peer, Endpoints} | Acc]','Rest, [{Peer, Endpoints} | Acc]')
rep(n,'normalize_route_candidates(_, _Count, _Acc)','normalize_route_candidates(_, _Acc)')
rep(n,'Routes = lists:sublist(\n               stable_unique_routes(Request ++ Live ++ Supplied ++ Bootstrap),\n               ?MAX_VALIDATORS),','Routes = stable_unique_routes(Request ++ Live ++ Supplied ++ Bootstrap),')
# This eviction helper and drop_first have no other callers (caller inventory retained).
cut(n,'put_bootstrap_hint(PeerKey, Endpoint, Hints0, Projection) ->','%% `entry` asks', '''put_bootstrap_hint(PeerKey, Endpoint, Hints0, _Projection) ->
    WithoutPeer = [{Peer, Ep} || {Peer, Ep} <- Hints0, Peer =/= PeerKey],
    {[{PeerKey, Endpoint} | WithoutPeer], 0}.

''')
rep(n,'bounded_committee(Committee, 0)','quod_quorum:committee_size(Committee) =/= error')
cut(n,'bounded_committee([], _Count)','valid_dtx_target(')
# Semantic singleton remains; payload quotas are not descriptor semantics.
n='src/quod_dtx.erl'
rep(n,'{ok, BridgesBlob}, {ok, TranscriptBlob}}\n          when byte_size(EffectsBlob) =< ?QUOD_MAX_DIRECT_EFFECT_BYTES ->','{ok, BridgesBlob}, {ok, TranscriptBlob}} ->')
cut(n,'        {{ok, _}, {ok, _}, {ok, EffectsBlob}, {ok, _}, {ok, _}}','        _ ->\n            {error, {too_large, plan}};') if False else None
rep(n,'        {{ok, _}, {ok, _}, {ok, EffectsBlob}, {ok, _}, {ok, _}}\n          when byte_size(EffectsBlob) > ?QUOD_MAX_DIRECT_EFFECT_BYTES ->\n            {error, {too_large, effects}};\n','')
rep(n,'        byte_size(Effects) =< ?QUOD_MAX_DIRECT_EFFECT_BYTES andalso\n','')
n='src/quod_transaction.erl'
rep(n,'{ok, ForeignReads}, true}\n          when byte_size(EffectsWire) =< ?QUOD_MAX_DIRECT_EFFECT_BYTES ->','{ok, ForeignReads}, true} ->')
rep(n,'?QUOD_MAX_DIRECT_EFFECT_BYTES','unlimited')
# Authenticated client vocabulary retains explicit configured finite overrides and rates.
n='src/quod_wire_term.erl'
rep(n,'-include("quod_vm_limits.hrl").\n','')
rep(n,'{ok, Symbols}\n          when map_size(Symbols) =< ?QUOD_MAX_NEW_MATERIAL_ATOMS ->','{ok, Symbols} ->')
rep(n,'        {ok, _TooMany} ->\n            {error, too_many_new_atoms};\n','')
rep(n,'malformed_material | too_many_new_atoms | atom_limit','malformed_material | atom_limit')
rep(n,'case atom_headroom(length(Names)) of','case atom_headroom(length([N || N <- Names, not existing_symbol(N)])) of')
rep(n,'erlang:system_info(atom_count) + NewAtoms + ?QUOD_ATOM_SAFETY_MARGIN <','erlang:system_info(atom_count) + NewAtoms =<')
rep(n,'collect_new_symbols({\'$quod_symbol\', Name}, Acc)', '''existing_symbol(Name) ->
    try binary_to_existing_atom(Name, utf8), true
    catch error:badarg -> false end.

collect_new_symbols({'$quod_symbol', Name}, Acc)''')
rep('src/quod_agent_ref.erl','-include("quod_vm_limits.hrl").\n','')
put('include/quod_vm_limits.hrl','')
n='src/quod_client_auth.erl'
rep(n,'max_materialized_atoms :: non_neg_integer()','max_materialized_atoms :: non_neg_integer() | unlimited')
rep(n,'?QUOD_CLIENT_MAX_CUMULATIVE_NEW_ATOMS','unlimited')
rep(n,'case Used + Count =< Max of','case Max =:= unlimited orelse Used + Count =< Max of')
rep(n,'%% existing materializer still enforces per-request and VM\n                    %% headroom limits shared with every other wire boundary.','%% shared materializer checks actual VM atom capacity. Explicit\n                    %% finite owner allowances and rates remain enforced above.')
n='include/quod_client_goal_limits.hrl'
cut(n,'%% Ordinary client traffic','%% Node-wide signed-goal', '%% Client rates and finite vocabulary overrides remain explicit owner options;\n%% there is no built-in cumulative vocabulary quota.\n\n')
# Pending work: retain ordering, exact reservation identity, custody and wake fingerprints.
n='src/quod_atomic_admission.erl'
rep(n,'-include("quod_ingress_limits.hrl").\n','')
rep(n,'trace_context/2, counts/1, has_capacity/2','trace_context/2, counts/1')
rep(n,'invalid_dtx_intent | busy','invalid_dtx_intent')
rep(n,'        false when map_size(ById) >= ?MAX_INGRESS_TXS -> {error, busy};\n','')
rep(n,'has_capacity(Id, {ById, _}) -> maps:is_key(Id, ById) orelse map_size(ById) < ?MAX_INGRESS_TXS.\n','')
n='src/quod_simplex.erl'
rep(n,'                    Prior = admission_state(S0),\n','')
cut(n,'                    case maps:is_key(Id, Pending) orelse','            end;\n        error -> {error, invalid_dtx_submission}', '''                    S = refresh_dtx_admission_engine(S0), A = admission_state(S),
                    Rows = quod_atomic_admission:admit(
                             Chosen, Waiter, quod_trace:context(), A#dtx_admission.waiting),
                    {ok, schedule_dtx_drive(S#s{dtx_admission = A#dtx_admission{waiting = Rows}})}
''')
n='src/quod_ingress_state.erl'
rep(n,'bounded parked queue','parked queue')
rep(n,'-define(MAX_INGRESS_BYTES, (2 * ?MAX_BLOCK_BYTES)).\n-define(MAX_INGRESS_PER_AUTHOR, 64).\n\n','')
rep(n,'{reject, bad_change | too_large | stale_seq}','{reject, bad_change | stale_seq}')
rep(n,'item_bytes = unknown :: unknown | pos_integer()','item_bytes = unknown :: unknown | invalid | pos_integer()')
cut(n,'    SignedBytes =\n','prepare_request(Request = #request{', '''    ItemBytes = case quod_transaction:encoded_ledger_transaction_size(Change) of
        {ok, Size} -> ?BATCH_ENVELOPE_BYTES + Size;
        {error, _} -> invalid
    end,
    Request#request{membership = Membership, item_bytes = ItemBytes};
''')
rep(n,'{ok, pos_integer(), state()} | full.','{ok, pos_integer(), state()}.')
s=get(n);i=s.index('    case Count >= ?MAX_INGRESS_TXS');j=s.index(';\nenqueue(_Context',i)
body=s[s.index('            Item = #item{',i):j].rsplit('    end',1)[0]
body='\n'.join(line[8:] if line.startswith('        ') else line for line in body.splitlines()).rstrip()
put(n,s[:i]+body+s[j:])
rep(n,'{too_large, Prepared} ->\n                            {{reject, too_large}, Prepared}', '{invalid, Prepared} ->\n                            {{reject, bad_change}, Prepared}')
rep(n,'{too_large, Prepared} ->\n                                    {{reject, too_large}, Prepared}', '{invalid, Prepared} ->\n                                    {{park, awaiting_turn}, Prepared}')
rep(n,'{too_large, Prepared} ->\n                    {{reject, too_large}, Prepared}', '{invalid, Prepared} ->\n                    {{reject, bad_change}, Prepared}')
rep(n,'case oversized(Prepared) of\n        true -> {too_large, Prepared};\n        false -> {ok, Prepared}', 'case Prepared#request.item_bytes of\n        invalid -> {invalid, Prepared};\n        _ -> {ok, Prepared}')
cut(n,'admissible_without_queue(\n','custody_sequence_status(', '''admissible_without_queue(
  #request{membership = Membership},
  #view{membership_open = MembershipOpen, collecting = Collecting}) ->
    (not Membership orelse MembershipOpen) andalso
        (Collecting =:= none orelse not Membership).

''')
n='src/quod_simplex.erl'
cut(n,'%% Park one append at the queue tail. Overflow','%% Retained signed work drains', '''%% Park one append at the queue tail; the existing owner retains FIFO demand.
park_ingress(Origin, Cause, Waiter, Request, Anchor,
             S = #s{ingress = Ingress}) ->
    {ok, Depth, Ingress1} = quod_ingress_state:enqueue(
                            Origin, Waiter, Request, Anchor, Ingress),
    _ = quod_trace:add_event(
          waiter_trace_ctx(Waiter), <<"consensus.parked">>,
          #{'quod.ingress.depth' => Depth, 'quod.ingress.cause' => Cause}),
    S1 = S#s{ingress = Ingress1},
    {watch_requested((S1#s.eng)#eng.view, S1), []}.

''')
cut(n,'encoded_change_size(Change) ->','consensus_barrier(S) ->', '''encoded_change_size(Change) ->
    %% Collection is reached only with a canonically validated transaction.
    {ok, Blob} = quod_transaction:encode_ledger_transaction(Change),
    byte_size(Blob).

''')
rep(n,'{ok, Bytes} -> Bytes =< ?MAX_BLOCK_BYTES;','{ok, _Bytes} -> true;')
rep(n,'%% Capacity and membership gating live in `quod_ingress_state`','%% Membership and FIFO gating live in `quod_ingress_state`')
# Derived quota header has one remaining meaningful owner: exact batch encoding accounting.
put('include/quod_ingress_limits.hrl','''-ifndef(QUOD_INGRESS_LIMITS_HRL).
-define(QUOD_INGRESS_LIMITS_HRL, true).

-include("quod_transport_limits.hrl").

%% ETF overhead for `{batch, [First]}` beyond First's standalone encoding.
%% This accounts bytes; it is not an admission quota.
-define(BATCH_ENVELOPE_BYTES, 15).
-endif.
''')
# Finite complete transport capacity replaces duplicate endpoint/page quota.
n='src/quod_dtx_endpoint.erl'
cut(n,'-if(?QUOD_DTX_ENDPOINT_MAX_ENVELOPE_BYTES','-type request_id()')
rep(n,'?QUOD_DTX_ENDPOINT_MAX_ENVELOPE_BYTES','?QUOD_LINK_PAYLOAD_CAPACITY')
rep(n,'{ok, Bytes} -> byte_size(Bytes) =< ?QUOD_MAX_FOREIGN_PAGE_BYTES;','{ok, _Bytes} -> true;')
rep(n,'    byte_size(Blob) > 0 andalso\n        byte_size(Blob) < ?QUOD_LINK_PAYLOAD_CAPACITY;','    byte_size(Blob) > 0;')
# Proposal artifact writer only. No production paths are written.
P=E/'proposals';P.mkdir(exist_ok=True)
def emit():
 rows={};patch=[]
 for n,s in sorted(D.items()):
  if s==B[n]:continue
  a=E/'proposal-before'/n;b=E/'proposal-after'/n
  a.parent.mkdir(parents=True,exist_ok=True);b.parent.mkdir(parents=True,exist_ok=True)
  a.write_text(B[n]);b.write_text(s)
  diff=list(difflib.unified_diff(B[n].splitlines(True),s.splitlines(True),fromfile='a/'+n,tofile='b/'+n))
  patch.extend(diff)
  rows[n]={'before':hashlib.sha256(B[n].encode()).hexdigest(),'after':hashlib.sha256(s.encode()).hexdigest(),'added':sum(x.startswith('+') and not x.startswith('+++') for x in diff),'removed':sum(x.startswith('-') and not x.startswith('---') for x in diff)}
 (P/'remaining-owners.patch').write_text(''.join(patch))
 (P/'manifest.json').write_text(json.dumps({'applied':False,'runtime_verified':False,'files':rows,'added':sum(v['added'] for v in rows.values()),'removed':sum(v['removed'] for v in rows.values())},indent=2)+'\n')
if __name__=='__main__':emit()
