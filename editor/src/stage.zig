const std = @import("std");
const mesha = @import("mesha");
const ui = mesha.ui;
const plugin = mesha.plugin;
const input = mesha.input;
const os = mesha.os;
const panels_mod = mesha.panels;
const time = mesha.time;
const resources = mesha.resources;
const camera_mod = mesha.camera;
const Atom = mesha.Atom;
const memory_mod = mesha.memory;
const Table = mesha.Table;
const math = mesha.math;
const Vec2f = math.Vec2f;
const roop = mesha.roop;
const figure = mesha.figure;
const Camera2D = camera_mod.Camera2D;
const state_mod = @import("stage_state.zig");
const modes = @import("modes.zig");
const keybinds = mesha.keybinds;
const Log = mesha.log.scope("app");
const hits_mod = @import("hits.zig");
const sequencer = mesha.sequencer;

/// The app around the game stage: the window's size, the stage's focus and the app's own
/// actions. No panel has this root, so its system draws none again.
pub const app_stage_root = Atom.from("app_stage");

pub const kScreenW: f32 = 1920;
pub const kScreenH: f32 = 1080;
/// A starting size, not a limit: the table grows when a frame needs more and keeps that capacity.
/// Every row is resident whether used or not, and each frame's clear walks all of them.
pub const initial_hit_region_rows: u32 = 256;
const Msg = enum(u64) {
    quit = Atom.from("quit").value(),
    _,
};

pub const world_id: Atom = Atom.from("world");
pub const ui_id: Atom = Atom.from("ui");

/// The app's actions, of the mode `modes.stage`, which is active while the panel that shows
/// the world has the focus. That panel is another plugin's, so these editor actions answer
/// from any panel.
pub const app_actions = [_]plugin.action_api.Def{
    .{ .name = "quit", .tag = "quit", .doc = "Quit the application", .scope = .global },
};

/// The keys of `app_actions`.
pub const stage_keys = [_]keybinds.KeyDef{
    .{ .chord = "q", .action = .{ "stage", "quit" } },
};

/// Eager fixture setup bypasses root's combined initialization admission.
pub fn initForTests(memory: *memory_mod.Memory, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    const scratch = try memory.frameScratchAllocator();

    _ = atoms.intern("app");
    atoms.internEnum(Msg);
    try state_mod.ensureAppState(scratch, atoms, tables, kScreenW, kScreenH);
    try state_mod.ensureDebugVisualizers(scratch, atoms, tables);
    try state_mod.ensureDebugVisualizerDraws(scratch, atoms, tables);

    var hit_schema: Table.Schema = undefined;
    try ui.initHitRegionSchema(&hit_schema, scratch, atoms);
    defer hit_schema.deinit();
    const hit_name = atoms.intern(state_mod.hit_regions_name);
    _ = try tables.ensure(&hit_schema, initial_hit_region_rows, hit_name, .durable);
    try modes.ensurePanelModes(scratch, atoms, tables, panel_modes_table_name);
}

/// Local to one init invocation. Root owns resource admissions and final validation.
pub const PreparedAppInit = struct {
    store: *Table.Registry,
    atoms: *Atom.Registry,
    state_handle: Table.Handle,
    state_table: *Table,
    state_schema: *Table.SchemaRegistry.Record,
    state_revision: u64,
    state_generation: u32,
    debug_default: state_mod.PreparedDebugDefault,
    applied: bool = false,

    pub fn validate(self: *const PreparedAppInit) !void {
        if (self.applied) return error.InvalidAppInitPlan;
        try self.debug_default.validate();
        const tab = self.store.get(self.state_handle) orelse return error.StaleAppInit;
        if (tab != self.state_table or tab.schema_ref != self.state_schema or tab.revision != self.state_revision or tab.rowGeneration(0) != self.state_generation or !tab.isAllocated(0)) return error.StaleAppInit;
    }

    /// Terminal only: resources committed and combined row reservations validated. No
    /// allocation or atom lookup occurs here.
    pub fn apply(self: *PreparedAppInit) void {
        if (self.applied) @panic("invalid app init terminal apply");
        self.debug_default.apply();
        self.applied = true;
    }
};

