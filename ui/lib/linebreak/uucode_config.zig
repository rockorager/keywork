const std = @import("std");
const config = @import("config.zig");

pub const LineBreak = enum(u6) {
    ai,
    ak,
    al,
    ap,
    as,
    b2,
    ba,
    bb,
    bk,
    cb,
    cj,
    cl,
    cm,
    cp,
    cr,
    eb,
    em,
    ex,
    gl,
    h2,
    h3,
    hh,
    hl,
    hy,
    id,
    in,
    is,
    jl,
    jt,
    jv,
    lf,
    nl,
    ns,
    nu,
    op,
    po,
    pr,
    qu,
    ri,
    sa,
    sg,
    sp,
    sy,
    vf,
    vi,
    wj,
    xx,
    zw,
    zwj,
};

pub const fields = &config.mergeFields(config.fields, &.{
    .{ .name = "line_break", .type = LineBreak },
});

pub const build_components = &config.mergeComponents(config.build_components, &.{
    .{ .Impl = LineBreakComponent, .fields = &.{"line_break"} },
});
pub const get_components = config.get_components;
pub const tables: []const config.Table = &.{
    .{ .fields = &.{"line_break"} },
    .{ .fields = &.{ "grapheme_break", "general_category", "east_asian_width", "is_extended_pictographic" } },
};

const LineBreakComponent = struct {
    pub fn build(
        comptime InputRow: type,
        comptime Row: type,
        allocator: std.mem.Allocator,
        io: std.Io,
        inputs: config.MultiSlice(InputRow),
        rows: *config.MultiSlice(Row),
        backing: anytype,
        tracking: anytype,
    ) !void {
        _ = allocator;
        _ = io;
        _ = inputs;
        _ = backing;
        _ = tracking;
        var default_row: Row = undefined;
        config.setBuiltField(&default_row, "line_break", .xx);
        rows.len = config.num_code_points;
        rows.*.memset(default_row);

        var lines = std.mem.splitScalar(u8, @embedFile("data/LineBreak.txt"), '\n');
        while (lines.next()) |untrimmed| {
            const line = config.components.trim(untrimmed);
            if (line.len == 0) continue;
            var columns = std.mem.splitScalar(u8, line, ';');
            const range = try config.components.parseRange(std.mem.trim(u8, columns.next().?, " \t"));
            const name = std.mem.trim(u8, columns.next().?, " \t");
            var lower: [3]u8 = undefined;
            for (name, 0..) |c, i| lower[i] = std.ascii.toLower(c);
            const value = std.meta.stringToEnum(LineBreak, lower[0..name.len]) orelse return error.InvalidLineBreak;
            var row = default_row;
            config.setBuiltField(&row, "line_break", value);
            for (range.start..range.end) |cp| rows.*.set(cp, row);
        }
    }
};
