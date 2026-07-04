#include <stdio.h>
#include <string.h>

#include "keywork.h"

struct app_state {
    unsigned count;
    int pulse;
};

static keywork_widget_t *build(void *userdata, keywork_build_t *build, const struct keywork_context *context) {
    struct app_state *state = userdata;
    char count_label[64];
    snprintf(count_label, sizeof(count_label), "Count from C: %u", state->count);

    keywork_widget_t *button_label = keywork_colored_text(build, "Increment", 0xffffffffu);
    keywork_widget_t *button_padding = keywork_padding(build, 8.0f, button_label);
    keywork_widget_t *button_box = keywork_box(build, button_padding, 0xff6d4affu);
    keywork_widget_t *button = keywork_clickable(build, "increment", button_box);
    keywork_widget_t *input = keywork_text_input(build, "c-input", context->input_text, "Type here", context->focused_input_id != NULL);
    keywork_widget_t *children[] = {
        keywork_colored_text(build, "C app hosted by libkeywork", 0xff6d4affu),
        keywork_text(build, count_label),
        input,
        keywork_text(build, state->pulse ? "timer: tick" : "timer: tock"),
        keywork_text(build, context->color_scheme),
        button,
    };
    keywork_widget_t *column = keywork_column(build, children, sizeof(children) / sizeof(children[0]), 12.0f);
    return keywork_padding(build, 24.0f, column);
}

static int click(void *userdata, const char *id) {
    struct app_state *state = userdata;
    if (strcmp(id, "increment") != 0) return 0;
    state->count += 1;
    return 1;
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
