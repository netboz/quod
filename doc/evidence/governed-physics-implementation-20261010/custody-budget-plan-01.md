# Governed preparation byte budget

QUD.27 live campaign 02 demonstrated a real gap in the existing lifecycle.
The ordinary create proof prepared 304,774 bytes from a 65,222-byte diff; the
compiled 262,144-byte custody limit refused it before commit. The action itself
was 2,097 bytes. Root remains at height 62; no measurement ontology or source
creation grant committed. Preserve both failed campaigns and their original
outcomes. This is an allocation policy limit, not an ETF encoding constraint.
Yan explicitly reiterated that such resource budgets belong in Prolog.

## Existing owners and smallest change

Root already owns the active direct-effect count through
`effect_custody_capacity/1`. The retained runtime resource `effect_custody`
selects that committed policy, tracks its predicate dependencies and installs
it in the single `quod_effect_journal` owner. The journal owns reservations,
private prepared bytes, binding to original transactions/groups/operations,
ordered release, recovery, retirement and durable snapshots.

Extend that same policy and resource to include the maximum prepared bytes per
effect. Replace the one-dimensional policy with
`effect_custody_limits(ActiveCount, PreparedBytes)` and its atomic setter
`set_effect_custody_limits/2`. Both accept nonnegative integers or explicit
`unlimited`. Root entry ACLs remain the authorization boundary. A rule or
staged override cannot install a budget; only the committed selector can.
The seed policy is explicit Prolog: 64 active records and unlimited prepared
bytes. This grants no extra source, proof, transaction or block capacity;
those existing protocol/encoding boundaries remain independently enforced.
Applications can set a finite byte budget through root policy.

Replace journal `configure_capacity/1` and `capacity/0` with
`configure_limits/2` and `limits/0`. Install both values atomically and retain
them together in the journal snapshot. Update every production and test caller,
resource selector, source visibility rule and relevant metrics. A failed committed
selection withdraws limits in that same journal: new reservations and unstaged
preparations become unavailable, while accepted custody remains valid. The
unavailable state is durable and unchanged withdrawals perform no writes. No old arity,
compatibility clause, fallback policy or second budget owner remains.

The journal applies the installed count policy when reserving a slot and the
installed byte policy when staging its exact preparation. Configuration and
staging are serialized by that existing owner. Already staged/bound custody
remains valid when limits tighten; there is no retroactive cancellation of
an accepted operation. Count pressure keeps its existing retryable `busy` class;
its detail remains available through journal stats and metrics. Byte pressure
is a nonretryable `{effect_custody_limit, prepared_bytes, Actual, Limit}` after
digest validation, carried by the closed scope and signed-result catalogs with
uint64 values. HTTP and the ordinary client report the exact bytes and limit.
Verify propagation through single-writer, atomic and independent admission;
all use the existing stage/bind owner. Preserve backtracking, rollback and
cancellation of unused reservations.

Remove the compiled prepared-byte ceiling from ontology encoding/decoding and
all three journal recovery row checks. Encoding remains deterministic and the
prepared digest remains bound to the certified effect. Recovery validates the
stored hash, original action and transaction/group/operation evidence; it must
not apply a newly lowered admission budget to already accepted custody.
No ledger history, signature, deadline or operation identity is changed.

The preparation currently repeats genesis data. Keep that representation out
of this policy fix: changing the codec solely to squeeze under a hidden cap
would leave the policy ownership defect in place. No new alternate codec is
introduced. A separate refinement can remove copies once its codec and recovery
contract is reviewed; it is not required to implement governed allocation.

## Deployment and validation

The changed journal policy snapshot is one new format, with explicit rejection
of superseded formats and no migration branch. Compatible validators and a
coordinated cold candidate release/refound including `direct_effects.qej` are
required; Yan has already
authorized that candidate scope. Do not mutate the separate main job. A
retained founding manifest cannot be changed by editing the package source.

Before deployment verify the real root resource and lifecycle owners:

- The full agent/space/physics composition is founded through the ordinary
  action with its complete configuration, and the recorded exact anchor and
  initial content survive recovery.
- A finite Prolog byte policy rejects the same preparation before binding or
  commit, with actual bytes and policy limit in the result. Unavailable,
  malformed, duplicate and unauthorized policy changes fail closed.
- A committed policy change installs through existing dependency notices;
  repeated unchanged reconciliation causes no selection, configuration,
  history replay or storage write/sync. Real policy changes remain durable.
- Tightening the limit does not invalidate staged/bound/committed custody or
  its recovery. Journal restart retains the exact policy and original operation.
- Concurrent reservation/staging/configuration, released reservations and
  failed proofs preserve count accounting. Existing atomic and independent
  recovery obligations remain covered.

Use the requested Fable plan review before production changes, independently
check its advice, then obtain the implementation review and clean sequential
release gates. Retain true exits, failed campaigns and exact tree hashes. The
remote collider campaign resumes only in a separately labeled campaign after
new deployment. Real signed personal desktop acceptance still requires its own
fresh identity/history baseline and remains outstanding.
