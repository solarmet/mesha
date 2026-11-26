//! A grid of a table's rows and fields, which a plugin draws wherever it shows a table: browsed
//! with the keys and the pointer, filtered, sorted, its columns hidden and frozen, its cells
//! edited. Free functions over state the caller keeps: nothing here remembers anything between
//! calls.
//!
//! The caller keeps the grid's `State` (the cursor, the scrolls, the open edit, the filter's text
//! and focus, the sort, the hidden and frozen columns) in a row of a table of its own, with
//! fields of its choosing, and makes a `State` over them for each call, as the table windows do
//! over their window's row, or over values it keeps for one draw, as a document's table does.
//! Each run, in a kernel of the caller's:
//!
//!     const outcome = try grid.update(state, instance, .table, message, received, table, ctx);
//!     switch (outcome) {
//!         .copy => |copy| askClipboard(copy.text),
//!         .paste_wanted => |target| askClipboardText(target), // and hand it back as `Msg.paste_reply`
//!         .column_menu => |menu| offer(grid.columnMenuChoices(state, menu.field, &choices)),
//!         .edit => |edit| forward(edit), // to the text editor that holds the cell's edit
//!         .chosen => |row| open(row),
//!         .mutated => markDirty(),
//!         .invalidated => close(),
//!         .handled, .ignored => {},
//!     }
//!     _ = grid.settle(state, table, .table, width, height, order_context);
//!
//! `update` changes only the state and the table it is given. What needs a system (the
//! clipboard, a menu, a text editor) it answers in its `Outcome` for the caller to ask: it never
//! sends a request itself. The caller answers a column menu's choice with `applyColumnAction`.
//!
//! The caller draws it each frame with `render`, which writes nothing: it settles a copy of the
//! state as `settle` would and draws that, the rows and columns in view only. The grid's clicks
//! and wheel go to the inbox the caller names, under the tags of `Msg`, with the instance the
//! caller names the grid by at the start of their user data (`instanceOf`). A table declared a
//! required singleton is drawn as a form of its one row's fields, one to a line.
//!
//! Which rows are in view is `window`: the positions of the view order a state scrolled so
//! shows in a body so big, which `render` draws too, so a caller over a large set loads and holds
//! only those. The body's size is the caller's to know: a panel's content less the toolbar and
//! header (`bodySize`); for a grid laid out inside something else, the place the tree's commit
//! recorded for `bodyElement`, read on the next update (`ui.committedPlace`), one update behind
//! the draw. The table may hold all the rows the grid shows (`Rows.all`) or a slice of a larger
//! set (`Rows.slice`), whose filter and sort the grid answers for the caller to apply. A caller
//! that scrolls the grid itself, as a page of blocks does, draws it inline: the rows it asks
//! (`RenderContext.inline_rows`), of the table's or of a list of rows of its own
//! (`RenderContext.chosen_rows`), `inlineHeight` tall. `Presentation` says whether the grid has
//! its toolbar, with its filter, and its header.
//!
//! Its colours, fonts and metrics are a `Style`: the caller's theme, or `default_style`.
const std = @import("std");
const Atom = atom.Atom;
const math = @import("../core/math.zig");
const memory_mod = @import("../core/memory.zig");
const sequencer = @import("../core/sequencer.zig");
const Table = @import("../core/table.zig");
const input = @import("../systems/input.zig");
const roop = @import("../systems/roop.zig");
const filter_field = @import("filter_field.zig");
const marks = @import("marks.zig");
const ui = @import("ui.zig");
const values = @import("grid/values.zig");
const vector_field = @import("vector_field.zig");

const FieldDescriptor = Table.FieldDescriptor;
const atom = @import("../core/atom.zig");
const log = @import("../core/log.zig");
const Log = log.scope("ui");

/// The height of a row of the grid, and of a field of the form, in pixels.
const row_height: f32 = 28;
/// The height of the line naming the grid's columns, in pixels.
const header_height: f32 = 30;
/// The height of the line above the header: the filter and what narrows, orders or freezes the
/// grid, in pixels.
const toolbar_height: f32 = 34;
/// The width of the column of row numbers, in pixels.
const row_number_width: f32 = 52;
/// The narrowest a grid's column gets; columns share the width they have, so they are wider.
const min_cell_width: f32 = 110;
/// The width of the form's column of field names, in pixels.
const field_name_width: f32 = 160;
/// The line after the last frozen row or column.
const frozen_line_width: f32 = 2;
/// Space inside a cell at its ends around its value, in pixels. None is left above and below
/// (`padding_y`): a clipped cell a row tall keeps the whole of its height for a line of text, its
/// descenders and underscores included.
const cell_padding: f32 = 8;
/// The radius of the form's corners, in pixels.
const form_corner_radius: f32 = 6;

/// What the grid shows: the caller's table, as a grid of its rows (a required singleton as a
/// form of its one row's fields), or one row as a form.
pub const Target = union(enum) {
    /// The table: a grid of its rows, or a required singleton's form.
    table,
    /// The row, while it is the one its handle names.
    row: Table.RowHandle,
};

/// Whether the grid's target is still there: `invalidated` for a row that is gone, or a
/// singleton with no row, which the caller closes.
pub const Status = enum { ready, invalidated };

/// What one of the grid's messages came to (`update`): what it changed, or what the caller is
/// to do that needs a system the grid does not ask. A text it carries is in the memory of the
/// `UpdateContext.allocator`, through the caller's frame.
pub const Outcome = union(enum) {
    /// Not one of the messages the grid takes now.
    ignored,
    /// Taken: the state may have changed. A checkbox flipped by a key answers this too, though
    /// its cell changed; `State.committed` says so.
    handled,
    /// The target is gone (`Status.invalidated`).
    invalidated,
    /// Taken, and a cell of the table changed.
    mutated,
    /// A grid read only (`Access.read`): its selected row was chosen, by `Msg.table_choose` (the
    /// owner's RET) or a click on that row, which the owner acts on.
    chosen: Table.RowHandle,
    /// A column's menu was asked for: the caller offers `columnMenuChoices` for `field` and
    /// applies the one chosen with `applyColumnAction`.
    column_menu: struct {
        /// The field whose column it is.
        field: u32,
    },
    /// The selected cell is to be copied: the caller puts `text` on the clipboard.
    copy: struct {
        /// The cell's text, or the edit's while one is open.
        text: []const u8,
    },
    /// A paste over the selected cell is wanted: the caller asks the clipboard and hands its
    /// text back as `Msg.paste_reply`, the clipboard's text its payload and this target its user
    /// data.
    paste_wanted: ClipboardTarget,
    /// While the caller's text editor holds the open edit (`UpdateContext.editor_loaded`): what
    /// the caller is to ask that text editor to do, whose report of its text comes back through
    /// `editorReport`.
    edit: Edit,
    /// Over a slice of a larger set (`Rows.slice`): the filter's text changed, which the grid
    /// cannot apply to rows it does not hold. The caller reads `filterText` and decides what it
    /// means, as to fetch the rows it keeps. Over `Rows.all` the grid filters and answers
    /// `handled`.
    filter_changed,
    /// Over a slice of a larger set (`Rows.slice`): a sort was asked for, by a header or the
    /// sort's chip, which the state now shows and the grid cannot apply to rows it does not hold.
    /// The caller decides what it means, as to fetch its rows in that order. Over `Rows.all` the
    /// grid sorts and answers `handled`.
    sort_wanted: SortWanted,
};

/// The order `Outcome.sort_wanted` asks for.
pub const SortWanted = struct {
    /// The field to sort by; null for the source's own order.
    field: ?u32,
    /// Whether by the field's values falling, where rising is the first asked.
    descending: bool,
};

/// What `Outcome.edit` asks of the caller's text editor.
pub const Edit = struct {
    /// What to do.
    kind: EditKind,
    /// The text inserted or pasted; empty for the others.
    text: []const u8 = "",
};

/// What the caller's text editor is to do with the edit it holds.
pub const EditKind = enum {
    /// Insert `text`, typed, at the caret.
    insert,
    /// Paste `text`, the clipboard's, at the caret.
    paste,
    /// Empty the text: select all of it and delete it.
    clear,
    /// Report its text, which a commit waits for.
    mark_saved,
};

/// How a caller presents the table its grid shows: what a person may do to the cells, which of
/// the table's fields are data only, and whether the rows are numbered. The default edits every
/// field, numbered; a list another system fills is shown read only, the fields only code reads
/// data only, its rows perhaps unnumbered.
pub const Presentation = struct {
    /// What a person may do to the cells.
    access: Access = .edit,
    /// How many of the table's last fields are data only: never shown, never counted as hidden,
    /// not offered by the column menu. Owners keep there what code reads and no person needs.
    data_fields: u32 = 0,
    /// Whether the rows are numbered.
    row_numbers: RowNumbers = .shown,
    /// Whether the grid has its toolbar, and with it its filter. Without it the grid draws none,
    /// takes no height for it, filters nothing and ignores the filter's messages.
    toolbar: Toolbar = .shown,
    /// Whether the line naming the columns is drawn above the rows (by a grid that scrolls
    /// itself, and by an inline draw, `RenderContext.inline_rows`, that wants it), and whether
    /// its names sort and offer a menu or only name.
    header: Header = .shown,
    /// Whether the last column drawn takes the width the others leave, as a read-only list's
    /// path does, or keeps its share.
    last_column: LastColumn = .shared,

    /// How many of `table`'s fields the grid may show: all but the data only ones, and all of a
    /// table with no other.
    pub fn shownFields(presentation: Presentation, table: *const Table) u32 {
        const field_count: u32 = @intCast(table.getSchema().fields.len);
        if (presentation.data_fields >= field_count) return field_count;
        return field_count - presentation.data_fields;
    }

    /// The height of what the grid draws above its rows: its toolbar and its header, as shown.
    fn chromeHeight(presentation: Presentation) f32 {
        var height: f32 = 0;
        if (presentation.toolbar == .shown) height += toolbar_height;
        if (presentation.header != .hidden) height += header_height;
        return height;
    }

    /// The width the grid's columns share at `viewport_w`: the row numbers' column's too when
    /// there are none.
    fn columnsWidth(presentation: Presentation, viewport_w: f32) f32 {
        return switch (presentation.row_numbers) {
            .shown => viewport_w,
            .hidden => viewport_w + row_number_width,
        };
    }
};

/// Whether a grid numbers its rows, in a first column of the table's row ids, or over a slice
/// of a larger set (`Rows.slice`) of their places in it.
pub const RowNumbers = enum { shown, hidden };

/// Whether a grid has its toolbar: the filter, the chips of what narrows, orders or freezes it,
/// and the count of its rows.
pub const Toolbar = enum { shown, hidden };

/// Whether a grid draws the line naming its columns, and what that line does.
pub const Header = enum {
    /// Drawn: a column's name sorts by it, and the button beside it opens its menu.
    shown,
    /// Not drawn.
    hidden,
    /// Drawn with the columns' names only, which do nothing: for a grid whose caller offers no
    /// sort and no column menu, as a read-only page's table.
    names,
};

/// How wide a grid's last drawn column is.
pub const LastColumn = enum {
    /// Its share, as every column's.
    shared,
    /// What the other columns leave of the grid's width, its header's name too.
    fills,
};

/// Which rows of what the grid shows its table holds: all of them, or a slice of a larger set.
/// The caller says, as it presents the grid (`OrderContext.rows`, `UpdateContext.rows`,
/// `RenderContext.rows`).
pub const Rows = union(enum) {
    /// The table holds every row the grid shows: the grid filters and sorts them itself.
    all,
    /// The table holds a slice of a larger set the caller keeps elsewhere: positions are places
    /// in the set, which the grid scrolls over; the table's rows, in its own order, are the
    /// positions from `Slice.first`. The grid neither filters nor sorts: it answers
    /// `Outcome.filter_changed` and `Outcome.sort_wanted` for the caller to. A position the table
    /// does not hold is drawn as an empty row. The caller loads what `window` names, passing it
    /// `ViewOrder.positions` (of `viewOrder` with the same `rows`) as its `rows`.
    ///
    /// What a caller must hold to besides:
    /// - The grid answers changes. A sort or a filter already in the state when the caller first
    ///   presents a slice (a state row kept from before) answers nothing: the caller reads
    ///   `State.sort_column`, `State.sort_descending` and `filterText` as it first presents it.
    /// - The cursor moves among the positions the table holds and stops at their edge; a key that
    ///   would page past them asks for nothing. The caller watches `window` (the scroll does move
    ///   past them, by the wheel) and loads around it.
    /// - A sort chosen from the column menu is written into the state by `applyColumnAction`,
    ///   which answers nothing: the caller, which applied the choice, applies that sort to its
    ///   source as it would a `sort_wanted`.
    /// - Frozen rows freeze the set's first positions, which a slice from further on does not
    ///   hold: they are drawn as empty rows above the window until the caller holds them.
    /// - Positions are 32-bit: a slice's `first`, and with it every place, is clamped where the
    ///   view is built so that the last row the table holds has a place.
    slice: Slice,
};

/// A slice of a larger set the grid's table holds (`Rows.slice`).
pub const Slice = struct {
    /// The place in the set of the table's first row, in the table's own order; positions are
    /// 32-bit, and a place past where the table's last row would still have one is taken as
    /// that place.
    first: u64,
    /// How many rows the set has.
    total: Total,
};

/// How many rows a larger set has, as its caller knows.
pub const Total = union(enum) {
    /// Exactly so many: the grid scrolls to the last.
    known: u64,
    /// So many at least, and perhaps more, as of a history not counted: the grid scrolls to the
    /// last of these, its toolbar counts them as `n+ rows`, and its window reaching that end is
    /// the caller's cue to learn more and tell the larger count.
    at_least: u64,

    /// The rows the grid scrolls over, at most as many as a position counts.
    fn positions(total: Total) u32 {
        const count = switch (total) {
            .known, .at_least => |rows| rows,
        };
        return std.math.cast(u32, count) orelse std.math.maxInt(u32);
    }
};

/// What the caller lets a person do to the cells of the table its grid shows: edit them, or, over
/// a table another system fills, only browse them.
pub const Access = enum {
    /// Typing, the edit key and a click on the selected cell edit it; clearing, flipping and
    /// pasting change it.
    edit,
    /// Nothing edits or changes a cell: the cells are browsed, sorted, filtered and copied, and
    /// a row is chosen (`Outcome.chosen`).
    read,
};

const ResolvedTarget = union(enum) {
    table,
    row: Table.RowHandle,
};

fn resolveTarget(table: *const Table, target: Target) ?ResolvedTarget {
    return switch (target) {
        .table => if (table.required_singleton)
            if (table.isAllocated(0)) .{ .row = .{ .row = 0, .generation = table.rowGeneration(0) } } else null
        else
            .table,
        .row => |handle| if (table.valid(handle)) .{ .row = handle } else null,
    };
}

/// The id of the element the grid `instance` records for `role` (`table.cell`,
/// `table.header.cell`, `table.row`, ...) at the table's `row` and `field`: what a caller finds
/// a drawn cell by in the tree it recorded into, as its tests do.
pub fn elementId(instance: Atom, comptime role: []const u8, row: u32, field: u32) ui.ElementId {
    const role_id: u64 = Atom.from("" ++ role).value();
    const cell = (@as(u64, row) << 32) | field;
    var hash = std.hash.Wyhash.init(@intFromEnum(instance));
    hash.update(std.mem.asBytes(&role_id));
    hash.update(std.mem.asBytes(&cell));
    return .{ .atom = instance, .extra = hash.final() };
}

/// What a click on a cell carries, as `Msg.cell_click`'s user data.
pub const CellClick = extern struct {
    /// The grid's instance, which its caller names it by.
    instance: Atom,
    /// The cell's row in the table.
    row: u32,
    /// The cell's field.
    field: u32,
};

/// The cell being edited, and what draws the caller's text editor in it once that holds
/// the edit; until then the edited text is drawn as it stands.
const EditRef = struct { row: u32, field: u32, invalid: bool, text: []const u8, drawable: ?CellDrawable };

/// What draws the cell being edited in place of its text: the caller's text editor, which the
/// grid knows nothing of. Made by `of` from the caller's drawable, which must stay where it is,
/// and hold what it draws, until the tree's last commit returns.
pub const CellDrawable = struct {
    /// The caller's drawable.
    object: *const anyopaque,
    /// Paints `object` `size` big into `ctx`, translated to the cell's top-left.
    paint: *const fn (object: *const anyopaque, size: math.Vec2f, ctx: *roop.Context) void,

    /// Over `drawable`, a pointer to a `T` that has `pub fn draw(*const T, math.Vec2f,
    /// *roop.Context) void`, as `ui.Tree.custom` takes; the grid only reads through it.
    pub fn of(drawable: anytype) CellDrawable {
        const Drawable = @typeInfo(@TypeOf(drawable)).pointer.child;
        const trampoline = struct {
            fn paint(object: *const anyopaque, size: math.Vec2f, ctx: *roop.Context) void {
                const typed: *const Drawable = @ptrCast(@alignCast(object));
                typed.draw(size, ctx);
            }
        };
        return .{ .object = drawable, .paint = trampoline.paint };
    }

    /// Paints the caller's drawable: what `ui.Tree.custom` calls.
    pub fn draw(cell: *const CellDrawable, size: math.Vec2f, ctx: *roop.Context) void {
        cell.paint(cell.object, size, ctx);
    }
};

/// How `render` paints a grid. The caller's, usually from its theme; `default_style` for a
/// plugin without one.
pub const Style = struct {
    /// The name of the font of every text the grid draws.
    font: roop.Font,
    /// A cell's value, the toolbar's chips, the selected row's number, and a column's name while
    /// its column is selected or sorted by.
    text: ui.Color,
    /// An absent cell's `-`, the row numbers, the form's field names, the count of rows, the
    /// chips' crosses and the column menu's dots.
    dim_text: ui.Color,
    /// The toolbar's and the header's fill.
    header_bg: ui.Color,
    /// A column's name, the sort's chevron, and the form's selected field name.
    header_text: ui.Color,
    /// The fill of every other row, from the first; and of the form's fields.
    row_bg_a: ui.Color,
    /// The fill of the rows between, and of the grid's background.
    row_bg_b: ui.Color,
    /// The fill of the selected row.
    selected_bg: ui.Color,
    /// The fill of the selected cell, of its column's header, and of a chip.
    active_bg: ui.Color,
    /// The border of the selected cell or the one being edited, and the frozen lines.
    active_border: ui.Color,
    /// The fill of a cell whose edit cannot be committed.
    invalid_bg: ui.Color,
    /// The border of a cell whose edit cannot be committed.
    invalid_border: ui.Color,
    /// The fill of the cell being edited.
    edit_bg: ui.Color,
    /// The border of the form.
    grid_border: ui.Color,
    /// The fill of a chip, and of a column's menu button, under the pointer.
    button_hover: ui.Color,
    /// The fill of a column's name, which sorts, under the pointer.
    header_hover: ui.Color,
    /// How the toolbar's filter is painted.
    filter: filter_field.Style,
    /// How a vector's components are painted in the form.
    vector: vector_field.Style,
};

/// A style that reads on a dark background, in roop's default font.
pub const default_style = Style{
    .font = roop.default_font,
    .text = ui.rgb(240, 240, 240),
    .dim_text = ui.rgb(190, 190, 190),
    .header_bg = ui.rgb(44, 44, 44),
    .header_text = ui.rgb(120, 195, 255),
    .row_bg_a = ui.rgb(56, 56, 56),
    .row_bg_b = ui.rgb(50, 50, 50),
    .selected_bg = ui.rgb(13, 110, 190),
    .active_bg = ui.rgba(13, 153, 255, 40),
    .active_border = ui.rgba(13, 153, 255, 200),
    .invalid_bg = ui.rgba(255, 84, 112, 44),
    .invalid_border = ui.rgb(255, 84, 112),
    .edit_bg = ui.rgb(12, 34, 56),
    .grid_border = ui.rgb(68, 68, 68),
    .button_hover = ui.rgb(84, 84, 84),
    .header_hover = ui.rgba(255, 255, 255, 14),
    .filter = filter_field.default_style,
    .vector = vector_field.default_style,
};

/// What a grid draws: a table's rows under a line naming its columns, or one row's fields,
/// which name themselves.
pub const Body = enum { grid, fields };

fn bodyOf(target: ResolvedTarget) Body {
    return switch (target) {
        .table => .grid,
        .row => .fields,
    };
}

/// The most rows one grid draws, whatever its size, which bounds the hit regions and elements
/// every grid together can make: a body taller than so many rows shows its background below
/// them.
pub const max_visible_rows: u32 = 64;
/// The most columns one grid draws, whatever its size; a wider grid gets wider columns instead.
pub const max_visible_columns: u32 = 24;
/// Hit regions a grid of `columns` columns presented as `presentation` makes besides its cells:
/// the wheel's over the grid and over its body, a sort and a menu target per header, and the
/// toolbar's filter, clear button and chips, as shown. An inline draw makes fewer: it takes no
/// wheel. A header of names only (`Header.names`) makes none.
pub fn chromeHitsPerGrid(columns: u32, presentation: Presentation) u32 {
    const wheel = 2;
    const headers = if (presentation.header == .shown) 2 * columns else 0;
    const toolbar: u32 = if (presentation.toolbar == .shown) 7 else 0;
    return wheel + headers + toolbar;
}

/// How many rows, or a form's fields, a grid `viewport_h` tall draws: those that fit under its
/// toolbar and header as `presentation` shows them (a form has neither), at least one, at most
/// `max_visible_rows`.
pub fn visibleRows(viewport_h: f32, body: Body, presentation: Presentation) u32 {
    const usable = if (body == .grid) viewport_h - presentation.chromeHeight() else viewport_h;
    return wholeRows(usable);
}

/// How many columns a grid whose columns share `viewport_w` draws: those of the narrowest width
/// that fit past the row numbers, at least one, at most `max_visible_columns`.
pub fn visibleColumns(viewport_w: f32) u32 {
    const usable = viewport_w - row_number_width;
    const fitting: u32 = if (usable < min_cell_width) 1 else @intFromFloat(@floor(usable / min_cell_width));
    return @min(fitting, max_visible_columns);
}

/// Each column's width: the room past the row numbers, shared by the columns that fit, on
/// whole pixels. Fewer columns than fit keep the minimum's share rather than stretching.
fn cellWidth(viewport_w: f32, shown: usize) f32 {
    const usable = @max(viewport_w - row_number_width, min_cell_width);
    const fitting: f32 = @floatFromInt(visibleColumns(viewport_w));
    const share = @floor(usable / fitting);
    // A table with fewer columns than fit keeps them at a readable width, not one wide strip.
    return if (shown > 0 and @as(f32, @floatFromInt(shown)) < fitting) @min(share, min_cell_width * 1.6) else share;
}

