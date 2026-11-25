//! A grid's cells as text: how a cell of each view kind is shown, how typed text is read back
//! into one, and the small edits a grid makes to a cell (commit, clear, flip). `grid` builds on
//! these; they take the table and a row and field, and keep nothing between calls.
//!
//! Reads go through `Table.cellBytes` and `Table.cellText`, so a run that has the table attached
//! sees its journal's copy; writes go through `Table.writableCellBytes`, `Table.setCellText` and
//! `Table.setPresent`, which a fault takes back. None touches raw storage
//! (`rowCellBytes`, `rowAtPosition`), so a journaled kernel may call any of them.
const std = @import("std");
const Atom = @import("../../core/atom.zig").Atom;
const memory_mod = @import("../../core/memory.zig");
const Table = @import("../../core/table.zig");
const Log = @import("../../core/log.zig").scope("ui");

const FieldDescriptor = Table.FieldDescriptor;

/// The longest text one cell is shown as, in bytes: what a caller's buffer for `formatValueBuf`,
/// `cellText` and `seedEditText` holds.
pub const cell_text_buffer_size: usize = 1024;

fn utf8Prefix(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch break;
        if (i + len > s.len or !std.unicode.utf8ValidateSlice(s[i .. i + len])) break;
        i += len;
    }
    return s[0..i];
}

/// Whether the field's cells are values of `T`, by the type its schema was given.
fn holds(desc: *const FieldDescriptor, comptime T: type) bool {
    return desc.size == @sizeOf(T) and desc.semantic_type == comptime std.hash.Wyhash.hash(0, @typeName(T));
}

