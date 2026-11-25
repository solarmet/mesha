//! The editor's modes: the first atom of an action's id, naming where the action is available.
//! `global`, the mode of what is about the whole editor, is `actions.global_mode`. Each mode here
//! is active while the panel that owns it has the focus, or while what it names is open, and so
//! are its ancestors by `chain`, which the editor registers with the actions system once, as it
//! starts (`registerAll`).
//!
//! Each system that draws panels keeps the modes of each of its panels in a table of its own,
//! `<owner>_panel_modes`, and asks the actions system for a panel's modes when that panel takes
//! the focus and whenever the focused panel's modes change (`syncPanelModes`). Whoever opens a
//! prompt, which suspends the focus, asks for the prompt's modes as it opens and for the modes it
//! found as it closes (`followPrompt`). No system reads another's tables of modes, but the
//! action list, which lists and invokes actions by the modes the palette found as its prompt
//! opened (`keptModes`).
const std = @import("std");
const mesha = @import("mesha");
const Atom = mesha.Atom;
const Table = mesha.Table;
const memory_mod = mesha.memory;
const sequencer = mesha.sequencer;
const panels_mod = mesha.panels;
const plugin = mesha.plugin;
const actions = plugin.action_api;
const text_editor = @import("text_editor.zig");

/// The figure editor's panels: its canvas, outliner, properties and timeline.
pub const figure = Atom.from("figure");
/// The game stage: the app's own panel, which the editor leaves its keys to.
pub const stage = Atom.from("stage");
/// A table window being browsed: moving between cells, copying, and the window's own commands.
pub const table = Atom.from("table");
/// What any text editor does, in a panel, a cell or a prompt: Emacs's fundamental mode.
pub const text = Atom.from("text");
/// A text panel: what needs a buffer and a window, such as going to a line, searching,
/// registers and macros.
pub const buffer = Atom.from("buffer");
/// A table window's cell while its text is being edited.
pub const table_cell = Atom.from("table_cell");
/// A form's field while its text is being edited.
pub const form = Atom.from("form");
/// The filter box of the profiler, of a table window or of vcs-git's log while it has the caret:
/// a plain field that offers no text editor's actions, so its keymap starts from `global`'s, not
/// `text`'s.
pub const filter = Atom.from("filter");
/// A prompt, such as the action palette, while it is open.
pub const prompt = Atom.from("prompt");
/// A text panel's incremental search while one is open.
pub const isearch = Atom.from("isearch");
/// A transient menu while one is shown (`transient.zig`), which takes every key itself.
pub const transient = Atom.from("transient");
/// A minor mode: the keys other editors share, over those of `global` and `text`.
pub const cua = Atom.from("cua");
/// A version-control panel: the mode its keys for moving through its sections, folding them,
/// its views and the work it runs live in; `vcs_git`, `vcs_git_diff`, `vcs_p4` and `vcs_p4_diff`
/// are under it.
pub const vcs = Atom.from("vcs");
/// The git panel, vcs-git, while it has the focus: git's own commands over `vcs`'s.
pub const vcs_git = Atom.from("vcs_git");
/// vcs-git's log view, a page of its query and the commits it listed, while it has the focus:
/// editing the query over `vcs_git`'s keys.
pub const vcs_log = Atom.from("vcs_log");
/// vcs-git's rebase list while it is shown: setting each commit's action, moving it, and
/// beginning or leaving the rebase, over `vcs`'s keys.
pub const vcs_rebase = Atom.from("vcs_rebase");
/// vcs-git's diff panel while it has the focus: its own moves, by line and by hunk, its folds,
/// and staging what the cursor is on, over `vcs`'s keys.
pub const vcs_git_diff = Atom.from("vcs_git_diff");
/// A text window on vcs-git's commit message buffer: finishing and cancelling the commit and
/// going through the messages written before, over `buffer`'s keys.
pub const vcs_message = Atom.from("vcs_message");
/// The Perforce panel, vcs-p4, while it has the focus: its moves, which shadow `vcs`'s so they
/// come to its own system, and Perforce's commands.
pub const vcs_p4 = Atom.from("vcs_p4");
/// vcs-p4's history, a page of its query and the changes it listed: editing the query over
/// `vcs_p4`'s keys.
pub const vcs_p4_history = Atom.from("vcs_p4_history");
/// vcs-p4's diff panel while it has the focus: its moves by line and by hunk, its folds and
/// reverting the file shown, over `vcs`'s keys, every one of which it shadows.
pub const vcs_p4_diff = Atom.from("vcs_p4_diff");
/// A text window on vcs-p4's description buffer: sending and giving up the description, over
/// `buffer`'s keys.
pub const vcs_p4_message = Atom.from("vcs_p4_message");

