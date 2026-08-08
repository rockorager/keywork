#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <inttypes.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>

struct counter {
    uint64_t done;
};

static void callback_done(void *data, struct wl_callback *callback, uint32_t serial) {
    (void)serial;
    struct counter *counter = data;
    counter->done++;
    wl_callback_destroy(callback);
}

static const struct wl_callback_listener callback_listener = { .done = callback_done };

static uint64_t monotonic_ns(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) abort();
    return (uint64_t)now.tv_sec * 1000000000ULL + (uint64_t)now.tv_nsec;
}

static void fail(const char *message) {
    fprintf(stderr, "wayring-benchmark-client: %s: %s\n", message, strerror(errno));
    exit(1);
}

static struct wl_display *connect_path(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) fail("socket");
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    if (strlen(path) >= sizeof(address.sun_path)) {
        errno = ENAMETOOLONG;
        fail("socket path");
    }
    strcpy(address.sun_path, path);
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) fail("connect");
    struct wl_display *display = wl_display_connect_to_fd(fd);
    if (display == NULL) fail("wl_display_connect_to_fd");
    return display;
}

static uint64_t parse_count(const char *text) {
    char *end = NULL;
    errno = 0;
    unsigned long long value = strtoull(text, &end, 10);
    if (errno != 0 || *text == '\0' || *end != '\0' || value == 0) {
        fprintf(stderr, "invalid positive count: %s\n", text);
        exit(2);
    }
    return value;
}

int main(int argc, char **argv) {
    if (argc != 6 || (strcmp(argv[2], "serial") != 0 && strcmp(argv[2], "pipeline") != 0 &&
        strcmp(argv[2], "churn") != 0 && strcmp(argv[2], "registry") != 0)) {
        fprintf(stderr, "usage: %s SOCKET serial|pipeline|churn|registry OPERATIONS WARMUP HOLD_MS\n", argv[0]);
        return 2;
    }
    const uint64_t operations = parse_count(argv[3]);
    const uint64_t warmup = parse_count(argv[4]);
    const uint64_t hold_ms = parse_count(argv[5]);
    struct wl_display *display = connect_path(argv[1]);
    for (uint64_t i = 0; i < warmup; i++)
        if (wl_display_roundtrip(display) < 0) fail("warmup roundtrip");

    puts("READY");
    fflush(stdout);
    char start;
    if (read(STDIN_FILENO, &start, 1) != 1) fail("start gate");

    struct counter counter = {0};
    uint64_t begin = monotonic_ns();
    if (strcmp(argv[2], "serial") == 0) {
        for (uint64_t i = 0; i < operations; i++)
            if (wl_display_roundtrip(display) < 0) fail("measured roundtrip");
        counter.done = operations;
    } else if (strcmp(argv[2], "pipeline") == 0) {
        const uint64_t pipeline_batch = 5000;
        for (uint64_t issued = 0; issued < operations;) {
            const uint64_t target = issued + (operations - issued < pipeline_batch ? operations - issued : pipeline_batch);
            for (; issued < target; issued++) {
                struct wl_callback *callback = wl_display_sync(display);
                if (callback == NULL || wl_callback_add_listener(callback, &callback_listener, &counter) != 0)
                    fail("create callback");
            }
            if (wl_display_flush(display) < 0 && errno != EAGAIN) fail("flush");
            while (counter.done < target)
                if (wl_display_dispatch(display) < 0) fail("dispatch");
        }
    } else if (strcmp(argv[2], "registry") == 0) {
        for (uint64_t i = 0; i < operations; i++) {
            struct wl_registry *registry = wl_display_get_registry(display);
            if (registry == NULL || wl_display_roundtrip(display) < 0) fail("registry roundtrip");
            wl_registry_destroy(registry);
        }
        counter.done = operations;
    } else {
        wl_display_disconnect(display);
        display = NULL;
        for (uint64_t i = 0; i < operations; i++) {
            struct wl_display *connection = connect_path(argv[1]);
            struct wl_registry *registry = wl_display_get_registry(connection);
            if (registry == NULL || wl_display_roundtrip(connection) < 0) fail("churn registry roundtrip");
            wl_registry_destroy(registry);
            wl_display_disconnect(connection);
        }
        counter.done = operations;
    }
    uint64_t elapsed = monotonic_ns() - begin;
    if (counter.done != operations) {
        fprintf(stderr, "completed operation count mismatch: %" PRIu64 " != %" PRIu64 "\n", counter.done, operations);
        return 1;
    }
    printf("{\"workload\":\"%s\",\"operations\":%" PRIu64 ",\"completed\":%" PRIu64 ",\"wall_ns\":%" PRIu64 "}\n",
           argv[2], operations, counter.done, elapsed);
    fflush(stdout);
    struct timespec hold = { .tv_sec = hold_ms / 1000, .tv_nsec = (hold_ms % 1000) * 1000000L };
    while (nanosleep(&hold, &hold) != 0 && errno == EINTR) {}
    if (display != NULL) wl_display_disconnect(display);
    return 0;
}
