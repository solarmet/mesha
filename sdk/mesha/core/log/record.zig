//! How a log record is encoded where it is logged: a subset of MessagePack, written into a
//! fixed buffer on the logging thread's stack, with no allocation.
//!
//! A record is an array of six: the thread's id, the monotonic time in nanoseconds, the
//! level, the scope's tag, the key, and the value. A value is encoded from its Zig type
//! (`Encoder.writeValue`): a struct as a map of its field names, a byte slice as a string,
//! an atom as its name. A record whose tag is 0 and key is `cmd` is metadata: it names a
//! scope, a thread or a zone, or anchors the clock (`MetadataCommand`), and is not printed.
//! `decoder.zig` reads records back.
const std = @import("std");
const Atom = @import("../atom.zig").Atom;

const fmt_nil: u8 = 0xc0;
const fmt_false: u8 = 0xc2;
const fmt_true: u8 = 0xc3;
const fmt_float32: u8 = 0xca;
const fmt_float64: u8 = 0xcb;
const fmt_uint8: u8 = 0xcc;
const fmt_uint16: u8 = 0xcd;
const fmt_uint32: u8 = 0xce;
const fmt_uint64: u8 = 0xcf;
const fmt_int8: u8 = 0xd0;
const fmt_int16: u8 = 0xd1;
const fmt_int32: u8 = 0xd2;
const fmt_int64: u8 = 0xd3;
const fmt_str8: u8 = 0xd9;
const fmt_str16: u8 = 0xda;
const fmt_arr16: u8 = 0xdc;
const fmt_map16: u8 = 0xde;

/// The most bytes an encoded record may take. The log panics on a larger one, naming it.
pub const max_record_bytes = 4096;

