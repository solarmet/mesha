//! ZON text read into the dynamic `Value` model and written back, and edits to one field of a
//! ZON file's root struct that leave the rest of the text, comments included, as it is.
//!
//! `parse` reads a whole document into a `Value` tree (`value.zig`): an enum literal (`.walk`)
//! becomes an atom, a struct literal a map keyed by its field names' atoms, a tuple a vector.
//! `serializeValue` and `serializeOutline` write a tree back as text that `parse` reads to the
//! same tree. `parseRootStruct` reads a hand-edited file field by field, so one bad field does
//! not lose the others. `rootStructFieldRange`, `replaceRootStructField`,
//! `appendRootStructField` and `removeRootStructField` change the text of a file in place of
//! rewriting it. Parsing uses Zig's own ZON parser (`std.zig.Ast`, `std.zig.ZonGen`).
//!
//! Nothing here touches a file or a table: callers read and write the bytes. Parsing interns
//! names, so it runs on the thread that owns the atom registry, outside kernels.
const std = @import("std");
const value_mod = @import("value.zig");
const memory_mod = @import("memory.zig");

/// The dynamic value a document parses to; see `value.zig`.
pub const Value = value_mod.Value;
/// A `Value` map, which a struct literal parses to.
pub const Map = value_mod.Map;
/// The engine's atom type.
pub const Atom = value_mod.Atom;
/// Every error reading or writing ZON gives; each is described at `value.ParseError`.
pub const ParseError = value_mod.ParseError;

/// How deep structs and tuples may nest. `parse` fails with `error.NestingTooDeep` on a
/// document that reaches this depth, and the serializers on a value that does.
pub const kMaxNestingDepth: usize = 256;

/// Why a `parse` failed, as a sentence for a person. The text is copied into the struct, cut at
/// 256 bytes, so it outlives the parse's own memory.
pub const Diagnostics = struct {
    /// The message's bytes; only the first `message_len` are meaningful.
    message: [256]u8 = [_]u8{0} ** 256,
    /// The length of the message in bytes; 0 when there is none.
    message_len: usize = 0,

    /// The message, empty when no failure set one. A slice of this struct: valid while it is
    /// neither moved nor passed to another `parse`.
    pub fn text(self: *const @This()) []const u8 {
        return self.message[0..self.message_len];
    }

    fn set(self: *@This(), message: []const u8) void {
        self.message_len = @min(message.len, self.message.len);
        @memcpy(self.message[0..self.message_len], message[0..self.message_len]);
    }
};

/// A parsed value with the arena that owns it.
pub const ParseResult = value_mod.ParseResult;

/// Whether `name` may be written as an atom literal (`.name`): a lowercase ASCII letter, then
/// lowercase letters, digits and single underscores, not ending in an underscore.
pub fn isSnakeCaseAtom(name: []const u8) bool {
    if (name.len == 0 or !std.ascii.isLower(name[0])) return false;
    var previous_underscore = false;
    for (name[1..], 1..) |c, i| {
        if (c == '_') {
            if (previous_underscore or i == name.len - 1) return false;
            previous_underscore = true;
        } else if (std.ascii.isLower(c) or std.ascii.isDigit(c)) {
            previous_underscore = false;
        } else {
            return false;
        }
    }
    return true;
}

/// Reads `source`, a whole ZON document, into a `Value`.
///
/// `true`, `false` and `null` become `boolean` and `nil`; numbers `integer` (an `i64`) or
/// `float`; a character literal `character`; a string a copy in `string`; an enum literal
/// `atom`, interned into `atoms`; a tuple `vector`; a struct `map`, its keys the field names'
/// atoms, interned too, in the order written; `.{}` is `empty`.
///
/// The result owns its values in an arena made from `allocator`: free it with
/// `ParseResult.deinit`. `source` is not kept. Names interned before a failure stay interned.
///
/// Errors: `InvalidZon` for text Zig's parser refuses (a repeated field name among it) or
/// 4 GiB or more of it; `InvalidAtomName` for an enum literal that is not `isSnakeCaseAtom`
/// or is written escaped (`.@"name"`); `IntegerOutOfRange` for an integer outside `i64`;
/// `NestingTooDeep` past `kMaxNestingDepth`; `OutOfMemory`. When `diagnostics` is given it is
/// reset first and holds a sentence for the failure, or the error's name where there is none.
pub fn parse(allocator: std.mem.Allocator, source: []const u8, atoms: *Atom.Registry, diagnostics: ?*Diagnostics) ParseError!ParseResult {
    if (diagnostics) |diag| diag.* = .{};

    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();
    const parse_allocator = parse_arena.allocator();
    // std.zig.Ast stores token offsets as u32.
    if (source.len >= std.math.maxInt(u32)) return error.InvalidZon;
    const zon_source = try parse_allocator.dupeZ(u8, source);

    var ast = std.zig.Ast.parse(parse_allocator, zon_source, .zon) catch return error.OutOfMemory;
    defer ast.deinit(parse_allocator);
    var zoir = std.zig.ZonGen.generate(parse_allocator, ast, .{ .parse_str_lits = true }) catch return error.OutOfMemory;
    defer zoir.deinit(parse_allocator);

    if (zoir.hasCompileErrors()) {
        if (diagnostics) |diag| {
            const first = zoir.compile_errors[0];
            diag.set(first.msg.get(zoir));
        }
        return error.InvalidZon;
    }

    var result = ParseResult{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .value = .nil,
    };
    errdefer result.deinit();
    result.value = convertNode(result.arena.allocator(), ast, zoir, .root, 0, atoms, diagnostics) catch |err| {
        if (diagnostics) |diag| if (diag.message_len == 0) {
            diag.set(@errorName(err));
        };
        return err;
    };
    return result;
}

