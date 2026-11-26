//! The profiler's timeline and frame strip: geometry, drawing and hit testing.
//!
//! A lane holds one thread's zones, one list per depth in begin order. Drawing walks a
//! depth's zones from the first one the view reaches, with a binary search, and stops past
//! the view's end. Neighbouring zones narrower than a pixel merge into one span, as Tracy
//! does, so a depth costs time in proportion to its width in pixels, not its zone count.
//! `zoneAt` walks the same spans, so what can be hit is exactly what is drawn.
//!
//! A lane's log messages are markers in its header, coloured by level, as Tracy draws them;
//! `messageAt` finds the one nearest the pointer there.
const std = @import("std");
const mesha = @import("mesha");
const Atom = mesha.Atom;
const roop = mesha.roop;
const math = mesha.math;
const plugin = mesha.plugin;

const profiler_api = plugin.profiler_api;
const vsync = @import("../ui/vsync.zig");
const style = @import("../ui/style.zig");
const Record = profiler_api.Record;
const Message = profiler_api.Message;
const Level = mesha.log.Level;

/// A span narrower than this merges with narrow neighbours.
pub const min_span_width: f32 = 1;
/// A span's row and a lane's name: a line of `style.small_font`, which the profiler draws them in.
pub const row_height: f32 = style.metric.small_text_line + 1;
pub const lane_header_height: f32 = style.metric.small_text_line + 1;

/// The part of time on screen, `width` pixels across.
pub const View = struct {
    begin_ns: f64,
    end_ns: f64,
    width: f32,

    pub fn xOf(view: View, ns: f64) f32 {
        const span = @max(view.end_ns - view.begin_ns, 1);
        const x = (ns - view.begin_ns) / span * view.width;
        return @floatCast(std.math.clamp(x, -1e7, 1e7));
    }

    pub fn nsAt(view: View, x: f32) f64 {
        const span = @max(view.end_ns - view.begin_ns, 1);
        const fraction: f64 = @as(f64, x) / @max(view.width, 1);
        return view.begin_ns + fraction * span;
    }

    /// The view scaled by `factor` around the time under `x`; less than 1 zooms in.
    pub fn zoomed(view: View, x: f32, factor: f64) View {
        const anchor = view.nsAt(x);
        const span = @max((view.end_ns - view.begin_ns) * factor, 100);
        const before: f64 = @as(f64, x) / @max(view.width, 1) * span;
        return .{ .begin_ns = anchor - before, .end_ns = anchor - before + span, .width = view.width };
    }

    /// The view moved by `dx` pixels, so the time under the pointer follows it.
    pub fn panned(view: View, dx: f32) View {
        const shift = view.nsAt(0) - view.nsAt(dx);
        return .{ .begin_ns = view.begin_ns + shift, .end_ns = view.end_ns + shift, .width = view.width };
    }
};

/// One drawn piece of a depth: a zone, or `count` merged neighbours.
pub const Span = struct {
    first: usize,
    count: usize,
    x0: f32,
    x1: f32,

    pub fn contains(span: Span, x: f32) bool {
        return x >= span.x0 and x < span.x1;
    }
};

/// The spans of one depth's zones that the view reaches, left to right.
pub const Spans = struct {
    zones: []const Record,
    view: View,
    index: usize,

    pub fn init(zones: []const Record, view: View) Spans {
        return .{ .zones = zones, .view = view, .index = firstReaching(zones, view.begin_ns) };
    }

    pub fn next(spans: *Spans) ?Span {
        if (spans.index >= spans.zones.len) return null;
        const first = spans.index;
        const zone = spans.zones[first];
        const begin: f64 = @floatFromInt(zone.begin_ns);
        if (begin > spans.view.end_ns) return null;
        const x0 = spans.view.xOf(begin);
        var x1 = spans.view.xOf(@floatFromInt(zone.endNs()));
        spans.index += 1;
        if (x1 - x0 >= min_span_width) return .{ .first = first, .count = 1, .x0 = x0, .x1 = x1 };
        // Narrow neighbours that start within a pixel of the run join it.
        while (spans.index < spans.zones.len) {
            const neighbour = spans.zones[spans.index];
            const neighbour_begin: f64 = @floatFromInt(neighbour.begin_ns);
            if (neighbour_begin > spans.view.end_ns) break;
            const nx0 = spans.view.xOf(neighbour_begin);
            const nx1 = spans.view.xOf(@floatFromInt(neighbour.endNs()));
            if (nx1 - nx0 >= min_span_width or nx0 - x1 >= min_span_width) break;
            x1 = @max(x1, nx1);
            spans.index += 1;
        }
        return .{ .first = first, .count = spans.index - first, .x0 = x0, .x1 = @max(x1, x0 + min_span_width) };
    }
};

