# Black-screen diagnosis

Run07 readiness was invalid: the WebXR query succeeded against a simulated HMD.
Its shell session/runtime later disappeared without a final result. Physical
USB enumeration initially contained only the link box/hub. After Yan reseated
the connection and reported a green LED, USB enumerated the actual Vive and
Lighthouse FPGA receiver; run09 and run10 detected HTC Vive LHR-D006848D.

Run08 and run09 retained page-loading failures. The old test module imported
Babylon from UI, which does not declare that package; cached Vite optimization
had masked this. Moved the fixture to client/test, which owns Babylon, imported
it from HTML like the existing spatial fixture, and explicitly allowed client
source in the UI development server. Run10 loaded every control with zero
fixture errors. No production renderer/lifecycle changes.

All physical runs08–10 failed Vulkan display acquisition (vkAcquireDrmDisplayEXT,
VK_ERROR_INITIALIZATION_FAILED). Run10 additionally exited runtime -11; kernel
confirmed a Monado segfault. Desktop-session scope did not fix it, so no claim
that user-service environment was its cause. All runs restored the headset
display and preserved desktop geometry. No hardware acceptance or XR entry.

Yan is asked to power-cycle the link box while all test processes are stopped.
A fresh run must verify actual physical device and successful WebXR support.
The persistent scope owns a control FIFO; stop through it for normal cleanup.
