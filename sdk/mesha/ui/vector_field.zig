//! A vector's value as its components side by side, each a field of its own: a dim axis
//! letter, then that component's number. Every panel that shows a vector draws it with this,
//! so one reads and behaves the same wherever it is. The widget draws and routes only: what a
//! press, a drag or typing does to a component is its caller's, and it keeps nothing between
//! calls.
//!
//!     if (vector_field.begin(tree, "inspector.position")) {
//!         defer tree.endRect();
//!         for (components, 0..) |number, index| {
//!             const text = try vector_field.formatNumber(allocator, number, vector_field.shown_decimals);
//!             vector_field.component(tree, .{ "inspector.position.component", index }, .{ .index = index, .text = text }, style);
//!         }
//!     }
//!
//! The colours, font and corner radius are a `Style`, the caller's from its theme or
//! `default_style`.
const std = @import("std");
const Atom = atom.Atom;
const roop = @import("../systems/roop.zig");
const ui = @import("ui.zig");
const atom = @import("../core/atom.zig");

/// The letters of a vector's components, in order.
pub const axis_letters = [_][]const u8{ "X", "Y", "Z", "W" };
/// The most components one row shows.
pub const max_components = axis_letters.len;

/// Decimals a shown number has at most. A field shows a rounded value; typing starts from the
/// exact one.
pub const shown_decimals: u8 = 2;

const component_gap: f32 = 4;
const axis_letter_width: f32 = 10;
/// Space inside a component's frame at its ends, and between its parts, in pixels. Above and
/// below there is none: the text is centred in the height the caller gives.
const frame_padding: f32 = 6;

/// How a vector's components are painted. The caller's, usually from its theme;
/// `default_style` for a plugin without one.
pub const Style = struct {
    /// The name of the font of the numbers and the axis letters.
    font: roop.Font,
    /// The colour of a number, unless its `Component` gives one.
    text: ui.Color,
    /// The colour of the axis letters.
    axis_letter: ui.Color,
    /// The fill of a component's frame.
    background: ui.Color,
    /// The fill of a component that takes a press, under the pointer.
    background_hover: ui.Color,
    /// The fill of a component being typed into.
    background_active: ui.Color,
    /// The frame's one-pixel border.
    border: ui.Color,
    /// The border, and the ring outside it, of a component being typed into.
    border_active: ui.Color,
    /// The radius of a frame's corners, in pixels.
    corner_radius: f32,
};

/// A style that reads on a dark background, in roop's default font.
pub const default_style = Style{
    .font = roop.default_font,
    .text = ui.rgb(240, 240, 240),
    .axis_letter = ui.rgb(125, 125, 125),
    .background = ui.rgb(26, 26, 26),
    .background_hover = ui.rgb(40, 40, 40),
    .background_active = ui.rgb(12, 34, 56),
    .border = ui.rgb(82, 82, 82),
    .border_active = ui.rgb(120, 195, 255),
    .corner_radius = 2,
};

/// A number as a field shows it: rounded to `decimals`, without trailing zeros, and never a
/// negative zero. The text is `allocator`'s.
pub fn formatNumber(allocator: std.mem.Allocator, value: f32, decimals: u8) ![]const u8 {
    const fixed = try std.fmt.allocPrint(allocator, "{d:.[1]}", .{ value, decimals });
    var text: []const u8 = fixed;
    if (std.mem.indexOfScalar(u8, text, '.') != null) {
        text = std.mem.trimEnd(u8, text, "0");
        text = std.mem.trimEnd(u8, text, ".");
    }
    if (std.mem.eql(u8, text, "-0")) return "0";
    return text;
}

/// Begins the row of components, which share its width equally and fill their parent. Pair a
/// true result with `tree.endRect()`.
pub fn begin(tree: *ui.Tree, id: anytype) bool {
    return tree.beginRect(id, .{
        .axis = .horizontal,
        .equal_fill = true,
        .size = .{ .w = .fill, .h = .fill },
        .gap = component_gap,
    });
}

