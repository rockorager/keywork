#include <errno.h>
#include <lauxlib.h>
#include <lua.h>
#include <poll.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>

#include "ext-idle-notify-v1-client-protocol.h"
#include "ext-workspace-v1-client-protocol.h"
#include "wlr-output-power-management-unstable-v1-client-protocol.h"

#define CLIENT_MT "shell.wayland.client"
#define WORKSPACE_CLIENT_MT "shell.wayland.workspace_client"

struct client;

struct event {
    struct event *next;
    uint32_t id;
    int idled;
};

struct watch {
    struct watch *next;
    struct client *client;
    struct ext_idle_notification_v1 *notification;
    uint32_t id;
};

struct output_power {
    struct output_power *next;
    struct client *client;
    struct wl_output *output;
    struct zwlr_output_power_v1 *power;
    uint32_t global_name;
    int failed;
};

struct client {
    struct wl_display *display;
    struct wl_registry *registry;
    struct wl_seat *seat;
    struct ext_idle_notifier_v1 *notifier;
    struct zwlr_output_power_manager_v1 *power_manager;
    struct output_power *output_powers;
    struct watch *watches;
    struct event *events_head;
    struct event *events_tail;
    uint32_t next_id;
    int overflow;
};

struct workspace_client;
struct workspace_group;

struct workspace_output {
    struct workspace_output *next;
    struct workspace_client *client;
    struct wl_output *output;
    uint32_t global_name;
    char *name;
};

struct group_output {
    struct group_output *next;
    struct workspace_output *output;
};

struct workspace_group {
    struct workspace_group *next;
    struct workspace_client *client;
    struct ext_workspace_group_handle_v1 *handle;
    struct group_output *outputs;
};

struct workspace {
    struct workspace *next;
    struct workspace_client *client;
    struct workspace_group *group;
    struct ext_workspace_handle_v1 *handle;
    char *name;
    uint32_t id;
    uint32_t state;
    uint32_t capabilities;
};

struct workspace_client {
    struct wl_display *display;
    struct wl_registry *registry;
    struct ext_workspace_manager_v1 *manager;
    struct workspace_output *outputs;
    struct workspace_output *outputs_tail;
    struct workspace_group *groups;
    struct workspace_group *groups_tail;
    struct workspace *workspaces;
    struct workspace *workspaces_tail;
    uint32_t next_id;
    int dirty;
    int finished;
    int overflow;
};

static struct client *check_client(lua_State *L) {
    return luaL_checkudata(L, 1, CLIENT_MT);
}

static int push_error(lua_State *L, const char *message) {
    lua_pushnil(L);
    lua_pushstring(L, message);
    return 2;
}

static int push_errno(lua_State *L, const char *operation) {
    lua_pushnil(L);
    lua_pushfstring(L, "%s: %s", operation, strerror(errno));
    return 2;
}

/* Protocol callbacks only append to this queue; Lua is touched by dispatch(). */
static void enqueue(struct watch *watch, int idled) {
    struct event *event = malloc(sizeof(*event));
    if (event == NULL) {
        watch->client->overflow = 1;
        return;
    }
    event->next = NULL;
    event->id = watch->id;
    event->idled = idled;
    if (watch->client->events_tail != NULL)
        watch->client->events_tail->next = event;
    else
        watch->client->events_head = event;
    watch->client->events_tail = event;
}

static void notification_idled(void *data, struct ext_idle_notification_v1 *unused) {
    (void)unused;
    enqueue(data, 1);
}

static void notification_resumed(void *data, struct ext_idle_notification_v1 *unused) {
    (void)unused;
    enqueue(data, 0);
}

static const struct ext_idle_notification_v1_listener notification_listener = {
    .idled = notification_idled,
    .resumed = notification_resumed,
};

static void output_power_mode(void *data, struct zwlr_output_power_v1 *power,
                              uint32_t mode) {
    (void)data;
    (void)power;
    (void)mode;
}

static void output_power_failed(void *data, struct zwlr_output_power_v1 *power) {
    struct output_power *output_power = data;
    output_power->failed = 1;
    if (output_power->power == power) {
        zwlr_output_power_v1_destroy(power);
        output_power->power = NULL;
    }
}

static const struct zwlr_output_power_v1_listener output_power_listener = {
    .mode = output_power_mode,
    .failed = output_power_failed,
};

static void attach_output_power(struct output_power *output_power) {
    struct client *client = output_power->client;
    if (client->power_manager == NULL || output_power->power != NULL ||
        output_power->failed)
        return;
    output_power->power = zwlr_output_power_manager_v1_get_output_power(
        client->power_manager, output_power->output);
    if (output_power->power != NULL)
        zwlr_output_power_v1_add_listener(
            output_power->power, &output_power_listener, output_power);
}

