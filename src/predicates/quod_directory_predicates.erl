-module(quod_directory_predicates).
-moduledoc """
Read-only Prolog view of the live system ontology directory and its root
control-peer authority.

`directory_host(+Ontology, ?NodeKey, ?Host, ?Port)` is deliberately an
external predicate: it enumerates the bounded ETS route index directly instead
of copying moving network membership into the root ontology's consensus log.
`directory_control_peer(?NodeKey)` projects the canonical public keys from the
root proof snapshot's committed `peer_admitted/4` facts. Both predicates are
available only while executing `quod:root`; private direct seeds are excluded
by `quod_directory:directory_hosts/1`.
""".

-include_lib("erlog/src/erlog_int.hrl").

-export([directory_host_4/3, directory_control_peer_1/3]).

-define(ROOT_NS, <<"quod:root">>).

-spec directory_host_4(term(), term(), tuple()) -> term().
directory_host_4(Goal, Next, #est{bs = Bs} = St) ->
    case {quod_predicates:ctx_ns(quod_predicates:context(St)),
          erlog_int:dderef(Goal, Bs)} of
        {?ROOT_NS, {directory_host, NsTerm, NodeKey, Host, Port}} ->
            case quod_ontology_name:flatten(NsTerm) of
                Ns when is_binary(Ns) ->
                    Candidates =
                        [[K, H, P]
                         || {K, H, P} <-
                                quod_directory:directory_hosts(Ns)],
                    prove_member(
                      [NodeKey, Host, Port], Candidates, Next, St);
                error ->
                    erlog_int:fail(St)
            end;
        _ ->
            erlog_int:fail(St)
    end.

%% Root's committed membership facts are the sole directory-control authority.
%% `admitted_pubkeys/1` already returns a sorted distinct list; the additional
%% byte-size check keeps malformed binary facts outside the public API.
-spec directory_control_peer_1(term(), term(), tuple()) -> term().
directory_control_peer_1(Goal, Next, #est{bs = Bs} = St) ->
    case {quod_predicates:ctx_ns(quod_predicates:context(St)),
          erlog_int:dderef(Goal, Bs)} of
        {?ROOT_NS, {directory_control_peer, NodeKey}} ->
            Keys =
                [Key
                 || Key <- quod_committee_predicates:admitted_pubkeys(St),
                    is_binary(Key), byte_size(Key) =:= 32],
            prove_member(NodeKey, Keys, Next, St);
        _ ->
            erlog_int:fail(St)
    end.

%% Delegate unification and choice-point management to Erlog's standard list
%% predicate. Prepending the goal is O(1); no private enumerator is needed.
prove_member(Pattern, Candidates, Next, St) ->
    erlog_int:prove_body(
      [{member, Pattern, Candidates} | Next], St).