/// The first zone that ends at or after `ns`. Zones at one depth never overlap, so their
/// ends are in order too.
fn firstReaching(zones: []const Record, ns: f64) usize {
    var low: usize = 0;
    var high: usize = zones.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const end: f64 = @floatFromInt(zones[middle].endNs());
        if (end < ns) low = middle + 1 else high = middle;
    }
    return low;
}

/// The first zone that begins at or after `ns`.
fn firstBeginning(zones: []const Record, ns: u64) usize {
    var low: usize = 0;
    var high: usize = zones.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (zones[middle].begin_ns < ns) low = middle + 1 else high = middle;
    }
    return low;
}

pub const Hit = struct { depth: usize, span: Span };

/// The message levels the panel shows, as a mask of `LevelGroup` bits.
pub const LevelGroup = enum(u3) {
    debug,
    info,
    warn,
    err,

    pub fn of(level: Level) LevelGroup {
        return switch (level) {
            .trace, .debug => .debug,
            .info => .info,
            .warn => .warn,
            .err, .fatal => .err,
        };
    }

    pub fn bit(group: LevelGroup) u8 {
        return @as(u8, 1) << @intFromEnum(group);
    }
};

pub const all_levels: u8 = 0b1111;

pub fn levelShown(levels: u8, level: Level) bool {
    return levels & LevelGroup.of(level).bit() != 0;
}

/// A message's marker colour, by its level.
pub fn messageColor(level: Level) roop.Color {
    return switch (LevelGroup.of(level)) {
        .debug => roop.rgba(150, 150, 160, 255),
        .info => roop.rgba(120, 195, 255, 255),
        .warn => roop.rgba(240, 195, 110, 255),
        .err => roop.rgba(255, 84, 112, 255),
    };
}

pub fn levelName(level: Level) []const u8 {
    return switch (level) {
        .trace => "trace",
        .debug => "debug",
        .info => "info",
        .warn => "warn",
        .err => "error",
        .fatal => "fatal",
    };
}

/// How near the pointer, in pixels, a message's marker must be to be under it.
pub const message_hit_radius: f32 = 5;

/// The shown message whose marker is nearest `x`, within the hit radius; an index into
/// `messages`.
pub fn messageAt(messages: []const Message, view: View, levels: u8, x: f32) ?usize {
    var nearest: ?usize = null;
    var nearest_distance: f32 = message_hit_radius;
    for (messages, 0..) |message, index| {
        if (!levelShown(levels, message.level)) continue;
        const distance = @abs(view.xOf(@floatFromInt(message.begin_ns)) - x);
        if (distance > nearest_distance) continue;
        // Ties go to the more severe, as it is drawn on top.
        if (distance == nearest_distance and nearest != null and @intFromEnum(messages[nearest.?].level) >= @intFromEnum(message.level)) continue;
        nearest = index;
        nearest_distance = distance;
    }
    return nearest;
}

/// What is drawn under `x`, `y` in a lane's rows (below its header), if anything.
pub fn zoneAt(depths: []const []const Record, view: View, x: f32, y: f32) ?Hit {
    if (y < 0 or x < 0 or x >= view.width) return null;
    const depth: usize = @intFromFloat(@floor(y / row_height));
    if (depth >= depths.len) return null;
    // Spans may overlap by their last pixel; the later one is drawn on top, so it wins.
    var found: ?Hit = null;
    var spans = Spans.init(depths[depth], view);
    while (spans.next()) |span| {
        if (span.x0 > x) break;
        if (span.contains(x)) found = .{ .depth = depth, .span = span };
    }
    return found;
}

/// A zone's time not spent in the zones nested directly in it.
pub fn selfNs(depths: []const []const Record, depth: usize, zone: Record) u64 {
    if (depth + 1 >= depths.len) return zone.duration_ns;
    const children = depths[depth + 1];
    var nested: u64 = 0;
    var index = firstBeginning(children, zone.begin_ns);
    while (index < children.len and children[index].begin_ns < zone.endNs()) : (index += 1) nested += children[index].duration_ns;
    return zone.duration_ns -| nested;
}

/// The zone at `depth` that contains the time `ns`, if one does.
pub fn enclosing(depths: []const []const Record, depth: usize, ns: u64) ?Record {
    if (depth >= depths.len) return null;
    const zones = depths[depth];
    const after = firstBeginning(zones, ns + 1);
    if (after == 0) return null;
    const candidate = zones[after - 1];
    return if (ns < candidate.endNs()) candidate else null;
}

/// Finds the zone at `depth` that begins at `begin_ns`.
pub fn findZone(depths: []const []const Record, depth: usize, begin_ns: u64) ?Record {
    if (depth >= depths.len) return null;
    const zones = depths[depth];
    const index = firstBeginning(zones, begin_ns);
    if (index < zones.len and zones[index].begin_ns == begin_ns) return zones[index];
    return null;
}

