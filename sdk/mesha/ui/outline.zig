//! An outline: lines in sections that nest, as a version-control status shows headings
//! ("Unstaged changes (3)"), the files under a heading, the hunks of a file and the lines of a
//! hunk, or a list of changelists their files and theirs. A section that has lines under it can
//! be collapsed to its own line; a cursor line moves through what is shown, by line, by sibling
//! and to its parent; and the view scrolls to keep the cursor in sight.
//!
//! The owner, a panel, builds its `Line`s anew each run from its own tables into frame
//! scratch, and keeps its `Cursor` and its collapsed keys in a table of its own. Each run of
//! its kernel:
//!
//!     const shown = outline.visible(lines, collapsed, out);      // what is not collapsed away
//!     var cursor = outline.settle(lines, shown, stored_cursor);  // its line, or what took its place
//!     cursor = outline.move(lines, shown, cursor, .next, page_lines); // for a key that moves it
//!     cursor.scroll = outline.scrollTo(shown, cursor, line_height, view_height);
//!
//! `scrollTo` follows the cursor, so it is called only in a run where the cursor moved or the
//! lines were built from new data: called every run, it would undo a wheel scroll. After the
//! wheel the kernel keeps the scroll the wheel asked for within the list (`clampScroll`), and
//! when that leaves the cursor's line out of view it moves the cursor to the nearest line in
//! view (`cursorInView`): the cursor follows the view, as Emacs's point follows its window.
//!
//! Its draw function reads the same tables, builds the same lines and calls `record` with the
//! cursor its kernel left, in a `Style` from its theme or `default_style`:
//!
//!     outline.record(&tree, lines, shown, cursor, .{ .inbox = inbox, .click_tag = click,
//!         .toggle_tag = toggle, .scroll_tag = wheel, .collapsed = collapsed,
//!         .view_height = view_height, .line_height = line_height, .style = theme });
//!
//! A click on a line, or on a line's chevron, and the wheel over the list come back to the
//! owner's inbox as messages carrying the line's key. Nothing here keeps anything between
//! calls, allocates (but for a chevron's copy in the tree's frame), or touches a table.
//!
//! A line's section is the line and every line after it that is deeper than it; its parent is
//! the nearest line before it that is shallower. Lines are found by their index in the list,
//! and shown lines by their position in what `visible` gives, which is what `Cursor.index` is.
const std = @import("std");
const Atom = @import("../core/atom.zig").Atom;
const roop = @import("../systems/roop.zig");
const memory_mod = @import("../core/memory.zig");
const marks = @import("marks.zig");
const ui = @import("ui.zig");

/// Which of the style's fonts a line is drawn in.
pub const Font = enum {
    /// `Style.text_font`, the owner's ui font: headings, files, changelists.
    text,
    /// `Style.code_font`, a monospace font: a diff's lines, which are code.
    code,
};

/// One line of the list. The owner builds them anew each run; nothing here keeps one.
pub const Line = struct {
    /// How deep the line nests: 0 a heading at the top. The line's section is it and every
    /// following line deeper than it.
    depth: u8,
    /// What the line is, in the owner's terms (a heading, a file, a hunk, an added line);
    /// never read here.
    kind: u8,
    /// Names the line across rebuilds: what the cursor and a collapsed section are kept by,
    /// what a click carries and what the line's elements are known by. Unique in the list, and
    /// never 0, which `Cursor.key` keeps for no line.
    key: u64,
    /// What the line says, for a person to read. The owner's, alive until the tree `record`
    /// wrote is committed.
    text: []const u8,
    /// Drawn dimmed after `text`, as a count or a file's status; empty for none. Alive as
    /// `text` is.
    detail: []const u8 = "",
    /// The colour of `text`.
    colour: ui.Color,
    /// The font `text` and `detail` are drawn in.
    font: Font = .text,
    /// The line has, or may have, lines under it: it draws a chevron and can be collapsed.
    expandable: bool = false,
};

/// Where the cursor is and how far the list is scrolled. The owner keeps it in a table between
/// runs (it has no pointers and no padding); `.{}` is the first line, unscrolled.
pub const Cursor = extern struct {
    /// The key of the line the cursor is on; 0 before it has been on any.
    key: u64 = 0,
    /// The position of that line in the shown lines, as `settle` last found it: where the
    /// cursor lands when the line is gone.
    index: u32 = 0,
    /// Pixels from the top of the list to the top of the view.
    scroll: f32 = 0,
};