fn convertNode(
    allocator: std.mem.Allocator,
    ast: std.zig.Ast,
    zoir: std.zig.Zoir,
    node_index: std.zig.Zoir.Node.Index,
    depth: usize,
    atoms: *Atom.Registry,
    diagnostics: ?*Diagnostics,
) ParseError!Value {
    if (depth >= kMaxNestingDepth) return error.NestingTooDeep;

    const node = node_index.get(zoir);
    return switch (node) {
        .true => .{ .boolean = true },
        .false => .{ .boolean = false },
        .null => .nil,
        .pos_inf => .{ .float = std.math.inf(f64) },
        .neg_inf => .{ .float = -std.math.inf(f64) },
        .nan => .{ .float = std.math.nan(f64) },
        .int_literal => |literal| .{ .integer = switch (literal) {
            .small => |n| n,
            .big => |n| n.toInt(i64) catch return error.IntegerOutOfRange,
        } },
        .float_literal => |n| .{ .float = @floatCast(n) },
        .char_literal => |c| .{ .character = c },
        .enum_literal => |literal| blk: {
            const name = literal.get(zoir);
            const ast_node = node_index.getAstNode(zoir);
            const token = ast.nodeMainToken(ast_node);
            const lexeme = ast.tokenSlice(token);
            if (std.mem.startsWith(u8, lexeme, "@") or !isSnakeCaseAtom(name)) {
                if (diagnostics) |diag| diag.set("atom enum literals must use unescaped lowercase snake_case");
                return error.InvalidAtomName;
            }
            break :blk .{ .atom = atoms.intern(name) };
        },
        .string_literal => |s| .{ .string = try allocator.dupe(u8, s) },
        .empty_literal => .empty,
        .array_literal => |range| blk: {
            const items = try allocator.alloc(Value, range.len);
            for (items, 0..) |*item, i| {
                item.* = try convertNode(allocator, ast, zoir, range.at(@intCast(i)), depth + 1, atoms, diagnostics);
            }
            break :blk .{ .vector = items };
        },
        .struct_literal => |fields| blk: {
            var map: Map = .empty;
            for (0..fields.names.len) |i| {
                const name = fields.names[i].get(zoir);
                const key: Value = .{ .atom = atoms.intern(name) };
                const gop = try map.getOrPut(allocator, key);
                if (gop.found_existing) {
                    if (diagnostics) |diag| diag.set("duplicate ZON struct field");
                    return error.DuplicateField;
                }
                gop.value_ptr.* = try convertNode(allocator, ast, zoir, fields.vals.at(@intCast(i)), depth + 1, atoms, diagnostics);
            }
            break :blk .{ .map = map };
        },
    };
}

/// A span of a ZON source text, as byte offsets: `start` inclusive, `end` exclusive.
pub const SourceRange = struct { start: usize, end: usize };

