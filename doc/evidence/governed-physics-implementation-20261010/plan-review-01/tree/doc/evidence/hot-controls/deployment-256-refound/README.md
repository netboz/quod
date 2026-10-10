# Candidate 0.7.256 deployment and ledger refound

Yan explicitly authorized deploying release 0.7.256 and refounding the ledgers.
The operation targeted only Nomad job
`quod-finality-candidate-v6-20260926`, which serves the current candidate
lobby/browser. The separate `quod` job remained at version 246 and
`JobModifyIndex` 826727.

## Immutable release

- Source commit: `ad46c75aa5f56650d2a6c68086867cadd2d9667f`
- Image:
  `192.168.1.11:5000/quod:0.7.256@sha256:7cd0ab4b51404f9d013a857d2e3124d532ccfedb7857bb3be5a65777bf48610e`
- Source manifest SHA-256:
  `53748936a7bbb4e09281c386c58621a84404495ebb048b197c2127c79828bdf9`
- The production release build passed. The registry digest and the embedded
  explorer assets match the frozen committed inputs.

## Destructive refound

The candidate moved from the eight-volume
`quod-finality-candidate-v6-20260926-refound-20261007-v2` family to eight new,
empty, ready volumes in
`quod-finality-candidate-v6-20260926-refound-20261010-v3`. A checked-index
bootstrap update first started one fresh founder. Only after that founder was
running and every old allocation had stopped were all eight old volumes
deleted. The final volume inventory contains all eight new volumes and no
member of the old family.

The fresh root anchor is
`3F88D70B7714366EE11D38764231DD2F6EE8AAFC58EB8C0559146543E5280F26`.
Using the existing governed root actions, `create_ontology`, ordinary
transactions, node enrollment and system-ontology catalogue, the refound
created and published all 18 system ontologies. The fresh lobby anchor is
`7B0DA9C7D3385065AD99A51B9987118FFA4C6DB837DA7211A924995206AD565A`.
No alternate domain engine or special lobby path was introduced.

## Runtime verification

Nomad deployment `82d460e6-edcc-49ee-89bc-d9fb3ab77da3` completed
successfully at candidate job version 57: eight desired, eight placed, eight
healthy and zero unhealthy. A production-owner probe on every allocation
reported:

- release 0.7.256 and the exact fresh root anchor;
- root state ready, with committed height equal to applied height 61;
- 18 catalogue entries, zero rejected entries and no unready ontology;
- completed node enrollment, a stored principal pointer and committed
  self-hosting;
- zero task restarts.

A fresh key-bound signup principal then exercised the real signed client
protocol at `https://192.168.1.10:31609`. It read all 17 public ontology
sources, repeated an unchanged read, and observed denial for a wrong anchor,
the private root and an unauthorized policy invocation. It submitted no ledger
writes. TLS verification was disabled only for this self-signed LAN endpoint;
this is an application authentication and policy check, not a certificate
verification test.

## Retained failures

The archive preserves every failed observation:

- The first host-volume create attempt supplied an unsupported CLI `-type`
  flag. It stopped before creating any volume. A separately labelled corrected
  attempt created the eight volumes.
- An optional verbose catalogue dump reached the live node but Erlang JSON
  encoding rejected an internal descriptor term with `{invalid_byte,98}`.
  The stricter final gate immediately afterwards encoded only asserted fields
  and passed with 18 ready ontologies.
- The first signed smoke attempt stopped at Node's self-signed certificate
  check and was classified outcome-unknown. That process and its ephemeral key
  ended; its request was not resubmitted. A separately labelled run used a new
  ephemeral identity and the documented LAN-only TLS bypass, then passed.

`deployment-logs.tar.gz` contains the exact build/push receipts, checked-index
plans and submissions, volume creation/deletion receipts, refound scripts and
outputs, ontology anchors, the failed diagnostics, final gates, fleet probe,
signed client probes and final seal. The adjacent JSON files expose the key
results without unpacking the archive; `manifest.json` hashes every committed
evidence file.

This deployment completes the release/failure-handling follow-up for hot
controls. It does not establish physical player movement in the newly founded
lobby and does not replace the pending Vive collision-locomotion acceptance.
Those remain tracked by the player-movement and existing-world integration
items.
