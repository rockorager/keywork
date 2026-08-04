//! Internal server-side Wayland foundations.

pub const ObjectMap = @import("server/object_map.zig");
pub const Fatal = @import("server/fatal.zig");
pub const Resource = @import("server/Resource.zig");

test {
    _ = ObjectMap;
    _ = Fatal;
    _ = Resource;
}
