#pragma once

#include <stdint.h>
#include <systemd/sd-varlink.h>

const sd_varlink_interface *keywork_application_varlink_interface(void);

int keywork_application_reply_status(
    sd_varlink *link,
    const char *app_id,
    const char *instance_id,
    int64_t generation,
    int reloading,
    int reload_supported);

int keywork_application_reply_reload(sd_varlink *link, int64_t generation);
int keywork_application_error_reload_failed(sd_varlink *link, const char *message);