fn formatValueBuf(buf: []u8, desc: *const FieldDescriptor, ptr: *const anyopaque, atoms: *const Atom.Registry) []const u8 {
    switch (desc.view_kind) {
        .float_slider => {
            const value: *const f32 = @ptrCast(@alignCast(ptr));
            return std.fmt.bufPrint(buf, "{d}", .{value.*}) catch buf[0..0];
        },
        .checkbox => return std.fmt.bufPrint(buf, "true", .{}) catch buf[0..0],
        .toggle => {
            const value: *const u8 = @ptrCast(ptr);
            return std.fmt.bufPrint(buf, "{s}", .{if (value.* != 0) "true" else "false"}) catch buf[0..0];
        },
        .text_field => {
            const bytes: [*]const u8 = @ptrCast(ptr);
            const raw = bytes[0..desc.size];
            const end = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
            return std.fmt.bufPrint(buf, "{s}", .{utf8Prefix(raw[0..end])}) catch buf[0..0];
        },
        .vector => |cfg| {
            const floats: [*]const f32 = @ptrCast(@alignCast(ptr));
            var len: usize = 0;
            if (len < buf.len) {
                buf[len] = '(';
                len += 1;
            }
            for (0..cfg.components) |i| {
                if (i != 0 and len + 2 <= buf.len) {
                    @memcpy(buf[len..][0..2], ", ");
                    len += 2;
                }
                const written = std.fmt.bufPrint(buf[len..], "{d}", .{floats[i]}) catch return buf[0..len];
                len += written.len;
            }
            if (len < buf.len) {
                buf[len] = ')';
                len += 1;
            }
            return buf[0..len];
        },
        .matrix => |cfg| {
            const floats: [*]const f32 = @ptrCast(@alignCast(ptr));
            var len: usize = 0;
            for (0..cfg.rows) |r| {
                if (r != 0 and len + 3 <= buf.len) {
                    @memcpy(buf[len..][0..3], " | ");
                    len += 3;
                }
                for (0..cfg.cols) |c| {
                    if (c != 0 and len < buf.len) {
                        buf[len] = ' ';
                        len += 1;
                    }
                    const written = std.fmt.bufPrint(buf[len..], "{d}", .{floats[r * cfg.cols + c]}) catch return buf[0..len];
                    len += written.len;
                }
            }
            return buf[0..len];
        },
        .color => {
            const bytes: [*]const u8 = @ptrCast(ptr);
            return std.fmt.bufPrint(buf, "{d}, {d}, {d}, {d}", .{ bytes[0], bytes[1], bytes[2], bytes[3] }) catch buf[0..0];
        },
        .ref => {
            const ref = std.mem.bytesToValue(Table.Ref, @as([*]const u8, @ptrCast(ptr))[0..@sizeOf(Table.Ref)]);
            return Table.formatRef(ref, atoms, buf);
        },
        .atom => {
            const id: *const Atom = @ptrCast(@alignCast(ptr));
            if (@intFromEnum(id.*) == 0) return std.fmt.bufPrint(buf, "<none>", .{}) catch buf[0..0];
            return std.fmt.bufPrint(buf, "{s}", .{atoms.lookup(id.*) orelse "<unknown atom>"}) catch buf[0..0];
        },
        .int => {
            // A plain number: schemas declare floats with this kind too, there being no other
            // for one without a slider's range. The field's type says how its bytes read.
            if (holds(desc, f32)) return std.fmt.bufPrint(buf, "{d}", .{@as(*const f32, @ptrCast(@alignCast(ptr))).*}) catch buf[0..0];
            if (holds(desc, f64)) return std.fmt.bufPrint(buf, "{d}", .{@as(*const f64, @ptrCast(@alignCast(ptr))).*}) catch buf[0..0];
            if (holds(desc, i32))
                return std.fmt.bufPrint(buf, "{d}", .{@as(*const i32, @ptrCast(@alignCast(ptr))).*}) catch buf[0..0];
            if (desc.size == 1) return std.fmt.bufPrint(buf, "{d}", .{@as(*const u8, @ptrCast(ptr)).*}) catch buf[0..0];
            if (desc.size == 2) return std.fmt.bufPrint(buf, "{d}", .{@as(*const u16, @ptrCast(@alignCast(ptr))).*}) catch buf[0..0];
            if (desc.size == 8) return std.fmt.bufPrint(buf, "{d}", .{@as(*const u64, @ptrCast(@alignCast(ptr))).*}) catch buf[0..0];
            return std.fmt.bufPrint(buf, "{d}", .{@as(*const u32, @ptrCast(@alignCast(ptr))).*}) catch buf[0..0];
        },
        .bytes => {
            const cell: *const Table.Bytes = @ptrCast(@alignCast(ptr));
            return std.fmt.bufPrint(buf, "{d} bytes", .{cell.payload.len}) catch buf[0..0];
        },
        .hex => {
            if (desc.size > 8) {
                if (desc.size * 2 + 2 > buf.len) return std.fmt.bufPrint(buf, "<{d} bytes; copy or inspect with MCP>", .{desc.size}) catch "";
                const bytes = @as([*]const u8, @ptrCast(ptr))[0..desc.size];
                @memcpy(buf[0..2], "0x");
                const digits = "0123456789abcdef";
                for (bytes, 0..) |byte, i| {
                    buf[2 + i * 2] = digits[byte >> 4];
                    buf[3 + i * 2] = digits[byte & 15];
                }
                return buf[0 .. desc.size * 2 + 2];
            }
            if (desc.size == 1) return std.fmt.bufPrint(buf, "0x{x}", .{@as(*const u8, @ptrCast(ptr)).*}) catch buf[0..0];
            if (desc.size == 2) return std.fmt.bufPrint(buf, "0x{x}", .{@as(*const u16, @ptrCast(@alignCast(ptr))).*}) catch buf[0..0];
            if (desc.size == 8) return std.fmt.bufPrint(buf, "0x{x}", .{@as(*const u64, @ptrCast(@alignCast(ptr))).*}) catch buf[0..0];
            return std.fmt.bufPrint(buf, "0x{x}", .{@as(*const u32, @ptrCast(@alignCast(ptr))).*}) catch buf[0..0];
        },
    }
}

/// The cell at `ptr`, of the field `desc`, as the grid shows it, in `scratch`'s memory; atom
/// and reference cells are named through `atoms`. An error only when `scratch` has no room.
pub fn formatValue(scratch: memory_mod.Scratch, desc: *const FieldDescriptor, ptr: *const anyopaque, atoms: *const Atom.Registry) ![]const u8 {
    var buf: [256]u8 = undefined;
    return scratch.allocator.dupe(u8, formatValueBuf(&buf, desc, ptr, atoms));
}

/// A cell's bytes as a run sees them, through its journal while a run has the table attached;
/// empty for a row the run cannot see. Valid until the table is next written.
pub fn cellValue(table: *const Table, row: u32, desc: *const FieldDescriptor) []const u8 {
    return table.cellBytes(row, desc);
}

