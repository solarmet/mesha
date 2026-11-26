//! What systems publish for documents to show: named sources and named values, in two tables
//! of the document component's. A document names them in its text (`org.zig`): a table block
//! shows a source's rows (`:source vcs-git.unstaged`), a macro a value (`{{{vcs-git.branch}}}`),
//! and the document's own macro `{{{count(name)}}}` a source's number of rows.
//!
//! - A *source* (`editor_document_sources`) is a name, a table of the publishing system's own,
//!   a row a thing, and which of its fields are for showing, in order.
//! - A *value* (`editor_document_values`) is a name and a text.
//!
//! A name is text a document's author writes, not an atom: by custom the publisher's name, a
//! dot, and what it is (`vcs-git.branch`). Each row also says who published it (`owner`): an
//! atom naming the publishing system, the same for everything it publishes and for its
//! `retract`. A name is published once: publishing it again replaces what was published,
//! whoever published it before; when that was another publisher, the later wins and a warning
//! names both, as two systems giving one name is a mistake to see.
//!
//! Publishing writes these tables, so it is done in a kernel of the publisher's system, which
//! declares both written (`sources_table_name`, `values_table_name`) and reaches them through
//! its pass (`Publishing.of`), which refuses a system that did not declare them
//! (`error.UndeclaredWrite`); a test outside any run makes a `Publishing` of the registry's
//! tables. A reader's system declares the table read and looks names up with `sourceOf` and `valueOf`
//! over its rows. The tables are `durable`: they live in memory while the host runs, through a
//! reload of the editor, and are never saved; a document's source is its `.org` text alone.
//!
//! So rows outlive the build that published them. A publisher that runs again after a reload
//! publishes over its own rows, by name, as it refreshes; it retracts what it published when
//! that no longer stands (`retract`, as its panel closes or its plugin is let go) and, between
//! refreshes, publishes no name it has stopped using without retracting it first. A name a
//! publisher no longer publishes, or a publisher removed or renamed between builds, leaves rows
//! that nothing retracts: they stay until the host stops, read by any document that names them.
//!
//! This is the editor's own mechanism while its one publisher is in the editor; its names and
//! shapes are meant to become a contract of the SDK once a plugin publishes to a document.
const std = @import("std");
const mesha = @import("mesha");
const Atom = mesha.Atom;
const Table = mesha.Table;
const memory_mod = mesha.memory;
const sequencer = mesha.sequencer;

const Log = mesha.log.scope("document_sources");

/// The sources published: a row a name.
pub const sources_table_name = "editor_document_sources";
/// The values published: a row a name.
pub const values_table_name = "editor_document_values";
const sources_table = Atom.from(sources_table_name);
const values_table = Atom.from(values_table_name);

/// Whether a source's table holds what its publisher last read.
pub const SourceState = enum(u8) {
    /// It does.
    ok,
    /// Its publisher could not read what it was to hold (a program's output that would not
    /// parse): the table holds what it held before, and a document says so.
    unread,
};

/// A source as a publisher gives it to `publishSource`.
pub const Source = struct {
    /// Its name, as a document writes it after `:source`; copied.
    name: []const u8,
    /// The table whose rows it is, the publisher's own, by its name's atom.
    table: Atom,
    /// The names of the table's fields that are for showing, in order, each holding no space; a
    /// document's `:columns` chooses among them. Copied, as one text.
    shown: []const []const u8,
};

