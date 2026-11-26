//! `mesha.ui`, the immediate-mode UI library a plugin draws its panels with.
//!
//! Each frame a caller records elements into a `Tree` and commits it. `Tree.commit` lays the
//! elements out, paints them through a `roop.Context`, and writes a hit region for every rect that
//! takes a press or the wheel. The library keeps nothing between frames and holds no widget state:
//! what a panel shows is read from tables each time it is drawn, and a press comes back later as a
//! message in a system's inbox, never as the result of the call that drew the button.
//!
//! The usual order of calls, in a plugin's `plugin_render_panel` (which reads tables and is not a
//! kernel):
//!
//! 1. `Tree.init` with the frame's scratch allocator, the atom registry and a capacity in elements.
//!
//! 2. Record. `Tree.beginRect` and `Tree.endRect` bracket a container, `Tree.rect` is a leaf,
//!    `Tree.text` a run of text, `Tree.cursor` a caret in the text before it, and `Tree.custom` a
//!    leaf that paints itself (a chart from `chart`, for one). `Tree.onClick`,
//!    `Tree.onScroll` and `Tree.trackHover` attach to the rect just recorded; `Tree.target` makes
//!    the `Target` they send to.
//!
//! 3. `Tree.commit` with a `Config` (the root's size and where it sits), the context, the hit
//!    regions table, or null for ui that takes no pointer, and the inbox told when a font the
//!    tree drew in before it loaded has loaded (`redraw_tag`).
//!
//! Layout: a rect is a row or a column (`RectParams.axis`) of its children, with `padding` around
//! them (`padding_y` in its place above and below, when given) and `gap` between them, and each
//! element's width and height is a `Dim`: fixed, hugging its content, or filling its parent.
//! Lengths are pixels and y grows downward. Elements recorded at the top level each lay out
//! against the whole root from its top-left corner, one over the other in the order recorded.
//!
//! Pointer: the hit regions table has the columns `initHitRegionSchema` gives it. The input system
//! (`mesha.input`) reads it through an `on_mouse` subscription: it sends a press or the wheel over
//! a region under the target's tag to the target's inbox with its user data, and keeps in
//! `input.hover` the `ElementId` of the followed region the pointer is over, which the caller
//! passes back as `Config.hovered` so the element paints its `bg_hover`.
//!
//! Ownership: a tree's element buffer, the user data and tooltips it copies and
//! `Tree.allocBuffer`'s bytes are the frame allocator's, and a tree has no deinit, so a tree lasts
//! one frame. Strings given to `Tree.text` and drawables given to `Tree.custom` are borrowed until
//! the tree's last commit returns.
//!
//! `TextEdit` is a fixed-capacity UTF-8 line editor for the text fields a panel draws with
//! `Tree.text` and `Tree.cursor`. The `validate*` functions are the checks the recording calls and
//! `commit` make, for a caller that would rather have an error than a contract violation.
const std = @import("std");
const color_mod = @import("../core/color.zig");
const input_mod = @import("../systems/input.zig");
/// The usual header of a panel, for a plugin that draws its panels' headers with it.
pub const panel_header = @import("panel_header.zig");
/// Line, bar and scatter charts of a table's numeric columns, drawn alone or as a leaf of a
/// `Tree` (`Tree.custom`).
pub const chart = @import("chart.zig");
/// A transient menu, keyed commands, switches and options shown while a key is awaited: its
/// model, what a typed key does to it, the arguments it yields, and how it is recorded into a
/// `Tree`.
pub const transient = @import("transient.zig");
/// Small marks drawn as paths (a chevron, a status dot, a magnifier, a cross, a menu's dots, a
/// scroll bar, a share bar), each a `Tree.custom` leaf.
pub const marks = @import("marks.zig");
/// A one-line filter over a text cell of the caller's table: what it hears, how typing and
/// keys change it, and how it is recorded into a `Tree`.
pub const filter_field = @import("filter_field.zig");
/// A vector's value as its components side by side, each a field with its axis letter: how
/// they are recorded into a `Tree`, and how a number is shown.
pub const vector_field = @import("vector_field.zig");
/// A grid of a table's rows and fields, or a form of one row's: the state its caller keeps, how
/// its messages change it and what they ask of the caller, and how it is recorded into a `Tree`.
pub const grid = @import("grid.zig");
/// An outline: lines in sections that nest and fold, a cursor that moves through what is shown,
/// and the list recorded into a `Tree` drawing only the lines in view.
pub const outline = @import("outline.zig");
/// A unified diff's hunks read from one file's part of it, the lines of its files and hunks
/// built for an outline, a hunk line's line in the new file, and the patch of one hunk.
pub const diff = @import("diff.zig");
const memory_mod = @import("../core/memory.zig");
const Table = @import("../core/table.zig");
const contract = @import("../core/contract.zig");
const math = @import("../core/math.zig");
const roop = @import("../systems/roop.zig");
const atom_mod = @import("../core/atom.zig");
const log = @import("../core/log.zig");
const os = @import("../systems/os.zig");

/// An id code refers to by name: here an element's name, a font, a message tag or an inbox.
/// `mesha.Atom`.
pub const Atom = atom_mod.Atom;
const Log = log.scope("ui");
const CursorKind = os.CursorKind;

/// A font text is drawn in, by what it is. `mesha.resources.Font`.
pub const Font = roop.Font;
/// The tag of the message `Tree.commit`'s `redraw_inbox` hears once a font the tree drew in
/// before it loaded has loaded: a `resources.ResourceMsg`, which needs no reading. The system
/// that reads the inbox redraws what the tree drew.
pub const redraw_tag = roop.redraw_tag;

/// An sRGB color with straight alpha, each channel 0 to 1: what every paint in this library
/// takes.
/// `mesha.color.Color`.
pub const Color = color_mod.Color;
/// A linear-light color, for math that needs it; this library's paints take `Color`.
/// `mesha.color.LinearColor`.
pub const LinearColor = color_mod.LinearColor;
/// An opaque `Color` from 8-bit sRGB channels. `mesha.color.rgb`.
pub const rgb = color_mod.rgb;
/// A `Color` from 8-bit sRGB channels and an 8-bit alpha. `mesha.color.rgba`.
pub const rgba = color_mod.rgba;

/// An element's identity among what is drawn: the atom that names it, and a number that tells apart
/// elements recorded under one name, as the rows of a list. A hit region carries it as 16 bytes in
/// its `id` column, `input.hover` holds the id of the region the pointer is over, and
/// `Config.hovered` is matched against it to paint `RectParams.bg_hover`. The library does not
/// check that ids are unique: elements that share one all show its hover. Recording calls make it
/// from their `id` argument with `Tree.toElementId`.
pub const ElementId = extern struct {
    /// The element's name.
    atom: Atom,
    /// Tells apart elements that share `atom`; 0 for the only element under its name.
    extra: u64 = 0,

    /// The id of the element named `atom`, with `extra` 0.
    pub fn init(atom: Atom) ElementId {
        return .{ .atom = atom };
    }
};

/// The id of the part `suffix` of the element `id` a widget draws: the atom named
/// `button.<the number of id's atom>.<suffix>`, with `id`'s extra. It is unique to the element
/// whatever form `id` takes, and the same every frame, so the hover the input system keeps for
/// a part is found again. The widgets of this library name their parts with it (`filter_field`,
/// `vector_field`, `grid`). Interns the name in the tree's registry; panics when the frame
/// allocator has no room for the name.
pub fn partId(tree: *Tree, id: anytype, comptime suffix: []const u8) ElementId {
    const base = tree.toElementId(id);
    const base_number = @intFromEnum(base.atom);
    const name = std.fmt.allocPrint(tree.frame_allocator.allocator, "button.{d}." ++ suffix, .{base_number}) catch @panic("ui: OOM naming a part");
    const part = tree.atoms.intern(name);
    return .{ .atom = part, .extra = base.extra };
}

comptime {
    std.debug.assert(@sizeOf(ElementId) == 16);
}

fn isStringType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => p.child == u8,
            .one => switch (@typeInfo(p.child)) {
                .array => |a| a.child == u8,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}

/// The direction a rect lays its children along: `horizontal` is a row, left to right; `vertical`
/// is a column, top to bottom.
pub const Axis = enum { horizontal, vertical };
/// Where children sit in the space left free: `start` is left or top, `center` the middle, `end`
/// right or bottom. Used across a rect's axis (`RectParams.cross_align`) and along it
/// (`RectParams.main_align`).
pub const CrossAlign = enum { start, center, end };

/// One dimension of an element's size, in pixels.
///
/// `fixed` is that many pixels whatever the content. `hug` is the content's size: for a rect, its
/// children's sizes and gaps along its axis, or its largest child across it, plus padding on both
/// sides; for text, its measured width and its lines' height. `fill` starts at the content's size
/// and takes what its parent has: along the parent's axis the fill children share the free space,
/// the smallest growing first until they level, and when the children overflow the fill children
/// shrink, the largest first; across the parent's axis a fill child is the parent's size inside its
/// padding. Fixed and hug children never shrink. A top-level `fill` is the root's size.
pub const Dim = union(enum) { fixed: f32, fill, hug };
/// An element's width `w` and height `h`, each a `Dim`; both hug by default.
pub const Size = struct { w: Dim = .hug, h: Dim = .hug };

/// Which way `RectParams.scroll_offset` moves a rect's children: `horizontal` along x, `vertical`
/// along y, `none` not at all.
pub const Scroll = enum { none, horizontal, vertical };

/// No inbox: a region's messages go to the inbox subscribed to the regions.
pub const no_inbox: Atom = @enumFromInt(0);

/// Where a region's press or wheel goes: the tag its message arrives under, the user data it
/// carries back, and the inbox of the system that takes it, named where the region is drawn.
/// Made by `Tree.target`, whose frame holds the user data until the regions are written.
pub const Target = struct {
    /// The tag the message arrives under in the inbox.
    tag: Atom,
    /// The bytes the message carries back; empty for none. Borrowed until the tree is committed,
    /// when they are copied into the hit region.
    user_data: []const u8 = &.{},
    /// The inbox of the system that takes the message, or `no_inbox` for the inbox subscribed to
    /// the regions table.
    inbox: Atom = no_inbox,
};

/// Which mouse button a click route answers. `all` sends every button down one route, and the
/// handler reads which it was; it cannot share a rect with a route for a single button.
pub const ClickButton = enum { left, right, middle, all };

/// How a rect is laid out and painted, and what the pointer does over it. Given to
/// `Tree.beginRect`, `Tree.rect` and `Tree.custom`; `Tree.cursor` reads only its fixed sizes, `bg`
/// and `corner_radius`. A custom leaf uses the layout, clip and pointer fields, and paints itself
/// in place of `bg` and `border`. Lengths are pixels.
pub const RectParams = struct {
    /// Set by the recording call from its `id` argument; a value given here is overwritten.
    id: ElementId = .{ .atom = @enumFromInt(0) },
    /// The direction the children are laid along.
    axis: Axis = .vertical,
    /// Places each child across the axis when it is smaller than the rect's size inside its
    /// padding.
    cross_align: CrossAlign = .start,
    /// Places children along the axis when they leave space free. Ignored while scrolling.
    main_align: CrossAlign = .start,
    /// Fill children split the free space evenly instead of levelling up from their content, so
    /// siblings match whatever they hold. Content wider than a share is left to `clip_content`.
    equal_fill: bool = false,
    /// The rect's width and height.
    size: Size = .{},
    /// Space between the rect's edges and its children: on all four sides, or on the left and
    /// right alone when `padding_y` is given.
    padding: f32 = 0,
    /// Space between the rect's top and bottom edges and its children, in place of `padding`
    /// there; null keeps `padding` on all four sides. A clipped rect a line of text tall gives 0,
    /// so its text keeps its descenders while it is still clipped at its ends.
    padding_y: ?f32 = null,
    /// Space between one child and the next along the axis.
    gap: f32 = 0,
    /// The fill; null paints none.
    bg: ?Color = null,
    /// The fill while this rect is the hovered element (`Config.hovered`); null keeps `bg`.
    bg_hover: ?Color = null,
    /// A one-pixel border just inside the rect's edges; null draws none. It follows rounded corners
    /// only on a rect that also has a fill: without one its four edges are straight.
    border: ?Color = null,
    /// Radius of the rect's corners; 0 is square. With `clip_content`, the children are clipped to
    /// corners rounded by this less the padding.
    corner_radius: f32 = 0,

    /// Width of a band in the `border` color painted outside the rect's edges, under the rect, with
    /// corners rounded to match; 0 or a null `border` paints none. It takes no room in layout.
    border_size: f32 = 0,

    /// Clips the paint and hit regions of everything inside the rect to the rect less its padding
    /// (`padding` at its ends, `padding_y` above and below when given).
    clip_content: bool = false,
    /// For `Tree.beginRect`: the rect is recorded with no children and `beginRect` returns false,
    /// so the caller skips them. The rect itself is still laid out and painted. `Tree.rect` ignores
    /// it.
    collapsed: bool = false,
    /// The direction `scroll_offset` moves the children in, whatever the rect's `axis`. Scrolling
    /// does not clip: set `clip_content` as well.
    scroll: Scroll = .none,
    /// Caller-owned pixel position. Moves descendants without moving the viewport or its clip.
    scroll_offset: f32 = 0,
    /// Where a left press on this rect goes; null for nowhere. Any click target gives the rect a
    /// hit region.
    on_click: ?Target = null,
    /// Where a right press on this rect goes. Set through `Tree.onClick`.
    on_right_click: ?Target = null,
    /// Where a middle press on this rect goes. Set through `Tree.onClick`.
    on_middle_click: ?Target = null,
    /// Whether one target takes every button, as `Tree.onClick` with `.all` sets it.
    click_all: bool = false,

    /// Whether the pointer over this rect's hit region is followed: input then says which
    /// element it is over, with `tooltip`, and `bg_hover` shows while it is.
    hover: bool = false,
    /// What the pointer over the rect says, shown where the host shows it; empty for nothing.
    /// Text for a person, so a string and never an atom. The tree's until it is committed,
    /// when it is copied into the hit region.
    tooltip: []const u8 = "",
    /// Takes the wheel over this rect and over any region inside it that has no `on_scroll` of its
    /// own.
    on_scroll: ?Target = null,
    /// Shown while the pointer is over this rect's hit region, which `on_click` or `on_scroll`
    /// creates.
    cursor: CursorKind = .arrow,

    /// Moves this rect's own paint and hit region by this many pixels without changing layout: its
    /// children and siblings stay where they were.
    offset: math.Vec2f = .{ .x = 0, .y = 0 },
};

/// How a run of text is laid out and painted. Text wider than its width wraps between words at
/// spaces; a word wider than the width is left whole.
pub const TextParams = struct {
    /// Set by the recording call from its `id` argument; a value given here is overwritten.
    id: ElementId = .{ .atom = @enumFromInt(0) },
    /// The font the text is measured and drawn in. One not loaded yet is drawn in the engine's
    /// font while it loads (`Tree.commit`).
    font: roop.Font = roop.default_font,

    /// The text's color; null is opaque white.
    color: ?Color = null,
    /// Draws a one-pixel line through the middle of each line's capitals, in the text's color and
    /// as wide as the line.
    strikethrough: bool = false,
    /// The text's width and height. A `hug` width is the whole string on one line. A `fill` width
    /// starts at the longest word's and takes the parent's free space, and the text wraps to the
    /// width it ends with, as it does to a `fixed` one. A `hug` or `fill` height is that of the
    /// wrapped lines.
    size_hint: Size = .{},

    /// A byte offset into the string to keep in view, for a one-line text field: the text is not
    /// wrapped, and is drawn shifted left by as much as keeps a caret at the offset within the
    /// text's width. It must be at most the string's length and on a codepoint boundary, and the
    /// string valid UTF-8. Null wraps as usual. The shifted text is clipped only by an ancestor's
    /// `clip_content`.
    scroll_cursor: ?usize = null,
};

/// A plugin's drawable in a tree the host commits: C's calling convention, as the plugin may be
/// built by another backend than the host's.
const CustomDrawable = struct {
    object: *const anyopaque,
    draw: *const fn (*const anyopaque, math.Vec2f, *roop.Context) callconv(.c) void,
};

/// One recorded entry of a tree: what `Tree`'s recording calls append and `Tree.commit` reads.
/// Callers do not build these by hand; a plugin hands a slice of them to the host for a panel
/// header's decoration, which the host takes with `Tree.include`.
pub const Element = union(enum) {
    /// A container begun by `Tree.beginRect`: the elements up to its `close_rect` are its children.
    open_rect: RectParams,
    /// Ends the nearest rect still open.
    close_rect,
    /// A leaf rect.
    rect: RectParams,
    /// A leaf laid out as a rect and painted by its drawable.
    custom: struct { params: RectParams, drawable: CustomDrawable },
    /// A run of text; `str` is borrowed.
    text: struct { str: []const u8, params: TextParams },

    /// A caret at byte offset `byte` of the text before it.
    cursor: struct { byte: usize, params: RectParams },
};

/// Why a text cursor's byte offset, or its place in the stream, is refused.
pub const CursorValidationError = error{
    /// The text is not valid UTF-8.
    InvalidUtf8,
    /// The offset is past the end of the text.
    CursorOutOfRange,
    /// The offset falls inside a multi-byte codepoint.
    CursorNotAtUtf8Boundary,
    /// The cursor is the first element, with nothing before it.
    MissingCursorPredecessor,
    /// The element before the cursor is neither text nor another cursor.
    InvalidCursorPredecessor,
};

/// `bytes` as a person reads it: itself when it is UTF-8, else a copy in `allocator` with each
/// byte that does not begin a whole, valid UTF-8 sequence shown as U+FFFD. The text a `Tree` draws
/// is read as UTF-8, and text that comes from outside (a path, a program's output) need not
/// be: this makes it so. A copy lives as long as `allocator` keeps it.
pub fn displayText(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return bytes;
    var displayed: std.Io.Writer.Allocating = .init(allocator);
    var index: usize = 0;
    while (index < bytes.len) {
        const length = validSequenceLength(bytes[index..]);
        if (length == 0) {
            try displayed.writer.writeAll("\u{FFFD}");
            index += 1;
            continue;
        }
        try displayed.writer.writeAll(bytes[index .. index + length]);
        index += length;
    }
    return displayed.written();
}

/// The length of the valid UTF-8 sequence `bytes` begins with; 0 when it begins with none.
fn validSequenceLength(bytes: []const u8) usize {
    const length = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return 0;
    if (length > bytes.len) return 0;
    _ = std.unicode.utf8Decode(bytes[0..length]) catch return 0;
    return length;
}

/// Checks that `byte` is a cursor position in `text`: at most its length, on a codepoint boundary,
/// the text valid UTF-8. It validates the whole text, so it costs the text's length.
pub fn validateCursorOffset(text: []const u8, byte: usize) CursorValidationError!void {
    if (byte > text.len) return error.CursorOutOfRange;
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    if (byte < text.len and text[byte] & 0xc0 == 0x80) return error.CursorNotAtUtf8Boundary;
}

/// Why a recorded element stream is refused, by `Tree.validateCommands` or `validateElementStream`.
pub const CommandValidationError = error{
    /// More elements than the buffer holds.
    CapacityExceeded,
    /// Rects nested deeper than the limit.
    ScopeTooDeep,
    /// A `close_rect` with no rect open.
    UnexpectedClose,
    /// The stream ends with a rect still open.
    UnclosedScope,
    /// The stream is balanced, but the tree's own count of open rects is not zero.
    ScopeDepthMismatch,
    /// A cursor does not follow text or another cursor.
    InvalidCursorPredecessor,
} || CursorValidationError;

