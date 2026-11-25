//! Tests of a document's page (`document.zig`) and its drawing (`view.zig`), over tables made
//! in the test's registry and published through `sources.zig`, the document the vcs-git one
//! (`editor/assets/documents/vcs-git.org`). A small owner, a system of one kernel over a state
//! table and a table of folds, runs the page as a panel's owner would.
const std = @import("std");
const mesha = @import("mesha");
const Atom = mesha.Atom;
const Table = mesha.Table;
const memory_mod = mesha.memory;
const plugin = mesha.plugin;
const sequencer = mesha.sequencer;
const input = mesha.input;
const ui = mesha.ui;
const grid = ui.grid;
const editor_sequencer = @import("../editor_sequencer.zig");
const panel_frame = @import("../panel_frame.zig");
const style = @import("../ui/style.zig");
const document = @import("document.zig");
const view = @import("view.zig");
const sources = @import("sources.zig");
const testing = std.testing;

const vcs_git_text = @embedFile("vcs_git_document");
const publisher = Atom.from("document_test_publisher");
const document_name = Atom.from("document_test_page");
const tags: document.Tags = .{ .click = Atom.from("document_test_click"), .toggle = Atom.from("document_test_toggle"), .wheel = Atom.from("document_test_wheel") };
const page_input: document.Input = .{ .document = document_name, .tags = tags };
const metrics: document.Metrics = .{ .line_height = 21 };

// The owner's tables.
const state_name = "document_test_state";
const folds_name = "document_test_folds";
const resize_reader_name = "document_test_resizes";
const panel_name = "document_test_panel";

/// The tables of the vcs-git document's sources, the values, and the owner's tables.
const Bench = struct {
    memory: memory_mod.Memory = undefined,
    atoms: Atom.Registry = undefined,
    tables: Table.Registry = undefined,
    arena: std.heap.ArenaAllocator = undefined,

    fn init(bench: *Bench) !void {
        bench.memory.init(testing.allocator);
        try bench.atoms.init(&bench.memory);
        try bench.tables.init(&bench.memory, 32);
        bench.arena = std.heap.ArenaAllocator.init(testing.allocator);
        const scratch = try bench.memory.tableScratchAllocator();
        try sources.ensure(scratch, &bench.atoms, &bench.tables);
        try bench.atoms.tryInternAll(&.{ state_name, folds_name, resize_reader_name, panel_name });
        try bench.atoms.tryInternAll(&view.element_names);

        var state_schema: Table.Schema = undefined;
        try state_schema.init(scratch.allocator, &bench.atoms, std.meta.fields(document.StateRow).len);
        defer state_schema.deinit();
        try document.addStateFields(&state_schema);
        _ = try bench.tables.ensureSingleton(&state_schema, Atom.from(state_name), document.initial_state, .durable);

        var folds_schema: Table.Schema = undefined;
        try folds_schema.init(scratch.allocator, &bench.atoms, 1);
        defer folds_schema.deinit();
        try document.addFoldFields(&folds_schema);
        _ = try bench.tables.ensure(&folds_schema, 8, Atom.from(folds_name), .durable);
    }

    fn deinit(bench: *Bench) void {
        bench.arena.deinit();
        bench.tables.deinit();
        bench.atoms.deinit();
        bench.memory.deinit();
    }

    fn allocator(bench: *Bench) std.mem.Allocator {
        return bench.arena.allocator();
    }

    /// A publisher's table `name` of text fields `fields`, its rows `rows`, each field of row `n`
    /// holding the field's name and `n` (`path-3`), published as the source `source`, every field
    /// but the last for showing when `last_is_data`.
    fn source(bench: *Bench, source_name: []const u8, table_name: []const u8, fields: []const []const u8, rows: u32, data: Data) !*Table {
        const scratch = try bench.memory.tableScratchAllocator();
        var schema: Table.Schema = undefined;
        try schema.init(scratch.allocator, &bench.atoms, fields.len);
        defer schema.deinit();
        for (fields) |field| try schema.addFieldFallible(field, Table.String, .text_field);
        const name = bench.atoms.intern(table_name);
        const table = (try bench.tables.ensure(&schema, @max(rows, 4), name, .durable)).table;
        for (0..rows) |row| try bench.insertRow(table, fields, @intCast(row));
        const shown = if (data == .last_is_data) fields[0 .. fields.len - 1] else fields;
        bench.publishing().publishSource(publisher, .{ .name = source_name, .table = name, .shown = shown });
        return table;
    }

    fn insertRow(bench: *Bench, table: *Table, fields: []const []const u8, row: u32) !void {
        const handle = try table.alloc();
        for (fields) |field| {
            const text = try std.fmt.allocPrint(bench.allocator(), "{s}-{d}", .{ field, row });
            try table.setString(handle, field, text);
        }
    }

    /// The document component's two tables, as a publisher's pass gives them.
    fn publishing(bench: *Bench) sources.Publishing {
        const sources_table = bench.tables.findByName(Atom.from(sources.sources_table_name)).?;
        const values_table = bench.tables.findByName(Atom.from(sources.values_table_name)).?;
        return .{ .sources = sources_table, .values = values_table, .memory = &bench.memory };
    }

    fn value(bench: *Bench, name: []const u8, text: []const u8) void {
        bench.publishing().publishValue(publisher, name, text);
    }

    /// The vcs-git document's sources: two untracked files, five unstaged, none staged; the
    /// unmerged and the commits not published; the head's values but no operation.
    fn vcsGit(bench: *Bench) !VcsGit {
        bench.value("vcs-git.branch", "main");
        bench.value("vcs-git.head-subject", "Fix the frame");
        bench.value("vcs-git.upstream", "origin/main");
        bench.value("vcs-git.ahead-behind", "+1");
        // The counts the headings say, as vcs-git publishes them: the files counted.
        bench.value("vcs-git.untracked-count", "2");
        bench.value("vcs-git.unstaged-count", "5");
        bench.value("vcs-git.staged-count", "0");
        return .{
            .untracked = try bench.source("vcs-git.untracked", "document_test_untracked", &.{"path"}, 2, .all_shown),
            .unstaged = try bench.source("vcs-git.unstaged", "document_test_unstaged", &.{ "change", "path", "letters" }, 5, .last_is_data),
            .staged = try bench.source("vcs-git.staged", "document_test_staged", &.{ "change", "path" }, 0, .all_shown),
        };
    }

    /// What a draw reads the page through.
    fn drawTables(bench: *Bench) document.DrawTables {
        return .{ .tables = &bench.tables, .atoms = &bench.atoms };
    }

    fn state(bench: *Bench) document.StateRow {
        const table = bench.tables.findByName(Atom.from(state_name)).?;
        return table.getRow(.{ .row = 0, .generation = table.rowGeneration(0) }, document.StateRow).?;
    }

    fn folds(bench: *Bench) sequencer.Rows(document.FoldRow) {
        return .of(bench.tables.findByName(Atom.from(folds_name)).?);
    }

    /// The vcs-git document laid out over what is published, with the folds the bench keeps.
    fn page(bench: *Bench) !document.Layout {
        return bench.pageOf(vcs_git_text);
    }

    /// The document `text` laid out over what is published, with the folds the bench keeps.
    fn pageOf(bench: *Bench, text: []const u8) !document.Layout {
        const parsed = try document.parse(bench.allocator(), text);
        const published = try document.publishedIn(bench.allocator(), bench.drawTables(), parsed);
        const folded = try document.foldedKeys(bench.allocator(), bench.folds().read());
        return document.layout(bench.allocator(), parsed, published, folded, metrics);
    }
};

const Data = enum { all_shown, last_is_data };

const VcsGit = struct { untracked: *Table, unstaged: *Table, staged: *Table };

/// The shown heading of `page` whose text begins `text`.
fn headingNamed(page: document.Layout, text: []const u8) document.Block {
    for (page.shown) |index| {
        const block = page.blocks[index];
        if (block.kind == .heading and std.mem.startsWith(u8, block.text, text)) return block;
    }
    std.debug.panic("no heading {s}", .{text});
}

/// The cursor on the heading `text`, settled.
fn onHeading(page: document.Layout, text: []const u8) document.Cursor {
    const heading = headingNamed(page, text);
    return document.settle(page, .{ .block = heading.key, .index = heading.first_stop });
}

/// The cursor on row `row` of the table block of `source`.
fn onRow(page: document.Layout, source: []const u8, row: u32) document.Cursor {
    for (page.shown) |index| {
        const block = page.blocks[index];
        const table = block.table orelse continue;
        if (!std.mem.eql(u8, table.source, source)) continue;
        const handle = document.rowAt(table.table, row).?;
        return .{ .block = block.key, .row = row, .row_id = handle.row, .row_generation = handle.generation, .index = block.first_stop + row };
    }
    std.debug.panic("no table {s}", .{source});
}

fn expectRow(at: document.At, source: []const u8, row: u32) !void {
    try testing.expect(at == .row);
    try testing.expectEqualStrings(source, at.row.source);
    try testing.expectEqual(row, at.row.row.row);
}

fn expectHeading(at: document.At, text: []const u8) !void {
    try testing.expect(at == .heading);
    try testing.expectEqualStrings(text, at.heading.text);
}

