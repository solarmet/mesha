//! A document as a page: the blocks of an org text (`org.zig`) laid out from top to bottom over
//! the tables and values systems publish (`sources.zig`), with one cursor that walks its
//! headings, its lines of text and the rows of its tables, headings that fold, and a scroll in
//! pixels. Free functions over state the document's owner keeps: the document has no panel, no
//! keys and no table of its own. Its drawing is `view.zig`'s.
//!
//! What the owner keeps, in tables it declares at init:
//! - a `StateRow` in its own state table (`addStateFields`): the cursor, the scroll, the size of
//!   the view the page is laid out in, and what was last warned of;
//! - a table of folds, a row a heading folded (`addFoldFields`, `FoldRow`).
//! A table block's grid keeps nothing between frames: its columns are the page's, its rows in
//! view and its selected row the cursor's, and it neither sorts nor filters, so its state is
//! made anew for each draw.
//!
//! Its system's `names` hold its reader of the panels' events and `view.element_names`; its
//! access declares those two tables written, the panels' events read, and what its page reads
//! (`declareAccess`, given the parsed text, so only the sources it names; each counts against
//! `sequencer.Access.max_tables`). Each run of its kernel
//! lays the page out again, as a run of the outline builds its lines again:
//!
//!     const arena = (try pass.frame.memory.frameScratchAllocator()).allocator;
//!     const state = try pass.writeSingleton(state_table, document.StateRow);
//!     const folds = try pass.writeRows(folds_table, document.FoldRow);
//!     const resized = try document.followResizes(pass, resize_reader, panel, state);
//!     const parsed = try document.parse(arena, org_text);
//!     const published = try document.publishedIn(arena, pass, parsed);
//!     const folded = try document.foldedKeys(arena, folds.read());
//!     const fonts = style.outlineStyle(); // the owner's theme
//!     const metrics = document.metricsOf(font_metrics, fonts.text_font, fonts.code_font);
//!     var page = try document.layout(arena, parsed, published, folded, metrics);
//!     for (pass.frame.messages) |received| switch (try document.take(received, page, state, folds, input)) {
//!         .toggled => page = try document.layout(arena, parsed, published, try document.foldedKeys(arena, folds.read()), metrics),
//!         .chosen => |at| act(at), // a click on what the cursor is already on
//!         .moved, .scrolled, .ignored => {},
//!     };
//!     // A key of the owner's: `document.step(page, state, .next)`, then act on `document.at`.
//!     document.settleView(page, state, if (resized) .cursor else .keep);
//!     try document.pruneFolds(page, folds);
//!
//! What the page shows, a publisher publishes from a kernel of its own system, which declares
//! both of `sources.zig`'s tables written; its pass hands them over, refusing a system that did
//! not declare them:
//!
//!     const publishing = try sources.Publishing.of(pass) orelse return; // not made: nothing to do
//!     publishing.publishSource(owner, .{ .name = "vcs-git.unstaged", .table = files_table, .shown = &.{ "change", "path" } });
//!     publishing.publishValue(owner, "vcs-git.branch", branch);
//!
//! To keep the cursor on the same thing across a refresh that rewrote a source's rows (the same
//! file, when the rows are new), the owner remembers what names the row the cursor is on, a cell
//! of the row `at` gives, before the refresh, and after it finds the row holding it and puts the
//! cursor there with `cursorOnRow`. In a group's table ("this file in this changelist") it
//! remembers too the group `at` gave with the row (`AtRow.group`: its `block` and `key_text`),
//! and puts the cursor back with `cursorOnGroup(page, block, key_text, row)`, which lands on the
//! group's heading when the row is no longer in it; on a group's heading, the same with no row.
//! When the group itself is gone, `cursorOnGroup` gives null, and the owner settles the cursor
//! it had: it lands where the group's heading was (`Cursor.landing`), on the group that took
//! its place, or the stop after the groups.
//! Rows are shown in the table's own order, its allocated rows by id: a publisher that frees and
//! inserts rows in a journaled run is handed ids in no useful order, so it writes its source
//! through `table_view.rowsInOrder`, which hands back the rows in the order they are shown.
//!
//! Its draw does the same reading through the tables (`publishedIn` takes a `DrawTables` there),
//! settles a copy of the cursor and calls `view.record`; it writes nothing. A page's blocks and
//! texts are in the allocator `layout` was given and last as long as it does: a frame's arena.
//!
//! Blocks are known by a key that lasts across refreshes and across edits of other parts of the
//! text: a heading's is its level, the literal parts of its text (not its macros' values) and
//! how many headings of that level and text come before it; a table's its source's name and
//! how many tables of that source come before it; a group block's its two sources' names and
//! how many such blocks come before it; any other block's the line it is on. A group's heading
//! and its table have keys of their group block's and of the group row's `:key` cell as text
//! (not its place or its row's id), so a group's fold and the cursor in it follow the group
//! through a refresh that reorders, adds or removes groups; a second group row of the same key
//! text, which a publisher should not write, is told apart by how many came before it. The
//! cursor and the folds are kept by key, so a fold outlives a refresh and an edit elsewhere in
//! the text, and is lost when its heading's words change, or its group is gone (its row is then
//! kept, naming nothing, until `pruneFolds` frees it).
//!
//! A group block (`#+BEGIN: group :by b :key k :source s :columns "a b"`, its body one heading
//! line) is laid out as a heading and a table for each row of `:by`, in that table's own order:
//! the heading its template line, at the level written, with `{{{field}}}` the group row's cell
//! of that field as the grid reads it (`ui.grid.valueText`: a number as the grid draws it, an
//! atom by its name), a published value of that name when the row has no such field, and nothing
//! when neither is; `{{{count()}}}` the group's own rows (`{{{count}}}`, without parentheses, is
//! a name like any other, a field or a value named `count`). Under it the rows of `:source` whose
//! `:key` cell reads the same as the group row's (each read as `valueText` reads it, so a number
//! in one source and text in the other match when they read alike), in that table's own order,
//! drawn as a table block's with its `:columns`, `:fill` and `:rows` (which caps each group's
//! table); every group's columns are fit together, over the first `rows_a_chunk` rows shown
//! across the block, so they line up down the page, and their names are drawn once, above the
//! first group's table the page shows (folds applied), the others their rows alone. A group with no rows is its heading with a
//! dim `(empty)` and no table, never left out. Each layout reads every row of the two sources
//! once, bucketing `:source`'s rows by their key's text, and makes two blocks a group: for 200
//! groups over 5,000 rows, 5,200 cells read and 400 blocks, not a million comparisons. A source
//! not published, or a `:key` field a source lacks, makes the block one dim line saying so (the
//! missing key warned of once, as a missing column is). As in org, what follows the block's
//! `#+END:` is in the last group's section, and folding that group hides it: an author puts a
//! heading after a group block. Since each layout reads and buckets `:source`'s rows again, an
//! owner lays its page out once a run where it can, and again only when its folds change.
//!
//! While a group block's groups are not known (a source of its not published, `unread`, or
//! lacking the `:key` field), `pruneFolds` lets go no fold of its groups, so a failed refresh
//! unfolds no changelist. A publisher whose refresh failed keeps its rows and marks its source
//! `unread` (`sources.Publishing.setSourceState`; drawn in the error colour); it does not empty the source,
//! which says there are no groups, and lets their folds go.
//!
//! What the page leaves out: the title and the refresh (the owner's to show and to follow); a
//! paragraph whose text, its macros' values put in, is only spaces, and a term whose text is
//! blank (`- Upstream :: {{{vcs-git.upstream}}}` with no upstream); a table block with no rows;
//! a heading whose content (what comes before the next heading of its level or a shallower one)
//! is table blocks, all of them empty, and group blocks of no groups, and nothing else shown, so
//! a "Pending changelists" over none is not shown, while one group, even `(empty)`, keeps it;
//! and everything under a folded heading, up to the next heading of its level or a shallower
//! one: a heading over a group block folds every group of it written deeper. A table whose source nobody published is one dim line that
//! says so, so an author sees the mistake. A macro with no published value is nothing;
//! `{{{count(name)}}}` is how many rows the source `name` has.
//!
//! The cursor is on a heading, a line of text (a paragraph, a term of a list, a line not read)
//! or a row of a table, its "stop"; the header of a table is no stop. A group's heading is a
//! heading (`next_heading` goes group to group, TAB folds its table) and its rows a table's; `at`
//! on one gives `group`, the group row of `:by` and its `:source`, and on a row of its table the
//! row with its `group`.
//!
//! Kernel-side functions read tables only as a journaled kernel may: a table's row count, which
//! rows are allocated and their generations (`Table.count`, `isAllocated`, `rowGeneration`), so
//! a row's place in its table is its rank among the allocated rows by id, the grid's own order;
//! and a group's key cells and its heading's fields through `ui.grid.valueText`, which reads
//! cells as any reader does, never raw storage.
const std = @import("std");
const mesha = @import("mesha");
const Atom = mesha.Atom;
const Table = mesha.Table;
const plugin = mesha.plugin;
const resources = mesha.resources;
const sequencer = mesha.sequencer;
const input = mesha.input;
const ui = mesha.ui;
const grid = ui.grid;
const org = @import("org.zig");
const sources = @import("sources.zig");
const panel_frame = @import("../panel_frame.zig");

const Log = mesha.log.scope("document");

// ---- the source -------------------------------------------------------------------------------

/// An org text read into blocks (`org.parse`): what `layout` lays out. Its slices are of the
/// text and of the allocator `parse` was given; it lasts while both do.
pub const Document = struct {
    /// The blocks, in the order of the text.
    blocks: []const org.Block,
    /// The spans the blocks' texts are ranges of.
    spans: []const org.Span,
};

/// `text` read into a `Document`, its arrays in `allocator`, every block of it. The slices are
/// of `text`, which the caller keeps as long as the document.
pub fn parse(allocator: std.mem.Allocator, text: []const u8) !Document {
    const sized = org.parse(text, &.{}, &.{});
    const blocks = try allocator.alloc(org.Block, sized.blocks_seen);
    const spans = try allocator.alloc(org.Span, sized.spans_seen);
    const parsed = org.parse(text, blocks, spans);
    std.debug.assert(parsed.complete());
    return .{ .blocks = blocks[0..parsed.blocks_kept], .spans = spans[0..parsed.spans_kept] };
}

