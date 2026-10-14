# Linux WebXR NVIDIA initialization investigation

The private Chromium 157.0.8091.0 candidate now passes the existing native
Monado simulated-device preflight on this NVIDIA RTX 4090 host, with Chromium's
browser/XR sandbox enabled. Both the traced and untraced runs complete two
immersive sessions, 120 stereo frames per session, `local-floor`, changing
tracked poses and both simple simulated controllers. Browser and runtime exit
codes are zero. The fixture and its acceptance assertions were unchanged.

This is a browser/runtime/GPU software result. It does not validate the original
HTC Vive's display, tracking, controller bindings or Quod's collision behavior
on hardware. QUD.26 remains in progress. SteamVR and a physical Vive were not
exercised. No global runtime selection, ordinary browser profile, system package
or Quod production source was changed.

## Cause and correction

The October 8 build succeeded and its version check passed; the subsequent
preflight failed during `xrCreateVulkanInstanceKHR`, before an XR session or
rendered frame. `VK_ERROR_INCOMPATIBLE_DRIVER` was the downstream error after
the Vulkan loader could not obtain `vkCreateInstance` from NVIDIA's ICD.

The original correction mapped `libGLX_nvidia.so.0` and its DT_NEEDED closure,
but that does not map libraries the proprietary driver loads lazily. The
October 9 dynamic-loader and syscall traces showed the additional EGL route:

1. The confined ICD tries `libEGL.so.1`, which was not resident or allow-listed.
2. GLVND enumerates EGL vendor manifests. The exact directory must be readable
   as well as its descendants: Chromium's recursive broker permissions require
   a trailing slash and do not match the directory itself.
3. NVIDIA's EGL vendor module loads `libnvidia-eglcore` lazily. The successful
   native initialization trace also loads `libnvidia-glvkspirv`.

The [candidate patch](chromium-nvidia-xr-02.patch) extends the existing XR hook's
resident-library list and individual library grants to these four lazy
libraries. It adds read-only enumeration/manifest grants for the two EGL vendor
manifest directories. The final diff against the exact upstream tag is one
file, 28 added lines: the original 18-line NVIDIA correction plus 10 EGL lines.
No broad library-directory, X11-socket, network, or sandbox-disabling grant was
added. The successful browser runs still use Wayland; the regular GPU-process
Wayland/Vulkan warning did not prevent XR's separate Vulkan context from working.

The native Vulkan probe also passed with DISPLAY unset, confirming the driver
can initialize through its headless path. Switching the browser to X11 was not
necessary for the passing result and was not represented as tested.

## Retained attempts

- `diagnosis-01`: baseline Vulkan loader trace, exit 1.
- `diagnosis-02`: baseline syscall trace, exit 1.
- `diagnosis-03`: baseline dynamic-loader trace, exit 1.
- `chromium-egl-01`: preload EGL, incremental build exit 0 (16.204 seconds),
  preflight exit 1; `diagnosis-04` shows the GLVND discovery gap.
- `chromium-egl-02`: preload NVIDIA's EGL vendor and grant manifest descendants,
  incremental build exit 0 (6.906 seconds), preflight exit 1. `diagnosis-05`
  identifies the missing directory-enumeration grant.
- `chromium-egl-03`: grant manifest directory enumeration, incremental build
  exit 0 (7.043 seconds), preflight exit 1. `diagnosis-06` shows the lazy EGL
  core load. Driver ioctls already succeed through the existing named grants.
- `native-loader-01`: host native driver initialization, exit 0; a second
  invocation with DISPLAY unset also exits 0.
- `chromium-egl-04`: add the remaining traced library closure, incremental build
  exit 0 (6.923 seconds). `preflight` with loader tracing and `preflight-clean`
  without tracing both pass, browser exit 0 and runtime exit 0. Each contains
  two complete native immersive sessions.

Every candidate has its exact hook snapshots/patch and build command, hash,
true exit and duration. All earlier failures, including the October 8 build's
failed preflight, are retained. [The final patch manifest](chromium-nvidia-xr-02.json)
pins the source tag, commit and hashes; [binary hashes](binary.json) identify
the tested executable, changed component and build arguments. Reverse patch
validation passed in `patch-check.json`.

## Reproduction

The existing runner selects the tested private binary explicitly:

```sh
python3 client/test/linux-webxr-run.py \
  --browser /home/yan/src/quod/client/_build/webxr-linux/chromium/src/out/QuodWebXR/chrome \
  --evidence /tmp/quod-native-xr-new-run
```

It requires host GPU/display access, the private build artifacts and a new
evidence directory. It owns and stops its own simulated runtime and uses its
own XDG/profile directories. Its default browser is still the unpatched
Chrome-for-Testing baseline; selecting the private candidate is required.

The existing private build wrapper now accepts the candidate's exact patch
manifest. For the already-patched checkout, it verifies the source hash,
reuses the retained build objects and runs the same preflight:

```sh
python3 client/_build/webxr-linux/build-chromium.py --prepared \
  --patch /home/yan/src/quod/doc/evidence/player-movement/linux-webxr-20261009/chromium-nvidia-xr-02.patch \
  --campaign /tmp/quod-native-xr-new-build
```

The patch is a local upstream Chromium correction, not a released official
browser or a Quod deployment. Next acceptance work is the original Vive and
its intended locomotion/controller mappings through Quod's Prolog-owned control
path, using the existing movement hardware checklist.
