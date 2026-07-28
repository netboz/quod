#!/usr/bin/env bash
#
# Fixed-work remote-read benchmark for the network ontology directory.
#
# Every operation enters SOURCE_NS through /api/prove and proves one
# TARGET_NS::Goal. Preflight refuses a source endpoint that also hosts the
# target, so successful work necessarily uses directory resolution, a
# key-pinned remote dial, and answer streaming. It deliberately sends no writes.
#
# The fleet must already host the two public ontologies. SOURCE_ENDPOINTS is
# explicit: Consul knows Quod nodes, not the subset hosting a given namespace.
#
# Example:
#   SOURCE_ENDPOINTS=http://192.168.1.12:26080 \
#   SOURCE_NS=quod:bench_source TARGET_NS=quod:bench_target \
#   GOAL='benchmark_echo(ok)' REQUESTS=2000 CONCURRENCY=64 \
#   scripts/cross-ontology-loadtest.sh

set -euo pipefail

: "${SOURCE_ENDPOINTS:=}"       # comma-separated http(s) explorer bases
: "${SOURCE_NS:=}"
: "${TARGET_NS:=}"
: "${GOAL:=true}"               # target-local, read-only Prolog goal
: "${REQUESTS:=1000}"
: "${CONCURRENCY:=32}"
: "${HTTP_TIMEOUT_S:=35}"
: "${PREFLIGHT_TIMEOUT_S:=60}"
: "${MAX_FAILURES:=0}"
: "${RESULT_DIR:=}"

usage() {
  cat <<'EOF'
Usage: scripts/cross-ontology-loadtest.sh --source-endpoints URL[,URL...] \
       --source-ns NAME --target-ns NAME [options]

Runs a fixed number of read-only remote Target::Goal proofs. Every source
endpoint must host SOURCE_NS and must not co-host TARGET_NS; that prevents a
local shortcut from contaminating the measurement.

Required:
  --source-endpoints URL[,URL...]  Explorer endpoint(s) hosting the source ontology
  --source-ns NAME                 Calling ontology namespace
  --target-ns NAME                 Directory-resolved target namespace

Options:
  --goal TEXT                      Read-only target goal (default: true)
  --requests N                     Total logical remote proofs (default: 1000)
  --concurrency N                  Maximum in-flight HTTP proofs (default: 32)
  --http-timeout SEC               Per-proof client deadline (default: 35)
  --preflight-timeout SEC          Wait for routes/readiness (default: 60)
  --max-failures N                 Fail above this many failed proofs (default: 0)
  --result-dir PATH                Keep raw TSV/JSON results here
  --help                           Show this help

The target goal must be read-only. Cross-ontology writes are unsupported and
are not a load-test workload.
EOF
}

die() {
  echo "cross-ontology-loadtest: $*" >&2
  exit 2
}

take_value() {
  case "$1" in
    *=*) ARG_VALUE=${1#*=}; ARG_SHIFT=1 ;;
    *)   [ "$#" -ge 2 ] || die "missing value for $1"
         ARG_VALUE=$2; ARG_SHIFT=2 ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --source-endpoints|--source-endpoints=*) take_value "$@"; SOURCE_ENDPOINTS=$ARG_VALUE ;;
    --source-ns|--source-ns=*) take_value "$@"; SOURCE_NS=$ARG_VALUE ;;
    --target-ns|--target-ns=*) take_value "$@"; TARGET_NS=$ARG_VALUE ;;
    --goal|--goal=*) take_value "$@"; GOAL=$ARG_VALUE ;;
    --requests|--requests=*) take_value "$@"; REQUESTS=$ARG_VALUE ;;
    --concurrency|--concurrency=*) take_value "$@"; CONCURRENCY=$ARG_VALUE ;;
    --http-timeout|--http-timeout=*) take_value "$@"; HTTP_TIMEOUT_S=$ARG_VALUE ;;
    --preflight-timeout|--preflight-timeout=*) take_value "$@"; PREFLIGHT_TIMEOUT_S=$ARG_VALUE ;;
    --max-failures|--max-failures=*) take_value "$@"; MAX_FAILURES=$ARG_VALUE ;;
    --result-dir|--result-dir=*) take_value "$@"; RESULT_DIR=$ARG_VALUE ;;
    -*) die "unknown option: $1" ;;
    *)  die "unexpected positional argument: $1" ;;
  esac
  shift "$ARG_SHIFT"
done

command -v curl >/dev/null || die "curl is required"
command -v jq >/dev/null || die "jq is required"

validate_uint() {
  [[ "$2" =~ ^[0-9]+$ ]] || die "$1 must be a non-negative integer, got '$2'"
}

