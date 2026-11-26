const std = @import("std");
const mesha = @import("mesha");
const log = mesha.log;
const plugin = mesha.plugin;
const Atom = mesha.Atom;
const memory_mod = mesha.memory;
const Table = mesha.Table;
const roop = mesha.roop;
const stage = @import("stage.zig");
const editor = @import("editor.zig");
const sequencer = mesha.sequencer;
const editor_sequencer = @import("editor_sequencer.zig");
const app_commands = plugin.app_commands;

const Log = log.scope("editor");

pub export fn plugin_bind_log(state: ?*log.SharedState) callconv(.c) void {
    log.bindSharedState(state);
}

/// The layout this image was built with, which the loader compares with its own.
pub export fn plugin_abi() callconv(.c) u64 {
    return plugin.abi_fingerprint;
}

pub export fn plugin_tag(atoms: *Atom.Registry) callconv(.c) Atom {
    _ = atoms;
    return Atom.from("editor");
}

pub export fn plugin_init(memory: *memory_mod.Memory, atoms: *Atom.Registry, tables: *Table.Registry) callconv(.c) bool {
    prepareInit(memory, atoms, tables) catch return false;
    return true;
}

const fail_stage = @import("root_init_options").fail_stage;

/// This file's profile zones, in its log scope.
const Zone = enum { editor_sequencer };

fn selected(comptime prefix: []const u8, comptime E: type) ?E {
    inline for (std.meta.fields(E)) |field| {
        if (comptime std.mem.eql(u8, fail_stage, prefix ++ field.name)) return @enumFromInt(field.value);
    }
    return null;
}

comptime {
    if (fail_stage.len != 0 and !std.mem.eql(u8, fail_stage, "root.final_validation") and
        selected("app.", stage.AppInitCheckpoint) == null and
        selected("editor.", editor.EditorInitCheckpoint) == null)
        @compileError("unknown root init fail_stage");
}

fn prepareInit(memory: *memory_mod.Memory, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    // The editor borrows an already-initialized facade; no asset policy or
    // domain preparation is part of its admission.
    // The figure system creates its sketch tables at its init and destroys them at its
    // deinit, so the table exists exactly while the figure system is initialized.
    const sketches_name = atoms.intern(mesha.figure.sketches_table_name);
    const sketches = tables.findByName(sketches_name);
    if (sketches == null) return error.NotInitialized;
    const previous_scope = tables.scope;
    defer tables.scope = previous_scope;
    // Before the admission, which takes no schema registrations: a schema registered for an
    // init that is then refused stays, and registering it again is no change.
    try @import("table_view_fixture.zig").registerSchema(try memory.tableScratchAllocator(), atoms, tables);
    const memory_token = try memory.beginInitAdmission();
    errdefer if (!memory.abortInitAdmission(memory_token)) @panic("root memory abort protocol");
    const table_token = try tables.beginInitAdmission();
    errdefer if (!tables.abortInitAdmission(table_token)) @panic("root tables abort protocol");
    // The systems' names are interned once, here, so their kernels never intern.
    const figure_authoring = editor.figure_workspace.figureAuthoring();
    const frame_root = editor_sequencer.frameRoot(&figure_authoring);
    try sequencer.internNames(atoms, &frame_root.sequencer());
    // A system's name names its inbox: one shared with a host system would lose messages.
    try sequencer.checkNamesFree(tables, &frame_root.sequencer());
    var app_plan = try stage.prepareAppInitWithCheckpoint(memory, atoms, tables, selected("app.", stage.AppInitCheckpoint));
    tables.scope = .editor;
    var editor_plan = try editor.prepareEditorInit(memory, atoms, tables, .{ .reject_after = selected("editor.", editor.EditorInitCheckpoint) });
    defer editor_plan.deinit();
    tables.scope = previous_scope;
    // The editor's own publication: editor focus; host figures are initialized independently and
    // are never part of the editor's admission.
    try editor_plan.stage();
    try app_plan.validate();
    try editor_plan.validate();
    if (comptime std.mem.eql(u8, fail_stage, "root.final_validation")) return error.RootFinalValidationInjectedFailure;
    try tables.validateInitAdmission(table_token);
    try memory.validateInitAdmission(memory_token);
    // Frozen terminal interval: no pushes, intern, allocation, or rejection.
    if (!tables.commitInitAdmission(table_token)) @panic("root tables commit protocol");
    if (!memory.commitInitAdmission(memory_token)) @panic("root memory commit protocol");
    app_plan.apply();
    editor_plan.apply();
}

/// `layer` is main's run's journal layer: the editor's sequencer runs as its child.
pub export fn plugin_update(memory: *memory_mod.Memory, atoms: *Atom.Registry, tables: *Table.Registry, layer: *mesha.journal.Layer) callconv(.c) void {
    const previous_scope = tables.scope;
    tables.scope = .editor;
    {
        const trace_zone = Log.zone(Zone.editor_sequencer);
        defer trace_zone.end();
        const figure_authoring = editor.figure_workspace.figureAuthoring();
        const frame_root = editor_sequencer.frameRoot(&figure_authoring);
        editor_sequencer.run(memory, atoms, tables, &frame_root.sequencer(), layer);
    }
    tables.scope = previous_scope;
}

pub export fn plugin_process_cmd(memory: *memory_mod.Memory, atoms: *Atom.Registry, tables: *Table.Registry, payload: *plugin.app_commands.Payload) callconv(.c) sequencer.Applied {
    const previous_scope = tables.scope;
    tables.scope = .editor;
    defer tables.scope = previous_scope;
    // The hook's signature is the host's: applying a command needs no memory of its own.
    _ = memory;
    return editor.processCmd(tables, atoms, payload);
}

/// One panel, header and all, in `frame`, its frame in the window: the editor draws its own
/// panels, and over the panel that shows the world, which is another plugin's and drawn
/// already, its debug figures, outside the editor's tables.
pub export fn plugin_render_panel(memory: *memory_mod.Memory, tables: *Table.Registry, atoms: *Atom.Registry, panel: Atom, frame: plugin.Viewport, ctx: *roop.Context) callconv(.c) void {
    if (stage.showsWorld(tables, panel)) stage.render(tables, atoms, frame, ctx);
    const previous = tables.scope;
    tables.scope = .editor;
    defer tables.scope = previous;
    editor.renderPanel(memory, tables, atoms, panel, frame, ctx);
}

pub export fn plugin_render_action_palette(memory: *memory_mod.Memory, tables: *Table.Registry, atoms: *Atom.Registry, viewport: plugin.Viewport, ctx: *roop.Context) callconv(.c) void {
    const previous = tables.scope;
    tables.scope = .editor;
    defer tables.scope = previous;
    editor.renderActionPalette(memory, tables, atoms, viewport, ctx);
}

pub export fn plugin_begin_frame(tables: *Table.Registry, atoms: *Atom.Registry) callconv(.c) void {
    stage.beginFrame(tables, atoms);
}
