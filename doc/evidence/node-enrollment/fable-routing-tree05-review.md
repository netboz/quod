Read-only Fable confirmation, 2026-10-07. The reviewer did not run builds or tests. Its response is reproduced below; the phrase “four production files” is a counting typo: this frozen scope has three production modules, three test modules and one contract document.

Verified, nothing further needed.

**Hashes.** All seven files in tree-05.json match the working tree, the evidence copy is identical, and the scoped diff hashes to exactly tree-05.patch (c6938074…). The four production files, the routing doc, the catchup tests and the directory unit tests are byte-identical to tree-04. Only the ask suite changed.

**The test delta.** The global subscriber count is replaced by two assertions on the custodian's actual subscriber map: exactly one stream whose key is the applicant's, and no key appearing twice across all subscribers. The `third_pub` config key is bound in the suite setup, so the applicant key lookup is sound. The new link pid check and the subsequent natural renewal wait are unchanged.

**Assessment.** The replacement is correct and stricter in the way that matters. With three peers, the source node is a legitimate directory consumer of the root custodian, so a global count of one was a fixture assumption, not a property of the fix. The new form still rejects a duplicate stream for any peer after the restart, which is the regression the lifecycle hunk prevents. Recording the first failure without captured keys as unproven in deployment.md is the right call.

**Gates-05** at the time of this check: the two clean steps done, eunit next. Approval stands for tree-05 once the full sequential run is green with retained logs. No open items on this scope from my side.
