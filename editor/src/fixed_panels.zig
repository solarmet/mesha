//! The editor's fixed panels: the figure editor's, the profiler, the vcs panels, the plugin
//! list and the widgets, panels that are not table windows or text windows. Which of them are
//! shown is the rows of `editor_shown_panels`, and a system of its own (`shownPanelsSystem`),
//! last in the editor's frame, declares a panel for each row every frame
//! (`plugin.panels.declare`), so showing one is adding its row (`showPanel`) and closing it
//! removing the row (`hidePanel`). What each is, and where it opens, is `fixedPanel`'s; a panel
//! that shows one thing after another, as vcs-git's diff panel does, titles its row with it
//! (`setPanelTitle`).
//!
//! The figure stage is shown as a buffer's window is: in the focused window's place
//! (`showInPlace`), and Layers, Properties and the sequencer, which open beside it, close with
//! it.
//!
//! A panel another plugin declares is that plugin's to open and draw; the editor only hides
//! and shows it (`plugin.panels.CmdPayload.hide`, `show`): closing one (`global.window_close`)
//! hides it, and `panels_show_hidden` shows them where the editor is.
const std = @import("std");
const mesha = @import("mesha");
const Atom = mesha.Atom;
const Table = mesha.Table;
const plugin = mesha.plugin;
const panels_mod = mesha.panels;
const figure = @import("figure/workspace.zig");
const profiler = @import("profiler/profiler.zig");
const vcs_git = @import("vcs/git_status.zig");
const vcs_git_diff = @import("vcs/git_diff.zig");
const plugin_list = @import("plugin_list.zig");
const vcs_p4 = @import("vcs/p4_status.zig");
const vcs_p4_diff = @import("vcs/p4_diff.zig");
const inspector = @import("inspector.zig");
const sequencer = mesha.sequencer;
const memory_mod = mesha.memory;
const editor = @import("editor.zig");
const state = @import("state.zig");
const editor_sequencer = @import("editor_sequencer.zig");
const Log = mesha.log.scope("fixed_panels");
const text_editor = plugin.text_editor_api;

const no_atom: Atom = @enumFromInt(0);

/// The stage the figure editor draws its canvas in.
pub const figure_stage = "figure_stage";

/// The tags of the actions its inbox takes.
const Msg = enum(u64) {
    panels_show_hidden = Atom.from("panels_show_hidden").value(),
    _,
};

pub const actions = [_]plugin.action_api.Def{
    .{ .name = "panels_show_hidden", .tag = @tagName(Msg.panels_show_hidden), .doc = "Show the hidden panels of other plugins, a game's among them" },
};

/// The ids of the fixed panels, `isFixedPanel`'s.
const fixed_panel_ids = [_]Atom{
    Atom.from(figure_stage),
    Atom.from(figure.outliner_id),
    Atom.from(figure.inspector_id),
    Atom.from(figure.sequencer_id),
    Atom.from(profiler.panel_name),
    vcs_git.panel,
    vcs_git_diff.panel,
    vcs_p4.panel,
    vcs_p4_diff.panel,
    plugin_list.panel,
};

/// Panels that are not table windows: the figure editor's, the profiler and vcs-git's. Widgets
/// are another kind again; see `inspector.isBuiltinWidget`.
pub fn isFixedPanel(id: Atom) bool {
    for (fixed_panel_ids) |fixed| {
        if (id == fixed) return true;
    }
    return false;
}

/// Whether the panel `id` is one the editor declares and draws: a fixed panel, a text
/// window, a widget or a table's window. Any other is another plugin's.
pub fn ownsPanel(tables: *Table.Registry, atoms: *Atom.Registry, id: Atom) bool {
    if (isFixedPanel(id)) return true;
    if (editor.text_panel.isPanel(id)) return true;
    return inspector.isPanel(tables, atoms, id);
}

/// Shows every hidden panel: each opens with the frame where its plugin's declaration puts
/// it, if its plugin still declares it. Returns how many were hidden.
fn showHiddenPanels(tables: *Table.Registry, atoms: *Atom.Registry) usize {
    if (tables.findByName(panel_state_table) == null) return 0;
    var hidden_buffer: [panels_mod.kMaxPanels]Atom = undefined;
    const hidden = panels_mod.hiddenPanels(tables, atoms, &hidden_buffer);
    for (hidden) |id| plugin.panels.request(tables.memory, tables, .{ .show = .{ .id = id } });
    return hidden.len;
}

