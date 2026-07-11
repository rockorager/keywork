//! Textual expansion of SVG `<use>` elements.
//!
//! nanosvg silently drops `<use>`, but icon SVGs authored in Inkscape
//! lean on it for repeated shapes: GNOME's Files icon draws one drawer
//! handle and clones the other two with `<use xlink:href="#id">`.
//! Rewriting each use into a `<g transform>` wrapping a copy of the
//! referenced element before parsing keeps those shapes without
//! patching the vendored rasterizer.
//!
//! The rewrite is deliberately text-level: icon documents are small
//! and well-formed enough that quote-aware scanning beats pulling in
//! an XML parser. Anything the scanner can't resolve is left in place,
//! which parses exactly as it would have without expansion.

const std = @import("std");

/// Bounds nested use-of-use chains and, together with
/// `max_output_bytes`, runaway self-referential clones.
const max_passes = 4;
/// A pass whose output exceeds this aborts expansion; callers fall
/// back to the unexpanded document.
const max_output_bytes = 4 * 1024 * 1024;

/// Byte range of an element, from its `<` to one past its final `>`.
/// `tag_end` is one past the start tag's `>`, so `[start, tag_end)`
/// covers the attributes.
const Span = struct {
    start: usize,
    tag_end: usize,
    end: usize,
};

/// Returns the document with every resolvable `<use>` replaced by an
/// inline clone of its target, or null when nothing was expanded and
/// the input can be parsed as-is. Unresolvable uses stay in place;
/// nanosvg ignores them.
pub fn expandUses(allocator: std.mem.Allocator, svg: []const u8) error{ OutOfMemory, SvgTooLarge }!?[]u8 {
    var current = try expandOnce(allocator, svg) orelse return null;
    errdefer allocator.free(current);
    var pass: usize = 1;
    while (pass < max_passes and std.mem.indexOf(u8, current, "<use") != null) : (pass += 1) {
        const next = try expandOnce(allocator, current) orelse break;
        allocator.free(current);
        current = next;
    }
    return current;
}

/// One expansion pass over the document; returns null when it made no
/// replacement. Uses cloned by an earlier pass may themselves contain
/// uses, which the next pass picks up.
fn expandOnce(allocator: std.mem.Allocator, svg: []const u8) error{ OutOfMemory, SvgTooLarge }!?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var replaced = false;
    var index: usize = 0;
    while (findUseStart(svg, index)) |use_start| {
        const use = elementSpan(svg, use_start) orelse break;
        try out.appendSlice(allocator, svg[index..use_start]);
        if (try appendClone(allocator, &out, svg, use)) {
            replaced = true;
        } else {
            try out.appendSlice(allocator, svg[use_start..use.end]);
        }
        if (out.items.len > max_output_bytes) return error.SvgTooLarge;
        index = use.end;
    }
    if (!replaced) return null;
    try out.appendSlice(allocator, svg[index..]);
    return try out.toOwnedSlice(allocator);
}

/// Appends the use's replacement: its target wrapped in a `<g>` that
/// carries the use's transform and x/y translate. Returns false when
/// the reference can't be resolved safely.
fn appendClone(allocator: std.mem.Allocator, out: *std.ArrayList(u8), svg: []const u8, use: Span) error{OutOfMemory}!bool {
    const tag = svg[use.start..use.tag_end];
    const href = attrValue(tag, "xlink:href") orelse attrValue(tag, "href") orelse return false;
    if (href.len < 2 or href[0] != '#') return false;
    const target = findElementById(svg, href[1..]) orelse return false;
    // A target enclosing its own use would clone itself forever.
    if (target.start <= use.start and use.end <= target.end) return false;

    const x = attrFloat(tag, "x") orelse 0;
    const y = attrFloat(tag, "y") orelse 0;
    const transform = attrValue(tag, "transform");

    try out.appendSlice(allocator, "<g");
    if (transform != null or x != 0 or y != 0) {
        // Per the SVG spec a use renders its target inside the use's
        // transform, then translate(x, y) — in that order.
        try out.appendSlice(allocator, " transform=\"");
        if (transform) |value| try out.appendSlice(allocator, value);
        if (x != 0 or y != 0) {
            if (transform != null) try out.append(allocator, ' ');
            const translate = try std.fmt.allocPrint(allocator, "translate({d} {d})", .{ x, y });
            defer allocator.free(translate);
            try out.appendSlice(allocator, translate);
        }
        try out.append(allocator, '"');
    }
    try out.append(allocator, '>');
    try out.appendSlice(allocator, svg[target.start..target.end]);
    try out.appendSlice(allocator, "</g>");
    return true;
}