[ -n "$SOURCE_ENDPOINTS" ] || die "source-endpoints is required"
[ -n "$SOURCE_NS" ] || die "source-ns is required"
[ -n "$TARGET_NS" ] || die "target-ns is required"
[ "$SOURCE_NS" != "$TARGET_NS" ] || die "source-ns and target-ns must differ"
[ -n "$GOAL" ] || die "goal must not be empty"
for pair in "requests:$REQUESTS" "concurrency:$CONCURRENCY" \
            "http-timeout:$HTTP_TIMEOUT_S" "preflight-timeout:$PREFLIGHT_TIMEOUT_S" \
            "max-failures:$MAX_FAILURES"; do
  name=${pair%%:*}; value=${pair#*:}
  validate_uint "$name" "$value"
done
[ "$REQUESTS" -gt 0 ] || die "requests must be positive"
[ "$CONCURRENCY" -gt 0 ] || die "concurrency must be positive"
[ "$HTTP_TIMEOUT_S" -gt 0 ] || die "http-timeout must be positive"

IFS=',' read -r -a RAW_ENDPOINTS <<< "$SOURCE_ENDPOINTS"
ENDPOINTS=()
declare -A SEEN_ENDPOINTS=()
for endpoint in "${RAW_ENDPOINTS[@]}"; do
  endpoint=${endpoint%/}
  [[ "$endpoint" =~ ^https?://[^[:space:]/]+(:[0-9]+)?$ ]] ||
    die "bad source endpoint '$endpoint' (use an http(s) base URL)"
  if [ -z "${SEEN_ENDPOINTS[$endpoint]+present}" ]; then
    ENDPOINTS+=("$endpoint")
    SEEN_ENDPOINTS[$endpoint]=1
  fi
done
[ "${#ENDPOINTS[@]}" -gt 0 ] || die "source-endpoints contained no endpoint"

if [ -z "$RESULT_DIR" ]; then
  SOURCE_LABEL=${SOURCE_NS//[^a-zA-Z0-9_.-]/_}
  TARGET_LABEL=${TARGET_NS//[^a-zA-Z0-9_.-]/_}
  RESULT_DIR="/tmp/quod-cross-ontology-${SOURCE_LABEL}-to-${TARGET_LABEL}-$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$RESULT_DIR/requests" "$RESULT_DIR/responses"

INNER_GOAL=${GOAL%.}
CALL_GOAL="${TARGET_NS}::(${INNER_GOAL})"
REQUEST_BODY=$(jq -cn --arg ns "$SOURCE_NS" --arg goal "$CALL_GOAL" \
  '{ns: $ns, goal: $goal}')

cleanup() {
  rm -f "$RESULT_DIR"/.warmup.* 2>/dev/null || true
}
trap cleanup EXIT

# Output: endpoint, curl_rc, HTTP status, elapsed_ms, result/error, success.
# Transport/application failures are data, not shell failures that could silently
# shorten the offered workload.
run_proof() {
  local endpoint=$1 response=$2 result rc code elapsed_ms detail success
  local start_ns end_ns
  start_ns=$(date +%s%N)
  if result=$(curl -sS --connect-timeout 3 --max-time "$HTTP_TIMEOUT_S" \
                 -o "$response" -w '%{http_code}' \
                 -H 'content-type: application/json' -X POST \
                 --data-binary "$REQUEST_BODY" "$endpoint/api/prove" 2>/dev/null); then
    rc=0
  else
    rc=$?
  fi
  end_ns=$(date +%s%N)
  elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
  code=${result:-000}
  detail=$(jq -r '
    if .result? then "result:" + (.result | tostring)
    elif .error? then "error:" + (.error | tostring)
    else "invalid_response"
    end
  ' "$response" 2>/dev/null || printf 'no_response')
  detail=${detail//$'\t'/ }
  detail=${detail//$'\n'/ }
  if [ "$rc" -eq 0 ] && [ "$code" = 200 ] &&
       jq -e '.result == "ok"' "$response" >/dev/null 2>&1; then
    success=1
  else
    success=0
  fi
  printf '%s\t%d\t%s\t%d\t%s\t%d\n' \
    "$endpoint" "$rc" "$code" "$elapsed_ms" "$detail" "$success"
}

source_summary() {
  local endpoint=$1 payload
  payload=$(curl -fsS --connect-timeout 2 --max-time 3 \
                    "$endpoint/api/summary" 2>/dev/null) || return 1
  printf '%s\n' "$payload" |
    jq -er --arg source "$SOURCE_NS" --arg target "$TARGET_NS" '
      (.node.id // error("missing node id")) as $node
      | ([.namespaces[] | select(.ns == $source)]) as $sources
      | ([.namespaces[] | select(.ns == $target)]) as $targets
      | if ($sources | length) != 1 then error("source missing or duplicated")
        elif ($targets | length) != 0 then error("target co-hosted")
        elif $sources[0].syncing != false then error("source syncing")
        else [$node, $sources[0].role, ($sources[0].height | tostring)] | @tsv
        end'
}

PREFLIGHT_ERROR=
preflight() {
  local endpoint row node role height warmup response
  local output="$RESULT_DIR/preflight.tsv.tmp"
  : > "$output"
  PREFLIGHT_ERROR=
  for endpoint in "${ENDPOINTS[@]}"; do
    if ! row=$(source_summary "$endpoint"); then
      PREFLIGHT_ERROR="$endpoint does not exclusively host ready $SOURCE_NS"
      return 1
    fi
    IFS=$'\t' read -r node role height <<< "$row"
    response="$RESULT_DIR/.warmup.$RANDOM.json"
    warmup=$(run_proof "$endpoint" "$response")
    rm -f "$response"
    if [ "$(awk -F'\t' '{print $6}' <<< "$warmup")" != 1 ]; then
      PREFLIGHT_ERROR="$endpoint remote warmup failed: $(awk -F'\t' '{print $2 "/" $3 "/" $5}' <<< "$warmup")"
      return 1
    fi
    printf '%s\t%s\t%s\t%s\n' "$endpoint" "$node" "$role" "$height" >> "$output"
  done
  mv "$output" "$RESULT_DIR/preflight.tsv"
}

wait_for_preflight() {
  local deadline=$((SECONDS + PREFLIGHT_TIMEOUT_S))
  while ! preflight; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      die "preflight did not establish a remote directory path: ${PREFLIGHT_ERROR:-unknown error}"
    fi
    echo "preflight waiting: ${PREFLIGHT_ERROR:-incomplete}" >&2
    sleep 1
  done
}

wait_for_preflight

echo "cross-ontology fixed-work benchmark"
echo "  source:      $SOURCE_NS (${#ENDPOINTS[@]} endpoint(s))"
echo "  target:      $TARGET_NS"
echo "  remote goal: $CALL_GOAL"
echo "  work:        $REQUESTS proofs at concurrency $CONCURRENCY"
echo "  sources:"
awk -F'\t' '{printf "    %s node=%s role=%s height=%s\\n", $1, $2, $3, $4}' \
  "$RESULT_DIR/preflight.tsv"

START_NS=$(date +%s%N)
active=0
for ((request_no = 1; request_no <= REQUESTS; request_no += 1)); do
  endpoint=${ENDPOINTS[$(( (request_no - 1) % ${#ENDPOINTS[@]} ))]}
  response="$RESULT_DIR/responses/$(printf '%06d' "$request_no").json"
  run_proof "$endpoint" "$response" > "$RESULT_DIR/requests/$(printf '%06d' "$request_no").tsv" &
  active=$((active + 1))
  if [ "$active" -ge "$CONCURRENCY" ]; then
    wait -n || true
    active=$((active - 1))
  fi
done
while [ "$active" -gt 0 ]; do
  wait -n || true
  active=$((active - 1))
done
END_NS=$(date +%s%N)

cat "$RESULT_DIR"/requests/*.tsv > "$RESULT_DIR/results.tsv"
TOTAL=$(wc -l < "$RESULT_DIR/results.tsv")
SUCCESS=$(awk -F'\t' '$6 == 1 {n += 1} END {print n + 0}' "$RESULT_DIR/results.tsv")
FAILURES=$((TOTAL - SUCCESS))
ELAPSED_MS=$(( (END_NS - START_NS) / 1000000 ))

quantile_ms() {
  local p=$1
  awk -F'\t' '$6 == 1 {print $4}' "$RESULT_DIR/results.tsv" |
    sort -n |
    awk -v p="$p" '{v[++n]=$1} END {
      if (n == 0) { print "nan"; exit }
      i = int(p*n); if (i < p*n) i++; if (i < 1) i = 1
      printf "%d", v[i]
    }'
}

MAX_MS=$(awk -F'\t' '$6 == 1 && $4 > m {m = $4} END {print m + 0}' "$RESULT_DIR/results.tsv")
RATE=$(awk -v n="$SUCCESS" -v ms="$ELAPSED_MS" \
  'BEGIN {if (ms > 0) printf "%.2f", n * 1000 / ms; else print "nan"}')

echo
echo "result"
echo "  operations: $TOTAL"
echo "  succeeded:  $SUCCESS"
echo "  failures:   $FAILURES"
echo "  latency:    p50=$(quantile_ms 0.50)ms p90=$(quantile_ms 0.90)ms p99=$(quantile_ms 0.99)ms max=${MAX_MS}ms"
echo "  makespan:   ${ELAPSED_MS}ms (${RATE} successful remote proofs/s)"
echo "  outcomes:"
awk -F'\t' '{key = $2 "/" $3 "/" $5; count[key] += 1} END {for (key in count) print "    " key ": " count[key]}' \
  "$RESULT_DIR/results.tsv" | sort
echo "  raw data:   $RESULT_DIR/results.tsv"

if [ "$FAILURES" -le "$MAX_FAILURES" ]; then
  echo "PASS"
  exit 0
fi
echo "FAIL: failures=$FAILURES exceeds max-failures=$MAX_FAILURES" >&2
exit 1
