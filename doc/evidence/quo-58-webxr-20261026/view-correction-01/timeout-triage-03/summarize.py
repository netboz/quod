"""Summarize diagnostic phase records without evaluating Erlang terms."""
import json
import re
from pathlib import Path

root = Path(__file__).resolve().parent
rows = []
previous = {}
for record in re.split(r"(?m)(?=^#\{pid =>)", (root / "editor-phases.term").read_text()):
    if not record.strip():
        continue
    def number(key):
        return int(re.search(r"\b" + key + r" => (-?\d+)", record)[1])
    run = re.search(r'run => "([^"]+)"', record)[1]
    row = {"run": run, "phase": re.search(r"phase => (\w+)", record)[1]}
    row.update({key: number(key) for key in (
        "at_us", "memory", "total_heap_size", "reductions", "message_queue_len")})
    if run in previous:
        prior = previous[run]
        row["elapsed_since_previous_us"] = row["at_us"] - prior["at_us"]
        row["reductions_since_previous"] = row["reductions"] - prior["reductions"]
    previous[run] = row
    rows.append(row)
(root / "phase-summary.json").write_text(json.dumps(rows, indent=2) + "\n")
for row in rows:
    print(row["run"], row["phase"],
          row.get("elapsed_since_previous_us"), row.get("reductions_since_previous"),
          "memory", row["memory"])
