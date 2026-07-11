#include "pipewire_c.h"

#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include <pipewire/pipewire.h>
#include <pipewire/extensions/metadata.h>

struct kw_pw_metadata {
    struct kw_pw_metadata *next;
    struct kw_pw_connection *connection;
    struct pw_metadata *proxy;
    struct spa_hook listener;
    uint32_t id;
};

struct kw_pw_connection {
    struct pw_main_loop *main_loop;
    struct pw_loop *loop;
    struct pw_context *context;
    struct pw_core *core;
    struct pw_registry *registry;
    struct spa_hook registry_listener;
    struct kw_pw_events events;
    struct kw_pw_metadata *metadata;
    void *data;
    int entered;
};

_Static_assert(sizeof(struct kw_pw_property) == sizeof(struct spa_dict_item), "property size");
_Static_assert(offsetof(struct kw_pw_property, key) == offsetof(struct spa_dict_item, key), "key offset");
_Static_assert(offsetof(struct kw_pw_property, value) == offsetof(struct spa_dict_item, value), "value offset");

static int metadata_property(
    void *data,
    uint32_t subject,
    const char *key,
    const char *value_type,
    const char *value
) {
    struct kw_pw_metadata *metadata = data;
    metadata->connection->events.metadata(
        metadata->connection->data,
        metadata->id,
        subject,
        key,
        value_type,
        value
    );
    return 0;
}

static const struct pw_metadata_events metadata_events = {
    PW_VERSION_METADATA_EVENTS,
    .property = metadata_property,
};

static void bind_default_metadata(
    struct kw_pw_connection *connection,
    uint32_t id,
    uint32_t version,
    const struct spa_dict *properties
) {
    const char *name = properties == NULL
        ? NULL
        : spa_dict_lookup(properties, PW_KEY_METADATA_NAME);
    if (name == NULL || strcmp(name, "default") != 0)
        return;

    struct kw_pw_metadata *metadata = calloc(1, sizeof(*metadata));
    if (metadata == NULL)
        return;
    metadata->connection = connection;
    metadata->id = id;
    metadata->proxy = pw_registry_bind(
        connection->registry,
        id,
        PW_TYPE_INTERFACE_Metadata,
        version < PW_VERSION_METADATA ? version : PW_VERSION_METADATA,
        0
    );
    if (metadata->proxy == NULL) {
        free(metadata);
        return;
    }
    if (pw_metadata_add_listener(
            metadata->proxy,
            &metadata->listener,
            &metadata_events,
            metadata
        ) < 0) {
        pw_proxy_destroy((struct pw_proxy *)metadata->proxy);
        free(metadata);
        return;
    }
    metadata->next = connection->metadata;
    connection->metadata = metadata;
}

static void destroy_metadata(
    struct kw_pw_connection *connection,
    uint32_t id,
    int match_id
) {
    struct kw_pw_metadata **link = &connection->metadata;
    while (*link != NULL) {
        struct kw_pw_metadata *metadata = *link;
        if (match_id && metadata->id != id) {
            link = &metadata->next;
            continue;
        }
        *link = metadata->next;
        spa_hook_remove(&metadata->listener);
        pw_proxy_destroy((struct pw_proxy *)metadata->proxy);
        free(metadata);
        if (match_id)
            return;
    }
}

static void registry_global(
    void *data,
    uint32_t id,
    uint32_t permissions,
    const char *interface,
    uint32_t version,
    const struct spa_dict *properties
) {
    struct kw_pw_connection *connection = data;
    const struct kw_pw_property *items = NULL;
    uint32_t count = 0;
    if (properties != NULL) {
        items = (const struct kw_pw_property *)properties->items;
        count = properties->n_items;
    }
    connection->events.global(
        connection->data,
        id,
        permissions,
        interface,
        version,
        items,
        count
    );
    if (strcmp(interface, PW_TYPE_INTERFACE_Metadata) == 0)
        bind_default_metadata(connection, id, version, properties);
}

static void registry_global_remove(void *data, uint32_t id) {
    struct kw_pw_connection *connection = data;
    destroy_metadata(connection, id, 1);
    connection->events.global_remove(connection->data, id);
}

static const struct pw_registry_events registry_events = {
    PW_VERSION_REGISTRY_EVENTS,
    .global = registry_global,
    .global_remove = registry_global_remove,
};

struct kw_pw_connection *kw_pw_connection_create(
    const struct kw_pw_events *events,
    void *data
) {
    struct kw_pw_connection *connection = NULL;
    struct pw_properties *properties = NULL;

    if (events == NULL || events->global == NULL ||
        events->global_remove == NULL || events->metadata == NULL)
        return NULL;

    pw_init(NULL, NULL);
    connection = calloc(1, sizeof(*connection));
    if (connection == NULL)
        goto fail;
    connection->events = *events;
    connection->data = data;

    connection->main_loop = pw_main_loop_new(NULL);
    if (connection->main_loop == NULL)
        goto fail;
    connection->loop = pw_main_loop_get_loop(connection->main_loop);

    properties = pw_properties_new(
        PW_KEY_APP_NAME, "Keywork",
        PW_KEY_APP_ID, "dev.keywork.Keywork",
        NULL
    );
    if (properties == NULL)
        goto fail;
    connection->context = pw_context_new(connection->loop, properties, 0);
    properties = NULL;
    if (connection->context == NULL)
        goto fail;

    connection->core = pw_context_connect(connection->context, NULL, 0);
    if (connection->core == NULL)
        goto fail;
    connection->registry = pw_core_get_registry(
        connection->core,
        PW_VERSION_REGISTRY,
        0
    );
    if (connection->registry == NULL)
        goto fail;
    if (pw_registry_add_listener(
            connection->registry,
            &connection->registry_listener,
            &registry_events,
            connection
        ) < 0)
        goto fail;
    return connection;

fail:
    if (properties != NULL)
        pw_properties_free(properties);
    kw_pw_connection_destroy(connection);
    return NULL;
}

int kw_pw_connection_get_fd(struct kw_pw_connection *connection) {
    return pw_loop_get_fd(connection->loop);
}

int kw_pw_connection_enter(struct kw_pw_connection *connection) {
    if (connection->entered)
        return 0;
    pw_loop_enter(connection->loop);
    connection->entered = 1;
    return 0;
}

void kw_pw_connection_leave(struct kw_pw_connection *connection) {
    if (!connection->entered)
        return;
    pw_loop_leave(connection->loop);
    connection->entered = 0;
}

int kw_pw_connection_iterate(struct kw_pw_connection *connection) {
    return pw_loop_iterate(connection->loop, 0);
}

void kw_pw_connection_destroy(struct kw_pw_connection *connection) {
    if (connection == NULL) {
        pw_deinit();
        return;
    }
    kw_pw_connection_leave(connection);
    destroy_metadata(connection, 0, 0);
    if (connection->registry != NULL) {
        spa_hook_remove(&connection->registry_listener);
        pw_proxy_destroy((struct pw_proxy *)connection->registry);
    }
    if (connection->core != NULL)
        pw_core_disconnect(connection->core);
    if (connection->context != NULL)
        pw_context_destroy(connection->context);
    if (connection->main_loop != NULL)
        pw_main_loop_destroy(connection->main_loop);
    free(connection);
    pw_deinit();
}