/// The figure editor's stage, which its panels open beside.
const figure_stage_panel: plugin.panels.Open = .{ .id = Atom.from(figure_stage), .title = "Figure", .root = figure.figure_root };

/// Every fixed panel, what it is and where it opens.
const fixed_panels = [_]plugin.panels.Open{
    figure_stage_panel,
    figure.outliner_panel,
    figure.inspector_panel,
    figure.sequencer_panel,
    profiler.fixed_panel,
    vcs_git.fixed_panel,
    vcs_git_diff.fixed_panel,
    vcs_p4.fixed_panel,
    vcs_p4_diff.fixed_panel,
    plugin_list.fixed_panel,
    inspector.perf_panel,
    inspector.memory_panel,
};

/// What the fixed panel `id` is and where it opens, or null for an id that is not one. A
/// row of `editor_shown_panels` may say another panel to open beside, and another title.
fn fixedPanel(id: Atom) ?plugin.panels.Open {
    for (fixed_panels) |panel| {
        if (panel.id == id) return panel;
    }
    return null;
}

/// The figure editor's panels that open beside its stage, and close with it.
const stage_companions = [_]Atom{
    figure.outliner_panel.id,
    figure.inspector_panel.id,
    figure.sequencer_panel.id,
};

// ---- the fixed panels shown ----------------------------------------------------------------

/// A row for each fixed panel shown: this system declares a panel for it every frame, so a
/// row added shows the panel and a row removed closes it.
pub const shown_panels_table_name = "editor_shown_panels";
const shown_panels_table = Atom.from(shown_panels_table_name);

const ShownPanel = struct {
    /// The panel's id, one `fixedPanel` knows.
    id: *Atom,
    /// The panel it opens beside, in place of the one `fixedPanel` names; none keeps that.
    beside: *Atom,
    /// Whether it takes the focus as it opens, a `plugin.panels.FocusOnOpen`.
    focus: *u8,
    /// The panel's title, in place of the one `fixedPanel` gives; empty keeps that
    /// (`setPanelTitle`).
    title: []const u8,
};

/// A row's title before `setPanelTitle`: `fixedPanel`'s is kept.
const no_title: []const u8 = "";

fn shownPanels(tables: *Table.Registry) ?*Table {
    return tables.findByName(shown_panels_table);
}

fn shownRow(shown: *Table, id: Atom) ?Table.RowHandle {
    var rows = shown.readQuery(ShownPanel);
    while (rows.next()) |found| {
        if (found.view.id.* == id) return found.handle;
    }
    return null;
}

/// Whether the fixed panel `id` is shown: declared open, whether or not it has opened yet.
pub fn panelShown(tables: *Table.Registry, id: Atom) bool {
    const shown = shownPanels(tables) orelse return false;
    return shownRow(shown, id) != null;
}

/// Where a fixed panel shown by `showPanel` opens.
pub const Placement = enum {
    /// Where `fixedPanel` says.
    arranged,
    /// Beside the focused panel, which asked for it.
    beside_focused,
};

/// Shows the fixed panel `id`: it opens with the frame, by `placement`, taking the focus when
/// `focus` says so. One already shown stays where it is and takes the focus when asked. A
/// journaled system that calls this declares `editor_shown_panels` written.
pub fn showPanel(tables: *Table.Registry, atoms: *Atom.Registry, id: Atom, placement: Placement, focus: plugin.panels.FocusOnOpen) void {
    const shown = shownPanels(tables) orelse return;
    if (shownRow(shown, id) != null) {
        if (focus == .take) plugin.panels.request(tables.memory, tables, .{ .focus = .{ .id = id } });
        return;
    }
    const beside = if (placement == .beside_focused) requester(tables, atoms) else no_atom;
    addShown(shown, id, beside, focus);
}

/// Adds the row that shows the fixed panel `id`, opening beside `beside` (none: where
/// `fixedPanel` says).
fn addShown(shown: *Table, id: Atom, beside: Atom, focus: plugin.panels.FocusOnOpen) void {
    _ = shown.tryInsert(.{ .id = id, .beside = beside, .focus = @intFromEnum(focus), .title = no_title }) catch |err| {
        Log.err("shown_panel_unrecorded", .{ .@"error" = @errorName(err) });
    };
}

