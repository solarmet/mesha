//! The Animate timeline: the clip spread across the panel's width, or a zoomed span of it, a
//! ruler to scrub along, a Keys lane of exposure blocks (a key's diamond, its easing, and a
//! grip at its end that sets its hold), and a lane for each property that changes between the
//! clip's keys: a bone channel, an IK target, or a value a pose gives the definition (see
//! `figure/properties.zig`). Ctrl and the wheel zoom it at the pointer, Shift and the wheel
//! move it along the clip, and a zoomed timeline pages along with the playhead in playback.
//!
//! Keys closer together than a diamond share one diamond, and exposure blocks too narrow for a
//! grip draw as one run, so a long clip draws a mark per few pixels and not one per key.
//!
//! A lane's diamond is filled at a key that changes the value from the key before, hollow at
//! one that keeps it, and a bar runs between keys while the value moves. Hovering a diamond
//! shows what changes there: the value before and after, between which frames, and how.
//!
//! This file builds the lanes from a definition, lays them out, draws them and finds what is
//! under a point; `filmstrip.zig` owns the state and what clicks and drags do.
const std = @import("std");
const mesha = @import("mesha");
const Atom = mesha.Atom;
const names = @import("names.zig");
const roop = mesha.roop;
const math = mesha.math;
const plugin = mesha.plugin;
const panels_mod = mesha.panels;
const style = @import("../ui/style.zig");

const api = plugin.figure_api;
const Rect = panels_mod.Rect;

// ---- geometry ---------------------------------------------------------------------------

/// The transport bar along the panel's top; `panels.zig` draws it.
pub const controls_height: f32 = 34;
pub const ruler_height: f32 = 22;
pub const lane_height: f32 = 22;
pub const gutter_width: f32 = 168;
const track_margin: f32 = 12;
/// Pixels either side of a key's diamond that still hit it.
const diamond_reach: f32 = 6;
/// Keys closer than this share one diamond: a diamond's width, so diamonds never overlap and
/// a dense lane draws one per diamond's width.
const mark_spacing: f32 = 11;
/// Exposure blocks narrower than this draw as one run with no grip or easing curve.
const dense_block: f32 = 8;

/// Where the timeline's parts sit in its panel: `frames / zoom` of the clip's frames, from
/// frame `start`, spread across the track.
pub const Geometry = struct {
    rect: Rect,
    frames: u32,
    /// How many times wider a frame is than with the whole clip fitted to the track; at least 1.
    zoom: f32 = 1,
    /// The frame at the track's left edge.
    start: f32 = 0,

    pub fn trackLeft(g: Geometry) f32 {
        return g.rect.x + gutter_width + track_margin;
    }

    pub fn trackWidth(g: Geometry) f32 {
        return @max(g.rect.w - gutter_width - 2 * track_margin, 1);
    }

    pub fn trackRight(g: Geometry) f32 {
        return g.trackLeft() + g.trackWidth();
    }

    /// The width of one frame.
    pub fn framePixels(g: Geometry) f32 {
        return g.trackWidth() / @as(f32, @floatFromInt(@max(g.frames, 1))) * g.zoom;
    }

    pub fn frameX(g: Geometry, frame: f64) f32 {
        return g.trackLeft() + (@as(f32, @floatCast(frame)) - g.start) * g.framePixels();
    }

    /// The frame nearest `x`, which may lie outside the clip.
    pub fn frameAt(g: Geometry, x: f32) i64 {
        return @intFromFloat(@round((x - g.trackLeft()) / g.framePixels() + g.start));
    }

    /// Whether a mark at `x`, `reach` pixels wide either side, shows on the track.
    pub fn shows(g: Geometry, x: f32, reach: f32) bool {
        return x + reach >= g.trackLeft() and x - reach <= g.trackRight();
    }

    pub fn rulerTop(g: Geometry) f32 {
        return g.rect.y + controls_height;
    }

    /// The top of display row `row`: row 0 is the Keys lane, then the property lanes.
    pub fn rowTop(g: Geometry, row: usize) f32 {
        return g.rulerTop() + ruler_height + @as(f32, @floatFromInt(row)) * lane_height;
    }

    /// Display rows that fit, the Keys lane included.
    pub fn visibleRows(g: Geometry) usize {
        const room = g.rect.y + g.rect.h - g.rowTop(0);
        return @intFromFloat(@max(@floor(room / lane_height), 0));
    }

    /// A key's exposure block in the Keys lane, `duration` frames long.
    pub fn exposureRect(g: Geometry, key_frame: u32, duration: u32) Rect {
        return .{
            .x = g.frameX(@floatFromInt(key_frame)),
            .y = g.rowTop(0) + 3,
            .w = @as(f32, @floatFromInt(duration)) * g.framePixels(),
            .h = lane_height - 6,
        };
    }
};

/// The most a clip `frames` long zooms in: eight frames across the track.
pub fn maxZoom(frames: u32) f32 {
    return @max(@as(f32, @floatFromInt(frames)) / 8, 1);
}

/// `start` kept where the track shows only the clip's frames, `zoom` within its limits.
pub fn bounded(frames: u32, zoom: f32, start: f32) struct { zoom: f32, start: f32 } {
    const shown_zoom = if (std.math.isFinite(zoom)) std.math.clamp(zoom, 1, maxZoom(frames)) else 1;
    const frame_count: f32 = @floatFromInt(frames);
    const latest = @max(frame_count - frame_count / shown_zoom, 0);
    const shown_start = if (std.math.isFinite(start)) std.math.clamp(start, 0, latest) else 0;
    return .{ .zoom = shown_zoom, .start = shown_start };
}

