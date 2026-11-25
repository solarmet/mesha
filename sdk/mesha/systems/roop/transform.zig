//! 2D affine transforms as roop keeps them: six floats, with the constructors and algebra a
//! `Context` and its paints use. Angles are radians. Coordinates have y down, so a positive
//! rotation turns clockwise on screen.
const std = @import("std");
const math = @import("../../core/math.zig");

/// An affine transform `.{ a, b, c, d, tx, ty }`: a point maps to `x' = a*x + c*y + tx`, `y' = b*x
/// + d*y + ty`.
pub const Transform2D = [6]f32;

/// `value` as a `Transform2D`, field for field.
pub fn fromAffine(value: math.Affine2f) Transform2D {
    return .{ value.a, value.b, value.c, value.d, value.tx, value.ty };
}

/// `value` as a `math.Affine2f`, field for field.
pub fn toAffine(value: Transform2D) math.Affine2f {
    return .{ .a = value[0], .b = value[1], .c = value[2], .d = value[3], .tx = value[4], .ty = value[5] };
}

test "Affine2f conversion preserves mirrored composition and inverse" {
    const value = math.Affine2f.fromTRS(20, -3, 0.7, -2, 0.5);
    const child = math.Affine2f.fromTRS(4, 5, -0.2, 1, 3);
    try std.testing.expectEqual(value, toAffine(fromAffine(value)));
    const actual = multiply(fromAffine(value), fromAffine(child));
    const expected = fromAffine(math.Affine2f.mul(value, child));
    for (actual, expected) |a, b| try std.testing.expectApproxEqAbs(a, b, 1e-5);
    for (inverse(fromAffine(value)).?, fromAffine(value.inverse().?)) |a, b| try std.testing.expectApproxEqAbs(a, b, 1e-5);
}

/// The transform that leaves every point where it is.
pub fn identity() Transform2D {
    return .{ 1, 0, 0, 1, 0, 0 };
}

/// Moves points by `tx, ty`.
pub fn translation(tx: f32, ty: f32) Transform2D {
    return .{ 1, 0, 0, 1, tx, ty };
}

/// Scales x by `sx` and y by `sy`, about the origin.
pub fn scaling(sx: f32, sy: f32) Transform2D {
    return .{ sx, 0, 0, sy, 0, 0 };
}

/// Rotates about the origin by `angle` radians: from the x axis toward the y axis, which with y
/// down is clockwise on screen.
pub fn rotation(angle: f32) Transform2D {
    const c = @cos(angle);
    const s = @sin(angle);
    return .{ c, s, -s, c, 0, 0 };
}

/// Shears along x: `x' = x + tan(angle) * y`.
pub fn skewX(angle: f32) Transform2D {
    return .{ 1, 0, @tan(angle), 1, 0, 0 };
}

/// Shears along y: `y' = y + tan(angle) * x`.
pub fn skewY(angle: f32) Transform2D {
    return .{ 1, @tan(angle), 0, 1, 0, 0 };
}

/// The transform that applies `b`, then `a`.
pub fn multiply(a: Transform2D, b: Transform2D) Transform2D {
    return .{
        a[0] * b[0] + a[2] * b[1],
        a[1] * b[0] + a[3] * b[1],
        a[0] * b[2] + a[2] * b[3],
        a[1] * b[2] + a[3] * b[3],
        a[0] * b[4] + a[2] * b[5] + a[4],
        a[1] * b[4] + a[3] * b[5] + a[5],
    };
}

/// The transform that applies `a`, then `b`: `multiply(b, a)`.
pub fn premultiply(a: Transform2D, b: Transform2D) Transform2D {
    return multiply(b, a);
}

/// The inverse of `t`, or null when it has none it can give: `math.Affine2f.inverse` decides, as
/// for the figure code, refusing a determinant too near zero and any input or result that is not
/// finite.
pub fn inverse(t: Transform2D) ?Transform2D {
    return fromAffine(toAffine(t).inverse() orelse return null);
}

/// The point `x, y` transformed by `t`.
pub fn point(t: Transform2D, x: f32, y: f32) [2]f32 {
    return .{
        x * t[0] + y * t[2] + t[4],
        x * t[1] + y * t[3] + t[5],
    };
}

/// `t` as the rows of a 3x3 matrix, each padded to four floats: the layout the shaders read
/// (`draw_list.PaintUniforms`).
pub fn toRows(t: Transform2D) [3][4]f32 {
    return .{
        .{ t[0], t[2], t[4], 0 },
        .{ t[1], t[3], t[5], 0 },
        .{ 0, 0, 1, 0 },
    };
}

test "identity round-trip" {
    const id = identity();
    const p = point(id, 3, 7);
    try std.testing.expectApproxEqAbs(p[0], 3, 1e-5);
    try std.testing.expectApproxEqAbs(p[1], 7, 1e-5);
}

test "multiply translation" {
    const a = translation(1, 2);
    const b = translation(3, 4);
    const c = multiply(a, b);
    const p = point(c, 0, 0);
    try std.testing.expectApproxEqAbs(p[0], 4, 1e-5);
    try std.testing.expectApproxEqAbs(p[1], 6, 1e-5);
}

test "inverse" {
    const t = multiply(translation(5, -3), rotation(0.3));
    const inv = inverse(t).?;
    const composed = multiply(t, inv);
    const id = identity();
    for (0..6) |i| try std.testing.expectApproxEqAbs(composed[i], id[i], 1e-5);
}

test "inverse shares affine determinant boundary and rejects nonfinite input or output" {
    const epsilon = std.math.floatEps(f32);
    for ([_]f32{ epsilon * 1.01, 5e-7, 1e-6, 2e-6 }) |determinant| {
        const matrix = Transform2D{ determinant, 0, 0, 1, 0, 0 };
        const actual = inverse(matrix).?;
        try std.testing.expectEqual(fromAffine(toAffine(matrix).inverse().?), actual);
        const product = multiply(matrix, actual);
        for (product, identity()) |x, y| try std.testing.expectApproxEqAbs(x, y, 1e-6);
    }
    for ([_]f32{ 0, epsilon * 0.99, epsilon }) |determinant| try std.testing.expect(inverse(.{ determinant, 0, 0, 1, 0, 0 }) == null);
    for (0..6) |i| {
        var matrix = identity();
        matrix[i] = std.math.inf(f32);
        try std.testing.expect(inverse(matrix) == null);
        matrix[i] = std.math.nan(f32);
        try std.testing.expect(inverse(matrix) == null);
    }
    try std.testing.expect(inverse(.{ 0.5, 0, 0, 0.5, std.math.floatMax(f32), 0 }) == null);
}
