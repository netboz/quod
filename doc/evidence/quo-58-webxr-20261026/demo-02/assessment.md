# Corrected fresh-ledger demo

QUO-58 and QUO-59 source is committed in `480ba266` and `1daac001`.
The second commit corrects the actual signed controller projection's numeric
bounds, discovered during demo-01. Both earlier failed measurements are retained.

All 12 sequential release gates passed on the corrected frozen tree: 57 native
debug and 57 native release tests, 289 client tests, UI build and lint,
4241 EUnit tests, 149 Common Test cases, xref, Dialyzer and release packaging.
See [gate receipts](release-gates-01/PASSED.json) and the individual full logs.
The frozen input includes HEAD `1daac001bfccb508cb5916cbb1e33e98296f3d90`
plus the preserved pre-existing working patch
`38f36875692d0044db4d5d86796c55ecc3f65f72423e167bbd6d292d3355ef04`.
It is not represented as a clean HEAD-only build.

The [verified image](verified-image.json) is pinned to registry digest
`sha256:6bb00abb0aee978433a8cffb90de6032c4169da8c2990b139c657243ae119243`.
Its packaged sources and emitted client assets match the frozen build.

Under Yan's explicit delete-and-recreate instruction, only the eight inventoried
candidate demo-01 volumes were deleted and replaced with demo-02 volumes.
The three protected jobs and 24 unrelated/historical volumes were preserved.
No existing ontology was updated in place. The new root is
`F3372F1D729A21D911149EB8D91D8A1FB5C0E94FE5EB1880AA5F0D16DABD92C1`;
all 18 system ontologies were founded from the packaged sources, then verified
on all eight healthy candidate allocations at job version 110.

The [HTTPS verification](https-verified.json) passed normal certificate and
hostname checks, exact security headers, world HTML and all 195 emitted assets.
The [live client checks](client.log) passed fresh-account controller definitions
and pinned appearance decoding, a distinct personal agent, storage discovery
and unchanged repeat, unplaced initial location, and one ordinary infinite-space
creation through the signed production operation. No uncertain write was retried.

The physical campaign is [vive-live-01](vive-live-01/session.py), using the
qualified headed Chromium and real Monado runtime with simulation disabled,
normal browser permissions, exact temporary server-certificate trust and the
actual HTTPS application. The browser created a separate normal demo account
and rendered its lobby with no recorded CSP violation or application exception.
The display was enabled with desktop geometry preserved. Yan confirmed HDMI
reconnection, green controllers and readiness before entry. Real stereo rendering,
changing head/controller poses, normal app exit and re-entry were observed.
However, Yan reported the physical-view mask repeatedly hiding the scene during
small movements. This is not usable physical acceptance. See the
[physical assessment](vive-live-01/assessment.md) for the observations,
view-guard diagnosis, remaining uncertainty and successful owned-process,
display and temporary-trust cleanup.
