#!/usr/bin/env bash
#
# quod fleet load + chaos test — a parameterized, rerunnable driver (MULTI-VALIDATOR).
#
# Drives a sustained (jittered) + occasionally-bursty transaction load across the
# DispersedSimplex committee, and randomly churns nodes — classifying each as a
# VALIDATOR (votes) or an OBSERVER (follows the feed) — while continuously
# monitoring the fleet. At the end it stops the load, waits for the fleet to
# reconverge, and prints a PASS/FAIL verdict against the invariants that matter
# at N>=4: no unverified gossip (safety), every node reconverged to one height
# (liveness), the ledger advanced (the load landed), the committee stayed intact
# (no spurious membership change, is_validator stable, weak-cert waits drained),
# and nothing is failed/lost (stability).
#
# WHY THIS IS NOT THE OLD N=1 DRIVER:
#   * Writes are LEADER-AWARE. At N=4 the founder leads only 1/4 of slots, so a
#     founder-only fire-and-forget writer would bounce ~3/4 of writes off
#     {error,{not_leader,_}} and silently drop them. There is no cross-alloc
#     Erlang distribution (nodes speak QUIC only) and no leader-forwarding, so a
#     writer MUST run in-BEAM on a validator and land only when that node leads.
#     We therefore run a bounded-retry writer on EACH validator: it retries a
#     write across the leader rotation (not_leader / retry / busy / rebuilding)
#     until it lands, then paces. Load is thus authored by all leaders, not one.
#   * Churn is VALIDATOR-AWARE. The committee tolerates ANY 1 of N validators down
#     (quorum = N-f); restarting one validator — INCLUDING the founder, no longer
#     special — must NOT stop commits (the key BFT test). Restarting f+1 at once
#     (OVERF mode) deliberately STALLS consensus, which must then RECOVER when the
#     nodes return (liveness under >f transient failures). Observer churn stays
#     safe (they catch up and re-follow).
#   * MEMBERSHIP CHURN under load (admit an observer / remove a validator while
#     writing) is built but OFF by default (MEMBERSHIP_CHURN=1). It mutates the
#     LIVE committee, so it is opt-in and meant to be run supervised.
#
#   scripts/loadtest.sh                              # test the LIVE fleet as-is
#   scripts/loadtest.sh --duration 600               # shorter window
#   scripts/loadtest.sh --overf 0                    # skip the deliberate >f stall
#   scripts/loadtest.sh --membership-churn 1         # exercise membership under load
#   scripts/loadtest.sh --scale 1 --nodes 8          # (re)deploy to 8 nodes first
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
: "${IMAGE_TAG:=0.7.1}"                     # clean homogeneous-fleet image
: "${IMAGE_REGISTRY:=192.168.1.11:5000}"    # registry used when SCALE=1
: "${GENESIS_HASH:=}"                       # required only when SCALE=1; never reuse an old fleet's anchor
: "${NOMAD_FILE:=deploy/quod.nomad}"        # relative to repo root

: "${SCALE:=0}"                             # 0 = test the LIVE fleet as-is (default); 1 = (re)deploy to NODES first
: "${NODES:=0}"                             # only used when SCALE=1; 0 => discover
: "${DURATION:=900}"                        # total chaos window, seconds
: "${WARMUP:=45}"                           # let any cold/restarted node catch up before churn starts, seconds

# sustained transaction load (a bounded-retry writer per validator, autonomous)
: "${TX_BASE_MS:=120}"                      # base delay between a validator's writes
: "${TX_JITTER_MS:=180}"                    # + a random 0..JITTER ms per write (random pacing)
: "${WRITER_RETRIES:=16}"                   # bounded not_leader/retry retries per fact (covers a full leader rotation)
: "${WRITER_RETRY_MS:=40}"                  # sleep between those retries (a fraction of a slot)

# bursts (fired from here during the chaos loop, on every validator)
: "${BURST_PROB:=35}"                       # % chance, each chaos tick, of a burst
: "${BURST_SIZE:=40}"                       # concurrent one-shot submits per burst per validator (stresses backpressure)

# observer churn (safe: catch up + re-follow)
: "${CHURN_PROB:=55}"                       # % chance, each chaos tick, of an observer churn event
: "${CHURN_MAX:=6}"                         # up to this many observers restarted AT ONCE (mass departure)
: "${MASS_PROB:=20}"                        # % of observer churn events that are a full CHURN_MAX mass departure

# validator churn (the BFT test)
: "${VAL_CHURN_PROB:=30}"                   # % chance, each chaos tick, of a validator restart
: "${OVERF:=1}"                             # 1 = also do deliberate >f (stall+recover) restarts; 0 = only <=f
: "${OVERF_PROB:=20}"                       # % of validator churn events that go OVER f (f+1 restarted at once)
: "${RANDOM_CHURN_PROB:=0}"                 # % chance, each tick, of restarting a random mixed validator/observer set
: "${RANDOM_CHURN_MAX:=0}"                  # largest random restart set; 0 disables mixed random churn

# membership churn under load (OFF by default — mutates the live committee)
: "${MEMBERSHIP_CHURN:=0}"                  # 1 = run one admit->grow->hold->remove->shrink cycle mid-window
: "${MEMB_HOLD:=60}"                        # seconds to hold at N+1 under load before removing

: "${TICK:=15}"                             # chaos + log cadence, seconds
: "${UNV_POLL:=3}"                          # unverified-drop poll cadence (< churn cadence: the drop gauge
                                            #   resets on a node restart, so sample it faster than we churn)
: "${LAG_OK:=50}"                           # final height spread that counts as "reconverged"
: "${SETTLE_TRIES:=96}"                     # reconvergence patience after load stops (x5s; 96 = 8 min). Catch-up
                                            #   is CPU-bound and grows with KB size + churn intensity.
: "${MIN_ADVANCE:=}"                        # min committed-height gain to prove the load landed (default: DURATION/4)

export NOMAD_ADDR
SELF=$(realpath "$0")                        # absolute path for the parallel scrape re-exec (survives the cd to repo root below)
WRITER=loadtest_writer                      # registered process name on each validator
STAMP() { date +%H:%M:%S; }
LOG()   { echo "[$(STAMP)] $*"; }

