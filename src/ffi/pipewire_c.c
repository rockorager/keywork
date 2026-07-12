#include "pipewire_c.h"

#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include <pipewire/device.h>
#include <pipewire/node.h>
#include <pipewire/pipewire.h>
#include <pipewire/extensions/metadata.h>
#include <spa/param/audio/raw.h>
#include <spa/param/props.h>
#include <spa/param/route.h>
#include <spa/pod/builder.h>
#include <spa/pod/iter.h>
#include <spa/pod/parser.h>
#include <spa/utils/result.h>

struct kw_pw_route {
    struct kw_pw_route *next;
    uint32_t index;
    uint32_t device;
    uint32_t availability;
};

struct kw_pw_device {
    struct kw_pw_device *next;
    struct kw_pw_connection *connection;
    struct pw_device *proxy;
    struct spa_hook listener;
    struct kw_pw_route *routes;
    uint32_t id;
};

struct kw_pw_node {
    struct kw_pw_node *next;
    struct kw_pw_connection *connection;
    struct pw_node *proxy;
    struct spa_hook listener;
    uint32_t id;
    uint32_t device_id;
    uint32_t profile_device;
    int route_managed;
    int route_info_sent;
    float volumes[SPA_AUDIO_MAX_CHANNELS];
    uint32_t volume_count;
    int has_mute;
    int muted;
};

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
    struct kw_pw_device *devices;
    struct kw_pw_node *nodes;
    void *data;
    int entered;
};

_Static_assert(sizeof(struct kw_pw_property) == sizeof(struct spa_dict_item), "property size");
_Static_assert(offsetof(struct kw_pw_property, key) == offsetof(struct spa_dict_item, key), "key offset");
_Static_assert(offsetof(struct kw_pw_property, value) == offsetof(struct spa_dict_item, value), "value offset");

static uint32_t property_id(const struct spa_dict *properties, const char *key) {
    const char *value = properties == NULL ? NULL : spa_dict_lookup(properties, key);
    if (value == NULL)
        return PW_ID_ANY;
    char *end = NULL;
    unsigned long result = strtoul(value, &end, 10);
    if (end == value || *end != '\0' || result > UINT32_MAX)
        return PW_ID_ANY;
    return (uint32_t)result;
}

static void node_info(void *data, const struct pw_node_info *info) {
    struct kw_pw_node *node = data;
    if (info->props != NULL) {
        uint32_t device_id = property_id(info->props, PW_KEY_DEVICE_ID);
        uint32_t profile_device = property_id(info->props, "card.profile.device");
        uint32_t route_count = property_id(info->props, "device.routes");
        int route_managed = route_count != PW_ID_ANY && route_count > 0;
        if (!node->route_info_sent ||
            node->device_id != device_id ||
            node->profile_device != profile_device ||
            node->route_managed != route_managed) {
            node->device_id = device_id;
            node->profile_device = profile_device;
            node->route_managed = route_managed;
            node->route_info_sent = 1;
            node->connection->events.node_route(
                node->connection->data,
                node->id,
                device_id,
                profile_device,
                route_managed
            );
        }
    }
    if ((info->change_mask & PW_NODE_CHANGE_MASK_PARAMS) == 0)
        return;
    for (uint32_t i = 0; i < info->n_params; i++) {
        const struct spa_param_info *param = &info->params[i];
        if (param->id == SPA_PARAM_Props && (param->flags & SPA_PARAM_INFO_READ) != 0) {
            pw_node_enum_params(node->proxy, 0, SPA_PARAM_Props, 0, UINT32_MAX, NULL);
            return;
        }
    }
}

