//! Shared canvas transforms, picking, and screen-tolerance snapping.
const std = @import("std");
const mesha = @import("mesha");
const math = mesha.math;
const Atom = mesha.Atom;
const panels_mod = mesha.panels;
const figure = mesha.figure;
const session = @import("session.zig");

// The figure stage's chrome and its usable canvas share this policy with global input bounds.
// Layers, Properties and the sequencer are panels of their own beside it.
pub const header_height: f32 = 40;
pub const options_height: f32 = 34;
const status_height: f32 = 28;

pub const StageLayout = struct {
    header: panels_mod.Rect = .{},
    options: panels_mod.Rect = .{},
    canvas: panels_mod.Rect = .{},
    status: panels_mod.Rect = .{},
};

pub const FocusMode = enum { off, on };
pub const StageChrome = struct { focus: FocusMode = .off };

/// Pass either the stage's local content rectangle for rendering or its global one for input.
/// Chrome takes its rows first; a tiny stage has an empty, never negative canvas. In focus mode
/// the canvas is the whole stage.
pub fn stageLayout(stage: panels_mod.Rect, chrome: StageChrome) StageLayout {
    if (!std.math.isFinite(stage.x) or !std.math.isFinite(stage.y) or
        !std.math.isFinite(stage.w) or !std.math.isFinite(stage.h)) return .{};
    const width = @max(0, stage.w);
    const height = @max(0, stage.h);
    if (chrome.focus == .on) return .{ .canvas = .{ .x = stage.x, .y = stage.y, .w = width, .h = height } };
    const status_size = @min(status_height, height);
    const body_height = height - status_size;
    const header_size = @min(header_height, body_height);
    const options_size = @min(options_height, body_height - header_size);
    const canvas_y = stage.y + header_size + options_size;
    return .{
        .header = .{ .x = stage.x, .y = stage.y, .w = width, .h = header_size },
        .options = .{ .x = stage.x, .y = stage.y + header_size, .w = width, .h = options_size },
        .canvas = .{ .x = stage.x, .y = canvas_y, .w = width, .h = body_height - header_size - options_size },
        .status = .{ .x = stage.x, .y = stage.y + body_height, .w = width, .h = status_size },
    };
}

/// `region` less `hole`, as up to four rectangles. Pointer capture owns its whole rectangle, so
/// a control floating over the canvas keeps its clicks only by being left out of the capture.
pub fn subtractRect(region: panels_mod.Rect, hole: panels_mod.Rect) [4]panels_mod.Rect {
    const left = @max(region.x, hole.x);
    const right = @min(region.x + region.w, hole.x + hole.w);
    const top = @max(region.y, hole.y);
    const bottom = @min(region.y + region.h, hole.y + hole.h);
    if (right <= left or bottom <= top) return .{ region, .{}, .{}, .{} };
    return .{
        .{ .x = region.x, .y = region.y, .w = region.w, .h = top - region.y },
        .{ .x = region.x, .y = bottom, .w = region.w, .h = region.y + region.h - bottom },
        .{ .x = region.x, .y = top, .w = left - region.x, .h = bottom - top },
        .{ .x = right, .y = top, .w = region.x + region.w - right, .h = bottom - top },
    };
}

// Camera transforms.
pub const minimum_zoom: f32 = 0.02;
pub const maximum_zoom: f32 = 256;

/// Zoom is actual pixels per document unit; 1 is 100%, independently of viewport size.
pub fn affine(rect: panels_mod.Rect, center: session.Vec2, zoom: f32) math.Affine2f {
    return math.Affine2f.fromTRS(rect.x + rect.w * 0.5 - center.x * zoom, rect.y + rect.h * 0.5 - center.y * zoom, 0, zoom, zoom);
}

