# Shared QUIC stream priorities

The existing link classifies each encoded channel once through the bounded
canonical `quod_safe_term` decoder, obtaining both priority and catch-up role.
Classification does not change
channel bytes, authenticate an application request or grant consensus authority.

| Channel | Urgency | Incremental |
| --- | --- | --- |
| `{log, Namespace}` | 0 | false |
| `{catchup, Namespace}` | 1 | true |
| `{ingress, Namespace}`, `{quod_dtx, Namespace}` | 2 | false |
| `quod_directory_control` | 2 | false |
| `{feed, Namespace}`, `{quod_scope, Namespace}` | 4 | true |
| `{quod_scope_return, NodeKey}` | 4 | true |
| Other channels, including signed goals and raw Brahms namespaces | 6 | true |

Namespaces must be nonempty binaries; a return-channel node key is 32 bytes.
Malformed, compressed, oversized, noncanonical or trailing-byte encodings remain
in the lowest application class. No untrusted atom is allocated. Raw namespace
channels cannot be distinguished from arbitrary application channels and are
not promoted by guessing. No new agent-delivery channel is introduced.

The existing link process sets the priority immediately before its first local
send. Outbound setup does this before sending its header. Inbound setup does it
only after the connection owner authenticates the header, before any ACK,
catch-up credit or response. Both directions use the same helper. A library
refusal resets that stream and terminates its link; normal ownership reports
failure to openers. There is no fallback to the default priority. Reopening a
stream repeats this setup before exposing it to callers.

The pinned QUIC library schedules queued stream data by urgency. Its urgency-0
send path also uses the existing bounded congestion-control allowance; this
change activates that library behavior for consensus streams. It does not
modify congestion control or promise that the incremental flag alone provides
fairness: the pinned library stores that flag but does not use it in local
scheduling. The Incremental column is advisory. Priorities cannot preempt data
already sent, reserve connection flow credit or shared send-queue capacity, or
bound application CPU and mailbox growth. Queue exhaustion can still refuse
best-effort consensus sends. Strict priority can starve lower classes, including
membership traffic. Catch-up ranks ahead of new writes to restore a lagging
peer's committed state, with its existing page credits bounding production;
the resulting tradeoff requires load acceptance.

Tests cover classification, priority-before-send ordering, refusal without a
send, both directions over real QUIC, replacement streams, and bounded mixed
application/log traffic. The mixed-traffic test is a liveness regression check;
it does not establish sustained queue contention or the benefit of priorities.
A broader congestion/churn load witness is required
before claiming fleet non-starvation or activating additional agent traffic.
Local loopback completion is not a fleet performance result.
