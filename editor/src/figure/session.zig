//! Editor-owned session state, shared table operations, and short-lived figure reads.
const std = @import("std");
const mesha = @import("mesha");
const Atom = mesha.Atom;
const names = @import("names.zig");
const watches = @import("watches.zig");
const figure = mesha.figure;
const memory = mesha.memory;
const Table = mesha.Table;
const sequencer = mesha.sequencer;
/// Which part of a field's value an edit is for: all of it, or one component of a vector.
pub const ValuePart = enum(u32) { whole, x, y };
pub const ItemEvent = extern struct { kind: Atom, id: u32, field: u32 = 0, part: ValuePart = .whole };

// Data types and editor state.
pub const Vec2 = mesha.math.Vec2f;
pub const Color = [4]u8;
pub const none: Atom = @enumFromInt(0);
pub const zero = Vec2{ .x = 0, .y = 0 };
pub const one = Vec2{ .x = 1, .y = 1 };
pub const BoneFlags = figure.read.BoneFlags;
/// Reconciliation values only; retains no authoring payload storage.
pub const Metadata = struct {
    operation: std.meta.Tag(api.Payload),
    doc: Atom,
    request: u32,
    capture_frame: u32 = 0,
    pub fn from(payload: api.Payload) Metadata {
        return switch (payload) {
            inline else => |command_payload| .{
                .operation = payload,
                .doc = command_payload.doc,
                .request = command_payload.request,
                .capture_frame = if (@TypeOf(command_payload) == api.CaptureClipKey) command_payload.frame else 0,
            },
        };
    }
};

