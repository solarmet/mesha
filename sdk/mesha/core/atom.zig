//! Atoms: the ids code refers to by name (a table, a column, an action, a panel, a message
//! tag, an enum-like kind), and the interner that keeps their names.
//!
//! `Atom.from("name")` hashes the name and needs no registry, so it works at comptime and in
//! any image. `Atom.Registry` records names so that an atom can be printed: the log, the
//! inspector and the MCP server read them with `lookup`. The host owns one registry and hands
//! it to each plugin's entry points; a plugin interns its names at init (a system's `names`),
//! never in a kernel. Text a person reads is a string, never an atom.
const std = @import("std");
const memory_mod = @import("memory.zig");

/// An id that code refers to by name: the 64-bit Wyhash (seed 0) of the name's bytes. Equal names
/// give equal atoms in every image and every run, so an atom may be stored in a table, a file
/// or a message. Two names that hash alike are the same atom; nothing detects it.
pub const Atom = enum(u64) {
    _,

    /// The atom of `source`: a string (a byte slice or a pointer to a byte array) is hashed; a
    /// `u64`, a comptime integer or an enum value is taken as the atom's number unchanged, which
    /// is how an atom-valued enum's tag becomes its atom. Any other type is a compile error.
    /// Records nothing: a name is printable only once a registry has interned it. Usable at
    /// comptime.
    pub fn from(source: anytype) Atom {
        return switch (@typeInfo(@TypeOf(source))) {
            .@"enum" => @enumFromInt(@intFromEnum(source)),
            .int => |int| if (int.bits == 64 and int.signedness == .unsigned)
                @enumFromInt(source)
            else
                @compileError("Atom.from expects a u64, enum, or string"),
            .comptime_int => @enumFromInt(source),
            .pointer => |ptr| blk: {
                const is_byte_slice = ptr.size == .slice and ptr.child == u8;
                const is_byte_array = ptr.size == .one and switch (@typeInfo(ptr.child)) {
                    .array => |array| array.child == u8,
                    else => false,
                };
                if (!is_byte_slice and !is_byte_array) {
                    @compileError("Atom.from expects a u64, enum, or string");
                }
                const bytes: []const u8 = source;
                // A message enum hashes all its tag names in one comptime scope.
                if (@inComptime()) @setEvalBranchQuota(1000 + 100 * bytes.len);
                break :blk @enumFromInt(std.hash.Wyhash.hash(0, bytes));
            },
            else => @compileError("Atom.from expects a u64, enum, or string"),
        };
    }

    /// The atom as a value of `T`, an `enum(u64)` whose tags are atoms' numbers, to `switch` on.
    /// The number is unchanged. `T` must be non-exhaustive (`_`) wherever an atom it has no tag
    /// for may arrive, as an unknown message tag may; converting such an atom to an exhaustive
    /// enum is illegal behavior.
    pub fn to(self: Atom, comptime T: type) T {
        const info = switch (@typeInfo(T)) {
            .@"enum" => |info| info,
            else => @compileError("Atom.to expects an enum(u64) target"),
        };
        if (info.tag_type != u64) @compileError("Atom.to expects an enum(u64) target");
        return @enumFromInt(@intFromEnum(self));
    }

    /// The atom's number: the value an atom-valued enum's tag declares, as in
    /// `quit = Atom.from("quit").value()`.
    pub fn value(self: Atom) u64 {
        return @intFromEnum(self);
    }

    /// Owns its storage in a private host scope named `scope_name`, so strings and the map survive
    /// plugin reload; its arenas keep no allocator, so either image grows them.
    ///
    /// Strings live in chunks that are never moved or released before `deinit`, so a slice
    /// from a lookup stays valid across growth and reload. The map is replaced by a new
    /// generation when it runs out of room. Nothing retains a map pointer across a call: a
    /// lookup returns the string slice by value, and the log encoder copies the bytes.
    ///
    /// Registration is monotonic. These arenas are exempt from init admissions, so an abort
    /// keeps names interned during it and interning never rejects or unvalidates one. The
    /// admission snapshot excludes this scope to match.
    ///
    /// One thread owns the interner: it interns, and looks up with `lookup`. Another thread
    /// looks up with `lookupShared`, which takes no lock and finds every name the owner has
    /// published. Neither waits for the other. A generation the owner replaces while another
    /// thread is inside `lookupShared` stays until a later publication finds no such thread.
    pub const Registry = struct {
        /// The name of the private memory scope the registry keeps its storage in.
        pub const scope_name = "atoms";
        const min_string_chunk_bytes = 16 * 1024;
        const max_string_chunk_bytes = 4 * 1024 * 1024;
        /// A generation holds at most this percentage of its slots, so a probe always ends.
        const max_load_percent = 80;
        const min_map_slots = 8;

        /// One name. Empty until `name_ptr` is published: the owner writes `atom` and
        /// `name_len` first, then the pointer with release, so a reader that loads the pointer
        /// with acquire reads both.
        const Slot = struct {
            atom: Atom,
            name_len: usize,
            name_ptr: std.atomic.Value(?[*]const u8),
        };

        /// One generation of the table, open-addressed by the atom's low bits, in its own
        /// arena. `slots.len` is a power of two.
        const Map = struct {
            slots: []Slot,
            arena: *memory_mod.Arena,
            /// The generation retired before this one, while this one waits to be released.
            next_retired: ?*Map = null,

            fn find(map: *const Map, id: Atom) ?[]const u8 {
                const mask = map.slots.len - 1;
                var index: usize = @intCast(id.value() & mask);
                while (true) : (index = (index + 1) & mask) {
                    const slot = &map.slots[index];
                    const name_ptr = slot.name_ptr.load(.acquire) orelse return null;
                    if (slot.atom == id) return name_ptr[0..slot.name_len];
                }
            }

            /// The owner's alone. `id` is not in the map, and a slot is free.
            fn insert(map: *Map, id: Atom, name: []const u8) void {
                const mask = map.slots.len - 1;
                var index: usize = @intCast(id.value() & mask);
                while (map.slots[index].name_ptr.load(.monotonic) != null) index = (index + 1) & mask;
                const slot = &map.slots[index];
                slot.atom = id;
                slot.name_len = name.len;
                slot.name_ptr.store(name.ptr, .release);
            }

            fn maxNames(slot_count: usize) usize {
                return slot_count * max_load_percent / 100;
            }

            /// The slots a generation holding `name_count` names takes.
            fn slotsFor(name_count: u32) error{OutOfMemory}!usize {
                const wanted_slots = @as(u64, name_count) * 100 / max_load_percent + 1;
                const slots = std.math.ceilPowerOfTwo(u64, wanted_slots) catch return error.OutOfMemory;
                return @intCast(@max(slots, min_map_slots));
            }
        };

        /// Everything a failed batch must leave unchanged.
        /// What the registry holds, as `storage` reports it: everything a failed `tryInternAll`
        /// must leave unchanged, which is what tests compare.
        pub const Storage = struct {
            /// The bytes of every recorded name together.
            string_bytes: usize,
            /// The chunks the names are kept in.
            string_chunk_count: u32,
            /// The slots of the live map generation; 0 before the first name.
            map_capacity: u32,
            /// How many times the map has been replaced by a larger one, the first included.
            map_generation: u64,
            /// The bytes of backing memory the registry's scope holds.
            backing_bytes: u64,
        };

        /// The private scope, named `scope_name`, that owns every chunk and map generation.
        scope: *memory_mod.Scope,
        /// The live generation; null until the first name. Replaced by the owner alone.
        current: std.atomic.Value(?*Map) = .init(null),
        /// Names in `current`; the owner's alone.
        name_count: u32 = 0,
        /// How many generations have been made live.
        map_generation: u64 = 0,
        /// Generations replaced while another thread was inside `lookupShared`, newest first.
        retired: ?*Map = null,
        /// Threads inside `lookupShared`. The owner releases a replaced generation only after
        /// reading zero here, which pairs with each reader counting itself before it loads
        /// `current`: a reader counted too late to stop the release loads the new generation.
        shared_readers: std.atomic.Value(u32) = .init(0),
        /// The newest chunk. The cursor only advances at publication, so a failed batch has
        /// nothing to roll back here.
        string_chunk: []u8 = &.{},
        /// The bytes of `string_chunk` that names occupy.
        string_chunk_used: usize = 0,
        /// The chunks allocated so far.
        string_chunk_count: u32 = 0,
        /// The bytes of every recorded name together.
        string_bytes: usize = 0,
        /// Failure injection: logical bytes storage may still take before refusing with
        /// OutOfMemory, counting names and any new map generation. Null outside tests.
        storage_limit_for_test: ?usize = null,

        /// Opens the registry's private scope in `memory` and starts empty; allocates nothing more
        /// until the first name. `self` must not move afterwards. Fails when the scope cannot be
        /// opened: inside an init admission (`error.AdmissionActive`), or while a scope of the name
        /// is open (`error.ScopeAlreadyOpen`).
        pub fn init(self: *Registry, memory: *memory_mod.Memory) !void {
            // A static hash: registering this name would need the interner being created.
            const scope = try memory.openPrivateScope(Atom.from(scope_name));
            self.* = .{ .scope = scope };
        }

        /// Releases the scope and with it every name, so slices from `lookup` dangle after. Inside
        /// an init admission the scope is left for `Memory.deinit` to reclaim.
        pub fn deinit(self: *Registry) void {
            _ = self.scope.memory.releasePrivateScope(self.scope);
        }

        /// The atom of `name`, with the name recorded so `lookup` finds it. The bytes are copied:
        /// `name` may be temporary. A name already recorded allocates nothing. Panics when memory
        /// runs out; `tryInternAll` reports that instead. The owner thread's alone.
        pub fn intern(self: *Registry, name: []const u8) Atom {
            const id: Atom = @enumFromInt(std.hash.Wyhash.hash(0, name));
            if (self.lookup(id) == null) {
                self.tryInternAll(&.{name}) catch @panic("atoms: out of bookkeeping space");
            }
            return id;
        }

        /// What the registry holds at this moment. The owner thread's alone.
        pub fn storage(self: *const Registry) Storage {
            const scope_stats = self.scope.stats();
            return .{
                .string_bytes = self.string_bytes,
                .string_chunk_count = self.string_chunk_count,
                .map_capacity = self.mapCapacity(),
                .map_generation = self.map_generation,
                .backing_bytes = scope_stats.backing.current_bytes,
            };
        }

        /// Records every name of `names` or none of them. Each name's atom is the one `intern`
        /// gives it; names already recorded, and repeats within `names`, cost nothing. The bytes
        /// are copied, so `names` may be temporary and may alias anything. Any new map generation
        /// and string chunk are prepared first, each in its own arena so a failure returns its
        /// pages, and publication has no fallible step: on `error.OutOfMemory` the names, the
        /// map and the scope's backing are as they were. The owner thread's alone.
        pub fn tryInternAll(self: *Registry, names: []const []const u8) error{OutOfMemory}!void {
            var bytes: usize = 0;
            var missing: u32 = 0;
            for (names, 0..) |name, i| {
                const id = Atom.from(name);
                if (self.lookup(id) != null) continue;
                var duplicate = false;
                for (names[0..i]) |previous| if (Atom.from(previous) == id) {
                    duplicate = true;
                    break;
                };
                if (duplicate) continue;
                bytes = std.math.add(usize, bytes, name.len) catch return error.OutOfMemory;
                missing = std.math.add(u32, missing, 1) catch return error.OutOfMemory;
            }
            if (missing == 0) return;
            const total = std.math.add(u32, self.name_count, missing) catch return error.OutOfMemory;
            if (@as(u64, total) * 100 > (@as(u64, 1) << 31) * max_load_percent) return error.OutOfMemory;
            const map_grows = total > Map.maxNames(self.mapCapacity());
            const remaining_limit = try self.chargeStorageLimit(bytes, map_grows, total);

            var new_map: ?*Map = null;
            errdefer if (new_map) |map| self.scope.releaseAdmissionExemptArena(map.arena);
            if (map_grows) new_map = try self.allocateMap(total);

            var chunk = self.string_chunk;
            var chunk_used = self.string_chunk_used;
            const chunk_grows = bytes > chunk.len - chunk_used;
            if (chunk_grows) {
                chunk = try self.allocateStringChunk(bytes);
                chunk_used = 0;
            }

            // Publication: nothing below can fail. A growing batch fills the new generation
            // whole before readers can reach it; otherwise each name is published in place.
            const old_map = self.current.load(.monotonic);
            const target_map = new_map orelse old_map.?;
            if (new_map) |map| {
                if (old_map) |old| {
                    for (old.slots) |*slot| {
                        const name_ptr = slot.name_ptr.load(.monotonic) orelse continue;
                        map.insert(slot.atom, name_ptr[0..slot.name_len]);
                    }
                }
            }
            for (names) |name| {
                const id = Atom.from(name);
                if (target_map.find(id) != null) continue;
                const copy = chunk[chunk_used..][0..name.len];
                @memcpy(copy, name);
                chunk_used += name.len;
                target_map.insert(id, copy);
            }
            if (new_map) |map| {
                // Sequentially consistent, with the load of `shared_readers` below: see there.
                self.current.store(map, .seq_cst);
                self.map_generation += 1;
                if (old_map) |old| {
                    old.next_retired = self.retired;
                    self.retired = old;
                }
            }
            self.name_count = total;
            self.string_chunk = chunk;
            self.string_chunk_used = chunk_used;
            if (chunk_grows) self.string_chunk_count += 1;
            self.string_bytes += bytes;
            self.storage_limit_for_test = remaining_limit;
            // After the copy, so names may alias anything, and after the new map is live.
            self.releaseRetiredMaps();
        }

        /// Releases the replaced generations once no other thread is inside `lookupShared`.
        /// A reader that counted itself after this load found the newest generation.
        fn releaseRetiredMaps(self: *Registry) void {
            if (self.retired == null) return;
            if (self.shared_readers.load(.seq_cst) != 0) return;
            var it = self.retired;
            while (it) |map| {
                it = map.next_retired;
                self.scope.releaseAdmissionExemptArena(map.arena);
            }
            self.retired = null;
        }

        /// An empty generation sized for `name_count` names, in a new arena.
        fn allocateMap(self: *Registry, name_count: u32) error{OutOfMemory}!*Map {
            const slot_count = try Map.slotsFor(name_count);
            const arena = self.scope.createAdmissionExemptArena() catch return error.OutOfMemory;
            errdefer self.scope.releaseAdmissionExemptArena(arena);
            const map_allocator = arena.allocator();
            const map = try map_allocator.create(Map);
            const slots = try map_allocator.alloc(Slot, slot_count);
            for (slots) |*slot| slot.* = .{ .atom = undefined, .name_len = 0, .name_ptr = .init(null) };
            map.* = .{ .slots = slots, .arena = arena };
            return map;
        }

        fn mapCapacity(self: *const Registry) u32 {
            const map = self.current.load(.monotonic) orelse return 0;
            return @intCast(map.slots.len);
        }

        /// Names the live generation takes before a batch must grow it.
        pub fn mapRoom(self: *const Registry) u32 {
            const max_names: u32 = @intCast(Map.maxNames(self.mapCapacity()));
            return max_names - self.name_count;
        }

        /// Tests only, with no other thread reading: forgets `id`'s name, which stays in its
        /// chunk, and returns it for `restoreForTest`. Later names in the probe run shift back
        /// so every lookup still ends at the first empty slot.
        pub fn removeForTest(self: *Registry, id: Atom) ?[]const u8 {
            const map = self.current.load(.monotonic) orelse return null;
            const name = map.find(id) orelse return null;
            const mask = map.slots.len - 1;
            var hole: usize = @intCast(id.value() & mask);
            while (map.slots[hole].atom != id) hole = (hole + 1) & mask;
            var index = hole;
            while (true) {
                index = (index + 1) & mask;
                const slot = &map.slots[index];
                const name_ptr = slot.name_ptr.load(.monotonic) orelse break;
                const home: usize = @intCast(slot.atom.value() & mask);
                // A slot moves into the hole unless its home lies after the hole, up to it.
                const distance_to_home = (index -% home) & mask;
                const distance_to_hole = (index -% hole) & mask;
                if (distance_to_home < distance_to_hole) continue;
                map.slots[hole].atom = slot.atom;
                map.slots[hole].name_len = slot.name_len;
                map.slots[hole].name_ptr.store(name_ptr, .monotonic);
                hole = index;
            }
            map.slots[hole].name_ptr.store(null, .monotonic);
            self.name_count -= 1;
            return name;
        }

        /// Tests only: puts back a name `removeForTest` returned.
        pub fn restoreForTest(self: *Registry, id: Atom, name: []const u8) void {
            const map = self.current.load(.monotonic).?;
            map.insert(id, name);
            self.name_count += 1;
        }

        /// Returns the limit that publication leaves, or refuses a batch that exceeds it.
        fn chargeStorageLimit(self: *const Registry, bytes: usize, map_grows: bool, total: u32) error{OutOfMemory}!?usize {
            const limit = self.storage_limit_for_test orelse return null;
            var cost = bytes;
            if (map_grows) {
                const slots = try Map.slotsFor(total);
                cost += slots * @sizeOf(Slot);
            }
            if (cost > limit) return error.OutOfMemory;
            return limit - cost;
        }

        /// Geometric until the cap, so the chunk count stays small, and a batch larger than
        /// the cap still fits. An earlier chunk's unused tail stays unused.
        fn allocateStringChunk(self: *Registry, bytes: usize) error{OutOfMemory}![]u8 {
            const doubled = self.string_chunk.len *| 2;
            const preferred = std.math.clamp(doubled, min_string_chunk_bytes, max_string_chunk_bytes);
            const chunk_bytes = @max(bytes, preferred);
            const arena = self.scope.createAdmissionExemptArena() catch return error.OutOfMemory;
            errdefer self.scope.releaseAdmissionExemptArena(arena);
            const chunk_allocator = arena.allocator();
            return chunk_allocator.alloc(u8, chunk_bytes);
        }

        /// The name recorded for `id`, or null when none was interned. The owner thread's lookup:
        /// another thread calls `lookupShared`. The slice stays valid until `deinit`.
        pub fn lookup(self: *const Registry, id: Atom) ?[]const u8 {
            const map = self.current.load(.monotonic) orelse return null;
            return map.find(id);
        }

        /// Any thread's lookup: null only for a name not yet published. Takes no lock and never
        /// waits. The name's bytes stay valid until `deinit`, as the owner's do.
        pub fn lookupShared(self: *Registry, id: Atom) ?[]const u8 {
            // Counted before loading `current`, so the owner keeps the generation it loads.
            _ = self.shared_readers.fetchAdd(1, .seq_cst);
            defer _ = self.shared_readers.fetchSub(1, .release);
            const map = self.current.load(.seq_cst) orelse return null;
            return map.find(id);
        }

        /// Interns the name of every tag of `E`, as written, with no prefix. For an enum whose tags
        /// are atoms (`quit = Atom.from("quit").value()`), this makes each tag's atom printable.
        pub fn internEnum(self: *Registry, comptime E: type) void {
            inline for (std.meta.fields(E)) |f| {
                _ = self.intern(f.name);
            }
        }
    };
};