/// A line and the lines under it: lines `first` up to, and not including, `end`.
pub const Section = struct {
    /// The index of the section's own line.
    first: u32,
    /// The index after its last line: the next line no deeper than it, or the list's length.
    end: u32,
};

/// A way `move` takes the cursor.
pub const Step = enum {
    /// The next shown line.
    next,
    /// The shown line before.
    previous,
    /// The next line at the cursor's depth in its parent's section; past the last, the next
    /// line that is not deeper (from a file's last hunk, the next file).
    next_sibling,
    /// The line before at the cursor's depth in its parent's section; from the first, the
    /// parent.
    previous_sibling,
    /// The line whose section the cursor's line is in.
    parent,
    /// The first shown line.
    first,
    /// The last shown line.
    last,
    /// `page_lines` lines on.
    page_down,
    /// `page_lines` lines back.
    page_up,
};

/// The indices of the lines shown, in order, written into `out`, which holds at least
/// `lines.len`: every line but those under a line whose key is in `collapsed`. A collapsed
/// line is itself shown; keys that name no line are passed over. One pass over `lines`, each
/// shown line looked for in `collapsed`, which is meant to be small and need not be sorted.
pub fn visible(lines: []const Line, collapsed: []const u64, out: []u32) []u32 {
    std.debug.assert(out.len >= lines.len);
    var count: usize = 0;
    // While a collapsed line's section runs, its depth: lines deeper than it are hidden.
    var hiding_below: ?u8 = null;
    for (lines, 0..) |line, index| {
        if (hiding_below) |collapsed_depth| {
            if (line.depth > collapsed_depth) continue;
            hiding_below = null;
        }
        out[count] = @intCast(index);
        count += 1;
        const is_collapsed = std.mem.indexOfScalar(u64, collapsed, line.key) != null;
        if (is_collapsed) hiding_below = line.depth;
    }
    return out[0..count];
}

/// The cursor brought up to date with lines built again, and `shown`, what `visible` gives of
/// them: on its line where that line is shown; on the nearest shown line whose section holds
/// it where it is hidden; and where its line is gone, on the line now at its old position (the
/// last, if that is past the end), which is the line that took its place. An empty list gives
/// `.{}`. The scroll is carried, made 0 when it is negative or not a number: `scrollTo`, which
/// knows the lines' height, keeps it within the list.
pub fn settle(lines: []const Line, shown: []const u32, cursor: Cursor) Cursor {
    if (shown.len == 0) return .{};
    const scroll = if (std.math.isFinite(cursor.scroll)) @max(cursor.scroll, 0) else 0;
    const line_index = indexOfKey(lines, cursor.key);
    const position = if (line_index) |found| shownAtOrAbove(lines, shown, found) else null;
    const last_position: u32 = @intCast(shown.len - 1);
    const settled_position = position orelse @min(cursor.index, last_position);
    const settled_line = shown[settled_position];
    return .{ .key = lines[settled_line].key, .index = settled_position, .scroll = scroll };
}

/// The cursor moved by `step` through `shown`, what `visible` gives of `lines`, and never
/// past either end; a step that finds no line leaves it where it is. A cursor not settled
/// against these lines is settled first. `page_lines` is how many lines `page_down` and
/// `page_up` go. The scroll is carried: `scrollTo` follows the cursor.
pub fn move(lines: []const Line, shown: []const u32, cursor: Cursor, step: Step, page_lines: u32) Cursor {
    const settled = settle(lines, shown, cursor);
    if (shown.len == 0) return settled;
    const from = settled.index;
    const last: u32 = @intCast(shown.len - 1);
    const depth = lines[shown[from]].depth;
    const to: u32 = switch (step) {
        .next => @min(from + 1, last),
        .previous => from -| 1,
        .first => 0,
        .last => last,
        .page_down => @min(from +| page_lines, last),
        .page_up => from -| page_lines,
        // A sibling is the next line no deeper; failing one, that line is the next section on.
        .next_sibling => shownAfter(lines, shown, from, depth, .same_or_shallower) orelse from,
        // Going back, the first line no deeper is the sibling before, else the parent.
        .previous_sibling => shownBefore(lines, shown, from, depth, .same_or_shallower) orelse from,
        .parent => shownBefore(lines, shown, from, depth, .shallower) orelse from,
    };
    const to_line = shown[to];
    return .{ .key = lines[to_line].key, .index = to, .scroll = settled.scroll };
}

