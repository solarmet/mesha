//! A one-line filter: the text a list is narrowed to, typed while the field has focus.
//!
//! The owner keeps the field's state in its own table (see `Field`): its text in a text cell,
//! whether it has the focus in a byte. It knows where the field sits, so it focuses the field
//! on a press inside it and blurs it on a press outside. While the field is focused and its
//! root has the keyboard, the owner subscribes with `subscribe` (or pushes `text_subscription`
//! and `key_subscription` itself) and routes the typing to `typeText` and keys to `pressKey`:
//!
//!     switch (message.tag) {
//!         text_tag => if (filter_field.typeText(field, typed)) scrollToTop(),
//!         key_tag => if (filter_field.pressKey(field, pressed) == .edited) scrollToTop(),
//!         clear_tag => field.clear(),
//!     }
//!
//! and draws it each frame with `render`, in a `Style` from its theme or `default_style`.
//!
//! Typing appends; Backspace takes the last character back and Control+Backspace all of them;
//! Escape empties the field and lets go; Enter lets go and keeps the text, which the owner may
//! also take as "pick the first match". The caret stays at the end: a filter is short and
//! retyped, not edited in place. Nothing here keeps anything between calls; `typeText` and
//! `pressKey` write only the owner's cells they are given.
const std = @import("std");
const Atom = @import("../core/atom.zig").Atom;
const memory_mod = @import("../core/memory.zig");
const sequencer = @import("../core/sequencer.zig");
const Table = @import("../core/table.zig");
const input = @import("../systems/input.zig");
const roop = @import("../systems/roop.zig");
const marks = @import("marks.zig");
const ui = @import("ui.zig");

/// A filter's state, as views of the owner's table fields: its text is a string cell of
/// `table`, the table the owner's row is in. The pointers are the owner's, valid while the row
/// stays where it is: a view lasts one call, made again from the row each time.
pub const Field = struct {
    /// The owner's table, which holds the text's payload.
    table: *Table,
    /// The text cell of the owner's row: what the list is narrowed to.
    text: *Table.String,
    /// The owner's byte that says whether the field has the focus: nonzero while it does.
    focused: *u8,

    /// The filter's text, in the table until the text next changes.
    pub fn query(field: Field) []const u8 {
        return field.table.textOf(field.text.*);
    }

    /// Whether the field has the focus and takes what is typed.
    pub fn isFocused(field: Field) bool {
        return field.focused.* != 0;
    }

    /// Gives the field the focus, or takes it away.
    pub fn setFocused(field: Field, focused: bool) void {
        field.focused.* = @intFromBool(focused);
    }

    /// Empties the text.
    pub fn clear(field: Field) void {
        field.text.* = .{};
    }
};

/// Whether `name` holds `query`, ignoring case. An empty query matches everything.
pub fn matches(query: []const u8, name: []const u8) bool {
    if (query.len == 0) return true;
    return std.ascii.indexOfIgnoreCase(name, query) != null;
}

/// What a focused field hears of typing: text typed without Control, Alt or Super, so the
/// shortcuts that hold them stay the keymap's. Its tag is the caller's to set.
pub const text_subscription: input.Subscription = .{ .text_input = .{ .modifiers = .{ .control = .forbidden, .alt = .forbidden, .super = .forbidden } } };
/// What a focused field hears of keys: every key, for `pressKey` to pick the ones it answers.
/// Its tag is the caller's to set.
pub const key_subscription: input.Subscription = .{ .key_input = .{} };

/// Pushes `text_subscription` and `key_subscription` through `subscriber`, typing arriving
/// under `text_tag` and keys under `key_tag`, each carrying `user_data` back. `subscriber` is
/// any value with `push(input.Subscription, sequencer.UserData)`: an `input.Subscriber`, or a
/// plugin's own subscriber that writes a run's subscriptions table. Call it on each pass the
/// field is focused and its root has the keyboard.
pub fn subscribe(subscriber: anytype, text_tag: Atom, key_tag: Atom, user_data: sequencer.UserData) void {
    var text = text_subscription;
    text.text_input.tag = text_tag;
    var key = key_subscription;
    key.key_input.tag = key_tag;
    subscriber.push(text, user_data);
    subscriber.push(key, user_data);
}

