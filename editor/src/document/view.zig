//! A document's page drawn (`document.zig` lays it out): only the blocks in view, and of a
//! table only its rows in view, each table by the SDK's grid inline, a group's table its group's
//! rows alone (`ui.grid.RenderContext.chosen_rows`). A heading is a line with a fold mark and no
//! stars, a group's with no rows followed by a dim `(empty)`, a paragraph or a line not read a
//! line of text, a run of terms pairs aligned on the widest term in view, a table not published
//! a dim line naming it. Its lines
//! look as the outline's do (`ui.outline`): its fonts, its cursor's fill, its fold mark.
//!
//! The owner's draw lays its page out as its kernel does, from what it reads through the
//! tables, settles a copy of the cursor its kernel left, and records:
//!
//!     const page = try document.layout(arena, parsed, published, folded, metrics);
//!     const cursor = document.settle(page, document.cursorOf(state));
//!     var tree = try ui.Tree.init(scratch, atoms, view.elementCount(view_height, metrics));
//!     view.record(&tree, page, cursor, .{ .inbox = inbox, .document = name, .tags = tags,
//!         .view_width = w, .view_height = h, .scratch = scratch,
//!         .style = style.documentStyle() });
//!
//! A click on a heading or a line, a click on a row (the grid's `cell_click`), a fold mark's
//! click and the wheel go to the owner's inbox, for `document.take`. Nothing here writes a
//! table or keeps anything between calls.
const std = @import("std");
const mesha = @import("mesha");
const Atom = mesha.Atom;
const Table = mesha.Table;
const memory_mod = mesha.memory;
const roop = mesha.roop;
const ui = mesha.ui;
const grid = ui.grid;
const marks = ui.marks;
const outline = ui.outline;
const document = @import("document.zig");
const sources = @import("sources.zig");

/// How a page is painted: the outline's style for its lines, the grid's for its tables, and the
/// colours of its texts. The caller's, from its theme (the editor's `style.documentStyle()`), or
/// `default_style`.
pub const Style = struct {
    /// The lines' fonts, cursor fill, hover, fold mark colour and metrics.
    outline: outline.Style,
    /// The tables' look.
    grid: grid.Style,
    /// A heading's text.
    heading: ui.Color,
    /// A paragraph's, a term's text's and a line's not read.
    text: ui.Color,
    /// A term, a table not published, and a group's `(empty)`.
    dimmed: ui.Color,
    /// The text of a table whose publisher could not read what it was to hold
    /// (`sources.SourceState.unread`).
    error_text: ui.Color,
    /// The fill of the selected row of such a table, in place of the grid's selection, so its
    /// text in `error_text` reads.
    error_selection: ui.Color,
    /// Space after the widest term of a run, in pixels.
    term_gap: f32 = 12,
};

/// A style that reads on a dark background, in roop's default font.
pub const default_style: Style = .{
    .outline = outline.default_style,
    .grid = grid.default_style,
    .heading = ui.rgb(120, 195, 255),
    .text = ui.rgb(240, 240, 240),
    .dimmed = ui.rgb(190, 190, 190),
    .error_text = ui.rgb(255, 84, 112),
    .error_selection = ui.rgb(84, 28, 40),
};

/// How `record` draws a page and where what is done to it goes. The owner's, made where it
/// draws; borrowed for the call.
pub const RecordOptions = struct {
    /// The owner's inbox, where the page's clicks and wheel go.
    inbox: Atom,
    /// The document's name, which the page's messages carry (`document.Click`), as `take` is
    /// given it.
    document: Atom,
    /// The tags of the page's messages.
    tags: document.Tags,
    /// The width of the view, in pixels: the tables are as wide, less their indentation.
    view_width: f32,
    /// The height of the view, in pixels: the page is drawn this tall.
    view_height: f32,
    /// The frame's scratch, which the grid copies its texts into; it lasts through the tree's
    /// last commit.
    scratch: memory_mod.Scratch,
    /// How it is painted.
    style: Style = default_style,
    /// What measures the tables' text, so each table's columns but its fill column are as wide
    /// as what they hold (`ui.grid.fitColumns`), the fill column the rest; the owner's, from the
    /// context it draws into (`ui.grid.TextMeasure.ofContext`). Null: the grid's even shares,
    /// the last column filling.
    measure: ?grid.TextMeasure = null,
};

