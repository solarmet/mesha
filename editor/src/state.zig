const std = @import("std");
const mesha = @import("mesha");
const ui = mesha.ui;
const Atom = mesha.Atom;
const memory_mod = mesha.memory;
const Table = mesha.Table;
const input = mesha.input;

pub const windows_name = "editor_windows";
pub const authoring_ui_name = "editor_authoring_ui";

pub const app_state_name = "app_state";
pub const hit_regions_name = "app_hit_regions";
pub const view_focus_name = "editor_view_focus";
pub const active_inspector_name = "editor_active_inspector";

pub fn table(tables: *Table.Registry, atoms: *Atom.Registry, name: []const u8) *Table {
    return tables.findByName(atoms.intern(name)) orelse @panic("required inspector table missing");
}

/// New storage may initialize under admission. Existing controls are read-only.
pub fn prepareSingletonSchema(tables: *Table.Registry, schema: *const Table.Schema, name: Atom, defaults: anytype, lifetime: Table.Lifetime) !Table.Registry.EnsureResult {
    if (tables.findByName(name)) |existing| {
        if (existing.rowCapacity() != 1) return error.SchemaMismatch;
        if (!existing.required_singleton or existing.count() != 1 or !existing.isAllocated(0)) return error.InvalidEditorSingleton;
    }
    return tables.ensureSingleton(schema, name, defaults, lifetime);
}

pub const ViewFocusView = struct {
    id: *Atom,
    focus_clicks_disabled: *u8,
    /// Set as the editor's init is applied: the editor's next update asks resources for the
    /// table index, keybind tables and fonts. Init admission takes back the tables it makes,
    /// not rows appended to tables already there, so the requests wait for the update.
    startup_requests_pending: *u8,
};

const view_focus_defaults = .{
    .id = @as(Atom, @enumFromInt(0)),
    .focus_clicks_disabled = @as(u8, 0),
    .startup_requests_pending = @as(u8, 0),
};

pub fn ensureViewFocus(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    var schema: Table.Schema = undefined;
    try schema.init(scratch.allocator, atoms, 3);
    defer schema.deinit();
    schema.addField("id", Atom, .atom);
    schema.addField("focus_clicks_disabled", u8, .int);
    schema.addField("startup_requests_pending", u8, .int);
    const name = atoms.intern(view_focus_name);
    _ = try tables.ensureSingleton(&schema, name, view_focus_defaults, .durable);
}

pub fn prepareViewFocus(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    var schema: Table.Schema = undefined;
    try schema.init(scratch.allocator, atoms, 3);
    defer schema.deinit();
    try schema.addFieldFallible("id", Atom, .atom);
    try schema.addFieldFallible("focus_clicks_disabled", u8, .int);
    try schema.addFieldFallible("startup_requests_pending", u8, .int);
    const name = atoms.intern(view_focus_name);
    _ = try prepareSingletonSchema(tables, &schema, name, view_focus_defaults, .durable);
}

pub fn viewFocus(tables: *Table.Registry, atoms: *Atom.Registry) ViewFocusView {
    const focus = table(tables, atoms, view_focus_name);
    const handle: Table.RowHandle = .{ .row = 0, .generation = focus.rowGeneration(0) };
    return focus.getRow(handle, ViewFocusView) orelse @panic("editor_view_focus singleton missing");
}

pub const ActiveInspectorView = struct {
    focused: *u8,
    table_name: *Atom,
    row: *u32,
    generation: *u32,
    field_name: *Atom,
};

const active_inspector_defaults = .{
    .focused = @as(u8, 0),
    .table_name = @as(Atom, @enumFromInt(0)),
    .row = @as(u32, 0),
    .generation = @as(u32, 0),
    .field_name = @as(Atom, @enumFromInt(0)),
};

pub fn ensureActiveInspector(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    var schema: Table.Schema = undefined;
    try schema.init(scratch.allocator, atoms, 5);
    defer schema.deinit();
    schema.addField("focused", u8, .int);
    schema.addField("table_name", Atom, .atom);
    schema.addField("row", u32, .int);
    schema.addField("generation", u32, .int);
    schema.addField("field_name", Atom, .atom);
    _ = try tables.ensureSingleton(&schema, atoms.intern(active_inspector_name), active_inspector_defaults, .durable);
}

