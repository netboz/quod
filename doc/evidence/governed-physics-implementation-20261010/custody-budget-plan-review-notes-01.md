# Additional owner trace while plan review runs

The frozen Fable plan packet remains unchanged. No production code has been
edited during this gate. These findings must be checked in the final design
and implementation review:

- `quod_proof_session:reserve_attested_preparation/9` forwards stage failures
  and releases its original reservation. `quod_prolog` forwards stage errors
  but currently collapses most reserve errors into journal-unavailable. Keep
  both paths precise without resubmitting an operation.
- `quod_scope_wire` owns a closed scope-error vocabulary; unknown terms become
  `protocol_error(proof_engine)`. `quod_client_result` similarly turns unknown
  errors into `proof_unavailable`. Add one bounded resource error shape to the
  shared wire validation and signed result path; expose resource and amounts
  in HTTP, and preserve useful text in the ordinary signed client. This is
  error reporting, not a new proof protocol or admission owner.
- Existing runtime selection errors mark `resource_failures` but leave the
  previous journal capacity installed. A malformed/absent committed limits
  projection must disable new reservations/staging through the existing owner.
  Keep already accepted obligations and exact original references available.
- Existing root lifecycle tests already measure owner selections,
  configuration calls, replay and file I/O using delivered trace barriers.
  Extend that existing coverage for byte-policy changes and invalidation.
  Do not replace it with timing tests or mirrored policy fixtures.