pub const observed_name = "editor_figure_observed";
/// Which surface a held press belongs to. It captures input until that button comes up.
pub const PointerOwner = enum(u8) { none, canvas, outliner };
pub const Observed = struct {
    pointer_owner: u8 = 0,
    pointer_button: u8 = 0,
    // Selection-local UI such as a custom pivot expires on an explicit reselect.
    selection_version: u64 = 0,
    // A Shift press becomes a toggle only if it never crosses the drag threshold.
    click_toggle_kind: Atom = none,
    click_toggle_id: u32 = 0,
    pick_filter: u8 = 0,
    outliner_reveal: u8 = 1,
    /// The folder the last group created; undo restores the selection remembered before it.
    grouped_folder: u32 = 0,
    outliner_height: f32 = 0,
    outliner_selected_index: u32 = std.math.maxInt(u32),
    // Continuous rail position in pixels; remembered identity drives update-time reveal.
    tools_scroll: f32 = 0,
    tools_mode: Atom = none,
    tools_tool: Atom = none,
    tools_reveal: u8 = 1,
    // Derived global bounds for external observers; geometry.stageLayout remains authoritative.
    // Canvas fills the stage, without Layers, Properties or other editor chrome.
    focus_mode: u8 = 0,
    // The side panel arrow keys and Enter act on; `none` means the canvas.
    key_panel: Atom = none,
    canvas_x: f32 = 0,
    canvas_y: f32 = 0,
    canvas_width: f32 = 0,
    canvas_height: f32 = 0,
    // The figure's extent as of bounds_revision. Evaluating every pose is too slow to repeat
    // per frame or per drag preview, so sync refreshes this copy between gestures.
    bounds_doc: Atom = none,
    bounds_revision: u64 = 0,
    bounds_present: u8 = 0,
    bounds_min: Vec2 = zero,
    bounds_max: Vec2 = zero,
    doc: Atom = none,
    close_doc: Atom = none,
    close_request: u32 = 0,
    observed_valid: u8 = 0,
    observed_table: u32 = 0,
    observed_table_generation: u32 = 0,
    observed_row: u32 = 0,
    observed_generation: u32 = 0,
    observed_revision: u64 = 0,
    catalog_version: u64 = 0,
    catalog_dirty: u8 = 1,
    // Captured at prompt admission; document names may change through Save As,
    // but a removed/reused definition must never become the prompt's target.
    prompt_identity_valid: u8 = 0,
    prompt_table: u32 = 0,
    prompt_table_generation: u32 = 0,
    prompt_row: u32 = 0,
    prompt_generation: u32 = 0,
    prompt_revision: u64 = 0,
    prompt_anchor_index: u32 = 0,
};
pub const pending_name = "editor_figure_commands";
pub const pending_capacity = 128;
/// doc/request are immutable correlation. Once a rename is observed, current_doc
/// stays authoritative even when the identity returns to the original atom.
pub const Pending = struct { doc: Atom = none, current_doc: Atom = none, rename_observed: u8 = 0, request: u32 = 0, operation: u32 = 0, capture_frame: u32 = 0 };
pub const name = "editor_figure_session";
/// Additive singleton so the outliner's category tab never changes the
/// editor_figure_session schema; the default view is art layers. `list_top`
/// echoes the last rendered first-row offset so a width-only resize that
/// rewraps the tab rows still reveals the selected row. `browsed` is the
/// one-shot marker of an explicit tab click: its render starts from the top
/// of the list instead of re-revealing the selected row.
pub const outliner_tab_name = "editor_figure_outliner_tab";
pub const OutlinerTab = struct { category: Atom = Atom.from("art"), list_top: f32 = 0, browsed: u8 = 0 };
/// Additive singleton of presentation cells that Time tweens; see motion.zig. Nothing here is
/// authored, and each cell rests at the value the state it follows implies.
pub const motion_name = "editor_figure_motion";
pub const Motion = struct {
    // What the indicators last announced. `none` means nothing yet, which must not animate.
    mode: Atom = none,
    tool: Atom = none,
    tool_row: Atom = none,
    /// Fractional index into the header's mode buttons.
    mode_slot: f32 = 0,
    /// Pixels from the start of the dock's content.
    tool_left: f32 = 0,
    // Hashes of the feedback last announced, zero for no text.
    seen_error: u64 = 0,
    seen_warning: u64 = 0,
    seen_information: u64 = 0,
    /// An action was refused since the last sync, which may have repeated the showing error.
    rejection_pending: u8 = 0,
    /// A hash of what rendering last found and was told, zero for nothing.
    seen_rendering: u64 = 0,
    /// A `motion.Tone` for the modal state the status bar is announcing.
    status_tone: u8 = 0,
    status_energy: f32 = 0,
};
pub const collapse_name = "editor_figure_collapsed_folders";
pub const selection_name = "editor_figure_selection";
pub const draft_name = "editor_figure_draft";
pub const Data = struct {
    doc: Atom = none,
    mode: Atom = Atom.from("design"),
    tool: Atom = Atom.from("select"),
    view_center: Vec2 = zero,
    view_zoom: f32 = 1,
    // Bit 0 grid, bit 1 bone overlays. The canvas starts as plain white.
    flags: u32 = 2,
    active_layer: u32 = 0,
    active_bone: u32 = 0,
    active_kind: Atom = none,
    active_id: u32 = 0,
    dirty: u8 = 0,
    gesture_active: u8 = 0,
    gesture_kind: Atom = none,
    gesture_start: Vec2 = zero,
    gesture_current: Vec2 = zero,
    gesture_start_screen: Vec2 = zero,
    gesture_parent: u32 = 0,
    gesture_connected: u8 = 0,
    gesture_origin: Vec2 = zero,
    gesture_local: Vec2 = zero,
    gesture_rotation: f32 = 0,
    gesture_length: f32 = 0,
    gesture_scale: Vec2 = one,
    gesture_button: u8 = 0,
    gesture_modifiers: u8 = 0,
    pan_center: Vec2 = zero,
    chain_parent: u32 = 0,
    chain_origin: Vec2 = zero,
    chain_mode: u8 = 0,
    tx_active: u8 = 0,
    space_held: u8 = 0,
    hover_kind: Atom = none,
    hover_id: u32 = 0,
    hover_sub: u32 = 0,
    hover_point: Vec2 = zero,
    snap_kind: Atom = none,
    snap_id: u32 = 0,
    snap_point: Vec2 = zero,
    inspector_field: u32 = 0,
    outliner_scroll: u32 = 0,
    outliner_drag: u32 = 0,
    outliner_drag_start: Vec2 = zero,
    pending_doc: Atom = none,
    prompt_kind: Atom = none,
    prompt_doc: Atom = none,
    prompt_id: u32 = 0,
    prompt_target_kind: Atom = none,
    prompt_mode: Atom = none,
    prompt_field: Atom = none,
    /// A `ValuePart`: the part of the prompted field's value the prompt's text is.
    prompt_part: u32 = 0,
    prompt_clip: u32 = 0,
    prompt_key_frame: u32 = 0,
    prompt_key_pose: u32 = 0,
    prompt_key_selected: u8 = 0,
    prompt_text: Table.String = .{},
    request_serial: u32 = 1000000,
    /// The serial of the latest question asked of the figure host (`asks.zig`); never reused
    /// while an answer to an earlier one may be in flight.
    ask_serial: u32 = 0,
    pending_request: u32 = 0,
    pending_action: Atom = none,
    pending_path: Table.String = .{},
    pending_target: Atom = none,
    close_after_save: u8 = 0,
    status: Table.String = .{},
    reparent_active: u8 = 0,
    fit_pending: u8 = 1,
};
pub const View = Row(Data);
pub const feedback_name = "editor_figure_feedback";
pub const Feedback = struct {
    information: Table.String = .{},
    information_seconds: f32 = 0,
    prompt_error_owned: u8 = 0,
    // Context of the latest hover sample. Changes invalidate it; only fresh motion
    // may recompute its description. Geometric ownership stays in editor state.
    hover_doc: Atom = none,
    hover_mode: Atom = none,
    hover_tool: Atom = none,
    hover_flags: u32 = 0,
    hover_center: Vec2 = zero,
    hover_zoom: f32 = 0,
    hover_version: u64 = 0,
    // Idle motion is consumed once per update; no message or scratch data is retained.
    hover_pending: u8 = 0,
    hover_screen: Vec2 = zero,
    hover_shift: u8 = 0,
    // The canvas region's os.CursorKind, chosen by the last hover pick.
    cursor_kind: u8 = 0,
    // What the last frame's rendering found (`chrome.noteRendering`), which `motion.sync`
    // tells: each failure an error's integer, 0 for none.
    render_artwork_error: u32 = 0,
    render_evaluation_error: u32 = 0,
    render_onion_error: u32 = 0,
    render_weights_error: u32 = 0,
    render_overlay_limited: u8 = 0,
    // The weight brush is over a path and reaches none of its anchors: the status bar's hint.
    brush_reaches_nothing: u8 = 0,
};
pub const RigOptions = struct {
    connected: u8 = 1,
    head: u8 = 0,
    snap_joints: u8 = 1,
    snap_midpoints: u8 = 1,
    snap_axes: u8 = 1,
    snap_lengths: u8 = 1,
    snap_grid: u8 = 1,
};
pub const rig_options_name = "editor_figure_rig_options";
pub const Selection = struct { doc: Atom = none, kind: Atom = none, id: u32 = 0, sub: u32 = 0, primary: u8 = 0 };
pub const Draft = struct { doc: Atom = none, index: u32 = 0, p: Vec2 = zero, in: Vec2 = zero, out: Vec2 = zero, ref_kind: Atom = none, ref_id: u32 = 0, flags: u32 = 0 };
// Initialization and table access.
pub const ObservedView = Row(Observed);
pub fn observed(tables: *Table.Registry) ObservedView {
    const editor_table = tables.findByName(Atom.from(observed_name)).?;
    return editor_table.getRow(.{ .row = 0, .generation = editor_table.rowGeneration(0) }, Row(Observed)).?;
}
pub fn ensure(mem: *memory.Memory, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    const previous = tables.scope;
    tables.scope = .editor;
    defer tables.scope = previous;
    try atoms.tryInternAll(&.{"tool_defaults"});
    try prepareSingleton(Observed, mem, atoms, tables, observed_name);
    _ = try ensureSingleton(Data, mem, atoms, tables, name);
    _ = try ensureSingleton(RigOptions, mem, atoms, tables, rig_options_name);
    _ = try ensureSingleton(Feedback, mem, atoms, tables, feedback_name);
    _ = try ensureSingleton(OutlinerTab, mem, atoms, tables, outliner_tab_name);
    _ = try ensureSingleton(Motion, mem, atoms, tables, motion_name);
    _ = try ensureTable(Selection, mem, atoms, tables, selection_name, 4096);
    _ = try ensureTable(Selection, mem, atoms, tables, collapse_name, 4096);
    _ = try ensureTable(Pending, mem, atoms, tables, pending_name, pending_capacity);
    _ = try ensureTable(Draft, mem, atoms, tables, draft_name, 1024);
    const atom_names = [_][]const u8{ "design", "draw", "select", "bone", "shape", "layer", "art", "bones", "clips", "poses" };
    for (atom_names) |atom_name| _ = Atom.from(atom_name);
}
/// Init-only: old singletons are compatibility checks, never repaired or reset.
pub fn prepareSingleton(comptime T: type, mem: *memory.Memory, atoms: *Atom.Registry, tables: *Table.Registry, table_name: []const u8) !void {
    try atoms.tryInternAll(&.{table_name});
    inline for (std.meta.fields(T)) |field| try atoms.tryInternAll(&.{field.name});
    const existing_table = tables.findByName(Atom.from(table_name));
    if (existing_table) |existing| {
        if (existing.rowCapacity() != 1 or !existing.required_singleton or existing.count() != 1 or !existing.isAllocated(0)) return error.InvalidEditorSingleton;
    }
    _ = try ensureSingleton(T, mem, atoms, tables, table_name);
}

