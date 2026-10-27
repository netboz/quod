# Read-only cutover resource boundary

Observed 2026-10-27 through the existing Nomad API and hostname-verified HTTPS. This is inventory, not a deployment or deletion. M5 refreshes every identity and refuses a changed boundary until reconciled. The authorization is fresh Godot-first replacement of this candidate network, not a wildcard purge of similarly named resources.

Current root: `quod:root`, genesis `664B1CC1D63CFBF9FDAF68DF5E11836B4999AE53480EC33F7EE6C3115D41DF2A`; catalogue height 69 with 18 entries. Root adds one shared identity (19 total); eight enrolled node identities are counted separately (27 before users). The prior campaign05 root `47B57BC0D3F69E93C3DCCE9B9BEDD61756F2558D89BB3291D41C0576A675B71B` is historical evidence, not the currently routed root.

Namespace `default`; job `quod-finality-candidate-v6-20260926`; job version 114, modify index 910806. Home group `quod-node` has eight running allocations; `quod-cloud` has count zero. Active image: `192.168.1.11:5000/quod:0.7.275-movement-f6c29fe9-4dcbd485-20261027-m01@sha256:358acc3197c9d24edafe4f562a909ce78de38eed462ba430372f848457b81dff`. In-container durable root `/quod/data`, identities below `/quod/data/identity`, ontology histories under their existing exact namespace/hash layout. The current cloud volume source is declared but has no running allocation; do not infer any cloud path is in the deletion set.

| Allocation index | Exact allocation | Node identity/name | Host volume ID | Host path |
| --- | --- | --- | --- | --- |
| 0 | `e9a938d4-300c-a5b2-b225-17e08b92c477` | `3e390ebd-5557-a67c-b64e-07b728144297` / conrad | `a1c66c8d-c09d-9e46-955d-2f94b417dce8` | `/var/lib/nomad/host_volumes/a1c66c8d-c09d-9e46-955d-2f94b417dce8` |
| 1 | `91f210a1-97cd-e1c2-6160-278f7880722d` | `75b1a578-a5f6-e5b9-70cb-9e3aca6baac0` / corin | `5e959241-4d87-1cbe-1a38-941fb8baa255` | `/var/lib/nomad/host_volumes/5e959241-4d87-1cbe-1a38-941fb8baa255` |
| 2 | `ceafd1da-04f6-d9cd-d93b-a4ccb29b92dd` | `c8f9edef-853b-fc43-e3fb-d884418f7061` / caton | `aedc1302-cd53-aabf-a8a0-52e55936cea1` | `/var/lib/nomad/host_volumes/aedc1302-cd53-aabf-a8a0-52e55936cea1` |
| 3 | `1414a6e2-5865-f3b3-2880-c1695e302e2e` | `3e390ebd-5557-a67c-b64e-07b728144297` / conrad | `7d4f2b5a-c54f-a6ce-91f4-9e27a70cb0b0` | `/var/lib/nomad/host_volumes/7d4f2b5a-c54f-a6ce-91f4-9e27a70cb0b0` |
| 4 | `ed749c6f-1aa3-8e83-9836-396155d97a56` | `75b1a578-a5f6-e5b9-70cb-9e3aca6baac0` / corin | `5ce79279-7b86-4d54-ded2-435f5c95aacf` | `/var/lib/nomad/host_volumes/5ce79279-7b86-4d54-ded2-435f5c95aacf` |
| 5 | `0fb69094-c4b5-5de4-6fb8-f29d483d53c4` | `c8f9edef-853b-fc43-e3fb-d884418f7061` / caton | `0016305f-66c5-1840-7062-13d22ff073ea` | `/var/lib/nomad/host_volumes/0016305f-66c5-1840-7062-13d22ff073ea` |
| 6 | `781f848d-2ac6-b309-b7b1-460c6691c5ae` | `3e390ebd-5557-a67c-b64e-07b728144297` / conrad | `930f80ef-2703-3461-fd11-edc71c7fb3b5` | `/var/lib/nomad/host_volumes/930f80ef-2703-3461-fd11-edc71c7fb3b5` |
| 7 | `b0f94038-4feb-fe47-737a-4184e2ba5e23` | `75b1a578-a5f6-e5b9-70cb-9e3aca6baac0` / corin | `50cbd7f4-6468-2815-4432-6e4fb93d8fca` | `/var/lib/nomad/host_volumes/50cbd7f4-6468-2815-4432-6e4fb93d8fca` |

The eight exact volume IDs above are the current old-network state candidates. Their contents include node identity/vault custody, not only ledger files. M5 must validate replacement identity, enrollment and endpoint/trust output before irreversible removal. Refresh allocation/claim-to-volume mapping; a name fragment alone is insufficient. Do not delete old histories before replacement routing is verified.