test "document: the vcs-git document over sources of 2, 0 and 5 rows lays out without the empty one's heading" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    _ = try bench.vcsGit();
    const page = try bench.page();
    try testing.expectEqualStrings("vcs-git", page.title);
    try testing.expectEqual(@as(?u32, 5), page.refresh);

    var shown: std.ArrayList([]const u8) = .empty;
    for (page.shown) |index| try shown.append(bench.allocator(), page.blocks[index].text);
    const expected = [_][]const u8{
        "Head",
        "Upstream",
        "Untracked files (2)",
        "vcs-git.untracked",
        "Unmerged ()",
        "(vcs-git.unmerged is not published)",
        "Unstaged changes (5)",
        "vcs-git.unstaged",
        "Recent commits",
        "(vcs-git.commits is not published)",
    };
    try testing.expectEqual(expected.len, shown.items.len);
    for (expected, shown.items) |want, got| try testing.expectEqualStrings(want, got);
    // The terms say their values; the operation, published as nothing, is left out.
    try testing.expectEqualStrings("main  Fix the frame", page.blocks[page.shown[0]].detail);
    // Two terms, four headings, two lines not published, and a stop a row.
    try testing.expectEqual(@as(u32, 2 + 4 + 2 + 2 + 5), page.stops);
    const untracked = page.blocks[page.shown[3]];
    try testing.expectEqual(untracked.top, headingNamed(page, "Untracked").top + metrics.line_height);
    try testing.expectEqual(grid.inlineHeight(2, document.table_presentation), untracked.height);
    try testing.expectEqual(page.height, page.blocks[page.shown[9]].top + metrics.line_height);
    // Unstaged changes shows its change and path, not its data.
    const unstaged = headingNamed(page, "Unstaged");
    const unstaged_table = page.blocks[unstaged.only_table.?].table.?;
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, unstaged_table.columns);
}

test "document: move next goes from a heading to its table's first row, and from its last row to the next heading" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    _ = try bench.vcsGit();
    const page = try bench.page();
    const on_untracked = onHeading(page, "Untracked");
    const into = document.move(page, on_untracked, .next, 400);
    try expectRow(document.at(page, into), "vcs-git.untracked", 0);
    const last_row = onRow(page, "vcs-git.untracked", 1);
    const out = document.move(page, last_row, .next, 400);
    try expectHeading(document.at(page, out), "Unmerged ()");
    const back = document.move(page, out, .previous, 400);
    try expectRow(document.at(page, back), "vcs-git.untracked", 1);
    // The parent of a row is its heading.
    try expectHeading(document.at(page, document.move(page, last_row, .parent, 400)), "Untracked files (2)");
}

test "document: next_heading skips a table, and previous_heading comes back" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    _ = try bench.vcsGit();
    const page = try bench.page();
    const on_untracked = onHeading(page, "Untracked");
    const next = document.move(page, on_untracked, .next_heading, 400);
    try expectHeading(document.at(page, next), "Unmerged ()");
    const from_row = onRow(page, "vcs-git.unstaged", 3);
    try expectHeading(document.at(page, document.move(page, from_row, .previous_heading, 400)), "Unstaged changes (5)");
    try expectHeading(document.at(page, document.move(page, from_row, .next_heading, 400)), "Recent commits");
}

test "document: folding a heading leaves out its table, and the cursor on a row inside lands on the heading" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    _ = try bench.vcsGit();
    const page = try bench.page();
    const on_row = onRow(page, "vcs-git.unstaged", 3);
    const key = try document.toggle(page, on_row, bench.folds());
    try testing.expectEqual(headingNamed(page, "Unstaged").key, key.?);
    const folded = try bench.page();
    const heading = headingNamed(folded, "Unstaged");
    try testing.expect(heading.folded);
    try testing.expect(!folded.blocks[indexOfSource(folded, "vcs-git.unstaged")].shown);
    try testing.expectEqual(page.stops - 5, folded.stops);
    const on_folded = document.at(folded, document.settle(folded, on_row));
    try expectHeading(on_folded, "Unstaged changes (5)");
    // Folded, the heading still names the table its section holds.
    try testing.expectEqualStrings("vcs-git.unstaged", on_folded.heading.source.?);
    // Opened again, the table is back under it.
    _ = try document.toggle(folded, document.settle(folded, on_row), bench.folds());
    try testing.expectEqual(page.stops, (try bench.page()).stops);
}

fn indexOfSource(page: document.Layout, source: []const u8) usize {
    for (page.blocks, 0..) |block, index| {
        if (block.kind == .table and std.mem.eql(u8, block.text, source)) return index;
    }
    std.debug.panic("no table {s}", .{source});
}

test "document: a row removed under the cursor leaves the cursor on the row that took its place, and at gives its source and handle" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    const vcs = try bench.vcsGit();
    const page = try bench.page();
    const on_row = onRow(page, "vcs-git.unstaged", 2);
    const at_row = document.at(page, on_row);
    try expectRow(at_row, "vcs-git.unstaged", 2);
    try testing.expectEqual(vcs.unstaged, at_row.row.table);
    try testing.expectEqual(vcs.unstaged.rowGeneration(2), at_row.row.row.generation);
    // A heading whose content is one table names that table's source.
    const at_heading = document.at(page, onHeading(page, "Unstaged"));
    try testing.expectEqualStrings("vcs-git.unstaged", at_heading.heading.source.?);
    try testing.expect(document.at(page, onHeading(page, "Recent")).heading.source == null);

    // The row the cursor is on goes: the row after it takes its place.
    vcs.unstaged.free(at_row.row.row);
    const after = try bench.page();
    const settled = document.settle(after, on_row);
    try expectRow(document.at(after, settled), "vcs-git.unstaged", 3);
    try testing.expectEqual(@as(u32, 2), settled.row);
    // A row added above it: the cursor stays on its row.
    try bench.insertRow(vcs.unstaged, &.{ "change", "path", "letters" }, 9);
    const grown = try bench.page();
    try expectRow(document.at(grown, document.settle(grown, settled)), "vcs-git.unstaged", 3);
    // Its last rows go: the cursor is on the last row there is.
    for (1..6) |row| {
        const handle = document.rowAt(vcs.unstaged, 1) orelse break;
        _ = row;
        vcs.unstaged.free(handle);
    }
    const shrunk = try bench.page();
    const on_last = document.settle(shrunk, settled);
    try expectRow(document.at(shrunk, on_last), "vcs-git.unstaged", 0);
    // Every row goes: the table and its heading are left out, and the cursor is on the block
    // before them, the line saying the unmerged are not published.
    vcs.unstaged.free(document.rowAt(vcs.unstaged, 0).?);
    const emptied = try bench.page();
    const before = document.at(emptied, document.settle(emptied, on_last));
    try testing.expect(before == .text);
    try testing.expectEqualStrings("(vcs-git.unmerged is not published)", before.text.text);
}

test "document: {{{count(src)}}} shows the row count, and changes when the table does" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    const vcs = try bench.vcsGit();
    const text =
        \\* Untracked files ({{{count(vcs-git.untracked)}}})
        \\#+BEGIN: table :source vcs-git.untracked :columns "path"
        \\#+END:
        \\* Staged changes ({{{count(vcs-git.staged)}}})
        \\#+BEGIN: table :source vcs-git.staged :columns "change path"
        \\#+END:
    ;
    try testing.expectEqualStrings("Untracked files (2)", headingNamed(try bench.pageOf(text), "Untracked").text);
    try bench.insertRow(vcs.untracked, &.{"path"}, 2);
    const page = try bench.pageOf(text);
    try testing.expectEqualStrings("Untracked files (3)", headingNamed(page, "Untracked").text);
    try testing.expectEqual(@as(u32, 3), page.blocks[indexOfSource(page, "vcs-git.untracked")].stops);
    // The staged, given a row, are shown under their heading.
    try bench.insertRow(vcs.staged, &.{ "change", "path" }, 0);
    try testing.expectEqualStrings("Staged changes (1)", headingNamed(try bench.pageOf(text), "Staged").text);
}

test "document: scrollTo, clampScroll and cursorInView keep the cursor and the view together" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    _ = try bench.vcsGit();
    const page = try bench.page();
    const view_height: f32 = 100;
    var cursor = onRow(page, "vcs-git.unstaged", 4);
    cursor.scroll = scrolled: {
        const scroll = document.scrollTo(page, cursor, view_height);
        break :scrolled scroll;
    };
    const unstaged = page.blocks[indexOfSource(page, "vcs-git.unstaged")];
    const row_bottom = unstaged.top + document.table_header_height + 5 * document.table_row_height;
    try testing.expectEqual(row_bottom - view_height, cursor.scroll);
    // A table's first row is shown with its header.
    const first = onRow(page, "vcs-git.unstaged", 0);
    try testing.expectEqual(unstaged.top, document.scrollTo(page, .{ .block = first.block, .index = first.index, .scroll = 1000 }, view_height));
    try testing.expectEqual(@as(f32, 0), document.clampScroll(page, -40, view_height));
    try testing.expectEqual(page.height - view_height, document.clampScroll(page, 1e6, view_height));
    // The view scrolled to the top: the cursor comes up to the last stop wholly in view.
    cursor.scroll = 0;
    const followed = document.cursorInView(page, cursor, view_height);
    try testing.expect(followed.index < cursor.index);
    try testing.expectEqual(@as(f32, 0), followed.scroll);
    // A page moves the view's height.
    const paged = document.move(page, onHeading(page, "Untracked"), .page_down, view_height);
    try testing.expect(paged.index > onHeading(page, "Untracked").index + 1);
}

/// The texts `tree` records whose text begins `prefix`.
fn textsBeginning(tree: *const ui.Tree, prefix: []const u8, into: *std.ArrayList([]const u8), allocator: std.mem.Allocator) !void {
    for (tree.elements[0..tree.count]) |element| {
        const text = switch (element) {
            .text => |text| text.str,
            else => continue,
        };
        if (std.mem.startsWith(u8, text, prefix)) try into.append(allocator, text);
    }
}