/// The names a page's elements are known by, each with a block's key and a line in it: an owner
/// puts them among its system's `names`, so the inspector and the hover name them.
pub const element_names = [_][]const u8{
    "document.page",        "document.above",       "document.below",        "document.line",
    "document.indent",      "document.mark",        "document.text",         "document.terms",
    "document.term_column", "document.said_column", "document.term",         "document.said",
    "document.gap",         "document.table",       "document.table_column", "document.note",
};
const page_name = Atom.from("document.page");
const above_name = Atom.from("document.above");
const below_name = Atom.from("document.below");
const line_name = Atom.from("document.line");
const indent_name = Atom.from("document.indent");
const mark_name = Atom.from("document.mark");
const text_name = Atom.from("document.text");
const terms_name = Atom.from("document.terms");
const term_column_name = Atom.from("document.term_column");
const said_column_name = Atom.from("document.said_column");
const term_name = Atom.from("document.term");
const said_name = Atom.from("document.said");
const gap_name = Atom.from("document.gap");
const table_name = Atom.from("document.table");
const table_column_name = Atom.from("document.table_column");
const note_name = Atom.from("document.note");

/// Records `layout` as a column as wide as its parent and `options.view_height` tall, scrolled by
/// `cursor.scroll`, `cursor` settled against `layout`: of its blocks only those in view, with a
/// spacer above and below that keep the page's height, so a page of any length costs what its
/// view holds. A table is drawn by `ui.grid.render` inline, with the rows of it in view (of a
/// group's table, of its group's rows), a grid a chunk of `document.rows_a_chunk` rows (so a
/// view of any height shows every row in it), its header above the first when that is in view,
/// its columns the page's, the cursor's row drawn selected in it and no row in the others. The tree must have room for
/// `elementCount(options.view_height, metrics)`. Writes nothing.
pub fn record(tree: *ui.Tree, layout: document.Layout, cursor: document.Cursor, options: RecordOptions) void {
    const page_open = tree.beginRect(.{ page_name, options.document.value() }, .{
        .axis = .vertical,
        .size = .{ .w = .fill, .h = .{ .fixed = options.view_height } },
        .clip_content = true,
        .scroll = .vertical,
        .scroll_offset = cursor.scroll,
    });
    if (!page_open) return;
    defer tree.endRect();
    const wheel = tree.target(options.inbox, options.tags.wheel, document.Click{ .document = options.document });
    tree.onScroll(wheel);
    if (layout.shown.len == 0) return;

    const view_top = @max(cursor.scroll, 0);
    const view_bottom = view_top + options.view_height;
    var drawn_to: ?f32 = null;
    var position: usize = 0;
    while (position < layout.shown.len) : (position += 1) {
        const block = layout.blocks[layout.shown[position]];
        const bottom = block.top + block.height;
        if (bottom <= view_top) continue;
        if (block.top >= view_bottom) break;
        const piece_top = switch (block.kind) {
            .table => pieceTopOfTable(block, view_top),
            else => block.top,
        };
        if (drawn_to == null) {
            tree.rect(.{ above_name, options.document.value() }, .{ .size = .{ .w = .fill, .h = .{ .fixed = piece_top } } });
        }
        switch (block.kind) {
            .heading, .paragraph, .text, .unpublished => recordLine(tree, block, cursor, options),
            // A group block is never shown: its groups are the headings and tables after it.
            .group => {},
            .table => recordTable(tree, block, cursor, view_top, view_bottom, options),
            .term => {
                // The terms side by side in view, as one piece aligned on the widest.
                var last = position;
                while (last + 1 < layout.shown.len) {
                    const next = layout.blocks[layout.shown[last + 1]];
                    if (next.kind != .term or next.top >= view_bottom) break;
                    last += 1;
                }
                recordTerms(tree, layout, layout.shown[position .. last + 1], cursor, options);
                position = last;
            },
        }
        // A line is drawn whole, a table to its last row in view.
        const drawn_block = layout.blocks[layout.shown[position]];
        drawn_to = if (drawn_block.kind == .table) tableBottom(drawn_block, view_bottom) else drawn_block.top + drawn_block.height;
    }
    const end = drawn_to orelse return;
    const rest = @max(layout.height - end, 0);
    tree.rect(.{ below_name, options.document.value() }, .{ .size = .{ .w = .fill, .h = .{ .fixed = rest } } });
}