/// Checks that a buffer of `capacity` entries holding `count` has room for `additional` more.
pub fn validateBufferCapacity(count: usize, capacity: usize, additional: usize) error{CapacityExceeded}!void {
    if (count > capacity or additional > capacity - count) return error.CapacityExceeded;
}

/// Checks that `additional` more rects may open at `depth` without passing `limit`.
pub fn validateScopeDepth(depth: usize, additional: usize, limit: usize) error{ScopeTooDeep}!void {
    if (depth > limit or additional > limit - depth) return error.ScopeTooDeep;
}

fn previousText(elements: []const Element) ?[]const u8 {
    var index = elements.len;
    while (index > 0) {
        index -= 1;
        switch (elements[index]) {
            .text => |text| return text.str,
            .cursor => continue,
            else => return null,
        }
    }
    return null;
}

/// Checks that the last of `elements` can take a click, scroll or hover attachment: a leaf rect, a
/// custom leaf, or a rect just begun. `MissingAttachmentTarget` when there are no elements;
/// `InvalidAttachmentTarget` when the last is text, a cursor or a close.
pub fn validateAttachmentTarget(elements: []const Element) error{ MissingAttachmentTarget, InvalidAttachmentTarget }!void {
    if (elements.len == 0) return error.MissingAttachmentTarget;
    switch (elements[elements.len - 1]) {
        .rect, .open_rect, .custom => {},
        else => return error.InvalidAttachmentTarget,
    }
}

/// Checks a whole element stream: rects balanced and nested at most `max_depth` deep, every
/// `scroll_cursor` and cursor offset valid for its text, and every cursor directly after text or
/// another cursor. This is what `Tree.include` and `Tree.commit` require of a stream.
pub fn validateElementStream(elements: []const Element, max_depth: usize) CommandValidationError!void {
    var depth: usize = 0;
    for (elements, 0..) |element, index| {
        switch (element) {
            .open_rect => {
                try validateScopeDepth(depth, 1, max_depth);
                depth += 1;
            },
            .close_rect => {
                if (depth == 0) return error.UnexpectedClose;
                depth -= 1;
            },
            .text => |text| if (text.params.scroll_cursor) |byte| try validateCursorOffset(text.str, byte),
            .cursor => |cursor| {
                if (index == 0) return error.MissingCursorPredecessor;
                switch (elements[index - 1]) {
                    .text, .cursor => {},
                    else => return error.InvalidCursorPredecessor,
                }
                const text = previousText(elements[0..index]) orelse return error.InvalidCursorPredecessor;
                try validateCursorOffset(text, cursor.byte);
            },
            .rect, .custom => {},
        }
    }
    if (depth != 0) return error.UnclosedScope;
}

/// Where and how one `Tree.commit` lays a tree out, paints it and writes its hit regions.
pub const Config = struct {
    /// The size, in pixels, of the area the top-level elements lay out in; a top-level `fill` is
    /// this size. Finite and not negative.
    root_size: math.Vec2f,

    /// Added to hit regions only: where the context's origin sits in the window, as a panel's
    /// viewport position is, so that regions are in the coordinates input reads the pointer in. It
    /// does not move paint.
    offset: math.Vec2f = .{ .x = 0, .y = 0 },

    /// Where the root's top-left corner sits in the context's coordinates. Moves paint, clips and
    /// hit regions together.
    origin: math.Vec2f = .{ .x = 0, .y = 0 },

    /// The element the pointer is over, as `input.hover` holds it: that element paints its
    /// `bg_hover`. Null falls back to `Tree.hovered`.
    hovered: ?ElementId = null,

    /// Written to every hit region of the commit. Where regions overlap, the press goes to the one
    /// with the greatest depth.
    depth: u32 = 0,

    /// Bounds hit regions in window coordinates, for a tree drawn inside a caller's scissor.
    hit_clip: ?ClipRect = null,
};

/// Why a `Config` is refused. `InvalidRootSize`: a dimension of `root_size` is negative or not
/// finite. `NonFiniteTransform`: a component of `offset` or `origin` is not finite.
pub const ConfigValidationError = error{ InvalidRootSize, NonFiniteTransform };

/// Checks a `Config` as `Tree.commit` requires it.
pub fn validateConfig(config: Config) ConfigValidationError!void {
    if (!std.math.isFinite(config.root_size.x) or config.root_size.x < 0 or
        !std.math.isFinite(config.root_size.y) or config.root_size.y < 0)
        return error.InvalidRootSize;
    if (!std.math.isFinite(config.offset.x) or !std.math.isFinite(config.offset.y) or
        !std.math.isFinite(config.origin.x) or !std.math.isFinite(config.origin.y))
        return error.NonFiniteTransform;
}

/// A hit region's columns for one of its targets: its tag, its user data and the inbox its
/// messages go to, each present only when the target has one. Input reads them.
pub const RegionRoute = input_mod.RegionRoute;
/// The route columns of a hit region, in this order: left click, right click, middle click, scroll.
/// `mesha.input.region_routes`.
pub const region_routes = input_mod.region_routes;

/// Initializes `schema` as a hit regions table's: `pos` and `size` (the region's rectangle, in
/// window pixels), `hover`, `tooltip`, `id` (an `ElementId`'s bytes), `depth`, `cursor`, and the
/// tag, user data and inbox columns of each of `region_routes`. The caller makes the table from the
/// schema, gives it to `Tree.commit` and to input in an `on_mouse` subscription, and deinits the
/// schema. Returns the error of `Table.Schema.init` when `scratch` cannot hold the schema.
pub fn initHitRegionSchema(schema: *Table.Schema, scratch: memory_mod.Scratch, atoms: *Atom.Registry) !void {
    try schema.init(scratch.allocator, atoms, 7 + 3 * region_routes.len);
    schema.addField("pos", math.Vec2f, .{ .vector = .{ .components = 2 } });
    schema.addField("size", math.Vec2f, .{ .vector = .{ .components = 2 } });
    schema.addField("hover", u8, .int);
    schema.addField("tooltip", Table.String, .text_field);
    schema.addField("id", [16]u8, .hex);
    schema.addField("depth", u32, .int);
    schema.addField("cursor", CursorKind, .int);
    for (region_routes) |region_route| {
        schema.addField(region_route.tag, Atom, .atom);
        schema.addField(region_route.user_data, Table.Bytes, .bytes);
        schema.addField(region_route.inbox, Atom, .atom);
    }
}

/// Where an element was laid out, as a hit region records it: its top-left corner and its size,
/// in window pixels, clipped to what encloses it.
pub const Place = struct {
    /// The top-left corner.
    pos: math.Vec2f,
    /// The size.
    size: math.Vec2f,
};

/// The place `Tree.commit` recorded for the element `id` in `hit_regions`, a table with
/// `initHitRegionSchema`'s columns: of several regions of one element, the later row's, as the
/// later row answers the pointer. Null for an element the commits since the table was last
/// cleared recorded no region for: one with no click or scroll target of its own, one clipped
/// away entirely, or one not drawn. A kernel reads it on the update after the commit, so what it
/// learns is one update behind what is drawn. Reads the table as any reader does, and writes
/// nothing.
pub fn committedPlace(hit_regions: *Table, id: ElementId) ?Place {
    const wanted = std.mem.toBytes(id);
    var place: ?Place = null;
    var rows = hit_regions.readQuery(struct { pos: *math.Vec2f, size: *math.Vec2f, id: *[16]u8 });
    while (rows.next()) |region| {
        if (!std.mem.eql(u8, region.view.id, &wanted)) continue;
        place = .{ .pos = region.view.pos.*, .size = region.view.size.* };
    }
    return place;
}

/// The capacity of a `Roots`.
pub const max_roots: usize = 8;
/// The deepest rects may nest in one tree. `Tree.beginRect` past it is a contract violation.
pub const max_scope_depth: usize = 63;

/// An entry of `Roots`: a rect's id and its params.
pub const RootSpec = struct {
    /// The rect's id.
    id: ElementId,
    /// The rect's params.
    params: RectParams,
};

/// A fixed list of up to `max_roots` `RootSpec`s, in the order pushed. Nothing else in this
/// library reads it.
pub const Roots = struct {
    /// Storage; only the first `count` entries are set.
    items: [max_roots]RootSpec = undefined,
    /// How many entries are pushed.
    count: usize = 0,

    /// Empties the list.
    pub fn reset(self: *Roots) void {
        self.count = 0;
    }

    /// Appends an entry. Pushing onto a full list is a contract violation.
    pub fn push(self: *Roots, id: ElementId, params: RectParams) void {
        validateBufferCapacity(self.count, self.items.len, 1) catch contract.invariant(false, "ui.roots.capacity");
        self.items[self.count] = .{ .id = id, .params = params };
        self.count += 1;
    }

    /// The pushed entries, borrowed from the list: valid until it is pushed to, reset or moved.
    pub fn slice(self: *const Roots) []const RootSpec {
        contract.invariant(self.count <= self.items.len, "ui.roots.count_valid");
        return self.items[0..self.count];
    }
};

/// One frame's recorded elements and the calls that record them. See the file's overview for the
/// order of calls.
///
/// Recording calls take an `id` in any form `toElementId` accepts. Recording past the tree's
/// capacity, or breaking a call's stated requirement, is a contract violation: a panic that names
/// the broken rule.
pub const Tree = struct {
    /// Allocates the element buffer, the user data and tooltips the tree copies, `allocBuffer`'s
    /// bytes and each commit's layout. Nothing is freed through the tree: give it a frame's
    /// scratch.
    frame_allocator: memory_mod.Scratch,
    /// The element buffer, its length the tree's capacity. `elements[0..count]` is the recorded
    /// stream.
    elements: []Element,
    /// How many elements are recorded.
    count: usize,
    /// How many rects are open.
    depth: usize,

    /// The registry string ids are interned in and names are looked up in. Borrowed.
    atoms: *Atom.Registry,
    /// The hovered element, used when `Config.hovered` is null: for a tree filled by one owner and
    /// committed by another, which may not know it.
    hovered: ?ElementId = null,
    /// False commits without writing hit regions, whatever table `commit` is given: the ui is drawn
    /// and takes no pointer.
    hits_enabled: bool = true,

    /// A tree with room for `max_cmds` elements, allocated from `frame_allocator`. A leaf, a text
    /// and a cursor are one element each; a container is two. `kw` is the atom registry, which must
    /// outlive the tree. Fails with `error.OutOfMemory`. There is no deinit: the memory is the
    /// allocator's.
    pub fn init(frame_allocator: memory_mod.Scratch, kw: *Atom.Registry, max_cmds: usize) !Tree {
        const cmds = try frame_allocator.allocator.alloc(Element, max_cmds);
        return .{
            .frame_allocator = frame_allocator,
            .elements = cmds,
            .count = 0,
            .depth = 0,
            .atoms = kw,
        };
    }

    /// The name of `id`'s atom, or null when the registry has none for it; `extra` is ignored. The
    /// slice is the registry's.
    pub fn lookupId(self: *const Tree, id: anytype) ?[]const u8 {
        const eid = self.toElementId(id);
        return self.atoms.lookup(eid.atom);
    }

    /// Turns any id form into an `ElementId`: an `ElementId` as it is, an `Atom`, a string
    /// (interned in the registry on every call), or a pair `.{ atom_or_string, number }` whose
    /// number becomes `extra`. Any other type is a compile error.
    pub fn toElementId(self: *const Tree, id: anytype) ElementId {
        const T = @TypeOf(id);
        if (T == ElementId) return id;
        if (T == Atom) return .{ .atom = id };
        if (comptime isStringType(T)) return .{ .atom = self.atoms.intern(id) };
        switch (@typeInfo(T)) {
            .@"struct" => |s| if (s.is_tuple and s.fields.len == 2) {
                const base = self.toElementId(id[0]);
                return .{ .atom = base.atom, .extra = @as(u64, id[1]) };
            },
            else => {},
        }
        @compileError("ui: unsupported element id type " ++ @typeName(T) ++ ". Supported id forms are: Atom|\"string\"|.{Atom|\"string\", u64}");
    }

    /// Forgets the recorded elements, so the buffer can be recorded into again. Every rect must be
    /// closed. Frees nothing.
    pub fn reset(self: *Tree) void {
        contract.invariant(self.depth == 0, "ui.tree.reset_balanced");
        self.count = 0;
        self.depth = 0;
    }

    fn emit(self: *Tree, cmd: Element) void {
        validateBufferCapacity(self.count, self.elements.len, 1) catch contract.invariant(false, "ui.tree.command_capacity");
        self.elements[self.count] = cmd;
        self.count += 1;
    }

    /// Opens a container rect: the elements recorded until the matching `endRect` are its children.
    /// Returns false when `params.collapsed`, having recorded the rect closed and empty: skip the
    /// children then, and do not call `endRect`. The usual form is `if (!ui.beginRect(id, .{}))
    /// return;` followed by `defer ui.endRect();`. Nesting deeper than `max_scope_depth` is a
    /// contract violation.
    pub fn beginRect(self: *Tree, id: anytype, params: RectParams) bool {
        validateScopeDepth(self.depth, 1, max_scope_depth) catch contract.invariant(false, "ui.tree.scope_depth");
        var p = params;
        p.id = self.toElementId(id);
        if (p.collapsed) {
            self.emit(.{ .open_rect = p });
            self.emit(.close_rect);
            return false;
        }
        self.emit(.{ .open_rect = p });
        self.depth += 1;
        return true;
    }

    /// Closes the rect the last unmatched `beginRect` opened. With none open it is a contract
    /// violation.
    pub fn endRect(self: *Tree) void {
        contract.invariant(self.depth > 0, "ui.tree.scope_underflow");
        self.emit(.close_rect);
        self.depth -= 1;
    }

    /// Records a leaf rect: a spacer, a filled box, or a button once `onClick` follows it.
    pub fn rect(self: *Tree, id: anytype, params: RectParams) void {
        var p = params;
        p.id = self.toElementId(id);
        self.emit(.{ .rect = p });
    }

    /// Records a rect-like leaf whose paint is entirely supplied by a public
    /// `draw(size: math.Vec2f, ctx: *roop.Context) void` method on the drawable.
    /// The borrowed *T or *const T and its referenced data must remain valid through
    /// every commit. Draw receives the full size and a context translated to the
    /// rect's top-left, with inherited clipping applied. It must balance its own
    /// context state and other scopes and manage its active path.
    pub fn custom(self: *Tree, id: anytype, drawable: anytype, params: RectParams) void {
        const Pointer = @TypeOf(drawable);
        const info = @typeInfo(Pointer);
        if (info != .pointer or info.pointer.size != .one) {
            @compileError("ui.custom expects a borrowed *T or *const T drawable");
        }
        const trampoline = struct {
            fn draw(object: *const anyopaque, size: math.Vec2f, ctx: *roop.Context) callconv(.c) void {
                const ptr: Pointer = if (info.pointer.is_const)
                    @ptrCast(@alignCast(object))
                else
                    @ptrCast(@alignCast(@constCast(object)));
                ptr.draw(size, ctx);
            }
        };
        var p = params;
        p.id = self.toElementId(id);
        self.emit(.{ .custom = .{ .params = p, .drawable = .{ .object = drawable, .draw = trampoline.draw } } });
    }

    /// `len` uninitialized bytes from the frame allocator, for formatting a string given to `text`.
    /// They live as long as the frame allocator's memory, so through `commit`. Panics when out of
    /// memory.
    pub fn allocBuffer(self: *Tree, len: usize) []u8 {
        return self.frame_allocator.allocator.alloc(u8, len) catch @panic("ui: OOM allocating text buffer");
    }

    /// Records a run of text. `str` is borrowed until the tree's last `commit` returns. A
    /// `params.scroll_cursor` that is not a cursor position in `str` is a contract violation;
    /// `textChecked` returns it.
    pub fn text(self: *Tree, id: anytype, str: []const u8, params: TextParams) void {
        self.textChecked(id, str, params) catch contract.invariant(false, "ui.tree.text_cursor_offset");
    }

    /// `text`, returning the error when `params.scroll_cursor` is not a cursor position in `str`.
    /// Nothing is recorded on error.
    pub fn textChecked(self: *Tree, id: anytype, str: []const u8, params: TextParams) CursorValidationError!void {
        if (params.scroll_cursor) |byte| try validateCursorOffset(str, byte);
        var p = params;
        p.id = self.toElementId(id);
        self.emit(.{ .text = .{ .str = str, .params = p } });
    }

    /// A target under `tag` for the inbox `inbox`, carrying back `user_data`'s bytes, which
    /// the tree's frame keeps until it writes its regions; void carries none.
    pub fn target(self: *Tree, inbox: Atom, tag: Atom, user_data: anytype) Target {
        if (@TypeOf(user_data) == void) return .{ .tag = tag, .inbox = inbox };
        const kept = self.frame_allocator.allocator.dupe(u8, std.mem.asBytes(&user_data)) catch {
            contract.invariant(false, "ui.tree.target_user_data");
            unreachable;
        };
        return .{ .tag = tag, .user_data = kept, .inbox = inbox };
    }

    /// Sends presses of `button` on the element just recorded to `on_click`, and gives the element
    /// a hit region. Call it directly after `rect` or `custom`, or after `beginRect` before any
    /// child is recorded. A second call for the same button replaces the first. Combining `.all`
    /// with a single button on one rect, or attaching to text, a cursor or a rect already closed,
    /// is a contract violation.
    pub fn onClick(self: *Tree, on_click: Target, button: ClickButton) void {
        validateBufferCapacity(self.count, self.elements.len, 0) catch {
            contract.invariant(false, "ui.tree.click_count_valid");
            unreachable;
        };
        validateAttachmentTarget(self.elements[0..self.count]) catch {
            contract.invariant(false, "ui.tree.click_target");
            unreachable;
        };
        switch (self.elements[self.count - 1]) {
            .rect => |*p| setClick(p, on_click, button),
            .custom => |*c| setClick(&c.params, on_click, button),
            .open_rect => |*p| setClick(p, on_click, button),
            else => unreachable,
        }
    }

    fn setClick(params: *RectParams, route: Target, button: ClickButton) void {
        const has_route = params.on_click != null or params.on_right_click != null or params.on_middle_click != null;
        if (button == .all) contract.invariant(!has_route, "ui.tree.click_all_alone");
        if (button != .all) contract.invariant(!params.click_all, "ui.tree.click_all_alone");
        switch (button) {
            .left => params.on_click = route,
            .right => params.on_right_click = route,
            .middle => params.on_middle_click = route,
            .all => {
                params.on_click = route;
                params.on_right_click = route;
                params.on_middle_click = route;
                params.click_all = true;
            },
        }
    }

    /// The pointer over the rect just begun is followed, the rect saying `tooltip`, which may
    /// be empty and is copied. Every clickable rect wants this: `bg_hover` paints only for the
    /// element input reports the pointer over, and only followed rects are reported.
    pub fn trackHover(self: *Tree, tooltip: []const u8) void {
        validateBufferCapacity(self.count, self.elements.len, 0) catch {
            contract.invariant(false, "ui.tree.hover_count_valid");
            unreachable;
        };
        validateAttachmentTarget(self.elements[0..self.count]) catch {
            contract.invariant(false, "ui.tree.hover_target");
            unreachable;
        };
        const kept: []const u8 = if (tooltip.len == 0) "" else self.frame_allocator.allocator.dupe(u8, tooltip) catch {
            contract.invariant(false, "ui.tree.hover_tooltip");
            unreachable;
        };
        switch (self.elements[self.count - 1]) {
            .rect => |*p| {
                p.hover = true;
                p.tooltip = kept;
            },
            .custom => |*c| {
                c.params.hover = true;
                c.params.tooltip = kept;
            },
            .open_rect => |*p| {
                p.hover = true;
                p.tooltip = kept;
            },
            else => unreachable,
        }
    }

    /// Sends the wheel over the element just recorded to `on_scroll`, and gives the element a hit
    /// region. Regions inside it with no scroll target of their own send the wheel here too. It
    /// attaches as `onClick` does, to a leaf rect, a custom leaf or a rect just begun.
    pub fn onScroll(self: *Tree, on_scroll: Target) void {
        self.setHoverPayload("on_scroll", on_scroll);
    }

    fn setHoverPayload(self: *Tree, comptime field_name: []const u8, payload: Target) void {
        validateBufferCapacity(self.count, self.elements.len, 0) catch {
            contract.invariant(false, "ui.tree.hover_count_valid");
            unreachable;
        };
        validateAttachmentTarget(self.elements[0..self.count]) catch {
            contract.invariant(false, "ui.tree.hover_target");
            unreachable;
        };
        switch (self.elements[self.count - 1]) {
            .rect => |*p| @field(p, field_name) = payload,
            .custom => |*c| @field(c.params, field_name) = payload,
            .open_rect => |*p| @field(p, field_name) = payload,
            else => unreachable,
        }
    }

    /// Records a caret at `byte_offset` of the text recorded before it; only other cursors may come
    /// between. A fixed `params.size.w` is its width (2 pixels otherwise), a fixed `params.size.h`
    /// its height (the text's line height otherwise), `params.bg` its color (opaque white
    /// otherwise), and `params.corner_radius` rounds it. Carets are painted after everything else
    /// in the tree, clipped as their text is. An offset past the text or inside a codepoint, or a
    /// cursor that does not follow text, is a contract violation; `cursorChecked` returns it.
    pub fn cursor(self: *Tree, id: anytype, byte_offset: usize, params: RectParams) void {
        self.cursorChecked(id, byte_offset, params) catch contract.invariant(false, "ui.tree.cursor_precondition");
    }

    /// `cursor`, returning why the cursor is refused. Nothing is recorded on error.
    pub fn cursorChecked(self: *Tree, id: anytype, byte_offset: usize, params: RectParams) CursorValidationError!void {
        if (self.count == 0) return error.MissingCursorPredecessor;
        if (self.count > self.elements.len) return error.InvalidCursorPredecessor;
        switch (self.elements[self.count - 1]) {
            .text => |text_value| try validateCursorOffset(text_value.str, byte_offset),
            .cursor => {
                const anchor = previousText(self.elements[0..self.count]) orelse return error.InvalidCursorPredecessor;
                try validateCursorOffset(anchor, byte_offset);
            },
            else => return error.InvalidCursorPredecessor,
        }
        var p = params;
        p.id = self.toElementId(id);
        self.emit(.{ .cursor = .{ .byte = byte_offset, .params = p } });
    }

    /// Appends `elements`, a whole stream another tree made, in the scope now open: as a panel's
    /// header takes the decoration a plugin built in a tree of its own, with its own allocator,
    /// so neither image allocates through the other's tree.
    pub fn include(self: *Tree, elements: []const Element) void {
        validateBufferCapacity(self.count, self.elements.len, elements.len) catch contract.invariant(false, "ui.tree.command_capacity");
        validateElementStream(elements, max_scope_depth - self.depth) catch contract.invariant(false, "ui.tree.included_stream");
        @memcpy(self.elements[self.count..][0..elements.len], elements);
        self.count += elements.len;
    }

    /// Checks the recorded stream as `commit` requires it: within capacity, balanced, every cursor
    /// valid, and no rect open. For a caller that hands `elements[0..count]` on, as a plugin does a
    /// panel's decoration.
    pub fn validateCommands(self: *const Tree) CommandValidationError!void {
        try validateBufferCapacity(self.count, self.elements.len, 0);
        try validateElementStream(self.elements[0..self.count], max_scope_depth);
        if (self.depth != 0) return error.ScopeDepthMismatch;
    }

    /// Lays the recorded elements out in `config`, paints them into `ctx`, and writes their hit
    /// regions.
    ///
    /// Elements are painted in the order recorded, so a rect lies under its children and under the
    /// siblings after it; carets are painted last. The context's state is saved and restored around
    /// each element.
    ///
    /// When `hit_regions` is given and `hits_enabled` is set, a row is appended to it for every
    /// rect with a click target or a scroll target of its own: the rect's rectangle, clipped by its
    /// ancestors' `clip_content` and by `config.hit_clip`, with its id, depth, cursor, hover flag,
    /// tooltip and targets. A region clipped away entirely is left out. The table must have
    /// `initHitRegionSchema`'s columns; commit does not clear it. User data the table cannot keep
    /// is left out of its region and logged.
    ///
    /// Text in a font not loaded yet is laid out and drawn in the engine's font, and the font is
    /// asked for with its reply to `redraw_inbox` under `redraw_tag` (`roop.Context.redraw_inbox`):
    /// once it loads, the system that reads that inbox redraws what this tree drew, as with
    /// `panels.requestRedraw`. `no_inbox` still asks for the font but tells no one,
    /// for a tree drawn every frame.
    ///
    /// The tree is not changed and may be committed again. An invalid stream or config is a
    /// contract violation. Layout memory comes from the frame allocator, and running out of it
    /// panics.
    pub fn commit(self: *Tree, config: Config, ctx: *roop.Context, hit_regions: ?*Table, redraw_inbox: Atom) void {
        self.validateCommands() catch contract.invariant(false, "ui.commit.command_stream");
        validateConfig(config) catch contract.invariant(false, "ui.commit.config");
        var effective = config;
        if (effective.hovered == null) effective.hovered = self.hovered;
        var layout = Layout.build(self.frame_allocator, self.elements[0..self.count], effective);
        const outer_inbox = ctx.redraw_inbox;
        ctx.redraw_inbox = redraw_inbox;
        defer ctx.redraw_inbox = outer_inbox;
        layout.run(if (self.hits_enabled) hit_regions else null, ctx);
    }
};

