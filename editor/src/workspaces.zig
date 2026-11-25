//! Workspaces are arrangements of panels. Activating one closes every panel, and the
//! workspace shows its own: a window on `*scratch*` for text, the figure stage for the figure
//! editor, and for the app the panels that are not the editor's, a game's among them. The
//! editor starts in the text workspace, and arranges the active workspace whenever its window
//! is empty, so it is never empty for long.
//!
//! A panel another plugin declares is that plugin's to open and draw; the editor only hides
//! and shows it (`plugin.panels.CmdPayload.hide`, `show`): arranging the text or the figure
//! workspace hides every such panel that is open, arranging the app shows the hidden ones,
//! closing one (`global.window_close`) hides it, and `panels_show_hidden` shows them where
//! the editor is.
//!
//! The figure editor's panels, the profiler, vcs-git's two panels and the widgets are fixed panels: which of them are shown is the
//! rows of `editor_shown_panels`, and a system of its own (`shownPanelsSystem`), last in the
//! editor's frame, declares a panel for each row every frame (`plugin.panels.declare`), so showing one is adding its row (`showPanel`) and closing it
//! removing the row (`hidePanel`). What each is, and where it opens, is `fixedPanel`'s; a panel
//! that shows one thing after another, as vcs-git's diff panel does, titles its row with it
//! (`setPanelTitle`).
//!
//! The workspaces are the editor's, the active one kept in `editor_workspace` as the atom the
//! editor names it by (`Workspace`): the panels system knows none of them.
//!
//! A system (`system`) whose kernels take the workspace actions and arrange the figure
//! workspace when nothing is open (the text workspace's window is the text panels' to open,
//! `text_panel.followBuffers`; the app's, left empty, gives way to the text workspace). The
//! panel tree is the panels system's. Leaving the figure
//! workspace asks the figure editor to put down what it was doing
//! (`figure.request(.leave_workspace)`).
const std = @import("std");
const mesha = @import("mesha");
const Atom = mesha.Atom;
const Table = mesha.Table;
const plugin = mesha.plugin;
const panels_mod = mesha.panels;
const figure = @import("figure/workspace.zig");
const action_palette = @import("action_palette.zig");
const windows = @import("windows.zig");
const profiler = @import("profiler/profiler.zig");
const vcs_git = @import("vcs/git_status.zig");
const vcs_git_diff = @import("vcs/git_diff.zig");
const vcs_p4 = @import("vcs/p4_status.zig");
const vcs_p4_diff = @import("vcs/p4_diff.zig");
const inspector = @import("inspector.zig");
const sequencer = mesha.sequencer;
const memory_mod = mesha.memory;
const state = @import("state.zig");
const status_bar = @import("status_bar.zig");
const editor = @import("editor.zig");
const editor_sequencer = @import("editor_sequencer.zig");
const Log = mesha.log.scope("workspaces");
const text_editor = plugin.text_editor_api;

const no_atom: Atom = @enumFromInt(0);

/// The stage the figure editor draws its canvas in.
pub const figure_stage = "figure_stage";

/// The editor's workspaces, each the atom of its name, as `editor_workspace` keeps the active
/// one. Interned at init (the system's `names`), so tools read them as names.
pub const Workspace = enum(u64) {
    text = Atom.from("text").value(),
    app = Atom.from("app").value(),
    figure = Atom.from("figure").value(),
    _,
};

/// The active workspace. None, before the editor activates one, and a name it does not know
/// (written by a tool) read as `text`, the workspace it starts in.
pub fn activeWorkspace(tables: *Table.Registry, atoms: *Atom.Registry) Workspace {
    _ = atoms;
    const active = activeAtom(tables);
    const workspace = active.to(Workspace);
    return switch (workspace) {
        .text, .app, .figure => workspace,
        _ => .text,
    };
}

/// The tags of the actions its inbox takes. `show_world` is the editor's own name for showing
/// the game, which the app workspace answers.
const Msg = enum(u64) {
    workspace_text = Atom.from("workspace_text").value(),
    workspace_app = Atom.from("workspace_app").value(),
    workspace_figure = Atom.from("workspace_figure").value(),
    workspace_reset_layout = Atom.from("workspace_reset_layout").value(),
    show_world = Atom.from("show_world").value(),
    panels_show_hidden = Atom.from("panels_show_hidden").value(),
    _,
};