/// The text of every mode here, and of `global`, which the editor interns at init so an action
/// id written as text names its mode: the one list the atoms above and their texts come from.
pub const names = [_][]const u8{ "global", "figure", "stage", "table", "text", "buffer", "table_cell", "form", "filter", "prompt", "isearch", "transient", "cua", "vcs", "vcs_git", "vcs_log", "vcs_rebase", "vcs_git_diff", "vcs_message", "vcs_p4", "vcs_p4_history", "vcs_p4_diff", "vcs_p4_message" };

/// A mode of the editor's and the mode whose keymap it starts from, which makes the parent
/// active wherever the mode is.
const Inheritance = struct { mode: Atom, parent: Atom };

/// The editor's modes and their parents: `global`, which the actions system registers itself, at
/// the root, `text` under it, and what edits text in a text editor under `text`. A filter, a
/// plain field, a transient menu and a version-control panel are under `global`, vcs-git, its
/// rebase list and its diff panel under `vcs`, its log under `vcs_git`, and its commit message
/// under `buffer`; vcs-p4 and its diff panel under `vcs`, its history under `vcs_p4`, and its
/// description under `buffer`. `cua`, a minor mode, has none.
const chain = [_]Inheritance{
    .{ .mode = figure, .parent = actions.global_mode },
    .{ .mode = stage, .parent = actions.global_mode },
    .{ .mode = table, .parent = actions.global_mode },
    .{ .mode = filter, .parent = actions.global_mode },
    .{ .mode = text, .parent = actions.global_mode },
    .{ .mode = buffer, .parent = text },
    .{ .mode = table_cell, .parent = text },
    .{ .mode = form, .parent = text },
    .{ .mode = prompt, .parent = text },
    .{ .mode = isearch, .parent = prompt },
    .{ .mode = transient, .parent = actions.global_mode },
    .{ .mode = vcs, .parent = actions.global_mode },
    .{ .mode = vcs_git, .parent = vcs },
    .{ .mode = vcs_log, .parent = vcs_git },
    .{ .mode = vcs_rebase, .parent = vcs },
    .{ .mode = vcs_git_diff, .parent = vcs },
    .{ .mode = vcs_message, .parent = buffer },
    .{ .mode = vcs_p4, .parent = vcs },
    .{ .mode = vcs_p4_history, .parent = vcs_p4 },
    .{ .mode = vcs_p4_diff, .parent = vcs },
    .{ .mode = vcs_p4_message, .parent = buffer },
    .{ .mode = cua, .parent = actions.no_mode },
};

/// Asks the actions system to register each of the editor's modes with its parent, in `chain`'s
/// order: once, as the editor starts. Registering them again, as when the editor's plugin is
/// loaded again, changes nothing. The kernel that calls it declares `commands.actions` written.
pub fn registerAll(tables: *Table.Registry) void {
    for (chain) |inheritance| actions.registerMode(tables, inheritance.mode, inheritance.parent);
}

/// `full` without its leading `<mode_text>_`: the short name of an action whose longer one starts
/// with its mode; `full` itself when it does not.
pub fn shortName(mode_text: []const u8, full: []const u8) []const u8 {
    const prefix_len = mode_text.len + 1;
    if (full.len <= prefix_len) return full;
    if (!std.mem.startsWith(u8, full, mode_text) or full[mode_text.len] != '_') return full;
    return full[prefix_len..];
}

