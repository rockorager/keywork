#include <node_api.h>
#include <uv.h>

#include <dlfcn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "keywork.h"

typedef struct KeyworkApi {
    void *handle;
    uint32_t (*abi_version)(void);
    uint32_t (*widget_version)(void);
    int (*context_create)(keywork_context_t **out_context);
    void (*context_destroy)(keywork_context_t *context);
    int (*context_event_fd)(keywork_context_t *context);
    int (*context_dispatch)(keywork_context_t *context);
    int (*context_next_event)(keywork_context_t *context, struct keywork_event *out_event);
    int (*context_get_color_scheme)(const keywork_context_t *context, int *out_color_scheme);
    int (*context_get_theme_colors)(const keywork_context_t *context, struct keywork_theme_colors *out_colors);
    int (*context_set_icon_theme)(keywork_context_t *context, const char *theme_name);
    int (*context_create_image_rgba8)(keywork_context_t *context, uint32_t width, uint32_t height, size_t stride_bytes, const uint8_t *pixels, size_t pixels_len, uint64_t *out_resource_id);
    int (*context_create_alpha_mask_a8)(keywork_context_t *context, uint32_t width, uint32_t height, size_t stride_bytes, const uint8_t *pixels, size_t pixels_len, uint64_t *out_resource_id);
    void (*context_release_resource)(keywork_context_t *context, uint64_t resource_id);
    int (*surface_create)(keywork_context_t *context, const struct keywork_surface_options *options, keywork_surface_t **out_surface);
    void (*surface_destroy)(keywork_context_t *context, keywork_surface_t *surface);
    uint64_t (*surface_id)(const keywork_surface_t *surface);
    int (*surface_submit)(keywork_surface_t *surface, const uint8_t *bytes, size_t bytes_len, uint64_t *out_document_id);
    int (*surface_invalidate)(keywork_surface_t *surface);
} KeyworkApi;

typedef struct NativeContext {
    keywork_context_t *handle;
    uint32_t child_count;
} NativeContext;

typedef struct NativeSurface {
    NativeContext *context;
    keywork_surface_t *handle;
    napi_ref context_ref;
} NativeSurface;

typedef struct NativeWatch {
    napi_env env;
    NativeContext *context;
    napi_ref context_ref;
    napi_ref callback_ref;
    uv_poll_t poll;
    bool initialized;
    bool closing;
    bool closed;
    bool finalized;
} NativeWatch;

static KeyworkApi api = {0};

static napi_value throw_error(napi_env env, const char *message) {
    napi_throw_error(env, NULL, message);
    return NULL;
}

static napi_value throw_napi(napi_env env, napi_status status) {
    const napi_extended_error_info *info = NULL;
    napi_get_last_error_info(env, &info);
    (void)status;
    return throw_error(env, info != NULL && info->error_message != NULL ? info->error_message : "N-API error");
}

static const char *status_name(int status) {
    switch (status) {
        case KEYWORK_OK: return "KEYWORK_OK";
        case KEYWORK_INVALID_ARGUMENT: return "KEYWORK_INVALID_ARGUMENT";
        case KEYWORK_OUT_OF_MEMORY: return "KEYWORK_OUT_OF_MEMORY";
        case KEYWORK_UNSUPPORTED: return "KEYWORK_UNSUPPORTED";
        case KEYWORK_INVALID_DOCUMENT: return "KEYWORK_INVALID_DOCUMENT";
        case KEYWORK_SYSTEM_ERROR: return "KEYWORK_SYSTEM_ERROR";
        case KEYWORK_INTERNAL_ERROR: return "KEYWORK_INTERNAL_ERROR";
        default: return "KEYWORK_UNKNOWN_ERROR";
    }
}

static napi_value throw_keywork(napi_env env, const char *call, int status) {
    char message[160];
    snprintf(message, sizeof(message), "%s failed: %s (%d)", call, status_name(status), status);
    return throw_error(env, message);
}

static void *symbol_or_null(const char *name) {
    dlerror();
    return dlsym(api.handle, name);
}

#define LOAD_SYMBOL(field, symbol) \
    do { \
        api.field = symbol_or_null(symbol); \
        if (api.field == NULL) return false; \
    } while (0)

static bool load_api(void) {
    if (api.handle != NULL) return true;

    const char *path = getenv("KEYWORK_LIBKEYWORK");
    if (path == NULL || path[0] == '\0') path = "libkeywork.so";
    api.handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (api.handle == NULL) return false;

    LOAD_SYMBOL(abi_version, "keywork_abi_version");
    LOAD_SYMBOL(widget_version, "keywork_widget_version");
    LOAD_SYMBOL(context_create, "keywork_context_create");
    LOAD_SYMBOL(context_destroy, "keywork_context_destroy");
    LOAD_SYMBOL(context_event_fd, "keywork_context_event_fd");
    LOAD_SYMBOL(context_dispatch, "keywork_context_dispatch");
    LOAD_SYMBOL(context_next_event, "keywork_context_next_event");
    LOAD_SYMBOL(context_get_color_scheme, "keywork_context_get_color_scheme");
    LOAD_SYMBOL(context_get_theme_colors, "keywork_context_get_theme_colors");
    LOAD_SYMBOL(context_set_icon_theme, "keywork_context_set_icon_theme");
    LOAD_SYMBOL(context_create_image_rgba8, "keywork_context_create_image_rgba8");
    LOAD_SYMBOL(context_create_alpha_mask_a8, "keywork_context_create_alpha_mask_a8");
    LOAD_SYMBOL(context_release_resource, "keywork_context_release_resource");
    LOAD_SYMBOL(surface_create, "keywork_surface_create");
    LOAD_SYMBOL(surface_destroy, "keywork_surface_destroy");
    LOAD_SYMBOL(surface_id, "keywork_surface_id");
    LOAD_SYMBOL(surface_submit, "keywork_surface_submit");
    LOAD_SYMBOL(surface_invalidate, "keywork_surface_invalidate");
    return true;
}