pub fn prepareInit(mem: *memory.Memory, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    try atoms.tryInternAll(&.{ "design", "draw", "select", "bone", "shape", "layer", "tool_defaults", "art", "bones", "clips", "poses" });
    try prepareSingleton(Observed, mem, atoms, tables, observed_name);
    try prepareSingleton(Data, mem, atoms, tables, name);
    try prepareSingleton(RigOptions, mem, atoms, tables, rig_options_name);
    try prepareSingleton(Feedback, mem, atoms, tables, feedback_name);
    try prepareSingleton(OutlinerTab, mem, atoms, tables, outliner_tab_name);
    try prepareSingleton(Motion, mem, atoms, tables, motion_name);
    try prepareTable(Selection, mem, atoms, tables, selection_name, 4096);
    try prepareTable(Selection, mem, atoms, tables, collapse_name, 4096);
    try prepareTable(Pending, mem, atoms, tables, pending_name, pending_capacity);
    try prepareTable(Draft, mem, atoms, tables, draft_name, 1024);
}

/// The table the session's row is in, which holds its text: `prompt_text`, `pending_path`
/// and `status` are string cells of it.
pub fn table(tables: *Table.Registry) *Table {
    return tables.findByName(Atom.from(name)).?;
}

/// The table the feedback's row is in, which holds its `information`.
pub fn feedbackTable(tables: *Table.Registry) *Table {
    return tables.findByName(Atom.from(feedback_name)).?;
}