pub fn prepareActiveInspector(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    var schema: Table.Schema = undefined;
    try schema.init(scratch.allocator, atoms, 5);
    defer schema.deinit();
    try schema.addFieldFallible("focused", u8, .int);
    try schema.addFieldFallible("table_name", Atom, .atom);
    try schema.addFieldFallible("row", u32, .int);
    try schema.addFieldFallible("generation", u32, .int);
    try schema.addFieldFallible("field_name", Atom, .atom);
    _ = try prepareSingletonSchema(tables, &schema, atoms.intern(active_inspector_name), active_inspector_defaults, .durable);
}

pub fn activeInspector(tables: *Table.Registry, atoms: *Atom.Registry) ActiveInspectorView {
    const inspector = table(tables, atoms, active_inspector_name);
    const handle: Table.RowHandle = .{ .row = 0, .generation = inspector.rowGeneration(0) };
    return inspector.getRow(handle, ActiveInspectorView) orelse @panic("editor_active_inspector singleton missing");
}

pub fn setViewFocus(tables: *Table.Registry, atoms: *Atom.Registry, id: Atom) void {
    const focus = viewFocus(tables, atoms);
    focus.id.* = id;
}

pub fn clearViewFocus(tables: *Table.Registry, atoms: *Atom.Registry, id: Atom) void {
    const focus = viewFocus(tables, atoms);
    if (focus.id.* != id) return;
    focus.id.* = @enumFromInt(0);
}

pub fn fixedString(buf: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return buf[0..end];
}

pub const DrawerMode = enum(u32) { none, schema, metadata };

pub const Modal = enum(u32) { none, dirty_close, conflict };

/// Which of the metadata form's text fields has the keyboard.
pub const FormFocus = enum(u32) { none, meta_key, meta_value };

pub const AuthoringUiView = struct {
    drawer_mode: *u32,
    drawer_table: *Atom,

    selected_column: *u32,

    selected_meta_row: *u32,

    form_focus: *u32,
    /// The metadata form's fields, and the key of the entry it edits; empty for a new one.
    meta_key: *Table.String,
    meta_value: *Table.String,
    meta_original_key: *Table.String,
    modal: *u32,

    modal_window_row: *u32,
    modal_window_generation: *u32,

    status: *Table.String,

    /// What the inspector's one text editor holds (an `InspectorTextOwner`); 0 for nothing.
    text_owner_kind: *u8,
    /// Which one: a window's instance atom for a cell, a `FormFocus` for a form field.
    text_owner: *u64,
    /// For a cell, which edit of its window: a window's edits each have a serial.
    text_owner_serial: *u32,
    /// The loaded owner is being left: its last text is awaited before the next loads.
    text_switch_pending: *u8,
    /// The editor's state the windows last heard of: its text, caret and selection. Writing
    /// it is what draws the owner's panel again after a caret move.
    text_serial: *u32,
    /// How far the loaded owner's text is scrolled to keep the caret in it, kept by its drawing.
    text_scroll_x: *f32,
    /// A form submit awaits the loaded field's last text.
    form_submit_pending: *u8,
};

/// What the inspector's text editor holds: a table window's cell edit, or a form's text field.
pub const InspectorTextOwner = enum(u8) { none, cell, form_field };

const authoring_ui_defaults = .{
    .drawer_mode = @as(u32, 0),
    .drawer_table = @as(Atom, @enumFromInt(0)),
    .selected_column = @as(u32, 0),
    .selected_meta_row = @as(u32, 0),
    .form_focus = @as(u32, 0),
    .meta_key = Table.String{},
    .meta_value = Table.String{},
    .meta_original_key = Table.String{},
    .modal = @as(u32, 0),
    .modal_window_row = @as(u32, 0),
    .modal_window_generation = @as(u32, 0),
    .status = Table.String{},
    .text_owner_kind = @as(u8, 0),
    .text_owner = @as(u64, 0),
    .text_owner_serial = @as(u32, 0),
    .text_switch_pending = @as(u8, 0),
    .text_serial = @as(u32, 0),
    .text_scroll_x = @as(f32, 0),
    .form_submit_pending = @as(u8, 0),
};

