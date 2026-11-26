//! Table RPC routing into per-document figure tables. These live app-side because only
//! this test root sees both the domain fixture and the mcp module.
const std = @import("std");
const mesha = @import("mesha");
const mesha_runtime = @import("mesha_runtime");
const figure_runtime = mesha_runtime.figure;
const domain = figure_runtime.domain;
const rpc = mesha_runtime.mcp.table_rpc;
const Atom = mesha.Atom;
const Fixture = domain.tests.Fixture;
const t = domain.tables;
const m = domain.model;

fn testUpdate(tables: ?*mesha.Table.Registry, atoms: ?*Atom.Registry, params: ?std.json.Value, w: *std.Io.Writer) anyerror!void {
    return rpc.handleTableUpdate(std.testing.allocator, tables, atoms, params, w);
}
fn testAlloc(tables: ?*mesha.Table.Registry, atoms: ?*Atom.Registry, params: ?std.json.Value, w: *std.Io.Writer) anyerror!void {
    return rpc.handleTableAlloc(std.testing.allocator, tables, atoms, params, w);
}
fn testFree(tables: ?*mesha.Table.Registry, atoms: ?*Atom.Registry, params: ?std.json.Value, w: *std.Io.Writer) anyerror!void {
    return rpc.handleTableFree(std.testing.allocator, tables, atoms, params, w);
}

const Harness = struct {
    fixture: Fixture = undefined,
    arena_state: std.heap.ArenaAllocator = undefined,
    buffer: [32 * 1024]u8 = undefined,
    first: Atom = undefined,
    second: Atom = undefined,

    /// Two documents with distinct bones. The caller owns `self` for the fixture's lifetime.
    fn init(self: *Harness) !void {
        try self.fixture.init();
        self.arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.first = self.fixture.atoms.intern("first");
        self.second = self.fixture.atoms.intern("second");
        try t.createDocument(&self.fixture.tables, &self.fixture.atoms, self.first);
        try t.createDocument(&self.fixture.tables, &self.fixture.atoms, self.second);
        const first_bones = try t.familyHandle(&self.fixture.tables, self.first, "bones");
        const second_bones = try t.familyHandle(&self.fixture.tables, self.second, "bones");
        _ = try t.insert(m.Bone, &self.fixture.tables, first_bones, .{ .doc = self.first, .id = 11, .length = 1 });
        _ = try t.insert(m.Bone, &self.fixture.tables, second_bones, .{ .doc = self.second, .id = 22, .length = 2 });
        _ = try t.insert(m.Bone, &self.fixture.tables, second_bones, .{ .doc = self.second, .id = 23, .length = 3 });
    }

    fn deinit(self: *Harness) void {
        self.arena_state.deinit();
        self.fixture.deinit();
    }

    fn params(self: *Harness, source: []const u8) !std.json.Value {
        return std.json.parseFromSliceLeaky(std.json.Value, self.arena_state.allocator(), source, .{});
    }

    const Handler = *const fn (?*mesha.Table.Registry, ?*Atom.Registry, ?std.json.Value, *std.Io.Writer) anyerror!void;

    fn call(self: *Harness, handler: Handler, source: []const u8) !std.json.ObjectMap {
        const request = try self.params(source);
        var writer = std.Io.Writer.fixed(&self.buffer);
        try handler(&self.fixture.tables, &self.fixture.atoms, request, &writer);
        const response = try self.params(writer.buffered());
        return response.object;
    }

    fn expectFails(self: *Harness, expected: anyerror, handler: Handler, source: []const u8) !void {
        try std.testing.expectError(expected, self.call(handler, source));
    }
};

fn expectString(expected: []const u8, object: std.json.ObjectMap, key: []const u8) !void {
    const value = object.get(key).?;
    try std.testing.expectEqualStrings(expected, value.string);
}