/// The most elements `record` adds to a tree for a view `view_height` tall, measured by
/// `metrics`: size the tree for these and the owner's own.
pub fn elementCount(view_height: f32, metrics: document.Metrics) u32 {
    const shortest = @min(metrics.line_height, document.table_row_height);
    const stops_in_view = stopsIn(view_height, shortest) + 1;
    // A piece of the page: a run of terms' three elements, or a table's four and its grid's
    // chrome at the most columns a grid draws.
    const piece_elements = 4 + grid.elementCount(0, grid.max_visible_columns);
    // A stop: a line's four elements, a term's six, or a grid's row at the most columns.
    const row_elements = grid.elementCount(1, grid.max_visible_columns) - grid.elementCount(0, grid.max_visible_columns);
    const term_elements = 6;
    const page_elements = 3; // the page and its two spacers
    return page_elements + (stops_in_view + 1) * piece_elements + stops_in_view * @max(row_elements, term_elements);
}

fn stopsIn(view_height: f32, stop_height: f32) u32 {
    if (stop_height <= 0) return 1;
    const most: f32 = @floatFromInt(std.math.maxInt(u16));
    const count = @ceil(@max(view_height, 0) / stop_height);
    return @intFromFloat(@min(count, most));
}

fn elementExtra(options: RecordOptions, key: u64, row: u32) u64 {
    var hasher = std.hash.Wyhash.init(options.document.value());
    hasher.update(std.mem.asBytes(&key));
    hasher.update(std.mem.asBytes(&row));
    return hasher.final();
}

/// Whether the cursor is on `block`'s stop `row`.
fn holdsCursor(block: document.Block, cursor: document.Cursor, row: u32) bool {
    return cursor.block == block.key and cursor.row == row;
}

/// The indentation of a line `depth` deep: the outline's padding, its indent a depth.
fn indentOf(outline_style: outline.Style, depth: u8) f32 {
    const levels: f32 = @floatFromInt(depth);
    return outline_style.line_padding + levels * outline_style.indent;
}

/// Where the text of a line `depth` deep begins: past its indentation, the room for a fold mark
/// and the gaps of a line between them, so a term's text and a table line up with a line's.
fn textIndentOf(outline_style: outline.Style, depth: u8) f32 {
    return indentOf(outline_style, depth) + outline_style.chevron_width + 2 * outline_style.line_gap;
}

/// A heading, a paragraph, a line not read or a table not published: its indentation, a fold
/// mark (a heading's) or the room for one, and its text.
fn recordLine(tree: *ui.Tree, block: document.Block, cursor: document.Cursor, options: RecordOptions) void {
    const look = options.style;
    const lines = look.outline;
    const extra = elementExtra(options, block.key, 0);
    const is_cursor = holdsCursor(block, cursor, 0);
    const line_open = tree.beginRect(.{ line_name, extra }, .{
        .axis = .horizontal,
        .cross_align = .center,
        .size = .{ .w = .fill, .h = .{ .fixed = block.height } },
        .gap = lines.line_gap,
        .bg = if (is_cursor) lines.highlight else null,
        .bg_hover = if (is_cursor) lines.highlight else lines.hover,
        .clip_content = true,
    });
    if (!line_open) return;
    defer tree.endRect();
    const click: document.Click = .{ .document = options.document, .block = block.key };
    tree.onClick(tree.target(options.inbox, options.tags.click, click), .left);
    tree.trackHover("");
    const indent = indentOf(lines, block.depth);
    tree.rect(.{ indent_name, extra }, .{ .size = .{ .w = .{ .fixed = indent }, .h = .fill } });
    const mark_size: ui.Size = .{ .w = .{ .fixed = lines.chevron_width }, .h = .fill };
    if (block.kind == .heading) {
        const chevron = tree.frame_allocator.allocator.create(marks.Chevron) catch @panic("document: OOM recording a fold mark");
        chevron.* = .{ .direction = if (block.folded) .right else .down, .color = lines.dimmed };
        tree.custom(.{ mark_name, extra }, chevron, .{ .size = mark_size });
        tree.onClick(tree.target(options.inbox, options.tags.toggle, click), .left);
        tree.trackHover(if (block.folded) "Show this section" else "Hide this section");
    } else {
        tree.rect(.{ mark_name, extra }, .{ .size = mark_size });
    }
    const colour = switch (block.kind) {
        .heading => look.heading,
        .unpublished => look.dimmed,
        else => look.text,
    };
    tree.text(.{ text_name, extra }, block.text, .{ .font = lines.text_font, .color = colour });
    // A group's heading with no rows says so, dim, after its text.
    if (block.kind == .heading and block.detail.len != 0) {
        tree.text(.{ note_name, extra }, block.detail, .{ .font = lines.text_font, .color = look.dimmed });
    }
}

