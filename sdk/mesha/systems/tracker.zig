//! The tracker system's contract: charts of table cells over time. A tracker is a pair of tables.
//!
//! - Its definition, `tracker_<name>`, lists what to chart: a row per series, each naming a table,
//!   a column and a row of it, and the series' colour (`Series`). The editor makes definitions
//!   (`create`), adds series to them (`addSeries`) and removes them (`delete`).
//! - Its history, `history_tracker_<name>`, is made and filled by the host's sampler
//!   (`runtime/tracker.zig`): once a frame it appends a row to each definition's history, the
//!   sample's number in `x` and each series' cell as an `f32` in `series_<index>`, keeping the
//!   latest `historySize` rows. A cell that is missing or not a number samples as NaN. Changing a
//!   definition's series empties its history.
//!
//! The two are tied by rows of resources' table metadata (`resources_table_metadata`) under the
//! definition's name: `tracker_history_handle` holds the history table's handle, which the sampler
//! writes and `history` reads, and `history_size` how many samples to keep. This file draws
//! nothing: a chart is drawn by whoever reads the history, as the editor's table windows do.

const std = @import("std");
/// The engine's atom type, as the tracker's names use it.
pub const Atom = @import("../core/atom.zig").Atom;
const memory_mod = @import("../core/memory.zig");
/// The engine's table type; `Table.Registry` holds the tables.
pub const Table = @import("../core/table.zig");
const resources = @import("resources.zig");
const math = @import("../core/math.zig");

/// The named schema every definition table has: the columns of `SeriesView`.
pub const definition_schema_name = "tracker_definition";
/// What a definition table's name begins with; the rest is the tracker's name.
pub const definition_prefix = "tracker_";
/// What a history table's name begins with; the rest is the tracker's name.
pub const history_prefix = "history_tracker_";
/// The metadata key, under a definition's name, whose value is how many samples its history keeps,
/// as decimal text.
pub const history_size_key = "history_size";
/// The metadata key, under a definition's name, whose value is its history table's handle as
/// `<index>:<generation>`. The sampler writes it.
pub const history_handle_key = "tracker_history_handle";
/// How many samples a history keeps when its definition's metadata says nothing valid.
pub const default_history_size: u32 = 256;
/// The most series a definition holds. A table's row mask has 64 bits: a history has one `x` column
/// and 63 series columns.
pub const max_series: usize = 63;

/// One thing a tracker charts: a cell, and the colour its line is drawn in.
pub const Series = struct {
    /// The table the cell is in, by name. One that does not exist samples as NaN.
    table_name: Atom,
    /// The cell's column. An integer or float column is charted; any other samples as NaN.
    field_name: Atom,
    /// The cell's row, as a row id of the table (`RowHandle.row`).
    row: u32 = 0,
    /// The line's colour, red, green, blue and alpha, each 0 to 1.
    color: math.Vec4f,
};
/// A row of a definition table as a view reads it: the fields of `Series`.
pub const SeriesView = struct {
    /// The table the cell is in, by name.
    table_name: *Atom,
    /// The cell's column.
    field_name: *Atom,
    /// The cell's row, as a row id of the table.
    row: *u32,
    /// The line's colour, red, green, blue and alpha, each 0 to 1.
    color: *math.Vec4f,
};

fn definitionSchema(allocator: std.mem.Allocator, atoms: *Atom.Registry) !Table.Schema {
    var schema: Table.Schema = undefined;
    try schema.init(allocator, atoms, 4);
    errdefer schema.deinit();
    try schema.addFieldFallible("table_name", Atom, .atom);
    try schema.addFieldFallible("field_name", Atom, .atom);
    try schema.addFieldFallible("row", u32, .int);
    try schema.addFieldFallible("color", math.Vec4f, .{ .vector = .{ .components = 4 } });
    return schema;
}

/// Creates the definition table `tracker_<name>`, empty and owned by the editor, and returns its
/// handle. It is durable but belongs to no table document, so it lasts for the session.
/// `error.InvalidTrackerName` for an empty name; `error.DuplicateTableName` when a table is already
/// called `tracker_<name>` or `history_tracker_<name>`. `allocator` is used for temporary names
/// only. The history appears when the host next samples.
pub fn create(allocator: std.mem.Allocator, atoms: *Atom.Registry, tables: *Table.Registry, name: []const u8) !Table.Handle {
    if (name.len == 0) return error.InvalidTrackerName;
    const full_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ definition_prefix, name });
    defer allocator.free(full_name);
    const history_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ history_prefix, name });
    defer allocator.free(history_name);
    if (tables.findHandleByName(Atom.from(full_name)) != null or tables.findHandleByName(Atom.from(history_name)) != null) return error.DuplicateTableName;
    var schema = try definitionSchema(allocator, atoms);
    defer schema.deinit();
    const schema_name = atoms.intern(definition_schema_name);
    try tables.registerSchema(schema_name, &schema);
    const previous_scope = tables.scope;
    tables.scope = .editor;
    defer tables.scope = previous_scope;
    return tables.createNamed(schema_name, 1, atoms.intern(full_name), .durable);
}