const palette = [_]roop.Color{
    roop.rgba(92, 148, 214, 255),
    roop.rgba(108, 178, 120, 255),
    roop.rgba(214, 156, 84, 255),
    roop.rgba(178, 112, 196, 255),
    roop.rgba(84, 176, 178, 255),
    roop.rgba(206, 108, 112, 255),
    roop.rgba(160, 168, 86, 255),
    roop.rgba(126, 132, 210, 255),
    roop.rgba(196, 132, 160, 255),
    roop.rgba(98, 160, 150, 255),
};
const merged_color = roop.rgba(110, 110, 118, 255);
const dimmed_color = roop.rgba(72, 72, 78, 255);
const label_color = roop.rgba(16, 16, 20, 255);
const hover_outline = roop.rgba(255, 255, 255, 220);
const selected_outline = roop.rgba(255, 214, 90, 255);

/// A zone's colour from its scope, its system, so a system keeps its colour from frame to
/// frame and its zones share it.
pub fn colorOf(scope: u32) roop.Color {
    var hash: u64 = scope;
    hash ^= hash >> 33;
    hash *%= 0xff51afd7ed558ccd;
    hash ^= hash >> 33;
    return palette[hash % palette.len];
}

fn fillRect(ctx: *roop.Context, x: f32, y: f32, w: f32, h: f32, color: roop.Color) void {
    ctx.beginPath();
    ctx.rect(x, y, w, h);
    ctx.fillColor(color);
    ctx.fill();
}

fn strokeRect(ctx: *roop.Context, x: f32, y: f32, w: f32, h: f32, color: roop.Color) void {
    ctx.beginPath();
    ctx.rect(x + 0.5, y + 0.5, @max(w - 1, 1), h - 1);
    ctx.strokeColor(color);
    ctx.strokeWidth(1);
    ctx.stroke();
}

pub fn milliseconds(nanoseconds: u64) f64 {
    const value: f64 = @floatFromInt(nanoseconds);
    return value / std.time.ns_per_ms;
}