/// Whether `major` is `text` or inherits it by the parents `registry`, the table
/// `actions_mode_registry`, gives, as the modes that edit text do, a plugin's among them: `cua`'s
/// keys are over theirs. A search, whose keys are its own, does not count; nor does any mode
/// without the registry, as in a test of the editor alone.
fn inheritsText(registry: ?*Table, major: Atom) bool {
    if (major == isearch) return false;
    const rows = registry orelse return false;
    var mode = major;
    // A step for each row at most, so a cycle of parents ends the walk.
    for (0..rows.count() + 1) |_| {
        if (mode == text) return true;
        mode = registeredParent(rows, mode) orelse return false;
    }
    return false;
}

/// The parent `mode` is registered with in `registry`; null for a mode not registered.
fn registeredParent(registry: *Table, mode: Atom) ?Atom {
    var rows = registry.readQuery(actions.ModeRegistryView);
    while (rows.next()) |row| {
        if (row.view.mode.* == mode) return row.view.parent.*;
    }
    return null;
}

/// The modes of a panel or a prompt of the major mode `major`: `cua` the one minor mode when
/// `major` inherits `text` by the parents `registry` gives (`actions_mode_registry`, null when
/// there is none) and `keymap` is the common keys, none otherwise.
pub fn modesFor(major: Atom, keymap: text_editor.Keymap, registry: ?*Table) actions.Modes {
    var result: actions.Modes = .{ .major = major };
    if (keymap == .cua and inheritsText(registry, major)) {
        result.minors[0] = cua;
        result.minor_count = 1;
    }
    return result;
}

fn sameModes(a: actions.Modes, b: actions.Modes) bool {
    const a_minors = a.minorSlice();
    const b_minors = b.minorSlice();
    return a.major == b.major and std.mem.eql(Atom, a_minors, b_minors);
}

/// The modes a row keeps as `major`, `minors` and the count of `minors` that count; a count past
/// `kMaxMinorModes`, as a table edit can leave, counts as `kMaxMinorModes`.
fn modesOf(major: Atom, minors: [actions.kMaxMinorModes]Atom, minor_count: u8) actions.Modes {
    const count: u8 = @intCast(@min(minor_count, actions.kMaxMinorModes));
    return .{ .major = major, .minors = minors, .minor_count = count };
}

/// The panels' state, the setting of the keys the text editors answer, and the actions system's
/// requests: what asking for modes reads and writes, each while it is there.
fn declareAsking(access: *sequencer.Access, tables: *Table.Registry) void {
    const panel_state = Atom.from(panels_mod.state_table_name);
    if (tables.findByName(panel_state) != null) access.readAll(&.{ Atom.from(panels_mod.nodes_table_name), panel_state });
    if (tables.findByName(text_editor.settings_table) != null) access.read(text_editor.settings_table);
    const registry = Atom.from(actions.mode_registry_table);
    if (tables.findByName(registry) != null) access.read(registry);
    access.writeIfPresent(tables, Atom.from(actions.commands_table_name));
}

/// The table `actions_mode_registry`, which says which modes inherit `text`, when the system
/// declared it (`declareAsking`); null without the actions system, as in a test of the editor
/// alone.
fn modeRegistry(pass: *sequencer.Pass) !?*Table {
    const registry = Atom.from(actions.mode_registry_table);
    if (!pass.declares(registry)) return null;
    return try pass.table(registry);
}

// ---- each panel's modes -------------------------------------------------------------------

/// A row of an owner's `<owner>_panel_modes`: the modes a panel it draws has now, which it asks
/// the actions system for while that panel has the focus. Its owner writes it, whenever what
/// decides the panel's mode changes, and no one else reads it.
pub const PanelModesRow = struct {
    /// The panel's id.
    panel: Atom,
    /// The panel's major mode; `global` for a panel whose state names none.
    major: Atom,
    /// The panel's minor modes, in the order they are turned on; only the first `minor_count`
    /// count.
    minors: [actions.kMaxMinorModes]Atom,
    /// How many of `minors` count.
    minor_count: u8,
};