// ---- what systems publish ---------------------------------------------------------------------

/// A source as a page reads it: its name, its table found, the fields for showing.
pub const Source = struct {
    /// Its name; the sources table's text, good for the run or the draw.
    name: []const u8,
    /// The publisher's table: in a kernel, as the run sees it.
    table: *Table,
    /// The names of the fields for showing, separated by spaces.
    shown: []const u8,
    /// Whether the table holds what its publisher last read.
    state: sources.SourceState,
};

/// What systems publish, as one run or one draw reads it: the sources whose tables were found,
/// and the values' rows. Its slices are the allocator's and the tables'; good for the run.
pub const Published = struct {
    /// The sources, each with its table.
    sources: []const Source = &.{},
    /// The rows of `editor_document_values`; null without it.
    values: ?Table.ReadQuery(sources.ValueRow) = null,
    /// Names the atom and reference cells a page shows as text (a group's key and the fields its
    /// heading names) as the grid reads them (`ui.grid.valueText`); read only. The frame's, or
    /// the draw's.
    atoms: *const Atom.Registry,

    fn sourceNamed(published: Published, name: []const u8) ?Source {
        for (published.sources) |source| {
            if (std.mem.eql(u8, source.name, name)) return source;
        }
        return null;
    }

    fn value(published: Published, name: []const u8) ?[]const u8 {
        const rows = published.values orelse return null;
        return sources.valueOf(rows, name);
    }
};

const sources_table = Atom.from(sources.sources_table_name);
const values_table = Atom.from(sources.values_table_name);

/// Declares read what `parsed`'s page reads: the published sources and values, and the table of
/// each source it names (a table block's, a group block's two, or a `count`'s) that is there;
/// no other publisher's.
/// Called in the access function of the owner's system, each frame, so a source published later
/// is read once it is.
pub fn declareAccess(access: *sequencer.Access, tables: *Table.Registry, parsed: Document) void {
    const published = tables.findByName(sources_table) orelse return;
    access.read(sources_table);
    if (tables.findByName(values_table) != null) access.read(values_table);
    var rows = published.readQuery(sources.SourceRow);
    while (rows.next()) |row| {
        if (!names(parsed, row.view.name)) continue;
        const name = row.view.table.*;
        if (tables.findByName(name) != null) access.read(name);
    }
}

/// Whether `parsed` names the source `name`: in a table block, as a group block's `:by` or
/// `:source`, or as a `count`'s argument.
pub fn names(parsed: Document, name: []const u8) bool {
    for (parsed.blocks) |block| {
        switch (block.content) {
            .table => |table| if (std.mem.eql(u8, table.source, name)) return true,
            .group => |group| {
                if (std.mem.eql(u8, group.by, name)) return true;
                if (std.mem.eql(u8, group.table.source, name)) return true;
            },
            else => {},
        }
    }
    for (parsed.spans) |span| {
        const macro = switch (span) {
            .macro => |macro| macro,
            .text, .line_end => continue,
        };
        if (!macro.parenthesized or !std.mem.eql(u8, macro.name, "count")) continue;
        if (std.mem.eql(u8, macro.argument, name)) return true;
    }
    return false;
}

/// What a draw reads a page through, as its kernel reads it through its pass: the draw's table
/// registry and atoms, borrowed for the draw.
pub const DrawTables = struct {
    /// The tables, read as the draw reads them.
    tables: *Table.Registry,
    /// What names atom and reference cells.
    atoms: *const Atom.Registry,
};

/// What is published that `parsed` names, as a page reads it, in `allocator`: through `place`, the
/// kernel's pass, which checks each table was declared (`declareAccess`), or a draw's
/// `DrawTables`, which reads tables itself. The one place a source's table is found from its
/// name: a source whose table is not there, or not declared, is left out and shows as not
/// published.
pub fn publishedIn(allocator: std.mem.Allocator, place: anytype, parsed: Document) !Published {
    const Reader = @TypeOf(place);
    const in_kernel = Reader == *sequencer.Pass or Reader == *const sequencer.Pass;
    if (!in_kernel and Reader != DrawTables) @compileError("publishedIn takes a kernel's pass or the draw's DrawTables");
    const atoms: *const Atom.Registry = if (in_kernel) place.frame.atoms else place.atoms;
    const sources_rows = tableOf(place, sources_table) orelse return .{ .atoms = atoms };
    const values_rows: ?Table.ReadQuery(sources.ValueRow) = if (tableOf(place, values_table)) |values| values.readQuery(sources.ValueRow) else null;
    var found: std.ArrayList(Source) = .empty;
    var rows = sources_rows.readQuery(sources.SourceRow);
    while (rows.next()) |row| {
        if (!names(parsed, row.view.name)) continue;
        const table = tableOf(place, row.view.table.*) orelse continue;
        const state: sources.SourceState = if (row.view.state.* == @intFromEnum(sources.SourceState.unread)) .unread else .ok;
        try found.append(allocator, .{ .name = row.view.name, .table = table, .shown = row.view.shown, .state = state });
    }
    return .{ .sources = found.items, .values = values_rows, .atoms = atoms };
}

/// The table `name` through a pass, if declared and there, or through the draw's registry.
fn tableOf(place: anytype, name: Atom) ?*Table {
    if (@TypeOf(place) == DrawTables) return place.tables.findByName(name);
    if (!place.declares(name)) return null;
    return place.table(name) catch null;
}

// ---- the state the owner keeps ----------------------------------------------------------------

/// The fields `addStateFields` adds to the owner's state table, as its `getRow` views them. The
/// pointers are the table's, valid while the row stays where it is.
pub const StateRow = struct {
    /// `Cursor.block`.
    document_block: *u64,
    /// `Cursor.row`.
    document_row: *u32,
    /// `Cursor.row_id`.
    document_row_id: *u32,
    /// `Cursor.row_generation`.
    document_row_generation: *u32,
    /// `Cursor.index`.
    document_index: *u32,
    /// `Cursor.landing` and one; 0 for none.
    document_landing: *u32,
    /// `Cursor.scroll`.
    document_scroll: *f32,
    /// The width of the view the page is shown in, in pixels.
    document_view_width: *f32,
    /// The height of the view the page is shown in, in pixels: what a page moves and the scroll
    /// is kept within.
    document_view_height: *f32,
    /// A hash of the columns named that their sources lack, as last warned of: 0 for none.
    document_warned: *u64,
};

/// Adds `StateRow`'s fields to `schema`, the owner's state table's, in `StateRow`'s order. Their
/// zero is a cursor that has been nowhere, unscrolled, in a view of no size.
pub fn addStateFields(schema: *Table.Schema) !void {
    try schema.addFieldFallible("document_block", u64, .hex);
    try schema.addFieldFallible("document_row", u32, .int);
    try schema.addFieldFallible("document_row_id", u32, .int);
    try schema.addFieldFallible("document_row_generation", u32, .int);
    try schema.addFieldFallible("document_index", u32, .int);
    try schema.addFieldFallible("document_landing", u32, .int);
    try schema.addFieldFallible("document_scroll", f32, .int);
    try schema.addFieldFallible("document_view_width", f32, .int);
    try schema.addFieldFallible("document_view_height", f32, .int);
    try schema.addFieldFallible("document_warned", u64, .hex);
}

/// The values `StateRow`'s fields start at, for an owner that inserts its state row itself.
pub const initial_state = .{
    .document_block = @as(u64, 0),
    .document_row = @as(u32, 0),
    .document_row_id = @as(u32, 0),
    .document_row_generation = @as(u32, 0),
    .document_index = @as(u32, 0),
    .document_landing = @as(u32, 0),
    .document_scroll = @as(f32, 0),
    .document_view_width = @as(f32, 0),
    .document_view_height = @as(f32, 0),
    .document_warned = @as(u64, 0),
};

/// A row of the owner's table of folds: the key of a heading folded. A table of folds is one
/// document's alone: `pruneFolds` frees every row whose key is no heading of that document's
/// text, so an owner of two documents keeps a table of folds for each.
pub const FoldRow = struct {
    /// The heading's key.
    key: *u64,
};

/// Adds `FoldRow`'s field to `schema`, the owner's table of folds, which holds one document's
/// folds alone.
pub fn addFoldFields(schema: *Table.Schema) !void {
    try schema.addFieldFallible("key", u64, .hex);
}

/// Keeps in `state` the size of the panel `panel`'s content, as it was told: from the panels
/// system's `resized` events, read with the owner's own `reader` (interned at its init, the
/// events table declared read), or, while that reader has read none, from the panel as it is laid
/// out now. Whether the size kept changed: the owner then settles its view with `.cursor`, so the
/// cursor stays in a view that shrank. A panel told no size (hidden behind a maximized one)
/// keeps the one it had.
pub fn followResizes(pass: *sequencer.Pass, reader: Atom, panel: Atom, state: StateRow) !bool {
    const frame = pass.frame;
    const events = plugin.panels.Events.of(frame.tables, plugin.panels.events_table_name);
    const first_read = !events.hasRead(reader);
    // All the events table keeps, so a run of other events never pushes a size out unread.
    var told: [plugin.panels.Events.retained]plugin.panels.Event = undefined;
    const taken = try events.read(pass, reader, &told);
    var size: ?panel_frame.ContentSize = null;
    if (first_read) {
        if (panel_frame.contentRect(frame.tables, frame.atoms, panel)) |content| size = .{ .width = content.w, .height = content.h };
    }
    for (taken) |event| {
        const resized = switch (event) {
            .resized => |resized| resized,
            .focused, .unfocused => continue,
        };
        if (resized.panel != panel) continue;
        const content = panel_frame.contentSize(frame.tables, frame.atoms, resized);
        if (content.width <= 0 or content.height <= 0) continue;
        size = content;
    }
    const kept = size orelse return false;
    const same = state.document_view_width.* == kept.width and state.document_view_height.* == kept.height;
    if (same) return false;
    state.document_view_width.* = kept.width;
    state.document_view_height.* = kept.height;
    return true;
}

// ---- the layout -------------------------------------------------------------------------------