static void registry_global(void *data, struct wl_registry *registry, uint32_t name,
                            const char *interface, uint32_t version) {
    struct client *client = data;
    if (client->seat == NULL && strcmp(interface, wl_seat_interface.name) == 0) {
        uint32_t supported = version < (uint32_t)wl_seat_interface.version
                                 ? version : (uint32_t)wl_seat_interface.version;
        client->seat = wl_registry_bind(registry, name, &wl_seat_interface, supported);
    } else if (client->notifier == NULL &&
               strcmp(interface, ext_idle_notifier_v1_interface.name) == 0) {
        uint32_t supported = version < (uint32_t)ext_idle_notifier_v1_interface.version
                                 ? version : (uint32_t)ext_idle_notifier_v1_interface.version;
        client->notifier = wl_registry_bind(
            registry, name, &ext_idle_notifier_v1_interface, supported);
    } else if (client->power_manager == NULL &&
               strcmp(interface, zwlr_output_power_manager_v1_interface.name) == 0) {
        struct output_power *output_power;
        uint32_t supported = version < (uint32_t)zwlr_output_power_manager_v1_interface.version
                                 ? version : (uint32_t)zwlr_output_power_manager_v1_interface.version;
        client->power_manager = wl_registry_bind(
            registry, name, &zwlr_output_power_manager_v1_interface, supported);
        for (output_power = client->output_powers; output_power != NULL;
             output_power = output_power->next)
            attach_output_power(output_power);
    } else if (strcmp(interface, wl_output_interface.name) == 0) {
        struct output_power *output_power = calloc(1, sizeof(*output_power));
        uint32_t supported = version < (uint32_t)wl_output_interface.version
                                 ? version : (uint32_t)wl_output_interface.version;
        if (output_power == NULL) {
            client->overflow = 1;
            return;
        }
        output_power->client = client;
        output_power->global_name = name;
        output_power->output = wl_registry_bind(
            registry, name, &wl_output_interface, supported);
        if (output_power->output == NULL) {
            free(output_power);
            client->overflow = 1;
            return;
        }
        output_power->next = client->output_powers;
        client->output_powers = output_power;
        attach_output_power(output_power);
    }
}

static void registry_global_remove(void *data, struct wl_registry *registry, uint32_t name) {
    struct client *client = data;
    struct output_power **cursor = &client->output_powers;
    (void)registry;
    while (*cursor != NULL) {
        struct output_power *output_power = *cursor;
        if (output_power->global_name != name) {
            cursor = &output_power->next;
            continue;
        }
        *cursor = output_power->next;
        if (output_power->power != NULL)
            zwlr_output_power_v1_destroy(output_power->power);
        if (wl_proxy_get_version((struct wl_proxy *)output_power->output) >=
            WL_OUTPUT_RELEASE_SINCE_VERSION)
            wl_output_release(output_power->output);
        else
            wl_output_destroy(output_power->output);
        free(output_power);
        return;
    }
}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_global_remove,
};

static void close_client(struct client *client) {
    struct watch *watch = client->watches;
    struct event *event = client->events_head;
    struct output_power *output_power = client->output_powers;
    while (watch != NULL) {
        struct watch *next = watch->next;
        if (watch->notification != NULL)
            ext_idle_notification_v1_destroy(watch->notification);
        free(watch);
        watch = next;
    }
    while (event != NULL) {
        struct event *next = event->next;
        free(event);
        event = next;
    }
    while (output_power != NULL) {
        struct output_power *next = output_power->next;
        if (output_power->power != NULL)
            zwlr_output_power_v1_destroy(output_power->power);
        if (output_power->output != NULL) {
            if (wl_proxy_get_version((struct wl_proxy *)output_power->output) >=
                WL_OUTPUT_RELEASE_SINCE_VERSION)
                wl_output_release(output_power->output);
            else
                wl_output_destroy(output_power->output);
        }
        free(output_power);
        output_power = next;
    }
    if (client->power_manager != NULL)
        zwlr_output_power_manager_v1_destroy(client->power_manager);
    if (client->notifier != NULL) ext_idle_notifier_v1_destroy(client->notifier);
    if (client->seat != NULL) wl_seat_destroy(client->seat);
    if (client->registry != NULL) wl_registry_destroy(client->registry);
    if (client->display != NULL) wl_display_disconnect(client->display);
    memset(client, 0, sizeof(*client));
}