static napi_value ensure_api(napi_env env) {
    if (load_api()) return NULL;
    const char *error = dlerror();
    return throw_error(env, error != NULL ? error : "failed to load libkeywork; set KEYWORK_LIBKEYWORK");
}

static bool value_is_object(napi_env env, napi_value value) {
    napi_valuetype type;
    if (napi_typeof(env, value, &type) != napi_ok) return false;
    return type == napi_object || type == napi_function;
}

static bool get_named(napi_env env, napi_value object, const char *camel, const char *snake, napi_value *out) {
    bool has = false;
    if (camel != NULL && napi_has_named_property(env, object, camel, &has) == napi_ok && has) {
        return napi_get_named_property(env, object, camel, out) == napi_ok;
    }
    if (snake != NULL && napi_has_named_property(env, object, snake, &has) == napi_ok && has) {
        return napi_get_named_property(env, object, snake, out) == napi_ok;
    }
    return false;
}

static uint32_t read_u32(napi_env env, napi_value object, const char *camel, const char *snake, uint32_t fallback) {
    napi_value value;
    if (!get_named(env, object, camel, snake, &value)) return fallback;
    uint32_t result = fallback;
    napi_get_value_uint32(env, value, &result);
    return result;
}

static int32_t read_i32(napi_env env, napi_value object, const char *camel, const char *snake, int32_t fallback) {
    napi_value value;
    if (!get_named(env, object, camel, snake, &value)) return fallback;
    int32_t result = fallback;
    napi_get_value_int32(env, value, &result);
    return result;
}

static char *read_string_alloc(napi_env env, napi_value object, const char *camel, const char *snake) {
    napi_value value;
    if (!get_named(env, object, camel, snake, &value)) return NULL;

    napi_valuetype type;
    if (napi_typeof(env, value, &type) != napi_ok || type != napi_string) return NULL;

    size_t len = 0;
    if (napi_get_value_string_utf8(env, value, NULL, 0, &len) != napi_ok) return NULL;
    char *buffer = malloc(len + 1);
    if (buffer == NULL) return NULL;
    if (napi_get_value_string_utf8(env, value, buffer, len + 1, &len) != napi_ok) {
        free(buffer);
        return NULL;
    }
    buffer[len] = '\0';
    return buffer;
}

static int enum_string(napi_env env, napi_value value, const char **names, const int *values, size_t count, int fallback) {
    napi_valuetype type;
    if (napi_typeof(env, value, &type) != napi_ok) return fallback;
    if (type == napi_number) {
        int32_t result = fallback;
        napi_get_value_int32(env, value, &result);
        return result;
    }
    if (type != napi_string) return fallback;

    char buffer[64];
    size_t len = 0;
    if (napi_get_value_string_utf8(env, value, buffer, sizeof(buffer), &len) != napi_ok) return fallback;
    buffer[sizeof(buffer) - 1] = '\0';
    for (size_t i = 0; i < count; i += 1) {
        if (strcmp(buffer, names[i]) == 0) return values[i];
    }
    return fallback;
}

static int read_enum(napi_env env, napi_value object, const char *camel, const char *snake, const char **names, const int *values, size_t count, int fallback) {
    napi_value value;
    if (!get_named(env, object, camel, snake, &value)) return fallback;
    return enum_string(env, value, names, values, count, fallback);
}

static void set_named_u32(napi_env env, napi_value object, const char *name, uint32_t value) {
    napi_value js_value;
    if (napi_create_uint32(env, value, &js_value) == napi_ok) napi_set_named_property(env, object, name, js_value);
}

static void set_named_i32(napi_env env, napi_value object, const char *name, int32_t value) {
    napi_value js_value;
    if (napi_create_int32(env, value, &js_value) == napi_ok) napi_set_named_property(env, object, name, js_value);
}

static void set_named_f64(napi_env env, napi_value object, const char *name, double value) {
    napi_value js_value;
    if (napi_create_double(env, value, &js_value) == napi_ok) napi_set_named_property(env, object, name, js_value);
}

static void set_named_u64(napi_env env, napi_value object, const char *name, uint64_t value) {
    napi_value js_value;
    if (napi_create_bigint_uint64(env, value, &js_value) == napi_ok) napi_set_named_property(env, object, name, js_value);
}

static napi_value unwrap_context(napi_env env, napi_value value, NativeContext **out) {
    void *data = NULL;
    napi_status status = napi_unwrap(env, value, &data);
    if (status != napi_ok || data == NULL) return throw_error(env, "expected Keywork context");
    NativeContext *context = data;
    if (context->handle == NULL) return throw_error(env, "Keywork context is destroyed");
    *out = context;
    return NULL;
}