test "document: record over a source of 100,000 rows in a 20-line view stays within elementCount and asks the grid for the rows in view" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    _ = try bench.vcsGit();
    // The untracked files grow to 100,000; the document shows them all.
    const untracked = bench.tables.findByName(Atom.from("document_test_untracked")).?;
    var row: u32 = 2;
    while (row < 100_000) : (row += 1) {
        const handle = try untracked.alloc();
        try untracked.setString(handle, "path", "file");
    }
    const page = try bench.page();
    const view_height = 20 * metrics.line_height;
    const block = page.blocks[indexOfSource(page, "vcs-git.untracked")];
    try testing.expectEqual(@as(u32, 100_000), block.stops);
    // The cursor on the 50,000th row, the view scrolled to show it.
    var cursor = onRow(page, "vcs-git.untracked", 50_000);
    cursor.scroll = document.scrollTo(page, cursor, view_height);

    const scratch: memory_mod.Scratch = .{ .allocator = bench.allocator() };
    const capacity = view.elementCount(view_height, metrics);
    var tree = try ui.Tree.init(scratch, &bench.atoms, capacity);
    view.record(&tree, page, cursor, .{
        .inbox = Atom.from("document_test_inbox"),
        .document = document_name,
        .tags = tags,
        .view_width = 800,
        .view_height = view_height,
        .scratch = scratch,
        .style = style.documentStyle(),
    });
    try tree.validateCommands();
    try testing.expect(tree.count <= capacity);
    // The rows the grid drew are those in view: the page's view over the rows, and no more.
    var drawn: std.ArrayList([]const u8) = .empty;
    try textsBeginning(&tree, "file", &drawn, bench.allocator());
    const rows_top = block.top + document.table_header_height;
    const first_in_view: u32 = @intFromFloat(@floor((cursor.scroll - rows_top) / document.table_row_height));
    const last_in_view: u32 = @intFromFloat(@ceil((cursor.scroll + view_height - rows_top) / document.table_row_height));
    try testing.expectEqual(last_in_view - first_in_view, @as(u32, @intCast(drawn.items.len)));
    try testing.expect(drawn.items.len <= 16);
    // The cursor's row is drawn selected, in the grid's selected fill.
    try testing.expect(holdsFill(&tree, style.documentStyle().grid.selected_bg));
}

test "document: a table its publisher could not read draws its selected row on the error selection, so its text reads" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    _ = try bench.vcsGit();
    bench.publishing().setSourceState(publisher, "vcs-git.untracked", .unread);
    const page = try bench.page();
    const cursor = onRow(page, "vcs-git.untracked", 0);
    const scratch: memory_mod.Scratch = .{ .allocator = bench.allocator() };
    const view_height = 20 * metrics.line_height;
    var tree = try ui.Tree.init(scratch, &bench.atoms, view.elementCount(view_height, metrics));
    const look = style.documentStyle();
    view.record(&tree, page, cursor, .{
        .inbox = Atom.from("document_test_inbox"),
        .document = document_name,
        .tags = tags,
        .view_width = 800,
        .view_height = view_height,
        .scratch = scratch,
        .style = look,
    });
    try testing.expect(holdsFill(&tree, look.error_selection));
    try testing.expect(!holdsFill(&tree, look.grid.selected_bg));
}

/// Whether some rect of `tree` is filled `colour`.
fn holdsFill(tree: *const ui.Tree, colour: ui.Color) bool {
    for (tree.elements[0..tree.count]) |element| {
        const params = switch (element) {
            .open_rect, .rect => |params| params,
            else => continue,
        };
        const fill = params.bg orelse continue;
        if (std.meta.eql(fill, colour)) return true;
    }
    return false;
}

/// A message to the owner as the tree's click on a region would deliver it.
fn clickMessage(tag: Atom, data: anytype) sequencer.Message {
    return .{ .tag = tag, .user_data = std.mem.asBytes(data) };
}

test "document: a click on a table's row puts the cursor there, a second chooses it, and a fold mark folds" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    _ = try bench.vcsGit();
    var page = try bench.page();
    const state = bench.state();
    state.document_view_height.* = 400;
    const block = page.blocks[indexOfSource(page, "vcs-git.unstaged")];
    const cell: grid.CellClick = .{ .instance = document.instanceOf(document_name, block.key, 0), .row = 3, .field = 1 };
    const message = clickMessage(Atom.from(grid.Msg.cell_click), &cell);
    try testing.expectEqual(document.Outcome.moved, try document.take(message, page, state, bench.folds(), page_input));
    try expectRow(document.at(page, document.cursorOf(state)), "vcs-git.unstaged", 3);
    const again = try document.take(message, page, state, bench.folds(), page_input);
    try expectRow(again.chosen, "vcs-git.unstaged", 3);
    // Another page's click is not this one's.
    const elsewhere: grid.CellClick = .{ .instance = document.instanceOf(Atom.from("other_page"), block.key, 0), .row = 1, .field = 1 };
    try testing.expectEqual(document.Outcome.ignored, try document.take(clickMessage(Atom.from(grid.Msg.cell_click), &elsewhere), page, state, bench.folds(), page_input));

    // A click on a heading, then on its fold mark.
    const heading = headingNamed(page, "Untracked");
    const on_heading: document.Click = .{ .document = document_name, .block = heading.key };
    try testing.expectEqual(document.Outcome.moved, try document.take(clickMessage(tags.click, &on_heading), page, state, bench.folds(), page_input));
    try expectHeading(document.at(page, document.cursorOf(state)), "Untracked files (2)");
    const toggled = try document.take(clickMessage(tags.toggle, &on_heading), page, state, bench.folds(), page_input);
    try testing.expectEqual(heading.key, toggled.toggled);
    page = try bench.page();
    try testing.expect(headingNamed(page, "Untracked").folded);

    // The wheel scrolls three lines a notch down, and the cursor stays in view.
    state.document_view_height.* = 60;
    const wheel_data: document.Click = .{ .document = document_name };
    const notch: input.MouseScrollMsg = .{ .x = 0, .y = -1 };
    var wheel = clickMessage(tags.wheel, &wheel_data);
    wheel.payload = std.mem.asBytes(&notch);
    try testing.expectEqual(document.Outcome.scrolled, try document.take(wheel, page, state, bench.folds(), page_input));
    try testing.expectEqual(3 * metrics.line_height, state.document_scroll.*);
    const cursor = document.cursorOf(state);
    try testing.expect(page.blocks[page.shown[0]].top + 3 * metrics.line_height <= blockTopOf(page, cursor));
}

fn blockTopOf(page: document.Layout, cursor: document.Cursor) f32 {
    for (page.blocks) |block| {
        if (block.key == cursor.block) return block.top;
    }
    unreachable;
}

test "document: a column named that its source does not show is left out and warned of once" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    _ = try bench.vcsGit();
    // The staged publish only their path: the document's `change` is not there.
    _ = try bench.source("vcs-git.staged", "document_test_staged_paths", &.{"path"}, 1, .all_shown);
    const page = try bench.page();
    try testing.expectEqual(@as(usize, 1), page.missing.len);
    try testing.expectEqualStrings("change", page.missing[0].column);
    const state = bench.state();
    document.settleView(page, state, .keep);
    const warned = state.document_warned.*;
    try testing.expect(warned != 0);
    document.settleView(page, state, .keep);
    try testing.expectEqual(warned, state.document_warned.*);
    const staged = page.blocks[indexOfSource(page, "vcs-git.staged")].table.?;
    try testing.expectEqualSlices(u32, &.{0}, staged.columns);
}

// ---- a small owner ----------------------------------------------------------------------------

/// A system that owns a page of the vcs-git document in a panel: each run it takes the size its
/// panel was told, lays the page out, takes its messages and settles its view.
fn ownerSystem() sequencer.System {
    return .{
        .name = "document_test_owner",
        .names = &.{ resize_reader_name, state_name, folds_name, panel_name },
        .root = Atom.from("document_test_owner"),
        .claims = sequencer.claims_nothing,
        .access = ownerAccess,
        .kernels = &.{.{ .name = "document_test_owner.keep", .run = ownerKeep }},
    };
}

fn ownerAccess(frame: *const sequencer.Frame) sequencer.Access {
    var access: sequencer.Access = .{};
    access.writeAll(&.{ Atom.from(state_name), Atom.from(folds_name) });
    const scratch = frame.memory.frameScratchAllocator() catch return access;
    const parsed = document.parse(scratch.allocator, vcs_git_text) catch return access;
    document.declareAccess(&access, frame.tables, parsed);
    plugin.panels.Events.declare(&access, frame.tables, plugin.panels.events_table_name);
    return access;
}

fn ownerKeep(pass: *sequencer.Pass) !void {
    const arena = (try pass.frame.memory.frameScratchAllocator()).allocator;
    const state = try pass.writeSingleton(Atom.from(state_name), document.StateRow);
    const folds = try pass.writeRows(Atom.from(folds_name), document.FoldRow);
    const resized = try document.followResizes(pass, Atom.from(resize_reader_name), Atom.from(panel_name), state);
    const parsed = try document.parse(arena, vcs_git_text);
    const published = try document.publishedIn(arena, pass, parsed);
    const folded = try document.foldedKeys(arena, folds.read());
    var page = try document.layout(arena, parsed, published, folded, metrics);
    for (pass.frame.messages) |received| {
        const outcome = try document.take(received, page, state, folds, page_input);
        if (outcome == .toggled) page = try document.layout(arena, parsed, published, try document.foldedKeys(arena, folds.read()), metrics);
    }
    document.settleView(page, state, if (resized) .cursor else .keep);
    try document.pruneFolds(page, folds);
}

fn runOwner(bench: *Bench) !void {
    const solo = sequencer.Solo.of("document_test", ownerSystem());
    const scratch = try bench.memory.tableScratchAllocator();
    try sequencer.ensureInboxes(scratch, &bench.atoms, &bench.tables, &solo.sequencer());
    editor_sequencer.run(&bench.memory, &bench.atoms, &bench.tables, &solo.sequencer(), null);
    bench.tables.reclaimPayloads();
}