const testing = std.testing;

test "Atom.from hashes strings and converts integer values" {
    try testing.expectEqual(@as(Atom, @enumFromInt(std.hash.Wyhash.hash(0, "literal"))), Atom.from("literal"));
    try testing.expectEqual(@as(Atom, @enumFromInt(std.hash.Wyhash.hash(0, ""))), Atom.from(""));
    try testing.expectEqual(@as(Atom, @enumFromInt(42)), Atom.from(42));

    const comptime_id: u64 = 0xfedc_ba98_7654_3210;
    try testing.expectEqual(@as(Atom, @enumFromInt(comptime_id)), Atom.from(comptime_id));

    var runtime_id: u64 = 0x1234_5678_9abc_def0;
    try testing.expectEqual(@as(Atom, @enumFromInt(runtime_id)), Atom.from(runtime_id));
    runtime_id += 1;
    try testing.expectEqual(@as(Atom, @enumFromInt(runtime_id)), Atom.from(runtime_id));
}

test "Atom.from converts enum values without changing their representation" {
    const Msg = enum(u64) {
        first = Atom.from("first").value(),
        second = Atom.from("second").value(),
        _,
    };

    try testing.expectEqual(@as(Atom, Atom.from("first")), Atom.from(Msg.first));
    try testing.expectEqual(@as(Atom, Atom.from("second")), Atom.from(Msg.second));
}

