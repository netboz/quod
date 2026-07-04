-module(quod_ns_SUITE).
-moduledoc """
Full-stack (`quod_simplex` + `quod_prolog` + `quod_prove`) N=1 integration for **committee admission** via
the `admit`/`remove` external predicates. A founder proves `admit(Pubkey, Host, Port)`; the staged
`peer_admitted` assert commits through the normal write path, and the founder's validator set GROWS to
include the joiner (committee = a projection of the `peer_admitted` facts). `remove` of the sole member is
refused (the crash-safe floor). The happy-path shrink needs a live 2-node committee (quorum 2, so a lone
founder can't commit it), so `remove`'s retract SHAPE is pinned at the predicate level in
`quod_committee_predicates_tests`; here we cover the end-to-end grow + the floor.
""".
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([t_admit_grows_committee/1, t_cannot_remove_last/1]).

all() -> [t_admit_grows_committee, t_cannot_remove_last].

init_per_testcase(_TC, Cfg) ->
    {ok, _} = application:ensure_all_started(gproc),
    U   = integer_to_list(erlang:unique_integer([positive])),
    Dir = filename:join("/tmp", "quod_ns_" ++ U),
    Ns  = list_to_binary("ns:" ++ U),
    {Pub, Seed} = quod_identity:generate(),
    NsCfg = #{mode => create, node_id => Pub, committee => [],
              identity => #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})},
              genesis_file => filename:join(code:priv_dir(quod), "ontologies/quod_root.pl"),
              data_dir => Dir},
    {ok, Pid} = quod_ns:start_link(Ns, NsCfg),
    unlink(Pid),
    [{ns, Ns}, {dir, Dir}, {node_id, Pub}, {ns_pid, Pid} | Cfg].

end_per_testcase(_TC, Cfg) ->
    Pid = ?config(ns_pid, Cfg),
    Ref = monitor(process, Pid),
    exit(Pid, shutdown),
    receive {'DOWN', Ref, process, Pid, _} -> ok after 5000 -> ok end,
    _ = file:del_dir_r(?config(dir, Cfg)),
    ok.

%% The founder admits a new member: prove admit → commit → the validator set grows to {founder, joiner},
%% and peer_admitted for the joiner is provable in the founder's kb.
t_admit_grows_committee(Cfg) ->
    Ns   = ?config(ns, Cfg),
    Self = ?config(node_id, Cfg),
    {Joiner, _} = quod_identity:generate(),
    ?assertEqual([Self], quod_simplex:committee(Ns)),
    ?assertMatch({ok, _, _}, rp(Ns, {admit, Joiner, "10.0.0.9", 9000})),
    ?assertEqual(lists:usort([Self, Joiner]), quod_simplex:committee(Ns)),
    ?assertMatch({ok, [#{}], _}, rp(Ns, {peer_admitted, {'_'}, {'_'}, {'_'}, Joiner})).

%% remove of the sole member is refused (the crash-safe floor): the predicate fails, nothing commits, the
%% committee is unchanged, and the process is still serving.
t_cannot_remove_last(Cfg) ->
    Ns   = ?config(ns, Cfg),
    Self = ?config(node_id, Cfg),
    ?assertEqual([Self], quod_simplex:committee(Ns)),
    ?assertEqual(fail, rp(Ns, {remove, Self})),
    ?assertEqual([Self], quod_simplex:committee(Ns)),
    ?assertMatch({ok, [#{}], _}, rp(Ns, {acl_sovereign, 'quod:root'})).   %% still serving proves

%% Proves are refused ({error,rebuilding}) until the post-boot replay marks the kb ready — retry.
rp(Ns, Goal) -> rp(Ns, Goal, 300).
rp(_Ns, _Goal, 0) -> {error, timeout};
rp(Ns, Goal, N) ->
    case quod_prolog:prove(Ns, Goal, Ns) of
        {error, rebuilding} -> timer:sleep(10), rp(Ns, Goal, N - 1);
        R -> R
    end.