usage() {
  cat <<'EOF'
Usage: scripts/loadtest.sh [options]

Runs transaction load and validator/observer chaos against the live Nomad fleet.
Options override the matching environment variables; environment variables remain
supported for scripts and CI.

Fleet and deployment:
  --nomad-addr ADDR       Nomad API address (NOMAD_ADDR)
  --job NAME               Nomad job name (JOB)
  --namespace NAME         quod namespace (NS)
  --scale 0|1              deploy before testing (SCALE)
  --nodes N                total nodes when scaling (NODES)
  --image-tag TAG          image tag when scaling (IMAGE_TAG)
  --image-registry ADDR    image registry when scaling (IMAGE_REGISTRY)
  --genesis-hash HEX       pinned genesis anchor when scaling (GENESIS_HASH)
  --nomad-file PATH        Nomad job file when scaling (NOMAD_FILE)

Load and chaos:
  --duration SEC            active chaos window (DURATION, default: 900)
  --warmup SEC              pre-test settling time (WARMUP, default: 45)
  --tick SEC                chaos/log interval (TICK, default: 15)
  --tx-base-ms MS           writer base delay (TX_BASE_MS)
  --tx-jitter-ms MS         writer random delay (TX_JITTER_MS)
  --writer-retries N        retries per write (WRITER_RETRIES)
  --writer-retry-ms MS      delay between retries (WRITER_RETRY_MS)
  --burst-prob PCT          burst probability per tick (BURST_PROB)
  --burst-size N            concurrent writes per burst (BURST_SIZE)
  --churn-prob PCT          observer churn probability (CHURN_PROB)
  --churn-max N             maximum observers restarted together (CHURN_MAX)
  --mass-prob PCT            probability of a mass observer restart (MASS_PROB)
  --val-churn-prob PCT      validator churn probability (VAL_CHURN_PROB)
  --overf 0|1               enable deliberate >f stalls (OVERF)
  --overf-prob PCT          probability of an >f stall (OVERF_PROB)
  --random-churn-prob PCT   probability of a mixed random restart (RANDOM_CHURN_PROB)
  --random-churn-max N      largest mixed random restart set; 0 disables it (RANDOM_CHURN_MAX)
  --membership-churn 0|1    mutate membership under load (MEMBERSHIP_CHURN)
  --memb-hold SEC           membership hold time (MEMB_HOLD)
  --unv-poll SEC             unverified-drop poll interval (UNV_POLL)
  --lag-ok N                 allowed final height spread (LAG_OK)
  --settle-tries N          post-load convergence attempts (SETTLE_TRIES)
  --min-advance N            required committed-height gain (MIN_ADVANCE)
  --help                    show this help

Examples:
  scripts/loadtest.sh --duration 120 --warmup 30 --overf 0
  scripts/loadtest.sh --duration 900 --membership-churn 1
  scripts/loadtest.sh --scale 1 --nodes 8 --image-tag 0.7.1 --genesis-hash <hex>
  scripts/loadtest.sh --scale 1 --nodes 16 --random-churn-prob 35 --random-churn-max 10
EOF
}

die() { echo "loadtest: $*" >&2; exit 2; }

take_value() {
  case "$1" in
    *=*) ARG_VALUE=${1#*=}; ARG_SHIFT=1 ;;
    *)   [ "$#" -ge 2 ] || die "missing value for $1"
         ARG_VALUE=$2; ARG_SHIFT=2 ;;
  esac
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --nomad-addr|--nomad-addr=*) take_value "$@"; NOMAD_ADDR=$ARG_VALUE ;;
      --job|--job=*) take_value "$@"; JOB=$ARG_VALUE ;;
      --namespace|--namespace=*) take_value "$@"; NS=$ARG_VALUE ;;
      --scale|--scale=*) take_value "$@"; SCALE=$ARG_VALUE ;;
      --nodes|--nodes=*) take_value "$@"; NODES=$ARG_VALUE ;;
      --image-tag|--image-tag=*) take_value "$@"; IMAGE_TAG=$ARG_VALUE ;;
      --image-registry|--image-registry=*) take_value "$@"; IMAGE_REGISTRY=$ARG_VALUE ;;
      --genesis-hash|--genesis-hash=*) take_value "$@"; GENESIS_HASH=$ARG_VALUE ;;
      --nomad-file|--nomad-file=*) take_value "$@"; NOMAD_FILE=$ARG_VALUE ;;
      --duration|--duration=*) take_value "$@"; DURATION=$ARG_VALUE ;;
      --warmup|--warmup=*) take_value "$@"; WARMUP=$ARG_VALUE ;;
      --tick|--tick=*) take_value "$@"; TICK=$ARG_VALUE ;;
      --tx-base-ms|--tx-base-ms=*) take_value "$@"; TX_BASE_MS=$ARG_VALUE ;;
      --tx-jitter-ms|--tx-jitter-ms=*) take_value "$@"; TX_JITTER_MS=$ARG_VALUE ;;
      --writer-retries|--writer-retries=*) take_value "$@"; WRITER_RETRIES=$ARG_VALUE ;;
      --writer-retry-ms|--writer-retry-ms=*) take_value "$@"; WRITER_RETRY_MS=$ARG_VALUE ;;
      --burst-prob|--burst-prob=*) take_value "$@"; BURST_PROB=$ARG_VALUE ;;
      --burst-size|--burst-size=*) take_value "$@"; BURST_SIZE=$ARG_VALUE ;;
      --churn-prob|--churn-prob=*) take_value "$@"; CHURN_PROB=$ARG_VALUE ;;
      --churn-max|--churn-max=*) take_value "$@"; CHURN_MAX=$ARG_VALUE ;;
      --mass-prob|--mass-prob=*) take_value "$@"; MASS_PROB=$ARG_VALUE ;;
      --val-churn-prob|--val-churn-prob=*) take_value "$@"; VAL_CHURN_PROB=$ARG_VALUE ;;
      --overf|--overf=*) take_value "$@"; OVERF=$ARG_VALUE ;;
      --overf-prob|--overf-prob=*) take_value "$@"; OVERF_PROB=$ARG_VALUE ;;
      --random-churn-prob|--random-churn-prob=*) take_value "$@"; RANDOM_CHURN_PROB=$ARG_VALUE ;;
      --random-churn-max|--random-churn-max=*) take_value "$@"; RANDOM_CHURN_MAX=$ARG_VALUE ;;
      --membership-churn|--membership-churn=*) take_value "$@"; MEMBERSHIP_CHURN=$ARG_VALUE ;;
      --memb-hold|--memb-hold=*) take_value "$@"; MEMB_HOLD=$ARG_VALUE ;;
      --unv-poll|--unv-poll=*) take_value "$@"; UNV_POLL=$ARG_VALUE ;;
      --lag-ok|--lag-ok=*) take_value "$@"; LAG_OK=$ARG_VALUE ;;
      --settle-tries|--settle-tries=*) take_value "$@"; SETTLE_TRIES=$ARG_VALUE ;;
      --min-advance|--min-advance=*) take_value "$@"; MIN_ADVANCE=$ARG_VALUE ;;
      --) ARG_SHIFT=0; shift; [ "$#" -eq 0 ] || die "unexpected positional argument: $1"; break ;;
      -*) die "unknown option: $1 (use --help)" ;;
      *)  die "unexpected positional argument: $1" ;;
    esac
    shift "$ARG_SHIFT"
  done
}

validate_uint() {
  [[ "$2" =~ ^[0-9]+$ ]] || die "$1 must be a non-negative integer, got '$2'"
}