/// How a page is measured.
pub const Metrics = struct {
    /// The height of a heading's or a text's line, in pixels.
    line_height: f32,
};

/// Space between lines, in pixels, beside the taller of the outline's two fonts: a page's lines
/// are the outline's.
const line_spacing: f32 = 6;
/// The height of a line before its fonts are loaded.
const fallback_line_height: f32 = 21;

/// A page's metrics for lines in the outline's two fonts, `text_font` and `code_font` (the
/// owner's `ui.outline.Style`'s), from `font_metrics`, the table `resources_font_metrics` (a
/// kernel's, declared read, or the draw's), as the outline measures its lines; a fallback while
/// the fonts are not loaded.
pub fn metricsOf(font_metrics: ?*Table, text_font_name: Atom, code_font_name: Atom) Metrics {
    const fallback: Metrics = .{ .line_height = fallback_line_height };
    const found = font_metrics orelse return fallback;
    const text_font = resources.fontMetrics(found, resources.kApplicationScope, text_font_name) orelse return fallback;
    const code_font = resources.fontMetrics(found, resources.kApplicationScope, code_font_name) orelse return fallback;
    const tallest = @max(text_font.pixel_height, code_font.pixel_height);
    return .{ .line_height = @round(tallest + line_spacing) };
}

/// How a page presents its tables: read only, no toolbar, no row numbers, a header of names, the
/// last column as wide as the rest of the page when the columns are not fit to what they hold
/// (`view.RecordOptions.measure`; fit, the `:fill` column takes the rest).
pub const table_presentation: grid.Presentation = .{ .access = .read, .toolbar = .hidden, .header = .names, .row_numbers = .hidden, .last_column = .fills };
/// The height of a table block's header, in pixels.
pub const table_header_height: f32 = grid.inlineHeight(0, table_presentation);
/// The height of a table's row, in pixels: the grid's.
pub const table_row_height: f32 = grid.inlineHeight(1, .{ .toolbar = .hidden, .header = .hidden });

/// What a block of the page is.
pub const Kind = enum {
    /// `* Heading`: a line with a fold mark.
    heading,
    /// A paragraph, its lines filled into one.
    paragraph,
    /// `- term :: text`: a term and its text, drawn aligned with the terms beside it.
    term,
    /// A line not read, as written.
    text,
    /// A table a system publishes.
    table,
    /// A table or a group block whose source nobody published, or a group block whose `:key`
    /// a source lacks: one dim line saying so.
    unpublished,
    /// A group block, as it stands among the blocks: never shown, its groups being the headings
    /// and tables after it (`Block.groups`).
    group,
};

/// A table block's table, as the page shows it.
pub const TableBlock = struct {
    /// The source's name, as the text writes it.
    source: []const u8,
    /// The publisher's table.
    table: *Table,
    /// The rows shown: the table's, at most `:rows`.
    rows: u32,
    /// The fields drawn as columns, in order (`ui.grid.RenderContext.columns`): those `:columns`
    /// names among the source's fields for showing, in its order; the fields for showing, in
    /// theirs, without `:columns` or when none it names is there. In the layout's allocator.
    columns: []const u32,
    /// The field of `columns` that takes the width the others leave: the one `:fill` names when
    /// it is drawn, else the last of `columns`.
    fill: u32,
    /// Whether the table holds what its publisher last read; `unread` draws it in the error
    /// colour.
    state: sources.SourceState,
    /// Whether its columns' names are drawn above its rows: `.names` for a table block; of a group
    /// block's tables, only the first the page shows has them (`.hidden` the others), its
    /// columns fit as every group's are, so one row of names stands over them all.
    header: grid.Header = .names,
    /// A group's table: the ids of the table's rows it shows, every one whose key matches, in
    /// the table's own order (`rows` the most shown). Null for a table block, which shows the
    /// table's own rows. In the layout's allocator.
    lines: ?[]const u32 = null,
    /// The rows its columns are fit over (`view.RecordOptions.measure`): for a group's table, the
    /// first `rows_a_chunk` rows shown across every group of its block, so the groups' columns
    /// line up down the page; null for a table block, fit over its first rows. In the layout's
    /// allocator.
    measured: ?[]const u32 = null,

    /// How it is drawn: `table_presentation` with its `header`.
    pub fn presentation(table: TableBlock) grid.Presentation {
        var drawn = table_presentation;
        drawn.header = table.header;
        return drawn;
    }

    /// The height of its header, in pixels: `table_header_height` with its names, 0 without.
    pub fn headerHeight(table: TableBlock) f32 {
        return if (table.header == .hidden) 0 else table_header_height;
    }

    /// The row at place `place` among those it shows; null past them, or for a row gone.
    pub fn rowAtPlace(table: TableBlock, place: u32) ?Table.RowHandle {
        const lines = table.lines orelse return rowAt(table.table, place);
        if (place >= lines.len) return null;
        const row = lines[place];
        if (!table.table.isAllocated(row)) return null;
        return .{ .row = row, .generation = table.table.rowGeneration(row) };
    }

    /// The place among those it shows of the row `handle`; null for a row gone, or not among
    /// them (a group's table shows a row of another group's key nowhere).
    pub fn placeOfRow(table: TableBlock, handle: Table.RowHandle) ?u32 {
        const lines = table.lines orelse return positionOf(table.table, handle);
        if (!table.table.valid(handle)) return null;
        const index = std.mem.indexOfScalar(u32, lines, handle.row) orelse return null;
        return @intCast(index);
    }
};

/// A group of a group block: one row of its `:by` source, shown as a heading and a table of the
/// rows of its `:source` whose `:key` cell reads as the row's. What a group's heading and its
/// table are of, and what `at` gives on them. Its texts and tables are the layout's.
pub const Group = struct {
    /// The key of the group's heading, which folds it and which `at` names it by.
    key: u64,
    /// The key of the group block that made it: what `cursorOnGroup` is given.
    block: u64,
    /// The group's heading as shown, its macros' values put in, without its `(empty)`.
    text: []const u8,
    /// The group row's `:key` cell as text, as the grid reads it (`ui.grid.valueText`): what
    /// names the group across refreshes.
    key_text: []const u8,
    /// The name of the `:by` source, as the text writes it.
    by_source: []const u8,
    /// The `:by` source's table.
    by_table: *Table,
    /// The group's row of `by_table`: the changelist, to read its cells.
    by_row: Table.RowHandle,
    /// The name of the `:source` source, whose rows the group's table shows.
    source: []const u8,
    /// The `:source` source's table: "every row of this group" is the rows of it whose `:key`
    /// cell reads `key_text`.
    table: *Table,
};

/// A block of the page: what it says, where it is, and the cursor's places in it.
pub const Block = struct {
    /// Names it across refreshes and edits elsewhere in the text: what the cursor and a fold are
    /// kept by. Never 0.
    key: u64,
    /// What it is.
    kind: Kind,
    /// The line of the text it starts on, from 1.
    line: u32,
    /// How far it is indented: a heading's level less one, and anything under a heading that
    /// heading's level.
    depth: u8,
    /// A heading's level; 0 for any other block.
    level: u8 = 0,
    /// What it says, its macros' values put in: a heading's, a paragraph's, a term's term, a
    /// line's, the not-published line's; for a table, its source's name.
    text: []const u8 = "",
    /// A term's text, after its term; `(empty)` for a group's heading whose table has no rows,
    /// drawn dim after its text.
    detail: []const u8 = "",
    /// Whether the page shows it.
    shown: bool = false,
    /// A heading folded, whose section the page leaves out.
    folded: bool = false,
    /// Pixels from the top of the page to its top; 0 when not shown.
    top: f32 = 0,
    /// Its height, in pixels; 0 when not shown.
    height: f32 = 0,
    /// The index of its first stop among the page's; 0 when not shown.
    first_stop: u32 = 0,
    /// How many stops it has: one for a line, a row each for a table; 0 when not shown.
    stops: u32 = 0,
    /// A table's table; null for any other block, an unpublished table's too.
    table: ?TableBlock = null,
    /// A heading whose content, as the page shows it unfolded, is one table block: that block's
    /// index in `Layout.blocks`.
    only_table: ?u32 = null,
    /// A group's heading's and its table's group; null for any other block.
    group: ?Group = null,
    /// A group block's number of groups, which decides whether a heading over it is left out.
    groups: u32 = 0,
};

/// What a block names that its source lacks.
pub const MissingKind = enum {
    /// A column of `:columns` the source does not show: the page leaves it out.
    column,
    /// A group block's `:key`, a field the source does not have: the block is one dim line.
    key,
};

/// A column a table or group block names that its source does not show, or a group's `:key` a
/// source lacks.
pub const Missing = struct {
    /// The source's name.
    source: []const u8,
    /// The column or the field named.
    column: []const u8,
    /// Which it is.
    kind: MissingKind = .column,
};

/// A document laid out as a page: its blocks, which of them are shown and where, and the
/// cursor's stops. In the allocator `layout` was given, with texts of the document's text and the
/// tables'; good while those last, a run or a draw.
pub const Layout = struct {
    /// Every block of the text that can be on the page, in the text's order: the title and the
    /// refresh are not.
    blocks: []const Block,
    /// The indices in `blocks` of those shown, in page order.
    shown: []const u32,
    /// How many stops the page has.
    stops: u32,
    /// The page's height, in pixels.
    height: f32,
    /// The height of a line, in pixels.
    line_height: f32,
    /// The document's title, its macros' values put in; empty without one.
    title: []const u8,
    /// How often its sources are asked to refresh; null when the text does not say.
    refresh: ?org.Seconds,
    /// The columns named that their sources do not show, and the group keys they lack.
    missing: []const Missing,
    /// The keys of the group blocks whose groups are not known this run: a source of theirs not
    /// published, or `unread`, or lacking the `:key` field. `pruneFolds` lets go no fold of
    /// their groups.
    unknown_groups: []const u64 = &.{},
};