const NONE: u32 = std.math.maxInt(u32);
const eps: f32 = 0.01;

const Line = struct { str: []const u8, width: f32 };

const CursorEntry = struct { node: u32, byte: usize, params: RectParams };

const Node = struct {
    kind: enum { rect, text },
    rect: RectParams = .{},
    drawable: ?CustomDrawable = null,
    text_str: []const u8 = "",
    text_params: TextParams = .{},

    parent: u32 = NONE,
    on_scroll: ?Target = null,
    first_child: u32 = NONE,
    last_child: u32 = NONE,
    next_sibling: u32 = NONE,
    child_count: u32 = 0,

    pos: math.Vec2f = .{ .x = 0, .y = 0 },
    size: math.Vec2f = .{ .x = 0, .y = 0 },

    clip: ?ClipRect = null,

    lines: []Line = &.{},
    line_height: f32 = 0,
    text_scroll_x: f32 = 0,
};

inline fn other(axis: Axis) Axis {
    return if (axis == .horizontal) .vertical else .horizontal;
}

inline fn dimGet(v: math.Vec2f, axis: Axis) f32 {
    return if (axis == .horizontal) v.x else v.y;
}

inline fn dimSet(v: *math.Vec2f, axis: Axis, val: f32) void {
    if (axis == .horizontal) v.x = val else v.y = val;
}

/// A rectangle in pixels: `x` and `y` its top-left corner, `w` and `h` its size, `radius` the
/// rounding of its corners.
pub const ClipRect = struct { x: f32, y: f32, w: f32, h: f32, radius: f32 = 0 };

fn clipIntersect(a: ?ClipRect, r: ClipRect) ClipRect {
    const c = a orelse return r;
    const x0 = @max(c.x, r.x);
    const y0 = @max(c.y, r.y);
    const x1 = @min(c.x + c.w, r.x + r.w);
    const y1 = @min(c.y + c.h, r.y + r.h);

    return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0), .radius = @min(c.radius, r.radius) };
}

/// The space between a rect's edges and its children across `axis`: `padding` at its ends,
/// `padding_y` (when given) above and below.
fn paddingAcross(rect: RectParams, axis: Axis) f32 {
    return switch (axis) {
        .horizontal => rect.padding,
        .vertical => rect.padding_y orelse rect.padding,
    };
}

fn inheritedClip(n: *const Node) ?ClipRect {
    if (!n.rect.clip_content) return n.clip;
    const pad_x = paddingAcross(n.rect, .horizontal);
    const pad_y = paddingAcross(n.rect, .vertical);
    const smaller_pad = @min(pad_x, pad_y);

    const radius = @max(0, n.rect.corner_radius - smaller_pad);
    return clipIntersect(n.clip, .{
        .x = n.pos.x + pad_x,
        .y = n.pos.y + pad_y,
        .w = @max(0, n.size.x - 2 * pad_x),
        .h = @max(0, n.size.y - 2 * pad_y),
        .radius = radius,
    });
}

const ClippedRegion = struct { pos: math.Vec2f, size: math.Vec2f };

fn clippedRegion(pos: math.Vec2f, size: math.Vec2f, clip: ?ClipRect) ?ClippedRegion {
    const c = clip orelse return .{ .pos = pos, .size = size };
    const r = clipIntersect(c, .{ .x = pos.x, .y = pos.y, .w = size.x, .h = size.y });
    if (r.w <= 0 or r.h <= 0) return null;
    return .{ .pos = .{ .x = r.x, .y = r.y }, .size = .{ .x = r.w, .y = r.h } };
}

fn applyClip(ctx: *roop.Context, clip: ?ClipRect) void {
    if (clip) |r| ctx.intersectScissor(r.x, r.y, r.w, r.h, r.radius);
}

fn nodeDim(n: *const Node, axis: Axis) Dim {
    const s = if (n.kind == .text) n.text_params.size_hint else n.rect.size;
    return if (axis == .horizontal) s.w else s.h;
}

