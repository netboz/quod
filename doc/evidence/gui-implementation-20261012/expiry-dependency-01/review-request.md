# Certified expiry dependency consultation

Read frozen AGENTS.md and candidate.md. Source-only; no commands/tests/production
edits. No runtime or wire implementation yet. Challenge the future-row distinction:
retained claim above captured prefix for different bytes/same agent-id must not
invalidate expiry of original bytes. A claim at/before prefix, including an
unresolved prepared group, must prevent expiry. Identify a concrete counterexample
or sufficient checks, including admission timestamps across source lanes and epochs.

Audit integration through current read-set validator and retained outcome index.
The candidate needs network validation alongside exact source identity; current
quod_diff outcome context is only {Index,Parent}, so identify appropriate existing
context propagation rather than assuming the request's claimed network is trusted.
Current planned positive unsigned query separately replaces signature-dependent
lookup and retains exact digest binding; it does not implement negative expiry.
No resubmission, timers to discover readiness, new service or history replay.
Write fable-review.md here; leave old reports and candidate unchanged.
