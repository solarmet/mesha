const std = @import("std");
const mesha = @import("mesha");
const mesha_runtime = @import("mesha_runtime");
const plugin = mesha.plugin;
const input_mod = mesha.input;
const os_mod = mesha.os;
const time_mod = mesha.time;
const panels_mod = mesha.panels;
const resources_mod = mesha.resources;
const value_mod = mesha.value;
const table_document_mod = mesha.table_document;
const Atom = mesha.Atom;
const memory_mod = mesha.memory;
const Table = mesha.Table;
const zon_mod = mesha.zon;
const math = mesha.math;

const app = @import("stage.zig");
const state_mod = @import("stage_state.zig");
const hits_mod = @import("hits.zig");
const editor_sequencer = @import("editor_sequencer.zig");
const fixed_panels = @import("fixed_panels.zig");

const kScreenW: f32 = app.kScreenW;
const kScreenH: f32 = app.kScreenH;

fn setDebugVisualizerEnabled(tables: *Table.Registry, atoms: *Atom.Registry, name: []const u8, enabled: bool) void {
    const debugviz = state_mod.table(tables, atoms, state_mod.debugviz_name);
    const enabled_index = debugviz.getSchema().fieldIndex("enabled").?;
    const enabled_bit = debugviz.getSchema().fields[enabled_index].bit;
    const id = atoms.intern(name);
    var q = debugviz.query(struct { visualizer: *Atom });
    while (q.next()) |item| {
        if (item.view.visualizer.* != id) continue;
        debugviz.setPresent(item.handle.row, enabled_bit, enabled);
        return;
    }
    unreachable;
}

const ScreenDebugCapture = struct {
    rect_count: usize = 0,
    circle_count: usize = 0,
    stroke_count: usize = 0,
    last_rect: struct { x: f32, y: f32, width: f32, height: f32 } = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    last_circle: struct { x: f32, y: f32, radius: f32 } = .{ .x = 0, .y = 0, .radius = 0 },

    pub fn beginPath(self: *ScreenDebugCapture) void {
        _ = self;
    }

    pub fn rect(self: *ScreenDebugCapture, x: f32, y: f32, width: f32, height: f32) void {
        self.rect_count += 1;
        self.last_rect = .{ .x = x, .y = y, .width = width, .height = height };
    }

    pub fn arc(self: *ScreenDebugCapture, x: f32, y: f32, radius: f32, a0: f32, a1: f32, winding: anytype) void {
        _ = a0;
        _ = a1;
        _ = winding;
        self.circle_count += 1;
        self.last_circle = .{ .x = x, .y = y, .radius = radius };
    }

    pub fn strokeColor(self: *ScreenDebugCapture, color: anytype) void {
        _ = self;
        _ = color;
    }

    pub fn strokeGlow(_: *@This(), _: mesha.roop.Color, _: f32) void {}

    pub fn strokeWidth(self: *ScreenDebugCapture, width: f32) void {
        _ = self;
        _ = width;
    }

    pub fn stroke(self: *ScreenDebugCapture) void {
        self.stroke_count += 1;
    }
};

/// The window's size as the os system keeps it in `os_window`, then the app stage's run.
fn resizeWindow(memory: *memory_mod.Memory, atoms: *Atom.Registry, tables: *Table.Registry, width: u32, height: u32) !void {
    const sequencer = mesha.sequencer;
    const scratch = try memory.tableScratchAllocator();
    var schema: Table.Schema = undefined;
    try schema.init(scratch.allocator, atoms, 2);
    defer schema.deinit();
    try schema.addFieldFallible("width", u32, .int);
    try schema.addFieldFallible("height", u32, .int);
    const window_name = Atom.from(os_mod.window_table_name);
    try atoms.tryInternAll(&.{os_mod.window_table_name});
    const ensured = try tables.ensureSingleton(&schema, window_name, .{ .width = width, .height = height }, .durable);
    const window = tables.get(ensured.handle).?;
    const row: Table.RowHandle = .{ .row = 0, .generation = window.rowGeneration(0) };
    const view = window.getRow(row, os_mod.WindowView).?;
    view.width.* = width;
    view.height.* = height;
    const steps = [_]sequencer.Step{.{ .system = app.system() }};
    const alone: sequencer.Sequencer = .{ .name = "app_stage_test", .steps = &steps };
    try sequencer.ensure(scratch, atoms, tables);
    try sequencer.ensureInboxes(scratch, atoms, tables, &alone);
    editor_sequencer.run(memory, atoms, tables, &alone, null);
}