static int client_fd(lua_State *L) {
    struct client *client = check_client(L);
    if (client->display == NULL) return 0;
    lua_pushinteger(L, wl_display_get_fd(client->display));
    return 1;
}

static int client_watch(lua_State *L) {
    struct client *client = check_client(L);
    lua_Number value = luaL_checknumber(L, 2);
    uint32_t timeout;
    struct watch *watch;
    if (client->display == NULL) return push_error(L, "Wayland client is closed");
    if (value != value || value < 0 || value > 4294967295.0 ||
        value != (lua_Number)(uint32_t)value)
        return luaL_argerror(L, 2, "expected a nonnegative uint32 integer");
    timeout = (uint32_t)value;
    watch = calloc(1, sizeof(*watch));
    if (watch == NULL) return push_error(L, "out of memory");
    if (client->next_id == 0) {
        free(watch);
        return push_error(L, "watch id space exhausted");
    }
    watch->client = client;
    watch->id = client->next_id++;
    watch->notification = ext_idle_notifier_v1_get_idle_notification(
        client->notifier, timeout, client->seat);
    if (watch->notification == NULL) {
        free(watch);
        return push_error(L, "failed to create idle notification");
    }
    ext_idle_notification_v1_add_listener(watch->notification, &notification_listener, watch);
    watch->next = client->watches;
    client->watches = watch;
    /* The Lua side watches readability only, so it cannot finish an EAGAIN flush. */
    if (wl_display_flush(client->display) < 0) {
        client->watches = watch->next;
        ext_idle_notification_v1_destroy(watch->notification);
        free(watch);
        return push_errno(L, "failed to flush Wayland display");
    }
    lua_pushnumber(L, watch->id);
    return 1;
}

static int client_dispatch(lua_State *L) {
    struct client *client = check_client(L);
    struct pollfd pollfd;
    int index = 1;
    if (client->display == NULL) return push_error(L, "Wayland client is closed");
    if (wl_display_dispatch_pending(client->display) < 0)
        return push_errno(L, "failed to dispatch pending Wayland events");
    /* keywork.loop deliberately gives a newly registered FD watch one
     * synthetic readable event so socket users can drain buffered data.
     * Verify the Wayland socket itself before calling the blocking dispatch
     * API, otherwise that first event could stall the whole shell. */
    pollfd.fd = wl_display_get_fd(client->display);
    pollfd.events = POLLIN;
    pollfd.revents = 0;
    if (poll(&pollfd, 1, 0) < 0) return push_errno(L, "failed to poll Wayland display");
    if (pollfd.revents != 0 && wl_display_dispatch(client->display) < 0)
        return push_errno(L, "failed to dispatch Wayland display");
    if (wl_display_flush(client->display) < 0 && errno != EAGAIN)
        return push_errno(L, "failed to flush Wayland display");
    if (client->overflow) return push_error(L, "idle event queue overflow");
    lua_newtable(L);
    while (client->events_head != NULL) {
        struct event *event = client->events_head;
        client->events_head = event->next;
        lua_createtable(L, 0, 2);
        lua_pushnumber(L, event->id);
        lua_setfield(L, -2, "id");
        lua_pushstring(L, event->idled ? "idled" : "resumed");
        lua_setfield(L, -2, "state");
        lua_rawseti(L, -2, index++);
        free(event);
    }
    client->events_tail = NULL;
    return 1;
}

static int client_set_outputs_power(lua_State *L) {
    struct client *client = check_client(L);
    struct output_power *output_power;
    uint32_t mode;
    int count = 0;
    if (client->display == NULL) return push_error(L, "Wayland client is closed");
    luaL_checktype(L, 2, LUA_TBOOLEAN);
    if (client->power_manager == NULL)
        return push_error(L, "wlr output power management is unavailable");
    for (output_power = client->output_powers; output_power != NULL;
         output_power = output_power->next) {
        if (output_power->power == NULL)
            return push_error(L, "output power control is unavailable");
        count++;
    }
    if (count == 0) return push_error(L, "no outputs are available");
    mode = lua_toboolean(L, 2)
        ? ZWLR_OUTPUT_POWER_V1_MODE_ON : ZWLR_OUTPUT_POWER_V1_MODE_OFF;
    for (output_power = client->output_powers; output_power != NULL;
         output_power = output_power->next)
        zwlr_output_power_v1_set_mode(output_power->power, mode);
    if (wl_display_flush(client->display) < 0 && errno != EAGAIN)
        return push_errno(L, "failed to flush Wayland display");
    lua_pushboolean(L, 1);
    return 1;
}

static int client_close(lua_State *L) {
    close_client(check_client(L));
    return 0;
}

