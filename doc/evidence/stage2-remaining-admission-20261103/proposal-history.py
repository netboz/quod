from propose import *
# Retire the now-dead capacity API metadata as well as its implementation.
n='src/quod_atomic_admission.erl'
rep(n,'-doc "Bound new volatile groups, not duplicate callers or journal-restored responsibilities.".\n-spec has_capacity(binary(), state()) -> boolean().\n','')
# Return codec errors at the existing framing boundary instead of crashing on actual width overflow.
n='src/quod_catchup.erl'
rep(n,'-define(MAX_BLOCKS,      ?QUOD_MAX_FOREIGN_PAGE_ENTRIES).\n-define(RESP_BUDGET,     ?QUOD_MAX_FOREIGN_PAGE_BYTES).\n','')
cut(n,'-spec encode_frame(binary(), term())','-doc "Decode one existing catch-up frame', '''-spec encode_frame(binary(), term()) -> {ok, binary()} | {error, term()}.
encode_frame(Ns, Term) when is_binary(Ns) ->
    case decode_wire_term(Term, 0) of
        {ok, Term, _} ->
            case quod_safe_term:encode_canonical(Term, ?QUOD_LINK_PAYLOAD_CAPACITY) of
                {ok, Inner} -> quod_safe_term:encode_canonical(
                                 {catchup, 3, Ns, Inner}, ?QUOD_LINK_PAYLOAD_CAPACITY);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

''')
rep(n,'To1 = lists:min([To, LastI, From + ?MAX_BLOCKS - 1]),','To1 = min(To, LastI),')
rep(n,'{ok, cap_bytes(Es, 0), LastI}','{ok, Es, LastI}')
rep(n,'%% bounded work unit is not a history transport or a certificate verifier.','%% local read is not a history transport or a certificate verifier.')
cut(n,'%% Keep one bounded materializer work unit','-doc """\nCapture a material range')
rep(n,'current = none, pending = none, selections = range','current = none, selections = range')
cut(n,'-doc "Produce a bounded page','next_transfer_part(_Store', '''-doc "Produce the complete selected snapshot through the existing proof cursor.".
-spec transfer_page(quod_ledger_store:handle(), transfer_sender() | done) ->
          {ok, [term()], done} | {error, term()}.
transfer_page(_Store, done) -> {ok, [], done};
transfer_page(Store, State) -> transfer_page(Store, State, []).

transfer_page(Store, State, Acc) ->
    case next_transfer_part(Store, State) of
        done -> {ok, lists:reverse(Acc), done};
        {ok, Part, State1} -> transfer_page(Store, State1, [Part | Acc])
    end.

''')
rep(n,'valid_transfer_parts(Parts, 0, 0)','valid_transfer_parts(Parts)')
cut(n,'valid_transfer_parts([],','valid_transfer_part({Kind', '''valid_transfer_parts([]) -> true;
valid_transfer_parts([Part | Rest]) ->
    valid_transfer_part(Part) andalso valid_transfer_parts(Rest);
valid_transfer_parts(_) -> false.

''')
rep(n,'To = From + ?MAX_BLOCKS - 1,','%% The existing range owner captures its actual last committed entry.\n    To = ?QUOD_SCOPE_WIRE_MAX_UINT64,')
# Complete-envelope refusal stays correlated through the existing page control contract.
n='src/quod_link.erl'
rep(n,'Payload = quod_catchup:encode_frame(Ns, {history_credit3, Grant}),','{ok, Payload} = quod_catchup:encode_frame(Ns, {history_credit3, Grant}),')
rep(n,'''    Payload = quod_catchup:encode_frame(Ns, {history_request3, Grant, ReqId, Query}),
    S1 = S#s{catchup = C#credit{grant = none, pending = {Grant, ReqId}}},
    enqueue_send({ordered, frame(Payload), request_accepted}, S1);''','''    case quod_catchup:encode_frame(Ns, {history_request3, Grant, ReqId, Query}) of
        {ok, Payload} ->
            S1 = S#s{catchup = C#credit{grant = none, pending = {Grant, ReqId}}},
            enqueue_send({ordered, frame(Payload), request_accepted}, S1);
        {error, Reason} -> protocol_failed(Reason, S)
    end;''')