fn clampScroll(scroll: u32, total: u32, visible: u32) u32 {
    return if (total <= visible) 0 else @min(scroll, total - visible);
}

/// A size laid out, in pixels.
pub const Size = struct {
    /// Across.
    width: f32,
    /// Down.
    height: f32,
};

/// The size of the body of a grid laid out `viewport_w` by `viewport_h`: the rows, under its
/// toolbar and its header as `presentation` shows them. What `window` takes as bounds for a
/// grid whose caller knows its size, as a panel's content.
pub fn bodySize(viewport_w: f32, viewport_h: f32, presentation: Presentation) Size {
    const chrome = presentation.chromeHeight();
    return .{ .width = viewport_w, .height = @max(viewport_h - chrome, 0) };
}

/// The height of an inline draw of `rows` rows (`RenderContext.inline_rows`): its toolbar and
/// header as `presentation` shows them, and the rows, each `row_height`. What a caller that
/// scrolls the grid itself lays the grid out at.
pub fn inlineHeight(rows: u32, presentation: Presentation) f32 {
    const rows_height = @as(f32, @floatFromInt(rows)) * row_height;
    return presentation.chromeHeight() + rows_height;
}

/// The element of the grid `instance` that holds its rows, its body, under its toolbar and
/// header. A grid that scrolls itself gives it the wheel, so `ui.Tree.commit` records its place
/// in the hit regions it writes, clipped to what encloses it. A caller that lays the grid out
/// inside something else, and so does not know its size, reads that place in a kernel of its
/// next update, `ui.committedPlace(hit_regions, grid.bodyElement(instance))`, over the hit
/// regions table it declares read, and passes its size to `window`: the place is the last
/// commit's, one update behind what is drawn, and null before the grid is first drawn. An
/// inline draw takes no wheel, and its place is not recorded: its caller placed it.
pub fn bodyElement(instance: Atom) ui.ElementId {
    return elementId(instance, "body", 0, 0);
}

/// The positions of a grid's view order in view (`window`): those from `first`, past the rows
/// that stay in place, `count` of them, and the `frozen` first positions, which stay in place
/// above them.
pub const Window = struct {
    /// The first position in view past the frozen ones: the frozen count plus the scroll.
    first: u32,
    /// How many positions from `first` are in view, the last perhaps only in part; none past the
    /// end of the view.
    count: u32,
    /// How many of the view's first positions stay in place above the window, in view too.
    frozen: u32 = 0,
};

/// The positions of the view order in view of a grid scrolled as `state` is, whose body is laid
/// out `bounds` big (`bodySize`, or the place the tree's commit recorded for `bodyElement`), over
/// a view of `rows` positions: what a caller loads, and holds, to show the grid. Pure: it reads
/// the state's scroll and frozen rows, kept within the rows as `settle` keeps them, and nothing
/// else. A row any part of which is in view counts; `render` draws the whole rows of the same
/// window, at most `max_visible_rows`. The window never names a position at or past `rows`: a
/// caller of a source of unknown length that sees the window reach the end of what it knows
/// (`first + count == rows`) learns more and tells the grid the larger count.
pub fn window(state: State, bounds: Size, rows: u64) Window {
    const total: u32 = std.math.cast(u32, rows) orelse std.math.maxInt(u32);
    const whole = wholeRows(bounds.height);
    const frozen = @min(state.frozen_rows.*, total);
    const split = splitVisible(frozen, whole);
    const scroll = clampScroll(state.scroll.*, total -| split.frozen, split.scrolling);
    const first = @min(split.frozen + scroll, total);
    var frozen_height: f32 = @as(f32, @floatFromInt(split.frozen)) * row_height;
    if (split.frozen > 0) frozen_height += frozen_line_width;
    const room = @max(bounds.height - frozen_height, 0);
    const touched: u32 = @intFromFloat(@ceil(room / row_height));
    return .{ .first = first, .count = @min(touched, total - first), .frozen = split.frozen };
}

/// How many whole rows a body `body_h` tall shows: at least one, at most `max_visible_rows`.
fn wholeRows(body_h: f32) u32 {
    const fitting: u32 = if (body_h < row_height) 1 else @intFromFloat(@floor(body_h / row_height));
    return @min(fitting, max_visible_rows);
}

/// The most elements `render` records for a grid of rows (`Body.grid`) that draws `rows` rows of
/// `columns` columns, its toolbar, header and chips included, whatever its presentation: what a
/// caller's `ui.Tree` is to have room for.
pub fn elementCount(rows: u32, columns: u32) u32 {
    // A row: its frame, its number's cell and text, a frozen line, and each cell's frame and value.
    const per_row = 6 + 3 * columns;
    // A column's header: its frame, its name's frame and text, the sort's chevron, the menu's
    // frame and dots.
    const per_header_column = 9;
    // The grid's and its body's frames, the toolbar (its frame, the filter's eleven, three chips
    // of four, a space and the count), the header's frame, number cell and frozen line, and the
    // line that says there are no rows.
    const chrome = 2 + 2 + 27 + 6 + 3;
    return rows * per_row + columns * per_header_column + chrome;
}

// ---- the grid's view: filter, sort, hidden and frozen ---------------------------------------

/// One axis of a grid's view: the table's rows, or its fields, in the order the grid shows them,
/// read by position (`at`, `positionOf`). The table's own order takes no memory: there the line
/// at position p is line p.
pub const Order = struct {
    /// The lines in the order shown, in the `OrderContext.allocator`'s memory; null for the
    /// table's own order, where position p is line p.
    lines: ?[]const u32 = null,
    /// How many positions the order has.
    len: u32,

    /// The table's own order of `len` lines, which takes no memory.
    fn identity(len: u32) Order {
        return .{ .len = len };
    }

    /// The order of `lines`, which the order views and does not copy.
    fn of(lines: []const u32) Order {
        return .{ .lines = lines, .len = @intCast(lines.len) };
    }

    /// The line at `position`, which is below `len`.
    pub fn at(order: Order, position: u32) u32 {
        std.debug.assert(position < order.len);
        const lines = order.lines orelse return position;
        return lines[position];
    }

    /// The position of `line`; null for a line the order leaves out.
    pub fn positionOf(order: Order, line: u32) ?u32 {
        const lines = order.lines orelse return if (line < order.len) line else null;
        const index = std.mem.indexOfScalar(u32, lines, line) orelse return null;
        return @intCast(index);
    }

    /// The line of the order nearest `wanted` by number, for a selection the view no longer
    /// holds; null for an empty order.
    fn nearest(order: Order, wanted: u32) ?u32 {
        if (order.len == 0) return null;
        if (order.lines == null) return @min(wanted, order.len - 1);
        var best: ?u32 = null;
        var best_distance: u32 = std.math.maxInt(u32);
        for (0..order.len) |position| {
            const line = order.at(@intCast(position));
            const distance = if (line > wanted) line - wanted else wanted - line;
            if (distance < best_distance) {
                best = line;
                best_distance = distance;
            }
        }
        return best;
    }
};

/// The rows and columns a grid shows, in the order it shows them: the populated rows the
/// filter keeps, sorted, and the fields not hidden. Navigation, scrolling and drawing count
/// positions in it; the selection stays a table row and a field. The first `frozen_rows`
/// rows and `frozen_columns` columns stay in place while the rest scroll.
///
/// Unfiltered and unsorted, its rows are the table's own order: its rows by number, which takes
/// no memory while they are the table's first rows, each populated; a table with a row freed
/// among them (a hole, until the row is used again) lists its populated rows by number. Columns
/// none of which is hidden are the fields by number, in no memory either. What a list takes is
/// the `OrderContext.allocator`'s. Rows its caller chose (`OrderContext.chosen_rows`) are its
/// rows as listed, the list viewed and not copied, and `total_rows` their number.
///
/// Over a slice of a larger set (`Rows.slice`) the positions are places in the set, `positions`
/// of them, and the table's rows, in its own order, are those from `first`; a position outside
/// them has no row.
pub const ViewOrder = struct {
    /// The table's rows shown, in the order shown: every position's over `Rows.all`, those from
    /// `first` over a slice.
    rows: Order,
    /// The fields shown as columns, in the order shown.
    columns: Order,
    /// How many of the first rows stay in place.
    frozen_rows: u32,
    /// How many of the first columns stay in place.
    frozen_columns: u32,
    /// Populated rows before the filter, for "n of m"; over a slice, the set's.
    total_rows: u32,
    /// The position of `rows`' first: 0 over `Rows.all`.
    first: u32 = 0,
    /// How many positions the view has: as many as `rows` over `Rows.all`, the set's over a
    /// slice.
    positions: u32,
    /// Whether the set's count is a floor (`Total.at_least`).
    open_ended: bool = false,

    /// The table's row at `position`; null for a position the table does not hold.
    pub fn rowAt(order: ViewOrder, position: u32) ?u32 {
        if (position < order.first) return null;
        const index = position - order.first;
        if (index >= order.rows.len) return null;
        return order.rows.at(index);
    }

    /// The position of the table's `row`; null for a row the view leaves out.
    pub fn rowPosition(order: ViewOrder, row: u32) ?u32 {
        const index = order.rows.positionOf(row) orelse return null;
        return order.first + index;
    }

    fn columnPosition(order: ViewOrder, field: u32) ?u32 {
        return order.columns.positionOf(field);
    }

    /// How many positions the view has, which the grid scrolls over.
    fn rowCount(order: ViewOrder) u32 {
        return order.positions;
    }

    fn columnCount(order: ViewOrder) u32 {
        return order.columns.len;
    }

    /// The positions the table holds rows at: none past them is selected.
    fn heldPositions(order: ViewOrder) struct { first: u32, last: u32 } {
        return .{ .first = order.first, .last = order.first + order.rows.len - 1 };
    }

    const empty: ViewOrder = .{ .rows = .identity(0), .columns = .identity(0), .frozen_rows = 0, .frozen_columns = 0, .total_rows = 0, .positions = 0 };
};

/// What building a view order needs: atoms to format values with, frame memory, how the owner
/// presents the grid, whose data only fields are no column, and which rows the table holds.
pub const OrderContext = struct {
    /// Names atom and reference cells, read only.
    atoms: *const Atom.Registry,
    /// Frame memory: the order's slices and the texts it sorts by, kept until the caller frees it.
    allocator: std.mem.Allocator,
    /// How the caller presents the grid.
    presentation: Presentation = .{},
    /// Which rows of what the grid shows the table holds.
    rows: Rows = .all,
    /// The fields shown as columns, in the order shown, as its caller chose them (a page's table
    /// whose author named its columns); the hidden columns and the data only fields are then not
    /// read. Field indices past the table's fields are left out. Null: the fields not hidden, in
    /// the table's order. The slice is the caller's, for the call.
    columns: ?[]const u32 = null,
    /// The table's rows shown, in the order shown, as its caller chose them (a page's group of
    /// rows, a subset of the table's in an order the caller keeps): the filter and the sort are
    /// not applied, and a position is a place in this list. A row the table does not hold (freed
    /// since, or past its capacity) keeps its place and is drawn as an empty row. Over `Rows.all`
    /// only: over a slice it is not read. Null: the table's rows as the filter and the sort
    /// leave them. The slice is the caller's, for the call.
    chosen_rows: ?[]const u32 = null,
};

/// How a frozen count and the room for `visible` lines share it: frozen lines stay, at least
/// one line scrolls.
const Split = struct { frozen: u32, scrolling: u32 };

fn splitVisible(frozen: u32, visible: u32) Split {
    const shown = @min(frozen, visible -| 1);
    return .{ .frozen = shown, .scrolling = visible - shown };
}

/// The grid's view of `table` under `state`'s filter, sort and hidden and frozen columns.
/// Empty when memory runs out, which draws an empty grid for the frame.
pub fn viewOrder(state: State, table: *const Table, ctx: OrderContext) ViewOrder {
    return buildViewOrder(state, table, ctx) catch ViewOrder.empty;
}

fn columnHidden(state: State, field: u32) bool {
    return field < 64 and (state.hidden_columns.* >> @intCast(field)) & 1 != 0;
}

/// Whether `table`'s populated rows are its first rows, with no row freed among them: then its
/// own order is its rows by number, 0 to its count, which takes no memory. A row past the count
/// populated means a hole below it. Reads the count and which rows are allocated, as a run sees
/// them through an attached journal: a journaled kernel may call it.
pub fn rowsDense(table: *const Table) bool {
    const live = table.count();
    var row = live;
    while (row < table.rowCapacity()) : (row += 1) {
        if (table.isAllocated(row)) return false;
    }
    return true;
}

fn buildViewOrder(state: State, table: *const Table, ctx: OrderContext) !ViewOrder {
    const field_count: u32 = @intCast(table.getSchema().fields.len);
    const shown_fields = ctx.presentation.shownFields(table);
    const columns = if (ctx.columns) |chosen| try chosenColumns(chosen, field_count, ctx.allocator) else try shownColumns(state, shown_fields, ctx.allocator);
    // Over a slice the grid filters and sorts nothing, as it cannot see the rows; without its
    // toolbar it has no filter.
    const over_all = ctx.rows == .all;
    // Rows its caller chose are shown as it lists them: neither filtered nor sorted.
    const chosen_rows: ?[]const u32 = if (over_all) ctx.chosen_rows else null;
    const filtered = over_all and chosen_rows == null and ctx.presentation.toolbar == .shown;
    const query = if (filtered) state.filterField().query() else "";
    const sort_field = state.sort_column.*;
    const sorting = over_all and chosen_rows == null and sort_field != 0 and sort_field - 1 < field_count;
    var rows: Order = undefined;
    var populated: u32 = undefined;
    if (chosen_rows) |chosen| {
        rows = .of(chosen);
        populated = rows.len;
    } else if (query.len == 0 and !sorting and rowsDense(table)) {
        populated = table.count();
        rows = .identity(populated);
    } else {
        var kept_rows: std.ArrayList(u32) = .empty;
        populated = 0;
        var buffer: [values.cell_text_buffer_size]u8 = undefined;
        for (0..table.rowCapacity()) |row_index| {
            const row: u32 = @intCast(row_index);
            if (!table.isAllocated(row)) continue;
            populated += 1;
            const kept = query.len == 0 or for (0..columns.len) |position| {
                const field = columns.at(@intCast(position));
                if (filter_field.matches(query, values.cellText(table, row, field, &buffer, ctx.atoms))) break true;
            } else false;
            if (kept) try kept_rows.append(ctx.allocator, row);
        }
        if (sorting) try sortRows(ctx, table, kept_rows.items, sort_field - 1, state.sort_descending.* != 0);
        rows = .of(kept_rows.items);
    }
    const frozen_columns = @min(state.frozen_columns.*, columns.len);
    switch (ctx.rows) {
        .all => return .{
            .rows = rows,
            .columns = columns,
            .frozen_rows = @min(state.frozen_rows.*, rows.len),
            .frozen_columns = frozen_columns,
            .total_rows = populated,
            .positions = rows.len,
        },
        .slice => |slice| {
            // Positions are 32-bit: the slice is placed so its last row still has one.
            const last_first = std.math.maxInt(u32) - rows.len;
            const first: u32 = @intCast(@min(slice.first, last_first));
            // A count behind what the table holds still shows every row held.
            const held_end = first +| rows.len;
            const positions = @max(slice.total.positions(), held_end);
            return .{
                .rows = rows,
                .columns = columns,
                .frozen_rows = @min(state.frozen_rows.*, positions),
                .frozen_columns = frozen_columns,
                .total_rows = positions,
                .first = first,
                .positions = positions,
                .open_ended = slice.total == .at_least,
            };
        },
    }
}

/// The fields its caller chose (`OrderContext.columns`), in its order, those past the table's
/// `field_count` fields left out.
fn chosenColumns(chosen: []const u32, field_count: u32, allocator: std.mem.Allocator) !Order {
    var columns: std.ArrayList(u32) = .empty;
    for (chosen) |field| {
        if (field < field_count) try columns.append(allocator, field);
    }
    return .of(columns.items);
}

/// The fields of the first `shown_fields` not hidden, in their order: the fields by number in no
/// memory when none is hidden, and all of them when every one is.
fn shownColumns(state: State, shown_fields: u32, allocator: std.mem.Allocator) !Order {
    var hidden_count: u32 = 0;
    for (0..shown_fields) |field| {
        if (columnHidden(state, @intCast(field))) hidden_count += 1;
    }
    // Every column hidden would leave nothing to select; show them all instead.
    if (hidden_count == 0 or hidden_count == shown_fields) return .identity(shown_fields);
    var columns: std.ArrayList(u32) = .empty;
    for (0..shown_fields) |field| {
        if (!columnHidden(state, @intCast(field))) try columns.append(allocator, @intCast(field));
    }
    return .of(columns.items);
}

/// A row's value in the sorting field: a number when it reads as one, else its text. Empty
/// cells sort last either way.
const SortKey = struct { row: u32, number: ?f64, text: []const u8 };

fn sortRows(ctx: OrderContext, table: *const Table, rows: []u32, field: u32, descending: bool) !void {
    const keys = try ctx.allocator.alloc(SortKey, rows.len);
    var buffer: [values.cell_text_buffer_size]u8 = undefined;
    for (rows, keys) |row, *key| {
        const text = try ctx.allocator.dupe(u8, values.cellText(table, row, field, &buffer, ctx.atoms));
        const number = std.fmt.parseFloat(f64, std.mem.trim(u8, text, " ")) catch null;
        key.* = .{ .row = row, .number = number, .text = text };
    }
    const Context = struct { descending: bool };
    std.mem.sort(SortKey, keys, Context{ .descending = descending }, struct {
        fn less(context: Context, a: SortKey, b: SortKey) bool {
            // Empty cells last in either direction; ties keep the table's order.
            if ((a.text.len == 0) != (b.text.len == 0)) return b.text.len == 0;
            const order = compareKeys(a, b);
            if (order == .eq) return a.row < b.row;
            return if (context.descending) order == .gt else order == .lt;
        }
    }.less);
    for (rows, keys) |*row, key| row.* = key.row;
}

fn compareKeys(a: SortKey, b: SortKey) std.math.Order {
    if (a.number != null and b.number != null) return std.math.order(a.number.?, b.number.?);
    // Numbers before words.
    if (a.number != null) return .lt;
    if (b.number != null) return .gt;
    return std.ascii.orderIgnoreCase(a.text, b.text);
}

// ---- the state a caller keeps ----------------------------------------------------------------

/// A grid's state, as views of the caller's cells: the pointers are the caller's, valid while
/// its row stays where it is, so a `State` lasts one call, made again from the row each time
/// (from the caller's own row, field by field). `update` and `settle`
/// write it; `render` only reads it. Every cell it views zero (`owner` aside, a table, not a
/// cell) is the start: nothing selected, sorted, hidden, frozen or filtered, the scrolls at the
/// start, no edit.
pub const State = struct {
    /// The first row (a form's first field) scrolled to, past the frozen ones.
    scroll: *u32,
    /// The first column scrolled to, past the frozen ones.
    horizontal_scroll: *u32,

    /// Nonzero after an `update` that changed a cell; each `update` starts it at 0.
    committed: *u8,
    /// Nonzero while a row is selected.
    selected_present: *u8,
    /// The selected row.
    selected_row: *u32,
    /// The selected row's generation, which tells a row freed and reused.
    selected_row_generation: *u32,

    /// Counts changes of what the selection or the edit is on, so an answer (a paste) for an
    /// earlier one is dropped (`ClipboardTarget`).
    target_epoch: *u32,
    /// Nonzero while a cell is edited.
    edit_present: *u8,
    /// The row of the cell edited.
    edit_row: *u32,
    /// The selected field, and the field of the cell edited.
    edit_field: *u32,
    /// The table the caller's row is in, which holds the edit's and the filter's text.
    owner: *Table,
    /// The edited text, as the caller's text editor last reported it, which a commit validates
    /// and writes.
    edit_text: *Table.String,
    /// Nonzero while the edited text cannot be committed.
    edit_invalid: *u8,
    /// A commit waiting for the text editor's next report of its text: 0 for none, else the move
    /// after it plus one.
    edit_commit: *u8,
    /// Counts the edits, so the caller's text editor knows which it holds.
    edit_serial: *u32,

    /// How the grid is narrowed, ordered and frozen; see `ViewOrder`. Zero is none of it.
    /// The sorting field plus one; 0 for the table's own order.
    sort_column: *u32,
    /// Nonzero to sort descending.
    sort_descending: *u8,
    /// A bit per field index under 64: the columns the grid leaves out.
    hidden_columns: *u64,
    /// How many of the view's first rows stay in place.
    frozen_rows: *u32,
    /// How many of the view's first columns stay in place.
    frozen_columns: *u32,
    /// The filter's text, of `owner`: the rows shown are those with a cell that holds it.
    filter: *Table.String,
    /// Nonzero while the filter has the keyboard.
    filter_focused: *u8,

    fn filterField(state: State) filter_field.Field {
        return .{ .table = state.owner, .text = state.filter, .focused = state.filter_focused };
    }
};

/// Whether the grid's filter has the keyboard, so its keys go nowhere else.
pub fn isFiltering(state: State) bool {
    return state.filter_focused.* != 0;
}

/// Whether the filter of a grid presented as `presentation` has the keyboard: never without its
/// toolbar.
fn filterHasKeys(state: State, presentation: Presentation) bool {
    return presentation.toolbar == .shown and isFiltering(state);
}

/// The filter's text, the state owner's until it next changes: what a caller over a slice of a
/// larger set reads on `Outcome.filter_changed`.
pub fn filterText(state: State) []const u8 {
    return state.filterField().query();
}

/// Whether a cell is being edited.
pub fn isEditing(state: State) bool {
    return state.edit_present.* != 0;
}

fn bumpTargetEpoch(state: State) void {
    state.target_epoch.* +%= 1;
}

/// Forgets everything of the grid's view, for a grid shown over another table: nothing
/// selected, edited, sorted, hidden, frozen or filtered, the scrolls at the start.
pub fn reset(state: State) void {
    bumpTargetEpoch(state);
    // Another table's fields: what was sorted, hidden or frozen means nothing there.
    state.sort_column.* = 0;
    state.sort_descending.* = 0;
    state.hidden_columns.* = 0;
    state.frozen_rows.* = 0;
    state.frozen_columns.* = 0;
    state.filterField().clear();
    state.filterField().setFocused(false);
    state.scroll.* = 0;
    state.horizontal_scroll.* = 0;
    state.selected_present.* = 0;
    state.edit_present.* = 0;
    state.edit_text.* = .{};
    state.edit_invalid.* = 0;
    state.edit_commit.* = 0;
    state.edit_field.* = 0;
    state.selected_row_generation.* = 0;
}