static int wayland_connect(lua_State *L) {
    struct client *client = lua_newuserdata(L, sizeof(*client));
    memset(client, 0, sizeof(*client));
    client->next_id = 1;
    luaL_getmetatable(L, CLIENT_MT);
    lua_setmetatable(L, -2);
    client->display = wl_display_connect(NULL);
    if (client->display == NULL) {
        lua_pop(L, 1);
        return push_errno(L, "failed to connect to Wayland display");
    }
    client->registry = wl_display_get_registry(client->display);
    if (client->registry == NULL ||
        wl_registry_add_listener(client->registry, &registry_listener, client) < 0 ||
        wl_display_roundtrip(client->display) < 0) {
        close_client(client);
        lua_pop(L, 1);
        return push_errno(L, "failed to initialize Wayland registry");
    }
    if (client->seat == NULL || client->notifier == NULL) {
        const char *message = client->seat == NULL
            ? "Wayland compositor has no wl_seat" : "ext-idle-notify-v1 is unavailable";
        close_client(client);
        lua_pop(L, 1);
        return push_error(L, message);
    }
    return 1;
}

static struct workspace_client *check_workspace_client(lua_State *L) {
    return luaL_checkudata(L, 1, WORKSPACE_CLIENT_MT);
}

static int replace_string(char **target, const char *value) {
    size_t size = strlen(value) + 1;
    char *copy = malloc(size);
    if (copy == NULL) return 0;
    memcpy(copy, value, size);
    free(*target);
    *target = copy;
    return 1;
}

static struct workspace_output *find_workspace_output(
    struct workspace_client *client, struct wl_output *output) {
    struct workspace_output *candidate;
    for (candidate = client->outputs; candidate != NULL; candidate = candidate->next) {
        if (candidate->output == output) return candidate;
    }
    return NULL;
}

static struct workspace *find_workspace(
    struct workspace_client *client, struct ext_workspace_handle_v1 *handle) {
    struct workspace *candidate;
    for (candidate = client->workspaces; candidate != NULL; candidate = candidate->next) {
        if (candidate->handle == handle) return candidate;
    }
    return NULL;
}

static void output_geometry(void *data, struct wl_output *output, int32_t x, int32_t y,
                            int32_t physical_width, int32_t physical_height,
                            int32_t subpixel, const char *make, const char *model,
                            int32_t transform) {
    (void)data;
    (void)output;
    (void)x;
    (void)y;
    (void)physical_width;
    (void)physical_height;
    (void)subpixel;
    (void)make;
    (void)model;
    (void)transform;
}

static void output_mode(void *data, struct wl_output *output, uint32_t flags,
                        int32_t width, int32_t height, int32_t refresh) {
    (void)data;
    (void)output;
    (void)flags;
    (void)width;
    (void)height;
    (void)refresh;
}

static void output_done(void *data, struct wl_output *output) {
    (void)data;
    (void)output;
}

static void output_scale(void *data, struct wl_output *output, int32_t factor) {
    (void)data;
    (void)output;
    (void)factor;
}

static void output_name(void *data, struct wl_output *output, const char *name) {
    struct workspace_output *workspace_output = data;
    (void)output;
    if (!replace_string(&workspace_output->name, name)) {
        workspace_output->client->overflow = 1;
        return;
    }
    workspace_output->client->dirty = 1;
}

static void output_description(void *data, struct wl_output *output,
                               const char *description) {
    (void)data;
    (void)output;
    (void)description;
}

static const struct wl_output_listener output_listener = {
    .geometry = output_geometry,
    .mode = output_mode,
    .done = output_done,
    .scale = output_scale,
    .name = output_name,
    .description = output_description,
};

static void group_capabilities(void *data,
                               struct ext_workspace_group_handle_v1 *handle,
                               uint32_t capabilities) {
    (void)data;
    (void)handle;
    (void)capabilities;
}

static void group_output_enter(void *data,
                               struct ext_workspace_group_handle_v1 *handle,
                               struct wl_output *output) {
    struct workspace_group *group = data;
    struct workspace_output *workspace_output;
    struct group_output *candidate;
    (void)handle;
    workspace_output = find_workspace_output(group->client, output);
    if (workspace_output == NULL) return;
    for (candidate = group->outputs; candidate != NULL; candidate = candidate->next) {
        if (candidate->output == workspace_output) return;
    }
    candidate = malloc(sizeof(*candidate));
    if (candidate == NULL) {
        group->client->overflow = 1;
        return;
    }
    candidate->output = workspace_output;
    candidate->next = group->outputs;
    group->outputs = candidate;
}