pub const AppInitCheckpoint = enum {
    atoms,
    state,
    debug_default,
    debug_draws,
    hits,
};

fn appInitCheckpoint(selected: ?AppInitCheckpoint, reached: AppInitCheckpoint) !void {
    if (selected == reached) return error.AppInitInjectedFailure;
}

pub fn prepareAppInit(memory: *memory_mod.Memory, atoms: *Atom.Registry, tables: *Table.Registry) !PreparedAppInit {
    return prepareAppInitWithCheckpoint(memory, atoms, tables, null);
}

/// Injection occurs after each named real preparation transition, never in the tail.
pub fn prepareAppInitWithCheckpoint(memory: *memory_mod.Memory, atoms: *Atom.Registry, tables: *Table.Registry, fail_after: ?AppInitCheckpoint) !PreparedAppInit {
    if (memory.admission == null or tables.admission == null) return error.AppAdmissionRequired;
    try atoms.tryInternAll(&.{
        "view_focused",
        "screen_w",
        "screen_h",
        "debug_figure_doc",
        "drawn_hover",
        "present",
        "row",
        "generation",
        "visualizer",
        "enabled",
        "hit_regions",
        "id",
        "kind",
        "x",
        "y",
        "radius",
        "length",
        "width",
        "app_state",
        "app_debugviz",
        "app_debug_visualizer_draws",
        "app_hit_regions",
        "app",
        "pos",
        "size",
        "hover",
        "tooltip",
        "depth",
    });
    for (ui.region_routes) |region_route| try atoms.tryInternAll(&.{ region_route.tag, region_route.user_data, region_route.inbox });
    const message_names = comptime sequencer.enumNames(Msg);
    try atoms.tryInternAll(&message_names);
    const scratch = try memory.frameScratchAllocator();
    try appInitCheckpoint(fail_after, .atoms);
    try state_mod.prepareAppState(scratch, atoms, tables, kScreenW, kScreenH);
    try appInitCheckpoint(fail_after, .state);
    const debug_default = try state_mod.prepareDebugVisualizers(scratch, atoms, tables);
    try appInitCheckpoint(fail_after, .debug_default);
    try state_mod.prepareDebugVisualizerDraws(scratch, atoms, tables);
    try appInitCheckpoint(fail_after, .debug_draws);
    var hit_schema: Table.Schema = undefined;
    try prepareHitRegionSchema(&hit_schema, scratch, atoms);
    defer hit_schema.deinit();
    const hit_name = Atom.from(state_mod.hit_regions_name);
    _ = try tables.ensure(&hit_schema, initial_hit_region_rows, hit_name, .durable);
    try modes.ensurePanelModes(scratch, atoms, tables, panel_modes_table_name);
    try appInitCheckpoint(fail_after, .hits);
    const state_handle = tables.findHandleByName(Atom.from(state_mod.app_state_name)).?;
    const state_table = tables.get(state_handle).?;
    return .{
        .debug_default = debug_default,
        .store = tables,
        .atoms = atoms,
        .state_handle = state_handle,
        .state_table = state_table,
        .state_schema = state_table.schema_ref,
        .state_revision = state_table.revision,
        .state_generation = state_table.rowGeneration(0),
    };
}

pub fn hitRegions(tables: *Table.Registry, atoms: *Atom.Registry) *Table {
    return state_mod.table(tables, atoms, state_mod.hit_regions_name);
}

// ---- the system ------------------------------------------------------------------------------

/// The app around the game stage, under `app_stage_root`: the window's size and
/// whether the game stage has the focus, which it reads, and the app's actions. It writes
/// `app_state`'s rows, and watches the debug figure `app_state` names (`watchDebugFigure`).
pub fn system() sequencer.System {
    return .{
        .name = system_name,
        .root = app_stage_root,
        .claims = claims,
        .access = access,
        .kernels = &.{
            .{ .name = "app_stage.follow_window", .run = followWindow },
            .{ .name = "app_stage.take_messages", .run = takeMessages },
            .{ .name = "app_stage.follow_modes", .run = followModes },
            .{ .name = "app_stage.watch_debug_figure", .run = watchDebugFigure },
        },
    };
}