/// A text cell's text, cut at its last whole UTF-8 character, in the table until the cell is
/// next written.
pub fn rawTextCell(table: *const Table, row: u32, desc: *const FieldDescriptor) []const u8 {
    const text = table.cellText(row, desc);
    return utf8Prefix(text);
}

/// The text an edit of the cell starts from: a text cell's own text, in its table, of any
/// length; another cell's value as text, in `buf`.
pub fn seedEditText(table: *const Table, row: u32, field: u32, buf: []u8, atoms: *const Atom.Registry) ![]const u8 {
    if (!table.isAllocated(row)) return error.InvalidRow;
    if (field >= table.getSchema().fields.len) return error.InvalidField;
    const desc = &table.getSchema().fields[field];
    const bit_set = table.rowHas(row, desc.bit);
    if (desc.view_kind == .checkbox) return std.fmt.bufPrint(buf, "{s}", .{if (bit_set) "true" else "false"}) catch error.ValueTooLong;
    if (!bit_set) return buf[0..0];
    if (desc.view_kind == .text_field) return rawTextCell(table, row, desc);
    var formatted: [cell_text_buffer_size]u8 = undefined;
    const cell = cellValue(table, row, desc);
    if (cell.len < desc.size) return buf[0..0];
    const text = formatValueBuf(&formatted, desc, cell.ptr, atoms);
    if (text.len > buf.len) return error.ValueTooLong;
    @memcpy(buf[0..text.len], text);
    return buf[0..text.len];
}

/// The cell's value as text, the text the grid filters, sorts and copies by: a checkbox's
/// `true` or `false`, an absent cell's empty text, a text cell's own text (in its table),
/// another cell's value formatted into `buf`. Empty for a row or field that is not there.
pub fn cellText(table: *const Table, row: u32, field: u32, buf: *[cell_text_buffer_size]u8, atoms: *const Atom.Registry) []const u8 {
    if (!table.isAllocated(row) or field >= table.getSchema().fields.len) return buf[0..0];
    const desc = &table.getSchema().fields[field];
    const bit_set = table.rowHas(row, desc.bit);
    if (desc.view_kind == .checkbox) return if (bit_set) "true" else "false";
    if (!bit_set) return "";
    if (desc.view_kind == .text_field) return rawTextCell(table, row, desc);
    const cell = cellValue(table, row, desc);
    if (cell.len < desc.size) return "";
    return formatValueBuf(buf, desc, cell.ptr, atoms);
}