/// The two tables a publisher writes, as its kernel's pass gives them (`of`), so a system that
/// did not declare them written is refused; a test outside any run makes one of the registry's
/// tables. Good for the kernel's call.
pub const Publishing = struct {
    /// `editor_document_sources`.
    sources: *Table,
    /// `editor_document_values`.
    values: *Table,
    /// Lends the frame's scratch, to join a source's fields.
    memory: *memory_mod.Memory,

    /// The two tables from `pass`, whose system must declare both written:
    /// `error.UndeclaredWrite` otherwise. Null while they are not made, when nothing is
    /// published.
    pub fn of(pass: *sequencer.Pass) sequencer.Error!?Publishing {
        const tables = pass.frame.tables;
        const made = tables.findByName(sources_table) != null and tables.findByName(values_table) != null;
        if (!made) return null;
        const sources = try pass.writeTable(sources_table);
        const values = try pass.writeTable(values_table);
        return .{ .sources = sources, .values = values, .memory = pass.frame.memory };
    }

    /// Publishes `source` as `owner`'s: a row of `editor_document_sources`, in place of any of
    /// its name, its state `ok`. A row that holds all of it already is not written again, so a
    /// publisher may publish on each refresh. The frame's scratch joins `shown`.
    pub fn publishSource(publishing: Publishing, owner: Atom, source: Source) void {
        const sources = publishing.sources;
        const scratch = publishing.memory.frameScratchAllocator() catch |err| {
            Log.err("source_unpublished", .{ .name = source.name, .@"error" = @errorName(err) });
            return;
        };
        const shown = std.mem.join(scratch.allocator, " ", source.shown) catch |err| {
            Log.err("source_unpublished", .{ .name = source.name, .@"error" = @errorName(err) });
            return;
        };
        const found = findSource(sources, source.name) orelse {
            const row = .{ .name = source.name, .table = source.table, .shown = shown, .owner = owner, .state = @intFromEnum(SourceState.ok) };
            _ = sources.tryInsert(row) catch |err| {
                Log.err("source_unpublished", .{ .name = source.name, .@"error" = @errorName(err) });
            };
            return;
        };
        const published = found.view;
        const unchanged = published.table.* == source.table and published.owner.* == owner and
            published.state.* == @intFromEnum(SourceState.ok) and std.mem.eql(u8, published.shown, shown);
        if (unchanged) return;
        if (published.owner.* != owner) {
            Log.warn("source_taken", .{ .name = source.name, .owner = published.owner.*, .by = owner });
        }
        const row = sources.getRow(found.handle, struct { table: *Atom, owner: *Atom, state: *u8 }) orelse return;
        row.table.* = source.table;
        row.owner.* = owner;
        row.state.* = @intFromEnum(SourceState.ok);
        sources.setString(found.handle, "shown", shown) catch |err| {
            Log.err("source_unpublished", .{ .name = source.name, .@"error" = @errorName(err) });
        };
    }

    /// Sets the state of the source `name`, which `owner` published: `unread` when what its
    /// table was to hold could not be read, `ok` again once it could. Nothing happens for a name
    /// `owner` has not published.
    pub fn setSourceState(publishing: Publishing, owner: Atom, name: []const u8, state: SourceState) void {
        const sources = publishing.sources;
        const found = findSource(sources, name) orelse return;
        if (found.view.owner.* != owner) return;
        if (found.view.state.* == @intFromEnum(state)) return;
        const row = sources.getRow(found.handle, struct { state: *u8 }) orelse return;
        row.state.* = @intFromEnum(state);
    }

    /// Publishes the value `name` as `owner`'s: a row of `editor_document_values` holding `text`,
    /// in place of any of its name. Both are copied. A row that holds them already is not
    /// written again.
    pub fn publishValue(publishing: Publishing, owner: Atom, name: []const u8, text: []const u8) void {
        const values = publishing.values;
        const found = findValue(values, name) orelse {
            _ = values.tryInsert(.{ .name = name, .text = text, .owner = owner }) catch |err| {
                Log.err("value_unpublished", .{ .name = name, .@"error" = @errorName(err) });
            };
            return;
        };
        const published = found.view;
        if (published.owner.* == owner and std.mem.eql(u8, published.text, text)) return;
        if (published.owner.* != owner) {
            Log.warn("value_taken", .{ .name = name, .owner = published.owner.*, .by = owner });
            const row = values.getRow(found.handle, struct { owner: *Atom }) orelse return;
            row.owner.* = owner;
        }
        values.setString(found.handle, "text", text) catch |err| {
            Log.err("value_unpublished", .{ .name = name, .@"error" = @errorName(err) });
        };
    }

    /// Takes back every source and value `owner` published, as a publisher does when what it
    /// published no longer stands (its panel closed, its plugin let go).
    pub fn retract(publishing: Publishing, owner: Atom) void {
        freeOwned(publishing.sources, owner);
        freeOwned(publishing.values, owner);
    }
};

/// Frees every row of `table` whose `owner` is `owner`, looking again after each, as a free
/// moves rows.
fn freeOwned(table: *Table, owner: Atom) void {
    while (true) {
        var rows = table.readQuery(struct { owner: *Atom });
        const handle = while (rows.next()) |row| {
            if (row.view.owner.* == owner) break row.handle;
        } else return;
        table.free(handle);
    }
}

