const std = @import("std");
const mesha = @import("mesha");
const mesha_runtime = @import("mesha_runtime");
const figure_runtime = mesha_runtime.figure;
const figure = mesha.figure;
const api = mesha.figure;
const Atom = mesha.Atom;
const names = @import("names.zig");
const memory = mesha.memory;
const Table = mesha.Table;
const resources = mesha.resources;
const adapter = @import("commands.zig");
const state = @import("session.zig");
const workspace = @import("workspace.zig");
const fixture = @import("transport_fixture.zig");
const Fixture = struct {
    mem: memory.Memory = undefined,
    atoms: Atom.Registry = undefined,
    tables: Table.Registry = undefined,
    host: figure_runtime.HostTransport.Host = undefined,
    /// The last resources request the figure host sent, read off its rows by `dispatch`: its
    /// slices copied into `kept`, as the rows' arena is reused by the next request.
    resource: ?resources.CmdPayload = null,
    kept: std.heap.ArenaAllocator = .init(std.testing.allocator),
    fn init(f: *@This()) !void {
        f.mem.init(std.testing.allocator);
        try f.atoms.init(&f.mem);
        try f.tables.init(&f.mem, 128);
        try fixture.ensureResultInbox(&f.mem, &f.atoms, &f.tables);
        f.host = .{ .context = .{ .memory = &f.mem, .tables = &f.tables, .atoms = &f.atoms } };
        try figure_runtime.init(f.context());
        try figure_runtime.HostTransport.prepareCommands(&f.host);
        try resources.Requests.ensure(try f.mem.tableScratchAllocator(), &f.atoms, &f.tables, resources.commands_table_name);
        try mesha.panels.ensure(try f.mem.tableScratchAllocator(), &f.atoms, &f.tables);
        try workspace.ensure(&f.mem, &f.atoms, &f.tables);
        // The inboxes and tables of subscriptions of the editor's systems, which the test runs.
        const authoring = workspace.figureAuthoring();
        try mesha.sequencer.ensureInboxes(try f.mem.tableScratchAllocator(), &f.atoms, &f.tables, &authoring.sequencer());
    }
    fn capture(f: *Fixture, sent: *resources.CmdPayload) mesha.sequencer.Applied {
        var copy = sent.*;
        mesha.sequencer.copySlices(f.kept.allocator(), resources.CmdPayload, &copy) catch @panic("out of memory");
        f.resource = copy;
        return .done;
    }
    /// Takes `commands.figure` away, so the next request's append is refused after its
    /// admission, as a full arena would refuse it.
    fn refuseFigureRequests(f: *@This()) void {
        const handle = f.tables.findHandleByName(Atom.from(figure_runtime.HostTransport.commands_table_name)).?;
        f.tables.destroy(handle);
    }
    fn acceptFigureRequests(f: *@This()) !void {
        try figure_runtime.HostTransport.prepareCommands(&f.host);
    }
    fn context(f: *@This()) figure.Context {
        return .{ .memory = &f.mem, .tables = &f.tables, .atoms = &f.atoms };
    }
    fn deinit(f: *@This()) void {
        figure_runtime.deinit(f.context()) catch @panic("pending");
        f.tables.deinit();
        f.atoms.deinit();
        f.mem.deinit();
        f.kept.deinit();
    }
    /// Dispatches as the host does: the figure applies its rows and publishes what it holds,
    /// then what they queued runs.
    fn dispatch(f: *@This()) !void {
        var commands: figure_runtime.HostTransport.HostContext = .{ .host = &f.host };
        try figure_runtime.HostTransport.dispatch(&commands);
        try f.synchronize();
        resources.Requests.of(&f.mem, &f.tables, resources.commands_table_name).drain(f, capture);
    }
    /// What the host does after it applies a frame's commands or takes an answer, once the
    /// editor has declared its watches: publishes what it holds and answers them, which the
    /// editor reads the catalog and the open definition from. A revision that does not compile
    /// is the result's to report.
    fn synchronize(f: *@This()) !void {
        fixture.declareWatches(&f.mem, &f.atoms, &f.tables);
        figure_runtime.HostTransport.synchronize(&f.host) catch |err| switch (err) {
            error.CompileFailed => {},
            else => return err,
        };
    }
    /// Hands the figure host resources' answer to a save at `reply_to`, as the figure
    /// system's inbox would.
    fn answerSave(f: *@This(), reply_to: mesha.sequencer.ReplyTo, saved: resources.DocumentSaveMsg) void {
        f.answer(reply_to, std.mem.asBytes(&saved));
    }
    /// Hands the figure host resources' answer to a document request at `reply_to`.
    fn answerDocument(f: *@This(), reply_to: mesha.sequencer.ReplyTo, document: resources.DocumentMsg) void {
        const payload = resources.documentPayload(std.testing.allocator, document) catch @panic("out of memory");
        defer std.testing.allocator.free(payload);
        f.answer(reply_to, payload);
    }
    /// The user data is copied aligned, as an inbox's cells are: `capture` copied the
    /// request's slices as plain bytes.
    fn answer(f: *@This(), reply_to: mesha.sequencer.ReplyTo, payload: []const u8) void {
        var user_data: [64]u8 align(16) = undefined;
        const asked = reply_to.user_data.bytes;
        @memcpy(user_data[0..asked.len], asked);
        const received: mesha.sequencer.Message = .{ .tag = reply_to.tag, .payload = payload, .user_data = user_data[0..asked.len] };
        figure_runtime.HostTransport.takeReply(&f.host, received);
        f.synchronize() catch @panic("the figure host could not publish");
    }
    fn result(f: *@This()) api.Result {
        const taken = fixture.nextResult(&f.tables) catch unreachable;
        return taken.?;
    }
};
fn noAccess(frame: *const mesha.sequencer.Frame) mesha.sequencer.Access {
    _ = frame;
    return .{};
}