test "document: a resized event's run lays the page out again for the new size" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    const scratch = try bench.memory.tableScratchAllocator();
    try sequencer.ensure(scratch, &bench.atoms, &bench.tables);
    try mesha.panels.ensure(scratch, &bench.atoms, &bench.tables);
    try plugin.panels.Events.ensure(scratch, &bench.atoms, &bench.tables, plugin.panels.events_table_name);
    _ = try bench.vcsGit();
    const events = plugin.panels.Events.of(&bench.tables, plugin.panels.events_table_name);
    const panel = Atom.from(panel_name);

    // Told a tall panel first, the page fits it: the cursor on the last row, nothing scrolled.
    events.publish(.{ .resized = .{ .panel = panel, .frame_width = 800, .frame_height = 900 } });
    try runOwner(&bench);
    const state = bench.state();
    const tall = panel_frame.contentSize(&bench.tables, &bench.atoms, .{ .panel = panel, .frame_width = 800, .frame_height = 900 });
    try testing.expectEqual(tall.height, state.document_view_height.*);
    const page = try bench.page();
    const last = onRow(page, "vcs-git.unstaged", 4);
    document.setCursor(state, last);
    try runOwner(&bench);
    try testing.expectEqual(@as(f32, 0), state.document_scroll.*);

    // Told it is short, the run lays the page out for that size and scrolls the cursor into it.
    events.publish(.{ .resized = .{ .panel = panel, .frame_width = 800, .frame_height = 160 } });
    try runOwner(&bench);
    const short = panel_frame.contentSize(&bench.tables, &bench.atoms, .{ .panel = panel, .frame_width = 800, .frame_height = 160 });
    try testing.expectEqual(short.height, state.document_view_height.*);
    try testing.expectEqual(short.width, state.document_view_width.*);
    const expected = document.scrollTo(page, .{ .block = last.block, .row = 4, .index = last.index }, short.height);
    try testing.expect(expected > 0);
    try testing.expectEqual(expected, state.document_scroll.*);
}

// ---- what the page looks like ------------------------------------------------------------------

test "document: the vcs-git page records its headings with fold marks, its terms aligned in two columns and its tables under their headers" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    _ = try bench.vcsGit();
    const page = try bench.page();
    const view_height: f32 = 600;
    const cursor = onRow(page, "vcs-git.unstaged", 1);
    const scratch: memory_mod.Scratch = .{ .allocator = bench.allocator() };
    var tree = try ui.Tree.init(scratch, &bench.atoms, view.elementCount(view_height, metrics));
    view.record(&tree, page, cursor, .{
        .inbox = Atom.from("document_test_inbox"),
        .document = document_name,
        .tags = tags,
        .view_width = 800,
        .view_height = view_height,
        .scratch = scratch,
        .style = style.documentStyle(),
    });
    try tree.validateCommands();
    var texts: std.ArrayList([]const u8) = .empty;
    try textsBeginning(&tree, "", &texts, bench.allocator());
    // Headings without stars, the empty one absent; tables' columns by name, their data not;
    // rows; the unpublished named.
    const wanted = [_][]const u8{ "Head", "Upstream", "main  Fix the frame", "origin/main  +1", "Untracked files (2)", "path", "path-0", "path-1", "Unmerged ()", "(vcs-git.unmerged is not published)", "Unstaged changes (5)", "change", "change-4", "path-4", "Recent commits" };
    for (wanted) |text| {
        const found = for (texts.items) |drawn| {
            if (std.mem.eql(u8, drawn, text)) break true;
        } else false;
        if (!found) std.debug.print("not drawn: {s}\n", .{text});
        try testing.expect(found);
    }
    for (texts.items) |drawn| {
        try testing.expect(!std.mem.startsWith(u8, drawn, "Staged"));
        try testing.expect(!std.mem.startsWith(u8, drawn, "letters"));
        try testing.expect(!std.mem.startsWith(u8, drawn, "*"));
    }
    // Each heading has its fold mark, a custom element; the terms are one piece of two columns.
    var marks: u32 = 0;
    for (tree.elements[0..tree.count]) |element| {
        if (element == .custom) marks += 1;
    }
    try testing.expectEqual(@as(u32, 4), marks);
    try testing.expect(holdsFill(&tree, style.documentStyle().grid.selected_bg));
    try dumpTree(&bench, &tree, page, "MESHA_DOCUMENT_DUMP");
}

/// Writes `page` and what `tree` recorded of it, element by element, to the file the
/// environment's variable `variable` names, when it names one: a page to read against the
/// design's.
fn dumpTree(bench: *Bench, tree: *const ui.Tree, page: document.Layout, variable: []const u8) !void {
    var environment = try testing.environ.createMap(testing.allocator);
    defer environment.deinit();
    const path = environment.get(variable) orelse return;
    const allocator = bench.allocator();
    var out: std.ArrayList(u8) = .empty;
    try out.print(allocator, "page: {d} blocks shown, {d} stops, {d:.0} px tall\n", .{ page.shown.len, page.stops, page.height });
    for (page.shown) |index| {
        const block = page.blocks[index];
        try out.print(allocator, "  {s:<12} top {d:>5.0} height {d:>4.0} depth {d} stops {d:>2}  {s}", .{ @tagName(block.kind), block.top, block.height, block.depth, block.stops, block.text });
        if (block.detail.len != 0) try out.print(allocator, " :: {s}", .{block.detail});
        if (block.folded) try out.appendSlice(allocator, " (folded)");
        try out.append(allocator, '\n');
    }
    try out.print(allocator, "\ntree: {d} elements\n", .{tree.count});
    var depth: usize = 0;
    const highlight = style.documentStyle().outline.highlight;
    const selected = style.documentStyle().grid.selected_bg;
    for (tree.elements[0..tree.count]) |element| {
        switch (element) {
            .close_rect => {
                depth -|= 1;
                continue;
            },
            else => {},
        }
        try out.appendNTimes(allocator, ' ', depth * 2);
        switch (element) {
            .open_rect, .rect => |params| {
                const name = tree.lookupId(params.id) orelse "?";
                try out.print(allocator, "{s} {s} {s} x {s}", .{ if (element == .open_rect) "[" else "-", name, dimText(allocator, params.size.w), dimText(allocator, params.size.h) });
                if (params.bg) |fill| {
                    if (std.meta.eql(fill, highlight)) try out.appendSlice(allocator, " CURSOR");
                    if (std.meta.eql(fill, selected)) try out.appendSlice(allocator, " SELECTED");
                }
                if (params.on_click != null) try out.appendSlice(allocator, " click");
                try out.append(allocator, '\n');
                if (element == .open_rect) depth += 1;
            },
            .custom => |custom| try out.print(allocator, "- mark {s} x {s}\n", .{ dimText(allocator, custom.params.size.w), dimText(allocator, custom.params.size.h) }),
            .text => |text| try out.print(allocator, "\"{s}\"\n", .{text.str}),
            .cursor, .close_rect => {},
        }
    }
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = out.items });
}

fn dimText(allocator: std.mem.Allocator, dim: ui.Dim) []const u8 {
    return switch (dim) {
        .fixed => |pixels| std.fmt.allocPrint(allocator, "{d:.0}", .{pixels}) catch "?",
        .fill => "fill",
        .hug => "hug",
    };
}

// ---- fix round 1 -------------------------------------------------------------------------------

fn recordPage(bench: *Bench, page: document.Layout, cursor: document.Cursor, view_height: f32) !ui.Tree {
    const scratch: memory_mod.Scratch = .{ .allocator = bench.allocator() };
    var tree = try ui.Tree.init(scratch, &bench.atoms, view.elementCount(view_height, metrics));
    view.record(&tree, page, cursor, .{
        .inbox = Atom.from("document_test_inbox"),
        .document = document_name,
        .tags = tags,
        .view_width = 800,
        .view_height = view_height,
        .scratch = scratch,
        .style = style.documentStyle(),
    });
    try tree.validateCommands();
    return tree;
}

test "document: a table's columns are drawn in the order its :columns names them" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    _ = try bench.vcsGit();
    const text =
        \\* Unstaged
        \\#+BEGIN: table :source vcs-git.unstaged :columns "path change"
        \\#+END:
    ;
    const page = try bench.pageOf(text);
    const table = page.blocks[indexOfSource(page, "vcs-git.unstaged")].table.?;
    try testing.expectEqualSlices(u32, &.{ 1, 0 }, table.columns);
    const tree = try recordPage(&bench, page, onHeading(page, "Unstaged"), 400);
    var drawn: std.ArrayList([]const u8) = .empty;
    try textsBeginning(&tree, "", &drawn, bench.allocator());
    // The header, then the first row, each path before change.
    try testing.expectEqualStrings("path", drawn.items[1]);
    try testing.expectEqualStrings("change", drawn.items[2]);
    try testing.expectEqualStrings("path-0", drawn.items[3]);
    try testing.expectEqualStrings("change-0", drawn.items[4]);

    // A name given again is drawn once, where it was first named.
    const repeated =
        \\* Unstaged
        \\#+BEGIN: table :source vcs-git.unstaged :columns "path change path"
        \\#+END:
    ;
    const once = try bench.pageOf(repeated);
    const once_table = once.blocks[indexOfSource(once, "vcs-git.unstaged")].table.?;
    try testing.expectEqualSlices(u32, &.{ 1, 0 }, once_table.columns);
}

test "document: a term whose text its macros leave blank is left out, as a paragraph is" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    _ = try bench.vcsGit();
    const text =
        \\- Here :: {{{vcs-git.branch}}}
        \\- Gone :: {{{nobody.published}}}  {{{nor.this}}}
    ;
    const page = try bench.pageOf(text);
    try testing.expectEqual(@as(usize, 2), page.blocks.len);
    try testing.expect(page.blocks[0].shown);
    try testing.expect(!page.blocks[1].shown);
    try testing.expectEqual(@as(u32, 1), page.stops);
}

