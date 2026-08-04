//! Minimal Wayring server whose first client controls its lifetime.

const std = @import("std");
const core = @import("core_protocol");
const wayring = @import("wayring");
const linux = std.os.linux;
const Shm = wayring.server.shm.Protocol(core);

const submission_capacity = 32;
// Every original operation may need a separately routed cancellation CQE.
const route_capacity = submission_capacity * 2;

const Route = struct {
    external: u64,
    token: wayring.io_uring.OperationToken,
};

const App = struct {
    allocator: std.mem.Allocator,
    client: *wayring.server.Client,
    compositors: std.ArrayList(*core.wl_compositor.Resource) = .empty,
    surfaces: std.ArrayList(*core.wl_surface.Resource) = .empty,

    fn deinit(self: *App) void {
        for (self.surfaces.items) |resource| {
            resource.destroy();
            resource.deinit();
            self.allocator.destroy(resource);
        }
        self.surfaces.deinit(self.allocator);
        for (self.compositors.items) |resource| {
            resource.destroy();
            resource.deinit();
            self.allocator.destroy(resource);
        }
        self.compositors.deinit(self.allocator);
    }

    fn bind(client: *wayring.server.Client, id: u32, version: u32, manager: *Manager) !void {
        const self = manager.find(client) orelse return error.UntrackedClient;
        const resource = try self.allocator.create(core.wl_compositor.Resource);
        errdefer self.allocator.destroy(resource);
        resource.* = .init(self.allocator, id, version, .client, client.ownerHooks());
        errdefer {
            resource.destroy();
            resource.deinit();
        }
        try resource.setHandler(App, self, handleCompositor, null);
        try client.materialize(&resource.runtime);
        try self.compositors.append(self.allocator, resource);
    }

    fn handleCompositor(resource: *core.wl_compositor.Resource, request: core.wl_compositor.Request, self: *App) !void {
        switch (request) {
            .create_surface => |value| {
                const surface = try self.allocator.create(core.wl_surface.Resource);
                errdefer self.allocator.destroy(surface);
                surface.* = .init(
                    self.allocator,
                    value.id,
                    @min(resource.version(), core.wl_surface.interface.version),
                    .client,
                    self.client.ownerHooks(),
                );
                errdefer {
                    surface.destroy();
                    surface.deinit();
                }
                try surface.setHandler(App, self, handleSurface, null);
                try self.client.materialize(&surface.runtime);
                try self.surfaces.append(self.allocator, surface);
            },
            .create_region => self.client.postImplementationError(&resource.runtime, "wl_region is not implemented by this example"),
            .release => resource.destroy(),
        }
    }

    fn handleSurface(resource: *core.wl_surface.Resource, request: core.wl_surface.Request, self: *App) !void {
        switch (request) {
            .destroy => resource.destroy(),
            else => self.client.postImplementationError(&resource.runtime, "rendering is not implemented by this example"),
        }
    }
};

const ManagedClient = struct {
    connection: *wayring.io_uring.Connection,
    app: App,
    app_live: bool = true,
    retiring: bool = false,
};

const Manager = struct {
    allocator: std.mem.Allocator,
    shm: *Shm,
    clients: std.ArrayList(*ManagedClient) = .empty,

    fn add(self: *Manager, connection: *wayring.io_uring.Connection) !void {
        const managed = try self.allocator.create(ManagedClient);
        errdefer self.allocator.destroy(managed);
        managed.* = .{
            .connection = connection,
            .app = .{ .allocator = self.allocator, .client = connection.client() },
        };
        try self.clients.append(self.allocator, managed);
    }

    fn find(self: *Manager, client: *wayring.server.Client) ?*App {
        for (self.clients.items) |managed| if (managed.app.client == client) return &managed.app;
        return null;
    }

    fn retire(self: *Manager, connection: *wayring.io_uring.Connection) void {
        for (self.clients.items) |managed| if (managed.connection == connection) {
            managed.retiring = true;
            return;
        };
    }

    fn releaseReady(self: *Manager, transport: *wayring.io_uring.Server, release_all: bool) !void {
        var index: usize = 0;
        while (index < self.clients.items.len) {
            const managed = self.clients.items[index];
            if (!release_all and !managed.retiring) {
                index += 1;
                continue;
            }
            if (managed.app_live) {
                managed.app.deinit();
                self.shm.destroyClientResources(managed.connection.client());
                managed.app_live = false;
            }
            transport.release(managed.connection) catch |err| switch (err) {
                error.OperationInFlight => {
                    index += 1;
                    continue;
                },
                else => return err,
            };
            self.allocator.destroy(managed);
            _ = self.clients.orderedRemove(index);
        }
    }

    fn deinit(self: *Manager) void {
        std.debug.assert(self.clients.items.len == 0);
        self.clients.deinit(self.allocator);
    }
};