/// The timeline zoomed to `zoom` with the frame under `x` kept under it.
pub fn zoomedAt(g: Geometry, zoom: f32, x: f32) Geometry {
    const offset = std.math.clamp(x - g.trackLeft(), 0, g.trackWidth());
    const anchor = offset / g.framePixels() + g.start;
    var result = g;
    result.zoom = zoom;
    result.start = anchor - offset / result.framePixels();
    const limits = bounded(g.frames, result.zoom, result.start);
    result.zoom = limits.zoom;
    result.start = limits.start;
    return result;
}

/// The grip at an exposure block's end, which drags its hold.
pub fn gripWidth(block: Rect) f32 {
    return @min(8, block.w / 3);
}

// ---- lanes ------------------------------------------------------------------------------

/// A lane's value at a key.
pub const Value = union(enum) {
    number: f32,
    /// Radians, shown in degrees.
    angle: f32,
    vec2: api.Vec2,
    color: [4]u8,
    flag: bool,
    name: Atom,
    /// A row id; zero is none.
    reference: u32,
    /// An IK controller the key leaves off.
    off,
    /// A list of values, compared but not spelled out.
    other: [api.property_value_bytes]u8,

    fn near(a: f32, b: f32) bool {
        return @abs(a - b) <= 1e-4;
    }

    pub fn eql(a: Value, b: Value) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .number => |x| near(x, b.number),
            .angle => |x| near(x, b.angle),
            .vec2 => |x| near(x.x, b.vec2.x) and near(x.y, b.vec2.y),
            .color => |x| std.mem.eql(u8, &x, &b.color),
            .flag => |x| x == b.flag,
            .name => |x| x == b.name,
            .reference => |x| x == b.reference,
            .off => true,
            .other => |x| std.mem.eql(u8, &x, &b.other),
        };
    }

    /// Whether the value switches at a key rather than easing between keys, as on/off
    /// values, names and references do; lists of numbers or colors blend.
    pub fn steps(value: Value) bool {
        return switch (value) {
            .flag, .name, .reference, .off => true,
            .number, .angle, .vec2, .color, .other => false,
        };
    }

    /// The value as text: numbers to two places, angles in degrees, colors as hex.
    pub fn format(value: Value, buffer: []u8, atoms: *Atom.Registry) []const u8 {
        return switch (value) {
            .number => |x| std.fmt.bufPrint(buffer, "{d:.2}", .{x}),
            .angle => |x| std.fmt.bufPrint(buffer, "{d:.1} deg", .{std.math.radiansToDegrees(x)}),
            .vec2 => |x| std.fmt.bufPrint(buffer, "({d:.1}, {d:.1})", .{ x.x, x.y }),
            .color => |x| if (x[3] == 255)
                std.fmt.bufPrint(buffer, "#{x:0>2}{x:0>2}{x:0>2}", .{ x[0], x[1], x[2] })
            else
                std.fmt.bufPrint(buffer, "#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ x[0], x[1], x[2], x[3] }),
            .flag => |x| std.fmt.bufPrint(buffer, "{s}", .{if (x) "on" else "off"}),
            .name => |x| std.fmt.bufPrint(buffer, "{s}", .{atoms.lookup(x) orelse "?"}),
            .reference => |x| if (x == 0) std.fmt.bufPrint(buffer, "none", .{}) else std.fmt.bufPrint(buffer, "#{d}", .{x}),
            .off => std.fmt.bufPrint(buffer, "off", .{}),
            .other => std.fmt.bufPrint(buffer, "(list)", .{}),
        } catch "";
    }
};

pub const LaneKind = enum { bone, ik, property };

/// One property over the clip: its value at each key, in key order.
pub const Lane = struct { kind: LaneKind, label: []const u8, values: []const Value };

pub const Model = struct {
    keys: []const api.read.ClipKey,
    frames: u32,
    loop: bool,
    lanes: []const Lane,
};

fn changes(values: []const Value) bool {
    for (values[1..]) |value| {
        if (!value.eql(values[0])) return true;
    }
    return false;
}

/// The clip's lanes: each bone channel, IK target and pose property whose value differs
/// between two of `keys`. One key, or none, changes nothing and has no lanes.
pub fn build(allocator: std.mem.Allocator, atoms: *Atom.Registry, data: api.read.Definition, clip: api.read.Clip, keys: []const api.read.ClipKey) !Model {
    var lanes: std.ArrayListUnmanaged(Lane) = .empty;
    const model: Model = .{ .keys = keys, .frames = clip.frames, .loop = clip.loop != 0, .lanes = &.{} };
    if (keys.len < 2) return model;
    try boneLanes(allocator, atoms, data, keys, &lanes);
    try ikLanes(allocator, atoms, data, keys, &lanes);
    try propertyLanes(allocator, atoms, data, keys, &lanes);
    var result = model;
    result.lanes = lanes.items;
    return result;
}