fn parseHexBytes(text: []const u8, bytes: []u8) !void {
    if (text.len != bytes.len * 2) return error.WrongByteCount;
    // Validate the whole string before publishing any bytes to a live row.
    for (text) |character| _ = try std.fmt.charToDigit(character, 16);
    for (bytes, 0..) |*byte, i| byte.* = std.fmt.parseInt(u8, text[i * 2 ..][0..2], 16) catch unreachable;
}
fn parseViewText(desc: *const FieldDescriptor, text: []const u8, dst: []u8, atoms: *Atom.Registry) !void {
    if (dst.len != desc.stride) return error.InvalidDestination;
    switch (desc.view_kind) {
        // Opaque: its bytes mean something only to the code that wrote them.
        .bytes => return error.NotEditable,
        .float_slider => |cfg| {
            const parsed = try std.fmt.parseFloat(f32, std.mem.trim(u8, text, " "));
            @as(*f32, @ptrCast(@alignCast(dst.ptr))).* = std.math.clamp(parsed, cfg.min, cfg.max);
        },
        .text_field => {
            // A string's text goes into its table's arena, not into cell bytes.
            if (desc.field_type == .string) return error.NotEditable;
            if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
            if (text.len > dst.len) return error.ValueTooLong;
            @memset(dst, 0);
            @memcpy(dst[0..text.len], text);
        },
        .vector => |cfg| {
            var temp: [64]f32 = undefined;
            if (cfg.components > temp.len) return error.TooManyComponents;
            var it = std.mem.splitScalar(u8, text, ',');
            var i: usize = 0;
            while (it.next()) |part| {
                if (i >= cfg.components) return error.TooManyComponents;
                temp[i] = try std.fmt.parseFloat(f32, std.mem.trim(u8, part, " ()"));
                i += 1;
            }
            if (i != cfg.components) return error.WrongComponentCount;
            @memcpy(@as([*]f32, @ptrCast(@alignCast(dst.ptr)))[0..i], temp[0..i]);
        },
        .matrix => |cfg| {
            const count: usize = @as(usize, cfg.rows) * cfg.cols;
            var temp: [64]f32 = undefined;
            if (count > temp.len) return error.TooManyComponents;
            var it = std.mem.splitAny(u8, text, ", |");
            var i: usize = 0;
            while (it.next()) |part| {
                const trimmed = std.mem.trim(u8, part, " ");
                if (trimmed.len == 0) continue;
                if (i >= count) return error.TooManyComponents;
                temp[i] = try std.fmt.parseFloat(f32, trimmed);
                i += 1;
            }
            if (i != count) return error.WrongComponentCount;
            @memcpy(@as([*]f32, @ptrCast(@alignCast(dst.ptr)))[0..count], temp[0..count]);
        },
        .color => {
            var temp: [4]u8 = undefined;
            var it = std.mem.splitScalar(u8, text, ',');
            var i: usize = 0;
            while (it.next()) |part| {
                if (i >= 4) return error.TooManyComponents;
                temp[i] = try std.fmt.parseInt(u8, std.mem.trim(u8, part, " "), 10);
                i += 1;
            }
            if (i != 4) return error.WrongComponentCount;
            @memcpy(dst[0..4], &temp);
        },
        .ref => {
            const ref = try Table.parseRef(text, atoms);
            @memcpy(dst[0..@sizeOf(Table.Ref)], std.mem.asBytes(&ref));
        },
        .atom => {
            const trimmed = std.mem.trim(u8, text, " ");
            @as(*Atom, @ptrCast(@alignCast(dst.ptr))).* = if (std.mem.eql(u8, trimmed, "<none>")) @enumFromInt(0) else atoms.intern(trimmed);
        },
        .int => {
            const t = std.mem.trim(u8, text, " ");
            if (holds(desc, f32)) {
                const parsed = try std.fmt.parseFloat(f32, t);
                if (!std.math.isFinite(parsed)) return error.NotFinite;
                @as(*f32, @ptrCast(@alignCast(dst.ptr))).* = parsed;
            } else if (holds(desc, f64)) {
                const parsed = try std.fmt.parseFloat(f64, t);
                if (!std.math.isFinite(parsed)) return error.NotFinite;
                @as(*f64, @ptrCast(@alignCast(dst.ptr))).* = parsed;
            } else if (holds(desc, i32))
                @as(*i32, @ptrCast(@alignCast(dst.ptr))).* = try std.fmt.parseInt(i32, t, 10)
            else if (desc.size == 1) @as(*u8, @ptrCast(dst.ptr)).* = try std.fmt.parseInt(u8, t, 10) else if (desc.size == 2) @as(*u16, @ptrCast(@alignCast(dst.ptr))).* = try std.fmt.parseInt(u16, t, 10) else if (desc.size == 8) @as(*u64, @ptrCast(@alignCast(dst.ptr))).* = try std.fmt.parseInt(u64, t, 10) else @as(*u32, @ptrCast(@alignCast(dst.ptr))).* = try std.fmt.parseInt(u32, t, 10);
        },
        .hex => {
            const trimmed = std.mem.trim(u8, text, " ");
            const t = if (std.mem.startsWith(u8, trimmed, "0x") or std.mem.startsWith(u8, trimmed, "0X")) trimmed[2..] else trimmed;
            if (desc.size > 8) {
                try parseHexBytes(t, dst[0..desc.size]);
                return;
            }
            if (desc.size == 1) @as(*u8, @ptrCast(dst.ptr)).* = try std.fmt.parseInt(u8, t, 16) else if (desc.size == 2) @as(*u16, @ptrCast(@alignCast(dst.ptr))).* = try std.fmt.parseInt(u16, t, 16) else if (desc.size == 8) @as(*u64, @ptrCast(@alignCast(dst.ptr))).* = try std.fmt.parseInt(u64, t, 16) else @as(*u32, @ptrCast(@alignCast(dst.ptr))).* = try std.fmt.parseInt(u32, t, 16);
        },
        .checkbox => return error.CheckboxHasNoPayload,
        .toggle => dst[0] = @intFromBool(try parseBoolean(text)),
    }
}