test "document: a view taller than a grid's rows draws every row in it, and a click past the 64th puts the cursor there" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    _ = try bench.vcsGit();
    const untracked = bench.tables.findByName(Atom.from("document_test_untracked")).?;
    var row: u32 = 2;
    while (row < 150) : (row += 1) try bench.insertRow(untracked, &.{"path"}, row);
    const page = try bench.page();
    const view_height: f32 = 120 * document.table_row_height;
    const cursor = onHeading(page, "Untracked");
    const tree = try recordPage(&bench, page, cursor, view_height);
    try testing.expect(tree.count <= view.elementCount(view_height, metrics));
    var drawn: std.ArrayList([]const u8) = .empty;
    try textsBeginning(&tree, "path-", &drawn, bench.allocator());
    const block = page.blocks[indexOfSource(page, "vcs-git.untracked")];
    const rows_top = block.top + document.table_header_height;
    const in_view: u32 = @intFromFloat(@ceil((view_height - rows_top) / document.table_row_height));
    try testing.expect(in_view > grid.max_visible_rows);
    try testing.expectEqual(in_view, @as(u32, @intCast(drawn.items.len)));
    try testing.expectEqualStrings("path-100", drawn.items[100]);

    const state = bench.state();
    state.document_view_height.* = view_height;
    const cell: grid.CellClick = .{ .instance = document.instanceOf(document_name, block.key, 1), .row = 100, .field = 0 };
    try testing.expectEqual(document.Outcome.moved, try document.take(clickMessage(Atom.from(grid.Msg.cell_click), &cell), page, state, bench.folds(), page_input));
    try expectRow(document.at(page, document.cursorOf(state)), "vcs-git.untracked", 100);
    // The same row's click as if drawn in the first chunk is no row of this page's.
    const misplaced: grid.CellClick = .{ .instance = document.instanceOf(document_name, block.key, 0), .row = 100, .field = 0 };
    try testing.expectEqual(document.Outcome.ignored, try document.take(clickMessage(Atom.from(grid.Msg.cell_click), &misplaced), page, state, bench.folds(), page_input));
}

test "document: a heading whose only table is empty keeps while a sub-heading under it shows" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    _ = try bench.vcsGit();
    const text =
        \\* Parent
        \\#+BEGIN: table :source vcs-git.staged
        \\#+END:
        \\** Child
        \\#+BEGIN: table :source vcs-git.untracked
        \\#+END:
        \\* Empty
        \\#+BEGIN: table :source vcs-git.staged
        \\#+END:
        \\** Empty child
        \\#+BEGIN: table :source vcs-git.staged
        \\#+END:
    ;
    const page = try bench.pageOf(text);
    var headings: std.ArrayList([]const u8) = .empty;
    for (page.shown) |index| {
        const block = page.blocks[index];
        if (block.kind == .heading) try headings.append(bench.allocator(), block.text);
    }
    try testing.expectEqual(@as(usize, 2), headings.items.len);
    try testing.expectEqualStrings("Parent", headings.items[0]);
    try testing.expectEqualStrings("Child", headings.items[1]);
}

test "document: the cursor is put back on the same row after its rows were written again, and folds of headings gone are pruned" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    const vcs = try bench.vcsGit();
    const page = try bench.page();
    const before = document.at(page, onRow(page, "vcs-git.unstaged", 1));
    const remembered = try bench.allocator().dupe(u8, vcs.unstaged.readRow(before.row.row, struct { path: []const u8 }).?.path);
    // The publisher writes its rows again, the same files with one more before them.
    while (document.rowAt(vcs.unstaged, 0)) |handle| vcs.unstaged.free(handle);
    try bench.insertRow(vcs.unstaged, &.{ "change", "path", "letters" }, 9);
    for (0..5) |row| try bench.insertRow(vcs.unstaged, &.{ "change", "path", "letters" }, @intCast(row));
    const after = try bench.page();
    var found: ?Table.RowHandle = null;
    var rows = vcs.unstaged.readQuery(struct { path: []const u8 });
    while (rows.next()) |entry| {
        if (std.mem.eql(u8, entry.view.path, remembered)) found = entry.handle;
    }
    const put = document.cursorOnRow(after, before.row.key, found.?);
    const settled = document.settle(after, put);
    const at = document.at(after, settled);
    try testing.expectEqual(found.?, at.row.row);
    try testing.expectEqualStrings("path-1", vcs.unstaged.readRow(at.row.row, struct { path: []const u8 }).?.path);
    // Not where it was: the rows came back in another order.
    try testing.expect(settled.row != 1);

    const folds = bench.folds();
    _ = try folds.insert(.{ .key = @as(u64, 12345) });
    _ = try folds.insert(.{ .key = headingNamed(after, "Unstaged").key });
    try document.pruneFolds(after, folds);
    const kept = try document.foldedKeys(bench.allocator(), folds.read());
    try testing.expectEqualSlices(u64, &.{headingNamed(after, "Unstaged").key}, kept);
}

test "document: only the sources a document names are declared and read" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    _ = try bench.vcsGit();
    _ = try bench.source("other.thing", "document_test_other", &.{"name"}, 3, .all_shown);
    const parsed = try document.parse(bench.allocator(), vcs_git_text);
    var access: sequencer.Access = .{};
    document.declareAccess(&access, &bench.tables, parsed);
    const other = Atom.from("document_test_other");
    try testing.expect(std.mem.indexOfScalar(Atom, access.reads[0..access.read_count], other) == null);
    try testing.expect(std.mem.indexOfScalar(Atom, access.reads[0..access.read_count], Atom.from("document_test_unstaged")) != null);
    const published = try document.publishedIn(bench.allocator(), bench.drawTables(), parsed);
    try testing.expectEqual(@as(usize, 3), published.sources.len);
}

/// A stand-in measure: ten pixels a byte.
fn tenPixelsAByte(context: *const anyopaque, font: Atom, text: []const u8) f32 {
    _ = context;
    _ = font;
    return @floatFromInt(text.len * 10);
}

test "document: :fill names the column that takes the rest, the others fit to what they hold, and an unknown :fill is text" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    _ = try bench.vcsGit();
    const text =
        \\* Filled by change
        \\#+BEGIN: table :source vcs-git.unstaged :columns "change path" :fill change
        \\#+END:
        \\* Filled by the last
        \\#+BEGIN: table :source vcs-git.untracked :columns "path"
        \\#+END:
        \\* Not a table
        \\#+BEGIN: table :source vcs-git.unstaged :columns "change path" :fill letters
        \\#+END:
    ;
    const page = try bench.pageOf(text);
    const unstaged = page.blocks[indexOfSource(page, "vcs-git.unstaged")].table.?;
    try testing.expectEqual(@as(u32, 0), unstaged.fill);
    const untracked = page.blocks[indexOfSource(page, "vcs-git.untracked")].table.?;
    try testing.expectEqual(untracked.columns[untracked.columns.len - 1], untracked.fill);
    var texts: usize = 0;
    for (page.blocks) |block| {
        if (block.kind == .text) texts += 1;
    }
    // Its two lines, `#+BEGIN:` and `#+END:`.
    try testing.expectEqual(@as(usize, 2), texts);

    // Drawn with a measure: path fits `path-4`, change fills, the same in every row.
    const scratch: memory_mod.Scratch = .{ .allocator = bench.allocator() };
    var tree = try ui.Tree.init(scratch, &bench.atoms, view.elementCount(600, metrics));
    var measured: u8 = 0;
    view.record(&tree, page, onHeading(page, "Filled by change"), .{
        .inbox = Atom.from("document_test_inbox"),
        .document = document_name,
        .tags = tags,
        .view_width = 800,
        .view_height = 600,
        .scratch = scratch,
        .style = style.documentStyle(),
        .measure = .{ .context = &measured, .width_fn = tenPixelsAByte },
    });
    const block = page.blocks[indexOfSource(page, "vcs-git.unstaged")];
    const instance = document.instanceOf(document_name, block.key, 0);
    const path_cell = rectOf(&tree, grid.elementId(instance, "table.cell", 0, 1)).?;
    try testing.expectEqual(ui.Dim{ .fixed = 6 * 10 + 16 }, path_cell.size.w);
    try testing.expectEqual(ui.Dim.fill, rectOf(&tree, grid.elementId(instance, "table.cell", 0, 0)).?.size.w);
    try testing.expectEqual(path_cell.size.w, rectOf(&tree, grid.elementId(instance, "table.cell", 4, 1)).?.size.w);
}

/// The parameters of the rect `id` records in `tree`; null for none.
fn rectOf(tree: *const ui.Tree, id: ui.ElementId) ?ui.RectParams {
    for (tree.elements[0..tree.count]) |element| switch (element) {
        .open_rect => |params| if (std.meta.eql(params.id, id)) return params,
        else => {},
    };
    return null;
}

// ---- groups ------------------------------------------------------------------------------------

/// A changelist of the groups' fixture: its number, a number cell, and its description.
const Changelist = struct { change: u32, description: []const u8 };
/// A file opened in a changelist: its changelist's number, a text cell, its action and path.
const Opened = struct { change: []const u8, action: []const u8, path: []const u8 };

const changelists_table = "document_test_changelists";
const opened_table = "document_test_opened";

/// The groups' page: a plain heading over a group block of a heading a changelist, its files
/// under it.
const groups_text =
    \\* Pending changelists
    \\#+BEGIN: group :by p4.changelists :key change :source p4.opened :columns "action path"
    \\** Change {{{change}}}  {{{description}}} ({{{count()}}})
    \\#+END:
    \\* After
;

/// Two changelists, the first with two files and the second with none, and a file of a
/// changelist not listed.
const two_changelists = [_]Changelist{ .{ .change = 1234, .description = "Fix the frame" }, .{ .change = 1240, .description = "Docs" } };
const files_of_the_first = [_]Opened{
    .{ .change = "1234", .action = "edit", .path = "a.zig" },
    .{ .change = "999", .action = "edit", .path = "elsewhere.zig" },
    .{ .change = "1234", .action = "add", .path = "b.zig" },
};

