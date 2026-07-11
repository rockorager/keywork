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

struct kw_pw_events {
    kw_pw_global_fn global;
    kw_pw_global_remove_fn global_remove;
    kw_pw_metadata_fn metadata;
};

struct kw_pw_connection *kw_pw_connection_create(
    const struct kw_pw_events *events,
    void *data
);

int kw_pw_connection_get_fd(struct kw_pw_connection *connection);
int kw_pw_connection_enter(struct kw_pw_connection *connection);
void kw_pw_connection_leave(struct kw_pw_connection *connection);
int kw_pw_connection_iterate(struct kw_pw_connection *connection);
void kw_pw_connection_destroy(struct kw_pw_connection *connection);

#endif
