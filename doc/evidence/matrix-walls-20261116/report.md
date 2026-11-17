# Matrix walls build — report (2026-11-16)

Tree: `worktree/pearl-stone`, built on `7b5a4d8c` (0.7.293).

## Gates (final tree)

| run | result |
|---|---|
| **server-02** (`server-gates-02.py`) | **eunit 4370/0, ct 150/150, xref, dialyzer: all pass** |
| **client-05** (`client-gates-05.py`) | **all 16 steps pass, `CLIENT_05_PASS`** |

Earlier runs, kept: server-01 had one `quod_physics_tests` custody failure
that passed alone (`server-01-triage-physics`) and did not recur in server-02.
client-01 (wrong font size in my check), client-02 (no notice when the rain
text arrived; the scene now raises `PresentationChanged`), client-03 (test
waited on a closed panel), client-04 (passed; tree changed after it).

## Measures

See `phase2.md`.

- Whole source of `quod:space` as stored: 83,185 bytes (6 chunks), complete
  read 22.8 ms on the node; it carries all five shared rule files. Not 117 KB:
  the node stores clauses, not files (no comments, variables `V0`…).
- Pie 417 → 413 ms; world view 44.3 → 43.2 ms (median of 41).
- Real client against the real fixture server (navigation journey, headless):
  source read once, 579–592 ms in the client, 83,2xx bytes, 73,1xx letters
  (84–86 distinct); returning to Default reads nothing.

## Images

- `matrix-walls.png` (client-05): inside a 4 × 3 × 5 m room with the green
  corner lines, real renderer, known short text.

## Yan's rulings after the first report (2026-11-16)

- No added world-view field: the change notice reaches the client as the
  world view's refresh. The named source is read once per sign-in. The
  approved text says "again only when that ontology changes"; a new
  `quod:space` shows after the next sign-in (releases are refounds).
- The browser is left alone (no change to `client/src`).
- `client/native` deleted (dead: no gate builds it);
  `doc/native-godot-client-plan.md` moved to `doc/outdated/`.

## Limits introduced (encoding constraints, stated)

- A rain text's cells must fit the device's largest 2D texture
  (limit × limit cells; 16384² on desktop Vulkan).
- At most 65,536 distinct letters per text (two bytes per cell); the atlas
  then needs (limit/64)² slots, the same bound at 16384.
- Without a rendering device (headless) the number 16384 only shapes textures.

## Not done

- Phase 8 needs Yan's headset: frame time with Wire and with Matrix, letter
  height (recipe says 100 mm), screen glow (off).
