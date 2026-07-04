-module(quod_committee_predicates).
-moduledoc """
External Erlang predicates that change the committee — the set of `peer_admitted/4` facts.

`admit(Pubkey, Host, Port)` and `remove(Pubkey)` are the interface between the ontology (its rules) and the
committee. They follow the **prove-before-broadcast** discipline (as in bbsvx/onia): a predicate does its
checks and STAGES the `peer_admitted` assert/retract into the proof's write-set — it does **not** submit to
consensus itself. quod's normal write path (`m:quod_prolog` `run_proof` → `submit_write` →
`quod_simplex:append`) turns that staged diff into a committed transaction; every member then applies it,
and `quod_simplex` grows/shrinks its validator set from the same committed diff (`committee_delta/1`). So
the committee stays a pure, deterministic projection of the committed log on every node.

- `admit/3` gates on `can_join/3` (default-open until node signatures land), then asserts
  `peer_admitted(Pubkey, Host, Port, Pubkey)` (`NodeId = Pubkey` at this stage).
- `remove/1` retracts `peer_admitted` **by pattern** (`peer_admitted(_,_,_,Pubkey)`), so the shipped op
  self-matches the committed fact's actual address — a hand-built op with the wrong address would retract
  from the validator set (keyed on the pubkey) but MISS in the kb (keyed on the whole head), leaving the two
  projections divergent. It also refuses to remove the **last** member (the crash-safe floor; the full BFT
  fault-tolerance floor + Byzantine re-validation are a later slice).

Registered per-node in `quod_prolog:build_kb/0`, so `admit`/`remove` are identical on every member and are
never carried in the log — only their resulting `peer_admitted` diff is.
""".

-export([load/1, admit_3/3, remove_1/3]).

-include_lib("erlog/src/erlog_int.hrl").

-doc "Register the committee predicates onto a freshly-built kb (`#est{}`), threading the erlog `#db{}`.".
-spec load(tuple()) -> tuple().
load(#est{db = Db0} = Est) ->
    Db1 = erlog_int:add_compiled_proc({admit, 3},  ?MODULE, admit_3,  Db0),
    Db2 = erlog_int:add_compiled_proc({remove, 1}, ?MODULE, remove_1, Db1),
    Est#est{db = Db2}.

%% admit(Pubkey, Host, Port): prove can_join, then stage the peer_admitted assert. Gate + stage are ONE
%% erlog conjunction — if can_join fails, the assert is never reached, so nothing is staged and the prove
%% fails (run_proof discards the overlay). An ill-typed goal fails closed (never crashes the fact engine).
admit_3(Goal, Next, #est{bs = Bs} = St) ->
    case erlog_int:dderef(Goal, Bs) of
        {admit, Pub, Host, Port} when is_binary(Pub) ->
            case self_ns() of
                undefined -> erlog_int:fail(St);
                Ns        -> Fact = {peer_admitted, Pub, Host, Port, Pub},
                             erlog_int:prove_body(
                               [{can_join, Ns, [Host, Port], Pub}, {assertz, Fact} | Next], St)
            end;
        _ ->
            erlog_int:fail(St)
    end.

%% remove(Pubkey): refuse to remove the last member (crash-safe floor), then retract peer_admitted BY
%% PATTERN — erlog unifies the pattern against the stored clause and the overlay captures its ACTUAL head,
%% so the shipped op matches the committed fact's address and the kb + validator set shrink in lockstep.
%% retract fails cleanly (no solution) if Pubkey is not a member.
remove_1(Goal, Next, #est{bs = Bs} = St) ->
    case erlog_int:dderef(Goal, Bs) of
        {remove, Pub} when is_binary(Pub) ->
            case committee_size(St) > 1 of
                %% DISTINCT var names for the wildcard positions — in erlog every `{'_'}` is the SAME
                %% variable, so three `{'_'}` would unify to one value and the retract would miss.
                true  -> erlog_int:prove_body(
                           [{retract, {peer_admitted, {'Ri'}, {'Rh'}, {'Rp'}, Pub}} | Next], St);
                false -> erlog_int:fail(St)   %% never empty the committee
            end;
        _ ->
            erlog_int:fail(St)
    end.

%% This node's namespace, stashed in the owning `quod_prolog` process dictionary at init — the handler runs
%% in-process during `run_proof`, so it is visible here. (Under `erlog_db_dict` there is no namespace handle
%% in `#est{}`; onia's `self_ns/1` ETS trick does not apply.)
self_ns() -> get('$quod_ns').

%% The current committee size = the number of DISTINCT peer_admitted pubkeys (element 5 of the fact head),
%% not the clause count — a pubkey with more than one address fact must not inflate the floor.
committee_size(#est{db = #db{mod = M, ref = R}}) ->
    case M:get_procedure(R, {peer_admitted, 4}) of
        {clauses, Cs} -> length(lists:usort([element(5, H) || {_Tag, H, _Body} <- Cs]));
        _             -> 0
    end.