/// Titles the fixed panel `id` `title`, in place of the title `fixedPanel` gives it, while it
/// is shown: what it shows, as a panel showing one thing after another says. `title` is
/// copied; empty gives back `fixedPanel`'s. Nothing happens for a panel not shown, and a
/// panel shown again starts with `fixedPanel`'s. A journaled system that calls this declares
/// `editor_shown_panels` written.
pub fn setPanelTitle(tables: *Table.Registry, id: Atom, title: []const u8) void {
    const shown = shownPanels(tables) orelse return;
    const row = shownRow(shown, id) orelse return;
    shown.setString(row, "title", title) catch |err| {
        Log.err("shown_panel_title_unrecorded", .{ .@"error" = @errorName(err) });
    };
}

/// Closes the fixed panel `id`: its row goes, and the panels system closes it with the frame.
/// The figure stage takes the panels beside it, Layers, Properties and the sequencer, with
/// it, and asks the figure editor to put down what it was doing (`figure.Request.stage_closed`).
/// Nothing happens for one that is not shown. A journaled system that calls this declares
/// `editor_shown_panels` written, and the figure editor's requests when `id` may be the stage.
pub fn hidePanel(tables: *Table.Registry, id: Atom) void {
    const shown = shownPanels(tables) orelse return;
    const row = shownRow(shown, id) orelse return;
    shown.free(row);
    if (id != Atom.from(figure_stage)) return;
    if (tables.findByName(Atom.from(figure.commands_table_name)) != null) figure.request(tables.memory, tables, .stage_closed);
    for (stage_companions) |companion| {
        const companion_row = shownRow(shown, companion) orelse continue;
        shown.free(companion_row);
    }
}

/// Shows the fixed panel `id` in the focused panel's place, taking the focus, as a file
/// opened in a window replaces what the window showed (`plugin.panels.CmdPayload.replace`):
/// whatever panel is focused goes. A text window's or a table window's row goes once its panel
/// has closed, a fixed panel replaced is no longer shown, and another plugin's panel is hidden
/// (`panels_show_hidden` brings it back). With no panel focused it opens along the window's
/// edge. The focused panel is the editor's record of the focused view (`state.viewFocus`),
/// which a prompt that asked for the file did not take. One already shown only takes the
/// focus. A journaled system that calls this declares `editor_shown_panels` and the panels'
/// requests written, and reads `editor_view_focus`.
pub fn showInPlace(tables: *Table.Registry, atoms: *Atom.Registry, id: Atom) void {
    const shown = shownPanels(tables) orelse return;
    if (shownRow(shown, id) != null) {
        plugin.panels.request(tables.memory, tables, .{ .focus = .{ .id = id } });
        return;
    }
    addShown(shown, id, no_atom, .take);
    const focused = viewFocused(tables, atoms);
    if (focused == no_atom) return;
    if (shownRow(shown, focused) != null) {
        hidePanel(tables, focused);
    } else if (!ownsPanel(tables, atoms, focused)) {
        plugin.panels.request(tables.memory, tables, .{ .hide = .{ .id = focused } });
    }
    plugin.panels.request(tables.memory, tables, .{ .replace = .{ .id = focused, .by = id } });
}

/// Shows the fixed panel `id` beside the focused panel, or closes it while it is shown.
pub fn togglePanel(tables: *Table.Registry, atoms: *Atom.Registry, id: Atom) void {
    if (panelShown(tables, id)) return hidePanel(tables, id);
    showPanel(tables, atoms, id, .beside_focused, .take);
}

/// Declares the fixed panels shown, after every system that shows or closes one: so a panel
/// shown in a frame opens with that frame, as the sequencer's does when the figure editor
/// begins to animate. The editor's sequencer runs it last of the systems that draw.
pub fn shownPanelsSystem() sequencer.System {
    return .{
        .name = "shown_panels",
        .root = editor.editor_root,
        .claims = sequencer.claims_nothing,
        .access = shownPanelsAccess,
        .kernels = &.{.{ .name = "shown_panels.declare", .run = declareShown }},
    };
}

fn shownPanelsAccess(frame: *const sequencer.Frame) sequencer.Access {
    var result: sequencer.Access = .{};
    if (frame.tables.findByName(shown_panels_table) != null) result.read(shown_panels_table);
    result.writeIfPresent(frame.tables, declared_panels_table);
    // Where Layers opens depends on whether Properties is open.
    if (frame.tables.findByName(panel_state_table) != null) result.readAll(&.{ panel_nodes_table, panel_state_table });
    return result;
}