/// Publishes `changes` as `p4.changelists`, its `change` a number, and `files` as `p4.opened`,
/// its `change` text: the two compare as the grid shows them.
fn publishGroups(bench: *Bench, changes: []const Changelist, files: []const Opened) !GroupTables {
    const scratch = try bench.memory.tableScratchAllocator();
    var changes_schema: Table.Schema = undefined;
    try changes_schema.init(scratch.allocator, &bench.atoms, 2);
    defer changes_schema.deinit();
    try changes_schema.addFieldFallible("change", u32, .int);
    try changes_schema.addFieldFallible("description", Table.String, .text_field);
    const changes_name = bench.atoms.intern(changelists_table);
    const by = (try bench.tables.ensure(&changes_schema, 16, changes_name, .durable)).table;
    for (changes) |change| try insertChangelist(by, change);
    bench.publishing().publishSource(publisher, .{ .name = "p4.changelists", .table = changes_name, .shown = &.{ "change", "description" } });

    var files_schema: Table.Schema = undefined;
    try files_schema.init(scratch.allocator, &bench.atoms, 3);
    defer files_schema.deinit();
    for ([_][]const u8{ "change", "action", "path" }) |field| try files_schema.addFieldFallible(field, Table.String, .text_field);
    const files_name = bench.atoms.intern(opened_table);
    const opened = (try bench.tables.ensure(&files_schema, 16, files_name, .durable)).table;
    for (files) |file| try insertOpened(opened, file);
    bench.publishing().publishSource(publisher, .{ .name = "p4.opened", .table = files_name, .shown = &.{ "change", "action", "path" } });
    return .{ .changelists = by, .opened = opened };
}

const GroupTables = struct { changelists: *Table, opened: *Table };

fn insertChangelist(table: *Table, change: Changelist) !void {
    const handle = try table.tryInsert(.{ .change = change.change, .description = Table.String{} });
    try table.setString(handle, "description", change.description);
}

fn insertOpened(table: *Table, file: Opened) !void {
    const handle = try table.alloc();
    try table.setString(handle, "change", file.change);
    try table.setString(handle, "action", file.action);
    try table.setString(handle, "path", file.path);
}

/// The texts of `page`'s shown blocks, in page order, each a heading's with its dim note after
/// a space.
fn shownTexts(bench: *Bench, page: document.Layout) ![]const []const u8 {
    var texts: std.ArrayList([]const u8) = .empty;
    for (page.shown) |index| {
        const block = page.blocks[index];
        const text = if (block.detail.len != 0) try std.fmt.allocPrint(bench.allocator(), "{s} {s}", .{ block.text, block.detail }) else block.text;
        try texts.append(bench.allocator(), text);
    }
    return texts.items;
}

fn expectTexts(expected: []const []const u8, got: []const []const u8) !void {
    for (expected, 0..) |want, index| {
        if (index >= got.len or !std.mem.eql(u8, want, got[index])) {
            std.debug.print("block {d}: wanted {s}\n", .{ index, want });
            for (got) |text| std.debug.print("  got {s}\n", .{text});
        }
    }
    try testing.expectEqual(expected.len, got.len);
    for (expected, got) |want, text| try testing.expectEqualStrings(want, text);
}

/// The shown table block of the group whose key cell reads `key_text`.
fn groupTable(page: document.Layout, key_text: []const u8) document.Block {
    for (page.shown) |index| {
        const block = page.blocks[index];
        if (block.kind != .table) continue;
        const group = block.group orelse continue;
        if (std.mem.eql(u8, group.key_text, key_text)) return block;
    }
    std.debug.panic("no group table {s}", .{key_text});
}

/// The path cell of `handle`'s row of the opened files.
fn pathOf(tables: GroupTables, handle: Table.RowHandle) []const u8 {
    return tables.opened.readRow(handle, struct { path: []const u8 }).?.path;
}

test "document: two changelists with 2 and 0 files give two headings, the first over a two-row table, the second (empty)" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    const tables = try publishGroups(&bench, &two_changelists, &files_of_the_first);
    const page = try bench.pageOf(groups_text);
    try expectTexts(&.{ "Pending changelists", "Change 1234  Fix the frame (2)", "p4.opened", "Change 1240  Docs (0) (empty)", "After" }, try shownTexts(&bench, page));
    const first = headingNamed(page, "Change 1234");
    try testing.expectEqual(@as(u8, 2), first.level);
    try testing.expectEqual(@as(u8, 1), first.depth);
    const table_block = groupTable(page, "1234");
    try testing.expectEqual(@as(u32, 2), table_block.stops);
    try testing.expectEqual(@as(u8, 2), table_block.depth);
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, table_block.table.?.columns);
    // Its rows are the first's two files, in the table's order: not the other changelist's.
    try testing.expectEqualStrings("a.zig", pathOf(tables, table_block.table.?.rowAtPlace(0).?));
    try testing.expectEqualStrings("b.zig", pathOf(tables, table_block.table.?.rowAtPlace(1).?));
    try testing.expect(table_block.table.?.rowAtPlace(2) == null);
    // The second is a heading with no table, said dim: one stop.
    const second = headingNamed(page, "Change 1240");
    try testing.expectEqualStrings("(empty)", second.detail);
    try testing.expectEqual(@as(u32, 1 + 1 + 2 + 1 + 1), page.stops);
}

test "document: folding a changelist leaves the other as it was, and a refresh that reorders them keeps each one's fold" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    const files = files_of_the_first ++ [_]Opened{.{ .change = "1240", .action = "delete", .path = "c.zig" }};
    const tables = try publishGroups(&bench, &two_changelists, &files);
    const page = try bench.pageOf(groups_text);
    const key = try document.toggle(page, onHeading(page, "Change 1234"), bench.folds());
    try testing.expectEqual(headingNamed(page, "Change 1234").key, key.?);
    const folded = try bench.pageOf(groups_text);
    try expectTexts(&.{ "Pending changelists", "Change 1234  Fix the frame (2)", "Change 1240  Docs (1)", "p4.opened", "After" }, try shownTexts(&bench, folded));
    try testing.expect(headingNamed(folded, "Change 1234").folded);
    try testing.expect(!headingNamed(folded, "Change 1240").folded);
    try testing.expectEqual(page.stops - 2, folded.stops);

    // The publisher writes its changelists again in another order: 1234 after 1240.
    tables.changelists.free(document.rowAt(tables.changelists, 0).?);
    try insertChangelist(tables.changelists, .{ .change = 1250, .description = "New" });
    try insertChangelist(tables.changelists, .{ .change = 1234, .description = "Fix the frame" });
    const reordered = try bench.pageOf(groups_text);
    const texts = try shownTexts(&bench, reordered);
    const at_1234 = for (texts, 0..) |text, index| {
        if (std.mem.startsWith(u8, text, "Change 1234")) break index;
    } else unreachable;
    const at_1240 = for (texts, 0..) |text, index| {
        if (std.mem.startsWith(u8, text, "Change 1240")) break index;
    } else unreachable;
    try testing.expect(at_1240 < at_1234);
    try testing.expect(headingNamed(reordered, "Change 1234").folded);
    try testing.expect(!headingNamed(reordered, "Change 1240").folded);
    try testing.expect(!headingNamed(reordered, "Change 1250").folded);
    // The fold is of a heading still there: pruning keeps it.
    try document.pruneFolds(reordered, bench.folds());
    try testing.expectEqual(@as(usize, 1), (try document.foldedKeys(bench.allocator(), bench.folds().read())).len);
    // Each group's keys are its key cell's, wherever it is: the table's too.
    try testing.expectEqual(groupTable(page, "1240").key, groupTable(reordered, "1240").key);
}

test "document: at on a group's heading gives its row of the :by source, on its row which group, and next_heading goes group to group" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    const tables = try publishGroups(&bench, &two_changelists, &files_of_the_first);
    const page = try bench.pageOf(groups_text);
    const on_first = onHeading(page, "Change 1234");
    const at_first = document.at(page, on_first);
    try testing.expect(at_first == .group);
    const group = at_first.group;
    try testing.expectEqual(headingNamed(page, "Change 1234").key, group.key);
    try testing.expectEqualStrings("p4.changelists", group.by_source);
    try testing.expectEqual(tables.changelists, group.by_table);
    try testing.expectEqual(@as(u32, 1234), tables.changelists.readRow(group.by_row, struct { change: *u32 }).?.change.*);
    try testing.expectEqualStrings("p4.opened", group.source);
    try testing.expectEqual(tables.opened, group.table);
    try testing.expectEqualStrings("1234", group.key_text);
    try testing.expectEqualStrings("Change 1234  Fix the frame (2)", group.text);

    // Into its table: a row, and which group it is in.
    const on_row = document.move(page, document.move(page, on_first, .next, 400), .next, 400);
    const at_row = document.at(page, on_row);
    try testing.expect(at_row == .row);
    try testing.expectEqualStrings("b.zig", pathOf(tables, at_row.row.row));
    try testing.expectEqual(group.key, at_row.row.group.?.key);
    try testing.expectEqual(group.by_row, at_row.row.group.?.by_row);
    try testing.expectEqual(groupTable(page, "1234").key, at_row.row.key);

    // Heading to heading: the first group, the second, then the heading after the block.
    const next = document.move(page, on_first, .next_heading, 400);
    try testing.expectEqualStrings("1240", document.at(page, next).group.key_text);
    try expectHeading(document.at(page, document.move(page, next, .next_heading, 400)), "After");
    try testing.expectEqualStrings("1234", document.at(page, document.move(page, next, .previous_heading, 400)).group.key_text);
    // The parent of a group is the heading above the block.
    try expectHeading(document.at(page, document.move(page, next, .parent, 400)), "Pending changelists");
    // A plain heading is still a heading: it names no group.
    try expectHeading(document.at(page, onHeading(page, "Pending")), "Pending changelists");
}

