const std = @import("std");
const builtin = @import("builtin");
const mesha = @import("mesha");
const ui = mesha.ui;
const mesha_runtime = @import("mesha_runtime");
const figure_runtime = mesha_runtime.figure;
const lib = @import("editor.zig");
const windows = @import("windows.zig");
const panel_frame = @import("panel_frame.zig");
const status_bar = @import("status_bar.zig");
const action_palette = @import("action_palette.zig");
const text_editor = @import("text_editor.zig");
const state = @import("state.zig");
const text_panel = @import("text_panel.zig");
const figure_workspace = @import("figure/workspace.zig");
const table_view = @import("table_view.zig");
const transport_fixture = @import("figure/transport_fixture.zig");
const fixed_panels = @import("fixed_panels.zig");
const buffer_list = @import("buffer_list.zig");
const editor_sequencer = @import("editor_sequencer.zig");
const transient = @import("transient.zig");
const tests = @import("figure/tests.zig");
const button = @import("ui/button.zig");
const vsync = @import("ui/vsync.zig");
const modes = @import("modes.zig");
const open = @import("open.zig");
const text_tools = @import("text_tools.zig");
const runner_test = @import("vcs/runner_test.zig");
const git = @import("vcs/git.zig");
const git_status_test = @import("vcs/git_status_test.zig");
const git_commit_test = @import("vcs/git_commit_test.zig");
const git_log_test = @import("vcs/git_log_test.zig");
const git_branch_test = @import("vcs/git_branch_test.zig");
const git_rebase_test = @import("vcs/git_rebase_test.zig");
const git_diff_test = @import("vcs/git_diff_test.zig");
const p4_test = @import("vcs/p4_test.zig");
const query_mod = @import("vcs/query.zig");
const p4_status_test = @import("vcs/p4_status_test.zig");
const org = @import("document/org.zig");
const sources = @import("document/sources.zig");
const document = @import("document/document.zig");
const view_mod = @import("document/view.zig");
const document_test = @import("document/document_test.zig");
const plugins_mod = @import("plugins.zig");
const sequencer = @import("figure/sequencer.zig");
const figure_ux_test = @import("figure_ux_test.zig");
const figure_table_rpc_test = @import("figure_table_rpc_test.zig");
const table_authoring = @import("table_authoring.zig");
const git_status = @import("vcs/git_status.zig");
const git_commit = @import("vcs/git_commit.zig");
const session = @import("figure/session.zig");
const stage = @import("stage.zig");
const git_log = @import("vcs/git_log.zig");
const git_rebase = @import("vcs/git_rebase.zig");
const style = @import("ui/style.zig");
const figure_view = @import("figure/view.zig");
const prompts = @import("figure/prompts.zig");
const names_mod = @import("figure/names.zig");
const drawing = @import("figure/drawing.zig");
const selection = @import("figure/selection.zig");
const commands_mod = @import("figure/commands.zig");
const weight = @import("figure/weight.zig");
const inspector = @import("inspector.zig");
test {
    _ = tests;
    _ = fixed_panels;
    _ = buffer_list;
    _ = button;
    _ = vsync;
    _ = modes;
    _ = open;
    _ = text_tools;
    _ = runner_test;
    _ = git;
    _ = git_status_test;
    _ = git_commit_test;
    _ = git_log_test;
    _ = git_branch_test;
    _ = git_rebase_test;
    _ = git_diff_test;
    _ = p4_test;
    _ = query_mod;
    _ = p4_status_test;
    _ = org;
    _ = sources;
    _ = document;
    _ = view_mod;
    _ = document_test;
    _ = plugins_mod;
    _ = sequencer;
    _ = figure_ux_test;
    _ = figure_table_rpc_test;
    _ = editor_sequencer;
}
const plugin = mesha.plugin;
const input_mod = mesha.input;
const os_mod = mesha.os;
const time_mod = mesha.time;
const sequencer_mod = mesha.sequencer;
const Atom = mesha.Atom;
const memory_mod = mesha.memory;
const Table = mesha.Table;

const panels_mod = mesha.panels;

const kScreenW: f32 = 1920;
const kScreenH: f32 = 1080;

/// Stands in for the host's `app` system: applies the editor's rows through its hook, keeping
/// the ones the hook keeps for the next application.
fn applyAppCommands(fx: *Fixture) void {
    const app_commands = plugin.app_commands;
    app_commands.Requests.of(&fx.mem, &fx.tables, app_commands.commands_table_name).drain(fx, applyAppCommand);
}

fn applyAppCommand(fx: *Fixture, payload: *plugin.app_commands.Payload) sequencer_mod.Applied {
    noteAnswerInbox(fx, payload);
    return lib.processCmd(&fx.tables, &fx.atoms, payload);
}

/// Remembers where a palette answer, or another answer the hook delivers, goes, for
/// `takeInboxMessage` to look.
fn noteAnswerInbox(fx: *Fixture, payload: *const plugin.app_commands.Payload) void {
    const reply = switch (payload.*) {
        .action_palette => |command| switch (command) {
            .emit => |emit| emit.reply,
            else => return,
        },
        .answer => |answering| answering.reply,
    };
    const inbox = reply.inbox;
    if (inbox == sequencer_mod.no_inbox) return;
    for (fx.answer_inboxes[0..fx.answer_inbox_count]) |known| if (known == inbox) return;
    fx.answer_inboxes[fx.answer_inbox_count] = inbox;
    fx.answer_inbox_count += 1;
}

/// The palette's answers waiting for the hook, in order.
fn appRequests(fx: *Fixture, into: []plugin.app_commands.Payload) []plugin.app_commands.Payload {
    const app_commands = plugin.app_commands;
    return app_commands.Requests.of(&fx.mem, &fx.tables, app_commands.commands_table_name).peek(into);
}

/// The requests the editor sent the panels since the fixture last reset its commands, in order.
fn panelRequests(tables: *Table.Registry, into: []plugin.panels.CmdPayload) []plugin.panels.CmdPayload {
    return plugin.panels.Requests.of(tables.memory, tables, plugin.panels.commands_table_name).peek(into);
}

fn panelRequestCount(tables: *Table.Registry) usize {
    var sent: [32]plugin.panels.CmdPayload = undefined;
    return panelRequests(tables, &sent).len;
}

fn panelRequestAt(tables: *Table.Registry, index: usize) ?plugin.panels.CmdPayload {
    var sent: [32]plugin.panels.CmdPayload = undefined;
    const requests = panelRequests(tables, &sent);
    if (index >= requests.len) return null;
    return requests[index];
}

/// The bar's text as it draws: after its system took the requests waiting for it.
fn hoverText(fx: *Fixture) ![]const u8 {
    const scratch = try fx.mem.tableScratchAllocator();
    try sequencer_mod.ensure(scratch, &fx.atoms, &fx.tables);
    const alone: sequencer_mod.Sequencer = .{ .name = "status_bar_test", .steps = &.{.{ .system = status_bar.system() }} };
    editor_sequencer.run(&fx.mem, &fx.atoms, &fx.tables, &alone, null);
    fx.tables.reclaimPayloads();
    return status_bar.hoverText(&fx.tables, &fx.atoms);
}

const Fixture = struct {
    mem: memory_mod.Memory = undefined,
    atoms: Atom.Registry = undefined,
    tables: Table.Registry = undefined,
    /// The inboxes the palette's answers went to, where the tests look for them.
    answer_inboxes: [8]Atom = undefined,
    answer_inbox_count: usize = 0,
    /// The text editors themselves: a test reports a text by setting it in its buffer.
    text_editors: mesha_runtime.text_editor.TextEditor = undefined,

    fn init(fx: *Fixture, allocator: std.mem.Allocator) !void {
        fx.answer_inbox_count = 0;
        fx.mem.init(allocator);
        errdefer fx.mem.deinit();
        try fx.atoms.init(&fx.mem);
        errdefer fx.atoms.deinit();
        try fx.tables.init(&fx.mem, 64);
        errdefer fx.tables.deinit();
        try mesha.panels.ensure(try fx.mem.tableScratchAllocator(), &fx.atoms, &fx.tables);
        try ensureReplyInboxes(fx);
        // Where the editor asks for actions to be invoked, which the actions host makes.
        try plugin.action_api.Requests.ensure(try fx.mem.tableScratchAllocator(), &fx.atoms, &fx.tables, plugin.action_api.commands_table_name);
        try plugin.app_commands.Requests.ensure(try fx.mem.tableScratchAllocator(), &fx.atoms, &fx.tables, plugin.app_commands.commands_table_name);
        try plugin.panels.Requests.ensure(try fx.mem.tableScratchAllocator(), &fx.atoms, &fx.tables, plugin.panels.commands_table_name);
        try os_mod.Requests.ensure(try fx.mem.tableScratchAllocator(), &fx.atoms, &fx.tables, os_mod.commands_table_name);
        // The palette's run loads its text editor. Its requests are not applied here: a test
        // looks at them, and sets the buffer's text by hand where the editor would have.
        try mesha_runtime.text_editor.ensure(try fx.mem.tableScratchAllocator(), &fx.atoms, &fx.tables);
        try fx.text_editors.init(allocator, &fx.mem, std.testing.io);
    }

    /// Forgets the commands queued and the requests sent the panels, the text editors and the
    /// editor's hook.
    fn resetCommands(fx: *Fixture) void {
        plugin.panels.Requests.of(&fx.mem, &fx.tables, plugin.panels.commands_table_name).reset();
        plugin.text_editor_api.Requests.of(&fx.mem, &fx.tables, plugin.text_editor_api.commands_table_name).reset();
        plugin.app_commands.Requests.of(&fx.mem, &fx.tables, plugin.app_commands.commands_table_name).reset();
    }

    fn deinit(fx: *Fixture) void {
        fx.text_editors.deinit(&fx.tables);
        fx.atoms.deinit();
        fx.tables.deinit();
        fx.mem.deinit();
    }
};

fn targetTable(allocator: std.mem.Allocator, atoms: *Atom.Registry, tables: *Table.Registry) !Table.Handle {
    var schema: Table.Schema = undefined;
    try schema.init(allocator, atoms, 1);
    defer schema.deinit();
    schema.addField("value", i32, .int);
    const ensured = try tables.ensure(&schema, 8, atoms.intern("test.target"), .durable);
    return ensured.handle;
}

fn actionByName(offered: plugin.Actions, atoms: *Atom.Registry, name: []const u8) ?plugin.action_api.Action {
    var actions = offered.iterate();
    while (actions.next()) |action| {
        if (action.id[1] == atoms.intern(name)) return action;
    }
    return null;
}

fn actionById(offered: plugin.Actions, atoms: *Atom.Registry, mode: []const u8, name: []const u8) ?plugin.action_api.Action {
    var actions = offered.iterate();
    const mode_atom = atoms.intern(mode);
    const name_atom = atoms.intern(name);
    while (actions.next()) |action| {
        if (action.id[0] == mode_atom and action.id[1] == name_atom) return action;
    }
    return null;
}

/// The actions a module declares, kept as declared, whatever inbox they name.
fn actionRows(fx: *Fixture) !plugin.ActionRows {
    const name = plugin.action_api.subscribed_table_name;
    try plugin.Actions.ensure(try fx.mem.tableScratchAllocator(), &fx.atoms, &fx.tables, name);
    return .{ .actions = plugin.Actions.of(&fx.mem, &fx.tables, name) };
}

/// An action to the table windows, as the editor delivers it to their system.
/// A click on the tracker chart toggle of the window at `handle`.
fn trackerChartToggle(fx: *Fixture, handle: Table.RowHandle) !void {
    // The window's row handle as the toggle's region carries it (`windows.WindowPayload`).
    const payload = extern struct { row: u32, generation: u32 }{ .row = handle.row, .generation = handle.generation };
    try windowsMessage(fx, .{ .tag = .from(windows.Msg.tracker_chart_toggle), .user_data = std.mem.asBytes(&payload) });
}

fn trackerAction(fx: *Fixture, tag: Atom) !void {
    try systemAction(fx, windows.system(), tag);
}

/// An action to an editor system as the actions host delivers it: to the system's inbox, then
/// taken in the system's run. Its commands reach the fixture's queue.
fn systemAction(fx: *Fixture, system: sequencer_mod.System, tag: Atom) !void {
    const steps = [_]sequencer_mod.Step{.{ .system = system }};
    const alone: sequencer_mod.Sequencer = .{ .name = "system_action_test", .steps = &steps };
    const scratch = try fx.mem.tableScratchAllocator();
    try sequencer_mod.ensure(scratch, &fx.atoms, &fx.tables);
    try sequencer_mod.ensureInboxes(scratch, &fx.atoms, &fx.tables, &alone);
    // As the actions host delivers an invoked action: to the system's inbox, under its tag.
    try std.testing.expect(system.claims(tag));
    try sequencer_mod.deliverMessage(&fx.tables, sequencer_mod.inboxOf(system), tag, &.{}, &.{});
    editor_sequencer.run(&fx.mem, &fx.atoms, &fx.tables, &alone, null);
}

/// The panels publish that the focus moved, and the editor's focus system follows it.
fn focusMove(fx: *Fixture, move: plugin.panels.Event) !void {
    const scratch = try fx.mem.tableScratchAllocator();
    try plugin.panels.Events.ensure(scratch, &fx.atoms, &fx.tables, plugin.panels.events_table_name);
    plugin.panels.Events.of(&fx.tables, plugin.panels.events_table_name).publish(move);
    try runSystem(fx, lib.focusSystem());
}

/// Runs `system` alone, as the editor's sequencer does, and reclaims what it took of its
/// command rows, as main does after its run.
fn runSystem(fx: *Fixture, system: sequencer_mod.System) !void {
    const steps = [_]sequencer_mod.Step{.{ .system = system }};
    const alone: sequencer_mod.Sequencer = .{ .name = "system_test", .steps = &steps };
    const scratch = try fx.mem.tableScratchAllocator();
    try sequencer_mod.ensure(scratch, &fx.atoms, &fx.tables);
    try sequencer_mod.ensureInboxes(scratch, &fx.atoms, &fx.tables, &alone);
    editor_sequencer.run(&fx.mem, &fx.atoms, &fx.tables, &alone, null);
    fx.tables.reclaimPayloads();
}

/// Table authoring applies the changes to tables' shapes asked for, as at the start of the
/// editor's run, and the windows take what they came to, as the next update does.
fn applyAuthoring(fx: *Fixture) !void {
    try runSystem(fx, table_authoring.system());
    try runSystem(fx, windows.system());
}

/// `received`, to the table windows as their subscriptions and regions address it: delivered
/// to their inbox and taken in their run.
fn windowsMessage(fx: *Fixture, received: sequencer_mod.Message) !void {
    try systemMessage(fx, windows.system(), received);
}

/// `received`, to `system`, which must claim it: delivered to its inbox and taken in its run.
fn systemMessage(fx: *Fixture, system: sequencer_mod.System, received: sequencer_mod.Message) !void {
    const scratch = try fx.mem.tableScratchAllocator();
    try sequencer_mod.ensureInboxes(scratch, &fx.atoms, &fx.tables, &.{ .name = "system_message_test", .steps = &.{.{ .system = system }} });
    try std.testing.expect(system.claims(received.tag));
    const inbox = sequencer_mod.inboxOf(system);
    try sequencer_mod.deliverMessage(&fx.tables, inbox, received.tag, received.user_data, received.payload);
    try runSystem(fx, system);
}

/// A palette answer as its owner takes it: the table windows' or the open system's when they
/// take its tag, else the editor's own handling, which must take it.
fn editorMessage(fx: *Fixture, received: sequencer_mod.Message) !void {
    if (windows.system().claims(received.tag)) return windowsMessage(fx, received);
    if (open.system().claims(received.tag)) return systemMessage(fx, open.system(), received);
    try std.testing.expect(lib.updateMessage(&fx.mem, &fx.tables, &fx.atoms, received));
}

/// An invoked action as the actions host delivers it, under its tag with the declarer's user
/// data: to the table windows when they take its tag, else to the editor's own handling,
/// which must take it.
fn editorAction(fx: *Fixture, received: sequencer_mod.Message) !void {
    if (windows.system().claims(received.tag)) return windowsMessage(fx, received);
    try std.testing.expect(lib.updateMessage(&fx.mem, &fx.tables, &fx.atoms, received));
}

/// The names of the actions asked to be invoked, as rows of `commands.actions`, which the
/// fixture makes.
fn invokedActions(fx: *Fixture, names: *[8]Atom) []const Atom {
    const requests = plugin.action_api.Requests.of(&fx.mem, &fx.tables, plugin.action_api.commands_table_name);
    var commands: [8]plugin.action_api.Command = undefined;
    var count: usize = 0;
    for (requests.peek(&commands)) |command| {
        switch (command) {
            .invoke => |id| {
                names[count] = id[1];
                count += 1;
            },
            .set_modes, .enable_minor, .disable_minor, .register_mode => {},
        }
    }
    return names[0..count];
}

/// The palette takes the requests appended for it, as at the end of the editor's run.
fn runPalette(fx: *Fixture) !void {
    try runSystem(fx, action_palette.system());
}

/// `message`, a key or text editor report for the palette, as its subscriptions address it:
/// delivered to its input system's inbox, which copies it whole, and taken in that system's
/// run. `message` is a message struct with a `header`, or a bare header.
fn paletteMessage(fx: *Fixture, received: sequencer_mod.Message) !void {
    const scratch = try fx.mem.tableScratchAllocator();
    try sequencer_mod.ensureInboxes(scratch, &fx.atoms, &fx.tables, &.{ .name = "palette_test", .steps = &.{.{ .system = action_palette.inputSystem() }} });
    try std.testing.expect(action_palette.inputSystem().claims(received.tag));
    const inbox = sequencer_mod.inboxOf(action_palette.inputSystem());
    try sequencer_mod.deliverMessage(&fx.tables, inbox, received.tag, received.user_data, received.payload);
    try runSystem(fx, action_palette.inputSystem());
}

/// A click on the palette's completion `index`.
fn paletteInvoke(fx: *Fixture, index: u32) !void {
    try paletteMessage(fx, .{ .tag = action_palette.Msg.invoke, .user_data = std.mem.asBytes(&index) });
}

/// A key `tag` at the palette, with no body.
fn paletteKey(fx: *Fixture, tag: Atom) !void {
    try paletteMessage(fx, .{ .tag = tag });
}

/// Submits `name` at the open prompt, whose text editor reports it as the submit asks, and
/// hands its owner what the palette sent, the changed text and then the answer. The palette
/// then takes up what the owner did: an acknowledgement, or a prompt presented again.
fn submitPromptText(fx: *Fixture, name: []const u8) !void {
    try paletteKey(fx, action_palette.Msg.submit);
    try editorReport(fx, name);
    try dispatchEditorCommands(fx);
    var answered = false;
    // Every answer is taken before any is handed on: the owner's run takes its whole inbox.
    var waiting: [8]sequencer_mod.Message = undefined;
    var waiting_count: usize = 0;
    while (takeInboxMessage(fx)) |received| {
        waiting[waiting_count] = received;
        waiting_count += 1;
    }
    for (waiting[0..waiting_count]) |received| {
        const event = try action_palette.eventOf(received);
        answered = answered or event.kind == .completed;
        try editorMessage(fx, received);
    }
    try std.testing.expect(answered);
    try runPalette(fx);
}

test "with no panel open nothing opens, and a buffer shown makes its window, which takes the focus" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    // A text panel's run subscribes to the pointer.
    try input_mod.ensureTables(try fx.mem.tableScratchAllocator(), &fx.atoms, &fx.tables);
    const scratch = plugin.text_editor_api.scratch_buffer;
    fx.text_editors.apply(&fx.tables, .{ .create = .{ .buffer = scratch, .lines = .multi, .name = plugin.text_editor_api.scratch_name } });
    fx.text_editors.publish(&fx.tables);
    fx.resetCommands();

    // The window is left empty.
    try runSystem(&fx, text_panel.system());
    try std.testing.expectEqual(@as(usize, 0), textPanelsOpened(&fx).count);

    // A buffer shown with no panel to show it in makes one.
    text_panel.showBuffer(&fx.tables, scratch, .this_window);
    try runSystem(&fx, text_panel.system());
    const opened = textPanelsOpened(&fx);
    try std.testing.expectEqual(@as(usize, 1), opened.count);
    try std.testing.expectEqual(scratch, textWindow(&fx, opened.last).?.buffer.*);
    applyPanelRequests(&fx);
    try std.testing.expect(panels_mod.hasFocus(&fx.tables, &fx.atoms, opened.last));
}

/// A fixture with the editor and a `*scratch*` buffer, and a window on it open and shown, as
/// at a start: returns that window's panel.
fn startWithScratchWindow(fx: *Fixture) !Atom {
    try fx.init(std.testing.allocator);
    errdefer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    return openScratchWindow(fx);
}

/// With the editor started, a `*scratch*` buffer and a window on it, open and shown: returns
/// that window's panel.
fn openScratchWindow(fx: *Fixture) !Atom {
    // A text panel's run subscribes to the pointer.
    try input_mod.ensureTables(try fx.mem.tableScratchAllocator(), &fx.atoms, &fx.tables);
    const scratch = plugin.text_editor_api.scratch_buffer;
    fx.text_editors.apply(&fx.tables, .{ .create = .{ .buffer = scratch, .lines = .multi, .name = plugin.text_editor_api.scratch_name } });
    fx.text_editors.publish(&fx.tables);
    fx.resetCommands();
    text_panel.showBuffer(&fx.tables, scratch, .this_window);
    try runSystem(fx, text_panel.system());
    const opened = textPanelsOpened(fx);
    try std.testing.expectEqual(@as(usize, 1), opened.count);
    applyPanelRequests(fx);
    // Shown once, the window is one whose panel closing takes its row.
    try runSystem(fx, text_panel.system());
    applyPanelRequests(fx);
    return opened.last;
}

/// Opens and closes panels as the systems declare them, then applies the panels' requests
/// waiting and forgets them: what the host's panels system does after a run.
fn applyPanelRequests(fx: *Fixture) void {
    _ = panels_mod.applyFrame(&fx.mem, &fx.tables, &fx.atoms);
    fx.resetCommands();
}

/// How many text panels the text panels' system declares that are not open yet, which the
/// panels system opens next, and the last of them.
fn textPanelsOpened(fx: *Fixture) struct { count: usize, last: Atom } {
    var count: usize = 0;
    var last: Atom = @enumFromInt(0);
    var declared = plugin.panels.Declared.of(&fx.mem, &fx.tables, plugin.panels.declared_table_name).iterate();
    while (declared.next()) |panel| {
        if (!text_panel.isPanel(panel.id) or panels_mod.isOpen(&fx.tables, &fx.atoms, panel.id)) continue;
        count += 1;
        last = panel.id;
    }
    return .{ .count = count, .last = last };
}

test "a text panel takes its cell from its font's metrics, and a zoom keeps its first line with no drawing" {
    var fx: Fixture = .{};
    const panel = try startWithScratchWindow(&fx);
    defer fx.deinit();
    // No font is loaded yet: nothing to scroll by.
    try std.testing.expectEqual(@as(f32, 0), textCell(&fx, panel).line_height.*);

    const resources = mesha.resources;
    try resources.ensureFontMetrics(std.testing.allocator, &fx.atoms, &fx.tables);
    const metrics = fx.tables.findByName(Atom.from(resources.font_metrics_table_name)).?;
    const opened_size = textCell(&fx, panel).text_size.*;
    const opened_font = text_panel.text_sizes[opened_size];
    const smaller_font = text_panel.text_sizes[opened_size - 1];
    for ([_]struct { font: text_panel.TextSize, advance: f32 }{ .{ .font = opened_font, .advance = 14 }, .{ .font = smaller_font, .advance = 12 } }) |loaded| {
        _ = try metrics.tryInsert(.{
            .scope = resources.kApplicationScope,
            .name = loaded.font.font.name,
            .pixel_height = loaded.font.pixel_height,
            .ascender = loaded.font.pixel_height,
            .cap_height = loaded.font.pixel_height,
            .mono_advance = loaded.advance,
        });
    }

    // The font arrived: the panel's run takes its cell, a line of the font and its spacing.
    try runSystem(&fx, text_panel.system());
    const line_height = textCell(&fx, panel).line_height.*;
    try std.testing.expect(line_height > opened_font.pixel_height);
    try std.testing.expectEqual(@as(f32, 14), textCell(&fx, panel).cell_width.*);

    // Scrolled three lines down, then zoomed out a size: the same line stays at the top.
    textCell(&fx, panel).scroll_y.* = 3 * line_height;
    textCell(&fx, panel).text_size.* = opened_size - 1;
    try runSystem(&fx, text_panel.system());
    const smaller_line_height = textCell(&fx, panel).line_height.*;
    try std.testing.expectEqual(line_height - (opened_font.pixel_height - smaller_font.pixel_height), smaller_line_height);
    try std.testing.expectEqual(@as(f32, 12), textCell(&fx, panel).cell_width.*);
    try std.testing.expectEqual(3 * smaller_line_height, textCell(&fx, panel).scroll_y.*);
}

const TextCell = struct { panel: *Atom, text_size: *u8, line_height: *f32, cell_width: *f32, scroll_y: *f32 };

/// The cell and scroll of `panel`'s window, as its row holds them now.
fn textCell(fx: *Fixture, panel: Atom) TextCell {
    const windows_table = fx.tables.findByName(Atom.from(text_panel.table_name)).?;
    var rows = windows_table.query(TextCell);
    while (rows.next()) |found| {
        if (found.view.panel.* == panel) return found.view;
    }
    unreachable;
}

const TextWindow = struct { panel: *Atom, buffer: *Atom, has_point: *u8 };

fn textWindow(fx: *Fixture, panel: Atom) ?Table.ReadView(TextWindow) {
    const windows_table = fx.tables.findByName(Atom.from(text_panel.table_name)).?;
    var rows = windows_table.readQuery(TextWindow);
    while (rows.next()) |found| {
        if (found.view.panel.* == panel) return found.view;
    }
    return null;
}

/// Runs the text panels for as many frames as a window closed with every other waits before
/// it opens again.
fn settleTextPanels(fx: *Fixture) !void {
    for (0..6) |_| try runSystem(fx, text_panel.system());
}

/// The text editor's requests waiting, in order.
fn textEditorRequests(fx: *Fixture, into: []plugin.text_editor_api.CmdPayload) []plugin.text_editor_api.CmdPayload {
    return plugin.text_editor_api.Requests.of(&fx.mem, &fx.tables, plugin.text_editor_api.commands_table_name).peek(into);
}

/// The one request waiting that asks which encodings the host converts.
fn encodingsAsked(fx: *Fixture) !@FieldType(plugin.text_editor_api.CmdPayload, "supported_encodings") {
    var sent: [64]plugin.text_editor_api.CmdPayload = undefined;
    var found: ?@FieldType(plugin.text_editor_api.CmdPayload, "supported_encodings") = null;
    for (textEditorRequests(fx, &sent)) |request| {
        if (request != .supported_encodings) continue;
        try std.testing.expect(found == null);
        found = request.supported_encodings;
    }
    return found orelse error.NothingAsked;
}

/// The labels the last prompt the palette was asked to present or replace offers, and
/// forgets the palette's requests.
fn encodingsOffered(fx: *Fixture, into: [][]const u8) ![]const []const u8 {
    const requests = action_palette.Requests.of(&fx.mem, &fx.tables, action_palette.requests_table_name);
    var sent: [16]action_palette.Request = undefined;
    var offered: ?*const action_palette.Completions = null;
    for (requests.peek(&sent)) |request| switch (request) {
        .present => |present| offered = present.completions,
        .replace => |replacing| offered = replacing.completions,
        else => {},
    };
    const completions = offered orelse return error.NothingPresented;
    try std.testing.expectEqualStrings("Save in encoding", completions.title);
    for (completions.entries, 0..) |entry, index| into[index] = entry.label;
    requests.reset();
    return into[0..completions.entries.len];
}

/// The labels and the details of the last prompt the palette was asked to present, titled
/// `title`, and forgets the palette's requests.
fn entriesOffered(fx: *Fixture, title: []const u8, labels: [][]const u8, details: [][]const u8) ![]const []const u8 {
    const requests = action_palette.Requests.of(&fx.mem, &fx.tables, action_palette.requests_table_name);
    var sent: [16]action_palette.Request = undefined;
    var offered: ?*const action_palette.Completions = null;
    for (requests.peek(&sent)) |request| switch (request) {
        .present => |present| offered = present.completions,
        else => {},
    };
    const completions = offered orelse return error.NothingPresented;
    try std.testing.expectEqualStrings(title, completions.title);
    for (completions.entries, 0..) |entry, index| {
        labels[index] = entry.label;
        details[index] = entry.detail;
    }
    requests.reset();
    return labels[0..completions.entries.len];
}

test "the buffers listed hold the figures, the latest visited first: the one shown last to switch to, first to kill" {
    const allocator = std.testing.allocator;
    var fx: Fixture = .{};
    try fx.init(allocator);
    defer fx.deinit();
    const context = mesha.figure.Context{ .memory = &fx.mem, .tables = &fx.tables, .atoms = &fx.atoms };
    try figure_runtime.init(context);
    defer figure_runtime.deinit(context) catch unreachable;
    try initFigureOpening(&fx);
    const own = try openScratchWindow(&fx);
    const blue = fx.atoms.intern("blue");
    const scope = mesha.resources.applicationScope(fx.tables.memory);
    try figure_runtime.domain.library.create(&fx.tables, &fx.atoms, .{ .scope = scope, .doc = blue, .path = "/home/someone/art/blue.mshf" });
    try transport_fixture.synchronize(&fx.mem, &fx.atoms, &fx.tables);
    const note = openNoteBuffer(&fx, modes.buffer);
    // *scratch* shown and focused, visited after the figure and the note.
    buffer_list.visit(&fx.tables, .figure, blue);
    buffer_list.visit(&fx.tables, .text, note);
    buffer_list.visit(&fx.tables, .text, plugin.text_editor_api.scratch_buffer);
    state.setViewFocus(&fx.tables, &fx.atoms, own);
    fx.resetCommands();

    var labels: [16][]const u8 = undefined;
    var details: [16][]const u8 = undefined;
    try systemAction(&fx, text_panel.system(), Atom.from("text_switch_buffer"));
    const switching = try entriesOffered(&fx, "Switch to buffer", &labels, &details);
    try std.testing.expectEqualStrings("*note*", switching[0]);
    try std.testing.expectEqualStrings("blue", switching[1]);
    try std.testing.expect(std.mem.startsWith(u8, details[1], "Figure"));
    try std.testing.expectEqualStrings("*scratch*", switching[switching.len - 1]);

    try systemAction(&fx, text_panel.system(), Atom.from("text_kill_buffer"));
    const killing = try entriesOffered(&fx, "Kill buffer", &labels, &details);
    try std.testing.expectEqualStrings("*scratch*", killing[0]);
    try std.testing.expectEqualStrings("*note*", killing[1]);
    try std.testing.expectEqualStrings("blue", killing[2]);
}

/// The palette's event `event` for the encodings' prompt, as its owner hears it.
fn encodingPromptEvent(fx: *Fixture, event: action_palette.Msg.Event) !void {
    const tag = Atom.from("text_panel_encoding");
    const received = try paletteEvent(fx, tag, event);
    const buffer = plugin.text_editor_api.scratch_buffer;
    try sequencer_mod.deliverMessage(&fx.tables, sequencer_mod.inboxOf(text_panel.system()), tag, std.mem.asBytes(&buffer), received.payload);
    try runSystem(fx, text_panel.system());
}

test "the encodings offered are UTF-8 alone until the host says which it converts, and a name typed is asked about" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    // Nothing is asked of the host until an encodings' prompt opens.
    try std.testing.expectError(error.NothingAsked, encodingsAsked(&fx));
    _ = try openScratchWindow(&fx);
    var labels: [plugin.text_editor_api.known_encodings.len + 1][]const u8 = undefined;

    // The first prompt asks which of the known encodings the host converts, and before the
    // answer offers UTF-8 alone, guessing nothing.
    try systemAction(&fx, text_panel.system(), Atom.from("text_set_encoding"));
    const asked = try encodingsAsked(&fx);
    try std.testing.expectEqualStrings("", asked.name);
    const reply = asked.reply;
    const before = try encodingsOffered(&fx, &labels);
    try std.testing.expectEqual(@as(usize, 1), before.len);
    try std.testing.expectEqualStrings("UTF-8", before[0]);

    // The answer comes next frame; the encodings the host converts are offered after it.
    fx.text_editors.apply(&fx.tables, .{ .supported_encodings = .{ .name = "", .reply = reply } });
    fx.resetCommands();
    try runSystem(&fx, text_panel.system());
    try systemAction(&fx, text_panel.system(), Atom.from("text_set_encoding"));
    const after = try encodingsOffered(&fx, &labels);
    try std.testing.expect(after.len > 8);
    try std.testing.expectEqualStrings("UTF-8", after[0]);
    try std.testing.expectEqualStrings("UTF-16LE", after[1]);
    for (after) |label| try std.testing.expect(std.mem.indexOf(u8, label, "NO-SUCH") == null);
    // With the answer kept, a prompt opened again asks nothing.
    try std.testing.expectError(error.NothingAsked, encodingsAsked(&fx));
    fx.resetCommands();

    // A name typed that is none of the known ones is asked about, and offered once the
    // answer says the host converts it.
    try encodingPromptEvent(&fx, .{ .kind = .query_changed, .completion = null, .query = "latin1" });
    const unanswered = try encodingsOffered(&fx, &labels);
    try std.testing.expectEqual(@as(usize, 0), unanswered.len);
    const typed_ask = try encodingsAsked(&fx);
    try std.testing.expectEqualStrings("latin1", typed_ask.name);
    mesha_runtime.text_editor.applyCommands(&fx.mem, &fx.atoms, &fx.tables, &fx.text_editors);
    try runSystem(&fx, text_panel.system());
    try encodingPromptEvent(&fx, .{ .kind = .query_changed, .completion = null, .query = "latin1" });
    const typed = try encodingsOffered(&fx, &labels);
    try std.testing.expectEqual(@as(usize, 1), typed.len);
    try std.testing.expectEqualStrings("latin1", typed[0]);
    try std.testing.expectError(error.NothingAsked, encodingsAsked(&fx));

    // Submitted with nothing offered, a name with no answer yet is asked about, and used once
    // the answer says the host converts it, with the line endings its suffix names.
    const nothing_chosen: action_palette.Completion = .{ .label = "" };
    try encodingPromptEvent(&fx, .{ .kind = .completed, .completion = nothing_chosen, .query = "cp1252-dos" });
    const submitted_ask = try encodingsAsked(&fx);
    try std.testing.expectEqualStrings("cp1252", submitted_ask.name);
    mesha_runtime.text_editor.applyCommands(&fx.mem, &fx.atoms, &fx.tables, &fx.text_editors);
    try runSystem(&fx, text_panel.system());
    const used = encodingChanges(&fx);
    try std.testing.expectEqualStrings("cp1252", used.encoding.?);
    try std.testing.expectEqual(plugin.text_editor_api.LineEnding.crlf, used.line_ending.?);
    try std.testing.expect(used.told == null);
    fx.resetCommands();

    // One the host does not convert is refused with a sentence, and nothing is changed.
    try encodingPromptEvent(&fx, .{ .kind = .completed, .completion = nothing_chosen, .query = "NO-SUCH-ENCODING" });
    const refused_ask = try encodingsAsked(&fx);
    try std.testing.expectEqualStrings("NO-SUCH-ENCODING", refused_ask.name);
    mesha_runtime.text_editor.applyCommands(&fx.mem, &fx.atoms, &fx.tables, &fx.text_editors);
    try runSystem(&fx, text_panel.system());
    const refused = encodingChanges(&fx);
    try std.testing.expect(refused.encoding == null and refused.line_ending == null);
    try std.testing.expectEqualStrings("The file's encoding is not changed to NO-SUCH-ENCODING: this platform does not convert it", refused.told.?);
    fx.resetCommands();

    // A name no encoding can have is refused as that at once, not asked about.
    try encodingPromptEvent(&fx, .{ .kind = .completed, .completion = nothing_chosen, .query = "UTF-8" ++ "x" ** 60 });
    try std.testing.expectError(error.NothingAsked, encodingsAsked(&fx));
    const not_a_name = encodingChanges(&fx);
    try std.testing.expect(not_a_name.encoding == null and not_a_name.line_ending == null);
    try std.testing.expectEqualStrings("Not an encoding's name: one has at most 40 bytes and no control characters", not_a_name.told.?);
}

