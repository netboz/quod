# Lobby design and implementation reviews

The [implementation follow-up](implementation-review-02/review.md) closes both
implementation blockers and reports no new blocker. Its release conditions are
clean frozen gates and actual candidate image/desktop acceptance. See
[coverage and dispositions](implementation-obligations.md) for the independent
checks. The [first implementation review](implementation-review-01/review.md)
is retained unchanged.

## Earlier corrected-design review

Claude Fable reviewed the corrected design on 2026-10-15. The process completed
successfully in 474.284 seconds with unchanged frozen inputs. The review explicitly
requires `isa(lobby, physical_space)` and a single
`instance_of(lobby, personal_lobby)` declaration.

- [Reviewed design](reviewed-design.md)
- [Full Fable findings](fable-review.md)
- [Independent disposition](disposition.md)
- [Input manifest](manifest.json)
- [Completion receipt](exit.json)

Design SHA-256:
`1afac62f30ab5d8329e83bcbc9de13ff6488f739e7161e7687fff764913fe754`.
The exact request and frozen source tree are retained under
`_build/lobby-redesign-20261015/review-02`.

Verdict: the corrected class model and representation direction are accepted;
automatic first-authority initialization still has design blockers. This is a
completed design review, not implementation or deployment approval. No production
code or deployed state changed during this review. The interrupted review-01 is
preserved and supplies no verdict.
