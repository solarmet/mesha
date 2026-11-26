//! Paths as the drawing tools make them: the points a primitive drag or a pencil stroke turns
//! into, a position along a segment between two points, and the box a drag spans. Everything here
//! is a pure function of its arguments over `read.Point` and `Vec2`, in the figure's space; it
//! reads no table, so a plugin, the editor and the host call it alike.
//!
//! A path is the cubic Bezier curve through its points in order: the segment from `a` to `b` has
//! control points `a.p`, `a.p + a.out`, `b.p + b.in` and `b.p`.
const std = @import("std");
const figure = @import("../figure.zig");
const read = @import("read.zig");
const Vec2 = figure.Vec2;
const Point = read.Point;
const zero = Vec2{ .x = 0, .y = 0 };

/// The handle length, as a fraction of the radius, of a cubic that draws a quarter circle.
const kappa: f32 = 0.5523;

fn mix(a: Vec2, b: Vec2, t: f32) Vec2 {
    const from = Vec2.scale(a, 1 - t);
    const to = Vec2.scale(b, t);
    return Vec2.add(from, to);
}

fn distance(a: Vec2, b: Vec2) f32 {
    const d = Vec2.sub(a, b);
    return @sqrt(d.x * d.x + d.y * d.y);
}

/// The position `t` of the way along the segment from `a` to `b`, `t` from 0 (`a.p`) to 1
/// (`b.p`). Only the points' `p`, `in` and `out` are read.
pub fn pathCubic(a: Point, b: Point, t: f32) Vec2 {
    const a_handle = Vec2.add(a.p, a.out);
    const b_handle = Vec2.add(b.p, b.in);
    const q0 = mix(a.p, a_handle, t);
    const q1 = mix(a_handle, b_handle, t);
    const q2 = mix(b_handle, b.p, t);
    const r0 = mix(q0, q1, t);
    const r1 = mix(q1, q2, t);
    return mix(r0, r1, t);
}

/// The box a drag from `start` to `end` spans. With `shift` it is square, its side the larger of
/// the drag's two extents; with `center`, `start` is its centre rather than a corner.
pub fn dragBounds(start: Vec2, end: Vec2, shift: bool, center: bool) figure.Bounds {
    var d = Vec2.sub(end, start);
    if (shift) {
        const size = @max(@abs(d.x), @abs(d.y));
        d = .{ .x = if (d.x < 0) -size else size, .y = if (d.y < 0) -size else size };
    }
    const a = if (center) Vec2.sub(start, d) else start;
    const b = Vec2.add(start, d);
    return .{
        .min = .{ .x = @min(a.x, b.x), .y = @min(a.y, b.y) },
        .max = .{ .x = @max(a.x, b.x), .y = @max(a.y, b.y) },
    };
}

