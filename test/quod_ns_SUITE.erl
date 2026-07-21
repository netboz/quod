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
-include("quod_ledger.hrl").
-import(quod_ct, [rp/2]).

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([t_admit_grows_committee/1, t_cannot_remove_last/1, t_gate_rejects_raw_wedge/1]).

all() -> [t_admit_grows_committee, t_cannot_remove_last, t_gate_rejects_raw_wedge].

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
    %% pick a Joiner pubkey that sorts AFTER the founder, so the founder (sort position 0) is the round-robin
    %% leader for the next (odd) slot — the founder therefore PROPOSES, deterministically (see the engine
    %% check below), rather than redirecting on ~half of runs.
    {Joiner, _} = quod_ct:generate_key_gt(Self),
    ?assertEqual([Self], quod_simplex:committee(Ns)),
    %% the readiness gate refuses a never-seen candidate...
    ?assertEqual(fail, rp(Ns, {admit, Joiner, "10.0.0.9", 9000})),
    %% ...so stamp a fresh digest for it in the feed's liveness table, as if it had been feed-following
    %% (the real end-to-end digest flow is join_SUITE's) — covering BOTH proofs: the submitter's admit
    %% and the validator's verdict re-proof.
    true = quod_feed:record_digest(quod_feed:digest_table(Ns), Joiner, 0),
    ?assertMatch({ok, _, _}, rp(Ns, {admit, Joiner, "10.0.0.9", 9000})),
    ?assertEqual([Self, Joiner], quod_simplex:committee(Ns)),   %% sorted, Self < Joiner by construction
    ?assertMatch({ok, [#{}], _}, rp(Ns, {peer_admitted, {'_'}, {'_'}, {'_'}, Joiner})),
    %% the ENGINE adopted the grown committee (quorum is now 2), not just the facts. The founder leads the
    %% next slot, so it PROPOSES + self-supports: 1 of 2 required, so it cannot notarize with only itself
    %% present and the committed height FREEZES. If the engine had kept quorum 1 (a mis-fed active set), the
    %% founder's single self-support would notarize+commit and the height would ADVANCE — so this deterministic
    %% freeze is the observable proof that active_validators/1 fed the engine the grown set (the adopt path the
    %% suite otherwise never checks). The write is spawned (it parks unfulfilled) so it doesn't block the test.
    H = height(Ns),
    _ = spawn(fun() -> catch quod_prolog:prove(Ns, {assertz, {wont, commit, now}}, Ns) end),
    timer:sleep(2000),
    ?assertEqual(H, height(Ns)).

height(Ns) -> maps:get(slot, quod_simplex:status(Ns), -1).

%% remove of the sole member is refused (the crash-safe floor): the predicate fails, nothing commits, the
%% committee is unchanged, and the process is still serving.
t_cannot_remove_last(Cfg) ->
    Ns   = ?config(ns, Cfg),
    Self = ?config(node_id, Cfg),
    ?assertEqual([Self], quod_simplex:committee(Ns)),
    ?assertEqual(fail, rp(Ns, {remove, Self})),
    ?assertEqual([Self], quod_simplex:committee(Ns)),
    ?assertMatch({ok, [#{}], _}, rp(Ns, {acl_sovereign, {':', quod, root}})).   %% still serving proves

%% The consensus gate (Slice A, deferred.md §3 a+c): a RAW membership transaction that bypasses the
%% admit/remove predicates — the Byzantine-submitter path — is rejected at the leader's own append
%% seam: a retract that would EMPTY the committee (the permanent-wedge attack), a mixed
%% content+membership diff, and a non-list diff all get {error, bad_change}; the committee is
%% unchanged and the namespace still commits afterward (the wedge is impossible).
t_gate_rejects_raw_wedge(Cfg) ->
    Ns   = ?config(ns, Cfg),
    Self = ?config(node_id, Cfg),
    ?assertMatch({ok, [#{}], _}, rp(Ns, {acl_sovereign, {':', quod, root}})),   %% kb ready, genesis applied
    ?assertEqual([Self], quod_simplex:committee(Ns)),
    RawTx = fun(Diff) -> #transaction{tx_id = <<"evil">>, caller_ns = Ns, diff = Diff,
                                      read_check = #{}, author = Self, sig = none} end,
    WedgeOp = {retract, {{peer_admitted, Self, {'_'}, {'_'}, Self}, true}},
    ?assertEqual({error, bad_change}, quod_simplex:append(Ns, RawTx([WedgeOp]))),          %% N=1 → 0
    ?assertEqual({error, bad_change},
                 quod_simplex:append(Ns, RawTx([WedgeOp, {assert, {{smuggled, x}, true}}]))),  %% mixed
    ?assertEqual({error, bad_change}, quod_simplex:append(Ns, RawTx(not_a_list))),         %% poison: non-list
    ?assertEqual({error, bad_change},
                 quod_simplex:append(Ns, RawTx([{assert, {{x, 1}, true}} | junk]))),       %% poison: improper list
    ?assert(is_process_alive(quod_reg:where({quod_simplex, Ns}))),   %% the gate REJECTED, never crashed
    ?assertEqual([Self], quod_simplex:committee(Ns)),                     %% committee untouched
    ?assertMatch({ok, [#{}], _}, rp(Ns, {assertz, {after_gate, ok}})),    %% namespace still commits
    ?assertMatch({ok, [#{}], _}, rp(Ns, {after_gate, {'_'}})).
