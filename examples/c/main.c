#include "keywork.h"

#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

enum {
    HEADER_SIZE = 48,
    NODE_SIZE = 80,
    BINDING_SIZE = 16,
    NODE_COUNT = 4,
    CHILD_COUNT = 3,
    BINDING_COUNT = 0,
    HANDLER_INCREMENT = 1,
};

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

static void put_u64(uint8_t *out, uint64_t value) {
    put_u32(out, (uint32_t)value);
    put_u32(out + 4, (uint32_t)(value >> 32));
}

static void put_f32(uint8_t *out, float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    put_u32(out, bits);
}

static int submit_document(keywork_surface_t *surface, unsigned count, uint64_t *out_document_id) {
    char counter[64];
    const int counter_len = snprintf(counter, sizeof(counter), "Count from C: %u", count);
    static const char id[] = "increment";
    static const char button[] = "Increment";
    const size_t strings_size = (size_t)counter_len + sizeof(id) - 1 + sizeof(button) - 1;
    uint8_t bytes[HEADER_SIZE + NODE_COUNT * NODE_SIZE + CHILD_COUNT * 4 + 128] = {0};
    const size_t children_offset = HEADER_SIZE + NODE_COUNT * NODE_SIZE;
    const size_t bindings_offset = children_offset + CHILD_COUNT * 4;
    const size_t strings_offset = bindings_offset + BINDING_COUNT * BINDING_SIZE;
    const size_t total_size = strings_offset + strings_size;
    size_t string_cursor = 0;

    memcpy(bytes, "KWW0", 4);
    put_u16(bytes + 4, KEYWORK_WIDGET_VERSION);
    put_u16(bytes + 6, HEADER_SIZE);
    put_u32(bytes + 8, (uint32_t)total_size);
    put_u32(bytes + 12, 0); /* root widget */
    put_u32(bytes + 16, NODE_COUNT);
    put_u32(bytes + 20, CHILD_COUNT);
    put_u32(bytes + 24, BINDING_COUNT);
    put_u32(bytes + 28, (uint32_t)strings_size);

    /* Widget 0: column(widgets 1 and 2), 12px gap. */
    put_u16(bytes + HEADER_SIZE, 3);
    put_u32(bytes + HEADER_SIZE + 4, 0);
    put_u32(bytes + HEADER_SIZE + 8, 2);
    put_f32(bytes + HEADER_SIZE + 36, 12.0f);
    put_u32(bytes + children_offset, 1);
    put_u32(bytes + children_offset + 4, 2);

    /* Widget 1: counter text. */
    uint8_t *widget = bytes + HEADER_SIZE + NODE_SIZE;
    put_u16(widget, 1);
    put_u32(widget + 20, (uint32_t)string_cursor);
    put_u32(widget + 24, (uint32_t)counter_len);
    memcpy(bytes + strings_offset + string_cursor, counter, (size_t)counter_len);
    string_cursor += (size_t)counter_len;

    /* Widget 2: semantic button; libkeywork supplies theme-aware styling. */
    widget += NODE_SIZE;
    put_u16(widget, 19);
    put_u32(widget + 4, 2); /* first child table entry */
    put_u32(widget + 8, 1);
    put_u32(bytes + children_offset + 8, 3);
    put_u32(widget + 20, (uint32_t)string_cursor);
    put_u32(widget + 24, sizeof(id) - 1);
    put_u64(widget + 28, HANDLER_INCREMENT);
    memcpy(bytes + strings_offset + string_cursor, id, sizeof(id) - 1);
    string_cursor += sizeof(id) - 1;

    /* Widget 3: button label. */
    widget += NODE_SIZE;
    put_u16(widget, 1);
    put_u32(widget + 20, (uint32_t)string_cursor);
    put_u32(widget + 24, sizeof(button) - 1);
    put_u32(widget + 60, 1); /* label text role */
    memcpy(bytes + strings_offset + string_cursor, button, sizeof(button) - 1);
    return keywork_surface_submit(surface, bytes, total_size, out_document_id);
}

int main(void) {
    keywork_context_t *context = NULL;
    keywork_surface_t *surface = NULL;
    struct keywork_surface_options options = {
        .struct_size = sizeof(options),
        .backend = KEYWORK_BACKEND_AUTO,
        .title = "Keywork C example",
        .app_id = "dev.keywork.CExample",
        .width = 480,
        .height = 240,
    };
    int result = keywork_context_create(&context);
    if (result != KEYWORK_OK) return result;
    result = keywork_surface_create(context, &options, &surface);
    if (result != KEYWORK_OK) {
        keywork_context_destroy(context);
        return result;
    }

    unsigned count = 0;
    uint64_t active_document_id = 0;
    result = submit_document(surface, count, &active_document_id);
    struct pollfd descriptor = {
        .fd = keywork_context_event_fd(context),
        .events = POLLIN,
    };
    while (result == KEYWORK_OK && poll(&descriptor, 1, -1) >= 0) {
        result = keywork_context_dispatch(context);
        struct keywork_event event = {.struct_size = sizeof(event)};
        int event_result = 0;
        while (result == KEYWORK_OK &&
               (event_result = keywork_context_next_event(context, &event)) > 0) {
            if (event.kind == KEYWORK_EVENT_CLOSED) goto done;
            if (event.kind == KEYWORK_EVENT_APPEARANCE_CHANGED) {
                int color_scheme = KEYWORK_COLOR_SCHEME_NO_PREFERENCE;
                if (keywork_context_get_color_scheme(context, &color_scheme) == KEYWORK_OK) {
                    fprintf(stderr, "desktop color scheme: %d\n", color_scheme);
                }
            }
            if (event.kind == KEYWORK_EVENT_DOCUMENT_RETIRED) {
                /* Applications with per-document registries can clean them up here. */
            }
            if (event.kind == KEYWORK_EVENT_HANDLER &&
                event.document_id == active_document_id &&
                event.handler_id == HANDLER_INCREMENT) {
                result = submit_document(surface, ++count, &active_document_id);
            }
            event.struct_size = sizeof(event);
        }
        if (event_result < 0) result = -event_result;
    }

done:
    keywork_surface_destroy(context, surface);
    keywork_context_destroy(context);
    return result;
}