/// A requester besides the editor, whose results the editor's document system never sees.
fn otherRequester() mesha.sequencer.System {
    return .{ .name = "editor_figure_test_requester", .root = Atom.from("editor_figure_test_requester"), .claims = mesha.sequencer.claims_nothing, .access = noAccess, .kernels = &.{} };
}
fn otherRequesters() mesha.sequencer.Solo {
    return .of("editor_figure_test_requesters", otherRequester());
}

fn ensureOtherInbox(f: *Fixture) !void {
    const other_requesters_solo = otherRequesters();
    try mesha.sequencer.ensureInboxes(try f.mem.tableScratchAllocator(), &f.atoms, &f.tables, &other_requesters_solo.sequencer());
}

/// The oldest result in the other requester's inbox not yet taken.
fn nextOtherResult(f: *Fixture) !api.Result {
    const inbox = f.tables.findByName(mesha.sequencer.inboxOf(otherRequester())).?;
    const received = mesha.sequencer.takeOldest(inbox) orelse return error.MissingResult;
    return (try received.payloadAs(api.Result)).*;
}

test "editor commands history retention is settable through the facade and refuses a useless limit" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const journal = &(try figure_runtime.domain.history_state.get(&f.mem)).journal;
    try std.testing.expect(journal.retention == .unbounded);
    try figure_runtime.setHistoryRetention(f.context(), .{ .bytes = 1024 * 1024 });
    try std.testing.expectEqual(@as(usize, 1024 * 1024), journal.retention.bytes);
    try std.testing.expectError(error.InvalidOptions, figure_runtime.setHistoryRetention(f.context(), .{ .bytes = 0 }));
    try std.testing.expectEqual(@as(usize, 1024 * 1024), journal.retention.bytes);
    try figure_runtime.setHistoryRetention(f.context(), .unbounded);
    try std.testing.expect(journal.retention == .unbounded);
}

test "editor commands independent host copied metadata out of order duplicate and rollback capacity" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const doc = f.atoms.intern("adapter_doc");
    // Initial creation is a host operation; no editor activation is needed here.
    try figure.appendRequest(f.context(), .{ .payload = .{ .new_doc = .{ .scope = mesha.resources.applicationScope(f.tables.memory), .doc = doc, .request = 1 } }, .reply = mesha.sequencer.ReplyTo.of(adapter.system(), .from(adapter.Msg.editor_figure_result)) });
    try f.dispatch();
    _ = f.result();
    state.get(&f.tables).doc.* = doc;
    var points = [_]api.Point{ .{}, .{ .p = .{ .x = 20, .y = 10 } } };
    const a = try adapter.submit(f.context(), .{ .add_shape = .{ .doc = doc, .layer = 1, .points = &points } });
    points[1].p.x = 999;
    const b = try adapter.submit(f.context(), .{ .delete_bone = .{ .doc = doc, .id = 9999 } });
    try std.testing.expect(a != b);
    try f.dispatch();
    const first = f.result();
    const second = f.result();
    try std.testing.expect(adapter.consume(f.context(), second));
    try std.testing.expect(adapter.consume(f.context(), first));
    try std.testing.expect(!adapter.consume(f.context(), first));
    try std.testing.expectEqualStrings(figure_runtime.domain.model.text(&second.diagnostic), state.statusText(&f.tables));
    // The host refuses a duplicate of a request it holds, and the refusal resolves the
    // editor's Pending row.
    const next = state.get(&f.tables).request_serial.* + 1;
    try ensureOtherInbox(&f);
    try figure.appendRequest(f.context(), .{ .payload = .{ .undo = .{ .doc = doc, .request = next } }, .reply = mesha.sequencer.ReplyTo.of(otherRequester(), .from("test.undo")) });
    try std.testing.expectEqual(next, try adapter.submit(f.context(), .{ .undo = .{ .doc = doc } }));
    const pending = f.tables.findByName(f.atoms.intern(state.pending_name)).?;
    try std.testing.expectEqual(@as(u32, 1), pending.count());
    try f.dispatch();
    const earlier = try nextOtherResult(&f);
    try std.testing.expectEqual(next, earlier.request);
    const refused = f.result();
    try std.testing.expectEqual(next, refused.request);
    try std.testing.expectEqual(error.Busy, refused.outcome.failure);
    try std.testing.expect(adapter.consume(f.context(), refused));
    try std.testing.expectEqual(@as(u32, 0), pending.count());
    try std.testing.expect(std.mem.indexOf(u8, state.statusText(&f.tables), "Busy") != null);
    for (0..state.pending_capacity) |_| _ = try adapter.submit(f.context(), .{ .delete_bone = .{ .doc = doc, .id = 9999 } });
    try std.testing.expectError(error.CapacityExceeded, adapter.submit(f.context(), .{ .undo = .{ .doc = doc } }));
    try f.dispatch();
    while (try fixture.nextResult(&f.tables)) |result| {
        try std.testing.expect(adapter.consume(f.context(), result));
    }
}

