//! Native actual-root fixture setup; never linked into the production editor.
const mesha = @import("mesha");
const mesha_runtime = @import("mesha_runtime");
const figure_runtime = mesha_runtime.figure;
const Atom = mesha.Atom;
const Table = mesha.Table;
const sequencer = mesha.sequencer;
const history = figure_runtime.domain.history;
const action_palette = @import("action_palette.zig");
const state = @import("stage_state.zig");

pub fn warm(tables: *Table.Registry, atoms: *Atom.Registry) !void {
    // Keep a real history transaction and an open prompt.
    try atoms.tryInternAll(&.{"root-loader-test"});
    try history.begin(tables, atoms, Atom.from("blue"), Atom.from("root-loader-test"));
    const prompt = action_palette.prompt(tables, atoms);
    prompt.request_open.* = 1;
    prompt.request_owner.* = Atom.from("root-loader-test");
    try tables.findByName(Atom.from(action_palette.table_name)).?.assignString(prompt.text, "warm");
    prompt.cursor.* = 2;
}

pub fn active(tables: *Table.Registry) bool {
    return history.anyActive(tables);
}

pub fn closeBlue(tables: *Table.Registry, atoms: *Atom.Registry) !void {
    try figure_runtime.domain.library.close(tables, atoms, .{ .doc = atoms.intern("blue"), .discard = true });
}

pub fn exerciseOldCommand(process: mesha.plugin.ProcessCmdFn, memory: *mesha.memory.Memory, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    const std = @import("std");
    const app_commands = mesha.plugin.app_commands;
    try app_commands.Requests.ensure(try memory.tableScratchAllocator(), atoms, tables, app_commands.commands_table_name);
    var command: app_commands.Payload = .{ .action_palette = .{ .dismiss = .{} } };
    const applied = process(memory, atoms, tables, &command);
    try std.testing.expectEqual(sequencer.Applied.done, applied);
    // The hook appends the dismissal for the palette, which takes it in its run and answers
    // the dismissed prompt's owner through the same hook.
    const steps = [_]sequencer.Step{.{ .system = action_palette.system() }};
    const alone: sequencer.Sequencer = .{ .name = "old_command_test", .steps = &steps };
    @import("editor_sequencer.zig").run(memory, atoms, tables, &alone, null);
    try std.testing.expectEqual(@as(u8, 0), action_palette.prompt(tables, atoms).request_open.*);
    const Answering = struct {
        process: mesha.plugin.ProcessCmdFn,
        memory: *mesha.memory.Memory,
        atoms: *Atom.Registry,
        tables: *Table.Registry,
        answered: u32 = 0,

        fn answer(answering: *@This(), payload: *app_commands.Payload) sequencer.Applied {
            const result = answering.process(answering.memory, answering.atoms, answering.tables, payload);
            if (result == .done) answering.answered += 1;
            return result;
        }
    };
    var answering: Answering = .{ .process = process, .memory = memory, .atoms = atoms, .tables = tables };
    app_commands.Requests.of(memory, tables, app_commands.commands_table_name).drain(&answering, Answering.answer);
    // The dismissal is answered through the hook; with no prompt open its answer has no
    // owner's inbox to reach.
    try std.testing.expect(answering.answered != 0);
}

pub fn initHost(memory: *mesha.memory.Memory, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    const figure = mesha.figure;
    try mesha.panels.ensure(try memory.tableScratchAllocator(), atoms, tables);
    const context = figure.Context{ .memory = memory, .atoms = atoms, .tables = tables };
    try figure_runtime.init(context);
    const library = figure_runtime.domain.library;
    const resources = mesha.resources;
    try resources.Requests.ensure(try memory.tableScratchAllocator(), atoms, tables, resources.commands_table_name);
    const blue = atoms.intern("blue");
    try library.load(tables, atoms, .{ .scope = resources.applicationScope(tables.memory), .doc = blue });
    // The load is the request just sent; it stays in its table, keeping its slices alive.
    const Sent = struct {
        fn keep(into: *resources.CmdPayload, sent: *resources.CmdPayload) mesha.sequencer.Applied {
            into.* = sent.*;
            return .retry;
        }
    };
    var request: resources.CmdPayload = undefined;
    resources.Requests.of(memory, tables, resources.commands_table_name).drain(&request, Sent.keep);
    const source = try @import("std").Io.Dir.cwd().readFileAlloc(@import("std").testing.io, "demo/assets/figures/blue.mshf", memory.globalAllocator(), .limited(1024 * 1024));
    defer memory.globalAllocator().free(source);
    const reply: mesha.resources.DocumentMsg = .{ .scope = request.request_document.scope, .id = blue, .result = .opened_loaded, .bytes = source, .fingerprint = 1 };
    const payload = try mesha.resources.documentPayload(memory.globalAllocator(), reply);
    defer memory.globalAllocator().free(payload);
    const received = request.request_document.reply.answered(payload);
    _ = library.handleMessage(tables, atoms, received);
    try figure_runtime.refresh(context);
}

pub fn submitEditorDocument(memory: *mesha.memory.Memory, atoms: *Atom.Registry, tables: *Table.Registry, doc: Atom) !void {
    _ = try @import("figure/commands.zig").submit(.{ .memory = memory, .atoms = atoms, .tables = tables }, .{ .new_doc = .{ .scope = mesha.resources.applicationScope(tables.memory), .doc = doc } });
}
pub fn editorDocument(tables: *Table.Registry) Atom {
    return @import("figure/session.zig").get(tables).doc.*;
}
