# Real WebSocket GUI call regression

Seven tests ran; one failed. The new real-Cowboy test expected `{ok,expired}`
for an unknown presentation receipt, but received `{error,not_found}`.
Cowboy intercepts `$gen_call` in its supervisor interface before forwarding
application messages to `websocket_info`. Existing direct-handler GUI fixtures
did not exercise that dispatch boundary.

The existing GUI call now uses an OTP labelled call (`quod_gui_request`) and
the same owner handlers. OTP retains monitors, reply aliases and timeout cleanup;
the absolute presentation deadline is unchanged. The obsolete `$gen_call`
handler shapes are removed, with no fallback, additional owner or retry.

The same failure occurred while opening the real world form in browser fixture
02. Its process exited cleanly on requested teardown; that exit is not browser
acceptance. The original response is retained in that fixture's evidence folder.