/// The session's status, in its table until the status next changes.
pub fn statusText(tables: *Table.Registry) []const u8 {
    return table(tables).textOf(get(tables).status.*);
}

/// The text of the open prompt as the session last took it.
pub fn promptText(tables: *Table.Registry) []const u8 {
    return table(tables).textOf(get(tables).prompt_text.*);
}

/// The information shown, in the feedback's table until it next changes.
pub fn informationText(tables: *Table.Registry) []const u8 {
    return feedbackTable(tables).textOf(feedback(tables).information.*);
}

pub fn get(tables: *Table.Registry) View {
    const state = tables.findByName(Atom.from(name)).?;
    return state.getRow(.{ .row = 0, .generation = state.rowGeneration(0) }, View).?;
}

/// Design and Rig edit the figure as it rests; Animate poses it.
pub fn atRest(editor: View) bool {
    return editor.mode.* == names.design or editor.mode.* == names.rig;
}

/// Rig always draws the bones it edits; the other tabs follow the overlay's toggle.
pub fn bonesShown(editor: View) bool {
    return editor.flags.* & 2 != 0 or editor.mode.* == names.rig;
}

pub const RigOptionsView = Row(RigOptions);
pub fn rigOptions(tables: *Table.Registry) RigOptionsView {
    const options = tables.findByName(Atom.from(rig_options_name)).?;
    return options.getRow(.{ .row = 0, .generation = options.rowGeneration(0) }, Row(RigOptions)).?;
}

