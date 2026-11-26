//! The figure document: editor-owned asynchronous admission of requests to the host, and
//! reconciliation of their terminal results.
const std = @import("std");
const mesha = @import("mesha");
const api = mesha.figure;
const Atom = mesha.Atom;
const names = @import("names.zig");
const figure = mesha.figure;
const plugin = mesha.plugin;
const Table = mesha.Table;
const action_palette = @import("../action_palette.zig");
const gesture = @import("gesture.zig");
const preview = @import("preview.zig");
const prompts = @import("prompts.zig");
const session = @import("session.zig");
const sketches = @import("sketches.zig");
const watches = @import("watches.zig");
const workspace = @import("workspace.zig");
const sequencer = mesha.sequencer;

const Log = mesha.log.scope("figure_editor");
/// This file's profile zones, in its log scope.
const Zone = enum { consume_result };

// ---- the system -----------------------------------------------------------------------------

/// The document: follows the host's catalog of definitions, takes the host's results for the
/// requests the editor sent, activates a document waiting to open, and keeps the editor's
/// view of the open definition (its active layer, dirtiness and bounds) current. It runs
/// first, so every other system acts on the document as the host now holds it.
pub fn system() sequencer.System {
    return .{
        .name = "figure_document",
        .names = comptime &workspace.vocabulary,
        .root = workspace.figure_root,
        .claims = claims,
        .active = active,
        .access = access,
        .kernels = &.{
            .{ .name = "figure_document.observe_catalog", .run = observeCatalog },
            .{ .name = "figure_document.take_results", .run = takeResults },
            .{ .name = "figure_document.activate_pending", .run = activatePending },
            .{ .name = "figure_document.follow_definition", .run = followDefinition },
        },
    };
}

/// The tag of the host's results for the editor's requests.
pub const Msg = enum(u64) {
    editor_figure_result = Atom.from("editor_figure_result").value(),
    _,
};

fn claims(tag: Atom) bool {
    return switch (tag.to(Msg)) {
        _ => false,
        else => true,
    };
}

/// Hidden, the document still follows the host's catalog, and opens a document it waits for
/// once the host has it ready.
fn active(frame: *const sequencer.Frame) bool {
    if (workspace.shown(frame)) return true;
    if (catalogMoved(frame)) return true;
    return session.get(frame.tables).pending_doc.* != session.none;
}

/// Every frame, the editor's document fields. A catalog change or a result may rename the
/// document or reconcile an edit in any of the editor's tables, so then all of them.
fn access(frame: *const sequencer.Frame) sequencer.Access {
    const groups = workspace.table_groups;
    var result: sequencer.Access = .{};
    // The host's publications the system's reads come from.
    watches.declareReads(&result);
    result.readAll(&groups.state);
    result.writeAll(&.{ groups.editor, groups.observed });
    if (frame.tables.findByName(catalog_table) != null) result.read(catalog_table);
    if (frame.messages.len != 0 or catalogMoved(frame)) {
        groups.declareEditing(&result);
        // A figure closed moves the stage on to another buffer.
        workspace.declareAfterClose(&result, frame.tables);
    }
    return result;
}

const catalog_table = Atom.from(api.catalog_table_name);

/// The version of the host's catalog of definitions; 0 before the host publishes one.
fn catalogVersion(tables: *Table.Registry) u64 {
    const catalog = tables.findByName(catalog_table) orelse return 0;
    const row: Table.RowHandle = .{ .row = 0, .generation = catalog.rowGeneration(0) };
    const view = catalog.readRow(row, api.CatalogView) orelse return 0;
    return view.version.*;
}

/// Whether the catalog changed since the editor last saw it, or the open document did, since
/// the editor last followed it.
fn catalogMoved(frame: *const sequencer.Frame) bool {
    const observed = session.observed(frame.tables);
    if (catalogVersion(frame.tables) != observed.catalog_version.*) return true;
    return observed.catalog_dirty.* != 0 or observed.doc.* != session.get(frame.tables).doc.*;
}