/// Where the value of the root struct's field `field_name` lies in `source`: the value alone,
/// without `.name =` or the comma after it. Null when the root is not a struct or has no such
/// field; a field of a nested struct is never found. Reads the text as `parse` does, so
/// escaped field names (`.@"a b"`) and multiline strings are understood. Fails with
/// `error.InvalidZon` on text that is not ZON. `allocator` is used for scratch only.
pub fn rootStructFieldRange(allocator: std.mem.Allocator, source: []const u8, field_name: []const u8) ParseError!?SourceRange {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const terminated = try a.dupeZ(u8, source);
    var ast = try std.zig.Ast.parse(a, terminated, .zon);
    defer ast.deinit(a);
    var zoir = try std.zig.ZonGen.generate(a, ast, .{ .parse_str_lits = true });
    defer zoir.deinit(a);
    if (zoir.hasCompileErrors()) return error.InvalidZon;
    const root = std.zig.Zoir.Node.Index.root.get(zoir);
    if (root != .struct_literal) return null;
    for (root.struct_literal.names, 0..) |name, i| {
        if (!std.mem.eql(u8, name.get(zoir), field_name)) continue;
        const node = root.struct_literal.vals.at(@intCast(i)).getAstNode(zoir);
        const first = ast.firstToken(node);
        const last = ast.lastToken(node);
        return .{ .start = ast.tokenStart(first), .end = ast.tokenStart(last) + ast.tokenSlice(last).len };
    }
    return null;
}

/// `source` with the value of its root struct's field `field_name` replaced by `replacement`,
/// every other byte kept. `replacement` is written as it is and must be ZON for the result to
/// parse. The caller owns the result, allocated with `allocator`. Fails with
/// `error.FieldNotFound` when the root is not a struct or has no such field, and
/// `error.InvalidZon` on text that is not ZON.
pub fn replaceRootStructField(allocator: std.mem.Allocator, source: []const u8, field_name: []const u8, replacement: []const u8) ![]u8 {
    const range = (try rootStructFieldRange(allocator, source, field_name)) orelse return error.FieldNotFound;
    const prefix_len = range.start;
    const suffix_start = range.end;
    const new_len = std.math.add(usize, prefix_len, replacement.len) catch return error.OutOfMemory;
    const total_len = std.math.add(usize, new_len, source.len - suffix_start) catch return error.OutOfMemory;
    const output = try allocator.alloc(u8, total_len);
    @memcpy(output[0..prefix_len], source[0..prefix_len]);
    @memcpy(output[prefix_len..][0..replacement.len], replacement);
    @memcpy(output[new_len..], source[suffix_start..]);
    return output;
}

/// A root struct literal's fields, each read alone, so a field that does not read loses only
/// itself: a file a person edits by hand. Owns everything its fields point at; free it with
/// `deinit`.
pub const RootStruct = struct {
    /// Owns the fields, their names and their values.
    arena: std.heap.ArenaAllocator,
    /// The root's fields in the order written; empty for `.{}`.
    fields: []const Field,

    /// One field of the root struct.
    pub const Field = struct {
        /// In the arena.
        name: []const u8,
        /// Its value, in the arena, or why it did not read.
        value: ParseError!Value,
    };

    /// Frees the fields and everything they point at.
    pub fn deinit(root: *RootStruct) void {
        root.arena.deinit();
    }
};

/// The fields of `source`'s root struct literal. Fails when the text is not ZON
/// (`error.InvalidZon`) or its root is not a struct (`error.UnexpectedToken`; `.{}` has no
/// fields); a field's own value failing fails only that field. Atoms in the values are interned
/// into `atoms`; field names are returned as text and not interned. The caller frees the
/// result with `RootStruct.deinit`.
pub fn parseRootStruct(allocator: std.mem.Allocator, source: []const u8, atoms: *Atom.Registry) ParseError!RootStruct {
    var document = try RootDocument.parse(allocator, source);
    defer document.deinit();

    var result: RootStruct = .{ .arena = std.heap.ArenaAllocator.init(allocator), .fields = &.{} };
    errdefer result.deinit();
    const result_allocator = result.arena.allocator();
    switch (document.root()) {
        .empty_literal => return result,
        .struct_literal => |literal| {
            const fields = try result_allocator.alloc(RootStruct.Field, literal.names.len);
            for (fields, literal.names, 0..) |*field, name, i| {
                const name_text = try result_allocator.dupe(u8, name.get(document.zoir));
                const value_node = literal.vals.at(@intCast(i));
                const value = convertNode(result_allocator, document.ast, document.zoir, value_node, 1, atoms, null);
                field.* = .{ .name = name_text, .value = value };
            }
            result.fields = fields;
            return result;
        },
        else => return error.UnexpectedToken,
    }
}

/// Whether `source` is ZON whose root is a struct (`.{}` included), which the root field edits
/// can change. `allocator` is used for scratch only; running out of memory reads as false.
pub fn rootIsStruct(allocator: std.mem.Allocator, source: []const u8) bool {
    var document = RootDocument.parse(allocator, source) catch return false;
    defer document.deinit();
    return document.closingBrace() != null;
}