test "Atom.to accepts const values temporaries and unknown message tags" {
    const Msg = enum(u64) { known = 7, _ };
    const atom = Atom.from(Msg.known);
    try testing.expectEqual(Msg.known, atom.to(Msg));
    try testing.expectEqual(Msg.known, Atom.from(7).to(Msg));
    const unknown = Atom.from(@as(u64, 0xfedc_ba98_7654_3210));
    try testing.expectEqual(unknown, Atom.from(unknown.to(Msg)));
    const runtime = try testing.allocator.dupe(u8, "runtime_text");
    defer testing.allocator.free(runtime);
    try testing.expectEqual(Atom.from("runtime_text"), Atom.from(runtime));
}

test "intern/lookup round trip" {
    var kw: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try kw.init(&mem);
    defer kw.deinit();

    const id = kw.intern("position");
    try testing.expectEqualStrings("position", kw.lookup(id).?);
    const bad_id: Atom = @enumFromInt(@intFromEnum(id) +% 1);
    try testing.expectEqual(@as(?[]const u8, null), kw.lookup(bad_id));
}

test "a shared lookup finds published names, and a generation it may hold outlives growth" {
    var kw: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try kw.init(&mem);
    defer kw.deinit();

    const id = kw.intern("position");
    try testing.expectEqualStrings("position", kw.lookupShared(id).?);
    try testing.expectEqual(@as(?[]const u8, null), kw.lookupShared(Atom.from("never_interned")));

    // A reader inside `lookupShared` keeps every generation replaced meanwhile.
    const arenas_before = kw.scope.stats().dynamic_arena_count;
    const generation_before = kw.map_generation;
    _ = kw.shared_readers.fetchAdd(1, .seq_cst);
    var name_buffer: [32]u8 = undefined;
    var index: usize = 0;
    while (kw.map_generation == generation_before) : (index += 1) {
        const name = try std.fmt.bufPrint(&name_buffer, "grow_{d}", .{index});
        _ = kw.intern(name);
    }
    try testing.expect(kw.retired != null);
    try testing.expectEqual(arenas_before + 1, kw.scope.stats().dynamic_arena_count);
    _ = kw.shared_readers.fetchSub(1, .release);

    // The next publication finds no reader and releases it.
    _ = kw.intern("after_the_reader");
    try testing.expect(kw.retired == null);
    try testing.expectEqual(arenas_before, kw.scope.stats().dynamic_arena_count);
    try testing.expectEqualStrings("position", kw.lookupShared(id).?);
}

