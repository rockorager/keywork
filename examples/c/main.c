#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "keywork.h"

struct app_state {
    unsigned count;
    int pulse;
};

static int click(void *userdata, const char *id);
static struct keywork_size progress_layout(void *userdata, struct keywork_constraints constraints);
static int progress_paint(void *userdata, keywork_display_list_t *display_list, struct keywork_rect rect);
static void *status_create_state(void *userdata);
static int status_update(void *userdata, void *state, const struct keywork_build_context *context);
static keywork_widget_t *status_build(void *userdata, void *state, keywork_build_t *build, const struct keywork_build_context *context);
static void status_destroy_state(void *userdata, void *state);
static keywork_widget_t *panel_build(void *userdata, keywork_build_t *build, const struct keywork_build_context *context);

static keywork_widget_t *build(void *userdata, keywork_build_t *build, const struct keywork_context *context) {
    struct app_state *state = userdata;
    char count_label[64];
    snprintf(count_label, sizeof(count_label), "Count from C: %u", state->count);

    const struct keywork_render_object_vtable progress_vtable = {
        .layout = progress_layout,
        .paint = progress_paint,
    };
    keywork_widget_t *progress = keywork_render_object(build, &progress_vtable, state);
    const struct keywork_stateful_vtable status_vtable = {
        .create_state = status_create_state,
        .update = status_update,
        .build = status_build,
        .destroy_state = status_destroy_state,
    };
    keywork_widget_t *status = keywork_stateful(build, &status_vtable, state);
    const struct keywork_element_vtable panel_vtable = {
        .build = panel_build,
    };
    keywork_widget_t *panel = keywork_element(build, &panel_vtable, state);

    keywork_widget_t *button = keywork_keyed_string(build, "increment-button",
        keywork_button(build, "increment", "Increment", 0));
    keywork_widget_t *input = keywork_text_input(build, "c-input", context->input_text, "Type here", context->focused_input_id != NULL);
    keywork_widget_t *labels[] = {
        keywork_text(build, state->pulse ? "timer: tick" : "timer: tock"),
        keywork_text(build, context->color_scheme),
    };
    keywork_widget_t *status_row = keywork_row(build, labels, sizeof(labels) / sizeof(labels[0]), 12.0f);
    keywork_widget_t *children[] = {
        keywork_colored_text(build, "C app hosted by libkeywork", 0xff6d4affu),
        keywork_text(build, count_label),
        panel,
        status,
        progress,
        input,
        status_row,
        keywork_center(build, button),
    };
    keywork_widget_t *column = keywork_column(build, children, sizeof(children) / sizeof(children[0]), 12.0f);
    return keywork_padding(build, 24.0f, column);
}

static int click(void *userdata, const char *id) {
    struct app_state *state = userdata;
    if (id == NULL || strcmp(id, "increment") != 0) return 0;
    state->count += 1;
    return 1;
}

static struct keywork_size progress_layout(void *userdata, struct keywork_constraints constraints) {
    (void)userdata;
    struct keywork_size size = { constraints.max_width, 12.0f };
    if (size.width > 240.0f) size.width = 240.0f;
    return size;
}

static int progress_paint(void *userdata, keywork_display_list_t *display_list, struct keywork_rect rect) {
    struct app_state *state = userdata;
    const float fraction = (float)(state->count % 10u) / 9.0f;
    struct keywork_rect fill = rect;
    fill.width *= fraction;
    return keywork_display_list_fill_rect(display_list, rect, 0xffe6e0ffu) &&
        keywork_display_list_fill_rect(display_list, fill, 0xff6d4affu);
}

struct status_state {
    unsigned builds;
    unsigned updates;
};

static void *status_create_state(void *userdata) {
    (void)userdata;
    struct status_state *state = malloc(sizeof(*state));
    if (state == NULL) return NULL;
    state->builds = 0;
    state->updates = 0;
    return state;
}

static int status_update(void *userdata, void *state, const struct keywork_build_context *context) {
    (void)userdata;
    (void)context;
    struct status_state *status = state;
    status->updates += 1;
    return 1;
}

static keywork_widget_t *status_build(void *userdata, void *state, keywork_build_t *build, const struct keywork_build_context *context) {
    struct app_state *app = userdata;
    struct status_state *status = state;
    (void)context;
    status->builds += 1;
    char label[96];
    snprintf(label, sizeof(label), "stateful C widget: count=%u builds=%u updates=%u", app->count, status->builds, status->updates);
    return keywork_text(build, label);
}

static void status_destroy_state(void *userdata, void *state) {
    (void)userdata;
    free(state);
}

static keywork_widget_t *panel_build(void *userdata, keywork_build_t *build, const struct keywork_build_context *context) {
    struct app_state *app = userdata;
    char label[96];
    snprintf(label, sizeof(label), "custom C element: count=%u max-width=%.0f", app->count, context->constraints.max_width);
    keywork_widget_t *text = keywork_colored_text(build, label, 0xffffffffu);
    keywork_widget_t *padded = keywork_padding(build, 8.0f, text);
    return keywork_box(build, padded, 0xff6d4affu);
}

static int timer(void *userdata, uint64_t expirations) {
    struct app_state *state = userdata;
    if (expirations == 0) return 0;
    state->pulse = !state->pulse;
    return 1;
}

int main(void) {
    struct app_state state = {0};
    const struct keywork_app_vtable app = {
        .build = build,
        .click = click,
        .timer = timer,
    };
    const struct keywork_run_options options = {
        .title = "Keywork C app example",
        .backend = KEYWORK_BACKEND_WAYLAND_SHM,
        .width = 480.0f,
        .height = 320.0f,
        .timer_interval_ms = 0,
    };
    const int result = keywork_run_app(&options, &app, &state);
    if (result != 0) {
        fprintf(stderr, "keywork_run_app failed: %d\n", result);
    }
    return result;
}
