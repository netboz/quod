# Obsolete ledger cleanup — 2026-10-14

Yan explicitly requested deletion of the retained old ledgers and other ledger
backups after the 0.7.265 candidate deployment. This receipt supersedes the
retained-offline storage status in the [deployment receipt](../ontology-eidolons-20261014/deployment-265/README.md).

Deleted 232 dynamic host volumes across 29 retired Quod storage families,
including the eight volumes of the 2026-10-11 candidate generation. Nomad's
`mkdir` plugin deleted each exact volume ID without `-force`. All 232 directories
under `/var/lib/nomad/host_volumes/{ID}` were subsequently confirmed absent on
conrad (87), corin (87), and caton (58). No unregistered volume directories or
separate Quod ledger backups were found in the inspected storage-host roots.

The shared cloud mount also contained six unused ledger directories: `0`, `1`,
`arch172`, `arch201`, `arch203`, and `arch205`. Both running cloud owners' rendered
configuration and open descriptors used only `arch206`. After checking canonical
paths and current job/allocation references, those six directories were deleted;
only `arch206` remained. Total measured allocated disk space removed:
3,403,689,984 bytes (about 3.40 GB).

Before and during deletion, current job volume sources and actual live
allocation job snapshots were checked. The main and candidate job versions and
modify indexes stayed fixed. Deletions were recorded individually with exact
intent and exit results; no uncertain mutation was resubmitted. Existing build,
review, test, and failed-measurement evidence was preserved. This receipt contains
metadata only.

Final verification: 16 dynamic volumes remain, comprising eight main `arch206`
volumes and eight current candidate `refound-20261014-v7` volumes. Their physical
paths remain present. The main fleet has ten running owners (including its two
cloud owners), version 246 / index 826727; the candidate has eight running owners,
version 77 / index 857357. Tasks are running without failure and allocation health
is not marked unhealthy. The stable browser at https://192.168.1.10:30519 returns
HTTP 200. No deployment, refounding, restart, or production code change was needed.

The detailed deletion manifest is [deleted-volumes.tsv](deleted-volumes.tsv).
The cloud receipt is [cloud-deletion.json](cloud-deletion.json), and totals and
fleet checks are [SUMMARY.json](SUMMARY.json). Full local operational logs,
including the unsuccessful initial SSH/cloud inspection attempts, remain under
`_build/obsolete-storage-cleanup-20261014`. One cloud inspection returned exit 2
because an optional configuration pathname did not exist; its descriptor output
was retained, and the subsequent check of the actual configuration returned zero
before deletion.