test "editor commands terminal save-as close failure and durable external rename close reuse" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const doc = f.atoms.intern("async_editor");
    const s = state.get(&f.tables);
    _ = try adapter.submit(f.context(), .{ .new_doc = .{ .scope = mesha.resources.applicationScope(f.context().memory), .doc = doc } });
    try std.testing.expect(s.doc.* != doc);
    try f.dispatch();
    try std.testing.expect(adapter.consume(f.context(), f.result()));
    try std.testing.expectEqual(doc, s.doc.*);
    try std.testing.expect(try adapter.observe(f.context(), std.testing.allocator));
    _ = try adapter.submit(f.context(), .{ .add_bone = .{ .doc = doc, .length = 12 } });
    try f.dispatch();
    const delayed = f.result();
    // External submitter receives no editor callback. Catalog sees stable row rename.
    var path = "editor/assets/figure/external_editor.mshf".*;
    try figure.appendRequest(f.context(), .{ .payload = .{ .save_doc = .{ .doc = doc, .request = 77, .path = &path } } });
    @memset(&path, 'x');
    try f.dispatch();
    const save = f.resource.?.save_document;
    try std.testing.expectEqualStrings("editor/assets/figure/external_editor.mshf", save.path.?);
    var reply: resources.DocumentSaveMsg = .{ .scope = save.scope, .id = save.id, .result = .saved, .path = @splat(0), .fingerprint = 42 };
    @memcpy(reply.path[0..save.path.?.len], save.path.?);
    f.answerSave(save.reply, reply);
    try std.testing.expect(try adapter.observe(f.context(), std.testing.allocator));
    const renamed = f.atoms.intern("external_editor");
    try std.testing.expectEqual(renamed, s.doc.*);
    try std.testing.expect(adapter.consume(f.context(), delayed));
    try std.testing.expectEqual(delayed.created_id.?, s.active_bone.*);
    try std.testing.expectEqual(renamed, s.doc.*);
    try std.testing.expect(!adapter.consume(f.context(), delayed));
    // A dirty close failure must preserve the UI; save failure clears deferred close.
    _ = try adapter.submit(f.context(), .{ .add_bone = .{ .doc = renamed, .length = 20 } });
    try f.dispatch();
    try std.testing.expect(adapter.consume(f.context(), f.result()));
    _ = try adapter.submit(f.context(), .{ .close_doc = .{ .doc = renamed } });
    try f.dispatch();
    const rejected = f.result();
    try std.testing.expect(rejected.outcome == .failure);
    try std.testing.expect(adapter.consume(f.context(), rejected));
    try std.testing.expectEqual(renamed, s.doc.*);
    s.close_after_save.* = 1;
    _ = try adapter.submit(f.context(), .{ .save_doc = .{ .doc = f.atoms.intern("missing") } });
    try f.dispatch();
    try std.testing.expect(adapter.consume(f.context(), f.result()));
    try std.testing.expectEqual(@as(u8, 0), s.close_after_save.*);
    try figure.appendRequest(f.context(), .{ .payload = .{ .close_doc = .{ .doc = renamed, .request = 78, .discard = true } } });
    try f.dispatch();
    try figure.appendRequest(f.context(), .{ .payload = .{ .new_doc = .{ .scope = mesha.resources.applicationScope(f.context().memory), .doc = renamed, .request = 79 } } });
    try f.dispatch();
    try std.testing.expect(try adapter.observe(f.context(), std.testing.allocator));
    try std.testing.expectEqual(api.none, s.doc.*);
}

test "editor commands async load rejection is terminal with precise diagnostic" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const doc = f.atoms.intern("load_missing");
    const s = state.get(&f.tables);
    s.doc.* = doc;
    const request = try adapter.submit(f.context(), .{ .load_doc = .{ .scope = mesha.resources.applicationScope(f.context().memory), .doc = doc } });
    try f.dispatch();
    try std.testing.expect(fixture.noResults(&f.tables));
    try std.testing.expectEqual(@as(u32, 1), f.tables.findByName(f.atoms.intern(state.pending_name)).?.count());
    const load = f.resource.?.request_document;
    const reply: resources.DocumentMsg = .{ .scope = load.scope, .id = doc, .result = .not_found, .bytes = &.{}, .fingerprint = 0 };
    f.answerDocument(load.reply, reply);
    const result = f.result();
    try std.testing.expectEqual(request, result.request);
    try std.testing.expect(adapter.consume(f.context(), result));
    try std.testing.expectEqualStrings("not_found", state.statusText(&f.tables));
}

