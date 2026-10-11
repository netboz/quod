# Governed first custody and complete activation

This evidence covers the missing first signing key for an ontology-backed agent
and complete initial physics configuration. It does not close real signed
desktop or remote collider acceptance.

## Implementation

The existing agent predicate module now exposes an exact-scope, read-only key
preparation query. Committed pure Prolog policy authorizes the authenticated
caller, agent, prior assignment and destination. The existing encrypted vault
retains one stable preparation for that assignment; a repeated unchanged check
performs no write, link, rename or sync. Actual mutations retain their durability,
including uncertainty after a failed mutation and recovery after vault restart.
Preparation grants neither hosting nor signing authority.

The shared preparation policy is now `can_prepare_agent_key/5`. Its superseded
four-argument form and the unused vault `generate/1` interface are removed, with
all repository callers updated. Recovery retains its positive-epoch contract.
Initial host assignment and complete physics configuration use the existing
action and transaction owners. No new process, domain engine or propagation
mechanism was added.

The final production delta is +119 lines across the existing agent/vault/runtime
owners and +82 lines in Nomad configuration to provision and enable the existing
local vault. This implements the missing governed query and its authorization
and durability checks. The Rust change is coverage for a genuine surface opening;
the native geometry algorithm is unchanged. Detailed geometry matching of the
draft floor/ground is outside this validation.

## Focused verification

`focused-validation.tar.gz` retains full logs, child exits and failed-run triage.

- Baseline: the initial sandboxed attempt could not open the TLS listener.
  The separately recorded run with local network permission passed 47 tests.
- Agent implementation: 89 tests passed. The earlier 50-test run had one
  test-harness macro variable collision; its failure and correction are retained.
- Physics/source regression: 190 cases passed in the 192-case run. Its two new
  configuration tests failed on noncanonical test variables before submission.
  A second focused run exposed an incorrect expected conflict encoding in those
  assertions. After correcting the test inputs and requiring the actual ordinary
  single-writer conflict result, both cases passed. Neither failed run is reported
  as a pass; production behavior and assertions were not weakened.
- Native: all 18 tests passed, including travel through an explicit hole and
  collision against its solid rim.

The two complete-configuration cases use independent non-lobby identities and
different authored gravity. They start nonphysical, prepare real custody through
signed ingress, reject incomplete configuration atomically, reject a revoked
assignment grant, and fence competing first assignments before checking the
installed native owner. Other production-owner suites cover subscribed live
collider editing, withdrawal, authorization, stale fences and recovery.

## Reviews and release scope

Fable reviewed the plan against 28 frozen inputs. The report, exact invocation,
receipt, source hashes and independent disposition are in `plan-review/`.
The strict policy context finding is addressed in the implementation.

Yan explicitly requires no backward compatibility and has authorized candidate
ledger refounding, most recently: “you can refound as you want”. This supersedes
the earlier proposed policy-source migration procedure. The release uses one
compatible binary and fresh candidate ledgers through the existing single-writer
deployment process. A fresh signed personal-world baseline must follow a
refound. The separate main network is outside this deployment's scope.

Fable's first implementation review approved proceeding to the next gate with no
blocking defect. Its exact report and the independent disposition are retained in
`implementation-review/`. The subsequent corrections passed 104 focused tests,
including refusing epoch-zero recovery publication and verifying zero storage
work after unchanged rejections. `corrections-validation.tar.gz` also retains
local Nomad parsing and vault provisioning tests, including the actual release
image. The denied host read of a correctly private container-created key and the
corrected test are both recorded.

The initial clean campaign passed its first five gates, then was deliberately
stopped during EUnit because review corrections changed its frozen implementation.
`superseded-gates-01.tar.gz` retains its partial logs, intent and stop marker; it
has no successful EUnit exit and is not a passing release campaign. Final clean
sequential gates now run against separately frozen 0.7.258 inputs. Their manifest
includes the planned two-file version label; the implementation and label will
be committed separately, and every executable input must match the final commit
before image publication. Unrelated user changes are excluded.

Fable accepted the corrections and deployment configuration against 40 unchanged
frozen inputs, with child exit 0. Its report and independent disposition are in
`corrections-review/`. A local boot of the existing release with this rendered
configuration verified a ready root and vault, with the network vault provider
disabled. `vault-boot-baseline.tar.gz` retains that evidence and two test-harness
corrections (explicit embedded-mode loading and readability of the public report).
The final 0.7.258 image must repeat this boot check before publication.

The final full gates are still running. No release, deployment, refound or new
signed personal-world baseline is claimed by this implementation evidence.

The local gate runner was initially rejected by automatic approval review as if
it contained deployment operations. Inspection established that its only child
commands are Cargo, npm and rebar verification in the frozen local checkout. The
same runner was then approved with that evidence and started once. No deployment
operation was performed by the gate runner.
