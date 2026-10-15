# Stopped release campaign

Native debug/release tests, clippy, client tests, UI build/lint, all 4000
EUnit tests, all 148 Common Tests and xref passed. Dialyzer stopped the run:
receipt loading constructed an incomplete vault state only to calculate a
filename. The existing filename helper now receives its directory directly;
no custody behavior, persistence format or authority changed.

The focused vault suite passed. This failed campaign is retained intact and
is not release clearance. The corrected source is verified in gates-03.
