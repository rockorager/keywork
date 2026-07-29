//! Native Keywork application runtime facade.

pub const BackendKind = @import("app/options.zig").BackendKind;

const wayland_options = @import("backend/wayland/options.zig");
pub const LayerShellOptions = wayland_options.LayerShellOptions;
pub const Decorations = wayland_options.Decorations;

const runner = @import("app/runner.zig");
pub const run = runner.run;
pub const RunOptions = runner.Options;

pub const HostBindings = @import("app/HostBindings.zig");

const windows = @import("app/windows.zig");
pub const WindowsHost = windows.WindowsHost;
pub const WindowsContext = windows.WindowsContext;
pub const WindowDeclaration = windows.WindowDeclaration;

const platform = @import("app/platform.zig");
pub const Platform = platform.Platform;
pub const resizeEdgeFromName = platform.resizeEdgeFromName;

pub const MemoryBackend = @import("backend/memory.zig");
pub const LogBackend = @import("backend/log.zig").LogBackend;

pub const svgIcon = @import("graphics/svg_icon.zig").icon;

const icon_theme = @import("linux/icon_theme.zig");
pub const IconThemeCache = icon_theme.Cache;
pub const lookupIconSizedPreferred = icon_theme.lookupIconSizedPreferred;

pub const SystemdEvent = @import("linux/SystemdEvent.zig");

const syscall = @import("linux/syscall.zig");
pub const linux = struct {
    pub const fd = syscall.fd;
    pub const check = syscall.check;
    pub const setNonblocking = syscall.setNonblocking;
    pub const readAllAlloc = syscall.readAllAlloc;
};

test {
    _ = @import("app/runner.zig");
    _ = @import("app/HostBindings.zig");
    _ = @import("backend/memory.zig");
    _ = @import("backend/wayland/input.zig");
    _ = @import("backend/wayland/shm.zig");
    _ = @import("backend/wayland/vulkan/renderer.zig");
    _ = @import("backend/wayland/window.zig");
    _ = @import("graphics/raster.zig");
    _ = @import("graphics/svg_icon.zig");
    _ = @import("app/platform.zig");
    _ = @import("linux/SystemdEvent.zig");
    _ = @import("linux/icon_theme.zig");
}