/// Whether `table` is a tracker's definition: named `tracker_<name>`, owned by the editor, durable
/// and of the definition schema. False when `atoms` does not hold the table's name.
pub fn isDefinition(atoms: *const Atom.Registry, table: *const Table) bool {
    const name = atoms.lookup(table.name) orelse return false;
    return std.mem.startsWith(u8, name, definition_prefix) and name.len > definition_prefix.len and
        table.owner == .editor and table.lifetime == .durable and table.uses_named_schema and
        table.schema_name == Atom.from(definition_schema_name);
}

/// Appends `series` to `definition` and returns its row. Series are charted in row order.
/// `error.TooManySeries` once the definition holds `max_series`; otherwise the table's own
/// allocation errors. The history is emptied at the next sample, since its columns change.
pub fn addSeries(definition: *Table, series: Series) !Table.RowHandle {
    if (definition.count() >= max_series) return error.TooManySeries;
    const handle = try definition.alloc();
    const view = definition.getRow(handle, SeriesView).?;
    view.table_name.* = series.table_name;
    view.field_name.* = series.field_name;
    view.row.* = series.row;
    view.color.* = series.color;
    definition.setRowMask(handle, series);
    return handle;
}

/// The series at `index` in the definition's row order, or null past the last. Its samples are the
/// history's column `series_<index>` (`seriesFieldName`). Each call walks the rows from the first.
pub fn seriesAt(definition: *Table, index: usize) ?Series {
    var it = definition.rows();
    var i: usize = 0;
    while (it.next()) |handle| : (i += 1) {
        if (i != index) continue;
        const view = definition.getRow(handle, SeriesView) orelse return null;
        return .{ .table_name = view.table_name.*, .field_name = view.field_name.*, .row = view.row.*, .color = view.color.* };
    }
    return null;
}

/// The name of the history column that holds series `index`, `series_<index>`, written into
/// `buffer`. `error.TooManySeries` for an index of `max_series` or more; `error.NoSpaceLeft` when
/// `buffer` is too small.
pub fn seriesFieldName(buffer: []u8, index: usize) ![]const u8 {
    if (index >= max_series) return error.TooManySeries;
    return std.fmt.bufPrint(buffer, "series_{d}", .{index});
}

/// The name of the history table of the definition named `definition_name`,
/// `history_tracker_<name>`, allocated in `allocator` for the caller to free.
/// `error.InvalidTrackerName` when the name is not interned or not a definition's.
pub fn historyName(allocator: std.mem.Allocator, atoms: *const Atom.Registry, definition_name: Atom) ![]u8 {
    const name = atoms.lookup(definition_name) orelse return error.InvalidTrackerName;
    if (!std.mem.startsWith(u8, name, definition_prefix) or name.len == definition_prefix.len) return error.InvalidTrackerName;
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ history_prefix, name[definition_prefix.len..] });
}

/// The history table of `definition`, or null when `definition` is not a tracker's definition or
/// the sampler has not yet made its history. It is found by the handle in the definition's metadata
/// and checked to be the host's durable table of the expected name, so a stale handle gives null.
/// `allocator` is used for a temporary name. The table is the host's: read it, and expect its rows
/// to move each frame.
pub fn history(allocator: std.mem.Allocator, atoms: *Atom.Registry, tables: *Table.Registry, definition: *const Table) !?*Table {
    if (!isDefinition(atoms, definition)) return null;
    const meta = resources.metadataTable(tables, atoms) orelse return null;
    var rows = resources.metadataRows(meta, definition.name);
    while (rows.next()) |item| {
        if (!std.mem.eql(u8, item.view.key, history_handle_key)) continue;
        var parts = std.mem.splitScalar(u8, item.view.value, ':');
        const index = std.fmt.parseInt(u32, parts.next() orelse return null, 10) catch return null;
        const generation = std.fmt.parseInt(u32, parts.next() orelse return null, 10) catch return null;
        if (parts.next() != null) return null;
        const result = tables.get(.{ .index = index, .generation = generation }) orelse return null;
        const name = try historyName(allocator, atoms, definition.name);
        defer allocator.free(name);
        if (result.name != Atom.from(name) or result.owner != .host or result.lifetime != .durable) return null;
        return result;
    }
    return null;
}