/// The transform the canvas draws the figure under: `context`, the drawing context's transform
/// where the canvas's panel content begins, then the camera over `rect`, the canvas in that
/// content's space. `canvas.render` installs it, and the figure's watches prepare their drawings
/// for it, so both must come from here to agree.
pub fn drawTransform(context: math.Affine2f, rect: panels_mod.Rect, center: session.Vec2, zoom: f32) math.Affine2f {
    const camera = affine(rect, center, zoom);
    return context.mul(camera);
}

pub fn toScreen(rect: panels_mod.Rect, center: session.Vec2, zoom: f32, point: session.Vec2) session.Vec2 {
    return .{ .x = rect.x + rect.w * 0.5 + (point.x - center.x) * zoom, .y = rect.y + rect.h * 0.5 + (point.y - center.y) * zoom };
}

pub fn toDocument(rect: panels_mod.Rect, center: session.Vec2, zoom: f32, point: session.Vec2) session.Vec2 {
    return .{ .x = center.x + (point.x - rect.x - rect.w * 0.5) / zoom, .y = center.y + (point.y - rect.y - rect.h * 0.5) / zoom };
}

pub const Camera = struct { center: session.Vec2, zoom: f32 };

/// Frames `extent` with a margin. A figure that draws nothing has no extent, so the view
/// shows its origin at 100%.
pub fn fit(rect: panels_mod.Rect, extent: ?figure.Bounds) Camera {
    const box = extent orelse return .{ .center = session.zero, .zoom = 1 };
    const center = math.Vec2f.scale(math.Vec2f.add(box.min, box.max), 0.5);
    // A proportional breathing margin is separate from the already-excluded chrome.
    const available_width = @max(0, rect.w) * 0.88;
    const available_height = @max(0, rect.h) * 0.88;
    // A flat figure, such as one line, still fits along its other axis.
    const width_zoom = available_width / @max(box.max.x - box.min.x, 1);
    const height_zoom = available_height / @max(box.max.y - box.min.y, 1);
    const fitted_zoom = @min(width_zoom, height_zoom);
    const zoom = std.math.clamp(fitted_zoom, minimum_zoom, maximum_zoom);
    return .{ .center = center, .zoom = zoom };
}

pub fn zoomAt(rect: panels_mod.Rect, center: session.Vec2, old_zoom: f32, zoom: f32, pointer: session.Vec2) session.Vec2 {
    const document_before_zoom = toDocument(rect, center, old_zoom, pointer);
    const document_after_zoom = toDocument(rect, center, zoom, pointer);
    const zoom_offset = math.Vec2f.sub(document_after_zoom, center);
    return math.Vec2f.sub(document_before_zoom, zoom_offset);
}

pub fn gridStep(zoom: f32) f32 {
    var step: f32 = 10;
    while (step * zoom < 8) step *= 2;
    return step;
}

pub fn contains(rect: panels_mod.Rect, point: session.Vec2) bool {
    return point.x >= rect.x and point.y >= rect.y and point.x < rect.x + rect.w and point.y < rect.y + rect.h;
}

test "focus mode gives the canvas the whole stage" {
    const stage = panels_mod.Rect{ .x = 120, .y = 50, .w = 900, .h = 650 };
    const focused = stageLayout(stage, .{ .focus = .on });
    try std.testing.expectEqual(stage, focused.canvas);
    try std.testing.expectEqual(@as(f32, 0), focused.header.h + focused.options.h + focused.status.h);
}

test "view inverse, pointer anchored zoom, and adaptive grid are screen independent" {
    const rect = panels_mod.Rect{ .x = 120, .y = 50, .w = 700, .h = 400 };
    const center = session.Vec2{ .x = 25, .y = -10 };
    const point = session.Vec2{ .x = 120, .y = 85 };
    const screen = toScreen(rect, center, 2.5, point);
    const transformed = affine(rect, center, 2.5).apply(point);
    try std.testing.expectApproxEqAbs(screen.x, transformed.x, 1e-4);
    try std.testing.expectApproxEqAbs(screen.y, transformed.y, 1e-4);
    const back = toDocument(rect, center, 2.5, screen);
    try std.testing.expectApproxEqAbs(point.x, back.x, 1e-4);
    try std.testing.expectApproxEqAbs(point.y, back.y, 1e-4);
    const anchored = zoomAt(rect, center, 2.5, 5, screen);
    const again = toScreen(rect, anchored, 5, point);
    try std.testing.expectApproxEqAbs(screen.x, again.x, 1e-4);
    try std.testing.expectApproxEqAbs(screen.y, again.y, 1e-4);
    try std.testing.expect(gridStep(0.05) * 0.05 >= 8);
}