static void node_param(
    void *data,
    int seq,
    uint32_t id,
    uint32_t index,
    uint32_t next,
    const struct spa_pod *param
) {
    (void)seq;
    (void)index;
    (void)next;
    struct kw_pw_node *node = data;
    if (id != SPA_PARAM_Props || param == NULL ||
        !spa_pod_is_object_type(param, SPA_TYPE_OBJECT_Props))
        return;

    bool changed = false;
    struct spa_pod_prop *property;
    SPA_POD_OBJECT_FOREACH((struct spa_pod_object *)param, property) {
        if (property->key == SPA_PROP_channelVolumes) {
            uint32_t count = spa_pod_copy_array(
                &property->value,
                SPA_TYPE_Float,
                node->volumes,
                SPA_AUDIO_MAX_CHANNELS
            );
            if (count > 0) {
                node->volume_count = count;
                changed = true;
            }
        } else if (property->key == SPA_PROP_mute) {
            bool muted;
            if (spa_pod_get_bool(&property->value, &muted) == 0) {
                node->has_mute = 1;
                node->muted = muted;
                changed = true;
            }
        }
    }
    if (changed) {
        node->connection->events.node_props(
            node->connection->data,
            node->id,
            node->volumes,
            node->volume_count,
            node->has_mute,
            node->muted
        );
    }
}

static const struct pw_node_events node_events = {
    PW_VERSION_NODE_EVENTS,
    .info = node_info,
    .param = node_param,
};

static void bind_audio_node(
    struct kw_pw_connection *connection,
    uint32_t id,
    uint32_t version,
    const struct spa_dict *properties
) {
    const char *media_class = properties == NULL
        ? NULL
        : spa_dict_lookup(properties, PW_KEY_MEDIA_CLASS);
    if (media_class == NULL ||
        (strcmp(media_class, "Audio/Sink") != 0 &&
         strcmp(media_class, "Audio/Source") != 0))
        return;

    struct kw_pw_node *node = calloc(1, sizeof(*node));
    if (node == NULL)
        return;
    node->connection = connection;
    node->id = id;
    node->device_id = property_id(properties, PW_KEY_DEVICE_ID);
    node->profile_device = property_id(properties, "card.profile.device");
    uint32_t route_count = property_id(properties, "device.routes");
    node->route_managed = route_count != PW_ID_ANY && route_count > 0;
    node->proxy = pw_registry_bind(
        connection->registry,
        id,
        PW_TYPE_INTERFACE_Node,
        version < PW_VERSION_NODE ? version : PW_VERSION_NODE,
        0
    );
    if (node->proxy == NULL) {
        free(node);
        return;
    }
    if (pw_node_add_listener(node->proxy, &node->listener, &node_events, node) < 0) {
        pw_proxy_destroy((struct pw_proxy *)node->proxy);
        free(node);
        return;
    }
    uint32_t params[] = { SPA_PARAM_Props };
    if (pw_node_subscribe_params(node->proxy, params, 1) < 0) {
        spa_hook_remove(&node->listener);
        pw_proxy_destroy((struct pw_proxy *)node->proxy);
        free(node);
        return;
    }
    node->next = connection->nodes;
    connection->nodes = node;
}

static void destroy_nodes(
    struct kw_pw_connection *connection,
    uint32_t id,
    int match_id
) {
    struct kw_pw_node **link = &connection->nodes;
    while (*link != NULL) {
        struct kw_pw_node *node = *link;
        if (match_id && node->id != id) {
            link = &node->next;
            continue;
        }
        *link = node->next;
        spa_hook_remove(&node->listener);
        pw_proxy_destroy((struct pw_proxy *)node->proxy);
        free(node);
        if (match_id)
            return;
    }
}

static void update_route(
    struct kw_pw_device *device,
    uint32_t route_index,
    uint32_t route_device,
    uint32_t availability
) {
    for (struct kw_pw_route *route = device->routes; route != NULL; route = route->next) {
        if (route->device == route_device) {
            route->index = route_index;
            route->availability = availability;
            return;
        }
    }
    struct kw_pw_route *route = calloc(1, sizeof(*route));
    if (route == NULL)
        return;
    route->index = route_index;
    route->device = route_device;
    route->availability = availability;
    route->next = device->routes;
    device->routes = route;
}

static void destroy_routes(struct kw_pw_device *device) {
    while (device->routes != NULL) {
        struct kw_pw_route *route = device->routes;
        device->routes = route->next;
        free(route);
    }
}