/// The scroll, in pixels from the top of the list, that shows the cursor's line whole with
/// the least change from `cursor.scroll`: never negative, and never past where the last line
/// meets the bottom of the view. Every line is `line_height` tall and the view `view_height`;
/// in a view shorter than a line, the line's top is shown.
pub fn scrollTo(shown: []const u32, cursor: Cursor, line_height: f32, view_height: f32) f32 {
    if (shown.len == 0) return 0;
    var scroll = if (std.math.isFinite(cursor.scroll)) cursor.scroll else 0;
    const position: f32 = @floatFromInt(@min(cursor.index, shown.len - 1));
    const line_top = position * line_height;
    const line_bottom = line_top + line_height;
    if (line_bottom > scroll + view_height) scroll = line_bottom - view_height;
    if (line_top < scroll) scroll = line_top;
    const line_count: f32 = @floatFromInt(shown.len);
    const list_height = line_count * line_height;
    const furthest = @max(list_height - view_height, 0);
    return std.math.clamp(scroll, 0, furthest);
}

/// `scroll` kept within the list: never negative, and never past where the last line meets the
/// bottom of the view, as `scrollTo` keeps it, without following the cursor. What a kernel
/// keeps of a wheel's scroll. Every line is `line_height` tall and the view `view_height`; a
/// scroll that is not a number is 0.
pub fn clampScroll(shown: []const u32, scroll: f32, line_height: f32, view_height: f32) f32 {
    if (!std.math.isFinite(scroll)) return 0;
    const line_count: f32 = @floatFromInt(shown.len);
    const list_height = line_count * line_height;
    const furthest = @max(list_height - view_height, 0);
    return std.math.clamp(scroll, 0, furthest);
}

/// The cursor on the nearest line wholly in the view its `scroll` gives, for after a wheel
/// scroll: as it is while its line is in view; else on the first line in view when its line is
/// above, the last when below. `shown` is what `visible` gave of `lines`, and `cursor` is
/// settled against them. In a view shorter than a line, the line at the view's top. The scroll
/// is kept.
pub fn cursorInView(lines: []const Line, shown: []const u32, cursor: Cursor, line_height: f32, view_height: f32) Cursor {
    if (shown.len == 0 or line_height <= 0) return cursor;
    const scroll = if (std.math.isFinite(cursor.scroll)) @max(cursor.scroll, 0) else 0;
    const last: u32 = @intCast(shown.len - 1);
    const first_whole: u32 = @intCast(@min(floatToCount(@ceil(scroll / line_height)), last));
    const lines_in_view = @max(floatToCount(@floor(view_height / line_height)), 1);
    const last_whole: u32 = @intCast(@min(first_whole + lines_in_view - 1, last));
    const position = std.math.clamp(@min(cursor.index, last), first_whole, last_whole);
    return .{ .key = lines[shown[position]].key, .index = position, .scroll = cursor.scroll };
}

/// The section of the line at `index`: it and the lines under it.
pub fn sectionOf(lines: []const Line, index: u32) Section {
    const depth = lines[index].depth;
    var end = index + 1;
    while (end < lines.len and lines[end].depth > depth) end += 1;
    return .{ .first = index, .end = end };
}

/// The index of the line whose section the line at `index` is directly in: the nearest line
/// before it that is shallower. Null for a line at the top.
pub fn parentOf(lines: []const Line, index: u32) ?u32 {
    const depth = lines[index].depth;
    var before = index;
    while (before > 0) {
        before -= 1;
        if (lines[before].depth < depth) return before;
    }
    return null;
}