test "init is idempotent and resize state survives rebind" {
    const allocator = std.testing.allocator;
    var atoms: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(allocator);
    defer mem.deinit();
    try atoms.init(&mem);
    defer atoms.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&mem, 32);
    defer tables.deinit();
    try app.initForTests(&mem, &atoms, &tables);
    const debugviz = state_mod.table(&tables, &atoms, state_mod.debugviz_name);
    try std.testing.expectEqual(@as(u32, 1), debugviz.count());
    try std.testing.expectEqual(@as(usize, 2), debugviz.getSchema().fields.len);
    try std.testing.expectEqualStrings("visualizer", debugviz.getSchema().fields[0].name);
    try std.testing.expectEqual(Table.FieldType.atom, debugviz.getSchema().fields[0].field_type.?);
    try std.testing.expectEqualStrings("enabled", debugviz.getSchema().fields[1].name);
    try std.testing.expectEqual(Table.FieldType.tag, debugviz.getSchema().fields[1].field_type.?);
    const initial_state = state_mod.app(&tables, &atoms);
    try std.testing.expect(!state_mod.debugVisualizerEnabled(&tables, &atoms, "hit_regions"));
    setDebugVisualizerEnabled(&tables, &atoms, "hit_regions", true);
    try std.testing.expect(state_mod.debugVisualizerEnabled(&tables, &atoms, "hit_regions"));

    initial_state.stage_focused.* = 0;
    const before = tables.findHandleByName(atoms.intern(state_mod.app_state_name)).?;
    const app_table = tables.get(before).?;
    const app_row = Table.RowHandle{ .row = 0, .generation = app_table.rowGeneration(0) };
    app_table.free(app_row);
    try std.testing.expect(app_table.valid(app_row));
    try app.initForTests(&mem, &atoms, &tables);
    const after = tables.findHandleByName(atoms.intern(state_mod.app_state_name)).?;
    try std.testing.expectEqual(before, after);
    const state = state_mod.app(&tables, &atoms);
    try std.testing.expectEqual(kScreenW, state.screen_w.*);
    try std.testing.expectEqual(kScreenH, state.screen_h.*);
    try std.testing.expectEqual(@as(u8, 0), state.stage_focused.*);
    try std.testing.expect(state_mod.debugVisualizerEnabled(&tables, &atoms, "hit_regions"));
    try std.testing.expectEqual(@as(u32, 1), state_mod.table(&tables, &atoms, state_mod.debugviz_name).count());
}

test "debug visualizer table schema and per-frame lifecycle" {
    const allocator = std.testing.allocator;
    var mem: memory_mod.Memory = undefined;
    mem.init(allocator);
    defer mem.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&mem);
    defer atoms.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&mem, 32);
    defer tables.deinit();
    try app.initForTests(&mem, &atoms, &tables);

    const draws = state_mod.debugVisualizerDraws(&tables, &atoms);
    try std.testing.expectEqual(@as(u32, 0), draws.count());
    const fields = draws.getSchema().fields;
    try std.testing.expectEqual(@as(usize, 7), fields.len);
    for ([_][]const u8{ "id", "kind", "x", "y", "radius", "length", "width" }, fields) |name, field| {
        try std.testing.expectEqualStrings(name, field.name);
    }
    try std.testing.expectEqual(Table.FieldType.atom, fields[0].field_type.?);
    try std.testing.expectEqual(Table.FieldType.atom, fields[1].field_type.?);
    inline for (2..7) |index| try std.testing.expectEqual(Table.FieldType.f32, fields[index].field_type.?);

    _ = state_mod.addDebugVisualizer(&tables, &atoms, .{ .id = atoms.intern("test"), .kind = atoms.intern("not_a_shape") });
    try std.testing.expectEqual(@as(u32, 1), draws.count());
    app.beginFrame(&tables, &atoms);
    try std.testing.expectEqual(@as(u32, 0), draws.count());
}