/// One thread's zones over the timeline's width. Borrows the snapshot, whose names it
/// draws; it outlives the commit that draws it.
pub const LaneDrawable = struct {
    lane: profiler_api.Lane,
    view: View,
    names: *const profiler_api.Snapshot,
    font: roop.Font,
    /// Zones of this name stand out; others dim. None when zero.
    highlight: u64,
    /// Zones whose names do not hold this, ignoring case, dim too. Borrowed.
    filter: []const u8 = "",
    /// The pointer in the drawable's coordinates, when it is over the lane.
    pointer: ?math.Vec2f,
    selected: ?struct { depth: usize, begin_ns: u64 },
    /// The message levels shown; see `LevelGroup`.
    message_levels: u8 = all_levels,
    /// The selected message's time, marked by a line through every lane.
    selected_message_ns: ?u64 = null,
    /// The time cursor: the pointer's x over the timeline, a line through every lane.
    cursor_x: ?f32 = null,

    pub fn draw(self: *const LaneDrawable, size: math.Vec2f, ctx: *roop.Context) void {
        ctx.fontFace(self.font);
        const ascender = ctx.fontAscender(self.font);
        fillRect(ctx, 0, 0, size.x, lane_header_height, roop.rgba(40, 40, 46, 255));
        ctx.fillColor(roop.rgba(190, 190, 196, 255));
        _ = ctx.text(4, @round(ascender + 1), self.lane.name);
        var hovered: ?Hit = null;
        var hovered_message: ?usize = null;
        if (self.pointer) |pointer| {
            if (pointer.y < lane_header_height) {
                hovered_message = messageAt(self.lane.messages, self.view, self.message_levels, pointer.x);
            } else hovered = zoneAt(self.lane.depths, self.view, pointer.x, pointer.y - lane_header_height);
        }
        for (self.lane.depths, 0..) |zones, depth| {
            const y = lane_header_height + @as(f32, @floatFromInt(depth)) * row_height;
            if (y > size.y) break;
            var spans = Spans.init(zones, self.view);
            while (spans.next()) |span| {
                const x0 = @max(span.x0, 0);
                const x1 = @min(span.x1, size.x);
                if (x1 <= x0) continue;
                const zone = zones[span.first];
                const color = if (span.count > 1)
                    merged_color
                else if (self.dims(zone))
                    dimmed_color
                else
                    colorOf(zone.scope);
                fillRect(ctx, x0, y, x1 - x0, row_height - 1, color);
                if (self.selected) |selected| {
                    if (selected.depth == depth and span.count == 1 and zone.begin_ns == selected.begin_ns) strokeRect(ctx, x0, y, x1 - x0, row_height - 1, selected_outline);
                }
                self.drawLabel(ctx, zone, span, x0, x1, y, ascender);
            }
        }
        if (self.selected_message_ns) |ns| fillRect(ctx, @round(self.view.xOf(@floatFromInt(ns))), 0, 1, size.y, roop.rgba(255, 214, 90, 200));
        if (self.cursor_x) |x| fillRect(ctx, @round(x), lane_header_height, 1, size.y - lane_header_height, roop.rgba(255, 255, 255, 60));
        self.drawMessages(ctx, size);
        if (hovered) |hit| self.drawHover(ctx, size, hit);
        if (hovered_message) |index| self.drawMessageHover(ctx, size, index);
    }

    /// A downward marker in the header at each shown message, the more severe drawn last so
    /// they stay on top.
    fn drawMessages(self: *const LaneDrawable, ctx: *roop.Context, size: math.Vec2f) void {
        for ([_]LevelGroup{ .debug, .info, .warn, .err }) |group| {
            for (self.lane.messages) |message| {
                if (LevelGroup.of(message.level) != group or !levelShown(self.message_levels, message.level)) continue;
                const x = self.view.xOf(@floatFromInt(message.begin_ns));
                if (x < -message_hit_radius or x > size.x + message_hit_radius) continue;
                ctx.beginPath();
                ctx.moveTo(x - 4, 2);
                ctx.lineTo(x + 4, 2);
                ctx.lineTo(x, lane_header_height - 2);
                ctx.closePath();
                ctx.fillColor(messageColor(message.level));
                ctx.fill();
            }
        }
    }

    /// A line down the lane at the message under the pointer, and a card of it and the
    /// messages beside it.
    fn drawMessageHover(self: *const LaneDrawable, ctx: *roop.Context, size: math.Vec2f, index: usize) void {
        const pointer = self.pointer.?;
        const hovered = self.lane.messages[index];
        const x = @round(self.view.xOf(@floatFromInt(hovered.begin_ns)));
        fillRect(ctx, x, 0, 1, size.y, messageColor(hovered.level));
        // Every shown message whose marker overlaps the hovered one's, up to a few.
        const most = 6;
        var lines: [most + 1][160]u8 = undefined;
        var texts: [most + 1][]const u8 = undefined;
        var colors: [most + 1]roop.Color = undefined;
        var count: usize = 0;
        var overlapping: usize = 0;
        for (self.lane.messages) |message| {
            if (!levelShown(self.message_levels, message.level)) continue;
            if (@abs(self.view.xOf(@floatFromInt(message.begin_ns)) - x) > message_hit_radius * 2) continue;
            overlapping += 1;
            if (count == most) continue;
            const scope_name = self.names.scopeName(message.scope);
            // A long message is cut where its line ends.
            var line: std.Io.Writer = .fixed(&lines[count]);
            line.print("{s} {s}: {s}", .{ levelName(message.level), scope_name, message.text }) catch {};
            texts[count] = line.buffered();
            colors[count] = messageColor(message.level);
            count += 1;
        }
        if (overlapping > count) {
            texts[count] = std.fmt.bufPrint(&lines[count], "and {d} more", .{overlapping - count}) catch "";
            colors[count] = roop.rgba(180, 180, 186, 255);
            count += 1;
        }
        drawCard(ctx, self.font, size, pointer, texts[0..count], colors[0..count]);
    }
    fn dims(self: *const LaneDrawable, zone: Record) bool {
        if (self.highlight != 0 and zone.name != self.highlight) return true;
        if (self.filter.len == 0) return false;
        const name = self.names.zoneName(zone.name);
        return std.ascii.indexOfIgnoreCase(name, self.filter) == null;
    }

    /// A name inside its span when it fits; a merged span says how many it holds.
    fn drawLabel(self: *const LaneDrawable, ctx: *roop.Context, zone: Record, span: Span, x0: f32, x1: f32, y: f32, ascender: f32) void {
        if (x1 - x0 < 24) return;
        var buffer: [96]u8 = undefined;
        const label = if (span.count > 1)
            std.fmt.bufPrint(&buffer, "{d} zones", .{span.count}) catch return
        else
            self.names.zoneName(zone.name);
        if (ctx.measureText(self.font, label).w + 6 > x1 - x0) return;
        ctx.fillColor(label_color);
        _ = ctx.text(@round(x0 + 3), @round(y + ascender + 1), label);
    }

    /// Outlines the span under the pointer and shows what it is beside the pointer.
    fn drawHover(self: *const LaneDrawable, ctx: *roop.Context, size: math.Vec2f, hit: Hit) void {
        const pointer = self.pointer.?;
        const y = lane_header_height + @as(f32, @floatFromInt(hit.depth)) * row_height;
        strokeRect(ctx, @max(hit.span.x0, 0), y, @min(hit.span.x1, size.x) - @max(hit.span.x0, 0), row_height - 1, hover_outline);
        const zones = self.lane.depths[hit.depth];
        var lines: [3][96]u8 = undefined;
        var texts: [3][]const u8 = undefined;
        if (hit.span.count > 1) {
            var total: u64 = 0;
            for (zones[hit.span.first..][0..hit.span.count]) |zone| total += zone.duration_ns;
            texts[0] = std.fmt.bufPrint(&lines[0], "{d} zones too small to show", .{hit.span.count}) catch "";
            texts[1] = std.fmt.bufPrint(&lines[1], "{d:.3} ms in all", .{milliseconds(total)}) catch "";
            texts[2] = std.fmt.bufPrint(&lines[2], "depth {d}", .{hit.depth}) catch "";
        } else {
            const zone = zones[hit.span.first];
            texts[0] = self.names.zoneName(zone.name);
            texts[1] = std.fmt.bufPrint(&lines[1], "{d:.3} ms, self {d:.3} ms", .{ milliseconds(zone.duration_ns), milliseconds(selfNs(self.lane.depths, hit.depth, zone)) }) catch "";
            texts[2] = std.fmt.bufPrint(&lines[2], "depth {d}", .{hit.depth}) catch "";
        }
        const colors = [_]roop.Color{ roop.rgba(240, 240, 240, 255), roop.rgba(180, 180, 186, 255), roop.rgba(180, 180, 186, 255) };
        drawCard(ctx, self.font, size, pointer, &texts, &colors);
    }
};