/// Finds the next `<use` that begins a use element (and not, say,
/// `<useless>`), at or after `from`.
fn findUseStart(svg: []const u8, from: usize) ?usize {
    var i = from;
    while (std.mem.indexOfPos(u8, svg, i, "<use")) |pos| {
        const after = pos + "<use".len;
        if (after < svg.len and (std.ascii.isWhitespace(svg[after]) or svg[after] == '/' or svg[after] == '>')) return pos;
        i = after;
    }
    return null;
}

/// Measures the element starting at `start` (which must point at `<`),
/// including its whole subtree when it isn't self-closing. Returns
/// null on malformed input.
fn elementSpan(svg: []const u8, start: usize) ?Span {
    const name = tagName(svg, start) orelse return null;
    const gt = findTagEnd(svg, start) orelse return null;
    if (svg[gt - 1] == '/') return .{ .start = start, .tag_end = gt + 1, .end = gt + 1 };

    var depth: usize = 1;
    var i = gt + 1;
    while (std.mem.indexOfScalarPos(u8, svg, i, '<')) |lt| {
        if (std.mem.startsWith(u8, svg[lt..], "<!--")) {
            i = (std.mem.indexOfPos(u8, svg, lt + 4, "-->") orelse return null) + 3;
            continue;
        }
        if (lt + 1 < svg.len and svg[lt + 1] == '/') {
            if (matchesName(svg, lt + 2, name)) {
                const close_gt = std.mem.indexOfScalarPos(u8, svg, lt + 2, '>') orelse return null;
                depth -= 1;
                if (depth == 0) return .{ .start = start, .tag_end = gt + 1, .end = close_gt + 1 };
                i = close_gt + 1;
                continue;
            }
            i = lt + 2;
            continue;
        }
        if (matchesName(svg, lt + 1, name)) {
            const nested_gt = findTagEnd(svg, lt) orelse return null;
            if (svg[nested_gt - 1] != '/') depth += 1;
            i = nested_gt + 1;
            continue;
        }
        i = lt + 1;
    }
    return null;
}

/// Finds the element carrying `id="<id>"` anywhere in the document.
fn findElementById(svg: []const u8, id: []const u8) ?Span {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, svg, i, "id=")) |pos| {
        i = pos + "id=".len;
        if (pos == 0 or !std.ascii.isWhitespace(svg[pos - 1])) continue;
        if (i >= svg.len or (svg[i] != '"' and svg[i] != '\'')) continue;
        const quote = svg[i];
        const value_start = i + 1;
        const value_end = std.mem.indexOfScalarPos(u8, svg, value_start, quote) orelse return null;
        i = value_end + 1;
        if (!std.mem.eql(u8, svg[value_start..value_end], id)) continue;
        // The id must sit inside a start tag, not in text content.
        const lt = std.mem.lastIndexOfScalar(u8, svg[0..pos], '<') orelse continue;
        if (!isNameChar(svg[lt + 1])) continue;
        const gt = findTagEnd(svg, lt) orelse continue;
        if (gt < pos) continue;
        return elementSpan(svg, lt);
    }
    return null;
}

/// Extracts an attribute value from a start tag's text, matching whole
/// attribute names only (so `href` never matches inside `xlink:href`).
fn attrValue(tag: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, tag, i, name)) |pos| {
        i = pos + name.len;
        if (pos == 0 or !std.ascii.isWhitespace(tag[pos - 1])) continue;
        var j = i;
        while (j < tag.len and std.ascii.isWhitespace(tag[j])) : (j += 1) {}
        if (j >= tag.len or tag[j] != '=') continue;
        j += 1;
        while (j < tag.len and std.ascii.isWhitespace(tag[j])) : (j += 1) {}
        if (j >= tag.len or (tag[j] != '"' and tag[j] != '\'')) continue;
        const quote = tag[j];
        const value_start = j + 1;
        const value_end = std.mem.indexOfScalarPos(u8, tag, value_start, quote) orelse return null;
        return tag[value_start..value_end];
    }
    return null;
}

fn attrFloat(tag: []const u8, name: []const u8) ?f32 {
    var value = std.mem.trim(u8, attrValue(tag, name) orelse return null, " \t");
    if (std.mem.endsWith(u8, value, "px")) value = value[0 .. value.len - 2];
    return std.fmt.parseFloat(f32, value) catch null;
}

