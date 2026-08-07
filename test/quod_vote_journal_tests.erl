-module(quod_vote_journal_tests).
-include_lib("eunit/include/eunit.hrl").

-define(MAGIC, 16#51564A33).   %% "QVJ3" — current

%% A journal records this node's own votes, which bind the consensus share
%% domain; every superseded journal format must be rejected outright rather than
%% restored as equivocation history for a chain that no longer exists.
legacy_formats() ->
    [{1, 16#51564A31, <<"QVJ1">>},
     {2, 16#51564A32, <<"QVJ2">>}].

persists_and_reloads_votes_test() ->
    with_journal(
      fun(Ns, Dir, J0) ->
              H1 = hash(1),
              H2 = hash(2),
              {ok, J1} = quod_vote_journal:record(J0, support, 6, H1),
              {ok, J2} = quod_vote_journal:record(J1, commit, 6, H1),
              {ok, J3} = quod_vote_journal:record(J2, complaint, 7, none),
              ok = quod_vote_journal:close(J3),
              {ok, J4} = quod_vote_journal:open(Ns, domain(), Dir, 5),
              ?assertEqual(#{6 => #{support => H1, final => {commit, H1}},
                             7 => #{support => none, final => complaint}},
                           quod_vote_journal:rounds(J4)),
              {ok, J5} = quod_vote_journal:record(J4, support, 8, H2),
              quod_vote_journal:close(J5)
      end).

conflicting_votes_fail_stop_test() ->
    with_journal(
      fun(_Ns, _Dir, J0) ->
              H1 = hash(1),
              H2 = hash(2),
              {ok, J1} = quod_vote_journal:record(J0, support, 6, H1),
              ?assertError({vote_conflict, 6, {support, H1}, {support, H2}},
                           quod_vote_journal:record(J1, support, 6, H2)),
              {ok, J2} = quod_vote_journal:record(J1, complaint, 6, none),
              ?assertError({vote_conflict, 6, complaint, {commit, H1}},
                           quod_vote_journal:record(J2, commit, 6, H1)),
              quod_vote_journal:close(J2)
      end).

%% Support and final votes are separate protocol decisions. A validator that supported a losing proposal
%% may still commit the uniquely notarized block; only double-support and commit-versus-complaint conflict.
support_and_commit_hashes_are_independent_test() ->
    with_journal(
      fun(_Ns, _Dir, J0) ->
              H1 = hash(1),
              H2 = hash(2),
              {ok, J1} = quod_vote_journal:record(J0, support, 6, H1),
              {ok, J2} = quod_vote_journal:record(J1, commit, 6, H2),
              {ok, J3} = quod_vote_journal:record(J2, commit, 7, H1),
              {ok, J4} = quod_vote_journal:record(J3, support, 7, H2),
              ?assertEqual(#{6 => #{support => H1, final => {commit, H2}},
                             7 => #{support => H2, final => {commit, H1}}},
                           quod_vote_journal:rounds(J4)),
              quod_vote_journal:close(J4)
      end).

conflicting_votes_remain_blocked_after_reload_test() ->
    with_journal(
      fun(Ns, Dir, J0) ->
              H1 = hash(1),
              H2 = hash(2),
              {ok, J1} = quod_vote_journal:record(J0, support, 6, H1),
              {ok, J2} = quod_vote_journal:record(J1, commit, 7, H1),
              ok = quod_vote_journal:close(J2),
              {ok, J3} = quod_vote_journal:open(Ns, domain(), Dir, 5),
              ?assertError({vote_conflict, 6, {support, H1}, {support, H2}},
                           quod_vote_journal:record(J3, support, 6, H2)),
              ?assertError({vote_conflict, 7, {commit, H1}, complaint},
                           quod_vote_journal:record(J3, complaint, 7, none)),
              quod_vote_journal:close(J3)
      end).

committed_rounds_are_filtered_and_compacted_test() ->
    with_journal(
      fun(Ns, Dir, J0) ->
              H1 = hash(1),
              H2 = hash(2),
              {ok, J1} = quod_vote_journal:record(J0, support, 6, H1),
              {ok, J2} = quod_vote_journal:record(J1, commit, 6, H1),
              {ok, J3} = quod_vote_journal:record(J2, support, 7, H2),
              {ok, J4} = quod_vote_journal:prune(J3, 6),
              J5 = quod_vote_journal:compact(J4),
              ok = quod_vote_journal:close(J5),
              {ok, J6} = quod_vote_journal:open(Ns, domain(), Dir, 6),
              ?assertEqual(#{7 => #{support => H2, final => none}},
                           quod_vote_journal:rounds(J6)),
              quod_vote_journal:close(J6)
      end).

torn_tail_is_trimmed_without_losing_synced_votes_test() ->
    with_journal(
      fun(Ns, Dir, J0) ->
              H = hash(1),
              {ok, J1} = quod_vote_journal:record(J0, support, 6, H),
              ok = quod_vote_journal:close(J1),
              Path = filename:join(quod_ledger_store:ns_dir(Dir, Ns), "votes.0001"),
              {ok, Fd} = file:open(Path, [read, write, raw, binary]),
              {ok, _} = file:position(Fd, eof),
              ok = file:write(Fd, <<?MAGIC:32, 200:32, 0:32, "torn">>),
              ok = file:close(Fd),
              {ok, J2} = quod_vote_journal:open(Ns, domain(), Dir, 5),
              ?assertEqual(#{6 => #{support => H, final => none}},
                           quod_vote_journal:rounds(J2)),
              {ok, J3} = quod_vote_journal:record(J2, complaint, 7, none),
              ok = quod_vote_journal:close(J3),
              {ok, J4} = quod_vote_journal:open(Ns, domain(), Dir, 5),
              ?assertEqual(#{6 => #{support => H, final => none},
                             7 => #{support => none, final => complaint}},
                           quod_vote_journal:rounds(J4)),
              quod_vote_journal:close(J4)
      end).

interior_corruption_fail_stops_test() ->
    with_journal(
      fun(Ns, Dir, J0) ->
              H1 = hash(1),
              H2 = hash(2),
              {ok, J1} = quod_vote_journal:record(J0, support, 6, H1),
              {ok, J2} = quod_vote_journal:record(J1, support, 7, H2),
              ok = quod_vote_journal:close(J2),
              Path = filename:join(quod_ledger_store:ns_dir(Dir, Ns), "votes.0001"),
              {ok, Fd} = file:open(Path, [read, write, raw, binary]),
              ok = file:pwrite(Fd, 12, <<0>>),
              ok = file:close(Fd),
              ?assertError({vote_journal_corruption, bad_crc, 0},
                           quod_vote_journal:open(Ns, domain(), Dir, 5)),
              closed
      end).

final_complete_record_corruption_fail_stops_test() ->
    with_journal(
      fun(Ns, Dir, J0) ->
              H = hash(1),
              {ok, J1} = quod_vote_journal:record(J0, support, 6, H),
              ok = quod_vote_journal:close(J1),
              Path = filename:join(quod_ledger_store:ns_dir(Dir, Ns), "votes.0001"),
              {ok, Fd} = file:open(Path, [read, write, raw, binary]),
              ok = file:pwrite(Fd, 12, <<0>>),
              ok = file:close(Fd),
              ?assertError({vote_journal_corruption, bad_crc, 0},
                           quod_vote_journal:open(Ns, domain(), Dir, 5)),
              closed
      end).

wrong_domain_reopen_fails_without_mutation_test() ->
    with_journal(
      fun(Ns, Dir, J0) ->
              H = hash(1),
              {ok, J1} = quod_vote_journal:record(J0, support, 6, H),
              ok = quod_vote_journal:close(J1),
              Path = journal_path(Ns, Dir),
              {ok, Before} = file:read_file(Path),
              Domain = domain(),
              OtherDomain = <<16#B6:256>>,
              ?assertError(
                 {vote_journal_domain_mismatch, Domain, OtherDomain},
                 quod_vote_journal:open(Ns, OtherDomain, Dir, 5)),
              ?assertEqual({ok, Before}, file:read_file(Path))
      end).

legacy_format_fails_without_mutation_test() ->
    with_journal(
      fun(Ns, Dir, J0) ->
              ok = quod_vote_journal:close(J0),
              Path = journal_path(Ns, Dir),
              lists:foreach(
                fun({Version, Magic, _Tag}) ->
                    Legacy = legacy_frame(
                               Magic, {quod_vote, 1, support, 6, hash(1)}),
                    ok = file:write_file(Path, Legacy),
                    ?assertError(
                       {unsupported_vote_journal_format, Version},
                       quod_vote_journal:open(Ns, domain(), Dir, 5)),
                    ?assertEqual({ok, Legacy}, file:read_file(Path))
                end, legacy_formats())
      end).

short_legacy_header_fails_without_mutation_test() ->
    with_journal(
      fun(Ns, Dir, J0) ->
              ok = quod_vote_journal:close(J0),
              Path = journal_path(Ns, Dir),
              lists:foreach(
                fun({Version, _Magic, Tag}) ->
                    ok = file:write_file(Path, Tag),
                    ?assertError(
                       {unsupported_vote_journal_format, Version},
                       quod_vote_journal:open(Ns, domain(), Dir, 5)),
                    ?assertEqual({ok, Tag}, file:read_file(Path))
                end, legacy_formats())
      end).

short_legacy_tail_fails_without_mutation_test() ->
    with_journal(
      fun(Ns, Dir, J0) ->
              {ok, J1} =
                  quod_vote_journal:record(
                    J0, support, 6, hash(1)),
              ok = quod_vote_journal:close(J1),
              Path = journal_path(Ns, Dir),
              [{Version, _Magic, Tag} | _] = legacy_formats(),
              ok = file:write_file(Path, Tag, [append]),
              {ok, Before} = file:read_file(Path),
              ?assertError(
                 {unsupported_vote_journal_format, Version},
                 quod_vote_journal:open(Ns, domain(), Dir, 5)),
              ?assertEqual({ok, Before}, file:read_file(Path))
      end).

with_journal(Fun) ->
    Ns = <<"journal:test">>,
    Dir = filename:join("/tmp", "quod_vote_journal_" ++
                                integer_to_list(erlang:unique_integer([positive]))),
    {ok, J0} = quod_vote_journal:open(Ns, domain(), Dir, 5),
    try Fun(Ns, Dir, J0)
    after
        _ = file:del_dir_r(Dir)
    end.

domain() -> <<16#A5:256>>.

journal_path(Ns, Dir) ->
    filename:join(quod_ledger_store:ns_dir(Dir, Ns), "votes.0001").

legacy_frame(Magic, Term) ->
    Payload = term_to_binary(Term, [deterministic]),
    <<Magic:32, (byte_size(Payload)):32,
      (erlang:crc32(Payload)):32, Payload/binary>>.

hash(N) -> crypto:hash(sha256, <<N:64>>).