test "another thread's lookups find every published name while the owner interns and grows" {
    var kw: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try kw.init(&mem);
    defer kw.deinit();

    const name_count = 20_000;
    const Reader = struct {
        fn run(atoms: *Atom.Registry, published: *const std.atomic.Value(u32), failed: *std.atomic.Value(bool)) void {
            var name_buffer: [32]u8 = undefined;
            var probe: u32 = 0;
            while (true) : (probe +%= 7919) {
                const visible = published.load(.acquire);
                if (visible == 0) continue;
                const index = probe % visible;
                const name = std.fmt.bufPrint(&name_buffer, "shared_{d}", .{index}) catch unreachable;
                const found = atoms.lookupShared(Atom.from(name));
                const matches = found != null and std.mem.eql(u8, found.?, name);
                if (!matches) failed.store(true, .monotonic);
                if (visible == name_count) return;
            }
        }
    };
    var published: std.atomic.Value(u32) = .init(0);
    var failed: std.atomic.Value(bool) = .init(false);
    const reader = try std.Thread.spawn(.{}, Reader.run, .{ &kw, &published, &failed });
    var name_buffer: [32]u8 = undefined;
    for (0..name_count) |index| {
        const name = try std.fmt.bufPrint(&name_buffer, "shared_{d}", .{index});
        _ = kw.intern(name);
        published.store(@intCast(index + 1), .release);
    }
    reader.join();
    try testing.expect(!failed.load(.monotonic));
}

