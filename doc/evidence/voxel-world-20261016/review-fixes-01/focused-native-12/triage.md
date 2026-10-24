# Fixture assertion triage

Both same-chunk edits integrated successfully. The probe measured 8.261224991248373 mm penetration at impact (tick 17) and 0.06919859587173338 mm at rest (tick 400). The newly added assertion of an ideal, axis-aligned two-box tower height failed; it did not account for body rotation/rearrangement.

The regression now checks each actual rotated shape AABB against the ground within the solver's 5 mm rest tolerance, rather than assuming an ideal centre height. This is tighter than the old y > 1.1 check and does not relax the transient admission check. Final poses and lowest points are recorded in focused-native-13. The real-owner loaded-body fixture separately asserts contact and vertical ordering before and after the signed dig.
