//! Turns a path's commands into flattened points and classifies their joins, for `Context.fill` and
//! `Context.stroke`. No triangle is made here: fans, fringes and stroke ribbons are tessellated on
//! the GPU from these points (`draw_list.ShapeArgs`).
const std = @import("std");
const path_mod = @import("path.zig");
const context_mod = @import("context.zig");

const Point = path_mod.Point;
const PointFlag = path_mod.PointFlag;
const SubPath = path_mod.SubPath;
const PathCache = path_mod.PathCache;
const Command = path_mod.Command;
const Winding = path_mod.Winding;
const LineCap = context_mod.LineCap;
const LineJoin = context_mod.LineJoin;

/// Why a path was not flattened.
pub const FlattenError = error{
    /// The tessellation tolerance is not finite or not above zero.
    InvalidTessellationTolerance,
    /// The distance tolerance is not finite or not above zero.
    InvalidDistanceTolerance,
    /// A command holds a coordinate that is not finite.
    NonFiniteCoordinate,
    /// More than `path.kMaxPathCommands` commands.
    TooManyCommands,
    /// More than `path.kMaxPaths` subpaths.
    TooManyPaths,
    /// More than `path.kMaxFlattenedPoints` points.
    TooManyPoints,
};

const kMaxCurveDivisions: u32 = 512;

/// A vertex recorded on the CPU, as text's glyph quads and a fill's cover quad are: uploaded as it
/// is.
pub const Vertex = extern struct {
    /// Position along x, in target pixels.
    x: f32,
    /// Position along y, in target pixels, down from the top.
    y: f32,
    /// Texture coordinate along x, 0 to 1 across the image.
    u: f32,
    /// Texture coordinate along y.
    v: f32,
};

fn ptEquals(ax: f32, ay: f32, bx: f32, by: f32, tol: f32) bool {
    const dx = bx - ax;
    const dy = by - ay;
    return dx * dx + dy * dy < tol * tol;
}

fn distPtSeg(px: f32, py: f32, ax: f32, ay: f32, bx: f32, by: f32) f32 {
    const pqx = bx - ax;
    const pqy = by - ay;
    var dx = px - ax;
    var dy = py - ay;
    const d = pqx * pqx + pqy * pqy;
    var t = pqx * dx + pqy * dy;
    if (d > 0) t /= d;
    t = std.math.clamp(t, 0, 1);
    dx = ax + t * pqx - px;
    dy = ay + t * pqy - py;
    return dx * dx + dy * dy;
}

fn polyArea(pts: []Point) f32 {
    var area: f32 = 0;
    const n = pts.len;
    if (n < 3) return 0;
    var i: usize = 0;
    var j: usize = n - 1;
    while (i < n) : (i += 1) {
        area += pts[j].x * pts[i].y - pts[i].x * pts[j].y;
        j = i;
    }
    return area * 0.5;
}

/// How many segments approximate an arc of `arc` radians at radius `r` so that none strays more
/// than `tol` from it: at least 2, at most 512. Any argument not finite or not above zero gives 2.
pub fn curveDivs(r: f32, arc: f32, tol: f32) u32 {
    if (!std.math.isFinite(r) or !std.math.isFinite(arc) or !std.math.isFinite(tol) or r <= 0 or arc <= 0 or tol <= 0) return 2;
    const da = std.math.acos(std.math.clamp(r / (r + tol), -1.0, 1.0)) * 2.0;
    if (!std.math.isFinite(da) or da <= 0) return 2;
    const divisions = @ceil(arc / da);
    if (!std.math.isFinite(divisions) or divisions >= @as(f32, @floatFromInt(kMaxCurveDivisions))) return kMaxCurveDivisions;
    return @max(2, @as(u32, @intFromFloat(divisions)));
}

fn normalize(x: f32, y: f32) [2]f32 {
    const d = @sqrt(x * x + y * y);
    if (d > 1e-6) return .{ x / d, y / d };
    return .{ 0, 0 };
}

