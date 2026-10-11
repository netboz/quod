# Release 0.7.258 candidate refound

The authorized candidate refound and deployment passed on 2026-10-11.
Source commit: `96ab9bf45ae9f3ccebe31a5adc1613d216c3d09d`.
All ten [clean release gates](../release-258-gates-03/README.md) passed first,
including 3,870 EUnit tests and all 146 Common Test cases. Earlier failed
campaigns remain separately recorded.

Candidate job `quod-finality-candidate-v6-20260926` is version 61,
JobModifyIndex 845205. Deployment `3bd2c3f9-642e-f770-5a20-61cdc138679e`
succeeded with eight healthy allocations, zero restarts, 18 ready system
ontologies, complete node enrollment, stored principal pointers and ready
local key vaults. The external vault provider is disabled.

Image: `192.168.1.11:5000/quod:0.7.258@sha256:b5190f009b08ebeca5923258c2cd99fb754eb69bb81c28ff6c1b19b3c4fc892c`.
New root: `AA1F4ABBE0C7597C1BE15A1656E447EB7685B798BFBE7B845CBE889C620CB4E5`.
New volume family: `quod-finality-candidate-v6-20260926-refound-20261011-v5`.
The guarded procedure stopped candidate allocations before removing the old
candidate volumes. Per-volume deletion receipts are retained in the archive.
The separate main job remained version 246 / JobModifyIndex 826727.

The [signed source smoke](signed-source-after.json) passed for 17 targets with
zero ledger writes. It used an ephemeral key-bound applicant and verifies
source/policy behavior, not Yan's personal world or desktop collision.
The new ordinary client origin is `https://192.168.1.10:30614`.
The prior personal-world baseline is historical after this authorized refound;
real personal acceptance needs a fresh signed identity/history baseline.

The archive retains deployment scripts, immutable intents, raw child logs,
true exit receipts, volume records and exact image provenance. The isolated
image vault boot also passed. Build-context copies and temporary BEAM files
are excluded; source and image hashes identify the delivered implementation.

The [final seal](final-seal.json) also confirms the old v4 volume family is
absent, both attempted measurement scopes are absent, and root is still at
height 62. Temporary deployment/measurement helper modules were unloaded.
The first cleanup receipt remains in the archive; a second removed the current
module after purging its old version and verified `code:is_loaded` is false.
