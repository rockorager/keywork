#pragma once

#include <dbus/dbus.h>

dbus_bool_t keywork_dbus_bus_add_match(
    DBusConnection *connection,
    const char *rule
);