/// A card of lines beside the pointer, kept within `size`.
fn drawCard(ctx: *roop.Context, font: roop.Font, size: math.Vec2f, pointer: math.Vec2f, texts: []const []const u8, colors: []const roop.Color) void {
    const line_height: f32 = 16;
    var width: f32 = 0;
    for (texts) |text| width = @max(width, ctx.measureText(font, text).w);
    const card_w = @min(width + 12, size.x);
    const card_h = @as(f32, @floatFromInt(texts.len)) * line_height + 8;
    const card_x = std.math.clamp(pointer.x + 14, 0, @max(size.x - card_w, 0));
    const card_y = std.math.clamp(pointer.y + 14, 0, @max(size.y - card_h, 0));
    fillRect(ctx, card_x, card_y, card_w, card_h, roop.rgba(24, 24, 28, 240));
    strokeRect(ctx, card_x, card_y, card_w, card_h, roop.rgba(90, 90, 100, 255));
    ctx.fontFace(font);
    const ascender = ctx.fontAscender(font);
    for (texts, colors, 0..) |text, color, index| {
        ctx.fillColor(color);
        _ = ctx.text(@round(card_x + 6), @round(card_y + 4 + @as(f32, @floatFromInt(index)) * line_height + ascender), text);
    }
}

pub const ruler_height: f32 = style.metric.small_text_line + 1;

/// The time scale over the lanes: a tick at each round step of time, labelled from the
/// frame's start, the step chosen so labels sit about `label_spacing` pixels apart.
pub const RulerDrawable = struct {
    view: View,
    /// The frame's start, which the labels count from.
    frame_begin_ns: f64,
    font: roop.Font,
    /// The time cursor's x, labelled with its time over the ticks.
    cursor_x: ?f32 = null,

    const label_spacing: f32 = 90;

    pub fn draw(self: *const RulerDrawable, size: math.Vec2f, ctx: *roop.Context) void {
        fillRect(ctx, 0, 0, size.x, size.y, roop.rgba(34, 34, 38, 255));
        fillRect(ctx, 0, size.y - 1, size.x, 1, roop.rgba(62, 62, 66, 255));
        const span = self.view.end_ns - self.view.begin_ns;
        if (span <= 0 or size.x <= 0) return;
        const step = niceStep(span * label_spacing / size.x);
        ctx.fontFace(self.font);
        ctx.textAlign(.{ .left = true, .baseline = true });
        const ascender = ctx.fontAscender(self.font);
        var tick = @ceil((self.view.begin_ns - self.frame_begin_ns) / step) * step + self.frame_begin_ns;
        while (tick <= self.view.end_ns) : (tick += step) {
            const x = self.view.xOf(tick);
            fillRect(ctx, x, size.y - 6, 1, 5, roop.rgba(120, 120, 128, 255));
            // Halfway ticks, unlabelled.
            const half = self.view.xOf(tick + step * 0.5);
            fillRect(ctx, half, size.y - 3, 1, 2, roop.rgba(90, 90, 96, 255));
            var buffer: [32]u8 = undefined;
            const label = durationLabel(&buffer, tick - self.frame_begin_ns, step);
            ctx.fillColor(roop.rgba(150, 150, 158, 255));
            _ = ctx.text(@round(x + 3), @round(ascender), label);
        }
        const cursor_x = self.cursor_x orelse return;
        var buffer: [32]u8 = undefined;
        // A finer unit than the ticks', so the cursor reads between them.
        const label = durationLabel(&buffer, self.view.nsAt(cursor_x) - self.frame_begin_ns, step / 10);
        const label_w = ctx.measureText(self.font, label).w + 8;
        const label_x = std.math.clamp(cursor_x - label_w * 0.5, 0, @max(size.x - label_w, 0));
        fillRect(ctx, label_x, 0, label_w, size.y - 1, roop.rgba(70, 70, 80, 255));
        fillRect(ctx, @round(cursor_x), 0, 1, size.y, roop.rgba(255, 255, 255, 140));
        ctx.fillColor(roop.rgba(240, 240, 240, 255));
        _ = ctx.text(@round(label_x + 4), @round(ascender), label);
    }
};

