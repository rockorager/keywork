#include <stdio.h>

#include "keywork.h"

struct app_state {
    unsigned count;
    int pulse;
};

static void increment(void *userdata);
static struct keywork_size progress_layout(void *userdata, struct keywork_constraints constraints);
static int progress_paint(void *userdata, keywork_display_list_t *display_list, struct keywork_rect rect);

static keywork_widget_t *build(void *userdata, keywork_build_t *build, const struct keywork_context *context) {
    struct app_state *state = userdata;
    char count_label[64];
    snprintf(count_label, sizeof(count_label), "Count from C: %u", state->count);

    const struct keywork_render_object_vtable progress_vtable = {
        .layout = progress_layout,
        .paint = progress_paint,
    };
    keywork_widget_t *progress = keywork_render_object(build, &progress_vtable, state);

    keywork_widget_t *button_label = keywork_colored_text(build, "Increment", 0xffffffffu);
    keywork_widget_t *button_padding = keywork_padding(build, 8.0f, button_label);
    keywork_widget_t *button_box = keywork_box(build, button_padding, 0xff6d4affu);
    keywork_widget_t *button = keywork_clickable_callback(build, button_box, increment, state);
    button = keywork_keyed_string(build, "increment-button", button);
    keywork_widget_t *input = keywork_text_input(build, "c-input", context->input_text, "Type here", context->focused_input_id != NULL);
    keywork_widget_t *labels[] = {
        keywork_text(build, state->pulse ? "timer: tick" : "timer: tock"),
        keywork_text(build, context->color_scheme),
    };
    keywork_widget_t *status_row = keywork_row(build, labels, sizeof(labels) / sizeof(labels[0]), 12.0f);
    keywork_widget_t *children[] = {
        keywork_colored_text(build, "C app hosted by libkeywork", 0xff6d4affu),
        keywork_text(build, count_label),
        progress,
        input,
        status_row,
        keywork_center(build, button),
    };
    keywork_widget_t *column = keywork_column(build, children, sizeof(children) / sizeof(children[0]), 12.0f);
    return keywork_padding(build, 24.0f, column);
}

static void increment(void *userdata) {
    struct app_state *state = userdata;
    state->count += 1;
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
        .timer = timer,
    };
    const struct keywork_run_options options = {
        .title = "Keywork C app example",
        .backend = KEYWORK_BACKEND_LOG,
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