// ---- reading what is published ----------------------------------------------------------------

/// A row of `editor_document_sources`, as a reader's query names it.
pub const SourceRow = struct {
    /// The source's name.
    name: []const u8,
    /// The table whose rows it is.
    table: *Atom,
    /// The names of the fields for showing, in order, separated by spaces (`org.columns` splits
    /// them).
    shown: []const u8,
    /// Who published it.
    owner: *Atom,
    /// A `SourceState`.
    state: *u8,
};

/// A source as `sourceOf` finds it. Its text is the table's: good for the reader's run.
pub const Published = struct {
    /// The table whose rows it is.
    table: Atom,
    /// The names of the fields for showing, separated by spaces.
    shown: []const u8,
    /// Who published it.
    owner: Atom,
    /// Whether the table holds what its publisher last read.
    state: SourceState,
};

/// The source published as `name`, from `rows`, the rows of `editor_document_sources`; null
/// when none is.
pub fn sourceOf(rows: Table.ReadQuery(SourceRow), name: []const u8) ?Published {
    var sources = rows;
    while (sources.next()) |row| {
        if (!std.mem.eql(u8, row.view.name, name)) continue;
        const state: SourceState = if (row.view.state.* == @intFromEnum(SourceState.unread)) .unread else .ok;
        return .{ .table = row.view.table.*, .shown = row.view.shown, .owner = row.view.owner.*, .state = state };
    }
    return null;
}

fn findSource(sources: *Table, name: []const u8) ?FoundRow(SourceRow) {
    var rows = sources.readQuery(SourceRow);
    while (rows.next()) |row| {
        if (std.mem.eql(u8, row.view.name, name)) return .{ .handle = row.handle, .view = row.view };
    }
    return null;
}

/// A row of `editor_document_values`, as a reader's query names it.
pub const ValueRow = struct {
    /// The value's name.
    name: []const u8,
    /// The value.
    text: []const u8,
    /// Who published it.
    owner: *Atom,
};

/// The text of the value published as `name`, from `rows`, the rows of
/// `editor_document_values`; null when none is. The text is the table's: good for the reader's
/// run.
pub fn valueOf(rows: Table.ReadQuery(ValueRow), name: []const u8) ?[]const u8 {
    var values = rows;
    while (values.next()) |row| {
        if (std.mem.eql(u8, row.view.name, name)) return row.view.text;
    }
    return null;
}

fn findValue(values: *Table, name: []const u8) ?FoundRow(ValueRow) {
    var rows = values.readQuery(ValueRow);
    while (rows.next()) |row| {
        if (std.mem.eql(u8, row.view.name, name)) return .{ .handle = row.handle, .view = row.view };
    }
    return null;
}

/// A row found by its name: its handle and a read-only view of it, good until the table next
/// changes.
fn FoundRow(comptime View: type) type {
    return struct { handle: Table.RowHandle, view: Table.ReadView(View) };
}

// ---- the tables -------------------------------------------------------------------------------

/// Makes the two tables, unless they are there: changes no row of one that is.
pub fn ensure(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    try atoms.tryInternAll(&.{ sources_table_name, values_table_name });

    var sources: Table.Schema = undefined;
    try sources.init(scratch.allocator, atoms, 5);
    defer sources.deinit();
    try sources.addFieldFallible("name", Table.String, .text_field);
    try sources.addFieldFallible("table", Atom, .atom);
    try sources.addFieldFallible("shown", Table.String, .text_field);
    try sources.addFieldFallible("owner", Atom, .atom);
    try sources.addFieldFallible("state", u8, .int);
    _ = try tables.ensure(&sources, 16, sources_table, .durable);

    var values: Table.Schema = undefined;
    try values.init(scratch.allocator, atoms, 3);
    defer values.deinit();
    try values.addFieldFallible("name", Table.String, .text_field);
    try values.addFieldFallible("text", Table.String, .text_field);
    try values.addFieldFallible("owner", Atom, .atom);
    _ = try tables.ensure(&values, 32, values_table, .durable);
}

// ---- tests ------------------------------------------------------------------------------------

const testing = std.testing;

