//! Vectors, matrices and quaternions of `f32`, laid out as C structs so they can sit in table
//! cells, message payloads and GPU buffers and cross the plugin boundary unchanged.
//!
//! `Vec2f` and `Affine2f` are the 2D pair: the affine matrix has roop's layout and is what
//! figures and 2D drawing transform points with. `Vec3f`, `Vec4f`, `Mat4x4f` and `Quat4f` are
//! the 3D set. Matrices are column-major and multiply column vectors, so in `a.mul(b)` the
//! transform `b` applies first. Angles are radians. The 3D view convention is right-handed,
//! the camera looking down its own -Z.
//!
//! The plain constructors (`Mat4x4f.perspective`, `ortho`, `lookAt`, `normalize`) do no
//! checking and give non-finite results for degenerate input; the `*Checked` functions refuse
//! such input with a `DomainError`. Everything here is pure: callable from a kernel, a plugin
//! or the host, on any thread.
const std = @import("std");

/// A 2D point or vector of `f32`, laid out as two consecutive floats in the C layout.
pub const Vec2f = extern struct {
    /// The first component.
    x: f32,
    /// The second component.
    y: f32,
    /// The components as a SIMD vector, in field order.
    pub inline fn simd(self: Vec2f) @Vector(2, f32) {
        return @bitCast(self);
    }
    /// The vector whose components are `v`'s, in field order.
    pub inline fn fromSimd(v: @Vector(2, f32)) Vec2f {
        return @bitCast(v);
    }
    /// The componentwise sum `a + b`.
    pub inline fn add(a: Vec2f, b: Vec2f) Vec2f {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }
    /// The componentwise difference `a - b`.
    pub inline fn sub(a: Vec2f, b: Vec2f) Vec2f {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }
    /// Every component of `a` multiplied by `s`.
    pub inline fn scale(a: Vec2f, s: f32) Vec2f {
        return .{ .x = a.x * s, .y = a.y * s };
    }
    /// Every component of `a` negated.
    pub inline fn neg(a: Vec2f) Vec2f {
        return .{ .x = -a.x, .y = -a.y };
    }
};

