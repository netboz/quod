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

- `admit/3` gates on `can_join/3`, then asserts `peer_admitted(Pubkey, Host, Port, Pubkey)`
  (`NodeId = Pubkey` at this stage).
- `remove/1` retracts `peer_admitted` **by pattern** (`peer_admitted(_,_,_,Pubkey)`), so the shipped op
  self-matches the committed fact's actual address — a hand-built op with the wrong address would retract
  from the validator set (keyed on the pubkey) but MISS in the kb (keyed on the whole head), leaving the two
  projections divergent. It also refuses to remove the **last** member.
- `peer_ready/1` is a **read-only reality bridge** for `can_join` rules (the root ontology's admission rule
  is `can_join(_Ns, _Addr, Pk) :- peer_ready(Pk)`): true iff this node's `m:quod_feed` holds a fresh feed
  digest from the candidate at a height within one catch-up window of our own applied height. It stages
  nothing — `can_join` must stay side-effect-free — and reads the feed's public digest table directly
  (never a gen_server call: this handler runs inside `m:quod_prolog` during the membership verdict, where a
  round-trip into the feed would deadlock the prolog←feed←simplex triangle).

> #### `peer_ready` is liveness UX, not a security gate {: .warning }
>
> The digest *sender* is authenticated (link header + mutual TLS), but the *height* it advertises is
> unauthenticated content — a Byzantine candidate can claim any height. What the gate prevents is the
> honest-operational disaster: admitting a dead or lagging node into a small committee. While the committee
> is size 2 or 3 the quorum is ALL members (t=0), so a dead admittee freezes writes — and 1→2 / 2→3 are
> **one-shot**: the admit commits under the OLD quorum, so if the fresh member permanently dies right after,
> the namespace is protocol-unrecoverable (recovery is restarting the member — its volume resumes catch-up
> and it re-promotes). The runbook therefore also gates admits on the candidate being a supervised alloc.

> #### The predicate checks are honest-path UX, not the safety boundary {: .info }
>
> These predicate-level guards (`can_join` in `admit`, the last-member floor in `remove`) run only on the
> **submitting** node — they give an honest client fast, local feedback. They are NOT the security boundary:
> a Byzantine submitter that hand-builds a raw `peer_admitted` diff skips them entirely. The authoritative
> defense is in `m:quod_simplex`, enforced by every validator before it support-signs — the pure shape +
> never-empty gate (`membership_change_ok/2`) and the per-node KB re-validation
> (`quod_prolog:request_membership_verdict/5`, which re-proves `can_join` and requires a retract's exact
> clause to be present). See `doc/deferred.md` §3. (Signed membership authorship — closing committee
> *packing* — is Phase B.)

Registered per-node in `quod_prolog:build_kb/0`, so `admit`/`remove` are identical on every member and are
never carried in the log — only their resulting `peer_admitted` diff is.
""".

-export([load/1, admit_3/3, remove_1/3, peer_ready_1/3, admitted_pubkeys/1]).

-include_lib("erlog/src/erlog_int.hrl").

-doc "Register the committee predicates onto a freshly-built kb (`#est{}`), threading the erlog `#db{}`.".
-spec load(tuple()) -> tuple().
load(#est{db = Db0} = Est) ->
    Db1 = erlog_int:add_compiled_proc({admit, 3},      ?MODULE, admit_3,      Db0),
    Db2 = erlog_int:add_compiled_proc({remove, 1},     ?MODULE, remove_1,     Db1),
    Db3 = erlog_int:add_compiled_proc({peer_ready, 1}, ?MODULE, peer_ready_1, Db2),
    Est#est{db = Db3}.

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

%% peer_ready(Pk): succeed iff Pk is a live, caught-up follower by this node's own observation
%% (quod_feed:peer_ready/3 — fresh digest + height slack). Read-only: stages nothing, binds nothing.
%% An unbound/non-binary argument fails closed (the gate is a check, not a generator). NOTE validators MAY
%% legitimately split on this predicate (each judges from its OWN digest table) — see the verdict-split
%% note at quod_prolog:membership_verdict/2.
peer_ready_1(Goal, Next, #est{bs = Bs} = St) ->
    case erlog_int:dderef(Goal, Bs) of
        {peer_ready, Pk} when is_binary(Pk) ->
            %% BOTH the namespace and the applied-height mirror must be present, or we fail CLOSED. A
            %% missing height must NOT default to 0: ready/4's slack check is `Height + window >= Judge`,
            %% which a judge height of 0 passes for ANY candidate — admitting a node arbitrarily far behind.
            case {self_ns(), applied_height()} of
                {Ns, H} when is_binary(Ns), is_integer(H) ->
                    case quod_feed:peer_ready(Ns, Pk, H) of
                        true  -> erlog_int:prove_body(Next, St);
                        false -> erlog_int:fail(St)
                    end;
                _ -> erlog_int:fail(St)
            end;
        _ ->
            erlog_int:fail(St)
    end.

%% This node's namespace, stashed in the owning `quod_prolog` process dictionary at init — the handler runs
%% in-process during `run_proof`, so it is visible here. (Under `erlog_db_dict` there is no namespace handle
%% in `#est{}`; onia's `self_ns/1` ETS trick does not apply.)
self_ns() -> get('$quod_ns').

%% The judge's applied height, stashed next to '$quod_ns' by the owning `quod_prolog` (updated on every
%% apply) — `quod_prolog:applied/1` from in here would be a gen_server call to self. `undefined` if the
%% mirror was never primed; peer_ready_1 then fails the gate CLOSED rather than defaulting to a height that
%% passes the slack check.
applied_height() -> get('$quod_applied').

%% The current committee size = the number of DISTINCT peer_admitted pubkeys — a pubkey with more than
%% one address fact must not inflate the floor.
committee_size(Est) -> length(admitted_pubkeys(Est)).

-doc """
The DISTINCT `peer_admitted` pubkeys committed in a kb (element 5 of the fact head, sorted) — the
committee as facts. `quod_prolog`'s membership verdict uses it for the one-fact-per-pubkey invariant
(reject an `admit` of a pubkey already admitted), which also keeps the KB and the validator-set
projection in lockstep on retract.
""".
-spec admitted_pubkeys(tuple()) -> [binary()].
admitted_pubkeys(#est{db = #db{mod = M, ref = R}}) ->
    case M:get_procedure(R, {peer_admitted, 4}) of
        {clauses, Cs} -> lists:usort([element(5, H) || {_Tag, H, _Body} <- Cs]);
        _             -> []
    end.
