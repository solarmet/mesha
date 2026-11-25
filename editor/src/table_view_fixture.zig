//! The schema of the table the table view functional suite loads
//! (`tools/table_view_functional_test.py`). A table file holds no schema, so a file loads only
//! where code registers the one it was saved with: the suite builds its fixture file with
//! these fields, in this order, and the editor registers them under the fixture's id.
const std = @import("std");
const mesha = @import("mesha");
const Atom = mesha.Atom;
const memory_mod = mesha.memory;
const Table = mesha.Table;

pub const table_id = "editor_table_view_functional";

/// The fields after the seven typed ones: plain numbers, enough to scroll the grid sideways.
const filler_first = 7;
const filler_last = 19;
const field_count = filler_last + 1;

pub fn registerSchema(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    var schema: Table.Schema = undefined;
    try schema.init(scratch.allocator, atoms, field_count);
    defer schema.deinit();
    try schema.addFieldFallible("value", i32, .int);
    try schema.addFieldFallible("title", Table.String, .text_field);
    try schema.addFieldFallible("enabled", void, .checkbox);
    try schema.addFieldFallible("ratio", f32, .{ .float_slider = .{ .min = 0, .max = 100 } });
    try schema.addFieldFallible("position", mesha.math.Vec3f, .{ .vector = .{ .components = 3 } });
    try schema.addFieldFallible("color", [4]u8, .color);
    try schema.addFieldFallible("kind", Atom, .atom);
    var filler: u32 = filler_first;
    while (filler <= filler_last) : (filler += 1) {
        var name_buffer: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buffer, "field_{d:0>2}", .{filler}) catch unreachable;
        try schema.addFieldFallible(name, i32, .int);
    }
    try tables.registerSchema(atoms.intern(table_id), &schema);
}
