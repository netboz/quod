# Naming catalogue recovery assertions

The final native, client, UI and all 4,080 EUnit tests pass. Common Test reports
two failures in `quod_names_SUITE`: cold peer join at line 394 and founder VM
restart at line 423. Both expected 1,449,227 names and observed 1,449,371.
The difference is exactly the 144 original landscape names introduced by the
world-library feature. These calls query all name kinds; they are not personal
name draws. The personal catalogue remains 1,449,227 and an unqualified draw
still excludes world names. Existing EUnit tests assert those facts explicitly.

This is a stale recovery fixture, not lost or duplicated catalogue data. Both
scenarios match the original genesis anchor and successfully reach the restored
ontology. The recovery assertions should compare the whole founded catalogue
with its recovered count, so `init_per_suite` now captures that count and both
recovery cases compare against it. The source-cardinality unit assertions and
the exact anchor/real draw checks remain. No assertion is removed, no deadline
is extended, and no production source changes.

The full campaign ended with Common Test exit 1: 146 passed and exactly those
two failed, with its frozen source unchanged. Its STOP and full logs remain;
it cannot claim release success. A separately labeled focused naming suite
verifies the fixture correction, followed by a new full clean campaign.
Fable's final frozen06 production review remains applicable to byte-identical
production source; the test-only delta will be recorded explicitly instead of
claiming that Fable reviewed a different tree.

Focused verification `names-recovery-count-01` exits 0: all nine real-node
naming suite cases pass, including cold join and whole-VM ledger replay. The
run took 46.29 seconds. No production source was changed for this correction.
