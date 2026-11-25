//! A table: rows of cells in typed columns, described by a `Schema`. Tables are the engine's state,
//! and this file is the `Table` type itself (`mesha.Table`): its fields are one table's, and its
//! declarations are everything about tables.
//!
//! - `Schema` lists a table's fields in order, each a `FieldDescriptor`: a name, a size, a durable
//!   type (`FieldType`) where it has one, and how an editor shows it (`ViewKind`).
//! - `Registry` (`Table.Registry`) owns every table and schema. Tables are made, found, grown,
//!   replaced and destroyed through it; each has a name, an atom, and is reached by `Handle` or by
//!   name. The host makes the one registry and hands plugins a pointer to it.
//! - `RowHandle` names a row by id and generation, `Mask` says which of its cells a row holds, and
//!   `Query` walks the rows that hold the cells a view names.
//! - `Payload`, `String` and `Bytes` are the cells of any length: an offset and length into the
//!   table's payload arena, never a pointer.
//! - `Ref` is a cell that refers to a row of some table by name.
//! - `Journal` is how a sequencer run's frame journal (`journal.zig`) stands between a table and
//!   the code that reads and writes it.
//! - `writeFile` and `readFile` save and load a table's rows as an `MSHT` file (`FileHeader`).
//!
//! The usual order of calls: build a `Schema` (`init`, `addField`), make a table from it
//! (`Registry.create`, `ensure`, `createSingleton`, or `registerSchema` once and `createNamed`),
//! which copies the schema, so the built one is then freed; add rows with `insert` or `tryInsert`;
//! read and write them through `query`, `getRow` and `getField`; drop them with `free` or `clear`;
//! and `Registry.destroy` the table.
//!
//! A view is a struct the caller declares, its fields named for the table's fields: `*T` is a
//! pointer to the cell, where `@sizeOf(T)` must be the field's size, and a const slice reads a
//! payload cell's bytes. A name the schema lacks or a `T` of the wrong size is a panic, not an
//! error. A cell may be absent: a row's mask says which it holds, a query yields only the rows
//! holding every cell its view names, and a cell written through a pointer is not thereby present.
//!
//! Storage is columnar, rows packed densely with a column per field, or for a singleton one row
//! inline. A row's id is logical, not its position: freeing a row moves the last row into its place
//! and changes no surviving handle, and the order rows are walked in is unspecified. Capacity grows
//! as rows are allocated and never shrinks, and `clear` keeps the pages. Pointers into cells,
//! views, iterators and slices read from payloads are short-lived: do not keep them across an
//! `alloc`, `free`, `clear`, sort or grow of the table; collect handles first
//! (`collectHandlesInto`) and look rows up again. Destroying a columnar table returns its pages; a
//! singleton in no memory scope keeps its cells in the registry's arena until the registry is torn
//! down.
//!
//! While a run journals a table (`journal` is set), the functions here that read and write rows go
//! through the journal, so a kernel sees its own run's changes and writes nothing in place. The
//! ones documented as raw storage (`rowCellBytes`, `rowAtPosition`, `reusableRows`,
//! `restoreRowState`, the `stored*` functions) reach the table's own storage whatever a journal
//! holds: they are for the journals and for host code outside runs, never for a journaled kernel.
//!
//! Nothing here locks: tables belong to the sim thread. The host and every plugin lay out `Table`
//! and its storage alike and share them, so after a change to these layouts both are rebuilt and
//! the host restarted.
const std = @import("std");
const contract = @import("contract.zig");
const Atom = @import("atom.zig").Atom;
const memory_mod = @import("memory.zig");
const zon = @import("zon.zig");
const math = @import("math.zig");
const Table = @This();

/// The storage under a table: a checked layout of offsets, the page arena a columnar table's chunks
/// come from, the payload arena, and the segmented arrays that grow without moving. Private to this
/// file.
const table_storage = struct {
    const Alignment = std.mem.Alignment;
    const Allocator = std.mem.Allocator;

    /// What reserving storage fails with: the backing has no pages left, or a size overflows.
    pub const Error = error{ OutOfMemory, Overflow };

    fn add(a: usize, b: usize) Error!usize {
        return std.math.add(usize, a, b) catch error.Overflow;
    }

    fn roundUp(value: usize, alignment: usize) Error!usize {
        std.debug.assert(std.math.isPowerOfTwo(alignment));
        return (try add(value, alignment - 1)) & ~(alignment - 1);
    }

    /// Checked offsets for one contiguous table bundle. Failed appends leave layout intact.
    pub const Layout = struct {
        /// Bytes laid out so far.
        size: usize = 0,
        /// The strictest alignment appended so far.
        alignment: Alignment = .@"1",

        /// Appends `byte_len` bytes at `alignment` and returns their offset.
        pub fn append(self: *Layout, byte_len: usize, alignment: Alignment) Error!usize {
            const offset = try roundUp(self.size, alignment.toByteUnits());
            const end = try add(offset, byte_len);
            self.* = .{ .size = end, .alignment = self.alignment.max(alignment) };
            return offset;
        }

        /// Appends `item_count` values of `T` and returns the offset of the first.
        pub fn appendArray(self: *Layout, comptime T: type, item_count: usize) Error!usize {
            const bytes = std.math.mul(usize, @sizeOf(T), item_count) catch return error.Overflow;
            return self.append(bytes, .of(T));
        }
    };

    const Page = struct { next: ?*Page = null, len: usize };
    /// Pages straight from a PageBacking, which code of either image calls.
    pub const Arena = struct {
        /// Where the pages come from and go back to.
        backing: *memory_mod.PageBacking,
        /// The newest allocation; each links to the one before it.
        first: ?*Page = null,
        /// Bytes taken from the backing, headers included.
        bytes: usize = 0,
        /// `bytes` in pages.
        pages: usize = 0,
        /// `size` bytes on pages of their own, at an address aligned to 16, not zeroed. They stay
        /// where they are until `deinit`.
        pub fn allocate(self: *Arena, size: usize) Error![]u8 {
            const offset = std.mem.alignForward(usize, @sizeOf(Page), 16);
            const len = try roundUp(try add(offset, size), std.heap.pageSize());
            const raw = self.backing.rawAlloc(len, .fromByteUnits(std.heap.pageSize()), @returnAddress()) orelse return error.OutOfMemory;
            const page: *Page = @ptrCast(@alignCast(raw));
            page.* = .{ .next = self.first, .len = len };
            self.first = page;
            self.bytes += len;
            self.pages += len / std.heap.pageSize();
            return raw[offset..len];
        }
        /// The bytes at the start of each allocation's pages that its header takes.
        pub fn headerBytes() usize {
            return std.mem.alignForward(usize, @sizeOf(Page), 16);
        }
        /// Returns every page to the backing.
        pub fn deinit(self: *Arena) void {
            var it = self.first;
            while (it) |page| {
                const next = page.next;
                self.backing.rawFree(@as([*]u8, @ptrCast(page))[0..page.len], .fromByteUnits(std.heap.pageSize()), @returnAddress());
                it = next;
            }
            self.first = null;
            self.bytes = 0;
            self.pages = 0;
        }
    };

    /// A table's payload bytes: append-only chunks that never move, addressed by an offset
    /// into their concatenation. A payload lies in one chunk, so its bytes are contiguous
    /// and stay where they are until `reset` or `deinit`.
    pub const Payloads = struct {
        /// Where the chunks' pages come from and go back to.
        backing: *memory_mod.PageBacking,
        /// The chunks, in offset order.
        first: ?*Chunk = null,
        /// The chunk appends go to.
        last: ?*Chunk = null,
        /// Mapped bytes, headers included.
        bytes: usize = 0,

        /// `start` is the offset of the chunk's first byte, a multiple of 16 as the bytes'
        /// address is, so an offset's alignment is its address's.
        const Chunk = struct { next: ?*Chunk = null, start: u32, used: u32, capacity: u32, mapped: usize };
        const header_bytes = std.mem.alignForward(usize, @sizeOf(Chunk), 16);
        const max_offset = std.math.maxInt(u32);

        fn chunkBytes(chunk: *Chunk) [*]u8 {
            return @as([*]u8, @ptrCast(chunk)) + header_bytes;
        }

        /// One past the last offset handed out.
        pub fn end(self: *const Payloads) u32 {
            const last = self.last orelse return 0;
            return last.start + last.used;
        }

        /// A copy of `bytes` at an offset aligned to `alignment`, at most 16. A failed append
        /// leaves the arena as it was.
        pub fn append(self: *Payloads, bytes: []const u8, alignment: Alignment) Error!Table.Payload {
            const payload = try self.allocate(bytes.len, alignment);
            @memcpy(self.bytesOf(payload), bytes);
            return payload;
        }

        /// `size` bytes at an offset aligned to `alignment`, at most 16, for the caller to
        /// fill. A failed allocation leaves the arena as it was.
        pub fn allocate(self: *Payloads, size: usize, alignment: Alignment) Error!Table.Payload {
            if (size == 0) return .{};
            std.debug.assert(alignment.toByteUnits() <= 16);
            if (size > max_offset) return error.Overflow;
            if (self.last) |last| {
                const position = std.mem.alignForward(usize, last.used, alignment.toByteUnits());
                if (position <= last.capacity and size <= last.capacity - position) {
                    last.used = @intCast(position + size);
                    return .{ .offset = @intCast(last.start + position), .len = @intCast(size) };
                }
            }
            const chunk = try self.grow(size);
            chunk.used = @intCast(size);
            return .{ .offset = chunk.start, .len = @intCast(size) };
        }

        /// The payload naming `bytes` when they lie in the arena, as bytes a payload was
        /// resolved to do; null for bytes from anywhere else.
        pub fn find(self: *const Payloads, bytes: []const u8) ?Table.Payload {
            if (bytes.len == 0) return .{};
            const address = @intFromPtr(bytes.ptr);
            var it = self.first;
            while (it) |chunk| : (it = chunk.next) {
                const base = @intFromPtr(chunkBytes(chunk));
                if (address < base or address - base >= chunk.used) continue;
                const position = address - base;
                if (bytes.len > chunk.used - position) return null;
                return .{ .offset = @intCast(chunk.start + position), .len = @intCast(bytes.len) };
            }
            return null;
        }

        /// Room for `size` more bytes in the last chunk, so appends that fit it cannot fail.
        pub fn reserve(self: *Payloads, size: usize) Error!void {
            if (size == 0) return;
            if (self.last) |last| {
                if (size <= last.capacity - last.used) return;
            }
            _ = try self.grow(size);
        }

        /// A new last chunk, empty, holding at least `size` bytes.
        fn grow(self: *Payloads, size: usize) Error!*Chunk {
            const start = try roundUp(self.end(), 16);
            // Each chunk holds the request and half of what is there, so lookups walk few.
            const wanted = @max(size, start / 2);
            const mapped = try roundUp(try add(header_bytes, wanted), std.heap.pageSize());
            const capacity = mapped - header_bytes;
            if (start > max_offset or capacity > max_offset - start) return error.Overflow;
            const raw = self.backing.rawAlloc(mapped, .fromByteUnits(std.heap.pageSize()), @returnAddress()) orelse return error.OutOfMemory;
            const chunk: *Chunk = @ptrCast(@alignCast(raw));
            chunk.* = .{ .start = @intCast(start), .used = 0, .capacity = @intCast(capacity), .mapped = mapped };
            if (self.last) |last| last.next = chunk else self.first = chunk;
            self.last = chunk;
            self.bytes += mapped;
            return chunk;
        }

        /// The payload's bytes. Its range must be one `append` returned since the last reset.
        pub fn bytesOf(self: *const Payloads, payload: Table.Payload) []u8 {
            if (payload.len == 0) return &.{};
            var found = self.last.?;
            if (payload.offset < found.start) {
                found = self.first.?;
                while (payload.offset >= found.start + found.used) found = found.next.?;
            }
            const position = payload.offset - found.start;
            std.debug.assert(position <= found.used and payload.len <= found.used - position);
            return chunkBytes(found)[position..][0..payload.len];
        }

        /// Whether `payload` names a range `append` could have returned.
        pub fn holds(self: *const Payloads, payload: Table.Payload) bool {
            if (payload.len == 0) return true;
            var it = self.first;
            while (it) |chunk| : (it = chunk.next) {
                if (payload.offset < chunk.start) return false;
                const position = payload.offset - chunk.start;
                if (position < chunk.used) return payload.len <= chunk.used - position;
            }
            return false;
        }

        /// Forgets every payload, keeping the largest chunk, the last, for the next ones.
        pub fn reset(self: *Payloads) void {
            const last = self.last orelse return;
            var it = self.first;
            while (it) |chunk| {
                if (chunk == last) break;
                it = chunk.next;
                self.release(chunk);
            }
            last.start = 0;
            last.used = 0;
            self.first = last;
        }

        /// Returns every chunk to the backing.
        pub fn deinit(self: *Payloads) void {
            var it = self.first;
            while (it) |chunk| {
                it = chunk.next;
                self.release(chunk);
            }
            self.first = null;
            self.last = null;
        }

        fn release(self: *Payloads, chunk: *Chunk) void {
            self.bytes -= chunk.mapped;
            self.backing.rawFree(@as([*]u8, @ptrCast(chunk))[0..chunk.mapped], .fromByteUnits(std.heap.pageSize()), @returnAddress());
        }
    };

    /// An array kept as a list of segments that never move: it grows by a segment, so pointers into
    /// earlier ones stay good. The segments and their values lie in the table's arena pages. The
    /// array is three plain values and no segment points back at it, so a copy of it reads the same
    /// values.
    pub fn Array(comptime T: type) type {
        return struct {
            const Self = @This();
            /// A run of values and its neighbours in the list.
            pub const Segment = struct { next: ?*Segment = null, prev: ?*Segment = null, values: []T };
            /// The segment holding index 0.
            first: ?*Segment = null,
            /// The segment added last.
            last: ?*Segment = null,
            /// Values in all segments together.
            len: usize = 0,
            /// Adds `segment`'s values at the end.
            pub fn append(self: *Self, segment: *Segment) void {
                segment.prev = self.last;
                if (self.last) |last| last.next = segment else self.first = segment;
                self.last = segment;
                self.len += segment.values.len;
            }
            /// A place in the array, for walking it without searching from the first segment at
            /// every step.
            pub const Cursor = struct {
                /// The segment the cursor is in.
                segment: *Segment,
                /// The value's index within `segment`.
                offset: usize,
                /// The value at the cursor.
                pub fn pointer(self: Cursor) *T {
                    return &self.segment.values[self.offset];
                }
                /// Steps to the next value. After the array's last value the cursor names nothing
                /// and must not be read.
                pub fn next(self: *Cursor) void {
                    self.offset += 1;
                    if (self.offset == self.segment.values.len) {
                        if (self.segment.next) |segment| {
                            self.segment = segment;
                            self.offset = 0;
                        }
                    }
                }
                /// Steps to the value before. The cursor must not be at the array's first value.
                pub fn previous(self: *Cursor) void {
                    if (self.offset == 0) {
                        self.segment = self.segment.prev.?;
                        self.offset = self.segment.values.len;
                    }
                    self.offset -= 1;
                }
            };
            /// A cursor at `index`, which must be below `len`.
            pub fn cursor(self: Self, index: usize) Cursor {
                var offset = index;
                var segment = self.first.?;
                while (offset >= segment.values.len) {
                    offset -= segment.values.len;
                    segment = segment.next.?;
                }
                return .{ .segment = segment, .offset = offset };
            }
            /// Copies `item_count` values from `source` to `destination`, the last first, so the
            /// two ranges may overlap when `destination` is the higher.
            pub fn copyBackwards(self: Self, destination: usize, source: usize, item_count: usize) void {
                if (item_count == 0) return;
                var dst = self.cursor(destination + item_count - 1);
                var src = self.cursor(source + item_count - 1);
                for (0..item_count) |i| {
                    dst.pointer().* = src.pointer().*;
                    if (i + 1 < item_count) {
                        dst.previous();
                        src.previous();
                    }
                }
            }
            /// The value at `index`, which must be below `len`.
            pub fn at(self: Self, index: usize) *T {
                return &self.sliceAt(index, 1)[0];
            }
            /// `item_count` values from `index`. They must lie in one segment.
            pub fn sliceAt(self: Self, index: usize, item_count: usize) []T {
                if (self.last) |last| {
                    const start = self.len - last.values.len;
                    if (index >= start and item_count <= last.values.len - (index - start)) return last.values[index - start ..][0..item_count];
                }
                var offset = index;
                var it = self.first;
                while (it) |segment| : (it = segment.next) {
                    if (offset < segment.values.len or (item_count == 0 and offset == 0)) return segment.values[offset..][0..item_count];
                    offset -= segment.values.len;
                }
                unreachable;
            }
        };
    }
    /// Bytes and pages reserved from a backing.
    pub const Stats = struct { reserved_bytes: usize = 0, reserved_pages: usize = 0 };
};

/// A table file's first four bytes.
pub const file_magic: [4]u8 = "MSHT".*;
/// The table file format's version. `fileHeader` refuses a file of any other.
pub const file_version: u32 = 3;

/// A table file's first bytes. The file is one table: a header, then sections that each
/// start on an 8-byte boundary, in this order:
///
///   masks     `row_count` × `mask_words` × u64, a row's presence words together
///   columns   for each field in schema order, `row_count` × stride bytes; absent cells zero
///   metadata  `metadata_count` entries, each `key_len: u32`, `value_len: u32`, key, value
///   names     `names_count` entries, each `len: u32`, text: the name of every atom the rows'
///             atom and ref cells hold, which loading interns, as a cell holds only its hash
///   payload   `payload_bytes`: what the string and opaque cells name, by offset into it
///
/// Rows are in the order they were saved, which is the order they are loaded in; their ids
/// and generations are not kept. The schema is not in the file, only its hash: a file loads
/// into a table whose schema hashes the same and into no other.
pub const FileHeader = extern struct {
    /// `file_magic`.
    magic: [4]u8 = file_magic,
    /// `file_version`.
    version: u32 = file_version,
    /// `fileSchemaHash` of the schema the rows were saved with.
    schema_hash: u32,
    /// Rows in the file.
    row_count: u32,
    /// Words in each row's mask: the schema's `maskWords`.
    mask_words: u32,
    /// Fields in the schema: the columns section holds one column for each.
    field_count: u32,
    /// Entries in the metadata section.
    metadata_count: u32,
    /// Bytes of the metadata section, without its padding.
    metadata_bytes: u32,
    /// Entries in the names section.
    names_count: u32,
    /// Bytes of the names section, without its padding.
    names_bytes: u32,
    /// Bytes of the payload section.
    payload_bytes: u64,
    /// Of every byte after the header.
    crc32: u32,
    /// Zero. `fileHeader` refuses anything else.
    reserved: u32 = 0,

    comptime {
        // No padding, so a file's bytes are deterministic.
        std.debug.assert(@sizeOf(FileHeader) == 56);
    }
};

/// A key and value saved with a table, as its document's notes: not a row of it.
pub const FileMetadata = struct { key: []const u8, value: []const u8 };

/// A payload cell: a range of the table's payload arena, by its offset there. The bytes are
/// never moved or changed while the table lives; they are dropped when the table is cleared
/// and renumbered when it is compacted (`compactPayloads`). An offset means the same in the
/// table and in a journal layer's copy of its rows, which shares the table's arena.
pub const Payload = extern struct { offset: u32 = 0, len: u32 = 0 };

/// A string cell (`FieldType.string`): text of any length, in the payload arena.
pub const String = extern struct { payload: Payload = .{} };

/// An opaque cell (`FieldType.bytes`): bytes in the payload arena, aligned to 16 so a value
/// or a slice of values of any type is read where it lies.
pub const Bytes = extern struct { payload: Payload = .{} };

/// The alignment of a `Bytes` cell's payload: 16.
pub const bytes_alignment: std.mem.Alignment = .@"16";

/// Which fields a row holds: bit `FieldDescriptor.bit` is set when that field is
/// present. A table stores `Schema.maskWords()` words per row; the words past that
/// are always zero, so masks from one table compare and combine as whole values.
pub const Mask = struct {
    /// The most mask words a row stores.
    pub const max_words = 4;
    /// The most fields a schema may have: 256.
    pub const max_bits = max_words * 64;

    /// Bit `b` is bit `b % 64` of word `b / 64`.
    words: [max_words]u64 = @splat(0),

    /// The mask of a row that holds no field.
    pub const empty: Mask = .{};

    /// The mask with only `bit` set.
    pub fn fromBit(bit: u8) Mask {
        var result: Mask = .{};
        result.set(bit);
        return result;
    }

    /// Bits `0..bit_count`, the mask of a row holding every field of a `bit_count`-field schema.
    pub fn firstBits(bit_count: usize) Mask {
        std.debug.assert(bit_count <= max_bits);
        var result: Mask = .{};
        var remaining = bit_count;
        for (&result.words) |*word| {
            if (remaining == 0) break;
            const taken = @min(remaining, 64);
            word.* = if (taken == 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(taken)) - 1;
            remaining -= taken;
        }
        return result;
    }

    /// Whether `bit` is set.
    pub fn has(mask: Mask, bit: u8) bool {
        return mask.words[bit / 64] & wordBit(bit) != 0;
    }

    /// Sets `bit`, in place.
    pub fn set(mask: *Mask, bit: u8) void {
        mask.words[bit / 64] |= wordBit(bit);
    }

    /// Clears `bit`, in place.
    pub fn unset(mask: *Mask, bit: u8) void {
        mask.words[bit / 64] &= ~wordBit(bit);
    }

    /// Sets `bit` when `present`, clears it otherwise, in place.
    pub fn setTo(mask: *Mask, bit: u8, present: bool) void {
        if (present) mask.set(bit) else mask.unset(bit);
    }

    /// A copy with `bit` set.
    pub fn with(mask: Mask, bit: u8) Mask {
        var result = mask;
        result.set(bit);
        return result;
    }

    /// A copy with `bit` cleared.
    pub fn without(mask: Mask, bit: u8) Mask {
        var result = mask;
        result.unset(bit);
        return result;
    }

    /// The union: every bit set in either mask.
    pub fn merge(mask: Mask, other: Mask) Mask {
        var result = mask;
        for (&result.words, other.words) |*word, other_word| word.* |= other_word;
        return result;
    }

    /// The bits of `mask` that `other` does not have.
    pub fn remove(mask: Mask, other: Mask) Mask {
        var result = mask;
        for (&result.words, other.words) |*word, other_word| word.* &= ~other_word;
        return result;
    }

    /// Whether `mask` has every bit of `required`.
    pub fn containsAll(mask: Mask, required: Mask) bool {
        for (mask.words, required.words) |word, required_word| {
            if (word & required_word != required_word) return false;
        }
        return true;
    }

    /// Whether any bit is set in both masks.
    pub fn intersects(mask: Mask, other: Mask) bool {
        for (mask.words, other.words) |word, other_word| {
            if (word & other_word != 0) return true;
        }
        return false;
    }

    /// Whether no bit is set.
    pub fn isEmpty(mask: Mask) bool {
        for (mask.words) |word| {
            if (word != 0) return false;
        }
        return true;
    }

    /// Whether the two masks have the same bits.
    pub fn eql(mask: Mask, other: Mask) bool {
        return std.mem.eql(u64, &mask.words, &other.words);
    }

    fn wordBit(bit: u8) u64 {
        return @as(u64, 1) << @intCast(bit % 64);
    }
};

/// A `ref` cell: a reference from one row to a row of some table. The names are its
/// identity and the only part saved: the target table's name, and the target row's
/// `name` atom. The handles are a cache, checked against those names on every use,
/// so a reload or a replaced table finds the row again by name instead of reading
/// whatever took its slot. A ref to a row without a `name` holds only handles: it
/// resolves while they stay valid and cannot be saved.
pub const Ref = extern struct {
    /// The target table's name (`Table.name`), or `no_name` in a ref to nothing.
    table_name: Atom = no_name,
    /// `no_name` for a ref to a row that has no `name` field or no value in it.
    row_name: Atom = no_name,
    /// Cache: the target table's handle when the ref was made or last resolved.
    table: Handle = .{ .index = 0, .generation = 0 },
    /// Cache: the target row's id.
    row: u32 = 0,
    /// Cache: the target row's generation.
    row_generation: u32 = 0,

    /// The null atom: the name a ref has where it has none.
    pub const no_name: Atom = @enumFromInt(0);
    /// Refers to nothing; never resolves.
    pub const none: Ref = .{};

    /// Whether the ref refers to nothing.
    pub fn isNone(ref: Ref) bool {
        return ref.table_name == no_name;
    }

    /// Only a ref whose row has a name survives a save and a reload.
    pub fn isPersistable(ref: Ref) bool {
        return ref.table_name != no_name and ref.row_name != no_name;
    }
};

/// A ref as editors show and accept it: `table/row_name`, `<none>`, or, for a nameless target,
/// `table/<row N>`, which can be shown but not typed back. A name `atoms_arg` does not know prints
/// as `<unknown table>` or `<unknown row>`. The text is written into `buf` and the result is a
/// slice of it, empty when `buf` is too small.
pub fn formatRef(ref: Ref, atoms_arg: *const Atom.Registry, buf: []u8) []const u8 {
    if (ref.isNone()) return std.fmt.bufPrint(buf, "<none>", .{}) catch buf[0..0];
    const table_text = atoms_arg.lookup(ref.table_name) orelse "<unknown table>";
    if (ref.row_name == Ref.no_name) return std.fmt.bufPrint(buf, "{s}/<row {d}>", .{ table_text, ref.row }) catch buf[0..0];
    const row_text = atoms_arg.lookup(ref.row_name) orelse "<unknown row>";
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ table_text, row_text }) catch buf[0..0];
}

/// Reads `table/row_name` or `<none>`, ignoring spaces around it, and interns both names in
/// `atoms_arg`. The handles are left empty for `Registry.resolveRef` to find; the names are not
/// checked against any table. `error.InvalidRef` for text with no `/`, an empty part, a second `/`,
/// or a row part that begins with `<`.
pub fn parseRef(text: []const u8, atoms_arg: *Atom.Registry) error{InvalidRef}!Ref {
    const trimmed = std.mem.trim(u8, text, " ");
    if (std.mem.eql(u8, trimmed, "<none>")) return .none;
    const slash = std.mem.indexOfScalar(u8, trimmed, '/') orelse return error.InvalidRef;
    const table_text = trimmed[0..slash];
    const row_text = trimmed[slash + 1 ..];
    if (table_text.len == 0 or row_text.len == 0 or std.mem.indexOfScalar(u8, row_text, '/') != null) return error.InvalidRef;
    if (row_text[0] == '<') return error.InvalidRef;
    return .{ .table_name = atoms_arg.intern(table_text), .row_name = atoms_arg.intern(row_text) };
}

/// The row a `Ref` names, and the ref with its cache pointing at that row.
pub const ResolvedRef = struct {
    /// The table the row is in.
    table: *Table,
    /// The row.
    handle: Table.RowHandle,
    /// Equal to the input when its cache was already current. A caller that owns
    /// the cell may store it so the next resolution skips the search by name.
    ref: Ref,
};

/// The CRC-32 a table file's header carries of the bytes after it.
pub fn crc32(data: []const u8) u32 {
    return std.hash.Crc32.hash(data);
}

/// A sequencer run's frame journal, as the tables it covers see it: a row of a covered table is
/// read and written through the journal, never in the table, until the journal is flushed.
/// The journal itself (`core/journal.zig`) attaches to tables and reaches their own storage
/// with `journal` set aside. Raw storage accessors (`rowCellBytes`, `rowAtPosition`,
/// `reusableRows`, `restoreRowState`) are not journaled.
pub const Journal = struct {
    /// The journal's own state, passed back to every `vtable` call.
    context: *anyopaque,
    /// The journal's operations.
    vtable: *const VTable,

    /// Where a row's values are: in the table itself, or in a journal's overlay table.
    pub const Place = struct { table: *Table, row: u32 };

    /// What a journal does for a table it covers. `Table`'s functions call these while
    /// `Table.journal` is set; other code calls those functions, not these.
    pub const VTable = struct {
        /// The row's values as the run sees them, without copying; null when gone.
        read: *const fn (context: *anyopaque, table: *Table, handle: Table.RowHandle) ?Place,
        /// The run's own copy of the row, made on its first access; null when gone.
        access: *const fn (context: *anyopaque, table: *Table, handle: Table.RowHandle) ?Place,
        /// The generation of the row id as the run sees it; null when not live.
        generation: *const fn (context: *anyopaque, table: *Table, row: u32) ?u32,
        /// A new row of the run's, with no cell present. Fails with `error.ReadOnlyTable` on a
        /// table the run attached only to read, or when there is no memory for it.
        insert: *const fn (context: *anyopaque, table: *Table) anyerror!Table.RowHandle,
        /// Removes a row for the run. A row already gone is left; any other failure is kept in the
        /// journal, which the run's owner reads, and not returned.
        remove: *const fn (context: *anyopaque, table: *Table, handle: Table.RowHandle) void,
        /// Removes every row the run sees. A failure is kept in the journal as `remove`'s is.
        clear: *const fn (context: *anyopaque, table: *Table) void,
        /// The rows the run sees.
        count: *const fn (context: *anyopaque, table: *Table) u32,
        /// Whether the run removed this live row of the table.
        removed: *const fn (context: *anyopaque, table: *Table, row: u32) bool,
        /// The run's `index`th inserted row id of the table, in insertion order, whether or not
        /// it was removed since; null past the last.
        inserted: *const fn (context: *anyopaque, table: *Table, index: usize) ?Table.RowHandle,
    };

    /// Where the row's values are for the run to read, copying nothing; null when the row is gone.
    pub fn read(journal: *const Journal, table: *Table, handle: Table.RowHandle) ?Place {
        return journal.vtable.read(journal.context, table, handle);
    }
    /// The run's own copy of the row, to write, made on its first access; null when the row is
    /// gone.
    pub fn access(journal: *const Journal, table: *Table, handle: Table.RowHandle) ?Place {
        return journal.vtable.access(journal.context, table, handle);
    }
    /// The generation of row id `row` as the run sees it; null when the id is not live for the run.
    pub fn generation(journal: *const Journal, table: *Table, row: u32) ?u32 {
        return journal.vtable.generation(journal.context, table, row);
    }
    /// The handle of row id `row` as the run sees it; null when the id is not live for the run.
    pub fn handleOf(journal: *const Journal, table: *Table, row: u32) ?Table.RowHandle {
        const live = journal.generation(table, row) orelse return null;
        return .{ .row = row, .generation = live };
    }
};

/// Who made a table: the registry's `scope` when the table was created, kept as `Table.owner`.
/// `host` is the host and its systems. `app` is a plugin: the plugin loader sets it around every
/// call into a plugin. `editor` is the editor plugin's own code, which sets it around the tables it
/// makes. A label for code that tells tables apart by maker; nothing in this file acts on it.
pub const Owner = enum { host, app, editor };

/// How long a table is meant to live and whether it is saved. `persistent` is a table document,
/// which the resources system loads from and saves to a table file; its schema may hold no pointer
/// and no opaque field that is not certified (`Schema.validatePersistentStorage`, checked when the
/// table is made). `durable` lives in memory until it is destroyed and is never saved. `transient`
/// holds short-lived working rows, and the editor's table windows do not offer it. The registry
/// counts the pages of each apart (`Registry.storageStats`).
pub const Lifetime = enum { persistent, durable, transient };

/// Options for `Schema.addFieldWithOptions` and `Schema.addFieldSizedWithOptions`.
pub const FieldOptions = struct {
    /// Certifies an otherwise opaque field as pointer-free. Typed pointer
    /// fields and pointer-containing aggregates are still rejected.
    persistent_safe: bool = false,
};

const dead_index = std.math.maxInt(u32);

const RowArray = table_storage.Array(u32);
/// A table's free row ids in the order they are reused: `alloc` takes the last. A view of the
/// table's storage, from `Table.reusableRows`.
pub const ReusableRows = struct {
    /// A columnar table's free list; only its first `len` values count.
    array: RowArray = .{},
    /// Set for a singleton, whose one id is 0.
    singleton: bool = false,
    /// How many ids are free.
    len: usize,
    /// The `i`th free id; `i` must be below `len`.
    pub fn at(self: ReusableRows, i: usize) u32 {
        std.debug.assert(i < self.len);
        return if (self.singleton) 0 else self.array.at(i).*;
    }
    /// Where `row` is in the list; null when the id is not free. Searches from the end.
    pub fn indexOf(self: ReusableRows, row: u32) ?usize {
        if (self.len == 0) return null;
        if (self.singleton) return if (row == 0) 0 else null;
        // Reusable IDs are unique; searching from the allocation end keeps
        // selected tail allocations from scanning the entire free list.
        var index = self.len - 1;
        var cursor = self.array.cursor(index);
        while (true) {
            if (cursor.pointer().* == row) return index;
            if (index == 0) return null;
            index -= 1;
            cursor.previous();
        }
    }
    /// For tests: fails unless the free ids are exactly `expected`, in order.
    pub fn expectEqual(self: ReusableRows, expected: []const u32) !void {
        try std.testing.expectEqual(expected.len, self.len);
        for (expected, 0..) |row, i| try std.testing.expectEqual(row, self.at(i));
    }
    /// Copies the free ids, in order, into `dst`, whose length must be `len`.
    pub fn copyTo(self: ReusableRows, dst: []u32) void {
        std.debug.assert(dst.len == self.len);
        if (self.len == 0) return;
        if (self.singleton) {
            dst[0] = 0;
            return;
        }
        var cursor = self.array.cursor(0);
        for (dst, 0..) |*row, i| {
            row.* = cursor.pointer().*;
            if (i + 1 < dst.len) cursor.next();
        }
    }
};
const FreeList = struct {
    /// The ids; only the first `len` count.
    array: RowArray = .{},
    /// How many ids are free.
    len: usize = 0,
    fn appendAssumeCapacity(self: *FreeList, row: u32) void {
        self.array.at(self.len).* = row;
        self.len += 1;
    }
    fn pop(self: *FreeList) ?u32 {
        if (self.len == 0) return null;
        self.len -= 1;
        return self.array.at(self.len).*;
    }
    fn clearRetainingCapacity(self: *FreeList) void {
        self.len = 0;
    }
};
/// A columnar table's storage: rows packed at positions `0..live_count`, a column of cells per
/// field, grown in chunks that never move. Read by this file and the journals; other code uses
/// `Table`'s functions.
pub const Columnar = struct {
    /// The table's pages.
    arena: table_storage.Arena,
    /// A byte array per field, `stride` bytes per position.
    columns: []table_storage.Array(u8) = &.{},
    /// `mask_words` words per physical position, word-major within a row.
    bitmask: table_storage.Array(u64) = .{},
    /// Mask words per row: the schema's `maskWords`.
    mask_words: u8 = 1,
    /// By row id: the generation of the row there, or, for a dead id, the one a handle to its last
    /// row does not have.
    generation: RowArray = .{},
    /// By row id: the row's position, or `maxInt(u32)` for a dead id.
    index: RowArray = .{},
    /// By position: the id of the row there.
    row_id: RowArray = .{},
    /// Live rows, which fill positions `0..live_count`.
    live_count: u32 = 0,
    /// The dead ids, in the order they are reused.
    free_list: FreeList = .{},
    /// Row ids the storage has room for.
    capacity: u32 = 0,
};
/// A singleton table's storage: at most one row, id 0. The slices and the cells belong to the
/// registry's singleton arena, or to `scoped_bytes` when the table is placed in a memory scope.
pub const Singleton = struct {
    /// The row's cell for each field.
    columns: [][]u8,
    /// The allocation holding `columns` and the cells of a table in a memory scope; empty
    /// otherwise.
    scoped_bytes: []align(16) u8 = &.{},
    /// The scope's backing, which `scoped_bytes` goes back to; null for a table in no scope.
    scoped_backing: ?*memory_mod.PageBacking = null,
    /// The row's mask.
    bitmask: Mask = .empty,
    /// The row's generation, bumped each time the row is allocated or freed.
    generation: u32 = 0,
    /// Whether the row exists.
    allocated: bool = false,
};
/// Who made the table: the registry's `scope` when it was created.
owner: Owner = .host,
/// How long the table is meant to live; see `Lifetime`.
lifetime: Lifetime = .durable,
/// Memory lifetime scope backing this table's pages; null uses the registry's backing.
/// Independent of `owner` and `lifetime`.
memory_scope: ?memory_mod.Scope.Id = null,
/// The registry's record of the table's schema, which the table holds a count on. Read the schema
/// with `getSchema`.
schema_ref: *SchemaRegistry.Record,
/// The name the schema is kept under in the registry: the table's own name for a table made from a
/// schema value, the registered name for one made by it.
schema_name: Atom = @enumFromInt(0),
/// Whether the table was made by a registered schema's name (`Registry.createNamed`), not from a
/// schema value.
uses_named_schema: bool = false,
/// The rows: one row inline, or columns.
storage: union(enum) { singleton: Singleton, columnar: Columnar },
/// The bytes of the table's string and opaque cells; see `Payload`.
payloads: table_storage.Payloads,
/// Asks for the payload arena to be compacted at the next point outside runs
/// (`Registry.reclaimPayloads`). Set where a save or dropped rows left dead bytes, which may be
/// inside a run, where compacting is not safe.
compact_payloads_wanted: bool = false,
/// Set once something outside the table keeps its payload cells by value, as an undo
/// history's row images and the figure model's staged rows do (`pinPayloads`): the arena is
/// then never reset or compacted, so such a cell names its bytes for the table's life.
payloads_pinned: bool = false,
/// A count `touch` bumps, wrapping: the functions here that change rows call it, writes through a
/// view's pointers do not. Two readings that differ mean the table changed.
revision: u64 = 0,
/// The table's name, unique among the registry's live tables.
name: Atom = @enumFromInt(0),

/// Set by `Registry.ensureSingleton`: the table's one row always exists, so `free` and `clear`
/// leave it.
required_singleton: bool = false,
/// While a sequencer run journals this table, the run's journal: rows are read and
/// written through it. Null outside runs and for tables runs never journal.
journal: ?*const Journal = null,
/// The registry's handle for this table, so a journal can key the table it covers.
handle: Handle = .{ .index = 0, .generation = 0 },

/// How an editor shows and edits a field's cells. Part of the schema: `Schema.validate` checks it
/// against the field's size, and two schemas that differ in it are not equal.
pub const ViewKind = union(enum) {
    /// An `f32` on a slider from `min` to `max`, both finite with `min <= max`.
    float_slider: struct { min: f32, max: f32 },
    /// Text: a `String` cell, or a fixed-size cell of NUL-padded bytes. The default, which fits a
    /// field of any size.
    text_field,
    /// A tag's presence.
    checkbox,
    /// A bool's value.
    toggle,

    /// An `Atom`, shown by its name.
    atom,
    /// A number, shown in decimal.
    int,
    /// A number or bytes, shown in hexadecimal.
    hex,
    /// `components` `f32`s, 1 to 4.
    vector: struct { components: u8 },
    /// `rows` by `cols` `f32`s, at most 64.
    matrix: struct { rows: u8, cols: u8 },

    /// A color in four bytes.
    color,
    /// A `Ref` to a row, shown as `formatRef` prints it.
    ref,
    /// An opaque payload (`FieldType.bytes`): shown as its length. Never edited.
    bytes,
};

/// The durable type of a field's cells: what a saved table may hold. A field with none
/// (`FieldDescriptor.field_type` null, and no view that implies one: see `durableFieldType`) is
/// opaque bytes.
pub const FieldType = enum {
    /// A 32-bit float.
    f32,
    /// A signed 32-bit integer.
    i32,
    /// A `math.Vec2f`: two `f32`s.
    vec2f,
    /// A `math.Vec3f`: three `f32`s.
    vec3f,
    /// A color: four bytes, `[4]u8`.
    color,
    /// Text of any length, in the table's payload arena: a `String` cell.
    string,
    /// Opaque bytes in the table's payload arena: a `Bytes` cell.
    bytes,

    /// An `Atom`. A table file keeps its name beside the rows.
    atom,
    /// No bytes: the cell's presence is its whole value.
    tag,
    /// A value of true or false, one byte: 0 or 1. Unlike a tag, a bool cell holds
    /// a value whether it reads true or false.
    bool,
    /// A `Ref` to a row of another table.
    ref,
    /// Unsigned integers of their width, little-endian.
    u8,
    u32,
    u64,
    /// A fixed-size array of numbers, pointer-free, saved as its bytes. Its size is the
    /// field's own, not the type's.
    fixed,

    /// A field's size for every type but `fixed`, whose size is the field's.
    pub fn size(field_type: FieldType) u32 {
        return switch (field_type) {
            .f32, .i32 => 4,
            .vec2f => 8,
            .vec3f => 12,
            .color => 4,
            .atom => @sizeOf(Atom),
            .string => @sizeOf(String),
            .bytes => @sizeOf(Bytes),
            .tag => 0,
            .bool => @sizeOf(bool),
            .ref => @sizeOf(Ref),
            .u8 => 1,
            .u32 => 4,
            .u64 => 8,
            .fixed => unreachable,
        };
    }
};

/// One field of a schema: a column of its tables. The schema owns it; read it, do not change it.
pub const FieldDescriptor = struct {
    /// The field's name. The schema's copy, valid while the schema lives.
    name: []const u8,
    /// Bytes in a cell; 0 for a tag.
    size: u32,

    /// A hash that identifies the cells' type: of the Zig type's name for a field added by type, of
    /// the `FieldType` for one added by it, of the view for one added by size. Two schemas are
    /// equal only where these match.
    semantic_type: u64 = 0,
    /// Bytes from one row's cell to the next: always `size`.
    stride: u32,
    /// The field's index in `Schema.fields`.
    column_index: u32,
    /// The field's bit in a row's `Mask`: always its index.
    bit: u8,
    /// How an editor shows the cells.
    view_kind: ViewKind = .text_field,

    /// The declared durable type; null for a field added by size, or by a Zig type that maps to
    /// none. `durableFieldType` also infers one from the view.
    field_type: ?FieldType = null,
    /// Whether the cells' bytes may be saved: the field has a durable type, a view that implies
    /// plain values, or the caller's certification (`FieldOptions`).
    persistent_safe: bool = false,
    /// Whether the Zig type the field was added with holds a pointer. Such a field is refused in a
    /// persistent table.
    contains_pointer: bool = false,

    /// The name's atom; the null atom in a schema built without an atom registry.
    name_id: Atom = @enumFromInt(0),

    /// Whether the cell is a `Payload`, its bytes in the table's payload arena.
    pub fn isPayload(field: *const FieldDescriptor) bool {
        return field.field_type == .string or field.field_type == .bytes;
    }

    /// The alignment a cell's payload is appended at.
    pub fn payloadAlignment(field: *const FieldDescriptor) std.mem.Alignment {
        return if (field.field_type == .bytes) bytes_alignment else .@"1";
    }
};

/// The fields of a table, in order. Build one with `init` and the `addField*` functions and hand it
/// to `Registry.create`, `ensure` or `registerSchema`, which keep a copy: the built schema stays
/// the caller's, to `deinit` afterwards. A table's own schema (`Table.getSchema`) is the registry's
/// copy, shared by every table of that schema, and is not to be changed.
pub const Schema = struct {
    /// What made the schema and frees it. Null in a registry's copy, which other images may
    /// reach: its registry frees it (`release`).
    allocator: ?std.mem.Allocator = null,
    /// The memory the descriptors lie in.
    backing_mem: []u8 = &.{},
    /// Hands `backing_mem` to `list`, once, in `init`.
    fba: std.heap.FixedBufferAllocator = undefined,
    /// The descriptors, with room for the `max_fields` given to `init`.
    list: std.ArrayListUnmanaged(FieldDescriptor) = .empty,
    /// Each field's name, copied when the field was added.
    owned_names: std.ArrayListUnmanaged([]u8) = .empty,
    /// The fields, in order: `list`'s items. A field's index here is its column and its mask bit.
    fields: []const FieldDescriptor,

    /// The registry the field names are interned in. Null in a schema built without one, whose
    /// fields are then found by text.
    atoms: ?*Atom.Registry = null,

    /// Makes an empty schema with room for `max_fields` fields, at most `Mask.max_bits`. `schema`
    /// may be undefined before the call. Fields added later intern their names in `kw`. `allocator`
    /// must live as long as the schema; free it with `deinit`. `error.TooManyFields`,
    /// `error.SchemaTooLarge` or `error.OutOfMemory`.
    pub fn init(schema: *Schema, allocator: std.mem.Allocator, kw: *Atom.Registry, max_fields: usize) !void {
        return schema.initWithAtoms(allocator, kw, max_fields);
    }

    fn initWithAtoms(schema: *Schema, allocator: std.mem.Allocator, kw: ?*Atom.Registry, max_fields: usize) !void {
        if (max_fields > Mask.max_bits) return error.TooManyFields;

        const descriptors_bytes = std.math.mul(usize, max_fields, @sizeOf(FieldDescriptor)) catch return error.SchemaTooLarge;
        const backing_bytes = std.math.add(usize, descriptors_bytes, @alignOf(FieldDescriptor)) catch return error.SchemaTooLarge;
        const backing_mem = try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(@alignOf(FieldDescriptor)), backing_bytes);
        var fba = std.heap.FixedBufferAllocator.init(backing_mem);
        var list: std.ArrayListUnmanaged(FieldDescriptor) = .empty;
        try list.ensureTotalCapacityPrecise(fba.allocator(), max_fields);
        schema.* = .{
            .allocator = allocator,
            .backing_mem = backing_mem,
            .fba = fba,
            .list = list,
            .owned_names = .empty,
            .fields = &.{},
            .atoms = kw,
        };
    }

    /// What `validate` refuses: more fields than `Mask.max_bits` (`TooManyFields`); two fields of
    /// one name (`DuplicateFieldName`); a field with no name, or whose stride, column index or bit
    /// is not what `addField*` gives it (`InvalidLayout`); a size that is not its `FieldType`'s, or
    /// a `fixed` field of no bytes (`InvalidFieldSize`); a view that does not fit the field's size
    /// or type (`InvalidViewLayout`); a slider's range that is not finite or has `min > max`
    /// (`InvalidViewRange`).
    pub const ValidationError = error{
        TooManyFields,
        DuplicateFieldName,
        InvalidLayout,
        InvalidFieldSize,
        InvalidViewLayout,
        InvalidViewRange,
    };

    /// Checks that a table can be made from the schema. The registry does this to every schema it
    /// is given, so a schema built wrong is refused there, not where the field was added.
    pub fn validate(schema: *const Schema) ValidationError!void {
        if (schema.fields.len > Mask.max_bits) return error.TooManyFields;
        for (schema.fields, 0..) |field, i| {
            if (field.name.len == 0 or field.stride != field.size or
                field.column_index != @as(u32, @intCast(i)) or @as(usize, field.bit) != i)
                return error.InvalidLayout;
            for (schema.fields[0..i]) |previous| {
                if (std.mem.eql(u8, field.name, previous.name)) return error.DuplicateFieldName;
            }
            if (field.field_type) |field_type| {
                const sized = if (field_type == .fixed) field.size != 0 else field.size == field_type.size();
                if (!sized) return error.InvalidFieldSize;
                if ((field_type == .bytes) != (field.view_kind == .bytes)) return error.InvalidViewLayout;
            }
            switch (field.view_kind) {
                .float_slider => |range| {
                    if (field.size != @sizeOf(f32)) return error.InvalidViewLayout;
                    if (!std.math.isFinite(range.min) or !std.math.isFinite(range.max) or range.min > range.max)
                        return error.InvalidViewRange;
                },
                .checkbox => if (field.size != 0) return error.InvalidViewLayout,
                .toggle => if (field.size != @sizeOf(bool)) return error.InvalidViewLayout,
                .atom => if (@as(usize, field.size) != @sizeOf(Atom)) return error.InvalidViewLayout,
                .ref => if (@as(usize, field.size) != @sizeOf(Ref)) return error.InvalidViewLayout,
                .color => if (field.size != 4) return error.InvalidViewLayout,
                .vector => |cfg| {
                    if (cfg.components == 0 or cfg.components > 4 or
                        @as(usize, field.size) != @as(usize, cfg.components) * @sizeOf(f32))
                        return error.InvalidViewLayout;
                },
                .matrix => |cfg| {
                    const elements = @as(usize, cfg.rows) * cfg.cols;
                    if (cfg.rows == 0 or cfg.cols == 0 or elements > 64 or
                        @as(usize, field.size) != elements * @sizeOf(f32))
                        return error.InvalidViewLayout;
                },
                .int, .hex => if (field.size == 0 or field.size == 3) return error.InvalidViewLayout,
                .bytes => if (field.size != @sizeOf(Bytes)) return error.InvalidViewLayout,
                .text_field => {},
            }
        }
    }

    /// A copy of `source` made with `allocator`, the caller's to `deinit`. Validates `source`
    /// first: fails with a `ValidationError`, or as `init` does.
    pub fn clone(source: *const Schema, allocator: std.mem.Allocator) !Schema {
        try source.validate();
        var result: Schema = undefined;
        try result.initWithAtoms(allocator, source.atoms, source.fields.len);
        errdefer result.release(allocator);
        for (source.fields) |field| try result.addFieldRawFallible(
            field.name,
            field.size,
            field.semantic_type,
            field.view_kind,
            field.field_type,
            field.persistent_safe,
            field.contains_pointer,
        );
        return result;
    }

    /// Frees a schema made by `init` or `clone`. Not for a registry's copy, which has no allocator.
    pub fn deinit(schema: *Schema) void {
        schema.release(schema.allocator.?);
    }

    /// Frees what the schema owns through `allocator`, which made it.
    pub fn release(schema: *Schema, allocator: std.mem.Allocator) void {
        for (schema.owned_names.items) |name| allocator.free(name);
        schema.owned_names.deinit(allocator);

        allocator.free(@as(
            []align(@alignOf(FieldDescriptor)) u8,
            @alignCast(schema.backing_mem),
        ));
    }

    fn typeId(comptime T: type) u64 {
        return comptime std.hash.Wyhash.hash(0, @typeName(T));
    }

    fn typeContainsPointer(comptime T: type) bool {
        return switch (@typeInfo(T)) {
            .pointer => true,
            .array => |info| typeContainsPointer(info.child),
            .optional => |info| typeContainsPointer(info.child),
            .@"struct" => |info| blk: {
                inline for (info.fields) |field| {
                    if (typeContainsPointer(field.type)) break :blk true;
                }
                break :blk false;
            },
            .@"union" => |info| blk: {
                inline for (info.fields) |field| {
                    if (typeContainsPointer(field.type)) break :blk true;
                }
                break :blk false;
            },
            else => false,
        };
    }

    fn fieldTypeId(field_type: FieldType) u64 {
        return switch (field_type) {
            .f32 => typeId(f32),
            .i32 => typeId(i32),
            .vec2f => typeId(math.Vec2f),
            .vec3f => typeId(math.Vec3f),
            .color => typeId([4]u8),
            .atom => typeId(Atom),
            .tag => typeId(void),
            .bool => typeId(bool),
            .string => typeId(String),
            .bytes => typeId(Bytes),
            .ref => typeId(Ref),
            .u8 => typeId(u8),
            .u32 => typeId(u32),
            .u64 => typeId(u64),
            .fixed => std.hash.Wyhash.hash(0, "table.fixed"),
        };
    }

    /// Appends a field whose cells are `T`s: its size is `@sizeOf(T)`, and its durable type is
    /// inferred where `T` is `f32`, `i32`, `math.Vec2f`, `math.Vec3f`, `[4]u8` (a color), `Atom`,
    /// `void` (a tag), `bool`, `String` or `Bytes`. Any other `T` is opaque and not certified for
    /// saving. `name` is copied and interned. Panics when memory runs out or the schema already
    /// holds the `max_fields` given to `init`. Nothing checks `view_kind` against `T` here:
    /// `validate` does.
    pub fn addField(schema: *Schema, name: []const u8, comptime T: type, view_kind: ViewKind) void {
        schema.addFieldWithOptions(name, T, view_kind, .{});
    }

    /// As `addField`, returning `error.OutOfMemory` where that panics; a full schema still panics.
    /// A failed call adds no field, though the name may stay interned.
    pub fn addFieldFallible(schema: *Schema, name: []const u8, comptime T: type, view_kind: ViewKind) !void {
        if (schema.atoms) |kw| try kw.tryInternAll(&.{name});
        const field_type = comptime durableFieldTypeFor(T);
        try schema.addFieldRawFallible(name, @sizeOf(T), typeId(T), view_kind, field_type, field_type != null, comptime typeContainsPointer(T));
    }

    /// As `addField`, with `options`.
    pub fn addFieldWithOptions(schema: *Schema, name: []const u8, comptime T: type, view_kind: ViewKind, options: FieldOptions) void {
        const field_type = comptime durableFieldTypeFor(T);
        schema.addFieldRaw(
            name,
            @sizeOf(T),
            typeId(T),
            view_kind,
            field_type,
            options.persistent_safe or field_type != null,
            comptime typeContainsPointer(T),
        );
    }

    /// Adds a field of `T` declared as `field_type`, for a schema that names durable types other
    /// than the ones `addField` infers, as `.u32` for a `u32`. Null infers as `addField` does.
    /// Panics where `addFieldOfTypeFallible` fails.
    pub fn addFieldOfType(schema: *Schema, name: []const u8, comptime T: type, field_type: ?FieldType, view_kind: ViewKind) void {
        schema.addFieldOfTypeFallible(name, T, field_type, view_kind) catch @panic("schema field OOM");
    }

    /// As `addFieldOfType`, returning its failures: `error.InvalidFieldType` when a durable type is
    /// declared or inferred for a `T` that holds a pointer, and `error.OutOfMemory`.
    pub fn addFieldOfTypeFallible(schema: *Schema, name: []const u8, comptime T: type, field_type: ?FieldType, view_kind: ViewKind) !void {
        if (schema.atoms) |kw| try kw.tryInternAll(&.{name});
        const declared = field_type orelse comptime durableFieldTypeFor(T);
        // A durable cell is saved as its bytes, which a pointer would not survive.
        if (declared != null and comptime typeContainsPointer(T)) return error.InvalidFieldType;
        try schema.addFieldRawFallible(name, @sizeOf(T), typeId(T), view_kind, declared, declared != null, comptime typeContainsPointer(T));
    }

    fn durableFieldTypeFor(comptime T: type) ?FieldType {
        return if (T == f32) .f32 else if (T == i32) .i32 else if (T == math.Vec2f) .vec2f else if (T == math.Vec3f) .vec3f else if (T == [4]u8) .color else if (T == Atom) .atom else if (T == void) .tag else if (T == bool) .bool else if (T == String) .string else if (T == Bytes) .bytes else null;
    }

    /// Appends a field by its durable type, with no Zig type. `field_size` is `field_type.size()`,
    /// or for `.fixed` the array's bytes; `validate` refuses any other. The field is certified for
    /// saving. Panics when memory runs out or the schema is full.
    pub fn addFieldType(schema: *Schema, name: []const u8, field_type: FieldType, field_size: u32, view_kind: ViewKind) void {
        schema.addFieldRaw(name, field_size, fieldTypeId(field_type), view_kind, field_type, true, false);
    }

    /// As `addFieldType`, returning `error.OutOfMemory` where that panics.
    pub fn addFieldTypeFallible(schema: *Schema, name: []const u8, field_type: FieldType, field_size: u32, view_kind: ViewKind) !void {
        try schema.addFieldRawFallible(name, field_size, fieldTypeId(field_type), view_kind, field_type, true, false);
    }

    /// Appends a field known by its size and view alone, with no durable type declared;
    /// `durableFieldType` infers one from the view where it can. It is certified for saving when
    /// the view implies plain values (`float_slider`, `checkbox`, `toggle`, `atom`, `ref`, `color`,
    /// `vector`, `matrix`) and not for `text_field`, `int`, `hex` or `bytes`. Panics when memory
    /// runs out or the schema is full.
    pub fn addFieldSized(schema: *Schema, name: []const u8, field_size: u32, view_kind: ViewKind) void {
        schema.addFieldSizedWithOptions(name, field_size, view_kind, .{});
    }

    /// As `addFieldSized`, with `options`.
    pub fn addFieldSizedWithOptions(schema: *Schema, name: []const u8, field_size: u32, view_kind: ViewKind, options: FieldOptions) void {
        const semantic_type = switch (view_kind) {
            .float_slider => typeId(f32),
            .checkbox => typeId(void),
            .toggle => typeId(bool),
            .atom => typeId(Atom),
            .ref => typeId(Ref),
            .color => typeId([4]u8),
            .vector => if (field_size == @sizeOf(math.Vec2f)) typeId(math.Vec2f) else if (field_size == @sizeOf(math.Vec3f)) typeId(math.Vec3f) else std.hash.Wyhash.hash(0, "table.opaque.vector"),
            else => std.hash.Wyhash.hash(0, "table.opaque"),
        };
        const inferred_safe = switch (view_kind) {
            // A ref holds names and handles, never pointers.
            .float_slider, .checkbox, .toggle, .atom, .ref, .color, .vector, .matrix => true,
            .text_field, .int, .hex, .bytes => false,
        };
        schema.addFieldRaw(name, field_size, semantic_type, view_kind, null, options.persistent_safe or inferred_safe, false);
    }

    fn addFieldRaw(
        schema: *Schema,
        name: []const u8,
        size: u32,
        semantic_type: u64,
        view_kind: ViewKind,
        field_type: ?FieldType,
        persistent_safe: bool,
        contains_pointer: bool,
    ) void {
        schema.addFieldRawFallible(name, size, semantic_type, view_kind, field_type, persistent_safe, contains_pointer) catch @panic("schema field OOM");
    }

    fn addFieldRawFallible(
        schema: *Schema,
        name: []const u8,
        size: u32,
        semantic_type: u64,
        view_kind: ViewKind,
        field_type: ?FieldType,
        persistent_safe: bool,
        contains_pointer: bool,
    ) !void {
        contract.invariant(schema.list.items.len < Mask.max_bits, "table.schema.max_fields");
        contract.invariant(schema.list.items.len < schema.list.capacity, "table.schema.initial_capacity");
        const idx: u32 = @intCast(schema.list.items.len);
        const allocator = schema.allocator.?;
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        try schema.owned_names.append(allocator, owned_name);
        schema.list.appendAssumeCapacity(.{
            .name = owned_name,
            .size = size,
            .semantic_type = semantic_type,
            .stride = size,
            .column_index = idx,
            .bit = @intCast(idx),
            .view_kind = view_kind,
            .field_type = field_type,
            .persistent_safe = persistent_safe,
            .contains_pointer = contains_pointer,
            .name_id = if (schema.atoms) |kw| kw.intern(name) else @enumFromInt(0),
        });
        schema.fields = schema.list.items;
    }

    /// Unions `other` into `schema`: each field of `other` this schema lacks is appended in
    /// `other`'s order, and a field both name must agree in size and type. Its view is
    /// presentation, so a field both name keeps this schema's. All or nothing: a conflict,
    /// a schema too small for the union or a refused name allocation leaves `schema` as it was.
    pub fn addFields(schema: *Schema, other: *const Schema) error{ FieldConflict, TooManyFields, OutOfMemory }!void {
        var added: usize = 0;
        for (other.fields) |field| {
            const existing_index = schema.fieldIndexByName(field.name) orelse {
                added += 1;
                continue;
            };
            const existing = schema.fields[existing_index];
            const same_layout = existing.size == field.size and
                existing.semantic_type == field.semantic_type and
                existing.field_type == field.field_type and
                existing.contains_pointer == field.contains_pointer;
            if (!same_layout) return error.FieldConflict;
        }
        const union_count = schema.list.items.len + added;
        if (union_count > schema.list.capacity or union_count > Mask.max_bits) return error.TooManyFields;
        if (schema.atoms) |kw| {
            for (other.fields) |field| try kw.tryInternAll(&.{field.name});
        }
        const original_count = schema.list.items.len;
        errdefer {
            for (schema.owned_names.items[original_count..]) |name| schema.allocator.?.free(name);
            schema.owned_names.shrinkRetainingCapacity(original_count);
            schema.list.shrinkRetainingCapacity(original_count);
            schema.fields = schema.list.items;
        }
        for (other.fields) |field| {
            if (schema.fieldIndexByName(field.name) != null) continue;
            try schema.addFieldRawFallible(
                field.name,
                field.size,
                field.semantic_type,
                field.view_kind,
                field.field_type,
                field.persistent_safe,
                field.contains_pointer,
            );
        }
    }

    /// By text, so it also serves schemas built without atoms.
    fn fieldIndexByName(schema: *const Schema, name: []const u8) ?usize {
        for (schema.fields, 0..) |field, index| {
            if (std.mem.eql(u8, field.name, name)) return index;
        }
        return null;
    }

    /// Whether a persistent table may have this schema: `error.PersistentPointerField` for a field
    /// whose type holds a pointer, `error.PersistentUnsafeField` for one not certified pointer-free
    /// (`FieldDescriptor.persistent_safe`).
    pub fn validatePersistentStorage(schema: *const Schema) error{ PersistentPointerField, PersistentUnsafeField }!void {
        for (schema.fields) |field| {
            if (field.contains_pointer) return error.PersistentPointerField;
            if (!field.persistent_safe) return error.PersistentUnsafeField;
        }
    }

    /// The index in `fields` of the field named `name`; null when there is none. A schema with an
    /// atom registry compares the names as atoms (`Atom.from(name)`, which interns nothing), one
    /// without compares text. A linear search.
    pub fn fieldIndex(schema: Schema, name: []const u8) ?usize {
        if (schema.atoms != null) {
            const id = Atom.from(name);
            for (schema.fields, 0..) |*field, i| {
                if (field.name_id == id) return i;
            }
            return null;
        }
        for (schema.fields, 0..) |*field, i| {
            if (std.mem.eql(u8, field.name, name)) return i;
        }
        return null;
    }

    /// The mask with the bit of each named field set. Panics on a name the schema lacks.
    pub fn mask(schema: Schema, names: []const []const u8) Mask {
        var m: Mask = .empty;
        for (names) |name| {
            const idx = schema.fieldIndex(name) orelse @panic("unknown schema field");
            m.set(schema.fields[idx].bit);
        }
        return m;
    }

    /// Mask words each row of a table with this schema stores.
    pub fn maskWords(schema: Schema) u8 {
        const words = (schema.fields.len + 63) / 64;
        return @intCast(@max(words, 1));
    }
};

/// The schemas a `Registry` holds, by name: one record per name, counted by the tables that use it.
/// A table made from a schema value keeps it under the table's own name; `register` adds a schema
/// that code names, and marks it enforced, so nothing else takes the name with another schema. Used
/// through `Registry`.
pub const SchemaRegistry = struct {
    /// A schema the registry owns, the name it is under, and how many tables and pending operations
    /// hold it.
    pub const Record = struct { schema: Schema, refs: usize = 0, name: Atom };
    /// The host's, shared: code of either image clones and frees records through it.
    global: memory_mod.SharedAllocator,
    /// The current record of each name.
    entries: std.AutoHashMapUnmanaged(Atom, *Record) = .empty,
    /// The schemas code registered, and what their tables store.
    enforced: std.AutoHashMapUnmanaged(Atom, Storage) = .empty,

    /// What a registered schema's tables hold: rows, or the one row of a singleton.
    pub const Storage = enum { columnar, singleton };

    fn clone(registry: *SchemaRegistry, name: Atom, template: *const Schema) !*Record {
        const allocator = registry.global.allocator();
        const record = try allocator.create(Record);
        errdefer allocator.destroy(record);
        var schema = try Schema.clone(template, allocator);
        // Another image may free it, so it keeps no allocator of the image cloning it.
        schema.allocator = null;
        record.* = .{ .schema = schema, .name = name };
        return record;
    }

    fn dispose(registry: *SchemaRegistry, record: *Record) void {
        const allocator = registry.global.allocator();
        record.schema.release(allocator);
        allocator.destroy(record);
    }

    fn retain(_: *SchemaRegistry, record: *Record) void {
        record.refs += 1;
    }
    fn release(registry: *SchemaRegistry, record: *Record) void {
        std.debug.assert(record.refs > 0);
        record.refs -= 1;
        registry.retire(record);
    }
    fn retire(registry: *SchemaRegistry, record: *Record) void {
        if (record.refs != 0) return;
        if (registry.entries.get(record.name) == record) {
            if (registry.enforced.contains(record.name)) return;
            _ = registry.entries.remove(record.name);
        }
        registry.dispose(record);
    }

    /// Keeps a copy of `template` under `name` as the enforced schema of tables of `storage`.
    /// Registering an equal schema again changes nothing. `error.SchemaMismatch` when the name
    /// holds a different schema or is registered for the other storage; a `ValidationError` or
    /// `error.OutOfMemory` from the copy. A failure leaves the registry as it was.
    pub fn register(registry: *SchemaRegistry, name: Atom, template: *const Schema, storage: Storage) !void {
        if (registry.enforced.get(name)) |registered| {
            if (registered != storage) return error.SchemaMismatch;
        }
        if (registry.get(name)) |existing| {
            if (!schemasEqual(existing, template)) return error.SchemaMismatch;
            const allocator = registry.global.allocator();
            try registry.enforced.ensureUnusedCapacity(allocator, 1);
            registry.enforced.putAssumeCapacity(name, storage);
            return;
        }
        // Both map admissions and the owned clone precede either publication.
        const allocator = registry.global.allocator();
        try registry.entries.ensureUnusedCapacity(allocator, 1);
        try registry.enforced.ensureUnusedCapacity(allocator, 1);
        const owned = try registry.clone(name, template);
        registry.entries.putAssumeCapacity(name, owned);
        registry.enforced.putAssumeCapacity(name, storage);
    }

    /// The schema under `name`, registered or a table's own; null when there is none.
    pub fn get(registry: *SchemaRegistry, name: Atom) ?*Schema {
        const record = registry.entries.get(name) orelse return null;
        return &record.schema;
    }

    /// Frees every record. No table may still hold one.
    pub fn deinit(registry: *SchemaRegistry) void {
        registry.enforced.clearRetainingCapacity();
        while (registry.entries.count() != 0) {
            var it = registry.entries.valueIterator();
            const record = it.next().?.*;
            std.debug.assert(record.refs == 0);
            registry.retire(record);
        }
        const allocator = registry.global.allocator();
        registry.entries.deinit(allocator);
        registry.enforced.deinit(allocator);
    }
};

/// Names a row: its id and the generation the id had when the row was made. It keeps naming that
/// row until the row is freed or its table is cleared or replaced, and `Table.valid` tells whether
/// it still does. A freed id is reused by a later row with another generation, so an old handle
/// never names the new row.
pub const RowHandle = struct {
    /// The row's id in its table: the same for the row's life, below `rowCapacity`, and not its
    /// position in storage.
    row: u32, // Stable logical ID, not a physical position.
    /// The id's generation when the row was made.
    generation: u32,
};

/// One present field of a row, in an `EntityView`.
pub const FieldNode = struct {
    /// The field's name: the schema's bytes.
    name: []const u8,
    /// The field, in the table's schema.
    descriptor: *const FieldDescriptor,
    /// The row's cell, in the table's own storage.
    ptr: *const anyopaque,
    /// The next present field, in schema order.
    next: ?*FieldNode,
};

/// A row as a list of the fields it holds, for code that walks a row without knowing its schema. It
/// reads the table's own storage, whatever a journal holds, and is good until the table's rows
/// change.
pub const EntityView = struct {
    /// The first present field; null for a row that holds none.
    head: ?*FieldNode,

    /// Lists the present fields of `handle`'s row in schema order, a node each from `allocator`.
    /// Nothing here frees the nodes, those made before a failed allocation included, so an arena
    /// suits. `error.StaleHandle` for a row that is gone, `error.OutOfMemory`.
    pub fn build(allocator: std.mem.Allocator, table: *const Table, handle: RowHandle) !EntityView {
        if (!table.valid(handle)) return error.StaleHandle;
        var head: ?*FieldNode = null;
        var tail: ?*FieldNode = null;
        const bitmask = table.rowMask(handle.row);
        for (table.getSchema().fields) |*desc| {
            if (!bitmask.has(desc.bit)) continue;
            const node = try allocator.create(FieldNode);
            const bytes = table.rowCellBytes(handle.row, desc);
            node.* = .{
                .name = desc.name,
                .descriptor = desc,
                .ptr = bytes.ptr,
                .next = null,
            };
            if (tail) |t| t.next = node else head = node;
            tail = node;
        }
        return .{ .head = head };
    }

    /// The node of the field named `name`; null when the row does not hold it.
    pub fn find(view: EntityView, name: []const u8) ?*FieldNode {
        var it = view.head;
        while (it) |node| : (it = node.next) {
            if (std.mem.eql(u8, node.name, name)) return node;
        }
        return null;
    }
};

/// The table's schema: the registry's copy, shared by every table of that schema. Read it; do not
/// add fields. Good while the table lives and its contents are not replaced.
pub fn getSchema(table: *const Table) *Schema {
    return &table.schema_ref.schema;
}

/// Row ids the storage has room for, live or not; 1 for a singleton. It grows as rows are allocated
/// and never shrinks.
pub fn rowCapacity(table: *const Table) u32 {
    return switch (table.storage) {
        .singleton => 1,
        .columnar => |*columnar| columnar.capacity,
    };
}

/// Whether the table is a singleton: at most one row, whose id is 0.
pub fn isSingleton(table: *const Table) bool {
    return table.storage == .singleton;
}

fn physicalCell(table: *const Table, position: u32, field: *const FieldDescriptor) []u8 {
    const offset = @as(usize, position) * field.stride;
    return switch (table.storage) {
        .singleton => |*singleton| singleton.columns[field.column_index][offset..][0..field.stride],
        .columnar => |*columnar| columnar.columns[field.column_index].sliceAt(offset, field.stride),
    };
}

/// Row ids whose generation is kept: 1 for a singleton, otherwise the columnar storage's ids. A
/// replacement gives the new storage at least as many as the table it replaces had, so that table's
/// old handles stay stale.
pub fn generationCount(table: *const Table) usize {
    return switch (table.storage) {
        .singleton => 1,
        .columnar => |columnar| columnar.generation.len,
    };
}

/// The generation a handle to row id `row` must have to be valid: for a row live in an attached
/// journal's run, the run's; otherwise the table's stored one. `row` must be below `rowCapacity`.
pub fn rowGeneration(table: *const Table, row: u32) u32 {
    if (table.journal) |journal| {
        if (journal.generation(@constCast(table), row)) |live| return live;
    }
    return table.storedGeneration(row);
}

/// The generation in the table's own storage, whatever a journal holds.
pub fn storedGeneration(table: *const Table, row: u32) u32 {
    return switch (table.storage) {
        .singleton => |*singleton| blk: {
            std.debug.assert(row == 0);
            break :blk singleton.generation;
        },
        .columnar => |*columnar| columnar.generation.at(row).*,
    };
}

/// Mask words per row in this table's storage.
pub fn maskWords(table: *const Table) u8 {
    return switch (table.storage) {
        .singleton => Mask.max_words,
        .columnar => |*columnar| columnar.mask_words,
    };
}

/// The stored words of a live physical position.
fn positionMaskWords(columnar: *const Columnar, position: u32) []u64 {
    return columnar.bitmask.sliceAt(@as(usize, position) * columnar.mask_words, columnar.mask_words);
}

fn positionMask(columnar: *const Columnar, position: u32) Mask {
    var mask: Mask = .empty;
    @memcpy(mask.words[0..columnar.mask_words], positionMaskWords(columnar, position));
    return mask;
}

/// The fields row id `row` holds, as an attached journal's run sees them. Empty for a dead row.
pub fn rowMask(table: *const Table, row: u32) Mask {
    if (table.journal) |journal| {
        const mutable: *Table = @constCast(table);
        const handle = journal.handleOf(mutable, row) orelse return .empty;
        const place = journal.read(mutable, handle) orelse return .empty;
        return place.table.storedMask(place.row);
    }
    return table.storedMask(row);
}

/// The row's mask in the table's own storage, whatever a journal holds.
pub fn storedMask(table: *const Table, row: u32) Mask {
    switch (table.storage) {
        .singleton => |*singleton| {
            std.debug.assert(row == 0);
            return if (singleton.allocated) singleton.bitmask else .empty;
        },
        .columnar => |*columnar| {
            const position = columnar.index.at(row).*;
            if (position == dead_index) return .empty;
            return positionMask(columnar, position);
        },
    }
}

/// Whether a live row holds field bit `bit`; false for a dead row. Reads one word.
pub fn rowHas(table: *const Table, row: u32, bit: u8) bool {
    if (table.journal != null) return table.rowMask(row).has(bit);
    switch (table.storage) {
        .singleton => |*singleton| {
            std.debug.assert(row == 0);
            return singleton.allocated and singleton.bitmask.has(bit);
        },
        .columnar => |*columnar| {
            const position = columnar.index.at(row).*;
            if (position == dead_index) return false;
            const word = bit / 64;
            std.debug.assert(word < columnar.mask_words);
            const stored = columnar.bitmask.at(@as(usize, position) * columnar.mask_words + word).*;
            return stored & (@as(u64, 1) << @intCast(bit % 64)) != 0;
        },
    }
}

/// Sets a row id's generation, mask and liveness in the table's own storage, for code that puts
/// rows back from an image it kept (the journals, a table RPC's rollback). Raw storage: no journal
/// sees it, `revision` is not bumped, and the reusable list is left alone, so the caller sets that
/// right and calls `touch` once the whole restore is done. An id brought to life takes the next
/// position with zeroed cells; one made dead gives its position up to the last row. `mask` is
/// ignored for a dead row.
pub fn restoreRowState(table: *Table, row: u32, generation: u32, mask: Mask, live: bool) void {
    switch (table.storage) {
        .singleton => |*singleton| {
            std.debug.assert(row == 0);
            singleton.generation = generation;
            singleton.bitmask = if (live) mask else .empty;
            singleton.allocated = live;
        },
        .columnar => |*columnar| {
            if (live and columnar.index.at(row).* == dead_index) {
                const position = columnar.live_count;
                std.debug.assert(position < columnar.capacity);
                columnar.live_count += 1;
                columnar.index.at(row).* = position;
                columnar.row_id.at(position).* = row;
                for (table.getSchema().fields) |*field| @memset(table.physicalCell(position, field), 0);
            } else if (!live and columnar.index.at(row).* != dead_index) table.removePhysicalRow(row);
            columnar.generation.at(row).* = generation;
            if (live) table.storeMask(columnar, columnar.index.at(row).*, mask);
        },
    }
}

/// Replaces the mask of row id `row`. Through an attached journal the run's copy of the row is
/// written and a row the run cannot see is left as it is; without one the row must be live. Does
/// not bump `revision`.
pub fn setMask(table: *Table, row: u32, mask: Mask) void {
    if (table.journal) |journal| {
        const handle = journal.handleOf(table, row) orelse return;
        const place = journal.access(table, handle) orelse return;
        return place.table.setStoredMask(place.row, mask);
    }
    table.setStoredMask(row, mask);
}

/// Sets the row's mask in the table's own storage, whatever a journal holds.
pub fn setStoredMask(table: *Table, row: u32, mask: Mask) void {
    switch (table.storage) {
        .singleton => |*singleton| {
            std.debug.assert(row == 0);
            singleton.bitmask = mask;
        },
        .columnar => |*columnar| {
            const position = columnar.index.at(row).*;
            std.debug.assert(position != dead_index);
            table.storeMask(columnar, position, mask);
        },
    }
}

/// Sets or clears one presence bit of a live row.
pub fn setPresent(table: *Table, row: u32, bit: u8, present: bool) void {
    if (table.journal) |journal| {
        const handle = journal.handleOf(table, row) orelse return;
        const place = journal.access(table, handle) orelse return;
        var copied = place.table.storedMask(place.row);
        copied.setTo(bit, present);
        return place.table.setStoredMask(place.row, copied);
    }
    var mask = table.rowMask(row);
    mask.setTo(bit, present);
    table.setMask(row, mask);
}

fn storeMask(table: *const Table, columnar: *Columnar, position: u32, mask: Mask) void {
    // A bit past the schema would name no field; words past the stored count must stay zero.
    std.debug.assert(Mask.firstBits(table.getSchema().fields.len).containsAll(mask));
    @memcpy(positionMaskWords(columnar, position), mask.words[0..columnar.mask_words]);
}

fn rowPosition(table: *const Table, row: u32) u32 {
    std.debug.assert(table.isAllocated(row));
    return switch (table.storage) {
        .singleton => 0,
        .columnar => |*columnar| columnar.index.at(row).*,
    };
}

/// The id of the row at storage position `position`, which must be below `liveCount`. Positions are
/// dense and change as rows are freed or sorted. Raw storage: no journal sees it.
pub fn rowAtPosition(table: *const Table, position: u32) u32 {
    std.debug.assert(position < table.liveCount());
    return switch (table.storage) {
        .singleton => 0,
        .columnar => |columnar| columnar.row_id.at(position).*,
    };
}

/// As `rowCellBytes`, the field named by its index in the schema.
pub fn rowFieldBytes(table: *const Table, row: u32, field_index: usize) []u8 {
    return table.rowCellBytes(row, &table.getSchema().fields[field_index]);
}

/// A live row's cell in the table's own storage: `field.stride` bytes, whether or not the cell is
/// present. `row` must be live. Raw storage: no journal sees a read or a write, so never use it in
/// a journaled kernel, where `cellBytes` and `writableCellBytes` serve. Good until the table's rows
/// change.
pub fn rowCellBytes(table: *const Table, row: u32, field: *const FieldDescriptor) []u8 {
    return table.physicalCell(table.rowPosition(row), field);
}

/// A cell's bytes as a run sees them, to read: through an attached journal, wherever the
/// row's current values are; empty for a row the run cannot see. Without a journal, the
/// table's own cell.
pub fn cellBytes(table: *const Table, row: u32, field: *const FieldDescriptor) []const u8 {
    const journal = table.journal orelse return table.rowCellBytes(row, field);
    const mutable: *Table = @constCast(table);
    const handle = journal.handleOf(mutable, row) orelse return &.{};
    const place = journal.read(mutable, handle) orelse return &.{};
    // An overlay has the table's schema, so the field has the same index there.
    const place_field = &place.table.getSchema().fields[field.column_index];
    return place.table.rowCellBytes(place.row, place_field);
}

/// A cell's bytes to write: through an attached journal, the run's own copy of the row,
/// made on its first access; empty for a row the run cannot see. Without a journal, the
/// table's own cell.
pub fn writableCellBytes(table: *Table, row: u32, field: *const FieldDescriptor) []u8 {
    const journal = table.journal orelse return table.rowCellBytes(row, field);
    const handle = journal.handleOf(table, row) orelse return &.{};
    const place = journal.access(table, handle) orelse return &.{};
    const place_field = &place.table.getSchema().fields[field.column_index];
    return place.table.rowCellBytes(place.row, place_field);
}

// ---- payloads ------------------------------------------------------------------------------
//
// A string or opaque cell is a `Payload` into this table's arena. A journal layer's copy of a
// row holds the same cell, so a payload is always resolved and appended with the table the
// caller names, never with a layer's overlay table.

/// The payload's bytes: valid until the table is cleared, compacted or destroyed.
pub fn payloadBytes(table: *const Table, payload: Payload) []const u8 {
    return table.payloads.bytesOf(payload);
}

/// The payload's bytes to write in place, for the code that made the payload and has not yet handed
/// it on, as one filling what `allocatePayload` returned. No journal covers them: a faulted run's
/// writes to them stay.
pub fn payloadBytesMut(table: *Table, payload: Payload) []u8 {
    return table.payloads.bytesOf(payload);
}

/// A payload of `size` bytes for the caller to fill, as one that copies several parts into
/// it. Nothing names it until a cell is written with it.
pub fn allocatePayload(table: *Table, size: usize, alignment: std.mem.Alignment) error{ OutOfMemory, Overflow }!Payload {
    return table.payloads.allocate(size, alignment);
}

/// A string cell's text. The bytes are the table's until it is cleared, compacted or destroyed:
/// copy what must last. `string` must be a cell of this table.
pub fn textOf(table: *const Table, string: String) []const u8 {
    return table.payloads.bytesOf(string.payload);
}

/// An opaque cell's bytes, at an address aligned to 16. They are the table's until it is cleared,
/// compacted or destroyed: copy what must last. `bytes` must be a cell of this table.
pub fn bytesOf(table: *const Table, bytes: Bytes) []align(16) const u8 {
    return @alignCast(table.payloads.bytesOf(bytes.payload));
}

/// A copy of `bytes` in the table's arena. Nothing names it until a cell is written with it.
pub fn appendPayload(table: *Table, bytes: []const u8, alignment: std.mem.Alignment) error{ OutOfMemory, Overflow }!Payload {
    return table.payloads.append(bytes, alignment);
}

/// One past the arena's last used offset: the bytes payloads take, dead ones included.
pub fn payloadEnd(table: *const Table) u32 {
    return table.payloads.end();
}

/// Room for `size` more payload bytes, taken now, so that appends that fit it cannot fail
/// and take nothing more from the table's backing.
pub fn reservePayloads(table: *Table, size: usize) error{ OutOfMemory, Overflow }!void {
    return table.payloads.reserve(size);
}

/// Keeps every payload where it is for the table's life: for a table whose payload cells
/// are kept by value outside it. Its dead bytes are then never given back.
pub fn pinPayloads(table: *Table) void {
    table.payloads_pinned = true;
}

/// Drops the arena's bytes when no row is left to name them and no run is using the table.
pub fn resetPayloadsIfEmpty(table: *Table) void {
    if (table.payloads_pinned or table.journal != null or table.liveCount() != 0) return;
    table.payloads.reset();
}

/// The payload naming `bytes`: the bytes themselves when they already lie in the table's
/// arena at `alignment`, as a slice a payload was resolved to does, and a copy otherwise.
pub fn payloadFor(table: *Table, bytes: []const u8, alignment: std.mem.Alignment) error{ OutOfMemory, Overflow }!Payload {
    if (table.payloads.find(bytes)) |found| {
        if (alignment.check(found.offset)) return found;
    }
    return table.payloads.append(bytes, alignment);
}

/// An allocator of the table's arena, for what a payload's own bytes point at: a command's
/// slice of values that hold slices keeps them all here, where they live as long as the
/// payload. It frees and resizes nothing; alignments past 16 fail.
pub fn payloadAllocator(table: *Table) std.mem.Allocator {
    return .{ .ptr = table, .vtable = &payload_allocator_vtable };
}

const payload_allocator_vtable: std.mem.Allocator.VTable = .{
    .alloc = payloadAlloc,
    .resize = std.mem.Allocator.noResize,
    .remap = std.mem.Allocator.noRemap,
    .free = std.mem.Allocator.noFree,
};

fn payloadAlloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
    _ = return_address;
    const table: *Table = @ptrCast(@alignCast(context));
    if (alignment.toByteUnits() > 16) return null;
    const payload = table.payloads.allocate(len, alignment) catch return null;
    return table.payloads.bytesOf(payload).ptr;
}

/// A payload cell's bytes as a run sees the row; empty for an absent cell or a row the run
/// cannot see.
pub fn cellPayload(table: *const Table, row: u32, field: *const FieldDescriptor) []const u8 {
    std.debug.assert(field.isPayload());
    if (!table.rowHas(row, field.bit)) return &.{};
    const cell = table.cellBytes(row, field);
    if (cell.len == 0) return &.{};
    return table.payloads.bytesOf(std.mem.bytesToValue(Payload, cell[0..@sizeOf(Payload)]));
}

/// A text cell's text as a run sees it: a string's payload, or a NUL-padded cell's bytes up
/// to the first NUL. Empty for an absent cell.
pub fn cellText(table: *const Table, row: u32, field: *const FieldDescriptor) []const u8 {
    if (field.field_type == .string) return table.cellPayload(row, field);
    if (!table.rowHas(row, field.bit)) return &.{};
    const cell = table.cellBytes(row, field);
    return std.mem.sliceTo(cell, 0);
}

/// What `setCellText` fails with: a `PayloadWriteError`, or `ValueTooLong` for text longer than a
/// fixed-size cell.
pub const TextWriteError = PayloadWriteError || error{ValueTooLong};

/// Writes a text cell, whichever way it is stored. A NUL-padded cell takes no more than its
/// size.
pub fn setCellText(table: *Table, handle: RowHandle, idx: u32, text: []const u8) TextWriteError!void {
    const fields = table.getSchema().fields;
    if (idx >= fields.len) return error.UnknownField;
    const field = &fields[idx];
    if (field.field_type == .string) return table.setPayloadByIndex(handle, idx, text);
    if (text.len > field.size) return error.ValueTooLong;
    if (!table.valid(handle)) return error.StaleHandle;
    const cell = table.writableCellBytes(handle.row, field);
    if (cell.len < field.size) return error.StaleHandle;
    @memcpy(cell[0..text.len], text);
    @memset(cell[text.len..field.size], 0);
    table.setPresent(handle.row, field.bit, true);
    table.touch();
}

/// What writing a payload cell fails with: no memory (`OutOfMemory`); a payload arena grown past
/// what a `u32` offset reaches (`Overflow`); a row that is gone (`StaleHandle`); a field the schema
/// lacks (`UnknownField`).
pub const PayloadWriteError = error{ OutOfMemory, Overflow, StaleHandle, UnknownField };

/// Writes a payload cell: appends `bytes` and points the cell at the copy. A cell that
/// already holds these bytes is left as it is, so writing the same value every frame appends
/// nothing. The cell's old bytes are dead until the table is cleared or compacted.
pub fn setPayloadByIndex(table: *Table, handle: RowHandle, idx: u32, bytes: []const u8) PayloadWriteError!void {
    const fields = table.getSchema().fields;
    if (idx >= fields.len) return error.UnknownField;
    const field = &fields[idx];
    contract.invariant(field.isPayload(), "table.payload_write.field_type");
    const current = table.getFieldByIndexConst(Payload, handle, idx) orelse return error.StaleHandle;
    const present = table.rowHas(handle.row, field.bit);
    if (present and std.mem.eql(u8, table.payloads.bytesOf(current.*), bytes)) return;
    const payload = try table.appendPayload(bytes, field.payloadAlignment());
    const cell = table.getFieldByIndex(Payload, handle, idx) orelse return error.StaleHandle;
    cell.* = payload;
    table.setPresent(handle.row, field.bit, true);
    table.touch();
}

/// Points a string cell at a copy of `text`, for code that holds the cell in a row's view:
/// a row of this table, or a run's copy of one, whose cells name this table's arena. A cell
/// already holding `text` is left as it is. The cell's presence and the table's revision are
/// the caller's, as with any write through a view.
pub fn assignString(table: *Table, cell: *String, text: []const u8) error{ OutOfMemory, Overflow }!void {
    if (std.mem.eql(u8, table.payloads.bytesOf(cell.payload), text)) return;
    cell.* = .{ .payload = try table.appendPayload(text, .@"1") };
}

/// Writes a string cell by its field's index, as `setPayloadByIndex` does. Panics when the field is
/// not a string.
pub fn setStringByIndex(table: *Table, handle: RowHandle, idx: u32, text: []const u8) PayloadWriteError!void {
    contract.invariant(idx >= table.getSchema().fields.len or table.getSchema().fields[idx].field_type == .string, "table.string_write.field_type");
    return table.setPayloadByIndex(handle, idx, text);
}

/// Writes the string cell named `name`: copies `text` into the table's arena, points the cell at
/// the copy and marks it present. `text` may be temporary. A cell already holding `text` is left as
/// it is; otherwise the old bytes are dead until the table is cleared or compacted. Panics when the
/// field is not a string.
pub fn setString(table: *Table, handle: RowHandle, name: []const u8, text: []const u8) PayloadWriteError!void {
    const idx = table.getSchema().fieldIndex(name) orelse return error.UnknownField;
    return table.setStringByIndex(handle, @intCast(idx), text);
}

/// Writes the opaque cell named `name`: copies `bytes` into the table's arena at an address aligned
/// to 16, points the cell at the copy and marks it present, as `setPayloadByIndex` does. Panics
/// when the field is not opaque bytes.
pub fn setBytes(table: *Table, handle: RowHandle, name: []const u8, bytes: []const u8) PayloadWriteError!void {
    const idx = table.getSchema().fieldIndex(name) orelse return error.UnknownField;
    contract.invariant(table.getSchema().fields[idx].field_type == .bytes, "table.bytes_write.field_type");
    return table.setPayloadByIndex(handle, @intCast(idx), bytes);
}

/// Whether a view field or an inserted value of type `T` is a slice, which a payload column
/// holds: a view reads the payload's bytes as the slice, an insert appends the slice's.
pub fn isPayloadSlice(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| pointer.size == .slice,
        else => false,
    };
}

/// The payload's bytes as a view's slice field: `[]const u8`, or `[]const T` of a `Bytes`
/// cell holding `T`s.
fn payloadSlice(table: *const Table, comptime Slice: type, payload: Payload) Slice {
    const pointer = @typeInfo(Slice).pointer;
    if (!pointer.is_const) @compileError("a view reads a payload as a const slice, not " ++ @typeName(Slice));
    const bytes = table.payloads.bytesOf(payload);
    if (pointer.child == u8 and pointer.sentinel_ptr == null) return bytes;
    if (pointer.sentinel_ptr != null) @compileError("a payload is not sentinel-terminated: " ++ @typeName(Slice));
    if (bytes.len == 0) return &.{};
    const aligned: []align(@alignOf(pointer.child)) const u8 = @alignCast(bytes);
    return std.mem.bytesAsSlice(pointer.child, aligned);
}

/// Rewrites every live payload cell into a fresh arena and drops the old one, so the arena
/// holds only what cells name, in row order. Every `Payload` read before it is invalid
/// after it, as is any saved image of a row. Not for a journaled table.
pub fn compactPayloads(table: *Table) error{ OutOfMemory, Overflow }!void {
    std.debug.assert(table.journal == null);
    if (table.payloads_pinned) return;
    var compacted: table_storage.Payloads = .{ .backing = table.payloads.backing };
    errdefer compacted.deinit();
    const fields = table.getSchema().fields;
    // Two passes, so a failed append leaves every cell naming the old arena.
    var live_bytes: usize = 0;
    var counted = table.rows();
    while (counted.next()) |handle| {
        for (fields) |*field| {
            if (!field.isPayload() or !table.rowHas(handle.row, field.bit)) continue;
            const cell: *const Payload = @ptrCast(@alignCast(table.rowCellBytes(handle.row, field).ptr));
            live_bytes += std.mem.alignForward(usize, cell.len, 16);
        }
    }
    // One chunk holds everything, so no append below can fail part way.
    try compacted.reserve(live_bytes);
    var moved = table.rows();
    while (moved.next()) |handle| {
        for (fields) |*field| {
            if (!field.isPayload()) continue;
            const cell: *Payload = @ptrCast(@alignCast(table.rowCellBytes(handle.row, field).ptr));
            // An absent cell may still name bytes from before it was removed.
            if (!table.rowHas(handle.row, field.bit)) {
                cell.* = .{};
                continue;
            }
            cell.* = compacted.append(table.payloads.bytesOf(cell.*), field.payloadAlignment()) catch unreachable;
        }
    }
    table.payloads.deinit();
    table.payloads = compacted;
    table.touch();
}

/// The table's free row ids in the order they are reused: `alloc` takes the last. Raw storage: no
/// journal sees it. Do not keep the view across a change to the table's rows.
pub fn reusableRows(table: *const Table) ReusableRows {
    return switch (table.storage) {
        .singleton => |singleton| .{ .singleton = true, .len = if (singleton.allocated) 0 else 1 },
        .columnar => |columnar| .{ .array = columnar.free_list.array, .len = columnar.free_list.len },
    };
}

/// Feeds `hash` the table's row bookkeeping: its capacity, the reusable ids in order, and every
/// id's generation, mask and liveness, dead ids included. Cell values are left out. Code that plans
/// a change against a table and applies it later compares two of these to learn whether rows were
/// made, freed or masked in between.
pub fn hashRowState(table: *const Table, hash: *std.hash.Wyhash) void {
    const capacity = table.rowCapacity();
    const reusable_capacity = table.reusableCapacity();
    hash.update(std.mem.asBytes(&capacity));
    hash.update(std.mem.asBytes(&table.required_singleton));
    hash.update(std.mem.asBytes(&reusable_capacity));
    const reusable = table.reusableRows();
    if (reusable.singleton) {
        if (reusable.len != 0) {
            const row: u32 = 0;
            hash.update(std.mem.asBytes(&row));
        }
    } else if (reusable.len != 0) {
        var cursor = reusable.array.cursor(0);
        for (0..reusable.len) |i| {
            hash.update(std.mem.asBytes(cursor.pointer()));
            if (i + 1 < reusable.len) cursor.next();
        }
    }
    if (table.isSingleton()) {
        const generation = table.rowGeneration(0);
        const mask = table.rowMask(0);
        const allocated = table.isAllocated(0);
        hash.update(std.mem.asBytes(&generation));
        hash.update(std.mem.sliceAsBytes(&mask.words));
        hash.update(std.mem.asBytes(&allocated));
        return;
    }
    var generations = table.storage.columnar.generation.first;
    while (generations) |segment| : (generations = segment.next) hash.update(std.mem.sliceAsBytes(segment.values));
    var indices = table.storage.columnar.index.first;
    while (indices) |segment| : (indices = segment.next) {
        for (segment.values) |position| {
            const mask: Mask = if (position == dead_index) .empty else positionMask(&table.storage.columnar, position);
            hash.update(std.mem.sliceAsBytes(&mask.words));
        }
    }
    indices = table.storage.columnar.index.first;
    while (indices) |segment| : (indices = segment.next) {
        for (segment.values) |position| {
            const allocated = position != dead_index;
            hash.update(std.mem.asBytes(&allocated));
        }
    }
}

/// How many ids the reusable list has room for: the row capacity.
pub fn reusableCapacity(table: *const Table) usize {
    return switch (table.storage) {
        .singleton => 1,
        .columnar => |columnar| columnar.free_list.array.len,
    };
}

/// Takes the id at `position` out of the reusable list, keeping the others in order. For the
/// journals, which reserve and return ids themselves. Raw storage; nothing to do in a singleton.
pub fn removeReusableAt(table: *Table, position: usize) void {
    if (table.isSingleton()) {
        std.debug.assert(position == 0);
        return;
    }
    const list = &table.storage.columnar.free_list;
    for (position..list.len - 1) |i| list.array.at(i).* = list.array.at(i + 1).*;
    list.len -= 1;
}

/// Puts `row` into the reusable list at `position`, keeping the others in order: the counterpart of
/// `removeReusableAt`. The id must be dead and not already in the list.
pub fn insertReusableAt(table: *Table, position: usize, row: u32) void {
    if (table.isSingleton()) {
        std.debug.assert(position == 0 and row == 0);
        return;
    }
    const list = &table.storage.columnar.free_list;
    var i = list.len;
    while (i > position) : (i -= 1) list.array.at(i).* = list.array.at(i - 1).*;
    list.array.at(position).* = row;
    list.len += 1;
}

/// Allocates the row whose id is at `position` of the reusable list, leaving the other ids' order.
/// Through an attached journal the position is ignored and the run inserts a row of its own.
/// `error.StaleRow` for a singleton's position other than 0; otherwise as `alloc`.
pub fn allocAt(table: *Table, position: usize) !RowHandle {
    // A journal reserves its own row ids; the position is the table's business once flushed.
    if (table.journal) |journal| return journal.vtable.insert(journal.context, table);
    if (table.isSingleton()) {
        if (position != 0) return error.StaleRow;
        return table.alloc();
    }
    const row = table.storage.columnar.free_list.array.at(position).*;
    table.removeReusableAt(position);
    table.storage.columnar.free_list.appendAssumeCapacity(row);
    return table.alloc();
}

/// Allocates the row with id `row`, for code that restores a table to a state it recorded.
/// `error.StaleRow` when the id is not free, `error.JournaledRowId` on a table a journal is
/// attached to.
pub fn allocRowId(table: *Table, row: u32) !RowHandle {
    // A journal chooses the ids it inserts; a chosen id is for restoring tables directly.
    if (table.journal != null) return error.JournaledRowId;
    const position = table.reusableRows().indexOf(row) orelse return error.StaleRow;
    return table.allocAt(position);
}

/// Walks a table's rows; from `Table.rows`.
pub const RowIterator = struct {
    /// The table walked.
    table: *const Table,
    /// The storage position to look at next and, past the stored rows, the run's insert.
    next_position: u32 = 0,

    /// The next row's handle; null after the last.
    pub fn next(iterator: *RowIterator) ?RowHandle {
        if (iterator.table.journal) |journal| return iterator.nextJournaled(journal);
        if (iterator.next_position >= iterator.table.count()) return null;
        const row = iterator.table.rowAtPosition(iterator.next_position);
        iterator.next_position += 1;
        return .{ .row = row, .generation = iterator.table.rowGeneration(row) };
    }

    /// The table's live rows the run did not remove, then the run's inserts.
    fn nextJournaled(iterator: *RowIterator, journal: *const Journal) ?RowHandle {
        const table: *Table = @constCast(iterator.table);
        const base_count = table.liveCount();
        while (iterator.next_position < base_count) {
            const row = table.rowAtPosition(iterator.next_position);
            iterator.next_position += 1;
            if (journal.vtable.removed(journal.context, table, row)) continue;
            return .{ .row = row, .generation = table.storedGeneration(row) };
        }
        while (true) {
            const index = iterator.next_position - base_count;
            const inserted = journal.vtable.inserted(journal.context, table, index) orelse return null;
            iterator.next_position += 1;
            if (journal.read(table, inserted) != null) return inserted;
        }
    }
};

/// An iterator over the table's rows: through an attached journal the rows its run sees (the stored
/// rows it did not remove, then its inserts), otherwise the live rows in storage order. Do not
/// allocate, free, clear or sort while walking: collect the handles first (`collectHandlesInto`).
pub fn rows(table: *const Table) RowIterator {
    return .{ .table = table };
}

/// Buffer must fit all live rows. Collect before structural mutation; do not
/// retain queries or field pointers across structural mutations.
pub fn collectHandlesInto(table: *const Table, buffer: []RowHandle) []RowHandle {
    var iterator = table.rows();
    var count_rows: usize = 0;
    while (iterator.next()) |handle| {
        buffer[count_rows] = handle;
        count_rows += 1;
    }
    return buffer[0..count_rows];
}

/// Buffer must fit all matching rows; preserves the query's field-mask filter.
pub fn collectQueryHandlesInto(table: *Table, comptime View: type, buffer: []RowHandle) []RowHandle {
    var query_rows = table.query(View);
    var count_rows: usize = 0;
    while (query_rows.next()) |row| {
        buffer[count_rows] = row.handle;
        count_rows += 1;
    }
    return buffer[0..count_rows];
}

const ChunkLayout = struct {
    /// The whole chunk's layout.
    layout: table_storage.Layout = .{},
    /// Offset of the columns' array descriptors, used by the first chunk.
    columns: usize,
    /// Offset of the mask words' segment descriptor.
    masks: usize,
    /// Offset of the generations' segment descriptor.
    generations: usize,
    /// Offset of the positions' segment descriptor.
    indices: usize,
    /// Offset of the row ids' segment descriptor.
    ids: usize,
    /// Offset of the free list's segment descriptor.
    free: usize,
    /// Offset of each field's cells.
    fields: [Mask.max_bits]usize = undefined,
    fn init(schema: *const Schema, chunk_rows: usize) !ChunkLayout {
        var layout: table_storage.Layout = .{};
        const columns = try layout.appendArray(table_storage.Array(u8), schema.fields.len);
        const masks = try layout.appendArray(table_storage.Array(u64).Segment, 1);
        const generations = try layout.appendArray(RowArray.Segment, 1);
        const indices = try layout.appendArray(RowArray.Segment, 1);
        const ids = try layout.appendArray(RowArray.Segment, 1);
        const free_descriptor = try layout.appendArray(RowArray.Segment, 1);
        var result: ChunkLayout = .{ .columns = columns, .masks = masks, .generations = generations, .indices = indices, .ids = ids, .free = free_descriptor };
        _ = try layout.appendArray(table_storage.Array(u8).Segment, schema.fields.len);
        _ = try layout.appendArray(u64, try std.math.mul(usize, chunk_rows, schema.maskWords()));
        _ = try layout.appendArray(u32, chunk_rows * 4);
        for (schema.fields, 0..) |field, i| result.fields[i] = try layout.append(try std.math.mul(usize, chunk_rows, field.stride), .@"16");
        result.layout = layout;
        return result;
    }
};

/// Makes room for at least `minimum` row ids, in whole chunks, so that many rows allocate without
/// failing. Never shrinks, and leaves a singleton as it is. `error.OutOfMemory` or
/// `error.Overflow`; a failure keeps the chunks reserved before it. It checks neither an open init
/// admission nor the table's memory scope: `Registry.grow` and `Registry.reserveRows` do.
pub fn reserveCapacity(table: *Table, minimum: u32) !void {
    if (table.isSingleton()) return;
    const columnar = &table.storage.columnar;
    const original_capacity = columnar.capacity;
    // A failed multi-page reserve retains already published chunks too.
    defer {
        const added = columnar.capacity - original_capacity;
        if (added != 0) {
            columnar.free_list.array.copyBackwards(added, 0, columnar.free_list.len);
            var cursor = columnar.free_list.array.cursor(0);
            for (0..added) |i| {
                cursor.pointer().* = columnar.capacity - 1 - @as(u32, @intCast(i));
                if (i + 1 < added) cursor.next();
            }
            columnar.free_list.len += added;
        }
    }
    while (columnar.capacity < minimum) {
        const schema = table.getSchema();
        std.debug.assert(columnar.mask_words == schema.maskWords());
        // Row access walks the chunks, so their count must stay logarithmic in the rows:
        // each chunk covers the request and a quarter of the table, not just one page.
        const remaining_rows = std.math.maxInt(u32) - columnar.capacity;
        const wanted_rows = @max(minimum - columnar.capacity, @min(columnar.capacity / 4, remaining_rows));
        const wanted = try ChunkLayout.init(schema, wanted_rows);
        const page = std.heap.pageSize();
        const bytes_needed = try std.math.add(usize, table_storage.Arena.headerBytes(), wanted.layout.size);
        const page_bytes = std.mem.alignForward(usize, bytes_needed, page);
        var low: usize = 1;
        var high: usize = page_bytes / 24 + 1;
        while (low < high) {
            const mid = low + (high - low + 1) / 2;
            const candidate = try ChunkLayout.init(schema, mid);
            if (candidate.layout.size <= page_bytes - table_storage.Arena.headerBytes()) low = mid else high = mid - 1;
        }
        const chunk_rows: u32 = @intCast(@min(low, remaining_rows));
        const new_capacity = try std.math.add(u32, columnar.capacity, chunk_rows);
        const chunk_layout = try ChunkLayout.init(schema, chunk_rows);
        const bytes = try columnar.arena.allocate(chunk_layout.layout.size);
        @memset(bytes, 0);
        const columns = Registry.slice(table_storage.Array(u8), bytes, chunk_layout.columns, schema.fields.len);
        for (columns) |*column| column.* = .{};
        const mask_segment = &Registry.slice(table_storage.Array(u64).Segment, bytes, chunk_layout.masks, 1)[0];
        const generation_segment = &Registry.slice(RowArray.Segment, bytes, chunk_layout.generations, 1)[0];
        const index_segment = &Registry.slice(RowArray.Segment, bytes, chunk_layout.indices, 1)[0];
        const id_segment = &Registry.slice(RowArray.Segment, bytes, chunk_layout.ids, 1)[0];
        const free_segment = &Registry.slice(RowArray.Segment, bytes, chunk_layout.free, 1)[0];
        var layout: table_storage.Layout = .{ .size = chunk_layout.free + @sizeOf(RowArray.Segment) };
        const field_segments_offset = try layout.appendArray(table_storage.Array(u8).Segment, schema.fields.len);
        const mask_word_count = @as(usize, chunk_rows) * columnar.mask_words;
        const masks_offset = try layout.appendArray(u64, mask_word_count);
        const generation_offset = try layout.appendArray(u32, chunk_rows);
        const index_offset = try layout.appendArray(u32, chunk_rows);
        const id_offset = try layout.appendArray(u32, chunk_rows);
        const free_offset = try layout.appendArray(u32, chunk_rows);
        mask_segment.* = .{ .values = Registry.slice(u64, bytes, masks_offset, mask_word_count) };
        generation_segment.* = .{ .values = Registry.slice(u32, bytes, generation_offset, chunk_rows) };
        index_segment.* = .{ .values = Registry.slice(u32, bytes, index_offset, chunk_rows) };
        @memset(index_segment.values, dead_index);
        id_segment.* = .{ .values = Registry.slice(u32, bytes, id_offset, chunk_rows) };
        free_segment.* = .{ .values = Registry.slice(u32, bytes, free_offset, chunk_rows) };
        const field_segments = Registry.slice(table_storage.Array(u8).Segment, bytes, field_segments_offset, schema.fields.len);
        for (schema.fields, field_segments, 0..) |field, *segment, i| segment.* = .{ .values = bytes[chunk_layout.fields[i]..][0 .. chunk_rows * field.stride] };
        // Publish only fully initialized descriptors. All persisted pointers refer to pages.
        if (columnar.capacity == 0) columnar.columns = columns;
        for (columnar.columns, field_segments) |*column, *segment| column.append(segment);
        columnar.bitmask.append(mask_segment);
        columnar.generation.append(generation_segment);
        columnar.index.append(index_segment);
        columnar.row_id.append(id_segment);
        columnar.free_list.array.append(free_segment);
        columnar.capacity = new_capacity;
        table.touch();
    }
}

/// Bumps `revision`: for code that changed cells through pointers and wants the table to read as
/// changed.
pub fn touch(table: *Table) void {
    table.revision +%= 1;
}

/// A new row holding no cell, its bytes zeroed. A columnar table grows when no id is free; a
/// singleton that has its row fails with `error.TableFull`. Through an attached journal the row is
/// the run's, and the journal's errors are returned (`Journal.VTable.insert`). Otherwise
/// `error.OutOfMemory` or `error.Overflow`. Views, iterators and cell pointers read before the call
/// are no longer good.
pub fn alloc(table: *Table) !RowHandle {
    if (table.journal) |journal| return journal.vtable.insert(journal.context, table);
    if (table.storage == .singleton) {
        const singleton = &table.storage.singleton;
        if (singleton.allocated) return error.TableFull;
        singleton.generation +%= 1;
        singleton.bitmask = .empty;
        for (singleton.columns) |column| @memset(column, 0);
        singleton.allocated = true;
        table.touch();
        return .{ .row = 0, .generation = singleton.generation };
    }
    if (table.storage.columnar.free_list.len == 0) try table.reserveCapacity(table.rowCapacity() + 1);
    const row = table.storage.columnar.free_list.pop().?;
    table.restoreRowState(row, table.rowGeneration(row) +% 1, .empty, true);
    table.touch();
    return .{ .row = row, .generation = table.storage.columnar.generation.at(row).* };
}

/// Reorders a columnar table's live rows so the `u32` field `field_index` ascends, keeping
/// the order of rows with equal keys; a row without the cell sorts as 0. Rows keep their
/// handles: only iteration and `rowAtPosition` see the new order. For a table whose readers
/// walk it in order, outside any run. Cheap when it is already nearly in order.
pub fn sortByU32(table: *Table, field_index: u32) void {
    std.debug.assert(table.journal == null);
    if (table.storage != .columnar) return;
    const columnar = &table.storage.columnar;
    const field = &table.getSchema().fields[field_index];
    std.debug.assert(field.size == @sizeOf(u32));
    const live = columnar.live_count;
    var index: u32 = 1;
    while (index < live) : (index += 1) {
        var at = index;
        while (at > 0 and table.positionKey(at - 1, field) > table.positionKey(at, field)) : (at -= 1) {
            table.swapPositions(at - 1, at);
        }
    }
}

fn positionKey(table: *const Table, position: u32, field: *const FieldDescriptor) u32 {
    const columnar = &table.storage.columnar;
    if (!positionMask(columnar, position).has(field.bit)) return 0;
    return std.mem.readInt(u32, table.physicalCell(position, field)[0..4], builtin_endian);
}

const builtin_endian = @import("builtin").cpu.arch.endian();

/// Exchanges the rows at two physical positions, their ids following them.
fn swapPositions(table: *Table, first: u32, second: u32) void {
    const columnar = &table.storage.columnar;
    for (table.getSchema().fields) |*field| {
        const a = table.physicalCell(first, field);
        const b = table.physicalCell(second, field);
        for (a, b) |*x, *y| std.mem.swap(u8, x, y);
    }
    const first_mask = positionMaskWords(columnar, first);
    const second_mask = positionMaskWords(columnar, second);
    for (first_mask, second_mask) |*x, *y| std.mem.swap(u64, x, y);
    const first_id = columnar.row_id.at(first).*;
    const second_id = columnar.row_id.at(second).*;
    columnar.row_id.at(first).* = second_id;
    columnar.row_id.at(second).* = first_id;
    columnar.index.at(first_id).* = second;
    columnar.index.at(second_id).* = first;
}

fn removePhysicalRow(table: *Table, row: u32) void {
    const columnar = &table.storage.columnar;
    const position = columnar.index.at(row).*;
    std.debug.assert(position != dead_index);
    const last = columnar.live_count - 1;
    if (position != last) {
        for (table.getSchema().fields) |*field| {
            @memcpy(table.physicalCell(position, field), table.physicalCell(last, field));
        }
        @memcpy(positionMaskWords(columnar, position), positionMaskWords(columnar, last));
        const moved_id = columnar.row_id.at(last).*;
        columnar.row_id.at(position).* = moved_id;
        columnar.index.at(moved_id).* = position;
    }
    columnar.index.at(row).* = dead_index;
    columnar.live_count = last;
}

/// Frees a row: its handle and every copy of it go stale, the last row moves into its position, and
/// its payload bytes are dead until the table is cleared or compacted. A stale handle does nothing,
/// nor does any handle of a required singleton (`Registry.ensureSingleton`). Through an attached
/// journal the row is removed for the run.
pub fn free(table: *Table, handle: RowHandle) void {
    if (table.required_singleton) return;
    if (table.journal) |journal| return journal.vtable.remove(journal.context, table, handle);
    if (!table.valid(handle)) return;
    if (table.storage == .singleton) {
        table.storage.singleton.bitmask = .empty;
        table.storage.singleton.allocated = false;
        table.storage.singleton.generation +%= 1;
    } else {
        table.removePhysicalRow(handle.row);
        table.storage.columnar.generation.at(handle.row).* +%= 1;
        table.storage.columnar.free_list.appendAssumeCapacity(handle.row);
    }
    table.touch();
}

/// Whether `handle` still names a live row: as the run sees it through an attached journal,
/// otherwise in the table's storage.
pub fn valid(table: *const Table, handle: RowHandle) bool {
    if (table.journal) |journal| return journal.read(@constCast(table), handle) != null;
    return table.isAllocated(handle.row) and table.rowGeneration(handle.row) == handle.generation;
}

/// Frees every row, keeping the capacity: every handle goes stale, and the payload arena is emptied
/// unless it is pinned (`pinPayloads`). Through an attached journal the rows the run sees are
/// removed for the run, and the arena is left for `Registry.reclaimPayloads`. A required singleton
/// is left as it is.
pub fn clear(table: *Table) void {
    if (table.required_singleton) return;
    if (table.journal) |journal| return journal.vtable.clear(journal.context, table);
    if (table.storage == .singleton) {
        table.storage.singleton.bitmask = .empty;
        table.storage.singleton.allocated = false;
        table.storage.singleton.generation +%= 1;
        if (!table.payloads_pinned) table.payloads.reset();
        table.touch();
        return;
    }
    if (!table.payloads_pinned) table.payloads.reset();
    const columnar = &table.storage.columnar;
    // Walk each linked array once: clear is used every frame by large
    // transient tables, so resolving each slot from the head is quadratic.
    var masks = columnar.bitmask.first;
    while (masks) |segment| : (masks = segment.next) @memset(segment.values, 0);
    var indices = columnar.index.first;
    while (indices) |segment| : (indices = segment.next) @memset(segment.values, dead_index);
    var generations = columnar.generation.first;
    while (generations) |segment| : (generations = segment.next) {
        for (segment.values) |*generation| generation.* +%= 1;
    }
    columnar.live_count = 0;
    var row = table.rowCapacity();
    var reusable = columnar.free_list.array.first;
    while (reusable) |segment| : (reusable = segment.next) {
        for (segment.values) |*id| {
            row -= 1;
            id.* = row;
        }
    }
    columnar.free_list.len = table.rowCapacity();
    table.touch();
}

/// How many rows the table has: as the run sees them through an attached journal, otherwise the
/// live rows in storage.
pub fn count(table: *const Table) u32 {
    if (table.journal) |journal| return journal.vtable.count(journal.context, @constCast(table));
    return table.liveCount();
}

/// The rows live in the table's own storage, whatever a journal holds.
pub fn liveCount(table: *const Table) u32 {
    return switch (table.storage) {
        .singleton => |singleton| @intFromBool(singleton.allocated),
        .columnar => |columnar| columnar.live_count,
    };
}

/// Whether row id `row` names a live row, whatever its generation: as the run sees it through an
/// attached journal, otherwise in storage. False for an id past the capacity.
pub fn isAllocated(table: *const Table, row: u32) bool {
    if (table.journal) |journal| return journal.generation(@constCast(table), row) != null;
    return row < table.rowCapacity() and switch (table.storage) {
        .singleton => |*singleton| singleton.allocated,
        .columnar => |*columnar| columnar.index.at(row).* != dead_index,
    };
}

/// A pointer to the cell named `name` of `handle`'s row, to read or write; null for a name the
/// schema lacks or a stale handle. `@sizeOf(T)` must be the field's size, or the call panics. The
/// row's mask is neither read nor changed: an absent cell is returned like any other, and writing
/// does not make it present (`setPresent`, `writeFieldSingle`). Through an attached journal the row
/// is copied into the run's layer; `getFieldByIndexConst` reads without copying. Good until the
/// table's rows change.
pub fn getField(table: *Table, comptime T: type, handle: RowHandle, name: []const u8) ?*T {
    const idx = table.getSchema().fieldIndex(name) orelse return null;
    return table.getFieldByIndex(T, handle, @intCast(idx));
}

/// As `getField`, the field by its index in the schema; null for an index past the fields.
pub fn getFieldByIndex(table: *Table, comptime T: type, handle: RowHandle, idx: u32) ?*T {
    if (table.journal) |journal| {
        const place = journal.access(table, handle) orelse return null;
        return place.table.storedField(T, place.row, idx);
    }
    if (!table.valid(handle)) return null;
    return table.storedField(T, handle.row, idx);
}

/// A live row's field in the table's own storage, whatever a journal holds.
fn storedField(table: *const Table, comptime T: type, row: u32, idx: u32) ?*T {
    const fields = table.getSchema().fields;
    if (idx >= fields.len) return null;
    const desc = fields[idx];
    contract.invariant(@sizeOf(T) == desc.size, "table.field.access_type_size");
    contract.invariant(desc.column_index < table.getSchema().fields.len, "table.field.access_column_index");
    const bytes = table.rowCellBytes(row, &desc);
    return @ptrCast(@alignCast(bytes.ptr));
}

/// As `getFieldByIndex`, to read only: through an attached journal the cell is read where the run
/// sees it and the row is not copied into the run's layer.
pub fn getFieldByIndexConst(table: *const Table, comptime T: type, handle: RowHandle, idx: u32) ?*const T {
    if (table.journal) |journal| {
        const place = journal.read(@constCast(table), handle) orelse return null;
        return place.table.storedField(T, place.row, idx);
    }
    if (!table.valid(handle)) return null;
    return table.storedField(T, handle.row, idx);
}

/// An iterator over the rows that hold every field `View` names, each with a view of its cells.
/// `View` is a struct whose fields are named for the table's: a `*T` points at the cell, and a
/// const slice reads a payload cell (`[]const u8`, or `[]const T` of a `Bytes` cell). Panics when
/// `View` names a field the schema lacks, or a `T` whose size is not the field's. A row that lacks
/// any of the cells is skipped. Through an attached journal each row handed out is copied into the
/// run's layer, so a caller that only reads uses `readQuery`.
pub fn query(table: *Table, comptime View: type) Query(View) {
    return Query(View).init(table);
}

/// As `query`, for a caller that only reads: through an attached journal the rows are
/// looked up where the run sees them and never copied into its overlay, as a query of a
/// table attached for writing does with every row it hands out.
pub fn readQuery(table: *Table, comptime View: type) ReadQuery(View) {
    return .{ .inner = Query(View).init(table) };
}

/// As `getRow`, read-only and without copying the row into a run's overlay.
pub fn readRow(table: *Table, handle: RowHandle, comptime View: type) ?ReadView(View) {
    if (table.journal) |journal| {
        const place = journal.read(table, handle) orelse return null;
        const found = place.table.storedRow(place.row, View, table);
        return readViewOf(View, found);
    }
    if (!table.valid(handle)) return null;
    const found = table.storedRow(handle.row, View, table);
    return readViewOf(View, found);
}

/// A view of `handle`'s row, as `query` gives; null for a stale handle. Unlike a query it does not
/// read the row's mask: a pointer to an absent cell is returned like any other, and a slice of an
/// absent payload cell is whatever the cell last named. Writing through the pointers neither marks
/// a cell present nor bumps `revision`. Through an attached journal the row is copied into the
/// run's layer; `readRow` does not copy.
pub fn getRow(table: *Table, handle: RowHandle, comptime View: type) ?View {
    if (table.journal) |journal| {
        const place = journal.access(table, handle) orelse return null;
        return place.table.storedRow(place.row, View, table);
    }
    if (!table.valid(handle)) return null;
    return table.storedRow(handle.row, View, table);
}

/// A live row's view in the table's own storage, whatever a journal holds. `payload_owner`
/// is the table whose arena the row's payload cells name: this table, or the table a journal
/// layer's overlay table covers. A view's slice field reads a payload cell's bytes there.
pub fn storedRow(table: *Table, row: u32, comptime View: type, payload_owner: *const Table) View {
    const position = table.rowPosition(row);
    const schema = table.getSchema();
    var view: View = undefined;
    inline for (std.meta.fields(View)) |vf| {
        const idx_opt = schema.fieldIndex(vf.name);
        contract.invariant(idx_opt != null, "table.row_view.field_exists");
        const idx = idx_opt.?;
        const field = &schema.fields[idx];
        contract.invariant(field.column_index < schema.fields.len, "table.field.access_column_index");
        const bytes = table.physicalCell(position, field);
        @field(view, vf.name) = payload_owner.viewField(vf.type, field, bytes);
    }
    return view;
}

/// A view's field of type `Field` for the cell `bytes` of `field`: a pointer to the cell, or
/// for a slice the bytes of the payload the cell names in this table's arena.
fn viewField(table: *const Table, comptime Field: type, field: *const FieldDescriptor, bytes: []u8) Field {
    if (comptime isPayloadSlice(Field)) {
        contract.invariant(field.isPayload(), "table.view.slice_of_payload_field");
        const cell: *const Payload = @ptrCast(@alignCast(bytes.ptr));
        return table.payloadSlice(Field, cell.*);
    }
    const Child = @typeInfo(Field).pointer.child;
    contract.invariant(@sizeOf(Child) == field.size, "table.field.access_type_size");
    return @ptrCast(@alignCast(bytes.ptr));
}

/// As `tryInsert`, panicking where that fails. For a table whose rows are known to fit; a row
/// carrying slices, which need payload memory, is better inserted with `tryInsert`.
pub fn insert(table: *Table, values: anytype) RowHandle {
    return table.tryInsert(values) catch {
        contract.invariant(false, "table.insert.capacity");
        unreachable;
    };
}

/// A new row holding the cells `values` names and no other. `values` is a struct, usually
/// anonymous, whose fields are named for the table's: each value is copied into its cell, and its
/// type's size must be the field's. A slice value goes to a payload field: its bytes are copied
/// into the table's arena, so it may be temporary. Panics on a name the schema lacks or a value of
/// the wrong size. Fails as `alloc` does, or with a `PayloadWriteError` for a slice, and then
/// leaves no row behind.
pub fn tryInsert(table: *Table, values: anytype) !RowHandle {
    const handle = try table.alloc();
    inline for (std.meta.fields(@TypeOf(values))) |vf| {
        const idx_opt = table.getSchema().fieldIndex(vf.name);
        contract.invariant(idx_opt != null, "table.insert.field_exists");
        const idx = idx_opt.?;
        if (comptime isPayloadSlice(vf.type)) {
            // The row is new: nothing else names it if the payload cannot be appended.
            errdefer table.free(handle);
            const slice_bytes = std.mem.sliceAsBytes(@field(values, vf.name));
            try table.setPayloadByIndex(handle, @intCast(idx), slice_bytes);
        } else {
            table.getFieldByIndex(vf.type, handle, @intCast(idx)).?.* = @field(values, vf.name);
        }
    }
    table.setRowMask(handle, values);
    return handle;
}

/// Marks present, in `handle`'s row, every field the struct type of `view` names; the fields'
/// values are not read. Cells already present stay so. Panics on a stale handle or a name the
/// schema lacks.
pub fn setRowMask(table: *Table, handle: RowHandle, view: anytype) void {
    contract.invariant(table.valid(handle), "table.row_mask.valid_handle");
    var m: Mask = .empty;
    inline for (std.meta.fields(@TypeOf(view))) |vf| {
        const idx_opt = table.getSchema().fieldIndex(vf.name);
        contract.invariant(idx_opt != null, "table.row_mask.field_exists");
        const idx = idx_opt.?;
        m.set(table.getSchema().fields[idx].bit);
    }
    table.setMask(handle.row, table.rowMask(handle.row).merge(m));
    table.touch();
}

/// Writes `value` into the cell named `name` and marks it present. `error.UnknownField` for a name
/// the schema lacks, `error.StaleHandle` for a row that is gone; panics when `@sizeOf(T)` is not
/// the field's size.
pub fn writeFieldSingle(table: *Table, comptime T: type, handle: RowHandle, comptime name: []const u8, value: T) !void {
    const idx = table.getSchema().fieldIndex(name) orelse return error.UnknownField;
    const ptr = table.getFieldByIndex(T, handle, @intCast(idx)) orelse return error.StaleHandle;
    ptr.* = value;
    table.setPresent(handle.row, table.getSchema().fields[idx].bit, true);
    table.touch();
}

/// Copies `bytes`, exactly the field's size, into the cell of field `idx` and marks it present, for
/// code that holds a value as bytes. Panics on a wrong length; without a journal also on a stale
/// handle or an index past the fields. Through an attached journal a row the run cannot see is left
/// alone, and `revision` is not bumped.
pub fn writeFieldRawByIndex(table: *Table, handle: RowHandle, idx: u32, bytes: []const u8) void {
    if (table.journal) |journal| {
        const place = journal.access(table, handle) orelse return;
        const desc = place.table.getSchema().fields[idx];
        contract.invariant(bytes.len == desc.stride, "table.raw_write.byte_length");
        @memcpy(place.table.rowCellBytes(place.row, &desc), bytes);
        var copied = place.table.storedMask(place.row);
        copied.set(desc.bit);
        return place.table.setStoredMask(place.row, copied);
    }
    contract.invariant(table.valid(handle), "table.raw_write.valid_handle");
    const fields = table.getSchema().fields;
    contract.invariant(idx < fields.len, "table.raw_write.field_index");
    const desc = fields[idx];
    contract.invariant(bytes.len == desc.stride, "table.raw_write.byte_length");
    contract.invariant(desc.column_index < table.getSchema().fields.len, "table.raw_write.column_index");
    @memcpy(table.rowCellBytes(handle.row, &desc), bytes);
    table.setPresent(handle.row, desc.bit, true);
    table.touch();
}

/// Marks the cell of field `idx` present without writing it: how a tag is set. Panics on a stale
/// handle or an index past the fields.
pub fn setFieldPresent(table: *Table, handle: RowHandle, idx: u32) void {
    contract.invariant(table.valid(handle), "table.field_present.valid_handle");
    const fields = table.getSchema().fields;
    contract.invariant(idx < fields.len, "table.field_present.field_index");
    table.setPresent(handle.row, fields[idx].bit, true);
    table.touch();
}

/// `View`, a struct of pointers to a row's fields, with every pointer read-only.
pub fn ReadView(comptime View: type) type {
    const fields = std.meta.fields(View);
    var types: [fields.len]type = undefined;
    // A slice field reads a payload and is read-only as it is.
    for (fields, &types) |field, *field_type| field_type.* = if (isPayloadSlice(field.type)) field.type else *const @typeInfo(field.type).pointer.child;
    return @Struct(.auto, null, std.meta.fieldNames(View), &types, &@splat(.{}));
}

/// `view` with every pointer made read-only.
pub fn readViewOf(comptime View: type, view: View) ReadView(View) {
    var result: ReadView(View) = undefined;
    // Field by field: the names are compile-time.
    inline for (std.meta.fields(View)) |field| @field(result, field.name) = @field(view, field.name);
    return result;
}

/// A query that only reads; see `Table.readQuery`.
pub fn ReadQuery(comptime View: type) type {
    return struct {
        /// The query underneath.
        inner: Query(View),

        const Self = @This();

        /// The next row holding every field of `View`, with a read-only view of it; null after the
        /// last.
        pub fn next(q: *Self) ?struct { handle: Table.RowHandle, view: ReadView(View) } {
            if (q.inner.journaled) |*journaled_rows| {
                while (journaled_rows.next()) |handle| {
                    if (!q.inner.table.rowMask(handle.row).containsAll(q.inner.required_mask)) continue;
                    const view = q.inner.table.readRow(handle, View) orelse continue;
                    return .{ .handle = handle, .view = view };
                }
                return null;
            }
            const found = q.inner.next() orelse return null;
            return .{ .handle = found.handle, .view = readViewOf(View, found.view) };
        }
    };
}

/// The iterator `Table.query` returns: it walks the rows that hold every field `View` names. Its
/// fields are its own state.
pub fn Query(comptime View: type) type {
    const view_fields = std.meta.fields(View);
    return struct {
        /// The table queried.
        table: *Table,
        /// The bits of `View`'s fields: a row must hold them all.
        required_mask: Mask,
        /// The first nonzero word of `required_mask`. A view whose fields share one word tests only it.
        primary: RequiredWord = .{ .word = 0, .bits = 0 },
        /// The other nonzero words, for views whose fields span words.
        others: [Mask.max_words - 1]RequiredWord = undefined,
        /// How many of `others` are in use.
        other_count: u8 = 0,
        /// The table's mask words per row.
        mask_words: u8 = 1,
        /// Rows in the current chunk, cached so the per-row chunk test does not divide.
        chunk_rows: u32 = 0,
        /// The storage position to look at next.
        position: u32 = 0,
        /// The schema index of each of `View`'s fields.
        field_indices: [view_fields.len]u32 = undefined,
        /// The chunk of mask words that `position` is in.
        mask_segment: ?*table_storage.Array(u64).Segment = null,
        /// The chunk of row ids that `position` is in.
        id_segment: ?*table_storage.Array(u32).Segment = null,
        /// For each of `View`'s fields, the chunk of cells that `position` is in.
        field_segments: [view_fields.len]?*table_storage.Array(u8).Segment = @splat(null),
        /// The position of the current chunk's first row.
        chunk_start: u32 = 0,
        /// A journaled table's rows as its run sees them, in place of its storage.
        journaled: ?Table.RowIterator = null,

        const Self = @This();
        const RequiredWord = struct { word: u8, bits: u64 };

        /// Starts a query of `table`. Panics when `View` names a field the schema lacks.
        pub fn init(table: *Table) Self {
            var q: Self = .{ .table = table, .required_mask = .empty };
            if (table.journal != null) q.journaled = table.rows();
            inline for (view_fields, 0..) |vf, i| {
                const idx_opt = table.getSchema().fieldIndex(vf.name);
                contract.invariant(idx_opt != null, "table.query.field_exists");
                const idx = idx_opt.?;
                q.field_indices[i] = @intCast(idx);
                q.required_mask.set(table.getSchema().fields[idx].bit);
            }
            var found_primary = false;
            for (q.required_mask.words, 0..) |bits, word| {
                if (bits == 0) continue;
                const required: RequiredWord = .{ .word = @intCast(word), .bits = bits };
                if (!found_primary) {
                    q.primary = required;
                    found_primary = true;
                } else {
                    q.others[q.other_count] = required;
                    q.other_count += 1;
                }
            }
            if (!table.isSingleton()) {
                q.mask_words = table.storage.columnar.mask_words;
                q.mask_segment = table.storage.columnar.bitmask.first;
                q.chunk_rows = q.chunkRows();
                q.id_segment = table.storage.columnar.row_id.first;
                inline for (0..view_fields.len) |i| {
                    const field = table.getSchema().fields[q.field_indices[i]];
                    q.field_segments[i] = table.storage.columnar.columns[field.column_index].first;
                }
            }
            return q;
        }

        fn chunkRows(q: *const Self) u32 {
            return @intCast(q.mask_segment.?.values.len / q.mask_words);
        }

        fn holdsRequired(q: *const Self, offset: u32) bool {
            const values = q.mask_segment.?.values;
            // Tables of 64 fields or fewer, the common case, keep the single-word test of a one-word mask.
            if (q.mask_words == 1) return values[offset] & q.primary.bits == q.primary.bits;
            const first_word = @as(usize, offset) * q.mask_words;
            if (values[first_word + q.primary.word] & q.primary.bits != q.primary.bits) return false;
            for (q.others[0..q.other_count]) |required| {
                if (values[first_word + required.word] & required.bits != required.bits) return false;
            }
            return true;
        }

        /// The next row holding every field of `View`, with its handle and a view of its cells;
        /// null after the last. Through an attached journal each row handed out is copied into the
        /// run's layer, as `getRow` does. The view's pointers and the query itself are no longer
        /// good once the table's rows are allocated, freed, cleared or sorted.
        pub fn next(q: *Self) ?struct { handle: Table.RowHandle, view: View } {
            if (q.journaled) |*journaled_rows| {
                while (journaled_rows.next()) |handle| {
                    if (!q.table.rowMask(handle.row).containsAll(q.required_mask)) continue;
                    const view = q.table.getRow(handle, View) orelse continue;
                    return .{ .handle = handle, .view = view };
                }
                return null;
            }
            while (q.position < q.table.count()) : (q.position += 1) {
                if (q.table.isSingleton()) {
                    if (!q.table.rowMask(0).containsAll(q.required_mask)) continue;
                    const handle: Table.RowHandle = .{ .row = 0, .generation = q.table.rowGeneration(0) };
                    q.position += 1;
                    return .{ .handle = handle, .view = q.table.getRow(handle, View).? };
                }
                while (q.position - q.chunk_start >= q.chunk_rows) {
                    q.chunk_start += q.chunk_rows;
                    q.mask_segment = q.mask_segment.?.next;
                    q.id_segment = q.id_segment.?.next;
                    inline for (0..view_fields.len) |i| q.field_segments[i] = q.field_segments[i].?.next;
                    q.chunk_rows = q.chunkRows();
                }
                const offset = q.position - q.chunk_start;
                if (!q.holdsRequired(offset)) continue;
                const row = q.id_segment.?.values[offset];
                const handle: Table.RowHandle = .{ .row = row, .generation = q.table.rowGeneration(row) };
                var view: View = undefined;
                inline for (view_fields, 0..) |vf, i| {
                    const field = &q.table.getSchema().fields[q.field_indices[i]];
                    const bytes = q.field_segments[i].?.values[@as(usize, offset) * field.stride ..][0..field.stride];
                    @field(view, vf.name) = q.table.viewField(vf.type, field, bytes);
                }
                q.position += 1;
                return .{ .handle = handle, .view = view };
            }
            return null;
        }
    };
}

/// Names a table in its `Registry`: a slot, and the generation the slot had when the table was
/// made. Stale once the table is destroyed (`Registry.valid`); a replaced table keeps its handle.
pub const Handle = extern struct {
    /// The table's slot.
    index: u32,
    /// The slot's generation when the table was made.
    generation: u32,
};

/// Owns every table and every schema. The host makes the one registry, at an address it keeps
/// (`init`), and hands plugins a pointer to it. Tables are created, found, grown, replaced and
/// destroyed through it, each named by an atom no other live table has. Nothing in it locks: it is
/// the sim thread's.
pub const Registry = struct {
    /// The pages of tables in no memory scope, from Memory's page source.
    pages: memory_mod.PageBacking,
    /// Counts what happened that the next frame may act on: a command sent, an event
    /// published, a message delivered, a system's run changing what it shows. The host
    /// compares it across frames to tell whether there is work, and sleeps while there is
    /// none. Only ever increased.
    activity: u64 = 0,
    /// The systems a frame's runs have come to so far, run or not: where a system's
    /// subscriptions go among everyone's (`sequencer.ensureSubscriptions`). The host zeroes
    /// it as each frame's runs begin.
    systems_visited: u32 = 0,
    /// Singletons in no memory scope, in `pages`.
    singleton_arena: memory_mod.Arena,
    /// Replacements prepared and not yet committed or aborted.
    preparations: usize = 0,
    /// The owner given to each table created (`Table.owner`). Code that makes tables on another's
    /// behalf sets it and puts back what it found.
    scope: Table.Owner = .host,

    /// The host's memory: the scopes' backings, and the allocator of the registry's own
    /// bookkeeping.
    memory: *memory_mod.Memory,
    /// Each slot's table record. One whose `allocated` is false holds no table.
    slots: []*Table,
    /// Each slot's generation, bumped when a table is made in the slot and when it is destroyed.
    generation: []u32,
    /// Whether each slot holds a live table.
    allocated: []bool,
    /// The free slots; the last is taken first.
    free_list: std.ArrayListUnmanaged(u32) = .empty,
    /// The length of `slots`, `generation` and `allocated`. It grows as tables are created.
    capacity: u32,
    /// Real length of the slot arrays and count of created records. `slots`, `generation`
    /// and `allocated` are `capacity` long; abort shrinks them without losing stale-handle
    /// generations. Records keep their addresses as the arrays grow.
    reserved_slots: u32,
    /// The schemas, by name.
    schemas: Table.SchemaRegistry,
    /// The open init admission's snapshot; null when none is open.
    admission: ?Admission = null,
    /// The number of the last admission begun, which its token carries.
    admission_generation: u64 = 0,

    /// The token of an open init admission: a checkpoint of which tables and schemas exist, taken
    /// by `beginInitAdmission` so that an initialization that fails part-way can be undone. While
    /// one is open, tables may be created, and `abortInitAdmission` destroys them; registering or
    /// unregistering a schema and preparing a replacement are refused
    /// (`error.AdmissionMutationRejected`); destroying or growing a table that was there before
    /// rejects the admission, which then only aborts. Rows are not checkpointed: what is written
    /// into a table that was there before stays written after an abort, so write those once the
    /// admission is committed. One is open at a time.
    pub const InitAdmission = struct { tables: *Registry, generation: u64 };
    const SchemaBinding = struct { name: Atom, record: *Table.SchemaRegistry.Record };
    const Admission = struct {
        /// The admission's number, which its token must match.
        generation: u64,
        /// The registry's `capacity` when the admission began.
        capacity: u32,
        /// Each slot's generation when the admission began.
        generations: []u32,
        /// Which slots held a table when the admission began.
        allocated: []bool,
        /// The free slots, in order, when the admission began.
        free: []u32,
        /// The record under each schema name when the admission began, each held by a count.
        bindings: []SchemaBinding,
        /// Set by `validateInitAdmission`; cleared by any table created or grown since.
        validated: bool = false,
        /// Set when a table from before the admission was asked to be destroyed. Only an abort ends
        /// it.
        rejected: bool = false,
    };

    /// Opens an init admission and returns its token. `error.AdmissionAlreadyActive` when one is
    /// open, `error.AdmissionPreparationActive` while a replacement is prepared,
    /// `error.AdmissionGenerationExhausted`, `error.Overflow` or `error.OutOfMemory`; a failure
    /// opens nothing.
    pub fn beginInitAdmission(tables: *Registry) !InitAdmission {
        if (tables.admission != null) return error.AdmissionAlreadyActive;
        if (tables.preparations != 0) return error.AdmissionPreparationActive;
        const generation = std.math.add(u64, tables.admission_generation, 1) catch return error.AdmissionGenerationExhausted;
        const allocator = tables.globalAllocator();
        const generations = try allocator.dupe(u32, tables.generation);
        errdefer allocator.free(generations);
        const allocated = try allocator.dupe(bool, tables.allocated);
        errdefer allocator.free(allocated);
        const free_copy = try allocator.dupe(u32, tables.free_list.items);
        errdefer allocator.free(free_copy);
        const bindings = try allocator.alloc(SchemaBinding, tables.schemas.entries.count());
        errdefer allocator.free(bindings);
        var it = tables.schemas.entries.iterator();
        var i: usize = 0;
        while (it.next()) |entry| : (i += 1) {
            if (entry.value_ptr.*.refs == std.math.maxInt(usize)) return error.Overflow;
            bindings[i] = .{ .name = entry.key_ptr.*, .record = entry.value_ptr.* };
        }
        // Pin before any candidate can retire an orphan same-name record.
        for (bindings) |binding| tables.schemas.retain(binding.record);
        tables.admission_generation = generation;
        tables.admission = .{ .generation = generation, .capacity = tables.capacity, .generations = generations, .allocated = allocated, .free = free_copy, .bindings = bindings };
        return .{ .tables = tables, .generation = generation };
    }

    fn validAdmission(tables: *Registry, token: InitAdmission) bool {
        return token.tables == tables and tables.admission != null and tables.admission.?.generation == token.generation;
    }
    fn admissionMutation(tables: *Registry) void {
        if (tables.admission) |*a| a.validated = false;
    }
    fn rejectAdmission(tables: *Registry) void {
        if (tables.admission) |*a| {
            a.validated = false;
            a.rejected = true;
        }
    }
    /// Marks the admission ready to commit. A table created or grown afterwards unmarks it, so
    /// validate last. `error.InvalidAdmissionToken` for a token that is not the open admission's,
    /// `error.AdmissionMutationRejected` when the admission was rejected.
    pub fn validateInitAdmission(tables: *Registry, token: InitAdmission) !void {
        if (!tables.validAdmission(token)) return error.InvalidAdmissionToken;
        if (tables.admission.?.rejected) return error.AdmissionMutationRejected;
        tables.admission.?.validated = true;
    }
    fn freeAdmission(tables: *Registry, a: Admission) void {
        const allocator = tables.globalAllocator();
        allocator.free(a.generations);
        allocator.free(a.allocated);
        allocator.free(a.free);
        allocator.free(a.bindings);
        tables.admission = null;
    }
    /// Closes a validated admission, keeping everything made during it. It allocates nothing and
    /// cannot fail part-way: false means the token is not the open admission's or the admission is
    /// not validated, and nothing changed. Where several components are admitted together, as
    /// `Memory.commitInitAdmission` is with this, validate them all before committing the first,
    /// with nothing changed in between; a false then is a fault in the caller, not leave to go on
    /// committing the others.
    pub fn commitInitAdmission(tables: *Registry, token: InitAdmission) bool {
        if (!tables.validAdmission(token) or !tables.admission.?.validated) return false;
        const a = tables.admission.?;
        // An unchanged orphan binding must remain published with its original zero refs.
        for (a.bindings) |binding| {
            if (tables.schemas.entries.get(binding.name) == binding.record) binding.record.refs -= 1 else tables.schemas.release(binding.record);
        }
        tables.freeAdmission(a);
        return true;
    }
    /// Closes the admission and undoes it: destroys the tables created since it began, drops the
    /// schemas they brought, and puts the slots' generations, liveness and free order back as they
    /// were. False, with nothing changed, for a token that is not the open admission's.
    pub fn abortInitAdmission(tables: *Registry, token: InitAdmission) bool {
        if (!tables.validAdmission(token)) return false;
        const a = tables.admission.?;
        for (tables.allocated, 0..) |allocated, i| {
            const preexisting = i < a.allocated.len and a.allocated[i];
            if (allocated and !preexisting) tables.destroy(.{ .index = @intCast(i), .generation = tables.generation[i] });
        }
        // New tables may already have been destroyed; retire their orphan mappings too.
        while (true) {
            var extra: ?*Table.SchemaRegistry.Record = null;
            var it = tables.schemas.entries.iterator();
            while (it.next()) |entry| {
                var original = false;
                for (a.bindings) |binding| if (binding.record == entry.value_ptr.*) {
                    original = true;
                    break;
                };
                if (!original) {
                    extra = entry.value_ptr.*;
                    break;
                }
            }
            const record = extra orelse break;
            tables.schemas.retire(record);
        }
        for (a.bindings) |binding| {
            tables.schemas.entries.putAssumeCapacity(binding.name, binding.record);
            binding.record.refs -= 1;
        }
        tables.setCapacity(a.capacity);
        @memcpy(tables.generation, a.generations);
        @memcpy(tables.allocated, a.allocated);
        tables.free_list.items.len = a.free.len;
        @memcpy(tables.free_list.items, a.free);
        tables.freeAdmission(a);
        return true;
    }

    /// Registers a copy of `schema` under `name` for columnar tables: `createNamed` makes tables of
    /// it by that name, a table file finds it by its hash (`findSchemaByFileHash`), and no table or
    /// schema of another shape may take the name. `schema` stays the caller's. Registering an equal
    /// schema again changes nothing. `error.SchemaMismatch` when the name holds a different schema
    /// or is a singleton's, `error.AdmissionMutationRejected` during an init admission, a
    /// `Schema.ValidationError`, or `error.OutOfMemory`.
    pub fn registerSchema(tables: *Registry, name: Atom, schema: *const Table.Schema) !void {
        if (tables.admission != null) return error.AdmissionMutationRejected;
        try tables.schemas.register(name, schema, .columnar);
    }

    /// Registers a schema whose tables are singletons, as resources makes them for a document
    /// with this id (`createNamedSingleton`).
    pub fn registerSingletonSchema(tables: *Registry, name: Atom, schema: *const Table.Schema) !void {
        if (tables.admission != null) return error.AdmissionMutationRejected;
        try tables.schemas.register(name, schema, .singleton);
    }

    /// Whether code registered `name` as a singleton's schema.
    pub fn isSingletonSchema(tables: *const Registry, name: Atom) bool {
        return tables.schemas.enforced.get(name) == .singleton;
    }

    /// The registered schema a table file with this hash was saved with: `preferred` when it
    /// is one, as a document's own id, else any registered schema that hashes the same.
    pub fn findSchemaByFileHash(tables: *Registry, hash: u32, preferred: Atom) ?Atom {
        if (tables.schemas.enforced.contains(preferred)) {
            if (fileSchemaHash(tables.schemas.get(preferred).?) == hash) return preferred;
        }
        var names = tables.schemas.enforced.keyIterator();
        while (names.next()) |name| {
            const schema = tables.schemas.get(name.*) orelse continue;
            if (fileSchemaHash(schema) == hash) return name.*;
        }
        return null;
    }

    /// Whether code registered a schema under `name` (`registerSchema`, `registerSingletonSchema`),
    /// as opposed to a table having brought its own.
    pub fn isSchemaEnforced(tables: *const Registry, name: Atom) bool {
        return tables.schemas.enforced.contains(name);
    }

    /// The registry's copy of the schema under `name`, registered or a table's own; null when there
    /// is none. Good until the schema is unregistered or the name is given another.
    pub fn getSchema(tables: *Registry, name: Atom) ?*Table.Schema {
        return tables.schemas.get(name);
    }

    /// Makes the registry, with `capacity` table slots to start with; more are added as tables are
    /// created. Host code runs it, on storage at the address the registry keeps for good, since its
    /// tables and arena point into it; `tables` may be undefined before. It registers itself with
    /// `memory`, which must outlive it. `error.OutOfMemory`, or what `Memory.registerTables`
    /// refuses: a memory that already has a registry, or an open init admission.
    pub fn init(tables: *Registry, memory: *memory_mod.Memory, capacity: u32) !void {
        tables.pages = .{ .upstream = .{ .source = &memory.page_source } };
        tables.singleton_arena = .{ .pages = &tables.pages };
        errdefer tables.singleton_arena.deinit();
        const allocator = memory.globalAllocator();
        const slots = try allocator.alloc(*Table, capacity);
        errdefer allocator.free(slots);
        var created_count: usize = 0;
        errdefer for (slots[0..created_count]) |slot| allocator.destroy(slot);
        for (slots) |*slot| {
            slot.* = try allocator.create(Table);
            created_count += 1;
        }
        const generation = try allocator.alloc(u32, capacity);
        errdefer allocator.free(generation);
        @memset(generation, 0);
        const allocated = try allocator.alloc(bool, capacity);
        errdefer allocator.free(allocated);
        @memset(allocated, false);
        var free_list: std.ArrayListUnmanaged(u32) = .empty;
        errdefer free_list.deinit(allocator);
        try free_list.ensureTotalCapacity(allocator, capacity);
        var i = capacity;
        while (i > 0) {
            i -= 1;
            free_list.appendAssumeCapacity(i);
        }
        tables.memory = memory;
        tables.slots = slots;
        tables.generation = generation;
        tables.allocated = allocated;
        tables.free_list = free_list;
        tables.capacity = capacity;
        tables.reserved_slots = capacity;
        tables.scope = .host;
        tables.preparations = 0;
        tables.admission = null;
        tables.admission_generation = 0;
        tables.schemas = .{ .global = memory.global };
        try memory.registerTables(tables);
    }

    /// Destroys every table and schema and frees the registry's bookkeeping, aborting an init
    /// admission left open. No replacement may be pending.
    pub fn deinit(tables: *Registry) void {
        std.debug.assert(tables.preparations == 0);
        if (tables.admission) |a| _ = tables.abortInitAdmission(.{ .tables = tables, .generation = a.generation });
        tables.memory.unregisterTables(tables);
        for (0..tables.capacity) |i| {
            if (tables.allocated[i]) tables.destroy(.{ .index = @intCast(i), .generation = tables.generation[i] });
        }
        tables.schemas.deinit();
        tables.setCapacity(tables.reserved_slots);
        const allocator = tables.globalAllocator();
        for (tables.slots) |slot| allocator.destroy(slot);
        allocator.free(tables.slots);
        allocator.free(tables.generation);
        allocator.free(tables.allocated);
        tables.free_list.deinit(allocator);
        tables.singleton_arena.deinit();
    }

    fn setCapacity(tables: *Registry, capacity: u32) void {
        std.debug.assert(capacity <= tables.reserved_slots);
        tables.slots = tables.slots.ptr[0..capacity];
        tables.generation = tables.generation.ptr[0..capacity];
        tables.allocated = tables.allocated.ptr[0..capacity];
        tables.capacity = capacity;
    }

    /// Adds free slots, reusing any left reserved by an aborted admission. Slot arrays
    /// move, so never iterate them across a call that can create a table; `*Table` records
    /// stay put. Failure leaves the registry unchanged.
    fn growSlots(tables: *Registry) !void {
        const old_capacity = tables.capacity;
        if (old_capacity == tables.reserved_slots) {
            const doubled = std.math.mul(u32, @max(old_capacity, 4), 2) catch return error.Overflow;
            try tables.reserveSlots(doubled);
        }
        tables.setCapacity(tables.reserved_slots);
        @memset(tables.allocated[old_capacity..], false);
        var index = tables.capacity;
        while (index > old_capacity) {
            index -= 1;
            tables.free_list.appendAssumeCapacity(index);
        }
    }

    fn reserveSlots(tables: *Registry, new_reserved: u32) !void {
        const allocator = tables.globalAllocator();
        const old_reserved = tables.reserved_slots;
        const slots = try allocator.alloc(*Table, new_reserved);
        errdefer allocator.free(slots);
        const generation = try allocator.alloc(u32, new_reserved);
        errdefer allocator.free(generation);
        const allocated = try allocator.alloc(bool, new_reserved);
        errdefer allocator.free(allocated);
        try tables.free_list.ensureTotalCapacity(allocator, new_reserved);
        var created = old_reserved;
        errdefer for (slots[old_reserved..created]) |slot| allocator.destroy(slot);
        for (slots[old_reserved..]) |*slot| {
            slot.* = try allocator.create(Table);
            created += 1;
        }
        const capacity = tables.capacity;
        tables.setCapacity(old_reserved);
        @memcpy(slots[0..old_reserved], tables.slots);
        @memcpy(generation[0..old_reserved], tables.generation);
        @memcpy(allocated[0..old_reserved], tables.allocated);
        @memset(generation[old_reserved..], 0);
        @memset(allocated[old_reserved..], false);
        allocator.free(tables.slots);
        allocator.free(tables.generation);
        allocator.free(tables.allocated);
        tables.slots = slots;
        tables.generation = generation;
        tables.allocated = allocated;
        tables.reserved_slots = new_reserved;
        tables.setCapacity(capacity);
    }

    /// The scope's direct backing, which owners call for pages of their own.
    fn scopeBacking(tables: *const Registry, memory_scope: memory_mod.Scope.Id) !*memory_mod.PageBacking {
        const found = tables.memory.scopeFor(memory_scope) orelse return error.StaleScope;
        if (found.state != .open) return error.ScopeClosing;
        return &found.direct;
    }

    /// The host's general-purpose allocator, for the registry's bookkeeping.
    fn globalAllocator(tables: *const Registry) std.mem.Allocator {
        return tables.memory.globalAllocator();
    }

    fn releaseStorage(table: *Table) void {
        table.payloads.deinit();
        switch (table.storage) {
            .columnar => |*columnar| columnar.arena.deinit(),
            .singleton => |singleton| {
                const backing = singleton.scoped_backing orelse return;
                if (singleton.scoped_bytes.len == 0) return;
                backing.rawFree(singleton.scoped_bytes, .@"16", @returnAddress());
            },
        }
    }

    /// Gives back payload bytes no cell names: resets the arena of every table left with no
    /// rows, and compacts the tables saved since. Call outside any run, once the root layer
    /// is flushed: a journaled clear leaves the bytes where they are, since the rows a
    /// faulted run restores still name them, and a layer's copy of a row names the arena as
    /// it was.
    pub fn reclaimPayloads(tables: *Registry) void {
        for (tables.slots, tables.allocated) |table, live| {
            if (!live) continue;
            table.resetPayloadsIfEmpty();
            // A saved table sheds its dead bytes here, where no run holds a copy of its rows.
            if (!table.compact_payloads_wanted or table.journal != null) continue;
            table.compact_payloads_wanted = false;
            table.compactPayloads() catch {};
        }
    }

    /// Destroys every table placed in a scope, returning their pages before the scope is
    /// released. Their handles go stale; consumers must already have stopped using them.
    pub fn destroyScopeTables(tables: *Registry, memory_scope: memory_mod.Scope.Id) void {
        for (0..tables.capacity) |i| {
            if (!tables.allocated[i]) continue;
            const placed = tables.slots[i].memory_scope orelse continue;
            if (!std.meta.eql(placed, memory_scope)) continue;
            tables.destroy(.{ .index = @intCast(i), .generation = tables.generation[i] });
        }
    }

    /// Direct backing the scope's tables hold, which destroying them returns.
    pub fn scopeTableBackingBytes(tables: *const Registry, memory_scope: memory_mod.Scope.Id) u64 {
        var bytes: u64 = 0;
        for (tables.slots, tables.allocated) |table, live| {
            if (!live) continue;
            const placed = table.memory_scope orelse continue;
            if (!std.meta.eql(placed, memory_scope)) continue;
            bytes += table.payloads.bytes;
            switch (table.storage) {
                .columnar => |columnar| bytes += columnar.arena.bytes,
                .singleton => |singleton| bytes += std.mem.alignForward(usize, singleton.scoped_bytes.len, std.heap.pageSize()),
            }
        }
        return bytes;
    }

    /// The storage of the tables in no memory scope; from `storageStats`.
    pub const StorageStats = struct {
        /// Pages of the persistent columnar tables, their payload arenas included.
        persistent: table_storage.Stats = .{},
        /// Pages of the durable columnar tables, their payload arenas included.
        durable: table_storage.Stats = .{},
        /// Pages of the transient columnar tables, their payload arenas included.
        transient: table_storage.Stats = .{},
        /// Retained singleton payload capacity, not exact mapped backing bytes.
        singleton_bytes: usize = 0,
    };
    /// Active table arenas only; metadata uses the host allocator and preparations
    /// own their unpublished storage independently until commit or abort. Tables placed
    /// in a memory scope are excluded: their pages count once, under that scope.
    pub fn storageStats(tables: *const Registry) StorageStats {
        var result: StorageStats = .{ .singleton_bytes = tables.singleton_arena.reserved() };
        for (tables.slots, tables.allocated) |table, live| {
            if (live and !table.isSingleton() and table.memory_scope == null) {
                const stats = switch (table.lifetime) {
                    .persistent => &result.persistent,
                    .durable => &result.durable,
                    .transient => &result.transient,
                };
                stats.reserved_bytes += table.storage.columnar.arena.bytes + table.payloads.bytes;
                stats.reserved_pages += table.storage.columnar.arena.pages + table.payloads.bytes / std.heap.pageSize();
            }
        }
        return result;
    }
    /// Rewrites the `table_memory` table, a report the host refreshes each frame and the inspector
    /// and MCP read as they read any table: a row per live table, itself included, with its name,
    /// slot and generation, owner, lifetime, storage, row count and capacity, and bytes. The table
    /// is made on the first call and cleared on each, so its row handles do not last: match rows by
    /// `table_index` and `table_generation`. `row_bytes`, `live_data_bytes` and
    /// `capacity_data_bytes` count field bytes only; `reserved_bytes` and `reserved_pages` are a
    /// columnar table's pages, headers, bookkeeping columns and payload arena included, and are
    /// absent for a singleton, whose bytes lie in an arena shared with the others that the `memory`
    /// table reports. Field names are interned in `kw`. Fails when there is no memory for the
    /// report.
    pub fn syncMemoryTable(tables: *Registry, kw: *Atom.Registry) !void {
        const scratch = try tables.memory.tableScratchAllocator();
        var schema: Table.Schema = undefined;
        try schema.init(scratch.allocator, kw, 13);
        defer schema.deinit();
        schema.addField("table_name", Atom, .atom);
        schema.addField("table_index", u32, .int);
        schema.addField("table_generation", u32, .int);
        schema.addField("owner", Atom, .atom);
        schema.addField("lifetime", Atom, .atom);
        schema.addField("storage", Atom, .atom);
        schema.addField("row_count", u32, .int);
        schema.addField("row_capacity", u32, .int);
        schema.addField("row_bytes", u64, .int);
        schema.addField("live_data_bytes", u64, .int);
        schema.addField("capacity_data_bytes", u64, .int);
        schema.addField("reserved_bytes", u64, .int);
        schema.addField("reserved_pages", u64, .int);
        const report_name = kw.intern("table_memory");
        const first_report_rows: u32 = if (tables.findHandleByName(report_name) == null) @max(tables.capacity, 1) else 1;
        const ensured_report = try tables.ensure(&schema, first_report_rows, report_name, .durable);
        const report = ensured_report.table;
        // Rows would grow on demand, but `insert` treats allocation failure as fatal.
        try tables.reserveRows(ensured_report.handle, tables.capacity);
        report.owner = .host;
        report.clear();
        var active: u32 = 0;
        for (tables.allocated) |live| active += @intFromBool(live);
        for (tables.slots, tables.allocated, 0..) |table, live, i| {
            if (!live) continue;
            var row_bytes: u64 = 0;
            for (table.getSchema().fields) |field| row_bytes += field.stride;
            const row_count = if (table == report) active else table.count();
            const row = report.insert(.{
                .table_name = table.name,
                .table_index = @as(u32, @intCast(i)),
                .table_generation = tables.generation[i],
                .owner = kw.intern(@tagName(table.owner)),
                .lifetime = kw.intern(@tagName(table.lifetime)),
                .storage = kw.intern(if (table.isSingleton()) "singleton" else "columnar"),
                .row_count = row_count,
                .row_capacity = table.rowCapacity(),
                .row_bytes = row_bytes,
                .live_data_bytes = row_bytes * row_count,
                .capacity_data_bytes = row_bytes * table.rowCapacity(),
            });
            if (!table.isSingleton()) {
                const reserved_bytes = table.storage.columnar.arena.bytes + table.payloads.bytes;
                const reserved_pages = table.storage.columnar.arena.pages + table.payloads.bytes / std.heap.pageSize();
                try report.writeFieldSingle(u64, row, "reserved_bytes", @intCast(reserved_bytes));
                try report.writeFieldSingle(u64, row, "reserved_pages", @intCast(reserved_pages));
            }
        }
    }

    const Bundle = struct { table: Table };

    fn reserveSingleton(tables: *Registry, record: *Table.SchemaRegistry.Record, name: Atom, lifetime: Table.Lifetime, named: bool, memory_scope: ?memory_mod.Scope.Id) !Bundle {
        const schema = &record.schema;
        try schema.validate();
        if (lifetime == .persistent) try schema.validatePersistentStorage();
        var layout: table_storage.Layout = .{};
        const columns_offset = try layout.appendArray([]u8, schema.fields.len);
        var offsets: [Mask.max_bits]usize = undefined;
        for (schema.fields, 0..) |field, i| offsets[i] = try layout.append(field.stride, .@"16");
        const scoped_backing = if (memory_scope) |id| try tables.scopeBacking(id) else null;
        const bytes: []align(16) u8 = if (scoped_backing) |backing| scoped: {
            // Pages are never zero bytes long; a singleton without fields takes none.
            if (layout.size == 0) break :scoped &.{};
            const raw = backing.rawAlloc(layout.size, .@"16", @returnAddress()) orelse return error.OutOfMemory;
            const aligned: [*]align(16) u8 = @alignCast(raw);
            break :scoped aligned[0..layout.size];
        } else unscoped: {
            const arena = tables.singleton_arena.allocator();
            break :unscoped try arena.alignedAlloc(u8, .@"16", layout.size);
        };
        @memset(bytes, 0);
        const columns_ = slice([]u8, bytes, columns_offset, schema.fields.len);
        for (schema.fields, 0..) |field, i| columns_[i] = bytes[offsets[i]..][0..field.stride];
        return .{ .table = .{
            .schema_ref = record,
            .schema_name = record.name,
            .uses_named_schema = named,
            .storage = .{ .singleton = .{
                .columns = columns_,
                .scoped_bytes = if (scoped_backing != null) bytes else &.{},
                .scoped_backing = scoped_backing,
            } },
            .payloads = .{ .backing = scoped_backing orelse &tables.pages },
            .name = name,
            .lifetime = lifetime,
            .memory_scope = memory_scope,
        } };
    }
    fn slice(comptime T: type, bytes: []u8, offset: usize, item_count: usize) []T {
        const ptr: [*]T = @ptrCast(@alignCast(bytes.ptr + offset));
        return ptr[0..item_count];
    }
    fn reserveBundle(tables: *Registry, record: *Table.SchemaRegistry.Record, capacity: u32, generation_count: usize, name: Atom, lifetime: Table.Lifetime, named: bool, memory_scope: ?memory_mod.Scope.Id) !Bundle {
        if (capacity == 0) return error.InvalidCapacity;
        const schema = &record.schema;
        try schema.validate();
        if (lifetime == .persistent) try schema.validatePersistentStorage();
        const backing = if (memory_scope) |id| try tables.scopeBacking(id) else &tables.pages;
        var table: Table = .{
            .schema_ref = record,
            .schema_name = record.name,
            .uses_named_schema = named,
            .storage = .{ .columnar = .{ .arena = .{ .backing = backing }, .mask_words = schema.maskWords() } },
            .payloads = .{ .backing = backing },
            .name = name,
            .lifetime = lifetime,
            .memory_scope = memory_scope,
        };
        errdefer table.storage.columnar.arena.deinit();
        try table.reserveCapacity(@intCast(@max(capacity, generation_count)));
        table.revision = 0;
        return .{ .table = table };
    }

    /// Copies `src`'s rows, generations and reusable ids into the empty `dst`, and the bytes
    /// of their payload cells into `dst`'s arena.
    fn copyRows(dst: *Table, src: *const Table) error{ OutOfMemory, Overflow }!void {
        for (0..@min(dst.generationCount(), src.generationCount())) |row| {
            if (dst.isSingleton()) dst.storage.singleton.generation = src.rowGeneration(@intCast(row)) else dst.storage.columnar.generation.at(row).* = src.rowGeneration(@intCast(row));
        }
        var row_iterator = src.rows();
        while (row_iterator.next()) |handle| {
            if (handle.row >= dst.rowCapacity()) continue;
            dst.restoreRowState(handle.row, handle.generation, src.rowMask(handle.row), true);
            for (src.getSchema().fields, 0..) |*field, field_index| {
                const copy = dst.rowFieldBytes(handle.row, field_index);
                const source = src.rowFieldBytes(handle.row, field_index);
                if (!field.isPayload()) {
                    @memcpy(copy, source);
                    continue;
                }
                const cell: *Payload = @ptrCast(@alignCast(copy.ptr));
                cell.* = .{};
                if (!src.rowHas(handle.row, field.bit)) continue;
                const held = src.payloads.bytesOf(std.mem.bytesToValue(Payload, source[0..@sizeOf(Payload)]));
                cell.* = try dst.payloads.append(held, field.payloadAlignment());
            }
        }
        if (dst.storage == .singleton) return;
        dst.storage.columnar.free_list.len = 0;
        if (dst.rowCapacity() > src.rowCapacity()) {
            var row = dst.rowCapacity();
            while (row > src.rowCapacity()) {
                row -= 1;
                dst.storage.columnar.free_list.appendAssumeCapacity(row);
            }
        }
        for (0..src.reusableRows().len) |i| {
            const row = src.reusableRows().at(i);
            if (row >= dst.rowCapacity()) continue;
            dst.storage.columnar.free_list.appendAssumeCapacity(row);
        }
    }

    /// Makes a columnar table of `schema`, named `name`, with room for `row_capacity` rows to start
    /// with; it grows as rows are allocated. The registry keeps its own copy of the schema under
    /// the table's name, so `schema` stays the caller's. The table's owner is the registry's
    /// `scope`. The handle is good until the table is destroyed. `error.DuplicateTableName` when a
    /// live table has the name; `error.SchemaMismatch` when a schema registered under the name
    /// differs; `error.InvalidCapacity` for zero rows; a `Schema.ValidationError`; for a persistent
    /// table what `Schema.validatePersistentStorage` refuses; `error.OutOfMemory` or
    /// `error.Overflow`. A failure makes nothing.
    pub fn create(tables: *Registry, schema: *const Table.Schema, row_capacity: u32, name: Atom, lifetime: Table.Lifetime) !Handle {
        return tables.createWithSchema(schema, name, row_capacity, name, lifetime, false, null);
    }

    /// As `create`, of the schema registered as `schema_name`, so the tables of one schema share it
    /// and a table file saved from one loads into another. `error.UnknownSchema` when no schema has
    /// that name.
    pub fn createNamed(tables: *Registry, schema_name: Atom, row_capacity: u32, name: Atom, lifetime: Table.Lifetime) !Handle {
        if (tables.schemas.get(schema_name) == null) return error.UnknownSchema;
        return tables.createWithSchema(null, schema_name, row_capacity, name, lifetime, false, null);
    }

    /// As `create`, the table's pages taken from `memory_scope`, which is charged for them;
    /// `destroyScopeTables` destroys it with the scope's other tables before the scope is released.
    /// Also `error.StaleScope` for a scope that is gone and `error.ScopeClosing` for one being
    /// closed.
    pub fn createScoped(tables: *Registry, memory_scope: memory_mod.Scope.Id, schema: *const Table.Schema, row_capacity: u32, name: Atom, lifetime: Table.Lifetime) !Handle {
        return tables.createWithSchema(schema, name, row_capacity, name, lifetime, false, memory_scope);
    }

    /// As `createNamed`, in `memory_scope` as `createScoped` places a table.
    pub fn createNamedScoped(tables: *Registry, memory_scope: memory_mod.Scope.Id, schema_name: Atom, row_capacity: u32, name: Atom, lifetime: Table.Lifetime) !Handle {
        if (tables.schemas.get(schema_name) == null) return error.UnknownSchema;
        return tables.createWithSchema(null, schema_name, row_capacity, name, lifetime, false, memory_scope);
    }

    /// As `createSingleton`, in `memory_scope` as `createScoped` places a table. The scope's
    /// backing gets the cells back when the table is destroyed.
    pub fn createSingletonScoped(tables: *Registry, memory_scope: memory_mod.Scope.Id, schema: *const Table.Schema, name: Atom, lifetime: Table.Lifetime) !Handle {
        return tables.createWithSchema(schema, name, 1, name, lifetime, true, memory_scope);
    }

    /// A singleton of the schema registered as `schema_name`, its row not yet allocated.
    pub fn createNamedSingleton(tables: *Registry, schema_name: Atom, name: Atom, lifetime: Table.Lifetime, memory_scope: ?memory_mod.Scope.Id) !Handle {
        if (tables.schemas.get(schema_name) == null) return error.UnknownSchema;
        return tables.createWithSchema(null, schema_name, 1, name, lifetime, true, memory_scope);
    }

    /// Drops the schema under `name`, registered or left by a table. Nothing to do for an unknown
    /// name. `error.SchemaInUse` while a live table or a pending operation holds it,
    /// `error.AdmissionMutationRejected` during an init admission.
    pub fn unregisterSchema(tables: *Registry, name: Atom) !void {
        if (tables.admission != null) return error.AdmissionMutationRejected;
        for (tables.slots, tables.allocated) |slot, allocated| {
            if (allocated and slot.schema_name == name) return error.SchemaInUse;
        }
        const record = tables.schemas.entries.get(name) orelse return;
        if (record.refs != 0) return error.SchemaInUse;
        _ = tables.schemas.enforced.remove(name);
        tables.schemas.retire(record);
    }

    /// Makes a singleton of `schema`, named `name`: a table of at most one row, id 0, which is not
    /// there until it is inserted (`insert`). `ensureSingleton` also inserts it and keeps it there.
    /// Fails as `create` does, row capacity aside. Its cells stay in the registry's arena after the
    /// table is destroyed.
    pub fn createSingleton(tables: *Registry, schema: *const Table.Schema, name: Atom, lifetime: Table.Lifetime) !Handle {
        return tables.createWithSchema(schema, name, 1, name, lifetime, true, null);
    }

    fn createWithSchema(tables: *Registry, template: ?*const Table.Schema, schema_name: Atom, row_capacity: u32, name: Atom, lifetime: Table.Lifetime, singleton: bool, memory_scope: ?memory_mod.Scope.Id) !Handle {
        tables.admissionMutation();
        if (tables.findHandleByName(name) != null) return error.DuplicateTableName;
        if (tables.free_list.items.len == 0) try tables.growSlots();
        var record = tables.schemas.entries.get(schema_name);
        var fresh = false;
        if (template) |schema| {
            try schema.validate();
            if (record == null or !schemasEqual(&record.?.schema, schema)) {
                if (tables.schemas.enforced.contains(schema_name)) return error.SchemaMismatch;
                try tables.schemas.entries.ensureUnusedCapacity(tables.globalAllocator(), 1);
                record = try tables.schemas.clone(schema_name, schema);
                fresh = true;
            }
        }
        const admitted = record orelse return error.UnknownSchema;
        errdefer if (fresh) tables.schemas.dispose(admitted);
        const bundle = if (singleton) try tables.reserveSingleton(admitted, name, lifetime, template == null, memory_scope) else try tables.reserveBundle(admitted, row_capacity, row_capacity, name, lifetime, template == null, memory_scope);
        const index = tables.free_list.pop().?;
        if (fresh) {
            const previous = tables.schemas.entries.get(schema_name);
            tables.schemas.entries.putAssumeCapacity(schema_name, admitted);
            if (previous) |old| tables.schemas.retire(old);
        }
        tables.schemas.retain(admitted);
        tables.slots[index].* = bundle.table;
        tables.slots[index].owner = tables.scope;
        tables.generation[index] +%= 1;
        tables.slots[index].handle = .{ .index = index, .generation = tables.generation[index] };
        tables.allocated[index] = true;
        return .{ .index = index, .generation = tables.generation[index] };
    }

    /// Destroys a table: returns its pages, drops its hold on its schema, and makes `handle` and
    /// every pointer to the table or into it stale; its slot and record are reused by a later
    /// table. A stale handle does nothing. During an init admission a table that was there before
    /// it is not destroyed, and the admission is rejected.
    pub fn destroy(tables: *Registry, handle: Handle) void {
        if (!tables.valid(handle)) return;
        if (tables.admission) |a| {
            if (handle.index < a.allocated.len and a.allocated[handle.index]) {
                tables.rejectAdmission();
                return;
            }
        }
        tables.admissionMutation();
        const table = tables.slots[handle.index];
        releaseStorage(table);
        tables.schemas.release(table.schema_ref);
        tables.generation[handle.index] +%= 1;
        tables.allocated[handle.index] = false;
        tables.free_list.appendAssumeCapacity(handle.index);
    }

    /// A replacement of one table's contents by another's, prepared and not yet done: hand it,
    /// once, to `commitReplacement` or `abortReplacement`. Until then neither table may change: the
    /// preparation holds the staged table's rows as they were, by copy or by its pages
    /// (`transfer`). Other tables are free to change.
    pub const Replacement = struct {
        /// The table whose contents are replaced.
        target: Handle,
        /// The table whose rows and schema it takes.
        staged: Handle,
        /// The storage the target will have: the staged table's own, or a copy of its rows.
        bundle: Bundle,
        /// Whether `bundle` is the staged table's own pages, not a copy. They change hands only
        /// between two columnar tables of one memory scope and lifetime, where the staged one has
        /// at least as many row ids.
        transfer: bool,
        /// The name the target's schema will be kept under.
        schema_name: Atom,
    };

    /// Does all the fallible work of replacing `target`'s rows and schema with `staged`'s, changing
    /// neither table: `commitReplacement` then cannot fail. `error.SameTable`; `error.StaleTarget`
    /// or `error.StaleStaging` for a handle that is gone; `error.InvalidSingleton` when the target
    /// is a singleton or a required one and `staged` does not hold exactly one row, at id 0;
    /// `error.SchemaMismatch` when the schema registered under the target's schema name differs
    /// from `staged`'s; for a persistent target what `Schema.validatePersistentStorage` refuses;
    /// `error.AdmissionMutationRejected` during an init admission; `error.StaleScope` or
    /// `error.ScopeClosing` from the target's memory scope; `error.OutOfMemory` or
    /// `error.Overflow`.
    pub fn prepareReplacement(tables: *Registry, target: Handle, staged: Handle) !Replacement {
        if (tables.admission != null) return error.AdmissionMutationRejected;
        if (target.index == staged.index and target.generation == staged.generation) return error.SameTable;
        const dst = tables.get(target) orelse return error.StaleTarget;
        const src = tables.get(staged) orelse return error.StaleStaging;
        if ((dst.isSingleton() or dst.required_singleton) and (src.count() != 1 or !src.isAllocated(0))) return error.InvalidSingleton;
        if (dst.lifetime == .persistent) try src.getSchema().validatePersistentStorage();
        const schema_name = if (src.uses_named_schema) src.schema_name else dst.schema_name;
        if (tables.schemas.enforced.contains(schema_name) and !schemasEqual(tables.getSchema(schema_name).?, src.getSchema())) return error.SchemaMismatch;
        // The destination owns its schema identity; staging peers retain their version.
        try tables.schemas.entries.ensureUnusedCapacity(tables.globalAllocator(), 1);
        const record = if (src.uses_named_schema or src.schema_name == schema_name) src.schema_ref else if (tables.schemas.enforced.contains(schema_name)) tables.schemas.entries.get(schema_name).? else try tables.schemas.clone(schema_name, src.getSchema());
        tables.schemas.retain(record);
        errdefer tables.schemas.release(record);
        // Pages may only change hands inside one scope; otherwise copy into dst's scope.
        const same_scope = std.meta.eql(dst.memory_scope, src.memory_scope);
        const transfer = same_scope and !dst.isSingleton() and !src.isSingleton() and dst.lifetime == src.lifetime and src.generationCount() >= dst.generationCount();
        var bundle = if (transfer) Bundle{ .table = src.* } else if (dst.isSingleton()) try tables.reserveSingleton(record, dst.name, dst.lifetime, src.uses_named_schema, dst.memory_scope) else try tables.reserveBundle(record, src.rowCapacity(), @max(src.generationCount(), dst.generationCount()), dst.name, dst.lifetime, src.uses_named_schema, dst.memory_scope);
        if (!transfer) {
            errdefer releaseStorage(&bundle.table);
            try copyRows(&bundle.table, src);
        }
        bundle.table.schema_ref = record;
        tables.preparations += 1;
        return .{ .target = target, .staged = staged, .bundle = bundle, .transfer = transfer, .schema_name = schema_name };
    }

    /// Gives up a prepared replacement, freeing what it reserved. Both tables are as they were.
    pub fn abortReplacement(tables: *Registry, prepared: Replacement) void {
        if (!prepared.transfer) {
            var table = prepared.bundle.table;
            releaseStorage(&table);
        }
        tables.schemas.release(prepared.bundle.table.schema_ref);
        tables.preparations -= 1;
    }

    /// Does a prepared replacement, and cannot fail. The target keeps its handle, record, name,
    /// owner, lifetime and attached journal and takes the staged table's rows and schema. Its rows
    /// keep the ids they had in the staged table, with new generations: every row handle to either
    /// table from before is stale, as are pointers into them. The staged table is destroyed. The
    /// target's `revision` moves past both tables'.
    pub fn commitReplacement(tables: *Registry, prepared: Replacement) void {
        const dst = tables.get(prepared.target).?;
        const src = tables.get(prepared.staged).?;
        var next = prepared.bundle.table;
        next.name = dst.name;
        next.owner = dst.owner;
        next.handle = dst.handle;
        next.journal = dst.journal;
        next.lifetime = dst.lifetime;
        next.required_singleton = dst.required_singleton;
        next.payloads_pinned = dst.payloads_pinned or next.payloads_pinned;
        next.schema_name = prepared.schema_name;
        next.revision = @max(dst.revision, src.revision) +% 1;
        // Destination tombstones, including truncated rows, are authoritative.
        for (0..next.generationCount()) |i| {
            const row: u32 = @intCast(i);
            const generation = if (i < dst.generationCount()) dst.rowGeneration(row) +% 1 else next.rowGeneration(row) +% 1;
            if (i < next.rowCapacity()) next.restoreRowState(row, generation, next.rowMask(row), next.isAllocated(row)) else next.storage.columnar.generation.at(i).* = generation;
        }
        const record = next.schema_ref;
        if (!next.uses_named_schema and tables.schemas.entries.get(prepared.schema_name) != record) {
            const previous = tables.schemas.entries.get(prepared.schema_name);
            tables.schemas.entries.putAssumeCapacity(prepared.schema_name, record);
            if (previous) |old| tables.schemas.retire(old);
        }
        releaseStorage(dst);
        tables.schemas.release(dst.schema_ref);
        if (prepared.transfer) {
            tables.schemas.release(src.schema_ref);
            tables.generation[prepared.staged.index] +%= 1;
            tables.allocated[prepared.staged.index] = false;
            tables.free_list.appendAssumeCapacity(prepared.staged.index);
        } else tables.destroy(prepared.staged);
        dst.* = next;
        tables.preparations -= 1;
    }

    /// `prepareReplacement` then `commitReplacement`: replaces `target`'s contents with `staged`'s
    /// and destroys `staged`, or fails as the preparation does and changes nothing.
    pub fn replaceContentsFallible(tables: *Registry, target: Handle, staged: Handle) !void {
        const prepared = try tables.prepareReplacement(target, staged);
        tables.commitReplacement(prepared);
    }

    /// The bytes `storageStats` counts, added up: what the tables in no memory scope reserve.
    pub fn tableBytesReserved(tables: *const Registry) usize {
        const stats = tables.storageStats();
        return stats.persistent.reserved_bytes + stats.durable.reserved_bytes + stats.transient.reserved_bytes + stats.singleton_bytes;
    }

    /// The table `handle` names; null for a stale handle. The pointer is good until the table is
    /// destroyed, however many tables are created meanwhile; after that the record is another
    /// table's.
    pub fn get(tables: *Registry, handle: Handle) ?*Table {
        if (!tables.valid(handle)) return null;
        return tables.slots[handle.index];
    }

    /// Makes room for at least `minimum` rows in the table, so that many allocate without failing.
    /// Does nothing when there is room already. `error.StaleTable`, or as `grow`.
    pub fn reserveRows(tables: *Registry, handle: Handle, minimum: u32) !void {
        const table = tables.get(handle) orelse return error.StaleTable;
        if (minimum > table.rowCapacity()) try tables.grow(handle, minimum);
    }

    /// Makes room for at least `new_capacity` row ids in the table; a table that has as many is
    /// left as it is. `error.StaleTable`; `error.InvalidCapacity` for zero; `error.SchemaMismatch`
    /// for a singleton and any capacity but 1; `error.StaleScope` or `error.ScopeClosing` from the
    /// table's memory scope; `error.AdmissionMutationRejected` for a table that was there before an
    /// open init admission; `error.OutOfMemory` or `error.Overflow`.
    pub fn grow(tables: *Registry, handle: Handle, new_capacity: u32) !void {
        if (tables.admission) |a| {
            if (handle.index < a.allocated.len and a.allocated[handle.index]) return error.AdmissionMutationRejected;
        }
        tables.admissionMutation();
        const table = tables.get(handle) orelse return error.StaleTable;
        if (new_capacity == 0) return error.InvalidCapacity;
        if (table.memory_scope) |id| _ = try tables.scopeBacking(id);
        if ((table.isSingleton() or table.required_singleton) and new_capacity != 1) return error.SchemaMismatch;
        try table.reserveCapacity(new_capacity);
    }

    /// Whether `handle` names a live table.
    pub fn valid(tables: *const Registry, handle: Handle) bool {
        return handle.index < tables.capacity and tables.allocated[handle.index] and tables.generation[handle.index] == handle.generation;
    }

    /// The handle of the live table named `name`; null when there is none. A search of every slot:
    /// look a table up once, at init, not in each kernel run.
    pub fn findHandleByName(tables: *const Registry, name: Atom) ?Handle {
        for (0..tables.capacity) |i| {
            const idx: u32 = @intCast(i);
            if (!tables.allocated[i]) continue;
            if (tables.slots[i].name == name) return .{ .index = idx, .generation = tables.generation[i] };
        }
        return null;
    }

    /// A ref to a live row, named by its table's name and the row's `name` atom when
    /// it has one. Null for a stale handle.
    pub fn makeRef(tables: *Registry, table_handle: Handle, handle: Table.RowHandle) ?Ref {
        const table = tables.get(table_handle) orelse return null;
        if (!table.valid(handle)) return null;
        return .{
            .table_name = table.name,
            .row_name = rowName(table, handle) orelse Ref.no_name,
            .table = table_handle,
            .row = handle.row,
            .row_generation = handle.generation,
        };
    }

    /// Finds the row a ref names. Reads only: when the cached handles no longer
    /// match the names, the row is searched for by name and the result carries a
    /// refreshed ref for the cell's owner to store. Null when no such row exists.
    pub fn resolveRef(tables: *Registry, ref: Ref) ?ResolvedRef {
        if (ref.isNone()) return null;
        if (tables.cachedRefTarget(ref)) |resolved| return resolved;
        if (ref.row_name == Ref.no_name) return null;
        const table_handle = tables.findHandleByName(ref.table_name) orelse return null;
        const table = tables.get(table_handle).?;
        const name_index = nameFieldIndex(table) orelse return null;
        const name_bit = table.getSchema().fields[name_index].bit;
        var row_iterator = table.rows();
        while (row_iterator.next()) |handle| {
            if (!table.rowHas(handle.row, name_bit)) continue;
            const name = table.getFieldByIndex(Atom, handle, name_index).?.*;
            if (name != ref.row_name) continue;
            var refreshed = ref;
            refreshed.table = table_handle;
            refreshed.row = handle.row;
            refreshed.row_generation = handle.generation;
            return .{ .table = table, .handle = handle, .ref = refreshed };
        }
        return null;
    }

    fn cachedRefTarget(tables: *Registry, ref: Ref) ?ResolvedRef {
        const table = tables.get(ref.table) orelse return null;
        if (table.name != ref.table_name) return null;
        const handle: Table.RowHandle = .{ .row = ref.row, .generation = ref.row_generation };
        if (!table.valid(handle)) return null;
        // A named ref must still name this row; a nameless one trusts its valid handles.
        if (ref.row_name != Ref.no_name and rowName(table, handle) != ref.row_name) return null;
        return .{ .table = table, .handle = handle, .ref = ref };
    }

    /// The index of the table's atom `name` field, which names rows for refs.
    fn nameFieldIndex(table: *Table) ?u32 {
        const schema = table.getSchema();
        const index = schema.fieldIndex("name") orelse return null;
        const field = schema.fields[index];
        if (field.size != @sizeOf(Atom) or field.view_kind != .atom) return null;
        return @intCast(index);
    }

    /// The row's `name` atom, when its table has a `name` field and the row holds one.
    fn rowName(table: *Table, handle: Table.RowHandle) ?Atom {
        const index = nameFieldIndex(table) orelse return null;
        if (!table.rowHas(handle.row, table.getSchema().fields[index].bit)) return null;
        return table.getFieldByIndex(Atom, handle, index).?.*;
    }

    /// The live table named `name`; null when there is none. The same search as `findHandleByName`.
    pub fn findByName(tables: *Registry, name: Atom) ?*Table {
        return tables.get(tables.findHandleByName(name) orelse return null);
    }

    /// What `ensure`, `ensureNamed` and `ensureSingleton` found or made: the table's handle, the
    /// table, and whether this call created it.
    pub const EnsureResult = struct { handle: Handle, table: *Table, created: bool };

    /// The table named `name`, made as `create` makes it when there is none. One that is there must
    /// be what was asked for: `error.LifetimeMismatch` for another lifetime, `error.SchemaMismatch`
    /// for another schema or room for fewer than `row_capacity` rows. It is never changed.
    pub fn ensure(tables: *Registry, schema: *const Table.Schema, row_capacity: u32, name: Atom, lifetime: Table.Lifetime) !EnsureResult {
        if (tables.findHandleByName(name)) |handle| {
            const table = tables.get(handle).?;
            if (table.lifetime != lifetime) return error.LifetimeMismatch;
            if (table.rowCapacity() < row_capacity or !schemasEqual(table.getSchema(), schema)) return error.SchemaMismatch;
            return .{ .handle = handle, .table = table, .created = false };
        }
        const handle = try tables.create(schema, row_capacity, name, lifetime);
        return .{ .handle = handle, .table = tables.get(handle).?, .created = true };
    }

    /// As `ensure`, of the schema registered as `schema_name`, as `createNamed` makes one. A table
    /// that is there must have been made by that schema name and have room for `row_capacity` rows,
    /// or it is `error.SchemaMismatch`.
    pub fn ensureNamed(tables: *Registry, schema_name: Atom, row_capacity: u32, name: Atom, lifetime: Table.Lifetime) !EnsureResult {
        if (tables.findHandleByName(name)) |handle| {
            const table = tables.get(handle).?;
            if (table.lifetime != lifetime) return error.LifetimeMismatch;
            if (table.rowCapacity() < row_capacity or table.schema_name != schema_name) return error.SchemaMismatch;
            return .{ .handle = handle, .table = table, .created = false };
        }
        const handle = try tables.createNamed(schema_name, row_capacity, name, lifetime);
        return .{ .handle = handle, .table = tables.get(handle).?, .created = true };
    }

    /// The singleton named `name` with its row in place: how one-row state is made. A new one is
    /// created and its row inserted with `defaults`, as `insert` takes them; one that is there must
    /// be a singleton of `schema` and `lifetime` that has its row, and keeps its values. Either way
    /// the table is marked required, so `free` and `clear` leave the row. `error.SchemaMismatch` or
    /// `error.LifetimeMismatch` for a table of another shape, `error.InvalidSingleton` for one
    /// without its row, `error.AdmissionMutationRejected` during an init admission for a table from
    /// before it that was not yet required, or as `createSingleton`.
    pub fn ensureSingleton(tables: *Registry, schema: *const Table.Schema, name: Atom, defaults: anytype, lifetime: Table.Lifetime) !EnsureResult {
        const result: EnsureResult = if (tables.findHandleByName(name) != null) try tables.ensure(schema, 1, name, lifetime) else blk: {
            const handle = try tables.createSingleton(schema, name, lifetime);
            break :blk .{ .handle = handle, .table = tables.get(handle).?, .created = true };
        };
        if (tables.admission != null and !result.created and !result.table.required_singleton) return error.AdmissionMutationRejected;
        if (!result.table.isSingleton()) return error.SchemaMismatch;
        if (result.created) {
            _ = result.table.insert(defaults);
        } else if (result.table.count() != 1 or !result.table.isAllocated(0)) {
            return error.InvalidSingleton;
        }
        if (result.created) tables.admissionMutation();
        result.table.required_singleton = true;
        return result;
    }

    /// How many tables are live.
    pub fn activeCount(tables: *const Registry) u32 {
        var n: u32 = 0;
        for (tables.allocated) |is_allocated| {
            if (is_allocated) n += 1;
        }
        return n;
    }

    /// The handles of the live tables in slot order, written into `buf`: as many as fit. The result
    /// is a slice of `buf`.
    pub fn activeHandles(tables: *const Registry, buf: []Handle) []Handle {
        var n: usize = 0;
        for (0..tables.capacity) |i| {
            if (tables.allocated[i]) {
                if (n >= buf.len) break;
                buf[n] = .{ .index = @intCast(i), .generation = tables.generation[i] };
                n += 1;
            }
        }
        return buf[0..n];
    }
};

/// Whether two schemas have the same fields in the same order: each field's name, size, type hash
/// (`FieldDescriptor.semantic_type`), layout, view and saving flags. A field's declared
/// `field_type` is not compared.
pub fn schemasEqual(a: *const Table.Schema, b: *const Table.Schema) bool {
    if (a.fields.len != b.fields.len) return false;
    for (a.fields, b.fields) |af, bf| {
        if (!std.mem.eql(u8, af.name, bf.name) or
            af.size != bf.size or af.semantic_type != bf.semantic_type or
            af.stride != bf.stride or af.column_index != bf.column_index or af.bit != bf.bit or
            af.persistent_safe != bf.persistent_safe or af.contains_pointer != bf.contains_pointer or
            !std.meta.eql(af.view_kind, bf.view_kind)) return false;
    }
    return true;
}

/// A hash of what `schemasEqual` compares, the saving flags aside. It takes in `semantic_type`, a
/// hash of how the code spells a type, so it is good within a running engine and is not what a file
/// carries: that is `fileSchemaHash`.
pub fn schemaHash(schema: *const Table.Schema) u32 {
    var hasher = std.hash.Wyhash.init(0);
    for (schema.fields) |f| {
        hasher.update(f.name);
        hasher.update(std.mem.asBytes(&f.size));
        hasher.update(std.mem.asBytes(&f.semantic_type));
        hasher.update(std.mem.asBytes(&f.stride));
        hasher.update(std.mem.asBytes(&f.column_index));
        hasher.update(std.mem.asBytes(&f.bit));
        const tag: u8 = @intCast(@intFromEnum(std.meta.activeTag(f.view_kind)));
        hasher.update(std.mem.asBytes(&tag));
        switch (f.view_kind) {
            .float_slider => |v| {
                hasher.update(std.mem.asBytes(&v.min));
                hasher.update(std.mem.asBytes(&v.max));
            },
            .vector => |v| hasher.update(std.mem.asBytes(&v.components)),
            .matrix => |v| {
                hasher.update(std.mem.asBytes(&v.rows));
                hasher.update(std.mem.asBytes(&v.cols));
            },
            else => {},
        }
    }
    return @truncate(hasher.final());
}

// ---- table files ---------------------------------------------------------------------------

/// The hash a table file carries of the schema it was saved with: each field's name, size,
/// type and view, in order. It holds nothing of how the code spells a type, so it changes
/// only when the schema does.
pub fn fileSchemaHash(schema: *const Schema) u32 {
    var hasher = std.hash.Wyhash.init(0);
    for (schema.fields) |*field| {
        const name_len: u32 = @intCast(field.name.len);
        hasher.update(std.mem.asBytes(&name_len));
        hasher.update(field.name);
        hasher.update(std.mem.asBytes(&field.size));
        // By name, so adding or removing another type or view leaves saved files as they are.
        const type_name = if (durableFieldType(field)) |field_type| @tagName(field_type) else "opaque";
        hasher.update(type_name);
        hasher.update(":");
        hasher.update(@tagName(std.meta.activeTag(field.view_kind)));
        hasher.update(";");
        switch (field.view_kind) {
            .float_slider => |range| {
                hasher.update(std.mem.asBytes(&range.min));
                hasher.update(std.mem.asBytes(&range.max));
            },
            .vector => |vector| hasher.update(std.mem.asBytes(&vector.components)),
            .matrix => |matrix| {
                hasher.update(std.mem.asBytes(&matrix.rows));
                hasher.update(std.mem.asBytes(&matrix.cols));
            },
            else => {},
        }
    }
    return @truncate(hasher.final());
}

const file_section_alignment = 8;

fn fileSectionEnd(offset: usize, size: usize) error{Overflow}!usize {
    const end = std.math.add(usize, offset, size) catch return error.Overflow;
    return std.mem.alignForward(usize, end, file_section_alignment);
}

/// Where a file's sections lie for a schema and the header's counts.
const FileLayout = struct {
    /// Offset of the masks section: the header's size.
    masks: usize,
    /// Offset of the first field's column.
    columns: usize,
    /// Offset of the metadata section.
    metadata: usize,
    /// Offset of the names section.
    names: usize,
    /// Offset of the payload section.
    payload: usize,
    /// The file's length.
    end: usize,

    fn init(schema: *const Schema, header: *const FileHeader) error{Overflow}!FileLayout {
        const row_count: usize = header.row_count;
        const mask_bytes = std.math.mul(usize, row_count, @as(usize, header.mask_words) * @sizeOf(u64)) catch return error.Overflow;
        const masks: usize = @sizeOf(FileHeader);
        var offset = try fileSectionEnd(masks, mask_bytes);
        const columns = offset;
        for (schema.fields) |field| {
            const column_bytes = std.math.mul(usize, row_count, field.stride) catch return error.Overflow;
            offset = try fileSectionEnd(offset, column_bytes);
        }
        const metadata = offset;
        offset = try fileSectionEnd(offset, header.metadata_bytes);
        const names = offset;
        offset = try fileSectionEnd(offset, header.names_bytes);
        const payload = offset;
        const payload_bytes = std.math.cast(usize, header.payload_bytes) orelse return error.Overflow;
        const end = std.math.add(usize, offset, payload_bytes) catch return error.Overflow;
        return .{ .masks = masks, .columns = columns, .metadata = metadata, .names = names, .payload = payload, .end = end };
    }
};

/// What `writeFile` fails with: no memory (`OutOfMemory`); a section too large for its field in the
/// header (`Overflow`); a cell holding an atom whose name is not interned (`UnnamedAtom`).
pub const FileWriteError = error{ OutOfMemory, Overflow, UnnamedAtom };

/// Whether a field's cells hold atoms, whose names a file keeps: an atom, or a ref's two.
fn fieldHoldsAtoms(field: *const FieldDescriptor) bool {
    return switch (field.view_kind) {
        .atom => field.size == @sizeOf(Atom),
        .ref => field.size == @sizeOf(Ref),
        else => false,
    };
}

/// The atoms a cell of an atom-holding field holds; the null atom where it holds none.
fn cellAtoms(field: *const FieldDescriptor, cell: []const u8) [2]Atom {
    const none: Atom = @enumFromInt(0);
    if (field.view_kind == .atom) return .{ std.mem.bytesToValue(Atom, cell[0..@sizeOf(Atom)]), none };
    const ref = std.mem.bytesToValue(Ref, cell[0..@sizeOf(Ref)]);
    return .{ ref.table_name, ref.row_name };
}

/// The table's rows as a table file, with `metadata`: the caller owns the bytes. Reads the
/// table's own storage, whatever a journal holds, and leaves the table as it is. The file's
/// payload holds only what the rows' cells name, renumbered from zero. An atom in a cell
/// must be interned in `atoms`: the file keeps its name, without which no reader could.
pub fn writeFile(allocator: std.mem.Allocator, table: *const Table, atoms: *const Atom.Registry, metadata: []const FileMetadata) FileWriteError![]u8 {
    const schema = table.getSchema();
    const row_count = table.liveCount();

    // Each atom once, in the order the columns first hold it.
    var named: std.AutoArrayHashMapUnmanaged(Atom, []const u8) = .empty;
    defer named.deinit(allocator);
    var names_bytes: usize = 0;
    for (schema.fields) |*field| {
        if (!fieldHoldsAtoms(field)) continue;
        for (0..row_count) |position| {
            const row = table.rowAtPosition(@intCast(position));
            if (!table.storedMask(row).has(field.bit)) continue;
            for (cellAtoms(field, table.rowCellBytes(row, field))) |atom| {
                if (@intFromEnum(atom) == 0 or named.contains(atom)) continue;
                const name = atoms.lookup(atom) orelse return error.UnnamedAtom;
                try named.put(allocator, atom, name);
                names_bytes += @sizeOf(u32) + name.len;
            }
        }
    }

    // Field by field, as the payloads are then written: padding depends on their order.
    var payload_bytes: usize = 0;
    for (schema.fields) |*field| {
        if (!field.isPayload()) continue;
        for (0..row_count) |position| {
            const row = table.rowAtPosition(@intCast(position));
            if (!table.storedMask(row).has(field.bit)) continue;
            const cell = std.mem.bytesToValue(Payload, table.rowCellBytes(row, field)[0..@sizeOf(Payload)]);
            if (cell.len == 0) continue;
            payload_bytes = std.mem.alignForward(usize, payload_bytes, field.payloadAlignment().toByteUnits()) + cell.len;
        }
    }
    var metadata_bytes: usize = 0;
    for (metadata) |entry| {
        const entry_bytes = 2 * @sizeOf(u32) + entry.key.len + entry.value.len;
        metadata_bytes = std.math.add(usize, metadata_bytes, entry_bytes) catch return error.Overflow;
    }
    if (payload_bytes > std.math.maxInt(u32) or metadata_bytes > std.math.maxInt(u32) or names_bytes > std.math.maxInt(u32)) return error.Overflow;

    var header: FileHeader = .{
        .schema_hash = fileSchemaHash(schema),
        .row_count = row_count,
        .mask_words = schema.maskWords(),
        .field_count = @intCast(schema.fields.len),
        .metadata_count = std.math.cast(u32, metadata.len) orelse return error.Overflow,
        .metadata_bytes = @intCast(metadata_bytes),
        .names_count = @intCast(named.count()),
        .names_bytes = @intCast(names_bytes),
        .payload_bytes = payload_bytes,
        .crc32 = 0,
    };
    const layout = try FileLayout.init(schema, &header);
    const bytes = try allocator.alloc(u8, layout.end);
    errdefer allocator.free(bytes);
    // Padding between sections is zero, so the same rows always make the same file.
    @memset(bytes, 0);

    const mask_word_bytes = @as(usize, header.mask_words) * @sizeOf(u64);
    var payload_end: usize = 0;
    for (0..row_count) |position| {
        const row = table.rowAtPosition(@intCast(position));
        const mask = table.storedMask(row);
        @memcpy(bytes[layout.masks + position * mask_word_bytes ..][0..mask_word_bytes], std.mem.sliceAsBytes(mask.words[0..header.mask_words]));
    }
    var column = layout.columns;
    for (schema.fields) |*field| {
        for (0..row_count) |position| {
            if (field.stride == 0) break;
            const row = table.rowAtPosition(@intCast(position));
            if (!table.storedMask(row).has(field.bit)) continue;
            const source = table.rowCellBytes(row, field);
            const saved = bytes[column + position * field.stride ..][0..field.stride];
            if (!field.isPayload()) {
                @memcpy(saved, source);
                continue;
            }
            const cell = std.mem.bytesToValue(Payload, source[0..@sizeOf(Payload)]);
            if (cell.len == 0) continue;
            const offset = std.mem.alignForward(usize, payload_end, field.payloadAlignment().toByteUnits());
            @memcpy(bytes[layout.payload + offset ..][0..cell.len], table.payloads.bytesOf(cell));
            payload_end = offset + cell.len;
            const renumbered: Payload = .{ .offset = @intCast(offset), .len = cell.len };
            @memcpy(saved, std.mem.asBytes(&renumbered));
        }
        column = fileSectionEnd(column, @as(usize, row_count) * field.stride) catch unreachable;
    }
    std.debug.assert(payload_end == payload_bytes);

    var entry_offset = layout.metadata;
    for (metadata) |entry| {
        const lengths = [2]u32{ @intCast(entry.key.len), @intCast(entry.value.len) };
        @memcpy(bytes[entry_offset..][0..@sizeOf([2]u32)], std.mem.asBytes(&lengths));
        entry_offset += @sizeOf([2]u32);
        @memcpy(bytes[entry_offset..][0..entry.key.len], entry.key);
        entry_offset += entry.key.len;
        @memcpy(bytes[entry_offset..][0..entry.value.len], entry.value);
        entry_offset += entry.value.len;
    }
    var name_offset = layout.names;
    for (named.values()) |name| {
        const name_len: u32 = @intCast(name.len);
        @memcpy(bytes[name_offset..][0..@sizeOf(u32)], std.mem.asBytes(&name_len));
        name_offset += @sizeOf(u32);
        @memcpy(bytes[name_offset..][0..name.len], name);
        name_offset += name.len;
    }

    header.crc32 = crc32(bytes[@sizeOf(FileHeader)..]);
    @memcpy(bytes[0..@sizeOf(FileHeader)], std.mem.asBytes(&header));
    return bytes;
}

/// What reading a table file fails with: fewer bytes than the header or its sections say
/// (`Truncated`) or more (`TrailingData`); not a table file (`BadMagic`) or one of another version
/// (`VersionMismatch`); saved with another schema (`SchemaMismatch`); a checksum that does not
/// match (`CrcMismatch`); contents that cannot be right, as a mask bit past the schema's fields, a
/// payload cell outside the payload, a malformed metadata or names section, or two rows for a
/// singleton (`InvalidFile`); a table that already has rows (`TableNotEmpty`); `OutOfMemory`; a
/// size past what the machine addresses (`Overflow`).
pub const FileReadError = error{ Truncated, BadMagic, VersionMismatch, SchemaMismatch, InvalidFile, CrcMismatch, TrailingData, TableNotEmpty, OutOfMemory, Overflow };

/// A file's header, checked only for being one: enough to tell which schema the file wants.
pub fn fileHeader(bytes: []const u8) FileReadError!FileHeader {
    if (bytes.len < @sizeOf(FileHeader)) return error.Truncated;
    const header = std.mem.bytesToValue(FileHeader, bytes[0..@sizeOf(FileHeader)]);
    if (!std.mem.eql(u8, &header.magic, &file_magic)) return error.BadMagic;
    if (header.version != file_version) return error.VersionMismatch;
    if (header.reserved != 0) return error.InvalidFile;
    return header;
}

/// Checks a whole file against `schema`: its hash, its sections' sizes, its checksum, every
/// row's mask, every payload cell's range and every metadata entry. A file that passes loads.
fn validateFile(schema: *const Schema, bytes: []const u8) FileReadError!FileLayout {
    const header = try fileHeader(bytes);
    if (header.schema_hash != fileSchemaHash(schema)) return error.SchemaMismatch;
    if (header.field_count != schema.fields.len or header.mask_words != schema.maskWords()) return error.SchemaMismatch;
    const layout = try FileLayout.init(schema, &header);
    if (bytes.len < layout.end) return error.Truncated;
    if (bytes.len > layout.end) return error.TrailingData;
    if (crc32(bytes[@sizeOf(FileHeader)..]) != header.crc32) return error.CrcMismatch;

    const valid_mask = Mask.firstBits(schema.fields.len);
    const mask_word_bytes = @as(usize, header.mask_words) * @sizeOf(u64);
    for (0..header.row_count) |position| {
        const mask = fileRowMask(bytes, &layout, mask_word_bytes, position);
        if (!valid_mask.containsAll(mask)) return error.InvalidFile;
    }
    var column = layout.columns;
    for (schema.fields) |*field| {
        if (field.isPayload()) {
            for (0..header.row_count) |position| {
                const mask = fileRowMask(bytes, &layout, mask_word_bytes, position);
                if (!mask.has(field.bit)) continue;
                const cell = std.mem.bytesToValue(Payload, bytes[column + position * field.stride ..][0..@sizeOf(Payload)]);
                if (cell.len == 0) continue;
                if (cell.offset > header.payload_bytes or cell.len > header.payload_bytes - cell.offset) return error.InvalidFile;
                if (!field.payloadAlignment().check(cell.offset)) return error.InvalidFile;
            }
        }
        column = fileSectionEnd(column, @as(usize, header.row_count) * field.stride) catch unreachable;
    }
    var entries: FileMetadataIterator = .{ .bytes = bytes[layout.metadata..][0..header.metadata_bytes], .remaining = header.metadata_count };
    while (entries.remaining != 0) _ = entries.next() orelse return error.InvalidFile;
    if (entries.bytes.len != 0) return error.InvalidFile;
    var names: FileNameIterator = .{ .bytes = bytes[layout.names..][0..header.names_bytes], .remaining = header.names_count };
    while (names.remaining != 0) _ = names.next() orelse return error.InvalidFile;
    if (names.bytes.len != 0) return error.InvalidFile;
    return layout;
}

/// A file's atom names, in the order they were saved.
const FileNameIterator = struct {
    /// The names not yet read.
    bytes: []const u8,
    /// How many names are not yet read.
    remaining: u32,

    /// The next name; null at the end, or where the bytes do not hold another whole name.
    fn next(names: *FileNameIterator) ?[]const u8 {
        if (names.remaining == 0) return null;
        if (names.bytes.len < @sizeOf(u32)) return null;
        const len = std.mem.bytesToValue(u32, names.bytes[0..@sizeOf(u32)]);
        const rest = names.bytes[@sizeOf(u32)..];
        if (len > rest.len) return null;
        names.bytes = rest[len..];
        names.remaining -= 1;
        return rest[0..len];
    }
};

fn fileRowMask(bytes: []const u8, layout: *const FileLayout, mask_word_bytes: usize, position: usize) Mask {
    var mask: Mask = .empty;
    @memcpy(std.mem.sliceAsBytes(&mask.words)[0..mask_word_bytes], bytes[layout.masks + position * mask_word_bytes ..][0..mask_word_bytes]);
    return mask;
}

/// Loads a file's rows into `table`, which is empty and unjournaled and whose schema the
/// file was saved with, and interns the names of the atoms its cells hold. The file is
/// checked whole first: one that is refused leaves the table as it was, but for the capacity
/// it reserved and the names it interned.
pub fn readFile(table: *Table, atoms: *Atom.Registry, bytes: []const u8) FileReadError!void {
    std.debug.assert(table.journal == null);
    if (table.liveCount() != 0) return error.TableNotEmpty;
    const schema = table.getSchema();
    const layout = try validateFile(schema, bytes);
    const header = std.mem.bytesToValue(FileHeader, bytes[0..@sizeOf(FileHeader)]);
    if (table.isSingleton() and header.row_count > 1) return error.InvalidFile;

    if (!table.isSingleton() and header.row_count > table.rowCapacity()) {
        table.reserveCapacity(header.row_count) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Overflow => error.Overflow,
        };
    }
    var names: FileNameIterator = .{ .bytes = bytes[layout.names..][0..header.names_bytes], .remaining = header.names_count };
    while (names.next()) |name| try atoms.tryInternAll(&.{name});
    // The file's payload is one run of the arena, so its cells keep their offsets from it.
    table.payloads.reset();
    const blob_size = std.math.cast(usize, header.payload_bytes) orelse return error.Overflow;
    const blob = try table.payloads.allocate(blob_size, bytes_alignment);
    @memcpy(table.payloads.bytesOf(blob), bytes[layout.payload..][0..blob_size]);

    const mask_word_bytes = @as(usize, header.mask_words) * @sizeOf(u64);
    for (0..header.row_count) |position| {
        const handle = table.alloc() catch {
            contract.invariant(false, "table.file.reserved_capacity");
            unreachable;
        };
        const mask = fileRowMask(bytes, &layout, mask_word_bytes, position);
        table.setStoredMask(handle.row, mask);
        var column = layout.columns;
        for (schema.fields) |*field| {
            defer column = fileSectionEnd(column, @as(usize, header.row_count) * field.stride) catch unreachable;
            if (field.stride == 0 or !mask.has(field.bit)) continue;
            const saved = bytes[column + position * field.stride ..][0..field.stride];
            const cell = table.rowCellBytes(handle.row, field);
            if (!field.isPayload()) {
                @memcpy(cell, saved);
                continue;
            }
            var payload = std.mem.bytesToValue(Payload, saved[0..@sizeOf(Payload)]);
            if (payload.len == 0) payload = .{} else payload.offset += blob.offset;
            @memcpy(cell, std.mem.asBytes(&payload));
        }
    }
    table.touch();
}

/// The metadata of a file `readFile` accepted or would accept for `schema`; its keys and
/// values are slices of `bytes`.
pub fn fileMetadata(schema: *const Schema, bytes: []const u8) FileReadError!FileMetadataIterator {
    const layout = try validateFile(schema, bytes);
    const header = std.mem.bytesToValue(FileHeader, bytes[0..@sizeOf(FileHeader)]);
    return .{ .bytes = bytes[layout.metadata..][0..header.metadata_bytes], .remaining = header.metadata_count };
}

/// Walks a table file's metadata entries; from `fileMetadata`.
pub const FileMetadataIterator = struct {
    /// The entries not yet read: a slice of the file's bytes.
    bytes: []const u8,
    /// How many entries are not yet read.
    remaining: u32,

    /// The next entry; null at the end, or where the bytes do not hold another whole entry.
    pub fn next(entries: *FileMetadataIterator) ?FileMetadata {
        if (entries.remaining == 0) return null;
        if (entries.bytes.len < @sizeOf([2]u32)) return null;
        const lengths = std.mem.bytesToValue([2]u32, entries.bytes[0..@sizeOf([2]u32)]);
        const rest = entries.bytes[@sizeOf([2]u32)..];
        if (lengths[0] > rest.len or lengths[1] > rest.len - lengths[0]) return null;
        entries.bytes = rest[@as(usize, lengths[0]) + lengths[1] ..];
        entries.remaining -= 1;
        return .{ .key = rest[0..lengths[0]], .value = rest[lengths[0]..][0..lengths[1]] };
    }
};

const testing = std.testing;

test "table_storage Layout checks alignment multiplication and atomic overflow" {
    var layout: table_storage.Layout = .{};
    try testing.expectEqual(@as(usize, 0), try layout.append(3, .@"1"));
    try testing.expectEqual(@as(usize, 8), try layout.appendArray(u64, 2));
    try testing.expectEqual(@as(usize, 24), layout.size);
    try testing.expectEqual(std.mem.Alignment.@"8", layout.alignment);
    const before = layout;
    try testing.expectError(error.Overflow, layout.appendArray(u64, std.math.maxInt(usize)));
    try testing.expectEqualDeep(before, layout);
    layout.size = std.math.maxInt(usize) - 1;
    const near_limit = layout;
    try testing.expectError(error.Overflow, layout.append(1, .@"8"));
    try testing.expectEqualDeep(near_limit, layout);
}
const Vec2f = @import("math.zig").Vec2f;

/// Whether `name` is a well-formed key: a lowercase letter, then lowercase letters, digits, `_`,
/// `.` or `-`. A table document's metadata keys are checked with it (`table_document.validKey`); a
/// schema's `addField*` take any name.
pub fn validFieldName(name: []const u8) bool {
    if (name.len == 0 or !std.ascii.isLower(name[0])) return false;
    for (name[1..]) |c| {
        if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '_' and c != '.' and c != '-') return false;
    }
    return true;
}

/// The name of the table a document's new rows are staged in before they replace the live ones:
/// `.staging.table.<id_name>`, written into `buf`. Null when `buf` is too small.
pub fn stagingTableName(buf: []u8, id_name: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, ".staging.table.{s}", .{id_name}) catch null;
}

/// Makes the staging table for the document `id_name` (`stagingTableName`): an empty table of the
/// schema registered as `schema_name`, in `memory_scope` when one is given, in place of any staging
/// table left from before. The caller fills it and hands it to `prepareReplacement`. Host code's,
/// as the resources system uses it; the staging name is interned in `atoms_arg`.
/// `error.NameTooLong` for an id whose staging name passes 256 bytes; otherwise as
/// `unregisterSchema` and `createNamed` or `createNamedScoped`.
pub fn stageRebuildNamedIn(tables: *Registry, atoms_arg: *Atom.Registry, id_name: []const u8, schema_name: Atom, capacity: u32, lifetime: Table.Lifetime, memory_scope: ?memory_mod.Scope.Id) !Handle {
    var buf: [256]u8 = undefined;
    const staging_text = stagingTableName(&buf, id_name) orelse return error.NameTooLong;
    const staging_name = atoms_arg.intern(staging_text);
    if (tables.findHandleByName(staging_name)) |h| tables.destroy(h);
    if (!tables.isSchemaEnforced(staging_name)) try tables.unregisterSchema(staging_name);
    if (memory_scope) |id| return tables.createNamedScoped(id, schema_name, capacity, staging_name, lifetime);
    return tables.createNamed(schema_name, capacity, staging_name, lifetime);
}

/// A field's durable type: the one it declares, else the one its view implies (`checkbox` a tag,
/// `toggle` a bool, `ref`, `color`, `atom`, `float_slider` an `f32`, a `vector` of two or three
/// components a `vec2f` or `vec3f`) where its size agrees. Null for a field with neither, which is
/// opaque bytes.
pub fn durableFieldType(desc: *const Table.FieldDescriptor) ?Table.FieldType {
    if (desc.field_type) |ft| return ft;
    return switch (desc.view_kind) {
        .checkbox => .tag,
        .toggle => if (desc.size == @sizeOf(bool)) .bool else null,
        .ref => if (desc.size == @sizeOf(Ref)) .ref else null,
        .color => .color,
        .atom => .atom,
        .float_slider => .f32,
        .vector => |cfg| if (cfg.components == 2 and desc.size == @sizeOf(math.Vec2f)) .vec2f else if (cfg.components == 3 and desc.size == @sizeOf(math.Vec3f)) .vec3f else null,
        else => null,
    };
}

/// Whether a saved field of `field_type` may have the view `view_kind`.
pub fn isDurableFieldCombo(field_type: Table.FieldType, view_kind: Table.ViewKind) bool {
    return switch (field_type) {
        .f32 => view_kind == .float_slider or view_kind == .int,
        .i32 => view_kind == .int,
        .u8, .u32, .u64 => view_kind == .int or view_kind == .hex,
        .fixed => view_kind == .hex or view_kind == .vector or view_kind == .text_field,
        .vec2f, .vec3f => view_kind == .vector,
        .color => view_kind == .color,
        .string => view_kind == .text_field,
        .bytes => view_kind == .bytes,
        .atom => view_kind == .atom,
        .tag => view_kind == .checkbox,
        .bool => view_kind == .toggle,
        .ref => view_kind == .ref,
    };
}

/// Whether the table can be saved as a document: every field has a durable type
/// (`durableFieldType`) and a view that goes with it (`isDurableFieldCombo`).
pub fn schemaPersistable(table: *const Table) bool {
    for (table.getSchema().fields) |*f| {
        const field_type = durableFieldType(f) orelse return false;
        if (!isDurableFieldCombo(field_type, f.view_kind)) return false;
    }
    return true;
}

fn testSchema() Table.Schema {
    const fields = [_]Table.FieldDescriptor{
        .{ .name = "position", .size = @sizeOf(Vec2f), .stride = @sizeOf(Vec2f), .column_index = 0, .bit = 0 },
        .{ .name = "velocity", .size = @sizeOf(Vec2f), .stride = @sizeOf(Vec2f), .column_index = 1, .bit = 1 },
        .{ .name = "health", .size = @sizeOf(f32), .stride = @sizeOf(f32), .column_index = 2, .bit = 2 },
        .{ .name = "name", .size = 32, .stride = 32, .column_index = 3, .bit = 3 },
    };
    return .{ .fields = &fields };
}

fn cloneSchemaFailureCase(allocator: std.mem.Allocator, schema: *const Table.Schema) !void {
    var cloned = try schema.clone(allocator);
    defer cloned.deinit();
    try std.testing.expect(schemasEqual(schema, &cloned));
}

test "schema cloning propagates every allocation failure without leaking names" {
    var schema: Table.Schema = undefined;
    try schema.initWithAtoms(testing.allocator, null, 2);
    defer schema.deinit();
    schema.addFieldType("position", .vec3f, 12, .{ .vector = .{ .components = 3 } });
    schema.addFieldType("kind", .atom, 8, .atom);
    try testing.checkAllAllocationFailures(testing.allocator, cloneSchemaFailureCase, .{&schema});
}

test "flattened schema layout" {
    const schema = testSchema();
    try testing.expectEqual(@as(usize, 4), schema.fields.len);

    var seen_columns = std.StaticBitSet(64).initEmpty();
    var seen_bits = std.StaticBitSet(64).initEmpty();
    for (schema.fields) |f| {
        try testing.expect(!seen_columns.isSet(f.column_index));
        seen_columns.set(f.column_index);
        try testing.expect(!seen_bits.isSet(f.bit));
        seen_bits.set(f.bit);
        try testing.expect(f.bit < 64);
    }

    try testing.expectEqual(@as(?usize, 0), schema.fieldIndex("position"));
    try testing.expectEqual(@as(?usize, null), schema.fieldIndex("nonexistent"));
}

test "builder produces expected schema" {
    var kw: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try kw.init(&mem);
    defer kw.deinit();

    var schema: Table.Schema = undefined;
    try schema.init(testing.allocator, &kw, 4);
    defer schema.deinit();
    schema.addField("position", Vec2f, .text_field);
    schema.addField("velocity", Vec2f, .text_field);
    schema.addField("health", f32, .{ .float_slider = .{ .min = 0, .max = 100 } });
    schema.addField("name", [32]u8, .text_field);

    const expected = testSchema();

    try testing.expectEqual(expected.fields.len, schema.fields.len);
    for (expected.fields, schema.fields) |e, b| {
        try testing.expectEqualStrings(e.name, b.name);
        try testing.expectEqual(e.size, b.size);
        try testing.expectEqual(e.stride, b.stride);
        try testing.expectEqual(e.column_index, b.column_index);
        try testing.expectEqual(e.bit, b.bit);
    }
}

test "alloc/free round trip with generation bump" {
    const schema = testSchema();
    var table_registry: Registry = undefined;
    var table_memory: memory_mod.Memory = undefined;
    table_memory.init(testing.allocator);
    defer table_memory.deinit();
    try table_registry.init(&table_memory, 1);
    defer table_registry.deinit();
    const table_handle = try table_registry.create(&schema, 4, Atom.from("test"), .durable);
    const table = table_registry.get(table_handle).?;

    const h1 = try table.alloc();
    const h2 = try table.alloc();
    try testing.expect(h1.row != h2.row);

    table.free(h1);
    try testing.expect(!table.valid(h1));

    const h3 = try table.alloc();
    try testing.expectEqual(h1.row, h3.row);
    try testing.expect(h3.generation != h1.generation);
    try testing.expect(table.valid(h3));
    try testing.expect(!table.valid(h1));
}

test "dense deletion preserves logical handles and reverse mappings through reuse grow and clear" {
    var memory: memory_mod.Memory = undefined;
    memory.init(testing.allocator);
    defer memory.deinit();
    var registry: Registry = undefined;
    try registry.init(&memory, 1);
    defer registry.deinit();
    const schema = testSchema();
    const identity = try registry.create(&schema, 6, Atom.from("dense_rows"), .durable);
    const table = registry.get(identity).?;
    var handles: [5]Table.RowHandle = undefined;
    for (&handles, 0..) |*handle, i| handle.* = table.insert(.{ .health = @as(f32, @floatFromInt(i + 10)) });
    const peer_generation = handles[4].generation;
    table.free(handles[1]);
    try testing.expect(!table.valid(handles[1]));
    try testing.expectEqual(@as(u32, 4), table.count());
    try testing.expectEqual(@as(u32, 1), table.storage.columnar.index.at(handles[4].row).*);
    try testing.expectEqual(handles[4].row, table.storage.columnar.row_id.at(1).*);
    try testing.expectEqual(peer_generation, table.rowGeneration(handles[4].row));
    try testing.expectEqual(@as(f32, 14), table.getField(f32, handles[4], "health").?.*);
    table.free(handles[3]); // Current physical tail: no peer copy needed.
    try testing.expectEqual(@as(u32, 3), table.count());
    const reused_tail = try table.alloc();
    const reused_middle = try table.alloc();
    try testing.expectEqual(handles[3].row, reused_tail.row);
    try testing.expectEqual(handles[1].row, reused_middle.row);
    try testing.expect(!table.valid(handles[3]));
    try testing.expect(!table.valid(handles[1]));
    try registry.grow(identity, 12);
    var row_iterator = table.rows();
    var visited: usize = 0;
    while (row_iterator.next()) |handle| {
        const position = table.storage.columnar.index.at(handle.row).*;
        try testing.expectEqual(handle.row, table.storage.columnar.row_id.at(position).*);
        try testing.expectEqual(@as(u32, @intCast(visited)), position);
        visited += 1;
    }
    try testing.expectEqual(@as(usize, 5), visited);
    var filtered = table.query(struct { health: *f32 });
    var matching_count: u32 = 0;
    while (filtered.next()) |_| matching_count += 1;
    try testing.expectEqual(@as(u32, 3), matching_count);
    try testing.expectEqual(@as(f32, 14), table.getField(f32, handles[4], "health").?.*);
    try testing.expect(table.valid(reused_tail));
    table.clear();
    try testing.expectEqual(@as(u32, 0), table.count());
    for (0..table.rowCapacity()) |i| try testing.expectEqual(Table.dead_index, table.storage.columnar.index.at(i).*);
    try testing.expect(!table.valid(handles[4]));
    try testing.expectEqual(@as(u32, 0), (try table.alloc()).row);
}

test "reusable row lookup traverses segments in reverse" {
    var first_values = [_]u32{ 7, 9 };
    var middle_values = [_]u32{ 11, 13 };
    var last_values = [_]u32{ 15, 17 };
    var first: Table.RowArray.Segment = .{ .values = &first_values };
    var middle: Table.RowArray.Segment = .{ .values = &middle_values };
    var last: Table.RowArray.Segment = .{ .values = &last_values };
    var array: Table.RowArray = .{};
    array.append(&first);
    array.append(&middle);
    array.append(&last);
    const reusable: Table.ReusableRows = .{ .array = array, .len = 6 };
    try testing.expectEqual(@as(?usize, 0), reusable.indexOf(7));
    try testing.expectEqual(@as(?usize, 2), reusable.indexOf(11));
    try testing.expectEqual(@as(?usize, 3), reusable.indexOf(13));
    try testing.expectEqual(@as(?usize, 5), reusable.indexOf(17));
    try testing.expectEqual(@as(?usize, null), reusable.indexOf(99));
    try testing.expectEqual(@as(?usize, null), (Table.ReusableRows{ .len = 0 }).indexOf(0));
    const singleton: Table.ReusableRows = .{ .singleton = true, .len = 1 };
    try testing.expectEqual(@as(?usize, 0), singleton.indexOf(0));
    try testing.expectEqual(@as(?usize, null), singleton.indexOf(1));
    try testing.expectEqual(@as(?usize, null), (Table.ReusableRows{ .singleton = true, .len = 0 }).indexOf(0));
}

test "logical row access preserves selected allocation, snapshots and iteration" {
    const schema = testSchema();
    var registry: Registry = undefined;
    var memory: memory_mod.Memory = undefined;
    memory.init(testing.allocator);
    defer memory.deinit();
    try registry.init(&memory, 1);
    defer registry.deinit();
    const identity = try registry.create(&schema, 4, Atom.from("logical_access"), .durable);
    const table = registry.get(identity).?;
    try testing.expect(table.rowCapacity() >= 4);
    const before = try testing.allocator.alloc(u32, table.reusableRows().len);
    defer testing.allocator.free(before);
    table.reusableRows().copyTo(before);
    const selected_position = before.len - 3;
    const selected = try table.allocRowId(before[selected_position]);
    try testing.expectEqual(@as(u32, 2), selected.row);
    const remaining = table.reusableRows();
    try testing.expectEqual(before.len - 1, remaining.len);
    for (0..remaining.len) |i| {
        const original_index = if (i < selected_position) i else i + 1;
        try testing.expectEqual(before[original_index], remaining.at(i));
    }
    try testing.expectEqual(@as(?usize, null), table.reusableRows().indexOf(2));
    const first = try table.allocRowId(0);
    try testing.expectError(error.StaleRow, table.allocRowId(first.row));
    table.setMask(selected.row, .{ .words = .{ 5, 0, 0, 0 } });
    @memset(table.rowFieldBytes(selected.row, 0), 0x42);
    try testing.expectEqual(@as(u64, 5), table.rowMask(selected.row).words[0]);
    try testing.expectEqual(selected.generation, table.rowGeneration(selected.row));
    try testing.expectEqual(@as(u8, 0x42), table.rowFieldBytes(selected.row, 0)[0]);
    var buffer: [4]Table.RowHandle = undefined;
    const handles = table.collectHandlesInto(&buffer);
    try testing.expectEqual(@as(usize, 2), handles.len);
    try testing.expect(std.meta.eql(selected, handles[0]));
    try testing.expect(std.meta.eql(first, handles[1]));
    const matching = table.collectQueryHandlesInto(struct { position: *Vec2f }, &buffer);
    try testing.expectEqual(@as(usize, 1), matching.len);
    try testing.expect(std.meta.eql(selected, matching[0]));
    const generation = table.rowGeneration(selected.row);
    table.free(selected);
    table.removeReusableAt(table.reusableRows().len - 1);
    table.restoreRowState(selected.row, generation, .{ .words = .{ 5, 0, 0, 0 } }, true);
    try testing.expectEqual(@as(u8, 0), table.rowFieldBytes(selected.row, 0)[0]);
    @memset(table.rowFieldBytes(selected.row, 0), 0x42); // Payload restoration follows liveness.
    try testing.expect(table.valid(selected));
    try testing.expectEqual(@as(u64, 5), table.rowMask(selected.row).words[0]);
    try registry.reserveRows(identity, 2);
    try testing.expect(table.rowCapacity() >= 4);
    try registry.reserveRows(identity, 8);
    try testing.expect(table.rowCapacity() >= 8);
    try testing.expect(table.valid(selected));
    try testing.expectEqual(@as(u8, 0x42), table.rowFieldBytes(selected.row, 0)[0]);
}

test "getField writes and reads back typed value" {
    const schema = testSchema();
    var table_registry: Registry = undefined;
    var table_memory: memory_mod.Memory = undefined;
    table_memory.init(testing.allocator);
    defer table_memory.deinit();
    try table_registry.init(&table_memory, 1);
    defer table_registry.deinit();
    const table_handle = try table_registry.create(&schema, 4, Atom.from("test"), .durable);
    const table = table_registry.get(table_handle).?;

    const handle = try table.alloc();
    table.getField(Vec2f, handle, "position").?.* = .{ .x = 1, .y = 2 };
    const read_back = table.getField(Vec2f, handle, "position").?.*;
    try testing.expectEqual(@as(f32, 1), read_back.x);
    try testing.expectEqual(@as(f32, 2), read_back.y);

    table.free(handle);
    try testing.expectEqual(@as(?*Vec2f, null), table.getField(Vec2f, handle, "position"));
}

test "payload arena appends without moving, resolves across chunks and resets to one chunk" {
    var source: memory_mod.PageSource = .{};
    var pages: memory_mod.PageBacking = .{ .upstream = .{ .source = &source } };
    var payloads: table_storage.Payloads = .{ .backing = &pages };
    defer payloads.deinit();
    try testing.expectEqual(Payload{}, try payloads.append("", .@"1"));
    const first = try payloads.append("first", .@"1");
    const first_bytes = payloads.bytesOf(first);
    const aligned = try payloads.append(&[_]u8{0xAB} ** 24, .@"16");
    try testing.expectEqual(@as(u32, 0), aligned.offset % 16);
    try testing.expect(std.mem.isAligned(@intFromPtr(payloads.bytesOf(aligned).ptr), 16));
    // Larger than a chunk: a chunk of its own, and what came before stays where it was.
    const large_source = try testing.allocator.alloc(u8, 3 * std.heap.pageSize());
    defer testing.allocator.free(large_source);
    @memset(large_source, 0x5A);
    const large = try payloads.append(large_source, .@"1");
    const after = try payloads.append("after", .@"1");
    try testing.expectEqual(first_bytes.ptr, payloads.bytesOf(first).ptr);
    try testing.expectEqualStrings("first", payloads.bytesOf(first));
    try testing.expectEqualSlices(u8, large_source, payloads.bytesOf(large));
    try testing.expectEqualStrings("after", payloads.bytesOf(after));
    try testing.expect(payloads.holds(large));
    try testing.expect(!payloads.holds(.{ .offset = payloads.end(), .len = 1 }));

    payloads.reset();
    try testing.expectEqual(@as(u32, 0), payloads.end());
    try testing.expect(payloads.first == payloads.last);
    const again = try payloads.append("again", .@"1");
    try testing.expectEqual(@as(u32, 0), again.offset);
    try testing.expectEqualStrings("again", payloads.bytesOf(again));
}

test "string and bytes cells hold payloads that views read as slices" {
    var table_registry: Registry = undefined;
    var table_memory: memory_mod.Memory = undefined;
    table_memory.init(testing.allocator);
    defer table_memory.deinit();
    try table_registry.init(&table_memory, 2);
    defer table_registry.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&table_memory);
    defer atoms.deinit();
    var schema: Schema = undefined;
    try schema.init(testing.allocator, &atoms, 3);
    defer schema.deinit();
    schema.addField("id", i32, .int);
    schema.addField("title", String, .text_field);
    schema.addField("points", Bytes, .bytes);
    try schema.validate();
    try schema.validatePersistentStorage();
    const table_handle = try table_registry.create(&schema, 4, Atom.from("payload_test"), .persistent);
    const table = table_registry.get(table_handle).?;

    const View = struct { id: *i32, title: []const u8, points: []const Vec2f };
    const points = [_]Vec2f{ .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 } };
    const first = try table.tryInsert(.{ .id = @as(i32, 1), .title = @as([]const u8, "a title of any length"), .points = @as([]const Vec2f, &points) });
    const second = try table.tryInsert(.{ .id = @as(i32, 2), .title = @as([]const u8, "") });
    const read = table.getRow(first, View).?;
    try testing.expectEqualStrings("a title of any length", read.title);
    try testing.expectEqualSlices(Vec2f, &points, read.points);
    try testing.expectEqualStrings("", table.cellText(second.row, &table.getSchema().fields[1]));

    // Writing what a cell holds appends nothing; a new value does, and the old bytes stay put.
    const end_before = table.payloads.end();
    try table.setString(first, "title", "a title of any length");
    try testing.expectEqual(end_before, table.payloads.end());
    try table.setString(first, "title", "changed");
    try testing.expect(table.payloads.end() > end_before);
    try testing.expectEqualStrings("a title of any length", read.title);
    try testing.expectEqualStrings("changed", table.getRow(first, View).?.title);
    var titled = table.query(View);
    var titles: usize = 0;
    while (titled.next()) |row| titles += row.view.title.len;
    try testing.expectEqual("changed".len, titles);

    // Compaction keeps what cells name and nothing else.
    try table.compactPayloads();
    try testing.expect(table.payloads.end() < end_before);
    const compacted = table.getRow(first, View).?;
    try testing.expectEqualStrings("changed", compacted.title);
    try testing.expectEqualSlices(Vec2f, &points, compacted.points);

    // A replacement that cannot take the staged pages copies the payloads into its own arena.
    const staged_handle = try table_registry.create(&schema, 1, Atom.from("payload_staged"), .durable);
    const staged = table_registry.get(staged_handle).?;
    _ = try staged.tryInsert(.{ .id = @as(i32, 9), .title = @as([]const u8, "staged title") });
    try table_registry.replaceContentsFallible(table_handle, staged_handle);
    var replaced = table.query(struct { title: []const u8 });
    try testing.expectEqualStrings("staged title", replaced.next().?.view.title);

    table.clear();
    try testing.expectEqual(@as(u32, 0), table.payloads.end());
}

test "getRow returns a View of pointers, null on stale handle" {
    const schema = testSchema();
    var table_registry: Registry = undefined;
    var table_memory: memory_mod.Memory = undefined;
    table_memory.init(testing.allocator);
    defer table_memory.deinit();
    try table_registry.init(&table_memory, 1);
    defer table_registry.deinit();
    const table_handle = try table_registry.create(&schema, 4, Atom.from("test"), .durable);
    const table = table_registry.get(table_handle).?;

    const handle = try table.alloc();
    table.getField(Vec2f, handle, "position").?.* = .{ .x = 1, .y = 2 };
    table.getField(f32, handle, "health").?.* = 42;

    const View = struct { position: *Vec2f, health: *f32 };
    const row = table.getRow(handle, View).?;
    try testing.expectEqual(@as(f32, 1), row.position.x);
    try testing.expectEqual(@as(f32, 2), row.position.y);
    try testing.expectEqual(@as(f32, 42), row.health.*);

    table.free(handle);
    try testing.expectEqual(@as(?View, null), table.getRow(handle, View));
}

test "getRow projects compacted and singleton rows without presence filtering" {
    const schema = testSchema();
    var memory: memory_mod.Memory = undefined;
    memory.init(testing.allocator);
    defer memory.deinit();
    var registry: Registry = undefined;
    try registry.init(&memory, 2);
    defer registry.deinit();
    const columnar_handle = try registry.create(&schema, 4, Atom.from("getrow_columnar"), .durable);
    const singleton_handle = try registry.createSingleton(&schema, Atom.from("getrow_singleton"), .durable);
    const columnar = registry.get(columnar_handle).?;
    const singleton = registry.get(singleton_handle).?;
    const View = struct { position: *Vec2f, health: *f32 };

    const removed = columnar.insert(.{ .health = @as(f32, 10) });
    const moved = columnar.insert(.{ .position = Vec2f{ .x = 3, .y = 4 } });
    columnar.getField(f32, moved, "health").?.* = 42;
    columnar.free(removed);
    const row = columnar.getRow(moved, View).?;
    try testing.expectEqual(columnar.getField(Vec2f, moved, "position").?, row.position);
    try testing.expectEqual(columnar.getField(f32, moved, "health").?, row.health);
    try testing.expectEqual(@as(f32, 42), row.health.*);
    const health_index = columnar.getSchema().fieldIndex("health").?;
    try testing.expect(!columnar.rowHas(moved.row, columnar.getSchema().fields[health_index].bit));
    try testing.expect(columnar.getRow(removed, View) == null);
    const dead = Table.RowHandle{ .row = removed.row, .generation = columnar.rowGeneration(removed.row) };
    try testing.expect(columnar.getRow(dead, View) == null);
    const reused = try columnar.alloc();
    try testing.expectEqual(removed.row, reused.row);
    try testing.expect(columnar.getRow(removed, View) == null);
    const fabricated = Table.RowHandle{ .row = moved.row, .generation = moved.generation +% 1 };
    try testing.expect(columnar.getRow(fabricated, View) == null);
    const out_of_range = Table.RowHandle{ .row = std.math.maxInt(u32), .generation = 0 };
    try testing.expect(columnar.getRow(out_of_range, View) == null);

    const scalar = try singleton.alloc();
    singleton.getField(f32, scalar, "health").?.* = 17;
    const scalar_row = singleton.getRow(scalar, View).?;
    try testing.expectEqual(singleton.getField(Vec2f, scalar, "position").?, scalar_row.position);
    try testing.expectEqual(singleton.getField(f32, scalar, "health").?, scalar_row.health);
    try testing.expectEqual(@as(f32, 17), scalar_row.health.*);
    singleton.free(scalar);
    try testing.expect(singleton.getRow(scalar, View) == null);
    try testing.expect(singleton.getRow(out_of_range, View) == null);
}

test "setRowMask sets bits for the row's View fields" {
    const schema = testSchema();
    var table_registry: Registry = undefined;
    var table_memory: memory_mod.Memory = undefined;
    table_memory.init(testing.allocator);
    defer table_memory.deinit();
    try table_registry.init(&table_memory, 1);
    defer table_registry.deinit();
    const table_handle = try table_registry.create(&schema, 4, Atom.from("test"), .durable);
    const table = table_registry.get(table_handle).?;

    const handle = try table.alloc();
    try testing.expect(table.rowMask(@intCast(handle.row)).isEmpty());

    const View = struct { position: *Vec2f, health: *f32 };
    const row = table.getRow(handle, View).?;
    row.position.* = .{ .x = 1, .y = 2 };
    row.health.* = 42;
    table.setRowMask(handle, row);

    try testing.expectEqual(schema.mask(&.{ "position", "health" }), table.rowMask(@intCast(handle.row)));
}

test "writeFieldSingle sets bitmask bit and is readable" {
    const schema = testSchema();
    var table_registry: Registry = undefined;
    var table_memory: memory_mod.Memory = undefined;
    table_memory.init(testing.allocator);
    defer table_memory.deinit();
    try table_registry.init(&table_memory, 1);
    defer table_registry.deinit();
    const table_handle = try table_registry.create(&schema, 4, Atom.from("test"), .durable);
    const table = table_registry.get(table_handle).?;

    const handle = try table.alloc();
    try testing.expect(table.rowMask(@intCast(handle.row)).isEmpty());

    try table.writeFieldSingle(Vec2f, handle, "position", .{ .x = 3, .y = 4 });
    try testing.expectEqual(@as(u64, 1), table.rowMask(@intCast(handle.row)).words[0]);
    const read_back = table.getField(Vec2f, handle, "position").?.*;
    try testing.expectEqual(@as(f32, 3), read_back.x);
    try testing.expectEqual(@as(f32, 4), read_back.y);
}

test "batch query only visits rows with required bits set" {
    const schema = testSchema();
    var table_registry: Registry = undefined;
    var table_memory: memory_mod.Memory = undefined;
    table_memory.init(testing.allocator);
    defer table_memory.deinit();
    try table_registry.init(&table_memory, 1);
    defer table_registry.deinit();
    const table_handle = try table_registry.create(&schema, 4, Atom.from("test"), .durable);
    const table = table_registry.get(table_handle).?;

    const only_pos = try table.alloc();
    try table.writeFieldSingle(Vec2f, only_pos, "position", .{ .x = 1, .y = 1 });

    const pos_and_vel = try table.alloc();
    try table.writeFieldSingle(Vec2f, pos_and_vel, "position", .{ .x = 5, .y = 6 });
    try table.writeFieldSingle(Vec2f, pos_and_vel, "velocity", .{ .x = 0.5, .y = -0.5 });

    _ = try table.alloc();

    var q = Query(struct { position: *Vec2f, velocity: *Vec2f }).init(table);
    var matches: u32 = 0;
    while (q.next()) |e| {
        matches += 1;
        try testing.expectEqual(pos_and_vel.row, e.handle.row);
        try testing.expectEqual(@as(f32, 5), e.view.position.x);
        try testing.expectEqual(@as(f32, -0.5), e.view.velocity.y);
    }
    try testing.expectEqual(@as(u32, 1), matches);
}

test "EntityView yields only present fields in schema order" {
    const schema = testSchema();
    var table_registry: Registry = undefined;
    var table_memory: memory_mod.Memory = undefined;
    table_memory.init(testing.allocator);
    defer table_memory.deinit();
    try table_registry.init(&table_memory, 1);
    defer table_registry.deinit();
    const table_handle = try table_registry.create(&schema, 4, Atom.from("test"), .durable);
    const table = table_registry.get(table_handle).?;

    const handle = try table.alloc();
    try table.writeFieldSingle(Vec2f, handle, "position", .{ .x = 1, .y = 2 });
    try table.writeFieldSingle(f32, handle, "health", 42);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const view = try Table.EntityView.build(arena.allocator(), table, handle);

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(testing.allocator);
    var it = view.head;
    while (it) |node| : (it = node.next) try names.append(testing.allocator, node.name);

    try testing.expectEqual(@as(usize, 2), names.items.len);
    try testing.expectEqualStrings("position", names.items[0]);
    try testing.expectEqualStrings("health", names.items[1]);
}

/// Recomputes a file's checksum after a test changed its bytes, so the change is what the
/// reader judges.
fn resealTestFile(bytes: []u8) void {
    const header = std.mem.bytesAsValue(FileHeader, bytes[0..@sizeOf(FileHeader)]);
    header.crc32 = crc32(bytes[@sizeOf(FileHeader)..]);
}

test "a table file round trips rows, absent cells, payloads and metadata" {
    var memory: memory_mod.Memory = undefined;
    memory.init(testing.allocator);
    defer memory.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&memory);
    defer atoms.deinit();
    var tables: Registry = undefined;
    try tables.init(&memory, 4);
    defer tables.deinit();
    var schema: Schema = undefined;
    try schema.init(testing.allocator, &atoms, 6);
    defer schema.deinit();
    schema.addField("position", Vec2f, .{ .vector = .{ .components = 2 } });
    schema.addField("health", f32, .{ .float_slider = .{ .min = 0, .max = 100 } });
    schema.addField("title", String, .text_field);
    schema.addField("points", Bytes, .bytes);
    schema.addField("tagged", void, .checkbox);
    schema.addField("kind", Atom, .atom);
    const source = tables.get(try tables.create(&schema, 4, Atom.from("file_source"), .persistent)).?;

    const points = [_]Vec2f{ .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 } };
    const dropped = try source.tryInsert(.{ .position = Vec2f{ .x = 9, .y = 9 }, .title = @as([]const u8, "dropped before saving") });
    const first = try source.tryInsert(.{ .position = Vec2f{ .x = 1, .y = 2 }, .title = @as([]const u8, "first"), .kind = atoms.intern("a_wolf_in_a_file") });
    _ = try source.tryInsert(.{ .health = @as(f32, 75), .title = @as([]const u8, ""), .points = @as([]const Vec2f, &points), .tagged = {} });
    // Dead bytes in the arena are not saved.
    try source.setString(first, "title", "the first row, renamed");
    source.free(dropped);

    const metadata = [_]FileMetadata{ .{ .key = "owner", .value = "test" }, .{ .key = "empty", .value = "" } };
    const bytes = try writeFile(testing.allocator, source, &atoms, &metadata);
    defer testing.allocator.free(bytes);
    const again = try writeFile(testing.allocator, source, &atoms, &metadata);
    defer testing.allocator.free(again);
    try testing.expectEqualSlices(u8, bytes, again);
    const header = try fileHeader(bytes);
    try testing.expectEqual(@as(u32, 2), header.row_count);
    try testing.expectEqual(@as(u64, "the first row, renamed".len + 10 + @sizeOf(@TypeOf(points))), header.payload_bytes);

    const loaded = tables.get(try tables.create(&schema, 1, Atom.from("file_loaded"), .persistent)).?;
    try readFile(loaded, &atoms, bytes);
    try testing.expectEqual(@as(u32, 2), loaded.count());
    const View = struct { position: *Vec2f, title: []const u8 };
    var with_position = loaded.query(View);
    const renamed = with_position.next().?;
    try testing.expectEqualStrings("the first row, renamed", renamed.view.title);
    try testing.expectEqual(@as(f32, 2), renamed.view.position.y);
    try testing.expect(!loaded.rowHas(renamed.handle.row, schema.fields[1].bit));
    try testing.expect(with_position.next() == null);
    var with_points = loaded.query(struct { health: *f32, title: []const u8, points: []const Vec2f, tagged: *void });
    const pointed = with_points.next().?;
    try testing.expectEqual(@as(f32, 75), pointed.view.health.*);
    try testing.expectEqualStrings("", pointed.view.title);
    try testing.expectEqualSlices(Vec2f, &points, pointed.view.points);

    var entries = try fileMetadata(loaded.getSchema(), bytes);
    const owner = entries.next().?;
    try testing.expectEqualStrings("owner", owner.key);
    try testing.expectEqualStrings("test", owner.value);
    try testing.expectEqualStrings("empty", entries.next().?.key);
    try testing.expect(entries.next() == null);

    // A reader that never heard an atom's name learns it from the file.
    var reader_memory: memory_mod.Memory = undefined;
    reader_memory.init(testing.allocator);
    defer reader_memory.deinit();
    var reader_atoms: Atom.Registry = undefined;
    try reader_atoms.init(&reader_memory);
    defer reader_atoms.deinit();
    const elsewhere = tables.get(try tables.create(&schema, 1, Atom.from("file_elsewhere"), .persistent)).?;
    try readFile(elsewhere, &reader_atoms, bytes);
    try testing.expectEqualStrings("a_wolf_in_a_file", reader_atoms.lookup(Atom.from("a_wolf_in_a_file")).?);
    // An atom no one named cannot be saved.
    var kinds = elsewhere.query(struct { kind: *Atom });
    kinds.next().?.view.kind.* = Atom.from("never_interned_anywhere");
    try testing.expectError(error.UnnamedAtom, writeFile(testing.allocator, elsewhere, &atoms, &.{}));

    // A loaded table saves the same file.
    const resaved = try writeFile(testing.allocator, loaded, &atoms, &metadata);
    defer testing.allocator.free(resaved);
    try testing.expectEqualSlices(u8, bytes, resaved);
}

test "a malformed table file is refused before any row is loaded" {
    var memory: memory_mod.Memory = undefined;
    memory.init(testing.allocator);
    defer memory.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&memory);
    defer atoms.deinit();
    var tables: Registry = undefined;
    try tables.init(&memory, 4);
    defer tables.deinit();
    var schema: Schema = undefined;
    try schema.init(testing.allocator, &atoms, 2);
    defer schema.deinit();
    schema.addField("value", i32, .int);
    schema.addField("title", String, .text_field);
    const source = tables.get(try tables.create(&schema, 2, Atom.from("malformed_source"), .durable)).?;
    _ = try source.tryInsert(.{ .value = @as(i32, 7), .title = @as([]const u8, "seven") });
    const intact = try writeFile(testing.allocator, source, &atoms, &.{});
    defer testing.allocator.free(intact);
    const target = tables.get(try tables.create(&schema, 2, Atom.from("malformed_target"), .durable)).?;

    const changed = try testing.allocator.alloc(u8, intact.len + 1);
    defer testing.allocator.free(changed);
    @memcpy(changed[0..intact.len], intact);
    changed[intact.len] = 0;
    try testing.expectError(error.TrailingData, readFile(target, &atoms, changed));
    try testing.expectError(error.Truncated, readFile(target, &atoms, intact[0 .. intact.len - 1]));
    try testing.expectError(error.Truncated, readFile(target, &atoms, intact[0..8]));

    const candidate = changed[0..intact.len];
    candidate[intact.len - 1] ^= 1;
    try testing.expectError(error.CrcMismatch, readFile(target, &atoms, candidate));

    // A presence bit past the schema's fields.
    @memcpy(candidate, intact);
    candidate[@sizeOf(FileHeader)] |= 1 << 5;
    resealTestFile(candidate);
    try testing.expectError(error.InvalidFile, readFile(target, &atoms, candidate));

    // A string cell reaching past the payload.
    @memcpy(candidate, intact);
    const layout = try FileLayout.init(&schema, &(try fileHeader(intact)));
    const title_column = try fileSectionEnd(layout.columns, @sizeOf(i32));
    const cell = std.mem.bytesAsValue(Payload, candidate[title_column..][0..@sizeOf(Payload)]);
    cell.len += 1;
    resealTestFile(candidate);
    try testing.expectError(error.InvalidFile, readFile(target, &atoms, candidate));

    @memcpy(candidate, intact);
    candidate[0] = 'X';
    try testing.expectError(error.BadMagic, readFile(target, &atoms, candidate));
    try testing.expectEqual(@as(u32, 0), target.count());

    // Another schema, even one that differs only in a field's name, is not this file's.
    var other: Schema = undefined;
    try other.init(testing.allocator, &atoms, 2);
    defer other.deinit();
    other.addField("value", i32, .int);
    other.addField("label", String, .text_field);
    const mismatched = tables.get(try tables.create(&other, 2, Atom.from("malformed_other"), .durable)).?;
    try testing.expectError(error.SchemaMismatch, readFile(mismatched, &atoms, intact));

    try readFile(target, &atoms, intact);
    try testing.expectError(error.TableNotEmpty, readFile(target, &atoms, intact));
}

test "failed creation does not leave an orphan inline schema registered" {
    var memory: memory_mod.Memory = undefined;
    memory.init(testing.allocator);
    defer memory.deinit();
    const failing = &memory.page_source;
    var kw: Atom.Registry = undefined;
    try kw.init(&memory);
    defer kw.deinit();
    var tables: Registry = undefined;
    try tables.init(&memory, 1);
    defer tables.deinit();

    var first_schema: Table.Schema = undefined;
    try first_schema.init(testing.allocator, &kw, 1);
    defer first_schema.deinit();
    first_schema.addField("first", i32, .int);
    _ = try tables.create(&first_schema, 1, kw.intern("first.table"), .durable);

    var second_schema: Table.Schema = undefined;
    try second_schema.init(testing.allocator, &kw, 1);
    defer second_schema.deinit();
    second_schema.addField("second", i32, .int);
    const second_name = kw.intern("second.table");
    failing.refuseAfter(0);
    try testing.expectError(error.OutOfMemory, tables.create(&second_schema, 1, second_name, .durable));
    try testing.expect(tables.getSchema(second_name) == null);
}

test "persistent tables reject pointer and undeclared opaque fields" {
    var kw: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try kw.init(&mem);
    defer kw.deinit();

    var tables: Registry = undefined;
    try tables.init(&mem, 4);
    defer tables.deinit();

    var pointer_schema: Table.Schema = undefined;
    try pointer_schema.init(testing.allocator, &kw, 1);
    defer pointer_schema.deinit();
    pointer_schema.addField("pointer", *u32, .hex);
    try testing.expectError(error.PersistentPointerField, tables.create(&pointer_schema, 1, kw.intern("pointer_table"), .persistent));
    try testing.expectEqual(@as(u32, 0), tables.activeCount());

    const NestedPointer = struct { pointer: *u32 };
    var nested_schema: Table.Schema = undefined;
    try nested_schema.init(testing.allocator, &kw, 1);
    defer nested_schema.deinit();
    nested_schema.addField("nested", NestedPointer, .text_field);
    try testing.expectError(error.PersistentPointerField, tables.create(&nested_schema, 1, kw.intern("nested_pointer_table"), .persistent));

    var opaque_schema: Table.Schema = undefined;
    try opaque_schema.init(testing.allocator, &kw, 1);
    defer opaque_schema.deinit();
    opaque_schema.addField("opaque", u64, .hex);
    try testing.expectError(error.PersistentUnsafeField, tables.create(&opaque_schema, 1, kw.intern("opaque_table"), .persistent));

    var safe_opaque_schema: Table.Schema = undefined;
    try safe_opaque_schema.init(testing.allocator, &kw, 1);
    defer safe_opaque_schema.deinit();
    safe_opaque_schema.addFieldWithOptions("opaque", u64, .hex, .{ .persistent_safe = true });
    const safe = try tables.create(&safe_opaque_schema, 1, kw.intern("safe_opaque_table"), .persistent);
    try testing.expectEqual(Table.Lifetime.persistent, tables.get(safe).?.lifetime);
}

test "Registry scope is inherited by created tables" {
    var kw: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try kw.init(&mem);
    defer kw.deinit();

    var tables: Registry = undefined;
    try tables.init(&mem, 4);
    defer tables.deinit();

    var schema: Table.Schema = undefined;
    try schema.init(testing.allocator, &kw, 1);
    defer schema.deinit();
    schema.addField("value", u32, .int);

    tables.scope = .editor;
    const editor_table = try tables.create(&schema, 1, kw.intern("editor_owned"), .durable);
    try testing.expectEqual(Table.Owner.editor, tables.get(editor_table).?.owner);

    tables.scope = .app;
    const app_table = try tables.create(&schema, 1, kw.intern("app_owned"), .durable);
    try testing.expectEqual(Table.Owner.app, tables.get(app_table).?.owner);
}

test "Registry create/destroy round trip with generation bump" {
    const schema = testSchema();
    var tables: Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try tables.init(&mem, 4);
    defer tables.deinit();

    const h1 = try tables.create(&schema, 4, Atom.from("t1"), .durable);
    const h2 = try tables.create(&schema, 4, Atom.from("t2"), .durable);
    try testing.expect(h1.index != h2.index);

    tables.destroy(h1);
    try testing.expect(!tables.valid(h1));

    const h3 = try tables.create(&schema, 4, Atom.from("t3"), .durable);
    try testing.expectEqual(h1.index, h3.index);
    try testing.expect(h3.generation != h1.generation);
    try testing.expect(tables.valid(h3));
    try testing.expect(!tables.valid(h1));
}

test "Registry owns and shares schemas by registered atom name" {
    var kw: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try kw.init(&mem);
    defer kw.deinit();

    var tables: Registry = undefined;
    try tables.init(&mem, 4);
    defer tables.deinit();

    var template: Table.Schema = undefined;
    try template.init(testing.allocator, &kw, 1);
    template.addFieldType("value", .i32, 4, .int);
    const schema_name = kw.intern("shared.schema");
    try tables.registerSchema(schema_name, &template);
    template.deinit();

    const first = try tables.createNamed(schema_name, 2, kw.intern("first"), .durable);
    const second = try tables.createNamed(schema_name, 2, kw.intern("second"), .durable);
    const first_table = tables.get(first).?;
    const second_table = tables.get(second).?;
    try testing.expect(first_table.uses_named_schema);
    try testing.expectEqual(schema_name, first_table.schema_name);
    try testing.expectEqual(first_table.getSchema(), second_table.getSchema());
    try testing.expectEqualStrings("value", first_table.getSchema().fields[0].name);
    const source_row = first_table.insert(.{ .value = @as(i32, 17) });
    const saved = try writeFile(testing.allocator, first_table, &kw, &.{});
    defer testing.allocator.free(saved);
    try readFile(second_table, &kw, saved);
    const imported_row: Table.RowHandle = .{ .row = 0, .generation = second_table.rowGeneration(@intCast(0)) };
    try testing.expect(second_table.valid(imported_row));
    try testing.expectEqual(first_table.getField(i32, source_row, "value").?.*, second_table.getField(i32, imported_row, "value").?.*);
    try testing.expectError(error.UnknownSchema, tables.createNamed(kw.intern("missing.schema"), 1, kw.intern("missing.table"), .durable));
    try testing.expectError(error.SchemaInUse, tables.unregisterSchema(schema_name));

    tables.destroy(first);
    tables.destroy(second);
    try tables.unregisterSchema(schema_name);
}

test "sortByU32 orders live rows by a key, stably, and keeps their handles" {
    const schema = testSchema();
    var table_registry: Registry = undefined;
    var table_memory: memory_mod.Memory = undefined;
    table_memory.init(testing.allocator);
    defer table_memory.deinit();
    try table_registry.init(&table_memory, 1);
    defer table_registry.deinit();
    const table = table_registry.get(try table_registry.create(&schema, 8, Atom.from("sorted"), .durable)).?;

    // Keys in `health`'s four bytes; `position.x` tells the rows apart.
    const keys = [_]u32{ 3, 1, 2, 1 };
    var handles: [keys.len]RowHandle = undefined;
    for (keys, &handles, 0..) |key, *handle, index| {
        handle.* = try table.alloc();
        try table.writeFieldSingle(u32, handle.*, "health", key);
        try table.writeFieldSingle(Vec2f, handle.*, "position", .{ .x = @floatFromInt(index), .y = 0 });
    }
    table.sortByU32(2);

    const expected = [_]f32{ 1, 3, 2, 0 };
    for (expected, 0..) |x, position| {
        const row = table.rowAtPosition(@intCast(position));
        const handle: RowHandle = .{ .row = row, .generation = table.rowGeneration(row) };
        try testing.expectEqual(x, table.getField(Vec2f, handle, "position").?.x);
    }
    // A handle still finds its own row.
    for (handles, 0..) |handle, index| {
        try testing.expectEqual(@as(f32, @floatFromInt(index)), table.getField(Vec2f, handle, "position").?.x);
    }
}

test "Registry.grow preserves handles, rows, free-list order, and revision tracking" {
    const schema = testSchema();
    var table_registry: Registry = undefined;
    var table_memory: memory_mod.Memory = undefined;
    table_memory.init(testing.allocator);
    defer table_memory.deinit();
    try table_registry.init(&table_memory, 1);
    defer table_registry.deinit();
    const table_handle = try table_registry.create(&schema, 4, Atom.from("grow"), .durable);
    const table = table_registry.get(table_handle).?;

    const first = try table.alloc();
    try table.writeFieldSingle(Vec2f, first, "position", .{ .x = 4, .y = 9 });
    const second = try table.alloc();
    try table.writeFieldSingle(f32, second, "health", 72);
    table.free(second);
    const old_revision = table.revision;

    const old_capacity = table.rowCapacity();
    try table_registry.grow(table_handle, old_capacity + 1);
    try testing.expect(table.rowCapacity() > old_capacity);
    try testing.expectEqual(old_revision +% 1, table.revision);
    try testing.expect(table.valid(first));
    try testing.expectEqual(@as(f32, 4), table.getField(Vec2f, first, "position").?.x);
    try testing.expectEqual(@as(f32, 9), table.getField(Vec2f, first, "position").?.y);
    const reused = try table.alloc();
    try testing.expectEqual(second.row, reused.row);
    try testing.expect(reused.generation != second.generation);

    try table_registry.grow(table_handle, 1);
    try table_registry.grow(table_handle, 4);
    try testing.expect(table.valid(first));
    try testing.expect(table.rowCapacity() >= 4);
}

test "Registry.grow reserves space to free every row and keeps truncated tombstones" {
    const schema = testSchema();
    var table_registry: Registry = undefined;
    var table_memory: memory_mod.Memory = undefined;
    table_memory.init(testing.allocator);
    defer table_memory.deinit();
    try table_registry.init(&table_memory, 1);
    defer table_registry.deinit();
    const table_handle = try table_registry.create(&schema, 4, Atom.from("grow_full"), .durable);
    const table = table_registry.get(table_handle).?;
    var handles: [8]Table.RowHandle = undefined;
    for (handles[0..4]) |*handle| handle.* = try table.alloc();
    try table_registry.grow(table_handle, 8);
    for (handles[4..]) |*handle| handle.* = try table.alloc();
    for (handles) |handle| table.free(handle);
    try testing.expectEqual(table.rowCapacity(), table.storage.columnar.free_list.len);
    const stale = handles[7];
    try table_registry.grow(table_handle, 4);
    try table_registry.grow(table_handle, 8);
    for (&handles) |*handle| handle.* = try table.alloc();
    try testing.expect(!table.valid(stale));
}

test "Registry capacity exhaustion" {
    const schema = testSchema();
    var tables: Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try tables.init(&mem, 1);
    defer tables.deinit();

    const first = try tables.create(&schema, 4, Atom.from("t1"), .durable);
    const first_table = tables.get(first).?;
    for (0..300) |i| {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "grown.{d}", .{i});
        const handle = try tables.create(&schema, 1, Atom.from(name), .durable);
        try testing.expect(tables.valid(handle));
    }
    try testing.expect(tables.capacity > 300);
    try testing.expect(tables.valid(first));
    try testing.expect(tables.get(first).? == first_table);
}

test "Registry growth in an admission aborts back to the old registry" {
    var kw: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try kw.init(&mem);
    defer kw.deinit();
    var schema: Table.Schema = undefined;
    try schema.init(testing.allocator, &kw, 1);
    defer schema.deinit();
    schema.addField("value", i32, .int);
    var tables: Registry = undefined;
    try tables.init(&mem, 2);
    defer tables.deinit();
    const kept = try tables.create(&schema, 1, Atom.from("kept"), .durable);
    const kept_table = tables.get(kept).?;
    const free_before = try testing.allocator.dupe(u32, tables.free_list.items);
    defer testing.allocator.free(free_before);

    const token = try tables.beginInitAdmission();
    var last: Handle = undefined;
    for (0..12) |i| {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "provisional.{d}", .{i});
        last = try tables.create(&schema, 1, Atom.from(name), .durable);
    }
    try testing.expect(tables.capacity > 2);
    try testing.expect(tables.abortInitAdmission(token));

    try testing.expectEqual(@as(u32, 2), tables.capacity);
    try testing.expectEqual(@as(usize, 2), tables.slots.len);
    try testing.expectEqualSlices(u32, free_before, tables.free_list.items);
    try testing.expect(tables.get(kept).? == kept_table);
    try testing.expect(tables.findByName(Atom.from("provisional.0")) == null);
    try testing.expect(!tables.valid(last));

    // Regrowth reuses reserved slots without reviving the aborted handle's generation.
    for (0..12) |i| {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "again.{d}", .{i});
        _ = try tables.create(&schema, 1, Atom.from(name), .durable);
    }
    try testing.expect(tables.capacity > last.index);
    try testing.expect(!tables.valid(last));
}

test "Registry slot growth failure leaves the registry unchanged" {
    var fail_index: usize = 0;
    while (fail_index < 12) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
        var mem: memory_mod.Memory = undefined;
        mem.init(failing.allocator());
        defer mem.deinit();
        var kw: Atom.Registry = undefined;
        try kw.init(&mem);
        defer kw.deinit();
        var schema: Table.Schema = undefined;
        try schema.init(testing.allocator, &kw, 1);
        defer schema.deinit();
        schema.addField("value", i32, .int);
        var tables: Registry = undefined;
        try tables.init(&mem, 1);
        defer tables.deinit();
        const kept = try tables.create(&schema, 1, Atom.from("kept"), .durable);
        const capacity = tables.capacity;
        const reserved = tables.reserved_slots;
        const free_count = tables.free_list.items.len;
        failing.fail_index = failing.alloc_index + fail_index;
        const created = tables.create(&schema, 1, Atom.from("second"), .durable);
        failing.fail_index = std.math.maxInt(usize);
        if (created) |handle| {
            try testing.expect(tables.valid(handle));
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expect(tables.findByName(Atom.from("second")) == null);
            // Slots may have grown before a later failure, but only as free slots.
            if (tables.capacity == capacity) {
                try testing.expectEqual(reserved, tables.reserved_slots);
                try testing.expectEqual(free_count, tables.free_list.items.len);
            } else {
                try testing.expectEqual(tables.capacity - capacity, @as(u32, @intCast(tables.free_list.items.len)));
            }
            try testing.expectEqual(@as(usize, tables.capacity), tables.slots.len);
        }
        try testing.expect(tables.valid(kept));
    }
}

test "Registry scoped placement charges one scope and returns its pages" {
    var kw: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try kw.init(&mem);
    defer kw.deinit();
    var schema: Table.Schema = undefined;
    try schema.init(testing.allocator, &kw, 1);
    defer schema.deinit();
    schema.addField("value", i32, .int);
    var tables: Registry = undefined;
    try tables.init(&mem, 4);
    defer tables.deinit();
    const scope_a = try mem.openScope(Atom.from("a"));
    const scope_b = try mem.openScope(Atom.from("b"));

    const unscoped_before = tables.storageStats();
    const columnar = try tables.createScoped(scope_a, &schema, 8, Atom.from("rows"), .durable);
    const singleton = try tables.createSingletonScoped(scope_a, &schema, Atom.from("single"), .durable);
    const row = tables.get(columnar).?.insert(.{ .value = @as(i32, 7) });
    _ = try tables.get(singleton).?.alloc();
    try testing.expect(mem.scopeFor(scope_a).?.stats().backing.current_bytes > 0);
    try testing.expectEqual(@as(u64, 0), mem.scopeFor(scope_b).?.stats().backing.current_bytes);
    // Scoped pages are charged once, to the scope.
    try testing.expectEqualDeep(unscoped_before, tables.storageStats());

    try tables.grow(columnar, 4096);
    try testing.expectEqual(@as(i32, 7), tables.get(columnar).?.getField(i32, row, "value").?.*);

    // Outstanding table pages hold the scope open until its tables are destroyed.
    try mem.beginCloseScope(scope_a);
    try testing.expectError(error.ScopeClosing, tables.createScoped(scope_a, &schema, 1, Atom.from("rejected"), .durable));
    try testing.expectError(error.ScopeBackingOutstanding, mem.releaseScope(scope_a));
    tables.destroyScopeTables(scope_a);
    try testing.expect(!tables.valid(columnar) and !tables.valid(singleton));
    try mem.releaseScope(scope_a);
    try testing.expectError(error.StaleScope, tables.createScoped(scope_a, &schema, 1, Atom.from("stale"), .durable));
}

test "Registry report and admission growth cover grown slots" {
    var kw: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try kw.init(&mem);
    defer kw.deinit();
    var schema: Table.Schema = undefined;
    try schema.init(testing.allocator, &kw, 1);
    defer schema.deinit();
    schema.addField("value", i32, .int);
    var tables: Registry = undefined;
    try tables.init(&mem, 2);
    defer tables.deinit();
    try tables.syncMemoryTable(&kw);
    for (0..40) |i| {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "report.{d}", .{i});
        _ = try tables.create(&schema, 1, Atom.from(name), .durable);
    }
    try tables.syncMemoryTable(&kw);
    try testing.expectEqual(tables.activeCount(), tables.findByName(kw.intern("table_memory")).?.count());

    // A provisional table in a slot beyond the admission snapshot may still grow.
    var filler_index: usize = 0;
    while (tables.free_list.items.len > 0) : (filler_index += 1) {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "filler.{d}", .{filler_index});
        _ = try tables.create(&schema, 1, Atom.from(name), .durable);
    }
    const token = try tables.beginInitAdmission();
    const provisional = try tables.create(&schema, 1, Atom.from("provisional"), .durable);
    try tables.grow(provisional, 64);
    try testing.expect(tables.get(provisional).?.rowCapacity() >= 64);
    try testing.expect(tables.abortInitAdmission(token));
}

test "Registry aborted scoped singleton replacement returns its payload" {
    var kw: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try kw.init(&mem);
    defer kw.deinit();
    var schema: Table.Schema = undefined;
    try schema.init(testing.allocator, &kw, 1);
    defer schema.deinit();
    schema.addField("value", i32, .int);
    var tables: Registry = undefined;
    try tables.init(&mem, 4);
    defer tables.deinit();
    const scope_id = try mem.openScope(Atom.from("a"));
    const single = try tables.createSingletonScoped(scope_id, &schema, Atom.from("single"), .durable);
    const staged = try tables.create(&schema, 1, Atom.from("staged"), .durable);
    _ = tables.get(staged).?.insert(.{ .value = @as(i32, 3) });
    const held = mem.scopeFor(scope_id).?.stats().backing.current_bytes;
    const prepared = try tables.prepareReplacement(single, staged);
    tables.abortReplacement(prepared);
    try testing.expectEqual(held, mem.scopeFor(scope_id).?.stats().backing.current_bytes);
}

test "Registry growth is refused once the scope is closing" {
    var kw: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try kw.init(&mem);
    defer kw.deinit();
    var schema: Table.Schema = undefined;
    try schema.init(testing.allocator, &kw, 1);
    defer schema.deinit();
    schema.addField("value", i32, .int);
    var tables: Registry = undefined;
    try tables.init(&mem, 4);
    defer tables.deinit();
    const scope_id = try mem.openScope(Atom.from("a"));
    const rows_handle = try tables.createScoped(scope_id, &schema, 1, Atom.from("rows"), .durable);
    try mem.beginCloseScope(scope_id);
    try testing.expectError(error.ScopeClosing, tables.grow(rows_handle, 4096));
    tables.destroyScopeTables(scope_id);
    try mem.releaseScope(scope_id);
}

test "Registry staged rebuild lands in the requested scope" {
    var kw: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try kw.init(&mem);
    defer kw.deinit();
    var tables: Registry = undefined;
    try tables.init(&mem, 4);
    defer tables.deinit();
    const scope_id = try mem.openScope(Atom.from("a"));
    var schema: Table.Schema = undefined;
    try schema.init(testing.allocator, &kw, 1);
    defer schema.deinit();
    schema.addField("value", i32, .int);
    try tables.registerSchema(kw.intern("doc"), &schema);
    const staged = try stageRebuildNamedIn(&tables, &kw, "doc", kw.intern("doc"), 2, .persistent, scope_id);
    try testing.expectEqual(scope_id, tables.get(staged).?.memory_scope.?);
    try testing.expect(mem.scopeFor(scope_id).?.stats().backing.current_bytes > 0);
    tables.destroy(staged);
    try testing.expectEqual(@as(u64, 0), mem.scopeFor(scope_id).?.stats().backing.current_bytes);
}

test "Registry replacement keeps pages inside the destination scope" {
    var kw: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try kw.init(&mem);
    defer kw.deinit();
    var schema: Table.Schema = undefined;
    try schema.init(testing.allocator, &kw, 1);
    defer schema.deinit();
    schema.addField("value", i32, .int);
    var tables: Registry = undefined;
    try tables.init(&mem, 8);
    defer tables.deinit();
    const scope_a = try mem.openScope(Atom.from("a"));
    const scope_b = try mem.openScope(Atom.from("b"));
    const a = mem.scopeFor(scope_a).?;
    const b = mem.scopeFor(scope_b).?;

    // Same scope transfers the staged pages: the old pages return, nothing is copied.
    const target = try tables.createScoped(scope_a, &schema, 4, Atom.from("target"), .durable);
    const same = try tables.createScoped(scope_a, &schema, 4, Atom.from("same"), .durable);
    _ = tables.get(same).?.insert(.{ .value = @as(i32, 1) });
    const before_same = tables.get(same).?.storage.columnar.arena.first;
    const prepared_same = try tables.prepareReplacement(target, same);
    try testing.expect(prepared_same.transfer);
    tables.commitReplacement(prepared_same);
    try testing.expect(tables.get(target).?.storage.columnar.arena.first == before_same);
    try testing.expectEqual(@as(usize, 1), tables.get(target).?.count());

    // Another scope's staged pages stay with it until staging is destroyed.
    const foreign = try tables.createScoped(scope_b, &schema, 4, Atom.from("foreign"), .durable);
    _ = tables.get(foreign).?.insert(.{ .value = @as(i32, 2) });
    const prepared_foreign = try tables.prepareReplacement(target, foreign);
    try testing.expect(!prepared_foreign.transfer);
    tables.abortReplacement(prepared_foreign);
    try testing.expect(tables.valid(foreign));
    try tables.replaceContentsFallible(target, foreign);
    try testing.expect(tables.get(target).?.memory_scope.?.generation == scope_a.generation);
    try testing.expect(a.stats().backing.current_bytes > 0);
    try testing.expectEqual(@as(u64, 0), b.stats().backing.current_bytes);

    // A scoped singleton replaced through staging frees its old payload.
    const single = try tables.createSingletonScoped(scope_b, &schema, Atom.from("single"), .durable);
    _ = try tables.get(single).?.alloc();
    const held = b.stats().backing.current_bytes;
    const staged_single = try tables.createScoped(scope_a, &schema, 1, Atom.from("staged"), .durable);
    _ = tables.get(staged_single).?.insert(.{ .value = @as(i32, 3) });
    try tables.replaceContentsFallible(single, staged_single);
    try testing.expectEqual(held, b.stats().backing.current_bytes);
    tables.destroy(single);
    tables.destroy(target);
    try testing.expectEqual(@as(u64, 0), a.stats().backing.current_bytes);
    try testing.expectEqual(@as(u64, 0), b.stats().backing.current_bytes);
}

test "Registry stale and fabricated free-slot handles are rejected after destroy" {
    const schema = testSchema();
    var tables: Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try tables.init(&mem, 4);
    defer tables.deinit();

    const handle = try tables.create(&schema, 4, Atom.from("test"), .durable);
    try testing.expect(tables.get(handle) != null);

    tables.destroy(handle);
    const fabricated = Handle{ .index = handle.index, .generation = tables.generation[handle.index] };
    try testing.expect(!tables.valid(handle));
    try testing.expect(!tables.valid(fabricated));
    try testing.expectEqual(@as(?*Table, null), tables.get(handle));
    try testing.expectEqual(@as(?*Table, null), tables.get(fabricated));
}

test "destroying the last lifetime borrower releases backing" {
    const schema = testSchema();
    var tables: Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try tables.init(&mem, 4);
    defer tables.deinit();

    const h1 = try tables.create(&schema, 4096, Atom.from("big"), .durable);
    const grown = tables.tableBytesReserved();
    try testing.expect(grown > 4096 * testSchema().fields.len * 4);

    tables.destroy(h1);
    try testing.expectEqual(@as(usize, 0), tables.tableBytesReserved());

    const h2 = try tables.create(&schema, 4096, Atom.from("again"), .durable);
    try testing.expectEqual(grown, tables.tableBytesReserved());
    tables.destroy(h2);
    try testing.expectEqual(@as(usize, 0), tables.tableBytesReserved());
}

test "Registry owns independent schema and field-name copies" {
    var kw: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try kw.init(&mem);
    defer kw.deinit();

    var schema: Table.Schema = undefined;
    try schema.init(testing.allocator, &kw, 1);
    schema.addField("durable_name", u32, .int);

    var table_registry: Registry = undefined;
    var table_memory: memory_mod.Memory = undefined;
    table_memory.init(testing.allocator);
    defer table_memory.deinit();
    try table_registry.init(&table_memory, 1);
    defer table_registry.deinit();
    const table_handle = try table_registry.create(&schema, 1, kw.intern("owned"), .durable);
    const table = table_registry.get(table_handle).?;
    schema.deinit();

    try testing.expectEqualStrings("durable_name", table.getSchema().fields[0].name);
    const row = table.insert(.{ .durable_name = @as(u32, 7) });
    try testing.expectEqual(@as(u32, 7), table.getField(u32, row, "durable_name").?.*);
}

test "schema hash includes view metadata" {
    var kw: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try kw.init(&mem);
    defer kw.deinit();
    var a: Table.Schema = undefined;
    try a.init(testing.allocator, &kw, 1);
    defer a.deinit();
    a.addField("value", f32, .{ .float_slider = .{ .min = 0, .max = 1 } });
    var b: Table.Schema = undefined;
    try b.init(testing.allocator, &kw, 1);
    defer b.deinit();
    b.addField("value", f32, .{ .float_slider = .{ .min = 0, .max = 2 } });
    try testing.expect(schemaHash(&a) != schemaHash(&b));
}

test "Registry ensure preserves compatible data and rejects mismatch" {
    var kw: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try kw.init(&mem);
    defer kw.deinit();
    var tables: Registry = undefined;
    try tables.init(&mem, 2);
    defer tables.deinit();

    var schema: Table.Schema = undefined;
    try schema.init(testing.allocator, &kw, 1);
    defer schema.deinit();
    schema.addField("value", u32, .int);

    const first = try tables.ensure(&schema, 1, kw.intern("singleton"), .durable);
    try testing.expect(first.created);
    _ = first.table.insert(.{ .value = @as(u32, 41) });
    const second = try tables.ensure(&schema, 1, kw.intern("singleton"), .durable);
    try testing.expect(!second.created);
    try testing.expectError(error.LifetimeMismatch, tables.ensure(&schema, 1, kw.intern("singleton"), .persistent));
    const handle = Table.RowHandle{ .row = 0, .generation = second.table.rowGeneration(@intCast(0)) };
    try testing.expectEqual(@as(u32, 41), second.table.getField(u32, handle, "value").?.*);

    var mismatch: Table.Schema = undefined;
    try mismatch.init(testing.allocator, &kw, 1);
    defer mismatch.deinit();
    mismatch.addField("other", u32, .int);
    try testing.expectError(error.SchemaMismatch, tables.ensure(&mismatch, 1, kw.intern("singleton"), .durable));
    try testing.expectError(error.DuplicateTableName, tables.create(&schema, 1, kw.intern("singleton"), .durable));
}

test "freed rows remain invalid even with their current generation" {
    var kw: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try kw.init(&mem);
    defer kw.deinit();
    var schema: Table.Schema = undefined;
    try schema.init(testing.allocator, &kw, 1);
    defer schema.deinit();
    schema.addField("value", u32, .int);
    var table_registry: Registry = undefined;
    var table_memory: memory_mod.Memory = undefined;
    table_memory.init(testing.allocator);
    defer table_memory.deinit();
    try table_registry.init(&table_memory, 1);
    defer table_registry.deinit();
    const table_handle = try table_registry.create(&schema, 1, kw.intern("rows"), .durable);
    const table = table_registry.get(table_handle).?;

    const handle = table.insert(.{ .value = @as(u32, 7) });
    table.free(handle);
    const fabricated = Table.RowHandle{ .row = handle.row, .generation = table.rowGeneration(@intCast(handle.row)) };
    try testing.expect(!table.valid(handle));
    try testing.expect(!table.valid(fabricated));
    try testing.expect(table.getField(u32, fabricated, "value") == null);
}

test "explicit singleton storage is scalar and arena backed while capacity one tables remain columnar" {
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    var registry: Registry = undefined;
    try registry.init(&mem, 4);
    defer registry.deinit();
    const schema = testSchema();
    const ordinary_id = try registry.create(&schema, 1, Atom.from("ordinary_one"), .durable);
    const ordinary = registry.get(ordinary_id).?;
    try testing.expect(!ordinary.isSingleton());
    _ = try ordinary.alloc();
    try testing.expectError(error.SchemaMismatch, registry.ensureSingleton(&schema, ordinary.name, .{ .health = @as(f32, 0) }, .durable));
    try registry.grow(ordinary_id, 2);
    try testing.expect(ordinary.rowCapacity() >= 2);

    const singleton_id = try registry.createSingleton(&schema, Atom.from("scalar_one"), .durable);
    const singleton = registry.get(singleton_id).?;
    try testing.expect(singleton.isSingleton());
    try singleton.reusableRows().expectEqual(&.{0});
    const row = try singleton.alloc();
    @memset(singleton.rowFieldBytes(0, 0), 0x42);
    singleton.setMask(0, Mask.fromBit(0));
    try testing.expectEqual(@as(usize, 0), singleton.reusableRows().len);
    try testing.expectError(error.TableFull, singleton.alloc());
    try testing.expectError(error.SchemaMismatch, registry.grow(singleton_id, 2));
    try registry.grow(singleton_id, 1);
    try testing.expectEqual(@as(usize, 1), singleton.generationCount());
    var row_query = singleton.query(struct { position: *Vec2f });
    try testing.expectEqualDeep(row, row_query.next().?.handle);
    try testing.expect(row_query.next() == null);

    // Copies contain independent scalar state, never pointers back into Table.
    var copied = singleton.*;
    copied.free(row);
    try testing.expect(!copied.valid(row));
    try testing.expect(singleton.valid(row));
    try testing.expectEqual(@as(u64, 1), singleton.rowMask(0).words[0]);
    const retained_bytes = singleton.rowFieldBytes(0, 0);
    const arena_capacity = registry.singleton_arena.reserved();
    try testing.expect(arena_capacity > 0);
    registry.destroy(singleton_id);
    try testing.expectEqual(arena_capacity, registry.singleton_arena.reserved());
    try testing.expectEqual(@as(u8, 0x42), retained_bytes[0]);
}

test "singleton replacement prepares independent arena storage and never adopts a columnar arm" {
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    var registry: Registry = undefined;
    try registry.init(&mem, 4);
    defer registry.deinit();
    const schema = testSchema();
    const target = try registry.ensureSingleton(&schema, Atom.from("singleton_target"), .{ .health = @as(f32, 9) }, .durable);
    const old_row = Table.RowHandle{ .row = 0, .generation = target.table.rowGeneration(0) };
    const staged = try registry.create(&schema, 1, Atom.from("singleton_stage"), .durable);
    const source = registry.get(staged).?;
    const staged_row = source.insert(.{ .health = @as(f32, 73) });
    const source_bytes = source.rowFieldBytes(0, 2).ptr;
    const aborted = try registry.prepareReplacement(target.handle, staged);
    try testing.expect(aborted.bundle.table.isSingleton());
    try testing.expect(aborted.bundle.table.rowFieldBytes(0, 2).ptr != source_bytes);
    registry.abortReplacement(aborted);
    try testing.expect(target.table.valid(old_row));
    try testing.expect(source.valid(staged_row));
    try testing.expectEqual(@as(f32, 9), target.table.getField(f32, old_row, "health").?.*);
    const prepared = try registry.prepareReplacement(target.handle, staged);
    registry.commitReplacement(prepared);
    try testing.expect(target.table.isSingleton());
    try testing.expect(target.table.required_singleton);
    try testing.expect(!target.table.valid(old_row));
    try testing.expect(!registry.valid(staged));
    const current = Table.RowHandle{ .row = 0, .generation = target.table.rowGeneration(0) };
    try testing.expectEqual(@as(f32, 73), target.table.getField(f32, current, "health").?.*);
    target.table.free(current);
    target.table.clear();
    try testing.expect(target.table.valid(current));

    // The destination's explicit representation also wins in the opposite direction.
    const ordinary_id = try registry.create(&schema, 1, Atom.from("columnar_target"), .durable);
    const singleton_stage = try registry.createSingleton(&schema, Atom.from("scalar_stage"), .durable);
    _ = registry.get(singleton_stage).?.insert(.{ .health = @as(f32, 81) });
    try registry.replaceContentsFallible(ordinary_id, singleton_stage);
    const ordinary = registry.get(ordinary_id).?;
    try testing.expect(!ordinary.isSingleton());
    try testing.expect(registry.get(ordinary_id).?.storage.columnar.arena.bytes > 0);
    const ordinary_row = Table.RowHandle{ .row = 0, .generation = ordinary.rowGeneration(0) };
    try testing.expectEqual(@as(f32, 81), ordinary.getField(f32, ordinary_row, "health").?.*);
}

test "required singleton cannot be freed or cleared" {
    var kw: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try kw.init(&mem);
    defer kw.deinit();
    var tables: Registry = undefined;
    try tables.init(&mem, 2);
    defer tables.deinit();
    var schema: Table.Schema = undefined;
    try schema.init(testing.allocator, &kw, 1);
    defer schema.deinit();
    schema.addField("value", u32, .int);

    const singleton = try tables.ensureSingleton(&schema, kw.intern("root"), .{ .value = @as(u32, 9) }, .durable);
    const row = Table.RowHandle{ .row = 0, .generation = singleton.table.rowGeneration(@intCast(0)) };
    singleton.table.free(row);
    singleton.table.clear();
    try testing.expect(singleton.table.valid(row));
    try testing.expectEqual(@as(u32, 1), singleton.table.count());
    try testing.expectEqual(@as(u32, 9), singleton.table.getField(u32, row, "value").?.*);
    const rebound = try tables.ensureSingleton(&schema, kw.intern("root"), .{ .value = @as(u32, 0) }, .durable);
    try testing.expect(!rebound.created);
}

test "Registry ensure rejects equal-width semantic type changes" {
    var kw: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try kw.init(&mem);
    defer kw.deinit();
    var tables: Registry = undefined;
    try tables.init(&mem, 2);
    defer tables.deinit();
    var unsigned: Table.Schema = undefined;
    try unsigned.init(testing.allocator, &kw, 1);
    defer unsigned.deinit();
    unsigned.addField("value", u32, .int);
    _ = try tables.ensure(&unsigned, 1, kw.intern("typed"), .durable);

    var signed: Table.Schema = undefined;
    try signed.init(testing.allocator, &kw, 1);
    defer signed.deinit();
    signed.addField("value", i32, .int);
    try testing.expectEqual(unsigned.fields[0].size, signed.fields[0].size);
    try testing.expect(unsigned.fields[0].semantic_type != signed.fields[0].semantic_type);
    try testing.expectError(error.SchemaMismatch, tables.ensure(&signed, 1, kw.intern("typed"), .durable));
}

test "Registry slot addresses are stable across unrelated create/destroy" {
    const schema = testSchema();
    var tables: Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try tables.init(&mem, 4);
    defer tables.deinit();

    const kept = try tables.create(&schema, 4, Atom.from("kept"), .durable);
    const kept_ptr = tables.get(kept).?;

    const other1 = try tables.create(&schema, 4, Atom.from("o1"), .durable);
    const other2 = try tables.create(&schema, 4, Atom.from("o2"), .durable);
    tables.destroy(other1);
    _ = try tables.create(&schema, 4, Atom.from("o3"), .durable);
    tables.destroy(other2);

    try testing.expectEqual(kept_ptr, tables.get(kept).?);
}

test "Registry.replaceContents commits a staged rebuild in place and invalidates row handles" {
    var kw: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try kw.init(&mem);
    defer kw.deinit();
    var tables: Registry = undefined;
    try tables.init(&mem, 4);
    defer tables.deinit();

    var old_schema: Table.Schema = undefined;
    try old_schema.init(testing.allocator, &kw, 2);
    defer old_schema.deinit();
    old_schema.addField("keep", i32, .int);
    old_schema.addField("drop", i32, .int);

    tables.scope = .app;
    const target = try tables.create(&old_schema, 4, kw.intern("rebuilt"), .persistent);
    const table = tables.get(target).?;
    const table_ptr = table;
    _ = table.insert(.{ .keep = @as(i32, 11), .drop = @as(i32, 99) });
    _ = table.insert(.{ .keep = @as(i32, 22) });
    const stale_handle: Table.RowHandle = .{ .row = 0, .generation = table.rowGeneration(@intCast(0)) };

    var new_schema: Table.Schema = undefined;
    try new_schema.init(testing.allocator, &kw, 1);
    defer new_schema.deinit();
    new_schema.addField("keep", i32, .int);
    tables.scope = .editor;
    const staged = try tables.create(&new_schema, 2, kw.intern(".staging.rebuilt"), .transient);
    const staged_table = tables.get(staged).?;
    var migrated: usize = 0;
    for (0..table.rowCapacity()) |r| {
        if (!table.isAllocated(@intCast(r))) continue;
        const dst = staged_table.alloc() catch return error.OutOfMemory;
        staged_table.writeFieldRawByIndex(dst, 0, std.mem.asBytes(table.getField(i32, .{ .row = @intCast(r), .generation = table.rowGeneration(@intCast(r)) }, "keep").?));
        migrated += 1;
    }
    try testing.expectEqual(@as(usize, 2), migrated);

    try tables.replaceContentsFallible(target, staged);

    try testing.expectEqual(table_ptr, tables.get(target).?);
    try testing.expectEqual(Table.Owner.app, table.owner);
    try testing.expectEqual(Table.Lifetime.persistent, table.lifetime);
    try testing.expectEqualStrings("rebuilt", kw.lookup(table.name).?);
    try testing.expect(table.rowCapacity() >= 2);
    try testing.expectEqual(@as(u32, 2), table.count());
    const new_row: Table.RowHandle = .{ .row = 0, .generation = table.rowGeneration(@intCast(0)) };
    try testing.expectEqual(@as(i32, 11), table.getField(i32, new_row, "keep").?.*);
    try testing.expectEqual(@as(i32, 22), table.getField(i32, .{ .row = 1, .generation = table.rowGeneration(@intCast(1)) }, "keep").?.*);

    try testing.expect(!table.valid(stale_handle));

    try testing.expect(tables.findHandleByName(kw.intern(".staging.rebuilt")) == null);

    // Reuse the actual staging slot; destination storage must retain registry
    // provenance and never overlap this unrelated lifetime's bundle.
    const unrelated = try tables.create(&new_schema, 2, kw.intern("unrelated"), .transient);
    const unrelated_table = tables.get(unrelated).?;
    try testing.expectEqual(staged.index, unrelated.index);
    try testing.expectEqual(staged_table, unrelated_table);
    try testing.expect(unrelated.generation != staged.generation);
    try testing.expect(table.storage.columnar.columns[0].first != unrelated_table.storage.columnar.columns[0].first);
    const unrelated_row = unrelated_table.insert(.{ .keep = @as(i32, 33) });

    try tables.grow(target, 8);
    const grown_row = table.insert(.{ .keep = @as(i32, 44) });
    try testing.expectEqual(@as(i32, 11), table.getField(i32, new_row, "keep").?.*);
    try testing.expectEqual(@as(i32, 44), table.getField(i32, grown_row, "keep").?.*);
    try testing.expectEqual(@as(i32, 33), unrelated_table.getField(i32, unrelated_row, "keep").?.*);
    tables.destroy(unrelated);

    try testing.expectEqual(@as(i32, 11), table.getField(i32, new_row, "keep").?.*);
    try testing.expectEqual(@as(i32, 44), table.getField(i32, grown_row, "keep").?.*);
    try tables.grow(target, 16);
    const later_row = table.insert(.{ .keep = @as(i32, 55) });
    try testing.expectEqual(@as(i32, 11), table.getField(i32, new_row, "keep").?.*);
    try testing.expectEqual(@as(i32, 44), table.getField(i32, grown_row, "keep").?.*);
    try testing.expectEqual(@as(i32, 55), table.getField(i32, later_row, "keep").?.*);
    try testing.expectEqual(table_ptr, tables.get(target).?);
}

test "Registry.ensure and ensureNamed admit grown capacity without changing identity or data" {
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    var kw: Atom.Registry = undefined;
    try kw.init(&mem);
    defer kw.deinit();
    var tables: Registry = undefined;
    try tables.init(&mem, 8);
    defer tables.deinit();
    var schema: Table.Schema = undefined;
    try schema.init(testing.allocator, &kw, 1);
    defer schema.deinit();
    schema.addField("value", i32, .int);
    var other: Table.Schema = undefined;
    try other.init(testing.allocator, &kw, 1);
    defer other.deinit();
    other.addField("other", i32, .int);
    const schema_name = kw.intern("a2_schema");
    const other_name = kw.intern("a2_other");
    try tables.registerSchema(schema_name, &schema);
    try tables.registerSchema(other_name, &other);
    inline for (.{ false, true }) |named| {
        const name = kw.intern(if (named) "a2_named" else "a2_inline");
        const initial = if (named) try tables.ensureNamed(schema_name, 2, name, .durable) else try tables.ensure(&schema, 2, name, .durable);
        const row = initial.table.insert(.{ .value = @as(i32, 73) });
        try tables.grow(initial.handle, 8);
        const revision = initial.table.revision;
        for ([_]u32{ 2, 8 }) |minimum| {
            const admitted = if (named) try tables.ensureNamed(schema_name, minimum, name, .durable) else try tables.ensure(&schema, minimum, name, .durable);
            try testing.expect(!admitted.created);
            try testing.expectEqual(initial.handle, admitted.handle);
            try testing.expect(initial.table == admitted.table);
        }
        if (named) {
            try testing.expectError(error.SchemaMismatch, tables.ensureNamed(schema_name, initial.table.rowCapacity() + 1, name, .durable));
            try testing.expectError(error.SchemaMismatch, tables.ensureNamed(other_name, 2, name, .durable));
            try testing.expectError(error.LifetimeMismatch, tables.ensureNamed(schema_name, 2, name, .transient));
        } else {
            try testing.expectError(error.SchemaMismatch, tables.ensure(&schema, initial.table.rowCapacity() + 1, name, .durable));
            try testing.expectError(error.SchemaMismatch, tables.ensure(&other, 2, name, .durable));
            try testing.expectError(error.LifetimeMismatch, tables.ensure(&schema, 2, name, .transient));
        }
        try testing.expect(initial.table.rowCapacity() >= 8);
        try testing.expectEqual(revision, initial.table.revision);
        try testing.expectEqual(@as(i32, 73), initial.table.getField(i32, row, "value").?.*);
        try testing.expectEqual(initial.handle, tables.findHandleByName(name).?);
        try testing.expect(!initial.table.required_singleton);
        try testing.expectError(error.SchemaMismatch, tables.ensureSingleton(&schema, name, .{ .value = @as(i32, 0) }, .durable));
        try testing.expect(!initial.table.required_singleton);
        try testing.expectEqual(@as(i32, 73), initial.table.getField(i32, row, "value").?.*);
    }
    const singleton = try tables.ensureSingleton(&schema, kw.intern("a2_singleton"), .{ .value = @as(i32, 91) }, .durable);
    const same = try tables.ensureSingleton(&schema, kw.intern("a2_singleton"), .{ .value = @as(i32, 0) }, .durable);
    try testing.expectEqual(singleton.handle, same.handle);
    try testing.expect(singleton.table.required_singleton);
    try testing.expectEqual(@as(u32, 1), singleton.table.rowCapacity());
    try testing.expectEqual(@as(i32, 91), singleton.table.getField(i32, .{ .row = 0, .generation = singleton.table.rowGeneration(@intCast(0)) }, "value").?.*);
}

fn schemaAdmissionFailureCase(allocator: std.mem.Allocator, schema: *const Table.Schema) !void {
    var registry: Table.SchemaRegistry = .{ .global = memory_mod.SharedAllocator.wrap(&allocator) };
    defer registry.deinit();
    const name = Atom.from("schema.failure");
    registry.register(name, schema, .columnar) catch |err| {
        try testing.expectEqual(@as(u32, 0), registry.entries.count());
        try testing.expectEqual(@as(u32, 0), registry.enforced.count());
        try testing.expect(registry.get(name) == null);
        return err;
    };
    try testing.expect(schemasEqual(schema, registry.get(name).?));
    try testing.expect(registry.enforced.contains(name));
}

test "SchemaRegistry.register preadmits both maps and clone before publication at every failure" {
    const schema = testSchema();
    try testing.checkAllAllocationFailures(testing.allocator, schemaAdmissionFailureCase, .{&schema});
    // Specifically reject the second map admission, after the first reserved capacity.
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    const failing_allocator = failing.allocator();
    var registry: Table.SchemaRegistry = .{ .global = memory_mod.SharedAllocator.wrap(&failing_allocator) };
    defer registry.deinit();
    try testing.expectError(error.OutOfMemory, registry.register(Atom.from("p1"), &schema, .columnar));
    try testing.expectEqual(@as(u32, 0), registry.entries.count());
    try testing.expectEqual(@as(u32, 0), registry.enforced.count());
}

fn registryInitFailureCase(allocator: std.mem.Allocator) !void {
    var mem: memory_mod.Memory = undefined;
    mem.init(allocator);
    defer mem.deinit();
    var tables: Registry = undefined;
    try tables.init(&mem, 256);
    defer tables.deinit();
    try testing.expectEqual(@as(u32, 0), tables.activeCount());
}

test "Registry.init unwinds partial host metadata allocations" {
    try testing.checkAllAllocationFailures(testing.allocator, registryInitFailureCase, .{});
}

test "table arena representation has no Table self pointer or allocator adapter" {
    comptime {
        for (std.meta.fields(Table.Columnar)) |field| {
            if (field.type == *Table or field.type == *Registry) @compileError("movable storage cannot retain its owner address");
        }
        if (@hasField(table_storage.Arena, "allocator")) @compileError("arena must use captured backing, not an adapter");
    }
}

test "Registry create and growth OOM preserve slots rows revision tombstones free ordering and peers" {
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    const failing = &mem.page_source;
    var tables: Registry = undefined;
    try tables.init(&mem, 8);
    defer tables.deinit();
    const schema = testSchema();
    const target = try tables.create(&schema, 4, Atom.from("failure.target"), .durable);
    const peer = try tables.create(&schema, 4, Atom.from("failure.peer"), .durable);
    const table = tables.get(target).?;
    const peer_table = tables.get(peer).?;
    const row = table.insert(.{ .health = @as(f32, 42) });
    const freed = try table.alloc();
    table.free(freed);
    const peer_row = peer_table.insert(.{ .health = @as(f32, 71) });
    const old = table.*;
    const free_rows = try testing.allocator.alloc(u32, table.reusableRows().len);
    defer testing.allocator.free(free_rows);
    table.reusableRows().copyTo(free_rows);
    const before = tables.storageStats();
    failing.refuseAfter(0);
    try testing.expectError(error.OutOfMemory, tables.grow(target, 1_000_000));
    try testing.expectEqualDeep(before, tables.storageStats());
    try testing.expectEqual(old.revision, table.revision);
    try testing.expectEqual(old.rowCapacity(), table.rowCapacity());
    try testing.expectEqual(old.storage.columnar.columns.ptr, table.storage.columnar.columns.ptr);
    try table.reusableRows().expectEqual(free_rows);
    const available = tables.free_list.items.len;
    try testing.expectError(error.OutOfMemory, tables.create(&schema, 1_000_000, Atom.from("failure.new"), .transient));
    try testing.expectEqual(available, tables.free_list.items.len);
    try testing.expect(tables.getSchema(Atom.from("failure.new")) == null);
    try testing.expectEqual(@as(f32, 42), table.getField(f32, row, "health").?.*);
    try testing.expectEqual(@as(f32, 71), peer_table.getField(f32, peer_row, "health").?.*);
    failing.refuseNone();
    try tables.grow(target, 32);
    try testing.expectEqual(table, tables.get(target).?);
    try testing.expectEqual(freed.row, (try table.alloc()).row);
}

test "Registry replacement prepare failure and abort preserve both versions and metadata" {
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    const failing = &mem.page_source;
    var tables: Registry = undefined;
    try tables.init(&mem, 8);
    defer tables.deinit();
    var schema: Table.Schema = undefined;
    try schema.initWithAtoms(testing.allocator, null, 1);
    defer schema.deinit();
    schema.addField("health", f32, .text_field);
    const target = try tables.create(&schema, 4, Atom.from("replace.target"), .persistent);
    const staged = try tables.create(&schema, 10000, Atom.from("replace.stage"), .transient);
    const dst = tables.get(target).?;
    const src = tables.get(staged).?;
    const old_row = dst.insert(.{ .health = @as(f32, 21) });
    const staged_row = src.insert(.{ .health = @as(f32, 81) });
    const before = tables.storageStats();
    const revision = dst.revision;
    failing.refuseAfter(0);
    try testing.expectError(error.OutOfMemory, tables.prepareReplacement(target, staged));
    const after_failure = tables.storageStats();
    try testing.expectEqualDeep(before, after_failure);
    try testing.expectEqual(revision, dst.revision);
    try testing.expectEqual(@as(f32, 21), dst.getField(f32, old_row, "health").?.*);
    try testing.expectEqual(@as(f32, 81), src.getField(f32, staged_row, "health").?.*);
    failing.refuseNone();
    const aborted = try tables.prepareReplacement(target, staged);
    tables.abortReplacement(aborted);
    try testing.expectEqual(@as(usize, 0), tables.preparations);
    try testing.expect(dst.valid(old_row));
    try testing.expect(src.valid(staged_row));
    const prepared = try tables.prepareReplacement(target, staged);
    // Commit, table retirement and schema retirement must never call the backend.
    failing.refuseAfter(0);
    const attempts = failing.allocations.load(.monotonic);
    tables.commitReplacement(prepared);
    try testing.expectEqual(attempts, failing.allocations.load(.monotonic));
    try testing.expectEqual(dst, tables.get(target).?);
    try testing.expect(!dst.valid(old_row));
    try testing.expect(!tables.valid(staged));
    try testing.expectEqual(@as(usize, 0), tables.storageStats().transient.reserved_bytes);
    const new_row: Table.RowHandle = .{ .row = 0, .generation = dst.rowGeneration(@intCast(0)) };
    try testing.expectEqual(@as(f32, 81), dst.getField(f32, new_row, "health").?.*);
}

test "Registry same lifetime transfer retires schemas only after last peer and keeps tombstone highwater" {
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    var tables: Registry = undefined;
    try tables.init(&mem, 8);
    defer tables.deinit();
    const schema = testSchema();
    const target = try tables.create(&schema, 8, Atom.from("transfer.target"), .durable);
    const dst = tables.get(target).?;
    var row_handles: [8]Table.RowHandle = undefined;
    for (&row_handles) |*row| row.* = try dst.alloc();
    const stale = row_handles[7];
    for (row_handles) |row| dst.free(row);
    const original_schema = dst.schema_ref;
    const peer = try tables.createNamed(dst.schema_name, 1, Atom.from("transfer.peer"), .durable);
    const staged = try tables.create(&schema, 8, Atom.from("transfer.stage"), .durable);
    const source_bytes = tables.get(staged).?.storage.columnar.arena.first;
    const source = tables.get(staged).?;
    _ = source.insert(.{ .health = @as(f32, 93) });
    const before = tables.storageStats().durable.reserved_bytes;
    const prepared = try tables.prepareReplacement(target, staged);
    try testing.expect(prepared.transfer);
    tables.commitReplacement(prepared);
    try testing.expect(tables.storageStats().durable.reserved_bytes < before);
    try testing.expectEqual(source_bytes, dst.storage.columnar.arena.first);
    try testing.expect(tables.get(peer).?.schema_ref == original_schema);
    try testing.expect(dst.schema_ref != original_schema);
    tables.destroy(peer);
    try tables.grow(target, 4);
    try tables.grow(target, 8);
    while (dst.count() < dst.rowCapacity()) _ = try dst.alloc();
    try testing.expect(!dst.valid(stale));
    const old = Table.RowHandle{ .row = 0, .generation = dst.rowGeneration(@intCast(0)) };
    const second = try tables.create(&schema, 1, Atom.from("transfer.second"), .durable);
    _ = try tables.get(second).?.alloc();
    try tables.replaceContentsFallible(target, second);
    try testing.expect(!dst.valid(old));
    try testing.expect(dst.generationCount() >= 8);
}

test "Registry schema admission and replacement clone OOM leave accepted metadata and rows unchanged" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var mem: memory_mod.Memory = undefined;
    mem.init(failing.allocator());
    defer mem.deinit();
    var tables: Registry = undefined;
    try tables.init(&mem, 8);
    defer tables.deinit();
    var schema: Table.Schema = undefined;
    try schema.initWithAtoms(testing.allocator, null, 1);
    defer schema.deinit();
    schema.addField("health", f32, .text_field);
    var replacement: Table.Schema = undefined;
    try replacement.initWithAtoms(testing.allocator, null, 1);
    defer replacement.deinit();
    const long_name = try testing.allocator.alloc(u8, std.heap.pageSize() * 16);
    defer testing.allocator.free(long_name);
    @memset(long_name, 'x');
    try replacement.addFieldTypeFallible(long_name, .f32, 4, .text_field);
    const name = Atom.from("schema.old");
    const target = try tables.create(&schema, 4, name, .durable);
    const staged = try tables.create(&replacement, 4, Atom.from("schema.stage"), .durable);
    const dst = tables.get(target).?;
    const src = tables.get(staged).?;
    const row = dst.insert(.{ .health = @as(f32, 37) });
    const staged_row = try src.alloc();
    src.writeFieldRawByIndex(staged_row, 0, std.mem.asBytes(&@as(f32, 52)));
    const revision = dst.revision;
    const old_schema = dst.schema_ref;
    const entries = tables.schemas.entries.count();
    const enforced = tables.schemas.enforced.count();
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, tables.registerSchema(Atom.from("schema.new"), &replacement));
    try testing.expectEqual(entries, tables.schemas.entries.count());
    try testing.expectEqual(enforced, tables.schemas.enforced.count());
    try testing.expectError(error.OutOfMemory, tables.prepareReplacement(target, staged));
    try testing.expectEqual(entries, tables.schemas.entries.count());
    try testing.expectEqual(old_schema, dst.schema_ref);
    try testing.expectEqual(revision, dst.revision);
    try testing.expectEqualStrings("health", tables.getSchema(name).?.fields[0].name);
    try testing.expectEqual(@as(f32, 37), dst.getField(f32, row, "health").?.*);
    try testing.expectEqual(@as(f32, 52), src.getFieldByIndex(f32, staged_row, 0).?.*);
    try testing.expectEqual(@as(usize, 0), tables.preparations);
    failing.fail_index = std.math.maxInt(usize);
    const prepared = try tables.prepareReplacement(target, staged);
    failing.fail_index = failing.alloc_index;
    tables.commitReplacement(prepared);
    try testing.expectEqualStrings(long_name, tables.getSchema(name).?.fields[0].name);
    try testing.expect(!dst.valid(row));
    try testing.expectEqual(@as(f32, 52), dst.getFieldByIndex(f32, .{ .row = 0, .generation = dst.rowGeneration(@intCast(0)) }, 0).?.*);
}

test "Table row operations within reserved capacity and unknown field lookup allocate nothing" {
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    var kw: Atom.Registry = undefined;
    try kw.init(&mem);
    defer kw.deinit();
    var schema: Table.Schema = undefined;
    try schema.init(testing.allocator, &kw, 1);
    defer schema.deinit();
    schema.addField("health", f32, .text_field);
    var tables: Registry = undefined;
    try tables.init(&mem, 2);
    defer tables.deinit();
    const handle = try tables.create(&schema, 1, kw.intern("row.operations"), .durable);
    const table = tables.get(handle).?;
    const before = tables.storageStats();
    const atom_storage = kw.storage();
    const names = kw.name_count;
    const row = try table.alloc();
    _ = try table.alloc();
    try testing.expect(table.getField(f32, row, "never.interned") == null);
    try testing.expectError(error.UnknownField, table.writeFieldSingle(f32, row, "also.never.interned", 1));
    try table.writeFieldSingle(f32, row, "health", 42);
    table.free(row);
    table.clear();
    try testing.expectEqualDeep(before, tables.storageStats());
    try testing.expectEqual(atom_storage, kw.storage());
    try testing.expectEqual(names, kw.name_count);
    try testing.expect(table.rowCapacity() >= 1);
}

test "Registry inline schema versions preserve named borrowers across recreation" {
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    var tables: Registry = undefined;
    try tables.init(&mem, 4);
    defer tables.deinit();
    const schema = testSchema();
    const name = Atom.from("inline.versions");
    const first = try tables.create(&schema, 1, name, .durable);
    const borrower = try tables.createNamed(name, 1, Atom.from("inline.borrower"), .durable);
    const old = tables.get(borrower).?.schema_ref;
    const row = tables.get(borrower).?.insert(.{ .health = @as(f32, 26) });
    tables.destroy(first);
    var changed: Table.Schema = undefined;
    try changed.initWithAtoms(testing.allocator, null, 1);
    defer changed.deinit();
    changed.addField("new", u32, .int);
    const recreated = try tables.create(&changed, 1, name, .durable);
    try testing.expect(tables.get(recreated).?.schema_ref != old);
    try testing.expectEqualStrings("new", tables.getSchema(name).?.fields[0].name);
    try testing.expectEqual(@as(f32, 26), tables.get(borrower).?.getField(f32, row, "health").?.*);
    tables.destroy(recreated);
    try testing.expect(tables.getSchema(name) == null);
    try testing.expectEqual(@as(usize, 1), old.refs);
    tables.destroy(borrower);
    try testing.expectEqual(@as(usize, 0), tables.tableBytesReserved());
}

test "Registry init admission restores orphan bindings slots and reused slots exactly" {
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    var tables: Registry = undefined;
    try tables.init(&mem, 4);
    defer tables.deinit();
    var old: Table.Schema = undefined;
    try old.initWithAtoms(testing.allocator, null, 1);
    defer old.deinit();
    old.addField("value", i32, .text_field);
    var new: Table.Schema = undefined;
    try new.initWithAtoms(testing.allocator, null, 1);
    defer new.deinit();
    new.addField("other", f32, .text_field);
    const name = Atom.from("admission.orphan");
    // Model an orphan published record, as produced by schema registry preparation.
    const orphan = try tables.schemas.clone(name, &old);
    try tables.schemas.entries.put(tables.globalAllocator(), name, orphan);
    const peer = try tables.create(&old, 2, Atom.from("admission.peer"), .durable);
    const ptr = tables.get(peer).?;
    const row = ptr.insert(.{ .value = @as(i32, 71) });
    const gens = try testing.allocator.dupe(u32, tables.generation);
    defer testing.allocator.free(gens);
    const free_copy = try testing.allocator.dupe(u32, tables.free_list.items);
    defer testing.allocator.free(free_copy);
    const token = try tables.beginInitAdmission();
    try testing.expectError(error.AdmissionAlreadyActive, tables.beginInitAdmission());
    const first = try tables.create(&new, 3, name, .transient);
    tables.destroy(first);
    const second = try tables.create(&new, 3, name, .transient);
    try testing.expectEqual(first.index, second.index);
    try testing.expect(tables.abortInitAdmission(token));
    try testing.expectEqualSlices(u32, gens, tables.generation);
    try testing.expectEqualSlices(u32, free_copy, tables.free_list.items);
    try testing.expectEqual(orphan, tables.schemas.entries.get(name).?);
    try testing.expectEqual(@as(usize, 0), orphan.refs);
    try testing.expectEqual(ptr, tables.get(peer).?);
    try testing.expectEqual(@as(i32, 71), ptr.getField(i32, row, "value").?.*);
    try testing.expect(!tables.abortInitAdmission(token));
    const retry = try tables.beginInitAdmission();
    try testing.expectError(error.InvalidAdmissionToken, tables.validateInitAdmission(token));
    try tables.validateInitAdmission(retry);
    const accepted = try tables.create(&new, 1, name, .transient);
    try testing.expect(!tables.commitInitAdmission(retry));
    try tables.validateInitAdmission(retry);
    try testing.expect(tables.commitInitAdmission(retry));
    try testing.expect(!tables.commitInitAdmission(retry));
    try testing.expect(tables.valid(accepted));
}

test "Registry init admission protects existing storage singleton and schema APIs" {
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    var tables: Registry = undefined;
    try tables.init(&mem, 4);
    defer tables.deinit();
    var schema: Table.Schema = undefined;
    try schema.initWithAtoms(testing.allocator, null, 1);
    defer schema.deinit();
    schema.addField("value", i32, .text_field);
    const name = Atom.from("admission.old");
    const h = try tables.create(&schema, 1, name, .durable);
    const ptr = tables.get(h).?;
    _ = ptr.insert(.{ .value = @as(i32, 19) });
    const token = try tables.beginInitAdmission();
    try testing.expectError(error.AdmissionMutationRejected, tables.grow(h, 8));
    try testing.expectError(error.AdmissionMutationRejected, tables.registerSchema(name, &schema));
    try testing.expectError(error.AdmissionMutationRejected, tables.unregisterSchema(name));
    try testing.expectError(error.AdmissionMutationRejected, tables.prepareReplacement(h, h));
    try testing.expectError(error.AdmissionMutationRejected, tables.ensureSingleton(&schema, name, .{ .value = @as(i32, 0) }, .durable));
    try testing.expect(!ptr.required_singleton);
    try tables.validateInitAdmission(token);
    tables.destroy(h);
    try testing.expect(!tables.commitInitAdmission(token));
    try testing.expectError(error.AdmissionMutationRejected, tables.validateInitAdmission(token));
    try testing.expect(tables.abortInitAdmission(token));
    try testing.expectEqual(ptr, tables.get(h).?);
    try testing.expect(ptr.rowCapacity() >= 1);
}

fn admissionAllocationFailures(allocator: std.mem.Allocator) !void {
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    var tables: Registry = undefined;
    try tables.init(&mem, 4);
    defer tables.deinit();
    var schema: Table.Schema = undefined;
    try schema.initWithAtoms(testing.allocator, null, 1);
    defer schema.deinit();
    schema.addField("value", i32, .text_field);
    const old = try tables.create(&schema, 1, Atom.from("failure.old"), .durable);
    const ptr = tables.get(old).?;
    const row = ptr.insert(.{ .value = @as(i32, 91) });
    // Inject every journal allocation independently, not only backing-pool growth.
    const saved = mem.global_source;
    mem.global_source = allocator;
    defer mem.global_source = saved;
    const checkpoint = try tables.beginInitAdmission();
    std.debug.assert(tables.abortInitAdmission(checkpoint));
    mem.global_source = saved;
    const token = try tables.beginInitAdmission();
    defer {
        std.debug.assert(tables.abortInitAdmission(token));
        std.debug.assert(tables.get(old).? == ptr);
        std.debug.assert(ptr.getField(i32, row, "value").?.* == 91);
    }
    _ = try tables.create(&schema, 10000, Atom.from("failure.new"), .transient);
    try tables.validateInitAdmission(token);
}

test "Registry init admission every metadata and storage allocation failure preserves abort" {
    try testing.checkAllAllocationFailures(testing.allocator, admissionAllocationFailures, .{});
}

test "schema typed fallible fields preserve exact descriptors" {
    var memory: memory_mod.Memory = undefined;
    memory.init(testing.allocator);
    defer memory.deinit();
    var kw: Atom.Registry = undefined;
    try kw.init(&memory);
    defer kw.deinit();
    var legacy: Table.Schema = undefined;
    try legacy.init(testing.allocator, &kw, 8);
    defer legacy.deinit();
    var prepared: Table.Schema = undefined;
    try prepared.init(testing.allocator, &kw, 8);
    defer prepared.deinit();
    inline for (.{ u32, u8, [64]u8, [6]f32, math.Vec2f, Atom, struct { x: u32, y: u8 } }, 0..) |T, i| {
        const name = std.fmt.comptimePrint("field_{d}", .{i});
        legacy.addField(name, T, .hex);
        try prepared.addFieldFallible(name, T, .hex);
    }
    try testing.expectEqualDeep(legacy.fields, prepared.fields);
}

test "schema typed fallible name allocation failures leave fields reusable" {
    var memory: memory_mod.Memory = undefined;
    memory.init(testing.allocator);
    defer memory.deinit();
    var kw: Atom.Registry = undefined;
    try kw.init(&memory);
    defer kw.deinit();
    // First failure is owned-name bytes, second is owned_names growth. Atom
    // registration can remain monotonically; no partial descriptor is published.
    for (0..2) |failure| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        var schema: Table.Schema = undefined;
        try schema.init(failing.allocator(), &kw, 2);
        defer schema.deinit();
        failing.fail_index = failing.alloc_index + failure;
        try testing.expectError(error.OutOfMemory, schema.addFieldFallible("prepared_name", [64]u8, .text_field));
        try testing.expectEqual(@as(usize, 0), schema.fields.len);
        try testing.expectEqual(@as(usize, 0), schema.list.items.len);
        try testing.expectEqual(@as(usize, 0), schema.owned_names.items.len);
        failing.fail_index = std.math.maxInt(usize);
        try schema.addFieldFallible("prepared_name", [64]u8, .text_field);
        try schema.addFieldFallible("second_name", u32, .int);
        try testing.expectEqual(@as(usize, 2), schema.fields.len);
        try testing.expectEqualStrings("prepared_name", schema.fields[0].name);
        try testing.expectEqualStrings("second_name", schema.fields[1].name);
    }
}

test "table arena mixed tag rows grow across pages and swap pop across chunks" {
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    var registry: Registry = undefined;
    try registry.init(&mem, 2);
    defer registry.deinit();
    var schema: Table.Schema = undefined;
    try schema.initWithAtoms(testing.allocator, null, 4);
    defer schema.deinit();
    schema.addField("small", u8, .int);
    schema.addField("wide", u64, .int);
    schema.addField("vector", Vec2f, .text_field);
    try schema.addFieldTypeFallible("tag", .tag, 0, .checkbox);
    const identity = try registry.create(&schema, 1, Atom.from("arena.mixed"), .durable);
    const table = registry.get(identity).?;
    const chunk_capacity = table.rowCapacity();
    try testing.expectEqual(std.heap.pageSize(), table.storage.columnar.arena.bytes);
    const handles = try testing.allocator.alloc(Table.RowHandle, chunk_capacity * 2 + 3);
    defer testing.allocator.free(handles);
    for (handles, 0..) |*handle, i| {
        handle.* = try table.alloc();
        try table.writeFieldSingle(u8, handle.*, "small", @intCast(i % 251));
        try table.writeFieldSingle(u64, handle.*, "wide", i * 1009);
        table.setFieldPresent(handle.*, 3);
        try testing.expectEqual(@as(usize, 0), table.rowFieldBytes(handle.row, 3).len);
        try testing.expectEqual(@as(usize, 0), @intFromPtr(table.rowFieldBytes(handle.row, 1).ptr) % @alignOf(u64));
    }
    try testing.expectEqual(@as(usize, 3), table.storage.columnar.arena.pages);
    const removed = handles[1];
    const moved = handles[handles.len - 1];
    table.free(removed);
    try testing.expect(!table.valid(removed));
    try testing.expect(table.valid(moved));
    try testing.expectEqual(@as(u32, 1), table.storage.columnar.index.at(moved.row).*);
    try testing.expectEqual(@as(u64, (handles.len - 1) * 1009), table.getField(u64, moved, "wide").?.*);
    for (handles[2..], 2..) |handle, i| {
        try testing.expect(table.valid(handle));
        try testing.expectEqual(@as(u64, i * 1009), table.getField(u64, handle, "wide").?.*);
        const position = table.storage.columnar.index.at(handle.row).*;
        try testing.expectEqual(handle.row, table.storage.columnar.row_id.at(position).*);
    }
    var row_query = table.query(struct { small: *u8, wide: *u64 });
    var queried: usize = 0;
    while (row_query.next()) |entry| {
        try testing.expect(table.valid(entry.handle));
        try testing.expectEqual(entry.view.wide.*, table.getField(u64, entry.handle, "wide").?.*);
        try testing.expectEqual(entry.view.small.*, table.getField(u8, entry.handle, "small").?.*);
        queried += 1;
    }
    try testing.expectEqual(handles.len - 1, queried);
    const reused = try table.alloc();
    try testing.expectEqual(removed.row, reused.row);
    try testing.expect(reused.generation != removed.generation);
    table.free(reused); // Dense tail deletion.
    const bytes = table.storage.columnar.arena.bytes;
    try registry.grow(identity, 1);
    try testing.expectEqual(bytes, table.storage.columnar.arena.bytes);
    table.clear();
    try testing.expectEqual(bytes, table.storage.columnar.arena.bytes);
    try testing.expectEqual(@as(u32, 0), table.count());
    try testing.expect(!table.valid(moved));
    _ = try table.alloc();
    try testing.expectEqual(bytes, table.storage.columnar.arena.bytes);
    registry.destroy(identity);
    try testing.expectEqual(@as(usize, 0), registry.storageStats().durable.reserved_bytes);
}

test "registry memory report tracks growth destruction and stable repeated samples" {
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    var kw: Atom.Registry = undefined;
    try kw.init(&mem);
    defer kw.deinit();
    var registry: Registry = undefined;
    try registry.init(&mem, 8);
    defer registry.deinit();
    var schema: Table.Schema = undefined;
    try schema.init(testing.allocator, &kw, 1);
    defer schema.deinit();
    schema.addField("value", u32, .int);
    const identity = try registry.create(&schema, 1, kw.intern("tracked"), .durable);
    const singleton = try registry.ensureSingleton(&schema, kw.intern("tracked_scalar"), .{ .value = @as(u32, 7) }, .durable);
    try registry.syncMemoryTable(&kw);
    const report = registry.get(registry.findHandleByName(kw.intern("table_memory")).?).?;
    try testing.expectEqual(@as(u32, 3), report.count());
    const before = registry.storageStats();
    for (0..10) |_| try registry.syncMemoryTable(&kw);
    try testing.expectEqualDeep(before, registry.storageStats());
    const tracked = registry.get(identity).?;
    const capacity = tracked.rowCapacity();
    for (0..capacity + 1) |_| _ = try tracked.alloc();
    try registry.syncMemoryTable(&kw);
    var row_iterator = report.rows();
    var found = false;
    while (row_iterator.next()) |row| {
        const index = report.getField(u32, row, "table_index").?.*;
        if (index == identity.index) {
            found = true;
            try testing.expectEqual(tracked.count(), report.getField(u32, row, "row_count").?.*);
            try testing.expectEqual(@as(u64, tracked.storage.columnar.arena.bytes), report.getField(u64, row, "reserved_bytes").?.*);
            try testing.expectEqual(@as(u64, 2), report.getField(u64, row, "reserved_pages").?.*);
        }
        if (index == singleton.handle.index) {
            const field = report.getSchema().fieldIndex("reserved_bytes").?;
            try testing.expect(!report.rowHas(row.row, report.getSchema().fields[field].bit));
        }
    }
    try testing.expect(found);
    registry.destroy(identity);
    try registry.syncMemoryTable(&kw);
    try testing.expectEqual(@as(u32, 2), report.count());
}

test "table arena oversized rows use minimum page multiple and tag-only tables grow" {
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    var registry: Registry = undefined;
    try registry.init(&mem, 2);
    defer registry.deinit();
    var schema: Table.Schema = undefined;
    try schema.initWithAtoms(testing.allocator, null, 1);
    defer schema.deinit();
    const Large = [std.heap.pageSize() + 17]u8;
    schema.addField("large", Large, .text_field);
    const identity = try registry.create(&schema, 1, Atom.from("arena.large"), .durable);
    const table = registry.get(identity).?;
    try testing.expectEqual(@as(u32, 1), table.rowCapacity());
    try testing.expectEqual(@as(usize, 2), table.storage.columnar.arena.pages);
    const first = try table.alloc();
    @memset(table.rowFieldBytes(first.row, 0), 0x5a);
    const second = try table.alloc();
    try testing.expectEqual(@as(usize, 4), table.storage.columnar.arena.pages);
    @memset(table.rowFieldBytes(second.row, 0), 0x6b);
    table.free(first);
    try testing.expectEqual(@as(u8, 0x6b), table.rowFieldBytes(second.row, 0)[@sizeOf(Large) - 1]);
    var tags: Table.Schema = undefined;
    try tags.initWithAtoms(testing.allocator, null, 1);
    defer tags.deinit();
    try tags.addFieldTypeFallible("tag", .tag, 0, .checkbox);
    const tag_identity = try registry.create(&tags, 1, Atom.from("arena.tags"), .durable);
    const tag_table = registry.get(tag_identity).?;
    const initial_capacity = tag_table.rowCapacity();
    for (0..initial_capacity + 1) |_| {
        const row = try tag_table.alloc();
        tag_table.setFieldPresent(row, 0);
    }
    try testing.expectEqual(@as(usize, 2), tag_table.storage.columnar.arena.pages);
    try testing.expectEqual(initial_capacity + 1, tag_table.count());
}

fn initWideTestSchema(schema: *Table.Schema, kw: *Atom.Registry, field_count: usize) !void {
    try schema.init(testing.allocator, kw, field_count);
    var name_buffer: [8]u8 = undefined;
    for (0..field_count) |i| {
        const name = std.fmt.bufPrint(&name_buffer, "f{d}", .{i}) catch unreachable;
        schema.addFieldType(name, .i32, 4, .int);
    }
}

fn writeWideTestField(table: *Table, handle: Table.RowHandle, index: u32) void {
    const value: i32 = @intCast(index);
    table.writeFieldRawByIndex(handle, index, std.mem.asBytes(&value));
}

fn countRows(query_rows: anytype) usize {
    var remaining_rows = query_rows;
    var total: usize = 0;
    while (remaining_rows.next()) |_| total += 1;
    return total;
}

test "wide tables keep presence in every mask word through queries, compaction, export and singletons" {
    var table_memory: memory_mod.Memory = undefined;
    table_memory.init(testing.allocator);
    defer table_memory.deinit();
    var kw: Atom.Registry = undefined;
    try kw.init(&table_memory);
    defer kw.deinit();
    var table_registry: Registry = undefined;
    try table_registry.init(&table_memory, 4);
    defer table_registry.deinit();

    var schema: Table.Schema = undefined;
    try initWideTestSchema(&schema, &kw, 100);
    defer schema.deinit();
    try testing.expectEqual(@as(u8, 2), schema.maskWords());

    const wide = table_registry.get(try table_registry.create(&schema, 2, kw.intern("wide"), .durable)).?;
    try testing.expectEqual(@as(u8, 2), wide.maskWords());
    const first = try wide.alloc();
    writeWideTestField(wide, first, 0);
    const second = try wide.alloc();
    for ([_]u32{ 0, 63, 64, 99 }) |index| writeWideTestField(wide, second, index);
    const third = try wide.alloc();
    writeWideTestField(wide, third, 70);

    const second_mask = wide.rowMask(second.row);
    try testing.expectEqual((@as(u64, 1) << 63) | 1, second_mask.words[0]);
    try testing.expectEqual((@as(u64, 1) << 35) | 1, second_mask.words[1]);
    try testing.expect(second_mask.words[2] == 0 and second_mask.words[3] == 0);
    try testing.expect(wide.rowHas(second.row, 99) and !wide.rowHas(first.row, 64));

    // A view spanning both words, one confined to the second word, and one in the first.
    try testing.expectEqual(@as(usize, 1), countRows(wide.query(struct { f0: *i32, f99: *i32 })));
    try testing.expectEqual(@as(usize, 1), countRows(wide.query(struct { f70: *i32 })));
    try testing.expectEqual(@as(usize, 2), countRows(wide.query(struct { f0: *i32 })));

    // Freeing the first row moves the last into its place; both words travel with it.
    wide.free(first);
    try testing.expect(wide.rowMask(second.row).eql(second_mask));
    try testing.expect(wide.rowHas(third.row, 70) and !wide.rowHas(third.row, 0));
    try testing.expectEqual(@as(usize, 1), countRows(wide.query(struct { f70: *i32 })));

    const saved = try writeFile(testing.allocator, wide, &kw, &.{});
    defer testing.allocator.free(saved);
    const copy = table_registry.get(try table_registry.create(&schema, 4, kw.intern("wide_copy"), .durable)).?;
    try readFile(copy, &kw, saved);
    try testing.expectEqual(@as(u32, 2), copy.count());
    var spanning = copy.query(struct { f0: *i32, f99: *i32 });
    const imported = spanning.next().?;
    try testing.expect(copy.rowMask(imported.handle.row).eql(second_mask));
    try testing.expectEqual(@as(i32, 99), imported.view.f99.*);
    try testing.expectEqual(@as(usize, 1), countRows(copy.query(struct { f70: *i32 })));

    // A row naming a bit past the schema, here field 114 in its second word, is refused.
    const first_row_second_word = std.mem.bytesAsValue(u64, saved[@sizeOf(FileHeader) + @sizeOf(u64) ..][0..@sizeOf(u64)]);
    first_row_second_word.* |= @as(u64, 1) << 50;
    resealTestFile(saved);
    const rejected = table_registry.get(try table_registry.create(&schema, 4, kw.intern("wide_rejected"), .durable)).?;
    try testing.expectError(error.InvalidFile, readFile(rejected, &kw, saved));

    const single = table_registry.get(try table_registry.createSingleton(&schema, kw.intern("wide_single"), .durable)).?;
    const only = try single.alloc();
    writeWideTestField(single, only, 99);
    try testing.expect(single.rowHas(0, 99) and !single.rowHas(0, 0));
    try testing.expectEqual(@as(usize, 1), countRows(single.query(struct { f99: *i32 })));
    try testing.expectEqual(@as(usize, 0), countRows(single.query(struct { f0: *i32, f99: *i32 })));
}

test "schema addFields unions fields and refuses conflicts or overflow without change" {
    var memory: memory_mod.Memory = undefined;
    memory.init(testing.allocator);
    defer memory.deinit();
    var kw: Atom.Registry = undefined;
    try kw.init(&memory);
    defer kw.deinit();
    var shared: Table.Schema = undefined;
    try shared.init(testing.allocator, &kw, 3);
    defer shared.deinit();
    shared.addField("position", math.Vec2f, .{ .vector = .{ .components = 2 } });
    shared.addField("time", f32, .{ .float_slider = .{ .min = 0, .max = 1 } });
    shared.addField("name", Atom, .atom);

    var target: Table.Schema = undefined;
    try target.init(testing.allocator, &kw, 4);
    defer target.deinit();
    target.addField("health", i32, .int);
    target.addField("position", math.Vec2f, .{ .vector = .{ .components = 2 } });
    target.addField("time", f32, .{ .float_slider = .{ .min = -5, .max = 5 } });
    try target.addFields(&shared);
    try target.validate();
    try testing.expectEqual(@as(usize, 4), target.fields.len);
    try testing.expectEqual(@as(f32, -5), target.fields[2].view_kind.float_slider.min);
    try testing.expectEqualStrings("name", target.fields[3].name);
    // A second union adds nothing.
    try target.addFields(&shared);
    try testing.expectEqual(@as(usize, 4), target.fields.len);

    var conflicting: Table.Schema = undefined;
    try conflicting.init(testing.allocator, &kw, 2);
    defer conflicting.deinit();
    conflicting.addField("time", i32, .int);
    try testing.expectError(error.FieldConflict, conflicting.addFields(&shared));
    try testing.expectEqual(@as(usize, 1), conflicting.fields.len);

    var small: Table.Schema = undefined;
    try small.init(testing.allocator, &kw, 2);
    defer small.deinit();
    small.addField("health", i32, .int);
    try testing.expectError(error.TooManyFields, small.addFields(&shared));
    try testing.expectEqual(@as(usize, 1), small.fields.len);

    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var refused: Table.Schema = undefined;
    try refused.init(failing.allocator(), &kw, 4);
    defer refused.deinit();
    failing.fail_index = failing.alloc_index + 2;
    try testing.expectError(error.OutOfMemory, refused.addFields(&shared));
    try testing.expectEqual(@as(usize, 0), refused.fields.len);
    try testing.expectEqual(@as(usize, 0), refused.owned_names.items.len);
}

test "schemas accept up to the mask's bit count and refuse more" {
    var table_memory: memory_mod.Memory = undefined;
    table_memory.init(testing.allocator);
    defer table_memory.deinit();
    var kw: Atom.Registry = undefined;
    try kw.init(&table_memory);
    defer kw.deinit();

    var widest: Table.Schema = undefined;
    try initWideTestSchema(&widest, &kw, Mask.max_bits);
    defer widest.deinit();
    try widest.validate();
    try testing.expectEqual(@as(u8, Mask.max_words), widest.maskWords());
    try testing.expectEqual(@as(u8, Mask.max_bits - 1), widest.fields[Mask.max_bits - 1].bit);

    var too_wide: Table.Schema = undefined;
    try testing.expectError(error.TooManyFields, too_wide.init(testing.allocator, &kw, Mask.max_bits + 1));
}

test "refs resolve through their cache, find a replaced row by name, and refuse a renamed one" {
    var table_memory: memory_mod.Memory = undefined;
    table_memory.init(testing.allocator);
    defer table_memory.deinit();
    var kw: Atom.Registry = undefined;
    try kw.init(&table_memory);
    defer kw.deinit();
    var table_registry: Registry = undefined;
    try table_registry.init(&table_memory, 4);
    defer table_registry.deinit();

    var named_schema: Table.Schema = undefined;
    try named_schema.init(testing.allocator, &kw, 2);
    defer named_schema.deinit();
    named_schema.addFieldType("name", .atom, @sizeOf(Atom), .atom);
    named_schema.addFieldType("health", .i32, 4, .int);
    const targets_handle = try table_registry.create(&named_schema, 4, kw.intern("targets"), .durable);
    const targets = table_registry.get(targets_handle).?;
    const wolf_name = kw.intern("wolf_1");
    const filler = try targets.alloc();
    try targets.writeFieldSingle(Atom, filler, "name", kw.intern("wolf_0"));
    const wolf = try targets.alloc();
    try targets.writeFieldSingle(Atom, wolf, "name", wolf_name);

    const ref = table_registry.makeRef(targets_handle, wolf).?;
    try testing.expect(ref.isPersistable());
    try testing.expectEqual(wolf_name, ref.row_name);
    const cached = table_registry.resolveRef(ref).?;
    try testing.expect(std.meta.eql(wolf, cached.handle));
    try testing.expect(std.meta.eql(ref, cached.ref));

    // The row is freed and a new one takes the name: the stale cache is refused and the search finds it.
    targets.free(wolf);
    targets.free(filler);
    _ = try targets.alloc();
    const reborn = try targets.alloc();
    try targets.writeFieldSingle(Atom, reborn, "name", wolf_name);
    const found = table_registry.resolveRef(ref).?;
    try testing.expect(std.meta.eql(reborn, found.handle));
    try testing.expect(!std.meta.eql(ref, found.ref));
    try testing.expect(std.meta.eql(found.ref, table_registry.resolveRef(found.ref).?.ref));

    // Renamed, the row no longer answers to the ref, through the cache or the search.
    try targets.writeFieldSingle(Atom, reborn, "name", kw.intern("wolf_renamed"));
    try testing.expect(table_registry.resolveRef(found.ref) == null);
    try testing.expect(table_registry.resolveRef(Ref.none) == null);

    var nameless_schema: Table.Schema = undefined;
    try nameless_schema.init(testing.allocator, &kw, 1);
    defer nameless_schema.deinit();
    nameless_schema.addFieldType("health", .i32, 4, .int);
    const nameless_handle = try table_registry.create(&nameless_schema, 2, kw.intern("nameless"), .durable);
    const nameless = table_registry.get(nameless_handle).?;
    const row = try nameless.alloc();
    const runtime_ref = table_registry.makeRef(nameless_handle, row).?;
    try testing.expect(!runtime_ref.isPersistable() and !runtime_ref.isNone());
    try testing.expect(table_registry.resolveRef(runtime_ref) != null);
    nameless.free(row);
    try testing.expect(table_registry.resolveRef(runtime_ref) == null);
    try testing.expect(table_registry.makeRef(nameless_handle, row) == null);
}

test "ref text names a table and a row and refuses anything else" {
    var table_memory: memory_mod.Memory = undefined;
    table_memory.init(testing.allocator);
    defer table_memory.deinit();
    var kw: Atom.Registry = undefined;
    try kw.init(&table_memory);
    defer kw.deinit();

    const ref = try parseRef(" app_entities/barnaby_1 ", &kw);
    try testing.expectEqual(kw.intern("app_entities"), ref.table_name);
    try testing.expectEqual(kw.intern("barnaby_1"), ref.row_name);
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("app_entities/barnaby_1", formatRef(ref, &kw, &buffer));
    try testing.expect((try parseRef("<none>", &kw)).isNone());
    try testing.expectEqualStrings("<none>", formatRef(.none, &kw, &buffer));
    for ([_][]const u8{ "", "app_entities", "/barnaby_1", "app_entities/", "a/b/c", "app_entities/<row 3>" }) |text| {
        try testing.expectError(error.InvalidRef, parseRef(text, &kw));
    }
    const nameless: Ref = .{ .table_name = kw.intern("app_entities"), .row = 3 };
    try testing.expectEqualStrings("app_entities/<row 3>", formatRef(nameless, &kw, &buffer));
}

test "Registry makes singletons of a schema registered as a singleton's" {
    var memory: memory_mod.Memory = undefined;
    memory.init(testing.allocator);
    defer memory.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&memory);
    defer atoms.deinit();
    var tables: Registry = undefined;
    try tables.init(&memory, 4);
    defer tables.deinit();
    var schema: Table.Schema = undefined;
    try schema.init(testing.allocator, &atoms, 1);
    defer schema.deinit();
    schema.addField("keymap", Atom, .atom);

    const name = atoms.intern("settings");
    try tables.registerSingletonSchema(name, &schema);
    try tables.registerSingletonSchema(name, &schema);
    try testing.expect(tables.isSingletonSchema(name));
    try testing.expectError(error.SchemaMismatch, tables.registerSchema(name, &schema));
    try testing.expect(!tables.isSingletonSchema(atoms.intern("other")));

    const handle = try tables.createNamedSingleton(name, atoms.intern("user_settings"), .persistent, null);
    const table = tables.get(handle).?;
    try testing.expect(table.isSingleton());
    try testing.expect(!table.isAllocated(0));
    try testing.expectEqual(name, table.schema_name);
    tables.destroy(handle);
    try testing.expectError(error.UnknownSchema, tables.createNamedSingleton(atoms.intern("unknown"), atoms.intern("x"), .durable, null));
}
