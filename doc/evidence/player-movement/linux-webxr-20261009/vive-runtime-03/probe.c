#include <openxr/openxr.h>
#include <stdio.h>
#include <string.h>
int main(void) {
 XrInstance instance=XR_NULL_HANDLE;
 XrInstanceCreateInfo ci={.type=XR_TYPE_INSTANCE_CREATE_INFO};
 strcpy(ci.applicationInfo.applicationName,"Quod physical Vive prerequisite");
 ci.applicationInfo.apiVersion=XR_MAKE_VERSION(1,0,0);
 XrResult r=xrCreateInstance(&ci,&instance);
 printf("xrCreateInstance=%d\n",r); fflush(stdout);
 if(XR_FAILED(r))return 1;
 XrSystemGetInfo gi={.type=XR_TYPE_SYSTEM_GET_INFO,.formFactor=XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY};
 XrSystemId system=0;
 r=xrGetSystem(instance,&gi,&system);
 printf("xrGetSystem=%d system=%llu\n",r,(unsigned long long)system); fflush(stdout);
 if(XR_SUCCEEDED(r)) {
  XrSystemProperties properties={.type=XR_TYPE_SYSTEM_PROPERTIES};
  r=xrGetSystemProperties(instance,system,&properties);
  printf("xrGetSystemProperties=%d name=%s orientation=%u position=%u\n",r,properties.systemName,properties.trackingProperties.orientationTracking,properties.trackingProperties.positionTracking);
 }
 XrResult destroyed=xrDestroyInstance(instance);
 printf("xrDestroyInstance=%d\n",destroyed);
 return XR_SUCCEEDED(r)&&XR_SUCCEEDED(destroyed)?0:1;
}
