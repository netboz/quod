# Closed unused adapters

This scope closes section A of the reviewed multiwrite deletion ledger, against
published 91c94d5. It removes seven exports and one exclusive private helper;
no replacement implementation or process is added. Five production modules
lose 87 physical lines in total. This is a measured small deletion, not a
claim that tens of thousands of lines are unused.

| Removed | Preserved responsibility |
| --- | --- |
| proof_session:run_first_with_dependencies/3 | run_first/3 and explicit session dependency capture |
| proof_session:absorb_live_bridges/2; local_prove:absorb_live_bridges/2; its private valid_bridge/1 | Live-bridge recording and sealing veto; ordinary monotonic committed-read dependencies |
| dtx:live_bridges_bytes/1 and live_bridges/1 | The signed field, canonical material decoder, validation and proof authority |
| committed_projection:target/1 | The anchored target in projection state and the canonical applier |
| client_goal:digest/1 | Signed-request verification and its authenticated request digest |

The source/test/configuration/script/operator-doc/system-ontology audit found
no repository roots outside the unused bridge-merge subtree. These are not
registered predicates, database or behaviour callbacks, supervisor starts,
configured handlers, or documented operator commands. Arbitrary external
console use cannot be excluded by a repository scan: removal of these unused
convenience exports is explicit, not a hidden compatibility promise.

Compiled-export and private-AST controls require every removal and retain the
live canonical interfaces. The unchanged source fails those eight removal
checks while all eight retention checks pass. Full existing proof, signature,
bridge, policy, projection, event and integration tests remain unchanged.
No wire/durable format, signed field, backtracking rule, deadline or limit is
altered. The other deletion-ledger sections remain separately scoped work.