validate_config() {
  validate_uint duration "$DURATION"
  validate_uint warmup "$WARMUP"
  validate_uint tick "$TICK"
  validate_uint nodes "$NODES"
  validate_uint writer-retries "$WRITER_RETRIES"
  validate_uint writer-retry-ms "$WRITER_RETRY_MS"
  validate_uint burst-size "$BURST_SIZE"
  validate_uint churn-max "$CHURN_MAX"
  validate_uint random-churn-prob "$RANDOM_CHURN_PROB"
  validate_uint random-churn-max "$RANDOM_CHURN_MAX"
  validate_uint unv-poll "$UNV_POLL"
  validate_uint lag-ok "$LAG_OK"
  validate_uint settle-tries "$SETTLE_TRIES"
  validate_uint min-advance "$MIN_ADVANCE"
  validate_uint membership-churn "$MEMBERSHIP_CHURN"
  [ "$SCALE" = 0 ] || [ "$SCALE" = 1 ] || die "scale must be 0 or 1, got '$SCALE'"
  [ "$OVERF" = 0 ] || [ "$OVERF" = 1 ] || die "overf must be 0 or 1, got '$OVERF'"
  [ "$RANDOM_CHURN_PROB" -le 100 ] || die "random-churn-prob must be <=100, got '$RANDOM_CHURN_PROB'"
  if [ "$SCALE" = 1 ]; then
    [ "$NODES" -ge 1 ] || die "scale=1 requires nodes>=1"
    [[ "$GENESIS_HASH" =~ ^[0-9A-Fa-f]{64}$ ]] ||
      die "scale=1 requires the current fleet's 64-character genesis hash"
  fi
}

# bounded exec into a node's BEAM (never hang the driver on an unresponsive alloc).
# -task quod is mandatory because the homogeneous group also has a prestart peer-wait task.
QEVAL()      { timeout 25 nomad alloc exec -task quod "$1" /opt/quod/bin/quod eval "$2" 2>/dev/null; }
QEVAL_LONG() { timeout 70 nomad alloc exec -task quod "$1" /opt/quod/bin/quod eval "$2" 2>/dev/null; }

#==============================================================================
# fleet discovery (JSON — no dependence on nomad's human table format / subnet)
#==============================================================================
# Running allocation IDs for the homogeneous quod-node task group. Uses the JSON API, not `nomad job status`
# text table: during churn the human table intermittently drops/mis-lists rows, which made stop_writers'
# re-kill miss the very validators holding writers (orphans survived + kept advancing the ledger).
allocs() {
  nomad operator api "/v1/job/$JOB/allocations" 2>/dev/null \
    | jq -r --arg g "$1" '.[] | select(.ClientStatus == "running" and .TaskGroup == $g) | .ID' 2>/dev/null
}

# "allocid group host:port" for every running alloc's metrics endpoint (parallel, one nomad call each)
endpoints() {
  allocs quod-node | xargs -P 16 -I{} sh -c '
    j=$(nomad alloc status -json "$1" 2>/dev/null)
    hp=$(printf "%s" "$j" | jq -r ".AllocatedResources.Shared.Ports[]? | select(.Label==\"metrics\") | \"\(.HostIP):\(.Value)\"" 2>/dev/null | head -1)
    grp=$(printf "%s" "$j" | jq -r ".TaskGroup" 2>/dev/null)
    [ -n "$hp" ] && echo "$1 $grp $hp"' _ {}
}
failed_allocs() {   # count allocs currently failed/lost (0 = healthy)
  nomad operator api "/v1/job/$JOB/allocations" 2>/dev/null \
    | jq '[.[] | select(.ClientStatus=="failed" or .ClientStatus=="lost")] | length' 2>/dev/null || echo 0
}

