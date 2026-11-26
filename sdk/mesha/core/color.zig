//! Colors are sRGB: what a color picker or hex code means, what render targets store, and what
//! blending operates on, as in Figma, Photoshop and Godot's 2D renderer. `LinearColor` exists for
//! math that needs linear light, and only explicit conversions cross between the two.
const std = @import("std");

/// sRGB-encoded channels and straight alpha, each 0 to 1.
pub const Color = struct {
    /// Red, sRGB-encoded.
    r: f32,
    /// Green, sRGB-encoded.
    g: f32,
    /// Blue, sRGB-encoded.
    b: f32,
    /// Opacity, straight (the color channels are not multiplied by it): 0 clear, 1 opaque.
    a: f32,

    /// Opaque black.
    pub const black = Color{ .r = 0, .g = 0, .b = 0, .a = 1 };
    /// Opaque white.
    pub const white = Color{ .r = 1, .g = 1, .b = 1, .a = 1 };
    /// Fully clear black: draws nothing.
    pub const transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
};

/// An opaque color from 8-bit sRGB channels, as a hex code gives them: `rgb(0xff, 0x80, 0)`.
pub fn rgb(r: u8, g: u8, b: u8) Color {
    return .{
        .r = @as(f32, @floatFromInt(r)) / 255.0,
        .g = @as(f32, @floatFromInt(g)) / 255.0,
        .b = @as(f32, @floatFromInt(b)) / 255.0,
        .a = 1.0,
    };
}

/// A color from 8-bit sRGB channels and 8-bit straight alpha (255 opaque).
pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
    return .{
        .r = @as(f32, @floatFromInt(r)) / 255.0,
        .g = @as(f32, @floatFromInt(g)) / 255.0,
        .b = @as(f32, @floatFromInt(b)) / 255.0,
        .a = @as(f32, @floatFromInt(a)) / 255.0,
    };
}

/// An opaque color from sRGB channels 0 to 1. The values are stored as given, not clamped.
pub fn rgbf(r: f32, g: f32, b: f32) Color {
    return .{ .r = r, .g = g, .b = b, .a = 1.0 };
}

/// A color from sRGB channels and straight alpha, each 0 to 1. The values are stored as
/// given, not clamped.
pub fn rgbaf(r: f32, g: f32, b: f32, a: f32) Color {
    return .{ .r = r, .g = g, .b = b, .a = a };
}

/// Linear-light channels and straight alpha. A distinct type, so it cannot reach a paint by
/// mistake.
pub const LinearColor = struct {
    /// Red, in linear light.
    r: f32,
    /// Green, in linear light.
    g: f32,
    /// Blue, in linear light.
    b: f32,
    /// Opacity, straight, 0 to 1: the same value as the sRGB color's.
    a: f32,

    /// `c` in linear light: each color channel through the sRGB decoding curve, alpha unchanged.
    pub fn fromSrgb(c: Color) LinearColor {
        return .{ .r = decodeSrgbChannel(c.r), .g = decodeSrgbChannel(c.g), .b = decodeSrgbChannel(c.b), .a = c.a };
    }

    /// The sRGB color for these linear channels: each through the sRGB encoding curve, alpha
    /// unchanged. Channels are not clamped.
    pub fn toSrgb(self: LinearColor) Color {
        return .{ .r = encodeSrgbChannel(self.r), .g = encodeSrgbChannel(self.g), .b = encodeSrgbChannel(self.b), .a = self.a };
    }
};

fn decodeSrgbChannel(c: f32) f32 {
    if (c <= 0.04045) return c / 12.92;
    return std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
}

fn encodeSrgbChannel(c: f32) f32 {
    if (c <= 0.0031308) return c * 12.92;
    return 1.055 * std.math.pow(f32, c, 1.0 / 2.4) - 0.055;
}

/// The channels as `{ r, g, b, a }`, still sRGB-encoded with straight alpha.
pub fn toArray(c: Color) [4]f32 {
    return .{ c.r, c.g, c.b, c.a };
}

/// `c` with its alpha replaced by the 8-bit `a` (255 opaque). The color channels are unchanged.
pub fn transRGBA(c: Color, a: u8) Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = @as(f32, @floatFromInt(a)) / 255.0 };
}

