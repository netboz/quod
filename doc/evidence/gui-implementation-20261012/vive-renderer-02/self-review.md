# XR feature registration review

The native05 attempt exposed default experience initialization stopping at
unregistered xr-controller-pointer-selection. Babylon catches and logs the
initialization error and returns a partial helper; the existing fixture mocked
the factory and missed this condition. Both04 and05 console logs contain the
error. Native05 black-screen report is retained, not a successful tracking test.

The shared XR entry now imports the existing registrations for all three enabled
default features (pointer selection, near interaction and hand tracking), plus
the existing glTF loader for device controller models. Teleportation stays
disabled under existing navigation ownership. Net4 production lines, no second
renderer or navigation path.

Client gate01:172/0 true exit0; build gate01:true exit0, hashes unchanged. Actual
MCP browser: all previous checks pass, required feature and loader registrations
present, browserErrors empty. This is registration and interaction regression
evidence, not a substitute for native initialization/hardware acceptance.
