const std = @import("std");
const mesha = @import("mesha");
const ui = mesha.ui;
const chart = ui.chart;
const plugin = mesha.plugin;
const panels_mod = mesha.panels;
const panel_frame = @import("panel_frame.zig");
const table_document_mod = mesha.table_document;
const Atom = mesha.Atom;
const memory_mod = mesha.memory;
const Table = mesha.Table;
const input = mesha.input;
const os = mesha.os;
const resources = mesha.resources;
const figure = mesha.figure;
const tracker = mesha.tracker;

const table_view = @import("table_view.zig");
const grid = ui.grid;
const keybinds = mesha.keybinds;
const state = @import("state.zig");
const authoring = @import("table_authoring.zig");
const action_palette = @import("action_palette.zig");
const status_bar = @import("status_bar.zig");
const inspector = @import("inspector.zig");
const workspaces = @import("workspaces.zig");
const shared = @import("text_editor.zig");
const modes = @import("modes.zig");
const style = @import("ui/style.zig");
const button = @import("ui/button.zig");
const sequencer = mesha.sequencer;
const editor_sequencer = @import("editor_sequencer.zig");

pub const kMaxWindows: u32 = 32;
pub const kPickerOwner: Atom = Atom.from("editor.windows.picker");
pub const kModalOwner: Atom = Atom.from("editor.windows.modal");
const kPickerStateName = "editor_windows_picker_state";

pub const kTrackerOwner: Atom = Atom.from("editor.windows.tracker");
/// The longest text the picker takes as a table's id.
const kPickerIdLimit: usize = 256;

/// The tags of the messages the windows take, from their actions, drawing, subscriptions,
/// prompts and requests.
pub const Msg = enum(u64) {
    create_tracker = Atom.from("create_tracker").value(),
    delete_tracker = Atom.from("delete_tracker").value(),
    tracker_completion_reply = Atom.from("tracker_completion_reply").value(),
    picker_toggle = Atom.from("picker_toggle").value(),
    picker_completion_reply = Atom.from("picker_completion_reply").value(),
    modal_completion_reply = Atom.from("modal_completion_reply").value(),

    window_close = Atom.from("window_close").value(),
    row_add = Atom.from("row_add").value(),
    row_delete = Atom.from("row_delete").value(),
    schema_toggle = Atom.from("schema_toggle").value(),
    metadata_toggle = Atom.from("metadata_toggle").value(),
    tracker_chart_toggle = Atom.from("tracker_chart_toggle").value(),
    save = Atom.from("save").value(),
    form_char = Atom.from("form_char").value(),
    form_escape = Atom.from("form_escape").value(),
    form_save = Atom.from("form_save").value(),
    form_cancel = Atom.from("form_cancel").value(),
    form_focus_meta_key = Atom.from("form_focus_meta_key").value(),
    form_focus_meta_value = Atom.from("form_focus_meta_value").value(),

    form_tab = Atom.from("form_tab").value(),

    column_select = Atom.from("column_select").value(),

    meta_select = Atom.from("meta_select").value(),

    ctx_add = Atom.from("ctx_add").value(),
    ctx_edit = Atom.from("ctx_edit").value(),
    ctx_delete = Atom.from("ctx_delete").value(),
    meta_add = Atom.from("meta_add").value(),
    meta_edit = Atom.from("meta_edit").value(),
    meta_delete = Atom.from("meta_delete").value(),
    meta_cancel_edit = Atom.from("meta_cancel_edit").value(),
    meta_save = Atom.from("meta_save").value(),
    modal_dirty_save = Atom.from("modal_dirty_save").value(),
    modal_close_without_saving = Atom.from("modal_close_without_saving").value(),
    modal_reload = Atom.from("modal_reload").value(),
    modal_overwrite = Atom.from("modal_overwrite").value(),
    modal_cancel = Atom.from("modal_cancel").value(),

    /// Resources' answers to the windows' table requests, saves and index requests.
    table_request = Atom.from("table_request").value(),
    table_save = Atom.from("table_save").value(),
    table_index = Atom.from("table_index").value(),
    _,
};

pub const PickerError = enum(u32) { none, no_match, window_limit, invalid_id, load_failed };

pub const PickerState = struct {
    cursor: *u32,
    selected: *u32,
    error_code: *u32,

    confirm_scope: *u8,
};

const window_field_count = 30;

pub const WindowState = struct {
    id: *Atom,
    instance: *Atom,
    /// The arrangement the window was last shown in (`workspaces.arrangementCount`): its
    /// panel is declared while that is the current one, so a window closes when a workspace
    /// is arranged and stays known, with its view, until it is opened again. 0 for one never
    /// shown.
    shown_in: *u32,
    /// The panel the window opens beside, the one that asked for it; none for the window's
    /// edge.
    open_beside: *Atom,

    viewport_w: *f32,
    viewport_h: *f32,
    inspector_scroll: *u32,
    inspector_horizontal_scroll: *u32,
    inspector_row_present: *u8,
    inspector_row: *u32,
    inspector_row_generation: *u32,
    inspector_target_epoch: *u32,
    edit_present: *u8,
    edit_row: *u32,
    edit_field: *u32,
    edit_text: *Table.String,
    edit_invalid: *u8,
    edit_commit: *u8,
    edit_serial: *u32,

    inspector_committed: *u8,
    tracker_chart: *u8,

    /// How the grid is viewed; see `ui.grid.ViewOrder`.
    view_sort_column: *u32,
    view_sort_descending: *u8,
    view_hidden_columns: *u64,
    view_frozen_rows: *u32,
    view_frozen_columns: *u32,
    view_filter: *Table.String,
    view_filter_focused: *u8,
};

const WindowPayload = extern struct { row: u32, generation: u32 };

const ToolbarPayload = extern struct { row: u32, generation: u32 };

const ColumnPayload = extern struct { row: u32, generation: u32, column: u32 };

const MetaPayload = extern struct { row: u32, generation: u32, meta_row: u32, meta_generation: u32 };

fn toolbarPayload(handle: Table.RowHandle) ToolbarPayload {
    return .{ .row = handle.row, .generation = handle.generation };
}

pub const MatchKind = enum { resident, disk, create };

pub const Match = struct {
    handle: Table.Handle = .{ .index = 0, .generation = 0 },
    name: []const u8,
    kind: MatchKind = .resident,
    match_index: usize = 0,
};

pub fn init(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    const allocator = scratch.allocator;

    try state.ensureViewFocus(scratch, atoms, tables);
    try state.ensureActiveInspector(scratch, atoms, tables);
    try state.ensureAuthoringUi(scratch, atoms, tables);

    try action_palette.ensure(scratch, atoms, tables);
    try authoring.ensureTables(scratch, atoms, tables);
    try status_bar.ensure(scratch, atoms, tables);
    try @import("profiler/profiler.zig").ensure(scratch, atoms, tables);
    try @import("text_panel.zig").ensure(scratch, atoms, tables);
    try @import("open.zig").ensure(scratch, atoms, tables);
    try @import("workspaces.zig").ensure(scratch, atoms, tables);
    try @import("text_tools.zig").ensure(scratch, atoms, tables);
    try @import("vcs/runner.zig").ensure(scratch, atoms, tables);
    try @import("vcs/git_status.zig").ensure(scratch, atoms, tables);
    try @import("vcs/p4_status.zig").ensure(scratch, atoms, tables);
    try @import("document/sources.zig").ensure(scratch, atoms, tables);
    try @import("transient.zig").ensure(scratch, atoms, tables);
    try modes.ensurePanelModes(scratch, atoms, tables, panel_modes_table_name);
    try modes.ensurePromptModes(scratch, atoms, tables, prompt_modes_table_name);
    try editor_sequencer.ensure(scratch, atoms, tables);
    try ensurePickerState(scratch, atoms, tables);

    var windows_schema: Table.Schema = undefined;
    try windows_schema.init(allocator, atoms, window_field_count);
    defer windows_schema.deinit();

    windows_schema.addField("id", Atom, .atom);
    windows_schema.addField("instance", Atom, .atom);
    windows_schema.addField("viewport_w", f32, .int);
    windows_schema.addField("viewport_h", f32, .int);
    windows_schema.addField("shown_in", u32, .int);
    windows_schema.addField("open_beside", Atom, .atom);
    windows_schema.addField("inspector_scroll", u32, .int);
    windows_schema.addField("inspector_horizontal_scroll", u32, .int);
    windows_schema.addField("inspector_row_present", u8, .int);
    windows_schema.addField("inspector_row", u32, .int);
    windows_schema.addField("inspector_row_generation", u32, .int);
    windows_schema.addField("inspector_target_epoch", u32, .int);
    windows_schema.addField("edit_present", u8, .int);
    windows_schema.addField("edit_row", u32, .int);
    windows_schema.addField("edit_field", u32, .int);
    windows_schema.addField("edit_text", Table.String, .text_field);
    windows_schema.addField("edit_invalid", u8, .int);
    windows_schema.addField("edit_commit", u8, .int);
    windows_schema.addField("edit_serial", u32, .int);
    windows_schema.addField("inspector_committed", u8, .int);
    windows_schema.addField("tracker_chart", u8, .int);
    windows_schema.addField("view_sort_column", u32, .int);
    windows_schema.addField("view_sort_descending", u8, .int);
    windows_schema.addField("view_hidden_columns", u64, .hex);
    windows_schema.addField("view_frozen_rows", u32, .int);
    windows_schema.addField("view_frozen_columns", u32, .int);
    windows_schema.addField("view_filter", Table.String, .text_field);
    windows_schema.addField("view_filter_focused", u8, .int);

    _ = try tables.ensure(&windows_schema, kMaxWindows, atoms.intern(state.windows_name), .durable);
}

pub fn windows(tables: *Table.Registry, atoms: *Atom.Registry) *Table {
    return state.table(tables, atoms, state.windows_name);
}

const PickerUiState = struct {
    error_code: *u32,
    confirm_scope: *u8,
};

const picker_defaults = .{
    .error_code = @as(u32, 0),
    .confirm_scope = @as(u8, 0),
};

fn ensurePickerState(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    var schema: Table.Schema = undefined;
    try schema.init(scratch.allocator, atoms, 2);
    defer schema.deinit();
    schema.addField("error_code", u32, .int);
    schema.addField("confirm_scope", u8, .int);
    const name = atoms.intern(kPickerStateName);
    _ = try tables.ensureSingleton(&schema, name, picker_defaults, .durable);
}

pub fn picker(tables: *Table.Registry, atoms: *Atom.Registry) PickerState {
    const mb = action_palette.prompt(tables, atoms);
    const picker_table = state.table(tables, atoms, kPickerStateName);
    const picker_handle = Table.RowHandle{ .row = 0, .generation = picker_table.rowGeneration(0) };
    const local = picker_table.getRow(picker_handle, PickerUiState) orelse @panic("editor_windows_picker_state missing");
    const s = PickerState{
        .cursor = mb.cursor,
        .selected = mb.selected,
        .error_code = local.error_code,
        .confirm_scope = local.confirm_scope,
    };
    s.confirm_scope.* = if (s.confirm_scope.* == 0) 0 else 1;
    s.cursor.* = @min(s.cursor.*, mb.text.payload.len);
    if (s.error_code.* > @intFromEnum(PickerError.load_failed)) s.error_code.* = @intFromEnum(PickerError.none);
    return s;
}

/// The window's table view state. `list` is the windows' table, which holds the edit's text.
fn widgetState(list: *Table, s: WindowState) grid.State {
    return .{
        .committed = s.inspector_committed,
        .scroll = s.inspector_scroll,
        .horizontal_scroll = s.inspector_horizontal_scroll,
        .selected_present = s.inspector_row_present,
        .selected_row = s.inspector_row,
        .selected_row_generation = s.inspector_row_generation,
        .target_epoch = s.inspector_target_epoch,
        .edit_present = s.edit_present,
        .edit_row = s.edit_row,
        .edit_field = s.edit_field,
        .owner = list,
        .edit_text = s.edit_text,
        .edit_invalid = s.edit_invalid,
        .edit_commit = s.edit_commit,
        .edit_serial = s.edit_serial,
        .sort_column = s.view_sort_column,
        .sort_descending = s.view_sort_descending,
        .hidden_columns = s.view_hidden_columns,
        .frozen_rows = s.view_frozen_rows,
        .frozen_columns = s.view_frozen_columns,
        .filter = s.view_filter,
        .filter_focused = s.view_filter_focused,
    };
}

pub fn targetHandle(tables: *Table.Registry, s: WindowState) ?Table.Handle {
    return tables.findHandleByName(s.id.*);
}

pub fn targetTable(tables: *Table.Registry, s: WindowState) ?*Table {
    const target = tables.get(targetHandle(tables, s) orelse return null) orelse return null;
    return if (target.lifetime == .transient) null else target;
}

/// Each window whose table went is freed, and each other's view settled as its draw shows it:
/// the selection normalised, the scrolls kept in the lines shown and a selection that moved
/// brought into view, at the width its grid is drawn at. The draw settles a copy and writes
/// nothing, so this is where a window's view is kept as it is seen.
fn pruneAndNormalize(tables: *Table.Registry, atoms: *Atom.Registry) void {
    const list = windows(tables, atoms);
    const authoring_ui = state.authoringUi(tables, atoms);
    var row: u32 = 0;
    while (row < list.rowCapacity()) : (row += 1) {
        if (!list.isAllocated(row)) continue;
        const handle: Table.RowHandle = .{ .row = row, .generation = list.rowGeneration(row) };
        const s = list.getRow(handle, WindowState).?;
        const target = targetTable(tables, s) orelse {
            list.free(handle);
            continue;
        };
        s.instance.* = target.name;
        const scratch = tables.memory.frameScratchAllocator() catch continue;
        const grid_w = gridWidth(authoring_ui, target.name, s.viewport_w.*);
        const view = widgetState(windows(tables, atoms), s);
        const order: grid.OrderContext = .{ .atoms = atoms, .allocator = scratch.allocator };
        if (grid.settle(view, target, .table, grid_w, s.viewport_h.*, order) == .invalidated) list.free(handle);
    }
}

fn publishActiveInspector(tables: *Table.Registry, atoms: *Atom.Registry) void {
    const active = state.activeInspector(tables, atoms);
    active.focused.* = 0;
    active.table_name.* = @enumFromInt(0);
    active.row.* = 0;
    active.generation.* = 0;
    active.field_name.* = @enumFromInt(0);

    const handle = focusedHandle(tables, atoms) orelse return;
    const s = windows(tables, atoms).getRow(handle, WindowState) orelse return;
    const target = targetTable(tables, s) orelse return;
    if (s.tracker_chart.* != 0 and tracker.isDefinition(atoms, target)) return;
    const view = widgetState(windows(tables, atoms), s);
    if (view.selected_present.* == 0) return;
    const cell = Table.RowHandle{ .row = view.selected_row.*, .generation = view.selected_row_generation.* };
    if (!target.valid(cell)) return;
    const fields = target.getSchema().fields;
    if (view.edit_field.* >= fields.len) return;

    active.focused.* = 1;
    active.table_name.* = target.name;
    active.row.* = cell.row;
    active.generation.* = cell.generation;
    active.field_name.* = atoms.intern(fields[view.edit_field.*].name);
}

fn syncActiveInspector(tables: *Table.Registry, atoms: *Atom.Registry) void {
    pruneAndNormalize(tables, atoms);
    publishActiveInspector(tables, atoms);
}

pub fn isVisible(tables: *Table.Registry, atoms: *Atom.Registry) bool {
    return windows(tables, atoms).count() != 0 or pickerOpen(tables, atoms);
}

pub fn pickerOpen(tables: *Table.Registry, atoms: *Atom.Registry) bool {
    return action_palette.currentOwner(tables, atoms) == kPickerOwner;
}

pub fn focusedHandle(tables: *Table.Registry, atoms: *Atom.Registry) ?Table.RowHandle {
    const id = state.viewFocus(tables, atoms).id.*;
    const list = windows(tables, atoms);
    var row: u32 = 0;
    while (row < list.rowCapacity()) : (row += 1) {
        if (!list.isAllocated(row)) continue;
        const handle: Table.RowHandle = .{ .row = row, .generation = list.rowGeneration(row) };
        const s = list.getRow(handle, WindowState).?;
        if (s.id.* == id) return handle;
    }
    return null;
}

pub fn focusedTracker(tables: *Table.Registry, atoms: *Atom.Registry) bool {
    const handle = focusedHandle(tables, atoms) orelse return false;
    const s = windows(tables, atoms).getRow(handle, WindowState) orelse return false;
    const target = targetTable(tables, s) orelse return false;
    return tracker.isDefinition(atoms, target);
}

// ---- the inspector's text editor -----------------------------------------------------------
//
// The inspector edits text in one text editor (`table_view.inspector_editor`), which holds
// whichever has the keyboard: the focused window's cell edit, or the open form's focused text
// field (an open form holds the keyboard over the table). When that changes, the editor is
// pointed at the new owner: its text, look and caret. Leaving an owner whose edit is still
// open first waits for the editor's report of its last text, which goes back to the owner, so
// a cell edit left in another window, or a field Tab moved off, keeps everything typed.
//
// While a cell edits, its keys are the text editor's actions and the cell's own, bound in
// `table_cell_keys`; while a form field edits, the form's own, bound in `form_keys`. Each
// owner's mode inherits `text`, and its keys win over the text editor's for the same chord.

