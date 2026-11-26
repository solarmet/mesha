const std = @import("std");
const mesha = @import("mesha");
const table_document_mod = mesha.table_document;
const Atom = mesha.Atom;
const memory_mod = mesha.memory;
const Table = mesha.Table;
const resources_mod = mesha.resources;
const state_mod = @import("state.zig");
const sequencer = mesha.sequencer;
const tracker = mesha.tracker;

const Log = mesha.log.scope("authoring");
const inspector = @import("inspector.zig");

pub fn fieldLabel(desc: *const Table.FieldDescriptor, buf: []u8) []const u8 {
    const ft: []const u8 = if (Table.durableFieldType(desc)) |t| @tagName(t) else "opaque";
    return switch (desc.view_kind) {
        .float_slider => |cfg| std.fmt.bufPrint(buf, "{s} [{d}..{d}]", .{ ft, cfg.min, cfg.max }) catch ft,
        .text_field => if (desc.field_type == .string) "string" else std.fmt.bufPrint(buf, "text len {d}", .{desc.size}) catch ft,
        else => ft,
    };
}

pub fn assetRow(tables: *Table.Registry, atoms: *Atom.Registry, id: Atom) ?resources_mod.TableAssetView {
    const assets = tables.findByName(atoms.intern(resources_mod.table_assets_name)) orelse return null;
    var q = assets.query(resources_mod.TableAssetView);
    while (q.next()) |item| {
        if (item.view.id.* == id) return item.view;
    }
    return null;
}

pub fn markDirty(tables: *Table.Registry, atoms: *Atom.Registry, id: Atom) void {
    if (tables.findByName(id)) |table| {
        if (table.owner != .editor) {
            Log.warn("editing_unowned_table", .{ .table = table.name, .owner = @tagName(table.owner) });
        }
    }
    if (assetRow(tables, atoms, id)) |row| row.dirty.* = 1;
}

pub fn isDirty(tables: *Table.Registry, atoms: *Atom.Registry, id: Atom) bool {
    const row = assetRow(tables, atoms, id) orelse return false;
    return row.dirty.* != 0;
}

/// Sets the status line, a string cell of `table`, the table the authoring state's row is
/// in. A status that cannot be kept leaves the line as it was.
pub fn setStatus(table: *Table, ui: state_mod.AuthoringUiView, comptime fmt: []const u8, args: anytype) void {
    const length = std.fmt.count(fmt, args);
    const payload = table.allocatePayload(length, .@"1") catch return;
    // Printed where it lies: the line has no bound to stage it in.
    _ = std.fmt.bufPrint(table.payloadBytesMut(payload), fmt, args) catch unreachable;
    ui.status.* = .{ .payload = payload };
}

pub fn clearStatus(ui: state_mod.AuthoringUiView) void {
    ui.status.* = .{};
}

pub const RowOpError = error{ TableFull, StaleTarget, OwnerManagedRows };

pub fn addRow(tables: *Table.Registry, atoms: *Atom.Registry, target: Table.Handle) RowOpError!Table.RowHandle {
    const table = tables.get(target) orelse return error.StaleTarget;
    if (resources_mod.isOwnerManagedTable(table, atoms)) return error.OwnerManagedRows;
    const handle = table.alloc() catch return error.TableFull;
    markDirty(tables, atoms, table.name);
    return handle;
}

pub fn deleteRow(tables: *Table.Registry, atoms: *Atom.Registry, target: Table.Handle, row: u32) RowOpError!void {
    const table = tables.get(target) orelse return error.StaleTarget;
    if (resources_mod.isOwnerManagedTable(table, atoms)) return error.OwnerManagedRows;
    table.free(.{ .row = row, .generation = table.rowGeneration(row) });
    markDirty(tables, atoms, table.name);
}

pub const MetadataError = error{
    OutOfMemory,
    InvalidKey,
    ValueTooLong,
    NotUtf8,
    DuplicateKey,
    KeyTooLong,
};

pub fn setMetadataEntry(
    tables: *Table.Registry,
    atoms: *Atom.Registry,
    id: Atom,
    key: []const u8,
    value: []const u8,
    original_key: []const u8,
) MetadataError!void {
    if (!table_document_mod.validKey(key)) return error.InvalidKey;
    if (key.len >= resources_mod.kMetadataKeyBytes) return error.KeyTooLong;
    if (value.len > table_document_mod.kMaxMetadataValueBytes) return error.ValueTooLong;
    if (!std.unicode.utf8ValidateSlice(value)) return error.NotUtf8;
    const meta = resources_mod.metadataTable(tables, atoms) orelse return error.OutOfMemory;

    var dup_it = resources_mod.metadataRows(meta, id);
    while (dup_it.next()) |row| {
        const existing = row.view.key;
        const is_self = original_key.len > 0 and std.mem.eql(u8, existing, original_key);
        if (!is_self and std.mem.eql(u8, existing, key)) return error.DuplicateKey;
    }

    if (original_key.len > 0) {
        var rm_it = resources_mod.metadataRows(meta, id);
        while (rm_it.next()) |row| {
            if (std.mem.eql(u8, row.view.key, original_key)) meta.free(row.handle);
        }
    }

    const handle = meta.alloc() catch return error.OutOfMemory;
    resources_mod.writeMetadataRow(meta, handle, id, key, value) catch |err| {
        meta.free(handle);
        return switch (err) {
            error.KeyTooLong => error.KeyTooLong,
            error.ValueTooLong => error.ValueTooLong,
            error.OutOfMemory, error.Overflow, error.StaleHandle, error.UnknownField => error.OutOfMemory,
        };
    };
    markDirty(tables, atoms, id);
}