/// The round step, 1, 2 or 5 times a power of ten nanoseconds, nearest above `ns`.
pub fn niceStep(ns: f64) f64 {
    const power = std.math.pow(f64, 10, @floor(std.math.log10(@max(ns, 1))));
    for ([_]f64{ 1, 2, 5, 10 }) |factor| {
        if (power * factor >= ns) return power * factor;
    }
    return power * 10;
}

/// `ns` in the unit that suits `step`: whole ms, or fractions of them, or µs.
fn durationLabel(buffer: []u8, ns: f64, step: f64) []const u8 {
    const ms = ns / std.time.ns_per_ms;
    if (step >= std.time.ns_per_ms) return std.fmt.bufPrint(buffer, "{d:.0} ms", .{ms}) catch "";
    if (step >= 100 * std.time.ns_per_us) return std.fmt.bufPrint(buffer, "{d:.1} ms", .{ms}) catch "";
    if (step >= 10 * std.time.ns_per_us) return std.fmt.bufPrint(buffer, "{d:.2} ms", .{ms}) catch "";
    return std.fmt.bufPrint(buffer, "{d:.0} us", .{ns / std.time.ns_per_us}) catch "";
}

/// One bar per recorded frame, as tall as the frame was long, with a line at the frame
/// budget and a playhead at the frame shown. Past the end, the game runs live beyond the
/// recording: the bars dim and the playhead stands past the last of them. Many frames share
/// a pixel when there are more frames than pixels.
pub const FrameStripDrawable = struct {
    frames: []const profiler_api.FrameSpan,
    /// The frame shown, as an index into `frames`.
    shown: ?usize,
    /// The game has gone on past the recorded frames.
    past_end: bool = false,
    /// One display refresh: a frame longer than this missed vsync.
    budget_ms: f64,
    scale_ms: f64,
    /// Labels the vsync bands when given.
    font: ?roop.Font = null,
    /// A value per frame to chart instead of the frames' lengths.
    chart: ?Chart = null,
    /// Each frame's most severe message, aligned with `frames`: 0 for none, else the level
    /// plus one. Frames with warnings or errors are marked along the top.
    message_levels: []const u8 = &.{},

    /// One number per recorded frame, aligned with `frames`, drawn against the largest.
    pub const Chart = struct {
        values: []const f64,
        /// What is charted, shown in the corner with the largest value.
        label: []const u8,
        color: roop.Color,
    };

    pub fn draw(self: *const FrameStripDrawable, size: math.Vec2f, ctx: *roop.Context) void {
        fillRect(ctx, 0, 0, size.x, size.y, roop.rgba(30, 30, 34, 255));
        if (self.frames.len == 0) return;
        const bar_width = size.x / @as(f32, @floatFromInt(self.frames.len));
        if (self.chart) |chart| return self.drawChart(chart, bar_width, size, ctx);
        // Behind the bars: a band per refresh a frame can take, up to two at 60 Hz.
        vsync.drawBands(ctx, size.x, size.y - 2, @floatCast(self.scale_ms), @floatCast(self.budget_ms), null);
        for (self.frames, 0..) |frame, index| {
            const frame_ms = milliseconds(frame.durationNs());
            const fraction: f32 = @floatCast(@min(frame_ms / self.scale_ms, 1));
            const height = @max(fraction * (size.y - 2), 1);
            const over_budget = frame_ms > self.budget_ms;
            const color = if (self.past_end)
                (if (over_budget) roop.rgba(120, 72, 72, 255) else roop.rgba(66, 96, 122, 255))
            else if (over_budget)
                roop.rgba(214, 96, 96, 255)
            else
                roop.rgba(96, 160, 214, 255);
            const x = @as(f32, @floatFromInt(index)) * bar_width;
            // A little see-through, so the bands behind still show which refresh it took.
            var see_through = color;
            see_through.a = 0.8;
            fillRect(ctx, x, size.y - height, @max(bar_width - 1, 1), height, see_through);
        }
        if (self.font) |font| vsync.drawBandEdges(ctx, size.x, size.y - 2, @floatCast(self.scale_ms), @floatCast(self.budget_ms), font);
        self.drawMessageMarks(bar_width, ctx);
        if (self.past_end) {
            fillRect(ctx, size.x - 3, 0, 3, size.y, roop.rgba(110, 200, 130, 255));
            return;
        }
        const index = self.shown orelse return;
        const playhead = (@as(f32, @floatFromInt(index)) + 0.5) * bar_width;
        fillRect(ctx, playhead - 1, 0, 2, size.y, roop.rgba(255, 220, 120, 255));
    }

    /// Bars of the chart's values in its colour, the label in the corner, and the playhead.
    fn drawChart(self: *const FrameStripDrawable, chart: Chart, bar_width: f32, size: math.Vec2f, ctx: *roop.Context) void {
        var largest: f64 = 0;
        for (chart.values) |value| largest = @max(largest, value);
        var dimmed = chart.color;
        dimmed.a = 0.45;
        for (chart.values[0..@min(chart.values.len, self.frames.len)], 0..) |value, index| {
            if (value <= 0) continue;
            const fraction: f32 = @floatCast(if (largest > 0) value / largest else 0);
            const height = @max(fraction * (size.y - 4), 1);
            const x = @as(f32, @floatFromInt(index)) * bar_width;
            fillRect(ctx, x, size.y - height, @max(bar_width - 1, 1), height, if (self.past_end) dimmed else chart.color);
        }
        if (self.font) |font| {
            ctx.fontFace(font);
            ctx.textAlign(.{ .left = true, .baseline = true });
            const ascender = ctx.fontAscender(font);
            const label_width = ctx.measureText(font, chart.label).w;
            ctx.beginPath();
            ctx.roundedRect(2, 2, label_width + 8, @round(ascender) + 6, 3);
            ctx.fillColor(roop.rgba(20, 20, 24, 220));
            ctx.fill();
            ctx.fillColor(roop.rgba(225, 225, 230, 255));
            _ = ctx.text(6, @round(ascender) + 4, chart.label);
        }
        self.drawMessageMarks(bar_width, ctx);
        if (self.past_end) {
            fillRect(ctx, size.x - 3, 0, 3, size.y, roop.rgba(110, 200, 130, 255));
            return;
        }
        const index = self.shown orelse return;
        const playhead = (@as(f32, @floatFromInt(index)) + 0.5) * bar_width;
        fillRect(ctx, playhead - 1, 0, 2, size.y, roop.rgba(255, 220, 120, 255));
    }

    /// A tick along the top over each frame that logged a warning or an error.
    fn drawMessageMarks(self: *const FrameStripDrawable, bar_width: f32, ctx: *roop.Context) void {
        const warn_mark = @intFromEnum(Level.warn) + 1;
        for (self.message_levels[0..@min(self.message_levels.len, self.frames.len)], 0..) |mark, index| {
            if (mark < warn_mark) continue;
            const level: Level = @enumFromInt(mark - 1);
            const x = @as(f32, @floatFromInt(index)) * bar_width;
            fillRect(ctx, x, 0, @max(bar_width - 1, 2), 4, messageColor(level));
        }
    }

    /// The frame under `x`, as an index into `frames`.
    pub fn frameAt(frames: []const profiler_api.FrameSpan, width: f32, x: f32) ?usize {
        if (frames.len == 0 or x < 0 or x >= width) return null;
        const bar_width = width / @as(f32, @floatFromInt(frames.len));
        const index: usize = @intFromFloat(@floor(x / bar_width));
        return @min(index, frames.len - 1);
    }
};