const system_name = "app_stage";

const watches_table = Atom.from(figure.watches_table_name);
/// The key of the app's one watch (`mesha.figure.Watch.key`): the debug figure's working pose.
const debug_figure_key: u32 = 0;
const no_figure: Atom = @enumFromInt(0);

/// Watches the debug figure `app_state` names, in its working pose, for its drawing alone,
/// prepared for where `render` draws it. None while no figure is named or the world shows
/// nowhere, and nothing without the figure host's watches, as in a test of the app alone.
fn watchDebugFigure(pass: *sequencer.Pass) !void {
    if (!pass.declares(watches_table)) return;
    const frame = pass.frame;
    // Through the run, so the sequencer names this system the row's subscriber.
    _ = try pass.writeTable(watches_table);
    const app = try pass.readSingleton(app_state_table, state_mod.AppState);
    const doc = app.debug_figure_doc.*;
    if (doc == no_figure) return;
    const drawn_under = debugFigureTransform(frame.tables, frame.atoms) orelse return;
    const watch_rows = figure.Watches.of(frame.memory, frame.tables, figure.watches_table_name);
    try watch_rows.tryPush(.{
        .key = debug_figure_key,
        .definition = doc,
        .pose = .working,
        .wants = .{ .drawing = true },
        .draw = .{ .transform = drawn_under },
    });
}

/// The transform `render` draws the debug figure under, in the target of the panel that shows
/// the world, which begins at the panel's corner: the world's view offset in the panel, then
/// its centre. Null while the world shows nowhere or its view is empty.
fn debugFigureTransform(tables: *Table.Registry, atoms: *Atom.Registry) ?math.Affine2f {
    const shown = worldView(tables) orelse return null;
    if (shown.size.x <= 0 or shown.size.y <= 0) return null;
    const world_panel = worldPanel(tables) orelse return null;
    const panel = panels_mod.panelFor(tables, atoms, world_panel) orelse return null;
    // In the order `render` translates the context, so the two agree exactly.
    const view_x = shown.origin.x - panel.frame.x;
    const view_y = shown.origin.y - panel.frame.y;
    const centre_x = shown.size.x * 0.5;
    const centre_y = shown.size.y * 0.5;
    return .{ .a = 1, .b = 0, .c = 0, .d = 1, .tx = view_x + centre_x, .ty = view_y + centre_y };
}

/// The modes of the panel that shows the world, a `modes.PanelModesRow`.
pub const panel_modes_table_name = "app_stage_panel_modes";

/// The mode of the panel that shows the world, `stage`, whose keys the editor leaves the
/// game; no panel has it while the world shows nowhere.
fn followModes(pass: *sequencer.Pass) !void {
    const world_panel = worldPanel(pass.frame.tables) orelse {
        try modes.syncPanelModes(pass, panel_modes_table_name, &.{});
        return;
    };
    const wanted = [_]modes.PanelMajor{.{ .panel = world_panel, .major = modes.stage }};
    try modes.syncPanelModes(pass, panel_modes_table_name, &wanted);
}

const world_view_table = Atom.from(mesha.world.view_table_name);

/// The row of `world_view`, or null without the host's table.
fn worldView(tables: *Table.Registry) ?Table.ReadView(mesha.world.View) {
    const table = tables.findByName(world_view_table) orelse return null;
    const row: Table.RowHandle = .{ .row = 0, .generation = table.rowGeneration(0) };
    return table.readRow(row, mesha.world.View);
}

/// The panel `world_view` says the world shows under, or null while it names none.
fn worldPanel(tables: *Table.Registry) ?Atom {
    const shown = worldView(tables) orelse return null;
    const no_panel: Atom = @enumFromInt(0);
    if (shown.panel.* == no_panel) return null;
    return shown.panel.*;
}

const os_window = Atom.from(os.window_table_name);
const panel_nodes = Atom.from(panels_mod.nodes_table_name);
const panel_state = Atom.from(panels_mod.state_table_name);