/// Flattens `cmds` into `cache`, replacing what it held and growing it with `allocator`, its
/// owner's. Each `move_to` starts a subpath; a curve is divided until it is within `tess_tol` of
/// its chord (ten levels at most); a point within `dist_tol` of the one before is merged into it.
/// Afterwards each subpath's points are ordered by its winding, each point knows its direction and
/// distance to the next, a closed subpath's repeated last point is dropped, and `cache.bounds`
/// covers every subpath of two points or more. A command before the first `move_to` adds nothing.
/// Errors: any `FlattenError`, checked before `cache` changes except for `TooManyPaths` and
/// `TooManyPoints`, and `OutOfMemory`; after either of those `cache` holds part of the path.
pub fn flattenPaths(
    allocator: std.mem.Allocator,
    cache: *PathCache,
    cmds: []const Command,
    tess_tol: f32,
    dist_tol: f32,
) !void {
    try validateFlattenInputs(cmds, tess_tol, dist_tol);
    cache.reset();

    var last_x: f32 = 0;
    var last_y: f32 = 0;

    for (cmds) |cmd| {
        switch (cmd) {
            .move_to => |p| {
                try addPath(allocator, cache);
                try addPoint(allocator, cache, p[0], p[1], .{ .corner = true }, dist_tol);
                last_x = p[0];
                last_y = p[1];
            },
            .line_to => |p| {
                try addPoint(allocator, cache, p[0], p[1], .{ .corner = true }, dist_tol);
                last_x = p[0];
                last_y = p[1];
            },
            .bezier_to => |b| {
                try tesselateBezier(
                    allocator,
                    cache,
                    last_x,
                    last_y,
                    b[0],
                    b[1],
                    b[2],
                    b[3],
                    b[4],
                    b[5],
                    0,
                    .{ .corner = true },
                    tess_tol,
                    dist_tol,
                );
                last_x = b[4];
                last_y = b[5];
            },
            .close => {
                if (cache.paths.items.len > 0) {
                    cache.paths.items[cache.paths.items.len - 1].closed = true;
                }
            },
            .winding => |w| {
                if (cache.paths.items.len > 0) {
                    cache.paths.items[cache.paths.items.len - 1].winding = w;
                }
            },
        }
    }

    cache.bounds = .{
        std.math.floatMax(f32),  std.math.floatMax(f32),
        -std.math.floatMax(f32), -std.math.floatMax(f32),
    };

    for (cache.paths.items) |*sp| {
        const pts = cache.points.items[sp.first .. sp.first + sp.count];

        if (sp.closed) {
            if (sp.count > 1) {
                const fp = pts[0];
                const lp = pts[pts.len - 1];
                if (ptEquals(fp.x, fp.y, lp.x, lp.y, dist_tol)) {
                    sp.count -= 1;
                }
            }
        }

        const pts2 = cache.points.items[sp.first .. sp.first + sp.count];
        if (pts2.len < 2) continue;

        // Normalize the transformed polygon, not the authoring coordinates.
        // Reflections reverse area; winding still describes solid versus hole.
        const area = polyArea(pts2);
        if ((sp.winding == .ccw and area > 0) or (sp.winding == .cw and area < 0)) std.mem.reverse(Point, pts2);
        const n = pts2.len;
        for (0..n) |i| {
            const j = (i + 1) % n;
            const dx = pts2[j].x - pts2[i].x;
            const dy = pts2[j].y - pts2[i].y;
            const d = @sqrt(dx * dx + dy * dy);
            const dirs = normalize(dx, dy);
            pts2[i].dx = dirs[0];
            pts2[i].dy = dirs[1];
            pts2[i].len = d;

            cache.bounds[0] = @min(cache.bounds[0], pts2[i].x);
            cache.bounds[1] = @min(cache.bounds[1], pts2[i].y);
            cache.bounds[2] = @max(cache.bounds[2], pts2[i].x);
            cache.bounds[3] = @max(cache.bounds[3], pts2[i].y);
        }

        sp.ccw = polyArea(pts2) <= 0;
    }
}

/// What `flattenPaths` checks before it touches the cache: the command count, both tolerances and
/// every coordinate.
pub fn validateFlattenInputs(cmds: []const Command, tess_tol: f32, dist_tol: f32) FlattenError!void {
    path_mod.validateCommandCapacity(cmds.len, 0) catch return error.TooManyCommands;
    if (!std.math.isFinite(tess_tol) or tess_tol <= 0) return error.InvalidTessellationTolerance;
    if (!std.math.isFinite(dist_tol) or dist_tol <= 0) return error.InvalidDistanceTolerance;
    for (cmds) |cmd| {
        switch (cmd) {
            .move_to, .line_to => |point| {
                if (!std.math.isFinite(point[0]) or !std.math.isFinite(point[1])) return error.NonFiniteCoordinate;
            },
            .bezier_to => |points| {
                for (points) |coordinate| {
                    if (!std.math.isFinite(coordinate)) return error.NonFiniteCoordinate;
                }
            },
            .close, .winding => {},
        }
    }
}