| Ingress job / group | Allocation | Listener | Exact Consul backend selector |
| --- | --- | --- | --- |
| `quod27-client-30519` / `ingress` | `f3de277a-f783-08a3-d918-6075bf2aec6f` | `--entrypoints.client.address=192.168.1.10:30519` | `candidate-quod-node-0.quod-finality-candidate-v6-20260926-client` |
| `quod-candidate-browser-ingress` / `ingress` | `4c8027e9-9fb2-b83b-4234-11258041ed7c` | `--entrypoints.client.address=192.168.1.10:31609` | `candidate-quod-node-0.quod-finality-candidate-v6-20260926-client` |

Both listeners currently select candidate `quod-node[0]`, exact allocation `e9a938d4-300c-a5b2-b225-17e08b92c477`. The frontend uses TLS passthrough and an exact-single-backend rule; missing/ambiguous selection withdraws the route. Preserve these ingress resources; M5 updates/validates the replacement route and certificate/network binding before removing the former backend state. An open browser origin does not require a browser compatibility engine.

The public gateway certificate was read from `/quod/data/identity/client_tls.crt` via its allocation owner. Verified HTTPS fetched `/api/ontologies/system`; its public pins are in [catalogue.json](catalogue.json), with full receipt in [catalogue-02.log](logs/catalogue-02.log). No private key, account or token was read.

## Explicitly outside removal scope

- Main job `quod` and its root `9F8CD12738E6223B81F68E2DD6D16A278FEA6B583756777D26A06A3FA6135DD4`, eight home/two cloud allocations, `quod-node-arch206[*]` volumes and cloud `/quod/data/arch206/<index>` paths.
- Global `traefik`, unrelated infrastructure jobs and every other network in the raw job summary.
- Former `refound-20261025-stage1-c05`, `refound-20261026-xr-demo02`, `refound-20261017-v12` and other retained volume families. These are not the current eight-volume boundary and may contain failure evidence.
- Local/browser/native user identities and exported backups, agent-vault unlock files outside the selected network volumes, repository/worktree files, `/tmp` retained test fixtures and all failed/stopped campaigns. No content census of private backups is needed or authorized.

## Exact old catalogue

| Namespace | Genesis anchor (hex) |
| --- | --- |
| `quod:agent` | `dfafdc7d14feb7db59ad937f3ec276ef00b1e1906cc0d9f1e0f3de328f67395a` |
| `quod:environment` | `1ea6010ec73ed9a26aa1d8e247bc6e68462ab9dc32aa511bc4caef53f9f21a0f` |
| `quod:environment:eidolons` | `41dd4473140f55a8e40173df4ae565b13d71cf3ebebee84d44119e4a89dedaf9` |
| `quod:gui` | `81a035eadcad877810f70d2844e106e8977c5085a4254fddbfa4d2622a0182a3` |
| `quod:human_user` | `57ddd89ce5d12cd4ba3b4791296392684b9ed2a967945b4a03ad9b4de82b5122` |
| `quod:lens` | `7602158d91959983a43354e9de0fe93a95baa272a15417734f5c213aad26d3ae` |
| `quod:licence` | `4dcebb0c8a9ccbba2b3ac133ce1c299e5a8cd11f3e8152f63fa659893bda9c95` |
| `quod:lobby` | `85275179ccf19eae8e83fdf9892fec28550ce4d67ca05a6007e865b881ad9458` |
| `quod:material` | `520f5ca3c4c74013f73143383e6dce51c01d07f22b18af7433a082312849e2c1` |
| `quod:material:eidolons` | `20f0e7aa39592771b596252e1e374a6377e10de34fe5ff2cdede4ada4b33e728` |
| `quod:measure` | `ca173214c050e750baea5658ac3ea5e77476b2b8379f4cc707ad5bcf57042a24` |
| `quod:modelling` | `64a022de83bcea9b1a4dacc05b5330ee98df4d4a441ced837710487b375c0074` |
| `quod:names` | `3709e8fe8e1573feb6b38b59f92c092002f4aa3200caea61a9fde3bb8fa24677` |
| `quod:node` | `e89f0b13ce1905306b7098d5f218b4ff9d8a42f4b559a68c87c859e78f206b2d` |
| `quod:prolog` | `aa32b49a4df542e85df511fe51a676aadd0c4df608bdf5f362972f91d08059a2` |
| `quod:prolog:eidolons` | `785ee70fc7576808aa12b3fd7926b892ac6c9c946dab971c5bb1705ba1a42e59` |
| `quod:rendering` | `5bc0e56811080a8c90ba1d0340ae2e08f5fa6f963a6b74b3e98522f6af0af7d5` |
| `quod:signup` | `986ec17ec741c14f2364f199f9661e8637fad9d1026e298bc58463570297aebd` |

[Full projected job/allocation/volume inventory](network-inventory.json) includes exact unrelated-resource identities for comparison. Capture a new labelled observation at M5; do not overwrite this evidence.