/// A parsed document, kept to find where its root struct's parts lie in the text.
const RootDocument = struct {
    arena: std.heap.ArenaAllocator,
    ast: std.zig.Ast,
    zoir: std.zig.Zoir,

    fn parse(allocator: std.mem.Allocator, source: []const u8) ParseError!RootDocument {
        // std.zig.Ast stores token offsets as u32.
        if (source.len >= std.math.maxInt(u32)) return error.InvalidZon;
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();
        const terminated = try arena_allocator.dupeZ(u8, source);
        const ast = try std.zig.Ast.parse(arena_allocator, terminated, .zon);
        const zoir = try std.zig.ZonGen.generate(arena_allocator, ast, .{ .parse_str_lits = true });
        if (zoir.hasCompileErrors()) return error.InvalidZon;
        return .{ .arena = arena, .ast = ast, .zoir = zoir };
    }

    fn deinit(document: *RootDocument) void {
        document.arena.deinit();
    }

    fn root(document: *const RootDocument) std.zig.Zoir.Node {
        return std.zig.Zoir.Node.Index.root.get(document.zoir);
    }

    /// The root struct's closing brace; null when the root is not a struct.
    fn closingBrace(document: *const RootDocument) ?std.zig.Ast.TokenIndex {
        switch (document.root()) {
            .empty_literal, .struct_literal => {},
            else => return null,
        }
        const node = std.zig.Zoir.Node.Index.root.getAstNode(document.zoir);
        return document.ast.lastToken(node);
    }

    /// The text of field `field_name`'s whole entry, `.name = value` and its comma.
    fn fieldEntryRange(document: *const RootDocument, field_name: []const u8) ?SourceRange {
        const literal = switch (document.root()) {
            .struct_literal => |literal| literal,
            else => return null,
        };
        const ast = &document.ast;
        for (literal.names, 0..) |name, i| {
            if (!std.mem.eql(u8, name.get(document.zoir), field_name)) continue;
            const value_node = literal.vals.at(@intCast(i)).getAstNode(document.zoir);
            // `.` name `=` precede the value.
            const period = ast.firstToken(value_node) - 3;
            std.debug.assert(ast.tokenTag(period) == .period);
            var last = ast.lastToken(value_node);
            if (ast.tokenTag(last + 1) == .comma) last += 1;
            return .{ .start = ast.tokenStart(period), .end = ast.tokenStart(last) + ast.tokenSlice(last).len };
        }
        return null;
    }
};

/// `source` with `.field_name = value_text,` added as its root struct's last field, on a line
/// of its own, indented four spaces. The field must not be there already: this does not check.
/// `value_text` is written as it is and must be ZON; `field_name` is escaped where an
/// identifier needs it. The caller owns the result, allocated with `allocator`. Fails with
/// `error.InvalidZon` on text that is not ZON and `error.UnexpectedToken` when its root is not
/// a struct.
pub fn appendRootStructField(allocator: std.mem.Allocator, source: []const u8, field_name: []const u8, value_text: []const u8) ![]u8 {
    var document = try RootDocument.parse(allocator, source);
    defer document.deinit();
    const ast = &document.ast;
    const brace = document.closingBrace() orelse return error.UnexpectedToken;
    const previous = brace - 1;
    // The field before it needs a comma to separate them.
    const needs_comma = ast.tokenTag(previous) != .comma and ast.tokenTag(previous) != .l_brace;
    const comma_at = ast.tokenStart(previous) + ast.tokenSlice(previous).len;
    const brace_at = ast.tokenStart(brace);
    const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..brace_at], '\n')) |newline| newline + 1 else 0;
    const brace_on_own_line = std.mem.trim(u8, source[line_start..brace_at], " \t").len == 0 and line_start > comma_at;

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    const insert_at = if (brace_on_own_line) line_start else brace_at;
    try writer.writeAll(source[0..comma_at]);
    if (needs_comma) try writer.writeByte(',');
    try writer.writeAll(source[comma_at..insert_at]);
    if (!brace_on_own_line) try writer.writeByte('\n');
    try writer.print("    .{f} = {s},\n", .{ std.zig.fmtId(field_name), value_text });
    try writer.writeAll(source[insert_at..]);
    return output.toOwnedSlice();
}