/// Keeps `app_state` showing the window's size and whether the panel that shows the world has
/// the focus.
fn followWindow(pass: *sequencer.Pass) !void {
    const frame = pass.frame;
    const app = try pass.readSingleton(app_state_table, state_mod.AppState);
    var screen_w = app.screen_w.*;
    var screen_h = app.screen_h.*;
    // Without the window, as in a headless run, the size stays as it is.
    if (pass.declares(os_window)) {
        const window = try pass.readSingleton(os_window, os.WindowView);
        if (window.width.* != 0 and window.height.* != 0) {
            screen_w = @floatFromInt(window.width.*);
            screen_h = @floatFromInt(window.height.*);
        }
    }
    const focused = panels_mod.focusedTarget(frame.tables, frame.atoms).id;
    const world_panel = worldPanel(frame.tables);
    const stage_focused: u8 = @intFromBool(world_panel != null and focused == world_panel.?);
    const same_window = screen_w == app.screen_w.* and screen_h == app.screen_h.* and stage_focused == app.stage_focused.*;
    if (same_window) return;
    const writable = try pass.writeSingleton(app_state_table, state_mod.AppState);
    writable.screen_w.* = screen_w;
    writable.screen_h.* = screen_h;
    writable.stage_focused.* = stage_focused;
}

pub fn claims(tag: Atom) bool {
    return switch (tag.to(Msg)) {
        _ => false,
        else => true,
    };
}

const app_state_table = Atom.from(state_mod.app_state_name);

fn access(frame: *const sequencer.Frame) sequencer.Access {
    var result: sequencer.Access = .{};
    // Every run follows the window and the focus into `app_state`.
    result.write(app_state_table);
    result.readAll(&.{ panel_nodes, panel_state });
    // The debug figure's watch, where the figure host keeps watches.
    result.writeIfPresent(frame.tables, watches_table);
    if (frame.tables.findByName(os_window) != null) result.read(os_window);
    if (frame.tables.findByName(world_view_table) != null) result.read(world_view_table);
    modes.declarePanelModes(&result, frame.tables, panel_modes_table_name);
    if (frame.messages.len == 0) return result;
    // `quit` asks the window to close.
    result.writeIfPresent(frame.tables, Atom.from(os.commands_table_name));
    return result;
}

fn takeMessages(pass: *sequencer.Pass) !void {
    const frame = pass.frame;
    for (frame.messages) |received| apply(frame.tables, received.tag);
}

/// What a message to the app does, by its tag.
pub fn apply(tables: *Table.Registry, tag: Atom) void {
    switch (tag.to(Msg)) {
        .quit => os.request(tables.memory, tables, .{ .request_close = .{} }),
        _ => {},
    }
}

/// The app's actions, which its system runs.
pub fn declareActions(atoms: *Atom.Registry, sink: plugin.ActionSink) void {
    const inbox = sequencer.inboxOf(system());
    for (app_actions) |def| keybinds.pushActionDefinitions(atoms, sink, modes.stage, inbox, &.{.{ .def = def }});
}

/// The keys of the app's actions, `stage_keys`, as a keymap of defaults, built once as the editor
/// starts (`keybinds.buildKeymap`); its bindings are in `allocator`.
pub fn buildKeymap(allocator: std.mem.Allocator, atoms: *Atom.Registry) error{OutOfMemory}!plugin.action_api.Keymap {
    return keybinds.buildKeymap(allocator, atoms, .{ .mode = modes.stage, .rank = .default, .keys = &stage_keys });
}

pub fn beginFrame(tables: *Table.Registry, atoms: *Atom.Registry) void {
    state_mod.debugVisualizerDraws(tables, atoms).clear();
    // The host clears the hit regions: a panel that keeps last frame's drawing keeps its own.
}