// ---- tests -------------------------------------------------------------------------

fn syntheticZones(allocator: std.mem.Allocator, count: usize, frame_ns: u64) ![]Record {
    const zones = try allocator.alloc(Record, count);
    const step = frame_ns / count;
    for (zones, 0..) |*zone, index| zone.* = .{
        .name = index % 7 + 1,
        .begin_ns = index * step,
        // Varied lengths, from a sliver to most of the step.
        .duration_ns = @intCast(@max(step * (index % 5 + 1) / 6, 1)),
        .depth = 0,
    };
    return zones;
}

test "a hundred thousand zones draw in spans bounded by the width, at every zoom" {
    const zones = try syntheticZones(std.testing.allocator, 100_000, 16_000_000);
    defer std.testing.allocator.free(zones);
    var span_ns: f64 = 16_000_000;
    while (span_ns >= 1_000) : (span_ns /= 4) {
        const view: View = .{ .begin_ns = 4_000_000, .end_ns = 4_000_000 + span_ns, .width = 1200 };
        var spans = Spans.init(zones, view);
        var count: usize = 0;
        var covered: usize = 0;
        while (spans.next()) |span| {
            count += 1;
            covered += span.count;
            try std.testing.expect(span.x1 > span.x0);
        }
        // A merged span or a zone at least a pixel wide: never more than about two a pixel.
        try std.testing.expect(count <= 2 * 1200 + 2);
        try std.testing.expect(covered > 0);
    }
}