test "re-interning the same name returns the same id without growing the table" {
    var kw: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try kw.init(&mem);
    defer kw.deinit();

    const id1 = kw.intern("velocity");
    const id2 = kw.intern("velocity");
    try testing.expectEqual(id1, id2);
    try testing.expectEqual(@as(u32, 1), kw.name_count);
}

test "distinct names produce distinct ids" {
    var kw: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try kw.init(&mem);
    defer kw.deinit();

    const id_a = kw.intern("health");
    const id_b = kw.intern("name");
    try testing.expect(id_a != id_b);
}

test "internEnum registers unqualified enum tags for reverse lookup" {
    const E = enum(u64) {
        foo = Atom.from("foo").value(),
        bar = Atom.from("bar").value(),
        _,
    };

    var kw: Atom.Registry = undefined;
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    try kw.init(&mem);
    defer kw.deinit();

    kw.internEnum(E);

    try testing.expectEqualStrings("foo", kw.lookup(Atom.from(E.foo)).?);
    try testing.expectEqualStrings("bar", kw.lookup(Atom.from(E.bar)).?);
    try testing.expectEqual(@as(?[]const u8, null), kw.lookup(Atom.from("ns.foo")));
}

test "tryInternAll keeps atom identity copies bytes and allocates nothing for existing IDs" {
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&mem);
    defer atoms.deinit();
    const existing = atoms.intern("existing");
    var spelling = [_]u8{ 'n', 'e', 'w' };
    try atoms.tryInternAll(&.{ "existing", &spelling, "new", "" });
    spelling[0] = 'x';
    try testing.expectEqual(@as(u32, 3), atoms.name_count);
    try testing.expectEqualStrings("new", atoms.lookup(Atom.from("new")).?);
    try testing.expectEqualStrings("", atoms.lookup(Atom.from("")).?);
    try testing.expectEqual(existing, atoms.intern("existing"));
    const stored = atoms.storage();
    atoms.storage_limit_for_test = 0;
    try atoms.tryInternAll(&.{ "new", "existing", "" });
    try testing.expectEqual(stored, atoms.storage());
    try testing.expectEqual(existing, atoms.intern("existing"));
}