/// Appends a typed character to a focused field's text, as a new payload of `field.table`.
/// Returns whether the text changed: false while unfocused, for a codepoint that is not one,
/// or when the table has no room for the payload.
pub fn typeText(field: Field, typed: *const input.TextInputMsg) bool {
    if (!field.isFocused()) return false;
    var bytes: [4]u8 = undefined;
    const codepoint = std.math.cast(u21, typed.codepoint) orelse return false;
    const length = std.unicode.utf8Encode(codepoint, &bytes) catch return false;
    const before = field.query();
    // One payload of the text and the character, filled where it lies.
    const joined = field.table.allocatePayload(before.len + length, .@"1") catch return false;
    const text = field.table.payloadBytesMut(joined);
    @memcpy(text[0..before.len], before);
    @memcpy(text[before.len..], bytes[0..length]);
    field.text.* = .{ .payload = joined };
    return true;
}

/// What a key did to a field.
pub const KeyOutcome = enum {
    /// Not a key the field answers.
    ignored,
    /// The text changed.
    edited,
    /// Enter: the field let go and kept its text.
    submitted,
    /// Escape: the field emptied and let go.
    cancelled,
};

/// Answers a key pressed while the field is focused: Backspace takes back the last character
/// (with Control, all of them), Enter lets go, Escape empties and lets go. Every key is
/// `ignored` while the field is unfocused.
pub fn pressKey(field: Field, pressed: *const input.KeyInputMsg) KeyOutcome {
    if (!field.isFocused()) return .ignored;
    switch (pressed.key) {
        .backspace => {
            const text = field.query();
            if (text.len == 0) return .ignored;
            if (pressed.modifiers.control) {
                field.clear();
                return .edited;
            }
            // Back to the start of the last UTF-8 sequence.
            var end: usize = text.len;
            end -= 1;
            while (end > 0 and text[end] & 0xC0 == 0x80) end -= 1;
            // What is left is the start of the payload the cell already names.
            field.text.payload.len = @intCast(end);
            return .edited;
        },
        .enter, .kp_enter => {
            field.setFocused(false);
            return .submitted;
        },
        .escape => {
            field.clear();
            field.setFocused(false);
            return .cancelled;
        },
        else => return .ignored,
    }
}

/// Whether `render` shows a focused field as taking keys: a field whose root does not have
/// the keyboard is drawn as idle, its focus kept.
pub const Caret = enum { hidden, shown };

/// How `render` paints a field. The caller's, usually from its theme; `default_style` for a
/// plugin without one.
pub const Style = struct {
    /// The name of the font of the text and the placeholder.
    font: Atom,
    /// The colour of the text typed.
    text: ui.Color,
    /// The colour of the placeholder, and of the magnifier while the field does not take keys.
    dim: ui.Color,
    /// The colour of the caret, of the magnifier, and of the frame's border and the ring
    /// outside it, while the field takes keys.
    accent: ui.Color,
    /// The fill of the frame while the field does not take keys.
    background: ui.Color,
    /// The fill of the frame while the field takes keys.
    background_active: ui.Color,
    /// The frame's one-pixel border while the field does not take keys.
    border: ui.Color,
    /// The fill of the clear button under the pointer.
    clear_hover: ui.Color,
    /// The colour of the clear button's cross.
    clear_mark: ui.Color,
    /// The radius of the frame's corners, in pixels.
    corner_radius: f32,
};

/// A style that reads on a dark background, in roop's default font.
pub const default_style = Style{
    .font = roop.default_font,
    .text = ui.rgb(240, 240, 240),
    .dim = ui.rgb(125, 125, 125),
    .accent = ui.rgb(120, 195, 255),
    .background = ui.rgb(26, 26, 26),
    .background_active = ui.rgb(12, 34, 56),
    .border = ui.rgb(82, 82, 82),
    .clear_hover = ui.rgb(84, 84, 84),
    .clear_mark = ui.rgb(190, 190, 190),
    .corner_radius = 2,
};

/// Space inside the frame around its parts, and between them, in pixels.
const frame_padding: f32 = 4;
/// The width of the magnifier's leaf, in pixels.
const magnifier_width: f32 = 16;
/// The caret's height, in pixels.
const caret_height: f32 = 14;
/// The clear button's side, in pixels, and its leaf's width.
const clear_side: f32 = 18;

