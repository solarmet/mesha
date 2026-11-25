//! Pointer controls share action tags and user data with existing keyboard actions.
const std = @import("std");
const mesha = @import("mesha");
const ui = mesha.ui;

const resources = mesha.resources;
const style = @import("style.zig");
const roop = mesha.roop;
const math = mesha.math;
pub const icons = @import("icons.zig");
pub const Badge = enum { none, lock };
/// `tab` picks one of several views: no fill, a dim label, and an accent underline when
/// selected, so it never reads as a button that does something.
pub const Variant = enum { text_only, icon_text, compact, icon_only, tab };

pub const Options = struct {
    label: []const u8 = "",
    tooltip: ?[]const u8 = null,
    icon: ?icons.Icon = null,
    badge: Badge = .none,
    variant: Variant = .icon_text,
    size: ui.Size = .{ .w = .fill, .h = .{ .fixed = 28 } },
    /// The side of an `icon_only` button, which is square and ignores `size`. It must fit the
    /// row it sits in: a child taller than its row is placed at the row's top, not centred.
    icon_only_side: f32 = 40,
    enabled: bool = true,
    selected: bool = false,
    /// Set false when the icon resource is unavailable; labels always remain.
    icons_available: bool = true,
};

/// Where a glyph's pen goes for its ink box to sit in the middle of `size`. An icon is placed
/// by the ink it draws, never by its font's line box, whose ascent and descent are uneven.
pub fn inkCenteredOrigin(size: math.Vec2f, glyph: resources.font.Glyph) math.Vec2f {
    const width: f32 = @floatFromInt(glyph.x1 - glyph.x0);
    const height: f32 = @floatFromInt(glyph.y1 - glyph.y0);
    return .{ .x = (size.x - width) * 0.5 - glyph.xoff, .y = (size.y - height) * 0.5 - glyph.yoff };
}

/// Draws the icon `text` from the atlas `font_name` with its ink centred in `size`.
fn drawInkCentered(font_name: mesha.Atom, text: []const u8, color: ui.Color, size: math.Vec2f, ctx: *roop.Context) void {
    const provider = ctx.renderer.font_provider orelse return;
    const font = provider.get(font_name) orelse return;
    const codepoint = std.unicode.utf8Decode(text) catch return;
    const glyph = font.glyph(codepoint) orelse return;
    const position = inkCenteredOrigin(size, glyph.*);
    ctx.fontFace(font_name);
    ctx.textAlign(.{ .left = true, .baseline = true });
    ctx.fillColor(color);
    _ = ctx.text(position.x, position.y, text);
}

const RailIcon = struct {
    text: []const u8,
    color: ui.Color,
    badge: Badge = .none,

    pub fn draw(self: *const RailIcon, size: math.Vec2f, ctx: *roop.Context) void {
        drawInkCentered(resources.kRailIconFontName, self.text, self.color, size, ctx);
        if (self.badge == .lock and ctx.pathBudget().paths >= 3) {
            const x = size.x - 13;
            const y = size.y - 13;
            ctx.beginPath();
            ctx.roundedRect(x, y, 12, 12, 2);
            ctx.fillColor(style.col.accent_deep);
            ctx.fill();
            ctx.beginPath();
            ctx.roundedRect(x + 2.5, y + 5, 7, 5, 1);
            ctx.fillColor(self.color);
            ctx.fill();
            ctx.beginPath();
            ctx.moveTo(x + 4, y + 5);
            ctx.lineTo(x + 4, y + 3.5);
            ctx.bezierTo(x + 4, y + 1, x + 8, y + 1, x + 8, y + 3.5);
            ctx.lineTo(x + 8, y + 5);
            ctx.strokeColor(self.color);
            ctx.strokeWidth(1.3);
            ctx.stroke();
        }
    }
};

/// A rail glyph at row size, from its own atlas: scaling the rail atlas down would blur it.
pub const SmallIcon = struct {
    text: []const u8,
    color: ui.Color,

    pub fn draw(self: *const SmallIcon, size: math.Vec2f, ctx: *roop.Context) void {
        drawInkCentered(resources.kRowIconFontName, self.text, self.color, size, ctx);
    }
};

/// The width an icon takes beside a label, in a button or a tab.
const label_icon_width: f32 = 18;

fn fillColor(options: Options) ui.Color {
    if (!options.enabled) return style.col.button_disabled;
    return if (options.selected) style.col.accent_deep else style.col.button;
}

fn hoverColor(options: Options) ?ui.Color {
    if (!options.enabled) return null;
    return if (options.selected) style.col.accent_deep else style.col.button_hover;
}

