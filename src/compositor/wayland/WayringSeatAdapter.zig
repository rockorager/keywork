//! Resource-free generated seat adapter boundary.
//!
//! Wave 2 installs this sink only for canonical owner/input/serial queries.
//! Event callbacks intentionally publish no protocol resources and deliver no
//! pointer, keyboard, or touch events.

const WayringSeatAdapter = @This();

const ClientRegistry = @import("../ClientRegistry.zig");
const SeatDelivery = @import("../SeatDelivery.zig");
const SurfaceRegistry = @import("../SurfaceRegistry.zig");
const WayringClients = @import("WayringClients.zig");
const WayringCompositor = @import("WayringCompositor.zig");
const wayring = @import("wayring");

protocol_server: *wayring.server.Server,
clients: *WayringClients,
compositor: *WayringCompositor,

pub fn init(
    protocol_server: *wayring.server.Server,
    clients: *WayringClients,
    compositor: *WayringCompositor,
) WayringSeatAdapter {
    return .{
        .protocol_server = protocol_server,
        .clients = clients,
        .compositor = compositor,
    };
}

pub fn sink(self: *WayringSeatAdapter) SeatDelivery.Sink {
    return .{
        .context = self,
        .owner_for_surface = ownerForSurface,
        .surface_accepts_input = surfaceAcceptsInput,
        .issue_serial = issueSerial,
        .touch_target = touchTarget,
        .capabilities = capabilities,
        .keyboard_state = keyboardState,
        .keyboard = keyboard,
        .pointer = pointer,
        .touch = touch,
    };
}

fn ownerForSurface(
    context: *anyopaque,
    surface: SurfaceRegistry.Id,
) ?ClientRegistry.Id {
    const self: *WayringSeatAdapter = @ptrCast(@alignCast(context));
    return self.compositor.ownerForSurface(self.clients, surface);
}

fn surfaceAcceptsInput(
    context: *anyopaque,
    surface: SurfaceRegistry.Id,
    x: f64,
    y: f64,
) bool {
    const self: *WayringSeatAdapter = @ptrCast(@alignCast(context));
    return self.compositor.surfaceAcceptsInput(surface, x, y);
}

fn issueSerial(
    context: *anyopaque,
    client: ClientRegistry.Id,
) ?ClientRegistry.Serial {
    const self: *WayringSeatAdapter = @ptrCast(@alignCast(context));
    if (!self.clients.contains(client)) return null;
    const value = self.protocol_server.nextSerial() catch return null;
    return .{ .domain = .wayring_server, .value = value };
}

fn touchTarget(_: *anyopaque, _: SurfaceRegistry.Id) ?SeatDelivery.TouchTarget {
    return null;
}

fn capabilities(_: *anyopaque, _: SeatDelivery.CapabilitySnapshot) void {}
fn keyboardState(_: *anyopaque, _: SeatDelivery.KeyboardStateEvent) void {}
fn keyboard(
    _: *anyopaque,
    _: ClientRegistry.Id,
    _: SurfaceRegistry.Id,
    _: SeatDelivery.KeyboardEvent,
) void {}
fn pointer(
    _: *anyopaque,
    _: ClientRegistry.Id,
    _: SurfaceRegistry.Id,
    _: SeatDelivery.PointerEvent,
) void {}
fn touch(_: *anyopaque, _: ClientRegistry.Id, _: SeatDelivery.TouchEvent) void {}