static void group_output_leave(void *data,
                               struct ext_workspace_group_handle_v1 *handle,
                               struct wl_output *output) {
    struct workspace_group *group = data;
    struct group_output **cursor = &group->outputs;
    (void)handle;
    while (*cursor != NULL) {
        struct group_output *candidate = *cursor;
        if (candidate->output != find_workspace_output(group->client, output)) {
            cursor = &candidate->next;
            continue;
        }
        *cursor = candidate->next;
        free(candidate);
        return;
    }
}

static void group_workspace_enter(void *data,
                                  struct ext_workspace_group_handle_v1 *handle,
                                  struct ext_workspace_handle_v1 *workspace_handle) {
    struct workspace_group *group = data;
    struct workspace *workspace = find_workspace(group->client, workspace_handle);
    (void)handle;
    if (workspace != NULL) workspace->group = group;
}

static void group_workspace_leave(void *data,
                                  struct ext_workspace_group_handle_v1 *handle,
                                  struct ext_workspace_handle_v1 *workspace_handle) {
    struct workspace_group *group = data;
    struct workspace *workspace = find_workspace(group->client, workspace_handle);
    (void)handle;
    if (workspace != NULL && workspace->group == group) workspace->group = NULL;
}

static void group_removed(void *data,
                          struct ext_workspace_group_handle_v1 *handle) {
    struct workspace_group *group = data;
    struct workspace_client *client = group->client;
    struct workspace_group **cursor = &client->groups;
    struct workspace *workspace;
    struct group_output *output = group->outputs;
    while (*cursor != NULL && *cursor != group) cursor = &(*cursor)->next;
    if (*cursor == group) *cursor = group->next;
    if (client->groups_tail == group) {
        client->groups_tail = client->groups;
        while (client->groups_tail != NULL && client->groups_tail->next != NULL)
            client->groups_tail = client->groups_tail->next;
    }
    for (workspace = client->workspaces; workspace != NULL; workspace = workspace->next) {
        if (workspace->group == group) workspace->group = NULL;
    }
    while (output != NULL) {
        struct group_output *next = output->next;
        free(output);
        output = next;
    }
    ext_workspace_group_handle_v1_destroy(handle);
    free(group);
}

static const struct ext_workspace_group_handle_v1_listener workspace_group_listener = {
    .capabilities = group_capabilities,
    .output_enter = group_output_enter,
    .output_leave = group_output_leave,
    .workspace_enter = group_workspace_enter,
    .workspace_leave = group_workspace_leave,
    .removed = group_removed,
};

static void workspace_protocol_id(void *data,
                                  struct ext_workspace_handle_v1 *handle,
                                  const char *id) {
    (void)data;
    (void)handle;
    (void)id;
}

static void workspace_name(void *data,
                           struct ext_workspace_handle_v1 *handle,
                           const char *name) {
    struct workspace *workspace = data;
    (void)handle;
    if (!replace_string(&workspace->name, name)) workspace->client->overflow = 1;
}

static void workspace_coordinates(void *data,
                                  struct ext_workspace_handle_v1 *handle,
                                  struct wl_array *coordinates) {
    (void)data;
    (void)handle;
    (void)coordinates;
}

static void workspace_state(void *data,
                            struct ext_workspace_handle_v1 *handle,
                            uint32_t state) {
    struct workspace *workspace = data;
    (void)handle;
    workspace->state = state;
}

static void workspace_capabilities(void *data,
                                   struct ext_workspace_handle_v1 *handle,
                                   uint32_t capabilities) {
    struct workspace *workspace = data;
    (void)handle;
    workspace->capabilities = capabilities;
}

static void workspace_removed(void *data,
                              struct ext_workspace_handle_v1 *handle) {
    struct workspace *workspace = data;
    struct workspace_client *client = workspace->client;
    struct workspace **cursor = &client->workspaces;
    while (*cursor != NULL && *cursor != workspace) cursor = &(*cursor)->next;
    if (*cursor == workspace) *cursor = workspace->next;
    if (client->workspaces_tail == workspace) {
        client->workspaces_tail = client->workspaces;
        while (client->workspaces_tail != NULL && client->workspaces_tail->next != NULL)
            client->workspaces_tail = client->workspaces_tail->next;
    }
    ext_workspace_handle_v1_destroy(handle);
    free(workspace->name);
    free(workspace);
}

static const struct ext_workspace_handle_v1_listener workspace_listener = {
    .id = workspace_protocol_id,
    .name = workspace_name,
    .coordinates = workspace_coordinates,
    .state = workspace_state,
    .capabilities = workspace_capabilities,
    .removed = workspace_removed,
};

