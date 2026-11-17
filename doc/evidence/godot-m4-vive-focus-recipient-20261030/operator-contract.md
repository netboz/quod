# Future recipient observation contract — offline preparation only

This helper has not been armed. No new desktop/native case, focus action or
human question is authorized by this preparation. Coordinator
`ed9cd520-b2a4-4607-a8f5-ff99d08f3e46` remains the only human contact.

The existing listener now requires `--recipient-bindings` in addition to its
existing caller-owned PID/address/executable/compositor/deadline/private-dir
arguments. This is a new diagnostic input contract; old arm wrappers and closed
case12 IDs are historical inputs and must not be reused automatically.

The bindings file must be an ordinary, non-symlink mode0600 file under the
task's private Data root with a mode0700 parent. It contains a JSON list of
explicit window/process bindings. Each entry has exactly `role`, `address`,
`pid`, `starttime`, `executable`, `device` and `inode`. Roles are only `task`,
`coordinator` or `runtime`; addresses are unique hexadecimal window addresses.
The future caller must establish these current identities and their ownership;
names, titles, application classes, parent-tree guesses and earlier case IDs
cannot establish a role. Extra task-owned windows require their own explicit
binding. Omit an unavailable binding. An empty list is valid. The observed task
window's existing verified process identity is included automatically, so do
not duplicate its address in this file. Bindings and actual invocation arguments
remain private; only filtered evidence is suitable for publication.

The first complete notification changing an event-recorded owned state to
not-owned consumes the one-shot opportunity. An initial not-owned event or an
owned snapshot cannot supply that anchor. Empty successor data records `none`
for the provider's empty-window notification. An address absent from the
explicit bindings records `unknown` without querying unrelated owners.

Only a bound address triggers one transient `clients` query. The same remaining
absolute budget supplies its timeout, capped at the existing5s. A unique mapped
window must still match the supplied address/PID, and a fresh process read must
match starttime and executable device/inode. The shared process owner also
checks the supplied executable path against `/proc/PID/exe`. Missing/stale or
ambiguous data stays unknown; I/O/shape errors produce a fixed sanitized failure
and terminate the existing listener through its existing error owner. No retry,
later-recipient query or deadline reset follows. All operations check the same
original budget; a result completing after expiry cannot confirm a role.

No successor address, PID, executable, title, class or clients reply is retained.
The recipient row contains only the role/validity, lookup-attempt flag, event
receive time, query start/end times, incarnation-check time when reached, and
the classification completion time. Query replies and successor bytes exist
only transiently. A confirmed role describes the lookup interval, not an atomic
transition-time identity or an initiating actor. Address reuse and changes
between notification, lookup and process read remain temporal limits. Unknown
does not identify a different application or prove any cause.

The existing single socket subscription, event FIFO, separate unordered
snapshot, local-close/remote-EOF distinction and conservative absolute caller
deadline remain. There is no subscription acknowledgement, cross-socket
barrier, provider emission timestamp or new native/pixel evidence.

If a future case is separately authorized, use its actual current owned
identities, exact qualified helper hash, explicit private bindings and a
deadline no later than its original participant deadline. Retain the real
`tty:true` launch/control receipt privately. Only after app/listener readiness
may the coordinator invoke a card directly first and relay that actual start.
Then the existing exact-owned focus hook runs once, followed promptly by the
existing geometry/status observation and filtered event interval. No extra
notifier or refocus loop follows during the look. False application/native/pose
or model gates are evidence, never overridden. The coordinator alone issues any
headset look instruction. Exact human response times and later samples retain
their separate scopes. Ordinary finish/close and restoration stay within the
original bounds. No ninety-frame, button, gesture, movement or physical pass
follows from this helper's protocol success.