test "editor commands owned save-as deferred close waits for both terminal results" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const doc = f.atoms.intern("save_owned");
    _ = try adapter.submit(f.context(), .{ .new_doc = .{ .scope = mesha.resources.applicationScope(f.context().memory), .doc = doc } });
    try f.dispatch();
    try std.testing.expect(adapter.consume(f.context(), f.result()));
    const s = state.get(&f.tables);
    _ = try adapter.submit(f.context(), .{ .add_bone = .{ .doc = doc, .length = 12 } });
    try f.dispatch();
    const delayed = f.result();
    s.close_after_save.* = 1;
    var path = "editor/assets/figure/save_owned_new.mshf".*;
    const request = try adapter.submit(f.context(), .{ .save_doc = .{ .doc = doc, .path = &path } });
    @memset(&path, 'x');
    try f.dispatch();
    try std.testing.expect(fixture.noResults(&f.tables));
    try std.testing.expectEqual(doc, s.doc.*);
    const save = f.resource.?.save_document;
    var reply: resources.DocumentSaveMsg = .{ .scope = save.scope, .id = save.id, .result = .saved, .path = @splat(0), .fingerprint = 42 };
    @memcpy(reply.path[0..save.path.?.len], save.path.?);
    f.answerSave(save.reply, reply);
    const result = f.result();
    try std.testing.expectEqual(request, result.request);
    try std.testing.expectEqual(doc, result.definition);
    const renamed = f.atoms.intern("save_owned_new");
    try std.testing.expectEqual(renamed, result.current_definition);
    try std.testing.expect(adapter.consume(f.context(), result));
    try std.testing.expectEqual(renamed, s.doc.*);
    try std.testing.expect(adapter.consume(f.context(), delayed));
    try std.testing.expectEqual(delayed.created_id.?, s.active_bone.*);
    try std.testing.expectEqual(renamed, s.doc.*);
    try std.testing.expect(!adapter.consume(f.context(), delayed));
    try f.dispatch();
    try std.testing.expect(adapter.consume(f.context(), f.result()));
    try std.testing.expectEqual(api.none, s.doc.*);
}

test "editor commands external clean close keeps a loader-held definition but invalidates initial and retained ownership" {
    for ([_]bool{ false, true }) |bind_first| {
        var f: Fixture = .{};
        try f.init();
        defer f.deinit();
        const doc = f.atoms.intern("closed_retained");
        _ = try adapter.submit(f.context(), .{ .new_doc = .{ .scope = mesha.resources.applicationScope(f.context().memory), .doc = doc } });
        try f.dispatch();
        try std.testing.expect(adapter.consume(f.context(), f.result()));
        _ = try adapter.submit(f.context(), .{ .save_doc = .{ .doc = doc, .path = "editor/assets/figure/closed_retained.mshf" } });
        try f.dispatch();
        const save = f.resource.?.save_document;
        const saved: resources.DocumentSaveMsg = .{ .scope = save.scope, .id = doc, .result = .saved, .path = @splat(0), .fingerprint = 42 };
        f.answerSave(save.reply, saved);
        try std.testing.expect(adapter.consume(f.context(), f.result()));
        try figure_runtime.refresh(f.context());
        // A loader lease keeps the definition resident once the editor closes it.
        try figure.appendRequest(f.context(), .{ .payload = .{ .load_doc = .{ .scope = mesha.resources.applicationScope(f.context().memory), .doc = doc, .request = 98, .editor_open = false } } });
        try f.dispatch();
        if (bind_first) try std.testing.expect(try adapter.observe(f.context(), std.testing.allocator));
        const before = try figure_runtime.listDefinitions(f.context(), std.testing.allocator);
        defer std.testing.allocator.free(before);
        try figure.appendRequest(f.context(), .{ .payload = .{ .close_doc = .{ .doc = doc, .request = 99 } } });
        try f.dispatch();
        const after = try figure_runtime.listDefinitions(f.context(), std.testing.allocator);
        defer std.testing.allocator.free(after);
        try std.testing.expectEqual(@as(usize, 1), after.len);
        try std.testing.expectEqual(before[0].info.authored_revision, after[0].info.authored_revision);
        try std.testing.expect(!after[0].info.editor_open);
        state.get(&f.tables).pending_doc.* = doc;
        try std.testing.expect(try adapter.observe(f.context(), std.testing.allocator));
        @import("transport_fixture.zig").runSystems(&f.mem, &f.atoms, &f.tables);
        try std.testing.expectEqual(api.none, state.get(&f.tables).doc.*);
        try std.testing.expectEqual(api.none, state.get(&f.tables).pending_doc.*);
        try std.testing.expect((try figure_runtime.definitionInfo(f.context(), doc)).runtime_load_held);
        try std.testing.expect(!try adapter.observe(f.context(), std.testing.allocator));
    }
}

test "editor commands deferred close ignores unrelated save success and failure before intended result" {
    for ([_]bool{ false, true }) |unrelated_fails| {
        var f: Fixture = .{};
        try f.init();
        defer f.deinit();
        const a = f.atoms.intern("save_a");
        const b = f.atoms.intern("save_b");
        for ([_]Atom{ a, b }) |doc| {
            _ = try adapter.submit(f.context(), .{ .new_doc = .{ .scope = mesha.resources.applicationScope(f.context().memory), .doc = doc } });
            try f.dispatch();
            try std.testing.expect(adapter.consume(f.context(), f.result()));
        }
        _ = try adapter.submit(f.context(), .{ .save_doc = .{ .doc = a, .request = 888, .path = "editor/assets/figure/save_a.mshf" } });
        try f.dispatch();
        const save_a = f.resource.?.save_document;
        const s = state.get(&f.tables);
        s.close_after_save.* = 1;
        _ = try adapter.submit(f.context(), .{ .save_doc = .{ .doc = b, .request = 888, .path = "editor/assets/figure/save_b.mshf" } });
        try f.dispatch();
        const save_b = f.resource.?.save_document;
        const reply_a: resources.DocumentSaveMsg = .{ .scope = save_a.scope, .id = a, .result = if (unrelated_fails) .write_failed else .saved, .path = @splat(0), .fingerprint = 42 };
        f.answerSave(save_a.reply, reply_a);
        try std.testing.expect(adapter.consume(f.context(), f.result()));
        try std.testing.expectEqual(@as(u8, 1), s.close_after_save.*);
        try std.testing.expectEqual(b, s.doc.*);
        try std.testing.expectEqual(@as(u32, 1), f.tables.findByName(f.atoms.intern(state.pending_name)).?.count());
        const reply_b: resources.DocumentSaveMsg = .{ .scope = save_b.scope, .id = b, .result = .saved, .path = @splat(0), .fingerprint = 43 };
        f.answerSave(save_b.reply, reply_b);
        try std.testing.expect(adapter.consume(f.context(), f.result()));
        try std.testing.expectEqual(@as(u8, 0), s.close_after_save.*);
        try f.dispatch();
        try std.testing.expect(adapter.consume(f.context(), f.result()));
        const entries = try figure_runtime.listDefinitions(f.context(), std.testing.allocator);
        defer std.testing.allocator.free(entries);
        try std.testing.expectEqual(@as(usize, 1), entries.len);
        try std.testing.expectEqual(a, entries[0].info.definition);
        try std.testing.expect(entries[0].info.editor_open);
    }
}

