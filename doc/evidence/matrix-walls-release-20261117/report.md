# Matrix walls: 0.7.294 by clean refound (2026-11-17)

Yan: commit, release, he tests on the cluster. All ledger data, user
ontologies, accounts and node keys of the compute fleet were replaced.

## Commits (worktree/pearl-stone)

- `49643e7c` feat: Matrix walls rain the real source of quod:space
- `896effdd` chore: bump Quod release version to 0.7.294

Gates on that tree: `../matrix-walls-20261116/` server-02 (eunit 4370/0, ct
150, xref, dialyzer) and client-05 (16 steps).

## Refound

1. Image `192.168.1.11:5000/quod:0.7.294` from `git archive HEAD`
   (`refound/fleet/image-head.txt`), pushed digest
   `sha256:7a9cbb735d7cb42b9c7f98f31c4d95dd270a80cdfa1683f783409c6b15cb3204`.
2. Rehearsal from empty genesis in an isolated container (`refound/rehearsal`):
   every founding phase exit 0, 38 icons; after a restart all eight
   ontologies run and `quod:space` holds the raining Matrix recipe.
   The operator module and its beam are 0.7.293's, unchanged.
3. Old root anchor `88A6C703…8F6F`. Job stopped; the eight host volumes
   deleted and recreated on the same hosts.
4. Founding deploy (one node, `bootstrap=true`, `cloud_node_count=0`), then
   every founding phase exit 0 (no out-of-memory this time); 38 icons,
   106039 bytes.
5. New root anchor `375B3F5E8E3421038898C14A0D2E63FE9011C3E5EAC245F9F068B8064FD479AC`.
   Join deploy `node_count=8`, `cloud_node_count=0`; eight healthy. Seven
   joiners admitted one at a time (`refound/fleet/admit-run.log`).
6. `refound/fleet/fleet-verify-03.log`, all eight nodes: the new anchor,
   committee 8, none syncing, seven system ontologies ready, none rejected,
   inside Eidolons `wireframe` and `matrix`, and the Matrix recipe rains.
   (`-01` read one node only and `-02` checked the wrong clause: my mistakes
   in the check, kept.)

## Client

Exported from the committed sources, installed to `~/Games/quod`
(`client-install01.json`, 227 files verified); the previous install is kept at
`~/Games/quod-before-matrix-20261117`. `https://quod-0.service.consul` serves
network `375B3F5E…`.

## For Yan, in the headset

Sign up again (new network). Enter a space, pie → Show as → Matrix. Letter
height is 100 mm; screen glow is off. Tell me the frame rate and the look.
