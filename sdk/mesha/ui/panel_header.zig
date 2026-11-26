//! The usual header of a panel: its title, what the panel adds, and buttons to maximize and
//! close it, with a line along its foot while the panel has the focus.
//!
//! A panel's whole frame is its plugin's to draw (`plugin_render_panel`), in a context that
//! begins at the frame's top left; the host knows nothing of headers. A panel that wants this
//! one builds it in a `Tree` of its own, `height` tall along the top of its frame:
//!
//!     if (panel_header.begin(&tree, options)) {
//!         tree.text(...);                       // what the panel adds, left to right
//!         panel_header.end(&tree, options);
//!     }
//!     tree.commit(.{ .root_size = .{ .x = frame.w, .y = panel_header.height }, .depth = panels.kChromeHitDepth, ... }, ctx, hits, inboxOf(system));
//!     panel_header.drawFootLine(ctx, frame.w, focus);
//!
//! and draws its content in what is left, `contentRect(frame)`, which its kernels ask for too
//! when they need the content's size before it is drawn. A panel that wants another header,
//! or none, draws whatever it likes in its frame instead.
//!
//! The header's presses go to the host's panel chrome, which owns what they do to the
//! arrangement: a press off the buttons may become a drag that docks the panel, maximize
//! fills the window with it or restores the arrangement, and close gives it the focus and
//! invokes the `global.window_close` action, so the editor decides what closing means for the
//! panel with the focus. A caller sends close to a system of its own, or has no close button
//! (`Options.close`).
const std = @import("std");
const Atom = atom.Atom;
const math = @import("../core/math.zig");
const panels = @import("../systems/panels.zig");
const font_mod = @import("../systems/font.zig");
const roop = @import("../systems/roop.zig");
const ui = @import("ui.zig");
const atom = @import("../core/atom.zig");

/// The host's panel chrome's inbox, where the header's presses go.
pub const chrome_inbox = Atom.from("inbox.panel_chrome");
/// The tag of a press on the header off its buttons, carrying the panel's id: the start of a
/// drag that docks it.
pub const header_press_tag = Atom.from("panel_header_press");
/// The tag of a press on the maximize button, carrying the panel's id.
pub const maximize_tag = Atom.from("panel_maximize");
/// The tag of a press on the close button, carrying the panel's id.
pub const close_tag = Atom.from("panel_close");

/// How tall the header is, in pixels.
pub const height: f32 = 32;

/// What a panel has of `frame` under this header: the frame less `height` along its top, and
/// nothing of a frame no taller than the header.
pub fn contentRect(frame: panels.Rect) panels.Rect {
    const header = @min(height, frame.h);
    return .{ .x = frame.x, .y = frame.y + header, .w = frame.w, .h = frame.h - header };
}

/// Where a press on the close button goes.
pub const Close = union(enum) {
    /// To the host's panel chrome, which gives the panel the focus and invokes
    /// `global.window_close`.
    chrome,
    /// To the caller's own system, which decides what closing its panel means.
    target: ui.Target,
    /// Nowhere: the header has no close button.
    none,
};

/// The elements the header takes of a tree beside what the caller adds between `begin` and
/// `end`: size the tree for these and the caller's own.
pub const commands = 32;

/// The font of the header's title, which what a panel adds usually shares: the editor's
/// OpenSans, from its `assets/`, as `icon_font` is.
pub const font = ui.Font.init(.{ .plugin = "editor", .path = "fonts/OpenSans-Regular.ttf", .pixel_height = 24 });
/// The header's fill.
pub const fill_color = ui.rgb(44, 44, 44);
/// The title of the panel that has the focus.
pub const text_color = ui.rgb(235, 235, 235);
/// A title or icon that is not the focus of attention.
pub const dim_text_color = ui.rgb(170, 170, 170);
/// The line along the foot of a header without the focus.
pub const line_color = ui.rgb(82, 82, 82);
/// The line along the foot of the focused panel's header.
pub const focus_color = ui.rgb(13, 153, 255);
/// How tall the focused panel's foot line is, in pixels.
pub const focus_line_height: f32 = 2;

const icon_font = ui.Font.init(.{ .plugin = "editor", .path = "fonts/RobotoMonoNerdFontMono-Regular.ttf", .pixel_height = font_mod.kRowIconPixelHeight, .glyph_codepoints = &font_mod.rail_icon_codepoints });
const quiet_hover = ui.rgba(255, 255, 255, 22);
const maximize_icon = "\u{f05af}";
const restore_icon = "\u{f05b2}";
const button_side: f32 = 20;
const button_radius: f32 = 4;

