#ifndef KEYWORK_PIPEWIRE_C_H
#define KEYWORK_PIPEWIRE_C_H

#include <stdint.h>

struct kw_pw_connection;

struct kw_pw_property {
    const char *key;
    const char *value;
};

typedef void (*kw_pw_global_fn)(
    void *data,
    uint32_t id,
    uint32_t permissions,
    const char *interface,
    uint32_t version,
    const struct kw_pw_property *properties,
    uint32_t property_count
);

typedef void (*kw_pw_global_remove_fn)(void *data, uint32_t id);

typedef void (*kw_pw_metadata_fn)(
    void *data,
    uint32_t id,
    uint32_t subject,
    const char *key,
    const char *value_type,
    const char *value
);

typedef void (*kw_pw_node_props_fn)(
    void *data,
    uint32_t id,
    const float *volumes,
    uint32_t volume_count,
    int has_mute,
    int muted
);

typedef void (*kw_pw_node_route_fn)(
    void *data,
    uint32_t id,
    uint32_t device_id,
    uint32_t route_device,
    int route_managed
);

typedef void (*kw_pw_routes_reset_fn)(void *data, uint32_t id);

typedef void (*kw_pw_route_fn)(
    void *data,
    uint32_t id,
    uint32_t device,
    uint32_t availability,
    const float *volumes,
    uint32_t volume_count,
    int has_mute,
    int muted,
    const char *port_type,
    const char *bus
);

struct kw_pw_events {
    kw_pw_global_fn global;
    kw_pw_global_remove_fn global_remove;
    kw_pw_metadata_fn metadata;
    kw_pw_node_props_fn node_props;
    kw_pw_node_route_fn node_route;
    kw_pw_routes_reset_fn routes_reset;
    kw_pw_route_fn route;
};

struct kw_pw_connection *kw_pw_connection_create(
    const struct kw_pw_events *events,
    void *data,
    int realtime
);

int kw_pw_connection_get_fd(struct kw_pw_connection *connection);
int kw_pw_connection_enter(struct kw_pw_connection *connection);
void kw_pw_connection_leave(struct kw_pw_connection *connection);
int kw_pw_connection_iterate(struct kw_pw_connection *connection);
int kw_pw_connection_set_volume(
    struct kw_pw_connection *connection,
    uint32_t node_id,
    float volume
);
int kw_pw_connection_set_mute(
    struct kw_pw_connection *connection,
    uint32_t node_id,
    int muted
);
int kw_pw_connection_set_metadata(
    struct kw_pw_connection *connection,
    const char *key,
    const char *value_type,
    const char *value
);
const char *kw_pw_error_string(int result);
void kw_pw_connection_destroy(struct kw_pw_connection *connection);

#endif
