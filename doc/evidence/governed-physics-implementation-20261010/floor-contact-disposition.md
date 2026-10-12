# Initial-contact candidate: withdrawn after review

The [signed 262 recording](desktop-262-02/README.md) completed 80.73 seconds
and six renewals, but three clear-floor pauses remained. All three captured poses
and quantized inputs reproduce the refusal in the
[unchanged solver investigation](floor-occupancy-investigation-01/README.md).
The skin-distance sweep returned no impact; the final occupancy check correctly
refused its penetrating endpoint.

The withdrawn candidate added a contact-manifold query before each linear
sweep. It used the closest approaching face inside the authored skin and charged
both queries against the existing allowance. Its first 27 native tests passed
in debug/release, and [release gate 02](release-263-gates-02/README.md) passed all
eleven checks. Those results were insufficient: expanded boundary coverage
found **8 failures among 3,608 travel cases**, including two occupied-floor
refusals, and 152 resting horizontal landing-path refusals. All 451 vertical
landings found support. This candidate was not deployed.

Fable's [plan invocation](floor-contact-plan-review-01/README.md) exhausted usage
credits before invoking a model. The [Opus review](floor-contact-plan-review-02/opus-review.md)
rejected the precheck and called for the broader coverage that exposed these
failures. A deeper trace confirmed its GJK stagnation concern: after progress
stalled at time zero, the miss used a projected simplex point instead of a true
support point.

The entire precheck and its documentation were removed. Its exact patch,
failed campaigns and stop markers remain in the
[diagnostic archive](floor-gjk-correction-01/README.md); the initial correction
campaigns retain their [full logs and source](floor-contact-correction-01/README.md).
Gate 02 is explicitly **NOT FOR RELEASE** despite its passing standard suite.
The earlier sandbox-denied gate 01 is separately retained.

Work continued with a [correction inside the existing library algorithm](floor-gjk-correction-01/README.md).
The original query-count assertions are restored. That investigation also
found the old 1m-prediction contact-distance test oracle could falsely report
penetration above a flat floor; the final tests use direct intersection checks.
These changes and all release/desktop obligations are recorded separately.
