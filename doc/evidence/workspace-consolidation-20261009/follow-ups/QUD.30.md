# Apply argument-error semantics to the existing source-chunk primitive

Local tracker: [QUD.30](nimbalyst://QUD.30). Tracker metadata and local body are saved; collaborative body storage failed on creation and retry. This file preserves the complete task description.

+Independent consolidation review found a small integration gap between [QUD.24](nimbalyst://QUD.24)'s preserved source-chunk primitive and the failure/error contract accompanying [QUD.8](nimbalyst://QUD.8).

src/predicates/quod_common_primitives.erl:source_chunk_2 currently accepts a positive integer Bytes and otherwise uses bare erlog_int:fail/1. The new doc/proofs.md contract requires malformed required arguments to raise argument errors; valid unequal output values remain ordinary Prolog failure. This function's preexisting inspection implementation was intentionally excluded from the failure-taxonomy commit scope, so the current reviewed release preserves that behavior.

Implement the established argument distinction at this existing pure primitive: unbound required Bytes, wrong type and nonpositive integer must use the appropriate existing Erlog error classes. Keep valid bound-output unification as ordinary failure. Do not add another parser, source inventory, budget constant or public-error allowlist entry. Chunk size stays Prolog lens policy; current snapshot and authorization remain owned by existing paths.

Test via existing source-inspection/primitive seams, including full empty/nonempty source, malformed allowances, valid mismatch and unchanged repeated-read cost where relevant. Preserve the already-deployed inspection baseline and qualify the narrow delta separately. Current valid ontology-authored source reads are not known broken.