pub fn deleteMetadataEntry(tables: *Table.Registry, atoms: *Atom.Registry, id: Atom, key: []const u8) void {
    const meta = resources_mod.metadataTable(tables, atoms) orelse return;
    var it = resources_mod.metadataRows(meta, id);
    while (it.next()) |row| {
        if (std.mem.eql(u8, row.view.key, key)) meta.free(row.handle);
    }
    markDirty(tables, atoms, id);
}

// ---- changes to a table's shape -----------------------------------------------------------
//
// A tracker is a table made or destroyed whole. A sequencer's journal undoes row writes, not
// these, so the editor asks for them as rows of `commands.table_authoring`, which a host
// system applies. It runs first in the editor's run, before any system this frame copies a
// row of a table it destroys into the run's layer. What each request came to is a row of
// `table_authoring_outcomes`, for the table windows. A table's columns are its schema's,
// which code declares: the editor does not change them.

pub const Request = union(enum) {
    /// `query` is the text the tracker prompt was answered with, for asking again.
    create_tracker: struct { suffix: []const u8, query: []const u8 },
    delete_tracker: struct { definition: Atom, reason: DeleteReason },
};

/// Whether the person asked to delete the tracker, or one just made could not be shown.
pub const DeleteReason = enum(u8) { asked, unopened };

pub const TrackerCreateError = error{ DuplicateTableName, CreateFailed };

pub const Outcome = union(enum) {
    tracker_created: struct { query: []const u8, result: union(enum) { created: Atom, failed: TrackerCreateError } },
    tracker_deleted: struct { definition: Atom, reason: DeleteReason, deleted: bool },
};

pub const requests_table_name = "commands.table_authoring";
pub const Requests = sequencer.Commands(Request);
pub const outcomes_table_name = "table_authoring_outcomes";
pub const Outcomes = sequencer.Commands(Outcome);

/// Asks for `wanted`, applied at the start of the editor's next run.
pub fn request(memory: *memory_mod.Memory, tables: *Table.Registry, wanted: Request) void {
    Requests.of(memory, tables, requests_table_name).push(wanted);
}

pub fn ensureTables(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    try Requests.ensure(scratch, atoms, tables, requests_table_name);
    try Outcomes.ensure(scratch, atoms, tables, outcomes_table_name);
}

/// A host system: what it does to tables no fault takes back.
pub fn system() sequencer.System {
    return .{
        .name = "table_authoring",
        .root = inspector.inspector_root,
        .claims = sequencer.claims_nothing,
        .access = access,
        .kernels = &.{.{ .name = "table_authoring.apply", .run = applyRequests }},
        .mode = .host,
    };
}

fn access(frame: *const sequencer.Frame) sequencer.Access {
    _ = frame;
    var result: sequencer.Access = .{};
    result.write(Atom.from(requests_table_name));
    result.write(Atom.from(outcomes_table_name));
    return result;
}

const Applying = struct {
    frame: *const sequencer.Frame,
    outcomes: Outcomes,

    fn apply(applying: *Applying, wanted: *Request) sequencer.Applied {
        const frame = applying.frame;
        const outcome: Outcome = switch (wanted.*) {
            .create_tracker => |creating| .{ .tracker_created = .{ .query = creating.query, .result = createTracker(frame, creating.suffix) } },
            .delete_tracker => |deleting| .{ .tracker_deleted = .{ .definition = deleting.definition, .reason = deleting.reason, .deleted = deleteTracker(frame, deleting.definition) } },
        };
        // A full outcome table is logged by the push; the change itself stands.
        applying.outcomes.push(outcome);
        return .done;
    }
};

fn applyRequests(pass: *sequencer.Pass) !void {
    const frame = pass.frame;
    const requests = Requests.of(frame.memory, frame.tables, requests_table_name);
    if (requests.count() == 0) return;
    var applying: Applying = .{ .frame = frame, .outcomes = Outcomes.of(frame.memory, frame.tables, outcomes_table_name) };
    requests.drain(&applying, Applying.apply);
}