/// The points of the `kind` primitive a drag from `start` to `end` draws, `shift` and `center` as
/// `dragBounds` takes them: a rectangle's four corners from its top left, or eight with rounded
/// corners of `radius` (at most half the shorter side) when `radius` is above 0; an ellipse's four
/// points from its right; a line's two ends, its angle a multiple of 45 degrees with `shift`; or a
/// regular polygon of `sides` (3 to 128) inscribed in the box from its top. Each point's `index` is
/// its place and every other field the default. The caller owns the slice, in `allocator`.
pub fn primitivePath(allocator: std.mem.Allocator, kind: figure.Primitive, start: Vec2, end: Vec2, shift: bool, center: bool, radius: f32, sides: u32) figure.Error![]Point {
    const box = dragBounds(start, end, shift, center);
    const lo = box.min;
    const hi = box.max;
    const rx = (hi.x - lo.x) / 2;
    const ry = (hi.y - lo.y) / 2;
    const cx = (hi.x + lo.x) / 2;
    const cy = (hi.y + lo.y) / 2;
    const count: usize = switch (kind) {
        .rect => if (radius > 0) 8 else 4,
        .ellipse => 4,
        .line => 2,
        .polygon => std.math.clamp(sides, 3, 128),
    };
    const out = try allocator.alloc(Point, count);
    @memset(out, .{});
    switch (kind) {
        .line => {
            var d = Vec2.sub(end, start);
            if (shift) {
                const eighth_turn = std.math.pi / 4.0;
                const angle = @round(std.math.atan2(d.y, d.x) / eighth_turn) * eighth_turn;
                const length = distance(start, end);
                d = .{ .x = @cos(angle) * length, .y = @sin(angle) * length };
            }
            out[0].p = if (center) Vec2.sub(start, d) else start;
            out[1].p = Vec2.add(start, d);
        },
        .ellipse => {
            out[0] = .{ .p = .{ .x = cx + rx, .y = cy }, .in = .{ .x = 0, .y = -ry * kappa }, .out = .{ .x = 0, .y = ry * kappa } };
            out[1] = .{ .p = .{ .x = cx, .y = cy + ry }, .in = .{ .x = rx * kappa, .y = 0 }, .out = .{ .x = -rx * kappa, .y = 0 } };
            out[2] = .{ .p = .{ .x = cx - rx, .y = cy }, .in = .{ .x = 0, .y = ry * kappa }, .out = .{ .x = 0, .y = -ry * kappa } };
            out[3] = .{ .p = .{ .x = cx, .y = cy - ry }, .in = .{ .x = -rx * kappa, .y = 0 }, .out = .{ .x = rx * kappa, .y = 0 } };
        },
        .rect => if (radius <= 0) {
            out[0].p = lo;
            out[1].p = .{ .x = hi.x, .y = lo.y };
            out[2].p = hi;
            out[3].p = .{ .x = lo.x, .y = hi.y };
        } else {
            const r = @min(radius, @min(rx, ry));
            const h = r * kappa;
            const corners = [_]Vec2{
                .{ .x = lo.x + r, .y = lo.y },
                .{ .x = hi.x - r, .y = lo.y },
                .{ .x = hi.x, .y = lo.y + r },
                .{ .x = hi.x, .y = hi.y - r },
                .{ .x = hi.x - r, .y = hi.y },
                .{ .x = lo.x + r, .y = hi.y },
                .{ .x = lo.x, .y = hi.y - r },
                .{ .x = lo.x, .y = lo.y + r },
            };
            for (out, corners) |*point, position| point.p = position;
            out[1].out = .{ .x = h, .y = 0 };
            out[2].in = .{ .x = 0, .y = -h };
            out[3].out = .{ .x = 0, .y = h };
            out[4].in = .{ .x = h, .y = 0 };
            out[5].out = .{ .x = -h, .y = 0 };
            out[6].in = .{ .x = 0, .y = h };
            out[7].out = .{ .x = 0, .y = -h };
            out[0].in = .{ .x = -h, .y = 0 };
        },
        .polygon => for (out, 0..) |*point, i| {
            const turn = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(count));
            const angle = -std.math.pi / 2.0 + 2 * std.math.pi * turn;
            point.p = .{ .x = cx + rx * @cos(angle), .y = cy + ry * @sin(angle) };
        },
    }
    for (out, 0..) |*point, i| point.index = @intCast(i);
    return out;
}

/// The path a pencil stroke through `points` draws: the samples thinned to those no closer than
/// `simplify_tolerance` to the polyline through the rest (Ramer-Douglas-Peucker; 0 or less keeps
/// all but collinear ones), then fitted with cubics (Schneider's least squares) that pass within
/// `maximum_error` of every kept sample, splitting a segment where they do not. The path begins
/// at the first sample and ends at the last; each point's `index` is its place. Fails with
/// `error.InvalidOptions` when `maximum_error` is not finite and above 0. The caller owns the
/// slice, in `allocator`.
pub fn fitPath(allocator: std.mem.Allocator, points: []const Vec2, simplify_tolerance: f32, maximum_error: f32) figure.Error![]Point {
    if (!std.math.isFinite(maximum_error) or maximum_error <= 0) return error.InvalidOptions;
    const simplified = try simplify(allocator, points, simplify_tolerance);
    defer allocator.free(simplified);
    return fit(allocator, simplified, maximum_error);
}