fn socketAddress(path: []const u8) !struct { linux.sockaddr.un, linux.socklen_t } {
    var address: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = @splat(0) };
    if (path.len == 0 or path.len >= address.path.len) return error.InvalidSocketPath;
    @memcpy(address.path[0..path.len], path);
    return .{ address, @intCast(@offsetOf(linux.sockaddr.un, "path") + path.len + 1) };
}

fn removeSocketPath(path: [:0]const u8) !void {
    var status: linux.Statx = undefined;
    const stat_result = linux.statx(linux.AT.FDCWD, path.ptr, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &status);
    switch (linux.errno(stat_result)) {
        .NOENT => return,
        .SUCCESS => if (status.mode & linux.S.IFMT != linux.S.IFSOCK) {
            std.log.err("refusing to remove non-socket path '{s}'", .{path});
            return error.SocketPathOccupied;
        },
        else => return error.SocketPathInspectionFailed,
    }
    const result = linux.unlink(path.ptr);
    switch (linux.errno(result)) {
        .SUCCESS, .NOENT => {},
        else => |err| {
            std.log.err("cannot remove socket path '{s}': {s}", .{ path, @tagName(err) });
            return error.UnlinkFailed;
        },
    }
}

fn stopWith(failure: *?anyerror, transport: *wayring.io_uring.Server, err: anyerror) void {
    if (failure.* == null) failure.* = err;
    transport.beginShutdown();
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    const executable_name = args.next() orelse "wayring-example";
    const path = args.next() orelse {
        std.log.err("usage: {s} /absolute/path/to/wayland-socket", .{executable_name});
        return error.InvalidArguments;
    };
    if (args.next() != null or !std.fs.path.isAbsolute(path)) {
        std.log.err("usage: {s} /absolute/path/to/wayland-socket", .{executable_name});
        return error.InvalidArguments;
    }
    const address, const address_len = try socketAddress(path);
    const socket_path = try allocator.dupeZ(u8, path);
    defer allocator.free(socket_path);
    // This is an explicit example-only path, so replacing a stale socket is intentional.
    try removeSocketPath(socket_path);
    defer removeSocketPath(socket_path) catch {};

    const raw_listener = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(raw_listener) != .SUCCESS) return error.SocketFailed;
    const listener: linux.fd_t = @intCast(raw_listener);
    var listener_owned = true;
    defer if (listener_owned) {
        _ = linux.close(listener);
    };
    if (linux.errno(linux.bind(listener, @ptrCast(&address), address_len)) != .SUCCESS) return error.BindFailed;
    if (linux.errno(linux.listen(listener, 8)) != .SUCCESS) return error.ListenFailed;

    var protocol_server: wayring.server.Server = .init(allocator);
    defer protocol_server.deinit();
    var shm: Shm = .init(allocator);
    defer shm.deinit();
    _ = try shm.publish(&protocol_server, core.wl_shm.interface.version);
    var manager: Manager = .{ .allocator = allocator, .shm = &shm };
    defer manager.deinit();
    _ = try protocol_server.addGlobal(core.wl_compositor, core.wl_compositor.interface.version, Manager, &manager, App.bind);

    var transport = try wayring.io_uring.Server.init(allocator, &protocol_server, listener);
    listener_owned = false;
    defer transport.deinit() catch |err| std.log.err("transport cleanup failed: {s}", .{@errorName(err)});
    var ring = try linux.IoUring.init(submission_capacity, 0);
    defer ring.deinit();

    var routes: [route_capacity]Route = undefined;
    var route_count: usize = 0;
    var next_external: u64 = 1;
    var first_client: ?*wayring.io_uring.Connection = null;
    var shutting_down = false;
    var failure: ?anyerror = null;
    var cqes: [route_capacity]linux.io_uring_cqe = undefined;

    event_loop: while (true) {
        const route_limit = if (shutting_down) routes.len else submission_capacity;
        while (route_count < route_limit) {
            const prepared = transport.prepareNext(&ring, next_external) catch |err| {
                stopWith(&failure, &transport, err);
                shutting_down = true;
                break;
            };
            switch (prepared) {
                .prepared => |token| {
                    // Install before submit: a submit error leaves this route intact.
                    routes[route_count] = .{ .external = next_external, .token = token };
                    route_count += 1;
                    next_external +%= 1;
                    if (next_external == 0) {
                        stopWith(&failure, &transport, error.ExternalUserDataExhausted);
                        shutting_down = true;
                        break;
                    }
                },
                .idle, .submission_queue_full => break,
            }
        }
        while (ring.sq_ready() != 0) {
            _ = ring.submit() catch |err| {
                stopWith(&failure, &transport, err);
                shutting_down = true;
                continue :event_loop;
            };
        }
        if (route_count == 0) {
            if (shutting_down and transport.isDrained()) break;
            stopWith(&failure, &transport, error.TransportBecameIdle);
            shutting_down = true;
            continue;
        }
        const count = ring.copy_cqes(&cqes, 1) catch |err| {
            stopWith(&failure, &transport, err);
            shutting_down = true;
            continue;
        };
        for (cqes[0..count]) |cqe| {
            var index: ?usize = null;
            for (routes[0..route_count], 0..) |route, candidate| if (route.external == cqe.user_data) {
                index = candidate;
                break;
            };
            const found = index orelse return error.UnknownCompletion;
            const token = routes[found].token;
            routes[found] = routes[route_count - 1];
            route_count -= 1;
            const completed = transport.complete(token, cqe.res, cqe.flags) catch |err| {
                stopWith(&failure, &transport, err);
                shutting_down = true;
                continue;
            };
            switch (completed) {
                .accepted => |connection| {
                    if (first_client == null) first_client = connection;
                    manager.add(connection) catch |err| {
                        transport.release(connection) catch |release_err| {
                            stopWith(&failure, &transport, release_err);
                        };
                        stopWith(&failure, &transport, err);
                        shutting_down = true;
                    };
                },
                .peer_disconnected => |connection| {
                    manager.retire(connection);
                    if (connection == first_client) {
                        transport.beginShutdown();
                        shutting_down = true;
                    }
                },
                // A send may already be in flight, in which case the output
                // query is intentionally false. Wait for `.sent`; the final
                // terminal-frame completion is the unambiguous drain edge.
                .terminal => {},
                .sent => |connection| if (connection.state() == .terminal and !connection.client().hasPendingOutput()) {
                    manager.retire(connection);
                    if (connection == first_client) {
                        transport.beginShutdown();
                        shutting_down = true;
                    }
                },
                .listener_error => |err| {
                    std.log.err("listener failed: {s}", .{@tagName(err)});
                    stopWith(&failure, &transport, error.ListenerFailed);
                    shutting_down = true;
                },
                .received, .cancellation, .retry => {},
            }
        }

        try manager.releaseReady(&transport, shutting_down);
        if (shutting_down and transport.isDrained() and route_count == 0 and manager.clients.items.len == 0) break;
    }
    if (failure) |err| return err;
}
