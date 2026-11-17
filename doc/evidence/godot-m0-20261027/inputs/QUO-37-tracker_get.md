# Make proof admission budgets governed for atomic source installation

**Type**: bug
**Issue Key**: QUO-37
**Status**: to-do
**Priority**: medium
**Tags**: architecture, prolog, resource-policy, proof
**Linked Commit**: c0a1567bfe9538bf805af233357b3dc39acbd4c9
**Sync Status**: synced
**linkedCommits**: [{"sha":"d2c419cf84855a53e06f3b18033b29d487f96061","message":"test: verify hinged outcomes in ordinary signed views","sessionId":"5b3d896b-45d7-4fb1-ae17-3e1a55439340","timestamp":"2026-10-12T13:25:12.924Z"},{"sha":"f527384e8df0b1310968c2ab7f1367f1075db3fc","message":"chore: prepare candidate release 0.7.264","sessionId":"5b3d896b-45d7-4fb1-ae17-3e1a55439340","timestamp":"2026-10-12T13:27:05.010Z"},{"sha":"c0a1567bfe9538bf805af233357b3dc39acbd4c9","message":"docs: retain partial signed hinged acceptance","sessionId":"5b3d896b-45d7-4fb1-ae17-3e1a55439340","timestamp":"2026-10-12T14:16:06.086Z"}]
**share**: {"status":"team","body":"team"}
**blocks**: []
**ID**: bug_1791807061434_iovrco
**Updated**: 2026-10-25T11:10:16.780Z

---

An all-at-once guarded replacement of 55 retained ontology predicates fails with savepoint_limit_exceeded(1024), normalized to proof_unavailable. The compact request fits current signed parser/encoding bounds; the destination remains unchanged. Full attributed evidence is retained in doc/evidence/hinged-views-20261012/source-composition-08. Expanded edits separately exceed encoding allowances.

This is independent of QUD.36. The supported signed predicate editor successfully installs the complete replacement while simulation is explicitly disabled; every edit checks expected source and inactivity. That route has now also installed both live worlds without splitting a physical transition. The earlier claim that bulk replacement was a prerequisite was incorrect.

Trace and attribute admission in the existing proof, source-editing and transaction owners. Distinguish encoding constraints from allocation budgets; configurable resources belong to Prolog policy. Do not raise constants, bypass proof checks, introduce wrappers or split domain transitions to evade limits. Preserve rollback, authorization, cut/backtracking, OCC, exact original operations and absolute deadlines. Verify atomic success and late conflict/denial rollback through production owners; retain full failure logs and true exits. Yan requested this separate ticket while finishing hinge testing.