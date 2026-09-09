# Foreign-cache writer custody across owner restart

Status: **implemented in the coherent owner cut; final independent review
closed 2026-09-10, safe to commit and deploy with preserved ledgers**. Baseline
`5c374c5` / 0.7.157. The stop condition in the approved
[exact-reference contract §4.4](exact-reference-lifecycle-tracing-contract.md#44-worker-custody-and-restart-boundary)
was reached by the actual same-file test, then returned for review. Approval
includes the registry-failure and phase-session corrections below. The local
implementation evidence is recorded in the
[exact-reference checkpoint](exact-reference-lifecycle-tracing-contract.md#implementation-checkpoint--2026-09-09);
it is not a performance result or deployment acceptance. The original fail-before
campaign changed no production or repository test code and made no commit,
deployment, ledger purge or hardware run.

## 1. Reproduced failure, not a timing conjecture

The isolated probe uses the existing foreign owner, verifier and signed
fixture. A real successful request first creates a checkpointed genesis prefix.
Each verifier then passes its real `reserve_page` request and is held at the
next operation, `quod_ledger_store:append/2`. The approved directional watcher
is installed before the old owner dies. Its processing of the real owner-DOWN
message is delayed, representing a finite scheduling delay.

After old-owner death, the replacement owner admits its own verification.
Both workers are now at the append boundary with distinct raw file handles:

| Observation | Old worker | Replacement worker |
|---|---:|---:|
| Live cache-log inode | 755240 | 755240 |
| Captured append offset | 1027 | 1027 |
| Initial last index | 1 | 1 |
| Durable slot-2 bytes written | 778 | 778 |
| Append result | `ok` | `ok` |
| Resulting file size | 1805 | 1805 |

Both append calls complete while the old worker remains alive, after the old
owner has died. Resuming the real watcher then kills that worker; the new
request completes successfully. This proves overlapping **writer custody of
the same file/inode and offset**, not simultaneous CPU execution. The two
writes deliberately use identical valid certified bytes. No corrupt or forged
certificate is fabricated and no on-disk corruption is claimed by this probe.

The append and watcher modules are instrumented only in the isolated VM with
before/after barriers around their original bodies; production owner/verifier
code is unchanged. This is a valid preemption point after permission, not a
bypass of the owner reservation. It does not establish any hardware outlier's
cause. Evidence and runnable harness:

- `/tmp/quod-custody-probe-vlt6hN/HANDOFF.md` (reproduction, hashes and cleanup)
- `/tmp/quod-custody-probe-vlt6hN/result.json`
- `/tmp/quod-custody-probe-vlt6hN/control.json`
- `/tmp/quod-custody-probe-vlt6hN/custody_probe.erl`

The independent control lets the watcher process DOWN before replacement:
the old append never runs and replacement verification succeeds. The control
retains a reused descriptive label from the positive harness; its explicit
`old_append` and worker-liveness fields, explained in the handoff, distinguish
the actual schedule.

The first probe was correctly rejected as insufficient: without a committed
checkpoint the replacement removed/recreated the cache, so identical pathnames
referred to different inodes. The corrected test above seeds the real prefix
and asserts inode equality. Keep that distinction in the permanent regression.

## 2. Why the already-approved watcher is insufficient

The watcher establishes eventual termination, not exclusion. A second owner
can be registered while the first worker has yet to process termination.
`reserve_page` is accounting/permission from a particular owner, not a fencing
token that `file:pwrite` verifies. Rechecking owner liveness immediately before
append would leave the same check-then-write race.

At the baseline:

- `quod_foreign_log:persist_verified_page/8` obtains a reservation before append
  (`src/quod_foreign_log.erl:5108`), then separately writes phase/checkpoint state.
- `quod_ledger_store:open/3` and `resume/1` create writable handles without
  mutual exclusion (`:150`, `:217`); an EOF match is not custody.
- `quod_process:kill_when_owner_dies/2` sends kill asynchronously (`:14`).
- The root supervisor is `one_for_one`, so replacing foreign-log does not
  await its unregistered workers (`src/quod_sup.erl:20`).

There is also mutation **before worker launch** today:
`ensure_history` → `load_or_new_history` → `load_history_dir` can remove a bad
cache or delete temporary files (`quod_foreign_log.erl:2176`, `:6086–6140`).
Protecting only append, or registering a worker after these calls, is not a
complete solution. All mutation of this cache must belong to the same custody.

Distinguish two kinds of phase-file cleanup. Owner-side `terminate/2`,
`reset_cache_accounting/2`, rejected worker-result cleanup,
`close_replaced_phase_session/2` and `hibernate_idle_history/3` call
`quod_dtx_phase_index:close/1`. `open_unique/2` chooses a fresh 128-bit random
session token; `close/1` deletes only that captured session path, not a
successor's separately created path (`src/quod_dtx_phase_index.erl:85–103`,
`:155–160`). This is existing session-specific ownership, not identity-wide
writer exclusion. A transferred suspended session retains the **same** path:
its transfer must wait for successful custody acquisition and the previous
holder must no longer clean it up.

The broad sweep is different: `fresh_phase_index/2` →
`quod_dtx_phase_index:cleanup/2` → `cleanup_names/2` removes every matching
`dtx-phases.<token>.dets` file (`quod_foreign_log.erl:4834`;
`quod_dtx_phase_index.erl:185–207`). It must run under custody and exclude the
exact suspended-session path handed to the current custodian. The baseline
admission `cleanup_cache_temps/1` does **not** perform that sweep: it deletes
only `MANIFEST.new.*` and `CHECKPOINT.new.*` (`quod_foreign_log.erl:6126`).
Both broad phase cleanup and admission's destructive cache/temp recovery need
custody; do not conflate their source locations or move all unique-path close
operations into a new cleanup executor.

## 3. Approved solution: register the existing writer's lifetime

Use gproc through the existing `quod_reg` owner conventions. Do not add a lock
server, new writer process, supervisor, cache or verifier. The existing short-
lived verifier worker is the registered append custodian for its anchored
identity, for example `{foreign_cache_writer, Identity}`.

This is a **new exclusion/registration protocol**, now explicitly reviewed as
part of this cut, not diagnostic cleanup. The key represents the node's
one cache for that exact namespace/anchor; changing root path spelling must
not permit two custodians for the same identity. During a configured cache-root
change, conservatively waiting for the old same-identity worker is acceptable.
Unrelated identities retain independent workers and do not share a global lock.

Required contract:

1. Atomically register before opening a writable cache handle, trimming a log,
   resetting/removing the cache, cleaning phase/temp files or writing manifest,
   ledger or checkpoint state. Do not use lookup-then-write as exclusion.
2. Keep that name for the existing worker's full mutation lifetime, including
   suspension/close and metadata handoff. Do not transfer it to a new worker
   merely because a result message arrived. Automatic removal on process death
   is the release edge; no lease expiry or periodic refresh.
3. On occupied custody, park the admitted work in the existing foreign-log
   queue with a distinct custody wait reason. No busy reply, second waiter
   queue, alternative executor or immediate respawn loop. Route availability
   and file custody are different conditions; neither implies the other.
   Work waiting only for custody retains its already-admitted cache-fill
   obligation even when its callers expire, as runnable queued work does today.
   Do not accidentally apply callerless **route**-park retirement to it. Once
   custody is available, ordinary route/verification failure rules still apply.
4. Use the existing gproc name monitor and subscribe/check discipline so
   release before, during or after parking cannot be missed. Correlate the
   monitor, exact identity and current job. A release permits one new atomic
   acquisition attempt; if another legitimate holder wins, remain parked.
   Never inherit custody using gproc `standby` or `give_away`.
   Install the job's wait correlation before a release notification could be
   discarded. Failed acquisition is custody contention, not verifier failure:
   preserve the original job and resident session. Today's immediate transfer
   and clearing of `phase_session` in `launch_request_owned` cannot happen
   before successful acquisition. An acquired/denied handoff must remain in
   this owner/worker pair and its existing queue, not become another broker.
   Contention can park only after that name monitor was successfully installed.
   Both name registration and monitoring call the gproc server synchronously;
   server unavailability is not an occupied-name verdict or a release edge.
   If monitor establishment fails, fail through the existing owner's failure
   boundary, rather than retain an unmonitored row with no future wake. Existing
   supervision and caller-unavailability semantics apply; no registry restart
   notifier, polling or private retry service is introduced. A registration
   may have committed before its reply was lost: a failed acquisition worker
   still exits, and any recorded name remains conservative until death cleanup.
5. Retain the directional owner-death watcher: it makes the old worker stop;
   the name prevents the replacement from mutating until that happens. The
   registration is not evidence, authority, a quorum vote or a durable lease.
6. Make admission's cache inspection read-only. Move its destructive
   cleanup/reset into the same custody-held recovery path; do not duplicate it
   in both places. Preserve the existing unverified checkpoint/route-hint
   meaning and cold discovery behavior. Reading metadata before acquisition
   cannot authorize a mutation or become a trusted resident projection.
   Revalidate mutable metadata after acquisition before acting on an earlier
   corrupt/missing observation: the previous writer may have repaired it.
   Keep unique-session close under its actual session owner, with no stale
   cleanup after transfer. Move broad phase sweeps into custody-held cleanup
   and preserve the exact retained session path; a wildcard sweep cannot use
   random session naming as its exclusion proof. No duplicate cleanup path.
7. Preserve one writer per live owner as well as across owner incarnations.
   The common cleanup covers failure/normal completion/cancellation. The
   actual gproc name lifecycle, not a sleep or expected scheduler ordering,
   determines when a successor can enter the cache.
8. Keep the existing registry/application lifetime boundary described below.
   Loss/recreation of its table is not writer release. A local name covers
   one BEAM only; two VMs must not share the same live node data directory.
   This is the inherited main-ledger deployment invariant (there is no file
   lock there either), not a new cross-VM exclusion mechanism in this cut.

This adds acquisition/release work at job boundaries, not another per-entry
or per-page handshake. It does not serialize different ontologies or change
certificate verification. No latency improvement is claimed from it.

### Registry restart is not registry-table loss

In pinned gproc 0.9.1, `gproc:start_link/0` runs `create_tabs/0` in its caller
before starting the server. Under the existing child specification that caller
is `gproc_sup`, which therefore owns the ETS table, without an heir. A server
crash leaves the table and custody registrations intact; the permanent child
restarts and `gproc:init/1` calls `set_monitors/0` to rearm process monitors from
those preserved entries (`gproc.erl:201`, `:2807–2831`; `gproc_sup.erl:51–71`).
Existing name-monitor data survives too. A newly requested monitor during the
outage may fail; the successful-monitor requirement above is essential.

Killing the table-owning supervisor terminates the gproc application, not just
its restartable server (`gproc_app:start/2`). Quod's release starts gproc as a
**permanent application**, so that failure terminates the node; a surviving
writer cannot coexist with a recreated table in that BEAM. This guarantee
depends on the release start type, not the child's `permanent` flag alone.
Do not weaken it to `ensure_all_started/1`'s temporary application semantics.
Administrative stop/restart of gproc underneath a live Quod node is likewise
not a supported recovery sequence; stop the whole node. These boundaries do
not claim OS-wide file exclusion or replace the cache's certified recovery.

Release evidence is kept separate from runtime evidence: the current
`rebar.config` release list retains bare `gproc` (the permanent default).
The local `rebar3 as prod release` build on 2026-09-09 exits 0; its generated
`_build/prod/rel/quod/releases/0.7.157/start.script` explicitly contains
`{apply,{application,start_boot,[gproc,permanent]}}`. This replaces the initial
inspection of an old 0.7.47 artifact with the current release definition's
boot instruction. It is not inferred from temporary-application EUnit setup
and is not a deployment claim; final source gates and review remain required.

The isolated registry tests pass all three cases on gproc 0.9.1 / OTP 28.0.2
(focused EUnit exit 0; `/tmp/quod-foreign-registry-u9fT6w/focused-1.log`). The
permanent-application case observes peer VM exit status 1; the temporary
control instead preserves the old live holder while a new table admits another
holder. This proves the registry failure distinction, not the foreign owner's
file mutation, session handoff or complete implementation gates.

## 4. Proof obligations and alternatives to challenge

The reviewer should prove or refute that name ownership covers the **complete
mutable cache object**, including the pre-worker cleanup above and phase
sessions, rather than just the log descriptor. Guard against these shortcuts:

- watcher only, link only, or `is_process_alive` before writing;
- releasing on kill-send rather than worker death;
- using a captured EOF/session as a writer lock;
- guarding append while startup can still unlink the live cache;
- permitting a route wake to bypass a custody wait;
- accepting an unregistered failed acquisition as a normal work launch;
- dropping callerless admitted work merely because custody is occupied, or
  retaining callerless route-parked work contrary to the approved lifecycle;
- a stale gproc notification starting work in a replacement row;
- adding a private map of writers that disappears with the very owner whose
  replacement must observe them.

An alternative using existing supervision or session ownership is welcome if
it proves the same exclusion for untrappable owner death without blocking the
node-wide coordinator on disk work. Do not adopt a registration mechanism
merely because it is familiar if the existing ownership can be made simpler.
The approved registry/session boundary still needs its implementation tests;
approval is not evidence that all handoff schedules have already been closed.

## 5. Required permanent tests

1. Preserve the reproduced checkpointed same-inode schedule with the watcher
   delayed. Replacement must not open/trim/delete/append mutable cache state
   while the old worker holds custody. Release the watcher; observe old worker
   death, normal registry release and successful replacement verification.
2. Normal completion, worker crash, source loss, owner normal stop, owner kill
   and owner replacement at each mutation/handoff boundary. No late write to
   either the live inode or an unlinked old file after custody retirement.
3. Custody release before subscription, between subscription and park, and
   after park; duplicated/stale notifications; failed reacquisition race.
   Exactly one writer, no missed wake, no self-retry, original caller deadlines.
4. Read-only discovery against valid and corrupt checkpoint metadata while an
   old writer is present: no deletion/repair before custody, no false trusted
   projection, and ordinary certified recovery after release.
5. Same identity across differently spelled/configured roots remains excluded;
   distinct identities progress concurrently. The test observes actual file
   mutation, not just registry population or process counts.
6. A positive observer control sees both baseline writes to the same offset;
   restoring watcher-only behavior fails the exclusion assertion. Keep the
   seeded-prefix and inode assertions, plus real reservation and certification.
7. Last-caller expiry while waiting only for custody preserves the admitted
   job/source monitor and resumes it after release; last-caller expiry in an
   unavailable-route park still retires it. Failed acquisition neither loses
   the resident phase session nor takes the verifier-failure cleanup branch.
8. Stale admission inspection, unique-session close, broad phase cleanup and transfer:
   no prior observation authorizes deleting a newly repaired cache, and no
   old result/owner can delete a transferred file still owned by the successor.
   A unique old-session close leaves an independently opened successor intact;
   the custody-held broad sweep excludes the handed-off suspended session.
9. Kill only the gproc server with its supervisor held: the table and existing
   writer registration survive; attempted acquisition/monitoring fails closed.
   Resume supervision, prove a new server rearmed the holder monitor, then
   observe the pre-crash name monitor report actual holder death and a successor
   acquire normally. Unavailable monitor setup must not leave a parked job
   without a wake. Separately test the owner boundary implementing that rule.
10. In an isolated peer running gproc as a permanent application, kill its real
    table-owning supervisor while an independently spawned registered holder
    lives: assert node termination, not merely that ETS disappears. A temporary-
    application negative control demonstrates table recreation while the old
    holder survives. These are real runtime tests in
    `test/quod_foreign_registry_tests.erl`, not registry source-shape checks.

Incorporate this approved extension into the **one** exact-reference owner cut,
delete superseded recovery/admission mutation paths, update `quod_reg`'s key
table and the owner's lifecycle docs, run the complete sequential gates and
return the final tree for review before commit. Approval authorizes this scoped
implementation, not commit/deploy, a latency claim or closure of any other
performance/architecture gate.