/// A cell's own actions while it edits, of the mode `modes.table_cell`.
pub const cell_actions = [_]plugin.action_api.Def{
    .{ .name = "commit_down", .tag = "cell_commit_down", .doc = "Commit the cell and edit the one below" },
    .{ .name = "commit_up", .tag = "cell_commit_up", .doc = "Commit the cell and move up" },
    .{ .name = "commit_next", .tag = "cell_commit_next", .doc = "Commit the cell and move to the next" },
    .{ .name = "commit_previous", .tag = "cell_commit_previous", .doc = "Commit the cell and move to the previous" },
    .{ .name = "cancel", .tag = "cell_cancel", .doc = "Stop editing the cell, keeping its value" },
    .{ .name = "clear", .tag = "cell_clear", .doc = "Clear the cell's text" },
};

/// The keymap of `table_cell`, over the text editor's: the keys of `cell_actions`, as Org's table
/// keys are while a field is edited, and Org's `M-a` and `M-e` for the start and end of the text.
pub const table_cell_keys = [_]keybinds.KeyDef{
    .{ .chord = "enter", .action = .{ "table_cell", "commit_down" } },
    .{ .chord = "kp_enter", .action = .{ "table_cell", "commit_down" } },
    .{ .chord = "S-enter", .action = .{ "table_cell", "commit_up" } },
    .{ .chord = "tab", .action = .{ "table_cell", "commit_next" } },
    .{ .chord = "S-tab", .action = .{ "table_cell", "commit_previous" } },
    .{ .chord = "escape", .action = .{ "table_cell", "cancel" } },
    .{ .chord = "C-g", .action = .{ "table_cell", "cancel" } },
    .{ .chord = "C-c SPC", .action = .{ "table_cell", "clear" } },
    .{ .chord = "M-a", .action = .{ "text", "line_begin" } },
    .{ .chord = "M-e", .action = .{ "text", "line_end" } },
};

/// The table view's message for each cell action, in `cell_actions` order.
const cell_action_messages = [_]grid.Msg{ .commit_down, .commit_up, .commit_tab, .commit_backtab, .cancel, .delete };

/// A form's own actions while one of its text fields has the keyboard, of the mode
/// `modes.form`.
pub const form_actions = [_]plugin.action_api.Def{
    .{ .name = "next", .tag = "form_field_next", .doc = "Move to the form's next field" },
    .{ .name = "submit", .tag = "form_field_submit", .doc = "Submit the form" },
    .{ .name = "close", .tag = "form_field_close", .doc = "Close the form without submitting it" },
};

/// The keys of the mode `form`, over the text editor's: those of `form_actions`, and of the
/// form's own commands `form.save` and `form.cancel`, which the editor offers
/// (`editor.editor_actions`) and the table windows take.
pub const form_keys = [_]keybinds.KeyDef{
    .{ .chord = "M-escape", .action = .{ "form", "cancel" } },
    .{ .chord = "M-enter", .action = .{ "form", "save" } },
    .{ .chord = "tab", .action = .{ "form", "next" } },
    .{ .chord = "enter", .action = .{ "form", "submit" } },
    .{ .chord = "kp_enter", .action = .{ "form", "submit" } },
    .{ .chord = "escape", .action = .{ "form", "close" } },
};

/// What the editor holds or should: a window's cell edit (its instance and the edit's serial),
/// or a form field (its `FormFocus`).
const TextOwner = struct {
    kind: state.InspectorTextOwner = .none,
    id: u64 = 0,
    serial: u32 = 0,

    fn eql(a: TextOwner, b: TextOwner) bool {
        return a.kind == b.kind and a.id == b.id and a.serial == b.serial;
    }
};

fn loadedOwner(authoring_ui: state.AuthoringUiView) TextOwner {
    const kind = std.enums.fromInt(state.InspectorTextOwner, authoring_ui.text_owner_kind.*) orelse .none;
    return .{ .kind = kind, .id = authoring_ui.text_owner.*, .serial = authoring_ui.text_owner_serial.* };
}

fn cellOwner(s: WindowState) TextOwner {
    return .{ .kind = .cell, .id = @intFromEnum(s.instance.*), .serial = s.edit_serial.* };
}

/// The text field the form's focus is on, if it is one and no modal holds the keyboard.
fn focusedTextField(authoring_ui: state.AuthoringUiView) ?state.FormFocus {
    if (@as(state.Modal, @enumFromInt(authoring_ui.modal.*)) != .none) return null;
    const focus = std.enums.fromInt(state.FormFocus, authoring_ui.form_focus.*) orelse return null;
    _ = fieldTarget(authoring_ui, focus) orelse return null;
    return focus;
}

/// Whether the focused window is editing a cell with the keyboard. An open form or modal holds
/// the keyboard over the table, so a cell edit under it waits.
pub fn isCellEditing(tables: *Table.Registry, atoms: *Atom.Registry) bool {
    if (action_palette.requestOpen(tables, atoms)) return false;
    if (isFormEditing(tables, atoms)) return false;
    const handle = focusedHandle(tables, atoms) orelse return false;
    const s = windows(tables, atoms).getRow(handle, WindowState) orelse return false;
    return grid.isEditing(widgetState(windows(tables, atoms), s));
}

/// Whether a form's text field has the keyboard.
pub fn isFormTextEditing(tables: *Table.Registry, atoms: *Atom.Registry) bool {
    if (action_palette.requestOpen(tables, atoms)) return false;
    return focusedTextField(state.authoringUi(tables, atoms)) != null;
}

/// What should have the editor now. The action palette over everything leaves it as it is.
fn wantedOwner(tables: *Table.Registry, atoms: *Atom.Registry) TextOwner {
    const authoring_ui = state.authoringUi(tables, atoms);
    if (action_palette.requestOpen(tables, atoms)) return loadedOwner(authoring_ui);
    if (focusedTextField(authoring_ui)) |field| return .{ .kind = .form_field, .id = @intFromEnum(field) };
    if (isFormEditing(tables, atoms)) return .{};
    const handle = focusedHandle(tables, atoms) orelse return .{};
    const s = windows(tables, atoms).getRow(handle, WindowState) orelse return .{};
    if (!grid.isEditing(widgetState(windows(tables, atoms), s))) return .{};
    return cellOwner(s);
}

const WindowRefOfEditor = struct { handle: Table.RowHandle, state: WindowState };

/// The window whose cell edit `owner` is, while that edit is still open.
fn windowOfOwner(tables: *Table.Registry, atoms: *Atom.Registry, owner: TextOwner) ?WindowRefOfEditor {
    if (owner.kind != .cell) return null;
    const list = windows(tables, atoms);
    var row: u32 = 0;
    while (row < list.rowCapacity()) : (row += 1) {
        if (!list.isAllocated(row)) continue;
        const handle: Table.RowHandle = .{ .row = row, .generation = list.rowGeneration(row) };
        const s = list.getRow(handle, WindowState) orelse continue;
        if (!cellOwner(s).eql(owner) or s.edit_present.* == 0) continue;
        return .{ .handle = handle, .state = s };
    }
    return null;
}

/// Whether `owner`'s edit is still open, so leaving it waits for its last text.
fn ownerLive(tables: *Table.Registry, atoms: *Atom.Registry, owner: TextOwner) bool {
    return switch (owner.kind) {
        .none => false,
        .cell => windowOfOwner(tables, atoms, owner) != null,
        .form_field => isFormEditing(tables, atoms),
    };
}

/// Whether the editor holds `s`'s current cell edit, so typing and commits go through it.
fn editorHoldsCell(tables: *Table.Registry, atoms: *Atom.Registry, s: WindowState) bool {
    if (s.edit_present.* == 0) return false;
    return loadedOwner(state.authoringUi(tables, atoms)).eql(cellOwner(s));
}

fn cellUpdateContext(tables: *Table.Registry, atoms: *Atom.Registry, handle: Table.RowHandle, s: WindowState) table_view.UpdateContext {
    const grid_w = gridWidth(state.authoringUi(tables, atoms), s.instance.*, s.viewport_w.*);
    return .{ .viewport_w = grid_w, .viewport_h = s.viewport_h.*, .tables = tables, .atoms = atoms, .incarnation = handle.generation, .editor_loaded = editorHoldsCell(tables, atoms, s), .reply_inbox = sequencer.inboxOf(system()) };
}

/// Points the editor at `owner`: its text, the caret at its end.
fn loadOwner(tables: *Table.Registry, atoms: *Atom.Registry, owner: TextOwner) void {
    const authoring_ui = state.authoringUi(tables, atoms);
    authoring_ui.text_owner_kind.* = @intFromEnum(owner.kind);
    authoring_ui.text_owner.* = owner.id;
    authoring_ui.text_owner_serial.* = owner.serial;
    authoring_ui.text_switch_pending.* = 0;
    const editor = table_view.inspector_editor;
    const text: []const u8 = switch (owner.kind) {
        .none => return,
        .cell => blk: {
            const found = windowOfOwner(tables, atoms, owner) orelse return;
            const edit = widgetState(windows(tables, atoms), found.state);
            break :blk grid.editText(edit);
        },
        .form_field => blk: {
            const field = std.enums.fromInt(state.FormFocus, owner.id) orelse return;
            const target = fieldTarget(authoring_ui, field) orelse return;
            break :blk authoringTable(tables, atoms).textOf(target.*);
        },
    };
    plugin.text_editor_api.request(tables.memory, tables, .{ .set_text = .{ .buffer = editor, .text = text } });
    plugin.text_editor_api.request(tables.memory, tables, .{ .run = .{ .buffer = editor, .command = .document_end } });
    authoring_ui.text_scroll_x.* = 0;
}

/// Forgets what the editor holds without waiting for its text, as a form reset by opening
/// does: what the editor held of its fields is dropped.
fn forgetInspectorText(authoring_ui: state.AuthoringUiView) void {
    authoring_ui.text_owner_kind.* = @intFromEnum(state.InspectorTextOwner.none);
    authoring_ui.text_switch_pending.* = 0;
    authoring_ui.form_submit_pending.* = 0;
}

/// Each frame: keeps the editor on what has the keyboard.
fn updateInspectorEditor(tables: *Table.Registry, atoms: *Atom.Registry) void {
    const authoring_ui = state.authoringUi(tables, atoms);
    const loaded = loadedOwner(authoring_ui);
    const wanted = wantedOwner(tables, atoms);
    if (!loaded.eql(wanted)) {
        if (ownerLive(tables, atoms, loaded)) {
            if (authoring_ui.text_switch_pending.* == 0) {
                authoring_ui.text_switch_pending.* = 1;
                plugin.text_editor_api.request(tables.memory, tables, .{ .mark_saved = table_view.inspector_editor });
            }
            return;
        }
        loadOwner(tables, atoms, wanted);
    }
}

/// The editor reported its text: give it to its owner, finish what waited for it (a cell's
/// commit, a form's submit), then, if the owner was being left, load the next.
fn onInspectorText(tables: *Table.Registry, atoms: *Atom.Registry, text: []const u8) void {
    const authoring_ui = state.authoringUi(tables, atoms);
    const owner = loadedOwner(authoring_ui);
    switch (owner.kind) {
        .none => {},
        .cell => if (windowOfOwner(tables, atoms, owner)) |found| {
            if (targetTable(tables, found.state)) |target| {
                const context = cellUpdateContext(tables, atoms, found.handle, found.state);
                if (context.gridContext()) |grid_context| {
                    const result = grid.editorReport(widgetState(windows(tables, atoms), found.state), .table, text, target, grid_context);
                    if (result == .mutated) authoring.markDirty(tables, atoms, target.name);
                }
            }
        },
        .form_field => if (isFormEditing(tables, atoms)) {
            const field = std.enums.fromInt(state.FormFocus, owner.id) orelse return;
            const target = fieldTarget(authoring_ui, field) orelse return;
            // A text that cannot be kept leaves the field as it was, and nothing is submitted.
            authoringTable(tables, atoms).assignString(target, text) catch {
                authoring_ui.form_submit_pending.* = 0;
                authoring.setStatus(authoringTable(tables, atoms), authoring_ui, "Not enough memory for the field's text", .{});
                return;
            };
            if (authoring_ui.form_submit_pending.* != 0) {
                authoring_ui.form_submit_pending.* = 0;
                if (focusedHandle(tables, atoms)) |handle| {
                    if (windows(tables, atoms).getRow(handle, WindowState)) |s| submitForm(tables, atoms, authoring_ui, s);
                }
            }
        },
    }
    if (authoring_ui.text_switch_pending.* != 0) loadOwner(tables, atoms, wantedOwner(tables, atoms));
}

/// Lists, while a cell edits, the cell's actions and the text editor's, both capturing their
/// keys, as the edit's typing does.
pub fn pushCellEditorActions(tables: *Table.Registry, atoms: *Atom.Registry, sink: plugin.ActionSink) void {
    if (!isCellEditing(tables, atoms)) return;
    pushOwnerActions(atoms, sink, modes.table_cell, &cell_actions);
}

/// Lists, while a form's text field has the keyboard, the form's actions and the text
/// editor's, both capturing their keys.
pub fn pushFormEditorActions(tables: *Table.Registry, atoms: *Atom.Registry, sink: plugin.ActionSink) void {
    if (!isFormTextEditing(tables, atoms)) return;
    pushOwnerActions(atoms, sink, modes.form, &form_actions);
}

/// An owner's own actions, of the mode `mode`, and the text editor's, all capturing their keys.
fn pushOwnerActions(atoms: *Atom.Registry, sink: plugin.ActionSink, mode: Atom, owner_actions: []const plugin.action_api.Def) void {
    const inbox = sequencer.inboxOf(system());
    for (owner_actions) |def| {
        keybinds.pushActionDefinitions(atoms, sink, mode, inbox, &.{.{ .def = def, .capture = true }});
    }
    shared.pushActions(atoms, sink, .captured, system());
}

/// Takes the cell's and form's actions, and the text editor's actions
/// while a cell or form field has the keyboard. Returns false for other messages, and an error
/// for an edit command action whose command it cannot read.
fn handleInspectorEditor(tables: *Table.Registry, atoms: *Atom.Registry, received: sequencer.Message) !bool {
    const tag = received.tag;
    const authoring_ui = state.authoringUi(tables, atoms);
    const is_cell_action = for (cell_actions) |def| {
        if (tag == Atom.from(def.tag)) break true;
    } else false;
    const is_form_action = for (form_actions) |def| {
        if (tag == Atom.from(def.tag)) break true;
    } else false;
    const is_editor_action = tag == shared.command_tag or tag == shared.save_tag or tag == shared.leave_tag;
    if (!is_cell_action and !is_form_action and !is_editor_action) return false;
    const wanted = wantedOwner(tables, atoms);
    switch (wanted.kind) {
        .none => return false,
        .form_field => {
            if (is_cell_action) return false;
            if (tag == shared.command_tag) {
                // Until the editor holds the field, it holds something else: the key is dropped.
                if (!loadedOwner(authoring_ui).eql(wanted)) return true;
                const command = try shared.commandOf(received);
                plugin.text_editor_api.request(tables.memory, tables, .{ .run = .{ .buffer = table_view.inspector_editor, .command = command } });
            } else if (tag == Atom.from("form_field_next")) {
                cycleFormFocus(authoring_ui);
            } else if (tag == Atom.from("form_field_submit") or tag == shared.save_tag) {
                const handle = focusedHandle(tables, atoms) orelse return true;
                const s = windows(tables, atoms).getRow(handle, WindowState) orelse return true;
                requestFormSubmit(tables, atoms, authoring_ui, s);
            } else {
                // form_field_close, or the text editor's leave.
                closeForm(authoring_ui);
            }
            return true;
        },
        .cell => {
            if (is_form_action) return false;
            const handle = focusedHandle(tables, atoms) orelse return false;
            const s = windows(tables, atoms).getRow(handle, WindowState) orelse return false;
            const target = targetTable(tables, s) orelse return false;
            const instance = s.instance.*;
            const context = cellUpdateContext(tables, atoms, handle, s);
            if (tag == shared.command_tag) {
                if (!context.editor_loaded) return true;
                const command = try shared.commandOf(received);
                plugin.text_editor_api.request(tables.memory, tables, .{ .run = .{ .buffer = table_view.inspector_editor, .command = command } });
                return true;
            }
            // Saving belongs to the table, not the cell; leaving is the cell's cancel.
            if (tag == shared.save_tag) return true;
            const message: grid.Msg = if (tag == shared.leave_tag) .cancel else for (cell_actions, cell_action_messages) |def, cell_message| {
                if (tag == Atom.from(def.tag)) break cell_message;
            } else return true;
            const result = table_view.updateMessage(widgetState(windows(tables, atoms), s), instance, .table, message, target, context);
            if (result == .mutated) authoring.markDirty(tables, atoms, target.name);
            if (result == .invalidated) windows(tables, atoms).free(handle);
            return true;
        },
    }
}

