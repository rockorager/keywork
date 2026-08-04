//! Internal server-side Wayland foundations.

const std = @import("std");
const wire = @import("wire.zig");

pub const ObjectMap = @import("server/object_map.zig");
pub const Fatal = @import("server/fatal.zig");
pub const Resource = @import("server/Resource.zig");
pub const Client = @import("server/Client.zig");
pub const Server = @import("server/Server.zig");
pub const CoreClient = @import("server/CoreClient.zig");

/// Stable caller-owned server resource specialized to a generated interface.
/// Handler contexts are borrowed and must outlive registration. Request data
/// borrowing the decoded message is valid only for the duration of dispatch.
pub fn TypedResource(comptime ProtocolInterface: type) type {
    return struct {
        const Self = @This();

        runtime: Resource,

        pub fn init(
            allocator: std.mem.Allocator,
            object_id: u32,
            negotiated_version: u32,
            object_origin: ObjectMap.Origin,
            owner: Resource.OwnerHooks,
        ) Self {
            return .{
                .runtime = .init(allocator, object_id, negotiated_version, &ProtocolInterface.interface, &ProtocolInterface.request_messages, object_origin, owner),
            };
        }

        pub fn id(self: *const Self) u32 {
            return self.runtime.id();
        }

        pub fn version(self: *const Self) u32 {
            return self.runtime.version();
        }

        pub fn interface(self: *const Self) *const wire.Interface {
            return self.runtime.interface();
        }

        pub fn origin(self: *const Self) ObjectMap.Origin {
            return self.runtime.origin();
        }

        pub fn state(self: *const Self) Resource.State {
            return self.runtime.state();
        }

        pub fn destroy(self: *Self) void {
            self.runtime.destroy();
        }

        pub fn deinit(self: *Self) void {
            self.runtime.deinit();
        }

        pub fn setHandler(
            self: *Self,
            comptime Context: type,
            context: *Context,
            comptime handler: *const fn (*Self, ProtocolInterface.Request, *Context) anyerror!void,
            comptime destructor: ?*const fn (*Self, *Context) void,
        ) !void {
            try self.runtime.setHandler(Context, context, struct {
                fn dispatch(typed_context: *Context, resource: *Resource, opcode: u16, message: *wire.DecodedMessage) anyerror!void {
                    const typed: *Self = @fieldParentPtr("runtime", resource);
                    const request = try ProtocolInterface.decodeRequest(opcode, message);
                    return handler(typed, request, typed_context);
                }
            }.dispatch, if (destructor) |destroy_typed| struct {
                fn destroy(resource: *Resource, typed_context: *Context) void {
                    const typed: *Self = @fieldParentPtr("runtime", resource);
                    destroy_typed(typed, typed_context);
                }
            }.destroy else null);
        }
    };
}

test {
    _ = ObjectMap;
    _ = Fatal;
    _ = Resource;
    _ = Client;
    _ = Server;
    _ = CoreClient;
    _ = TypedResource;
}
