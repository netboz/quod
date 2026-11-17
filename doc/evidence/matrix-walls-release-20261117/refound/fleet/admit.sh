#!/usr/bin/env bash
# admit.sh: admit compute joiners idx 1..7 one at a time through validator idx 0,
# with the same goal and retry shape as scripts/loadtest.sh. Each admission waits
# for the founder's committee size to grow before the next one.
set -u
export NOMAD_ADDR=http://192.168.1.10:4646
NS=quod:root
LOG=/home/yan/src/quod_worktrees/pearl-stone/doc/evidence/matrix-walls-release-20261117/refound/fleet/admissions.log
alloc_of() { nomad job allocs -json quod | python3 -c "
import json,sys
a=[x for x in json.load(sys.stdin) if x['TaskGroup']=='quod-node' and x['ClientStatus']=='running' and x['Name'].endswith('[%s]'%sys.argv[1])]
print(a[0]['ID'] if len(a)==1 else '')" "$1"; }
committee() { timeout -k 5 25 nomad alloc exec -task quod "$1" /usr/bin/curl -s --max-time 4 http://127.0.0.1:14568/metrics 2>/dev/null |
  awk -v ns="$NS" 'index($0,"namespace=\"" ns "\"") && $1 ~ /^quod_consensus_committee_size\{/ {print $2+0; exit}'; }
identity() { timeout -k 5 25 nomad alloc exec -task quod "$1" /bin/sh -c '
set -eu
hex=$(/usr/bin/curl -fsS --max-time 4 http://127.0.0.1:14569/api/summary | grep -o "\"pubkey\":\"[0-9a-fA-F]\{64\}\"" | head -n 1 | sed "s/\"pubkey\":\"//; s/\"$//")
[ "${#hex}" -eq 64 ]
host=$(awk -F "\"" "/^[[:space:]]*ip[[:space:]]*=/{print \$2; exit}" "$NOMAD_TASK_DIR/quod.conf")
port=$(awk "/^[[:space:]]*port[[:space:]]*=/{print \$3; exit}" "$NOMAD_TASK_DIR/quod.conf")
printf "<<%s>>|%s|%s\n" "$(printf %s "$hex" | sed "s/../16#&,/g; s/,$//")" "$host" "$port"' 2>/dev/null; }
admit_code() { printf 'Ns= <<"%s">>, G={admit,%s,"%s",%d}, (fun T(0)->{error,exhausted}; T(K)->case (catch quod_prolog:prove(Ns,G)) of {ok,_,_}->admitted; {error,{not_leader,_}}->timer:sleep(200),T(K-1); {error,retry}->timer:sleep(200),T(K-1); {error,busy}->timer:sleep(200),T(K-1); {error,rebuilding}->timer:sleep(200),T(K-1); Other->Other end end)(200).' "$NS" "$1" "$2" "$3"; }

admitter=$(alloc_of 0); [ -n "$admitter" ] || { echo "no running idx 0" >&2; exit 1; }
for idx in 1 2 3 4 5 6 7; do
  cand=$(alloc_of $idx); [ -n "$cand" ] || { echo "idx=$idx no running allocation" | tee -a $LOG; exit 1; }
  IFS='|' read -r pk host port <<< "$(identity "$cand")"
  [ -n "$pk" ] || { echo "idx=$idx ${cand:0:8} identity unreadable" | tee -a $LOG; exit 1; }
  before=$(committee "$admitter")
  r=$(timeout -k 5 70 nomad alloc exec -task quod "$admitter" /opt/quod/bin/quod eval "$(admit_code "$pk" "$host" "$port")" 2>/dev/null)
  cs=$before
  for i in $(seq 1 24); do cs=$(committee "$admitter"); [ "${cs:-0}" -gt "${before:-0}" ] && break; sleep 5; done
  echo "idx=$idx ${cand:0:8} $host:$port admit=$r committee=$cs" | tee -a $LOG
  [ "${cs:-0}" -gt "${before:-0}" ] || { echo "idx=$idx committee did not grow; stopping" | tee -a $LOG; exit 1; }
done