const Layout = struct {
    arena: memory_mod.Scratch,
    cfg: Config,
    nodes: []Node,
    count: usize,

    cursors: std.ArrayListUnmanaged(CursorEntry),

    fn build(arena: memory_mod.Scratch, elements: []const Element, cfg: Config) Layout {
        const nodes = arena.allocator.alloc(Node, elements.len + 1) catch @panic("ui: OOM building layout");
        var self = Layout{
            .arena = arena,
            .cfg = cfg,
            .nodes = nodes,
            .count = 0,
            .cursors = .empty,
        };

        self.nodes[0] = .{
            .kind = .rect,
            .rect = .{
                .axis = .vertical,
                .size = .{
                    .w = .{ .fixed = cfg.root_size.x },
                    .h = .{ .fixed = cfg.root_size.y },
                },
            },
        };
        self.count = 1;

        var stack: [64]u32 = undefined;
        var sp: usize = 0;
        stack[0] = 0;
        var last_text: u32 = NONE;
        for (elements) |el| {
            switch (el) {
                .open_rect => |params| {
                    contract.invariant(sp + 1 < stack.len, "ui.layout.stack_capacity");
                    const idx = self.addChild(stack[sp], .{ .kind = .rect, .rect = params });
                    sp += 1;
                    stack[sp] = idx;
                },
                .close_rect => {
                    contract.invariant(sp > 0, "ui.layout.scope_underflow");
                    sp -= 1;
                },
                .rect => |params| {
                    _ = self.addChild(stack[sp], .{ .kind = .rect, .rect = params });
                },
                .custom => |c| {
                    _ = self.addChild(stack[sp], .{ .kind = .rect, .rect = c.params, .drawable = c.drawable });
                },
                .text => |t| {
                    last_text = self.addChild(stack[sp], .{
                        .kind = .text,
                        .text_str = t.str,
                        .text_params = t.params,
                    });
                },

                .cursor => |c| {
                    contract.invariant(last_text != NONE, "ui.layout.cursor_anchor");
                    self.cursors.append(arena.allocator, .{
                        .node = last_text,
                        .byte = c.byte,
                        .params = c.params,
                    }) catch @panic("ui: OOM collecting cursors");
                },
            }
        }
        contract.invariant(sp == 0, "ui.layout.scopes_balanced");

        return self;
    }

    fn addChild(self: *Layout, parent: u32, node: Node) u32 {
        const idx: u32 = @intCast(self.count);
        self.nodes[idx] = node;
        self.nodes[idx].parent = parent;
        self.count += 1;

        const p = &self.nodes[parent];
        if (p.first_child == NONE) {
            p.first_child = idx;
        } else {
            self.nodes[p.last_child].next_sibling = idx;
        }
        p.last_child = idx;
        p.child_count += 1;
        return idx;
    }

    fn run(self: *Layout, hit_regions: ?*Table, ctx: *roop.Context) void {
        self.fitAlongAxis(.horizontal, ctx);
        self.growShrinkAlongAxis(.horizontal);
        self.wrapText(ctx);
        self.fitAlongAxis(.vertical, ctx);
        self.growShrinkAlongAxis(.vertical);
        self.positionAndEmit(hit_regions, ctx);
    }

    fn fitAlongAxis(self: *Layout, axis: Axis, ctx: *roop.Context) void {
        var i: usize = self.count;
        while (i > 0) {
            i -= 1;
            const n = &self.nodes[i];

            if (n.kind == .text) {
                self.fitText(n, axis, ctx);
                continue;
            }

            const dim = nodeDim(n, axis);
            switch (dim) {
                .fixed => |v| dimSet(&n.size, axis, v),

                .hug, .fill => {
                    const pad = paddingAcross(n.rect, axis);
                    var content: f32 = 0;
                    if (axis == n.rect.axis) {
                        var sum: f32 = 0;
                        var c = n.first_child;
                        while (c != NONE) : (c = self.nodes[c].next_sibling) {
                            sum += dimGet(self.nodes[c].size, axis);
                        }
                        const gaps = if (n.child_count > 1)
                            n.rect.gap * @as(f32, @floatFromInt(n.child_count - 1))
                        else
                            0;
                        content = sum + gaps;
                    } else {
                        var mx: f32 = 0;
                        var c = n.first_child;
                        while (c != NONE) : (c = self.nodes[c].next_sibling) {
                            mx = @max(mx, dimGet(self.nodes[c].size, axis));
                        }
                        content = mx;
                    }
                    dimSet(&n.size, axis, content + 2 * pad);
                },
            }
        }
    }

    fn fitText(self: *Layout, n: *Node, axis: Axis, ctx: *roop.Context) void {
        _ = self;
        const measured = ctx.measureText(n.text_params.font, n.text_str);
        if (axis == .horizontal) {
            n.line_height = measured.h;
            const dim = nodeDim(n, .horizontal);
            switch (dim) {
                .fixed => |v| n.size.x = v,
                .hug => n.size.x = measured.w,
                .fill => n.size.x = longestWord(n.text_params.font, n.text_str, ctx),
            }
        } else {
            const dim = nodeDim(n, .vertical);
            switch (dim) {
                .fixed => |v| n.size.y = v,

                .hug, .fill => {
                    const rows: f32 = @floatFromInt(@max(n.lines.len, 1));
                    n.size.y = rows * n.line_height;
                },
            }
        }
    }

    fn longestWord(font: roop.Font, str: []const u8, ctx: *roop.Context) f32 {
        var mx: f32 = 0;
        var it = std.mem.tokenizeScalar(u8, str, ' ');
        while (it.next()) |word| {
            mx = @max(mx, ctx.measureText(font, word).w);
        }
        return mx;
    }

    fn growShrinkAlongAxis(self: *Layout, axis: Axis) void {
        for (0..self.count) |i| {
            const n = &self.nodes[i];
            if (n.child_count == 0) continue;

            if (i == 0) {
                var c = n.first_child;
                while (c != NONE) : (c = self.nodes[c].next_sibling) {
                    if (nodeDim(&self.nodes[c], axis) == .fill) {
                        dimSet(&self.nodes[c].size, axis, dimGet(self.cfg.root_size, axis));
                    }
                }
                continue;
            }

            if (axis == n.rect.axis) {
                const pad = paddingAcross(n.rect, axis);
                const gaps = if (n.child_count > 1)
                    n.rect.gap * @as(f32, @floatFromInt(n.child_count - 1))
                else
                    0;
                const inner = dimGet(n.size, axis) - 2 * pad - gaps;

                if (n.rect.equal_fill) {
                    self.distributeEqual(n, axis, inner);
                    continue;
                }

                var used: f32 = 0;
                var c = n.first_child;
                while (c != NONE) : (c = self.nodes[c].next_sibling) {
                    used += dimGet(self.nodes[c].size, axis);
                }
                const remaining = inner - used;
                if (remaining > eps) {
                    self.distributeGrow(n, axis, remaining);
                } else if (remaining < -eps) {
                    self.distributeShrink(n, axis, -remaining);
                }
            } else {
                const pad = paddingAcross(n.rect, axis);
                const inner = dimGet(n.size, axis) - 2 * pad;
                var c = n.first_child;
                while (c != NONE) : (c = self.nodes[c].next_sibling) {
                    if (nodeDim(&self.nodes[c], axis) == .fill) {
                        dimSet(&self.nodes[c].size, axis, inner);
                    }
                }
            }
        }
    }

    fn distributeEqual(self: *Layout, parent: *Node, axis: Axis, inner: f32) void {
        var fixed_used: f32 = 0;
        var fill_count: u32 = 0;
        var c = parent.first_child;
        while (c != NONE) : (c = self.nodes[c].next_sibling) {
            if (nodeDim(&self.nodes[c], axis) == .fill) {
                fill_count += 1;
            } else {
                fixed_used += dimGet(self.nodes[c].size, axis);
            }
        }
        if (fill_count == 0) return;
        const share = @max(0, inner - fixed_used) / @as(f32, @floatFromInt(fill_count));
        c = parent.first_child;
        while (c != NONE) : (c = self.nodes[c].next_sibling) {
            if (nodeDim(&self.nodes[c], axis) == .fill) dimSet(&self.nodes[c].size, axis, share);
        }
    }

    fn distributeGrow(self: *Layout, parent: *Node, axis: Axis, remaining: f32) void {
        var rem = remaining;
        while (rem > eps) {
            var smallest: f32 = std.math.floatMax(f32);
            var second: f32 = std.math.floatMax(f32);
            var cnt: u32 = 0;
            var c = parent.first_child;
            while (c != NONE) : (c = self.nodes[c].next_sibling) {
                if (nodeDim(&self.nodes[c], axis) != .fill) continue;
                const s = dimGet(self.nodes[c].size, axis);
                if (s < smallest - eps) {
                    second = smallest;
                    smallest = s;
                    cnt = 1;
                } else if (s <= smallest + eps) {
                    cnt += 1;
                } else if (s < second) {
                    second = s;
                }
            }
            if (cnt == 0) break;

            var add = rem / @as(f32, @floatFromInt(cnt));
            if (second != std.math.floatMax(f32)) add = @min(add, second - smallest);
            if (add <= eps) break;

            c = parent.first_child;
            while (c != NONE) : (c = self.nodes[c].next_sibling) {
                if (nodeDim(&self.nodes[c], axis) != .fill) continue;
                if (dimGet(self.nodes[c].size, axis) <= smallest + eps) {
                    dimSet(&self.nodes[c].size, axis, dimGet(self.nodes[c].size, axis) + add);
                }
            }
            rem -= add * @as(f32, @floatFromInt(cnt));
        }
    }

    fn distributeShrink(self: *Layout, parent: *Node, axis: Axis, overflow: f32) void {
        var rem = overflow;
        while (rem > eps) {
            var largest: f32 = -std.math.floatMax(f32);
            var second: f32 = -std.math.floatMax(f32);
            var cnt: u32 = 0;
            var c = parent.first_child;
            while (c != NONE) : (c = self.nodes[c].next_sibling) {
                if (nodeDim(&self.nodes[c], axis) != .fill) continue;
                const s = dimGet(self.nodes[c].size, axis);
                if (s > largest + eps) {
                    second = largest;
                    largest = s;
                    cnt = 1;
                } else if (s >= largest - eps) {
                    cnt += 1;
                } else if (s > second) {
                    second = s;
                }
            }
            if (cnt == 0) break;

            var sub = rem / @as(f32, @floatFromInt(cnt));
            if (second != -std.math.floatMax(f32)) sub = @min(sub, largest - second);
            sub = @min(sub, largest);
            if (sub <= eps) break;

            c = parent.first_child;
            while (c != NONE) : (c = self.nodes[c].next_sibling) {
                if (nodeDim(&self.nodes[c], axis) != .fill) continue;
                if (dimGet(self.nodes[c].size, axis) >= largest - eps) {
                    dimSet(&self.nodes[c].size, axis, dimGet(self.nodes[c].size, axis) - sub);
                }
            }
            rem -= sub * @as(f32, @floatFromInt(cnt));
        }
    }

    fn wrapText(self: *Layout, ctx: *roop.Context) void {
        for (0..self.count) |i| {
            const n = &self.nodes[i];
            if (n.kind != .text) continue;

            const width = n.size.x;
            const natural = ctx.measureText(n.text_params.font, n.text_str).w;
            if (n.text_params.scroll_cursor) |cursor_byte| {
                n.lines = self.arena.allocator.alloc(Line, 1) catch @panic("ui: OOM wrapping text");
                n.lines[0] = .{ .str = n.text_str, .width = natural };
                const cursor = @min(cursor_byte, n.text_str.len);
                const cursor_x = ctx.measureText(n.text_params.font, n.text_str[0..cursor]).w;
                n.text_scroll_x = cursorScrollOffset(cursor_x, width);
                continue;
            }
            if (natural <= width + eps) {
                n.lines = self.arena.allocator.alloc(Line, 1) catch @panic("ui: OOM wrapping text");
                n.lines[0] = .{ .str = n.text_str, .width = natural };
                continue;
            }

            var lines: std.ArrayListUnmanaged(Line) = .empty;
            const str = n.text_str;
            var line_start: usize = 0;
            var line_end: usize = 0;
            var w: usize = 0;
            while (w < str.len) {
                while (w < str.len and str[w] == ' ') w += 1;
                const word_start = w;
                while (w < str.len and str[w] != ' ') w += 1;
                const word_end = w;
                if (word_end == word_start) break;

                const cand = str[line_start..word_end];
                const cand_w = ctx.measureText(n.text_params.font, cand).w;
                if (line_end == line_start or cand_w <= width + eps) {
                    line_end = word_end;
                } else {
                    const slice = str[line_start..line_end];
                    lines.append(self.arena.allocator, .{
                        .str = slice,
                        .width = ctx.measureText(n.text_params.font, slice).w,
                    }) catch @panic("ui: OOM wrapping text");
                    line_start = word_start;
                    line_end = word_end;
                }
            }
            if (line_end > line_start) {
                const slice = str[line_start..line_end];
                lines.append(self.arena.allocator, .{
                    .str = slice,
                    .width = ctx.measureText(n.text_params.font, slice).w,
                }) catch @panic("ui: OOM wrapping text");
            }
            n.lines = lines.items;
        }
    }

    fn assignPositions(self: *Layout) void {
        if (self.count == 0) return;
        self.nodes[0].pos = .{ .x = 0, .y = 0 };

        for (0..self.count) |i| {
            const n = &self.nodes[i];
            if (n.child_count == 0) continue;

            if (i == 0) {
                var c = n.first_child;
                while (c != NONE) : (c = self.nodes[c].next_sibling) {
                    self.nodes[c].pos = .{ .x = 0, .y = 0 };
                }
                continue;
            }

            const layout_axis = n.rect.axis;
            const perp_axis = other(layout_axis);
            const pad_along = paddingAcross(n.rect, layout_axis);
            const pad_across = paddingAcross(n.rect, perp_axis);
            var along = dimGet(n.pos, layout_axis) + pad_along;
            if (n.rect.main_align != .start and n.rect.scroll == .none) {
                var content: f32 = n.rect.gap * @as(f32, @floatFromInt(n.child_count - 1));
                var sibling = n.first_child;
                while (sibling != NONE) : (sibling = self.nodes[sibling].next_sibling) {
                    content += dimGet(self.nodes[sibling].size, layout_axis);
                }
                const free = @max(0, dimGet(n.size, layout_axis) - 2 * pad_along - content);
                along += if (n.rect.main_align == .center) free * 0.5 else free;
            }
            const perp = dimGet(n.pos, perp_axis) + pad_across;

            const child_clip = inheritedClip(n);
            var c = n.first_child;
            while (c != NONE) : (c = self.nodes[c].next_sibling) {
                const child = &self.nodes[c];
                dimSet(&child.pos, layout_axis, along);
                const cross_space = dimGet(n.size, perp_axis) - 2 * pad_across - dimGet(child.size, perp_axis);
                const cross_available = @max(0, cross_space);
                const cross_offset = switch (n.rect.cross_align) {
                    .start => 0,
                    .center => cross_available * 0.5,
                    .end => cross_available,
                };
                dimSet(&child.pos, perp_axis, perp + cross_offset);
                switch (n.rect.scroll) {
                    .none => {},
                    .horizontal => child.pos.x -= n.rect.scroll_offset,
                    .vertical => child.pos.y -= n.rect.scroll_offset,
                }
                along += dimGet(child.size, layout_axis) + n.rect.gap;
                child.clip = child_clip;
            }
        }
    }

    fn positionAndEmit(self: *Layout, hit_regions: ?*Table, ctx: *roop.Context) void {
        self.assignPositions();
        if (self.cfg.origin.x != 0 or self.cfg.origin.y != 0) {
            for (self.nodes[0..self.count]) |*node| {
                node.pos.x += self.cfg.origin.x;
                node.pos.y += self.cfg.origin.y;
                if (node.clip) |*clip| {
                    clip.x += self.cfg.origin.x;
                    clip.y += self.cfg.origin.y;
                }
            }
        }

        for (0..self.count) |i| {
            const n = &self.nodes[i];

            self.emitNode(n, ctx);

            if (n.kind == .rect) {
                // Parents precede their children, so the parent's route is already resolved.
                n.on_scroll = n.rect.on_scroll orelse if (n.parent != NONE) self.nodes[n.parent].on_scroll else null;
                const clickable = n.rect.on_click != null or n.rect.on_right_click != null or n.rect.on_middle_click != null;
                if (clickable or n.rect.on_scroll != null) {
                    if (hit_regions) |hr| {
                        var region_clip = n.clip;
                        if (region_clip) |*rc| {
                            rc.x += self.cfg.offset.x;
                            rc.y += self.cfg.offset.y;
                        }
                        if (self.cfg.hit_clip) |hit_clip| region_clip = clipIntersect(region_clip, hit_clip);
                        if (clippedRegion(.{
                            .x = n.pos.x + n.rect.offset.x + self.cfg.offset.x,
                            .y = n.pos.y + n.rect.offset.y + self.cfg.offset.y,
                        }, n.size, region_clip)) |region| {
                            const row = hr.insert(.{
                                .pos = region.pos,
                                .size = region.size,
                                .hover = @as(u8, @intFromBool(n.rect.hover)),
                                .tooltip = n.rect.tooltip,
                                .id = std.mem.toBytes(n.rect.id),
                                .depth = self.cfg.depth,
                                .cursor = n.rect.cursor,
                            });
                            // Only the targets that exist become present, so a region that just
                            // scrolls lets a press through.
                            const routes = [_]struct { region_route: RegionRoute, target: ?Target }{
                                .{ .region_route = region_routes[0], .target = n.rect.on_click },
                                .{ .region_route = region_routes[1], .target = n.rect.on_right_click },
                                .{ .region_route = region_routes[2], .target = n.rect.on_middle_click },
                                .{ .region_route = region_routes[3], .target = n.on_scroll },
                            };
                            for (routes) |entry| {
                                const target = entry.target orelse continue;
                                setRegionTarget(hr, row, entry.region_route, target);
                            }
                        }
                    }
                }
            }
        }

        for (self.cursors.items) |entry| self.emitCursor(entry, ctx);
    }

    /// Writes a region's target for one of its routes: its tag, and its user data and inbox
    /// when it has them. User data that cannot be kept is left out, and logged.
    fn setRegionTarget(regions: *Table, row: Table.RowHandle, region_route: RegionRoute, target: Target) void {
        const schema = regions.getSchema();
        const tag_index: u32 = @intCast(schema.fieldIndex(region_route.tag).?);
        regions.setFieldPresent(row, tag_index);
        regions.getFieldByIndex(Atom, row, tag_index).?.* = target.tag;
        if (target.user_data.len != 0) {
            regions.setBytes(row, region_route.user_data, target.user_data) catch |err| {
                Log.err("region_user_data_dropped", .{ .@"error" = @errorName(err) });
            };
        }
        if (target.inbox == no_inbox) return;
        const inbox_index: u32 = @intCast(schema.fieldIndex(region_route.inbox).?);
        regions.setFieldPresent(row, inbox_index);
        regions.getFieldByIndex(Atom, row, inbox_index).?.* = target.inbox;
    }

    fn fillRoundedRect(ctx: *roop.Context, x: f32, y: f32, w: f32, h: f32, radius: f32, color: Color) void {
        ctx.beginPath();
        if (radius > 0) {
            ctx.roundedRect(x, y, w, h, radius);
        } else {
            ctx.rect(x, y, w, h);
        }
        ctx.fillColor(color);
        ctx.fill();
    }

    /// Borders are filled, never stroked: an antialiased one-pixel stroke all but vanishes on
    /// straight edges and survives only around curves. A rounded border is the rect in the border
    /// color under a smaller fill, so a translucent fill shows the border color through it.
    fn emitRectBody(ctx: *roop.Context, x: f32, y: f32, size: math.Vec2f, radius: f32, fill: ?Color, border: ?Color) void {
        const edge = border orelse {
            if (fill) |color| fillRoundedRect(ctx, x, y, size.x, size.y, radius, color);
            return;
        };
        if (radius > 0 and fill != null) {
            fillRoundedRect(ctx, x, y, size.x, size.y, radius, edge);
            fillRoundedRect(ctx, x + 1, y + 1, @max(0, size.x - 2), @max(0, size.y - 2), @max(0, radius - 1), fill.?);
            return;
        }
        if (fill) |color| fillRoundedRect(ctx, x, y, size.x, size.y, 0, color);
        fillRoundedRect(ctx, x, y, size.x, 1, 0, edge);
        fillRoundedRect(ctx, x, y + size.y - 1, size.x, 1, 0, edge);
        fillRoundedRect(ctx, x, y, 1, size.y, 0, edge);
        fillRoundedRect(ctx, x + size.x - 1, y, 1, size.y, 0, edge);
    }

    fn emitNode(self: *Layout, n: *Node, ctx: *roop.Context) void {
        switch (n.kind) {
            .rect => {
                if (n.drawable) |drawable| {
                    const composite_op = ctx.composite_op;
                    ctx.save();
                    applyClip(ctx, n.clip);
                    const x = n.pos.x + n.rect.offset.x;
                    const y = n.pos.y + n.rect.offset.y;
                    const current = ctx.currentTransform();
                    const local = roop.transform.translation(x, y);
                    const translated = roop.transform.multiply(current, local);
                    ctx.setTransform(translated);
                    drawable.draw(drawable.object, n.size, ctx);
                    ctx.restore();
                    ctx.composite_op = composite_op;
                    return;
                }
                const is_hovered = if (self.cfg.hovered) |h|
                    h.atom == n.rect.id.atom and h.extra == n.rect.id.extra
                else
                    false;
                const fill = if (is_hovered) n.rect.bg_hover orelse n.rect.bg else n.rect.bg;
                if (fill != null or n.rect.border != null) {
                    const x = n.pos.x + n.rect.offset.x;
                    const y = n.pos.y + n.rect.offset.y;
                    ctx.save();

                    applyClip(ctx, n.clip);

                    if (n.rect.border_size > 0) {
                        if (n.rect.border) |band| {
                            ctx.beginPath();
                            ctx.roundedRect(
                                x - n.rect.border_size,
                                y - n.rect.border_size,
                                n.size.x + 2 * n.rect.border_size,
                                n.size.y + 2 * n.rect.border_size,
                                n.rect.corner_radius + n.rect.border_size,
                            );
                            ctx.fillColor(band);
                            ctx.fill();
                        }
                    }
                    emitRectBody(ctx, x, y, n.size, n.rect.corner_radius, fill, n.rect.border);
                    ctx.restore();
                }
            },
            .text => {
                ctx.save();
                applyClip(ctx, n.clip);
                ctx.fontFace(n.text_params.font);
                const color = n.text_params.color orelse Color{ .r = 1, .g = 1, .b = 1, .a = 1 };
                ctx.fillColor(color);
                // Each line's capitals centered in its line box, as the eye centers text.
                const baseline: f32 = ctx.fontBaseline(n.text_params.font, n.line_height);
                const cap_height: f32 = ctx.fontCapHeight(n.text_params.font);
                var y = n.pos.y;
                for (n.lines) |line| {
                    _ = ctx.text(n.pos.x - n.text_scroll_x, y + baseline, line.str);
                    if (n.text_params.strikethrough) {
                        const mid_y = y + baseline - cap_height * 0.5;
                        ctx.beginPath();
                        ctx.rect(n.pos.x - n.text_scroll_x, mid_y, line.width, 1.0);
                        ctx.fill();
                    }
                    y += n.line_height;
                }
                ctx.restore();
            },
        }
    }

    fn emitCursor(self: *Layout, entry: CursorEntry, ctx: *roop.Context) void {
        if (entry.node == NONE) return;
        const n = &self.nodes[entry.node];
        if (n.kind != .text) return;

        const off = @min(entry.byte, n.text_str.len);

        var line_idx: usize = if (n.lines.len > 0) n.lines.len - 1 else 0;
        var x_in_line: f32 = if (n.lines.len > 0)
            ctx.measureText(n.text_params.font, n.lines[n.lines.len - 1].str).w
        else
            0;
        for (n.lines, 0..) |line, i| {
            const s = @intFromPtr(line.str.ptr) - @intFromPtr(n.text_str.ptr);
            const e = s + line.str.len;
            if (off <= e) {
                line_idx = i;
                const local = off -| s;
                x_in_line = ctx.measureText(n.text_params.font, line.str[0..local]).w;
                break;
            }
        }

        const w: f32 = switch (entry.params.size.w) {
            .fixed => |v| v,
            else => default_caret_width,
        };
        const h: f32 = switch (entry.params.size.h) {
            .fixed => |v| v,
            else => n.line_height,
        };

        const caret_color = entry.params.bg orelse Color{ .r = 1, .g = 1, .b = 1, .a = 1 };
        ctx.save();

        applyClip(ctx, n.clip);
        ctx.beginPath();
        ctx.rect(
            n.pos.x + x_in_line - n.text_scroll_x,
            n.pos.y + @as(f32, @floatFromInt(line_idx)) * n.line_height,
            w,
            h,
        );
        if (entry.params.corner_radius > 0) {
            ctx.beginPath();
            ctx.roundedRect(
                n.pos.x + x_in_line - n.text_scroll_x,
                n.pos.y + @as(f32, @floatFromInt(line_idx)) * n.line_height,
                w,
                h,
                entry.params.corner_radius,
            );
        }
        ctx.fillColor(caret_color);
        ctx.fill();
        ctx.restore();
    }
};

const default_caret_width: f32 = 2.0;

fn cursorScrollOffset(cursor_x: f32, viewport_width: f32) f32 {
    const latest_visible_x = @max(0, viewport_width - default_caret_width);
    return @max(0, cursor_x - latest_visible_x);
}

const testing = std.testing;

test "a part's id is named by its element's atom and keeps its extra" {
    var memory: memory_mod.Memory = undefined;
    memory.init(std.testing.allocator);
    defer memory.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&memory);
    defer atoms.deinit();
    var frame_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frame_arena.deinit();
    var tree = try Tree.init(.{ .allocator = frame_arena.allocator() }, &atoms, 8);
    const field_id: ElementId = .{ .atom = atoms.intern("toolbar.filter"), .extra = 7 };
    const part = partId(&tree, field_id, "filter_clear");
    var name_buffer: [64]u8 = undefined;
    const expected_name = try std.fmt.bufPrint(&name_buffer, "button.{d}.filter_clear", .{@intFromEnum(field_id.atom)});
    const expected_atom = atoms.intern(expected_name);
    try std.testing.expectEqual(expected_atom, part.atom);
    try std.testing.expectEqual(@as(@TypeOf(part.extra), 7), part.extra);
}

test "capacity, scope, attachment, and UTF-8 validators cover boundary cases" {
    try validateBufferCapacity(max_roots - 1, max_roots, 1);
    try std.testing.expectError(error.CapacityExceeded, validateBufferCapacity(max_roots, max_roots, 1));
    try validateScopeDepth(max_scope_depth - 1, 1, max_scope_depth);
    try std.testing.expectError(error.ScopeTooDeep, validateScopeDepth(max_scope_depth, 1, max_scope_depth));
    try std.testing.expectError(error.ScopeTooDeep, validateScopeDepth(max_scope_depth + 1, 0, max_scope_depth));

    try validateAttachmentTarget(&.{.{ .rect = .{} }});
    try validateAttachmentTarget(&.{.{ .open_rect = .{} }});
    try std.testing.expectError(error.MissingAttachmentTarget, validateAttachmentTarget(&.{}));
    try std.testing.expectError(error.InvalidAttachmentTarget, validateAttachmentTarget(&.{.{ .text = .{ .str = "x", .params = .{} } }}));

    const utf8 = "café";
    try validateCursorOffset(utf8, 0);
    try validateCursorOffset(utf8, utf8.len);
    try std.testing.expectError(error.CursorNotAtUtf8Boundary, validateCursorOffset(utf8, 4));
    try std.testing.expectError(error.CursorOutOfRange, validateCursorOffset(utf8, utf8.len + 1));
    try std.testing.expectError(error.InvalidUtf8, validateCursorOffset(&.{0xff}, 0));

    var exact_depth: [2 * max_scope_depth]Element = undefined;
    for (0..max_scope_depth) |i| {
        exact_depth[i] = .{ .open_rect = .{} };
        exact_depth[max_scope_depth + i] = .close_rect;
    }
    try validateElementStream(&exact_depth, max_scope_depth);
    var over_depth: [2 * (max_scope_depth + 1)]Element = undefined;
    for (0..max_scope_depth + 1) |i| {
        over_depth[i] = .{ .open_rect = .{} };
        over_depth[max_scope_depth + 1 + i] = .close_rect;
    }
    try std.testing.expectError(error.ScopeTooDeep, validateElementStream(&over_depth, max_scope_depth));
    try std.testing.expectError(error.UnexpectedClose, validateElementStream(&.{.close_rect}, max_scope_depth));
    try std.testing.expectError(error.UnclosedScope, validateElementStream(&.{.{ .open_rect = .{} }}, max_scope_depth));
}

