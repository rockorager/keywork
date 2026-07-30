#define _GNU_SOURCE 1

#include "application_varlink.h"
#include <systemd/sd-json.h>
#include <systemd/sd-varlink-idl.h>

SD_VARLINK_DEFINE_STRUCT_TYPE(
    Status,
    SD_VARLINK_DEFINE_FIELD(appId, SD_VARLINK_STRING, 0),
    SD_VARLINK_DEFINE_FIELD(instanceId, SD_VARLINK_STRING, 0),
    SD_VARLINK_DEFINE_FIELD(generation, SD_VARLINK_INT, 0),
    SD_VARLINK_DEFINE_FIELD(reloading, SD_VARLINK_BOOL, 0),
    SD_VARLINK_DEFINE_FIELD(reloadSupported, SD_VARLINK_BOOL, 0));

SD_VARLINK_DEFINE_METHOD(
    GetStatus,
    SD_VARLINK_DEFINE_OUTPUT_BY_TYPE(status, Status, 0));

SD_VARLINK_DEFINE_METHOD(
    Reload,
    SD_VARLINK_DEFINE_OUTPUT(generation, SD_VARLINK_INT, 0));

SD_VARLINK_DEFINE_ERROR(ReloadUnsupported);
SD_VARLINK_DEFINE_ERROR(
    ReloadFailed,
    SD_VARLINK_DEFINE_FIELD(message, SD_VARLINK_STRING, 0));

SD_VARLINK_DEFINE_INTERFACE(
    application,
    "dev.rockorager.keywork.application",
    &vl_type_Status,
    &vl_method_GetStatus,
    &vl_method_Reload,
    &vl_error_ReloadUnsupported,
    &vl_error_ReloadFailed);

const sd_varlink_interface *keywork_application_varlink_interface(void) {
    return &vl_interface_application;
}

int keywork_application_reply_status(
    sd_varlink *link,
    const char *app_id,
    const char *instance_id,
    int64_t generation,
    int reloading,
    int reload_supported) {
    return sd_varlink_replybo(
        link,
        SD_JSON_BUILD_PAIR_OBJECT(
            "status",
            SD_JSON_BUILD_PAIR_STRING("appId", app_id),
            SD_JSON_BUILD_PAIR_STRING("instanceId", instance_id),
            SD_JSON_BUILD_PAIR_INTEGER("generation", generation),
            SD_JSON_BUILD_PAIR_BOOLEAN("reloading", reloading),
            SD_JSON_BUILD_PAIR_BOOLEAN("reloadSupported", reload_supported)));
}

int keywork_application_reply_reload(sd_varlink *link, int64_t generation) {
    return sd_varlink_replybo(
        link,
        SD_JSON_BUILD_PAIR_INTEGER("generation", generation));
}

int keywork_application_error_reload_failed(sd_varlink *link, const char *message) {
    return sd_varlink_errorbo(
        link,
        "dev.rockorager.keywork.application.ReloadFailed",
        SD_JSON_BUILD_PAIR_STRING("message", message));
}
