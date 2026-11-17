"""Generate revision 03 UNAPPLIED patches. Never writes product/test sources."""
from pathlib import Path
import difflib, hashlib, json

r = Path('/home/yan/src/quod_worktrees/pearl-stone')
e = Path(__file__).resolve().parent
original = (e / 'propose.py').read_text()
hook = """
bundles = {}
def emit(label):
    bundles[label] = dict(changes)
    changes.clear()
"""
original = original.replace("change('include/quod_proof_limits.hrl'", hook + "\nchange('include/quod_proof_limits.hrl'", 1)
ns = {'__file__': str(e / 'propose.py')}
exec(compile(original, str(e / 'propose.py'), 'exec'), ns)
bundles = ns['bundles']
out = e / 'proposals-revision03'
out.mkdir(exist_ok=True)

def edit(label, path, fn):
    bundle = bundles.setdefault(label, {})
    before, after = bundle.get(path, ((r / path).read_text(), (r / path).read_text()))
    changed = fn(after)
    assert changed != after, (label, path)
    bundle[path] = (before, changed)

def replace_once(s, old, new):
    assert s.count(old) == 1, (old, s.count(old))
    return s.replace(old, new, 1)

for path in ['src/quod_dtx.erl', 'src/predicates/quod_ask.erl']:
    edit('nested-goal-owner', path, lambda s: s.replace('GoalBlob, byte_size(GoalBlob)', 'GoalBlob, ?QUOD_MAX_PLAN_ENVELOPE_BYTES'))
edit('nested-goal-owner', 'src/quod_proof_session.erl', lambda s: replace_once(s,
    '        _ ->\n            {error, {too_large, goal}}\n    end.',
    '        {error, bad_term} ->\n            {error, {protocol_error, bad_payload}}\n    end.'))

def result(s):
    s = s.replace('One closed, bounded signed-client proof result', 'One closed signed-client proof result')
    s = s.replace("names and encoded with the shared canonical binding codec. The complete reply\nowns the byte allowance; transient reads do not consume a durable-result budget.",
                  "names and encoded with the shared canonical binding codec. Proof answer policy\nowns answer allocation; remote delivery retains complete transport admission.")
    s = s.replace('-include("quod_client_goal_limits.hrl").\n', '')
    s = s.replace('        {error, result_too_large} = Error -> Error;\n', '')
    s = s.replace('        {{error, result_too_large} = Error, {ok, _}} -> Error;\n', '')
    s = s.replace('                {error, too_large} -> {error, result_too_large};\n', '')
    s = s.replace('{error, result_too_large | invalid_result}', '{error, invalid_result}')
    s = s.replace('bounded(', 'validated(').replace('bounded_error(', 'invalid_result(')
    start = s.index('validated(Result) ->')
    end = s.index('\nencode_bindings(Evidence, Bindings) ->', start)
    s = s[:start] + '''validated(Result) ->
    case valid_result(Result) of
        true -> Result;
        false -> invalid_result(Result)
    end.

invalid_result({read, Dependencies, _}) ->
    {read, Dependencies, {error, proof_unavailable}};
invalid_result(_) -> {error, proof_unavailable}.
''' + s[end:]
    s = s.replace('decode(Blob) when is_binary(Blob) ->',
        '%% The enclosing endpoint or admitted local caller owns byte allocation.\ndecode(Blob) when is_binary(Blob) ->')
    s = s.replace('already carried by the bounded client reply', 'already carried by the admitted client reply')
    s = s.replace('{error, bad_term | invalid_result | too_large}', '{error, bad_term | invalid_result}')
    return s
edit('presentation-reply-owner', 'src/quod_client_result.erl', result)

def router(s):
    start = s.index('send_result_response(Link, {Kind, RequestId, Result}) ->')
    end = s.index('\npreexecution_reply(', start)
    s = s[:start] + '''send_result_response(Link, Response) ->
    Index = tuple_size(Response),
    Blob = case quod_client_result:encode(element(Index, Response)) of
        {ok, Encoded} -> Encoded;
        {error, invalid_result} ->
            {ok, Error} = quod_client_result:encode({error, proof_unavailable}),
            Error
    end,
    send_response(Link, setelement(Index, Response, Blob)).
''' + s[end:]
    return replace_once(s, '''        {ok, Frame} -> quod_link:send_ordered(Link, Frame);
        {error, _} -> ok
    end.''', '''        {ok, Frame} -> quod_link:send_ordered(Link, Frame);
        {error, {too_large, client_goal_endpoint}}
          when element(1, Response) =:= result;
               element(1, Response) =:= cursor_result ->
            %% This is a delivery refusal, never permission to execute again.
            %% Keep the exact request/cursor correlation on the error result.
            {ok, Blob} = quod_client_result:encode({error, result_too_large}),
            Refusal = setelement(tuple_size(Response), Response, Blob),
            {ok, Frame} = quod_client_goal_endpoint:encode_response(Refusal),
            quod_link:send_ordered(Link, Frame);
        {error, _} -> ok
    end.''')
edit('presentation-reply-owner', 'src/quod_client_goal_router.erl', router)