/// Notes the catalog's version, then, if the catalog or the open document changed, follows
/// the document's identity: through a rename, or out when it closed.
fn observeCatalog(pass: *sequencer.Pass) !void {
    const frame = pass.frame;
    const context: figure.Context = .{ .memory = frame.memory, .tables = frame.tables, .atoms = frame.atoms };
    if (!catalogMoved(frame)) return;
    const version = catalogVersion(frame.tables);
    if (version != session.observed(frame.tables).catalog_version.*) consumeCatalog(context, version);
    const scratch = try frame.memory.frameScratchAllocator();
    observeIfChanged(context, scratch.allocator) catch |err| prompts.status(session.table(frame.tables), session.get(frame.tables), session.feedback(frame.tables), @errorName(err));
}

/// Each result the host sent for a request of the editor's, in arrival order.
fn takeResults(pass: *sequencer.Pass) !void {
    const frame = pass.frame;
    const context: figure.Context = .{ .memory = frame.memory, .tables = frame.tables, .atoms = frame.atoms };
    for (frame.messages) |received| {
        if (received.tag.to(Msg) != .editor_figure_result) continue;
        const result = received.payloadAs(figure.Result) catch |err| {
            received.unreadable(err);
            continue;
        };
        _ = consume(context, result.*);
    }
}

/// A document asked for before any was open becomes the open one once the host has it ready,
/// unless it closed in the meantime.
fn activatePending(pass: *sequencer.Pass) !void {
    const tables = pass.frame.tables;
    const atoms = pass.frame.atoms;
    const editor = session.get(tables);
    const waiting = editor.pending_action.* == session.none and editor.doc.* == session.none and editor.pending_doc.* != session.none;
    if (!waiting) return;
    const info = session.definitionInfo(tables, atoms, editor.pending_doc.*) orelse return;
    if (info.state != .ready) return;
    if (info.editor_open) editor.doc.* = editor.pending_doc.*;
    editor.pending_doc.* = session.none;
}

/// The open definition's active layer, dirtiness and bounds, and the fit a new document asked
/// for.
fn followDefinition(pass: *sequencer.Pass) !void {
    const tables = pass.frame.tables;
    const atoms = pass.frame.atoms;
    const editor = session.get(tables);
    var reads = session.ReadContext{ .tables = tables, .atoms = atoms };
    defer reads.deinit();
    if (reads.definition(editor.doc.*)) |definition| {
        const layers = definition.layers;
        if (session.findById(api.read.Layer, layers, editor.active_layer.*) == null) editor.active_layer.* = if (layers.len != 0) layers[0].id else 0;
    } else |_| {}
    if (session.definitionInfo(tables, atoms, editor.doc.*)) |info| editor.dirty.* = @intFromBool(info.dirty);
    workspace.syncFigureBounds(tables, atoms);
    if (editor.fit_pending.* != 0) workspace.fitCanvas(tables, atoms);
}

const Metadata = session.Metadata;

/// Reserves bounded UX metadata, then asks the figure host for `payload`. Serial is never
/// reused, even after a refused request. Explicit UX transaction request IDs are preserved.
pub fn submit(context: figure.Context, payload: api.Payload) !u32 {
    const pending_table = session.pendingCommands(context.tables);
    if (pending_table.count() >= session.pending_capacity) return error.CapacityExceeded;
    const editor = session.get(context.tables);
    const payload_metadata = Metadata.from(payload);
    const supplied_request = payload_metadata.request;
    if (supplied_request == 0 and editor.request_serial.* >= 0x7fffffff) return error.CapacityExceeded;
    if (supplied_request == 0) editor.request_serial.* += 1;
    const request = if (supplied_request == 0) editor.request_serial.* else supplied_request;
    if (request < 0x80000000) editor.request_serial.* = @max(editor.request_serial.*, request);
    var request_payload = payload;
    switch (request_payload) {
        inline else => |*command_payload| command_payload.request = request,
    }
    const metadata = Metadata.from(request_payload);
    var existing = pending_table.read();
    while (existing.next()) |entry| {
        if (entry.view.doc.* == metadata.doc and entry.view.request.* == request) return error.Busy;
    }
    const row = try pending_table.alloc();
    errdefer pending_table.free(row);
    session.writeRow(session.Pending, pending_table.table, row, .{
        .doc = metadata.doc,
        .current_doc = metadata.doc,
        .request = request,
        .operation = @intFromEnum(metadata.operation),
        .capture_frame = metadata.capture_frame,
    });
    errdefer {
        if (metadata.operation == .close_doc) preview.reopen(preview.state(context.tables));
    }
    if (metadata.operation == .close_doc and metadata.doc == editor.doc.*) {
        preview.closing(preview.state(context.tables));
    }
    try figure.appendRequest(context, .{
        .payload = request_payload,
        // Results come back to the document system, whoever sent the request.
        .reply = sequencer.ReplyTo.of(system(), .from(Msg.editor_figure_result)),
    });
    const observed = session.observed(context.tables);
    if (metadata.operation == .save_doc and editor.close_after_save.* != 0 and observed.close_request.* == 0) {
        observed.close_doc.* = metadata.doc;
        observed.close_request.* = request;
    }
    return request;
}

