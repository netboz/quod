# Retained-work gate 01

Native debug/release (57 each), clippy, client file-level runner (22 files), UI build and lint exited zero. EUnit exited 1 after 43 passes because the sandbox denied the localhost TLS listener with EPERM; no complete suite result. STOP.json and all logs are retained. No source or assertion changes. Campaign 02 uses the identical source with local networking permission. It runs client files directly to capture individual test totals, rather than Node 26 file-only summaries.
