# Independent disposition

Fable completed the requested plan review using claude-fable-5-1, child exit 0,
28 unchanged frozen inputs. Its verdict required two corrections before implementation.

1. Accepted: package changes do not migrate founded policy. The revised plan adds
a concrete live-source inventory and rollout gate, atomic policy/action edits for
active scopes, the fail-closed recovery interval and its explicit quiescent-window
condition. Current personal-world evidence is not presented as a fleet inventory.
This gate must be satisfied before deployment; no live rollout is made now.
2. Accepted: the signing bridge does not itself use strict policy context. The
revised plan specifies argument/scope/destination validation first, principal
binding in proof context, strict local committed reproof with retained chain and
access guard, monotonic read absorption and cleanup. Calls to governed predicates
inside that pure policy are invalid, even with a correct retained chain.

The recovery descriptor and runtime resource scope remain positive-only. The
new direct read supports epoch zero through the same vault owner. Test fixtures
must use previous epochs, including physics restart sequence 1 then 3. Losing
initialization may leave inert encrypted custody; no automatic deletion of keys
or uncertain write resubmission is introduced. The implementation review must
check these corrections against code and real test results.

Yan subsequently clarified that the physical floor/ground are drafts; generic
hole support remains required, while detailed matching of the draft is unnecessary.

Yan subsequently clarified again: no backward compatibility; refound ledgers if
needed. This supersedes the proposed policy-source migration/window procedure.
The current plan has a simple coordinated clean release boundary, with an
explicitly authorized candidate refound if necessary and fresh signed acceptance
baseline afterward. No migration machinery or compatibility branch is needed.