/// A row of an owner's `<owner>_panel_modes`, as a query gives it; see `PanelModesRow`.
pub const PanelModesView = struct {
    /// The panel's id.
    panel: *Atom,
    /// The panel's major mode.
    major: *Atom,
    /// The panel's minor modes; only the first `minor_count` count.
    minors: *[actions.kMaxMinorModes]Atom,
    /// How many of `minors` count.
    minor_count: *u8,
};

/// A row of `<owner>_panel_modes`, read-only.
pub const PanelModesReadView = Table.ReadView(PanelModesView);

/// Makes the owner's table of its panels' modes, `table_name`, room for a row per panel, unless
/// it is there.
pub fn ensurePanelModes(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry, comptime table_name: []const u8) !void {
    try atoms.tryInternAll(&.{table_name});
    var schema: Table.Schema = undefined;
    try schema.init(scratch.allocator, atoms, 4);
    defer schema.deinit();
    try schema.addFieldFallible("panel", Atom, .atom);
    try schema.addFieldFallible("major", Atom, .atom);
    try schema.addFieldFallible("minors", [actions.kMaxMinorModes]Atom, .hex);
    try schema.addFieldFallible("minor_count", u8, .int);
    _ = try tables.ensure(&schema, panels_mod.kMaxPanels, Atom.from(table_name), .durable);
}

fn modesOfRow(row: PanelModesReadView) actions.Modes {
    return modesOf(row.major.*, row.minors.*, row.minor_count.*);
}

/// Asks the actions system for `row`'s modes when its panel is `focused`, the panel that has the
/// focus now.
pub fn sendWhenFocused(row: PanelModesReadView, focused: Atom, tables: *Table.Registry) void {
    if (row.panel.* != focused) return;
    const modes = modesOfRow(row);
    actions.requestModes(tables, modes);
}

/// What `syncPanelModes` reads and writes, for the access of the system whose kernel calls it:
/// the owner's table `table_name`, the focus moves, and what asking for modes needs. Without the
/// owner's table, as in a test that does not make it, nothing is declared and nothing is synced.
pub fn declarePanelModes(access: *sequencer.Access, tables: *Table.Registry, comptime table_name: []const u8) void {
    const table_atom = comptime Atom.from(table_name);
    if (tables.findByName(table_atom) == null) return;
    access.write(table_atom);
    plugin.panels.Events.declare(access, tables, plugin.panels.events_table_name);
    declareAsking(access, tables);
}

/// A panel an owner draws, and the major mode its owner's state gives it now.
pub const PanelMajor = struct {
    /// The panel's id.
    panel: Atom,
    /// Its major mode; `global` for none of its own.
    major: Atom,
};

/// The most of the panels' events one sync reads: all the events table keeps, so a run of
/// sizes never pushes a focus move out unread.
const focus_moves_max = plugin.panels.Events.retained;

/// Keeps the owner's table `table_name` holding a row for each panel of `wanted` and no other,
/// each with the modes `modesFor` gives its major mode and the keys the text editors answer now,
/// writing it only where it changes. Then, when the focus moved since the owner last looked
/// (`events.panels`, read under the table's name) or the focused panel's row changed, asks for
/// the focused panel's modes (`sendWhenFocused`). Nothing happens when the system did not declare
/// the table (`declarePanelModes`).
pub fn syncPanelModes(pass: *sequencer.Pass, comptime table_name: []const u8, wanted: []const PanelMajor) !void {
    const table_atom = comptime Atom.from(table_name);
    if (!pass.writes(table_atom)) return;
    const tables = pass.frame.tables;
    const events = plugin.panels.Events.of(tables, plugin.panels.events_table_name);
    var told: [focus_moves_max]plugin.panels.Event = undefined;
    const taken = try events.read(pass, table_atom, &told);
    const focus_moved = for (taken) |event| {
        if (event != .resized) break true;
    } else false;
    const focused = focusedPanel(pass);
    const keymap = text_editor.keymapInUse(tables);
    const registry = try modeRegistry(pass);
    const observed = try pass.table(table_atom);
    var focused_changed = false;
    if (rowsStale(observed, wanted, keymap, registry)) {
        const owned = try pass.writeTable(table_atom);
        focused_changed = try rewriteRows(owned, wanted, keymap, registry, focused);
    }
    if (!focus_moved and !focused_changed) return;
    var rows = observed.readQuery(PanelModesView);
    while (rows.next()) |found| sendWhenFocused(found.view, focused, tables);
}