fn parseBoolean(text: []const u8) !bool {
    const t = std.mem.trim(u8, text, " ");
    if (std.ascii.eqlIgnoreCase(t, "true") or std.mem.eql(u8, t, "1")) return true;
    if (std.ascii.eqlIgnoreCase(t, "false") or std.mem.eql(u8, t, "0")) return false;
    return error.InvalidBoolean;
}

/// Writes `text`, read as the field's view kind reads it, into the cell, and marks it present.
/// An error leaves the cell as it was: the row or field is gone, or the text is not a value of
/// the field (`parseViewText`'s errors). Atom and reference cells intern what was typed in
/// `atoms`: a person's data being entered.
pub fn commitEditText(table: *Table, row: u32, field: u32, text: []const u8, atoms: *Atom.Registry) !void {
    if (!table.isAllocated(row)) return error.InvalidRow;
    if (field >= table.getSchema().fields.len) return error.InvalidField;
    const desc = &table.getSchema().fields[field];
    if (desc.view_kind == .text_field) {
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        const handle: Table.RowHandle = .{ .row = row, .generation = table.rowGeneration(row) };
        table.setCellText(handle, field, text) catch |failure| return switch (failure) {
            error.ValueTooLong => error.ValueTooLong,
            error.OutOfMemory, error.Overflow => error.OutOfMemory,
            error.StaleHandle, error.UnknownField => error.InvalidRow,
        };
        return;
    }
    // The run's copy of the row, through the journal: a fault takes the edit back.
    const cell = table.writableCellBytes(row, desc);
    if (cell.len < desc.size) return error.InvalidRow;
    switch (desc.view_kind) {
        .text_field => unreachable,
        .checkbox => {
            const value = try parseBoolean(text);
            table.setPresent(row, desc.bit, value);
            table.touch();
            return;
        },
        else => {
            const dst = cell.ptr[0..desc.stride];
            try parseViewText(desc, text, dst, atoms);
        },
    }
    table.setPresent(row, desc.bit, true);
    table.touch();
}

/// Whether a click or Enter flips the cell instead of editing its text: a tag's
/// presence or a bool's value.
pub fn flipsOnActivate(desc: *const FieldDescriptor) bool {
    return desc.view_kind == .checkbox or desc.view_kind == .toggle;
}

/// Blanks a cell, as Org blanks a field: a text cell's text is emptied, and any other cell is
/// left absent, which shows as `-`, or as an unchecked checkbox. False when the row or field is
/// gone or the text could not be emptied.
pub fn clearCell(table: *Table, row: u32, field: u32) bool {
    if (!table.isAllocated(row) or field >= table.getSchema().fields.len) return false;
    const desc = &table.getSchema().fields[field];
    if (desc.view_kind == .text_field) {
        const handle: Table.RowHandle = .{ .row = row, .generation = table.rowGeneration(row) };
        table.setCellText(handle, field, "") catch |err| {
            Log.err("table_view_cell_clear_failed", .{ .table = table.name, .row = row, .field = field, .@"error" = @errorName(err) });
            return false;
        };
        return true;
    }
    table.setPresent(row, desc.bit, false);
    table.touch();
    return true;
}

/// Flips a checkbox cell's presence, or a toggle's value (making it present); does nothing to
/// another cell, or to a row or field that is not there.
pub fn toggleCheckbox(table: *Table, row: u32, field: u32) void {
    if (!table.isAllocated(row) or field >= table.getSchema().fields.len) return;
    const desc = &table.getSchema().fields[field];
    switch (desc.view_kind) {
        .checkbox => table.setPresent(row, desc.bit, !table.rowHas(row, desc.bit)),
        .toggle => {
            const cell = table.writableCellBytes(row, desc);
            if (cell.len == 0) return;
            cell[0] = @intFromBool(cell[0] == 0);
            table.setPresent(row, desc.bit, true);
        },
        else => {},
    }
}