const EncodingChanges = struct {
    encoding: ?[]const u8 = null,
    line_ending: ?plugin.text_editor_api.LineEnding = null,
    told: ?[]const u8 = null,
};

/// What the text editor's requests waiting change of a buffer's encoding, and tell the person.
fn encodingChanges(fx: *Fixture) EncodingChanges {
    var changes: EncodingChanges = .{};
    var sent: [64]plugin.text_editor_api.CmdPayload = undefined;
    for (textEditorRequests(fx, &sent)) |request| switch (request) {
        .set_encoding => |set| changes.encoding = set.encoding,
        .set_line_ending => |set| changes.line_ending = set.ending,
        .message => |line| changes.told = line,
        else => {},
    };
    return changes;
}

test "the figure stage takes the focused text window's place, and a buffer shown from the stage takes the stage's" {
    var fx: Fixture = .{};
    const own = try startWithScratchWindow(&fx);
    defer fx.deinit();
    const figure_stage = Atom.from(fixed_panels.figure_stage);
    // A second window, beside the first, which keeps the focus.
    try systemAction(&fx, text_panel.system(), Atom.from("text_split_right"));
    const other = textPanelsOpened(&fx).last;
    applyPanelRequests(&fx);
    try runSystem(&fx, text_panel.system());
    applyPanelRequests(&fx);
    try std.testing.expect(panels_mod.hasFocus(&fx.tables, &fx.atoms, own));
    const own_frame = panels_mod.panelFor(&fx.tables, &fx.atoms, own).?.frame;

    // Opening a figure: the figure_stage opens where the focused window was, with its frame and the
    // focus, and the window's row goes, so it does not open again.
    fixed_panels.showInPlace(&fx.tables, &fx.atoms, figure_stage);
    try runSystem(&fx, text_panel.system());
    try runSystem(&fx, fixed_panels.shownPanelsSystem());
    applyPanelRequests(&fx);
    try std.testing.expect(panels_mod.hasFocus(&fx.tables, &fx.atoms, figure_stage));
    try std.testing.expectEqual(own_frame, panels_mod.panelFor(&fx.tables, &fx.atoms, figure_stage).?.frame);
    try std.testing.expect(!panels_mod.isOpen(&fx.tables, &fx.atoms, own));
    try settleTextPanels(&fx);
    try std.testing.expect(textWindow(&fx, own) == null);
    try std.testing.expectEqual(@as(usize, 0), textPanelsOpened(&fx).count);
    try std.testing.expect(panels_mod.isOpen(&fx.tables, &fx.atoms, other));

    // A buffer chosen while the figure_stage has the focus opens in the figure_stage's place, which closes.
    state.setViewFocus(&fx.tables, &fx.atoms, figure_stage);
    const note = openNoteBuffer(&fx, modes.buffer);
    text_panel.showBuffer(&fx.tables, note, .this_window);
    try runSystem(&fx, text_panel.system());
    try runSystem(&fx, fixed_panels.shownPanelsSystem());
    const shown_note = textPanelsOpened(&fx).last;
    applyPanelRequests(&fx);
    try std.testing.expect(!fixed_panels.panelShown(&fx.tables, figure_stage));
    try std.testing.expect(!panels_mod.isOpen(&fx.tables, &fx.atoms, figure_stage));
    try std.testing.expect(panels_mod.hasFocus(&fx.tables, &fx.atoms, shown_note));
    try std.testing.expectEqual(own_frame, panels_mod.panelFor(&fx.tables, &fx.atoms, shown_note).?.frame);
    try std.testing.expectEqual(note, textWindow(&fx, shown_note).?.buffer.*);
}

/// A buffer of the test's own that no window shows, with `mode` its own major mode.
fn openNoteBuffer(fx: *Fixture, mode: Atom) Atom {
    const note = Atom.from("*note*");
    fx.text_editors.apply(&fx.tables, .{ .create = .{ .buffer = note, .lines = .multi, .name = "*note*" } });
    fx.text_editors.publish(&fx.tables);
    text_panel.setBufferMode(&fx.tables, note, mode);
    return note;
}

test "a buffer shown in the other window from a text window opens beside it, takes the focus and has its own mode" {
    var fx: Fixture = .{};
    const own = try startWithScratchWindow(&fx);
    defer fx.deinit();
    try plugin.action_api.ensureTables(try fx.mem.tableScratchAllocator(), &fx.atoms, &fx.tables);
    var published: panels_mod.FocusTarget = .{};
    state.setViewFocus(&fx.tables, &fx.atoms, own);
    panels_mod.dispatchFocusChanges(&fx.tables, &fx.atoms, &published);
    try runSystem(&fx, text_panel.modesSystem());
    try std.testing.expectEqual(modes.buffer, try routedMajor(&fx));

    const note = openNoteBuffer(&fx, modes.vcs_message);
    text_panel.showBuffer(&fx.tables, note, .other_window);
    try runSystem(&fx, text_panel.system());
    // A window of its own beside the focused one, which stays on `*scratch*`.
    const opened = textPanelsOpened(&fx);
    try std.testing.expectEqual(@as(usize, 1), opened.count);
    try std.testing.expectEqual(note, textWindow(&fx, opened.last).?.buffer.*);
    try std.testing.expectEqual(plugin.text_editor_api.scratch_buffer, textWindow(&fx, own).?.buffer.*);
    applyPanelRequests(&fx);
    try std.testing.expect(panels_mod.hasFocus(&fx.tables, &fx.atoms, opened.last));
    // Its window's major mode is the buffer's own, under `buffer`.
    panels_mod.dispatchFocusChanges(&fx.tables, &fx.atoms, &published);
    try runSystem(&fx, text_panel.modesSystem());
    try std.testing.expectEqual(modes.vcs_message, try routedMajor(&fx));

    // Back on the first window, the mode is `buffer` again; set back to `buffer`, the note's
    // window has `buffer` too.
    panels_mod.applyCmd(&fx.tables, &fx.atoms, .{ .focus = .{ .id = own } });
    panels_mod.dispatchFocusChanges(&fx.tables, &fx.atoms, &published);
    try runSystem(&fx, text_panel.modesSystem());
    try std.testing.expectEqual(modes.buffer, try routedMajor(&fx));
    text_panel.setBufferMode(&fx.tables, note, modes.buffer);
    panels_mod.applyCmd(&fx.tables, &fx.atoms, .{ .focus = .{ .id = opened.last } });
    panels_mod.dispatchFocusChanges(&fx.tables, &fx.atoms, &published);
    try runSystem(&fx, text_panel.modesSystem());
    try std.testing.expectEqual(modes.buffer, try routedMajor(&fx));
}

test "a buffer shown in the other window from a panel that is not a text window goes in the text window there" {
    var fx: Fixture = .{};
    const own = try startWithScratchWindow(&fx);
    defer fx.deinit();
    // vcs-git has the focus, a window on `*scratch*` beside it.
    state.setViewFocus(&fx.tables, &fx.atoms, Atom.from("vcs_git"));
    const note = openNoteBuffer(&fx, modes.vcs_message);
    text_panel.showBuffer(&fx.tables, note, .other_window);
    try runSystem(&fx, text_panel.system());
    try std.testing.expectEqual(@as(usize, 0), textPanelsOpened(&fx).count);
    try std.testing.expectEqual(note, textWindow(&fx, own).?.buffer.*);
    applyPanelRequests(&fx);
    try std.testing.expect(panels_mod.hasFocus(&fx.tables, &fx.atoms, own));

    // A buffer asked for before it is open is shown once it opens.
    const later = Atom.from("*later*");
    text_panel.showBuffer(&fx.tables, later, .this_window);
    try runSystem(&fx, text_panel.system());
    try std.testing.expectEqual(note, textWindow(&fx, own).?.buffer.*);
    fx.text_editors.apply(&fx.tables, .{ .create = .{ .buffer = later, .lines = .multi, .name = "*later*" } });
    fx.text_editors.publish(&fx.tables);
    state.setViewFocus(&fx.tables, &fx.atoms, own);
    try runSystem(&fx, text_panel.system());
    try std.testing.expectEqual(later, textWindow(&fx, own).?.buffer.*);

    // A buffer closed takes its mode with it.
    fx.text_editors.apply(&fx.tables, .{ .close = note });
    fx.text_editors.publish(&fx.tables);
    try runSystem(&fx, text_panel.system());
    const buffer_modes = fx.tables.findByName(Atom.from(text_panel.buffer_modes_table_name)).?;
    try std.testing.expectEqual(@as(u32, 0), buffer_modes.count());
}

test "a buffer shown by request gives its window back as it closes, and a window made for it closes" {
    var fx: Fixture = .{};
    const own = try startWithScratchWindow(&fx);
    defer fx.deinit();
    // The window shows a buffer of the person's, `*work*`, with `*scratch*` hidden.
    const work = Atom.from("*work*");
    fx.text_editors.apply(&fx.tables, .{ .create = .{ .buffer = work, .lines = .multi, .name = "*work*" } });
    fx.text_editors.publish(&fx.tables);
    state.setViewFocus(&fx.tables, &fx.atoms, own);
    text_panel.showBuffer(&fx.tables, work, .this_window);
    try runSystem(&fx, text_panel.system());
    try std.testing.expectEqual(work, textWindow(&fx, own).?.buffer.*);

    // From vcs-git, the note goes in that window; closed, the window shows `*work*` again, not
    // the `*scratch*` a killed buffer's window would take.
    state.setViewFocus(&fx.tables, &fx.atoms, Atom.from("vcs_git"));
    const note = openNoteBuffer(&fx, modes.vcs_message);
    text_panel.showBuffer(&fx.tables, note, .other_window);
    try runSystem(&fx, text_panel.system());
    try std.testing.expectEqual(note, textWindow(&fx, own).?.buffer.*);
    applyPanelRequests(&fx);
    fx.text_editors.apply(&fx.tables, .{ .close = note });
    fx.text_editors.publish(&fx.tables);
    try runSystem(&fx, text_panel.system());
    try std.testing.expectEqual(work, textWindow(&fx, own).?.buffer.*);
    // The window stays, so it gives the focus back to the panel before it.
    try std.testing.expectEqual(@as(usize, 1), focusPreviousAsked(&fx));
    applyPanelRequests(&fx);

    // Shown again in that window, which takes the focus, the note closes after the person has
    // moved the focus on to a third panel: the request is the window's, and nothing moves.
    const third = Atom.from("third_panel");
    state.setViewFocus(&fx.tables, &fx.atoms, Atom.from("vcs_git"));
    const shown_again = openNoteBuffer(&fx, modes.vcs_message);
    text_panel.showBuffer(&fx.tables, shown_again, .other_window);
    try runSystem(&fx, text_panel.system());
    applyPanelRequests(&fx);
    try std.testing.expect(panels_mod.hasFocus(&fx.tables, &fx.atoms, own));
    panels_mod.openNow(&fx.tables, &fx.atoms, .{ .id = third, .root = third, .beside = own, .side = .right });
    try std.testing.expect(panels_mod.hasFocus(&fx.tables, &fx.atoms, third));
    fx.text_editors.apply(&fx.tables, .{ .close = shown_again });
    fx.text_editors.publish(&fx.tables);
    try runSystem(&fx, text_panel.system());
    try std.testing.expectEqual(work, textWindow(&fx, own).?.buffer.*);
    try std.testing.expectEqual(@as(usize, 1), focusPreviousAsked(&fx));
    applyPanelRequests(&fx);
    try std.testing.expect(panels_mod.hasFocus(&fx.tables, &fx.atoms, third));
    panels_mod.closeNow(&fx.tables, &fx.atoms, third);

    // From the window itself, the other window is made for it, and goes as it closes.
    state.setViewFocus(&fx.tables, &fx.atoms, own);
    const again = openNoteBuffer(&fx, modes.vcs_message);
    text_panel.showBuffer(&fx.tables, again, .other_window);
    try runSystem(&fx, text_panel.system());
    const made = textPanelsOpened(&fx);
    try std.testing.expectEqual(@as(usize, 1), made.count);
    applyPanelRequests(&fx);
    fx.text_editors.apply(&fx.tables, .{ .close = again });
    fx.text_editors.publish(&fx.tables);
    try runSystem(&fx, text_panel.system());
    try std.testing.expect(textWindow(&fx, made.last) == null);
    // Its closing gives the focus back: nothing asks it again.
    try std.testing.expectEqual(@as(usize, 0), focusPreviousAsked(&fx));
    try std.testing.expectEqual(work, textWindow(&fx, own).?.buffer.*);

    // A buffer asked for that never opens is forgotten after a few runs, with its own mode.
    const never = Atom.from("*never*");
    text_panel.setBufferMode(&fx.tables, never, modes.vcs_message);
    text_panel.showBuffer(&fx.tables, never, .other_window);
    for (0..10) |_| try runSystem(&fx, text_panel.system());
    // Only `*work*`'s row is left, its window still showing it.
    const requests = fx.tables.findByName(Atom.from(text_panel.show_requests_table_name)).?;
    var remembered = requests.readQuery(struct { buffer: *Atom });
    while (remembered.next()) |found| try std.testing.expectEqual(work, found.view.buffer.*);
    const buffer_modes = fx.tables.findByName(Atom.from(text_panel.buffer_modes_table_name)).?;
    try std.testing.expectEqual(@as(u32, 0), buffer_modes.count());
}

/// How many `focus_previous` requests wait for the panels system.
fn focusPreviousAsked(fx: *Fixture) usize {
    const requests = plugin.panels.Requests.of(&fx.mem, &fx.tables, plugin.panels.commands_table_name);
    var sent: [32]plugin.panels.CmdPayload = undefined;
    const waiting = requests.peek(&sent);
    var count: usize = 0;
    for (waiting) |request| {
        if (request == .focus_previous) count += 1;
    }
    return count;
}

test "a buffer shown by request and closed while no text window is open leaves no row behind" {
    var fx: Fixture = .{};
    const own = try startWithScratchWindow(&fx);
    defer fx.deinit();
    const note = openNoteBuffer(&fx, modes.vcs_message);
    state.setViewFocus(&fx.tables, &fx.atoms, own);
    text_panel.showBuffer(&fx.tables, note, .this_window);
    try runSystem(&fx, text_panel.system());
    try std.testing.expectEqual(note, textWindow(&fx, own).?.buffer.*);

    // With the window gone, the figure stage shown, the note closes while no text window is open:
    // the row of the note, shown, goes with it.
    fixed_panels.layOutNow(&fx.tables, &fx.atoms, .figure_stage);
    fx.tables.findByName(Atom.from(text_panel.table_name)).?.clear();
    try runSystem(&fx, text_panel.system());
    fx.text_editors.apply(&fx.tables, .{ .close = note });
    fx.text_editors.publish(&fx.tables);
    try runSystem(&fx, text_panel.system());
    const requests = fx.tables.findByName(Atom.from(text_panel.show_requests_table_name)).?;
    var remembered = requests.readQuery(struct { buffer: *Atom });
    while (remembered.next()) |found| try std.testing.expect(found.view.buffer.* != note);
}

test "vcs git commit: a window on the message buffer has the vcs_message mode" {
    var fx: Fixture = .{};
    const own = try startWithScratchWindow(&fx);
    defer fx.deinit();
    try plugin.action_api.ensureTables(try fx.mem.tableScratchAllocator(), &fx.atoms, &fx.tables);
    var published: panels_mod.FocusTarget = .{};
    // vcs-git has the focus, a repository's status read with a file staged.
    state.setViewFocus(&fx.tables, &fx.atoms, git_status.panel);
    const panel_state = fx.tables.findByName(Atom.from(git_status.state_table_name)).?;
    const panel_row: Table.RowHandle = .{ .row = 0, .generation = panel_state.rowGeneration(0) };
    try panel_state.setString(panel_row, "root", "/work/repo");
    var counts = panel_state.query(struct { staged_count: *u32 });
    counts.next().?.view.staged_count.* = 1;

    // `c c`: the commit menu's answer, as the menu gives it.
    const chosen: transient.Chosen = .{ .id = @intFromEnum(git_commit.MenuItem.commit), .cancelled = 0, .state = .{} };
    try systemMessage(&fx, git_status.system(), .{ .tag = Atom.from(git_commit.Msg.vcs_git_commit_chosen), .payload = std.mem.asBytes(&chosen) });
    mesha_runtime.text_editor.applyCommands(&fx.mem, &fx.atoms, &fx.tables, &fx.text_editors);
    try runSystem(&fx, text_panel.system());
    // The text window beside vcs-git shows it, never vcs-git, and takes the focus.
    try std.testing.expectEqual(git_commit.message_buffer, textWindow(&fx, own).?.buffer.*);
    applyPanelRequests(&fx);
    try std.testing.expect(panels_mod.hasFocus(&fx.tables, &fx.atoms, own));
    panels_mod.dispatchFocusChanges(&fx.tables, &fx.atoms, &published);
    try runSystem(&fx, text_panel.modesSystem());
    try std.testing.expectEqual(modes.vcs_message, try routedMajor(&fx));

    // `C-c C-k` closes the buffer, and the window shows `*scratch*`, what it showed, again.
    try runSystem(&fx, git_status.system());
    try systemAction(&fx, git_status.system(), Atom.from(git_commit.Msg.vcs_message_cancel));
    mesha_runtime.text_editor.applyCommands(&fx.mem, &fx.atoms, &fx.tables, &fx.text_editors);
    try runSystem(&fx, text_panel.system());
    try std.testing.expectEqual(plugin.text_editor_api.scratch_buffer, textWindow(&fx, own).?.buffer.*);
}

/// The actions system's major mode once it applied the requests waiting for it, as after a
/// dispatch.
fn routedMajor(fx: *Fixture) !Atom {
    try mesha_runtime.actions.route(&fx.mem, &fx.atoms, &fx.tables);
    const modes_table = fx.tables.findByName(Atom.from(plugin.action_api.modes_table)).?;
    const handle: Table.RowHandle = .{ .row = 0, .generation = modes_table.rowGeneration(0) };
    const view = modes_table.getRow(handle, plugin.action_api.ModesView).?;
    return view.major.*;
}

test "a panel's owner asks for its modes as it takes the focus, and the palette for its prompt's until it closes" {
    var fx: Fixture = .{};
    _ = try startWithScratchWindow(&fx);
    defer fx.deinit();
    try plugin.action_api.ensureTables(try fx.mem.tableScratchAllocator(), &fx.atoms, &fx.tables);
    // What the host publishes each frame of the focus's moves.
    var published: panels_mod.FocusTarget = .{};

    // The window on `*scratch*` has the focus.
    panels_mod.dispatchFocusChanges(&fx.tables, &fx.atoms, &published);
    try runSystem(&fx, text_panel.modesSystem());
    try std.testing.expectEqual(modes.buffer, try routedMajor(&fx));

    // The figure stage takes it.
    fixed_panels.layOutNow(&fx.tables, &fx.atoms, .figure_stage);
    panels_mod.applyCmd(&fx.tables, &fx.atoms, .{ .focus = .{ .id = Atom.from(figure_workspace.canvas_id) } });
    panels_mod.dispatchFocusChanges(&fx.tables, &fx.atoms, &published);
    try runSystem(&fx, figure_workspace.system());
    try std.testing.expectEqual(modes.figure, try routedMajor(&fx));

    // The palette opens over it, then closes with nothing picked.
    try toggleActionPalette(&fx);
    try std.testing.expect(action_palette.requestOpen(&fx.tables, &fx.atoms));
    try std.testing.expectEqual(modes.prompt, try routedMajor(&fx));
    action_palette.request(&fx.mem, &fx.tables, .{ .dismiss = .{} });
    try runPalette(&fx);
    try std.testing.expect(!action_palette.requestOpen(&fx.tables, &fx.atoms));
    try std.testing.expectEqual(modes.figure, try routedMajor(&fx));
}

/// What holds the keyboard over a focused table window for a while, in `tableModesAfterHold`.
const KeyboardHold = enum { form_field, dirty_close };

/// Focuses a table window, lets `hold` take the keyboard and give it back, frame by frame as the
/// editor runs (the focus clicks follow after the windows' run, as `syncFocusClicks` does at the
/// next frame's start), and returns the major mode the actions system is left with.
fn tableModesAfterHold(hold: KeyboardHold) !Atom {
    var fx: Fixture = .{};
    _ = try startWithScratchWindow(&fx);
    defer fx.deinit();
    try plugin.action_api.ensureTables(try fx.mem.tableScratchAllocator(), &fx.atoms, &fx.tables);
    var published: panels_mod.FocusTarget = .{};
    const target = try targetTable(std.testing.allocator, &fx.atoms, &fx.tables);
    const name = fx.tables.get(target).?.name;
    try std.testing.expect(windows.open(&fx.tables, &fx.atoms, target));
    // Its system declares its panel, which the panels system opens.
    try runSystem(&fx, windows.system());
    applyPanelRequests(&fx);
    panels_mod.applyCmd(&fx.tables, &fx.atoms, .{ .focus = .{ .id = name } });
    state.setViewFocus(&fx.tables, &fx.atoms, name);
    const frame = struct {
        fn run(f: *Fixture, focus: *panels_mod.FocusTarget) !void {
            panels_mod.dispatchFocusChanges(&f.tables, &f.atoms, focus);
            try runSystem(f, windows.system());
            lib.syncFocusClicks(&f.tables, &f.atoms);
            applyPanelRequests(f);
        }
    }.run;
    try frame(&fx, &published);
    try std.testing.expectEqual(modes.table, try routedMajor(&fx));

    const authoring_ui = state.authoringUi(&fx.tables, &fx.atoms);
    switch (hold) {
        .form_field => authoring_ui.form_focus.* = @intFromEnum(state.FormFocus.meta_key),
        .dirty_close => authoring_ui.modal.* = @intFromEnum(state.Modal.dirty_close),
    }
    for (0..3) |_| {
        try frame(&fx, &published);
        _ = try routedMajor(&fx);
    }
    switch (hold) {
        .form_field => authoring_ui.form_focus.* = @intFromEnum(state.FormFocus.none),
        // Cancel: the window stays open.
        .dirty_close => authoring_ui.modal.* = @intFromEnum(state.Modal.none),
    }
    for (0..3) |_| {
        try frame(&fx, &published);
        _ = try routedMajor(&fx);
    }
    return routedMajor(&fx);
}

test "a table window has table's keys again once a form field it opened stops editing" {
    try std.testing.expectEqual(modes.table, try tableModesAfterHold(.form_field));
}

test "a table window has table's keys again once its dirty-close question is cancelled" {
    try std.testing.expectEqual(modes.table, try tableModesAfterHold(.dirty_close));
}

test "the figure stage takes a focused table window's place, and the window's row goes" {
    var fx: Fixture = .{};
    _ = try startWithScratchWindow(&fx);
    defer fx.deinit();
    const target = try targetTable(std.testing.allocator, &fx.atoms, &fx.tables);
    const name = fx.tables.get(target).?.name;
    try std.testing.expect(windows.open(&fx.tables, &fx.atoms, target));
    try runSystem(&fx, windows.system());
    applyPanelRequests(&fx);
    panels_mod.applyCmd(&fx.tables, &fx.atoms, .{ .focus = .{ .id = name } });
    state.setViewFocus(&fx.tables, &fx.atoms, name);
    const window_frame = panels_mod.panelFor(&fx.tables, &fx.atoms, name).?.frame;

    const figure_stage = Atom.from(fixed_panels.figure_stage);
    fixed_panels.showInPlace(&fx.tables, &fx.atoms, figure_stage);
    try runSystem(&fx, fixed_panels.shownPanelsSystem());
    applyPanelRequests(&fx);
    try std.testing.expect(!panels_mod.isOpen(&fx.tables, &fx.atoms, name));
    try std.testing.expectEqual(window_frame, panels_mod.panelFor(&fx.tables, &fx.atoms, figure_stage).?.frame);
    // The windows run again: the replaced window's row goes, so it opens no more.
    for (0..3) |_| {
        try runSystem(&fx, windows.system());
        try runSystem(&fx, fixed_panels.shownPanelsSystem());
        applyPanelRequests(&fx);
    }
    try std.testing.expect(!panels_mod.isOpen(&fx.tables, &fx.atoms, name));
    try std.testing.expectEqual(@as(u32, 0), fx.tables.findByName(Atom.from(state.windows_name)).?.count());
}

test "closing the figure stage, the last panel, leaves the window empty" {
    var fx: Fixture = .{};
    const own = try startWithScratchWindow(&fx);
    defer fx.deinit();
    const figure_stage = Atom.from(fixed_panels.figure_stage);
    fixed_panels.showInPlace(&fx.tables, &fx.atoms, figure_stage);
    try runSystem(&fx, text_panel.system());
    try runSystem(&fx, fixed_panels.shownPanelsSystem());
    applyPanelRequests(&fx);
    try settleTextPanels(&fx);
    try std.testing.expect(textWindow(&fx, own) == null);
    try std.testing.expectEqual(@as(usize, 0), textPanelsOpened(&fx).count);

    fixed_panels.hidePanel(&fx.tables, figure_stage);
    try runSystem(&fx, fixed_panels.shownPanelsSystem());
    applyPanelRequests(&fx);
    try std.testing.expect(!panels_mod.isOpen(&fx.tables, &fx.atoms, figure_stage));
    try settleTextPanels(&fx);
    try std.testing.expectEqual(@as(usize, 0), textPanelsOpened(&fx).count);
}

test "tracker editor create prompt lifecycle and duplicate recovery" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    fx.resetCommands();
    try trackerAction(&fx, .from(windows.Msg.create_tracker));
    try dispatchEditorCommands(&fx);
    try std.testing.expect(action_palette.requestOpen(&fx.tables, &fx.atoms));
    try submitPromptText(&fx, "bad name");
    try std.testing.expect(action_palette.requestOpen(&fx.tables, &fx.atoms));
    try std.testing.expect(fx.tables.findHandleByName(fx.atoms.intern("tracker_bad name")) == null);
    try dispatchEditorCommands(&fx);
    try submitPromptText(&fx, "tracker_speed");
    try applyAuthoring(&fx);
    const name = fx.atoms.intern("tracker_speed");
    const handle = fx.tables.findHandleByName(name).?;
    try std.testing.expect(mesha.tracker.isDefinition(&fx.atoms, fx.tables.get(handle).?));
    try std.testing.expectEqual(@as(u32, 1), windows.windows(&fx.tables, &fx.atoms).count());
    // Its window is shown, declared by the windows' system, and asked to take the focus.
    try std.testing.expectEqual(@as(usize, 1), panelRequestCount(&fx.tables));
    try std.testing.expectEqual(name, panelRequestAt(&fx.tables, 0).?.focus.id);
    fx.resetCommands();
    try trackerAction(&fx, .from(windows.Msg.create_tracker));
    try dispatchEditorCommands(&fx);
    try submitPromptText(&fx, "speed");
    // The duplicate is refused as the tracker is made, which asks again.
    try applyAuthoring(&fx);
    try runPalette(&fx);
    try std.testing.expect(action_palette.requestOpen(&fx.tables, &fx.atoms));
    try std.testing.expectEqualStrings("speed", promptText(&fx));
    try dispatchEditorCommands(&fx);
    try paletteKey(&fx, action_palette.Msg.cancel);
    try dispatchEditorCommands(&fx);
    const reply = popEditorMessage(&fx);
    try editorMessage(&fx, reply);
    try std.testing.expect(!action_palette.requestOpen(&fx.tables, &fx.atoms));
    try std.testing.expect(fx.tables.get(handle) != null);
}

test "tracker editor deferred prompt cancellation is acknowledged" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    fx.resetCommands();
    try trackerAction(&fx, .from(windows.Msg.create_tracker));
    try dispatchEditorCommands(&fx);
    action_palette.request(&fx.mem, &fx.tables, .{ .cancel = .{ .owner = windows.kTrackerOwner } });
    try dispatchEditorCommands(&fx);
    try std.testing.expect(!action_palette.requestOpen(&fx.tables, &fx.atoms));
    try std.testing.expect(!action_palette.canPresent(&fx.tables, &fx.atoms));
    const reply = popEditorMessage(&fx);
    try editorMessage(&fx, reply);
    try runPalette(&fx);
    try std.testing.expect(action_palette.canPresent(&fx.tables, &fx.atoms));
    try trackerAction(&fx, .from(windows.Msg.create_tracker));
    try dispatchEditorCommands(&fx);
    try std.testing.expect(action_palette.requestOpen(&fx.tables, &fx.atoms));
}

test "tracker editor action availability follows focused definition" {
    const allocator = std.testing.allocator;
    var fx: Fixture = .{};
    try fx.init(allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    var rows = try actionRows(&fx);
    const action_subs = rows.actions;
    state.setViewFocus(&fx.tables, &fx.atoms, fx.atoms.intern("stage"));
    lib.pushEditorActions(&fx.tables, &fx.atoms, rows.sink());
    try std.testing.expect(actionByName(action_subs, &fx.atoms, "create_tracker") != null);
    try std.testing.expect(actionByName(action_subs, &fx.atoms, "delete_tracker") == null);
    action_subs.reset();
    const ordinary = try targetTable(allocator, &fx.atoms, &fx.tables);
    try std.testing.expect(windows.open(&fx.tables, &fx.atoms, ordinary));
    state.setViewFocus(&fx.tables, &fx.atoms, fx.tables.get(ordinary).?.name);
    lib.pushEditorActions(&fx.tables, &fx.atoms, rows.sink());
    try std.testing.expect(actionByName(action_subs, &fx.atoms, "delete_tracker") == null);
    const metadata_toggle = actionByName(action_subs, &fx.atoms, "metadata_toggle").?;
    // A table window's action names the table windows' inbox, so it draws only the inspector's
    // panels, and reaches it under its tag.
    try std.testing.expectEqual(sequencer_mod.inboxOf(windows.system()), metadata_toggle.inbox);
    try std.testing.expectEqual(Atom.from(windows.Msg.metadata_toggle), metadata_toggle.tag);
    try std.testing.expectEqual(@as(usize, 0), metadata_toggle.user_data.bytes.len);
    try editorAction(&fx, .{ .tag = metadata_toggle.tag, .user_data = metadata_toggle.user_data.bytes });
    const authoring_ui = state.authoringUi(&fx.tables, &fx.atoms);
    try std.testing.expectEqual(@intFromEnum(state.DrawerMode.metadata), authoring_ui.drawer_mode.*);
    action_subs.reset();
    const definition = try mesha.tracker.create(allocator, &fx.atoms, &fx.tables, "actions");
    try std.testing.expect(windows.open(&fx.tables, &fx.atoms, definition));
    state.setViewFocus(&fx.tables, &fx.atoms, fx.tables.get(definition).?.name);
    lib.pushEditorActions(&fx.tables, &fx.atoms, rows.sink());
    try std.testing.expect(actionByName(action_subs, &fx.atoms, "delete_tracker") != null);
}

test "tracker editor focused delete and series defaults limit" {
    const tracker = mesha.tracker;
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    fx.resetCommands();
    const ordinary = try targetTable(std.testing.allocator, &fx.atoms, &fx.tables);
    try std.testing.expect(windows.open(&fx.tables, &fx.atoms, ordinary));
    state.setViewFocus(&fx.tables, &fx.atoms, fx.tables.get(ordinary).?.name);
    try std.testing.expect(!windows.focusedTracker(&fx.tables, &fx.atoms));
    try trackerAction(&fx, .from(windows.Msg.delete_tracker));
    try std.testing.expect(fx.tables.get(ordinary) != null);
    try trackerAction(&fx, .from(windows.Msg.row_add));
    try std.testing.expectEqual(@as(u32, 1), fx.tables.get(ordinary).?.count());
    const handle = try tracker.create(std.testing.allocator, &fx.atoms, &fx.tables, "test");
    const name = fx.tables.get(handle).?.name;
    try std.testing.expect(windows.open(&fx.tables, &fx.atoms, handle));
    state.setViewFocus(&fx.tables, &fx.atoms, name);
    try std.testing.expect(windows.focusedTracker(&fx.tables, &fx.atoms));
    for (0..tracker.max_series + 1) |_| try trackerAction(&fx, .from(windows.Msg.row_add));
    const definition = fx.tables.get(handle).?;
    try std.testing.expectEqual(@as(u32, tracker.max_series), definition.count());
    const series = tracker.seriesAt(definition, 0).?;
    try std.testing.expectEqual(@as(u32, 0), series.row);
    try std.testing.expectEqual(@as(Atom, @enumFromInt(0)), series.table_name);
    try std.testing.expectEqual(@as(Atom, @enumFromInt(0)), series.field_name);
    try std.testing.expectEqual(@as(f32, 1), series.color.w);
    fx.resetCommands();
    try trackerAction(&fx, .from(windows.Msg.delete_tracker));
    try applyAuthoring(&fx);
    try std.testing.expect(fx.tables.get(handle) == null);
    try std.testing.expect(fx.tables.get(ordinary) != null);
    // Its window went with it, and is declared no longer, which closes its panel.
    try std.testing.expectEqual(@as(u32, 1), windows.windows(&fx.tables, &fx.atoms).count());
    var declared = plugin.panels.Declared.of(&fx.mem, &fx.tables, plugin.panels.declared_table_name).iterate();
    while (declared.next()) |panel| try std.testing.expect(panel.id != name);
}

test "tracker editor chart toggle gates table edits and preserves metadata" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    const ordinary = try targetTable(std.testing.allocator, &fx.atoms, &fx.tables);
    try std.testing.expect(windows.open(&fx.tables, &fx.atoms, ordinary));
    const definition = try mesha.tracker.create(std.testing.allocator, &fx.atoms, &fx.tables, "chart_test");
    try std.testing.expect(windows.open(&fx.tables, &fx.atoms, definition));
    const list = windows.windows(&fx.tables, &fx.atoms);
    const ordinary_handle = Table.RowHandle{ .row = 0, .generation = list.rowGeneration(0) };
    const handle = Table.RowHandle{ .row = 1, .generation = list.rowGeneration(1) };
    const s = list.getRow(handle, windows.WindowState).?;
    try std.testing.expectEqual(@as(u8, 0), s.tracker_chart.*);
    try trackerChartToggle(&fx, ordinary_handle);
    try std.testing.expectEqual(@as(u8, 0), list.getRow(ordinary_handle, windows.WindowState).?.tracker_chart.*);
    state.setViewFocus(&fx.tables, &fx.atoms, fx.tables.get(definition).?.name);
    s.edit_present.* = 1;
    s.inspector_row_present.* = 1;
    try trackerChartToggle(&fx, Table.RowHandle{ .row = handle.row, .generation = handle.generation + 1 });
    try std.testing.expectEqual(@as(u8, 0), s.tracker_chart.*);
    try trackerChartToggle(&fx, handle);
    try std.testing.expectEqual(@as(u8, 1), s.tracker_chart.*);
    try std.testing.expectEqual(@as(u8, 0), s.edit_present.*);
    try std.testing.expectEqual(@as(u8, 0), s.inspector_row_present.*);
    try trackerAction(&fx, .from(windows.Msg.row_add));
    try std.testing.expectEqual(@as(u32, 0), fx.tables.get(definition).?.count());
    try trackerAction(&fx, .from(windows.Msg.metadata_toggle));
    try trackerAction(&fx, .from(windows.Msg.ctx_add));
    try std.testing.expect(state.authoringUi(&fx.tables, &fx.atoms).form_focus.* != 0);
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    try std.testing.expectEqual(@as(u8, 1), list.getRow(handle, windows.WindowState).?.tracker_chart.*);
    try trackerChartToggle(&fx, handle);
    try std.testing.expectEqual(@as(u8, 0), s.tracker_chart.*);
}

