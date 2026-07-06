#ifndef KEYWORK_H
#define KEYWORK_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum keywork_backend {
    KEYWORK_BACKEND_LOG = 0,
    KEYWORK_BACKEND_WAYLAND_SHM = 1,
    KEYWORK_BACKEND_VULKAN = 2,
};

enum keywork_layer_shell_layer {
    KEYWORK_LAYER_BACKGROUND = 0,
    KEYWORK_LAYER_BOTTOM = 1,
    KEYWORK_LAYER_TOP = 2,
    KEYWORK_LAYER_OVERLAY = 3,
};

enum keywork_layer_shell_anchor {
    KEYWORK_LAYER_ANCHOR_TOP = 1 << 0,
    KEYWORK_LAYER_ANCHOR_BOTTOM = 1 << 1,
    KEYWORK_LAYER_ANCHOR_LEFT = 1 << 2,
    KEYWORK_LAYER_ANCHOR_RIGHT = 1 << 3,
};

enum keywork_layer_shell_keyboard_interactivity {
    KEYWORK_LAYER_KEYBOARD_NONE = 0,
    KEYWORK_LAYER_KEYBOARD_EXCLUSIVE = 1,
    KEYWORK_LAYER_KEYBOARD_ON_DEMAND = 2,
};

typedef struct keywork_build keywork_build_t;
typedef struct keywork_widget keywork_widget_t;
typedef struct keywork_display_list keywork_display_list_t;
typedef struct keywork_event_loop keywork_event_loop_t;
typedef struct keywork_runtime keywork_runtime_t;
typedef struct keywork_timer keywork_timer_t;

enum keywork_loop_event {
    KEYWORK_LOOP_READ = 1 << 0,
    KEYWORK_LOOP_WRITE = 1 << 1,
    KEYWORK_LOOP_HANGUP = 1 << 2,
    KEYWORK_LOOP_ERROR = 1 << 3,
};

struct keywork_size {
    float width;
    float height;
};

struct keywork_rect {
    float x;
    float y;
    float width;
    float height;
};

struct keywork_constraints {
    float max_width;
    float max_height;
};

struct keywork_context {
    float window_width;
    float window_height;
    const char *color_scheme;
};

typedef void (*keywork_click_callback_t)(void *userdata);
typedef int (*keywork_install_event_sources_callback_t)(void *userdata, keywork_event_loop_t *loop, keywork_runtime_t *runtime);
typedef int (*keywork_fd_callback_t)(void *userdata, keywork_event_loop_t *loop, uint32_t events);
typedef int (*keywork_timer_callback_t)(void *userdata, keywork_event_loop_t *loop, uint64_t expirations);
/* The text pointer is only valid for the duration of the callback. */
typedef void (*keywork_text_change_callback_t)(void *userdata, const char *text, size_t len);
typedef keywork_widget_t *(*keywork_item_builder_t)(void *userdata, keywork_build_t *build, size_t index);

enum keywork_scroll_axes {
    KEYWORK_SCROLL_VERTICAL = 0,
    KEYWORK_SCROLL_HORIZONTAL = 1,
    KEYWORK_SCROLL_BOTH = 2,
};

enum keywork_main_align {
    KEYWORK_MAIN_ALIGN_START = 0,
    KEYWORK_MAIN_ALIGN_CENTER = 1,
    KEYWORK_MAIN_ALIGN_END = 2,
    KEYWORK_MAIN_ALIGN_SPACE_BETWEEN = 3,
    KEYWORK_MAIN_ALIGN_SPACE_AROUND = 4,
    KEYWORK_MAIN_ALIGN_SPACE_EVENLY = 5,
};

enum keywork_cross_align {
    KEYWORK_CROSS_ALIGN_START = 0,
    KEYWORK_CROSS_ALIGN_CENTER = 1,
    KEYWORK_CROSS_ALIGN_END = 2,
    KEYWORK_CROSS_ALIGN_STRETCH = 3,
};

struct keywork_app_vtable {
    keywork_widget_t *(*build)(void *userdata, keywork_build_t *build, const struct keywork_context *context);
    keywork_install_event_sources_callback_t install_event_sources;
};

struct keywork_render_object_vtable {
    struct keywork_size (*layout)(void *userdata, struct keywork_constraints constraints);
    int (*paint)(void *userdata, keywork_display_list_t *display_list, struct keywork_rect rect);
    void (*destroy)(void *userdata);
};

struct keywork_build_context {
    struct keywork_constraints constraints;
};

struct keywork_stateful_vtable {
    void *(*create_state)(void *userdata);
    int (*update)(void *userdata, void *state, const struct keywork_build_context *context);
    keywork_widget_t *(*build)(void *userdata, void *state, keywork_build_t *build, const struct keywork_build_context *context);
    void (*destroy_state)(void *userdata, void *state);
};