fn dot(a: Vec2, b: Vec2) f32 {
    return a.x * b.x + a.y * b.y;
}

fn unit(v: Vec2) Vec2 {
    const length = distance(v, zero);
    if (length > 1e-8) return Vec2.scale(v, 1 / length);
    return .{ .x = 1, .y = 0 };
}

fn segmentDistance(p: Vec2, a: Vec2, b: Vec2) f32 {
    const d = Vec2.sub(b, a);
    const n = dot(d, d);
    const along = if (n > 0) std.math.clamp(dot(Vec2.sub(p, a), d) / n, 0, 1) else 0;
    const nearest = mix(a, b, along);
    return distance(p, nearest);
}

/// Deepest recursion of the thinning and the fitting; past it a stretch is kept as it is.
const max_depth = 32;

fn rdp(out: *std.ArrayListUnmanaged(Vec2), allocator: std.mem.Allocator, samples: []const Vec2, tolerance: f32, depth: u32) error{OutOfMemory}!void {
    const first = samples[0];
    const last = samples[samples.len - 1];
    var maximum: f32 = 0;
    var split: usize = 0;
    for (samples[1 .. samples.len - 1], 1..) |sample, i| {
        const d = segmentDistance(sample, first, last);
        if (d > maximum) {
            maximum = d;
            split = i;
        }
    }
    if (maximum > tolerance and depth < max_depth) {
        try rdp(out, allocator, samples[0 .. split + 1], tolerance, depth + 1);
        try rdp(out, allocator, samples[split..], tolerance, depth + 1);
    } else if (maximum > tolerance) {
        try out.appendSlice(allocator, samples[1..]);
    } else {
        try out.append(allocator, last);
    }
}

fn simplify(allocator: std.mem.Allocator, samples: []const Vec2, tolerance: f32) error{OutOfMemory}![]Vec2 {
    if (samples.len < 3) return allocator.dupe(Vec2, samples);
    var out: std.ArrayListUnmanaged(Vec2) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, samples[0]);
    try rdp(&out, allocator, samples, @max(0, tolerance), 0);
    return out.toOwnedSlice(allocator);
}

/// Longest accepted handle, as a fraction of the arc length the cubic covers.
const max_handle_to_arc: f32 = 0.5;