test "transient tables cannot be opened in the inspector" {
    const allocator = std.testing.allocator;
    var fx: Fixture = .{};
    try fx.init(allocator);
    defer fx.deinit();

    var schema: Table.Schema = undefined;
    try schema.init(allocator, &fx.atoms, 1);
    defer schema.deinit();
    schema.addField("value", i32, .int);
    const handle = try fx.tables.create(&schema, 1, fx.atoms.intern("transient.table"), .transient);

    try std.testing.expect(!windows.open(&fx.tables, &fx.atoms, handle));
}

test "inspector init is idempotent and window state survives rebind" {
    const allocator = std.testing.allocator;
    var fx: Fixture = .{};
    try fx.init(allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);

    const target = try targetTable(allocator, &fx.atoms, &fx.tables);
    try std.testing.expect(windows.open(&fx.tables, &fx.atoms, target));
    const list = windows.windows(&fx.tables, &fx.atoms);
    const handle = Table.RowHandle{ .row = 0, .generation = list.rowGeneration(0) };
    const edit = list.getRow(handle, windows.WindowState).?;
    edit.inspector_row_present.* = 1;
    edit.inspector_row.* = 0;
    edit.inspector_row_generation.* = fx.tables.get(target).?.rowGeneration(0);
    edit.inspector_target_epoch.* = 17;
    edit.inspector_scroll.* = 3;
    edit.inspector_horizontal_scroll.* = 2;
    edit.edit_present.* = 1;
    edit.edit_row.* = 0;
    edit.edit_field.* = 0;
    edit.edit_invalid.* = 1;
    try windows.windows(&fx.tables, &fx.atoms).assignString(edit.edit_text, "42");
    edit.edit_serial.* = 7;

    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    const rebound = windows.windows(&fx.tables, &fx.atoms).getRow(handle, windows.WindowState).?;
    try std.testing.expectEqual(@as(u8, 1), rebound.edit_present.*);
    try std.testing.expectEqual(@as(u32, 2), rebound.inspector_horizontal_scroll.*);
    try std.testing.expectEqual(@as(u32, fx.tables.get(target).?.rowGeneration(0)), rebound.inspector_row_generation.*);
    try std.testing.expectEqual(@as(u32, 17), rebound.inspector_target_epoch.*);
    try std.testing.expectEqual(@as(u8, 1), rebound.edit_invalid.*);
    try std.testing.expectEqualStrings("42", windows.windows(&fx.tables, &fx.atoms).textOf(rebound.edit_text.*));
    try std.testing.expectEqual(@as(u32, 7), rebound.edit_serial.*);
    try std.testing.expect(lib.isVisible(&fx.tables, &fx.atoms));
}

/// A table of `count` rows of one number, and a window on it laid out `height` pixels tall:
/// returns the table and the window's row.
fn scrolledWindow(fx: *Fixture, count: u32, height: f32) !struct { table: *Table, window: windows.WindowState } {
    var schema: Table.Schema = undefined;
    try schema.init(std.testing.allocator, &fx.atoms, 1);
    defer schema.deinit();
    schema.addField("value", i32, .int);
    const ensured = try fx.tables.ensure(&schema, 64, fx.atoms.intern("test.scrolled"), .durable);
    const table = ensured.table;
    for (0..count) |index| _ = try table.tryInsert(.{ .value = @as(i32, @intCast(index)) });
    try std.testing.expect(windows.open(&fx.tables, &fx.atoms, ensured.handle));
    const list = windows.windows(&fx.tables, &fx.atoms);
    const window = list.getRow(.{ .row = 0, .generation = list.rowGeneration(0) }, windows.WindowState).?;
    window.viewport_w.* = 800;
    window.viewport_h.* = height;
    return .{ .table = table, .window = window };
}

/// Frees the rows `first` to `last` of `table`.
fn freeRows(table: *Table, first: u32, last: u32) void {
    for (first..last + 1) |row| table.free(.{ .row = @intCast(row), .generation = table.rowGeneration(@intCast(row)) });
}

test "a table window's stored scroll is kept in the rows there are once its table shrinks" {
    const allocator = std.testing.allocator;
    var fx: Fixture = .{};
    try fx.init(allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    // Forty rows, eight shown, scrolled to the thirtieth; then thirty of them go.
    const opened = try scrolledWindow(&fx, 40, 300);
    try runSystem(&fx, windows.system());
    opened.window.inspector_scroll.* = 30;
    freeRows(opened.table, 10, 39);
    try runSystem(&fx, windows.system());
    // Ten rows, eight shown: the stored scroll, not only the drawn one, is at most two.
    try std.testing.expectEqual(@as(u32, 2), opened.window.inspector_scroll.*);
}

test "a table window's stored scroll shows the selection the next run after its row goes" {
    const allocator = std.testing.allocator;
    var fx: Fixture = .{};
    try fx.init(allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    const opened = try scrolledWindow(&fx, 40, 300);
    try runSystem(&fx, windows.system());
    // The twenty-sixth row selected and in view, scrolled to the twentieth; then the first
    // twenty-six rows go, the selected one with them.
    const window = opened.window;
    window.inspector_row_present.* = 1;
    window.inspector_row.* = 25;
    window.inspector_row_generation.* = opened.table.rowGeneration(25);
    window.inspector_scroll.* = 20;
    try runSystem(&fx, windows.system());
    try std.testing.expectEqual(@as(u32, 20), window.inspector_scroll.*);
    freeRows(opened.table, 0, 25);
    try runSystem(&fx, windows.system());
    // The nearest row left, the first shown now, is selected and scrolled to.
    try std.testing.expectEqual(@as(u32, 26), window.inspector_row.*);
    try std.testing.expectEqual(@as(u32, 0), window.inspector_scroll.*);
}

test "a table window whose panel is resized settles its stored scroll on the resized event's run" {
    const allocator = std.testing.allocator;
    var fx: Fixture = .{};
    try fx.init(allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    // Forty rows, eight shown, scrolled to the thirtieth.
    const opened = try scrolledWindow(&fx, 40, 300);
    try runSystem(&fx, windows.system());
    opened.window.inspector_scroll.* = 30;
    try runSystem(&fx, windows.system());
    try std.testing.expectEqual(@as(u32, 30), opened.window.inspector_scroll.*);
    // The panels tell the window's panel it is taller: its content is laid out at the new size
    // and the scroll is kept in the rows that now fit, in that run.
    const scratch = try fx.mem.tableScratchAllocator();
    try plugin.panels.Events.ensure(scratch, &fx.atoms, &fx.tables, plugin.panels.events_table_name);
    const resized: plugin.panels.Resized = .{ .panel = opened.window.id.*, .frame_width = 800, .frame_height = 900 };
    plugin.panels.Events.of(&fx.tables, plugin.panels.events_table_name).publish(.{ .resized = resized });
    try runSystem(&fx, windows.system());
    const content = panel_frame.contentSize(&fx.tables, &fx.atoms, resized);
    try std.testing.expectEqual(content.height, opened.window.viewport_h.*);
    const shown = ui.grid.visibleRows(content.height, .grid, .{});
    try std.testing.expectEqual(40 - shown, opened.window.inspector_scroll.*);
}

test "a table window whose resized was never read takes its panel's size on its first run, and only then" {
    const allocator = std.testing.allocator;
    var fx: Fixture = .{};
    try fx.init(allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    const scratch = try fx.mem.tableScratchAllocator();
    try plugin.panels.Events.ensure(scratch, &fx.atoms, &fx.tables, plugin.panels.events_table_name);
    // Its panel laid out before the windows' reader ever read: the size it was told is gone.
    const opened = try scrolledWindow(&fx, 40, 3000);
    const panel = opened.window.id.*;
    panels_mod.openNow(&fx.tables, &fx.atoms, .{ .id = panel, .root = panel });
    panels_mod.relayout(&fx.tables, &fx.atoms, .{ .w = 1000, .h = 700 });
    const events = plugin.panels.Events.of(&fx.tables, plugin.panels.events_table_name);
    events.publish(.{ .focused = panel });
    try runSystem(&fx, windows.system());
    const pane = panel_frame.contentRect(&fx.tables, &fx.atoms, panel).?;
    try std.testing.expectEqual(pane.h, opened.window.viewport_h.*);
    try std.testing.expectEqual(pane.w, opened.window.viewport_w.*);
    // Once it has read, a size comes only from what the panels tell.
    panels_mod.relayout(&fx.tables, &fx.atoms, .{ .w = 1000, .h = 400 });
    try runSystem(&fx, windows.system());
    try std.testing.expectEqual(pane.h, opened.window.viewport_h.*);
}

test "active inspector publishes focused cell identity and clears without a selected row" {
    const allocator = std.testing.allocator;
    var fx: Fixture = .{};
    try fx.init(allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);

    const active_table = fx.tables.findByName(fx.atoms.intern(state.active_inspector_name)).?;
    try std.testing.expectEqual(@as(u32, 1), active_table.count());
    const fields = active_table.getSchema().fields;
    try std.testing.expectEqual(@as(usize, 5), fields.len);
    for ([_][]const u8{ "focused", "table_name", "row", "generation", "field_name" }, fields) |name, field| {
        try std.testing.expectEqualStrings(name, field.name);
    }
    try std.testing.expectEqual(@as(u8, 0), state.activeInspector(&fx.tables, &fx.atoms).focused.*);

    const target_handle = try targetTable(allocator, &fx.atoms, &fx.tables);
    const target = fx.tables.get(target_handle).?;
    const selected = target.insert(.{ .value = @as(i32, 42) });
    try std.testing.expect(windows.open(&fx.tables, &fx.atoms, target_handle));
    state.setViewFocus(&fx.tables, &fx.atoms, target.name);
    try runSystem(&fx, windows.system());

    const active = state.activeInspector(&fx.tables, &fx.atoms);
    try std.testing.expectEqual(@as(u8, 1), active.focused.*);
    try std.testing.expectEqual(target.name, active.table_name.*);
    try std.testing.expectEqual(selected.row, active.row.*);
    try std.testing.expectEqual(selected.generation, active.generation.*);
    try std.testing.expectEqual(fx.atoms.intern("value"), active.field_name.*);

    state.setViewFocus(&fx.tables, &fx.atoms, fx.atoms.intern("stage"));
    try runSystem(&fx, windows.system());
    try std.testing.expectEqual(@as(u8, 0), active.focused.*);
    try std.testing.expectEqual(@as(Atom, @enumFromInt(0)), active.table_name.*);
    try std.testing.expectEqual(@as(u32, 0), active.row.*);
    try std.testing.expectEqual(@as(u32, 0), active.generation.*);
    try std.testing.expectEqual(@as(Atom, @enumFromInt(0)), active.field_name.*);

    target.free(selected);
    state.setViewFocus(&fx.tables, &fx.atoms, target.name);
    try runSystem(&fx, windows.system());
    try std.testing.expectEqual(@as(u8, 0), active.focused.*);
}

test "picker toggle opens and closes through the completion request API" {
    const allocator = std.testing.allocator;
    var fx: Fixture = .{};
    try fx.init(allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    try initModes(&fx);
    fx.resetCommands();

    try editorAction(&fx, .{ .tag = .from(windows.Msg.picker_toggle) });
    try dispatchEditorCommands(&fx);
    try std.testing.expect(windows.pickerOpen(&fx.tables, &fx.atoms));

    try editorAction(&fx, .{ .tag = .from(windows.Msg.picker_toggle) });
    try dispatchEditorCommands(&fx);
    const event_message = popEditorMessage(&fx);
    try editorMessage(&fx, event_message);
    try std.testing.expect(!windows.pickerOpen(&fx.tables, &fx.atoms));
}

test "figure_open action dispatch opens the find-file prompt" {
    const allocator = std.testing.allocator;
    var fx: Fixture = .{};
    try fx.init(allocator);
    defer fx.deinit();
    // Production owns figure initialization; this isolated editor fixture must supply it.
    const figure = mesha.figure;
    const context = figure.Context{ .memory = &fx.mem, .tables = &fx.tables, .atoms = &fx.atoms };
    try figure_runtime.init(context);
    defer figure_runtime.deinit(context) catch unreachable;
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    try mesha.panels.ensure(try fx.mem.tableScratchAllocator(), &fx.atoms, &fx.tables);
    try transport_fixture.synchronize(&fx.mem, &fx.atoms, &fx.tables);
    const scratch = try fx.mem.tableScratchAllocator();
    try sequencer_mod.ensureInboxes(scratch, &fx.atoms, &fx.tables, &.{ .name = "open_test", .steps = &.{.{ .system = open.system() }} });
    fx.resetCommands();
    const stage_before = fixed_panels.panelShown(&fx.tables, Atom.from(fixed_panels.figure_stage));

    try editorAction(&fx, .{ .tag = Atom.from("figure_open") });
    const reply = try findFileListingAsked(&fx, "");
    try deliverListing(&fx, sequencer_mod.inboxOf(open.system()), reply.tag, reply.user_data.bytes, .listed, "/home/someone/art", &.{});
    try runSystem(&fx, open.system());
    try dispatchEditorCommands(&fx);
    try std.testing.expect(action_palette.requestOpen(&fx.tables, &fx.atoms));
    const completions = action_palette.currentCompletions(&fx.tables, &fx.atoms).?;
    try std.testing.expectEqual(open.find_file_owner, completions.owner);
    try std.testing.expectEqualStrings("/home/someone/art/", completions.initial_query);
    // The stage shows only once a figure or a sketch is chosen.
    try std.testing.expectEqual(stage_before, fixed_panels.panelShown(&fx.tables, Atom.from(fixed_panels.figure_stage)));
}

test "figure_open opens find-file on the directory of the figure shown" {
    const allocator = std.testing.allocator;
    var fx: Fixture = .{};
    try fx.init(allocator);
    defer fx.deinit();
    const figure = mesha.figure;
    const context = figure.Context{ .memory = &fx.mem, .tables = &fx.tables, .atoms = &fx.atoms };
    try figure_runtime.init(context);
    defer figure_runtime.deinit(context) catch unreachable;
    try initFigureOpening(&fx);
    const blue = fx.atoms.intern("blue");
    const scope = mesha.resources.applicationScope(fx.tables.memory);
    try figure_runtime.domain.library.create(&fx.tables, &fx.atoms, .{ .scope = scope, .doc = blue, .path = "/home/someone/art/blue.mshf" });
    session.get(&fx.tables).doc.* = blue;
    figure_workspace.showStage(&fx.tables, &fx.atoms);
    try transport_fixture.synchronize(&fx.mem, &fx.atoms, &fx.tables);
    fx.resetCommands();

    try editorAction(&fx, .{ .tag = Atom.from("figure_open") });
    _ = try findFileListingAsked(&fx, "/home/someone/art");
}

/// With a window on `*scratch*`, its buffer holding the file at `path`
/// (none when empty) and the window the focused view, asks for find-file as `C-x C-f` does:
/// the open system's one request, a listing, must name `directory`.
fn findFileFromBuffer(path: []const u8, directory: []const u8) !void {
    var fx: Fixture = .{};
    const panel = try startWithScratchWindow(&fx);
    defer fx.deinit();
    const buffers = fx.tables.findByName(Atom.from(plugin.text_editor_api.buffers_table_name)).?;
    var rows = buffers.query(struct { buffer: *Atom, path: *Table.String });
    while (rows.next()) |row| {
        if (row.view.buffer.* != plugin.text_editor_api.scratch_buffer) continue;
        try buffers.assignString(row.view.path, path);
    }
    state.setViewFocus(&fx.tables, &fx.atoms, panel);
    fx.resetCommands();
    plugin.text_editor_api.Requests.of(&fx.mem, &fx.tables, plugin.text_editor_api.commands_table_name).reset();

    try systemAction(&fx, open.system(), Atom.from("text_find_file"));
    _ = try findFileListingAsked(&fx, directory);
}

test "find-file opens on the directory of the focused buffer's file" {
    try findFileFromBuffer("/home/someone/game/src/main.zig", "/home/someone/game/src");
}

test "find-file opens on the working directory when the buffer has no file" {
    try findFileFromBuffer("", "");
}

/// The one request the find-file prompt sent the text editor, a listing of `directory`, taken
/// from its rows: where its answer goes.
fn findFileListingAsked(fx: *Fixture, directory: []const u8) !sequencer_mod.ReplyTo {
    const text_editor_api = plugin.text_editor_api;
    const text_requests = text_editor_api.Requests.of(&fx.mem, &fx.tables, text_editor_api.commands_table_name);
    var sent: [2]text_editor_api.CmdPayload = undefined;
    const listings = text_requests.peek(&sent);
    try std.testing.expectEqual(@as(usize, 1), listings.len);
    try std.testing.expectEqualStrings(directory, listings[0].list_directory.path);
    const reply = listings[0].list_directory.reply;
    text_requests.reset();
    return reply;
}

test "action palette: init enables focus clicks; prompt sources are mutually exclusive" {
    const allocator = std.testing.allocator;
    var fx: Fixture = .{};
    try fx.init(allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    try initModes(&fx);

    try std.testing.expectEqual(@as(usize, 1), panelRequestCount(&fx.tables));
    try std.testing.expect(panelRequestAt(&fx.tables, 0).? == .enable_focus_clicks);
    fx.resetCommands();

    try toggleActionPalette(&fx);
    try std.testing.expect(lib.actionListOpen(&fx.tables, &fx.atoms));
    try std.testing.expect(!windows.pickerOpen(&fx.tables, &fx.atoms));
    try std.testing.expect(action_palette.requestOpen(&fx.tables, &fx.atoms));

    try editorAction(&fx, .{ .tag = .from(windows.Msg.picker_toggle) });
    try dispatchEditorCommands(&fx);
    try std.testing.expect(!lib.actionListOpen(&fx.tables, &fx.atoms));
    try std.testing.expect(windows.pickerOpen(&fx.tables, &fx.atoms));

    try std.testing.expectEqual(@as(usize, 0), promptText(&fx).len);

    windows.dismissPicker(&fx.tables, &fx.atoms);
    try runPalette(&fx);
    try std.testing.expect(!action_palette.requestOpen(&fx.tables, &fx.atoms));
}

test "editor keeps view focus locally while action palette context remains editor-owned" {
    const allocator = std.testing.allocator;
    var fx: Fixture = .{};
    try fx.init(allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    try initModes(&fx);

    try std.testing.expectEqual(@as(Atom, @enumFromInt(0)), state.viewFocus(&fx.tables, &fx.atoms).id.*);
    const focused_id = fx.atoms.intern("editor.widget");
    try focusMove(&fx, .{ .focused = focused_id });
    try std.testing.expectEqual(focused_id, state.viewFocus(&fx.tables, &fx.atoms).id.*);

    try toggleActionPalette(&fx);
    try std.testing.expect(action_palette.requestOpen(&fx.tables, &fx.atoms));
    try std.testing.expectEqual(focused_id, state.viewFocus(&fx.tables, &fx.atoms).id.*);

    try focusMove(&fx, .{ .unfocused = focused_id });
    try std.testing.expectEqual(focused_id, state.viewFocus(&fx.tables, &fx.atoms).id.*);
}

test "inspector hover converges on the shared app_state.hovered_id" {
    const allocator = std.testing.allocator;
    var fx: Fixture = .{};
    try fx.init(allocator);
    defer fx.deinit();

    const id = ui.ElementId{ .atom = fx.atoms.intern("test.element"), .extra = 7 };
    // Without input's table nothing is hovered.
    try std.testing.expect(state.hoveredElementId(&fx.tables) == null);
    try input_mod.writeHover(&fx.tables, &fx.atoms, .{ .element = std.mem.toBytes(id) });
    try std.testing.expectEqual(@intFromEnum(id.atom), @intFromEnum(state.hoveredElementId(&fx.tables).?.atom));
    try std.testing.expectEqual(@as(u64, 7), state.hoveredElementId(&fx.tables).?.extra);
    try input_mod.writeHover(&fx.tables, &fx.atoms, .{});
    try std.testing.expect(state.hoveredElementId(&fx.tables) == null);
}

const keybinds = mesha.keybinds;

/// Chooses `project`, remembered, in the prompt `project_switch` opens: the one request it
/// then sends the OS, which must be to enter `project`, taken from its rows. The text editor's
/// requests are forgotten, so a test sees only those that follow the OS's answer.
fn projectSwitchAsked(fx: *Fixture, project: []const u8) !os_mod.CmdPayload {
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    const projects = fx.tables.findByName(Atom.from(plugin.text_editor_api.projects_table_name)).?;
    _ = try projects.tryInsert(.{ .path = project });
    fx.resetCommands();

    try systemAction(fx, open.system(), Atom.from("project_switch"));
    try dispatchEditorCommands(fx);
    const completions = action_palette.currentCompletions(&fx.tables, &fx.atoms).?;
    // The remembered project, then the entry that reads a directory instead.
    try std.testing.expectEqual(@as(usize, 2), completions.entries.len);
    try std.testing.expectEqualStrings(project, completions.entries[0].key);
    try std.testing.expectEqualStrings("Choose a directory…", completions.entries[1].label);
    try submitPromptText(fx, "");

    var sent: [2]os_mod.CmdPayload = undefined;
    const asked = os_mod.Requests.of(&fx.mem, &fx.tables, os_mod.commands_table_name).peek(&sent);
    try std.testing.expectEqual(@as(usize, 1), asked.len);
    try std.testing.expectEqualStrings(project, asked[0].set_working_directory.path);
    plugin.text_editor_api.Requests.of(&fx.mem, &fx.tables, plugin.text_editor_api.commands_table_name).reset();
    return asked[0];
}

/// The OS's answer to `asked`, a request to enter a directory, as it reaches the open system.
fn answerProjectEntered(fx: *Fixture, asked: os_mod.CmdPayload, result: os_mod.WorkingDirectoryMsg.Result) !void {
    const answer: os_mod.WorkingDirectoryMsg = .{ .result = result };
    const answered = asked.set_working_directory.reply.answered(std.mem.asBytes(&answer));
    try systemMessage(fx, open.system(), answered);
}

test "project_switch sends the chosen directory to the OS and remembers it when it changed" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    const asked = try projectSwitchAsked(&fx, "/home/someone/game");
    try answerProjectEntered(&fx, asked, .changed);

    var sent: [4]plugin.text_editor_api.CmdPayload = undefined;
    const requests = textEditorRequests(&fx, &sent);
    try std.testing.expectEqual(@as(usize, 2), requests.len);
    try std.testing.expectEqualStrings("/home/someone/game", requests[0].remember_project);
    try std.testing.expectEqualStrings("Project: /home/someone/game", requests[1].message);
    // Then what to do in it, as project.el's commands offer.
    var presented: [2]transient.Request = undefined;
    const menus = transient.Requests.of(&fx.mem, &fx.tables, transient.requests_table_name).peek(&presented);
    try std.testing.expectEqual(@as(usize, 1), menus.len);
    try std.testing.expectEqualStrings("Project", menus[0].present.menu.title);
}

test "a project that cannot be entered is told and not remembered" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    const asked = try projectSwitchAsked(&fx, "/home/someone/gone");
    try answerProjectEntered(&fx, asked, .not_found);

    var sent: [4]plugin.text_editor_api.CmdPayload = undefined;
    const requests = textEditorRequests(&fx, &sent);
    try std.testing.expectEqual(@as(usize, 1), requests.len);
    try std.testing.expectEqualStrings("No such directory: /home/someone/gone", requests[0].message);
}

test "project_switch with no project remembered reads a directory from the working directory" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    fx.resetCommands();
    try systemAction(&fx, open.system(), Atom.from("project_switch"));
    // The listing is answered to the project prompt, not to find-file.
    const reply = try findFileListingAsked(&fx, "");
    try std.testing.expectEqual(Atom.from("open_project_listing"), reply.tag);
}

test "the project's keys are bound in global" {
    try expectKeysBound(plugin.action_api.no_mode, &.{
        .{ .chord = "C-x p p", .mode = "global", .name = "project_switch" },
        .{ .chord = "C-x p f", .mode = "global", .name = "find_project_file" },
        .{ .chord = "C-x p g", .mode = "global", .name = "grep" },
        .{ .chord = "C-x p d", .mode = "global", .name = "project_find_directory" },
        .{ .chord = "C-x p b", .mode = "global", .name = "project_switch_buffer" },
        .{ .chord = "C-x p c", .mode = "global", .name = "compile" },
        .{ .chord = "C-x p S-d", .mode = "global", .name = "project_forget" },
    });
}

// ---- transient menus --------------------------------------------------------------------------

/// A menu as a presenter keeps it, a constant: a switch, an option and a command.
const test_transient_menu: ui.transient.Menu = .{
    .title = "Log",
    .groups = &.{
        .{ .title = "Arguments", .items = &.{
            .{ .key = "-a", .label = "All branches", .kind = .toggle, .argument = "--all", .id = 1 },
            .{ .key = "=n", .label = "Limit", .kind = .option, .argument = "--max-count=", .id = 2 },
        } },
        .{ .title = "Log", .items = &.{.{ .key = "l", .label = "Current", .id = 10 }} },
    },
};

/// The tag the tests' presenter hears its answer under.
const transient_reply_tag = Atom.from("test_transient_chosen");

/// The editor initialised, with the input system's and the actions system's tables.
fn prepareTransient(fx: *Fixture) !void {
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    const scratch = try fx.mem.tableScratchAllocator();
    try input_mod.ensureTables(scratch, &fx.atoms, &fx.tables);
    try plugin.action_api.ensureTables(scratch, &fx.atoms, &fx.tables);
    fx.resetCommands();
}

/// `test_transient_menu` presented, and shown by the transient's run.
fn presentTestMenu(fx: *Fixture) !void {
    transient.present(&fx.mem, &fx.tables, .{ .menu = &test_transient_menu, .reply = testReply(transient_reply_tag) });
    try runSystem(fx, transient.system());
}

/// `typed` typed at the transient, as its subscription delivers it.
fn transientChar(fx: *Fixture, typed: u8) !void {
    const message: input_mod.TextInputMsg = .{ .codepoint = typed };
    try systemMessage(fx, transient.system(), .{ .tag = Atom.from("transient_char"), .payload = std.mem.asBytes(&message) });
}

/// `key` pressed at the transient with `modifiers` held, as its subscription delivers it.
fn transientKey(fx: *Fixture, key: input_mod.Key, modifiers: input_mod.ModifierState) !void {
    const message: input_mod.KeyInputMsg = .{ .key = key, .modifiers = modifiers };
    try systemMessage(fx, transient.system(), .{ .tag = Atom.from("transient_key"), .payload = std.mem.asBytes(&message) });
}

/// Whether the transient has every key: it subscribed to them, capturing.
fn transientCaptures(fx: *Fixture) bool {
    const rows = fx.tables.findByName(Atom.from(input_mod.subscriptions_table_name)) orelse return false;
    const inbox = sequencer_mod.inboxOf(transient.system());
    var query = rows.readQuery(struct { subscription: *input_mod.Subscription, inbox: *Atom });
    while (query.next()) |row| {
        if (row.view.inbox.* != inbox) continue;
        const subscription = row.view.subscription.*;
        if (subscription == .key_input and subscription.captures()) return true;
    }
    return false;
}

/// The transient's answer to the tests' presenter, once the hook delivered what waits for it;
/// null when it gave none.
fn transientAnswer(fx: *Fixture) !?transient.Chosen {
    applyAppCommands(fx);
    const received = takeInboxMessage(fx) orelse return null;
    try std.testing.expectEqual(transient_reply_tag, received.tag);
    const chosen = try received.payloadAs(transient.Chosen);
    return chosen.*;
}

test "a transient captures keys until a command is chosen, and answers its id and arguments" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try prepareTransient(&fx);
    const major_before = try routedMajor(&fx);
    try presentTestMenu(&fx);
    try std.testing.expect(transientCaptures(&fx));
    try std.testing.expectEqual(modes.transient, try routedMajor(&fx));

    // A switch's two keys turn it on, and the menu stays.
    try transientChar(&fx, '-');
    try transientChar(&fx, 'a');
    try std.testing.expect(transientCaptures(&fx));
    try std.testing.expect(try transientAnswer(&fx) == null);

    // An option's keys read its value in the palette's prompt, which has the keys meanwhile.
    try transientChar(&fx, '=');
    try transientChar(&fx, 'n');
    var asked: [2]action_palette.Request = undefined;
    const asked_prompts = action_palette.Requests.of(&fx.mem, &fx.tables, action_palette.requests_table_name).peek(&asked);
    try std.testing.expectEqual(@as(usize, 1), asked_prompts.len);
    try std.testing.expectEqualStrings("Limit", asked_prompts[0].present.completions.prompt);
    try std.testing.expect(!transientCaptures(&fx));
    const value_reply = asked_prompts[0].present.reply;
    var typed = try paletteEvent(&fx, value_reply.tag, .{ .kind = .completed, .completion = .{ .label = "" }, .query = "20" });
    typed.user_data = value_reply.user_data.bytes;
    try systemMessage(&fx, transient.system(), typed);
    try std.testing.expect(transientCaptures(&fx));

    // The command closes the menu, answering with what it was set to.
    try transientChar(&fx, 'l');
    const chosen = (try transientAnswer(&fx)).?;
    try std.testing.expectEqual(@as(u32, 10), chosen.id);
    try std.testing.expectEqual(@as(u8, 0), chosen.cancelled);
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try ui.transient.writeArguments(&test_transient_menu, &chosen.state, ' ', &writer);
    try std.testing.expectEqualStrings("--all --max-count=20 ", writer.buffered());
    try std.testing.expect(!transientCaptures(&fx));
    try std.testing.expectEqual(major_before, try routedMajor(&fx));
}

test "C-g closes a transient and answers cancelled" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try prepareTransient(&fx);
    try presentTestMenu(&fx);
    try transientChar(&fx, '-');
    try transientKey(&fx, .g, .{ .control = true });
    const chosen = (try transientAnswer(&fx)).?;
    try std.testing.expectEqual(@as(u8, 1), chosen.cancelled);
    try std.testing.expect(!transientCaptures(&fx));
}

test "an unbound key leaves the transient open and tells" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try prepareTransient(&fx);
    try presentTestMenu(&fx);
    try transientChar(&fx, '-');
    try transientChar(&fx, 'x');
    var sent: [4]plugin.text_editor_api.CmdPayload = undefined;
    const told = textEditorRequests(&fx, &sent);
    try std.testing.expectEqual(@as(usize, 1), told.len);
    try std.testing.expectEqualStrings("- x is not bound in Log", told[0].message);
    try std.testing.expect(transientCaptures(&fx));
    try std.testing.expect(try transientAnswer(&fx) == null);

    // A key with Control held is bound to nothing in a menu either.
    fx.resetCommands();
    try transientKey(&fx, .x, .{ .control = true });
    const told_again = textEditorRequests(&fx, &sent);
    try std.testing.expectEqual(@as(usize, 1), told_again.len);
    try std.testing.expectEqualStrings("C-x is not bound in Log", told_again[0].message);
    try std.testing.expect(transientCaptures(&fx));

    // Nor is a key that types nothing.
    fx.resetCommands();
    try transientKey(&fx, .enter, .{});
    const told_last = textEditorRequests(&fx, &sent);
    try std.testing.expectEqual(@as(usize, 1), told_last.len);
    try std.testing.expectEqualStrings("RET is not bound in Log", told_last[0].message);
    try std.testing.expect(transientCaptures(&fx));
}

/// The editor's init as an image loaded again runs it, through the host's init admission,
/// committed; the caller applies the plan and deinitialises it.
fn prepareReload(fx: *Fixture) !lib.PreparedEditorInit {
    const memory_token = try fx.mem.beginInitAdmission();
    const table_token = try fx.tables.beginInitAdmission();
    var plan = try lib.prepareEditorInit(&fx.mem, &fx.atoms, &fx.tables, .{});
    errdefer plan.deinit();
    try plan.stage();
    try plan.validate();
    try fx.tables.validateInitAdmission(table_token);
    try fx.mem.validateInitAdmission(memory_token);
    try std.testing.expect(fx.tables.commitInitAdmission(table_token));
    try std.testing.expect(fx.mem.commitInitAdmission(memory_token));
    return plan;
}

/// `test_transient_menu` shown and reading the value of its option `=n` in the palette's
/// prompt, which the palette opened; the reply the prompt answers.
fn readTestValue(fx: *Fixture) !sequencer_mod.ReplyTo {
    try presentTestMenu(fx);
    try transientChar(fx, '=');
    try transientChar(fx, 'n');
    var asked: [2]action_palette.Request = undefined;
    const asked_prompts = action_palette.Requests.of(&fx.mem, &fx.tables, action_palette.requests_table_name).peek(&asked);
    try std.testing.expectEqual(@as(usize, 1), asked_prompts.len);
    const reply = asked_prompts[0].present.reply;
    try runPalette(fx);
    try std.testing.expectEqual(transient.value_prompt_owner, action_palette.currentOwner(&fx.tables, &fx.atoms).?);
    return reply;
}

test "a reload while a transient reads a value cancels its prompt, and a prompt another system presented then stays open" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try prepareTransient(&fx);
    _ = try readTestValue(&fx);
    var plan = try prepareReload(&fx);
    defer plan.deinit();
    plan.apply();
    // In the frame after: another system presents a prompt before the transient runs.
    const completions: action_palette.Completions = .{ .owner = Atom.from("test_other"), .presentation = .prompt, .entries = &.{} };
    action_palette.request(&fx.mem, &fx.tables, .{ .present = .{ .completions = &completions, .reply = testReply(Atom.from("test_other_prompt")) } });
    try runSystem(&fx, transient.system());
    try runPalette(&fx);
    try std.testing.expectEqual(Atom.from("test_other"), action_palette.currentOwner(&fx.tables, &fx.atoms).?);
    const chosen = (try transientAnswer(&fx)).?;
    try std.testing.expectEqual(@as(u8, 1), chosen.cancelled);
}

test "a reload while a transient reads a value closes its prompt, and the palette opens the next" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try prepareTransient(&fx);
    _ = try readTestValue(&fx);
    var plan = try prepareReload(&fx);
    defer plan.deinit();
    plan.apply();
    try runSystem(&fx, transient.system());
    try runPalette(&fx);
    try std.testing.expect(!action_palette.requestOpen(&fx.tables, &fx.atoms));
    // The cancel was acknowledged: a prompt presented now opens.
    try std.testing.expect(action_palette.canPresent(&fx.tables, &fx.atoms));
}

