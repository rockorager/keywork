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

pub const Action = struct {
    handle: []const u8,
    id: []const u8,
    enabled: bool,
    inputSchemaJson: ?[]const u8,
};

pub const ActionsReply = struct {
    actions: []const Action,
};

pub const InvokeParameters = struct {
    handle: []const u8,
    targetJson: ?[]const u8 = null,
};

pub const get_status_method = interface_name ++ ".GetStatus";
pub const reload_method = interface_name ++ ".Reload";
pub const list_actions_method = interface_name ++ ".ListActions";
pub const invoke_action_method = interface_name ++ ".InvokeAction";
pub const reload_unsupported_error = interface_name ++ ".ReloadUnsupported";
pub const reload_failed_error = interface_name ++ ".ReloadFailed";
pub const actions_unavailable_error = interface_name ++ ".ActionsUnavailable";
pub const action_not_found_error = interface_name ++ ".ActionNotFound";
pub const action_failed_error = interface_name ++ ".ActionFailed";