/// A 2D affine transform, six `f32` in the order roop's transforms use (column-major):
/// `x' = a*x + c*y + tx`, `y' = b*x + d*y + ty`.
pub const Affine2f = extern struct {
    /// How much of an input x reaches the output x: the first column's x.
    a: f32,
    /// How much of an input x reaches the output y: the first column's y.
    b: f32,
    /// How much of an input y reaches the output x: the second column's x.
    c: f32,
    /// How much of an input y reaches the output y: the second column's y.
    d: f32,
    /// The translation along x, added after the linear part.
    tx: f32,
    /// The translation along y, added after the linear part.
    ty: f32,

    /// The transform that leaves every point where it is.
    pub const identity: Affine2f = .{ .a = 1, .b = 0, .c = 0, .d = 1, .tx = 0, .ty = 0 };

    /// The transform that scales by `sx`, `sy`, then rotates by `angle` radians (from +X towards
    /// +Y, which is clockwise on a y-down screen), then translates to `x`, `y`.
    pub fn fromTRS(x: f32, y: f32, angle: f32, sx: f32, sy: f32) Affine2f {
        const cosine = @cos(angle);
        const sine = @sin(angle);
        return .{ .a = cosine * sx, .b = sine * sx, .c = -sine * sy, .d = cosine * sy, .tx = x, .ty = y };
    }

    /// The product `a*b`: `b` is applied to points before `a`.
    pub fn mul(a: Affine2f, b: Affine2f) Affine2f {
        return .{
            .a = a.a * b.a + a.c * b.b,
            .b = a.b * b.a + a.d * b.b,
            .c = a.a * b.c + a.c * b.d,
            .d = a.b * b.c + a.d * b.d,
            .tx = a.a * b.tx + a.c * b.ty + a.tx,
            .ty = a.b * b.tx + a.d * b.ty + a.ty,
        };
    }

    /// The transform that undoes this one. Null when a component is not finite, when the
    /// determinant is within `f32` epsilon of zero (the transform flattens the plane), or when
    /// the inverse is not finite.
    pub fn inverse(self: Affine2f) ?Affine2f {
        inline for (std.meta.fields(Affine2f)) |field| if (!std.math.isFinite(@field(self, field.name))) return null;
        const determinant = self.a * self.d - self.b * self.c;
        if (!std.math.isFinite(determinant) or @abs(determinant) <= std.math.floatEps(f32)) return null;
        const inv = 1.0 / determinant;
        const a = self.d * inv;
        const b = -self.b * inv;
        const c = -self.c * inv;
        const d = self.a * inv;
        const result = Affine2f{ .a = a, .b = b, .c = c, .d = d, .tx = -(a * self.tx + c * self.ty), .ty = -(b * self.tx + d * self.ty) };
        inline for (std.meta.fields(Affine2f)) |field| if (!std.math.isFinite(@field(result, field.name))) return null;
        return result;
    }

    /// `point` transformed: the linear part, then the translation.
    pub fn apply(self: Affine2f, point: Vec2f) Vec2f {
        return .{ .x = self.a * point.x + self.c * point.y + self.tx, .y = self.b * point.x + self.d * point.y + self.ty };
    }

    /// `vector` transformed as a direction or offset: the linear part alone, no translation.
    pub fn applyVector(self: Affine2f, vector: Vec2f) Vec2f {
        return .{ .x = self.a * vector.x + self.c * vector.y, .y = self.b * vector.x + self.d * vector.y };
    }

    /// The angle of the transformed +X axis, in radians within [-pi, pi]: the rotation a
    /// transform made by `fromTRS` with positive scale was given.
    pub fn rotation(self: Affine2f) f32 {
        return std.math.atan2(self.b, self.a);
    }

    /// The lengths of the transformed +X and +Y axes: the scale along each, never negative, so a
    /// mirrored axis reads as positive.
    pub fn scaleOf(self: Affine2f) Vec2f {
        return .{ .x = @sqrt(self.a * self.a + self.b * self.b), .y = @sqrt(self.c * self.c + self.d * self.d) };
    }
};

/// A vector of 3 `f32`, laid out as 3 consecutive floats in the C layout.
pub const Vec3f = extern struct {
    /// The first component.
    x: f32,
    /// The second component.
    y: f32,
    /// The third component.
    z: f32,
    /// The components as a SIMD vector, in field order.
    pub inline fn simd(self: Vec3f) @Vector(3, f32) {
        return @bitCast(self);
    }
    /// The vector whose components are `v`'s, in field order.
    pub inline fn fromSimd(v: @Vector(3, f32)) Vec3f {
        return @bitCast(v);
    }
    /// The componentwise sum `a + b`.
    pub inline fn add(a: Vec3f, b: Vec3f) Vec3f {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }
    /// The componentwise difference `a - b`.
    pub inline fn sub(a: Vec3f, b: Vec3f) Vec3f {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }
    /// Every component of `a` multiplied by `s`.
    pub inline fn scale(a: Vec3f, s: f32) Vec3f {
        return .{ .x = a.x * s, .y = a.y * s, .z = a.z * s };
    }
    /// Every component of `a` negated.
    pub inline fn neg(a: Vec3f) Vec3f {
        return .{ .x = -a.x, .y = -a.y, .z = -a.z };
    }
};