static napi_value unwrap_surface(napi_env env, napi_value value, NativeSurface **out) {
    void *data = NULL;
    napi_status status = napi_unwrap(env, value, &data);
    if (status != napi_ok || data == NULL) return throw_error(env, "expected Keywork surface");
    NativeSurface *surface = data;
    if (surface->handle == NULL) return throw_error(env, "Keywork surface is destroyed");
    if (surface->context == NULL || surface->context->handle == NULL) return throw_error(env, "Keywork context is destroyed");
    *out = surface;
    return NULL;
}

static void context_finalize(napi_env env, void *data, void *hint) {
    (void)env;
    (void)hint;
    NativeContext *context = data;
    if (context->handle != NULL && context->child_count == 0) api.context_destroy(context->handle);
    free(context);
}

static void surface_destroy_inner(napi_env env, NativeSurface *surface) {
    if (surface->handle != NULL && surface->context != NULL && surface->context->handle != NULL) {
        api.surface_destroy(surface->context->handle, surface->handle);
        surface->handle = NULL;
    }
    if (surface->context != NULL) {
        if (surface->context->child_count > 0) surface->context->child_count -= 1;
        surface->context = NULL;
    }
    if (surface->context_ref != NULL) {
        napi_delete_reference(env, surface->context_ref);
        surface->context_ref = NULL;
    }
}

static void surface_finalize(napi_env env, void *data, void *hint) {
    (void)hint;
    NativeSurface *surface = data;
    surface_destroy_inner(env, surface);
    free(surface);
}

static void watch_release_refs(NativeWatch *watch) {
    if (watch->context != NULL) {
        if (watch->context->child_count > 0) watch->context->child_count -= 1;
        watch->context = NULL;
    }
    if (watch->callback_ref != NULL) {
        napi_delete_reference(watch->env, watch->callback_ref);
        watch->callback_ref = NULL;
    }
    if (watch->context_ref != NULL) {
        napi_delete_reference(watch->env, watch->context_ref);
        watch->context_ref = NULL;
    }
}

static void watch_close_cb(uv_handle_t *handle) {
    NativeWatch *watch = handle->data;
    watch->closed = true;
    watch_release_refs(watch);
    if (watch->finalized) free(watch);
}

static void watch_close_inner(NativeWatch *watch) {
    if (watch->closed || watch->closing) return;
    watch->closing = true;
    if (watch->initialized) {
        uv_poll_stop(&watch->poll);
        uv_close((uv_handle_t *)&watch->poll, watch_close_cb);
        watch_release_refs(watch);
    } else {
        watch->closed = true;
        watch_release_refs(watch);
    }
}

static void watch_finalize(napi_env env, void *data, void *hint) {
    (void)env;
    (void)hint;
    NativeWatch *watch = data;
    watch->finalized = true;
    if (watch->closed) {
        free(watch);
        return;
    }
    watch_close_inner(watch);
}

static void watch_poll_cb(uv_poll_t *handle, int status, int events) {
    NativeWatch *watch = handle->data;
    if (watch == NULL || watch->closing || watch->closed || watch->callback_ref == NULL) return;

    napi_handle_scope scope;
    if (napi_open_handle_scope(watch->env, &scope) != napi_ok) return;

    napi_value callback;
    napi_value global;
    napi_value argv[2];
    if (napi_get_reference_value(watch->env, watch->callback_ref, &callback) == napi_ok &&
        napi_get_global(watch->env, &global) == napi_ok &&
        napi_create_int32(watch->env, status, &argv[0]) == napi_ok &&
        napi_create_int32(watch->env, events, &argv[1]) == napi_ok) {
        napi_value result;
        napi_call_function(watch->env, global, callback, 2, argv, &result);
    }

    napi_close_handle_scope(watch->env, scope);
}

static napi_value js_abi_version(napi_env env, napi_callback_info info) {
    (void)info;
    if (ensure_api(env) != NULL) return NULL;
    napi_value result;
    napi_status status = napi_create_uint32(env, api.abi_version(), &result);
    return status == napi_ok ? result : throw_napi(env, status);
}

static napi_value js_widget_version(napi_env env, napi_callback_info info) {
    (void)info;
    if (ensure_api(env) != NULL) return NULL;
    napi_value result;
    napi_status status = napi_create_uint32(env, api.widget_version(), &result);
    return status == napi_ok ? result : throw_napi(env, status);
}

static napi_value js_create_context(napi_env env, napi_callback_info info) {
    (void)info;
    if (ensure_api(env) != NULL) return NULL;

    NativeContext *context = calloc(1, sizeof(*context));
    if (context == NULL) return throw_error(env, "out of memory");

    int rc = api.context_create(&context->handle);
    if (rc != KEYWORK_OK) {
        free(context);
        return throw_keywork(env, "keywork_context_create", rc);
    }

    napi_value object;
    napi_status status = napi_create_object(env, &object);
    if (status != napi_ok) {
        api.context_destroy(context->handle);
        free(context);
        return throw_napi(env, status);
    }
    status = napi_wrap(env, object, context, context_finalize, NULL, NULL);
    if (status != napi_ok) {
        api.context_destroy(context->handle);
        free(context);
        return throw_napi(env, status);
    }
    return object;
}

