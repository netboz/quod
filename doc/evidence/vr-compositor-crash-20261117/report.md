# SteamVR compositor crash when Quod starts (2026-11-17)

Quod started in desktop 3D because SteamVR's compositor died 3 s after Quod
connected (13:58:44). Same crash on 2026-11-14 at 16:27 and 22:18.

- Compositor log: `Fatal : VkResult is "UNKNOWN_ERROR" in vulkanrenderer.cpp at line 3719`.
- Kernel: `RenderThread[437494]: segfault at 108 ... in libnvidia-glcore.so.615.71.09`.
- Just before: `Overlay mips (40s): 455 built` (overlay images rebuilt at the app's start).
- SteamVR: branch `beta`, build 26655409 (2.19.3), from `appmanifest_250820.acf`.
- Dumps: `dumps/` (copied from /tmp/dumps).

Known SteamVR 2.19.3 beta bug: https://github.com/ValveSoftware/SteamVR-for-Linux/issues/1067
(same build, same line, same NVIDIA fault address). Reporters trace it to the
compositor's fixed descriptor pool (maxSets 200) running out while it rebuilds
overlay images; 2.19.2 and 2.18.4 do not crash. Not a Quod fault: Quod draws
through its own swapchain, no SteamVR overlays.

Fix: leave the SteamVR beta (Steam > SteamVR > Properties > Betas > None).