struct keywork_element_vtable {
    keywork_widget_t *(*build)(void *userdata, keywork_build_t *build, const struct keywork_build_context *context);
    void (*destroy)(void *userdata);
};

struct keywork_run_options {
    const char *title;
    int backend;
    float width;
    float height;
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

struct keywork_run_text_options {
    const char *title;
    const char *text;
    int backend;
    float width;
    float height;
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

int keywork_run_app(const struct keywork_run_options *options, const struct keywork_app_vtable *vtable, void *userdata);
int keywork_run_text(const struct keywork_run_text_options *options);

int keywork_loop_add_fd(keywork_event_loop_t *loop, int fd, uint32_t events, keywork_fd_callback_t callback, void *userdata);
void keywork_loop_remove_fd(keywork_event_loop_t *loop, int fd);
keywork_timer_t *keywork_loop_add_timer(keywork_event_loop_t *loop, keywork_timer_callback_t callback, void *userdata);
int keywork_timer_arm(keywork_timer_t *timer, uint64_t delay_ms, uint64_t interval_ms);
void keywork_timer_disarm(keywork_timer_t *timer);
int keywork_runtime_invalidate(keywork_runtime_t *runtime);
int keywork_runtime_invalidate_state(keywork_runtime_t *runtime);
void keywork_loop_quit(keywork_event_loop_t *loop);

keywork_widget_t *keywork_text(keywork_build_t *build, const char *value);
keywork_widget_t *keywork_colored_text(keywork_build_t *build, const char *value, uint32_t argb);
keywork_widget_t *keywork_text_input(keywork_build_t *build, const char *id, const char *value, const char *placeholder);
keywork_widget_t *keywork_text_input_on_change(keywork_build_t *build, const char *id, const char *value, const char *placeholder, keywork_text_change_callback_t callback, void *userdata);
keywork_widget_t *keywork_scroll(keywork_build_t *build, const char *id, keywork_widget_t *child, enum keywork_scroll_axes axes);
keywork_widget_t *keywork_list(keywork_build_t *build, const char *id, size_t item_count, float item_extent, keywork_item_builder_t callback, void *userdata);
/* Pass a negative width or height to leave that axis unconstrained. */
keywork_widget_t *keywork_sized(keywork_build_t *build, keywork_widget_t *child, float width, float height);
keywork_widget_t *keywork_box(keywork_build_t *build, keywork_widget_t *child, uint32_t argb);
keywork_widget_t *keywork_clickable(keywork_build_t *build, const char *id, keywork_widget_t *child, keywork_click_callback_t callback, void *userdata);
keywork_widget_t *keywork_button(keywork_build_t *build, const char *id, const char *label, keywork_click_callback_t callback, void *userdata);
keywork_widget_t *keywork_render_object(keywork_build_t *build, const struct keywork_render_object_vtable *vtable, void *userdata);
int keywork_display_list_fill_rect(keywork_display_list_t *display_list, struct keywork_rect rect, uint32_t argb);
keywork_widget_t *keywork_stateful(keywork_build_t *build, const struct keywork_stateful_vtable *vtable, void *userdata);
keywork_widget_t *keywork_element(keywork_build_t *build, const struct keywork_element_vtable *vtable, void *userdata);
keywork_widget_t *keywork_padding(keywork_build_t *build, float inset, keywork_widget_t *child);
keywork_widget_t *keywork_center(keywork_build_t *build, keywork_widget_t *child);
keywork_widget_t *keywork_keyed_string(keywork_build_t *build, const char *key, keywork_widget_t *child);
keywork_widget_t *keywork_keyed_int(keywork_build_t *build, uint64_t key, keywork_widget_t *child);
keywork_widget_t *keywork_column(keywork_build_t *build, keywork_widget_t *const *children, size_t child_count, float gap);
keywork_widget_t *keywork_row(keywork_build_t *build, keywork_widget_t *const *children, size_t child_count, float gap);
keywork_widget_t *keywork_column_aligned(keywork_build_t *build, keywork_widget_t *const *children, size_t child_count, float gap, enum keywork_main_align main_align, enum keywork_cross_align cross_align);
keywork_widget_t *keywork_row_aligned(keywork_build_t *build, keywork_widget_t *const *children, size_t child_count, float gap, enum keywork_main_align main_align, enum keywork_cross_align cross_align);
/* An expanded child fills its share of the row/column main axis; a
 * flexible child may be smaller. Shares are proportional to flex. */
keywork_widget_t *keywork_expanded(keywork_build_t *build, keywork_widget_t *child, float flex);
keywork_widget_t *keywork_flexible(keywork_build_t *build, keywork_widget_t *child, float flex);

#ifdef __cplusplus
}
#endif

#endif