/// `c` with its alpha replaced by `a`, 0 to 1. The color channels are unchanged.
pub fn transRGBAf(c: Color, a: f32) Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = a };
}

/// The color `t` of the way from `a` (`t` = 0) to `b` (`t` = 1), each channel and alpha
/// blended on its sRGB-encoded value. `t` is not clamped.
pub fn lerpRGBA(a: Color, b: Color, t: f32) Color {
    const u = 1.0 - t;
    return .{
        .r = a.r * u + b.r * t,
        .g = a.g * u + b.g * t,
        .b = a.b * u + b.b * t,
        .a = a.a * u + b.a * t,
    };
}

/// An opaque color from hue, saturation and lightness; see `hsla`.
pub fn hsl(h: f32, s: f32, l: f32) Color {
    return hsla(h, s, l, 255);
}

/// A color from hue, saturation and lightness, with 8-bit alpha. `h_in` is the hue as a
/// fraction of a turn (0 red, 1/3 green, 2/3 blue) and wraps, so any value is valid; `s` and
/// `l` are clamped to 0..1. The result's channels are sRGB.
pub fn hsla(h_in: f32, s: f32, l: f32, a: u8) Color {
    var h = @mod(h_in, 1.0);
    if (h < 0.0) h += 1.0;
    const s_clamped = std.math.clamp(s, 0.0, 1.0);
    const l_clamped = std.math.clamp(l, 0.0, 1.0);
    const m2: f32 = if (l_clamped <= 0.5)
        l_clamped * (1.0 + s_clamped)
    else
        l_clamped + s_clamped - l_clamped * s_clamped;
    const m1 = 2.0 * l_clamped - m2;
    return .{
        .r = std.math.clamp(hue(h + 1.0 / 3.0, m1, m2), 0.0, 1.0),
        .g = std.math.clamp(hue(h, m1, m2), 0.0, 1.0),
        .b = std.math.clamp(hue(h - 1.0 / 3.0, m1, m2), 0.0, 1.0),
        .a = @as(f32, @floatFromInt(a)) / 255.0,
    };
}

fn hue(h_in: f32, m1: f32, m2: f32) f32 {
    var h = h_in;
    if (h < 0) h += 1;
    if (h > 1) h -= 1;
    if (h < 1.0 / 6.0) return m1 + (m2 - m1) * h * 6.0;
    if (h < 3.0 / 6.0) return m2;
    if (h < 4.0 / 6.0) return m1 + (m2 - m1) * (2.0 / 3.0 - h) * 6.0;
    return m1;
}

test "rgb round-trip" {
    const c = rgb(255, 128, 0);
    try std.testing.expectApproxEqAbs(c.r, 1.0, 1e-5);
    try std.testing.expectApproxEqAbs(c.g, 128.0 / 255.0, 1e-4);
    try std.testing.expectApproxEqAbs(c.b, 0.0, 1e-5);
    try std.testing.expectApproxEqAbs(c.a, 1.0, 1e-5);
}

test "lerpRGBA" {
    const a = Color.black;
    const b = Color.white;
    const mid = lerpRGBA(a, b, 0.5);
    try std.testing.expectApproxEqAbs(mid.r, 0.5, 1e-5);
}

test "hsl white" {
    const c = hsl(0, 0, 1);
    try std.testing.expectApproxEqAbs(c.r, 1.0, 1e-5);
    try std.testing.expectApproxEqAbs(c.g, 1.0, 1e-5);
    try std.testing.expectApproxEqAbs(c.b, 1.0, 1e-5);
}

test "linear conversion follows the sRGB curve, leaves alpha alone and round-trips" {
    const mid_gray = rgba(188, 188, 188, 128);
    const linear = LinearColor.fromSrgb(mid_gray);
    try std.testing.expectApproxEqAbs(@as(f32, 0.503), linear.r, 0.001);
    try std.testing.expectEqual(mid_gray.a, linear.a);
    const back = linear.toSrgb();
    try std.testing.expectApproxEqAbs(mid_gray.r, back.r, 0.0001);
    try std.testing.expectEqual(mid_gray.a, back.a);
}