test "a transient drops a value answered for another option than the one it reads" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try prepareTransient(&fx);
    const reply = try readTestValue(&fx);
    const other_option: u32 = 99;
    var late = try paletteEvent(&fx, reply.tag, .{ .kind = .completed, .completion = .{ .label = "" }, .query = "5" });
    late.user_data = std.mem.asBytes(&other_option);
    try systemMessage(&fx, transient.system(), late);
    // Still reading: the menu has not taken the keys back.
    try std.testing.expect(!transientCaptures(&fx));
    var answered = try paletteEvent(&fx, reply.tag, .{ .kind = .completed, .completion = .{ .label = "" }, .query = "7" });
    answered.user_data = reply.user_data.bytes;
    try systemMessage(&fx, transient.system(), answered);
    try std.testing.expect(transientCaptures(&fx));
    try transientChar(&fx, 'l');
    const chosen = (try transientAnswer(&fx)).?;
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try ui.transient.writeArguments(&test_transient_menu, &chosen.state, ' ', &writer);
    try std.testing.expectEqualStrings("--max-count=7 ", writer.buffered());
}

test "a transient shown as a reloaded editor initialises is closed unread and answered cancelled" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try prepareTransient(&fx);
    try presentTestMenu(&fx);
    // As an image of the editor loaded again initialises, through the init admission the host
    // runs it in: the menu's address was the last image's. Nothing changes before it applies.
    var plan = try prepareReload(&fx);
    defer plan.deinit();
    try std.testing.expect(transient.shown(&fx.tables) != null);
    plan.apply();
    try std.testing.expect(transient.shown(&fx.tables) == null);
    try runSystem(&fx, transient.system());
    const chosen = (try transientAnswer(&fx)).?;
    try std.testing.expectEqual(@as(u8, 1), chosen.cancelled);
    try std.testing.expect(!transientCaptures(&fx));
}

test "a transient presented over a shown one replaces it, whose presenter hears cancelled" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try prepareTransient(&fx);
    try presentTestMenu(&fx);
    transient.present(&fx.mem, &fx.tables, .{ .menu = &test_transient_menu, .reply = testReply(Atom.from("test_transient_next")) });
    try runSystem(&fx, transient.system());
    const replaced = (try transientAnswer(&fx)).?;
    try std.testing.expectEqual(@as(u8, 1), replaced.cancelled);
    try std.testing.expect(transientCaptures(&fx));
    try std.testing.expect(transient.shown(&fx.tables) != null);
}

/// A prompt of the palette's, which another system presents, opened.
fn openOtherPrompt(fx: *Fixture, completions: *const action_palette.Completions) !void {
    action_palette.request(&fx.mem, &fx.tables, .{ .present = .{ .completions = completions, .reply = testReply(Atom.from("test_other_prompt")) } });
    try runPalette(fx);
    try std.testing.expect(action_palette.requestOpen(&fx.tables, &fx.atoms));
}

test "a transient presented while a palette prompt is open is refused and answered cancelled" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try prepareTransient(&fx);
    const completions: action_palette.Completions = .{ .owner = Atom.from("test_other"), .presentation = .prompt, .entries = &.{} };
    try openOtherPrompt(&fx, &completions);
    try presentTestMenu(&fx);
    const refused = (try transientAnswer(&fx)).?;
    try std.testing.expectEqual(@as(u8, 1), refused.cancelled);
    try std.testing.expect(transient.shown(&fx.tables) == null);
    try std.testing.expect(!transientCaptures(&fx));
}

test "a palette prompt another system opens over a transient closes it, and the modes come back as it closes" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try prepareTransient(&fx);
    const major_before = try routedMajor(&fx);
    try presentTestMenu(&fx);
    try std.testing.expectEqual(modes.transient, try routedMajor(&fx));

    const completions: action_palette.Completions = .{ .owner = Atom.from("test_other"), .presentation = .prompt, .entries = &.{} };
    try openOtherPrompt(&fx, &completions);
    try std.testing.expectEqual(modes.prompt, try routedMajor(&fx));
    // The next frame: the menu closes before it takes a key, then the palette runs.
    try runSystem(&fx, transient.system());
    try runPalette(&fx);
    const closed = (try transientAnswer(&fx)).?;
    try std.testing.expectEqual(@as(u8, 1), closed.cancelled);
    try std.testing.expect(!transientCaptures(&fx));
    try std.testing.expectEqual(modes.prompt, try routedMajor(&fx));

    action_palette.request(&fx.mem, &fx.tables, .{ .dismiss = .{} });
    try runPalette(&fx);
    try std.testing.expectEqual(major_before, try routedMajor(&fx));
}

fn initModes(fx: *Fixture) !void {
    try keybinds.init(&fx.atoms, &fx.tables);
    try plugin.action_api.ensureChordState(.{ .allocator = std.testing.allocator }, &fx.atoms, &fx.tables);
}

/// What the tests' own prompts name for their answers.
fn replyReceiver() sequencer_mod.System {
    return .{ .name = "editor_test_replies", .root = Atom.from("editor_test_replies"), .claims = sequencer_mod.claims_nothing, .access = noTestAccess, .kernels = &.{} };
}

fn noTestAccess(frame: *const sequencer_mod.Frame) sequencer_mod.Access {
    _ = frame;
    return .{};
}

fn testReply(tag: Atom) sequencer_mod.ReplyTo {
    return sequencer_mod.ReplyTo.of(replyReceiver(), tag);
}

/// Every system's inbox, and the tests' own, so the palette's answers have somewhere to go
/// whichever systems a test runs.
fn ensureReplyInboxes(fx: *Fixture) !void {
    const scratch = try fx.mem.tableScratchAllocator();
    try editor_sequencer.ensure(scratch, &fx.atoms, &fx.tables);
    const receivers: sequencer_mod.Sequencer = .{ .name = "editor_test_replies_sequencer", .steps = &.{.{ .system = replyReceiver() }} };
    try sequencer_mod.ensureInboxes(scratch, &fx.atoms, &fx.tables, &receivers);
}

/// The first palette answer waiting in an inbox the palette answered to, taken out of it so
/// that the system's run does not take it too. A copy in the frame's scratch: the next
/// delivery to an emptied inbox reuses its storage.
fn takeInboxMessage(fx: *Fixture) ?sequencer_mod.Message {
    for (fx.answer_inboxes[0..fx.answer_inbox_count]) |name| {
        const inbox = fx.tables.findByName(name) orelse continue;
        const waiting = sequencer_mod.takeOldest(inbox) orelse continue;
        const scratch = fx.mem.frameScratchAllocator() catch return null;
        const payload = scratch.allocator.alignedAlloc(u8, Table.bytes_alignment, waiting.payload.len) catch return null;
        @memcpy(payload, waiting.payload);
        const user_data = scratch.allocator.alignedAlloc(u8, Table.bytes_alignment, waiting.user_data.len) catch return null;
        @memcpy(user_data, waiting.user_data);
        return .{ .tag = waiting.tag, .payload = payload, .user_data = user_data };
    }
    return null;
}

fn popEditorMessage(fx: *Fixture) sequencer_mod.Message {
    return takeInboxMessage(fx) orelse unreachable;
}

/// `event` as the palette answers it under `tag`, its payload in the frame's scratch.
fn paletteEvent(fx: *Fixture, tag: Atom, event: action_palette.Msg.Event) !sequencer_mod.Message {
    const scratch = try fx.mem.frameScratchAllocator();
    const payload = try plugin.editor_api.eventPayload(scratch.allocator, event);
    return .{ .tag = tag, .payload = payload };
}

/// The palette takes the frame's requests, then the queue's commands are applied: the palette's
/// events reach their owners' routes in the fixture's messages.
fn dispatchEditorCommands(fx: *Fixture) !void {
    try runPalette(fx);
    applyAppCommands(fx);
    fx.resetCommands();
}

/// As `dispatchEditorCommands`, with the figure's host system applying its rows between.
fn dispatchWithFigure(fx: *Fixture, figure_commands: *figure_runtime.HostTransport.HostContext) !void {
    try runPalette(fx);
    transport_fixture.declareWatches(&fx.mem, &fx.atoms, &fx.tables);
    try figure_runtime.HostTransport.dispatch(figure_commands);
    try figure_runtime.HostTransport.synchronize(figure_commands.host);
    fx.resetCommands();
}

fn toggleActionPalette(fx: *Fixture) !void {
    fx.resetCommands();
    try editorAction(fx, .{ .tag = Atom.from("action_palette_toggle") });
    try dispatchEditorCommands(fx);
}

/// The action list shows `entries` for `query`, as the editor lists the actions offered.
fn deliverActionListReply(fx: *Fixture, query: []const u8, entries: []const plugin.action_api.ListEntry) !void {
    lib.showActionList(&fx.mem, &fx.tables, &fx.atoms, query, entries);
    try dispatchEditorCommands(fx);
}

test "action search uses Actions list subscriptions and sends invoke_action for the selected entry" {
    const allocator = std.testing.allocator;
    var fx: Fixture = .{};
    try fx.init(allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    try initModes(&fx);
    fx.resetCommands();

    try editorAction(&fx, .{ .tag = Atom.from("action_palette_toggle") });
    try dispatchEditorCommands(&fx);
    try std.testing.expectEqual(lib.kActionListOwner, action_palette.currentOwner(&fx.tables, &fx.atoms).?);

    var query: [action_palette.kBufSize]u8 = std.mem.zeroes([action_palette.kBufSize]u8);
    for ("row_ad", 0..) |cp, i| {
        query[i] = cp;
        // The text editor holds the text, and reports it as each key changes it.
        try editorReport(&fx, query[0 .. i + 1]);
        try dispatchEditorCommands(&fx);
        const change_message = popEditorMessage(&fx);
        const change = try action_palette.eventOf(change_message);
        try std.testing.expectEqual(action_palette.Msg.EventKind.query_changed, change.kind);
        try std.testing.expectEqualStrings(query[0 .. i + 1], change.query);
        try editorMessage(&fx, change_message);
    }

    // The fixture does not run the editor's init, which interns the mode names.
    _ = fx.atoms.intern("global");
    const rows = [_]plugin.action_api.ListEntry{.{ .id = .{ plugin.action_api.global_mode, fx.atoms.intern("row_add") }, .mode = "global", .label = "row_add", .doc = "Add a row" }};
    try deliverActionListReply(&fx, "row_ad", &rows);
    const completions = action_palette.currentCompletions(&fx.tables, &fx.atoms).?;
    try std.testing.expectEqual(@as(usize, 1), completions.entries.len);
    try std.testing.expectEqualStrings("global.row_add", completions.entries[0].label);
    try std.testing.expectEqualStrings("Add a row", completions.entries[0].detail);

    // The submit waits for the text editor's report of its text, which it asks for.
    try paletteKey(&fx, action_palette.Msg.submit);
    try editorReport(&fx, "row_ad");
    try dispatchEditorCommands(&fx);
    const selected_message = popEditorMessage(&fx);
    const selected = try action_palette.eventOf(selected_message);
    try std.testing.expectEqual(action_palette.Msg.EventKind.completed, selected.kind);
    try std.testing.expectEqualStrings("row_ad", selected.query);
    try editorMessage(&fx, selected_message);

    var invoked: [8]Atom = undefined;
    try std.testing.expectEqualSlices(Atom, &.{fx.atoms.intern("row_add")}, invokedActions(&fx, &invoked));
    try std.testing.expect(!lib.actionListOpen(&fx.tables, &fx.atoms));
}

test "the action list shows the listed actions offered that match its query" {
    const allocator = std.testing.allocator;
    var fx: Fixture = .{};
    try fx.init(allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    try initModes(&fx);
    fx.resetCommands();

    try editorAction(&fx, .{ .tag = Atom.from("action_palette_toggle") });
    try dispatchEditorCommands(&fx);
    try setPromptText(&fx, "row");

    // Offered this frame: one that matches, one that does not, one not listed, and one that
    // matches of a mode not active where the palette opened.
    _ = fx.atoms.intern("global");
    var rows = try actionRows(&fx);
    rows.actions.push(.{ .id = .{ plugin.action_api.global_mode, fx.atoms.intern("row_add") }, .doc = "Add a row", .tag = fx.atoms.intern("row_add") });
    rows.actions.push(.{ .id = .{ plugin.action_api.global_mode, fx.atoms.intern("figure_open") }, .doc = "Open a figure", .tag = fx.atoms.intern("figure_open") });
    rows.actions.push(.{ .id = .{ plugin.action_api.global_mode, fx.atoms.intern("row_hidden") }, .tag = fx.atoms.intern("row_hidden"), .listed = false });
    rows.actions.push(.{ .id = .{ fx.atoms.intern("figure"), fx.atoms.intern("row_figure") }, .tag = fx.atoms.intern("row_figure") });
    try runSystem(&fx, lib.subscriptionsSystem());
    try dispatchEditorCommands(&fx);
    try runPalette(&fx);
    const completions = action_palette.currentCompletions(&fx.tables, &fx.atoms).?;
    try std.testing.expectEqualStrings("row", completions.initial_query);
    var listed_row_add = false;
    for (completions.entries) |entry| {
        try std.testing.expect(!std.mem.eql(u8, entry.label, "global.figure_open"));
        try std.testing.expect(!std.mem.eql(u8, entry.label, "global.row_hidden"));
        try std.testing.expect(!std.mem.eql(u8, entry.label, "figure.row_figure"));
        if (std.mem.eql(u8, entry.label, "global.row_add")) listed_row_add = true;
    }
    try std.testing.expect(listed_row_add);
}

test "an action picked from the palette is asked for after the modes it was opened over" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    fx.resetCommands();
    const requests = plugin.action_api.Requests.of(&fx.mem, &fx.tables, plugin.action_api.commands_table_name);
    requests.reset();

    // The palette kept the figure stage's modes as its prompt opened.
    const palette_modes = fx.tables.findByName(Atom.from(action_palette.prompt_modes_table_name)).?;
    const no_minors: [plugin.action_api.kMaxMinorModes]Atom = @splat(plugin.action_api.no_mode);
    _ = try palette_modes.tryInsert(.{
        .prompt = modes.prompt,
        .prompt_minors = no_minors,
        .prompt_minor_count = @as(u8, 0),
        .kept_major = modes.figure,
        .kept_minors = no_minors,
        .kept_minor_count = @as(u8, 0),
    });

    const picked: plugin.action_api.ActionId = .{ modes.figure, fx.atoms.intern("save") };
    var completion: action_palette.Completion = .{ .label = "Save figure" };
    @memcpy(completion.data[0..@sizeOf(plugin.action_api.ActionId)], std.mem.asBytes(&picked));
    const event = try paletteEvent(&fx, lib.action_selected_tag, .{ .kind = .completed, .completion = completion, .query = "" });
    try editorMessage(&fx, event);

    var queued: [4]plugin.action_api.Command = undefined;
    const commands = requests.peek(&queued);
    try std.testing.expectEqual(@as(usize, 2), commands.len);
    try std.testing.expectEqual(modes.figure, commands[0].set_modes.major);
    try std.testing.expectEqual(@as(u8, 0), commands[0].set_modes.minor_count);
    try std.testing.expectEqualSlices(Atom, &picked, &commands[1].invoke);
    requests.reset();
}

test "action palette toggles focus clicks with modal keyboard ownership" {
    const allocator = std.testing.allocator;
    var fx: Fixture = .{};
    try fx.init(allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    fx.resetCommands();

    // A requester's command reaches the palette through the hook, which appends it as a row.
    const completions = action_palette.Completions{ .presentation = .prompt, .entries = &.{} };
    var present: plugin.app_commands.Payload = .{ .action_palette = .{ .present = .{ .completions = &completions, .reply = .{} } } };
    const presented = lib.processCmd(&fx.tables, &fx.atoms, &present);
    try std.testing.expect(presented == .done);
    try runPalette(&fx);
    fx.resetCommands();
    lib.syncFocusClicks(&fx.tables, &fx.atoms);
    try std.testing.expectEqual(@as(u8, 2), state.viewFocus(&fx.tables, &fx.atoms).focus_clicks_disabled.*);
    try std.testing.expectEqual(@as(usize, 1), panelRequestCount(&fx.tables));
    // The minibuffer's prompt has the keyboard: the panels are told it is outside them.
    const disable = panelRequestAt(&fx.tables, 0).?;
    try std.testing.expect(disable == .disable_focus_clicks);
    try std.testing.expectEqual(plugin.panels.KeyboardPlace.outside_panels, disable.disable_focus_clicks.keyboard);

    fx.resetCommands();
    var dismiss: plugin.app_commands.Payload = .{ .action_palette = .{ .dismiss = .{} } };
    const dismissed = lib.processCmd(&fx.tables, &fx.atoms, &dismiss);
    try std.testing.expect(dismissed == .done);
    try runPalette(&fx);
    fx.resetCommands();
    lib.syncFocusClicks(&fx.tables, &fx.atoms);
    try std.testing.expectEqual(@as(u8, 0), state.viewFocus(&fx.tables, &fx.atoms).focus_clicks_disabled.*);
    try std.testing.expectEqual(@as(usize, 1), panelRequestCount(&fx.tables));
    const enable = panelRequestAt(&fx.tables, 0).?;
    try std.testing.expect(enable == .enable_focus_clicks);
}

test "form context disables and restores focus clicks" {
    const allocator = std.testing.allocator;
    var fx: Fixture = .{};
    try fx.init(allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    fx.resetCommands();

    const authoring_ui = state.authoringUi(&fx.tables, &fx.atoms);
    authoring_ui.form_focus.* = @intFromEnum(state.FormFocus.meta_key);
    lib.syncFocusClicks(&fx.tables, &fx.atoms);
    try std.testing.expectEqual(@as(usize, 1), panelRequestCount(&fx.tables));
    // A form is in the focused panel, which keeps the keyboard.
    const disable = panelRequestAt(&fx.tables, 0).?;
    try std.testing.expect(disable == .disable_focus_clicks);
    try std.testing.expectEqual(plugin.panels.KeyboardPlace.focused_panel, disable.disable_focus_clicks.keyboard);

    fx.resetCommands();
    authoring_ui.form_focus.* = @intFromEnum(state.FormFocus.none);
    lib.syncFocusClicks(&fx.tables, &fx.atoms);
    try std.testing.expectEqual(@as(usize, 1), panelRequestCount(&fx.tables));
    try std.testing.expect(panelRequestAt(&fx.tables, 0).? == .enable_focus_clicks);
}

test "action palette requests report query changes, replaced-list selections, and null cancellation" {
    const allocator = std.testing.allocator;
    var fx: Fixture = .{};
    try fx.init(allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    try initModes(&fx);
    fx.resetCommands();

    var first_entries = [_]action_palette.Completion{.{ .label = "first" }};
    const first = action_palette.Completions{ .entries = &first_entries };
    const reply_route = testReply(Atom.from("test_action_palette_reply"));
    action_palette.request(&fx.mem, &fx.tables, .{ .present = .{ .completions = &first, .reply = reply_route } });
    try dispatchEditorCommands(&fx);
    try std.testing.expect(action_palette.requestOpen(&fx.tables, &fx.atoms));
    try std.testing.expect(action_palette.currentCompletions(&fx.tables, &fx.atoms).? == &first);

    // A key goes to the text editor holding the prompt's text, which reports the text back.
    fx.resetCommands();
    const char = input_mod.TextInputMsg{ .codepoint = 'x' };
    try paletteMessage(&fx, .{ .tag = action_palette.Msg.char, .payload = std.mem.asBytes(&char) });
    var sent: [4]plugin.text_editor_api.CmdPayload = undefined;
    const editor_requests = plugin.text_editor_api.Requests.of(&fx.mem, &fx.tables, plugin.text_editor_api.commands_table_name).peek(&sent);
    const typed = editor_requests[0].insert;
    try std.testing.expectEqualStrings("x", typed.utf8);
    try editorReport(&fx, "x");
    try dispatchEditorCommands(&fx);
    const query_message = popEditorMessage(&fx);
    const query_event = try action_palette.eventOf(query_message);
    try std.testing.expectEqual(action_palette.Msg.EventKind.query_changed, query_event.kind);
    try std.testing.expectEqualStrings("x", query_event.query);

    var replacement_entries = [_]action_palette.Completion{.{ .label = "replacement" }};
    const replacement = action_palette.Completions{ .entries = &replacement_entries };
    action_palette.request(&fx.mem, &fx.tables, .{ .replace = .{ .completions = &replacement } });
    try dispatchEditorCommands(&fx);
    try std.testing.expect(action_palette.currentCompletions(&fx.tables, &fx.atoms).? == &replacement);
    try std.testing.expectEqualStrings("first", first_entries[0].label);

    try paletteInvoke(&fx, 0);
    try dispatchEditorCommands(&fx);
    const chosen_message = popEditorMessage(&fx);
    const chosen = try action_palette.eventOf(chosen_message);
    try std.testing.expectEqual(action_palette.Msg.EventKind.completed, chosen.kind);
    try std.testing.expectEqualStrings(replacement_entries[0].label, chosen.completion.?.label);
    try std.testing.expectEqualSlices(u8, &replacement_entries[0].data, &chosen.completion.?.data);
    try std.testing.expectEqualStrings("x", chosen.query);

    var cancel_entries = [_]action_palette.Completion{.{ .label = "cancel me" }};
    const cancel_list = action_palette.Completions{ .entries = &cancel_entries };
    action_palette.request(&fx.mem, &fx.tables, .{ .present = .{ .completions = &cancel_list, .reply = reply_route } });
    try dispatchEditorCommands(&fx);
    try paletteKey(&fx, action_palette.Msg.cancel);
    try dispatchEditorCommands(&fx);
    const cancelled_message = popEditorMessage(&fx);
    const cancelled = try action_palette.eventOf(cancelled_message);
    try std.testing.expectEqual(action_palette.Msg.EventKind.completed, cancelled.kind);
    try std.testing.expect(cancelled.completion == null);
    try std.testing.expect(!action_palette.requestOpen(&fx.tables, &fx.atoms));
}

test "deferred picker cancellation sends null completion from the host intercept path" {
    const allocator = std.testing.allocator;
    var fx: Fixture = .{};
    try fx.init(allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    try initModes(&fx);
    fx.resetCommands();

    var entries = [_]action_palette.Completion{.{ .label = "candidate" }};
    const completions = action_palette.Completions{ .owner = windows.kPickerOwner, .presentation = .prompt, .entries = &entries };
    const route = testReply(.from(windows.Msg.picker_completion_reply));
    action_palette.request(&fx.mem, &fx.tables, .{ .present = .{ .completions = &completions, .reply = route } });
    try dispatchEditorCommands(&fx);
    try std.testing.expect(windows.pickerOpen(&fx.tables, &fx.atoms));

    windows.dismissPicker(&fx.tables, &fx.atoms);
    try runSystem(&fx, lib.messagesSystem());
    try dispatchEditorCommands(&fx);
    try std.testing.expect(!windows.pickerOpen(&fx.tables, &fx.atoms));
    const cancelled_message = popEditorMessage(&fx);
    const cancelled = try action_palette.eventOf(cancelled_message);
    try std.testing.expectEqual(action_palette.Msg.EventKind.completed, cancelled.kind);
    try std.testing.expect(cancelled.completion == null);
    try std.testing.expect(!action_palette.canPresent(&fx.tables, &fx.atoms));
    try editorMessage(&fx, cancelled_message);
    try runPalette(&fx);
    try std.testing.expect(action_palette.canPresent(&fx.tables, &fx.atoms));
}

test "window picker rebuilds owner completions on query changes and opens the selected table" {
    const allocator = std.testing.allocator;
    var fx: Fixture = .{};
    try fx.init(allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    try initModes(&fx);
    fx.resetCommands();
    _ = try targetTable(allocator, &fx.atoms, &fx.tables);

    try editorAction(&fx, .{ .tag = .from(windows.Msg.picker_toggle) });
    try dispatchEditorCommands(&fx);
    try std.testing.expectEqual(windows.kPickerOwner, action_palette.currentOwner(&fx.tables, &fx.atoms).?);

    const typed = "test.target";
    for (1..typed.len + 1) |count| {
        try editorReport(&fx, typed[0..count]);
        try dispatchEditorCommands(&fx);
        const change_message = popEditorMessage(&fx);
        const change = try action_palette.eventOf(change_message);
        try std.testing.expectEqual(action_palette.Msg.EventKind.query_changed, change.kind);
        try windowsMessage(&fx, change_message);
        try dispatchEditorCommands(&fx);
    }
    const completions = action_palette.currentCompletions(&fx.tables, &fx.atoms).?;
    try std.testing.expectEqual(@as(usize, 1), completions.entries.len);
    try std.testing.expectEqualStrings("test.target", completions.entries[0].label);

    try paletteInvoke(&fx, 0);
    try dispatchEditorCommands(&fx);
    const selected_message = popEditorMessage(&fx);
    try editorMessage(&fx, selected_message);
    try std.testing.expect(!windows.pickerOpen(&fx.tables, &fx.atoms));
    try std.testing.expectEqual(@as(u32, 1), windows.windows(&fx.tables, &fx.atoms).count());
    fx.resetCommands();
}

test "picker cancellation with persisted scope confirmation reopens the ordinary picker" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    try initModes(&fx);
    fx.resetCommands();

    try editorAction(&fx, .{ .tag = .from(windows.Msg.picker_toggle) });
    try dispatchEditorCommands(&fx);
    windows.picker(&fx.tables, &fx.atoms).confirm_scope.* = 1;

    try paletteKey(&fx, action_palette.Msg.cancel);
    try dispatchEditorCommands(&fx);
    const reply = popEditorMessage(&fx);
    try editorMessage(&fx, reply);
    try dispatchEditorCommands(&fx);
    try std.testing.expectEqual(@as(u8, 0), windows.picker(&fx.tables, &fx.atoms).confirm_scope.*);
    try std.testing.expect(windows.pickerOpen(&fx.tables, &fx.atoms));
    try std.testing.expectEqual(action_palette.Completions.Presentation.prompt, action_palette.currentCompletions(&fx.tables, &fx.atoms).?.presentation);
}

test "modal actions render as completion entries and selected action closes the dialog" {
    const allocator = std.testing.allocator;
    var fx: Fixture = .{};
    try fx.init(allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    try initModes(&fx);
    fx.resetCommands();

    const authoring_ui = state.authoringUi(&fx.tables, &fx.atoms);
    authoring_ui.modal.* = @intFromEnum(state.Modal.conflict);
    try runSystem(&fx, windows.system());
    try dispatchEditorCommands(&fx);

    const completions = action_palette.currentCompletions(&fx.tables, &fx.atoms).?;
    try std.testing.expectEqual(windows.kModalOwner, completions.owner);
    try std.testing.expectEqual(action_palette.Completions.Presentation.dialog, completions.presentation);
    try std.testing.expectEqual(@as(usize, 3), completions.entries.len);
    try std.testing.expectEqualStrings("Cancel", completions.entries[2].label);

    try paletteInvoke(&fx, 2);
    try dispatchEditorCommands(&fx);
    const response = popEditorMessage(&fx);
    const event = try action_palette.eventOf(response);
    try std.testing.expectEqual(action_palette.Msg.EventKind.completed, event.kind);
    try std.testing.expectEqual(Atom.from("modal_cancel"), std.mem.bytesToValue(Atom, event.completion.?.data[0..@sizeOf(Atom)]));
    try editorMessage(&fx, response);
    try std.testing.expectEqual(state.Modal.none, @as(state.Modal, @enumFromInt(authoring_ui.modal.*)));
    try std.testing.expect(!action_palette.requestOpen(&fx.tables, &fx.atoms));
}

/// The prompt's text editor holding `text`, as after its host applied the typing: the text in
/// its buffer, a change in the editors' events; then the palette's input system reads it.
fn editorReport(fx: *Fixture, text: []const u8) !void {
    publishEditorText(fx, action_palette.text_editor_name, text);
    try runSystem(fx, action_palette.inputSystem());
}

fn publishEditorText(fx: *Fixture, editor: Atom, text: []const u8) void {
    fx.text_editors.apply(&fx.tables, .{ .set_text = .{ .buffer = editor, .text = text } });
    fx.text_editors.publish(&fx.tables);
}

test "action palette query events only follow text changes" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    fx.resetCommands();
    const completions = action_palette.Completions{ .owner = fx.atoms.intern("test_prompt"), .presentation = .prompt, .initial_query = "abc", .entries = &.{} };
    const route = testReply(fx.atoms.intern("test_reply"));
    // The palette's run opens the prompt and loads its text editor with the seed.
    action_palette.request(&fx.mem, &fx.tables, .{ .present = .{ .completions = &completions, .reply = route } });
    try runPalette(&fx);
    const prompt = action_palette.prompt(&fx.tables, &fx.atoms);
    try std.testing.expectEqualStrings("abc", promptText(&fx));
    prompt.selected.* = 3;
    // The text editor holds the text; its reports are what change it here.
    fx.resetCommands();
    try editorReport(&fx, "abc");
    try std.testing.expectEqual(@as(usize, 0), appRequestCount(&fx));
    try std.testing.expectEqual(@as(u32, 3), prompt.selected.*);
    try editorReport(&fx, "ab");
    try std.testing.expectEqual(@as(u32, 0), prompt.selected.*);
    try dispatchEditorCommands(&fx);
    const header = popEditorMessage(&fx);
    const event = try action_palette.eventOf(header);
    try std.testing.expectEqual(action_palette.Msg.EventKind.query_changed, event.kind);
    try std.testing.expectEqualStrings("ab", event.query);
}

/// Opens `completions` in the palette, its text editor holding the prompt's text, and clears
/// what the opening asked for.
fn openHeldPrompt(fx: *Fixture, completions: *const action_palette.Completions) !void {
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    try initModes(fx);
    fx.resetCommands();
    const route = testReply(fx.atoms.intern("test_reply"));
    action_palette.request(&fx.mem, &fx.tables, .{ .present = .{ .completions = completions, .reply = route } });
    try runPalette(fx);
    try editorReport(fx, completions.initial_query);
    fx.resetCommands();
}

/// Tab at the open prompt.
fn pressTab(fx: *Fixture) !void {
    try paletteMessage(fx, .{ .tag = Atom.from("prompt_complete") });
}

/// The text Tab asked the prompt's text editor to type over the whole text; null when it asked
/// nothing.
fn tabTyped(fx: *Fixture) !?[]const u8 {
    var sent: [4]plugin.text_editor_api.CmdPayload = undefined;
    const requests = textEditorRequests(fx, &sent);
    if (requests.len == 0) return null;
    try std.testing.expectEqual(@as(usize, 2), requests.len);
    try std.testing.expectEqual(plugin.text_editor_api.EditCommand.select_all, requests[0].run.command);
    return requests[1].insert.utf8;
}

test "action palette Tab makes the text the selected entry" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    const entries = [_]action_palette.Completion{ .{ .label = "alpha" }, .{ .label = "beta" } };
    const completions = action_palette.Completions{ .owner = fx.atoms.intern("test_prompt"), .entries = &entries };
    try openHeldPrompt(&fx, &completions);
    const prompt = action_palette.prompt(&fx.tables, &fx.atoms);

    try paletteMessage(&fx, .{ .tag = Atom.from("prompt_next") });
    try std.testing.expectEqual(@as(u32, 1), prompt.selected.*);
    try pressTab(&fx);
    try std.testing.expectEqualStrings("beta", (try tabTyped(&fx)) orelse return error.TestUnexpectedResult);
    // The text editor's report is the text's change, which keeps the entry completed selected.
    try editorReport(&fx, "beta");
    try std.testing.expectEqualStrings("beta", promptText(&fx));
    try std.testing.expectEqual(@as(u32, 1), prompt.selected.*);
}

test "action palette Tab does not move the selection when there is nothing to add" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    const entries = [_]action_palette.Completion{ .{ .label = "alpha" }, .{ .label = "beta" } };
    const completions = action_palette.Completions{ .owner = fx.atoms.intern("test_prompt"), .entries = &entries };
    try openHeldPrompt(&fx, &completions);
    const prompt = action_palette.prompt(&fx.tables, &fx.atoms);

    try pressTab(&fx);
    try std.testing.expectEqualStrings("alpha", (try tabTyped(&fx)) orelse return error.TestUnexpectedResult);
    try editorReport(&fx, "alpha");
    try std.testing.expectEqual(@as(u32, 0), prompt.selected.*);
    fx.resetCommands();
    // The text is the selected entry's already: the second Tab asks nothing and moves nothing.
    try pressTab(&fx);
    try std.testing.expectEqual(@as(?[]const u8, null), try tabTyped(&fx));
    try std.testing.expectEqual(@as(u32, 0), prompt.selected.*);
    try std.testing.expectEqualStrings("alpha", promptText(&fx));
}

test "action palette Tab completes a directory with its slash in find-file" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    try initModes(&fx);
    fx.resetCommands();
    try systemAction(&fx, open.system(), Atom.from("project_find_directory"));
    const reply = try findFileListingAsked(&fx, "");
    const listed = [_]plugin.text_editor_api.ListedEntry{ .{ .kind = .file, .name = "notes.txt" }, .{ .kind = .directory, .name = "cast" } };
    try deliverListing(&fx, sequencer_mod.inboxOf(open.system()), reply.tag, reply.user_data.bytes, .listed, "/home/someone/art", &listed);
    try runSystem(&fx, open.system());
    try dispatchEditorCommands(&fx);
    try std.testing.expectEqualStrings("/home/someone/art/", promptText(&fx));
    try editorReport(&fx, "/home/someone/art/");
    fx.resetCommands();

    const prompt = action_palette.prompt(&fx.tables, &fx.atoms);
    prompt.selected.* = try completionIndex(&fx, "cast/");
    try pressTab(&fx);
    try std.testing.expectEqualStrings("/home/someone/art/cast/", (try tabTyped(&fx)) orelse return error.TestUnexpectedResult);
    try editorReport(&fx, "/home/someone/art/cast/");
    try std.testing.expectEqualStrings("/home/someone/art/cast/", promptText(&fx));
}

/// Types `typed` in the open find-file prompt and lists its directory, asked as `directory`,
/// as holding `entries` under `real_directory`: the prompt then offers them.
fn typeAndList(fx: *Fixture, typed: []const u8, directory: []const u8, real_directory: []const u8, entries: []const plugin.text_editor_api.ListedEntry) !void {
    try editorReport(fx, typed);
    try dispatchEditorCommands(fx);
    try runSystem(fx, open.system());
    const reply = try findFileListingAsked(fx, directory);
    try deliverListing(fx, sequencer_mod.inboxOf(open.system()), reply.tag, reply.user_data.bytes, .listed, real_directory, entries);
    try runSystem(fx, open.system());
    try dispatchEditorCommands(fx);
}

test "action palette Tab completes to the entry selected with C-n, not to the entries' common beginning" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    try initModes(&fx);
    fx.resetCommands();
    try systemAction(&fx, open.system(), Atom.from("project_find_directory"));
    const reply = try findFileListingAsked(&fx, "");
    const listed = [_]plugin.text_editor_api.ListedEntry{ .{ .kind = .directory, .name = "proj" }, .{ .kind = .directory, .name = "prog" } };
    try deliverListing(&fx, sequencer_mod.inboxOf(open.system()), reply.tag, reply.user_data.bytes, .listed, "/a", &listed);
    try runSystem(&fx, open.system());
    try dispatchEditorCommands(&fx);
    try std.testing.expectEqualStrings("/a/", promptText(&fx));
    try typeAndList(&fx, "/a/p", "/a/", "/a", &listed);
    fx.resetCommands();

    const prompt = action_palette.prompt(&fx.tables, &fx.atoms);
    try paletteMessage(&fx, .{ .tag = Atom.from("prompt_next") });
    const completions = action_palette.currentCompletions(&fx.tables, &fx.atoms).?;
    const second = completions.entries[prompt.selected.*].label;
    const wanted = try std.fmt.allocPrint(std.testing.allocator, "/a/{s}", .{second});
    defer std.testing.allocator.free(wanted);
    try pressTab(&fx);
    // The selected entry, not `/a/pro`, which both names begin with.
    try std.testing.expectEqualStrings(wanted, (try tabTyped(&fx)) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(@as(u32, 1), prompt.selected.*);

    // The new directory's listing selects its first entry.
    const inside = [_]plugin.text_editor_api.ListedEntry{ .{ .kind = .file, .name = "main.zig" }, .{ .kind = .file, .name = "notes" } };
    try typeAndList(&fx, wanted, wanted, wanted, &inside);
    try std.testing.expectEqualStrings(wanted, promptText(&fx));
    try std.testing.expectEqualStrings("main.zig", action_palette.currentCompletions(&fx.tables, &fx.atoms).?.entries[0].label);
    try std.testing.expectEqual(@as(u32, 0), prompt.selected.*);
}

test "action palette Tab does nothing in a pattern prompt" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    const entries = [_]action_palette.Completion{ .{ .label = "src/a.zig:1:1:fn main" }, .{ .label = "src/b.zig:4:2:fn main" } };
    const completions = action_palette.Completions{ .owner = fx.atoms.intern("test_prompt"), .initial_query = "fn main", .tab = .nothing, .entries = &entries };
    try openHeldPrompt(&fx, &completions);
    const prompt = action_palette.prompt(&fx.tables, &fx.atoms);

    try pressTab(&fx);
    try std.testing.expectEqual(@as(?[]const u8, null), try tabTyped(&fx));
    try std.testing.expectEqual(@as(u32, 0), prompt.selected.*);
    try std.testing.expectEqualStrings("fn main", promptText(&fx));
}

test "a dialog's answers narrow to the text typed and Enter takes the one selected" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    try initModes(&fx);
    fx.resetCommands();
    const entries = [_]action_palette.Completion{ .{ .label = "Save" }, .{ .label = "Close without saving" }, .{ .label = "Cancel" } };
    const reply_route = testReply(Atom.from("test_dialog_reply"));

    // With no default nothing is selected: Enter takes no answer until one is moved to.
    const no_default = action_palette.Completions{ .owner = fx.atoms.intern("test_dialog"), .presentation = .dialog, .entries = &entries };
    action_palette.request(&fx.mem, &fx.tables, .{ .present = .{ .completions = &no_default, .reply = reply_route } });
    try dispatchEditorCommands(&fx);
    try std.testing.expectEqual(std.math.maxInt(u32), action_palette.prompt(&fx.tables, &fx.atoms).selected.*);
    try paletteKey(&fx, action_palette.Msg.submit);
    try editorReport(&fx, "");
    try dispatchEditorCommands(&fx);
    try std.testing.expect(action_palette.requestOpen(&fx.tables, &fx.atoms));
    try paletteKey(&fx, Atom.from("prompt_previous"));
    try std.testing.expectEqual(@as(u32, 2), action_palette.prompt(&fx.tables, &fx.atoms).selected.*);

    // The default is selected as it opens.
    const completions = action_palette.Completions{ .owner = no_default.owner, .presentation = .dialog, .default_entry = 2, .entries = &entries };
    action_palette.request(&fx.mem, &fx.tables, .{ .present = .{ .completions = &completions, .reply = reply_route } });
    try dispatchEditorCommands(&fx);
    // The dialog replaced holds nothing chosen.
    const replaced = try action_palette.eventOf(popEditorMessage(&fx));
    try std.testing.expect(replaced.completion == null);
    try std.testing.expectEqual(@as(u32, 2), action_palette.prompt(&fx.tables, &fx.atoms).selected.*);

    // "sav" is held by the first two labels, ignoring case, not by "Cancel": the second of
    // those listed is "Close without saving". The owner hears no query change.
    try editorReport(&fx, "sav");
    try dispatchEditorCommands(&fx);
    try std.testing.expect(takeInboxMessage(&fx) == null);
    try std.testing.expectEqual(@as(u32, 0), action_palette.prompt(&fx.tables, &fx.atoms).selected.*);
    try paletteKey(&fx, Atom.from("prompt_next"));
    try paletteKey(&fx, Atom.from("prompt_next"));
    try std.testing.expectEqual(@as(u32, 1), action_palette.prompt(&fx.tables, &fx.atoms).selected.*);
    try paletteKey(&fx, action_palette.Msg.submit);
    try editorReport(&fx, "sav");
    try dispatchEditorCommands(&fx);
    const chosen = try action_palette.eventOf(popEditorMessage(&fx));
    try std.testing.expectEqual(action_palette.Msg.EventKind.completed, chosen.kind);
    try std.testing.expectEqualStrings("Close without saving", chosen.completion.?.label);
}

