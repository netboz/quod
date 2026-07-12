variable "image_tag" {
  type        = string
  default     = "0.6.32"
  description = "quod image tag in the cluster registry. 0.6.32 = multi-validator Slice C (the readiness gate): committee admission is now gated on the candidate being provably alive and caught up — the root ontology's admission rule becomes can_join(_Ns,_Addr,Pk) :- peer_ready(Pk), where peer_ready is a new READ-ONLY external Erlang predicate (the Prolog-reads-reality bridge; it stages nothing, so can_join stays side-effect-free). Reality source: quod_feed now digests its height to EVERY committee member each anti-entropy round (~3s; previously one sampled peer only), and every node passively records each authenticated digest sender in a public per-ns ETS liveness table (sender pubkey from the mTLS-bound link header; written only by the feed, read lock-free from any process). peer_ready(Pk) is true iff Pk's digest is fresh (<=15s) AND its height is within one pull window (256) of the judging node's own applied height — so admitting a dead or lagging node into a small committee (N=2,3: quorum=ALL, one dead member freezes writes) becomes a REFUSAL instead of a freeze. Judged independently by the submitter AND by every validator's verdict re-proof; honest validators MAY split (each observes liveness itself) — fail-closed, the slot Delta-skips and the submitter retries. HONESTY: this is liveness UX, not a security boundary (the height claim is unauthenticated content); and 1->2 / 2->3 admits stay one-shot ops (the admit commits under the OLD quorum) — the runbook additionally gates admits on the candidate being a supervised alloc. Side effect by design: a caught-up mode=join observer now TRACKS THE HEAD with no Brahms overlay (its member-digests draw ahead-replies -> verified pulls), making the read tier sturdier. Also fixes a latent feed crash (oversized eager-push bumped a map counter with +1 -> badarith). The gated rule ships in the genesis SEED (quod_root.pl), so it applies to NEW founds; the LIVE namespace keeps its committed default-open rule until the rollout's policy write upgrades it (retract+assert in ONE tx). NO block-format change => plain rolling update. 0.6.31 = multi-validator Slice B (growth liveness — the promotion race, max-review hardened): a leader no longer abandons its own in-flight proposal after one Delta timeout, and a genuine stall gets amplified to a skip. Before: founder proposes the first post-admit slot, the not-yet-promoted joiner drops the frame (send-once transport, no retransmit), the founder's Delta fires and it complains its OWN slot -> complained[] latches forever -> at quorum=N committee sizes (2,3) neither a commit nor a complaint cert can form -> permanent namespace wedge (DA-confirmed reachable at every 1->2 admission). Now: (1) STUCK-HEAD REDRIVE — the leader of an in-flight slot re-broadcasts (to peers with a LIVE conn only, so no outbox bloat) the proposal + its own re-signed support/commit shares (pinned by the supported[V] hash latch) + pooled certs each Delta; a receiver of a duplicate proposal RE-ECHOES its own shares, healing the reverse direction (follower->leader loss) too; a commit-signed leader keeps redriving (its retransmitted commit share is what heals a lagging follower) rather than no-op'ing. (2) f+1 COMPLAINT AMPLIFICATION — ANY node joins a complaint on f+1 distinct member-signed peer complaint shares (not only via its own Delta), so a late-promoting member that never saw the proposal still learns of the stall from the re-broadcast shares and its join closes the skip cert at the quorum=N sizes; the f+1 threshold is DERIVED from quorum/1 (f = N-quorum(N)) so it can't drift; a lone Byzantine can't force a skip (needs f+1). (3) a redriven membership proposal never re-requests a KB verdict once judged valid-and-supported or invalid (no per-Delta re-proof, no reject double-count). New quod_consensus_redrives Prometheus gauge (climbing = a member isn't responding). Tests: deterministic eunit for the f+1 threshold across N=2..7 incl. self-exclusion; join_SUITE's promotion case is UNPACED (post-admit write hits the founder immediately, in the race window) with ordered keys (shared quod_ct:generate_key_gt) so the founder leads the race slot and the joiner leads the acceptance slot. NO block-format change => plain rolling update. 0.6.30 = multi-validator Slice A (S5b admission-to-voter, deferred.md #3): a caught-up mode=join observer that sees its OWN peer_admitted fact commit — delivered over the live feed like any block — SELF-PROMOTES to a voting member (quod_simplex:maybe_promote/2 on the is_participant false->true edge across a sunk window: re-arms the engine over the new committee at the new head, exactly like the join_done re-arm; the committed fact IS the signal, the engine/links are projections catching up with the KB). Plus two safety gates from the plan's DA pass: sink_catchup now refuses windows once the node is a voting participant (an in-flight anti-entropy pull crossing the promotion would advance the store past the engine and crash the statem), and handle_append requires is_participant (a resuming mid-catch-up node whose on-disk prefix folds its own pubkey must not propose over a stale engine); status role is now derived (observer|validator), no longer hardcoded. Proven end-to-end in join_SUITE joiner_promoted_to_voter: founder admits the caught-up observer (one ordinary can_join-gated transaction), the observer promotes via the feed, and probe writes commit at quorum(2)=2 under EACH member's leadership (the joiner leads a slot). NO block-format change => plain rolling update. 0.6.29 = structured JSON logs: a new quod_log_formatter (OTP logger formatter, ~90 LOC, native json:encode/1, never-crash fallback, 4096-byte msg cap) makes the default handler emit one JSON object per log event to stdout; quod_app stamps node_id (the Ed25519 pubkey short-id) into the primary logger metadata so every line is attributable per fleet instance. The existing qengho promtail {job=docker} scrape carries these to Loki, where a query-time `| json` exposes level/msg/node_id/mfa as fields (Grafana panel: {job=\"docker\"} |~ \"quod[quod:\" | json | level=~\"warning|error|notice\"). Pattern lifted from the sibling onia node (same OTP-logger stack, same cluster). Observability-only, NO behavior or block-format change => plain rolling update. 0.6.28 = transport logging quieted: the pure-Erlang quic transport logged one INFO line per received packet (short_header_packet), which under sustained load floods the default logger_std_h handler faster than its stdout sink drains; the handler's overload protection then stalls the node's stdout entirely, so genuine warnings/errors never reach the nomad/docker log files promtail ships to Loki (this is why the founder's stdout froze at boot). quod_app now raises the quic application's log level to notice at boot (keeps quic warnings/errors, drops the per-packet info torrent), restoring live stdout so the existing promtail docker scrape can carry quod logs into Loki/Grafana. Observability/log-plumbing only, NO behavior or block-format change => plain rolling update (no re-found / no volume wipe). 0.6.27 = metrics: every Prometheus metric's `help` text rewritten in plain, jargon-free language (the help field the prometheus lib exposes as the metric's # HELP line, which Grafana surfaces per panel) + plain-language panel descriptions added to the quod-brahms Grafana dashboard. HELP strings are strictly ASCII: prometheus_text_format:escape_string does iolist_to_binary at SCRAPE time, which throws on any codepoint > 255 — a stray em-dash in 0.6.26 crashed every /metrics scrape and, since the Nomad health check is GET /metrics, failed the deploy; fixed here. Metrics-only, no behavior change, NO block-format change ⇒ plain rolling update. 0.6.25 = membership-safety Slice D (epoch seam, groundwork): a PURE behavior-preserving refactor introducing quod_simplex:active_validators/1 — the single seam for the 'who votes/leads/disseminates now' reads, holding the ACTIVE voting set distinct from the committee FACTS (#s.validators). Today it is the identity over the facts (epoch length 1); the future epoch-frozen-validators work rewrites only that one function + adds a snapshot field, without re-finding the read sites. No behavior change, NO block-format change ⇒ plain rolling update. This is the deploy of the whole membership-safety milestone A–D (0.6.22–0.6.25): committee changes are re-validated by every validator before support (shape+never-empty gate + per-node can_join/clause KB verdict), proven Byzantine-safe on a 4-node committee. 0.6.24 = membership-safety Slice C (deferred.md §3 a+c COMPLETE): wires the Prolog-side verdict into the consensus vote. A validator now DEFERS its support signature on a committee-changing proposal until its own KB judges it (quod_prolog:request_membership_verdict, correlated to the exact block by {Slot,BlockHash} so a Byzantine leader that equivocates can't cross a valid verdict onto an invalid block); valid=>support, invalid=>latch+never-endorse+count (quod_consensus_membership_rejects metric), abstain=>neither. A node that judged a change invalid never emits a commit share (notarized guard). Proven on the 4-node loopback-QUIC committee (simplex_SUITE byzantine_retract_rejected/byzantine_admit_rejected: a hostile leader's crafted membership change is refused support, the slot skips, the committee is unchanged, the namespace still commits). Still open: signed membership authorship (Phase B, closes packing) + the hard 3f+1 floor. NO block-format change ⇒ plain rolling update. 0.6.23 = membership-safety Slice B (deferred.md §3 a): the Prolog-side membership verdict + projection lockstep. quod_prolog:request_membership_verdict/5 (async cast; verdict delivered as a message) re-judges a proposed committee change against each node's OWN KB, pinned to the proposal's parent height (Slot-1) so honest nodes agree; assert re-proves can_join (rejects a can_join that writes, or a pubkey already admitted), retract requires the exact peer_admitted clause present (closes the fabricated-address validator-ejection from the Slice A review). A committed committee-changing tx now applies UNCONDITIONALLY (skip OCC) so the KB and the validator-set projection stay in lockstep (closes a confirmed divergence). NOT WIRED into consensus yet (the statem calls it in Slice C) — this bump is code-only; NO block-format change, plain rolling update when deployed. 0.6.22 = membership-safety Slice A (deferred.md §3 a+c): the consensus-side membership gate — a transaction touching peer_admitted must be EXACTLY one well-formed op (Id=:=Pk, binary) and must never EMPTY the committee (the permanent-wedge attack), enforced at both proposal seams (leader input + every validator before support-signing); also rejects non-list diffs (a poison block that would crash every node's commit fold). The committee stays a projection of the peer_admitted Prolog facts — this gate is pure arithmetic on the proposal; the per-node can_join re-proof (Prolog-side verdict) is the next slice. NO block-format change ⇒ a plain rolling update (no re-found / no volume wipe). 0.6.21 = per-ontology memory density (deferred.md §6): quod_ledger_store's per-slot in-RAM index (~54 B/slot, grew with block height without bound — THE fat behind the consensus process's ~6.5 MB) replaced by a sparse checkpoint index (8 B per 256 entries, ~32 KB per million slots) + ONE chunked read cursor; the boot committee re-fold and the KB replay now STREAM the log (never materialized in RAM; replay backpressured via a quod_prolog:sync barrier so a big rebuild can't flood the KB mailbox); store trust hardening from a max-effort review (log contiguous from index 1, per-frame CRC+index verification — never a silently wrong block, fold-beyond-tail fails loud, an open-time pread I/O error never truncates committed entries, corrupt frame-length capped). Consensus process measured 5.9 KB post-GC at slot 20001 (was ~1 MB and growing). In-RAM index only — ON-DISK FORMAT UNCHANGED ⇒ a plain rolling update (no re-found / no volume wipe). 0.6.20 = fast dead-peer detection (~2.5s, was ~80s): quod builds against a patched fork of the pure-Erlang quic library (netboz/erlang_quic) that fixes an RFC 9000 §10.1 bug (the idle timer was kept alive by our OWN sends, so a black-holed peer never timed out) + unlocks sub-second keep-alive; quod sets idle_timeout=2000ms / keepalive=500ms via config (node.idle_timeout_ms / node.keepalive_ms). Transport-only ⇒ NO block-format change ⇒ a plain rolling update (no re-found / no volume wipe). 0.6.19 = consensus dial self-heal: quod_simplex sweeps a per-peer dial marker that never resolved (neither link_up nor link_error — e.g. a connection that died mid-handshake) after a fixed ~15s, so the re-drive tick re-dials it instead of the peer staying silently unreachable forever. NO block-format change ⇒ a plain rolling update (no re-found / no volume wipe). 0.6.18 = feed_dropped split into per-reason counters (quod_feed_dropped{reason=duplicate|gap|unverified|non_following|oversized|ingest_busy}) so benign gossip redundancy is distinguishable from real drops. NO block-format change ⇒ a plain rolling update (no re-found / no volume wipe). 0.6.17 = same node image as 0.6.16 + the quod-brahms membership dashboard organized into the Grafana 'Quod' folder (deploy/grafana/quod-brahms-dashboard.json, provisioned via the loki-stack quod provider). 0.6.16 = Prometheus metrics buildout (quod_metrics: per-node node_id constant label + namespace/author labels; consensus submit/commit/skip/reject counters + in-flight pending; quod_prolog parked/park_timeouts; feed health; per-tx commit-latency/diff-size histograms + committed-by-author counter via the live {committed,Ns} event) + Grafana dashboard (deploy/grafana). Builds on 0.6.15 block/transaction timestamps. NOTE: 0.6.15's block fields change the genesis hash — coming from an older image (≤0.6.14) MUST re-found (wipe the quod-root/quod-join volumes)."
}

