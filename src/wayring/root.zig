//! Embeddable Zig implementation of the Wayland protocol.
//!
//! The initial public boundary is a transport-independent server foundation.
//! Product policy and event-loop ownership remain with consumers.

pub const wire = @import("wire.zig");
pub const protocol = @import("protocol.zig");
pub const generator = @import("generator.zig");
pub const server = @import("server.zig");
pub const io_uring = @import("io_uring.zig");

test {
    _ = wire;
    _ = protocol;
    _ = generator;
    _ = server;
    _ = io_uring;
}