/// A run of terms in view, `run` their indices in the layout's blocks: two columns, the terms
/// as wide as the widest, then their texts.
fn recordTerms(tree: *ui.Tree, layout: document.Layout, run: []const u32, cursor: document.Cursor, options: RecordOptions) void {
    const look = options.style;
    const lines = look.outline;
    const first = layout.blocks[run[0]];
    const run_extra = elementExtra(options, first.key, 0);
    const count: f32 = @floatFromInt(run.len);
    const run_open = tree.beginRect(.{ terms_name, run_extra }, .{ .axis = .horizontal, .size = .{ .w = .fill, .h = .{ .fixed = count * layout.line_height } } });
    if (!run_open) return;
    defer tree.endRect();
    if (tree.beginRect(.{ term_column_name, run_extra }, .{ .axis = .vertical, .size = .{ .w = .hug, .h = .fill } })) {
        defer tree.endRect();
        for (run) |index| {
            const block = layout.blocks[index];
            const extra = elementExtra(options, block.key, 0);
            if (!termCell(tree, .{ term_name, extra }, block, cursor, options, .term)) continue;
            defer tree.endRect();
            const indent = textIndentOf(lines, block.depth);
            tree.rect(.{ indent_name, extra }, .{ .size = .{ .w = .{ .fixed = indent }, .h = .fill } });
            tree.text(.{ text_name, extra }, block.text, .{ .font = lines.text_font, .color = look.dimmed });
            tree.rect(.{ gap_name, extra }, .{ .size = .{ .w = .{ .fixed = look.term_gap }, .h = .fill } });
        }
    }
    if (tree.beginRect(.{ said_column_name, run_extra }, .{ .axis = .vertical, .size = .{ .w = .fill, .h = .fill } })) {
        defer tree.endRect();
        for (run) |index| {
            const block = layout.blocks[index];
            const extra = elementExtra(options, block.key, 1);
            if (!termCell(tree, .{ said_name, extra }, block, cursor, options, .said)) continue;
            defer tree.endRect();
            tree.text(.{ text_name, extra }, block.detail, .{ .font = lines.text_font, .color = look.text });
        }
    }
}

/// Which half of a term's line a cell is.
const TermHalf = enum { term, said };

/// Opens a cell of a term's line, filled while the cursor is on it, clicking to it; false when
/// it took no children.
fn termCell(tree: *ui.Tree, id: anytype, block: document.Block, cursor: document.Cursor, options: RecordOptions, half: TermHalf) bool {
    const lines = options.style.outline;
    const is_cursor = holdsCursor(block, cursor, 0);
    const open = tree.beginRect(id, .{
        .axis = .horizontal,
        .cross_align = .center,
        .size = .{ .w = .fill, .h = .{ .fixed = block.height } },
        .bg = if (is_cursor) lines.highlight else null,
        .bg_hover = if (is_cursor) lines.highlight else lines.hover,
        .clip_content = half == .said,
    });
    if (!open) return false;
    const click: document.Click = .{ .document = options.document, .block = block.key };
    tree.onClick(tree.target(options.inbox, options.tags.click, click), .left);
    tree.trackHover("");
    return true;
}

