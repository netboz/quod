# Diagnostic loader failure

The read-only inspection did not open the ledger: its standalone escript
omitted the OpenTelemetry dependency path and failed in `traced_file_open/4`.
Load the existing test dependency paths before opening the stopped fixture.
The failed receipt is retained; this is not evidence about ledger contents.
