//! Embeddable Zig implementation of the Wayland protocol.
//!
//! The initial public boundary is a transport-independent server foundation.
//! Product policy and event-loop ownership remain with consumers.

pub const wire = @import("wire.zig");

test {
    _ = wire;
}