test "an action picked from M-x is invoked through the shared operation API" {
    const allocator = std.testing.allocator;
    var fx: Fixture = .{};
    try fx.init(allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    try initModes(&fx);
    fx.resetCommands();

    try editorAction(&fx, .{ .tag = Atom.from("action_palette_toggle") });
    try dispatchEditorCommands(&fx);
    // The prompt's text is the text editor's.
    const action_name = "picked";
    try setPromptText(&fx, action_name);
    const rows = [_]plugin.action_api.ListEntry{.{ .id = .{ plugin.action_api.global_mode, fx.atoms.intern(action_name) }, .mode = "global", .label = action_name, .doc = "Do the picked thing" }};
    try deliverActionListReply(&fx, action_name, &rows);
    // The submit waits for the text editor's report of its text, which it asks for.
    try paletteKey(&fx, action_palette.Msg.submit);
    try editorReport(&fx, action_name);
    try dispatchEditorCommands(&fx);
    const selected_message = popEditorMessage(&fx);
    try editorMessage(&fx, selected_message);
    var invoked: [8]Atom = undefined;
    try std.testing.expectEqualSlices(Atom, &.{fx.atoms.intern(action_name)}, invokedActions(&fx, &invoked));
    try std.testing.expect(!lib.actionListOpen(&fx.tables, &fx.atoms));
}

/// A default key the editor binds: its chord as Emacs writes it, and the id of the action it
/// names.
const ExpectedKey = struct { chord: []const u8, mode: []const u8, name: []const u8 };

/// The editor's and the stage's actions, and those its modules offer while they edit text, whose
/// keys `expectKeysBound` looks for.
const keyed_actions = lib.editor_actions ++ stage.app_actions ++ text_editor.actions ++
    text_panel.panel_actions ++ text_panel.isearch_actions ++ windows.cell_actions ++
    windows.form_actions ++ action_palette.prompt_actions ++ table_view.actions ++ git_status.vcs_actions ++
    git_status.vcs_git_actions ++ git_commit.message_actions ++
    [_]plugin.action_api.Def{git_log.edit_action} ++ git_rebase.rebase_actions;

/// Expects each of `expected` among the bindings the actions system resolves while `major` is the
/// major mode, or the key's own mode when `major` is none, with the editor's modes registered and
/// its keymaps and the stage's declared, and its action among `keyed_actions`.
fn expectKeysBound(major: Atom, expected: []const ExpectedKey) !void {
    var memory: memory_mod.Memory = undefined;
    memory.init(std.testing.allocator);
    defer memory.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&memory);
    defer atoms.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&memory, 64);
    defer tables.deinit();
    const scratch = try memory.tableScratchAllocator();
    try mesha_runtime.actions.ensure(scratch, &atoms, &tables);
    try plugin.Keymaps.ensure(scratch, &atoms, &tables, plugin.action_api.keymaps_table_name);
    try plugin.Actions.ensure(scratch, &atoms, &tables, plugin.action_api.subscribed_table_name);
    modes.registerAll(&tables);
    try mesha_runtime.actions.route(&memory, &atoms, &tables);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var keymap_rows: plugin.KeymapRows = .{ .keymaps = plugin.Keymaps.of(&memory, &tables, plugin.action_api.keymaps_table_name) };
    try declareDefaultKeymaps(arena.allocator(), &atoms, keymap_rows.sink());
    const stage_keymap = try stage.buildKeymap(arena.allocator(), &atoms);
    keymap_rows.sink().declare(stage_keymap);

    const bindings = tables.findByName(Atom.from(plugin.action_api.bindings_table_name)).?;
    for (expected) |key| {
        const id: plugin.action_api.ActionId = .{ atoms.intern(key.mode), atoms.intern(key.name) };
        const defined = for (keyed_actions) |def| {
            if (std.mem.eql(u8, def.name, key.name)) break true;
        } else false;
        try std.testing.expect(defined);
        const mode = if (major == plugin.action_api.no_mode) id[0] else major;
        plugin.action_api.requestModes(&tables, .{ .major = mode });
        try mesha_runtime.actions.route(&memory, &atoms, &tables);
        try mesha_runtime.actions.collectKeys(&memory, &atoms, &tables);
        const sequence = keybinds.parse(key.chord).?;
        const chord = sequence.chord();
        var rows = bindings.query(plugin.action_api.BoundView);
        const bound = while (rows.next()) |row| {
            const row_chord = row.view.keys.toChord(row.view.len.*) orelse continue;
            const row_id: plugin.action_api.ActionId = .{ row.view.mode.*, row.view.name.* };
            if (row_chord.eql(chord) and std.mem.eql(Atom, &row_id, &id)) break true;
        } else false;
        if (!bound) std.debug.print("not bound: {s} -> {s}.{s}\n", .{ key.chord, key.mode, key.name });
        try std.testing.expect(bound);
    }
}

test "vcs git status: the keys of vcs and vcs_git are bound while vcs-git has the focus" {
    // `vcs_git` is under `vcs`, under `global`: no key of `text` reaches it, so `C-g` gives up
    // the panel's commands rather than leaving a text editor.
    try expectKeysBound(modes.vcs_git, &.{
        .{ .chord = "n", .mode = "vcs", .name = "next" },
        .{ .chord = "C-n", .mode = "vcs", .name = "next" },
        .{ .chord = "p", .mode = "vcs", .name = "previous" },
        .{ .chord = "C-p", .mode = "vcs", .name = "previous" },
        .{ .chord = "M-n", .mode = "vcs", .name = "next_sibling" },
        .{ .chord = "M-p", .mode = "vcs", .name = "previous_sibling" },
        .{ .chord = "S-6", .mode = "vcs", .name = "parent" },
        .{ .chord = "M-S-comma", .mode = "vcs", .name = "first" },
        .{ .chord = "M-S-period", .mode = "vcs", .name = "last" },
        .{ .chord = "C-v", .mode = "vcs", .name = "page_down" },
        .{ .chord = "M-v", .mode = "vcs", .name = "page_up" },
        .{ .chord = "tab", .mode = "vcs", .name = "toggle" },
        .{ .chord = "S-tab", .mode = "vcs", .name = "toggle_all" },
        .{ .chord = "RET", .mode = "vcs", .name = "visit" },
        .{ .chord = "g", .mode = "vcs", .name = "refresh" },
        .{ .chord = "q", .mode = "vcs", .name = "quit" },
        .{ .chord = "S-4", .mode = "vcs", .name = "process_log" },
        .{ .chord = "C-g", .mode = "vcs", .name = "give_up" },
        .{ .chord = "S-slash", .mode = "vcs", .name = "menu" },
        .{ .chord = "s", .mode = "vcs_git", .name = "stage" },
        .{ .chord = "u", .mode = "vcs_git", .name = "unstage" },
        .{ .chord = "S-s", .mode = "vcs_git", .name = "stage_all" },
        .{ .chord = "S-u", .mode = "vcs_git", .name = "unstage_all" },
        .{ .chord = "k", .mode = "vcs_git", .name = "discard" },
        .{ .chord = "c", .mode = "vcs_git", .name = "commit" },
        .{ .chord = "l", .mode = "vcs_git", .name = "log" },
        .{ .chord = "b", .mode = "vcs_git", .name = "branch" },
        .{ .chord = "m", .mode = "vcs_git", .name = "merge" },
        .{ .chord = "S-p", .mode = "vcs_git", .name = "push" },
        .{ .chord = "S-f", .mode = "vcs_git", .name = "pull" },
        .{ .chord = "f", .mode = "vcs_git", .name = "fetch" },
        .{ .chord = "r", .mode = "vcs_git", .name = "rebase" },
        .{ .chord = "C-x g", .mode = "global", .name = "vcs_git_status" },
    });
}

test "vcs git rebase: the keys of vcs_rebase are bound in the rebase list, over vcs's" {
    // `p` is pick here, `C-p` moves up; `M-p` and `M-n` move the row; `q` leaves the list.
    try expectKeysBound(modes.vcs_rebase, &.{
        .{ .chord = "p", .mode = "vcs_rebase", .name = "pick" },
        .{ .chord = "r", .mode = "vcs_rebase", .name = "reword" },
        .{ .chord = "e", .mode = "vcs_rebase", .name = "edit" },
        .{ .chord = "s", .mode = "vcs_rebase", .name = "squash" },
        .{ .chord = "f", .mode = "vcs_rebase", .name = "fixup" },
        .{ .chord = "k", .mode = "vcs_rebase", .name = "drop" },
        .{ .chord = "M-p", .mode = "vcs_rebase", .name = "move_up" },
        .{ .chord = "M-n", .mode = "vcs_rebase", .name = "move_down" },
        .{ .chord = "C-c C-c", .mode = "vcs_rebase", .name = "begin" },
        .{ .chord = "C-c C-k", .mode = "vcs_rebase", .name = "leave" },
        .{ .chord = "q", .mode = "vcs_rebase", .name = "leave" },
        .{ .chord = "n", .mode = "vcs", .name = "next" },
        .{ .chord = "C-p", .mode = "vcs", .name = "previous" },
        .{ .chord = "RET", .mode = "vcs", .name = "visit" },
        .{ .chord = "S-slash", .mode = "vcs", .name = "menu" },
    });
}

test "vcs git log: the keys of vcs_log are bound in the log view, over vcs_git's" {
    // The log is a page: `vcs`'s moves move through it, `e` edits the query, and `g`, `q`, `l`,
    // `$` and `?` stay the panel's.
    try expectKeysBound(modes.vcs_log, &.{
        .{ .chord = "e", .mode = "vcs_log", .name = "edit_query" },
        .{ .chord = "n", .mode = "vcs", .name = "next" },
        .{ .chord = "C-n", .mode = "vcs", .name = "next" },
        .{ .chord = "p", .mode = "vcs", .name = "previous" },
        .{ .chord = "C-p", .mode = "vcs", .name = "previous" },
        .{ .chord = "C-v", .mode = "vcs", .name = "page_down" },
        .{ .chord = "M-v", .mode = "vcs", .name = "page_up" },
        .{ .chord = "M-S-comma", .mode = "vcs", .name = "first" },
        .{ .chord = "M-S-period", .mode = "vcs", .name = "last" },
        .{ .chord = "RET", .mode = "vcs", .name = "visit" },
        .{ .chord = "g", .mode = "vcs", .name = "refresh" },
        .{ .chord = "q", .mode = "vcs", .name = "quit" },
        .{ .chord = "l", .mode = "vcs_git", .name = "log" },
        .{ .chord = "c", .mode = "vcs_git", .name = "commit" },
    });
}

test "vcs git commit: the keys of vcs_message are bound in the message buffer, over buffer's" {
    try expectKeysBound(modes.vcs_message, &.{
        .{ .chord = "C-c C-c", .mode = "vcs_message", .name = "finish" },
        .{ .chord = "C-c C-k", .mode = "vcs_message", .name = "cancel" },
        .{ .chord = "C-x k", .mode = "vcs_message", .name = "cancel" },
        .{ .chord = "M-p", .mode = "vcs_message", .name = "previous_message" },
        .{ .chord = "M-n", .mode = "vcs_message", .name = "next_message" },
        .{ .chord = "C-x C-q", .mode = "buffer", .name = "toggle_read_only" },
    });
}

test "every default key of the editor is bound in the mode of its action" {
    try expectKeysBound(plugin.action_api.no_mode, &.{
        .{ .chord = "M-x", .mode = "global", .name = "action_palette_toggle" },
        .{ .chord = "C-x o", .mode = "global", .name = "select_window" },
        .{ .chord = "M-escape", .mode = "form", .name = "cancel" },
        .{ .chord = "C-p", .mode = "global", .name = "picker_toggle" },
        .{ .chord = "C-x 0", .mode = "global", .name = "window_close" },
        .{ .chord = "C-x C-f", .mode = "global", .name = "find_file" },
        .{ .chord = "C-x 1", .mode = "global", .name = "maximize_toggle" },
        .{ .chord = "C-tab", .mode = "global", .name = "focus_next_view" },
        .{ .chord = "f11", .mode = "global", .name = "maximize_toggle" },
        .{ .chord = "C-S-w", .mode = "global", .name = "window_close" },
        .{ .chord = "C-backslash", .mode = "global", .name = "inspector_add_widget" },
        .{ .chord = "C-x C-s", .mode = "table", .name = "save" },
        .{ .chord = "C-enter", .mode = "table", .name = "add" },
        .{ .chord = "C-S-k", .mode = "table", .name = "delete" },
        .{ .chord = "M-enter", .mode = "form", .name = "save" },
    });
}

test "every default key of the stage is bound in stage" {
    try expectKeysBound(plugin.action_api.no_mode, &.{
        .{ .chord = "q", .mode = "stage", .name = "quit" },
    });
}

test "every default key of the figure editor is bound in figure" {
    try expectKeysBound(plugin.action_api.no_mode, &.{
        .{ .chord = "v", .mode = "figure", .name = "tool_select" },
        .{ .chord = "h", .mode = "figure", .name = "tool_hand" },
        .{ .chord = "b", .mode = "figure", .name = "tool_bone" },
        .{ .chord = "k", .mode = "figure", .name = "tool_stick" },
        .{ .chord = "p", .mode = "figure", .name = "tool_pencil" },
        .{ .chord = "S-p", .mode = "figure", .name = "tool_pen" },
        .{ .chord = "r", .mode = "figure", .name = "tool_rect" },
        .{ .chord = "o", .mode = "figure", .name = "tool_ellipse" },
        .{ .chord = "l", .mode = "figure", .name = "tool_line" },
        .{ .chord = "y", .mode = "figure", .name = "tool_polygon" },
        .{ .chord = "j", .mode = "figure", .name = "tool_joint_fill" },
        .{ .chord = "g", .mode = "figure", .name = "tool_gradient" },
        .{ .chord = "i", .mode = "figure", .name = "tool_eyedropper" },
        .{ .chord = "S-i", .mode = "figure", .name = "tool_ik" },
        .{ .chord = "e", .mode = "figure", .name = "tool_eraser" },
        .{ .chord = "x", .mode = "figure", .name = "color_target_toggle" },
        .{ .chord = "C-/", .mode = "figure", .name = "undo" },
        .{ .chord = "C-z", .mode = "figure", .name = "undo" },
        .{ .chord = "C-x u", .mode = "figure", .name = "undo" },
        .{ .chord = "C-S-z", .mode = "figure", .name = "redo" },
        .{ .chord = "C-S-/", .mode = "figure", .name = "redo" },
        .{ .chord = "C-w", .mode = "figure", .name = "cut" },
        .{ .chord = "M-w", .mode = "figure", .name = "copy" },
        .{ .chord = "C-y", .mode = "figure", .name = "paste" },
        .{ .chord = "C-d", .mode = "figure", .name = "duplicate" },
        .{ .chord = "C-x h", .mode = "figure", .name = "select_all" },
        .{ .chord = "M-a", .mode = "figure", .name = "deselect" },
        .{ .chord = "page_down", .mode = "figure", .name = "select_next" },
        .{ .chord = "page_up", .mode = "figure", .name = "select_previous" },
        .{ .chord = "delete", .mode = "figure", .name = "delete_bone" },
        .{ .chord = "backspace", .mode = "figure", .name = "delete_bone" },
        .{ .chord = "C-delete", .mode = "figure", .name = "delete_branch" },
        .{ .chord = "C-c C-g", .mode = "figure", .name = "folder_group" },
        .{ .chord = "C-c C-u", .mode = "figure", .name = "folder_ungroup" },
        .{ .chord = "C-S-n", .mode = "figure", .name = "layer_add" },
        .{ .chord = "C-right_bracket", .mode = "figure", .name = "shape_forward" },
        .{ .chord = "C-left_bracket", .mode = "figure", .name = "shape_backward" },
        .{ .chord = "M-C-right_bracket", .mode = "figure", .name = "shape_front" },
        .{ .chord = "M-C-left_bracket", .mode = "figure", .name = "shape_back" },
        .{ .chord = "C-S-h", .mode = "figure", .name = "toggle_visible" },
        .{ .chord = "C-S-l", .mode = "figure", .name = "toggle_lock" },
        .{ .chord = "f2", .mode = "figure", .name = "rename" },
        .{ .chord = "m", .mode = "figure", .name = "mirror_branch" },
        .{ .chord = "left", .mode = "figure", .name = "nudge_left" },
        .{ .chord = "right", .mode = "figure", .name = "nudge_right" },
        .{ .chord = "up", .mode = "figure", .name = "nudge_up" },
        .{ .chord = "down", .mode = "figure", .name = "nudge_down" },
        .{ .chord = "S-left", .mode = "figure", .name = "nudge_left_large" },
        .{ .chord = "S-right", .mode = "figure", .name = "nudge_right_large" },
        .{ .chord = "S-up", .mode = "figure", .name = "nudge_up_large" },
        .{ .chord = "S-down", .mode = "figure", .name = "nudge_down_large" },
        .{ .chord = "enter", .mode = "figure", .name = "chain_finish" },
        .{ .chord = "escape", .mode = "figure", .name = "gesture_cancel" },
        .{ .chord = "C-g", .mode = "figure", .name = "gesture_cancel" },
        .{ .chord = "S-1", .mode = "figure", .name = "view_fit" },
        .{ .chord = "home", .mode = "figure", .name = "view_fit" },
        .{ .chord = "S-2", .mode = "figure", .name = "view_selection" },
        .{ .chord = "kp_decimal", .mode = "figure", .name = "view_selection" },
        .{ .chord = "C-0", .mode = "figure", .name = "view_reset" },
        .{ .chord = "C-equal", .mode = "figure", .name = "zoom_in" },
        .{ .chord = "C-minus", .mode = "figure", .name = "zoom_out" },
        .{ .chord = "C-apostrophe", .mode = "figure", .name = "toggle_grid" },
        .{ .chord = "C-semicolon", .mode = "figure", .name = "toggle_bones" },
        .{ .chord = "C-x C-s", .mode = "figure", .name = "save" },
        .{ .chord = "C-x C-w", .mode = "figure", .name = "save_as" },
        .{ .chord = "C-x k", .mode = "global", .name = "kill_buffer" },
        .{ .chord = "tab", .mode = "figure", .name = "focus_mode" },
        .{ .chord = "f6", .mode = "figure", .name = "key_panel_next" },
        .{ .chord = "1", .mode = "figure", .name = "mode_design" },
        .{ .chord = "comma", .mode = "figure", .name = "frame_previous" },
        .{ .chord = "period", .mode = "figure", .name = "frame_next" },
        .{ .chord = "insert", .mode = "figure", .name = "key_add" },
        .{ .chord = "S-f6", .mode = "figure", .name = "key_delete" },
        .{ .chord = "S-o", .mode = "figure", .name = "toggle_onion" },
        .{ .chord = "M-r", .mode = "figure", .name = "pose_reset" },
        .{ .chord = "2", .mode = "figure", .name = "mode_rig" },
        .{ .chord = "3", .mode = "figure", .name = "mode_animate" },
        .{ .chord = "w", .mode = "figure", .name = "mode_weight" },
    });
}

test "typing in a filter binds no key but global's" {
    var memory: memory_mod.Memory = undefined;
    memory.init(std.testing.allocator);
    defer memory.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&memory);
    defer atoms.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&memory, 64);
    defer tables.deinit();
    const scratch = try memory.tableScratchAllocator();
    try mesha_runtime.actions.ensure(scratch, &atoms, &tables);
    try plugin.Keymaps.ensure(scratch, &atoms, &tables, plugin.action_api.keymaps_table_name);
    try plugin.Actions.ensure(scratch, &atoms, &tables, plugin.action_api.subscribed_table_name);
    modes.registerAll(&tables);
    try mesha_runtime.actions.route(&memory, &atoms, &tables);
    const registry = tables.findByName(Atom.from(plugin.action_api.mode_registry_table)).?;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var keymap_rows: plugin.KeymapRows = .{ .keymaps = plugin.Keymaps.of(&memory, &tables, plugin.action_api.keymaps_table_name) };
    try declareDefaultKeymaps(arena.allocator(), &atoms, keymap_rows.sink());
    const filter_modes = modes.modesFor(modes.filter, .cua, registry);
    plugin.action_api.requestModes(&tables, filter_modes);
    try mesha_runtime.actions.route(&memory, &atoms, &tables);
    try mesha_runtime.actions.collectKeys(&memory, &atoms, &tables);

    // No `cua` over a filter, and of the keys typed in one, none is bound: they reach the field.
    try std.testing.expectEqual(@as(u8, 0), filter_modes.minor_count);
    const bindings = tables.findByName(Atom.from(plugin.action_api.bindings_table_name)).?;
    var rows = bindings.query(plugin.action_api.BoundView);
    var count: usize = 0;
    while (rows.next()) |row| : (count += 1) {
        try std.testing.expectEqual(plugin.action_api.global_mode, row.view.keymap.*);
        const chord = row.view.keys.toChord(row.view.len.*).?;
        const first = chord.tokens[0];
        const typed = !first.control and !first.alt and !first.super_key;
        const typed_key = switch (first.key) {
            .backspace, .delete, .left, .right, .up, .down, .enter, .kp_enter, .tab, .home, .end, .escape => true,
            else => false,
        };
        try std.testing.expect(!(typed and typed_key));
    }
    try std.testing.expect(count > 0);
}

test "every Emacs key of the text editor is bound in a text panel" {
    try expectKeysBound(modes.buffer, &.{
        .{ .chord = "C-f", .mode = "text", .name = "char_right" },
        .{ .chord = "right", .mode = "text", .name = "char_right" },
        .{ .chord = "S-right", .mode = "text", .name = "char_right_extend" },
        .{ .chord = "C-b", .mode = "text", .name = "char_left" },
        .{ .chord = "left", .mode = "text", .name = "char_left" },
        .{ .chord = "S-left", .mode = "text", .name = "char_left_extend" },
        .{ .chord = "M-f", .mode = "text", .name = "forward_word" },
        .{ .chord = "C-right", .mode = "text", .name = "forward_word" },
        .{ .chord = "C-S-right", .mode = "text", .name = "forward_word_extend" },
        .{ .chord = "M-b", .mode = "text", .name = "backward_word" },
        .{ .chord = "C-left", .mode = "text", .name = "backward_word" },
        .{ .chord = "C-S-left", .mode = "text", .name = "backward_word_extend" },
        .{ .chord = "C-n", .mode = "text", .name = "line_down" },
        .{ .chord = "down", .mode = "text", .name = "line_down" },
        .{ .chord = "S-down", .mode = "text", .name = "line_down_extend" },
        .{ .chord = "C-p", .mode = "text", .name = "line_up" },
        .{ .chord = "up", .mode = "text", .name = "line_up" },
        .{ .chord = "S-up", .mode = "text", .name = "line_up_extend" },
        .{ .chord = "C-a", .mode = "text", .name = "line_begin" },
        .{ .chord = "home", .mode = "text", .name = "line_begin" },
        .{ .chord = "S-home", .mode = "text", .name = "line_begin_extend" },
        .{ .chord = "C-e", .mode = "text", .name = "line_end" },
        .{ .chord = "end", .mode = "text", .name = "line_end" },
        .{ .chord = "S-end", .mode = "text", .name = "line_end_extend" },
        .{ .chord = "C-v", .mode = "text", .name = "scroll_page_down" },
        .{ .chord = "page_down", .mode = "text", .name = "scroll_page_down" },
        .{ .chord = "S-page_down", .mode = "text", .name = "page_down_extend" },
        .{ .chord = "M-v", .mode = "text", .name = "scroll_page_up" },
        .{ .chord = "page_up", .mode = "text", .name = "scroll_page_up" },
        .{ .chord = "S-page_up", .mode = "text", .name = "page_up_extend" },
        .{ .chord = "M-S-comma", .mode = "text", .name = "document_start" },
        .{ .chord = "C-home", .mode = "text", .name = "document_start" },
        .{ .chord = "C-S-home", .mode = "text", .name = "document_start_extend" },
        .{ .chord = "M-S-period", .mode = "text", .name = "document_end" },
        .{ .chord = "C-end", .mode = "text", .name = "document_end" },
        .{ .chord = "C-S-end", .mode = "text", .name = "document_end_extend" },
        .{ .chord = "C-l", .mode = "text", .name = "recenter" },
        .{ .chord = "C-up", .mode = "text", .name = "paragraph_back" },
        .{ .chord = "C-down", .mode = "text", .name = "paragraph_forward" },
        .{ .chord = "backspace", .mode = "text", .name = "delete_back" },
        .{ .chord = "S-backspace", .mode = "text", .name = "delete_back" },
        .{ .chord = "C-d", .mode = "text", .name = "delete_forward" },
        .{ .chord = "delete", .mode = "text", .name = "delete_forward" },
        .{ .chord = "M-d", .mode = "text", .name = "kill_word_forward" },
        .{ .chord = "C-delete", .mode = "text", .name = "kill_word_forward" },
        .{ .chord = "M-backspace", .mode = "text", .name = "kill_word_back" },
        .{ .chord = "C-backspace", .mode = "text", .name = "kill_word_back" },
        .{ .chord = "C-k", .mode = "text", .name = "kill_line" },
        .{ .chord = "C-S-backspace", .mode = "text", .name = "kill_whole_line" },
        .{ .chord = "C-SPC", .mode = "text", .name = "set_mark" },
        .{ .chord = "C-x C-x", .mode = "text", .name = "exchange_point_and_mark" },
        .{ .chord = "C-x h", .mode = "text", .name = "select_all" },
        .{ .chord = "C-w", .mode = "text", .name = "kill_region" },
        .{ .chord = "M-w", .mode = "text", .name = "copy_region" },
        .{ .chord = "C-y", .mode = "text", .name = "yank" },
        .{ .chord = "M-y", .mode = "text", .name = "yank_pop" },
        .{ .chord = "C-/", .mode = "text", .name = "undo" },
        .{ .chord = "C-z", .mode = "text", .name = "undo" },
        .{ .chord = "C-x u", .mode = "text", .name = "undo" },
        .{ .chord = "C-S-z", .mode = "text", .name = "redo" },
        .{ .chord = "enter", .mode = "text", .name = "new_line" },
        .{ .chord = "kp_enter", .mode = "text", .name = "new_line" },
        .{ .chord = "C-j", .mode = "text", .name = "new_line" },
        .{ .chord = "S-tab", .mode = "text", .name = "unindent" },
        .{ .chord = "M-j", .mode = "text", .name = "new_line" },
        .{ .chord = "M-up", .mode = "text", .name = "move_lines_up" },
        .{ .chord = "M-down", .mode = "text", .name = "move_lines_down" },
        .{ .chord = "insert", .mode = "text", .name = "toggle_overtype" },
        .{ .chord = "C-x C-s", .mode = "text", .name = "save" },
        .{ .chord = "C-g", .mode = "text", .name = "leave" },
        .{ .chord = "escape", .mode = "text", .name = "leave" },
        .{ .chord = "M-z", .mode = "buffer", .name = "zap_to_char" },
        .{ .chord = "M-g g", .mode = "buffer", .name = "goto_line" },
        .{ .chord = "M-g M-g", .mode = "buffer", .name = "goto_line" },
        .{ .chord = "C-x C-w", .mode = "buffer", .name = "save_as" },
        .{ .chord = "C-x k", .mode = "global", .name = "kill_buffer" },
        .{ .chord = "C-x C-f", .mode = "global", .name = "find_file" },
        .{ .chord = "C-x b", .mode = "global", .name = "switch_buffer" },
        .{ .chord = "M-period", .mode = "buffer", .name = "goto_definition" },
        .{ .chord = "M-comma", .mode = "buffer", .name = "go_back" },
        .{ .chord = "C-h period", .mode = "buffer", .name = "describe" },
        .{ .chord = "M-S-f", .mode = "text", .name = "forward_word_extend" },
        .{ .chord = "M-S-b", .mode = "text", .name = "backward_word_extend" },
        .{ .chord = "M-m", .mode = "text", .name = "back_to_indentation" },
        .{ .chord = "M-S-left_bracket", .mode = "text", .name = "paragraph_back" },
        .{ .chord = "M-S-right_bracket", .mode = "text", .name = "paragraph_forward" },
        .{ .chord = "C-o", .mode = "text", .name = "open_line" },
        .{ .chord = "C-t", .mode = "text", .name = "transpose_chars" },
        .{ .chord = "M-u", .mode = "text", .name = "upcase_word" },
        .{ .chord = "M-l", .mode = "text", .name = "downcase_word" },
        .{ .chord = "M-c", .mode = "text", .name = "capitalize_word" },
        .{ .chord = "M-backslash", .mode = "text", .name = "delete_horizontal_space" },
        .{ .chord = "M-SPC", .mode = "text", .name = "just_one_space" },
        .{ .chord = "M-S-6", .mode = "text", .name = "join_previous_line" },
        .{ .chord = "C-S-minus", .mode = "text", .name = "undo" },
        .{ .chord = "C-S-/", .mode = "text", .name = "redo" },
        .{ .chord = "C-M-S-minus", .mode = "text", .name = "redo" },
        .{ .chord = "C-x C-b", .mode = "global", .name = "switch_buffer" },
        .{ .chord = "C-x RET f", .mode = "buffer", .name = "set_encoding" },
        .{ .chord = "C-x RET r", .mode = "buffer", .name = "revert_with_encoding" },
        .{ .chord = "C-u", .mode = "buffer", .name = "universal_argument" },
        .{ .chord = "M-0", .mode = "buffer", .name = "digit_argument_0" },
        .{ .chord = "M-1", .mode = "buffer", .name = "digit_argument_1" },
        .{ .chord = "M-2", .mode = "buffer", .name = "digit_argument_2" },
        .{ .chord = "M-3", .mode = "buffer", .name = "digit_argument_3" },
        .{ .chord = "M-4", .mode = "buffer", .name = "digit_argument_4" },
        .{ .chord = "M-5", .mode = "buffer", .name = "digit_argument_5" },
        .{ .chord = "M-6", .mode = "buffer", .name = "digit_argument_6" },
        .{ .chord = "M-7", .mode = "buffer", .name = "digit_argument_7" },
        .{ .chord = "M-8", .mode = "buffer", .name = "digit_argument_8" },
        .{ .chord = "M-9", .mode = "buffer", .name = "digit_argument_9" },
        .{ .chord = "M-semicolon", .mode = "text", .name = "comment_dwim" },
        .{ .chord = "C-x C-semicolon", .mode = "text", .name = "comment_line" },
        .{ .chord = "M-q", .mode = "text", .name = "fill_paragraph" },
        .{ .chord = "C-x C-o", .mode = "text", .name = "delete_blank_lines" },
        .{ .chord = "M-t", .mode = "text", .name = "transpose_words" },
        .{ .chord = "C-x C-t", .mode = "text", .name = "transpose_lines" },
        .{ .chord = "C-M-f", .mode = "text", .name = "forward_sexp" },
        .{ .chord = "C-M-b", .mode = "text", .name = "backward_sexp" },
        .{ .chord = "C-M-k", .mode = "text", .name = "kill_sexp" },
        .{ .chord = "C-M-SPC", .mode = "text", .name = "mark_sexp" },
        .{ .chord = "C-x C-q", .mode = "buffer", .name = "toggle_read_only" },
        .{ .chord = "C-s", .mode = "buffer", .name = "isearch_forward" },
        .{ .chord = "C-r", .mode = "buffer", .name = "isearch_backward" },
        .{ .chord = "M-s l", .mode = "buffer", .name = "search_lines" },
        .{ .chord = "M-S-5", .mode = "buffer", .name = "query_replace" },
        .{ .chord = "C-x 2", .mode = "buffer", .name = "split_below" },
        .{ .chord = "C-x 3", .mode = "buffer", .name = "split_right" },
        .{ .chord = "C-x 4 b", .mode = "buffer", .name = "switch_buffer_other_window" },
        .{ .chord = "C-x 4 f", .mode = "buffer", .name = "find_file_other_window" },
        .{ .chord = "C-x 4 C-f", .mode = "buffer", .name = "find_file_other_window" },
        .{ .chord = "M-s r", .mode = "global", .name = "grep" },
        .{ .chord = "M-s f", .mode = "global", .name = "find_project_file" },
        .{ .chord = "C-x p f", .mode = "global", .name = "find_project_file" },
        .{ .chord = "C-x p c", .mode = "global", .name = "compile" },
        .{ .chord = "M-g n", .mode = "global", .name = "next_error" },
        .{ .chord = "M-g p", .mode = "global", .name = "previous_error" },
        .{ .chord = "M-g M-n", .mode = "global", .name = "next_error" },
        .{ .chord = "M-g M-p", .mode = "global", .name = "previous_error" },
        .{ .chord = "tab", .mode = "buffer", .name = "complete_or_indent" },
        .{ .chord = "C-M-i", .mode = "buffer", .name = "complete" },
        .{ .chord = "M-g i", .mode = "buffer", .name = "goto_symbol" },
        .{ .chord = "C-x r k", .mode = "text", .name = "kill_rectangle" },
        .{ .chord = "C-x r d", .mode = "text", .name = "delete_rectangle" },
        .{ .chord = "C-x r y", .mode = "text", .name = "yank_rectangle" },
        .{ .chord = "C-x r o", .mode = "text", .name = "open_rectangle" },
        .{ .chord = "C-x r t", .mode = "buffer", .name = "string_rectangle" },
        .{ .chord = "C-x r s", .mode = "buffer", .name = "copy_to_register" },
        .{ .chord = "C-x r i", .mode = "buffer", .name = "insert_register" },
        .{ .chord = "C-x r SPC", .mode = "buffer", .name = "point_to_register" },
        .{ .chord = "C-x r j", .mode = "buffer", .name = "jump_to_register" },
        .{ .chord = "f3", .mode = "buffer", .name = "macro_start" },
        .{ .chord = "f4", .mode = "buffer", .name = "macro_end_or_call" },
        .{ .chord = "C-x S-9", .mode = "buffer", .name = "macro_start" },
        .{ .chord = "C-x S-0", .mode = "buffer", .name = "macro_end" },
        .{ .chord = "C-x e", .mode = "buffer", .name = "macro_call" },
    });
}

