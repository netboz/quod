#!/usr/bin/env bash
#
# Controlled >f outage validation for voting readiness and evidence-driven finality recovery.
#
# Reproduces the slot-713 incident on the LIVE fleet against a QUIESCENT, caught-up committee — the exact
# path scripts/loadtest.sh cannot force (it self-defers over-f under load):
#   1. take f+1 compute validators DOWN (over-f: a certificate quorum is impossible);
#   2. submit ONE write -> the surviving leader proposes it at H+1, the survivors support-sign, and
#      complaint signing PAUSES (quod_consensus_quorum_pauses climbs while the slot stays at H);
#   3. bring the down nodes back;
#   4. assert the interrupted slot RESOLVES (commit or evidence-driven skip), then commit a fresh write.
#
# `quod_consensus_skips` identifies which safe finality camp won; it is not itself a failure signal. If
# enough validators durably chose complaint, skipping is the only safe resolution and the interrupted write
# must be retried. The final continuation write is therefore the liveness discriminator in both outcomes.
#
# Side effects: `nomad alloc restart` on f+1 compute validators, and TWO `POST /api/prove` writes. Reads
# go through /metrics + the explorer /api/* HTTP surface — no `nomad alloc exec`. qengho is a TEST cluster.
# Needs: nomad CLI (NOMAD_ADDR reachable), curl, python3.
#
set -uo pipefail

: "${NOMAD_ADDR:=http://192.168.1.10:4646}"
: "${NS:=quod:root}"
: "${OVERF_N:=4}"          # validators to take down (f+1 at N=10, f=3, quorum=7)
: "${OBSERVE_S:=50}"       # seconds to watch for the over-f pause precondition
: "${RECOVER_S:=240}"      # max seconds to wait for the downed nodes to reboot + the fleet to reconverge
export NOMAD_ADDR

STAMP(){ date +%H:%M:%S; }
LOG(){ echo "[$(STAMP)] $*"; }
die(){ LOG "FATAL: $*"; exit 2; }

command -v nomad  >/dev/null || die "nomad CLI not found"
command -v curl   >/dev/null || die "curl not found"
command -v python3>/dev/null || die "python3 not found"

addr_of(){ # $1 alloc, $2 label -> host:port
  nomad alloc status "$1" 2>/dev/null | awk -v l="$2" '$0 ~ l && /->/ {print $3; exit}'
}
# scrape one node's /metrics -> "slot skips pauses ready nodeid"  (blank fields if unreachable)
scrape(){
  local m; m=$(curl -s --max-time 4 "http://$1/metrics" 2>/dev/null) || return 1
  [ -z "$m" ] && return 1
  local slot skips pauses ready nid
  slot=$(awk '/^quod_consensus_slot\{/{print $2; exit}'               <<<"$m")
  skips=$(awk '/^quod_consensus_skips\{/{print $2; exit}'             <<<"$m")
  pauses=$(awk '/^quod_consensus_quorum_pauses\{/{print $2; exit}'    <<<"$m")
  ready=$(awk '/^quod_consensus_progress_quorum_ready\{/{print $2; exit}' <<<"$m")
  nid=$(sed -n 's/.*node_id="\(kp_[0-9a-f]*\)".*/\1/p' <<<"$m" | head -1)
  echo "${slot:-} ${skips:-} ${pauses:-} ${ready:-} ${nid:-}"
}

# ---- enumerate the 8 compute (quod-node) validators; the 2 cloud validators stay up + untouched ----
LOG "enumerating compute validators (quod-node group)..."
mapfile -t COMPUTE < <(nomad job status quod | awk '/quod-node/ && /running/ {print $1}')
[ "${#COMPUTE[@]}" -ge "$((OVERF_N + 1))" ] || die "need >= $((OVERF_N+1)) compute allocs, found ${#COMPUTE[@]}"

declare -A MET EXP NID
for a in "${COMPUTE[@]}"; do
  MET[$a]=$(addr_of "$a" metrics)
  EXP[$a]=$(addr_of "$a" explorer)
  read -r _ _ _ _ nid <<<"$(scrape "${MET[$a]}")"
  NID[$a]="$nid"
  LOG "  $a  node=$nid  metrics=${MET[$a]}  explorer=${EXP[$a]}"
