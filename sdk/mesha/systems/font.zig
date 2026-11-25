//! A baked font's shape, shared by the runtime's baker (`runtime/font.zig`), the resources system
//! that keeps fonts, and `roop.Context`, which draws text from them. A font is one square atlas of
//! coverage and a `Glyph` for each codepoint baked, at one pixel height. It is baked with either a
//! contiguous range of `kNumChars` codepoints from a first one, or a list of up to `kMaxCodepoints`
//! codepoints (`resources.ResourceDecl`). Also here: the icon codepoints the editor bakes its icon
//! fonts with, and the checks on what a bake is asked for.
const std = @import("std");

/// The side of a font's square atlas, in texels.
pub const kAtlasSize: u32 = 512;
/// The first codepoint of the contiguous range a font is baked with unless told another: space.
pub const kFirstChar: u32 = 32;
/// How many codepoints a contiguous range holds.
pub const kNumChars: u32 = 96;

/// One baked glyph: its box in the atlas and how to place and advance it. Laid out as
/// stb_truetype's `stbtt_bakedchar`, which the runtime bakes into; the runtime asserts the layout.
pub const Glyph = extern struct {
    /// The left of the glyph's box in the atlas, in texels.
    x0: c_ushort,
    /// The top of its box.
    y0: c_ushort,
    /// The right of its box, exclusive. A glyph with no ink has `x1 == x0`.
    x1: c_ushort,
    /// The bottom of its box, exclusive.
    y1: c_ushort,
    /// From the pen position to the box's left, in pixels.
    xoff: f32,
    /// From the baseline to the box's top, in pixels, y down: negative for ink above the baseline.
    yoff: f32,
    /// How far the pen moves after the glyph, in pixels.
    xadvance: f32,
};
/// The glyphs of a contiguous range, indexed by codepoint less the range's first.
pub const BakedChars = [kNumChars]Glyph;

/// The Material Design codepoints the editor draws, in the order of its `Icon` enum
/// (`editor/src/ui/button.zig`) after that enum's first five.
pub const icon_codepoints = [_]u32{
    0xf01c0, 0xf1225, 0xf03ea, 0xf03eb, 0xf0e5f, 0xf0ea1, 0xf055e, 0xf0560,
    0xf00b9, 0xf064d, 0xf0266, 0xf174a, 0xf1853, 0xf020a, 0xf0467, 0xf0a68,
    0xf0e46, 0xf034b, 0xf034a, 0xf18f4, 0xf02c1, 0xf0347, 0xf0208, 0xf0209,
    0xf033e, 0xf033f, 0xf0328, 0xf024b, 0xf0770, 0xf0415, 0xf0374, 0xf01b4,
    0xf054c, 0xf044e, 0xf0193, 0xf040a, 0xf03e4, 0xf04ae, 0xf04ad, 0xf0f96,
    0xf1534, 0xf0fe8, 0xf0403, 0xf00e3, 0xf10e7, 0xf03d8, 0xf0493, 0xf1353,
    0xf05a1, 0xf02e6, 0xf158f, 0xf10aa, 0xf10ab, 0xf1513, 0xf10a9, 0xf10ac,
    0xf01fe, 0xf044a, 0xf05af, 0xf05b2,
};

/// The pixel height the editor bakes its `icon_rail` font at.
pub const kRailIconPixelHeight: f32 = 34;
/// The pixel height the editor bakes its `icon_row` font at.
pub const kRowIconPixelHeight: f32 = 20;
/// The codepoints the editor bakes `icon_rail` and `icon_row` with: `icon_codepoints` and five
/// more.
pub const rail_icon_codepoints = icon_codepoints ++ [_]u32{ 0xf060, 0xf067, 0xf068, 0xf06e, 0xf070 };

/// The codepoints the editor bakes its 16 pixel `icon` font with: the `kNumChars` from `0xf060`,
/// then `icon_codepoints`.
pub const legacy_icon_codepoints = blk: {
    var codepoints: [kNumChars + icon_codepoints.len]u32 = undefined;
    for (0..kNumChars) |i| codepoints[i] = 0xf060 + @as(u32, @intCast(i));
    @memcpy(codepoints[kNumChars..], &icon_codepoints);
    break :blk codepoints;
};

/// The most codepoints a font may be baked with by list.
pub const kMaxCodepoints: usize = 192;
/// Room for a listed font's codepoints.
pub const Codepoints = [kMaxCodepoints]u32;
/// Room for a listed font's glyphs.
pub const ListedChars = [kMaxCodepoints]Glyph;
/// The glyphs of a font baked by list.
pub const ListedGlyphs = struct {
    /// The codepoints baked; the first `count` are set.
    codepoints: Codepoints = std.mem.zeroes(Codepoints),
    /// Each codepoint's glyph, at its codepoint's index.
    baked_chars: ListedChars = std.mem.zeroes(ListedChars),
    /// How many codepoints were baked; 0 for a font baked by range.
    count: u32 = 0,
};

/// What is wrong with what a bake was asked for: `EmptyFontData`, no font file bytes, which the
/// runtime's baker returns; `InvalidPixelHeight`, a height not finite, not above zero or over
/// `kAtlasSize`; `InvalidCodepointRange`, a range that leaves Unicode or crosses the surrogates;
/// `EmptyCodepointList`; `TooManyCodepoints`, more than `kMaxCodepoints`; `InvalidCodepoint`, one
/// past `0x10ffff` or a surrogate; `DuplicateCodepoint`.
pub const BakeInputError = error{ EmptyFontData, InvalidPixelHeight, InvalidCodepointRange, EmptyCodepointList, TooManyCodepoints, InvalidCodepoint, DuplicateCodepoint };

/// Checks a bake by list: the pixel height, then that `codepoints` is not empty, not over
/// `kMaxCodepoints`, and holds only valid codepoints, each once.
pub fn validateCodepoints(pixel_height: f32, codepoints: []const u32) BakeInputError!void {
    if (!std.math.isFinite(pixel_height) or pixel_height <= 0 or pixel_height > kAtlasSize)
        return error.InvalidPixelHeight;
    if (codepoints.len == 0) return error.EmptyCodepointList;
    if (codepoints.len > kMaxCodepoints) return error.TooManyCodepoints;
    for (codepoints, 0..) |codepoint, i| {
        if (codepoint > 0x10ffff or (codepoint >= 0xd800 and codepoint <= 0xdfff)) return error.InvalidCodepoint;
        for (codepoints[0..i]) |previous| {
            if (codepoint == previous) return error.DuplicateCodepoint;
        }
    }
}

/// Checks a bake by range: the pixel height, then that the `kNumChars` codepoints from `first_char`
/// stay within Unicode and clear of the surrogates.
pub fn validateBakeParameters(pixel_height: f32, first_char: u32) BakeInputError!void {
    if (!std.math.isFinite(pixel_height) or pixel_height <= 0 or pixel_height > kAtlasSize)
        return error.InvalidPixelHeight;
    const last_char = std.math.add(u32, first_char, kNumChars - 1) catch return error.InvalidCodepointRange;
    if (last_char > 0x10ffff or (first_char <= 0xdfff and last_char >= 0xd800))
        return error.InvalidCodepointRange;
}
