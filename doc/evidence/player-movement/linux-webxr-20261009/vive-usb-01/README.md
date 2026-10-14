# Vive USB prerequisite check

SteamVR installation completed; its Lighthouse driver has no unresolved
DT_NEEDED dependencies. No physical runtime or browser session was started.

The kernel rejected HTC hub 0bb4:2210 at USB path 1-3 with error -28:
“Not enough bandwidth for new device state” and “can’t set config #1”.
The hub is unconfigured and no Vive tracking or Valve receiver devices appear.
This blocks hardware acceptance before the XR runtime is involved. A different
direct PC USB port is the next connection check; no kernel, USB or Steam settings
were changed. The underlying USB enumeration failure dates to October 8.

The logs, commands, actual exits and installed driver hash are in result.json.
