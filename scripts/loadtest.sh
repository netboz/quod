#!/usr/bin/env bash
#
# quod fleet load + chaos test — a parameterized, rerunnable driver.
#
# Scales the Nomad `quod` job to a target size, drives a sustained (jittered) +
# occasionally-bursty transaction load at the founder, and randomly churns
# joiner nodes (single restarts up to a simultaneous mass departure), while
# continuously monitoring the fleet. At the end it stops the load, waits for the
# fleet to reconverge, and prints a PASS/FAIL verdict against the invariants that
# actually matter: no unverified gossip (safety), every node reconverged to one
# height (liveness), the ledger advanced by a meaningful amount (the load landed),
# and nothing is failed/lost (stability).
#
# Everything is a parameter (env-overridable) — see the CONFIG block. Defaults
# climb to 30 nodes for ~15 min. The founder is NEVER churned (it is the sole
# voter at N=1; taking it down halts consensus and kills the writer) — only
# joiners come and go.
#
#   scripts/loadtest.sh                 # defaults (30 nodes, 15 min)
#   NODES=8 DURATION=180 scripts/loadtest.sh
#   NODES=30 CHURN_MAX=15 BURST_SIZE=60 DURATION=1800 scripts/loadtest.sh
#
# Needs: nomad CLI (NOMAD_ADDR reachable), jq, curl. Run from anywhere in the repo.
#
set -uo pipefail

#==============================================================================
# CONFIG (all env-overridable)
#==============================================================================
: "${NOMAD_ADDR:=http://192.168.1.10:4646}"
: "${JOB:=quod}"
: "${NS:=quod:root}"
: "${IMAGE_TAG:=0.6.27}"
: "${GENESIS_HASH:=2A5DF06608FE9CC9FE0CC48B1668D74164D26FEF4A5EF5A8F5C0C84FD20426B9}"
: "${NOMAD_FILE:=deploy/quod.nomad}"        # relative to repo root

: "${NODES:=30}"                            # total nodes = 1 founder + (NODES-1) joiners
: "${DURATION:=900}"                        # total chaos window, seconds
: "${WARMUP:=45}"                           # let cold joiners catch up before churn starts, seconds

# sustained transaction load (runs on the founder, autonomous)
: "${TX_BASE_MS:=120}"                      # base delay between writes
: "${TX_JITTER_MS:=180}"                    # + a random 0..JITTER ms per write (random pacing)

# bursts (fired from here during the chaos loop)
: "${BURST_PROB:=35}"                       # % chance, each chaos tick, of a burst
: "${BURST_SIZE:=40}"                       # concurrent one-shot submits per burst (stresses backpressure)

# churn (joiners restart = disconnect -> reboot -> reconnect -> catch up)
: "${CHURN_PROB:=55}"                       # % chance, each chaos tick, of a churn event
: "${CHURN_MAX:=15}"                        # up to this many joiners restarted AT ONCE (mass departure)
: "${MASS_PROB:=20}"                        # % of churn events that are a full CHURN_MAX mass departure

: "${TICK:=15}"                             # chaos + log cadence, seconds
: "${UNV_POLL:=3}"                          # unverified-drop poll cadence (< churn cadence: the drop gauge
                                            #   resets on a node restart, so sample it faster than we churn)
: "${LAG_OK:=50}"                           # final height spread that counts as "reconverged"
: "${SETTLE_TRIES:=48}"                      # reconvergence patience after load stops (x5s; 48 = 4 min)
: "${MIN_ADVANCE:=}"                        # min committed-height gain to prove the load landed (default: DURATION/4)
: "${SCALE:=1}"                             # 1 = (re)deploy to NODES first; 0 = use the fleet as-is

export NOMAD_ADDR
WRITER=loadtest_writer                      # registered process name on the founder
[ -z "$MIN_ADVANCE" ] && MIN_ADVANCE=$(( DURATION / 4 ))
STAMP() { date +%H:%M:%S; }
LOG()   { echo "[$(STAMP)] $*"; }
# bounded exec into a node's BEAM (never hang the driver on an unresponsive alloc)
QEVAL() { timeout 20 nomad alloc exec "$1" /opt/quod/bin/quod eval "$2" 2>/dev/null; }

#==============================================================================
# fleet discovery (JSON — no dependence on nomad's human table format / subnet)
#==============================================================================
allocs() { nomad job status "$JOB" 2>/dev/null | awk -v g="$1" '$0 ~ g" " && / running /{print $1}'; }
founder() { allocs quod-root | head -1; }