fn boneLanes(allocator: std.mem.Allocator, atoms: *Atom.Registry, data: api.read.Definition, keys: []const api.read.ClipKey, lanes: *std.ArrayListUnmanaged(Lane)) !void {
    const channels = [_]struct { name: []const u8, bit: u32 }{
        .{ .name = "rotation", .bit = api.read.Channels.rotation },
        .{ .name = "position", .bit = api.read.Channels.local },
        .{ .name = "scale", .bit = api.read.Channels.scale },
        .{ .name = "length", .bit = api.read.Channels.length },
    };
    // A pose has one channel row for a bone. Found by its pose and bone, a long clip's lanes
    // cost its keys and not its keys times every pose's rows.
    const PoseBone = struct { pose: u32, bone: u32 };
    var channel_rows: std.AutoHashMapUnmanaged(PoseBone, api.read.PoseChannel) = .empty;
    try channel_rows.ensureTotalCapacity(allocator, @intCast(data.pose_channels.len));
    for (data.pose_channels) |row| {
        const entry = channel_rows.getOrPutAssumeCapacity(.{ .pose = row.pose, .bone = row.bone });
        if (!entry.found_existing) entry.value_ptr.* = row;
    }
    for (data.bones) |bone| for (channels) |channel| {
        const values = try allocator.alloc(Value, keys.len);
        for (keys, values) |key, *value| {
            const found = channel_rows.get(.{ .pose = key.pose, .bone = bone.id });
            const row = if (found != null and found.?.mask & channel.bit != 0) found else null;
            value.* = switch (channel.bit) {
                api.read.Channels.rotation => .{ .angle = if (row) |r| r.rotation else bone.rotation },
                api.read.Channels.local => .{ .vec2 = if (row) |r| r.local else bone.local },
                api.read.Channels.scale => .{ .vec2 = if (row) |r| r.scale else bone.scale },
                else => .{ .number = if (row) |r| r.length else bone.length },
            };
        }
        if (!changes(values)) continue;
        const label = try std.fmt.allocPrint(allocator, "{s} {s}", .{ atoms.lookup(bone.name) orelse "bone", channel.name });
        try lanes.append(allocator, .{ .kind = .bone, .label = label, .values = values });
    };
}

fn ikLanes(allocator: std.mem.Allocator, atoms: *Atom.Registry, data: api.read.Definition, keys: []const api.read.ClipKey, lanes: *std.ArrayListUnmanaged(Lane)) !void {
    for (data.ik) |controller| {
        const values = try allocator.alloc(Value, keys.len);
        for (keys, values) |key, *value| {
            const row = for (data.pose_ik) |row| {
                if (row.pose == key.pose and row.ik == controller.id and row.enabled != 0) break row;
            } else null;
            value.* = if (row) |r| .{ .vec2 = r.target } else .off;
        }
        if (!changes(values)) continue;
        const label = try std.fmt.allocPrint(allocator, "{s} target", .{atoms.lookup(controller.name) orelse "ik"});
        try lanes.append(allocator, .{ .kind = .ik, .label = label, .values = values });
    }
}

fn ReadRow(comptime family: api.PropertyFamily) type {
    return switch (family) {
        .bone => api.read.Bone,
        .layer => api.read.Layer,
        .shape => api.read.Shape,
        .point => api.read.Point,
        .paint => api.read.Paint,
    };
}

fn asValue(comptime T: type, value: T) Value {
    if (T == f32) return .{ .number = value };
    if (T == api.Vec2) return .{ .vec2 = value };
    if (T == [4]u8) return .{ .color = value };
    if (T == u8) return .{ .flag = value != 0 };
    if (T == Atom) return .{ .name = value };
    if (T == u32) return .{ .reference = value };
    return .{ .other = api.propertyValue(value) };
}

/// A pose property's bytes as a lane value, by its field's type.
fn decode(family: api.PropertyFamily, field: Atom, bytes: [api.property_value_bytes]u8) Value {
    switch (family) {
        inline else => |known| inline for (@field(api.animatable_fields, @tagName(known))) |name| {
            if (Atom.from(name) == field) {
                const T = @FieldType(ReadRow(known), name);
                return asValue(T, api.propertyAs(T, bytes));
            }
        },
    }
    return .{ .other = bytes };
}

/// The definition's own value of a property, where no key sets it.
fn baseValue(data: api.read.Definition, row: api.read.PoseProperty) ?Value {
    const family = std.enums.fromInt(api.PropertyFamily, row.family) orelse return null;
    switch (family) {
        inline else => |known| {
            const rows = switch (known) {
                .bone => data.bones,
                .layer => data.layers,
                .shape => data.shapes,
                .point => data.points,
                .paint => data.paints,
            };
            const source = for (rows) |candidate| {
                const matches = if (known == .point) candidate.shape == row.target and candidate.index == row.index else candidate.id == row.target;
                if (matches) break candidate;
            } else return null;
            inline for (@field(api.animatable_fields, @tagName(known))) |name| {
                if (Atom.from(name) == row.field) return asValue(@TypeOf(@field(source, name)), @field(source, name));
            }
            return null;
        },
    }
}

fn rowName(data: api.read.Definition, family: api.PropertyFamily, target: u32) Atom {
    const none: Atom = @enumFromInt(0);
    return switch (family) {
        .bone => for (data.bones) |row| {
            if (row.id == target) break row.name;
        } else none,
        .layer => for (data.layers) |row| {
            if (row.id == target) break row.name;
        } else none,
        .shape, .point => for (data.shapes) |row| {
            if (row.id == target) break row.name;
        } else none,
        .paint => for (data.paints) |row| {
            if (row.id == target) break row.name;
        } else none,
    };
}