/// The editor's drawing for `field`, while it holds that field.
fn fieldEditor(tables: *Table.Registry, ui_state: state.AuthoringUiView, field: state.FormFocus) ?shared.FieldDrawable {
    const owner: TextOwner = .{ .kind = .form_field, .id = @intFromEnum(field) };
    if (!loadedOwner(ui_state).eql(owner)) return null;
    if (ui_state.form_focus.* != @intFromEnum(field)) return null;
    const look: shared.FieldLook = .{ .text = style.col.text, .caret = style.col.accent_bright };
    return shared.fieldDrawable(tables, table_view.inspector_editor, look, ui_state.text_scroll_x);
}

/// The editor's drawing for `s`'s cell edit, while it holds that edit, kept in `scratch` for
/// the grid to draw through the tree's commit.
fn cellEditor(scratch: memory_mod.Scratch, tables: *Table.Registry, atoms: *Atom.Registry, s: WindowState) ?grid.CellDrawable {
    if (!editorHoldsCell(tables, atoms, s)) return null;
    const authoring_ui = state.authoringUi(tables, atoms);
    const look: shared.FieldLook = .{ .text = style.col.text, .caret = style.col.accent_bright };
    const found = shared.fieldDrawable(tables, table_view.inspector_editor, look, authoring_ui.text_scroll_x) orelse return null;
    const kept = scratch.allocator.create(shared.FieldDrawable) catch return null;
    kept.* = found;
    return grid.CellDrawable.of(kept);
}

/// Asks to submit the open form: once the editor's report of the field it holds arrives, or at
/// once when it holds none of the form's.
fn requestFormSubmit(tables: *Table.Registry, atoms: *Atom.Registry, authoring_ui: state.AuthoringUiView, s: WindowState) void {
    if (loadedOwner(authoring_ui).kind != .form_field) {
        submitForm(tables, atoms, authoring_ui, s);
        return;
    }
    authoring_ui.form_submit_pending.* = 1;
    plugin.text_editor_api.request(tables.memory, tables, .{ .mark_saved = table_view.inspector_editor });
}

/// Submits the open form, a metadata entry, which validates what it holds.
fn submitForm(tables: *Table.Registry, atoms: *Atom.Registry, authoring_ui: state.AuthoringUiView, s: WindowState) void {
    if (isMetaFormOpen(authoring_ui)) handleMetaSave(tables, atoms, authoring_ui, s);
}

/// Closes the open form, or the modal over it.
fn closeForm(authoring_ui: state.AuthoringUiView) void {
    if (@as(state.Modal, @enumFromInt(authoring_ui.modal.*)) != .none) {
        authoring_ui.modal.* = @intFromEnum(state.Modal.none);
    } else {
        authoring_ui.form_focus.* = 0;
    }
}
pub fn isTextEditing(tables: *Table.Registry, atoms: *Atom.Registry) bool {
    if (pickerOpen(tables, atoms)) return true;
    const handle = focusedHandle(tables, atoms) orelse return false;
    const s = windows(tables, atoms).getRow(handle, WindowState) orelse return false;
    return grid.isEditing(widgetState(windows(tables, atoms), s));
}

fn lessMatch(_: void, a: Match, b: Match) bool {
    if (a.kind == .create and b.kind != .create) return false;
    if (a.kind != .create and b.kind == .create) return true;
    if (a.match_index != b.match_index) return a.match_index < b.match_index;
    const kind_rank = struct {
        fn rank(k: MatchKind) u8 {
            return switch (k) {
                .resident => 0,
                .disk => 1,
                .create => 2,
            };
        }
    }.rank;
    if (kind_rank(a.kind) != kind_rank(b.kind)) return kind_rank(a.kind) < kind_rank(b.kind);
    return std.ascii.lessThanIgnoreCase(a.name, b.name);
}

fn substringIndex(name: []const u8, query: []const u8) ?usize {
    if (query.len == 0) return 0;
    return std.ascii.indexOfIgnoreCase(name, query);
}

pub fn collectMatches(scratch: memory_mod.Scratch, tables: *Table.Registry, atoms: *Atom.Registry, query: []const u8) ![]Match {
    const allocator = scratch.allocator;
    var result: std.ArrayListUnmanaged(Match) = .empty;
    errdefer result.deinit(allocator);
    var seen: std.ArrayListUnmanaged(Atom) = .empty;
    defer seen.deinit(allocator);
    var exact_match = false;

    const handles = try allocator.alloc(Table.Handle, tables.capacity);
    defer allocator.free(handles);
    for (tables.activeHandles(handles)) |handle| {
        const candidate = tables.get(handle) orelse continue;
        const name = atoms.lookup(candidate.name) orelse continue;

        if (std.mem.startsWith(u8, name, ".staging.")) continue;

        const match_index = substringIndex(name, query) orelse continue;
        if (query.len == name.len) exact_match = true;
        try seen.append(allocator, candidate.name);
        if (candidate.lifetime == .transient) continue;
        try result.append(allocator, .{ .handle = handle, .name = name, .kind = .resident, .match_index = match_index });
    }

    if (tables.findByName(atoms.intern(resources.table_assets_name))) |assets| {
        var q = assets.query(resources.TableAssetView);
        while (q.next()) |item| {
            const id_name = atoms.lookup(item.view.id.*) orelse continue;
            if (@as(resources.TableAssetState, @enumFromInt(item.view.state.*)) == .attached and item.view.disk_present.* == 0) continue;
            if (!table_document_mod.validId(id_name)) continue;
            const match_index = substringIndex(id_name, query) orelse continue;
            if (query.len == id_name.len) exact_match = true;
            var resident = false;
            for (seen.items) |n| if (n == item.view.id.*) {
                resident = true;
                break;
            };
            if (resident) continue;
            try result.append(allocator, .{ .name = id_name, .kind = .disk, .match_index = match_index });
        }
    }

    if (query.len > 0 and !exact_match and table_document_mod.validId(query)) {
        const collide_resident = tables.findHandleByName(atoms.intern(query)) != null;
        // Figure family names are reserved: RPC routes them to documents, so a table created
        // under one would be unreachable by name.
        const reserved = figure.isDocumentTableName(query);
        if (!collide_resident and !reserved) try result.append(allocator, .{ .name = query, .kind = .create, .match_index = 0 });
    }

    std.mem.sort(Match, result.items, {}, lessMatch);
    return result.toOwnedSlice(allocator);
}

const PickerCompletionKind = enum(u8) { match, scope_confirm, scope_cancel };
const PickerCompletionData = extern struct { action: u8, table: Table.Handle, kind: u32, id: Atom };

fn pickerCompletionData(completion: *const action_palette.Completion) PickerCompletionData {
    return std.mem.bytesToValue(PickerCompletionData, completion.data[0..@sizeOf(PickerCompletionData)]);
}

fn makePickerCompletions(scratch: memory_mod.Scratch, allocator: std.mem.Allocator, tables: *Table.Registry, atoms: *Atom.Registry, query: []const u8, picker_state: PickerState) !*action_palette.Completions {
    const matches = try collectMatches(scratch, tables, atoms, query);
    defer scratch.allocator.free(matches);
    const entries = try allocator.alloc(action_palette.Completion, matches.len);
    for (matches, 0..) |match, i| {
        const id: Atom = if (match.kind == .resident) blk: {
            if (tables.get(match.handle)) |table| break :blk table.name;
            break :blk atoms.intern(match.name);
        } else atoms.intern(match.name);
        const label = switch (match.kind) {
            .resident => match.name,
            .disk => try std.fmt.allocPrint(allocator, "{s}  (on disk)", .{match.name}),
            .create => try std.fmt.allocPrint(allocator, "Create {s}", .{match.name}),
        };
        var data = std.mem.zeroes([action_palette.kCompletionDataSize]u8);
        var payload = std.mem.zeroes(PickerCompletionData);
        payload.action = @intFromEnum(PickerCompletionKind.match);
        payload.table = match.handle;
        payload.kind = @intFromEnum(match.kind);
        payload.id = id;
        @memcpy(data[0..@sizeOf(PickerCompletionData)], std.mem.asBytes(&payload));
        // Tab makes the text the table's id, which the label may add words to.
        entries[i] = .{ .label = label, .data = data, .completes_to = match.name };
    }
    const picker_error: PickerError = @enumFromInt(picker_state.error_code.*);
    const body: []const u8 = if (picker_error != .none) switch (picker_error) {
        .none => unreachable,
        .no_match => "No matching table",
        .window_limit => "Inspector window limit reached (32)",
        .invalid_id => "Invalid id (a-z, digits, '-', '_', '.')",
        .load_failed => "Could not load that table",
    } else if (matches.len == 0 and query.len > 0)
        "No matching table"
    else
        "";
    const completions = try allocator.create(action_palette.Completions);
    completions.* = .{
        .owner = kPickerOwner,
        .presentation = .prompt,
        .prompt = "Find table: ",
        .initial_query = query,
        .body = body,
        .entries = entries,
    };
    try action_palette.ownRequestText(allocator, completions);
    return completions;
}

fn queuePickerRequest(memory: *memory_mod.Memory, scratch: memory_mod.Scratch, tables: *Table.Registry, atoms: *Atom.Registry, query: []const u8) void {
    const allocator = action_palette.completionAllocator(memory, .picker) catch return;
    const completions = makePickerCompletions(scratch, allocator, tables, atoms, query, picker(tables, atoms)) catch return;
    action_palette.request(memory, tables, .{ .present = .{ .completions = completions, .reply = replyTo(.picker_completion_reply) } });
}

fn replacePickerCompletions(memory: *memory_mod.Memory, scratch: memory_mod.Scratch, tables: *Table.Registry, atoms: *Atom.Registry, query: []const u8) void {
    const allocator = action_palette.completionAllocator(memory, .picker) catch return;
    const completions = makePickerCompletions(scratch, allocator, tables, atoms, query, picker(tables, atoms)) catch return;
    action_palette.request(memory, tables, .{ .replace = .{ .completions = completions } });
}

fn openPickerRequest(memory: *memory_mod.Memory, scratch: memory_mod.Scratch, tables: *Table.Registry, atoms: *Atom.Registry, query: []const u8) void {
    const s = picker(tables, atoms);
    s.confirm_scope.* = 0;
    queuePickerRequest(memory, scratch, tables, atoms, query);
}

fn closePicker(s: PickerState) void {
    s.error_code.* = @intFromEnum(PickerError.none);
    s.confirm_scope.* = 0;
}

fn handlePickerCompletionEvent(memory: *memory_mod.Memory, scratch: memory_mod.Scratch, tables: *Table.Registry, atoms: *Atom.Registry, event: action_palette.Msg.Event) void {
    const s = picker(tables, atoms);
    if (event.kind == .query_changed) {
        if (action_palette.currentOwner(tables, atoms) == kPickerOwner)
            replacePickerCompletions(memory, scratch, tables, atoms, event.query);
        return;
    }

    var reopen = false;
    if (event.completion) |completion| {
        const data = pickerCompletionData(&completion);
        switch (@as(PickerCompletionKind, @enumFromInt(data.action))) {
            .match => {
                const kind: MatchKind = @enumFromInt(data.kind);
                const match = Match{ .handle = data.table, .name = atoms.lookup(data.id) orelse "", .kind = kind };
                chooseMatch(tables, atoms, match, s);
                reopen = kind != .resident or s.error_code.* != @intFromEnum(PickerError.none);
                if (s.confirm_scope.* != 0) reopen = false;
            },
            .scope_confirm => {
                // Longer text is no valid id, and interning keeps it for good.
                if (event.query.len > kPickerIdLimit) {
                    s.error_code.* = @intFromEnum(PickerError.invalid_id);
                } else if (event.query.len > 0) {
                    const scope = resources.applicationScope(tables.memory);
                    resources.request(tables.memory, tables, .{ .create_table = .{
                        .scope = scope,
                        .id = atoms.intern(event.query),
                        .reply = replyTo(.table_request),
                    } });
                }
                s.confirm_scope.* = 0;
                reopen = true;
            },
            .scope_cancel => {
                s.confirm_scope.* = 0;
                reopen = true;
            },
        }
    } else if (s.confirm_scope.* != 0) {
        s.confirm_scope.* = 0;
        reopen = true;
    } else {
        closePicker(s);
    }

    // A request of this owner may have opened before the response landed, and uses this arena.
    if (action_palette.currentOwner(tables, atoms) != kPickerOwner) action_palette.resetCompletionArena(memory, .picker);
    action_palette.request(memory, tables, .{ .acknowledge = .{ .owner = kPickerOwner } });
    if (reopen) {
        openPickerRequest(memory, scratch, tables, atoms, event.query);
    } else {
        closePicker(s);
    }
}

/// Closes the picker outside the system's run, as setup for tests.
pub fn dismissPicker(tables: *Table.Registry, atoms: *Atom.Registry) void {
    const s = picker(tables, atoms);
    if (action_palette.currentOwner(tables, atoms) == kPickerOwner)
        action_palette.request(tables.memory, tables, .{ .cancel = .{ .owner = kPickerOwner } });
    closePicker(s);
}

/// Opens a window on `table_handle` outside the system's run: setup for tests, which then
/// drive the window through the system.
/// Where a table window opens: to the right of the panel that asked for it.
/// Its header says the table's name as the table is named, as the other debugging views do.
fn windowPanel(atoms: *Atom.Registry, id: Atom) plugin.panels.Open {
    const table_name = atoms.lookup(id) orelse "";
    return .{ .id = id, .title = table_name, .root = inspector.inspector_root, .side = .right, .share = 0.4 };
}

/// Shows `s`'s window in the current arrangement: beside the focused panel when it is not
/// open, and with the focus either way.
fn showWindow(tables: *Table.Registry, atoms: *Atom.Registry, s: WindowState) void {
    const current = workspaces.arrangementCount(tables);
    if (s.shown_in.* != current) {
        s.shown_in.* = current;
        s.open_beside.* = workspaces.requester(tables, atoms);
    }
    plugin.panels.request(tables.memory, tables, .{ .focus = .{ .id = s.id.* } });
}

/// Opens a window on `table_handle`, or focuses the one open on it.
pub fn open(tables: *Table.Registry, atoms: *Atom.Registry, table_handle: Table.Handle) bool {
    const target = tables.get(table_handle) orelse return false;
    if (target.lifetime == .transient) return false;
    const list = windows(tables, atoms);
    var row: u32 = 0;
    while (row < list.rowCapacity()) : (row += 1) {
        if (!list.isAllocated(row)) continue;
        const handle: Table.RowHandle = .{ .row = row, .generation = list.rowGeneration(row) };
        const existing = list.getRow(handle, WindowState).?;
        if (existing.id.* == target.name) {
            // Window lifetime is global; explicit open adds it to the arrangement again.
            showWindow(tables, atoms, existing);
            return true;
        }
    }

    if (list.count() >= kMaxWindows) return false;
    const handle = list.alloc() catch return false;
    const s = list.getRow(handle, WindowState).?;
    s.id.* = target.name;
    s.instance.* = target.name;
    s.shown_in.* = 0;
    showWindow(tables, atoms, s);

    s.viewport_w.* = 640;
    s.viewport_h.* = 480;
    s.inspector_scroll.* = 0;
    s.inspector_horizontal_scroll.* = 0;
    s.inspector_row_present.* = 0;
    s.inspector_row.* = 0;
    s.inspector_row_generation.* = 0;
    s.inspector_target_epoch.* = handle.generation;
    s.edit_present.* = 0;
    s.edit_row.* = 0;
    s.edit_field.* = 0;
    s.edit_text.* = .{};
    s.edit_invalid.* = 0;
    s.edit_commit.* = 0;
    s.edit_serial.* = 0;
    s.inspector_committed.* = 0;
    s.tracker_chart.* = 0;
    list.setRowMask(handle, s);
    grid.reset(widgetState(windows(tables, atoms), s));
    return true;
}

fn queueTrackerPrompt(memory: *memory_mod.Memory, tables: *Table.Registry, query: []const u8, body: []const u8) void {
    const allocator = action_palette.completionAllocator(memory, .tracker) catch return;
    const completions = allocator.create(action_palette.Completions) catch return;
    const entries = allocator.alloc(action_palette.Completion, 1) catch return;
    entries[0] = .{ .label = "Create tracker" };
    completions.* = .{
        .owner = kTrackerOwner,
        .presentation = .prompt,
        .prompt = "Tracker suffix: ",
        .initial_query = query,
        // The entry is what to do with the suffix typed, not a suffix.
        .tab = .nothing,
        .body = body,
        .entries = entries,
    };
    action_palette.ownRequestText(allocator, completions) catch return;
    action_palette.request(memory, tables, .{ .present = .{ .completions = completions, .reply = replyTo(.tracker_completion_reply) } });
}

fn handleTrackerCompletion(memory: *memory_mod.Memory, tables: *Table.Registry, atoms: *Atom.Registry, event: action_palette.Msg.Event) void {
    if (event.kind != .completed) return;
    const query = event.query;
    var error_text: []const u8 = "";
    if (event.completion != null) {
        const suffix = if (std.mem.startsWith(u8, query, tracker.definition_prefix)) query[tracker.definition_prefix.len..] else query;
        if (suffix.len == 0 or !table_document_mod.validId(suffix)) {
            error_text = "Enter a short lowercase tracker suffix";
        } else if (windows(tables, atoms).count() >= kMaxWindows) {
            error_text = "Inspector window limit reached (32)";
        } else {
            // Made at the start of the next run; `takeAuthoringOutcome` opens it.
            authoring.request(memory, tables, .{ .create_tracker = .{ .suffix = suffix, .query = query } });
        }
    }
    // A request of this owner may have opened before the response landed, and uses this arena.
    if (action_palette.currentOwner(tables, atoms) != kTrackerOwner) action_palette.resetCompletionArena(memory, .tracker);
    action_palette.request(memory, tables, .{ .acknowledge = .{ .owner = kTrackerOwner } });
    if (error_text.len != 0) {
        authoring.setStatus(authoringTable(tables, atoms), state.authoringUi(tables, atoms), "{s}", .{error_text});
        queueTrackerPrompt(memory, tables, query, error_text);
    }
}