test "figure client table rpc routes a family name to the named document" {
    var h: Harness = .{};
    try h.init();
    defer h.deinit();
    const first = try h.call(rpc.handleTableQuery, "{\"table\":\"figure_bones\",\"doc\":\"first\"}");
    try expectString("figure_bones", first, "table");
    try expectString("first", first, "doc");
    try std.testing.expectEqual(@as(i64, 1), first.get("count").?.integer);
    const second = try h.call(rpc.handleTableQuery, "{\"table\":\"figure_bones\",\"doc\":\"second\"}");
    try expectString("second", second, "doc");
    try std.testing.expectEqual(@as(i64, 2), second.get("count").?.integer);
    const rows = second.get("rows").?.array;
    const row_fields = rows.items[0].object.get("fields").?.object;
    try std.testing.expectEqual(@as(i64, 22), row_fields.get("id").?.integer);
    // The legacy name keys route the same way, and the bone-world table is a document table too.
    const legacy = try h.call(rpc.handleTableGetSchema, "{\"table_name\":\":figure_bones\",\"doc\":\":first\"}");
    try expectString("first", legacy, "doc");
    const world = try h.call(rpc.handleTableGetSchema, "{\"name\":\"figure_bone_world\",\"doc\":\"second\"}");
    try expectString("figure_bone_world", world, "table");
}

test "figure client table rpc requires a document and rejects unknown ones" {
    var h: Harness = .{};
    try h.init();
    defer h.deinit();
    const atoms_before = h.fixture.atoms.storage();
    try h.expectFails(error.FigureDocumentRequired, rpc.handleTableQuery, "{\"table\":\"figure_bones\"}");
    try h.expectFails(error.FigureDocumentRequired, testUpdate, "{\"table\":\"figure_bones\",\"row\":0,\"fields\":{}}");
    try h.expectFails(error.UnknownFigureDocument, rpc.handleTableQuery, "{\"table\":\"figure_bones\",\"doc\":\"never_opened\"}");
    try h.expectFails(error.InvalidParams, rpc.handleTableQuery, "{\"table\":\"figure_bones\",\"doc\":7}");
    // Rejected routing leaves atom storage alone.
    try std.testing.expectEqual(atoms_before, h.fixture.atoms.storage());
    // A table that is not per-document keeps its name-only contract.
    const documents = try h.call(rpc.handleTableQuery, "{\"table\":\"figure_documents\"}");
    try std.testing.expectEqual(@as(i64, 2), documents.get("count").?.integer);
}

test "figure client table rpc lists tables in pages that add up to the whole" {
    var h: Harness = .{};
    try h.init();
    defer h.deinit();
    var whole_writer = std.Io.Writer.fixed(&h.buffer);
    try rpc.handleTableList(&h.fixture.tables, &h.fixture.atoms, null, &whole_writer);
    // Parsed strings can point into their source, and the pages below reuse the buffer.
    const whole_bytes = try h.arena_state.allocator().dupe(u8, whole_writer.buffered());
    const whole = (try h.params(whole_bytes)).object;
    const total = whole.get("total").?.integer;
    try std.testing.expectEqual(total, @as(i64, @intCast(whole.get("tables").?.array.items.len)));
    var collected: i64 = 0;
    while (collected < total) {
        var request_buffer: [64]u8 = undefined;
        const request = try std.fmt.bufPrint(&request_buffer, "{{\"offset\":{d},\"limit\":5}}", .{collected});
        var writer = std.Io.Writer.fixed(&h.buffer);
        try rpc.handleTableList(&h.fixture.tables, &h.fixture.atoms, try h.params(request), &writer);
        const page = (try h.params(writer.buffered())).object;
        try std.testing.expectEqual(total, page.get("total").?.integer);
        const entries = page.get("tables").?.array.items;
        try std.testing.expect(entries.len > 0 and entries.len <= 5);
        const first_name = entries[0].object.get("name").?.string;
        try std.testing.expectEqualStrings(whole.get("tables").?.array.items[@intCast(collected)].object.get("name").?.string, first_name);
        collected += @intCast(entries.len);
    }
    try std.testing.expectEqual(total, collected);
    var bad_writer = std.Io.Writer.fixed(&h.buffer);
    try std.testing.expectError(error.InvalidParams, rpc.handleTableList(&h.fixture.tables, &h.fixture.atoms, try h.params("{\"limit\":-1}"), &bad_writer));
}