/// `source` without its root struct's field `field_name`, and without the line it was on when
/// nothing but space or a comment shared it. Null when the field is not there or the root is
/// not a struct. The caller owns the result, allocated with `allocator`.
pub fn removeRootStructField(allocator: std.mem.Allocator, source: []const u8, field_name: []const u8) ParseError!?[]u8 {
    var document = try RootDocument.parse(allocator, source);
    defer document.deinit();
    var range = document.fieldEntryRange(field_name) orelse return null;
    const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..range.start], '\n')) |newline| newline + 1 else 0;
    const line_end = std.mem.indexOfScalarPos(u8, source, range.end, '\n') orelse source.len;
    const before = std.mem.trim(u8, source[line_start..range.start], " \t");
    const after = std.mem.trim(u8, source[range.end..line_end], " \t");
    const after_is_comment = after.len == 0 or std.mem.startsWith(u8, after, "//");
    if (before.len == 0 and after_is_comment) {
        range.start = line_start;
        range.end = @min(line_end + 1, source.len);
    }
    const output = try allocator.alloc(u8, source.len - (range.end - range.start));
    @memcpy(output[0..range.start], source[0..range.start]);
    @memcpy(output[range.start..], source[range.end..]);
    return output;
}

/// Writes `value` to `writer` as ZON on one line, which `parse` reads back to an equal value.
///
/// An atom is written as `.name` and a map key as `.@"name"`, from the names `atoms` holds.
/// A float always has a `.` or exponent, or is `inf`, `-inf` or `nan`; `nil` is `null`.
///
/// Errors: `UnknownAtom` for an atom `atoms` has no name for; `InvalidAtomName` for an atom
/// value whose name is not `isSnakeCaseAtom` (a map key may be any name); `InvalidMapKey` for
/// a map key that is not an atom; `NestingTooDeep` past `kMaxNestingDepth`; and the writer's
/// own errors. What was written before a failure stays written.
pub fn serializeValue(value: Value, atoms: *const Atom.Registry, writer: anytype) !void {
    try serializeDepth(value, atoms, writer, 0);
}

/// Writes `value` as a document a person reads in a diff: each top-level field on a line of its
/// own, and each item of a field that is a list on its own line. Parses to the value
/// `serializeValue`'s text parses to, and fails as it does. A value that is not a map is
/// written as `serializeValue` writes it.
pub fn serializeOutline(value: Value, atoms: *const Atom.Registry, writer: anytype) !void {
    if (value != .map) return serializeValue(value, atoms, writer);
    try writer.writeAll(".{\n");
    var fields = value.map.iterator();
    while (fields.next()) |entry| {
        const key = entry.key_ptr.*;
        if (key != .atom) return error.InvalidMapKey;
        const name = atoms.lookup(key.atom) orelse return error.UnknownAtom;
        try writer.writeAll("    .@");
        try writeString(name, writer);
        try writer.writeAll(" = ");
        const item_list = entry.value_ptr.*;
        if (item_list == .vector and item_list.vector.len != 0) {
            try writer.writeAll(".{\n");
            for (item_list.vector) |item| {
                try writer.writeAll("        ");
                try serializeDepth(item, atoms, writer, 2);
                try writer.writeAll(",\n");
            }
            try writer.writeAll("    }");
        } else try serializeDepth(item_list, atoms, writer, 1);
        try writer.writeAll(",\n");
    }
    try writer.writeByte('}');
}

fn serializeDepth(value: Value, atoms: *const Atom.Registry, writer: anytype, depth: usize) !void {
    if (depth >= kMaxNestingDepth) return error.NestingTooDeep;
    switch (value) {
        .nil => try writer.writeAll("null"),
        .empty => try writer.writeAll(".{}"),
        .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
        .integer => |n| try writer.print("{d}", .{n}),
        .float => |f| try writeFloat(f, writer),
        .string => |s| try writeString(s, writer),
        .atom => |id| {
            const name = atoms.lookup(id) orelse return error.UnknownAtom;
            if (!isSnakeCaseAtom(name)) return error.InvalidAtomName;
            try writer.writeByte('.');
            try writer.writeAll(name);
        },
        .character => |c| try writeCharacter(c, writer),
        .vector => |items| {
            try writer.writeAll(".{");
            for (items, 0..) |item, i| {
                if (i > 0) try writer.writeAll(", ");
                try serializeDepth(item, atoms, writer, depth + 1);
            }
            try writer.writeByte('}');
        },
        .map => |map| {
            try writer.writeAll(".{");
            var it = map.iterator();
            var first = true;
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (key != .atom) return error.InvalidMapKey;
                const name = atoms.lookup(key.atom) orelse return error.UnknownAtom;
                if (!first) try writer.writeAll(", ");
                first = false;
                try writer.writeAll(".@");
                try writeString(name, writer);
                try writer.writeAll(" = ");
                try serializeDepth(entry.value_ptr.*, atoms, writer, depth + 1);
            }
            try writer.writeByte('}');
        },
    }
}

