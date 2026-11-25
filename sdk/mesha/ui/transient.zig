//! Transient menus: a menu of keyed commands, switches and options that stays up while keys are
//! typed, sets its switches and options as they are, and ends when a command is chosen.
//!
//! A `Menu` is the caller's constant: a title and groups of items, each item reached by typing
//! its key. What the menu is set to, and the keys typed so far, are a `State`, which the caller
//! keeps wherever it likes between frames (it has no pointers, so a table's bytes cell or a
//! message can carry it). A system that shows a menu feeds it each typed character and acts on
//! the outcome:
//!
//!     switch (transient.press(&menu, &state, typed)) {
//!         .pending, .toggled, .unbound => {},           // the menu stays up
//!         .wants_value => |id| ...,                     // read a value, then setValue(&menu, &state, id, value)
//!         .chosen => |id| ...,                          // run the command with the arguments, end the menu
//!         .menu => |id| ...,                            // show the menu `id` leads to
//!     }
//!
//! and, for a command, reads the arguments of what is on with `writeArguments`. A panel draws
//! the menu each frame into a `ui.Tree` of its own, of `elementCount` elements, `height` tall,
//! where `line_height` is the height `roop.Context.measureText` gives a line of the style's font:
//!
//!     var tree = try ui.Tree.init(frame_scratch, atoms, transient.elementCount(&menu));
//!     transient.record(&tree, &menu, &state, transient.default_style);
//!     const menu_height = transient.height(&menu, line_height);
//!     tree.commit(.{ .root_size = .{ .x = width, .y = menu_height } }, ctx, null);
//!
//! Items are found by their position: item i is the i-th item counting through the groups in
//! order, at most `max_items` in a menu. A menu with more, an empty key or one longer than
//! `max_key`, a key that begins another item's key, or two items with one id is a programming
//! error, which every function here asserts in a safe build. Nothing here allocates, interns or
//! touches a table; nothing drawn takes the pointer.
const std = @import("std");
const Atom = @import("../core/atom.zig").Atom;
const roop = @import("../systems/roop.zig");
const ui = @import("ui.zig");

/// What choosing an item does.
pub const Kind = enum(u8) {
    /// Ends the menu: `press` returns `.chosen`.
    command,
    /// A switch, on or off: `press` flips it and returns `.toggled`.
    toggle,
    /// An argument that takes a value: `press` returns `.wants_value`, and it is on while it
    /// has one (`setValue`).
    option,
    /// Leads to another menu, which the caller shows: `press` returns `.menu`.
    menu,
};

/// One entry of a menu. Its strings are the caller's, usually constants, and must outlive every
/// call that reads the menu, and a tree `record` wrote until its commit returns.
pub const Item = struct {
    /// What is typed to choose the item, one or more characters ("c", "-a", "=n"), at most
    /// `max_key` bytes. It neither begins nor is the beginning of another item's key in the
    /// menu, so the item is chosen the moment its last character is typed.
    key: []const u8,
    /// What the item does, for a person to read.
    label: []const u8,
    /// What choosing the item does.
    kind: Kind = .command,
    /// For a toggle, the argument it writes while on ("--all"); for an option, the argument its
    /// value is appended to ("--max-count=", "-S"). Empty, and unread, for a command or menu.
    argument: []const u8 = "",
    /// The caller's name for the item, which outcomes carry and `setValue`, `isOn` and
    /// `valueOf` take; unique in the menu.
    id: u32,

    /// A command: typing `key` chooses it.
    pub fn command(key: []const u8, label: []const u8, id: u32) Item {
        return .{ .key = key, .label = label, .id = id };
    }

    /// A switch that writes `argument` while it is on.
    pub fn toggle(key: []const u8, label: []const u8, argument: []const u8, id: u32) Item {
        return .{ .key = key, .label = label, .kind = .toggle, .argument = argument, .id = id };
    }

    /// An option that writes `argument` and its value while it has one.
    pub fn option(key: []const u8, label: []const u8, argument: []const u8, id: u32) Item {
        return .{ .key = key, .label = label, .kind = .option, .argument = argument, .id = id };
    }

    /// An item that leads to another menu, which the caller shows.
    pub fn menu(key: []const u8, label: []const u8, id: u32) Item {
        return .{ .key = key, .label = label, .kind = .menu, .id = id };
    }
};

