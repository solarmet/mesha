const std = @import("std");
const mesha = @import("mesha");
const Atom = mesha.Atom;
const memory_mod = mesha.memory;
const Table = mesha.Table;
const math = mesha.math;

pub const app_state_name = "app_state";

pub const debugviz_name = "app_debugviz";
pub const debug_visualizer_draws_name = "app_debug_visualizer_draws";
pub const hit_regions_name = "app_hit_regions";

pub const AppState = struct {
    /// Whether the panel that shows the world has the focus.
    stage_focused: *u8,
    screen_w: *f32,
    screen_h: *f32,
    debug_figure_doc: *Atom,
    /// The element whose hover the panels last drew: `input.hover` moving off it asks them to
    /// draw again.
    drawn_hover: *[16]u8,
};

pub const DebugVisualizerEntry = struct {
    id: Atom,
    kind: Atom,
    x: f32 = 0,
    y: f32 = 0,
    radius: f32 = 0,
    length: f32 = 0,
    width: f32 = 0,
};

fn finishSchema(schema: *Table.Schema, tables: *Table.Registry, capacity: u32, name: Atom) !Table.Registry.EnsureResult {
    defer schema.deinit();
    return tables.ensure(schema, capacity, name, .durable);
}

pub fn ensureAppState(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry, screen_w: f32, screen_h: f32) !void {
    return ensureAppStateInternal(false, scratch, atoms, tables, screen_w, screen_h);
}

pub fn prepareAppState(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry, screen_w: f32, screen_h: f32) !void {
    return ensureAppStateInternal(true, scratch, atoms, tables, screen_w, screen_h);
}

fn ensureAppStateInternal(comptime fallible: bool, scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry, screen_w: f32, screen_h: f32) !void {
    const allocator = scratch.allocator;

    var schema = try buildAppStateSchema(fallible, allocator, atoms);
    defer schema.deinit();
    _ = try tables.ensureSingleton(&schema, atoms.intern(app_state_name), .{
        .stage_focused = @as(u8, 1),
        .screen_w = screen_w,
        .screen_h = screen_h,
        .debug_figure_doc = @as(Atom, @enumFromInt(0)),
        .drawn_hover = std.mem.zeroes([16]u8),
    }, .durable);
}

pub const PreparedDebugDefault = struct {
    destination: *Table,
    visualizer: Atom,
    insert: bool,
    store: *Table.Registry,
    handle: Table.Handle,
    schema: *Table.SchemaRegistry.Record,
    revision: u64,
    free_count: usize,
    next_row: ?u32,
    next_generation: u32,

    pub fn validate(self: PreparedDebugDefault) !void {
        const tab = self.store.get(self.handle) orelse return error.StaleDebugDefault;
        if (tab != self.destination or tab.schema_ref != self.schema or tab.revision != self.revision or tab.reusableRows().len != self.free_count) return error.StaleDebugDefault;
        const next = if (tab.reusableRows().len == 0) null else tab.reusableRows().at(tab.reusableRows().len - 1);
        if (next != self.next_row) return error.StaleDebugDefault;
        if (next) |row| if (tab.rowGeneration(row) != self.next_generation or tab.isAllocated(row)) return error.StaleDebugDefault;
        var found = false;
        var query = tab.query(struct { visualizer: *Atom });
        while (query.next()) |item| {
            if (item.view.visualizer.* == self.visualizer) found = true;
        }
        if (found == self.insert) return error.StaleDebugDefault;
    }

    pub fn apply(self: PreparedDebugDefault) void {
        if (self.insert) _ = self.destination.insert(.{ .visualizer = self.visualizer });
    }
};