pub fn renderScreenDebugVisualizers(tables: *Table.Registry, atoms: *Atom.Registry, viewport: plugin.Viewport, ctx: anytype) void {
    const visualizers = state_mod.debugVisualizerDraws(tables, atoms);
    const rect_kind = atoms.intern("rect");
    const circle_kind = atoms.intern("circle");
    const offset_x = viewport.x;
    const offset_y = viewport.y;

    var rects = visualizers.query(struct { kind: *Atom, x: *f32, y: *f32, length: *f32, width: *f32 });
    while (rects.next()) |item| {
        if (item.view.kind.* != rect_kind or item.view.length.* <= 0 or item.view.width.* <= 0) continue;
        ctx.beginPath();
        ctx.rect(item.view.x.* - offset_x, item.view.y.* - offset_y, item.view.length.*, item.view.width.*);
        ctx.strokeColor(roop.rgba(255, 168, 168, 180));
        ctx.strokeWidth(1.5);
        ctx.stroke();
    }

    var circles = visualizers.query(struct { kind: *Atom, x: *f32, y: *f32, radius: *f32 });
    while (circles.next()) |item| {
        if (item.view.kind.* != circle_kind or item.view.radius.* <= 0) continue;
        ctx.beginPath();
        ctx.arc(item.view.x.* - offset_x, item.view.y.* - offset_y, item.view.radius.*, 0, 6.28318530718, .cw);
        ctx.strokeColor(roop.rgba(255, 168, 168, 180));
        ctx.strokeWidth(1.5);
        ctx.stroke();
    }
}

pub fn addHitRegionVisualizers(tables: *Table.Registry, atoms: *Atom.Registry, hits: *Table) void {
    const id = atoms.intern("hit_regions");
    const kind = atoms.intern("rect");
    var q = hits.query(struct { pos: *math.Vec2f, size: *math.Vec2f });
    while (q.next()) |item| {
        _ = state_mod.addDebugVisualizer(tables, atoms, .{
            .id = id,
            .kind = kind,
            .x = item.view.pos.x,
            .y = item.view.pos.y,
            .length = item.view.size.x,
            .width = item.view.size.y,
        });
    }
}

/// What one figure may draw; a figure over it is skipped whole.
pub const figure_reserve = figure.Reserve{ .draws = 256, .uniforms = 256, .gpu_points = 4096, .shapes = 256, .gpu_vertices = 16384, .cpu_vertices = 8192, .indirect_draws = 256 };

/// Whether `panel` is the one the world shows under, where the editor draws its debug figures.
pub fn showsWorld(tables: *Table.Registry, panel: Atom) bool {
    const world_panel = worldPanel(tables) orelse return false;
    return world_panel == panel;
}

/// Draws the editor's debug figures over the world, in the panel that shows it: `frame` is
/// that panel's frame in the window, which `ctx` begins at. They are placed in the world's
/// view, as `world_view` gives it.
pub fn render(tables: *Table.Registry, atoms: *Atom.Registry, frame: plugin.Viewport, ctx: *roop.Context) void {
    const shown = worldView(tables) orelse return;
    const viewport: plugin.Viewport = .{ .x = shown.origin.x, .y = shown.origin.y, .width = shown.size.x, .height = shown.size.y };
    if (viewport.width <= 0 or viewport.height <= 0) return;
    ctx.save();
    defer ctx.restore();
    ctx.translate(viewport.x - frame.x, viewport.y - frame.y);

    const state = state_mod.app(tables, atoms);
    const hits = hitRegions(tables, atoms);
    {
        if (state.debug_figure_doc.* != @as(Atom, @enumFromInt(0))) {
            ctx.save();
            ctx.translate(viewport.width * 0.5, viewport.height * 0.5);
            renderDebugFigure(tables, state.debug_figure_doc.*, ctx) catch {};
            ctx.restore();
        }
        if (state_mod.debugVisualizerEnabled(tables, atoms, "hit_regions")) {
            addHitRegionVisualizers(tables, atoms, hits);
        }
        renderScreenDebugVisualizers(tables, atoms, viewport, ctx);
    }
}

test {
    _ = @import("stage_tests.zig");
}