/// A record being encoded. Each write appends; one that would pass `max_record_bytes`, or a
/// string or container too long for the encoding, sets `overflow` and writes nothing more
/// of itself, so check `overflow` once at the end. A plain value: 4 KiB, made on the stack.
pub const Encoder = struct {
    /// The encoded bytes; only the first `pos` are meaningful.
    buf: [max_record_bytes]u8 = undefined,
    /// How many bytes are written.
    pos: usize = 0,
    /// Whether a write did not fit: the record is not to be used.
    overflow: bool = false,
    /// The interner an `Atom` value's name is read from, or null to write atoms as numbers.
    /// Read only with `lookupShared`, which is sound from any thread.
    atoms: ?*Atom.Registry = null,

    /// The bytes encoded so far, a slice of this encoder: valid while it is not moved.
    pub fn slice(self: *const Encoder) []const u8 {
        return self.buf[0..self.pos];
    }

    fn reserve(self: *Encoder, n: usize) ?[]u8 {
        if (self.pos + n > max_record_bytes) {
            self.overflow = true;
            return null;
        }
        const s = self.buf[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }

    fn writeByte(self: *Encoder, b: u8) void {
        if (self.reserve(1)) |s| s[0] = b;
    }

    fn writeU16Be(self: *Encoder, v: u16) void {
        if (self.reserve(2)) |s| std.mem.writeInt(u16, s[0..2], v, .big);
    }

    fn writeU32Be(self: *Encoder, v: u32) void {
        if (self.reserve(4)) |s| std.mem.writeInt(u32, s[0..4], v, .big);
    }

    fn writeU64Be(self: *Encoder, v: u64) void {
        if (self.reserve(8)) |s| std.mem.writeInt(u64, s[0..8], v, .big);
    }

    /// Writes nil.
    pub fn writeNil(self: *Encoder) void {
        self.writeByte(fmt_nil);
    }

    /// Writes a boolean.
    pub fn writeBool(self: *Encoder, v: bool) void {
        self.writeByte(if (v) fmt_true else fmt_false);
    }

    /// Writes an unsigned integer in the shortest form that holds it, one to nine bytes.
    pub fn writeUint(self: *Encoder, v: u64) void {
        if (v <= 0x7f) {
            self.writeByte(@intCast(v));
        } else if (v <= 0xff) {
            self.writeByte(fmt_uint8);
            self.writeByte(@intCast(v));
        } else if (v <= 0xffff) {
            self.writeByte(fmt_uint16);
            self.writeU16Be(@intCast(v));
        } else if (v <= 0xffff_ffff) {
            self.writeByte(fmt_uint32);
            self.writeU32Be(@intCast(v));
        } else {
            self.writeByte(fmt_uint64);
            self.writeU64Be(v);
        }
    }

    /// Writes a signed integer in the shortest form that holds it; one that is not negative is
    /// written as `writeUint` writes it.
    pub fn writeInt(self: *Encoder, v: i64) void {
        if (v >= 0) {
            self.writeUint(@intCast(v));
            return;
        }
        if (v >= -32) {
            self.writeByte(@bitCast(@as(i8, @intCast(v))));
        } else if (v >= std.math.minInt(i8)) {
            self.writeByte(fmt_int8);
            self.writeByte(@bitCast(@as(i8, @intCast(v))));
        } else if (v >= std.math.minInt(i16)) {
            self.writeByte(fmt_int16);
            self.writeU16Be(@bitCast(@as(i16, @intCast(v))));
        } else if (v >= std.math.minInt(i32)) {
            self.writeByte(fmt_int32);
            self.writeU32Be(@bitCast(@as(i32, @intCast(v))));
        } else {
            self.writeByte(fmt_int64);
            self.writeU64Be(@bitCast(v));
        }
    }

    /// Writes a 32-bit float.
    pub fn writeFloat32(self: *Encoder, v: f32) void {
        self.writeByte(fmt_float32);
        self.writeU32Be(@bitCast(v));
    }

    /// Writes a 64-bit float.
    pub fn writeFloat64(self: *Encoder, v: f64) void {
        self.writeByte(fmt_float64);
        self.writeU64Be(@bitCast(v));
    }

    /// Writes `s` as a string, copying its bytes; they are not checked to be UTF-8. A string of
    /// 64 KiB or more overflows.
    pub fn writeStr(self: *Encoder, s: []const u8) void {
        const len = s.len;
        if (len <= 31) {
            self.writeByte(0xa0 | @as(u8, @intCast(len)));
        } else if (len <= 0xff) {
            self.writeByte(fmt_str8);
            self.writeByte(@intCast(len));
        } else if (len <= 0xffff) {
            self.writeByte(fmt_str16);
            self.writeU16Be(@intCast(len));
        } else {
            self.overflow = true;
            return;
        }
        if (self.reserve(len)) |dst| @memcpy(dst, s);
    }

    /// Begins an array of `count` items, which the caller writes next. More than 65535
    /// overflows.
    pub fn writeArrayHeader(self: *Encoder, count: u32) void {
        if (count <= 15) {
            self.writeByte(0x90 | @as(u8, @intCast(count)));
        } else if (count <= 0xffff) {
            self.writeByte(fmt_arr16);
            self.writeU16Be(@intCast(count));
        } else {
            self.overflow = true;
        }
    }

    /// Begins a map of `count` entries; the caller writes each key, then its value. More than
    /// 65535 overflows.
    pub fn writeMapHeader(self: *Encoder, count: u32) void {
        if (count <= 15) {
            self.writeByte(0x80 | @as(u8, @intCast(count)));
        } else if (count <= 0xffff) {
            self.writeByte(fmt_map16);
            self.writeU16Be(@intCast(count));
        } else {
            self.overflow = true;
        }
    }

    /// Writes any supported value by its type: `void` and `null` as nil; booleans, integers and
    /// floats as themselves (a float of 32 bits or fewer as `f32`, a wider one as `f64`); an
    /// `Atom` as its name when `atoms` holds it; any other enum, and an atom with no name, as
    /// its integer; an optional as its payload or nil; a `[]const u8` or byte array as a string;
    /// another slice, array or vector as an array; a pointer to one value as that value; a
    /// struct as a map of field name to value, in declaration order. A many-item or C pointer is
    /// written as nil. Unions, error sets and other types are a compile error.
    pub fn writeValue(self: *Encoder, value: anytype) void {
        const T = @TypeOf(value);
        const info = @typeInfo(T);
        switch (info) {
            .void, .null => self.writeNil(),
            .bool => self.writeBool(value),
            .int => |i| {
                if (i.signedness == .unsigned) {
                    self.writeUint(@intCast(value));
                } else {
                    self.writeInt(@intCast(value));
                }
            },
            .float => |f| {
                if (f.bits <= 32) {
                    self.writeFloat32(@floatCast(value));
                } else {
                    self.writeFloat64(@floatCast(value));
                }
            },
            .@"enum" => {
                if (T == Atom) {
                    if (self.atoms) |atoms| {
                        if (atoms.lookupShared(value)) |name| {
                            self.writeStr(name);
                            return;
                        }
                    }
                }
                const id = @intFromEnum(value);
                self.writeUint(id);
            },
            .optional => {
                if (value) |v| self.writeValue(v) else self.writeNil();
            },
            .pointer => |p| {
                switch (p.size) {
                    .one => self.writeValue(value.*),
                    .slice => {
                        if (p.child == u8) {
                            self.writeStr(value);
                        } else {
                            self.writeArrayHeader(@intCast(value.len));
                            for (value) |elem| self.writeValue(elem);
                        }
                    },
                    .many, .c => self.writeNil(),
                }
            },
            .array => |a| {
                if (a.child == u8) {
                    self.writeStr(&value);
                } else {
                    self.writeArrayHeader(a.len);
                    for (value) |elem| self.writeValue(elem);
                }
            },
            .vector => |v| {
                self.writeArrayHeader(v.len);
                inline for (0..v.len) |i| self.writeValue(value[i]);
            },
            .@"struct" => |s| {
                self.writeMapHeader(s.fields.len);
                inline for (s.fields) |field| {
                    self.writeStr(field.name);
                    self.writeValue(@field(value, field.name));
                }
            },
            else => @compileError("writeValue: unsupported type " ++ @typeName(T)),
        }
    }
};

/// What a metadata record says, as the `cmd` field of its value names it: `tag_name` gives a
/// scope tag (`id`) its `name`; `thread_name` gives a thread (`id`) and its `lane` a `name`;
/// `clock_anchor` pairs a monotonic time with the wall clock (`monotonic_ns`,
/// `wall_clock_ns`, since the Unix epoch); `zone_name` gives a zone's name hash (`id`) in a
/// `scope` its `name`.
pub const MetadataCommand = enum { tag_name, thread_name, clock_anchor, zone_name };

/// The command a metadata record's `cmd` text names, or null for text that names none. A
/// leading `:` or `.` is ignored, and `tag-name` and `thread-name` are read as `tag_name`
/// and `thread_name`.
pub fn metadataCommand(value: []const u8) ?MetadataCommand {
    const name = if (value.len > 0 and (value[0] == ':' or value[0] == '.')) value[1..] else value;
    if (std.mem.eql(u8, name, "tag_name") or std.mem.eql(u8, name, "tag-name")) return .tag_name;
    if (std.mem.eql(u8, name, "thread_name") or std.mem.eql(u8, name, "thread-name")) return .thread_name;
    if (std.mem.eql(u8, name, "clock_anchor")) return .clock_anchor;
    if (std.mem.eql(u8, name, "zone_name")) return .zone_name;
    return null;
}

/// Encodes one record with no interner, so atoms are written as numbers: `thread` is the
/// logging thread's id, `timestamp` monotonic nanoseconds, `level` a `log.Level` integer and
/// `tag` the scope's tag. Pure: it touches no log state. Check the result's `overflow`.
pub fn encode(thread: u64, timestamp: u64, level: u8, tag: u32, key: []const u8, value: anytype) Encoder {
    return encodeWithAtoms(null, thread, timestamp, level, tag, key, value);
}

/// Encodes one record as `encode` does, writing each `Atom` in `value` as its name where
/// `atoms` holds one. Names are looked up here, on the logging thread, and copied into the
/// record; the result keeps no pointer to `atoms`, `key` or `value`.
pub fn encodeWithAtoms(atoms: ?*Atom.Registry, thread: u64, timestamp: u64, level: u8, tag: u32, key: []const u8, value: anytype) Encoder {
    var enc: Encoder = .{ .atoms = atoms };
    enc.writeArrayHeader(6);
    enc.writeUint(thread);
    enc.writeUint(timestamp);
    enc.writeUint(level);
    enc.writeUint(tag);
    enc.writeStr(key);
    enc.writeValue(value);
    enc.atoms = null;
    return enc;
}
