# Explicit persistent mouse capture

A scene click now captures the pointer until the user releases it with Esc/Tab
or opens the menu. Releasing the mouse button does not end mouse look. The first
click only captures; subsequent clicks select along the centre crosshair.
Keyboard/wheel navigation requires capture. Focus loss, menu opening and
disconnection release the pointer and clear held input; refocus/menu closing
never recaptures automatically. The previous right-button hold path is removed.

[Desktop input checks](navigation-desktop/output.log) verify the actual window
system reports captured mode, persistent look after button release, no selection
on the capture click, centre-ray selection, movement, pitch limits, Escape,
focus and disconnect cleanup. [Headless checks](navigation-headless/output.log)
cover the same application transitions. Both pass with clean engine diagnostics.

The [complete sequential gates](final-client/) also pass, including identity,
TLS/onboarding, resources, navigation, Linux export and exported startup. No
server or rendering changes are included. Conceptual-thinking MCP checked the
capture lifecycle; knowledge-graph memory records the corrected interaction.
[Source/export hashes](source-manifest.json) identify the verified tree.

Production source delta: **+31 / −12 lines, net +19**, excluding tests/docs.
The additional lines provide persistent capture, centre picking and crosshair
visibility through the existing camera owner; the hold-to-look path is replaced.