fn propertyLanes(allocator: std.mem.Allocator, atoms: *Atom.Registry, data: api.read.Definition, keys: []const api.read.ClipKey, lanes: *std.ArrayListUnmanaged(Lane)) !void {
    // Every property one of the keys sets, once.
    // Found by what they name, so a long clip's lanes cost its keys and not its keys times
    // every pose's rows.
    const Property = struct { family: u32, target: u32, index: u32, field: Atom };
    const PoseProperty = struct { pose: u32, property: Property };
    var keyed_poses: std.AutoHashMapUnmanaged(u32, void) = .empty;
    try keyed_poses.ensureTotalCapacity(allocator, @intCast(keys.len));
    for (keys) |key| keyed_poses.putAssumeCapacity(key.pose, {});
    // In the order the rows first name them, which is the lanes' order.
    var seen: std.AutoArrayHashMapUnmanaged(Property, api.read.PoseProperty) = .empty;
    var property_rows: std.AutoHashMapUnmanaged(PoseProperty, api.read.PoseProperty) = .empty;
    for (data.pose_properties) |row| {
        if (!keyed_poses.contains(row.pose)) continue;
        const property: Property = .{ .family = row.family, .target = row.target, .index = row.index, .field = row.field };
        const first = try seen.getOrPut(allocator, property);
        if (!first.found_existing) first.value_ptr.* = row;
        const entry = try property_rows.getOrPut(allocator, .{ .pose = row.pose, .property = property });
        if (!entry.found_existing) entry.value_ptr.* = row;
    }
    for (seen.keys(), seen.values()) |named, property| {
        const family = std.enums.fromInt(api.PropertyFamily, property.family) orelse continue;
        const base = baseValue(data, property) orelse continue;
        const values = try allocator.alloc(Value, keys.len);
        for (keys, values) |key, *value| {
            const row = property_rows.get(.{ .pose = key.pose, .property = named });
            value.* = if (row) |r| decode(family, r.field, r.value) else base;
        }
        if (!changes(values)) continue;
        const target = atoms.lookup(rowName(data, family, property.target)) orelse "?";
        const field = try spaced(allocator, atoms.lookup(property.field) orelse "?");
        const label = if (family == .point)
            try std.fmt.allocPrint(allocator, "{s} point {d} {s}", .{ target, property.index, field })
        else
            try std.fmt.allocPrint(allocator, "{s} {s}", .{ target, field });
        try lanes.append(allocator, .{ .kind = .property, .label = label, .values = values });
    }
}

/// A field name as words: `fill_color` reads "fill color".
fn spaced(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const words = try allocator.dupe(u8, name);
    std.mem.replaceScalar(u8, words, '_', ' ');
    return words;
}

/// The key a lane's value comes from before key `index`: the one before, or the last when
/// a looping clip wraps around.
fn previousKey(model: Model, index: usize) ?usize {
    if (index > 0) return index - 1;
    return if (model.loop and model.keys.len > 1) model.keys.len - 1 else null;
}

// ---- hit testing ---------------------------------------------------------------------------

pub const Hit = union(enum) {
    none,
    /// The ruler, or empty track: a press scrubs.
    track,
    /// A key's diamond or exposure block: a press selects it.
    key: struct { row: usize, index: usize },
    /// The grip at the end of a key's exposure: a drag sets its hold.
    grip: usize,
};

/// What is under `point`: `scroll` property lanes are scrolled past.
pub fn hitAt(model: Model, g: Geometry, scroll: usize, point: api.Vec2, holds: []const u32) Hit {
    if (point.x < g.rect.x or point.x >= g.rect.x + g.rect.w or point.y < g.rulerTop() or point.y >= g.rect.y + g.rect.h) return .none;
    if (point.x < g.trackLeft() - diamond_reach) return .none;
    if (point.y < g.rowTop(0)) return .track;
    const row: usize = @intFromFloat(@floor((point.y - g.rowTop(0)) / lane_height));
    if (row == 0) {
        for (model.keys, holds, 0..) |key, duration, index| {
            const block = g.exposureRect(key.frame, duration);
            if (block.w < dense_block) continue;
            if (point.x >= block.x + block.w - gripWidth(block) and point.x < block.x + block.w) return .{ .grip = index };
        }
        for (model.keys, holds, 0..) |key, duration, index| {
            const block = g.exposureRect(key.frame, duration);
            if (point.x >= block.x - diamond_reach and point.x < block.x + block.w) return .{ .key = .{ .row = 0, .index = index } };
        }
        return .track;
    }
    const lane = row - 1 + scroll;
    if (lane >= model.lanes.len) return .track;
    for (model.keys, 0..) |key, index| {
        if (@abs(point.x - g.frameX(@floatFromInt(key.frame))) <= diamond_reach) return .{ .key = .{ .row = row, .index = index } };
    }
    return .track;
}

// ---- drawing ------------------------------------------------------------------------------

const bone_color = roop.rgba(110, 170, 235, 255);
const ik_color = roop.rgba(190, 140, 225, 255);
const property_color = roop.rgba(232, 160, 84, 255);
const keys_color = roop.rgba(205, 205, 212, 255);

fn laneColor(kind: LaneKind) roop.Color {
    return switch (kind) {
        .bone => bone_color,
        .ik => ik_color,
        .property => property_color,
    };
}

fn withAlpha(color: roop.Color, alpha: f32) roop.Color {
    var result = color;
    result.a = alpha;
    return result;
}

fn fillRect(ctx: *roop.Context, x: f32, y: f32, w: f32, h: f32, color: roop.Color) void {
    if (w <= 0 or h <= 0) return;
    ctx.beginPath();
    ctx.rect(x, y, w, h);
    ctx.fillColor(color);
    ctx.fill();
}

/// Limits drawing to the track and the margins either side of it, out of the gutter; the
/// caller restores.
fn clipToTrack(ctx: *roop.Context, g: Geometry) void {
    ctx.save();
    const left = g.rect.x + gutter_width;
    ctx.intersectScissor(left, g.rulerTop(), g.rect.x + g.rect.w - left, g.rect.y + g.rect.h - g.rulerTop(), 0);
}

fn diamond(ctx: *roop.Context, x: f32, y: f32, radius: f32) void {
    ctx.beginPath();
    addDiamond(ctx, x, y, radius);
}

