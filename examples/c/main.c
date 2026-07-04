#include <stdio.h>

#include "keywork.h"

int main(void) {
    const struct keywork_run_text_options options = {
        .title = "Keywork C example",
        .text = "Hello from C through libkeywork",
        .backend = KEYWORK_BACKEND_LOG,
        .width = 480.0f,
        .height = 240.0f,
    };
    const int result = keywork_run_text(&options);
    if (result != 0) {
        fprintf(stderr, "keywork_run_text failed: %d\n", result);
    }
    return result;
}