test "drawing stage layout shares local and global camera bounds and fit" {
    const stage = panels_mod.Rect{ .x = 120, .y = 50, .w = 900, .h = 650 };
    const global = stageLayout(stage, .{});
    const local = stageLayout(.{ .w = stage.w, .h = stage.h }, .{});
    // The whole stage's width, below the header and options and above the status line;
    // Layers and Properties are panels of their own.
    const expected = panels_mod.Rect{ .x = 120, .y = 124, .w = 900, .h = 548 };
    try std.testing.expectEqualDeep(expected, global.canvas);
    try std.testing.expectEqual(global.canvas.x, local.canvas.x + stage.x);
    try std.testing.expectEqual(global.canvas.y, local.canvas.y + stage.y);
    try std.testing.expectEqual(global.canvas.w, local.canvas.w);
    try std.testing.expectEqual(global.canvas.h, local.canvas.h);
    try std.testing.expectEqual(global.canvas.y, global.options.y + global.options.h);

    const document_start = session.Vec2{ .x = -10, .y = -20 };
    const document_end = session.Vec2{ .x = 390, .y = 180 };
    const camera = fit(global.canvas, .{ .min = document_start, .max = document_end });
    const start = toScreen(global.canvas, camera.center, camera.zoom, document_start);
    const end = toScreen(global.canvas, camera.center, camera.zoom, document_end);
    try std.testing.expect(start.x > global.canvas.x and start.y > global.canvas.y);
    try std.testing.expect(end.x < global.canvas.x + global.canvas.w);
    try std.testing.expect(end.y < global.canvas.y + global.canvas.h);
    const local_start = toScreen(local.canvas, camera.center, camera.zoom, document_start);
    try std.testing.expectApproxEqAbs(start.x, local_start.x + stage.x, 1e-4);
    try std.testing.expectApproxEqAbs(start.y, local_start.y + stage.y, 1e-4);
    const restored = toDocument(global.canvas, camera.center, camera.zoom, start);
    try std.testing.expectApproxEqAbs(document_start.x, restored.x, 1e-4);
    try std.testing.expectApproxEqAbs(document_start.y, restored.y, 1e-4);
}

test "drawing stage layout clamps short and empty viewports without overlapping chrome" {
    const stages = [_]panels_mod.Rect{
        .{ .x = 17, .y = 19, .w = 0, .h = 800 },
        .{ .x = 17, .y = 19, .w = 40, .h = 80 },
        .{ .x = 17, .y = 19, .w = 800, .h = 30 },
        .{ .x = 17, .y = 19, .w = 800, .h = 80 },
        .{ .x = 17, .y = 19, .w = 800, .h = 102 },
    };
    for (stages) |stage| {
        const layout = stageLayout(stage, .{});
        const regions = [_]panels_mod.Rect{ layout.header, layout.options, layout.canvas };
        for (regions) |region| {
            try std.testing.expect(region.w >= 0 and region.h >= 0);
            try std.testing.expect(region.x >= stage.x and region.y >= stage.y);
            try std.testing.expect(region.x + region.w <= stage.x + stage.w);
            try std.testing.expect(region.y + region.h <= stage.y + stage.h);
        }
        try std.testing.expectEqual(layout.options.y + layout.options.h, layout.canvas.y);
    }
    const invalid_width = std.math.nan(f32);
    const invalid = stageLayout(.{ .w = invalid_width, .h = 100 }, .{});
    try std.testing.expectEqualDeep(StageLayout{}, invalid);
}

