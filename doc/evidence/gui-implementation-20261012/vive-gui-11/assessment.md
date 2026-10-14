# Display failure after link-box power cycle

Yan confirmed link-box power cycle. Physical Vive was detected, same GPU and
driver as previous successful vive-gui-06. Vulkan display acquisition still
failed with VK_ERROR_INITIALIZATION_FAILED. Monado exited -11. WebXR immersive
support false, zero entries, zero fixture errors. Hyprland rolling log says
lease was granted (connector828, CRTC205, primary59); the rejection is afterward
in vkAcquireDrmDisplayEXT. Root cause remains unresolved; no reboot or desktop
restart performed. All test-owned processes stopped and display restoration
exit0 with desktop geometry preserved. Exact source manifest verified.

UI fixture loading fixes validated by successful module initialization and all
control descriptors. No renderer changes. Hardware acceptance remains blocked
by native display acquisition. Do not mark the GUI tracker done.