pub fn ensureAuthoringUi(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    const allocator = scratch.allocator;
    var schema: Table.Schema = undefined;
    try schema.init(allocator, atoms, 23);
    defer schema.deinit();
    schema.addField("drawer_mode", u32, .int);
    schema.addField("drawer_table", Atom, .atom);
    schema.addField("selected_column", u32, .int);
    schema.addField("selected_meta_row", u32, .int);
    schema.addField("form_focus", u32, .int);
    schema.addField("meta_key", Table.String, .text_field);
    schema.addField("meta_value", Table.String, .text_field);
    schema.addField("meta_original_key", Table.String, .text_field);
    schema.addField("modal", u32, .int);
    schema.addField("modal_window_row", u32, .int);
    schema.addField("modal_window_generation", u32, .int);
    schema.addField("status", Table.String, .text_field);
    schema.addField("text_owner_kind", u8, .int);
    schema.addField("text_owner", u64, .int);
    schema.addField("text_owner_serial", u32, .int);
    schema.addField("text_switch_pending", u8, .int);
    schema.addField("text_serial", u32, .int);
    schema.addField("text_scroll_x", f32, .int);
    schema.addField("form_submit_pending", u8, .int);
    _ = try tables.ensureSingleton(&schema, atoms.intern(authoring_ui_name), authoring_ui_defaults, .durable);
}

pub fn prepareAuthoringUi(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    const allocator = scratch.allocator;
    var schema: Table.Schema = undefined;
    try schema.init(allocator, atoms, 23);
    defer schema.deinit();
    try schema.addFieldFallible("drawer_mode", u32, .int);
    try schema.addFieldFallible("drawer_table", Atom, .atom);
    try schema.addFieldFallible("selected_column", u32, .int);
    try schema.addFieldFallible("selected_meta_row", u32, .int);
    try schema.addFieldFallible("form_focus", u32, .int);
    try schema.addFieldFallible("meta_key", Table.String, .text_field);
    try schema.addFieldFallible("meta_value", Table.String, .text_field);
    try schema.addFieldFallible("meta_original_key", Table.String, .text_field);
    try schema.addFieldFallible("modal", u32, .int);
    try schema.addFieldFallible("modal_window_row", u32, .int);
    try schema.addFieldFallible("modal_window_generation", u32, .int);
    try schema.addFieldFallible("status", Table.String, .text_field);
    try schema.addFieldFallible("text_owner_kind", u8, .int);
    try schema.addFieldFallible("text_owner", u64, .int);
    try schema.addFieldFallible("text_owner_serial", u32, .int);
    try schema.addFieldFallible("text_switch_pending", u8, .int);
    try schema.addFieldFallible("text_serial", u32, .int);
    try schema.addFieldFallible("text_scroll_x", f32, .int);
    try schema.addFieldFallible("form_submit_pending", u8, .int);
    _ = try prepareSingletonSchema(tables, &schema, atoms.intern(authoring_ui_name), authoring_ui_defaults, .durable);
}

pub fn authoringUi(tables: *Table.Registry, atoms: *Atom.Registry) AuthoringUiView {
    const t = table(tables, atoms, authoring_ui_name);
    const handle = Table.RowHandle{ .row = 0, .generation = t.rowGeneration(0) };
    return t.getRow(handle, AuthoringUiView) orelse @panic("editor_authoring_ui singleton missing");
}

/// The element input reports the pointer over, for the editor's hover highlights.
pub fn hoveredElementId(tables: *Table.Registry) ?ui.ElementId {
    const hover = input.hovered(tables);
    if (!hover.isOver()) return null;
    return std.mem.bytesToValue(ui.ElementId, &hover.element);
}

pub fn hitRegions(tables: *Table.Registry, atoms: *Atom.Registry) *Table {
    return table(tables, atoms, hit_regions_name);
}
