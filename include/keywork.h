#ifndef KEYWORK_H
#define KEYWORK_H

#include <stddef.h>
#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

#define KEYWORK_ABI_VERSION 3u
#define KEYWORK_WIDGET_VERSION 0u

typedef struct keywork_context keywork_context_t;
typedef struct keywork_surface keywork_surface_t;

enum keywork_status {
    KEYWORK_OK = 0,
    KEYWORK_INVALID_ARGUMENT = 1,
    KEYWORK_OUT_OF_MEMORY = 2,
    KEYWORK_UNSUPPORTED = 3,
    KEYWORK_INVALID_DOCUMENT = 4,
    KEYWORK_SYSTEM_ERROR = 5,
    KEYWORK_INTERNAL_ERROR = 6,
};

enum keywork_backend {
    KEYWORK_BACKEND_AUTO = 0,
    KEYWORK_BACKEND_WAYLAND_SHM = 1,
    KEYWORK_BACKEND_VULKAN = 2,
    KEYWORK_BACKEND_HEADLESS = 3,
};

enum keywork_layer {
    KEYWORK_LAYER_BACKGROUND = 0,
    KEYWORK_LAYER_BOTTOM = 1,
    KEYWORK_LAYER_TOP = 2,
    KEYWORK_LAYER_OVERLAY = 3,
};

enum keywork_anchor {
    KEYWORK_ANCHOR_TOP = 1u << 0,
    KEYWORK_ANCHOR_BOTTOM = 1u << 1,
    KEYWORK_ANCHOR_LEFT = 1u << 2,
    KEYWORK_ANCHOR_RIGHT = 1u << 3,
};

enum keywork_keyboard_interactivity {
    KEYWORK_KEYBOARD_NONE = 0,
    KEYWORK_KEYBOARD_EXCLUSIVE = 1,
    KEYWORK_KEYBOARD_ON_DEMAND = 2,
};

enum keywork_event_kind {
    KEYWORK_EVENT_HANDLER = 1,
    KEYWORK_EVENT_CONFIGURED = 2,
    KEYWORK_EVENT_CLOSED = 3,
    KEYWORK_EVENT_APPEARANCE_CHANGED = 4,
    KEYWORK_EVENT_DOCUMENT_RETIRED = 5,
};

enum keywork_event_payload_kind {
    KEYWORK_EVENT_PAYLOAD_NONE = 0,
    KEYWORK_EVENT_PAYLOAD_BOOL = 1,
    KEYWORK_EVENT_PAYLOAD_TEXT = 2,
};

enum keywork_color_scheme {
    KEYWORK_COLOR_SCHEME_NO_PREFERENCE = 0,
    KEYWORK_COLOR_SCHEME_DARK = 1,
    KEYWORK_COLOR_SCHEME_LIGHT = 2,
};

struct keywork_surface_options {
    /*
     * Set to sizeof(struct keywork_surface_options). ABI v2 and later accept
     * larger values and ignore trailing caller storage.
     */
    size_t struct_size;
    /*
     * Selects rendering backend. AUTO tries Vulkan first and falls back to
     * Wayland SHM only if Vulkan initialization/capability setup fails.
     * Explicit VULKAN returns its error. Zero-initialized C storage selects
     * AUTO, matching the default behavior of the Zig API.
     */
    int backend;
    const char *title;
    const char *app_id;
    uint32_t width;
    uint32_t height;

    /*
     * Width may be zero only for a Wayland layer surface with both LEFT and
     * RIGHT anchors. Height must be nonzero.
     */
    int layer_shell;
    const char *layer_namespace;
    int layer;
    uint32_t layer_anchors;
    int32_t layer_exclusive_zone;
    int32_t layer_margin_top;
    int32_t layer_margin_right;
    int32_t layer_margin_bottom;
    int32_t layer_margin_left;
    int layer_keyboard_interactivity;
};

struct keywork_event {
    size_t struct_size;
    int kind;
    uint64_t surface_id;
    uint64_t document_id;
    uint64_t handler_id;
    int payload_kind;
    const uint8_t *payload_ptr;
    size_t payload_len;
    int payload_bool;
    float width;
    float height;
};

