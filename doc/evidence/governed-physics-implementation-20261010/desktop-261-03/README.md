# Desktop campaign 261-03: second browser hang retained

This separately labelled launch reuses the same profile and hardware rendering,
without the inherited Nimbalyst AppImage library path. Removing that variable
did not establish the cause of the preceding hang, and this X11 launch also
became unresponsive. The [stop record](STOP.json) and failed step remain.
The failure occurred before the next step sent keys. Only the verified test
browser was terminated; no profile or domain data was removed.

The inward and strafe steps produce 63 and 89 physical frames respectively,
with floor contact and no eight-contact exhaustion. Their animation counts
fall sharply. Subsequent compositor inspection found the browser window below
the physical monitor area. The DOM's focused/visible flags were insufficient
to establish actual desktop visibility, so those animation counts are not
valid measurements of visible gameplay performance.

No browser libraries, GPU settings, client code, authority, geometry or policy
were changed in this campaign. [Campaign 04](../desktop-261-04/README.md)
separately checks the native Wayland launch. [SNAPSHOT.json](SNAPSHOT.json)
hashes the public artifacts and excludes compiled caches and private profile data.
