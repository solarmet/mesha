//! Small marks drawn as paths, for controls whose glyph no icon atlas holds: a chevron that
//! opens and closes a section, a status dot, a filter field's magnifier and clear cross, a
//! menu's dots, a list's scroll bar and a share of a whole as a bar.
//!
//! Each mark is a value with a `draw` that `ui.Tree.custom` calls when the tree is committed,
//! centred in the rect it is given. `place` copies a mark into the tree's frame and records it
//! as a fixed-width leaf as tall as its row:
//!
//!     marks.place(tree, "list.chevron", marks.Chevron{ .direction = .down, .color = color }, 12);
//!
//! A caller that wants another size records its own copy with `ui.Tree.custom`. Nothing here
//! keeps anything between calls or touches a table.
const std = @import("std");
const math = @import("../core/math.zig");
const roop = @import("../systems/roop.zig");
const ui = @import("ui.zig");

/// The way a `Chevron` points.
pub const ChevronDirection = enum { right, down, left, up };

/// A section's open state: right while closed, down while open; left collapses a column.
pub const Chevron = struct {
    /// The way the chevron points.
    direction: ChevronDirection,
    /// The colour of its stroke.
    color: ui.Color,

    /// Strokes the chevron, 7 pixels across, about the centre of a rect of `size`, in `ctx`'s
    /// space with the rect's top left corner at its origin, as `ui.Tree.custom` calls it.
    pub fn draw(self: *const Chevron, size: math.Vec2f, ctx: *roop.Context) void {
        const center_x = size.x * 0.5;
        const center_y = size.y * 0.5;
        const reach: f32 = 3.5;
        ctx.beginPath();
        switch (self.direction) {
            .right => {
                ctx.moveTo(center_x - reach * 0.5, center_y - reach);
                ctx.lineTo(center_x + reach * 0.5, center_y);
                ctx.lineTo(center_x - reach * 0.5, center_y + reach);
            },
            .left => {
                ctx.moveTo(center_x + reach * 0.5, center_y - reach);
                ctx.lineTo(center_x - reach * 0.5, center_y);
                ctx.lineTo(center_x + reach * 0.5, center_y + reach);
            },
            .down => {
                ctx.moveTo(center_x - reach, center_y - reach * 0.5);
                ctx.lineTo(center_x, center_y + reach * 0.5);
                ctx.lineTo(center_x + reach, center_y - reach * 0.5);
            },
            .up => {
                ctx.moveTo(center_x - reach, center_y + reach * 0.5);
                ctx.lineTo(center_x, center_y - reach * 0.5);
                ctx.lineTo(center_x + reach, center_y + reach * 0.5);
            },
        }
        ctx.strokeColor(self.color);
        ctx.strokeWidth(1.5);
        ctx.lineCap(.round);
        ctx.lineJoin(.round);
        ctx.stroke();
    }
};

/// How a `Dot` is painted.
pub const DotFill = enum {
    /// A filled disc.
    solid,
    /// The disc's outline only.
    ring,
};

/// A status light: solid for a state that holds, a ring for one that is off.
pub const Dot = struct {
    /// The colour of the disc or its ring.
    color: ui.Color,
    /// Whether the disc is filled or only outlined.
    fill: DotFill = .solid,
    /// The disc's radius, in pixels.
    radius: f32 = 3.5,

    /// Paints the dot at the centre of a rect of `size`, in `ctx`'s space with the rect's top
    /// left corner at its origin, as `ui.Tree.custom` calls it.
    pub fn draw(self: *const Dot, size: math.Vec2f, ctx: *roop.Context) void {
        ctx.beginPath();
        ctx.circle(size.x * 0.5, size.y * 0.5, self.radius);
        switch (self.fill) {
            .solid => {
                ctx.fillColor(self.color);
                ctx.fill();
            },
            .ring => {
                ctx.strokeColor(self.color);
                ctx.strokeWidth(1.2);
                ctx.stroke();
            },
        }
    }
};

/// A magnifying glass, for a filter field's leading mark.
pub const Magnifier = struct {
    /// The colour of its stroke.
    color: ui.Color,

    /// Strokes the glass, its lens a little up and left of the centre of a rect of `size` and
    /// its handle down and right, in `ctx`'s space with the rect's top left corner at its
    /// origin, as `ui.Tree.custom` calls it.
    pub fn draw(self: *const Magnifier, size: math.Vec2f, ctx: *roop.Context) void {
        const center_x = size.x * 0.5 - 1.5;
        const center_y = size.y * 0.5 - 1.5;
        const radius: f32 = 4.5;
        ctx.beginPath();
        ctx.circle(center_x, center_y, radius);
        ctx.strokeColor(self.color);
        ctx.strokeWidth(1.4);
        ctx.stroke();
        ctx.beginPath();
        ctx.moveTo(center_x + radius * 0.72, center_y + radius * 0.72);
        ctx.lineTo(center_x + radius * 0.72 + 4, center_y + radius * 0.72 + 4);
        ctx.lineCap(.round);
        ctx.stroke();
    }
};