/// Callback-scoped sender boundary; retains no services.
pub fn send(tables: *Table.Registry, atoms: *Atom.Registry, payload: api.Payload) !void {
    _ = try submit(.{ .memory = tables.memory, .tables = tables, .atoms = atoms }, payload);
}

/// The sentence a person reads for a figure or sketch save the figure system refused, from the
/// refusal's text (`diagnostic`) and the file the save named (`save_path`, empty when the
/// editor does not know it): the folder that does not exist, or the document open elsewhere
/// that holds the name. Any other refusal reads as its text.
pub fn saveRefusalText(buffer: []u8, diagnostic: []const u8, save_path: []const u8) []const u8 {
    if (std.mem.eql(u8, diagnostic, "directory_missing")) {
        const folder = std.fs.path.dirname(save_path) orelse "";
        if (folder.len == 0) return "Not saved: the folder does not exist.";
        return std.fmt.bufPrint(buffer, "Not saved: the folder {s} does not exist.", .{folder}) catch "Not saved: the folder does not exist.";
    }
    const taken_alone = "Not saved: another open figure or sketch has this name.";
    if (std.mem.eql(u8, diagnostic, "id_taken")) return taken_alone;
    const taken_by = "id_taken: ";
    if (std.mem.startsWith(u8, diagnostic, taken_by)) {
        const holder = diagnostic[taken_by.len..];
        if (holder.len == 0) return taken_alone;
        return std.fmt.bufPrint(buffer, "Not saved: another open figure or sketch, {s}, has this name.", .{holder}) catch taken_alone;
    }
    return diagnostic;
}