test "hit-region visualizer submits screen-space rect rows" {
    const allocator = std.testing.allocator;
    var mem: memory_mod.Memory = undefined;
    mem.init(allocator);
    defer mem.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&mem);
    defer atoms.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&mem, 32);
    defer tables.deinit();
    try app.initForTests(&mem, &atoms, &tables);

    const hit = app.hitRegions(&tables, &atoms);
    _ = hits_mod.insertClick(hit, .{ .x = 101, .y = 202 }, .{ .x = 303, .y = 404 }, mesha.input.no_tag);
    setDebugVisualizerEnabled(&tables, &atoms, "hit_regions", true);
    try std.testing.expect(state_mod.debugVisualizerEnabled(&tables, &atoms, "hit_regions"));
    app.addHitRegionVisualizers(&tables, &atoms, hit);

    const draws = state_mod.debugVisualizerDraws(&tables, &atoms);
    var q = draws.query(struct { id: *Atom, kind: *Atom, x: *f32, y: *f32, length: *f32, width: *f32 });
    const item = q.next().?.view;
    try std.testing.expectEqual(atoms.intern("hit_regions"), item.id.*);
    try std.testing.expectEqual(atoms.intern("rect"), item.kind.*);
    try std.testing.expectEqual(@as(f32, 101), item.x.*);
    try std.testing.expectEqual(@as(f32, 202), item.y.*);
    try std.testing.expectEqual(@as(f32, 303), item.length.*);
    try std.testing.expectEqual(@as(f32, 404), item.width.*);
    try std.testing.expect(q.next() == null);
}

test "screen debug visualizers render rectangles and circles and ignore unknown kinds" {
    const allocator = std.testing.allocator;
    var mem: memory_mod.Memory = undefined;
    mem.init(allocator);
    defer mem.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&mem);
    defer atoms.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&mem, 32);
    defer tables.deinit();
    try app.initForTests(&mem, &atoms, &tables);

    _ = state_mod.addDebugVisualizer(&tables, &atoms, .{ .id = atoms.intern("hit"), .kind = atoms.intern("rect"), .x = 110, .y = 220, .length = 30, .width = 40 });
    _ = state_mod.addDebugVisualizer(&tables, &atoms, .{ .id = atoms.intern("cursor"), .kind = atoms.intern("circle"), .x = 150, .y = 270, .radius = 12 });
    _ = state_mod.addDebugVisualizer(&tables, &atoms, .{ .id = atoms.intern("unknown"), .kind = atoms.intern("capsule"), .x = 99, .y = 99, .radius = 9 });

    var capture = ScreenDebugCapture{};
    app.renderScreenDebugVisualizers(&tables, &atoms, .{ .x = 100, .y = 200, .width = 800, .height = 600 }, &capture);
    try std.testing.expectEqual(@as(usize, 1), capture.rect_count);
    try std.testing.expectEqual(@as(usize, 1), capture.circle_count);
    try std.testing.expectEqual(@as(usize, 2), capture.stroke_count);
    try std.testing.expectEqual(@as(f32, 10), capture.last_rect.x);
    try std.testing.expectEqual(@as(f32, 20), capture.last_rect.y);
    try std.testing.expectEqual(@as(f32, 30), capture.last_rect.width);
    try std.testing.expectEqual(@as(f32, 40), capture.last_rect.height);
    try std.testing.expectEqual(@as(f32, 50), capture.last_circle.x);
    try std.testing.expectEqual(@as(f32, 70), capture.last_circle.y);
    try std.testing.expectEqual(@as(f32, 12), capture.last_circle.radius);
}

test "hit regions grow past their initial capacity and keep it across a frame" {
    const allocator = std.testing.allocator;
    var atoms: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(allocator);
    defer mem.deinit();
    try atoms.init(&mem);
    defer atoms.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&mem, 32);
    defer tables.deinit();
    try app.initForTests(&mem, &atoms, &tables);
    const hits = app.hitRegions(&tables, &atoms);
    const initial_capacity = hits.rowCapacity();
    const region_count = initial_capacity + 1;
    for (0..region_count) |_| {
        _ = hits_mod.insertClick(hits, math.Vec2f{ .x = 1, .y = 2 }, math.Vec2f{ .x = 3, .y = 4 }, mesha.input.no_tag);
    }
    try std.testing.expectEqual(region_count, hits.count());
    const grown_capacity = hits.rowCapacity();
    try std.testing.expect(grown_capacity > initial_capacity);
    // The host clears them: a panel that keeps last frame's drawing keeps its regions.
    app.beginFrame(&tables, &atoms);
    try std.testing.expectEqual(region_count, hits.count());
    try std.testing.expectEqual(grown_capacity, hits.rowCapacity());
}