/// Three dots in a column, for a control that opens a menu.
pub const Dots = struct {
    /// The colour of the dots.
    color: ui.Color,

    /// Fills the three dots, 9 pixels from the first to the last, about the centre of a rect
    /// of `size`, in `ctx`'s space with the rect's top left corner at its origin, as
    /// `ui.Tree.custom` calls it.
    pub fn draw(self: *const Dots, size: math.Vec2f, ctx: *roop.Context) void {
        const center_x = size.x * 0.5;
        const center_y = size.y * 0.5;
        for ([_]f32{ -4.5, 0, 4.5 }) |offset| {
            ctx.beginPath();
            ctx.circle(center_x, center_y + offset, 1.4);
            ctx.fillColor(self.color);
            ctx.fill();
        }
    }
};

/// An x, for a control that clears or closes.
pub const Cross = struct {
    /// The colour of its stroke.
    color: ui.Color,

    /// Strokes the x, 7 pixels across, about the centre of a rect of `size`, in `ctx`'s space
    /// with the rect's top left corner at its origin, as `ui.Tree.custom` calls it.
    pub fn draw(self: *const Cross, size: math.Vec2f, ctx: *roop.Context) void {
        const center_x = size.x * 0.5;
        const center_y = size.y * 0.5;
        const reach: f32 = 3.5;
        ctx.beginPath();
        ctx.moveTo(center_x - reach, center_y - reach);
        ctx.lineTo(center_x + reach, center_y + reach);
        ctx.moveTo(center_x + reach, center_y - reach);
        ctx.lineTo(center_x - reach, center_y + reach);
        ctx.strokeColor(self.color);
        ctx.strokeWidth(1.4);
        ctx.lineCap(.round);
        ctx.stroke();
    }
};

/// Records `drawable`, a mark of this file or any value with a `draw` as `ui.Tree.custom`
/// takes, as a leaf `width` pixels wide filling its row's height, under the element id `id`.
/// The mark is copied into the tree's frame allocator, so it lives as long as the tree; when
/// the frame has no room for it, nothing is recorded. The tree must have room for one more
/// element.
pub fn place(tree: *ui.Tree, id: anytype, drawable: anytype, width: f32) void {
    const object = tree.frame_allocator.allocator.create(@TypeOf(drawable)) catch return;
    object.* = drawable;
    tree.custom(id, object, .{ .size = .{ .w = .{ .fixed = width }, .h = .fill } });
}

/// A list's scroll position: a thumb as long as the share of rows shown, at their place.
pub const ScrollBar = struct {
    /// The position of the first row shown.
    first: usize,
    /// How many rows are shown.
    visible: usize,
    /// How many rows the list has.
    total: usize,

    /// Paints a 4-pixel track down the middle of a rect of `size` and the thumb on it, at
    /// least 12 pixels long, in `ctx`'s space with the rect's top left corner at its origin, as
    /// `ui.Tree.custom` calls it. Paints nothing while every row is shown.
    pub fn draw(self: *const ScrollBar, size: math.Vec2f, ctx: *roop.Context) void {
        if (self.total <= self.visible or self.total == 0) return;
        const total: f32 = @floatFromInt(self.total);
        const length = @max(size.y * @as(f32, @floatFromInt(self.visible)) / total, 12);
        const top = (size.y - length) * @as(f32, @floatFromInt(self.first)) / @max(total - @as(f32, @floatFromInt(self.visible)), 1);
        ctx.beginPath();
        ctx.roundedRect(size.x * 0.5 - 2, 0, 4, size.y, 2);
        ctx.fillColor(ui.rgba(255, 255, 255, 12));
        ctx.fill();
        ctx.beginPath();
        ctx.roundedRect(size.x * 0.5 - 2, top, 4, length, 2);
        ctx.fillColor(ui.rgba(255, 255, 255, 70));
        ctx.fill();
    }
};

/// A share of a whole as a bar across the cell's width, under nothing but itself.
pub const ShareBar = struct {
    /// The share, 0 to 1; a value outside is taken as the nearer end.
    fraction: f32,
    /// The colour of the filled part.
    color: ui.Color,

    /// Paints a 6-pixel track across a rect of `size`, 2 pixels in from each side and
    /// centred down it, and fills `fraction` of it from the left, in `ctx`'s space with the
    /// rect's top left corner at its origin, as `ui.Tree.custom` calls it.
    pub fn draw(self: *const ShareBar, size: math.Vec2f, ctx: *roop.Context) void {
        const height: f32 = 6;
        const y = (size.y - height) * 0.5;
        ctx.beginPath();
        ctx.roundedRect(2, y, size.x - 4, height, 3);
        ctx.fillColor(ui.rgba(255, 255, 255, 14));
        ctx.fill();
        const filled = (size.x - 4) * std.math.clamp(self.fraction, 0, 1);
        if (filled < 1) return;
        ctx.beginPath();
        ctx.roundedRect(2, y, filled, height, 3);
        ctx.fillColor(self.color);
        ctx.fill();
    }
};
