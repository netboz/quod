# Corrected founding recipe: deployment 02

The tested frozen07 production tree and pinned 0.7.273 image are unchanged.
The first deployment's browser acceptance exposed an operator recipe error:
`deployment-01/refound/quod_fresh_systems.erl:12` founded every catalogue ontology
with only `quod_agent_predicates`. `quod:gui` also requires `quod_gui_predicates`,
as the real production-seam fixtures already specify. The immutable deployed
manifest confirms its absence. An undefined staging predicate therefore fails
before any native presentation. This is not an installed responder race: the
signed native-handler read succeeds, but no GUI preparation reaches the browser.

Evidence under `_build/world-library-20261016/deployment-01`:

- `browser-diagnosis-02/gui-module-profile.txt`: recorded deployed manifest.
- `browser-diagnosis-02/signed-read-diagnosis-02.json`: no pending operation,
  no questions/worlds, correct form, human capacity and installed actor handler.
- `form-reproduction-01/observation.json`: new ordinary opening after those
  terminal checks returns `fail`, and no native preparation is delivered.
- `acceptance-desktop-deployed-02/STOP.json`: original browser failure retained.

Correction scope is `_build/world-library-20261016/deployment-02`, frozen by
`script-manifest.json`; `correction.patch` compares the first recipe. The helper
selects the GUI profile explicitly, verifies each newly founded immutable
module manifest, and checks all profiles again at the final catalogue gate.
Every fleet probe verifies all 18 profiles on every node. No application source
or release label changes are involved, so the 12 passing frozen07 release gates
and the existing Fable06 production review remain applicable.

The new separately labelled campaign reuses the exact verified image digest.
It replaces only the candidate job, requiring current version 93/index 868831,
on fresh v11 volumes. Main job and ingress remain pinned and checked. User's
overnight authorization explicitly permits candidate ledger resets/deletion.
The v9 and failed-v10 volume families remain intact until full deployed browser
acceptance and a second eight-node fleet check pass. Purge then checks the exact
16 saved IDs/names, absent old running allocations, and current new volume
family. Every command retains full output and true exits; a failure stops its
campaign. No uncertain operation is automatically resubmitted.

The browser harness now records execute replies and input status values, which
were missing from the first failure capture. It uses the production root route
`https://192.168.1.10:30519/`. Its account remains synthetic and private key
material is never printed. Physical VR remains outside this headless check.

Validation before review: Python syntax compilation and Erlang helper `-Werror`
compilation passed. Deployment02 has not started. Review is consultative and
read-only; no tests/builds, edits, or memory changes are requested.