test "tryInternAll atom allocator exhaustion rolls back string bytes and map growth at every budget" {
    var failures: usize = 0;
    var successes: usize = 0;
    for (0..800) |remaining| {
        var mem: memory_mod.Memory = undefined;
        mem.init(testing.allocator);
        defer mem.deinit();
        var atoms: Atom.Registry = undefined;
        try atoms.init(&mem);
        defer atoms.deinit();
        for ([_][]const u8{ "old_a", "old_b", "old_c", "old_d", "old_e" }) |name| _ = atoms.intern(name);
        const stored = atoms.storage();
        const count = atoms.name_count;
        const capacity = atoms.storage().map_capacity;
        atoms.storage_limit_for_test = remaining;
        atoms.tryInternAll(&.{ "new_a", "new_b", "new_c", "new_d", "new_e", "new_f", "new_a", "old_a" }) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            failures += 1;
            try testing.expectEqual(stored, atoms.storage());
            try testing.expectEqual(count, atoms.name_count);
            try testing.expectEqual(capacity, atoms.storage().map_capacity);
            for ([_][]const u8{ "new_a", "new_b", "new_c", "new_d", "new_e", "new_f" }) |name| try testing.expect(atoms.lookup(Atom.from(name)) == null);
            try testing.expectEqualStrings("old_a", atoms.lookup(Atom.from("old_a")).?);
            // A failed batch can be retried successfully when real allocator capacity returns.
            atoms.storage_limit_for_test = null;
            try atoms.tryInternAll(&.{ "new_a", "new_b", "new_c", "new_d", "new_e", "new_f" });
            continue;
        };
        successes += 1;
        try testing.expectEqual(count + 6, atoms.name_count);
        try testing.expect(atoms.storage().map_capacity > capacity);
        try testing.expectEqualStrings("new_f", atoms.lookup(Atom.from("new_f")).?);
    }
    try testing.expect(failures > 0);
    try testing.expect(successes > 0);
}