fn clearActive(state: State) bool {
    const changed = state.selected_present.* != 0 or state.edit_present.* != 0;
    state.selected_present.* = 0;
    state.selected_row_generation.* = 0;
    state.edit_present.* = 0;
    state.edit_invalid.* = 0;
    state.scroll.* = 0;
    state.horizontal_scroll.* = 0;
    if (changed) bumpTargetEpoch(state);
    return changed;
}

/// Nothing selected or edited, the scrolls kept; whether anything was.
fn dropSelection(state: State) bool {
    const changed = state.selected_present.* != 0 or state.edit_present.* != 0;
    state.selected_present.* = 0;
    state.selected_row_generation.* = 0;
    state.edit_present.* = 0;
    state.edit_invalid.* = 0;
    if (changed) bumpTargetEpoch(state);
    return changed;
}

fn normalizeScalars(state: State) void {
    state.selected_present.* = if (state.selected_present.* == 0) 0 else 1;
    state.edit_present.* = if (state.edit_present.* == 0) 0 else 1;
    state.edit_invalid.* = if (state.edit_invalid.* == 0) 0 else 1;
}

/// `row`'s generation in `table`, or 0 for a row past its capacity, which a caller's
/// `OrderContext.chosen_rows` may name: no row is there, and nothing of it is read.
fn generationOf(table: *const Table, row: u32) u32 {
    if (row >= table.rowCapacity()) return 0;
    return table.rowGeneration(row);
}

fn normalizeResolved(state: State, table: *const Table, target: ResolvedTarget, order: ViewOrder) bool {
    normalizeScalars(state);
    if (table.getSchema().fields.len == 0 or (target == .table and order.rowCount() == 0)) return clearActive(state);
    // A slice that holds no row yet: nothing to select, and the scroll stays where the caller's
    // rows are wanted.
    if (target == .table and order.rows.len == 0) return dropSelection(state);

    var changed = false;
    var target_changed = false;
    switch (target) {
        .table => {
            if (state.selected_present.* == 0) {
                state.selected_present.* = 1;
                state.selected_row.* = order.rows.at(0);
                state.selected_row_generation.* = generationOf(table, state.selected_row.*);
                changed = true;
                target_changed = true;
            } else if (!table.isAllocated(state.selected_row.*) or order.rowPosition(state.selected_row.*) == null) {
                // Gone from the table, or left out by the filter: the nearest row still shown.
                state.selected_row.* = order.rows.nearest(state.selected_row.*).?;
                state.selected_row_generation.* = generationOf(table, state.selected_row.*);
                state.edit_present.* = 0;
                state.edit_invalid.* = 0;
                changed = true;
                target_changed = true;
            } else if (state.selected_row_generation.* != table.rowGeneration(state.selected_row.*)) {
                state.selected_row_generation.* = table.rowGeneration(state.selected_row.*);
                state.edit_present.* = 0;
                state.edit_invalid.* = 0;
                changed = true;
                target_changed = true;
            }
        },
        .row => |handle| {
            state.horizontal_scroll.* = 0;
            if (state.selected_present.* == 0 or state.selected_row.* != handle.row or state.selected_row_generation.* != handle.generation) {
                state.selected_present.* = 1;
                state.selected_row.* = handle.row;
                state.selected_row_generation.* = handle.generation;
                state.edit_present.* = 0;
                state.edit_invalid.* = 0;
                changed = true;
                target_changed = true;
            }
        },
    }

    const max_field: u32 = @intCast(table.getSchema().fields.len - 1);
    var field_was_invalid = state.edit_field.* > max_field;
    if (field_was_invalid) {
        state.edit_field.* = max_field;
        changed = true;
        target_changed = true;
    }
    // A hidden column cannot hold the selection: the first column shown takes it.
    if (target == .table and order.columnPosition(state.edit_field.*) == null) {
        state.edit_field.* = order.columns.at(0);
        field_was_invalid = true;
        changed = true;
        target_changed = true;
    }
    if (state.edit_present.* != 0) {
        if (field_was_invalid or !table.isAllocated(state.edit_row.*) or state.edit_row.* != state.selected_row.*) {
            state.edit_present.* = 0;
            state.edit_invalid.* = 0;
            target_changed = true;
        } else state.edit_row.* = state.selected_row.*;
    }
    if (target_changed) bumpTargetEpoch(state);
    return changed;
}

fn prepare(state: State, table: *const Table, target: Target, order: ViewOrder) ?struct { target: ResolvedTarget, changed: bool } {
    const resolved = resolveTarget(table, target) orelse {
        normalizeScalars(state);
        _ = clearActive(state);
        return null;
    };
    return .{ .target = resolved, .changed = normalizeResolved(state, table, resolved, order) };
}

fn normalize(state: State, table: *const Table, target: Target, ctx: OrderContext) Status {
    _ = prepare(state, table, target, viewOrder(state, table, ctx)) orelse return .invalidated;
    return .ready;
}

/// Scrolls `position`, of the lines past the frozen ones, into the `scrolling` lines shown.
fn revealPosition(scroll: *u32, position: u32, split: Split) void {
    if (position < split.frozen) return;
    const offset = position - split.frozen;
    if (offset < scroll.*) scroll.* = offset else if (offset >= scroll.* +| split.scrolling) scroll.* = offset - split.scrolling + 1;
}

fn reveal(state: State, table: *const Table, target: ResolvedTarget, order: ViewOrder, rows: u32, cols: u32) void {
    switch (target) {
        .table => {
            const ordinal = order.rowPosition(state.selected_row.*) orelse return;
            revealPosition(state.scroll, ordinal, splitVisible(order.frozen_rows, rows));
            const column = order.columnPosition(state.edit_field.*) orelse return;
            revealPosition(state.horizontal_scroll, column, splitVisible(order.frozen_columns, cols));
        },
        .row => {
            _ = table;
            state.horizontal_scroll.* = 0;
            if (state.edit_field.* < state.scroll.*) state.scroll.* = state.edit_field.* else if (state.edit_field.* >= state.scroll.* + rows) state.scroll.* = state.edit_field.* - rows + 1;
        },
    }
}

const Move = enum { left, right, up, down, first_col, last_col, first_cell, last_cell, page_up, page_down, tab_back, tab_forward };

fn moveActive(state: State, table: *const Table, target: ResolvedTarget, order: ViewOrder, movement: Move, page_rows: u32, rows: u32, cols: u32) void {
    if (state.selected_present.* == 0) return;
    const old_row = state.selected_row.*;
    const old_field = state.edit_field.*;
    const field_count: u32 = @intCast(table.getSchema().fields.len);
    switch (target) {
        .table => {
            // Positions in the view: the rows the filter keeps, in sort order, and the
            // columns shown. The cursor moves among the positions the table holds rows at: all
            // of them, or over a slice those it holds, so it stops at the edge of what is loaded.
            const column_count = order.columnCount();
            if (order.rows.len == 0 or column_count == 0) return;
            const held = order.heldPositions();
            var ordinal = order.rowPosition(state.selected_row.*) orelse held.first;
            var column = order.columnPosition(state.edit_field.*) orelse 0;
            switch (movement) {
                .left => column -|= 1,
                .right => column = @min(column_count - 1, column + 1),
                .up => ordinal = @max(held.first, ordinal -| 1),
                .down => ordinal = @min(held.last, ordinal +| 1),
                .first_col => column = 0,
                .last_col => column = column_count - 1,
                .first_cell => {
                    ordinal = held.first;
                    column = 0;
                },
                .last_cell => {
                    ordinal = held.last;
                    column = column_count - 1;
                },
                .page_up => ordinal = @max(held.first, ordinal -| page_rows),
                .page_down => ordinal = @min(held.last, ordinal +| page_rows),
                .tab_forward => {
                    if (column + 1 < column_count) column += 1 else if (ordinal < held.last) {
                        column = 0;
                        ordinal += 1;
                    }
                },
                .tab_back => {
                    if (column > 0) column -= 1 else if (ordinal > held.first) {
                        column = column_count - 1;
                        ordinal -= 1;
                    }
                },
            }
            state.selected_row.* = order.rowAt(ordinal).?;
            state.selected_row_generation.* = generationOf(table, state.selected_row.*);
            state.edit_field.* = order.columns.at(column);
        },
        .row => |handle| {
            switch (movement) {
                .up, .tab_back => state.edit_field.* -|= 1,
                .down, .tab_forward => state.edit_field.* = @min(field_count - 1, state.edit_field.* + 1),
                .first_col, .first_cell => state.edit_field.* = 0,
                .last_col, .last_cell => state.edit_field.* = field_count - 1,
                .page_up => state.edit_field.* -|= page_rows,
                .page_down => state.edit_field.* = @min(field_count - 1, state.edit_field.* + page_rows),
                .left, .right => {},
            }
            state.selected_row.* = handle.row;
            state.selected_row_generation.* = handle.generation;
        },
    }
    if (state.selected_row.* != old_row or state.edit_field.* != old_field) {
        state.edit_invalid.* = 0;
        bumpTargetEpoch(state);
    }
    reveal(state, table, target, order, rows, cols);
}

/// The edited text as last reported: the owner table's until the edit's text next changes.
pub fn editText(state: State) []const u8 {
    return state.owner.textOf(state.edit_text.*);
}

/// Takes `text` as the edited text. A text that cannot be kept marks the edit invalid, so
/// it is not committed short.
fn setEditText(state: State, text: []const u8) void {
    state.owner.assignString(state.edit_text, text) catch {
        state.edit_invalid.* = 1;
    };
}

const BeginEditMode = enum { replace, seed };

/// Starts editing the selected cell, with its text or none. The caller's text editor takes the
/// edit when the grid has the keyboard (`UpdateContext.editor_loaded`).
fn beginEdit(state: State, table: *const Table, atoms: *const Atom.Registry, mode: BeginEditMode) void {
    if (state.selected_present.* == 0) return;
    var seed_buffer: [values.cell_text_buffer_size]u8 = undefined;
    const initial = if (mode == .replace) "" else values.seedEditText(table, state.selected_row.*, state.edit_field.*, &seed_buffer, atoms) catch {
        state.edit_present.* = 0;
        state.edit_invalid.* = 1;
        return;
    };
    if (!isEditing(state)) bumpTargetEpoch(state);
    state.edit_present.* = 1;
    state.edit_invalid.* = 0;
    state.edit_commit.* = 0;
    state.edit_row.* = state.selected_row.*;
    setEditText(state, initial);
    state.edit_serial.* +%= 1;
}

/// Adds `text` to the edited text, as typing does before the editor holds the edit.
fn appendEditText(state: State, text: []const u8) void {
    const before = editText(state);
    // One payload of both parts, filled where it lies: the text has no bound to stage it in.
    const joined = state.owner.allocatePayload(before.len + text.len, .@"1") catch {
        state.edit_invalid.* = 1;
        return;
    };
    const bytes = state.owner.payloadBytesMut(joined);
    @memcpy(bytes[0..before.len], before);
    @memcpy(bytes[before.len..], text);
    state.edit_text.* = .{ .payload = joined };
}

/// Commits and then moves. While the caller's text editor holds the edit, the commit waits for
/// its report of its text (`Outcome.edit`, `mark_saved`), so it has every character typed
/// before it; otherwise the text is here.
fn requestCommit(state: State, table: *Table, atoms: *Atom.Registry, target: ResolvedTarget, order: ViewOrder, movement: Move, rows: u32, cols: u32, ctx: UpdateContext) Outcome {
    if (!ctx.editor_loaded) {
        _ = commitAndMove(state, table, atoms, target, order, movement, rows, cols);
        return .handled;
    }
    state.edit_commit.* = @as(u8, @intFromEnum(movement)) + 1;
    return .{ .edit = .{ .kind = .mark_saved } };
}

// ---- taking the grid's messages ------------------------------------------------------------

/// The tags of the messages a grid takes, from its caller's inbox: those its drawing sends
/// (clicks, the wheel, the header's and the toolbar's buttons), those the caller's actions and
/// subscriptions deliver under them, and the clipboard's and a column menu's answers. Each
/// carries the grid's instance at the start of its user data, or nothing (`instanceOf`).
pub const Msg = enum(u64) {
    /// A click on a cell; its user data is a `CellClick`.
    cell_click = Atom.from("cell_click").value(),
    /// A character typed; its payload is an `input.TextInputMsg`.
    char = Atom.from("char").value(),
    /// Clears the selected cell, or the edited text.
    delete = Atom.from("delete").value(),
    /// Leaves the edit, keeping the cell as it was.
    cancel = Atom.from("cancel").value(),
    /// Edits the selected cell starting from its text, or flips a checkbox.
    begin_edit = Atom.from("begin_edit").value(),
    /// Commits the edit and selects the cell below.
    commit_down = Atom.from("commit_down").value(),
    /// Commits the edit and selects the cell above.
    commit_up = Atom.from("commit_up").value(),
    /// Commits the edit and selects the next cell.
    commit_tab = Atom.from("commit_tab").value(),
    /// Commits the edit and selects the previous cell.
    commit_backtab = Atom.from("commit_backtab").value(),
    /// Selects the cell to the left.
    nav_left = Atom.from("nav_left").value(),
    /// Selects the cell to the right.
    nav_right = Atom.from("nav_right").value(),
    /// Selects the cell above.
    nav_up = Atom.from("nav_up").value(),
    /// Selects the cell below.
    nav_down = Atom.from("nav_down").value(),
    /// Selects the row's first cell.
    home = Atom.from("home").value(),
    /// Selects the row's last cell.
    end = Atom.from("end").value(),
    /// Selects the grid's first cell.
    first_cell = Atom.from("first_cell").value(),
    /// Selects the grid's last cell.
    last_cell = Atom.from("last_cell").value(),
    /// Selects the cell a page up.
    page_up = Atom.from("page_up").value(),
    /// Selects the cell a page down.
    page_down = Atom.from("page_down").value(),
    /// Selects the next cell, or the next row's first.
    tab = Atom.from("tab").value(),
    /// Selects the previous cell, or the previous row's last.
    backtab = Atom.from("backtab").value(),
    /// Flips the selected checkbox cell.
    toggle = Atom.from("toggle").value(),
    /// The wheel over the grid; its payload is an `input.MouseScrollMsg`.
    wheel = Atom.from("wheel").value(),
    /// Copies the selected cell (`Outcome.copy`).
    copy = Atom.from("copy").value(),
    /// Asks to paste over the selected cell (`Outcome.paste_wanted`).
    paste = Atom.from("paste").value(),
    /// The clipboard's text, its payload, for a `ClipboardTarget`, its user data.
    paste_reply = Atom.from("paste_reply").value(),
    /// A header was clicked: sort by its column, the other way, or not at all.
    table_header_sort = Atom.from("table_header_sort").value(),
    /// A header's menu button, its user data a `ColumnRef`: answers `Outcome.column_menu`.
    table_column_menu = Atom.from("table_column_menu").value(),
    /// The tag a caller asks its column menu's answer under; `update` takes it and does
    /// nothing, the caller applying the answer (`applyColumnAction`).
    table_column_menu_reply = Atom.from("table_column_menu_reply").value(),
    /// The sort's chip: back to the table's order.
    table_clear_sort = Atom.from("table_clear_sort").value(),
    /// The hidden columns' chip: shows every column.
    table_show_columns = Atom.from("table_show_columns").value(),
    /// The frozen chip: nothing stays in place.
    table_unfreeze = Atom.from("table_unfreeze").value(),
    /// A click on the filter: it takes the keyboard.
    table_filter_focus = Atom.from("table_filter_focus").value(),
    /// Typing in the filter; its payload is an `input.TextInputMsg`.
    table_filter_text = Atom.from("table_filter_text").value(),
    /// A key in the filter; its payload is an `input.KeyInputMsg`.
    table_filter_key = Atom.from("table_filter_key").value(),
    /// The filter's clear button: empties it.
    table_filter_clear = Atom.from("table_filter_clear").value(),
    /// The owner's RET on a grid read only: its selected row is chosen (`Outcome.chosen`).
    table_choose = Atom.from("table_choose").value(),
    _,
};

/// A column of a grid: the grid's instance, and the field.
pub const ColumnRef = extern struct {
    /// The grid's instance, which its caller names it by.
    instance: Atom,
    /// The column's field.
    field: u32,
};

/// What a choice of a column's menu does to the grid (`applyColumnAction`). Its values are
/// small numbers a caller may carry in a byte.
pub const ColumnAction = enum(u8) { sort_ascending, sort_descending, clear_sort, hide, show_all, freeze_columns, unfreeze_columns, freeze_rows, unfreeze_rows };

/// The most choices a column's menu has.
pub const max_column_choices = @typeInfo(ColumnAction).@"enum".fields.len;

/// A choice of a column's menu: what it is called and what it does.
pub const ColumnChoice = struct {
    /// The choice's name, a person reads; static.
    label: []const u8,
    /// What choosing it does.
    action: ColumnAction,
};

/// The choices `field`'s menu offers, those that would change something, into `choices`:
/// sorting by it, back to the table's order, hiding it, showing all, and freezing columns
/// through it or rows through the selection, and unfreezing them. A slice of `choices`.
pub fn columnMenuChoices(state: State, field: u32, choices: *[max_column_choices]ColumnChoice) []const ColumnChoice {
    var count: usize = 0;
    choices[count] = .{ .label = "Ascending", .action = .sort_ascending };
    count += 1;
    choices[count] = .{ .label = "Descending", .action = .sort_descending };
    count += 1;
    if (state.sort_column.* != 0) {
        choices[count] = .{ .label = "Unsorted", .action = .clear_sort };
        count += 1;
    }
    if (field < 64) {
        choices[count] = .{ .label = "Hide", .action = .hide };
        count += 1;
    }
    if (state.hidden_columns.* != 0) {
        choices[count] = .{ .label = "Show all", .action = .show_all };
        count += 1;
    }
    choices[count] = .{ .label = "Freeze columns", .action = .freeze_columns };
    count += 1;
    if (state.frozen_columns.* != 0) {
        choices[count] = .{ .label = "Unfreeze columns", .action = .unfreeze_columns };
        count += 1;
    }
    if (state.selected_present.* != 0) {
        choices[count] = .{ .label = "Freeze rows", .action = .freeze_rows };
        count += 1;
    }
    if (state.frozen_rows.* != 0) {
        choices[count] = .{ .label = "Unfreeze rows", .action = .unfreeze_rows };
        count += 1;
    }
    return choices[0..count];
}

/// Applies `action`, chosen from `field`'s menu, to the grid's state over `table`: nothing for
/// a field the grid does not show. Hiding keeps the last column shown; freezing columns keeps
/// those through `field`, freezing rows those through the selection. Over a slice of a larger set
/// (`OrderContext.rows`) a sort chosen is the state's to show and the caller's to apply, as
/// `Outcome.sort_wanted` says for a header's.
pub fn applyColumnAction(state: State, table: *const Table, field: u32, action: ColumnAction, ctx: OrderContext) void {
    if (field >= ctx.presentation.shownFields(table)) return;
    const order = viewOrder(state, table, ctx);
    switch (action) {
        .sort_ascending, .sort_descending => {
            state.sort_column.* = field + 1;
            state.sort_descending.* = @intFromBool(action == .sort_descending);
        },
        .clear_sort => {
            state.sort_column.* = 0;
            state.sort_descending.* = 0;
        },
        .hide => {
            // The last column shown stays: a grid of no columns has nothing to select.
            if (field < 64 and order.columnCount() > 1) state.hidden_columns.* |= @as(u64, 1) << @intCast(field);
        },
        .show_all => state.hidden_columns.* = 0,
        .freeze_columns => if (order.columnPosition(field)) |position| {
            state.frozen_columns.* = position + 1;
            state.horizontal_scroll.* = 0;
        },
        .unfreeze_columns => state.frozen_columns.* = 0,
        .freeze_rows => if (order.rowPosition(state.selected_row.*)) |position| {
            state.frozen_rows.* = position + 1;
            state.scroll.* = 0;
        },
        .unfreeze_rows => state.frozen_rows.* = 0,
    }
}

/// Where a paste is wanted (`Outcome.paste_wanted`), which the clipboard's answer carries back:
/// it is pasted only while the grid's instance, incarnation and selection are still these.
pub const ClipboardTarget = extern struct {
    /// The grid's instance.
    instance: Atom,
    /// The state's `target_epoch` when the paste was asked.
    target_epoch: u32,
    /// The caller's `UpdateContext.incarnation` when the paste was asked.
    incarnation: u32 = 0,
};

/// The grid a message is for: the instance its user data begins with, as every message a grid
/// sends itself does; none (0) for one without, as a caller's action's.
pub fn instanceOf(received: sequencer.Message) Atom {
    if (received.user_data.len < @sizeOf(Atom)) return @enumFromInt(0);
    return std.mem.bytesToValue(Atom, received.user_data[0..@sizeOf(Atom)]);
}

/// What `update` needs besides the state and the table: the grid's size, whose the edit is,
/// memory, and how the grid is presented.
pub const UpdateContext = struct {
    /// The grid's width as the caller lays it out, in pixels: what its keys page by.
    viewport_w: f32,
    /// The grid's height as the caller lays it out, in pixels: what its keys page by. A caller
    /// that draws the grid inline (`RenderContext.inline_rows`) passes the height of the view it
    /// scrolls the grid in, as a page's, so a page key moves the cursor by what that view shows.
    viewport_h: f32,
    /// The caller's count of the grid's incarnations (a generation of the row that keeps its
    /// state, say): a paste asked by an earlier one is dropped.
    incarnation: u32 = 0,
    /// Names atom and reference cells, and interns what is typed into one as it is committed.
    atoms: *Atom.Registry,
    /// Frame memory: the view order, and the texts an `Outcome` carries, kept until the caller
    /// frees it.
    allocator: std.mem.Allocator,
    /// Whether the caller's text editor holds the grid's current edit, so typing and commits go
    /// through it (`Outcome.edit`).
    editor_loaded: bool = false,
    /// How the grid is presented: with `read` access nothing edits, clears, flips or pastes over
    /// a cell, and a row is chosen.
    presentation: Presentation = .{},
    /// Which rows of what the grid shows the table holds: over a slice of a larger set the grid
    /// answers a change of its filter or sort for the caller to apply.
    rows: Rows = .all,

    /// The order context of the grid this updates.
    pub fn orderContext(ctx: UpdateContext) OrderContext {
        return .{ .atoms = ctx.atoms, .allocator = ctx.allocator, .presentation = ctx.presentation, .rows = ctx.rows };
    }
};

