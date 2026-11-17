# VR fixes release: 0.7.290 by clean refound (2026-11-14)

Yan asked to refound the network from clean ground. All ledger data, user
ontologies, accounts and node keys were replaced.

## Commits (worktree/pearl-stone)

- `ca819157` fix: readable VR surfaces, pad choice kept, leave to parent, fast pies
- `9ff8b66e` chore: bump to 0.7.290

## Gates

- Server, on the frozen tree (`tree-01.diff`): EUnit 4362/0, CT 150, xref 0,
  dialyzer 0 (`server-01-*.log`).
- Client run 01 stopped on `navigation`: a check counted `Contents cycle`
  labels, which are now written twice (front and back). The check counts the
  labelled occurrences instead. Run 02 (`tree-02.diff`) passes all 15 steps
  (`client-02-*`).

## Refound

1. Image `192.168.1.11:5000/quod:0.7.290` from `git archive HEAD`, digest
   `sha256:c4e3b421cfa36830e294b5f07327b1e7d9c587b181bb8a95ec1846b0ccc96b1d`.
2. Founding rehearsed twice from empty genesis in an isolated container
   (`refound/rehearsal-01`, `refound/rehearsal`). Rehearsal 1's node phase
   checked the node's hosting fact before enrollment had written it; the check
   moved to the catalogue step. Rehearsal 2: every phase exit 0, the same
   result after a restart.
3. Old root anchor `C21E011B…3F5E` (`fleet/before-root-anchor.txt`). Job
   stopped; the eight compute host volumes deleted and recreated on their
   hosts (`fleet/volume-*`); the guarded cloud job removed only the old `0`
   and `1` ledgers (`fleet/cloud-cleanup-task.log`).
4. Founding deploy (one node, `bootstrap=true`), then the founding phases with
   `refound/found.py fleet` and `quod_refound_operator`
   (`refound/founding/`): seven system ontologies founded and listed, node
   enrolled, the user class listed by the node actor's signed transaction
   (`committed`), 36 icons read back.
5. New root anchor
   **`D27F08F84BC33BAB4FDA358096ABF91CD2F38BD4D6A212CDE24F0A485366DA26`**.
   Join deploy with 8 compute and 2 cloud nodes, all healthy; seven compute
   joiners admitted one at a time (`fleet/admissions.log`).
6. `fleet/fleet-verify-01.log`, all ten nodes: the new anchor, root height 57,
   seven system ontologies ready, none rejected, committee 8 (8 validators,
   2 observers), none syncing, leave-to-parent and personal-pie icon rules
   present.

## Client

Exported by client gate run 02 and installed to `~/Games/quod`
(`client-install01.json`, 226 files verified); the previous install is kept at
`~/Games/quod-before-vrfixes-20261114`.

## For Yan

The network is new: choose **Trust this server** in the client's Options,
then **Sign in** with the key already on the device and **Create my account**. The first pies on the new network are the
timing measurement: their `QUOD_TRACE pie` lines land in Steam's
`console-linux.txt`, the node's spans in Tempo with the called goal names.