pub fn prepareDebugVisualizers(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !PreparedDebugDefault {
    return debugVisualizersInternal(true, scratch, atoms, tables);
}

fn debugVisualizersInternal(comptime fallible: bool, scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !PreparedDebugDefault {
    var schema = try buildDebugVisualizersSchema(fallible, scratch.allocator, atoms);
    defer schema.deinit();
    const debugviz = (try tables.ensure(&schema, 16, atoms.intern(debugviz_name), .durable)).table;
    const id = atoms.intern("hit_regions");
    var q = debugviz.query(struct { visualizer: *Atom });
    var found = false;
    while (q.next()) |item| {
        if (item.view.visualizer.* == id) found = true;
    }
    if (!found and debugviz.count() == debugviz.rowCapacity()) return error.TableFull;
    const next = if (debugviz.reusableRows().len == 0) null else debugviz.reusableRows().at(debugviz.reusableRows().len - 1);
    return .{
        .destination = debugviz,
        .visualizer = id,
        .insert = !found,
        .store = tables,
        .handle = tables.findHandleByName(Atom.from(debugviz_name)).?,
        .schema = debugviz.schema_ref,
        .revision = debugviz.revision,
        .free_count = debugviz.reusableRows().len,
        .next_row = next,
        .next_generation = if (next) |row| debugviz.rowGeneration(row) else 0,
    };
}

pub fn ensureDebugVisualizers(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    const prepared = try debugVisualizersInternal(false, scratch, atoms, tables);
    prepared.apply();
}

pub fn ensureDebugVisualizerDraws(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    return ensureDebugVisualizerDrawsInternal(false, scratch, atoms, tables);
}

pub fn prepareDebugVisualizerDraws(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    return ensureDebugVisualizerDrawsInternal(true, scratch, atoms, tables);
}

fn ensureDebugVisualizerDrawsInternal(comptime fallible: bool, scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    var schema = try buildDebugVisualizerDrawsSchema(fallible, scratch.allocator, atoms);
    defer schema.deinit();

    _ = try tables.ensure(&schema, 65536, atoms.intern(debug_visualizer_draws_name), .durable);
}

pub fn debugVisualizerDraws(tables: *Table.Registry, atoms: *Atom.Registry) *Table {
    return table(tables, atoms, debug_visualizer_draws_name);
}

pub fn addDebugVisualizer(tables: *Table.Registry, atoms: *Atom.Registry, entry: DebugVisualizerEntry) Table.RowHandle {
    return debugVisualizerDraws(tables, atoms).insert(entry);
}

pub fn debugVisualizerEnabled(tables: *Table.Registry, atoms: *Atom.Registry, name: []const u8) bool {
    const debugviz = table(tables, atoms, debugviz_name);
    const enabled_index = debugviz.getSchema().fieldIndex("enabled") orelse return false;
    const enabled_bit = debugviz.getSchema().fields[enabled_index].bit;
    const id = atoms.intern(name);
    var q = debugviz.query(struct { visualizer: *Atom });
    while (q.next()) |item| {
        if (item.view.visualizer.* == id) return debugviz.rowHas(item.handle.row, enabled_bit);
    }
    return false;
}

pub fn table(tables: *Table.Registry, atoms: *Atom.Registry, name: []const u8) *Table {
    return tables.findByName(atoms.intern(name)) orelse @panic("required app table missing");
}

pub fn app(tables: *Table.Registry, atoms: *Atom.Registry) AppState {
    const t = table(tables, atoms, app_state_name);
    const handle = Table.RowHandle{ .row = 0, .generation = t.rowGeneration(0) };
    return t.getRow(handle, AppState) orelse @panic("app_state singleton row missing");
}

pub fn fixedString(buf: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return buf[0..end];
}

pub fn copyFixed(comptime N: usize, source: []const u8) ![N]u8 {
    if (source.len >= N) return error.StringTooLong;
    var result = std.mem.zeroes([N]u8);
    @memcpy(result[0..source.len], source);
    return result;
}

fn addInitField(comptime fallible: bool, schema: *Table.Schema, name: []const u8, comptime T: type, view: Table.ViewKind) !void {
    if (fallible) try schema.addFieldFallible(name, T, view) else schema.addField(name, T, view);
}

fn buildAppStateSchema(comptime fallible: bool, allocator: std.mem.Allocator, atoms: *Atom.Registry) !Table.Schema {
    var schema: Table.Schema = undefined;
    try schema.init(allocator, atoms, 33);
    errdefer schema.deinit();
    try addInitField(fallible, &schema, "stage_focused", u8, .int);
    try addInitField(fallible, &schema, "screen_w", f32, .int);
    try addInitField(fallible, &schema, "screen_h", f32, .int);
    try addInitField(fallible, &schema, "debug_figure_doc", Atom, .atom);
    try addInitField(fallible, &schema, "drawn_hover", [16]u8, .hex);
    return schema;
}

fn buildDebugVisualizersSchema(comptime fallible: bool, allocator: std.mem.Allocator, atoms: *Atom.Registry) !Table.Schema {
    var schema: Table.Schema = undefined;
    try schema.init(allocator, atoms, 2);
    errdefer schema.deinit();
    try addInitField(fallible, &schema, "visualizer", Atom, .atom);
    try addInitField(fallible, &schema, "enabled", void, .checkbox);
    return schema;
}

fn buildDebugVisualizerDrawsSchema(comptime fallible: bool, allocator: std.mem.Allocator, atoms: *Atom.Registry) !Table.Schema {
    var schema: Table.Schema = undefined;
    try schema.init(allocator, atoms, 7);
    errdefer schema.deinit();
    try addInitField(fallible, &schema, "id", Atom, .atom);
    try addInitField(fallible, &schema, "kind", Atom, .atom);
    try addInitField(fallible, &schema, "x", f32, .int);
    try addInitField(fallible, &schema, "y", f32, .int);
    try addInitField(fallible, &schema, "radius", f32, .int);
    try addInitField(fallible, &schema, "length", f32, .int);
    try addInitField(fallible, &schema, "width", f32, .int);
    return schema;
}

test "app preparation state schemas every native owned name allocation is fallible and runtime identical" {
    var memory: memory_mod.Memory = undefined;
    memory.init(std.testing.allocator);
    defer memory.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&memory);
    defer atoms.deinit();
    inline for (.{ buildAppStateSchema, buildDebugVisualizersSchema, buildDebugVisualizerDrawsSchema }) |build| {
        var runtime = try build(false, std.testing.allocator, &atoms);
        defer runtime.deinit();
        var count = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
        var prepared = try build(true, count.allocator(), &atoms);
        defer prepared.deinit();
        try std.testing.expectEqualDeep(runtime.fields, prepared.fields);
        for (1..count.alloc_index) |failure| {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = failure, .resize_fail_index = 0 });
            try std.testing.expectError(error.OutOfMemory, build(true, failing.allocator(), &atoms));
            try std.testing.expectEqual(failure, failing.alloc_index);
            try std.testing.expect(failing.has_induced_failure);
            try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        }
    }
}