/// A vector of 4 `f32`, laid out as 4 consecutive floats in the C layout.
pub const Vec4f = extern struct {
    /// The first component.
    x: f32,
    /// The second component.
    y: f32,
    /// The third component.
    z: f32,
    /// The fourth component.
    w: f32,
    /// The components as a SIMD vector, in field order.
    pub inline fn simd(self: Vec4f) @Vector(4, f32) {
        return @bitCast(self);
    }
    /// The vector whose components are `v`'s, in field order.
    pub inline fn fromSimd(v: @Vector(4, f32)) Vec4f {
        return @bitCast(v);
    }
    /// The componentwise sum `a + b`.
    pub inline fn add(a: Vec4f, b: Vec4f) Vec4f {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z, .w = a.w + b.w };
    }
    /// The componentwise difference `a - b`.
    pub inline fn sub(a: Vec4f, b: Vec4f) Vec4f {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z, .w = a.w - b.w };
    }
    /// Every component of `a` multiplied by `s`.
    pub inline fn scale(a: Vec4f, s: f32) Vec4f {
        return .{ .x = a.x * s, .y = a.y * s, .z = a.z * s, .w = a.w * s };
    }
    /// Every component of `a` negated.
    pub inline fn neg(a: Vec4f) Vec4f {
        return .{ .x = -a.x, .y = -a.y, .z = -a.z, .w = -a.w };
    }
};

