//! A 2D camera: the mapping between world coordinates and the pixels of the viewport that
//! shows them, for a stage that pans and zooms.
//!
//! Both spaces have +X right and +Y down. The camera's `position` is the world point at the
//! viewport's center, and `zoom` is how many viewport pixels a world unit covers. Screen
//! coordinates are relative to the viewport's top-left corner, not the window's. Pure
//! arithmetic: usable from a kernel, a plugin or the host.
const std = @import("std");
const math = @import("math.zig");
const Vec2f = math.Vec2f;

/// Why a camera or a coordinate was refused by `Camera2D.validate` and the checked
/// conversions.
pub const ValidationError = error{
    /// The camera's position or viewport size has a NaN or infinite component.
    NonFiniteCamera,
    /// The viewport's width or height is negative. Zero is allowed.
    InvalidViewport,
    /// The zoom is zero, negative, NaN or infinite.
    InvalidZoom,
    /// The point to convert has a NaN or infinite component.
    NonFiniteCoordinate,
    /// The camera and the point are valid, but the converted point overflows `f32`.
    UnrepresentableResult,
};

/// A camera over a 2D world: where it looks, how large its viewport is and how far it is
/// zoomed. A plain value; copy it freely.
pub const Camera2D = struct {
    /// The world point shown at the center of the viewport, in world units.
    position: Vec2f = .{ .x = 0, .y = 0 },

    /// The viewport's width and height in pixels.
    viewport_size: Vec2f = .{ .x = 1920, .y = 1080 },

    /// Viewport pixels per world unit; must be positive. 2 shows the world twice as large.
    zoom: f32 = 1.0,

    /// Checks that the conversions are defined for this camera: finite position and viewport
    /// (`NonFiniteCamera`), a viewport that is not negative (`InvalidViewport`), and a finite,
    /// positive zoom (`InvalidZoom`).
    pub fn validate(self: Camera2D) ValidationError!void {
        if (!finite(self.position.x) or !finite(self.position.y) or
            !finite(self.viewport_size.x) or !finite(self.viewport_size.y)) return error.NonFiniteCamera;
        if (self.viewport_size.x < 0 or self.viewport_size.y < 0) return error.InvalidViewport;
        if (!finite(self.zoom) or self.zoom <= 0) return error.InvalidZoom;
    }

    /// The viewport pixel, relative to the viewport's top-left corner, that shows the world
    /// point `world_pos`. Unchecked; the result may lie outside the viewport.
    pub fn worldToScreen(self: Camera2D, world_pos: Vec2f) Vec2f {
        return .{
            .x = (world_pos.x - self.position.x) * self.zoom + self.viewport_size.x / 2.0,
            .y = (world_pos.y - self.position.y) * self.zoom + self.viewport_size.y / 2.0,
        };
    }

    /// The world point shown at the viewport pixel `screen_pos`, relative to the viewport's
    /// top-left corner. Unchecked: a zero zoom gives non-finite results.
    pub fn screenToWorld(self: Camera2D, screen_pos: Vec2f) Vec2f {
        const inv_zoom = 1.0 / self.zoom;
        return .{
            .x = (screen_pos.x - self.viewport_size.x / 2.0) * inv_zoom + self.position.x,
            .y = (screen_pos.y - self.viewport_size.y / 2.0) * inv_zoom + self.position.y,
        };
    }

    /// `worldToScreen`, refusing a camera `validate` refuses, a non-finite `world_pos`
    /// (`NonFiniteCoordinate`) and a result that is not finite (`UnrepresentableResult`).
    pub fn worldToScreenChecked(self: Camera2D, world_pos: Vec2f) ValidationError!Vec2f {
        try self.validate();
        if (!finite(world_pos.x) or !finite(world_pos.y)) return error.NonFiniteCoordinate;
        const result = self.worldToScreen(world_pos);
        if (!finite(result.x) or !finite(result.y)) return error.UnrepresentableResult;
        return result;
    }

    /// `screenToWorld`, refusing a camera `validate` refuses, a non-finite `screen_pos`
    /// (`NonFiniteCoordinate`) and a result that is not finite (`UnrepresentableResult`).
    pub fn screenToWorldChecked(self: Camera2D, screen_pos: Vec2f) ValidationError!Vec2f {
        try self.validate();
        if (!finite(screen_pos.x) or !finite(screen_pos.y)) return error.NonFiniteCoordinate;
        const result = self.screenToWorld(screen_pos);
        if (!finite(result.x) or !finite(result.y)) return error.UnrepresentableResult;
        return result;
    }

    /// The world rectangle the viewport shows: `min` its top-left corner and `max` its
    /// bottom-right, in world units. Unchecked, as `screenToWorld` is.
    pub fn visibleWorldBounds(self: Camera2D) struct { min: Vec2f, max: Vec2f } {
        const top_left = self.screenToWorld(.{ .x = 0, .y = 0 });
        const bottom_right = self.screenToWorld(self.viewport_size);
        return .{
            .min = .{
                .x = @min(top_left.x, bottom_right.x),
                .y = @min(top_left.y, bottom_right.y),
            },
            .max = .{
                .x = @max(top_left.x, bottom_right.x),
                .y = @max(top_left.y, bottom_right.y),
            },
        };
    }
};

