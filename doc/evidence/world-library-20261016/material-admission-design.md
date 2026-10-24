# Material admission refactor

Authorized in the `shared_refactor` response on 2026-10-17. This is the
implementation design, not a validation receipt.

The composed lobby has 635 source terms and a 339,337-byte canonical genesis
diff before its instance facts. The old 256 KiB transaction envelope refuses
it. Its 516 symbols outside the release vocabulary also exceed the old 512
allocation quota. Neither a split founding nor preloading atoms corrects this.

## Policy and ownership

The existing root proof owns creation admission. Each target's existing proof
session owns admission of its new sealed material. A shared Prolog policy
provides defaults and ordinary per-ontology overrides. Selection runs against
the proof's pinned committed state, strictly read-only and without governed
bridges; its reads join the existing OCC dependency set. A staged write cannot
raise its own allowance. Missing, duplicate or invalid policy refuses admission.
This requires no process, installed-policy cache or new transaction lane.

Measure canonical bytes and distinct symbols, with operations and read entries
for plans. Count symbols independently of the current VM vocabulary. Report
the kind, resource, actual quantity and allowance on refusal. Check source
symbols before materializing opaque founding input. Allocation still validates
all UTF-8 names and reserves real VM atom-table headroom before any allocation.

Accepted history uses the same canonical codec and physical checks, without
reapplying today's allocation policy. Removing the fixed materializer quota
therefore closes the warm-founder/cold-reader inconsistency. Client request
parsing and authenticated client allocation retain their existing independent
protections; this change does not widen untrusted goal syntax.

## Encoding

Keep the canonical alphabet, signatures, identities and stored bytes unchanged.
Derive material envelope capacity from the existing 1 MiB transport frame and
the existing scope envelope's two material carriers, principal and fixed
metadata. The shared byte owners continue to cover founding, transaction and
block encoding, relay, custody, scope transport, foreign pages and recovery.
The assembled envelope is always checked; an individual admissible plan does
not promise that an arbitrary multi-plan group fits. Do not widen transport,
split a transition or silently reduce its content.

## Verification obligations

- Combined library founding and the original create/list/enter/return journey.
- Resource-specific refusal before source atoms or storage are allocated;
  valid custom limits and fail-closed missing/ambiguous/invalid policy.
- A staged allowance change cannot authorize its own oversized material;
  committed policy updates conflict with already captured policy reads.
- Cold decoding above the removed 512 quota and unchanged signed bytes.
- Maximal enclosing carriers, foreign-page delivery and durable reopen.
- Through the real owners, unchanged repeats do not replay history, rebuild
  projections or write policy state; actual updates take effect.
- Frozen Fable review and clean sequential gates on the complete scope.
