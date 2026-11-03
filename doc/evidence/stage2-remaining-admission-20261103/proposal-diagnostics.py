# Executes artifact generation only, never proposed modules.
exec(compile((__import__('pathlib').Path(__file__).parent/'proposal-history.py').read_text(),'proposal-history.py','exec'))
n='src/quod_transaction.erl'
rep(n,'?QUOD_DTX_ENDPOINT_MAX_ENVELOPE_BYTES','unlimited')
rep(n,'when is_binary(Blob),\n       byte_size(Blob) =< unlimited ->','when is_binary(Blob) ->')
rep(n,'''                    %% Evidence is one transport frame, not a new semantic
                    %% quota.  Reuse the existing durable-operation envelope
                    %% bound so this codec and its only carrier cannot disagree.''','''                    %% The endpoint admits its complete envelope. This codec
                    %% validates exact evidence without a nested byte quota.''')
n='src/quod_ingress_state.erl'
rep(n,'       is_integer(ItemBytes), ItemBytes > 0 ->\n    Request.', '       (ItemBytes =:= invalid orelse (is_integer(ItemBytes) andalso ItemBytes > 0)) ->\n    Request.')
# Do not relabel malformed material as a resource overflow.
rep('src/quod_dtx.erl','{error, {too_large, plan}}\n    end.', '{error, malformed_material}\n    end.')
# Pinned dependency proposal: same owner/policy callback; no interpreter dispatch changes.
n='_build/default/lib/erlog/src/erlog_int.erl'
rep(n,'case Count < ?ERLOG_MAX_FAILURE_REASONS andalso\n\t failure_stack_allowed(Candidate, Policy) of','case failure_stack_allowed(Candidate, Policy) of')
rep(n,'case Count < ?ERLOG_MAX_FAILURE_REASONS - 1 andalso\n\t failure_stack_allowed(Reserved, Policy) of','case failure_stack_allowed(Reserved, Policy) of')
rep(n,'    true = Count < ?ERLOG_MAX_FAILURE_REASONS,\n','')
cut(n,'failure_stack_allowed(Reasons, native) ->','portable_failure_reason(T)', '''failure_stack_allowed(Reasons, native) ->
    valid_failure_stack_shape(Reasons);
failure_stack_allowed(Reasons, {Mod,Fun}) ->
    valid_failure_stack_shape(Reasons) andalso
        try Mod:Fun(Reasons) =:= true catch _:_ -> false end.

valid_failure_stack_shape([Reason|Reasons]) ->
    valid_failure_reason(Reason) andalso valid_failure_stack_shape(Reasons);
valid_failure_stack_shape([]) -> true;
valid_failure_stack_shape(_) -> false.

''')
rep(n,'\tfalse when Count < ?ERLOG_MAX_FAILURE_BOUNDARIES ->','\tfalse ->')
rep(n,'\t\t   fail_boundaries=Count+1};\n\tfalse ->\n\t    mark_failure_reasons_truncated(St)','\t\t   fail_boundaries=Count+1}')
n='_build/default/lib/erlog/src/erlog_int.hrl'
cut(n,'%% Failure diagnostics are transient interpreter state.','%% Define the interpreter state record.')
n='src/quod_wire_term.erl'
cut(n,'decode_failure_reasons(Blob)\n','-doc "Return whether a full stack', '''decode_failure_reasons(Blob) when is_binary(Blob) ->
    case quod_safe_term:decode(Blob, unlimited) of
        {ok, Wire} -> decode_failure_reason_wire(Blob, Wire);
        {error, _} -> {error, bad_term}
    end;
decode_failure_reasons(_) -> {error, bad_term}.

''')
rep(n,'validate_failure_reasons(Reasons, 0)','validate_failure_reasons(Reasons)')
cut(n,'validate_failure_reasons([],','decode_failure_reason_wire(Blob, Wire) ->', '''validate_failure_reasons([]) -> ok;
validate_failure_reasons([Reason | Rest]) ->
    case validate_failure_reason(Reason) of
        ok -> validate_failure_reasons(Rest);
        {error, _} = Error -> Error
    end;
validate_failure_reasons(_) -> {error, bad_term}.

validate_failure_reason(Reason) ->
    case encode(Reason) of
        {ok, _Wire} ->
            case erlog_int:valid_failure_reason(Reason) of
                true -> ok;
                false -> {error, bad_term}
            end;
        {error, bad_term} -> {error, bad_term}
    end.

encode_failure_reason_stack(Reasons) ->
    case encode(Reasons) of
        {ok, Wire} -> {ok, canonical(Wire)};
        {error, bad_term} -> {error, bad_term}
    end.

''')
rep(n,'{error, bad_term | too_large}.\nencode_failure_reasons','{error, bad_term}.\nencode_failure_reasons')
rep(n,'{error, bad_term | too_large}.\ndecode_failure_reasons','{error, bad_term}.\ndecode_failure_reasons')
n='src/quod_scope_wire.erl'
rep(n,'payload_limit(failure_reasons) -> {ok, ?ERLOG_MAX_FAILURE_REASONS_BYTES};\npayload_limit(erlog_error) -> {ok, ?ERLOG_MAX_FAILURE_REASON_BYTES};\n','')
rep(n,'payload_limit(Kind) when Kind =:= goal;', 'payload_limit(Kind) when Kind =:= failure_reasons; Kind =:= erlog_error;\n                         Kind =:= goal;')
n='src/quod_ontology.erl'
rep(n,'-define(MAX_ERROR_TERM_BYTES, 4096).\n','')
rep(n,'try erlang:external_size(Term) =< ?MAX_ERROR_TERM_BYTES\n            andalso portable_term(Term)','try portable_term(Term)')
emit()
