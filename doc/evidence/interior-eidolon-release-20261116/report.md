# Eidolons without styles: 0.7.293 by clean refound (2026-11-16)

Yan: "ok, please commit, refound and then redeploy". All ledger data, user
ontologies, accounts and node keys of the compute fleet were replaced.

## Commits (worktree/pearl-stone)

- `a9ef32de` feat: Show as changes only what I see; the inside is an Eidolon
- `7b5a4d8c` chore: bump Quod release version to 0.7.293

Gates before the commit: `../interior-eidolon-purpose-20261116/` server-04
(eunit 4369/0, ct, xref, dialyzer) and client-04 (16 steps).

## Refound

1. Image `192.168.1.11:5000/quod:0.7.293` from `git archive HEAD`
   (`fleet/image-head.txt`), digest
   `sha256:4a0a4a8e141689862f535af69299aa59d7f6280c19ff61df06a2052ee79b0239`.
2. Rehearsal from empty genesis in an isolated container. Attempt 1
   (`refound/rehearsal-01`) never started: my readiness probe ran `quod eval`
   while the node booted, and both ran the start script's first-boot copy of
   `vm.args`. Attempt 2 (`refound/rehearsal`) waited for that file first:
   every phase exit 0, 38 icons, root height 19 and seven system ontologies
   after a restart.
3. Old root anchor `D27F08F8…DA26` (`fleet/before-root-anchor.txt`). Job
   stopped; the eight compute host volumes deleted and recreated on the same
   hosts (`fleet/volume-*`).
4. **Cloud satellites not refounded.** `quod-cloud-1` (Hetzner) has been
   `down` in Nomad since 2026-11-16 12:42 and its SSH port does not answer.
   The cleanup job could not be placed and was purged so nothing runs
   unattended; its old ledgers `0` and `1` are still on that host. The fleet
   was deployed with `cloud_node_count=0`.
5. Founding deploy (one node, `bootstrap=true`), then the founding phases.
   The founder was **OOM-killed** (exit 137 at the 1024 MiB `memory_max`)
   while creating `quod:gui`: root had committed the creation, the node died
   before the checks and the listing. It restarted on its own. The operator
   gained `gui_resume/0` (same readiness, anchor and profile checks, then the
   listing, never a second creation); the module was loaded again (first load
   kept as `founding/load-01.*`). Every later phase exit 0; 38 icons,
   106039 bytes, read back.
6. New root anchor `88A6C70335657769EEF9A0A8FFB12970B2AA306C401C1C62516AE33BC9508F6F`.
   Join deploy with `node_count=8`; eight healthy, no restarts. Seven joiners
   admitted one at a time (`fleet/admissions.log`; its last line read the
   committee before propagation; every node reads 8).
7. `fleet/fleet-verify-01.log`, all eight nodes: the new anchor, root height
   72, seven system ontologies ready, none rejected, committee 8 (all
   validators), none syncing; `quod:space` lists the inside Eidolons
   `wireframe` and `matrix`, `quod:user` has `show_as/3`, `quod:gui` has the
   Default icon.

## Client

Exported from the committed client sources and installed to `~/Games/quod`
(`client-install01.json`, 226 files verified); the previous install is kept at
`~/Games/quod-before-eidolon-20261116`. `https://quod-0.service.consul` (the
client's saved endpoint) serves network `88A6C703…`, root height 72.

## Open

- **Cloud satellites**: Yan, 2026-11-16: the Hetzner VM is decommissioned
  for now; deploys use `cloud_node_count=0`.
- **Memory**: creating `quod:gui` from its genesis crossed 1024 MiB once. The
  supervisor's progress report logs the whole genesis (over 3 MB of text) at
  that moment. Joiners started without a restart. Raising `memory_max` is
  Yan's call; not changed.