test "editor commands observed save rename roundtrip rejects stale snapshot and close target" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const doc = f.atoms.intern("roundtrip_a");
    const renamed = f.atoms.intern("roundtrip_b");
    _ = try adapter.submit(f.context(), .{ .new_doc = .{ .scope = mesha.resources.applicationScope(f.context().memory), .doc = doc } });
    try f.dispatch();
    try std.testing.expect(adapter.consume(f.context(), f.result()));
    try std.testing.expect(try adapter.observe(f.context(), std.testing.allocator));
    const s = state.get(&f.tables);
    const scratch = try f.mem.tableScratchAllocator();
    try @import("../action_palette.zig").ensure(scratch, &f.atoms, &f.tables);
    try @import("prompts.zig").show(&f.mem, &f.tables, &f.atoms, names.save_as, "roundtrip_b");
    try state.validatePromptDocument(&f.tables, &f.atoms);
    // This transport fixture inspects admission; it does not render the prompt.
    s.pending_doc.* = doc;
    s.pending_target.* = doc;
    s.close_after_save.* = 1;
    _ = try adapter.submit(f.context(), .{ .save_doc = .{ .doc = doc, .path = "editor/assets/figure/roundtrip_b.mshf" } });
    try f.dispatch();
    const save = f.resource.?.save_document;
    var reply: resources.DocumentSaveMsg = .{ .scope = save.scope, .id = save.id, .result = .saved, .path = @splat(0), .fingerprint = 42 };
    @memcpy(reply.path[0..save.path.?.len], save.path.?);
    f.answerSave(save.reply, reply);
    const delayed = f.result();
    try std.testing.expectEqual(renamed, delayed.current_definition);
    try std.testing.expect(try adapter.observe(f.context(), std.testing.allocator));
    try std.testing.expectEqual(renamed, s.doc.*);
    try std.testing.expectEqual(renamed, s.prompt_doc.*);
    try state.validatePromptDocument(&f.tables, &f.atoms);
    try figure.appendRequest(f.context(), .{ .payload = .{ .save_doc = .{ .doc = renamed, .request = 77, .path = "editor/assets/figure/roundtrip_a.mshf" } } });
    try f.dispatch();
    const external = f.resource.?.save_document;
    reply = .{ .scope = external.scope, .id = external.id, .result = .saved, .path = @splat(0), .fingerprint = 43 };
    @memcpy(reply.path[0..external.path.?.len], external.path.?);
    f.answerSave(external.reply, reply);
    try std.testing.expect(try adapter.observe(f.context(), std.testing.allocator));
    try std.testing.expectEqual(doc, s.prompt_doc.*);
    try state.validatePromptDocument(&f.tables, &f.atoms);
    const pending = f.tables.findByName(f.atoms.intern(state.pending_name)).?;
    var rows = pending.query(figure_runtime.domain.model.Row(state.Pending));
    const row = rows.next().?;
    try std.testing.expectEqual(doc, row.view.doc.*);
    try std.testing.expectEqual(doc, row.view.current_doc.*);
    try std.testing.expectEqual(@as(u8, 1), row.view.rename_observed.*);
    try std.testing.expect(adapter.consume(f.context(), delayed));
    try std.testing.expect(!adapter.consume(f.context(), delayed));
    try std.testing.expectEqual(doc, s.doc.*);
    try std.testing.expectEqual(doc, s.pending_doc.*);
    try std.testing.expectEqual(doc, s.pending_target.*);
    var followups = pending.query(figure_runtime.domain.model.Row(state.Pending));
    const close = followups.next().?;
    try std.testing.expectEqual(@intFromEnum(api.Operation.close_doc), close.view.operation.*);
    try std.testing.expectEqual(doc, close.view.doc.*);
    try std.testing.expect(followups.next() == null);
    try f.dispatch();
    const closed = f.result();
    try std.testing.expectEqual(doc, closed.definition);
    try std.testing.expect(closed.outcome == .success);
    try std.testing.expect(adapter.consume(f.context(), closed));
}

