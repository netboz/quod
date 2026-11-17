/* Read-only DRM properties and Wayland lease offers. Never requests a lease,
 * changes a property, acquires DRM master, or modesets an output. */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <wayland-client.h>
#include "drm-lease-v1-client-protocol.h"

struct device { struct wp_drm_lease_device_v1 *proxy; struct device *next; };
struct connector { struct wp_drm_lease_connector_v1 *proxy; struct connector *next; };
static struct device *devices;
static struct connector *connectors;
static unsigned device_count, connector_count, done_count;
static void conn_name(void *data, struct wp_drm_lease_connector_v1 *p, const char *name) { (void)data; printf("LEASE_NAME id=%u name=%s\n",wl_proxy_get_id((struct wl_proxy*)p),name); }
static void conn_description(void *data, struct wp_drm_lease_connector_v1 *p, const char *s) { (void)data; (void)p; (void)s; /* Description may include a monitor serial. */ }
static void conn_id(void *data, struct wp_drm_lease_connector_v1 *p, uint32_t id) { (void)data; printf("LEASE_CONNECTOR id=%u drm_connector=%u\n",wl_proxy_get_id((struct wl_proxy*)p),id); }
static void conn_done(void *data, struct wp_drm_lease_connector_v1 *p) { (void)data; printf("LEASE_CONNECTOR_DONE id=%u\n",wl_proxy_get_id((struct wl_proxy*)p)); }
static void conn_withdrawn(void *data, struct wp_drm_lease_connector_v1 *p) { (void)data; printf("LEASE_WITHDRAWN id=%u\n",wl_proxy_get_id((struct wl_proxy*)p)); }
static const struct wp_drm_lease_connector_v1_listener connector_listener={conn_name,conn_description,conn_id,conn_done,conn_withdrawn};
static void dev_fd(void *data, struct wp_drm_lease_device_v1 *p, int32_t fd) {
    (void)data; char *node=drmGetDeviceNameFromFd2(fd);
    printf("LEASE_DEVICE_FD id=%u node=%s master=%d\n",wl_proxy_get_id((struct wl_proxy*)p),node?node:"unknown",drmIsMaster(fd));
    free(node); close(fd);
}
static void dev_connector(void *data, struct wp_drm_lease_device_v1 *p, struct wp_drm_lease_connector_v1 *c) {
    (void)data; (void)p; struct connector *entry=calloc(1,sizeof(*entry)); if(!entry)exit(3);
    entry->proxy=c; entry->next=connectors; connectors=entry; connector_count++;
    wp_drm_lease_connector_v1_add_listener(c,&connector_listener,entry);
}
static void dev_done(void *data, struct wp_drm_lease_device_v1 *p) { (void)data; done_count++; printf("LEASE_DEVICE_DONE id=%u\n",wl_proxy_get_id((struct wl_proxy*)p)); }
static void dev_released(void *data, struct wp_drm_lease_device_v1 *p) { struct device *entry=data; wp_drm_lease_device_v1_destroy(p); entry->proxy=NULL; }
static const struct wp_drm_lease_device_v1_listener device_listener={dev_fd,dev_connector,dev_done,dev_released};
static void global(void *data, struct wl_registry *r, uint32_t name, const char *interface, uint32_t version) {
    (void)data; printf("GLOBAL name=%u interface=%s version=%u\n",name,interface,version);
    if(strcmp(interface,"wp_drm_lease_device_v1"))return;
    struct device *entry=calloc(1,sizeof(*entry)); if(!entry)exit(3);
    entry->proxy=wl_registry_bind(r,name,&wp_drm_lease_device_v1_interface,1);entry->next=devices;devices=entry;device_count++;
    wp_drm_lease_device_v1_add_listener(entry->proxy,&device_listener,entry);
}
static void global_remove(void *data, struct wl_registry *r, uint32_t name) { (void)data;(void)r;printf("GLOBAL_REMOVE name=%u\n",name); }
static const struct wl_registry_listener registry_listener={global,global_remove};
static int drm_inventory(const char *node) {
    int fd=open(node,O_RDONLY|O_CLOEXEC); if(fd<0){printf("DRM_OPEN_FAILED node=%s errno=%d\n",node,errno);return 1;}
    drmModeRes *resources=drmModeGetResources(fd);if(!resources){printf("DRM_RESOURCES_FAILED node=%s errno=%d\n",node,errno);close(fd);return 1;}
    printf("DRM_NODE node=%s master=%d connectors=%d\n",node,drmIsMaster(fd),resources->count_connectors);
    for(int i=0;i<resources->count_connectors;i++) {
        drmModeConnector *c=drmModeGetConnector(fd,resources->connectors[i]);if(!c)continue;
        printf("DRM_CONNECTOR id=%u type=%s-%u connection=%d encoder=%u modes=%d\n",c->connector_id,drmModeGetConnectorTypeName(c->connector_type),c->connector_type_id,c->connection,c->encoder_id,c->count_modes);
        for(int j=0;j<c->count_props;j++) {
            drmModePropertyRes *prop=drmModeGetProperty(fd,c->props[j]);if(!prop)continue;
            if(!strcmp(prop->name,"non-desktop")||!strcmp(prop->name,"CRTC_ID")||!strcmp(prop->name,"DPMS")||!strcmp(prop->name,"link-status"))
                printf("DRM_PROPERTY connector=%u name=%s value=%llu flags=%u\n",c->connector_id,prop->name,(unsigned long long)c->prop_values[j],prop->flags);
            drmModeFreeProperty(prop);
        }
        drmModeFreeConnector(c);
    }
    drmModeFreeResources(resources);close(fd);return 0;
}
int main(int argc,char **argv) {
    setvbuf(stdout,NULL,_IOLBF,0);int status=0,await_connector=0;
    for(int i=1;i<argc;i++) {
        if(!strcmp(argv[i],"--await-connector"))await_connector=1;
        else status|=drm_inventory(argv[i]);
    }
    struct wl_display *display=wl_display_connect(NULL);if(!display){perror("wl_display_connect");return 2;}
    struct wl_registry *registry=wl_display_get_registry(display);wl_registry_add_listener(registry,&registry_listener,NULL);
    /* Ordered protocol barriers: registry, device offer, connector metadata. */
    for(int i=0;i<3;i++)if(wl_display_roundtrip(display)<0){perror("wl_display_roundtrip");return 2;}
    printf("LEASE_SNAPSHOT devices=%u connectors=%u done_events=%u\n",device_count,connector_count,done_count);
    if(await_connector && !connector_count) {
        printf("WAIT_CONNECTOR\n");
        while(!connector_count)if(wl_display_dispatch(display)<0){perror("wl_display_dispatch");return 2;}
        if(wl_display_roundtrip(display)<0)return 2;
        printf("LEASE_NOTIFICATION connectors=%u\n",connector_count);
    }
    while(connectors){struct connector *e=connectors;connectors=e->next;wp_drm_lease_connector_v1_destroy(e->proxy);free(e);}
    for(struct device *e=devices;e;e=e->next)if(e->proxy)wp_drm_lease_device_v1_release(e->proxy);
    if(wl_display_roundtrip(display)<0)status=2;
    while(devices){struct device *e=devices;devices=e->next;if(e->proxy)wp_drm_lease_device_v1_destroy(e->proxy);free(e);}
    wl_registry_destroy(registry);wl_display_disconnect(display);printf("DISPLAY_INVENTORY_COMPLETE status=%d\n",status);return status;
}