/// A column of a menu's items under a heading.
pub const Group = struct {
    /// The heading, for a person to read. The caller's, as an item's strings are.
    title: []const u8,
    /// The group's items, top to bottom. The caller's, as an item's strings are.
    items: []const Item,
};

/// A transient menu: a title and its groups, left to right. The caller's, usually a constant,
/// alive as long as an item's strings must be.
pub const Menu = struct {
    /// What the menu is for, for a person to read.
    title: []const u8,
    /// The menu's columns of items, left to right.
    groups: []const Group,
};

/// The most items a menu holds, one bit of `State.on` each.
pub const max_items = 64;
/// The longest key, in bytes: what `State.pending` holds.
pub const max_key = 8;
/// The most options of a menu that have a value at once.
pub const max_values = 8;
/// The longest value an option keeps, in bytes; a longer one is cut at a UTF-8 character
/// boundary.
pub const max_value = 128;

/// What a menu's toggles and options are set to, and the keys typed so far. The caller's, kept
/// wherever it likes between frames: it has no pointers and no padding, so it may be copied
/// into a table's bytes cell or a message and read back by another image. `.{}` is a menu with
/// nothing on and nothing typed. Its fields are this file's to read and write; a caller reads
/// them through `isOn` and `valueOf`.
///
/// Its bytes are canonical: two states that mean the same, however they were reached, have
/// equal bytes, so a caller may compare them as bytes. Bytes past `pending_len` are zero, the
/// options with a value fill the first slots in their menu order, and every other slot is zero.
///
/// A state belongs to one version of one menu, as it names items by their position: when the
/// menu changes, as a plugin's constant may across a reload, reset the state to `.{}`, or its
/// bits and slots refer to other items.
pub const State = extern struct {
    /// Bit i is set while item i (in menu order), a toggle, is on.
    on: u64 = 0,
    /// The keys typed so far that begin some item's key, `pending_len` bytes of it.
    pending: [max_key]u8 = @splat(0),
    /// How many bytes of `pending` are typed.
    pending_len: u8 = 0,
    /// The options' values, one a slot: slot s holds `value_lens[s]` bytes for item
    /// `value_items[s]`, and zeros after them.
    values: [max_values][max_value]u8 = @splat(@splat(0)),
    /// How many bytes of each slot of `values` are the value; 0 is a free slot, and every slot
    /// after a free one is free.
    value_lens: [max_values]u8 = @splat(0),
    /// The position in the menu of the option each slot's value is for, ascending over the used
    /// slots; 0 in a free slot.
    value_items: [max_values]u8 = @splat(0),
    /// Unused; zero, so that a copy of the state has no undefined bytes.
    reserved: [7]u8 = @splat(0),
};

comptime {
    std.debug.assert(@sizeOf(State) == 8 + max_key + 1 + max_values * max_value + 2 * max_values + 7);
    std.debug.assert(@sizeOf(State) % @alignOf(State) == 0);
}

/// What a typed character did to a menu. The payloads are items' ids.
pub const Outcome = union(enum) {
    /// The keys typed so far begin some item's key: more are wanted.
    pending,
    /// A toggle was flipped.
    toggled: u32,
    /// An option was chosen. Nothing changed: the caller reads a value however it likes, then
    /// gives it to `setValue`.
    wants_value: u32,
    /// A command was chosen: the caller runs it, with `writeArguments`, and ends the menu.
    chosen: u32,
    /// An item that leads to another menu was chosen.
    menu: u32,
    /// No item's key begins with the keys typed: they are dropped.
    unbound,
};

