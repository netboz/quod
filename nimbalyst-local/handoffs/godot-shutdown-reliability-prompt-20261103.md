/planning-implement QUO-66

Use GPT-6 Astra (`openai-codex:gpt-6-astra`) with xhigh reasoning, selected in
the session launcher. Prompt text does not change the running model. Start a
fresh session attached to the EXISTING worktree below; do not create a new
worktree or copy the dirty tree.

## Objective and authority

Yan has chosen reliability/release as the next priority. This first checkpoint
owns the intermittent Godot client shutdown failure: establish its cause, fix
the responsible owner when demonstrated, and complete the affected software
acceptance. Continue necessary authorized work through implementation and
verification. A diagnosis document or a successful rerun alone is not a fix.
Prepare a concrete account of the remaining final-acceptance/cutover prerequisites
afterward. Deployment, old-network deletion and cutover are outside this first
checkpoint; they follow the existing M5 prerequisite checks.

Work only in `/home/yan/src/quod_worktrees/pearl-stone`, branch
`worktree/pearl-stone`. Last verified HEAD:
`293cf6115c0a6b18315eccdbb42cbca396f443d3`. On prompt preparation the index was
empty and the worktree contained extensive accepted/uncommitted work. Verify
current branch, HEAD, status and active sessions before editing; never reset,
stash away, overwrite or reinterpret those changes as disposable.

Read AGENTS.md first. Use the existing QUO-66 item and QUO-60 parent plan:
call work_radar, tracker_get and link this session to QUO-66. Adapt the invoked
planning-implement skill to the shared tracker; do not create a duplicate task,
frontmatter plan or synthetic fm:plan lookup. Set session tags/phase with
update_session_meta. Existing coordinator is
`ed9cd520-b2a4-4607-a8f5-ff99d08f3e46`; the previous implementation session is
`ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f`. Both were idle when this prompt was
prepared. This session becomes the sole writer only after checking current
activity. Do not launch parallel writers, reviewers or additional sessions.

Tracker bodies have repeatedly failed collaborative publication despite local
save success. Inspect nested results, preserve failures, and do not infer shared
publication from local tracker_get. Old to-do checkboxes are not evidence that
accepted M1/M2/M3 or Stage 2 work must be repeated. If worktree routing fails,
the existing parent-project caller is
`/home/yan/src/quod/nimbalyst-local/tools/tracker-call.mjs`; use your own session
UUID and the documented route, never another worker's identity. Do not fix the
editor, rebuild it or blindly retry failed body publication as a detour.

## Read the current evidence

Paths below are relative to this worktree:

1. `doc/multiwrite-architecture.md` and the relevant current client specifications.
2. `nimbalyst-local/handoffs/godot-client-retirement-diagnosis-250.md` — causal
   investigation and bounded capture design. Its old same-session assignment
   and historical source baseline are superseded by this new-session handoff;
   its process-identity, privacy, deadline and capture safeguards still apply.
3. `nimbalyst-local/handoffs/godot-client-retirement-result-250.md`, plus
   `doc/evidence/godot-client-retirement-20261101/README.md`, `result.json`,
   `retained-failures.md` and `release-gates.md`.
4. `nimbalyst-local/handoffs/godot-vr-reliability-result-20261103.md` and
   `doc/evidence/godot-vr-reliability-20261103/review-fixes01/result.json`.
5. `nimbalyst-local/review-packets/vr-reliability-remediation01/manifest.json`
   and `result.json`. Manifest SHA256:
   `37d7461f439f01d2988206a81650d94aeba8425313898eb8d583ce4283e58c32`.
6. `nimbalyst-local/handoffs/godot-attention-package-result-279.md` and its
   linked current package/journey evidence, then only the relevant earlier
   failure receipts. Do not treat historical appearance-package246 as current
   product source or recount every old archive/export/history.
7. `doc/evidence/godot-visibility-test-20261103/attempt-visual02-result.json`.

Known facts: appearance246's companion completed 117 behavior checks before
the original post-completion no-EOF guard failed. That did not establish whether
the direct native engine or only its wrapper/pipe writers remained alive.
Observation250 subsequently passed 117 initial plus 36 reopen checks, reaching
managed close awaits, Quit and _ExitTree with normal exits and EOF. The original
trigger did not recur, so no shutdown cause or fix was established.