/// What a header says and does.
pub const Options = struct {
    /// The panel's id: it salts the header's element ids, and its presses carry it.
    panel: Atom,
    /// What the header says first; empty says nothing, as for a panel whose own elements
    /// name it. Borrowed for the call.
    title: []const u8 = "",
    /// Whether the panel has the focus: its title is bright.
    focused: bool,
    /// Whether the panel fills the window: the maximize button then restores.
    maximized: bool = false,
    /// Where a press on the close button goes, and whether there is one.
    close: Close = .chrome,
};

/// Opens the header in `tree`: its row and title, then the row what the caller adds goes in,
/// which fills the space before the buttons. False when the tree has no room, and then
/// nothing is open and `end` must not be called.
pub fn begin(tree: *ui.Tree, options: Options) bool {
    const salt: u64 = @intFromEnum(options.panel);
    const row_open = tree.beginRect(.{ "panel.header", salt }, .{
        .axis = .horizontal,
        .cross_align = .center,
        .size = .{ .w = .fill, .h = .{ .fixed = height } },
        .padding = 3,
        .gap = 3,
        .bg = fill_color,
        .clip_content = true,
    });
    if (!row_open) return false;
    const press = tree.target(chrome_inbox, header_press_tag, options.panel);
    tree.onClick(press, .left);
    // The focus shows in the title's brightness and the line under the header, not a fill.
    tree.rect(.{ "panel.title.inset", salt }, .{ .size = .{ .w = .{ .fixed = 3 }, .h = .fill } });
    if (options.title.len != 0) {
        const color = if (options.focused) text_color else dim_text_color;
        tree.text(.{ "panel.title", salt }, options.title, .{ .font = font, .color = color });
    }
    const added_open = tree.beginRect(.{ "panel.decoration", salt }, .{
        .axis = .horizontal,
        .cross_align = .center,
        .size = .{ .w = .fill, .h = .fill },
        .gap = 6,
        .clip_content = true,
    });
    if (!added_open) {
        tree.endRect();
        return false;
    }
    return true;
}

/// Closes what `begin` opened, after the caller's elements: the maximize button follows
/// them, and the close button unless `options.close` is `none`.
pub fn end(tree: *ui.Tree, options: Options) void {
    const salt: u64 = @intFromEnum(options.panel);
    tree.endRect();
    const maximize = tree.target(chrome_inbox, maximize_tag, options.panel);
    const maximize_glyph = if (options.maximized) restore_icon else maximize_icon;
    iconButton(tree, .{ "panel.maximize", salt }, maximize_glyph, maximize);
    switch (options.close) {
        .chrome => closeButton(tree, .{ "panel.close", salt }, tree.target(chrome_inbox, close_tag, options.panel)),
        .target => |target| closeButton(tree, .{ "panel.close", salt }, target),
        .none => {},
    }
    tree.endRect();
}

/// The line along a header's foot, `width` wide, in a context that begins at the panel's top
/// left: the focus colour for the panel with the focus, a rule for any other.
pub fn drawFootLine(ctx: *roop.Context, width: f32, focus: enum { focused, unfocused }) void {
    const line_height: f32 = if (focus == .focused) focus_line_height else 1;
    ctx.beginPath();
    ctx.rect(0, height - line_height, width, line_height);
    ctx.fillColor(if (focus == .focused) focus_color else line_color);
    ctx.fill();
}

/// How thick the border around the panel with the focus is, in pixels.
pub const focus_border_width: f32 = 2;
/// How far the focus border's glow reaches past it: the panels' gap, which it fits in.
pub const focus_glow_radius: f32 = panels.kGap;
/// The colour of the focus border's glow.
pub const focus_glow_color = ui.rgba(13, 153, 255, 150);

/// Whether a focus border glows: it does around what has the keyboard, and not around the
/// panel the keyboard returns to while something outside the panels has lent it.
pub const FocusGlow = enum { glowing, plain };

/// The border around what has the focus, `focus_border_width` thick in `focus_color`, inside
/// `rect` (in `ctx`'s coordinates), with its glow reaching out past it when `glow` says so.
/// Nothing for a rect too small to hold it. The host's panel chrome draws it around the focused
/// panel, and the editor's minibuffer around itself while it has the keyboard.
pub fn drawFocusBorder(ctx: *roop.Context, rect: panels.Rect, glow: FocusGlow) void {
    if (rect.w <= focus_border_width or rect.h <= focus_border_width) return;
    // The stroke stays inside the rect, and the glow begins at its edge.
    const inset = focus_border_width * 0.5;
    ctx.beginPath();
    ctx.rect(rect.x + inset, rect.y + inset, rect.w - focus_border_width, rect.h - focus_border_width);
    ctx.strokeColor(focus_color);
    ctx.strokeWidth(focus_border_width);
    // A glow set before would otherwise carry over to a plain border.
    const glow_radius: f32 = if (glow == .glowing) focus_glow_radius else 0;
    ctx.strokeGlow(focus_glow_color, glow_radius);
    ctx.stroke();
}

