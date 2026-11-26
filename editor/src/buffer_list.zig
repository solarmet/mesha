//! The buffers a person switches between and kills (`C-x b`, `C-x k`): the text editors'
//! buffers, the figures loaded and the sketches open, a figure being a kind of buffer the
//! figure stage shows as a text window shows a text buffer. Each is listed most recently
//! visited first: a buffer is visited while the window that shows it has the focus, which the
//! text panels and the figure canvas note (`visit`) in `editor_buffer_visits`.
const std = @import("std");
const mesha = @import("mesha");
const Atom = mesha.Atom;
const Table = mesha.Table;
const sequencer = mesha.sequencer;
const memory_mod = mesha.memory;
const plugin = mesha.plugin;
const figure_api = mesha.figure;
const session = @import("figure/session.zig");
const Log = mesha.log.scope("buffer_list");
const text_editor = plugin.text_editor_api;

const no_atom: Atom = @enumFromInt(0);

/// What a listed buffer is, and so what shows it and what closes it.
pub const Kind = enum(u8) { text, figure, sketch };

/// `editor_buffer_visits`: a row for each buffer visited, with when, by a serial that grows
/// with each visit. A buffer closed keeps its row, which lists nothing, until the oldest rows
/// make room for new ones.
pub const visits_table_name = "editor_buffer_visits";
const visits_table = Atom.from(visits_table_name);

/// The most rows `editor_buffer_visits` keeps: past it, a visit forgets the oldest.
const max_visits = 128;

const VisitRow = struct {
    /// The buffer's id: a text buffer's, or a figure's or a sketch's document key.
    buffer: *Atom,
    /// A `Kind`.
    kind: *u8,
    /// When it was last visited: the greatest is the latest.
    serial: *u32,
};

pub fn ensure(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    var schema: Table.Schema = undefined;
    try schema.init(scratch.allocator, atoms, 3);
    defer schema.deinit();
    try schema.addFieldFallible("buffer", Atom, .atom);
    try schema.addFieldFallible("kind", u8, .int);
    try schema.addFieldFallible("serial", u32, .int);
    _ = try tables.ensure(&schema, max_visits, visits_table, .durable);
}

/// Declares what `visit` writes, for a system that calls it.
pub fn declareVisits(result: *sequencer.Access, tables: *Table.Registry) void {
    result.writeIfPresent(tables, visits_table);
}

/// Declares what `collect` reads, for a system that calls it.
pub fn declareListing(result: *sequencer.Access, tables: *Table.Registry) void {
    const read = [_]Atom{
        visits_table,
        Atom.from(text_editor.buffers_table_name),
        Atom.from(figure_api.definitions_table_name),
        Atom.from(figure_api.sketches_table_name),
    };
    for (read) |name| {
        if (tables.findByName(name) != null) result.read(name);
    }
}

/// Notes that `buffer`, of `kind`, is being visited: it becomes the latest. Nothing is written
/// when it is the latest already, so a system may call this every frame its window has the
/// focus.
pub fn visit(tables: *Table.Registry, kind: Kind, buffer: Atom) void {
    if (buffer == no_atom) return;
    const table = tables.findByName(visits_table) orelse return;
    var latest: u32 = 0;
    var own: ?VisitRow = null;
    var oldest: ?Table.RowHandle = null;
    var oldest_serial: u32 = std.math.maxInt(u32);
    var rows = table.query(VisitRow);
    while (rows.next()) |found| {
        const row = found.view;
        latest = @max(latest, row.serial.*);
        if (row.buffer.* == buffer and row.kind.* == @intFromEnum(kind)) own = row;
        if (row.serial.* < oldest_serial) {
            oldest_serial = row.serial.*;
            oldest = found.handle;
        }
    }
    if (own) |row| {
        if (row.serial.* == latest) return;
        row.serial.* = latest + 1;
        return;
    }
    if (table.count() >= max_visits) {
        if (oldest) |handle| table.free(handle);
    }
    _ = table.tryInsert(.{ .buffer = buffer, .kind = @intFromEnum(kind), .serial = latest + 1 }) catch |err| {
        Log.err("buffer_visit_unrecorded", .{ .@"error" = @errorName(err) });
    };
}

/// A buffer listed.
pub const Entry = struct {
    kind: Kind,
    /// The text buffer's id, or the figure's or the sketch's document key.
    id: Atom,
    /// The file it holds, absolute; empty for none. Its table's, good for the frame.
    path: []const u8,
    /// What it is called without a file, as `*scratch*` or a figure's key; empty for a text
    /// buffer that holds a file.
    name: []const u8,
    /// Whether it has unsaved changes. Known for figures and sketches; false for text, whose
    /// state the text panels read themselves.
    modified: bool,
    /// When it was last visited; 0 for never.
    serial: u32,
};