struct keywork_theme_colors {
    /*
     * Set to sizeof(struct keywork_theme_colors). ABI v3 accepts larger
     * values and ignores trailing caller storage.
     */
    size_t struct_size;
    int color_scheme;
    uint32_t primary;
    uint32_t on_primary;
    uint32_t primary_container;
    uint32_t on_primary_container;
    uint32_t surface;
    uint32_t on_surface;
    uint32_t on_surface_variant;
    uint32_t surface_container_low;
    uint32_t surface_container;
    uint32_t surface_container_high;
    uint32_t error;
    uint32_t on_error;
    uint32_t error_container;
    uint32_t on_error_container;
    uint32_t outline;
    uint32_t outline_variant;
};

uint32_t keywork_abi_version(void);
uint32_t keywork_widget_version(void);

int keywork_context_create(keywork_context_t **out_context);
void keywork_context_destroy(keywork_context_t *context);

/*
 * Returns one stable epoll descriptor owned by the context. Watch it for
 * readability. The host must not read from or close it.
 */
int keywork_context_event_fd(keywork_context_t *context);

/* Non-blocking. Never invokes host callbacks. */
int keywork_context_dispatch(keywork_context_t *context);

/*
 * Returns 1 for an event, 0 for an empty queue, or -keywork_status.
 * The caller must set out_event->struct_size = sizeof(*out_event) before
 * every call. ABI v2 and later require at least that size, write the complete
 * v2 event, and ignore any trailing caller storage. Payload pointers are
 * owned by the context and valid until the next next_event call.
 */
int keywork_context_next_event(
    keywork_context_t *context,
    struct keywork_event *out_event
);

/*
 * Returns the current XDG desktop-portal color-scheme preference. An
 * APPEARANCE_CHANGED event has surface_id zero; query this function for the
 * latest value. Keywork also applies the preference to default widget themes.
 */
int keywork_context_get_color_scheme(
    const keywork_context_t *context,
    int *out_color_scheme
);

/* Returns the resolved default theme colors for the context's color scheme. */
int keywork_context_get_theme_colors(
    const keywork_context_t *context,
    struct keywork_theme_colors *out_colors
);

/* Changes the context's XDG icon theme, clears icon lookup misses/hits, and invalidates surfaces. */
int keywork_context_set_icon_theme(keywork_context_t *context, const char *theme_name);

/*
 * Creates immutable context-local image resources. Input rows may have
 * padding; pixels_len must cover (height - 1) * stride_bytes plus the final
 * packed row. RGBA8 data uses straight-alpha R,G,B,A byte order. Both calls
 * copy their input before returning.
 */
int keywork_context_create_image_rgba8(
    keywork_context_t *context,
    uint32_t width,
    uint32_t height,
    size_t stride_bytes,
    const uint8_t *pixels,
    size_t pixels_len,
    uint64_t *out_resource_id
);
int keywork_context_create_alpha_mask_a8(
    keywork_context_t *context,
    uint32_t width,
    uint32_t height,
    size_t stride_bytes,
    const uint8_t *pixels,
    size_t pixels_len,
    uint64_t *out_resource_id
);

/*
 * Releases host ownership. Installed documents retain referenced resources,
 * so an ID remains valid for those documents until they are replaced or their
 * surfaces are destroyed. IDs are context-local and are never reused.
 */
void keywork_context_release_resource(keywork_context_t *context, uint64_t resource_id);

int keywork_surface_create(
    keywork_context_t *context,
    const struct keywork_surface_options *options,
    keywork_surface_t **out_surface
);
void keywork_surface_destroy(
    keywork_context_t *context,
    keywork_surface_t *surface
);
uint64_t keywork_surface_id(const keywork_surface_t *surface);

/*
 * Atomically replaces the surface document. `bytes` only need to remain
 * valid for this call. See docs/widget-schema-v0.md for the wire format.
 */
int keywork_surface_submit(
    keywork_surface_t *surface,
    const uint8_t *bytes,
    size_t bytes_len,
    uint64_t *out_document_id
);
int keywork_surface_invalidate(keywork_surface_t *surface);

#if defined(__cplusplus)
}
#endif

#endif