test "large hex cells roundtrip every byte and reject partial invalid writes" {
    var mem: memory_mod.Memory = undefined;
    mem.init(std.testing.allocator);
    defer mem.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&mem);
    defer atoms.deinit();
    const desc = FieldDescriptor{ .name = "bones", .size = 16, .stride = 16, .column_index = 0, .bit = 0, .view_kind = .hex };
    const bytes = [_]u8{ 1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0, 4, 0, 0, 0 };
    var buf: [256]u8 = undefined;
    const text = formatValueBuf(&buf, &desc, &bytes, &atoms);
    try std.testing.expectEqualStrings("0x01000000020000000300000004000000", text);
    var parsed: [16]u8 = @splat(0);
    try parseViewText(&desc, text, &parsed, &atoms);
    try std.testing.expectEqualSlices(u8, &bytes, &parsed);
    buf[text.len - 1] = 'z';
    try std.testing.expectError(error.InvalidCharacter, parseViewText(&desc, text, &parsed, &atoms));
    try std.testing.expectEqualSlices(u8, &bytes, &parsed);
}
test "a float declared as a plain number shows and parses as a float" {
    var atoms: Atom.Registry = undefined;
    var desc: FieldDescriptor = undefined;
    desc.view_kind = .int;
    desc.size = @sizeOf(f32);
    desc.stride = @sizeOf(f32);
    desc.semantic_type = std.hash.Wyhash.hash(0, @typeName(f32));
    const width: f32 = 1920;
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1920", formatValueBuf(&buf, &desc, &width, &atoms));
    var parsed: f32 = 0;
    try parseViewText(&desc, "1052.5", std.mem.asBytes(&parsed), &atoms);
    try std.testing.expectEqual(@as(f32, 1052.5), parsed);
    try std.testing.expectError(error.NotFinite, parseViewText(&desc, "inf", std.mem.asBytes(&parsed), &atoms));
}

test "parseViewText validates compound and string values before writing" {
    var mem: memory_mod.Memory = undefined;
    mem.init(std.testing.allocator);
    defer mem.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&mem);
    defer atoms.deinit();
    const color = FieldDescriptor{ .name = "color", .size = 4, .stride = 4, .column_index = 0, .bit = 0, .view_kind = .color };
    var bytes: [4]u8 = .{ 1, 2, 3, 4 };
    try std.testing.expectError(error.WrongComponentCount, parseViewText(&color, "9, 8, 7", &bytes, &atoms));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, &bytes);
    try parseViewText(&color, "9, 8, 7, 6", &bytes, &atoms);
    try std.testing.expectEqualSlices(u8, &.{ 9, 8, 7, 6 }, &bytes);
    const text = FieldDescriptor{ .name = "text", .size = 4, .stride = 4, .column_index = 0, .bit = 0, .view_kind = .text_field };
    try std.testing.expectError(error.InvalidUtf8, parseViewText(&text, "\xff", &bytes, &atoms));
    try std.testing.expectError(error.ValueTooLong, parseViewText(&text, "12345", &bytes, &atoms));
    try std.testing.expectEqualSlices(u8, &.{ 9, 8, 7, 6 }, &bytes);
    try parseViewText(&text, "hi", &bytes, &atoms);
    try std.testing.expectEqualSlices(u8, &.{ 'h', 'i', 0, 0 }, &bytes);
}

test "clearCell empties a text cell and leaves any other cell absent" {
    var mem: memory_mod.Memory = undefined;
    mem.init(std.testing.allocator);
    defer mem.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&mem);
    defer atoms.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&mem, 8);
    defer tables.deinit();
    const scratch = try mem.tableScratchAllocator();
    var schema: Table.Schema = undefined;
    try schema.init(scratch.allocator, &atoms, 2);
    defer schema.deinit();
    schema.addField("name", Table.String, .text_field);
    schema.addField("count", u32, .int);
    const ensured = try tables.ensure(&schema, 4, atoms.intern("clear_cell_test"), .durable);
    const table = ensured.table;
    const handle = try table.tryInsert(.{ .name = Table.String{}, .count = @as(u32, 7) });
    try table.setCellText(handle, 0, "a name");
    const fields = table.getSchema().fields;

    try std.testing.expect(clearCell(table, handle.row, 0));
    try std.testing.expectEqualStrings("", table.cellText(handle.row, &fields[0]));
    try std.testing.expect(table.rowHas(handle.row, fields[1].bit));
    try std.testing.expect(clearCell(table, handle.row, 1));
    try std.testing.expect(!table.rowHas(handle.row, fields[1].bit));
    // A field past the schema's, or a row that is gone, clears nothing.
    try std.testing.expect(!clearCell(table, handle.row, 2));
    table.free(handle);
    try std.testing.expect(!clearCell(table, handle.row, 0));
}
