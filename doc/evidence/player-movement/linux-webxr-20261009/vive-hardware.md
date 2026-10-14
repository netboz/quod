# Physical Vive runtime qualification

Physical WebXR output is now verified on the original HTC Vive.
`vive-webxr-02` passes two immersive sessions, 120 stereo frames each,
`local-floor`, changing head poses and both physical `htc-vive` controller
profiles. Browser and runtime exit zero, with the Chromium sandbox enabled.
Yan missed the short visual test, so it was repeated with longer sessions.

`vive-webxr-03` completes its first session with 1,800 stereo frames. Its second
session fails when the native runtime supplies no viewer pose; the browser test
exits 1 and runtime exits 0. Yan confirmed a colored image in the headset and
reported taking it off during the test. Exact removal timing was not recorded,
so this is consistent with tracking loss but does not prove its cause. The
longer run remains a failure; it is not presented as a passing two-session run.
The human observation is retained in `vive-webxr-03/human-observation.json`.

The native OpenXR prerequisite check in `vive-runtime-08` also passes with
simulation disabled. OpenXR selects the headset and both controllers; Monado
acquires HDMI-A-1 through Hyprland's Wayland display lease. Probe and runtime
exits are zero. The software/simulated regression after the upstream runtime
fixes passes in `monado-steamvr-04/simulated-regression`.

This qualifies physical browser/runtime interoperability and visible output.
It does not validate controller buttons/axes/haptics, comfort, Quod movement,
teleportation, contact masks, occupied spawns, moving doors or authority changes.
The movement hardware checklist and QUD.26 acceptance remain open.

SteamVR is installed, with its Lighthouse driver linked successfully. Linux
originally rejected the Vive USB hub with error -28 / insufficient bandwidth;
moving the PC cable to another direct USB port restored all headset and receiver
devices. The failure is retained in `vive-usb-01`.

Two exact official upstream Monado corrections were required in the private
runtime: commit 4156456d9741b0b177242d3e08cc7ac08bceb849 adds the SteamVR 2.16.1
server interface slot; commit cfa6078b8d7f368fa5296f540a436d59833e496c exposes the
SteamVR 2.18.2 input interface. Together they add four source lines. Their original
patches, hashes, source hashes, build logs and exits are retained. Chromium and
Quod production sources were not changed during this hardware check.

The installed Hyprland 0.56.2 configuration disables every monitor unmatched
by its three desktop rules. Its source processes that disable rule before
offering non-desktop outputs for VR leasing. A temporary exact Vive description
rule (`disabled=false`) followed by reconnecting the PC-side HDMI enabled the
lease. Its previous disabled state was restored with `disabled=true`; no
configuration file was edited. The first temporary override also verified that
all three desktop monitor geometries remained unchanged.

Failed physical runs `vive-runtime-01` through `vive-runtime-07` remain intact.
They include the two interface crashes, Xlib display acquisition failure, one
failed headset discovery during USB re-enumeration, and missing Wayland lease
connectors. They all failed; the eventual native success does not replace them.
`monado-steamvr-02/STOP.md` records a no-op patch attempt, detected by its unchanged
source hash; the actual rebuilds are `monado-steamvr-03` and `monado-steamvr-04`.

The reusable WebXR runner now accepts `--device vive`, disables simulation,
selects the existing Lighthouse owner and the Wayland direct backend, and records
the device mode and runtime hash. Its listener startup notice is explicitly
distinguished from headset/compositor readiness, which the WebXR assertions
verify. No assertion was weakened.

The first physical browser attempt, `vive-webxr-01`, fails before a session
because automatic SteamVR path discovery fails. The passing attempt uses
`STEAMVR_PATH=/home/yan/.local/share/Steam/steamapps/common/SteamVR`, the same
explicit runtime-owner configuration used by the native probe. Every headset
display override was restored; the physical browser runs verify unchanged
desktop monitor geometry. No user configuration file was edited.

To repeat with the Vive already offered for leasing by Hyprland:

```sh
STEAMVR_PATH=/home/yan/.local/share/Steam/steamapps/common/SteamVR \
python3 client/test/linux-webxr-run.py --device vive --frames 1800 \
  --browser /home/yan/src/quod/client/_build/webxr-linux/chromium/src/out/QuodWebXR/chrome \
  --evidence /tmp/quod-vive-new-run
```

A new evidence directory, powered tracking equipment, worn/moving headset and
both controllers are required. The existing absolute test deadlines and
acceptance assertions were retained. `--frames` defaults to the original 120.
The exact tested sources and the temporary headset-rule wrapper are retained
with each physical browser campaign. The final Monado source/runtime hashes
are in `vive-runtime-08/source.json`; Chromium's hashes remain in `binary.json`.