/// Lays `parsed` out as a page over what is `published`, with the headings whose keys `folded`
/// holds folded, measured by `metrics`; in `allocator`, an arena's. Reads the published tables'
/// row counts and the values' rows, as a kernel may: call it in the owner's kernel, and in its
/// draw with what the draw read.
pub fn layout(allocator: std.mem.Allocator, parsed: Document, published: Published, folded: []const u64, metrics: Metrics) !Layout {
    var blocks: std.ArrayList(Block) = .empty;
    var occurrences: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    var title: []const u8 = "";
    var refresh: ?org.Seconds = null;
    var missing: std.ArrayList(Missing) = .empty;
    var unknown_groups: std.ArrayList(u64) = .empty;
    // The level of the heading the blocks read now are under; 0 before the first.
    var under: u8 = 0;
    for (parsed.blocks) |block| {
        switch (block.content) {
            .title => |spans| {
                title = try resolve(allocator, spans.of(parsed.spans), published, null);
                continue;
            },
            .refresh => |seconds| {
                refresh = seconds;
                continue;
            },
            .group => |group| {
                const key = try keyOf(allocator, &occurrences, block, parsed.spans);
                const read = try readGroups(allocator, &blocks, block, group, parsed.spans, published, under, key, &missing, &unknown_groups);
                // As in org, what follows the groups' last heading is in its section.
                if (read != 0) under = group.heading.level;
                continue;
            },
            else => {},
        }
        var placed = try readBlock(allocator, block, parsed.spans, published, under, &missing);
        placed.key = try keyOf(allocator, &occurrences, block, parsed.spans);
        if (placed.kind == .heading) under = placed.level;
        try blocks.append(allocator, placed);
    }
    const all = blocks.items;
    leaveOutEmptyHeadings(all);
    // A heading's one table is its content's whether or not it is folded away.
    findOnlyTables(all);
    applyFolds(all, folded);
    nameFirstGroupTables(all);
    var shown: std.ArrayList(u32) = .empty;
    var top: f32 = 0;
    var stops: u32 = 0;
    for (all, 0..) |*placed, index| {
        if (!placed.shown) continue;
        placed.top = top;
        placed.first_stop = stops;
        if (placed.table) |table| {
            placed.height = grid.inlineHeight(table.rows, table.presentation());
            placed.stops = table.rows;
        } else {
            placed.height = metrics.line_height;
            placed.stops = 1;
        }
        top += placed.height;
        stops += placed.stops;
        try shown.append(allocator, @intCast(index));
    }
    return .{
        .blocks = all,
        .shown = shown.items,
        .stops = stops,
        .height = top,
        .line_height = metrics.line_height,
        .title = title,
        .refresh = refresh,
        .missing = missing.items,
        .unknown_groups = unknown_groups.items,
    };
}

/// A block of the text as the page has it, before it is placed: its kind, its text and whether it
/// shows on its own merits (a paragraph or a term's text of only spaces, and an empty table, do not).
fn readBlock(allocator: std.mem.Allocator, block: org.Block, spans: []const org.Span, published: Published, under: u8, missing: *std.ArrayList(Missing)) !Block {
    var placed: Block = .{ .key = 0, .kind = .text, .line = block.line, .depth = under, .shown = true };
    switch (block.content) {
        .heading => |heading| {
            placed.kind = .heading;
            placed.level = heading.level;
            placed.depth = heading.level - 1;
            placed.text = try resolve(allocator, heading.text.of(spans), published, null);
        },
        .paragraph => |text| {
            placed.kind = .paragraph;
            placed.text = try resolve(allocator, text.of(spans), published, null);
            placed.shown = std.mem.trim(u8, placed.text, " \t").len != 0;
        },
        .term => |term| {
            placed.kind = .term;
            placed.text = try resolve(allocator, term.term.of(spans), published, null);
            placed.detail = try resolve(allocator, term.text.of(spans), published, null);
            placed.shown = std.mem.trim(u8, placed.detail, " \t").len != 0;
        },
        .text => |line| placed.text = try ui.displayText(allocator, line),
        .table => |table| {
            const source = published.sourceNamed(table.source) orelse {
                placed.kind = .unpublished;
                placed.text = try std.fmt.allocPrint(allocator, "({s} is not published)", .{table.source});
                return placed;
            };
            placed.kind = .table;
            placed.text = table.source;
            const count = source.table.count();
            const rows = if (table.rows) |most| @min(count, most) else count;
            const columns = try columnsOf(allocator, source, table, missing);
            const fill = fillOf(source, table, columns);
            placed.table = .{ .source = table.source, .table = source.table, .rows = rows, .columns = columns, .fill = fill, .state = source.state };
            placed.shown = rows != 0;
        },
        .title, .refresh, .group => unreachable,
    }
    return placed;
}

/// The field of `columns` that takes the width the others leave: the one `table`'s `:fill`
/// names when it is drawn, else the last.
fn fillOf(source: Source, table: org.Table, columns: []const u32) u32 {
    const last: u32 = if (columns.len != 0) columns[columns.len - 1] else 0;
    if (table.fill.len == 0) return last;
    const index = shownField(source, table.fill) orelse return last;
    const field: u32 = @intCast(index);
    if (std.mem.indexOfScalar(u32, columns, field) == null) return last;
    return field;
}

/// Appends to `blocks` what the group block `block` is on the page: the block itself, never
/// shown (or one dim line, when a source is not published or lacks the `:key` field), then, for
/// each row of its `:by` source in that table's own order, the group's heading, and its table
/// when any row of `:source` has its key. How many groups it made.
///
/// A row of `:source` is in the group whose key cell reads the same as its own, each read as the
/// grid reads a cell (`ui.grid.valueText`), so a number in one source and text in the other match
/// when they read alike. The rows of `:source` are read once, bucketed by their key's text, so a
/// layout reads each row of either source once: proportionate to the groups and the rows, not
/// their product. A group's keys are made from `key` and the group row's key text, so a fold and
/// the cursor follow a group wherever the refresh puts it; a second row of the same key text, which
/// a publisher should not write, is told apart by how many came before it.
fn readGroups(allocator: std.mem.Allocator, blocks: *std.ArrayList(Block), block: org.Block, group: org.Group, spans: []const org.Span, published: Published, under: u8, key: u64, missing: *std.ArrayList(Missing), unknown: *std.ArrayList(u64)) !u32 {
    var stand_in: Block = .{ .key = key, .kind = .group, .line = block.line, .depth = under };
    const by_found = published.sourceNamed(group.by);
    const source_found = published.sourceNamed(group.table.source);
    // Groups not known this run: no fold of theirs is let go (`pruneFolds`).
    const by_read = if (by_found) |by| by.state == .ok else false;
    const source_read = if (source_found) |source| source.state == .ok else false;
    if (!by_read or !source_read) try unknown.append(allocator, key);
    if (by_found == null or source_found == null) {
        const name = if (by_found == null) group.by else group.table.source;
        stand_in.kind = .unpublished;
        stand_in.shown = true;
        stand_in.text = try std.fmt.allocPrint(allocator, "({s} is not published)", .{name});
        try blocks.append(allocator, stand_in);
        return 0;
    }
    const by = by_found.?;
    const source = source_found.?;
    const by_key = by.table.getSchema().fieldIndex(group.key);
    const source_key = source.table.getSchema().fieldIndex(group.key);
    if (by_key == null or source_key == null) {
        const lacking = if (by_key == null) group.by else group.table.source;
        stand_in.kind = .unpublished;
        stand_in.shown = true;
        stand_in.text = try std.fmt.allocPrint(allocator, "({s} has no field {s})", .{ lacking, group.key });
        try missing.append(allocator, .{ .source = lacking, .column = group.key, .kind = .key });
        if (by_read and source_read) try unknown.append(allocator, key);
        try blocks.append(allocator, stand_in);
        return 0;
    }
    const stand_in_index = blocks.items.len;
    try blocks.append(allocator, stand_in);

    const buckets = try rowsByKey(allocator, source.table, @intCast(source_key.?), published.atoms);
    const columns = try columnsOf(allocator, source, group.table, missing);
    const fill = fillOf(source, group.table, columns);
    var measured: std.ArrayList(u32) = .empty;
    var occurrences: std.StringHashMapUnmanaged(u32) = .empty;
    var made: u32 = 0;
    var buffer: grid.ValueTextBuffer = undefined;
    const by_field: u32 = @intCast(by_key.?);
    var row: u32 = 0;
    while (row < by.table.rowCapacity()) : (row += 1) {
        if (!by.table.isAllocated(row)) continue;
        const by_row: Table.RowHandle = .{ .row = row, .generation = by.table.rowGeneration(row) };
        const read_key = grid.valueText(by.table, row, by_field, &buffer, published.atoms);
        const key_text = try allocator.dupe(u8, read_key);
        const lines: []const u32 = if (buckets.get(key_text)) |found| found.items else &.{};
        const seen = try occurrences.getOrPut(allocator, key_text);
        if (!seen.found_existing) seen.value_ptr.* = 0;
        const occurrence = seen.value_ptr.*;
        seen.value_ptr.* += 1;

        const macros: GroupMacros = .{ .table = by.table, .row = row, .count = @intCast(lines.len) };
        const text = try resolve(allocator, group.heading.text.of(spans), published, macros);
        const level = group.heading.level;
        const of: Group = .{
            .key = groupKey(key, .heading, key_text, occurrence),
            .block = key,
            .text = text,
            .key_text = key_text,
            .by_source = group.by,
            .by_table = by.table,
            .by_row = by_row,
            .source = group.table.source,
            .table = source.table,
        };
        try blocks.append(allocator, .{
            .key = of.key,
            .kind = .heading,
            .line = block.line,
            .depth = level - 1,
            .level = level,
            .text = text,
            .detail = if (lines.len == 0) "(empty)" else "",
            .shown = true,
            .group = of,
        });
        made += 1;
        if (lines.len == 0) continue;
        const matched: u32 = @intCast(lines.len);
        const rows: u32 = if (group.table.rows) |most| @min(matched, most) else matched;
        const room = rows_a_chunk -| @as(u32, @intCast(measured.items.len));
        const measured_here = @min(rows, room);
        try measured.appendSlice(allocator, lines[0..measured_here]);
        try blocks.append(allocator, .{
            .key = groupKey(key, .table, key_text, occurrence),
            .kind = .table,
            .line = block.line,
            .depth = level,
            .text = group.table.source,
            .shown = true,
            .table = .{ .source = group.table.source, .table = source.table, .rows = rows, .columns = columns, .fill = fill, .state = source.state, .header = .hidden, .lines = lines },
            .group = of,
        });
    }
    blocks.items[stand_in_index].groups = made;
    // One fit for every group's table, so their columns line up down the page.
    for (blocks.items[stand_in_index + 1 ..]) |*placed| {
        if (placed.table) |*table| table.measured = measured.items;
    }
    return made;
}