/// Fits `samples` with cubics leaving along `left` and arriving along `right`, unit tangents, and
/// appends their points after the last of `out`, whose `out` handle it sets. Error is measured at
/// chord-length sample parameters; a rejected fit splits at its worst sample.
fn fitPart(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(Point), samples: []const Vec2, left: Vec2, right: Vec2, maximum_error: f32, depth: u32) error{OutOfMemory}!void {
    const last = samples.len - 1;
    if (last == 0) return;
    if (last == 1 or depth >= max_depth) {
        // A straight cubic is exact for each remaining sample segment.
        for (samples[1..]) |sample| {
            const start = &out.items[out.items.len - 1];
            const handle = Vec2.scale(Vec2.sub(sample, start.p), 1.0 / 3.0);
            start.out = handle;
            try out.append(allocator, .{ .p = sample, .in = Vec2.scale(handle, -1) });
        }
        return;
    }
    const u = try allocator.alloc(f32, samples.len);
    defer allocator.free(u);
    u[0] = 0;
    for (1..samples.len) |i| u[i] = u[i - 1] + distance(samples[i], samples[i - 1]);
    if (u[last] < 1e-7) return;
    const total = u[last];
    for (u) |*t| t.* /= total;
    var c00: f32 = 0;
    var c01: f32 = 0;
    var c11: f32 = 0;
    var x0: f32 = 0;
    var x1: f32 = 0;
    for (samples, u) |sample, t| {
        const s = 1 - t;
        const b0 = s * s * s;
        const b1 = 3 * t * s * s;
        const b2 = 3 * t * t * s;
        const b3 = t * t * t;
        const v0 = Vec2.scale(left, b1);
        const v1 = Vec2.scale(right, b2);
        const ends = Vec2.add(Vec2.scale(samples[0], b0 + b1), Vec2.scale(samples[last], b2 + b3));
        const residual = Vec2.sub(sample, ends);
        c00 += dot(v0, v0);
        c01 += dot(v0, v1);
        c11 += dot(v1, v1);
        x0 += dot(v0, residual);
        x1 += dot(v1, residual);
    }
    const det = c00 * c11 - c01 * c01;
    const chord = distance(samples[0], samples[last]);
    var alpha = if (@abs(det) > 1e-12) (x0 * c11 - x1 * c01) / det else chord / 3;
    var beta = if (@abs(det) > 1e-12) (c00 * x1 - c01 * x0) / det else chord / 3;
    // Nearly parallel end tangents make the solve ill-conditioned: it can match every
    // sample exactly with handles far longer than the stroke, and the sample-only error
    // check below would accept the resulting excursion between samples.
    const handle_limit = total * max_handle_to_arc;
    const too_short = alpha < chord * 1e-6 or beta < chord * 1e-6;
    const too_long = alpha > handle_limit or beta > handle_limit;
    if (too_short or too_long or !std.math.isFinite(alpha + beta)) {
        alpha = chord / 3;
        beta = chord / 3;
    }
    const p0 = Point{ .p = samples[0], .out = Vec2.scale(left, alpha) };
    const p1 = Point{ .p = samples[last], .in = Vec2.scale(right, beta) };
    var maximum: f32 = 0;
    var split: usize = last / 2;
    for (samples[1..last], 1..) |sample, i| {
        const on_curve = pathCubic(p0, p1, u[i]);
        const d = distance(on_curve, sample);
        if (d > maximum) {
            maximum = d;
            split = i;
        }
    }
    if (maximum <= maximum_error) {
        out.items[out.items.len - 1].out = p0.out;
        try out.append(allocator, p1);
        return;
    }
    const tangent = unit(Vec2.sub(samples[split - 1], samples[split + 1]));
    try fitPart(allocator, out, samples[0 .. split + 1], left, tangent, maximum_error, depth + 1);
    try fitPart(allocator, out, samples[split..], Vec2.scale(tangent, -1), right, maximum_error, depth + 1);
}

/// `maximum_error` is finite and above 0; `fitPath` checks it.
fn fit(allocator: std.mem.Allocator, samples: []const Vec2, maximum_error: f32) error{OutOfMemory}![]Point {
    if (samples.len == 0) return allocator.alloc(Point, 0);
    var out: std.ArrayListUnmanaged(Point) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, .{ .p = samples[0] });
    if (samples.len > 1) {
        const left = unit(Vec2.sub(samples[1], samples[0]));
        const right = unit(Vec2.sub(samples[samples.len - 2], samples[samples.len - 1]));
        try fitPart(allocator, &out, samples, left, right, maximum_error, 0);
    }
    for (out.items, 0..) |*point, i| point.index = @intCast(i);
    return out.toOwnedSlice(allocator);
}

test "primitive rectangle rounded corners ellipse and modifiers" {
    const a = std.testing.allocator;
    const rect = try primitivePath(a, .rect, .{ .x = 10, .y = 20 }, .{ .x = 30, .y = 50 }, true, true, 0, 5);
    defer a.free(rect);
    try std.testing.expectEqual(@as(usize, 4), rect.len);
    try std.testing.expectEqual(@as(f32, -20), rect[0].p.x);
    const ellipse = try primitivePath(a, .ellipse, .{ .x = -10, .y = -20 }, .{ .x = 10, .y = 20 }, false, false, 0, 5);
    defer a.free(ellipse);
    try std.testing.expectApproxEqAbs(@as(f32, 20 * kappa), ellipse[0].out.y, 0.0001);
    const rounded = try primitivePath(a, .rect, zero, .{ .x = 20, .y = 10 }, false, false, 100, 5);
    defer a.free(rounded);
    try std.testing.expectEqual(@as(usize, 8), rounded.len);
    try std.testing.expectApproxEqAbs(@as(f32, 5), rounded[0].p.x, 0.0001);
}