test "app preparation warm abort preserves debug defaults and hit regions" {
    var memory: memory_mod.Memory = undefined;
    memory.init(std.testing.allocator);
    defer memory.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&memory);
    var tables: Table.Registry = undefined;
    try tables.init(&memory, 64);
    defer tables.deinit();
    try initForTests(&memory, &atoms, &tables);
    const state = state_mod.app(&tables, &atoms);
    const hit_table = hitRegions(&tables, &atoms);
    const hit = hit_table.insert(.{ .id = [_]u8{9} ** 16 });
    const hit_revision = hit_table.revision;
    state.stage_focused.* = 0;
    const debug = state_mod.table(&tables, &atoms, state_mod.debugviz_name);
    debug.clear();
    const revision = debug.revision;
    const mem = try memory.beginInitAdmission();
    defer _ = memory.abortInitAdmission(mem);
    const tab = try tables.beginInitAdmission();
    defer _ = tables.abortInitAdmission(tab);
    inline for (std.meta.tags(AppInitCheckpoint)) |checkpoint| {
        try std.testing.expectError(error.AppInitInjectedFailure, prepareAppInitWithCheckpoint(&memory, &atoms, &tables, checkpoint));
        try std.testing.expectEqual(@as(u32, 0), debug.count());
    }
    _ = try prepareAppInit(&memory, &atoms, &tables);
    try std.testing.expectEqual(@as(u8, 0), state.stage_focused.*);
    try std.testing.expectEqual(@as(u32, 0), debug.count());
    try std.testing.expectEqual(revision, debug.revision);
    try std.testing.expectEqual(hit_revision, hit_table.revision);
    try std.testing.expectEqual([_]u8{9} ** 16, hit_table.getField([16]u8, hit, "id").?.*);
}

test "app preparation missing resources abort then terminal commit once" {
    var memory: memory_mod.Memory = undefined;
    memory.init(std.testing.allocator);
    defer memory.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&memory);
    var tables: Table.Registry = undefined;
    try tables.init(&memory, 64);
    defer tables.deinit();
    for (0..2) |pass| {
        const mem = try memory.beginInitAdmission();
        const tab = try tables.beginInitAdmission();
        var prepared = try prepareAppInit(&memory, &atoms, &tables);
        if (pass == 0) {
            try std.testing.expect(tables.abortInitAdmission(tab));
            try std.testing.expect(memory.abortInitAdmission(mem));
            try std.testing.expect(tables.findByName(Atom.from(state_mod.app_state_name)) == null);
            continue;
        }
        try prepared.validate();
        try tables.validateInitAdmission(tab);
        try memory.validateInitAdmission(mem);
        try std.testing.expect(tables.commitInitAdmission(tab));
        try std.testing.expect(memory.commitInitAdmission(mem));
        prepared.apply();
        try std.testing.expectEqual(@as(u32, 1), prepared.debug_default.destination.count());
    }
}

test "app preparation debug default full and singleton flag compatibility reject" {
    var memory: memory_mod.Memory = undefined;
    memory.init(std.testing.allocator);
    defer memory.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&memory);
    var tables: Table.Registry = undefined;
    try tables.init(&memory, 64);
    defer tables.deinit();
    try initForTests(&memory, &atoms, &tables);
    const debug = state_mod.table(&tables, &atoms, state_mod.debugviz_name);
    debug.clear();
    for (0..debug.rowCapacity()) |_| _ = debug.insert(.{ .visualizer = world_id });
    const revision = debug.revision;
    const singleton = state_mod.table(&tables, &atoms, state_mod.app_state_name);
    const mem = try memory.beginInitAdmission();
    defer _ = memory.abortInitAdmission(mem);
    const tab = try tables.beginInitAdmission();
    defer _ = tables.abortInitAdmission(tab);
    try std.testing.expectError(error.TableFull, prepareAppInit(&memory, &atoms, &tables));
    try std.testing.expectEqual(revision, debug.revision);
    try std.testing.expectEqual(debug.rowCapacity(), debug.count());
    // An accepted legacy singleton without the required flag is incompatible;
    // preparation must reject rather than silently repair the old flag.
    singleton.required_singleton = false;
    defer singleton.required_singleton = true;
    try std.testing.expectError(error.AdmissionMutationRejected, prepareAppInit(&memory, &atoms, &tables));
    try std.testing.expect(!singleton.required_singleton);
}