static napi_value js_context_destroy(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_status status = napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    if (status != napi_ok) return throw_napi(env, status);
    if (ensure_api(env) != NULL) return NULL;
    if (argc < 1) return throw_error(env, "contextDestroy requires a context");

    NativeContext *context = NULL;
    napi_value err = unwrap_context(env, argv[0], &context);
    if (err != NULL) return NULL;
    if (context->child_count != 0) return throw_error(env, "destroy surfaces and event watchers before destroying the context");
    api.context_destroy(context->handle);
    context->handle = NULL;
    return NULL;
}

static napi_value js_context_event_fd(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_status status = napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    if (status != napi_ok) return throw_napi(env, status);
    if (ensure_api(env) != NULL) return NULL;
    if (argc < 1) return throw_error(env, "contextEventFd requires a context");

    NativeContext *context = NULL;
    napi_value err = unwrap_context(env, argv[0], &context);
    if (err != NULL) return NULL;

    int fd = api.context_event_fd(context->handle);
    napi_value result;
    status = napi_create_int32(env, fd, &result);
    return status == napi_ok ? result : throw_napi(env, status);
}

static napi_value js_context_dispatch(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_status status = napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    if (status != napi_ok) return throw_napi(env, status);
    if (ensure_api(env) != NULL) return NULL;
    if (argc < 1) return throw_error(env, "contextDispatch requires a context");

    NativeContext *context = NULL;
    napi_value err = unwrap_context(env, argv[0], &context);
    if (err != NULL) return NULL;
    int rc = api.context_dispatch(context->handle);
    if (rc != KEYWORK_OK) return throw_keywork(env, "keywork_context_dispatch", rc);
    return NULL;
}

static napi_value js_context_next_event(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_status status = napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    if (status != napi_ok) return throw_napi(env, status);
    if (ensure_api(env) != NULL) return NULL;
    if (argc < 1) return throw_error(env, "contextNextEvent requires a context");

    NativeContext *context = NULL;
    napi_value err = unwrap_context(env, argv[0], &context);
    if (err != NULL) return NULL;

    struct keywork_event event = {0};
    event.struct_size = sizeof(event);
    int rc = api.context_next_event(context->handle, &event);
    if (rc == 0) {
        napi_value null_value;
        status = napi_get_null(env, &null_value);
        return status == napi_ok ? null_value : throw_napi(env, status);
    }
    if (rc < 0) return throw_keywork(env, "keywork_context_next_event", -rc);

    napi_value object;
    status = napi_create_object(env, &object);
    if (status != napi_ok) return throw_napi(env, status);

    set_named_i32(env, object, "kind", event.kind);
    set_named_u64(env, object, "surfaceId", event.surface_id);
    set_named_u64(env, object, "documentId", event.document_id);
    set_named_u64(env, object, "handlerId", event.handler_id);
    set_named_i32(env, object, "payloadKind", event.payload_kind);
    set_named_f64(env, object, "width", event.width);
    set_named_f64(env, object, "height", event.height);

    napi_value payload;
    if (event.payload_kind == KEYWORK_EVENT_PAYLOAD_BOOL) {
        status = napi_get_boolean(env, event.payload_bool != 0, &payload);
    } else if (event.payload_kind == KEYWORK_EVENT_PAYLOAD_TEXT && event.payload_ptr != NULL) {
        status = napi_create_string_utf8(env, (const char *)event.payload_ptr, event.payload_len, &payload);
    } else {
        status = napi_get_undefined(env, &payload);
    }
    if (status != napi_ok) return throw_napi(env, status);
    napi_set_named_property(env, object, "payload", payload);
    return object;
}

static napi_value js_context_get_color_scheme(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_status status = napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    if (status != napi_ok) return throw_napi(env, status);
    if (ensure_api(env) != NULL) return NULL;
    if (argc < 1) return throw_error(env, "contextGetColorScheme requires a context");

    NativeContext *context = NULL;
    napi_value err = unwrap_context(env, argv[0], &context);
    if (err != NULL) return NULL;
    int scheme = 0;
    int rc = api.context_get_color_scheme(context->handle, &scheme);
    if (rc != KEYWORK_OK) return throw_keywork(env, "keywork_context_get_color_scheme", rc);
    napi_value result;
    status = napi_create_int32(env, scheme, &result);
    return status == napi_ok ? result : throw_napi(env, status);
}