/// Removes every metadata row kept under the table name `id`. Does nothing when resources' metadata
/// table is not there.
pub fn removeMetadata(atoms: *Atom.Registry, tables: *Table.Registry, id: Atom) void {
    const meta = resources.metadataTable(tables, atoms) orelse return;
    // Free compacts rows; restart the iterator after each deletion.
    while (true) {
        var it = resources.metadataRows(meta, id);
        const item = it.next() orelse break;
        meta.free(item.handle);
    }
}

/// Destroys the definition table `handle` and removes its metadata. `error.StaleTable` when the
/// handle names no table, `error.NotTrackerDefinition` when it names another kind. The history
/// table is destroyed by the host's sampler on its next frame.
pub fn delete(atoms: *Atom.Registry, tables: *Table.Registry, handle: Table.Handle) !void {
    const definition = tables.get(handle) orelse return error.StaleTable;
    if (!isDefinition(atoms, definition)) return error.NotTrackerDefinition;
    const name = definition.name;
    tables.destroy(handle);
    removeMetadata(atoms, tables, name);
}

/// How many samples the history of the definition named `name` keeps: the value of its
/// `history_size` metadata, or `default_history_size` when there is none, or it is 0 or not a
/// decimal `u32`. Of several such rows the one with the lowest row id counts.
pub fn historySize(atoms: *Atom.Registry, tables: *Table.Registry, name: Atom) u32 {
    const meta = resources.metadataTable(tables, atoms) orelse return default_history_size;
    var rows = meta.rows();
    var first_row: ?u32 = null;
    var first_view: ?resources.TableMetadataView = null;
    while (rows.next()) |handle| {
        const view = meta.getRow(handle, resources.TableMetadataView) orelse continue;
        if (view.id.* != name) continue;
        if (!std.mem.eql(u8, view.key, history_size_key)) continue;
        // Physical iteration order can change when rows are freed.
        if (first_row) |row| if (handle.row >= row) continue;
        first_row = handle.row;
        first_view = view;
    }
    const view = first_view orelse return default_history_size;
    const size = std.fmt.parseInt(u32, view.value, 10) catch return default_history_size;
    return if (size == 0) default_history_size else size;
}

test "historySize selects the lowest live logical metadata row" {
    const testing = std.testing;
    var memory: memory_mod.Memory = undefined;
    memory.init(testing.allocator);
    defer memory.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&memory);
    defer atoms.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&memory, 32);
    defer tables.deinit();
    try resources.ensureTableAssetCatalog(testing.allocator, &atoms, &tables);
    const meta = resources.metadataTable(&tables, &atoms).?;
    const name = atoms.intern("tracker_lookup");
    const other_name = atoms.intern("other");

    const unrelated = try meta.alloc();
    try resources.writeMetadataRow(meta, unrelated, other_name, history_size_key, "99");
    const first = try meta.alloc();
    try resources.writeMetadataRow(meta, first, name, history_size_key, "7");
    const other_key = try meta.alloc();
    try resources.writeMetadataRow(meta, other_key, name, "other", "98");
    const duplicate = try meta.alloc();
    try resources.writeMetadataRow(meta, duplicate, name, history_size_key, "9");
    try testing.expectEqual(@as(u32, 7), historySize(&atoms, &tables, name));

    // Compaction moves the higher logical ID ahead of the first match physically.
    meta.free(unrelated);
    var rows = meta.rows();
    try testing.expectEqual(duplicate.row, rows.next().?.row);
    try testing.expect(first.row < duplicate.row);
    try testing.expectEqual(@as(u32, 7), historySize(&atoms, &tables, name));
    try resources.writeMetadataRow(meta, first, name, history_size_key, "bad");
    try testing.expectEqual(default_history_size, historySize(&atoms, &tables, name));
    try resources.writeMetadataRow(meta, first, name, history_size_key, "4294967296");
    try testing.expectEqual(default_history_size, historySize(&atoms, &tables, name));
    meta.free(first);
    try testing.expectEqual(@as(u32, 9), historySize(&atoms, &tables, name));
    meta.free(duplicate);
    try testing.expectEqual(default_history_size, historySize(&atoms, &tables, name));
}
