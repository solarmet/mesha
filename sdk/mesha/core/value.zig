//! The dynamic value model: what a ZON document is once read, before code that knows its shape
//! takes it apart.
//!
//! A `Value` is a tagged union of the scalars, strings, atoms, vectors and maps a document may
//! hold. `zon.parse` builds one in an arena (`ParseResult`), `zon.serializeValue` writes one,
//! and a reader walks it with the `as*` accessors, each of which fails with
//! `error.UnexpectedToken` on a value of another kind. A `Value` owns nothing: its slices and
//! maps belong to whoever built it.
const std = @import("std");

/// The engine's atom type.
pub const Atom = @import("atom.zig").Atom;

/// What an `as*` accessor fails with when the value is of another kind.
pub const ValueError = error{UnexpectedToken};

/// Every error reading a document into values, or writing values out, gives: the ZON reader's
/// and writer's (`zon.zig`) and those of code that walks the values.
pub const ParseError = ValueError || error{
    /// Structs or tuples nest to `zon.kMaxNestingDepth` or deeper.
    NestingTooDeep,
    /// The text is not ZON, or is too long to parse.
    InvalidZon,
    /// An atom's name is not lowercase snake_case (`zon.isSnakeCaseAtom`), or an enum literal is
    /// written escaped.
    InvalidAtomName,
    /// An atom to be written has no name in the registry.
    UnknownAtom,
    /// A struct names a field twice.
    DuplicateField,
    /// An integer does not fit an `i64`.
    IntegerOutOfRange,
    /// A map to be written has a key that is not an atom.
    InvalidMapKey,
    /// The allocator refused.
    OutOfMemory,
};

/// How `Map` hashes and compares its keys: by value, through `valueEql`.
pub const ValueContext = struct {
    /// A hash of `v`'s kind and contents. A map is hashed in its entries' order.
    pub fn hash(_: ValueContext, v: Value) u32 {
        var hasher = std.hash.Wyhash.init(0);
        hashValue(&hasher, v);
        return @truncate(hasher.final());
    }

    /// Whether `a` and `b` are equal by `valueEql`. The index parameter is unused.
    pub fn eql(_: ValueContext, a: Value, b: Value, _: usize) bool {
        return valueEql(a, b);
    }
};

fn hashValue(hasher: *std.hash.Wyhash, v: Value) void {
    const tag: u8 = @intFromEnum(v);
    hasher.update(&.{tag});
    switch (v) {
        .nil, .empty => {},
        .boolean => |b| hasher.update(&.{if (b) 1 else 0}),
        .integer => |n| hasher.update(std.mem.asBytes(&n)),
        .float => |f| hasher.update(std.mem.asBytes(&f)),
        .string => |s| hasher.update(s),
        .atom => |a| hasher.update(std.mem.asBytes(&a)),
        .character => |cp| hasher.update(std.mem.asBytes(&cp)),
        .vector => |items| for (items) |item| hashValue(hasher, item),
        .map => |m| {
            var it = m.iterator();
            while (it.next()) |entry| {
                hashValue(hasher, entry.key_ptr.*);
                hashValue(hasher, entry.value_ptr.*);
            }
        },
    }
}

/// Whether `a` and `b` are the same kind and hold equal contents: strings by bytes, vectors
/// item by item in order, maps entry by entry in any order. Kinds never convert: `integer` 1
/// is not `float` 1.0, and `empty` equals neither an empty vector nor an empty map. A `float`
/// NaN equals nothing, itself included.
pub fn valueEql(a: Value, b: Value) bool {
    if (@as(std.meta.Tag(Value), a) != @as(std.meta.Tag(Value), b)) return false;
    return switch (a) {
        .nil, .empty => true,
        .boolean => |av| av == b.boolean,
        .integer => |av| av == b.integer,
        .float => |av| av == b.float,
        .string => |av| std.mem.eql(u8, av, b.string),
        .atom => |av| av == b.atom,
        .character => |av| av == b.character,
        .vector => |av| sliceEql(av, b.vector),
        .map => |av| mapEql(av, b.map),
    };
}

fn sliceEql(a: []const Value, b: []const Value) bool {
    if (a.len != b.len) return false;
    for (a, b) |av, bv| if (!valueEql(av, bv)) return false;
    return true;
}

fn mapEql(a: Map, b: Map) bool {
    if (a.count() != b.count()) return false;
    var it = a.iterator();
    while (it.next()) |entry| {
        const bv = b.getKey(entry.key_ptr.*) orelse return false;
        if (!valueEql(bv, entry.key_ptr.*)) return false;

        const b_val = b.get(entry.key_ptr.*) orelse return false;
        if (!valueEql(entry.value_ptr.*, b_val)) return false;
    }
    return true;
}

/// A map from `Value` to `Value` that keeps its entries in the order they were put. A parsed
/// struct's keys are atoms. Unmanaged: its storage belongs to the allocator it was filled with.
pub const Map = std.ArrayHashMapUnmanaged(Value, Value, ValueContext, false);

/// The atom of `name` as a `Value`: the key to look a struct's field up by, as in
/// `map.get(value.atom("position"))`. Hashes the name and interns nothing.
pub fn atom(name: []const u8) Value {
    return .{ .atom = Atom.from(name) };
}

