# Failure reasons: 0.7.295 by clean refound (2026-11-18)

Source tree: `2c1cc47213b5cd06770802825e196028e22ec30c` on `master`,
matching `origin/master` when checked. `rebar.config` and `rebar.lock` pin
erlog `5dad08cdc95f5100f8885caa65038b0c6ee832f9`.
The published-pin qualification in
`doc/evidence/failure-reasons-implementation-20261118/pinned/report.md`
passed 4,370 EUnit tests, 150 Common Test cases, xref, Dialyzer and the final
scene checks. Release label 0.7.295 was committed separately at `b37b3426`;
the registry had no 0.7.295 tag before this build.

The image was built from `git archive HEAD` (not a dirty checkout) and pushed
as `192.168.1.11:5000/quod:0.7.295`, registry digest
`sha256:bc71a5a0c3e6c39634722814a8a8af1c4c01e2458a696c089ee6558081d79e93`.
The full build and push exits are in `refound/fleet/results.jsonl` and their
labelled logs. The host had 20 GiB available memory and 273 GiB available disk
before building.

The isolated empty-genesis rehearsal used the committed image. All founding
phases passed, in order: load, root, node, agent, gui, controllers, names,
space, user, user-sign, user-submit, catalogue, gui-assets. After a container
restart, the existing fleet verifier found seven system ontologies ready, no
rejections, one validator, no syncing, and the Matrix recipe. The rehearsal
anchor was `46996BD2776CDF621F529059C561C54A59CC392A74C1E4C53152C2BBD739D941`.
Each one-shot phase has its intent, exit and result under `refound/rehearsal/`.
The first start attempt failed before launching because the script lacks an
executable bit; `rehearsal-start-02.log` records the Bash invocation that
worked. The rehearsal container and its generated local data were removed.

The live Nomad job was still eight healthy `quod-node` allocations on 0.7.294
at the preflight. Its root anchor was
`375B3F5E8E3421038898C14A0D2E63FE9011C3E5EAC245F9F068B8064FD479AC`.
The exact eight current host-volume IDs and node assignments are saved in
`refound/fleet/before-volume-ids.log`. No cloud-class Nomad client was ready;
the job's desired cloud allocation count was zero.

## Live refound

Automatic approval review initially rejected `nomad job stop quod` as a
service-disrupting mutation because it did not treat the previous session's
request as explicit authorization in this turn. Yan then explicitly approved
stopping the eight-node job, erasing its eight host volumes and deploying
0.7.295 by clean refound. The job version, image and exact eight volume IDs
were rechecked before the successful stop. The first delete attempt specified
no volume type, so Nomad looked for a CSI volume and changed nothing; its
failed exit is retained as `volume-delete-0.log`. The corrected `-type=host`
commands deleted exactly the recorded eight IDs, then eight new volumes were
created on the same compute nodes. All eight new volumes were ready.

The bootstrap Nomad plan proposed one founder and zero cloud nodes; the
`-check-index=952004` submission succeeded. The plan's exit 1 denotes a job
diff, not a scheduling failure; its dry run allocated every task. The founder
allocation completed the same 13 one-shot phases as the rehearsal, with
seven system ontologies in the catalogue and 38 GUI assets. Its new root
anchor is `8A9671E47F4CC9D3642EF5C614699A97455255456DD2A303D5A7EF5C6A977814`.
The join plan proposed seven new allocations and kept the founder; the
`-check-index=952273` submission reached eight healthy nodes. That plan also
exited 1 because it contained a diff, with all tasks allocated.

The seven root admission calls each returned `admitted`. The admission script
printed committee size 7 for the final admission and still exited zero:
its comparison used a lagging *before* sample. The source of
`scripts/release/refound/admit.sh` now waits for the absolute expected size
at each index. The live admission was **not** resubmitted. Independent
verification on each of the eight running allocations found the new anchor,
committee size 8, validator role, no syncing, seven ready system ontologies,
no rejected entries and the expected GUI and Matrix facts. See
`refound/fleet/fleet-verify-results.json` and the eight per-node logs. The
founder allocation was replaced during the join-mode deployment and recovered
the same anchor and committee correctly. Nomad's final deployment is
successful with eight healthy nodes (`refound/fleet/final-job-status.log`).
The final job specification points all eight compute tasks at 0.7.295
(`refound/fleet/final-job-image.log`).

`https://quod-0.service.consul/` answered HTTP 200. Its public explorer
summary reports the new root genesis, committee size 8, validator role and
no syncing (`refound/fleet/client-endpoint.log`). The installed Godot client
does not need reinstall for this server-side failure-result change.

No cloud-class Nomad client was ready and cloud allocation count remained
zero. Before future cloud satellites are enabled, inspect their static
`quod-node-cloud` storage for an old network identity and clear stale
allocation subdirectories under the appropriate separate authority.