fn pasteTargetCurrent(target: ClipboardTarget, instance: Atom, incarnation: u32, state: State, table: *const Table) bool {
    if (target.instance != instance or target.incarnation != incarnation or target.target_epoch != state.target_epoch.*) return false;
    return state.selected_present.* != 0 and table.isAllocated(state.selected_row.*);
}

fn finalizeActiveEdit(state: State, table: *Table, atoms: *Atom.Registry) bool {
    values.commitEditText(table, state.edit_row.*, state.edit_field.*, editText(state), atoms) catch {
        state.edit_invalid.* = 1;
        return false;
    };
    state.edit_present.* = 0;
    state.edit_invalid.* = 0;
    state.edit_commit.* = 0;
    bumpTargetEpoch(state);
    state.committed.* = 1;
    return true;
}

fn commitAndMove(state: State, table: *Table, atoms: *Atom.Registry, target: ResolvedTarget, order: ViewOrder, movement: Move, rows: u32, cols: u32) bool {
    if (!finalizeActiveEdit(state, table, atoms)) return false;
    moveActive(state, table, target, order, movement, rows, rows, cols);
    return true;
}

/// The selected cell's text, or the edit's while one is open, to copy, in the context's memory;
/// none with no cell selected, or with no memory for the text, which is logged as a copy dropped.
fn copyText(state: State, table: *const Table, ctx: UpdateContext) ?[]const u8 {
    if (state.selected_present.* == 0) return null;
    var buf: [values.cell_text_buffer_size]u8 = undefined;
    const text = if (isEditing(state)) editText(state) else values.cellText(table, state.selected_row.*, state.edit_field.*, &buf, ctx.atoms);
    return ctx.allocator.dupe(u8, text) catch {
        Log.warn("grid_copy_dropped", .{ .bytes = text.len, .reason = "out of memory" });
        return null;
    };
}

fn activateCell(state: State, table: *Table, atoms: *Atom.Registry, target: ResolvedTarget, row: u32, field: u32) bool {
    if (!table.isAllocated(row) or field >= table.getSchema().fields.len) return true;
    if (target == .row and row != target.row.row) return true;
    const already = state.selected_present.* != 0 and state.selected_row.* == row and state.edit_field.* == field;
    if (already and isEditing(state)) return true;

    if (isEditing(state) and !finalizeActiveEdit(state, table, atoms)) return false;

    if (!already) {
        state.selected_present.* = 1;
        state.selected_row.* = row;
        state.selected_row_generation.* = generationOf(table, row);
        state.edit_field.* = field;
        state.edit_invalid.* = 0;
        bumpTargetEpoch(state);
    } else if (values.flipsOnActivate(&table.getSchema().fields[field])) {
        values.toggleCheckbox(table, row, field);
        state.committed.* = 1;
    } else {
        beginEdit(state, table, atoms, .seed);
    }
    return true;
}

/// Where a paste over the selected cell would go; none with no cell selected.
fn pasteTarget(instance: Atom, state: State, ctx: UpdateContext) ?ClipboardTarget {
    if (state.selected_present.* == 0) return null;
    return .{ .instance = instance, .target_epoch = state.target_epoch.*, .incarnation = ctx.incarnation };
}

/// What the caller's text editor is to do, `kind` with `text`, which is copied into the
/// context's memory; handled, asking nothing, when there is no room for it, which is logged as
/// an edit dropped.
fn editorEdit(ctx: UpdateContext, kind: EditKind, text: []const u8) Outcome {
    const kept = ctx.allocator.dupe(u8, text) catch {
        Log.warn("grid_edit_dropped", .{ .kind = @tagName(kind), .bytes = text.len, .reason = "out of memory" });
        return .handled;
    };
    return .{ .edit = .{ .kind = kind, .text = kept } };
}

/// Takes one of the grid's messages, `received`, for the grid `instance`, which its caller
/// found it is for (`instanceOf`), writing the state and `table` and nothing else: what needs a
/// system is answered in the `Outcome`, for the caller to ask. A kernel of the caller's calls
/// it, the only writer of the state. An error is the message's that could not be read.
pub fn update(state: State, instance: Atom, target: Target, message: Msg, received: sequencer.Message, table: *Table, ctx: UpdateContext) !Outcome {
    state.committed.* = 0;

    const atoms = ctx.atoms;
    const order_context = ctx.orderContext();
    if (try updateView(state, table, message, received, ctx)) |outcome| return outcome;
    // While the filter has the keyboard, keys that reach here move nothing in the grid.
    const reaches_grid = switch (message) {
        .cell_click, .wheel, .paste_reply => true,
        else => false,
    };
    if (filterHasKeys(state, ctx.presentation) and !reaches_grid) return .handled;
    const order = viewOrder(state, table, order_context);
    const prepared = prepare(state, table, target, order) orelse return .invalidated;
    const rows = visibleRows(ctx.viewport_h, bodyOf(prepared.target), ctx.presentation);
    const cols = if (prepared.target == .table) visibleColumns(ctx.presentation.columnsWidth(ctx.viewport_w)) else 1;
    if (prepared.changed and state.selected_present.* != 0) reveal(state, table, prepared.target, order, rows, cols);

    switch (message) {
        .paste_reply => {
            if (ctx.presentation.access == .read) return .handled;
            // The clipboard's text is the payload.
            const pasted = received.payload;
            const clipboard_target = try received.userDataAs(ClipboardTarget);
            if (!pasteTargetCurrent(clipboard_target.*, instance, ctx.incarnation, state, table)) return .handled;
            if (isEditing(state)) {
                // The caller's text editor pastes, and its report brings the text back here.
                if (ctx.editor_loaded) return editorEdit(ctx, .paste, pasted);
                appendEditText(state, pasted);
                return .handled;
            } else values.commitEditText(table, state.selected_row.*, state.edit_field.*, pasted, atoms) catch {
                // What failed to commit is left to edit, marked invalid; the editor takes it as it
                // is, so its report matches and the mark stays until the text is changed.
                beginEdit(state, table, atoms, .replace);
                setEditText(state, pasted);
                state.edit_invalid.* = 1;
            };
            state.committed.* = 1;
            return .mutated;
        },
        .copy => {
            const text = copyText(state, table, ctx) orelse return .handled;
            return .{ .copy = .{ .text = text } };
        },
        .paste => {
            if (ctx.presentation.access != .edit) return .handled;
            const wanted = pasteTarget(instance, state, ctx) orelse return .handled;
            return .{ .paste_wanted = wanted };
        },
        .table_choose => {
            if (ctx.presentation.access != .read or state.selected_present.* == 0) return .ignored;
            const selected_row = state.selected_row.*;
            const generation = generationOf(table, selected_row);
            return .{ .chosen = .{ .row = selected_row, .generation = generation } };
        },
        .cell_click => {
            const cell = try received.userDataAs(CellClick);
            state.filterField().setFocused(false);
            // Read only, a click on the selected cell, a double click, chooses its row, where it
            // would edit the cell; a click on another moves the selection, as in a grid that edits.
            const on_selected_cell = state.selected_present.* != 0 and state.selected_row.* == cell.row and state.edit_field.* == cell.field;
            if (ctx.presentation.access == .read and on_selected_cell and table.isAllocated(cell.row)) {
                const generation = table.rowGeneration(cell.row);
                return .{ .chosen = .{ .row = cell.row, .generation = generation } };
            }
            if (activateCell(state, table, atoms, prepared.target, cell.row, cell.field))
                reveal(state, table, prepared.target, order, rows, cols);
            return if (state.committed.* != 0) .mutated else .handled;
        },
        .wheel => {
            const m = try received.payloadAs(input.MouseScrollMsg);
            // Alt belongs to whatever holds this view, and the row form has no sideways scroll.
            if (m.modifiers.alt) return .handled;
            switch (prepared.target) {
                .table => {
                    if (m.modifiers.shift) {
                        if (m.y > 0) state.horizontal_scroll.* -|= 1 else if (m.y < 0) state.horizontal_scroll.* += 1;
                    } else {
                        if (m.y > 0) state.scroll.* -|= 1 else if (m.y < 0) state.scroll.* += 1;
                        if (m.x > 0) state.horizontal_scroll.* += 1 else if (m.x < 0) state.horizontal_scroll.* -|= 1;
                    }
                    clampGridScroll(state, order, rows, cols);
                },
                .row => {
                    if (!m.modifiers.shift) {
                        if (m.y > 0) state.scroll.* -|= 1 else if (m.y < 0) state.scroll.* += 1;
                        state.scroll.* = clampScroll(state.scroll.*, @intCast(table.getSchema().fields.len), rows);
                    }
                    state.horizontal_scroll.* = 0;
                },
            }
            return .handled;
        },
        else => {},
    }
    if (isEditing(state)) {
        // Keys reach the caller's text editor through its own actions; here are typed
        // characters, and the cell's own actions: commit and move, or cancel.
        var outcome: Outcome = .handled;
        switch (message) {
            .char => {
                const m = try received.payloadAs(input.TextInputMsg);
                var bytes: [4]u8 = undefined;
                if (m.codepoint >= 32 and m.codepoint != 127) {
                    const utf8 = input.typedText(m, &bytes) orelse return .handled;
                    if (ctx.editor_loaded) {
                        outcome = editorEdit(ctx, .insert, utf8);
                    } else appendEditText(state, utf8);
                }
            },
            .cancel => {
                state.edit_present.* = 0;
                state.edit_invalid.* = 0;
                state.edit_commit.* = 0;
                bumpTargetEpoch(state);
            },
            // The caller's text editor empties the cell's text; its report brings the empty
            // text back here.
            .delete => if (ctx.editor_loaded) {
                outcome = .{ .edit = .{ .kind = .clear } };
            } else setEditText(state, ""),
            .commit_down => outcome = requestCommit(state, table, atoms, prepared.target, order, .down, rows, cols, ctx),
            .commit_up => outcome = requestCommit(state, table, atoms, prepared.target, order, .up, rows, cols, ctx),
            .commit_tab => outcome = requestCommit(state, table, atoms, prepared.target, order, .tab_forward, rows, cols, ctx),
            .commit_backtab => outcome = requestCommit(state, table, atoms, prepared.target, order, .tab_back, rows, cols, ctx),
            else => return .ignored,
        }
        return if (state.committed.* != 0) .mutated else outcome;
    }
    // Read only, what would edit or change a cell does nothing.
    if (ctx.presentation.access == .read) switch (message) {
        .char, .begin_edit, .toggle, .delete => return .handled,
        else => {},
    };
    const movement: Move = switch (message) {
        .char => {
            const m = try received.payloadAs(input.TextInputMsg);
            if (m.codepoint >= 32 and m.codepoint != 127 and state.selected_present.* != 0 and !values.flipsOnActivate(&table.getSchema().fields[state.edit_field.*])) {
                // Typing on a cell replaces it: the edit starts with the character.
                beginEdit(state, table, atoms, .replace);
                var bytes: [4]u8 = undefined;
                const utf8 = input.typedText(m, &bytes) orelse return .handled;
                appendEditText(state, utf8);
            }
            return .handled;
        },
        .begin_edit => {
            if (state.selected_present.* != 0) {
                if (values.flipsOnActivate(&table.getSchema().fields[state.edit_field.*])) values.toggleCheckbox(table, state.selected_row.*, state.edit_field.*) else beginEdit(state, table, atoms, .seed);
            }
            return .handled;
        },
        .toggle => {
            values.toggleCheckbox(table, state.selected_row.*, state.edit_field.*);
            state.committed.* = 1;
            return .handled;
        },
        .delete => {
            if (state.selected_present.* == 0) return .handled;
            if (!values.clearCell(table, state.selected_row.*, state.edit_field.*)) return .handled;
            state.committed.* = 1;
            return .mutated;
        },
        .nav_left => .left,
        .nav_right => .right,
        .nav_up => .up,
        .nav_down => .down,
        .home => .first_col,
        .end => .last_col,
        .first_cell => .first_cell,
        .last_cell => .last_cell,
        .page_up => .page_up,
        .page_down => .page_down,
        .tab => .tab_forward,
        .backtab => .tab_back,
        else => return .ignored,
    };
    moveActive(state, table, prepared.target, order, movement, rows, rows, cols);
    return .handled;
}

/// Keeps the scrolls within the lines past the frozen ones.
fn clampGridScroll(state: State, order: ViewOrder, rows: u32, cols: u32) void {
    const row_split = splitVisible(order.frozen_rows, rows);
    const column_split = splitVisible(order.frozen_columns, cols);
    state.scroll.* = clampScroll(state.scroll.*, order.rowCount() -| row_split.frozen, row_split.scrolling);
    state.horizontal_scroll.* = clampScroll(state.horizontal_scroll.*, order.columnCount() -| column_split.frozen, column_split.scrolling);
}

/// The messages that change how the grid is viewed, not what it holds: sorting, the column
/// menu, showing columns, unfreezing and the filter. Null for any other message. Over a slice of
/// a larger set a change of the sort or the filter is answered for the caller to apply
/// (`Outcome.sort_wanted`, `Outcome.filter_changed`); without the toolbar the filter's messages
/// are ignored.
fn updateView(state: State, table: *Table, message: Msg, received: sequencer.Message, ctx: UpdateContext) !?Outcome {
    switch (message) {
        .table_header_sort => {
            // From a key, which carries no column (or only the view), the selected cell's.
            const column = if (received.userDataAs(ColumnRef)) |ref| ref.field else |_| state.edit_field.*;
            if (column >= ctx.presentation.shownFields(table)) return .handled;
            // Ascending, then descending, then the table's own order again.
            if (state.sort_column.* != column + 1) {
                state.sort_column.* = column + 1;
                state.sort_descending.* = 0;
            } else if (state.sort_descending.* == 0) {
                state.sort_descending.* = 1;
            } else {
                state.sort_column.* = 0;
                state.sort_descending.* = 0;
            }
            return sortAnswer(state, ctx);
        },
        .table_column_menu => {
            const column = try received.userDataAs(ColumnRef);
            if (column.field >= ctx.presentation.shownFields(table)) return .handled;
            return .{ .column_menu = .{ .field = column.field } };
        },
        // The menu's answer, which the caller applies (`applyColumnAction`).
        .table_column_menu_reply => {},
        .table_clear_sort => {
            state.sort_column.* = 0;
            state.sort_descending.* = 0;
            return sortAnswer(state, ctx);
        },
        .table_show_columns => state.hidden_columns.* = 0,
        .table_unfreeze => {
            state.frozen_rows.* = 0;
            state.frozen_columns.* = 0;
        },
        .table_filter_focus, .table_filter_clear, .table_filter_text, .table_filter_key => {
            if (ctx.presentation.toolbar == .hidden) return .ignored;
            return try updateFilter(state, message, received, ctx);
        },
        else => return null,
    }
    return .handled;
}

/// One of the filter's messages, for a grid that has its toolbar.
fn updateFilter(state: State, message: Msg, received: sequencer.Message, ctx: UpdateContext) !Outcome {
    const field = state.filterField();
    var edited = false;
    switch (message) {
        .table_filter_focus => field.setFocused(true),
        .table_filter_clear => {
            edited = field.query().len != 0;
            field.clear();
            state.scroll.* = 0;
        },
        .table_filter_text => {
            const typed = try received.payloadAs(input.TextInputMsg);
            edited = filter_field.typeText(field, typed);
            if (edited) state.scroll.* = 0;
        },
        .table_filter_key => {
            const pressed = try received.payloadAs(input.KeyInputMsg);
            // `C-g` leaves the filter keeping its text, as RET does; Escape empties it.
            if (pressed.key == .g and pressed.modifiers.control) {
                field.setFocused(false);
                return .handled;
            }
            edited = filter_field.pressKey(field, pressed) == .edited;
            if (edited) state.scroll.* = 0;
        },
        else => unreachable,
    }
    if (edited and ctx.rows == .slice) return .filter_changed;
    return .handled;
}

/// What a change of the sort comes to: the grid sorts its rows itself, or over a slice the
/// caller is asked to.
fn sortAnswer(state: State, ctx: UpdateContext) Outcome {
    if (ctx.rows == .all) return .handled;
    const sort_field = state.sort_column.*;
    const field: ?u32 = if (sort_field == 0) null else sort_field - 1;
    return .{ .sort_wanted = .{ .field = field, .descending = state.sort_descending.* != 0 } };
}

/// Runs one of the grid's messages that carries nothing but its instance, such as a cell
/// action's commit: `update`'s answer.
fn updateMessage(state: State, instance: Atom, target: Target, message: Msg, table: *Table, ctx: UpdateContext) Outcome {
    const received: sequencer.Message = .{ .tag = Atom.from(message), .user_data = std.mem.asBytes(&instance) };
    // Nothing is read from a message that carries only its instance.
    return update(state, instance, target, message, received, table, ctx) catch unreachable;
}

/// The caller's text editor reported the edit's text: keep it, and finish a commit that waited
/// for it (`Outcome.edit`, `mark_saved`), validating the text as any commit does. A changed text
/// is no longer marked invalid. Answers `handled`, `mutated` or `invalidated`.
pub fn editorReport(state: State, target: Target, text: []const u8, table: *Table, ctx: UpdateContext) Outcome {
    state.committed.* = 0;
    const order = viewOrder(state, table, ctx.orderContext());
    const prepared = prepare(state, table, target, order) orelse return .invalidated;
    if (!isEditing(state)) return .handled;
    const changed = !std.mem.eql(u8, text, editText(state));
    setEditText(state, text);
    if (state.edit_commit.* != 0) {
        const movement: Move = @enumFromInt(state.edit_commit.* - 1);
        state.edit_commit.* = 0;
        const rows = visibleRows(ctx.viewport_h, bodyOf(prepared.target), ctx.presentation);
        const cols = if (prepared.target == .table) visibleColumns(ctx.presentation.columnsWidth(ctx.viewport_w)) else 1;
        _ = commitAndMove(state, table, ctx.atoms, prepared.target, order, movement, rows, cols);
        return if (state.committed.* != 0) .mutated else .handled;
    }
    if (changed) state.edit_invalid.* = 0;
    return .handled;
}

/// What a grid listens for now, which says what its caller subscribes it to and offers: nothing
/// (its target is gone), its filter's typing and keys, its cell's editing, or browsing its cells.
pub const Listening = enum { invalidated, filtering, editing, browsing };

/// What the grid listens for now. Settles the state's selection over `table` as `update` does,
/// so a caller's kernel calls it.
pub fn listening(state: State, target: Target, table: *const Table, ctx: OrderContext) Listening {
    const order = viewOrder(state, table, ctx);
    const prepared = prepare(state, table, target, order) orelse return .invalidated;
    if (filterHasKeys(state, ctx.presentation) and prepared.target == .table) return .filtering;
    if (isEditing(state)) return .editing;
    return .browsing;
}

// ---- drawing ----------------------------------------------------------------------------------

/// A field row's padding around a vector's components, which are frames of their own and want
/// the row's height.
const vector_cell_padding: f32 = 2;

/// The components of a vector cell the field view shows side by side; null for any other
/// cell, an absent one, or a vector of more components than a row has room for.
fn shownVectorComponents(table: *const Table, row: u32, desc: *const FieldDescriptor) ?[]const f32 {
    if (desc.view_kind != .vector) return null;
    if (!table.rowHas(row, desc.bit)) return null;
    const component_count: usize = desc.view_kind.vector.components;
    if (component_count > vector_field.max_components) return null;
    const cell = values.cellValue(table, row, desc);
    if (cell.len < desc.size) return null;
    const floats: [*]const f32 = @ptrCast(@alignCast(cell.ptr));
    return floats[0..component_count];
}

/// A vector's components side by side, as every panel shows a vector. They only show: a press
/// is the cell's, which selects it, and typing edits the whole vector as text.
fn drawVectorComponents(comptime role: []const u8, tree: *ui.Tree, instance: Atom, row: u32, field: u32, components: []const f32, scratch: memory_mod.Scratch, vector_style: vector_field.Style) !void {
    // The first component's frame starts where other rows' text does.
    const inset = cell_padding - vector_cell_padding;
    tree.rect(elementId(instance, role ++ ".vector.lead", row, field), .{ .size = .{ .w = .{ .fixed = inset }, .h = .fill } });
    if (vector_field.begin(tree, elementId(instance, role ++ ".vector", row, field))) {
        defer tree.endRect();
        const first_component = elementId(instance, role ++ ".component", row, field);
        for (components, 0..) |number, component_index| {
            const component_id = ui.ElementId{ .atom = first_component.atom, .extra = first_component.extra +% component_index };
            const text = try vector_field.formatNumber(scratch.allocator, number, vector_field.shown_decimals);
            vector_field.component(tree, component_id, .{ .index = component_index, .text = text }, vector_style);
        }
    }
    tree.rect(elementId(instance, role ++ ".vector.trail", row, field), .{ .size = .{ .w = .{ .fixed = inset }, .h = .fill } });
}

fn drawValueContent(comptime role: []const u8, tree: *ui.Tree, instance: Atom, table: *const Table, row: u32, field: u32, edit: ?EditRef, scratch: memory_mod.Scratch, style: Style) !void {
    const desc = &table.getSchema().fields[field];
    const editing = if (edit) |e| e.row == row and e.field == field else false;
    const bit = table.rowHas(row, desc.bit);
    if (editing) {
        if (edit.?.drawable) |editor| {
            // The caller's text editor draws in the text's place, sized as `ui` lays it out.
            const drawable = try scratch.allocator.create(CellDrawable);
            drawable.* = editor;
            tree.custom(elementId(instance, role ++ ".editor", row, field), drawable, .{ .size = .{ .w = .fill, .h = .fill } });
        } else {
            tree.text(elementId(instance, role ++ ".text", row, field), edit.?.text, .{ .font = style.font, .color = style.text, .size_hint = .{ .w = .fill, .h = .fill } });
        }
    } else {
        const text = try cellText(table, row, field, scratch, tree.atoms) orelse return;
        const colour = if (desc.view_kind != .checkbox and !bit) style.dim_text else style.text;
        tree.text(elementId(instance, role ++ ".text", row, field), text, .{ .font = style.font, .color = colour });
    }
}

/// The room `valueText` formats a cell's value into.
pub const ValueTextBuffer = [values.cell_text_buffer_size]u8;