test "Tree borrows text through commit and offers checked UTF-8 cursor recording" {
    var memory: memory_mod.Memory = undefined;
    memory.init(testing.allocator);
    defer memory.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&memory);
    defer atoms.deinit();
    var frame_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame_arena.deinit();
    var tree = try Tree.init(.{ .allocator = frame_arena.allocator() }, &atoms, 8);

    var borrowed = [_]u8{ 'c', 'a', 'f', 0xc3, 0xa9 };
    try tree.textChecked(atoms.intern("label"), &borrowed, .{});
    borrowed[0] = 'C';
    try std.testing.expectEqualStrings("Café", tree.elements[0].text.str);
    try std.testing.expectError(error.CursorNotAtUtf8Boundary, tree.cursorChecked(atoms.intern("caret"), 4, .{}));
    try std.testing.expectError(error.CursorOutOfRange, tree.textChecked(atoms.intern("bad.scroll"), "x", .{ .scroll_cursor = 2 }));
    try tree.cursorChecked(atoms.intern("caret"), borrowed.len, .{});
    try tree.validateCommands();
    try std.testing.expect(tree.beginRect(atoms.intern("scope"), .{}));
    try std.testing.expectError(error.UnclosedScope, tree.validateCommands());
    tree.endRect();
    try tree.validateCommands();
    tree.reset();
    try std.testing.expectEqual(@as(usize, 0), tree.count);
}

test "config rejects non-finite viewport inputs" {
    try validateConfig(.{ .root_size = .{ .x = 0, .y = 0 } });
    try std.testing.expectError(error.InvalidRootSize, validateConfig(.{ .root_size = .{ .x = std.math.nan(f32), .y = 10 } }));
    try std.testing.expectError(error.NonFiniteTransform, validateConfig(.{ .root_size = .{ .x = 10, .y = 10 }, .origin = .{ .x = 0, .y = std.math.inf(f32) } }));
}

const test_click_tag: Atom = @enumFromInt(1);
const test_click_target: Target = .{ .tag = test_click_tag };
const test_tooltip = "Says what it does";

fn testPrefixWidth(text: []const u8, end: usize) f32 {
    var byte: usize = 0;
    var codepoints: usize = 0;
    while (byte < end) : (codepoints += 1) {
        const len = std.unicode.utf8ByteSequenceLength(text[byte]) catch unreachable;
        byte += len;
    }
    std.debug.assert(byte == end);
    return @floatFromInt(codepoints * 10);
}

test "cursor scrolling keeps a long UTF-8 text cursor visible" {
    const value = "A café has a very long description for the inspector";
    const width: f32 = 40;
    var storage: [128]u8 = undefined;
    var edit = TextEdit{ .buf = .{ .data = &storage, .len = 0 }, .cursor = 0 };
    _ = edit.insertSlice(value);

    edit.cursor = 0;
    try testing.expectEqual(@as(f32, 0), cursorScrollOffset(testPrefixWidth(edit.text(), edit.cursor), width));
    const accent = std.mem.indexOf(u8, edit.text(), "é").?;
    edit.cursor = accent;
    const before_accent = cursorScrollOffset(testPrefixWidth(edit.text(), edit.cursor), width);
    edit.cursor = accent + "é".len;
    const after_accent = cursorScrollOffset(testPrefixWidth(edit.text(), edit.cursor), width);
    try testing.expectEqual(@as(f32, 10), after_accent - before_accent);
    const accent_x = testPrefixWidth(edit.text(), edit.cursor) - after_accent;
    try testing.expect(accent_x >= 0 and accent_x + default_caret_width <= width);

    edit.cursor = std.mem.indexOf(u8, edit.text(), "long").?;
    const middle_x = testPrefixWidth(edit.text(), edit.cursor);
    const middle_scroll = cursorScrollOffset(middle_x, width);
    try testing.expect(middle_scroll > 0);
    try testing.expectEqual(width - default_caret_width, middle_x - middle_scroll);

    edit.cursor = edit.buf.len;
    const end_x = testPrefixWidth(edit.text(), edit.cursor);
    const end_scroll = cursorScrollOffset(end_x, width);
    try testing.expect(end_scroll > middle_scroll);
    try testing.expectEqual(width - default_caret_width, end_x - end_scroll);
    try testing.expectEqual(@as(f32, 0), cursorScrollOffset(0, width));
}

test "ordinary text leaves cursor-following scroll opt-in disabled" {
    try testing.expect((TextParams{}).scroll_cursor == null);
    try testing.expect((TextParams{ .scroll_cursor = 3 }).scroll_cursor != null);
}

test "records a balanced nested layout with siblings" {
    var kw: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try kw.init(&mem);
    defer kw.deinit();

    var frame_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame_arena.deinit();

    var tree = try Tree.init(.{ .allocator = frame_arena.allocator() }, &kw, 64);

    const surface = Color{ .r = 0.1, .g = 0.1, .b = 0.15, .a = 1 };
    const accent = Color{ .r = 0.49, .g = 0.42, .b = 0.97, .a = 1 };

    if (tree.beginRect(@as(Atom, @enumFromInt(1)), .{ .axis = .vertical, .bg = surface, .corner_radius = 6 })) {
        defer tree.endRect();

        if (tree.beginRect(@as(Atom, @enumFromInt(2)), .{ .axis = .horizontal, .padding = 10, .gap = 10 })) {
            defer tree.endRect();
            tree.text(@as(Atom, @enumFromInt(3)), "Design the asset pipeline", .{ .size_hint = .{ .w = .fill } });
            tree.rect(@as(Atom, @enumFromInt(4)), .{ .size = .{ .w = .{ .fixed = 16 }, .h = .{ .fixed = 16 } }, .bg = accent });
        }

        if (tree.beginRect(@as(Atom, @enumFromInt(5)), .{ .axis = .vertical, .padding = 12, .on_click = test_click_target })) {
            defer tree.endRect();
            tree.text(@as(Atom, @enumFromInt(6)), "body", .{});
        }
    }

    try testing.expectEqual(@as(usize, 9), tree.count);
    try testing.expectEqual(@as(usize, 0), tree.depth);
    try testing.expect(tree.elements[0] == .open_rect);
    try testing.expect(tree.elements[1] == .open_rect);
    try testing.expect(tree.elements[2] == .text);
    try testing.expect(tree.elements[3] == .rect);
    try testing.expect(tree.elements[4] == .close_rect);
    try testing.expect(tree.elements[8] == .close_rect);
}

test "collapsed scope skips its body and stays balanced" {
    var kw: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try kw.init(&mem);
    defer kw.deinit();

    var frame_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame_arena.deinit();

    var u = try Tree.init(.{ .allocator = frame_arena.allocator() }, &kw, 16);

    if (u.beginRect(@as(Atom, @enumFromInt(1)), .{ .collapsed = true })) {
        defer u.endRect();
        u.text(@as(Atom, @enumFromInt(2)), "never recorded", .{});
    }

    try testing.expectEqual(@as(usize, 2), u.count);
    try testing.expectEqual(@as(usize, 0), u.depth);
    try testing.expect(u.elements[0] == .open_rect);
    try testing.expect(u.elements[1] == .close_rect);
}

test "onClick patches on_click on the preceding rect or open_rect" {
    var kw: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try kw.init(&mem);
    defer kw.deinit();

    var frame_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame_arena.deinit();

    var u = try Tree.init(.{ .allocator = frame_arena.allocator() }, &kw, 16);

    u.rect(@as(Atom, @enumFromInt(1)), .{});
    u.onClick(u.target(no_inbox, @enumFromInt(42), @as(u8, 9)), .left);
    try testing.expectEqual(@as(Atom, @enumFromInt(42)), u.elements[0].rect.on_click.?.tag);
    try testing.expectEqualSlices(u8, &.{9}, u.elements[0].rect.on_click.?.user_data);

    u.reset();

    if (u.beginRect(@as(Atom, @enumFromInt(1)), .{})) {
        u.onClick(.{ .tag = @enumFromInt(7) }, .left);
        defer u.endRect();
    }
    try testing.expectEqual(@as(Atom, @enumFromInt(7)), u.elements[0].open_rect.on_click.?.tag);
}

test "reset clears recorded commands" {
    var kw: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try kw.init(&mem);
    defer kw.deinit();

    var frame_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame_arena.deinit();

    var u = try Tree.init(.{ .allocator = frame_arena.allocator() }, &kw, 8);

    u.rect(@as(Atom, @enumFromInt(1)), .{});
    u.rect(@as(Atom, @enumFromInt(2)), .{});
    try testing.expectEqual(@as(usize, 2), u.count);

    u.reset();
    try testing.expectEqual(@as(usize, 0), u.count);
    try testing.expectEqual(@as(usize, 0), u.depth);
}

test "positionAndEmit collects hit regions with config offset and rect offset" {
    var kw: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try kw.init(&mem);
    defer kw.deinit();

    var frame_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame_arena.deinit();

    var tree = try Tree.init(.{ .allocator = frame_arena.allocator() }, &kw, 16);

    tree.rect(@as(Atom, @enumFromInt(1)), .{
        .size = .{ .w = .{ .fixed = 100 }, .h = .{ .fixed = 50 } },
        .offset = .{ .x = 5, .y = 10 },
        .on_click = test_click_target,
    });
    tree.trackHover(test_tooltip);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var layout = Layout.build(.{ .allocator = arena.allocator() }, tree.elements[0..tree.count], .{
        .root_size = .{ .x = 800, .y = 600 },
        .offset = .{ .x = 200, .y = 150 },
        .depth = 7,
    });

    var schema: Table.Schema = undefined;
    try initHitRegionSchema(&schema, .{ .allocator = testing.allocator }, &kw);
    defer schema.deinit();

    var tables: Table.Registry = undefined;
    try tables.init(&mem, 1);
    defer tables.deinit();
    const table_handle = try tables.create(&schema, 16, kw.intern("hit_regions"), .transient);
    const table = tables.get(table_handle).?;

    layout.fitAlongAxis(.horizontal, undefined);
    layout.fitAlongAxis(.vertical, undefined);
    layout.positionAndEmit(table, undefined);

    try testing.expectEqual(@as(u32, 1), table.count());
    const handle: Table.RowHandle = .{ .row = 0, .generation = table.rowGeneration(0) };
    const row = table.getRow(handle, struct { pos: *math.Vec2f, size: *math.Vec2f, on_click: *Atom, hover: *u8, tooltip: []const u8, depth: *u32 }).?;
    try testing.expectEqual(@as(f32, 205), row.pos.x);
    try testing.expectEqual(@as(f32, 160), row.pos.y);
    try testing.expectEqual(@as(f32, 100), row.size.x);
    try testing.expectEqual(@as(f32, 50), row.size.y);
    try testing.expectEqual(@as(u32, 7), row.depth.*);
    try testing.expectEqual(test_click_tag, row.on_click.*);

    try testing.expectEqual(@as(u8, 1), row.hover.*);
    try testing.expectEqualStrings(test_tooltip, row.tooltip);
}

test "positionAndEmit names the inboxes its targets name, and only those" {
    var kw: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try kw.init(&mem);
    defer kw.deinit();

    var frame_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame_arena.deinit();
    var tree = try Tree.init(.{ .allocator = frame_arena.allocator() }, &kw, 16);

    const click_inbox: Atom = @enumFromInt(41);
    const scroll_inbox: Atom = @enumFromInt(42);
    const scroll: Target = .{ .tag = test_click_tag, .inbox = scroll_inbox };
    if (tree.beginRect(@as(Atom, @enumFromInt(1)), .{ .size = .{ .w = .{ .fixed = 100 }, .h = .{ .fixed = 50 } }, .on_scroll = scroll })) {
        defer tree.endRect();
        tree.rect(@as(Atom, @enumFromInt(2)), .{ .size = .{ .w = .{ .fixed = 10 }, .h = .{ .fixed = 10 } } });
        tree.onClick(.{ .tag = test_click_tag, .inbox = click_inbox }, .left);
        tree.onClick(tree.target(no_inbox, @enumFromInt(3), @as(u32, 0x0102_0304)), .right);
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var layout = Layout.build(.{ .allocator = arena.allocator() }, tree.elements[0..tree.count], .{ .root_size = .{ .x = 800, .y = 600 } });

    var schema: Table.Schema = undefined;
    try initHitRegionSchema(&schema, .{ .allocator = testing.allocator }, &kw);
    defer schema.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&mem, 1);
    defer tables.deinit();
    const table_handle = try tables.create(&schema, 16, kw.intern("hit_regions"), .transient);
    const table = tables.get(table_handle).?;

    layout.fitAlongAxis(.horizontal, undefined);
    layout.fitAlongAxis(.vertical, undefined);
    layout.positionAndEmit(table, undefined);

    try testing.expectEqual(@as(u32, 2), table.count());
    const outer: Table.RowHandle = .{ .row = 0, .generation = table.rowGeneration(0) };
    const inner: Table.RowHandle = .{ .row = 1, .generation = table.rowGeneration(1) };
    try testing.expectEqual(scroll_inbox, table.getField(Atom, outer, "on_scroll_inbox").?.*);
    try testing.expectEqual(no_inbox, table.getField(Atom, outer, "on_click_inbox").?.*);
    // The child takes its parent's wheel, inbox and all.
    try testing.expectEqual(scroll_inbox, table.getField(Atom, inner, "on_scroll_inbox").?.*);
    try testing.expectEqual(click_inbox, table.getField(Atom, inner, "on_click_inbox").?.*);
    try testing.expectEqual(no_inbox, table.getField(Atom, inner, "on_right_click_inbox").?.*);
    try testing.expectEqual(@as(Atom, @enumFromInt(3)), table.getField(Atom, inner, "on_right_click").?.*);
    const right_user_data = table.getField(Table.Bytes, inner, "on_right_click_user_data").?.*;
    try testing.expectEqual(@as(u32, 0x0102_0304), std.mem.bytesToValue(u32, table.bytesOf(right_user_data)));
}