pub const FeedbackView = Row(Feedback);
pub fn feedback(tables: *Table.Registry) FeedbackView {
    const state = tables.findByName(Atom.from(feedback_name)).?;
    return state.getRow(.{ .row = 0, .generation = state.rowGeneration(0) }, Row(Feedback)).?;
}
pub const OutlinerTabView = Row(OutlinerTab);
pub fn outlinerTab(tables: *Table.Registry) OutlinerTabView {
    const tab_table = tables.findByName(Atom.from(outliner_tab_name)).?;
    return tab_table.getRow(.{ .row = 0, .generation = tab_table.rowGeneration(0) }, Row(OutlinerTab)).?;
}
pub const MotionView = Row(Motion);
pub fn motion(tables: *Table.Registry) MotionView {
    const motion_table = tables.findByName(Atom.from(motion_name)).?;
    return motion_table.getRow(.{ .row = 0, .generation = motion_table.rowGeneration(0) }, Row(Motion)).?;
}
/// The pen's and joint fill's draft points, and the selection a press sets aside, a row each.
pub const DraftRows = sequencer.Rows(Row(Draft));
pub fn drafts(tables: *Table.Registry) DraftRows {
    return .of(tables.findByName(Atom.from(draft_name)).?);
}
/// The collapsed folders, a row each.
pub const CollapsedRows = sequencer.Rows(Row(Selection));
pub fn collapsedFolders(tables: *Table.Registry) CollapsedRows {
    return .of(tables.findByName(Atom.from(collapse_name)).?);
}
/// The requests sent to the host and not yet answered, a row each.
pub const PendingRows = sequencer.Rows(Row(Pending));
pub fn pendingCommands(tables: *Table.Registry) PendingRows {
    return .of(tables.findByName(Atom.from(pending_name)).?);
}
/// What is selected, a row per item.
pub const SelectionRows = sequencer.Rows(Row(Selection));
pub fn selections(tables: *Table.Registry) SelectionRows {
    return .of(tables.findByName(Atom.from(selection_name)).?);
}

pub fn prepareTable(comptime T: type, mem: *memory.Memory, atoms: *Atom.Registry, tables: *Table.Registry, table_name: []const u8, capacity: u32) !void {
    try atoms.tryInternAll(&.{table_name});
    if (tables.findByName(Atom.from(table_name))) |existing_table| {
        if (existing_table.rowCapacity() < capacity or existing_table.required_singleton) return error.InvalidEditorInitTable;
    }
    _ = try ensureTable(T, mem, atoms, tables, table_name, capacity);
}