/// What a drag on a component does, which its cursor says.
pub const Drag = enum { none, scrubs };

/// One component as `component` draws it. The texts are borrowed until the tree's last commit
/// returns.
pub const Component = struct {
    /// Which component this is, naming its axis letter.
    index: usize,
    /// The number as shown, usually `formatNumber`'s.
    text: []const u8,
    /// Where a press on the component goes; none for a value that is only shown.
    click: ?ui.Target = null,
    /// What the pointer over a component that takes a press shows.
    tooltip: []const u8 = "",
    /// What a drag on the component does.
    drag: Drag = .none,
    /// The number's colour, dimmer for a value that stands for nothing, as with no selection;
    /// null for the style's `text`.
    text_color: ?ui.Color = null,
};

/// The frame of one component, `size` in its parent: idle, or lit while it is typed into.
const FrameState = enum { idle, active };

fn frameOf(frame_state: FrameState, size: ui.Size, style: Style) ui.RectParams {
    const active = frame_state == .active;
    return .{
        .axis = .horizontal,
        .cross_align = .center,
        .size = size,
        .padding = frame_padding,
        .padding_y = 0,
        .gap = frame_padding,
        .bg = if (active) style.background_active else style.background,
        .border = if (active) style.border_active else style.border,
        // A ring outside the line: a component being typed into must stand out at a glance.
        .border_size = if (active) 1 else 0,
        .corner_radius = style.corner_radius,
        .clip_content = true,
    };
}

/// One component showing its value. `id` must be unique to the component; its parts' ids are
/// made from it (`ui.partId`). The tree must have room for 3 more elements.
pub fn component(tree: *ui.Tree, id: anytype, options: Component, style: Style) void {
    var frame = frameOf(.idle, .{ .w = .fill, .h = .fill }, style);
    if (options.click != null) frame.bg_hover = style.background_hover;
    if (options.drag == .scrubs) frame.cursor = .resize_ew;
    if (!tree.beginRect(id, frame)) return;
    defer tree.endRect();
    if (options.click) |click| {
        tree.onClick(click, .left);
        tree.trackHover(options.tooltip);
    }
    axisLetter(tree, id, options.index, style);
    const value_id = ui.partId(tree, id, "vector_value");
    const text_color = options.text_color orelse style.text;
    tree.text(value_id, options.text, .{ .font = style.font, .color = text_color, .size_hint = .{ .w = .fill } });
}

/// Begins a component that is being typed into: its frame lit and its axis letter drawn. The
/// caller draws the text being edited, then `tree.endRect()`.
pub fn beginEditing(tree: *ui.Tree, id: anytype, index: usize, style: Style) bool {
    const frame = frameOf(.active, .{ .w = .fill, .h = .fill }, style);
    if (!tree.beginRect(id, frame)) return false;
    axisLetter(tree, id, index, style);
    return true;
}

fn axisLetter(tree: *ui.Tree, id: anytype, index: usize, style: Style) void {
    std.debug.assert(index < max_components);
    const letter_id = ui.partId(tree, id, "vector_axis");
    tree.text(letter_id, axis_letters[index], .{
        .font = style.font,
        .color = style.axis_letter,
        .size_hint = .{ .w = .{ .fixed = axis_letter_width } },
    });
}

test "a shown number drops trailing zeros and negative zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("1.5", try formatNumber(allocator, 1.5, 2));
    try std.testing.expectEqualStrings("12", try formatNumber(allocator, 12, 2));
    try std.testing.expectEqualStrings("-2.25", try formatNumber(allocator, -2.25, 2));
    try std.testing.expectEqualStrings("0.33", try formatNumber(allocator, 1.0 / 3.0, 2));
    try std.testing.expectEqualStrings("0", try formatNumber(allocator, -0.001, 2));
    try std.testing.expectEqualStrings("100", try formatNumber(allocator, 100, 0));
}