/// The ids of `table`'s rows, in its own order, by the text of their `field` cell as the grid
/// reads it, in `allocator`: one pass over the table.
fn rowsByKey(allocator: std.mem.Allocator, table: *Table, field: u32, atoms: *const Atom.Registry) !std.StringHashMapUnmanaged(std.ArrayList(u32)) {
    var buckets: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty;
    var buffer: grid.ValueTextBuffer = undefined;
    var row: u32 = 0;
    while (row < table.rowCapacity()) : (row += 1) {
        if (!table.isAllocated(row)) continue;
        const read = grid.valueText(table, row, field, &buffer, atoms);
        const entry = try buckets.getOrPut(allocator, read);
        if (!entry.found_existing) {
            // The text may be the buffer's, written again for the next row: the key keeps a copy.
            entry.key_ptr.* = try allocator.dupe(u8, read);
            entry.value_ptr.* = .empty;
        }
        try entry.value_ptr.append(allocator, row);
    }
    return buckets;
}

/// Which of a group's blocks a key is made for.
const GroupPart = enum(u8) { heading, table };

/// The key of a group's heading or table: of its group block's `block` key, the group row's key
/// text and how many groups of that text came before it in the block. Its high 16 bits are the
/// block key's (`ofGroupBlock`), so a fold can be told to be of the block's groups while they are
/// not known; its low 48 a hash of the rest, so two groups of a block share a key one time in
/// 2^48. Never 0.
fn groupKey(block: u64, part: GroupPart, key_text: []const u8, occurrence: u32) u64 {
    var hasher = std.hash.Wyhash.init(block);
    hasher.update(&.{@intFromEnum(part)});
    hasher.update(key_text);
    hasher.update(std.mem.asBytes(&occurrence));
    const low: u64 = hasher.final() & ~group_block_bits;
    const key = (block & group_block_bits) | low;
    return if (key == 0) 1 else key;
}

/// The bits of a group's key that are its group block's.
const group_block_bits: u64 = 0xffff_0000_0000_0000;

/// Whether `key` may be a key of a group of the group block `block`: one in 2^16 of other keys
/// is taken for one too, which only keeps a stale fold a run longer.
fn ofGroupBlock(key: u64, block: u64) bool {
    return key & group_block_bits == block & group_block_bits;
}

/// What a group's heading's macros read: its row of the `:by` source, and its own rows' number.
const GroupMacros = struct {
    /// The `:by` source's table.
    table: *Table,
    /// The group's row of it.
    row: u32,
    /// How many rows of `:source` the group has: `{{{count()}}}`.
    count: u32,
};

/// The fields of `source`'s table drawn as `table`'s columns, in order, in `allocator`: those its
/// `:columns` names among the source's fields for showing, in that order, or the fields for
/// showing in theirs, without `:columns` or when none it names is there. A name the source does
/// not show is added to `missing`. A name given again is drawn once, where it was first named:
/// a field drawn twice would give two cells one element id.
fn columnsOf(allocator: std.mem.Allocator, source: Source, table: org.Table, missing: *std.ArrayList(Missing)) ![]const u32 {
    var columns: std.ArrayList(u32) = .empty;
    var named = org.columns(table.columns);
    while (named.next()) |column| {
        const index = shownField(source, column) orelse {
            try missing.append(allocator, .{ .source = table.source, .column = column });
            continue;
        };
        const field: u32 = @intCast(index);
        if (std.mem.indexOfScalar(u32, columns.items, field) != null) continue;
        try columns.append(allocator, field);
    }
    if (columns.items.len != 0) return columns.items;
    var shown = org.columns(source.shown);
    while (shown.next()) |column| {
        const index = shownField(source, column) orelse continue;
        try columns.append(allocator, @intCast(index));
    }
    return columns.items;
}

/// The index of the field `column` of `source`'s table, when it is one of the source's fields
/// for showing.
fn shownField(source: Source, column: []const u8) ?usize {
    if (!containsWord(source.shown, column)) return null;
    return source.table.getSchema().fieldIndex(column);
}

fn containsWord(words: []const u8, word: []const u8) bool {
    var each = org.columns(words);
    while (each.next()) |found| {
        if (std.mem.eql(u8, found, word)) return true;
    }
    return false;
}

/// `spans` as one text, each macro's value put in: a published value by its name, or a source's
/// row count for `count(name)`; nothing for one not published. In a group's heading (`group`),
/// a name of a field of the group's row is that row's cell, as the grid reads it, before a
/// published value of that name, and `count()` is the group's own rows. `{{{count}}}`, without
/// parentheses, is a name like any other. A line's end is a space, as org fills.
fn resolve(allocator: std.mem.Allocator, spans: []const org.Span, published: Published, group: ?GroupMacros) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    var buffer: grid.ValueTextBuffer = undefined;
    for (spans) |span| switch (span) {
        .text => |words| try text.appendSlice(allocator, words),
        .line_end => try text.append(allocator, ' '),
        .macro => |macro| {
            if (macro.parenthesized and std.mem.eql(u8, macro.name, "count")) {
                if (macro.argument.len == 0) {
                    const of = group orelse continue;
                    try text.print(allocator, "{d}", .{of.count});
                    continue;
                }
                const source = published.sourceNamed(macro.argument) orelse continue;
                try text.print(allocator, "{d}", .{source.table.count()});
                continue;
            }
            if (group) |of| {
                if (of.table.getSchema().fieldIndex(macro.name)) |field| {
                    const cell = grid.valueText(of.table, of.row, @intCast(field), &buffer, published.atoms);
                    const shown = try ui.displayText(allocator, cell);
                    try text.appendSlice(allocator, shown);
                    continue;
                }
            }
            const value = published.value(macro.name) orelse continue;
            const shown = try ui.displayText(allocator, value);
            try text.appendSlice(allocator, shown);
        },
    };
    return text.items;
}

/// The key of `block`: see the module's doc. `occurrences` counts the blocks of each kind and
/// name seen so far.
fn keyOf(allocator: std.mem.Allocator, occurrences: *std.AutoHashMapUnmanaged(u64, u32), block: org.Block, spans: []const org.Span) !u64 {
    var hasher = std.hash.Wyhash.init(@intFromEnum(std.meta.activeTag(block.content)));
    switch (block.content) {
        .heading => |heading| {
            hasher.update(&.{heading.level});
            for (heading.text.of(spans)) |span| switch (span) {
                .text => |words| hasher.update(words),
                .macro, .line_end => {},
            };
        },
        .table => |table| hasher.update(table.source),
        .group => |group| {
            hasher.update(group.by);
            hasher.update(&.{0});
            hasher.update(group.table.source);
        },
        else => hasher.update(std.mem.asBytes(&block.line)),
    }
    const named = hasher.final();
    const seen = try occurrences.getOrPut(allocator, named);
    if (!seen.found_existing) seen.value_ptr.* = 0;
    const occurrence = seen.value_ptr.*;
    seen.value_ptr.* += 1;
    var keyed = std.hash.Wyhash.init(named);
    keyed.update(std.mem.asBytes(&occurrence));
    const key = keyed.final();
    return if (key == 0) 1 else key;
}

/// Leaves out each heading under which everything, up to the next heading of its level or a
/// shallower one, is empty table blocks, group blocks of no groups and headings left out, at
/// least one such block among them, as an empty "Staged changes" is not shown. A heading with a
/// sub-heading that shows keeps, and a group block of any group, even one `(empty)`, is content.
/// A group's heading is always shown. The deepest are decided first, last to first.
fn leaveOutEmptyHeadings(blocks: []Block) void {
    var index = blocks.len;
    while (index > 0) {
        index -= 1;
        const heading = &blocks[index];
        if (heading.kind != .heading or heading.group != null) continue;
        var tables: u32 = 0;
        var anything_shown = false;
        for (blocks[index + 1 ..]) |content| {
            if (content.kind == .heading and content.level <= heading.level) break;
            if (content.kind == .table) tables += 1;
            if (content.kind == .group) {
                if (content.groups == 0) tables += 1 else anything_shown = true;
            }
            if (content.shown) anything_shown = true;
        }
        if (tables != 0 and !anything_shown) heading.shown = false;
    }
}

/// Gives the names of their columns to the first table each group block shows, folds applied,
/// and to none of its others, which `readGroups` made without: one row of names over every
/// group's table, which share one fit of columns.
fn nameFirstGroupTables(blocks: []Block) void {
    // The group block whose groups are being read, and whether one of its tables has the names.
    var current: u64 = 0;
    var named = false;
    for (blocks) |*block| {
        const group = block.group orelse continue;
        if (group.block != current) {
            current = group.block;
            named = false;
        }
        if (named or !block.shown or block.table == null) continue;
        block.table.?.header = .names;
        named = true;
    }
}

/// Leaves out what is under each folded heading, up to the next heading of its level or a
/// shallower one.
fn applyFolds(blocks: []Block, folded: []const u64) void {
    // While a folded heading's section runs, its level.
    var hiding_to: ?u8 = null;
    for (blocks) |*block| {
        if (block.kind == .heading) block.folded = std.mem.indexOfScalar(u64, folded, block.key) != null;
        if (hiding_to) |level| {
            const ends = block.kind == .heading and block.level <= level;
            if (!ends) {
                block.shown = false;
                continue;
            }
            hiding_to = null;
        }
        if (block.folded) hiding_to = block.level;
    }
}

/// Notes, for each heading, the one table block its content is, where the page shows that alone
/// of it, folds aside.
fn findOnlyTables(blocks: []Block) void {
    for (blocks, 0..) |*heading, index| {
        if (heading.kind != .heading) continue;
        var only: ?u32 = null;
        var others = false;
        for (blocks[index + 1 ..], index + 1..) |content, content_index| {
            if (content.kind == .heading) break;
            if (!content.shown) continue;
            if (content.kind == .table and only == null) {
                only = @intCast(content_index);
            } else {
                others = true;
            }
        }
        heading.only_table = if (others) null else only;
    }
}