/// The panel that has the focus: none while a prompt suspends it, or without the panels, as in a
/// headless run.
fn focusedPanel(pass: *sequencer.Pass) Atom {
    const frame = pass.frame;
    if (!pass.declares(Atom.from(panels_mod.state_table_name))) return actions.no_mode;
    return panels_mod.focusedTarget(frame.tables, frame.atoms).id;
}

fn findRow(owned: *Table, panel: Atom) ?PanelModesReadView {
    var rows = owned.readQuery(PanelModesView);
    while (rows.next()) |found| {
        if (found.view.panel.* == panel) return found.view;
    }
    return null;
}

/// Whether the table holds other rows than those `wanted` gives.
fn rowsStale(owned: *Table, wanted: []const PanelMajor, keymap: text_editor.Keymap, registry: ?*Table) bool {
    if (owned.count() != wanted.len) return true;
    for (wanted) |panel| {
        const row = findRow(owned, panel.panel) orelse return true;
        const modes = modesFor(panel.major, keymap, registry);
        if (!sameModes(modesOfRow(row), modes)) return true;
    }
    return false;
}

/// Writes the rows `wanted` gives and removes the others; returns whether the `focused` panel's
/// row changed. A row the table cannot take fails the owner's kernel, which the sequencer logs
/// as the fault starts, and not each frame it repeats.
fn rewriteRows(owned: *Table, wanted: []const PanelMajor, keymap: text_editor.Keymap, registry: ?*Table, focused: Atom) !bool {
    var gone: [panels_mod.kMaxPanels]Table.RowHandle = undefined;
    var gone_count: usize = 0;
    var rows = owned.readQuery(PanelModesView);
    while (rows.next()) |found| {
        const kept = for (wanted) |panel| {
            if (panel.panel == found.view.panel.*) break true;
        } else false;
        if (kept or gone_count == gone.len) continue;
        gone[gone_count] = found.handle;
        gone_count += 1;
    }
    for (gone[0..gone_count]) |handle| owned.free(handle);

    var focused_changed = false;
    for (wanted) |panel| {
        const modes = modesFor(panel.major, keymap, registry);
        if (findRow(owned, panel.panel)) |row| {
            if (sameModes(modesOfRow(row), modes)) continue;
        }
        try writeRow(owned, panel.panel, modes);
        if (panel.panel == focused) focused_changed = true;
    }
    return focused_changed;
}

fn writeRow(owned: *Table, panel: Atom, modes: actions.Modes) !void {
    var rows = owned.query(PanelModesView);
    while (rows.next()) |found| {
        if (found.view.panel.* != panel) continue;
        found.view.major.* = modes.major;
        found.view.minors.* = modes.minors;
        found.view.minor_count.* = modes.minor_count;
        return;
    }
    const row: PanelModesRow = .{ .panel = panel, .major = modes.major, .minors = modes.minors, .minor_count = modes.minor_count };
    _ = try owned.tryInsert(row);
}

// ---- a prompt's modes ---------------------------------------------------------------------

/// The row of an opener's `<owner>_prompt_modes`, which holds one at most: the modes it asked for
/// the prompt it has open, and the modes it found as that prompt opened. Its opener writes it;
/// what picks an action for the panel the prompt was opened from reads the modes found
/// (`keptModes`).
pub const PromptModesView = struct {
    /// The major mode asked for the prompt the opener has open; none while it has none open.
    prompt: *Atom,
    /// The minor modes asked for with it; only the first `prompt_minor_count` count.
    prompt_minors: *[actions.kMaxMinorModes]Atom,
    /// How many of `prompt_minors` count.
    prompt_minor_count: *u8,
    /// The major mode the actions system had as the prompt opened, asked for again as it closes.
    kept_major: *Atom,
    /// The minor modes it had then; only the first `kept_minor_count` count.
    kept_minors: *[actions.kMaxMinorModes]Atom,
    /// How many of `kept_minors` count.
    kept_minor_count: *u8,
};