/// A diamond added to the current path, so many fill or stroke as one.
fn addDiamond(ctx: *roop.Context, x: f32, y: f32, radius: f32) void {
    ctx.moveTo(x, y - radius);
    ctx.lineTo(x + radius, y);
    ctx.lineTo(x, y + radius);
    ctx.lineTo(x - radius, y);
    ctx.closePath();
}

/// `text` cut short with "..." to fit `width`.
fn fitted(ctx: *roop.Context, font: roop.Font, text: []const u8, width: f32, buffer: []u8) []const u8 {
    if (ctx.measureText(font, text).w <= width) return text;
    var length = @min(text.len, buffer.len -| 3);
    while (length > 0) : (length -= 1) {
        if (length < text.len and text[length] & 0xC0 == 0x80) continue;
        @memcpy(buffer[0..length], text[0..length]);
        @memcpy(buffer[length..][0..3], "...");
        if (ctx.measureText(font, buffer[0 .. length + 3]).w <= width) return buffer[0 .. length + 3];
    }
    return "";
}

/// The easing of a key's outgoing segment: its shape from 0 to 1.
fn ease(easing: Atom, u: f32) f32 {
    if (easing == Atom.from("constant")) return 0;
    if (easing == Atom.from("smooth")) return u * u * (3 - 2 * u);
    if (easing == Atom.from("ease_in")) return u * u;
    if (easing == Atom.from("ease_out")) return u * (2 - u);
    return u;
}

/// What the timeline shows besides the model: the playhead, the selected key, the pointer.
pub const View = struct {
    /// The playhead, in frames.
    playhead: f64,
    selected_key: ?usize,
    /// Property lanes scrolled past.
    scroll: usize,
    /// The pointer, while it is over the timeline and no drag holds it.
    pointer: ?api.Vec2,
    /// Each key's exposure in frames, in key order.
    holds: []const u32,
};

pub fn draw(ctx: *roop.Context, atoms: *Atom.Registry, model: Model, g: Geometry, view: View) void {
    const font = style.ui_font;
    ctx.fontFace(font);
    ctx.textAlign(.{ .left = true, .baseline = true });
    const ascender = @round(ctx.fontAscender(font));
    fillRect(ctx, g.rect.x, g.rulerTop(), g.rect.w, g.rect.y + g.rect.h - g.rulerTop(), style.col.canvas);
    // The gutter, under the lane names.
    fillRect(ctx, g.rect.x, g.rulerTop(), gutter_width, g.rect.y + g.rect.h - g.rulerTop(), style.col.sidebar);
    drawRuler(ctx, model, g, ascender);
    const rows = g.visibleRows();
    var label_buffer: [128]u8 = undefined;
    for (0..rows) |row| {
        const top = g.rowTop(row);
        if (row % 2 == 1) fillRect(ctx, g.rect.x + gutter_width, top, g.rect.w - gutter_width, lane_height, roop.rgba(255, 255, 255, 6));
        if (row == 0) {
            ctx.fillColor(style.col.text);
            _ = ctx.text(g.rect.x + 10, top + ascender + 3, "Keys");
            drawKeysLane(ctx, atoms, model, g, view, ascender);
            continue;
        }
        const index = row - 1 + view.scroll;
        if (index >= model.lanes.len) {
            if (row == 1 and model.lanes.len == 0) {
                ctx.fillColor(style.col.text_disabled);
                const hint = if (model.keys.len < 2) "Add a second key to see what changes" else "Nothing changes between these keys";
                _ = ctx.text(g.rect.x + 10, top + ascender + 3, hint);
            }
            continue;
        }
        const lane = model.lanes[index];
        // A swatch of the lane's kind, then its name.
        fillRect(ctx, g.rect.x + 8, top + 7, 3, lane_height - 14, laneColor(lane.kind));
        ctx.fillColor(style.col.text_dim);
        _ = ctx.text(g.rect.x + 18, top + ascender + 3, fitted(ctx, font, lane.label, gutter_width - 24, &label_buffer));
        drawLane(ctx, model, g, view, lane, top);
    }
    if (model.lanes.len > rows -| 1 and rows > 1) {
        var buffer: [48]u8 = undefined;
        const more = std.fmt.bufPrint(&buffer, "{d}-{d} of {d} lanes", .{ view.scroll + 1, @min(view.scroll + rows - 1, model.lanes.len), model.lanes.len }) catch "";
        const width = ctx.measureText(font, more).w;
        fillRect(ctx, g.rect.x + g.rect.w - width - 14, g.rect.y + g.rect.h - lane_height + 2, width + 10, lane_height - 4, roop.rgba(20, 20, 24, 220));
        ctx.fillColor(style.col.text_disabled);
        _ = ctx.text(g.rect.x + g.rect.w - width - 9, g.rect.y + g.rect.h - 6, more);
    }
    // The playhead over every lane.
    const playhead = g.frameX(view.playhead);
    if (playhead >= g.trackLeft() - 1 and playhead <= g.trackLeft() + g.trackWidth() + 1) {
        fillRect(ctx, @round(playhead) - 1, g.rulerTop(), 2, g.rect.y + g.rect.h - g.rulerTop(), style.playhead);
        ctx.beginPath();
        ctx.moveTo(playhead - 5, g.rulerTop());
        ctx.lineTo(playhead + 5, g.rulerTop());
        ctx.lineTo(playhead, g.rulerTop() + 7);
        ctx.closePath();
        ctx.fillColor(style.playhead);
        ctx.fill();
    }
    if (view.pointer) |pointer| drawHover(ctx, atoms, model, g, view, pointer, ascender);
}