/// A cell's value as text, the text the grid filters, sorts and copies it by, for a caller that
/// compares or shows a cell as the grid reads it (a document matching rows by a key, or naming a
/// row's field in a heading): a checkbox's `true` or `false`, an absent cell's empty text, a text
/// cell's own text (the table's, until the cell is next written), any other value formatted into
/// `buffer` (a number as the grid draws it, an atom or a reference named through `atoms`); empty
/// for a row or field that is not there. Reads as any reader does, never raw storage, so a
/// journaled kernel may call it, and sees what its run sees.
pub fn valueText(table: *const Table, row: u32, field: u32, buffer: *ValueTextBuffer, atoms: *const Atom.Registry) []const u8 {
    return values.cellText(table, row, field, buffer, atoms);
}

/// The text a cell not being edited is drawn as, in `scratch`: a checkbox's `true` or `false`, a
/// missing value's `-`, a text cell's text, any other value formatted; null for a cell too short
/// to hold its value.
fn cellText(table: *const Table, row: u32, field: u32, scratch: memory_mod.Scratch, atoms: *const Atom.Registry) !?[]const u8 {
    const desc = &table.getSchema().fields[field];
    const bit = table.rowHas(row, desc.bit);
    if (desc.view_kind == .checkbox) return if (bit) "true" else "false";
    if (!bit) return "-";
    if (desc.view_kind == .text_field) return try scratch.allocator.dupe(u8, values.rawTextCell(table, row, desc));
    const cell = values.cellValue(table, row, desc);
    if (cell.len < desc.size) return null;
    return try values.formatValue(scratch, desc, cell.ptr, atoms);
}

// ---- columns fit to what they hold ---------------------------------------------------------

/// Measures text as it is drawn, for columns fit to what they hold: the width `text` takes in
/// the font `font`. The caller's, from what draws it (`ofContext`), or a stand-in in a test.
pub const TextMeasure = struct {
    /// What `width_fn` reads; the caller's, alive for the call it is given to.
    context: *const anyopaque,
    /// The width of `text` in `font`, in pixels.
    width_fn: *const fn (context: *const anyopaque, font: roop.Font, text: []const u8) f32,

    /// The width of `text` in `font`.
    pub fn width(measure: TextMeasure, font: roop.Font, text: []const u8) f32 {
        return measure.width_fn(measure.context, font, text);
    }

    /// What `ctx`, the context a panel draws into, measures text as.
    pub fn ofContext(ctx: *const roop.Context) TextMeasure {
        return .{ .context = ctx, .width_fn = contextWidth };
    }

    fn contextWidth(context: *const anyopaque, font: roop.Font, text: []const u8) f32 {
        const ctx: *const roop.Context = @ptrCast(@alignCast(context));
        return ctx.measureText(font, text).w;
    }
};

/// Columns fit to what they hold (`fitColumns`), for `RenderContext.fitted`. Its slices are in
/// the allocator `fitColumns` was given.
pub const Fitted = struct {
    /// The fields drawn as columns, in order: those asked, less the trailing ones that did not
    /// fit.
    columns: []const u32,
    /// Each column's width in pixels, in `columns`' order; the fill column's is what the others
    /// left when fitted, which the draw gives it whatever it is then.
    widths: []const f32,
    /// The place in `columns` of the column that takes what the others leave.
    fill: usize,
};

/// The narrowest a column fit to what it holds is, in pixels.
pub const fit_min_width: f32 = 48;
/// The widest share of the width a column fit to what it holds takes.
pub const fit_max_share: f32 = 0.4;
/// The least a fill column keeps before columns after it are left out, in pixels.
pub const fill_min_width: f32 = 200;

/// `columns`, fields of `table` drawn in that order, fit to what they hold in `available`
/// pixels: each but `fill_field` as wide as its widest text among its header's name and the
/// cells of `rows` (row ids of `table`; a caller gives every row its table shows, or the first
/// so many, so the widths do not change as its rows scroll), measured by `measure` in
/// `style.font`, with its padding, at least `fit_min_width` and at most `fit_max_share` of
/// `available`; the fill column (the last when `fill_field` is none of `columns`) takes the
/// rest. When they do not fit with the fill column keeping `fill_min_width`, the columns after
/// it are left out from the last, then those before it from the nearest to it, until they do or
/// only it is left. At most `max_visible_columns`; none for no columns. Writes nothing; its
/// slices are in `allocator`.
pub fn fitColumns(table: *const Table, columns: []const u32, fill_field: u32, rows: []const u32, available: f32, measure: TextMeasure, style: Style, atoms: *const Atom.Registry, scratch: memory_mod.Scratch) !Fitted {
    const allocator = scratch.allocator;
    const fields = table.getSchema().fields;
    var kept: std.ArrayList(u32) = .empty;
    for (columns) |field| {
        if (field >= fields.len or kept.items.len == max_visible_columns) continue;
        try kept.append(allocator, field);
    }
    if (kept.items.len == 0) return .{ .columns = &.{}, .widths = &.{}, .fill = 0 };
    const fill = std.mem.indexOfScalar(u32, kept.items, fill_field) orelse kept.items.len -| 1;
    const widths = try allocator.alloc(f32, kept.items.len);
    const widest = @max(available * fit_max_share, fit_min_width);
    for (kept.items, widths, 0..) |field, *width, index| {
        if (index == fill) {
            width.* = 0;
            continue;
        }
        var content = measure.width(style.font, fields[field].name);
        for (rows) |row| {
            if (!table.isAllocated(row)) continue;
            const text = try cellText(table, row, field, scratch, atoms) orelse continue;
            content = @max(content, measure.width(style.font, text));
        }
        width.* = std.math.clamp(@ceil(content + 2 * cell_padding), fit_min_width, widest);
    }
    // Left out until the fill column keeps its least: those after it from the last, then those
    // before it from the nearest to it, so the first column, which names a row, goes last.
    const keep = try allocator.alloc(bool, kept.items.len);
    @memset(keep, true);
    var total = sumWidths(widths);
    var next_after = kept.items.len;
    var next_before = fill;
    while (total + fill_min_width > available) {
        const dropped = if (next_after > fill + 1) blk: {
            next_after -= 1;
            break :blk next_after;
        } else if (next_before > 0) blk: {
            next_before -= 1;
            break :blk next_before;
        } else break;
        keep[dropped] = false;
        total -= widths[dropped];
    }
    var drawn: std.ArrayList(u32) = .empty;
    var drawn_widths: std.ArrayList(f32) = .empty;
    var drawn_fill: usize = 0;
    for (kept.items, widths, keep, 0..) |field, width, kept_column, index| {
        if (!kept_column) continue;
        if (index == fill) drawn_fill = drawn.items.len;
        try drawn.append(allocator, field);
        try drawn_widths.append(allocator, width);
    }
    drawn_widths.items[drawn_fill] = @max(available - total, 0);
    return .{ .columns = drawn.items, .widths = drawn_widths.items, .fill = drawn_fill };
}

fn sumWidths(widths: []const f32) f32 {
    var total: f32 = 0;
    for (widths) |width| total += width;
    return total;
}

/// The lines of one axis on screen, as positions of its order: the frozen ones, then
/// `scrolling` from `first`.
const ShownLines = struct { positions: []const u32, frozen: usize };

fn shownLines(allocator: std.mem.Allocator, frozen: u32, first: u32, scrolling: u32) !ShownLines {
    const shown = try allocator.alloc(u32, frozen + scrolling);
    for (shown[0..frozen], 0..) |*position, index| position.* = @intCast(index);
    for (shown[frozen..], 0..) |*position, index| position.* = first + @as(u32, @intCast(index));
    return .{ .positions = shown, .frozen = frozen };
}

/// The columns on screen: the frozen ones, then those from the horizontal scroll.
fn shownColumnLines(allocator: std.mem.Allocator, columns: Order, split: Split, scroll: u32) !ShownLines {
    const frozen = @min(split.frozen, columns.len);
    const first = @min(frozen + scroll, columns.len);
    const scrolling = @min(split.scrolling, columns.len - first);
    return shownLines(allocator, frozen, first, scrolling);
}

fn frozenLine(tree: *ui.Tree, id: ui.ElementId, axis: ui.Axis, style: Style) void {
    const size: ui.Size = if (axis == .vertical) .{ .w = .{ .fixed = frozen_line_width }, .h = .fill } else .{ .w = .fill, .h = .{ .fixed = frozen_line_width } };
    tree.rect(id, .{ .size = size, .bg = style.active_border });
}

/// Which stripe the row at `position` of the view order, drawn `index` from the grid's top, is
/// in: inline, by its position, so a caller that draws a table's rows as several grids, or
/// scrolls them, keeps each row's stripe; else by where it is drawn.
fn stripeOf(ctx: RenderContext, position: u32, index: usize) usize {
    if (ctx.inline_rows != null) return position;
    return index;
}

/// The fill of the row in stripe `index`: the selection's, or the stripes'.
fn rowFill(style: Style, selected: bool, index: usize) ui.Color {
    if (selected) return style.selected_bg;
    return if (index % 2 == 0) style.row_bg_a else style.row_bg_b;
}

/// The rows a grid of rows draws: the frozen positions and those after them, as positions of
/// the view order, and how tall its root is.
const DrawnRows = struct { shown: ShownLines, height: f32 };

/// The rows a grid of rows draws `viewport_w` by `viewport_h`: an inline draw's, or the whole
/// rows of its window, the same window a caller asks of `window`, less a last row only partly in
/// view, which the grid leaves to its background.
fn drawnRows(ctx: RenderContext, state: State, order: ViewOrder, viewport_w: f32, viewport_h: f32, allocator: std.mem.Allocator) !DrawnRows {
    if (ctx.inline_rows) |asked| {
        const first = @min(asked.first, order.rowCount());
        const left = order.rowCount() - first;
        const count = @min(asked.count, left, max_visible_rows);
        const shown = try shownLines(allocator, 0, first, count);
        return .{ .shown = shown, .height = inlineHeight(count, ctx.presentation) };
    }
    const rows = visibleRows(viewport_h, .grid, ctx.presentation);
    const body = bodySize(viewport_w, viewport_h, ctx.presentation);
    const in_view = window(state, body, order.rowCount());
    const whole_scrolling = splitVisible(in_view.frozen, rows).scrolling;
    const shown = try shownLines(allocator, in_view.frozen, in_view.first, @min(in_view.count, whole_scrolling));
    return .{ .shown = shown, .height = viewport_h };
}

fn drawTable(ctx: RenderContext, tree: *ui.Tree, instance: Atom, table: *const Table, state: State, order: ViewOrder, edit: ?EditRef, viewport_w: f32, viewport_h: f32, scratch: memory_mod.Scratch, style: Style) !void {
    const columns_width = ctx.presentation.columnsWidth(viewport_w);
    // Fitted, every column drawn is one the caller fit in, from the first, as it fit them: the
    // state's horizontal scroll and frozen columns would move the widths off their columns, and
    // are not read. Else as many as the shares allow, past the frozen ones and the scroll.
    const fitted = ctx.fitted != null;
    const cols: u32 = if (fitted) @intCast(order.columnCount()) else visibleColumns(columns_width);
    const column_split: Split = if (fitted) .{ .frozen = 0, .scrolling = cols } else splitVisible(order.frozen_columns, cols);
    const column_scroll: u32 = if (fitted) 0 else state.horizontal_scroll.*;
    const shown_columns = try shownColumnLines(scratch.allocator, order.columns, column_split, column_scroll);
    const drawn = try drawnRows(ctx, state, order, viewport_w, viewport_h, scratch.allocator);
    // A grid drawn inline takes no wheel: its encloser scrolls it.
    const wheel: ?ui.Target = if (ctx.inline_rows == null) targetOf(tree, ctx.inbox, Msg.wheel, instance) else null;
    if (!tree.beginRect(elementId(instance, "root", 0, 0), .{
        .axis = .vertical,
        .size = .{ .w = .{ .fixed = viewport_w }, .h = .{ .fixed = drawn.height } },
        .bg = style.row_bg_b,
        .clip_content = true,
        .on_scroll = wheel,
    })) return;
    defer tree.endRect();
    if (ctx.presentation.toolbar == .shown) drawToolbar(ctx, tree, instance, table, state, order, scratch, style);
    const column_width = cellWidth(columns_width, order.columnCount());
    if (ctx.presentation.header != .hidden) drawHeader(ctx, tree, instance, table, state, order.columns, shown_columns, column_width, style);
    // The body takes the wheel too, so the tree's commit records its place (`bodyElement`).
    const body_id = bodyElement(instance);
    if (!tree.beginRect(body_id, .{ .axis = .vertical, .size = .{ .w = .fill, .h = .fill }, .on_scroll = wheel })) return;
    defer tree.endRect();
    const shown_rows = drawn.shown;
    for (shown_rows.positions, 0..) |position, i| {
        if (i == shown_rows.frozen and shown_rows.frozen > 0) frozenLine(tree, elementId(instance, "table.frozen_rows", 0, 0), .horizontal, style);
        // A position the table does not hold (past a slice's rows, or a row freed after the
        // order was made) is drawn empty: nothing is read of it.
        const held = order.rowAt(position);
        const row = held orelse {
            drawEmptyRow(tree, instance, position, stripeOf(ctx, position, i), style);
            continue;
        };
        if (!table.isAllocated(row)) {
            drawEmptyRow(tree, instance, position, stripeOf(ctx, position, i), style);
            continue;
        }
        // Over a slice a row is numbered by its place in the set; else by its row id.
        const number = if (ctx.rows == .all) row else position;
        // Drawn inline, the caller's row is selected, whole; else the state's row and cell.
        const selected = if (ctx.inline_rows) |asked| asked.selected == row else state.selected_present.* != 0 and state.selected_row.* == row;
        const cell_selected = ctx.inline_rows == null and selected;
        const stripe = stripeOf(ctx, position, i);
        if (!tree.beginRect(elementId(instance, "table.row", row, 0), .{ .axis = .horizontal, .size = .{ .w = .fill, .h = .{ .fixed = row_height } }, .bg = rowFill(style, selected, stripe) })) continue;
        defer tree.endRect();
        const id_buf = tree.allocBuffer(16);
        const numbered = ctx.presentation.row_numbers == .shown;
        if (numbered and tree.beginRect(elementId(instance, "table.row.id.cell", row, 0), .{ .axis = .horizontal, .cross_align = .center, .size = .{ .w = .{ .fixed = row_number_width }, .h = .fill }, .padding = cell_padding, .padding_y = 0, .clip_content = true })) {
            defer tree.endRect();
            tree.text(elementId(instance, "table.row.id", row, 0), std.fmt.bufPrint(id_buf, "{d}", .{number}) catch "?", .{ .font = style.font, .color = if (selected) style.text else style.dim_text });
        }
        for (shown_columns.positions, 0..) |column, c| {
            const field = order.columns.at(column);
            if (c == shown_columns.frozen and shown_columns.frozen > 0) frozenLine(tree, elementId(instance, "table.frozen_column", row, 0), .vertical, style);
            const active = cell_selected and state.edit_field.* == field;
            const editing = if (edit) |e| e.row == row and e.field == field else false;
            const invalid = editing and edit.?.invalid;
            const bg: ?ui.Color = if (invalid) style.invalid_bg else if (editing) style.edit_bg else if (active) style.active_bg else null;
            // Only the active cell is outlined; rows read by their stripes, columns by the header.
            const border: ?ui.Color = if (invalid) style.invalid_border else if (editing or active) style.active_border else null;
            const cell_width = drawnWidth(ctx, column_width, c, shown_columns.positions.len);
            if (tree.beginRect(elementId(instance, "table.cell", row, field), .{ .axis = .horizontal, .cross_align = .center, .size = .{ .w = cell_width, .h = .fill }, .padding = cell_padding, .padding_y = 0, .bg = bg, .border = border, .clip_content = true })) {
                defer tree.endRect();
                tree.onClick(targetOf(tree, ctx.inbox, Msg.cell_click, CellClick{ .instance = instance, .row = row, .field = field }), .left);
                try drawValueContent("table.cell", tree, instance, table, row, field, edit, scratch, style);
            }
        }
    }
    if (order.rowCount() == 0) {
        const hint = if (order.total_rows == 0) "No rows" else "No rows match the filter";
        if (tree.beginRect(elementId(instance, "table.empty", 0, 0), .{ .axis = .horizontal, .cross_align = .center, .size = .{ .w = .fill, .h = .{ .fixed = row_height } }, .padding = cell_padding })) {
            defer tree.endRect();
            tree.text(elementId(instance, "table.empty.text", 0, 0), hint, .{ .font = style.font, .color = style.dim_text });
        }
    }
}

/// A row of the view the table does not hold, at `position`, in stripe `index`: its frame in
/// its stripe, and no cells.
fn drawEmptyRow(tree: *ui.Tree, instance: Atom, position: u32, index: usize, style: Style) void {
    tree.rect(elementId(instance, "table.row.empty", position, 0), .{ .size = .{ .w = .fill, .h = .{ .fixed = row_height } }, .bg = rowFill(style, false, index) });
}

/// Above the grid: its filter, what narrows, orders or freezes it, each with a way back, and
/// how many rows it shows.
fn drawToolbar(ctx: RenderContext, tree: *ui.Tree, instance: Atom, table: *const Table, state: State, order: ViewOrder, scratch: memory_mod.Scratch, style: Style) void {
    if (!tree.beginRect(elementId(instance, "toolbar", 0, 0), .{ .axis = .horizontal, .cross_align = .center, .size = .{ .w = .fill, .h = .{ .fixed = toolbar_height } }, .padding = 4, .gap = 6, .bg = style.header_bg, .clip_content = true })) return;
    defer tree.endRect();
    filter_field.render(tree, elementId(instance, "toolbar.filter", 0, 0), state.filterField(), "Filter rows", .{ .w = .{ .fixed = 170 }, .h = .{ .fixed = 26 } }, .shown, targetOf(tree, ctx.inbox, Msg.table_filter_clear, instance), targetOf(tree, ctx.inbox, Msg.table_filter_focus, instance), style.filter);
    const allocator = scratch.allocator;
    const fields = table.getSchema().fields;
    const sort_field = state.sort_column.*;
    if (sort_field != 0 and sort_field - 1 < fields.len) {
        const direction = if (state.sort_descending.* != 0) "descending" else "ascending";
        const label = std.fmt.allocPrint(allocator, "{s}, {s}", .{ fields[sort_field - 1].name, direction }) catch "sorted";
        chip(tree, elementId(instance, "toolbar.sort", 0, 0), label, "Back to the table's order", targetOf(tree, ctx.inbox, Msg.table_clear_sort, instance), style);
    }
    // A data only field is no column, hidden or shown.
    const shown_fields = ctx.presentation.shownFields(table);
    const shown_mask: u64 = if (shown_fields >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(shown_fields)) - 1;
    const hidden_count = @popCount(state.hidden_columns.* & shown_mask);
    if (hidden_count != 0) {
        const label = std.fmt.allocPrint(allocator, "{d} hidden", .{hidden_count}) catch "hidden";
        chip(tree, elementId(instance, "toolbar.hidden", 0, 0), label, "Show all columns", targetOf(tree, ctx.inbox, Msg.table_show_columns, instance), style);
    }
    if (order.frozen_rows != 0 or order.frozen_columns != 0) {
        const label = std.fmt.allocPrint(allocator, "frozen {d} x {d}", .{ order.frozen_rows, order.frozen_columns }) catch "frozen";
        chip(tree, elementId(instance, "toolbar.frozen", 0, 0), label, "Unfreeze rows and columns", targetOf(tree, ctx.inbox, Msg.table_unfreeze, instance), style);
    }
    tree.rect(elementId(instance, "toolbar.space", 0, 0), .{ .size = .{ .w = .fill, .h = .fill } });
    const count = if (order.open_ended)
        std.fmt.allocPrint(allocator, "{d}+ rows", .{order.total_rows}) catch ""
    else if (order.rowCount() == order.total_rows)
        std.fmt.allocPrint(allocator, "{d} rows", .{order.total_rows}) catch ""
    else
        std.fmt.allocPrint(allocator, "{d} of {d} rows", .{ order.rowCount(), order.total_rows }) catch "";
    tree.text(elementId(instance, "toolbar.count", 0, 0), count, .{ .font = style.font, .color = style.dim_text });
}

/// A pill naming something that narrows or orders the grid; a click undoes it. Its padding is at
/// its ends alone, so its label keeps the chip's whole height.
fn chip(tree: *ui.Tree, id: ui.ElementId, label: []const u8, tooltip: []const u8, click: ui.Target, style: Style) void {
    if (!tree.beginRect(id, .{ .axis = .horizontal, .cross_align = .center, .size = .{ .w = .hug, .h = .{ .fixed = 22 } }, .padding = 6, .padding_y = 0, .gap = 4, .bg = style.active_bg, .bg_hover = style.button_hover, .corner_radius = 11, .clip_content = true })) return;
    defer tree.endRect();
    tree.onClick(click, .left);
    tree.trackHover(tooltip);
    const label_id = ui.partId(tree, id, "label");
    tree.text(label_id, label, .{ .font = style.font, .color = style.text });
    const cross_id = ui.partId(tree, id, "cross");
    marks.place(tree, cross_id, marks.Cross{ .color = style.dim_text }, 12);
}

