# Follow-up review evidence

Fable closed B1 and B2 and reported no implementation blocker. Frozen release
gates and deployed desktop acceptance remain required; this is not release clearance.

The remaining decoder audit point is bounded: `quod_wire_term.erl:649-655`
checks `ERLOG_MAX_FAILURE_REASONS_BYTES` before invoking
`quod_safe_term:decode/2` with the same limit. Oversized binaries return
`too_large` at lines657-658. No change is needed.

The patched founding helper is an image-specific deployment operator copied
from historical evidence. The application's development/bootstrap source path
is unchanged; no general dev-shell founding regression was introduced.
The five persisted source file names are part of the factory contract and must
remain present at the canonical packaged location on subsequent images.

The actual built image must resolve all five factory sources and the signup
user template through `/opt/quod/priv`. The next image rollout must repeat that
check against the same stable paths before deployment.

## Subsequent mechanical validation correction

Dialyzer found that startup receipt loading constructed `#s{directory=Dir}`
without the record's required unlock function solely to call `receipt_path/2`.
The helper now takes `Dir`, with its other two callers passing `S#s.directory`.
The resulting path, receipt format and all state transitions are unchanged.
This routine four-line refactor was independently checked; it does not reopen
Fable's closed design findings. Focused vault tests and Dialyzer pass, with full
sequential verification recorded separately.