/// Declares a panel for each fixed panel shown.
fn declareShown(pass: *sequencer.Pass) !void {
    if (!pass.declares(shown_panels_table)) return;
    if (!pass.writes(declared_panels_table)) return;
    const frame = pass.frame;
    const shown = try pass.table(shown_panels_table);
    var rows = shown.readQuery(ShownPanel);
    while (rows.next()) |found| {
        const row = found.view;
        var panel = fixedPanel(row.id.*) orelse continue;
        // Layers and Properties stack right of the stage, Layers on top, whichever opens first:
        // Properties alone takes Layers' place, and Layers opens above Properties when that is
        // open already. A placement counts only as the panel opens.
        const is_layers = row.id.* == figure.outliner_panel.id;
        const is_properties = row.id.* == figure.inspector_panel.id;
        const layers_shown = shownRow(shown, figure.outliner_panel.id) != null;
        const properties_open = panels_mod.isOpen(frame.tables, frame.atoms, figure.inspector_panel.id);
        if (is_properties and !layers_shown) {
            panel.beside = figure.outliner_panel.beside;
            panel.side = figure.outliner_panel.side;
            panel.share = figure.outliner_panel.share;
        }
        if (is_layers and properties_open) {
            panel.beside = figure.inspector_panel.id;
            panel.side = .top;
            panel.share = 1 - figure.inspector_panel.share;
        }
        if (row.beside.* != no_atom) panel.beside = row.beside.*;
        if (row.title.len != 0) panel.title = row.title;
        panel.focus = std.enums.fromInt(plugin.panels.FocusOnOpen, row.focus.*) orelse .keep;
        plugin.panels.declare(frame.memory, frame.tables, panel);
    }
}

/// What `layOutNow` leaves open.
pub const FixtureLayout = enum {
    /// No panel.
    empty,
    /// The figure stage alone, with the focus.
    figure_stage,
};

/// Closes every panel and opens `layout` at once, without the command queue or a run of the
/// systems: for fixtures setting up a frame. The stage it shows is `shownPanelsSystem`'s to
/// declare from its next run.
pub fn layOutNow(tables: *Table.Registry, atoms: *Atom.Registry, layout: FixtureLayout) void {
    panels_mod.applyCmd(tables, atoms, .close_all);
    if (shownPanels(tables)) |shown| shown.clear();
    if (layout == .empty) return;
    showPanel(tables, atoms, figure_stage_panel.id, .arranged, .take);
    panels_mod.openNow(tables, atoms, figure_stage_panel);
}

/// The panel the person works in: the editor's record of the focused view while that panel is
/// open, which a prompt over it does not take; else the focused panel (`requester`).
fn viewFocused(tables: *Table.Registry, atoms: *Atom.Registry) Atom {
    if (tables.findByName(Atom.from(state.view_focus_name)) != null) {
        const id = state.viewFocus(tables, atoms).id.*;
        const open = id != no_atom and panels_mod.isOpen(tables, atoms, id);
        if (open) return id;
    }
    return requester(tables, atoms);
}

/// The panel a new one opens beside: the focused one, which asked for it. None opens it along
/// the window's edge.
pub fn requester(tables: *Table.Registry, atoms: *Atom.Registry) Atom {
    // Without the panels' state there is nothing to open beside.
    if (tables.findByName(atoms.intern(panels_mod.state_table_name)) == null) return no_atom;
    return panels_mod.focusedTarget(tables, atoms).id;
}

// ---- the tables -----------------------------------------------------------------------------

pub fn ensure(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    var shown_schema: Table.Schema = undefined;
    try shown_schema.init(scratch.allocator, atoms, 4);
    defer shown_schema.deinit();
    try shown_schema.addFieldFallible("id", Atom, .atom);
    try shown_schema.addFieldFallible("beside", Atom, .atom);
    try shown_schema.addFieldFallible("focus", u8, .int);
    try shown_schema.addFieldFallible("title", Table.String, .text_field);
    _ = try tables.ensure(&shown_schema, fixed_panels.len, atoms.intern(shown_panels_table_name), .durable);
}

// ---- the system ---------------------------------------------------------------------------

/// Takes `panels_show_hidden`.
pub fn system() sequencer.System {
    return .{
        .name = "fixed_panels",
        .names = comptime &(sequencer.enumNames(Msg) ++ [_][]const u8{shown_panels_table_name}),
        .root = editor.editor_root,
        .claims = claims,
        .access = access,
        .kernels = &.{.{ .name = "fixed_panels.take_actions", .run = takeActions }},
    };
}

fn claims(tag: Atom) bool {
    return switch (tag.to(Msg)) {
        _ => false,
        else => true,
    };
}

const panel_nodes_table = Atom.from(panels_mod.nodes_table_name);
const panel_state_table = Atom.from(panels_mod.state_table_name);
const declared_panels_table = Atom.from(plugin.panels.declared_table_name);