done

# ---- baseline: height + leader of H+1, require a quiescent, converged fleet ----
FIRST_EXP=""
for a in "${COMPUTE[@]}"; do [ -n "${EXP[$a]}" ] && { FIRST_EXP="${EXP[$a]}"; break; }; done
[ -n "$FIRST_EXP" ] || die "no reachable explorer"

SUMMARY=$(curl -s --max-time 6 "http://$FIRST_EXP/api/summary") || die "summary fetch failed"
read -r H LEADER < <(printf '%s' "$SUMMARY" | python3 -c '
import sys, json
ns = sys.argv[1]
d = json.load(sys.stdin)
n = next(x for x in d["namespaces"] if x["ns"] == ns)
np = n.get("next_proposer") or {}
print(n["height"], (np.get("id") if isinstance(np, dict) else np) or "none")
' "$NS")
[ -n "$H" ] || die "could not read height"
LOG "baseline: height H=$H, leader(H+1)=$LEADER, committee=10 (f=3 quorum=7)"

# confirm every compute node sits at H (quiescent + converged) and snapshot skips
declare -A BASE_SKIPS BASE_PAUSES
CONVERGED=1
for a in "${COMPUTE[@]}"; do
  read -r slot skips pauses _ _ <<<"$(scrape "${MET[$a]}")"
  BASE_SKIPS[$a]="${skips:-0}"
  BASE_PAUSES[$a]="${pauses:-0}"
  [ "${slot:-x}" = "$H" ] || { LOG "  WARN $a at slot ${slot:-?} != $H"; CONVERGED=0; }
done
[ "$CONVERGED" = 1 ] || die "fleet not converged/quiescent at H=$H — retry when idle"

# ---- choose the kill set (compute, excluding the H+1 leader) and a prober that stays up ----
KILL=(); SURV=()
for a in "${COMPUTE[@]}"; do
  if [ "${NID[$a]}" = "$LEADER" ]; then SURV+=("$a"); continue; fi
  if [ "${#KILL[@]}" -lt "$OVERF_N" ]; then KILL+=("$a"); else SURV+=("$a"); fi
done
[ "${#KILL[@]}" -eq "$OVERF_N" ] || die "could not select $OVERF_N non-leader victims"

# prober = the leader's node if it is a reachable compute survivor, else any compute survivor (relay)
PROBER_EXP=""
for a in "${SURV[@]}"; do [ "${NID[$a]}" = "$LEADER" ] && [ -n "${EXP[$a]}" ] && PROBER_EXP="${EXP[$a]}"; done
[ -z "$PROBER_EXP" ] && for a in "${SURV[@]}"; do [ -n "${EXP[$a]}" ] && { PROBER_EXP="${EXP[$a]}"; break; }; done
[ -n "$PROBER_EXP" ] || die "no reachable survivor explorer to submit through"

LOG "kill set (over-f): ${KILL[*]}"
LOG "survivors (stay up): ${SURV[*]} + 2 cloud"
LOG "write submitted via: $PROBER_EXP"

UNIQ=$(( $(date +%s) % 1000000 ))
WOUT=$(mktemp)

# ---- step 1: take f+1 down (SIGKILL for an immediate, simultaneous outage — `restart` drains
#      gracefully, leaving the victims up + voting long enough for the write to commit at full quorum) ----
LOG "STEP 1 — hard-killing $OVERF_N compute validators (over-f outage begins)..."
for a in "${KILL[@]}"; do ( nomad alloc signal -s SIGKILL "$a" quod >/dev/null 2>&1 \
                            || nomad alloc restart "$a" >/dev/null 2>&1 ) & done

# ---- step 1b: WAIT until every victim is actually unreachable, so the write below is submitted while a
#      certificate quorum is genuinely impossible (6 up < 7). Submitting before they drop lets it commit
#      normally and proves nothing. ----
LOG "STEP 1b — waiting for the $OVERF_N victims to go down (quorum must become impossible)..."
alldown=0
for _ in $(seq 1 60); do
  n_up=0
  for a in "${KILL[@]}"; do curl -s --max-time 2 "http://${MET[$a]}/metrics" >/dev/null 2>&1 && n_up=$((n_up+1)); done
  [ "$n_up" -eq 0 ] && { alldown=1; break; }
  sleep 1
done
[ "$alldown" = 1 ] && LOG "  all $OVERF_N victims down — quorum now impossible (6 up < 7)" \
                   || LOG "  WARN: victims did not all drop together; proceeding (result may be inconclusive)"

# ---- step 2: submit ONE write NOW, into the outage (async; parks until commit, may 503) ----
LOG "STEP 2 — submitting write assertz(overf_probe($UNIQ)) into the outage..."
( curl -s --max-time "$RECOVER_S" -X POST "http://$PROBER_EXP/api/prove" \
    -H 'content-type: application/json' \
    -d "{\"ns\":\"$NS\",\"goal\":\"assertz(overf_probe($UNIQ)).\"}" > "$WOUT" 2>&1 ) &
WRITE_PID=$!

# ---- observe the pause precondition: survivors support-signed + stalled, slot held, skips flat ----
LOG "OBSERVING over-f window (${OBSERVE_S}s): expect quorum_pauses to climb while slot stays $H..."
PAUSE_SEEN=0; MAX_PAUSE_DELTA=0; SKIP_DURING=0
for _ in $(seq 1 "$OBSERVE_S"); do
  for a in "${SURV[@]}"; do
    read -r slot skips pauses ready _ <<<"$(scrape "${MET[$a]}")"
    [ -z "${pauses:-}" ] && continue
    # pause precondition: this survivor is stalled at H with a pause counter above its baseline
    delta=$(( ${pauses:-0} - ${BASE_PAUSES[$a]:-0} ))
    if [ "${slot:-x}" = "$H" ] && [ "$delta" -gt 0 ]; then
      PAUSE_SEEN=1
      [ "$delta" -gt "$MAX_PAUSE_DELTA" ] && MAX_PAUSE_DELTA="$delta"
    fi
    [ "${skips:-0}" -gt "${BASE_SKIPS[$a]:-0}" ] && SKIP_DURING=1
  done
  # stop early once quorum is clearly restored (a survivor sees quorum_ready=1 and slot moved past H)
  moved=0
  for a in "${SURV[@]}"; do read -r slot _ _ _ _ <<<"$(scrape "${MET[$a]}")"; [ "${slot:-0}" -gt "$H" ] && moved=1; done
  [ "$moved" = 1 ] && { LOG "  slot advanced past $H — quorum restored, ending observation"; break; }
  sleep 1
done
LOG "  pause precondition observed: $([ $PAUSE_SEEN = 1 ] && echo YES || echo NO) (peak quorum_pauses=$MAX_PAUSE_DELTA), skip-during-outage: $([ $SKIP_DURING = 1 ] && echo YES || echo no)"

# ---- step 3: wait for the downed nodes to reboot + the whole fleet to reconverge ----
LOG "STEP 3 — waiting up to ${RECOVER_S}s for reboot + reconvergence..."
FINAL_H=""; t=0
while [ "$t" -lt "$RECOVER_S" ]; do
  vals=(); ok=1
  for a in "${COMPUTE[@]}"; do
    read -r slot _ _ _ _ <<<"$(scrape "${MET[$a]}")"
    [ -z "${slot:-}" ] && { ok=0; break; }
    vals+=("$slot")
  done
  if [ "$ok" = 1 ]; then
    mn=$(printf '%s\n' "${vals[@]}" | sort -n | head -1)
    mx=$(printf '%s\n' "${vals[@]}" | sort -n | tail -1)
    if [ "$mn" = "$mx" ] && [ "$mn" -gt "$H" ]; then FINAL_H="$mn"; break; fi
  fi
  sleep 3; t=$((t+3))
done
[ -n "$FINAL_H" ] || { LOG "WARN: fleet did not fully reconverge above H within ${RECOVER_S}s"; }

# ---- step 4: outcome ----
NET_SKIPS=0
for a in "${COMPUTE[@]}"; do
  read -r _ skips _ _ _ <<<"$(scrape "${MET[$a]}")"
  d=$(( ${skips:-0} - ${BASE_SKIPS[$a]:-0} )); [ "$d" -gt 0 ] && NET_SKIPS=$((NET_SKIPS + d))
done

# Did the interrupted write itself commit? A safe skip normally leaves it absent.
FACT="unknown"
RESP=$(curl -s --max-time 8 -X POST "http://$PROBER_EXP/api/prove" \
        -H 'content-type: application/json' \
        -d "{\"ns\":\"$NS\",\"goal\":\"overf_probe($UNIQ).\"}" 2>/dev/null)
echo "$RESP" | grep -qi '"result":"ok"' && FACT="present" || FACT="absent"

wait "$WRITE_PID" 2>/dev/null || true
WRITE_RESP=$(head -c 300 "$WOUT"); rm -f "$WOUT"

# Whichever finality camp won H+1, a fresh transaction must commit afterward. This distinguishes a safely
# resolved skip from a cluster that merely moved one metric while remaining unable to process work.
CONT_UNIQ=$((UNIQ + 1000000))
CONT_FACT="unknown"; CONT_RESP="<not submitted>"
if [ -n "$FINAL_H" ]; then
  LOG "STEP 4 — proving continuation with assertz(overf_continue($CONT_UNIQ))..."
  CONT_RESP=$(curl -s --max-time 45 -X POST "http://$PROBER_EXP/api/prove" \
      -H 'content-type: application/json' \
      -d "{\"ns\":\"$NS\",\"goal\":\"assertz(overf_continue($CONT_UNIQ)).\"}" 2>/dev/null)
  CONT_FACT="absent"
  for _ in $(seq 1 20); do
    Q=$(curl -s --max-time 8 -X POST "http://$PROBER_EXP/api/prove" \
          -H 'content-type: application/json' \
          -d "{\"ns\":\"$NS\",\"goal\":\"overf_continue($CONT_UNIQ).\"}" 2>/dev/null)
    echo "$Q" | grep -qi '"result":"ok"' && { CONT_FACT="present"; break; }
    sleep 1
  done
fi

if [ "$NET_SKIPS" -gt 0 ]; then
  HEAD_OUTCOME="safely skipped"
elif [ "$FACT" = "present" ]; then
  HEAD_OUTCOME="committed"
else
  HEAD_OUTCOME="unclear"
fi

echo
LOG "================= RESULT (over-f recovery, N=10 f=3) ================="
LOG "baseline height            : $H"
LOG "leader(H+1) kept up         : $LEADER"
LOG "validators taken down       : $OVERF_N (quorum 7 impossible with 6 up)"
LOG "over-f pause precondition   : $([ $PAUSE_SEEN = 1 ] && echo 'observed (survivors stalled at H, complaints paused)' || echo 'NOT observed (window too short — inconclusive)')"
LOG "peak quorum_pauses (surv)   : $MAX_PAUSE_DELTA"
LOG "final converged height      : ${FINAL_H:-<not converged>}"
LOG "net skips across fleet      : $NET_SKIPS"
LOG "interrupted-slot outcome    : $HEAD_OUTCOME"
LOG "written fact overf_probe    : $FACT"
LOG "original write response     : ${WRITE_RESP:-<none>}"
LOG "continuation fact           : $CONT_FACT"
LOG "continuation response       : ${CONT_RESP:0:300}"
LOG "====================================================================="

if [ "$PAUSE_SEEN" != 1 ]; then
  LOG "VERDICT: INCONCLUSIVE — the over-f stall was not actually exercised (nodes recovered too fast)."
  exit 3
elif [ -n "$FINAL_H" ] && [ "$HEAD_OUTCOME" != "unclear" ] && [ "$CONT_FACT" = "present" ]; then
  LOG "VERDICT: PASS — the interrupted slot $HEAD_OUTCOME and a fresh transaction committed afterward."
  exit 0
else
  LOG "VERDICT: UNCLEAR — recovery did not prove both slot resolution and subsequent transaction progress."
  exit 4
fi