test "figure client table rpc labels document tables in table list" {
    var h: Harness = .{};
    try h.init();
    defer h.deinit();
    var writer = std.Io.Writer.fixed(&h.buffer);
    try rpc.handleTableList(&h.fixture.tables, &h.fixture.atoms, null, &writer);
    const response = try h.params(writer.buffered());
    var first_count: usize = 0;
    var second_count: usize = 0;
    var labelled_bones: usize = 0;
    for (response.object.get("tables").?.array.items) |item| {
        const entry = item.object;
        try std.testing.expect(!std.mem.eql(u8, entry.get("name").?.string, "<unnamed>"));
        const doc = entry.get("doc") orelse continue;
        try std.testing.expectEqualStrings(entry.get("name").?.string, entry.get("family").?.string);
        try std.testing.expect(entry.get("handle") != null and entry.get("fields") != null);
        if (std.mem.eql(u8, doc.string, "first")) first_count += 1;
        if (std.mem.eql(u8, doc.string, "second")) second_count += 1;
        if (!std.mem.eql(u8, entry.get("name").?.string, "figure_bones")) continue;
        labelled_bones += 1;
        const expected: i64 = if (std.mem.eql(u8, doc.string, "first")) 1 else 2;
        try std.testing.expectEqual(expected, entry.get("count").?.integer);
    }
    try std.testing.expectEqual(m.authoring.len + 1, first_count);
    try std.testing.expectEqual(m.authoring.len + 1, second_count);
    try std.testing.expectEqual(@as(usize, 2), labelled_bones);
}

test "figure client table rpc writes reach only the routed document and keep owner validation" {
    var h: Harness = .{};
    try h.init();
    defer h.deinit();
    const tables = &h.fixture.tables;
    const first_table = try t.boneTable(tables, h.first);
    const second_table = try t.boneTable(tables, h.second);
    var first_rows = first_table.query(t.Bone);
    const first_row = first_rows.next().?;
    const second_revision = second_table.revision;
    const row_index = first_row.handle.row;

    var request_buffer: [256]u8 = undefined;
    const update = try std.fmt.bufPrint(&request_buffer, "{{\"table\":\"figure_bones\",\"doc\":\"first\",\"row\":{d},\"fields\":{{\"length\":9}}}}", .{row_index});
    const updated = try h.call(testUpdate, update);
    try expectString("first", updated, "doc");
    try std.testing.expectEqual(@as(f32, 9), first_row.view.length.*);
    try std.testing.expectEqual(second_revision, second_table.revision);

    // Moving a row to a peer would hide it from both documents; the write rolls back.
    const stolen = try std.fmt.bufPrint(&request_buffer, "{{\"table\":\"figure_bones\",\"doc\":\"first\",\"row\":{d},\"fields\":{{\"doc\":\"second\",\"length\":5}}}}", .{row_index});
    try h.expectFails(error.InvalidOwnerState, testUpdate, stolen);
    try std.testing.expectEqual(h.first, first_row.view.doc.*);
    try std.testing.expectEqual(@as(f32, 9), first_row.view.length.*);

    // Addressing the table by handle is held to the same owner.
    const first_handle = try t.familyHandle(tables, h.first, "bones");
    const by_handle = try std.fmt.bufPrint(&request_buffer, "{{\"table\":{{\"index\":{d},\"generation\":{d}}},\"row\":{d},\"fields\":{{\"doc\":\"second\"}}}}", .{ first_handle.index, first_handle.generation, row_index });
    try h.expectFails(error.InvalidOwnerState, testUpdate, by_handle);
    const mismatched = try std.fmt.bufPrint(&request_buffer, "{{\"table\":{{\"index\":{d},\"generation\":{d}}},\"doc\":\"second\"}}", .{ first_handle.index, first_handle.generation });
    try h.expectFails(error.FigureDocumentMismatch, rpc.handleTableQuery, mismatched);

    // A routed insert belongs to the routed document without repeating it, and a row
    // naming a peer is released rather than left behind.
    const count_before = first_table.count();
    const allocated = try h.call(testAlloc, "{\"table\":\"figure_bones\",\"doc\":\"first\",\"fields\":{\"id\":40}}");
    try expectString("first", allocated.get("fields").?.object, "doc");
    try std.testing.expectEqual(count_before + 1, first_table.count());
    try h.expectFails(error.InvalidOwnerState, testAlloc, "{\"table\":\"figure_bones\",\"doc\":\"first\",\"fields\":{\"doc\":\"second\"}}");
    try std.testing.expectEqual(count_before + 1, first_table.count());

    const row_after_alloc: i64 = allocated.get("row").?.integer;
    const free_request = try std.fmt.bufPrint(&request_buffer, "{{\"table\":\"figure_bones\",\"doc\":\"first\",\"row\":{d}}}", .{row_after_alloc});
    const freed = try h.call(testFree, free_request);
    try expectString("first", freed, "doc");
    try std.testing.expectEqual(count_before, first_table.count());
}