test "document: a group block with no heading line inside is shown as text" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    _ = try publishGroups(&bench, &two_changelists, &files_of_the_first);
    const text =
        \\#+BEGIN: group :by p4.changelists :key change :source p4.opened :columns "action path"
        \\#+END:
    ;
    const page = try bench.pageOf(text);
    try expectTexts(&.{ "#+BEGIN: group :by p4.changelists :key change :source p4.opened :columns \"action path\"", "#+END:" }, try shownTexts(&bench, page));
}

test "document: a group's heading names the group row's fields, a published value when the row has no such field, and count() is its own rows" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    _ = try publishGroups(&bench, &two_changelists, &files_of_the_first);
    bench.value("p4.note", "shelved");
    const text =
        \\#+BEGIN: group :by p4.changelists :key change :source p4.opened :columns "path"
        \\* {{{change}}} [{{{p4.note}}}] [{{{nobody}}}] {{{count()}}} of {{{count(p4.opened)}}}
        \\#+END:
    ;
    const page = try bench.pageOf(text);
    try expectTexts(&.{ "1234 [shelved] [] 2 of 3", "p4.opened", "1240 [shelved] [] 0 of 3 (empty)" }, try shownTexts(&bench, page));
}

test "document: a :key field one source lacks shows one dim line saying which, warned of once" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    _ = try publishGroups(&bench, &two_changelists, &files_of_the_first);
    const text =
        \\* Pending
        \\#+BEGIN: group :by p4.changelists :key path :source p4.opened :columns "path"
        \\** {{{change}}}
        \\#+END:
        \\* Unpublished
        \\#+BEGIN: group :by p4.nothing :key change :source p4.opened :columns "path"
        \\** {{{change}}}
        \\#+END:
    ;
    const page = try bench.pageOf(text);
    try expectTexts(&.{ "Pending", "(p4.changelists has no field path)", "Unpublished", "(p4.nothing is not published)" }, try shownTexts(&bench, page));
    try testing.expectEqual(document.Kind.unpublished, page.blocks[page.shown[1]].kind);
    try testing.expectEqual(@as(usize, 1), page.missing.len);
    try testing.expectEqual(document.MissingKind.key, page.missing[0].kind);
    const state = bench.state();
    document.settleView(page, state, .keep);
    const warned = state.document_warned.*;
    try testing.expect(warned != 0);
    document.settleView(page, state, .keep);
    try testing.expectEqual(warned, state.document_warned.*);
}

test "document: a plain heading over a group block of no groups is left out, and kept over one empty group" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    const tables = try publishGroups(&bench, &.{}, &files_of_the_first);
    try expectTexts(&.{"After"}, try shownTexts(&bench, try bench.pageOf(groups_text)));
    try insertChangelist(tables.changelists, .{ .change = 77, .description = "Nothing yet" });
    try expectTexts(&.{ "Pending changelists", "Change 77  Nothing yet (0) (empty)", "After" }, try shownTexts(&bench, try bench.pageOf(groups_text)));
}

test "document: cursorOnGroup puts the cursor on a group's heading, or on a row of its table, after a refresh rewrote both sources" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    const files = files_of_the_first ++ [_]Opened{.{ .change = "1240", .action = "delete", .path = "c.zig" }};
    const tables = try publishGroups(&bench, &two_changelists, &files);
    const page = try bench.pageOf(groups_text);
    // The owner remembers what the cursor is on: b.zig, in changelist 1234.
    const on_b = document.at(page, document.settle(page, onGroupRow(page, "1234", 1)));
    const block = on_b.row.group.?.block;
    const changelist = try bench.allocator().dupe(u8, on_b.row.group.?.key_text);
    const path = try bench.allocator().dupe(u8, pathOf(tables, on_b.row.row));
    try testing.expectEqualStrings("b.zig", path);

    // The publisher writes every row again: another changelist first, the files in another order.
    while (document.rowAt(tables.changelists, 0)) |handle| tables.changelists.free(handle);
    while (document.rowAt(tables.opened, 0)) |handle| tables.opened.free(handle);
    try insertChangelist(tables.changelists, .{ .change = 1300, .description = "Newer" });
    for (two_changelists) |change| try insertChangelist(tables.changelists, change);
    var index = files.len;
    while (index > 0) {
        index -= 1;
        try insertOpened(tables.opened, files[index]);
    }
    const after = try bench.pageOf(groups_text);
    var found: ?Table.RowHandle = null;
    var rows = tables.opened.readQuery(struct { path: []const u8 });
    while (rows.next()) |row| {
        if (std.mem.eql(u8, row.view.path, path)) found = row.handle;
    }
    const put = document.settle(after, document.cursorOnGroup(after, block, changelist, found.?).?);
    const at = document.at(after, put);
    try testing.expectEqualStrings("b.zig", pathOf(tables, at.row.row));
    try testing.expectEqualStrings("1234", at.row.group.?.key_text);
    // On the heading of 1240: no row given.
    const heading = document.at(after, document.settle(after, document.cursorOnGroup(after, block, "1240", null).?));
    try testing.expectEqualStrings("1240", heading.group.key_text);
    // A row of no group of that key: its heading.
    const elsewhere = document.at(after, document.settle(after, document.cursorOnGroup(after, block, "1300", found.?).?));
    try testing.expectEqualStrings("1300", elsewhere.group.key_text);
}

/// The cursor on place `place` of the table of the group whose key cell reads `key_text`.
fn onGroupRow(page: document.Layout, key_text: []const u8, place: u32) document.Cursor {
    const block = groupTable(page, key_text);
    const handle = block.table.?.rowAtPlace(place).?;
    return .{ .block = block.key, .row = place, .row_id = handle.row, .row_generation = handle.generation, .index = block.first_stop + place };
}

test "document: a click on a group's row puts the cursor on that row of that group, and two groups' tables over one source share no element id" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    const files = files_of_the_first ++ [_]Opened{.{ .change = "1240", .action = "delete", .path = "c.zig" }};
    const tables = try publishGroups(&bench, &two_changelists, &files);
    const page = try bench.pageOf(groups_text);
    const state = bench.state();
    state.document_view_height.* = 400;
    const first = groupTable(page, "1234");
    const b_row = first.table.?.rowAtPlace(1).?;
    const cell: grid.CellClick = .{ .instance = document.instanceOf(document_name, first.key, 0), .row = b_row.row, .field = 2 };
    try testing.expectEqual(document.Outcome.moved, try document.take(clickMessage(Atom.from(grid.Msg.cell_click), &cell), page, state, bench.folds(), page_input));
    const at = document.at(page, document.cursorOf(state));
    try testing.expectEqualStrings("b.zig", pathOf(tables, at.row.row));
    try testing.expectEqualStrings("1234", at.row.group.?.key_text);
    try testing.expectEqual(first.first_stop + 1, document.cursorOf(state).index);
    // The same row's click as if the other group's table drew it is no row of this page's.
    const second = groupTable(page, "1240");
    const misplaced: grid.CellClick = .{ .instance = document.instanceOf(document_name, second.key, 0), .row = b_row.row, .field = 2 };
    try testing.expectEqual(document.Outcome.ignored, try document.take(clickMessage(Atom.from(grid.Msg.cell_click), &misplaced), page, state, bench.folds(), page_input));

    // Both tables drawn: no element id twice.
    const tree = try recordPage(&bench, page, document.cursorOf(state), 400);
    var seen: std.AutoHashMapUnmanaged(ui.ElementId, void) = .empty;
    var rects: u32 = 0;
    for (tree.elements[0..tree.count]) |element| {
        const id = switch (element) {
            .open_rect, .rect => |params| params.id,
            .custom => |custom| custom.params.id,
            else => continue,
        };
        rects += 1;
        const entry = try seen.getOrPut(bench.allocator(), id);
        try testing.expect(!entry.found_existing);
    }
    try testing.expect(rects > 20);
    var drawn: std.ArrayList([]const u8) = .empty;
    try textsBeginning(&tree, "", &drawn, bench.allocator());
    for ([_][]const u8{ "a.zig", "b.zig", "c.zig" }) |file| {
        const found = for (drawn.items) |text| {
            if (std.mem.eql(u8, text, file)) break true;
        } else false;
        try testing.expect(found);
    }
    for (drawn.items) |text| try testing.expect(!std.mem.eql(u8, text, "elsewhere.zig"));
}

test "document: a group block declares and reads both of its sources" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    _ = try publishGroups(&bench, &two_changelists, &files_of_the_first);
    _ = try bench.source("other.thing", "document_test_other", &.{"name"}, 3, .all_shown);
    const parsed = try document.parse(bench.allocator(), groups_text);
    var access: sequencer.Access = .{};
    document.declareAccess(&access, &bench.tables, parsed);
    const reads = access.reads[0..access.read_count];
    try testing.expect(std.mem.indexOfScalar(Atom, reads, Atom.from(changelists_table)) != null);
    try testing.expect(std.mem.indexOfScalar(Atom, reads, Atom.from(opened_table)) != null);
    try testing.expect(std.mem.indexOfScalar(Atom, reads, Atom.from("document_test_other")) == null);
    const published = try document.publishedIn(bench.allocator(), bench.drawTables(), parsed);
    try testing.expectEqual(@as(usize, 2), published.sources.len);
}