fn writeFloat(value: f64, writer: anytype) !void {
    if (std.math.isNan(value)) return writer.writeAll("nan");
    if (std.math.isInf(value)) return writer.writeAll(if (value < 0) "-inf" else "inf");

    var buffer: [96]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{d}", .{value});
    try writer.writeAll(text);
    if (std.mem.indexOfAny(u8, text, ".eE") == null) try writer.writeAll(".0");
}

fn writeString(value: []const u8, writer: anytype) !void {
    try writer.writeByte('"');
    for (value) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0...8, 11, 12, 14...31, 127 => try writer.print("\\x{X:0>2}", .{byte}),
        else => try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}

fn writeCharacter(value: u21, writer: anytype) !void {
    try writer.writeByte('\'');
    switch (value) {
        '\'' => try writer.writeAll("\\'"),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        32...38, 40...91, 93...126 => try writer.writeByte(@intCast(value)),
        else => try writer.print("\\u{{{X}}}", .{value}),
    }
    try writer.writeByte('\'');
}

const testing = std.testing;

const TestAtoms = struct {
    memory: memory_mod.Memory = undefined,
    atoms: Atom.Registry = undefined,

    fn init(self: *@This()) !void {
        self.memory.init(testing.allocator);
        try self.atoms.init(&self.memory);
    }

    fn deinit(self: *@This()) void {
        self.atoms.deinit();
        self.memory.deinit();
    }
};

fn atomValue(name: []const u8) Value {
    return .{ .atom = Atom.from(name) };
}

fn parseTestValue(atoms: *Atom.Registry, source: []const u8) !ParseResult {
    return parse(testing.allocator, source, atoms, null);
}

test "ZON reader maps enum literals and struct fields to interned atoms" {
    var context: TestAtoms = .{};
    try context.init();
    defer context.deinit();

    var parsed = try parseTestValue(
        &context.atoms,
        ".{ .name = .barnaby_locomotion, .text = \"barnaby-locomotion\", .position = .{ 1, 2, 3 }, .empty = .{} }",
    );
    defer parsed.deinit();

    const root = try parsed.value.asMap();
    const name = try root.get(atomValue("name")).?.asAtom();
    try testing.expectEqual(Atom.from("barnaby_locomotion"), name);
    try testing.expectEqualStrings("barnaby_locomotion", context.atoms.lookup(name).?);
    try testing.expectEqualStrings("barnaby-locomotion", try root.get(atomValue("text")).?.asString());
    try testing.expectEqual(@as(usize, 3), (try root.get(atomValue("position")).?.asVector()).len);
    try testing.expectEqual(@as(usize, 0), (try root.get(atomValue("empty")).?.asVector()).len);
    try testing.expectEqual(@as(usize, 0), (try root.get(atomValue("empty")).?.asMap()).count());
}

test "ZON reader rejects invalid, escaped, dotted, and hyphenated atom literals" {
    var context: TestAtoms = .{};
    try context.init();
    defer context.deinit();

    for ([_][]const u8{ ".@\"bad-name\"", ".@\"bad.name\"", ".@\"escaped_name\"" }) |source| {
        try testing.expectError(error.InvalidAtomName, parseTestValue(&context.atoms, source));
    }
}

test "ZON reader reports syntax and duplicate-field diagnostics" {
    var context: TestAtoms = .{};
    try context.init();
    defer context.deinit();

    var diag: Diagnostics = .{};
    try testing.expectError(error.InvalidZon, parse(testing.allocator, ".{", &context.atoms, &diag));
    try testing.expect(diag.message_len != 0);
    try testing.expectError(error.InvalidZon, parse(testing.allocator, ".{ .name = 1, .name = 2 }", &context.atoms, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.text(), "duplicate") != null);
}

test "ZON serialize and parse round-trip supported values through the same interner" {
    var context: TestAtoms = .{};
    try context.init();
    defer context.deinit();

    var parsed = try parseTestValue(&context.atoms, ".{ .name = .barnaby, .text = \"a\\nstring\", .values = .{ 1, -2.5, inf, nan }, .empty = .{} }");
    defer parsed.deinit();

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try serializeValue(parsed.value, &context.atoms, &output.writer);

    var reparsed = try parse(testing.allocator, output.written(), &context.atoms, null);
    defer reparsed.deinit();
    const before = try parsed.value.asMap();
    const after = try reparsed.value.asMap();
    const before_name = try before.get(atomValue("name")).?.asAtom();
    const after_name = try after.get(atomValue("name")).?.asAtom();
    try testing.expectEqual(before_name, after_name);
    try testing.expectEqualStrings("barnaby", context.atoms.lookup(after_name).?);
    try testing.expectEqualStrings("a\nstring", try after.get(atomValue("text")).?.asString());
    try testing.expectEqual(@as(usize, 0), (try after.get(atomValue("empty")).?.asMap()).count());
    const floats = try after.get(atomValue("values")).?.asVector();
    try testing.expect(std.math.isInf(try floats[2].asFloat()));
    try testing.expect(std.math.isNan(try floats[3].asFloat()));
    try testing.expectEqual(before.count(), after.count());
}