/// A 4x4 matrix of `f32`, column-major: 16 consecutive floats, a column after another. It
/// multiplies column vectors, so a translation is in `cols[3]`.
pub const Mat4x4f = extern struct {
    /// The columns; `cols[c]`'s `x`, `y`, `z`, `w` are rows 0 to 3 of column `c`.
    cols: [4]Vec4f,

    /// The matrix that leaves every point where it is.
    pub const identity = Mat4x4f{ .cols = .{
        .{ .x = 1, .y = 0, .z = 0, .w = 0 },
        .{ .x = 0, .y = 1, .z = 0, .w = 0 },
        .{ .x = 0, .y = 0, .z = 1, .w = 0 },
        .{ .x = 0, .y = 0, .z = 0, .w = 1 },
    } };

    /// The product `a*b`: `b` is applied to points before `a`.
    pub fn mul(a: Mat4x4f, b: Mat4x4f) Mat4x4f {
        var result: Mat4x4f = undefined;
        inline for (0..4) |j| {
            result.cols[j] = Vec4f.fromSimd(
                a.cols[0].simd() * @as(@Vector(4, f32), @splat(b.cols[j].x)) +
                    a.cols[1].simd() * @as(@Vector(4, f32), @splat(b.cols[j].y)) +
                    a.cols[2].simd() * @as(@Vector(4, f32), @splat(b.cols[j].z)) +
                    a.cols[3].simd() * @as(@Vector(4, f32), @splat(b.cols[j].w)),
            );
        }
        return result;
    }

    /// The matrix that moves points by `t`.
    pub fn translation(t: Vec3f) Mat4x4f {
        var m = Mat4x4f.identity;
        m.cols[3] = .{ .x = t.x, .y = t.y, .z = t.z, .w = 1 };
        return m;
    }

    /// The matrix that scales each axis by the matching component of `s`, about the origin.
    pub fn scaling(s: Vec3f) Mat4x4f {
        var m = Mat4x4f.identity;
        m.cols[0].x = s.x;
        m.cols[1].y = s.y;
        m.cols[2].z = s.z;
        return m;
    }

    /// The matrix that scales, then rotates, then translates. `rotation` must be a unit
    /// quaternion.
    pub fn fromTRS(translation_: Vec3f, rotation: Quat4f, scale_: Vec3f) Mat4x4f {
        return mul(translation(translation_), mul(fromQuat(rotation), scaling(scale_)));
    }

    /// `point` transformed as a position (w = 1). The result is not divided by w, so this is for
    /// affine matrices, not projections.
    pub fn transformPoint(self: Mat4x4f, point: Vec3f) Vec3f {
        return .{
            .x = self.cols[0].x * point.x + self.cols[1].x * point.y + self.cols[2].x * point.z + self.cols[3].x,
            .y = self.cols[0].y * point.x + self.cols[1].y * point.y + self.cols[2].y * point.z + self.cols[3].y,
            .z = self.cols[0].z * point.x + self.cols[1].z * point.y + self.cols[2].z * point.z + self.cols[3].z,
        };
    }

    /// `vector` transformed as a direction (w = 0): the upper 3x3 alone, no translation.
    pub fn transformVector(self: Mat4x4f, vector: Vec3f) Vec3f {
        return .{
            .x = self.cols[0].x * vector.x + self.cols[1].x * vector.y + self.cols[2].x * vector.z,
            .y = self.cols[0].y * vector.x + self.cols[1].y * vector.y + self.cols[2].y * vector.z,
            .z = self.cols[0].z * vector.x + self.cols[1].z * vector.y + self.cols[2].z * vector.z,
        };
    }

    /// The matrix with rows and columns exchanged.
    pub fn transpose(self: Mat4x4f) Mat4x4f {
        return .{ .cols = .{
            .{ .x = self.cols[0].x, .y = self.cols[1].x, .z = self.cols[2].x, .w = self.cols[3].x },
            .{ .x = self.cols[0].y, .y = self.cols[1].y, .z = self.cols[2].y, .w = self.cols[3].y },
            .{ .x = self.cols[0].z, .y = self.cols[1].z, .z = self.cols[2].z, .w = self.cols[3].z },
            .{ .x = self.cols[0].w, .y = self.cols[1].w, .z = self.cols[2].w, .w = self.cols[3].w },
        } };
    }

    /// The inverse of any invertible matrix, projections included, by Gauss-Jordan elimination
    /// with partial pivoting in `f64`. Null when a component is not finite, a pivot is below
    /// 1e-12 (the matrix is singular), or the inverse is not finite in `f32`.
    pub fn inverse(self: Mat4x4f) ?Mat4x4f {
        var rows: [4][8]f64 = undefined;
        for (0..4) |r| {
            for (0..4) |c| {
                const v = switch (r) {
                    0 => self.cols[c].x,
                    1 => self.cols[c].y,
                    2 => self.cols[c].z,
                    else => self.cols[c].w,
                };
                if (!std.math.isFinite(v)) return null;
                rows[r][c] = v;
                rows[r][c + 4] = if (r == c) 1 else 0;
            }
        }
        for (0..4) |col| {
            var pivot = col;
            for (col + 1..4) |row| if (@abs(rows[row][col]) > @abs(rows[pivot][col])) {
                pivot = row;
            };
            if (@abs(rows[pivot][col]) < 1e-12) return null;
            if (pivot != col) std.mem.swap([8]f64, &rows[pivot], &rows[col]);
            const div = rows[col][col];
            for (0..8) |j| rows[col][j] /= div;
            for (0..4) |row| {
                if (row == col) continue;
                const factor = rows[row][col];
                for (0..8) |j| rows[row][j] -= factor * rows[col][j];
            }
        }
        var result: Mat4x4f = undefined;
        for (0..4) |c| {
            result.cols[c] = .{
                .x = @floatCast(rows[0][c + 4]),
                .y = @floatCast(rows[1][c + 4]),
                .z = @floatCast(rows[2][c + 4]),
                .w = @floatCast(rows[3][c + 4]),
            };
        }
        return if (finiteMat4(result)) result else null;
    }

    /// The rotation matrix of `q`, which must be a unit quaternion: it is not normalized here.
    pub fn fromQuat(q: Quat4f) Mat4x4f {
        const x = q.v.x;
        const y = q.v.y;
        const z = q.v.z;
        const w = q.v.w;
        return .{ .cols = .{
            .{ .x = 1 - 2 * (y * y + z * z), .y = 2 * (x * y + w * z), .z = 2 * (x * z - w * y), .w = 0 },
            .{ .x = 2 * (x * y - w * z), .y = 1 - 2 * (x * x + z * z), .z = 2 * (y * z + w * x), .w = 0 },
            .{ .x = 2 * (x * z + w * y), .y = 2 * (y * z - w * x), .z = 1 - 2 * (x * x + y * y), .w = 0 },
            .{ .x = 0, .y = 0, .z = 0, .w = 1 },
        } };
    }

    /// A right-handed perspective projection, the camera looking down -Z. `fov_y` is the full
    /// vertical field of view in radians, `aspect` width over height, `near` and `far` positive
    /// distances. View depth -`near` maps to -1 and -`far` to +1 after the divide by w.
    /// Unchecked: see `perspectiveChecked`.
    pub fn perspective(fov_y: f32, aspect: f32, near: f32, far: f32) Mat4x4f {
        const f = 1.0 / @tan(fov_y * 0.5);
        const nf = 1.0 / (near - far);
        return .{ .cols = .{
            .{ .x = f / aspect, .y = 0, .z = 0, .w = 0 },
            .{ .x = 0, .y = f, .z = 0, .w = 0 },
            .{ .x = 0, .y = 0, .z = (far + near) * nf, .w = -1 },
            .{ .x = 0, .y = 0, .z = 2 * far * near * nf, .w = 0 },
        } };
    }

    /// A right-handed orthographic projection, the camera looking down -Z: x in `left`..`right`
    /// maps to -1..+1, y in `bottom`..`top` to -1..+1, and view depth -`near`..-`far` to 0..1.
    /// Note the depth range differs from `perspective`'s. Unchecked: see `orthoChecked`.
    pub fn ortho(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) Mat4x4f {
        const rl = right - left;
        const tb = top - bottom;
        const fn_ = far - near;
        return .{ .cols = .{
            .{ .x = 2 / rl, .y = 0, .z = 0, .w = 0 },
            .{ .x = 0, .y = 2 / tb, .z = 0, .w = 0 },
            .{ .x = 0, .y = 0, .z = -1 / fn_, .w = 0 },
            .{ .x = -(right + left) / rl, .y = -(top + bottom) / tb, .z = -near / fn_, .w = 1 },
        } };
    }

    /// A right-handed view matrix: the camera at `eye` looks at `center`, its -Z towards it, with
    /// `up` roughly upwards. Unchecked: non-finite when `center` is `eye`, `up` is zero or `up`
    /// is parallel to the view direction; see `lookAtChecked`.
    pub fn lookAt(eye: Vec3f, center: Vec3f, up: Vec3f) Mat4x4f {
        const f = normalize(center.sub(eye));
        const s = normalize(cross(f, normalize(up)));
        const u = cross(s, f);
        return .{ .cols = .{
            .{ .x = s.x, .y = u.x, .z = -f.x, .w = 0 },
            .{ .x = s.y, .y = u.y, .z = -f.y, .w = 0 },
            .{ .x = s.z, .y = u.z, .z = -f.z, .w = 0 },
            .{ .x = -dot(s, eye), .y = -dot(u, eye), .z = dot(f, eye), .w = 1 },
        } };
    }
};

