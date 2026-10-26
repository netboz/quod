# Babylon XR lifecycle

The 9.18.1 patch retains and removes the disposal observers owned by the XR
helper, session manager and managed output canvas. The manager installs its
native end handler before notifying fallible session-init observers.

`npm ci` applies the patch using pinned patch-package. Client tests and the Vite
configuration verify the installed module digests; they never modify dependencies.
Include this directory and the lockfile in build inputs and dependency cache keys.
The runtime image consumes the resulting bundle and needs no patching tool.

The three modified generated JavaScript modules omit their original source-map
links because those maps describe the unpatched sources. Private declarations
match the patch; the public API is unchanged. Remove this patch only after a
qualified upstream version supplies the fixes and passes the owner regressions.