static void manager_workspace_group(
    void *data, struct ext_workspace_manager_v1 *manager,
    struct ext_workspace_group_handle_v1 *handle) {
    struct workspace_client *client = data;
    struct workspace_group *group = calloc(1, sizeof(*group));
    (void)manager;
    if (group == NULL) {
        client->overflow = 1;
        ext_workspace_group_handle_v1_destroy(handle);
        return;
    }
    group->client = client;
    group->handle = handle;
    ext_workspace_group_handle_v1_add_listener(handle, &workspace_group_listener, group);
    if (client->groups_tail != NULL)
        client->groups_tail->next = group;
    else
        client->groups = group;
    client->groups_tail = group;
}

static void manager_workspace(void *data,
                              struct ext_workspace_manager_v1 *manager,
                              struct ext_workspace_handle_v1 *handle) {
    struct workspace_client *client = data;
    struct workspace *workspace = calloc(1, sizeof(*workspace));
    (void)manager;
    if (workspace == NULL || client->next_id == 0) {
        client->overflow = 1;
        free(workspace);
        ext_workspace_handle_v1_destroy(handle);
        return;
    }
    workspace->client = client;
    workspace->handle = handle;
    workspace->id = client->next_id++;
    ext_workspace_handle_v1_add_listener(handle, &workspace_listener, workspace);
    if (client->workspaces_tail != NULL)
        client->workspaces_tail->next = workspace;
    else
        client->workspaces = workspace;
    client->workspaces_tail = workspace;
}

static void manager_done(void *data,
                         struct ext_workspace_manager_v1 *manager) {
    struct workspace_client *client = data;
    (void)manager;
    client->dirty = 1;
}

static void manager_finished(void *data,
                             struct ext_workspace_manager_v1 *manager) {
    struct workspace_client *client = data;
    ext_workspace_manager_v1_destroy(manager);
    client->manager = NULL;
    client->finished = 1;
}

static const struct ext_workspace_manager_v1_listener workspace_manager_listener = {
    .workspace_group = manager_workspace_group,
    .workspace = manager_workspace,
    .done = manager_done,
    .finished = manager_finished,
};

static void workspace_registry_global(void *data, struct wl_registry *registry,
                                      uint32_t name, const char *interface,
                                      uint32_t version) {
    struct workspace_client *client = data;
    if (strcmp(interface, wl_output_interface.name) == 0) {
        struct workspace_output *output = calloc(1, sizeof(*output));
        uint32_t supported = version < (uint32_t)wl_output_interface.version
                                 ? version : (uint32_t)wl_output_interface.version;
        if (output == NULL) {
            client->overflow = 1;
            return;
        }
        output->client = client;
        output->global_name = name;
        output->output = wl_registry_bind(registry, name, &wl_output_interface, supported);
        if (output->output == NULL) {
            free(output);
            client->overflow = 1;
            return;
        }
        wl_output_add_listener(output->output, &output_listener, output);
        if (client->outputs_tail != NULL)
            client->outputs_tail->next = output;
        else
            client->outputs = output;
        client->outputs_tail = output;
    } else if (client->manager == NULL &&
               strcmp(interface, ext_workspace_manager_v1_interface.name) == 0) {
        uint32_t supported = version < (uint32_t)ext_workspace_manager_v1_interface.version
                                 ? version : (uint32_t)ext_workspace_manager_v1_interface.version;
        client->manager = wl_registry_bind(
            registry, name, &ext_workspace_manager_v1_interface, supported);
        if (client->manager != NULL)
            ext_workspace_manager_v1_add_listener(
                client->manager, &workspace_manager_listener, client);
    }
}

static void workspace_registry_global_remove(void *data, struct wl_registry *registry,
                                             uint32_t name) {
    struct workspace_client *client = data;
    struct workspace_output **cursor = &client->outputs;
    (void)registry;
    while (*cursor != NULL) {
        struct workspace_output *output = *cursor;
        struct workspace_group *group;
        if (output->global_name != name) {
            cursor = &output->next;
            continue;
        }
        for (group = client->groups; group != NULL; group = group->next) {
            struct group_output **group_cursor = &group->outputs;
            while (*group_cursor != NULL) {
                struct group_output *group_output = *group_cursor;
                if (group_output->output != output) {
                    group_cursor = &group_output->next;
                    continue;
                }
                *group_cursor = group_output->next;
                free(group_output);
            }
        }
        *cursor = output->next;
        if (client->outputs_tail == output) {
            client->outputs_tail = client->outputs;
            while (client->outputs_tail != NULL && client->outputs_tail->next != NULL)
                client->outputs_tail = client->outputs_tail->next;
        }
        if (wl_proxy_get_version((struct wl_proxy *)output->output) >=
            WL_OUTPUT_RELEASE_SINCE_VERSION)
            wl_output_release(output->output);
        else
            wl_output_destroy(output->output);
        free(output->name);
        free(output);
        client->dirty = 1;
        return;
    }
}

