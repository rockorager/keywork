//! Application-level command-line and runner options.

pub const BackendKind = enum {
    log,
    wayland_shm,
    vulkan,
};