// Bounds and picking.
pub const Hit = struct { kind: Atom, id: u32, sub: u32 = 0, point: session.Vec2 };

pub const Bounds = struct {
    min: session.Vec2,
    max: session.Vec2,
    pub fn center(self: Bounds) session.Vec2 {
        return .{ .x = (self.min.x + self.max.x) * 0.5, .y = (self.min.y + self.max.y) * 0.5 };
    }
    pub fn intersects(self: Bounds, other: Bounds) bool {
        return self.max.x >= other.min.x and self.min.x <= other.max.x and self.max.y >= other.min.y and self.min.y <= other.max.y;
    }
};

pub const ScaleHandle = enum(u8) { none, top_left, top, top_right, right, bottom_right, bottom, bottom_left, left };
pub const scale_handles = [_]ScaleHandle{ .top_left, .top, .top_right, .right, .bottom_right, .bottom, .bottom_left, .left };

pub fn scaleHandlePoint(box: Bounds, handle: ScaleHandle) session.Vec2 {
    const center = box.center();
    return switch (handle) {
        .top_left => box.min,
        .top => .{ .x = center.x, .y = box.min.y },
        .top_right => .{ .x = box.max.x, .y = box.min.y },
        .right => .{ .x = box.max.x, .y = center.y },
        .bottom_right => box.max,
        .bottom => .{ .x = center.x, .y = box.max.y },
        .bottom_left => .{ .x = box.min.x, .y = box.max.y },
        .left => .{ .x = box.min.x, .y = center.y },
        .none => center,
    };
}

/// Collapsed axes have no scale extent; omit overlapping handles so the pivot
/// remains reachable on a horizontal or vertical path.
pub fn scaleHandleEnabled(box: Bounds, handle: ScaleHandle) bool {
    if (handle == .none) return false;
    const width = box.max.x - box.min.x;
    const height = box.max.y - box.min.y;
    if (width <= 1e-6 and height <= 1e-6) return false;
    if (width <= 1e-6) return handle == .top or handle == .bottom;
    if (height <= 1e-6) return handle == .left or handle == .right;
    return true;
}

/// Resize handles keep a 14 px hit square at every zoom level.
pub fn pickScaleHandle(box: Bounds, point: session.Vec2, zoom: f32) ScaleHandle {
    for (scale_handles) |handle| {
        if (!scaleHandleEnabled(box, handle)) continue;
        const location = scaleHandlePoint(box, handle);
        if (@abs(location.x - point.x) * zoom <= 7 and @abs(location.y - point.y) * zoom <= 7) return handle;
    }
    return .none;
}

pub const rotation_handles = [_]ScaleHandle{ .top_left, .top_right, .bottom_right, .bottom_left };

pub fn rotationHandlePoint(box: Bounds, corner: ScaleHandle, zoom: f32) session.Vec2 {
    const point = scaleHandlePoint(box, corner);
    const offset = 12 / zoom;
    const left = corner == .top_left or corner == .bottom_left;
    const top = corner == .top_left or corner == .top_right;
    return .{ .x = point.x + if (left) -offset else offset, .y = point.y + if (top) -offset else offset };
}

pub fn segmentDistance(point: session.Vec2, start: session.Vec2, end: session.Vec2) f32 {
    const delta = math.Vec2f.sub(end, start);
    const relative = math.Vec2f.sub(point, start);
    const length_squared = delta.x * delta.x + delta.y * delta.y;
    const fraction = if (length_squared == 0) 0 else std.math.clamp((relative.x * delta.x + relative.y * delta.y) / length_squared, 0, 1);
    const segment_offset = math.Vec2f.scale(delta, fraction);
    const closest_point = math.Vec2f.add(start, segment_offset);
    return distance(point, closest_point);
}

