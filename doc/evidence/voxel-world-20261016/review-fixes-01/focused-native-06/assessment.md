# Supplemental checkpoint probe

The existing restore path was additionally exercised with a 4 mm resting surface penetration and its authored 5 mm recovery tolerance. The actual native test passed (see receipt/run log). The pinned Rapier default allowed_linear_error is also 5 mm. This resolves the suspected mismatch for that recovery profile; it does not establish every possible authored tolerance.

The exploratory fixture is retained in checkpoint-probe-terrain.rs, outside production test discovery. No production change followed. The final working source is restored to the exact clean-fixes-02 source reviewed by Fable; the existing clean gates remain the release evidence. This probe is supplementary evidence only.