test "tryInternAll real allocation failure at each step leaves names map and pages unchanged" {
    // A batch that needs a new map generation and a new string chunk. Every page request
    // it makes is refused in turn, until one attempt needs fewer requests than the index.
    var long_names: [128][256]u8 = undefined;
    var batch: [128][]const u8 = undefined;
    for (&long_names, &batch, 0..) |*spelling, *name, i| {
        @memset(spelling, 'x');
        _ = try std.fmt.bufPrint(spelling, "long_{d}_", .{i});
        name.* = spelling;
    }
    var failures: usize = 0;
    for (0..16) |fail_at| {
        var mem: memory_mod.Memory = undefined;
        mem.init(testing.allocator);
        defer mem.deinit();
        const page_source = &mem.page_source;
        var atoms: Atom.Registry = undefined;
        try atoms.init(&mem);
        defer atoms.deinit();
        const old = atoms.intern("old_name");
        const old_bytes = atoms.lookup(old).?;
        const stored = atoms.storage();
        const arenas = atoms.scope.stats().dynamic_arena_count;
        page_source.refuseAfter(fail_at);
        atoms.tryInternAll(&batch) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            failures += 1;
            try testing.expectEqual(stored, atoms.storage());
            try testing.expectEqual(arenas, atoms.scope.stats().dynamic_arena_count);
            try testing.expectEqual(@as(u32, 1), atoms.name_count);
            try testing.expect(atoms.lookup(Atom.from(batch[0])) == null);
            try testing.expectEqual(old_bytes.ptr, atoms.lookup(old).?.ptr);
            page_source.refuseNone();
            try atoms.tryInternAll(&batch);
            try testing.expectEqualStrings(batch[127], atoms.lookup(Atom.from(batch[127])).?);
            try testing.expectEqual(old_bytes.ptr, atoms.lookup(old).?.ptr);
            continue;
        };
        try testing.expectEqualStrings(batch[127], atoms.lookup(Atom.from(batch[127])).?);
        break;
    }
    // The map's arena and the string chunk's arena each refused at least once.
    try testing.expect(failures >= 2);
}