test "hit regions without hover opt-in are not hoverable" {
    var kw: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try kw.init(&mem);
    defer kw.deinit();

    var frame_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame_arena.deinit();

    var tree = try Tree.init(.{ .allocator = frame_arena.allocator() }, &kw, 16);

    tree.rect(@as(Atom, @enumFromInt(1)), .{
        .size = .{ .w = .{ .fixed = 100 }, .h = .{ .fixed = 50 } },
        .on_click = test_click_target,
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var layout = Layout.build(.{ .allocator = arena.allocator() }, tree.elements[0..tree.count], .{
        .root_size = .{ .x = 800, .y = 600 },
    });

    var schema: Table.Schema = undefined;
    try initHitRegionSchema(&schema, .{ .allocator = testing.allocator }, &kw);
    defer schema.deinit();

    var tables: Table.Registry = undefined;
    try tables.init(&mem, 1);
    defer tables.deinit();
    const table_handle = try tables.create(&schema, 16, kw.intern("hit_regions"), .transient);
    const table = tables.get(table_handle).?;

    layout.fitAlongAxis(.horizontal, undefined);
    layout.fitAlongAxis(.vertical, undefined);
    layout.positionAndEmit(table, undefined);

    const handle: Table.RowHandle = .{ .row = 0, .generation = table.rowGeneration(0) };
    const row = table.getRow(handle, struct { hover: *u8, tooltip: []const u8 }).?;

    try testing.expectEqual(@as(u8, 0), row.hover.*);
    try testing.expectEqual(@as(usize, 0), row.tooltip.len);
}

test "rects without clip_content leave descendants unclipped" {
    var kw: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try kw.init(&mem);
    defer kw.deinit();

    var frame_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame_arena.deinit();

    var tree = try Tree.init(.{ .allocator = frame_arena.allocator() }, &kw, 16);

    if (tree.beginRect(@as(Atom, @enumFromInt(1)), .{ .size = .{ .w = .{ .fixed = 100 }, .h = .{ .fixed = 60 } }, .padding = 10 })) {
        defer tree.endRect();
        tree.rect(@as(Atom, @enumFromInt(2)), .{ .size = .{ .w = .{ .fixed = 200 }, .h = .{ .fixed = 200 } } });
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var layout = Layout.build(.{ .allocator = arena.allocator() }, tree.elements[0..tree.count], .{ .root_size = .{ .x = 800, .y = 600 } });
    layout.fitAlongAxis(.horizontal, undefined);
    layout.growShrinkAlongAxis(.horizontal);
    layout.fitAlongAxis(.vertical, undefined);
    layout.growShrinkAlongAxis(.vertical);
    layout.assignPositions();

    try testing.expect(layout.nodes[1].clip == null);
    try testing.expect(layout.nodes[2].clip == null);
}

test "clip_content clips children to the padded content box" {
    var kw: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try kw.init(&mem);
    defer kw.deinit();

    var frame_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame_arena.deinit();

    var tree = try Tree.init(.{ .allocator = frame_arena.allocator() }, &kw, 16);

    if (tree.beginRect(@as(Atom, @enumFromInt(1)), .{ .size = .{ .w = .{ .fixed = 100 }, .h = .{ .fixed = 60 } }, .padding = 10, .clip_content = true })) {
        defer tree.endRect();
        tree.rect(@as(Atom, @enumFromInt(2)), .{ .size = .{ .w = .{ .fixed = 200 }, .h = .{ .fixed = 200 } } });
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var layout = Layout.build(.{ .allocator = arena.allocator() }, tree.elements[0..tree.count], .{ .root_size = .{ .x = 800, .y = 600 } });
    layout.fitAlongAxis(.horizontal, undefined);
    layout.growShrinkAlongAxis(.horizontal);
    layout.fitAlongAxis(.vertical, undefined);
    layout.growShrinkAlongAxis(.vertical);
    layout.assignPositions();

    try testing.expect(layout.nodes[1].clip == null);
    const clip = layout.nodes[2].clip.?;
    try testing.expectEqual(@as(f32, 10), clip.x);
    try testing.expectEqual(@as(f32, 10), clip.y);
    try testing.expectEqual(@as(f32, 80), clip.w);
    try testing.expectEqual(@as(f32, 40), clip.h);
}

test "padding_y takes the place of padding above and below, in the clip, the hug and the place of a child" {
    var kw: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try kw.init(&mem);
    defer kw.deinit();

    var frame_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame_arena.deinit();

    var tree = try Tree.init(.{ .allocator = frame_arena.allocator() }, &kw, 16);

    // A clipped cell a line tall, centring a child taller than its height less `padding`.
    if (tree.beginRect(@as(Atom, @enumFromInt(1)), .{ .axis = .horizontal, .cross_align = .center, .size = .{ .w = .{ .fixed = 100 }, .h = .{ .fixed = 28 } }, .padding = 8, .padding_y = 0, .clip_content = true })) {
        defer tree.endRect();
        tree.rect(@as(Atom, @enumFromInt(2)), .{ .size = .{ .w = .{ .fixed = 200 }, .h = .{ .fixed = 18 } } });
    }
    // A rect that hugs its child: `padding` at its ends, `padding_y` above and below.
    if (tree.beginRect(@as(Atom, @enumFromInt(3)), .{ .size = .{ .w = .hug, .h = .hug }, .padding = 6, .padding_y = 2 })) {
        defer tree.endRect();
        tree.rect(@as(Atom, @enumFromInt(4)), .{ .size = .{ .w = .{ .fixed = 40 }, .h = .{ .fixed = 10 } } });
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var layout = Layout.build(.{ .allocator = arena.allocator() }, tree.elements[0..tree.count], .{ .root_size = .{ .x = 800, .y = 600 } });
    layout.fitAlongAxis(.horizontal, undefined);
    layout.growShrinkAlongAxis(.horizontal);
    layout.fitAlongAxis(.vertical, undefined);
    layout.growShrinkAlongAxis(.vertical);
    layout.assignPositions();

    const clip = layout.nodes[2].clip.?;
    try testing.expectEqual(@as(f32, 8), clip.x);
    try testing.expectEqual(@as(f32, 0), clip.y);
    try testing.expectEqual(@as(f32, 84), clip.w);
    try testing.expectEqual(@as(f32, 28), clip.h);
    // Centred in the whole height: (28 - 18) / 2.
    try testing.expectEqual(@as(f32, 5), layout.nodes[2].pos.y);
    try testing.expectEqual(@as(f32, 8), layout.nodes[2].pos.x);
    try testing.expectEqual(@as(f32, 52), layout.nodes[3].size.x);
    try testing.expectEqual(@as(f32, 14), layout.nodes[3].size.y);
    try testing.expectEqual(layout.nodes[3].pos.x + 6, layout.nodes[4].pos.x);
    try testing.expectEqual(layout.nodes[3].pos.y + 2, layout.nodes[4].pos.y);
}

test "cross axis alignment centers fixed controls without changing their target size" {
    var atoms: Atom.Registry = undefined;
    var memory: memory_mod.Memory = undefined;
    memory.init(testing.allocator);
    defer memory.deinit();
    try atoms.init(&memory);
    defer atoms.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const scratch = memory_mod.Scratch{ .allocator = arena.allocator() };
    var tree = try Tree.init(scratch, &atoms, 16);
    const alignments = [_]CrossAlign{ .start, .center, .end };
    for (alignments, 0..) |alignment, i| {
        const parent = ElementId{ .atom = atoms.intern("row"), .extra = i };
        const child = ElementId{ .atom = atoms.intern("control"), .extra = i };
        if (tree.beginRect(parent, .{ .axis = .horizontal, .cross_align = alignment, .size = .{ .w = .{ .fixed = 100 }, .h = .{ .fixed = 40 } }, .padding = 4 })) {
            defer tree.endRect();
            tree.rect(child, .{ .size = .{ .w = .{ .fixed = 20 }, .h = .{ .fixed = 16 } } });
        }
    }
    var layout = Layout.build(scratch, tree.elements[0..tree.count], .{ .root_size = .{ .x = 100, .y = 40 } });
    layout.fitAlongAxis(.horizontal, undefined);
    layout.growShrinkAlongAxis(.horizontal);
    layout.fitAlongAxis(.vertical, undefined);
    layout.growShrinkAlongAxis(.vertical);
    layout.assignPositions();
    const positions = [_]f32{ 4, 12, 20 };
    for (positions, 0..) |position, i| {
        const node = layout.nodes[i * 2 + 2];
        try testing.expectEqual(position, node.pos.y);
        try testing.expectEqual(@as(f32, 4), node.pos.x);
        try testing.expectEqual(@as(f32, 20), node.size.x);
        try testing.expectEqual(@as(f32, 16), node.size.y);
    }
}

test "scroll offset moves descendants while preserving viewport and clipped hit regions" {
    var atoms: Atom.Registry = undefined;
    var memory: memory_mod.Memory = undefined;
    memory.init(testing.allocator);
    defer memory.deinit();
    try atoms.init(&memory);
    defer atoms.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const scratch = memory_mod.Scratch{ .allocator = arena.allocator() };
    var tree = try Tree.init(scratch, &atoms, 16);
    if (tree.beginRect("viewport", .{ .size = .{ .w = .{ .fixed = 56 }, .h = .{ .fixed = 80 } }, .clip_content = true, .scroll = .vertical, .scroll_offset = 20 })) {
        defer tree.endRect();
        if (tree.beginRect("content", .{ .size = .{ .w = .fill, .h = .{ .fixed = 144 } }, .padding = 8, .gap = 4 })) {
            defer tree.endRect();
            for (0..3) |index| {
                const id = ElementId{ .atom = atoms.intern("button"), .extra = index };
                tree.rect(id, .{ .size = .{ .w = .{ .fixed = 40 }, .h = .{ .fixed = 40 } }, .on_click = test_click_target });
            }
        }
    }
    var layout = Layout.build(scratch, tree.elements[0..tree.count], .{ .root_size = .{ .x = 56, .y = 80 }, .offset = .{ .x = 100, .y = 200 } });
    var schema: Table.Schema = undefined;
    try initHitRegionSchema(&schema, scratch, &atoms);
    defer schema.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&memory, 1);
    defer tables.deinit();
    const name = atoms.intern("hit_regions");
    const handle = try tables.create(&schema, 8, name, .transient);
    const hits = tables.get(handle).?;
    layout.fitAlongAxis(.horizontal, undefined);
    layout.growShrinkAlongAxis(.horizontal);
    layout.fitAlongAxis(.vertical, undefined);
    layout.growShrinkAlongAxis(.vertical);
    layout.positionAndEmit(hits, undefined);
    try testing.expectEqual(@as(f32, 0), layout.nodes[1].pos.y);
    try testing.expectEqual(@as(f32, -20), layout.nodes[2].pos.y);
    try testing.expectEqual(@as(u32, 3), hits.count());
    var rows = hits.query(struct { pos: *math.Vec2f, size: *math.Vec2f });
    const positions = [_]f32{ 200, 232, 276 };
    const heights = [_]f32{ 28, 40, 4 };
    for (positions, heights) |position, height| {
        const row = rows.next().?;
        try testing.expectEqual(@as(f32, 108), row.view.pos.x);
        try testing.expectEqual(position, row.view.pos.y);
        try testing.expectEqual(height, row.view.size.y);
    }
}

test "committedPlace finds the place a commit recorded for an element, and nothing for one it did not" {
    var atoms: Atom.Registry = undefined;
    var memory: memory_mod.Memory = undefined;
    memory.init(testing.allocator);
    defer memory.deinit();
    try atoms.init(&memory);
    defer atoms.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const scratch = memory_mod.Scratch{ .allocator = arena.allocator() };
    var tree = try Tree.init(scratch, &atoms, 16);
    const body: ElementId = .{ .atom = atoms.intern("body"), .extra = 7 };
    const spacer: ElementId = .{ .atom = atoms.intern("spacer") };
    if (tree.beginRect("page", .{ .axis = .vertical, .size = .{ .w = .{ .fixed = 300 }, .h = .{ .fixed = 200 } } })) {
        defer tree.endRect();
        tree.rect(spacer, .{ .size = .{ .w = .fill, .h = .{ .fixed = 40 } } });
        tree.rect(body, .{ .size = .{ .w = .fill, .h = .fill }, .on_scroll = test_click_target });
    }
    var layout = Layout.build(scratch, tree.elements[0..tree.count], .{ .root_size = .{ .x = 300, .y = 200 }, .offset = .{ .x = 10, .y = 20 } });
    var schema: Table.Schema = undefined;
    try initHitRegionSchema(&schema, scratch, &atoms);
    defer schema.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&memory, 1);
    defer tables.deinit();
    const handle = try tables.create(&schema, 8, atoms.intern("hit_regions"), .transient);
    const hits = tables.get(handle).?;
    try testing.expectEqual(@as(?Place, null), committedPlace(hits, body));
    layout.fitAlongAxis(.horizontal, undefined);
    layout.growShrinkAlongAxis(.horizontal);
    layout.fitAlongAxis(.vertical, undefined);
    layout.growShrinkAlongAxis(.vertical);
    layout.positionAndEmit(hits, undefined);
    const place = committedPlace(hits, body).?;
    try testing.expectEqual(math.Vec2f{ .x = 10, .y = 60 }, place.pos);
    try testing.expectEqual(math.Vec2f{ .x = 300, .y = 160 }, place.size);
    // An element that takes no click or wheel has no region, and no place recorded.
    try testing.expectEqual(@as(?Place, null), committedPlace(hits, spacer));
}

test "nested clip rects intersect" {
    var kw: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try kw.init(&mem);
    defer kw.deinit();

    var frame_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame_arena.deinit();

    var tree = try Tree.init(.{ .allocator = frame_arena.allocator() }, &kw, 16);

    if (tree.beginRect(@as(Atom, @enumFromInt(1)), .{ .axis = .horizontal, .size = .{ .w = .{ .fixed = 100 }, .h = .{ .fixed = 100 } }, .clip_content = true })) {
        defer tree.endRect();
        tree.rect(@as(Atom, @enumFromInt(2)), .{ .size = .{ .w = .{ .fixed = 50 }, .h = .{ .fixed = 100 } } });
        if (tree.beginRect(@as(Atom, @enumFromInt(3)), .{ .size = .{ .w = .{ .fixed = 100 }, .h = .{ .fixed = 100 } }, .padding = 10, .clip_content = true })) {
            defer tree.endRect();
            tree.rect(@as(Atom, @enumFromInt(4)), .{ .size = .{ .w = .{ .fixed = 10 }, .h = .{ .fixed = 10 } } });
        }
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var layout = Layout.build(.{ .allocator = arena.allocator() }, tree.elements[0..tree.count], .{ .root_size = .{ .x = 800, .y = 600 } });
    layout.fitAlongAxis(.horizontal, undefined);
    layout.growShrinkAlongAxis(.horizontal);
    layout.fitAlongAxis(.vertical, undefined);
    layout.growShrinkAlongAxis(.vertical);
    layout.assignPositions();

    const outer = layout.nodes[2].clip.?;
    try testing.expectEqual(@as(f32, 0), outer.x);
    try testing.expectEqual(@as(f32, 0), outer.y);
    try testing.expectEqual(@as(f32, 100), outer.w);
    try testing.expectEqual(@as(f32, 100), outer.h);

    const inner = layout.nodes[4].clip.?;
    try testing.expectEqual(@as(f32, 60), inner.x);
    try testing.expectEqual(@as(f32, 10), inner.y);
    try testing.expectEqual(@as(f32, 40), inner.w);
    try testing.expectEqual(@as(f32, 80), inner.h);
}

test "rounded container clips propagate concentric corner radius to children" {
    var kw: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try kw.init(&mem);
    defer kw.deinit();

    var frame_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame_arena.deinit();

    var tree = try Tree.init(.{ .allocator = frame_arena.allocator() }, &kw, 16);

    if (tree.beginRect(@as(Atom, @enumFromInt(1)), .{
        .size = .{ .w = .{ .fixed = 100 }, .h = .{ .fixed = 100 } },
        .corner_radius = 8,
        .padding = 2,
        .clip_content = true,
    })) {
        defer tree.endRect();

        tree.rect(@as(Atom, @enumFromInt(2)), .{ .size = .{ .w = .fill, .h = .{ .fixed = 32 } } });

        if (tree.beginRect(@as(Atom, @enumFromInt(3)), .{
            .size = .{ .w = .fill, .h = .{ .fixed = 50 } },
            .clip_content = true,
        })) {
            defer tree.endRect();
            tree.rect(@as(Atom, @enumFromInt(4)), .{ .size = .{ .w = .{ .fixed = 10 }, .h = .{ .fixed = 10 } } });
        }
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var layout = Layout.build(.{ .allocator = arena.allocator() }, tree.elements[0..tree.count], .{ .root_size = .{ .x = 800, .y = 600 } });
    layout.fitAlongAxis(.horizontal, undefined);
    layout.growShrinkAlongAxis(.horizontal);
    layout.fitAlongAxis(.vertical, undefined);
    layout.growShrinkAlongAxis(.vertical);
    layout.assignPositions();

    const titlebar = layout.nodes[2].clip.?;
    try testing.expectEqual(@as(f32, 6), titlebar.radius);
    try testing.expectEqual(@as(f32, 2), titlebar.x);

    const inner_child = layout.nodes[4].clip.?;
    try testing.expectEqual(@as(f32, 0), inner_child.radius);
}

test "sibling clip scopes isolate their children" {
    var kw: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try kw.init(&mem);
    defer kw.deinit();

    var frame_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame_arena.deinit();

    var tree = try Tree.init(.{ .allocator = frame_arena.allocator() }, &kw, 16);

    if (tree.beginRect(@as(Atom, @enumFromInt(1)), .{ .axis = .horizontal, .size = .{ .w = .{ .fixed = 200 }, .h = .{ .fixed = 100 } } })) {
        defer tree.endRect();
        if (tree.beginRect(@as(Atom, @enumFromInt(2)), .{ .size = .{ .w = .{ .fixed = 100 }, .h = .{ .fixed = 100 } }, .padding = 5, .clip_content = true })) {
            defer tree.endRect();
            tree.rect(@as(Atom, @enumFromInt(3)), .{ .size = .{ .w = .{ .fixed = 200 }, .h = .{ .fixed = 10 } } });
        }
        if (tree.beginRect(@as(Atom, @enumFromInt(4)), .{ .size = .{ .w = .{ .fixed = 100 }, .h = .{ .fixed = 100 } }, .padding = 5, .clip_content = true })) {
            defer tree.endRect();
            tree.rect(@as(Atom, @enumFromInt(5)), .{ .size = .{ .w = .{ .fixed = 200 }, .h = .{ .fixed = 10 } } });
        }
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var layout = Layout.build(.{ .allocator = arena.allocator() }, tree.elements[0..tree.count], .{ .root_size = .{ .x = 800, .y = 600 } });
    layout.fitAlongAxis(.horizontal, undefined);
    layout.growShrinkAlongAxis(.horizontal);
    layout.fitAlongAxis(.vertical, undefined);
    layout.growShrinkAlongAxis(.vertical);
    layout.assignPositions();

    const a = layout.nodes[3].clip.?;
    const b = layout.nodes[5].clip.?;
    try testing.expectEqual(@as(f32, 5), a.x);
    try testing.expectEqual(@as(f32, 105), b.x);

    try testing.expect(a.x + a.w <= 100);
    try testing.expect(b.x + b.w <= 200);
}

test "text nodes inherit their scope's clip for caret rendering" {
    var kw: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try kw.init(&mem);
    defer kw.deinit();

    var frame_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame_arena.deinit();

    var tree = try Tree.init(.{ .allocator = frame_arena.allocator() }, &kw, 16);

    if (tree.beginRect(@as(Atom, @enumFromInt(1)), .{ .size = .{ .w = .{ .fixed = 100 }, .h = .{ .fixed = 40 } }, .padding = 4, .clip_content = true })) {
        defer tree.endRect();
        tree.text(@as(Atom, @enumFromInt(2)), "value", .{});
        tree.cursor(@as(Atom, @enumFromInt(3)), 2, .{ .bg = Color{ .r = 0, .g = 0, .b = 0, .a = 1 } });
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var layout = Layout.build(.{ .allocator = arena.allocator() }, tree.elements[0..tree.count], .{ .root_size = .{ .x = 800, .y = 600 } });

    layout.nodes[1].size = .{ .x = 100, .y = 40 };
    layout.assignPositions();

    try testing.expectEqual(@as(u32, 2), layout.cursors.items[0].node);
    const clip = layout.nodes[2].clip.?;
    try testing.expectEqual(@as(f32, 4), clip.x);
    try testing.expectEqual(@as(f32, 4), clip.y);
    try testing.expectEqual(@as(f32, 92), clip.w);
    try testing.expectEqual(@as(f32, 32), clip.h);
}

test "inheritedClip intersects its own clip with the padded content box" {
    var n = Node{ .kind = .rect, .rect = .{ .padding = 5, .clip_content = true } };
    n.pos = .{ .x = 10, .y = 20 };
    n.size = .{ .x = 100, .y = 60 };

    const clip = inheritedClip(&n).?;
    try testing.expectEqual(@as(f32, 15), clip.x);
    try testing.expectEqual(@as(f32, 25), clip.y);
    try testing.expectEqual(@as(f32, 90), clip.w);
    try testing.expectEqual(@as(f32, 50), clip.h);

    n.clip = .{ .x = 0, .y = 0, .w = 50, .h = 100 };
    const narrowed = inheritedClip(&n).?;
    try testing.expectEqual(@as(f32, 15), narrowed.x);
    try testing.expectEqual(@as(f32, 35), narrowed.w);

    n.size = .{ .x = 4, .y = 60 };
    n.clip = null;
    const empty = inheritedClip(&n).?;
    try testing.expectEqual(@as(f32, 0), empty.w);
}

test "clippedRegion intersects with the clip and drops empty intersections" {
    const full = clippedRegion(.{ .x = 0, .y = 0 }, .{ .x = 100, .y = 50 }, null).?;
    try testing.expectEqual(@as(f32, 100), full.size.x);

    const partial = clippedRegion(.{ .x = 50, .y = 0 }, .{ .x = 100, .y = 50 }, .{ .x = 0, .y = 0, .w = 100, .h = 50 }).?;
    try testing.expectEqual(@as(f32, 50), partial.pos.x);
    try testing.expectEqual(@as(f32, 50), partial.size.x);

    try testing.expect(clippedRegion(.{ .x = 200, .y = 0 }, .{ .x = 10, .y = 10 }, .{ .x = 0, .y = 0, .w = 100, .h = 50 }) == null);
}

test "layout origin shifts clipped paint geometry and hit regions together" {
    var kw: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try kw.init(&mem);
    defer kw.deinit();
    var frame_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame_arena.deinit();
    var tree = try Tree.init(.{ .allocator = frame_arena.allocator() }, &kw, 16);
    if (tree.beginRect(@as(Atom, @enumFromInt(1)), .{
        .size = .{ .w = .{ .fixed = 100 }, .h = .{ .fixed = 60 } },
        .padding = 10,
        .clip_content = true,
    })) {
        defer tree.endRect();
        if (tree.beginRect(@as(Atom, @enumFromInt(2)), .{ .size = .{ .w = .{ .fixed = 200 }, .h = .{ .fixed = 200 } } })) {
            defer tree.endRect();
            tree.onClick(.{ .tag = @enumFromInt(7) }, .left);
        }
    }

    var schema: Table.Schema = undefined;
    try initHitRegionSchema(&schema, .{ .allocator = testing.allocator }, &kw);
    defer schema.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&mem, 1);
    defer tables.deinit();
    const hits_handle = try tables.create(&schema, 4, kw.intern("origin.hits"), .transient);
    const hits = tables.get(hits_handle).?;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var layout = Layout.build(.{ .allocator = arena.allocator() }, tree.elements[0..tree.count], .{
        .root_size = .{ .x = 200, .y = 200 },
        .origin = .{ .x = 50, .y = 70 },
    });
    layout.fitAlongAxis(.horizontal, undefined);
    layout.growShrinkAlongAxis(.horizontal);
    layout.fitAlongAxis(.vertical, undefined);
    layout.growShrinkAlongAxis(.vertical);
    layout.positionAndEmit(hits, undefined);

    try testing.expectEqual(@as(f32, 60), layout.nodes[2].clip.?.x);
    try testing.expectEqual(@as(f32, 80), layout.nodes[2].clip.?.y);
    const hit = hits.getRow(.{ .row = 0, .generation = hits.rowGeneration(0) }, struct { pos: *math.Vec2f, size: *math.Vec2f }).?;
    try testing.expectEqual(@as(f32, 60), hit.pos.x);
    try testing.expectEqual(@as(f32, 80), hit.pos.y);
    try testing.expectEqual(@as(f32, 80), hit.size.x);
    try testing.expectEqual(@as(f32, 40), hit.size.y);
}

test "buttons inside a clipped horizontal content pane keep their hit regions" {
    var kw: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try kw.init(&mem);
    defer kw.deinit();
    var frame_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame_arena.deinit();
    var tree = try Tree.init(.{ .allocator = frame_arena.allocator() }, &kw, 256);

    if (tree.beginRect(@as(Atom, @enumFromInt(1)), .{ .axis = .vertical, .size = .{ .w = .{ .fixed = 720 }, .h = .{ .fixed = 480 } }, .clip_content = true })) {
        defer tree.endRect();
        if (tree.beginRect(@as(Atom, @enumFromInt(2)), .{ .axis = .horizontal, .size = .{ .w = .fill, .h = .{ .fixed = 414 } }, .clip_content = true })) {
            defer tree.endRect();
            tree.rect(@as(Atom, @enumFromInt(3)), .{ .size = .{ .w = .{ .fixed = 400 }, .h = .fill } });
            if (tree.beginRect(@as(Atom, @enumFromInt(4)), .{ .axis = .vertical, .size = .{ .w = .{ .fixed = 320 }, .h = .fill }, .padding = 8, .clip_content = true })) {
                defer tree.endRect();

                if (tree.beginRect(@as(Atom, @enumFromInt(5)), .{ .size = .{ .w = .{ .fixed = 74 }, .h = .fill }, .padding = 6, .clip_content = true, .on_click = test_click_target })) {
                    defer tree.endRect();
                    tree.rect(@as(Atom, @enumFromInt(6)), .{ .size = .{ .w = .fill, .h = .{ .fixed = 20 } } });
                }
            }
        }
    }
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var schema: Table.Schema = undefined;
    try initHitRegionSchema(&schema, .{ .allocator = testing.allocator }, &kw);
    defer schema.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&mem, 1);
    defer tables.deinit();
    const table_handle = try tables.create(&schema, 16, kw.intern("drawer_hits"), .transient);
    const table = tables.get(table_handle).?;

    var layout = Layout.build(.{ .allocator = arena.allocator() }, tree.elements[0..tree.count], .{ .root_size = .{ .x = 720, .y = 480 } });
    layout.fitAlongAxis(.horizontal, undefined);
    layout.growShrinkAlongAxis(.horizontal);
    layout.fitAlongAxis(.vertical, undefined);
    layout.growShrinkAlongAxis(.vertical);
    layout.positionAndEmit(table, undefined);

    var q = table.query(struct { pos: *math.Vec2f, size: *math.Vec2f });
    var found = false;
    while (q.next()) |item| {
        if (item.view.pos.x == 408 and item.view.pos.y == 8) found = true;
    }
    try testing.expect(found);
}

test "custom borrows mutable and const drawables until commit and replaces rect paint" {
    const Mutable = struct {
        calls: usize = 0,
        size: math.Vec2f = .{ .x = 0, .y = 0 },
        fn draw(self: *@This(), size: math.Vec2f, _: *roop.Context) void {
            self.calls += 1;
            self.size = size;
        }
    };
    const Const = struct {
        calls: *usize,
        fn draw(self: *const @This(), _: math.Vec2f, _: *roop.Context) void {
            self.calls.* += 1;
        }
    };
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&mem);
    defer atoms.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var tree = try Tree.init(.{ .allocator = arena.allocator() }, &atoms, 8);
    var mutable = Mutable{};
    var const_calls: usize = 0;
    const immutable = Const{ .calls = &const_calls };
    const color = Color{ .r = 1, .g = 0, .b = 0, .a = 1 };
    tree.custom(@as(Atom, @enumFromInt(1)), &mutable, .{
        .size = .{ .w = .fill, .h = .{ .fixed = 25 } },
        .bg = color,
        .bg_hover = color,
        .border = color,
        .border_size = 2,
    });
    tree.onClick(.{ .tag = @enumFromInt(3) }, .left);
    tree.trackHover("four");
    tree.custom(@as(Atom, @enumFromInt(2)), &immutable, .{});
    try tree.validateCommands();
    try testing.expectEqual(@as(usize, 0), mutable.calls);
    try testing.expectEqual(@as(usize, 0), const_calls);
    try testing.expectEqual(@as(Atom, @enumFromInt(3)), tree.elements[0].custom.params.on_click.?.tag);
    try testing.expect(tree.elements[0].custom.params.hover);
    try testing.expectEqualStrings("four", tree.elements[0].custom.params.tooltip);

    var layout = Layout.build(.{ .allocator = arena.allocator() }, tree.elements[0..tree.count], .{
        .root_size = .{ .x = 100, .y = 80 },
    });
    layout.fitAlongAxis(.horizontal, undefined);
    layout.fitAlongAxis(.vertical, undefined);
    layout.assignPositions();
    try testing.expectEqual(@as(usize, 0), mutable.calls);
    try testing.expectEqual(@as(usize, 0), const_calls);

    var renderer: roop.Renderer = .{};
    const ctx_allocator = arena.allocator();
    var ctx = try roop.Context.initWithoutTarget(&renderer, &ctx_allocator);
    ctx.beginFrame(100, 80, 1, .wrap(&ctx_allocator));
    // Deeper than the save stack's former 32 entries.
    for (0..40) |_| ctx.save();
    ctx.translate(7, 9);
    const original_transform = ctx.currentTransform();
    const original_count = ctx.states.items.len;
    tree.commit(.{ .root_size = .{ .x = 100, .y = 80 } }, &ctx, null, no_inbox);
    try testing.expectEqual(original_count, ctx.states.items.len);
    try testing.expectEqual(original_transform, ctx.currentTransform());
    try testing.expectEqual(@as(usize, 1), mutable.calls);
    try testing.expectEqual(@as(usize, 1), const_calls);
    try testing.expectEqual(@as(f32, 100), mutable.size.x);
    try testing.expectEqual(@as(f32, 25), mutable.size.y);
    try testing.expectEqual(@as(usize, 0), ctx.calls.items.len);
}

// Solid CPU paths need retained buffers, but no render target or GPU initialization.
fn customTestContext(allocator: *const std.mem.Allocator, renderer: *roop.Renderer) roop.Context {
    var ctx = roop.Context.initWithoutTarget(renderer, allocator) catch @panic("OOM");
    ctx.beginFrame(200, 200, 1, .wrap(allocator));
    return ctx;
}

test "custom layout matches rect through fitting growth shrink and positioning" {
    const Drawable = struct {
        calls: usize = 0,
        fn draw(self: *@This(), _: math.Vec2f, _: *roop.Context) void {
            self.calls += 1;
        }
    };
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&mem);
    defer atoms.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const scratch = memory_mod.Scratch{ .allocator = arena.allocator() };
    var tree = try Tree.init(scratch, &atoms, 20);
    var drawable = Drawable{};
    const id: Atom = @enumFromInt(1);
    _ = tree.beginRect(id, .{ .axis = .horizontal, .size = .{ .w = .{ .fixed = 90 }, .h = .{ .fixed = 80 } }, .padding = 5, .gap = 3 });
    _ = tree.beginRect(id, .{ .axis = .vertical, .size = .{ .w = .fill, .h = .fill }, .padding = 4, .gap = 2 });
    tree.custom(id, &drawable, .{ .size = .{ .w = .fill, .h = .fill }, .padding = 30, .offset = .{ .x = 2, .y = 3 }, .collapsed = true });
    tree.custom(id, &drawable, .{ .size = .{ .w = .hug, .h = .hug }, .padding = 7 });
    tree.custom(id, &drawable, .{ .size = .{ .w = .{ .fixed = 12 }, .h = .{ .fixed = 10 } } });
    tree.endRect();
    tree.custom(id, &drawable, .{ .size = .{ .w = .fill, .h = .fill }, .padding = 2 });
    tree.endRect();
    try tree.validateCommands();
    const cfg = Config{ .root_size = .{ .x = 90, .y = 80 } };
    var custom_layout = Layout.build(scratch, tree.elements[0..tree.count], cfg);
    for (tree.elements[0..tree.count]) |*element| {
        if (element.* == .custom) {
            const params = element.custom.params;
            element.* = .{ .rect = params };
        }
    }
    var rect_layout = Layout.build(scratch, tree.elements[0..tree.count], cfg);
    for ([_]*Layout{ &custom_layout, &rect_layout }) |layout| {
        layout.fitAlongAxis(.horizontal, undefined);
        layout.growShrinkAlongAxis(.horizontal);
        layout.fitAlongAxis(.vertical, undefined);
        layout.growShrinkAlongAxis(.vertical);
        layout.assignPositions();
    }
    try testing.expectEqual(@as(usize, 0), drawable.calls);
    try testing.expectEqual(rect_layout.count, custom_layout.count);
    for (custom_layout.nodes[0..custom_layout.count], rect_layout.nodes[0..rect_layout.count]) |custom_node, rect_node| {
        try testing.expectEqual(rect_node.pos, custom_node.pos);
        try testing.expectEqual(rect_node.size, custom_node.size);
        try testing.expectEqual(rect_node.rect.offset, custom_node.rect.offset);
    }
    // The first nested fill shrinks from its 60-pixel padded intrinsic height.
    try testing.expect(custom_layout.nodes[3].size.y < 60);
    // The horizontal fill siblings grow beyond their intrinsic padded widths.
    try testing.expect(custom_layout.nodes[6].size.x > 4);
}

test "equal fill splits space evenly and main align centers what is left" {
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&mem);
    defer atoms.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const scratch = memory_mod.Scratch{ .allocator = arena.allocator() };
    var tree = try Tree.init(scratch, &atoms, 16);
    const id: Atom = @enumFromInt(1);
    _ = tree.beginRect(id, .{ .axis = .vertical, .size = .{ .w = .{ .fixed = 210 }, .h = .{ .fixed = 80 } } });
    _ = tree.beginRect(id, .{ .axis = .horizontal, .equal_fill = true, .gap = 10, .size = .{ .w = .fill, .h = .{ .fixed = 20 } } });
    // This child's content would otherwise keep it wider than its sibling.
    _ = tree.beginRect(id, .{ .size = .{ .w = .fill, .h = .fill }, .clip_content = true });
    tree.rect(id, .{ .size = .{ .w = .{ .fixed = 150 }, .h = .{ .fixed = 4 } } });
    tree.endRect();
    tree.rect(id, .{ .size = .{ .w = .fill, .h = .fill } });
    tree.endRect();
    _ = tree.beginRect(id, .{ .axis = .horizontal, .main_align = .center, .size = .{ .w = .fill, .h = .{ .fixed = 20 } } });
    tree.rect(id, .{ .size = .{ .w = .{ .fixed = 40 }, .h = .{ .fixed = 4 } } });
    tree.endRect();
    tree.endRect();
    try tree.validateCommands();
    var layout = Layout.build(scratch, tree.elements[0..tree.count], .{ .root_size = .{ .x = 210, .y = 80 } });
    layout.fitAlongAxis(.horizontal, undefined);
    layout.growShrinkAlongAxis(.horizontal);
    layout.fitAlongAxis(.vertical, undefined);
    layout.growShrinkAlongAxis(.vertical);
    layout.assignPositions();
    // Nodes in build order: root, column, row, wide, wide content, narrow, centered, its content.
    try testing.expectApproxEqAbs(@as(f32, 100), layout.nodes[3].size.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 100), layout.nodes[5].size.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 110), layout.nodes[5].pos.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 85), layout.nodes[7].pos.x, 0.01);
}