fn drawRuler(ctx: *roop.Context, model: Model, g: Geometry, ascender: f32) void {
    fillRect(ctx, g.rect.x, g.rulerTop(), g.rect.w, ruler_height, roop.rgba(34, 34, 38, 255));
    fillRect(ctx, g.rect.x, g.rulerTop() + ruler_height - 1, g.rect.w, 1, style.col.divider);
    // Labels about 48 pixels apart, on a step a frame count divides well by.
    const steps = [_]u32{ 1, 2, 4, 5, 6, 8, 10, 12, 16, 20, 24, 30, 48, 60, 96, 120, 240, 480 };
    var step: u32 = steps[steps.len - 1];
    for (steps) |candidate| {
        if (@as(f32, @floatFromInt(candidate)) * g.framePixels() >= 48) {
            step = candidate;
            break;
        }
    }
    const minor = g.framePixels() >= 5;
    // Without minor ticks, only labelled frames are visited, and only those on the track.
    const stride: u32 = if (minor) 1 else step;
    const shown_frames = g.trackWidth() / g.framePixels();
    const first_shown: u32 = @intFromFloat(@max(@floor(g.start), 0));
    const last_shown: u32 = @intFromFloat(@min(@ceil(g.start + shown_frames), @as(f32, @floatFromInt(model.frames))));
    clipToTrack(ctx, g);
    defer ctx.restore();
    var frame: u32 = first_shown - first_shown % stride;
    var buffer: [16]u8 = undefined;
    while (frame <= last_shown) : (frame += stride) {
        const x = @round(g.frameX(@floatFromInt(frame)));
        if (frame % step == 0) {
            fillRect(ctx, x, g.rulerTop() + ruler_height - 8, 1, 7, style.col.text_disabled);
            const label = std.fmt.bufPrint(&buffer, "{d}", .{frame}) catch "";
            ctx.fillColor(style.col.text_dim);
            _ = ctx.text(x + 3, g.rulerTop() + ascender + 1, label);
        } else if (minor) {
            fillRect(ctx, x, g.rulerTop() + ruler_height - 4, 1, 3, roop.rgba(90, 90, 96, 255));
        }
    }
    // The clip's end.
    const end = g.frameX(@floatFromInt(model.frames));
    if (g.shows(end, 1)) fillRect(ctx, @round(end), g.rulerTop(), 1, g.rect.y + g.rect.h - g.rulerTop(), style.col.divider);
}

fn drawKeysLane(ctx: *roop.Context, atoms: *Atom.Registry, model: Model, g: Geometry, view: View, ascender: f32) void {
    const font = style.ui_font;
    clipToTrack(ctx, g);
    defer ctx.restore();
    // Blocks too narrow for a grip or a curve draw as one run where they touch.
    var dense: ?[2]f32 = null;
    for (model.keys, view.holds, 0..) |key, duration, index| {
        const block = g.exposureRect(key.frame, duration);
        if (block.x > g.trackRight() + diamond_reach or block.x + block.w < g.trackLeft() - diamond_reach) continue;
        const selected = view.selected_key != null and view.selected_key.? == index;
        if (block.w < dense_block and !selected) {
            if (dense) |*run| {
                if (block.x <= run[1] + 0.5) {
                    run[1] = block.x + block.w;
                    continue;
                }
                drawDenseRun(ctx, g, run.*);
            }
            dense = .{ block.x, block.x + block.w };
            continue;
        }
        if (dense) |run| drawDenseRun(ctx, g, run);
        dense = null;
        ctx.beginPath();
        ctx.roundedRect(block.x, block.y, @max(block.w - 1, 1), block.h, 3);
        ctx.fillColor(if (selected) style.col.accent_deep else style.col.card);
        ctx.fill();
        // The segment's easing, drawn as the curve it follows.
        if (block.w > 16) {
            ctx.beginPath();
            const samples: usize = 12;
            for (0..samples + 1) |sample| {
                const u: f32 = @as(f32, @floatFromInt(sample)) / @as(f32, @floatFromInt(samples));
                const x = block.x + u * (block.w - 1);
                const y = block.y + block.h - 2 - ease(key.easing, u) * (block.h - 4);
                if (sample == 0) ctx.moveTo(x, y) else ctx.lineTo(x, y);
            }
            ctx.strokeColor(roop.rgba(255, 255, 255, 40));
            ctx.strokeWidth(1);
            ctx.stroke();
        }
        if (block.w >= 60) {
            var buffer: [48]u8 = undefined;
            ctx.save();
            ctx.intersectScissor(block.x, block.y, block.w - gripWidth(block), block.h, 0);
            ctx.fillColor(if (selected) style.col.text else style.col.text_dim);
            const easing = atoms.lookup(key.easing) orelse "?";
            _ = ctx.text(block.x + 12, block.y + ascender, fitted(ctx, font, easing, block.w - 20, &buffer));
            ctx.restore();
        }
        if (block.w >= dense_block) {
            const grip = gripWidth(block);
            fillRect(ctx, block.x + block.w - grip, block.y + 3, grip - 2, block.h - 6, roop.rgba(255, 255, 255, 50));
        }
    }
    if (dense) |run| drawDenseRun(ctx, g, run);
    // The diamonds over the blocks as one path; the selected key's last, on top.
    const middle = g.rowTop(0) + lane_height * 0.5;
    ctx.beginPath();
    var marks: Marks = .{ .model = model, .g = g, .lane = null };
    while (marks.next()) |mark| addDiamond(ctx, mark.x, middle, 5);
    ctx.fillColor(keys_color);
    ctx.fill();
    if (view.selected_key) |index| {
        diamond(ctx, g.frameX(@floatFromInt(model.keys[index].frame)), middle, 5);
        ctx.fillColor(style.col.accent_bright);
        ctx.fill();
    }
}

