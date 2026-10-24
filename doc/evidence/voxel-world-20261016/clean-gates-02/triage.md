# EUnit stop

The frozen campaign stopped on EUnit's true exit 1 after 4,050 tests and one
failure. Earlier native/client/build/lint gates passed. CT, xref, Dialyzer and
release did not run in this campaign.

`quod_lifecycle_single_path_tests:default_lobby_physics_startup_test_` still
matches the old native-query owner reply `{ok,Tick,Answer}`. The shared local
coordinate extension returns `{ok,Tick,Origin,Answer}`; the observed answer is
the expected clear pose with origin `{0,0,0}`. Update this shared lifecycle
fixture to check the coherent origin as well as the existing placement/contact
obligations. Do not remove the test or alter collision behavior to fit it.

The exact source manifest, log, receipt and STOP marker remain unchanged. A
new separately labelled campaign must validate the corrected final tree; this
failed campaign cannot be resumed or reported as passing.