/// How `record` draws a list and where what is done to it goes. The owner's, made where it
/// draws; the slices are borrowed for the call.
pub const RecordOptions = struct {
    /// The inbox a click on a line, on a chevron, or the wheel over the list is sent to: the
    /// owner's, as `sequencer.inboxOf` names it.
    inbox: Atom,
    /// The tag a click on a line is sent under, with the line's key (a `u64`) as its user data:
    /// the owner puts the cursor there.
    click_tag: Atom,
    /// The tag a click on a line's chevron is sent under, with the line's key as its user data:
    /// the owner collapses or opens the line's section.
    toggle_tag: Atom,
    /// The tag the wheel over the list is sent under, with no user data: the owner scrolls.
    scroll_tag: Atom,
    /// The keys of the lines whose sections are collapsed, as given to `visible`: their
    /// chevrons point right, the others' down.
    collapsed: []const u64,
    /// The height of the list's view, in pixels: the list is drawn this tall.
    view_height: f32,
    /// The height of every line, in pixels, as `scrollTo` was given it: at least the taller
    /// font's line.
    line_height: f32,
    /// Mixed into every element's id with a line's key, to tell apart two lists drawn at once
    /// whose keys may be the same; 0 where one list is shown.
    salt: u64 = 0,
    /// The fonts, colours and metrics the list is drawn in.
    style: Style = default_style,
};

/// How `record` paints a list. The caller's, usually from its theme; `default_style` for a
/// plugin without one. Copied into the call; it holds no pointers.
pub const Style = struct {
    /// The font of a `.text` line.
    text_font: Atom,
    /// The font of a `.code` line: a monospace one, where the owner has one.
    code_font: Atom,
    /// The fill of the cursor's line, across the list's width.
    highlight: ui.Color,
    /// The fill of a line under the pointer.
    hover: ui.Color,
    /// The colour of a line's detail and of its chevron (`ui.marks.Chevron`), the fold mark.
    dimmed: ui.Color,
    /// How far each depth is indented, in pixels.
    indent: f32 = 14,
    /// How wide a line's chevron is, and the room left for one on a line without, in pixels.
    chevron_width: f32 = 16,
    /// Space between a line's chevron, text and detail, in pixels.
    line_gap: f32 = 6,
    /// Space before the indentation, in pixels.
    line_padding: f32 = 4,
};

/// A style that reads on a dark background, every line in roop's default font: a plugin with
/// a monospace font passes it as `code_font`.
pub const default_style = Style{
    .text_font = roop.default_font,
    .code_font = roop.default_font,
    .highlight = ui.rgb(13, 110, 190),
    .hover = ui.rgb(68, 68, 68),
    .dimmed = ui.rgb(190, 190, 190),
};

// The names the list's elements are known by, each with its line's key and `RecordOptions.salt`.
const list_name = Atom.from("outline.list");
const above_name = Atom.from("outline.above");
const below_name = Atom.from("outline.below");
const line_name = Atom.from("outline.line");
const indent_name = Atom.from("outline.indent");
const chevron_name = Atom.from("outline.chevron");
const text_name = Atom.from("outline.text");
const detail_name = Atom.from("outline.detail");

/// Records the list as a column as wide as its parent and `options.view_height` tall,
/// scrolled by `cursor.scroll`: only the shown lines in view, with a spacer above and below
/// that keep the list's whole height, so a list of any length costs what its view holds. A
/// line is its indentation by depth, a chevron when it is expandable (right while collapsed,
/// down while open), its text in its colour and font, and its detail dimmed; the cursor's line
/// is filled with the style's `highlight`. A click on a line sends `options.click_tag`, one on a
/// chevron `options.toggle_tag`, each with the line's key; the wheel over the list sends
/// `options.scroll_tag`. A line's elements are known by its key (and `options.salt`), so the
/// pointer's hover follows the line across rebuilds. `shown` is what `visible` gave of `lines`
/// and `cursor` is settled against them. The lines' strings are borrowed until the tree's last
/// commit returns. The tree must have room for `elementCount` of the lines the view holds.
pub fn record(tree: *ui.Tree, lines: []const Line, shown: []const u32, cursor: Cursor, options: RecordOptions) void {
    const list_open = tree.beginRect(.{ list_name, options.salt }, .{
        .axis = .vertical,
        .size = .{ .w = .fill, .h = .{ .fixed = options.view_height } },
        .clip_content = true,
        .scroll = .vertical,
        .scroll_offset = cursor.scroll,
    });
    if (!list_open) return;
    defer tree.endRect();
    const scroll_target = tree.target(options.inbox, options.scroll_tag, {});
    tree.onScroll(scroll_target);
    if (shown.len == 0 or options.line_height <= 0) return;

    const window = windowOf(shown.len, cursor.scroll, options.line_height, options.view_height);
    const first: f32 = @floatFromInt(window.first);
    const after: f32 = @floatFromInt(shown.len - window.end);
    tree.rect(.{ above_name, options.salt }, .{ .size = .{ .w = .fill, .h = .{ .fixed = first * options.line_height } } });
    for (shown[window.first..window.end], window.first..) |line_index, position| {
        const is_cursor = position == cursor.index;
        recordLine(tree, &lines[line_index], is_cursor, options);
    }
    tree.rect(.{ below_name, options.salt }, .{ .size = .{ .w = .fill, .h = .{ .fixed = after * options.line_height } } });
}