/// `ui.initHitRegionSchema`'s columns, each added fallibly, in its order.
fn prepareHitRegionSchema(schema: *Table.Schema, scratch: memory_mod.Scratch, atoms: *Atom.Registry) !void {
    try schema.init(scratch.allocator, atoms, 7 + 3 * ui.region_routes.len);
    errdefer schema.deinit();
    try schema.addFieldFallible("pos", math.Vec2f, .{ .vector = .{ .components = 2 } });
    try schema.addFieldFallible("size", math.Vec2f, .{ .vector = .{ .components = 2 } });
    try schema.addFieldFallible("hover", u8, .int);
    try schema.addFieldFallible("tooltip", Table.String, .text_field);
    try schema.addFieldFallible("id", [16]u8, .hex);
    try schema.addFieldFallible("depth", u32, .int);
    try schema.addFieldFallible("cursor", os.CursorKind, .int);
    for (ui.region_routes) |region_route| {
        try schema.addFieldFallible(region_route.tag, Atom, .atom);
        try schema.addFieldFallible(region_route.user_data, Table.Bytes, .bytes);
        try schema.addFieldFallible(region_route.inbox, Atom, .atom);
    }
}

test "app preparation hit schema every native field name allocation" {
    var memory: memory_mod.Memory = undefined;
    memory.init(std.testing.allocator);
    defer memory.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&memory);
    defer atoms.deinit();
    {
        const build = prepareHitRegionSchema;
        var count = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
        var schema: Table.Schema = undefined;
        try build(&schema, .{ .allocator = count.allocator() }, &atoms);
        defer schema.deinit();
        var runtime: Table.Schema = undefined;
        try ui.initHitRegionSchema(&runtime, .{ .allocator = std.testing.allocator }, &atoms);
        defer runtime.deinit();
        try std.testing.expectEqualDeep(runtime.fields, schema.fields);
        for (1..count.alloc_index) |failure| {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = failure, .resize_fail_index = 0 });
            var rejected: Table.Schema = undefined;
            try std.testing.expectError(error.OutOfMemory, build(&rejected, .{ .allocator = failing.allocator() }, &atoms));
            try std.testing.expectEqual(failure, failing.alloc_index);
            try std.testing.expect(failing.has_induced_failure);
            try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        }
    }
}

test "app preparation final validation rejects state and debug staleness" {
    var memory: memory_mod.Memory = undefined;
    memory.init(std.testing.allocator);
    defer memory.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&memory);
    var tables: Table.Registry = undefined;
    try tables.init(&memory, 64);
    defer tables.deinit();
    const mem = try memory.beginInitAdmission();
    const tab = try tables.beginInitAdmission();
    var plan = try prepareAppInit(&memory, &atoms, &tables);
    try plan.validate();
    const debug = plan.debug_default.destination;
    const row = debug.insert(.{ .visualizer = plan.debug_default.visualizer });
    try std.testing.expectError(error.StaleDebugDefault, plan.validate());
    debug.free(row);
    // A fresh plan captures the restored rows and their new generations.
    var retry = try prepareAppInit(&memory, &atoms, &tables);
    try retry.validate();
    retry.state_table.touch();
    try std.testing.expectError(error.StaleAppInit, retry.validate());
    try std.testing.expect(tables.abortInitAdmission(tab));
    try std.testing.expect(memory.abortInitAdmission(mem));
}

/// Draws the debug figure `doc` in its working pose from the drawing the host published for the
/// app's watch of it (`watchDebugFigure`), under the context's transform. Writes no table.
fn renderDebugFigure(tables: *Table.Registry, doc: Atom, ctx: *roop.Context) !void {
    const subscriber = Atom.from(system_name);
    const published = figure.published(tables, subscriber, debug_figure_key) orelse return;
    if (published.definition != doc) return;
    try published.failure.check();
    try published.drawing_failure.check();
    const drawing = published.drawing orelse return;
    _ = try figure.draw(drawing, figure_reserve, ctx);
}