// Shared editor-owned table operations.
pub fn Row(comptime T: type) type {
    const fields = std.meta.fields(T);
    var types: [fields.len]type = undefined;
    for (fields, 0..) |field, i| types[i] = *field.type;
    return @Struct(.auto, null, std.meta.fieldNames(T), &types, &@splat(.{}));
}
pub fn findRow(editor_table: *Table, doc: Atom, id: u32) ?Table.RowHandle {
    var rows = editor_table.readQuery(struct { doc: *Atom, id: *u32 });
    while (rows.next()) |row| if (row.view.doc.* == doc and row.view.id.* == id) return row.handle;
    return null;
}
pub fn writeRow(comptime T: type, editor_table: *Table, handle: Table.RowHandle, value: T) void {
    const row = editor_table.getRow(handle, Row(T)).?;
    inline for (std.meta.fields(T)) |field| @field(row, field.name).* = @field(value, field.name);
    editor_table.setRowMask(handle, row);
}
pub fn insertRow(comptime T: type, tables: *Table.Registry, handle: Table.Handle, value: T) !Table.RowHandle {
    const editor_table = tables.get(handle) orelse return error.StaleTable;
    const row = try editor_table.alloc();
    writeRow(T, editor_table, row, value);
    return row;
}
pub fn removeRows(editor_table: *Table, doc: Atom) void {
    while (true) {
        var rows = editor_table.readQuery(struct { doc: *Atom });
        var remove: ?Table.RowHandle = null;
        while (rows.next()) |row| if (row.view.doc.* == doc) {
            remove = row.handle;
            break;
        };
        editor_table.free(remove orelse break);
    }
}

pub fn readRow(comptime T: type, view: Row(T)) T {
    var value: T = undefined;
    inline for (std.meta.fields(T)) |field| @field(value, field.name) = @field(view, field.name).*;
    return value;
}

pub fn ensureTable(comptime T: type, mem: *memory.Memory, atoms: *Atom.Registry, tables: *Table.Registry, table_name: []const u8, capacity: u32) !*Table {
    return ensureTypedTable(T, mem, atoms, tables, table_name, capacity, false);
}
pub fn ensureSingleton(comptime T: type, mem: *memory.Memory, atoms: *Atom.Registry, tables: *Table.Registry, table_name: []const u8) !*Table {
    return ensureTypedTable(T, mem, atoms, tables, table_name, 1, true);
}
fn ensureTypedTable(comptime T: type, mem: *memory.Memory, atoms: *Atom.Registry, tables: *Table.Registry, table_name: []const u8, capacity: u32, comptime singleton: bool) !*Table {
    const table_allocator = try mem.tableScratchAllocator();
    var schema: Table.Schema = undefined;
    try schema.init(table_allocator.allocator, atoms, std.meta.fields(T).len);
    defer schema.deinit();
    inline for (std.meta.fields(T)) |field| {
        const kind: Table.ViewKind = comptime blk: {
            if (field.type == Atom) break :blk .atom;
            if (field.type == Vec2) break :blk .{ .vector = .{ .components = 2 } };
            if (field.type == Color) break :blk .color;
            if (field.type == Table.String) break :blk .text_field;
            if (field.type == Table.Bytes) break :blk .bytes;
            if (@typeInfo(field.type) == .array) {
                const array = @typeInfo(field.type).array;
                if (array.child == u8) break :blk .text_field;
                if (array.child == f32 and array.len <= 4) break :blk .{ .vector = .{ .components = array.len } };
                break :blk .hex;
            }
            if (std.mem.eql(u8, field.name, "flags") or std.mem.eql(u8, field.name, "mask")) break :blk .hex;
            break :blk .int;
        };
        try schema.addFieldFallible(field.name, field.type, kind);
    }
    if (singleton) return (try tables.ensureSingleton(&schema, Atom.from(table_name), T{}, .durable)).table;
    return (try tables.ensure(&schema, capacity, Atom.from(table_name), .durable)).table;
}

// Public figure reads and text utilities.
pub const api = figure;
pub fn figureContext(tables: *Table.Registry, atoms: *Atom.Registry) figure.Context {
    return .{ .memory = tables.memory, .tables = tables, .atoms = atoms };
}

/// `doc`'s authored content as the host published it for the editor's watch, which is the host's
/// until it next publishes a change: a caller copies what it keeps past its run, and frees none
/// of it.
/// `error.NotReady` unless it is at the authored revision the catalog publishes, as while the
/// document loads or before the editor's watch of it is answered.
pub fn readDefinition(tables: *Table.Registry, atoms: *Atom.Registry, doc: Atom) !api.read.Definition {
    const content = try watches.content(tables, doc);
    const info = definitionInfo(tables, atoms, doc) orelse return error.NotReady;
    if (content.revision != info.authored_revision) return error.NotReady;
    return content.*;
}