static napi_value js_context_get_theme_colors(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_status status = napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    if (status != napi_ok) return throw_napi(env, status);
    if (ensure_api(env) != NULL) return NULL;
    if (argc < 1) return throw_error(env, "contextGetThemeColors requires a context");

    NativeContext *context = NULL;
    napi_value err = unwrap_context(env, argv[0], &context);
    if (err != NULL) return NULL;

    struct keywork_theme_colors colors = {0};
    colors.struct_size = sizeof(colors);
    int rc = api.context_get_theme_colors(context->handle, &colors);
    if (rc != KEYWORK_OK) return throw_keywork(env, "keywork_context_get_theme_colors", rc);

    napi_value object;
    status = napi_create_object(env, &object);
    if (status != napi_ok) return throw_napi(env, status);
    set_named_i32(env, object, "colorScheme", colors.color_scheme);
    set_named_u32(env, object, "primary", colors.primary);
    set_named_u32(env, object, "onPrimary", colors.on_primary);
    set_named_u32(env, object, "primaryContainer", colors.primary_container);
    set_named_u32(env, object, "onPrimaryContainer", colors.on_primary_container);
    set_named_u32(env, object, "surface", colors.surface);
    set_named_u32(env, object, "onSurface", colors.on_surface);
    set_named_u32(env, object, "onSurfaceVariant", colors.on_surface_variant);
    set_named_u32(env, object, "surfaceContainerLow", colors.surface_container_low);
    set_named_u32(env, object, "surfaceContainer", colors.surface_container);
    set_named_u32(env, object, "surfaceContainerHigh", colors.surface_container_high);
    set_named_u32(env, object, "error", colors.error);
    set_named_u32(env, object, "onError", colors.on_error);
    set_named_u32(env, object, "errorContainer", colors.error_container);
    set_named_u32(env, object, "onErrorContainer", colors.on_error_container);
    set_named_u32(env, object, "outline", colors.outline);
    set_named_u32(env, object, "outlineVariant", colors.outline_variant);
    return object;
}

static napi_value js_context_set_icon_theme(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_status status = napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    if (status != napi_ok) return throw_napi(env, status);
    if (ensure_api(env) != NULL) return NULL;
    if (argc < 2) return throw_error(env, "contextSetIconTheme requires context and theme name");

    NativeContext *context = NULL;
    napi_value err = unwrap_context(env, argv[0], &context);
    if (err != NULL) return NULL;
    size_t len = 0;
    status = napi_get_value_string_utf8(env, argv[1], NULL, 0, &len);
    if (status != napi_ok) return throw_napi(env, status);
    char *theme_name = malloc(len + 1);
    if (theme_name == NULL) return throw_error(env, "out of memory");
    status = napi_get_value_string_utf8(env, argv[1], theme_name, len + 1, &len);
    if (status != napi_ok) {
        free(theme_name);
        return throw_napi(env, status);
    }
    int rc = api.context_set_icon_theme(context->handle, theme_name);
    free(theme_name);
    if (rc != KEYWORK_OK) return throw_keywork(env, "keywork_context_set_icon_theme", rc);
    return NULL;
}

static bool typed_array_bytes(napi_env env, napi_value value, uint8_t **out_ptr, size_t *out_len) {
    bool is_typed = false;
    if (napi_is_typedarray(env, value, &is_typed) != napi_ok || !is_typed) return false;

    napi_typedarray_type type;
    size_t length = 0;
    void *data = NULL;
    napi_value arraybuffer;
    size_t byte_offset = 0;
    if (napi_get_typedarray_info(env, value, &type, &length, &data, &arraybuffer, &byte_offset) != napi_ok) return false;
    (void)arraybuffer;
    (void)byte_offset;

    size_t element_size = 1;
    if (type == napi_uint16_array || type == napi_int16_array) element_size = 2;
    else if (type == napi_uint32_array || type == napi_int32_array || type == napi_float32_array) element_size = 4;
    else if (type == napi_float64_array || type == napi_bigint64_array || type == napi_biguint64_array) element_size = 8;
    *out_ptr = data;
    *out_len = length * element_size;
    return true;
}

static uint64_t read_u64_arg(napi_env env, napi_value value) {
    napi_valuetype type;
    if (napi_typeof(env, value, &type) != napi_ok) return 0;
    if (type == napi_bigint) {
        uint64_t result = 0;
        bool lossless = false;
        napi_get_value_bigint_uint64(env, value, &result, &lossless);
        return result;
    }
    double result = 0;
    napi_get_value_double(env, value, &result);
    return (uint64_t)result;
}

static napi_value js_context_create_image(napi_env env, napi_callback_info info, bool alpha_mask) {
    size_t argc = 5;
    napi_value argv[5];
    napi_status status = napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    if (status != napi_ok) return throw_napi(env, status);
    if (ensure_api(env) != NULL) return NULL;
    if (argc < 5) return throw_error(env, "image creation requires context, width, height, strideBytes, pixels");

    NativeContext *context = NULL;
    napi_value err = unwrap_context(env, argv[0], &context);
    if (err != NULL) return NULL;
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t stride = 0;
    napi_get_value_uint32(env, argv[1], &width);
    napi_get_value_uint32(env, argv[2], &height);
    napi_get_value_uint32(env, argv[3], &stride);
    uint8_t *pixels = NULL;
    size_t pixels_len = 0;
    if (!typed_array_bytes(env, argv[4], &pixels, &pixels_len)) return throw_error(env, "pixels must be a typed array");

    uint64_t resource_id = 0;
    int rc = alpha_mask
        ? api.context_create_alpha_mask_a8(context->handle, width, height, stride, pixels, pixels_len, &resource_id)
        : api.context_create_image_rgba8(context->handle, width, height, stride, pixels, pixels_len, &resource_id);
    if (rc != KEYWORK_OK) return throw_keywork(env, alpha_mask ? "keywork_context_create_alpha_mask_a8" : "keywork_context_create_image_rgba8", rc);

    napi_value result;
    status = napi_create_bigint_uint64(env, resource_id, &result);
    return status == napi_ok ? result : throw_napi(env, status);
}

