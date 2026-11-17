# Private runtime repair and hardware boundary

The April system Monado package, monado-git25.1.0.r381.gf4dc0ec36-1, needs six
OpenCV.so.413 libraries; installed OpenCV5 supplies the incompatible.so.500 ABI.
Inventory found no selected compatible Envision/user runtime. It does not prove
every protected cache/profile was searched. Global selection/packages are unchanged.

The first private repair extracts signature-verified official Arch Archive
packages: OpenCV4.13.0-12, libjxl0.11.2-2, openexr3.4.15-2, protobuf35.1-2 and
abseil-cpp20260526.0-2. Exact URLs, archive/signature hashes and public-key
verification receipts are under inputs. No install scripts, global package
changes or ABI-spoof links were used. The initial armored-keyring failure is
retained separately from successful private dearmored-keyring verification.

Restoring that old ABI was insufficient: the old Lighthouse wrapper crashed
inside the installed Valve driver. Its restricted argument-free stack and
SIGSEGV remain failed; gdb exit0 is not an inferior-process pass. Current
official unmodified Monado supports the driver's requested IVRDriverInput_005.
Source inspection and successful current-driver discovery establish compatibility
progress, not a complete attribution of every old-driver failure.

The working private runtime uses official Monado commit
59be345db769a89c93d1bdf6ed8316fa6209d8ae, archive SHA256
55bcf466c0f08da73a7d261b9b66a02370c33f4c9168b5ec3ecdd93cbb62d3be.
Compatible02 source/build/install manifests and full configure/compiler/install
logs are retained. The first build's /tmp quota failure and partial outputs
remain intact. Compatible02 is a separate source-only build with an owned cache
TMPDIR. It links actual OpenCV.so.500; exact readelf requirements are retained
in logs/runtime-abi-final01. Vive, SteamVR Lighthouse and simulator backends are
enabled; no active runtime, systemd service or SteamVR plugin is installed.
Unused Mercury/SLAM backends are not built.

The actual Valve driver, mapped userspace code and compiler dependencies are
preserved as hash-bound bytes:2,912 paths,2,696 unique objects,1,301,479,082 unique
bytes. This is a code/dependency boundary, not an OS/kernel/display image.
Tests set XR_RUNTIME_JSON and private XDG directories per process. An owned
bwrap namespace binds only private Steam Lighthouse/chaperone copies at the
expected path; HOME is unchanged. Owned service stdin exit, process wait and
output EOF are retained. Unrelated user runtimes are never killed. Original
calibration comparisons remain true.

Native Vive display acquisition remains unavailable: NVIDIA Xlib acquisition
failed; explicit Wayland lease received no connectors. Read-only inventory sees
the Vive HDMI output connected and disabled by current compositor configuration.
No display/session configuration was changed. A separate X display query was
denied and not bypassed. A private window compositor permits actual devices,
poses, action delivery and stereo-submission observations, but proves no HMD
scanout/pixels. The startup alert remains failed evidence.

Yan kept wands on a table and retained calibration. Observation03 witnesses
trigger/pad on both hands and right squeeze, but fails its window guard before
close. Observation04 witnesses both squeezes and client/runtime0 with EOF, while
its old grip lookup cannot qualify canonical poses. Observation05 uses canonical
grip, witnesses both real aim/grip poses including high-confidence events and
both squeezes, and closes client0/runtime0 with EOF. It records87,735 valid head
frames,48,809 high-confidence head frames and38,691/38,943 valid controller frames.
These are pinned editor/source-project observations, not an automated exported
mapped-gesture or headset-pixel pass. Low-confidence final samples are retained.

Yan reported a red headset LED. The official original-Vive guide defines red as
an error indication, with cable/display issues as examples; the LED alone does
not identify the cause. Later high-confidence head tracking does not resolve the
display error. Its primary URL is retained in inputs/vive-led-documentation.json.

Physical pixels, stereo comfort, direct-display exit, complete mapped wand
gestures and physical disconnect/reentry remain open. No Quest/Android
qualification is claimed. QUO-27's pinned-engine teardown errors remain failed
independently of this now-usable private runtime.
