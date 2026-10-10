# Capability architecture review disposition

Fable's follow-up review used `claude-fable-5-1`, returned child exit 0 and
changed none of 63 frozen inputs. It found the existing-owner capability
proposal not ready for implementation. The interactive architecture question
is still pending; neither the question's default nor this review is approval.
No capability-evolution implementation or live transition has been made.

The current loader runs at genesis only. An evolution contract must name the
activation height and make live application and cold recovery agree at every
height. Quiescence cannot be assumed from a release description: there is no
current transition which fences admission of new proofs and drains retained
scopes at a profile boundary.

The review suggested live in-process installation subject to checking snapshot
isolation. That suggestion is not accepted as an implementation. The real
`quod_erlog_db_mvcc` owner stores compiled procedures as static shared ETS rows.
`registry-snapshot-diagnostic-01.erl` creates one isolated store, retains its
height-0 handle, advances to height 1, registers a new compiled procedure, and
then observes that procedure through the old handle. The true child exit is 0.
No ontology, native physics world or ledger is involved. A live module load
would expose new compiled procedures to old scopes whose registry descriptor
flags still describe the previous profile. Fencing or rebuilding those scopes
needs a concrete owner contract before code.

Both ordinary and prepared commit validation need a named protected record
and a precise authenticated exception. Root participation alone cannot bind
approval to the target's exact identity, old/new epoch and ordered profile.
The target must verify the relevant sealed root material or equivalent existing
authenticated evidence. The root receipt is authorization evidence; the target
record alone determines the installed registry. No request-time root query or
second native-profile inventory is proposed.

The authorization identity also needs to be specified. An ordinary personal
lobby proof cannot borrow root's direct-call administrator authority. Root's
released-profile policy must name its catalogue, authorized writer and public
queries. A literal manifest-derived group reference in a proposed diff may
depend on the diff itself; the contract must use an original request identity
or existing non-circular sealing evidence instead of assuming that reference
is available during authoring.

The profile/code digest rule must distinguish immutable provenance from any
new installation requirement. Existing founding digests are provenance, not
lifetime code pins. A stricter rule would be a new contract, and must include
retained foreign projection consumers as well as validators. Revocation must
invalidate the existing resource basis and retire installed physics even while
the Prolog selector remains present. It must not switch a controlled body into
observer travel. Old custody and uncertain operations retain original identity.

These are concrete unsolved mechanics at the task's required architecture gate,
not permission to revive the removed module-selection experiment. Historical
format interpretation needed to preserve the actual lobby's history does not
justify permanent old/new execution branches. The fresh signed lobby baseline,
deployment profile and release authority remain unverified.
