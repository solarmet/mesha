//! Paints: how a fill or a stroke is colored. A `Paint` is a solid color, a gradient between two
//! colors or an image pattern, made by the constructors here and given to a `Context` (`fillPaint`,
//! `strokePaint`), which binds its coordinates to the transform current at that call. Also the
//! blend modes and compositing operations a layer takes (`layer_stream.Begin`).
const std = @import("std");
const transform = @import("transform.zig");
const color = @import("../../core/color.zig");

/// A 2D affine transform as six floats (`transform.Transform2D`).
pub const Transform2D = transform.Transform2D;
/// A color in sRGB-encoded channels with straight alpha, each 0 to 1.
pub const Color = color.Color;

/// An image handle: 0 for none, else as the runtime registered it, from 1
/// (`renderer.Renderer.images`). The handle of a retired image must not be drawn with.
pub const Image = u32;

/// Options for an image. Nothing reads them: how an image is sampled is its sampler's, which
/// whoever registers the image makes.
pub const ImageFlags = packed struct(u32) {
    /// Unread.
    generate_mipmaps: bool = false,
    /// Unread.
    repeat_x: bool = false,
    /// Unread.
    repeat_y: bool = false,
    /// Unread.
    flip_y: bool = false,
    /// Unread.
    premultiplied: bool = false,
    /// Unread.
    nearest: bool = false,
    /// Unused bits, zero.
    _pad: u26 = 0,
};

/// How a shape is colored. Every paint is one form: a rounded box, `extent` in half size with
/// corners of `radius`, in the paint's own frame; `inner_color` inside it turns to `outer_color`
/// outside it over `feather`. With an image, the image is drawn in place of the colors.
pub const Paint = struct {
    /// Maps the coordinates the shape is drawn in to the paint's frame. A constructor makes it from
    /// the coordinates current when the paint is given to a `Context`, which then takes the
    /// transform into it, so it maps target pixels.
    xform: Transform2D,
    /// The box's half width and half height; for an image, the size one copy of the image covers.
    extent: [2]f32,
    /// The box's corner radius.
    radius: f32,
    /// The distance over which the inner color turns to the outer, centered on the box's edge.
    feather: f32,
    /// The color inside the box; with an image, its tint (the constructors make it white with the
    /// pattern's alpha).
    inner_color: Color,
    /// The color outside the box.
    outer_color: Color,
    /// The image drawn, or 0 for a paint of colors alone.
    image: Image,
};

/// A paint that is `c` everywhere.
pub fn solidColor(c: Color) Paint {
    return .{
        .xform = transform.identity(),
        .extent = .{ 0, 0 },
        .radius = 0,
        .feather = 1,
        .inner_color = c,
        .outer_color = c,
        .image = 0,
    };
}

/// A paint that is `icol` at `sx, sy` and `ocol` at `ex, ey`, blending along the line between and
/// constant beyond each end. Two points less than 0.0001 apart give a gradient down the y axis one
/// unit long.
pub fn linearGradient(
    sx: f32,
    sy: f32,
    ex: f32,
    ey: f32,
    icol: Color,
    ocol: Color,
) Paint {
    const kLarge = 1e5;
    const dx = ex - sx;
    const dy = ey - sy;
    const d = @sqrt(dx * dx + dy * dy);

    const ndx = if (d > 0.0001) dx / d else 0;
    const ndy = if (d > 0.0001) dy / d else 1;

    const xform: Transform2D = .{
        ndy,               -ndx,
        ndx,               ndy,
        sx - ndx * kLarge, sy - ndy * kLarge,
    };
    return .{
        .xform = transform.inverse(xform) orelse transform.identity(),
        .extent = .{ kLarge, kLarge + d * 0.5 },
        .radius = 0,
        .feather = @max(d, 1),
        .inner_color = icol,
        .outer_color = ocol,
        .image = 0,
    };
}

/// A paint around `cx, cy` that is `icol` within `inr`, `ocol` beyond `outr`, blending between.
/// Radii less than one unit apart blend over one unit.
pub fn radialGradient(
    cx: f32,
    cy: f32,
    inr: f32,
    outr: f32,
    icol: Color,
    ocol: Color,
) Paint {
    const r = (inr + outr) * 0.5;
    const f = outr - inr;
    const xform: Transform2D = .{ 1, 0, 0, 1, cx, cy };
    return .{
        .xform = transform.inverse(xform) orelse transform.identity(),
        .extent = .{ r, r },
        .radius = r,
        .feather = @max(f, 1),
        .inner_color = icol,
        .outer_color = ocol,
        .image = 0,
    };
}

/// A paint that is `icol` inside the rectangle `x, y, w, h` with corners of radius `r`, and `ocol`
/// outside it, blending over `f` (at least 1) across its edge: a soft-edged box, as a shadow is.
pub fn boxGradient(
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    r: f32,
    f: f32,
    icol: Color,
    ocol: Color,
) Paint {
    const xform: Transform2D = .{ 1, 0, 0, 1, x + w * 0.5, y + h * 0.5 };
    return .{
        .xform = transform.inverse(xform) orelse transform.identity(),
        .extent = .{ w * 0.5, h * 0.5 },
        .radius = r,
        .feather = @max(f, 1),
        .inner_color = icol,
        .outer_color = ocol,
        .image = 0,
    };
}

/// A paint that draws `img`: its top left corner at `ox, oy`, one copy covering `ex` by `ey`,
/// turned by `angle` radians about that corner, at opacity `alpha`. What lies outside one copy,
/// repeated or clamped, is the image's sampler's.
pub fn imagePattern(
    ox: f32,
    oy: f32,
    ex: f32,
    ey: f32,
    angle: f32,
    img: Image,
    alpha: f32,
) Paint {
    const rot = transform.rotation(angle);
    const t: Transform2D = .{
        rot[0], rot[1],
        rot[2], rot[3],
        ox,     oy,
    };
    return .{
        .xform = transform.inverse(t) orelse transform.identity(),
        .extent = .{ ex, ey },
        .radius = 0,
        .feather = 1,
        .inner_color = color.rgbaf(1, 1, 1, alpha),
        .outer_color = color.rgbaf(1, 1, 1, alpha),
        .image = img,
    };
}

/// A layer's blend modes: how its colors mix with what is beneath, apart from coverage.
pub const blend = struct {
    /// The modes, numbered as the blend shader reads them. `unsupported` stands for a mode the
    /// renderer cannot draw: a layer that asks for it is refused.
    pub const Mode = enum(u32) { normal, multiply, screen, overlay, darken, lighten, color_dodge, color_burn, hard_light, soft_light, difference, exclusion, add, hue, saturation, color, luminosity, unsupported };
};

/// Porter-Duff coverage operations; inputs and outputs are premultiplied. `lighter` sums coverage
/// and color, clamped by the UNORM render target.
pub const composite = struct {
    /// The operations, source being the layer and destination what is beneath it. `source_over` is
    /// ordinary drawing.
    pub const Operation = enum { source_over, source_in, source_out, atop, destination_over, destination_in, destination_out, destination_atop, lighter, copy, xor };

    /// Whether a wholly transparent source leaves the destination as it was under `op`. Where it
    /// does not, the layer must be composited even at zero opacity.
    pub fn preservesDestinationAtZeroSource(op: Operation) bool {
        return switch (op) {
            .source_in, .source_out, .destination_in, .destination_atop, .copy => false,
            else => true,
        };
    }
};