/// Draws the field into `tree` as one row, `size` in its parent, under the element id `id`:
/// the magnifier, then `placeholder` while the field is empty and does not take keys, else
/// the text with the caret after it while it takes keys, then a clear button sending `clear`
/// while it holds text. The field takes keys while it is focused and `caret` is `shown`. A
/// click on the field sends `focus` when given; an owner that watches every press instead
/// passes null. The text and `placeholder` are borrowed until the tree's last commit returns.
/// The field's parts have ids made from `id` (see `ui.partId`), so a tree holds one field an id.
/// The tree must have room for 7 more elements.
pub fn render(tree: *ui.Tree, id: anytype, field: Field, placeholder: []const u8, size: ui.Size, caret: Caret, clear: ui.Target, focus: ?ui.Target, style: Style) void {
    const focused = field.isFocused() and caret == .shown;
    const frame: ui.RectParams = .{
        .axis = .horizontal,
        .cross_align = .center,
        .size = size,
        .padding = frame_padding,
        .gap = frame_padding,
        .bg = if (focused) style.background_active else style.background,
        .border = if (focused) style.accent else style.border,
        // A ring outside the line: a field that takes keys must stand out at a glance.
        .border_size = if (focused) 1 else 0,
        .corner_radius = style.corner_radius,
        .clip_content = true,
    };
    if (!tree.beginRect(id, frame)) return;
    defer tree.endRect();
    if (focus) |target| tree.onClick(target, .left);
    const icon_color = if (focused) style.accent else style.dim;
    const icon_id = ui.partId(tree, id, "filter_icon");
    marks.place(tree, icon_id, marks.Magnifier{ .color = icon_color }, magnifier_width);
    const query = field.query();
    if (query.len == 0 and !focused) {
        const placeholder_id = ui.partId(tree, id, "filter_text");
        tree.text(placeholder_id, placeholder, .{ .font = style.font, .color = style.dim, .size_hint = .{ .w = .fill } });
        return;
    }
    const line_id = ui.partId(tree, id, "filter_line");
    if (tree.beginRect(line_id, .{ .axis = .horizontal, .cross_align = .center, .size = .{ .w = .fill, .h = .fill }, .clip_content = true })) {
        defer tree.endRect();
        const text_id = ui.partId(tree, id, "filter_text");
        tree.text(text_id, query, .{ .font = style.font, .color = style.text });
        if (focused) {
            const caret_id = ui.partId(tree, id, "filter_caret");
            tree.rect(caret_id, .{ .size = .{ .w = .{ .fixed = 1 }, .h = .{ .fixed = caret_height } }, .bg = style.accent });
        }
    }
    if (query.len == 0) return;
    const clear_id = ui.partId(tree, id, "filter_clear");
    if (tree.beginRect(clear_id, .{ .axis = .horizontal, .cross_align = .center, .size = .{ .w = .{ .fixed = clear_side }, .h = .{ .fixed = clear_side } }, .bg_hover = style.clear_hover, .corner_radius = clear_side * 0.5 })) {
        defer tree.endRect();
        tree.onClick(clear, .left);
        tree.trackHover("Clear the filter");
        const cross_id = ui.partId(tree, id, "filter_cross");
        marks.place(tree, cross_id, marks.Cross{ .color = style.clear_mark }, clear_side);
    }
}

test "a filter matches names that hold it, in any case" {
    try std.testing.expect(matches("", "camera"));
    try std.testing.expect(matches("CAM", "camera"));
    try std.testing.expect(matches("era", "camera"));
    try std.testing.expect(!matches("hud", "camera"));
}

test "backspace takes back a whole character, and escape empties the field" {
    var memory: memory_mod.Memory = undefined;
    memory.init(std.testing.allocator);
    defer memory.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&memory);
    defer atoms.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&memory, 2);
    defer tables.deinit();
    var schema: Table.Schema = undefined;
    try schema.init(std.testing.allocator, &atoms, 1);
    defer schema.deinit();
    schema.addField("text", Table.String, .text_field);
    const owner = tables.get(try tables.create(&schema, 1, Atom.from("filter_test"), .durable)).?;
    const row = try owner.tryInsert(.{ .text = @as([]const u8, "") });
    var focused: u8 = 1;
    const field: Field = .{ .table = owner, .text = owner.getField(Table.String, row, "text").?, .focused = &focused };
    var typed: input.TextInputMsg = .{ .codepoint = 'a' };
    try std.testing.expect(typeText(field, &typed));
    typed.codepoint = 0xE9;
    try std.testing.expect(typeText(field, &typed));
    try std.testing.expectEqualStrings("a\u{e9}", field.query());
    var pressed: input.KeyInputMsg = .{ .key = .backspace, .modifiers = .{} };
    try std.testing.expectEqual(KeyOutcome.edited, pressKey(field, &pressed));
    try std.testing.expectEqualStrings("a", field.query());
    pressed.key = .escape;
    try std.testing.expectEqual(KeyOutcome.cancelled, pressKey(field, &pressed));
    try std.testing.expectEqualStrings("", field.query());
    try std.testing.expect(!field.isFocused());
}