/// A quaternion of `f32` for 3D rotation, laid out as four consecutive floats.
pub const Quat4f = extern struct {
    /// The components: `x`, `y`, `z` are the vector part and `w` the scalar part.
    v: Vec4f,

    /// No rotation.
    pub const identity = Quat4f{ .v = .{ .x = 0, .y = 0, .z = 0, .w = 1 } };

    /// The rotation by `angle` radians about `axis`, counter-clockwise seen from the axis' tip.
    /// `axis` must be unit length for the result to be a unit quaternion.
    pub fn axisAngle(axis: Vec3f, angle: f32) Quat4f {
        const half = angle * 0.5;
        const s = @sin(half);
        return .{ .v = .{ .x = axis.x * s, .y = axis.y * s, .z = axis.z * s, .w = @cos(half) } };
    }

    /// The four-component dot product; `dot(q, q)` is the squared length.
    pub fn dot(a: Quat4f, b: Quat4f) f32 {
        return a.v.x * b.v.x + a.v.y * b.v.y + a.v.z * b.v.z + a.v.w * b.v.w;
    }

    /// The quaternion scaled to unit length. Null when its squared length is not finite or is
    /// below 1e-20.
    pub fn normalized(self: Quat4f) ?Quat4f {
        const len_sq = Quat4f.dot(self, self);
        if (!std.math.isFinite(len_sq) or len_sq < 1e-20) return null;
        const inv_len = 1.0 / @sqrt(len_sq);
        return .{ .v = .{ .x = self.v.x * inv_len, .y = self.v.y * inv_len, .z = self.v.z * inv_len, .w = self.v.w * inv_len } };
    }

    /// Every component negated: the same rotation, on the other side of the 4D sphere.
    pub fn negated(self: Quat4f) Quat4f {
        return .{ .v = .{ .x = -self.v.x, .y = -self.v.y, .z = -self.v.z, .w = -self.v.w } };
    }

    /// The rotation `amount` of the way from `a_` to `b_` along the shorter arc, at constant
    /// angular speed; always unit length. `amount_` is clamped to 0..1. The inputs are
    /// normalized first, and one that cannot be reads as `identity`. Quaternions whose dot
    /// product is above 0.9995 are blended linearly and normalized.
    pub fn slerp(a_: Quat4f, b_: Quat4f, amount_: f32) Quat4f {
        const a = a_.normalized() orelse identity;
        var b = b_.normalized() orelse identity;
        const amount = std.math.clamp(amount_, 0, 1);
        var cosine = Quat4f.dot(a, b);
        if (cosine < 0) {
            b = b.negated();
            cosine = -cosine;
        }
        if (cosine > 0.9995) {
            const blended = Quat4f{ .v = .{
                .x = a.v.x + (b.v.x - a.v.x) * amount,
                .y = a.v.y + (b.v.y - a.v.y) * amount,
                .z = a.v.z + (b.v.z - a.v.z) * amount,
                .w = a.v.w + (b.v.w - a.v.w) * amount,
            } };
            return blended.normalized() orelse identity;
        }
        const theta = std.math.acos(std.math.clamp(cosine, -1, 1));
        const sine = @sin(theta);
        const wa = @sin((1 - amount) * theta) / sine;
        const wb = @sin(amount * theta) / sine;
        return (Quat4f{ .v = .{
            .x = a.v.x * wa + b.v.x * wb,
            .y = a.v.y * wa + b.v.y * wb,
            .z = a.v.z * wa + b.v.z * wb,
            .w = a.v.w * wa + b.v.w * wb,
        } }).normalized() orelse identity;
    }
};