/// Adds `typed`, the UTF-8 text of one typed character, to the keys typed so far, and does
/// what they reach. A whole key chooses its item: a toggle flips, and the typed keys are
/// cleared. The beginning of a key waits for more. Anything else is `.unbound`, and the typed
/// keys are cleared. Keys typed past `max_key` bytes are unbound.
pub fn press(menu: *const Menu, state: *State, typed: []const u8) Outcome {
    checkMenu(menu);
    const typed_before: usize = state.pending_len;
    if (typed_before + typed.len > max_key) {
        clearPending(state);
        return .unbound;
    }
    @memcpy(state.pending[typed_before..][0..typed.len], typed);
    state.pending_len = @intCast(typed_before + typed.len);
    const pending = state.pending[0..state.pending_len];

    var begins_a_key = false;
    var position: usize = 0;
    for (menu.groups) |group| {
        for (group.items) |item| {
            defer position += 1;
            if (!std.mem.startsWith(u8, item.key, pending)) continue;
            if (item.key.len != pending.len) {
                begins_a_key = true;
                continue;
            }
            clearPending(state);
            switch (item.kind) {
                .command => return .{ .chosen = item.id },
                .toggle => {
                    state.on ^= bitOf(position);
                    return .{ .toggled = item.id };
                },
                .option => return .{ .wants_value = item.id },
                .menu => return .{ .menu = item.id },
            }
        }
    }
    if (begins_a_key) return .pending;
    clearPending(state);
    return .unbound;
}

/// Forgets the keys typed so far, zeroing their bytes, as `press` does when they reach nothing:
/// for a caller that takes a key the menu cannot be typed with as unbound, as one with Control
/// held.
pub fn clearPending(state: *State) void {
    state.pending = @splat(0);
    state.pending_len = 0;
}

/// Gives the option `id` the value `value`, cut to `max_value` bytes at a UTF-8 character
/// boundary; an empty value clears it. The state copies the bytes. True when the value is kept
/// (or cleared). False, with nothing changed, when `id` is no option of this menu, as an id
/// read before the menu changed may be, or when `max_values` other options have a value
/// already.
pub fn setValue(menu: *const Menu, state: *State, id: u32, value: []const u8) bool {
    checkMenu(menu);
    const position = positionOf(menu, id) orelse return false;
    const item = itemAt(menu, position);
    if (item.kind != .option) return false;
    const kept_len = utf8Cut(value, max_value);
    const kept = value[0..kept_len];

    if (slotOf(state, position)) |slot| {
        if (kept.len == 0) {
            removeSlot(state, slot);
        } else {
            writeSlot(state, slot, position, kept);
        }
        return true;
    }
    if (kept.len == 0) return true;
    const used = usedSlots(state);
    if (used == max_values) return false;
    // Keep the used slots in menu order: move those of later options up by one.
    var slot = used;
    while (slot > 0 and state.value_items[slot - 1] > position) : (slot -= 1) {
        copySlot(state, slot - 1, slot);
    }
    writeSlot(state, slot, position, kept);
    return true;
}

/// Whether `setToggle` turns a toggle on or off.
pub const Switch = enum { on, off };

/// Turns the toggle `id` on or off, as `wanted` says, whatever it was: what a caller does to a
/// state the menu answered with before it writes the arguments, as a command that needs a switch
/// on. False, with nothing changed, when `id` is no toggle of this menu.
pub fn setToggle(menu: *const Menu, state: *State, id: u32, wanted: Switch) bool {
    checkMenu(menu);
    const position = positionOf(menu, id) orelse return false;
    if (itemAt(menu, position).kind != .toggle) return false;
    switch (wanted) {
        .on => state.on |= bitOf(position),
        .off => state.on &= ~bitOf(position),
    }
    return true;
}

/// Whether the item `id` is on: a toggle that is set, or an option that has a value. A command,
/// a menu, or an id not in the menu is never on.
pub fn isOn(menu: *const Menu, state: *const State, id: u32) bool {
    checkMenu(menu);
    const position = positionOf(menu, id) orelse return false;
    return isOnAt(menu, state, position);
}

/// The value of the option `id`; empty when it has none, or `id` is no option's. The slice is
/// the state's, valid until the state is next changed or moved.
pub fn valueOf(menu: *const Menu, state: *const State, id: u32) []const u8 {
    checkMenu(menu);
    const position = positionOf(menu, id) orelse return "";
    return valueAt(state, position);
}