fn deleteFocusedTracker(tables: *Table.Registry, atoms: *Atom.Registry) void {
    const list = windows(tables, atoms);
    const window_handle = focusedHandle(tables, atoms) orelse return;
    const s = list.getRow(window_handle, WindowState) orelse return;
    const handle = targetHandle(tables, s) orelse return;
    const target = tables.get(handle) orelse return;
    if (!tracker.isDefinition(atoms, target)) return;
    // Deleted at the start of the next run; `takeAuthoringOutcome` closes its window.
    authoring.request(tables.memory, tables, .{ .delete_tracker = .{ .definition = target.name, .reason = .asked } });
}

fn chooseMatch(tables: *Table.Registry, atoms: *Atom.Registry, match: Match, s: PickerState) void {
    switch (match.kind) {
        .resident => {
            if (!open(tables, atoms, match.handle)) {
                s.error_code.* = @intFromEnum(PickerError.window_limit);
                return;
            }
            closePicker(s);
        },
        .disk => {
            const scope = resources.applicationScope(tables.memory);
            resources.request(tables.memory, tables, .{ .request_table = .{
                .scope = scope,
                .id = atoms.intern(match.name),
                .reply = replyTo(.table_request),
            } });
        },
        .create => {
            const scope = resources.applicationScope(tables.memory);
            resources.request(tables.memory, tables, .{ .create_table = .{
                .scope = scope,
                .id = atoms.intern(match.name),
                .reply = replyTo(.table_request),
            } });
        },
    }
}

pub fn handleTableRequest(tables: *Table.Registry, atoms: *Atom.Registry, m: *const resources.TableRequestMsg) void {
    const s = picker(tables, atoms);
    switch (m.result) {
        .opened_resident, .opened_loaded, .created => {
            if (m.id == atoms.intern(state.view_focus_name) or keybinds.isInternalTable(m.id)) return;
            const authoring_ui = state.authoringUi(tables, atoms);
            if (m.result == .created) {
                authoring_ui.drawer_mode.* = @intFromEnum(state.DrawerMode.schema);
                authoring_ui.drawer_table.* = m.id;
                authoring.setStatus(authoringTable(tables, atoms), authoring_ui, "New table", .{});
            } else {
                authoring.clearStatus(authoring_ui);
            }
            _ = open(tables, atoms, m.handle);
            if (action_palette.currentOwner(tables, atoms) == kPickerOwner) {
                action_palette.request(tables.memory, tables, .{ .dismiss = .{} });
            } else {
                closePicker(s);
            }
        },
        .not_found => {
            s.error_code.* = @intFromEnum(PickerError.no_match);
        },
        .invalid_id => {
            s.error_code.* = @intFromEnum(PickerError.invalid_id);
        },
        .load_failed, .registry_full, .stale_scope => {
            s.error_code.* = @intFromEnum(PickerError.load_failed);
        },
    }
}

pub fn handleTableSave(tables: *Table.Registry, atoms: *Atom.Registry, m: *const resources.TableSaveMsg) void {
    const authoring_ui = state.authoringUi(tables, atoms);
    if (m.ok) {
        authoring.clearStatus(authoring_ui);

        if (@as(state.Modal, @enumFromInt(authoring_ui.modal.*)) == .dirty_close) {
            const list = windows(tables, atoms);
            const handle: Table.RowHandle = .{ .row = authoring_ui.modal_window_row.*, .generation = authoring_ui.modal_window_generation.* };
            if (list.getRow(handle, WindowState) != null) list.free(handle);
            authoring_ui.modal.* = @intFromEnum(state.Modal.none);
        }
        return;
    }
    if (m.conflict) {
        authoring_ui.modal.* = @intFromEnum(state.Modal.conflict);
        authoring_ui.modal_window_row.* = 0;
        authoring.setStatus(authoringTable(tables, atoms), authoring_ui, "Save blocked: file changed on disk", .{});
    } else {
        authoring.setStatus(authoringTable(tables, atoms), authoring_ui, "Save failed", .{});
    }
}

const WindowRef = struct { handle: Table.RowHandle, state: WindowState };

/// The window a message's user data names; null for one that names none, as an action's.
fn windowFromPayload(list: *Table, received: sequencer.Message) ?WindowRef {
    const p = received.userDataAs(WindowPayload) catch return null;
    const handle: Table.RowHandle = .{ .row = p.row, .generation = p.generation };
    return .{ .handle = handle, .state = list.getRow(handle, WindowState) orelse return null };
}

const kDrawerWidth: f32 = 320;
const kDrawerMinBody: f32 = 300;
const kFormRowHeight: f32 = 30;

fn drawerOpenFor(authoring_ui: state.AuthoringUiView, instance: Atom) bool {
    if (@as(state.DrawerMode, @enumFromInt(authoring_ui.drawer_mode.*)) == .none) return false;
    return authoring_ui.drawer_table.* == instance;
}

/// How wide the grid of the window on `instance` is drawn in a pane `pane_w` wide: the pane, less
/// the drawer beside it while one is open on that table and leaves the grid room. A drawer that
/// takes the whole pane hides the grid, which keeps the pane's width.
fn gridWidth(authoring_ui: state.AuthoringUiView, instance: Atom, pane_w: f32) f32 {
    if (!drawerOpenFor(authoring_ui, instance)) return pane_w;
    if (pane_w < kDrawerWidth + kDrawerMinBody) return pane_w;
    return pane_w - kDrawerWidth;
}

/// A form text field's text: a string cell of the authoring state's table.
fn fieldTarget(authoring_ui: state.AuthoringUiView, field: state.FormFocus) ?*Table.String {
    return switch (field) {
        .meta_key => authoring_ui.meta_key,
        .meta_value => authoring_ui.meta_value,
        .none => null,
    };
}

/// The table the authoring state's row is in, which holds its form fields' text.
fn authoringTable(tables: *Table.Registry, atoms: *Atom.Registry) *Table {
    return state.table(tables, atoms, state.authoring_ui_name);
}

pub fn isFormEditing(tables: *Table.Registry, atoms: *Atom.Registry) bool {
    const authoring_ui = state.authoringUi(tables, atoms);
    return authoring_ui.form_focus.* != 0 or @as(state.Modal, @enumFromInt(authoring_ui.modal.*)) != .none;
}

fn handleRowAdd(tables: *Table.Registry, atoms: *Atom.Registry, authoring_ui: state.AuthoringUiView, s: WindowState) void {
    const handle = targetHandle(tables, s) orelse return;
    const target = tables.get(handle) orelse return;
    if (tracker.isDefinition(atoms, target)) {
        _ = tracker.addSeries(target, .{
            .table_name = @enumFromInt(0),
            .field_name = @enumFromInt(0),
            .row = 0,
            .color = .{ .x = 0.3, .y = 0.7, .z = 1.0, .w = 1.0 },
        }) catch |err| {
            if (err == error.TooManySeries) {
                authoring.setStatus(authoringTable(tables, atoms), authoring_ui, "Tracker limit: 63 series", .{});
            } else {
                authoring.setStatus(authoringTable(tables, atoms), authoring_ui, "Could not add tracker series", .{});
            }
            return;
        };
        authoring.clearStatus(authoring_ui);
        return;
    }
    _ = authoring.addRow(tables, atoms, handle) catch |err| {
        if (err == error.OwnerManagedRows) {
            authoring.setStatus(authoringTable(tables, atoms), authoring_ui, "Rows in this table are managed by the engine", .{});
        } else {
            authoring.setStatus(authoringTable(tables, atoms), authoring_ui, "Table full — raise capacity in Schema", .{});
        }
        return;
    };
    authoring.clearStatus(authoring_ui);
}

fn handleRowDelete(tables: *Table.Registry, atoms: *Atom.Registry, authoring_ui: state.AuthoringUiView, s: WindowState) void {
    if (s.inspector_row_present.* == 0) return;
    const handle = targetHandle(tables, s) orelse return;
    authoring.deleteRow(tables, atoms, handle, s.inspector_row.*) catch |err| {
        if (err == error.OwnerManagedRows) authoring.setStatus(authoringTable(tables, atoms), authoring_ui, "Rows in this table are managed by the engine", .{});
        return;
    };
    authoring.clearStatus(authoring_ui);
}

const OutcomeTaking = struct {
    memory: *memory_mod.Memory,
    tables: *Table.Registry,
    atoms: *Atom.Registry,

    fn take(taking: *OutcomeTaking, outcome: *const authoring.Outcome) !void {
        takeAuthoringOutcome(taking.memory, taking.tables, taking.atoms, outcome);
    }

    fn takeForTest(taking: *OutcomeTaking, outcome: *authoring.Outcome) sequencer.Applied {
        takeAuthoringOutcome(taking.memory, taking.tables, taking.atoms, outcome);
        return .done;
    }
};

/// What became of a table change the windows asked for: the status line says so, and a column
/// form closes once its change is in. A tracker made is opened, or deleted again if it cannot
/// be; one deleted takes its window with it.
fn takeAuthoringOutcome(memory: *memory_mod.Memory, tables: *Table.Registry, atoms: *Atom.Registry, outcome: *const authoring.Outcome) void {
    const authoring_ui = state.authoringUi(tables, atoms);
    switch (outcome.*) {
        .tracker_created => |created| {
            const error_text: []const u8 = switch (created.result) {
                .created => |definition| opened: {
                    const handle = tables.findHandleByName(definition) orelse break :opened "Could not open tracker";
                    if (open(tables, atoms, handle)) {
                        authoring.setStatus(authoringTable(tables, atoms), authoring_ui, "Created {s}", .{atoms.lookup(definition) orelse "tracker"});
                        break :opened "";
                    }
                    authoring.request(memory, tables, .{ .delete_tracker = .{ .definition = definition, .reason = .unopened } });
                    break :opened "Could not open tracker";
                },
                .failed => |err| if (err == error.DuplicateTableName) "Tracker name already exists" else "Could not create tracker",
            };
            if (error_text.len == 0) return;
            authoring.setStatus(authoringTable(tables, atoms), authoring_ui, "{s}", .{error_text});
            if (action_palette.currentOwner(tables, atoms) != kTrackerOwner) action_palette.resetCompletionArena(memory, .tracker);
            queueTrackerPrompt(memory, tables, created.query, error_text);
        },
        .tracker_deleted => |deleted| {
            if (deleted.reason == .unopened) return;
            if (!deleted.deleted) {
                authoring.setStatus(authoringTable(tables, atoms), authoring_ui, "Could not delete tracker", .{});
                return;
            }
            if (authoring_ui.drawer_table.* == deleted.definition) {
                authoring_ui.drawer_mode.* = @intFromEnum(state.DrawerMode.none);
                authoring_ui.form_focus.* = 0;
            }
            // Its window went with its table, when the windows were last pruned.
            pruneAndNormalize(tables, atoms);
            publishActiveInspector(tables, atoms);
            authoring.setStatus(authoringTable(tables, atoms), authoring_ui, "Deleted tracker", .{});
        },
    }
}

fn openMetaForm(tables: *Table.Registry, atoms: *Atom.Registry, authoring_ui: state.AuthoringUiView, handle: ?Table.RowHandle) void {
    authoring_ui.form_focus.* = @intFromEnum(state.FormFocus.meta_key);
    authoring_ui.meta_key.* = .{};
    authoring_ui.meta_value.* = .{};
    authoring_ui.meta_original_key.* = .{};
    // The fields start over: what the editor held of them is dropped.
    forgetInspectorText(authoring_ui);
    const h = handle orelse return;
    const meta = tables.findByName(atoms.intern(resources.table_metadata_name)) orelse return;
    const view = meta.getRow(h, resources.TableMetadataView) orelse return;
    const form = authoringTable(tables, atoms);
    // An entry whose text cannot be copied opens as a new, empty one.
    form.assignString(authoring_ui.meta_key, view.key) catch return;
    form.assignString(authoring_ui.meta_value, view.value) catch return;
    form.assignString(authoring_ui.meta_original_key, view.key) catch return;
}

fn handleMetaSave(tables: *Table.Registry, atoms: *Atom.Registry, authoring_ui: state.AuthoringUiView, s: WindowState) void {
    const target = targetTable(tables, s) orelse return;

    const form = authoringTable(tables, atoms);
    const key = form.textOf(authoring_ui.meta_key.*);
    const value = form.textOf(authoring_ui.meta_value.*);
    const original = form.textOf(authoring_ui.meta_original_key.*);
    authoring.setMetadataEntry(tables, atoms, target.name, key, value, original) catch |err| {
        authoring.setStatus(authoringTable(tables, atoms), authoring_ui, "Metadata: {s}", .{@errorName(err)});
        return;
    };
    authoring_ui.form_focus.* = 0;
    authoring.clearStatus(authoring_ui);
}

fn handleModalAction(tables: *Table.Registry, atoms: *Atom.Registry, authoring_ui: state.AuthoringUiView, action: state.Modal) void {
    switch (action) {
        .none => {},
        .dirty_close => {
            const list = windows(tables, atoms);
            if (list.getRow(.{ .row = authoring_ui.modal_window_row.*, .generation = authoring_ui.modal_window_generation.* }, WindowState)) |s| {
                const scope = resources.applicationScope(tables.memory);
                resources.request(tables.memory, tables, .{ .save_table = .{ .scope = scope, .id = s.instance.*, .reply = replyTo(.table_save) } });
            } else authoring_ui.modal.* = @intFromEnum(state.Modal.none);
        },
        .conflict => {},
    }
}

fn makeModalCompletions(memory: *memory_mod.Memory, modal: state.Modal) !*action_palette.Completions {
    const allocator = try action_palette.completionAllocator(memory, .modal);
    var title: []const u8 = "";
    var body: []const u8 = "";
    var labels: [3][]const u8 = undefined;
    var tags: [3]Msg = undefined;
    var count: usize = 0;
    switch (modal) {
        .none => return error.NoModal,
        .dirty_close => {
            title = "Unsaved changes";
            body = "This table has modifications that are not on disk yet.";
            labels[0] = "Save";
            tags[0] = .modal_dirty_save;
            labels[1] = "Close without saving";
            tags[1] = .modal_close_without_saving;
            count = 2;
        },
        .conflict => {
            title = "File changed on disk";
            body = "The table asset file was modified externally. Reload to adopt the disk version, or overwrite it with the live table.";
            labels[0] = "Reload";
            tags[0] = .modal_reload;
            labels[1] = "Overwrite";
            tags[1] = .modal_overwrite;
            labels[2] = "Cancel";
            tags[2] = .modal_cancel;
            count = 3;
        },
    }
    const entries = try allocator.alloc(action_palette.Completion, count);
    for (entries, 0..) |*entry, i| {
        var data = std.mem.zeroes([action_palette.kCompletionDataSize]u8);
        @memcpy(data[0..@sizeOf(Atom)], std.mem.asBytes(&tags[i]));
        entry.* = .{ .label = labels[i], .data = data };
    }
    const completions = try allocator.create(action_palette.Completions);
    completions.* = .{
        .owner = kModalOwner,
        .identity = @intFromEnum(modal),
        .presentation = .dialog,
        .title = title,
        .body = body,
        .entries = entries,
    };
    try action_palette.ownRequestText(allocator, completions);
    return completions;
}

fn syncModalRequest(memory: *memory_mod.Memory, tables: *Table.Registry, atoms: *Atom.Registry) void {
    const authoring_ui = state.authoringUi(tables, atoms);
    const modal: state.Modal = @enumFromInt(authoring_ui.modal.*);
    const owner = action_palette.currentOwner(tables, atoms);
    if (modal == .none) {
        // A sync re-presents an answered modal until its answer lands, so the arena can reach
        // here still in use. With no modal and no request of ours, and last update's commands
        // dispatched, nothing points into it.
        if (owner == kModalOwner) action_palette.request(memory, tables, .{ .dismiss = .{} }) else action_palette.resetCompletionArena(memory, .modal);
        return;
    }
    if (action_palette.requestOpen(tables, atoms) and owner != kModalOwner) return;
    // A present would be refused until the cancel settles, and this runs each update: building
    // one to throw away would grow the arena, which resets only when the modal ends, and the
    // refusal would answer the modal as if it were cancelled.
    if (owner != kModalOwner and !action_palette.canPresent(tables, atoms)) return;
    if (owner == kModalOwner) {
        if (action_palette.currentCompletions(tables, atoms)) |current|
            if (current.identity == @intFromEnum(modal)) return;
    }
    const completions = makeModalCompletions(memory, modal) catch return;
    if (owner == kModalOwner) {
        action_palette.request(memory, tables, .{ .replace = .{ .completions = completions } });
    } else {
        action_palette.request(memory, tables, .{ .present = .{ .completions = completions, .reply = replyTo(.modal_completion_reply) } });
    }
}

