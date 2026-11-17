from pathlib import Path
R=Path('/home/yan/src/quod_worktrees/pearl-stone');E=Path(__file__).resolve().parent
p=R/'test/quod_ledger_store_tests.erl';s=p.read_text().replace('filename:join([Dir, base64url(Ns), "log.0001"])','filename:join(quod_ledger_store:ns_dir(Dir, Ns), "log.0001")').replace('LogDir = filename:join(Dir, base64url(Ns)),','LogDir = quod_ledger_store:ns_dir(Dir, Ns),').replace("%% an Ns containing ':' to exercise base64url","%% exact namespace contains punctuation")
a=s.index('%% mirror of quod_ledger_store:base64url/1');b=s.index('%% The ledger',a);s=s[:a]+s[b:];assert 'base64url' not in s;p.write_text(s)
p=R/'test/quod_foreign_log_tests.erl';s=p.read_text().replace('args => ["-pa" | code:get_path()]','args => ["-setcookie", atom_to_list(erlang:get_cookie()), "-pa" | code:get_path()]')
a=s.index('foreign_stream_case(Carriers, Mode) ->');b=s.index('\nfixture_evidence_sender(',a);chunk=s[a:b];needle='    Snapshot = quod_ledger_store:snapshot(Store),\n    Test = self(),';assert needle in chunk
chunk=chunk.replace(needle,'''    Snapshot = quod_ledger_store:snapshot(Store),
    %% A measured fixture allowance exercises the retained continuation through
    %% the existing complete-frame owner without constructing a multi-GB file.
    PageCapacity = case Mode of
        complete ->
            {ok, FullParts, done} = quod_catchup:transfer_page(Store,
                quod_catchup:transfer_open(Store, 1, quod_ledger_store:last(Store)), unlimited),
            Half = lists:sublist(FullParts, length(FullParts) div 2),
            {ok, Frame} = quod_catchup:encode_frame(Ns,
                {history_page3, <<0:128>>, <<0:128>>, Half,
                 quod_ledger_store:last(Store), {<<0:128>>, 1}, <<0:128>>}),
            byte_size(Frame);
        _ -> unlimited
    end,
    Test = self(),''')
old='            {ok, Parts, Next} = quod_catchup:transfer_page(Read, Sender, unlimited),';assert old in chunk
chunk=chunk.replace(old,'''            Framing = case PageCapacity of
                unlimited -> unlimited;
                _ ->
                    put({quod_catchup, page_capacity}, PageCapacity),
                    Sequence = case Query of {continue, _, Q} -> Q + 1; _ -> 1 end,
                    {Ns, {<<0:128>>, Sequence}}
            end,
            {ok, Parts, Next} = quod_catchup:transfer_page(Read, Sender, Framing),''',1)
chunk=chunk.replace('after quod_ledger_store:close(Read) end','after erase({quod_catchup, page_capacity}), quod_ledger_store:close(Read) end',1)
s=s[:a]+chunk+s[b:];p.write_text(s)
p=E/'build-applied.py';s=p.read_text().replace("opts='[export_all,","opts='[debug_info,export_all,")
s=s.replace("for f in (D/'test').glob('*.erl')]","for f in (D/'test').glob('*.erl') if f.name!='records_test.erl']")
s=s.replace("modules_compiled_only=True)","modules_compiled_only=True,unavailable_legacy_optional_test='records_test requires absent eqc/include/eqc.hrl; failure retained in applied-build01')");p.write_text(s)
p=E/'build-update.py';p.write_text(p.read_text().replace("opts='[export_all,","opts='[debug_info,export_all,"))
p=E/'test-applied.py';s=p.read_text().replace("P.mkdir(exist_ok=False)\n","P.mkdir(exist_ok=False);(P/'source').symlink_to('/build/source')\n");p.write_text(s)
print('CORRECTED_HISTORY_FIXTURES_AND_HARNESS')
