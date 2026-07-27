#!/usr/bin/env bash
#
# Fixed-work transaction benchmark for controlled revision A/B tests.
#
# Unlike loadtest.sh, this driver offers exactly the configured number of logical
# writes on a fixed wave schedule. It follows only authoritative 409/503 responses
# with the same goal; transport failures and 202 outcome_unknown are never retried.
# Each run must use a fresh predicate so relation size does not bias the next revision.
#
set -euo pipefail

: "${CONSUL_ADDR:=http://192.168.1.10:8500}"
: "${NS:=quod:root}"
: "${TX_PREDICATE:=}"
: "${WAVES:=6}"
: "${REQUESTS_PER_NODE:=40}"
: "${WAVE_INTERVAL_S:=5}"
: "${HTTP_TIMEOUT_S:=35}"
: "${MAX_ATTEMPTS:=100}"
: "${RETRY_DELAY_MS:=40}"
: "${PREFLIGHT_TIMEOUT_S:=30}"
: "${EXPECTED_INGRESS_RETARGET:=}"
: "${RESULT_DIR:=}"

usage() {
  cat <<'EOF'
Usage: scripts/perf-test.sh --tx-predicate ATOM [options]

Submit a fixed number of writes to every directly reachable home validator.
Each logical write is measured end to end. Only authoritative 409/503 responses
are retried; failures and ambiguous outcomes remain visible.

Options:
  --tx-predicate ATOM       fresh predicate for this run (required)
  --namespace NAME          ontology namespace (default: quod:root)
  --waves N                 number of request waves (default: 6)
  --requests-per-node N     concurrent requests per endpoint per wave (default: 40)
  --wave-interval SEC       delay between wave starts (default: 5)
  --http-timeout SEC        per-request curl timeout (default: 35)
  --max-attempts N          maximum HTTP attempts per operation (default: 100)
  --retry-delay-ms MS       delay between safe retries (default: 40)
  --preflight-timeout SEC   wait for one fully converged fleet snapshot (default: 30)
  --expected-ingress-retarget true|false
                            require this fleet-wide retarget gate (optional)
  --consul-addr URL         Consul HTTP endpoint
  --result-dir PATH         retain raw request timings here
  --help                    show this help

Example:
  scripts/perf-test.sh --tx-predicate loadtest_ab_current_1
EOF
}

die() {
  echo "perf-test: $*" >&2
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
    --tx-predicate|--tx-predicate=*) take_value "$@"; TX_PREDICATE=$ARG_VALUE ;;
    --namespace|--namespace=*) take_value "$@"; NS=$ARG_VALUE ;;
    --waves|--waves=*) take_value "$@"; WAVES=$ARG_VALUE ;;
    --requests-per-node|--requests-per-node=*) take_value "$@"; REQUESTS_PER_NODE=$ARG_VALUE ;;
    --wave-interval|--wave-interval=*) take_value "$@"; WAVE_INTERVAL_S=$ARG_VALUE ;;
    --http-timeout|--http-timeout=*) take_value "$@"; HTTP_TIMEOUT_S=$ARG_VALUE ;;
    --max-attempts|--max-attempts=*) take_value "$@"; MAX_ATTEMPTS=$ARG_VALUE ;;
    --retry-delay-ms|--retry-delay-ms=*) take_value "$@"; RETRY_DELAY_MS=$ARG_VALUE ;;
    --preflight-timeout|--preflight-timeout=*) take_value "$@"; PREFLIGHT_TIMEOUT_S=$ARG_VALUE ;;
    --expected-ingress-retarget|--expected-ingress-retarget=*)
      take_value "$@"; EXPECTED_INGRESS_RETARGET=$ARG_VALUE ;;
    --consul-addr|--consul-addr=*) take_value "$@"; CONSUL_ADDR=$ARG_VALUE ;;
    --result-dir|--result-dir=*) take_value "$@"; RESULT_DIR=$ARG_VALUE ;;
    -*) die "unknown option: $1" ;;
    *)  die "unexpected positional argument: $1" ;;
  esac
  shift "$ARG_SHIFT"
done

command -v curl >/dev/null || die "curl is required"
command -v jq >/dev/null || die "jq is required"
[[ "$TX_PREDICATE" =~ ^[a-z][a-zA-Z0-9_]{0,63}$ ]] ||
  die "tx-predicate is required and must be an unquoted Prolog atom of at most 64 characters"