/// A row of `<owner>_prompt_modes`, read-only.
pub const PromptModesReadView = Table.ReadView(PromptModesView);

/// The modes the row's opener found as its prompt last opened: those of the panel it was opened
/// from, which an action picked from the prompt is judged by.
pub fn keptModes(row: PromptModesReadView) actions.Modes {
    return modesOf(row.kept_major.*, row.kept_minors.*, row.kept_minor_count.*);
}

fn promptModes(row: PromptModesReadView) actions.Modes {
    return modesOf(row.prompt.*, row.prompt_minors.*, row.prompt_minor_count.*);
}

/// Makes the opener's table of its prompt's modes, `table_name`, room for its one row, unless it
/// is there. The row is added as the first prompt opens.
pub fn ensurePromptModes(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry, comptime table_name: []const u8) !void {
    try atoms.tryInternAll(&.{table_name});
    var schema: Table.Schema = undefined;
    try schema.init(scratch.allocator, atoms, 6);
    defer schema.deinit();
    try schema.addFieldFallible("prompt", Atom, .atom);
    try schema.addFieldFallible("prompt_minors", [actions.kMaxMinorModes]Atom, .hex);
    try schema.addFieldFallible("prompt_minor_count", u8, .int);
    try schema.addFieldFallible("kept_major", Atom, .atom);
    try schema.addFieldFallible("kept_minors", [actions.kMaxMinorModes]Atom, .hex);
    try schema.addFieldFallible("kept_minor_count", u8, .int);
    _ = try tables.ensure(&schema, 1, Atom.from(table_name), .durable);
}

/// What `followPrompt` reads and writes, for the access of the system whose kernel calls it: the
/// opener's table `table_name`, `actions_modes`, and what asking for modes needs. Without the
/// opener's table, nothing is declared and nothing is followed.
pub fn declarePromptModes(access: *sequencer.Access, tables: *Table.Registry, comptime table_name: []const u8) void {
    const table_atom = comptime Atom.from(table_name);
    if (tables.findByName(table_atom) == null) return;
    access.write(table_atom);
    const modes_table = Atom.from(actions.modes_table);
    if (tables.findByName(modes_table) != null) access.read(modes_table);
    declareAsking(access, tables);
}

/// Follows the prompt an opener has open, of the major mode `major`, none while it has none open.
/// As one opens, keeps the modes it is opened over (`othersModes`, else `actions_modes`) and asks
/// for the prompt's: `modesFor` of `major` and the keys the text editors answer now. While it is
/// open, asks for them again whenever they change, as with the setting, and whenever another
/// system asked for modes this frame, as a panel's owner does when its panel takes the focus
/// under the prompt: those modes are kept in place of the earlier ones, and the prompt's are
/// asked for after them. As it closes, picked from or not, asks for the modes kept. The panel
/// the focus comes back to asks for its own again after that. Nothing happens when the system
/// did not declare the table (`declarePromptModes`).
pub fn followPrompt(pass: *sequencer.Pass, comptime table_name: []const u8, major: Atom) !void {
    const table_atom = comptime Atom.from(table_name);
    if (!pass.writes(table_atom)) return;
    const tables = pass.frame.tables;
    const keymap = text_editor.keymapInUse(tables);
    const registry = try modeRegistry(pass);
    const wanted: actions.Modes = if (major == actions.no_mode) .{ .major = actions.no_mode } else modesFor(major, keymap, registry);
    const observed = try pass.table(table_atom);
    var observed_rows = observed.readQuery(PromptModesView);
    const sent: actions.Modes = if (observed_rows.next()) |found| promptModes(found.view) else .{ .major = actions.no_mode };
    const was_open = sent.major != actions.no_mode;
    const queued = if (was_open or major != actions.no_mode) othersModes(pass, sent, wanted) else null;
    if (sameModes(sent, wanted) and queued == null) return;

    const owned = try pass.writeTable(table_atom);
    const row = try promptRow(owned);
    if (queued) |modes| {
        keepModes(row, modes);
    } else if (!was_open) {
        const found = try currentModes(pass);
        keepModes(row, found);
    }
    row.prompt.* = wanted.major;
    row.prompt_minors.* = wanted.minors;
    row.prompt_minor_count.* = wanted.minor_count;
    if (major == actions.no_mode) {
        const kept = modesOf(row.kept_major.*, row.kept_minors.*, row.kept_minor_count.*);
        actions.requestModes(tables, kept);
        return;
    }
    actions.requestModes(tables, wanted);
}

