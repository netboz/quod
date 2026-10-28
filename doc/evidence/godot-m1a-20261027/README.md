# M1a qualification evidence

This directory records the M1a server implementation for [QUO-62](nimbalyst://QUO-62).
The existing ticket owns acceptance. Godot implementation remains M1b; additional
space GUI is M2 and entry/recursive physics is M3. No interactive desktop, XR or
physical Vive acceptance is claimed. M0 evidence remains unchanged.

The sole implementation worker is session `922c7c06-1acb-4c2b-9141-fccf4ab4c947`,
actual launcher model `openai-codex:gpt-6.1-sol`. High reasoning was requested;
the installed session API does not expose effective reasoning effort.
The branch is `worktree/pearl-stone`, HEAD
`d027f9f65bbce2f484f906c92bf07ebaa4669c38`, whose parent is the original
`f6c29fe925e666dd68ee7fa68c0e03f5d03391a2` base. Yan committed the M0 prerequisite
before this worker started. [Starting comparison](inputs/snapshot-comparison.json)
verifies all 778 preserved M0 entries and the tracked patch. No reset, main import,
integration branch, worker commit, cluster deployment or existing-network deletion
occurred. Every network exercised here uses disposable local storage.

## Qualification state

The [final clean campaign04](gates-04-result.json) passes all six gates in order:
native locked56, full EUnit4,252, full CT149, xref, Dialyzer and local production
release. Every true child exit is0; there is no timeout, unrun gate or source
change during the campaign. Exact commands, elapsed times and complete output
are in `logs/gates-04-*`. The [final provenance check](gates-04-consistency.json) passes. Founding
EUnit objects were reconstructed separately and byte-match their recorded hashes;
post-CT and production release objects remain separately identified. No rebuilt
object was copied into the qualified stage. The failed first evidence-reader
check and corrected passing check are both retained.

All three failed clean campaigns remain: [campaign01](gates-01-result.json)
completed EUnit with31 fixture failures; [campaign02](gates-02-result.json)
stopped at its remote-GUI fixture failure; [campaign03](gates-03-result.json)
stopped at signed savepoints with scope expiry. Each records true exits,
unchanged frozen source and explicitly unrun later gates. [Development notes](development-notes.md)
retain their diagnoses and all intermediate attempts. Assertions, workloads,
caller deadlines and gate timeouts were not weakened.

[Campaign runner](gate-campaign.py) froze1,426 authored inputs and copied the
exact1,094 M0-qualified dependency entries into a new empty stage, with no
compiled input. The [frozen input](inputs/gates-04-source-manifest.json) and
[compiled manifest](inputs/gates-04-compiled-manifest.json) separate1,091 authored
source/resource/symlink entries,3 generated lexer/parser sources,9 derived Rebar
indexes and2,053 remaining compiled outputs across24 dependency apps. Generated
dependency inputs did not change. Grammar hashes and parser annotations remain
separate. The worktree's older ignored dependency cache is not an input; the
lockfile stack remains Cowboy2.19.0/Cowlib2.21.0/Ranch2.3.0.

[Actual server toolchain](logs/server-toolchain-01.log): Rust/Cargo1.90.0,
rebar3.26.0, OTP28.5.0.2/ERTS16.4.0.2. Builder identity
`sha256:12c1389ee346993026ea83248037af7629f344eb2eebf09a6917ca0d10900e55`
is a retained local image ID, not a published repository digest. The production
HTTPS test client uses [builder Node20.19.2](logs/production-client-toolchain-01.log);
[host Node26.10.0](logs/client-toolchain-01.log) runs the browser tests/build.
Installed browser dependency versions match unchanged locks; that audit is not
claimed as a complete npm source manifest or a clean npm install.

## Signed production journey

Campaign04's `m1a_seven_foundations_test_` journey passes in174.798s inside
full EUnit4,252 (zero failures). Its [readable receipt](founding-receipt.md) and
[canonical receipt](gates-04-founding.json) contain actual root/network identity,
six exact catalogue anchors, ordered source hashes, all eleven compiled
predicate-module profiles, two U/A/S0 result sets and public signed operation
identifiers/digests. These are real disposable histories, not hand-filled slots.
The earlier [focused journey23](logs/focused-foundations-23.json) passed in176.757
seconds; its receipts and all earlier attempts remain preserved. The complete campaign04 result supplies final clean qualification.

The count is seven shared foundations: root plus node, agent, GUI, controllers,
space and user. The enrolled node's own history, two human histories and a separate
unrelated agent history bring the total to eleven. A and S0 are instances in each
selected account history, not extra catalogue entries. AClass/UClass are shared
class anchors; personal A and human U are separate instances and keys.

Root creation, node enrollment, source/module preparation and registration use
the existing governed owners. Signup first creates U and retains the original
allocation/hosting intention. Explicit read-only custody preparation then returns
the exact A key and executor-signed receipt. One existing atomic setup transition
assigns A, constructs parentless U-owned S0, places the existing A during the shared
constructor part, stores exact completion/results/pins and consumes the signup
receipt. There is no setup reaction replay or new executor. Empty S0 has no required
floor, sky, terrain, physics or lobby subclass. Its valid world view is empty and
nonphysical; a denied/mismatched dependency returns unavailable.

[Offline public-identity verification](gates-04-public-identity.json)
verifies both immutable custody signatures using the compiled production parser,
canonical codec and Ed25519 verifier against the enrolled node public key. It also
refuses an altered message. It reads no vault or private key and performs no write
to account state. The [verification command](logs/public-receipt-06.json) and
[script](verify-public-receipt.escript) are retained.

The [HTTPS receipt](gates-04-founding.json.https.json),
[endpoint/trust output](gates-04-founding.json.trust.json) and
[public CA](gates-04-founding.json.ca.pem) record real production
client signing and TLS/hostname verification. Save and Reset each commit through
U instruction to A execution. A fresh session recovers both original results with
zero recovery writes and without the originating device's journal. The endpoint
is disposable and stops with its fixture; the CA is public evidence, not a service
to deploy. M0's unchanged Godot crypto/export qualification is reused only for
those independent contracts.

## Refusal, ownership and repeated work

The real signed seams exercise two unrelated humans, their distinct personal
agents, an independent unrelated agent, public complete-source readers and wrong
history anchors. Raw/source/lens reads and writes of account state, signup receipts,
U-to-A instructions, preferences and HUD state refuse. Root excludes the user
foundation as well as itself from public complete source. Public GUI/controller/
space authored state remains byte-identical after private operations; ledger
control heights may advance for atomic read participants. An owner-revocation
while subscribed withdraws the retained view. Foreign source-wrapper withdrawal
and Root-denied local inspection also refuse, rather than returning valid empty
source; [inspection-owners02](logs/inspection-owners-02.json) passes all four cases.

Custody tests [16 tests](logs/custody-receipt-01.json) and
[26 custody/constructor tests](logs/custody-and-parts-01.json) preserve existing
vault obligations and verify payload tampering, executor/history isolation,
verification without a live vault, ordinary empty creation, selected foreign
storage with its resident, and rollback after inherited constructor failure.
Imported initial occupants from another storage history explicitly refuse with
`initial_occupants_require_local_storage`: the native continuation context does
not cross foreign ask re-entry. Ordinary foreign storage and subsequent explicit
foreign placement retain their existing paths. No runtime construction-context
extension or staged self-grant is introduced.

Setup additionally injects a final foreign acknowledgement failure after local
assignment/S0/admission has been staged; all local effects unwind and the original
receipt remains. Missing/mismatched pins and withdrawn committed create/entry/
admission grants refuse before setup completion. Typed defaults, stale revision,
invented operation, invalid type/range, denied principal and cancelled unsent
drafts are covered. Existing deferred-question tests remain active.

Repeated work is observed through actual owners, not latency alone. The passing
journey asserts zero traced projection creation/read/replay, ledger fold/read/
snapshot and file/DETS write/sync calls during three unchanged renewals of each
HUD/operation view (and three more operation renewals after a real update).
Outcome/setup reads run three times per account with zero ledger replay/open,
generation or persistence calls. After vault, runtime, Prolog and outcome-owner
restart, three readiness/preparation reads per account yield zero traced I/O and
no increment in runtime reconciles. Identity generation/constructor calls are
zero across recovery. A real new offered Reset after restart signs with the
original vault key, increments the saved revision and persists. These bounded
assertions are in `m1a_renew`, `m1a_setup`, `m1a_restart_accounts` and the existing
trace helpers; they do not establish a production-wide performance bound.

## Review, retirement and limits

Yan's explicit Claude request was fulfilled by one read-only Fable session
`a2cdb043-2e69-4b70-8f0e-2362b74b65da`. The [full report](fable-review.md) and
[independent dispositions](checked-fable-review.md) are retained. It reviewed the
immutable review01 tree; it neither ran tests nor approved later changes. The
arbitrary-key setup finding was independently reproduced and corrected through
the existing custody bridge. Subsequent source/privacy and fixture corrections
are independently qualified. This review authorization is consumed.

Eighteen replaced Prolog sources are relocated byte-for-byte from HEAD to
`outdated/ontologies/prolog`, outside packaged/bootstrap/loading paths. Their
2,932 lines are archive relocation, not code reduction. There is no Erlang ontology
archive. [Final source accounting](final-source-03-line-accounting.json) separates active
Prolog, runtime growth for demonstrated hash-loading/custody gaps, client changes,
tests and derived browser assets. Active Prolog is nine physical/fifteen
nonblank non-comment lines smaller; runtime grows 108 physical lines and authored
client code grows 8, for net active production growth 107 physical lines. That
growth implements the demonstrated source/custody gaps and private onboarding.
Erlang tests grow 758 physical lines and Prolog fixtures grow 18. Rebuilt assets
are separate: 198 fewer files and 466,819 fewer bytes; minified line counts are
not a code-reduction measure. Optional physics, terrain, material, naming,
licence and physical-lobby machinery remains for its owning milestones. The
physical fixtures use a test-only preset through normal governed creation;
the production legacy provisioning path is retired.

All failed/interrupted/stale-build attempts remain under their original labels;
[development notes](development-notes.md) distinguish their causes and invalid
evidence. Shared logs redact random disposable private-key-bearing binary values;
raw originals are retained in restricted external directories recorded by the
redaction manifests and excluded from source snapshots. No real network key,
private seed, unlock file or raw credential is a public evidence artifact.

Completed S0's construction-only policy does not yet authorize later instance
admission/entry. M2/M3 must author and qualify that policy. Godot identity/unlock,
generic keyboard/mouse GUI, client subscription/cancellation behavior and black
interior presentation remain M1b. Full M1 acceptance stays open. The tracker
session-link API reports linked with `linkedCount: 0`; visible UI attribution is
not claimed. The coordinator verifies the final external snapshot before issuing
M1b. Yan subsequently authorized overnight completion of QUO-62 and potentially
the next ticket with Sol xhigh, after the required coordinator verification.
No commit, deployment or additional Claude review is authorized.

The [testing-cost observations](testing-cost-observations.json) retain existing
campaign02 CT timings. [Campaign04 EUnit timings](gates-04-eunit-timings.json)
record3,642 timed cases without assigning zero to omitted submillisecond cases.
These are single-run observations, not CPU/wait diagnoses or latency distributions.
The necessary scope-owner correction reuses unchanged local savepoints; the
[bounded before/after comparison](inputs/remote-savepoints-cost-comparison.json)
records the same1,200-step signed case falling from29.515s with scope expiry to
2.930s completed. Its workload and deadlines are unchanged. The correction passes
75 focused tests, all45 affected ask cases and the complete campaign04. Its
new regression observes zero controller requests for3,075 unchanged pairs and
preserves foreign rollback/re-entry invalidation. The existing scope owner retains
the reuse token; the controller remains authoritative. No polling or second owner
is added. Temporary diagnostic source is archived as evidence and removed from
the live/build test path.

Tracker publication limitation: the [body-write audit](inputs/tracker-body-write-audit.json)
records definitive nested `collaborativeBodyStored:false` responses despite
outer `isError:false`. The item fields and local snapshots were saved; the final
body-only directed retry also failed. The local item is in-review/44% with4/9
checks; shared-body publication is not confirmed. Local tracker reads do not prove
collaborators received those bodies. The installed app is not rebuilt/restarted
and no database/token workaround is used. All original errors are retained.