for pair in "waves:$WAVES" "requests-per-node:$REQUESTS_PER_NODE" \
            "wave-interval:$WAVE_INTERVAL_S" "http-timeout:$HTTP_TIMEOUT_S" \
            "max-attempts:$MAX_ATTEMPTS" "retry-delay-ms:$RETRY_DELAY_MS" \
            "preflight-timeout:$PREFLIGHT_TIMEOUT_S"; do
  name=${pair%%:*}; value=${pair#*:}
  [[ "$value" =~ ^[0-9]+$ ]] || die "$name must be a non-negative integer"
done
[ "$WAVES" -gt 0 ] || die "waves must be positive"
[ "$REQUESTS_PER_NODE" -gt 0 ] || die "requests-per-node must be positive"
[ "$MAX_ATTEMPTS" -gt 0 ] || die "max-attempts must be positive"
case "$EXPECTED_INGRESS_RETARGET" in
  ""|true|false) ;;
  *) die "expected-ingress-retarget must be true or false" ;;
esac

if [ -z "$RESULT_DIR" ]; then
  RESULT_DIR="/tmp/quod-perf-$(date +%Y%m%d-%H%M%S)-$TX_PREDICATE"
fi
mkdir -p "$RESULT_DIR/requests"

mapfile -t CANDIDATE_ENDPOINTS < <(
  curl -fsS "$CONSUL_ADDR/v1/health/service/quod-explorer?passing=true" |
    jq -r '.[] |
      "http://\(.Service.Address):\(.Service.Port)"' |
    sort -u
)
ENDPOINTS=()
for endpoint in "${CANDIDATE_ENDPOINTS[@]}"; do
  if curl -fsS --connect-timeout 1 --max-time 2 -o /dev/null \
       "$endpoint/health" 2>/dev/null; then
    ENDPOINTS+=("$endpoint")
  fi
done
[ "${#ENDPOINTS[@]}" -gt 0 ] || die "no directly reachable explorer endpoints"

mapfile -t METRICS_ENDPOINTS < <(
  curl -fsS "$CONSUL_ADDR/v1/health/service/quod-metrics?passing=true" |
    jq -r '.[] |
      "http://\(.Service.Address):\(.Service.Port)"' |
    sort -u
)
[ "${#METRICS_ENDPOINTS[@]}" -gt 0 ] ||
  die "no passing metrics endpoints available for configuration preflight"

NS_JSON=$(jq -Rn --arg ns "$NS" '$ns')