/// A quiet icon button: no fill until the pointer is over it.
fn iconButton(tree: *ui.Tree, id: anytype, icon: []const u8, click: ui.Target) void {
    const element = tree.toElementId(id);
    const open = tree.beginRect(element, .{
        .axis = .horizontal,
        .size = .{ .w = .{ .fixed = button_side }, .h = .{ .fixed = button_side } },
        .bg_hover = quiet_hover,
        .corner_radius = button_radius,
        .clip_content = true,
    });
    if (!open) return;
    defer tree.endRect();
    tree.onClick(click, .left);
    tree.trackHover("");
    const glyph = tree.frame_allocator.allocator.create(IconGlyph) catch return;
    glyph.* = .{ .text = icon, .color = dim_text_color };
    tree.custom(.{ element.atom, element.extra +% 1 }, glyph, .{ .size = .{ .w = .fill, .h = .fill } });
}

/// A quiet button that closes its panel, drawn as a cross.
fn closeButton(tree: *ui.Tree, id: anytype, click: ui.Target) void {
    const element = tree.toElementId(id);
    const open = tree.beginRect(element, .{
        .axis = .horizontal,
        .size = .{ .w = .{ .fixed = button_side }, .h = .{ .fixed = button_side } },
        .bg_hover = quiet_hover,
        .corner_radius = button_radius,
    });
    if (!open) return;
    defer tree.endRect();
    tree.onClick(click, .left);
    tree.trackHover("");
    const cross = tree.frame_allocator.allocator.create(Cross) catch return;
    cross.* = .{ .color = dim_text_color };
    tree.custom(.{ element.atom, element.extra +% 1 }, cross, .{ .size = .{ .w = .fill, .h = .fill } });
}

/// An x centred in its rect.
const Cross = struct {
    color: ui.Color,

    /// Strokes the cross in `color` about the centre of a rect of `size`, in `ctx`'s space with
    /// the rect's top left corner at its origin, as `ui.Tree.custom` calls it when it draws.
    pub fn draw(self: *const Cross, size: math.Vec2f, ctx: *roop.Context) void {
        const center_x = size.x * 0.5;
        const center_y = size.y * 0.5;
        const reach: f32 = 3.5;
        ctx.beginPath();
        ctx.moveTo(center_x - reach, center_y - reach);
        ctx.lineTo(center_x + reach, center_y + reach);
        ctx.moveTo(center_x + reach, center_y - reach);
        ctx.lineTo(center_x - reach, center_y + reach);
        ctx.strokeColor(self.color);
        ctx.strokeWidth(1.4);
        ctx.lineCap(.round);
        ctx.stroke();
    }
};

/// An icon glyph with its ink centred in its rect, as the cross beside it is: text layout
/// would place it by the font's line box instead.
const IconGlyph = struct {
    text: []const u8,
    color: ui.Color,

    /// Fills `text`'s glyph in `color` with its ink centred in a rect of `size`, in `ctx`'s space
    /// with the rect's top left corner at its origin, as `ui.Tree.custom` calls it when it draws.
    /// Draws nothing while the icon font is not loaded, as the engine's font in its place has no
    /// icons, or does not have the glyph.
    pub fn draw(self: *const IconGlyph, size: math.Vec2f, ctx: *roop.Context) void {
        const found = ctx.fontView(icon_font) orelse return;
        const codepoint = std.unicode.utf8Decode(self.text) catch return;
        const glyph = found.glyph(codepoint) orelse return;
        const ink_width: f32 = @floatFromInt(glyph.x1 - glyph.x0);
        const ink_height: f32 = @floatFromInt(glyph.y1 - glyph.y0);
        const pen_x = (size.x - ink_width) * 0.5 - glyph.xoff;
        const pen_y = (size.y - ink_height) * 0.5 - glyph.yoff;
        ctx.fontFace(icon_font);
        ctx.textAlign(.{ .left = true, .baseline = true });
        ctx.fillColor(self.color);
        _ = ctx.text(pen_x, pen_y, self.text);
    }
};