fn handleModalCompletionEvent(memory: *memory_mod.Memory, tables: *Table.Registry, atoms: *Atom.Registry, event: action_palette.Msg.Event) void {
    if (event.kind == .query_changed) return;
    const authoring_ui = state.authoringUi(tables, atoms);
    if (event.completion) |completion| {
        const action = std.mem.bytesToValue(Msg, completion.data[0..@sizeOf(Msg)]);
        switch (action) {
            .modal_dirty_save => handleModalAction(tables, atoms, authoring_ui, .dirty_close),
            .modal_close_without_saving => handleCloseWithoutSaving(windows(tables, atoms), authoring_ui),
            .modal_reload => handleModalReload(tables, atoms, authoring_ui),
            .modal_overwrite => handleModalOverwrite(tables, atoms, authoring_ui),
            .modal_cancel => authoring_ui.modal.* = @intFromEnum(state.Modal.none),
            else => {},
        }
    } else {
        authoring_ui.modal.* = @intFromEnum(state.Modal.none);
    }
    // A request of this owner may have opened before the response landed, and uses this arena.
    if (action_palette.currentOwner(tables, atoms) != kModalOwner) action_palette.resetCompletionArena(memory, .modal);
    action_palette.request(memory, tables, .{ .acknowledge = .{ .owner = kModalOwner } });
}

fn isMetaFormOpen(authoring_ui: state.AuthoringUiView) bool {
    const f: state.FormFocus = @enumFromInt(authoring_ui.form_focus.*);
    return f == .meta_key or f == .meta_value;
}

fn cycleFormFocus(authoring_ui: state.AuthoringUiView) void {
    if (isMetaFormOpen(authoring_ui)) {
        authoring_ui.form_focus.* = if (authoring_ui.form_focus.* == @intFromEnum(state.FormFocus.meta_key))
            @intFromEnum(state.FormFocus.meta_value)
        else
            @intFromEnum(state.FormFocus.meta_key);
        return;
    }
}

fn payloadColumn(received: sequencer.Message) !u32 {
    return (try received.userDataAs(ColumnPayload)).column;
}

fn payloadMetaRow(received: sequencer.Message) !u32 {
    return (try received.userDataAs(MetaPayload)).meta_row;
}

fn selectedMetaHandle(tables: *Table.Registry, atoms: *Atom.Registry) ?Table.RowHandle {
    const meta = resources.metadataTable(tables, atoms) orelse return null;
    const row = state.authoringUi(tables, atoms).selected_meta_row.*;
    if (row >= meta.rowCapacity()) return null;
    if (!meta.isAllocated(row)) return null;
    return .{ .row = row, .generation = meta.rowGeneration(row) };
}

fn toggleDrawer(authoring_ui: state.AuthoringUiView, s: WindowState, mode: state.DrawerMode) void {
    if (authoring_ui.drawer_table.* != s.instance.* or authoring_ui.drawer_mode.* != @intFromEnum(mode)) {
        authoring_ui.drawer_mode.* = @intFromEnum(mode);
        authoring_ui.drawer_table.* = s.instance.*;
    } else authoring_ui.drawer_mode.* = @intFromEnum(state.DrawerMode.none);
}

fn handleToolbarSave(tables: *Table.Registry, atoms: *Atom.Registry, authoring_ui: state.AuthoringUiView, s: WindowState) void {
    const scope = resources.applicationScope(tables.memory);
    resources.request(tables.memory, tables, .{ .save_table = .{ .scope = scope, .id = s.instance.*, .reply = replyTo(.table_save) } });
    authoring.setStatus(authoringTable(tables, atoms), authoring_ui, "Saving...", .{});
}

fn handleMetaDelete(tables: *Table.Registry, atoms: *Atom.Registry, instance: Atom, meta_handle: ?Table.RowHandle) void {
    const meta = resources.metadataTable(tables, atoms) orelse return;
    const handle = meta_handle orelse return;
    if (meta.getRow(handle, resources.TableMetadataView)) |view| {
        authoring.deleteMetadataEntry(tables, atoms, instance, view.key);
    }
}

/// A typed character goes to the focused text field: through the editor once it holds the
/// field, straight into the field until then.
fn handleFormChar(authoring_ui: state.AuthoringUiView, received: sequencer.Message, tables: *Table.Registry, atoms: *Atom.Registry) !void {
    const m = try received.payloadAs(input.TextInputMsg);
    if (m.codepoint < 32 or m.codepoint == 127) return;
    const field = focusedTextField(authoring_ui) orelse return;
    var bytes: [4]u8 = undefined;
    const utf8 = input.typedText(m, &bytes) orelse return;
    if (loadedOwner(authoring_ui).eql(.{ .kind = .form_field, .id = @intFromEnum(field) })) {
        plugin.text_editor_api.request(tables.memory, tables, .{ .insert = .{ .buffer = table_view.inspector_editor, .utf8 = utf8 } });
        return;
    }
    const target = fieldTarget(authoring_ui, field) orelse return;
    const form = authoringTable(tables, atoms);
    const before = form.textOf(target.*);
    // One payload of the text and the character, filled where it lies.
    const joined = form.allocatePayload(before.len + utf8.len, .@"1") catch return;
    const text = form.payloadBytesMut(joined);
    @memcpy(text[0..before.len], before);
    @memcpy(text[before.len..], utf8);
    target.* = .{ .payload = joined };
}

fn handleCloseWithoutSaving(list: *Table, authoring_ui: state.AuthoringUiView) void {
    const handle: Table.RowHandle = .{ .row = authoring_ui.modal_window_row.*, .generation = authoring_ui.modal_window_generation.* };
    if (list.getRow(handle, WindowState) != null) list.free(handle);
    authoring_ui.modal.* = @intFromEnum(state.Modal.none);
}

fn handleModalReload(tables: *Table.Registry, atoms: *Atom.Registry, authoring_ui: state.AuthoringUiView) void {
    if (focusedHandle(tables, atoms)) |fhandle| {
        const fs = windows(tables, atoms).getRow(fhandle, WindowState).?;
        const scope = resources.applicationScope(tables.memory);
        resources.request(tables.memory, tables, .{ .reload_table = .{
            .scope = scope,
            .id = fs.instance.*,
            .reply = replyTo(.table_request),
        } });
    }
    authoring_ui.modal.* = @intFromEnum(state.Modal.none);
}

fn handleModalOverwrite(tables: *Table.Registry, atoms: *Atom.Registry, authoring_ui: state.AuthoringUiView) void {
    if (focusedHandle(tables, atoms)) |fhandle| {
        const fs = windows(tables, atoms).getRow(fhandle, WindowState).?;
        const scope = resources.applicationScope(tables.memory);
        resources.request(tables.memory, tables, .{ .save_table = .{
            .scope = scope,
            .id = fs.instance.*,
            .overwrite = true,
            .reply = replyTo(.table_save),
        } });
    }
    authoring_ui.modal.* = @intFromEnum(state.Modal.none);
}

/// One message as the system's run takes it, without the journal: for the tests here, which
/// drive the handlers directly.
fn update(scratch: memory_mod.Scratch, tables: *Table.Registry, atoms: *Atom.Registry, received: sequencer.Message) bool {
    return takeMessage(tables.memory, scratch, tables, atoms, received) catch false;
}

/// One of the windows' own messages; false for one no window took.
fn takeWindowsMessage(memory: *memory_mod.Memory, scratch: memory_mod.Scratch, tables: *Table.Registry, atoms: *Atom.Registry, message: Msg, received: sequencer.Message) !bool {
    const list = windows(tables, atoms);
    switch (message) {
        .tracker_completion_reply => {
            const event = try action_palette.eventOf(received);
            handleTrackerCompletion(memory, tables, atoms, event);
        },
        .create_tracker => {
            if (action_palette.currentOwner(tables, atoms) != kTrackerOwner)
                queueTrackerPrompt(memory, tables, "", "");
        },
        .delete_tracker => deleteFocusedTracker(tables, atoms),
        .picker_completion_reply => {
            const event = try action_palette.eventOf(received);
            handlePickerCompletionEvent(memory, scratch, tables, atoms, event);
        },
        .modal_completion_reply => {
            const event = try action_palette.eventOf(received);
            handleModalCompletionEvent(memory, tables, atoms, event);
        },
        .table_request => {
            const m = try received.payloadAs(resources.TableRequestMsg);
            handleTableRequest(tables, atoms, m);
            const pick = picker(tables, atoms);
            if (pick.error_code.* != @intFromEnum(PickerError.none) and action_palette.currentOwner(tables, atoms) == kPickerOwner)
                replacePickerCompletions(memory, scratch, tables, atoms, action_palette.promptText(tables, atoms));
        },
        .table_save => {
            const m = try received.payloadAs(resources.TableSaveMsg);
            handleTableSave(tables, atoms, m);
        },
        .table_index => {},
        .picker_toggle => togglePickerRequest(memory, scratch, tables, atoms),
        .tracker_chart_toggle => {
            const found = windowFromPayload(list, received) orelse return true;
            const target = targetTable(tables, found.state) orelse return true;
            if (!tracker.isDefinition(atoms, target)) return true;
            found.state.tracker_chart.* = if (found.state.tracker_chart.* == 0) 1 else 0;
            if (found.state.tracker_chart.* != 0) {
                found.state.edit_present.* = 0;
                found.state.inspector_row_present.* = 0;
                publishActiveInspector(tables, atoms);
            }
            return true;
        },
        .window_close => {
            const found = windowFromPayload(list, received) orelse blk: {
                const fhandle = focusedHandle(tables, atoms) orelse {
                    const id = state.viewFocus(tables, atoms).id.*;
                    // Another plugin's panel, a game's among them, is its plugin's to
                    // declare: the editor only hides it, until `panels_show_hidden` or the
                    // app workspace shows it again.
                    const no_panel: Atom = @enumFromInt(0);
                    if (id != no_panel and !workspaces.ownsPanel(tables, atoms, id)) {
                        plugin.panels.request(tables.memory, tables, .{ .hide = .{ .id = id } });
                        return true;
                    }
                    // Not a table window: a fixed panel (a panel of the figure editor's, the
                    // profiler, a widget), which is no longer shown. The last one closed
                    // brings back the workspace's arrangement.
                    workspaces.hidePanel(tables, id);
                    return true;
                };
                break :blk WindowRef{ .handle = fhandle, .state = list.getRow(fhandle, WindowState).? };
            };
            {
                const authoring_ui = state.authoringUi(tables, atoms);
                if (authoring.isDirty(tables, atoms, found.state.instance.*)) {
                    authoring_ui.modal.* = @intFromEnum(state.Modal.dirty_close);
                    authoring_ui.modal_window_row.* = found.handle.row;
                    authoring_ui.modal_window_generation.* = found.handle.generation;
                    authoring.clearStatus(authoring_ui);
                    return true;
                }

                if (authoring_ui.drawer_table.* == found.state.instance.*) authoring_ui.drawer_mode.* = @intFromEnum(state.DrawerMode.none);
                list.free(found.handle);
            }
            return true;
        },
        .save => {
            // A save from no window's toolbar saves the focused window's table, when it persists.
            if (windowFromPayload(list, received) != null) return takeToolbarMessage(tables, atoms, message, received);
            if (focusedHandle(tables, atoms)) |fhandle| {
                if (list.getRow(fhandle, WindowState)) |fs| {
                    if (authoring.assetRow(tables, atoms, fs.instance.*)) |asset| {
                        if (asset.persistable.* != 0) handleToolbarSave(tables, atoms, state.authoringUi(tables, atoms), fs);
                    }
                }
            }
        },
        .row_add, .row_delete, .schema_toggle, .metadata_toggle, .form_save, .form_cancel => return takeToolbarMessage(tables, atoms, message, received),
        .column_select => return takeToolbarMessage(tables, atoms, message, received),
        .meta_select, .meta_add, .meta_edit, .meta_delete, .meta_save, .meta_cancel_edit => return takeToolbarMessage(tables, atoms, message, received),
        .ctx_add, .ctx_edit, .ctx_delete => return takeToolbarMessage(tables, atoms, message, received),
        .form_char, .form_escape, .form_tab => return takeFormModalMessage(tables, atoms, message, received),
        .form_focus_meta_key, .form_focus_meta_value => return takeFormModalMessage(tables, atoms, message, received),
        .modal_dirty_save, .modal_close_without_saving => return takeFormModalMessage(tables, atoms, message, received),
        .modal_reload, .modal_overwrite, .modal_cancel => return takeFormModalMessage(tables, atoms, message, received),
        _ => return false,
    }
    return true;
}

/// A window toolbar's, drawer's or form's button, for the window its payload names or else the
/// focused one.
fn takeToolbarMessage(tables: *Table.Registry, atoms: *Atom.Registry, message: Msg, received: sequencer.Message) !bool {
    const list = windows(tables, atoms);
    const found = windowFromPayload(list, received) orelse blk: {
        const fhandle = focusedHandle(tables, atoms) orelse return true;
        break :blk WindowRef{ .handle = fhandle, .state = list.getRow(fhandle, WindowState).? };
    };
    const authoring_ui = state.authoringUi(tables, atoms);
    const target = targetTable(tables, found.state);
    if (target != null and found.state.tracker_chart.* != 0 and tracker.isDefinition(atoms, target.?)) {
        // A tracker's chart takes no rows, nor the context menu's while no drawer is open.
        const drawer_closed = authoring_ui.drawer_mode.* == @intFromEnum(state.DrawerMode.none);
        switch (message) {
            .row_add, .row_delete => return true,
            .ctx_add, .ctx_delete => if (drawer_closed) return true,
            else => {},
        }
    }

    const selected_meta: ?Table.RowHandle = selectedMetaHandle(tables, atoms);
    switch (message) {
        .row_add => handleRowAdd(tables, atoms, authoring_ui, found.state),
        .row_delete => handleRowDelete(tables, atoms, authoring_ui, found.state),
        .schema_toggle => toggleDrawer(authoring_ui, found.state, .schema),
        .metadata_toggle => toggleDrawer(authoring_ui, found.state, .metadata),
        .save => handleToolbarSave(tables, atoms, authoring_ui, found.state),

        .form_save => requestFormSubmit(tables, atoms, authoring_ui, found.state),
        .form_cancel => {
            authoring_ui.form_focus.* = 0;
            if (isMetaFormOpen(authoring_ui)) authoring.clearStatus(authoring_ui);
        },
        .column_select => authoring_ui.selected_column.* = try payloadColumn(received),
        .meta_select => authoring_ui.selected_meta_row.* = try payloadMetaRow(received),
        .meta_add => openMetaForm(tables, atoms, authoring_ui, null),
        .meta_edit => if (selected_meta) |mh| openMetaForm(tables, atoms, authoring_ui, mh),
        .meta_delete => if (selected_meta) |mh| handleMetaDelete(tables, atoms, found.state.instance.*, mh),
        .meta_save => requestFormSubmit(tables, atoms, authoring_ui, found.state),
        .meta_cancel_edit => {
            authoring_ui.form_focus.* = 0;
            authoring.clearStatus(authoring_ui);
        },

        // The schema drawer shows columns; the context menu changes nothing there.
        .ctx_add => switch (@as(state.DrawerMode, @enumFromInt(authoring_ui.drawer_mode.*))) {
            .none => handleRowAdd(tables, atoms, authoring_ui, found.state),
            .schema => {},
            .metadata => openMetaForm(tables, atoms, authoring_ui, null),
        },
        .ctx_edit => switch (@as(state.DrawerMode, @enumFromInt(authoring_ui.drawer_mode.*))) {
            .none, .schema => {},
            .metadata => if (selected_meta) |mh| openMetaForm(tables, atoms, authoring_ui, mh),
        },
        .ctx_delete => switch (@as(state.DrawerMode, @enumFromInt(authoring_ui.drawer_mode.*))) {
            .none => handleRowDelete(tables, atoms, authoring_ui, found.state),
            .schema => {},
            .metadata => if (selected_meta) |mh| handleMetaDelete(tables, atoms, found.state.instance.*, mh),
        },
        else => unreachable,
    }
    return true;
}

/// A form's keys and focus, and a modal prompt's buttons.
fn takeFormModalMessage(tables: *Table.Registry, atoms: *Atom.Registry, message: Msg, received: sequencer.Message) !bool {
    const list = windows(tables, atoms);
    const authoring_ui = state.authoringUi(tables, atoms);
    switch (message) {
        .form_char => try handleFormChar(authoring_ui, received, tables, atoms),
        .form_escape => closeForm(authoring_ui),
        .form_tab => cycleFormFocus(authoring_ui),
        .form_focus_meta_key => authoring_ui.form_focus.* = @intFromEnum(state.FormFocus.meta_key),
        .form_focus_meta_value => authoring_ui.form_focus.* = @intFromEnum(state.FormFocus.meta_value),
        .modal_dirty_save => handleModalAction(tables, atoms, authoring_ui, .dirty_close),
        .modal_close_without_saving => handleCloseWithoutSaving(list, authoring_ui),
        .modal_reload => handleModalReload(tables, atoms, authoring_ui),
        .modal_overwrite => handleModalOverwrite(tables, atoms, authoring_ui),
        .modal_cancel => authoring_ui.modal.* = @intFromEnum(state.Modal.none),
        else => unreachable,
    }
    return true;
}