rep(n,'    Payload = quod_catchup:encode_frame(Ns, Control),','''    Encoded = case quod_catchup:encode_frame(Ns, Control) of
        {ok, _} = Ok -> Ok;
        {error, _} -> quod_catchup:encode_frame(
                       Ns, {history_error3, Grant, ReqId, server_error, Next})
    end,
    {ok, Payload} = Encoded,''')
# Tests consume the single changed codec contract, without production compatibility wrappers.
for n in ['test/quod_link_tests.erl','test/quod_catchup_tests.erl','test/quod_foreign_log_tests.erl']:
 s=get(n)
 s=re.sub(r'(\b(?:Wire|Frame) = )quod_catchup:encode_frame', lambda m:'{ok, '+m.group(1).split(' =')[0]+'} = quod_catchup:encode_frame',s)
 if 'quod_catchup:encode_frame' in s and n.endswith('quod_link_tests.erl'):
  s=s.replace('frame(quod_catchup:encode_frame','frame(catchup_frame')
  s+='\ncatchup_frame(Ns, Term) ->\n    {ok, Bytes} = quod_catchup:encode_frame(Ns, Term),\n    Bytes.\n'
 put(n,s)
n='src/quod_foreign_projection.erl'
rep(n,'S#s.resnapshot orelse Applied =:= 0 orelse\n                         Height - Applied > ?QUOD_MAX_FOREIGN_PAGE_ENTRIES','S#s.resnapshot orelse Applied =:= 0')
rep(n,'To = min(Target, From + ?QUOD_MAX_FOREIGN_PAGE_ENTRIES - 1),','To = Target,')
n='src/quod_foreign_log.erl'
rep(n,'-define(MANIFEST_RESERVE_BYTES, 4096).\n','')
rep(n,'{ok, Bytes} when byte_size(Bytes) =< ?QUOD_MAX_FOREIGN_PAGE_BYTES -> Entry;','{ok, _Bytes} -> Entry;')
rep(n,'min(Tip, Cursor#verified_cursor.height + ?QUOD_MAX_FOREIGN_PAGE_ENTRIES)','Tip')
rep(n,'min(Tip, Height + ?QUOD_MAX_FOREIGN_PAGE_ENTRIES)','Tip')
rep(n,'min(Target, Height + ?QUOD_MAX_FOREIGN_PAGE_ENTRIES)','Target')
# Byte reservations are accounting; reserve the actual group, then exact metadata before its write.
rep(n,'    Reservation = StoredBytes + ?QUOD_MAX_FOREIGN_PAGE_BYTES,\n','')
rep(n,'{reserve_page, RequestRef, Reservation}','{reserve_page, RequestRef, StoredBytes}')
rep(n,'write_checkpoint(Root, {Ns, Anchor}, CacheNs, Height, Projection)','write_checkpoint(Owner, RequestRef, Root, {Ns, Anchor}, CacheNs, Height, Projection)')
rep(n,'write_checkpoint(Root, Identity, cache_namespace(Identity),','write_checkpoint(Owner, RequestRef, Root, Identity, cache_namespace(Identity),')
rep(n,'{error, enoent} ->\n            case gen_server:call(\n                   Owner,\n                   {reserve_page, RequestRef, ?MANIFEST_RESERVE_BYTES}) of','{error, enoent} ->\n            Blob = term_to_binary(Expected, [deterministic]),\n            case gen_server:call(\n                   Owner,\n                   {reserve_page, RequestRef, byte_size(Blob)}) of')
rep(n,'atomic_write(\n                      Path, term_to_binary(Expected, [deterministic]))','atomic_write(Path, Blob)')
rep(n,'''    case byte_size(Blob) =< ?QUOD_MAX_FOREIGN_PAGE_BYTES of
        true -> atomic_write(checkpoint_path(Root, CacheNs), Blob);
        false -> {error, checkpoint_too_large}
    end.''','''    case gen_server:call(Owner, {reserve_page, RequestRef, byte_size(Blob)}) of
        ok -> atomic_write(checkpoint_path(Root, CacheNs), Blob);
        {error, _} -> {error, cache_unavailable}
    end.''')