test "pencil synthetic line circle fit bounds and simplification" {
    const a = std.testing.allocator;
    var line: [101]Vec2 = undefined;
    var circle: [129]Vec2 = undefined;
    for (&line, 0..) |*p, i| p.* = .{ .x = @floatFromInt(i), .y = 2 * @as(f32, @floatFromInt(i)) };
    const simple = try simplify(a, &line, 0.1);
    defer a.free(simple);
    try std.testing.expectEqual(@as(usize, 2), simple.len);
    const fitted = try fit(a, &line, 0.1);
    defer a.free(fitted);
    try std.testing.expectEqual(@as(usize, 2), fitted.len);
    for (&circle, 0..) |*p, i| {
        const t = 2 * std.math.pi * @as(f32, @floatFromInt(i)) / 128;
        p.* = .{ .x = 100 * @cos(t), .y = 100 * @sin(t) };
    }
    const arcs = try fit(a, &circle, 0.3);
    defer a.free(arcs);
    try std.testing.expect(arcs.len < 25 and arcs.len >= 5);
    // Independent dense nearest-distance check against the original samples.
    for (circle) |p| {
        var nearest: f32 = 1e9;
        for (0..arcs.len - 1) |i| for (0..201) |j| {
            nearest = @min(nearest, distance(p, pathCubic(arcs[i], arcs[i + 1], @as(f32, @floatFromInt(j)) / 200)));
        };
        try std.testing.expect(nearest < 0.7);
    }
    try std.testing.expectError(error.InvalidOptions, fitPath(a, &line, 0.1, 0));
}

test "pencil fit stays near wobbly strokes between samples" {
    const a = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(1);
    const random = prng.random();
    for (0..300) |_| {
        var raw: [200]Vec2 = undefined;
        const count = random.intRangeAtMost(usize, 3, raw.len);
        var position = zero;
        var angle = random.float(f32) * 2 * std.math.pi;
        for (raw[0..count]) |*sample| {
            sample.* = position;
            angle += (random.float(f32) - 0.5) * 1.2;
            const step = 2 + random.float(f32) * 6;
            position = .{ .x = @round(position.x + @cos(angle) * step), .y = @round(position.y + @sin(angle) * step) };
        }
        const fitted = try fitPath(a, raw[0..count], 0.7, 1);
        defer a.free(fitted);
        for (fitted[0 .. fitted.len - 1], fitted[1..]) |start, end| for (0..33) |j| {
            const curve_point = pathCubic(start, end, @as(f32, @floatFromInt(j)) / 32);
            var nearest: f32 = std.math.inf(f32);
            for (raw[0 .. count - 1], raw[1..count]) |from, to| nearest = @min(nearest, segmentDistance(curve_point, from, to));
            try std.testing.expect(nearest < 10);
        };
    }
}

test "pencil fit crosses its former workspace limit of 16384 samples" {
    const a = std.testing.allocator;
    const sample_count = 16385;
    const samples = try a.alloc(Vec2, sample_count);
    defer a.free(samples);
    for (samples, 0..) |*sample, index| {
        const x: f32 = @floatFromInt(index);
        sample.* = .{ .x = x, .y = 40 * @sin(x / 20) };
    }
    const fitted = try fit(a, samples, 0.5);
    defer a.free(fitted);
    try std.testing.expect(fitted.len >= 2);
    try std.testing.expectEqual(samples[sample_count - 1], fitted[fitted.len - 1].p);
}