/// The keys of the folds `rows`, the owner's table of folds, holds, in `allocator`: what `layout`
/// takes.
pub fn foldedKeys(allocator: std.mem.Allocator, rows: Table.ReadQuery(FoldRow)) ![]const u64 {
    var keys: std.ArrayList(u64) = .empty;
    var folds = rows;
    while (folds.next()) |row| try keys.append(allocator, row.view.key.*);
    return keys.items;
}

// ---- rows of a table, by place ----------------------------------------------------------------

/// The row of `table` at `position` in its own order, the allocated rows by id as the grid shows
/// them; null past its rows.
pub fn rowAt(table: *Table, position: u32) ?Table.RowHandle {
    if (position >= table.count()) return null;
    if (grid.rowsDense(table)) return .{ .row = position, .generation = table.rowGeneration(position) };
    var seen: u32 = 0;
    var row: u32 = 0;
    while (row < table.rowCapacity()) : (row += 1) {
        if (!table.isAllocated(row)) continue;
        if (seen == position) return .{ .row = row, .generation = table.rowGeneration(row) };
        seen += 1;
    }
    return null;
}

/// The place in `table`'s own order of the row `handle`; null for a row that is gone.
pub fn positionOf(table: *Table, handle: Table.RowHandle) ?u32 {
    if (!table.valid(handle)) return null;
    if (grid.rowsDense(table)) return handle.row;
    var seen: u32 = 0;
    var row: u32 = 0;
    while (row < handle.row) : (row += 1) {
        if (table.isAllocated(row)) seen += 1;
    }
    return seen;
}

// ---- the cursor -------------------------------------------------------------------------------

/// Where the cursor is and how far the page is scrolled, as the owner's `StateRow` keeps it;
/// `.{}` has been nowhere, unscrolled.
pub const Cursor = struct {
    /// The key of the block it is in; 0 before it has been in any.
    block: u64 = 0,
    /// In a table block, the place among its rows of the row it is on; 0 in any other block.
    row: u32 = 0,
    /// In a table block, that row's id and generation as it was last placed: the cursor follows
    /// the row while it stays, and takes the row now at its place when it went.
    row_id: u32 = 0,
    /// The generation of `row_id`.
    row_generation: u32 = 0,
    /// Its stop on the page as it was last placed: where it lands when its block is gone from
    /// the text, unless `landing` says otherwise.
    index: u32 = 0,
    /// In a group's heading or table, the stop of the group's heading as it was last placed:
    /// where it lands when its group is gone (a changelist submitted), the stop that took the
    /// place of the group's first, so the cursor goes to the next group and not past it. Null
    /// elsewhere, where `index` is.
    landing: ?u32 = null,
    /// Pixels from the top of the page to the top of the view.
    scroll: f32 = 0,
};

/// The cursor `state` keeps.
pub fn cursorOf(state: StateRow) Cursor {
    return .{
        .block = state.document_block.*,
        .row = state.document_row.*,
        .row_id = state.document_row_id.*,
        .row_generation = state.document_row_generation.*,
        .index = state.document_index.*,
        .landing = if (state.document_landing.* == 0) null else state.document_landing.* - 1,
        .scroll = state.document_scroll.*,
    };
}

/// Keeps `cursor` in `state`, writing only what changed.
pub fn setCursor(state: StateRow, cursor: Cursor) void {
    if (state.document_block.* != cursor.block) state.document_block.* = cursor.block;
    if (state.document_row.* != cursor.row) state.document_row.* = cursor.row;
    if (state.document_row_id.* != cursor.row_id) state.document_row_id.* = cursor.row_id;
    if (state.document_row_generation.* != cursor.row_generation) state.document_row_generation.* = cursor.row_generation;
    if (state.document_index.* != cursor.index) state.document_index.* = cursor.index;
    const landing: u32 = if (cursor.landing) |stop| stop + 1 else 0;
    if (state.document_landing.* != landing) state.document_landing.* = landing;
    if (state.document_scroll.* != cursor.scroll) state.document_scroll.* = cursor.scroll;
}

/// A way `move` takes the cursor.
pub const Step = enum {
    /// The next stop: from a heading into its table at its first row, out of a table after its
    /// last.
    next,
    /// The stop before.
    previous,
    /// The heading the cursor is under; from a heading, the one its section is in.
    parent,
    /// The first stop.
    first,
    /// The last stop.
    last,
    /// A view's height on.
    page_down,
    /// A view's height back.
    page_up,
    /// The next heading.
    next_heading,
    /// The heading before; from what is under a heading, that heading.
    previous_heading,
};

/// A stop's block, by its place in the page, and its row in it.
const Place = struct { position: u32, row: u32 };

/// The block and row of stop `stop`, which is below `page.stops`.
fn placeOf(page: Layout, stop: u32) Place {
    var low: usize = 0;
    var high: usize = page.shown.len;
    // The last block whose first stop is at or before `stop`.
    while (high - low > 1) {
        const middle = low + (high - low) / 2;
        if (page.blocks[page.shown[middle]].first_stop <= stop) low = middle else high = middle;
    }
    const block = page.blocks[page.shown[low]];
    return .{ .position = @intCast(low), .row = stop - block.first_stop };
}

fn blockAt(page: Layout, page_position: u32) Block {
    return page.blocks[page.shown[page_position]];
}

/// The cursor on stop `stop`, scrolled `scroll`.
fn cursorAtStop(page: Layout, stop: u32, scroll: f32) Cursor {
    const place = placeOf(page, stop);
    const block = blockAt(page, place.position);
    var cursor: Cursor = .{ .block = block.key, .index = stop, .scroll = scroll, .landing = landingOf(page, block) };
    const table = block.table orelse return cursor;
    cursor.row = place.row;
    const handle = table.rowAtPlace(place.row) orelse return cursor;
    cursor.row_id = handle.row;
    cursor.row_generation = handle.generation;
    return cursor;
}

/// Where a cursor in `block` lands when the block is gone: in a group, its heading's stop.
fn landingOf(page: Layout, block: Block) ?u32 {
    const group = block.group orelse return null;
    if (block.kind == .heading) return block.first_stop;
    const heading = indexOfKey(page, group.key) orelse return null;
    return page.blocks[heading].first_stop;
}

fn indexOfKey(page: Layout, key: u64) ?u32 {
    for (page.blocks, 0..) |block, index| {
        if (block.key == key) return @intCast(index);
    }
    return null;
}

fn sanitizedScroll(scroll: f32) f32 {
    if (!std.math.isFinite(scroll)) return 0;
    return @max(scroll, 0);
}

/// The cursor brought up to date with a page laid out again: in its block and on its row where
/// that row is still shown, where its row went on the row now at its place (the one that took
/// its place) or the block's last, and where its block is not shown (folded away, or empty and
/// left out) on the last stop of the shown block before it, a folded heading for what is under
/// it. A block gone from the text gives the stop at its old place, a group's the stop at its
/// heading's old place (`Cursor.landing`). An empty page gives `.{}`.
/// The scroll is carried, 0 when negative or not a number.
pub fn settle(page: Layout, cursor: Cursor) Cursor {
    const scroll = sanitizedScroll(cursor.scroll);
    if (page.stops == 0) return .{ .scroll = scroll };
    const found = indexOfKey(page, cursor.block) orelse {
        const was = cursor.landing orelse cursor.index;
        const stop = @min(was, page.stops - 1);
        return cursorAtStop(page, stop, scroll);
    };
    const block = page.blocks[found];
    if (block.shown) {
        const row = if (block.table) |table| rowIn(table, cursor) else 0;
        return cursorAtStop(page, block.first_stop + row, scroll);
    }
    var before = found;
    while (before > 0) {
        before -= 1;
        const earlier = page.blocks[before];
        if (earlier.shown) return cursorAtStop(page, earlier.first_stop + earlier.stops - 1, scroll);
    }
    return cursorAtStop(page, 0, scroll);
}

/// The row of `table` the cursor is on: its own row while it is shown, else the row at its place,
/// else the last.
fn rowIn(table: TableBlock, cursor: Cursor) u32 {
    const handle: Table.RowHandle = .{ .row = cursor.row_id, .generation = cursor.row_generation };
    if (table.placeOfRow(handle)) |position| {
        if (position < table.rows) return position;
    }
    return @min(cursor.row, table.rows - 1);
}

/// Where a stop is on the page, in pixels from its top.
const Extent = struct { top: f32, bottom: f32 };

/// Where stop `stop` is: a table's first row measured `.with_header` from the table's top, so
/// its header shows with it.
fn extentOf(page: Layout, stop: u32, header: Header) Extent {
    const place = placeOf(page, stop);
    const block = blockAt(page, place.position);
    if (block.table == null) return .{ .top = block.top, .bottom = block.top + block.height };
    const row: f32 = @floatFromInt(place.row);
    const top = block.top + block.table.?.headerHeight() + row * table_row_height;
    const shown_top = if (place.row == 0 and header == .with_header) block.top else top;
    return .{ .top = shown_top, .bottom = top + table_row_height };
}

/// Whether a table's first row is measured with its header above it.
const Header = enum { with_header, row_only };

/// The stop at `y` pixels down the page, past its end the last.
fn stopAtY(page: Layout, y: f32) u32 {
    var low: usize = 0;
    var high: usize = page.shown.len;
    while (high - low > 1) {
        const middle = low + (high - low) / 2;
        if (blockAt(page, @intCast(middle)).top <= y) low = middle else high = middle;
    }
    const block = blockAt(page, @intCast(low));
    const table = block.table orelse return block.first_stop;
    const into = y - block.top - table.headerHeight();
    const rows: f32 = @floor(@max(into, 0) / table_row_height);
    const last: f32 = @floatFromInt(block.stops - 1);
    const row: u32 = @intFromFloat(@min(rows, last));
    return block.first_stop + row;
}