/// One value of a document. It owns nothing: `string`, `vector` and `map` point into memory
/// their maker owns, a `ParseResult`'s arena for a parsed value.
pub const Value = union(enum) {
    /// ZON's `null`.
    nil,
    /// ZON's `.{}`, which is an empty struct or an empty tuple until its reader says which:
    /// `asVector` and `asMap` both accept it.
    empty,
    /// `true` or `false`.
    boolean: bool,
    /// An integer literal.
    integer: i64,
    /// A float literal, `inf`, `-inf` or `nan`.
    float: f64,
    /// A string literal's bytes, escapes resolved. Not zero-terminated.
    string: []const u8,
    /// An enum literal (`.walk`): the atom of its name.
    atom: Atom,
    /// A character literal (`'a'`): its code point.
    character: u21,
    /// A tuple's items in order; never empty when parsed, since `.{}` parses as `empty`.
    vector: []Value,
    /// A struct's fields, keyed by their names' atoms.
    map: Map,

    /// Succeeds only for `nil`.
    pub fn asNil(self: Value) ValueError!void {
        if (self != .nil) return error.UnexpectedToken;
    }

    /// The `boolean`; any other kind fails.
    pub fn asBool(self: Value) ValueError!bool {
        if (self != .boolean) return error.UnexpectedToken;
        return self.boolean;
    }

    /// The `integer`; any other kind fails, a `float` included.
    pub fn asInt(self: Value) ValueError!i64 {
        if (self != .integer) return error.UnexpectedToken;
        return self.integer;
    }

    /// The `float`, or an `integer` converted to one; any other kind fails.
    pub fn asFloat(self: Value) ValueError!f64 {
        return switch (self) {
            .float => |f| f,
            .integer => |n| @floatFromInt(n),
            else => error.UnexpectedToken,
        };
    }

    /// The `string`'s bytes, which stay the value's owner's; any other kind fails.
    pub fn asString(self: Value) ValueError![]const u8 {
        if (self != .string) return error.UnexpectedToken;
        return self.string;
    }

    /// The `atom`; any other kind fails, a `string` included.
    pub fn asAtom(self: Value) ValueError!Atom {
        if (self != .atom) return error.UnexpectedToken;
        return self.atom;
    }

    /// The `vector`'s items, or none for `empty`; any other kind fails. The slice stays the
    /// value's owner's.
    pub fn asVector(self: Value) ValueError![]Value {
        if (self == .empty) return &.{};
        if (self != .vector) return error.UnexpectedToken;
        return self.vector;
    }

    /// The `map`, or an empty one for `empty`; any other kind fails. The copy shares the
    /// value's storage: read it, and do not put into it.
    pub fn asMap(self: Value) ValueError!Map {
        if (self == .empty) return .empty;
        if (self != .map) return error.UnexpectedToken;
        return self.map;
    }
};

/// A parsed `Value` and the arena that owns everything it points at.
pub const ParseResult = struct {
    /// Owns every string, vector and map of `value`.
    arena: std.heap.ArenaAllocator,
    /// The document's root.
    value: Value,

    /// Frees the value. Nothing read from it may be used after.
    pub fn deinit(self: *ParseResult) void {
        self.arena.deinit();
    }
};

test "value equality - scalars and atoms" {
    const testing = std.testing;

    try testing.expect(valueEql(.nil, .nil));
    try testing.expect(valueEql(.{ .boolean = true }, .{ .boolean = true }));
    try testing.expect(!valueEql(.{ .boolean = true }, .{ .boolean = false }));
    try testing.expect(valueEql(.{ .integer = 42 }, .{ .integer = 42 }));
    try testing.expect(!valueEql(.{ .integer = 1 }, .{ .integer = 2 }));
    try testing.expect(valueEql(.{ .float = 3.14 }, .{ .float = 3.14 }));
    try testing.expect(valueEql(.{ .string = "hello" }, .{ .string = "hello" }));
    try testing.expect(!valueEql(.{ .string = "hello" }, .{ .string = "world" }));
    try testing.expect(!valueEql(.nil, .{ .boolean = false }));
    try testing.expect(valueEql(.{ .character = 'a' }, .{ .character = 'a' }));
    try testing.expect(!valueEql(.{ .character = 'a' }, .{ .character = 'b' }));
    try testing.expect(valueEql(atom("foo"), atom("foo")));
    try testing.expect(!valueEql(atom("foo"), atom("bar")));
}

test "typed accessors" {
    const testing = std.testing;

    const v = Value{ .integer = 5 };
    try testing.expectEqual(@as(i64, 5), try v.asInt());
    try testing.expectError(error.UnexpectedToken, v.asBool());
    try testing.expectError(error.UnexpectedToken, v.asString());
}

test "value context hashing" {
    const testing = std.testing;
    const ctx = ValueContext{};

    const a = Value{ .integer = 42 };
    const b = Value{ .integer = 42 };
    const c = Value{ .integer = 43 };
    try testing.expectEqual(ctx.hash(a), ctx.hash(b));
    try testing.expect(ctx.hash(a) != ctx.hash(c));
    try testing.expectEqual(ctx.hash(atom("foo")), ctx.hash(atom("foo")));
}