/// Exposure blocks from `run[0]` to `run[1]`, too narrow to draw apart.
fn drawDenseRun(ctx: *roop.Context, g: Geometry, run: [2]f32) void {
    ctx.beginPath();
    ctx.roundedRect(run[0], g.rowTop(0) + 3, @max(run[1] - run[0] - 1, 1), lane_height - 6, 3);
    ctx.fillColor(style.col.card);
    ctx.fill();
}

fn drawLane(ctx: *roop.Context, model: Model, g: Geometry, view: View, lane: Lane, top: f32) void {
    const middle = top + lane_height * 0.5;
    const color = laneColor(lane.kind);
    const bar_color = withAlpha(color, 0.45);
    clipToTrack(ctx, g);
    defer ctx.restore();
    // Where the value moves: a bar from each key to the next that differs from it, the bars
    // that meet drawn as one.
    var moving: ?[2]f32 = null;
    for (model.keys, 0..) |key, index| {
        const next = if (index + 1 < model.keys.len) index + 1 else if (model.loop) 0 else continue;
        if (lane.values[index].eql(lane.values[next])) continue;
        const from = g.frameX(@floatFromInt(key.frame));
        const to = if (next > index) g.frameX(@floatFromInt(model.keys[next].frame)) else g.frameX(@floatFromInt(model.frames));
        // A loop's wrap: from the clip's start to the first key as well.
        if (next < index and model.keys[0].frame > 0) fillRect(ctx, g.frameX(0), middle - 1.5, g.frameX(@floatFromInt(model.keys[0].frame)) - g.frameX(0), 3, bar_color);
        if (to < g.trackLeft() or from > g.trackRight()) continue;
        if (moving) |*run| {
            if (from <= run[1] + 0.5) {
                run[1] = to;
                continue;
            }
            fillRect(ctx, run[0], middle - 1.5, run[1] - run[0], 3, bar_color);
        }
        moving = .{ from, to };
    }
    if (moving) |run| fillRect(ctx, run[0], middle - 1.5, run[1] - run[0], 3, bar_color);
    // The diamonds, each kind as one path: filled where the value changes, hollow where it holds.
    ctx.beginPath();
    var marks: Marks = .{ .model = model, .g = g, .lane = lane };
    while (marks.next()) |mark| if (mark.changed) addDiamond(ctx, mark.x, middle, 5);
    ctx.fillColor(color);
    ctx.fill();
    ctx.beginPath();
    marks = .{ .model = model, .g = g, .lane = lane };
    while (marks.next()) |mark| if (!mark.changed) addDiamond(ctx, mark.x, middle, 5);
    ctx.fillColor(style.col.canvas);
    ctx.fill();
    ctx.beginPath();
    marks = .{ .model = model, .g = g, .lane = lane };
    while (marks.next()) |mark| if (!mark.changed) addDiamond(ctx, mark.x, middle, 4.5);
    ctx.strokeColor(withAlpha(color, 0.8));
    ctx.strokeWidth(1.2);
    ctx.stroke();
    if (view.selected_key) |index| {
        diamond(ctx, g.frameX(@floatFromInt(model.keys[index].frame)), middle, 7.5);
        ctx.strokeColor(style.col.accent_bright);
        ctx.strokeWidth(1.2);
        ctx.stroke();
    }
}

/// The diamonds a lane shows on the track, from the left: keys closer than `mark_spacing` to
/// the last one shown share its diamond, which is filled if any of them changes the value.
const Marks = struct {
    model: Model,
    g: Geometry,
    /// The lane whose values say which keys change it; null for the Keys lane.
    lane: ?Lane,
    index: usize = 0,

    const Mark = struct { x: f32, changed: bool };

    fn next(marks: *Marks) ?Mark {
        const keys = marks.model.keys;
        while (marks.index < keys.len) {
            const first = marks.index;
            marks.index += 1;
            const x = marks.g.frameX(@floatFromInt(keys[first].frame));
            if (!marks.g.shows(x, diamond_reach)) continue;
            var mark: Mark = .{ .x = x, .changed = marks.changes(first) };
            while (marks.index < keys.len) : (marks.index += 1) {
                const following = marks.g.frameX(@floatFromInt(keys[marks.index].frame));
                if (following - x >= mark_spacing) break;
                mark.changed = mark.changed or marks.changes(marks.index);
            }
            return mark;
        }
        return null;
    }

    fn changes(marks: Marks, index: usize) bool {
        const lane = marks.lane orelse return true;
        const previous = previousKey(marks.model, index) orelse return true;
        return !lane.values[index].eql(lane.values[previous]);
    }
};

