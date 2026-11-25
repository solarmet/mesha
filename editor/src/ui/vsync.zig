//! Vsync bands for frame time charts. A vsynced frame lasts a whole number of display
//! refreshes, so a chart of frame times reads best against bands at each multiple of the
//! refresh interval: the first band is a frame on time, the next one a frame late, and so on.
//! Bands go up to `band_limit_ms`, in greens that darken as the frame gets longer.
const std = @import("std");
const mesha = @import("mesha");
const Atom = mesha.Atom;
const Table = mesha.Table;
const roop = mesha.roop;

/// The host's `display` table; see `src/main.zig`.
const display_table = "display";
/// Only until the host has read the display's rate, on its first frames: every chart uses
/// the rate the host publishes.
const fallback_hz: f32 = 60;
/// Bands go on until they cover this: two refreshes at 60 Hz, five at 144 Hz.
pub const band_limit_ms: f32 = 1000.0 / 30.0;
/// Bands at more multiples than this would be too thin to tell apart.
const max_bands = 12;

/// One refresh of the display the window is on, in milliseconds.
pub fn intervalMs(tables: *Table.Registry, atoms: *Atom.Registry) f32 {
    const table = tables.findByName(atoms.intern(display_table)) orelse return 1000 / fallback_hz;
    var rows = table.query(struct { refresh_hz: *f32 });
    const row = rows.next() orelse return 1000 / fallback_hz;
    const hz = row.view.refresh_hz.*;
    if (!std.math.isFinite(hz) or hz < 1) return 1000 / fallback_hz;
    return 1000 / hz;
}

/// The green of band `index` of `count`: brightest for a frame on time, darker for each
/// refresh later.
pub fn bandColor(index: usize, count: usize) roop.Color {
    const bright = [3]f32{ 74, 156, 92 };
    const dark = [3]f32{ 22, 58, 34 };
    const t: f32 = if (count <= 1) 0 else @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(count - 1));
    return .{
        .r = (bright[0] + (dark[0] - bright[0]) * t) / 255,
        .g = (bright[1] + (dark[1] - bright[1]) * t) / 255,
        .b = (bright[2] + (dark[2] - bright[2]) * t) / 255,
        .a = 0.38,
    };
}

/// How many bands it takes to cover `band_limit_ms` at `interval_ms`.
pub fn bandCount(interval_ms: f32) usize {
    if (interval_ms <= 0) return 0;
    // A hair under, so 2 x 16.67 counts as covering 33.33 without a third band.
    const count: usize = @intFromFloat(@ceil(band_limit_ms / interval_ms - 0.01));
    return @min(@max(count, 1), max_bands);
}

/// Fills the bands across a chart `width` wide and `height` tall whose top stands for
/// `top_ms`. When `font` is given, each band's top edge is labelled with its time.
pub fn drawBands(ctx: *roop.Context, width: f32, height: f32, top_ms: f32, interval_ms: f32, font: ?Atom) void {
    if (top_ms <= 0 or width <= 0 or height <= 0) return;
    const count = bandCount(interval_ms);
    for (0..count) |index| {
        const low_ms = interval_ms * @as(f32, @floatFromInt(index));
        const high_ms = @min(interval_ms * @as(f32, @floatFromInt(index + 1)), top_ms);
        if (low_ms >= top_ms) break;
        const y_top = @round(height * (1 - high_ms / top_ms));
        const y_bottom = @round(height * (1 - low_ms / top_ms));
        ctx.beginPath();
        ctx.rect(0, y_top, width, y_bottom - y_top);
        ctx.fillColor(bandColor(index, count));
        ctx.fill();
        // The line where a frame becomes one refresh later.
        ctx.beginPath();
        ctx.rect(0, y_top, width, 1);
        ctx.fillColor(.{ .r = 0.45, .g = 0.75, .b = 0.5, .a = 0.35 });
        ctx.fill();
        const label_font = font orelse continue;
        if (y_bottom - y_top < 12) continue;
        var buffer: [16]u8 = undefined;
        const label = std.fmt.bufPrint(&buffer, "{d:.1}", .{interval_ms * @as(f32, @floatFromInt(index + 1))}) catch continue;
        ctx.fontFace(label_font);
        ctx.textAlign(.{ .left = true, .baseline = true });
        const label_width = ctx.measureText(label_font, label).w;
        ctx.fillColor(.{ .r = 0.6, .g = 0.85, .b = 0.65, .a = 0.9 });
        _ = ctx.text(@round(width - label_width - 4), y_top + 12, label);
    }
}

/// The bands' top edges and their times, to draw over a chart that covers the bands, such
/// as bars: a line across at each refresh, labelled at the left on a dark backing. Labels go
/// from the bottom up, and one that would overlap a label under it is left out.
pub fn drawBandEdges(ctx: *roop.Context, width: f32, height: f32, top_ms: f32, interval_ms: f32, font: Atom) void {
    if (top_ms <= 0 or width <= 0 or height <= 0) return;
    const count = bandCount(interval_ms);
    ctx.fontFace(font);
    ctx.textAlign(.{ .left = true, .baseline = true });
    const ascender = @round(ctx.fontAscender(font));
    const label_height = ascender + 4;
    // The top of the highest label drawn so far.
    var labels_top = height + label_height;
    for (0..count) |index| {
        const edge_ms = interval_ms * @as(f32, @floatFromInt(index + 1));
        if (edge_ms > top_ms) break;
        const y = @round(height * (1 - edge_ms / top_ms));
        var line = bandColor(index, count);
        line.a = 0.95;
        ctx.beginPath();
        ctx.rect(0, y, width, 1);
        ctx.fillColor(line);
        ctx.fill();
        var buffer: [16]u8 = undefined;
        const label = std.fmt.bufPrint(&buffer, "{d:.1} ms", .{edge_ms}) catch continue;
        const label_width = ctx.measureText(font, label).w;
        // Just above its line, unless that would leave the chart.
        const baseline = if (y - 2 - ascender < 0) y + ascender + 2 else y - 2;
        const label_top = baseline - ascender - 1;
        if (label_top + label_height + 1 > labels_top) continue;
        labels_top = label_top;
        ctx.beginPath();
        ctx.roundedRect(2, label_top, label_width + 6, label_height, 3);
        ctx.fillColor(.{ .r = 0.08, .g = 0.08, .b = 0.09, .a = 0.85 });
        ctx.fill();
        ctx.fillColor(.{ .r = 0.6, .g = 0.85, .b = 0.65, .a = 1 });
        _ = ctx.text(5, baseline, label);
    }
}

test "bands reach two frames at 60 Hz, more at faster rates, darkening as they go" {
    try std.testing.expectEqual(@as(usize, 2), bandCount(1000.0 / 60.0));
    try std.testing.expectEqual(@as(usize, 4), bandCount(1000.0 / 120.0));
    // 144 Hz: five refreshes, 34.7 ms, to cover 33 ms.
    try std.testing.expectEqual(@as(usize, 5), bandCount(1000.0 / 144.0));
    try std.testing.expectEqual(@as(usize, 1), bandCount(1000.0 / 30.0));
    const first = bandColor(0, 3);
    const last = bandColor(2, 3);
    try std.testing.expect(last.g < first.g);
}
