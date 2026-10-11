# Release 261 gate 01 stopped

Native test invocation used a stale scratch executable from the copied Cargo cache; it did not test the frozen candidate. See [triage](triage.json) and [stop receipt](STOP.json).
Full logs, frozen sources and runner scripts are retained. A separately
labelled corrected campaign is required; this run is not acceptance evidence.
