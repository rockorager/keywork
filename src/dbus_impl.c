#include "dbus_c.h"

dbus_bool_t keywork_dbus_bus_add_match(
    DBusConnection *connection,
    const char *rule
) {
    DBusError error;
    dbus_error_init(&error);
    dbus_bus_add_match(connection, rule, &error);
    dbus_bool_t succeeded = !dbus_error_is_set(&error);
    dbus_error_free(&error);
    return succeeded;
}
