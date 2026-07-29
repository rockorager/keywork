#include <lauxlib.h>
#include <lua.h>
#include <pwd.h>
#include <security/pam_appl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

#define AUTH_PAM_SERVICE "keywork-shell"

struct conversation_data {
    const char *username;
    const char *password;
};

static void clear_string(char *value) {
    if (value == NULL) return;
    volatile unsigned char *cursor = (volatile unsigned char *)value;
    size_t length = strlen(value);
    while (length-- > 0) *cursor++ = 0;
}

static void free_responses(struct pam_response *responses, int count) {
    if (responses == NULL) return;
    for (int index = 0; index < count; index++) {
        clear_string(responses[index].resp);
        free(responses[index].resp);
    }
    free(responses);
}

static int converse(
    int message_count,
    const struct pam_message **messages,
    struct pam_response **response_out,
    void *data_ptr
) {
    if (message_count <= 0 || messages == NULL || response_out == NULL || data_ptr == NULL)
        return PAM_CONV_ERR;

    const struct conversation_data *data = data_ptr;
    struct pam_response *responses = calloc((size_t)message_count, sizeof(*responses));
    if (responses == NULL) return PAM_BUF_ERR;

    for (int index = 0; index < message_count; index++) {
        const char *answer = NULL;
        switch (messages[index]->msg_style) {
        case PAM_PROMPT_ECHO_OFF:
            answer = data->password;
            break;
        case PAM_PROMPT_ECHO_ON:
            answer = data->username;
            break;
        case PAM_ERROR_MSG:
        case PAM_TEXT_INFO:
            continue;
        default:
            free_responses(responses, message_count);
            return PAM_CONV_ERR;
        }
        responses[index].resp = strdup(answer);
        if (responses[index].resp == NULL) {
            free_responses(responses, message_count);
            return PAM_BUF_ERR;
        }
    }

    *response_out = responses;
    return PAM_SUCCESS;
}

static int authenticate(const char *password) {
    struct passwd entry;
    struct passwd *result = NULL;
    long requested_size = sysconf(_SC_GETPW_R_SIZE_MAX);
    size_t buffer_size = requested_size > 0 ? (size_t)requested_size : 16384;
    char *buffer = malloc(buffer_size);
    if (buffer == NULL) return 0;

    int lookup_status = getpwuid_r(getuid(), &entry, buffer, buffer_size, &result);
    if (lookup_status != 0 || result == NULL) {
        free(buffer);
        return 0;
    }

    struct conversation_data data = {
        .username = result->pw_name,
        .password = password,
    };
    const struct pam_conv conversation = {
        .conv = converse,
        .appdata_ptr = &data,
    };
    pam_handle_t *handle = NULL;
    int status = pam_start(AUTH_PAM_SERVICE, result->pw_name, &conversation, &handle);
    if (status == PAM_SUCCESS) status = pam_authenticate(handle, 0);
    if (status == PAM_SUCCESS) (void)pam_setcred(handle, PAM_REFRESH_CRED);
    if (handle != NULL) pam_end(handle, status);
    free(buffer);
    return status == PAM_SUCCESS;
}

static int lua_authenticate(lua_State *lua_state) {
    size_t password_len = 0;
    const char *password = luaL_checklstring(lua_state, 1, &password_len);
    if (memchr(password, '\0', password_len) != NULL) {
        lua_pushboolean(lua_state, 0);
        return 1;
    }
    lua_pushboolean(lua_state, authenticate(password));
    return 1;
}

int luaopen_shell_auth(lua_State *lua_state) {
    lua_newtable(lua_state);
    lua_pushcfunction(lua_state, lua_authenticate);
    lua_setfield(lua_state, -2, "authenticate");
    return 1;
}