cut(n,'read_small_term(Path) ->','atomic_write(Path, Blob) ->', '''read_cache_term(Path) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            %% Canonical wrapped decoding does not create historical atoms.
            case quod_safe_term:decode_wrapped(Bin, unlimited) of
                {ok, Term} -> {ok, Term};
                {error, _} -> {error, bad_term}
            end;
        {error, Reason} -> {error, Reason}
    end.

''')
rep(n,'read_small_term(','read_cache_term(')
# Retire a false page metric; actual entries and bytes remain unchanged.
rep(n,'          follow_pages = 0 :: non_neg_integer(),\n','')
rep(n,'follow_wakes => 0, follow_pages => 0,','follow_wakes => 0,')
rep(n,'              follow_pages => S#s.follow_pages,\n','')
cut(n,'                    Pages = case Entries of','                         follow_bytes =', '                    S0#s{follow_entries = S0#s.follow_entries + Entries,\n')
n='src/quod_metrics.erl'
rep(n,'    _ = N(quod_foreign_follow_pages, "Total certified history pages added by continuous follows (only ever goes up)."),\n','')
rep(n,'    _ = Set(quod_foreign_follow_pages, follow_pages),\n','')
rep('test/quod_runtime_tests.erl','        ?assert(maps:get(follow_pages, FollowStats) > 0),\n','')
# The adjacent entries assertion in this same real-owner test retains its progress obligation.
n='src/quod_feed.erl'
cut(n,'            %% A block whose framed size exceeds','            drop(oversized, S);','            %% The complete encoded push must fit the link length field.\n')
n='include/quod_transport_limits.hrl'
rep(n,'%% Retained history-page admission policy; not the actual transport capacity.\n-define(QUOD_MAX_FOREIGN_PAGE_BYTES, (900 * 1024)).\n','')
n='include/quod_proof_limits.hrl'
rep(n,'-define(QUOD_MAX_DIRECT_EFFECT_BYTES, 2048).\n','')
rep(n,'-define(QUOD_MAX_FOREIGN_PAGE_ENTRIES, 256).\n','')
cut(n,'%% Process-free DTX recovery endpoint.','-define(QUOD_DTX_ENDPOINT_WORKER_TIMEOUT_MS', '%% The process-free DTX endpoint uses the complete transport envelope capacity.\n')
# Preserve actual frame widths; retire the store reader's arbitrary64MiB ceiling.
# The fill owner reads only existing file bytes and returns short at EOF; CRC/group handling stays.
n='src/quod_ledger_store.erl'
rep(n,'-define(MAX_FRAME_BYTES, (64 * 1024 * 1024)).  %% sanity cap on a frame\'s length field — a corrupted\n                                               %% Len must never drive a giant pread allocation\n','')
rep(n,'Len > 1, Len =< ?MAX_FRAME_BYTES,','Len > 1,')
rep(n,'                <<?MAGIC:32, Len:32, _:32, _/binary>> when Len > ?MAX_FRAME_BYTES ->\n                    {stop, {frame_too_big, Len}, Off};\n','')
# Complete writer representability is checked before binary segment construction (no truncation).
rep(n,'frame(Payload) ->\n    <<?MAGIC:32, (byte_size(Payload)):32, (erlang:crc32(Payload)):32, Payload/binary>>.', '''frame(Payload) when byte_size(Payload) =< (1 bsl 32) - 1 ->
    <<?MAGIC:32, (byte_size(Payload)):32, (erlang:crc32(Payload)):32, Payload/binary>>;
frame(_Payload) -> error(frame_too_large).''')
emit()