test "document: the groups' page records each changelist's heading, its table's columns aligned across the groups, and (empty) dim" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    const files = files_of_the_first ++ [_]Opened{.{ .change = "1240", .action = "integrate", .path = "a-much-longer-path/c.zig" }};
    const changes = two_changelists ++ [_]Changelist{.{ .change = 1250, .description = "Nothing yet" }};
    _ = try publishGroups(&bench, &changes, &files);
    const page = try bench.pageOf(groups_text);
    const scratch: memory_mod.Scratch = .{ .allocator = bench.allocator() };
    var tree = try ui.Tree.init(scratch, &bench.atoms, view.elementCount(600, metrics));
    var measured: u8 = 0;
    const look = style.documentStyle();
    view.record(&tree, page, onHeading(page, "Change 1234"), .{
        .inbox = Atom.from("document_test_inbox"),
        .document = document_name,
        .tags = tags,
        .view_width = 800,
        .view_height = 600,
        .scratch = scratch,
        .style = look,
        .measure = .{ .context = &measured, .width_fn = tenPixelsAByte },
    });
    try tree.validateCommands();
    try testing.expect(tree.count <= view.elementCount(600, metrics));
    // One fit for every group of the block: action is as wide in both, fit to the second's
    // `integrate`, wider than any action of the first's.
    const first = document.instanceOf(document_name, groupTable(page, "1234").key, 0);
    const second = document.instanceOf(document_name, groupTable(page, "1240").key, 0);
    const first_action = rectOf(&tree, grid.elementId(first, "table.cell", groupTable(page, "1234").table.?.rowAtPlace(0).?.row, 1)).?;
    const second_action = rectOf(&tree, grid.elementId(second, "table.cell", groupTable(page, "1240").table.?.rowAtPlace(0).?.row, 1)).?;
    try testing.expectEqual(ui.Dim{ .fixed = 9 * 10 + 16 }, first_action.size.w);
    try testing.expectEqual(first_action.size.w, second_action.size.w);
    // The empty one's note is drawn dim after its heading's text.
    var notes: u32 = 0;
    for (tree.elements[0..tree.count]) |element| {
        const text = switch (element) {
            .text => |text| text,
            else => continue,
        };
        if (!std.mem.eql(u8, text.str, "(empty)")) continue;
        notes += 1;
        try testing.expectEqual(@as(?ui.Color, look.dimmed), text.params.color);
    }
    try testing.expectEqual(@as(u32, 1), notes);
    try dumpTree(&bench, &tree, page, "MESHA_DOCUMENT_GROUPS_DUMP");
}

// ---- groups: one row of names, folds kept while groups are unknown, a group gone -------------

/// Three changelists of a file or two each, for the follow-ups' tests.
const three_changelists = two_changelists ++ [_]Changelist{.{ .change = 1250, .description = "Later" }};
const files_of_three = files_of_the_first ++ [_]Opened{
    .{ .change = "1240", .action = "integrate", .path = "c.zig" },
    .{ .change = "1250", .action = "edit", .path = "d.zig" },
    .{ .change = "1240", .action = "add", .path = "e.zig" },
};

/// How many texts `tree` records that read `text` exactly.
fn countTexts(tree: *const ui.Tree, text: []const u8) u32 {
    var count: u32 = 0;
    for (tree.elements[0..tree.count]) |element| {
        switch (element) {
            .text => |drawn| if (std.mem.eql(u8, drawn.str, text)) {
                count += 1;
            },
            else => {},
        }
    }
    return count;
}

test "document: a group block's tables have one row of names, above the first group's table the page shows" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    _ = try publishGroups(&bench, &three_changelists, &files_of_three);
    const page = try bench.pageOf(groups_text);
    const first = groupTable(page, "1234");
    const second = groupTable(page, "1240");
    try testing.expectEqual(grid.Header.names, first.table.?.header);
    try testing.expectEqual(grid.Header.hidden, second.table.?.header);
    try testing.expectEqual(grid.Header.hidden, groupTable(page, "1250").table.?.header);
    // The others are their rows alone, and their rows' stops are where they are drawn.
    try testing.expectEqual(document.table_header_height + 2 * document.table_row_height, first.height);
    try testing.expectEqual(2 * document.table_row_height, second.height);
    // A view of the second group's second row alone: the cursor below it comes up to that row,
    // and that row scrolls into a view of its height to its own top.
    var below = onHeading(page, "Change 1250");
    below.scroll = second.top + document.table_row_height;
    const in_view = document.cursorInView(page, below, document.table_row_height);
    try testing.expectEqual(second.first_stop + 1, in_view.index);
    try testing.expectEqual(second.top + document.table_row_height, document.scrollTo(page, in_view, document.table_row_height));
    // A page down from its heading by the heading, a row and a few pixels: its second row.
    const by = metrics.line_height + document.table_row_height + 5;
    try testing.expectEqual(second.first_stop + 1, document.move(page, onHeading(page, "Change 1240"), .page_down, by).index);
    const tree = try recordPage(&bench, page, onHeading(page, "Pending"), 600);
    try testing.expectEqual(@as(u32, 1), countTexts(&tree, "action"));
    try testing.expect(rectOf(&tree, grid.elementId(document.instanceOf(document_name, first.key, 0), "table.header", 0, 0)) != null);

    // The first folded, the names go above the second.
    _ = try document.toggle(page, onHeading(page, "Change 1234"), bench.folds());
    const folded = try bench.pageOf(groups_text);
    const now_second = groupTable(folded, "1240");
    try testing.expectEqual(grid.Header.names, now_second.table.?.header);
    try testing.expectEqual(document.table_header_height + 2 * document.table_row_height, now_second.height);
    try testing.expectEqual(grid.Header.hidden, groupTable(folded, "1250").table.?.header);
    const folded_tree = try recordPage(&bench, folded, onHeading(folded, "Pending"), 600);
    try testing.expectEqual(@as(u32, 1), countTexts(&folded_tree, "action"));
    try testing.expect(rectOf(&folded_tree, grid.elementId(document.instanceOf(document_name, now_second.key, 0), "table.header", 0, 0)) != null);
    // A click on the third group's row lands on it, its stops placed without a header.
    const third = groupTable(folded, "1250");
    const state = bench.state();
    state.document_view_height.* = 400;
    const cell: grid.CellClick = .{ .instance = document.instanceOf(document_name, third.key, 0), .row = third.table.?.rowAtPlace(0).?.row, .field = 2 };
    try testing.expectEqual(document.Outcome.moved, try document.take(clickMessage(Atom.from(grid.Msg.cell_click), &cell), folded, state, bench.folds(), page_input));
    try testing.expectEqual(third.first_stop, document.cursorOf(state).index);
}

test "document: a group's fold is kept while its :by source is not published or unread, and let go once the group is gone from a source read" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    const tables = try publishGroups(&bench, &two_changelists, &files_of_the_first);
    const page = try bench.pageOf(groups_text);
    _ = try document.toggle(page, onHeading(page, "Change 1234"), bench.folds());
    // A stale fold of a heading gone is let go in the same runs.
    _ = try bench.folds().insert(.{ .key = @as(u64, 12345) });

    // The refresh failed: the publisher marks its changelists unread, its rows written as nothing.
    bench.publishing().setSourceState(publisher, "p4.changelists", .unread);
    while (document.rowAt(tables.changelists, 0)) |handle| tables.changelists.free(handle);
    try document.pruneFolds(try bench.pageOf(groups_text), bench.folds());
    try testing.expectEqual(@as(usize, 1), (try document.foldedKeys(bench.allocator(), bench.folds().read())).len);

    // Not published at all for a run.
    bench.publishing().retract(publisher);
    try document.pruneFolds(try bench.pageOf(groups_text), bench.folds());
    try testing.expectEqual(@as(usize, 1), (try document.foldedKeys(bench.allocator(), bench.folds().read())).len);

    // Published again and read: the fold is 1234's still.
    _ = try publishGroups(&bench, &two_changelists, &files_of_the_first);
    const back = try bench.pageOf(groups_text);
    try document.pruneFolds(back, bench.folds());
    try testing.expect(headingNamed(back, "Change 1234").folded);

    // Submitted, from a source read: its fold goes.
    var rows = tables.changelists.readQuery(struct { change: *u32 });
    const submitted = while (rows.next()) |row| {
        if (row.view.change.* == 1234) break row.handle;
    } else unreachable;
    tables.changelists.free(submitted);
    try document.pruneFolds(try bench.pageOf(groups_text), bench.folds());
    try testing.expectEqual(@as(usize, 0), (try document.foldedKeys(bench.allocator(), bench.folds().read())).len);
}

test "document: the cursor in a group that is gone lands on the group that took its heading's place" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    const tables = try publishGroups(&bench, &three_changelists, &files_of_three);
    const page = try bench.pageOf(groups_text);
    const on_c = document.settle(page, onGroupRow(page, "1240", 0));
    const at = document.at(page, on_c);
    const block = at.row.group.?.block;
    // 1240 is submitted: its row goes, and its file with it.
    tables.changelists.free(document.rowAt(tables.changelists, 1).?);
    tables.opened.free(document.rowAt(tables.opened, 3).?);
    const after = try bench.pageOf(groups_text);
    try testing.expect(document.cursorOnGroup(after, block, "1240", at.row.row) == null);
    // The recipe: on null, the cursor it had, settled.
    const landed = document.at(after, document.settle(after, on_c));
    try testing.expect(landed == .group);
    try testing.expectEqualStrings("1250", landed.group.key_text);
}

test "document: in a group's heading {{{count}}} is the row's field count, {{{count()}}} the group's rows" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    _ = try publishGroups(&bench, &two_changelists, &files_of_the_first);
    _ = try bench.source("p4.counted", "document_test_counted", &.{ "change", "count" }, 1, .all_shown);
    const text =
        \\#+BEGIN: group :by p4.counted :key change :source p4.opened :columns "path"
        \\* {{{change}}} {{{count}}} {{{count()}}}
        \\#+END:
    ;
    try expectTexts(&.{"change-0 count-0 0 (empty)"}, try shownTexts(&bench, try bench.pageOf(text)));
}