# "allocid host:port" for every running alloc's metrics endpoint (parallel)
endpoints() {
  { allocs quod-root; allocs quod-join; } | xargs -P 16 -I{} sh -c '
    hp=$(nomad alloc status -json {} 2>/dev/null \
         | jq -r ".AllocatedResources.Shared.Ports[]? | select(.Label==\"metrics\") | \"\(.HostIP):\(.Value)\"" 2>/dev/null | head -1)
    [ -n "$hp" ] && echo "{} $hp"'
}
failed_allocs() {   # count allocs currently failed/lost (0 = healthy)
  nomad operator api "/v1/job/$JOB/allocations" 2>/dev/null \
    | jq '[.[] | select(.ClientStatus=="failed" or .ClientStatus=="lost")] | length' 2>/dev/null || echo 0
}

# scrape one endpoint -> "slot unverified membership_rejects" (missing -> "-1 0 0")
scrape() {
  curl -s --max-time 4 "http://$1/metrics" 2>/dev/null | awk '
    /^quod_consensus_slot\{/                     {slot=$2}
    /^quod_feed_dropped\{.*reason="unverified"/  {unv+=$2}
    /^quod_consensus_membership_rejects\{/       {mr+=$2}
    END { printf "%d %d %d\n", (slot==""?-1:slot), unv+0, mr+0 }'
}
# re-entry hook: parallel scrape workers re-exec THIS script. Must sit AFTER the fn
# defs and BEFORE any fleet side effect (scale/writer/churn) — verified airtight.
[ "${1:-}" = "_scrape_one" ] && { scrape "$2"; exit 0; }

#==============================================================================
# load control (founder-side)
#==============================================================================
start_writer() {
  local f code
  f=$(founder); [ -z "$f" ] && { LOG "FATAL: no founder alloc"; exit 1; }
  # kill any prior writer and WAIT for the name to free before spawn+register (exit/2 is
  # async; registering while the old name lingers throws and orphans the new loop). Then a
  # registered self-pacing loop: assert a unique junk fact, sleep base + random jitter, repeat.
  printf -v code 'W = %s, (fun K() -> case whereis(W) of undefined -> ok; O -> exit(O, kill), timer:sleep(30), K() end end)(), P = spawn(fun Loop() -> _ = (catch quod_prolog:prove(<<"%s">>, {assertz, {loadtest, erlang:unique_integer([positive])}}, <<"%s">>)), timer:sleep(%d + rand:uniform(%d)), Loop() end), register(W, P), {writer_started, P}.' \
    "$WRITER" "$NS" "$NS" "$TX_BASE_MS" "$((TX_JITTER_MS + 1))"
  LOG "starting sustained writer on founder $f (base=${TX_BASE_MS}ms jitter=0..${TX_JITTER_MS}ms): $(QEVAL "$f" "$code")"
}

stop_writer() {
  local f out
  f=$(founder)
  [ -z "$f" ] && { LOG "WARN: no founder alloc reachable — writer may be ORPHANED, check manually"; return 0; }
  out=$(QEVAL "$f" "case whereis($WRITER) of undefined -> already_stopped; P -> exit(P, kill), stopped end.")
  case "$out" in
    *stopped*) LOG "writer stopped ($out)"; return 0;;
    *) LOG "WARN: writer stop unconfirmed (got '${out:-<timeout>}') — retrying"; sleep 1
       out=$(QEVAL "$f" "case whereis($WRITER) of undefined -> already_stopped; P -> exit(P, kill), stopped end.")
       case "$out" in
         *stopped*) LOG "writer stopped on retry ($out)";;
         *) LOG "ERROR: could not confirm writer stopped on $f — stop it manually: nomad alloc exec $f /opt/quod/bin/quod eval 'exit(whereis($WRITER),kill).'";;
       esac;;
  esac
}

burst() {
  local f; f=$(founder); [ -z "$f" ] && return 0
  # BURST_SIZE concurrent one-shot submits: most bounce off {error,busy} (backpressure), a few land.
  QEVAL "$f" "[spawn(fun() -> catch quod_prolog:prove(<<\"$NS\">>, {assertz, {burst, erlang:unique_integer([positive])}}, <<\"$NS\">>) end) || _ <- lists:seq(1, $BURST_SIZE)], ok." >/dev/null
  LOG "BURST: $BURST_SIZE concurrent submits"
}

