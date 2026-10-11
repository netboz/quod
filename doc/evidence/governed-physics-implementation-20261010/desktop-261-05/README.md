# Desktop campaign 261-05: visible strafe and gaming pause

The same signed profile runs the native Wayland browser with the inherited
AppImage library path and `CHROME_DESKTOP` removed. The compositor now identifies
it as `chromium-browser`. Removing inherited launcher settings is diagnostic
harness configuration, not a production client change or an established cure
for the earlier internal-pipe hang.

The initial compositor placement is still off-screen. The old focus command
fails with exit 7 and its output is retained. The installed Hyprland dispatcher
accepts the Lua-form command in [the successful result](focus-current-api-result.json).
Tool-call or user focus changes can move the browser off-screen again, so
`Page.bringToFront` alone does not make the first strafe's one-callback result
a valid foreground measurement.

For [foreground-strafe-02](foreground-strafe-02-summary.json), the diagnostic
focuses only its owned browser, observes nine animation timestamps at roughly
16.5 ms intervals and verifies the compositor's active PID immediately before
ordinary input. That [visibility receipt](foreground-strafe-02-visibility.json)
binds the successful check. The 500 ms strafe records 30 animation callbacks
over 513 ms, 32 collected physical frames and 15 accepted control responses,
with none refused. The body moves from `(3.4363, 0.7513, 5.6744)` to
`(4.3570, 0.7518, 5.5262)` metres. Floor contact remains active, without the
old eight-contact stall. These short observations do not establish sustained
smoothness or eliminate every possible source of intermittent pauses.

Yan then asked to play Project Zomboid while testing continues. The completed
step released its keys, and [the handoff](noninterference-handoff.json) records
no remaining input worker. Further work is restricted to background analysis;
browser focus, keyboard and mouse control are deferred. Low-roof collision and
longer visible movement checks remain outstanding. QUD.27 stays open.

[Trace analysis](trace-analysis.json) is computed from the archived public
events by [analyze-traces.py](analyze-traces.py). It counts actual contact entries,
not the trailing query-work count in a motion result. Capture buffers can include
events preceding a keyboard step; per-trace frame counts are not independent
sampling trials or measurements of only the held-key interval. Recorded refresh
gaps are not correlated with held keys and are not diagnosed as the cause of
the user's pauses.

The existing client invalidates current command authorization on expiry and
clears held input during the replacement read. Five refreshes in the second
user-movement capture take 276–325 ms to receive a new projection. A future
visible test should record held input across an expiry to distinguish that
pause from collision or rendering stalls. No expiry, authorization or client
input behavior was changed based on this uncorrelated observation.

The first offline analysis failed because the preceding release's capture has
no event timestamps. Its source and nonzero exit are retained. The corrected
analysis reports unavailable timing as null and counts contacts from the actual
events; it does not invent timing or change the captured records.

This is an immutable snapshot while the browser remains open. Its active driver
log, private profile, signing keys and compiled caches are excluded.
[SNAPSHOT.json](SNAPSHOT.json) hashes the copied public artifacts. No geometry,
authorization deadline, resource budget or production implementation changed.