def terrain_wire(s):
    start = s.index('%% View and resource tokens')
    end = s.index('decimal(N)', start)
    s = s[:start] + 'chunk(I,Payload) -> #{index => I,payload => b64(Payload)}.\n' + s[end:]
    s = s.replace('Pure terrain message encoding and packing under the existing view-frame bound.',
                  'Pure encoding of the resource owner\'s complete terrain selection.')
    s = s.replace('-include("quod_client_goal_limits.hrl").\n', '').replace('-export([message/1, admit/3, batch/2]).', '-export([message/1]).')
    return s
edit('presentation-reply-owner', 'src/quod_terrain_wire.erl', terrain_wire)

def physics(s):
    s = s.replace('        {{terrain_chunks,Token,{through,Index}},{through,Index}} -> V#{credit => true};\n', '')
    start = s.index('                    case quod_terrain_wire:admit(Token,Interest,Rows) of')
    end = s.index('\n                {error,Reason} ->', start)
    s = s[:start] + '''                    send_view_resource({terrain_manifest,Token,Interest,[maps:remove(payload,R) || R <- Rows]},V),
                    S#s{viewer = V#{terrain_source => SourceKey,terrain_snapshot => Rows,
                        terrain_token => Token,terrain_complete => false,terrain_wanted => [],
                        delivery => {terrain_manifest,Token},credit => false}};''' + s[end:]
    start = s.index('            {Batch,Remaining} = quod_terrain_wire:batch(Token,Chunks),')
    end = s.index('\n    end.', start)
    return s[:start] + '''            send_view_resource({terrain_chunks,Token,Chunks,true},V),
            S#s{viewer = V#{delivery => {terrain_chunks,Token,complete},credit => false}}''' + s[end:]
edit('presentation-reply-owner', 'src/quod_physics.erl', physics)
edit('presentation-reply-owner', 'src/quod_client_view.erl', lambda s: s.replace('                    #{<<"through">> := Index} when is_integer(Index),Index >= 0 -> {through,Index};\n', ''))
def simulation(s):
    s = s.replace("require(Array.isArray(message.chunks) && typeof message.complete === 'boolean' &&\n        (message.complete || message.chunks.length > 0) &&", "require(Array.isArray(message.chunks) && message.complete === true &&")
    s = s.replace("      const acknowledgement = message.complete ? { complete: true } : { through: message.chunks.at(-1).index }\n", '')
    s = s.replace('...acknowledgement', 'complete: true')
    s = s.replace('message.chunks.length <= missing.length &&\n        message.complete === (message.chunks.length === missing.length)', 'message.chunks.length === missing.length')
    return s.replace('if (message.complete && manifestInterest === interest)', 'if (manifestInterest === interest)')
edit('presentation-reply-owner', 'client/src/simulation.js', simulation)
edit('presentation-reply-owner', 'include/quod_client_goal_limits.hrl', lambda s: s.replace('%% Legacy terrain resource packing quota; its remaining callers are separately\n%% identified for retirement. Ordinary signed results/views have no subquota.\n-define(QUOD_CLIENT_GOAL_MAX_REPLY_BYTES, (512 * 1024)).\n\n', ''))

# Optional policy semantics: the VM counters are used, not summed binary refs.
def memory(s):
    s = replace_once(s, '            {total_heap_size, Words} = process_info(self(), total_heap_size),', '''            {garbage_collection_info, Info} = process_info(self(), garbage_collection_info),
            Counters = maps:from_list(Info),
            %% Use the VM's heap blocks and binary virtual-heap word counters.
            %% Binary reference lists are not the max_heap_size accounting unit.
            Words = lists:sum([maps:get(Key, Counters) || Key <-
                [heap_block_size, old_heap_block_size, mbuf_size,
                 bin_vheap_size, bin_old_vheap_size]]),''')
    return replace_once(s, '#{size => MaxWords, kill => true, error_logger => true}',
        '#{size => MaxWords, kill => true, error_logger => true,\n                                       include_shared_binaries => true}')
edit('optional-shared-binary-owner', 'src/quod_proof_session.erl', memory)

# Additional test/doc proposal transforms are kept separate from runtime patches.
exec(compile((e / 'revision03_tests.py').read_text(), str(e / 'revision03_tests.py'), 'exec'))

for label, changes in bundles.items():
    patch, rows = [], []
    for path, (before, after) in changes.items():
        assert before != after, path
        delta = list(difflib.unified_diff(before.splitlines(True), after.splitlines(True), fromfile='a/' + path, tofile='b/' + path))
        patch += delta
        rows.append({'path': path, 'before_sha256': hashlib.sha256(before.encode()).hexdigest(),
                     'proposed_sha256': hashlib.sha256(after.encode()).hexdigest(),
                     'added': sum(x.startswith('+') and not x.startswith('+++') for x in delta),
                     'removed': sum(x.startswith('-') and not x.startswith('---') for x in delta)})
    (out / (label + '.patch')).write_text(''.join(patch))
    (out / (label + '.json')).write_text(json.dumps({'revision': 3, 'applied': False,
        'compiled_or_executed': False, 'files': rows, 'added': sum(x['added'] for x in rows),
        'removed': sum(x['removed'] for x in rows)}, indent=2) + '\n')
print(json.dumps({'proposal_revision': 3, 'artifacts': list(bundles), 'runtime_executed': False}))