/// `id` must be stable and unique among repeated controls; `click` names the inbox a press goes to.
/// Compact reduces spacing, not the label or the default hit-target height. Content is centered:
/// that, with the lighter flat fill, is what separates a button from a left-aligned text field.
/// Side by side, buttons match only under a parent with `equal_fill`; see `beginRow`.
pub fn render(tree: *ui.Tree, id: anytype, click: ui.Target, options: Options) void {
    if (options.variant == .tab) return renderTab(tree, id, click, options);
    const icon_only = options.variant == .icon_only;
    if (tree.beginRect(id, .{
        .axis = if (icon_only) .vertical else .horizontal,
        .cross_align = .center,
        .main_align = if (icon_only) .start else .center,
        .size = if (icon_only) .{ .w = .{ .fixed = options.icon_only_side }, .h = .{ .fixed = options.icon_only_side } } else options.size,
        .padding = if (icon_only) 0 else 4,
        .gap = if (icon_only) 0 else if (options.variant == .compact) 4 else 6,
        .bg = fillColor(options),
        .bg_hover = hoverColor(options),
        .corner_radius = style.metric.button_radius,
        .clip_content = true,
    })) {
        defer tree.endRect();
        if (options.enabled) {
            tree.onClick(click, .left);
            tree.trackHover(options.tooltip orelse "");
        }
        const text_color = if (options.enabled) style.col.text else style.col.text_disabled;
        if (icon_only) {
            if (options.icons_available) {
                if (options.icon) |icon| {
                    const drawable = tree.frame_allocator.allocator.create(RailIcon) catch unreachable;
                    drawable.* = .{ .text = icons.glyph(icon), .color = text_color, .badge = options.badge };
                    const icon_id = ui.partId(tree, id, "icon");
                    tree.custom(icon_id, drawable, .{ .size = .{ .w = .fill, .h = .fill } });
                }
            }
            return;
        }
        if (options.variant != .text_only and options.icons_available) {
            if (options.icon) |icon| {
                const icon_id = ui.partId(tree, id, "icon");
                const drawable = tree.frame_allocator.allocator.create(SmallIcon) catch unreachable;
                drawable.* = .{ .text = icons.glyph(icon), .color = text_color };
                tree.custom(icon_id, drawable, .{ .size = .{ .w = .{ .fixed = label_icon_width }, .h = .fill } });
            }
        }
        // An empty label would still take the gap beside it, and push the icon off centre.
        if (options.label.len == 0) return;
        const label_id = ui.partId(tree, id, "label");
        tree.text(label_id, options.label, .{ .font = style.ui_font, .color = text_color });
    }
}

/// Height of the underline under the selected tab.
const tab_underline: f32 = 2;

/// A tab: its label over an underline, accent when selected. Unselected tabs only lighten
/// under the pointer; they never take a button's fill.
fn renderTab(tree: *ui.Tree, id: anytype, click: ui.Target, options: Options) void {
    if (!tree.beginRect(id, .{
        .axis = .vertical,
        .cross_align = .center,
        .size = options.size,
        .gap = 0,
        .bg_hover = if (options.enabled and !options.selected) style.col.tab_hover else null,
        .corner_radius = style.metric.button_radius,
        .clip_content = true,
    })) return;
    defer tree.endRect();
    if (options.enabled) {
        tree.onClick(click, .left);
        tree.trackHover(options.tooltip orelse "");
    }
    const text_color = if (!options.enabled)
        style.col.text_disabled
    else if (options.selected)
        style.col.text
    else
        style.col.text_dim;
    const label_row_id = ui.partId(tree, id, "tab_row");
    if (tree.beginRect(label_row_id, .{ .axis = .horizontal, .cross_align = .center, .main_align = .center, .size = .{ .w = .fill, .h = .fill }, .padding = 4, .gap = 6, .clip_content = true })) {
        defer tree.endRect();
        if (options.icon) |icon| {
            if (options.icons_available) {
                const drawable = tree.frame_allocator.allocator.create(SmallIcon) catch unreachable;
                drawable.* = .{ .text = icons.glyph(icon), .color = text_color };
                tree.custom(ui.partId(tree, id, "icon"), drawable, .{ .size = .{ .w = .{ .fixed = label_icon_width }, .h = .fill } });
            }
        }
        tree.text(ui.partId(tree, id, "label"), options.label, .{ .font = style.ui_font, .color = text_color });
    }
    tree.rect(ui.partId(tree, id, "underline"), .{
        .size = .{ .w = .fill, .h = .{ .fixed = tab_underline } },
        .bg = if (options.selected) style.col.accent_bright else null,
        .corner_radius = 1,
    });
}

/// How a strip's tabs take its width: each its own, or an equal share.
pub const TabWidth = enum { own, equal };

/// A strip of tabs: a row of `height` over a hairline that the selected tab's underline sits
/// on. `equal` shares the width evenly. Pair a true result with `endTabStrip`.
pub fn beginTabStrip(tree: *ui.Tree, id: anytype, height: f32, width: TabWidth) bool {
    if (!tree.beginRect(id, .{ .axis = .vertical, .size = .{ .w = .fill, .h = .{ .fixed = height } }, .gap = 0 })) return false;
    if (!tree.beginRect(ui.partId(tree, id, "strip_row"), .{ .axis = .horizontal, .equal_fill = width == .equal, .size = .{ .w = .fill, .h = .fill }, .gap = 2 })) {
        tree.endRect();
        return false;
    }
    return true;
}

pub fn endTabStrip(tree: *ui.Tree, id: anytype) void {
    tree.endRect();
    tree.rect(ui.partId(tree, id, "strip_line"), .{ .size = .{ .w = .fill, .h = .{ .fixed = 1 } }, .bg = style.col.divider });
    tree.endRect();
}

/// A line of buttons that share it equally, whatever their labels. Pair with `tree.endRect()`.
pub fn beginRow(tree: *ui.Tree, id: anytype) bool {
    return tree.beginRect(id, .{
        .axis = .horizontal,
        .equal_fill = true,
        .size = .{ .w = .fill, .h = .{ .fixed = style.metric.button_height } },
        .gap = 4,
    });
}