fn finite(value: f32) bool {
    return std.math.isFinite(value);
}

const testing = std.testing;

test "Camera2D worldToScreen and screenToWorld default center" {
    const cam = Camera2D{
        .position = .{ .x = 0, .y = 0 },
        .viewport_size = .{ .x = 1920, .y = 1080 },
        .zoom = 1.0,
    };

    const screen_center = cam.worldToScreen(.{ .x = 0, .y = 0 });
    try testing.expectEqual(@as(f32, 960), screen_center.x);
    try testing.expectEqual(@as(f32, 540), screen_center.y);

    const world_center = cam.screenToWorld(screen_center);
    try testing.expectEqual(@as(f32, 0), world_center.x);
    try testing.expectEqual(@as(f32, 0), world_center.y);
}

test "Camera2D panning" {
    const cam = Camera2D{
        .position = .{ .x = 100, .y = -50 },
        .viewport_size = .{ .x = 1920, .y = 1080 },
        .zoom = 1.0,
    };

    const screen_center = cam.worldToScreen(.{ .x = 100, .y = -50 });
    try testing.expectEqual(@as(f32, 960), screen_center.x);
    try testing.expectEqual(@as(f32, 540), screen_center.y);

    const world_origin = cam.worldToScreen(.{ .x = 0, .y = 0 });
    try testing.expectEqual(@as(f32, 860), world_origin.x);
    try testing.expectEqual(@as(f32, 590), world_origin.y);
}

test "Camera2D zoom and round-trip accuracy" {
    const cam = Camera2D{
        .position = .{ .x = 50, .y = 75 },
        .viewport_size = .{ .x = 800, .y = 600 },
        .zoom = 2.0,
    };

    const world_pt = Vec2f{ .x = 150, .y = 25 };
    const screen_pt = cam.worldToScreen(world_pt);

    try testing.expectEqual(@as(f32, 600), screen_pt.x);
    try testing.expectEqual(@as(f32, 200), screen_pt.y);

    const round_trip = cam.screenToWorld(screen_pt);
    try testing.expectEqual(world_pt.x, round_trip.x);
    try testing.expectEqual(world_pt.y, round_trip.y);
}

test "Camera2D validates zoom and viewport domains before checked transforms" {
    var cam = Camera2D{};
    try cam.validate();
    const screen = try cam.worldToScreenChecked(.{ .x = 12, .y = -4 });
    const world = try cam.screenToWorldChecked(screen);
    try testing.expectEqual(@as(f32, 12), world.x);
    try testing.expectEqual(@as(f32, -4), world.y);

    cam.zoom = 0;
    try testing.expectError(error.InvalidZoom, cam.validate());
    try testing.expectError(error.InvalidZoom, cam.screenToWorldChecked(.{ .x = 0, .y = 0 }));
    cam.zoom = -1;
    try testing.expectError(error.InvalidZoom, cam.validate());
    cam.zoom = 1;
    cam.viewport_size.x = -1;
    try testing.expectError(error.InvalidViewport, cam.validate());
    cam.viewport_size.x = 1;
    cam.position.x = std.math.nan(f32);
    try testing.expectError(error.NonFiniteCamera, cam.validate());
    const valid_camera = Camera2D{};
    try testing.expectError(error.NonFiniteCoordinate, valid_camera.worldToScreenChecked(.{ .x = std.math.inf(f32), .y = 0 }));
}

test "Camera2D visibleWorldBounds" {
    const cam = Camera2D{
        .position = .{ .x = 0, .y = 0 },
        .viewport_size = .{ .x = 1000, .y = 600 },
        .zoom = 1.0,
    };

    const bounds = cam.visibleWorldBounds();
    try testing.expectEqual(@as(f32, -500), bounds.min.x);
    try testing.expectEqual(@as(f32, -300), bounds.min.y);
    try testing.expectEqual(@as(f32, 500), bounds.max.x);
    try testing.expectEqual(@as(f32, 300), bounds.max.y);
}