test "a new figure saves in the working directory unless the person names a path" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const doc = f.atoms.intern("meadow_sketch");
    _ = try adapter.submit(f.context(), .{ .new_doc = .{ .scope = mesha.resources.applicationScope(f.context().memory), .doc = doc } });
    try f.dispatch();
    try std.testing.expect(adapter.consume(f.context(), f.result()));
    try std.testing.expect(try adapter.observe(f.context(), std.testing.allocator));
    // The frame ends: the editor watches the figure it opened, and the host answers.
    try f.synchronize();
    const prompts = @import("prompts.zig");

    // A figure that has no file saves as `<stem>.mshf` in the working directory.
    try prompts.save(&f.tables, &f.atoms, null, false);
    try f.dispatch();
    const unnamed = f.resource.?.save_document;
    try std.testing.expectEqualStrings("meadow_sketch.mshf", unnamed.path.?);
    var reply: resources.DocumentSaveMsg = .{ .scope = unnamed.scope, .id = unnamed.id, .result = .write_failed, .path = @splat(0), .fingerprint = 0 };
    f.answerSave(unnamed.reply, reply);
    try std.testing.expect(adapter.consume(f.context(), f.result()));

    // A path the person names is where it saves.
    try prompts.save(&f.tables, &f.atoms, "art/figures/meadow_sketch.mshf", false);
    try f.dispatch();
    const named = f.resource.?.save_document;
    try std.testing.expectEqualStrings("art/figures/meadow_sketch.mshf", named.path.?);
    reply = .{ .scope = named.scope, .id = named.id, .result = .write_failed, .path = @splat(0), .fingerprint = 0 };
    f.answerSave(named.reply, reply);
    try std.testing.expect(adapter.consume(f.context(), f.result()));
}

test "editor buffered submit copy failure rolls back UX and host reservations" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const doc = f.atoms.intern("buffer_failure");
    const initial_serial = state.get(&f.tables).request_serial.*;
    f.refuseFigureRequests();
    try std.testing.expectError(error.NotInitialized, adapter.submit(f.context(), .{ .new_doc = .{ .scope = mesha.resources.applicationScope(f.context().memory), .doc = doc } }));
    try f.acceptFigureRequests();
    const s = state.get(&f.tables);
    try std.testing.expectEqual(initial_serial + 1, s.request_serial.*);
    try std.testing.expectEqual(@as(u32, 0), f.tables.findByName(f.atoms.intern(state.pending_name)).?.count());
    try std.testing.expect(figure_runtime.HostTransport.requestStatus(f.host.context, doc, initial_serial + 1) == null);
    // Failed admission consumes the serial, not the caller's eventual request.
    try std.testing.expectEqual(initial_serial + 2, try adapter.submit(f.context(), .{ .new_doc = .{ .scope = mesha.resources.applicationScope(f.context().memory), .doc = doc } }));
    try f.dispatch();
    try std.testing.expect(adapter.consume(f.context(), f.result()));
}

test "editor close admission failure reopens the preview" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const preview = @import("preview.zig");
    const doc = f.atoms.intern("close_preview_failure");
    _ = try adapter.submit(f.context(), .{ .new_doc = .{ .scope = mesha.resources.applicationScope(f.context().memory), .doc = doc } });
    try f.dispatch();
    try std.testing.expect(adapter.consume(f.context(), f.result()));
    try figure_runtime.refresh(f.context());
    try preview.ready(&f.tables, &f.atoms);
    f.refuseFigureRequests();
    try std.testing.expectError(error.NotInitialized, adapter.submit(f.context(), .{ .close_doc = .{ .doc = doc, .discard = true } }));
    try f.acceptFigureRequests();
    try std.testing.expectEqual(@as(u32, 0), f.tables.findByName(f.atoms.intern(state.pending_name)).?.count());
    // The refused close reopened the preview, so the canvas still shows the definition.
    try std.testing.expectEqual(@as(u8, 0), preview.state(&f.tables).closing.*);
    try preview.ready(&f.tables, &f.atoms);
    const shown = try preview.current(&f.tables, &f.atoms);
    try std.testing.expectEqual(doc, shown.definition);
}

test "editor prompt buffered load submit failure clears phantom pending UI" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const prompts = @import("prompts.zig");
    const s = state.get(&f.tables);
    const serial = s.request_serial.*;
    f.refuseFigureRequests();
    prompts.load(&f.tables, &f.atoms, f.atoms.intern("missing"), false, null);
    try f.acceptFigureRequests();
    try std.testing.expectEqual(figure_runtime.domain.model.none, s.pending_action.*);
    try std.testing.expectEqual(@as(u8, 0), s.fit_pending.*);
    try std.testing.expectEqualStrings("NotInitialized", state.statusText(&f.tables));
    try std.testing.expectEqual(serial + 1, s.request_serial.*);
    try std.testing.expectEqual(@as(u32, 0), f.tables.findByName(f.atoms.intern(state.pending_name)).?.count());
}

