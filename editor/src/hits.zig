const std = @import("std");
const mesha = @import("mesha");
const ui = mesha.ui;
const Atom = mesha.Atom;
const memory_mod = mesha.memory;
const Table = mesha.Table;
const math = mesha.math;

/// Adds a region whose click arrives under `on_click`, for a test of what reads regions.
pub fn insertClick(hits: *Table, pos: math.Vec2f, size: math.Vec2f, on_click: Atom) Table.RowHandle {
    return hits.insert(.{
        .pos = pos,
        .size = size,
        .on_click = on_click,
        .id = std.mem.zeroes([16]u8),
    });
}

const testing = std.testing;

test "insertClick adds a region with its click's tag" {
    var atoms: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try atoms.init(&mem);
    defer atoms.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&mem, 4);
    defer tables.deinit();
    var schema: Table.Schema = undefined;
    try ui.initHitRegionSchema(&schema, .{ .allocator = testing.allocator }, &atoms);
    defer schema.deinit();
    _ = try tables.ensure(&schema, 8, atoms.intern("hits_test"), .durable);
    const hits = tables.findByName(atoms.intern("hits_test")).?;
    const handle = insertClick(hits, .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 }, @enumFromInt(123));
    try testing.expectEqual(@as(u32, 1), hits.count());
    try testing.expectEqual(@as(Atom, @enumFromInt(123)), hits.getField(Atom, handle, "on_click").?.*);
}