static const struct wl_registry_listener workspace_registry_listener = {
    .global = workspace_registry_global,
    .global_remove = workspace_registry_global_remove,
};

static void close_workspace_client(struct workspace_client *client) {
    struct workspace *workspace = client->workspaces;
    struct workspace_group *group = client->groups;
    struct workspace_output *output = client->outputs;
    while (workspace != NULL) {
        struct workspace *next = workspace->next;
        if (workspace->handle != NULL) ext_workspace_handle_v1_destroy(workspace->handle);
        free(workspace->name);
        free(workspace);
        workspace = next;
    }
    while (group != NULL) {
        struct workspace_group *next = group->next;
        struct group_output *group_output = group->outputs;
        while (group_output != NULL) {
            struct group_output *output_next = group_output->next;
            free(group_output);
            group_output = output_next;
        }
        if (group->handle != NULL) ext_workspace_group_handle_v1_destroy(group->handle);
        free(group);
        group = next;
    }
    if (client->manager != NULL) ext_workspace_manager_v1_destroy(client->manager);
    while (output != NULL) {
        struct workspace_output *next = output->next;
        if (output->output != NULL) {
            if (wl_proxy_get_version((struct wl_proxy *)output->output) >=
                WL_OUTPUT_RELEASE_SINCE_VERSION)
                wl_output_release(output->output);
            else
                wl_output_destroy(output->output);
        }
        free(output->name);
        free(output);
        output = next;
    }
    if (client->registry != NULL) wl_registry_destroy(client->registry);
    if (client->display != NULL) wl_display_disconnect(client->display);
    memset(client, 0, sizeof(*client));
}

static int push_workspace_snapshot(lua_State *L, struct workspace_client *client) {
    struct workspace *workspace;
    int index = 1;
    lua_newtable(L);
    for (workspace = client->workspaces; workspace != NULL; workspace = workspace->next) {
        struct group_output *output;
        int output_index = 1;
        lua_createtable(L, 0, 7);
        lua_pushnumber(L, workspace->id);
        lua_setfield(L, -2, "id");
        lua_pushstring(L, workspace->name != NULL ? workspace->name : "");
        lua_setfield(L, -2, "name");
        lua_pushboolean(L, workspace->state & EXT_WORKSPACE_HANDLE_V1_STATE_ACTIVE);
        lua_setfield(L, -2, "active");
        lua_pushboolean(L, workspace->state & EXT_WORKSPACE_HANDLE_V1_STATE_URGENT);
        lua_setfield(L, -2, "urgent");
        lua_pushboolean(L, workspace->state & EXT_WORKSPACE_HANDLE_V1_STATE_HIDDEN);
        lua_setfield(L, -2, "hidden");
        lua_pushboolean(
            L, workspace->capabilities & EXT_WORKSPACE_HANDLE_V1_WORKSPACE_CAPABILITIES_ACTIVATE);
        lua_setfield(L, -2, "can_activate");
        lua_newtable(L);
        for (output = workspace->group != NULL ? workspace->group->outputs : NULL;
             output != NULL; output = output->next) {
            if (output->output->name == NULL) continue;
            lua_pushstring(L, output->output->name);
            lua_rawseti(L, -2, output_index++);
        }
        lua_setfield(L, -2, "outputs");
        lua_rawseti(L, -2, index++);
    }
    client->dirty = 0;
    return 1;
}

static int workspace_client_fd(lua_State *L) {
    struct workspace_client *client = check_workspace_client(L);
    if (client->display == NULL) return 0;
    lua_pushinteger(L, wl_display_get_fd(client->display));
    return 1;
}

static int workspace_client_snapshot(lua_State *L) {
    struct workspace_client *client = check_workspace_client(L);
    if (client->display == NULL) return push_error(L, "Wayland client is closed");
    return push_workspace_snapshot(L, client);
}

