# Multi-ontology writes

This is the current compact map of Quod's write lanes. The
[archived consolidated architecture](outdated/multiwrite-architecture.md)
preserves its pinned rulings, protocol amendments and implementation record.
Read that record and the affected code before changing wire, custody or
recovery semantics.

## One sealed proof, three lanes

The proof worker selects one answer and seals all participating scopes once.
Read-only dependencies are certified and validated at their target; they do
not become writers merely because they were read. The resulting write shape
selects a lane:

| Shape | Commit path | Result |
| --- | --- | --- |
| One writer | That ontology's ordinary signed transaction and consensus | Its applied outcome |
| Several ordinary writers | One atomic source-and-role group | Commit or abort together |
| Explicit independent intent | One durable source claim and separate target applications | Complete vector of certified target outcomes |

The independent lane requires intent proved from the original signed request
and sealed plans. A peer flag or coordinator assertion cannot grant it. The
source role is retained for an ordinary atomic multiwriter even if the
source's own diff is empty. Each target receives only its own sealed material
plus bounded shared evidence; no participant receives another ontology's KB.

## Atomic group

The installed protocol uses Vote, Resolve and Complete records.
Each role makes one immutable prepared or refused Vote under its own
committee. All certified prepared references authorize commit; one certified
refusal authorizes abort. Timeout, missing route and transport refusal do
not decide the group. Resolve publishes or discards each role's hidden plan.
Complete records the terminal group and portable application evidence for
recovery. The client waits for certified applied outcome, while Complete may
finish asynchronously.

`quod_dtx_coordinator` is a volatile driver started from a durable source or
role obligation. It uses monitored asynchronous target work and exact
progress notices. Its restart reconstructs work from certified history;
readiness dips pause obligations rather than retiring them. No timer grants
permission to resubmit an uncertain write or extends the caller's original
deadline.

## Independent operation

A source claim fixes the exact target set. Target applications progress
independently through the same owners. A committed inclusion still needs an
exact applied-result certificate; it is not a terminal result by itself.
Only a complete certified target vector is final. Mixed applied and rejected
results are valid. A timeout yields uncertainty, not an invented rejection.
Source receipt durability can follow client result delivery; resolution uses
the original claim and exact target evidence without new submission.

The pure record and transition modules are `quod_dtx`, `quod_atomic` and
`quod_operation`. `quod_prolog` owns proof and apply, `quod_simplex` owns
ledger custody, and `quod_foreign_log` owns foreign evidence. The local
`quod_effect_journal` retains private direct-effect preparation until the
controlling committed transition authorizes its release. Related domain
changes and receiver consequences belong in one atomic transaction when
they are one transition, as in the [internal FIPA Request](runtime-and-agents.md).