pub fn pickJoint(world: anytype, point: session.Vec2, zoom: f32) ?Hit {
    var best: ?Hit = null;
    var best_distance: f32 = 8 / zoom;
    for (world) |bone| {
        const tip = distance(point, bone.tip);
        if (tip <= best_distance) {
            best_distance = tip;
            best = .{ .kind = Atom.from("bone"), .id = bone.id, .sub = 1, .point = bone.tip };
        }
        if (bone.parent == 0) {
            const root = distance(point, bone.origin);
            if (root < best_distance) {
                best_distance = root;
                best = .{ .kind = Atom.from("bone"), .id = bone.id, .sub = 0, .point = bone.origin };
            }
        }
    }
    return best;
}

pub fn pickBone(world: anytype, point: session.Vec2, zoom: f32) ?Hit {
    if (pickJoint(world, point, zoom)) |hit| return hit;
    var best: ?Hit = null;
    var best_distance: f32 = 8 / zoom;
    for (world) |bone| {
        const segment_distance = segmentDistance(point, bone.origin, bone.tip);
        if (segment_distance <= best_distance) {
            best_distance = segment_distance;
            best = .{ .kind = Atom.from("bone"), .id = bone.id, .sub = 2, .point = point };
        }
    }
    return best;
}

pub fn bounds(points: []const session.Vec2) ?Bounds {
    if (points.len == 0) return null;
    var result = Bounds{ .min = points[0], .max = points[0] };
    for (points[1..]) |p| {
        result.min.x = @min(result.min.x, p.x);
        result.min.y = @min(result.min.y, p.y);
        result.max.x = @max(result.max.x, p.x);
        result.max.y = @max(result.max.y, p.y);
    }
    return result;
}

test "segment distance handles degenerate segments" {
    const result = segmentDistance(.{ .x = 3, .y = 4 }, session.zero, session.zero);
    try std.testing.expectEqual(@as(f32, 5), result);
}

// Screen-space snapping.
pub const SnapKind = enum { none, joint, midpoint, axis, length, grid };

pub const SnapOptions = struct {
    joints: bool = true,
    midpoints: bool = true,
    axes: bool = true,
    lengths: bool = true,
    grid: ?f32 = null,
};
pub const SnapMode = enum { enabled, bypass };

pub const Snap = struct { point: session.Vec2, kind: SnapKind = .none, id: u32 = 0 };

pub const MoveConstraint = enum { none, axis };

pub fn moveDelta(origin: session.Vec2, point: session.Vec2, constraint: MoveConstraint) session.Vec2 {
    var delta = math.Vec2f.sub(point, origin);
    if (constraint == .axis) {
        if (@abs(delta.x) >= @abs(delta.y)) delta.y = 0 else delta.x = 0;
    }
    return delta;
}

pub fn distance(a: session.Vec2, b: session.Vec2) f32 {
    const d = math.Vec2f.sub(a, b);
    return @sqrt(d.x * d.x + d.y * d.y);
}

const Search = struct {
    pointer: session.Vec2,
    zoom: f32,
    previous: Snap,
    best: Snap,
    best_distance: f32 = 8,
    fn offer(self: *Search, candidate: Snap) void {
        const d = distance(candidate.point, self.pointer) * self.zoom;
        const sticky = candidate.kind == self.previous.kind and candidate.id == self.previous.id;
        if (d > (if (sticky) @as(f32, 12) else 8)) return;
        if (self.best.kind == .none or
            @intFromEnum(candidate.kind) < @intFromEnum(self.best.kind) or
            (candidate.kind == self.best.kind and d < self.best_distance))
        {
            self.best = candidate;
            self.best_distance = d;
        }
    }
};