/// The rows of a table block in view: from the first whose bottom is below the view's top, up
/// to the last whose top is above its bottom.
const RowsInView = struct { first: u32, count: u32, header: bool };

fn rowsInView(block: document.Block, view_top: f32, view_bottom: f32) RowsInView {
    const table = block.table.?;
    const rows_top = block.top + table.headerHeight();
    const above: f32 = @floor(@max(view_top - rows_top, 0) / document.table_row_height);
    const first: u32 = @intFromFloat(@min(above, @as(f32, @floatFromInt(table.rows))));
    const reach: f32 = @ceil(@max(view_bottom - rows_top, 0) / document.table_row_height);
    const end: u32 = @intFromFloat(@min(reach, @as(f32, @floatFromInt(table.rows))));
    return .{ .first = first, .count = end -| first, .header = table.header != .hidden and rows_top > view_top };
}

/// Where a table block's piece begins: its top with its header in view, else its first row's in
/// view.
fn pieceTopOfTable(block: document.Block, view_top: f32) f32 {
    const in_view = rowsInView(block, view_top, view_top);
    if (in_view.header) return block.top;
    const first: f32 = @floatFromInt(in_view.first);
    return block.top + block.table.?.headerHeight() + first * document.table_row_height;
}

/// Where a table block's piece ends: after its last row in view.
fn tableBottom(block: document.Block, view_bottom: f32) f32 {
    const rows_top = block.top + block.table.?.headerHeight();
    const in_view = rowsInView(block, block.top, view_bottom);
    const end: f32 = @floatFromInt(in_view.first + in_view.count);
    return rows_top + end * document.table_row_height;
}

/// A table block's rows in view, by the grid inline, indented as a line under its heading.
fn recordTable(tree: *ui.Tree, block: document.Block, cursor: document.Cursor, view_top: f32, view_bottom: f32, options: RecordOptions) void {
    const table = block.table.?;
    const look = options.style;
    const lines = look.outline;
    const in_view = rowsInView(block, view_top, view_bottom);
    const extra = elementExtra(options, block.key, 0);
    const header_height: f32 = if (in_view.header) document.table_header_height else 0;
    const rows: f32 = @floatFromInt(in_view.count);
    const piece_height = header_height + rows * document.table_row_height;
    const piece_open = tree.beginRect(.{ table_name, extra }, .{ .axis = .horizontal, .size = .{ .w = .fill, .h = .{ .fixed = piece_height } } });
    if (!piece_open) return;
    defer tree.endRect();
    const indent = textIndentOf(lines, block.depth);
    tree.rect(.{ indent_name, extra }, .{ .size = .{ .w = .{ .fixed = indent }, .h = .fill } });
    const width = @max(options.view_width - indent, 0);
    if (!tree.beginRect(.{ table_column_name, extra }, .{ .axis = .vertical, .size = .{ .w = .{ .fixed = width }, .h = .fill } })) return;
    defer tree.endRect();
    var grid_style = look.grid;
    if (table.state == .unread) {
        grid_style.text = look.error_text;
        grid_style.selected_bg = look.error_selection;
    }
    const selected: ?u32 = if (cursor.block == block.key) selected: {
        const handle = table.rowAtPlace(cursor.row) orelse break :selected null;
        break :selected handle.row;
    } else null;
    // One fit for the table, so its pieces' columns line up and keep their widths as it scrolls.
    const fitted: ?grid.Fitted = if (options.measure) |measure| fitTable(table, width, measure, grid_style, tree.atoms, options.scratch) else null;
    // A grid a chunk, so that no grid is asked for more rows than it draws; the header above
    // the first, when it is in view. A piece of the header alone is one grid of no rows.
    const end = in_view.first + in_view.count;
    var first = in_view.first;
    var header = in_view.header;
    while (true) {
        const chunk = first / document.rows_a_chunk;
        const chunk_end = @min(end, (chunk + 1) * document.rows_a_chunk);
        const count = chunk_end -| first;
        var presentation = table.presentation();
        if (!header) presentation.header = .hidden;
        var unkept: UnkeptGrid = .{};
        const drawing: grid.RenderContext = .{
            .inbox = options.inbox,
            .presentation = presentation,
            .style = grid_style,
            .columns = table.columns,
            .chosen_rows = table.lines,
            .fitted = fitted,
            .inline_rows = .{ .first = first, .count = count, .selected = selected },
        };
        const instance = document.instanceOf(options.document, block.key, chunk);
        const height = grid.inlineHeight(count, presentation);
        _ = grid.render(unkept.state(table.table), instance, .table, tree, table.table, width, height, options.scratch, drawing);
        header = false;
        first = chunk_end;
        if (first >= end) break;
    }
}