/// Writes the arguments of what is on, in menu order, each followed by `separator`: a toggle
/// that is on as its `argument`, an option that has a value as its `argument` and the value
/// together (`--max-count=` and `20` write `--max-count=20`, `-S` and `foo` write `-Sfoo`).
/// Commands and menus write nothing. Fails as `writer` does.
pub fn writeArguments(menu: *const Menu, state: *const State, separator: u8, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    checkMenu(menu);
    var position: usize = 0;
    for (menu.groups) |group| {
        for (group.items) |item| {
            defer position += 1;
            switch (item.kind) {
                .toggle => {
                    if (state.on & bitOf(position) == 0) continue;
                    try writer.writeAll(item.argument);
                },
                .option => {
                    const value = valueAt(state, position);
                    if (value.len == 0) continue;
                    try writer.writeAll(item.argument);
                    try writer.writeAll(value);
                },
                .command, .menu => continue,
            }
            try writer.writeByte(separator);
        }
    }
}

/// How `record` paints a menu. The caller's, usually from its theme; `default_style` for a
/// plugin without one.
pub const Style = struct {
    /// The name of the font every line is drawn in.
    font: Atom,
    /// The colour of an item's key and of the keys typed so far.
    key: ui.Color,
    /// The colour of the menu's title, an item's label, and the argument of an item that is off.
    label: ui.Color,
    /// The colour of the label and argument of an item that is on.
    on: ui.Color,
    /// The colour of a group's heading.
    heading: ui.Color,
    /// The colour of the menu's fill.
    background: ui.Color,
};

/// A style that reads on a dark background, in roop's default font.
pub const default_style = Style{
    .font = roop.default_font,
    .key = ui.rgb(210, 140, 230),
    .label = ui.rgb(220, 220, 220),
    .on = ui.rgb(240, 200, 90),
    .heading = ui.rgb(110, 170, 250),
    .background = ui.rgb(32, 32, 32),
};

/// Space around the menu inside its fill, in pixels.
const padding: f32 = 8;
/// Space between the title line and the groups, in pixels.
const title_gap: f32 = 6;
/// Space between one group and the next, in pixels.
const group_gap: f32 = 24;
/// Space between a key and its label, and a label and its argument, in pixels.
const column_gap: f32 = 8;

const menu_name = Atom.from("transient.menu");
const title_row_name = Atom.from("transient.title_row");
const title_name = Atom.from("transient.title");
const pending_name = Atom.from("transient.pending");
const groups_name = Atom.from("transient.groups");
const group_name = Atom.from("transient.group");
const heading_name = Atom.from("transient.heading");
const group_body_name = Atom.from("transient.group_body");
const group_keys_name = Atom.from("transient.group_keys");
const group_lines_name = Atom.from("transient.group_lines");
const key_name = Atom.from("transient.key");
const line_name = Atom.from("transient.line");
const label_name = Atom.from("transient.label");
const argument_name = Atom.from("transient.argument");

/// Records the menu into `tree` as a column as wide as its parent and as tall as `height`, in
/// `style.background`: the title, with the keys typed so far after it in `style.key`, then the
/// groups left to right, each its heading over its items, one a line: the key, then the label,
/// then a toggle's or option's argument in parentheses, an option's value after its argument.
/// An item that is on has its label and argument in `style.on`. The pending keys and the
/// arguments are copied into the tree's frame; the menu's strings are borrowed until the tree's
/// last commit returns. Element ids are this file's names with the group's or item's position,
/// so one menu a tree. The tree must have room for `elementCount(menu)` more elements.
pub fn record(tree: *ui.Tree, menu: *const Menu, state: *const State, style: Style) void {
    checkMenu(menu);
    const menu_open = tree.beginRect(menu_name, .{
        .axis = .vertical,
        .size = .{ .w = .fill, .h = .hug },
        .padding = padding,
        .gap = title_gap,
        .bg = style.background,
        .clip_content = true,
    });
    if (!menu_open) return;
    defer tree.endRect();

    recordTitle(tree, menu, state, style);
    if (menu.groups.len == 0) return;
    const groups_open = tree.beginRect(groups_name, .{ .axis = .horizontal, .gap = group_gap });
    if (!groups_open) return;
    defer tree.endRect();
    var position: usize = 0;
    for (menu.groups, 0..) |*group, group_index| {
        recordGroup(tree, group, group_index, position, state, style);
        position += group.items.len;
    }
}