static int workspace_client_dispatch(lua_State *L) {
    struct workspace_client *client = check_workspace_client(L);
    struct pollfd pollfd;
    if (client->display == NULL) return push_error(L, "Wayland client is closed");
    if (wl_display_dispatch_pending(client->display) < 0)
        return push_errno(L, "failed to dispatch pending Wayland events");
    pollfd.fd = wl_display_get_fd(client->display);
    pollfd.events = POLLIN;
    pollfd.revents = 0;
    if (poll(&pollfd, 1, 0) < 0) return push_errno(L, "failed to poll Wayland display");
    if (pollfd.revents != 0 && wl_display_dispatch(client->display) < 0)
        return push_errno(L, "failed to dispatch Wayland display");
    if (wl_display_flush(client->display) < 0 && errno != EAGAIN)
        return push_errno(L, "failed to flush Wayland display");
    if (client->overflow) return push_error(L, "workspace state allocation failed");
    if (client->finished) return push_error(L, "workspace manager finished");
    if (client->dirty) return push_workspace_snapshot(L, client);
    return 0;
}

static int workspace_client_activate(lua_State *L) {
    struct workspace_client *client = check_workspace_client(L);
    lua_Number value = luaL_checknumber(L, 2);
    struct workspace *workspace;
    uint32_t id;
    if (client->display == NULL) return push_error(L, "Wayland client is closed");
    if (client->manager == NULL) return push_error(L, "workspace manager is unavailable");
    if (value != value || value < 1 || value > 4294967295.0 ||
        value != (lua_Number)(uint32_t)value)
        return luaL_argerror(L, 2, "expected a positive uint32 integer");
    id = (uint32_t)value;
    for (workspace = client->workspaces; workspace != NULL; workspace = workspace->next) {
        if (workspace->id == id) break;
    }
    if (workspace == NULL) return push_error(L, "workspace is unavailable");
    if (!(workspace->capabilities & EXT_WORKSPACE_HANDLE_V1_WORKSPACE_CAPABILITIES_ACTIVATE))
        return push_error(L, "workspace cannot be activated");
    ext_workspace_handle_v1_activate(workspace->handle);
    ext_workspace_manager_v1_commit(client->manager);
    if (wl_display_flush(client->display) < 0 && errno != EAGAIN)
        return push_errno(L, "failed to flush Wayland display");
    lua_pushboolean(L, 1);
    return 1;
}

static int workspace_client_close(lua_State *L) {
    close_workspace_client(check_workspace_client(L));
    return 0;
}

static int wayland_connect_workspaces(lua_State *L) {
    struct workspace_client *client = lua_newuserdata(L, sizeof(*client));
    memset(client, 0, sizeof(*client));
    client->next_id = 1;
    luaL_getmetatable(L, WORKSPACE_CLIENT_MT);
    lua_setmetatable(L, -2);
    client->display = wl_display_connect(NULL);
    if (client->display == NULL) {
        lua_pop(L, 1);
        return push_errno(L, "failed to connect to Wayland display");
    }
    client->registry = wl_display_get_registry(client->display);
    if (client->registry == NULL ||
        wl_registry_add_listener(client->registry, &workspace_registry_listener, client) < 0 ||
        wl_display_roundtrip(client->display) < 0) {
        close_workspace_client(client);
        lua_pop(L, 1);
        return push_error(L, "failed to initialize Wayland registry");
    }
    if (client->manager == NULL) {
        close_workspace_client(client);
        lua_pop(L, 1);
        return push_error(L, "ext-workspace-v1 is unavailable");
    }
    if (wl_display_roundtrip(client->display) < 0 || client->overflow || client->finished) {
        const char *message = client->overflow
            ? "workspace state allocation failed" : "failed to initialize ext-workspace-v1";
        close_workspace_client(client);
        lua_pop(L, 1);
        return push_error(L, message);
    }
    return 1;
}

int luaopen_shell_wayland(lua_State *L) {
    static const luaL_Reg methods[] = {
        {"fd", client_fd}, {"watch", client_watch},
        {"set_outputs_power", client_set_outputs_power}, {"dispatch", client_dispatch},
        {"close", client_close}, {"__gc", client_close}, {NULL, NULL},
    };
    static const luaL_Reg workspace_methods[] = {
        {"fd", workspace_client_fd},
        {"snapshot", workspace_client_snapshot},
        {"dispatch", workspace_client_dispatch},
        {"activate", workspace_client_activate},
        {"close", workspace_client_close},
        {"__gc", workspace_client_close},
        {NULL, NULL},
    };
    luaL_newmetatable(L, CLIENT_MT);
    luaL_register(L, NULL, methods);
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");
    lua_pop(L, 1);
    luaL_newmetatable(L, WORKSPACE_CLIENT_MT);
    luaL_register(L, NULL, workspace_methods);
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");
    lua_pop(L, 1);
    lua_newtable(L);
    lua_pushcfunction(L, wayland_connect);
    lua_setfield(L, -2, "connect");
    lua_pushcfunction(L, wayland_connect_workspaces);
    lua_setfield(L, -2, "connect_workspaces");
    return 1;
}