/// Returns false for unknown/duplicate results. Only terminal host results enter
/// this path: enqueue success never changes selection, prompts or close state.
pub fn consume(context: figure.Context, result: api.Result) bool {
    const trace_zone = Log.zone(Zone.consume_result);
    defer trace_zone.end();
    const pending_table = session.pendingCommands(context.tables);
    var rows = pending_table.read();
    while (rows.next()) |row| {
        if (row.view.doc.* != result.definition or row.view.request.* != result.request or row.view.operation.* != @intFromEnum(result.operation)) continue;
        const current_doc = row.view.current_doc.*;
        var reconciliation_doc = if (row.view.rename_observed.* != 0) current_doc else result.current_definition;
        const activates = result.outcome == .success and (result.operation == .new_doc or result.operation == .load_doc);
        if (activates) reconciliation_doc = activation: {
            const identity = result.definition_handle orelse break :activation api.none;
            const entries = figure.listDefinitions(context, context.memory.globalAllocator()) catch break :activation api.none;
            defer context.memory.globalAllocator().free(entries);
            for (entries) |entry| {
                if (std.meta.eql(identity, entry.handle) and entry.info.editor_open) break :activation entry.info.definition;
            }
            break :activation api.none;
        };
        const metadata = Metadata{
            .doc = reconciliation_doc,
            .request = result.request,
            .operation = result.operation,
            .capture_frame = row.view.capture_frame.*,
        };
        pending_table.free(row.handle);
        const editor = session.get(context.tables);
        const observed = session.observed(context.tables);
        const closes = result.operation == .save_doc and observed.close_doc.* == result.definition and observed.close_request.* == result.request;
        if (closes) {
            observed.close_doc.* = api.none;
            observed.close_request.* = 0;
        }
        const failed = result.outcome == .failure;
        if (result.operation == .close_doc) preview.reopen(preview.state(context.tables));
        if (!failed and reconciliation_doc != api.none and reconciliation_doc != current_doc) workspace.renameDocument(context.tables, current_doc, reconciliation_doc);
        const command_result: anyerror!?u32 = switch (result.outcome) {
            .success => result.created_id,
            .failure => |err| err,
        };
        // Attribution is read before reconciliation releases the request.
        const request_owner = gesture.requestOwner(gesture.get(context.tables), reconciliation_doc, result.request);
        const pose_owned = request_owner == .pose;
        workspace.reconcileResult(context.tables, context.atoms, metadata, command_result);
        if (failed) {
            if (result.definition == editor.doc.* or reportsFailure(result.operation)) {
                var buffer: [192]u8 = undefined;
                const diagnostic = session.text(&result.diagnostic);
                const save_path = session.table(context.tables).textOf(editor.pending_path.*);
                // A sketch's save path is the sketch row's, which the editor does not keep here.
                const explained = switch (result.operation) {
                    .save_doc => saveRefusalText(&buffer, diagnostic, save_path),
                    .save_sketch => saveRefusalText(&buffer, diagnostic, ""),
                    else => diagnostic,
                };
                const diagnostic_text = if (pose_owned) std.fmt.bufPrint(&buffer, "Pose edit rejected: {s}", .{diagnostic}) catch diagnostic else explained;
                prompts.status(session.table(context.tables), session.get(context.tables), session.feedback(context.tables), diagnostic_text);
            }
            if (result.operation == .save_doc) {
                if (closes) editor.close_after_save.* = 0;
                if (std.mem.eql(u8, session.text(&result.diagnostic), "conflict") and !action_palette.requestOpen(context.tables, context.atoms)) {
                    prompts.show(context.memory, context.tables, context.atoms, names.conflict_dialog, "") catch |err| prompts.status(session.table(context.tables), session.get(context.tables), session.feedback(context.tables), @errorName(err));
                }
            }
        } else switch (result.operation) {
            .load_doc => if (reconciliation_doc != api.none) workspace.activate(context.tables, context.atoms, reconciliation_doc),
            .save_doc => {
                prompts.inform(session.feedbackTable(context.tables), session.feedback(context.tables), "Saved");
                if (closes and editor.close_after_save.* != 0) {
                    editor.close_after_save.* = 0;
                    // Follow-up must use the same asynchronous adapter, not the
                    // legacy prompt sender. Caller pumps this queue next.
                    _ = submit(context, .{ .close_doc = .{ .doc = reconciliation_doc } }) catch |err| {
                        prompts.status(session.table(context.tables), session.get(context.tables), session.feedback(context.tables), @errorName(err));
                    };
                }
            },
            else => {},
        }
        sketches.followResult(context, result);
        if (editor.pending_request.* == result.request and (editor.pending_doc.* == result.definition or editor.pending_doc.* == current_doc or editor.pending_doc.* == reconciliation_doc)) {
            // A suppressed load must not leave its name for sync's startup fallback.
            // Only retire the exact prompt intent; a newer load still owns its state.
            if (activates and result.operation == .load_doc and reconciliation_doc == api.none and editor.pending_action.* == names.load_doc) {
                editor.pending_doc.* = session.none;
                editor.pending_request.* = 0;
                editor.fit_pending.* = 0;
            }
            editor.pending_action.* = session.none;
        }
        return true;
    }
    return false;
}