/// The title line: the menu's title, then the keys typed so far.
fn recordTitle(tree: *ui.Tree, menu: *const Menu, state: *const State, style: Style) void {
    const row_open = tree.beginRect(title_row_name, .{ .axis = .horizontal, .gap = column_gap });
    if (!row_open) return;
    defer tree.endRect();
    tree.text(title_name, menu.title, .{ .font = style.font, .color = style.label });
    if (state.pending_len == 0) return;
    const pending = tree.allocBuffer(state.pending_len);
    @memcpy(pending, state.pending[0..state.pending_len]);
    tree.text(pending_name, pending, .{ .font = style.font, .color = style.key });
}

/// A group's column: its heading over a row of its keys' column and its lines' column, so that
/// the labels line up whatever the keys' widths. `first_position` is the group's first item's
/// position in the menu.
fn recordGroup(tree: *ui.Tree, group: *const Group, group_index: usize, first_position: usize, state: *const State, style: Style) void {
    const group_open = tree.beginRect(.{ group_name, group_index }, .{ .axis = .vertical });
    if (!group_open) return;
    defer tree.endRect();
    tree.text(.{ heading_name, group_index }, group.title, .{ .font = style.font, .color = style.heading });

    const body_open = tree.beginRect(.{ group_body_name, group_index }, .{ .axis = .horizontal, .gap = column_gap });
    if (!body_open) return;
    defer tree.endRect();

    const keys_open = tree.beginRect(.{ group_keys_name, group_index }, .{ .axis = .vertical });
    if (keys_open) {
        for (group.items, first_position..) |item, position| {
            tree.text(.{ key_name, position }, item.key, .{ .font = style.font, .color = style.key });
        }
        tree.endRect();
    }

    const lines_open = tree.beginRect(.{ group_lines_name, group_index }, .{ .axis = .vertical });
    if (!lines_open) return;
    defer tree.endRect();
    for (group.items, first_position..) |*item, position| {
        recordLine(tree, item, position, state, style);
    }
}

/// An item's line beside its key: its label, and a toggle's or option's argument.
fn recordLine(tree: *ui.Tree, item: *const Item, position: usize, state: *const State, style: Style) void {
    const line_open = tree.beginRect(.{ line_name, position }, .{ .axis = .horizontal, .gap = column_gap });
    if (!line_open) return;
    defer tree.endRect();
    const on = isOnItem(item, state, position);
    const color = if (on) style.on else style.label;
    tree.text(.{ label_name, position }, item.label, .{ .font = style.font, .color = color });
    if (item.kind != .toggle and item.kind != .option) return;

    const value = valueAt(state, position);
    const argument = tree.allocBuffer(item.argument.len + value.len + 2);
    argument[0] = '(';
    @memcpy(argument[1..][0..item.argument.len], item.argument);
    @memcpy(argument[1 + item.argument.len ..][0..value.len], value);
    argument[argument.len - 1] = ')';
    tree.text(.{ argument_name, position }, argument, .{ .font = style.font, .color = color });
}

/// How tall `record` lays the menu out, in pixels: its padding, the title line, and the heading
/// and items of the longest group, one line each. `line_height` is the height of a line of the
/// style's font, which is what `roop.Context.measureText` gives as `h` for it (the font's pixel
/// height; 0 while the font is not loaded). The menu is assumed wide enough that no label wraps.
pub fn height(menu: *const Menu, line_height: f32) f32 {
    checkMenu(menu);
    const title_height = 2 * padding + line_height;
    if (menu.groups.len == 0) return title_height;
    var most_items: usize = 0;
    for (menu.groups) |group| most_items = @max(most_items, group.items.len);
    const group_lines: f32 = @floatFromInt(1 + most_items);
    return title_height + title_gap + group_lines * line_height;
}

/// At most how many elements `record` takes of a tree for `menu` (fewer while no key is pending,
/// or when the menu has no groups): size the tree for these and the caller's own.
pub fn elementCount(menu: *const Menu) usize {
    checkMenu(menu);
    const menu_elements = 2 + 2 + 2 + 2; // the menu, the title row, the title and pending keys, the groups' row
    const group_elements = 2 + 1 + 2 + 2 + 2; // the column, its heading, its body, keys and lines
    const item_elements = 1 + 2 + 1; // the key, the line and the label
    var count: usize = menu_elements;
    for (menu.groups) |group| {
        count += group_elements;
        for (group.items) |item| {
            count += item_elements;
            const has_argument = item.kind == .toggle or item.kind == .option;
            if (has_argument) count += 1;
        }
    }
    return count;
}