test "custom paint order borrowed updates reset and caller state isolation" {
    const Probe = struct {
        calls: usize = 0,
        seen_calls: [2]usize = undefined,
        sizes: [2]math.Vec2f = undefined,
        transforms: [2]roop.Transform2D = undefined,
        seen_alpha: [2]f32 = undefined,
        value: f32 = 0,
        seen_value: [2]f32 = undefined,
        fn draw(self: *@This(), size: math.Vec2f, ctx: *roop.Context) void {
            const i = self.calls;
            self.seen_calls[i] = ctx.calls.items.len;
            self.sizes[i] = size;
            self.transforms[i] = ctx.currentTransform();
            self.seen_alpha[i] = ctx.states.items[ctx.states.items.len - 1].alpha;
            self.seen_value[i] = self.value;
            self.calls += 1;
            ctx.fillColor(.{ .r = 0, .g = 1, .b = 0, .a = 1 });
            ctx.strokeColor(.{ .r = 0, .g = 0, .b = 1, .a = 1 });
            ctx.globalAlpha(0.2);
            ctx.translate(9, 11);
            ctx.scissor(0, 0, 1, 1, 0);
            ctx.compositeOperation(.copy);
            ctx.beginPath();
            ctx.rect(0, 0, 3, 4);
            ctx.fill();
        }
    };
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&mem);
    defer atoms.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var renderer: roop.Renderer = .{};
    const ctx_allocator = arena.allocator();
    var ctx = customTestContext(&ctx_allocator, &renderer);
    // Nonuniform scale followed by a quarter turn and translation.
    const transform: roop.Transform2D = .{ 0, 2, -3, 0, 5, 7 };
    ctx.setTransform(transform);
    ctx.globalAlpha(0.7);
    const initial = ctx.states.items[0];
    var tree = try Tree.init(.{ .allocator = arena.allocator() }, &atoms, 10);
    var probe = Probe{};
    const id: Atom = @enumFromInt(1);
    _ = tree.beginRect(id, .{ .axis = .horizontal, .size = .{ .w = .{ .fixed = 100 }, .h = .{ .fixed = 40 } }, .padding = 2, .gap = 3 });
    tree.rect(id, .{ .size = .{ .w = .{ .fixed = 10 }, .h = .{ .fixed = 10 } }, .bg = .{ .r = 1, .g = 0, .b = 0, .a = 1 } });
    tree.custom(id, &probe, .{ .size = .{ .w = .{ .fixed = 20 }, .h = .{ .fixed = 12 } }, .offset = .{ .x = 4, .y = 6 } });
    tree.rect(id, .{ .size = .{ .w = .{ .fixed = 8 }, .h = .{ .fixed = 8 } }, .bg = .{ .r = 1, .g = 0, .b = 0, .a = 1 } });
    tree.endRect();
    const cfg = Config{ .root_size = .{ .x = 100, .y = 40 }, .origin = .{ .x = 10, .y = 20 }, .offset = .{ .x = 100, .y = 200 } };
    tree.commit(cfg, &ctx, null, no_inbox);
    try testing.expectEqual(@as(usize, 1), probe.seen_calls[0]);
    try testing.expectEqual(@as(usize, 3), ctx.calls.items.len);
    try testing.expectEqual(math.Vec2f{ .x = 20, .y = 12 }, probe.sizes[0]);
    const local = roop.transform.translation(29, 28);
    const expected = roop.transform.multiply(transform, local);
    for (expected, probe.transforms[0]) |a, b| try testing.expectApproxEqAbs(a, b, 0.0001);
    try testing.expectEqual(@as(f32, -79), probe.transforms[0][4]);
    try testing.expectEqual(@as(f32, 65), probe.transforms[0][5]);

    const sibling_call = ctx.calls.items[2];
    const sibling_uniform = ctx.uniforms.items[sibling_call.uniform_offset];
    try testing.expectEqual([4]f32{ 0.7, 0, 0, 0.7 }, sibling_uniform.innerCol);
    try testing.expectEqual([2]f32{ 1e5, 1e5 }, sibling_uniform.scissorExt);
    // Locate the sibling's fan through its draw call and inspect its transformed points.
    var found_corner = false;
    for (ctx.shape_args.items) |shape| {
        if (shape.kind != 0 or shape.outVertexOffset != sibling_call.vertex_offset) continue;
        const points = ctx.gpu_points.items[shape.pointFirst..][0..shape.pointCount];
        for (points) |point| {
            if (point.x == -61 and point.y == 103) found_corner = true;
        }
    }
    try testing.expect(found_corner);
    try testing.expectEqual(@as(usize, 1), ctx.states.items.len);
    try testing.expectEqual(initial, ctx.states.items[0]);
    try testing.expectEqual(roop.CompositeOperation.source_over, ctx.composite_op);
    probe.value = 42;
    tree.commit(cfg, &ctx, null, no_inbox);
    try testing.expectEqual(@as(f32, 42), probe.seen_value[1]);
    try testing.expectEqual(@as(usize, 4), probe.seen_calls[1]);
    try testing.expectEqual(@as(f32, 0.7), probe.seen_alpha[1]);
    try testing.expectEqual(@as(usize, 6), ctx.calls.items.len);
    tree.reset();
    tree.commit(cfg, &ctx, null, no_inbox);
    try testing.expectEqual(@as(usize, 2), probe.calls);
}