/// The reads of one update or render invocation: the published definitions (`readDefinition`),
/// and the outliners projected from them, which it owns in frame scratch. Do not retain it
/// across frame-scratch resets or the host's next publication of a change.
pub const ReadContext = struct {
    tables: *Table.Registry,
    atoms: *Atom.Registry,
    allocator: ?std.mem.Allocator = null,
    outlines: std.ArrayList(Outline) = .empty,

    const Outline = struct { doc: Atom, revision: u32, outline: api.Outliner };

    pub fn deinit(self: *ReadContext) void {
        const allocator = self.allocator orelse return;
        for (self.outlines.items) |entry| allocator.free(entry.outline.items);
        self.outlines.deinit(allocator);
        self.outlines = .empty;
    }

    pub fn readAllocator(self: *ReadContext) !std.mem.Allocator {
        if (self.allocator) |allocator| return allocator;
        const scratch = try self.tables.memory.frameScratchAllocator();
        self.allocator = scratch.allocator;
        return scratch.allocator;
    }

    pub fn definition(self: *ReadContext, doc: Atom) !api.read.Definition {
        return readDefinition(self.tables, self.atoms, doc);
    }

    /// `doc`'s outliner, projected once per revision of its published content.
    pub fn outliner(self: *ReadContext, doc: Atom) !api.Outliner {
        const snapshot = try self.definition(doc);
        for (self.outlines.items) |entry| {
            if (entry.doc == doc and entry.revision == snapshot.revision) return entry.outline;
        }
        const allocator = try self.readAllocator();
        const outline = try figure.projectOutliner(snapshot, allocator);
        errdefer allocator.free(outline.items);
        try self.outlines.append(allocator, .{ .doc = doc, .revision = snapshot.revision, .outline = outline });
        return outline;
    }
};

pub fn definitionInfo(tables: *Table.Registry, atoms: *Atom.Registry, doc: Atom) ?api.DefinitionInfo {
    return figure.definitionInfo(figureContext(tables, atoms), doc) catch null;
}
/// The file of the loaded figure `doc` as the host last published it (`figure.definitionPath`),
/// empty when it has none; null when no figure is loaded by `doc`. The host's until it next
/// publishes.
pub fn definitionPath(tables: *Table.Registry, atoms: *Atom.Registry, doc: Atom) ?[]const u8 {
    return figure.definitionPath(figureContext(tables, atoms), doc) catch null;
}
pub fn listDefinitions(tables: *Table.Registry, atoms: *Atom.Registry) ![]api.DefinitionEntry {
    const frame_allocator = (try tables.memory.frameScratchAllocator()).allocator;
    const entries = try figure.listDefinitions(figureContext(tables, atoms), frame_allocator);
    // Stores in other scopes belong to the game; the editor opens its own, so offers only those.
    var kept: usize = 0;
    for (entries) |entry| {
        if (!api.isProcessScope(entry.info.scope)) continue;
        entries[kept] = entry;
        kept += 1;
    }
    return entries[0..kept];
}
pub fn validatePromptDocument(tables: *Table.Registry, atoms: *Atom.Registry) !void {
    const editor = get(tables);
    if (editor.prompt_doc.* != editor.doc.*) return error.PromptDocumentChanged;
    if (editor.prompt_doc.* == none) return;
    const capture = observed(tables);
    if (capture.prompt_identity_valid.* == 0) return error.PromptDocumentChanged;
    const handle = api.DefinitionHandle{
        .table_index = capture.prompt_table.*,
        .table_generation = capture.prompt_table_generation.*,
        .row = capture.prompt_row.*,
        .generation = capture.prompt_generation.*,
    };
    const context = figureContext(tables, atoms);
    const doc = figure.resolveDefinition(context, handle) catch return error.PromptDocumentChanged;
    if (doc != editor.prompt_doc.*) return error.PromptDocumentChanged;
    const info = try figure.definitionInfo(context, doc);
    if (!info.editor_open) return error.PromptDocumentChanged;
}
pub fn findById(comptime T: type, rows: []const T, id: u32) ?T {
    for (rows) |row| if (row.id == id) return row;
    return null;
}
/// The value of `E` whose tag name `value` is `Atom.from` of, if any: for an enum stored as an
/// atom, read back without looking its name up.
pub fn enumFromAtom(comptime E: type, value: Atom) ?E {
    // Each tag's atom is a compile-time constant, so this unrolls to comparisons.
    inline for (@typeInfo(E).@"enum".fields) |field| {
        if (value == comptime Atom.from(field.name)) return @enumFromInt(field.value);
    }
    return null;
}