test "editor filmstrip partial batch admission cancels after accepted begin without phantom pending or ID overlap" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const filmstrip = @import("filmstrip.zig");
    const doc = f.atoms.intern("partial_batch");
    _ = try adapter.submit(f.context(), .{ .new_doc = .{ .scope = mesha.resources.applicationScope(f.context().memory), .doc = doc } });
    try f.dispatch();
    try std.testing.expect(adapter.consume(f.context(), f.result()));
    // Keep UI commands in the same buffer as the eventual begin.
    const s = state.get(&f.tables);
    s.mode.* = f.atoms.intern("animate");
    for (0..127) |_| _ = try adapter.submit(f.context(), .{ .preview_reset = .{ .doc = doc } });
    const before_serial = s.request_serial.*;
    try std.testing.expectError(error.CapacityExceeded, filmstrip.edit(&f.tables, &f.atoms, .{ .add_clip = .{ .doc = doc, .name = f.atoms.intern("clip") } }));
    const c = filmstrip.config(&f.tables);
    try std.testing.expectEqual(before_serial, s.request_serial.*);
    try std.testing.expectEqual(@as(u32, 1), c.pending.*);
    try std.testing.expectEqual(@as(u8, 2), c.ending.*);
    try f.dispatch();
    while (try fixture.nextResult(&f.tables)) |result| {
        try std.testing.expect(adapter.consume(f.context(), result));
    }
    try std.testing.expectEqual(@as(u32, 0), c.pending.*);
    filmstrip.settle(&f.tables, &f.atoms);
    try std.testing.expectEqual(@as(u8, 2), c.transaction.*);
    try f.dispatch();
    try std.testing.expect(adapter.consume(f.context(), f.result()));
    try std.testing.expectEqual(@as(u32, 0), c.pending.*);
    try std.testing.expectEqual(@as(u8, 0), c.transaction.*);
    try std.testing.expectEqual(@as(u8, 0), s.tx_active.*);
    try std.testing.expect(!figure_runtime.domain.history.anyActive(&f.tables));
}

test "editor commands withheld new and load success cannot reopen external close or same name replacement" {
    for ([_]bool{ false, true }) |load| {
        for ([_]bool{ false, true }) |retained| {
            for ([_]bool{ false, true }) |replace| {
                var f: Fixture = .{};
                try f.init();
                defer f.deinit();
                const doc = f.atoms.intern("blue");
                if (load) {
                    @import("prompts.zig").load(&f.tables, &f.atoms, doc, false, null);
                } else {
                    _ = try adapter.submit(f.context(), .{ .new_doc = .{ .scope = mesha.resources.applicationScope(f.context().memory), .doc = doc } });
                }
                try f.dispatch();
                if (load) {
                    const request = f.resource.?.request_document;
                    const reply: resources.DocumentMsg = .{ .scope = request.scope, .id = doc, .result = .opened_loaded, .bytes = figure_runtime.domain.tests.blue_source, .fingerprint = 7 };
                    f.answerDocument(request.reply, reply);
                }
                const delayed = f.result();
                try std.testing.expect(delayed.outcome == .success);
                try std.testing.expect(delayed.definition_handle != null);
                // A new document needs a saved baseline before a retained close.
                if (!load and retained) {
                    try figure.appendRequest(f.context(), .{ .payload = .{ .save_doc = .{ .doc = doc, .request = 100, .path = "editor/assets/figure/blue.mshf" } } });
                    try f.dispatch();
                    const save = f.resource.?.save_document;
                    const saved: resources.DocumentSaveMsg = .{ .scope = save.scope, .id = doc, .result = .saved, .path = @splat(0), .fingerprint = 42 };
                    f.answerSave(save.reply, saved);
                }
                try figure_runtime.refresh(f.context());
                try f.dispatch();
                if (retained) {
                    // A loader lease retains the definition past the editor's close.
                    try figure.appendRequest(f.context(), .{ .payload = .{ .load_doc = .{ .scope = mesha.resources.applicationScope(f.context().memory), .doc = doc, .request = 99, .editor_open = false } } });
                    try f.dispatch();
                }
                try figure.appendRequest(f.context(), .{ .payload = .{ .close_doc = .{ .doc = doc, .request = 101, .discard = !retained } } });
                try f.dispatch();
                // Retained definitions cannot be replaced while the lease lives.
                if (replace and !retained) {
                    try figure.appendRequest(f.context(), .{ .payload = .{ .new_doc = .{ .scope = mesha.resources.applicationScope(f.context().memory), .doc = doc, .request = 102 } } });
                    try f.dispatch();
                }
                _ = try adapter.observe(f.context(), std.testing.allocator);
                try std.testing.expect(adapter.consume(f.context(), delayed));
                if (load) @import("transport_fixture.zig").runSystems(&f.mem, &f.atoms, &f.tables);
                try std.testing.expectEqual(api.none, state.get(&f.tables).doc.*);
                if (load) {
                    const s = state.get(&f.tables);
                    try std.testing.expectEqual(api.none, s.pending_doc.*);
                    try std.testing.expectEqual(api.none, s.pending_action.*);
                    try std.testing.expectEqual(@as(u32, 0), s.pending_request.*);
                }
                try std.testing.expectEqual(@as(u32, 0), f.tables.findByName(f.atoms.intern(state.pending_name)).?.count());
                _ = try adapter.observe(f.context(), std.testing.allocator);
                try std.testing.expectEqual(api.none, state.get(&f.tables).doc.*);
            }
        }
    }
}

test "editor commands initial unbound missing document is invalidated" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    state.get(&f.tables).doc.* = f.atoms.intern("missing");
    try std.testing.expect(try adapter.observe(f.context(), std.testing.allocator));
    try std.testing.expectEqual(api.none, state.get(&f.tables).doc.*);
}