fn createTracker(frame: *const sequencer.Frame, suffix: []const u8) @FieldType(@FieldType(Outcome, "tracker_created"), "result") {
    const scratch = frame.memory.frameScratchAllocator() catch return .{ .failed = error.CreateFailed };
    const handle = tracker.create(scratch.allocator, frame.atoms, frame.tables, suffix) catch |err| {
        const failure: TrackerCreateError = if (err == error.DuplicateTableName) error.DuplicateTableName else error.CreateFailed;
        return .{ .failed = failure };
    };
    return .{ .created = frame.tables.get(handle).?.name };
}

fn deleteTracker(frame: *const sequencer.Frame, definition: Atom) bool {
    const handle = frame.tables.findHandleByName(definition) orelse return false;
    tracker.delete(frame.atoms, frame.tables, handle) catch return false;
    return true;
}

const testing = std.testing;

test "engine-managed resource rows cannot be added or deleted from the editor" {
    var memory: memory_mod.Memory = undefined;
    memory.init(testing.allocator);
    defer memory.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&memory);
    defer atoms.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&memory, 4);
    defer tables.deinit();
    const table = try resources_mod.createRowTable(&tables, &atoms, testing.allocator, 2);
    const handle = tables.findHandleByName(table.name).?;
    try testing.expectError(error.OwnerManagedRows, addRow(&tables, &atoms, handle));
    try testing.expectError(error.OwnerManagedRows, deleteRow(&tables, &atoms, handle, 0));
    try testing.expectEqual(@as(u32, 0), table.count());
}

test "row add and delete mark the catalog dirty with automatic growth" {
    var atoms: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try atoms.init(&mem);
    defer atoms.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&mem, 8);
    defer tables.deinit();
    try resources_mod.ensureTableAssetCatalog(testing.allocator, &atoms, &tables);

    var schema: Table.Schema = undefined;
    try schema.init(testing.allocator, &atoms, 1);
    defer schema.deinit();
    schema.addField("value", i32, .int);
    const handle = try tables.create(&schema, 2, atoms.intern("auth.rows"), .durable);
    const table = tables.get(handle).?;

    const assets = tables.findByName(atoms.intern(resources_mod.table_assets_name)).?;
    const arow = try assets.alloc();
    const aview = assets.getRow(arow, resources_mod.TableAssetView).?;
    aview.id.* = atoms.intern("auth.rows");
    aview.state.* = @intFromEnum(resources_mod.TableAssetState.attached);
    aview.dirty.* = 0;
    aview.persistable.* = 1;
    aview.disk_present.* = 0;
    aview.conflict.* = 0;
    aview.fingerprint.* = 0;
    aview.table_index.* = 0;
    aview.table_generation.* = 0;
    aview.error_code.* = 0;
    assets.setRowMask(arow, aview);

    const id = atoms.intern("auth.rows");
    try testing.expect(!isDirty(&tables, &atoms, id));
    const r = try addRow(&tables, &atoms, handle);
    try testing.expect(table.valid(r));
    try testing.expect(isDirty(&tables, &atoms, id));
    const r2 = try addRow(&tables, &atoms, handle);
    const r3 = try addRow(&tables, &atoms, handle);
    try deleteRow(&tables, &atoms, handle, r3.row);

    try deleteRow(&tables, &atoms, handle, r2.row);
    try deleteRow(&tables, &atoms, handle, r.row);
    try testing.expectEqual(@as(u32, 0), table.count());

    try testing.expectEqual(@as(u32, 0), table.count());
}

test "metadata entry CRUD validates keys and values and marks dirty" {
    var atoms: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try atoms.init(&mem);
    defer atoms.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&mem, 4);
    defer tables.deinit();
    try resources_mod.ensureTableAssetCatalog(testing.allocator, &atoms, &tables);
    const id = atoms.intern("auth.meta");

    try setMetadataEntry(&tables, &atoms, id, "owner", "narrative", "");
    try testing.expectError(error.InvalidKey, setMetadataEntry(&tables, &atoms, id, "Owner", "x", ""));
    try testing.expectError(error.DuplicateKey, setMetadataEntry(&tables, &atoms, id, "owner", "other", ""));

    try setMetadataEntry(&tables, &atoms, id, "keeper", "narrative", "owner");
    const entries = try resources_mod.metadataFor(testing.allocator, &tables, &atoms, id);
    defer {
        for (entries) |e| {
            testing.allocator.free(e.key);
            testing.allocator.free(e.value);
        }
        testing.allocator.free(entries);
    }
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("keeper", entries[0].key);

    deleteMetadataEntry(&tables, &atoms, id, "keeper");
    const empty = try resources_mod.metadataFor(testing.allocator, &tables, &atoms, id);
    defer testing.allocator.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
}