/// One message from the windows' inbox, `received`; false for one no window took. An error
/// is the message's that could not be read.
fn takeMessage(memory: *memory_mod.Memory, scratch: memory_mod.Scratch, tables: *Table.Registry, atoms: *Atom.Registry, received: sequencer.Message) !bool {
    pruneAndNormalize(tables, atoms);
    const list = windows(tables, atoms);

    const tag = received.tag;
    switch (tag.to(Msg)) {
        _ => {},
        else => |message| return takeWindowsMessage(memory, scratch, tables, atoms, message, received),
    }
    if (try handleInspectorEditor(tables, atoms, received)) return true;

    {
        const view_message = tag.to(grid.Msg);
        switch (view_message) {
            _ => return false,
            else => {},
        }
        // A message without its view's instance, as an action's, is for the focused window's.
        var instance = grid.instanceOf(received);
        if (instance == @as(Atom, @enumFromInt(0))) instance = focusedInstance(tables, atoms);
        var row: u32 = 0;
        while (row < list.rowCapacity()) : (row += 1) {
            if (!list.isAllocated(row)) continue;
            const handle: Table.RowHandle = .{ .row = row, .generation = list.rowGeneration(row) };
            const s = list.getRow(handle, WindowState).?;
            if (s.instance.* != instance) continue;
            if (view_message == .paste_reply) {
                const clipboard_target = try received.userDataAs(grid.ClipboardTarget);
                if (clipboard_target.incarnation != handle.generation) return true;
            }
            const target = targetTable(tables, s) orelse {
                list.free(handle);
                break;
            };
            if (s.tracker_chart.* != 0 and tracker.isDefinition(atoms, target)) return view_message == .paste_reply;
            const view_state = widgetState(windows(tables, atoms), s);
            const context = cellUpdateContext(tables, atoms, handle, s);
            if (view_message == .table_column_menu_reply) {
                table_view.takeColumnMenuReply(view_state, target, received, context);
                return true;
            }
            const result = try table_view.update(view_state, s.instance.*, .table, view_message, received, target, context);
            if (result == .mutated) authoring.markDirty(tables, atoms, target.name);
            if (result == .invalidated) list.free(handle);
            return result != .ignored;
        }
        if (view_message == .paste_reply) return true;
    }
    return false;
}

/// Where resources' answers to the table windows' requests go: their system's inbox, under
/// `tag`.
pub fn replyTo(message: Msg) sequencer.ReplyTo {
    const tag = Atom.from(message);
    return sequencer.ReplyTo.of(system(), tag);
}

// ---- the windows' system ----------------------------------------------------------------------

/// The table windows, the table picker, the tracker and modal prompts, the schema and metadata
/// drawers and their forms, and the inspector's text editor: a system under the inspector's
/// root. It takes what its table changes came to, then its messages, then keeps the modal's
/// prompt, the text editor, the panes and the active inspector in step with the windows.
/// The tables its windows show are declared written, so what an edit writes a fault takes
/// back; a change to a table's shape is table authoring's.
pub fn system() sequencer.System {
    return .{
        .name = "table_windows",
        .names = comptime &(sequencer.enumNames(Msg) ++ sequencer.enumNames(grid.Msg) ++ [_][]const u8{resize_reader_name}),
        .root = inspector.inspector_root,
        .claims = claims,
        .access = access,
        .kernels = &.{
            .{ .name = "table_windows.subscribe", .run = subscribe },
            .{ .name = "table_windows.take_outcomes", .run = takeOutcomesKernel },
            .{ .name = "table_windows.take_messages", .run = takeMessagesKernel },
            .{ .name = "table_windows.follow_editor", .run = followEditor },
            .{ .name = "table_windows.keep_up", .run = keepUp },
            .{ .name = "table_windows.follow_modes", .run = followModes },
            .{ .name = "table_windows.declare_windows", .run = declareWindows },
        },
    };
}

/// The windows' modes, a `modes.PanelModesRow` each.
pub const panel_modes_table_name = "table_windows_panel_modes";
/// The form's modes while one of its text fields edits, which suspends the focus: see
/// `modes.followPrompt`.
pub const prompt_modes_table_name = "table_windows_prompt_modes";

/// What decides a window's mode.
const WindowModeView = struct { id: *Atom, edit_present: *u8, view_filter_focused: *u8 };

/// A window's major mode: `filter` while its filter is typed in, `table_cell` while a cell
/// edits, and `table` otherwise, a tracker's chart included, whose window's own commands (save,
/// the drawers) are `table`'s though its view offers none of its actions.
fn windowMode(window: Table.ReadView(WindowModeView)) Atom {
    if (window.view_filter_focused.* != 0) return modes.filter;
    if (window.edit_present.* != 0) return modes.table_cell;
    return modes.table;
}

/// Each window's modes as its state gives them, and the form's while one of its text fields
/// edits; the modal's prompt is the palette's.
fn followModes(pass: *sequencer.Pass) !void {
    const windows_table = Atom.from(state.windows_name);
    const authoring_ui_table = Atom.from(state.authoring_ui_name);
    if (!pass.declares(windows_table) or !pass.declares(authoring_ui_table)) return;
    const list = try pass.table(windows_table);
    var wanted: [kMaxWindows]modes.PanelMajor = undefined;
    var count: usize = 0;
    var rows = list.readQuery(WindowModeView);
    while (rows.next()) |found| {
        if (count == wanted.len) break;
        wanted[count] = .{ .panel = found.view.id.*, .major = windowMode(found.view) };
        count += 1;
    }
    try modes.syncPanelModes(pass, panel_modes_table_name, wanted[0..count]);

    const authoring_ui = try pass.readSingleton(authoring_ui_table, state.AuthoringUiView);
    const modal: state.Modal = @enumFromInt(authoring_ui.modal.*);
    const form_editing = modal == .none and authoring_ui.form_focus.* != 0;
    const form_mode = if (form_editing) modes.form else mesha.plugin.action_api.no_mode;
    try modes.followPrompt(pass, prompt_modes_table_name, form_mode);
}

/// Hears the input it takes now, in this system's inbox.
fn subscribe(pass: *sequencer.Pass) !void {
    if (!pass.writes(editor_sequencer.InputSubscriber.table)) return;
    subscribeInput(pass.frame.tables, pass.frame.atoms, editor_sequencer.InputSubscriber.of(pass, system()));
}

/// Follows the cell and form editor's text as it changes. Not under the action palette, which
/// goes over the windows.
fn followEditor(pass: *sequencer.Pass) !void {
    const frame = pass.frame;
    var events: [shared.events_max]plugin.text_editor_api.Event = undefined;
    const taken = try shared.readEvents(pass, Atom.from(system().name), &events);
    if (action_palette.requestOpen(frame.tables, frame.atoms)) return;
    for (taken) |event| {
        const change = switch (event) {
            .changed => |change| change,
            else => continue,
        };
        if (change.buffer != table_view.inspector_editor) continue;
        const authoring_ui = state.authoringUi(frame.tables, frame.atoms);
        authoring_ui.text_serial.* = change.serial;
        const text = try shared.textOf(frame.tables, table_view.inspector_editor);
        onInspectorText(frame.tables, frame.atoms, text);
    }
}

/// The windows' own tags, the table view's, and the cell's, form's and text editor's actions.
const action_tags = plugin.action_api.tags(&cell_actions) ++ plugin.action_api.tags(&form_actions) ++ [_]Atom{ shared.command_tag, shared.save_tag, shared.leave_tag };

fn claims(tag: Atom) bool {
    switch (tag.to(Msg)) {
        _ => {},
        else => return true,
    }
    switch (tag.to(grid.Msg)) {
        _ => {},
        else => return true,
    }
    return std.mem.indexOfScalar(Atom, &action_tags, tag) != null;
}

/// The windows' own tables and the tables they show; a table that is not there is not
/// declared, so a window whose table is gone is pruned rather than the system skipped.
fn access(frame: *const sequencer.Frame) sequencer.Access {
    const tables = frame.tables;
    var result: sequencer.Access = .{};
    const owned = [_][]const u8{
        state.windows_name,            kPickerStateName,                   state.authoring_ui_name,
        state.active_inspector_name,   action_palette.requests_table_name, authoring.requests_table_name,
        authoring.outcomes_table_name, resources.table_assets_name,        resources.table_metadata_name,
    };
    // Copying and pasting a cell ask the window's clipboard, saving and requesting tables ask
    // resources, opening and closing windows ask the panels, and the cell and form editors are
    // text editors.
    const asked = [_][]const u8{
        os.commands_table_name,
        resources.commands_table_name,
        plugin.panels.commands_table_name,
        plugin.text_editor_api.commands_table_name,
        // Closing a fixed panel that has the focus (a stage, a panel of the figure
        // editor's) takes its row from those shown.
        workspaces.shown_panels_table_name,
        // Each window shown is a panel the system declares.
        plugin.panels.declared_table_name,
    };
    shared.declareEvents(&result, tables, table_view.inspector_editor);
    // Every run subscribes again: its run replaces what it subscribed to before.
    result.writeIfPresent(tables, editor_sequencer.InputSubscriber.table);
    for (owned ++ asked) |name| {
        const atom = Atom.from(name);
        if (tables.findByName(atom) != null) result.write(atom);
    }
    result.read(Atom.from(action_palette.table_name));
    // Which arrangement is current: a window shown in an earlier one is closed.
    if (tables.findByName(Atom.from(workspaces.workspace_table_name)) != null) result.read(Atom.from(workspaces.workspace_table_name));
    modes.declarePanelModes(&result, tables, panel_modes_table_name);
    modes.declarePromptModes(&result, tables, prompt_modes_table_name);
    // The sizes the panels tell, which the windows' grids settle at.
    plugin.panels.Events.declare(&result, tables, plugin.panels.events_table_name);
    const list = tables.findByName(Atom.from(state.windows_name)) orelse return result;
    var rows = list.query(WindowIdView);
    while (rows.next()) |row| {
        const target = tables.findByName(row.view.id.*) orelse continue;
        if (target.lifetime == .transient) continue;
        result.write(target.name);
    }
    return result;
}

const WindowIdView = struct { id: *Atom };

/// What the table changes asked for came to, taken through the run's journal.
fn takeOutcomesKernel(pass: *sequencer.Pass) !void {
    const frame = pass.frame;
    const outcomes = authoring.Outcomes.of(frame.memory, frame.tables, authoring.outcomes_table_name);
    if (outcomes.count() == 0) return;
    var taking: OutcomeTaking = .{ .memory = frame.memory, .tables = frame.tables, .atoms = frame.atoms };
    try outcomes.take(pass, &taking, OutcomeTaking.take);
}

fn takeMessagesKernel(pass: *sequencer.Pass) !void {
    const frame = pass.frame;
    if (frame.messages.len == 0) return;
    const scratch = try frame.memory.frameScratchAllocator();
    for (frame.messages) |received| {
        _ = takeMessage(frame.memory, scratch, frame.tables, frame.atoms, received) catch |err| received.unreadable(err);
    }
}

/// Each frame, after the messages: the modal's prompt, the text editor on what has the keys,
/// the sizes the panels told, windows whose tables went, the panes of windows that closed, and
/// the active inspector.
fn keepUp(pass: *sequencer.Pass) !void {
    const frame = pass.frame;
    syncModalRequest(frame.memory, frame.tables, frame.atoms);
    updateInspectorEditor(frame.tables, frame.atoms);
    try followResizes(pass);
    syncActiveInspector(frame.tables, frame.atoms);
}

/// The reader of `events.panels` that hears the windows' panels resized.
const resize_reader_name = "table_windows_resizes";
const resize_reader = Atom.from(resize_reader_name);

/// Keeps each window's `viewport_w` and `viewport_h` as its panel's content is laid out, which
/// its keys page and scroll by, as the panels system tells each size (`Event.resized`); the same
/// run then settles every window's grid at its size (`syncActiveInspector`). A panel just opened
/// is told its first size so; a panel hidden behind a maximized one is told an empty frame, and
/// its window keeps the size it last had, to be told the next as the panel shows again. Until the
/// reader has taken an event (its first run, as after a reload into a session whose sizes were
/// told before it read), each window takes its panel's place as it is now (`seedSizes`), so no
/// size told before is missed. Drawing reads the pane itself and writes nothing.
fn followResizes(pass: *sequencer.Pass) !void {
    const frame = pass.frame;
    const tables = frame.tables;
    const atoms = frame.atoms;
    const events = plugin.panels.Events.of(tables, plugin.panels.events_table_name);
    const first_read = !events.hasRead(resize_reader);
    // All the events table keeps, so a run of other events never pushes a size out unread.
    var told: [plugin.panels.Events.retained]plugin.panels.Event = undefined;
    const taken = try events.read(pass, resize_reader, &told);
    const list = windows(tables, atoms);
    if (first_read) seedSizes(tables, atoms, list);
    for (taken) |event| {
        const resized = switch (event) {
            .resized => |resized| resized,
            .focused, .unfocused => continue,
        };
        const row = rowForId(list, resized.panel) orelse continue;
        const content = panel_frame.contentSize(tables, atoms, resized);
        if (content.width <= 0 or content.height <= 0) continue;
        const handle: Table.RowHandle = .{ .row = row, .generation = list.rowGeneration(row) };
        const s = list.getRow(handle, WindowState) orelse continue;
        s.viewport_w.* = content.width;
        s.viewport_h.* = content.height;
    }
}

/// Each shown window's size as its panel's content is laid out now; a window whose panel is
/// hidden or not yet laid out keeps the size it has.
fn seedSizes(tables: *Table.Registry, atoms: *Atom.Registry, list: *Table) void {
    var row: u32 = 0;
    while (row < list.rowCapacity()) : (row += 1) {
        if (!list.isAllocated(row)) continue;
        const handle: Table.RowHandle = .{ .row = row, .generation = list.rowGeneration(row) };
        const s = list.getRow(handle, WindowState) orelse continue;
        const pane = panel_frame.contentRect(tables, atoms, s.id.*) orelse continue;
        s.viewport_w.* = pane.w;
        s.viewport_h.* = pane.h;
    }
}

/// Declares a panel for each window shown in the current arrangement, as the panels system
/// follows them: one shown this frame opens beside the panel that asked for it, taking the
/// focus, and one whose row went, or that an arrangement left behind, closes.
fn declareWindows(pass: *sequencer.Pass) !void {
    const declared = Atom.from(plugin.panels.declared_table_name);
    if (!pass.writes(declared)) return;
    const frame = pass.frame;
    const current = workspaces.arrangementCount(frame.tables);
    const list = try pass.table(Atom.from(state.windows_name));
    var rows = list.readQuery(WindowState);
    while (rows.next()) |found| {
        const row = found.view;
        if (row.shown_in.* != current) continue;
        var panel = windowPanel(frame.atoms, row.id.*);
        panel.beside = row.open_beside.*;
        plugin.panels.declare(frame.memory, frame.tables, panel);
    }
}

/// The keys and typing the focused window takes now, through the system's input subscriber.
/// Reads only: a window whose table went is pruned in the system's run.
fn subscribeInput(tables: *Table.Registry, atoms: *Atom.Registry, inputs: editor_sequencer.InputSubscriber) void {
    // The action palette goes over these, and two live captures would both receive its keys.
    if (action_palette.requestOpen(tables, atoms)) return;

    const owner: table_view.Owner = .{ .tables = tables, .atoms = atoms, .system = system() };
    if (isFormEditing(tables, atoms)) {
        if (focusedTextField(state.authoringUi(tables, atoms)) != null) {
            // Every other key is an action's: the text editor's and the form's own, listed
            // while a field edits; see `pushFormEditorActions`.
            inputs.push(.{ .text_input = .{
                .capture = true,
                .modifiers = .{ .control = .forbidden, .alt = .forbidden, .super = .forbidden },
                .tag = .from(Msg.form_char),
            } }, .none);
            return;
        }
        inputs.push(.{ .text_input = .{
            .capture = true,
            .modifiers = .{ .control = .forbidden, .alt = .forbidden, .super = .forbidden },
            .tag = .from(Msg.form_char),
        } }, .none);
        inputs.push(.{ .key_down = .{ .capture = true, .key = .escape, .tag = .from(Msg.form_escape) } }, .none);

        inputs.push(.{ .key_down = .{ .capture = true, .key = .tab, .tag = .from(Msg.form_tab) } }, .none);
        return;
    }
    const handle = focusedHandle(tables, atoms) orelse return;
    const s = windows(tables, atoms).getRow(handle, WindowState) orelse return;
    const target = targetTable(tables, s) orelse return;

    if (s.tracker_chart.* != 0 and tracker.isDefinition(atoms, target)) return;
    _ = table_view.subscribeInput(widgetState(windows(tables, atoms), s), s.instance.*, .table, target, owner, inputs);
}

/// The focused window whose view offers its actions: the palette is shut, no form
/// edits, and the view browses its cells.
const BrowsedView = struct { state: grid.State, instance: Atom, target: *const Table };