/// Asserts what a menu must hold to (see the file's doc), in a safe build.
fn checkMenu(menu: *const Menu) void {
    if (!std.debug.runtime_safety) return;
    var count: usize = 0;
    for (menu.groups) |group| count += group.items.len;
    std.debug.assert(count <= max_items);
    for (menu.groups, 0..) |group, group_index| {
        for (group.items, 0..) |item, item_index| {
            std.debug.assert(item.key.len != 0 and item.key.len <= max_key);
            for (menu.groups[group_index..], group_index..) |other_group, other_group_index| {
                const first = if (other_group_index == group_index) item_index + 1 else 0;
                for (other_group.items[first..]) |other| {
                    std.debug.assert(item.id != other.id);
                    std.debug.assert(!std.mem.startsWith(u8, item.key, other.key));
                    std.debug.assert(!std.mem.startsWith(u8, other.key, item.key));
                }
            }
        }
    }
}

fn bitOf(position: usize) u64 {
    const shift: u6 = @intCast(position);
    return @as(u64, 1) << shift;
}

/// The position in the menu of the item `id`, or null when no item has it.
fn positionOf(menu: *const Menu, id: u32) ?usize {
    var position: usize = 0;
    for (menu.groups) |group| {
        for (group.items) |item| {
            if (item.id == id) return position;
            position += 1;
        }
    }
    return null;
}

/// The item at `position`, which is in the menu.
fn itemAt(menu: *const Menu, position: usize) *const Item {
    var first: usize = 0;
    for (menu.groups) |group| {
        if (position < first + group.items.len) return &group.items[position - first];
        first += group.items.len;
    }
    unreachable;
}

fn isOnAt(menu: *const Menu, state: *const State, position: usize) bool {
    const item = itemAt(menu, position);
    return isOnItem(item, state, position);
}

fn isOnItem(item: *const Item, state: *const State, position: usize) bool {
    return switch (item.kind) {
        .toggle => state.on & bitOf(position) != 0,
        .option => slotOf(state, position) != null,
        .command, .menu => false,
    };
}

/// The value of the item at `position`; empty when it has none.
fn valueAt(state: *const State, position: usize) []const u8 {
    const slot = slotOf(state, position) orelse return "";
    return state.values[slot][0..state.value_lens[slot]];
}

/// The slot holding the value of the item at `position`, or null when it has none.
fn slotOf(state: *const State, position: usize) ?usize {
    for (state.value_lens, state.value_items, 0..) |len, item_position, slot| {
        if (len != 0 and item_position == position) return slot;
    }
    return null;
}

/// How many slots hold a value: they are the first ones.
fn usedSlots(state: *const State) usize {
    for (state.value_lens, 0..) |len, slot| {
        if (len == 0) return slot;
    }
    return max_values;
}

/// Makes `slot` hold `value`, a value of at most `max_value` bytes, for the item at `position`,
/// with zeros after it.
fn writeSlot(state: *State, slot: usize, position: usize, value: []const u8) void {
    state.values[slot] = @splat(0);
    @memcpy(state.values[slot][0..value.len], value);
    state.value_lens[slot] = @intCast(value.len);
    state.value_items[slot] = @intCast(position);
}

fn copySlot(state: *State, from: usize, to: usize) void {
    state.values[to] = state.values[from];
    state.value_lens[to] = state.value_lens[from];
    state.value_items[to] = state.value_items[from];
}

/// Empties the used `slot`, moving the used slots after it down by one and zeroing the last.
fn removeSlot(state: *State, slot: usize) void {
    const used = usedSlots(state);
    for (slot..used - 1) |to| copySlot(state, to + 1, to);
    const last = used - 1;
    state.values[last] = @splat(0);
    state.value_lens[last] = 0;
    state.value_items[last] = 0;
}

/// How many bytes of `text` fit in `limit` without cutting a UTF-8 character: all of it when it
/// fits, else up to the last character boundary at or before `limit`.
fn utf8Cut(text: []const u8, limit: usize) usize {
    if (text.len <= limit) return text.len;
    var cut = limit;
    while (cut > 0 and text[cut] & 0xc0 == 0x80) cut -= 1;
    return cut;
}