test "every default key of the search is bound in isearch" {
    try expectKeysBound(plugin.action_api.no_mode, &.{
        .{ .chord = "C-s", .mode = "isearch", .name = "forward" },
        .{ .chord = "C-r", .mode = "isearch", .name = "backward" },
        .{ .chord = "C-w", .mode = "isearch", .name = "yank_word" },
    });
}

test "every default key of the prompt is bound in prompt" {
    try expectKeysBound(plugin.action_api.no_mode, &.{
        .{ .chord = "enter", .mode = "prompt", .name = "submit" },
        .{ .chord = "kp_enter", .mode = "prompt", .name = "submit" },
        .{ .chord = "escape", .mode = "prompt", .name = "cancel" },
        .{ .chord = "down", .mode = "prompt", .name = "next" },
        .{ .chord = "up", .mode = "prompt", .name = "previous" },
        .{ .chord = "C-n", .mode = "prompt", .name = "next" },
        .{ .chord = "C-p", .mode = "prompt", .name = "previous" },
        .{ .chord = "tab", .mode = "prompt", .name = "complete" },
        .{ .chord = "S-tab", .mode = "prompt", .name = "previous" },
        .{ .chord = "page_down", .mode = "prompt", .name = "page_down" },
        .{ .chord = "page_up", .mode = "prompt", .name = "page_up" },
    });
}

test "every default key of the cell is bound in table_cell" {
    try expectKeysBound(plugin.action_api.no_mode, &.{
        .{ .chord = "enter", .mode = "table_cell", .name = "commit_down" },
        .{ .chord = "kp_enter", .mode = "table_cell", .name = "commit_down" },
        .{ .chord = "S-enter", .mode = "table_cell", .name = "commit_up" },
        .{ .chord = "tab", .mode = "table_cell", .name = "commit_next" },
        .{ .chord = "S-tab", .mode = "table_cell", .name = "commit_previous" },
        .{ .chord = "escape", .mode = "table_cell", .name = "cancel" },
    });
}

test "every default key of the form is bound in form" {
    try expectKeysBound(plugin.action_api.no_mode, &.{
        .{ .chord = "tab", .mode = "form", .name = "next" },
        .{ .chord = "enter", .mode = "form", .name = "submit" },
        .{ .chord = "kp_enter", .mode = "form", .name = "submit" },
        .{ .chord = "escape", .mode = "form", .name = "close" },
    });
}

/// The keys of a browsed table window, as the design's Org table and the task's list of the
/// table's keys have them, with the command modifier's for this OS.
const table_window_keys = [_]ExpectedKey{
    .{ .chord = "tab", .mode = "table", .name = "next_cell" },
    .{ .chord = "S-tab", .mode = "table", .name = "previous_cell" },
    .{ .chord = "enter", .mode = "table", .name = "next_row" },
    .{ .chord = "kp_enter", .mode = "table", .name = "next_row" },
    .{ .chord = "down", .mode = "table", .name = "next_row" },
    .{ .chord = "C-n", .mode = "table", .name = "next_row" },
    .{ .chord = "up", .mode = "table", .name = "previous_row" },
    .{ .chord = "C-p", .mode = "table", .name = "previous_row" },
    .{ .chord = "left", .mode = "table", .name = "previous_column" },
    .{ .chord = "C-b", .mode = "table", .name = "previous_column" },
    .{ .chord = "right", .mode = "table", .name = "next_column" },
    .{ .chord = "C-f", .mode = "table", .name = "next_column" },
    .{ .chord = "home", .mode = "table", .name = "row_start" },
    .{ .chord = "end", .mode = "table", .name = "row_end" },
    .{ .chord = "page_up", .mode = "table", .name = "page_up" },
    .{ .chord = "page_down", .mode = "table", .name = "page_down" },
    .{ .chord = "M-S-comma", .mode = "table", .name = "first_cell" },
    .{ .chord = "M-S-period", .mode = "table", .name = "last_cell" },
    .{ .chord = "C-c grave_accent", .mode = "table", .name = "edit_cell" },
    .{ .chord = "C-c SPC", .mode = "table", .name = "clear_cell" },
    .{ .chord = "C-c S-6", .mode = "table", .name = "sort_column" },
    .{ .chord = "C-c C-c", .mode = "table", .name = "toggle" },
    .{ .chord = "SPC", .mode = "table", .name = "toggle" },
    .{ .chord = "M-w", .mode = "table", .name = "copy" },
    .{ .chord = "C-y", .mode = "table", .name = "paste" },
    .{ .chord = "M-S-down", .mode = "table", .name = "row_add" },
    .{ .chord = "M-S-up", .mode = "table", .name = "row_delete" },
    .{ .chord = "C-x C-s", .mode = "table", .name = "save" },
    .{ .chord = "C-enter", .mode = "table", .name = "add" },
    .{ .chord = "C-S-k", .mode = "table", .name = "delete" },
} ++ if (builtin.os.tag == .macos) [_]ExpectedKey{
    .{ .chord = "s-c", .mode = "table", .name = "copy" },
    .{ .chord = "s-v", .mode = "table", .name = "paste" },
    .{ .chord = "s-home", .mode = "table", .name = "first_cell" },
    .{ .chord = "s-end", .mode = "table", .name = "last_cell" },
} else [_]ExpectedKey{
    .{ .chord = "C-v", .mode = "table", .name = "paste" },
    .{ .chord = "C-home", .mode = "table", .name = "first_cell" },
    .{ .chord = "C-end", .mode = "table", .name = "last_cell" },
};

test "every key of a browsed table window is bound in table" {
    try expectKeysBound(modes.table, &table_window_keys);
}

test "a cell's Org keys are bound in table_cell" {
    try expectKeysBound(modes.table_cell, &.{
        .{ .chord = "M-a", .mode = "text", .name = "line_begin" },
        .{ .chord = "M-e", .mode = "text", .name = "line_end" },
        .{ .chord = "C-c SPC", .mode = "table_cell", .name = "clear" },
        .{ .chord = "C-g", .mode = "table_cell", .name = "cancel" },
    });
}

test "a mode a plugin registers under buffer has cua over it, as the editor's text modes do" {
    var resolved: ResolvedKeys = .{};
    try resolved.setUp();
    defer resolved.deinit();
    const zig_mode = resolved.atoms.intern("zig");
    plugin.action_api.registerMode(&resolved.tables, zig_mode, modes.buffer);
    try mesha_runtime.actions.route(&resolved.memory, &resolved.atoms, &resolved.tables);
    const registry = resolved.tables.findByName(Atom.from(plugin.action_api.mode_registry_table)).?;
    const zig_modes = modes.modesFor(zig_mode, .cua, registry);
    try std.testing.expectEqualSlices(Atom, &.{modes.cua}, zig_modes.minorSlice());
    const filter_modes = modes.modesFor(modes.filter, .cua, registry);
    try std.testing.expectEqual(@as(u8, 0), filter_modes.minor_count);
}

test "in a figure panel with Emacs's keys, figure's keys hide none of global's chords" {
    var global: ResolvedKeys = .{};
    try global.init(.{});
    defer global.deinit();
    var figure: ResolvedKeys = .{};
    try figure.init(.{ .major = modes.figure });
    defer figure.deinit();

    var hidden_buffer: [512]u8 = undefined;
    var hidden = std.Io.Writer.fixed(&hidden_buffer);
    const bindings = global.tables.findByName(Atom.from(plugin.action_api.bindings_table_name)).?;
    var rows = bindings.query(plugin.action_api.BoundView);
    while (rows.next()) |row| {
        const chord = row.view.keys.toChord(row.view.len.*).?;
        var chord_buffer: [64]u8 = undefined;
        const chord_text = formatChordText(&chord_buffer, chord);
        const in_global: plugin.action_api.ActionId = .{ row.view.mode.*, row.view.name.* };
        const in_figure = figure.boundTo(chord_text);
        const kept = if (in_figure) |id| std.mem.eql(Atom, &id, &in_global) else false;
        if (!kept) try hidden.print("{s}\n", .{chord_text});
    }
    // `figure`'s modifier keys are Emacs's editing keys and its own `C-c` chords.
    try std.testing.expectEqualStrings("", hidden.buffered());
}

/// `chord` as Emacs writes it, keys apart by spaces, in `buffer`.
fn formatChordText(buffer: []u8, chord: plugin.action_api.Chord) []const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    for (chord.slice(), 0..) |token, index| {
        if (index != 0) writer.writeByte(' ') catch break;
        var token_buffer: [32]u8 = undefined;
        const token_text = plugin.action_api.formatToken(&token_buffer, token);
        writer.writeAll(token_text) catch break;
    }
    return writer.buffered();
}

test "a figure panel answers the text editor's keys: Emacs's, with global's C-x chords, or the common ones" {
    var emacs: ResolvedKeys = .{};
    try emacs.initFor(modes.figure, .emacs);
    defer emacs.deinit();
    for ([_]ExpectedKey{
        .{ .chord = "C-x 0", .mode = "global", .name = "window_close" },
        .{ .chord = "C-x b", .mode = "global", .name = "switch_buffer" },
        .{ .chord = "C-x C-f", .mode = "global", .name = "find_file" },
        .{ .chord = "C-w", .mode = "figure", .name = "cut" },
        .{ .chord = "M-w", .mode = "figure", .name = "copy" },
        .{ .chord = "C-y", .mode = "figure", .name = "paste" },
        .{ .chord = "C-/", .mode = "figure", .name = "undo" },
        .{ .chord = "C-x u", .mode = "figure", .name = "undo" },
        .{ .chord = "C-g", .mode = "figure", .name = "gesture_cancel" },
        .{ .chord = "C-x C-s", .mode = "figure", .name = "save" },
    }) |key| try emacs.expectBound(key);
    // `C-c` is the figure's own prefix, as it is a mode's in Emacs.
    try std.testing.expect(emacs.boundTo("C-c") == null);
    const emacs_warned = emacs.tables.findByName(Atom.from(plugin.action_api.warned_table_name)).?;
    try std.testing.expectEqual(@as(usize, 0), emacs_warned.count());

    var cua: ResolvedKeys = .{};
    try cua.initFor(modes.figure, .cua);
    defer cua.deinit();
    for ([_]ExpectedKey{
        .{ .chord = "C-c", .mode = "figure", .name = "copy" },
        .{ .chord = "C-x", .mode = "figure", .name = "cut" },
        .{ .chord = "C-v", .mode = "figure", .name = "paste" },
        .{ .chord = "C-z", .mode = "figure", .name = "undo" },
        .{ .chord = "C-y", .mode = "figure", .name = "redo" },
        .{ .chord = "C-a", .mode = "figure", .name = "select_all" },
        .{ .chord = "C-g", .mode = "figure", .name = "folder_group" },
        .{ .chord = "C-s", .mode = "figure", .name = "save" },
        .{ .chord = "C-S-w", .mode = "global", .name = "window_close" },
    }) |key| try cua.expectBound(key);
    // As in a text panel with the common keys, `C-x` is cut, which hides `global`'s chords
    // that begin with it, and Emacs's editing keys are unbound.
    for ([_][]const u8{ "C-x 0", "C-w", "M-w", "C-/", "C-c C-g" }) |chord| {
        if (cua.boundTo(chord)) |bound| std.debug.print("bound: {s} -> {s}\n", .{ chord, cua.atoms.lookup(bound[1]) orelse "?" });
        try std.testing.expect(cua.boundTo(chord) == null);
    }
    const cua_warned = cua.tables.findByName(Atom.from(plugin.action_api.warned_table_name)).?;
    try std.testing.expectEqual(@as(usize, 0), cua_warned.count());
}

test "in a browsed table Org's C-c chords are bound and C-c alone is not" {
    var resolved: ResolvedKeys = .{};
    try resolved.init(.{ .major = modes.table });
    defer resolved.deinit();
    try resolved.expectBound(.{ .chord = "C-c SPC", .mode = "table", .name = "clear_cell" });
    try resolved.expectBound(.{ .chord = "C-c C-c", .mode = "table", .name = "toggle" });
    try std.testing.expect(resolved.boundTo("C-c") == null);
    // No two of the keymap's own keys overlap.
    const warned = resolved.tables.findByName(Atom.from(plugin.action_api.warned_table_name)).?;
    try std.testing.expectEqual(@as(usize, 0), warned.count());
}

/// Declares the editor's default keymaps to `sink`, as its subscriptions system does each frame,
/// built in `allocator`, which must outlive the declaration.
fn declareDefaultKeymaps(allocator: std.mem.Allocator, atoms: *Atom.Registry, sink: plugin.KeymapSink) !void {
    const built = try lib.buildKeymaps(allocator, atoms);
    for (built) |keymap| sink.declare(keymap);
}

/// The editor's keymaps resolved for one set of modes: the editor's modes registered, its keymaps
/// declared, and `actions_bindings` as the actions system writes it for `modes`.
const ResolvedKeys = struct {
    memory: memory_mod.Memory = undefined,
    atoms: Atom.Registry = undefined,
    tables: Table.Registry = undefined,

    fn init(self: *ResolvedKeys, wanted_modes: plugin.action_api.Modes) !void {
        try self.setUp();
        try self.resolve(wanted_modes);
    }

    /// `init` with the modes a panel of `major` has while the text editors answer `keymap`
    /// (`modes.modesFor`), by the modes the editor registered.
    fn initFor(self: *ResolvedKeys, major: Atom, keymap: text_editor.Keymap) !void {
        try self.setUp();
        const registry = self.tables.findByName(Atom.from(plugin.action_api.mode_registry_table)).?;
        const wanted_modes = modes.modesFor(major, keymap, registry);
        try self.resolve(wanted_modes);
    }

    /// The tables, the editor's modes registered and its keymaps declared.
    fn setUp(self: *ResolvedKeys) !void {
        self.memory.init(std.testing.allocator);
        errdefer self.memory.deinit();
        try self.atoms.init(&self.memory);
        errdefer self.atoms.deinit();
        try self.tables.init(&self.memory, 64);
        errdefer self.tables.deinit();
        const scratch = try self.memory.tableScratchAllocator();
        try mesha_runtime.actions.ensure(scratch, &self.atoms, &self.tables);
        try plugin.Keymaps.ensure(scratch, &self.atoms, &self.tables, plugin.action_api.keymaps_table_name);
        try plugin.Actions.ensure(scratch, &self.atoms, &self.tables, plugin.action_api.subscribed_table_name);
        modes.registerAll(&self.tables);
        try mesha_runtime.actions.route(&self.memory, &self.atoms, &self.tables);
        var keymap_rows: plugin.KeymapRows = .{ .keymaps = plugin.Keymaps.of(&self.memory, &self.tables, plugin.action_api.keymaps_table_name) };
        var keymap_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer keymap_arena.deinit();
        try declareDefaultKeymaps(keymap_arena.allocator(), &self.atoms, keymap_rows.sink());
    }

    /// `actions_bindings` as the actions system writes it for `modes`.
    fn resolve(self: *ResolvedKeys, wanted_modes: plugin.action_api.Modes) !void {
        plugin.action_api.requestModes(&self.tables, wanted_modes);
        try mesha_runtime.actions.route(&self.memory, &self.atoms, &self.tables);
        try mesha_runtime.actions.collectKeys(&self.memory, &self.atoms, &self.tables);
    }

    fn deinit(self: *ResolvedKeys) void {
        self.tables.deinit();
        self.atoms.deinit();
        self.memory.deinit();
    }

    /// The action `chord` is bound to, or null when it is bound to none.
    fn boundTo(self: *ResolvedKeys, chord_text: []const u8) ?plugin.action_api.ActionId {
        const sequence = keybinds.parse(chord_text).?;
        const chord = sequence.chord();
        const bindings = self.tables.findByName(Atom.from(plugin.action_api.bindings_table_name)).?;
        var rows = bindings.query(plugin.action_api.BoundView);
        while (rows.next()) |row| {
            const row_chord = row.view.keys.toChord(row.view.len.*) orelse continue;
            if (row_chord.eql(chord)) return .{ row.view.mode.*, row.view.name.* };
        }
        return null;
    }

    /// Expects `key`'s chord bound to its action and to no other.
    fn expectBound(self: *ResolvedKeys, key: ExpectedKey) !void {
        const expected: plugin.action_api.ActionId = .{ self.atoms.intern(key.mode), self.atoms.intern(key.name) };
        const bound = self.boundTo(key.chord);
        const matches = if (bound) |id| std.mem.eql(Atom, &id, &expected) else false;
        if (!matches) std.debug.print("not bound: {s} -> {s}.{s}\n", .{ key.chord, key.mode, key.name });
        try std.testing.expect(matches);
    }
};

/// Whether `chord_text` is among the chords of `keys`, compared as parsed.
fn hasChord(keys: []const ExpectedKey, chord_text: []const u8) bool {
    const chord = keybinds.parse(chord_text).?;
    for (keys) |key| {
        const candidate = keybinds.parse(key.chord).?;
        if (candidate.eql(chord)) return true;
    }
    return false;
}

/// The common keys: every key a text panel has while the setting chooses them.
const common_keys = [_]ExpectedKey{
    .{ .chord = "left", .mode = "text", .name = "char_left" },
    .{ .chord = "S-left", .mode = "text", .name = "char_left_extend" },
    .{ .chord = "right", .mode = "text", .name = "char_right" },
    .{ .chord = "S-right", .mode = "text", .name = "char_right_extend" },
    .{ .chord = "C-left", .mode = "text", .name = "word_left" },
    .{ .chord = "C-S-left", .mode = "text", .name = "word_left_extend" },
    .{ .chord = "C-right", .mode = "text", .name = "word_right" },
    .{ .chord = "C-S-right", .mode = "text", .name = "word_right_extend" },
    .{ .chord = "up", .mode = "text", .name = "line_up" },
    .{ .chord = "S-up", .mode = "text", .name = "line_up_extend" },
    .{ .chord = "down", .mode = "text", .name = "line_down" },
    .{ .chord = "S-down", .mode = "text", .name = "line_down_extend" },
    .{ .chord = "home", .mode = "text", .name = "line_start" },
    .{ .chord = "S-home", .mode = "text", .name = "line_start_extend" },
    .{ .chord = "end", .mode = "text", .name = "line_end" },
    .{ .chord = "S-end", .mode = "text", .name = "line_end_extend" },
    .{ .chord = "page_up", .mode = "text", .name = "page_up" },
    .{ .chord = "S-page_up", .mode = "text", .name = "page_up_extend" },
    .{ .chord = "page_down", .mode = "text", .name = "page_down" },
    .{ .chord = "S-page_down", .mode = "text", .name = "page_down_extend" },
    .{ .chord = "C-home", .mode = "text", .name = "document_start" },
    .{ .chord = "C-S-home", .mode = "text", .name = "document_start_extend" },
    .{ .chord = "C-end", .mode = "text", .name = "document_end" },
    .{ .chord = "C-S-end", .mode = "text", .name = "document_end_extend" },
    .{ .chord = "C-up", .mode = "text", .name = "scroll_up" },
    .{ .chord = "C-down", .mode = "text", .name = "scroll_down" },
    .{ .chord = "backspace", .mode = "text", .name = "delete_back" },
    .{ .chord = "S-backspace", .mode = "text", .name = "delete_back" },
    .{ .chord = "delete", .mode = "text", .name = "delete_forward" },
    .{ .chord = "C-backspace", .mode = "text", .name = "delete_word_back" },
    .{ .chord = "C-delete", .mode = "text", .name = "delete_word_forward" },
    .{ .chord = "C-S-backspace", .mode = "text", .name = "delete_line_back" },
    .{ .chord = "C-S-delete", .mode = "text", .name = "delete_line_forward" },
    .{ .chord = "C-S-k", .mode = "text", .name = "delete_line" },
    .{ .chord = "C-d", .mode = "text", .name = "duplicate_line" },
    .{ .chord = "M-up", .mode = "text", .name = "move_lines_up" },
    .{ .chord = "M-down", .mode = "text", .name = "move_lines_down" },
    .{ .chord = "enter", .mode = "text", .name = "new_line" },
    .{ .chord = "kp_enter", .mode = "text", .name = "new_line" },
    .{ .chord = "tab", .mode = "text", .name = "indent" },
    .{ .chord = "S-tab", .mode = "text", .name = "unindent" },
    .{ .chord = "C-z", .mode = "text", .name = "undo" },
    .{ .chord = "C-y", .mode = "text", .name = "redo" },
    .{ .chord = "C-S-z", .mode = "text", .name = "redo" },
    .{ .chord = "C-x", .mode = "text", .name = "cut" },
    .{ .chord = "S-delete", .mode = "text", .name = "cut" },
    .{ .chord = "C-c", .mode = "text", .name = "copy" },
    .{ .chord = "C-insert", .mode = "text", .name = "copy" },
    .{ .chord = "C-v", .mode = "text", .name = "paste" },
    .{ .chord = "S-insert", .mode = "text", .name = "paste" },
    .{ .chord = "C-a", .mode = "text", .name = "select_all" },
    .{ .chord = "insert", .mode = "text", .name = "toggle_overtype" },
    .{ .chord = "C-s", .mode = "text", .name = "save" },
    .{ .chord = "escape", .mode = "text", .name = "leave" },
    .{ .chord = "C-g", .mode = "buffer", .name = "goto_line" },
    .{ .chord = "C-f", .mode = "buffer", .name = "search_lines" },
    .{ .chord = "C-S-s", .mode = "buffer", .name = "save_as" },
    .{ .chord = "f12", .mode = "buffer", .name = "goto_definition" },
    .{ .chord = "M-left", .mode = "buffer", .name = "go_back" },
    .{ .chord = "C-k C-i", .mode = "buffer", .name = "describe" },
    .{ .chord = "f8", .mode = "buffer", .name = "next_diagnostic" },
    .{ .chord = "S-f8", .mode = "buffer", .name = "previous_diagnostic" },
};

/// The chords the field modes bind for themselves, which `cua` leaves to Emacs's keys in a text
/// panel, with the actions they have there.
const cua_left_alone = [_]ExpectedKey{
    .{ .chord = "tab", .mode = "buffer", .name = "complete_or_indent" },
    .{ .chord = "page_up", .mode = "text", .name = "scroll_page_up" },
    .{ .chord = "page_down", .mode = "text", .name = "scroll_page_down" },
    .{ .chord = "C-n", .mode = "text", .name = "line_down" },
    .{ .chord = "C-p", .mode = "text", .name = "line_up" },
};

test "a text panel with the common keys has each of them and no other of Emacs's" {
    var resolved: ResolvedKeys = .{};
    try resolved.initFor(modes.buffer, .cua);
    defer resolved.deinit();

    for (common_keys) |key| {
        if (hasChord(&cua_left_alone, key.chord)) continue;
        try resolved.expectBound(key);
    }
    for (cua_left_alone) |key| try resolved.expectBound(key);
    for (text_editor.text_keys ++ text_panel.buffer_keys) |key| {
        if (hasChord(&common_keys, key.chord) or hasChord(&cua_left_alone, key.chord)) continue;
        const bound = resolved.boundTo(key.chord);
        if (bound != null) std.debug.print("still bound with the common keys: {s}\n", .{key.chord});
        try std.testing.expect(bound == null);
    }
    // No two of a keymap's own keys overlap.
    const warned = resolved.tables.findByName(Atom.from(plugin.action_api.warned_table_name)).?;
    try std.testing.expectEqual(@as(usize, 0), warned.count());
}

test "a prompt and a cell keep their own keys with the common keys" {
    var prompt: ResolvedKeys = .{};
    try prompt.initFor(modes.prompt, .cua);
    defer prompt.deinit();
    for ([_]ExpectedKey{
        .{ .chord = "enter", .mode = "prompt", .name = "submit" },
        .{ .chord = "tab", .mode = "prompt", .name = "complete" },
        .{ .chord = "C-n", .mode = "prompt", .name = "next" },
        .{ .chord = "C-p", .mode = "prompt", .name = "previous" },
        .{ .chord = "S-tab", .mode = "prompt", .name = "previous" },
        .{ .chord = "escape", .mode = "prompt", .name = "cancel" },
    }) |key| try prompt.expectBound(key);

    var cell: ResolvedKeys = .{};
    try cell.initFor(modes.table_cell, .cua);
    defer cell.deinit();
    for ([_]ExpectedKey{
        .{ .chord = "enter", .mode = "table_cell", .name = "commit_down" },
        .{ .chord = "tab", .mode = "table_cell", .name = "commit_next" },
        .{ .chord = "S-tab", .mode = "table_cell", .name = "commit_previous" },
        .{ .chord = "escape", .mode = "table_cell", .name = "cancel" },
    }) |key| try cell.expectBound(key);
}

test "keyed global actions remain available in App while widget actions are gated" {
    const allocator = std.testing.allocator;
    var fx: Fixture = .{};
    try fx.init(allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);

    var rows = try actionRows(&fx);
    const action_subs = rows.actions;

    // In App, the actions offered are those a default keymap binds, and those that show panels.
    state.setViewFocus(&fx.tables, &fx.atoms, fx.atoms.intern("stage"));
    lib.pushEditorActions(&fx.tables, &fx.atoms, rows.sink());
    for ([_][]const u8{ "action_palette_toggle", "picker_toggle", "window_close", "maximize_toggle", "panels_show_hidden" }) |name| {
        try std.testing.expect(actionById(action_subs, &fx.atoms, "global", name) != null);
    }
    // No widget's `cancel` is offered: only vcs-git's commit message buffer's and vcs-p4's
    // description buffer's, which their modes, not active here, keep from being invoked.
    var cancels = action_subs.iterate();
    while (cancels.next()) |action| {
        if (action.id[1] != fx.atoms.intern("cancel")) continue;
        const buffer_mode = action.id[0] == modes.vcs_message or action.id[0] == modes.vcs_p4_message;
        try std.testing.expect(buffer_mode);
    }
    try std.testing.expect(actionByName(action_subs, &fx.atoms, "row_add") == null);
    action_subs.reset();

    const target = try targetTable(allocator, &fx.atoms, &fx.tables);
    try std.testing.expect(windows.open(&fx.tables, &fx.atoms, target));
    state.setViewFocus(&fx.tables, &fx.atoms, fx.tables.get(target).?.name);
    lib.pushEditorActions(&fx.tables, &fx.atoms, rows.sink());
    try std.testing.expect(actionById(action_subs, &fx.atoms, "table", "row_add") != null);
    try std.testing.expect(actionById(action_subs, &fx.atoms, "table", "save") != null);
    try std.testing.expect(actionById(action_subs, &fx.atoms, "form", "save") == null);
    // The focused view offers its own actions too, which the keymap of `table` binds. No id is
    // offered twice.
    windows.declareActions(&fx.tables, &fx.atoms, rows.sink());
    for (table_view.actions) |def| {
        // Sorting is by the selected cell's column, and this table has no row to select.
        const sorts = std.mem.eql(u8, def.name, "sort_column");
        const found = actionById(action_subs, &fx.atoms, "table", def.name);
        if (sorts) {
            try std.testing.expect(found == null);
            continue;
        }
        try std.testing.expect(found != null);
    }
    var offered = action_subs.iterate();
    var offered_count: usize = 0;
    while (offered.next()) |action| : (offered_count += 1) {
        var others = action_subs.iterate();
        var same_id_count: usize = 0;
        while (others.next()) |other| {
            if (std.mem.eql(Atom, &action.id, &other.id)) same_id_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), same_id_count);
    }
    try std.testing.expect(offered_count > 0);
    action_subs.reset();

    try toggleActionPalette(&fx);
    lib.pushEditorActions(&fx.tables, &fx.atoms, rows.sink());
    // The action palette's own keys take part in its capture; anything else stays out of it.
    const toggle = actionByName(action_subs, &fx.atoms, "action_palette_toggle").?;
    try std.testing.expect(toggle.capture);
    // Its text is the text editor's: the prompt's actions and the text editor's capture.
    const captured_ids = [_][2][]const u8{ .{ "prompt", "submit" }, .{ "prompt", "next" }, .{ "text", "word_left" } };
    for (captured_ids) |captured| {
        try std.testing.expect(actionById(action_subs, &fx.atoms, captured[0], captured[1]).?.capture);
    }
    try std.testing.expect(!actionByName(action_subs, &fx.atoms, "row_add").?.capture);
}

test "window_close with an empty params blob closes the focused window" {
    const allocator = std.testing.allocator;
    var fx: Fixture = .{};
    try fx.init(allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    try initModes(&fx);

    const target = try targetTable(allocator, &fx.atoms, &fx.tables);
    try std.testing.expect(windows.open(&fx.tables, &fx.atoms, target));
    try std.testing.expectEqual(@as(u32, 1), windows.windows(&fx.tables, &fx.atoms).count());

    state.setViewFocus(&fx.tables, &fx.atoms, fx.tables.get(target).?.name);

    try windowsMessage(&fx, .{ .tag = .from(windows.Msg.window_close) });
    try std.testing.expectEqual(@as(u32, 0), windows.windows(&fx.tables, &fx.atoms).count());
}

test "ctx_add acts on the focused window's table (row when no drawer is open)" {
    const allocator = std.testing.allocator;
    var fx: Fixture = .{};
    try fx.init(allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    try initModes(&fx);

    const target = try targetTable(allocator, &fx.atoms, &fx.tables);
    try std.testing.expect(windows.open(&fx.tables, &fx.atoms, target));
    try std.testing.expectEqual(@as(u32, 0), fx.tables.get(target).?.count());
    state.setViewFocus(&fx.tables, &fx.atoms, fx.tables.get(target).?.name);

    try windowsMessage(&fx, .{ .tag = .from(windows.Msg.ctx_add) });
    try std.testing.expectEqual(@as(u32, 1), fx.tables.get(target).?.count());
}

test "menu UI rail glyph bounds are centred at the packed size" {
    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "editor/assets/fonts/RobotoMonoNerdFontMono-Regular.ttf", std.testing.allocator, .limited(8 * 1024 * 1024));
    defer std.testing.allocator.free(data);
    const atlas = try mesha_runtime.font.bakeListedToRgba(std.testing.allocator, data, mesha.font.kRailIconPixelHeight, &mesha.font.rail_icon_codepoints);
    defer std.testing.allocator.free(atlas.pixels);
    for (atlas.baked_chars[0..atlas.count]) |glyph| {
        try std.testing.expect(glyph.x1 - glyph.x0 <= 36);
        try std.testing.expect(glyph.y1 - glyph.y0 <= 36);
    }
    for ([_]u32{ 0xf01c0, 0xf03ea }) |codepoint| {
        const index = std.mem.indexOfScalar(u32, atlas.codepoints[0..atlas.count], codepoint).?;
        const glyph = atlas.baked_chars[index];
        const width: f32 = @floatFromInt(glyph.x1 - glyph.x0);
        const height: f32 = @floatFromInt(glyph.y1 - glyph.y0);
        try std.testing.expect(@max(width, height) >= 16 and @max(width, height) <= 24);
        for ([_]f32{ 40, 36 }) |size| {
            const position = button.inkCenteredOrigin(.{ .x = size, .y = size }, glyph);
            const center_x = position.x + glyph.xoff + width * 0.5;
            const center_y = position.y + glyph.yoff + height * 0.5;
            try std.testing.expectApproxEqAbs(size * 0.5, center_x, 0.5);
            try std.testing.expectApproxEqAbs(size * 0.5, center_y, 0.5);
        }
    }
}

test "menu UI icon catalog matches baked codepoints and icon-only routing" {
    const resource = mesha.resources;
    const icon_values = std.enums.values(button.icons.Icon);
    try std.testing.expectEqual(resource.font.icon_codepoints.len + 5, icon_values.len);
    for (icon_values[5..], resource.font.icon_codepoints) |icon, codepoint| {
        const text = button.icons.glyph(icon);
        try std.testing.expectEqual(codepoint, try std.unicode.utf8Decode(text));
    }
    for (icon_values[0..5]) |icon| {
        const codepoint = try std.unicode.utf8Decode(button.icons.glyph(icon));
        try std.testing.expect(std.mem.indexOfScalar(u32, &resource.font.rail_icon_codepoints, codepoint) != null);
    }

    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    var tree = try ui.Tree.init(try fx.mem.frameScratchAllocator(), &fx.atoms, 64);
    const payload = editor_sequencer.to(&tree, figure_workspace.system(), fx.atoms.intern("figure_tool_pen"), {});
    button.render(&tree, "pen", payload, .{ .variant = .icon_only, .icon = .pen, .selected = true, .tooltip = "Pen · p" });
    const rect = tree.elements[0].open_rect;
    try std.testing.expectEqual(@as(f32, 40), rect.size.w.fixed);
    try std.testing.expectEqual(@as(f32, 40), rect.size.h.fixed);
    try std.testing.expect(std.meta.eql(style.col.accent_deep, rect.bg.?));
    try std.testing.expect(rect.border == null);
    try std.testing.expectEqual(payload, rect.on_click.?);
    try std.testing.expect(rect.hover);
    try std.testing.expectEqualStrings("Pen · p", rect.tooltip);
    var icon_count: usize = 0;
    for (tree.elements[0..tree.count]) |element| switch (element) {
        .custom => |icon| {
            icon_count += 1;
            try std.testing.expect(icon.params.size.w == .fill and icon.params.size.h == .fill);
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), icon_count);

    tree.reset();
    button.render(&tree, "disabled", payload, .{ .variant = .icon_only, .icon = .pen, .enabled = false });
    const disabled = tree.elements[0].open_rect;
    try std.testing.expect(disabled.on_click == null and !disabled.hover);
    try std.testing.expect(disabled.bg_hover == null);
}

test "action palette tooltip owns queued text and preserves prompt state" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try action_palette.ensure(try fx.mem.tableScratchAllocator(), &fx.atoms, &fx.tables);
    try state.ensureViewFocus(try fx.mem.tableScratchAllocator(), &fx.atoms, &fx.tables);
    try state.ensureAuthoringUi(try fx.mem.tableScratchAllocator(), &fx.atoms, &fx.tables);
    try status_bar.ensure(try fx.mem.tableScratchAllocator(), &fx.atoms, &fx.tables);
    var text = [_]u8{'a'} ** 300;
    status_bar.request(&fx.mem, &fx.tables, .{ .set_hover = text[0..] });
    @memset(&text, 'b');
    try dispatchEditorCommands(&fx);
    const s = action_palette.prompt(&fx.tables, &fx.atoms);
    try std.testing.expectEqual(@as(usize, 256), (try hoverText(&fx)).len);
    try std.testing.expect(std.mem.allEqual(u8, (try hoverText(&fx)), 'a'));
    const entries = [_]action_palette.Completion{};
    const request: action_palette.Completions = .{ .owner = fx.atoms.intern("test.owner"), .prompt = "Error", .initial_query = "value", .entries = &entries };
    action_palette.request(&fx.mem, &fx.tables, .{ .present = .{ .completions = &request, .reply = .{} } });
    try runPalette(&fx);
    try std.testing.expectEqual(@as(usize, 0), (try hoverText(&fx)).len);
    const before = s.text.*;
    const cursor = s.cursor.*;
    status_bar.request(&fx.mem, &fx.tables, .{ .set_hover = "hover" });
    try std.testing.expectEqual(@as(usize, 0), (try hoverText(&fx)).len);
    try std.testing.expectEqual(before, s.text.*);
    try std.testing.expectEqual(cursor, s.cursor.*);
    try std.testing.expectEqual(request.owner, action_palette.currentOwner(&fx.tables, &fx.atoms).?);
    status_bar.request(&fx.mem, &fx.tables, .clear_hover);
    try std.testing.expectEqual(@as(usize, 0), (try hoverText(&fx)).len);
    try std.testing.expectEqual(before, s.text.*);
}