static void device_info(void *data, const struct pw_device_info *info) {
    struct kw_pw_device *device = data;
    if ((info->change_mask & PW_DEVICE_CHANGE_MASK_PARAMS) == 0)
        return;
    for (uint32_t i = 0; i < info->n_params; i++) {
        const struct spa_param_info *param = &info->params[i];
        if (param->id == SPA_PARAM_Route && (param->flags & SPA_PARAM_INFO_READ) != 0) {
            destroy_routes(device);
            device->connection->events.routes_reset(
                device->connection->data,
                device->id
            );
            pw_device_enum_params(device->proxy, 0, SPA_PARAM_Route, 0, UINT32_MAX, NULL);
            return;
        }
    }
}

static const char *route_info_value(
    const struct spa_pod *info,
    const char *wanted_key
) {
    if (info == NULL)
        return NULL;
    struct spa_pod_parser parser;
    struct spa_pod_frame frame;
    int32_t item_count;
    spa_pod_parser_pod(&parser, info);
    if (spa_pod_parser_push_struct(&parser, &frame) < 0 ||
        spa_pod_parser_get_int(&parser, &item_count) < 0 ||
        item_count < 0)
        return NULL;

    const char *result = NULL;
    for (int32_t i = 0; i < item_count; i++) {
        const char *key;
        const char *value;
        if (spa_pod_parser_get(
                &parser,
                SPA_POD_String(&key),
                SPA_POD_String(&value),
                NULL
            ) < 0)
            break;
        if (key != NULL && value != NULL && strcmp(key, wanted_key) == 0) {
            result = value;
            break;
        }
    }
    spa_pod_parser_pop(&parser, &frame);
    return result;
}

static void device_param(
    void *data,
    int seq,
    uint32_t id,
    uint32_t index,
    uint32_t next,
    const struct spa_pod *param
) {
    (void)seq;
    (void)index;
    (void)next;
    struct kw_pw_device *device = data;
    if (id != SPA_PARAM_Route || param == NULL)
        return;
    int32_t route_index = -1;
    int32_t route_device = -1;
    uint32_t availability = SPA_PARAM_AVAILABILITY_unknown;
    const struct spa_pod *route_info = NULL;
    if (spa_pod_parse_object(
            param,
            SPA_TYPE_OBJECT_ParamRoute,
            NULL,
            SPA_PARAM_ROUTE_index, SPA_POD_Int(&route_index),
            SPA_PARAM_ROUTE_device, SPA_POD_Int(&route_device),
            SPA_PARAM_ROUTE_available, SPA_POD_OPT_Id(&availability),
            SPA_PARAM_ROUTE_info, SPA_POD_OPT_PodStruct(&route_info)
        ) < 0 || route_index < 0 || route_device < 0)
        return;
    update_route(
        device,
        (uint32_t)route_index,
        (uint32_t)route_device,
        availability
    );
    device->connection->events.route(
        device->connection->data,
        device->id,
        (uint32_t)route_device,
        availability,
        route_info_value(route_info, "port.type")
    );
}

static const struct pw_device_events device_events = {
    PW_VERSION_DEVICE_EVENTS,
    .info = device_info,
    .param = device_param,
};

static void bind_audio_device(
    struct kw_pw_connection *connection,
    uint32_t id,
    uint32_t version,
    const struct spa_dict *properties
) {
    const char *media_class = properties == NULL
        ? NULL
        : spa_dict_lookup(properties, PW_KEY_MEDIA_CLASS);
    if (media_class == NULL || strcmp(media_class, "Audio/Device") != 0)
        return;

    struct kw_pw_device *device = calloc(1, sizeof(*device));
    if (device == NULL)
        return;
    device->connection = connection;
    device->id = id;
    device->proxy = pw_registry_bind(
        connection->registry,
        id,
        PW_TYPE_INTERFACE_Device,
        version < PW_VERSION_DEVICE ? version : PW_VERSION_DEVICE,
        0
    );
    if (device->proxy == NULL) {
        free(device);
        return;
    }
    if (pw_device_add_listener(device->proxy, &device->listener, &device_events, device) < 0) {
        pw_proxy_destroy((struct pw_proxy *)device->proxy);
        free(device);
        return;
    }
    uint32_t params[] = { SPA_PARAM_Route };
    if (pw_device_subscribe_params(device->proxy, params, 1) < 0) {
        spa_hook_remove(&device->listener);
        pw_proxy_destroy((struct pw_proxy *)device->proxy);
        free(device);
        return;
    }
    device->next = connection->devices;
    connection->devices = device;
}