batch_metric_row() {
  awk -v ns="$NS" '
    function label_value(labels, key, marker, pos, tail, ending) {
      marker = key "=\""
      pos = index(labels, marker)
      if (pos == 0) return ""
      tail = substr(labels, pos + length(marker))
      ending = index(tail, "\"")
      if (ending == 0) return ""
      return substr(tail, 1, ending - 1)
    }
    $1 ~ /^quod_consensus_batch_window_ms\{/ {
      namespace = label_value($1, "namespace")
      node = label_value($1, "node_id")
      if (namespace == ns && node != "" && $2 ~ /^[0-9]+([.]0+)?$/) {
        printf "%s\t%d\n", node, $2
        exit
      }
    }
  '
}

# Build one authoritative fleet snapshot before any write is offered. Explorer
# supplies full identity, consensus role/frontier, applied projection, genesis,
# and committee; the matching node_id label on /metrics supplies the deployed
# batch window, which /api/summary does not expose. A stale, incomplete, or
# partially reachable rollout therefore fails closed instead of contaminating an
# A/B leg with one recovering or differently configured writer.
PREFLIGHT_ERROR=
preflight_snapshot() {
  local output="$RESULT_DIR/preflight.tsv.tmp"
  local endpoint payload row node pubkey batch role syncing node_height applied
  local genesis committee_size node_in_committee committee reachable_count
  local committee_id ingress_retarget
  local reference_height= reference_committee= reference_batch=
  local reference_genesis= reference_committee_size=
  local reference_committee_id= reference_ingress_retarget=
  local -A batch_by_node=()
  local -A metrics_by_node=()
  local -A seen_nodes=()
  local -A seen_pubkeys=()

  PREFLIGHT_ERROR=
  : > "$output"

  for endpoint in "${METRICS_ENDPOINTS[@]}"; do
    if ! payload=$(curl -fsS --connect-timeout 1 --max-time 3 \
                         "$endpoint/metrics" 2>/dev/null); then
      continue
    fi
    row=$(printf '%s\n' "$payload" | batch_metric_row)
    [ -n "$row" ] || continue
    IFS=$'\t' read -r node batch <<< "$row"
    if [ -n "${batch_by_node[$node]+present}" ] &&
       [ "${batch_by_node[$node]}" != "$batch" ]; then
      PREFLIGHT_ERROR="node $node exposes conflicting batch windows"
      return 1
    fi
    batch_by_node[$node]=$batch
    metrics_by_node[$node]=$endpoint
  done

  for endpoint in "${ENDPOINTS[@]}"; do
    if ! payload=$(curl -fsS --connect-timeout 1 --max-time 3 \
                         "$endpoint/api/summary" 2>/dev/null); then
      PREFLIGHT_ERROR="$endpoint summary is unreachable"
      return 1
    fi
    if ! row=$(
      printf '%s\n' "$payload" |
        jq -er --arg ns "$NS" '
          (.node.id // error("missing node id")) as $node
          | (.node.pubkey // error("missing node pubkey")) as $pubkey
          | ([.namespaces[] | select(.ns == $ns)]) as $matches
          | if ($matches | length) != 1
            then error("namespace missing or duplicated")
            else $matches[0]
            end as $n
          | ($n.committee
             | map(.pubkey // error("committee pubkey missing"))
             | sort) as $committee
          | ($n.committee_id // error("missing committee_id")) as $committee_id
          | ($n.ingress_retarget
             | if type == "boolean"
               then tostring
               else error("invalid ingress_retarget")
               end) as $ingress_retarget
          | [$node,
             $pubkey,
             $n.role,
             ($n.syncing | tostring),
             ($n.height | tostring),
             ($n.applied | tostring),
             ($n.genesis // error("missing genesis")),
             ($committee | length | tostring),
             (($committee | index($pubkey)) != null | tostring),
             ($committee | join(",")),
             $committee_id,
             $ingress_retarget]
          | @tsv'
    ); then
      PREFLIGHT_ERROR="$endpoint has no complete $NS status"
      return 1
    fi
    IFS=$'\t' read -r node pubkey role syncing node_height applied genesis \
      committee_size node_in_committee committee committee_id \
      ingress_retarget <<< "$row"

    if [ "$role" != validator ] || [ "$syncing" != false ]; then
      PREFLIGHT_ERROR="$endpoint node=$node is role=$role syncing=$syncing"
      return 1
    fi
    if ! [[ "$pubkey" =~ ^[0-9a-f]{64}$ ]]; then
      PREFLIGHT_ERROR="$endpoint node=$node reports invalid full pubkey"
      return 1
    fi
    if ! [[ "$node_height" =~ ^[0-9]+$ ]] || [ "$node_height" -lt 1 ]; then
      PREFLIGHT_ERROR="$endpoint node=$node reports invalid height=$node_height"
      return 1
    fi
    if ! [[ "$applied" =~ ^[0-9]+$ ]] || [ "$applied" != "$node_height" ]; then
      PREFLIGHT_ERROR="$endpoint node=$node applied=$applied height=$node_height"
      return 1
    fi
    if ! [[ "$genesis" =~ ^[0-9a-f]{64}$ ]]; then
      PREFLIGHT_ERROR="$endpoint node=$node reports invalid genesis"
      return 1
    fi
    if ! [[ "$committee_size" =~ ^[0-9]+$ ]] || [ "$committee_size" -lt 1 ]; then
      PREFLIGHT_ERROR="$endpoint node=$node reports invalid committee size=$committee_size"
      return 1
    fi
    if [ -z "$committee" ]; then
      PREFLIGHT_ERROR="$endpoint node=$node reports an empty committee"
      return 1
    fi
    if [ "$node_in_committee" != true ]; then
      PREFLIGHT_ERROR="$endpoint node=$node pubkey is absent from its committee"
      return 1
    fi
    if ! [[ "$committee_id" =~ ^[0-9a-f]{64}$ ]]; then
      PREFLIGHT_ERROR="$endpoint node=$node reports invalid committee_id"
      return 1
    fi
    case "$ingress_retarget" in
      true|false) ;;
      *)
        PREFLIGHT_ERROR="$endpoint node=$node reports invalid ingress_retarget=$ingress_retarget"
        return 1
        ;;
    esac
    if [ -n "$EXPECTED_INGRESS_RETARGET" ] &&
       [ "$ingress_retarget" != "$EXPECTED_INGRESS_RETARGET" ]; then
      PREFLIGHT_ERROR="$endpoint ingress_retarget=$ingress_retarget expected=$EXPECTED_INGRESS_RETARGET"
      return 1
    fi
    if [ -n "${seen_nodes[$node]+present}" ]; then
      PREFLIGHT_ERROR="duplicate explorer identity $node"
      return 1
    fi
    if [ -n "${seen_pubkeys[$pubkey]+present}" ]; then
      PREFLIGHT_ERROR="duplicate explorer validator pubkey $pubkey"
      return 1
    fi
    seen_nodes[$node]=$endpoint
    seen_pubkeys[$pubkey]=$endpoint
    if [ -z "${batch_by_node[$node]+missing}" ]; then
      PREFLIGHT_ERROR="$endpoint node=$node has no reachable matching metrics service"
      return 1
    fi
    batch=${batch_by_node[$node]}

    if [ -z "$reference_height" ]; then
      reference_height=$node_height
      reference_committee=$committee
      reference_batch=$batch
      reference_genesis=$genesis
      reference_committee_size=$committee_size
      reference_committee_id=$committee_id
      reference_ingress_retarget=$ingress_retarget
    elif [ "$node_height" != "$reference_height" ]; then
      PREFLIGHT_ERROR="height divergence: $endpoint=$node_height expected=$reference_height"
      return 1
    elif [ "$committee" != "$reference_committee" ]; then
      PREFLIGHT_ERROR="committee divergence at $endpoint node=$node"
      return 1
    elif [ "$batch" != "$reference_batch" ]; then
      PREFLIGHT_ERROR="batch_window_ms divergence: $endpoint=$batch expected=$reference_batch"
      return 1
    elif [ "$genesis" != "$reference_genesis" ]; then
      PREFLIGHT_ERROR="genesis divergence at $endpoint node=$node"
      return 1
    elif [ "$committee_size" != "$reference_committee_size" ]; then
      PREFLIGHT_ERROR="committee-size divergence at $endpoint node=$node"
      return 1
    elif [ "$committee_id" != "$reference_committee_id" ]; then
      PREFLIGHT_ERROR="committee_id divergence at $endpoint node=$node"
      return 1
    elif [ "$ingress_retarget" != "$reference_ingress_retarget" ]; then
      PREFLIGHT_ERROR="ingress_retarget divergence: $endpoint=$ingress_retarget expected=$reference_ingress_retarget"
      return 1
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$endpoint" "$node" "$node_height" "$batch" "$role" \
      "${metrics_by_node[$node]}" "$pubkey" "$applied" "$genesis" \
      "$committee_size" "$committee" "$committee_id" \
      "$ingress_retarget" >> "$output"
  done

  reachable_count=${#seen_pubkeys[@]}
  if [ "$reachable_count" -ne "$reference_committee_size" ]; then
    PREFLIGHT_ERROR="reachable validators=$reachable_count committee_size=$reference_committee_size"
    return 1
  fi

  mv "$output" "$RESULT_DIR/preflight.tsv"
  return 0
}

wait_for_preflight() {
  local deadline=$((SECONDS + PREFLIGHT_TIMEOUT_S))
  while ! preflight_snapshot; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      die "cluster preflight did not converge: ${PREFLIGHT_ERROR:-unknown error}"
    fi
    echo "preflight waiting: ${PREFLIGHT_ERROR:-incomplete snapshot}" >&2
    sleep 1
  done

  echo "cluster preflight"
  awk -F'\t' '
    {printf "  %s node=%s height=%s applied=%s batch_window_ms=%s genesis=%s committee=%s committee_id=%s retarget=%s metrics=%s\n",
            $1, $2, $3, $8, $4, $9, $10, $12, $13, $6}
  ' "$RESULT_DIR/preflight.tsv"
}

height() {
  local attempt endpoint value
  for attempt in 1 2 3; do
    for endpoint in "${ENDPOINTS[@]}"; do
      if value=$(
        curl -fsS --max-time 3 "$endpoint/api/summary" 2>/dev/null |
          jq -er --arg ns "$NS" '.namespaces[] | select(.ns == $ns) | .height'
      ); then
        echo "$value"
        return 0
      fi
    done
    sleep 1
  done
  return 1
}

run_request() {
  local endpoint=$1 id=$2 output=$3 body result response detail rc code
  local reason_key retry_reasons_text key
  local attempt=0 retry_retry=0 retry_busy=0 retry_other=0
  local -A retry_reasons=()
  local start_ns end_ns elapsed_s
  body="{\"ns\":$NS_JSON,\"goal\":\"assertz(${TX_PREDICATE}($id))\"}"
  response="${output}.response"
  start_ns=$(date +%s%N)
  while :; do
    attempt=$((attempt + 1))
    rm -f "$response"
    set +e
    result=$(curl -sS --max-time "$HTTP_TIMEOUT_S" -o "$response" \
      -w '%{http_code}\t%{time_total}' \
      -H 'content-type: application/json' -X POST --data-binary "$body" \
      "$endpoint/api/prove" 2>/dev/null)
    rc=$?
    set -e
    code=${result%%$'\t'*}
    detail=$(jq -r '.error // .result // "no_result"' "$response" 2>/dev/null || echo no_response)
    if [ "$rc" -ne 0 ] || [[ "$code" =~ ^2 ]] ||
       { [ "$code" != 409 ] && [ "$code" != 503 ]; } ||
       [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
      break
    fi
    case "$detail" in
      retry) retry_retry=$((retry_retry + 1)) ;;
      busy)  retry_busy=$((retry_busy + 1)) ;;
      *)     retry_other=$((retry_other + 1)) ;;
    esac
    reason_key=${detail//$'\t'/ }
    reason_key=${reason_key//$'\n'/ }
    reason_key=${reason_key//[^a-zA-Z0-9_.:-]/_}
    [ -n "$reason_key" ] || reason_key=no_detail
    reason_key="${code}:${reason_key}"
    retry_reasons["$reason_key"]=$(( ${retry_reasons["$reason_key"]:-0} + 1 ))
    sleep "$(printf '%d.%03d' "$((RETRY_DELAY_MS / 1000))" "$((RETRY_DELAY_MS % 1000))")"
  done
  end_ns=$(date +%s%N)
  elapsed_s=$(awk -v ns="$((end_ns - start_ns))" 'BEGIN {printf "%.6f", ns/1000000000}')
  detail=${detail//$'\t'/ }
  detail=${detail//$'\n'/ }
  retry_reasons_text=-
  if [ "${#retry_reasons[@]}" -gt 0 ]; then
    retry_reasons_text=
    while IFS= read -r key; do
      [ -n "$retry_reasons_text" ] && retry_reasons_text+=,
      retry_reasons_text+="${key}=${retry_reasons[$key]}"
    done < <(printf '%s\n' "${!retry_reasons[@]}" | sort)
  fi
  # Columns 1-9 retain the original schema. Column 10 adds exact HTTP/detail
  # retry counts, for example `409:not_leader=2,503:retry=1`.
  printf '%s\t%d\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%s\n' \
    "$endpoint" "$rc" "$code" "$elapsed_s" "$detail" "$attempt" \
    "$retry_retry" "$retry_busy" "$retry_other" "$retry_reasons_text" > "$output"
  rm -f "$response"
}

wait_for_preflight

# Warm connections and parser paths with a read-only goal outside the measurement.
for endpoint in "${ENDPOINTS[@]}"; do
  curl -fsS --max-time 3 -o /dev/null \
    -H 'content-type: application/json' -X POST \
    --data-binary "{\"ns\":$NS_JSON,\"goal\":\"true\"}" \
    "$endpoint/api/prove" || die "warmup failed for $endpoint"
done

START_HEIGHT=$(height || echo -1)
START_NS=$(date +%s%N)
declare -a PIDS=()
request_no=0

echo "fixed-work benchmark"
echo "  predicate: $TX_PREDICATE"
echo "  endpoints: ${#ENDPOINTS[@]}"
echo "  work:      $WAVES waves x $REQUESTS_PER_NODE requests x ${#ENDPOINTS[@]} nodes"
echo "  start:     height $START_HEIGHT"

for ((wave=1; wave<=WAVES; wave++)); do
  wave_start=$(date +%s%N)
  for endpoint in "${ENDPOINTS[@]}"; do
    for ((n=1; n<=REQUESTS_PER_NODE; n++)); do
      request_no=$((request_no + 1))
      tx_id="${START_NS}${wave}${request_no}"
      run_request "$endpoint" "$tx_id" \
        "$RESULT_DIR/requests/$(printf '%06d' "$request_no").tsv" &
      PIDS+=("$!")
    done
  done
  echo "  wave $wave/$WAVES offered ($request_no cumulative)"
  if [ "$wave" -lt "$WAVES" ]; then
    target=$((wave_start + WAVE_INTERVAL_S * 1000000000))
    now=$(date +%s%N)
    if [ "$now" -lt "$target" ]; then
      delay_ms=$(( (target - now) / 1000000 ))
      sleep "$(printf '%d.%03d' "$((delay_ms / 1000))" "$((delay_ms % 1000))")"
    fi
  fi
done

for pid in "${PIDS[@]}"; do
  wait "$pid" || true
done
END_NS=$(date +%s%N)

cat "$RESULT_DIR"/requests/*.tsv > "$RESULT_DIR/results.tsv"
END_HEIGHT=$(height || echo -1)
ELAPSED_MS=$(( (END_NS - START_NS) / 1000000 ))

# results.tsv is TAB-separated and the `detail` field (col 5) can contain spaces.
# Columns 1-9 preserve the original schema; column 10 is a comma-separated
# `HTTP:reason=count` map for every safely retried response. Every reader MUST
# split on tab only (-F'\t'), or later columns shift.
TOTAL=$(wc -l < "$RESULT_DIR/results.tsv")
COMMITTED=$(awk -F'\t' '$2 == 0 && $3 == 200 {n++} END {print n+0}' "$RESULT_DIR/results.tsv")
UNKNOWN=$(awk -F'\t' '$2 == 0 && $3 == 202 {n++} END {print n+0}' "$RESULT_DIR/results.tsv")
FAILED=$((TOTAL - COMMITTED - UNKNOWN))
ATTEMPTS=$(awk -F'\t' '{n+=$6} END {print n+0}' "$RESULT_DIR/results.tsv")
read -r RETRY_RETRY RETRY_BUSY RETRY_OTHER < <(
  awk -F'\t' '{r+=$7; b+=$8; o+=$9} END {print r+0, b+0, o+0}' "$RESULT_DIR/results.tsv"
)

quantile_ms() {
  local p=$1
  awk -F'\t' '$2 == 0 && $3 == 200 {print $4 * 1000}' "$RESULT_DIR/results.tsv" |
    sort -n |
    awk -v p="$p" '{v[++n]=$1} END {
      if (n == 0) { print "nan"; exit }
      i = int(p*n); if (i < p*n) i++; if (i < 1) i=1
      printf "%.1f", v[i]
    }'
}

MAX_MS=$(
  awk -F'\t' '$2 == 0 && $3 == 200 {v=$4*1000; if (v>m) m=v} END {printf "%.1f", m+0}' \
    "$RESULT_DIR/results.tsv"
)
RATE=$(awk -v n="$COMMITTED" -v ms="$ELAPSED_MS" \
  'BEGIN {if (ms > 0) printf "%.2f", n*1000/ms; else print "nan"}')

echo
echo "result"
echo "  operations:$TOTAL"
echo "  HTTP tries:$ATTEMPTS ($((ATTEMPTS - TOTAL)) safe retries)"
echo "  retries:   retry=$RETRY_RETRY busy=$RETRY_BUSY other=$RETRY_OTHER (legacy classes)"
echo "  retry reasons:"
RETRY_REASON_SUMMARY=$(
  awk -F'\t' '
    $10 != "" && $10 != "-" {
      n = split($10, reasons, ",")
      for (i = 1; i <= n; i++) {
        split(reasons[i], pair, "=")
        count[pair[1]] += pair[2]
      }
    }
    END {
      for (reason in count) printf "%s\t%d\n", reason, count[reason]
    }
  ' "$RESULT_DIR/results.tsv" | sort
)
if [ -n "$RETRY_REASON_SUMMARY" ]; then
  while IFS=$'\t' read -r reason count; do
    printf '    %s: %s\n' "$reason" "$count"
  done <<< "$RETRY_REASON_SUMMARY"
else
  echo "    none"
fi
echo "  committed: $COMMITTED"
echo "  unknown:   $UNKNOWN (202 outcome_unknown; never retried)"
echo "  failures:  $FAILED"
echo "  HTTP/rc:"
awk -F'\t' '{key=$2 "/" $3 "/" $5; count[key]++} END {for (key in count) print "    " key ": " count[key]}' \
  "$RESULT_DIR/results.tsv" | sort
echo "  latency:   p50=$(quantile_ms 0.50)ms p90=$(quantile_ms 0.90)ms p95=$(quantile_ms 0.95)ms p99=$(quantile_ms 0.99)ms max=${MAX_MS}ms"
echo "  makespan:  ${ELAPSED_MS}ms (${RATE} successful responses/s)"
echo "  ledger:    $START_HEIGHT -> $END_HEIGHT (+$((END_HEIGHT - START_HEIGHT)) blocks)"
echo "  raw data:  $RESULT_DIR/results.tsv"