/// Every buffer a person switches to, the latest visited first and those never visited after
/// them in the order their lists hold them: text buffers, then figures, then sketches. A text
/// buffer with neither a file nor a name (a field's) is left out, and so is a figure the
/// game's scope holds. Allocated from `allocator`; its strings are the tables' for the frame.
pub fn collect(allocator: std.mem.Allocator, tables: *Table.Registry, atoms: *Atom.Registry) ![]Entry {
    var listed: std.ArrayList(Entry) = .empty;
    if (tables.findByName(Atom.from(text_editor.buffers_table_name))) |buffers| {
        var rows = buffers.readQuery(text_editor.BufferEntry);
        while (rows.next()) |found| {
            const entry = found.view;
            if (entry.path.len == 0 and entry.name.len == 0) continue;
            try listed.append(allocator, .{ .kind = .text, .id = entry.buffer.*, .path = entry.path, .name = entry.name, .modified = false, .serial = 0 });
        }
    }
    if (tables.findByName(Atom.from(figure_api.definitions_table_name)) != null) {
        for (try session.listDefinitions(tables, atoms)) |definition| {
            const info = definition.info;
            const name = atoms.lookup(info.definition) orelse continue;
            const path = session.definitionPath(tables, atoms, info.definition) orelse "";
            try listed.append(allocator, .{ .kind = .figure, .id = info.definition, .path = path, .name = name, .modified = info.dirty, .serial = 0 });
        }
    }
    if (tables.findByName(Atom.from(figure_api.sketches_table_name))) |sketches| {
        var rows = sketches.readQuery(figure_api.SketchView);
        while (rows.next()) |found| {
            const sketch = found.view;
            // A loader's hold is the game's; the editor lists those it opened.
            if (sketch.editor_open.* == 0) continue;
            const name = atoms.lookup(sketch.sketch.*) orelse continue;
            try listed.append(allocator, .{ .kind = .sketch, .id = sketch.sketch.*, .path = sketch.path, .name = name, .modified = sketch.dirty.* != 0, .serial = 0 });
        }
    }
    if (tables.findByName(visits_table)) |visits| {
        var rows = visits.readQuery(VisitRow);
        while (rows.next()) |found| {
            const row = found.view;
            for (listed.items) |*entry| {
                if (entry.id != row.buffer.* or @intFromEnum(entry.kind) != row.kind.*) continue;
                entry.serial = row.serial.*;
            }
        }
    }
    // Stable, so the buffers never visited keep their lists' order.
    std.mem.sort(Entry, listed.items, {}, struct {
        fn later(_: void, lhs: Entry, rhs: Entry) bool {
            return lhs.serial > rhs.serial;
        }
    }.later);
    return listed.toOwnedSlice(allocator);
}

/// A listed buffer as a completion's data carries it: its id, then its kind.
pub const Chosen = struct {
    kind: Kind,
    id: Atom,

    /// `chosen` written into a completion's data.
    pub fn encode(chosen: Chosen) [plugin.editor_api.kCompletionDataSize]u8 {
        var data = std.mem.zeroes([plugin.editor_api.kCompletionDataSize]u8);
        @memcpy(data[0..@sizeOf(Atom)], std.mem.asBytes(&chosen.id));
        data[@sizeOf(Atom)] = @intFromEnum(chosen.kind);
        return data;
    }

    /// What `encode` wrote into `data`; a kind it does not know reads as text.
    pub fn decode(data: []const u8) Chosen {
        const id = std.mem.bytesToValue(Atom, data[0..@sizeOf(Atom)]);
        const kind = std.enums.fromInt(Kind, data[@sizeOf(Atom)]) orelse .text;
        return .{ .kind = kind, .id = id };
    }
};

test "the latest visited is listed first, and a visit to the latest writes nothing" {
    var memory: memory_mod.Memory = undefined;
    memory.init(std.testing.allocator);
    defer memory.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&memory);
    defer atoms.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&memory, 16);
    defer tables.deinit();
    const scratch = try memory.tableScratchAllocator();
    try ensure(scratch, &atoms, &tables);
    const first = Atom.from("visits_test_first");
    const second = Atom.from("visits_test_second");
    visit(&tables, .text, first);
    visit(&tables, .figure, second);
    visit(&tables, .text, first);
    const table = tables.findByName(visits_table).?;
    const serial = struct {
        fn of(visits: *Table, id: Atom, kind: Kind) u32 {
            var rows = visits.readQuery(VisitRow);
            while (rows.next()) |found| {
                if (found.view.buffer.* == id and found.view.kind.* == @intFromEnum(kind)) return found.view.serial.*;
            }
            return 0;
        }
    }.of;
    try std.testing.expect(serial(table, first, .text) > serial(table, second, .figure));
    const before = serial(table, first, .text);
    visit(&tables, .text, first);
    try std.testing.expectEqual(before, serial(table, first, .text));
    // The same id of another kind is another buffer.
    try std.testing.expectEqual(@as(u32, 0), serial(table, second, .text));
    try std.testing.expectEqual(@as(usize, 2), table.count());
}