variable "join_count" {
  type        = number
  default     = 0
  description = "Number of mode=join follower nodes, beyond the single founder. Default 0: bring up the founder FIRST, read its genesis anchor from the boot log, then deploy joiners with `-var join_count=N -var genesis_hash=<hex>`."
}

variable "genesis_hash" {
  type        = string
  default     = ""
  description = "The founder's genesis block hash (64-char hex), copied from the founder's boot log line `quod[..]: genesis anchor — pin as content.genesis_hash: <hex>`. REQUIRED when join_count>0: it is the joiner's out-of-band trust anchor — a joiner verifies the whole downloaded history against this one pinned fingerprint, so a wrong/empty value makes it fail-fast (never a silent trust-on-first-use). Leave empty when join_count=0."
}

# ============================================================================
# quod — quod:root DispersedSimplex deploy: one founder + optional joiners.
#
#  - group "quod-root" (count 1, content.mode=create) founds quod:root as a
#    self-only 1-validator committee, applies its genesis, serves prove, and
#    LOGS its genesis anchor for joiners to pin.
#  - group "quod-join" (count var.join_count, content.mode=join) catches up the
#    founder's committed log TRUSTLESSLY (verifying every block's quorum cert
#    against the genesis anchor it was handed), then FOLLOWS live commits over
#    the dissemination feed (quod_feed) as a read-only observer. Discovers the
#    founder via the `quod` Consul service (p2p seed) and `quod-metrics` (a
#    `wait-for-root` prestart blocks until the founder's TCP metrics port is up).
#
# TWO-PHASE bring-up (the joiner's trust anchor is only known after the founder
# founds genesis, and must be pinned out-of-band — that is the whole point):
#   1. nomad job run deploy/quod.nomad                 # founder only (join_count=0)
#   2. nomad alloc logs <quod-root-alloc> | grep 'genesis anchor'   # copy the hex
#   3. nomad job run -var join_count=1 -var genesis_hash=<hex> deploy/quod.nomad
# A post-join write on the founder (e.g. a prove that asserts a fact) then
# demonstrates the live feed: the joiner picks the new block up over gossip.
#
# Networking — bridge + CNI portmap (NOT host mode). QUIC binds a FIXED
# in-container port (node.bind_port = 14567); Nomad maps a DYNAMIC host port and
# quod ADVERTISES that host port (node.port = ${NOMAD_HOST_PORT_p2p}) as its
# endpoint — identity is the Ed25519 pubkey, the address is only where it's dialed.
#
# Volumes — per_alloc CSI ceph RBD (`quod-root`, `quod-join`). The on-disk block
# log format changed with the de-Raft cleanup (#entry dropped its Raft term/kind
# fields), so any volume written by an older image (≤ 0.6.13) MUST be wiped:
#   nomad job stop -purge quod
#   nomad volume delete quod-root[0]        # and quod-join[0] if it exists
#   nomad volume create deploy/volumes/quod-root.hcl
#   nomad volume create deploy/volumes/quod-join.hcl
# ============================================================================
job "quod" {
  datacenters = ["qengho"]
  type        = "service"

  # Compute-class nodes (caton/corin/conrad); excludes the GPU node (prospero).
  constraint {
    attribute = "${node.class}"
    value     = "compute"
  }

  # ==========================================================================
  # Founder — mode=create. Founds quod:root, logs the genesis anchor.
  # ==========================================================================
  group "quod-root" {
    count = 1

    network {
      mode = "bridge"
      port "p2p" { to = 14567 }
      port "metrics" { to = 14568 }
    }

    volume "quod-data" {
      type            = "csi"
      source          = "quod-root"
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
      per_alloc       = true
    }

    task "quod" {
      driver = "docker"

      config {
        image      = "192.168.1.11:5000/quod:${var.image_tag}"
        force_pull = true
        ports      = ["p2p", "metrics"]
      }

      volume_mount {
        volume      = "quod-data"
        destination = "/quod/data"
        read_only   = false
      }

      template {
        data        = <<-EOT
node {
  ip        = "{{ env "attr.unique.network.ip-address" }}"
  port      = {{ env "NOMAD_HOST_PORT_p2p" }}
  bind_port = 14567
}
metrics { port = 14568 }
content {
  namespace    = "quod:root"
  mode         = create
  genesis_file = "ontologies/quod_root.pl"
  data_dir     = "/quod/data"
  seeds        = []
}
EOT
        destination = "${NOMAD_TASK_DIR}/quod.conf"
        change_mode = "noop"
      }

      template {
        data        = <<-EOT
QUOD_CONF={{ env "NOMAD_TASK_DIR" }}/quod.conf
EOT
        destination = "${NOMAD_TASK_DIR}/env"
        env         = true
        change_mode = "noop"
      }

      resources {
        cpu        = 500
        memory     = 256
        memory_max = 512
      }

      service {
        name = "quod"
        port = "p2p"
        tags = ["quod", "content", "quic", "p2p", "founder"]
      }

      service {
        name = "quod-metrics"
        port = "metrics"
        tags = ["quod", "metrics", "prometheus", "founder"]

        check {
          type     = "http"
          path     = "/metrics"
          interval = "15s"
          timeout  = "3s"
        }
      }

      kill_signal  = "SIGTERM"
      kill_timeout = "30s"
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "delay"
    }
  }

  # ==========================================================================
  # Joiners — mode=join. Trustless catch-up + live feed-follow (read-only).
  # Deployed only when join_count>0 AND genesis_hash is set (see the header).
  # ==========================================================================
  group "quod-join" {
    count = var.join_count

    spread {
      attribute = "${node.unique.name}"
    }

    network {
      mode = "bridge"
      port "p2p" { to = 14567 }
      port "metrics" { to = 14568 }
    }

    volume "quod-data" {
      type            = "csi"
      source          = "quod-join"
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
      per_alloc       = true
    }

    # Block startup until the founder is up. We probe its TCP METRICS port (via the
    # `quod-metrics` Consul service), NOT the p2p port: p2p is QUIC-over-UDP and a TCP
    # scan (`nc -z`) can never connect to it — the founder's own QUIC dial + retry is
    # what validates p2p reachability. A live metrics port means the BEAM booted and the
    # namespace is up, which is exactly the "founder ready" signal we want to gate on.
    task "wait-for-root" {
      driver = "docker"

      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      template {
        data        = <<-EOT
{{- range service "quod-metrics" }}
QUOD_ROOT_HOST={{ .Address }}
QUOD_ROOT_METRICS_PORT={{ .Port }}
{{- end }}
EOT
        destination = "${NOMAD_TASK_DIR}/root.env"
        env         = true
        change_mode = "noop"
      }

      config {
        image   = "alpine:3.19"
        command = "sh"
        args = [
          "-c",
          "echo \"waiting for quod founder metrics at $${QUOD_ROOT_HOST}:$${QUOD_ROOT_METRICS_PORT}...\"; while [ -z \"$${QUOD_ROOT_HOST}\" ] || ! nc -z -w2 \"$${QUOD_ROOT_HOST}\" \"$${QUOD_ROOT_METRICS_PORT}\" 2>/dev/null; do echo 'founder not ready, sleeping 2s'; sleep 2; done; echo \"founder up, proceeding\""
        ]
      }

      resources {
        cpu    = 100
        memory = 32
      }
    }

    task "quod" {
      driver = "docker"

      config {
        image      = "192.168.1.11:5000/quod:${var.image_tag}"
        force_pull = true
        ports      = ["p2p", "metrics"]
      }

      volume_mount {
        volume      = "quod-data"
        destination = "/quod/data"
        read_only   = false
      }

      template {
        data        = <<-EOT
node {
  ip        = "{{ env "attr.unique.network.ip-address" }}"
  port      = {{ env "NOMAD_HOST_PORT_p2p" }}
  bind_port = 14567
}
metrics { port = 14568 }
content {
  namespace    = "quod:root"
  mode         = join
  data_dir     = "/quod/data"
{{- range service "quod" }}
  seeds        = ["{{ .Address }}:{{ .Port }}"]
{{- end }}
  genesis_hash = "${var.genesis_hash}"
}
EOT
        destination = "${NOMAD_TASK_DIR}/quod.conf"
        change_mode = "noop"
      }

      template {
        data        = <<-EOT
QUOD_CONF={{ env "NOMAD_TASK_DIR" }}/quod.conf
EOT
        destination = "${NOMAD_TASK_DIR}/env"
        env         = true
        change_mode = "noop"
      }

      resources {
        cpu        = 500
        memory     = 256
        memory_max = 512
      }

      service {
        name = "quod-join"
        port = "p2p"
        tags = ["quod", "content", "quic", "p2p", "join"]
      }

      service {
        name = "quod-metrics"
        port = "metrics"
        tags = ["quod", "metrics", "prometheus", "join"]

        check {
          type     = "http"
          path     = "/metrics"
          interval = "15s"
          timeout  = "3s"
        }
      }

      kill_signal  = "SIGTERM"
      kill_timeout = "30s"
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "delay"
    }
  }

  update {
    max_parallel     = 1
    min_healthy_time = "15s"
    healthy_deadline = "3m"
    auto_revert      = false
  }
}