fn browsedView(tables: *Table.Registry, atoms: *Atom.Registry, owner: table_view.Owner) ?BrowsedView {
    if (action_palette.requestOpen(tables, atoms)) return null;
    if (isFormEditing(tables, atoms)) return null;
    const handle = focusedHandle(tables, atoms) orelse return null;
    const s = windows(tables, atoms).getRow(handle, WindowState) orelse return null;
    const target = targetTable(tables, s) orelse return null;
    if (s.tracker_chart.* != 0 and tracker.isDefinition(atoms, target)) return null;
    const view_state = widgetState(windows(tables, atoms), s);
    if (!table_view.isBrowsing(view_state, .table, target, owner)) return null;
    return .{ .state = view_state, .instance = s.instance.*, .target = target };
}

/// The focused window's view's actions (`table_view.actions`), offered while the palette is shut,
/// no form edits and the view browses its cells.
pub fn declareActions(tables: *Table.Registry, atoms: *Atom.Registry, sink: plugin.ActionSink) void {
    const owner: table_view.Owner = .{ .tables = tables, .atoms = atoms, .system = system() };
    const browsed = browsedView(tables, atoms, owner) orelse return;
    table_view.declareActions(browsed.state, browsed.instance, .table, browsed.target, owner, sink);
}

fn togglePickerRequest(memory: *memory_mod.Memory, scratch: memory_mod.Scratch, tables: *Table.Registry, atoms: *Atom.Registry) void {
    const pick = picker(tables, atoms);
    if (action_palette.currentOwner(tables, atoms) == kPickerOwner) {
        action_palette.request(memory, tables, .{ .dismiss = .{} });
        return;
    }
    pick.error_code.* = @intFromEnum(PickerError.none);
    pick.confirm_scope.* = 0;
    openPickerRequest(memory, scratch, tables, atoms, "");
}

pub fn focusedInstance(tables: *Table.Registry, atoms: *Atom.Registry) Atom {
    const handle = focusedHandle(tables, atoms) orelse return @as(Atom, @enumFromInt(0));
    const s = windows(tables, atoms).getRow(handle, WindowState) orelse return @as(Atom, @enumFromInt(0));
    if (targetTable(tables, s) == null) return @as(Atom, @enumFromInt(0));
    return s.instance.*;
}

fn windowSalt(handle: Table.RowHandle) u64 {
    return (@as(u64, handle.row) << 32) | handle.generation;
}

/// A table window's place in its pane's header: a "*" right after the title for unsaved work, its
/// chart toggle, and, for the focused window, the last thing authoring had to say.
pub fn renderDecoration(tree: *ui.Tree, tables: *Table.Registry, atoms: *Atom.Registry, id: Atom) void {
    const list = windows(tables, atoms);
    const found = rowForId(list, id) orelse return;
    const handle: Table.RowHandle = .{ .row = found, .generation = list.rowGeneration(found) };
    const s = list.getRow(handle, WindowState) orelse return;
    const target = targetTable(tables, s) orelse return;
    const salt = windowSalt(handle);
    const persistable = target.lifetime == .persistent and Table.schemaPersistable(target);
    if (persistable and authoring.isDirty(tables, atoms, target.name)) {
        tree.text(.{ "editor_window.decoration.unsaved", salt }, "*", .{ .font = style.ui_font, .color = style.col.text });
    }
    if (tracker.isDefinition(atoms, target)) {
        const input_state: ToggleInput = if (action_palette.requestOpen(tables, atoms)) .held_by_prompt else .live;
        renderTrackerChartToggle(tree, salt, handle, s.tracker_chart.*, input_state);
    }
    const focused = if (focusedHandle(tables, atoms)) |focused_handle| focused_handle.row == handle.row else false;
    if (!focused) return;
    const ui_state = state.authoringUi(tables, atoms);
    const status = authoringTable(tables, atoms).textOf(ui_state.status.*);
    if (status.len != 0) tree.text(.{ "editor_window.decoration.status", salt }, status, .{ .font = style.ui_font, .color = style.col.text, .size_hint = .{ .w = .fill } });
}

/// Fills a host-owned tree with this table's window, sized by the pane layout gave it. It
/// draws the windows as the system's run left them (`keepUp`) and writes no table.
pub fn renderWidget(tree: *ui.Tree, tables: *Table.Registry, atoms: *Atom.Registry, id: Atom) void {
    const pane = panel_frame.contentRect(tables, atoms, id) orelse return;
    const list = windows(tables, atoms);
    const found = rowForId(list, id) orelse return;
    const handle: Table.RowHandle = .{ .row = found, .generation = list.rowGeneration(found) };
    const s = list.getRow(handle, WindowState) orelse return;
    const target = targetTable(tables, s) orelse return;
    renderWindow(tree, atoms, tables, handle, s, target, pane);
}

/// Whether the panel `id` is a table's window. None is, without the windows' table.
pub fn isWindow(tables: *Table.Registry, atoms: *Atom.Registry, id: Atom) bool {
    const list = tables.findByName(atoms.intern(state.windows_name)) orelse return false;
    return rowForId(list, id) != null;
}

fn rowForId(list: *Table, id: Atom) ?u32 {
    var row: u32 = 0;
    while (row < list.rowCapacity()) : (row += 1) {
        if (!list.isAllocated(row)) continue;
        const s = list.getRow(.{ .row = row, .generation = list.rowGeneration(row) }, WindowState) orelse continue;
        if (s.id.* == id) return row;
    }
    return null;
}

fn renderWindow(tree: *ui.Tree, atoms: *Atom.Registry, tables: *Table.Registry, handle: Table.RowHandle, s: WindowState, target: *Table, pane: panels_mod.Rect) void {
    const scratch = tree.frame_allocator;
    const vw = pane.w;
    const vh = pane.h;
    const salt = windowSalt(handle);
    if (tree.beginRect(.{ "editor_window.root", salt }, .{
        .axis = .vertical,
        .size = .{ .w = .fill, .h = .fill },
        // The pane's header says it has the focus; a frame here as well would say it twice.
        .bg = style.col.canvas,
        .padding = 0,
        .corner_radius = 0,
        .clip_content = true,
    })) {
        defer tree.endRect();
        const body_w = vw;
        const ui_state = state.authoringUi(tables, atoms);
        const drawer_mode = @as(state.DrawerMode, @enumFromInt(ui_state.drawer_mode.*));
        const drawer_open = drawerOpenFor(ui_state, target.name);
        const full_body_drawer = drawer_open and body_w < kDrawerWidth + kDrawerMinBody;
        const grid_w = gridWidth(ui_state, target.name, body_w);
        const body_h = vh;
        if (tree.beginRect(.{ "editor_window.content", salt }, .{
            .axis = .horizontal,
            .size = .{ .w = .fill, .h = .{ .fixed = body_h } },
            .clip_content = true,
        })) {
            defer tree.endRect();
            if (!full_body_drawer) {
                if (s.tracker_chart.* != 0 and tracker.isDefinition(atoms, target)) {
                    renderTrackerChart(scratch, tree, salt, atoms, tables, target);
                } else {
                    const grid_style = style.gridStyle(target.lifetime);
                    const cell_editor = cellEditor(scratch, tables, atoms, s);
                    const drawing: grid.RenderContext = .{ .inbox = sequencer.inboxOf(system()), .style = grid_style, .editor = cell_editor };
                    _ = grid.render(widgetState(windows(tables, atoms), s), s.instance.*, .table, tree, target, grid_w, body_h, scratch, drawing);
                }
            }
            if (drawer_open) {
                switch (drawer_mode) {
                    .schema => renderSchemaDrawer(tree, salt, handle, tables, atoms, target),
                    .metadata => renderMetadataDrawer(tree, salt, handle, tables, atoms, target),
                    .none => {},
                }
            }
        }
    }
}

const ToggleInput = enum { live, held_by_prompt };

fn renderTrackerChartToggle(tree: *ui.Tree, salt: u64, handle: Table.RowHandle, mode: u8, input_state: ToggleInput) void {
    const payload = WindowPayload{ .row = handle.row, .generation = handle.generation };
    const click = editor_sequencer.to(tree, system(), .from(Msg.tracker_chart_toggle), payload);
    button.render(tree, .{ "editor_window.tracker_chart_toggle", salt }, click, .{
        .label = if (mode == 0) "Chart" else "Table",
        .variant = .text_only,
        // The host's header tree stays live under a prompt, which must keep the input to itself.
        .enabled = input_state == .live,
        .size = .{ .w = .{ .fixed = 54 }, .h = .fill },
    });
}

fn renderTrackerChart(scratch: memory_mod.Scratch, tree: *ui.Tree, salt: u64, atoms: *Atom.Registry, tables: *Table.Registry, definition: *Table) void {
    if (!tree.beginRect(.{ "editor_window.tracker_chart", salt }, .{ .axis = .vertical, .size = .{ .w = .fill, .h = .fill }, .bg = style.col.canvas, .padding = 8, .gap = 4, .clip_content = true })) return;
    defer tree.endRect();
    const count = @min(definition.count(), tracker.max_series);
    const history = tracker.history(scratch.allocator, atoms, tables, definition) catch null;
    const samples = if (history) |h| h.count() else 0;
    if (count == 0) {
        tree.text(.{ "editor_window.tracker_chart.empty", salt }, "Add a series in Table view", .{ .font = style.ui_font, .color = style.col.text_dim });
        return;
    }
    const h = history orelse {
        tree.text(.{ "editor_window.tracker_chart.waiting", salt }, "Waiting for history", .{ .font = style.ui_font, .color = style.col.text_dim });
        return;
    };
    if (samples == 0 or h.getSchema().fields.len != count + 1) {
        tree.text(.{ "editor_window.tracker_chart.waiting", salt }, "Waiting for samples", .{ .font = style.ui_font, .color = style.col.text_dim });
        return;
    }
    const Color = std.meta.Child(@TypeOf(@as(chart.Options, .{}).colors));
    const fields = scratch.allocator.alloc(Atom, count + 1) catch return;
    const colors = scratch.allocator.alloc(Color, count) catch return;
    fields[0] = Atom.from("x");
    for (0..count) |i| {
        const series = tracker.seriesAt(definition, i) orelse return;
        var name_buf: [32]u8 = undefined;
        const name = tracker.seriesFieldName(&name_buf, i) catch return;
        fields[i + 1] = atoms.intern(name);
        colors[i] = .{ .r = series.color.x, .g = series.color.y, .b = series.color.z, .a = series.color.w };
        if (i < 6) {
            const label = tree.allocBuffer(256);
            const table_name = atoms.lookup(series.table_name) orelse "?";
            const field_name = atoms.lookup(series.field_name) orelse "?";
            const text = std.fmt.bufPrint(label, "{s}[{d}].{s}", .{ table_name, series.row, field_name }) catch "series";
            tree.text(.{ "editor_window.tracker_chart.legend", salt + i }, text, .{ .font = style.ui_font, .color = colors[i] });
        }
    }
    if (count > 6) tree.text(.{ "editor_window.tracker_chart.more", salt }, "...", .{ .font = style.ui_font, .color = style.col.text_dim });
    const drawable = scratch.allocator.create(chart.Drawable([]const Atom)) catch return;
    drawable.* = chart.drawable(.line, h, @as([]const Atom, fields), .{ .colors = colors });
    tree.custom(.{ "editor_window.tracker_chart.plot", salt }, drawable, .{ .size = .{ .w = .fill, .h = .fill }, .clip_content = true });
}

/// A form's text field: the form editor's drawing while it is loaded there, else its text.
fn textInput(tree: *ui.Tree, comptime id: []const u8, salt: u64, buf: []const u8, focused: bool, editor: ?shared.FieldDrawable, focus: ui.Target) void {
    if (tree.beginRect(.{ id, salt }, style.fieldFrame(if (focused) .active else .idle, .{ .w = .fill, .h = .{ .fixed = kFormRowHeight } }))) {
        defer tree.endRect();
        tree.onClick(focus, .left);
        if (editor) |drawable| {
            const kept = tree.frame_allocator.allocator.create(shared.FieldDrawable) catch return;
            kept.* = drawable;
            tree.custom(.{ id ++ ".editor", salt }, kept, .{ .size = .{ .w = .fill, .h = .fill } });
            return;
        }
        tree.text(.{ id ++ ".text", salt }, if (buf.len == 0 and !focused) "..." else buf, .{ .font = style.ui_font, .color = style.col.text, .size_hint = .{ .w = .fill, .h = .fill } });
    }
}

fn renderSchemaDrawer(tree: *ui.Tree, salt: u64, handle: Table.RowHandle, tables: *Table.Registry, atoms: *Atom.Registry, target: *Table) void {
    if (tree.beginRect(.{ "editor_window.drawer", salt }, .{
        .axis = .vertical,
        .size = .{ .w = .{ .fixed = kDrawerWidth }, .h = .fill },
        .bg = style.col.sidebar,
        .border = style.col.border,
        .padding = 8,
        .gap = 4,
        .clip_content = true,
    })) {
        defer tree.endRect();
        tree.text(.{ "editor_window.drawer.title", salt }, "Schema", .{ .font = style.ui_font, .color = style.tableAccent(target.lifetime).bright });

        const cap_buf = tree.allocBuffer(16);
        tree.text(.{ "editor_window.drawer.capacity", salt }, std.fmt.bufPrint(cap_buf, "Capacity {d}", .{target.rowCapacity()}) catch "Capacity", .{ .font = style.ui_font, .color = style.col.text });

        const ui_state = state.authoringUi(tables, atoms);

        for (target.getSchema().fields, 0..) |*desc, i| {
            const selected = ui_state.selected_column.* == @as(u32, @intCast(i));
            if (tree.beginRect(.{ "editor_window.drawer.column", salt + i }, .{ .axis = .horizontal, .size = .{ .w = .fill, .h = .{ .fixed = kFormRowHeight } }, .gap = 2, .padding = 2, .bg = if (selected) style.col.accent_deep else style.col.card, .bg_hover = if (selected) style.col.accent_deep else style.col.card_hover, .corner_radius = 4, .clip_content = true })) {
                defer tree.endRect();
                tree.onClick(editor_sequencer.to(tree, system(), .from(Msg.column_select), ColumnPayload{ .row = handle.row, .generation = handle.generation, .column = @intCast(i) }), .left);
                tree.trackHover("");
                tree.text(.{ "editor_window.drawer.column.name", salt + i }, desc.name, .{ .font = style.ui_font, .color = if (selected) style.col.accent_bright else style.col.text, .size_hint = .{ .w = .fill, .h = .fill } });

                const label_buf = tree.allocBuffer(96);
                tree.text(.{ "editor_window.drawer.column.type", salt + i }, authoring.fieldLabel(desc, label_buf), .{ .font = style.ui_font, .color = style.col.text_dim });
            }
        }

        // Columns are the schema's, which code declares: they are shown, not edited.
        tree.text(.{ "editor_window.drawer.hint", salt }, "Declared in code", .{ .font = style.ui_font, .color = style.col.text_dim });
    }
}

fn renderMetadataDrawer(tree: *ui.Tree, salt: u64, handle: Table.RowHandle, tables: *Table.Registry, atoms: *Atom.Registry, target: *Table) void {
    const ui_state = state.authoringUi(tables, atoms);
    if (tree.beginRect(.{ "editor_window.drawer", salt }, .{
        .axis = .vertical,
        .size = .{ .w = .{ .fixed = kDrawerWidth }, .h = .fill },
        .bg = style.col.sidebar,
        .border = style.col.border,
        .padding = 8,
        .gap = 4,
        .clip_content = true,
    })) {
        defer tree.endRect();
        tree.text(.{ "editor_window.drawer.title", salt }, "Metadata", .{ .font = style.ui_font, .color = style.col.accent_bright });

        if (resources.metadataTable(tables, atoms)) |meta_table| {
            var it = resources.metadataRows(meta_table, target.name);
            while (it.next()) |row| {
                const r = row.handle.row;
                const selected = ui_state.selected_meta_row.* == r;
                const key = row.view.key;
                const value = row.view.value;
                if (tree.beginRect(.{ "editor_window.drawer.meta", salt + r }, .{ .axis = .vertical, .size = .{ .w = .fill, .h = .{ .hug = {} } }, .padding = 4, .gap = 2, .bg = if (selected) style.col.accent_deep else style.col.card, .bg_hover = if (selected) style.col.accent_deep else style.col.card_hover, .corner_radius = 4, .clip_content = true })) {
                    defer tree.endRect();
                    tree.onClick(editor_sequencer.to(tree, system(), .from(Msg.meta_select), MetaPayload{ .row = handle.row, .generation = handle.generation, .meta_row = r, .meta_generation = row.handle.generation }), .left);
                    tree.trackHover("");
                    tree.text(.{ "editor_window.drawer.meta.key", salt + r }, key, .{ .font = style.ui_font, .color = if (selected) style.col.accent_bright else style.col.text });
                    tree.text(.{ "editor_window.drawer.meta.value", salt + r }, value, .{ .font = style.ui_font, .color = style.col.text, .size_hint = .{ .w = .fill } });
                }
            }
        }

        if (ui_state.form_focus.* == @intFromEnum(state.FormFocus.meta_key) or ui_state.form_focus.* == @intFromEnum(state.FormFocus.meta_value)) {
            textInput(tree, "editor_window.drawer.metaf.key", salt, authoringTable(tables, atoms).textOf(ui_state.meta_key.*), ui_state.form_focus.* == @intFromEnum(state.FormFocus.meta_key), fieldEditor(tables, ui_state, .meta_key), editor_sequencer.to(tree, system(), .from(Msg.form_focus_meta_key), toolbarPayload(handle)));
            textInput(tree, "editor_window.drawer.metaf.value", salt, authoringTable(tables, atoms).textOf(ui_state.meta_value.*), ui_state.form_focus.* == @intFromEnum(state.FormFocus.meta_value), fieldEditor(tables, ui_state, .meta_value), editor_sequencer.to(tree, system(), .from(Msg.form_focus_meta_value), toolbarPayload(handle)));
        } else {
            tree.text(.{ "editor_window.drawer.meta.hint", salt }, "Ctrl+Enter adds an entry", .{ .font = style.ui_font, .color = style.col.text_dim });
        }
    }
}

