#include <dlfcn.h>
#include <stdio.h>
#include <vulkan/vulkan.h>

int main(void) {
  const char *libraries[] = {
      "libvulkan.so.1", "libvulkan_radeon.so", "libvulkan_intel.so",
      "libvulkan_freedreno.so", "libGLX_nvidia.so.0", "libxcb-dri3.so.0",
      "libxcb-glx.so.0", "libxcb-present.so.0", "libxcb-sync.so.1",
      "libvulkan_lvp.so", "libVkLayer_MESA_device_select.so",
      "libVkLayer_MESA_anti_lag.so"};
  void *loader = NULL;
  for (unsigned i = 0; i < sizeof(libraries) / sizeof(libraries[0]); ++i) {
    void *handle = dlopen(libraries[i], RTLD_NOW | RTLD_GLOBAL | RTLD_NODELETE);
    printf("prewarm %s: %s\n", libraries[i], handle ? "loaded" : dlerror());
    if (i == 0) loader = handle;
  }
  if (!loader) return 1;
  PFN_vkGetInstanceProcAddr get = dlsym(loader, "vkGetInstanceProcAddr");
  if (!get) return 1;
  PFN_vkCreateInstance create = (PFN_vkCreateInstance)get(NULL, "vkCreateInstance");
  VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
                          .pApplicationName = "quod-prewarm-check",
                          .apiVersion = VK_API_VERSION_1_0};
  VkInstanceCreateInfo info = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
                              .pApplicationInfo = &app};
  VkInstance instance;
  VkResult result = create(&info, NULL, &instance);
  printf("vkCreateInstance: %d\n", result);
  if (result != VK_SUCCESS) return 1;
  PFN_vkEnumeratePhysicalDevices enumerate =
      (PFN_vkEnumeratePhysicalDevices)get(instance, "vkEnumeratePhysicalDevices");
  PFN_vkGetPhysicalDeviceProperties properties =
      (PFN_vkGetPhysicalDeviceProperties)get(instance, "vkGetPhysicalDeviceProperties");
  PFN_vkDestroyInstance destroy = (PFN_vkDestroyInstance)get(instance, "vkDestroyInstance");
  VkPhysicalDevice devices[16];
  uint32_t count = 16;
  result = enumerate(instance, &count, devices);
  int found = 0;
  if (result == VK_SUCCESS) {
    for (uint32_t i = 0; i < count; ++i) {
      VkPhysicalDeviceProperties p;
      properties(devices[i], &p);
      printf("physical device: %s vendor=%04x\n", p.deviceName, p.vendorID);
      if (p.vendorID == 0x10de && p.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU)
        found = 1;
    }
  }
  destroy(instance, NULL);
  return found ? 0 : 1;
}