/// Whether a failure of `operation` is shown whatever document is open: it opens, saves or
/// edits a sketch rather than editing the open figure.
fn reportsFailure(operation: std.meta.Tag(api.Payload)) bool {
    return switch (operation) {
        .new_doc, .load_doc, .save_doc, .load_sketch, .new_sketch, .save_sketch, .close_sketch, .add_sketch_member, .rename_sketch_member, .remove_sketch_member, .move_sketch_member => true,
        else => false,
    };
}

/// Call after host refresh, before UX sync. Catalog identity survives Save As;
/// close/reuse is not mistaken for rename. No result-history retention required.
/// Returns true when authored revision/identity changed (preview rebind signal).
pub fn observe(context: figure.Context, allocator: std.mem.Allocator) !bool {
    const entries = try figure.listDefinitions(context, allocator);
    defer allocator.free(entries);
    const editor = session.get(context.tables);
    const observed = session.observed(context.tables);
    if (observed.doc.* != editor.doc.*) observed.observed_valid.* = 0;
    if (observed.observed_valid.* != 0) {
        for (entries) |entry| {
            const identity = entry.handle;
            if (identity.table_index != observed.observed_table.* or identity.table_generation != observed.observed_table_generation.* or identity.row != observed.observed_row.* or identity.generation != observed.observed_generation.*) continue;
            if (!entry.info.editor_open) break;
            const renamed = entry.info.definition != editor.doc.*;
            if (renamed) workspace.renameDocument(context.tables, editor.doc.*, entry.info.definition);
            const changed = renamed or observed.observed_revision.* != entry.info.authored_revision;
            observed.observed_revision.* = entry.info.authored_revision;
            return changed;
        }
        // Removed/replaced identity: discard selection and force explicit rebind.
        invalidate(context, entries);
        return true;
    }
    for (entries) |entry| if (entry.info.definition == editor.doc.*) {
        if (!entry.info.editor_open) {
            invalidate(context, entries);
            return true;
        }
        observed.doc.* = editor.doc.*;
        observed.observed_valid.* = 1;
        observed.observed_table.* = entry.handle.table_index;
        observed.observed_table_generation.* = entry.handle.table_generation;
        observed.observed_row.* = entry.handle.row;
        observed.observed_generation.* = entry.handle.generation;
        observed.observed_revision.* = entry.info.authored_revision;
        return true;
    };
    if (editor.doc.* != api.none) {
        invalidate(context, entries);
        return true;
    }
    return false;
}

/// Lets go of the document shown, whose identity in the catalog's `entries` went or changed.
/// When it is no longer open in `entries` at all, closed or unloaded, the stage moves on to
/// another buffer (`workspace.showAfterClose`); a document only reloaded stays for its rebind.
fn invalidate(context: figure.Context, entries: []const figure.DefinitionEntry) void {
    const editor = session.get(context.tables);
    const closed = editor.doc.*;
    session.removeRows(session.selections(context.tables).table, editor.doc.*);
    if (editor.pending_doc.* == editor.doc.*) editor.pending_doc.* = session.none;
    if (editor.pending_target.* == editor.doc.*) editor.pending_target.* = session.none;
    editor.doc.* = session.none;
    editor.active_id.* = 0;
    editor.active_bone.* = 0;
    session.observed(context.tables).observed_valid.* = 0;
    for (entries) |entry| {
        if (entry.info.definition == closed and entry.info.editor_open) return;
    }
    workspace.showAfterClose(context.tables, context.atoms, closed);
}

/// The catalog moved to `version`: the editor follows it on its next look.
pub fn consumeCatalog(context: figure.Context, version: u64) void {
    const observed = session.observed(context.tables);
    observed.catalog_version.* = version;
    observed.catalog_dirty.* = 1;
}
pub fn observeIfChanged(context: figure.Context, allocator: std.mem.Allocator) !void {
    const observed = session.observed(context.tables);
    if (observed.catalog_dirty.* == 0 and observed.doc.* == session.get(context.tables).doc.*) return;
    _ = try observe(context, allocator);
    observed.catalog_dirty.* = 0;
    observed.doc.* = session.get(context.tables).doc.*;
}
