"""Analyze archived public events; never connect to or control a browser."""
from collections import Counter
from pathlib import Path
import hashlib
import json
import re


def analyze(path):
    raw = path.read_bytes()
    document = json.loads(raw)
    events = document if isinstance(document, list) else document.get("events")
    if not events or not isinstance(events[0], dict) or "data" not in events[0]:
        return None
    frames = [event["data"]["frame"] for event in events
              if isinstance(event.get("data", {}).get("frame"), dict)]
    contacts = [re.findall(r"contact\((\d+),", str(
        frame.get("control_state", {}).get("result", ""))) for frame in frames]
    refreshes = []
    for index, event in enumerate(events):
        if event["data"].get("type") != "refresh":
            continue
        following = next((candidate for candidate in events[index + 1:]
                          if candidate["data"].get("type") == "projection"), None)
        start = event.get("timestamp")
        end = following.get("timestamp") if following else None
        refreshes.append({
            "reason": event["data"].get("reason"),
            "next_projection_ms": round(1000 * (end - start), 3)
            if start is not None and end is not None else None,
        })
    return {
        "sha256": hashlib.sha256(raw).hexdigest(),
        "physical_frames": len(frames),
        "frames_with_eight_or_more_contacts": sum(len(row) >= 8 for row in contacts),
        "frames_with_eight_floor_contacts": sum(row == ["1"] * 8 for row in contacts),
        "contact_entries_by_body": dict(sorted(Counter(
            body for row in contacts for body in row).items())),
        "generation_structure_body_revisions": sorted({
            (str(frame.get("generation")), str(frame.get("structure")),
             tuple((str(pose["body"]), str(pose["revision"]))
                   for pose in frame.get("poses", []))) for frame in frames}),
        "refreshes": refreshes,
    }


if __name__ == "__main__":
    root = Path(__file__).resolve().parent.parent
    paths = [root / "desktop-260-06/movement-stutters-01.json"]
    paths.extend(path for directory in sorted(root.glob("desktop-261-*"))
                 for path in sorted(directory.glob("*.json"))
                 if path.name != "trace-analysis.json")
    results = {}
    for path in paths:
        result = analyze(path)
        if result is not None:
            results[str(path.relative_to(root))] = result
    print(json.dumps({
        "method": "Offline event analysis; buffers may precede input; no key-state correlation",
        "traces": results,
    }, indent=2))