fn drawHeader(ctx: RenderContext, tree: *ui.Tree, instance: Atom, table: *const Table, state: State, columns: Order, shown_columns: ShownLines, column_width: f32, style: Style) void {
    if (!tree.beginRect(elementId(instance, "table.header", 0, 0), .{ .axis = .horizontal, .size = .{ .w = .fill, .h = .{ .fixed = header_height } }, .bg = style.header_bg })) return;
    defer tree.endRect();
    const numbered = ctx.presentation.row_numbers == .shown;
    if (numbered and tree.beginRect(elementId(instance, "table.header.id.cell", 0, 0), .{ .axis = .horizontal, .cross_align = .center, .size = .{ .w = .{ .fixed = row_number_width }, .h = .fill }, .padding = cell_padding, .padding_y = 0, .clip_content = true })) {
        defer tree.endRect();
        tree.text(elementId(instance, "table.header.id", 0, 0), "row", .{ .font = style.font, .color = style.dim_text });
    }
    // An inline draw's selection is a whole row, of no column.
    const cell_selected = ctx.inline_rows == null and state.selected_present.* != 0;
    for (shown_columns.positions, 0..) |column, c| {
        const field = columns.at(column);
        if (c == shown_columns.frozen and shown_columns.frozen > 0) frozenLine(tree, elementId(instance, "table.header.frozen", 0, 0), .vertical, style);
        if (ctx.presentation.header == .names) {
            namedColumn(tree, instance, table, field, drawnWidth(ctx, column_width, c, shown_columns.positions.len), style);
            continue;
        }
        const active_column = cell_selected and state.edit_field.* == field;
        const sorted = state.sort_column.* == field + 1;
        if (!tree.beginRect(elementId(instance, "table.header.cell", 0, field), .{
            .axis = .horizontal,
            .cross_align = .center,
            .size = .{ .w = drawnWidth(ctx, column_width, c, shown_columns.positions.len), .h = .fill },
            .bg = if (active_column) style.active_bg else null,
            .clip_content = true,
        })) continue;
        defer tree.endRect();
        // The name sorts; the button beside it opens the column's menu.
        const name_id = elementId(instance, "table.header.name", 0, field);
        if (tree.beginRect(name_id, .{ .axis = .horizontal, .cross_align = .center, .size = .{ .w = .fill, .h = .fill }, .padding = cell_padding, .padding_y = 0, .gap = 2, .bg_hover = style.header_hover, .clip_content = true })) {
            defer tree.endRect();
            tree.onClick(targetOf(tree, ctx.inbox, Msg.table_header_sort, ColumnRef{ .instance = instance, .field = field }), .left);
            tree.trackHover(if (sorted and state.sort_descending.* != 0) "Back to the table's order" else if (sorted) "Sort descending" else "Sort by this column");
            tree.text(elementId(instance, "table.header.text", 0, field), table.getSchema().fields[field].name, .{ .font = style.font, .color = if (active_column or sorted) style.text else style.header_text, .size_hint = .{ .w = .fill } });
            if (sorted) marks.place(tree, elementId(instance, "table.header.sorted", 0, field), marks.Chevron{ .direction = if (state.sort_descending.* != 0) .down else .up, .color = style.header_text }, 12);
        }
        const menu_id = elementId(instance, "table.header.menu", 0, field);
        if (tree.beginRect(menu_id, .{ .axis = .horizontal, .size = .{ .w = .{ .fixed = 20 }, .h = .fill }, .bg_hover = style.button_hover })) {
            defer tree.endRect();
            tree.onClick(targetOf(tree, ctx.inbox, Msg.table_column_menu, ColumnRef{ .instance = instance, .field = field }), .left);
            tree.trackHover("Sort, hide or freeze");
            marks.place(tree, elementId(instance, "table.header.menu.dots", 0, field), marks.Dots{ .color = style.dim_text }, 20);
        }
    }
}

/// The width of the column drawn `drawn` of `count`: its fitted width, the fill column what the
/// others leave, when `ctx.fitted` gives them; else `columnWidth`'s.
fn drawnWidth(ctx: RenderContext, share: f32, drawn: usize, count: usize) ui.Dim {
    const fitted = ctx.fitted orelse return columnWidth(ctx.presentation, share, drawn, count);
    if (drawn == fitted.fill) return .fill;
    if (drawn >= fitted.widths.len) return .{ .fixed = share };
    return .{ .fixed = fitted.widths[drawn] };
}

/// The width of the column drawn `drawn` of `count`: its share, or, the last with
/// `LastColumn.fills`, what the others leave.
fn columnWidth(presentation: Presentation, share: f32, drawn: usize, count: usize) ui.Dim {
    const last = drawn + 1 == count;
    if (last and presentation.last_column == .fills) return .fill;
    return .{ .fixed = share };
}

/// A column's name in a header of names only (`Header.names`): a cell as wide as the column's,
/// holding its name, which does nothing.
fn namedColumn(tree: *ui.Tree, instance: Atom, table: *const Table, field: u32, column_width: ui.Dim, style: Style) void {
    const cell_id = elementId(instance, "table.header.cell", 0, field);
    if (!tree.beginRect(cell_id, .{ .axis = .horizontal, .cross_align = .center, .size = .{ .w = column_width, .h = .fill }, .padding = cell_padding, .padding_y = 0, .clip_content = true })) return;
    defer tree.endRect();
    const name = table.getSchema().fields[field].name;
    tree.text(elementId(instance, "table.header.text", 0, field), name, .{ .font = style.font, .color = style.header_text, .size_hint = .{ .w = .fill } });
}

fn drawRow(ctx: RenderContext, tree: *ui.Tree, instance: Atom, table: *const Table, handle: Table.RowHandle, state: State, edit: ?EditRef, viewport_w: f32, viewport_h: f32, scratch: memory_mod.Scratch, style: Style) !void {
    const rows = visibleRows(viewport_h, .fields, ctx.presentation);
    const field_start = clampScroll(state.scroll.*, @intCast(table.getSchema().fields.len), rows);
    if (!tree.beginRect(elementId(instance, "root", 0, 0), .{
        .axis = .vertical,
        .size = .{ .w = .{ .fixed = viewport_w }, .h = .{ .fixed = viewport_h } },
        .bg = style.row_bg_b,
        .border = style.grid_border,
        .corner_radius = form_corner_radius,
        .clip_content = true,
        .on_scroll = targetOf(tree, ctx.inbox, Msg.wheel, instance),
    })) return;
    defer tree.endRect();
    var i: u32 = 0;
    while (i < rows and field_start + i < table.getSchema().fields.len) : (i += 1) {
        const field = field_start + i;
        const editing = if (edit) |e| e.row == handle.row and e.field == field else false;
        const active = state.selected_present.* != 0 and state.edit_field.* == field;
        const invalid = editing and edit.?.invalid;
        if (tree.beginRect(elementId(instance, "row.field", handle.row, field), .{ .axis = .horizontal, .size = .{ .w = .fill, .h = .{ .fixed = row_height } }, .bg = if (i % 2 == 0) style.row_bg_a else style.row_bg_b })) {
            defer tree.endRect();
            if (tree.beginRect(elementId(instance, "row.field.name.cell", handle.row, field), .{ .axis = .horizontal, .cross_align = .center, .size = .{ .w = .{ .fixed = field_name_width }, .h = .fill }, .padding = cell_padding, .padding_y = 0, .clip_content = true })) {
                defer tree.endRect();
                tree.text(elementId(instance, "row.field.name", handle.row, field), table.getSchema().fields[field].name, .{ .font = style.font, .color = if (active) style.header_text else style.dim_text });
            }
            const bg: ?ui.Color = if (invalid) style.invalid_bg else if (editing) style.edit_bg else if (active) style.active_bg else null;
            const border: ?ui.Color = if (invalid) style.invalid_border else if (editing or active) style.active_border else null;
            const desc = &table.getSchema().fields[field];
            const vector_components: ?[]const f32 = if (editing) null else shownVectorComponents(table, handle.row, desc);
            const value_padding: f32 = if (vector_components != null) vector_cell_padding else cell_padding;
            const value_padding_y: ?f32 = if (vector_components != null) null else 0;
            if (tree.beginRect(elementId(instance, "row.field.value.cell", handle.row, field), .{ .axis = .horizontal, .cross_align = .center, .size = .{ .w = .fill, .h = .fill }, .padding = value_padding, .padding_y = value_padding_y, .bg = bg, .border = border, .clip_content = true })) {
                defer tree.endRect();
                tree.onClick(targetOf(tree, ctx.inbox, Msg.cell_click, CellClick{ .instance = instance, .row = handle.row, .field = field }), .left);
                if (vector_components) |components| {
                    try drawVectorComponents("row.field.value", tree, instance, handle.row, field, components, scratch, style.vector);
                } else {
                    try drawValueContent("row.field.value", tree, instance, table, handle.row, field, edit, scratch, style);
                }
            }
        }
    }
}

/// The grid settled as it is drawn `viewport_w` by `viewport_h`, the columns sharing what the
/// caller's `presentation` gives them: what `normalize` does, the scrolls kept within the lines
/// past the frozen ones and a selection that moved brought into view. Null for a target that is
/// gone. It writes `state`: a kernel's, or the copy a draw settles (`Scalars`).
fn settleOrder(state: State, table: *const Table, target: Target, order: ViewOrder, viewport_w: f32, viewport_h: f32, presentation: Presentation) ?ResolvedTarget {
    const prepared = prepare(state, table, target, order) orelse return null;
    const rows = visibleRows(viewport_h, bodyOf(prepared.target), presentation);
    switch (prepared.target) {
        .table => {
            const cols = visibleColumns(presentation.columnsWidth(viewport_w));
            clampGridScroll(state, order, rows, cols);
            if (prepared.changed and state.selected_present.* != 0) reveal(state, table, prepared.target, order, rows, cols);
        },
        .row => {
            state.scroll.* = clampScroll(state.scroll.*, @intCast(table.getSchema().fields.len), rows);
            state.horizontal_scroll.* = 0;
            if (prepared.changed and state.selected_present.* != 0) reveal(state, table, prepared.target, order, rows, 1);
        },
    }
    return prepared.target;
}

/// Settles the grid, as `render` will draw it `viewport_w` by `viewport_h`, in a kernel of its
/// caller, the only writer of its state: the selection normalised, the scrolls kept within the
/// lines shown and a selection that moved brought into view. `render` settles a copy and writes
/// nothing. `invalidated` for a target that is gone.
pub fn settle(state: State, table: *const Table, target: Target, viewport_w: f32, viewport_h: f32, ctx: OrderContext) Status {
    const order = viewOrder(state, table, ctx);
    _ = settleOrder(state, table, target, order, viewport_w, viewport_h, ctx.presentation) orelse return .invalidated;
    return .ready;
}

/// A copy of a grid's state's numbers, which a draw settles in place of the caller's: the texts
/// (the filter's, the edit's) stay the caller's, only read.
const Scalars = struct {
    scroll: u32,
    horizontal_scroll: u32,
    committed: u8,
    selected_present: u8,
    selected_row: u32,
    selected_row_generation: u32,
    target_epoch: u32,
    edit_present: u8,
    edit_row: u32,
    edit_field: u32,
    edit_invalid: u8,
    edit_commit: u8,
    edit_serial: u32,
    sort_column: u32,
    sort_descending: u8,
    hidden_columns: u64,
    frozen_rows: u32,
    frozen_columns: u32,
    filter_focused: u8,

    fn of(state: State) Scalars {
        return .{
            .scroll = state.scroll.*,
            .horizontal_scroll = state.horizontal_scroll.*,
            .committed = state.committed.*,
            .selected_present = state.selected_present.*,
            .selected_row = state.selected_row.*,
            .selected_row_generation = state.selected_row_generation.*,
            .target_epoch = state.target_epoch.*,
            .edit_present = state.edit_present.*,
            .edit_row = state.edit_row.*,
            .edit_field = state.edit_field.*,
            .edit_invalid = state.edit_invalid.*,
            .edit_commit = state.edit_commit.*,
            .edit_serial = state.edit_serial.*,
            .sort_column = state.sort_column.*,
            .sort_descending = state.sort_descending.*,
            .hidden_columns = state.hidden_columns.*,
            .frozen_rows = state.frozen_rows.*,
            .frozen_columns = state.frozen_columns.*,
            .filter_focused = state.filter_focused.*,
        };
    }

    /// `state` with its numbers this copy's.
    fn over(copy: *Scalars, state: State) State {
        var copied = state;
        copied.scroll = &copy.scroll;
        copied.horizontal_scroll = &copy.horizontal_scroll;
        copied.committed = &copy.committed;
        copied.selected_present = &copy.selected_present;
        copied.selected_row = &copy.selected_row;
        copied.selected_row_generation = &copy.selected_row_generation;
        copied.target_epoch = &copy.target_epoch;
        copied.edit_present = &copy.edit_present;
        copied.edit_row = &copy.edit_row;
        copied.edit_field = &copy.edit_field;
        copied.edit_invalid = &copy.edit_invalid;
        copied.edit_commit = &copy.edit_commit;
        copied.edit_serial = &copy.edit_serial;
        copied.sort_column = &copy.sort_column;
        copied.sort_descending = &copy.sort_descending;
        copied.hidden_columns = &copy.hidden_columns;
        copied.frozen_rows = &copy.frozen_rows;
        copied.frozen_columns = &copy.frozen_columns;
        copied.filter_focused = &copy.filter_focused;
        return copied;
    }
};

/// How a grid is drawn besides its state and table: where its clicks go, how it presents its
/// table, its look, and what draws the cell being edited.
pub const RenderContext = struct {
    /// The inbox the grid's clicks and wheel go to, under `Msg`'s tags.
    inbox: Atom,
    /// How the caller presents the grid: the columns drawn and the row numbers.
    presentation: Presentation = .{},
    /// The grid's colours, fonts and metrics.
    style: Style = default_style,
    /// What draws the cell being edited while the caller's text editor holds the edit; null
    /// draws the edited text as it stands.
    editor: ?CellDrawable = null,
    /// Which rows of what the grid shows the table holds: a position it does not hold is drawn
    /// as an empty row.
    rows: Rows = .all,
    /// The fields drawn as columns, in order, as `OrderContext.columns`; null for the fields not
    /// hidden, in the table's order. The caller's, for the call. `update` and `settle` do not see
    /// it: they move the cursor and scroll over the table's own columns, so a caller's list is
    /// for a grid that takes no cursor of its own, drawn inline and read only with a header of
    /// names (`Header.names`) or none.
    columns: ?[]const u32 = null,
    /// The table's rows drawn, in order, as `OrderContext.chosen_rows`: an inline draw's
    /// positions (`Inline.first`) are then places in this list, so a caller draws a subset of a
    /// table's rows, as a page's group of rows is, in pieces as it draws a whole table. Null for
    /// the table's rows as the filter and the sort leave them. The caller's, for the call; like
    /// `columns`, for a grid drawn inline that takes no cursor of its own (`update` and `settle`
    /// do not see it).
    chosen_rows: ?[]const u32 = null,
    /// For an inline draw: the columns drawn and each one's width, fit to what they hold
    /// (`fitColumns`), in place of `columns`, the shares of `cellWidth` and
    /// `Presentation.last_column`; every one of them is drawn, from the first, its fill column
    /// taking what the others leave, and the state's horizontal scroll and frozen columns are
    /// not read. The caller's, for the call: one table drawn as several pieces gives each the
    /// same, so the columns line up. Null: the columns and shares as without it.
    fitted: ?Fitted = null,
    /// For a caller that scrolls the grid itself, as a page of blocks does: the positions of the
    /// view order to draw, every one of them, under the toolbar and header `presentation` shows,
    /// `inlineHeight` tall, with no scroll of the grid's own: no rows kept in place, no wheel
    /// taken (the wheel over it is its encloser's), and the grid's vertical scroll left unread.
    /// Its selection is the caller's too (`Inline.selected`). Rows are striped by their
    /// position in the view order, not by where they fall in the draw, so a caller that draws
    /// one table's rows as several grids, a piece each, or scrolls them, keeps each row's stripe.
    /// Null for a grid that scrolls itself in its `viewport_h`. A form (`Target.row`, or a
    /// required singleton) is drawn as ever.
    ///
    /// The caller asks only for the rows in its view, and makes its tree with room for
    /// `elementCount(count, columns)` more elements, `columns` being `fitted.columns.len` when
    /// `fitted` is given, as every fitted column is drawn, else `visibleColumns(viewport_w)`. At
    /// most `max_visible_rows` are drawn, whatever it asks, so a count past that cannot fill the
    /// tree or the hit regions: the grid's root is then `inlineHeight` of the rows drawn, and the
    /// rest is the encloser's background.
    inline_rows: ?Inline = null,
};

/// The positions of the view order an inline draw shows (`RenderContext.inline_rows`): `count`
/// from `first`, those past the end of the view left out. A caller that works out which rows of
/// its page are in view as it lays the page out knows them without waiting for a commit.
pub const Inline = struct {
    /// The first position drawn.
    first: u32,
    /// How many positions are drawn.
    count: u32,
    /// The table's row drawn selected, the whole row in `Style.selected_bg` and no cell of it
    /// marked; null for none. An inline draw's selection is its caller's, as its scroll is: the
    /// state's selected row and cell are not drawn, so a page with one cursor across its blocks
    /// shows it in the grid it is in and in no other.
    selected: ?u32 = null,
};

/// A click or the wheel over what `tree` draws, to `inbox` under `message`'s tag with `data`.
fn targetOf(tree: *ui.Tree, inbox: Atom, message: Msg, data: anytype) ui.Target {
    const tag = Atom.from(message);
    return tree.target(inbox, tag, data);
}

/// Draws the grid into `tree`, `viewport_w` by `viewport_h`, as `state` settles there: a copy of it
/// is settled, so the draw writes nothing, and shows what the caller's kernel's `settle` would
/// leave. Only the rows and columns in view are drawn: of the rows, the whole ones of `window` for
/// the body `bodySize` gives, of the columns those that fit past the horizontal scroll (every one
/// `RenderContext.fitted` gives, when it does), so what it records is bounded by `elementCount` of
/// what fits, however long the table. A row of the view the table no longer holds is drawn as an
/// empty row, and nothing of it is read. Reads the table's cells as any reader does
/// (`Table.cellBytes`, `Table.cellText`), never raw storage, and names atom and reference cells
/// through `tree.atoms`. The texts it draws are copied into `scratch`, which must last through the
/// tree's last commit. `invalidated`, drawing nothing, for a target that is gone.
pub fn render(state: State, instance: Atom, target: Target, tree: *ui.Tree, table: *const Table, viewport_w: f32, viewport_h: f32, scratch: memory_mod.Scratch, ctx: RenderContext) Status {
    var scalars = Scalars.of(state);
    const drawn = scalars.over(state);
    const drawn_columns = if (ctx.fitted) |fitted| fitted.columns else ctx.columns;
    const order_context: OrderContext = .{ .atoms = tree.atoms, .allocator = scratch.allocator, .presentation = ctx.presentation, .rows = ctx.rows, .columns = drawn_columns, .chosen_rows = ctx.chosen_rows };
    const order = viewOrder(drawn, table, order_context);
    const resolved = settleOrder(drawn, table, target, order, viewport_w, viewport_h, ctx.presentation) orelse return .invalidated;
    const edit: ?EditRef = if (isEditing(drawn)) .{
        .row = drawn.edit_row.*,
        .field = drawn.edit_field.*,
        .invalid = drawn.edit_invalid.* != 0,
        .text = editText(drawn),
        .drawable = ctx.editor,
    } else null;
    const style = ctx.style;
    switch (resolved) {
        .table => drawTable(ctx, tree, instance, table, drawn, order, edit, viewport_w, viewport_h, scratch, style) catch |e| Log.debug("table_view_render_failed", .{ .target = "table", .instance = instance, .@"error" = @errorName(e) }),
        .row => |handle| drawRow(ctx, tree, instance, table, handle, drawn, edit, viewport_w, viewport_h, scratch, style) catch |e| Log.debug("table_view_render_failed", .{ .target = "row", .instance = instance, .@"error" = @errorName(e) }),
    }
    return .ready;
}

// ---- tests ------------------------------------------------------------------------------------

/// A grid's state for a test, its values here, nothing selected, sorted, hidden, frozen or
/// filtered: a `State` over them, its texts the table `owner`'s, while they stay where they are.
const TestState = struct {
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

    fn state(kept: *TestState, owner: *Table) State {
        return .{
            .scroll = &kept.scroll,
            .horizontal_scroll = &kept.horizontal_scroll,
            .committed = &kept.committed,
            .selected_present = &kept.selected_present,
            .selected_row = &kept.selected_row,
            .selected_row_generation = &kept.selected_row_generation,
            .target_epoch = &kept.target_epoch,
            .edit_present = &kept.edit_present,
            .edit_row = &kept.edit_row,
            .edit_field = &kept.edit_field,
            .owner = owner,
            .edit_text = &kept.edit_text,
            .edit_invalid = &kept.edit_invalid,
            .edit_commit = &kept.edit_commit,
            .edit_serial = &kept.edit_serial,
            .sort_column = &kept.sort_column,
            .sort_descending = &kept.sort_descending,
            .hidden_columns = &kept.hidden_columns,
            .frozen_rows = &kept.frozen_rows,
            .frozen_columns = &kept.frozen_columns,
            .filter = &kept.filter,
            .filter_focused = &kept.filter_focused,
        };
    }
};

/// A table of two text cells a row and one number, and a grid's state over it, for the tests of
/// a grid read only.
const TestGrid = struct {
    mem: memory_mod.Memory = undefined,
    atoms: Atom.Registry = undefined,
    tables: Table.Registry = undefined,
    table: *Table = undefined,
    kept: TestState = .{},
    state: State = undefined,

    fn init(grid: *TestGrid) !void {
        grid.mem.init(std.testing.allocator);
        try grid.atoms.init(&grid.mem);
        try grid.tables.init(&grid.mem, 8);
        const scratch = try grid.mem.tableScratchAllocator();
        var schema: Table.Schema = undefined;
        try schema.init(scratch.allocator, &grid.atoms, 3);
        defer schema.deinit();
        schema.addField("subject", Table.String, .text_field);
        schema.addField("count", u32, .int);
        schema.addField("key", Table.String, .text_field);
        grid.table = (try grid.tables.ensure(&schema, 4, grid.atoms.intern("read_grid_test"), .durable)).table;
        const subjects = [_][]const u8{ "first", "second" };
        for (subjects) |subject| {
            const handle = try grid.table.tryInsert(.{ .subject = Table.String{}, .count = @as(u32, 7), .key = Table.String{} });
            try grid.table.setCellText(handle, 0, subject);
            try grid.table.setCellText(handle, 2, "data");
        }
        grid.state = grid.kept.state(grid.table);
    }

    fn deinit(grid: *TestGrid) void {
        grid.tables.deinit();
        grid.atoms.deinit();
        grid.mem.deinit();
    }

    fn context(grid: *TestGrid, access: Access) !UpdateContext {
        const frame = try grid.mem.frameScratchAllocator();
        return .{ .viewport_w = 800, .viewport_h = 400, .atoms = &grid.atoms, .allocator = frame.allocator, .presentation = .{ .access = access, .data_fields = 1 } };
    }

    fn orderContext(grid: *TestGrid) !OrderContext {
        const frame = try grid.mem.frameScratchAllocator();
        return .{ .atoms = &grid.atoms, .allocator = frame.allocator, .presentation = .{ .access = .read, .data_fields = 1 } };
    }

    fn click(grid: *TestGrid, row: u32, field: u32, ctx: UpdateContext) !Outcome {
        const clicked: CellClick = .{ .instance = grid.table.name, .row = row, .field = field };
        const received: sequencer.Message = .{ .tag = Atom.from(Msg.cell_click), .user_data = std.mem.asBytes(&clicked) };
        return update(grid.state, grid.table.name, .table, .cell_click, received, grid.table, ctx);
    }
};

