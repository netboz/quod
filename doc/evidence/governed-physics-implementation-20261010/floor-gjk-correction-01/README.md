# GJK correction: diagnosis and native verification

The contact-manifold precheck was withdrawn after the [plan review](../floor-contact-plan-review-02/opus-review.md)
and the retained boundary failures. This correction stays in Parry's existing
shape-cast algorithm. No server deployment is represented by these campaigns.

The deeper trace confirms that all three signed desktop stalls take the same
uncertified miss: GJK stagnates at time zero and uses a projected simplex point
as a separating plane. The minimal direct triangle/capsule regression fails on
unmodified Parry (negative-control-01, exit 101) and passes with the correction.
The existing small-time contact refinement and composite traversal remain the
owners of approach/separation and per-face coverage.

The [archive](diagnostics.tar.gz), [file hashes](diagnostic-files.json) and
[true child exits](receipts.json) retain twelve separately labelled campaigns.
Unmodified library files are deduplicated: each reconstruction record identifies
the verified published archive and the exact overlaid files. No target binaries,
credentials or signed browser profile are included.

| Campaign | Result and interpretation |
| --- | --- |
| GJK trace 03 | Three exact captured poses fail; each relevant miss is time-zero stagnation. |
| Withdrawn precheck boundary | 8/3,608 travel failures; 152/451 resting path refusals; all 451 descents pass. Candidate rejected. |
| GJK candidate 01 | All 3,608 travel cases pass; 111 resting paths refuse; two wide-prediction contact-oracle failures remain. |
| Unmodified boundary baseline | 9 travel failures, 113 resting path refusals; 451 descents pass. |
| Distance probe | Contact with a 1m prediction reports negative distance for one body whose actual AABB is 2.28mm above the flat floor; prediction 0 and 2mm return no contact. This invalidates that test oracle. |
| Precision probe 01 | Dependency resolution stopped offline; no test result. |
| Precision probe 02 | Binary64 diagnosis: travel passes, 137 resting path refusals. Precision change rejected as the implementation approach. |
| GJK candidate 02 | Direct intersection replaces the erroneous contact-distance oracle; 27 pass, strict resting-path assertion fails. |
| GJK candidate 03 | Physical-geometry landing path, unchanged support skin: all 28 tests pass, including all 451 resting paths. |
| GJK candidate 04 | All 32 tests pass with direct triangle, compound-face, rotation/translation and blocked/occupied landing regressions. |
| Negative control 01 | The exact direct triangle test fails with unmodified Parry; no test assertion was changed. |

The final tests preserve the original query-count limits (`<10` and `<=4`).
Direct intersection checks replace a false-positive wide-prediction distance
oracle; they do not permit penetration. The final release tree additionally
applies and checks each of the 3,608 gap-sweep moves. The long reciprocal test
checks progress and nonintersection on 8,736 steps across identity and transformed
frames; the original 2,048-step circle remains.

Landing's path checks the complete physical body with zero added margin;
its descent still uses the configured skin. This allows a body already inside
the support margin to move along a geometrically clear floor. Walls, occupied
destinations, holes, unsupported slopes, exhausted budgets and initial/final
occupancy still refuse a usable landing. This clarification requires review;
the strict new resting-path test was kept and fixed, not removed.

The [line accounting](source-delta.json) distinguishes the small algorithm and
adapter changes from test growth and the vendored upstream source. Vendoring
retains the exact release and its upstream tests/examples; only one library
algorithm file changes. The standard Cargo patch replaces the registry instance
of Parry. There is no second physics engine, compatibility branch, new policy
constant or new query before the native sweep.

Implementation review, full release gates and actual signed desktop acceptance
are recorded separately. These native campaigns alone do not close the ticket.