test "ZON serializer rejects invalid and unknown atoms" {
    var context: TestAtoms = .{};
    try context.init();
    defer context.deinit();

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try testing.expectError(error.InvalidAtomName, serializeValue(.{ .atom = context.atoms.intern("bad-name") }, &context.atoms, &output.writer));
    try testing.expectError(error.UnknownAtom, serializeValue(.{ .atom = @enumFromInt(0) }, &context.atoms, &output.writer));
}

test "ZON struct serialization requires interned atom keys" {
    var context: TestAtoms = .{};
    try context.init();
    defer context.deinit();

    const unknown: Atom = @enumFromInt(0);
    try testing.expect(context.atoms.lookup(unknown) == null);

    var unknown_key_map: Map = .empty;
    defer unknown_key_map.deinit(testing.allocator);
    try unknown_key_map.put(testing.allocator, .{ .atom = unknown }, .{ .integer = 1 });

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try testing.expectError(error.UnknownAtom, serializeValue(.{ .map = unknown_key_map }, &context.atoms, &output.writer));

    var invalid_key_map: Map = .empty;
    defer invalid_key_map.deinit(testing.allocator);
    try invalid_key_map.put(testing.allocator, .{ .integer = 7 }, .{ .integer = 1 });
    try testing.expectError(error.InvalidMapKey, serializeValue(.{ .map = invalid_key_map }, &context.atoms, &output.writer));
}

test "ZON root-field patching ignores comments and strings" {
    var context: TestAtoms = .{};
    try context.init();
    defer context.deinit();

    const source = "// .rows = .{ } is only a comment\n.{ .text = \"literal .rows = .{ }\", .rows = .{ .{ .value = 1 } }, .tail = .ok }";
    const patched = try replaceRootStructField(testing.allocator, source, "rows", ".{ .{ .value = 2 } }");
    defer testing.allocator.free(patched);
    try testing.expect(std.mem.startsWith(u8, patched, "// .rows = .{ } is only a comment\n"));
    try testing.expect(std.mem.indexOf(u8, patched, "literal .rows = .{ }") != null);
    var parsed = try parse(testing.allocator, patched, &context.atoms, null);
    defer parsed.deinit();
    const root = try parsed.value.asMap();
    const rows = try root.get(atomValue("rows")).?.asVector();
    const first = try rows[0].asMap();
    try testing.expectEqual(@as(i64, 2), try first.get(atomValue("value")).?.asInt());
}

test "serialized ZON can be patched repeatedly without changing other fields" {
    var context: TestAtoms = .{};
    try context.init();
    defer context.deinit();

    var parsed = try parseTestValue(&context.atoms, ".{ .text = \"keep .rows = .{}\", .rows = .{ .{ .value = 1 } }, .nested = .{ .rows = .{} } }");
    defer parsed.deinit();
    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();
    try serializeValue(parsed.value, &context.atoms, &output.writer);
    const first = try replaceRootStructField(testing.allocator, output.written(), "rows", ".{ .{ .value = 2 } }");
    defer testing.allocator.free(first);
    const second = try replaceRootStructField(testing.allocator, first, "rows", ".{}");
    defer testing.allocator.free(second);
    var result = try parseTestValue(&context.atoms, second);
    defer result.deinit();
    const root = try result.value.asMap();
    try testing.expectEqualStrings("keep .rows = .{}", try root.get(atomValue("text")).?.asString());
    try testing.expectEqual(@as(usize, 0), (try root.get(atomValue("rows")).?.asVector()).len);
    try testing.expect(value_mod.valueEql((try parsed.value.asMap()).get(atomValue("nested")).?, root.get(atomValue("nested")).?));
}