/// The lines of `order`, position by position, into `buffer`.
fn linesOf(order: Order, buffer: []u32) []const u32 {
    for (buffer[0..order.len], 0..) |*line, position| line.* = order.at(@intCast(position));
    return buffer[0..order.len];
}

/// Which of `Outcome`'s answers one is, for the tests to compare.
const OutcomeTag = std.meta.Tag(Outcome);

fn tagOf(outcome: Outcome) OutcomeTag {
    return outcome;
}

test "a grid read only starts no edit, and tells its row chosen by RET or a click on its cell" {
    var grid: TestGrid = .{};
    try grid.init();
    defer grid.deinit();
    const state = grid.state;
    const table = grid.table;
    const instance = table.name;
    var ctx = try grid.context(.read);
    try std.testing.expectEqual(Status.ready, normalize(state, table, .table, try grid.orderContext()));

    // Typing, the edit key, clearing and flipping start nothing and change nothing.
    const typed: input.TextInputMsg = .{ .codepoint = 'x' };
    const char: sequencer.Message = .{ .tag = Atom.from(Msg.char), .payload = std.mem.asBytes(&typed), .user_data = std.mem.asBytes(&instance) };
    _ = try update(state, instance, .table, .char, char, table, ctx);
    const left_alone = [_]Msg{ .begin_edit, .delete, .toggle, .paste };
    for (left_alone) |message| try std.testing.expectEqual(OutcomeTag.handled, tagOf(updateMessage(state, instance, .table, message, table, ctx)));
    try std.testing.expect(!isEditing(state));
    try std.testing.expectEqualStrings("first", table.cellText(0, &table.getSchema().fields[0]));
    try std.testing.expect(table.rowHas(0, table.getSchema().fields[1].bit));

    // RET chooses the selected row. A click on another cell selects it, its row's other cell
    // too; a click on the selected cell, a double click, chooses its row.
    try std.testing.expectEqual(OutcomeTag.chosen, tagOf(updateMessage(state, instance, .table, .table_choose, table, ctx)));
    try std.testing.expectEqual(OutcomeTag.handled, tagOf(try grid.click(1, 0, ctx)));
    try std.testing.expectEqual(@as(u32, 1), state.selected_row.*);
    try std.testing.expectEqual(OutcomeTag.handled, tagOf(try grid.click(1, 1, ctx)));
    try std.testing.expectEqual(@as(u32, 1), state.edit_field.*);
    try std.testing.expectEqual(OutcomeTag.chosen, tagOf(try grid.click(1, 1, ctx)));
    try std.testing.expect(!isEditing(state));

    // A grid that edits edits as before, and chooses nothing.
    ctx.presentation.access = .edit;
    try std.testing.expectEqual(OutcomeTag.ignored, tagOf(updateMessage(state, instance, .table, .table_choose, table, ctx)));
    _ = updateMessage(state, instance, .table, .begin_edit, table, ctx);
    try std.testing.expect(isEditing(state));
}

test "valueText reads a text cell as written and a number as the grid draws it" {
    var grid: TestGrid = .{};
    try grid.init();
    defer grid.deinit();
    var buffer: ValueTextBuffer = undefined;
    try std.testing.expectEqualStrings("second", valueText(grid.table, 1, 0, &buffer, &grid.atoms));
    try std.testing.expectEqualStrings("7", valueText(grid.table, 1, 1, &buffer, &grid.atoms));
    try std.testing.expectEqualStrings("", valueText(grid.table, 3, 1, &buffer, &grid.atoms));
}

test "a grid's data only fields are no column, a key sorts by the selected column, and C-g leaves the filter" {
    var grid: TestGrid = .{};
    try grid.init();
    defer grid.deinit();
    const state = grid.state;
    const table = grid.table;
    const instance = table.name;
    const ctx = try grid.context(.read);
    const order = viewOrder(state, table, try grid.orderContext());
    var lines: [4]u32 = undefined;
    try std.testing.expectEqualSlices(u32, &.{ 0, 1 }, linesOf(order.columns, &lines));
    _ = normalize(state, table, .table, try grid.orderContext());

    // The sort key carries no column: the selected cell's is sorted by.
    try std.testing.expectEqual(OutcomeTag.handled, tagOf(updateMessage(state, instance, .table, .table_header_sort, table, ctx)));
    try std.testing.expectEqual(@as(u32, 1), state.sort_column.*);

    // `C-g` in the filter leaves it, its text kept.
    _ = updateMessage(state, instance, .table, .table_filter_focus, table, ctx);
    const typed: input.TextInputMsg = .{ .codepoint = 's' };
    const text: sequencer.Message = .{ .tag = Atom.from(Msg.table_filter_text), .payload = std.mem.asBytes(&typed), .user_data = std.mem.asBytes(&instance) };
    _ = try update(state, instance, .table, .table_filter_text, text, table, ctx);
    const pressed: input.KeyInputMsg = .{ .key = .g, .modifiers = .{ .control = true } };
    const key: sequencer.Message = .{ .tag = Atom.from(Msg.table_filter_key), .payload = std.mem.asBytes(&pressed), .user_data = std.mem.asBytes(&instance) };
    _ = try update(state, instance, .table, .table_filter_key, key, table, ctx);
    try std.testing.expect(!isFiltering(state));
    try std.testing.expectEqualStrings("s", state.filterField().query());
}

test "drawing a grid writes nothing to its state" {
    var grid: TestGrid = .{};
    try grid.init();
    defer grid.deinit();
    const state = grid.state;
    // Unsettled: no row selected, the scrolls past the lines there are.
    state.scroll.* = 40;
    state.horizontal_scroll.* = 9;
    const before = Scalars.of(state);
    const frame = try grid.mem.frameScratchAllocator();
    var tree = try ui.Tree.init(frame, &grid.atoms, 4096);
    const drawing: RenderContext = .{ .inbox = Atom.from("grid_test"), .presentation = .{ .access = .read, .data_fields = 1, .row_numbers = .hidden } };
    try std.testing.expectEqual(Status.ready, render(state, grid.table.name, .table, &tree, grid.table, 800, 400, frame, drawing));
    try std.testing.expectEqual(before, Scalars.of(state));
}

/// A message of the grid's carrying `payload`, the instance its user data.
fn messageOf(message: Msg, instance: *const Atom, payload: []const u8) sequencer.Message {
    return .{ .tag = Atom.from(message), .payload = payload, .user_data = std.mem.asBytes(instance) };
}

test "a column's menu asked for answers column_menu and changes nothing" {
    var grid: TestGrid = .{};
    try grid.init();
    defer grid.deinit();
    const state = grid.state;
    const table = grid.table;
    const ctx = try grid.context(.edit);
    _ = normalize(state, table, .table, try grid.orderContext());
    const before = Scalars.of(state);
    const column: ColumnRef = .{ .instance = table.name, .field = 1 };
    const received: sequencer.Message = .{ .tag = Atom.from(Msg.table_column_menu), .user_data = std.mem.asBytes(&column) };
    const outcome = try update(state, table.name, .table, .table_column_menu, received, table, ctx);
    try std.testing.expectEqual(OutcomeTag.column_menu, tagOf(outcome));
    try std.testing.expectEqual(@as(u32, 1), outcome.column_menu.field);
    try std.testing.expectEqual(before, Scalars.of(state));
    // The data only field has no column, and no menu.
    const hidden: ColumnRef = .{ .instance = table.name, .field = 2 };
    const asked_hidden: sequencer.Message = .{ .tag = Atom.from(Msg.table_column_menu), .user_data = std.mem.asBytes(&hidden) };
    try std.testing.expectEqual(OutcomeTag.handled, tagOf(try update(state, table.name, .table, .table_column_menu, asked_hidden, table, ctx)));
    var choices: [max_column_choices]ColumnChoice = undefined;
    const offered = columnMenuChoices(state, 1, &choices);
    try std.testing.expectEqualStrings("Ascending", offered[0].label);
    try std.testing.expectEqual(ColumnAction.hide, offered[2].action);
}

test "the column menu's hide hides that column" {
    var grid: TestGrid = .{};
    try grid.init();
    defer grid.deinit();
    const state = grid.state;
    const table = grid.table;
    const order_context = try grid.orderContext();
    applyColumnAction(state, table, 0, .hide, order_context);
    try std.testing.expectEqual(@as(u64, 1), state.hidden_columns.*);
    const order = viewOrder(state, table, try grid.orderContext());
    var lines: [4]u32 = undefined;
    try std.testing.expectEqualSlices(u32, &.{1}, linesOf(order.columns, &lines));
    // The last column shown stays.
    applyColumnAction(state, table, 1, .hide, try grid.orderContext());
    try std.testing.expectEqual(@as(u64, 1), state.hidden_columns.*);
}

test "a toolbar's chip and a cell leave no padding above and below, so a clipped line of text keeps its descenders" {
    var grid: NumberGrid = .{};
    try grid.init(10);
    defer grid.deinit();
    const state = grid.state;
    const table = grid.table;
    const instance = table.name;
    state.sort_column.* = 1;
    const frame = try grid.frame();
    var tree = try ui.Tree.init(frame, &grid.atoms, 4096);
    const drawing: RenderContext = .{ .inbox = Atom.from("grid_test") };
    _ = render(state, instance, .table, &tree, table, 400, 300, frame, drawing);
    const sort_chip = rectParams(&tree, elementId(instance, "toolbar.sort", 0, 0));
    try std.testing.expect(sort_chip.clip_content);
    try std.testing.expectEqual(@as(?f32, 0), sort_chip.padding_y);
    const cell = rectParams(&tree, elementId(instance, "table.cell", 0, 0));
    try std.testing.expect(cell.clip_content);
    try std.testing.expectEqual(@as(?f32, 0), cell.padding_y);
    const header = rectParams(&tree, elementId(instance, "table.header.name", 0, 0));
    try std.testing.expectEqual(@as(?f32, 0), header.padding_y);
}

test "copy answers the selected cell's text" {
    var grid: TestGrid = .{};
    try grid.init();
    defer grid.deinit();
    const state = grid.state;
    const table = grid.table;
    const ctx = try grid.context(.read);
    _ = normalize(state, table, .table, try grid.orderContext());
    const outcome = updateMessage(state, table.name, .table, .copy, table, ctx);
    try std.testing.expectEqual(OutcomeTag.copy, tagOf(outcome));
    try std.testing.expectEqualStrings("first", outcome.copy.text);
}

test "typing in a cell its text editor holds answers edit.insert with the text, and read only nothing" {
    var grid: TestGrid = .{};
    try grid.init();
    defer grid.deinit();
    const state = grid.state;
    const table = grid.table;
    const instance = table.name;
    const typed: input.TextInputMsg = .{ .codepoint = 'q' };
    const char = messageOf(.char, &instance, std.mem.asBytes(&typed));

    // Read only, typing starts no edit and asks nothing.
    const read_ctx = try grid.context(.read);
    _ = normalize(state, table, .table, try grid.orderContext());
    try std.testing.expectEqual(OutcomeTag.handled, tagOf(try update(state, instance, .table, .char, char, table, read_ctx)));
    try std.testing.expect(!isEditing(state));

    // Editable, with the caller's text editor holding the cell's edit, typing goes to it.
    var ctx = try grid.context(.edit);
    _ = updateMessage(state, instance, .table, .begin_edit, table, ctx);
    try std.testing.expect(isEditing(state));
    ctx.editor_loaded = true;
    const outcome = try update(state, instance, .table, .char, char, table, ctx);
    try std.testing.expectEqual(OutcomeTag.edit, tagOf(outcome));
    try std.testing.expectEqual(EditKind.insert, outcome.edit.kind);
    try std.testing.expectEqualStrings("q", outcome.edit.text);
    // The edited text waits for the text editor's report.
    try std.testing.expectEqualStrings("first", editText(state));
}

test "a grid's element ids are its instance's atom, told apart by a hash of role, row and field" {
    const instance = Atom.from("grid_test_table");
    const id = elementId(instance, "table.cell", 3, 2);
    var hash = std.hash.Wyhash.init(@intFromEnum(instance));
    const role_id: u64 = Atom.from("table.cell").value();
    const cell: u64 = (@as(u64, 3) << 32) | 2;
    hash.update(std.mem.asBytes(&role_id));
    hash.update(std.mem.asBytes(&cell));
    try std.testing.expectEqual(instance, id.atom);
    try std.testing.expectEqual(hash.final(), id.extra);
}

/// A table of rows of one number, each its row's, and a grid's state over it, for the tests of
/// a grid over a large table or a slice of a larger set.
const NumberGrid = struct {
    /// The rows of the tests over a large table.
    const million: u32 = 1_000_000;

    mem: memory_mod.Memory = undefined,
    atoms: Atom.Registry = undefined,
    tables: Table.Registry = undefined,
    table: *Table = undefined,
    kept: TestState = .{},
    state: State = undefined,

    fn init(grid: *NumberGrid, row_count: u32) !void {
        grid.mem.init(std.testing.allocator);
        try grid.atoms.init(&grid.mem);
        try grid.tables.init(&grid.mem, 8);
        const scratch = try grid.mem.tableScratchAllocator();
        var schema: Table.Schema = undefined;
        try schema.init(scratch.allocator, &grid.atoms, 1);
        defer schema.deinit();
        schema.addField("number", u32, .int);
        grid.table = (try grid.tables.ensure(&schema, row_count, grid.atoms.intern("number_grid_test"), .durable)).table;
        for (0..row_count) |row| _ = try grid.table.tryInsert(.{ .number = @as(u32, @intCast(row)) });
        grid.state = grid.kept.state(grid.table);
    }

    fn deinit(grid: *NumberGrid) void {
        grid.tables.deinit();
        grid.atoms.deinit();
        grid.mem.deinit();
    }

    fn frame(grid: *NumberGrid) !memory_mod.Scratch {
        return grid.mem.frameScratchAllocator();
    }
};

test "the table's own order, unfiltered and unsorted, allocates nothing over a million rows" {
    var grid: NumberGrid = .{};
    try grid.init(NumberGrid.million);
    defer grid.deinit();
    const order = viewOrder(grid.state, grid.table, .{ .atoms = &grid.atoms, .allocator = std.testing.failing_allocator });
    try std.testing.expectEqual(NumberGrid.million, order.rows.len);
    try std.testing.expectEqual(NumberGrid.million - 1, order.rows.at(NumberGrid.million - 1));
    try std.testing.expectEqual(@as(u32, 1), order.columns.len);
}

/// Whether `tree` holds a rect, open or a leaf, of `id`.
fn recordsRect(tree: *const ui.Tree, id: ui.ElementId) bool {
    for (tree.elements[0..tree.count]) |element| {
        const params = switch (element) {
            .open_rect, .rect => |params| params,
            else => continue,
        };
        if (std.meta.eql(params.id, id)) return true;
    }
    return false;
}

test "the window over a million rows at scroll 500,000 is the 21 rows in view, and render draws no more" {
    var grid: NumberGrid = .{};
    try grid.init(NumberGrid.million);
    defer grid.deinit();
    const state = grid.state;
    const table = grid.table;
    const instance = table.name;
    const frame = try grid.mem.frameScratchAllocator();
    const order_context: OrderContext = .{ .atoms = &grid.atoms, .allocator = frame.allocator };
    // A body of 20 whole rows and half of one more.
    const viewport_w: f32 = 400;
    const viewport_h: f32 = toolbar_height + header_height + 20.5 * row_height;
    _ = settle(state, table, .table, viewport_w, viewport_h, order_context);
    state.scroll.* = 500_000;
    _ = settle(state, table, .table, viewport_w, viewport_h, order_context);

    const body = bodySize(viewport_w, viewport_h, .{});
    const in_view = window(state, body, table.count());
    try std.testing.expectEqual(Window{ .first = 500_000, .count = 21 }, in_view);
    // At the end the window stops at the last row.
    state.scroll.* = NumberGrid.million;
    try std.testing.expectEqual(Window{ .first = NumberGrid.million - 20, .count = 20 }, window(state, body, table.count()));
    state.scroll.* = 500_000;

    var tree = try ui.Tree.init(frame, &grid.atoms, 4096);
    const drawing: RenderContext = .{ .inbox = Atom.from("grid_test") };
    try std.testing.expectEqual(Status.ready, render(state, instance, .table, &tree, table, viewport_w, viewport_h, frame, drawing));
    try std.testing.expect(tree.count <= elementCount(21, 1));
    // The window's whole rows are drawn, and none outside it.
    try std.testing.expect(recordsRect(&tree, elementId(instance, "table.row", 500_000, 0)));
    try std.testing.expect(recordsRect(&tree, elementId(instance, "table.row", 500_019, 0)));
    try std.testing.expect(!recordsRect(&tree, elementId(instance, "table.row", 499_999, 0)));
    try std.testing.expect(!recordsRect(&tree, elementId(instance, "table.row", 500_021, 0)));
}

test "a table with a row freed among its rows lists its populated rows by number, and the table's own order again once it is used" {
    var grid: TestGrid = .{};
    try grid.init();
    defer grid.deinit();
    const table = grid.table;
    _ = try table.tryInsert(.{ .subject = Table.String{}, .count = @as(u32, 1), .key = Table.String{} });
    table.free(.{ .row = 1, .generation = table.rowGeneration(1) });
    var lines: [4]u32 = undefined;
    const holed = viewOrder(grid.state, table, try grid.orderContext());
    try std.testing.expect(holed.rows.lines != null);
    try std.testing.expectEqualSlices(u32, &.{ 0, 2 }, linesOf(holed.rows, &lines));
    // The freed row used again: the rows are the table's first again, in no memory.
    _ = try table.tryInsert(.{ .subject = Table.String{}, .count = @as(u32, 2), .key = Table.String{} });
    const dense = viewOrder(grid.state, table, try grid.orderContext());
    try std.testing.expect(dense.rows.lines == null);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, linesOf(dense.rows, &lines));
}

/// Whether `tree` holds a rect of `instance`'s role `role` at any row from 0 to `rows`.
fn recordsRole(tree: *const ui.Tree, instance: Atom, comptime role: []const u8, rows: u32) bool {
    for (0..rows) |row| {
        if (recordsRect(tree, elementId(instance, role, @intCast(row), 0))) return true;
    }
    return false;
}

/// The rect of `id` in `tree`; it must be there.
fn rectParams(tree: *const ui.Tree, id: ui.ElementId) ui.RectParams {
    for (tree.elements[0..tree.count]) |element| {
        const params = switch (element) {
            .open_rect, .rect => |params| params,
            else => continue,
        };
        if (std.meta.eql(params.id, id)) return params;
    }
    unreachable;
}

/// The slice the tests over a windowed source hold: rows 1000 to 1064 of at least 5000.
const test_slice: Rows = .{ .slice = .{ .first = 1000, .total = .{ .at_least = 5000 } } };

test "over a slice, a scroll past what the table holds gives a window it does not hold, drawn as empty rows" {
    var grid: NumberGrid = .{};
    try grid.init(64);
    defer grid.deinit();
    const state = grid.state;
    const table = grid.table;
    const instance = table.name;
    const frame = try grid.frame();
    const order_context: OrderContext = .{ .atoms = &grid.atoms, .allocator = frame.allocator, .rows = test_slice };
    const viewport_w: f32 = 400;
    const viewport_h: f32 = toolbar_height + header_height + 20.5 * row_height;
    _ = settle(state, table, .table, viewport_w, viewport_h, order_context);
    // The selection is the table's first row, the slice's first position.
    try std.testing.expectEqual(@as(u32, 1000), viewOrder(state, table, order_context).rowPosition(state.selected_row.*).?);
    state.scroll.* = 1200;
    _ = settle(state, table, .table, viewport_w, viewport_h, order_context);
    try std.testing.expectEqual(@as(u32, 1200), state.scroll.*);
    const body = bodySize(viewport_w, viewport_h, .{});
    try std.testing.expectEqual(Window{ .first = 1200, .count = 21 }, window(state, body, 5000));

    var tree = try ui.Tree.init(frame, &grid.atoms, 4096);
    const drawing: RenderContext = .{ .inbox = Atom.from("grid_test"), .rows = test_slice };
    try std.testing.expectEqual(Status.ready, render(state, instance, .table, &tree, table, viewport_w, viewport_h, frame, drawing));
    // Positions 1200 to 1219 are drawn empty; no row of the table is.
    try std.testing.expect(recordsRect(&tree, elementId(instance, "table.row.empty", 1200, 0)));
    try std.testing.expect(recordsRect(&tree, elementId(instance, "table.row.empty", 1219, 0)));
    try std.testing.expect(!recordsRole(&tree, instance, "table.row", 64));
    // Scrolled back into what it holds, its rows are drawn, numbered by their place in the set.
    state.scroll.* = 1050;
    var held = try ui.Tree.init(frame, &grid.atoms, 4096);
    _ = render(state, instance, .table, &held, table, viewport_w, viewport_h, frame, drawing);
    try std.testing.expect(recordsRect(&held, elementId(instance, "table.row", 50, 0)));
    try std.testing.expect(recordsRect(&held, elementId(instance, "table.row.empty", 1064, 0)));
}

test "over a slice, typing in the filter answers filter_changed and leaves the order" {
    var grid: NumberGrid = .{};
    try grid.init(64);
    defer grid.deinit();
    const state = grid.state;
    const table = grid.table;
    const instance = table.name;
    const frame = try grid.frame();
    const ctx: UpdateContext = .{ .viewport_w = 400, .viewport_h = 400, .atoms = &grid.atoms, .allocator = frame.allocator, .rows = test_slice };
    _ = updateMessage(state, instance, .table, .table_filter_focus, table, ctx);
    const typed: input.TextInputMsg = .{ .codepoint = '7' };
    const text = messageOf(.table_filter_text, &instance, std.mem.asBytes(&typed));
    try std.testing.expectEqual(OutcomeTag.filter_changed, tagOf(try update(state, instance, .table, .table_filter_text, text, table, ctx)));
    try std.testing.expectEqualStrings("7", state.filterField().query());
    const order = viewOrder(state, table, ctx.orderContext());
    try std.testing.expectEqual(@as(u32, 64), order.rows.len);
    try std.testing.expectEqual(@as(u32, 5000), order.rowCount());
}