/// A card beside a hovered key: in the Keys lane, the key itself; in a property lane, what
/// changes there.
fn drawHover(ctx: *roop.Context, atoms: *Atom.Registry, model: Model, g: Geometry, view: View, pointer: api.Vec2, ascender: f32) void {
    const hit = hitAt(model, g, view.scroll, pointer, view.holds);
    const found = switch (hit) {
        .key => |key| key,
        .grip => |index| @as(@FieldType(Hit, "key"), .{ .row = 0, .index = index }),
        else => return,
    };
    const key = model.keys[found.index];
    var lines: [3][160]u8 = undefined;
    var texts: [3][]const u8 = .{ "", "", "" };
    var swatches: [2]?[4]u8 = .{ null, null };
    const easing = atoms.lookup(key.easing) orelse "?";
    if (found.row == 0) {
        texts[0] = std.fmt.bufPrint(&lines[0], "Key at frame {d}", .{key.frame}) catch "";
        texts[1] = std.fmt.bufPrint(&lines[1], "holds {d} frames, {s} into the next", .{ view.holds[found.index], easing }) catch "";
        texts[2] = if (hit == .grip) "Drag to change how long it holds" else "Click to edit this key";
    } else {
        const lane = model.lanes[found.row - 1 + view.scroll];
        const before = previousKey(model, found.index);
        var from_buffer: [64]u8 = undefined;
        var to_buffer: [64]u8 = undefined;
        const to = lane.values[found.index].format(&to_buffer, atoms);
        texts[0] = lane.label;
        if (before) |previous| {
            const from = lane.values[previous].format(&from_buffer, atoms);
            const unchanged = lane.values[previous].eql(lane.values[found.index]);
            texts[1] = if (unchanged)
                std.fmt.bufPrint(&lines[1], "{s}, unchanged", .{to}) catch ""
            else
                std.fmt.bufPrint(&lines[1], "{s}  to  {s}", .{ from, to }) catch "";
            const previous_key = model.keys[previous];
            const previous_easing = atoms.lookup(previous_key.easing) orelse "?";
            texts[2] = if (lane.values[found.index].steps())
                std.fmt.bufPrint(&lines[2], "switches at frame {d}", .{key.frame}) catch ""
            else
                std.fmt.bufPrint(&lines[2], "frame {d} to {d}, {s}", .{ previous_key.frame, key.frame, previous_easing }) catch "";
            if (lane.values[previous] == .color) swatches[0] = lane.values[previous].color;
        } else {
            texts[1] = std.fmt.bufPrint(&lines[1], "{s} from the start", .{to}) catch "";
            texts[2] = std.fmt.bufPrint(&lines[2], "frame {d}", .{key.frame}) catch "";
        }
        if (lane.values[found.index] == .color) swatches[1] = lane.values[found.index].color;
    }
    const font = style.ui_font;
    var width: f32 = 0;
    for (texts) |text| width = @max(width, ctx.measureText(font, text).w);
    const swatch_room: f32 = if (swatches[0] != null or swatches[1] != null) 40 else 0;
    const card_w = @round(width + 20 + swatch_room);
    const card_h: f32 = 3 * 18 + 12;
    const card_x = @round(std.math.clamp(pointer.x + 14, g.rect.x, @max(g.rect.x + g.rect.w - card_w, g.rect.x)));
    // Above the pointer, or below it where the transport bar would cover the card.
    const above = pointer.y - card_h - 8;
    const preferred = if (above >= g.rulerTop()) above else pointer.y + 16;
    const card_y = @round(std.math.clamp(preferred, g.rulerTop(), @max(g.rect.y + g.rect.h - card_h, g.rulerTop())));
    ctx.beginPath();
    ctx.roundedRect(card_x, card_y, card_w, card_h, 5);
    ctx.fillColor(roop.rgba(22, 22, 26, 245));
    ctx.fill();
    ctx.beginPath();
    ctx.roundedRect(card_x + 0.5, card_y + 0.5, card_w - 1, card_h - 1, 5);
    ctx.strokeColor(style.col.border);
    ctx.strokeWidth(1);
    ctx.stroke();
    for (texts, 0..) |text, index| {
        ctx.fillColor(if (index == 0) style.col.text else style.col.text_dim);
        _ = ctx.text(card_x + 10, card_y + 6 + @as(f32, @floatFromInt(index)) * 18 + ascender, text);
    }
    // Colors are easier read as colors.
    for (swatches, 0..) |swatch, index| {
        const color = swatch orelse continue;
        const x = card_x + card_w - 36 + @as(f32, @floatFromInt(index)) * 16;
        ctx.beginPath();
        ctx.roundedRect(x, card_y + 24 + 2, 12, 12, 2);
        ctx.fillColor(roop.rgba(color[0], color[1], color[2], color[3]));
        ctx.fill();
    }
}

test "lanes keep only properties that change, and values compare within a tolerance" {
    const a: Value = .{ .angle = 1 };
    try std.testing.expect(a.eql(.{ .angle = 1.00001 }));
    try std.testing.expect(!a.eql(.{ .angle = 1.1 }));
    try std.testing.expect(!changes(&.{ a, .{ .angle = 1 } }));
    try std.testing.expect(changes(&.{ a, .{ .angle = 2 } }));
}

test "a dragged hold and a pressed frame map through one frame scale" {
    const g: Geometry = .{ .rect = .{ .x = 0, .y = 0, .w = 800, .h = 200 }, .frames = 24 };
    const block = g.exposureRect(6, 6);
    try std.testing.expectApproxEqAbs(g.frameX(6), block.x, 1e-4);
    try std.testing.expectApproxEqAbs(6 * g.framePixels(), block.w, 1e-4);
    try std.testing.expectEqual(@as(i64, 12), g.frameAt(g.frameX(12)));
}

test "a zoomed timeline keeps the frame under the pointer and stays on the clip" {
    const g: Geometry = .{ .rect = .{ .x = 0, .y = 0, .w = 1000, .h = 200 }, .frames = 240 };
    const x = g.frameX(60);
    const zoomed = zoomedAt(g, 4, x);
    try std.testing.expectApproxEqAbs(@as(f32, 4), zoomed.zoom, 1e-4);
    try std.testing.expectApproxEqAbs(x, zoomed.frameX(60), 1e-3);
    try std.testing.expectEqual(@as(i64, 60), zoomed.frameAt(x));
    // Zooming out past the whole clip, or scrolling past its ends, is held at them.
    try std.testing.expectApproxEqAbs(@as(f32, 1), zoomedAt(zoomed, 0.1, x).zoom, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0), zoomedAt(zoomed, 0.1, x).start, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 180), bounded(240, 4, 1000).start, 1e-4);
    try std.testing.expectApproxEqAbs(maxZoom(240), bounded(240, 1e9, 0).zoom, 1e-4);
}