fn testTarget(tables: *Table.Registry, atoms: *Atom.Registry, name: []const u8) !Table.Handle {
    var schema: Table.Schema = undefined;
    try schema.init(std.testing.allocator, atoms, 1);
    defer schema.deinit();
    schema.addField("value", u32, .int);
    const handle = try tables.create(&schema, 2, atoms.intern(name), .durable);
    _ = tables.get(handle).?.insert(.{ .value = @as(u32, 1) });
    return handle;
}

/// Applies the table changes asked for, as the editor's run does first, and takes what they
/// came to, as the next update does.
fn applyAuthoringForTest(tables: *Table.Registry, atoms: *Atom.Registry) void {
    const alone: sequencer.Sequencer = .{ .name = "authoring_test", .steps = &.{.{ .system = authoring.system() }} };
    var no_context: u8 = 0;
    sequencer.runHost(tables.memory, atoms, tables, &alone, &no_context);
    const outcomes = authoring.Outcomes.of(tables.memory, tables, authoring.outcomes_table_name);
    var taking: OutcomeTaking = .{ .memory = tables.memory, .tables = tables, .atoms = atoms };
    outcomes.drain(&taking, OutcomeTaking.takeForTest);
}

test "tracker editor chart toggle names the table windows' inbox" {
    var memory: memory_mod.Memory = undefined;
    memory.init(std.testing.allocator);
    defer memory.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&memory);
    defer atoms.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = try ui.Tree.init(.{ .allocator = arena.allocator() }, &atoms, 8);
    const handle = Table.RowHandle{ .row = 3, .generation = 7 };
    renderTrackerChartToggle(&tree, windowSalt(handle), handle, 0, .live);
    const rect = tree.elements[0].open_rect;
    try std.testing.expectEqual(sequencer.inboxOf(system()), rect.on_click.?.inbox);
    const click = rect.on_click.?;
    try std.testing.expectEqual(Atom.from(Msg.tracker_chart_toggle), click.tag);
    const payload = std.mem.bytesAsValue(WindowPayload, click.user_data).*;
    try std.testing.expectEqual(handle.row, payload.row);
    try std.testing.expectEqual(handle.generation, payload.generation);
    try std.testing.expect(rect.hover);
}

test "picker substring matches rank by earliest occurrence and offer create matches" {
    var atoms: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(std.testing.allocator);
    defer mem.deinit();
    try atoms.init(&mem);
    defer atoms.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&mem, 64);
    defer tables.deinit();
    try init(.{ .allocator = std.testing.allocator }, &atoms, &tables);
    _ = try testTarget(&tables, &atoms, "alpine");
    _ = try testTarget(&tables, &atoms, "Alpha");
    _ = try testTarget(&tables, &atoms, "zz.alpine");
    _ = try testTarget(&tables, &atoms, "beta");

    const matches = try collectMatches(.{ .allocator = std.testing.allocator }, &tables, &atoms, "ALP");
    defer std.testing.allocator.free(matches);
    try std.testing.expectEqual(@as(usize, 3), matches.len);
    try std.testing.expectEqualStrings("Alpha", matches[0].name);
    try std.testing.expectEqualStrings("alpine", matches[1].name);
    try std.testing.expectEqualStrings("zz.alpine", matches[2].name);
    try std.testing.expectEqual(@as(usize, 0), matches[0].match_index);
    try std.testing.expectEqual(@as(usize, 3), matches[2].match_index);

    const lower_matches = try collectMatches(.{ .allocator = std.testing.allocator }, &tables, &atoms, "alp");
    defer std.testing.allocator.free(lower_matches);
    try std.testing.expectEqual(@as(usize, 4), lower_matches.len);
    try std.testing.expectEqualStrings("Alpha", lower_matches[0].name);
    try std.testing.expectEqualStrings("alpine", lower_matches[1].name);
    try std.testing.expectEqualStrings("zz.alpine", lower_matches[2].name);
    try std.testing.expectEqual(MatchKind.create, lower_matches[3].kind);
    try std.testing.expectEqual(@as(usize, 0), lower_matches[3].match_index);

    const no_matches = try collectMatches(.{ .allocator = std.testing.allocator }, &tables, &atoms, "!");
    defer std.testing.allocator.free(no_matches);
    try std.testing.expectEqual(@as(usize, 0), no_matches.len);
    // Figure document table names are reserved, so the picker offers no table to create.
    const reserved = try collectMatches(.{ .allocator = std.testing.allocator }, &tables, &atoms, "figure_bones");
    defer std.testing.allocator.free(reserved);
    try std.testing.expectEqual(@as(usize, 0), reserved.len);
}

test "window capacity is recoverable and duplicate requests focus the existing pane" {
    var atoms: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(std.testing.allocator);
    defer mem.deinit();
    try atoms.init(&mem);
    defer atoms.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&mem, 96);
    defer tables.deinit();
    try init(.{ .allocator = std.testing.allocator }, &atoms, &tables);
    try plugin.panels.Requests.ensure(try mem.tableScratchAllocator(), &atoms, &tables, plugin.panels.commands_table_name);

    var handles: [kMaxWindows + 1]Table.Handle = undefined;
    for (&handles, 0..) |*handle, i| {
        var name: [32]u8 = undefined;
        handle.* = try testTarget(&tables, &atoms, try std.fmt.bufPrint(&name, "capacity.{d}", .{i}));
    }
    for (handles[0..kMaxWindows]) |handle| try std.testing.expect(open(&tables, &atoms, handle));
    try std.testing.expectEqual(kMaxWindows, windows(&tables, &atoms).count());
    try std.testing.expect(!open(&tables, &atoms, handles[kMaxWindows]));

    const panel_requests = plugin.panels.Requests.of(&mem, &tables, plugin.panels.commands_table_name);
    panel_requests.reset();
    try std.testing.expect(open(&tables, &atoms, handles[0]));
    try std.testing.expectEqual(kMaxWindows, windows(&tables, &atoms).count());
    var sent: [4]plugin.panels.CmdPayload = undefined;
    const requested = panel_requests.peek(&sent);
    // Shown already, it is only focused: its panel is the one its system declares.
    try std.testing.expectEqual(@as(usize, 1), requested.len);
    const focus = requested[0].focus;
    try std.testing.expectEqual(tables.get(handles[0]).?.name, focus.id);
}

fn focusedViewOf(tables: *Table.Registry, atoms: *Atom.Registry, row: u32) void {
    const list = windows(tables, atoms);
    const handle: Table.RowHandle = .{ .row = row, .generation = list.rowGeneration(row) };
    state.setViewFocus(tables, atoms, list.getRow(handle, WindowState).?.id.*);
}

test "window_close resolves the host-focused pane and stale targets clean up" {
    var atoms: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(std.testing.allocator);
    defer mem.deinit();
    try atoms.init(&mem);
    defer atoms.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&mem, 32);
    defer tables.deinit();
    try init(.{ .allocator = std.testing.allocator }, &atoms, &tables);
    const target = try testTarget(&tables, &atoms, "closing");
    try std.testing.expect(open(&tables, &atoms, target));
    const list = windows(&tables, &atoms);

    focusedViewOf(&tables, &atoms, 0);
    try std.testing.expect(update(.{ .allocator = std.testing.allocator }, &tables, &atoms, .{ .tag = .from(Msg.window_close) }));
    try std.testing.expectEqual(@as(u32, 0), list.count());

    try std.testing.expect(open(&tables, &atoms, target));
    try std.testing.expect(!update(.{ .allocator = std.testing.allocator }, &tables, &atoms, .{ .tag = @enumFromInt(999999) }));
    tables.destroy(target);

    _ = update(.{ .allocator = std.testing.allocator }, &tables, &atoms, .{ .tag = .from(Msg.row_add) });
    try std.testing.expectEqual(@as(u32, 0), list.count());
}

test "late clipboard reply cannot cross a close and reopen epoch collision" {
    var atoms: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(std.testing.allocator);
    defer mem.deinit();
    try atoms.init(&mem);
    defer atoms.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&mem, 32);
    defer tables.deinit();
    try init(.{ .allocator = std.testing.allocator }, &atoms, &tables);
    const target = try testTarget(&tables, &atoms, "clipboard.target");
    try std.testing.expect(open(&tables, &atoms, target));
    const list = windows(&tables, &atoms);
    const handle = Table.RowHandle{ .row = 0, .generation = list.rowGeneration(0) };
    const old = list.getRow(handle, WindowState).?;
    const instance = old.instance.*;
    const old_epoch = old.inspector_target_epoch.*;
    const old_incarnation = handle.generation;
    list.free(handle);

    try std.testing.expect(open(&tables, &atoms, target));
    _ = update(.{ .allocator = std.testing.allocator }, &tables, &atoms, .{ .tag = @enumFromInt(999999) });
    const reopened_handle = Table.RowHandle{ .row = 0, .generation = list.rowGeneration(0) };
    const reopened = list.getRow(reopened_handle, WindowState).?;
    reopened.inspector_target_epoch.* = old_epoch;

    const clipboard_target = grid.ClipboardTarget{
        .instance = instance,
        .target_epoch = old_epoch,
        .incarnation = old_incarnation,
    };
    const reply: sequencer.Message = .{
        .tag = .from(grid.Msg.paste_reply),
        .payload = "42",
        .user_data = std.mem.asBytes(&clipboard_target),
    };
    try std.testing.expect(update(.{ .allocator = std.testing.allocator }, &tables, &atoms, reply));
    const row = Table.RowHandle{ .row = 0, .generation = tables.get(target).?.rowGeneration(0) };
    try std.testing.expectEqual(@as(u32, 1), tables.get(target).?.getField(u32, row, "value").?.*);
}

test "maximum window command and hit budgets remain bounded" {
    var atoms: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(std.testing.allocator);
    defer mem.deinit();
    try atoms.init(&mem);
    defer atoms.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&mem, 32);
    defer tables.deinit();
    try init(.{ .allocator = std.testing.allocator }, &atoms, &tables);
    const columns = grid.visibleColumns(3840);
    const hits_per_window = @as(usize, grid.visibleRows(2160, .grid, .{})) * columns + grid.chromeHitsPerGrid(columns, .{}) + 6;
    try std.testing.expect(hits_per_window * kMaxWindows < 65536);
}

/// Admission-only wrapper: core ensureSingleton rejects existing malformed controls.
/// Vocabulary includes every field reached by init, including the editor state helpers.
pub fn prepareInit(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    try atoms.tryInternAll(&.{
        "id",
        "user_data",
        "focus_clicks_disabled",
        "focused",
        "table_name",
        "row",
        "generation",
        "field_name",
        "drawer_mode",
        "drawer_table",
        "selected_column",
        "selected_meta_row",
        "form_focus",
        "meta_key",
        "meta_value",
        "meta_original_key",
        "modal",
        "modal_window_row",
        "modal_window_generation",
        "status",
        "instance",
        "viewport_w",
        "viewport_h",
        "shown_in",
        "open_beside",
        "inspector_scroll",
        "inspector_horizontal_scroll",
        "inspector_row_present",
        "inspector_row",
        "inspector_row_generation",
        "inspector_target_epoch",
        "edit_present",
        "edit_row",
        "edit_field",
        "edit_text",
        "edit_invalid",
        "edit_commit",
        "edit_serial",
        "inspector_committed",
        "tracker_chart",
        "view_sort_column",
        "view_sort_descending",
        "view_hidden_columns",
        "view_frozen_rows",
        "view_frozen_columns",
        "view_filter",
        "view_filter_focused",
        "error_code",
        "confirm_scope",
        "buf",
        "len",
        "cursor",
        "selected",
        "request_open",
        "request_owner",
        "request_presentation",
        "request_mode",
        "completions_ptr",
        "reply_route",
        "pending_open",
        "pending_owner",
        "pending_presentation",
        "pending_completions_ptr",
        "cancel_pending",
        "editor_view_focus",
        "editor_active_inspector",
        "editor_authoring_ui",
        "editor_action_palette",
        "editor_status_bar",
        "editor_windows_picker_state",
        "editor_windows",
    });
    try prepareWindowsTables(scratch, atoms, tables);
    const tab = tables.findByName(atoms.intern(state.windows_name)).?;
    if (tab.rowCapacity() < kMaxWindows or tab.required_singleton) return error.InvalidEditorWindows;
}

fn prepareWindowsTables(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    const allocator = scratch.allocator;

    try state.prepareViewFocus(scratch, atoms, tables);
    try state.prepareActiveInspector(scratch, atoms, tables);
    try state.prepareAuthoringUi(scratch, atoms, tables);

    try action_palette.prepareInit(scratch, atoms, tables);
    try authoring.ensureTables(scratch, atoms, tables);
    try status_bar.prepareInit(scratch, atoms, tables);
    try @import("profiler/profiler.zig").prepareInit(scratch, atoms, tables);
    try @import("text_panel.zig").ensure(scratch, atoms, tables);
    try @import("open.zig").ensure(scratch, atoms, tables);
    try @import("workspaces.zig").ensure(scratch, atoms, tables);
    try @import("text_tools.zig").ensure(scratch, atoms, tables);
    try @import("vcs/runner.zig").ensure(scratch, atoms, tables);
    try @import("vcs/git_status.zig").ensure(scratch, atoms, tables);
    try @import("vcs/p4_status.zig").ensure(scratch, atoms, tables);
    try @import("document/sources.zig").ensure(scratch, atoms, tables);
    try @import("transient.zig").ensure(scratch, atoms, tables);
    try modes.ensurePanelModes(scratch, atoms, tables, panel_modes_table_name);
    try modes.ensurePromptModes(scratch, atoms, tables, prompt_modes_table_name);
    try editor_sequencer.ensure(scratch, atoms, tables);
    try preparePickerState(scratch, atoms, tables);

    var windows_schema: Table.Schema = undefined;
    try windows_schema.init(allocator, atoms, window_field_count);
    defer windows_schema.deinit();

    try windows_schema.addFieldFallible("id", Atom, .atom);
    try windows_schema.addFieldFallible("instance", Atom, .atom);
    try windows_schema.addFieldFallible("viewport_w", f32, .int);
    try windows_schema.addFieldFallible("viewport_h", f32, .int);
    try windows_schema.addFieldFallible("shown_in", u32, .int);
    try windows_schema.addFieldFallible("open_beside", Atom, .atom);
    try windows_schema.addFieldFallible("inspector_scroll", u32, .int);
    try windows_schema.addFieldFallible("inspector_horizontal_scroll", u32, .int);
    try windows_schema.addFieldFallible("inspector_row_present", u8, .int);
    try windows_schema.addFieldFallible("inspector_row", u32, .int);
    try windows_schema.addFieldFallible("inspector_row_generation", u32, .int);
    try windows_schema.addFieldFallible("inspector_target_epoch", u32, .int);
    try windows_schema.addFieldFallible("edit_present", u8, .int);
    try windows_schema.addFieldFallible("edit_row", u32, .int);
    try windows_schema.addFieldFallible("edit_field", u32, .int);
    try windows_schema.addFieldFallible("edit_text", Table.String, .text_field);
    try windows_schema.addFieldFallible("edit_invalid", u8, .int);
    try windows_schema.addFieldFallible("edit_commit", u8, .int);
    try windows_schema.addFieldFallible("edit_serial", u32, .int);
    try windows_schema.addFieldFallible("inspector_committed", u8, .int);
    try windows_schema.addFieldFallible("tracker_chart", u8, .int);
    try windows_schema.addFieldFallible("view_sort_column", u32, .int);
    try windows_schema.addFieldFallible("view_sort_descending", u8, .int);
    try windows_schema.addFieldFallible("view_hidden_columns", u64, .hex);
    try windows_schema.addFieldFallible("view_frozen_rows", u32, .int);
    try windows_schema.addFieldFallible("view_frozen_columns", u32, .int);
    try windows_schema.addFieldFallible("view_filter", Table.String, .text_field);
    try windows_schema.addFieldFallible("view_filter_focused", u8, .int);

    _ = try tables.ensure(&windows_schema, kMaxWindows, atoms.intern(state.windows_name), .durable);
}

fn preparePickerState(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    var schema: Table.Schema = undefined;
    try schema.init(scratch.allocator, atoms, 2);
    defer schema.deinit();
    try schema.addFieldFallible("error_code", u32, .int);
    try schema.addFieldFallible("confirm_scope", u8, .int);
    const name = atoms.intern(kPickerStateName);
    _ = try state.prepareSingletonSchema(tables, &schema, name, picker_defaults, .durable);
}