static napi_value js_context_create_image_rgba8(napi_env env, napi_callback_info info) {
    return js_context_create_image(env, info, false);
}

static napi_value js_context_create_alpha_mask_a8(napi_env env, napi_callback_info info) {
    return js_context_create_image(env, info, true);
}

static napi_value js_context_release_resource(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_status status = napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    if (status != napi_ok) return throw_napi(env, status);
    if (ensure_api(env) != NULL) return NULL;
    if (argc < 2) return throw_error(env, "contextReleaseResource requires context and resource id");

    NativeContext *context = NULL;
    napi_value err = unwrap_context(env, argv[0], &context);
    if (err != NULL) return NULL;
    api.context_release_resource(context->handle, read_u64_arg(env, argv[1]));
    return NULL;
}

static uint32_t read_anchor_mask(napi_env env, napi_value layer) {
    napi_value value;
    if (!get_named(env, layer, "anchor", "anchor", &value)) return 0;

    bool is_array = false;
    if (napi_is_array(env, value, &is_array) != napi_ok || !is_array) return 0;
    uint32_t len = 0;
    napi_get_array_length(env, value, &len);

    uint32_t mask = 0;
    for (uint32_t i = 0; i < len; i += 1) {
        napi_value item;
        if (napi_get_element(env, value, i, &item) != napi_ok) continue;
        char anchor[16];
        size_t written = 0;
        if (napi_get_value_string_utf8(env, item, anchor, sizeof(anchor), &written) != napi_ok) continue;
        anchor[sizeof(anchor) - 1] = '\0';
        if (strcmp(anchor, "top") == 0) mask |= KEYWORK_ANCHOR_TOP;
        else if (strcmp(anchor, "bottom") == 0) mask |= KEYWORK_ANCHOR_BOTTOM;
        else if (strcmp(anchor, "left") == 0) mask |= KEYWORK_ANCHOR_LEFT;
        else if (strcmp(anchor, "right") == 0) mask |= KEYWORK_ANCHOR_RIGHT;
    }
    return mask;
}

static napi_value js_context_create_surface(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_status status = napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    if (status != napi_ok) return throw_napi(env, status);
    if (ensure_api(env) != NULL) return NULL;
    if (argc < 1) return throw_error(env, "contextCreateSurface requires a context");

    NativeContext *context = NULL;
    napi_value err = unwrap_context(env, argv[0], &context);
    if (err != NULL) return NULL;

    napi_value options = argc >= 2 ? argv[1] : NULL;
    bool has_options = options != NULL && value_is_object(env, options);

    static const char *backend_names[] = { "auto", "cpu", "shm", "wayland_shm", "vulkan", "headless" };
    static const int backend_values[] = { KEYWORK_BACKEND_AUTO, KEYWORK_BACKEND_WAYLAND_SHM, KEYWORK_BACKEND_WAYLAND_SHM, KEYWORK_BACKEND_WAYLAND_SHM, KEYWORK_BACKEND_VULKAN, KEYWORK_BACKEND_HEADLESS };
    static const char *layer_names[] = { "background", "bottom", "top", "overlay" };
    static const int layer_values[] = { KEYWORK_LAYER_BACKGROUND, KEYWORK_LAYER_BOTTOM, KEYWORK_LAYER_TOP, KEYWORK_LAYER_OVERLAY };
    static const char *keyboard_names[] = { "none", "exclusive", "on_demand", "on-demand" };
    static const int keyboard_values[] = { KEYWORK_KEYBOARD_NONE, KEYWORK_KEYBOARD_EXCLUSIVE, KEYWORK_KEYBOARD_ON_DEMAND, KEYWORK_KEYBOARD_ON_DEMAND };

    struct keywork_surface_options raw = {0};
    raw.struct_size = sizeof(raw);
    raw.backend = has_options ? read_enum(env, options, "backend", "backend", backend_names, backend_values, 6, KEYWORK_BACKEND_AUTO) : KEYWORK_BACKEND_AUTO;
    raw.width = has_options ? read_u32(env, options, "width", "width", 640) : 640;
    raw.height = has_options ? read_u32(env, options, "height", "height", 480) : 480;

    char *title = has_options ? read_string_alloc(env, options, "title", "title") : NULL;
    char *app_id = has_options ? read_string_alloc(env, options, "appId", "app_id") : NULL;
    raw.title = title;
    raw.app_id = app_id;

    char *layer_namespace = NULL;
    napi_value layer_value;
    if (has_options && get_named(env, options, "layerShell", "layer_shell", &layer_value)) {
        bool layer_enabled = false;
        napi_valuetype type;
        napi_typeof(env, layer_value, &type);
        if (type == napi_boolean) napi_get_value_bool(env, layer_value, &layer_enabled);
        else if (value_is_object(env, layer_value)) layer_enabled = true;

        if (layer_enabled) {
            raw.layer_shell = 1;
            napi_value layer = value_is_object(env, layer_value) ? layer_value : options;
            layer_namespace = read_string_alloc(env, layer, "namespace", "namespace");
            raw.layer_namespace = layer_namespace != NULL ? layer_namespace : raw.app_id;
            raw.layer = read_enum(env, layer, "layer", "layer", layer_names, layer_values, 4, KEYWORK_LAYER_TOP);
            raw.layer_anchors = read_anchor_mask(env, layer);
            raw.layer_exclusive_zone = read_i32(env, layer, "exclusiveZone", "exclusive_zone", 0);
            raw.layer_keyboard_interactivity = read_enum(env, layer, "keyboardInteractivity", "keyboard_interactivity", keyboard_names, keyboard_values, 4, KEYWORK_KEYBOARD_NONE);

            napi_value margin;
            if (get_named(env, layer, "margin", "margin", &margin) && value_is_object(env, margin)) {
                int32_t all = read_i32(env, margin, "all", "all", 0);
                int32_t x = read_i32(env, margin, "x", "x", all);
                int32_t y = read_i32(env, margin, "y", "y", all);
                raw.layer_margin_top = read_i32(env, margin, "top", "top", y);
                raw.layer_margin_right = read_i32(env, margin, "right", "right", x);
                raw.layer_margin_bottom = read_i32(env, margin, "bottom", "bottom", y);
                raw.layer_margin_left = read_i32(env, margin, "left", "left", x);
            }
        }
    }

    keywork_surface_t *surface_handle = NULL;
    int rc = api.surface_create(context->handle, &raw, &surface_handle);
    free(title);
    free(app_id);
    free(layer_namespace);
    if (rc != KEYWORK_OK) return throw_keywork(env, "keywork_surface_create", rc);

    NativeSurface *surface = calloc(1, sizeof(*surface));
    if (surface == NULL) {
        api.surface_destroy(context->handle, surface_handle);
        return throw_error(env, "out of memory");
    }
    surface->context = context;
    surface->handle = surface_handle;
    context->child_count += 1;
    status = napi_create_reference(env, argv[0], 1, &surface->context_ref);
    if (status != napi_ok) {
        context->child_count -= 1;
        api.surface_destroy(context->handle, surface_handle);
        free(surface);
        return throw_napi(env, status);
    }

    napi_value object;
    status = napi_create_object(env, &object);
    if (status != napi_ok) {
        surface_destroy_inner(env, surface);
        free(surface);
        return throw_napi(env, status);
    }
    status = napi_wrap(env, object, surface, surface_finalize, NULL, NULL);
    if (status != napi_ok) {
        surface_destroy_inner(env, surface);
        free(surface);
        return throw_napi(env, status);
    }
    set_named_u64(env, object, "id", api.surface_id(surface_handle));
    return object;
}