/// `table`'s columns fit to what they hold in `width`, measured over its first rows shown (a
/// chunk's, `document.rows_a_chunk`), whichever are in view, so the widths do not change as the
/// page scrolls; a group's table over the first rows shown across its block's groups
/// (`TableBlock.measured`), so every group's columns line up. Null when they cannot be (the
/// frame's memory ran out), the grid then sharing.
fn fitTable(table: document.TableBlock, width: f32, measure: grid.TextMeasure, grid_style: grid.Style, atoms: *const mesha.Atom.Registry, scratch: memory_mod.Scratch) ?grid.Fitted {
    if (table.measured) |rows| return grid.fitColumns(table.table, table.columns, table.fill, rows, width, measure, grid_style, atoms, scratch) catch null;
    const measured = @min(table.rows, document.rows_a_chunk);
    const rows = scratch.allocator.alloc(u32, measured) catch return null;
    var count: usize = 0;
    for (0..measured) |position| {
        const handle = document.rowAt(table.table, @intCast(position)) orelse continue;
        rows[count] = handle.row;
        count += 1;
    }
    return grid.fitColumns(table.table, table.columns, table.fill, rows[0..count], width, measure, grid_style, atoms, scratch) catch null;
}

/// A grid's state for a page's table, which keeps none between frames: made for each draw,
/// nothing selected, sorted, hidden, frozen or filtered, every value its zero. The grid
/// reads its texts only for a filter its toolbar shows or an edit it holds, neither of which a
/// page's table has, so they are empty here and the table is named their owner.
const UnkeptGrid = struct {
    scroll: u32 = 0,
    horizontal_scroll: u32 = 0,
    committed: u8 = 0,
    selected_present: u8 = 0,
    selected_row: u32 = 0,
    selected_row_generation: u32 = 0,
    target_epoch: u32 = 0,
    edit_present: u8 = 0,
    edit_row: u32 = 0,
    edit_field: u32 = 0,
    edit_text: Table.String = .{},
    edit_invalid: u8 = 0,
    edit_commit: u8 = 0,
    edit_serial: u32 = 0,
    sort_column: u32 = 0,
    sort_descending: u8 = 0,
    hidden_columns: u64 = 0,
    frozen_rows: u32 = 0,
    frozen_columns: u32 = 0,
    filter: Table.String = .{},
    filter_focused: u8 = 0,

    /// The grid's state over these values, for as long as they stay where they are.
    fn state(unkept: *UnkeptGrid, table: *Table) grid.State {
        return .{
            .scroll = &unkept.scroll,
            .horizontal_scroll = &unkept.horizontal_scroll,
            .committed = &unkept.committed,
            .selected_present = &unkept.selected_present,
            .selected_row = &unkept.selected_row,
            .selected_row_generation = &unkept.selected_row_generation,
            .target_epoch = &unkept.target_epoch,
            .edit_present = &unkept.edit_present,
            .edit_row = &unkept.edit_row,
            .edit_field = &unkept.edit_field,
            .owner = table,
            .edit_text = &unkept.edit_text,
            .edit_invalid = &unkept.edit_invalid,
            .edit_commit = &unkept.edit_commit,
            .edit_serial = &unkept.edit_serial,
            .sort_column = &unkept.sort_column,
            .sort_descending = &unkept.sort_descending,
            .hidden_columns = &unkept.hidden_columns,
            .frozen_rows = &unkept.frozen_rows,
            .frozen_columns = &unkept.frozen_columns,
            .filter = &unkept.filter,
            .filter_focused = &unkept.filter_focused,
        };
    }
};