fn addPath(allocator: std.mem.Allocator, cache: *PathCache) !void {
    try path_mod.validatePathCapacity(cache.paths.items.len, 1);
    try cache.paths.append(allocator, .{
        .first = @intCast(cache.points.items.len),
        .count = 0,
        .closed = false,
        .winding = .ccw,
    });
}

fn addPoint(allocator: std.mem.Allocator, cache: *PathCache, x: f32, y: f32, flags: PointFlag, dist_tol: f32) !void {
    if (cache.paths.items.len == 0) return;
    const path = &cache.paths.items[cache.paths.items.len - 1];

    if (path.count > 0) {
        const last = cache.points.items[cache.points.items.len - 1];
        if (ptEquals(last.x, last.y, x, y, dist_tol)) {
            cache.points.items[cache.points.items.len - 1].flags = .{
                .corner = last.flags.corner or flags.corner,
                .left = last.flags.left or flags.left,
                .bevel = last.flags.bevel or flags.bevel,
                .innerbevel = last.flags.innerbevel or flags.innerbevel,
            };
            return;
        }
    }
    try path_mod.validatePointCapacity(cache.points.items.len, 1);
    try cache.points.append(allocator, .{ .x = x, .y = y, .flags = flags });
    path.count += 1;
}

fn tesselateBezier(
    allocator: std.mem.Allocator,
    cache: *PathCache,
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,
    x3: f32,
    y3: f32,
    x4: f32,
    y4: f32,
    level: u32,
    flags: PointFlag,
    tess_tol: f32,
    dist_tol: f32,
) !void {
    if (level > 10) return;

    const x12 = (x1 + x2) * 0.5;
    const y12 = (y1 + y2) * 0.5;
    const x23 = (x2 + x3) * 0.5;
    const y23 = (y2 + y3) * 0.5;
    const x34 = (x3 + x4) * 0.5;
    const y34 = (y3 + y4) * 0.5;
    const x123 = (x12 + x23) * 0.5;
    const y123 = (y12 + y23) * 0.5;
    const x234 = (x23 + x34) * 0.5;
    const y234 = (y23 + y34) * 0.5;
    const x1234 = (x123 + x234) * 0.5;
    const y1234 = (y123 + y234) * 0.5;

    const dx = x4 - x1;
    const dy = y4 - y1;
    const d2 = @abs((x2 - x4) * dy - (y2 - y4) * dx);
    const d3 = @abs((x3 - x4) * dy - (y3 - y4) * dx);

    if ((d2 + d3) * (d2 + d3) < tess_tol * (dx * dx + dy * dy)) {
        try addPoint(allocator, cache, x4, y4, flags, dist_tol);
        return;
    }

    try tesselateBezier(allocator, cache, x1, y1, x12, y12, x123, y123, x1234, y1234, level + 1, .{}, tess_tol, dist_tol);
    try tesselateBezier(allocator, cache, x1234, y1234, x234, y234, x34, y34, x4, y4, level + 1, flags, tess_tol, dist_tol);
}

/// Classifies the joins of `sp` for a fill with an antialiasing fringe `fringe` wide (zero for
/// none): writes each point's miter direction and flags, and `sp`'s convexity. `miter_limit` is the
/// `State`'s. Returns no error.
pub fn expandFill(
    cache: *PathCache,
    sp: *SubPath,
    fringe: f32,
    miter_limit: f32,
) !void {
    const woff = 0.5 * fringe;
    calculateJoinsForPath(cache, sp, fringe, .miter, miter_limit);

    const pts = cache.points.items[sp.first .. sp.first + sp.count];
    const n = pts.len;
    if (n < 3) return;

    _ = woff;
    sp.fill_count = @intCast(n);
}