static void destroy_devices(
    struct kw_pw_connection *connection,
    uint32_t id,
    int match_id
) {
    struct kw_pw_device **link = &connection->devices;
    while (*link != NULL) {
        struct kw_pw_device *device = *link;
        if (match_id && device->id != id) {
            link = &device->next;
            continue;
        }
        *link = device->next;
        destroy_routes(device);
        spa_hook_remove(&device->listener);
        pw_proxy_destroy((struct pw_proxy *)device->proxy);
        free(device);
        if (match_id)
            return;
    }
}

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
    if (strcmp(interface, PW_TYPE_INTERFACE_Node) == 0)
        bind_audio_node(connection, id, version, properties);
    else if (strcmp(interface, PW_TYPE_INTERFACE_Device) == 0)
        bind_audio_device(connection, id, version, properties);
    else if (strcmp(interface, PW_TYPE_INTERFACE_Metadata) == 0)
        bind_default_metadata(connection, id, version, properties);
}

static void registry_global_remove(void *data, uint32_t id) {
    struct kw_pw_connection *connection = data;
    destroy_nodes(connection, id, 1);
    destroy_devices(connection, id, 1);
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
    void *data,
    int realtime
) {
    struct kw_pw_connection *connection = NULL;
    struct pw_properties *properties = NULL;

    if (events == NULL || events->global == NULL ||
        events->global_remove == NULL || events->metadata == NULL ||
        events->node_props == NULL || events->node_route == NULL ||
        events->routes_reset == NULL || events->route == NULL)
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
        "module.rt", realtime ? "true" : "false",
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

static struct kw_pw_node *find_node(
    struct kw_pw_connection *connection,
    uint32_t id
) {
    for (struct kw_pw_node *node = connection->nodes; node != NULL; node = node->next) {
        if (node->id == id)
            return node;
    }
    return NULL;
}

static struct kw_pw_device *find_device(
    struct kw_pw_connection *connection,
    uint32_t id
) {
    for (struct kw_pw_device *device = connection->devices; device != NULL; device = device->next) {
        if (device->id == id)
            return device;
    }
    return NULL;
}

static struct kw_pw_route *find_route(
    struct kw_pw_device *device,
    uint32_t route_device
) {
    for (struct kw_pw_route *route = device->routes; route != NULL; route = route->next) {
        if (route->device == route_device)
            return route;
    }
    return NULL;
}

static int set_node_props(
    struct kw_pw_node *node,
    int set_volume,
    float volume,
    int set_mute,
    int muted
) {
    uint8_t buffer[1024];
    struct spa_pod_builder builder = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    struct spa_pod_frame frame;
    spa_pod_builder_push_object(
        &builder,
        &frame,
        SPA_TYPE_OBJECT_Props,
        SPA_PARAM_Props
    );
    if (set_volume) {
        if (node->volume_count == 0)
            return -EAGAIN;
        float volumes[SPA_AUDIO_MAX_CHANNELS];
        for (uint32_t i = 0; i < node->volume_count; i++)
            volumes[i] = volume;
        spa_pod_builder_prop(&builder, SPA_PROP_channelVolumes, 0);
        spa_pod_builder_array(
            &builder,
            sizeof(float),
            SPA_TYPE_Float,
            node->volume_count,
            volumes
        );
    }
    if (set_mute) {
        spa_pod_builder_prop(&builder, SPA_PROP_mute, 0);
        spa_pod_builder_bool(&builder, muted != 0);
    }
    const struct spa_pod *param = spa_pod_builder_pop(&builder, &frame);
    if (param == NULL || spa_pod_builder_corrupted(&builder))
        return -ENOSPC;
    return pw_node_set_param(node->proxy, SPA_PARAM_Props, 0, param);
}

static int set_route_props(
    struct kw_pw_device *device,
    struct kw_pw_route *route,
    struct kw_pw_node *node,
    int set_volume,
    float volume,
    int set_mute,
    int muted
) {
    uint8_t buffer[1024];
    struct spa_pod_builder builder = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    struct spa_pod_frame route_frame;
    struct spa_pod_frame props_frame;
    spa_pod_builder_push_object(
        &builder,
        &route_frame,
        SPA_TYPE_OBJECT_ParamRoute,
        SPA_PARAM_Route
    );
    spa_pod_builder_prop(&builder, SPA_PARAM_ROUTE_index, 0);
    spa_pod_builder_int(&builder, (int32_t)route->index);
    spa_pod_builder_prop(&builder, SPA_PARAM_ROUTE_device, 0);
    spa_pod_builder_int(&builder, (int32_t)route->device);
    spa_pod_builder_prop(&builder, SPA_PARAM_ROUTE_props, 0);
    spa_pod_builder_push_object(
        &builder,
        &props_frame,
        SPA_TYPE_OBJECT_Props,
        SPA_PARAM_Route
    );
    if (set_volume) {
        if (node->volume_count == 0)
            return -EAGAIN;
        float volumes[SPA_AUDIO_MAX_CHANNELS];
        for (uint32_t i = 0; i < node->volume_count; i++)
            volumes[i] = volume;
        spa_pod_builder_prop(&builder, SPA_PROP_channelVolumes, 0);
        spa_pod_builder_array(
            &builder,
            sizeof(float),
            SPA_TYPE_Float,
            node->volume_count,
            volumes
        );
    }
    if (set_mute) {
        spa_pod_builder_prop(&builder, SPA_PROP_mute, 0);
        spa_pod_builder_bool(&builder, muted != 0);
    }
    spa_pod_builder_pop(&builder, &props_frame);
    spa_pod_builder_prop(&builder, SPA_PARAM_ROUTE_save, 0);
    spa_pod_builder_bool(&builder, true);
    const struct spa_pod *param = spa_pod_builder_pop(&builder, &route_frame);
    if (param == NULL || spa_pod_builder_corrupted(&builder))
        return -ENOSPC;
    return pw_device_set_param(device->proxy, SPA_PARAM_Route, 0, param);
}

static int set_audio_props(
    struct kw_pw_connection *connection,
    uint32_t node_id,
    int set_volume,
    float volume,
    int set_mute,
    int muted
) {
    struct kw_pw_node *node = find_node(connection, node_id);
    if (node == NULL)
        return -ENOENT;
    if (node->route_managed) {
        struct kw_pw_device *device = find_device(connection, node->device_id);
        struct kw_pw_route *route = device == NULL
            ? NULL
            : find_route(device, node->profile_device);
        if (route == NULL)
            return -EAGAIN;
        return set_route_props(
            device,
            route,
            node,
            set_volume,
            volume,
            set_mute,
            muted
        );
    }
    return set_node_props(node, set_volume, volume, set_mute, muted);
}

int kw_pw_connection_set_volume(
    struct kw_pw_connection *connection,
    uint32_t node_id,
    float volume
) {
    return set_audio_props(connection, node_id, 1, volume, 0, 0);
}

int kw_pw_connection_set_mute(
    struct kw_pw_connection *connection,
    uint32_t node_id,
    int muted
) {
    return set_audio_props(connection, node_id, 0, 0.0f, 1, muted);
}

int kw_pw_connection_set_metadata(
    struct kw_pw_connection *connection,
    const char *key,
    const char *value_type,
    const char *value
) {
    if (connection->metadata == NULL)
        return -ENOENT;
    return pw_metadata_set_property(
        connection->metadata->proxy,
        PW_ID_CORE,
        key,
        value_type,
        value
    );
}

const char *kw_pw_error_string(int result) {
    return spa_strerror(result);
}

void kw_pw_connection_destroy(struct kw_pw_connection *connection) {
    if (connection == NULL) {
        pw_deinit();
        return;
    }
    kw_pw_connection_leave(connection);
    destroy_nodes(connection, 0, 0);
    destroy_devices(connection, 0, 0);
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