pub const actions = [_]plugin.action_api.Def{
    .{ .name = "workspace_text", .tag = @tagName(Msg.workspace_text), .doc = "Activate the Text workspace" },
    .{ .name = "workspace_app", .tag = @tagName(Msg.workspace_app), .doc = "Activate the App workspace: the panels of the other plugins" },
    .{ .name = "workspace_figure", .tag = @tagName(Msg.workspace_figure), .doc = "Activate the Figure Stage workspace" },
    .{ .name = "workspace_reset_layout", .tag = @tagName(Msg.workspace_reset_layout), .doc = "Restore the active workspace's arrangement without changing documents" },
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

/// Hides every open panel that is not the editor's, as an arrangement with no place for
/// them does. Nothing without the panels' tables.
fn hideForeignPanels(tables: *Table.Registry, atoms: *Atom.Registry) void {
    if (tables.findByName(panel_state_table) == null) return;
    var open_buffer: [panels_mod.kMaxPanels]Atom = undefined;
    const open = panels_mod.load(tables, atoms).panelIds(&open_buffer);
    for (open) |id| {
        if (ownsPanel(tables, atoms, id)) continue;
        plugin.panels.request(tables.memory, tables, .{ .hide = .{ .id = id } });
    }
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

/// The app's arrangement: none of the editor's panels. What shows there is the other
/// plugins' panels, which arranging it shows.
const app_arrangement = [_]Atom{};

/// The figure stage, Layers left of it and Properties below Layers; the sequencer joins below
/// the figure stage while the editor animates. No game stage: a figure belongs to no plugin.
const figure_arrangement = [_]Atom{ figure_stage_panel.id, figure.outliner_panel.id, figure.inspector_panel.id };

/// The fixed panels `workspace` shows, in order, each beside one shown before it. The text
/// workspace shows none here: its window on `*scratch*` is the text panels' to open.
fn arrangement(workspace: Workspace) []const Atom {
    return switch (workspace) {
        .app => &app_arrangement,
        .figure => &figure_arrangement,
        .text, _ => &.{},
    };
}

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
/// Nothing happens for one that is not shown.
pub fn hidePanel(tables: *Table.Registry, id: Atom) void {
    const shown = shownPanels(tables) orelse return;
    const row = shownRow(shown, id) orelse return;
    shown.free(row);
}

/// Shows the fixed panel `id` beside the focused panel, or closes it while it is shown.
pub fn togglePanel(tables: *Table.Registry, atoms: *Atom.Registry, id: Atom) void {
    if (panelShown(tables, id)) return hidePanel(tables, id);
    showPanel(tables, atoms, id, .beside_focused, .take);
}

/// `editor_workspace`, one row: what the workspaces system keeps of the arrangement itself.
pub const workspace_table_name = "editor_workspace";
const workspace_table = Atom.from(workspace_table_name);

const WorkspaceRow = struct {
    /// The active workspace, a `Workspace`'s atom; none until one is arranged.
    active: *Atom,
    /// How many times a workspace has been arranged. An owner of panels that an arrangement
    /// closes (a table window) notes the count it showed them in, and shows them no longer
    /// once it has moved on.
    arrangement: *u32,
};

/// The active workspace's atom as `editor_workspace` holds it; none before one is arranged,
/// and without the editor's tables.
fn activeAtom(tables: *Table.Registry) Atom {
    const table = tables.findByName(workspace_table) orelse return no_atom;
    var rows = table.readQuery(WorkspaceRow);
    const row = rows.next() orelse return no_atom;
    return row.view.active.*;
}

/// The count of arrangements so far, which `arrange` bumps: 1 at the start, and without the
/// editor's tables, so no count is the 0 a panel never shown has noted.
pub fn arrangementCount(tables: *Table.Registry) u32 {
    const first: u32 = 1;
    const table = tables.findByName(workspace_table) orelse return first;
    var rows = table.readQuery(WorkspaceRow);
    const row = rows.next() orelse return first;
    return row.view.arrangement.*;
}

/// Makes `workspace` the active one and shows its arrangement in place of every fixed panel
/// shown, counting the arrangement, so the panels that go with one go.
fn showArrangement(tables: *Table.Registry, workspace: Workspace) void {
    if (tables.findByName(workspace_table)) |table| {
        var rows = table.query(WorkspaceRow);
        if (rows.next()) |row| {
            row.view.active.* = Atom.from(workspace);
            // Never 0, which a window never shown has noted.
            row.view.arrangement.* = @max(row.view.arrangement.* +% 1, 1);
        }
    }
    const shown = shownPanels(tables) orelse return;
    shown.clear();
    for (arrangement(workspace)) |id| {
        const panel = fixedPanel(id).?;
        _ = shown.tryInsert(.{ .id = id, .beside = no_atom, .focus = @intFromEnum(panel.focus), .title = no_title }) catch |err| {
            Log.err("shown_panel_unrecorded", .{ .@"error" = @errorName(err) });
        };
    }
}

/// Closes every panel and shows `workspace`'s arrangement, which opens with the frame: the
/// app's shows the other plugins' hidden panels, and any other hides those that are open.
pub fn arrange(tables: *Table.Registry, atoms: *Atom.Registry, workspace: Workspace) void {
    plugin.panels.request(tables.memory, tables, .close_all);
    if (workspace == .app) {
        _ = showHiddenPanels(tables, atoms);
    } else {
        hideForeignPanels(tables, atoms);
    }
    showArrangement(tables, workspace);
}

/// Arranges `workspace` at once, without the command queue or a run of this system: for
/// fixtures setting up a frame. The panels it opens are the system's to declare from its next
/// run.
pub fn arrangeNow(tables: *Table.Registry, atoms: *Atom.Registry, workspace: Workspace) void {
    panels_mod.applyCmd(tables, atoms, .close_all);
    showArrangement(tables, workspace);
    for (arrangement(workspace)) |id| panels_mod.openNow(tables, atoms, fixedPanel(id).?);
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
        if (row.beside.* != no_atom) panel.beside = row.beside.*;
        if (row.title.len != 0) panel.title = row.title;
        panel.focus = std.enums.fromInt(plugin.panels.FocusOnOpen, row.focus.*) orelse .keep;
        plugin.panels.declare(frame.memory, frame.tables, panel);
    }
}

/// Keeps the window from staying empty: with nothing open, the figure workspace is arranged
/// again unless its fixed panels are shown and only yet to open, and the app workspace, which
/// has no panel of the editor's and so nothing to show once the other plugins' are gone,
/// gives way to the text workspace. The text workspace's window on `*scratch*` opens from the
/// text panels (`text_panel.followBuffers`).
pub fn ensureArranged(tables: *Table.Registry, atoms: *Atom.Registry) void {
    const tree = panels_mod.load(tables, atoms);
    if (tree.panelCount() != 0) return;
    const workspace = activeWorkspace(tables, atoms);
    if (workspace == .text) return;
    if (workspace == .app) return arrange(tables, atoms, .text);
    // Arranged already, its panels open with the frame: the window is empty only until then.
    const shown = shownPanels(tables) orelse return;
    if (shown.count() != 0) return;
    arrange(tables, atoms, workspace);
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

    var workspace_schema: Table.Schema = undefined;
    try workspace_schema.init(scratch.allocator, atoms, 2);
    defer workspace_schema.deinit();
    try workspace_schema.addFieldFallible("active", Atom, .atom);
    try workspace_schema.addFieldFallible("arrangement", u32, .int);
    _ = try tables.ensureSingleton(&workspace_schema, atoms.intern(workspace_table_name), .{ .active = no_atom, .arrangement = @as(u32, 1) }, .durable);
}

// ---- the system ---------------------------------------------------------------------------

pub fn system() sequencer.System {
    return .{
        .name = "workspaces",
        .names = comptime &(sequencer.enumNames(Msg) ++ sequencer.enumNames(Workspace) ++ [_][]const u8{ shown_panels_table_name, workspace_table_name }),
        .root = editor.editor_root,
        .claims = claims,
        .access = access,
        .kernels = &.{
            .{ .name = "workspaces.take_actions", .run = takeActions },
            .{ .name = "workspaces.arrange_empty", .run = arrangeEmpty },
        },
    };
}

fn claims(tag: Atom) bool {
    return switch (tag.to(Msg)) {
        _ => false,
        else => true,
    };
}

const palette_table = Atom.from(action_palette.table_name);
const authoring_ui_table = Atom.from(state.authoring_ui_name);
const app_state_table = Atom.from(state.app_state_name);
const panel_nodes_table = Atom.from(panels_mod.nodes_table_name);
const panel_state_table = Atom.from(panels_mod.state_table_name);
const declared_panels_table = Atom.from(plugin.panels.declared_table_name);
const figure_requests_table = Atom.from(figure.commands_table_name);
const status_bar_requests_table = Atom.from(status_bar.commands_table_name);

/// Every frame it reads what the panels hold. Its actions also read the palette and forms, and
/// write the hover they end, the figure editor's requests and the message line.
fn access(frame: *const sequencer.Frame) sequencer.Access {
    const tables = frame.tables;
    var result: sequencer.Access = .{};
    result.readAll(&.{ panel_nodes_table, panel_state_table });
    // The fixed panels shown, which arranging a workspace changes.
    result.writeIfPresent(tables, shown_panels_table);
    result.writeIfPresent(tables, workspace_table);
    // Arranging a workspace and focusing a panel ask the panels.
    result.writeIfPresent(tables, Atom.from(plugin.panels.commands_table_name));
    if (frame.messages.len == 0) return result;
    result.readAll(&.{ palette_table, authoring_ui_table });
    // Without the figure editor there is nothing to put down when its workspace is left.
    if (tables.findByName(figure_requests_table) != null) result.write(figure_requests_table);
    // The hover is cleared only where the editor keeps one.
    if (tables.findByName(app_state_table) != null) result.write(app_state_table);
    if (tables.findByName(status_bar_requests_table) != null) result.write(status_bar_requests_table);
    // `panels_show_hidden` says on the message line when no panel is hidden.
    result.writeIfPresent(tables, Atom.from(text_editor.commands_table_name));
    return result;
}

/// Each workspace action of the frame, in order.
fn takeActions(pass: *sequencer.Pass) !void {
    const frame = pass.frame;
    for (frame.messages) |received| {
        if (received.tag.to(Msg) == .panels_show_hidden) {
            const shown = showHiddenPanels(frame.tables, frame.atoms);
            if (shown == 0) text_editor.message(frame.memory, frame.tables, "No panel is hidden.");
            continue;
        }
        switchWorkspace(frame.memory, frame.tables, frame.atoms, received.tag);
    }
}

/// Keeps the window from staying empty (`ensureArranged`).
fn arrangeEmpty(pass: *sequencer.Pass) !void {
    ensureArranged(pass.frame.tables, pass.frame.atoms);
}

fn switchWorkspace(memory: *memory_mod.Memory, tables: *Table.Registry, atoms: *Atom.Registry, tag: Atom) void {
    const message = tag.to(Msg);
    if (action_palette.requestOpen(tables, atoms) or windows.isFormEditing(tables, atoms)) return;
    const active = activeWorkspace(tables, atoms);
    const target: Workspace = switch (message) {
        .workspace_text => .text,
        .workspace_app, .show_world => .app,
        .workspace_figure => .figure,
        .workspace_reset_layout => active,
        .panels_show_hidden, _ => return,
    };
    // Switching to the active workspace does nothing; resetting rearranges it.
    if (message != .workspace_reset_layout and target == active) return;
    if (active == .figure and tables.findByName(figure_requests_table) != null) figure.request(memory, tables, .leave_workspace);
    arrange(tables, atoms, target);
}

test "the figure workspace puts Layers left of its stage and Properties below Layers" {
    var fx: panels_mod.Fixture = .{};
    try fx.init();
    defer fx.deinit();
    arrangeNow(&fx.tables, &fx.atoms, .figure);
    const frame = struct {
        fn of(f: *panels_mod.Fixture, name: []const u8) panels_mod.Rect {
            return panels_mod.panelFor(&f.tables, &f.atoms, Atom.from(name)).?.frame;
        }
    }.of;
    const stage = frame(&fx, figure_stage);
    const layers = frame(&fx, figure.outliner_id);
    const properties = frame(&fx, figure.inspector_id);
    try std.testing.expect(layers.x + layers.w <= stage.x);
    try std.testing.expectEqual(layers.x, properties.x);
    try std.testing.expect(properties.y >= layers.y + layers.h);
    // The figure stage keeps the focus; the panels beside it opened without taking it.
    try std.testing.expect(panels_mod.hasFocus(&fx.tables, &fx.atoms, Atom.from(figure_stage)));
}

test "an unknown or empty workspace reads as text" {
    var fx: panels_mod.Fixture = .{};
    try fx.init();
    defer fx.deinit();
    try ensure(try fx.mem.tableScratchAllocator(), &fx.atoms, &fx.tables);
    // None is active until the editor arranges one.
    try std.testing.expectEqual(Workspace.text, activeWorkspace(&fx.tables, &fx.atoms));
    // A name the editor does not know, as a tool might write.
    const kept = fx.tables.findByName(workspace_table).?;
    var kept_rows = kept.query(WorkspaceRow);
    kept_rows.next().?.view.active.* = Atom.from("elsewhere");
    try std.testing.expectEqual(Workspace.text, activeWorkspace(&fx.tables, &fx.atoms));
    arrangeNow(&fx.tables, &fx.atoms, .figure);
    try std.testing.expectEqual(Workspace.figure, activeWorkspace(&fx.tables, &fx.atoms));
}

/// A test's registries: the panels and their requests, with the workspaces system alone to
/// run.
const WorkspaceFixture = struct {
    memory: memory_mod.Memory = undefined,
    atoms: Atom.Registry = undefined,
    tables: Table.Registry = undefined,

    /// The workspaces system, then the one that declares the fixed panels it shows.
    fn alone() sequencer.Built(2) {
        return .{ .name = "workspaces_test", .steps = .{
            .{ .system = system() },
            .{ .system = shownPanelsSystem() },
        } };
    }

    fn init(fixture: *WorkspaceFixture) !void {
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
        // An action reads the palette and the forms, and may say something on the message line.
        try action_palette.ensure(scratch, &fixture.atoms, &fixture.tables);
        try state.ensureAuthoringUi(scratch, &fixture.atoms, &fixture.tables);
        try text_editor.Requests.ensure(scratch, &fixture.atoms, &fixture.tables, text_editor.commands_table_name);
    }

    /// `tag` delivered to the system's inbox, as the actions host delivers an action, before
    /// the next `run`.
    fn deliver(fixture: *WorkspaceFixture, tag: Atom) !void {
        try sequencer.deliverMessage(&fixture.tables, sequencer.inboxOf(system()), tag, &.{}, &.{});
    }

    /// How many lines the person was told, which this forgets.
    fn toldCount(fixture: *WorkspaceFixture) usize {
        const requests = text_editor.Requests.of(&fixture.memory, &fixture.tables, text_editor.commands_table_name);
        var count: usize = 0;
        var sent: [8]text_editor.CmdPayload = undefined;
        for (requests.peek(&sent)) |request| {
            if (request == .message) count += 1;
        }
        requests.reset();
        return count;
    }

    fn deinit(fixture: *WorkspaceFixture) void {
        fixture.tables.deinit();
        fixture.atoms.deinit();
        fixture.memory.deinit();
    }

    /// Runs the system as the editor's sequencer does, then the panels system's part of the
    /// frame: the panels declared open and close, and the requests made are applied and
    /// forgotten.
    fn run(fixture: *WorkspaceFixture) void {
        const solo = alone();
        editor_sequencer.run(&fixture.memory, &fixture.atoms, &fixture.tables, &solo.sequencer(), null);
        fixture.tables.reclaimPayloads();
        _ = panels_mod.applyFrame(&fixture.memory, &fixture.tables, &fixture.atoms);
    }
};

test "arranging a workspace hides another plugin's panel, the app shows it, and so does panels_show_hidden" {
    var fixture: WorkspaceFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    // Another plugin's panel, a game's, open in the app workspace beside one of the editor's.
    const game = Atom.from("workspaces_test_game");
    arrangeNow(&fixture.tables, &fixture.atoms, .app);
    panels_mod.openNow(&fixture.tables, &fixture.atoms, .{ .id = game, .root = game, .owner = .game });
    try std.testing.expect(!ownsPanel(&fixture.tables, &fixture.atoms, game));
    try std.testing.expect(ownsPanel(&fixture.tables, &fixture.atoms, Atom.from(figure_stage)));

    try fixture.deliver(Atom.from(Msg.workspace_figure));
    fixture.run();
    try std.testing.expectEqual(Workspace.figure, activeWorkspace(&fixture.tables, &fixture.atoms));
    try std.testing.expect(panels_mod.isHidden(&fixture.tables, &fixture.atoms, game));
    try std.testing.expect(panels_mod.isOpen(&fixture.tables, &fixture.atoms, Atom.from(figure_stage)));

    try fixture.deliver(Atom.from(Msg.workspace_app));
    fixture.run();
    try std.testing.expectEqual(Workspace.app, activeWorkspace(&fixture.tables, &fixture.atoms));
    try std.testing.expect(!panels_mod.isHidden(&fixture.tables, &fixture.atoms, game));

    // Hidden again, and shown where the editor is, without a change of workspace.
    panels_mod.applyCmd(&fixture.tables, &fixture.atoms, .{ .hide = .{ .id = game } });
    try fixture.deliver(Atom.from(Msg.panels_show_hidden));
    fixture.run();
    try std.testing.expect(!panels_mod.isHidden(&fixture.tables, &fixture.atoms, game));
    try std.testing.expectEqual(@as(usize, 0), fixture.toldCount());
    // With none hidden, the person is told so.
    try fixture.deliver(Atom.from(Msg.panels_show_hidden));
    fixture.run();
    try std.testing.expectEqual(@as(usize, 1), fixture.toldCount());
}
