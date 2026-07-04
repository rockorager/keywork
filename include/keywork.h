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

typedef struct keywork_build keywork_build_t;
typedef struct keywork_widget keywork_widget_t;
typedef struct keywork_display_list keywork_display_list_t;

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
    const char *input_text;
    float window_width;
    float window_height;
    const char *color_scheme;
};

struct keywork_app_vtable {
    keywork_widget_t *(*build)(void *userdata, keywork_build_t *build, const struct keywork_context *context);
    int (*click)(void *userdata, const char *id);
    int (*timer)(void *userdata, uint64_t expirations);
};

typedef void (*keywork_click_callback_t)(void *userdata);

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
    uint64_t timer_interval_ms;
};

struct keywork_run_text_options {
    const char *title;
    const char *text;
    int backend;
    float width;
    float height;
};

int keywork_run_app(const struct keywork_run_options *options, const struct keywork_app_vtable *vtable, void *userdata);
int keywork_run_text(const struct keywork_run_text_options *options);

keywork_widget_t *keywork_text(keywork_build_t *build, const char *value);
keywork_widget_t *keywork_colored_text(keywork_build_t *build, const char *value, uint32_t argb);
keywork_widget_t *keywork_text_input(keywork_build_t *build, const char *id, const char *value, const char *placeholder);
keywork_widget_t *keywork_box(keywork_build_t *build, keywork_widget_t *child, uint32_t argb);
keywork_widget_t *keywork_clickable(keywork_build_t *build, const char *id, keywork_widget_t *child);
keywork_widget_t *keywork_clickable_callback(keywork_build_t *build, keywork_widget_t *child, keywork_click_callback_t callback, void *userdata);
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

#ifdef __cplusplus
}
#endif

#endif
