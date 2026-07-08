#include "keywork.h"

#include <stdint.h>
#include <string.h>

static void put_u16(uint8_t *out, uint16_t value) {
    out[0] = (uint8_t)value;
    out[1] = (uint8_t)(value >> 8);
}

static void put_u32(uint8_t *out, uint32_t value) {
    out[0] = (uint8_t)value;
    out[1] = (uint8_t)(value >> 8);
    out[2] = (uint8_t)(value >> 16);
    out[3] = (uint8_t)(value >> 24);
}

int main(void) {
    keywork_context_t *context = NULL;
    keywork_surface_t *surface = NULL;
    uint64_t document_id = 0;
    int color_scheme = -1;
    struct keywork_surface_options options = {
        .struct_size = sizeof(options),
        .backend = KEYWORK_BACKEND_HEADLESS,
        .title = "C ABI smoke test",
        .app_id = "dev.keywork.Smoke",
        .width = 320,
        .height = 80,
    };

    if (keywork_abi_version() != KEYWORK_ABI_VERSION) return 1;
    if (keywork_widget_version() != KEYWORK_WIDGET_VERSION) return 9;
    if (keywork_context_create(&context) != KEYWORK_OK) return 2;
    if (keywork_context_event_fd(context) < 0) return 3;
    if (keywork_context_get_color_scheme(context, &color_scheme) != KEYWORK_OK) return 7;
    if (color_scheme < KEYWORK_COLOR_SCHEME_NO_PREFERENCE ||
        color_scheme > KEYWORK_COLOR_SCHEME_LIGHT) return 8;
    if (keywork_surface_create(context, &options, &surface) != KEYWORK_OK) return 4;

    static const char text[] = "libkeywork C ABI smoke test";
    uint8_t document[48 + 80 + sizeof(text) - 1] = {0};
    memcpy(document, "KWW0", 4);
    put_u16(document + 4, KEYWORK_WIDGET_VERSION);
    put_u16(document + 6, 48);
    put_u32(document + 8, sizeof(document));
    put_u32(document + 12, 0); /* root */
    put_u32(document + 16, 1); /* nodes */
    put_u32(document + 20, 0); /* child indices */
    put_u32(document + 24, 0); /* bindings */
    put_u32(document + 28, sizeof(text) - 1);
    put_u16(document + 48, 1); /* text node */
    put_u32(document + 48 + 24, sizeof(text) - 1);
    memcpy(document + 48 + 80, text, sizeof(text) - 1);

    if (keywork_surface_submit(surface, document, sizeof(document), &document_id) != KEYWORK_OK) return 5;
    if (document_id == 0) return 10;
    if (keywork_context_dispatch(context) != KEYWORK_OK) return 6;

    keywork_surface_destroy(context, surface);
    keywork_context_destroy(context);
    return 0;
}
