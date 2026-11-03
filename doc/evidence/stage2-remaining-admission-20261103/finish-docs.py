from pathlib import Path
import shutil
R=Path('/home/yan/src/quod_worktrees/pearl-stone');E=Path(__file__).resolve().parent
for n in ['RESULTS.md','OWNER-VERIFICATION.md']:
 d=E/'revisions/consolidated01-before-workers'/n
 if not d.exists():shutil.copy2(E/n,d)
p=E/'RESULTS.md';s=p.read_text().replace('proposal — consolidated01','proposal — consolidated02').replace('inputs/apply-check03.json','inputs/apply-check04.json').replace('inputs/production-unchanged-final.json','inputs/production-unchanged-final02.json').replace('+457/−591, net−134 across39 paths','+483/−609, net−126 across42 paths').replace('+505/−273','+578/−306').replace('specs:+35/−9','specs:+43/−9').replace('inputs/proposal-delta.json','inputs/proposal-delta02.json')
a=s.index('`proposal-production02` compiles');b=s.index('the VM code path.',a)+len('the VM code path.')
s=s[:a]+'''`proposal-production03` compiles the complete affected production overlay
without TEST or an export_all compiler option, true exit0/bothEOF. The unchanged
Erlog ETS module contains its own existing export_all attribute; its warning is
literal. The compiler includes the isolated proposed Erlog library root, and
RESOLVED_HEADERS records the exact proposed header used by Quod local_prove.
`proposal-compile12` compiles all affected tests and production with TEST/export_all;
all modules except `quod_prolog` pass. That module failed because an unanchored
artifact-generator replacement also altered the test wrapper. The generator
was corrected at the existing function definition; `proposal-compile13` and
`proposal-production04` compile only that corrected module in test/production
modes, both exit0/bothEOF. Exact source-hash coverage for all62 production modules
and119 test-mode modules is recorded in `inputs/proposal-compile-coverage02.json`;
the failed aggregate receipt is not relabeled passing. Every compile asserts
identical preprocessed `est` record forms in Quod and Erlog. No emitted beam
directory is on the VM code path.''' + s[b:]
s=s.replace('Earlier compile receipts remain literal:01/02', 'Earlier compile receipts remain literal:11 failed to access the Docker socket\ninside the sandbox (no compiler ran); the separately labeled12 used the approved\ncompile-only Docker access. This was a local permission failure, not an automatic\napproval rejection. Test10/production02 passed the preceding proposal.\n01/02')
s=s.replace('runtime evidence. Worker pool defaults64 in `quod_prolog`/schema are an additional\nlive configured population policy reported to the parent; this packet does not\nchange them or mislabel them as encoding. Original scope is not declared fully\ncomplete.', '''runtime evidence. The consolidated02 proposal retires proof/scope worker default64
through the existing engine, config and schema owners, accepting `unlimited`
while preserving positive finite overrides, active/pending scope accounting,
retained completion waiters, monitors, custody and original deadlines. Proposed
coverage includes65 concurrently held real proof workers and release/new-work,
explicit finite configuration, finite busy/release/caller-loss tests, and the
actual scope-capacity helper with finite and unlimited settings. These compiled
tests have not executed. No new allocator, registry or numeric default was added.
Namespace test callers now use the existing shared ETS-name constructor instead
of reconstructing raw names. Original scope is not declared fully complete.''')
s+='''

## Exact freeze

The consolidated02 packet is
[stage2-remaining-admission-proposal01](../../../nimbalyst-local/review-packets/stage2-remaining-admission-proposal01/result.json).
Its result binds the three patches, saved preimages/afterimages, literal failed
attempts, compiler input snapshots, parent review/preprocessor corrections,
current plan/handoff and prior immutable packet hashes. No fixture stores,
credentials, generated native profiles/certificates or emitted beams are included.
A passing compile or applicability check is not authorization to apply the patch
and is not runtime acceptance. No feature inventory delivery entry is changed.
'''
p.write_text(s)
p=E/'OWNER-VERIFICATION.md';s=p.read_text();anchor='| Namespace lifecycle/directory/client/scope/storage |';i=s.index(anchor);s=s[:i]+'''| Proof/scope engine, application config and schema | Retire built-in worker population64 through existing `unlimited` allowance; preserve positive finite options and original active/pending/waiter accounting. No new allocator or deadline change. | Proposed65 live real proof workers acknowledge the existing barrier, release through the owner and admit subsequent work; finite configuration and existing busy/release/caller-loss/deadline tests remain. Scope helper verifies finite active+pending refusal and unlimited admission. All compile-only, no runtime claim. |
'''+s[i:];s=s.replace('uint16 mirrors. Optional heap accounting and remaining configured worker-pool\npolicy are not silently included.', 'uint16 mirrors. Namespace ETS-name fixture callers use the existing shared\nconstructor. Worker allowance changes are explicitly included in consolidated02;\noptional heap accounting remains separate.')
p.write_text(s)
p=R/'nimbalyst-local/handoffs/stage2-d5-reconciliation-20261103.md';s=p.read_text();s=s.replace('### Remaining-owner preparation — consolidated01, unapplied','### Remaining-owner preparation — consolidated02, unapplied').replace('combined proposed repository production+457/−591,\nnet−134','combined proposed repository production+483/−609,\nnet−126').replace('renewals under aggregate30s remain failed. Live configured proof/scope worker\nmaxima64 were reported to parent and are not falsely called encoding constraints.', 'renewals under aggregate30s remain failed. Consolidated02 includes unlimited\nproof/scope worker defaults through existing engine/config/schema, retaining\nfinite options, monitors, custody and deadlines. Real65-worker/release and finite\nconfiguration fixtures compile; no proposed tests have executed.')
s+='''

Final proposal evidence: production03 passes; test12 retains the generator's
test-wrapper head-mismatch failure, all other modules compile. Corrected module
passes test13 and production04; source-hash coverage binds62 production and119
test-mode module results. Sandbox Docker-access failure11 remains literal.
Read-only applicability04 passes all three patches; production-unchanged-final02
confirms no source/pin changes. Combined proposed tests+578/−306; dependency
production+23/−51 separately. Exact packet:
`nimbalyst-local/review-packets/stage2-remaining-admission-proposal01/result.json`.
This is proposal preparation only; broader application, dependency delivery and
storage-format cutover remain unapproved, and original signed acceptance is open.
''';p.write_text(s)
p=R/'nimbalyst-local/plans/space-conceptual-architecture-review.md';s=p.read_text().replace('Remaining-owner proposal `consolidated01`','Remaining-owner proposal `consolidated02`').replace('+457/−591 (net−134), with pinned-dependency', '+483/−609 (net−126), with pinned-dependency').replace('aggregate30s signed acceptance remain open. Worker-pool defaults64 remain a live\nconfigured policy reported to the parent; no all-limits-removed claim is made.', 'aggregate30s signed acceptance remain open. The proposal includes unlimited\nproof/scope worker defaults through existing config/schema/engine owners, with\nfinite settings and deadlines preserved; no all-limits-removed claim is made.')
s+='''

Consolidated02 evidence closes proposal preparation only: current production
unchanged0/0; all three exact patches pass applicability04. Production03 and
corrected module production04 pass; test12's wrapper-generation failure remains
literal, corrected module test13 passes, and exact hash coverage binds every
compiled module. Proposed runtime tests are unexecuted. Final packet:
[proposal01 freeze](../review-packets/stage2-remaining-admission-proposal01/result.json).
No Stage2 checkbox or original aggregate30s acceptance is closed by compilation.
''';p.write_text(s)
print('DOCS_UPDATED')
