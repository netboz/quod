# Boundary follow-up

All six real-owner lobby jump cases and the retained Simplex pipeline test
passed. The foreign-payload search reached a second legitimate refusal at
transaction signing, before block encoding. Its helper now returns an explicit
size result to the binary search rather than assuming every candidate signs.

`foreign-boundary-02` then reached the actual enclosing history-page check and
failed with `bad_frame`: two maximal blocks plus the full certificate exceeded
the existing page allowance. This is a production sizing defect, not a test
expectation to weaken. The shared block capacity now uses the minimum of scope
carrier space and full-committee compact history-page space. Neither transport
nor page limits are increased; canonical encoding stays unchanged.
