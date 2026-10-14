# Linux WebXR software preflight

Scope: check the browser/runtime/GPU path before Yan assembles the original HTC
Vive. A Monado simulated HMD exercises native OpenXR and graphics; it does not
validate Vive tracking, display output, controller mappings or Quod collisions
on physical hardware. QUD.26 remains in progress.

## Host findings

- Arch Linux, NVIDIA RTX 4090, driver 615.71.09. Host Vulkan and EGL/OpenGL ES
  3.2 work. The command sandbox does not expose these devices; display/GPU
  tests ran with host access.
- Installed WebKitGTK 2.52.6 does not expose `navigator.xr`. The actual GTK
  browser harness confirmed this in `system-webkit-preflight-01.log` (expected
  test exit 1).
- Installed Monado 25.1.0 cannot load because its OpenCV 4.13 shared libraries
  are missing. `monado-simulated-01.log` records exit 127.
- Steam is installed, but its only registered library has no SteamVR install
  or Lighthouse driver. The simulated test cannot establish Vive tracking
  readiness while that dependency is absent.

## Isolated preparation

Everything is under the already ignored `client/_build/webxr-linux` directory.
No system packages, normal browser, global OpenXR selection or user settings
were changed. Tests use their own XDG runtime/configuration directories.

WebKitGTK 2.54.1 came from the [official release archive](https://webkitgtk.org/releases/webkitgtk-2.54.1.tar.xz).
GPG reported a good signature against the key published by WebKitGTK, with
fingerprint `013A0127AC9C65B34FFA62526C1009B693975393`; that published key is
expired, so this is not an unqualified current-key trust claim. Monado source
was archived from the existing local AUR checkout at
`f4dc0ec36e1109a997c8b388fb30de3cf1dc01b0`. Archive hashes are in `provenance.json`.

The installed build environment lacked Ruby, ERB, gperf and unifdef. An attempted
noninteractive package install required a password and made no changes. Private
Arch packages were downloaded and verified with the installed Arch signing
keyring before extraction. An initial verification attempt used the armored
keyring directly and failed to parse it; dearmoring it fixed the verification
input without bypassing signatures.

WebKit configuration explicitly enables WebXR, MiniBrowser and its normal
process sandbox. Documentation, introspection generation and test suites are
disabled. Optional speech synthesis and libbacktrace were disabled after the
first two configure attempts identified those missing, unrelated dependencies.
`configure-03` passed. `webkit-build-01` stopped because the separately packaged
Ruby ERB library was missing; `webkit-build-02` includes it, but stopped with
exit 127 because `gdbus-codegen` is also missing. Logs and true exits are retained
separately for every attempt. No build remains running.

Monado's private build disables the unavailable OpenCV/ONNX/SLAM camera stack
and enables its service, simulated devices, Vive and SteamVR Lighthouse support.
`monado-configure-01` and `monado-build-01` passed. Upstream production sources
were not patched.

## Executed tests

- `monado-simulated-02`: service IPC started, but compositor creation failed
  because SDL tried the desktop Wayland backend inside the isolated runtime
  directory. Service exit 0 alone was insufficient evidence of graphics success.
- `native-opengles-01`: installed `hello_xr` rejected `OpenGLES`; this executable
  lacks that backend. Exit 1; no runtime conclusion follows from this attempt.
- `native-vulkan-01`: exit 1, exposing the compositor failure above.
- `monado-simulated-03` and `native-vulkan-02`: explicitly select X11 for SDL
  and XCB for the compositor. Native Vulkan stereo session reached `FOCUSED`,
  created both eye swapchains, exposed tracked position/orientation and both
  simple controllers. The test ran for 12 seconds, received an explicit shutdown
  request on stdin and exited 0. The owned service was then stopped, exit 0.

## Browser gate

Blocked pending a usable browser path. No browser/WebXR success or hardware
acceptance is claimed. Source inspection found that this WebKit release's
`OpenXRInputMappings.h` only declares hand interaction and generic-button
controller profiles. It has no Vive profile or bound controller axes. Quod's
actual controls require grip and touchpad input, so a generic stereo session
would not establish that this browser can exercise Vive locomotion. No browser
source patches were applied. Yan interrupted the build-preparation work to
consider Steam/SteamVR; SteamVR can replace Monado as the headset runtime but
does not itself supply the browser's missing WebXR integration.

### Newer upstream route found on October 8

Live Chromium Gerrit API checks supersede the older project guides: [Linux
OpenXR activation](https://chromium-review.googlesource.com/c/chromium/src/+/8132979)
merged on September 29 at main position 1707175. It remains opt-in with
`--enable-features=OpenXR`. The Linux XR sandbox change 8441736 merged on
September 26. [Official Chrome for Testing builds](https://googlechromelabs.github.io/chrome-for-testing/)
now include Linux x64 Dev 157.0.8081.0 (1708524) and Canary 157.0.8091.0
(1713292). Reading the exact Canary tag confirms both the Linux runtime
provider and the GPU-process GBM/SCANOUT shared-image allocation path needed
by the NVIDIA implementation. The Canary binary was then downloaded and tested
as recorded below; its XR sandbox still prevents NVIDIA driver initialization.

[SteamVR integration reports](https://github.com/utzcoz/chromium-webxr-linux/issues/7)
include actual Steam Frame stereo rendering, but not original Vive validation.
The live issue-comment API includes an October 2 report by mbucchia that
SteamVR's SO_PEERCRED check was removed from the relevant path and PID
exchange adjusted for Chromium containers, expected in a subsequent Steam
Frame OS beta. Availability in desktop SteamVR has not been established.
Older instructions disabling seccomp therefore must not be treated as the
current required setup. Both community browser repositories' release APIs
returned empty lists; official Chrome for Testing is the available binary
candidate. Prefer testing it on Wayland with a fresh profile and sandbox
enabled, first against the existing simulated runtime, then SteamVR. Neither
stage substitutes for physical Vive/controller acceptance.

The repeatable test now uses the official Chrome build downloaded below:

```sh
python3 client/test/linux-webxr-run.py --evidence /tmp/quod-webxr-run-01
```

It requires the local build artifacts and access to the host display/GPU. Each
run requires a new evidence directory, owns its Monado process, listens for the
service startup notice, and shuts down only that process. The browser uses the
Chrome/ChromeDriver binaries and an isolated profile. Wayland socket access is
retained through a test-local symlink; Monado's socket and user settings remain
isolated. The test grants XR permission only to its exact localhost origin.

The original installed-WebKit baseline used GTK embedding activation. The
current Chrome harness uses real WebDriver button clicks for user activation.
No JavaScript XR emulator or fake `navigator.xr` is installed. The fixture requires
`local-floor`, stereo native frame poses, real WebGL eye rendering, changing
tracked poses, both controllers and two consecutive enter/end cycles. Its
deadline detects failure; it does not poll for readiness.

### Official Chrome test results

Downloaded official Chrome for Testing and ChromeDriver 157.0.8091.0; archive
URLs, sizes and SHA-256 hashes are in `chrome-download-01.json`. No browser
source build or patch was used. All five runs used the browser sandbox and
real Wayland/NVIDIA graphics, a fresh localhost origin/profile, the private
Monado runtime and its simulated HMD/two controllers. The production Quod
physics/authorization code was not changed by these tests.

- `chrome-preflight-01`: `navigator.xr` exists, secure context true and
  `isSessionSupported('immersive-vr')` true, but the first session failed with
  `NotSupportedError`. Browser exit 1, runtime exit 0. No rendered XR frame.
- `chrome-preflight-02`: same failure with Chrome's native logs retained.
- `chrome-preflight-03`: Monado entry-point and Vulkan loader tracing identify
  the failure in `xrCreateVulkanInstanceKHR`: `libGLX_nvidia.so.0` cannot open
  because permission is denied, then `VK_ERROR_INCOMPATIBLE_DRIVER` / no drivers.
  The exact Chromium tag's `xr_sandbox_hook_linux.cc` prewarms/allow-lists Mesa
  ICD sonames and omits NVIDIA's ICD. This explains why the native Vulkan test
  passes while sandboxed browser rendering cannot start.
- `chrome-preflight-04`: diagnostic process-local preload of NVIDIA's installed
  ICD alone caused a GPU-process abort (`vkGetInstanceProcAddr` invalid instance),
  and immersive support was false. Exit 1; not a usable remedy.
- `chrome-preflight-05`: preload the Vulkan loader before NVIDIA's ICD. Headset
  discovery returned true again, but the loader could not obtain `vkCreateInstance`
  from NVIDIA's ICD; session creation failed. Exit 1; not a usable remedy.

All Monado instances shut down with exit 0. The preload settings were passed
only to the corresponding test commands; the default repeatable runner has
neither preload nor sandbox-disabling switches. Browser console, driver/native
logs and per-run exits are retained. The required stereo/local-floor/pose/input/
two-session assertions were not weakened to manufacture a pass.

Software preflight therefore **fails on this host with this official build**.
SteamVR is absent from the registered Steam library and was not exercised.
These results establish an NVIDIA/Chromium XR initialization blocker against
Monado; they do not independently prove a SteamVR session will fail identically.
Original Vive hardware acceptance and tracker completion remain outstanding.

### NVIDIA correction candidate

The [candidate patch](chromium-nvidia-xr-01.patch) targets the exact failed
Chrome tag, `157.0.8091.0`, commit
`6532fdea9c01b64cea9c3d3d9f10c241bc3dfb42`. It adds NVIDIA's Vulkan ICD and
its lazy XCB libraries to the XR hook's existing prewarm/soname list, plus the
named NVIDIA character-device and parameter-file grants already used by
Chromium's regular GPU sandbox. This is 18 added lines in the existing XR
owner; it adds neither a second runtime nor a sandbox-disabling switch.

Patch application and the selectable-browser harness's syntax, help and
missing-artifact rejection checks passed. The native driver-order probe in
`chromium-prepare-01` also passed: prewarming with the exact hook flags and
candidate order produced `VK_SUCCESS` from `vkCreateInstance` and enumerated
the NVIDIA RTX 4090. That probe is unsandboxed and renders no XR frames; it
does not establish browser success. The candidate has not yet been compiled
or exercised by the WebXR preflight.

The official source checkout, dependencies and build tools remain isolated
under the ignored build directory. Depot_tools' initial bootstrap additionally
used its normal vpython cache; subsequent build commands select test-local
vpython, UV and CIPD caches. No normal browser profile, global OpenXR selection
or system package is changed. Preparation logs, true exits and exact source
hashes are retained in `chromium-prepare-01`; the original failed browser
campaign and its source manifest remain intact.

The runner accepts `--browser /absolute/path/to/chrome` and an optional
`--driver` override. Its default remains the original official binary; both
paths run the same native stereo/pose/controller/two-session assertions.

`chromium-prepare-01` completed the pinned source/dependency sync with exit 0.
`chromium-build-01` applied the patch, ran upstream preparation hooks and
generated the build graph successfully. Its compiler run stopped with exit 1
after 7,512 completed actions: the unchanged TypeScript dependency validator
detected undeclared `undici-types` declarations from `/home/yan/node_modules`.
That run and its full failure log remain intact; no browser was produced or
tested by it.

The resolution trace in `chromium-build-02` identifies the dependency search:
Chromium's packaged `undici-types` contains no declaration entry point, so
TypeScript continued searching ancestor package directories and selected the
unrelated home-directory version. The build-only Bubblewrap filesystem now
exposes the private checkout and host toolchain while leaving those ancestors
empty. It changes no home-directory files, source validation or browser sandbox
flags. The exact previously failing target passed under that isolation
(exit 0, one actual build action). `chromium-build-02/compile` continues with
the existing compiled objects, the unchanged NVIDIA patch and separately
retained logs. Native browser rendering remains unvalidated.
