-module(raft_safety_SUITE).
-moduledoc """
M2 integration: a real **N=3 Raft committee over loopback QUIC**. Each committee
member runs in its own OS Erlang node (via `peer`, stdio-controlled, no Erlang
distribution) with its own `quod_quic` listener on a distinct port, so the `{log,
Ns}` traffic between them is genuine loopback QUIC — exactly the deployment shape,
not a single-VM simulation.

Covers the M2 demonstrables (`doc/ordering-layer-spec.md` §6.3): three nodes elect
one leader; an `append` on the leader commits once a majority holds it and reaches
every member's KB; an `append` on a follower is redirected; killing the leader
yields a new leader that still serves writes; surviving KBs stay identical.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([elects_single_leader/1, replicates_and_converges/1,
         follower_redirects_append/1, leader_failover/1]).

-define(NS, <<"raft:m2">>).
-define(PORTS, [15810, 15811, 15812]).

%% Election timing: long enough that the first-dial QUIC links are up before the
%% first election fires (so a leader emerges in ~one round), short enough for a brisk
%% test. heartbeat << election.
-define(NS_TUNING, #{mode => create, election_ms => 2500, election_jit => 0.4,
                     heartbeat_ms => 150}).

all() ->
    [elects_single_leader, replicates_and_converges,
     follower_redirects_append, leader_failover].

%%%===================================================================
%%% suite setup: one 3-node committee, shared across the (ordered) tests
%%%===================================================================

init_per_suite(Config) ->
    {Cert, Key} = make_cert(Config),
    Committee   = [{"127.0.0.1", P} || P <- ?PORTS],
    Nodes = [ start_member(P, Cert, Key, Committee, Config) || P <- ?PORTS ],
    %% all listeners + namespaces are up; wait for the committee to settle on a leader.
    {_LeaderPeer, _LeaderId, _Term} = wait_for_leader(Nodes, 25000),
    [{nodes, Nodes}, {committee, Committee} | Config].

end_per_suite(Config) ->
    _ = [catch peer:stop(Peer) || {Peer, _Id} <- ?config(nodes, Config)],
    ok.

%% Start one committee member in its own node: own QUIC listener on Port, own
%% data_dir, the shared committee. Returns {Peer, NodeId}.
start_member(Port, Cert, Key, Committee, Config) ->
    Self = {"127.0.0.1", Port},
    Name = list_to_atom("raft_m2_" ++ integer_to_list(Port)),
    %% peer:start (NOT start_link): the peers must outlive the transient init_per_suite
    %% process and persist across test cases; end_per_suite stops them explicitly.
    {ok, Peer, _Node} = peer:start(
                          #{name => Name, connection => standard_io,
                            args => ["-pa" | code:get_path()]}),
    _ = peer:call(Peer, logger, set_primary_config, [level, warning]),  %% hush the stdio channel
    %% load quod BEFORE set_env — application:load resets env from the .app file, so
    %% setting certfile/port first would be clobbered (the relative default ⇒ enoent).
    _ = peer:call(Peer, application, load, [quod]),
    ok = peer:call(Peer, application, set_env, [quod, listen_port, Port]),
    ok = peer:call(Peer, application, set_env, [quod, node_id, Self]),
    ok = peer:call(Peer, application, set_env, [quod, certfile, Cert]),
    ok = peer:call(Peer, application, set_env, [quod, keyfile, Key]),
    {ok, _} = peer:call(Peer, application, ensure_all_started, [quod]),
    DataDir = filename:join(?config(priv_dir, Config), "data_" ++ integer_to_list(Port)),
    Cfg = (?NS_TUNING)#{node_id => Self, committee => Committee, data_dir => DataDir},
    {ok, _} = peer:call(Peer, quod_ns_sup, start_namespace, [?NS, Cfg]),
    {Peer, Self}.

%%%===================================================================
%%% tests
%%%===================================================================

%% Exactly one leader, the other two followers, all at the same term.
elects_single_leader(Config) ->
    Nodes = ?config(nodes, Config),
    {_LeaderPeer, LeaderId, Term} = wait_for_leader(Nodes, 15000),
    Roles = [role(Peer) || {Peer, _} <- Nodes],
    ?assertEqual(1, length([leader || leader <- Roles])),
    ?assertEqual(2, length([follower || follower <- Roles])),
    %% every member agrees on the term and the leader's identity
    [ begin
          S = status(Peer),
          ?assertEqual(Term, maps:get(term, S)),
          ?assertEqual(LeaderId, maps:get(leader, S))
      end || {Peer, _} <- Nodes ].

%% A write on the leader commits and its fact reaches every member's KB.
replicates_and_converges(Config) ->
    Nodes = ?config(nodes, Config),
    ?assertMatch({ok, [_], _}, write(Nodes, {assertz, {capital, france, paris}})),
    ?assertMatch({ok, [_], _}, write(Nodes, {assertz, {capital, japan, tokyo}})),
    %% each member (leader + followers) eventually reads both facts from its own KB
    [ begin
          ?assert(eventually(fun() -> match_ok(prove(Peer, {capital, france, {'X'}})) end, 10000)),
          ?assert(eventually(fun() -> match_ok(prove(Peer, {capital, japan, {'Y'}})) end, 10000))
      end || {Peer, _} <- Nodes ],
    %% commit_index is identical across the committee
    Commits = [maps:get(commit_index, status(Peer)) || {Peer, _} <- Nodes],
    ?assertEqual(1, length(lists:usort(Commits))).

%% A write submitted to a follower is refused with a redirect, not silently dropped.
follower_redirects_append(Config) ->
    Nodes = ?config(nodes, Config),
    {LeaderPeer, _LeaderId, _T} = wait_for_leader(Nodes, 15000),
    [{FollowerPeer, _} | _] = [N || {P, _} = N <- Nodes, P =/= LeaderPeer],
    ?assertMatch({error, {not_leader, _}},
                 prove(FollowerPeer, {assertz, {should, not_commit}})).

%% Kill the leader: a new leader emerges among the survivors and still serves writes;
%% the two survivors converge to identical KBs (both pre- and post-failover facts).
leader_failover(Config) ->
    Nodes = ?config(nodes, Config),
    {LeaderPeer, _LeaderId, _T} = wait_for_leader(Nodes, 15000),
    ?assertMatch({ok, [_], _}, write(Nodes, {assertz, {era, before_crash}})),

    Survivors = [N || {P, _} = N <- Nodes, P =/= LeaderPeer],
    ok = peer:stop(LeaderPeer),

    {_NewLeaderPeer, _NewId, _NewT} = wait_for_leader(Survivors, 20000),
    ?assertMatch({ok, [_], _}, write(Survivors, {assertz, {era, after_crash}})),

    [ begin
          ?assert(eventually(fun() -> match_ok(prove(Peer, {era, before_crash})) end, 10000)),
          ?assert(eventually(fun() -> match_ok(prove(Peer, {era, after_crash})) end, 10000))
      end || {Peer, _} <- Survivors ],
    Commits = [maps:get(commit_index, status(Peer)) || {Peer, _} <- Survivors],
    ?assertEqual(1, length(lists:usort(Commits))).

%%%===================================================================
%%% helpers
%%%===================================================================

status(Peer) -> peer:call(Peer, quod_ledger, status, [?NS]).
role(Peer)   -> maps:get(role, status(Peer), undefined).

%% Submit a write, the way a real client does: find the current leader, try it, and
%% retry against the (re-found) leader on a redirect/timeout — leadership can churn
%% transiently. Returns the committed `{ok, Bindings, Height}` or the last error.
write(Nodes, Goal) -> write(Nodes, Goal, 20).
write(_Nodes, _Goal, 0) -> {error, exhausted};
write(Nodes, Goal, N) ->
    {LeaderPeer, _Id, _T} = wait_for_leader(Nodes, 15000),
    case prove(LeaderPeer, Goal) of
        {ok, _, _} = Ok -> Ok;
        _Transient      -> timer:sleep(200), write(Nodes, Goal, N - 1)  %% redirect/timeout/churn
    end.

%% prove a goal on a node, retrying only while its engine is still rebuilding.
prove(Peer, Goal) -> prove(Peer, Goal, 200).
prove(_Peer, _Goal, 0) -> {error, timeout};
prove(Peer, Goal, N) ->
    case peer:call(Peer, quod_prolog, prove, [?NS, Goal, ?NS]) of
        {error, rebuilding} -> timer:sleep(25), prove(Peer, Goal, N - 1);
        R -> R
    end.

match_ok({ok, [_ | _], _}) -> true;
match_ok(_)                -> false.

%% Wait until exactly one member reports role=leader and the rest agree on its id at
%% the same term. Returns {LeaderPeer, LeaderId, Term}.
wait_for_leader(Nodes, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_for_leader_loop(Nodes, Deadline).

wait_for_leader_loop(Nodes, Deadline) ->
    case settled_leader(Nodes) of
        {ok, Result} -> Result;
        none ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true  -> ct:fail({no_leader, [catch status(P) || {P, _} <- Nodes]});
                false -> timer:sleep(200), wait_for_leader_loop(Nodes, Deadline)
            end
    end.

settled_leader(Nodes) ->
    Statuses = [{Peer, catch status(Peer)} || {Peer, _} <- Nodes],
    Leaders  = [{Peer, S} || {Peer, S} <- Statuses, is_map(S), maps:get(role, S, undefined) =:= leader],
    case Leaders of
        [{LeaderPeer, S}] ->
            LeaderId = maps:get(leader, S),
            Term     = maps:get(term, S),
            %% every reachable member must point at this leader at this term
            Agree = lists:all(fun({_P, St}) ->
                                  is_map(St) andalso maps:get(leader, St, none) =:= LeaderId
                                          andalso maps:get(term, St, -1) =:= Term
                              end, Statuses),
            case Agree of
                true  -> {ok, {LeaderPeer, LeaderId, Term}};
                false -> none
            end;
        _ -> none   %% zero or split leaders: not settled
    end.

eventually(_F, Timeout) when Timeout =< 0 -> false;
eventually(F, Timeout) ->
    case (catch F()) of
        true -> true;
        _    -> timer:sleep(150), eventually(F, Timeout - 150)
    end.

%% self-signed dev cert for the QUIC listeners (TLS 1.3 mandatory), shared by all nodes.
make_cert(Config) ->
    CertDir = filename:join(?config(priv_dir, Config), "certs"),
    ok = filelib:ensure_dir(filename:join(CertDir, "x")),
    Cert = filename:join(CertDir, "cert.pem"),
    Key  = filename:join(CertDir, "key.pem"),
    _ = os:cmd("openssl req -x509 -newkey rsa:2048 -nodes -keyout " ++ Key ++
               " -out " ++ Cert ++ " -days 1 -subj /CN=quod-raft-test 2>&1"),
    true = filelib:is_regular(Cert) andalso filelib:is_regular(Key),
    {Cert, Key}.
