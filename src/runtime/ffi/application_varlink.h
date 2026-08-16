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
int keywork_application_reply_json(sd_varlink *link, const char *json);
int keywork_application_parameters_json(sd_json_variant *parameters, char **json);
void keywork_application_free_json(char *json);
int keywork_application_error_actions_unavailable(sd_varlink *link);
int keywork_application_error_action_not_found(sd_varlink *link);
int keywork_application_error_action_failed(sd_varlink *link, const char *message);
int keywork_application_error_ui_unavailable(sd_varlink *link);
int keywork_application_error_ui_snapshot_failed(sd_varlink *link, const char *message);