test "beginFrame keeps hit regions for the host; render dispatches world/ui by atom" {
    const allocator = std.testing.allocator;
    var atoms: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(allocator);
    defer mem.deinit();
    try atoms.init(&mem);
    defer atoms.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&mem, 32);
    defer tables.deinit();
    try app.initForTests(&mem, &atoms, &tables);
    const hits = app.hitRegions(&tables, &atoms);
    try std.testing.expect(hits.rowCapacity() >= app.initial_hit_region_rows);
    _ = hits_mod.insertClick(hits, math.Vec2f{ .x = 1, .y = 2 }, math.Vec2f{ .x = 3, .y = 4 }, mesha.input.no_tag);
    try std.testing.expectEqual(@as(u32, 1), hits.count());
    // The host clears them: a panel that keeps last frame's drawing keeps its regions.
    app.beginFrame(&tables, &atoms);
    try std.testing.expectEqual(@as(u32, 1), hits.count());

    try std.testing.expectEqual(Atom.from("world"), app.world_id);
    try std.testing.expectEqual(Atom.from("ui"), app.ui_id);
}

/// A game's panel, another plugin's, which shows the world.
const game_panel: mesha.plugin.panels.Open = .{ .id = Atom.from("stage"), .title = "Game", .root = Atom.from("game"), .owner = .game };

/// Makes `world_view` and has it name the game's panel, as the game's plugin does.
fn showWorldInGamePanel(memory: *memory_mod.Memory, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    try mesha.world.ensure(try memory.tableScratchAllocator(), atoms, tables);
    const table = tables.findByName(Atom.from(mesha.world.view_table_name)).?;
    const row: Table.RowHandle = .{ .row = 0, .generation = table.rowGeneration(0) };
    table.getRow(row, mesha.world.View).?.panel.* = game_panel.id;
}

test "the app follows the focus of the panel that shows the world, beside the figure stage or not" {
    const allocator = std.testing.allocator;
    var atoms: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(allocator);
    defer mem.deinit();
    try atoms.init(&mem);
    defer atoms.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&mem, 32);
    defer tables.deinit();
    try app.initForTests(&mem, &atoms, &tables);
    const scratch = try mem.tableScratchAllocator();
    try panels_mod.ensure(scratch, &atoms, &tables);
    try showWorldInGamePanel(&mem, &atoms, &tables);

    const sequencer = mesha.sequencer;
    const steps = [_]sequencer.Step{.{ .system = app.system() }};
    const alone: sequencer.Sequencer = .{ .name = "app_stage_test", .steps = &steps };
    try sequencer.ensure(scratch, &atoms, &tables);
    try sequencer.ensureInboxes(scratch, &atoms, &tables, &alone);
    const state = state_mod.app(&tables, &atoms);
    const cases = [_]struct {
        layout: fixed_panels.FixtureLayout,
        focused: []const u8,
        expected_focus: u8,
    }{
        .{ .layout = .empty, .focused = "stage", .expected_focus = 1 },
        // A panel not open takes no focus: none has it.
        .{ .layout = .empty, .focused = "figure_outliner", .expected_focus = 0 },
        .{ .layout = .empty, .focused = "stage", .expected_focus = 1 },
        .{ .layout = .figure_stage, .focused = "figure_stage", .expected_focus = 0 },
        // The game's panel may be open beside the figure editor, and is focused there too.
        .{ .layout = .figure_stage, .focused = "stage", .expected_focus = 1 },
    };
    for (cases) |case| {
        fixed_panels.layOutNow(&tables, &atoms, case.layout);
        panels_mod.openNow(&tables, &atoms, game_panel);
        const panels_state = panels_mod.state(&tables, &atoms);
        panels_state.focus_clicks_enabled.* = 1;
        panels_state.focused.* = atoms.intern(case.focused);
        editor_sequencer.run(&mem, &atoms, &tables, &alone, null);
        try std.testing.expectEqual(case.expected_focus, state.stage_focused.*);
    }
}