static napi_value js_surface_id(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_status status = napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    if (status != napi_ok) return throw_napi(env, status);
    if (ensure_api(env) != NULL) return NULL;
    if (argc < 1) return throw_error(env, "surfaceId requires a surface");

    NativeSurface *surface = NULL;
    napi_value err = unwrap_surface(env, argv[0], &surface);
    if (err != NULL) return NULL;
    napi_value result;
    status = napi_create_bigint_uint64(env, api.surface_id(surface->handle), &result);
    return status == napi_ok ? result : throw_napi(env, status);
}

static napi_value js_surface_submit(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_status status = napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    if (status != napi_ok) return throw_napi(env, status);
    if (ensure_api(env) != NULL) return NULL;
    if (argc < 2) return throw_error(env, "surfaceSubmit requires a surface and Uint8Array");

    NativeSurface *surface = NULL;
    napi_value err = unwrap_surface(env, argv[0], &surface);
    if (err != NULL) return NULL;
    uint8_t *bytes = NULL;
    size_t bytes_len = 0;
    if (!typed_array_bytes(env, argv[1], &bytes, &bytes_len)) return throw_error(env, "surfaceSubmit bytes must be a typed array");

    uint64_t document_id = 0;
    int rc = api.surface_submit(surface->handle, bytes, bytes_len, &document_id);
    if (rc != KEYWORK_OK) return throw_keywork(env, "keywork_surface_submit", rc);

    napi_value result;
    status = napi_create_bigint_uint64(env, document_id, &result);
    return status == napi_ok ? result : throw_napi(env, status);
}

static napi_value js_surface_invalidate(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_status status = napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    if (status != napi_ok) return throw_napi(env, status);
    if (ensure_api(env) != NULL) return NULL;
    if (argc < 1) return throw_error(env, "surfaceInvalidate requires a surface");

    NativeSurface *surface = NULL;
    napi_value err = unwrap_surface(env, argv[0], &surface);
    if (err != NULL) return NULL;
    int rc = api.surface_invalidate(surface->handle);
    if (rc != KEYWORK_OK) return throw_keywork(env, "keywork_surface_invalidate", rc);
    return NULL;
}

static napi_value js_surface_destroy(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_status status = napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    if (status != napi_ok) return throw_napi(env, status);
    if (ensure_api(env) != NULL) return NULL;
    if (argc < 1) return throw_error(env, "surfaceDestroy requires a surface");

    void *data = NULL;
    status = napi_unwrap(env, argv[0], &data);
    if (status != napi_ok || data == NULL) return throw_error(env, "expected Keywork surface");
    surface_destroy_inner(env, data);
    return NULL;
}