test "root field patching respects multiline strings and escaped field names" {
    var context: TestAtoms = .{};
    try context.init();
    defer context.deinit();

    const source =
        \\.{
        \\ .text =
        \\   \\\\ } .rows = .{ misleading }
        \\   \\\\ \"quoted\" { braces
        \\ ,
        \\ .@"rows" = .{ .{ .text = "quote\\\" brace }", .ch = '}' } },
        \\ .nested = .{ .rows = .{} }, // leave this intact
        \\}
    ;
    const patched = try replaceRootStructField(testing.allocator, source, "rows", ".{}");
    defer testing.allocator.free(patched);
    var before = try parseTestValue(&context.atoms, source);
    defer before.deinit();
    var after = try parseTestValue(&context.atoms, patched);
    defer after.deinit();
    const before_map = try before.value.asMap();
    const after_map = try after.value.asMap();
    try testing.expect(value_mod.valueEql(before_map.get(atomValue("text")).?, after_map.get(atomValue("text")).?));
    try testing.expect(std.mem.endsWith(u8, patched, ".nested = .{ .rows = .{} }, // leave this intact\n}"));
}

test "root source ranges reject malformed documents and ignore nested-only fields" {
    try testing.expectError(error.InvalidZon, rootStructFieldRange(testing.allocator, ".{", "rows"));
    try testing.expectError(error.InvalidZon, rootStructFieldRange(testing.allocator, ".{ .rows = .{}, .rows = .{} }", "rows"));
    try testing.expectEqual(@as(?SourceRange, null), try rootStructFieldRange(testing.allocator, ".{ .nested = .{ .rows = .{} } }", "rows"));
}

test "snake_case atom predicate rejects punctuation and malformed separators" {
    for ([_][]const u8{ "", "Upper", "has-dash", "has.dot", "_leading", "trailing_", "double__underscore", "has space" }) |name| {
        try testing.expect(!isSnakeCaseAtom(name));
    }
    for ([_][]const u8{ "barnaby", "barnaby_locomotion", "font_11", "act1_world" }) |name| {
        try testing.expect(isSnakeCaseAtom(name));
    }
}

test "a root struct's fields read one by one, a bad one failing alone" {
    var context: TestAtoms = .{};
    try context.init();
    defer context.deinit();
    var root = try parseRootStruct(testing.allocator, ".{ .keymap = .emacs, .bad = .NotSnake, .size = 3 }", &context.atoms);
    defer root.deinit();
    try testing.expectEqual(@as(usize, 3), root.fields.len);
    try testing.expectEqualStrings("keymap", root.fields[0].name);
    try testing.expectEqual(context.atoms.intern("emacs"), try (try root.fields[0].value).asAtom());
    try testing.expectError(error.InvalidAtomName, root.fields[1].value);
    try testing.expectEqual(@as(i64, 3), try (try root.fields[2].value).asInt());

    var empty = try parseRootStruct(testing.allocator, ".{}", &context.atoms);
    defer empty.deinit();
    try testing.expectEqual(@as(usize, 0), empty.fields.len);
    try testing.expectError(error.UnexpectedToken, parseRootStruct(testing.allocator, ".{ 1, 2 }", &context.atoms));
    try testing.expectError(error.InvalidZon, parseRootStruct(testing.allocator, ".{", &context.atoms));
}

test "root fields are added and removed, the rest of the text kept" {
    const allocator = testing.allocator;
    const empty = try appendRootStructField(allocator, ".{}\n", "keymap", ".emacs");
    defer allocator.free(empty);
    try testing.expectEqualStrings(".{\n    .keymap = .emacs,\n}\n", empty);

    const source =
        \\// Settings.
        \\.{
        \\    // The keys.
        \\    .keymap = .emacs, // or .cua
        \\    .size = 3
        \\}
        \\
    ;
    const added = try appendRootStructField(allocator, source, "a.b", "true");
    defer allocator.free(added);
    try testing.expectEqualStrings(
        \\// Settings.
        \\.{
        \\    // The keys.
        \\    .keymap = .emacs, // or .cua
        \\    .size = 3,
        \\    .@"a.b" = true,
        \\}
        \\
    , added);

    const removed = (try removeRootStructField(allocator, added, "keymap")).?;
    defer allocator.free(removed);
    try testing.expectEqualStrings(
        \\// Settings.
        \\.{
        \\    // The keys.
        \\    .size = 3,
        \\    .@"a.b" = true,
        \\}
        \\
    , removed);

    const inline_removed = (try removeRootStructField(allocator, ".{ .a = 1, .b = 2 }", "a")).?;
    defer allocator.free(inline_removed);
    try testing.expectEqualStrings(".{  .b = 2 }", inline_removed);
    try testing.expectEqual(@as(?[]u8, null), try removeRootStructField(allocator, ".{ .a = 1 }", "missing"));
    try testing.expectError(error.UnexpectedToken, appendRootStructField(allocator, "5", "a", "1"));
}