/// Runs only for its actions: they read what the panels hold, ask the panels to show the
/// hidden ones, and say on the message line when there are none.
fn access(frame: *const sequencer.Frame) sequencer.Access {
    const tables = frame.tables;
    var result: sequencer.Access = .{};
    result.readAll(&.{ panel_nodes_table, panel_state_table });
    result.writeIfPresent(tables, Atom.from(plugin.panels.commands_table_name));
    result.writeIfPresent(tables, Atom.from(text_editor.commands_table_name));
    return result;
}

/// Each `panels_show_hidden` of the frame.
fn takeActions(pass: *sequencer.Pass) !void {
    const frame = pass.frame;
    for (frame.messages) |received| {
        if (received.tag.to(Msg) != .panels_show_hidden) continue;
        const shown = showHiddenPanels(frame.tables, frame.atoms);
        if (shown == 0) text_editor.message(frame.memory, frame.tables, "No panel is hidden.");
    }
}

/// A test's registries: the panels and their requests, with this module's systems alone to
/// run.
const PanelsFixture = struct {
    memory: memory_mod.Memory = undefined,
    atoms: Atom.Registry = undefined,
    tables: Table.Registry = undefined,

    /// The actions' system, then the one that declares the fixed panels shown.
    fn alone() sequencer.Built(2) {
        return .{ .name = "fixed_panels_test", .steps = .{
            .{ .system = system() },
            .{ .system = shownPanelsSystem() },
        } };
    }

    fn init(fixture: *PanelsFixture) !void {
        fixture.memory.init(std.testing.allocator);
        try fixture.atoms.init(&fixture.memory);
        try fixture.tables.init(&fixture.memory, 32);
        const scratch = try fixture.memory.tableScratchAllocator();
        try panels_mod.ensure(scratch, &fixture.atoms, &fixture.tables);
        panels_mod.relayout(&fixture.tables, &fixture.atoms, .{ .w = 1280, .h = 720 });
        try plugin.panels.Requests.ensure(scratch, &fixture.atoms, &fixture.tables, plugin.panels.commands_table_name);
        try ensure(scratch, &fixture.atoms, &fixture.tables);
        try sequencer.ensure(scratch, &fixture.atoms, &fixture.tables);
        const solo = alone();
        try sequencer.ensureInboxes(scratch, &fixture.atoms, &fixture.tables, &solo.sequencer());
        // `panels_show_hidden` may say something on the message line.
        try text_editor.Requests.ensure(scratch, &fixture.atoms, &fixture.tables, text_editor.commands_table_name);
    }

    /// `tag` delivered to the system's inbox, as the actions host delivers an action, before
    /// the next `run`.
    fn deliver(fixture: *PanelsFixture, tag: Atom) !void {
        try sequencer.deliverMessage(&fixture.tables, sequencer.inboxOf(system()), tag, &.{}, &.{});
    }

    /// How many lines the person was told, which this forgets.
    fn toldCount(fixture: *PanelsFixture) usize {
        const requests = text_editor.Requests.of(&fixture.memory, &fixture.tables, text_editor.commands_table_name);
        var count: usize = 0;
        var sent: [8]text_editor.CmdPayload = undefined;
        for (requests.peek(&sent)) |request| {
            if (request == .message) count += 1;
        }
        requests.reset();
        return count;
    }

    fn deinit(fixture: *PanelsFixture) void {
        fixture.tables.deinit();
        fixture.atoms.deinit();
        fixture.memory.deinit();
    }

    /// Runs the system as the editor's sequencer does, then the panels system's part of the
    /// frame: the panels declared open and close, and the requests made are applied and
    /// forgotten.
    fn run(fixture: *PanelsFixture) void {
        const solo = alone();
        editor_sequencer.run(&fixture.memory, &fixture.atoms, &fixture.tables, &solo.sequencer(), null);
        fixture.tables.reclaimPayloads();
        _ = panels_mod.applyFrame(&fixture.memory, &fixture.tables, &fixture.atoms);
    }
};