const Bench = struct {
    memory: memory_mod.Memory = undefined,
    atoms: Atom.Registry = undefined,
    tables: Table.Registry = undefined,

    fn init(bench: *Bench) !void {
        bench.memory.init(testing.allocator);
        try bench.atoms.init(&bench.memory);
        try bench.tables.init(&bench.memory, 16);
        try ensure(try bench.memory.tableScratchAllocator(), &bench.atoms, &bench.tables);
    }

    fn deinit(bench: *Bench) void {
        bench.tables.deinit();
        bench.atoms.deinit();
        bench.memory.deinit();
    }

    fn sourceRows(bench: *Bench) Table.ReadQuery(SourceRow) {
        return bench.tables.findByName(sources_table).?.readQuery(SourceRow);
    }

    fn valueRows(bench: *Bench) Table.ReadQuery(ValueRow) {
        return bench.tables.findByName(values_table).?.readQuery(ValueRow);
    }

    fn count(bench: *Bench, name: Atom) u32 {
        return bench.tables.findByName(name).?.count();
    }

    /// The two tables, as a publisher's pass gives them.
    fn publishing(bench: *Bench) Publishing {
        return .{ .sources = bench.tables.findByName(sources_table).?, .values = bench.tables.findByName(values_table).?, .memory = &bench.memory };
    }
};

test "document: a source published twice by one owner is replaced, and retract removes an owner's" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    const vcs = Atom.from("vcs_git");
    const other = Atom.from("other_publisher");
    const first_table = Atom.from("editor_vcs_git_unstaged");
    const second_table = Atom.from("editor_vcs_git_unstaged_again");

    bench.publishing().publishSource(vcs, .{ .name = "vcs-git.unstaged", .table = first_table, .shown = &.{"path"} });
    bench.publishing().publishSource(vcs, .{ .name = "vcs-git.unstaged", .table = second_table, .shown = &.{ "change", "path" } });
    try testing.expectEqual(@as(u32, 1), bench.count(sources_table));
    const replaced = sourceOf(bench.sourceRows(), "vcs-git.unstaged").?;
    try testing.expectEqual(second_table, replaced.table);
    try testing.expectEqualStrings("change path", replaced.shown);
    try testing.expectEqual(vcs, replaced.owner);
    try testing.expectEqual(SourceState.ok, replaced.state);

    bench.publishing().setSourceState(vcs, "vcs-git.unstaged", .unread);
    try testing.expectEqual(SourceState.unread, sourceOf(bench.sourceRows(), "vcs-git.unstaged").?.state);
    bench.publishing().publishSource(vcs, .{ .name = "vcs-git.unstaged", .table = second_table, .shown = &.{ "change", "path" } });
    try testing.expectEqual(SourceState.ok, sourceOf(bench.sourceRows(), "vcs-git.unstaged").?.state);

    bench.publishing().publishValue(vcs, "vcs-git.branch", "main");
    bench.publishing().publishValue(vcs, "vcs-git.branch", "topic");
    try testing.expectEqual(@as(u32, 1), bench.count(values_table));
    try testing.expectEqualStrings("topic", valueOf(bench.valueRows(), "vcs-git.branch").?);
    try testing.expect(valueOf(bench.valueRows(), "vcs-git.upstream") == null);

    // Another publisher's name of the same: the later wins, and is its own to retract.
    bench.publishing().publishSource(vcs, .{ .name = "vcs-git.staged", .table = first_table, .shown = &.{"path"} });
    bench.publishing().publishSource(other, .{ .name = "vcs-git.staged", .table = second_table, .shown = &.{"path"} });
    try testing.expectEqual(other, sourceOf(bench.sourceRows(), "vcs-git.staged").?.owner);
    bench.publishing().publishValue(other, "other.value", "kept");

    bench.publishing().retract(vcs);
    try testing.expect(sourceOf(bench.sourceRows(), "vcs-git.unstaged") == null);
    try testing.expect(valueOf(bench.valueRows(), "vcs-git.branch") == null);
    try testing.expectEqual(second_table, sourceOf(bench.sourceRows(), "vcs-git.staged").?.table);
    try testing.expectEqualStrings("kept", valueOf(bench.valueRows(), "other.value").?);
    try testing.expectEqual(@as(u32, 1), bench.count(sources_table));
    try testing.expectEqual(@as(u32, 1), bench.count(values_table));
}