/// The cursor moved by `way` through `page`'s stops, never past either end; a step that finds
/// no stop leaves it where it is. A cursor not settled against `page` is settled first. The
/// pages move by `view_height` pixels. The scroll is carried: `scrollTo` follows the cursor.
pub fn move(page: Layout, cursor: Cursor, way: Step, view_height: f32) Cursor {
    const settled = settle(page, cursor);
    if (page.stops == 0) return settled;
    const from = settled.index;
    const last = page.stops - 1;
    const on_page = placeOf(page, from).position;
    const to: u32 = switch (way) {
        .next => @min(from + 1, last),
        .previous => from -| 1,
        .first => 0,
        .last => last,
        .page_down => pageFrom(page, from, view_height),
        .page_up => pageFrom(page, from, -view_height),
        .parent => parentStop(page, on_page) orelse from,
        .next_heading => headingAfter(page, on_page) orelse from,
        .previous_heading => headingBefore(page, on_page, .any) orelse from,
    };
    return cursorAtStop(page, to, settled.scroll);
}

/// The stop `by` pixels from stop `from`'s top: at least one stop on, as far as there is one.
fn pageFrom(page: Layout, from: u32, by: f32) u32 {
    const top = extentOf(page, from, .row_only).top;
    const wanted = top + by;
    const last = page.stops - 1;
    if (wanted >= page.height) return last;
    const found = if (wanted <= 0) 0 else stopAtY(page, wanted);
    if (found != from) return found;
    return if (by > 0) @min(from + 1, last) else from -| 1;
}

/// Which headings `headingBefore` stops at.
const Above = enum { any, shallower };

/// The stop of the nearest heading of the page before the block at `page`, of any level or only
/// one shallower than `level`.
fn headingBefore(page: Layout, on_page: u32, above: Above) ?u32 {
    const level = blockAt(page, on_page).level;
    var position = on_page;
    while (position > 0) {
        position -= 1;
        const block = blockAt(page, position);
        if (block.kind != .heading) continue;
        if (above == .shallower and block.level >= level) continue;
        return block.first_stop;
    }
    return null;
}

fn headingAfter(page: Layout, on_page: u32) ?u32 {
    var position = on_page + 1;
    while (position < page.shown.len) : (position += 1) {
        const block = blockAt(page, position);
        if (block.kind == .heading) return block.first_stop;
    }
    return null;
}

/// The heading the block at `page` is under; for a heading, the one its section is in.
fn parentStop(page: Layout, on_page: u32) ?u32 {
    const block = blockAt(page, on_page);
    if (block.kind == .heading) return headingBefore(page, on_page, .shallower);
    return headingBefore(page, on_page, .any);
}

/// The scroll, in pixels from the top of the page, that shows the cursor's stop whole (a table's
/// first row with its header) with the least change from `cursor.scroll`: never negative, never
/// past where the page's end meets the view's bottom. In a view shorter than the stop, its top.
pub fn scrollTo(page: Layout, cursor: Cursor, view_height: f32) f32 {
    if (page.stops == 0) return 0;
    var scroll = sanitizedScroll(cursor.scroll);
    const stop = @min(cursor.index, page.stops - 1);
    const extent = extentOf(page, stop, .with_header);
    if (extent.bottom > scroll + view_height) scroll = extent.bottom - view_height;
    if (extent.top < scroll) scroll = extent.top;
    return clampScroll(page, scroll, view_height);
}

/// `scroll` kept within the page, as `scrollTo` keeps it, without following the cursor: what a
/// kernel keeps of a wheel's scroll. Not a number is 0.
pub fn clampScroll(page: Layout, scroll: f32, view_height: f32) f32 {
    if (!std.math.isFinite(scroll)) return 0;
    const furthest = @max(page.height - view_height, 0);
    return std.math.clamp(scroll, 0, furthest);
}

/// The cursor on the nearest stop wholly in the view its scroll gives, for after a wheel: as it
/// is while its stop is in view, else the first stop in view when its stop is above, the last
/// when below. `cursor` is settled against `page`. The scroll is kept.
pub fn cursorInView(page: Layout, cursor: Cursor, view_height: f32) Cursor {
    if (page.stops == 0) return cursor;
    const scroll = sanitizedScroll(cursor.scroll);
    const last = page.stops - 1;
    const stop = @min(cursor.index, last);
    const extent = extentOf(page, stop, .row_only);
    var to = stop;
    if (extent.top < scroll) {
        to = stopAtY(page, scroll);
        if (extentOf(page, to, .row_only).top < scroll and to < last) to += 1;
    } else if (extent.bottom > scroll + view_height) {
        to = stopAtY(page, scroll + view_height);
        if (extentOf(page, to, .row_only).bottom > scroll + view_height and to > 0) to -= 1;
    }
    if (to == stop) return cursor;
    return cursorAtStop(page, to, cursor.scroll);
}

/// What the cursor is on, which the owner's keys act on.
pub const At = union(enum) {
    /// Nothing: the page is empty.
    none,
    /// A heading not a group's.
    heading: AtHeading,
    /// A group's heading: its row of the `:by` source and its `:source`.
    group: Group,
    /// A line of text: a paragraph, a term, a line not read, a table not published.
    text: AtText,
    /// A row of a table.
    row: AtRow,
};

/// A heading the cursor is on.
pub const AtHeading = struct {
    /// Its key.
    key: u64,
    /// What it says, its macros' values put in.
    text: []const u8,
    /// Where its content as the page shows it is one table: that table's source, which "every row
    /// of this section" acts on; null otherwise.
    source: ?[]const u8,
    /// That source's table.
    table: ?*Table,
};

/// A line of text the cursor is on.
pub const AtText = struct {
    /// Its block's key.
    key: u64,
    /// What it says.
    text: []const u8,
};

/// A row of a table the cursor is on. The owner reads its cells itself, through its pass.
pub const AtRow = struct {
    /// The table block's key.
    key: u64,
    /// The source's name, as the text writes it.
    source: []const u8,
    /// The publisher's table, as the layout's reader saw it.
    table: *Table,
    /// The row.
    row: Table.RowHandle,
    /// In a group's table, its group: which changelist a file is in, without reading its key
    /// cell again. Null in a table block.
    group: ?Group = null,
};

/// What `cursor`, settled against `page`, is on. Its texts and table are the layout's.
pub fn at(page: Layout, cursor: Cursor) At {
    if (page.stops == 0) return .none;
    const settled = settle(page, cursor);
    const place = placeOf(page, settled.index);
    const block = blockAt(page, place.position);
    switch (block.kind) {
        .heading => {
            if (block.group) |group| return .{ .group = group };
            const table: ?TableBlock = if (block.only_table) |index| page.blocks[index].table else null;
            return .{ .heading = .{
                .key = block.key,
                .text = block.text,
                .source = if (table) |found| found.source else null,
                .table = if (table) |found| found.table else null,
            } };
        },
        .table => {
            const table = block.table.?;
            const row = table.rowAtPlace(place.row) orelse return .none;
            return .{ .row = .{ .key = block.key, .source = table.source, .table = table.table, .row = row, .group = block.group } };
        },
        .paragraph, .term, .text, .unpublished => return .{ .text = .{ .key = block.key, .text = block.text } },
        // Never shown, so never under the cursor.
        .group => return .none,
    }
}

// ---- what the owner calls in its kernel -------------------------------------------------------

/// The cursor moved by `way` and the view scrolled to show it, kept in `state`: what the owner's
/// key for `way` does.
pub fn step(page: Layout, state: StateRow, way: Step) void {
    const view_height = state.document_view_height.*;
    var moved = move(page, cursorOf(state), way, view_height);
    moved.scroll = scrollTo(page, moved, view_height);
    setCursor(state, moved);
}

/// How `settleView` treats the scroll.
pub const Follow = enum {
    /// Kept as it is (a wheel's), within the page, unless settling moved the cursor, which it
    /// then shows.
    keep,
    /// Moved to show the cursor: after a key moved it, or the view was resized.
    cursor,
};

/// Brings `state`'s cursor up to date with `page` (`settle`) and keeps the scroll as `follow`
/// says, at the end of a run of the owner's kernel; and logs, once each time what is missing
/// changes, the columns named that their sources do not show and the group keys they lack.
pub fn settleView(page: Layout, state: StateRow, follow: Follow) void {
    const view_height = state.document_view_height.*;
    const stored = cursorOf(state);
    var settled = settle(page, stored);
    const moved = settled.block != stored.block or settled.row != stored.row;
    settled.scroll = if (follow == .cursor or moved) scrollTo(page, settled, view_height) else clampScroll(page, settled.scroll, view_height);
    setCursor(state, settled);
    warnMissing(page, state);
}

fn warnMissing(page: Layout, state: StateRow) void {
    var hasher = std.hash.Wyhash.init(0);
    for (page.missing) |missing| {
        hasher.update(&.{@intFromEnum(missing.kind)});
        hasher.update(missing.source);
        hasher.update(&.{0});
        hasher.update(missing.column);
        hasher.update(&.{0});
    }
    const fingerprint = if (page.missing.len == 0) 0 else hasher.final();
    if (fingerprint == state.document_warned.*) return;
    state.document_warned.* = fingerprint;
    for (page.missing) |missing| switch (missing.kind) {
        .column => Log.warn("column_not_shown", .{ .source = missing.source, .column = missing.column }),
        .key => Log.warn("group_key_missing", .{ .source = missing.source, .field = missing.column }),
    };
}

/// The heading the cursor is on, or under, folded or opened in `folds`, the owner's table of
/// folds: what TAB does. Its key; null on a page with no heading over the cursor. The page is
/// then laid out again.
pub fn toggle(page: Layout, cursor: Cursor, folds: sequencer.Rows(FoldRow)) !?u64 {
    if (page.stops == 0) return null;
    const settled = settle(page, cursor);
    const on_page = placeOf(page, settled.index).position;
    const block = blockAt(page, on_page);
    const heading_stop = if (block.kind == .heading) block.first_stop else headingBefore(page, on_page, .any) orelse return null;
    const heading = blockAt(page, placeOf(page, heading_stop).position);
    try toggleKey(folds, heading.key);
    return heading.key;
}