test "the figure stage opens in the focused panel's place, and takes its companions when it closes" {
    var fixture: PanelsFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const tables = &fixture.tables;
    const atoms = &fixture.atoms;
    const stage = Atom.from(figure_stage);
    // The profiler alone, focused: a fixed panel the stage takes the place of.
    showPanel(tables, atoms, profiler.fixed_panel.id, .arranged, .take);
    fixture.run();
    try std.testing.expect(panels_mod.hasFocus(tables, atoms, profiler.fixed_panel.id));
    showInPlace(tables, atoms, stage);
    fixture.run();
    try std.testing.expect(panels_mod.isOpen(tables, atoms, stage));
    try std.testing.expect(panels_mod.hasFocus(tables, atoms, stage));
    try std.testing.expect(!panelShown(tables, profiler.fixed_panel.id));
    fixture.run();
    try std.testing.expect(!panels_mod.isOpen(tables, atoms, profiler.fixed_panel.id));

    // Layers opens beside the stage, and goes when the stage closes.
    showPanel(tables, atoms, figure.outliner_panel.id, .arranged, .keep);
    fixture.run();
    try std.testing.expect(panels_mod.isOpen(tables, atoms, figure.outliner_panel.id));
    hidePanel(tables, stage);
    fixture.run();
    try std.testing.expect(!panels_mod.isOpen(tables, atoms, stage));
    try std.testing.expect(!panels_mod.isOpen(tables, atoms, figure.outliner_panel.id));
}

test "the figure stage takes another plugin's panel's place, which is hidden until shown again" {
    var fixture: PanelsFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const tables = &fixture.tables;
    const atoms = &fixture.atoms;
    const game = Atom.from("fixed_panels_test_game");
    const stage = Atom.from(figure_stage);
    panels_mod.openNow(tables, atoms, .{ .id = game, .root = game, .owner = .game, .focus = .take });
    const game_frame = panels_mod.panelFor(tables, atoms, game).?.frame;
    showInPlace(tables, atoms, stage);
    fixture.run();
    try std.testing.expect(!panels_mod.isOpen(tables, atoms, game));
    try std.testing.expect(panels_mod.isHidden(tables, atoms, game));
    try std.testing.expect(panels_mod.hasFocus(tables, atoms, stage));
    try std.testing.expectEqual(game_frame, panels_mod.panelFor(tables, atoms, stage).?.frame);
}

test "panels_show_hidden shows another plugin's hidden panel, and says when there is none" {
    var fixture: PanelsFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const game = Atom.from("fixed_panels_test_game");
    panels_mod.openNow(&fixture.tables, &fixture.atoms, .{ .id = game, .root = game, .owner = .game });
    try std.testing.expect(!ownsPanel(&fixture.tables, &fixture.atoms, game));
    try std.testing.expect(ownsPanel(&fixture.tables, &fixture.atoms, Atom.from(figure_stage)));
    panels_mod.applyCmd(&fixture.tables, &fixture.atoms, .{ .hide = .{ .id = game } });
    try std.testing.expect(panels_mod.isHidden(&fixture.tables, &fixture.atoms, game));
    try fixture.deliver(Atom.from(Msg.panels_show_hidden));
    fixture.run();
    try std.testing.expect(!panels_mod.isHidden(&fixture.tables, &fixture.atoms, game));
    try std.testing.expectEqual(@as(usize, 0), fixture.toldCount());
    try fixture.deliver(Atom.from(Msg.panels_show_hidden));
    fixture.run();
    try std.testing.expectEqual(@as(usize, 1), fixture.toldCount());
}

test "Layers and Properties stack right of the figure stage, Layers on top, whichever opens first" {
    const orders = [_][2]Atom{
        .{ figure.outliner_panel.id, figure.inspector_panel.id },
        .{ figure.inspector_panel.id, figure.outliner_panel.id },
    };
    for (orders) |order| {
        var fixture: PanelsFixture = .{};
        try fixture.init();
        defer fixture.deinit();
        const tables = &fixture.tables;
        const atoms = &fixture.atoms;
        layOutNow(tables, atoms, .figure_stage);
        fixture.run();
        for (order) |id| {
            showPanel(tables, atoms, id, .arranged, .keep);
            fixture.run();
        }
        const stage = panels_mod.panelFor(tables, atoms, Atom.from(figure_stage)).?.frame;
        const layers = panels_mod.panelFor(tables, atoms, figure.outliner_panel.id).?.frame;
        const properties = panels_mod.panelFor(tables, atoms, figure.inspector_panel.id).?.frame;
        try std.testing.expect(layers.x >= stage.x + stage.w);
        try std.testing.expectEqual(layers.x, properties.x);
        try std.testing.expect(properties.y >= layers.y + layers.h);
        // The stage keeps the focus as they open.
        try std.testing.expect(panels_mod.hasFocus(tables, atoms, Atom.from(figure_stage)));
    }
}