const test_menu = Menu{
    .title = "Log",
    .groups = &.{
        .{ .title = "Arguments", .items = &.{
            .{ .key = "-a", .label = "All branches", .kind = .toggle, .argument = "--all", .id = 1 },
            .{ .key = "=n", .label = "Limit", .kind = .option, .argument = "--max-count=", .id = 2 },
            .{ .key = "-S", .label = "Search", .kind = .option, .argument = "-S", .id = 3 },
            .{ .key = "-n", .label = "No merges", .kind = .toggle, .argument = "--no-merges", .id = 4 },
        } },
        .{ .title = "Log", .items = &.{
            .{ .key = "c", .label = "Commit", .id = 10 },
            .{ .key = "b", .label = "Branches", .kind = .menu, .id = 11 },
        } },
    },
};

fn writtenArguments(state: *const State, buffer: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writeArguments(&test_menu, state, ' ', &writer);
    return writer.buffered();
}

test "press of a command's key chooses it" {
    var state: State = .{};
    try std.testing.expectEqual(Outcome{ .chosen = 10 }, press(&test_menu, &state, "c"));
}

test "a toggle's key is pending after its first character, toggles on, then off" {
    var state: State = .{};
    try std.testing.expectEqual(Outcome.pending, press(&test_menu, &state, "-"));
    try std.testing.expectEqual(Outcome{ .toggled = 1 }, press(&test_menu, &state, "a"));
    try std.testing.expect(isOn(&test_menu, &state, 1));
    _ = press(&test_menu, &state, "-");
    _ = press(&test_menu, &state, "a");
    try std.testing.expect(!isOn(&test_menu, &state, 1));
}

test "setToggle turns a toggle on and off whatever it was, and no other kind" {
    var state: State = .{};
    try std.testing.expect(setToggle(&test_menu, &state, 1, .on));
    try std.testing.expect(setToggle(&test_menu, &state, 1, .on));
    try std.testing.expect(isOn(&test_menu, &state, 1));
    try std.testing.expect(setToggle(&test_menu, &state, 1, .off));
    try std.testing.expect(!isOn(&test_menu, &state, 1));
    try std.testing.expect(!setToggle(&test_menu, &state, 10, .on));
    try std.testing.expectEqual(@as(u64, 0), state.on);
}

test "an option wants a value, and its value is written after its argument" {
    var state: State = .{};
    _ = press(&test_menu, &state, "=");
    try std.testing.expectEqual(Outcome{ .wants_value = 2 }, press(&test_menu, &state, "n"));
    try std.testing.expect(setValue(&test_menu, &state, 2, "20"));
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("--max-count=20 ", try writtenArguments(&state, &buffer));
    const before = state;
    try std.testing.expect(!setValue(&test_menu, &state, 99, "x") and std.mem.eql(u8, std.mem.asBytes(&before), std.mem.asBytes(&state)));
}

test "an unbound key gives unbound and clears the pending keys" {
    var state: State = .{};
    _ = press(&test_menu, &state, "-");
    try std.testing.expectEqual(Outcome.unbound, press(&test_menu, &state, "x"));
    try std.testing.expectEqual(@as(u8, 0), state.pending_len);
}

test "writeArguments writes what is on in menu order" {
    var state: State = .{};
    _ = press(&test_menu, &state, "-");
    _ = press(&test_menu, &state, "n");
    _ = setValue(&test_menu, &state, 3, "foo");
    _ = press(&test_menu, &state, "-");
    _ = press(&test_menu, &state, "a");
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("--all -Sfoo --no-merges ", try writtenArguments(&state, &buffer));
}

test "states that mean the same have equal bytes" {
    var state: State = .{};
    _ = setValue(&test_menu, &state, 3, "foo");
    _ = setValue(&test_menu, &state, 2, "20");
    _ = setValue(&test_menu, &state, 2, "");
    _ = press(&test_menu, &state, "-");
    _ = press(&test_menu, &state, "a");
    _ = press(&test_menu, &state, "-");
    _ = press(&test_menu, &state, "a");
    var expected: State = .{};
    _ = setValue(&test_menu, &expected, 3, "foo");
    try std.testing.expect(std.mem.eql(u8, std.mem.asBytes(&expected), std.mem.asBytes(&state)));
}