fn keepModes(row: PromptModesView, modes: actions.Modes) void {
    row.kept_major.* = modes.major;
    row.kept_minors.* = modes.minors;
    row.kept_minor_count.* = modes.minor_count;
}

/// The opener's one row, added when it is not there yet.
fn promptRow(owned: *Table) !PromptModesView {
    var rows = owned.query(PromptModesView);
    if (rows.next()) |found| return found.view;
    const no_minors: [actions.kMaxMinorModes]Atom = @splat(actions.no_mode);
    const handle = try owned.tryInsert(.{
        .prompt = actions.no_mode,
        .prompt_minors = no_minors,
        .prompt_minor_count = @as(u8, 0),
        .kept_major = actions.global_mode,
        .kept_minors = no_minors,
        .kept_minor_count = @as(u8, 0),
    });
    return owned.getRow(handle, PromptModesView) orelse error.MissingTable;
}

/// The modes another system asked for this frame (`queuedModes`): null when none did, or when
/// what waits is the prompt's own modes, `sent` before or `wanted` now, not yet applied.
fn othersModes(pass: *sequencer.Pass, sent: actions.Modes, wanted: actions.Modes) ?actions.Modes {
    const queued = queuedModes(pass) orelse return null;
    const own = sameModes(queued, sent) or sameModes(queued, wanted);
    return if (own) null else queued;
}

/// The modes of the last `set_modes` waiting in `commands.actions`, asked for earlier this frame,
/// as by the owner of a panel that took the focus, with a major mode of none as `global`, as
/// the actions system keeps it; null when none waits.
fn queuedModes(pass: *sequencer.Pass) ?actions.Modes {
    const frame = pass.frame;
    var queued: ?actions.Modes = null;
    var requests = actions.Requests.of(frame.memory, frame.tables, actions.commands_table_name).iterate();
    while (requests.next()) |command| switch (command) {
        .set_modes => |modes| queued = modes,
        .invoke, .enable_minor, .disable_minor, .register_mode => {},
    };
    var found = queued orelse return null;
    if (found.major == actions.no_mode) found.major = actions.global_mode;
    return found;
}

/// The modes `actions_modes` holds: `global` and none without it, as in a test of the editor
/// alone.
fn currentModes(pass: *sequencer.Pass) !actions.Modes {
    const modes_table = Atom.from(actions.modes_table);
    if (!pass.declares(modes_table)) return .{};
    const view = try pass.readSingleton(modes_table, actions.ModesView);
    return actions.currentModes(view);
}

test "shortName drops the mode's prefix only when it is one" {
    try std.testing.expectEqualStrings("undo", shortName("figure", "figure_undo"));
    try std.testing.expectEqualStrings("figure", shortName("figure", "figure"));
    try std.testing.expectEqualStrings("figurine_undo", shortName("figure", "figurine_undo"));
    try std.testing.expectEqualStrings("save", shortName("figure", "save"));
}

test "names lists the text of every mode" {
    inline for (@typeInfo(@This()).@"struct".decls) |decl| {
        const value = @field(@This(), decl.name);
        if (@TypeOf(value) != Atom) continue;
        var listed = false;
        for (names) |mode_text| listed = listed or Atom.from(mode_text) == value;
        try std.testing.expect(listed);
    }
}