test "lookup and re-interning existing atoms reach no allocator" {
    var records = std.testing.FailingAllocator.init(testing.allocator, .{});
    var mem: memory_mod.Memory = undefined;
    mem.init(records.allocator());
    defer mem.deinit();
    const page_source = &mem.page_source;
    var atoms: Atom.Registry = undefined;
    try atoms.init(&mem);
    defer atoms.deinit();
    const id = atoms.intern("present");
    const pages_before = page_source.allocations.load(.monotonic);
    const records_before = records.alloc_index;
    page_source.refuseAfter(0);
    records.fail_index = records_before;
    try testing.expectEqual(id, atoms.intern("present"));
    try atoms.tryInternAll(&.{ "present", "present" });
    try testing.expectEqualStrings("present", atoms.lookup(id).?);
    try testing.expectEqual(pages_before, page_source.allocations.load(.monotonic));
    try testing.expectEqual(records_before, records.alloc_index);
}

test "strings stay stable as storage crosses the former 1 MiB buffer and old map generations return" {
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&mem);
    defer atoms.deinit();
    var name_buffer: [80]u8 = undefined;
    const first_name = try std.fmt.bufPrint(&name_buffer, "atom_{d:0>70}", .{0});
    const first = atoms.intern(first_name);
    const first_bytes = atoms.lookup(first).?;
    var index: usize = 1;
    while (atoms.storage().string_bytes <= 2 * 1024 * 1024) : (index += 1) {
        const name = try std.fmt.bufPrint(&name_buffer, "atom_{d:0>70}", .{index});
        _ = atoms.intern(name);
    }
    const stored = atoms.storage();
    try testing.expect(stored.map_generation > 8);
    try testing.expectEqual(first_bytes.ptr, atoms.lookup(first).?.ptr);
    // Exactly one map generation stays resident next to the string chunks.
    const scope_stats = atoms.scope.stats();
    try testing.expectEqual(@as(usize, stored.string_chunk_count) + 1, scope_stats.dynamic_arena_count);
    // Every name is still reachable and holds its own spelling after every growth.
    for (0..index) |i| {
        const name = try std.fmt.bufPrint(&name_buffer, "atom_{d:0>70}", .{i});
        try testing.expectEqualStrings(name, atoms.lookup(Atom.from(name)).?);
    }
}

test "a name larger than the chunk cap fits in its own chunk" {
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&mem);
    defer atoms.deinit();
    const name = try testing.allocator.alloc(u8, Atom.Registry.max_string_chunk_bytes + 1);
    defer testing.allocator.free(name);
    @memset(name, 'q');
    const id = atoms.intern(name);
    try testing.expectEqualStrings(name, atoms.lookup(id).?);
}

test "growth during an init admission survives abort and leaves the admission valid" {
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&mem);
    defer atoms.deinit();
    const before_admission = atoms.intern("before_admission");
    const generation_before = atoms.storage().map_generation;

    const aborted = try mem.beginInitAdmission();
    var name_buffer: [32]u8 = undefined;
    for (0..64) |i| {
        const name = try std.fmt.bufPrint(&name_buffer, "admitted_{d}", .{i});
        _ = atoms.intern(name);
    }
    try testing.expect(atoms.storage().map_generation > generation_before);
    try mem.validateInitAdmission(aborted);
    // Registration is outside admission state: it neither rejects nor unvalidates.
    for (64..128) |i| {
        const name = try std.fmt.bufPrint(&name_buffer, "admitted_{d}", .{i});
        _ = atoms.intern(name);
    }
    try testing.expect(mem.admission.?.validated);
    try testing.expect(!mem.admission.?.rejected);
    try testing.expect(mem.abortInitAdmission(aborted));

    try testing.expectEqualStrings("before_admission", atoms.lookup(before_admission).?);
    try testing.expectEqualStrings("admitted_127", atoms.lookup(Atom.from("admitted_127")).?);

    const committed = try mem.beginInitAdmission();
    for (128..256) |i| {
        const name = try std.fmt.bufPrint(&name_buffer, "admitted_{d}", .{i});
        _ = atoms.intern(name);
    }
    try mem.validateInitAdmission(committed);
    try testing.expect(mem.commitInitAdmission(committed));
    try testing.expectEqualStrings("admitted_255", atoms.lookup(Atom.from("admitted_255")).?);
}

test "deinit returns the scope so the same Memory can open the interner again" {
    var mem: memory_mod.Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&mem);
    _ = atoms.intern("first_incarnation");
    atoms.deinit();
    try testing.expectEqual(@as(usize, 0), mem.scopes.items.len);
    try atoms.init(&mem);
    defer atoms.deinit();
    try testing.expect(atoms.lookup(Atom.from("first_incarnation")) == null);
}