/// The most elements `record` adds to a tree for a view that holds `view_lines` lines (the
/// view's height over a line's, rounded up): size the tree for these and the owner's own.
pub fn elementCount(view_lines: u32) u32 {
    const list_elements = 2 + 2; // the list, its two spacers
    const line_elements = 2 + 1 + 1 + 1 + 1; // the line, its indentation, chevron, text and detail
    // A view scrolled part of a line down shows a line more than it holds.
    return list_elements + (view_lines + 1) * line_elements;
}

/// The shown lines in view: positions `first` up to, and not including, `end`.
const Window = struct { first: usize, end: usize };

fn windowOf(shown_count: usize, scroll: f32, line_height: f32, view_height: f32) Window {
    const top = if (std.math.isFinite(scroll)) @max(scroll, 0) else 0;
    const lines_above: f32 = @floor(top / line_height);
    const first: usize = @min(shown_count, floatToCount(lines_above));
    // As many as `elementCount` makes room for: a line more than the view holds.
    const view_lines: f32 = @ceil(@max(view_height, 0) / line_height);
    const in_view = floatToCount(view_lines) + 1;
    const end = @min(shown_count, first + in_view);
    return .{ .first = first, .end = end };
}

fn floatToCount(value: f32) usize {
    const most: f32 = @floatFromInt(std.math.maxInt(u32));
    return @intFromFloat(@min(value, most));
}

/// A line's row: its indentation, its chevron (or the room for one), its text and its detail.
fn recordLine(tree: *ui.Tree, line: *const Line, is_cursor: bool, options: RecordOptions) void {
    const style = options.style;
    const key_bytes = std.mem.asBytes(&line.key);
    const extra = std.hash.Wyhash.hash(options.salt, key_bytes);
    const line_open = tree.beginRect(.{ line_name, extra }, .{
        .axis = .horizontal,
        .cross_align = .center,
        .size = .{ .w = .fill, .h = .{ .fixed = options.line_height } },
        .padding = 0,
        .gap = style.line_gap,
        .bg = if (is_cursor) style.highlight else null,
        .bg_hover = if (is_cursor) style.highlight else style.hover,
        .clip_content = true,
    });
    if (!line_open) return;
    defer tree.endRect();
    const click_target = tree.target(options.inbox, options.click_tag, line.key);
    tree.onClick(click_target, .left);
    tree.trackHover("");

    const depth: f32 = @floatFromInt(line.depth);
    const indent_width = style.line_padding + depth * style.indent;
    tree.rect(.{ indent_name, extra }, .{ .size = .{ .w = .{ .fixed = indent_width }, .h = .fill } });
    const chevron_size: ui.Size = .{ .w = .{ .fixed = style.chevron_width }, .h = .fill };
    if (line.expandable) {
        const is_collapsed = std.mem.indexOfScalar(u64, options.collapsed, line.key) != null;
        const chevron = tree.frame_allocator.allocator.create(marks.Chevron) catch @panic("ui outline: OOM recording a chevron");
        chevron.* = .{ .direction = if (is_collapsed) .right else .down, .color = style.dimmed };
        tree.custom(.{ chevron_name, extra }, chevron, .{ .size = chevron_size });
        const toggle_target = tree.target(options.inbox, options.toggle_tag, line.key);
        tree.onClick(toggle_target, .left);
        tree.trackHover(if (is_collapsed) "Show this section" else "Hide this section");
    } else {
        tree.rect(.{ chevron_name, extra }, .{ .size = chevron_size });
    }
    const font = switch (line.font) {
        .text => style.text_font,
        .code => style.code_font,
    };
    tree.text(.{ text_name, extra }, line.text, .{ .font = font, .color = line.colour });
    if (line.detail.len == 0) return;
    tree.text(.{ detail_name, extra }, line.detail, .{ .font = font, .color = style.dimmed });
}

