//! Damage history and stale-buffer repair for CPU-rendered shared-memory frames.

const ShmFrameHistory = @This();

const std = @import("std");
const builtin = @import("builtin");
const keywork = @import("keywork-ui");
const raster = @import("raster.zig");
const TextRenderer = @import("text.zig");

entries: [capacity]Entry = undefined,
len: usize = 0,
width: u31 = 0,
height: u31 = 0,

/// More frames than a compositor plausibly holds buffers for; normal
/// double/triple buffering stays well under this.
pub const capacity = 8;

pub const PixelRegion = struct {
    clips: [keywork.DamageRegion.max_rects]TextRenderer.PixelClip = undefined,
    len: u8 = 0,

    pub fn slice(self: *const PixelRegion) []const TextRenderer.PixelClip {
        return self.clips[0..self.len];
    }

    pub fn add(self: *PixelRegion, clip: TextRenderer.PixelClip) void {
        if (clip.x0 >= clip.x1 or clip.y0 >= clip.y1) return;
        var merged = clip;
        var index: usize = 0;
        while (index < self.len) {
            const current = self.clips[index];
            if (!clipsOverlapOrTouch(current, merged)) {
                index += 1;
                continue;
            }
            merged = unionClips(current, merged);
            self.len -= 1;
            self.clips[index] = self.clips[self.len];
            index = 0;
        }
        if (self.len < self.clips.len) {
            self.clips[self.len] = merged;
            self.len += 1;
            return;
        }
        var collapsed = merged;
        for (self.slice()) |current| collapsed = unionClips(collapsed, current);
        self.clips[0] = collapsed;
        self.len = 1;
    }

    pub fn bounds(self: *const PixelRegion) ?TextRenderer.PixelClip {
        if (self.len == 0) return null;
        var result = self.clips[0];
        for (self.slice()[1..]) |clip| result = unionClips(result, clip);
        return result;
    }

    pub fn contains(self: *const PixelRegion, clip: TextRenderer.PixelClip) bool {
        for (self.slice()) |current| {
            if (clipContains(current, clip)) return true;
        }
        return false;
    }
};

pub const Entry = struct {
    frame: u64,
    region: PixelRegion,
};

pub fn record(self: *ShmFrameHistory, frame: u64, width: u31, height: u31, region: PixelRegion) void {
    if (self.width != width or self.height != height) {
        self.len = 0;
        self.width = width;
        self.height = height;
    }
    std.debug.assert(self.len == 0 or frame == self.entries[0].frame + 1);
    const count = @min(self.len + 1, capacity);
    var index = count - 1;
    while (index > 0) : (index -= 1) self.entries[index] = self.entries[index - 1];
    self.entries[0] = .{ .frame = frame, .region = region };
    self.len = count;
}

/// Whether history covers every frame committed after `buffer_frame`, so a
/// stale buffer can be repaired from damage records alone.
pub fn canRepair(self: *const ShmFrameHistory, buffer_frame: u64, width: u31, height: u31) bool {
    if (buffer_frame == 0) return false;
    if (self.len == 0 or self.width != width or self.height != height) return false;
    return self.entries[self.len - 1].frame <= buffer_frame + 1;
}

/// Copy regions damaged after `buffer_frame` from `src` into `dst`, skipping
/// regions the current frame repaints. Entries must be ordered newest first.
pub fn repairRegions(
    dst: []u32,
    src: []const u32,
    width: u31,
    height: u31,
    entries_value: []const Entry,
    buffer_frame: u64,
    repaint: PixelRegion,
) void {
    for (entries_value) |entry| {
        if (entry.frame <= buffer_frame) break;
        for (entry.region.slice()) |clip| {
            if (repaint.contains(clip)) continue;
            copyRegion(dst, src, width, height, clip);
        }
    }
}

fn clipsOverlapOrTouch(a: TextRenderer.PixelClip, b: TextRenderer.PixelClip) bool {
    return a.x0 < b.x1 and b.x0 < a.x1 and a.y0 < b.y1 and b.y0 < a.y1;
}