/// Index of the start tag's closing `>`, skipping quoted attribute
/// values that may contain one.
fn findTagEnd(svg: []const u8, start: usize) ?usize {
    var quote: u8 = 0;
    var i = start;
    while (i < svg.len) : (i += 1) {
        const ch = svg[i];
        if (quote != 0) {
            if (ch == quote) quote = 0;
        } else if (ch == '"' or ch == '\'') {
            quote = ch;
        } else if (ch == '>') {
            return i;
        }
    }
    return null;
}

fn tagName(svg: []const u8, start: usize) ?[]const u8 {
    var i = start + 1;
    while (i < svg.len and isNameChar(svg[i])) : (i += 1) {}
    if (i == start + 1) return null;
    return svg[start + 1 .. i];
}

fn matchesName(svg: []const u8, pos: usize, name: []const u8) bool {
    if (pos + name.len > svg.len or !std.mem.eql(u8, svg[pos .. pos + name.len], name)) return false;
    const after = pos + name.len;
    return after >= svg.len or std.ascii.isWhitespace(svg[after]) or svg[after] == '/' or svg[after] == '>';
}

fn isNameChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == ':' or ch == '-' or ch == '_' or ch == '.';
}

test "documents without use pass through untouched" {
    try std.testing.expect(try expandUses(std.testing.allocator, "<svg><rect id=\"r\"/></svg>") == null);
}

test "use clones its target with transform and translate" {
    // The GNOME Files icon shape: one real handle, two use clones.
    const expanded = (try expandUses(std.testing.allocator,
        \\<svg><g id="g1"><rect width="4"/></g>
        \\<use x="0" y="0" xlink:href="#g1" transform="translate(0,32)" width="100%" height="100%" />
        \\<use height="100%" width="100%" transform="translate(0,64)" id="u2" xlink:href="#g1" y="0" x="0" /></svg>
    )).?;
    defer std.testing.allocator.free(expanded);

    try std.testing.expect(std.mem.indexOf(u8, expanded, "<use") == null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "<g transform=\"translate(0,32)\"><g id=\"g1\"><rect width=\"4\"/></g></g>") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "<g transform=\"translate(0,64)\"><g id=\"g1\"><rect width=\"4\"/></g></g>") != null);
}

test "use x and y become a translate after the transform" {
    const expanded = (try expandUses(std.testing.allocator,
        \\<svg><rect id="r" width="4"/><use href="#r" x="10" y="-2.5" transform="scale(2)"/></svg>
    )).?;
    defer std.testing.allocator.free(expanded);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "<g transform=\"scale(2) translate(10 -2.5)\"><rect id=\"r\" width=\"4\"/></g>") != null);
}

test "use without transform or offset clones inside a bare group" {
    const expanded = (try expandUses(std.testing.allocator,
        \\<svg><rect id="r" width="4"/><use href="#r"/></svg>
    )).?;
    defer std.testing.allocator.free(expanded);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "<g><rect id=\"r\" width=\"4\"/></g>") != null);
}

test "nested same-name elements keep the target subtree intact" {
    const expanded = (try expandUses(std.testing.allocator,
        \\<svg><g id="outer"><g><rect/></g><circle/></g><use href="#outer" x="1"/></svg>
    )).?;
    defer std.testing.allocator.free(expanded);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "<g transform=\"translate(1 0)\"><g id=\"outer\"><g><rect/></g><circle/></g></g>") != null);
}

test "use of a use resolves across passes" {
    const expanded = (try expandUses(std.testing.allocator,
        \\<svg><rect id="r"/><g id="pair"><use href="#r" x="8"/></g><use href="#pair" y="16"/></svg>
    )).?;
    defer std.testing.allocator.free(expanded);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "<use") == null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "translate(0 16)") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "translate(8 0)") != null);
}

test "unresolvable and self-referential uses stay in place" {
    // Unknown target: left verbatim (nanosvg ignores it), so no
    // replacement happens and the document reports no change.
    try std.testing.expect(try expandUses(std.testing.allocator, "<svg><use href=\"#missing\"/></svg>") == null);
    try std.testing.expect(try expandUses(std.testing.allocator, "<svg><use href=\"nofragment\"/></svg>") == null);
    // A use inside its own target must not clone itself forever.
    try std.testing.expect(try expandUses(std.testing.allocator, "<svg><g id=\"loop\"><use href=\"#loop\"/></g></svg>") == null);
}

test "id in text content is not a target" {
    try std.testing.expect(try expandUses(std.testing.allocator, "<svg><text>has id=\"t\" inside</text><use href=\"#t\"/></svg>") == null);
}