test "figure client table rpc keeps the document catalog matched to its records" {
    var h: Harness = .{};
    try h.init();
    defer h.deinit();
    const catalog = t.documentTable(&h.fixture.tables, &h.fixture.atoms);
    const row = t.findDocument(&h.fixture.tables, &h.fixture.atoms, h.first).?;
    var request_buffer: [160]u8 = undefined;
    const rename = try std.fmt.bufPrint(&request_buffer, "{{\"table\":\"figure_documents\",\"row\":{d},\"fields\":{{\"doc\":\"renamed\"}}}}", .{row.row});
    try h.expectFails(error.InvalidOwnerState, testUpdate, rename);
    try std.testing.expect(t.findDocument(&h.fixture.tables, &h.fixture.atoms, h.first) != null);
    const remove = try std.fmt.bufPrint(&request_buffer, "{{\"table\":\"figure_documents\",\"row\":{d}}}", .{row.row});
    try h.expectFails(error.InvalidOwnerState, testFree, remove);
    try std.testing.expectEqual(@as(u32, 2), catalog.count());
    try std.testing.expect(catalog.valid(row));
    // Other catalog fields stay raw-writable as a debugging escape hatch.
    const edit = try std.fmt.bufPrint(&request_buffer, "{{\"table\":\"figure_documents\",\"row\":{d},\"fields\":{{\"next_id\":77}}}}", .{row.row});
    _ = try h.call(testUpdate, edit);
}

test "figure client table rpc cannot reach a closed document's tables" {
    var h: Harness = .{};
    try h.init();
    defer h.deinit();
    const stale = try t.familyHandle(&h.fixture.tables, h.first, "bones");
    t.removeDocument(&h.fixture.tables, &h.fixture.atoms, h.first);
    try h.expectFails(error.UnknownFigureDocument, rpc.handleTableQuery, "{\"table\":\"figure_bones\",\"doc\":\"first\"}");
    var request_buffer: [128]u8 = undefined;
    const by_handle = try std.fmt.bufPrint(&request_buffer, "{{\"table\":{{\"index\":{d},\"generation\":{d}}}}}", .{ stale.index, stale.generation });
    try h.expectFails(error.TableNotFound, rpc.handleTableQuery, by_handle);
    // The peer stays reachable.
    const second = try h.call(rpc.handleTableQuery, "{\"table\":\"figure_bones\",\"doc\":\"second\"}");
    try std.testing.expectEqual(@as(i64, 2), second.get("count").?.integer);
}
