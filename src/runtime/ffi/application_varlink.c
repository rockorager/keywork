#define _GNU_SOURCE 1

#include "application_varlink.h"
#include <systemd/sd-json.h>
#include <systemd/sd-varlink-idl.h>
#include <stdlib.h>

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

SD_VARLINK_DEFINE_STRUCT_TYPE(
    Action,
    SD_VARLINK_DEFINE_FIELD(handle, SD_VARLINK_STRING, 0),
    SD_VARLINK_DEFINE_FIELD(id, SD_VARLINK_STRING, 0),
    SD_VARLINK_DEFINE_FIELD(enabled, SD_VARLINK_BOOL, 0),
    SD_VARLINK_DEFINE_FIELD(inputSchemaJson, SD_VARLINK_STRING, SD_VARLINK_NULLABLE));

SD_VARLINK_DEFINE_METHOD(
    ListActions,
    SD_VARLINK_DEFINE_OUTPUT_BY_TYPE(actions, Action, SD_VARLINK_ARRAY));

SD_VARLINK_DEFINE_METHOD(
    InvokeAction,
    SD_VARLINK_DEFINE_INPUT(handle, SD_VARLINK_STRING, 0),
    SD_VARLINK_DEFINE_INPUT(targetJson, SD_VARLINK_STRING, SD_VARLINK_NULLABLE));

SD_VARLINK_DEFINE_STRUCT_TYPE(
    UiSnapshot,
    SD_VARLINK_DEFINE_FIELD(generation, SD_VARLINK_INT, 0),
    SD_VARLINK_DEFINE_FIELD(snapshotJson, SD_VARLINK_STRING, 0));

SD_VARLINK_DEFINE_METHOD(
    GetUiSnapshot,
    SD_VARLINK_DEFINE_OUTPUT_BY_TYPE(snapshot, UiSnapshot, 0));

SD_VARLINK_DEFINE_ERROR(ReloadUnsupported);
SD_VARLINK_DEFINE_ERROR(
    ReloadFailed,
    SD_VARLINK_DEFINE_FIELD(message, SD_VARLINK_STRING, 0));
SD_VARLINK_DEFINE_ERROR(ActionsUnavailable);
SD_VARLINK_DEFINE_ERROR(ActionNotFound);
SD_VARLINK_DEFINE_ERROR(
    ActionFailed,
    SD_VARLINK_DEFINE_FIELD(message, SD_VARLINK_STRING, 0));
SD_VARLINK_DEFINE_ERROR(UiUnavailable);
SD_VARLINK_DEFINE_ERROR(
    UiSnapshotFailed,
    SD_VARLINK_DEFINE_FIELD(message, SD_VARLINK_STRING, 0));

SD_VARLINK_DEFINE_INTERFACE(
    application,
    "dev.rockorager.keywork.application",
    &vl_type_Status,
    &vl_type_Action,
    &vl_type_UiSnapshot,
    &vl_method_GetStatus,
    &vl_method_Reload,
    &vl_method_ListActions,
    &vl_method_InvokeAction,
    &vl_method_GetUiSnapshot,
    &vl_error_ReloadUnsupported,
    &vl_error_ReloadFailed,
    &vl_error_ActionsUnavailable,
    &vl_error_ActionNotFound,
    &vl_error_ActionFailed,
    &vl_error_UiUnavailable,
    &vl_error_UiSnapshotFailed);

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

int keywork_application_reply_json(sd_varlink *link, const char *json) {
    sd_json_variant *parameters = NULL;
    int result = sd_json_parse(json, 0, &parameters, NULL, NULL);
    if (result >= 0)
        result = sd_varlink_reply(link, parameters);
    sd_json_variant_unref(parameters);
    return result;
}

int keywork_application_parameters_json(sd_json_variant *parameters, char **json) {
    return sd_json_variant_format(parameters, 0, json);
}

void keywork_application_free_json(char *json) {
    free(json);
}

int keywork_application_error_actions_unavailable(sd_varlink *link) {
    return sd_varlink_error(link, "dev.rockorager.keywork.application.ActionsUnavailable", NULL);
}

int keywork_application_error_action_not_found(sd_varlink *link) {
    return sd_varlink_error(link, "dev.rockorager.keywork.application.ActionNotFound", NULL);
}

int keywork_application_error_action_failed(sd_varlink *link, const char *message) {
    return sd_varlink_errorbo(
        link,
        "dev.rockorager.keywork.application.ActionFailed",
        SD_JSON_BUILD_PAIR_STRING("message", message));
}

int keywork_application_error_ui_unavailable(sd_varlink *link) {
    return sd_varlink_error(link, "dev.rockorager.keywork.application.UiUnavailable", NULL);
}

int keywork_application_error_ui_snapshot_failed(sd_varlink *link, const char *message) {
    return sd_varlink_errorbo(
        link,
        "dev.rockorager.keywork.application.UiSnapshotFailed",
        SD_JSON_BUILD_PAIR_STRING("message", message));
}