test "a value longer than max_value is cut at a character boundary" {
    var state: State = .{};
    const long = "a" ++ "é" ** max_value;
    _ = setValue(&test_menu, &state, 2, long);
    try std.testing.expectEqualStrings(long[0 .. max_value - 1], valueOf(&test_menu, &state, 2));
}

test "a ninth value is refused" {
    var items: [max_values + 1]Item = undefined;
    const keys = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i" };
    for (&items, keys, 0..) |*item, key, index| {
        item.* = .{ .key = key, .label = key, .kind = .option, .argument = "-", .id = @intCast(index) };
    }
    const options_menu = Menu{ .title = "Options", .groups = &.{.{ .title = "All", .items = &items }} };
    var state: State = .{};
    for (0..max_values) |index| _ = setValue(&options_menu, &state, @intCast(index), "v");
    try std.testing.expect(!setValue(&options_menu, &state, max_values, "v"));
}

test "record records the menu within elementCount, balanced" {
    const memory = @import("../core/memory.zig");
    var mem: memory.Memory = undefined;
    mem.init(std.testing.allocator);
    defer mem.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&mem);
    defer atoms.deinit();
    var frame_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frame_arena.deinit();
    const capacity = elementCount(&test_menu);
    var tree = try ui.Tree.init(.{ .allocator = frame_arena.allocator() }, &atoms, capacity);
    var state: State = .{};
    _ = press(&test_menu, &state, "-");
    _ = setValue(&test_menu, &state, 2, "20");
    record(&tree, &test_menu, &state, default_style);
    try tree.validateCommands();
    try std.testing.expectEqual(capacity, tree.count);
}

test "record lays the menu out height tall" {
    const math = @import("../core/math.zig");
    const memory = @import("../core/memory.zig");
    const resources = @import("../systems/resources.zig");
    const font = @import("../systems/font.zig");
    const Fixture = struct {
        view: resources.FontView,
        fn get(raw: *anyopaque, _: *const resources.ScopeId, _: Atom, view: *resources.FontView) callconv(.c) bool {
            const fixture: *@This() = @ptrCast(@alignCast(raw));
            view.* = fixture.view;
            return true;
        }
    };
    // Draws nothing; keeps how far down the tree it was laid out.
    const Probe = struct {
        top: f32 = -1,
        pub fn draw(self: *@This(), _: math.Vec2f, ctx: *roop.Context) void {
            const transform = ctx.currentTransform();
            self.top = transform[5];
        }
    };
    var glyphs = std.mem.zeroes(font.BakedChars);
    for (&glyphs) |*glyph| glyph.xadvance = 6;
    const line_height: f32 = 12;
    var fixture: Fixture = .{ .view = .{ .baked_chars = &glyphs, .pixel_height = line_height, .image = 1, .first_char = font.kFirstChar } };
    var renderer: roop.Renderer = .{ .font_provider = .{ .context = &fixture, .scope = .{ .atom = resources.kApplicationScope, .generation = 1 }, .get_fn = Fixture.get } };

    var mem: memory.Memory = undefined;
    mem.init(std.testing.allocator);
    defer mem.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&mem);
    defer atoms.deinit();
    var frame_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frame_arena.deinit();
    const frame_allocator = frame_arena.allocator();
    var ctx = try roop.Context.initWithoutTarget(&renderer, &frame_allocator);
    ctx.beginFrame(800, 600, 1, .wrap(&frame_allocator));

    const capacity = elementCount(&test_menu) + 3;
    var tree = try ui.Tree.init(.{ .allocator = frame_allocator }, &atoms, capacity);
    var state: State = .{};
    _ = press(&test_menu, &state, "-");
    var probe = Probe{};
    // The probe sits right under the menu in a column with no gap: its top is the menu's height.
    const column_open = tree.beginRect(Atom.from("test.column"), .{ .axis = .vertical });
    try std.testing.expect(column_open);
    record(&tree, &test_menu, &state, default_style);
    tree.custom(Atom.from("test.probe"), &probe, .{ .size = .{ .w = .{ .fixed = 1 }, .h = .{ .fixed = 1 } } });
    tree.endRect();
    tree.commit(.{ .root_size = .{ .x = 800, .y = 600 } }, &ctx, null);
    try std.testing.expectEqual(height(&test_menu, line_height), probe.top);
}