test "editor prompt suppressed load preserves newer same name pending load" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const prompts = @import("prompts.zig");
    const doc = f.atoms.intern("blue");
    prompts.load(&f.tables, &f.atoms, doc, false, null);
    try f.dispatch();
    const request = f.resource.?.request_document;
    const reply: resources.DocumentMsg = .{ .scope = request.scope, .id = doc, .result = .opened_loaded, .bytes = figure_runtime.domain.tests.blue_source, .fingerprint = 7 };
    f.answerDocument(request.reply, reply);
    const delayed = f.result();
    try figure.appendRequest(f.context(), .{ .payload = .{ .close_doc = .{ .doc = doc, .request = 101 } } });
    try f.dispatch();
    // Same name, different request: the old terminal must not retire this intent.
    prompts.load(&f.tables, &f.atoms, doc, false, null);
    try f.dispatch();
    const newer = f.resource.?.request_document;
    const s = state.get(&f.tables);
    const newer_request = s.pending_request.*;
    try std.testing.expect(newer_request != delayed.request);
    _ = try adapter.observe(f.context(), std.testing.allocator);
    try std.testing.expect(adapter.consume(f.context(), delayed));
    @import("transport_fixture.zig").runSystems(&f.mem, &f.atoms, &f.tables);
    try std.testing.expectEqual(api.none, s.doc.*);
    try std.testing.expectEqual(doc, s.pending_doc.*);
    try std.testing.expectEqual(f.atoms.intern("load_doc"), s.pending_action.*);
    try std.testing.expectEqual(newer_request, s.pending_request.*);
    try std.testing.expectEqual(@as(u8, 1), s.fit_pending.*);
    // Finish the newer host request so teardown also verifies normal completion.
    f.answerDocument(newer.reply, reply);
    try std.testing.expect(adapter.consume(f.context(), f.result()));
    @import("transport_fixture.zig").runSystems(&f.mem, &f.atoms, &f.tables);
    try std.testing.expectEqual(doc, s.doc.*);
}

test "drawing shape creation switches tools only after its matching successful result" {
    const drawing = @import("drawing.zig");
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const doc = f.atoms.intern("shape_completion");
    const reply = mesha.sequencer.ReplyTo.of(adapter.system(), .from(adapter.Msg.editor_figure_result));
    try figure.appendRequest(f.context(), .{ .payload = .{ .new_doc = .{ .scope = mesha.resources.applicationScope(f.context().memory), .doc = doc, .request = 1 } }, .reply = reply });
    try f.dispatch();
    _ = f.result();
    const editor = state.get(&f.tables);
    const settings = drawing.config(&f.tables);
    editor.doc.* = doc;
    editor.mode.* = f.atoms.intern("design");
    editor.active_layer.* = 1;
    editor.gesture_current.* = .{ .x = 20, .y = 10 };
    const rect = f.atoms.intern("rect");
    const select = f.atoms.intern("select");
    const outcomes = enum { ordinary, locked, rejected };
    for ([_]outcomes{ .ordinary, .locked, .rejected }) |outcome| {
        editor.tool.* = rect;
        settings.locked_tool.* = if (outcome == .locked) rect else state.none;
        // A deleted press-time layer must fail, even if current defaults changed.
        settings.primitive_layer.* = if (outcome == .rejected) 9999 else 1;
        try std.testing.expect(try drawing.pointerUp(&f.tables, &f.atoms));
        const request = settings.creation_request.*;
        try std.testing.expect(request != 0);
        try std.testing.expectEqual(rect, editor.tool.*);
        try f.dispatch();
        const result = f.result();
        var stale = result;
        stale.request += 100;
        try std.testing.expect(!adapter.consume(f.context(), stale));
        try std.testing.expectEqual(request, settings.creation_request.*);
        try std.testing.expectEqual(rect, editor.tool.*);
        try std.testing.expect(adapter.consume(f.context(), result));
        try std.testing.expectEqual(@as(u32, 0), settings.creation_request.*);
        try std.testing.expectEqual(if (outcome == .ordinary) select else rect, editor.tool.*);
        if (outcome == .rejected) {
            try std.testing.expect(result.outcome == .failure);
        } else {
            try std.testing.expect(result.outcome == .success);
            try std.testing.expectEqual(result.created_id.?, editor.active_id.*);
        }
    }
}

test "a refused save reads as a sentence naming the missing folder or the document that has the name" {
    var buffer: [192]u8 = undefined;
    try std.testing.expectEqualStrings("Not saved: the folder art/figures does not exist.", adapter.saveRefusalText(&buffer, "directory_missing", "art/figures/meadow.mshf"));
    try std.testing.expectEqualStrings("Not saved: the folder does not exist.", adapter.saveRefusalText(&buffer, "directory_missing", ""));
    try std.testing.expectEqualStrings("Not saved: another open figure or sketch, demo/assets/figures/blue.mshf, has this name.", adapter.saveRefusalText(&buffer, "id_taken: demo/assets/figures/blue.mshf", "x/blue.mshf"));
    try std.testing.expectEqualStrings("Not saved: another open figure or sketch has this name.", adapter.saveRefusalText(&buffer, "id_taken", "x/blue.mshf"));
    // A sketch's refusal, whose path the editor does not hold, reads the same.
    try std.testing.expectEqualStrings("Not saved: another open figure or sketch, demo/assets/figures/wolf.mshs, has this name.", adapter.saveRefusalText(&buffer, "id_taken: demo/assets/figures/wolf.mshs", ""));
    // Only `id_taken` itself or `id_taken: <file>` is a taken name.
    try std.testing.expectEqualStrings("id_taken_foo", adapter.saveRefusalText(&buffer, "id_taken_foo", "x/blue.mshf"));
    try std.testing.expectEqualStrings("write_failed", adapter.saveRefusalText(&buffer, "write_failed", "x/blue.mshf"));
}