test "status bar shows the hovered element's tooltip unless the palette asks for the screen" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    fx.resetCommands();
    const a = figure_view.canvas_hover_id;
    const b: ui.ElementId = .{ .atom = fx.atoms.intern("hover.b"), .extra = 0 };
    // What an element says is its hit region's: the bar reads it there.
    var region_schema: Table.Schema = undefined;
    try ui.initHitRegionSchema(&region_schema, try fx.mem.tableScratchAllocator(), &fx.atoms);
    defer region_schema.deinit();
    _ = try fx.tables.ensure(&region_schema, 8, fx.atoms.intern(state.hit_regions_name), .durable);
    const regions = state.hitRegions(&fx.tables, &fx.atoms);
    _ = regions.insert(.{ .hover = @as(u8, 1), .id = std.mem.toBytes(b), .tooltip = @as([]const u8, "second") });
    const silent_region = regions.insert(.{ .hover = @as(u8, 1), .id = std.mem.toBytes(a), .tooltip = @as([]const u8, "") });
    try input_mod.writeHover(&fx.tables, &fx.atoms, .{ .element = std.mem.toBytes(b) });
    try std.testing.expectEqualStrings("second", (try hoverText(&fx)));
    try std.testing.expectEqual(b, state.hoveredElementId(&fx.tables).?);
    try input_mod.writeHover(&fx.tables, &fx.atoms, .{});
    try std.testing.expectEqual(@as(usize, 0), (try hoverText(&fx)).len);
    // An element without a tooltip is hovered but says nothing.
    try input_mod.writeHover(&fx.tables, &fx.atoms, .{ .element = std.mem.toBytes(a) });
    try std.testing.expectEqual(@as(usize, 0), (try hoverText(&fx)).len);
    try std.testing.expectEqual(a, state.hoveredElementId(&fx.tables).?);

    const request: action_palette.Completions = .{
        .owner = fx.atoms.intern("test.pending"),
        .presentation = .prompt,
        .entries = &.{},
    };
    action_palette.request(&fx.mem, &fx.tables, .{ .present = .{ .completions = &request, .reply = .{} } });
    try runPalette(&fx);
    // While a request owns the palette, what is behind it says nothing.
    try regions.setString(silent_region, "tooltip", "behind the palette");
    try input_mod.writeHover(&fx.tables, &fx.atoms, .{ .element = std.mem.toBytes(a) });
    try std.testing.expectEqual(@as(usize, 0), (try hoverText(&fx)).len);
    try std.testing.expectEqual(a, state.hoveredElementId(&fx.tables).?);
    action_palette.request(&fx.mem, &fx.tables, .{ .dismiss = .{} });
    try runPalette(&fx);
    try std.testing.expectEqualStrings("behind the palette", (try hoverText(&fx)));
}

test "action palette figure prompt capture survives busy admission and acknowledges cancellation" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    fx.resetCommands();
    // The figure editor's prompts are asked with its stage shown, while it watches the open figure.
    fixed_panels.layOutNow(&fx.tables, &fx.atoms, .figure_stage);
    const editor = session.get(&fx.tables);
    const figure = mesha_runtime.figure;
    const context = session.figureContext(&fx.tables, &fx.atoms);
    try figure.init(context);
    defer figure.deinit(context) catch unreachable;
    const domain = mesha_runtime.figure.domain;
    const doc = fx.atoms.intern("prompt_capture");
    try domain.library.create(&fx.tables, &fx.atoms, .{ .scope = mesha.resources.applicationScope(fx.tables.memory), .doc = doc });
    const original = fx.atoms.intern("original");
    const object_id = (try domain.command.apply(&fx.atoms, &fx.tables, .{ .add_bone = .{ .doc = doc, .name = original } })).?;
    editor.doc.* = doc;
    try transport_fixture.synchronize(&fx.mem, &fx.atoms, &fx.tables);
    const bone = fx.atoms.intern("bone");
    try prompts.showTarget(&fx.mem, &fx.tables, &fx.atoms, names_mod.rename, "original", bone, object_id);
    try dispatchEditorCommands(&fx);
    const request = action_palette.currentCompletions(&fx.tables, &fx.atoms).?;
    try std.testing.expectError(error.PromptBusy, prompts.showTarget(&fx.mem, &fx.tables, &fx.atoms, names_mod.new, "replacement", bone, 9));
    try std.testing.expectEqual(object_id, editor.prompt_id.*);
    const original_text = session.promptText(&fx.tables);
    try std.testing.expectEqualStrings("original", original_text);
    try std.testing.expectEqualStrings("original", request.initial_query);
    try std.testing.expectEqualStrings("original", request.entries[0].label);

    action_palette.request(&fx.mem, &fx.tables, .{ .cancel = .{ .owner = prompts.owner } });
    try dispatchEditorCommands(&fx);
    try std.testing.expectError(error.PromptBusy, prompts.showTarget(&fx.mem, &fx.tables, &fx.atoms, names_mod.new, "replacement", bone, 9));
    const completion = popEditorMessage(&fx);
    try editorMessage(&fx, completion);
    try runPalette(&fx);
    try std.testing.expect(action_palette.canPresent(&fx.tables, &fx.atoms));
    try prompts.showTarget(&fx.mem, &fx.tables, &fx.atoms, names_mod.new, "replacement", bone, 9);
    try std.testing.expectEqual(@as(u32, 9), editor.prompt_id.*);
    try runPalette(&fx);

    // An answer to the earlier prompt still in flight does not act on this one.
    const late = try paletteEvent(&fx, .from(figure_workspace.Msg.figure_prompt_reply), .{ .kind = .completed, .completion = null, .query = "earlier answer" });
    try std.testing.expect(prompts.handleMessage(&fx.mem, &fx.tables, &fx.atoms, late));
    try std.testing.expectEqualStrings("replacement", session.promptText(&fx.tables));
    try std.testing.expectEqual(fx.atoms.intern("new"), editor.prompt_kind.*);
}

test "action palette selected shape property keeps mixed target isolated and journals edits" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    fx.resetCommands();
    // The figure editor's prompts are asked with its stage shown, while it watches the open figure.
    fixed_panels.layOutNow(&fx.tables, &fx.atoms, .figure_stage);
    const figure = mesha_runtime.figure;
    const domain = mesha_runtime.figure.domain;
    const context = session.figureContext(&fx.tables, &fx.atoms);
    try figure.init(context);
    defer figure.deinit(context) catch unreachable;
    try transport_fixture.ensureResultInbox(&fx.mem, &fx.atoms, &fx.tables);
    var host = figure.HostTransport.Host{ .context = .{ .memory = &fx.mem, .tables = &fx.tables, .atoms = &fx.atoms } };
    try figure.HostTransport.prepareCommands(&host);
    var figure_commands: figure.HostTransport.HostContext = .{ .host = &host };
    const doc = fx.atoms.intern("property_target");
    try domain.library.create(&fx.tables, &fx.atoms, .{ .scope = mesha.resources.applicationScope(fx.tables.memory), .doc = doc });
    const primary_name = fx.atoms.intern("primary");
    const bone = (try domain.command.apply(&fx.atoms, &fx.tables, .{ .add_bone = .{ .doc = doc, .length = 40 } })).?;
    const allocated_shape = (try domain.command.apply(&fx.atoms, &fx.tables, .{ .add_shape = .{ .doc = doc, .name = primary_name, .layer = 1, .points = &.{ .{ .p = .{ .x = 0, .y = 0 } }, .{ .p = .{ .x = 10, .y = 10 } } } } })).?;
    // Loaded documents may reuse IDs across kinds. Construct that valid case;
    // the authoring allocator itself uses a shared monotonically increasing ID.
    const shapes = try domain.tables.family(&fx.tables, doc, "shapes");
    const shape_handle = domain.tables.find(shapes, doc, allocated_shape).?;
    const shape_row = shapes.getRow(shape_handle, domain.tables.Shape).?;
    shape_row.id.* = bone;
    const points = try domain.tables.family(&fx.tables, doc, "points");
    var point_rows = points.query(domain.tables.Point);
    while (point_rows.next()) |row| {
        if (row.view.doc.* == doc and row.view.shape.* == allocated_shape) row.view.shape.* = bone;
    }
    const primary = shape_row.id.*;
    const secondary = (try domain.command.apply(&fx.atoms, &fx.tables, .{ .add_shape = .{ .doc = doc, .layer = 1, .style = .{ .stroke_width = 3 }, .points = &.{ .{ .p = .{ .x = 20, .y = 0 } }, .{ .p = .{ .x = 30, .y = 10 } } } } })).?;
    try std.testing.expectEqual(bone, primary);
    const editor = session.get(&fx.tables);
    editor.doc.* = doc;
    try transport_fixture.synchronize(&fx.mem, &fx.atoms, &fx.tables);
    const shape_kind = fx.atoms.intern("shape");
    const bone_kind = fx.atoms.intern("bone");
    selection.select(&fx.tables, &fx.atoms, shape_kind, primary, false, false);
    selection.select(&fx.tables, &fx.atoms, shape_kind, secondary, true, false);
    selection.select(&fx.tables, &fx.atoms, bone_kind, bone, true, false);
    try transport_fixture.synchronize(&fx.mem, &fx.atoms, &fx.tables);
    const defaults = drawing.config(&fx.tables);
    const default_width = defaults.stroke_width.*;
    const width_field: u32 = for (prompts.inspectorFields(shape_kind), 0..) |field, index| {
        if (std.mem.eql(u8, field.name, "stroke_width")) break @intCast(index);
    } else return error.MissingField;
    try prompts.editTarget(&fx.mem, &fx.tables, &fx.atoms, shape_kind, primary, width_field, .whole, null);
    try dispatchWithFigure(&fx, &figure_commands);
    const request = action_palette.currentCompletions(&fx.tables, &fx.atoms).?;
    try std.testing.expectEqualStrings("2", request.initial_query);
    try std.testing.expectEqualStrings("shape primary #2 - Stroke width: ", request.prompt);
    try submitPromptText(&fx, "-1");
    try dispatchWithFigure(&fx, &figure_commands);
    const retry = action_palette.currentCompletions(&fx.tables, &fx.atoms).?;
    try std.testing.expectEqualStrings("Finite width of at least 0", retry.entries[0].detail);
    try std.testing.expect(transport_fixture.noResults(&fx.tables));
    try submitPromptText(&fx, "7");
    try dispatchWithFigure(&fx, &figure_commands);
    const result = (try transport_fixture.nextResult(&fx.tables)).?;
    const consumed = commands_mod.consume(context, result);
    try std.testing.expect(consumed);
    const changed = try session.readDefinition(&fx.tables, &fx.atoms, doc);
    const changed_primary = session.findById(plugin.figure_api.read.Shape, changed.shapes, primary).?;
    const unchanged_secondary = session.findById(plugin.figure_api.read.Shape, changed.shapes, secondary).?;
    const unchanged_bone = session.findById(plugin.figure_api.read.Bone, changed.bones, bone).?;
    try std.testing.expectEqual(@as(f32, 7), changed_primary.stroke_width);
    try std.testing.expectEqual(@as(f32, 3), unchanged_secondary.stroke_width);
    try std.testing.expectEqual(@as(f32, 40), unchanged_bone.length);
    try std.testing.expectEqual(default_width, defaults.stroke_width.*);
    _ = try domain.command.apply(&fx.atoms, &fx.tables, .{ .undo = .{ .doc = doc } });
    try transport_fixture.synchronize(&fx.mem, &fx.atoms, &fx.tables);
    const undone = try session.readDefinition(&fx.tables, &fx.atoms, doc);
    const undone_primary = session.findById(plugin.figure_api.read.Shape, undone.shapes, primary).?;
    try std.testing.expectEqual(@as(f32, 2), undone_primary.stroke_width);
    _ = try domain.command.apply(&fx.atoms, &fx.tables, .{ .redo = .{ .doc = doc } });
    try transport_fixture.synchronize(&fx.mem, &fx.atoms, &fx.tables);
    const redone = try session.readDefinition(&fx.tables, &fx.atoms, doc);
    const redone_primary = session.findById(plugin.figure_api.read.Shape, redone.shapes, primary).?;
    try std.testing.expectEqual(@as(f32, 7), redone_primary.stroke_width);
    editor.prompt_field.* = fx.atoms.intern("name");
    const duplicate_name = fx.atoms.lookup(unchanged_secondary.name).?;
    try std.testing.expectError(error.DuplicateName, prompts.fieldCommand(&fx.tables, &fx.atoms, editor, duplicate_name));
}

test "action palette creation appearance defaults stay separate from selected artwork and history" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    fx.resetCommands();
    // The figure editor's prompts are asked with its stage shown, while it watches the open figure.
    fixed_panels.layOutNow(&fx.tables, &fx.atoms, .figure_stage);
    const figure = mesha_runtime.figure;
    const domain = mesha_runtime.figure.domain;
    const context = session.figureContext(&fx.tables, &fx.atoms);
    try figure.init(context);
    defer figure.deinit(context) catch unreachable;
    const doc = fx.atoms.intern("creation_defaults");
    try domain.library.create(&fx.tables, &fx.atoms, .{ .scope = mesha.resources.applicationScope(fx.tables.memory), .doc = doc });
    const shape = (try domain.command.apply(&fx.atoms, &fx.tables, .{ .add_shape = .{
        .doc = doc,
        .layer = 1,
        .style = .{ .stroke_width = 5 },
        .points = &.{ .{ .p = .{ .x = 0, .y = 0 } }, .{ .p = .{ .x = 10, .y = 10 } } },
    } })).?;
    const destination_name = fx.atoms.intern("destination");
    const destination = (try domain.command.apply(&fx.atoms, &fx.tables, .{ .add_layer = .{ .doc = doc, .name = destination_name } })).?;
    const folder_name = fx.atoms.intern("folder");
    const folder_kind = fx.atoms.intern("folder");
    _ = try domain.command.apply(&fx.atoms, &fx.tables, .{ .add_layer = .{ .doc = doc, .name = folder_name, .kind = folder_kind } });
    const editor = session.get(&fx.tables);
    editor.doc.* = doc;
    try transport_fixture.synchronize(&fx.mem, &fx.atoms, &fx.tables);
    const original = try session.readDefinition(&fx.tables, &fx.atoms, doc);
    // A copy: it outlives the publication it was read from.
    const original_shape = session.findById(plugin.figure_api.read.Shape, original.shapes, shape).?;
    const before = try figure.definitionInfo(context, doc);
    editor.active_layer.* = 1;
    const shape_kind = fx.atoms.intern("shape");
    selection.select(&fx.tables, &fx.atoms, shape_kind, shape, false, false);
    editor.tool.* = fx.atoms.intern("rect");
    editor.inspector_field.* = 1;
    const settings = drawing.config(&fx.tables);
    const original_stroke = settings.stroke_color.*;
    const target = prompts.inspectorTarget(session.get(&fx.tables), drawing.config(&fx.tables));
    try std.testing.expectEqual(prompts.defaults_kind, target.kind);
    const target_name = fx.atoms.lookup(target.kind).?;
    try std.testing.expectEqualStrings("tool_defaults", target_name);
    try prompts.editField(&fx.mem, &fx.tables, &fx.atoms, null);
    try dispatchEditorCommands(&fx);
    const request = action_palette.currentCompletions(&fx.tables, &fx.atoms).?;
    try std.testing.expectEqualStrings("Tool defaults - Fill RGBA: ", request.prompt);
    try std.testing.expectEqualStrings("#98c4efff", request.initial_query);
    // Completion stays attached to defaults after the visible context changes.
    editor.tool.* = fx.atoms.intern("select");
    try submitPromptText(&fx, "nope");
    try dispatchEditorCommands(&fx);
    const color_request_open = action_palette.requestOpen(&fx.tables, &fx.atoms);
    try std.testing.expect(color_request_open);
    try std.testing.expectEqual(session.Color{ 152, 196, 239, 255 }, settings.fill_color.*);
    try submitPromptText(&fx, "#10203040");
    try dispatchEditorCommands(&fx);
    try std.testing.expectEqual(session.Color{ 16, 32, 48, 64 }, settings.fill_color.*);
    try std.testing.expectEqual(original_stroke, settings.stroke_color.*);
    try std.testing.expectEqual(@as(f32, 2), settings.stroke_width.*);
    const selected_target = prompts.inspectorTarget(session.get(&fx.tables), drawing.config(&fx.tables));
    try std.testing.expectEqual(editor.active_kind.*, selected_target.kind);
    try std.testing.expectEqual(shape, selected_target.id);
    try prompts.editTarget(&fx.mem, &fx.tables, &fx.atoms, prompts.defaults_kind, 0, 5, .whole, null);
    try dispatchEditorCommands(&fx);
    try submitPromptText(&fx, "folder");
    try dispatchEditorCommands(&fx);
    const layer_request_open = action_palette.requestOpen(&fx.tables, &fx.atoms);
    try std.testing.expect(layer_request_open);
    try std.testing.expectEqual(@as(u32, 1), editor.active_layer.*);
    try submitPromptText(&fx, "destination");
    try dispatchEditorCommands(&fx);
    selection.prune(&fx.tables, &fx.atoms);
    try std.testing.expectEqual(destination, editor.active_layer.*);
    const after = try figure.definitionInfo(context, doc);
    try std.testing.expectEqual(before.authored_revision, after.authored_revision);
    const current = try session.readDefinition(&fx.tables, &fx.atoms, doc);
    const current_shape = session.findById(plugin.figure_api.read.Shape, current.shapes, shape).?;
    try std.testing.expectEqualDeep(original_shape, current_shape);
    selection.select(&fx.tables, &fx.atoms, shape_kind, shape, false, false);
    try std.testing.expectEqual(original_shape.layer, editor.active_layer.*);
}

test "action palette drawing options prefill validate retry cancel and isolate one setting" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    fx.resetCommands();
    const settings = drawing.config(&fx.tables);
    const options = std.enums.values(drawing.ToolOption);
    var before: [options.len]f32 = undefined;
    for (options, &before) |option, *value| value.* = option.value(settings);
    try prompts.showDrawingOption(&fx.mem, &fx.tables, &fx.atoms, .pencil_spacing);
    try dispatchEditorCommands(&fx);
    const initial = action_palette.currentCompletions(&fx.tables, &fx.atoms).?;
    try std.testing.expectEqualStrings("2", initial.initial_query);
    try std.testing.expectEqualStrings("Tool defaults - Spacing: ", initial.prompt);
    try submitPromptText(&fx, "0");
    try dispatchEditorCommands(&fx);
    try std.testing.expect(action_palette.requestOpen(&fx.tables, &fx.atoms));
    const retry = action_palette.currentCompletions(&fx.tables, &fx.atoms).?;
    try std.testing.expectEqualStrings("0", retry.initial_query);
    try std.testing.expectEqualStrings("Spacing must be finite and at least 0.5 pixels", retry.entries[0].detail);
    for (options, before) |option, value| {
        const actual = option.value(settings);
        try std.testing.expectEqual(value, actual);
    }
    try submitPromptText(&fx, "2.5");
    const status = session.statusText(&fx.tables);
    try std.testing.expectEqualStrings("", status);
    for (options, before) |option, value| {
        const expected: f32 = if (option == .pencil_spacing) 2.5 else value;
        const actual = option.value(settings);
        try std.testing.expectEqual(expected, actual);
    }
    try dispatchEditorCommands(&fx);
    try prompts.showDrawingOption(&fx.mem, &fx.tables, &fx.atoms, .polygon_sides);
    try dispatchEditorCommands(&fx);
    try submitPromptText(&fx, "3.5");
    try dispatchEditorCommands(&fx);
    try std.testing.expectEqual(@as(u32, 5), settings.polygon_sides.*);
    prompts.status(session.table(&fx.tables), session.get(&fx.tables), session.feedback(&fx.tables), "Unrelated command error");
    try paletteKey(&fx, action_palette.Msg.cancel);
    try dispatchEditorCommands(&fx);
    const reply = popEditorMessage(&fx);
    try editorMessage(&fx, reply);
    try std.testing.expect(!action_palette.requestOpen(&fx.tables, &fx.atoms));
    try std.testing.expectEqual(@as(u32, 5), settings.polygon_sides.*);
    const retained_error = session.statusText(&fx.tables);
    try std.testing.expectEqualStrings("Unrelated command error", retained_error);
}

test "action palette Weight brush fields validate independently and cancel without changes" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    fx.resetCommands();
    const settings = weight.config(&fx.tables);
    try prompts.showWeightOption(&fx.mem, &fx.tables, &fx.atoms, .radius);
    try dispatchEditorCommands(&fx);
    const request = action_palette.currentCompletions(&fx.tables, &fx.atoms).?;
    try std.testing.expectEqualStrings("Weight brush - Radius px: ", request.prompt);
    try std.testing.expectEqualStrings("45", request.initial_query);
    try submitPromptText(&fx, "0");
    try dispatchEditorCommands(&fx);
    const retry_open = action_palette.requestOpen(&fx.tables, &fx.atoms);
    try std.testing.expect(retry_open);
    try std.testing.expectEqual(@as(f32, 45), settings.radius.*);
    try submitPromptText(&fx, "96");
    try dispatchEditorCommands(&fx);
    try std.testing.expectEqual(@as(f32, 96), settings.radius.*);
    try std.testing.expectEqual(@as(f32, 0.1), settings.strength.*);
    try std.testing.expectEqual(@as(f32, 1), settings.value.*);
    try prompts.showWeightOption(&fx.mem, &fx.tables, &fx.atoms, .strength);
    try dispatchEditorCommands(&fx);
    try submitPromptText(&fx, "2");
    try dispatchEditorCommands(&fx);
    try paletteKey(&fx, action_palette.Msg.cancel);
    try dispatchEditorCommands(&fx);
    const reply = popEditorMessage(&fx);
    const handled_reply = lib.updateMessage(&fx.mem, &fx.tables, &fx.atoms, reply);
    try std.testing.expect(handled_reply);
    try std.testing.expectEqual(@as(f32, 0.1), settings.strength.*);
    const closed = !action_palette.requestOpen(&fx.tables, &fx.atoms);
    try std.testing.expect(closed);
    for ([_]weight.BrushOption{ .mode, .falloff }) |option| {
        for (option.choices()) |choice| {
            try option.apply(&fx.tables, &fx.atoms, choice);
            const expected = fx.atoms.intern(choice);
            const actual = if (option == .mode) settings.brush_mode.* else settings.falloff.*;
            try std.testing.expectEqual(expected, actual);
            try std.testing.expectError(error.InvalidBrushOption, option.apply(&fx.tables, &fx.atoms, "invalid"));
            const retained = if (option == .mode) settings.brush_mode.* else settings.falloff.*;
            try std.testing.expectEqual(expected, retained);
        }
    }
    try std.testing.expectEqual(@as(f32, 96), settings.radius.*);
    try std.testing.expectEqual(@as(f32, 1), settings.value.*);
}

test "menu UI icon text selects sparse atlas while retaining legacy text glyphs" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    var tree = try ui.Tree.init(try fx.mem.frameScratchAllocator(), &fx.atoms, 32);
    const payload: ui.Target = .{ .tag = fx.atoms.intern("test.icon") };
    button.render(&tree, "material", payload, .{ .icon = .undo, .label = "Undo" });
    var custom: usize = 0;
    for (tree.elements[0..tree.count]) |element| if (element == .custom) {
        custom += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), custom);
    tree.reset();
    button.render(&tree, "legacy", payload, .{ .icon = .back, .label = "Back" });
    custom = 0;
    for (tree.elements[0..tree.count]) |element| if (element == .custom) {
        custom += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), custom);
}

test "action palette command tag ordinals remain stable" {
    const Tag = std.meta.Tag(mesha.plugin.editor_api.CmdPayload);
    const tags = [_]Tag{ .present, .replace, .dismiss, .emit };
    for (tags, 0..) |tag, ordinal| try std.testing.expectEqual(ordinal, @intFromEnum(tag));
}

test "ownRequestText leaves no display string in the requester's image" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const prompt_literal = "M-x ";
    const entry_literal = "Create tracker";
    const key_literal = "C-x";
    const entries = [_]action_palette.Completion{.{ .key = key_literal, .label = entry_literal, .detail = entry_literal, .data = @splat(3), .completes_to = entry_literal }};
    var request: action_palette.Completions = .{ .prompt = prompt_literal, .initial_query = prompt_literal, .title = prompt_literal, .body = prompt_literal, .entries = &entries };
    try action_palette.ownRequestText(allocator, &request);

    for ([_][]const u8{ request.prompt, request.initial_query, request.title, request.body }) |text| {
        try std.testing.expectEqualStrings(prompt_literal, text);
        try std.testing.expect(text.ptr != prompt_literal.ptr);
    }
    try std.testing.expect(request.entries.ptr != &entries);
    try std.testing.expectEqualStrings(entry_literal, request.entries[0].label);
    try std.testing.expect(request.entries[0].label.ptr != entry_literal.ptr);
    try std.testing.expect(request.entries[0].detail.ptr != entry_literal.ptr);
    try std.testing.expect(request.entries[0].completes_to.?.ptr != entry_literal.ptr);
    try std.testing.expect(request.entries[0].key.ptr != key_literal.ptr);
    try std.testing.expectEqual(@as(u8, 3), request.entries[0].data[0]);
}

/// The palette's last `emit`, as its run pushed it to the fixture's queue.
/// The palette's last answer waiting for the hook. A copy: its strings stay in the row's
/// arena until the fixture resets its commands.
fn lastEmit(fx: *Fixture) plugin.app_commands.Payload {
    var waiting: [16]plugin.app_commands.Payload = undefined;
    const requests = appRequests(fx, &waiting);
    return requests[requests.len - 1];
}

fn appRequestCount(fx: *Fixture) usize {
    var waiting: [16]plugin.app_commands.Payload = undefined;
    return appRequests(fx, &waiting).len;
}

test "the inspector's actions run as its system: panel commands, and the add-widget prompt" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    fx.resetCommands();
    try systemAction(&fx, inspector.system(), fx.atoms.intern("maximize_toggle"));
    try std.testing.expectEqual(@as(usize, 1), panelRequestCount(&fx.tables));
    try std.testing.expect(panelRequestAt(&fx.tables, 0).? == .toggle_maximize);
    fx.resetCommands();

    try systemAction(&fx, inspector.system(), fx.atoms.intern("inspector_add_widget"));
    try runPalette(&fx);
    try std.testing.expectEqual(inspector.widget_owner, action_palette.currentOwner(&fx.tables, &fx.atoms).?);
    // While the prompt is open the panels stay as they are.
    fx.resetCommands();
    try systemAction(&fx, inspector.system(), fx.atoms.intern("maximize_toggle"));
    try std.testing.expectEqual(@as(usize, 0), panelRequestCount(&fx.tables));
}

test "of the prompts presented in one frame the first opens and the others hear they were refused" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    fx.resetCommands();
    const first = action_palette.Completions{ .owner = fx.atoms.intern("first_prompt"), .title = "First", .entries = &.{} };
    const second = action_palette.Completions{ .owner = fx.atoms.intern("second_prompt"), .title = "Second", .entries = &.{} };
    const second_reply = fx.atoms.intern("second_reply");
    action_palette.request(&fx.mem, &fx.tables, .{ .present = .{ .completions = &first, .reply = testReply(fx.atoms.intern("first_reply")) } });
    action_palette.request(&fx.mem, &fx.tables, .{ .present = .{ .completions = &second, .reply = testReply(second_reply) } });
    try dispatchEditorCommands(&fx);
    try std.testing.expectEqual(first.owner, action_palette.currentOwner(&fx.tables, &fx.atoms).?);
    const refused_message = popEditorMessage(&fx);
    try std.testing.expectEqual(second_reply, refused_message.tag);
    const refused = try action_palette.eventOf(refused_message);
    try std.testing.expectEqual(action_palette.Msg.EventKind.completed, refused.kind);
    try std.testing.expect(refused.completion == null);
    try std.testing.expect(takeInboxMessage(&fx) == null);
    // A prompt presented in a later frame replaces the one open, whose owner hears so.
    action_palette.request(&fx.mem, &fx.tables, .{ .present = .{ .completions = &second, .reply = testReply(second_reply) } });
    try dispatchEditorCommands(&fx);
    try std.testing.expectEqual(second.owner, action_palette.currentOwner(&fx.tables, &fx.atoms).?);
    try std.testing.expectEqual(fx.atoms.intern("first_reply"), popEditorMessage(&fx).tag);
}

test "a refused final response is kept for retry and no prompt opens until it lands" {
    var fx: Fixture = undefined;
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    fx.resetCommands();
    const route = testReply(fx.atoms.intern("test_reply"));
    const completions = action_palette.Completions{ .owner = fx.atoms.intern("test_prompt"), .presentation = .prompt, .entries = &.{} };
    action_palette.request(&fx.mem, &fx.tables, .{ .present = .{ .completions = &completions, .reply = route } });
    try runPalette(&fx);
    try std.testing.expect(action_palette.requestOpen(&fx.tables, &fx.atoms));

    action_palette.request(&fx.mem, &fx.tables, .{ .dismiss = .{} });
    try runPalette(&fx);
    try std.testing.expect(!action_palette.requestOpen(&fx.tables, &fx.atoms));

    // Held as the hook holds a refused answer; the fixture's reset below drops its row, and
    // the answer, dismissing with nothing typed, carries no text to lose with it. Its owner's
    // inbox refuses it: it is not there.
    var held = lastEmit(&fx);
    fx.tables.destroy(fx.tables.findHandleByName(held.action_palette.emit.reply.inbox).?);
    try std.testing.expectEqual(sequencer_mod.Applied.retry, applyAppCommand(&fx, &held));
    try ensureReplyInboxes(&fx);
    try std.testing.expect(!action_palette.canPresent(&fx.tables, &fx.atoms));

    // Presented while the answer is held, the prompt is refused: its owner hears so.
    fx.resetCommands();
    action_palette.request(&fx.mem, &fx.tables, .{ .present = .{ .completions = &completions, .reply = route } });
    try runPalette(&fx);
    try std.testing.expect(!action_palette.requestOpen(&fx.tables, &fx.atoms));
    try std.testing.expect(lastEmit(&fx).action_palette.emit.kind == .completed);

    try std.testing.expectEqual(sequencer_mod.Applied.done, applyAppCommand(&fx, &held));
    try std.testing.expect(action_palette.canPresent(&fx.tables, &fx.atoms));
    action_palette.request(&fx.mem, &fx.tables, .{ .present = .{ .completions = &completions, .reply = route } });
    try runPalette(&fx);
    try std.testing.expect(action_palette.requestOpen(&fx.tables, &fx.atoms));
}

test "a chosen completion survives reuse of its arena, queued or held for queue space" {
    var fx: Fixture = undefined;
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    fx.resetCommands();
    const allocator = try action_palette.completionAllocator(&fx.mem, .figure);
    const entries = try allocator.alloc(action_palette.Completion, 1);
    entries[0] = .{ .key = try allocator.dupe(u8, "k"), .label = try allocator.dupe(u8, "chosen"), .detail = try allocator.dupe(u8, "d") };
    const completions = try allocator.create(action_palette.Completions);
    completions.* = .{ .owner = fx.atoms.intern("test_prompt"), .presentation = .prompt, .entries = entries };
    const route = testReply(fx.atoms.intern("test_reply"));
    action_palette.request(&fx.mem, &fx.tables, .{ .present = .{ .completions = completions, .reply = route } });
    try runPalette(&fx);

    // Enter queues the response, once the text editor reports the text; a toggle earlier in
    // the batch then rebuilds the same arena.
    fx.resetCommands();
    try paletteKey(&fx, action_palette.Msg.submit);
    try editorReport(&fx, "");
    action_palette.resetCompletionArena(&fx.mem, .figure);
    @memset(try allocator.alloc(u8, 256), 0xee);
    try std.testing.expect(action_palette.canPresent(&fx.tables, &fx.atoms));

    // Its owner's inbox refuses it first: it is not there.
    var held = lastEmit(&fx);
    const owner_inbox = fx.tables.findHandleByName(held.action_palette.emit.reply.inbox).?;
    fx.tables.destroy(owner_inbox);
    try std.testing.expectEqual(sequencer_mod.Applied.retry, applyAppCommand(&fx, &held));
    try ensureReplyInboxes(&fx);
    try std.testing.expect(!action_palette.requestOpen(&fx.tables, &fx.atoms));
    try std.testing.expect(!action_palette.canPresent(&fx.tables, &fx.atoms));

    try std.testing.expectEqual(sequencer_mod.Applied.done, applyAppCommand(&fx, &held));
    try std.testing.expect(action_palette.canPresent(&fx.tables, &fx.atoms));
    var delivered: ?action_palette.Msg.Event = null;
    while (takeInboxMessage(&fx)) |received| delivered = try action_palette.eventOf(received);
    try std.testing.expectEqualStrings("chosen", delivered.?.completion.?.label);
    try std.testing.expectEqualStrings("k", delivered.?.completion.?.key);
    try std.testing.expectEqualStrings("d", delivered.?.completion.?.detail);
    fx.resetCommands();
    action_palette.resetCompletionArena(&fx.mem, .figure);
}