static napi_value js_watch_context(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_status status = napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    if (status != napi_ok) return throw_napi(env, status);
    if (ensure_api(env) != NULL) return NULL;
    if (argc < 2) return throw_error(env, "watchContext requires a context and callback");

    NativeContext *context = NULL;
    napi_value err = unwrap_context(env, argv[0], &context);
    if (err != NULL) return NULL;

    napi_valuetype callback_type;
    if (napi_typeof(env, argv[1], &callback_type) != napi_ok || callback_type != napi_function) return throw_error(env, "watchContext callback must be a function");

    uv_loop_t *loop = NULL;
    status = napi_get_uv_event_loop(env, &loop);
    if (status != napi_ok) return throw_napi(env, status);

    int fd = api.context_event_fd(context->handle);
    if (fd < 0) return throw_error(env, "keywork_context_event_fd returned an invalid descriptor");

    NativeWatch *watch = calloc(1, sizeof(*watch));
    if (watch == NULL) return throw_error(env, "out of memory");
    watch->env = env;
    watch->context = context;
    context->child_count += 1;

    status = napi_create_reference(env, argv[0], 1, &watch->context_ref);
    if (status != napi_ok) {
        context->child_count -= 1;
        free(watch);
        return throw_napi(env, status);
    }
    status = napi_create_reference(env, argv[1], 1, &watch->callback_ref);
    if (status != napi_ok) {
        watch_release_refs(watch);
        free(watch);
        return throw_napi(env, status);
    }

    int uv_rc = uv_poll_init(loop, &watch->poll, fd);
    if (uv_rc != 0) {
        watch_release_refs(watch);
        free(watch);
        return throw_error(env, uv_strerror(uv_rc));
    }
    watch->initialized = true;
    watch->poll.data = watch;

    uv_rc = uv_poll_start(&watch->poll, UV_READABLE | UV_DISCONNECT, watch_poll_cb);
    if (uv_rc != 0) {
        watch->finalized = true;
        watch_close_inner(watch);
        return throw_error(env, uv_strerror(uv_rc));
    }

    napi_value object;
    status = napi_create_object(env, &object);
    if (status != napi_ok) {
        watch->finalized = true;
        watch_close_inner(watch);
        return throw_napi(env, status);
    }
    status = napi_wrap(env, object, watch, watch_finalize, NULL, NULL);
    if (status != napi_ok) {
        watch->finalized = true;
        watch_close_inner(watch);
        return throw_napi(env, status);
    }
    return object;
}

static napi_value js_watch_close(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_status status = napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    if (status != napi_ok) return throw_napi(env, status);
    if (argc < 1) return throw_error(env, "watchClose requires a watch");

    void *data = NULL;
    status = napi_unwrap(env, argv[0], &data);
    if (status != napi_ok || data == NULL) return throw_error(env, "expected Keywork watch");
    watch_close_inner(data);
    return NULL;
}

static napi_status set_function(napi_env env, napi_value exports, const char *name, napi_callback callback) {
    napi_value fn;
    napi_status status = napi_create_function(env, name, NAPI_AUTO_LENGTH, callback, NULL, &fn);
    if (status != napi_ok) return status;
    return napi_set_named_property(env, exports, name, fn);
}

static napi_value init(napi_env env, napi_value exports) {
    if (set_function(env, exports, "abiVersion", js_abi_version) != napi_ok) return NULL;
    if (set_function(env, exports, "widgetVersion", js_widget_version) != napi_ok) return NULL;
    if (set_function(env, exports, "createContext", js_create_context) != napi_ok) return NULL;
    if (set_function(env, exports, "contextDestroy", js_context_destroy) != napi_ok) return NULL;
    if (set_function(env, exports, "contextEventFd", js_context_event_fd) != napi_ok) return NULL;
    if (set_function(env, exports, "contextDispatch", js_context_dispatch) != napi_ok) return NULL;
    if (set_function(env, exports, "contextNextEvent", js_context_next_event) != napi_ok) return NULL;
    if (set_function(env, exports, "contextGetColorScheme", js_context_get_color_scheme) != napi_ok) return NULL;
    if (set_function(env, exports, "contextGetThemeColors", js_context_get_theme_colors) != napi_ok) return NULL;
    if (set_function(env, exports, "contextSetIconTheme", js_context_set_icon_theme) != napi_ok) return NULL;
    if (set_function(env, exports, "contextCreateImageRgba8", js_context_create_image_rgba8) != napi_ok) return NULL;
    if (set_function(env, exports, "contextCreateAlphaMaskA8", js_context_create_alpha_mask_a8) != napi_ok) return NULL;
    if (set_function(env, exports, "contextReleaseResource", js_context_release_resource) != napi_ok) return NULL;
    if (set_function(env, exports, "contextCreateSurface", js_context_create_surface) != napi_ok) return NULL;
    if (set_function(env, exports, "surfaceId", js_surface_id) != napi_ok) return NULL;
    if (set_function(env, exports, "surfaceSubmit", js_surface_submit) != napi_ok) return NULL;
    if (set_function(env, exports, "surfaceInvalidate", js_surface_invalidate) != napi_ok) return NULL;
    if (set_function(env, exports, "surfaceDestroy", js_surface_destroy) != napi_ok) return NULL;
    if (set_function(env, exports, "watchContext", js_watch_context) != napi_ok) return NULL;
    if (set_function(env, exports, "watchClose", js_watch_close) != napi_ok) return NULL;
    return exports;
}

NAPI_MODULE(NODE_GYP_MODULE_NAME, init)
