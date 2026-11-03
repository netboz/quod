# Unsupported renewal hypothesis — do not apply

The actual configured-completion01 renewal did not call checked_completion/1 or the wire-policy callback. This proposal is untested and does not explain the measured remaining cost. Retained only as an abandoned investigation artifact. See ../STATUS.md.

# Isolated diagnostic candidate

Not installed in Quod or the pinned dependency. No pin/commit/publication change.

Erlog already validates every admitted native reason. Prepending another valid reason preserves a proper portable stack; the immutable suffix needs no second validation. Incoming merges retain their complete shape validation. Explicit whole-stack callback policies retain their current contract and truncation behavior.

Quod’s default callback now performs only redundant portable-shape checks and canonical encoding; no resource quota remains in it. The shared committed-projection constructor therefore uses Erlog’s native admission. Actual wire encoding/decoding retains canonical and shape validation at delivery. No failure reasons are dropped, delayed, deduplicated or truncated by a new rule.

Tests cover exact reasons/order, finite callback behavior, native/wire shape equivalence and actual admission call counts. The signed diagnostic decides whether this explains current scene failure; it does not establish the original renewal acceptance by itself.

## Contract argument

Erlog’s portable-reason validator accepts atoms, numbers, binaries, recursively portable lists, and compounds with an atom or opaque-symbol functor; it rejects variables and runtime resources. Every accepted constructor is representable by the current Quod `encode_value/1`; the failure codec adds no independent quota. Thus the removed default callback does not reject any additional portable reason by policy. Actual canonical transport encoding remains at its existing delivery owner. This claim does not turn an unrepresentable transport frame into successful delivery.

The existing immutable reason suffix is admitted by the same constructor. New reason validation therefore preserves the complete stack invariant inductively. Explicit external whole-stack callbacks remain fully evaluated as before, including reservation of the truncation marker for finite policies. Incoming merge still checks a proper admitted list and preserves order. No raw automatic failure frame, diagnostic history, permission check or failure boundary is discarded.

Configured validation:158 tests pass on OTP28.5.0.2 with the dependency’s actual configuration script and maps backend. The original aggregate acceptance still fails (first renewal26.219s; second cancelled3.775s). This is a verified partial correction candidate, not a completed performance fix.

## Second duplicate admission owner

`quod_ask:checked_completion/1` previously created an empty Erlog state, installed the wire policy, then merged the entire completion into it. The resulting state was discarded. The existing wire predicate validates the same complete proper stack directly, including canonical representability. Calling it once preserves exact accepted/refused data and reason order without repeatedly admitting every prefix. The same initial native-admission correction above remains included. This revision is still an isolated proposal, not installed source.