fn calculateJoinsForPath(
    cache: *PathCache,
    sp: *SubPath,
    w: f32,
    line_join: LineJoin,
    miter_limit: f32,
) void {
    const iw: f32 = if (w > 0) 1.0 / w else 0;
    const pts = cache.points.items[sp.first .. sp.first + sp.count];
    const n = pts.len;
    if (n < 2) return;

    var nleft: u32 = 0;
    sp.convex = true;

    for (0..n) |i| {
        const p0 = &pts[(i + n - 1) % n];
        const p1 = &pts[i];

        const dlx0 = p0.dy;
        const dly0 = -p0.dx;
        const dlx1 = p1.dy;
        const dly1 = -p1.dx;

        var dmx = (dlx0 + dlx1) * 0.5;
        var dmy = (dly0 + dly1) * 0.5;
        const dmr2 = dmx * dmx + dmy * dmy;
        if (dmr2 > 0.000001) {
            var sc = 1.0 / dmr2;
            if (sc > 600.0) sc = 600.0;
            dmx *= sc;
            dmy *= sc;
        }

        p1.dmx = dmx;
        p1.dmy = dmy;

        const cross = p1.dx * p0.dy - p0.dx * p1.dy;
        if (cross > 0.0) {
            nleft += 1;
            p1.flags.left = true;
        }

        const limit = @max(1.01, @min(p0.len, p1.len) * iw);
        if (dmr2 * limit * limit < 1.0) p1.flags.innerbevel = true;

        if (p1.flags.corner) {
            if (dmr2 * miter_limit * miter_limit < 1.0 or line_join == .bevel or line_join == .round) {
                p1.flags.bevel = true;
            }
        }

        if (p1.flags.bevel or p1.flags.innerbevel) sp.convex = false;
    }
    sp.convex = nleft == n;
    sp.geom_convex = (nleft == 0 or nleft == n);
}

/// Classifies the joins of `sp` for a stroke of half width `w`, measured against the ribbon as
/// drawn, half a fringe wider: writes each point's miter direction and flags. `line_cap` is not
/// read: caps are made by the tessellation shader. Returns no error.
pub fn expandStroke(
    cache: *PathCache,
    sp: *SubPath,
    fringe: f32,
    w: f32,
    line_cap: LineCap,
    line_join: LineJoin,
    miter_limit: f32,
) !void {
    // Joins are judged against the ribbon as drawn, which reaches half a fringe past the width.
    calculateJoinsForPath(cache, sp, w + fringe * 0.5, line_join, miter_limit);

    _ = line_cap;
}

test "flatten validates tolerance, coordinates, and curve-division bounds" {
    try std.testing.expectError(error.InvalidTessellationTolerance, validateFlattenInputs(&.{}, 0, 0.01));
    try std.testing.expectError(error.InvalidDistanceTolerance, validateFlattenInputs(&.{}, 0.25, std.math.nan(f32)));
    const invalid = [_]Command{.{ .move_to = .{ std.math.nan(f32), 0 } }};
    try std.testing.expectError(error.NonFiniteCoordinate, validateFlattenInputs(&invalid, 0.25, 0.01));
    try std.testing.expectEqual(@as(u32, 2), curveDivs(1, std.math.pi, 0));
    try std.testing.expectEqual(kMaxCurveDivisions, curveDivs(1, std.math.pi, 1e-7));
}

test "flatten rect" {
    const alloc = std.testing.allocator;
    var cache: PathCache = .empty;
    defer cache.deinit(alloc);

    const cmds = [_]Command{
        .{ .move_to = .{ 0, 0 } },
        .{ .line_to = .{ 10, 0 } },
        .{ .line_to = .{ 10, 10 } },
        .{ .line_to = .{ 0, 10 } },
        .close,
    };
    try flattenPaths(alloc, &cache, &cmds, 0.25, 0.01);
    try std.testing.expectEqual(@as(usize, 1), cache.paths.items.len);
    try std.testing.expect(cache.paths.items[0].count >= 4);
}

test "flatten circle" {
    const alloc = std.testing.allocator;
    var cache: PathCache = .empty;
    defer cache.deinit(alloc);

    const kappa = 0.5523;
    const r: f32 = 50;
    const cmds = [_]Command{
        .{ .move_to = .{ -r, 0 } },
        .{ .bezier_to = .{ -r, r * kappa, -r * kappa, r, 0, r } },
        .{ .bezier_to = .{ r * kappa, r, r, r * kappa, r, 0 } },
        .{ .bezier_to = .{ r, -r * kappa, r * kappa, -r, 0, -r } },
        .{ .bezier_to = .{ -r * kappa, -r, -r, -r * kappa, -r, 0 } },
        .close,
    };
    try flattenPaths(alloc, &cache, &cmds, 0.25, 0.01);
    try std.testing.expect(cache.paths.items[0].count > 10);

    try std.testing.expect(cache.bounds[0] <= -49);
    try std.testing.expect(cache.bounds[2] >= 49);
}