/// The index of the line with `key`, or null when none has it.
fn indexOfKey(lines: []const Line, key: u64) ?u32 {
    for (lines, 0..) |line, index| {
        if (line.key == key) return @intCast(index);
    }
    return null;
}

/// The position in `shown` of the line at `line_index`, or, where it is hidden, of the
/// nearest line whose section holds it that is shown; null when neither is.
fn shownAtOrAbove(lines: []const Line, shown: []const u32, line_index: u32) ?u32 {
    if (positionOf(shown, line_index)) |position| return position;
    var ancestor = line_index;
    while (parentOf(lines, ancestor)) |parent| {
        if (positionOf(shown, parent)) |position| return position;
        ancestor = parent;
    }
    return null;
}

/// The position of `line_index` in `shown`, which is ascending, or null when it is not shown.
fn positionOf(shown: []const u32, line_index: u32) ?u32 {
    var low: usize = 0;
    var high: usize = shown.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (shown[middle] == line_index) return @intCast(middle);
        if (shown[middle] < line_index) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    return null;
}

/// Which lines a scan from the cursor stops at, by their depth against the cursor's.
const Stop = enum { same_or_shallower, shallower };

fn stopsAt(line_depth: u8, depth: u8, stop: Stop) bool {
    return switch (stop) {
        .same_or_shallower => line_depth <= depth,
        .shallower => line_depth < depth,
    };
}

/// The position of the first shown line after `from` that `stop` stops at, or null.
fn shownAfter(lines: []const Line, shown: []const u32, from: u32, depth: u8, stop: Stop) ?u32 {
    var position = from + 1;
    while (position < shown.len) : (position += 1) {
        const line_depth = lines[shown[position]].depth;
        if (stopsAt(line_depth, depth, stop)) return position;
    }
    return null;
}

/// The position of the nearest shown line before `from` that `stop` stops at, or null.
fn shownBefore(lines: []const Line, shown: []const u32, from: u32, depth: u8, stop: Stop) ?u32 {
    var position = from;
    while (position > 0) {
        position -= 1;
        const line_depth = lines[shown[position]].depth;
        if (stopsAt(line_depth, depth, stop)) return position;
    }
    return null;
}

const test_colour = ui.rgb(255, 255, 255);

fn testLine(depth: u8, key: u64, expandable: bool) Line {
    return .{ .depth = depth, .kind = depth, .key = key, .text = "line", .colour = test_colour, .expandable = expandable };
}

/// A status list: two headings, the first with two files, the first file with two hunks.
const status_lines = [_]Line{
    testLine(0, 1, true), // 0 Unstaged changes
    testLine(1, 10, true), // 1 file a
    testLine(2, 100, true), // 2 hunk a1
    testLine(3, 1000, false), // 3
    testLine(3, 1001, false), // 4
    testLine(2, 101, true), // 5 hunk a2
    testLine(3, 1010, false), // 6
    testLine(1, 11, true), // 7 file b
    testLine(2, 110, true), // 8 hunk b1
    testLine(3, 1100, false), // 9
    testLine(0, 2, true), // 10 Staged changes
    testLine(1, 20, true), // 11 file c
};

fn expectShown(collapsed: []const u64, expected: []const u32) !void {
    var out: [status_lines.len]u32 = undefined;
    const shown = visible(&status_lines, collapsed, &out);
    try std.testing.expectEqualSlices(u32, expected, shown);
}

/// The cursor on the shown line with `key`, settled against `lines` with nothing collapsed.
fn cursorOn(lines: []const Line, key: u64) Cursor {
    var out: [status_lines.len]u32 = undefined;
    const shown = visible(lines, &.{}, &out);
    for (shown, 0..) |line_index, position| {
        if (lines[line_index].key == key) return .{ .key = key, .index = @intCast(position) };
    }
    unreachable;
}

fn moved(from_key: u64, step: Step) u64 {
    var out: [status_lines.len]u32 = undefined;
    const shown = visible(&status_lines, &.{}, &out);
    const cursor = cursorOn(&status_lines, from_key);
    const result = move(&status_lines, shown, cursor, step, 1);
    return result.key;
}

test "collapsing a heading hides its children and not its siblings" {
    try expectShown(&.{1}, &.{ 0, 10, 11 });
    try expectShown(&.{10}, &.{ 0, 1, 7, 8, 9, 10, 11 });
    try expectShown(&.{ 999, 100 }, &.{ 0, 1, 2, 5, 6, 7, 8, 9, 10, 11 });
}

