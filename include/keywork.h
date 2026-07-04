#ifndef KEYWORK_H
#define KEYWORK_H

#ifdef __cplusplus
extern "C" {
#endif

enum keywork_backend {
    KEYWORK_BACKEND_LOG = 0,
    KEYWORK_BACKEND_WAYLAND_SHM = 1,
    KEYWORK_BACKEND_VULKAN = 2,
};

struct keywork_run_text_options {
    const char *title;
    const char *text;
    int backend;
    float width;
    float height;
};

int keywork_run_text(const struct keywork_run_text_options *options);

#ifdef __cplusplus
}
#endif

#endif