test "app subscriptions require a focused Stage" {
    const allocator = std.testing.allocator;
    var atoms: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(allocator);
    defer mem.deinit();
    try atoms.init(&mem);
    defer atoms.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&mem, 32);
    defer tables.deinit();
    try app.initForTests(&mem, &atoms, &tables);
    const scratch = try mem.tableScratchAllocator();
    try panels_mod.ensure(scratch, &atoms, &tables);
    const state = state_mod.app(&tables, &atoms);

    const input_state = try mesha_runtime.input.Input.init(&mem, &tables, &atoms);
    defer input_state.deinit();
    try time_mod.ensureTables(scratch, &atoms, &tables);
    const actions_name = plugin.action_api.subscribed_table_name;
    try plugin.Actions.ensure(scratch, &atoms, &tables, actions_name);
    var rows: plugin.ActionRows = .{ .actions = plugin.Actions.of(&mem, &tables, actions_name) };

    const cases = [_]struct {
        layout: fixed_panels.FixtureLayout,
        focused: u8,
    }{
        .{ .layout = .empty, .focused = 0 },
        .{ .layout = .empty, .focused = 1 },
        .{ .layout = .figure_stage, .focused = 1 },
        .{ .layout = .empty, .focused = 1 },
    };
    for (cases) |case| {
        fixed_panels.layOutNow(&tables, &atoms, case.layout);
        state.stage_focused.* = case.focused;
        rows.actions.reset();
        app.declareActions(&atoms, rows.sink());
        // The game's keys and clock belong to the game's plugin; the app lists its actions only.
        try std.testing.expectEqual(@as(u32, app.app_actions.len), rows.actions.count());
    }
}

test "with no world shown the app takes no stale time messages and draws nothing, while following a resize" {
    const allocator = std.testing.allocator;
    var memory: memory_mod.Memory = undefined;
    memory.init(allocator);
    defer memory.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&memory);
    defer atoms.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&memory, 32);
    defer tables.deinit();
    try app.initForTests(&memory, &atoms, &tables);
    const scratch = try memory.tableScratchAllocator();
    try panels_mod.ensure(scratch, &atoms, &tables);

    const state = state_mod.app(&tables, &atoms);
    fixed_panels.layOutNow(&tables, &atoms, .figure_stage);

    // A frame and a tick reach the app while no world is shown: it takes neither.
    app.apply(&tables, .from("frame"));
    app.apply(&tables, .from("tick"));
    // The window resized meanwhile: the app still follows it.
    try resizeWindow(&memory, &atoms, &tables, 1280, 720);
    try std.testing.expectEqual(@as(f32, 1280), state.screen_w.*);
    try std.testing.expectEqual(@as(f32, 720), state.screen_h.*);

    const hits = app.hitRegions(&tables, &atoms);
    const viewport = plugin.Viewport{ .x = 10, .y = 20, .width = 640, .height = 480 };
    // Inactive dispatch must not access a GPU context, including the UI path.
    var context: mesha.roop.Context = undefined;
    app.render(&tables, &atoms, viewport, &context);
    try std.testing.expectEqual(@as(u32, 0), hits.count());

    fixed_panels.layOutNow(&tables, &atoms, .empty);
    app.apply(&tables, .from("frame"));
    app.apply(&tables, .from("tick"));
}

test "quit requests window close" {
    const allocator = std.testing.allocator;
    var atoms: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(allocator);
    defer mem.deinit();
    try atoms.init(&mem);
    defer atoms.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&mem, 32);
    defer tables.deinit();
    try app.initForTests(&mem, &atoms, &tables);

    try os_mod.Requests.ensure(try mem.tableScratchAllocator(), &atoms, &tables, os_mod.commands_table_name);
    // As the app stage takes the invoked `quit` action.
    app.apply(&tables, atoms.intern("quit"));
    const Asked = struct {
        payloads: u32 = 0,
        closes: bool = false,
        fn keep(asked: *@This(), row: *os_mod.CmdPayload) mesha.sequencer.Applied {
            asked.payloads += 1;
            asked.closes = row.* == .request_close;
            return .done;
        }
    };
    var asked: Asked = .{};
    os_mod.Requests.of(&mem, &tables, os_mod.commands_table_name).drain(&asked, Asked.keep);
    try std.testing.expectEqual(@as(u32, 1), asked.payloads);
    try std.testing.expect(asked.closes);
}