test "over a slice, a header's sort answers sort_wanted and leaves the order" {
    var grid: NumberGrid = .{};
    try grid.init(64);
    defer grid.deinit();
    const state = grid.state;
    const table = grid.table;
    const frame = try grid.frame();
    const ctx: UpdateContext = .{ .viewport_w = 400, .viewport_h = 400, .atoms = &grid.atoms, .allocator = frame.allocator, .rows = test_slice };
    const column: ColumnRef = .{ .instance = table.name, .field = 0 };
    const received: sequencer.Message = .{ .tag = Atom.from(Msg.table_header_sort), .user_data = std.mem.asBytes(&column) };
    const ascending = try update(state, table.name, .table, .table_header_sort, received, table, ctx);
    try std.testing.expectEqual(SortWanted{ .field = 0, .descending = false }, ascending.sort_wanted);
    const descending = try update(state, table.name, .table, .table_header_sort, received, table, ctx);
    try std.testing.expectEqual(SortWanted{ .field = 0, .descending = true }, descending.sort_wanted);
    const order = viewOrder(state, table, ctx.orderContext());
    try std.testing.expect(order.rows.lines == null);
    const unsorted = try update(state, table.name, .table, .table_header_sort, received, table, ctx);
    try std.testing.expectEqual(SortWanted{ .field = null, .descending = false }, unsorted.sort_wanted);
}

test "inline draws exactly the rows asked, under its header, with no scroll of its own" {
    var grid: NumberGrid = .{};
    try grid.init(10);
    defer grid.deinit();
    const state = grid.state;
    const table = grid.table;
    const instance = table.name;
    const frame = try grid.frame();
    const presentation: Presentation = .{ .access = .read, .toolbar = .hidden };
    var tree = try ui.Tree.init(frame, &grid.atoms, 4096);
    const drawing: RenderContext = .{ .inbox = Atom.from("grid_test"), .presentation = presentation, .inline_rows = .{ .first = 3, .count = 4 } };
    try std.testing.expectEqual(Status.ready, render(state, instance, .table, &tree, table, 400, 1000, frame, drawing));
    for (0..10) |row| {
        const asked = row >= 3 and row < 7;
        try std.testing.expectEqual(asked, recordsRect(&tree, elementId(instance, "table.row", @intCast(row), 0)));
    }
    try std.testing.expect(recordsRect(&tree, elementId(instance, "table.header", 0, 0)));
    try std.testing.expect(!recordsRect(&tree, elementId(instance, "toolbar", 0, 0)));
    const root = rectParams(&tree, elementId(instance, "root", 0, 0));
    try std.testing.expect(root.on_scroll == null);
    try std.testing.expect(rectParams(&tree, bodyElement(instance)).on_scroll == null);
    try std.testing.expectEqual(header_height + 4 * row_height, inlineHeight(4, presentation));
    try std.testing.expectEqual(ui.Dim{ .fixed = inlineHeight(4, presentation) }, root.size.h);
    // No header asked: the rows alone.
    try std.testing.expectEqual(2 * row_height, inlineHeight(2, .{ .toolbar = .hidden, .header = .hidden }));
}

test "inline, rows are striped by their position, so a piece drawn from an odd one starts on the other stripe" {
    var grid: NumberGrid = .{};
    try grid.init(10);
    defer grid.deinit();
    const state = grid.state;
    const table = grid.table;
    const instance = table.name;
    const frame = try grid.frame();
    const presentation: Presentation = .{ .access = .read, .toolbar = .hidden, .header = .hidden };
    var tree = try ui.Tree.init(frame, &grid.atoms, 4096);
    const drawing: RenderContext = .{ .inbox = Atom.from("grid_test"), .presentation = presentation, .style = default_style, .inline_rows = .{ .first = 3, .count = 4 } };
    try std.testing.expectEqual(Status.ready, render(state, instance, .table, &tree, table, 400, 1000, frame, drawing));
    // Rows 3 and 5, odd positions, in one stripe; 4 and 6 in the other: as a draw of all ten.
    try std.testing.expectEqual(default_style.row_bg_b, rectParams(&tree, elementId(instance, "table.row", 3, 0)).bg.?);
    try std.testing.expectEqual(default_style.row_bg_a, rectParams(&tree, elementId(instance, "table.row", 4, 0)).bg.?);
    try std.testing.expectEqual(default_style.row_bg_b, rectParams(&tree, elementId(instance, "table.row", 5, 0)).bg.?);
    try std.testing.expectEqual(default_style.row_bg_a, rectParams(&tree, elementId(instance, "table.row", 6, 0)).bg.?);
}

test "inline, a caller's rows are drawn in its order, its positions are places in its list, and its stripes follow them" {
    var grid: NumberGrid = .{};
    try grid.init(10);
    defer grid.deinit();
    const state = grid.state;
    const table = grid.table;
    const instance = table.name;
    const frame = try grid.frame();
    const presentation: Presentation = .{ .access = .read, .toolbar = .hidden, .header = .hidden };
    // A subset of the table's rows in an order of the caller's, as a page's group of rows is.
    const chosen = [_]u32{ 7, 2, 5, 9 };
    var tree = try ui.Tree.init(frame, &grid.atoms, 4096);
    const drawing: RenderContext = .{ .inbox = Atom.from("grid_test"), .presentation = presentation, .style = default_style, .chosen_rows = &chosen, .inline_rows = .{ .first = 1, .count = 2, .selected = 5 } };
    try std.testing.expectEqual(Status.ready, render(state, instance, .table, &tree, table, 400, 1000, frame, drawing));
    for (0..10) |row| {
        const asked = row == 2 or row == 5;
        try std.testing.expectEqual(asked, recordsRect(&tree, elementId(instance, "table.row", @intCast(row), 0)));
    }
    // Places 1 and 2 of the list: the other stripe from place 0's, then place 0's; row 5 selected.
    try std.testing.expectEqual(default_style.row_bg_b, rectParams(&tree, elementId(instance, "table.row", 2, 0)).bg.?);
    try std.testing.expectEqual(default_style.selected_bg, rectParams(&tree, elementId(instance, "table.row", 5, 0)).bg.?);
    // The order is the list's: the filter and the sort do not apply to it.
    const order = viewOrder(state, table, .{ .atoms = &grid.atoms, .allocator = frame.allocator, .presentation = presentation, .chosen_rows = &chosen });
    var lines: [4]u32 = undefined;
    try std.testing.expectEqualSlices(u32, &chosen, linesOf(order.rows, &lines));
    try std.testing.expectEqual(@as(u32, 4), order.total_rows);
    // None given: the table's own order, as ever.
    const own = viewOrder(state, table, .{ .atoms = &grid.atoms, .allocator = frame.allocator, .presentation = presentation });
    try std.testing.expect(own.rows.lines == null);
    try std.testing.expectEqual(@as(u32, 10), own.rows.len);
    // A row past the table's capacity, first in the list with nothing selected, is read for
    // nothing: it keeps its place, drawn empty, and the row after it is drawn.
    state.selected_present.* = 0;
    const past = [_]u32{ table.rowCapacity() + 3, 2 };
    var past_tree = try ui.Tree.init(frame, &grid.atoms, 4096);
    const past_drawing: RenderContext = .{ .inbox = Atom.from("grid_test"), .presentation = presentation, .style = default_style, .chosen_rows = &past, .inline_rows = .{ .first = 0, .count = 2 } };
    try std.testing.expectEqual(Status.ready, render(state, instance, .table, &past_tree, table, 400, 1000, frame, past_drawing));
    try std.testing.expect(recordsRect(&past_tree, elementId(instance, "table.row", 2, 0)));
}

/// The texts of the header `tree` records, in order.
fn headerNames(tree: *const ui.Tree, buffer: [][]const u8) []const []const u8 {
    var count: usize = 0;
    var in_header = false;
    var depth: usize = 0;
    for (tree.elements[0..tree.count]) |element| {
        switch (element) {
            .open_rect => |params| {
                if (in_header) depth += 1;
                const header_id = elementId(params.id.atom, "table.header", 0, 0);
                if (std.meta.eql(params.id, header_id)) {
                    in_header = true;
                    depth = 1;
                }
            },
            .close_rect => if (in_header) {
                depth -= 1;
                if (depth == 0) in_header = false;
            },
            .text => |text| if (in_header and count < buffer.len) {
                buffer[count] = text.str;
                count += 1;
            },
            else => {},
        }
    }
    return buffer[0..count];
}

test "a caller's columns are drawn in its order, none given the table's, and the last column fills when asked" {
    var grid: TestGrid = .{};
    try grid.init();
    defer grid.deinit();
    const frame = try grid.mem.frameScratchAllocator();
    const instance = grid.table.name;
    var names: [8][]const u8 = undefined;
    const presentation: Presentation = .{ .access = .read, .toolbar = .hidden, .header = .names, .row_numbers = .hidden };
    var as_is = try ui.Tree.init(frame, &grid.atoms, 4096);
    _ = render(grid.state, instance, .table, &as_is, grid.table, 800, 400, frame, .{ .inbox = Atom.from("grid_test"), .presentation = presentation, .inline_rows = .{ .first = 0, .count = 2 } });
    const table_order = headerNames(&as_is, &names);
    try std.testing.expectEqual(@as(usize, 3), table_order.len);
    try std.testing.expectEqualStrings("subject", table_order[0]);
    try std.testing.expectEqualStrings("key", table_order[2]);
    // None asked to fill: the last column keeps its share.
    try std.testing.expect(rectParams(&as_is, elementId(instance, "table.header.cell", 0, 2)).size.w == .fixed);

    const chosen = [_]u32{ 2, 0, 9 };
    var filling = presentation;
    filling.last_column = .fills;
    var ordered = try ui.Tree.init(frame, &grid.atoms, 4096);
    _ = render(grid.state, instance, .table, &ordered, grid.table, 800, 400, frame, .{ .inbox = Atom.from("grid_test"), .presentation = filling, .columns = &chosen, .inline_rows = .{ .first = 0, .count = 2 } });
    const caller_order = headerNames(&ordered, &names);
    try std.testing.expectEqual(@as(usize, 2), caller_order.len);
    try std.testing.expectEqualStrings("key", caller_order[0]);
    try std.testing.expectEqualStrings("subject", caller_order[1]);
    // The count is not drawn; the last, subject, takes what is left, header and cells.
    try std.testing.expect(!recordsRect(&ordered, elementId(instance, "table.cell", 0, 1)));
    try std.testing.expectEqual(ui.Dim.fill, rectParams(&ordered, elementId(instance, "table.header.cell", 0, 0)).size.w);
    try std.testing.expectEqual(ui.Dim.fill, rectParams(&ordered, elementId(instance, "table.cell", 1, 0)).size.w);
    try std.testing.expect(rectParams(&ordered, elementId(instance, "table.cell", 1, 2)).size.w == .fixed);
}

test "inline, the caller's row is drawn selected whole and the state's selection is not, and a header of names only takes no click" {
    var grid: NumberGrid = .{};
    try grid.init(10);
    defer grid.deinit();
    const state = grid.state;
    const table = grid.table;
    const instance = table.name;
    const frame = try grid.frame();
    const presentation: Presentation = .{ .access = .read, .toolbar = .hidden, .header = .names };
    // The state has row 2 selected; the caller's cursor is on row 5.
    state.selected_present.* = 1;
    state.selected_row.* = 2;
    state.selected_row_generation.* = table.rowGeneration(2);
    var tree = try ui.Tree.init(frame, &grid.atoms, 4096);
    const drawing: RenderContext = .{ .inbox = Atom.from("grid_test"), .presentation = presentation, .style = default_style, .inline_rows = .{ .first = 0, .count = 8, .selected = 5 } };
    try std.testing.expectEqual(Status.ready, render(state, instance, .table, &tree, table, 400, 1000, frame, drawing));
    try std.testing.expectEqual(default_style.selected_bg, rectParams(&tree, elementId(instance, "table.row", 5, 0)).bg.?);
    try std.testing.expect(!std.meta.eql(default_style.selected_bg, rectParams(&tree, elementId(instance, "table.row", 2, 0)).bg.?));
    // No cell of the selected row is marked, as the grid's own selection marks one.
    try std.testing.expect(rectParams(&tree, elementId(instance, "table.cell", 5, 0)).border == null);
    // The header names its column and offers nothing to click.
    try std.testing.expect(recordsRect(&tree, elementId(instance, "table.header.cell", 0, 0)));
    try std.testing.expect(!recordsRect(&tree, elementId(instance, "table.header.name", 0, 0)));
    try std.testing.expect(!recordsRect(&tree, elementId(instance, "table.header.menu", 0, 0)));
    try std.testing.expectEqual(header_height + 8 * row_height, inlineHeight(8, presentation));
    try std.testing.expectEqual(@as(u32, 2), chromeHitsPerGrid(3, presentation));
    // None selected: no row has the selection's fill.
    var unselected = try ui.Tree.init(frame, &grid.atoms, 4096);
    const plain: RenderContext = .{ .inbox = Atom.from("grid_test"), .presentation = presentation, .inline_rows = .{ .first = 0, .count = 8 } };
    _ = render(state, instance, .table, &unselected, table, 400, 1000, frame, plain);
    for (0..8) |row| {
        const fill = rectParams(&unselected, elementId(instance, "table.row", @intCast(row), 0)).bg.?;
        try std.testing.expect(!std.meta.eql(default_style.selected_bg, fill));
    }
}

test "a grid without its toolbar draws none, gives its body the room, and takes no filter key" {
    var grid: NumberGrid = .{};
    try grid.init(10);
    defer grid.deinit();
    const state = grid.state;
    const table = grid.table;
    const instance = table.name;
    const frame = try grid.frame();
    const presentation: Presentation = .{ .toolbar = .hidden };
    try std.testing.expectEqual(Size{ .width = 400, .height = 300 - header_height }, bodySize(400, 300, presentation));
    try std.testing.expectEqual(Size{ .width = 400, .height = 300 - header_height - toolbar_height }, bodySize(400, 300, .{}));
    try std.testing.expect(chromeHitsPerGrid(3, presentation) < chromeHitsPerGrid(3, .{}));
    try std.testing.expect(visibleRows(300, .grid, presentation) > visibleRows(300, .grid, .{}));
    const ctx: UpdateContext = .{ .viewport_w = 400, .viewport_h = 300, .atoms = &grid.atoms, .allocator = frame.allocator, .presentation = presentation };
    try std.testing.expectEqual(OutcomeTag.ignored, tagOf(updateMessage(state, instance, .table, .table_filter_focus, table, ctx)));
    try std.testing.expect(!isFiltering(state));
    var tree = try ui.Tree.init(frame, &grid.atoms, 4096);
    const drawing: RenderContext = .{ .inbox = Atom.from("grid_test"), .presentation = presentation };
    _ = render(state, instance, .table, &tree, table, 400, 300, frame, drawing);
    try std.testing.expect(!recordsRect(&tree, elementId(instance, "toolbar", 0, 0)));
    // Its body, which scrolls, is where the tree's commit records its place.
    try std.testing.expect(rectParams(&tree, bodyElement(instance)).on_scroll != null);
}

test "a table that loses rows after its grid settled is drawn with what it has, reading nothing outside it" {
    var grid: NumberGrid = .{};
    try grid.init(10);
    defer grid.deinit();
    const state = grid.state;
    const table = grid.table;
    const instance = table.name;
    const frame = try grid.frame();
    _ = settle(state, table, .table, 400, 600, .{ .atoms = &grid.atoms, .allocator = frame.allocator });
    state.selected_row.* = 9;
    state.selected_row_generation.* = table.rowGeneration(9);
    // A refresh lands between the settle and the draw: the last five rows go.
    for (5..10) |row| table.free(.{ .row = @intCast(row), .generation = table.rowGeneration(@intCast(row)) });
    var tree = try ui.Tree.init(frame, &grid.atoms, 4096);
    try std.testing.expectEqual(Status.ready, render(state, instance, .table, &tree, table, 400, 600, frame, .{ .inbox = Atom.from("grid_test") }));
    try std.testing.expect(recordsRect(&tree, elementId(instance, "table.row", 4, 0)));
    try std.testing.expect(!recordsRect(&tree, elementId(instance, "table.row", 5, 0)));
    // A caller whose count is behind (ten rows, of which the table holds five): the missing
    // positions are drawn empty.
    const stale: Rows = .{ .slice = .{ .first = 0, .total = .{ .known = 10 } } };
    var behind = try ui.Tree.init(frame, &grid.atoms, 4096);
    _ = render(state, instance, .table, &behind, table, 400, 600, frame, .{ .inbox = Atom.from("grid_test"), .rows = stale });
    try std.testing.expect(recordsRect(&behind, elementId(instance, "table.row", 4, 0)));
    for (5..10) |position| try std.testing.expect(recordsRect(&behind, elementId(instance, "table.row.empty", @intCast(position), 0)));
    try std.testing.expect(!recordsRect(&behind, elementId(instance, "table.row", 5, 0)));
}

test "an inline draw asked for more rows than a grid draws draws max_visible_rows of them" {
    var grid: NumberGrid = .{};
    try grid.init(200);
    defer grid.deinit();
    const instance = grid.table.name;
    const frame = try grid.frame();
    const presentation: Presentation = .{ .access = .read, .toolbar = .hidden };
    var tree = try ui.Tree.init(frame, &grid.atoms, 8192);
    const drawing: RenderContext = .{ .inbox = Atom.from("grid_test"), .presentation = presentation, .inline_rows = .{ .first = 0, .count = 1000 } };
    _ = render(grid.state, instance, .table, &tree, grid.table, 400, 1000, frame, drawing);
    try std.testing.expect(recordsRect(&tree, elementId(instance, "table.row", max_visible_rows - 1, 0)));
    try std.testing.expect(!recordsRect(&tree, elementId(instance, "table.row", max_visible_rows, 0)));
    try std.testing.expect(tree.count <= elementCount(max_visible_rows, 1));
    const root = rectParams(&tree, elementId(instance, "root", 0, 0));
    try std.testing.expectEqual(ui.Dim{ .fixed = inlineHeight(max_visible_rows, presentation) }, root.size.h);
}

test "a slice placed past what 32-bit positions hold is placed where its last row still has one" {
    var grid: NumberGrid = .{};
    try grid.init(64);
    defer grid.deinit();
    const state = grid.state;
    const table = grid.table;
    const frame = try grid.frame();
    const far: Rows = .{ .slice = .{ .first = std.math.maxInt(u64), .total = .{ .at_least = std.math.maxInt(u64) } } };
    const ctx: UpdateContext = .{ .viewport_w = 400, .viewport_h = 400, .atoms = &grid.atoms, .allocator = frame.allocator, .rows = far };
    const order = viewOrder(state, table, ctx.orderContext());
    try std.testing.expectEqual(std.math.maxInt(u32) - 64, order.first);
    try std.testing.expectEqual(std.math.maxInt(u32) - 1, order.rowPosition(63).?);
    _ = settle(state, table, .table, 400, 400, ctx.orderContext());
    for ([_]Msg{ .last_cell, .nav_down, .page_down, .first_cell, .page_up }) |message| _ = updateMessage(state, table.name, .table, message, table, ctx);
    try std.testing.expectEqual(@as(u32, 0), state.selected_row.*);
}

/// A stand-in measure for tests: ten pixels a byte, whatever the font.
fn tenPixelsAByte(context: *const anyopaque, font: roop.Font, text: []const u8) f32 {
    _ = context;
    _ = font;
    return @floatFromInt(text.len * 10);
}

test "columns fit to what they hold, the fill column takes the rest, and those that do not fit go from the last" {
    var grid: TestGrid = .{};
    try grid.init();
    defer grid.deinit();
    const frame = try grid.mem.frameScratchAllocator();
    const measure: TextMeasure = .{ .context = &grid, .width_fn = tenPixelsAByte };
    const rows = [_]u32{ 0, 1 };
    // key, subject (the fill), count: key's widest is `data`, count's its name.
    const asked = [_]u32{ 2, 0, 1 };
    const wide = try fitColumns(grid.table, &asked, 0, &rows, 800, measure, default_style, &grid.atoms, frame);
    try std.testing.expectEqualSlices(u32, &.{ 2, 0, 1 }, wide.columns);
    try std.testing.expectEqual(@as(usize, 1), wide.fill);
    try std.testing.expectEqual(@as(f32, 40 + 2 * cell_padding), wide.widths[0]);
    try std.testing.expectEqual(@as(f32, 50 + 2 * cell_padding), wide.widths[2]);
    try std.testing.expectEqual(@as(f32, 800 - (56 + 66)), wide.widths[1]);
    // Narrow: count, after the fill, goes first; narrower, key before it too.
    const narrow = try fitColumns(grid.table, &asked, 0, &rows, 300, measure, default_style, &grid.atoms, frame);
    try std.testing.expectEqualSlices(u32, &.{ 2, 0 }, narrow.columns);
    try std.testing.expectEqual(@as(f32, 300 - 56), narrow.widths[narrow.fill]);
    const narrowest = try fitColumns(grid.table, &asked, 0, &rows, 200, measure, default_style, &grid.atoms, frame);
    try std.testing.expectEqualSlices(u32, &.{0}, narrowest.columns);
    // A fill none of the columns: the last.
    const unnamed = try fitColumns(grid.table, &.{ 0, 2 }, 1, &rows, 800, measure, default_style, &grid.atoms, frame);
    try std.testing.expectEqual(@as(usize, 1), unnamed.fill);
    // At least the narrowest a column is.
    const short = try fitColumns(grid.table, &.{ 1, 0 }, 0, &.{}, 800, measure, default_style, &grid.atoms, frame);
    try std.testing.expectEqual(@as(f32, 66), short.widths[0]);

    // Drawn inline with them: every column, each its width, the fill the rest, header and cells,
    // even where the shares would draw fewer.
    const instance = grid.table.name;
    const presentation: Presentation = .{ .access = .read, .toolbar = .hidden, .header = .names, .row_numbers = .hidden };
    var tree = try ui.Tree.init(frame, &grid.atoms, 4096);
    _ = render(grid.state, instance, .table, &tree, grid.table, 300, 400, frame, .{ .inbox = Atom.from("grid_test"), .presentation = presentation, .fitted = wide, .inline_rows = .{ .first = 0, .count = 2 } });
    var names: [8][]const u8 = undefined;
    const drawn = headerNames(&tree, &names);
    try std.testing.expectEqual(@as(usize, 3), drawn.len);
    try std.testing.expectEqualStrings("key", drawn[0]);
    try std.testing.expectEqual(ui.Dim{ .fixed = 56 }, rectParams(&tree, elementId(instance, "table.header.cell", 0, 2)).size.w);
    try std.testing.expectEqual(ui.Dim.fill, rectParams(&tree, elementId(instance, "table.header.cell", 0, 0)).size.w);
    try std.testing.expectEqual(ui.Dim.fill, rectParams(&tree, elementId(instance, "table.cell", 1, 0)).size.w);
    try std.testing.expectEqual(ui.Dim{ .fixed = 66 }, rectParams(&tree, elementId(instance, "table.cell", 1, 1)).size.w);
}