#==============================================================================
# chaos: churn joiners (never the founder)
#==============================================================================
CHURN_PID=""
churn() {
  # do not overlap mass restarts (would exceed CHURN_MAX concurrent)
  if [ -n "$CHURN_PID" ] && kill -0 "$CHURN_PID" 2>/dev/null; then LOG "churn: previous restart still in flight, skipping"; return 0; fi
  local n ids pick
  mapfile -t ids < <(allocs quod-join)
  [ "${#ids[@]}" -eq 0 ] && { LOG "churn: no joiners"; return 0; }
  if [ "$((RANDOM % 100))" -lt "$MASS_PROB" ]; then n=$CHURN_MAX; else n=$(( 1 + RANDOM % 3 )); fi
  [ "$n" -gt "${#ids[@]}" ] && n=${#ids[@]}
  pick=$(printf '%s\n' "${ids[@]}" | shuf | head -n "$n")
  LOG "CHURN: restarting $n joiner(s) simultaneously"
  echo "$pick" | xargs -P "$CHURN_MAX" -I{} nomad alloc restart {} >/dev/null 2>&1 &
  CHURN_PID=$!
}

#==============================================================================
# monitor
#==============================================================================
EPFILE=$(mktemp)                            # cached endpoints for the fast unverified poll
WORST_LAG=0; MAX_UNVERIFIED=0; MAX_REJECTS=0

refresh_endpoints() { endpoints > "$EPFILE"; }

# one full snapshot -> "caught_up min max lag unverified rejects", where caught_up counts only nodes
# reporting a REAL height (a restarting/catching-up node scrapes as -1 and is excluded from min/max/lag,
# so the lag shown is the true spread among the healthy nodes; the rest are churning/catching up).
# PURE (runs in a $(...) subshell, so it must NOT mutate the accumulators — the caller does that in the
# main shell after reading the line, else the updates are lost).
snapshot() {
  local rows caught up_slots mins maxs unv mr lag
  rows=$(awk '{print $2}' "$EPFILE" | xargs -P 16 -I{} bash "$0" _scrape_one {} 2>/dev/null)
  up_slots=$(printf '%s\n' "$rows" | awk '$1>=0{print $1}')
  caught=$(printf '%s\n' "$up_slots" | grep -c .)
  unv=$(printf '%s\n' "$rows" | awk '{s+=$2} END{print s+0}')
  mr=$(printf '%s\n' "$rows" | awk '{s+=$3} END{print s+0}')
  if [ "$caught" -eq 0 ]; then echo "0 -1 -1 999999 $unv $mr"; return; fi
  mins=$(printf '%s\n' "$up_slots" | sort -n | head -1)
  maxs=$(printf '%s\n' "$up_slots" | sort -n | tail -1)
  echo "$caught $mins $maxs $(( maxs - mins )) $unv $mr"
}
# fold a snapshot line's stats into the run-wide accumulators (call in the MAIN shell)
accumulate() {   # $1=caught_up $2=lag $3=unverified $4=rejects
  [ "$1" -ge 2 ] && [ "$2" -gt "$WORST_LAG" ] && WORST_LAG=$2
  [ "$3" -gt "$MAX_UNVERIFIED" ] && MAX_UNVERIFIED=$3
  [ "$4" -gt "$MAX_REJECTS" ] && MAX_REJECTS=$4
}

# fast, cheap unverified-only poll from the cached endpoints (shrinks the gauge-reset blind spot)
poll_unverified() {
  local u
  u=$(awk '{print $2}' "$EPFILE" | xargs -P 16 -I{} bash "$0" _scrape_one {} 2>/dev/null | awk '{s+=$2} END{print s+0}')
  [ "${u:-0}" -gt "$MAX_UNVERIFIED" ] && MAX_UNVERIFIED=$u
}

#==============================================================================
# run
#==============================================================================
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 1
command -v jq >/dev/null || { echo "FATAL: jq required"; exit 1; }
trap 'echo; LOG "interrupted — stopping writer"; stop_writer; exit 130' INT TERM
trap 'stop_writer; rm -f "$EPFILE"' EXIT

LOG "=== quod load+chaos :: NODES=$NODES DURATION=${DURATION}s tag=$IMAGE_TAG min_advance=$MIN_ADVANCE ==="

if [ "$SCALE" = "1" ]; then
  LOG "scaling job to $NODES nodes (join_count=$((NODES-1)))..."
  nomad job run -var image_tag="$IMAGE_TAG" -var join_count=$((NODES-1)) -var genesis_hash="$GENESIS_HASH" "$NOMAD_FILE" 2>&1 | tail -3
fi

LOG "warmup ${WARMUP}s (cold joiners catch up)..."; sleep "$WARMUP"
refresh_endpoints
read -r n0 min0 max0 _ <<<"$(snapshot)"
LOG "start: nodes=$n0 slot_min=$min0 slot_max=$max0"
START_SLOT=$max0

start_writer

polls=$(( TICK / UNV_POLL )); [ "$polls" -lt 1 ] && polls=1
END=$(( $(date +%s) + DURATION )); tick=0
while [ "$(date +%s)" -lt "$END" ]; do
  tick=$((tick+1))
  [ "$((RANDOM % 100))" -lt "$BURST_PROB" ] && burst
  [ "$((RANDOM % 100))" -lt "$CHURN_PROB" ] && churn
  refresh_endpoints
  read -r n mn mx lag unv mr <<<"$(snapshot)"
  accumulate "$n" "$lag" "$unv" "$mr"
  LOG "tick $tick: caught_up=$n/$NODES churning=$((NODES-n)) slot=$mn..$mx lag=$lag unverified=$unv rejects=$mr"
  for _ in $(seq 1 "$polls"); do sleep "$UNV_POLL"; poll_unverified; done   # fast unverified poll across the interval
done

LOG "chaos window over — stopping load, waiting for churn to settle + reconvergence..."
stop_writer
[ -n "$CHURN_PID" ] && wait "$CHURN_PID" 2>/dev/null   # let the last mass restart finish before judging

converged=0; n=0; mx=$START_SLOT
for _ in $(seq 1 "$SETTLE_TRIES"); do
  refresh_endpoints
  read -r n mn mx lag unv mr <<<"$(snapshot)"
  accumulate "$n" "$lag" "$unv" "$mr"
  LOG "settle: caught_up=$n/$NODES slot=$mn..$mx lag=$lag unverified=$unv"
  if [ "$n" -eq "$NODES" ] && [ "$mn" -ge 0 ] && [ "$lag" -le "$LAG_OK" ]; then converged=1; break; fi
  sleep 5
done
END_SLOT=$mx

#==============================================================================
# verdict
#==============================================================================
FAILED=0
FAILEDALLOCS=$(failed_allocs)
ADVANCE=$(( END_SLOT - START_SLOT ))
echo
LOG "================= RESULT ================="
LOG "nodes caught up at end : $n / $NODES";                  [ "$n" -eq "$NODES" ]              || { LOG "  FAIL: not all nodes caught up"; FAILED=1; }
LOG "reconverged (lag<=$LAG_OK) : $([ "$converged" = 1 ] && echo yes || echo NO)"; [ "$converged" = 1 ] || { LOG "  FAIL: fleet did not reconverge"; FAILED=1; }
LOG "ledger advanced        : +$ADVANCE (>= $MIN_ADVANCE required)"; [ "$ADVANCE" -ge "$MIN_ADVANCE" ] || { LOG "  FAIL: too few commits (sustained load did not land)"; FAILED=1; }
LOG "unverified drops (max) : $MAX_UNVERIFIED";              [ "$MAX_UNVERIFIED" -eq 0 ]        || { LOG "  FAIL: unverified gossip observed (safety!)"; FAILED=1; }
LOG "membership rejects(max): $MAX_REJECTS  (expected 0 — no membership churn in this test)"
LOG "worst height spread    : $WORST_LAG (during chaos — informational)"
LOG "failed/lost allocs     : $FAILEDALLOCS";                [ "$FAILEDALLOCS" -eq 0 ]          || { LOG "  FAIL: allocs failed/lost"; FAILED=1; }
LOG "========================================="
LOG "note: the unverified gauge resets on a node restart; it is sampled every ${UNV_POLL}s (< churn"
LOG "      cadence) to shrink but not eliminate that blind spot. A transient recovered crash between"
LOG "      snapshots is likewise not counted — a PERSISTENT crash-loop still fails via non-reconvergence."
[ "$FAILED" -eq 0 ] && { LOG "PASS"; exit 0; } || { LOG "FAIL"; exit 1; }