test "next skips hidden lines" {
    var out: [status_lines.len]u32 = undefined;
    const shown = visible(&status_lines, &.{10}, &out);
    const cursor = Cursor{ .key = 10, .index = 1 };
    const next = move(&status_lines, shown, cursor, .next, 1);
    try std.testing.expectEqual(Cursor{ .key = 11, .index = 2 }, next);
}

test "a cursor whose line went lands on the line that took its place" {
    var out: [status_lines.len]u32 = undefined;
    // File a staged: the list is built again without it and its hunks.
    const without_a = [_]Line{ status_lines[0], status_lines[7], status_lines[8], status_lines[9], status_lines[10], status_lines[11] };
    const shown_without_a = visible(&without_a, &.{}, &out);
    const on_a = cursorOn(&status_lines, 10);
    try std.testing.expectEqual(Cursor{ .key = 11, .index = 1 }, settle(&without_a, shown_without_a, on_a));
    // A line that stayed is found where it is now.
    const on_b = cursorOn(&status_lines, 11);
    try std.testing.expectEqual(Cursor{ .key = 11, .index = 1 }, settle(&without_a, shown_without_a, on_b));

    // The last line went: the cursor is on the new last line.
    const without_c = status_lines[0..11];
    const shown_without_c = visible(without_c, &.{}, &out);
    const on_c = cursorOn(&status_lines, 20);
    try std.testing.expectEqual(Cursor{ .key = 2, .index = 10 }, settle(without_c, shown_without_c, on_c));

    // The line is there but its file was collapsed: the cursor is on the file.
    const shown_collapsed = visible(&status_lines, &.{10}, &out);
    const on_diff = cursorOn(&status_lines, 1000);
    try std.testing.expectEqual(Cursor{ .key = 10, .index = 1 }, settle(&status_lines, shown_collapsed, on_diff));

    try std.testing.expectEqual(Cursor{}, settle(&.{}, &.{}, on_diff));
}

test "sibling and parent steps follow the sections" {
    try std.testing.expectEqual(@as(u64, 101), moved(100, .next_sibling));
    try std.testing.expectEqual(@as(u64, 11), moved(101, .next_sibling));
    try std.testing.expectEqual(@as(u64, 10), moved(100, .previous_sibling));
    try std.testing.expectEqual(@as(u64, 100), moved(101, .previous_sibling));
    try std.testing.expectEqual(@as(u64, 100), moved(1001, .parent));
    try std.testing.expectEqual(@as(u64, 2), moved(1, .next_sibling));
    try std.testing.expectEqual(Section{ .first = 1, .end = 7 }, sectionOf(&status_lines, 1));
    try std.testing.expectEqual(@as(?u32, 2), parentOf(&status_lines, 4));
    try std.testing.expectEqual(@as(?u32, null), parentOf(&status_lines, 10));
}

test "scrollTo scrolls just enough to show the cursor" {
    var shown: [100]u32 = undefined;
    for (&shown, 0..) |*line_index, position| line_index.* = @intCast(position);
    const line_height: f32 = 10;
    const view_height: f32 = 50;
    const below = Cursor{ .index = 10, .scroll = 0 };
    try std.testing.expectEqual(@as(f32, 60), scrollTo(&shown, below, line_height, view_height));
    const in_view = Cursor{ .index = 4, .scroll = 15 };
    try std.testing.expectEqual(@as(f32, 15), scrollTo(&shown, in_view, line_height, view_height));
    const above = Cursor{ .index = 0, .scroll = 30 };
    try std.testing.expectEqual(@as(f32, 0), scrollTo(&shown, above, line_height, view_height));
    const negative = Cursor{ .index = 0, .scroll = -20 };
    try std.testing.expectEqual(@as(f32, 0), scrollTo(&shown, negative, line_height, view_height));
    const past_end = Cursor{ .index = 99, .scroll = 5000 };
    try std.testing.expectEqual(@as(f32, 950), scrollTo(&shown, past_end, line_height, view_height));
}