test "custom inherited clip and hit regions preserve rect semantics" {
    const Probe = struct {
        count: usize = 0,
        sizes: [3]math.Vec2f = undefined,
        scissor_extents: [3][2]f32 = undefined,
        scissor_radii: [3]f32 = undefined,
        scissor_transforms: [3]roop.Transform2D = undefined,
        fn draw(self: *@This(), size: math.Vec2f, ctx: *roop.Context) void {
            const state = ctx.states.items[ctx.states.items.len - 1];
            self.sizes[self.count] = size;
            self.scissor_extents[self.count] = state.scissor_extent;
            self.scissor_radii[self.count] = state.scissor_radius;
            self.scissor_transforms[self.count] = state.scissor_xform;
            self.count += 1;
        }
    };
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&mem);
    defer atoms.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const scratch = memory_mod.Scratch{ .allocator = arena.allocator() };
    var tree = try Tree.init(scratch, &atoms, 12);
    var probe = Probe{};
    const id: Atom = @enumFromInt(1);
    _ = tree.beginRect(id, .{ .size = .{ .w = .{ .fixed = 80 }, .h = .{ .fixed = 80 } }, .padding = 10, .corner_radius = 12, .clip_content = true });
    _ = tree.beginRect(id, .{ .size = .{ .w = .{ .fixed = 50 }, .h = .{ .fixed = 50 } }, .padding = 5, .corner_radius = 8, .clip_content = true });
    tree.custom(.{ id, @as(u64, 99) }, &probe, .{ .size = .{ .w = .{ .fixed = 50 }, .h = .{ .fixed = 30 } }, .padding = 4, .clip_content = true, .offset = .{ .x = -10, .y = 0 } });
    tree.onClick(.{ .tag = @enumFromInt(11) }, .left);
    tree.trackHover("twelve");
    tree.custom(id, &probe, .{ .size = .{ .w = .{ .fixed = 10 }, .h = .{ .fixed = 10 } }, .offset = .{ .x = -100, .y = 0 }, .on_click = test_click_target });
    tree.endRect();
    tree.custom(id, &probe, .{ .size = .{ .w = .{ .fixed = 10 }, .h = .{ .fixed = 10 } } });
    tree.endRect();
    var schema: Table.Schema = undefined;
    try initHitRegionSchema(&schema, .{ .allocator = testing.allocator }, &atoms);
    defer schema.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&mem, 1);
    defer tables.deinit();
    const handle = try tables.create(&schema, 16, atoms.intern("custom_hits"), .transient);
    const hits = tables.get(handle).?;
    var renderer: roop.Renderer = .{};
    const ctx_allocator = arena.allocator();
    var ctx = customTestContext(&ctx_allocator, &renderer);
    ctx.scissor(0, 0, 55, 100, 9);
    const caller_state = ctx.states.items[0];
    tree.commit(.{ .root_size = .{ .x = 100, .y = 100 }, .origin = .{ .x = 10, .y = 20 }, .offset = .{ .x = 100, .y = 200 }, .depth = 7 }, &ctx, hits, no_inbox);
    try testing.expectEqual(@as(usize, 3), probe.count);
    try testing.expectEqual(math.Vec2f{ .x = 50, .y = 30 }, probe.sizes[0]);
    try testing.expectEqual([2]f32{ 15, 20 }, probe.scissor_extents[0]);
    try testing.expectEqual(@as(f32, 2), probe.scissor_radii[0]);
    try testing.expectEqual(@as(f32, -40), probe.scissor_transforms[0][4]);
    try testing.expectEqual(@as(f32, -55), probe.scissor_transforms[0][5]);
    try testing.expectEqual([2]f32{ 17.5, 30 }, probe.scissor_extents[2]);
    try testing.expectEqual(@as(f32, 2), probe.scissor_radii[2]);
    try testing.expectEqual(caller_state, ctx.states.items[0]);
    try testing.expectEqual(@as(u32, 1), hits.count());
    const row_handle: Table.RowHandle = .{ .row = 0, .generation = hits.rowGeneration(0) };
    const row = hits.getRow(row_handle, struct { pos: *math.Vec2f, size: *math.Vec2f, id: *[16]u8, depth: *u32, on_click: *Atom, hover: *u8, tooltip: []const u8 }).?;
    try testing.expectEqual(math.Vec2f{ .x = 125, .y = 235 }, row.pos.*);
    try testing.expectEqual(math.Vec2f{ .x = 40, .y = 30 }, row.size.*);
    const expected_id = ElementId{ .atom = id, .extra = 99 };
    try testing.expectEqual(std.mem.toBytes(expected_id), row.id.*);
    try testing.expectEqual(@as(u32, 7), row.depth.*);
    try testing.expectEqual(@as(Atom, @enumFromInt(11)), row.on_click.*);
    try testing.expectEqual(@as(u8, 1), row.hover.*);
    try testing.expectEqualStrings("twelve", row.tooltip);
}

/// Caller-owned storage for a `TextEdit`.
pub const TextBuffer = struct {
    /// The whole storage: its length is the most bytes the text can hold.
    data: []u8,
    /// How many bytes of `data` hold text.
    len: usize,
};

/// A line of UTF-8 text edited in place in a fixed buffer, with a cursor: the state behind a text
/// field, which a caller keeps and draws with `Tree.text` and `Tree.cursor`. It allocates nothing.
/// `cursor` must stay at most `buf.len` and on a codepoint boundary, as every method leaves it.
/// Words, for the word motions and kills, are runs of ASCII letters, digits, `_` and any non-ASCII
/// codepoint.
pub const TextEdit = struct {
    /// The text and its storage.
    buf: TextBuffer,
    /// The byte offset edits happen at, from 0 to `buf.len`.
    cursor: usize,

    /// The text, borrowed from the buffer: valid until the next edit.
    pub fn text(self: *const TextEdit) []const u8 {
        return self.buf.data[0..self.buf.len];
    }

    /// Inserts `codepoint` at the cursor and moves the cursor past it. Does nothing when it is not
    /// a Unicode scalar value or its encoding does not fit in the buffer.
    pub fn insert(self: *TextEdit, codepoint: u32) void {
        if (codepoint > std.math.maxInt(u21)) return;
        var encoded: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(@intCast(codepoint), &encoded) catch return;
        _ = self.insertSlice(encoded[0..len]);
    }

    /// Inserts as much of `bytes` at the cursor as is whole, valid codepoints that fit in the
    /// buffer, stopping at the first that is not, and moves the cursor past what went in. Returns
    /// how many bytes went in.
    pub fn insertSlice(self: *TextEdit, bytes: []const u8) usize {
        var accepted: usize = 0;
        while (accepted < bytes.len) {
            const cp_len = std.unicode.utf8ByteSequenceLength(bytes[accepted]) catch break;
            if (accepted + cp_len > bytes.len) break;
            if (!std.unicode.utf8ValidateSlice(bytes[accepted .. accepted + cp_len])) break;
            if (self.buf.len + accepted + cp_len > self.buf.data.len) break;
            accepted += cp_len;
        }
        if (accepted == 0) return 0;
        std.mem.copyBackwards(u8, self.buf.data[self.cursor + accepted .. self.buf.len + accepted], self.buf.data[self.cursor..self.buf.len]);
        @memcpy(self.buf.data[self.cursor .. self.cursor + accepted], bytes[0..accepted]);
        self.buf.len += accepted;
        self.cursor += accepted;
        return accepted;
    }

    /// Deletes the codepoint before the cursor; nothing at the start.
    pub fn backspace(self: *TextEdit) void {
        if (self.cursor == 0) return;
        const start = previousBoundary(self.text(), self.cursor);
        std.mem.copyForwards(u8, self.buf.data[start .. self.buf.len - (self.cursor - start)], self.buf.data[self.cursor..self.buf.len]);
        self.buf.len -= self.cursor - start;
        self.cursor = start;
    }

    /// Deletes the codepoint at the cursor; nothing at the end.
    pub fn delete(self: *TextEdit) void {
        if (self.cursor >= self.buf.len) return;
        const end = nextBoundary(self.text(), self.cursor);
        std.mem.copyForwards(u8, self.buf.data[self.cursor .. self.buf.len - (end - self.cursor)], self.buf.data[end..self.buf.len]);
        self.buf.len -= end - self.cursor;
    }

    /// Moves the cursor back one codepoint, stopping at the start.
    pub fn moveCursorLeft(self: *TextEdit) void {
        self.cursor = previousBoundary(self.text(), self.cursor);
    }

    /// Moves the cursor forward one codepoint, stopping at the end.
    pub fn moveCursorRight(self: *TextEdit) void {
        self.cursor = nextBoundary(self.text(), self.cursor);
    }

    /// Moves the cursor to the end of the next word: past any non-word characters, then past the
    /// word.
    pub fn moveCursorWordForward(self: *TextEdit) void {
        const bytes = self.text();
        while (self.cursor < bytes.len and !isWordChar(codepointAt(bytes, self.cursor)))
            self.cursor = nextBoundary(bytes, self.cursor);
        while (self.cursor < bytes.len and isWordChar(codepointAt(bytes, self.cursor)))
            self.cursor = nextBoundary(bytes, self.cursor);
    }

    /// Moves the cursor to the start of the previous word: back over any non-word characters, then
    /// over the word.
    pub fn moveCursorWordBackward(self: *TextEdit) void {
        const bytes = self.text();
        while (self.cursor > 0 and !isWordChar(codepointBefore(bytes, self.cursor)))
            self.cursor = previousBoundary(bytes, self.cursor);
        while (self.cursor > 0 and isWordChar(codepointBefore(bytes, self.cursor)))
            self.cursor = previousBoundary(bytes, self.cursor);
    }

    fn killRange(self: *TextEdit, start: usize, end: usize) void {
        if (end <= start) return;
        std.mem.copyForwards(u8, self.buf.data[start .. self.buf.len - (end - start)], self.buf.data[end..self.buf.len]);
        self.buf.len -= end - start;
        self.cursor = start;
    }

    /// Deletes from the cursor to the end of the text. The deleted text is not kept.
    pub fn killToEnd(self: *TextEdit) void {
        self.killRange(self.cursor, self.buf.len);
    }

    /// Deletes from the cursor to where `moveCursorWordForward` would take it.
    pub fn killWordForward(self: *TextEdit) void {
        const start = self.cursor;
        self.moveCursorWordForward();
        self.killRange(start, self.cursor);
    }

    /// Deletes from where `moveCursorWordBackward` would take the cursor up to it, leaving the
    /// cursor at the start of the gap.
    pub fn killWordBackward(self: *TextEdit) void {
        const end = self.cursor;
        self.moveCursorWordBackward();
        self.killRange(self.cursor, end);
    }

    fn previousBoundary(bytes: []const u8, cursor: usize) usize {
        if (cursor == 0) return 0;
        var i = cursor - 1;
        while (i > 0 and bytes[i] & 0xc0 == 0x80) i -= 1;
        return i;
    }

    fn nextBoundary(bytes: []const u8, cursor: usize) usize {
        if (cursor >= bytes.len) return bytes.len;
        const len = std.unicode.utf8ByteSequenceLength(bytes[cursor]) catch return @min(cursor + 1, bytes.len);
        return @min(cursor + len, bytes.len);
    }
};

fn isWordChar(cp: u21) bool {
    if (cp >= 0x80) return true;
    return std.ascii.isAlphanumeric(@intCast(cp)) or cp == '_';
}

fn codepointAt(bytes: []const u8, cursor: usize) u21 {
    const len = std.unicode.utf8ByteSequenceLength(bytes[cursor]) catch return 0xfffd;
    if (cursor + len > bytes.len) return 0xfffd;
    return std.unicode.utf8Decode(bytes[cursor .. cursor + len]) catch 0xfffd;
}

fn codepointBefore(bytes: []const u8, cursor: usize) u21 {
    var i = cursor - 1;
    while (i > 0 and bytes[i] & 0xc0 == 0x80) i -= 1;
    return codepointAt(bytes, i);
}

test "TextEdit UTF-8 insertion and codepoint operations" {
    var storage: [16]u8 = undefined;
    var edit = TextEdit{ .buf = .{ .data = &storage, .len = 0 }, .cursor = 0 };
    edit.insert('a');
    edit.insert(0x20ac);
    edit.insert(0x1f642);
    try testing.expectEqualStrings("a€🙂", edit.text());
    edit.moveCursorLeft();
    edit.backspace();
    try testing.expectEqualStrings("a🙂", edit.text());
    edit.delete();
    try testing.expectEqualStrings("a", edit.text());
}

test "TextEdit slice insertion truncates only at codepoint boundaries" {
    var storage: [5]u8 = undefined;
    var edit = TextEdit{ .buf = .{ .data = &storage, .len = 0 }, .cursor = 0 };
    try testing.expectEqual(@as(usize, 4), edit.insertSlice("ééé"));
    try testing.expectEqualStrings("éé", edit.text());
    try testing.expectEqual(@as(usize, 0), edit.insertSlice(&.{0xff}));
    try testing.expect(std.unicode.utf8ValidateSlice(edit.text()));
}

test "TextEdit emacs word motion" {
    var storage: [32]u8 = undefined;
    var edit = TextEdit{ .buf = .{ .data = &storage, .len = 0 }, .cursor = 0 };
    _ = edit.insertSlice("foo_bar, two words");

    edit.cursor = 0;
    edit.moveCursorWordForward();
    try testing.expectEqual(@as(usize, 7), edit.cursor);
    edit.cursor = 2;
    edit.moveCursorWordForward();
    try testing.expectEqual(@as(usize, 7), edit.cursor);
    edit.cursor = 7;
    edit.moveCursorWordForward();
    try testing.expectEqual(@as(usize, 12), edit.cursor);
    edit.moveCursorWordForward();
    try testing.expectEqual(@as(usize, 18), edit.cursor);
    edit.moveCursorWordForward();
    try testing.expectEqual(@as(usize, 18), edit.cursor);

    edit.moveCursorWordBackward();
    try testing.expectEqual(@as(usize, 13), edit.cursor);
    edit.cursor = 15;
    edit.moveCursorWordBackward();
    try testing.expectEqual(@as(usize, 13), edit.cursor);
    edit.cursor = 12;
    edit.moveCursorWordBackward();
    try testing.expectEqual(@as(usize, 9), edit.cursor);
    edit.moveCursorWordBackward();
    try testing.expectEqual(@as(usize, 0), edit.cursor);
    edit.moveCursorWordBackward();
    try testing.expectEqual(@as(usize, 0), edit.cursor);
}

test "TextEdit word motion keeps multi-byte codepoints glued" {
    var storage: [32]u8 = undefined;
    var edit = TextEdit{ .buf = .{ .data = &storage, .len = 0 }, .cursor = 0 };
    _ = edit.insertSlice("héllo wörld");
    edit.cursor = 1;
    edit.moveCursorWordForward();
    try testing.expectEqual(@as(usize, 6), edit.cursor);
    edit.moveCursorWordBackward();
    try testing.expectEqual(@as(usize, 0), edit.cursor);
}

test "TextEdit kill helpers" {
    var storage: [32]u8 = undefined;
    var edit = TextEdit{ .buf = .{ .data = &storage, .len = 0 }, .cursor = 0 };
    _ = edit.insertSlice("hello brave world");
    edit.cursor = 6;
    edit.killToEnd();
    try testing.expectEqualStrings("hello ", edit.text());
    try testing.expectEqual(@as(usize, 6), edit.cursor);

    _ = edit.insertSlice("brave world");
    edit.cursor = 6;
    edit.killWordForward();
    try testing.expectEqualStrings("hello  world", edit.text());

    edit.cursor = 12;
    edit.killWordBackward();
    try testing.expectEqualStrings("hello  ", edit.text());
    try testing.expectEqual(@as(usize, 7), edit.cursor);

    edit.cursor = 0;
    edit.killWordBackward();
    try testing.expectEqualStrings("hello  ", edit.text());
    edit.cursor = 7;
    edit.killWordForward();
    try testing.expectEqualStrings("hello  ", edit.text());
}

test "chart drawable custom commit uses live data and reports errors" {
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&mem);
    defer atoms.deinit();
    var schema: Table.Schema = undefined;
    try schema.init(testing.allocator, &atoms, 2);
    defer schema.deinit();
    schema.addField("x", f32, .text_field);
    schema.addField("y", i32, .text_field);
    var tables: Table.Registry = undefined;
    try tables.init(&mem, 2);
    defer tables.deinit();
    const handle = try tables.create(&schema, 2, atoms.intern("chart.custom"), .durable);
    const table = tables.get(handle).?;
    const first_row = table.insert(.{ .x = @as(f32, 0), .y = @as(i32, 0) });
    _ = table.insert(.{ .x = @as(f32, 1), .y = @as(i32, 10) });
    var fields = .{ atoms.intern("x"), atoms.intern("y") };
    var line_chart = chart.drawable(.line, table, fields, .{ .padding = 0 });
    var bar_chart = chart.drawable(.bar, table, fields, .{ .padding = 0 });
    var scatter_chart = chart.drawable(.scatter, table, fields, .{ .padding = 0 });
    fields[1] = atoms.intern("unknown");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var renderer: roop.Renderer = .{};
    const ctx_allocator = arena.allocator();
    var ctx = customTestContext(&ctx_allocator, &renderer);
    const state = ctx.states.items[0];
    var tree = try Tree.init(.{ .allocator = arena.allocator() }, &atoms, 8);
    const id = atoms.intern("chart.ui");
    _ = tree.beginRect(id, .{ .axis = .horizontal, .size = .{ .w = .{ .fixed = 120 }, .h = .{ .fixed = 40 } } });
    const params = RectParams{ .size = .{ .w = .{ .fixed = 40 }, .h = .{ .fixed = 40 } } };
    tree.custom(.{ id, @as(u64, 1) }, &line_chart, params);
    tree.custom(.{ id, @as(u64, 2) }, &bar_chart, params);
    tree.custom(.{ id, @as(u64, 3) }, &scatter_chart, params);
    tree.endRect();
    const config = Config{ .root_size = .{ .x = 120, .y = 40 }, .origin = .{ .x = 10, .y = 20 } };
    tree.commit(config, &ctx, null, no_inbox);
    try testing.expectEqual(@as(usize, 5), ctx.calls.items.len);
    try testing.expectEqual(@as(?chart.Error, null), line_chart.last_error);
    try testing.expectEqual(@as(?chart.Error, null), bar_chart.last_error);
    try testing.expectEqual(@as(?chart.Error, null), scatter_chart.last_error);
    try testing.expectApproxEqAbs(@as(f32, 10), ctx.gpu_points.items[0].x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 60), ctx.gpu_points.items[0].y, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 50), ctx.gpu_points.items[1].x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 20), ctx.gpu_points.items[1].y, 0.01);
    try testing.expect(ctx.gpu_points.items[2].x >= 50 and ctx.gpu_points.items[2].x <= 90);
    try testing.expect(ctx.gpu_points.items[10].x >= 90 and ctx.gpu_points.items[10].x <= 130);
    try testing.expectEqualDeep(state, ctx.states.items[0]);

    try table.writeFieldSingle(i32, first_row, "y", 20);
    const next_point = ctx.gpu_points.items.len;
    tree.commit(config, &ctx, null, no_inbox);
    try testing.expectApproxEqAbs(@as(f32, 10), ctx.gpu_points.items[next_point].x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 20), ctx.gpu_points.items[next_point].y, 0.01);
    line_chart.options.padding = 30;
    tree.commit(config, &ctx, null, no_inbox);
    try testing.expectEqual(@as(?chart.Error, error.InvalidBounds), line_chart.last_error);
    line_chart.options.padding = 0;
    tree.commit(config, &ctx, null, no_inbox);
    try testing.expectEqual(@as(?chart.Error, null), line_chart.last_error);
    // The slice backing storage and drawable both survive all commits.
    var runtime_storage = [_]Atom{ atoms.intern("x"), atoms.intern("y") };
    const runtime_fields: []const Atom = &runtime_storage;
    var runtime_chart = chart.drawable(.line, table, runtime_fields, .{ .padding = 0 });
    _ = tree.beginRect(id, .{ .size = .{ .w = .{ .fixed = 40 }, .h = .{ .fixed = 40 } } });
    tree.custom(.{ id, @as(u64, 4) }, &runtime_chart, params);
    tree.endRect();
    tree.commit(config, &ctx, null, no_inbox);
    try testing.expectEqual(@as(?chart.Error, null), runtime_chart.last_error);
    runtime_storage[1] = atoms.intern("unknown");
    tree.commit(config, &ctx, null, no_inbox);
    try testing.expectEqual(@as(?chart.Error, error.UnknownField), runtime_chart.last_error);
    runtime_storage[1] = atoms.intern("y");
    tree.commit(config, &ctx, null, no_inbox);
    try testing.expectEqual(@as(?chart.Error, null), runtime_chart.last_error);
}

test "text that is not UTF-8 is shown with replacement characters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const displayed = try displayText(arena.allocator(), "caf\xe9 caf\xc3\xa9 \xc3");
    try std.testing.expectEqualStrings("caf\u{FFFD} caf\xc3\xa9 \u{FFFD}", displayed);
    const valid = "caf\xc3\xa9";
    try std.testing.expect((try displayText(arena.allocator(), valid)).ptr == valid.ptr);
}