/// Whether `doc` has the object of `kind`, an object kind's atom or a point's (its shape): null
/// while its content is not published to the editor, which only the open definition's is, once
/// the editor's watch of it is answered.
pub fn objectExists(tables: *Table.Registry, atoms: *Atom.Registry, doc: Atom, kind: Atom, id: u32) ?bool {
    const object_kind = if (kind == names.point) api.ObjectKind.shape else enumFromAtom(api.ObjectKind, kind) orelse return false;
    const definition = readDefinition(tables, atoms, doc) catch return null;
    return definition.has(.{ .kind = object_kind, .id = id });
}

/// Whether `doc` has the object (`objectExists`), and false while that is not known.
pub fn isValidObject(tables: *Table.Registry, atoms: *Atom.Registry, doc: Atom, kind: Atom, id: u32) bool {
    return objectExists(tables, atoms, doc, kind, id) orelse false;
}

pub const editableLayer = figure.editableLayer;

pub fn text(bytes: []const u8) []const u8 {
    return bytes[0 .. std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len];
}
pub fn setText(dest: []u8, value: []const u8) !void {
    if (value.len >= dest.len) return error.TextTooLong;
    if (@intFromPtr(dest.ptr) > @intFromPtr(value.ptr) and @intFromPtr(dest.ptr) < @intFromPtr(value.ptr) + value.len)
        std.mem.copyBackwards(u8, dest[0..value.len], value)
    else
        std.mem.copyForwards(u8, dest[0..value.len], value);
    @memset(dest[value.len..], 0);
}

test "session ensure preserves registry singleton identity and editor state" {
    var mem: memory.Memory = undefined;
    mem.init(std.testing.allocator);
    defer mem.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&mem);
    defer atoms.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&mem, 8);
    defer tables.deinit();

    try ensure(&mem, &atoms, &tables);
    const handle = tables.findHandleByName(Atom.from(name)).?;
    const state = tables.get(handle).?;
    const row_handle = Table.RowHandle{ .row = 0, .generation = state.rowGeneration(0) };
    get(&tables).doc.* = names.session_document;
    get(&tables).gesture_active.* = 1;
    get(&tables).tx_active.* = 1;

    try ensure(&mem, &atoms, &tables);
    try std.testing.expect(state == tables.get(handle).?);
    try std.testing.expectEqual(@as(u32, 1), state.rowCapacity());
    try std.testing.expectEqual(@as(u32, 1), state.count());
    try std.testing.expect(state.required_singleton);
    const view = state.getRow(row_handle, View).?;
    try std.testing.expectEqual(names.session_document, view.doc.*);
    try std.testing.expectEqual(@as(u8, 1), view.gesture_active.*);
    try std.testing.expectEqual(@as(u8, 1), view.tx_active.*);
    try std.testing.expectEqual(Table.Owner.host, tables.scope);
}

/// The extent last computed for the open document, null when it draws nothing or when no
/// computation has finished for it yet.
pub fn figureExtent(capture: ObservedView, editor: View) ?api.Bounds {
    if (capture.bounds_doc.* != editor.doc.* or capture.bounds_present.* == 0) return null;
    return .{ .min = capture.bounds_min.*, .max = capture.bounds_max.* };
}