/// Every heading folded, or, when all are, every one opened: what S-TAB does.
pub fn toggleAll(page: Layout, folds: sequencer.Rows(FoldRow)) !void {
    var any_open = false;
    for (page.blocks) |block| {
        if (block.kind == .heading and !block.folded) any_open = true;
    }
    for (page.blocks) |block| {
        if (block.kind != .heading) continue;
        const folded = findFold(folds, block.key);
        if (any_open and folded == null) _ = try folds.insert(.{ .key = block.key });
        if (!any_open) if (folded) |handle| folds.free(handle);
    }
}

fn toggleKey(folds: sequencer.Rows(FoldRow), key: u64) !void {
    if (findFold(folds, key)) |handle| return folds.free(handle);
    _ = try folds.insert(.{ .key = key });
}

fn findFold(folds: sequencer.Rows(FoldRow), key: u64) ?Table.RowHandle {
    var rows = folds.read();
    while (rows.next()) |row| {
        if (row.view.key.* == key) return row.handle;
    }
    return null;
}

/// Frees the rows of `folds`, the owner's table of folds, whose heading the page no longer has,
/// as when its words changed or its group is gone: what ends a run of the owner's kernel. While
/// a group block's groups are not known (`Layout.unknown_groups`: a source of its not published
/// or `unread`, or one lacking the block's `:key` field), no fold of its groups is freed, so a
/// refresh that failed unfolds no changelist; a publisher whose refresh failed therefore keeps
/// its rows and marks its source `unread` (drawn in the error colour), and does not empty it,
/// which says there are no groups and lets their folds go. One pass over the folds. `folds` is
/// `page`'s document's alone: the folds of another document's headings in it would be freed
/// too.
pub fn pruneFolds(page: Layout, folds: sequencer.Rows(FoldRow)) !void {
    const table = folds.table;
    var row: u32 = 0;
    while (row < table.rowCapacity()) : (row += 1) {
        if (!table.isAllocated(row)) continue;
        const handle: Table.RowHandle = .{ .row = row, .generation = table.rowGeneration(row) };
        const fold = table.readRow(handle, FoldRow) orelse continue;
        const key = fold.key.*;
        if (holdsHeading(page, key)) continue;
        if (ofUnknownGroups(page, key)) continue;
        folds.free(handle);
    }
}

fn ofUnknownGroups(page: Layout, key: u64) bool {
    for (page.unknown_groups) |block| {
        if (ofGroupBlock(key, block)) return true;
    }
    return false;
}

fn holdsHeading(page: Layout, key: u64) bool {
    for (page.blocks) |block| {
        if (block.key == key and block.kind == .heading) return true;
    }
    return false;
}

/// The cursor on the row `handle` of the table block `block_key`, unscrolled: where the owner
/// puts it to keep it on the same thing across a refresh that rewrote the rows. The owner finds
/// the row by a cell it remembered of the row `at` gave, gives the cursor the scroll it keeps,
/// and stores it (`setCursor`); `settle` puts it on that row while the page shows it, and as for
/// a row gone when it does not.
pub fn cursorOnRow(page: Layout, block_key: u64, handle: Table.RowHandle) Cursor {
    var cursor: Cursor = .{ .block = block_key, .row_id = handle.row, .row_generation = handle.generation };
    const index = indexOfKey(page, block_key) orelse return cursor;
    const block = page.blocks[index];
    const table = block.table orelse return cursor;
    const position = table.placeOfRow(handle) orelse return cursor;
    cursor.row = position;
    if (block.shown and position < block.stops) cursor.index = block.first_stop + position;
    return cursor;
}

/// The cursor, unscrolled, on the group whose key cell reads `key_text` of the group block
/// `block_key` (`Group.block`): on the row `row` of its table, when given and in it, else on its
/// heading; null when the page has no such group. Where the owner puts it to keep it on "this
/// file in this changelist" across a refresh that wrote both sources again: it remembers the
/// `Group.block` and `Group.key_text` `at` gave and a cell naming the row, finds the row holding
/// that cell after the refresh, and calls this, then gives the cursor its scroll and stores it,
/// as for `cursorOnRow`. On null (the changelist was submitted or deleted) it settles the cursor
/// it had instead, which lands where the group's heading was (`Cursor.landing`): on the group
/// that took its place, or the stop after the groups.
pub fn cursorOnGroup(page: Layout, block_key: u64, key_text: []const u8, row: ?Table.RowHandle) ?Cursor {
    const heading = for (page.blocks) |block| {
        const group = block.group orelse continue;
        if (block.kind != .heading or group.block != block_key) continue;
        if (std.mem.eql(u8, group.key_text, key_text)) break block;
    } else return null;
    var on_heading: Cursor = .{ .block = heading.key };
    if (heading.shown) on_heading.index = heading.first_stop;
    const handle = row orelse return on_heading;
    for (page.blocks) |block| {
        const group = block.group orelse continue;
        if (block.kind != .table or group.key != heading.key) continue;
        const table = block.table.?;
        if (table.placeOfRow(handle) == null) return on_heading;
        return cursorOnRow(page, block.key, handle);
    }
    return on_heading;
}

// ---- input ------------------------------------------------------------------------------------

/// The tags the owner names its page's messages by, each its own in its inbox.
pub const Tags = struct {
    /// A click on a heading or a line: the cursor goes there.
    click: Atom,
    /// A click on a heading's fold mark: it folds or opens.
    toggle: Atom,
    /// The wheel over the page: it scrolls.
    wheel: Atom,
};

/// What a click on the page or its wheel carries as its user data: which page, which block, which
/// row. A table's rows' clicks are the grid's (`ui.grid.CellClick`), whose instance names the
/// page's block and the chunk of its rows the row is drawn in (`instanceOf`).
pub const Click = extern struct {
    /// The page's document, as the owner names it to `take` and `view.record`.
    document: Atom,
    /// The block's key; 0 for the wheel.
    block: u64 = 0,
    /// The row in it; 0 but in a table.
    row: u32 = 0,
    /// Nothing: keeps the bytes defined.
    unused: u32 = 0,
};

/// How many of a table block's rows one grid draws: a block's rows are drawn in chunks of so
/// many, each a grid of its own (`ui.grid.max_visible_rows`).
pub const rows_a_chunk: u32 = grid.max_visible_rows;

/// The grid instance the chunk `chunk` (rows `chunk * rows_a_chunk` on) of a table block is drawn
/// as, in the document `document`: what its rows' clicks carry.
pub fn instanceOf(document: Atom, key: u64, chunk: u32) Atom {
    const named: [2]u64 = .{ key, chunk };
    const hashed = std.hash.Wyhash.hash(document.value(), std.mem.asBytes(&named));
    const nonzero = if (hashed == 0) 1 else hashed;
    return @enumFromInt(nonzero);
}

/// What the owner names its page by, for `take`.
pub const Input = struct {
    /// The document's name, as `view.record` was given it: tells apart two pages of one owner.
    document: Atom,
    /// The page's tags.
    tags: Tags,
};

/// What `take` made of a message.
pub const Outcome = union(enum) {
    /// Not one of this page's.
    ignored,
    /// The cursor went where a click was, and the view shows it.
    moved,
    /// A heading was folded or opened: its key. The owner lays the page out again.
    toggled: u64,
    /// The view scrolled, and the cursor kept in it.
    scrolled,
    /// A click on what the cursor is already on: the owner acts on it, as on RET.
    chosen: At,
};

/// How far a notch of the wheel scrolls, in lines.
const wheel_lines: f32 = 3;

/// Takes `received`, a message to the owner's inbox, when it is one of this page's: a click on a
/// heading or a line, or on a table's row (`ui.grid.Msg.cell_click`), puts the cursor there; a
/// click on a fold mark folds or opens the heading in `folds`; the wheel scrolls. Writes `state`
/// and `folds`; reads the tables `page` was laid out from.
pub fn take(received: sequencer.Message, page: Layout, state: StateRow, folds: sequencer.Rows(FoldRow), page_input: Input) !Outcome {
    const tags = page_input.tags;
    if (received.tag == tags.click) {
        const click = try received.userDataAs(Click);
        if (click.document != page_input.document) return .ignored;
        const index = indexOfKey(page, click.block) orelse return .ignored;
        const block = page.blocks[index];
        if (!block.shown or click.row >= block.stops) return .ignored;
        return placeCursor(page, state, block.first_stop + click.row);
    }
    if (received.tag == tags.toggle) {
        const click = try received.userDataAs(Click);
        if (click.document != page_input.document) return .ignored;
        const index = indexOfKey(page, click.block) orelse return .ignored;
        if (page.blocks[index].kind != .heading) return .ignored;
        try toggleKey(folds, click.block);
        return .{ .toggled = click.block };
    }
    if (received.tag == tags.wheel) {
        const click = try received.userDataAs(Click);
        if (click.document != page_input.document) return .ignored;
        const scrolled = try received.payloadAs(input.MouseScrollMsg);
        const view_height = state.document_view_height.*;
        var cursor = settle(page, cursorOf(state));
        const wanted = cursor.scroll - scrolled.y * wheel_lines * page.line_height;
        cursor.scroll = clampScroll(page, wanted, view_height);
        setCursor(state, cursorInView(page, cursor, view_height));
        return .scrolled;
    }
    if (received.tag == Atom.from(grid.Msg.cell_click)) {
        const click = try received.userDataAs(grid.CellClick);
        for (page.shown) |index| {
            const block = page.blocks[index];
            const table = block.table orelse continue;
            if (click.row >= table.table.rowCapacity()) continue;
            const handle: Table.RowHandle = .{ .row = click.row, .generation = table.table.rowGeneration(click.row) };
            const position = table.placeOfRow(handle) orelse continue;
            const chunk = position / rows_a_chunk;
            if (instanceOf(page_input.document, block.key, chunk) != click.instance) continue;
            if (position >= table.rows) return .ignored;
            return placeCursor(page, state, block.first_stop + position);
        }
        return .ignored;
    }
    return .ignored;
}

/// The cursor put on `stop` by a click, or what it is on chosen when it is there already.
fn placeCursor(page: Layout, state: StateRow, stop: u32) Outcome {
    const stored = settle(page, cursorOf(state));
    if (stored.index == stop) return .{ .chosen = at(page, stored) };
    var placed = cursorAtStop(page, stop, stored.scroll);
    placed.scroll = scrollTo(page, placed, state.document_view_height.*);
    setCursor(state, placed);
    return .moved;
}