fn unionClips(a: TextRenderer.PixelClip, b: TextRenderer.PixelClip) TextRenderer.PixelClip {
    return .{
        .x0 = @min(a.x0, b.x0),
        .y0 = @min(a.y0, b.y0),
        .x1 = @max(a.x1, b.x1),
        .y1 = @max(a.y1, b.y1),
    };
}

fn clipContains(outer: TextRenderer.PixelClip, inner: TextRenderer.PixelClip) bool {
    return outer.x0 <= inner.x0 and outer.y0 <= inner.y0 and
        outer.x1 >= inner.x1 and outer.y1 >= inner.y1;
}

/// Copy one clip between equally sized frames. Full-width regions collapse
/// into one contiguous copy so large repairs can use non-temporal stores.
fn copyRegion(noalias dst: []u32, noalias src: []const u32, width: u31, height: u31, clip: TextRenderer.PixelClip) void {
    const x0 = raster.clampClip(clip.x0, width);
    const x1 = raster.clampClip(clip.x1, width);
    const y0 = raster.clampClip(clip.y0, height);
    const y1 = raster.clampClip(clip.y1, height);
    if (x0 >= x1 or y0 >= y1) return;
    if (x0 == 0 and x1 == width) {
        copyPixels(dst[y0 * width .. y1 * width], src[y0 * width .. y1 * width]);
        return;
    }
    var y = y0;
    while (y < y1) : (y += 1) {
        @memcpy(dst[y * width ..][x0..x1], src[y * width ..][x0..x1]);
    }
}

/// Copy pixels into memory the CPU will not read back. Large copies use
/// non-temporal stores on x86_64 to avoid read-for-ownership traffic and
/// evicting the render working set.
pub fn copyPixels(noalias dst: []u32, noalias src: []const u32) void {
    std.debug.assert(dst.len == src.len);
    const nt_threshold = 256 * 1024 / @sizeOf(u32);
    if (comptime builtin.cpu.arch == .x86_64 and builtin.zig_backend == .stage2_llvm) {
        if (dst.len >= nt_threshold) return copyNonTemporal(dst, src);
    }
    @memcpy(dst, src);
}

fn copyNonTemporal(noalias dst: []u32, noalias src: []const u32) void {
    var d: [*]u8 = @ptrCast(dst.ptr);
    var s: [*]const u8 = @ptrCast(src.ptr);
    var n: usize = dst.len * @sizeOf(u32);

    const misalign = @intFromPtr(d) & 15;
    if (misalign != 0) {
        const head = @min(16 - misalign, n);
        @memcpy(d[0..head], s[0..head]);
        d += head;
        s += head;
        n -= head;
    }
    while (n >= 64) {
        asm volatile (
            \\movdqu  (%%rsi), %%xmm0
            \\movdqu 16(%%rsi), %%xmm1
            \\movdqu 32(%%rsi), %%xmm2
            \\movdqu 48(%%rsi), %%xmm3
            \\movntdq %%xmm0,  (%%rdi)
            \\movntdq %%xmm1, 16(%%rdi)
            \\movntdq %%xmm2, 32(%%rdi)
            \\movntdq %%xmm3, 48(%%rdi)
            :
            : [s] "{rsi}" (s),
              [d] "{rdi}" (d),
            : .{ .xmm0 = true, .xmm1 = true, .xmm2 = true, .xmm3 = true, .memory = true });
        d += 64;
        s += 64;
        n -= 64;
    }
    if (n != 0) @memcpy(d[0..n], s[0..n]);
    asm volatile ("sfence" ::: .{ .memory = true });
}

test "damage history covers only retained consecutive frames" {
    var history: ShmFrameHistory = .{};
    try std.testing.expect(!history.canRepair(1, 4, 4));

    var frame: u64 = 1;
    while (frame <= 10) : (frame += 1) {
        var region: PixelRegion = .{};
        region.add(.{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1 });
        history.record(frame, 4, 4, region);
    }
    try std.testing.expectEqual(@as(usize, capacity), history.len);
    try std.testing.expect(history.canRepair(9, 4, 4));
    try std.testing.expect(history.canRepair(2, 4, 4));
    try std.testing.expect(!history.canRepair(1, 4, 4));
    try std.testing.expect(!history.canRepair(0, 4, 4));
    try std.testing.expect(!history.canRepair(9, 8, 4));
}