The recent VR harness corrections are already implemented and verified. The
separately labeled review-fixes01 suite has 116 mixed checks/cases/tests, all five
qualification children and wrapper0; seven harmless pipe children exit0 with
both EOF. It fixes readiness reporting and pre-admission cutoff classification,
preserves the original bounds, and retains built offline artifacts. These
synthetic and pipe checks do not establish native application shutdown.
The original temporary archive/DLL were lost; the handoff discloses that loss.
Persistent packets preserve surviving evidence and new artifacts. Keep them.

Visual02 remains a failure: 236 stereo frames, SteamVR Visible, never Focused,
no supported controller profiles. Rendering-only and interaction-ready states
remain distinct. The later SteamVR crash has no established cause.

## Diagnose, correct and verify

Trace the current existing owners, starting at `client/godot/Main.cs`, the real
ExportChecks/journey caller, view/action/backup/XR/model completion, identity
store durability, SceneTree Quit/_ExitTree, native process exit, wrapper and
stdout/stderr lifetime. Identify what the saved evidence does and does not prove.
Distinguish a managed await, native engine hang, live wrapper and inherited pipe
writer. Do not infer the culprit from a missing EOF or a completion marker that
precedes CloseApplication.

Choose the smallest additional observation that distinguishes concrete causal
hypotheses. Reuse the existing retirement journey and shutdown_capture.py owners.
If saved evidence is insufficient, a new finite, separately labeled, current-source
desktop diagnostic with XR disabled is authorized. Bind its actual sources and
dependencies. Preserve the relevant original phase180/post-completion60/outer300
and cleanup60+10 bounds; preserve the VR harness's separate preparation180,
authentic expiry, participant1800/close60/outer2100 bounds if touched. Do not
conflate the two harnesses or extend deadlines to obtain success.

Minimal payload-free close-stage observations may surround the existing owners
without changing scheduling/authority or introducing readiness polling. At an
actual original cutoff, preserve the whole failure first and capture direct
engine identity/liveness separately from wrapper/reader state. Reuse the existing
bounded failure-only native capture only for an exact currently owned child,
under the safeguards in diagnosis250. No attach to stale PIDs, unrelated process
inspection, global ptrace change, debugger install/download or private memory dump.
If the engine has exited, investigate only its invocation's remaining writers.

No trigger means no causal proof. Do not repeat successful runs merely to collect
green exits. An additional run needs a new discriminating observation or a
causally justified correction and a separate label. Keep all failed runs intact.

Fix a demonstrated defect in its existing owner. Preserve Prolog authority,
atomic writes, authorization, persistence, original-result recovery, exact process
ownership and uncertain-write fences. No forced exit, swallowed error, guessed
cleanup reorder, speculative engine replacement, uncertain-operation replay or
second lifecycle owner. A concrete external dependency remedy outside this
checkpoint needs a reviewable diagnosis after unaffected work is complete.

For a correction, retain the failing real-owner regression, verify the corrected
behavior, then run the affected signed software journey and same-profile reopen
with original U/A/location/draft/outcome and no replay. Check true direct child
and wrapper exits, both EOF, retired readers/resources and the original bounds.
Qualify ordinary user-close and test-close paths when the change affects them.
Run the applicable clean sequential gates at the actual acceptance boundary;
reuse unaffected verified inputs instead of repeating blanket release campaigns.

## Completion and limits

This checkpoint is software-only: XR disabled, no SteamVR configuration or runtime
launch, hardware/display changes, host input/focus, live human test, headset
request or expiring user session. Use isolated existing software fixtures where
needed. No product-policy change, release deployment, cutover, data retirement,
deletion, commit or push. The previous requested Fable review is complete and
its findings addressed; it authorizes no additional review.

Keep binaries, full logs, receipts and reconstruction evidence in persistent
workspace locations, not solely /tmp. Reuse available existing dependencies;
respect actual filesystem permissions. Preserve profiles, keys, archives and
every failed label. Freeze only the exact new source/evidence delta with separate
before-copies and verify material reconstruction. Avoid another full-tree archive.

Finish with the demonstrated cause and fix, or the precise remaining causal gap;
actual test/child/wrapper exits and EOF; exact changed files and line delta;
retained failures; and which final acceptance/release/cutover prerequisites remain.
Update the existing checkpoint truthfully without closing broader M4/M5 or
claiming hardware acceptance. Do not stop at reviewing findings when an authorized
correction can be implemented. If a native/hardware boundary genuinely prevents
completion, finish independent software work and identify the concrete blocker.
Invoke AGENTS.md's stop notifier before ending.

For context only as needed, call get_session_summary with
sessionId=`24781f1a-c144-44b4-8f2a-83074305649c`. The files above are the primary
handoff; do not replay this long session or rebuild its already accepted work.