/// Screen-space candidates change position, never connectivity. Holding Alt bypasses all candidates.
pub fn snapEndpoint(origin: session.Vec2, pointer: session.Vec2, zoom: f32, bones: []const figure.EvaluatedBone, options: SnapOptions, previous: Snap, mode: SnapMode) Snap {
    if (mode == .bypass) return .{ .point = pointer };
    var search = Search{ .pointer = pointer, .zoom = zoom, .previous = previous, .best = .{ .point = pointer } };
    const delta = math.Vec2f.sub(pointer, origin);
    const length = distance(pointer, origin);
    for (bones) |bone| {
        if (options.joints) {
            search.offer(.{ .point = bone.origin, .kind = .joint, .id = bone.id *% 2 });
            search.offer(.{ .point = bone.tip, .kind = .joint, .id = bone.id *% 2 +% 1 });
        }
        if (options.midpoints) {
            const endpoint_sum = math.Vec2f.add(bone.origin, bone.tip);
            const midpoint = math.Vec2f.scale(endpoint_sum, 0.5);
            search.offer(.{ .point = midpoint, .kind = .midpoint, .id = bone.id });
        }
        if (options.lengths and length > 1e-6) {
            const bone_length = distance(bone.origin, bone.tip);
            const scaled_delta = math.Vec2f.scale(delta, bone_length / length);
            const length_point = math.Vec2f.add(origin, scaled_delta);
            search.offer(.{ .point = length_point, .kind = .length, .id = bone.id });
        }
    }
    if (options.axes and length > 1e-6) {
        const step = std.math.pi / 4.0;
        const angle = @round(std.math.atan2(delta.y, delta.x) / step) * step;
        search.offer(.{
            .point = math.Vec2f.add(origin, .{ .x = @cos(angle) * length, .y = @sin(angle) * length }),
            .kind = .axis,
            .id = @intFromFloat(@round((angle + std.math.pi) / step)),
        });
    }
    if (options.grid) |step| if (step > 0) {
        if (previous.kind == .grid) search.offer(previous);
        search.offer(.{ .point = .{ .x = @round(pointer.x / step) * step, .y = @round(pointer.y / step) * step }, .kind = .grid });
    };
    return search.best;
}

test "axis and grid snapping use screen tolerance and Alt bypass" {
    const original = session.Vec2{ .x = 100, .y = 3 };
    const snapped = snapEndpoint(session.zero, original, 1, &.{}, .{ .grid = 10 }, .{ .point = original }, .enabled);
    try std.testing.expectEqual(SnapKind.axis, snapped.kind);
    try std.testing.expectApproxEqAbs(@as(f32, 0), snapped.point.y, 1e-4);
    const bypassed = snapEndpoint(session.zero, original, 1, &.{}, .{ .grid = 10 }, snapped, .bypass);
    try std.testing.expectEqual(original, bypassed.point);
    const far = snapEndpoint(session.zero, .{ .x = 100, .y = 20 }, 10, &.{}, .{}, snapped, .enabled);
    try std.testing.expectEqual(SnapKind.none, far.kind);
}

test "snapping disabled candidates cannot retain the previous snap" {
    const pointer = session.Vec2{ .x = 100, .y = 3 };
    const previous = Snap{ .point = .{ .x = 100, .y = 0 }, .kind = .axis, .id = 4 };
    const unsnapped = snapEndpoint(session.zero, pointer, 1, &.{}, .{ .axes = false }, previous, .enabled);
    try std.testing.expectEqual(SnapKind.none, unsnapped.kind);
    try std.testing.expectEqual(pointer, unsnapped.point);
    const grid = snapEndpoint(session.zero, pointer, 1, &.{}, .{ .axes = false, .grid = 10 }, previous, .enabled);
    try std.testing.expectEqual(SnapKind.grid, grid.kind);
    const grid_off = snapEndpoint(session.zero, pointer, 1, &.{}, .{ .axes = false }, grid, .enabled);
    try std.testing.expectEqual(SnapKind.none, grid_off.kind);
    try std.testing.expectEqual(pointer, grid_off.point);
}