/// The prompt's text editor reports its text as the palette's text followed by `count` typed
/// letters, as when they were typed into it.
/// The open prompt's text, as the palette holds it.
fn promptText(fx: *Fixture) []const u8 {
    return action_palette.promptText(&fx.tables, &fx.atoms);
}

/// Puts `text` in the prompt as if it had been typed there, the cursor after it.
fn setPromptText(fx: *Fixture, text: []const u8) !void {
    const palette = fx.tables.findByName(Atom.from(action_palette.table_name)).?;
    const prompt = action_palette.prompt(&fx.tables, &fx.atoms);
    try palette.assignString(prompt.text, text);
    prompt.cursor.* = @intCast(text.len);
}

fn reportTyped(fx: *Fixture, count: usize) !void {
    const before = promptText(fx);
    const text = try std.testing.allocator.alloc(u8, before.len + count);
    defer std.testing.allocator.free(text);
    @memcpy(text[0..before.len], before);
    for (text[before.len..], 0..) |*byte, index| byte.* = 'a' + @as(u8, @intCast(index % 26));
    try editorReport(fx, text);
}

test "prompt text of any length is kept whole and cancels with all of it" {
    var fx: Fixture = undefined;
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    fx.resetCommands();
    const route = testReply(fx.atoms.intern("test_reply"));
    const seed = "s" ** (2 * action_palette.kBufSize);
    const entries = [_]action_palette.Completion{.{ .label = "only" }};
    const completions = action_palette.Completions{ .owner = fx.atoms.intern("long_prompt"), .presentation = .prompt, .initial_query = seed, .entries = &entries };
    action_palette.request(&fx.mem, &fx.tables, .{ .present = .{ .completions = &completions, .reply = route } });
    try runPalette(&fx);
    const s = action_palette.prompt(&fx.tables, &fx.atoms);
    try std.testing.expectEqualStrings(seed, promptText(&fx));

    // Far longer still, and each change reports the whole text.
    const typed = 3 * action_palette.kBufSize;
    fx.resetCommands();
    try reportTyped(&fx, typed);
    try std.testing.expectEqual(@as(usize, seed.len + typed), promptText(&fx).len);
    try std.testing.expectEqual(@as(u32, seed.len + typed), s.cursor.*);
    try dispatchEditorCommands(&fx);
    var last_change: ?action_palette.Msg.Event = null;
    while (takeInboxMessage(&fx)) |received| last_change = try action_palette.eventOf(received);
    try std.testing.expectEqualStrings(promptText(&fx), last_change.?.query);

    // A cancelled prompt's response carries its text after the prompt has let it go.
    const expected = try std.testing.allocator.dupe(u8, promptText(&fx));
    defer std.testing.allocator.free(expected);
    action_palette.request(&fx.mem, &fx.tables, .{ .cancel = .{ .owner = completions.owner } });
    try dispatchEditorCommands(&fx);
    const cancelled = try action_palette.eventOf(takeInboxMessage(&fx).?);
    try std.testing.expectEqual(action_palette.Msg.EventKind.completed, cancelled.kind);
    try std.testing.expect(cancelled.completion == null);
    try std.testing.expectEqualStrings(expected, cancelled.query);
    action_palette.request(&fx.mem, &fx.tables, .{ .acknowledge = .{ .owner = completions.owner } });
    try runPalette(&fx);
    try std.testing.expectEqual(@as(usize, 0), promptText(&fx).len);

    // Consecutive long prompts keep no storage of their own outside the palette's table.
    const short = action_palette.Completions{ .owner = fx.atoms.intern("short_prompt"), .presentation = .prompt, .entries = &entries };
    const scope = try fx.mem.resolvedPrivateScope(Atom.from(action_palette.completions_scope_name));
    var settled: u64 = 0;
    for (0..4) |round| {
        action_palette.request(&fx.mem, &fx.tables, .{ .present = .{ .completions = &short, .reply = route } });
        try runPalette(&fx);
        try reportTyped(&fx, typed);
        action_palette.request(&fx.mem, &fx.tables, .{ .dismiss = .{} });
        try runPalette(&fx);
        fx.resetCommands();
        const backing = scope.stats().backing.current_bytes;
        if (round == 0) settled = backing else try std.testing.expectEqual(settled, backing);
    }
}

test "a modal waiting for a cancel to settle builds nothing" {
    var fx: Fixture = undefined;
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    fx.resetCommands();
    const route = testReply(fx.atoms.intern("test_reply"));
    const cancelled = action_palette.Completions{ .owner = fx.atoms.intern("cancelled"), .presentation = .prompt, .entries = &.{} };
    action_palette.request(&fx.mem, &fx.tables, .{ .present = .{ .completions = &cancelled, .reply = route } });
    action_palette.request(&fx.mem, &fx.tables, .{ .cancel = .{ .owner = cancelled.owner } });
    try runPalette(&fx);
    try std.testing.expect(!action_palette.canPresent(&fx.tables, &fx.atoms));

    state.authoringUi(&fx.tables, &fx.atoms).modal.* = @intFromEnum(state.Modal.dirty_close);
    const allocator = try action_palette.completionAllocator(&fx.mem, .modal);
    const arena: *memory_mod.Arena = @ptrCast(@alignCast(allocator.ptr));
    const before = arena.allocatedBytes();
    for (0..8) |_| try runSystem(&fx, windows.system());
    try std.testing.expectEqual(before, arena.allocatedBytes());
    state.authoringUi(&fx.tables, &fx.atoms).modal.* = @intFromEnum(state.Modal.none);
}

test "a long prompt survives unrelated messages and takes a shorter text" {
    var fx: Fixture = undefined;
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    fx.resetCommands();
    const route = testReply(fx.atoms.intern("test_reply"));
    const seed = "a" ++ "\u{e9}" ** 150;
    const completions = action_palette.Completions{ .owner = fx.atoms.intern("long_prompt"), .presentation = .prompt, .initial_query = seed, .entries = &.{} };
    action_palette.request(&fx.mem, &fx.tables, .{ .present = .{ .completions = &completions, .reply = route } });
    try runPalette(&fx);
    const s = action_palette.prompt(&fx.tables, &fx.atoms);

    _ = lib.updateMessage(&fx.mem, &fx.tables, &fx.atoms, .{ .tag = fx.atoms.intern("unrelated_message") });
    try std.testing.expectEqualStrings(seed, promptText(&fx));
    try std.testing.expectEqual(@as(u32, seed.len), s.cursor.*);

    // The text editor holds the prompt; its report of a shorter text replaces it whole.
    fx.resetCommands();
    const shorter = seed[0 .. 1 + 2 * 100];
    try editorReport(&fx, shorter);
    try std.testing.expectEqualStrings(shorter, promptText(&fx));
    fx.resetCommands();

    // Text typed into a new prompt grows a character at a time.
    action_palette.request(&fx.mem, &fx.tables, .{ .dismiss = .{} });
    const short = action_palette.Completions{ .owner = fx.atoms.intern("short"), .presentation = .prompt, .entries = &.{} };
    action_palette.request(&fx.mem, &fx.tables, .{ .present = .{ .completions = &short, .reply = route } });
    try runPalette(&fx);
    try reportTyped(&fx, action_palette.kBufSize);
    try std.testing.expectEqual(@as(usize, action_palette.kBufSize), promptText(&fx).len);
    try reportTyped(&fx, 1);
    try std.testing.expectEqual(@as(usize, action_palette.kBufSize + 1), promptText(&fx).len);
    fx.resetCommands();
}

test "repeated action list answers take no storage and a late selection leaves a new action list's arena" {
    var fx: Fixture = undefined;
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    fx.resetCommands();
    try editorAction(&fx, .{ .tag = Atom.from("action_palette_toggle") });
    try dispatchEditorCommands(&fx);
    const rows = [_]plugin.action_api.ListEntry{.{ .id = .{ plugin.action_api.global_mode, fx.atoms.intern("row_add") }, .mode = "global", .label = "row_add", .doc = "Add a row" }};
    try deliverActionListReply(&fx, "", &rows);
    const allocator = try action_palette.completionAllocator(&fx.mem, .action_list);
    const arena: *memory_mod.Arena = @ptrCast(@alignCast(allocator.ptr));
    const settled = arena.allocatedBytes();
    for (0..8) |_| try deliverActionListReply(&fx, "", &rows);
    try std.testing.expectEqual(settled, arena.allocatedBytes());
    try std.testing.expectEqual(@as(usize, 1), action_palette.currentCompletions(&fx.tables, &fx.atoms).?.entries.len);

    const changed = [_]plugin.action_api.ListEntry{.{ .id = .{ plugin.action_api.global_mode, fx.atoms.intern("row_add") }, .mode = "global", .label = "row_add", .doc = "Changed" }};
    try deliverActionListReply(&fx, "", &changed);
    try std.testing.expect(arena.allocatedBytes() > settled);
    const live_bytes = arena.allocatedBytes();

    const event = try paletteEvent(&fx, lib.action_selected_tag, .{ .kind = .completed, .completion = null, .query = "" });
    try editorMessage(&fx, event);
    try std.testing.expectEqual(live_bytes, arena.allocatedBytes());
    fx.resetCommands();
}

test "an answered modal closes though the sync re-presents it before the answer lands" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    try initModes(&fx);
    fx.resetCommands();
    const authoring_ui = state.authoringUi(&fx.tables, &fx.atoms);
    authoring_ui.modal.* = @intFromEnum(state.Modal.conflict);
    try runSystem(&fx, windows.system());
    try dispatchEditorCommands(&fx);

    try paletteInvoke(&fx, 2);
    try runSystem(&fx, windows.system());
    try dispatchEditorCommands(&fx);
    try std.testing.expectEqual(windows.kModalOwner, action_palette.currentOwner(&fx.tables, &fx.atoms).?);

    const response = popEditorMessage(&fx);
    try editorMessage(&fx, response);
    try std.testing.expectEqual(state.Modal.none, @as(state.Modal, @enumFromInt(authoring_ui.modal.*)));
    // The re-presented dialog stayed readable through the answer, then the sync ends it.
    try std.testing.expectEqual(@as(usize, 3), action_palette.currentCompletions(&fx.tables, &fx.atoms).?.entries.len);
    try runSystem(&fx, windows.system());
    try dispatchEditorCommands(&fx);
    while (takeInboxMessage(&fx)) |_| {}
    try std.testing.expect(!action_palette.requestOpen(&fx.tables, &fx.atoms));
    try runSystem(&fx, windows.system());
    const allocator = try action_palette.completionAllocator(&fx.mem, .modal);
    const arena: *memory_mod.Arena = @ptrCast(@alignCast(allocator.ptr));
    try std.testing.expectEqual(@as(usize, 0), arena.allocatedBytes());
    fx.resetCommands();
}

test "a failed table request rebuilds a picker holding text past the row" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    try initModes(&fx);
    fx.resetCommands();
    const route = testReply(.from(windows.Msg.table_request));
    const seed = "q" ** 300;
    const completions = action_palette.Completions{ .owner = windows.kPickerOwner, .presentation = .prompt, .initial_query = seed, .entries = &.{} };
    action_palette.request(&fx.mem, &fx.tables, .{ .present = .{ .completions = &completions, .reply = route } });
    try runPalette(&fx);
    const reply: mesha.resources.TableRequestMsg = .{
        .scope = mesha.resources.applicationScope(&fx.mem),
        .id = fx.atoms.intern("missing"),
        .handle = undefined,
        .result = .not_found,
    };
    try windowsMessage(&fx, .{ .tag = .from(windows.Msg.table_request), .payload = std.mem.asBytes(&reply) });
    try std.testing.expectEqualStrings(seed, promptText(&fx));
    // The picker is rebuilt for the text it holds, as a replacement for the palette's next run.
    const requests = action_palette.Requests.of(&fx.mem, &fx.tables, action_palette.requests_table_name);
    try std.testing.expectEqual(@as(u32, 1), requests.count());
    fx.resetCommands();
}

test "a picked path that is not a figure or a log opens as text" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    const scratch = try fx.mem.tableScratchAllocator();
    try sequencer_mod.ensureInboxes(scratch, &fx.atoms, &fx.tables, &.{ .name = "open_test", .steps = &.{.{ .system = open.system() }} });
    fx.resetCommands();

    const inbox = sequencer_mod.inboxOf(open.system());
    try sequencer_mod.deliverMessage(&fx.tables, inbox, Atom.from("open_path"), "", "/home/someone/notes.txt");
    try runSystem(&fx, open.system());

    var sent: [2]plugin.text_editor_api.CmdPayload = undefined;
    const requests = plugin.text_editor_api.Requests.of(&fx.mem, &fx.tables, plugin.text_editor_api.commands_table_name).peek(&sent);
    try std.testing.expectEqual(@as(usize, 1), requests.len);
    try std.testing.expectEqualStrings("/home/someone/notes.txt", requests[0].open.path);
    // A text file names no document for the figure editor.
    try std.testing.expect(open.requested(&fx.tables) == null);
}

test "a figure outside every index opens by its path" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    const scratch = try fx.mem.tableScratchAllocator();
    try sequencer_mod.ensureInboxes(scratch, &fx.atoms, &fx.tables, &.{ .name = "open_test", .steps = &.{.{ .system = open.system() }} });
    fx.resetCommands();

    const path = "/home/someone/art/blue.mshf";
    const inbox = sequencer_mod.inboxOf(open.system());
    try sequencer_mod.deliverMessage(&fx.tables, inbox, Atom.from("open_path"), "", path);
    try runSystem(&fx, open.system());

    const wanted = open.requested(&fx.tables).?;
    try std.testing.expectEqual(open.DocumentKind.figure, wanted.kind);
    try std.testing.expectEqual(Atom.from("blue"), wanted.document);
    try std.testing.expectEqualStrings(path, wanted.path);
    // The figure canvas is asked to open it, as a request of its own and not an action, which
    // would need the figure editor's mode.
    var asked: [2]figure_workspace.Request = undefined;
    const canvas_requests = figure_workspace.Requests.of(&fx.mem, &fx.tables, figure_workspace.commands_table_name).peek(&asked);
    try std.testing.expectEqualSlices(figure_workspace.Request, &.{.open_requested}, canvas_requests);
    var names: [8]Atom = undefined;
    try std.testing.expectEqual(@as(usize, 0), invokedActions(&fx, &names).len);
}

/// The text editor's answer `result` to a listing of the directory `real_directory`, holding
/// `entries`, to the open system's inbox under `tag`, with `user_data` as the request gave it.
fn deliverListing(fx: *Fixture, inbox: Atom, tag: Atom, user_data: []const u8, result: plugin.text_editor_api.ListResult, real_directory: []const u8, entries: []const plugin.text_editor_api.ListedEntry) !void {
    const head: plugin.text_editor_api.ListedMsg = .{ .directory_len = @intCast(real_directory.len), .entry_count = @intCast(entries.len), .result = result };
    // The directory's path, then each entry as its kind's byte, its name and a 0.
    var trailing: std.ArrayListUnmanaged(u8) = .empty;
    defer trailing.deinit(std.testing.allocator);
    try trailing.appendSlice(std.testing.allocator, real_directory);
    for (entries) |entry| {
        try trailing.append(std.testing.allocator, @intFromEnum(entry.kind));
        try trailing.appendSlice(std.testing.allocator, entry.name);
        try trailing.append(std.testing.allocator, 0);
    }
    try sequencer_mod.deliverMessageCarrying(&fx.tables, inbox, tag, user_data, std.mem.asBytes(&head), trailing.items);
}

test "a table file under a plugin opens in a table window, and one elsewhere is refused" {
    var fx: Fixture = .{};
    try fx.init(std.testing.allocator);
    defer fx.deinit();
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    const resources = mesha.resources;
    const plugins = plugin.plugins;
    const text_editor_api = plugin.text_editor_api;
    const scratch = try fx.mem.tableScratchAllocator();
    try sequencer_mod.ensureInboxes(scratch, &fx.atoms, &fx.tables, &.{ .name = "open_test", .steps = &.{.{ .system = open.system() }} });
    try resources.Requests.ensure(try fx.mem.tableScratchAllocator(), &fx.atoms, &fx.tables, resources.commands_table_name);
    const plugin_rows = try plugins.ensureTable(std.testing.allocator, &fx.atoms, &fx.tables);
    // The row's directory is not named for the plugin.
    _ = try plugins.add(plugin_rows, .{ .name = fx.atoms.intern("meadow"), .directory = "/home/someone/pasture", .library = "", .origin = .loaded });
    fx.resetCommands();
    const inbox = sequencer_mod.inboxOf(open.system());
    const resource_requests = resources.Requests.of(&fx.mem, &fx.tables, resources.commands_table_name);
    const text_requests = text_editor_api.Requests.of(&fx.mem, &fx.tables, text_editor_api.commands_table_name);

    // The file's directory is asked for by its real path, the file's name riding along.
    const spelled = "/home/someone/pasture/assets/../assets/tables/world.msht";
    try sequencer_mod.deliverMessage(&fx.tables, inbox, Atom.from("open_path"), "", spelled);
    try runSystem(&fx, open.system());
    var sent: [2]text_editor_api.CmdPayload = undefined;
    const listings = text_requests.peek(&sent);
    try std.testing.expectEqual(@as(usize, 1), listings.len);
    try std.testing.expectEqualStrings("/home/someone/pasture/assets/../assets/tables", listings[0].list_directory.path);
    try std.testing.expectEqualStrings("world.msht", listings[0].list_directory.reply.user_data.bytes);
    const answer_tag = listings[0].list_directory.reply.tag;
    try std.testing.expect(open.requested(&fx.tables) == null);
    fx.resetCommands();

    // It is the plugin's assets/tables: the table window opens on its id.
    try deliverListing(&fx, inbox, answer_tag, "world.msht", .listed, "/home/someone/pasture/assets/tables", &.{});
    try runSystem(&fx, open.system());
    var asked: [2]resources.CmdPayload = undefined;
    const opened = resource_requests.peek(&asked);
    try std.testing.expectEqual(@as(usize, 1), opened.len);
    const request = opened[0].request_table;
    try std.testing.expectEqual(Atom.from("meadow_world"), request.id);
    try std.testing.expectEqualStrings("meadow_world", fx.atoms.lookup(request.id).?);
    try std.testing.expectEqual(Atom.from("inbox.table_windows"), request.reply.inbox);
    try std.testing.expectEqual(Atom.from("table_request"), request.reply.tag);
    resource_requests.reset();

    // A table file anywhere else is refused, and the person is told why.
    try deliverListing(&fx, inbox, answer_tag, "world.msht", .listed, "/home/someone/notes", &.{});
    try runSystem(&fx, open.system());
    try std.testing.expectEqual(@as(u32, 0), resource_requests.count());
    const told = text_requests.peek(&sent);
    try std.testing.expectEqual(@as(usize, 1), told.len);
    try std.testing.expectEqualStrings("A table document opens from a loaded plugin's assets/tables folder, whose code registers its schema.", told[0].message);
    fx.resetCommands();

    // A directory the text editor could not list is said to be unreadable, not refused.
    try deliverListing(&fx, inbox, answer_tag, "world.msht", .not_found, "", &.{});
    try runSystem(&fx, open.system());
    try std.testing.expectEqual(@as(u32, 0), resource_requests.count());
    const unreadable = text_requests.peek(&sent);
    try std.testing.expectEqual(@as(usize, 1), unreadable.len);
    try std.testing.expectEqualStrings("The table document's folder could not be read: it is not there.", unreadable[0].message);
    fx.resetCommands();

    // In `game`'s tables, `engine_x.msht` would be `game_engine_x`, which `game_engine` holds.
    _ = try plugins.add(plugin_rows, .{ .name = fx.atoms.intern("game"), .directory = "/home/someone/game", .library = "", .origin = .loaded });
    _ = try plugins.add(plugin_rows, .{ .name = fx.atoms.intern("game_engine"), .directory = "/home/someone/engine", .library = "", .origin = .loaded });
    try deliverListing(&fx, inbox, answer_tag, "engine_x.msht", .listed, "/home/someone/game/assets/tables", &.{});
    try runSystem(&fx, open.system());
    try std.testing.expectEqual(@as(u32, 0), resource_requests.count());
    const shadowed = text_requests.peek(&sent);
    try std.testing.expectEqual(@as(usize, 1), shadowed.len);
    try std.testing.expectEqualStrings("A table document opens from a loaded plugin's assets/tables folder, whose code registers its schema.", shadowed[0].message);
    fx.resetCommands();
}

test "the figure editor interns the id of a file it is asked to open, and an empty path loads the catalog's" {
    const allocator = std.testing.allocator;
    var fx: Fixture = .{};
    try fx.init(allocator);
    defer fx.deinit();
    const figure = mesha.figure;
    const context = figure.Context{ .memory = &fx.mem, .tables = &fx.tables, .atoms = &fx.atoms };
    try figure_runtime.init(context);
    defer figure_runtime.deinit(context) catch unreachable;
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    try mesha.panels.ensure(try fx.mem.tableScratchAllocator(), &fx.atoms, &fx.tables);
    try figure.Requests.ensure(try fx.mem.tableScratchAllocator(), &fx.atoms, &fx.tables, figure.commands_table_name);
    const scratch = try fx.mem.tableScratchAllocator();
    try sequencer_mod.ensureInboxes(scratch, &fx.atoms, &fx.tables, &.{ .name = "open_test", .steps = &.{.{ .system = open.system() }} });
    fx.resetCommands();
    const figure_requests = figure.Requests.of(&fx.mem, &fx.tables, figure.commands_table_name);
    defer figure_requests.reset();

    const path = "/home/someone/art/never_named_before.mshf";
    try sequencer_mod.deliverMessage(&fx.tables, sequencer_mod.inboxOf(open.system()), Atom.from("open_path"), "", path);
    try runSystem(&fx, open.system());
    try std.testing.expect(fx.atoms.lookup(Atom.from("never_named_before")) == null);
    try runSystem(&fx, figure_workspace.system());
    try std.testing.expectEqualStrings("never_named_before", fx.atoms.lookup(Atom.from("never_named_before")).?);
    var sent: [4]figure.HostRequest = undefined;
    const by_path = figure_requests.peek(&sent);
    try std.testing.expectEqual(@as(usize, 1), by_path.len);
    try std.testing.expectEqualStrings(path, by_path[0].authoring.payload.load_doc.path.?);
    figure_requests.reset();

    // A row naming no file asks for the catalog's.
    const open_state = fx.tables.findByName(Atom.from(open.table_name)).?;
    var rows = open_state.query(open.StateRow);
    const row = rows.next().?.view;
    row.document.* = fx.atoms.intern("blue");
    try open_state.assignString(row.path, "");
    figure_workspace.request(&fx.mem, &fx.tables, .open_requested);
    try runSystem(&fx, figure_workspace.system());
    const by_catalog = figure_requests.peek(&sent);
    try std.testing.expectEqual(@as(usize, 1), by_catalog.len);
    try std.testing.expect(by_catalog[0].authoring.payload.load_doc.path == null);
}

/// The editor with the figure runtime and the open system's inbox, for opening figures.
fn initFigureOpening(fx: *Fixture) !void {
    const figure = mesha.figure;
    try lib.init(&fx.mem, &fx.atoms, &fx.tables);
    try mesha.panels.ensure(try fx.mem.tableScratchAllocator(), &fx.atoms, &fx.tables);
    // Where the figure editor's requests go, which the figure host system makes.
    try figure.Requests.ensure(try fx.mem.tableScratchAllocator(), &fx.atoms, &fx.tables, figure.commands_table_name);
    try transport_fixture.synchronize(&fx.mem, &fx.atoms, &fx.tables);
    const scratch = try fx.mem.tableScratchAllocator();
    try sequencer_mod.ensureInboxes(scratch, &fx.atoms, &fx.tables, &.{ .name = "open_test", .steps = &.{.{ .system = open.system() }} });
    fx.resetCommands();
}

/// The index of the entry labelled `label` among the open prompt's.
fn completionIndex(fx: *Fixture, label: []const u8) !u32 {
    const completions = action_palette.currentCompletions(&fx.tables, &fx.atoms).?;
    for (completions.entries, 0..) |entry, at| {
        if (std.mem.eql(u8, entry.label, label)) return @intCast(at);
    }
    return error.TestUnexpectedResult;
}

test "figure.open asks find-file, and the path chosen loads by path" {
    const allocator = std.testing.allocator;
    var fx: Fixture = .{};
    try fx.init(allocator);
    defer fx.deinit();
    const figure = mesha.figure;
    const context = figure.Context{ .memory = &fx.mem, .tables = &fx.tables, .atoms = &fx.atoms };
    try figure_runtime.init(context);
    defer figure_runtime.deinit(context) catch unreachable;
    try initFigureOpening(&fx);
    const open_inbox = sequencer_mod.inboxOf(open.system());

    // With no figure shown, find-file opens on the working directory.
    try editorAction(&fx, .{ .tag = Atom.from("figure_open") });
    const reply = try findFileListingAsked(&fx, "");
    const entries = [_]plugin.text_editor_api.ListedEntry{ .{ .kind = .file, .name = "blue.mshf" }, .{ .kind = .directory, .name = "cast" } };
    try deliverListing(&fx, open_inbox, reply.tag, reply.user_data.bytes, .listed, "/home/someone/art", &entries);
    try runSystem(&fx, open.system());
    try dispatchEditorCommands(&fx);

    // Choosing the file loads the figure from it, by its absolute path.
    try paletteInvoke(&fx, try completionIndex(&fx, "blue.mshf"));
    try dispatchEditorCommands(&fx);
    try runSystem(&fx, open.system());
    try runSystem(&fx, figure_workspace.system());
    var sent: [4]figure.HostRequest = undefined;
    const figure_requests = figure.Requests.of(&fx.mem, &fx.tables, figure.commands_table_name);
    const loads = figure_requests.peek(&sent);
    try std.testing.expectEqual(@as(usize, 1), loads.len);
    const load = loads[0].authoring.payload.load_doc;
    try std.testing.expectEqual(Atom.from("blue"), load.doc);
    try std.testing.expectEqualStrings("/home/someone/art/blue.mshf", load.path.?);
    // No figure host takes the request here; the runtime's deinit refuses one waiting.
    figure_requests.reset();
}

/// Opens find-file with `figure_open` on the working directory, which the text editor lists as
/// `working_directory`; types `typed`, whose directory, asked as `typed_directory`, it lists as
/// `listed_directory` holding `entries`; and chooses the text as typed. The open system and the
/// figure canvas then take what was chosen.
fn chooseTypedPath(fx: *Fixture, working_directory: []const u8, typed: []const u8, typed_directory: []const u8, listed_directory: []const u8, entries: []const plugin.text_editor_api.ListedEntry) !void {
    const open_inbox = sequencer_mod.inboxOf(open.system());
    try editorAction(fx, .{ .tag = Atom.from("figure_open") });
    const opened = try findFileListingAsked(fx, "");
    try deliverListing(fx, open_inbox, opened.tag, opened.user_data.bytes, .listed, working_directory, entries);
    try runSystem(fx, open.system());
    try dispatchEditorCommands(fx);
    // Typing lists the typed directory again, and the text as typed is offered.
    try editorReport(fx, typed);
    try dispatchEditorCommands(fx);
    try runSystem(fx, open.system());
    const typing = try findFileListingAsked(fx, typed_directory);
    try deliverListing(fx, open_inbox, typing.tag, typing.user_data.bytes, .listed, listed_directory, entries);
    try runSystem(fx, open.system());
    try dispatchEditorCommands(fx);
    try paletteInvoke(fx, try completionIndex(fx, "Open the file at this path"));
    try dispatchEditorCommands(fx);
    try runSystem(fx, open.system());
    try runSystem(fx, figure_workspace.system());
}

/// The figure editor's one request to the host since its rows were last reset, which it resets.
fn onlyFigureRequest(fx: *Fixture) !mesha.figure.Payload {
    const figure = mesha.figure;
    var sent: [4]figure.HostRequest = undefined;
    const figure_requests = figure.Requests.of(&fx.mem, &fx.tables, figure.commands_table_name);
    defer figure_requests.reset();
    const asked = figure_requests.peek(&sent);
    try std.testing.expectEqual(@as(usize, 1), asked.len);
    return asked[0].authoring.payload;
}

test "a figure path find-file does not list makes a new figure that saves there" {
    const allocator = std.testing.allocator;
    var fx: Fixture = .{};
    try fx.init(allocator);
    defer fx.deinit();
    const figure = mesha.figure;
    const context = figure.Context{ .memory = &fx.mem, .tables = &fx.tables, .atoms = &fx.atoms };
    try figure_runtime.init(context);
    defer figure_runtime.deinit(context) catch unreachable;
    try initFigureOpening(&fx);
    const entries = [_]plugin.text_editor_api.ListedEntry{.{ .kind = .file, .name = "blue.mshf" }};
    const typed = "/home/someone/art/fresh.mshf";
    try chooseTypedPath(&fx, "/home/someone/art", typed, "/home/someone/art/", "/home/someone/art", &entries);
    // Made in memory with its file; nothing is written until its first save.
    const new = (try onlyFigureRequest(&fx)).new_doc;
    try std.testing.expectEqual(Atom.from("fresh"), new.doc);
    try std.testing.expectEqualStrings(typed, new.path.?);
}

test "a relative path typed in find-file makes a new figure under its listed directory" {
    const allocator = std.testing.allocator;
    var fx: Fixture = .{};
    try fx.init(allocator);
    defer fx.deinit();
    const figure = mesha.figure;
    const context = figure.Context{ .memory = &fx.mem, .tables = &fx.tables, .atoms = &fx.atoms };
    try figure_runtime.init(context);
    defer figure_runtime.deinit(context) catch unreachable;
    try initFigureOpening(&fx);
    // The prompt's text cleared to a bare name: its directory is the working directory, which
    // the text editor lists by its real path.
    try chooseTypedPath(&fx, "/work", "fresh.mshf", "", "/work", &.{});
    const new = (try onlyFigureRequest(&fx)).new_doc;
    try std.testing.expectEqualStrings("/work/fresh.mshf", new.path.?);
}

test "find-file of a new figure's own path, not yet written, shows it" {
    const allocator = std.testing.allocator;
    var fx: Fixture = .{};
    try fx.init(allocator);
    defer fx.deinit();
    const figure = mesha.figure;
    const context = figure.Context{ .memory = &fx.mem, .tables = &fx.tables, .atoms = &fx.atoms };
    try figure_runtime.init(context);
    defer figure_runtime.deinit(context) catch unreachable;
    try initFigureOpening(&fx);
    const fresh = fx.atoms.intern("fresh");
    try figure_runtime.domain.library.create(&fx.tables, &fx.atoms, .{ .scope = mesha.resources.applicationScope(fx.tables.memory), .doc = fresh, .path = "/x/fresh.mshf" });
    try transport_fixture.synchronize(&fx.mem, &fx.atoms, &fx.tables);
    fx.resetCommands();
    try chooseTypedPath(&fx, "/x", "/x/fresh.mshf", "/x/", "/x", &.{});
    const load = (try onlyFigureRequest(&fx)).load_doc;
    try std.testing.expectEqual(fresh, load.doc);
    try std.testing.expectEqualStrings("/x/fresh.mshf", load.path.?);
}

test "a path typed in find-file whose name a loaded figure has makes nothing and says so" {
    const allocator = std.testing.allocator;
    var fx: Fixture = .{};
    try fx.init(allocator);
    defer fx.deinit();
    const figure = mesha.figure;
    const context = figure.Context{ .memory = &fx.mem, .tables = &fx.tables, .atoms = &fx.atoms };
    try figure_runtime.init(context);
    defer figure_runtime.deinit(context) catch unreachable;
    try initFigureOpening(&fx);
    const blue = fx.atoms.intern("blue");
    try figure_runtime.domain.library.create(&fx.tables, &fx.atoms, .{ .scope = mesha.resources.applicationScope(fx.tables.memory), .doc = blue, .path = "/art/blue.mshf" });
    try transport_fixture.synchronize(&fx.mem, &fx.atoms, &fx.tables);
    fx.resetCommands();
    try chooseTypedPath(&fx, "/x", "/x/blue.mshf", "/x/", "/x", &.{});
    // Neither a new document nor a save of the loaded one: the person is told why.
    try std.testing.expectEqual(@as(u32, 0), figure.Requests.of(&fx.mem, &fx.tables, figure.commands_table_name).count());
    try std.testing.expectEqualStrings("No figure was made at /x/blue.mshf: a figure or sketch named blue is already open or saved.", session.statusText(&fx.tables));
}

test "figure.switch_document lists the loaded figures" {
    const allocator = std.testing.allocator;
    var fx: Fixture = .{};
    try fx.init(allocator);
    defer fx.deinit();
    const figure = mesha.figure;
    const context = figure.Context{ .memory = &fx.mem, .tables = &fx.tables, .atoms = &fx.atoms };
    try figure_runtime.init(context);
    defer figure_runtime.deinit(context) catch unreachable;
    try initFigureOpening(&fx);
    const blue = fx.atoms.intern("blue");
    try figure_runtime.domain.library.create(&fx.tables, &fx.atoms, .{ .scope = mesha.resources.applicationScope(fx.tables.memory), .doc = blue });
    try transport_fixture.synchronize(&fx.mem, &fx.atoms, &fx.tables);

    try editorAction(&fx, .{ .tag = Atom.from("figure_switch_document") });
    try dispatchEditorCommands(&fx);
    try std.testing.expect(action_palette.requestOpen(&fx.tables, &fx.atoms));
    const index = try completionIndex(&fx, "blue");
    const completions = action_palette.currentCompletions(&fx.tables, &fx.atoms).?;
    // A new document has not been saved.
    try std.testing.expectEqualStrings("Loaded, modified", completions.entries[index].detail);

    // Choosing it shows it, from the file it was loaded from.
    try paletteInvoke(&fx, index);
    try dispatchEditorCommands(&fx);
    try editorMessage(&fx, popEditorMessage(&fx));
    var sent: [4]figure.HostRequest = undefined;
    const figure_requests = figure.Requests.of(&fx.mem, &fx.tables, figure.commands_table_name);
    const loads = figure_requests.peek(&sent);
    try std.testing.expectEqual(@as(usize, 1), loads.len);
    try std.testing.expectEqual(blue, loads[0].authoring.payload.load_doc.doc);
    try std.testing.expect(loads[0].authoring.payload.load_doc.path == null);
    figure_requests.reset();
}
