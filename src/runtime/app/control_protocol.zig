//! Public contract for per-instance Keywork application control.

pub const interface_name = "dev.rockorager.keywork.application";
pub const interface_description = @embedFile("control.varlink");

pub const Status = struct {
    appId: []const u8,
    instanceId: []const u8,
    generation: i64,
    reloading: bool,
    reloadSupported: bool,
};

pub const StatusReply = struct {
    status: Status,
};

pub const ReloadReply = struct {
    generation: i64,
};

pub const get_status_method = interface_name ++ ".GetStatus";
pub const reload_method = interface_name ++ ".Reload";
pub const reload_unsupported_error = interface_name ++ ".ReloadUnsupported";
pub const reload_failed_error = interface_name ++ ".ReloadFailed";
