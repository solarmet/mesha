//! Where the world shows: the one row of `world_view`, which says which panel the world is
//! drawn under, where in the window, and through what camera.
//!
//! The world is the Figure system's registered rows (`figure.zig`). The host draws it, on the
//! render thread, at the display's rate, between the newest two of the snapshots it takes
//! after each frame: so the world moves smoothly however the frames fall against the clock's
//! fixed ticks. It draws it under the target of the panel the row names, clipped to the
//! row's view, and what that panel's plugin draws in its frame shows over it; a panel that
//! shows the world leaves its frame clear where the world is to be seen.
//!
//! The row is the host's table and the showing plugin's to write: a kernel of the system
//! that declares the panel keeps it in step with the panel's frame and the game's camera
//! (`View`, `letterbox`). With no panel named, or one that is not open, no world is drawn.
const std = @import("std");
const Atom = @import("../core/atom.zig").Atom;
const memory_mod = @import("../core/memory.zig");
const Table = @import("../core/table.zig");
const math = @import("../core/math.zig");
const panels = @import("panels.zig");

const Vec2f = math.Vec2f;

/// `world_view`, one row: what `View` views. Durable, so a reloaded plugin finds its camera.
pub const view_table_name = "world_view";

/// A view of the row of `world_view`.
pub const View = struct {
    /// The panel the world is drawn under; none (0) for nowhere.
    panel: *Atom,
    /// The top left of the view, in window pixels.
    origin: *Vec2f,
    /// The view's size on screen, in pixels: the world is clipped to it.
    size: *Vec2f,
    /// The world position at the view's middle, in world units.
    camera_position: *Vec2f,
    /// How far the game's camera zooms; 1 shows the world at the view's scale.
    camera_zoom: *f32,
    /// Screen pixels to a world unit at a zoom of 1: the scale that fits a design size into
    /// the view (`Letterbox.scale`).
    world_scale: *f32,
};

/// Creates `world_view` with a row that shows the world nowhere, unless it is there. The host
/// calls it.
pub fn ensure(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    var schema: Table.Schema = undefined;
    try schema.init(scratch.allocator, atoms, 6);
    defer schema.deinit();
    schema.addField("panel", Atom, .atom);
    schema.addField("origin", Vec2f, .{ .vector = .{ .components = 2 } });
    schema.addField("size", Vec2f, .{ .vector = .{ .components = 2 } });
    schema.addField("camera_position", Vec2f, .{ .vector = .{ .components = 2 } });
    schema.addField("camera_zoom", f32, .{ .float_slider = .{ .min = 0.1, .max = 8 } });
    schema.addField("world_scale", f32, .int);
    const no_panel: Atom = @enumFromInt(0);
    _ = try tables.ensureSingleton(&schema, atoms.intern(view_table_name), .{
        .panel = no_panel,
        .origin = Vec2f{ .x = 0, .y = 0 },
        .size = Vec2f{ .x = 0, .y = 0 },
        .camera_position = Vec2f{ .x = 0, .y = 0 },
        .camera_zoom = @as(f32, 1),
        .world_scale = @as(f32, 1),
    }, .durable);
}

/// A design size fitted whole into an area, centred, with bars along the sides it does not
/// fill.
pub const Letterbox = struct {
    /// The top left of the fitted view, in the area's coordinates.
    origin: Vec2f,
    /// The fitted view's size.
    size: Vec2f,
    /// The area's pixels to one of the design's.
    scale: f32,
};

/// Fits `design`, a size in design pixels, into `area`: the largest view of the design's
/// shape the area holds, centred in it. An empty area, or a design with no extent, gives an
/// empty view at the area's corner and a scale of 0.
pub fn letterbox(area: panels.Rect, design: Vec2f) Letterbox {
    if (area.empty() or design.x <= 0 or design.y <= 0) {
        return .{ .origin = .{ .x = area.x, .y = area.y }, .size = .{ .x = 0, .y = 0 }, .scale = 0 };
    }
    const scale = @min(area.w / design.x, area.h / design.y);
    const width = design.x * scale;
    const height = design.y * scale;
    return .{
        .origin = .{ .x = area.x + (area.w - width) / 2, .y = area.y + (area.h - height) / 2 },
        .size = .{ .x = width, .y = height },
        .scale = scale,
    };
}

test "a design is fitted whole into an area, centred" {
    const tall = letterbox(.{ .x = 100, .y = 0, .w = 960, .h = 1080 }, .{ .x = 1920, .y = 1080 });
    try std.testing.expectEqual(@as(f32, 0.5), tall.scale);
    try std.testing.expectEqual(Vec2f{ .x = 960, .y = 540 }, tall.size);
    try std.testing.expectEqual(Vec2f{ .x = 100, .y = 270 }, tall.origin);
    const none = letterbox(.{ .x = 4, .y = 8, .w = 0, .h = 300 }, .{ .x = 1920, .y = 1080 });
    try std.testing.expectEqual(@as(f32, 0), none.scale);
    try std.testing.expectEqual(Vec2f{ .x = 0, .y = 0 }, none.size);
}