test "clampScroll keeps a wheel's scroll within the list" {
    var shown: [100]u32 = undefined;
    for (&shown, 0..) |*line_index, position| line_index.* = @intCast(position);
    const line_height: f32 = 10;
    const view_height: f32 = 50;
    try std.testing.expectEqual(@as(f32, 125), clampScroll(&shown, 125, line_height, view_height));
    try std.testing.expectEqual(@as(f32, 0), clampScroll(&shown, -30, line_height, view_height));
    try std.testing.expectEqual(@as(f32, 950), clampScroll(&shown, 4000, line_height, view_height));
    try std.testing.expectEqual(@as(f32, 0), clampScroll(shown[0..3], 20, line_height, view_height));
    try std.testing.expectEqual(@as(f32, 0), clampScroll(&shown, std.math.nan(f32), line_height, view_height));
}

test "a wheel scroll that hides the cursor brings it to the nearest line in view" {
    var out: [status_lines.len]u32 = undefined;
    const shown = visible(&status_lines, &.{}, &out);
    const line_height: f32 = 10;
    const view_height: f32 = 30;
    // Lines 4 to 6 are whole in view at 40; at 35 line 3 is cut and 4 to 6 are whole.
    const above = Cursor{ .key = 1, .index = 0, .scroll = 35 };
    try std.testing.expectEqual(Cursor{ .key = 1001, .index = 4, .scroll = 35 }, cursorInView(&status_lines, shown, above, line_height, view_height));
    const below = Cursor{ .key = 2, .index = 10, .scroll = 40 };
    try std.testing.expectEqual(Cursor{ .key = 1010, .index = 6, .scroll = 40 }, cursorInView(&status_lines, shown, below, line_height, view_height));
    const in_view = Cursor{ .key = 101, .index = 5, .scroll = 40 };
    try std.testing.expectEqual(in_view, cursorInView(&status_lines, shown, in_view, line_height, view_height));
}

test "the window of lines drawn reaches the bottom of the view" {
    // Scrolled half a line: lines 0 to 20 show, the first and the last in part.
    const half = windowOf(1000, 8, 16, 320);
    try std.testing.expectEqual(Window{ .first = 0, .end = 21 }, half);
    // Scrolled to the end of the list, the window ends with it.
    const end = windowOf(30, 160, 16, 320);
    try std.testing.expectEqual(Window{ .first = 10, .end = 30 }, end);
}

test "record draws only the lines in view" {
    var mem: memory_mod.Memory = undefined;
    mem.init(std.testing.allocator);
    defer mem.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&mem);
    defer atoms.deinit();
    var frame_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frame_arena.deinit();
    const frame_allocator = frame_arena.allocator();

    const line_count = 50_000;
    const lines = try frame_allocator.alloc(Line, line_count);
    for (lines, 0..) |*line, index| {
        const depth: u8 = @intCast(index % 4);
        line.* = .{ .depth = depth, .kind = depth, .key = index, .text = "+ added", .detail = "3", .colour = test_colour, .font = .code, .expandable = depth < 3 };
    }
    const out = try frame_allocator.alloc(u32, line_count);
    const collapsed = [_]u64{ 5, 9 };
    const shown = visible(lines, &collapsed, out);

    const line_height: f32 = 16;
    const view_lines = 20;
    const view_height = line_height * view_lines;
    const middle = Cursor{ .key = lines[shown[shown.len / 2]].key, .index = @intCast(shown.len / 2), .scroll = 0 };
    const cursor = Cursor{ .key = middle.key, .index = middle.index, .scroll = scrollTo(shown, middle, line_height, view_height) - line_height / 2 };

    const capacity = elementCount(view_lines);
    var tree = try ui.Tree.init(.{ .allocator = frame_allocator }, &atoms, capacity);
    const options = RecordOptions{
        .inbox = Atom.from("test.inbox"),
        .click_tag = Atom.from("test.click"),
        .toggle_tag = Atom.from("test.toggle"),
        .scroll_tag = Atom.from("test.scroll"),
        .collapsed = &collapsed,
        .view_height = view_height,
        .line_height = line_height,
    };
    record(&tree, lines, shown, cursor, options);
    try tree.validateCommands();
    // The list and its two spacers, and six elements a line for the lines of the view and the
    // one it shows a part of.
    const list_elements = 4;
    const line_elements = 6;
    try std.testing.expectEqual(@as(usize, list_elements + (view_lines + 1) * line_elements), tree.count);
    try std.testing.expect(tree.count <= capacity);
}
