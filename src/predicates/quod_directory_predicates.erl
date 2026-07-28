-module(quod_directory_predicates).
-moduledoc """
Read-only Prolog view of the live system ontology directory.

`directory_host(+Ontology, ?NodeKey, ?Host, ?Port)` is deliberately an
external predicate: it enumerates the bounded ETS route index directly instead
of copying moving network membership into the root ontology's consensus log.
The predicate is available only while executing `quod:root`; private direct
seeds are excluded by `quod_directory:directory_hosts/1`.
""".

-include_lib("erlog/src/erlog_int.hrl").

-export([directory_host_4/3]).

-define(ROOT_NS, <<"quod:root">>).

-spec directory_host_4(term(), term(), tuple()) -> term().
directory_host_4(Goal, Next, #est{bs = Bs} = St) ->
    case {quod_predicates:ctx_ns(quod_predicates:context(St)),
          erlog_int:dderef(Goal, Bs)} of
        {?ROOT_NS, {directory_host, NsTerm, NodeKey, Host, Port}} ->
            case quod_ontology_name:flatten(NsTerm) of
                Ns when is_binary(Ns) ->
                    enumerate(
                      [NodeKey, Host, Port],
                      [[K, H, P]
                       || {K, H, P} <- quod_directory:directory_hosts(Ns)],
                      Next, St);
                error ->
                    erlog_int:fail(St)
            end;
        _ ->
            erlog_int:fail(St)
    end.

enumerate(_Pattern, [], _Next, St) ->
    erlog_int:fail(St);
enumerate(Pattern, [Candidate | Rest], Next,
          #est{cps = Cps, bs = Bs, vn = Vn} = St) ->
    case erlog_int:unify(Pattern, Candidate, Bs) of
        {succeed, Bs1} ->
            case Rest of
                [] ->
                    erlog_int:prove_body(Next, St#est{bs = Bs1});
                _ ->
                    Fail = fun(#cp{bs = Bs0, vn = Vn0}, RemainingCps, FailSt) ->
                               enumerate(
                                 Pattern, Rest, Next,
                                 FailSt#est{cps = RemainingCps,
                                            bs = Bs0, vn = Vn0})
                           end,
                    Cp = #cp{type = compiled, data = Fail, next = Next,
                             bs = Bs, vn = Vn},
                    erlog_int:prove_body(
                      Next, St#est{cps = [Cp | Cps], bs = Bs1})
            end;
        fail ->
            enumerate(Pattern, Rest, Next, St)
    end.