test "zoneAt finds exactly what is drawn, merged spans included" {
    const zones = try syntheticZones(std.testing.allocator, 20_000, 16_000_000);
    defer std.testing.allocator.free(zones);
    const depths = [_][]const Record{zones};
    for ([_]f64{ 16_000_000, 400_000, 20_000 }) |span_ns| {
        const view: View = .{ .begin_ns = 2_000_000, .end_ns = 2_000_000 + span_ns, .width = 800 };
        var drawn: [800]?Span = @splat(null);
        var spans = Spans.init(zones, view);
        while (spans.next()) |span| {
            var x: f32 = @max(@ceil(span.x0), 0);
            while (x < @min(span.x1, 800)) : (x += 1) drawn[@intFromFloat(x)] = span;
        }
        for (drawn, 0..) |expected, pixel| {
            const x: f32 = @floatFromInt(pixel);
            const hit = zoneAt(&depths, view, x, row_height * 0.5);
            if (expected) |span| {
                try std.testing.expect(hit != null);
                try std.testing.expectEqual(span.first, hit.?.span.first);
                try std.testing.expectEqual(span.count, hit.?.span.count);
            } else try std.testing.expect(hit == null);
        }
    }
}

test "self time leaves out nested zones, and a zone finds the one it is in" {
    const outer = [_]Record{.{ .name = 1, .begin_ns = 100, .duration_ns = 100, .depth = 0 }};
    const inner = [_]Record{
        .{ .name = 2, .begin_ns = 110, .duration_ns = 20, .depth = 1 },
        .{ .name = 2, .begin_ns = 150, .duration_ns = 30, .depth = 1 },
        .{ .name = 2, .begin_ns = 300, .duration_ns = 30, .depth = 1 },
    };
    const depths = [_][]const Record{ &outer, &inner };
    try std.testing.expectEqual(@as(u64, 50), selfNs(&depths, 0, outer[0]));
    try std.testing.expectEqual(@as(u64, 100), enclosing(&depths, 0, 155).?.begin_ns);
    try std.testing.expect(enclosing(&depths, 0, 305) == null);
}

test "the message under the pointer is the nearest shown marker, the more severe on a tie" {
    const messages = [_]Message{
        .{ .begin_ns = 1000, .scope = 1, .level = .info, .text = "a" },
        .{ .begin_ns = 1000, .scope = 1, .level = .err, .text = "b" },
        .{ .begin_ns = 1500, .scope = 1, .level = .debug, .text = "c" },
    };
    const view: View = .{ .begin_ns = 0, .end_ns = 2000, .width = 200 };
    try std.testing.expectEqual(@as(?usize, 1), messageAt(&messages, view, all_levels, 101));
    try std.testing.expectEqual(@as(?usize, 0), messageAt(&messages, view, LevelGroup.info.bit(), 101));
    try std.testing.expectEqual(@as(?usize, 2), messageAt(&messages, view, all_levels, 152));
    try std.testing.expect(messageAt(&messages, view, all_levels, 130) == null);
    try std.testing.expect(messageAt(&messages, view, LevelGroup.err.bit(), 150) == null);
}

test "the ruler's step is a round number at least the span asked for" {
    try std.testing.expectEqual(@as(f64, 2_000_000), niceStep(1_300_000));
    try std.testing.expectEqual(@as(f64, 500), niceStep(450));
    try std.testing.expectEqual(@as(f64, 1_000), niceStep(1_000));
}

test "zooming keeps the time under the pointer in place" {
    const view: View = .{ .begin_ns = 1000, .end_ns = 2000, .width = 100 };
    const zoomed = view.zoomed(25, 0.5);
    try std.testing.expectApproxEqAbs(view.nsAt(25), zoomed.nsAt(25), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 500), zoomed.end_ns - zoomed.begin_ns, 1e-6);
    const panned = view.panned(10);
    try std.testing.expectApproxEqAbs(@as(f64, 900), panned.begin_ns, 1e-6);
}
