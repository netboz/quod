# Held movement pauses across permission renewal

Yan reserved the desktop for this windowed test. The ordinary signed client
reopened the same private profile, account, world and body on release 0.7.261.
The [preflight](signed-preflight.json) records body 2 at
`(4.5115761757, 0.7518299818, 1.5186029673)` metres and the existing 700 mm camera
offset. No source, geometry, permissions, budgets or server configuration changed.

The [input and animation recording](renewal-movement-01-recovered-input-animation.json)
contains 2,071 rendered frames over 34.533 seconds: about 59.94 fps, median frame
interval 16.70 ms, maximum 27.00 ms. There is no focus, capture or visibility loss.
The [public network recording](renewal-movement-01-recovered-network.json)
contains 1,864 simulation frames, 198 HTTP 200 control responses, one expiry
notice and one replacement signed projection. Response bodies were not collected
by this recovery collector; HTTP status alone is not a domain-success assertion.

## Renewal interval

All times below are milliseconds from the recorded test start. Network events
are aligned to browser observations using the median HTTP wall/monotonic clock
offset; the observed offset spread is 1.314 ms.

- ArrowUp is continuously held from 28,794.0 until 29,444.7.
- The server sends `refresh(expired)` at 28,917.6.
- The replacement projection arrives at 29,219.5, a 301.9 ms gap.
- The rendered horizontal position stays within 0.01 mm of its position at
  28,913.4 through 29,430.5: a 517.1 ms stationary interval while ArrowUp is held.
- The last preceding authoritative frame, tick 7128 at 28,903.5, places body 2
  at `(4.8775205612, 0.7517502904, 1.4506210089)`. The replacement's tick 7129
  and subsequent tick 7130 retain that horizontal position to within 0.001 mm.
- ArrowDown is pressed at 29,446.2. Tick 7131 at 29,474.7 then advances the body.

The [analysis](renewal-movement-01-analysis.json) retains the key transitions,
camera frames and authoritative body samples around the renewal. This establishes
a real renewal-correlated pause with continuous input and smooth rendering.
It does not establish that every reported micro-cut has this cause. The generic
client refresh path clears the scene and held movement; the corrective design
must preserve current authorization and expiry guarantees.

## Interrupted orchestration and retained corrections

The fullscreen question interrupted the orchestration call while the child test
continued. The first process check ran inside the sandbox and wrongly suggested
that the host child was absent. The assistant released driver actions and stopped
the existing observer while recovering its original data. This deliberate stop
occurred about five seconds after the renewal interval above.

The original [stop record](renewal-movement-01-STOP.json) retains that incorrect
child-absence inference; this paragraph and the analysis explicitly correct it.
The later host check and [completion receipt](renewal-movement-01-exit.json)
establish that the original child exited zero after 18 cycles, with driver keys
released. This is not a completed 19-cycle acceptance pass. The recovery collector
drained the public events, so the child's subsequent network capture is empty;
use the recovered recording linked above. Neither the interrupted run nor the
empty later capture was silently retried or replaced.

Three earlier window-ownership checks failed before any test input because Chrome
rewrites its process arguments into one space-separated string. Matching the
exact executable and profile after parsing that string established the correct
compositor window. The first analysis printer also failed formatting tuple keys
after printing its measurements; the retained JSON analysis avoids that diagnostic
formatting error.

## Desktop released; acceptance remains open

The [closure receipt](browser-closed.json) confirms normal browser exit, no
remaining process owning the profile, and preservation of that profile. All
driver keys are released. The reserved desktop window has ended; further live
testing must be coordinated with Yan's desktop use.

QUD.27 remains in progress: correct the renewal interruption and verify sustained
movement again in the same signed world. No production fix, deployment or new
refound is claimed here. [SNAPSHOT.json](SNAPSHOT.json) hashes the retained public
artifacts; the private profile and compiled caches are excluded.