test "damage history resets when the frame size changes" {
    var history: ShmFrameHistory = .{};
    var first: PixelRegion = .{};
    first.add(.{ .x0 = 0, .y0 = 0, .x1 = 4, .y1 = 4 });
    history.record(1, 4, 4, first);
    var second: PixelRegion = .{};
    second.add(.{ .x0 = 0, .y0 = 0, .x1 = 8, .y1 = 8 });
    history.record(2, 8, 8, second);
    try std.testing.expectEqual(@as(usize, 1), history.len);
    try std.testing.expect(!history.canRepair(2, 4, 4));
    try std.testing.expect(history.canRepair(2, 8, 8));
}

test "stale buffer repair copies only interim damage" {
    const width: u31 = 4;
    const height: u31 = 4;
    var src: [width * height]u32 = undefined;
    for (&src, 0..) |*pixel, index| pixel.* = @intCast(index + 100);
    var dst: [width * height]u32 = @splat(0);

    var bottom: PixelRegion = .{};
    bottom.add(.{ .x0 = 0, .y0 = 3, .x1 = 4, .y1 = 4 });
    var middle: PixelRegion = .{};
    middle.add(.{ .x0 = 1, .y0 = 1, .x1 = 3, .y1 = 2 });
    var top: PixelRegion = .{};
    top.add(.{ .x0 = 0, .y0 = 0, .x1 = 4, .y1 = 1 });
    const entries_value = [_]Entry{
        .{ .frame = 5, .region = bottom },
        .{ .frame = 4, .region = middle },
        .{ .frame = 3, .region = top },
    };
    repairRegions(&dst, &src, width, height, &entries_value, 3, bottom);

    const expected = [width * height]u32{
        0, 0,   0,   0,
        0, 105, 106, 0,
        0, 0,   0,   0,
        0, 0,   0,   0,
    };
    try std.testing.expectEqualSlices(u32, &expected, &dst);
}

test "stale buffer repair does not mistake a damage bounding box for its region" {
    const width: u31 = 5;
    const height: u31 = 1;
    const src = [width * height]u32{ 10, 11, 12, 13, 14 };
    var dst: [width * height]u32 = @splat(0);

    var historical: PixelRegion = .{};
    historical.add(.{ .x0 = 2, .y0 = 0, .x1 = 3, .y1 = 1 });
    const entries_value = [_]Entry{.{ .frame = 2, .region = historical }};
    var repaint: PixelRegion = .{};
    repaint.add(.{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1 });
    repaint.add(.{ .x0 = 4, .y0 = 0, .x1 = 5, .y1 = 1 });

    repairRegions(&dst, &src, width, height, &entries_value, 1, repaint);
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 12, 0, 0 }, &dst);
}

test "copyRegion clamps out-of-bounds clips" {
    const width: u31 = 2;
    const height: u31 = 2;
    const src = [width * height]u32{ 1, 2, 3, 4 };
    var dst: [width * height]u32 = @splat(0);
    copyRegion(&dst, &src, width, height, .{ .x0 = -5, .y0 = -5, .x1 = 10, .y1 = 10 });
    try std.testing.expectEqualSlices(u32, &src, &dst);

    var untouched: [width * height]u32 = @splat(0);
    copyRegion(&untouched, &src, width, height, .{ .x0 = 2, .y0 = 0, .x1 = 2, .y1 = 2 });
    try std.testing.expectEqualSlices(u32, &[_]u32{ 0, 0, 0, 0 }, &untouched);
}

test "copyPixels matches the source above the non-temporal threshold" {
    const allocator = std.testing.allocator;
    const len = 256 * 1024 / @sizeOf(u32) + 13;
    const src_storage = try allocator.alloc(u32, len + 1);
    defer allocator.free(src_storage);
    const dst_storage = try allocator.alloc(u32, len + 1);
    defer allocator.free(dst_storage);

    var prng: std.Random.DefaultPrng = .init(0x6b657977);
    const random = prng.random();
    for (src_storage) |*pixel| pixel.* = random.int(u32);

    const src = src_storage[1..];
    const dst = dst_storage[1..];
    copyPixels(dst, src);
    try std.testing.expectEqualSlices(u32, src, dst);
}