/// The dot product of `a` and `b`.
pub fn dot(a: Vec3f, b: Vec3f) f32 {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

/// The cross product `a x b`, right-handed.
pub fn cross(a: Vec3f, b: Vec3f) Vec3f {
    return .{
        .x = a.y * b.z - a.z * b.y,
        .y = a.z * b.x - a.x * b.z,
        .z = a.x * b.y - a.y * b.x,
    };
}

/// The Euclidean length of `v`.
pub fn length(v: Vec3f) f32 {
    return @sqrt(dot(v, v));
}

/// Why a `*Checked` function refused its input.
pub const DomainError = error{
    /// An input is NaN or infinite, or a vector is too long for its length to be finite.
    NonFiniteInput,
    /// The vertical field of view is not strictly between 0 and pi radians.
    InvalidFieldOfView,
    /// The aspect ratio is zero or negative.
    InvalidAspect,
    /// `near` is not positive, or `far` is not beyond `near`.
    InvalidPlanes,
    /// Two opposite bounds of an orthographic volume are equal.
    DegenerateBounds,
    /// A vector to normalize has zero length.
    DegenerateVector,
    /// The view direction and `up` are parallel, so no camera basis exists.
    DegenerateBasis,
    /// The inputs are valid but the matrix has a component that is not finite in `f32`.
    UnrepresentableResult,
};

fn finiteVec3(v: Vec3f) bool {
    return std.math.isFinite(v.x) and std.math.isFinite(v.y) and std.math.isFinite(v.z);
}

fn finiteMat4(matrix: Mat4x4f) bool {
    for (matrix.cols) |col| {
        if (!std.math.isFinite(col.x) or !std.math.isFinite(col.y) or
            !std.math.isFinite(col.z) or !std.math.isFinite(col.w)) return false;
    }
    return true;
}

/// `v` scaled to unit length. Fails with `NonFiniteInput` when a component or the length is
/// not finite, and `DegenerateVector` when the length is zero.
pub fn normalizeChecked(v: Vec3f) DomainError!Vec3f {
    if (!finiteVec3(v)) return error.NonFiniteInput;
    const len = length(v);
    if (!std.math.isFinite(len)) return error.NonFiniteInput;
    if (len == 0) return error.DegenerateVector;
    return v.scale(1.0 / len);
}

/// Checks the parameters of `Mat4x4f.perspective`: all finite (`NonFiniteInput`), `fov_y`
/// strictly between 0 and pi (`InvalidFieldOfView`), `aspect` positive (`InvalidAspect`), and
/// 0 < `near` < `far` (`InvalidPlanes`).
pub fn validatePerspective(fov_y: f32, aspect: f32, near: f32, far: f32) DomainError!void {
    if (!std.math.isFinite(fov_y) or !std.math.isFinite(aspect) or
        !std.math.isFinite(near) or !std.math.isFinite(far)) return error.NonFiniteInput;
    if (fov_y <= 0 or fov_y >= std.math.pi) return error.InvalidFieldOfView;
    if (aspect <= 0) return error.InvalidAspect;
    if (near <= 0 or far <= near) return error.InvalidPlanes;
}

/// `Mat4x4f.perspective` for parameters `validatePerspective` accepts; `UnrepresentableResult`
/// when the matrix is still not finite.
pub fn perspectiveChecked(fov_y: f32, aspect: f32, near: f32, far: f32) DomainError!Mat4x4f {
    try validatePerspective(fov_y, aspect, near, far);
    const matrix = Mat4x4f.perspective(fov_y, aspect, near, far);
    if (!finiteMat4(matrix)) return error.UnrepresentableResult;
    return matrix;
}

/// Checks the parameters of `Mat4x4f.ortho`: all finite (`NonFiniteInput`) and no two
/// opposite bounds equal (`DegenerateBounds`). A bound may lie on either side of its
/// opposite; reversed bounds mirror that axis.
pub fn validateOrtho(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) DomainError!void {
    const bounds = [_]f32{ left, right, bottom, top, near, far };
    for (bounds) |bound| if (!std.math.isFinite(bound)) return error.NonFiniteInput;
    if (left == right or bottom == top or near == far) return error.DegenerateBounds;
}

/// `Mat4x4f.ortho` for parameters `validateOrtho` accepts; `UnrepresentableResult` when the
/// matrix is still not finite.
pub fn orthoChecked(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) DomainError!Mat4x4f {
    try validateOrtho(left, right, bottom, top, near, far);
    const matrix = Mat4x4f.ortho(left, right, bottom, top, near, far);
    if (!finiteMat4(matrix)) return error.UnrepresentableResult;
    return matrix;
}

/// `Mat4x4f.lookAt`, refusing what it cannot make a camera from: `NonFiniteInput` for a
/// non-finite component, `DegenerateVector` when `center` equals `eye` or `up` is zero,
/// `DegenerateBasis` when `up` is parallel to the view direction, and
/// `UnrepresentableResult` when the matrix is not finite.
pub fn lookAtChecked(eye: Vec3f, center: Vec3f, up: Vec3f) DomainError!Mat4x4f {
    if (!finiteVec3(eye) or !finiteVec3(center) or !finiteVec3(up)) return error.NonFiniteInput;
    const forward = try normalizeChecked(center.sub(eye));
    const normalized_up = try normalizeChecked(up);
    _ = normalizeChecked(cross(forward, normalized_up)) catch |err| switch (err) {
        error.DegenerateVector => return error.DegenerateBasis,
        else => return err,
    };
    const matrix = Mat4x4f.lookAt(eye, center, up);
    if (!finiteMat4(matrix)) return error.UnrepresentableResult;
    return matrix;
}

/// `v` scaled to unit length, unchecked: a zero vector gives NaN components. See
/// `normalizeChecked`.
pub fn normalize(v: Vec3f) Vec3f {
    return v.scale(1.0 / length(v));
}

test "Affine2f composition and inverse preserve points" {
    const parent = Affine2f.fromTRS(20, -7, 0.35, 2, 0.5);
    const child = Affine2f.fromTRS(3, 4, -0.2, 1, 1);
    const composed = Affine2f.mul(parent, child);
    const point = Vec2f{ .x = 5, .y = -2 };
    const transformed = composed.apply(point);
    const restored = (composed.inverse() orelse return error.Singular).apply(transformed);
    try std.testing.expectApproxEqAbs(point.x, restored.x, 1e-5);
    try std.testing.expectApproxEqAbs(point.y, restored.y, 1e-5);
    const child_origin = parent.apply(.{ .x = 3, .y = 4 });
    const actual_origin = composed.apply(.{ .x = 0, .y = 0 });
    try std.testing.expectApproxEqAbs(child_origin.x, actual_origin.x, 1e-5);
    try std.testing.expectApproxEqAbs(child_origin.y, actual_origin.y, 1e-5);
}

test "Affine2f reflection retains signed determinant" {
    const mirrored = Affine2f.fromTRS(0, 0, 0, -1, 1);
    try std.testing.expect(mirrored.a * mirrored.d - mirrored.b * mirrored.c < 0);
    try std.testing.expect(mirrored.inverse() != null);
}

test "checked math constructors reject singular and non-finite domains" {
    try std.testing.expectError(error.InvalidAspect, perspectiveChecked(std.math.pi / 2.0, 0, 0.1, 100));
    try std.testing.expectError(error.NonFiniteInput, perspectiveChecked(std.math.nan(f32), 1, 0.1, 100));
    try std.testing.expectError(error.InvalidPlanes, perspectiveChecked(std.math.pi / 2.0, 1, 0, 100));
    try std.testing.expectError(error.UnrepresentableResult, perspectiveChecked(1e-40, 1, 0.1, 100));
    try std.testing.expectError(error.DegenerateBounds, orthoChecked(1, 1, -1, 1, 0, 10));
    try std.testing.expectError(error.DegenerateVector, normalizeChecked(.{ .x = 0, .y = 0, .z = 0 }));
    try std.testing.expectError(error.DegenerateBasis, lookAtChecked(.{ .x = 0, .y = 0, .z = 0 }, .{ .x = 0, .y = 0, .z = -1 }, .{ .x = 0, .y = 0, .z = -1 }));

    const perspective = try perspectiveChecked(std.math.pi / 2.0, 16.0 / 9.0, 0.1, 100);
    try std.testing.expect(std.math.isFinite(perspective.cols[0].x));
    const ortho = try orthoChecked(-2, 2, -1, 1, 0.1, 100);
    try std.testing.expect(std.math.isFinite(ortho.cols[0].x));
    const normalized = try normalizeChecked(.{ .x = 0, .y = 3, .z = 4 });
    try std.testing.expectApproxEqAbs(@as(f32, 1), length(normalized), 0.0001);
}