# Scrape ONE alloc's metrics for $NS only ->
# "alloc group slot unverified rejects is_validator committee_size weak_cert_waits syncing".
# Nodes may host more than one ontology. Every metric used for the verdict must
# therefore match the requested namespace; otherwise a small auxiliary ontology
# can be mistaken for a lagging root replica. A down/restarting node's curl
# fails -> slot/isv/cs = -1 (excluded from aggregates + classification).
scrape_row() {   # arg: "alloc,group,host:port"
  local a g hp; IFS=, read -r a g hp <<<"$1"
  curl -s --max-time 4 "http://$hp/metrics" 2>/dev/null | awk -v a="$a" -v g="$g" -v ns="$NS" '
    index($0, "namespace=\"" ns "\"") {
      if ($1 ~ /^quod_consensus_slot\{/) slot=$2
      else if ($1 ~ /^quod_feed_dropped\{/ && $0 ~ /reason="unverified"/) unv+=$2
      else if ($1 ~ /^quod_consensus_membership_rejects\{/) mr=$2
      else if ($1 ~ /^quod_consensus_is_validator\{/) isv=$2
      else if ($1 ~ /^quod_consensus_committee_size\{/) cs=$2
      else if ($1 ~ /^quod_consensus_weak_cert_waits\{/) wcw=$2
      else if ($1 ~ /^quod_consensus_syncing\{/) sy=$2
    }
    END { printf "%s %s %d %d %d %d %d %d %d\n", a, g,
                 (slot==""?-1:slot), unv+0, mr+0,
                 (isv==""?-1:isv), (cs==""?-1:cs), wcw+0, (sy==""?-1:sy) }'
}
# re-entry hook: parallel scrape workers re-exec THIS script. Must sit AFTER the fn
# defs and BEFORE any fleet side effect (scale/writer/churn).
[ "${1:-}" = "_scrape_one" ] && { scrape_row "$2"; exit 0; }

parse_args "$@"
[ -z "$MIN_ADVANCE" ] && MIN_ADVANCE=$(( DURATION / 4 ))
validate_config

EPFILE=$(mktemp)                            # alloc->endpoint map:  "alloc group host:port"
FLEETFILE=$(mktemp)                         # per-tick metrics table (cols above); shared by churn + monitor
refresh_endpoints() { endpoints > "$EPFILE"; }
# scrape every endpoint in parallel into the shared per-tick table
scrape_fleet() { awk '{print $1","$2","$3}' "$EPFILE" | xargs -P 16 -I{} bash "$SELF" _scrape_one {}; }
# highest committed slot across the fleet (the ledger head) — used to confirm the ledger froze
fleet_head() { refresh_endpoints; scrape_fleet 2>/dev/null | awk '$3>m{m=$3} END{print m+0}'; }

# classification from the current FLEETFILE
validators() { awk '$6==1 && $9==0 {print $1}' "$FLEETFILE"; }
observers()  { awk '$2=="quod-node" && $6==0 && $9==0 {print $1}' "$FLEETFILE"; }

#==============================================================================
# load control — a bounded-retry writer per validator (leader-aware)
#==============================================================================
# One line (Erlang tolerates the whitespace; keep it single-arg for `quod eval`).
# Force=true kills+respawns; Force=false is ensure-if-missing (self-heals after a restart).
writer_code() {   # $1 = true|false
  printf 'W=%s, Force=%s, Spawn=fun()->spawn(fun Loop()->Try=fun T(0)->dropped; T(K)->case (catch quod_prolog:prove(<<"%s">>,{assertz,{loadtest,erlang:unique_integer([positive])}},<<"%s">>)) of {ok,_,_}->committed; {error,{not_leader,_}}->timer:sleep(%d),T(K-1); {error,retry}->timer:sleep(%d),T(K-1); {error,busy}->timer:sleep(%d),T(K-1); {error,rebuilding}->timer:sleep(%d),T(K-1); _->dropped end end, _=Try(%d), timer:sleep(%d+rand:uniform(%d)), Loop() end) end, case {Force,whereis(W)} of {false,P0} when is_pid(P0)->{already_running,P0}; _->(fun Kill()->case whereis(W) of undefined->ok; O->exit(O,kill),timer:sleep(30),Kill() end end)(), P=Spawn(), register(W,P), {writer_started,P} end.' \
    "$WRITER" "$1" "$NS" "$NS" \
    "$WRITER_RETRY_MS" "$WRITER_RETRY_MS" "$WRITER_RETRY_MS" "$WRITER_RETRY_MS" \
    "$WRITER_RETRIES" "$TX_BASE_MS" "$((TX_JITTER_MS + 1))"
}

start_writers() {   # $1 = "force" to kill+respawn (run once at start); else ensure-if-missing (each tick)
  local force=false; [ "${1:-}" = force ] && force=true
  local code vals a tmp started=0 running=0
  code=$(writer_code "$force")
  mapfile -t vals < <(validators)
  [ "${#vals[@]}" -eq 0 ] && { LOG "WARN: no validators up to run writers on"; return 0; }
  tmp=$(mktemp -d)
  for a in "${vals[@]}"; do ( QEVAL "$a" "$code" > "$tmp/$a" 2>&1 ) & done
  wait
  for a in "${vals[@]}"; do
    case "$(cat "$tmp/$a" 2>/dev/null)" in
      *writer_started*)  started=$((started + 1));;
      *already_running*) running=$((running + 1));;
    esac
  done
  rm -rf "$tmp"
  [ "$started" -gt 0 ] && LOG "writers: +$started (re)started, $running already running (on ${#vals[@]} validators)"
  return 0
}

kill_writers_once() {
  # Fan out through the long exec path. Under saturation the short probe can
  # time out before it reaches the BEAM, leaving an otherwise invisible writer.
  local a out tmp left=0 pid
  local -a pids=()
  tmp=$(mktemp -d)
  while read -r a; do
    [ -z "$a" ] && continue
    ( QEVAL_LONG "$a" "case whereis($WRITER) of undefined -> gone; P -> exit(P,kill), timer:sleep(100), case whereis($WRITER) of undefined -> killed; _ -> alive end end." > "$tmp/$a" 2>&1 ) &
    pids+=("$!")
  done < <(allocs quod-node)
  for pid in "${pids[@]}"; do wait "$pid" || true; done
  for out in "$tmp"/*; do
    [ -e "$out" ] || continue
    case "$(<"$out")" in *gone*|*killed*) ;; *) left=$((left + 1));; esac
  done
  rm -rf "$tmp"
  printf '%s\n' "$left"
}

stop_writers() {
  # Stop on the full current allocation set, then prove the ledger is quiet.
  # A task can be absent while its allocation restarts, hence repeated rounds.
  local left round h1 h2 tries
  for round in 1 2 3 4 5; do
    left=$(kill_writers_once)
    [ "$left" -eq 0 ] && break
    LOG "stop_writers: $left alloc exec probe(s) unresolved; retrying"
    sleep 3
  done
  h1=$(fleet_head); sleep 4; h2=$(fleet_head); tries=0
  while [ "${h2:-0}" -gt "${h1:-0}" ] && [ "$tries" -lt 6 ]; do
    LOG "stop_writers: ledger still advancing ($h1 -> $h2) — re-killing current writers"
    kill_writers_once >/dev/null
    h1=$(fleet_head); sleep 4; h2=$(fleet_head); tries=$((tries + 1))
  done
  if [ "${h2:-0}" -le "${h1:-0}" ]; then
    LOG "writers stopped (ledger quiescent at ${h2:-?})"
  else
    LOG "writers: WARN ledger still advancing ($h1 -> $h2) after re-kills"
  fi
}

burst() {
  local vals a
  mapfile -t vals < <(validators)
  [ "${#vals[@]}" -eq 0 ] && return 0
  # BURST_SIZE concurrent one-shots on EVERY validator: the leader's contend (backpressure /
  # append_busy), the rest exercise the not_leader redirect path. Each eval monitors its
  # children and bounds their lifetime, so stopping the load cannot leave detached submits behind.
  for a in "${vals[@]}"; do
    QEVAL "$a" "Ps=[spawn_monitor(fun()->catch quod_prolog:prove(<<\"$NS\">>,{assertz,{burst,erlang:unique_integer([positive])}},<<\"$NS\">>) end)||_<-lists:seq(1,$BURST_SIZE)], D=erlang:monotonic_time(millisecond)+20000, W=fun F([])->ok; F([{P,R}|T])->Left=D-erlang:monotonic_time(millisecond), receive {'DOWN',R,process,P,_}->F(T) after max(0,Left)->lists:foreach(fun({P0,_})->exit(P0,kill) end,[{P,R}|T]),ok end end, W(Ps), ok." >/dev/null &
  done
  wait
  LOG "BURST: $BURST_SIZE concurrent submits x ${#vals[@]} validators"
}

#==============================================================================
# chaos: validator-aware churn
#==============================================================================
CHURN_PID=""; VAL_CHURN_PID=""; RANDOM_CHURN_PID=""
STALLED=0; PRE_STALL_SLOT=0; STALL_LAST_SLOT=0; STALL_QUORUM_LOST=0; STALL_OBSERVED=0; CUR_MAX=0
OVERF_EVENTS=0; OVERF_STALLS_OBSERVED=0; OVERF_RECOVERED=0; OVERF_UNOBSERVED=0
RANDOM_CHURN_EVENTS=0; RANDOM_OVERF_EVENTS=0

churn_observers() {
  if [ -n "$CHURN_PID" ] && kill -0 "$CHURN_PID" 2>/dev/null; then LOG "obs-churn: previous restart still in flight, skipping"; return 0; fi
  local ids n pick
  mapfile -t ids < <(observers)
  [ "${#ids[@]}" -eq 0 ] && return 0
  if [ "$((RANDOM % 100))" -lt "$MASS_PROB" ]; then n=$CHURN_MAX; else n=$(( 1 + RANDOM % 3 )); fi
  [ "$n" -gt "${#ids[@]}" ] && n=${#ids[@]}
  pick=$(printf '%s\n' "${ids[@]}" | shuf | head -n "$n")
  LOG "CHURN(observer): restarting $n observer(s) simultaneously"
  echo "$pick" | xargs -P "$CHURN_MAX" -I{} nomad alloc restart {} >/dev/null 2>&1 &
  CHURN_PID=$!
}

churn_validators() {
  if [ -n "$VAL_CHURN_PID" ] && kill -0 "$VAL_CHURN_PID" 2>/dev/null; then LOG "val-churn: previous restart still in flight, skipping"; return 0; fi
  [ "$STALLED" = 0 ] || { LOG "val-churn: waiting for the previous expected stall to recover"; return 0; }
  local ids up n label pick head behind
  mapfile -t ids < <(validators)
  up=${#ids[@]}
  # Only churn validators from a fully-caught-up committee. A restarted validator stays a
  # non-voting observer for the ~15-30s it catches up + re-promotes; if we take ANOTHER down in
  # that window we transiently push >f validators unavailable and stall consensus UNINTENDED. And
  # a validator that promoted "behind" (the deferred member gap-fill gap) reads is_validator=1
  # while still lagging the head — churning on top of it piles unavailability past f. So require
  # all EXP_VALIDATORS voting AND each within LAG_OK of the head. This self-paces churn to the
  # fleet's true recovery. (The deliberate >f stall is the OVER-f case, from the same whole set.)
  head=$(awk '$3>=0{if($3>m)m=$3} END{print m+0}' "$FLEETFILE")
  behind=$(awk -v h="$head" -v lag="$LAG_OK" '$6==1 && ($9!=0 || $3<0 || h-$3>lag){c++} END{print c+0}' "$FLEETFILE")
  if [ "$up" -lt "$EXP_VALIDATORS" ] || [ "$behind" -gt 0 ]; then
    LOG "val-churn: committee not fully caught up ($up/$EXP_VALIDATORS voting, $behind behind head=$head) — deferring"
    return 0
  fi
  n=1; label="within-f (<=$F, quorum $QUORUM holds -> commits MUST continue)"
  if [ "$OVERF" = 1 ] && [ "$((RANDOM % 100))" -lt "$OVERF_PROB" ]; then
    n=$OVERF_N; label="OVER-f (${OVERF_N}>f=$F -> deliberate STALL, must RECOVER)"
  fi
  [ "$n" -ge "$up" ] && n=$((up - 1))   # never restart ALL up validators — leave >=1 to drive recovery
  [ "$n" -lt 1 ] && return 0
  pick=$(printf '%s\n' "${ids[@]}" | shuf | head -n "$n")
  if [ "$n" -gt "$F" ]; then
    PRE_STALL_SLOT=$CUR_MAX; STALL_LAST_SLOT=$CUR_MAX; STALL_QUORUM_LOST=0; STALL_OBSERVED=0; STALLED=1; OVERF_EVENTS=$((OVERF_EVENTS + 1))
    LOG "CHURN(validator, $label): restarting $n/$up [$(echo $pick | tr '\n' ' ')] — expect commit STALL at slot ~$PRE_STALL_SLOT until >=$QUORUM validators return"
  else
    LOG "CHURN(validator, $label): restarting $n/$up [$(echo $pick | tr '\n' ' ')]"
  fi
  echo "$pick" | xargs -P "$n" -I{} nomad alloc restart {} >/dev/null 2>&1 &
  VAL_CHURN_PID=$!
}

random_churn() {
  [ "$RANDOM_CHURN_MAX" -gt 0 ] || return 0
  if [ -n "$RANDOM_CHURN_PID" ] && kill -0 "$RANDOM_CHURN_PID" 2>/dev/null; then LOG "random-churn: previous restart still in flight, skipping"; return 0; fi
  [ "$STALLED" = 0 ] || { LOG "random-churn: waiting for the previous expected stall to recover"; return 0; }
  local rows n pick validator_count ids label
  mapfile -t rows < <(awk '$9==0 {print $1 ":" $6}' "$FLEETFILE")
  [ "${#rows[@]}" -gt 1 ] || return 0
  n=$((1 + RANDOM % RANDOM_CHURN_MAX))
  [ "$n" -ge "${#rows[@]}" ] && n=$((${#rows[@]} - 1))
  pick=$(printf '%s\n' "${rows[@]}" | shuf | head -n "$n")
  validator_count=$(printf '%s\n' "$pick" | awk -F: '$2==1 {c++} END{print c+0}')
  ids=$(printf '%s\n' "$pick" | cut -d: -f1)
  RANDOM_CHURN_EVENTS=$((RANDOM_CHURN_EVENTS + 1))
  if [ "$validator_count" -gt "$F" ]; then
    PRE_STALL_SLOT=$CUR_MAX; STALL_LAST_SLOT=$CUR_MAX; STALL_QUORUM_LOST=0; STALL_OBSERVED=0; STALLED=1; OVERF_EVENTS=$((OVERF_EVENTS + 1)); RANDOM_OVERF_EVENTS=$((RANDOM_OVERF_EVENTS + 1))
    label="expected STALL: $validator_count validators > f=$F"
  else
    label="within-f: $validator_count validator(s) <= f=$F"
  fi
  LOG "CHURN(random): restarting $n mixed node(s), $label"
  printf '%s\n' "$ids" | xargs -P "$n" -I{} nomad alloc restart {} >/dev/null 2>&1 &
  RANDOM_CHURN_PID=$!
}

#==============================================================================
# optional: membership churn under load (Slice C/D/E) — OFF by default
#==============================================================================
MEMB_RAN=0; MEMB_RESULT=pass

# read a candidate's own identity as an embeddable Erlang literal + address:  "PKLIT|HOST|PORT"
cand_pk_addr() {   # $1 = alloc
  local out
  out=$(QEVAL "$1" '{ok,Pk}=application:get_env(quod,node_pubkey), {ok,{H,P}}=application:get_env(quod,node_addr), Hs=if is_list(H)->H; is_tuple(H)->inet:ntoa(H); true->H end, lists:flatten(io_lib:format("~w|~s|~w",[Pk,Hs,P])).')
  out=${out#\"}; out=${out%\"}   # eval prints a string with surrounding quotes
  printf '%s' "$out"
}
# admit/remove goals run in-BEAM on a validator with an internal leader-retry (like the writer,
# but generous — up to ~40s — so peer_ready has time to go true and the leader turn to come round).
admit_code()  { printf 'Ns= <<"%s">>, G={admit,%s,"%s",%d}, (fun T(0)->{error,exhausted}; T(K)->case (catch quod_prolog:prove(Ns,G,Ns)) of {ok,_,_}->admitted; {error,{not_leader,_}}->timer:sleep(200),T(K-1); {error,retry}->timer:sleep(200),T(K-1); {error,busy}->timer:sleep(200),T(K-1); {error,rebuilding}->timer:sleep(200),T(K-1); _->timer:sleep(200),T(K-1) end end)(200).' "$NS" "$1" "$2" "$3"; }
remove_code() { printf 'Ns= <<"%s">>, G={remove,%s}, (fun T(0)->{error,exhausted}; T(K)->case (catch quod_prolog:prove(Ns,G,Ns)) of {ok,_,_}->removed; {error,{not_leader,_}}->timer:sleep(200),T(K-1); {error,retry}->timer:sleep(200),T(K-1); {error,busy}->timer:sleep(200),T(K-1); {error,rebuilding}->timer:sleep(200),T(K-1); _->timer:sleep(200),T(K-1) end end)(200).' "$NS" "$1"; }

_memb_wait() {   # $1=admitter $2=cand $3=target_cs_op(-ge|-le) $4=target_cs $5=want_isv  -> 0 ok / 1 timeout
  local i cs isv sy
  for i in $(seq 1 24); do
    refresh_endpoints; scrape_fleet > "$FLEETFILE"
    cs=$(awk -v a="$1" '$1==a{print $7}' "$FLEETFILE"); isv=$(awk -v a="$2" '$1==a{print $6}' "$FLEETFILE")
    sy=$(awk -v a="$2" '$1==a{print $9}' "$FLEETFILE")
    if [ "${cs:--1}" "$3" "$4" ] && [ "${isv:--1}" = "$5" ] && [ "${sy:--1}" = 0 ]; then return 0; fi
    sleep 5
  done
  return 1
}

membership_churn_cycle() {
  local vids cand head pk host port admitter r
  mapfile -t vids < <(validators)
  [ "${#vids[@]}" -lt "$EXP_VALIDATORS" ] && { LOG "MEMB-CHURN: committee not whole (${#vids[@]}/$EXP_VALIDATORS up) — deferring"; return 0; }
  head=$(awk '$3>=0{if($3>m)m=$3}END{print m+0}' "$FLEETFILE")
  cand=$(awk -v h="$head" '$2=="quod-node" && $6==0 && $9==0 && $3>=0 && (h-$3)<=256 {print $1" "$3}' "$FLEETFILE" | sort -k2 -n | tail -1 | awk '{print $1}')
  [ -z "$cand" ] && { LOG "MEMB-CHURN: no caught-up observer candidate — skipping"; return 0; }
  IFS='|' read -r pk host port <<< "$(cand_pk_addr "$cand")"
  [ -z "$pk" ] && { LOG "MEMB-CHURN: could not read candidate $cand identity — skipping"; return 0; }
  admitter=${vids[0]}; MEMB_RAN=1

  LOG "MEMB-CHURN: ADMIT observer $cand ($host:$port) via validator $admitter — expect committee $EXP_COMMITTEE -> $((EXP_COMMITTEE + 1))"
  r=$(QEVAL_LONG "$admitter" "$(admit_code "$pk" "$host" "$port")")
  LOG "MEMB-CHURN: admit result = ${r:-<timeout>}"
  if _memb_wait "$admitter" "$cand" -ge "$((EXP_COMMITTEE + 1))" 1; then
    LOG "MEMB-CHURN: committee grew + candidate self-promoted (is_validator=1)"
  else
    LOG "MEMB-CHURN: FAIL — grow/promote not observed within ~2min"; MEMB_RESULT=fail
  fi

  LOG "MEMB-CHURN: holding ${MEMB_HOLD}s at N+1 under load..."; sleep "$MEMB_HOLD"

  LOG "MEMB-CHURN: REMOVE $cand via $admitter — expect committee -> $EXP_COMMITTEE, demote to observer"
  r=$(QEVAL_LONG "$admitter" "$(remove_code "$pk")")
  LOG "MEMB-CHURN: remove result = ${r:-<timeout>}"
  if _memb_wait "$admitter" "$cand" -le "$EXP_COMMITTEE" 0; then
    LOG "MEMB-CHURN: committee re-formed at $EXP_COMMITTEE + candidate demoted (is_validator=0)"
  else
    LOG "MEMB-CHURN: FAIL — shrink/demote not observed within ~2min"; MEMB_RESULT=fail
  fi
}

#==============================================================================
# monitor
#==============================================================================
WORST_LAG=0; MAX_UNVERIFIED=0; MAX_REJECTS=0; MAX_WEAK_CERT=0
REJECT_BASELINE=0
CS_SEEN_MIN=999; CS_SEEN_MAX=0
BASE_FAILED_ALLOCS=0

# aggregate the current FLEETFILE -> "up min max lag unv mr ready_validators cs_min cs_max wcw recovering"
snapshot() {
  awk '
    $3>=0 { caught++; if(mn==""||$3<mn)mn=$3; if($3>mx)mx=$3 }
          { unv+=$4; if($5>mr)mr=$5 }
    $6==1 && $9==0 { vals++ }
    $7>=0 { if(csmn==""||$7<csmn)csmn=$7; if($7>csmx)csmx=$7 }
          { if($8>wcw)wcw=$8 }
    $9!=0 { recovering++ }
    END {
      if(caught+0==0){ printf "0 -1 -1 999999 %d %d %d -1 -1 %d %d\n", unv+0, mr+0, vals+0, wcw+0, recovering+0 }
      else { printf "%d %d %d %d %d %d %d %d %d %d %d\n", caught, mn, mx, mx-mn, unv+0, mr+0, vals+0,
                    (csmn==""?-1:csmn), (csmx==""?-1:csmx), wcw+0, recovering+0 }
    }' "$FLEETFILE"
}
# fold a snapshot line into the run-wide accumulators (call in the MAIN shell)
accumulate() {   # $1=caught $2=lag $3=unv $4=rej $5=cs_min $6=cs_max $7=wcw
  local new_rejects=$(( $4 - REJECT_BASELINE ))
  [ "$new_rejects" -lt 0 ] && new_rejects=0  # a node restart resets its local gauge
  [ "$1" -ge 2 ] && [ "$2" -gt "$WORST_LAG" ] && WORST_LAG=$2
  [ "$3" -gt "$MAX_UNVERIFIED" ] && MAX_UNVERIFIED=$3
  [ "$new_rejects" -gt "$MAX_REJECTS" ] && MAX_REJECTS=$new_rejects
  [ "$7" -gt "$MAX_WEAK_CERT" ] && MAX_WEAK_CERT=$7
  [ "$5" -ge 0 ] && [ "$5" -lt "$CS_SEEN_MIN" ] && CS_SEEN_MIN=$5
  [ "$6" -gt "$CS_SEEN_MAX" ] && CS_SEEN_MAX=$6
}
# A deliberate over-f restart can leave a few already-approved commits in flight.
# Only assert a stall/recovery when metrics actually show fewer than quorum-ready
# validators and then a height plateau. Nomad can complete a fast restart between
# two full-fleet scrapes; that is an unobserved churn event, not a liveness failure.
detect_overf_recovery() {   # $1 = current max slot, $2 = ready validators
  local slot=${1:--1} vals=${2:-0}
  [ "$STALLED" = 1 ] && [ "$slot" -ge 0 ] || return 0
  if [ "$vals" -lt "$QUORUM" ] && [ "$STALL_QUORUM_LOST" = 0 ]; then
    STALL_QUORUM_LOST=1
    LOG "OVER-f quorum loss observed ($vals/$EXP_VALIDATORS ready, quorum=$QUORUM)"
  fi

  if [ "$STALL_OBSERVED" = 1 ]; then
    if [ "$vals" -ge "$QUORUM" ] && [ "$slot" -gt "$STALL_LAST_SLOT" ]; then
      LOG "OVER-f RECOVERY: commits resumed (slot $STALL_LAST_SLOT -> $slot) after validators returned"
      STALLED=0; OVERF_RECOVERED=$((OVERF_RECOVERED + 1))
    elif [ "$slot" -gt "$STALL_LAST_SLOT" ]; then
      STALL_LAST_SLOT=$slot
    fi
  elif [ "$STALL_QUORUM_LOST" = 1 ] && [ "$slot" -le "$STALL_LAST_SLOT" ]; then
    STALL_OBSERVED=1; OVERF_STALLS_OBSERVED=$((OVERF_STALLS_OBSERVED + 1))
    LOG "OVER-f STALL observed at slot $slot"
  elif [ "$vals" -ge "$QUORUM" ]; then
    STALLED=0; OVERF_UNOBSERVED=$((OVERF_UNOBSERVED + 1))
    LOG "OVER-f churn reconverged before a measurable quorum-loss plateau; not counted as a stall"
  else
    STALL_LAST_SLOT=$slot
  fi
}
# fast, cheap unverified-only poll from the cached endpoints (shrinks the gauge-reset blind spot)
poll_unverified() {
  local rows u w
  rows=$(scrape_fleet)
  u=$(printf '%s\n' "$rows" | awk '{s+=$4} END{print s+0}')
  w=$(printf '%s\n' "$rows" | awk '{if($8>m)m=$8} END{print m+0}')
  [ "${u:-0}" -gt "$MAX_UNVERIFIED" ] && MAX_UNVERIFIED=$u
  [ "${w:-0}" -gt "$MAX_WEAK_CERT" ] && MAX_WEAK_CERT=$w
}

#==============================================================================
# run
#==============================================================================
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 1
command -v jq >/dev/null || { echo "FATAL: jq required"; exit 1; }
trap 'echo; LOG "interrupted — stopping writers"; stop_writers; exit 130' INT TERM
trap 'stop_writers; rm -f "$EPFILE" "$FLEETFILE"' EXIT

LOG "=== quod load+chaos (multi-validator) :: DURATION=${DURATION}s tag=$IMAGE_TAG overf=$OVERF random_churn=${RANDOM_CHURN_PROB}%/${RANDOM_CHURN_MAX} membership_churn=$MEMBERSHIP_CHURN min_advance=$MIN_ADVANCE ==="

if [ "$SCALE" = "1" ]; then
  LOG "scaling homogeneous job to $NODES nodes..."
  nomad job run -var image_tag="$IMAGE_TAG" -var image_registry="$IMAGE_REGISTRY" \
    -var node_count="$NODES" -var genesis_hash="$GENESIS_HASH" "$NOMAD_FILE" 2>&1 | tail -3
fi

LOG "warmup ${WARMUP}s (let any cold/restarted node catch up)..."; sleep "$WARMUP"
refresh_endpoints; scrape_fleet > "$FLEETFILE"

# discover the fleet shape from reality (fleet-size-agnostic)
TOTAL=$(awk 'END{print NR}' "$FLEETFILE")
read -r n0 min0 max0 _ unv0 REJECT_BASELINE EXP_VALIDATORS csmn0 csmx0 _ recovering0 <<<"$(snapshot)"
EXP_COMMITTEE=$csmx0
F=$(( (EXP_VALIDATORS - 1) / 3 )); QUORUM=$(( EXP_VALIDATORS - F )); OVERF_N=$(( F + 1 ))
START_VALIDATORS=$(validators | sort | tr '\n' ' ')
START_SLOT=$max0; CUR_MAX=$max0
LOG "fleet: $TOTAL nodes, committee_size=$EXP_COMMITTEE, VALIDATORS=$EXP_VALIDATORS (f=$F quorum=$QUORUM overf_n=$OVERF_N), slot=$min0..$max0"
LOG "validators: $START_VALIDATORS"
[ "$EXP_VALIDATORS" -lt 1 ] && { LOG "FATAL: no validators discovered — is the fleet up?"; exit 1; }
BASE_FAILED_ALLOCS=$(failed_allocs)
LOG "failed/lost alloc baseline: $BASE_FAILED_ALLOCS"
LOG "membership reject baseline: $REJECT_BASELINE"

start_writers force

MEMB_AT=$(( DURATION * 40 / 100 ))          # fire the membership cycle ~40% into the window
polls=$(( TICK / UNV_POLL )); [ "$polls" -lt 1 ] && polls=1
START_TS=$(date +%s); END=$(( START_TS + DURATION )); tick=0
while [ "$(date +%s)" -lt "$END" ]; do
  tick=$((tick + 1))
  [ "$((RANDOM % 100))" -lt "$BURST_PROB" ]     && burst
  [ "$((RANDOM % 100))" -lt "$CHURN_PROB" ]     && churn_observers
  [ "$((RANDOM % 100))" -lt "$VAL_CHURN_PROB" ] && churn_validators
  [ "$((RANDOM % 100))" -lt "$RANDOM_CHURN_PROB" ] && random_churn

  if [ "$MEMBERSHIP_CHURN" = 1 ] && [ "$MEMB_RAN" = 0 ] && [ "$(( $(date +%s) - START_TS ))" -ge "$MEMB_AT" ]; then
    membership_churn_cycle
  fi

  refresh_endpoints; scrape_fleet > "$FLEETFILE"
  read -r n mn mx lag unv mr vals csmn csmx wcw recovering <<<"$(snapshot)"
  accumulate "$n" "$lag" "$unv" "$mr" "$csmn" "$csmx" "$wcw"
  [ "$mx" -ge 0 ] && CUR_MAX=$mx
  start_writers            # ensure-if-missing: self-heal writers after a validator restart

  detect_overf_recovery "$mx" "$vals"

  LOG "tick $tick: up=$n/$TOTAL ready_validators=$vals/$EXP_VALIDATORS recovering=$recovering slot=$mn..$mx lag=$lag unv=$unv rej=$mr cs=$csmn..$csmx wcw=$wcw"
  for _ in $(seq 1 "$polls"); do sleep "$UNV_POLL"; poll_unverified; done
done

LOG "chaos window over — stopping load, waiting for churn to settle + reconvergence..."
[ -n "$CHURN_PID" ]     && wait "$CHURN_PID" 2>/dev/null
[ -n "$VAL_CHURN_PID" ] && wait "$VAL_CHURN_PID" 2>/dev/null
[ -n "$RANDOM_CHURN_PID" ] && wait "$RANDOM_CHURN_PID" 2>/dev/null
stop_writers

converged=0; n=0; mx=$START_SLOT; vals=$EXP_VALIDATORS; csmn=$EXP_COMMITTEE; csmx=$EXP_COMMITTEE; wcw=0; vbehind=$EXP_VALIDATORS; recovering=$TOTAL
for _ in $(seq 1 "$SETTLE_TRIES"); do
  refresh_endpoints; scrape_fleet > "$FLEETFILE"
  read -r n mn mx lag unv mr vals csmn csmx wcw recovering <<<"$(snapshot)"
  # validators NOT at the (frozen) head: a promote-behind validator (member gap-fill gap) reads
  # is_validator=1 and can sit within LAG_OK of the head, so a lag<=LAG_OK check passes it
  # spuriously. The load has stopped, so a healthy fleet converges to the IDENTICAL head; only a
  # genuinely-stuck validator stays below it (small tolerance absorbs a last-slot timing skew).
  vbehind=$(awk -v h="$mx" '$6==1 && ($9!=0 || $3<0 || h-$3>2){c++} END{print c+0}' "$FLEETFILE")
  detect_overf_recovery "$mx" "$vals"   # a >f stall from the last tick(s) recovers HERE, after the window
  accumulate "$n" "$lag" "$unv" "$mr" "$csmn" "$csmx" "$wcw"
  LOG "settle: up=$n/$TOTAL ready_validators=$vals/$EXP_VALIDATORS(behind:$vbehind) recovering=$recovering slot=$mn..$mx lag=$lag unv=$unv cs=$csmn..$csmx wcw=$wcw"
  if [ "$n" -eq "$TOTAL" ] && [ "$recovering" -eq 0 ] && [ "$mn" -ge 0 ] && [ "$lag" -le "$LAG_OK" ] && [ "$vals" -eq "$EXP_VALIDATORS" ] && [ "$vbehind" -eq 0 ]; then converged=1; break; fi
  sleep 5
done
END_SLOT=$mx
END_VALIDATORS=$(validators | sort | tr '\n' ' ')

#==============================================================================
# verdict
#==============================================================================
FAILED=0
FAILEDALLOCS=$(failed_allocs)
NEW_FAILEDALLOCS=$((FAILEDALLOCS - BASE_FAILED_ALLOCS))
[ "$NEW_FAILEDALLOCS" -lt 0 ] && NEW_FAILEDALLOCS=$FAILEDALLOCS
ADVANCE=$(( END_SLOT - START_SLOT ))
echo
LOG "================= RESULT (N=$EXP_VALIDATORS, f=$F) ================="
LOG "nodes up at end          : $n / $TOTAL";                 [ "$n" -eq "$TOTAL" ]                  || { LOG "  FAIL: not all nodes are up"; FAILED=1; }
LOG "nodes still recovering  : $recovering";                 [ "$recovering" -eq 0 ]                 || { LOG "  FAIL: node(s) have not corroborated their ledger tip"; FAILED=1; }
LOG "reconverged (lag<=$LAG_OK)   : $([ "$converged" = 1 ] && echo yes || echo NO)"; [ "$converged" = 1 ] || { LOG "  FAIL: fleet did not reconverge"; FAILED=1; }
LOG "ledger advanced          : +$ADVANCE (>= $MIN_ADVANCE required)"; [ "$ADVANCE" -ge "$MIN_ADVANCE" ] || { LOG "  FAIL: too few commits (sustained load did not land)"; FAILED=1; }
LOG "unverified drops (max)   : $MAX_UNVERIFIED";             [ "$MAX_UNVERIFIED" -eq 0 ]            || { LOG "  FAIL: unverified gossip observed (safety!)"; FAILED=1; }
LOG "failed/lost allocs       : $NEW_FAILEDALLOCS new ($FAILEDALLOCS total)"; [ "$NEW_FAILEDALLOCS" -eq 0 ] || { LOG "  FAIL: allocs failed/lost during test"; FAILED=1; }
# --- N>=4 committee invariants ---
LOG "validators at end        : $vals / $EXP_VALIDATORS";     [ "$vals" -eq "$EXP_VALIDATORS" ]      || { LOG "  FAIL: not all validators recovered/voting"; FAILED=1; }
LOG "validators at head       : $([ "$vbehind" -eq 0 ] && echo yes || echo NO)  ($vbehind behind head=$END_SLOT)"; [ "$vbehind" -eq 0 ] || { LOG "  FAIL: validator(s) stuck behind the head after load stopped (member multi-slot gap-fill gap — deferred.md §3)"; FAILED=1; }
LOG "validator set stable     : $([ "$START_VALIDATORS" = "$END_VALIDATORS" ] && echo yes || echo NO)"
  [ "$START_VALIDATORS" = "$END_VALIDATORS" ] || { LOG "  FAIL: validator set changed (start[$START_VALIDATORS] != end[$END_VALIDATORS])"; FAILED=1; }
LOG "committee_size (max seen): $CS_SEEN_MAX (expected $EXP_COMMITTEE), settled $csmn..$csmx"
if [ "$MEMBERSHIP_CHURN" = 0 ]; then
  { [ "$CS_SEEN_MAX" -eq "$EXP_COMMITTEE" ] && [ "$csmn" -eq "$EXP_COMMITTEE" ] && [ "$csmx" -eq "$EXP_COMMITTEE" ]; } \
    || { LOG "  FAIL: spurious membership change (committee_size drifted)"; FAILED=1; }
  LOG "membership rejects (new) : $MAX_REJECTS (baseline $REJECT_BASELINE)"; [ "$MAX_REJECTS" -eq 0 ] || { LOG "  FAIL: new membership rejects with no membership churn"; FAILED=1; }
else
  { [ "$csmn" -eq "$EXP_COMMITTEE" ] && [ "$csmx" -eq "$EXP_COMMITTEE" ]; } \
    || { LOG "  FAIL: committee did not re-form at $EXP_COMMITTEE after membership churn"; FAILED=1; }
  LOG "membership rejects (max) : $MAX_REJECTS  (informational — honest peer_ready split fail-closed)"
fi
LOG "weak_cert_waits (drained): $wcw  (peak during chaos: $MAX_WEAK_CERT)"; [ "$wcw" -eq 0 ] || { LOG "  FAIL: weak-cert waits did not drain (a laggard stuck across a committee change)"; FAILED=1; }
if [ "$OVERF_EVENTS" -gt 0 ]; then
  LOG "over-f stalls recovered  : $OVERF_RECOVERED / $OVERF_STALLS_OBSERVED observed ($OVERF_EVENTS churn events, $OVERF_UNOBSERVED unobserved)";
  { [ "$OVERF_RECOVERED" -eq "$OVERF_STALLS_OBSERVED" ] && [ "$STALLED" -eq 0 ]; } || { LOG "  FAIL: a measured deliberate >f stall did not recover"; FAILED=1; }
fi
LOG "random restart events     : $RANDOM_CHURN_EVENTS ($RANDOM_OVERF_EVENTS expected over-f)"
if [ "$MEMB_RAN" = 1 ]; then
  LOG "membership churn cycle   : $MEMB_RESULT";               [ "$MEMB_RESULT" = pass ]             || { LOG "  FAIL: committee did not re-form/keep committing under membership churn"; FAILED=1; }
fi
LOG "worst height spread      : $WORST_LAG (during chaos — informational)"
LOG "======================================================"
LOG "note: the unverified/weak-cert gauges reset on a node restart; they are sampled every ${UNV_POLL}s"
LOG "      (< churn cadence) to shrink but not eliminate that blind spot. A transient recovered crash"
LOG "      between snapshots is not counted; a PERSISTENT crash-loop still fails via non-reconvergence."
[ "$FAILED" -eq 0 ] && { LOG "PASS"; exit 0; } || { LOG "FAIL"; exit 1; }
