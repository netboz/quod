# Candidate release 0.7.255

Image `192.168.1.11:5000/quod:0.7.255@sha256:d3adce8bb9d8bd46ce97d6c3ab65533c48ffee747d78f7c41cf56ac4bbbb6ca1` was built from the frozen, qualified source tree plus the
separate version-label commit `c348365764ab514587a6fb974d26d3b73d4f5122`. The image includes the preserved,
already deployed 0.7.254 ontology-source baseline, whose unrelated local edits
remain uncommitted. [Source provenance](image-source-manifest.json) records
all inputs; generated explorer files match the frozen UI/client build.

The image-only candidate job update used one checked-index submission.
Eight candidate allocations run 0.7.255 with the existing root anchor,
18 ready catalogue entries, zero rejected entries, completed enrollment and
stored, self-hosting node actors. The main `quod` job was unchanged.

The signed read-only smoke check verifies all 17 public ontology sources,
repeat reads, wrong-anchor/private-root refusal and denied policy invocation.
Source hashes match the pre-deploy snapshot and it performs zero ledger writes.
TLS certificate verification was disabled for the self-signed LAN endpoint,
as in the pre-deploy fixture; this checks application authentication and policy,
and is not a TLS verification test. No chair state was seeded or physical
host-failure injection performed.

[Full deployment logs](deployment-logs.tar.gz) retain build/push exits,
registry digest verification, the plan and single submission, deployment events,
fleet probes and signed application smoke results.

The first image campaign stopped with exit 1 at the registry HEAD check,
before build, push or job submission, while the configured servers were
unreachable. Its failure logs are retained. The separately labelled
`image-build-255-post-reboot-01` campaign ran after the user rebooted the
servers and restarted AdGuard. Read-only checks then confirmed the original
addresses, all eight candidate ontologies ready, and the original root intact.
Nomad reported two healthy voting servers and failure tolerance zero; Caton
was absent from server membership. Consul retained three voting servers.
The application release does not repair this separate infrastructure issue.

The single Nomad submission exited 0 and monitored all eight allocations to
a successful deployment. The subsequent watcher exited 1 because it expected
an `Evaluation ID:` line absent from the actual CLI output. The original
campaign, script and failure remain in the archive. A separately labelled,
read-only `deployment-verify-255-01` campaign qualified the exact deployment
ID, job version, image configuration, eight healthy allocations, recovered
ontology state and signed client checks. No job or uncertain action was
resubmitted.
